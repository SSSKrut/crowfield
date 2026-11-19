package simulation

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log"
	"slices"
	"time"

	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/network/transport"
)

const helloTimeout = 5 * time.Second

// Messages are limited per connection before they are decoded
// (ARCHITECTURE.md, 6.8), so that one client cannot crowd the events of the
// simulation: input datagrams to twice the tick rate, of which an honest
// client sends one a tick, and reliable messages to a few a second, of
// which it sends two in all. Excess datagrams are dropped; excess reliable
// messages close the connection.
const (
	inputRate, inputBurst     = 2 * game.TickRate, game.TickRate / 2
	controlRate, controlBurst = 2, 8
)

// session is a connection as the simulation sees it. It becomes a player once
// its Hello is accepted.
type session struct {
	conn     transport.Conn
	accepted time.Time
	player   *player
}

// reservation keeps the place of a player whose connection was lost, for
// the reconnect window.
type reservation struct {
	id    game.PlayerID
	token [16]byte
	name  string
	team  game.Team
	until time.Time
}

type player struct {
	id         game.PlayerID
	name       string
	team       game.Team
	token      [16]byte
	conn       transport.Conn
	ready      bool
	soldier    game.SoldierID
	controller *game.CharacterController
	// respawnAt is when a dead soldier of the player comes back.
	respawnAt game.Tick

	inputs        inputBuffer
	lastInput     time.Time
	last          game.InputCommand
	processed     bool
	lastProcessed game.Tick
	// newest is the tick of the last command the client sent, as of the
	// latest input packet, if hasInput. After the client's clock jumps back
	// it is the new clock, not the largest tick ever sent.
	newest   game.Tick
	hasInput bool
	lead     int8

	// views is what the player was told about each soldier slot.
	views      []entityView
	removals   []pendingRemoval
	candidates []candidate
	// datagrams counts the snapshot datagrams sent; its low 16 bits are the
	// sequence of the next one. acks holds, by datagram number modulo the
	// window, the number plus one of each acknowledged datagram.
	datagrams uint64
	acks      [ackWindow]uint64
	// allowance is how many bytes the budget of the player still allows.
	allowance  float64
	snapshot   protocol.Snapshot
	packer     protocol.SnapshotPacker
	removedIDs []game.SoldierID
	buffer     []byte
}

type eventKind uint8

const (
	eventConnected eventKind = iota
	eventMessage
	eventInput
	eventClosed
)

type event struct {
	kind    eventKind
	conn    transport.Conn
	message protocol.Message
	input   *protocol.InputPacket
	err     error
}

func (s *Server) accept(ctx context.Context, listener transport.Listener) {
	for {
		conn, err := listener.Accept(ctx)
		if err != nil {
			return
		}
		s.connections.Go(func() { s.serveConn(ctx, conn) })
	}
}

// serveConn reads one connection until it ends. Reliable messages and
// datagrams are read by separate goroutines and posted to the simulation.
func (s *Server) serveConn(ctx context.Context, conn transport.Conn) {
	defer conn.Close("connection ended")
	if !s.post(ctx, event{kind: eventConnected, conn: conn}) {
		return
	}
	s.connections.Go(func() { s.readInputs(ctx, conn) })
	err := s.readControl(ctx, conn)
	s.post(ctx, event{kind: eventClosed, conn: conn, err: err})
}

func (s *Server) readControl(ctx context.Context, conn transport.Conn) error {
	limit := newRateLimit(controlRate, controlBurst)
	for {
		_, data, err := conn.ReceiveReliable(ctx)
		if err != nil {
			return err
		}
		if !limit.allow(time.Now()) {
			err := errors.New("too many messages")
			_ = conn.Close(err.Error())
			return err
		}
		messageType, err := protocol.PeekType(data)
		if err == nil && messageType != protocol.MessageHello && messageType != protocol.MessageReady &&
			messageType != protocol.MessageRespawn {
			err = fmt.Errorf("unexpected %s message", messageType)
		}
		var message protocol.Message
		if err == nil {
			message, _ = protocol.New(messageType)
			err = message.Decode(data)
		}
		if err != nil {
			_ = conn.Close("bad message: " + err.Error())
			return err
		}
		if !s.post(ctx, event{kind: eventMessage, conn: conn, message: message}) {
			return ctx.Err()
		}
	}
}

// readInputs ignores datagrams that do not decode: they are unreliable
// anyway. Datagrams over the limit are dropped unread.
func (s *Server) readInputs(ctx context.Context, conn transport.Conn) {
	limit := newRateLimit(inputRate, inputBurst)
	for {
		data, err := conn.ReceiveUnreliable(ctx)
		if err != nil {
			return
		}
		if !limit.allow(time.Now()) {
			s.droppedInputs.Add(1)
			continue
		}
		packet := &protocol.InputPacket{}
		if packet.Decode(data) != nil {
			continue
		}
		if !s.post(ctx, event{kind: eventInput, conn: conn, input: packet}) {
			return
		}
	}
}

func (s *Server) post(ctx context.Context, e event) bool {
	select {
	case s.events <- e:
		return true
	case <-ctx.Done():
		return false
	}
}

// handleEvents applies what arrived since the last tick, with a cap so that a
// flood of events cannot stall the tick.
func (s *Server) handleEvents() {
	for range cap(s.events) {
		select {
		case e := <-s.events:
			s.handleEvent(e)
		default:
			return
		}
	}
}

func (s *Server) handleEvent(e event) {
	if e.kind == eventConnected {
		s.sessions[e.conn] = &session{conn: e.conn, accepted: time.Now()}
		return
	}
	sess := s.sessions[e.conn]
	if sess == nil {
		return
	}
	switch e.kind {
	case eventMessage:
		switch message := e.message.(type) {
		case *protocol.Hello:
			s.hello(sess, message)
		case *protocol.Ready:
			s.ready(sess)
		case *protocol.Respawn:
			s.respawn(sess)
		}
	case eventInput:
		if sess.player != nil {
			p := sess.player
			p.lastInput = time.Now()
			p.acknowledge(e.input)
			for _, command := range e.input.Commands {
				p.inputs.put(command, s.tick)
			}
			// Late commands count too: they tell how late the client is.
			if count := len(e.input.Commands); count > 0 && int32(e.input.Commands[count-1].Tick-s.tick) < inputWindow {
				p.newest, p.hasInput = e.input.Commands[count-1].Tick, true
			}
		}
	case eventClosed:
		s.leave(sess, e.err)
	}
}

func (s *Server) hello(sess *session, hello *protocol.Hello) {
	if sess.player != nil {
		s.drop(sess, "hello sent twice")
		return
	}
	if hello.ProtocolVersion != protocol.ProtocolVersion {
		s.reject(sess, protocol.RejectVersion,
			fmt.Sprintf("the server speaks protocol %d, the client %d", protocol.ProtocolVersion, hello.ProtocolVersion))
		return
	}
	p := s.returning(hello)
	if p == nil {
		id, ok := s.freePlayer()
		if !ok {
			s.reject(sess, protocol.RejectFull, "the server is full")
			return
		}
		p = s.newPlayer(id, hello.Name)
	}
	p.conn, p.lastInput = sess.conn, time.Now()
	id := p.id
	welcome := protocol.Welcome{
		Player: id, SessionToken: p.token, TickRate: game.TickRate, SnapshotRate: uint8(s.settings.SnapshotRate),
		ServerTick: s.tick, Map: game.PrototypeMap,
		TuningHash: s.rules.Hash(), MatchSeed: s.matchSeed,
	}
	if err := send(sess.conn, &welcome); err != nil {
		s.drop(sess, err.Error())
		return
	}
	s.players[id] = p
	sess.player = p
	if p.team != game.TeamNone {
		log.Printf("player %d %q returned", id, p.name)
	} else {
		log.Printf("player %d %q joined", id, p.name)
	}
}

// returning gives a player who comes back with the token of a lost
// connection its place, name and team again. A connection of that player that
// is still open is closed first: two would make a phantom.
func (s *Server) returning(hello *protocol.Hello) *player {
	if hello.Token == [16]byte{} {
		return nil
	}
	for _, sess := range s.sessions {
		if sess.player != nil && sess.player.token == hello.Token {
			s.drop(sess, "replaced by a new connection")
			break
		}
	}
	for i, r := range s.reservations {
		if r.token == hello.Token {
			s.reservations = append(s.reservations[:i], s.reservations[i+1:]...)
			p := s.newPlayer(r.id, r.name)
			p.token, p.team = r.token, r.team
			return p
		}
	}
	return nil
}

func (s *Server) newPlayer(id game.PlayerID, name string) *player {
	p := &player{id: id, name: name, views: make([]entityView, s.soldiers.Slots())}
	_, _ = rand.Read(p.token[:])
	return p
}

// freePlayer finds a place that is neither taken nor kept for a return.
func (s *Server) freePlayer() (game.PlayerID, bool) {
	for id := range s.settings.MaxPlayers {
		if s.players[id] == nil && !s.reserved(game.PlayerID(id)) {
			return game.PlayerID(id), true
		}
	}
	return 0, false
}

func (s *Server) reserved(id game.PlayerID) bool {
	for _, r := range s.reservations {
		if r.id == id {
			return true
		}
	}
	return false
}

func (s *Server) ready(sess *session) {
	p := sess.player
	if p == nil || p.ready {
		return
	}
	p.ready = true
	if err := s.spawn(p); err != nil {
		log.Printf("player %d could not spawn: %v", p.id, err)
		s.drop(sess, "could not spawn")
	}
}

// spawn gives a player a soldier at the spawn of its team, the team it
// played for before.
func (s *Server) spawn(p *player) error {
	if p.team == game.TeamNone {
		p.team = s.smallerTeam()
	}
	spawn := s.scene.SpawnOf(p.team)
	id, err := s.soldiers.Add(game.Soldier{
		Team: p.team, Controller: game.PlayerController(p.id), Alive: true, Position: spawn,
		Health: game.MaxHealth, Arsenal: game.NewArsenal(game.DefaultLoadout(), &s.rules.Weapons),
	})
	if err != nil {
		return err
	}
	controller, err := game.NewCharacterController(s.world, s.rules.Movement, spawn)
	if err != nil {
		s.soldiers.Remove(id)
		return err
	}
	p.soldier, p.controller = id, controller
	return controller.Teleport(s.soldiers.Get(id), spawn)
}

func (s *Server) smallerTeam() game.Team {
	counts := map[game.Team]int{}
	for soldier := range s.soldiers.All() {
		counts[soldier.Team]++
	}
	if counts[game.TeamRed] < counts[game.TeamBlue] {
		return game.TeamRed
	}
	return game.TeamBlue
}

// respawn puts a living soldier back at its spawn with full health and
// magazines; the dead wait for their time. It is a debug aid of solo play:
// elsewhere anyone could heal and refill at will, so it is refused.
func (s *Server) respawn(sess *session) {
	p := sess.player
	if p == nil || p.soldier == 0 || !s.soldiers.Get(p.soldier).Alive || !s.settings.AllowRespawn {
		return
	}
	soldier := s.soldiers.Get(p.soldier)
	soldier.Health, soldier.Arsenal = game.MaxHealth, game.NewArsenal(game.DefaultLoadout(), &s.rules.Weapons)
	if err := p.controller.Teleport(soldier, s.scene.SpawnOf(soldier.Team)); err != nil {
		log.Printf("player %d could not respawn: %v", p.id, err)
	}
}

func (s *Server) leave(sess *session, reason error) {
	delete(s.sessions, sess.conn)
	_ = sess.conn.Close("connection ended")
	p := sess.player
	if p == nil {
		return
	}
	if p.soldier != 0 {
		// Every other player's view of the slot notices the soldier is gone.
		s.soldiers.Remove(p.soldier)
	}
	if p.controller != nil {
		_ = p.controller.Close()
	}
	s.players[p.id] = nil
	var closed *transport.CloseError
	quit := errors.As(reason, &closed) && closed.Remote && closed.Reason == protocol.QuitReason
	if !quit {
		// The connection was lost, not ended: the player may come back with
		// its token. The soldier is gone meanwhile, so no one waits for it.
		s.reservations = append(s.reservations, reservation{
			id: p.id, token: p.token, name: p.name, team: p.team, until: time.Now().Add(s.settings.ReconnectWindow),
		})
	}
	if closed != nil {
		log.Printf("player %d %q left: %s", p.id, p.name, closed.Reason)
	} else {
		log.Printf("player %d %q left: %v", p.id, p.name, reason)
	}
}

// reject tells the client why before closing. Closing is immediate, so the
// reason also travels as the close reason in case the message is lost.
func (s *Server) reject(sess *session, reason protocol.RejectReason, message string) {
	_ = send(sess.conn, &protocol.Reject{Reason: reason, Message: message})
	s.drop(sess, message)
}

func (s *Server) drop(sess *session, reason string) {
	_ = sess.conn.Close(reason)
	s.leave(sess, errors.New(reason))
}

// dropSilentSessions closes connections that send nothing: no hello in time,
// or no input for the input timeout, which a frozen client or a broken link
// cause before QUIC notices. It also forgets players who did not return.
func (s *Server) dropSilentSessions() {
	for _, sess := range s.sessions {
		switch p := sess.player; {
		case p == nil && time.Since(sess.accepted) > helloTimeout:
			s.drop(sess, "no hello in time")
		case p != nil && time.Since(p.lastInput) > s.settings.InputTimeout:
			s.drop(sess, "no input in time")
		}
	}
	now := time.Now()
	s.reservations = slices.DeleteFunc(s.reservations, func(r reservation) bool {
		if now.After(r.until) {
			log.Printf("player %d %q did not return", r.id, r.name)
			return true
		}
		return false
	})
}

func send(conn transport.Conn, message protocol.Message) error {
	data, err := message.Encode(nil)
	if err != nil {
		return err
	}
	return conn.SendReliable(transport.ChannelControl, data)
}

package simulation

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log"
	"time"

	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/network/transport"
)

const helloTimeout = 5 * time.Second

// session is a connection as the simulation sees it. It becomes a player once
// its Hello is accepted.
type session struct {
	conn     transport.Conn
	accepted time.Time
	player   *player
}

type player struct {
	id         game.PlayerID
	name       string
	token      [16]byte
	conn       transport.Conn
	ready      bool
	soldier    game.SoldierID
	controller *game.CharacterController

	inputs        inputBuffer
	last          game.InputCommand
	processed     bool
	lastProcessed game.Tick
	buffered      int8

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
	for {
		_, data, err := conn.ReceiveReliable(ctx)
		if err != nil {
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

// readInputs ignores datagrams that do not decode: they are unreliable anyway.
func (s *Server) readInputs(ctx context.Context, conn transport.Conn) {
	for {
		data, err := conn.ReceiveUnreliable(ctx)
		if err != nil {
			return
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
			sess.player.acknowledge(e.input)
			for _, command := range e.input.Commands {
				sess.player.inputs.put(command, s.tick)
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
	id, ok := s.freePlayer()
	if !ok {
		s.reject(sess, protocol.RejectFull, "the server is full")
		return
	}
	p := s.newPlayer(id, hello.Name, sess.conn)
	welcome := protocol.Welcome{
		Player: id, SessionToken: p.token, TickRate: game.TickRate, SnapshotRate: uint8(s.settings.SnapshotRate),
		ServerTick: s.tick, Map: game.PrototypeMap,
		TuningHash: s.tuning.Hash(), MatchSeed: s.matchSeed,
	}
	if err := send(sess.conn, &welcome); err != nil {
		s.drop(sess, err.Error())
		return
	}
	s.players[id] = p
	sess.player = p
	log.Printf("player %d %q joined", id, p.name)
}

func (s *Server) newPlayer(id game.PlayerID, name string, conn transport.Conn) *player {
	p := &player{id: id, name: name, conn: conn, views: make([]entityView, s.soldiers.Slots())}
	_, _ = rand.Read(p.token[:])
	return p
}

func (s *Server) freePlayer() (game.PlayerID, bool) {
	for id := range s.settings.MaxPlayers {
		if s.players[id] == nil {
			return game.PlayerID(id), true
		}
	}
	return 0, false
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

func (s *Server) spawn(p *player) error {
	id, err := s.soldiers.Add(game.Soldier{
		Team: s.smallerTeam(), Controller: game.PlayerController(p.id), Alive: true, Position: s.scene.Spawn,
	})
	if err != nil {
		return err
	}
	controller, err := game.NewCharacterController(s.world, s.tuning, s.scene.Spawn)
	if err != nil {
		s.soldiers.Remove(id)
		return err
	}
	p.soldier, p.controller = id, controller
	return controller.Teleport(s.soldiers.Get(id), s.scene.Spawn)
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

func (s *Server) respawn(sess *session) {
	p := sess.player
	if p == nil || p.soldier == 0 {
		return
	}
	if err := p.controller.Teleport(s.soldiers.Get(p.soldier), s.scene.Spawn); err != nil {
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
		_ = p.controller.Close()
	}
	s.players[p.id] = nil
	var closed *transport.CloseError
	if errors.As(reason, &closed) {
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

func (s *Server) dropSilentSessions() {
	for _, sess := range s.sessions {
		if sess.player == nil && time.Since(sess.accepted) > helloTimeout {
			s.drop(sess, "no hello in time")
		}
	}
}

func send(conn transport.Conn, message protocol.Message) error {
	data, err := message.Encode(nil)
	if err != nil {
		return err
	}
	return conn.SendReliable(transport.ChannelControl, data)
}

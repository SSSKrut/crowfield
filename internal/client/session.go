package client

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/network/transport"
)

const (
	connectTimeout = 5 * time.Second
	// commandLead is how many ticks ahead of the server's tick the client's
	// commands should arrive, a margin for jitter.
	commandLead = 2
	// The client keeps the lead by making its ticks longer or shorter, by at
	// most maxDilation and by dilationGain per tick of error in the lead, which
	// it estimates from the snapshots with weight leadSmoothing each.
	maxDilation   = 0.05
	dilationGain  = 0.01
	leadSmoothing = 0.1
	// A lead further than maxLeadError (250 ms) from the target is not worth
	// correcting gently: the clock jumps.
	maxLeadError = game.TickRate / 4
	// A removed soldier's late records are ignored for this long.
	buryTicks = 5 * game.TickRate
	// A server that sends no snapshot for this long is taken for lost.
	serverTimeout = 5 * time.Second
)

// session is the client's side of a connection: it sends a command every tick
// and applies the snapshots it receives.
type session struct {
	conn    transport.Conn
	name    string
	welcome protocol.Welcome

	tick game.Tick
	// judgeFrom is the first tick sent since the clock was last set: a missing
	// command for an earlier tick says nothing about the current clock.
	judgeFrom game.Tick
	// settleUntil is the client tick from which snapshots can reflect commands
	// sent under the current clock; earlier ones were already on their way.
	settleUntil game.Tick
	history     []game.InputCommand
	// lead is the running estimate of the input lead; dilation stretches the
	// client's ticks to bring it to the target.
	lead     float64
	hasLead  bool
	leadTick game.Tick
	dilation float64
	// late counts the snapshots that reported commands arriving late.
	late     int
	acks     ackTracker
	buffer   []byte
	resyncs  int
	received int

	serverTick game.Tick
	player     protocol.PlayerState
	// soldiers are the soldiers the client knows, by slot.
	soldiers  map[int]*knownSoldier
	baselines *protocol.Baselines
	// buried are removed soldiers with the server tick of their removal:
	// their records in datagrams that were on the way are ignored.
	buried     map[game.SoldierID]game.Tick
	resolved   []protocol.SoldierState
	unresolved int
	clock      interpolationClock
	// bytes counts the snapshot datagrams received, payload only.
	bytes atomic.Int64

	snapshots chan received
	graph     netGraph
	// heard is when the last snapshot came; after timeout without one the
	// server is taken for lost.
	heard    time.Time
	timeout  time.Duration
	cancel   context.CancelFunc
	failOnce sync.Once
	failed   chan struct{}
	failure  error
}

var errServerSilent = errors.New("the server stopped sending snapshots")

// connect runs the handshake: Hello, then Welcome or Reject, then Ready. A
// player who lost its connection gives the token of its last session to get
// its place back; a new one gives none.
func connect(conn transport.Conn, name string, rules game.Rules, token [16]byte) (*session, error) {
	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()
	sent := time.Now()
	if err := send(conn, &protocol.Hello{ProtocolVersion: protocol.ProtocolVersion, Name: name, Token: token}); err != nil {
		return nil, err
	}
	_, data, err := conn.ReceiveReliable(ctx)
	// Hello and Welcome make one round trip, the first measure of the network.
	handshakeRTT := time.Since(sent)
	if err != nil {
		var closed *transport.CloseError
		if errors.As(err, &closed) {
			return nil, fmt.Errorf("server refused: %s", closed.Reason)
		}
		return nil, err
	}
	var welcome protocol.Welcome
	if err := welcome.Decode(data); err != nil {
		var reject protocol.Reject
		if reject.Decode(data) == nil {
			return nil, fmt.Errorf("server refused (%s): %s", reject.Reason, reject.Message)
		}
		return nil, fmt.Errorf("bad welcome: %w", err)
	}
	if welcome.TickRate != game.TickRate {
		return nil, fmt.Errorf("server runs at %d Hz, the client at %d Hz", welcome.TickRate, game.TickRate)
	}
	if welcome.TuningHash != rules.Hash() {
		return nil, errors.New("server uses different movement or weapon tuning; prediction would not match")
	}
	if welcome.Map != game.PrototypeMap {
		return nil, fmt.Errorf("server plays map %q, the client only has %q", welcome.Map, game.PrototypeMap)
	}
	if err := send(conn, &protocol.Ready{}); err != nil {
		return nil, err
	}
	readCtx, stop := context.WithCancel(context.Background())
	s := &session{
		conn: conn, name: name, welcome: welcome, history: make([]game.InputCommand, 0, protocol.MaxCommandsPerInput),
		soldiers: make(map[int]*knownSoldier), baselines: protocol.NewBaselines(), buried: make(map[game.SoldierID]game.Tick),
		clock: newInterpolationClock(int(welcome.SnapshotRate)), snapshots: make(chan received, 64),
		cancel: stop, failed: make(chan struct{}), timeout: serverTimeout, heard: time.Now(),
	}
	s.setClock(welcome.ServerTick, handshakeRTT)
	go s.readSnapshots(readCtx)
	go s.readControl(readCtx)
	return s, nil
}

// sendCommand sends the command for the current client tick together with the
// previous ones, so that a lost datagram is covered by the next. It returns the
// command with its tick, for the prediction.
func (s *session) sendCommand(command game.InputCommand) (game.InputCommand, error) {
	if err := s.err(); err != nil {
		return command, err
	}
	command.Tick = s.tick
	command.ViewDelta, command.ViewFrac = s.view(command.Tick)
	if len(s.history) == cap(s.history) {
		copy(s.history, s.history[1:])
		s.history = s.history[:len(s.history)-1]
	}
	s.history = append(s.history, command)
	packet := protocol.InputPacket{HasAck: s.acks.has, AckSequence: s.acks.latest, AckBits: s.acks.bits, Commands: s.history}
	data, err := packet.Encode(s.buffer[:0])
	if err != nil {
		return command, err
	}
	s.buffer = data
	s.tick++
	return command, s.conn.SendUnreliable(data)
}

// view tells the server for lag compensation which moment of its own the
// player sees while it makes the command of tick: the interpolation time of
// the last frame drawn, as whole ticks before the command and a fraction of
// a tick after that. Zero, before the clock started, means now.
func (s *session) view(tick game.Tick) (delta, fraction uint8) {
	if !s.clock.started {
		return 0, 0
	}
	whole := math.Floor(s.clock.renderTick)
	back := float64(tick) - whole
	if back < 1 {
		return 0, 0
	}
	return uint8(min(math.MaxUint8, back)), uint8(min(math.MaxUint8, math.Round((s.clock.renderTick-whole)*256)))
}

func (s *session) respawn() error {
	return send(s.conn, &protocol.Respawn{})
}

// poll applies the snapshots received since the last frame. It reports
// whether the player's own state changed, which calls for reconciliation.
func (s *session) poll() (bool, error) {
	updated := false
	for {
		select {
		case datagram := <-s.snapshots:
			s.heard = time.Now()
			s.graph.datagram(datagram.size, datagram.snapshot)
			updated = s.apply(datagram.snapshot) || updated
		default:
			if s.timeout > 0 && time.Since(s.heard) > s.timeout {
				s.fail(errServerSilent)
				_ = s.conn.Close(errServerSilent.Error())
			}
			return updated, s.err()
		}
	}
}

// token is what the player gives to get its place back after a lost
// connection.
func (s *session) token() [16]byte {
	return s.welcome.SessionToken
}

// received is a decoded snapshot datagram and its size.
type received struct {
	snapshot *protocol.Snapshot
	size     int
}

// knownSoldier is a soldier as the client last heard of it, and its recent
// states for drawing it in the past.
type knownSoldier struct {
	soldier game.Soldier
	// tick is the server tick of the state in soldier; updates counts the
	// states received.
	tick    game.Tick
	updates int
	remote  remoteSoldier
}

// apply takes in one snapshot datagram. Its soldiers are applied even when it
// arrives late, since a soldier may be in no newer datagram; only the private
// state and the clocks need the newest. A delta whose base is missing drops
// the whole datagram, unacknowledged, so the server never builds on it; with
// the rule of protocol.BaseHistory that is a bug, not a network condition.
func (s *session) apply(snapshot *protocol.Snapshot) bool {
	s.resolved = s.resolved[:0]
	for i := range snapshot.Soldiers {
		record := &snapshot.Soldiers[i]
		if s.isBuried(record.State.ID, snapshot.ServerTick) {
			continue
		}
		state, err := s.baselines.Resolve(snapshot.Sequence, record)
		if err != nil {
			s.unresolved++
			log.Printf("snapshot datagram %d dropped: %v", snapshot.Sequence, err)
			return false
		}
		s.resolved = append(s.resolved, state)
	}
	s.acks.observe(snapshot.Sequence)
	s.received++
	for _, id := range snapshot.Removed {
		s.bury(id, snapshot.ServerTick)
	}
	for _, state := range s.resolved {
		s.baselines.Store(snapshot.Sequence, state)
		s.update(state, snapshot.ServerTick, snapshot.Player.Soldier)
	}
	for id, tick := range s.buried {
		if int32(snapshot.ServerTick-tick) > buryTicks {
			delete(s.buried, id)
		}
	}
	if s.received > 1 && snapshot.ServerTick < s.serverTick {
		return false
	}
	s.serverTick, s.player = snapshot.ServerTick, snapshot.Player
	s.clock.observe(snapshot.ServerTick)
	if own := s.localSoldier(); own != nil {
		own.Position, own.Velocity = s.player.Position, s.player.Velocity
	}
	s.keepLead(snapshot.ServerTick)
	return true
}

// keepLead adjusts the client's clock from the input lead the server reports:
// gently by the length of its ticks, or at once when it is far off. Only
// snapshots of ticks whose commands were sent under the current clock count.
func (s *session) keepLead(serverTick game.Tick) {
	if !s.player.Processed || s.player.InputLead == protocol.NoInput || serverTick < s.judgeFrom ||
		s.tick < s.settleUntil || (s.hasLead && serverTick == s.leadTick) {
		return
	}
	sample := float64(s.player.InputLead)
	if sample < 0 {
		s.late++
	}
	if math.Abs(sample-commandLead) > maxLeadError {
		s.jump(commandLead - int(s.player.InputLead))
		return
	}
	if !s.hasLead {
		s.lead, s.hasLead = sample, true
	}
	s.lead += (sample - s.lead) * leadSmoothing
	s.leadTick = serverTick
	s.dilation = max(-maxDilation, min(maxDilation, (s.lead-commandLead)*dilationGain))
}

// tickDuration is how long a client tick takes in real time now.
func (s *session) tickDuration() float32 {
	return game.TickDelta * float32(1+s.dilation)
}

// update applies a soldier's state from a snapshot of the given server tick.
// A new soldier in a known slot replaces the old one, even if the removal of
// that one has not arrived yet.
func (s *session) update(state protocol.SoldierState, tick game.Tick, own game.SoldierID) {
	known := s.soldiers[state.ID.Slot()]
	if known != nil && known.soldier.ID != state.ID {
		s.bury(known.soldier.ID, tick)
		known = nil
	}
	if known == nil {
		known = &knownSoldier{tick: tick}
		s.soldiers[state.ID.Slot()] = known
	}
	if int32(tick-known.tick) >= 0 {
		state.Apply(&known.soldier)
		known.tick = tick
	}
	known.updates++
	if state.ID == own {
		return
	}
	var soldier game.Soldier
	state.Apply(&soldier)
	remote := &known.remote
	if !s.clock.started || remote.count == 0 {
		remote.add(tick, soldier)
		return
	}
	// A state that changes where the soldier is drawn now, after a stretch of
	// extrapolation, is caught up with smoothly.
	before := remote.at(s.clock.renderTick).Position
	remote.add(tick, soldier)
	remote.keep(before, s.clock.renderTick)
}

func (s *session) bury(id game.SoldierID, tick game.Tick) {
	if buried, ok := s.buried[id]; !ok || int32(tick-buried) < 0 {
		s.buried[id] = tick
	}
	s.baselines.Forget(id)
	if known := s.soldiers[id.Slot()]; known != nil && known.soldier.ID == id {
		delete(s.soldiers, id.Slot())
	}
}

// isBuried reports whether a record of the given server tick belongs to a
// soldier removed since. A later record means the slot came round to the
// same generation again.
func (s *session) isBuried(id game.SoldierID, tick game.Tick) bool {
	buried, ok := s.buried[id]
	if ok && int32(tick-buried) > 0 {
		delete(s.buried, id)
		return false
	}
	return ok
}

// resume connects again as the player of a lost session, which the caller
// has abandoned.
func resume(lost *session, conn transport.Conn, rules game.Rules) (*session, error) {
	return connect(conn, lost.name, rules, lost.token())
}

// jump moves the client's clock by the given number of ticks, when the lead
// is too far off to correct gently: after a stall, or a change of route.
func (s *session) jump(ticks int) {
	before := s.tick
	s.tick += game.Tick(ticks)
	ahead := game.Tick(max(0, s.conn.Stats().RTT/game.TickDuration))
	s.judgeFrom, s.settleUntil = s.tick, s.tick+ahead+commandLead+2
	s.history = s.history[:0]
	s.hasLead, s.dilation = false, 0
	s.resyncs++
	log.Printf("clock jump: our commands were %d ticks ahead of server tick %d; client tick %d -> %d",
		s.player.InputLead, s.serverTick, before, s.tick)
}

// setClock sets the client tick from a server tick the client just learned.
// That tick is already half a round trip old and a command needs the other
// half to reach the server, so the client runs a whole round trip plus the
// lead ahead of it.
func (s *session) setClock(serverTick game.Tick, rtt time.Duration) {
	ahead := game.Tick((rtt + game.TickDuration - 1) / game.TickDuration)
	s.tick = serverTick + 1 + commandLead + ahead
	s.judgeFrom = s.tick
	s.settleUntil = s.tick + ahead + commandLead + 2
}

// localSoldier is the player's own soldier as of the latest snapshot, or nil
// before it spawned.
func (s *session) localSoldier() *game.Soldier {
	if known := s.soldiers[s.player.Soldier.Slot()]; known != nil && s.player.Soldier != 0 && known.soldier.ID == s.player.Soldier {
		return &known.soldier
	}
	return nil
}

// close ends the session for good: the server frees the player's place.
func (s *session) close() {
	s.cancel()
	_ = s.conn.Close(protocol.QuitReason)
}

// abandon lets go of a lost session; the player means to come back.
func (s *session) abandon() {
	s.cancel()
	_ = s.conn.Close("connection lost")
}

func (s *session) readSnapshots(ctx context.Context) {
	for {
		data, err := s.conn.ReceiveUnreliable(ctx)
		if err != nil {
			s.fail(err)
			return
		}
		s.bytes.Add(int64(len(data)))
		snapshot := &protocol.Snapshot{}
		if snapshot.Decode(data) != nil {
			continue
		}
		// Keep the newest snapshots when the frame loop falls behind.
		for {
			select {
			case s.snapshots <- received{snapshot: snapshot, size: len(data)}:
			default:
				select {
				case <-s.snapshots:
				default:
				}
				continue
			}
			break
		}
	}
}

// readControl only watches the control channel for now: nothing arrives on it
// after Welcome until match events exist, but a closed connection ends here.
func (s *session) readControl(ctx context.Context) {
	for {
		if _, _, err := s.conn.ReceiveReliable(ctx); err != nil {
			s.fail(err)
			return
		}
	}
}

func (s *session) fail(err error) {
	s.failOnce.Do(func() {
		s.failure = err
		close(s.failed)
	})
}

func (s *session) err() error {
	select {
	case <-s.failed:
		return s.failure
	default:
		return nil
	}
}

// ackTracker remembers which snapshot datagrams arrived: the newest sequence
// and a bit for each of the 32 before it.
type ackTracker struct {
	has    bool
	latest uint16
	bits   uint32
}

func (a *ackTracker) observe(sequence uint16) {
	if !a.has {
		a.has, a.latest, a.bits = true, sequence, 0
		return
	}
	switch distance := int16(sequence - a.latest); {
	case distance > 32:
		a.latest, a.bits = sequence, 0
	case distance > 0:
		a.latest, a.bits = sequence, a.bits<<distance|1<<(distance-1)
	case distance < 0 && -distance <= 32:
		a.bits |= 1 << (-distance - 1)
	}
}

func send(conn transport.Conn, message protocol.Message) error {
	data, err := message.Encode(nil)
	if err != nil {
		return err
	}
	return conn.SendReliable(transport.ChannelControl, data)
}

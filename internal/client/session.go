package client

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/network/transport"
)

const (
	connectTimeout = 5 * time.Second
	// commandLead is how many ticks the client runs ahead of the server, so
	// that a command arrives before the server needs it.
	commandLead = 2
	// A server queue outside [0, maxBuffered] means the client clock drifted;
	// it then jumps back to the lead. Smooth adjustment comes in step 1.9.
	maxBuffered = commandLead + 8
)

// session is the client's side of a connection: it sends a command every tick
// and applies the snapshots it receives.
type session struct {
	conn    transport.Conn
	welcome protocol.Welcome

	tick game.Tick
	// judgeFrom is the first tick sent since the clock was last set: a missing
	// command for an earlier tick says nothing about the current clock.
	judgeFrom game.Tick
	history   []game.InputCommand
	acks      ackTracker
	buffer    []byte
	resyncs   int
	received  int

	serverTick game.Tick
	player     protocol.PlayerState
	soldiers   map[game.SoldierID]*game.Soldier
	remotes    map[game.SoldierID]*remoteSoldier
	clock      interpolationClock

	snapshots chan *protocol.Snapshot
	cancel    context.CancelFunc
	failOnce  sync.Once
	failed    chan struct{}
	failure   error
}

// connect runs the handshake: Hello, then Welcome or Reject, then Ready.
func connect(conn transport.Conn, name string, tuning game.MovementTuning) (*session, error) {
	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()
	sent := time.Now()
	if err := send(conn, &protocol.Hello{ProtocolVersion: protocol.ProtocolVersion, Name: name}); err != nil {
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
	if welcome.TuningHash != tuning.Hash() {
		return nil, errors.New("server uses different movement tuning; prediction would not match")
	}
	if welcome.Map != game.PrototypeMap {
		return nil, fmt.Errorf("server plays map %q, the client only has %q", welcome.Map, game.PrototypeMap)
	}
	if err := send(conn, &protocol.Ready{}); err != nil {
		return nil, err
	}
	readCtx, stop := context.WithCancel(context.Background())
	s := &session{
		conn: conn, welcome: welcome, history: make([]game.InputCommand, 0, protocol.MaxCommandsPerInput),
		soldiers: make(map[game.SoldierID]*game.Soldier), remotes: make(map[game.SoldierID]*remoteSoldier),
		clock: newInterpolationClock(int(welcome.SnapshotRate)), snapshots: make(chan *protocol.Snapshot, 64),
		cancel: stop, failed: make(chan struct{}),
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

func (s *session) respawn() error {
	return send(s.conn, &protocol.Respawn{})
}

// poll applies the snapshots received since the last frame. It reports
// whether the player's own state changed, which calls for reconciliation.
func (s *session) poll() (bool, error) {
	updated := false
	for {
		select {
		case snapshot := <-s.snapshots:
			updated = s.apply(snapshot) || updated
		default:
			return updated, s.err()
		}
	}
}

func (s *session) apply(snapshot *protocol.Snapshot) bool {
	s.acks.observe(snapshot.Sequence)
	s.received++
	if s.received > 1 && snapshot.ServerTick < s.serverTick {
		return false
	}
	s.serverTick, s.player = snapshot.ServerTick, snapshot.Player
	for _, state := range snapshot.Soldiers {
		soldier := s.soldiers[state.ID]
		if soldier == nil {
			soldier = &game.Soldier{}
			s.soldiers[state.ID] = soldier
		}
		state.Apply(soldier)
		if state.ID != s.player.Soldier {
			remote := s.remotes[state.ID]
			if remote == nil {
				remote = &remoteSoldier{}
				s.remotes[state.ID] = remote
			}
			remote.add(snapshot.ServerTick, *soldier)
		}
	}
	for _, id := range snapshot.Removed {
		delete(s.soldiers, id)
		delete(s.remotes, id)
	}
	s.clock.observe(snapshot.ServerTick)
	if own := s.soldiers[s.player.Soldier]; own != nil {
		own.Position, own.Velocity = s.player.Position, s.player.Velocity
	}
	if s.player.Processed && snapshot.ServerTick >= s.judgeFrom &&
		(s.player.BufferedCommands < 0 || s.player.BufferedCommands > maxBuffered) {
		s.resync()
	}
	return true
}

// resync jumps the client tick back to its lead when the server reports that
// commands arrive late or too early.
func (s *session) resync() {
	s.setClock(s.serverTick, s.conn.Stats().RTT)
	s.history = s.history[:0]
	s.resyncs++
}

// setClock sets the client tick from a server tick the client just learned.
// That tick is already half a round trip old and a command needs the other
// half to reach the server, so the client runs a whole round trip plus the
// lead ahead of it.
func (s *session) setClock(serverTick game.Tick, rtt time.Duration) {
	ahead := game.Tick((rtt + game.TickDuration - 1) / game.TickDuration)
	s.tick = serverTick + 1 + commandLead + ahead
	s.judgeFrom = s.tick
}

// localSoldier is the player's own soldier as of the latest snapshot, or nil
// before it spawned.
func (s *session) localSoldier() *game.Soldier {
	return s.soldiers[s.player.Soldier]
}

func (s *session) close() {
	s.cancel()
	_ = s.conn.Close("client quit")
}

func (s *session) readSnapshots(ctx context.Context) {
	for {
		data, err := s.conn.ReceiveUnreliable(ctx)
		if err != nil {
			s.fail(err)
			return
		}
		snapshot := &protocol.Snapshot{}
		if snapshot.Decode(data) != nil {
			continue
		}
		// Keep the newest snapshots when the frame loop falls behind.
		for {
			select {
			case s.snapshots <- snapshot:
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

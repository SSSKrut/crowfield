package client

import (
	"context"
	"fmt"
	"math"
	"math/rand/v2"
	"sync"
	"time"

	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/physics"
)

// Headless is a client without a window, for load tests: it plays with random
// input through the whole client path of a real one — the session with its
// clock, prediction and reconciliation, the snapshots with their deltas and
// interpolation — but draws nothing.
type Headless struct {
	session   *session
	predictor *predictor
	world     *physics.World
	input     wanderer
	last      time.Time
	shots     int
	hits      int
	kills     int
	deaths    int

	mu    sync.Mutex
	stats HeadlessStats
}

// HeadlessStats is what a headless client counted so far.
type HeadlessStats struct {
	Ticks, Snapshots   int
	Bytes              int64
	Jumps, Corrections int
	// Shots counts the shots predicted; WeaponCorrections the corrections
	// where only the weapons disagreed with the server. Hits and Kills are
	// what the server confirmed of the shots, Deaths how often the
	// client's own soldier died.
	Shots, WeaponCorrections int
	Hits, Kills, Deaths      int
	// Unresolved counts snapshot datagrams dropped for a missing delta base;
	// Late counts snapshots that reported commands arriving too late.
	Unresolved, Late int
	Lead             float64
	Soldiers         int
	// LargestCorrection is the largest correction of the prediction, in m.
	LargestCorrection float32
}

// NewHeadless joins a server over conn.
func NewHeadless(conn transport.Conn, name string, rules game.Rules, seed uint64) (*Headless, error) {
	world, err := physics.NewWorld()
	if err != nil {
		return nil, err
	}
	for _, box := range game.PrototypeScene().Boxes {
		if _, err := world.CreateBox(box); err != nil {
			_ = world.Close()
			return nil, err
		}
	}
	predictor, err := newPredictor(world, rules)
	if err != nil {
		_ = world.Close()
		return nil, err
	}
	session, err := connect(conn, name, rules, [16]byte{})
	if err != nil {
		_ = predictor.close()
		_ = world.Close()
		return nil, err
	}
	predictor.join(session.welcome.MatchSeed)
	return &Headless{
		session: session, predictor: predictor, world: world,
		input: wanderer{random: rand.New(rand.NewPCG(seed, seed^0x5eed)), area: game.PrototypeScene().PlayArea},
	}, nil
}

// Run plays until ctx ends or the connection fails, a tick at a time at the
// pace of the session's clock.
func (h *Headless) Run(ctx context.Context) error {
	next := time.Now()
	for {
		select {
		case <-ctx.Done():
			return nil
		default:
		}
		if err := h.Tick(); err != nil {
			return err
		}
		next = next.Add(time.Duration(float64(h.session.tickDuration()) * float64(time.Second)))
		if delay := time.Until(next); delay > 0 {
			time.Sleep(delay)
		} else if delay < -time.Second {
			next = time.Now()
		}
	}
}

// Tick plays one tick: a command, its prediction, the snapshots that came and
// the frame work on the other soldiers.
func (h *Headless) Tick() error {
	command, err := h.session.sendCommand(h.input.command(h.predictor))
	if err != nil {
		return fmt.Errorf("disconnected: %w", err)
	}
	step, err := h.predictor.predict(command)
	if err != nil {
		return err
	}
	if step.Events.Has(game.EventFired) {
		h.shots++
	}
	if err := h.world.Step(game.TickDelta); err != nil {
		return err
	}
	updated, err := h.session.poll()
	if err != nil {
		return fmt.Errorf("disconnected: %w", err)
	}
	if updated {
		if err := h.predictor.reconcile(h.session.player); err != nil {
			return err
		}
	}
	for _, event := range h.session.news {
		switch event := event.(type) {
		case *protocol.HitConfirm:
			h.hits++
			if event.Killed {
				h.kills++
			}
		case *protocol.Death:
			if event.Victim == h.session.player.Soldier {
				h.deaths++
			}
		}
	}
	now := time.Now()
	if h.last.IsZero() {
		h.last = now
	}
	h.predictor.smooth(float32(now.Sub(h.last).Seconds()))
	h.session.clock.advance(float32(now.Sub(h.last).Seconds()))
	h.session.updateRemotes()
	h.last = now
	h.publish()
	return nil
}

func (h *Headless) publish() {
	s := h.session
	h.mu.Lock()
	h.stats = HeadlessStats{
		Ticks: h.stats.Ticks + 1, Snapshots: s.received, Bytes: s.bytes.Load(), Jumps: s.resyncs,
		Corrections: h.predictor.corrections, Unresolved: s.unresolved, Late: s.late, Lead: s.lead,
		Shots: h.shots, WeaponCorrections: h.predictor.weaponCorrections, Hits: h.hits, Kills: h.kills, Deaths: h.deaths,
		Soldiers: len(s.soldiers), LargestCorrection: max(h.stats.LargestCorrection, h.predictor.lastError),
	}
	h.mu.Unlock()
}

// Stats may be called while Run plays.
func (h *Headless) Stats() HeadlessStats {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.stats
}

// Rejoin comes back over a new connection after Run ended with a lost one:
// the server gives the player its place and team again.
func (h *Headless) Rejoin(conn transport.Conn, rules game.Rules) error {
	h.session.abandon()
	session, err := resume(h.session, conn, rules)
	if err != nil {
		return err
	}
	h.session = session
	h.predictor.join(session.welcome.MatchSeed)
	return nil
}

// Player is the player the server knows this client as.
func (h *Headless) Player() game.PlayerID {
	return h.session.welcome.Player
}

// Position is where the client predicts its soldier; call it after Run.
func (h *Headless) Position() physics.Vec3 {
	return h.predictor.soldier.Position
}

func (h *Headless) Close() {
	h.session.close()
	_ = h.predictor.close()
	_ = h.world.Close()
}

// updateRemotes does a frame's work on the other soldiers without drawing
// them: smoothing and interpolating every one.
func (s *session) updateRemotes() {
	for _, known := range s.soldiers {
		if known.soldier.ID != s.player.Soldier && known.remote.count > 0 {
			known.remote.smooth(game.TickDelta)
			_ = known.remote.at(s.clock.renderTick)
		}
	}
}

// wanderer is random input: it walks or runs in a direction for a few
// seconds, sometimes stands or jumps, and turns back inside the play area.
// Now and then it shoots, aims, reloads or takes another weapon.
type wanderer struct {
	random  *rand.Rand
	area    float32
	elapsed float32
	until   float32
	yaw     float32
	forward float32
	buttons game.Buttons
	firing  bool
	weapon  uint8
	ticks   int
}

func (w *wanderer) command(p *predictor) game.InputCommand {
	w.elapsed += game.TickDelta
	position := p.soldier.Position
	if outside := p.started && max(abs(position.X), abs(position.Z)) > w.area-2; outside || w.elapsed >= w.until {
		w.until = w.elapsed + 1 + 2*w.random.Float32()
		w.yaw = w.random.Float32() * 2 * math.Pi
		if outside {
			// Head back towards the middle of the map before the edge.
			w.yaw = float32(math.Atan2(float64(-position.X), float64(position.Z)))
		}
		w.forward, w.buttons = 1, 0
		switch roll := w.random.IntN(10); {
		case roll < 2:
			w.forward = 0
		case roll < 5:
			w.buttons = game.ButtonSprint
		}
		w.firing = w.random.IntN(3) == 0
		if w.firing && w.random.IntN(2) == 0 {
			w.buttons |= game.ButtonAim
		}
		if w.random.IntN(5) == 0 {
			w.weapon = uint8(w.random.IntN(game.MaxLoadout))
		}
	}
	w.ticks++
	buttons := w.buttons
	if w.random.IntN(120) == 0 {
		buttons |= game.ButtonJump
	}
	// Pulls of a quarter second fire bursts and single shots alike.
	if w.firing && w.ticks%30 < 15 {
		buttons |= game.ButtonFire
	}
	if w.random.IntN(240) == 0 {
		buttons |= game.ButtonReload
	}
	command := game.NewInputCommand(0, w.forward, 0, w.yaw, 0, buttons)
	command.Weapon = w.weapon
	return command
}

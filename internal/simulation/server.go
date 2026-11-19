// Package simulation is the authoritative server. Every piece of game state
// belongs to the goroutine that runs Serve; connections only post events to it,
// so the game logic needs no locks.
package simulation

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"log"
	"sync"
	"time"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/physics"
)

const (
	mapName = "prototype"
	// A soldier that falls this far below the map goes back to the spawn.
	fallLimit = -10
)

type Server struct {
	settings         config.Server
	tuning           game.MovementTuning
	scene            game.Scene
	world            *physics.World
	bodies           []*physics.Body
	soldiers         *game.SoldierSet
	players          [game.MaxPlayers]*player
	sessions         map[transport.Conn]*session
	removed          []removal
	events           chan event
	connections      sync.WaitGroup
	tick             game.Tick
	snapshotInterval game.Tick
	matchSeed        uint64

	states    []protocol.SoldierState
	removedID []game.SoldierID
	stats     tickStats
}

type tickStats struct {
	missedCommands uint64
	maxTick        time.Duration
}

// NewServer builds the world of the prototype scene. Only its static part runs
// on the server: dynamic props are not replicated yet, so clients keep them as
// local decoration.
func NewServer(settings config.Server, tuning game.MovementTuning) (*Server, error) {
	if settings.MaxPlayers < 1 || settings.MaxPlayers > game.MaxPlayers {
		return nil, fmt.Errorf("max players must be in 1..%d", game.MaxPlayers)
	}
	if settings.SnapshotRate < 1 || game.TickRate%settings.SnapshotRate != 0 {
		return nil, fmt.Errorf("snapshot rate %d does not divide the tick rate %d", settings.SnapshotRate, game.TickRate)
	}
	if err := tuning.Validate(); err != nil {
		return nil, err
	}
	soldiers, err := game.NewSoldierSet(settings.MaxPlayers)
	if err != nil {
		return nil, err
	}
	world, err := physics.NewWorld()
	if err != nil {
		return nil, err
	}
	var seed [8]byte
	_, _ = rand.Read(seed[:])
	s := &Server{
		settings: settings, tuning: tuning, scene: game.PrototypeScene(), world: world, soldiers: soldiers,
		sessions: make(map[transport.Conn]*session), events: make(chan event, 4096),
		snapshotInterval: game.Tick(game.TickRate / settings.SnapshotRate), matchSeed: binary.LittleEndian.Uint64(seed[:]),
	}
	for _, box := range s.scene.Boxes {
		body, err := world.CreateBox(box)
		if err != nil {
			_ = s.Close()
			return nil, err
		}
		s.bodies = append(s.bodies, body)
	}
	return s, nil
}

// Close frees the world. Call it after Serve has returned.
func (s *Server) Close() error {
	if s.world == nil {
		return nil
	}
	for _, p := range s.players {
		if p != nil && p.controller != nil {
			_ = p.controller.Close()
		}
	}
	for _, body := range s.bodies {
		_ = body.Close()
	}
	s.bodies = nil
	err := s.world.Close()
	s.world = nil
	return err
}

// Serve accepts clients from the listeners and runs the simulation until ctx
// ends. The listeners stay open; their owner closes them.
func (s *Server) Serve(ctx context.Context, listeners ...transport.Listener) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	for _, listener := range listeners {
		s.connections.Go(func() { s.accept(ctx, listener) })
	}
	err := s.run(ctx)
	cancel()
	for conn := range s.sessions {
		_ = conn.Close("server is shutting down")
	}
	s.connections.Wait()
	return err
}

func (s *Server) run(ctx context.Context) error {
	next := time.Now()
	lastStats := time.Now()
	for {
		select {
		case <-ctx.Done():
			log.Printf("server stopped: tick=%d players=%d max_tick=%s", s.tick, s.soldiers.Len(), s.stats.maxTick)
			return nil
		default:
		}
		started := time.Now()
		if err := s.step(); err != nil {
			return err
		}
		s.stats.maxTick = max(s.stats.maxTick, time.Since(started))
		next = next.Add(game.TickDuration)
		if s.settings.StatsInterval > 0 && time.Since(lastStats) >= s.settings.StatsInterval {
			log.Printf("server running: tick=%d rate=%d players=%d missed_commands=%d max_tick=%s",
				s.tick, game.TickRate, s.soldiers.Len(), s.stats.missedCommands, s.stats.maxTick)
			lastStats = time.Now()
			s.stats = tickStats{}
		}
		if delay := time.Until(next); delay > 0 {
			time.Sleep(delay)
		} else if delay < -250*time.Millisecond {
			next = time.Now()
		}
	}
}

// step runs one tick. Commands for this tick move the soldiers, then the world
// steps, then the snapshot describes the state at the end of the tick.
func (s *Server) step() error {
	s.handleEvents()
	s.dropSilentSessions()
	for _, p := range s.players {
		if p != nil && p.soldier != 0 {
			if err := s.movePlayer(p); err != nil {
				return err
			}
		}
	}
	if err := s.world.Step(game.TickDelta); err != nil {
		return err
	}
	if s.tick%s.snapshotInterval == 0 {
		s.sendSnapshots()
	}
	s.tick++
	return nil
}

func (s *Server) movePlayer(p *player) error {
	command, ok := p.inputs.take(s.tick)
	if ok {
		p.buffered = int8(min(127, p.inputs.waiting(s.tick)))
	} else {
		command = p.last.Repeated(s.tick)
		p.buffered = -1
		s.stats.missedCommands++
	}
	command.Sanitize()
	p.last = command
	soldier := s.soldiers.Get(p.soldier)
	if err := p.controller.Step(soldier, command); err != nil {
		return err
	}
	if soldier.Position.Y < fallLimit {
		if err := p.controller.Teleport(soldier, s.scene.Spawn); err != nil {
			return err
		}
	}
	p.processed, p.lastProcessed = true, s.tick
	return nil
}

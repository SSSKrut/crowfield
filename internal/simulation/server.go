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
	"math"
	"runtime"
	"sync"
	"time"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/physics"
)

const (
	// A soldier that falls this far below the map goes back to the spawn.
	fallLimit = -10
	// gridCellSize suits the prototype map and the queries of dummies; it will
	// be tuned with the queries of bots.
	gridCellSize = 8
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
	reservations     []reservation
	events           chan event
	connections      sync.WaitGroup
	tick             game.Tick
	snapshotInterval game.Tick
	matchSeed        uint64
	dummies          dummies
	grid             *game.SoldierGrid
	history          *poseHistory

	// states are the soldiers of the current snapshot by slot, quantized once
	// for every player; a zero ID marks an empty slot.
	states  []protocol.SoldierState
	profile tickProfile
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
	if settings.ClientBandwidth == 0 {
		settings.ClientBandwidth = config.DefaultClientBandwidth
	}
	if settings.InputTimeout <= 0 {
		settings.InputTimeout = config.DefaultInputTimeout
	}
	if settings.ReconnectWindow <= 0 {
		settings.ReconnectWindow = config.DefaultReconnectWindow
	}
	if settings.ClientBandwidth < 0 {
		return nil, fmt.Errorf("client bandwidth %d is negative", settings.ClientBandwidth)
	}
	if err := tuning.Validate(); err != nil {
		return nil, err
	}
	if settings.Dummies < 0 || settings.MaxPlayers+settings.Dummies > game.MaxSoldiers {
		return nil, fmt.Errorf("at most %d soldiers fit, %d players and %d dummies asked", game.MaxSoldiers, settings.MaxPlayers, settings.Dummies)
	}
	capacity := settings.MaxPlayers + settings.Dummies
	soldiers, err := game.NewSoldierSet(capacity)
	if err != nil {
		return nil, err
	}
	world, err := physics.NewWorld()
	if err != nil {
		return nil, err
	}
	var seed [8]byte
	_, _ = rand.Read(seed[:])
	if settings.Seed != 0 {
		binary.LittleEndian.PutUint64(seed[:], settings.Seed)
	}
	s := &Server{
		settings: settings, tuning: tuning, scene: game.PrototypeScene(), world: world, soldiers: soldiers,
		sessions: make(map[transport.Conn]*session), events: make(chan event, 4096),
		snapshotInterval: game.Tick(game.TickRate / settings.SnapshotRate), matchSeed: binary.LittleEndian.Uint64(seed[:]),
		grid: game.NewSoldierGrid(gridCellSize), history: newPoseHistory(capacity),
	}
	for _, box := range s.scene.Boxes {
		body, err := world.CreateBox(box)
		if err != nil {
			_ = s.Close()
			return nil, err
		}
		s.bodies = append(s.bodies, body)
	}
	if err := s.spawnDummies(settings.Dummies); err != nil {
		_ = s.Close()
		return nil, err
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
			log.Printf("server stopped: tick=%d soldiers=%d", s.tick, s.soldiers.Len())
			return nil
		default:
		}
		started := time.Now()
		if err := s.step(); err != nil {
			return err
		}
		s.profile.finish(started)
		next = next.Add(game.TickDuration)
		if since := time.Since(lastStats); s.settings.StatsInterval > 0 && since >= s.settings.StatsInterval {
			players := s.playerCount()
			var memory runtime.MemStats
			runtime.ReadMemStats(&memory)
			log.Printf("server running: tick=%d rate=%.1f players=%d soldiers=%d missed_commands=%d snapshots=%.1fKB/s/player heap=%.1fMB goroutines=%d %s",
				s.tick, float64(s.profile.ticks)/since.Seconds(), players, s.soldiers.Len(), s.profile.missedCommands,
				float64(s.profile.snapshotBytes)/1024/since.Seconds()/float64(max(1, players)),
				float64(memory.HeapInuse)/(1<<20), runtime.NumGoroutine(), &s.profile)
			lastStats = time.Now()
			s.profile = tickProfile{}
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
	s.profile.start()
	s.handleEvents()
	s.dropSilentSessions()
	s.profile.lap(systemEvents)
	for _, p := range s.players {
		if p != nil && p.soldier != 0 {
			if err := s.movePlayer(p); err != nil {
				return err
			}
		}
	}
	s.profile.lap(systemPlayers)
	if err := s.moveDummies(); err != nil {
		return err
	}
	s.profile.lap(systemDummies)
	if err := s.world.Step(game.TickDelta); err != nil {
		return err
	}
	s.profile.lap(systemPhysics)
	s.grid.Rebuild(s.soldiers)
	s.profile.lap(systemGrid)
	s.history.record(s.tick, s.soldiers)
	s.profile.lap(systemHistory)
	if s.tick%s.snapshotInterval == 0 {
		s.sendSnapshots()
	}
	s.profile.lap(systemSnapshots)
	s.tick++
	return nil
}

func (s *Server) playerCount() int {
	count := 0
	for _, p := range s.players {
		if p != nil {
			count++
		}
	}
	return count
}

func (s *Server) movePlayer(p *player) error {
	command, ok := p.inputs.take(s.tick)
	if !ok {
		command = p.last.Repeated(s.tick)
		s.profile.missedCommands++
	}
	p.lead = protocol.NoInput
	if p.hasInput {
		p.lead = int8(max(protocol.NoInput+1, min(math.MaxInt8, int32(p.newest-s.tick))))
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

package simulation

import (
	"context"
	"fmt"
	"log"
	"time"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/physics"
)

type Server struct {
	settings config.Server
	world    *physics.World
	bodies   []*physics.Body
	tick     uint64
}

func NewServer(settings config.Server) (*Server, error) {
	if settings.TickRate <= 0 {
		return nil, fmt.Errorf("tick rate must be positive")
	}
	if err := physics.Init(); err != nil {
		return nil, err
	}
	world, err := physics.NewWorld()
	if err != nil {
		return nil, err
	}
	server := &Server{settings: settings, world: world}
	description := game.PrototypeScene()
	for _, box := range description.Boxes {
		body, err := world.CreateBox(box)
		if err != nil {
			server.Close()
			return nil, err
		}
		server.bodies = append(server.bodies, body)
	}
	for _, sphere := range description.Spheres {
		body, err := world.CreateSphere(sphere)
		if err != nil {
			server.Close()
			return nil, err
		}
		server.bodies = append(server.bodies, body)
	}
	return server, nil
}

func (s *Server) Close() error {
	if s.world == nil {
		return nil
	}
	for _, body := range s.bodies {
		_ = body.Close()
	}
	s.bodies = nil
	return s.world.Close()
}

func (s *Server) Run(ctx context.Context) error {
	step := time.Second / time.Duration(s.settings.TickRate)
	fixedDelta := float32(1.0 / float64(s.settings.TickRate))
	next := time.Now()
	lastStats := time.Now()
	var maxTick time.Duration
	for {
		select {
		case <-ctx.Done():
			log.Printf("server stopped: tick=%d bodies=%d max_tick=%s", s.tick, len(s.bodies), maxTick)
			return nil
		default:
		}
		started := time.Now()
		if err := s.world.Step(fixedDelta); err != nil {
			return err
		}
		s.tick++
		elapsed := time.Since(started)
		if elapsed > maxTick {
			maxTick = elapsed
		}
		next = next.Add(step)
		if time.Since(lastStats) >= s.settings.StatsInterval {
			log.Printf("server running: tick=%d rate=%d bodies=%d max_tick=%s", s.tick, s.settings.TickRate, len(s.bodies), maxTick)
			lastStats = time.Now()
			maxTick = 0
		}
		if delay := time.Until(next); delay > 0 {
			time.Sleep(delay)
		} else if delay < -250*time.Millisecond {
			next = time.Now()
		}
	}
}

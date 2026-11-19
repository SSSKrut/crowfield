package main

import (
	"context"
	"flag"
	"log"
	"os/signal"
	"syscall"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/physics"
	"ravenfield/internal/simulation"
)

func main() {
	settings := config.DefaultServer()
	flag.DurationVar(&settings.StatsInterval, "stats", settings.StatsInterval, "statistics logging interval")
	flag.DurationVar(&settings.RunDuration, "duration", 0, "stop after this duration")
	flag.IntVar(&settings.MaxPlayers, "max-players", settings.MaxPlayers, "maximum number of human players")
	flag.IntVar(&settings.SnapshotRate, "snapshot-rate", settings.SnapshotRate, "snapshots per second; must divide the tick rate")
	flag.Parse()
	if err := run(settings); err != nil {
		log.Fatal(err)
	}
}

func run(settings config.Server) error {
	if err := physics.Init(); err != nil {
		return err
	}
	server, err := simulation.NewServer(settings, game.DefaultMovementTuning())
	if err != nil {
		return err
	}
	defer physics.Shutdown()
	defer server.Close()
	ctx := context.Background()
	if settings.RunDuration > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, settings.RunDuration)
		defer cancel()
	}
	ctx, stop := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	log.Printf("server started: tick_rate=%d", game.TickRate)
	// Clients connect over QUIC from step 1.5; until then the server only ticks.
	return server.Serve(ctx)
}

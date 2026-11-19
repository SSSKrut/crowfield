package main

import (
	"context"
	"flag"
	"log"
	"os/signal"
	"syscall"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/physics"
	"ravenfield/internal/simulation"
)

func main() {
	settings := config.DefaultServer()
	flag.DurationVar(&settings.StatsInterval, "stats", settings.StatsInterval, "statistics logging interval")
	flag.DurationVar(&settings.RunDuration, "duration", 0, "stop after this duration")
	flag.StringVar(&settings.Listen, "listen", settings.Listen, "UDP address for clients")
	flag.StringVar(&settings.Certificate, "cert", settings.Certificate, "certificate file, created on the first run")
	flag.StringVar(&settings.Key, "key", settings.Key, "private key file, created on the first run")
	flag.StringVar(&settings.Tuning, "tuning", "", "JSON file overriding movement tuning; clients need the same")
	flag.IntVar(&settings.MaxPlayers, "max-players", settings.MaxPlayers, "maximum number of human players")
	flag.IntVar(&settings.SnapshotRate, "snapshot-rate", settings.SnapshotRate, "snapshots per second; must divide the tick rate")
	flag.Parse()
	if err := run(settings); err != nil {
		log.Fatal(err)
	}
}

func run(settings config.Server) error {
	tuning := game.DefaultMovementTuning()
	if settings.Tuning != "" {
		loaded, err := game.LoadMovementTuning(settings.Tuning)
		if err != nil {
			return err
		}
		tuning = loaded
	}
	certificate, fingerprint, err := transport.LoadOrCreateCertificate(settings.Certificate, settings.Key)
	if err != nil {
		return err
	}
	if err := physics.Init(); err != nil {
		return err
	}
	defer physics.Shutdown()
	server, err := simulation.NewServer(settings, tuning)
	if err != nil {
		return err
	}
	defer server.Close()
	listener, err := transport.ListenQUIC(settings.Listen, transport.ServerTLSConfig(certificate), transport.QUICOptions{})
	if err != nil {
		return err
	}
	defer listener.Close()
	ctx := context.Background()
	if settings.RunDuration > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, settings.RunDuration)
		defer cancel()
	}
	ctx, stop := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	log.Printf("server started: tick_rate=%d snapshot_rate=%d listen=%s", game.TickRate, settings.SnapshotRate, listener.Addr())
	log.Printf("certificate fingerprint %s", fingerprint)
	return server.Serve(ctx, listener)
}

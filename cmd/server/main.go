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
	flag.StringVar(&settings.Weapons, "weapons", "", "JSON file overriding weapon tuning; clients need the same")
	flag.IntVar(&settings.MaxPlayers, "max-players", settings.MaxPlayers, "maximum number of human players")
	flag.IntVar(&settings.SnapshotRate, "snapshot-rate", settings.SnapshotRate, "snapshots per second; must divide the tick rate")
	flag.IntVar(&settings.Dummies, "dummies", 0, "roaming bot soldiers without AI, for load tests")
	flag.Uint64Var(&settings.Seed, "seed", 0, "match seed for repeatable runs; 0 picks a random one")
	flag.DurationVar(&settings.InputTimeout, "input-timeout", config.DefaultInputTimeout, "disconnect a player who sends no input this long")
	flag.DurationVar(&settings.ReconnectWindow, "reconnect-window", config.DefaultReconnectWindow, "keep the place of a lost player this long")
	flag.DurationVar(&settings.RespawnDelay, "respawn-delay", config.DefaultRespawnDelay, "how long the dead wait to come back")
	flag.BoolVar(&settings.FriendlyFire, "friendly-fire", false, "let shots hurt the shooter's own team")
	flag.DurationVar(&settings.MaxRewind, "max-rewind", config.DefaultMaxRewind, "how far back lag compensation looks")
	bandwidth := flag.Int("client-bandwidth", settings.ClientBandwidth/1024, "snapshot budget of each client, KB/s")
	flag.Parse()
	settings.ClientBandwidth = *bandwidth * 1024
	if err := run(settings); err != nil {
		log.Fatal(err)
	}
}

func run(settings config.Server) error {
	rules, err := game.LoadRules(settings.Tuning, settings.Weapons)
	if err != nil {
		return err
	}
	certificate, fingerprint, err := transport.LoadOrCreateCertificate(settings.Certificate, settings.Key)
	if err != nil {
		return err
	}
	if err := physics.Init(); err != nil {
		return err
	}
	defer physics.Shutdown()
	server, err := simulation.NewServer(settings, rules)
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
	log.Printf("server started: tick_rate=%d snapshot_rate=%d client_bandwidth=%dKB/s listen=%s",
		game.TickRate, settings.SnapshotRate, settings.ClientBandwidth/1024, listener.Addr())
	log.Printf("certificate fingerprint %s", fingerprint)
	return server.Serve(ctx, listener)
}

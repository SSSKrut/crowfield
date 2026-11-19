package client

import (
	"context"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/simulation"
)

// localServer is the server embedded in the client for solo play. The client
// reaches it through an in-memory connection that still carries encoded bytes.
type localServer struct {
	server   *simulation.Server
	listener *transport.MemoryListener
	cancel   context.CancelFunc
	done     chan error
}

func startLocalServer(tuning game.MovementTuning) (*localServer, error) {
	settings := config.DefaultServer()
	settings.MaxPlayers = 1
	settings.StatsInterval = 0
	// Until the client predicts its own soldier (step 1.5) it shows it straight
	// from snapshots, so solo play gets one every tick.
	settings.SnapshotRate = game.TickRate
	server, err := simulation.NewServer(settings, tuning)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	local := &localServer{server: server, listener: transport.NewMemoryListener(), cancel: cancel, done: make(chan error, 1)}
	go func() { local.done <- server.Serve(ctx, local.listener) }()
	return local, nil
}

func (l *localServer) dial() (transport.Conn, error) {
	return l.listener.Dial()
}

func (l *localServer) stop() error {
	l.cancel()
	err := <-l.done
	_ = l.listener.Close()
	if closeErr := l.server.Close(); err == nil {
		err = closeErr
	}
	return err
}

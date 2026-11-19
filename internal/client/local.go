package client

import (
	"context"
	"log"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/simulation"
)

// localServer is the server embedded in the client. Solo play reaches it
// through an in-memory connection that still carries encoded bytes; a host
// also opens it to other players over QUIC.
type localServer struct {
	server  *simulation.Server
	memory  *transport.MemoryListener
	network transport.Listener
	cancel  context.CancelFunc
	done    chan error
}

// startLocalServer starts a solo server, or a hosted one when host is a UDP
// address. A host makes a fresh certificate every run and prints its fingerprint.
func startLocalServer(tuning game.MovementTuning, host string) (*localServer, error) {
	settings := config.DefaultServer()
	settings.MaxPlayers = 1
	settings.StatsInterval = 0
	local := &localServer{memory: transport.NewMemoryListener(), done: make(chan error, 1)}
	listeners := []transport.Listener{local.memory}
	if host != "" {
		settings.MaxPlayers = game.MaxPlayers
		certificate, fingerprint, err := transport.GenerateCertificate()
		if err != nil {
			return nil, err
		}
		if local.network, err = transport.ListenQUIC(host, transport.ServerTLSConfig(certificate), transport.QUICOptions{}); err != nil {
			return nil, err
		}
		listeners = append(listeners, local.network)
		log.Printf("hosting on %s, certificate fingerprint %s", local.network.Addr(), fingerprint)
	}
	server, err := simulation.NewServer(settings, tuning)
	if err != nil {
		if local.network != nil {
			_ = local.network.Close()
		}
		return nil, err
	}
	local.server = server
	ctx, cancel := context.WithCancel(context.Background())
	local.cancel = cancel
	go func() { local.done <- server.Serve(ctx, listeners...) }()
	return local, nil
}

func (l *localServer) dial() (transport.Conn, error) {
	return l.memory.Dial()
}

func (l *localServer) stop() error {
	l.cancel()
	err := <-l.done
	_ = l.memory.Close()
	if l.network != nil {
		_ = l.network.Close()
	}
	if closeErr := l.server.Close(); err == nil {
		err = closeErr
	}
	return err
}

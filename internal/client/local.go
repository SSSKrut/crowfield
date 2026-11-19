package client

import (
	"context"
	"crypto/tls"
	"log"
	"os"
	"path/filepath"

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

// startLocalServer starts a solo server, or a hosted one when the client
// settings name a host address. A host keeps its certificate in the config
// directory, so that the players who joined it once trust it again; without
// one it makes a fresh certificate every run. It prints the fingerprint.
func startLocalServer(tuning game.MovementTuning, client config.Client) (*localServer, error) {
	host := client.Host
	settings := config.DefaultServer()
	settings.MaxPlayers = 1
	settings.StatsInterval = 0
	settings.Dummies = client.Dummies
	local := &localServer{memory: transport.NewMemoryListener(), done: make(chan error, 1)}
	listeners := []transport.Listener{local.memory}
	if host != "" {
		settings.MaxPlayers = game.MaxPlayers
		certificate, fingerprint, err := hostCertificate(client.ConfigDir)
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

func hostCertificate(dir string) (tls.Certificate, transport.Fingerprint, error) {
	if dir == "" {
		return transport.GenerateCertificate()
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return tls.Certificate{}, transport.Fingerprint{}, err
	}
	return transport.LoadOrCreateCertificate(filepath.Join(dir, "host.crt"), filepath.Join(dir, "host.key"))
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

package config

import "time"

type Server struct {
	StatsInterval time.Duration
	RunDuration   time.Duration
	Listen        string
	Certificate   string
	Key           string
	Tuning        string
	MaxPlayers    int
	// SnapshotRate is how many snapshots per second each client receives; it
	// must divide the tick rate.
	SnapshotRate int
	// Dummies are bot soldiers without AI that roam the map, to load the
	// network and the clients until real bots exist.
	Dummies int
	// Seed fixes the match seed, which places the dummies, for runs that
	// repeat; zero picks a random one.
	Seed uint64
	// A player who sends no input for InputTimeout is disconnected; one whose
	// connection was lost keeps its place for ReconnectWindow. Zero means the
	// defaults.
	InputTimeout    time.Duration
	ReconnectWindow time.Duration
	// ClientBandwidth is the snapshot budget of each client in bytes per
	// second, transport overhead included; zero means the default.
	ClientBandwidth int
}

// DefaultClientBandwidth is 32 KB/s (ARCHITECTURE.md, 6.6).
const DefaultClientBandwidth = 32 * 1024

const (
	DefaultInputTimeout    = 5 * time.Second
	DefaultReconnectWindow = time.Minute
)

func DefaultServer() Server {
	return Server{
		StatsInterval: 5 * time.Second, Listen: ":7777", Certificate: "server.crt", Key: "server.key",
		MaxPlayers: 16, SnapshotRate: 20, ClientBandwidth: DefaultClientBandwidth,
	}
}

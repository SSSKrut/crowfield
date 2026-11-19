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
}

func DefaultServer() Server {
	return Server{
		StatsInterval: 5 * time.Second, Listen: ":7777", Certificate: "server.crt", Key: "server.key",
		MaxPlayers: 16, SnapshotRate: 20,
	}
}

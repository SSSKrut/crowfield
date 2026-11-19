package config

import "time"

type Server struct {
	StatsInterval time.Duration
	RunDuration   time.Duration
	MaxPlayers    int
	// SnapshotRate is how many snapshots per second each client receives; it
	// must divide the tick rate.
	SnapshotRate int
}

func DefaultServer() Server {
	return Server{StatsInterval: 5 * time.Second, MaxPlayers: 16, SnapshotRate: 20}
}

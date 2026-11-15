package config

import "time"

type Server struct {
	TickRate      int
	StatsInterval time.Duration
	RunDuration   time.Duration
}

func DefaultServer() Server {
	return Server{TickRate: 30, StatsInterval: 5 * time.Second}
}

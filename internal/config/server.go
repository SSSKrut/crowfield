package config

import "time"

type Server struct {
	StatsInterval time.Duration
	RunDuration   time.Duration
}

func DefaultServer() Server {
	return Server{StatsInterval: 5 * time.Second}
}

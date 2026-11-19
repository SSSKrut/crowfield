package config

import (
	"os"
	"path/filepath"
)

type Client struct {
	Width      int
	Height     int
	FrameLimit int
	Screenshot string
	Demo       bool
	Movement   bool
	// Shoot fires every weapon at the column ahead of the spawn by itself.
	Shoot  bool
	Cycles int
	Debug  bool
	Tuning string
	// Weapons overrides the weapon tuning; the server must use the same.
	Weapons string
	Name    string
	Netsim  string
	// Host opens the embedded server to other players on this UDP address.
	Host string
	// Connect joins a server at this address instead of starting one.
	Connect string
	// Fingerprint pins the certificate of the server given by Connect.
	Fingerprint string
	// ConfigDir keeps the fingerprints of servers joined before and the
	// certificate of a host; empty keeps nothing.
	ConfigDir string
	// Dummies adds roaming bot soldiers without AI to the embedded server.
	Dummies int
	// Overview watches the whole map from above, to see every soldier.
	Overview bool
	// NetGraph shows the network graph from the start.
	NetGraph bool
	// MaxFPS caps the frame rate; zero leaves it free, to measure.
	MaxFPS int
	// Knockdowns knocks down the nearest soldiers this many times, half a
	// second apart, to load the ragdolls.
	Knockdowns       int
	MouseSensitivity float32
	FieldOfView      float32
	// Volume is the master volume from 0 to 1; zero opens no audio device.
	Volume float32
}

func DefaultClient() Client {
	dir, err := os.UserConfigDir()
	if err == nil {
		dir = filepath.Join(dir, "ravenfield")
	}
	return Client{
		ConfigDir: dir,
		Width:     1280, Height: 720, MouseSensitivity: 0.0025, FieldOfView: 75, Name: "Player", MaxFPS: 144, Volume: 0.5,
	}
}

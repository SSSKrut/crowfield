package main

import (
	"flag"
	"log"

	"ravenfield/internal/client"
	"ravenfield/internal/config"
)

func main() {
	settings := config.DefaultClient()
	var volume float64
	flag.IntVar(&settings.Width, "width", settings.Width, "window width")
	flag.IntVar(&settings.Height, "height", settings.Height, "window height")
	flag.IntVar(&settings.FrameLimit, "frames", 0, "close after this many frames")
	flag.StringVar(&settings.Screenshot, "screenshot", "", "save a screenshot on the final frame")
	flag.BoolVar(&settings.Demo, "demo", false, "walk and trigger the ragdoll automatically")
	flag.BoolVar(&settings.Movement, "movement", false, "run and jump toward the ramp automatically")
	flag.BoolVar(&settings.Shoot, "shoot", false, "fire every weapon at the column ahead automatically")
	flag.IntVar(&settings.Cycles, "cycles", 1, "number of automatic ragdoll cycles")
	flag.BoolVar(&settings.Debug, "debug", false, "show physics shapes")
	flag.StringVar(&settings.Tuning, "tuning", "", "JSON file overriding movement tuning")
	flag.StringVar(&settings.Weapons, "weapons", "", "JSON file overriding weapon tuning")
	flag.Float64Var(&volume, "volume", float64(settings.Volume), "sound volume from 0 to 1; 0 is silent")
	flag.StringVar(&settings.Name, "name", settings.Name, "player name")
	flag.StringVar(&settings.Netsim, "netsim", "", "simulate network conditions, e.g. delay=50ms,jitter=10ms,loss=2%")
	flag.StringVar(&settings.Host, "host", "", "let other players join on this UDP address, e.g. :7777")
	flag.StringVar(&settings.Connect, "connect", "", "join the server at this address instead of playing solo; the port defaults to "+client.DefaultPort)
	flag.StringVar(&settings.Fingerprint, "fingerprint", "", "certificate fingerprint the -connect server must have; remembered after the first connection anyway")
	flag.StringVar(&settings.ConfigDir, "config-dir", settings.ConfigDir, "where remembered servers and the host certificate are kept; empty keeps nothing")
	flag.IntVar(&settings.Dummies, "dummies", 0, "roaming bot soldiers without AI on the embedded server")
	flag.Float64Var(&settings.DummyDeaths, "dummy-deaths", 0, "dummies of the embedded server killed at random every second")
	flag.DurationVar(&settings.RespawnDelay, "respawn-delay", 0, "how long the dead of the embedded server wait; 0 is the default")
	flag.DurationVar(&settings.Stats, "stats", 0, "log frame rate, memory and ragdolls this often")
	flag.BoolVar(&settings.Overview, "overview", false, "watch the whole map from above")
	flag.BoolVar(&settings.NetGraph, "netgraph", false, "show the network graph (F2)")
	flag.IntVar(&settings.MaxFPS, "max-fps", settings.MaxFPS, "frame rate cap; 0 leaves it free")
	flag.IntVar(&settings.Knockdowns, "knockdowns", 0, "knock down the nearest soldiers this many times, to load ragdolls")
	flag.Parse()
	settings.Volume = float32(volume)
	if err := client.Run(settings); err != nil {
		log.Fatal(err)
	}
}

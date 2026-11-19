package main

import (
	"flag"
	"log"

	"ravenfield/internal/client"
	"ravenfield/internal/config"
)

func main() {
	settings := config.DefaultClient()
	flag.IntVar(&settings.Width, "width", settings.Width, "window width")
	flag.IntVar(&settings.Height, "height", settings.Height, "window height")
	flag.IntVar(&settings.FrameLimit, "frames", 0, "close after this many frames")
	flag.StringVar(&settings.Screenshot, "screenshot", "", "save a screenshot on the final frame")
	flag.BoolVar(&settings.Demo, "demo", false, "walk and trigger the ragdoll automatically")
	flag.BoolVar(&settings.Movement, "movement", false, "run and jump toward the ramp automatically")
	flag.IntVar(&settings.Cycles, "cycles", 1, "number of automatic ragdoll cycles")
	flag.BoolVar(&settings.Debug, "debug", false, "show physics shapes")
	flag.StringVar(&settings.Tuning, "tuning", "", "JSON file overriding movement tuning")
	flag.StringVar(&settings.Name, "name", settings.Name, "player name")
	flag.StringVar(&settings.Netsim, "netsim", "", "simulate network conditions, e.g. delay=50ms,jitter=10ms,loss=2%")
	flag.StringVar(&settings.Host, "host", "", "let other players join on this UDP address, e.g. :7777")
	flag.StringVar(&settings.Connect, "connect", "", "join the server at this address instead of playing solo")
	flag.StringVar(&settings.Fingerprint, "fingerprint", "", "certificate fingerprint the -connect server must have")
	flag.IntVar(&settings.Dummies, "dummies", 0, "roaming bot soldiers without AI on the embedded server")
	flag.BoolVar(&settings.Overview, "overview", false, "watch the whole map from above")
	flag.IntVar(&settings.MaxFPS, "max-fps", settings.MaxFPS, "frame rate cap; 0 leaves it free")
	flag.IntVar(&settings.Knockdowns, "knockdowns", 0, "knock down the nearest soldiers this many times, to load ragdolls")
	flag.Parse()
	if err := client.Run(settings); err != nil {
		log.Fatal(err)
	}
}

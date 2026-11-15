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
	flag.Parse()
	if err := client.Run(settings); err != nil {
		log.Fatal(err)
	}
}

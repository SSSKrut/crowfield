package game

import "time"

// TickRate is shared by the client and the server: prediction only matches
// the server when both sides step movement with the same delta.
const TickRate = 60

const (
	TickDelta    = float32(1.0 / TickRate)
	TickDuration = time.Second / TickRate
)

// Tick numbers simulation steps; at 60 Hz it wraps after about 2.2 years.
type Tick uint32

package game

import (
	"math"

	"ravenfield/internal/physics"
)

func float32Sin(value float32) float32 {
	return float32(math.Sin(float64(value)))
}

func float32Cos(value float32) float32 {
	return float32(math.Cos(float64(value)))
}

func float32Sqrt(value float32) float32 {
	return float32(math.Sqrt(float64(value)))
}

// ViewDirection is where a soldier with this yaw and pitch looks: yaw zero
// looks along -Z and turns towards +X, a positive pitch looks up.
func ViewDirection(yaw, pitch float32) physics.Vec3 {
	cosPitch := float32Cos(pitch)
	return physics.V(float32Sin(yaw)*cosPitch, float32Sin(pitch), -float32Cos(yaw)*cosPitch)
}

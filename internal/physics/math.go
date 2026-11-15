package physics

import "math"

func float32Sin(value float32) float32 {
	return float32(math.Sin(float64(value)))
}

func float32Cos(value float32) float32 {
	return float32(math.Cos(float64(value)))
}

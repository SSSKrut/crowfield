package render

import (
	"math"

	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

func Vector(value physics.Vec3) rl.Vector3 {
	return rl.NewVector3(value.X, value.Y, value.Z)
}

func Quaternion(value physics.Quat) rl.Quaternion {
	return rl.NewQuaternion(value.X, value.Y, value.Z, value.W)
}

func AxisAngle(value physics.Quat) (rl.Vector3, float32) {
	quaternion := Quaternion(value)
	var axis rl.Vector3
	var angle float32
	quaternion.ToAxisAngle(&axis, &angle)
	return axis, angle * 180 / math.Pi
}

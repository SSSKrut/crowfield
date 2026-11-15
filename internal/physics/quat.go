package physics

import "math"

func QuatMultiply(first, second Quat) Quat {
	return Quat{
		X: first.W*second.X + first.X*second.W + first.Y*second.Z - first.Z*second.Y,
		Y: first.W*second.Y - first.X*second.Z + first.Y*second.W + first.Z*second.X,
		Z: first.W*second.Z + first.X*second.Y - first.Y*second.X + first.Z*second.W,
		W: first.W*second.W - first.X*second.X - first.Y*second.Y - first.Z*second.Z,
	}
}

func QuatRotate(rotation Quat, vector Vec3) Vec3 {
	pure := Quat{X: vector.X, Y: vector.Y, Z: vector.Z}
	inverse := Quat{X: -rotation.X, Y: -rotation.Y, Z: -rotation.Z, W: rotation.W}
	result := QuatMultiply(QuatMultiply(rotation, pure), inverse)
	return V(result.X, result.Y, result.Z)
}

func QuatNormalize(value Quat) Quat {
	length := math.Sqrt(float64(value.X*value.X + value.Y*value.Y + value.Z*value.Z + value.W*value.W))
	if length == 0 {
		return IdentityQuat()
	}
	factor := float32(1 / length)
	return Quat{X: value.X * factor, Y: value.Y * factor, Z: value.Z * factor, W: value.W * factor}
}

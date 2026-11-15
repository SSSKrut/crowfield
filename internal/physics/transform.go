package physics

func QuatConjugate(value Quat) Quat {
	return Quat{X: -value.X, Y: -value.Y, Z: -value.Z, W: value.W}
}

func ComposeTransform(parent, local Transform) Transform {
	return Transform{
		Position: parent.Position.Add(QuatRotate(parent.Rotation, local.Position)),
		Rotation: QuatNormalize(QuatMultiply(parent.Rotation, local.Rotation)),
	}
}

func InverseTransform(value Transform) Transform {
	rotation := QuatConjugate(QuatNormalize(value.Rotation))
	return Transform{Position: QuatRotate(rotation, value.Position.Mul(-1)), Rotation: rotation}
}

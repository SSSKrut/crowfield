package game

import "ravenfield/internal/physics"

type Scene struct {
	Boxes   []physics.BoxDesc
	Spheres []physics.SphereDesc
	Spawn   physics.Vec3
}

func PrototypeScene() Scene {
	identity := func(position physics.Vec3) physics.Transform {
		return physics.Transform{Position: position, Rotation: physics.IdentityQuat()}
	}
	rotated := func(position physics.Vec3, axis physics.Vec3, angle float32) physics.Transform {
		return physics.Transform{Position: position, Rotation: physics.QuatFromAxisAngle(axis, angle)}
	}
	return Scene{
		Spawn: physics.V(0, 1.1, 7),
		Boxes: []physics.BoxDesc{
			{HalfExtents: physics.V(15, 0.25, 15), Transform: identity(physics.V(0, -0.25, 0))},
			{HalfExtents: physics.V(2.5, 0.2, 3), Transform: rotated(physics.V(4, 0.65, 0), physics.V(1, 0, 0), -0.22)},
			{HalfExtents: physics.V(2.5, 0.75, 2.5), Transform: identity(physics.V(4, 0.75, -5))},
			{HalfExtents: physics.V(0.35, 0.6, 2), Transform: identity(physics.V(-2, 0.6, -2))},
			{HalfExtents: physics.V(1.5, 0.15, 0.5), Transform: identity(physics.V(-5, 0.15, 3))},
			{HalfExtents: physics.V(1.5, 0.3, 0.5), Transform: identity(physics.V(-5, 0.3, 2))},
			{HalfExtents: physics.V(1.5, 0.45, 0.5), Transform: identity(physics.V(-5, 0.45, 1))},
			{HalfExtents: physics.V(1.5, 0.6, 0.5), Transform: identity(physics.V(-5, 0.6, 0))},
			{HalfExtents: physics.V(1.5, 0.75, 1.5), Transform: identity(physics.V(-5, 0.75, -1.5))},
			{HalfExtents: physics.V(0.4, 1.2, 0.4), Transform: identity(physics.V(0, 1.2, -4))},
		},
		Spheres: []physics.SphereDesc{
			{Radius: 0.35, Dynamic: true, Transform: identity(physics.V(-1.5, 3, 0))},
			{Radius: 0.45, Dynamic: true, Transform: identity(physics.V(0, 4, 0))},
			{Radius: 0.3, Dynamic: true, Transform: identity(physics.V(1.5, 5, 0))},
		},
	}
}

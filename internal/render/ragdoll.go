package render

import (
	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

func (s *Scene) DrawRagdoll(parts []physics.RagdollPart, transforms []physics.Transform) {
	tint := rl.NewColor(250, 80, 80, 150)
	for i, part := range parts {
		transform := transforms[i]
		position := Vector(transform.Position)
		switch part.Shape {
		case physics.ShapeBox:
			axis, angle := AxisAngle(transform.Rotation)
			rl.DrawModelWiresEx(s.cube, position, axis, angle, Vector(part.Size.Mul(2)), tint)
		case physics.ShapeCapsule:
			offset := physics.QuatRotate(transform.Rotation, physics.V(0, part.Size.X, 0))
			rl.DrawCapsule(Vector(transform.Position.Add(offset)), Vector(transform.Position.Sub(offset)), part.Size.Y, 6, 10, tint)
		case physics.ShapeSphere:
			rl.DrawSphereWires(position, part.Size.X, 10, 8, tint)
		}
		if part.Parent >= 0 {
			rl.DrawLine3D(position, Vector(transforms[part.Parent].Position), rl.Yellow)
		}
	}
}

package render

import (
	"image/color"

	"ravenfield/internal/game"
	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

type boxVisual struct {
	body    *physics.Body
	initial physics.Transform
	half    physics.Vec3
	dynamic bool
	tint    color.RGBA
}

type sphereVisual struct {
	body    *physics.Body
	initial physics.Transform
	radius  float32
	tint    color.RGBA
}

type Scene struct {
	world   *physics.World
	cube    rl.Model
	boxes   []boxVisual
	spheres []sphereVisual
}

func NewScene(world *physics.World, description game.Scene) (*Scene, error) {
	scene := &Scene{world: world}
	mesh := rl.GenMeshCube(1, 1, 1)
	scene.cube = rl.LoadModelFromMesh(mesh)
	for i, description := range description.Boxes {
		body, err := world.CreateBox(description)
		if err != nil {
			_ = scene.Close()
			return nil, err
		}
		tint := rl.NewColor(115, 125, 115, 255)
		if i > 0 {
			tint = rl.NewColor(145, 130, 105, 255)
		}
		scene.boxes = append(scene.boxes, boxVisual{
			body: body, initial: description.Transform, half: description.HalfExtents,
			dynamic: description.Dynamic, tint: tint,
		})
	}
	for i, description := range description.Spheres {
		body, err := world.CreateSphere(description)
		if err != nil {
			_ = scene.Close()
			return nil, err
		}
		tints := []color.RGBA{rl.Orange, rl.SkyBlue, rl.Pink}
		scene.spheres = append(scene.spheres, sphereVisual{
			body: body, initial: description.Transform, radius: description.Radius, tint: tints[i%len(tints)],
		})
	}
	return scene, nil
}

func (s *Scene) Close() error {
	for _, visual := range s.boxes {
		_ = visual.body.Close()
	}
	for _, visual := range s.spheres {
		_ = visual.body.Close()
	}
	rl.UnloadModel(s.cube)
	return nil
}

func (s *Scene) Reset() error {
	for _, visual := range s.boxes {
		if visual.dynamic {
			if err := visual.body.SetTransform(visual.initial); err != nil {
				return err
			}
			if err := visual.body.SetLinearVelocity(physics.Vec3{}); err != nil {
				return err
			}
		}
	}
	for _, visual := range s.spheres {
		if err := visual.body.SetTransform(visual.initial); err != nil {
			return err
		}
		if err := visual.body.SetLinearVelocity(physics.Vec3{}); err != nil {
			return err
		}
	}
	return nil
}

func (s *Scene) Draw(debug bool) {
	for _, visual := range s.boxes {
		transform := visual.initial
		if visual.dynamic {
			transform, _ = visual.body.Transform()
		}
		axis, angle := AxisAngle(transform.Rotation)
		position := Vector(transform.Position)
		scale := Vector(visual.half.Mul(2))
		rl.DrawModelEx(s.cube, position, axis, angle, scale, visual.tint)
		if debug {
			rl.DrawModelWiresEx(s.cube, position, axis, angle, scale, rl.Black)
		}
	}
	for _, visual := range s.spheres {
		transform, _ := visual.body.Transform()
		position := Vector(transform.Position)
		rl.DrawSphereEx(position, visual.radius, 16, 12, visual.tint)
		if debug {
			rl.DrawSphereWires(position, visual.radius, 16, 12, rl.Black)
		}
	}
}

func DrawCharacterCapsule(position physics.Vec3, halfHeight, radius float32) {
	start := Vector(position.Add(physics.V(0, halfHeight, 0)))
	end := Vector(position.Add(physics.V(0, -halfHeight, 0)))
	rl.DrawCapsule(start, end, radius, 8, 16, rl.NewColor(50, 160, 230, 150))
}

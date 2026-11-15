package client

import (
	"fmt"
	"log"
	"math"

	"ravenfield/internal/animation"
	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/physics"
	"ravenfield/internal/render"

	rl "github.com/gen2brain/raylib-go/raylib"
)

const (
	fixedStep           = float32(1.0 / 60.0)
	characterHalfHeight = float32(0.55)
	characterRadius     = float32(0.35)
)

type app struct {
	settings    config.Client
	world       *physics.World
	scene       *render.Scene
	character   *physics.Character
	controller  *game.CharacterController
	model       *animation.CharacterModel
	camera      rl.Camera3D
	yaw         float32
	pitch       float32
	captured    bool
	debug       bool
	thirdPerson bool
	dead        bool
	elapsed     float32
	demoCycle   int
}

func Run(settings config.Client) error {
	rl.SetConfigFlags(rl.FlagWindowResizable | rl.FlagMsaa4xHint)
	rl.InitWindow(int32(settings.Width), int32(settings.Height), "Ravenfield prototype — stage 0")
	defer rl.CloseWindow()
	rl.SetExitKey(0)
	rl.SetTargetFPS(144)

	if err := physics.Init(); err != nil {
		return err
	}
	defer physics.Shutdown()
	world, err := physics.NewWorld()
	if err != nil {
		return err
	}
	defer world.Close()
	description := game.PrototypeScene()
	scene, err := render.NewScene(world, description)
	if err != nil {
		return err
	}
	defer scene.Close()
	character, err := world.CreateCharacter(physics.CharacterDesc{
		Position: description.Spawn, HalfHeight: characterHalfHeight,
		Radius: characterRadius, MaxSlopeRadians: 50 * math.Pi / 180,
	})
	if err != nil {
		return err
	}
	defer character.Close()
	model, err := animation.LoadCharacterModel("assets/prototype/RobotExpressive.glb")
	if err != nil {
		return err
	}
	defer model.Close()

	a := &app{
		settings: settings, world: world, scene: scene, character: character, model: model,
		controller: game.NewCharacterController(character, description.Spawn),
		captured:   settings.FrameLimit == 0, debug: settings.Debug, thirdPerson: true,
	}
	if a.captured {
		rl.DisableCursor()
	}
	return a.run(description.Spawn)
}

func (a *app) run(spawn physics.Vec3) error {
	accumulator := float32(0)
	frames := 0
	for !rl.WindowShouldClose() {
		a.handleMouse()
		if rl.IsKeyPressed(rl.KeyEscape) && a.settings.FrameLimit == 0 {
			a.captured = !a.captured
			if a.captured {
				rl.DisableCursor()
			} else {
				rl.EnableCursor()
			}
		}
		if rl.IsKeyPressed(rl.KeyF1) {
			a.debug = !a.debug
		}
		if rl.IsKeyPressed(rl.KeyF3) {
			a.thirdPerson = !a.thirdPerson
		}
		if rl.IsKeyPressed(rl.KeyK) {
			if err := a.die(); err != nil {
				return err
			}
		}
		if rl.IsKeyPressed(rl.KeyR) {
			if err := a.reset(spawn); err != nil {
				return err
			}
		}

		deltaTime := rl.GetFrameTime()
		if deltaTime > 0.1 {
			deltaTime = 0.1
		}
		a.elapsed += deltaTime
		accumulator += deltaTime
		for accumulator >= fixedStep {
			if !a.dead {
				if err := a.controller.Update(a.input(), fixedStep); err != nil {
					return err
				}
			}
			if err := a.world.Step(fixedStep); err != nil {
				return err
			}
			accumulator -= fixedStep
		}
		position, err := a.controller.Position()
		if err != nil {
			return err
		}
		if position.Y < -10 {
			if err := a.reset(spawn); err != nil {
				return err
			}
			position = spawn
		}
		if a.settings.Demo && !a.dead && a.elapsed >= 1.2 {
			if err := a.die(); err != nil {
				return err
			}
		}
		if a.settings.Demo && a.dead && a.elapsed >= 3 && a.demoCycle+1 < a.settings.Cycles {
			if err := a.reset(spawn); err != nil {
				return err
			}
			a.demoCycle++
			position = spawn
		}
		velocity := a.controller.Velocity()
		speed := float32(math.Sqrt(float64(velocity.X*velocity.X + velocity.Z*velocity.Z)))
		if err := a.model.Update(deltaTime, speed); err != nil {
			return err
		}
		a.updateCamera(position)
		a.draw(position)
		frames++
		if a.settings.Screenshot != "" && frames == a.settings.FrameLimit {
			rl.TakeScreenshot(a.settings.Screenshot)
		}
		if a.settings.FrameLimit > 0 && frames >= a.settings.FrameLimit {
			break
		}
	}
	position, _ := a.controller.Position()
	grounded, _ := a.character.IsGrounded()
	log.Printf("prototype finished: position=%+v grounded=%t ragdoll=%t active=%t animation=%s", position, grounded, a.dead, a.model.RagdollActive(), a.model.AnimationName())
	return nil
}

func (a *app) handleMouse() {
	if !a.captured {
		return
	}
	delta := rl.GetMouseDelta()
	a.yaw += delta.X * a.settings.MouseSensitivity
	a.pitch -= delta.Y * a.settings.MouseSensitivity
	a.pitch = max(-1.45, min(1.45, a.pitch))
}

func (a *app) input() game.PlayerInput {
	input := game.PlayerInput{Yaw: a.yaw}
	if a.settings.Movement {
		switch {
		case a.elapsed < 0.6:
			input.Yaw = math.Pi / 2
			input.Forward = 1
			input.Sprint = true
		case a.elapsed < 2.2:
			input.Yaw = 0
			input.Forward = 1
			input.Sprint = true
			input.Jump = a.elapsed >= 1.1 && a.elapsed < 1.4
		}
		return input
	}
	if a.settings.Demo {
		if a.elapsed < 1.2 {
			input.Forward = 1
			input.Sprint = true
		}
		return input
	}
	if !a.captured {
		return input
	}
	if rl.IsKeyDown(rl.KeyW) {
		input.Forward++
	}
	if rl.IsKeyDown(rl.KeyS) {
		input.Forward--
	}
	if rl.IsKeyDown(rl.KeyD) {
		input.Right++
	}
	if rl.IsKeyDown(rl.KeyA) {
		input.Right--
	}
	input.Jump = rl.IsKeyDown(rl.KeySpace)
	input.Sprint = rl.IsKeyDown(rl.KeyLeftShift)
	return input
}

func (a *app) updateCamera(position physics.Vec3) {
	cosPitch := float32(math.Cos(float64(a.pitch)))
	forward := rl.NewVector3(
		float32(math.Sin(float64(a.yaw)))*cosPitch,
		float32(math.Sin(float64(a.pitch))),
		-float32(math.Cos(float64(a.yaw)))*cosPitch,
	)
	if a.thirdPerson || a.dead {
		target := render.Vector(position.Add(physics.V(0, 0.65, 0)))
		eye := rl.Vector3Add(rl.Vector3Subtract(target, rl.Vector3Scale(forward, 5.5)), rl.NewVector3(0, 0.8, 0))
		a.camera = rl.NewCamera3D(eye, target, rl.NewVector3(0, 1, 0), a.settings.FieldOfView, rl.CameraPerspective)
		return
	}
	eye := render.Vector(position.Add(physics.V(0, 0.65, 0)))
	a.camera = rl.NewCamera3D(eye, rl.Vector3Add(eye, forward), rl.NewVector3(0, 1, 0), a.settings.FieldOfView, rl.CameraPerspective)
}

func (a *app) draw(position physics.Vec3) {
	rl.BeginDrawing()
	rl.ClearBackground(rl.NewColor(135, 175, 205, 255))
	rl.BeginMode3D(a.camera)
	a.scene.Draw(a.debug)
	if a.thirdPerson || a.dead {
		feet := position.Add(physics.V(0, -characterHalfHeight-characterRadius, 0))
		a.model.Draw(feet, physics.QuatFromAxisAngle(physics.V(0, 1, 0), a.yaw))
	}
	if a.debug {
		if !a.dead {
			render.DrawCharacterCapsule(position, characterHalfHeight, characterRadius)
		}
		if parts, transforms, ok := a.model.RagdollDebug(); ok {
			a.scene.DrawRagdoll(parts, transforms)
		}
		rl.DrawGrid(30, 1)
		a.drawRay()
	}
	rl.EndMode3D()
	rl.DrawLine(int32(rl.GetScreenWidth()/2-7), int32(rl.GetScreenHeight()/2), int32(rl.GetScreenWidth()/2+7), int32(rl.GetScreenHeight()/2), rl.White)
	rl.DrawLine(int32(rl.GetScreenWidth()/2), int32(rl.GetScreenHeight()/2-7), int32(rl.GetScreenWidth()/2), int32(rl.GetScreenHeight()/2+7), rl.White)
	rl.DrawText("WASD move | Space jump | Shift sprint | K ragdoll | R reset", 18, 18, 18, rl.White)
	rl.DrawText("F1 physics | F3 camera | Esc cursor", 18, 44, 18, rl.White)
	rl.DrawText(fmt.Sprintf("FPS %d | XYZ %.2f %.2f %.2f | %s", rl.GetFPS(), position.X, position.Y, position.Z, a.model.AnimationName()), 18, 70, 18, rl.White)
	rl.DrawText(fmt.Sprintf("Jolt 5.7.0 | 60 Hz | ragdoll %t active %t | debug %v", a.dead, a.model.RagdollActive(), a.debug), 18, 96, 18, rl.White)
	if !a.captured && a.settings.FrameLimit == 0 {
		rl.DrawText("Press Esc to capture the mouse", 18, 132, 22, rl.Yellow)
	}
	rl.EndDrawing()
}

func (a *app) drawRay() {
	origin := a.camera.Position
	direction := rl.Vector3Normalize(rl.Vector3Subtract(a.camera.Target, a.camera.Position))
	hit, ok, _ := a.world.RayCast(
		physics.V(origin.X, origin.Y, origin.Z),
		physics.V(direction.X, direction.Y, direction.Z),
		100,
	)
	if ok {
		rl.DrawLine3D(origin, render.Vector(hit.Position), rl.Red)
		rl.DrawSphere(render.Vector(hit.Position), 0.06, rl.Red)
	}
}

func (a *app) die() error {
	if a.dead {
		return nil
	}
	position, err := a.controller.Position()
	if err != nil {
		return err
	}
	feet := position.Add(physics.V(0, -characterHalfHeight-characterRadius, 0))
	yaw := physics.QuatFromAxisAngle(physics.V(0, 1, 0), a.yaw)
	impulse := physics.QuatRotate(yaw, physics.V(0, 20, -35))
	if err := a.model.CreateRagdoll(a.world, feet, yaw, a.controller.Velocity(), impulse); err != nil {
		return err
	}
	a.dead = true
	a.thirdPerson = true
	return nil
}

func (a *app) reset(spawn physics.Vec3) error {
	a.yaw = 0
	a.pitch = 0
	a.dead = false
	a.elapsed = 0
	if err := a.model.RemoveRagdoll(); err != nil {
		return err
	}
	if err := a.scene.Reset(); err != nil {
		return err
	}
	return a.controller.Reset()
}

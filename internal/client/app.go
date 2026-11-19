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

const localPlayer = game.PlayerID(0)

type app struct {
	settings    config.Client
	world       *physics.World
	scene       *render.Scene
	tuning      game.MovementTuning
	soldiers    *game.SoldierSet
	soldierID   game.SoldierID
	controller  *game.CharacterController
	model       *animation.CharacterModel
	camera      rl.Camera3D
	yaw         float32
	pitch       float32
	tick        game.Tick
	captured    bool
	debug       bool
	thirdPerson bool
	elapsed     float32
	demoCycle   int
}

func Run(settings config.Client) error {
	tuning := game.DefaultMovementTuning()
	if settings.Tuning != "" {
		loaded, err := game.LoadMovementTuning(settings.Tuning)
		if err != nil {
			return err
		}
		tuning = loaded
	}

	rl.SetConfigFlags(rl.FlagWindowResizable | rl.FlagMsaa4xHint)
	rl.InitWindow(int32(settings.Width), int32(settings.Height), "Ravenfield prototype — stage 1")
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
	soldiers, err := game.NewSoldierSet(game.MaxPlayers)
	if err != nil {
		return err
	}
	soldierID, err := soldiers.Add(game.Soldier{
		Team: game.TeamBlue, Controller: game.PlayerController(localPlayer),
		Alive: true, Position: description.Spawn,
	})
	if err != nil {
		return err
	}
	controller, err := game.NewCharacterController(world, tuning, description.Spawn)
	if err != nil {
		return err
	}
	defer controller.Close()
	model, err := animation.LoadCharacterModel("assets/prototype/RobotExpressive.glb")
	if err != nil {
		return err
	}
	defer model.Close()

	a := &app{
		settings: settings, world: world, scene: scene, tuning: tuning, soldiers: soldiers,
		soldierID: soldierID, controller: controller, model: model,
		captured: settings.FrameLimit == 0, debug: settings.Debug, thirdPerson: true,
	}
	if a.captured {
		rl.DisableCursor()
	}
	return a.run(description.Spawn)
}

func (a *app) run(spawn physics.Vec3) error {
	soldier := a.soldiers.Get(a.soldierID)
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
			if err := a.die(soldier); err != nil {
				return err
			}
		}
		if rl.IsKeyPressed(rl.KeyR) {
			if err := a.reset(soldier, spawn); err != nil {
				return err
			}
		}

		deltaTime := rl.GetFrameTime()
		if deltaTime > 0.1 {
			deltaTime = 0.1
		}
		a.elapsed += deltaTime
		accumulator += deltaTime
		for accumulator >= game.TickDelta {
			if soldier.Alive {
				if err := a.controller.Step(soldier, a.command()); err != nil {
					return err
				}
			}
			if err := a.world.Step(game.TickDelta); err != nil {
				return err
			}
			a.tick++
			accumulator -= game.TickDelta
		}
		if soldier.Position.Y < -10 {
			if err := a.reset(soldier, spawn); err != nil {
				return err
			}
		}
		if a.settings.Demo && soldier.Alive && a.elapsed >= 1.2 {
			if err := a.die(soldier); err != nil {
				return err
			}
		}
		if a.settings.Demo && !soldier.Alive && a.elapsed >= 3 && a.demoCycle+1 < a.settings.Cycles {
			if err := a.reset(soldier, spawn); err != nil {
				return err
			}
			a.demoCycle++
		}
		velocity := soldier.Velocity
		speed := float32(math.Sqrt(float64(velocity.X*velocity.X + velocity.Z*velocity.Z)))
		if err := a.model.Update(deltaTime, speed); err != nil {
			return err
		}
		a.updateCamera(soldier)
		a.draw(soldier)
		frames++
		if a.settings.Screenshot != "" && frames == a.settings.FrameLimit {
			rl.TakeScreenshot(a.settings.Screenshot)
		}
		if a.settings.FrameLimit > 0 && frames >= a.settings.FrameLimit {
			break
		}
	}
	log.Printf("prototype finished: tick=%d feet=%+v grounded=%t ragdoll=%t active=%t animation=%s", a.tick, soldier.Position, soldier.Grounded, !soldier.Alive, a.model.RagdollActive(), a.model.AnimationName())
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

func (a *app) command() game.InputCommand {
	var forward, right float32
	var buttons game.Buttons
	yaw := a.yaw
	switch {
	case a.settings.Movement:
		switch {
		case a.elapsed < 0.6:
			yaw, forward, buttons = math.Pi/2, 1, game.ButtonSprint
		case a.elapsed < 2.2:
			yaw, forward, buttons = 0, 1, game.ButtonSprint
			if a.elapsed >= 1.1 && a.elapsed < 1.4 {
				buttons |= game.ButtonJump
			}
		}
	case a.settings.Demo:
		if a.elapsed < 1.2 {
			forward, buttons = 1, game.ButtonSprint
		}
	case a.captured:
		if rl.IsKeyDown(rl.KeyW) {
			forward++
		}
		if rl.IsKeyDown(rl.KeyS) {
			forward--
		}
		if rl.IsKeyDown(rl.KeyD) {
			right++
		}
		if rl.IsKeyDown(rl.KeyA) {
			right--
		}
		if rl.IsKeyDown(rl.KeySpace) {
			buttons |= game.ButtonJump
		}
		if rl.IsKeyDown(rl.KeyLeftShift) {
			buttons |= game.ButtonSprint
		}
	}
	return game.NewInputCommand(a.tick, forward, right, yaw, a.pitch, buttons)
}

func (a *app) updateCamera(soldier *game.Soldier) {
	cosPitch := float32(math.Cos(float64(a.pitch)))
	forward := rl.NewVector3(
		float32(math.Sin(float64(a.yaw)))*cosPitch,
		float32(math.Sin(float64(a.pitch))),
		-float32(math.Cos(float64(a.yaw)))*cosPitch,
	)
	eye := render.Vector(soldier.Position.Add(physics.V(0, a.tuning.EyeHeight, 0)))
	if a.thirdPerson || !soldier.Alive {
		target := eye
		eye = rl.Vector3Add(rl.Vector3Subtract(target, rl.Vector3Scale(forward, 5.5)), rl.NewVector3(0, 0.8, 0))
		a.camera = rl.NewCamera3D(eye, target, rl.NewVector3(0, 1, 0), a.settings.FieldOfView, rl.CameraPerspective)
		return
	}
	a.camera = rl.NewCamera3D(eye, rl.Vector3Add(eye, forward), rl.NewVector3(0, 1, 0), a.settings.FieldOfView, rl.CameraPerspective)
}

func (a *app) draw(soldier *game.Soldier) {
	feet := soldier.Position
	rl.BeginDrawing()
	rl.ClearBackground(rl.NewColor(135, 175, 205, 255))
	rl.BeginMode3D(a.camera)
	a.scene.Draw(a.debug)
	if a.thirdPerson || !soldier.Alive {
		a.model.Draw(feet, physics.QuatFromAxisAngle(physics.V(0, 1, 0), a.yaw))
	}
	if a.debug {
		if soldier.Alive {
			center := feet.Add(physics.V(0, a.tuning.CenterHeight(), 0))
			render.DrawCharacterCapsule(center, a.tuning.CapsuleHalfHeight, a.tuning.CapsuleRadius)
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
	rl.DrawText(fmt.Sprintf("FPS %d | XYZ %.2f %.2f %.2f | %s", rl.GetFPS(), feet.X, feet.Y, feet.Z, a.model.AnimationName()), 18, 70, 18, rl.White)
	rl.DrawText(fmt.Sprintf("Jolt 5.7.0 | %d Hz | tick %d | ragdoll %t active %t | debug %v", game.TickRate, a.tick, !soldier.Alive, a.model.RagdollActive(), a.debug), 18, 96, 18, rl.White)
	if !a.captured && a.settings.FrameLimit == 0 {
		rl.DrawText("Press Esc to capture the mouse", 18, 132, 22, rl.Yellow)
	}
	rl.EndDrawing()
}

func (a *app) drawRay() {
	origin := a.camera.Position
	direction := rl.Vector3Normalize(rl.Vector3Subtract(a.camera.Target, a.camera.Position))
	hit, _ := a.world.RayCast(physics.Ray{
		Origin:    physics.V(origin.X, origin.Y, origin.Z),
		Direction: physics.V(direction.X, direction.Y, direction.Z),
		Distance:  100,
	}, physics.Mask(physics.LayerStatic, physics.LayerVehicle, physics.LayerDynamic))
	if hit.Hit {
		rl.DrawLine3D(origin, render.Vector(hit.Position), rl.Red)
		rl.DrawSphere(render.Vector(hit.Position), 0.06, rl.Red)
	}
}

func (a *app) die(soldier *game.Soldier) error {
	if !soldier.Alive {
		return nil
	}
	yaw := physics.QuatFromAxisAngle(physics.V(0, 1, 0), a.yaw)
	impulse := physics.QuatRotate(yaw, physics.V(0, 20, -35))
	if err := a.model.CreateRagdoll(a.world, soldier.Position, yaw, soldier.Velocity, impulse); err != nil {
		return err
	}
	soldier.Alive = false
	a.thirdPerson = true
	return nil
}

func (a *app) reset(soldier *game.Soldier, spawn physics.Vec3) error {
	a.yaw = 0
	a.pitch = 0
	a.elapsed = 0
	if err := a.model.RemoveRagdoll(); err != nil {
		return err
	}
	if err := a.scene.Reset(); err != nil {
		return err
	}
	soldier.Alive = true
	return a.controller.Teleport(soldier, spawn)
}

package client

import (
	"fmt"
	"log"
	"math"

	"ravenfield/internal/animation"
	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/physics"
	"ravenfield/internal/render"

	rl "github.com/gen2brain/raylib-go/raylib"
)

type app struct {
	settings    config.Client
	world       *physics.World
	scene       *render.Scene
	spawn       physics.Vec3
	tuning      game.MovementTuning
	session     *session
	model       *animation.CharacterModel
	camera      rl.Camera3D
	yaw         float32
	pitch       float32
	captured    bool
	debug       bool
	thirdPerson bool
	ragdoll     bool
	elapsed     float32
	demoCycle   int
}

// Run starts the embedded server, connects to it and plays. The client world
// only holds cosmetic physics: ragdolls and the props of the prototype scene.
func Run(settings config.Client) error {
	tuning := game.DefaultMovementTuning()
	if settings.Tuning != "" {
		loaded, err := game.LoadMovementTuning(settings.Tuning)
		if err != nil {
			return err
		}
		tuning = loaded
	}
	conditions, err := transport.ParseNetworkConditions(settings.Netsim)
	if err != nil {
		return err
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

	local, err := startLocalServer(tuning)
	if err != nil {
		return err
	}
	defer func() {
		if err := local.stop(); err != nil {
			log.Printf("local server: %v", err)
		}
	}()
	conn, err := local.dial()
	if err != nil {
		return err
	}
	if conditions != (transport.NetworkConditions{}) {
		log.Printf("simulating network: %s", conditions)
		conn = transport.Simulate(conn, conditions)
	}
	session, err := connect(conn, settings.Name, tuning)
	if err != nil {
		_ = conn.Close("handshake failed")
		return err
	}
	defer session.close()

	model, err := animation.LoadCharacterModel("assets/prototype/RobotExpressive.glb")
	if err != nil {
		return err
	}
	defer model.Close()

	a := &app{
		settings: settings, world: world, scene: scene, spawn: description.Spawn, tuning: tuning, session: session,
		model: model, captured: settings.FrameLimit == 0, debug: settings.Debug, thirdPerson: true,
	}
	if a.captured {
		rl.DisableCursor()
	}
	return a.run()
}

func (a *app) run() error {
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
			if err := a.reset(); err != nil {
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
			if err := a.session.sendCommand(a.command()); err != nil {
				return fmt.Errorf("disconnected: %w", err)
			}
			if err := a.world.Step(game.TickDelta); err != nil {
				return err
			}
			accumulator -= game.TickDelta
		}
		if err := a.session.poll(); err != nil {
			return fmt.Errorf("disconnected: %w", err)
		}
		soldier := a.session.localSoldier()
		if a.settings.Demo && soldier != nil && !a.ragdoll && a.elapsed >= 1.2 {
			if err := a.die(); err != nil {
				return err
			}
		}
		if a.settings.Demo && a.ragdoll && a.elapsed >= 3 && a.demoCycle+1 < a.settings.Cycles {
			if err := a.reset(); err != nil {
				return err
			}
			a.demoCycle++
		}
		feet := a.spawn
		var speed float32
		if soldier != nil {
			feet = soldier.Position
			speed = float32(math.Hypot(float64(soldier.Velocity.X), float64(soldier.Velocity.Z)))
		}
		if err := a.model.Update(deltaTime, speed); err != nil {
			return err
		}
		a.updateCamera(feet)
		a.draw(feet, soldier != nil)
		frames++
		if a.settings.Screenshot != "" && frames == a.settings.FrameLimit {
			rl.TakeScreenshot(a.settings.Screenshot)
		}
		if a.settings.FrameLimit > 0 && frames >= a.settings.FrameLimit {
			break
		}
	}
	var soldier game.Soldier
	if own := a.session.localSoldier(); own != nil {
		soldier = *own
	}
	log.Printf("prototype finished: tick=%d server_tick=%d feet=%+v grounded=%t ragdoll=%t active=%t animation=%s snapshots=%d resyncs=%d",
		a.session.tick, a.session.serverTick, soldier.Position, soldier.Grounded, a.ragdoll, a.model.RagdollActive(),
		a.model.AnimationName(), a.session.received, a.session.resyncs)
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

// command reads the input for one tick. While the cosmetic ragdoll lies on the
// ground the soldier stands still on the server.
func (a *app) command() game.InputCommand {
	var forward, right float32
	var buttons game.Buttons
	yaw := a.yaw
	switch {
	case a.ragdoll:
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
	return game.NewInputCommand(0, forward, right, yaw, a.pitch, buttons)
}

func (a *app) updateCamera(feet physics.Vec3) {
	cosPitch := float32(math.Cos(float64(a.pitch)))
	forward := rl.NewVector3(
		float32(math.Sin(float64(a.yaw)))*cosPitch,
		float32(math.Sin(float64(a.pitch))),
		-float32(math.Cos(float64(a.yaw)))*cosPitch,
	)
	eye := render.Vector(feet.Add(physics.V(0, a.tuning.EyeHeight, 0)))
	if a.thirdPerson || a.ragdoll {
		target := eye
		eye = rl.Vector3Add(rl.Vector3Subtract(target, rl.Vector3Scale(forward, 5.5)), rl.NewVector3(0, 0.8, 0))
		a.camera = rl.NewCamera3D(eye, target, rl.NewVector3(0, 1, 0), a.settings.FieldOfView, rl.CameraPerspective)
		return
	}
	a.camera = rl.NewCamera3D(eye, rl.Vector3Add(eye, forward), rl.NewVector3(0, 1, 0), a.settings.FieldOfView, rl.CameraPerspective)
}

func (a *app) draw(feet physics.Vec3, spawned bool) {
	rl.BeginDrawing()
	rl.ClearBackground(rl.NewColor(135, 175, 205, 255))
	rl.BeginMode3D(a.camera)
	a.scene.Draw(a.debug)
	if spawned && (a.thirdPerson || a.ragdoll) {
		a.model.Draw(feet, physics.QuatFromAxisAngle(physics.V(0, 1, 0), a.yaw))
	}
	// Other soldiers are capsules until the client renders several models (step 1.8).
	for id, soldier := range a.session.soldiers {
		if id != a.session.player.Soldier || (a.debug && !a.ragdoll) {
			center := soldier.Position.Add(physics.V(0, a.tuning.CenterHeight(), 0))
			render.DrawCharacterCapsule(center, a.tuning.CapsuleHalfHeight, a.tuning.CapsuleRadius)
		}
	}
	if a.debug {
		if parts, transforms, ok := a.model.RagdollDebug(); ok {
			a.scene.DrawRagdoll(parts, transforms)
		}
		rl.DrawGrid(30, 1)
		a.drawRay()
	}
	rl.EndMode3D()
	rl.DrawLine(int32(rl.GetScreenWidth()/2-7), int32(rl.GetScreenHeight()/2), int32(rl.GetScreenWidth()/2+7), int32(rl.GetScreenHeight()/2), rl.White)
	rl.DrawLine(int32(rl.GetScreenWidth()/2), int32(rl.GetScreenHeight()/2-7), int32(rl.GetScreenWidth()/2), int32(rl.GetScreenHeight()/2+7), rl.White)
	rl.DrawText("WASD move | Space jump | Shift sprint | K ragdoll | R respawn", 18, 18, 18, rl.White)
	rl.DrawText("F1 physics | F3 camera | Esc cursor", 18, 44, 18, rl.White)
	rl.DrawText(fmt.Sprintf("FPS %d | XYZ %.2f %.2f %.2f | %s", rl.GetFPS(), feet.X, feet.Y, feet.Z, a.model.AnimationName()), 18, 70, 18, rl.White)
	stats := a.session.conn.Stats()
	rl.DrawText(fmt.Sprintf("%d Hz | tick %d server %d buffered %d | RTT %d ms | resyncs %d | ragdoll %t",
		game.TickRate, a.session.tick, a.session.serverTick, a.session.player.BufferedCommands,
		stats.RTT.Milliseconds(), a.session.resyncs, a.ragdoll), 18, 96, 18, rl.White)
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

// die shows the cosmetic ragdoll. Death itself is decided by the server from
// stage 2 on; until then the soldier only stands still on the server.
func (a *app) die() error {
	soldier := a.session.localSoldier()
	if a.ragdoll || soldier == nil {
		return nil
	}
	yaw := physics.QuatFromAxisAngle(physics.V(0, 1, 0), a.yaw)
	impulse := physics.QuatRotate(yaw, physics.V(0, 20, -35))
	if err := a.model.CreateRagdoll(a.world, soldier.Position, yaw, soldier.Velocity, impulse); err != nil {
		return err
	}
	a.ragdoll = true
	a.thirdPerson = true
	return nil
}

func (a *app) reset() error {
	a.yaw = 0
	a.pitch = 0
	a.elapsed = 0
	a.ragdoll = false
	if err := a.model.RemoveRagdoll(); err != nil {
		return err
	}
	if err := a.scene.Reset(); err != nil {
		return err
	}
	return a.session.respawn()
}

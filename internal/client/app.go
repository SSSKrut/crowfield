package client

import (
	"cmp"
	"context"
	"fmt"
	"image/color"
	"log"
	"math"
	"slices"

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
	predictor   *predictor
	model       *animation.CharacterModel
	models      []*animation.CharacterModel
	modelFor    map[game.SoldierID]*animation.CharacterModel
	views       []remoteView
	alpha       float32
	camera      rl.Camera3D
	yaw         float32
	pitch       float32
	captured    bool
	debug       bool
	thirdPerson bool
	ragdoll     bool
	elapsed     float32
	demoCycle   int
	played      float32
	// The snapshot traffic of the last whole second.
	netWindow float32
	netBytes  int64
	netRate   float32
}

// Run connects to a server and plays: to the embedded one in solo play and
// when hosting, or to the one given by -connect. The client world holds the
// static map for prediction and cosmetic physics: ragdolls and props.
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

	predictor, err := newPredictor(world, tuning)
	if err != nil {
		return err
	}
	defer predictor.close()
	model, err := animation.LoadCharacterModel(characterModelPath)
	if err != nil {
		return err
	}
	defer model.Close()
	a := &app{
		settings: settings, world: world, scene: scene, spawn: description.Spawn, tuning: tuning,
		predictor: predictor, model: model, modelFor: make(map[game.SoldierID]*animation.CharacterModel),
		captured: settings.FrameLimit == 0, debug: settings.Debug, thirdPerson: true,
	}
	defer a.closeRemotes()
	// Everything is loaded before connecting: once connected, the client must
	// send a command every tick, and a stall puts its clock behind the server.
	for range animatedRemotes {
		model, err := animation.LoadCharacterModel(characterModelPath)
		if err != nil {
			return err
		}
		a.models = append(a.models, model)
	}

	conn, stop, err := open(settings, tuning)
	if err != nil {
		return err
	}
	defer stop()
	if conditions != (transport.NetworkConditions{}) {
		log.Printf("simulating network: %s", conditions)
		conn = transport.Simulate(conn, conditions)
	}
	a.session, err = connect(conn, settings.Name, tuning)
	if err != nil {
		_ = conn.Close("handshake failed")
		return err
	}
	defer a.session.close()
	if a.captured {
		rl.DisableCursor()
	}
	return a.run()
}

const characterModelPath = "assets/prototype/RobotExpressive.glb"

// open returns a connection to the server the settings ask for and a function
// that releases what open started.
func open(settings config.Client, tuning game.MovementTuning) (transport.Conn, func(), error) {
	if settings.Connect != "" {
		var pinned *transport.Fingerprint
		if settings.Fingerprint != "" {
			fingerprint, err := transport.ParseFingerprint(settings.Fingerprint)
			if err != nil {
				return nil, nil, err
			}
			pinned = &fingerprint
		}
		ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
		defer cancel()
		conn, err := transport.DialQUIC(ctx, settings.Connect, transport.ClientTLSConfig(pinned), transport.QUICOptions{})
		if err != nil {
			return nil, nil, fmt.Errorf("connect to %s: %w", settings.Connect, err)
		}
		if seen, ok := transport.PeerFingerprint(conn); ok && pinned == nil {
			log.Printf("connected to %s, certificate fingerprint %s (pass -fingerprint to pin it)", settings.Connect, seen)
		}
		return conn, func() {}, nil
	}
	local, err := startLocalServer(tuning, settings)
	if err != nil {
		return nil, nil, err
	}
	stop := func() {
		if err := local.stop(); err != nil {
			log.Printf("local server: %v", err)
		}
	}
	conn, err := local.dial()
	if err != nil {
		stop()
		return nil, nil, err
	}
	return conn, stop, nil
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
		a.played += deltaTime
		accumulator += deltaTime
		for accumulator >= game.TickDelta {
			command, err := a.session.sendCommand(a.command())
			if err != nil {
				return fmt.Errorf("disconnected: %w", err)
			}
			if err := a.predictor.predict(command); err != nil {
				return err
			}
			if err := a.world.Step(game.TickDelta); err != nil {
				return err
			}
			accumulator -= game.TickDelta
		}
		a.alpha = accumulator / game.TickDelta
		updated, err := a.session.poll()
		if err != nil {
			return fmt.Errorf("disconnected: %w", err)
		}
		if updated {
			if err := a.predictor.reconcile(a.session.player); err != nil {
				return err
			}
		}
		a.predictor.smooth(deltaTime)
		a.session.clock.advance(deltaTime)
		if a.netWindow += deltaTime; a.netWindow >= 1 {
			bytes := a.session.bytes.Load()
			a.netRate = float32(bytes-a.netBytes) / 1024 / a.netWindow
			a.netBytes, a.netWindow = bytes, 0
		}
		soldier := a.ownSoldier()
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
			feet = a.predictor.drawn(a.alpha)
			speed = horizontalSpeed(soldier.Velocity)
		}
		if err := a.model.Update(deltaTime, speed); err != nil {
			return err
		}
		a.updateRemotes(deltaTime, feet)
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
	log.Printf("prototype finished: tick=%d server_tick=%d feet=%+v grounded=%t ragdoll=%t active=%t animation=%s snapshots=%d snapshot_traffic=%.1fKB/s resyncs=%d corrections=%d soldiers=%d unresolved=%d",
		a.session.tick, a.session.serverTick, soldier.Position, soldier.Grounded, a.ragdoll, a.model.RagdollActive(),
		a.model.AnimationName(), a.session.received, float32(a.session.bytes.Load())/1024/max(a.played, 1e-3),
		a.session.resyncs, a.predictor.corrections, len(a.session.soldiers), a.session.unresolved)
	return nil
}

// ownSoldier is the predicted soldier, or nil before the first snapshot of it.
func (a *app) ownSoldier() *game.Soldier {
	if !a.predictor.started {
		return nil
	}
	return &a.predictor.soldier
}

// animatedRemotes is how many other soldiers get an animated model; farther
// ones are capsules. Every model is a separate copy skinned on the CPU, which
// does not scale to hundreds; shared models come with step 1.8.
const animatedRemotes = 16

type remoteView struct {
	id       game.SoldierID
	soldier  game.Soldier
	distance float32
}

// updateRemotes places every other soldier at the interpolation time and lends
// the models of a small pool to the nearest ones.
func (a *app) updateRemotes(deltaTime float32, eye physics.Vec3) {
	a.views = a.views[:0]
	for _, known := range a.session.soldiers {
		if known.soldier.ID == a.session.player.Soldier || known.remote.count == 0 {
			continue
		}
		known.remote.smooth(deltaTime)
		soldier := known.remote.at(a.session.clock.renderTick)
		a.views = append(a.views, remoteView{id: known.soldier.ID, soldier: soldier, distance: distance(soldier.Position, eye)})
	}
	slices.SortFunc(a.views, func(first, second remoteView) int { return cmp.Compare(first.distance, second.distance) })
	clear(a.modelFor)
	for i := range min(len(a.views), len(a.models)) {
		_ = a.models[i].Update(deltaTime, horizontalSpeed(a.views[i].soldier.Velocity))
		a.modelFor[a.views[i].id] = a.models[i]
	}
}

func (a *app) closeRemotes() {
	for _, model := range a.models {
		_ = model.Close()
	}
}

var teamColors = map[game.Team]color.RGBA{
	game.TeamNone: rl.Gray, game.TeamBlue: rl.NewColor(60, 110, 220, 255), game.TeamRed: rl.NewColor(210, 70, 60, 255),
}

func (a *app) drawCapsule(soldier game.Soldier, tint color.RGBA) {
	feet := render.Vector(soldier.Position.Add(physics.V(0, a.tuning.CapsuleRadius, 0)))
	head := render.Vector(soldier.Position.Add(physics.V(0, a.tuning.CapsuleRadius+2*a.tuning.CapsuleHalfHeight, 0)))
	rl.DrawCapsule(feet, head, a.tuning.CapsuleRadius, 4, 6, tint)
}

// facing turns the character model, which looks along +Z, towards where a
// soldier with this yaw moves: (sin yaw, 0, -cos yaw).
func facing(yaw float32) physics.Quat {
	return physics.QuatFromAxisAngle(physics.V(0, 1, 0), math.Pi-yaw)
}

func horizontalSpeed(velocity physics.Vec3) float32 {
	return float32(math.Hypot(float64(velocity.X), float64(velocity.Z)))
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
		a.model.Draw(feet, facing(a.yaw))
	}
	for _, view := range a.views {
		if model := a.modelFor[view.id]; model != nil {
			model.Draw(view.soldier.Position, facing(view.soldier.Yaw))
		} else {
			a.drawCapsule(view.soldier, teamColors[view.soldier.Team])
		}
		if a.debug {
			center := view.soldier.Position.Add(physics.V(0, a.tuning.CenterHeight(), 0))
			render.DrawCharacterCapsule(center, a.tuning.CapsuleHalfHeight, a.tuning.CapsuleRadius)
		}
	}
	if a.debug && spawned && !a.ragdoll {
		// The server's view of the own soldier, to compare with the prediction.
		if server := a.session.localSoldier(); server != nil {
			center := server.Position.Add(physics.V(0, a.tuning.CenterHeight(), 0))
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
	rl.DrawText(fmt.Sprintf("%d Hz | tick %d server %d buffered %d | RTT %d ms | snapshots %.1f KB/s | resyncs %d | corrections %d (last %.3f m) | soldiers %d",
		game.TickRate, a.session.tick, a.session.serverTick, a.session.player.BufferedCommands, stats.RTT.Milliseconds(),
		a.netRate, a.session.resyncs, a.predictor.corrections, a.predictor.lastError, len(a.session.soldiers)), 18, 96, 18, rl.White)
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
	soldier := a.ownSoldier()
	if a.ragdoll || soldier == nil {
		return nil
	}
	forward := physics.V(float32(math.Sin(float64(a.yaw))), 0, -float32(math.Cos(float64(a.yaw))))
	impulse := forward.Mul(35).Add(physics.V(0, 20, 0))
	if err := a.model.CreateRagdoll(a.world, a.predictor.drawn(a.alpha), facing(a.yaw), soldier.Velocity, impulse); err != nil {
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

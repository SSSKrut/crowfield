package client

import (
	"context"
	"fmt"
	"log"
	"math"
	"path/filepath"
	"sync/atomic"
	"time"

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
	asset       *animation.CharacterAsset
	self        *animation.Character
	soldiers    *soldiers
	fallen      bodies
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
	frames    frameStats
	// reconnect is the restoring of a lost connection to a remote server.
	reconnect *reconnecting
	// knockdowns counts the automatic knockdowns done.
	knockdowns int
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
	rl.SetTargetFPS(int32(settings.MaxFPS))

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
	// Everything is loaded before connecting: once connected, the client must
	// send a command every tick, and a stall puts its clock behind the server.
	asset, err := animation.LoadCharacterAsset(characterModelPath)
	if err != nil {
		return err
	}
	defer asset.Close()
	a := &app{
		settings: settings, world: world, scene: scene, spawn: description.Spawn, tuning: tuning,
		predictor: predictor, asset: asset, self: asset.NewCharacter(), soldiers: newSoldiers(asset),
		captured: settings.FrameLimit == 0, debug: settings.Debug, thirdPerson: true,
	}
	defer a.self.Close()
	defer a.fallen.close()

	conn, stop, err := open(settings, tuning)
	if err != nil {
		return err
	}
	defer stop()
	if conditions != (transport.NetworkConditions{}) {
		log.Printf("simulating network: %s", conditions)
		conn = transport.Simulate(conn, conditions)
	}
	a.session, err = connect(conn, settings.Name, tuning, [16]byte{})
	if err != nil {
		_ = conn.Close("handshake failed")
		return err
	}
	// The session may be replaced by a reconnection.
	defer func() { a.session.close() }()
	defer a.stopReconnecting()
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
		conn, err := dial(context.Background(), settings)
		return conn, func() {}, err
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

// dial joins the server of -connect. The certificate is checked before
// anything is sent: against -fingerprint, or against the fingerprint
// remembered on the first connection to that address.
func dial(ctx context.Context, settings config.Client) (transport.Conn, error) {
	address := withDefaultPort(settings.Connect)
	var given *transport.Fingerprint
	if settings.Fingerprint != "" {
		fingerprint, err := transport.ParseFingerprint(settings.Fingerprint)
		if err != nil {
			return nil, err
		}
		given = &fingerprint
	}
	var known *knownServers
	if settings.ConfigDir != "" {
		var err error
		if known, err = loadKnownServers(filepath.Join(settings.ConfigDir, "known_servers")); err != nil {
			return nil, err
		}
	}
	ctx, cancel := context.WithTimeout(ctx, connectTimeout)
	defer cancel()
	conn, err := transport.DialQUIC(ctx, address, transport.ClientTLSConfig(nil), transport.QUICOptions{})
	if err != nil {
		return nil, fmt.Errorf("connect to %s: %w", address, err)
	}
	seen, ok := transport.PeerFingerprint(conn)
	if !ok {
		_ = conn.Close("no certificate")
		return nil, fmt.Errorf("the server at %s showed no certificate", address)
	}
	message, err := checkServer(known, address, given, seen)
	if err != nil {
		_ = conn.Close("untrusted certificate")
		return nil, err
	}
	if message != "" {
		log.Print(message)
	}
	return conn, nil
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
		if rl.IsKeyPressed(rl.KeyF2) {
			a.settings.NetGraph = !a.settings.NetGraph
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
		knock := a.settings.Knockdowns > a.knockdowns && a.played >= 2+0.5*float32(a.knockdowns)
		if knock {
			a.knockdowns++
		}
		if rl.IsKeyPressed(rl.KeyL) || knock {
			if err := a.soldiers.knockDown(a.world, &a.fallen, a.eye()); err != nil {
				return err
			}
		}

		deltaTime := rl.GetFrameTime()
		a.frames.add(deltaTime)
		if deltaTime > 0.1 {
			deltaTime = 0.1
		}
		a.elapsed += deltaTime
		a.played += deltaTime
		accumulator += deltaTime
		if a.reconnect != nil {
			// The world waits while the connection comes back.
			accumulator = 0
			if err := a.pollReconnect(); err != nil {
				return err
			}
		}
		var lost error
		// Ticks last a little more or less than TickDelta while the session
		// brings its commands to the right lead.
		for a.reconnect == nil && accumulator >= a.session.tickDuration() {
			accumulator -= a.session.tickDuration()
			command, err := a.session.sendCommand(a.command())
			if err != nil {
				lost = err
				break
			}
			if err := a.predictor.predict(command); err != nil {
				return err
			}
			if err := a.world.Step(game.TickDelta); err != nil {
				return err
			}
		}
		a.alpha = accumulator / a.session.tickDuration()
		updated := false
		if lost == nil && a.reconnect == nil {
			updated, lost = a.session.poll()
		}
		if lost != nil {
			if err := a.lose(lost); err != nil {
				return err
			}
		}
		if updated {
			corrections := a.predictor.corrections
			if err := a.predictor.reconcile(a.session.player); err != nil {
				return err
			}
			if a.predictor.corrections != corrections {
				a.session.graph.correction(a.predictor.lastError)
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
		if err := a.self.Update(deltaTime, speed); err != nil {
			return err
		}
		if err := a.fallen.update(deltaTime); err != nil {
			return err
		}
		a.updateCamera(feet)
		a.soldiers.update(a.session, deltaTime, a.camera, float32(rl.GetScreenWidth())/float32(max(1, rl.GetScreenHeight())))
		cosPitch := float32(math.Cos(float64(a.pitch)))
		forward := physics.V(float32(math.Sin(float64(a.yaw)))*cosPitch, float32(math.Sin(float64(a.pitch))), -float32(math.Cos(float64(a.yaw)))*cosPitch)
		a.soldiers.aim(feet.Add(physics.V(0, a.tuning.EyeHeight, 0)), forward, a.tuning.CenterHeight())
		var aimed uint16
		var aimedUpdates int
		if known := a.soldiers.aimed; known != nil {
			aimed, aimedUpdates = uint16(known.soldier.ID), known.updates
		}
		a.session.graph.frame(deltaTime, a.session.conn.Stats().RTT, a.session.dilation, aimed, aimedUpdates)
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
	log.Printf("prototype finished: tick=%d server_tick=%d feet=%+v grounded=%t ragdoll=%t active=%t animation=%s snapshots=%d snapshot_traffic=%.1fKB/s resyncs=%d corrections=%d soldiers=%d unresolved=%d drawn=%d full_detail=%d bodies=%d ragdolls=%d peak_ragdolls=%d %s",
		a.session.tick, a.session.serverTick, soldier.Position, soldier.Grounded, a.ragdoll, a.self.RagdollActive(),
		a.self.AnimationName(), a.session.received, float32(a.session.bytes.Load())/1024/max(a.played, 1e-3),
		a.session.resyncs, a.predictor.corrections, len(a.session.soldiers), a.session.unresolved,
		a.soldiers.drawn, a.soldiers.full, len(a.fallen.all), a.fallen.ragdolls(), a.fallen.peak, &a.frames)
	return nil
}

// ownSoldier is the predicted soldier, or nil before the first snapshot of it.
func (a *app) ownSoldier() *game.Soldier {
	if !a.predictor.started {
		return nil
	}
	return &a.predictor.soldier
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
	if a.settings.Overview {
		// High above the south edge of the map: every soldier is in view.
		a.camera = rl.NewCamera3D(rl.NewVector3(0, 16, 21), rl.NewVector3(0, 0, -1), rl.NewVector3(0, 1, 0), a.settings.FieldOfView, rl.CameraPerspective)
		return
	}
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
	if spawned && (a.thirdPerson || a.ragdoll || a.settings.Overview) {
		team := game.TeamNone
		if own := a.session.localSoldier(); own != nil {
			team = own.Team
		}
		a.self.Draw(feet, facing(a.yaw), a.soldiers.tint(team), animation.DetailFull)
	}
	a.soldiers.draw(a.tuning, a.debug)
	bodies := a.fallen.draw(&a.soldiers.frustum)
	if a.debug && spawned && !a.ragdoll {
		// The server's view of the own soldier, to compare with the prediction.
		if server := a.session.localSoldier(); server != nil {
			center := server.Position.Add(physics.V(0, a.tuning.CenterHeight(), 0))
			render.DrawCharacterCapsule(center, a.tuning.CapsuleHalfHeight, a.tuning.CapsuleRadius)
		}
	}
	if a.debug {
		if parts, transforms, ok := a.self.RagdollDebug(); ok {
			a.scene.DrawRagdoll(parts, transforms)
		}
		rl.DrawGrid(30, 1)
		a.drawRay()
	}
	rl.EndMode3D()
	rl.DrawLine(int32(rl.GetScreenWidth()/2-7), int32(rl.GetScreenHeight()/2), int32(rl.GetScreenWidth()/2+7), int32(rl.GetScreenHeight()/2), rl.White)
	rl.DrawLine(int32(rl.GetScreenWidth()/2), int32(rl.GetScreenHeight()/2-7), int32(rl.GetScreenWidth()/2), int32(rl.GetScreenHeight()/2+7), rl.White)
	rl.DrawText("WASD move | Space jump | Shift sprint | K ragdoll | R respawn | L knock down nearest", 18, 18, 18, rl.White)
	rl.DrawText("F1 physics | F2 network | F3 camera | Esc cursor", 18, 44, 18, rl.White)
	rl.DrawText(fmt.Sprintf("FPS %d | XYZ %.2f %.2f %.2f | %s | drawn %d (full %d, capsules %d) | bodies %d (ragdolls %d)",
		rl.GetFPS(), feet.X, feet.Y, feet.Z, a.self.AnimationName(), a.soldiers.drawn, a.soldiers.full, a.soldiers.capsules,
		bodies, a.fallen.ragdolls()), 18, 70, 18, rl.White)
	stats := a.session.conn.Stats()
	rl.DrawText(fmt.Sprintf("%d Hz | tick %d server %d lead %d (clock %+.1f%%) | RTT %d ms | snapshots %.1f KB/s | jumps %d | corrections %d (last %.3f m) | soldiers %d",
		game.TickRate, a.session.tick, a.session.serverTick, a.session.player.InputLead, 100*a.session.dilation, stats.RTT.Milliseconds(),
		a.netRate, a.session.resyncs, a.predictor.corrections, a.predictor.lastError, len(a.session.soldiers)), 18, 96, 18, rl.White)
	if a.settings.NetGraph {
		a.session.graph.draw(a.session.resyncs)
	}
	if r := a.reconnect; r != nil {
		rl.DrawText(fmt.Sprintf("Connection lost: %v", r.reason), 18, 160, 22, rl.Orange)
		rl.DrawText(fmt.Sprintf("Reconnecting: attempt %d, %.0f s of %.0f", r.attempts.Load(), time.Since(r.since).Seconds(),
			reconnectWindow.Seconds()), 18, 188, 22, rl.Orange)
	}
	if !a.captured && a.settings.FrameLimit == 0 {
		rl.DrawText("Press Esc to capture the mouse", 18, 132, 22, rl.Yellow)
	}
	rl.EndDrawing()
}

// eye is where the camera is.
func (a *app) eye() physics.Vec3 {
	return physics.V(a.camera.Position.X, a.camera.Position.Y, a.camera.Position.Z)
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
	if err := a.self.CreateRagdoll(a.world, a.predictor.drawn(a.alpha), facing(a.yaw), soldier.Velocity, impulse); err != nil {
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
	if err := a.self.RemoveRagdoll(); err != nil {
		return err
	}
	if err := a.scene.Reset(); err != nil {
		return err
	}
	return a.session.respawn()
}

// frameStats measures frame times after the first second, which loads and
// connects.
type frameStats struct {
	skipped        float32
	frames         int
	total, longest float32
}

func (f *frameStats) add(deltaTime float32) {
	if f.skipped < 1 {
		f.skipped += deltaTime
		return
	}
	f.frames++
	f.total += deltaTime
	f.longest = max(f.longest, deltaTime)
}

func (f *frameStats) String() string {
	if f.frames == 0 {
		return "fps=0"
	}
	return fmt.Sprintf("fps=%.0f longest_frame=%.1fms", float32(f.frames)/f.total, f.longest*1000)
}

// reconnectWindow is how long the client tries to come back to a remote
// server, the time the server keeps the player's place.
const reconnectWindow = time.Minute

// reconnecting restores a lost connection to a remote server in the
// background, once a second, while the window keeps drawing.
type reconnecting struct {
	reason   error
	since    time.Time
	attempts atomic.Int32
	done     chan reconnected
	cancel   context.CancelFunc
}

type reconnected struct {
	session *session
	err     error
}

// lose handles a lost connection: playing solo or hosting it is the end, on
// a remote server the client comes back with its token.
func (a *app) lose(reason error) error {
	if a.settings.Connect == "" {
		return fmt.Errorf("disconnected: %w", reason)
	}
	log.Printf("connection lost: %v; reconnecting", reason)
	lost := a.session
	lost.abandon()
	ctx, cancel := context.WithTimeout(context.Background(), reconnectWindow)
	r := &reconnecting{reason: reason, since: time.Now(), done: make(chan reconnected, 1), cancel: cancel}
	a.reconnect = r
	go func() {
		defer cancel()
		for {
			r.attempts.Add(1)
			conn, err := dial(ctx, a.settings)
			if err == nil {
				var session *session
				if session, err = resume(lost, conn, a.tuning); err == nil {
					r.done <- reconnected{session: session}
					return
				}
				_ = conn.Close("rejoin failed")
			}
			select {
			case <-ctx.Done():
				r.done <- reconnected{err: fmt.Errorf("could not reconnect within %s: %w", reconnectWindow, err)}
				return
			case <-time.After(time.Second):
			}
		}
	}()
	return nil
}

// pollReconnect takes the new session once the connection is back.
func (a *app) pollReconnect() error {
	select {
	case result := <-a.reconnect.done:
		a.reconnect = nil
		if result.err != nil {
			return result.err
		}
		a.session = result.session
		a.predictor.reset()
		log.Printf("reconnected as player %d", a.session.welcome.Player)
	default:
	}
	return nil
}

func (a *app) stopReconnecting() {
	if a.reconnect == nil {
		return
	}
	a.reconnect.cancel()
	if result := <-a.reconnect.done; result.session != nil {
		result.session.close()
	}
}

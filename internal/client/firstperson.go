package client

import (
	"image/color"
	"math"

	"ravenfield/internal/game"
	"ravenfield/internal/physics"
	"ravenfield/internal/render"

	rl "github.com/gen2brain/raylib-go/raylib"
)

const (
	// viewModelFieldOfView draws the weapon in hand at a constant size, while
	// the world zooms when aiming.
	viewModelFieldOfView = 58
	// The weapon in hand comes to the sights in aimTime and leaves them in the
	// same; a shot's kick of the model fades with recoilTime.
	aimTime    = 0.15
	recoilTime = 0.06
	flashTime  = 0.05
)

var (
	gunMetal   = rl.NewColor(58, 60, 64, 255)
	gunDark    = rl.NewColor(32, 33, 36, 255)
	gunPolymer = rl.NewColor(74, 76, 66, 255)
	gunWood    = rl.NewColor(124, 82, 47, 255)
	sleeve     = rl.NewColor(86, 92, 102, 255)
)

// weaponModel is how a weapon looks in the player's hands. Its boxes are in a
// space where X points right, Y up and Z forward, with the line of its sights
// along +Z through the origin, so that aiming puts that line on the
// crosshair.
type weaponModel struct {
	// gun is the weapon itself, arms the hands that hold it in first person.
	gun    []render.Box
	arms   []render.Box
	muzzle physics.Vec3
	// hip and aim place the origin of the model in front of the eye: X
	// right, Y up, Z forward.
	hip, aim physics.Vec3
	// A shot throws the model back by kickBack metres and its muzzle up by
	// kickPitch radians.
	kickBack, kickPitch float32
	// scope replaces the model with the view through a scope when aiming.
	scope bool
}

// limb is a box from one point to another, for arms.
func limb(from, to physics.Vec3, half float32, tint color.RGBA, accent bool) render.Box {
	d := to.Sub(from)
	length := float32(math.Sqrt(float64(d.Dot(d))))
	return render.Box{
		Center: from.Add(to).Mul(0.5), Half: physics.V(half, half, length/2), Color: tint, Accent: accent,
		Pitch: float32(math.Atan2(float64(d.Y), math.Hypot(float64(d.X), float64(d.Z)))),
		Yaw:   float32(math.Atan2(float64(d.X), float64(d.Z))),
	}
}

// arms are the sleeves from the elbows to the hands; the hands, in the team
// colour, hold the weapon at the given points.
func arms(right, rightElbow, left, leftElbow physics.Vec3) []render.Box {
	hand := physics.V(0.032, 0.036, 0.042)
	return []render.Box{
		limb(rightElbow, right, 0.038, sleeve, false),
		limb(leftElbow, left, 0.036, sleeve, false),
		{Center: right, Half: hand, Accent: true},
		{Center: left, Half: hand, Accent: true},
	}
}

func weaponModels() [game.WeaponKinds]*weaponModel {
	v := physics.V
	var models [game.WeaponKinds]*weaponModel
	models[game.WeaponAssaultRifle] = &weaponModel{
		gun: []render.Box{
			{Center: v(0, -0.055, 0.06), Half: v(0.024, 0.034, 0.17), Color: gunMetal},
			{Center: v(0, -0.019, 0.07), Half: v(0.01, 0.004, 0.15), Color: gunDark},
			{Center: v(0, -0.05, 0.31), Half: v(0.028, 0.03, 0.09), Color: gunPolymer},
			{Center: v(0, -0.045, 0.47), Half: v(0.009, 0.009, 0.08), Color: gunDark},
			{Center: v(0, -0.045, 0.57), Half: v(0.013, 0.013, 0.025), Color: gunDark},
			{Center: v(0, -0.009, 0.37), Half: v(0.0018, 0.009, 0.003), Color: gunDark},
			{Center: v(0, -0.026, 0.37), Half: v(0.012, 0.008, 0.006), Color: gunDark},
			{Center: v(-0.0065, -0.007, -0.045), Half: v(0.002, 0.009, 0.003), Color: gunDark},
			{Center: v(0.0065, -0.007, -0.045), Half: v(0.002, 0.009, 0.003), Color: gunDark},
			{Center: v(0, -0.16, 0.12), Half: v(0.015, 0.07, 0.028), Pitch: 0.3, Color: gunDark},
			{Center: v(0, -0.125, -0.06), Half: v(0.015, 0.05, 0.02), Pitch: -0.35, Color: gunPolymer},
			{Center: v(0, -0.07, -0.24), Half: v(0.02, 0.04, 0.09), Color: gunPolymer},
		},
		arms:   arms(v(0.004, -0.11, -0.05), v(0.11, -0.3, -0.42), v(-0.006, -0.085, 0.3), v(-0.17, -0.3, 0.02)),
		muzzle: v(0, -0.045, 0.6), hip: v(0.15, -0.16, 0.26), aim: v(0, 0, 0.23), kickBack: 0.035, kickPitch: 0.05,
	}
	models[game.WeaponRifle] = &weaponModel{
		gun: []render.Box{
			{Center: v(0, -0.065, 0), Half: v(0.022, 0.035, 0.3), Color: gunWood},
			{Center: v(0, -0.04, 0.08), Half: v(0.018, 0.018, 0.13), Color: gunMetal},
			{Center: v(0, -0.04, 0.45), Half: v(0.01, 0.01, 0.22), Color: gunDark},
			{Center: v(0, 0, 0.05), Half: v(0.018, 0.018, 0.12), Color: gunDark},
			{Center: v(0, 0, 0.19), Half: v(0.026, 0.026, 0.03), Color: gunDark},
			{Center: v(0, 0, -0.085), Half: v(0.022, 0.022, 0.025), Color: gunDark},
			{Center: v(0, -0.024, 0), Half: v(0.008, 0.008, 0.01), Color: gunMetal},
			{Center: v(0, -0.024, 0.11), Half: v(0.008, 0.008, 0.01), Color: gunMetal},
			{Center: v(0, -0.11, 0.06), Half: v(0.014, 0.025, 0.035), Color: gunDark},
			{Center: v(0, -0.11, -0.15), Half: v(0.018, 0.045, 0.06), Pitch: -0.3, Color: gunWood},
			{Center: v(0, -0.09, -0.32), Half: v(0.02, 0.05, 0.07), Color: gunWood},
		},
		arms:   arms(v(0.004, -0.11, -0.13), v(0.12, -0.3, -0.48), v(-0.006, -0.095, 0.24), v(-0.17, -0.3, -0.02)),
		muzzle: v(0, -0.04, 0.67), hip: v(0.15, -0.15, 0.24), aim: v(0, 0, 0.16), kickBack: 0.07, kickPitch: 0.12,
		scope: true,
	}
	models[game.WeaponPistol] = &weaponModel{
		gun: []render.Box{
			{Center: v(0, -0.012, 0.03), Half: v(0.013, 0.016, 0.09), Color: gunMetal},
			{Center: v(0, -0.036, 0.025), Half: v(0.012, 0.009, 0.08), Color: gunDark},
			{Center: v(0, -0.085, -0.04), Half: v(0.013, 0.048, 0.022), Pitch: -0.25, Color: gunDark},
			{Center: v(0, -0.055, 0.03), Half: v(0.003, 0.012, 0.02), Color: gunDark},
			{Center: v(0, 0.006, 0.11), Half: v(0.002, 0.003, 0.003), Color: gunDark},
			{Center: v(-0.006, 0.006, -0.05), Half: v(0.003, 0.003, 0.003), Color: gunDark},
			{Center: v(0.006, 0.006, -0.05), Half: v(0.003, 0.003, 0.003), Color: gunDark},
		},
		arms:   arms(v(0.006, -0.08, -0.05), v(0.1, -0.24, -0.38), v(-0.024, -0.088, -0.035), v(-0.15, -0.24, -0.36)),
		muzzle: v(0, -0.012, 0.125), hip: v(0.1, -0.095, 0.4), aim: v(0, -0.003, 0.36), kickBack: 0.03, kickPitch: 0.18,
	}
	return models
}

// viewModel is the weapon in the player's hands as the player sees it. Its
// motion is cosmetic: it comes from the predicted arsenal and from how the
// player moves and looks, never back.
type viewModel struct {
	shapes [game.WeaponKinds]*weaponModel
	models [game.WeaponKinds]*render.BoxModel
	// held are the weapons alone, as other soldiers carry them.
	held [game.WeaponKinds]*render.BoxModel
	// aim goes from 0 at the hip to 1 down the sights.
	aim float32
	// The walk sways the model: bob is its phase, stride its strength.
	bob, stride float32
	sway        [2]float32
	sprint      float32
	recoil      float32
	flash       float32
	flashTurn   float32
	// transform and muzzle are where the model was placed for this frame.
	transform rl.Matrix
	muzzle    physics.Vec3
}

func newViewModel(shader rl.Shader) *viewModel {
	v := &viewModel{shapes: weaponModels()}
	for kind, shape := range v.shapes {
		if shape != nil {
			v.models[kind] = render.NewBoxModel(append(append([]render.Box(nil), shape.gun...), shape.arms...), shader)
			v.held[kind] = render.NewBoxModel(shape.gun, shader)
		}
	}
	return v
}

func (v *viewModel) close() {
	for kind, model := range v.models {
		if model != nil {
			model.Close()
			v.held[kind].Close()
		}
	}
}

const (
	// A soldier holds its weapon at its right side, at the height of the
	// chest and somewhat forward, along its aim; a little larger than in
	// first person, to suit the chunky robot.
	heldScale = 1.2
)

var heldOffset = physics.V(0.26, 1.0, 0.3)

// heldTransform places the weapon a soldier carries.
func heldTransform(soldier *game.Soldier) rl.Matrix {
	right := physics.V(float32(math.Cos(float64(soldier.Yaw))), 0, float32(math.Sin(float64(soldier.Yaw))))
	forward := game.ViewDirection(soldier.Yaw, 0)
	at := soldier.Position.Add(right.Mul(heldOffset.X)).Add(physics.V(0, heldOffset.Y, 0)).Add(forward.Mul(heldOffset.Z))
	transform := rl.MatrixMultiply(rl.MatrixScale(heldScale, heldScale, heldScale), rl.MatrixRotateX(soldier.Pitch))
	transform = rl.MatrixMultiply(transform, rl.MatrixRotateY(-soldier.Yaw))
	return rl.MatrixMultiply(transform, rl.MatrixTranslate(at.X, at.Y, at.Z))
}

// drawHeld draws the weapon a soldier carries, if any.
func (v *viewModel) drawHeld(soldier *game.Soldier, tint color.RGBA) {
	if kind := soldier.Arsenal.Weapon(); v.shapeOf(kind) != nil {
		v.held[kind].Draw(heldTransform(soldier), tint)
	}
}

// heldMuzzle is where the weapon a soldier carries fires from.
func (v *viewModel) heldMuzzle(soldier *game.Soldier) (physics.Vec3, bool) {
	shape := v.shapeOf(soldier.Arsenal.Weapon())
	if shape == nil {
		return physics.Vec3{}, false
	}
	point := rl.Vector3Transform(render.Vector(render.Forward(shape.muzzle)), heldTransform(soldier))
	return physics.V(point.X, point.Y, point.Z), true
}

// fired starts the kick of the model and the muzzle flash.
func (v *viewModel) fired(turn float32) {
	v.recoil, v.flash, v.flashTurn = 1, flashTime, turn
}

// update moves the model for a frame. speed is the soldier's share of the
// sprint speed; look is how far the view turned this frame, in radians.
func (v *viewModel) update(deltaTime float32, aiming, sprinting, grounded bool, speed float32, look [2]float32) {
	aimRate := deltaTime / aimTime
	if aiming {
		v.aim = min(1, v.aim+aimRate)
	} else {
		v.aim = max(0, v.aim-aimRate)
	}
	stride := float32(0)
	if grounded {
		stride = min(1, speed)
	}
	v.stride += (stride - v.stride) * min(1, deltaTime*8)
	v.bob += deltaTime * (5 + 6*speed)
	sprint := float32(0)
	if sprinting {
		sprint = 1
	}
	v.sprint += (sprint - v.sprint) * min(1, deltaTime*10)
	for i := range v.sway {
		target := max(-0.04, min(0.04, -look[i]*0.6))
		v.sway[i] += (target - v.sway[i]) * min(1, deltaTime*12)
	}
	v.recoil *= float32(math.Exp(-float64(deltaTime) / recoilTime))
	v.flash = max(0, v.flash-deltaTime)
}

// place puts the model of the weapon in hand in front of the eye of camera,
// lowered by the action of the arsenal: progress runs from 0 to 1 through an
// equip or a reload.
func (v *viewModel) place(camera rl.Camera3D, kind game.WeaponKind, action game.WeaponAction, progress float32) bool {
	shape := v.shapeOf(kind)
	if shape == nil {
		return false
	}
	calm := 1 - 0.85*v.aim
	offset := shape.hip.Add(shape.aim.Sub(shape.hip).Mul(v.aim))
	offset = offset.Add(physics.V(
		0.012*v.stride*float32(math.Sin(float64(v.bob)))*calm+v.sway[0]*calm,
		-0.01*v.stride*float32(math.Abs(math.Cos(float64(v.bob))))*calm+v.sway[1]*calm,
		-shape.kickBack*v.recoil*(1-0.5*v.aim),
	))
	offset = offset.Add(physics.V(-0.03, -0.06, -0.06).Mul(v.sprint))
	pitch := shape.kickPitch*v.recoil*calm - 0.45*v.sprint
	// Sprinting carries the weapon across the body, muzzle down and left.
	yaw := -0.55 * v.sprint
	roll := float32(0)
	switch action {
	case game.WeaponEquipping:
		lower := (1 - progress) * (1 - progress)
		offset = offset.Add(physics.V(0, -0.25*lower, 0))
		pitch -= 0.7 * lower
	case game.WeaponReloading:
		dip := float32(math.Sin(math.Pi * float64(progress)))
		offset = offset.Add(physics.V(0, -0.07*dip, -0.03*dip))
		pitch -= 0.25 * dip
		roll += 0.6 * dip
	}
	local := rl.MatrixMultiply(rl.MatrixMultiply(rl.MatrixRotateZ(roll), rl.MatrixRotateX(pitch)), rl.MatrixRotateY(-yaw))
	local = rl.MatrixMultiply(local, rl.MatrixTranslate(offset.X, offset.Y, -offset.Z))
	v.transform = rl.MatrixMultiply(local, cameraMatrix(camera))
	muzzle := rl.Vector3Transform(render.Vector(render.Forward(shape.muzzle)), v.transform)
	v.muzzle = physics.V(muzzle.X, muzzle.Y, muzzle.Z)
	return true
}

func (v *viewModel) shapeOf(kind game.WeaponKind) *weaponModel {
	if kind >= game.WeaponKinds {
		return nil
	}
	return v.shapes[kind]
}

// scoped reports whether the player looks through a scope instead of at the
// weapon.
func (v *viewModel) scoped(kind game.WeaponKind) bool {
	shape := v.shapeOf(kind)
	return shape != nil && shape.scope && v.aim > 0.95
}

// draw draws the placed model and its muzzle flash, in a pass of their own
// over the world: the world's depth is cleared first, so that a weapon held
// against a wall does not sink into it.
func (v *viewModel) draw(camera rl.Camera3D, kind game.WeaponKind, tint color.RGBA) {
	if v.shapeOf(kind) == nil || v.scoped(kind) {
		return
	}
	rl.DrawRenderBatchActive()
	rl.ColorMask(false, false, false, false)
	rl.ClearScreenBuffers()
	rl.ColorMask(true, true, true, true)
	camera.Fovy = viewModelFieldOfView
	rl.BeginMode3D(camera)
	v.models[kind].Draw(v.transform, tint)
	if v.flash > 0 {
		forward := rl.Vector3Normalize(rl.Vector3Subtract(camera.Target, camera.Position))
		size := v.flash / flashTime
		muzzle := render.Vector(v.muzzle)
		rl.BeginBlendMode(rl.BlendAdditive)
		rl.DrawSphere(muzzle, 0.028*size, rl.NewColor(255, 214, 120, 255))
		tip := rl.Vector3Add(muzzle, rl.Vector3Scale(forward, 0.09+0.05*v.flashTurn))
		rl.DrawCylinderEx(muzzle, tip, 0.03*size, 0, 6, rl.NewColor(255, 170, 60, 220))
		rl.EndBlendMode()
	}
	rl.EndMode3D()
}

// muzzleInWorld is where the muzzle of the model appears in the world drawn
// by camera: the model is drawn with its own field of view, so the point on
// the screen is carried back into the world at the same distance from the eye.
func (v *viewModel) muzzleInWorld(camera rl.Camera3D) physics.Vec3 {
	own := camera
	own.Fovy = viewModelFieldOfView
	muzzle := render.Vector(v.muzzle)
	screen := rl.GetWorldToScreen(muzzle, own)
	ray := rl.GetScreenToWorldRay(screen, camera)
	reach := rl.Vector3Distance(muzzle, camera.Position)
	point := rl.Vector3Add(ray.Position, rl.Vector3Scale(ray.Direction, reach))
	return physics.V(point.X, point.Y, point.Z)
}

// cameraMatrix turns the space of the eye — X right, Y up, -Z forward — into
// the world.
func cameraMatrix(camera rl.Camera3D) rl.Matrix {
	forward := rl.Vector3Normalize(rl.Vector3Subtract(camera.Target, camera.Position))
	right := rl.Vector3Normalize(rl.Vector3CrossProduct(forward, camera.Up))
	up := rl.Vector3CrossProduct(right, forward)
	return rl.Matrix{
		M0: right.X, M1: right.Y, M2: right.Z,
		M4: up.X, M5: up.Y, M6: up.Z,
		M8: -forward.X, M9: -forward.Y, M10: -forward.Z,
		M12: camera.Position.X, M13: camera.Position.Y, M14: camera.Position.Z, M15: 1,
	}
}

package animation

import (
	"math"

	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

// A hit that does not kill makes the character flinch (ARCHITECTURE.md,
// 10.2): a few bones of the struck part turn away from the shot and spring
// back, on top of the animation, with no physics. The spring rings at
// flinchFrequency, damped by flinchDamping; a hit gives it flinchKick
// radians per second, and the turn never exceeds maxFlinch.
const (
	flinchFrequency = 3
	flinchDamping   = 0.45
	flinchKick      = 7
	maxFlinch       = 0.35
	// A flinch smaller than this, turning slower than its speed, is over.
	flinchRest, flinchRestSpeed = 0.002, 0.02
	flinchStep                  = 1.0 / 120
)

// flinchChain is the bones a hit on a part turns, each by a share of the
// spring's angle. The body bends at the waist and the neck; a limb swings
// from its shoulder or hip.
type flinchChain struct {
	bones   [2]string
	weights [2]float32
	// limb chains hang below their pivot: they swing against the shot's
	// turn of the body.
	limb bool
}

var flinchChains = [ragdollParts]flinchChain{
	RagdollHips:          {bones: [2]string{"Abdomen", "Torso"}, weights: [2]float32{0.5, 0.5}},
	RagdollTorso:         {bones: [2]string{"Abdomen", "Torso"}, weights: [2]float32{0.5, 0.5}},
	RagdollHead:          {bones: [2]string{"Neck", "Head"}, weights: [2]float32{0.5, 0.6}},
	RagdollUpperArmLeft:  {bones: [2]string{"UpperArm.L", "LowerArm.L"}, weights: [2]float32{1, 0.5}, limb: true},
	RagdollLowerArmLeft:  {bones: [2]string{"UpperArm.L", "LowerArm.L"}, weights: [2]float32{0.6, 1}, limb: true},
	RagdollUpperArmRight: {bones: [2]string{"UpperArm.R", "LowerArm.R"}, weights: [2]float32{1, 0.5}, limb: true},
	RagdollLowerArmRight: {bones: [2]string{"UpperArm.R", "LowerArm.R"}, weights: [2]float32{0.6, 1}, limb: true},
	RagdollUpperLegLeft:  {bones: [2]string{"UpperLeg.L", "LowerLeg.L"}, weights: [2]float32{0.7, 0.3}, limb: true},
	RagdollLowerLegLeft:  {bones: [2]string{"UpperLeg.L", "LowerLeg.L"}, weights: [2]float32{0.5, 0.6}, limb: true},
	RagdollFootLeft:      {bones: [2]string{"UpperLeg.L", "LowerLeg.L"}, weights: [2]float32{0.5, 0.6}, limb: true},
	RagdollUpperLegRight: {bones: [2]string{"UpperLeg.R", "LowerLeg.R"}, weights: [2]float32{0.7, 0.3}, limb: true},
	RagdollLowerLegRight: {bones: [2]string{"UpperLeg.R", "LowerLeg.R"}, weights: [2]float32{0.5, 0.6}, limb: true},
	RagdollFootRight:     {bones: [2]string{"UpperLeg.R", "LowerLeg.R"}, weights: [2]float32{0.5, 0.6}, limb: true},
}

// flinch is the spring of a character that was hit and is not over it yet.
type flinch struct {
	active  bool
	bones   [2]int
	weights [2]float32
	// axis is what the bones turn about, in the space of the model.
	axis         rl.Vector3
	angle, speed float32
}

// Flinch makes a standing character flinch from a hit on a ragdoll part by a
// shot travelling along direction; yaw turns the model as it is drawn. A
// hit while still flinching adds to the swing.
func (c *Character) Flinch(part int, direction physics.Vec3, yaw physics.Quat) {
	if c.ragdoll != nil || part < 0 || part >= ragdollParts {
		return
	}
	chain := flinchChains[part]
	for i, name := range chain.bones {
		c.flinch.bones[i] = c.asset.bones[name]
		c.flinch.weights[i] = chain.weights[i]
	}
	// The shot in the model's space, flat. Turning about up × shot carries
	// what is above the pivot along the shot, and what hangs below it back.
	shot := physics.QuatRotate(physics.QuatConjugate(yaw), direction)
	shot.Y = 0
	if length := vectorLength(shot); length > 1e-6 {
		shot = shot.Mul(1 / length)
	} else {
		shot = physics.V(0, 0, 1)
	}
	axis := rl.NewVector3(shot.Z, 0, -shot.X)
	if chain.limb {
		axis = rl.Vector3Negate(axis)
	}
	if !c.flinch.active {
		c.flinch.angle, c.flinch.speed = 0, 0
	}
	c.flinch.axis, c.flinch.active = axis, true
	c.flinch.speed += flinchKick
}

// Flinching reports whether the character is still flinching.
func (c *Character) Flinching() bool {
	return c.flinch.active
}

// updateFlinch advances the spring in small steps.
func (c *Character) updateFlinch(deltaTime float32) {
	f := &c.flinch
	if !f.active {
		return
	}
	omega := float32(2 * math.Pi * flinchFrequency)
	for remaining := deltaTime; remaining > 0; remaining -= flinchStep {
		step := min(remaining, flinchStep)
		f.speed += (-omega*omega*f.angle - 2*flinchDamping*omega*f.speed) * step
		f.angle = max(-maxFlinch, min(maxFlinch, f.angle+f.speed*step))
	}
	if math.Abs(float64(f.angle)) < flinchRest && math.Abs(float64(f.speed)) < flinchRestSpeed {
		f.active = false
	}
}

// applyFlinch turns the bones of the flinch in the pose last computed by
// pose, carrying their children along, into the character's own matrices.
func (c *Character) applyFlinch() {
	a := c.asset
	c.ownPose()
	pose := a.model.GetCurrentPose()
	bones := a.model.Skeleton.GetBones()
	for _, i := range a.order {
		delta := rl.MatrixIdentity()
		if parent := bones[i].Parent; parent >= 0 {
			delta = a.deltas[parent]
		}
		for k, bone := range c.flinch.bones {
			if bone != i {
				continue
			}
			// Turn about where the bone now is, after its parents turned.
			pivot := rl.Vector3Transform(pose[i].Translation, delta)
			turn := rl.MatrixMultiply(rl.MatrixTranslate(-pivot.X, -pivot.Y, -pivot.Z), rl.MatrixRotate(c.flinch.axis, c.flinch.angle*c.flinch.weights[k]))
			delta = rl.MatrixMultiply(delta, rl.MatrixMultiply(turn, rl.MatrixTranslate(pivot.X, pivot.Y, pivot.Z)))
		}
		a.deltas[i] = delta
		c.matrices[i] = rl.MatrixMultiply(a.inverseBind[i], rl.MatrixMultiply(matrixFromRaylib(pose[i]), delta))
	}
}

// boneOrder lists the bones of a skeleton with every parent before its
// children.
func boneOrder(bones []rl.BoneInfo) []int {
	order := make([]int, 0, len(bones))
	placed := make([]bool, len(bones))
	for len(order) < len(bones) {
		progress := false
		for i, bone := range bones {
			if !placed[i] && (bone.Parent < 0 || placed[bone.Parent]) {
				placed[i], progress = true, true
				order = append(order, i)
			}
		}
		if !progress {
			// A cycle: keep what is left in its order.
			for i := range bones {
				if !placed[i] {
					placed[i] = true
					order = append(order, i)
				}
			}
		}
	}
	return order
}

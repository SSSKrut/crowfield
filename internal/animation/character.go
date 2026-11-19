package animation

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"image/color"
	"math"
	"unsafe"

	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

const (
	// blendTime is how long a change of clip takes in full detail.
	blendTime = 0.2
	// A soldier walks from walkSpeed and runs from runSpeed, in m/s.
	walkSpeed = 0.15
	runSpeed  = 6
)

// Detail is how carefully a soldier's pose is computed for a frame.
type Detail int

const (
	// DetailFull samples the clip between keyframes and blends a change of
	// clip, for the few soldiers near the camera.
	DetailFull Detail = iota
	// DetailCached shows the nearest keyframe computed at load and changes
	// clips at once: nothing is computed per soldier.
	DetailCached
)

// Character is one soldier drawn with a shared CharacterAsset. It holds only
// its own state: the clip, the time in it, a fading previous clip, and once it
// falls, its ragdoll and then its frozen pose.
type Character struct {
	asset          *CharacterAsset
	clip, from     Clip
	time, fromTime float32
	blend          float32

	// matrices are the character's own bone matrices, in C memory, while it
	// is a ragdoll or a frozen body; nil while it is animated.
	matrices []rl.Matrix
	ragdoll  *ragdollState
	flinch   flinch
}

func (a *CharacterAsset) NewCharacter() *Character {
	return &Character{asset: a, blend: 1}
}

// Copy returns a character in the same animation state, standing.
func (c *Character) Copy() *Character {
	return &Character{asset: c.asset, clip: c.clip, from: c.from, time: c.time, fromTime: c.fromTime, blend: c.blend}
}

// Close frees the character's own pose and ragdoll.
func (c *Character) Close() error {
	return c.RemoveRagdoll()
}

func (c *Character) Clip() Clip {
	return c.clip
}

func (c *Character) AnimationName() string {
	return c.clip.String()
}

// Update advances the animation of a soldier moving at speed, or the ragdoll
// of a fallen one.
func (c *Character) Update(deltaTime, speed float32) error {
	if c.ragdoll != nil {
		return c.updateRagdoll(deltaTime)
	}
	c.updateFlinch(deltaTime)
	next := ClipIdle
	if speed >= runSpeed {
		next = ClipRunning
	} else if speed >= walkSpeed {
		next = ClipWalking
	}
	if next != c.clip {
		c.from, c.fromTime, c.blend = c.clip, c.time, 0
		if c.clip != ClipIdle && next != ClipIdle {
			// Walking and running are the same gait: the phase carries over.
			c.time *= c.asset.period(next) / c.asset.period(c.clip)
		} else {
			c.time = 0
		}
		c.clip = next
	}
	c.time = wrap(c.time+deltaTime, c.asset.period(c.clip))
	c.fromTime = wrap(c.fromTime+deltaTime, c.asset.period(c.from))
	c.blend = min(1, c.blend+deltaTime/blendTime)
	return nil
}

// Draw draws the soldier standing at position, or its body where it fell.
func (c *Character) Draw(position physics.Vec3, yaw physics.Quat, tint color.RGBA, detail Detail) {
	a := c.asset
	switch {
	case c.ragdoll != nil:
		a.draw(&c.matrices[0], c.ragdollRoot(), c.ragdollYaw(), tint)
	case c.flinch.active:
		c.pose()
		c.applyFlinch()
		a.draw(&c.matrices[0], position, yaw, tint)
	case detail == DetailFull:
		c.pose()
		a.draw(a.model.BoneMatrices, position, yaw, tint)
	default:
		a.draw(a.cachedPose(c.clip, c.time), position, yaw, tint)
	}
}

// pose computes the exact pose of the character into the shared model: its
// current pose and bone matrices.
func (c *Character) pose() {
	a := c.asset
	current := &a.clips[c.clip]
	if c.blend >= 1 {
		rl.UpdateModelAnimation(a.model, current.animation, c.time*keyframeRate)
		return
	}
	from := &a.clips[c.from]
	rl.UpdateModelAnimationEx(a.model, from.animation, c.fromTime*keyframeRate, current.animation, c.time*keyframeRate, c.blend)
}

// bone returns a bone of the pose last computed by pose.
func (c *Character) bone(name string) (int, rl.Transform, error) {
	index, ok := c.asset.bones[name]
	if !ok {
		return 0, rl.Transform{}, fmt.Errorf("bone %q not found", name)
	}
	return index, c.asset.model.GetCurrentPose()[index], nil
}

// ownPose gives the character its own bone matrices.
func (c *Character) ownPose() {
	if c.matrices == nil {
		c.matrices = cArray[rl.Matrix](int(c.asset.model.Skeleton.BoneCount))
	}
}

func (c *Character) freePose() {
	if c.matrices != nil {
		C.free(unsafe.Pointer(&c.matrices[0]))
		c.matrices = nil
	}
}

// period is the length of a clip in seconds.
func (a *CharacterAsset) period(c Clip) float32 {
	return float32(a.clips[c].frames) / keyframeRate
}

func wrap(time, period float32) float32 {
	return float32(math.Mod(float64(time), float64(period)))
}

func boneName(bone rl.BoneInfo) string {
	bytes := make([]byte, 0, len(bone.Name))
	for _, value := range bone.Name {
		if value == 0 {
			break
		}
		bytes = append(bytes, byte(value))
	}
	return string(bytes)
}

func vector(value physics.Vec3) rl.Vector3 {
	return rl.NewVector3(value.X, value.Y, value.Z)
}

func quaternion(value physics.Quat) rl.Quaternion {
	return rl.NewQuaternion(value.X, value.Y, value.Z, value.W)
}

func yawAngle(value physics.Quat) float32 {
	return float32(2 * math.Atan2(float64(value.Y), float64(value.W)) * 180 / math.Pi)
}

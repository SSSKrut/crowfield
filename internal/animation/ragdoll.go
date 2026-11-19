package animation

import (
	"fmt"
	"math"

	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

const (
	// A ragdoll freezes once its bodies sleep, or after ragdollTime unless it
	// is still flying, and after maxRagdollTime in any case. A frozen body
	// keeps its pose and costs no physics.
	ragdollTime    = 4
	maxRagdollTime = 8
	flyingSpeed    = 1
)

// ragdollState is a fallen character: its physics while it falls, and what
// turns the bodies back into a pose of the skeleton.
type ragdollState struct {
	body    *physics.Ragdoll
	age     float32
	hips    physics.Vec3
	base    []rl.Transform
	root    physics.Vec3
	yaw     physics.Quat
	parts   []physics.RagdollPart
	bones   []string
	offsets []physics.Transform

	partAtBone []int
	oldWorld   []rl.Matrix
	newWorld   []rl.Matrix
	propagated []bool
	pose       []rl.Transform
}

// CreateRagdoll knocks the character down from its current pose, standing at
// root and turned by yaw. It falls with the given velocity and an impulse in
// the hips.
func (c *Character) CreateRagdoll(world *physics.World, root physics.Vec3, yaw physics.Quat, velocity, impulse physics.Vec3) error {
	if c.ragdoll != nil {
		return nil
	}
	if c.matrices == nil {
		c.pose()
	}
	builder := ragdollBuilder{character: c, root: root, yaw: yaw}
	parts, partBones, err := builder.build()
	if err != nil {
		return err
	}
	offsets := make([]physics.Transform, len(parts))
	for i, name := range partBones {
		_, pose, err := c.bone(name)
		if err != nil {
			return err
		}
		boneTransform := physics.Transform{
			Position: builder.worldPosition(pose.Translation),
			Rotation: builder.worldRotation(pose.Rotation),
		}
		offsets[i] = physics.ComposeTransform(physics.InverseTransform(parts[i].Transform), boneTransform)
	}
	body, err := world.CreateRagdoll(parts, velocity, impulse)
	if err != nil {
		return err
	}
	count := int(c.asset.model.Skeleton.BoneCount)
	state := &ragdollState{
		body: body, base: append([]rl.Transform(nil), c.asset.model.GetCurrentPose()...), root: root, yaw: yaw,
		parts: parts, bones: partBones, offsets: offsets, hips: parts[0].Transform.Position,
		partAtBone: make([]int, count), oldWorld: make([]rl.Matrix, count), newWorld: make([]rl.Matrix, count),
		propagated: make([]bool, count), pose: make([]rl.Transform, count),
	}
	for i := range state.partAtBone {
		state.partAtBone[i] = -1
	}
	for i, name := range partBones {
		state.partAtBone[c.asset.bones[name]] = i
	}
	c.ragdoll = state
	c.ownPose()
	return c.updateRagdoll(0)
}

// RemoveRagdoll stands the character up again: it is animated as before.
func (c *Character) RemoveRagdoll() error {
	var err error
	if c.ragdoll != nil {
		err = c.ragdoll.body.Close()
		c.ragdoll = nil
	}
	c.freePose()
	return err
}

// Freeze ends the physics of a fallen character; it keeps its last pose.
func (c *Character) Freeze() error {
	if c.ragdoll == nil || c.ragdoll.body == nil {
		return nil
	}
	err := c.ragdoll.body.Close()
	c.ragdoll.body = nil
	return err
}

// Fallen reports whether the character is a ragdoll or a frozen body.
func (c *Character) Fallen() bool {
	return c.ragdoll != nil
}

// RagdollActive reports whether the character's ragdoll is simulated now.
func (c *Character) RagdollActive() bool {
	return c.ragdoll != nil && c.ragdoll.body != nil
}

// FallenAt is where a fallen character lies.
func (c *Character) FallenAt() physics.Vec3 {
	if c.ragdoll == nil {
		return physics.Vec3{}
	}
	return c.ragdoll.hips
}

func (c *Character) ragdollRoot() physics.Vec3 {
	return c.ragdoll.root
}

func (c *Character) ragdollYaw() physics.Quat {
	return c.ragdoll.yaw
}

func (c *Character) updateRagdoll(deltaTime float32) error {
	r := c.ragdoll
	if r.body == nil {
		return nil
	}
	transforms, err := r.body.Transforms()
	if err != nil {
		return err
	}
	if err := c.applyRagdoll(transforms); err != nil {
		return err
	}
	r.age += deltaTime
	speed := float32(0)
	if deltaTime > 0 {
		speed = vectorLength(transforms[0].Position.Sub(r.hips)) / deltaTime
	}
	r.hips = transforms[0].Position
	active, err := r.body.IsActive()
	if err != nil {
		return err
	}
	if !active || (r.age >= ragdollTime && speed < flyingSpeed) || r.age >= maxRagdollTime {
		return c.Freeze()
	}
	return nil
}

type ragdollBuilder struct {
	character *Character
	root      physics.Vec3
	yaw       physics.Quat
	parts     []physics.RagdollPart
	bones     []string
}

func (b *ragdollBuilder) build() ([]physics.RagdollPart, []string, error) {
	if err := b.box("Hips", physics.V(0.17, 0.14, 0.13), 12, -1, physics.JointNone, 0); err != nil {
		return nil, nil, err
	}
	if err := b.capsule("Torso", "Neck", 0.18, 16, 0, physics.JointSwingTwist, 0.55); err != nil {
		return nil, nil, err
	}
	if err := b.head(); err != nil {
		return nil, nil, err
	}
	for _, side := range []string{"L", "R"} {
		parent := 1
		if err := b.capsule("UpperArm."+side, "LowerArm."+side, 0.075, 2.2, parent, physics.JointSwingTwist, 1.1); err != nil {
			return nil, nil, err
		}
		upper := len(b.parts) - 1
		if err := b.capsule("LowerArm."+side, "Palm1."+side, 0.065, 1.7, upper, physics.JointHinge, 1.25); err != nil {
			return nil, nil, err
		}
	}
	for _, side := range []string{"L", "R"} {
		if err := b.capsule("UpperLeg."+side, "LowerLeg."+side, 0.105, 6, 0, physics.JointSwingTwist, 0.85); err != nil {
			return nil, nil, err
		}
		upper := len(b.parts) - 1
		if err := b.capsule("LowerLeg."+side, "Foot."+side, 0.09, 4, upper, physics.JointHinge, 1.15); err != nil {
			return nil, nil, err
		}
		lower := len(b.parts) - 1
		if err := b.box("Foot."+side, physics.V(0.1, 0.07, 0.16), 1.2, lower, physics.JointPoint, 0); err != nil {
			return nil, nil, err
		}
	}
	return b.parts, b.bones, nil
}

func (b *ragdollBuilder) capsule(startName, endName string, radius, mass float32, parent int, joint physics.JointKind, limit float32) error {
	startIndex, start, err := b.character.bone(startName)
	if err != nil {
		return err
	}
	_ = startIndex
	_, end, err := b.character.bone(endName)
	if err != nil {
		return err
	}
	startPosition := b.worldPosition(start.Translation)
	endPosition := b.worldPosition(end.Translation)
	direction := endPosition.Sub(startPosition)
	length := vectorLength(direction)
	if length < 0.03 {
		return fmt.Errorf("bones %q and %q are too close: length=%f start=%+v end=%+v scale=%f", startName, endName, length, start, end, b.character.asset.scale)
	}
	rotation := b.worldRotation(start.Rotation)
	halfHeight := max(0.02, (length-2*radius)*0.5)
	axis := direction.Mul(1 / length)
	if joint == physics.JointHinge {
		axis = physics.QuatRotate(rotation, physics.V(1, 0, 0))
	}
	b.append(physics.RagdollPart{
		Transform: physics.Transform{Position: startPosition.Add(endPosition).Mul(0.5), Rotation: rotation},
		Size:      physics.V(halfHeight, radius, 0), Mass: mass, Parent: parent, Shape: physics.ShapeCapsule,
		Joint: joint, JointPivot: startPosition, JointAxis: axis, JointLimit: limit,
	}, startName)
	return nil
}

func (b *ragdollBuilder) head() error {
	_, pose, err := b.character.bone("Head")
	if err != nil {
		return err
	}
	rotation := b.worldRotation(pose.Rotation)
	position := b.worldPosition(pose.Translation)
	b.append(physics.RagdollPart{
		Transform: physics.Transform{Position: position.Add(physics.QuatRotate(rotation, physics.V(0, 0.13, 0))), Rotation: rotation},
		Size:      physics.V(0.17, 0, 0), Mass: 4, Parent: 1, Shape: physics.ShapeSphere,
		Joint: physics.JointSwingTwist, JointPivot: position, JointAxis: physics.V(0, 1, 0), JointLimit: 0.65,
	}, "Head")
	return nil
}

func (b *ragdollBuilder) box(name string, size physics.Vec3, mass float32, parent int, joint physics.JointKind, limit float32) error {
	_, pose, err := b.character.bone(name)
	if err != nil {
		return err
	}
	position := b.worldPosition(pose.Translation)
	rotation := b.worldRotation(pose.Rotation)
	b.append(physics.RagdollPart{
		Transform: physics.Transform{Position: position, Rotation: rotation}, Size: size, Mass: mass,
		Parent: parent, Shape: physics.ShapeBox, Joint: joint, JointPivot: position,
		JointAxis: physics.QuatRotate(b.yaw, physics.V(0, 0, 1)), JointLimit: limit,
	}, name)
	return nil
}

func (b *ragdollBuilder) append(part physics.RagdollPart, bone string) {
	b.parts = append(b.parts, part)
	b.bones = append(b.bones, bone)
}

func (b *ragdollBuilder) worldPosition(position rl.Vector3) physics.Vec3 {
	asset := b.character.asset
	local := physics.V(position.X, position.Y, position.Z).Mul(asset.scale).Add(asset.origin)
	return b.root.Add(physics.QuatRotate(b.yaw, local))
}

func (b *ragdollBuilder) worldRotation(rotation rl.Vector4) physics.Quat {
	local := physics.Quat{X: rotation.X, Y: rotation.Y, Z: rotation.Z, W: rotation.W}
	return physics.QuatNormalize(physics.QuatMultiply(b.yaw, local))
}

// applyRagdoll moves the bones with ragdoll parts to their bodies, carries
// the bones below them along, and moves the rest with the hips. The result
// becomes the character's own bone matrices.
func (c *Character) applyRagdoll(transforms []physics.Transform) error {
	r := c.ragdoll
	if len(transforms) != len(r.bones) {
		return fmt.Errorf("ragdoll part count changed")
	}
	asset := c.asset
	rootPosition := r.root.Add(physics.QuatRotate(r.yaw, asset.origin))
	root := rl.MatrixMultiply(
		matrixFromPhysics(physics.Transform{Position: rootPosition, Rotation: r.yaw}),
		rl.MatrixScale(asset.scale, asset.scale, asset.scale),
	)
	inverseRoot := rl.MatrixInvert(root)
	bones := asset.model.Skeleton.GetBones()
	for i := range r.base {
		r.oldWorld[i] = rl.MatrixMultiply(matrixFromRaylib(r.base[i]), root)
		r.newWorld[i] = r.oldWorld[i]
		r.propagated[i] = false
	}
	for i := range bones {
		if part := r.partAtBone[i]; part >= 0 {
			r.newWorld[i] = matrixFromPhysics(physics.ComposeTransform(transforms[part], r.offsets[part]))
			r.propagated[i] = true
		} else if parent := bones[i].Parent; parent >= 0 && int(parent) < i && r.propagated[parent] {
			delta := rl.MatrixMultiply(rl.MatrixInvert(r.oldWorld[parent]), r.newWorld[parent])
			r.newWorld[i] = rl.MatrixMultiply(r.oldWorld[i], delta)
			r.propagated[i] = true
		}
	}
	hips := asset.bones["Hips"]
	rootDelta := rl.MatrixMultiply(rl.MatrixInvert(r.oldWorld[hips]), r.newWorld[hips])
	for i := range bones {
		if !r.propagated[i] {
			r.newWorld[i] = rl.MatrixMultiply(r.oldWorld[i], rootDelta)
		}
		local := rl.MatrixMultiply(r.newWorld[i], inverseRoot)
		var transform rl.Transform
		local.Decompose(&transform.Translation, &transform.Rotation, &transform.Scale)
		transform.Scale = r.base[i].Scale
		r.pose[i] = transform
		c.matrices[i] = rl.MatrixMultiply(asset.inverseBind[i], matrixFromRaylib(transform))
	}
	return nil
}

func matrixFromRaylib(transform rl.Transform) rl.Matrix {
	return rl.MatrixMultiply(
		rl.MatrixMultiply(
			rl.MatrixScale(transform.Scale.X, transform.Scale.Y, transform.Scale.Z),
			rl.QuaternionToMatrix(transform.Rotation),
		),
		rl.MatrixTranslate(transform.Translation.X, transform.Translation.Y, transform.Translation.Z),
	)
}

func matrixFromPhysics(transform physics.Transform) rl.Matrix {
	return matrixFromRaylib(rl.Transform{
		Translation: vector(transform.Position), Rotation: quaternion(transform.Rotation),
		Scale: rl.NewVector3(1, 1, 1),
	})
}

func vectorLength(value physics.Vec3) float32 {
	return float32(math.Sqrt(float64(value.X*value.X + value.Y*value.Y + value.Z*value.Z)))
}

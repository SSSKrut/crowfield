package animation

import (
	"fmt"
	"math"

	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

func (c *CharacterModel) CreateRagdoll(world *physics.World, rootPosition physics.Vec3, yaw physics.Quat, velocity, impulse physics.Vec3) error {
	if c.ragdoll != nil {
		return nil
	}
	builder := ragdollBuilder{character: c, root: rootPosition, yaw: yaw}
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
	ragdoll, err := world.CreateRagdoll(parts, velocity, impulse)
	if err != nil {
		return err
	}
	c.ragdoll = ragdoll
	c.ragdollPose = append([]rl.Transform(nil), c.model.GetCurrentPose()...)
	c.ragdollRoot = rootPosition
	c.ragdollYaw = yaw
	c.parts = parts
	c.partBones = partBones
	c.partOffsets = offsets
	return nil
}

func (c *CharacterModel) RemoveRagdoll() error {
	if c.ragdoll == nil {
		return nil
	}
	if err := c.ragdoll.Close(); err != nil {
		return err
	}
	c.ragdoll = nil
	c.parts = nil
	c.partBones = nil
	rl.UpdateModelAnimation(c.model, c.animations[c.current], c.frame)
	return nil
}

func (c *CharacterModel) updateRagdoll() error {
	transforms, err := c.ragdoll.Transforms()
	if err != nil {
		return err
	}
	return c.applyRagdoll(transforms)
}

type ragdollBuilder struct {
	character *CharacterModel
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
		return fmt.Errorf("bones %q and %q are too close: length=%f start=%+v end=%+v scale=%f", startName, endName, length, start, end, b.character.scale)
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
	local := physics.V(position.X, position.Y, position.Z).Mul(b.character.scale).Add(b.character.origin)
	return b.root.Add(physics.QuatRotate(b.yaw, local))
}

func (b *ragdollBuilder) worldRotation(rotation rl.Vector4) physics.Quat {
	local := physics.Quat{X: rotation.X, Y: rotation.Y, Z: rotation.Z, W: rotation.W}
	return physics.QuatNormalize(physics.QuatMultiply(b.yaw, local))
}

func (c *CharacterModel) applyRagdoll(transforms []physics.Transform) error {
	if len(transforms) != len(c.partBones) {
		return fmt.Errorf("ragdoll part count changed")
	}
	rootPosition := c.ragdollRoot.Add(physics.QuatRotate(c.ragdollYaw, c.origin))
	root := rl.MatrixMultiply(
		matrixFromPhysics(physics.Transform{Position: rootPosition, Rotation: c.ragdollYaw}),
		rl.MatrixScale(c.scale, c.scale, c.scale),
	)
	inverseRoot := rl.MatrixInvert(root)
	bones := c.model.Skeleton.GetBones()
	base := c.ragdollPose
	oldWorld := make([]rl.Matrix, len(base))
	newWorld := make([]rl.Matrix, len(base))
	propagated := make([]bool, len(base))
	partAtBone := make(map[int]int, len(c.partBones))
	for i, name := range c.partBones {
		index, ok := c.bones[name]
		if !ok {
			return fmt.Errorf("ragdoll bone %q disappeared", name)
		}
		partAtBone[index] = i
	}
	for i := range base {
		oldWorld[i] = rl.MatrixMultiply(matrixFromRaylib(base[i]), root)
		newWorld[i] = oldWorld[i]
	}
	for i := range bones {
		if part, ok := partAtBone[i]; ok {
			boneTransform := physics.ComposeTransform(transforms[part], c.partOffsets[part])
			newWorld[i] = matrixFromPhysics(boneTransform)
			propagated[i] = true
		} else if parent := bones[i].Parent; parent >= 0 && int(parent) < i && propagated[parent] {
			delta := rl.MatrixMultiply(rl.MatrixInvert(oldWorld[parent]), newWorld[parent])
			newWorld[i] = rl.MatrixMultiply(oldWorld[i], delta)
			propagated[i] = true
		}
	}
	hips := c.bones["Hips"]
	rootDelta := rl.MatrixMultiply(rl.MatrixInvert(oldWorld[hips]), newWorld[hips])
	for i := range bones {
		if !propagated[i] {
			newWorld[i] = rl.MatrixMultiply(oldWorld[i], rootDelta)
		}
	}
	pose := c.model.GetCurrentPose()
	for i := range bones {
		local := rl.MatrixMultiply(newWorld[i], inverseRoot)
		var transform rl.Transform
		local.Decompose(&transform.Translation, &transform.Rotation, &transform.Scale)
		transform.Scale = base[i].Scale
		pose[i] = transform
	}
	updateSkinning(c.model)
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

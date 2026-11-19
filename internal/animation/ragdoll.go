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

// The parts of the ragdoll, in the order the rig builds them; a Strike
// names the part it hits by them.
const (
	RagdollHips = iota
	RagdollTorso
	RagdollHead
	RagdollUpperArmLeft
	RagdollLowerArmLeft
	RagdollUpperArmRight
	RagdollLowerArmRight
	RagdollUpperLegLeft
	RagdollLowerLegLeft
	RagdollFootLeft
	RagdollUpperLegRight
	RagdollLowerLegRight
	RagdollFootRight
	ragdollParts
)

// A strike gives the part it hits at most maxStrikeSpeed m/s: a light
// forearm struck as hard as the body would fling the whole ragdoll away.
const maxStrikeSpeed = 4

// Strike is the blow that fells a character: an impulse into one part of
// its ragdoll at a point, in N·s. A negative part strikes nothing.
type Strike struct {
	Part    int
	Point   physics.Vec3
	Impulse physics.Vec3
}

// ragdollRig is how the skeleton of an asset falls (ARCHITECTURE.md, 10.2):
// the parts of its ragdoll in the reference pose, the first keyframe of the
// idle clip, standing at the origin; the bone each part follows, and where
// the part sits on that bone. It is built once, with the shapes and joints
// every ragdoll of the asset shares.
type ragdollRig struct {
	parts      []physics.RagdollPart
	bones      []int
	toPart     []physics.Transform
	partAtBone []int
	settings   *physics.RagdollSettings
}

// rig builds the ragdoll rig on first use.
func (a *CharacterAsset) rig() (*ragdollRig, error) {
	if a.ragdollRig != nil {
		return a.ragdollRig, nil
	}
	reference := a.NewCharacter()
	reference.pose()
	builder := ragdollBuilder{character: reference, yaw: physics.IdentityQuat()}
	parts, names, err := builder.build()
	if err != nil {
		return nil, err
	}
	if len(parts) != ragdollParts {
		return nil, fmt.Errorf("the ragdoll has %d parts, want %d", len(parts), ragdollParts)
	}
	rig := &ragdollRig{parts: parts, bones: make([]int, len(parts)), toPart: make([]physics.Transform, len(parts))}
	rig.partAtBone = make([]int, a.model.Skeleton.BoneCount)
	for i := range rig.partAtBone {
		rig.partAtBone[i] = -1
	}
	for i, name := range names {
		bone, pose, err := reference.bone(name)
		if err != nil {
			return nil, err
		}
		rig.bones[i], rig.partAtBone[bone] = bone, i
		// Where the part sits on its bone, which holds in any pose.
		boneTransform := builder.place(pose)
		rig.toPart[i] = physics.ComposeTransform(physics.InverseTransform(boneTransform), parts[i].Transform)
	}
	if rig.settings, err = physics.NewRagdollSettings(parts); err != nil {
		return nil, err
	}
	a.ragdollRig = rig
	return rig, nil
}

// RagdollPool lends the ragdolls of an asset in a world, at most limit at
// once. They are made as needed and kept: falling makes no bodies or joints.
type RagdollPool struct {
	asset *CharacterAsset
	world *physics.World
	limit int
	idle  []*physics.Ragdoll
	lent  int
	// pose is where the parts go for the next ragdoll that starts.
	pose []physics.Transform
}

func (a *CharacterAsset) NewRagdollPool(world *physics.World, limit int) *RagdollPool {
	return &RagdollPool{asset: a, world: world, limit: limit, pose: make([]physics.Transform, ragdollParts)}
}

// Full reports whether every ragdoll is lent: one must freeze before another
// character can fall.
func (p *RagdollPool) Full() bool {
	return p.lent >= p.limit
}

// Lent is how many ragdolls are simulated now; Made how many exist.
func (p *RagdollPool) Lent() int {
	return p.lent
}

func (p *RagdollPool) Made() int {
	return p.lent + len(p.idle)
}

func (p *RagdollPool) take() (*physics.Ragdoll, error) {
	if p.Full() {
		return nil, fmt.Errorf("all %d ragdolls are in use", p.limit)
	}
	if len(p.idle) == 0 {
		if err := p.make(); err != nil {
			return nil, err
		}
	}
	ragdoll := p.idle[len(p.idle)-1]
	p.idle = p.idle[:len(p.idle)-1]
	p.lent++
	return ragdoll, nil
}

// Fill makes every ragdoll of the pool now, while loading, so that no fall
// makes one.
func (p *RagdollPool) Fill() error {
	for p.Made() < p.limit {
		if err := p.make(); err != nil {
			return err
		}
	}
	return nil
}

func (p *RagdollPool) make() error {
	rig, err := p.asset.rig()
	if err != nil {
		return err
	}
	ragdoll, err := p.world.CreateRagdoll(rig.settings)
	if err != nil {
		return err
	}
	p.idle = append(p.idle, ragdoll)
	return nil
}

func (p *RagdollPool) give(ragdoll *physics.Ragdoll) {
	ragdoll.Stop()
	p.idle = append(p.idle, ragdoll)
	p.lent--
}

// Close frees the idle ragdolls; those lent go with their world.
func (p *RagdollPool) Close() {
	for _, ragdoll := range p.idle {
		_ = ragdoll.Close()
	}
	p.idle = nil
}

// ragdollState is a fallen character: its ragdoll while it falls, and what
// turns the bodies back into a pose of the skeleton.
type ragdollState struct {
	body *physics.Ragdoll
	pool *RagdollPool
	rig  *ragdollRig
	age  float32
	hips physics.Vec3
	base []rl.Transform
	root physics.Vec3
	yaw  physics.Quat

	oldWorld   []rl.Matrix
	newWorld   []rl.Matrix
	propagated []bool
	pose       []rl.Transform
}

// Fall knocks the character down from its current pose, standing at root and
// turned by yaw: a ragdoll of the pool takes the pose of its bones, the
// velocity of the soldier and the strike.
func (c *Character) Fall(pool *RagdollPool, root physics.Vec3, yaw physics.Quat, velocity physics.Vec3, strike Strike) error {
	if c.ragdoll != nil {
		return nil
	}
	rig, err := c.asset.rig()
	if err != nil {
		return err
	}
	body, err := pool.take()
	if err != nil {
		return err
	}
	c.pose()
	current := c.asset.model.GetCurrentPose()
	place := ragdollBuilder{character: c, root: root, yaw: yaw}
	for i, bone := range rig.bones {
		pool.pose[i] = physics.ComposeTransform(place.place(current[bone]), rig.toPart[i])
	}
	impulse := strike.Impulse
	if strike.Part >= 0 && strike.Part < len(rig.parts) {
		if limit := rig.parts[strike.Part].Mass * maxStrikeSpeed; vectorLength(impulse) > limit {
			impulse = impulse.Mul(limit / vectorLength(impulse))
		}
	}
	if err := body.Start(pool.pose, velocity, strike.Part, strike.Point, impulse); err != nil {
		pool.give(body)
		return err
	}
	count := int(c.asset.model.Skeleton.BoneCount)
	c.ragdoll = &ragdollState{
		body: body, pool: pool, rig: rig, base: append([]rl.Transform(nil), current...), root: root, yaw: yaw,
		hips: pool.pose[RagdollHips].Position, oldWorld: make([]rl.Matrix, count), newWorld: make([]rl.Matrix, count),
		propagated: make([]bool, count), pose: make([]rl.Transform, count),
	}
	c.ownPose()
	return c.updateRagdoll(0)
}

// RemoveRagdoll stands the character up again: it is animated as before.
func (c *Character) RemoveRagdoll() error {
	if c.ragdoll != nil && c.ragdoll.body != nil {
		c.ragdoll.pool.give(c.ragdoll.body)
	}
	c.ragdoll = nil
	c.freePose()
	return nil
}

// Freeze ends the physics of a fallen character, whose ragdoll goes back to
// the pool; it keeps its last pose.
func (c *Character) Freeze() error {
	if c.ragdoll == nil || c.ragdoll.body == nil {
		return nil
	}
	c.ragdoll.pool.give(c.ragdoll.body)
	c.ragdoll.body = nil
	return nil
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
		speed = vectorLength(transforms[RagdollHips].Position.Sub(r.hips)) / deltaTime
	}
	r.hips = transforms[RagdollHips].Position
	active, err := r.body.IsActive()
	if err != nil {
		return err
	}
	if !active || (r.age >= ragdollTime && speed < flyingSpeed) || r.age >= maxRagdollTime {
		return c.Freeze()
	}
	return nil
}

// ragdollBuilder lays out the ragdoll on the pose last computed for a
// character standing at root, turned by yaw.
type ragdollBuilder struct {
	character *Character
	root      physics.Vec3
	yaw       physics.Quat
	parts     []physics.RagdollPart
	bones     []string
}

// place is where a bone of the pose is in the world.
func (b *ragdollBuilder) place(pose rl.Transform) physics.Transform {
	return physics.Transform{Position: b.worldPosition(pose.Translation), Rotation: b.worldRotation(pose.Rotation)}
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
	if len(transforms) != len(r.rig.bones) {
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
		if part := r.rig.partAtBone[i]; part >= 0 {
			r.newWorld[i] = matrixFromPhysics(physics.ComposeTransform(transforms[part], physics.InverseTransform(r.rig.toPart[part])))
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

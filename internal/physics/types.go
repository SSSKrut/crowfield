package physics

import "errors"

var ErrClosed = errors.New("physics object is closed")

type Vec3 struct {
	X float32
	Y float32
	Z float32
}

func V(x, y, z float32) Vec3 {
	return Vec3{X: x, Y: y, Z: z}
}

func (v Vec3) Add(other Vec3) Vec3 {
	return V(v.X+other.X, v.Y+other.Y, v.Z+other.Z)
}

func (v Vec3) Sub(other Vec3) Vec3 {
	return V(v.X-other.X, v.Y-other.Y, v.Z-other.Z)
}

func (v Vec3) Mul(value float32) Vec3 {
	return V(v.X*value, v.Y*value, v.Z*value)
}

func (v Vec3) Dot(other Vec3) float32 {
	return v.X*other.X + v.Y*other.Y + v.Z*other.Z
}

type Quat struct {
	X float32
	Y float32
	Z float32
	W float32
}

func IdentityQuat() Quat {
	return Quat{W: 1}
}

func QuatFromAxisAngle(axis Vec3, angle float32) Quat {
	half := angle * 0.5
	sine := float32Sin(half)
	return Quat{X: axis.X * sine, Y: axis.Y * sine, Z: axis.Z * sine, W: float32Cos(half)}
}

type Transform struct {
	Position Vec3
	Rotation Quat
}

func IdentityTransform() Transform {
	return Transform{Rotation: IdentityQuat()}
}

// Cosmetic bodies are dynamic but sit on the cosmetic layer: they touch only
// the world and ragdolls, never characters, vehicles or game objects.
type BoxDesc struct {
	HalfExtents Vec3
	Transform   Transform
	Dynamic     bool
	Cosmetic    bool
}

type SphereDesc struct {
	Radius    float32
	Transform Transform
	Dynamic   bool
	Cosmetic  bool
}

type Ray struct {
	Origin    Vec3
	Direction Vec3
	Distance  float32
}

type RayHit struct {
	Hit      bool
	Position Vec3
	Fraction float32
	BodyID   uint32
}

type ShapeKind int32

const (
	ShapeBox ShapeKind = iota
	ShapeCapsule
	ShapeSphere
)

type JointKind int32

const (
	JointNone JointKind = iota
	JointPoint
	JointHinge
	JointSwingTwist
)

type RagdollPart struct {
	Transform  Transform
	Size       Vec3
	Mass       float32
	Parent     int
	Shape      ShapeKind
	Joint      JointKind
	JointPivot Vec3
	JointAxis  Vec3
	JointLimit float32
}

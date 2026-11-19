package render

import (
	"math"

	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

// Frustum is the visible pyramid of a perspective camera, to skip drawing
// what lies outside it.
type Frustum struct {
	eye, forward, right, up physics.Vec3
	// tangents and secants of the half angles, horizontal and vertical
	tanX, tanY, secX, secY float32
}

// NewFrustum describes a camera with a vertical field of view in degrees,
// drawn at the given aspect ratio of width to height.
func NewFrustum(camera rl.Camera3D, aspect float32) Frustum {
	eye := physics.V(camera.Position.X, camera.Position.Y, camera.Position.Z)
	target := physics.V(camera.Target.X, camera.Target.Y, camera.Target.Z)
	forward := normalize(target.Sub(eye))
	right := normalize(cross(forward, physics.V(camera.Up.X, camera.Up.Y, camera.Up.Z)))
	up := cross(right, forward)
	halfY := float64(camera.Fovy) * math.Pi / 360
	halfX := math.Atan(math.Tan(halfY) * float64(aspect))
	return Frustum{
		eye: eye, forward: forward, right: right, up: up,
		tanX: float32(math.Tan(halfX)), tanY: float32(math.Tan(halfY)),
		secX: float32(1 / math.Cos(halfX)), secY: float32(1 / math.Cos(halfY)),
	}
}

// Sees reports whether any part of a sphere may be visible.
func (f *Frustum) Sees(center physics.Vec3, radius float32) bool {
	offset := center.Sub(f.eye)
	depth := offset.Dot(f.forward)
	if depth < -radius {
		return false
	}
	x, y := offset.Dot(f.right), offset.Dot(f.up)
	return abs(x) <= depth*f.tanX+radius*f.secX && abs(y) <= depth*f.tanY+radius*f.secY
}

func normalize(v physics.Vec3) physics.Vec3 {
	return v.Mul(1 / float32(math.Sqrt(float64(v.Dot(v)))))
}

func cross(a, b physics.Vec3) physics.Vec3 {
	return physics.V(a.Y*b.Z-a.Z*b.Y, a.Z*b.X-a.X*b.Z, a.X*b.Y-a.Y*b.X)
}

func abs(v float32) float32 {
	return float32(math.Abs(float64(v)))
}

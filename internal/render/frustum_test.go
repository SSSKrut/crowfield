package render

import (
	"testing"

	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

func TestFrustumSeesWhatTheCameraSees(t *testing.T) {
	// Looking along -Z with 60° vertically on a 2:1 screen: about 98° across.
	camera := rl.NewCamera3D(rl.NewVector3(0, 0, 0), rl.NewVector3(0, 0, -1), rl.NewVector3(0, 1, 0), 60, rl.CameraPerspective)
	frustum := NewFrustum(camera, 2)
	for _, c := range []struct {
		center physics.Vec3
		radius float32
		seen   bool
	}{
		{physics.V(0, 0, -10), 0.1, true},
		{physics.V(0, 0, 10), 1, false},
		{physics.V(0, 0, 0.5), 1, true},     // around the camera
		{physics.V(0, 5.5, -10), 0.1, true}, // tan 30° × 10 = 5.77
		{physics.V(0, 6, -10), 0.1, false},
		{physics.V(0, 6, -10), 0.5, true},
		{physics.V(11, 0, -10), 0.1, true}, // tan 49° × 10 = 11.5
		{physics.V(12, 0, -10), 0.1, false},
	} {
		if seen := frustum.Sees(c.center, c.radius); seen != c.seen {
			t.Errorf("sphere at %+v, radius %.1f: seen %t", c.center, c.radius, seen)
		}
	}
}

package physics

import (
	"math/rand/v2"
	"strings"
	"sync"
	"testing"
)

func TestErrorsComeFromTheFailingCall(t *testing.T) {
	var wg sync.WaitGroup
	failures := make(chan string, 64)
	for range 8 {
		wg.Go(func() {
			world, err := NewWorld()
			if err != nil {
				failures <- err.Error()
				return
			}
			defer world.Close()
			for range 200 {
				_, boxErr := world.CreateBox(BoxDesc{HalfExtents: V(-1, 1, 1), Transform: IdentityTransform()})
				_, sphereErr := world.CreateSphere(SphereDesc{Radius: 0, Transform: IdentityTransform()})
				_, characterErr := world.CreateCharacter(CharacterDesc{HalfHeight: 1, Radius: 0.3, MaxStrength: -1})
				for _, c := range []struct {
					err  error
					want string
				}{
					{boxErr, "Box extents must be positive"}, {sphereErr, "Sphere radius must be positive"},
					{characterErr, "Invalid character parameters"},
				} {
					if c.err == nil || c.err.Error() != c.want {
						failures <- "got " + errorText(c.err) + ", want " + c.want
						return
					}
				}
			}
		})
	}
	wg.Wait()
	close(failures)
	for failure := range failures {
		t.Error(failure)
	}
}

func TestRayCastHonoursLayerMask(t *testing.T) {
	world := newTestWorld(t)
	floor := createFloor(t, world)
	sphere, err := world.CreateSphere(SphereDesc{Radius: 0.5, Dynamic: true, Transform: translation(V(0, 2, 0))})
	if err != nil {
		t.Fatal(err)
	}
	down := Ray{Origin: V(0, 5, 0), Direction: V(0, -1, 0), Distance: 10}
	for _, c := range []struct {
		name  string
		mask  LayerMask
		hit   bool
		atY   float32
		owner *Body
	}{
		{"static and dynamic", Mask(LayerStatic, LayerDynamic), true, 2.5, sphere},
		{"static only", Mask(LayerStatic), true, 0, floor},
		{"cosmetic only", Mask(LayerCosmetic), false, 0, nil},
	} {
		hit, err := world.RayCast(down, c.mask)
		if err != nil {
			t.Fatal(err)
		}
		if hit.Hit != c.hit || (c.hit && (!near(hit.Position.Y, c.atY) || hit.BodyID != c.owner.ID())) {
			t.Errorf("%s: got %+v, want hit=%t at y=%.1f", c.name, hit, c.hit, c.atY)
		}
	}
}

func TestRayCastBatchMatchesSingleRays(t *testing.T) {
	world := newTestWorld(t)
	createFloor(t, world)
	for i := range 20 {
		_, err := world.CreateBox(BoxDesc{
			HalfExtents: V(0.5+float32(i%3), 1+float32(i%4), 0.5), Transform: translation(V(float32(i*3-30), 1, float32(i%5*4-8))),
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	random := rand.New(rand.NewPCG(1, 2))
	for _, count := range []int{1, 31, 32, 33, 1000} {
		rays := make([]Ray, count)
		for i := range rays {
			rays[i] = Ray{
				Origin:    V(random.Float32()*60-30, random.Float32()*4, random.Float32()*20-10),
				Direction: V(random.Float32()*2-1, random.Float32()*2-1, random.Float32()*2-1),
				Distance:  random.Float32() * 40,
			}
		}
		hits := make([]RayHit, count)
		if err := world.RayCastBatch(rays, Mask(LayerStatic), hits); err != nil {
			t.Fatal(err)
		}
		hitCount := 0
		for i, ray := range rays {
			single, err := world.RayCast(ray, Mask(LayerStatic))
			if err != nil {
				t.Fatal(err)
			}
			if hits[i] != single {
				t.Fatalf("batch of %d, ray %d: batch %+v, single %+v", count, i, hits[i], single)
			}
			if single.Hit {
				hitCount++
			}
		}
		if count >= 1000 && (hitCount == 0 || hitCount == count) {
			t.Errorf("batch of %d hit %d rays; the test scene should give a mix", count, hitCount)
		}
	}
	if err := world.RayCastBatch(make([]Ray, 2), Mask(LayerStatic), make([]RayHit, 1)); err == nil {
		t.Error("mismatched batch lengths accepted")
	}
}

// The embedded server and the client step their own worlds at the same time on
// the shared job pool, while bots cast ray batches.
func TestWorldsShareThePoolConcurrently(t *testing.T) {
	falling := newTestWorld(t)
	createFloor(t, falling)
	var balls []*Body
	for i := range 50 {
		ball, err := falling.CreateSphere(SphereDesc{
			Radius: 0.3, Dynamic: true, Transform: translation(V(float32(i)-25, 2, 0)),
		})
		if err != nil {
			t.Fatal(err)
		}
		balls = append(balls, ball)
	}
	casting := newTestWorld(t)
	createFloor(t, casting)
	rays := make([]Ray, 1000)
	for i := range rays {
		rays[i] = Ray{Origin: V(float32(i%40)-20, 3, float32(i/40)-12), Direction: V(0, -1, 0.1), Distance: 10}
	}
	want := make([]RayHit, len(rays))
	if err := casting.RayCastBatch(rays, Mask(LayerStatic), want); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	wg.Go(func() {
		for range 120 {
			_ = falling.Step(1.0 / 60)
		}
	})
	mismatches := make(chan int, 1)
	wg.Go(func() {
		got := make([]RayHit, len(rays))
		for range 50 {
			_ = casting.RayCastBatch(rays, Mask(LayerStatic), got)
			for i := range got {
				if got[i] != want[i] {
					mismatches <- i
					return
				}
			}
		}
	})
	wg.Wait()
	close(mismatches)
	if i, ok := <-mismatches; ok {
		t.Errorf("ray %d changed while another world was stepping", i)
	}
	for i, ball := range balls {
		transform, _ := ball.Transform()
		if transform.Position.Y > 0.35 || transform.Position.Y < 0.25 {
			t.Fatalf("ball %d did not come to rest on the floor: %+v", i, transform.Position)
		}
	}
}

func TestCharacterMaxStrength(t *testing.T) {
	for _, c := range []struct {
		strength float32
		pushed   bool
	}{{0, false}, {100, true}} {
		world := newTestWorld(t)
		createFloor(t, world)
		// A 0.3 m sphere weighs about 113 kg at Jolt's default density and rolls,
		// so 100 N moves it; a box of similar size would be held by friction.
		ball, err := world.CreateSphere(SphereDesc{Radius: 0.3, Dynamic: true, Transform: translation(V(0, 0.3, -2))})
		if err != nil {
			t.Fatal(err)
		}
		character, err := world.CreateCharacter(CharacterDesc{
			Position: V(0, 0.9, 0), HalfHeight: 0.55, Radius: 0.35, MaxSlopeRadians: 0.87, MaxStrength: c.strength,
		})
		if err != nil {
			t.Fatal(err)
		}
		start, _ := ball.Transform()
		for range 90 {
			_ = character.SetLinearVelocity(V(0, -1, -4))
			_ = character.Update(1.0 / 60)
			_ = world.Step(1.0 / 60)
		}
		end, _ := ball.Transform()
		moved := start.Position.Z - end.Position.Z
		if pushed := moved > 0.1; pushed != c.pushed {
			t.Errorf("strength %.0f N moved the ball by %.3f m, want pushed=%t", c.strength, moved, c.pushed)
		}
	}
}

// Cosmetic props fall and rest on the world, but a character walks through them.
func TestCosmeticBodiesDoNotTouchCharacters(t *testing.T) {
	world := newTestWorld(t)
	createFloor(t, world)
	prop, err := world.CreateSphere(SphereDesc{Radius: 0.5, Dynamic: true, Cosmetic: true, Transform: translation(V(0, 1, -2))})
	if err != nil {
		t.Fatal(err)
	}
	character, err := world.CreateCharacter(CharacterDesc{Position: V(0, 0.9, 0), HalfHeight: 0.55, Radius: 0.35, MaxSlopeRadians: 0.87})
	if err != nil {
		t.Fatal(err)
	}
	for range 120 {
		_ = character.SetLinearVelocity(V(0, -1, -3))
		_ = character.Update(1.0 / 60)
		_ = world.Step(1.0 / 60)
	}
	resting, _ := prop.Transform()
	// Jolt lets resting bodies sink a couple of centimetres into their support.
	if resting.Position.Y < 0.45 || resting.Position.Y > 0.51 || !near(resting.Position.Z, -2) {
		t.Errorf("the prop did not rest where it fell: %+v", resting.Position)
	}
	if position, _ := character.Position(); position.Z > -5.5 {
		t.Errorf("the character stopped at z=%.2f; the prop blocked it", position.Z)
	}
	hit, _ := world.RayCast(Ray{Origin: V(0, 3, -2), Direction: V(0, -1, 0), Distance: 5}, Mask(LayerStatic, LayerDynamic))
	if !hit.Hit || !near(hit.Position.Y, 0) {
		t.Errorf("a query without the cosmetic layer hit %+v", hit)
	}
}

func TestRefreshContactsUpdatesGroundState(t *testing.T) {
	world := newTestWorld(t)
	createFloor(t, world)
	character, err := world.CreateCharacter(CharacterDesc{Position: V(0, 0.9, 0), HalfHeight: 0.55, Radius: 0.35, MaxSlopeRadians: 0.87})
	if err != nil {
		t.Fatal(err)
	}
	for range 10 {
		_ = character.SetLinearVelocity(V(0, -1, 0))
		_ = character.Update(1.0 / 60)
	}
	for _, c := range []struct {
		y        float32
		grounded bool
	}{{5, false}, {0.9, true}} {
		before, _ := character.IsGrounded()
		_ = character.SetPosition(V(0, c.y, 0))
		stale, _ := character.IsGrounded()
		if stale != before {
			t.Fatalf("SetPosition changed the ground state by itself")
		}
		if err := character.RefreshContacts(); err != nil {
			t.Fatal(err)
		}
		if grounded, _ := character.IsGrounded(); grounded != c.grounded {
			t.Errorf("at y=%.1f grounded=%t after RefreshContacts, want %t", c.y, grounded, c.grounded)
		}
	}
}

func TestShutdownRequiresClosedWorlds(t *testing.T) {
	world, err := NewWorld()
	if err != nil {
		t.Fatal(err)
	}
	if err := Shutdown(); err == nil || !strings.Contains(err.Error(), "still open") {
		t.Errorf("shutdown with an open world returned %v", err)
	}
	if err := world.Close(); err != nil {
		t.Fatal(err)
	}
	if err := Shutdown(); err != nil {
		t.Fatalf("shutdown after closing worlds: %v", err)
	}
	again, err := NewWorld()
	if err != nil {
		t.Fatalf("Jolt did not start again after shutdown: %v", err)
	}
	if _, err := again.CreateBox(BoxDesc{HalfExtents: V(1, 1, 1), Transform: IdentityTransform()}); err != nil {
		t.Error(err)
	}
	_ = again.Close()
}

func newTestWorld(t *testing.T) *World {
	t.Helper()
	world, err := NewWorld()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = world.Close() })
	return world
}

func createFloor(t *testing.T, world *World) *Body {
	t.Helper()
	floor, err := world.CreateBox(BoxDesc{HalfExtents: V(50, 0.25, 50), Transform: translation(V(0, -0.25, 0))})
	if err != nil {
		t.Fatal(err)
	}
	return floor
}

func translation(position Vec3) Transform {
	return Transform{Position: position, Rotation: IdentityQuat()}
}

func near(value, want float32) bool {
	return value > want-1e-3 && value < want+1e-3
}

func errorText(err error) string {
	if err == nil {
		return "no error"
	}
	return err.Error()
}

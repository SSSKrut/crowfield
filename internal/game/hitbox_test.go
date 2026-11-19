package game

import (
	"math"
	"testing"

	"ravenfield/internal/physics"
)

func TestRayEntersCapsulesAndSpheres(t *testing.T) {
	capsule := Hitbox{A: physics.V(0, 1, 0), B: physics.V(0, 2, 0), Radius: 0.5}
	sphere := Hitbox{A: physics.V(3, 1, 0), B: physics.V(3, 1, 0), Radius: 0.25}
	for _, c := range []struct {
		name              string
		box               Hitbox
		origin, direction physics.Vec3
		want              float32
		hit               bool
	}{
		{"side of the body", capsule, physics.V(-5, 1.5, 0), physics.V(1, 0, 0), 4.5, true},
		{"top cap from above", capsule, physics.V(0, 5, 0), physics.V(0, -1, 0), 2.5, true},
		{"bottom cap along the axis", capsule, physics.V(0, -3, 0), physics.V(0, 1, 0), 3.5, true},
		{"past the side", capsule, physics.V(-5, 1.5, 0.6), physics.V(1, 0, 0), 0, false},
		{"away from it", capsule, physics.V(-5, 1.5, 0), physics.V(-1, 0, 0), 0, false},
		{"from inside", capsule, physics.V(0, 1.4, 0.1), physics.V(1, 0, 0), 0, false},
		{"sphere", sphere, physics.V(3, 1, -4), physics.V(0, 0, 1), 3.75, true},
		{"past the sphere", sphere, physics.V(3, 1.3, -4), physics.V(0, 0, 1), 0, false},
	} {
		got, hit := c.box.Ray(c.origin, c.direction)
		if hit != c.hit || (hit && math.Abs(float64(got-c.want)) > 1e-5) {
			t.Errorf("%s: hit %t at %.4f, want %t at %.4f", c.name, hit, got, c.hit, c.want)
		}
	}
}

// A soldier ten metres ahead, seen from the front, the side and the back:
// shots at the height of the head, the body and the legs hit those zones, and
// a shot past the hands misses.
func TestHitboxesFollowTheSoldier(t *testing.T) {
	for _, yaw := range []float32{0, math.Pi / 2, math.Pi, -2.5} {
		position := physics.V(3, 0.5, -10)
		for _, c := range []struct {
			height float32
			side   float32
			zone   HitZone
		}{{1.6, 0, ZoneHead}, {1.05, 0, ZoneTorso}, {0.7, 0, ZoneTorso}, {0.3, 0.26, ZoneLimb}, {0.6, 1.2, ZoneNone}} {
			origin := physics.V(3+c.side, 0.5+c.height, 0)
			distance, box, hit := RayHitboxes(origin, physics.V(0, 0, -1), 100, position, yaw)
			sideways := math.Abs(math.Sin(float64(yaw))) > 0.9
			// From the side the arm covers the lower body, and the legs stand
			// one behind the other.
			if sideways && c.height == 0.7 {
				continue
			}
			if sideways && c.zone == ZoneLimb {
				origin.X = 3
				distance, box, hit = RayHitboxes(origin, physics.V(0, 0, -1), 100, position, yaw)
			}
			zone := HitboxZone(box)
			if zone != c.zone || hit != (c.zone != ZoneNone) {
				t.Errorf("yaw %.1f, height %.2f: hit %s, want %s", yaw, c.height, zone, c.zone)
			}
			if hit && (distance < 8.5 || distance > 10) {
				t.Errorf("yaw %.1f, height %.2f: hit at %.2f m, the soldier stands at 10", yaw, c.height, distance)
			}
		}
		if _, _, hit := RayHitboxes(physics.V(3, 1.5, 0), physics.V(0, 0, -1), 5, position, yaw); hit {
			t.Errorf("yaw %.1f: a shot reaching 5 m hit a soldier at 10", yaw)
		}
	}
}

func TestHitboxesStayWithinTheirReach(t *testing.T) {
	for _, yaw := range []float32{0, 1, 2, 3, 4, 5, 6} {
		for _, box := range Hitboxes(physics.Vec3{}, yaw) {
			for _, end := range []physics.Vec3{box.A, box.B} {
				if reach := float32(math.Hypot(float64(end.X), float64(end.Z))) + box.Radius; reach > HitboxReach {
					t.Errorf("yaw %.0f: a %s hitbox reaches %.2f m out", yaw, box.Zone, reach)
				}
			}
		}
	}
}

func TestHitDamageByZone(t *testing.T) {
	weapons := DefaultWeapons()
	rifle := &weapons.AssaultRifle
	for _, c := range []struct {
		zone     HitZone
		distance float32
		want     int
	}{{ZoneHead, 10, 50}, {ZoneTorso, 10, 25}, {ZoneLimb, 10, 19}, {ZoneTorso, 300, 15}, {ZoneLimb, 300, 11}} {
		if got := rifle.HitDamage(c.zone, c.distance); got != c.want {
			t.Errorf("%s at %.0f m: %d, want %d", c.zone, c.distance, got, c.want)
		}
	}
	// Two body shots of the rifle and one in the head kill.
	if weapons.Rifle.HitDamage(ZoneTorso, 50)*2 < MaxHealth || weapons.Rifle.HitDamage(ZoneHead, 50) < MaxHealth {
		t.Error("the rifle does not kill with two body shots or one in the head")
	}
}

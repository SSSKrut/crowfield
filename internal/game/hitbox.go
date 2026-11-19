package game

import (
	"math"

	"ravenfield/internal/physics"
)

// MaxHealth is the health a soldier spawns with.
const MaxHealth = 100

// HitZone is the part of a soldier a shot hit; the damage depends on it.
type HitZone uint8

const (
	ZoneNone HitZone = iota
	ZoneHead
	ZoneTorso
	ZoneLimb
)

var zoneNames = [...]string{"none", "head", "torso", "limb"}

func (z HitZone) String() string {
	if int(z) < len(zoneNames) {
		return zoneNames[z]
	}
	return "zone"
}

// Hitbox is a capsule from A to B of the given radius; a sphere when A and B
// are the same point.
type Hitbox struct {
	A, B   physics.Vec3
	Radius float32
	Zone   HitZone
}

// The hitboxes of every soldier, human or bot (ARCHITECTURE.md, 6.9), in a
// space at its feet where X points to its right, Y up and Z forward. They
// are procedural: no animation runs on the server. They follow the robot of
// the prototype standing idle, a cartoon with a head as wide as its
// shoulders are long and forearms held forward: a capsule across the head,
// one for the body, and the legs, upper arms and forearms with the hands.
var standingHitboxes = [...]Hitbox{
	{A: physics.V(-0.17, 1.45, 0), B: physics.V(0.17, 1.45, 0), Radius: 0.35, Zone: ZoneHead},
	{A: physics.V(0, 0.82, 0), B: physics.V(0, 0.88, 0), Radius: 0.29, Zone: ZoneTorso},
	{A: physics.V(-0.26, 0.1, 0), B: physics.V(-0.26, 0.55, 0), Radius: 0.1, Zone: ZoneLimb},
	{A: physics.V(0.26, 0.1, 0), B: physics.V(0.26, 0.55, 0), Radius: 0.1, Zone: ZoneLimb},
	{A: physics.V(-0.25, 0.94, 0), B: physics.V(-0.36, 0.72, 0), Radius: 0.08, Zone: ZoneLimb},
	{A: physics.V(0.25, 0.94, 0), B: physics.V(0.36, 0.72, 0), Radius: 0.08, Zone: ZoneLimb},
	{A: physics.V(-0.36, 0.72, 0), B: physics.V(-0.6, 0.45, 0.55), Radius: 0.15, Zone: ZoneLimb},
	{A: physics.V(0.36, 0.72, 0), B: physics.V(0.6, 0.45, 0.55), Radius: 0.15, Zone: ZoneLimb},
}

// HitboxCount is how many hitboxes a soldier has.
const HitboxCount = len(standingHitboxes)

// HitboxReach bounds the hitboxes horizontally around a soldier's position:
// a shot that passes farther away misses it.
const HitboxReach = 1

// Hitboxes places the hitboxes of a soldier standing at position, looking
// along yaw.
func Hitboxes(position physics.Vec3, yaw float32) [HitboxCount]Hitbox {
	right := physics.V(float32Cos(yaw), 0, float32Sin(yaw))
	forward := physics.V(float32Sin(yaw), 0, -float32Cos(yaw))
	place := func(local physics.Vec3) physics.Vec3 {
		return position.Add(right.Mul(local.X)).Add(physics.V(0, local.Y, 0)).Add(forward.Mul(local.Z))
	}
	var boxes [HitboxCount]Hitbox
	for i, box := range standingHitboxes {
		boxes[i] = Hitbox{A: place(box.A), B: place(box.B), Radius: box.Radius, Zone: box.Zone}
	}
	return boxes
}

// RayHitboxes finds where a ray from origin along the unit direction first
// enters the hitboxes of a soldier standing at position and looking along
// yaw, no farther than limit, and which hitbox it enters.
func RayHitboxes(origin, direction physics.Vec3, limit float32, position physics.Vec3, yaw float32) (float32, int, bool) {
	nearest, entered := limit, -1
	for i, box := range Hitboxes(position, yaw) {
		if t, ok := box.Ray(origin, direction); ok && t <= nearest {
			nearest, entered = t, i
		}
	}
	return nearest, entered, entered >= 0
}

// HitboxZone is the zone of a hitbox by its index.
func HitboxZone(box int) HitZone {
	if box < 0 || box >= HitboxCount {
		return ZoneNone
	}
	return standingHitboxes[box].Zone
}

// HitMark is the last hit a soldier took, which every client sees: a
// counter that changes with each hit, the hitbox, and the yaw the shot
// travelled along. The client shows the hit with it, and the fall when it
// killed.
type HitMark struct {
	Count uint8
	Box   uint8
	Yaw   float32
}

// Ray returns the distance along a ray from origin in the unit direction to
// where it enters the hitbox. A ray that starts inside does not hit it.
func (h *Hitbox) Ray(origin, direction physics.Vec3) (float32, bool) {
	best := math.Inf(1)
	o := vec64(origin)
	d := vec64(direction)
	a, b := vec64(h.A), vec64(h.B)
	r := float64(h.Radius)
	// The two spheres at the ends.
	for _, center := range [2][3]float64{a, b} {
		if t, ok := raySphere(o, d, center, r); ok {
			best = math.Min(best, t)
		}
	}
	// The cylinder between them: the ray's component across the axis.
	axis := sub64(b, a)
	length := math.Sqrt(dot64(axis, axis))
	if length > 1e-9 {
		axis = scale64(axis, 1/length)
		oa := sub64(o, a)
		across := sub64(d, scale64(axis, dot64(d, axis)))
		offset := sub64(oa, scale64(axis, dot64(oa, axis)))
		qa := dot64(across, across)
		qb := dot64(across, offset)
		qc := dot64(offset, offset) - r*r
		if h := qb*qb - qa*qc; qa > 1e-12 && h >= 0 {
			t := (-qb - math.Sqrt(h)) / qa
			if along := dot64(oa, axis) + t*dot64(d, axis); t >= 0 && along >= 0 && along <= length {
				best = math.Min(best, t)
			}
		}
	}
	if math.IsInf(best, 1) {
		return 0, false
	}
	return float32(best), true
}

// raySphere is where a ray from outside a sphere enters it.
func raySphere(o, d, center [3]float64, radius float64) (float64, bool) {
	oc := sub64(o, center)
	b := dot64(oc, d)
	c := dot64(oc, oc) - radius*radius
	h := b*b - c
	if c < 0 || h < 0 {
		return 0, false
	}
	t := -b - math.Sqrt(h)
	return t, t >= 0
}

func vec64(v physics.Vec3) [3]float64 {
	return [3]float64{float64(v.X), float64(v.Y), float64(v.Z)}
}

func sub64(a, b [3]float64) [3]float64 {
	return [3]float64{a[0] - b[0], a[1] - b[1], a[2] - b[2]}
}

func scale64(a [3]float64, s float64) [3]float64 {
	return [3]float64{a[0] * s, a[1] * s, a[2] * s}
}

func dot64(a, b [3]float64) float64 {
	return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]
}

// HitDamage is the damage of a hit in a zone from a distance, in whole points
// of health, at least one.
func (w *WeaponTuning) HitDamage(zone HitZone, distance float32) int {
	damage := w.DamageAt(distance)
	switch zone {
	case ZoneHead:
		damage *= w.HeadMultiplier
	case ZoneLimb:
		damage *= w.LimbMultiplier
	}
	return max(1, int(math.Round(float64(damage))))
}

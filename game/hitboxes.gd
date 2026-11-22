class_name Hitboxes
## The hitboxes of every soldier, human or bot (ARCHITECTURE.md, 6.9), in a
## space at its feet where X points to its right, Y up and Z forward. They are
## procedural, using the infantry soldier's ready pose. Animation runs on the
## client; the same capsules are used for server hits and visible impacts.

## Zone is the part of a soldier a shot hit; the damage depends on it.
enum Zone { NONE, HEAD, TORSO, LIMB }
const ZONE_NAMES := ["none", "head", "torso", "limb"]

## Each hitbox is a capsule from A to B of a radius; a sphere when A and B are
## the same point.
const A := [
	Vector3(0, 1.60, 0.006), Vector3(0, 1.03, 0), Vector3(-0.118, 0.12, 0.038), Vector3(0.118, 0.12, 0.038),
	Vector3(-0.23, 1.415, 0), Vector3(0.23, 1.415, 0), Vector3(-0.20, 1.22, 0.22), Vector3(0.255, 1.155, 0.105),
]
const B := [
	Vector3(0, 1.69, 0.006), Vector3(0, 1.31, 0), Vector3(-0.118, 0.84, 0.019), Vector3(0.118, 0.84, 0.019),
	Vector3(-0.20, 1.22, 0.22), Vector3(0.255, 1.155, 0.105), Vector3(0.075, 1.215, 0.515), Vector3(0.085, 1.205, 0.26),
]
const RADII := [0.118, 0.21, 0.105, 0.105, 0.082, 0.082, 0.069, 0.069]
## A staggered crouch lowers the head and keeps the chest over bent legs.
## A low bridge parapet hides the legs and lower torso, leaving the head exposed.
const CROUCH_A := [
	Vector3(0, 1.04, 0.23), Vector3(0, 0.48, -0.025), Vector3(-0.11, 0.115, 0.28), Vector3(0.11, 0.12, -0.24),
	Vector3(-0.21, 0.86, 0.17), Vector3(0.24, 0.88, 0.12), Vector3(-0.14, 0.65, 0.37), Vector3(0.21, 0.65, 0.24),
]
const CROUCH_B := [
	Vector3(0, 1.11, 0.23), Vector3(0, 0.84, 0.15), Vector3(-0.10, 0.51, 0.24), Vector3(0.13, 0.38, 0.02),
	Vector3(-0.14, 0.65, 0.37), Vector3(0.21, 0.65, 0.24), Vector3(0.06, 0.77, 0.59), Vector3(0.13, 0.77, 0.29),
]
const CROUCH_RADII := [0.118, 0.18, 0.112, 0.112, 0.082, 0.082, 0.105, 0.105]
const ZONES := [Zone.HEAD, Zone.TORSO, Zone.LIMB, Zone.LIMB, Zone.LIMB, Zone.LIMB, Zone.LIMB, Zone.LIMB]

## COUNT is how many hitboxes a soldier has.
const COUNT := 8
## REACH bounds the hitboxes horizontally around a soldier's position: a shot
## that passes farther away misses it.
const REACH := 1.0


static func zone_name(zone: int) -> String:
	if zone >= 0 and zone < ZONE_NAMES.size():
		return ZONE_NAMES[zone]
	return "zone"


## zone_of is the zone of a hitbox by its index.
static func zone_of(box: int) -> int:
	if box < 0 or box >= COUNT:
		return Zone.NONE
	return ZONES[box]


## place returns where a point of the hitbox space is for a soldier standing at
## position, looking along yaw.
static func place(local: Vector3, position: Vector3, yaw: float) -> Vector3:
	var right := Vector3(cos(yaw), 0, sin(yaw))
	var forward := Vector3(sin(yaw), 0, -cos(yaw))
	return position + right * local.x + Vector3(0, local.y, 0) + forward * local.z


## center is the middle of a hitbox of a soldier at position looking along yaw.
static func center(box: int, position: Vector3, yaw: float, crouched := false) -> Vector3:
	var a: Vector3 = CROUCH_A[box] if crouched else A[box]
	var b: Vector3 = CROUCH_B[box] if crouched else B[box]
	return place((a + b) * 0.5, position, yaw)


## ray finds where a ray from origin along the unit direction first enters the
## hitboxes of a soldier standing at position and looking along yaw, no
## farther than limit. It returns [distance, hitbox], or [] for a miss.
static func ray(origin: Vector3, direction: Vector3, limit: float, position: Vector3, yaw: float, crouched := false) -> Array:
	var right := Vector3(cos(yaw), 0, sin(yaw))
	var forward := Vector3(sin(yaw), 0, -cos(yaw))
	var nearest := limit
	var entered := -1
	var first := CROUCH_A if crouched else A
	var second := CROUCH_B if crouched else B
	var radii := CROUCH_RADII if crouched else RADII
	for i in COUNT:
		var a: Vector3 = first[i]
		var b: Vector3 = second[i]
		var start := position + right * a.x + Vector3(0, a.y, 0) + forward * a.z
		var end := position + right * b.x + Vector3(0, b.y, 0) + forward * b.z
		var t := ray_capsule(origin, direction, start, end, radii[i])
		if t >= 0.0 and t <= nearest:
			nearest = t
			entered = i
	if entered < 0:
		return []
	return [nearest, entered]


## ray_capsule returns the distance along a ray from origin in the unit
## direction to where it enters a capsule from a to b, or -1. A ray that starts
## inside does not hit it.
static func ray_capsule(origin: Vector3, direction: Vector3, a: Vector3, b: Vector3, radius: float) -> float:
	var best := INF
	# The two spheres at the ends.
	for end in [a, b]:
		var t := _ray_sphere(origin, direction, end, radius)
		if t >= 0.0:
			best = minf(best, t)
	# The cylinder between them: the ray's component across the axis.
	var axis := b - a
	var length := axis.length()
	if length > 1e-9:
		axis /= length
		var oa := origin - a
		var across := direction - axis * direction.dot(axis)
		var offset := oa - axis * oa.dot(axis)
		var qa := across.dot(across)
		var qb := across.dot(offset)
		var qc := offset.dot(offset) - radius * radius
		var h := qb * qb - qa * qc
		if qa > 1e-12 and h >= 0:
			var t := (-qb - sqrt(h)) / qa
			var along := oa.dot(axis) + t * direction.dot(axis)
			if t >= 0 and along >= 0 and along <= length:
				best = minf(best, t)
	return -1.0 if best == INF else best


## _ray_sphere is where a ray from outside a sphere enters it, or -1.
static func _ray_sphere(origin: Vector3, direction: Vector3, center: Vector3, radius: float) -> float:
	var oc := origin - center
	var b := oc.dot(direction)
	var c := oc.dot(oc) - radius * radius
	var h := b * b - c
	if c < 0 or h < 0:
		return -1.0
	var t := -b - sqrt(h)
	return t if t >= 0 else -1.0

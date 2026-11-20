class_name Hitboxes
## The hitboxes of every soldier, human or bot (ARCHITECTURE.md, 6.9), in a
## space at its feet where X points to its right, Y up and Z forward. They are
## procedural: no animation runs on the server. They follow the robot of the
## prototype standing idle, a cartoon with a head as wide as its shoulders are
## long and forearms held forward: a capsule across the head, one for the
## body, and the legs, upper arms and forearms with the hands.

## Zone is the part of a soldier a shot hit; the damage depends on it.
enum Zone { NONE, HEAD, TORSO, LIMB }
const ZONE_NAMES := ["none", "head", "torso", "limb"]

## Each hitbox is a capsule from A to B of a radius; a sphere when A and B are
## the same point.
const A := [
	Vector3(-0.17, 1.45, 0), Vector3(0, 0.82, 0), Vector3(-0.26, 0.1, 0), Vector3(0.26, 0.1, 0),
	Vector3(-0.25, 0.94, 0), Vector3(0.25, 0.94, 0), Vector3(-0.36, 0.72, 0), Vector3(0.36, 0.72, 0),
]
const B := [
	Vector3(0.17, 1.45, 0), Vector3(0, 0.88, 0), Vector3(-0.26, 0.55, 0), Vector3(0.26, 0.55, 0),
	Vector3(-0.36, 0.72, 0), Vector3(0.36, 0.72, 0), Vector3(-0.6, 0.45, 0.55), Vector3(0.6, 0.45, 0.55),
]
const RADII := [0.35, 0.29, 0.1, 0.1, 0.08, 0.08, 0.15, 0.15]
const ZONES := [Zone.HEAD, Zone.TORSO, Zone.LIMB, Zone.LIMB, Zone.LIMB, Zone.LIMB, Zone.LIMB, Zone.LIMB]

## COUNT is how many hitboxes a soldier has; TORSO_BOX is the body, where a
## blast wounds.
const COUNT := 8
const TORSO_BOX := 1
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
static func center(box: int, position: Vector3, yaw: float) -> Vector3:
	return (place(A[box], position, yaw) + place(B[box], position, yaw)) * 0.5


## ray finds where a ray from origin along the unit direction first enters the
## hitboxes of a soldier standing at position and looking along yaw, no
## farther than limit. It returns [distance, hitbox], or [] for a miss.
static func ray(origin: Vector3, direction: Vector3, limit: float, position: Vector3, yaw: float) -> Array:
	var right := Vector3(cos(yaw), 0, sin(yaw))
	var forward := Vector3(sin(yaw), 0, -cos(yaw))
	var nearest := limit
	var entered := -1
	for i in COUNT:
		var a: Vector3 = A[i]
		var b: Vector3 = B[i]
		var start := position + right * a.x + Vector3(0, a.y, 0) + forward * a.z
		var end := position + right * b.x + Vector3(0, b.y, 0) + forward * b.z
		var t := ray_capsule(origin, direction, start, end, RADII[i])
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

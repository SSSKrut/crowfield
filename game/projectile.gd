class_name Projectile
extends RefCounted
## Projectile is a rocket or a grenade in flight. The server moves it, tick by
## tick, and bursts it; every client moves its picture of it with this same
## code through its copy of the same static world, from the tick it was
## launched, and bursts it where the server says. It falls, and a grenade
## bounces off what it strikes and rolls to rest; a rocket bursts where it
## strikes, or in the air at its range.

## A bouncing projectile slower than REST_SPEED on ground flatter than
## REST_SLOPE stops; what slides along a surface keeps GRIP of that speed.
const REST_SPEED := 1.2
const REST_SLOPE := 0.7
const GRIP := 0.75
## A projectile stays this far off the surfaces it strikes.
const SKIN := 0.05

var id := 0
var kind: int = WeaponTuning.Kind.NONE
## owner is the soldier that launched it, of team.
var owner := 0
var team := 0
var position := Vector3.ZERO
var velocity := Vector3.ZERO
var launched := 0
var travelled := 0.0
var resting := false


static func launch(number: int, shot: Shot, soldier: Soldier, tuning: WeaponTuning, tick: int) -> Projectile:
	var projectile := Projectile.new()
	projectile.id = number
	projectile.kind = shot.weapon
	projectile.owner = soldier.id
	projectile.team = soldier.team
	projectile.position = shot.origin
	projectile.velocity = shot.direction * tuning.projectile_speed
	projectile.launched = tick
	return projectile


func copy() -> Projectile:
	var other := Projectile.new()
	other.id = id
	other.kind = kind
	other.owner = owner
	other.team = team
	other.position = position
	other.velocity = velocity
	other.launched = launched
	other.travelled = travelled
	other.resting = resting
	return other


## step moves the projectile through the static world for the tick after
## tick, the ray query being reused, and returns whether it bursts: at its
## fuse, where it is, fuse ticks after it left; where a rocket strikes; or at
## its range.
func step(state: PhysicsDirectSpaceState3D, query: PhysicsRayQueryParameters3D, tuning: WeaponTuning, tick: int) -> bool:
	if tuning.fuse > 0 and tick - launched >= tuning.fuse_ticks():
		return true
	if resting:
		return false
	velocity.y -= tuning.projectile_gravity * Game.TICK_DELTA
	var motion := velocity * Game.TICK_DELTA
	query.from = position
	query.to = position + motion
	query.collision_mask = Game.LAYER_STATIC | Game.LAYER_VEHICLE
	query.hit_from_inside = false
	var hit := state.intersect_ray(query)
	if hit.is_empty():
		position += motion
		travelled += motion.length()
		return tuning.bounce <= 0 and travelled >= tuning.range
	var normal: Vector3 = hit["normal"]
	position = hit["position"] + normal * SKIN
	if tuning.bounce <= 0:
		return true
	var along := normal * velocity.dot(normal)
	velocity = (velocity - along) * GRIP - along * tuning.bounce
	if velocity.length() < REST_SPEED and normal.y > REST_SLOPE:
		velocity = Vector3.ZERO
		resting = true
	return false

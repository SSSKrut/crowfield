class_name Vehicle
extends RefCounted
## Vehicle is a tank on the map: its hull on the ground, its turret and gun,
## its health and its driver, who steers it and fires its gun alone, as in
## Battlefield. TankController moves it; the server
## owns it and every client draws it from the snapshots.
##
## Vehicle space has X to the right, Y up and Z backward, so the hull looks
## along -Z, like a soldier. Its origin is the ground under the middle of the
## hull. The sizes are those of the CF-27 model (assets/vehicles).

enum Kind { NONE, TANK }

const MAX_VEHICLES := 15
const MAX_HEALTH := 1000
## The hull box stands clear of the ground by its tracks; the turret box turns
## about TURRET_PIVOT, and the gun rises about GUN_PIVOT of the turret.
const HULL_CENTER := Vector3(0, 1.1, 0)
const HULL_HALF := Vector3(2.0, 0.55, 3.1)
const TURRET_PIVOT := Vector3(0, 1.62, 0.12)
const TURRET_CENTER := Vector3(0, 0.42, 0)
const TURRET_HALF := Vector3(1.3, 0.42, 1.8)
const GUN_PIVOT := Vector3(0, 0.42, -1.24)
const MUZZLE := 3.1
## A soldier gets in within REACH metres of the hull's side; the camera of
## the driver circles a point EYE above the turret ring.
const REACH := 2.5
const EYE := Vector3(0, 3.3, 0.12)
const RELOAD_TIME := 3.5
## A wreck stays WRECK_TIME seconds; a new tank comes RESPAWN_TIME seconds
## after the old one was destroyed.
const WRECK_TIME := 12.0
const RESPAWN_TIME := 30.0
## Damage a weapon does to the tank, which bullets do not scratch: a direct
## hit takes it all, a blast nearby a share by its distance, halved.
const DAMAGE := {
	WeaponTuning.Kind.ROCKET_LAUNCHER: 260,
	WeaponTuning.Kind.TANK_CANNON: 300,
	WeaponTuning.Kind.GRENADE: 90,
}

var id := 0
var kind: int = Kind.TANK
var team: int = Game.Team.NONE
var position := Vector3.ZERO
var yaw := 0.0
## speed is along the hull, negative in reverse; turret the yaw of the turret
## from the hull's, and gun the elevation of the gun, in radians.
var speed := 0.0
var turret := 0.0
var gun := 0.0
var health := MAX_HEALTH
var driver := 0
## reload counts the ticks until the gun fires again; shots counts the shells
## it fired, wrapping at 256.
var reload := 0
var shots := 0
var wrecked := false


func copy() -> Vehicle:
	var other := Vehicle.new()
	other.id = id
	other.kind = kind
	other.team = team
	other.position = position
	other.yaw = yaw
	other.speed = speed
	other.turret = turret
	other.gun = gun
	other.health = health
	other.driver = driver
	other.reload = reload
	other.shots = shots
	other.wrecked = wrecked
	return other


static func reload_ticks() -> int:
	return roundi(RELOAD_TIME * Game.TICK_RATE)


## damage_from is what a weapon does to the tank: all of it for a hit by the
## projectile itself, at distance 0, or a halved share of the blast of the
## tuning farther away.
static func damage_from(kind: int, tuning: WeaponTuning, distance: float) -> int:
	var full: int = DAMAGE.get(kind, 0)
	if distance <= 0.0:
		return full
	return roundi(full * 0.5 * tuning.blast_share(distance))

class_name MapScene
extends RefCounted
## MapScene describes a map: its terrain and static boxes, the props on it,
## where the teams appear and where bots go. The server and the client build
## the same collision from it; the client draws it, with decoration of its
## own that nothing collides with: tree crowns, bushes and water.

## Kind tells the client how to draw a box; the simulation does not care.
enum Kind { GROUND, CONCRETE, PLASTER, ROOF, WOOD, PLANKS, SANDBAG, ROCK, METAL, TRUNK, HAY, BLUE_CLOTH, RED_CLOTH, INVISIBLE }

const MAPS := ["valley", "prototype"]

## Box is a static box of the map; Sphere is a prop, decoration of the client
## that the server does not simulate.
class Box:
	var half_extents: Vector3
	var transform: Transform3D
	var kind: int = Kind.CONCRETE

class Sphere:
	var radius: float
	var transform: Transform3D

## Zone is a round area of the map: where a team appears, or a place bots
## head for.
class Zone:
	var name: String
	var center: Vector3
	var radius: float

	func _init(zone_name: String, at: Vector3, size: float) -> void:
		name = zone_name
		center = at
		radius = size


	## The bridge flag can be captured from the deck, but not the water below.
	func contains_flag_position(at: Vector3) -> bool:
		return absf(at.y - center.y) <= 1.4 and Vector2(at.x - center.x, at.z - center.z).length_squared() <= radius * radius

## Plant is a tree or a bush the client draws. A tree has a trunk among the
## boxes; its crown and a bush stop nothing.
class Plant:
	var position: Vector3
	var size: float
	var pine: bool

## Water is a level rectangle of water the client draws; soldiers wade
## through it.
class Water:
	var center: Vector3
	var half_extents: Vector2

var name := "prototype"
var terrain: Terrain
var boxes: Array[Box] = []
var spheres: Array[Sphere] = []
## zones[team] is where the soldiers of a team appear: a point when its
## radius is zero.
var zones: Array[Zone] = [null, null, null]
## objectives are the places of the map worth fighting for, where bots go.
var objectives: Array[Zone] = []
## Flags ordered by their positions from west to east. Empty on sandbox maps.
var flags: Array[Zone] = []
var trees: Array[Plant] = []
var bushes: Array[Plant] = []
var waters: Array[Water] = []
## roads are the dirt tracks the client paints on the ground, as lines
## through points; the ground under them is not changed.
var roads: Array[PackedVector2Array] = []
## patches are where soldiers gather and the client draws worn ground.
var patches: Array[Zone] = []
## play_area is the half size of the square around the origin that soldiers
## may roam.
var play_area := 14.0
## spawn and red_spawn are the centres of the zones of the teams.
var spawn := Vector3.ZERO
var red_spawn := Vector3.ZERO
var _hash := 0
var _hashed := false


## named builds a map by its name, or returns null for a name no map has.
static func named(map_name: String) -> MapScene:
	match map_name:
		"prototype":
			return prototype()
		"valley":
			return ValleyMap.build()
	return null


## prototype is the test map: a floor with a ramp, a platform, a wall, stairs
## and a column, and three balls to knock about.
static func prototype() -> MapScene:
	var scene := MapScene.new()
	scene.name = "prototype"
	scene.set_zone(Game.Team.BLUE, Vector3(0, 0.2, 7), 0)
	scene.set_zone(Game.Team.RED, Vector3(0, 0.2, -11), 0)
	scene.play_area = 14.0
	scene.add_box(Vector3(15, 0.25, 15), Vector3(0, -0.25, 0), Basis(), Kind.GROUND)
	scene.add_box(Vector3(2.5, 0.2, 3), Vector3(4, 0.65, 0), Basis(Vector3.RIGHT, 0.22), Kind.WOOD)
	scene.add_box(Vector3(2.5, 0.75, 2.5), Vector3(4, 0.75, -5), Basis(), Kind.WOOD)
	scene.add_box(Vector3(0.35, 0.6, 2), Vector3(-2, 0.6, -2), Basis(), Kind.WOOD)
	scene.add_box(Vector3(1.5, 0.15, 0.5), Vector3(-5, 0.15, 3), Basis(), Kind.WOOD)
	scene.add_box(Vector3(1.5, 0.3, 0.5), Vector3(-5, 0.3, 2), Basis(), Kind.WOOD)
	scene.add_box(Vector3(1.5, 0.45, 0.5), Vector3(-5, 0.45, 1), Basis(), Kind.WOOD)
	scene.add_box(Vector3(1.5, 0.6, 0.5), Vector3(-5, 0.6, 0), Basis(), Kind.WOOD)
	scene.add_box(Vector3(1.5, 0.75, 1.5), Vector3(-5, 0.75, -1.5), Basis(), Kind.WOOD)
	scene.add_box(Vector3(0.4, 1.2, 0.4), Vector3(0, 1.2, -4), Basis(), Kind.WOOD)
	scene._sphere(0.35, Vector3(-1.5, 3, 0))
	scene._sphere(0.45, Vector3(0, 4, 0))
	scene._sphere(0.3, Vector3(1.5, 5, 0))
	scene.objectives.append(Zone.new("floor", Vector3.ZERO, 12))
	return scene


func set_zone(team: int, at: Vector3, radius: float) -> void:
	zones[team] = Zone.new(Game.team_name(team) + " base", at, radius)
	if team == Game.Team.RED:
		red_spawn = at
	else:
		spawn = at


func add_box(half_extents: Vector3, at: Vector3, basis: Basis = Basis(), kind: int = Kind.CONCRETE) -> void:
	var box := Box.new()
	box.half_extents = half_extents
	box.transform = Transform3D(basis, at)
	box.kind = kind
	boxes.append(box)


## _box keeps the old name of add_box for tests that build small worlds.
func _box(half_extents: Vector3, at: Vector3, basis: Basis = Basis()) -> void:
	add_box(half_extents, at, basis)


func _sphere(radius: float, at: Vector3) -> void:
	var sphere := Sphere.new()
	sphere.radius = radius
	sphere.transform = Transform3D(Basis(), at)
	spheres.append(sphere)


## spawn_of is the centre of where soldiers of a team appear.
func spawn_of(team: int) -> Vector3:
	return red_spawn if team == Game.Team.RED else spawn


func zone_of(team: int) -> Zone:
	return zones[Game.Team.RED if team == Game.Team.RED else Game.Team.BLUE]


## ground_at is the height of the terrain at x, z, or zero on a map without
## one.
func ground_at(x: float, z: float) -> float:
	return terrain.height_at(x, z) if terrain != null else 0.0


## build_collision adds the terrain and the static boxes of the map to a
## physics space and returns their bodies and shapes, for free_collision.
func build_collision(space: RID) -> Array[RID]:
	var made: Array[RID] = []
	if terrain != null:
		made.append_array(terrain.build_collision(space))
	for box in boxes:
		var shape := PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(shape, box.half_extents)
		var body := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_add_shape(body, shape)
		PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, box.transform)
		PhysicsServer3D.body_set_collision_layer(body, Game.LAYER_STATIC)
		PhysicsServer3D.body_set_collision_mask(body, 0)
		PhysicsServer3D.body_set_space(body, space)
		made.append(body)
		made.append(shape)
	return made


static func free_collision(made: Array[RID]) -> void:
	for rid in made:
		PhysicsServer3D.free_rid(rid)


## hash_value identifies the geometry: a client refuses a server whose map
## differs from its own, since its prediction would not match.
func hash_value() -> int:
	if _hashed:
		return _hash
	var bytes := PackedByteArray()
	for box in boxes:
		for value in [box.half_extents, box.transform.origin, box.transform.basis.x, box.transform.basis.y, box.transform.basis.z]:
			var at := bytes.size()
			bytes.resize(at + 12)
			bytes.encode_float(at, value.x)
			bytes.encode_float(at + 4, value.y)
			bytes.encode_float(at + 8, value.z)
	if terrain != null:
		var digest := HashingContext.new()
		digest.start(HashingContext.HASH_SHA256)
		digest.update(terrain.bytes())
		bytes.append_array(digest.finish())
	for flag in flags:
		bytes.append_array(flag.name.to_utf8_buffer())
		bytes.append(0)
		var at := bytes.size()
		bytes.resize(at + 16)
		bytes.encode_float(at, flag.center.x)
		bytes.encode_float(at + 4, flag.center.y)
		bytes.encode_float(at + 8, flag.center.z)
		bytes.encode_float(at + 12, flag.radius)
	_hash = Game.fnv64(bytes)
	_hashed = true
	return _hash

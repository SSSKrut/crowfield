class_name MapScene
extends RefCounted
## MapScene describes a map: its static boxes, the props on it and where the
## teams appear. The server and the client build the same collision from it,
## and the client draws it.

## Box is a static box of the map, or a prop; Sphere is a prop. Props are
## decoration of the client: the server does not simulate them.
class Box:
	var half_extents: Vector3
	var transform: Transform3D

class Sphere:
	var radius: float
	var transform: Transform3D

var boxes: Array[Box] = []
var spheres: Array[Sphere] = []
## spawn is where the blue team appears, red_spawn the red team.
var spawn := Vector3.ZERO
var red_spawn := Vector3.ZERO
## play_area is the half size of the square around the origin that soldiers
## may roam.
var play_area := 14.0


## prototype is the test map: a floor with a ramp, a platform, a wall, stairs
## and a column, and three balls to knock about.
static func prototype() -> MapScene:
	var scene := MapScene.new()
	scene.spawn = Vector3(0, 0.2, 7)
	scene.red_spawn = Vector3(0, 0.2, -11)
	scene.play_area = 14.0
	scene._box(Vector3(15, 0.25, 15), Vector3(0, -0.25, 0))
	scene._box(Vector3(2.5, 0.2, 3), Vector3(4, 0.65, 0), Basis(Vector3.RIGHT, -0.22))
	scene._box(Vector3(2.5, 0.75, 2.5), Vector3(4, 0.75, -5))
	scene._box(Vector3(0.35, 0.6, 2), Vector3(-2, 0.6, -2))
	scene._box(Vector3(1.5, 0.15, 0.5), Vector3(-5, 0.15, 3))
	scene._box(Vector3(1.5, 0.3, 0.5), Vector3(-5, 0.3, 2))
	scene._box(Vector3(1.5, 0.45, 0.5), Vector3(-5, 0.45, 1))
	scene._box(Vector3(1.5, 0.6, 0.5), Vector3(-5, 0.6, 0))
	scene._box(Vector3(1.5, 0.75, 1.5), Vector3(-5, 0.75, -1.5))
	scene._box(Vector3(0.4, 1.2, 0.4), Vector3(0, 1.2, -4))
	scene._sphere(0.35, Vector3(-1.5, 3, 0))
	scene._sphere(0.45, Vector3(0, 4, 0))
	scene._sphere(0.3, Vector3(1.5, 5, 0))
	return scene


func _box(half_extents: Vector3, at: Vector3, basis: Basis = Basis()) -> void:
	var box := Box.new()
	box.half_extents = half_extents
	box.transform = Transform3D(basis, at)
	boxes.append(box)


func _sphere(radius: float, at: Vector3) -> void:
	var sphere := Sphere.new()
	sphere.radius = radius
	sphere.transform = Transform3D(Basis(), at)
	spheres.append(sphere)


## spawn_of is where soldiers of a team appear.
func spawn_of(team: int) -> Vector3:
	return red_spawn if team == Game.Team.RED else spawn


## build_collision adds the static boxes of the map to a physics space and
## returns their bodies and shapes, for free_collision.
func build_collision(space: RID) -> Array[RID]:
	var made: Array[RID] = []
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
	var bytes := PackedByteArray()
	for box in boxes:
		for value in [box.half_extents, box.transform.origin, box.transform.basis.x, box.transform.basis.y, box.transform.basis.z]:
			var at := bytes.size()
			bytes.resize(at + 12)
			bytes.encode_float(at, value.x)
			bytes.encode_float(at + 4, value.y)
			bytes.encode_float(at + 8, value.z)
	return Game.fnv64(bytes)

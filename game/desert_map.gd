class_name DesertMap
extends RefCounted
## DesertMap builds the desert: an oil town in a sandy basin 200 m across,
## ringed by high dunes. The blue base lies in the south, the red one in the
## north. Three flags stand on the line between them: a pump station in the
## west, the town square in the middle and a pump station in the east. Each
## side has a field of pumpjacks on one flank and a tank farm with a water
## tower on the other. The map is the same for both teams turned half a turn
## around its centre, so neither has the better side.
##
## The buildings, pumpjacks, tanks and the rest are sourced models
## (assets/desert/LICENSE.md) that only the client draws; their collision is
## a few invisible boxes each, from MODELS. The server never loads a model.

const SIZE := 256
const AREA := 100.0
const BASE := Vector3(0, 0, 76)
## Deploy just inside the gate, as in the valley.
const MUSTER := Vector3(0, 0, 69)
const MUSTER_RADIUS := 3.5
const OILFIELD := Vector3(-58, 0, 32)
const TANK_FARM := Vector3(58, 0, 32)
const STATION := Vector3(-56, 0, 0)
const BASE_LEVEL := 0.6
const TOWN_LEVEL := 0.4
const STATION_LEVEL := 0.4
const FIELD_LEVEL := 0.5
const TOWN_RADIUS := 8.0
const STATION_RADIUS := 6.0

## The sourced models by name: the file in res://assets/desert/models, the
## offset that brings the middle of its base to its origin, in its own units,
## the scale that turns those into metres, and its collision as boxes of
## [centre, half extents, yaw] in metres from that origin, or as bars
## {from, to, radius} along a slanted part. The houses take the whole of their
## bounds; the open frames, a core that stops shots and feet.
const MODELS := {
	"house_low": { "scale": 7.0, "boxes": [[Vector3(0, 3.08, -0.35), Vector3(2.94, 3.08, 3.29)]] },
	"house_two_a": { "scale": 7.0, "boxes": [[Vector3(0, 4.48, -0.35), Vector3(2.94, 4.48, 3.29)]] },
	"house_two_b": { "scale": 7.0, "boxes": [[Vector3(0, 4.48, 0), Vector3(2.94, 4.48, 2.94)]] },
	"house_three": { "scale": 7.0, "boxes": [[Vector3(0, 4.48, -0.45), Vector3(2.94, 4.48, 3.39)]] },
	"house_wide": { "scale": 7.0, "boxes": [[Vector3(0, 5.25, 0), Vector3(7.14, 5.25, 2.96)]] },
	"house_tall": { "scale": 7.0, "boxes": [[Vector3(0, 5.88, 0), Vector3(2.94, 5.88, 2.94)]] },
	"container_red": { "boxes": [[Vector3(0, 1.3, 0), Vector3(2.85, 1.3, 1.28)]] },
	"container_green": { "boxes": [[Vector3(0, 1.32, 0), Vector3(2.85, 1.3, 1.28)]] },
	"barrel": { "scale": 0.85, "boxes": [[Vector3(0, 0.49, 0), Vector3(0.28, 0.49, 0.28)]] },
	"pipes": { "scale": 1.5, "boxes": [[Vector3(0, 0.7, 0), Vector3(0.35, 0.7, 3.2)]] },
	"palm_a": { "scale": 2.6, "boxes": [[Vector3(0, 3.0, 0), Vector3(0.2, 3.0, 0.2)]] },
	"palm_b": { "scale": 2.3, "boxes": [[Vector3(0, 3.9, 0), Vector3(0.2, 3.9, 0.2)]] },
	# A round tank is four slabs through its axis, at most 8 % past its wall.
	"water_tower": { "scale": 1.4, "boxes": [
		[Vector3(0, 10.4, 0), Vector3(1.6, 1.9, 0.66), 0.0], [Vector3(0, 10.4, 0), Vector3(1.6, 1.9, 0.66), PI / 4],
		[Vector3(0, 10.4, 0), Vector3(1.6, 1.9, 0.66), PI / 2], [Vector3(0, 10.4, 0), Vector3(1.6, 1.9, 0.66), 3 * PI / 4],
		[Vector3(1.56, 4.3, 1.56), Vector3(0.14, 4.3, 0.14)], [Vector3(-1.56, 4.3, 1.56), Vector3(0.14, 4.3, 0.14)],
		[Vector3(1.56, 4.3, -1.56), Vector3(0.14, 4.3, 0.14)], [Vector3(-1.56, 4.3, -1.56), Vector3(0.14, 4.3, 0.14)]] },
	# The tank stands on legs round its rim; its cone hangs low enough over
	# the middle that a soldier ducks under it but walks between the legs.
	"storage_tank": { "offset": Vector3(0, 7.622, 0), "boxes": [
		[Vector3(0, 9.2, 0), Vector3(3.6, 4.7, 1.5), 0.0], [Vector3(0, 9.2, 0), Vector3(3.6, 4.7, 1.5), PI / 4],
		[Vector3(0, 9.2, 0), Vector3(3.6, 4.7, 1.5), PI / 2], [Vector3(0, 9.2, 0), Vector3(3.6, 4.7, 1.5), 3 * PI / 4],
		[Vector3(0, 3.7, 0), Vector3(1.7, 0.8, 1.7), PI / 4],
		[Vector3(2.42, 2.25, 2.42), Vector3(0.12, 2.25, 0.12)], [Vector3(-2.42, 2.25, 2.42), Vector3(0.12, 2.25, 0.12)],
		[Vector3(2.42, 2.25, -2.42), Vector3(0.12, 2.25, 0.12)], [Vector3(-2.42, 2.25, -2.42), Vector3(0.12, 2.25, 0.12)]] },
	# A squat oil cistern on a concrete plinth, with a caged ladder and a pipe
	# run along its wall.
	"oil_cistern": { "boxes": [
		[Vector3(0, 4.53, 0), Vector3(5.03, 4.53, 2.08), 0.0], [Vector3(0, 4.53, 0), Vector3(5.03, 4.53, 2.08), PI / 4],
		[Vector3(0, 4.53, 0), Vector3(5.03, 4.53, 2.08), PI / 2], [Vector3(0, 4.53, 0), Vector3(5.03, 4.53, 2.08), 3 * PI / 4],
		[Vector3(0, 0.245, 0), Vector3(5.48, 0.245, 2.27), 0.0], [Vector3(0, 0.245, 0), Vector3(5.48, 0.245, 2.27), PI / 4],
		[Vector3(0, 0.245, 0), Vector3(5.48, 0.245, 2.27), PI / 2], [Vector3(0, 0.245, 0), Vector3(5.48, 0.245, 2.27), 3 * PI / 4],
		[Vector3(3.04, 4.72, 4.33), Vector3(0.75, 4.34, 0.85), -0.96],
		[Vector3(-2.9, 1.3, 4.9), Vector3(2.7, 1.35, 0.6)]] },
	# The walking beam runs aslant from the crank up to the horse head.
	"pumpjack": { "offset": Vector3(743917, 801.4, -586006), "scale": 1.8e-5, "boxes": [
		[Vector3(-1.62, 0.09, -0.36), Vector3(2.58, 0.09, 1.95)],
		[Vector3(-0.68, 2.65, -0.06), Vector3(0.45, 2.6, 0.45)],
		[Vector3(-3.38, 2.27, -0.8), Vector3(0.45, 2.1, 0.45)],
		{ "from": Vector3(-3.85, 4.25, -1.35), "to": Vector3(2.8, 7.45, 1.3), "radius": 0.3 },
		[Vector3(2.58, 7.57, 1.12), Vector3(0.65, 1.9, 0.35), -0.4]] },
	# The camp of a base. The field tent is full of bunks and takes the whole
	# of its bounds; the mast is an open frame with a core. A pallet and a
	# jerry can are too low to stop anyone.
	"field_tent": { "offset": Vector3(-25.49, 0.085, 0.41), "scale": 0.65, "boxes": [[Vector3(0, 1.4, 0), Vector3(2.6, 1.4, 2.86)]] },
	"camp_tent": { "scale": 0.2, "boxes": [[Vector3(0, 0.8, 0), Vector3(0.8, 0.8, 1.25)]] },
	"radio_tower": { "scale": 0.55, "boxes": [[Vector3(0.41, 9.4, -0.2), Vector3(1.0, 9.4, 1.1)]] },
	"generator": { "offset": Vector3(-12.135, 0.12, -6.625), "scale": 0.8, "boxes": [[Vector3(0, 0.5, 0), Vector3(0.84, 0.5, 0.4)]] },
	"crate": { "scale": 1.2, "boxes": [[Vector3(0, 0.49, 0), Vector3(0.49, 0.49, 0.49)]] },
	"crate_slat": { "scale": 0.9, "boxes": [[Vector3(0, 0.59, 0), Vector3(0.62, 0.59, 0.59)]] },
	"barrier": { "scale": 1.3, "boxes": [[Vector3(0.02, 0.41, 0), Vector3(1.23, 0.41, 0.43)]] },
	"pallet": { "boxes": [] },
	"jerry_can": { "scale": 0.19, "boxes": [] },
	"rock_a": { "boxes": [[Vector3(-0.4, 0.8, 0.07), Vector3(1.1, 1.05, 1.0)]] },
	"rock_b": { "boxes": [[Vector3(-0.54, 3.4, 0.12), Vector3(3.4, 3.6, 3.0)]] },
	"rock_pillar": { "boxes": [[Vector3(-0.12, 3.2, -0.41), Vector3(2.1, 3.4, 2.05)]] },
}

## The houses of one half of the town, around the square at the origin:
## [model, x, z, yaw]. The other half is the same turned half a turn.
const TOWN := [
	["house_wide", -20.0, 10.0, 0.0], ["house_tall", -9.5, 10.0, 0.0], ["house_low", -32.0, 9.0, PI / 2],
	["house_two_a", -9.0, 21.0, -PI / 2], ["house_three", -20.0, 22.0, 0.0], ["house_two_b", -30.0, 22.0, 0.0],
	["house_tall", -14.0, 32.0, PI], ["house_low", -25.0, 32.0, PI],
	["house_two_b", 9.5, 10.0, 0.0], ["house_three", 17.0, 10.5, 0.0], ["house_wide", 30.0, 14.0, PI / 2],
	["house_tall", 11.0, 22.0, 0.0], ["house_low", 20.0, 23.0, PI], ["house_two_a", 30.0, 30.0, PI / 2],
	["house_two_b", 14.0, 32.0, PI], ["house_low", 22.0, 33.0, PI / 2],
]
## Dunes of one half of the basin: [x, z, radius, height].
const DUNES := [
	[-28.0, 50.0, 13.0, 3.0], [30.0, 52.0, 12.0, 2.6], [-84.0, 52.0, 20.0, 6.0], [84.0, 24.0, 18.0, 5.0],
	[-38.0, 72.0, 11.0, 2.8], [44.0, 74.0, 12.0, 3.2], [-86.0, 4.0, 14.0, 3.5],
]

## Flat is ground levelled for building: fully within inner, blending into the
## land up to outer.
class Flat:
	var center: Vector2
	var inner: float
	var outer: float
	var level: float

	func _init(at: Vector2, inner_radius: float, outer_radius: float, height: float) -> void:
		center = at
		inner = inner_radius
		outer = outer_radius
		level = height

var roads: Array[PackedVector2Array] = []
var _scene: MapScene
var _flats: Array[Flat] = []
var _random := RandomNumberGenerator.new()


static func build() -> MapScene:
	var maker := DesertMap.new()
	return maker._build()


func _build() -> MapScene:
	_scene = MapScene.new()
	_scene.name = "desert"
	_scene.play_area = AREA
	_scene.roads = roads
	_flats.append(Flat.new(Vector2.ZERO, 46, 56, TOWN_LEVEL))
	for sign: float in [1.0, -1.0]:
		_flats.append(Flat.new(_flat(BASE, sign), 20, 30, BASE_LEVEL))
		_flats.append(Flat.new(_flat(STATION, sign), 16, 24, STATION_LEVEL))
		_flats.append(Flat.new(_flat(OILFIELD, sign), 20, 28, FIELD_LEVEL))
		_flats.append(Flat.new(_flat(TANK_FARM, sign), 25, 33, FIELD_LEVEL))
	_scene.terrain = Terrain.create(SIZE, _height)
	_scene.set_zone(Game.Team.BLUE, _on_ground(MUSTER), MUSTER_RADIUS)
	_scene.set_zone(Game.Team.RED, _on_ground(-MUSTER), MUSTER_RADIUS)
	_roads()
	_town()
	for sign: float in [1.0, -1.0]:
		var turn := 0.0 if sign > 0 else PI
		_base(BASE * sign, turn)
		_station(STATION * sign, turn)
		_oilfield(OILFIELD * sign, turn)
		_tank_farm(TANK_FARM * sign, turn)
	_boundary()
	_nature()
	_objectives()
	return _scene


static func _flat(at: Vector3, sign: float) -> Vector2:
	return Vector2(at.x, at.z) * sign


# The ground.


func _height(x: float, z: float) -> float:
	var h := 0.4 + 0.5 * (_ripples(x, z) + _ripples(-x, -z))
	for dune: Array in DUNES:
		for sign: float in [1.0, -1.0]:
			h += _dune(x, z, Vector2(dune[0], dune[1]) * sign, dune[2], dune[3])
	# Where levelled places overlap, the ground goes to their levels weighed by
	# how near each is, the same whatever order they come in.
	var weights := 0.0
	var levels := 0.0
	var strongest := 0.0
	for flat in _flats:
		var distance := Vector2(x, z).distance_to(flat.center)
		if distance < flat.outer:
			var weight := smoothstep(flat.outer, flat.inner, distance)
			weights += weight
			levels += weight * flat.level
			strongest = maxf(strongest, weight)
	if weights > 0:
		h = lerpf(h, levels / weights, strongest)
	# The basin rises into a ring of high dunes, crested unevenly.
	var rim := maxf(absf(x), absf(z)) - 88
	if rim > 0:
		var crest := 0.8 + 0.2 * sin(0.11 * x + 0.07 * z) * sin(0.09 * z - 0.05 * x)
		h += pow(rim / 34, 2) * 26 * crest
	return snappedf(h, 0.001)


## _ripples are the long low waves the wind lays across open sand: gentle on
## the windward side, steeper in the lee.
static func _ripples(x: float, z: float) -> float:
	var along := 0.051 * (0.82 * x + 0.57 * z) + 0.6 * sin(0.023 * (x - z))
	var wave := sin(along)
	wave = wave + 0.35 * sin(2.0 * along + 0.8)
	return 0.8 * wave + 0.4 * sin(0.087 * x - 0.061 * z + 1.3) * cos(0.071 * z + 0.4)


static func _dune(x: float, z: float, at: Vector2, radius: float, height: float) -> float:
	var distance := Vector2(x, z).distance_to(at)
	if distance >= radius:
		return 0.0
	return height * (0.5 + 0.5 * cos(PI * distance / radius))


func _on_ground(at: Vector3) -> Vector3:
	return Vector3(at.x, _scene.terrain.height_at(at.x, at.z), at.z)


## _local turns a point of a place laid out facing north, around origin, by
## the turn of the place.
static func _local(origin: Vector3, turn: float, x: float, z: float) -> Vector3:
	return origin + Vector3(x, 0, z).rotated(Vector3.UP, turn)


## _model stands a sourced model on level at a local point of a place, turned
## by yaw on the spot, and adds its collision.
func _model(name: String, origin: Vector3, turn: float, x: float, z: float, level: float, yaw: float = 0.0, size: float = 1.0) -> void:
	var at := _local(origin, turn, x, z)
	at.y = level
	_place(name, at, turn + yaw, size)


func _place(name: String, at: Vector3, yaw: float, size: float = 1.0) -> void:
	var model := MapScene.Model.new()
	model.name = name
	model.transform = Transform3D(Basis(Vector3.UP, yaw), at)
	model.size = size
	_scene.models.append(model)
	for box: Variant in MODELS[name]["boxes"]:
		var local := _box_of(box)
		_scene.add_box(local[1] * size, model.transform * (local[0].origin * size),
			model.transform.basis * local[0].basis, MapScene.Kind.INVISIBLE)


## _box_of is a box of a model, as [its place in the model, half extents].
static func _box_of(box: Variant) -> Array:
	if box is Dictionary:
		var from: Vector3 = box["from"]
		var to: Vector3 = box["to"]
		var along := (to - from).normalized()
		var up := (Vector3.UP - along * along.dot(Vector3.UP)).normalized()
		var radius: float = box["radius"]
		return [Transform3D(Basis(along, up, along.cross(up)), (from + to) / 2), Vector3(from.distance_to(to) / 2, radius, radius)]
	var spin: float = box[2] if box.size() > 2 else 0.0
	return [Transform3D(Basis(Vector3.UP, spin), box[0]), box[1]]


## _put adds a box of the given size standing on level at a local point of a
## place: size is the full size, yaw turns it on the spot.
func _put(origin: Vector3, turn: float, x: float, z: float, level: float, size: Vector3, kind: int, yaw: float = 0.0) -> void:
	var at := _local(origin, turn, x, z)
	at.y = level + size.y / 2
	_scene.add_box(size / 2, at, Basis(Vector3.UP, turn + yaw), kind)


## _barrels stands a few drums together around a local point.
func _barrels(origin: Vector3, turn: float, x: float, z: float, level: float, count: int) -> void:
	const SPOTS := [Vector2(0, 0), Vector2(0.62, 0.1), Vector2(0.28, 0.6), Vector2(-0.4, 0.5)]
	for i in count:
		var spot: Vector2 = SPOTS[i]
		_model("barrel", origin, turn, x + spot.x, z + spot.y, level, 0.9 * i)


# The places.


## _base is a camp behind sandbags facing north, with a gate in the middle:
## two containers for shelter, a water tower to find it by, drums, palms and
## the team's tank. Its west half is the command post: a bunk tent, and a
## radio mast with its generator in the front corner. Its east half holds the
## stores beside the container and two small tents along the wall. A concrete
## barrier screens each side exit.
func _base(origin: Vector3, turn: float) -> void:
	const GATE_HALF_WIDTH := 4.5
	var level := BASE_LEVEL
	for side: float in [-1.0, 1.0]:
		_put(origin, turn, side * (GATE_HALF_WIDTH + 5.75), -15, level, Vector3(11.5, 1.1, 0.8), MapScene.Kind.SANDBAG)
		_put(origin, turn, side * 17, -8, level, Vector3(0.8, 1.1, 10), MapScene.Kind.SANDBAG)
		_put(origin, turn, side * 17, 8, level, Vector3(0.8, 1.1, 10), MapScene.Kind.SANDBAG)
		_model("container_green" if side < 0 else "container_red", origin, turn, side * 10, 2, level, PI / 2)
		_put(origin, turn, side * 6.5, -18.5, level, Vector3(3.2, 1.1, 0.8), MapScene.Kind.SANDBAG)
	_model("water_tower", origin, turn, 12, 11, level)
	_barrels(origin, turn, -6, -11, level, 3)
	_barrels(origin, turn, 6.5, -10.5, level, 2)
	_model("palm_a", origin, turn, -13, 12, level, 0.4)
	_model("palm_b", origin, turn, 14, -7, level, 2.1)
	# The bunk tent opens east, onto the yard.
	_model("field_tent", origin, turn, -9.5, 11.5, level, PI / 2)
	_model("radio_tower", origin, turn, -13.5, -10, level, 0.3)
	_model("generator", origin, turn, -11.3, -6.6, level, 0.25)
	_model("camp_tent", origin, turn, 14.3, 6, level)
	_model("camp_tent", origin, turn, 14.3, -11, level, 0.08)
	_model("crate", origin, turn, 7.6, 0.2, level, 0.1)
	_model("crate", origin, turn, 7.7, 1.45, level, 0.42)
	_model("crate_slat", origin, turn, 7.45, 3.2, level, -0.12)
	_model("pallet", origin, turn, 6.1, 0.5, level, 0.2)
	_model("jerry_can", origin, turn, 6.2, 2.3, level, 1.2)
	_model("jerry_can", origin, turn, 5.9, 2.7, level, 0.5)
	for side: float in [-1.0, 1.0]:
		_model("barrier", origin, turn, side * 19, 0, level, PI / 2)
	# The team's tank waits behind the gate, facing out.
	var team := Game.Team.BLUE if turn == 0.0 else Game.Team.RED
	_scene.vehicle_spawns.append(MapScene.VehicleSpawn.new(Vehicle.Kind.TANK, team, _local(origin, turn, 0, 6) + Vector3(0, level, 0), turn))


## _station is the pump station at a flag: containers on its flanks, pipe
## runs, sandbags and drums for cover, and a pumpjack on either side. It is
## the same turned half a turn, so either team comes at it alike.
func _station(origin: Vector3, turn: float) -> void:
	var level := STATION_LEVEL
	for half: float in [0.0, PI]:
		var spin := turn + half
		_model("container_green" if half == 0.0 else "container_red", origin, spin, -8, -1, level, PI / 2)
		_model("pipes", origin, spin, -1, -10, level, PI / 2)
		_put(origin, spin, -4, -6.5, level, Vector3(3.2, 1.1, 0.8), MapScene.Kind.SANDBAG)
		_put(origin, spin, 5, -6, level, Vector3(2.6, 1.1, 0.8), MapScene.Kind.SANDBAG, 0.4)
		_barrels(origin, spin, 3, -3, level, 3)
		_model("pumpjack", origin, spin, -15, -6, level, 0.5)


## _oilfield is a field of pumpjacks nodding over their wells, tied together
## by pipe runs, with drums and a container.
func _oilfield(origin: Vector3, turn: float) -> void:
	var level := FIELD_LEVEL
	for well: Array in [[-11.0, -8.0, 0.2], [5.0, -11.0, 1.4], [12.0, 4.0, 2.6], [-3.0, 6.0, -0.4], [-15.0, 11.0, 0.9]]:
		_model("pumpjack", origin, turn, well[0], well[1], level, well[2])
	_model("pipes", origin, turn, -4, -2, level, 0.3)
	_model("pipes", origin, turn, 6, 12, level, 1.2)
	_model("container_red", origin, turn, 16, -6, level, 0.2)
	_barrels(origin, turn, 2, -2, level, 3)
	_barrels(origin, turn, -12, 1, level, 2)


## _tank_farm is four storage tanks in a square with lanes between them, an
## oil cistern on the outer flank, a water tower, a container and pipe runs.
func _tank_farm(origin: Vector3, turn: float) -> void:
	var level := FIELD_LEVEL
	for corner: Vector2 in [Vector2(-7, -7), Vector2(7, -7), Vector2(-7, 7), Vector2(7, 7)]:
		_model("storage_tank", origin, turn, corner.x, corner.y, level)
	_model("pipes", origin, turn, 0, -12, level, PI / 2)
	_model("pipes", origin, turn, 0, 12, level, PI / 2)
	_model("oil_cistern", origin, turn, 18, -2, level)
	_model("water_tower", origin, turn, 17, 12, level)
	_model("container_green", origin, turn, -17, -2, level, PI / 2)
	_barrels(origin, turn, 13, -13, level, 3)


## _town is the oil town around its square: houses in two blocks on each half
## of the main street, with palms on the corners of the square.
func _town() -> void:
	for sign: float in [1.0, -1.0]:
		var turn := 0.0 if sign > 0 else PI
		for house: Array in TOWN:
			_model(house[0], Vector3.ZERO, turn, house[1], house[2], TOWN_LEVEL, house[3])
		_model("palm_a", Vector3.ZERO, turn, 5.2, 5.6, TOWN_LEVEL, 0.7)
		_model("palm_b", Vector3.ZERO, turn, -5.2, 5.6, TOWN_LEVEL, 2.3)
		_model("palm_a", Vector3.ZERO, turn, -14.5, 15.5, TOWN_LEVEL, 1.9)
		_model("palm_b", Vector3.ZERO, turn, 24.0, 16.5, TOWN_LEVEL, 0.2)
		_barrels(Vector3.ZERO, turn, 6.0, 15.0, TOWN_LEVEL, 2)


func _boundary() -> void:
	for side: float in [-1.0, 1.0]:
		_scene.add_box(Vector3(0.5, 20, AREA + 1), Vector3(side * (AREA + 0.5), 10, 0), Basis(), MapScene.Kind.INVISIBLE)
		_scene.add_box(Vector3(AREA + 1, 20, 0.5), Vector3(0, 10, side * (AREA + 0.5)), Basis(), MapScene.Kind.INVISIBLE)


func _roads() -> void:
	var west := PackedVector2Array([Vector2(-5, 62), Vector2(-26, 52), Vector2(-42, 36), Vector2(-50, 14), Vector2(-56, 6)])
	var east := PackedVector2Array([Vector2(5, 62), Vector2(26, 52), Vector2(42, 36), Vector2(50, 14), Vector2(56, 6)])
	var main := PackedVector2Array([Vector2(0, 62), Vector2(0, 36), Vector2(0, 0)])
	for road in [west, east, main]:
		roads.append(road)
		var turned := PackedVector2Array()
		for point in road:
			turned.append(-point)
		roads.append(turned)
	roads.append(PackedVector2Array([Vector2(-56, 0), Vector2(-36, 0), Vector2(36, 0), Vector2(56, 0)]))


## _nature scatters red rocks over the open sand of half of the basin and
## turns them onto the other half, away from the places and the roads.
func _nature() -> void:
	_random.seed = 2207
	for i in 90:
		var at := Vector2(_random.randf_range(-AREA + 4, AREA - 4), _random.randf_range(0, AREA - 4))
		if not _clear(at, 3.0):
			continue
		var pick := _random.randf()
		var name := "rock_a" if pick < 0.6 else ("rock_b" if pick < 0.85 else "rock_pillar")
		var size := _random.randf_range(0.8, 1.5) if name == "rock_a" else _random.randf_range(0.55, 0.9)
		var yaw := _random.randf() * TAU
		for sign: float in [1.0, -1.0]:
			var ground := _on_ground(Vector3(at.x * sign, 0, at.y * sign))
			_place(name, ground, yaw + (0.0 if sign > 0 else PI), size)


## _clear tells whether a point lies away from everything built, the roads
## and the bases, by at least margin.
func _clear(at: Vector2, margin: float) -> bool:
	if at.length() < 44 + margin:
		return false
	for sign: float in [1.0, -1.0]:
		for place: Array in [[BASE, 24.0], [STATION, 20.0], [OILFIELD, 24.0], [TANK_FARM, 27.0]]:
			var center := Vector2(place[0].x, place[0].z) * sign
			if at.distance_to(center) < place[1] + margin:
				return false
	for road in roads:
		for i in road.size() - 1:
			if Geometry2D.get_closest_point_to_segment(at, road[i], road[i + 1]).distance_to(at) < 4 + margin:
				return false
	return true


func _objectives() -> void:
	for sign: float in [1.0, -1.0]:
		var side := "south" if sign > 0 else "north"
		_scene.patches.append(MapScene.Zone.new("base", _on_ground(BASE * sign), 15))
		_scene.patches.append(MapScene.Zone.new("station", _on_ground(STATION * sign), 8))
		_scene.objectives.append(MapScene.Zone.new("%s pumps" % side, _on_ground(OILFIELD * sign), 14))
		_scene.objectives.append(MapScene.Zone.new("%s tanks" % side, _on_ground(TANK_FARM * sign), 14))
		_scene.objectives.append(MapScene.Zone.new("%s town" % side, _on_ground(Vector3(0, 0, 16) * sign), 10))
	_scene.patches.append(MapScene.Zone.new("square", _on_ground(Vector3.ZERO), 9))
	_scene.flags = [
		MapScene.Zone.new("West Wells", _on_ground(STATION), STATION_RADIUS),
		MapScene.Zone.new("Town", _on_ground(Vector3.ZERO), TOWN_RADIUS),
		MapScene.Zone.new("East Wells", _on_ground(-STATION), STATION_RADIUS),
	]
	_scene.objectives.append_array(_scene.flags)

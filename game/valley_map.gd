class_name ValleyMap
extends RefCounted
## ValleyMap builds the valley: a field 200 m across between wooded hills, cut
## in two by a shallow river. The blue base lies in the south, the red one in
## the north. Between them three ways cross the river: a bridge in the west,
## a ford in the middle and a bridge in the east. Each side has a village by
## one bridge and a hill with a bunker by the other, and ruins by the ford.
## The map is the same for both teams turned half a turn around its centre,
## so neither has the better side.
##
## Everything is computed: the same code gives the same map to the server and
## to every client, and the hash of the map checks that it did.

const SIZE := 256
const AREA := 100.0
const RIVER_BED := -2.2
const FORD_BED := -1.75
const WATER_LEVEL := -1.55
const RIVER_HALF_WIDTH := 10.0
const BASE := Vector3(0, 0, 76)
const VILLAGE := Vector3(-40, 0, 30)
const HILL := Vector3(58, 0, 44)
const KNOLL := Vector3(-66, 0, 54)
const RUINS := Vector3(13, 0, 16)
const BRIDGE_X := 45.0
const BASE_LEVEL := 1.2
const VILLAGE_LEVEL := 0.9
const HILL_LEVEL := 6.2
const BANK_LEVEL := 0.6

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
	var maker := ValleyMap.new()
	return maker._build()


## river_z is where the middle of the river runs at x.
static func river_z(x: float) -> float:
	return 7.0 * sin(0.031 * x)


func _build() -> MapScene:
	_scene = MapScene.new()
	_scene.name = "valley"
	_scene.play_area = AREA
	_scene.roads = roads
	for sign: float in [1.0, -1.0]:
		_flats.append(Flat.new(_flat(BASE, sign), 18, 28, BASE_LEVEL))
		_flats.append(Flat.new(_flat(VILLAGE, sign), 18, 28, VILLAGE_LEVEL))
		_flats.append(Flat.new(_flat(HILL, sign), 7, 12, HILL_LEVEL))
		var bridge := Vector2(BRIDGE_X * sign, river_z(BRIDGE_X * sign))
		_flats.append(Flat.new(bridge + Vector2(0, 14), 4, 9, BANK_LEVEL))
		_flats.append(Flat.new(bridge - Vector2(0, 14), 4, 9, BANK_LEVEL))
	_scene.terrain = Terrain.create(SIZE, _height)
	_scene.set_zone(Game.Team.BLUE, _on_ground(BASE), 8)
	_scene.set_zone(Game.Team.RED, _on_ground(-BASE), 8)
	_roads()
	for sign: float in [1.0, -1.0]:
		var turn := 0.0 if sign > 0 else PI
		_base(BASE * sign, turn)
		_village(VILLAGE * sign, turn)
		_hill_post(HILL * sign, turn)
		_bridge(BRIDGE_X * sign)
		_ruins(RUINS * sign, turn)
	_ford()
	_boundary()
	_nature()
	_objectives()
	return _scene


static func _flat(at: Vector3, sign: float) -> Vector2:
	return Vector2(at.x, at.z) * sign


# The ground.


func _height(x: float, z: float) -> float:
	var h := 0.5 + 0.6 * (_rolling(x, z) + _rolling(-x, -z))
	for sign: float in [1.0, -1.0]:
		h += _bump(x, z, HILL * sign, 26, 6.5)
		h += _bump(x, z, KNOLL * sign, 18, 3.5)
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
	var across := absf(z - river_z(x))
	if across < RIVER_HALF_WIDTH:
		var bed := lerpf(FORD_BED, RIVER_BED, smoothstep(5, 18, absf(x)))
		h = lerpf(h, bed, smoothstep(RIVER_HALF_WIDTH, RIVER_HALF_WIDTH * 0.35, across))
	var rim := maxf(absf(x), absf(z)) - 90
	if rim > 0:
		h += pow(rim / 38, 2) * 24
	return snappedf(h, 0.001)


static func _rolling(x: float, z: float) -> float:
	return 0.9 * sin(0.043 * x + 0.6) * cos(0.037 * z - 0.3) + 0.55 * sin(0.097 * x + 0.061 * z + 0.4) \
		+ 0.35 * cos(0.083 * x - 0.117 * z + 1.1)


static func _bump(x: float, z: float, at: Vector3, radius: float, height: float) -> float:
	var distance := Vector2(x - at.x, z - at.z).length()
	if distance >= radius:
		return 0.0
	return height * (0.5 + 0.5 * cos(PI * distance / radius))


func _on_ground(at: Vector3) -> Vector3:
	return Vector3(at.x, _scene.terrain.height_at(at.x, at.z), at.z)


## _local turns a point of a place laid out facing north, around origin, by
## the turn of the place.
static func _local(origin: Vector3, turn: float, x: float, z: float) -> Vector3:
	return origin + Vector3(x, 0, z).rotated(Vector3.UP, turn)


## _put adds a box of the given size standing on level at a local point of a
## place: size is the full size, yaw turns it on the spot.
func _put(origin: Vector3, turn: float, x: float, z: float, level: float, size: Vector3, kind: int, yaw: float = 0.0, lift: float = 0.0) -> void:
	var at := _local(origin, turn, x, z)
	at.y = level + lift + size.y / 2
	_scene.add_box(size / 2, at, Basis(Vector3.UP, turn + yaw), kind)


## _wall adds a straight wall from a to b of a place, standing on level, with
## openings cut into it: each is [distance along the wall to its middle,
## width, bottom, top].
func _wall(origin: Vector3, turn: float, a: Vector2, b: Vector2, level: float, height: float, thickness: float, kind: int, openings: Array = []) -> void:
	var length := a.distance_to(b)
	var along := (b - a) / length
	var yaw := atan2(-along.y, along.x)
	var cuts := openings.duplicate()
	cuts.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
	var start := 0.0
	var pieces := []
	for cut in cuts:
		var left: float = cut[0] - cut[1] / 2.0
		var right: float = cut[0] + cut[1] / 2.0
		pieces.append([start, left, 0.0, height])
		if cut[2] > 0:
			pieces.append([left, right, 0.0, cut[2]])
		if cut[3] < height:
			pieces.append([left, right, cut[3], height])
		start = right
	pieces.append([start, length, 0.0, height])
	for piece in pieces:
		var from: float = piece[0]
		var to: float = piece[1]
		if to - from < 0.05:
			continue
		var middle := a + along * (from + to) / 2.0
		var size := Vector3(to - from, piece[3] - piece[2], thickness)
		_put(origin, turn, middle.x, middle.y, level, size, kind, yaw, piece[2])


# The places.


## _base is a camp behind sandbags, facing north: huts, crates, a flag and a
## watch platform with a ramp.
func _base(origin: Vector3, turn: float) -> void:
	var level := BASE_LEVEL
	for side: float in [-1.0, 1.0]:
		_wall(origin, turn, Vector2(side * 4, -15), Vector2(side * 15, -15), level, 1.1, 0.8, MapScene.Kind.SANDBAG)
		_wall(origin, turn, Vector2(side * 17, -12), Vector2(side * 17, -2), level, 1.1, 0.8, MapScene.Kind.SANDBAG)
		_wall(origin, turn, Vector2(side * 17, 4), Vector2(side * 17, 14), level, 1.1, 0.8, MapScene.Kind.SANDBAG)
		_put(origin, turn, side * 2.2, -17.5, level, Vector3(2.4, 1.1, 0.8), MapScene.Kind.SANDBAG)
		# A hut open to the middle of the camp.
		var hut := Vector2(side * 11, 4)
		_wall(origin, turn, hut + Vector2(-2.5, -2), hut + Vector2(2.5, -2), level, 2.6, 0.2, MapScene.Kind.PLANKS)
		_wall(origin, turn, hut + Vector2(-2.5, 2), hut + Vector2(2.5, 2), level, 2.6, 0.2, MapScene.Kind.PLANKS)
		_wall(origin, turn, hut + Vector2(side * 2.5, -2), hut + Vector2(side * 2.5, 2), level, 2.6, 0.2, MapScene.Kind.PLANKS)
		_put(origin, turn, hut.x, hut.y, level, Vector3(5.6, 0.2, 4.6), MapScene.Kind.ROOF, 0.0, 2.6)
		# Crates by the front wall.
		_put(origin, turn, side * 8, -12.6, level, Vector3(1.2, 1.2, 1.2), MapScene.Kind.WOOD, 0.2 * side)
		_put(origin, turn, side * 9.4, -12.4, level, Vector3(1.2, 1.2, 1.2), MapScene.Kind.WOOD, -0.1 * side)
		_put(origin, turn, side * 8.7, -12.5, level, Vector3(1.1, 1.0, 1.1), MapScene.Kind.WOOD, 0.4 * side, 1.2)
		_put(origin, turn, side * 13, -8, level, Vector3(2.2, 1.3, 1.1), MapScene.Kind.METAL, 0.3 * side)
	# The watch platform at the back, 3 m up, with a ramp along its east side.
	var deck := Vector2(0, 10)
	for corner: Vector2 in [Vector2(-1.8, -1.8), Vector2(1.8, -1.8), Vector2(-1.8, 1.8), Vector2(1.8, 1.8)]:
		_put(origin, turn, deck.x + corner.x, deck.y + corner.y, level, Vector3(0.3, 3.0, 0.3), MapScene.Kind.WOOD)
	_put(origin, turn, deck.x, deck.y, level, Vector3(4.2, 0.2, 4.2), MapScene.Kind.PLANKS, 0.0, 2.8)
	_wall(origin, turn, deck + Vector2(-2.1, -2.1), deck + Vector2(2.1, -2.1), level + 3.0, 1.0, 0.15, MapScene.Kind.PLANKS)
	_wall(origin, turn, deck + Vector2(-2.1, 2.1), deck + Vector2(2.1, 2.1), level + 3.0, 1.0, 0.15, MapScene.Kind.PLANKS)
	_wall(origin, turn, deck + Vector2(-2.1, -2.1), deck + Vector2(-2.1, 2.1), level + 3.0, 1.0, 0.15, MapScene.Kind.PLANKS)
	# The ramp climbs west to the open east side of the deck, at 20 degrees.
	const RISE := 3.0
	const SLOPE := deg_to_rad(20.0)
	var run := RISE / tan(SLOPE)
	var ramp := _local(origin, turn, deck.x + 2.1 + run / 2.0, deck.y)
	ramp.y = level + RISE / 2.0 - 0.1 / cos(SLOPE)
	_scene.add_box(Vector3(RISE / sin(SLOPE) / 2.0, 0.1, 0.75), ramp, Basis(Vector3.UP, turn) * Basis(Vector3.BACK, -SLOPE), MapScene.Kind.PLANKS)
	# The flag.
	_put(origin, turn, -4, -4, level, Vector3(0.15, 7.0, 0.15), MapScene.Kind.METAL)
	var cloth := MapScene.Kind.BLUE_CLOTH if turn == 0.0 else MapScene.Kind.RED_CLOTH
	_put(origin, turn, -4 + 0.85, -4, level, Vector3(1.6, 1.0, 0.04), cloth, 0.0, 5.8)


## _house is a plastered house of width by depth with a flat roof, a door in
## the wall the given way (0 south, 1 east, 2 north, 3 west of the house) and
## windows in the other walls.
func _house(origin: Vector3, turn: float, center: Vector2, width: float, depth: float, door: int, level: float) -> void:
	const HEIGHT := 3.0
	const THICK := 0.3
	# A door lets a bot through: wider than its body and the margin of the mesh.
	const DOOR := 1.8
	var w := width / 2.0
	var d := depth / 2.0
	var corners := [Vector2(-w, d), Vector2(w, d), Vector2(w, -d), Vector2(-w, -d)]
	for side in 4:
		var a: Vector2 = center + corners[side]
		var b: Vector2 = center + corners[(side + 1) % 4]
		var length := a.distance_to(b)
		var openings := []
		if side == door:
			openings.append([length / 2.0, DOOR, 0.0, 2.2])
			if length > 6:
				openings.append([length / 2.0 - 2.4, 1.1, 1.0, 2.0])
				openings.append([length / 2.0 + 2.4, 1.1, 1.0, 2.0])
		else:
			if length > 4.5:
				openings.append([length / 3.0, 1.1, 1.0, 2.0])
				openings.append([length * 2.0 / 3.0, 1.1, 1.0, 2.0])
			else:
				openings.append([length / 2.0, 1.1, 1.0, 2.0])
		# Walls run along the side; the thickness lies inside the corners.
		var inward := (center - (a + b) / 2.0).normalized() * THICK / 2.0
		_wall(origin, turn, a + inward, b + inward, level - 0.3, HEIGHT + 0.3, THICK, MapScene.Kind.PLASTER,
			openings.map(func(o: Array) -> Array: return [o[0], o[1], o[2] + 0.3 if o[2] > 0 else 0.0, o[3] + 0.3]))
	_put(origin, turn, center.x, center.y, level, Vector3(width + 0.6, 0.3, depth + 0.6), MapScene.Kind.ROOF, 0.0, HEIGHT)


## _village is four houses around a square with a well, garden fences, stone
## walls and a cart.
func _village(origin: Vector3, turn: float) -> void:
	var level := VILLAGE_LEVEL
	_house(origin, turn, Vector2(-9, -8), 7, 6, 1, level)
	_house(origin, turn, Vector2(9, -9), 6, 8, 3, level)
	_house(origin, turn, Vector2(-9, 8), 6, 7, 1, level)
	_house(origin, turn, Vector2(10, 8), 8, 6, 3, level)
	# The well in the square.
	for side: float in [-1.0, 1.0]:
		_put(origin, turn, side * 0.7, 0, level, Vector3(0.3, 0.8, 1.7), MapScene.Kind.CONCRETE)
		_put(origin, turn, 0, side * 0.7, level, Vector3(1.1, 0.8, 0.3), MapScene.Kind.CONCRETE)
	# Stone walls round the village, with gaps for the ways in.
	_wall(origin, turn, Vector2(-16, -15), Vector2(-4, -15), level, 1.0, 0.5, MapScene.Kind.CONCRETE)
	_wall(origin, turn, Vector2(4, -15), Vector2(16, -15), level, 1.0, 0.5, MapScene.Kind.CONCRETE)
	_wall(origin, turn, Vector2(-16, 15), Vector2(-5, 15), level, 1.0, 0.5, MapScene.Kind.CONCRETE)
	_wall(origin, turn, Vector2(5, 15), Vector2(16, 15), level, 1.0, 0.5, MapScene.Kind.CONCRETE)
	# Garden fences.
	_wall(origin, turn, Vector2(-15, -3), Vector2(-15, 3), level, 1.1, 0.1, MapScene.Kind.PLANKS)
	_wall(origin, turn, Vector2(15, -2), Vector2(15, 3), level, 1.1, 0.1, MapScene.Kind.PLANKS)
	# A cart and hay.
	_put(origin, turn, 3, 3.5, level, Vector3(1.6, 0.9, 2.8), MapScene.Kind.WOOD, 0.4)
	_put(origin, turn, -4, 2.5, level, Vector3(1.4, 1.2, 1.4), MapScene.Kind.HAY, 0.2)
	_put(origin, turn, -4.2, 4.2, level, Vector3(1.4, 1.2, 1.4), MapScene.Kind.HAY, -0.3)
	_put(origin, turn, 4.5, -3.5, level, Vector3(1.0, 1.0, 1.0), MapScene.Kind.WOOD, 0.6)


## _hill_post is a concrete bunker on top of a hill, looking at the enemy
## through slits, with sandbags around it.
func _hill_post(origin: Vector3, turn: float) -> void:
	var level := HILL_LEVEL
	var front := [[1.6, 1.4, 1.2, 1.6], [4.0, 1.4, 1.2, 1.6]]
	_wall(origin, turn, Vector2(-3, -2.5), Vector2(3, -2.5), level - 0.3, 2.8, 0.5, MapScene.Kind.CONCRETE,
		front.map(func(o: Array) -> Array: return [o[0], o[1], o[2] + 0.3, o[3] + 0.3]))
	_wall(origin, turn, Vector2(-3, -2.5), Vector2(-3, 2.5), level - 0.3, 2.8, 0.5, MapScene.Kind.CONCRETE, [[2.5, 1.2, 1.5, 1.9]])
	_wall(origin, turn, Vector2(3, -2.5), Vector2(3, 2.5), level - 0.3, 2.8, 0.5, MapScene.Kind.CONCRETE, [[2.5, 1.2, 1.5, 1.9]])
	_wall(origin, turn, Vector2(-3, 2.5), Vector2(3, 2.5), level - 0.3, 2.8, 0.5, MapScene.Kind.CONCRETE, [[3.0, 1.8, 0.0, 2.5]])
	_put(origin, turn, 0, 0, level, Vector3(6.8, 0.4, 5.8), MapScene.Kind.CONCRETE, 0.0, 2.5)
	for side: float in [-1.0, 1.0]:
		_wall(origin, turn, Vector2(side * 5, -5), Vector2(side * 8, -1), level, 1.0, 0.7, MapScene.Kind.SANDBAG)
		_wall(origin, turn, Vector2(side * 1.5, -6.5), Vector2(side * 4.5, -6), level, 1.0, 0.7, MapScene.Kind.SANDBAG)
		_put(origin, turn, side * 6, 3, level, Vector3(1.2, 1.2, 1.2), MapScene.Kind.WOOD, 0.3)


## _bridge is a stone bridge with parapets over the river at x.
func _bridge(x: float) -> void:
	var middle := river_z(x)
	const HALF := 12.5
	const DECK := 0.7
	_scene.add_box(Vector3(2.2, 0.25, HALF), Vector3(x, DECK - 0.25, middle), Basis(), MapScene.Kind.CONCRETE)
	for side: float in [-1.0, 1.0]:
		_scene.add_box(Vector3(0.2, 0.45, HALF - 1.5), Vector3(x + side * 2.0, DECK + 0.45, middle), Basis(), MapScene.Kind.CONCRETE)
		_scene.add_box(Vector3(1.2, 1.4, 0.9), Vector3(x, DECK - 1.6, middle + side * 4), Basis(), MapScene.Kind.CONCRETE)


## _ruins are the broken walls of a mill by the ford.
func _ruins(origin: Vector3, turn: float) -> void:
	var level := _scene.terrain.height_at(origin.x, origin.z)
	_wall(origin, turn, Vector2(-5, -4), Vector2(3, -4), level - 0.4, 2.6, 0.6, MapScene.Kind.CONCRETE, [[2.0, 1.2, 0.0, 2.6], [6.0, 1.0, 1.1, 2.6]])
	_wall(origin, turn, Vector2(-5, -4), Vector2(-5, 3), level - 0.4, 1.8, 0.6, MapScene.Kind.CONCRETE, [[4.5, 1.6, 0.0, 1.8]])
	_wall(origin, turn, Vector2(5, 0), Vector2(5, 4), level - 0.4, 1.3, 0.6, MapScene.Kind.CONCRETE)
	_put(origin, turn, 1, 1.5, level - 0.2, Vector3(1.6, 0.8, 1.2), MapScene.Kind.ROCK, 0.5)
	_put(origin, turn, -2, 2, level - 0.2, Vector3(1.0, 0.6, 1.4), MapScene.Kind.ROCK, -0.4)


## _ford lays stepping stones across the shallow middle of the river.
func _ford() -> void:
	for i in 3:
		var at := Vector3(1.4 * sin(i * 1.7 + 0.4), 0, 1.25 + i * 2.5)
		for sign: float in [1.0, -1.0]:
			var stone := _on_ground(at * sign)
			_scene.add_box(Vector3(0.5, 0.2, 0.45), stone + Vector3(0, 0.05, 0), Basis(Vector3.UP, i * 0.7 + (0.0 if sign > 0 else PI)), MapScene.Kind.ROCK)
	var water := MapScene.Water.new()
	water.center = Vector3(0, WATER_LEVEL, 0)
	water.half_extents = Vector2(SIZE / 2.0, SIZE / 2.0)
	_scene.waters.append(water)


## _boundary keeps soldiers in the play area with walls no one sees.
func _boundary() -> void:
	for side: float in [-1.0, 1.0]:
		_scene.add_box(Vector3(0.5, 20, AREA + 1), Vector3(side * (AREA + 0.5), 10, 0), Basis(), MapScene.Kind.INVISIBLE)
		_scene.add_box(Vector3(AREA + 1, 20, 0.5), Vector3(0, 10, side * (AREA + 0.5)), Basis(), MapScene.Kind.INVISIBLE)


func _roads() -> void:
	var west := PackedVector2Array([Vector2(0, 62), Vector2(-24, 47), Vector2(-40, 30), Vector2(-45, 16),
		Vector2(-45, river_z(-45)), Vector2(-45, -22), Vector2(-30, -48), Vector2(0, -62)])
	var east := PackedVector2Array()
	for point in west:
		east.append(-point)
	roads.append(west)
	roads.append(east)
	roads.append(PackedVector2Array([Vector2(0, 62), Vector2(2, 30), Vector2(0, 0), Vector2(-2, -30), Vector2(0, -62)]))


## _nature scatters woods on the flanks, single trees, bushes and rocks over
## half of the map and turns them onto the other half, away from the
## places, the roads and the river.
func _nature() -> void:
	_random.seed = 1907
	for i in 260:
		var at := Vector2(_random.randf_range(-AREA - 20, AREA + 20), _random.randf_range(0, AREA + 20))
		var flank := absf(at.x) > 66 or at.y > 96
		if not flank and _random.randf() > 0.18:
			continue
		if not _clear(at, 5.0):
			continue
		var size := _random.randf_range(0.8, 1.25)
		var pine := _random.randf() < (0.7 if flank else 0.3)
		for sign: float in [1.0, -1.0]:
			_tree(at * sign, size, pine)
	for i in 160:
		var at := Vector2(_random.randf_range(-AREA, AREA), _random.randf_range(0, AREA))
		if not _clear(at, 2.5):
			continue
		var size := _random.randf_range(0.6, 1.3)
		for sign: float in [1.0, -1.0]:
			var bush := MapScene.Plant.new()
			bush.position = _on_ground(Vector3(at.x * sign, 0, at.y * sign))
			bush.size = size
			_scene.bushes.append(bush)
	for i in 26:
		var at := Vector2(_random.randf_range(-AREA + 6, AREA - 6), _random.randf_range(4, AREA - 6))
		if not _clear(at, 4.0):
			continue
		var size := Vector3(_random.randf_range(1.0, 2.6), _random.randf_range(0.7, 1.8), _random.randf_range(1.0, 2.4))
		var yaw := _random.randf() * TAU
		var tilt := _random.randf_range(-0.15, 0.15)
		for sign: float in [1.0, -1.0]:
			var ground := _on_ground(Vector3(at.x * sign, 0, at.y * sign))
			ground.y += size.y * 0.35
			_scene.add_box(size / 2, ground, Basis(Vector3.UP, yaw + (0.0 if sign > 0 else PI)) * Basis(Vector3.RIGHT, tilt), MapScene.Kind.ROCK)


func _tree(at: Vector2, size: float, pine: bool) -> void:
	var ground := _on_ground(Vector3(at.x, 0, at.y))
	var height := (5.5 if pine else 3.2) * size
	_scene.add_box(Vector3(0.17, height / 2, 0.17) * Vector3(size, 1, size), ground + Vector3(0, height / 2 - 0.2, 0), Basis(), MapScene.Kind.TRUNK)
	var tree := MapScene.Plant.new()
	tree.position = ground
	tree.size = size
	tree.pine = pine
	_scene.trees.append(tree)


## _clear tells whether a point lies away from everything built, the roads,
## the river and the bases, by at least margin.
func _clear(at: Vector2, margin: float) -> bool:
	if absf(at.y - river_z(at.x)) < RIVER_HALF_WIDTH + margin * 0.5:
		return false
	for sign: float in [1.0, -1.0]:
		for place: Array in [[BASE, 26.0], [VILLAGE, 22.0], [HILL, 13.0], [RUINS, 9.0]]:
			var center := Vector2(place[0].x, place[0].z) * sign
			if at.distance_to(center) < place[1] + margin:
				return false
		if at.distance_to(Vector2(BRIDGE_X * sign, river_z(BRIDGE_X * sign))) < 18 + margin:
			return false
	for road in roads:
		for i in road.size() - 1:
			if Geometry2D.get_closest_point_to_segment(at, road[i], road[i + 1]).distance_to(at) < 3 + margin * 0.5:
				return false
	return true


func _objectives() -> void:
	for sign: float in [1.0, -1.0]:
		_scene.patches.append(MapScene.Zone.new("base", _on_ground(BASE * sign), 15))
		_scene.patches.append(MapScene.Zone.new("square", _on_ground(VILLAGE * sign), 6))
		_scene.patches.append(MapScene.Zone.new("post", _on_ground(HILL * sign), 7))
		_scene.patches.append(MapScene.Zone.new("ruins", _on_ground(RUINS * sign), 5))
		var side := "south" if sign > 0 else "north"
		var village := "west village" if sign > 0 else "east village"
		var bridge := "west bridge" if sign > 0 else "east bridge"
		_scene.objectives.append(MapScene.Zone.new(village, _on_ground(VILLAGE * sign), 13))
		_scene.objectives.append(MapScene.Zone.new("%s hill" % side, _on_ground(HILL * sign), 7))
		_scene.objectives.append(MapScene.Zone.new("%s ruins" % side, _on_ground(RUINS * sign), 7))
		var x := -BRIDGE_X * sign
		_scene.objectives.append(MapScene.Zone.new(bridge, Vector3(x, 0.7, river_z(x)), 3))
	_scene.objectives.append(MapScene.Zone.new("ford", _on_ground(Vector3.ZERO), 8))

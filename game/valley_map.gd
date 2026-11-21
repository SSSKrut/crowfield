class_name ValleyMap
extends RefCounted
## ValleyMap builds the valley: a field 200 m across between wooded hills, cut
## in two by a shallow river. The blue base lies in the south, the red one in
## the north. Between them three ways cross the river: a bridge in the west,
## a ford in the middle and a bridge in the east. Each side has a village by
## one bridge and a timber lookout above the woods by the other. Ruins frame
## a direct, exposed ford between them.
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
## Deploy just behind the gate and within its straight approach.
const MUSTER := Vector3(0, 0, 67)
const MUSTER_RADIUS := 3.2
const GATE_HALF_WIDTH := 4.0
const ROUTE_POST_X := 5.1
const ROUTE_POST_Z := -19.4
const ROUTE_BOARD_Y := 2.30
const VILLAGE := Vector3(-40, 0, 30)
const HILL := Vector3(58, 0, 44)
const KNOLL := Vector3(-66, 0, 54)
const RUINS := Vector3(13, 0, 16)
const BRIDGE_X := 45.0
const BASE_LEVEL := 1.2
const VILLAGE_LEVEL := 0.9
const HILL_LEVEL := 6.2
const BANK_LEVEL := 0.6
const BRIDGE_HALF := 12.5
const BRIDGE_DECK := 0.7
const CUSTOMS_TOWER := Vector2(-13.15, -10.25)
const CUSTOMS_WELL := Vector2(0.0, 0.15)
const CUSTOMS_HOUSES := [
	{ "center": Vector2(-9.8, -7.8), "footprint": Vector2(9.0, 7.5), "door": 1,
		"height": 3.2, "pitch": 32.0, "wall": MapScene.Kind.MASONRY },
	{ "center": Vector2(9.2, -9.0), "footprint": Vector2(6.0, 8.0), "door": 3,
		"height": 3.0, "pitch": 24.0, "wall": MapScene.Kind.PLASTER },
	{ "center": Vector2(-9.0, 8.0), "footprint": Vector2(5.8, 6.8), "door": 1,
		"height": 2.65, "pitch": 29.0, "wall": MapScene.Kind.PLANKS },
	{ "center": Vector2(10.0, 8.0), "footprint": Vector2(8.0, 6.0), "door": 3,
		"height": 3.0, "pitch": 19.0, "wall": MapScene.Kind.PLASTER },
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
	_scene.set_zone(Game.Team.BLUE, _on_ground(MUSTER), MUSTER_RADIUS)
	_scene.set_zone(Game.Team.RED, _on_ground(-MUSTER), MUSTER_RADIUS)
	_roads()
	for sign: float in [1.0, -1.0]:
		var turn := 0.0 if sign > 0 else PI
		_base(BASE * sign, turn)
		_village(VILLAGE * sign, turn)
		_hill_post(HILL * sign, turn)
		_wooded_approach(sign)
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
	const FLANK_COVER_WIDTH := 2.4
	var level := BASE_LEVEL
	for side: float in [-1.0, 1.0]:
		_wall(origin, turn, Vector2(side * GATE_HALF_WIDTH, -15), Vector2(side * 15, -15), level, 1.1, 0.8, MapScene.Kind.SANDBAG)
		_wall(origin, turn, Vector2(side * 17, -12), Vector2(side * 17, -2), level, 1.1, 0.8, MapScene.Kind.SANDBAG)
		_wall(origin, turn, Vector2(side * 17, 4), Vector2(side * 17, 14), level, 1.1, 0.8, MapScene.Kind.SANDBAG)
		# Keep the outer sandbags clear of the main gate.
		_put(origin, turn, side * (GATE_HALF_WIDTH + FLANK_COVER_WIDTH / 2), -17.5, level,
			Vector3(FLANK_COVER_WIDTH, 1.1, 0.8), MapScene.Kind.SANDBAG)
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
	# The lane boards frame the gate, outside the clear line of advance.
	for side: float in [-1.0, 1.0]:
		_put(origin, turn, side * ROUTE_POST_X, ROUTE_POST_Z, level,
			Vector3(0.13, ROUTE_BOARD_Y + 0.38, 0.13), MapScene.Kind.METAL)
		_put(origin, turn, side * ROUTE_POST_X, ROUTE_POST_Z + 0.08, level,
			Vector3(2.2, 0.47, 0.09), MapScene.Kind.METAL, 0.0, ROUTE_BOARD_Y - 0.235)
	# The flag.
	_put(origin, turn, -4, -4, level, Vector3(0.15, 7.0, 0.15), MapScene.Kind.METAL)
	var cloth := MapScene.Kind.BLUE_CLOTH if turn == 0.0 else MapScene.Kind.RED_CLOTH
	_put(origin, turn, -4 + 0.85, -4, level, Vector3(1.6, 1.0, 0.04), cloth, 0.0, 5.8)


## The village buildings have traversable interiors and sloped collision
## that follows the visible roof. A door faces south, east, north or west.
func _house(origin: Vector3, turn: float, center: Vector2, width: float, depth: float,
		door: int, height: float, pitch: float, wall: int) -> void:
	var level := VILLAGE_LEVEL
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
		_wall(origin, turn, a + inward, b + inward, level - 0.3, height + 0.3, THICK, wall,
			openings.map(func(o: Array) -> Array: return [o[0], o[1], o[2] + 0.3 if o[2] > 0 else 0.0, o[3] + 0.3]))
	_pitched_roof(origin, turn, center, width, depth, level + height, pitch)


## Put a roof on the collision map, including its overhang and ridge beam.
func _pitched_roof(origin: Vector3, turn: float, center: Vector2, width: float, depth: float,
		eave: float, degrees: float) -> void:
	var pitch := deg_to_rad(degrees)
	var half_run := (depth + 0.65) * 0.25
	var ridge := eave + 2.0 * half_run * tan(pitch)
	const THICKNESS := 0.13
	for side: float in [-1.0, 1.0]:
		var at := _local(origin, turn, center.x, center.y + side * half_run)
		at.y = (eave + ridge) * 0.5
		var basis := Basis(Vector3.UP, turn) * Basis(Vector3.RIGHT, side * pitch)
		_scene.add_box(Vector3((width + 0.74) * 0.5, THICKNESS, half_run / cos(pitch)),
			at, basis, MapScene.Kind.SLATE)
	_put(origin, turn, center.x, center.y, ridge - 0.16, Vector3(width + 0.85, 0.24, 0.22), MapScene.Kind.SLATE)
	for end: float in [-1.0, 1.0]:
		# Short boards under each gable. Narrow them toward the ridge.
		var rise := ridge - eave
		for band in 4:
			var opening := depth * (1.0 - float(band + 1) / 5.0)
			_put(origin, turn, center.x + end * (width * 0.5 - 0.10), center.y,
				eave - 0.06, Vector3(0.15, rise / 4.0 + 0.05, opening),
				MapScene.Kind.PLANKS, 0.0, rise * band / 4.0)


## The customs house and courtyards form a covered route to the bridge.
func _village(origin: Vector3, turn: float) -> void:
	var level := VILLAGE_LEVEL
	for house in CUSTOMS_HOUSES:
		var footprint: Vector2 = house.footprint
		_house(origin, turn, house.center, footprint.x, footprint.y, house.door, house.height, house.pitch, house.wall)
	_customs_tower(origin, turn)
	_put(origin, turn, 0, 1, level - 0.16, Vector3(7.3, 0.19, 8.0), MapScene.Kind.COBBLES)
	_wall(origin, turn, Vector2(-11, -1), Vector2(-4.2, -1), level - 0.12,
		1.18, 0.48, MapScene.Kind.MASONRY, [[2.7, 2.2, 0.0, 1.18]])
	_wall(origin, turn, Vector2(4.3, -2), Vector2(12.5, -2), level - 0.12,
		1.18, 0.48, MapScene.Kind.MASONRY, [[4.4, 2.2, 0.0, 1.18]])
	_village_well(origin, turn, level)
	# Stone walls round the village, with gaps for the ways in.
	_wall(origin, turn, Vector2(-16, -15), Vector2(-4, -15), level, 1.0, 0.5, MapScene.Kind.MASONRY)
	_wall(origin, turn, Vector2(4, -15), Vector2(16, -15), level, 1.0, 0.5, MapScene.Kind.MASONRY)
	_wall(origin, turn, Vector2(-16, 15), Vector2(-5, 15), level, 1.0, 0.5, MapScene.Kind.MASONRY)
	_wall(origin, turn, Vector2(5, 15), Vector2(16, 15), level, 1.0, 0.5, MapScene.Kind.MASONRY)
	# Garden fences.
	_wall(origin, turn, Vector2(-15, -3), Vector2(-15, 3), level, 1.1, 0.1, MapScene.Kind.PLANKS)
	_wall(origin, turn, Vector2(15, -2), Vector2(15, 3), level, 1.1, 0.1, MapScene.Kind.PLANKS)
	# Stored cargo along the lane. Leave a straight line through the square.
	_put(origin, turn, 3.0, 3.5, level, Vector3(1.20, 0.75, 1.34), MapScene.Kind.WOOD, 0.40)
	_put(origin, turn, -4.0, 2.5, level, Vector3(1.34, 0.93, 1.25), MapScene.Kind.WOOD, 0.20)
	_put(origin, turn, -4.2, 4.2, level, Vector3(1.44, 1.11, 1.36), MapScene.Kind.WOOD, -0.30)
	_put(origin, turn, -4.1, 4.2, level, Vector3(0.82, 0.62, 0.94), MapScene.Kind.METAL, -0.16, 1.11)
	_put(origin, turn, 4.5, -3.5, level, Vector3(1.0, 1.0, 1.0), MapScene.Kind.WOOD, 0.60)


## A roofed stone well marks the courtyard and gives low cover.
func _village_well(origin: Vector3, turn: float, level: float) -> void:
	var center := CUSTOMS_WELL
	for side in 8:
		var angle := side * TAU / 8.0
		var normal := Vector2(cos(angle), sin(angle))
		var wall := center + normal * 0.79
		_put(origin, turn, wall.x, wall.y, level - 0.05, Vector3(0.72, 0.80, 0.29),
			MapScene.Kind.MASONRY, -angle + PI / 2.0)
		_put(origin, turn, wall.x, wall.y, level + 0.75, Vector3(0.76, 0.12, 0.35),
			MapScene.Kind.SLATE, -angle + PI / 2.0)
	for side: float in [-1.0, 1.0]:
		_put(origin, turn, center.x + side * 0.69, center.y, level + 0.78,
			Vector3(0.16, 1.46, 0.19), MapScene.Kind.PLANKS)
	_put(origin, turn, center.x, center.y, level + 1.54,
		Vector3(1.39, 0.11, 0.14), MapScene.Kind.PLANKS)
	_pitched_roof(origin, turn, center, 1.45, 1.36, level + 2.24, 32.0)


## The attached observation tower gives the village a recognizable
## silhouette from the camp gate and either riverbank.
func _customs_tower(origin: Vector3, turn: float) -> void:
	var center := CUSTOMS_TOWER
	const WIDTH := 3.0
	const HEIGHT := 6.15
	var level := VILLAGE_LEVEL
	_put(origin, turn, center.x, center.y, level - 0.25,
		Vector3(WIDTH + 0.4, 0.55, WIDTH + 0.4), MapScene.Kind.MASONRY)
	_put(origin, turn, center.x, center.y, level, Vector3(WIDTH, HEIGHT - 1.1, WIDTH), MapScene.Kind.MASONRY)
	var half := WIDTH * 0.5
	# Narrow openings under the roof read as a timber lookout around a small deck.
	for side: float in [-1.0, 1.0]:
		_wall(origin, turn, center + Vector2(-half, side * half), center + Vector2(half, side * half),
			level + HEIGHT - 1.14, 1.14, 0.18, MapScene.Kind.PLANKS, [[half, 1.25, 0.33, 0.88]])
		_wall(origin, turn, center + Vector2(side * half, -half), center + Vector2(side * half, half),
			level + HEIGHT - 1.14, 1.14, 0.18, MapScene.Kind.PLANKS, [[half, 1.25, 0.33, 0.88]])
	_put(origin, turn, center.x, center.y, level + HEIGHT - 1.18,
		Vector3(WIDTH + 0.24, 0.16, WIDTH + 0.24), MapScene.Kind.PLANKS)
	_pitched_roof(origin, turn, center, WIDTH, WIDTH, level + HEIGHT, 39.0)


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
	_put(origin, turn, 0, 0, level, Vector3(6.4, 0.22, 5.4), MapScene.Kind.CONCRETE, 0.0, 2.5)
	# Timber cap catches the eye above the trees, while the concrete hide
	# keeps its slit and southern door usable.
	_pitched_roof(origin, turn, Vector2.ZERO, 7.0, 5.8, level + 2.74, 25.0)
	for side: float in [-1.0, 1.0]:
		_put(origin, turn, side * 3.28, -2.62, level, Vector3(0.30, 2.75, 0.31), MapScene.Kind.PLANKS)
		_put(origin, turn, side * 3.28, 2.62, level, Vector3(0.30, 2.75, 0.31), MapScene.Kind.PLANKS)
	for side: float in [-1.0, 1.0]:
		_wall(origin, turn, Vector2(side * 5, -5), Vector2(side * 8, -1), level, 1.0, 0.7, MapScene.Kind.SANDBAG)
		_wall(origin, turn, Vector2(side * 1.5, -6.5), Vector2(side * 4.5, -6), level, 1.0, 0.7, MapScene.Kind.SANDBAG)
		_put(origin, turn, side * 6, 3, level, Vector3(1.2, 1.2, 1.2), MapScene.Kind.WOOD, 0.3)


## Leave the road clear, while the uphill side gives an infantry route under
## cover of trunks and a short breastwork into the hill post.
func _wooded_approach(sign: float) -> void:
	var trees: Array[Vector2] = [
		Vector2(53, 19), Vector2(58, 23), Vector2(67, 25), Vector2(60, 29),
		Vector2(64, 34), Vector2(72, 36), Vector2(70, 43), Vector2(72, 49),
		Vector2(64, 55), Vector2(58, 58), Vector2(52, 55), Vector2(50, 46),
		Vector2(45, 44), Vector2(46, 37), Vector2(36, 38), Vector2(39, 33),
		Vector2(33, 29), Vector2(39, 23),
	]
	for index in trees.size():
		_tree(trees[index] * sign, 0.94 + (index % 4) * 0.09, true)
	var turn := 0.0 if sign > 0 else PI
	for offset: Vector2 in [Vector2(56, 25), Vector2(51, 34), Vector2(45, 41)]:
		var at := _on_ground(Vector3(offset.x, 0, offset.y) * sign)
		_put(at, turn, 0, 0, at.y - 0.18, Vector3(3.0, 1.28, 0.55),
			MapScene.Kind.MASONRY, deg_to_rad(-23.0))


## _bridge is a stone bridge with parapets over the river at x.
func _bridge(x: float) -> void:
	var middle := river_z(x)
	_scene.add_box(Vector3(2.2, 0.25, BRIDGE_HALF), Vector3(x, BRIDGE_DECK - 0.25, middle), Basis(), MapScene.Kind.CONCRETE)
	for side: float in [-1.0, 1.0]:
		_scene.add_box(Vector3(0.2, 0.45, BRIDGE_HALF - 1.5), Vector3(x + side * 2.0, BRIDGE_DECK + 0.45, middle), Basis(), MapScene.Kind.MASONRY)
		_scene.add_box(Vector3(1.2, 1.4, 0.9), Vector3(x, BRIDGE_DECK - 1.6, middle + side * 4), Basis(), MapScene.Kind.MASONRY)
		for bank: float in [-1.0, 1.0]:
			var head := Vector3(x + side * 2.02, BRIDGE_DECK + 0.53, middle + bank * (BRIDGE_HALF - 1.82))
			_scene.add_box(Vector3(0.28, 0.53, 0.37), head, Basis(), MapScene.Kind.MASONRY)
			_scene.add_box(Vector3(0.34, 0.095, 0.43), head + Vector3(0, 0.53, 0), Basis(), MapScene.Kind.SLATE)


## _ruins are the broken walls of a mill by the ford.
func _ruins(origin: Vector3, turn: float) -> void:
	var level := _scene.terrain.height_at(origin.x, origin.z)
	_wall(origin, turn, Vector2(-5, -4), Vector2(3, -4), level - 0.4, 2.6, 0.6, MapScene.Kind.MASONRY, [[2.0, 1.2, 0.0, 2.6], [6.0, 1.0, 1.1, 2.6]])
	_wall(origin, turn, Vector2(-5, -4), Vector2(-5, 3), level - 0.4, 1.8, 0.6, MapScene.Kind.MASONRY, [[4.5, 1.6, 0.0, 1.8]])
	_wall(origin, turn, Vector2(5, 0), Vector2(5, 4), level - 0.4, 1.3, 0.6, MapScene.Kind.MASONRY)
	_put(origin, turn, 1, 1.5, level - 0.2, Vector3(1.6, 0.8, 1.2), MapScene.Kind.ROCK, 0.5)
	_put(origin, turn, -2, 2, level - 0.2, Vector3(1.0, 0.6, 1.4), MapScene.Kind.ROCK, -0.4)
	# A surviving mill chimney sits on the side of the ruins, leaving the
	# direct run through the ford and its exposed banks open.
	_put(origin, turn, 4.25, -3.9, level - 0.45, Vector3(1.35, 4.8, 1.35), MapScene.Kind.MASONRY)
	_put(origin, turn, 4.25, -3.9, level - 0.45,
		Vector3(1.58, 0.30, 1.58), MapScene.Kind.MASONRY, 0.0, 4.8)


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
		Vector2(-45, river_z(-45)), Vector2(-45, -22), Vector2(-52, -36), Vector2(-40, -48), Vector2(-23, -55), Vector2(0, -62)])
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
		_scene.objectives.append(MapScene.Zone.new(village, _on_ground(VILLAGE * sign), 13))
		_scene.objectives.append(MapScene.Zone.new("%s hill" % side, _on_ground(HILL * sign), 7))
		_scene.objectives.append(MapScene.Zone.new("%s ruins" % side, _on_ground(RUINS * sign), 7))
	_scene.flags = [
		MapScene.Zone.new("West Bridge", Vector3(-BRIDGE_X, 0.7, river_z(-BRIDGE_X)), 5),
		MapScene.Zone.new("Ford", _on_ground(Vector3.ZERO), 8),
		MapScene.Zone.new("East Bridge", Vector3(BRIDGE_X, 0.7, river_z(BRIDGE_X)), 5),
	]
	_scene.objectives.append_array(_scene.flags)

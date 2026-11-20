class_name SoldierGrid
extends RefCounted
## SoldierGrid buckets soldiers by horizontal position, so that neighbour
## queries look at a few cells instead of every soldier. It is rebuilt each
## tick. A query fills ids and positions with what it found: the soldiers'
## identifiers and their positions at the last rebuild.

var cell_size: float
var ids := PackedInt32Array()
var positions := PackedVector3Array()
## _cells maps a cell to the indices of its soldiers in _all_ids.
var _cells := {}
var _all_ids := PackedInt32Array()
var _all_positions := PackedVector3Array()
## _low and _high bound the occupied cells.
var _low := Vector2i.ZERO
var _high := Vector2i.ZERO
var _occupied := false
var _visited := {}


func _init(size: float) -> void:
	cell_size = size


func rebuild(soldiers: SoldierSet) -> void:
	_cells.clear()
	_all_ids.resize(0)
	_all_positions.resize(0)
	_occupied = false
	for slot in soldiers.slots():
		var soldier := soldiers.at(slot)
		if soldier == null:
			continue
		var cell := cell_of(soldier.position)
		var bucket: PackedInt32Array = _cells.get(cell, PackedInt32Array())
		bucket.append(_all_ids.size())
		_cells[cell] = bucket
		_all_ids.append(soldier.id)
		_all_positions.append(soldier.position)
		if not _occupied:
			_low = cell
			_high = cell
			_occupied = true
		_low = Vector2i(mini(_low.x, cell.x), mini(_low.y, cell.y))
		_high = Vector2i(maxi(_high.x, cell.x), maxi(_high.y, cell.y))


func cell_of(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / cell_size), floori(position.z / cell_size))


## near finds the soldiers within radius of position, measured horizontally,
## and returns how many.
func near(position: Vector3, radius: float) -> int:
	ids.resize(0)
	positions.resize(0)
	var low := cell_of(position - Vector3(radius, 0, radius))
	var high := cell_of(position + Vector3(radius, 0, radius))
	for x in range(low.x, high.x + 1):
		for z in range(low.y, high.y + 1):
			var bucket: Variant = _cells.get(Vector2i(x, z))
			if bucket == null:
				continue
			for index in bucket:
				var at := _all_positions[index]
				var dx := at.x - position.x
				var dz := at.z - position.z
				if dx * dx + dz * dz <= radius * radius:
					ids.append(_all_ids[index])
					positions.append(at)
	return ids.size()


## along_ray finds the soldiers whose positions lie within margin of the
## horizontal track of a ray from origin along the unit direction, as far as
## length, and returns how many. It walks the track half a cell at a time,
## only through the occupied part of the grid, and looks into every cell
## within the margin of each point.
func along_ray(origin: Vector3, direction: Vector3, length: float, margin: float) -> int:
	ids.resize(0)
	positions.resize(0)
	if not _occupied:
		return 0
	var flat := sqrt(direction.x * direction.x + direction.z * direction.z)
	if flat < 1e-6:
		return near(origin, margin)
	var ux := direction.x / flat
	var uz := direction.z / flat
	var reach := length * flat
	# Clip the track to the occupied cells, widened by the margin.
	var start := 0.0
	var end := reach
	for axis in 2:
		var from := origin.x if axis == 0 else origin.z
		var u := ux if axis == 0 else uz
		var low_edge := float(_low.x if axis == 0 else _low.y) * cell_size - margin
		var high_edge := float((_high.x if axis == 0 else _high.y) + 1) * cell_size + margin
		if absf(u) < 1e-9:
			if from < low_edge or from > high_edge:
				return 0
			continue
		var first := (low_edge - from) / u
		var second := (high_edge - from) / u
		start = maxf(start, minf(first, second))
		end = minf(end, maxf(first, second))
	if start > end:
		return 0
	_visited.clear()
	var step := cell_size / 2
	var box := margin + step / 2
	var along := start
	while true:
		along = minf(along, end)
		var x := origin.x + ux * along
		var z := origin.z + uz * along
		var low := cell_of(Vector3(x - box, 0, z - box))
		var high := cell_of(Vector3(x + box, 0, z + box))
		for cx in range(low.x, high.x + 1):
			for cz in range(low.y, high.y + 1):
				var cell := Vector2i(cx, cz)
				if _visited.has(cell):
					continue
				_visited[cell] = true
				var bucket: Variant = _cells.get(cell)
				if bucket == null:
					continue
				for index in bucket:
					# The distance from the track, clamped to its ends.
					var at := _all_positions[index]
					var dx := at.x - origin.x
					var dz := at.z - origin.z
					var t := clampf(dx * ux + dz * uz, 0.0, reach)
					var ex := dx - ux * t
					var ez := dz - uz * t
					if ex * ex + ez * ez <= margin * margin:
						ids.append(_all_ids[index])
						positions.append(at)
		if along >= end:
			break
		along += step
	return ids.size()

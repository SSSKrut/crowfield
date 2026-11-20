class_name PoseHistory
extends RefCounted
## PoseHistory records every soldier at the end of every tick, by slot, for
## lag compensation: what a hit test needs of a soldier at one tick.

## TICKS keeps a second of poses: more than the limit of lag compensation and
## the reaction delay of bots, which both look into the past.
const TICKS := Game.TICK_RATE

## Every slot keeps TICKS entries; entry i of slot s is at s * TICKS + i.
var _ticks := PackedInt64Array()
var _ids := PackedInt32Array()
var _positions := PackedVector3Array()
var _yaws := PackedFloat32Array()
var _alive := PackedByteArray()


func _init(capacity: int) -> void:
	_ticks.resize(capacity * TICKS)
	_ticks.fill(-1)
	_ids.resize(capacity * TICKS)
	_positions.resize(capacity * TICKS)
	_yaws.resize(capacity * TICKS)
	_alive.resize(capacity * TICKS)


func record(tick: int, soldiers: SoldierSet) -> void:
	var entry := tick % TICKS
	for slot in soldiers.slots():
		var soldier := soldiers.at(slot)
		if soldier == null:
			continue
		var i := slot * TICKS + entry
		_ticks[i] = tick
		_ids[i] = soldier.id
		_positions[i] = soldier.position
		_yaws[i] = soldier.yaw
		_alive[i] = 1 if soldier.alive else 0


## at returns a soldier's pose at a fractional tick, between the two recorded
## ticks around it, as [position, yaw, alive]. It returns [] for times not
## recorded, or recorded for another soldier that had the same slot.
func at(id: int, tick: float) -> Array:
	var whole := floori(tick)
	var earlier := _recorded(id, whole)
	if earlier < 0:
		return []
	var fraction := tick - whole
	if fraction == 0.0:
		return [_positions[earlier], float(_yaws[earlier]), _alive[earlier] == 1]
	var later := _recorded(id, whole + 1)
	if later < 0:
		return []
	var position := _positions[earlier].lerp(_positions[later], fraction)
	var yaw := _yaws[earlier] + Game.remainder(_yaws[later] - _yaws[earlier]) * fraction
	return [position, yaw, _alive[earlier] == 1]


func _recorded(id: int, tick: int) -> int:
	var slot := SoldierSet.slot_of(id)
	if tick < 0 or slot * TICKS >= _ticks.size():
		return -1
	var i := slot * TICKS + tick % TICKS
	if _ids[i] != id or _ticks[i] != tick:
		return -1
	return i

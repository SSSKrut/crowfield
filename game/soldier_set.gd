class_name SoldierSet
extends RefCounted
## SoldierSet stores soldiers in fixed slots. A removed slot is reused with the
## next generation, so stale identifiers stop resolving instead of aliasing a
## newcomer. A soldier identifier packs the slot into its low 12 bits and the
## generation, 1 to 15, into the high 4, so the zero identifier never refers
## to a soldier.

const SLOT_BITS := 12
const MAX_SOLDIERS := 1 << SLOT_BITS
const MAX_GENERATION := (1 << (16 - SLOT_BITS)) - 1

var _soldiers: Array[Soldier] = []
var _generations := PackedInt32Array()
var _free := PackedInt32Array()


static func make_id(slot: int, generation: int) -> int:
	return slot | (generation << SLOT_BITS)


static func slot_of(id: int) -> int:
	return id & (MAX_SOLDIERS - 1)


static func generation_of(id: int) -> int:
	return (id >> SLOT_BITS) & MAX_GENERATION


func _init(capacity: int) -> void:
	assert(capacity > 0 and capacity <= MAX_SOLDIERS)
	_soldiers.resize(capacity)
	_generations.resize(capacity)
	_free.resize(capacity)
	for i in capacity:
		_free[i] = capacity - 1 - i


## add places a soldier in a free slot and gives it its identifier, or
## returns 0 when every slot is taken.
func add(soldier: Soldier) -> int:
	if _free.is_empty():
		return 0
	var slot := _free[_free.size() - 1]
	_free.resize(_free.size() - 1)
	_generations[slot] = _generations[slot] % MAX_GENERATION + 1
	soldier.id = make_id(slot, _generations[slot])
	_soldiers[slot] = soldier
	return soldier.id


func remove(id: int) -> bool:
	var soldier := get_soldier(id)
	if soldier == null:
		return false
	_soldiers[slot_of(id)] = null
	_free.append(slot_of(id))
	return true


func get_soldier(id: int) -> Soldier:
	var slot := slot_of(id)
	if id == 0 or slot >= _soldiers.size():
		return null
	var soldier := _soldiers[slot]
	if soldier == null or soldier.id != id:
		return null
	return soldier


## at returns the soldier in a slot, or null when the slot is free.
func at(slot: int) -> Soldier:
	return _soldiers[slot]


## slots is the capacity of the set: slots run from 0 to slots() - 1.
func slots() -> int:
	return _soldiers.size()


func count() -> int:
	return _soldiers.size() - _free.size()


## all lists every soldier in slot order.
func all() -> Array[Soldier]:
	var list: Array[Soldier] = []
	for soldier in _soldiers:
		if soldier != null:
			list.append(soldier)
	return list

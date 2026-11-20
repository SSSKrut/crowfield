class_name SnapshotPacker
extends RefCounted
## SnapshotPacker fills a snapshot datagram with soldiers up to a size limit.
## Soldiers are taken in any order and kept in slot order; the packer knows the
## exact encoded size all along, although the size of a slot depends on its
## neighbours. It makes no objects, so that snapshots for many players can be
## packed on parallel threads.

var _snapshot: Snapshot
## _slots are the slots of the soldiers added, ascending.
var _slots := PackedInt32Array()
var _bits := 0
var _limit := 0


## reset starts packing into snapshot, whose header, player state and
## removals are set already. Its soldiers are cleared.
func reset(snapshot: Snapshot, limit_bytes: int) -> void:
	snapshot.soldiers.clear()
	snapshot.clear_outgoing()
	_snapshot = snapshot
	_slots.resize(0)
	_bits = snapshot.fixed_bits()
	_limit = limit_bytes * 8


## add packs a soldier's state as a delta from base, sent age datagrams
## earlier, or in full without a usable base, if the datagram still fits the
## limit with it. Each slot may be added once. It works out what the delta
## carries and its size in one pass, as SoldierRecord.delta_fields and
## bits_of do: this is the busiest loop of the server.
func add(state: SoldierState, base: SoldierState, age: int) -> bool:
	if _slots.size() == Snapshot.MAX_SOLDIERS:
		return false
	var slot := state.id & (SoldierSet.MAX_SOLDIERS - 1)
	var i := _slots.bsearch(slot)
	if i < _slots.size() and _slots[i] == slot:
		return false
	var bot := state.bot
	var velocity_bits := 16 if bot else 36
	var angle_bits := 14 if bot else 22
	var fields := 0
	# Generation, the bot flag and the age of the base.
	var bits := 13
	if base == null or age < 1 or age > SoldierRecord.MAX_BASE_AGE or base.id != state.id or base.bot != bot or base.team != state.team:
		age = 0
		base = null
		bits += 2 + 8 + SoldierState.POSITION_BITS + velocity_bits + angle_bits + 4 + 4 + SoldierState.HIT_BITS
	else:
		# The position mode and the six flags of the other fields.
		bits += 8
		if state.position != base.position:
			var width := SoldierRecord.move_width(state.position - base.position)
			if width > SoldierRecord.MAX_MOVE_BITS:
				fields = SoldierRecord.FIELD_POSITION
				bits += SoldierState.POSITION_BITS
			else:
				fields = SoldierRecord.FIELD_MOVE
				bits += 4 + 3 * width
		if state.velocity != base.velocity:
			fields |= SoldierRecord.FIELD_VELOCITY
			bits += velocity_bits
		if state.yaw != base.yaw or state.pitch != base.pitch:
			fields |= SoldierRecord.FIELD_ANGLES
			bits += angle_bits
		if state.flags != base.flags:
			fields |= SoldierRecord.FIELD_FLAGS
			bits += 8
		if state.weapon != base.weapon:
			fields |= SoldierRecord.FIELD_WEAPON
			bits += 4
		if state.shots != base.shots:
			fields |= SoldierRecord.FIELD_SHOTS
			bits += 4
		if state.hit_count != base.hit_count or state.hit_box != base.hit_box or state.hit_yaw != base.hit_yaw:
			fields |= SoldierRecord.FIELD_HIT
			bits += SoldierState.HIT_BITS
	# The slot is the gap after the previous record's: 4 bits short, 13 long;
	# the gap of the next record shrinks.
	var previous := _slots[i - 1] if i > 0 else -1
	var added := bits + (4 if slot - previous - 1 < 8 else 13)
	if i < _slots.size():
		var next := _slots[i]
		added += (4 if next - slot - 1 < 8 else 13) - (4 if next - previous - 1 < 8 else 13)
	if _bits + added > _limit:
		return false
	_slots.insert(i, slot)
	_snapshot.out_states.insert(i, state)
	_snapshot.out_bases.insert(i, base)
	_snapshot.out_meta.insert(i, age | (fields << 8))
	_bits += added
	return true


## count is how many soldiers the datagram holds.
func count() -> int:
	return _slots.size()


## finish returns the size the snapshot will encode to.
func finish() -> int:
	return (_bits + 7) / 8

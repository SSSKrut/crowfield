class_name Snapshot
extends RefCounted
## Snapshot is one server datagram. A snapshot of the world may take several,
## and a soldier missing from one is not removed: the server sends each
## soldier as often as its priority asks, and removal is explicit.

const MAX_SOLDIERS := 1023
const MAX_REMOVED := 255
## BUDGET is the size of the largest snapshot datagram; it leaves room below
## the transport limit (ARCHITECTURE.md, 6.6).
const BUDGET := 1100
const _SOLDIER_COUNT_BITS := 10
const _REMOVED_COUNT_BITS := 8

## sequence numbers every datagram; deltas name their base by it.
var sequence := 0
var server_tick := 0
var player := PlayerState.new()
## soldiers are in ascending slot order, which keeps their identifiers short.
## SnapshotPacker builds them so.
var soldiers: Array[SoldierRecord] = []
var removed := PackedInt32Array()
## The records a SnapshotPacker added, kept without record objects, in slot
## order: the state, the base of a delta or null for a full record, and the
## age of the base with what the delta carries, packed as age | fields << 8.
var out_states: Array[SoldierState] = []
var out_bases: Array[SoldierState] = []
var out_meta := PackedInt32Array()


func clear_outgoing() -> void:
	out_states.clear()
	out_bases.clear()
	out_meta.resize(0)


func type() -> int:
	return Protocol.Type.SNAPSHOT


## fixed_bits is the size of everything but the soldier records.
func fixed_bits() -> int:
	return 8 + 16 + 32 + player.bits() + _SOLDIER_COUNT_BITS + _REMOVED_COUNT_BITS + 16 * removed.size()


func write(w: BitWriter) -> String:
	if soldiers.size() > MAX_SOLDIERS or out_states.size() > MAX_SOLDIERS or removed.size() > MAX_REMOVED:
		return "snapshot with %d soldiers and %d removals is too large" % [maxi(soldiers.size(), out_states.size()), removed.size()]
	if not soldiers.is_empty() and not out_states.is_empty():
		return "a snapshot has either records or packed states"
	var error := player.validate()
	if error != "":
		return error
	# The records are built from checked states (SoldierState.create) or
	# decoded and checked; only their order is checked here.
	var previous := -1
	for record in soldiers:
		var slot := SoldierSet.slot_of(record.state.id)
		if slot <= previous:
			return "snapshot soldiers must be in ascending slot order"
		previous = slot
	for id in removed:
		if SoldierSet.generation_of(id) == 0:
			return "removed soldier 0x%04x has no generation" % id
	w.write_bits(sequence, 16)
	w.write_bits(server_tick, 32)
	player.write(w)
	if not out_states.is_empty():
		w.write_bits(out_states.size(), _SOLDIER_COUNT_BITS)
		previous = -1
		for i in out_states.size():
			var state := out_states[i]
			var meta := out_meta[i]
			var fields := (meta >> 8) & 0xFF
			var moved := Vector3i.ZERO
			if fields & SoldierRecord.FIELD_MOVE:
				moved = state.position - out_bases[i].position
			SoldierRecord.write_of(w, previous, state, meta & 0xFF, fields, moved)
			previous = state.id & (SoldierSet.MAX_SOLDIERS - 1)
	else:
		w.write_bits(soldiers.size(), _SOLDIER_COUNT_BITS)
		previous = -1
		for record in soldiers:
			record.write(w, previous)
			previous = SoldierSet.slot_of(record.state.id)
	w.write_bits(removed.size(), _REMOVED_COUNT_BITS)
	for id in removed:
		w.write_bits(id, 16)
	return ""


func read(r: BitReader) -> void:
	sequence = r.read_bits(16)
	server_tick = r.read_bits(32)
	player.read(r)
	soldiers.clear()
	removed.resize(0)
	var count := r.read_bits(_SOLDIER_COUNT_BITS)
	if count * SoldierRecord.MIN_RECORD_BITS > r.remaining():
		r.fail(BitReader.SHORT_MESSAGE)
	var previous := -1
	for i in count:
		if r.error != "":
			break
		var record := SoldierRecord.new()
		record.read(r, previous)
		soldiers.append(record)
		previous = SoldierSet.slot_of(record.state.id)
	var removed_count := r.read_bits(_REMOVED_COUNT_BITS)
	for i in removed_count:
		var id := r.read_bits(16)
		if r.error != "":
			break
		if SoldierSet.generation_of(id) == 0:
			r.fail("removed soldier has no generation")
		removed.append(id)

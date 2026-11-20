class_name SoldierRecord
extends RefCounted
## SoldierRecord is a soldier in a snapshot datagram: its full state, or a delta
## that carries only what changed since a base the client acknowledged.

## BASE_HISTORY is how many recent states of a soldier both ends keep for
## deltas. The server builds a delta only on one of the last BASE_HISTORY states
## it sent of a soldier, and the client keeps the BASE_HISTORY newest it
## received, so a base the client acknowledged is always still there.
const BASE_HISTORY := 8
const BASE_BITS := 8
## MAX_BASE_AGE is the oldest base a delta can name, in datagrams.
const MAX_BASE_AGE := (1 << BASE_BITS) - 1
## A slot is written as the gap after the previous record's slot: short gaps,
## the usual case, take 3 bits, the rest 12.
const SHORT_GAP_BITS := 3
const LONG_GAP_BITS := 12
const GENERATION_BITS := 4
## A position difference is written with the fewest bits that hold all three
## components, up to MAX_MOVE_BITS each.
const MOVE_WIDTH_BITS := 4
const MAX_MOVE_BITS := 1 << MOVE_WIDTH_BITS
## MIN_RECORD_BITS is the smallest record: a delta that changes nothing.
const MIN_RECORD_BITS := 1 + SHORT_GAP_BITS + GENERATION_BITS + 1 + BASE_BITS + 2 + 6

## Position modes of a delta record.
const POSITION_KEPT := 0
const POSITION_MOVED := 1
const POSITION_FULL := 2

## What a delta record carries. FIELD_POSITION carries the whole position and
## FIELD_MOVE its difference from the base; a delta has at most one of them.
const FIELD_POSITION := 1
const FIELD_MOVE := 2
const FIELD_VELOCITY := 4
const FIELD_ANGLES := 8
const FIELD_FLAGS := 16
const FIELD_WEAPON := 32
const FIELD_SHOTS := 64
const FIELD_HIT := 128
const KNOWN_FIELDS := FIELD_HIT * 2 - 1

const MISSING_BASE := "the base of a delta is missing"

## state has the identity of the soldier and the values of the fields the
## record carries; a decoded delta leaves the other fields zero.
var state: SoldierState
## base is how many datagrams before this one the base was sent. Zero makes a
## full record, which needs no base.
var base := 0
var fields := 0
## move is the position minus the base position, with FIELD_MOVE.
var move := Vector3i.ZERO


## create describes state as a delta from base_state, which was sent age
## datagrams earlier, or in full when there is no usable base.
static func create(current: SoldierState, base_state: SoldierState, age: int) -> SoldierRecord:
	var record := SoldierRecord.new()
	record.state = current
	var delta := delta_fields(current, base_state, age)
	if delta < 0:
		return record
	record.base = age
	record.fields = delta
	if delta & FIELD_MOVE:
		record.move = current.position - base_state.position
	return record


## delta_fields returns what a delta of current from base_state, sent age
## datagrams earlier, carries, or -1 when the base cannot serve and the
## record must be full.
static func delta_fields(current: SoldierState, base_state: SoldierState, age: int) -> int:
	if base_state == null or age < 1 or age > MAX_BASE_AGE or base_state.id != current.id \
			or base_state.bot != current.bot or base_state.team != current.team:
		return -1
	var delta := 0
	if current.position != base_state.position:
		delta = FIELD_POSITION if move_width(current.position - base_state.position) > MAX_MOVE_BITS else FIELD_MOVE
	if current.velocity != base_state.velocity:
		delta |= FIELD_VELOCITY
	if current.yaw != base_state.yaw or current.pitch != base_state.pitch:
		delta |= FIELD_ANGLES
	if current.flags != base_state.flags:
		delta |= FIELD_FLAGS
	if current.weapon != base_state.weapon:
		delta |= FIELD_WEAPON
	if current.shots != base_state.shots:
		delta |= FIELD_SHOTS
	if current.hit_count != base_state.hit_count or current.hit_box != base_state.hit_box or current.hit_yaw != base_state.hit_yaw:
		delta |= FIELD_HIT
	return delta


## resolve returns the state the record describes: its own for a full record,
## or the base with the carried fields replaced. It returns the error as a
## String when the base does not fit.
func resolve(base_state: SoldierState) -> Variant:
	if base == 0:
		return state
	if base_state == null or base_state.id != state.id or base_state.bot != state.bot:
		return "soldier 0x%04x: %s" % [state.id, MISSING_BASE]
	var resolved := base_state.copy()
	if fields & FIELD_POSITION:
		resolved.position = state.position
	if fields & FIELD_MOVE:
		resolved.position += move
	if fields & FIELD_VELOCITY:
		resolved.velocity = state.velocity
	if fields & FIELD_ANGLES:
		resolved.yaw = state.yaw
		resolved.pitch = state.pitch
	if fields & FIELD_FLAGS:
		resolved.flags = state.flags
	if fields & FIELD_WEAPON:
		resolved.weapon = state.weapon
	if fields & FIELD_SHOTS:
		resolved.shots = state.shots
	if fields & FIELD_HIT:
		resolved.hit_count = state.hit_count
		resolved.hit_box = state.hit_box
		resolved.hit_yaw = state.hit_yaw
	var error := resolved.validate()
	if error != "":
		return error
	return resolved


func validate() -> String:
	var error := state.validate()
	if error != "" or base == 0:
		return error
	if fields & ~KNOWN_FIELDS:
		return "soldier 0x%04x: unknown record fields 0x%x" % [state.id, fields]
	if fields & FIELD_POSITION and fields & FIELD_MOVE:
		return "soldier 0x%04x: a delta has both a position and a move" % state.id
	if fields & FIELD_MOVE and (move == Vector3i.ZERO or move_width(move) > MAX_MOVE_BITS):
		return "soldier 0x%04x: move %s is empty or too long" % [state.id, move]
	return ""


## body_bits is the size of the record after its slot gap.
func body_bits() -> int:
	return bits_of(state, base, fields, move)


## bits_of is the size after its slot gap of a record of state s: full with a
## zero age, otherwise a delta carrying fields with the given move.
static func bits_of(s: SoldierState, age: int, delta: int, moved: Vector3i) -> int:
	var bits := GENERATION_BITS + 1 + BASE_BITS
	var velocity := 2 * SoldierState.BOT_VELOCITY_BITS if s.bot else 3 * SoldierState.VELOCITY_BITS
	var angles := SoldierState.BOT_YAW_BITS + SoldierState.BOT_PITCH_BITS if s.bot else SoldierState.YAW_BITS + SoldierState.PITCH_BITS
	if age == 0:
		return bits + Protocol.TEAM_BITS + SoldierState.FLAGS_BITS + SoldierState.POSITION_BITS + velocity \
			+ angles + Protocol.WEAPON_BITS + SoldierState.SHOTS_BITS + SoldierState.HIT_BITS
	bits += 2 + 6
	if delta & FIELD_POSITION:
		bits += SoldierState.POSITION_BITS
	elif delta & FIELD_MOVE:
		bits += MOVE_WIDTH_BITS + 3 * move_width(moved)
	if delta & FIELD_VELOCITY:
		bits += velocity
	if delta & FIELD_ANGLES:
		bits += angles
	if delta & FIELD_FLAGS:
		bits += SoldierState.FLAGS_BITS
	if delta & FIELD_WEAPON:
		bits += Protocol.WEAPON_BITS
	if delta & FIELD_SHOTS:
		bits += SoldierState.SHOTS_BITS
	if delta & FIELD_HIT:
		bits += SoldierState.HIT_BITS
	return bits


## write writes the record after one for slot previous, or first with -1.
func write(w: BitWriter, previous: int) -> void:
	write_of(w, previous, state, base, fields, move)


## write_of writes a record of state s, as bits_of describes it. Neighbouring
## fields go into one call of the writer where they fit; the bits are the same
## as field by field.
static func write_of(w: BitWriter, previous: int, s: SoldierState, base: int, fields: int, move: Vector3i) -> void:
	var gap := SoldierSet.slot_of(s.id) - previous - 1
	var tail := SoldierSet.generation_of(s.id) | (int(s.bot) << 4) | (base << 5)
	if gap >= 1 << SHORT_GAP_BITS:
		w.write_bits(1 | (gap << 1) | (tail << 13), 26)
	else:
		w.write_bits((gap << 1) | (tail << 4), 17)
	if base == 0:
		w.write_bits(s.team | (s.flags << 2) | ((s.position.x & 0x1FFFFF) << 10), 31)
		w.write_bits(s.position.y & 0x7FFFF, 19)
		w.write_bits(s.position.z & 0x1FFFFF, 21)
		_write_velocity(w, s)
		_write_angles(w, s)
		w.write_bits(s.weapon | (s.shots << 4) | (s.hit_count << 8) | (s.hit_box << 11) | (s.hit_yaw << 14), 20)
		return
	if fields & FIELD_POSITION:
		w.write_bits(POSITION_FULL | ((s.position.x & 0x1FFFFF) << 2), 23)
		w.write_bits(s.position.y & 0x7FFFF, 19)
		w.write_bits(s.position.z & 0x1FFFFF, 21)
	elif fields & FIELD_MOVE:
		var width := move_width(move)
		var mask := (1 << width) - 1
		w.write_bits(POSITION_MOVED | ((width - 1) << 2) | ((move.x & mask) << 6), 6 + width)
		w.write_bits((move.y & mask) | ((move.z & mask) << width), 2 * width)
	else:
		w.write_bits(POSITION_KEPT, 2)
	if fields & FIELD_VELOCITY:
		w.write_bits(1, 1)
		_write_velocity(w, s)
	else:
		w.write_bits(0, 1)
	if fields & FIELD_ANGLES:
		w.write_bits(1, 1)
		_write_angles(w, s)
	else:
		w.write_bits(0, 1)
	var rest := 0
	var bits := 1
	if fields & FIELD_FLAGS:
		rest = 1 | (s.flags << 1)
		bits = 9
	if fields & FIELD_WEAPON:
		rest |= (1 | (s.weapon << 1)) << bits
		bits += 5
	else:
		bits += 1
	if fields & FIELD_SHOTS:
		rest |= (1 | (s.shots << 1)) << bits
		bits += 5
	else:
		bits += 1
	if fields & FIELD_HIT:
		rest |= 1 << bits
		w.write_bits(rest, bits + 1)
		w.write_bits(s.hit_count | (s.hit_box << 3) | (s.hit_yaw << 6), SoldierState.HIT_BITS)
		return
	w.write_bits(rest, bits + 1)


static func _write_velocity(w: BitWriter, s: SoldierState) -> void:
	if s.bot:
		w.write_bits(((s.velocity.x / SoldierState.BOT_VELOCITY_STEP) & 0xFF) | (((s.velocity.z / SoldierState.BOT_VELOCITY_STEP) & 0xFF) << 8), 16)
		return
	w.write_bits((s.velocity.x & 0xFFF) | ((s.velocity.y & 0xFFF) << 12), 24)
	w.write_bits(s.velocity.z & 0xFFF, 12)


static func _write_angles(w: BitWriter, s: SoldierState) -> void:
	if s.bot:
		w.write_bits((s.yaw / SoldierState.BOT_ANGLE_STEP) | (((s.pitch / SoldierState.BOT_ANGLE_STEP) & 0x3F) << 8), 14)
		return
	w.write_bits(s.yaw | ((s.pitch & 0x3FF) << 12), 22)


## read reads a record into a fresh one. Every value has one encoding: a long
## gap that would fit the short form and a move wider than needed are rejected.
func read(r: BitReader, previous: int) -> void:
	state = SoldierState.new()
	var s := state
	var gap := 0
	if r.read_bits(1) == 1:
		gap = r.read_bits(LONG_GAP_BITS)
		if gap < 1 << SHORT_GAP_BITS:
			r.fail("a short slot gap is written long")
	else:
		gap = r.read_bits(SHORT_GAP_BITS)
	var slot := previous + 1 + gap
	if slot >= SoldierSet.MAX_SOLDIERS:
		r.fail("slot %d is out of range" % slot)
	var tail := r.read_bits(13)
	s.id = SoldierSet.make_id(slot & (SoldierSet.MAX_SOLDIERS - 1), tail & 0xF)
	s.bot = (tail >> 4) & 1 == 1
	base = tail >> 5
	if base == 0:
		var head := r.read_bits(31)
		s.team = head & 3
		s.flags = (head >> 2) & 0xFF
		s.position = Vector3i(_signed(head >> 10, 21), r.read_signed(19), r.read_signed(21))
		_read_velocity(r, s)
		_read_angles(r, s)
		var last := r.read_bits(20)
		s.weapon = last & 0xF
		s.shots = (last >> 4) & 0xF
		s.hit_count = (last >> 8) & 7
		s.hit_box = (last >> 11) & 7
		s.hit_yaw = (last >> 14) & 0x3F
	else:
		match r.read_bits(2):
			POSITION_KEPT:
				pass
			POSITION_MOVED:
				fields |= FIELD_MOVE
				var width := r.read_bits(MOVE_WIDTH_BITS) + 1
				var x := r.read_signed(width)
				var y := r.read_signed(width)
				move = Vector3i(x, y, r.read_signed(width))
				if r.error == "" and move_width(move) != width:
					r.fail("a move is written wider than needed")
			POSITION_FULL:
				fields |= FIELD_POSITION
				var x := r.read_signed(21)
				var y := r.read_signed(19)
				s.position = Vector3i(x, y, r.read_signed(21))
			_:
				r.fail("unknown position mode")
		if r.read_bits(1) == 1:
			fields |= FIELD_VELOCITY
			_read_velocity(r, s)
		if r.read_bits(1) == 1:
			fields |= FIELD_ANGLES
			_read_angles(r, s)
		if r.read_bits(1) == 1:
			fields |= FIELD_FLAGS
			s.flags = r.read_bits(SoldierState.FLAGS_BITS)
		if r.read_bits(1) == 1:
			fields |= FIELD_WEAPON
			s.weapon = r.read_bits(Protocol.WEAPON_BITS)
		if r.read_bits(1) == 1:
			fields |= FIELD_SHOTS
			s.shots = r.read_bits(SoldierState.SHOTS_BITS)
		if r.read_bits(1) == 1:
			fields |= FIELD_HIT
			var hit := r.read_bits(SoldierState.HIT_BITS)
			s.hit_count = hit & 7
			s.hit_box = (hit >> 3) & 7
			s.hit_yaw = (hit >> 6) & 0x3F
	if r.error == "":
		var error := validate()
		if error != "":
			r.fail(error)


static func _read_velocity(r: BitReader, s: SoldierState) -> void:
	if s.bot:
		var both := r.read_bits(16)
		s.velocity = Vector3i(_signed(both & 0xFF, 8) * SoldierState.BOT_VELOCITY_STEP, 0, _signed(both >> 8, 8) * SoldierState.BOT_VELOCITY_STEP)
		return
	var xy := r.read_bits(24)
	s.velocity = Vector3i(_signed(xy & 0xFFF, 12), _signed(xy >> 12, 12), r.read_signed(12))


static func _read_angles(r: BitReader, s: SoldierState) -> void:
	if s.bot:
		var both := r.read_bits(14)
		s.yaw = (both & 0xFF) * SoldierState.BOT_ANGLE_STEP
		s.pitch = _signed(both >> 8, 6) * SoldierState.BOT_ANGLE_STEP
		return
	var angles := r.read_bits(22)
	s.yaw = angles & 0xFFF
	s.pitch = _signed(angles >> 12, 10)


static func _signed(value: int, bits: int) -> int:
	if value >= 1 << (bits - 1):
		return value - (1 << bits)
	return value


static func slot_bits(gap: int) -> int:
	return 1 + (SHORT_GAP_BITS if gap < 1 << SHORT_GAP_BITS else LONG_GAP_BITS)


## move_width is the fewest bits that hold every component as a signed value.
static func move_width(value: Vector3i) -> int:
	var largest := maxi(maxi(value.x if value.x >= 0 else -value.x - 1, value.y if value.y >= 0 else -value.y - 1),
		value.z if value.z >= 0 else -value.z - 1)
	var width := 1
	while width < 32 and largest >> (width - 1) != 0:
		width += 1
	return width

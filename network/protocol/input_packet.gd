class_name InputPacket
extends RefCounted
## InputPacket is the client's datagram for one tick. It repeats the newest
## commands, so a lost datagram is covered by the next one, and acknowledges
## the snapshot datagrams received so far.

## MAX_COMMANDS limits how many recent commands one datagram repeats.
const MAX_COMMANDS := 8
const _COUNT_BITS := 4

var has_ack := false
## ack_sequence is the newest snapshot datagram received; bit i of ack_bits is
## set when ack_sequence - 1 - i was received too.
var ack_sequence := 0
var ack_bits := 0
## commands have consecutive ticks, oldest first.
var commands: Array[InputCommand] = []


func type() -> int:
	return Protocol.Type.INPUT


func write(w: BitWriter) -> String:
	if commands.size() > MAX_COMMANDS:
		return "%d commands in one input, at most %d" % [commands.size(), MAX_COMMANDS]
	for i in commands.size():
		if commands[i].tick != commands[0].tick + i:
			return "input commands must have consecutive ticks"
		if commands[i].weapon < 0 or commands[i].weapon >= 1 << Protocol.WEAPON_BITS:
			return "weapon slot %d is out of range" % commands[i].weapon
	w.write_bool(has_ack)
	if has_ack:
		w.write_bits(ack_sequence, 16)
		w.write_bits(ack_bits, 32)
	w.write_bits(commands.size(), _COUNT_BITS)
	if not commands.is_empty():
		w.write_bits(commands[0].tick, 32)
	for command in commands:
		w.write_signed(command.move_forward, 8)
		w.write_signed(command.move_right, 8)
		w.write_bits(command.yaw, 16)
		w.write_signed(command.pitch, 16)
		w.write_bits(command.buttons, 16)
		w.write_bits(command.weapon, Protocol.WEAPON_BITS)
		w.write_bits(command.view_delta, 8)
		w.write_bits(command.view_frac, 8)
	return ""


func read(r: BitReader) -> void:
	has_ack = r.read_bool()
	ack_sequence = 0
	ack_bits = 0
	if has_ack:
		ack_sequence = r.read_bits(16)
		ack_bits = r.read_bits(32)
	var count := r.read_bits(_COUNT_BITS)
	if count > MAX_COMMANDS:
		r.fail("%d commands in one input, at most %d" % [count, MAX_COMMANDS])
	commands.clear()
	if count == 0 or r.error != "":
		return
	var first := r.read_bits(32)
	for i in count:
		var command := InputCommand.new()
		command.tick = first + i
		command.move_forward = r.read_signed(8)
		command.move_right = r.read_signed(8)
		command.yaw = r.read_bits(16)
		command.pitch = r.read_signed(16)
		command.buttons = r.read_bits(16)
		command.weapon = r.read_bits(Protocol.WEAPON_BITS)
		command.view_delta = r.read_bits(8)
		command.view_frac = r.read_bits(8)
		commands.append(command)

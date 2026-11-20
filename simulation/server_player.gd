class_name ServerPlayer
extends RefCounted
## ServerPlayer is a human in the server: its connection, its soldier, the
## commands waiting for their ticks, and what its client has been told about
## every soldier slot.

## INPUT_WINDOW is how far ahead of the server a command may arrive: one
## second.
const INPUT_WINDOW := Game.TICK_RATE
## ACK_WINDOW is how many recent datagrams the server remembers
## acknowledgements of; it covers the oldest base a delta can name.
const ACK_WINDOW := SoldierRecord.MAX_BASE_AGE + 1

var id := 0
var name := ""
var team: int = Game.Team.NONE
var token := PackedByteArray()
var conn: Conn
var ready := false
var soldier := 0
var controller: CharacterController
## respawn_at is the tick when a dead soldier of the player comes back.
var respawn_at := 0

var last_input := 0.0
var last := InputCommand.new()
var processed := false
var last_processed := 0
## newest is the tick of the last command the client sent, as of the latest
## input packet, if has_input. After the client's clock jumps back it is the
## new clock, not the largest tick ever sent.
var newest := 0
var has_input := false
var lead := PlayerState.NO_INPUT

## views is what the player was told about each soldier slot.
var views: Array[EntityView] = []
var removals: Array[PendingRemoval] = []
## candidates are the slots to send in the next snapshot, by priority.
var candidates := PackedInt64Array()
## datagrams counts the snapshot datagrams sent; its low 16 bits are the
## sequence of the next one. acks holds, by datagram number modulo the
## window, the number plus one of each acknowledged datagram.
var datagrams := 0
var acks := PackedInt64Array()
## allowance is how many bytes the budget of the player still allows.
var allowance := 0.0
## outbox holds the snapshot datagrams built for the player, which the main
## thread sends, and outbox_bytes what they cost on the wire. snapshot and
## packer are the player's own, so that players are served in parallel.
var outbox: Array[PackedByteArray] = []
var outbox_bytes := 0
var snapshot := Snapshot.new()
var packer := SnapshotPacker.new()

var _inputs: Array[InputCommand] = []


func _init(number: int, player_name: String, slots: int) -> void:
	id = number
	name = player_name
	token = Crypto.new().generate_random_bytes(16)
	views.resize(slots)
	for i in slots:
		views[i] = EntityView.new()
	acks.resize(ACK_WINDOW)
	_inputs.resize(INPUT_WINDOW)


## put accepts commands for the current tick and up to a second ahead. Late
## commands are useless and commands from the far future would block slots.
## Each datagram repeats several recent commands; the copies land in the same
## slot.
func put_input(command: InputCommand, current: int) -> bool:
	if command.tick < current or command.tick - current >= INPUT_WINDOW:
		return false
	_inputs[command.tick % INPUT_WINDOW] = command
	return true


## take_input returns the command for a tick, or null.
func take_input(tick: int) -> InputCommand:
	var slot := tick % INPUT_WINDOW
	var command := _inputs[slot]
	_inputs[slot] = null
	if command != null and command.tick == tick:
		return command
	return null


## acknowledge records the snapshot datagrams an input packet confirms.
func acknowledge(packet: InputPacket) -> void:
	if not packet.has_ack or datagrams == 0:
		return
	_ack(packet.ack_sequence)
	for i in 32:
		if packet.ack_bits & (1 << i):
			_ack((packet.ack_sequence - 1 - i) & 0xFFFF)


## _ack marks a datagram by its sequence, if it is among the recent ones sent.
func _ack(sequence: int) -> void:
	var latest := datagrams - 1
	var back := ((latest & 0xFFFF) - sequence) & 0xFFFF
	if back >= ACK_WINDOW or back > latest:
		return
	var datagram := latest - back
	acks[datagram % ACK_WINDOW] = datagram + 1


func acknowledged(datagram: int) -> bool:
	return datagrams - datagram <= ACK_WINDOW and acks[datagram % ACK_WINDOW] == datagram + 1


func removal_delivered(removal: PendingRemoval) -> bool:
	for sent in removal.sends:
		if sent != 0 and acknowledged(sent - 1):
			return true
	return false


## EntityView is what a client has been told about one soldier slot.
class EntityView:
	## id is the soldier the client is being told about; zero for none.
	var id := 0
	var priority := 0.0
	## The newest states sent, the possible bases of a delta: the datagram of
	## each, and the state.
	var datagrams := PackedInt64Array([-1, -1, -1, -1, -1, -1, -1, -1])
	var states: Array[SoldierState] = [null, null, null, null, null, null, null, null]
	var next := 0

	func reset(soldier: int) -> void:
		id = soldier
		priority = 0.0
		datagrams.fill(-1)
		states.fill(null)
		next = 0

	func ever_sent() -> bool:
		return datagrams[0] >= 0

	## latest is the state last sent, or null.
	func latest() -> SoldierState:
		return states[(next + SoldierRecord.BASE_HISTORY - 1) % SoldierRecord.BASE_HISTORY]

	func sent(datagram: int, state: SoldierState) -> void:
		datagrams[next] = datagram
		states[next] = state
		next = (next + 1) % SoldierRecord.BASE_HISTORY
		priority = 0.0

	## base_age picks the base of a delta: the newest state the client
	## acknowledged, which it leaves in base. It returns how many datagrams ago
	## the base was sent, or zero for none, when the soldier goes in full.
	func base_age(player: ServerPlayer) -> int:
		base = null
		# From the newest send back: the first acknowledged one is the newest.
		var sent := player.datagrams
		var acks := player.acks
		for back in SoldierRecord.BASE_HISTORY:
			var i := (next - 1 - back + SoldierRecord.BASE_HISTORY) % SoldierRecord.BASE_HISTORY
			var datagram := datagrams[i]
			if datagram < 0:
				return 0
			if sent - datagram > ServerPlayer.ACK_WINDOW:
				return 0
			if acks[datagram % ServerPlayer.ACK_WINDOW] == datagram + 1:
				base = states[i]
				return sent - datagram
		return 0

	## base is the state base_age picked last.
	var base: SoldierState


## PendingRemoval is a soldier the client knows of and that is gone. It is
## repeated in every snapshot until a datagram carrying it is acknowledged.
class PendingRemoval:
	var id := 0
	## sends are datagram numbers plus one; zero for none.
	var sends := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0])
	var next := 0

	func _init(soldier: int) -> void:
		id = soldier

	func sent(datagram: int) -> void:
		sends[next] = datagram + 1
		next = (next + 1) % sends.size()

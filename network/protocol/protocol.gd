class_name Protocol
## Protocol defines the binary encoding of every network message. Each message
## writes its fields explicitly, so changing a class never changes the wire
## format by accident; any encoding change bumps VERSION.
##
## Decoding is strict: a message that decodes without error encodes back to
## the same bytes. Values that are valid on the wire but break game rules are
## not rejected here; the receiver sanitizes them (InputCommand.sanitize).
##
## A message implements type(), write(writer) -> error and read(reader); see
## Messages for the small ones.

const VERSION := 12

enum Type {
	HELLO = 1, WELCOME, REJECT, READY, INPUT, SNAPSHOT, RESPAWN, HIT_CONFIRM, DAMAGE, DEATH,
	CERTIFICATE_REQUEST, CERTIFICATE,
}
const _TYPE_NAMES := {
	Type.HELLO: "hello", Type.WELCOME: "welcome", Type.REJECT: "reject", Type.READY: "ready",
	Type.INPUT: "input", Type.SNAPSHOT: "snapshot", Type.RESPAWN: "respawn", Type.HIT_CONFIRM: "hit confirm",
	Type.DAMAGE: "damage", Type.DEATH: "death", Type.CERTIFICATE_REQUEST: "certificate request",
	Type.CERTIFICATE: "certificate",
}

const UNKNOWN_MESSAGE := "unknown message type"

## QUIT_REASON closes the connection of a player who leaves on purpose: the
## server frees the place at once instead of keeping it for a return.
const QUIT_REASON := "player quit"

const MAX_NAME_BYTES := 32
const MAX_PASSWORD_BYTES := 64
const MAX_MAP_BYTES := 64
const MAX_REJECT_MESSAGE_BYTES := 255
const NAME_LENGTH_BITS := 6
const PASSWORD_LENGTH_BITS := 7
const MAP_LENGTH_BITS := 7
const REJECT_LENGTH_BITS := 8
const PLAYER_BITS := 4
const TEAM_BITS := 2
const WEAPON_BITS := 4
const ZONE_BITS := 2


static func type_name(type: int) -> String:
	return _TYPE_NAMES.get(type, "message %d" % type)


## peek_type returns the type of an encoded message, or -1 when it has none
## or an unknown one.
static func peek_type(data: PackedByteArray) -> int:
	if data.is_empty() or not _TYPE_NAMES.has(data[0]):
		return -1
	return data[0]


## create returns an empty message of a type to decode into, or null.
static func create(type: int) -> Object:
	match type:
		Type.HELLO:
			return Messages.Hello.new()
		Type.WELCOME:
			return Messages.Welcome.new()
		Type.REJECT:
			return Messages.Reject.new()
		Type.READY:
			return Messages.Ready.new()
		Type.INPUT:
			return InputPacket.new()
		Type.SNAPSHOT:
			return Snapshot.new()
		Type.RESPAWN:
			return Messages.Respawn.new()
		Type.HIT_CONFIRM:
			return Messages.HitConfirm.new()
		Type.DAMAGE:
			return Messages.Damage.new()
		Type.DEATH:
			return Messages.Death.new()
		Type.CERTIFICATE_REQUEST:
			return Messages.CertificateRequest.new()
		Type.CERTIFICATE:
			return Messages.Certificate.new()
	return null


## encode returns the bytes of a message, or an empty array when the message
## cannot be encoded; error_of tells why.
static func encode(message: Object) -> PackedByteArray:
	var writer := BitWriter.new()
	writer.write_bits(message.type(), 8)
	var error: String = message.write(writer)
	if error != "":
		push_error("encode %s: %s" % [type_name(message.type()), error])
		return PackedByteArray()
	return writer.bytes()


## encode_error returns why a message cannot be encoded, or "".
static func encode_error(message: Object) -> String:
	var writer := BitWriter.new()
	writer.write_bits(message.type(), 8)
	return message.write(writer)


## decode replaces message with the one in data and returns an error, or "".
static func decode_into(message: Object, data: PackedByteArray) -> String:
	var reader := BitReader.start(data, message.type())
	message.read(reader)
	return reader.finish()


## decode returns the message in data, or the error as a String.
static func decode(data: PackedByteArray) -> Variant:
	var message := create(peek_type(data))
	if message == null:
		return UNKNOWN_MESSAGE
	var error := decode_into(message, data)
	if error != "":
		return error
	return message


## check_text returns an error unless value is UTF-8 of at most max_bytes.
static func check_text(field: String, value: String, max_bytes: int) -> String:
	var bytes := value.to_utf8_buffer()
	if bytes.size() > max_bytes or not BitReader.valid_utf8(bytes):
		return "%s must be UTF-8 of at most %d bytes" % [field, max_bytes]
	return ""


static func check_soldier(role: String, id: int) -> String:
	if SoldierSet.generation_of(id) == 0:
		return "%s 0x%04x has no generation" % [role, id]
	return ""


static func read_soldier(reader: BitReader) -> int:
	var id := reader.read_bits(16)
	if reader.error == "" and SoldierSet.generation_of(id) == 0:
		reader.fail("soldier 0x%04x has no generation" % id)
	return id


static func fits_signed(value: int, bits: int) -> bool:
	var limit := 1 << (bits - 1)
	return value >= -limit and value < limit

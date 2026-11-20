class_name BitReader
extends RefCounted
## BitReader reads fields written by BitWriter. The first error sticks and
## later reads return zero, so a decoder reads every field and checks finish
## once. Errors are messages; the empty string means none.

const SHORT_MESSAGE := "message ends before its last field"
const TRAILING_DATA := "message has data after its last field"
const INVALID_TEXT := "text is too long or not UTF-8"
const INVALID_FLOAT := "number is not finite"

var error := ""
## _data is the message with eight zero bytes after it, so that every read
## takes one 64-bit word; _bits is the size of the message itself.
var _data: PackedByteArray
var _bits := 0
var _position := 0
var _scratch := PackedByteArray([0, 0, 0, 0])


func _init(data: PackedByteArray = PackedByteArray()) -> void:
	_bits = data.size() * 8
	_data = data.duplicate()
	_data.resize(data.size() + 8)


## start reads the type byte of a message and checks it is the one expected.
static func start(data: PackedByteArray, type: int) -> BitReader:
	var reader := BitReader.new(data)
	var got := reader.read_bits(8)
	if reader.error == "" and got != type:
		reader.fail("expected %s, got %s" % [Protocol.type_name(type), Protocol.type_name(got)])
	return reader


func read_bits(bits: int) -> int:
	if error != "" or bits == 0:
		return 0
	if _bits - _position < bits:
		error = SHORT_MESSAGE
		return 0
	var value := (_data.decode_u64(_position >> 3) >> (_position & 7)) & ((1 << bits) - 1)
	_position += bits
	return value


func read_signed(bits: int) -> int:
	var value := read_bits(bits)
	if value >= 1 << (bits - 1):
		value -= 1 << bits
	return value


func read_bool() -> bool:
	return read_bits(1) == 1


func read_u64() -> int:
	var low := read_bits(32)
	var high := read_bits(32)
	return (high << 32) | low


## read_float32 rejects NaN and infinities: no field of the protocol needs them,
## and they would poison the simulation that receives them.
func read_float32() -> float:
	_scratch.encode_u32(0, read_bits(32))
	var value := _scratch.decode_float(0)
	if is_nan(value) or is_inf(value):
		fail(INVALID_FLOAT)
		return 0.0
	return value


func read_bytes(count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(count)
	for i in count:
		bytes[i] = read_bits(8)
	return bytes


func read_string(length_bits: int, max_bytes: int) -> String:
	var length := read_bits(length_bits)
	if length > max_bytes:
		fail(INVALID_TEXT)
	if error == "" and remaining() < length * 8:
		fail(SHORT_MESSAGE)
	if error != "" or length == 0:
		return ""
	var bytes := read_bytes(length)
	if not valid_utf8(bytes):
		fail(INVALID_TEXT)
		return ""
	return bytes.get_string_from_utf8()


func remaining() -> int:
	return _bits - _position


func fail(message: String) -> void:
	if error == "":
		error = message


## finish returns the first error, or TRAILING_DATA unless all that is left is
## the zero padding of the last byte.
func finish() -> String:
	if error != "":
		return error
	var left := remaining()
	if left >= 8 or read_bits(left) != 0:
		return TRAILING_DATA
	return ""


## valid_utf8 reports whether bytes are well-formed UTF-8: no overlong forms,
## surrogates or code points past U+10FFFF, and no NUL, which a String cannot
## hold.
static func valid_utf8(bytes: PackedByteArray) -> bool:
	var i := 0
	var count := bytes.size()
	while i < count:
		var b := bytes[i]
		if b == 0:
			return false
		if b < 0x80:
			i += 1
			continue
		var need := 0
		var code := 0
		var low := 0
		if b >= 0xC2 and b <= 0xDF:
			need = 1
			code = b & 0x1F
			low = 0x80
		elif b >= 0xE0 and b <= 0xEF:
			need = 2
			code = b & 0x0F
			low = 0x800
		elif b >= 0xF0 and b <= 0xF4:
			need = 3
			code = b & 0x07
			low = 0x10000
		else:
			return false
		if i + need >= count:
			return false
		for k in range(1, need + 1):
			var c := bytes[i + k]
			if c & 0xC0 != 0x80:
				return false
			code = (code << 6) | (c & 0x3F)
		if code < low or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF):
			return false
		i += need + 1
	return true

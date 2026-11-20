class_name BitWriter
extends RefCounted
## BitWriter appends fields of up to 32 bits each, least significant bit first,
## with no byte alignment between fields. It collects bits in a 64-bit word and
## stores them 32 at a time.

var _buffer := PackedByteArray()
var _size := 0
var _pending := 0
var _count := 0


func _init() -> void:
	_buffer.resize(1536)


func write_bits(value: int, bits: int) -> void:
	_pending |= (value & ((1 << bits) - 1)) << _count
	_count += bits
	if _count >= 32:
		if _size + 4 > _buffer.size():
			_buffer.resize(_buffer.size() * 2)
		_buffer.encode_u32(_size, _pending & 0xFFFFFFFF)
		_size += 4
		_pending = (_pending >> 32) & 0xFFFFFFFF
		_count -= 32


## write_signed writes the two's complement of value truncated to bits.
func write_signed(value: int, bits: int) -> void:
	write_bits(value, bits)


func write_bool(value: bool) -> void:
	write_bits(1 if value else 0, 1)


func write_u64(value: int) -> void:
	write_bits(value & 0xFFFFFFFF, 32)
	write_bits((value >> 32) & 0xFFFFFFFF, 32)


func write_float32(value: float) -> void:
	var scratch := PackedByteArray([0, 0, 0, 0])
	scratch.encode_float(0, value)
	write_bits(scratch.decode_u32(0), 32)


func write_bytes(value: PackedByteArray) -> void:
	for b in value:
		write_bits(b, 8)


## write_string writes the byte length in length_bits bits, then the UTF-8 bytes.
func write_string(value: String, length_bits: int) -> void:
	var bytes := value.to_utf8_buffer()
	write_bits(bytes.size(), length_bits)
	write_bytes(bytes)


## bits_written is how many bits the writer holds.
func bits_written() -> int:
	return _size * 8 + _count


## bytes pads the last byte with zero bits and returns what was written.
func bytes() -> PackedByteArray:
	var result := _buffer.slice(0, _size)
	var pending := _pending
	var count := _count
	while count > 0:
		result.append(pending & 0xFF)
		pending >>= 8
		count -= 8
	return result

package protocol

import (
	"errors"
	"math"
	"unicode/utf8"
)

var (
	ErrShortMessage = errors.New("message ends before its last field")
	ErrTrailingData = errors.New("message has data after its last field")
	ErrInvalidText  = errors.New("text is too long or not UTF-8")
	ErrInvalidFloat = errors.New("number is not finite")
)

// BitWriter appends fields of up to 32 bits each, least significant bit first,
// with no byte alignment between fields.
type BitWriter struct {
	buffer  []byte
	pending uint64
	count   uint
}

func (w *BitWriter) Reset(dst []byte) {
	*w = BitWriter{buffer: dst}
}

func (w *BitWriter) WriteBits(value uint32, bits uint) {
	w.pending |= (uint64(value) & lowBits(bits)) << w.count
	w.count += bits
	for w.count >= 8 {
		w.buffer = append(w.buffer, byte(w.pending))
		w.pending >>= 8
		w.count -= 8
	}
}

// WriteSigned writes the two's complement of value truncated to bits.
func (w *BitWriter) WriteSigned(value int32, bits uint) {
	w.WriteBits(uint32(value), bits)
}

func (w *BitWriter) WriteBool(value bool) {
	if value {
		w.WriteBits(1, 1)
	} else {
		w.WriteBits(0, 1)
	}
}

func (w *BitWriter) WriteUint64(value uint64) {
	w.WriteBits(uint32(value), 32)
	w.WriteBits(uint32(value>>32), 32)
}

func (w *BitWriter) WriteFloat32(value float32) {
	w.WriteBits(math.Float32bits(value), 32)
}

func (w *BitWriter) WriteBytes(value []byte) {
	for _, b := range value {
		w.WriteBits(uint32(b), 8)
	}
}

// WriteString writes the byte length in lengthBits bits, then the bytes.
func (w *BitWriter) WriteString(value string, lengthBits uint) {
	w.WriteBits(uint32(len(value)), lengthBits)
	for i := 0; i < len(value); i++ {
		w.WriteBits(uint32(value[i]), 8)
	}
}

// Bytes pads the last byte with zero bits and returns the buffer.
func (w *BitWriter) Bytes() []byte {
	if w.count > 0 {
		w.buffer = append(w.buffer, byte(w.pending))
		w.pending, w.count = 0, 0
	}
	return w.buffer
}

// BitReader reads fields written by BitWriter. The first error sticks and
// later reads return zero, so a decoder reads every field and checks Finish once.
type BitReader struct {
	data     []byte
	position uint
	err      error
}

func (r *BitReader) Reset(data []byte) {
	*r = BitReader{data: data}
}

func (r *BitReader) ReadBits(bits uint) uint32 {
	if r.err != nil || bits == 0 {
		return 0
	}
	if r.Remaining() < bits {
		r.err = ErrShortMessage
		return 0
	}
	offset, first := r.position%8, r.position/8
	var value uint64
	for i := uint(0); i*8 < offset+bits; i++ {
		value |= uint64(r.data[first+i]) << (8 * i)
	}
	r.position += bits
	return uint32((value >> offset) & lowBits(bits))
}

func (r *BitReader) ReadSigned(bits uint) int32 {
	shift := 32 - bits
	return int32(r.ReadBits(bits)<<shift) >> shift
}

func (r *BitReader) ReadBool() bool {
	return r.ReadBits(1) == 1
}

func (r *BitReader) ReadUint64() uint64 {
	low := r.ReadBits(32)
	high := r.ReadBits(32)
	return uint64(high)<<32 | uint64(low)
}

// ReadFloat32 rejects NaN and infinities: no field of the protocol needs them,
// and they would poison the simulation that receives them.
func (r *BitReader) ReadFloat32() float32 {
	value := math.Float32frombits(r.ReadBits(32))
	if math.IsNaN(float64(value)) || math.IsInf(float64(value), 0) {
		r.Fail(ErrInvalidFloat)
		return 0
	}
	return value
}

func (r *BitReader) ReadBytes(dst []byte) {
	for i := range dst {
		dst[i] = byte(r.ReadBits(8))
	}
}

func (r *BitReader) ReadString(lengthBits uint, maxBytes int) string {
	length := int(r.ReadBits(lengthBits))
	if length > maxBytes {
		r.Fail(ErrInvalidText)
	}
	if r.err == nil && r.Remaining() < uint(length)*8 {
		r.Fail(ErrShortMessage)
	}
	if r.err != nil || length == 0 {
		return ""
	}
	text := make([]byte, length)
	r.ReadBytes(text)
	if !utf8.Valid(text) {
		r.Fail(ErrInvalidText)
		return ""
	}
	return string(text)
}

func (r *BitReader) Remaining() uint {
	return uint(len(r.data))*8 - r.position
}

func (r *BitReader) Err() error {
	return r.err
}

func (r *BitReader) Fail(err error) {
	if r.err == nil {
		r.err = err
	}
}

// Finish returns the first error, or ErrTrailingData unless all that is left
// is the zero padding of the last byte.
func (r *BitReader) Finish() error {
	if r.err != nil {
		return r.err
	}
	if remaining := r.Remaining(); remaining >= 8 || r.ReadBits(remaining) != 0 {
		return ErrTrailingData
	}
	return nil
}

func lowBits(bits uint) uint64 {
	return 1<<bits - 1
}

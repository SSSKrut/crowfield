package protocol

import (
	"bytes"
	"errors"
	"math"
	"math/rand/v2"
	"testing"
)

// The bit order is part of the wire format: fields are packed from the least
// significant bit of each byte.
func TestBitWriterLayout(t *testing.T) {
	var w BitWriter
	w.Reset(nil)
	w.WriteBits(0b101, 3)
	w.WriteBits(0xFF, 8)
	w.WriteBool(true)
	if got, want := w.Bytes(), []byte{0xFD, 0x0F}; !bytes.Equal(got, want) {
		t.Errorf("wrote %08b, want %08b", got, want)
	}
}

func TestBitsRoundTrip(t *testing.T) {
	random := rand.New(rand.NewPCG(3, 4))
	type field struct {
		bits     uint
		value    uint32
		signed   int32
		wide     uint64
		float    float32
		text     string
		kind     int
		fullWide bool
	}
	fields := make([]field, 3000)
	var w BitWriter
	w.Reset([]byte{0xAA})
	for i := range fields {
		f := field{kind: random.IntN(6), bits: uint(1 + random.IntN(32))}
		switch f.kind {
		case 0:
			f.value = uint32(random.Uint64() & lowBits(f.bits))
			w.WriteBits(f.value, f.bits)
		case 1:
			limit := int64(1) << (f.bits - 1)
			f.signed = int32(random.Int64N(2*limit) - limit)
			w.WriteSigned(f.signed, f.bits)
		case 2:
			f.value = uint32(random.IntN(2))
			w.WriteBool(f.value == 1)
		case 3:
			f.wide = random.Uint64()
			w.WriteUint64(f.wide)
		case 4:
			f.float = float32(random.NormFloat64() * 1000)
			w.WriteFloat32(f.float)
		case 5:
			f.text = []string{"", "a", "Ворон", "eagle-raven-17"}[random.IntN(4)]
			w.WriteString(f.text, 6)
		}
		fields[i] = f
	}
	data := w.Bytes()
	if data[0] != 0xAA {
		t.Fatal("writer overwrote the existing buffer")
	}
	var r BitReader
	r.Reset(data[1:])
	for i, f := range fields {
		switch f.kind {
		case 0:
			if got := r.ReadBits(f.bits); got != f.value {
				t.Fatalf("field %d: %d bits read %d, want %d", i, f.bits, got, f.value)
			}
		case 1:
			if got := r.ReadSigned(f.bits); got != f.signed {
				t.Fatalf("field %d: %d signed bits read %d, want %d", i, f.bits, got, f.signed)
			}
		case 2:
			if got := r.ReadBool(); got != (f.value == 1) {
				t.Fatalf("field %d: bool read %t", i, got)
			}
		case 3:
			if got := r.ReadUint64(); got != f.wide {
				t.Fatalf("field %d: uint64 read %d, want %d", i, got, f.wide)
			}
		case 4:
			if got := r.ReadFloat32(); got != f.float {
				t.Fatalf("field %d: float read %v, want %v", i, got, f.float)
			}
		case 5:
			if got := r.ReadString(6, 63); got != f.text {
				t.Fatalf("field %d: string read %q, want %q", i, got, f.text)
			}
		}
	}
	if err := r.Finish(); err != nil {
		t.Fatal(err)
	}
}

func TestBitReaderErrors(t *testing.T) {
	var r BitReader
	r.Reset([]byte{0xFF})
	r.ReadBits(4)
	if r.ReadBits(5) != 0 || !errors.Is(r.Err(), ErrShortMessage) {
		t.Errorf("reading past the end returned err %v", r.Err())
	}
	if r.ReadBits(1) != 0 || !errors.Is(r.Finish(), ErrShortMessage) {
		t.Error("the first error does not stick")
	}

	for name, c := range map[string]struct {
		data []byte
		read func(r *BitReader)
		want error
	}{
		"trailing byte":   {[]byte{0x01, 0x00}, func(r *BitReader) { r.ReadBits(1) }, ErrTrailingData},
		"padding bits":    {[]byte{0x03}, func(r *BitReader) { r.ReadBits(1) }, ErrTrailingData},
		"long string":     {[]byte{0x05, 'a', 'b', 'c', 'd', 'e'}, func(r *BitReader) { r.ReadString(8, 4) }, ErrInvalidText},
		"bad utf-8":       {[]byte{0x01, 0xFF}, func(r *BitReader) { r.ReadString(8, 4) }, ErrInvalidText},
		"short string":    {[]byte{0x04, 'a'}, func(r *BitReader) { r.ReadString(8, 4) }, ErrShortMessage},
		"nan":             {float32Bytes(float32(math.NaN())), func(r *BitReader) { r.ReadFloat32() }, ErrInvalidFloat},
		"infinity":        {float32Bytes(float32(math.Inf(-1))), func(r *BitReader) { r.ReadFloat32() }, ErrInvalidFloat},
		"exact end":       {[]byte{0x01}, func(r *BitReader) { r.ReadBits(8) }, nil},
		"zero padding ok": {[]byte{0x01}, func(r *BitReader) { r.ReadBits(1) }, nil},
	} {
		var r BitReader
		r.Reset(c.data)
		c.read(&r)
		if err := r.Finish(); !errors.Is(err, c.want) {
			t.Errorf("%s: got %v, want %v", name, err, c.want)
		}
	}
}

func float32Bytes(value float32) []byte {
	var w BitWriter
	w.Reset(nil)
	w.WriteFloat32(value)
	return w.Bytes()
}

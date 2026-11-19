package protocol

import (
	"bytes"
	"testing"
)

// FuzzDecode feeds arbitrary bytes to the decoders. Decoding must never panic,
// and whatever decodes must encode back to exactly the same bytes, so there is
// one encoding per message and nothing is silently ignored.
func FuzzDecode(f *testing.F) {
	for _, message := range sampleMessages() {
		data, err := message.Encode(nil)
		if err != nil {
			f.Fatal(err)
		}
		f.Add(data)
	}
	f.Add([]byte{})
	f.Add([]byte{byte(MessageSnapshot), 0xFF, 0xFF, 0xFF})
	f.Fuzz(func(t *testing.T, data []byte) {
		messageType, err := PeekType(data)
		if err != nil {
			return
		}
		message, err := New(messageType)
		if err != nil {
			t.Fatal(err)
		}
		if message.Decode(data) != nil {
			return
		}
		encoded, err := message.Encode(nil)
		if err != nil {
			t.Fatalf("decoded %s does not encode: %v", messageType, err)
		}
		if !bytes.Equal(encoded, data) {
			t.Fatalf("%s decodes %x but encodes %x", messageType, data, encoded)
		}
	})
}

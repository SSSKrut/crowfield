package physics

/*
#include "wrapper.h"
*/
import "C"

import (
	"errors"
	"unsafe"
)

type CharacterDesc struct {
	Position        Vec3
	HalfHeight      float32
	Radius          float32
	MaxSlopeRadians float32
	// MaxStrength is the force in newtons with which the character pushes
	// dynamic bodies; zero does not push them at all.
	MaxStrength float32
}

type Character struct {
	world *World
	ptr   *C.RFCharacter
}

func (w *World) CreateCharacter(desc CharacterDesc) (*Character, error) {
	if w == nil || w.ptr == nil {
		return nil, ErrClosed
	}
	var nativeErr C.RFError
	ptr := C.rf_character_create(w.ptr, C.RFCharacterDesc{
		position:          cVec(desc.Position),
		half_height:       C.float(desc.HalfHeight),
		radius:            C.float(desc.Radius),
		max_slope_radians: C.float(desc.MaxSlopeRadians),
		max_strength:      C.float(desc.MaxStrength),
	}, &nativeErr)
	if ptr == nil {
		return nil, goError(&nativeErr)
	}
	character := &Character{world: w, ptr: ptr}
	w.characters[character] = struct{}{}
	return character, nil
}

func (c *Character) Close() error {
	if c == nil || c.ptr == nil {
		return nil
	}
	C.rf_character_destroy(c.ptr)
	delete(c.world.characters, c)
	c.ptr = nil
	return nil
}

func (c *Character) Update(deltaTime float32) error {
	if c == nil || c.ptr == nil {
		return ErrClosed
	}
	C.rf_character_update(c.ptr, C.float(deltaTime))
	return nil
}

// RefreshContacts recomputes contacts and the ground state after a teleport;
// without it the next update starts from the contacts of the old position. It
// cannot rebuild what the previous update learned from collisions, so replays
// must restore a saved state instead.
func (c *Character) RefreshContacts() error {
	if c == nil || c.ptr == nil {
		return ErrClosed
	}
	C.rf_character_refresh_contacts(c.ptr)
	return nil
}

// SaveState writes the character's internal state into buffer, reusing its
// capacity, and returns the filled slice. The state is only valid for the same
// build of the native library.
func (c *Character) SaveState(buffer []byte) ([]byte, error) {
	if c == nil || c.ptr == nil {
		return buffer, ErrClosed
	}
	buffer = buffer[:cap(buffer)]
	size := int(C.rf_character_save_state(c.ptr, bytePointer(buffer), C.size_t(len(buffer))))
	if size > len(buffer) {
		buffer = make([]byte, size)
		C.rf_character_save_state(c.ptr, bytePointer(buffer), C.size_t(size))
	}
	return buffer[:size], nil
}

func (c *Character) RestoreState(state []byte) error {
	if c == nil || c.ptr == nil {
		return ErrClosed
	}
	if len(state) == 0 || C.rf_character_restore_state(c.ptr, bytePointer(state), C.size_t(len(state))) == 0 {
		return errors.New("invalid character state")
	}
	return nil
}

func bytePointer(buffer []byte) *C.uint8_t {
	if len(buffer) == 0 {
		return nil
	}
	return (*C.uint8_t)(unsafe.Pointer(&buffer[0]))
}

func (c *Character) Position() (Vec3, error) {
	if c == nil || c.ptr == nil {
		return Vec3{}, ErrClosed
	}
	return goVec(C.rf_character_get_position(c.ptr)), nil
}

func (c *Character) SetPosition(position Vec3) error {
	if c == nil || c.ptr == nil {
		return ErrClosed
	}
	C.rf_character_set_position(c.ptr, cVec(position))
	return nil
}

func (c *Character) LinearVelocity() (Vec3, error) {
	if c == nil || c.ptr == nil {
		return Vec3{}, ErrClosed
	}
	return goVec(C.rf_character_get_linear_velocity(c.ptr)), nil
}

func (c *Character) SetLinearVelocity(velocity Vec3) error {
	if c == nil || c.ptr == nil {
		return ErrClosed
	}
	C.rf_character_set_linear_velocity(c.ptr, cVec(velocity))
	return nil
}

func (c *Character) IsGrounded() (bool, error) {
	if c == nil || c.ptr == nil {
		return false, ErrClosed
	}
	return C.rf_character_is_grounded(c.ptr) != 0, nil
}

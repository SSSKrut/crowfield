package physics

/*
#include "wrapper.h"
*/
import "C"

type CharacterDesc struct {
	Position        Vec3
	HalfHeight      float32
	Radius          float32
	MaxSlopeRadians float32
}

type Character struct {
	world *World
	ptr   *C.RFCharacter
}

func (w *World) CreateCharacter(desc CharacterDesc) (*Character, error) {
	if w == nil || w.ptr == nil {
		return nil, ErrClosed
	}
	ptr := C.rf_character_create(
		w.ptr,
		cVec(desc.Position),
		C.float(desc.HalfHeight),
		C.float(desc.Radius),
		C.float(desc.MaxSlopeRadians),
	)
	if ptr == nil {
		return nil, lastError()
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

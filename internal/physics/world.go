package physics

/*
#cgo CFLAGS: -I${SRCDIR}/../../native/jolt
#cgo LDFLAGS: -L${SRCDIR}/../../build/native/lib -lravenfield_jolt -lJolt -lstdc++ -lm -pthread
#include <stdlib.h>
#include "wrapper.h"
*/
import "C"

import (
	"errors"
	"sync"
)

var (
	initOnce sync.Once
	initErr  error
)

func Init() error {
	initOnce.Do(func() {
		if C.rf_initialize() == 0 {
			initErr = lastError()
		}
	})
	return initErr
}

func Shutdown() {
	C.rf_shutdown()
}

func lastError() error {
	message := C.GoString(C.rf_last_error())
	if message == "" {
		message = "unknown Jolt error"
	}
	return errors.New(message)
}

type World struct {
	ptr        *C.RFWorld
	bodies     map[*Body]struct{}
	characters map[*Character]struct{}
	ragdolls   map[*Ragdoll]struct{}
}

func NewWorld() (*World, error) {
	if err := Init(); err != nil {
		return nil, err
	}
	ptr := C.rf_world_create()
	if ptr == nil {
		return nil, lastError()
	}
	return &World{
		ptr:        ptr,
		bodies:     make(map[*Body]struct{}),
		characters: make(map[*Character]struct{}),
		ragdolls:   make(map[*Ragdoll]struct{}),
	}, nil
}

func (w *World) Close() error {
	if w == nil || w.ptr == nil {
		return nil
	}
	for ragdoll := range w.ragdolls {
		_ = ragdoll.Close()
	}
	for character := range w.characters {
		_ = character.Close()
	}
	for body := range w.bodies {
		_ = body.Close()
	}
	C.rf_world_destroy(w.ptr)
	w.ptr = nil
	return nil
}

func (w *World) Step(deltaTime float32) error {
	if w == nil || w.ptr == nil {
		return ErrClosed
	}
	if deltaTime <= 0 {
		return nil
	}
	C.rf_world_step(w.ptr, C.float(deltaTime))
	return nil
}

func (w *World) RayCast(origin, direction Vec3, distance float32) (RayHit, bool, error) {
	if w == nil || w.ptr == nil {
		return RayHit{}, false, ErrClosed
	}
	var hit C.RFRayHit
	result := C.rf_world_ray_cast(w.ptr, cVec(origin), cVec(direction), C.float(distance), &hit)
	if result == 0 {
		return RayHit{}, false, nil
	}
	return RayHit{Position: goVec(hit.position), Fraction: float32(hit.fraction), BodyID: uint32(hit.body_id)}, true, nil
}

func (w *World) CreateBox(desc BoxDesc) (*Body, error) {
	if w == nil || w.ptr == nil {
		return nil, ErrClosed
	}
	ptr := C.rf_body_create_box(w.ptr, cVec(desc.HalfExtents), cTransform(desc.Transform), cBool(desc.Dynamic))
	if ptr == nil {
		return nil, lastError()
	}
	body := &Body{world: w, ptr: ptr}
	w.bodies[body] = struct{}{}
	return body, nil
}

func (w *World) CreateSphere(desc SphereDesc) (*Body, error) {
	if w == nil || w.ptr == nil {
		return nil, ErrClosed
	}
	ptr := C.rf_body_create_sphere(w.ptr, C.float(desc.Radius), cTransform(desc.Transform), cBool(desc.Dynamic))
	if ptr == nil {
		return nil, lastError()
	}
	body := &Body{world: w, ptr: ptr}
	w.bodies[body] = struct{}{}
	return body, nil
}

type Body struct {
	world *World
	ptr   *C.RFBody
}

func (b *Body) Close() error {
	if b == nil || b.ptr == nil {
		return nil
	}
	C.rf_body_destroy(b.ptr)
	delete(b.world.bodies, b)
	b.ptr = nil
	return nil
}

func (b *Body) Transform() (Transform, error) {
	if b == nil || b.ptr == nil {
		return Transform{}, ErrClosed
	}
	return goTransform(C.rf_body_get_transform(b.ptr)), nil
}

func (b *Body) SetTransform(transform Transform) error {
	if b == nil || b.ptr == nil {
		return ErrClosed
	}
	C.rf_body_set_transform(b.ptr, cTransform(transform))
	return nil
}

func (b *Body) SetLinearVelocity(velocity Vec3) error {
	if b == nil || b.ptr == nil {
		return ErrClosed
	}
	C.rf_body_set_linear_velocity(b.ptr, cVec(velocity))
	return nil
}

func (b *Body) LinearVelocity() (Vec3, error) {
	if b == nil || b.ptr == nil {
		return Vec3{}, ErrClosed
	}
	return goVec(C.rf_body_get_linear_velocity(b.ptr)), nil
}

func (b *Body) AddImpulse(impulse Vec3) error {
	if b == nil || b.ptr == nil {
		return ErrClosed
	}
	C.rf_body_add_impulse(b.ptr, cVec(impulse))
	return nil
}

func (b *Body) IsActive() (bool, error) {
	if b == nil || b.ptr == nil {
		return false, ErrClosed
	}
	return C.rf_body_is_active(b.ptr) != 0, nil
}

func cVec(value Vec3) C.RFVec3 {
	return C.RFVec3{x: C.float(value.X), y: C.float(value.Y), z: C.float(value.Z)}
}

func goVec(value C.RFVec3) Vec3 {
	return V(float32(value.x), float32(value.y), float32(value.z))
}

func cQuat(value Quat) C.RFQuat {
	return C.RFQuat{x: C.float(value.X), y: C.float(value.Y), z: C.float(value.Z), w: C.float(value.W)}
}

func goQuat(value C.RFQuat) Quat {
	return Quat{X: float32(value.x), Y: float32(value.y), Z: float32(value.z), W: float32(value.w)}
}

func cTransform(value Transform) C.RFTransform {
	return C.RFTransform{position: cVec(value.Position), rotation: cQuat(value.Rotation)}
}

func goTransform(value C.RFTransform) Transform {
	return Transform{Position: goVec(value.position), Rotation: goQuat(value.rotation)}
}

func cBool(value bool) C.int {
	if value {
		return 1
	}
	return 0
}

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
	"fmt"
	"sync"
)

var (
	stateMu     sync.Mutex
	initialized bool
)

// Init starts Jolt and the job thread pool shared by all worlds.
func Init() error {
	stateMu.Lock()
	defer stateMu.Unlock()
	if initialized {
		return nil
	}
	var nativeErr C.RFError
	if C.rf_initialize(&nativeErr) == 0 {
		return goError(&nativeErr)
	}
	initialized = true
	return nil
}

// Shutdown stops Jolt. It fails while any world is still open.
func Shutdown() error {
	stateMu.Lock()
	defer stateMu.Unlock()
	if !initialized {
		return nil
	}
	var nativeErr C.RFError
	if C.rf_shutdown(&nativeErr) == 0 {
		return goError(&nativeErr)
	}
	initialized = false
	return nil
}

func goError(nativeErr *C.RFError) error {
	message := C.GoString(&nativeErr.message[0])
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
	rayBuffer  []C.RFRay
	hitBuffer  []C.RFRayHit
}

func NewWorld() (*World, error) {
	if err := Init(); err != nil {
		return nil, err
	}
	var nativeErr C.RFError
	ptr := C.rf_world_create(&nativeErr)
	if ptr == nil {
		return nil, goError(&nativeErr)
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

// RayCast returns the closest hit on the layers in mask.
func (w *World) RayCast(ray Ray, mask LayerMask) (RayHit, error) {
	if w == nil || w.ptr == nil {
		return RayHit{}, ErrClosed
	}
	var hit C.RFRayHit
	C.rf_world_ray_cast(w.ptr, cRay(ray), C.uint32_t(mask), &hit)
	return goRayHit(hit), nil
}

// RayCastBatch casts all rays with one call into Jolt; large batches run in
// parallel on the shared pool. hits must have the same length as rays.
func (w *World) RayCastBatch(rays []Ray, mask LayerMask, hits []RayHit) error {
	if w == nil || w.ptr == nil {
		return ErrClosed
	}
	if len(hits) != len(rays) {
		return fmt.Errorf("ray batch has %d rays but %d hits", len(rays), len(hits))
	}
	if len(rays) == 0 {
		return nil
	}
	if cap(w.rayBuffer) < len(rays) {
		w.rayBuffer = make([]C.RFRay, len(rays))
		w.hitBuffer = make([]C.RFRayHit, len(rays))
	}
	nativeRays, nativeHits := w.rayBuffer[:len(rays)], w.hitBuffer[:len(rays)]
	for i, ray := range rays {
		nativeRays[i] = cRay(ray)
	}
	C.rf_world_ray_cast_batch(w.ptr, &nativeRays[0], C.size_t(len(rays)), C.uint32_t(mask), &nativeHits[0])
	for i, hit := range nativeHits {
		hits[i] = goRayHit(hit)
	}
	return nil
}

func (w *World) CreateBox(desc BoxDesc) (*Body, error) {
	if w == nil || w.ptr == nil {
		return nil, ErrClosed
	}
	var nativeErr C.RFError
	ptr := C.rf_body_create_box(w.ptr, cVec(desc.HalfExtents), cTransform(desc.Transform), bodyKind(desc.Dynamic, desc.Cosmetic), &nativeErr)
	if ptr == nil {
		return nil, goError(&nativeErr)
	}
	body := &Body{world: w, ptr: ptr}
	w.bodies[body] = struct{}{}
	return body, nil
}

func (w *World) CreateSphere(desc SphereDesc) (*Body, error) {
	if w == nil || w.ptr == nil {
		return nil, ErrClosed
	}
	var nativeErr C.RFError
	ptr := C.rf_body_create_sphere(w.ptr, C.float(desc.Radius), cTransform(desc.Transform), bodyKind(desc.Dynamic, desc.Cosmetic), &nativeErr)
	if ptr == nil {
		return nil, goError(&nativeErr)
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

// ID matches RayHit.BodyID of hits on this body.
func (b *Body) ID() uint32 {
	if b == nil || b.ptr == nil {
		return 0
	}
	return uint32(C.rf_body_get_id(b.ptr))
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

func cRay(ray Ray) C.RFRay {
	return C.RFRay{origin: cVec(ray.Origin), direction: cVec(ray.Direction), distance: C.float(ray.Distance)}
}

func goRayHit(hit C.RFRayHit) RayHit {
	return RayHit{
		Hit: hit.hit != 0, Position: goVec(hit.position), Fraction: float32(hit.fraction), BodyID: uint32(hit.body_id),
	}
}

func bodyKind(dynamic, cosmetic bool) C.int {
	switch {
	case cosmetic:
		return C.RF_BODY_COSMETIC
	case dynamic:
		return C.RF_BODY_DYNAMIC
	}
	return C.RF_BODY_STATIC
}

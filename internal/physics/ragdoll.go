package physics

/*
#include <stdlib.h>
#include "wrapper.h"
*/
import "C"

import "unsafe"

type Ragdoll struct {
	world *World
	ptr   *C.RFRagdoll
	count int
}

func (w *World) CreateRagdoll(parts []RagdollPart, linearVelocity, rootImpulse Vec3) (*Ragdoll, error) {
	if w == nil || w.ptr == nil {
		return nil, ErrClosed
	}
	if len(parts) == 0 {
		return nil, lastError()
	}
	memory := C.malloc(C.size_t(len(parts)) * C.size_t(unsafe.Sizeof(C.RFRagdollPart{})))
	if memory == nil {
		return nil, lastError()
	}
	defer C.free(memory)
	cParts := unsafe.Slice((*C.RFRagdollPart)(memory), len(parts))
	for i, part := range parts {
		cParts[i] = C.RFRagdollPart{
			transform:   cTransform(part.Transform),
			size:        cVec(part.Size),
			mass:        C.float(part.Mass),
			parent:      C.int32_t(part.Parent),
			shape:       C.int32_t(part.Shape),
			joint:       C.int32_t(part.Joint),
			joint_pivot: cVec(part.JointPivot),
			joint_axis:  cVec(part.JointAxis),
			joint_limit: C.float(part.JointLimit),
		}
	}
	ptr := C.rf_ragdoll_create(
		w.ptr,
		(*C.RFRagdollPart)(memory),
		C.size_t(len(parts)),
		cVec(linearVelocity),
		cVec(rootImpulse),
	)
	if ptr == nil {
		return nil, lastError()
	}
	ragdoll := &Ragdoll{world: w, ptr: ptr, count: len(parts)}
	w.ragdolls[ragdoll] = struct{}{}
	return ragdoll, nil
}

func (r *Ragdoll) Close() error {
	if r == nil || r.ptr == nil {
		return nil
	}
	C.rf_ragdoll_destroy(r.ptr)
	delete(r.world.ragdolls, r)
	r.ptr = nil
	return nil
}

func (r *Ragdoll) Transforms() ([]Transform, error) {
	if r == nil || r.ptr == nil {
		return nil, ErrClosed
	}
	memory := C.malloc(C.size_t(r.count) * C.size_t(unsafe.Sizeof(C.RFTransform{})))
	if memory == nil {
		return nil, lastError()
	}
	defer C.free(memory)
	C.rf_ragdoll_get_transforms(r.ptr, (*C.RFTransform)(memory), C.size_t(r.count))
	cTransforms := unsafe.Slice((*C.RFTransform)(memory), r.count)
	transforms := make([]Transform, r.count)
	for i, transform := range cTransforms {
		transforms[i] = goTransform(transform)
	}
	return transforms, nil
}

func (r *Ragdoll) IsActive() (bool, error) {
	if r == nil || r.ptr == nil {
		return false, ErrClosed
	}
	return C.rf_ragdoll_is_active(r.ptr) != 0, nil
}

func (r *Ragdoll) AddImpulse(impulse Vec3) error {
	if r == nil || r.ptr == nil {
		return ErrClosed
	}
	C.rf_ragdoll_add_impulse(r.ptr, cVec(impulse))
	return nil
}

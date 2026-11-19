package physics

/*
#include <stdlib.h>
#include "wrapper.h"
*/
import "C"

import (
	"errors"
	"unsafe"
)

// RagdollSettings describe the parts of a skeleton once, in a reference pose
// whose transforms place the joints. Ragdolls made from them share the shapes.
type RagdollSettings struct {
	ptr   *C.RFRagdollSettings
	count int
}

func NewRagdollSettings(parts []RagdollPart) (*RagdollSettings, error) {
	if err := Init(); err != nil {
		return nil, err
	}
	if len(parts) == 0 {
		return nil, errors.New("ragdoll has no parts")
	}
	memory := C.malloc(C.size_t(len(parts)) * C.size_t(unsafe.Sizeof(C.RFRagdollPart{})))
	if memory == nil {
		return nil, errors.New("out of memory for ragdoll parts")
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
	var nativeErr C.RFError
	ptr := C.rf_ragdoll_settings_create((*C.RFRagdollPart)(memory), C.size_t(len(parts)), &nativeErr)
	if ptr == nil {
		return nil, goError(&nativeErr)
	}
	return &RagdollSettings{ptr: ptr, count: len(parts)}, nil
}

// Parts is how many bodies a ragdoll of these settings has.
func (s *RagdollSettings) Parts() int {
	return s.count
}

// Close frees the settings; ragdolls made from them keep working.
func (s *RagdollSettings) Close() {
	if s != nil && s.ptr != nil {
		C.rf_ragdoll_settings_destroy(s.ptr)
		s.ptr = nil
	}
}

// Ragdoll is made once and reused: it has its bodies and joints for all its
// life and is simulated only between Start and Stop. Its buffer of
// transforms is in C memory, so reading them allocates nothing.
type Ragdoll struct {
	world      *World
	ptr        *C.RFRagdoll
	count      int
	buffer     []C.RFTransform
	transforms []Transform
	running    bool
}

// CreateRagdoll makes a ragdoll of the settings, outside the simulation.
func (w *World) CreateRagdoll(settings *RagdollSettings) (*Ragdoll, error) {
	if w == nil || w.ptr == nil || settings == nil || settings.ptr == nil {
		return nil, ErrClosed
	}
	var nativeErr C.RFError
	ptr := C.rf_ragdoll_create(w.ptr, settings.ptr, &nativeErr)
	if ptr == nil {
		return nil, goError(&nativeErr)
	}
	memory := C.calloc(C.size_t(settings.count), C.size_t(unsafe.Sizeof(C.RFTransform{})))
	if memory == nil {
		C.rf_ragdoll_destroy(ptr)
		return nil, errors.New("out of memory for ragdoll transforms")
	}
	ragdoll := &Ragdoll{
		world: w, ptr: ptr, count: settings.count,
		buffer: unsafe.Slice((*C.RFTransform)(memory), settings.count), transforms: make([]Transform, settings.count),
	}
	w.ragdolls[ragdoll] = struct{}{}
	return ragdoll, nil
}

func (r *Ragdoll) Close() error {
	if r == nil || r.ptr == nil {
		return nil
	}
	C.rf_ragdoll_destroy(r.ptr)
	C.free(unsafe.Pointer(&r.buffer[0]))
	delete(r.world.ragdolls, r)
	r.ptr, r.buffer, r.running = nil, nil, false
	return nil
}

// Start puts the bodies at the transforms, one per part, gives them the
// velocity and adds them to the simulation; then the impulse strikes the
// given part at a point. A negative part strikes nothing.
func (r *Ragdoll) Start(transforms []Transform, velocity Vec3, part int, point, impulse Vec3) error {
	if r == nil || r.ptr == nil {
		return ErrClosed
	}
	if len(transforms) != r.count {
		return errors.New("a ragdoll pose needs a transform for every part")
	}
	for i, transform := range transforms {
		r.buffer[i] = cTransform(transform)
	}
	var nativeErr C.RFError
	if C.rf_ragdoll_start(r.ptr, &r.buffer[0], C.size_t(r.count), cVec(velocity), C.int32_t(part), cVec(point), cVec(impulse), &nativeErr) == 0 {
		return goError(&nativeErr)
	}
	r.running = true
	return nil
}

// Stop takes the bodies out of the simulation, to start again later.
func (r *Ragdoll) Stop() {
	if r != nil && r.ptr != nil && r.running {
		C.rf_ragdoll_stop(r.ptr)
		r.running = false
	}
}

// Running reports whether the ragdoll is in the simulation.
func (r *Ragdoll) Running() bool {
	return r != nil && r.running
}

// Transforms returns where the bodies are. The slice is the ragdoll's own
// and changes with the next call.
func (r *Ragdoll) Transforms() ([]Transform, error) {
	if r == nil || r.ptr == nil {
		return nil, ErrClosed
	}
	C.rf_ragdoll_get_transforms(r.ptr, &r.buffer[0], C.size_t(r.count))
	for i, transform := range r.buffer {
		r.transforms[i] = goTransform(transform)
	}
	return r.transforms, nil
}

func (r *Ragdoll) IsActive() (bool, error) {
	if r == nil || r.ptr == nil {
		return false, ErrClosed
	}
	return C.rf_ragdoll_is_active(r.ptr) != 0, nil
}

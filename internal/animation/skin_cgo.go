package animation

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	rl "github.com/gen2brain/raylib-go/raylib"
)

func updateSkinning(model rl.Model) {
	memory := C.malloc(C.size_t(unsafe.Sizeof(uintptr(0))))
	if memory == nil {
		return
	}
	defer C.free(memory)
	*(*uintptr)(memory) = uintptr(unsafe.Pointer(model.CurrentPose))
	animation := rl.ModelAnimation{
		BoneCount: model.Skeleton.BoneCount, KeyframeCount: 1,
		KeyframePoses: (*rl.ModelAnimPose)(memory),
	}
	rl.UpdateModelAnimation(model, animation, 0)
}

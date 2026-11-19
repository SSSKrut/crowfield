package physics

/*
#include "wrapper.h"
*/
import "C"

// Layer decides what a body collides with; the table lives in the native adapter.
type Layer uint8

const (
	LayerStatic    = Layer(C.RF_LAYER_STATIC)
	LayerCharacter = Layer(C.RF_LAYER_CHARACTER)
	LayerVehicle   = Layer(C.RF_LAYER_VEHICLE)
	LayerDynamic   = Layer(C.RF_LAYER_DYNAMIC)
	LayerCosmetic  = Layer(C.RF_LAYER_COSMETIC)
)

// LayerMask selects the layers a query may hit.
type LayerMask uint32

func Mask(layers ...Layer) LayerMask {
	var mask LayerMask
	for _, layer := range layers {
		mask |= 1 << layer
	}
	return mask
}

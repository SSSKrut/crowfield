class_name Bodies
extends RefCounted
## Bodies are fallen soldiers that no longer belong to anyone: they fall as
## ragdolls, freeze, and go after a while.

## At most MAX_BODIES fallen bodies stay, each for LIFETIME seconds; beyond
## that the oldest goes first.
const MAX_BODIES := 128
const LIFETIME := 30.0

var all: Array[CharacterView] = []
var ages := PackedFloat32Array()
## peak is the most ragdolls simulated at once so far.
var peak := 0


## make_room frees a ragdoll of the pool for a new fall, when all are in use:
## the ragdoll farthest from the eye freezes early.
func make_room(pool: RagdollPool, eye: Vector3) -> void:
	if not pool.full():
		return
	var farthest := -1
	var longest := -1.0
	for i in all.size():
		var distance := all[i].fallen_at.distance_to(eye)
		if all[i].ragdoll_active() and distance > longest:
			farthest = i
			longest = distance
	if farthest >= 0:
		all[farthest].freeze()


## add takes a soldier that has just fallen.
func add(view: CharacterView) -> void:
	if all.size() >= MAX_BODIES:
		_remove(0)
	all.append(view)
	ages.append(0.0)
	peak = maxi(peak, ragdolls())


func ragdolls() -> int:
	var count := 0
	for view in all:
		if view.ragdoll_active():
			count += 1
	return count


func update(delta: float) -> void:
	var i := 0
	while i < all.size():
		ages[i] += delta
		if ages[i] >= LIFETIME:
			_remove(i)
			continue
		all[i].update_fall(delta)
		i += 1


func _remove(i: int) -> void:
	var view := all[i]
	view.freeze()
	view.queue_free()
	all.remove_at(i)
	ages.remove_at(i)


func clear() -> void:
	while not all.is_empty():
		_remove(0)

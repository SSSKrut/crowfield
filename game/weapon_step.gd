class_name WeaponStep
extends RefCounted
## WeaponStep is what the weapons did in a tick: the events, and the shot with
## Arsenal.EVENT_FIRED; a weapon fires at most once a tick.

var events := 0
var shot: Shot = null


func has(event: int) -> bool:
	return events & event != 0

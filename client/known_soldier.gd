class_name KnownSoldier
extends RefCounted
## KnownSoldier is a soldier as the client last heard of it, and its recent
## states for drawing it in the past.

## MAX_PENDING_SHOTS bounds the shots waiting to be shown of one soldier.
const MAX_PENDING_SHOTS := 16

var soldier := Soldier.new()
## tick is the server tick of the state in soldier; updates counts the states
## received.
var tick := 0
var updates := 0
var remote := RemoteSoldier.new()
## shots are the server ticks of shots the soldier fired that are not shown
## yet, oldest first, and hit the tick of a hit it took; shown when the
## interpolation reaches them.
var shots := PackedFloat64Array()
var hit := 0.0
var hurt := false


func _init(at_tick: int) -> void:
	tick = at_tick


## schedule spreads the shots a soldier fired since its last state over the
## ticks between the two states, and marks a new hit at the tick of the new
## one: the client shows them as the interpolation passes those ticks.
func schedule(state: SoldierState, at_tick: int) -> void:
	var fired := (state.shots - soldier.shots) & 15
	var span := float(at_tick - tick)
	for i in range(1, fired + 1):
		if shots.size() == MAX_PENDING_SHOTS:
			shots.remove_at(0)
		shots.append(tick + span * i / fired)
	if state.hit_count != soldier.hit_count:
		hit = at_tick
		hurt = true

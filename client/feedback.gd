class_name Feedback
extends RefCounted
## Feedback is what the events of combat show the player: a marker on the
## crosshair when its shot hurt someone, where hits came from, and who
## killed the player. Hud draws it.

const MARKER_TIME := 0.25
## A damage indicator shows HURT_TIME, the red flash of a hit HURT_FLASH.
const HURT_TIME := 1.5
const HURT_FLASH := 0.25
## At most MAX_HURT damage indicators show at once.
const MAX_HURT := 8

var marker := 0.0
var marker_kill := false
var marker_head := false
## hurt marks point where hits came from; flash is what is left of the red
## flash of the last one.
var hurt: Array[HurtMark] = []
var flash := 0.0
## killed_by tells the death screen about the last death of the own soldier.
var killed_by := ""


## take shows the events a poll brought; own is the player's soldier, and
## sounds, if any, tick for a hit.
func take(events: Array, own: int, sounds: Object) -> void:
	for event in events:
		if event is Messages.HitConfirm:
			marker = MARKER_TIME
			marker_kill = event.killed
			marker_head = event.zone == Hitboxes.Zone.HEAD
			if sounds != null:
				sounds.hit_marker(event.killed)
		elif event is Messages.Damage:
			if hurt.size() == MAX_HURT:
				hurt.pop_front()
			var mark := HurtMark.new()
			mark.yaw = event.yaw * (TAU / 256.0) + PI
			hurt.append(mark)
			if flash <= 0.0 and sounds != null:
				sounds.take_damage()
			flash = HURT_FLASH
		elif event is Messages.Death and event.victim == own:
			killed_by = "Killed by %s with the %s" % [event.killer_name, WeaponTuning.kind_name(event.weapon)]
			if event.zone == Hitboxes.Zone.HEAD:
				killed_by += ", in the head"


func update(delta: float) -> void:
	marker = maxf(0.0, marker - delta)
	flash = maxf(0.0, flash - delta)
	var kept: Array[HurtMark] = []
	for mark in hurt:
		mark.age += delta
		if mark.age < HURT_TIME:
			kept.append(mark)
	hurt = kept


## HurtMark points where a hit came from: yaw is the direction from the player
## towards the shooter.
class HurtMark:
	var yaw := 0.0
	var age := 0.0

class_name Shot
extends RefCounted
## Shot is a round fired from the soldier's eye along direction, which has the
## kick and the spread in it: a bullet, the pellets of a shotgun, a rocket or a
## grenade on its way, or the use of a medkit.

var weapon: int = WeaponTuning.Kind.NONE
var origin := Vector3.ZERO
var direction := Vector3.FORWARD
## pellets are the directions of the pellets of a shotgun shot, around
## direction; empty for a single round.
var pellets := PackedVector3Array()

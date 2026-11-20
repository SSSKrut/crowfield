class_name Shot
extends RefCounted
## Shot is a round fired from the soldier's eye along direction, which has the
## kick and the spread in it.

var weapon: int = WeaponTuning.Kind.NONE
var origin := Vector3.ZERO
var direction := Vector3.FORWARD

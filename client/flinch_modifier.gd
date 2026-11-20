class_name FlinchModifier
extends SkeletonModifier3D
## FlinchModifier makes a soldier hit by a shot that does not kill flinch
## (ARCHITECTURE.md, 10.2): a few bones of the struck part turn away from the
## shot and spring back, on top of the animation, with no physics. The spring
## rings at FREQUENCY, damped by DAMPING; a hit gives it KICK radians per
## second, and the turn never exceeds MAX_ANGLE.

const FREQUENCY := 3.0
const DAMPING := 0.45
const KICK := 7.0
const MAX_ANGLE := 0.35
## A flinch smaller than this, turning slower than its speed, is over.
const REST := 0.002
const REST_SPEED := 0.02
const STEP := 1.0 / 120.0

## CHAINS are the bones a hit on a part turns, each by a share of the
## spring's angle, by ragdoll part. The body bends at the waist and the neck;
## a limb swings from its shoulder or hip, against the turn of the body.
const CHAINS := [
	[["Abdomen", "Torso_2"], [0.5, 0.5], false],
	[["Abdomen", "Torso_2"], [0.5, 0.5], false],
	[["Neck", "Head_2"], [0.5, 0.6], false],
	[["UpperArm.L", "LowerArm.L"], [1.0, 0.5], true],
	[["UpperArm.L", "LowerArm.L"], [0.6, 1.0], true],
	[["UpperArm.R", "LowerArm.R"], [1.0, 0.5], true],
	[["UpperArm.R", "LowerArm.R"], [0.6, 1.0], true],
	[["UpperLeg.L", "LowerLeg.L"], [0.7, 0.3], true],
	[["UpperLeg.L", "LowerLeg.L"], [0.5, 0.6], true],
	[["UpperLeg.L", "LowerLeg.L"], [0.5, 0.6], true],
	[["UpperLeg.R", "LowerLeg.R"], [0.7, 0.3], true],
	[["UpperLeg.R", "LowerLeg.R"], [0.5, 0.6], true],
	[["UpperLeg.R", "LowerLeg.R"], [0.5, 0.6], true],
]

var flinching := false
var angle := 0.0
var speed := 0.0
var _bones := PackedInt32Array([-1, -1])
var _weights := PackedFloat32Array([0.0, 0.0])
## _axis is what the bones turn about, in the space of the skeleton.
var _axis := Vector3.RIGHT
var _asset: CharacterAsset


func setup(asset: CharacterAsset) -> void:
	_asset = asset


## kick starts a flinch of a part by a shot travelling along direction, in the
## world. A hit while still flinching adds to the swing.
func kick(part: int, direction: Vector3) -> void:
	if part < 0 or part >= CHAINS.size():
		return
	var chain: Array = CHAINS[part]
	for i in 2:
		_bones[i] = _asset.bones.get(chain[0][i], -1)
		_weights[i] = chain[1][i]
	# Turning about up × shot carries what is above the pivot along the shot,
	# and what hangs below it back.
	var flat := Vector3(direction.x, 0, direction.z)
	flat = flat.normalized() if flat.length_squared() > 1e-8 else Vector3.FORWARD
	var axis := Vector3.UP.cross(flat)
	if chain[2]:
		axis = -axis
	var skeleton := get_skeleton()
	if skeleton != null:
		axis = skeleton.global_basis.orthonormalized().inverse() * axis
	_axis = axis.normalized()
	if not flinching:
		angle = 0.0
		speed = 0.0
	flinching = true
	speed += KICK


## advance runs the spring in small steps.
func advance(delta: float) -> void:
	if not flinching:
		return
	var omega := TAU * FREQUENCY
	var remaining := delta
	while remaining > 0:
		var step := minf(remaining, STEP)
		speed += (-omega * omega * angle - 2 * DAMPING * omega * speed) * step
		angle = clampf(angle + speed * step, -MAX_ANGLE, MAX_ANGLE)
		remaining -= STEP
	if absf(angle) < REST and absf(speed) < REST_SPEED:
		flinching = false


## _process_modification turns the bones of the flinch about where they are,
## their children with them.
func _process_modification_with_delta(_delta: float) -> void:
	if not flinching:
		return
	var skeleton := get_skeleton()
	for i in 2:
		var bone := _bones[i]
		if bone < 0:
			continue
		var pose := skeleton.get_bone_global_pose(bone)
		var turned := Basis(_axis, angle * _weights[i]) * pose.basis
		var parent := skeleton.get_bone_parent(bone)
		var local := turned if parent < 0 else skeleton.get_bone_global_pose(parent).basis.inverse() * turned
		skeleton.set_bone_pose_rotation(bone, local.get_rotation_quaternion())

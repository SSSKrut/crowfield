class_name ArmedPose
extends SkeletonModifier3D
## Both wrists follow the carried weapon. The authored elbows determine the
## natural bend, and the solved arms keep the skeleton's segment lengths.

var weapon := Transform3D.IDENTITY
var trigger := Vector3.ZERO
var support := Vector3.ZERO
var aim := 0.0
var pitch := 0.0
var recoil := 0.0
var _torso: int
var _head: int
var _arms: Array[PackedInt32Array] = []


func setup(asset: CharacterAsset) -> void:
	_torso = asset.bones["Torso_2"]
	_head = asset.bones["Head_2"]
	for side in ["R", "L"]:
		_arms.append(PackedInt32Array([
			asset.bones["UpperArm." + side], asset.bones["LowerArm." + side], asset.bones["Palm1." + side],
		]))


func _process_modification_with_delta(_delta: float) -> void:
	apply_pose()


## Also used at the ragdoll handoff, before the current pose is saved.
func apply_pose() -> void:
	var skeleton := get_skeleton()
	var shoulders := skeleton.get_bone_pose_rotation(_torso)
	var face := skeleton.get_bone_pose_rotation(_head)
	skeleton.set_bone_pose_rotation(_torso, shoulders * Quaternion(Vector3.RIGHT, 0.08 * aim - 0.10 * recoil))
	skeleton.set_bone_pose_rotation(_head, face * Quaternion(Vector3.RIGHT, -0.09 * aim - 0.19 * pitch))
	var glove_basis := weapon.basis.orthonormalized() * Basis(Vector3.UP, PI)
	_place_arm(skeleton, _arms[0], weapon * trigger, glove_basis, InfantryMesh.TRIGGER_CONTACT)
	_place_arm(skeleton, _arms[1], weapon * support, glove_basis, InfantryMesh.SUPPORT_CONTACT)


func _place_arm(skeleton: Skeleton3D, arm: PackedInt32Array, grip: Vector3,
		glove: Basis, contact: Vector3) -> void:
	var upper := skeleton.get_bone_global_pose(arm[0])
	var lower := skeleton.get_bone_global_pose(arm[1])
	var wrist := skeleton.get_bone_global_pose(arm[2])
	var parent := skeleton.get_bone_global_pose(skeleton.get_bone_parent(arm[0])).basis
	var humerus := lower.origin - upper.origin
	var forearm := wrist.origin - lower.origin
	var to_wrist := grip - glove * contact - upper.origin
	var along := to_wrist.normalized()
	var a := humerus.length()
	var b := forearm.length()
	var reach := clampf(to_wrist.length(), absf(a - b) + 0.001, a + b - 0.001)
	var elbow_depth := (a * a - b * b + reach * reach) / (2.0 * reach)
	var pole := humerus - along * humerus.dot(along)
	if pole.length_squared() < 0.000001:
		var out := parent.x if contact.x < 0.0 else -parent.x
		pole = out - along * out.dot(along)
	var elbow := along * elbow_depth + pole.normalized() * sqrt(maxf(0.0, a * a - elbow_depth * elbow_depth))
	var destination := along * reach
	var new_upper := Basis(Quaternion(humerus.normalized(), elbow.normalized())) * upper.basis
	var new_lower := Basis(Quaternion(forearm.normalized(), (destination - elbow).normalized())) * lower.basis
	skeleton.set_bone_pose_rotation(arm[0], (parent.inverse() * new_upper).get_rotation_quaternion())
	skeleton.set_bone_pose_rotation(arm[1], (new_upper.inverse() * new_lower).get_rotation_quaternion())
	skeleton.set_bone_pose_rotation(arm[2], (new_lower.inverse() * glove).get_rotation_quaternion())

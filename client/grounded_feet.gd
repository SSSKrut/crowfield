class_name GroundedFeet
extends SkeletonModifier3D
## Lift a penetrating boot without moving its horizontal contact or changing
## the pelvis, upper body, or physical state of the soldier.

const CLEARANCE_TOLERANCE := 0.012
const MAX_LIFT := 0.30

var terrain: Terrain
var _hips: int
var _legs: Array[PackedInt32Array] = []


func setup(asset: CharacterAsset) -> void:
	_hips = asset.bones["Hips"]
	for side in ["L", "R"]:
		_legs.append(PackedInt32Array([
			asset.bones["UpperLeg." + side], asset.bones["LowerLeg." + side], asset.bones["Foot." + side],
		]))


func _process_modification_with_delta(_delta: float) -> void:
	place_boots()


## Use the same terrain correction for a rendered pose and at ragdoll handoff.
func place_boots() -> void:
	if terrain == null:
		return
	var skeleton := get_skeleton()
	var skeleton_to_world := skeleton.global_transform
	var world_up := skeleton_to_world.basis.orthonormalized().inverse() * Vector3.UP
	var hips := skeleton.get_bone_global_pose(_hips).basis
	for leg in _legs:
		var foot := skeleton.get_bone_global_pose(leg[2])
		var point := sole_contact(skeleton_to_world * foot, terrain)
		var lift := terrain.height_at(point.x, point.z) - point.y - CLEARANCE_TOLERANCE
		if lift <= 0.0:
			continue
		_lift_leg(skeleton, leg, hips, foot, world_up * minf(lift, MAX_LIFT))


## The lowest point of the oriented sole ellipsoid along the terrain normal.
## Sampling at that point takes the heel and toe into account on a slope.
static func sole_contact(foot: Transform3D, ground: Terrain) -> Vector3:
	var center := foot * InfantryMesh.SOLE_CENTER
	var normal := ground.normal_at(center.x, center.z)
	var radii := InfantryMesh.SOLE_RADII
	var scaled_normal := (foot.basis.transposed() * normal) * radii
	return center - foot.basis * (radii * scaled_normal.normalized())


func _lift_leg(skeleton: Skeleton3D, leg: PackedInt32Array, hips: Basis,
		foot: Transform3D, offset: Vector3) -> void:
	var thigh := skeleton.get_bone_global_pose(leg[0])
	var shin := skeleton.get_bone_global_pose(leg[1])
	var thigh_ray := shin.origin - thigh.origin
	var shin_ray := foot.origin - shin.origin
	var a := thigh_ray.length()
	var b := shin_ray.length()
	var destination := foot.origin + offset - thigh.origin
	var distance := destination.length()
	if distance < 0.001:
		return
	var along_leg := destination / distance
	var reach := clampf(distance, absf(a - b) + 0.001, a + b - 0.001)
	var along_knee := (a * a - b * b + reach * reach) / (2.0 * reach)
	var bend := thigh_ray - along_leg * thigh_ray.dot(along_leg)
	if bend.length_squared() < 0.00001:
		var forward := hips.z
		bend = forward - along_leg * forward.dot(along_leg)
	var knee := along_leg * along_knee + bend.normalized() * sqrt(maxf(0.0, a * a - along_knee * along_knee))
	var ankle := along_leg * reach
	var thigh_rotation := Basis(Quaternion(thigh_ray.normalized(), knee.normalized())) * thigh.basis
	var shin_rotation := Basis(Quaternion(shin_ray.normalized(), (ankle - knee).normalized())) * shin.basis
	skeleton.set_bone_pose_rotation(leg[0], (hips.inverse() * thigh_rotation).get_rotation_quaternion())
	skeleton.set_bone_pose_rotation(leg[1], (thigh_rotation.inverse() * shin_rotation).get_rotation_quaternion())
	skeleton.set_bone_pose_rotation(leg[2], (shin_rotation.inverse() * foot.basis).get_rotation_quaternion())

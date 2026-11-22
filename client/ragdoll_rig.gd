class_name RagdollRig
extends RefCounted
## RagdollRig is how the infantry skeleton falls (ARCHITECTURE.md, 10.2):
## thirteen parts in the reference pose, the first frame of the idle clip,
## standing at the origin; the bone each part follows and where the part sits
## on that bone; and the joints between the parts. It is built once and every
## ragdoll of the pool shares its shapes.

## The parts, in the order the rig builds them; a strike names the part it
## hits by them.
enum Part {
	HIPS, TORSO, HEAD, UPPER_ARM_LEFT, LOWER_ARM_LEFT, UPPER_ARM_RIGHT, LOWER_ARM_RIGHT,
	UPPER_LEG_LEFT, LOWER_LEG_LEFT, FOOT_LEFT, UPPER_LEG_RIGHT, LOWER_LEG_RIGHT, FOOT_RIGHT,
}
const PARTS := 13
enum Shape { BOX, CAPSULE, SPHERE }
enum Joint { NONE, POINT, HINGE, SWING_TWIST }

var parts: Array[PartSpec] = []
## part_of_bone maps a bone to the part that moves it, or -1.
var part_of_bone := PackedInt32Array()
## moved lists the bones with parts and their ancestors, parents first: the
## bones a fall needs the place of. Other bones keep their pose relative to
## their parents and follow by themselves.
var moved := PackedInt32Array()
## above_hips are the ancestors of the hips, nearest first: the root and the
## body, which the shell of the torso hangs from. They have no parts, and go
## where the hips take them.
var above_hips := PackedInt32Array()
## is_above_hips marks them by bone.
var is_above_hips := PackedByteArray()


## build lays the parts out on the reference pose of the asset, whose bones
## are in world space by bone_world.
static func build(asset: CharacterAsset, reference: Skeleton3D) -> RagdollRig:
	var rig := RagdollRig.new()
	rig.part_of_bone.resize(reference.get_bone_count())
	rig.part_of_bone.fill(-1)
	rig._box(asset, reference, "Hips", Vector3(0.16, 0.11, 0.13), 12, -1, Joint.NONE, 0)
	rig._capsule(asset, reference, "Torso_2", "Neck", 0.18, 16, Part.HIPS, Joint.SWING_TWIST, 0.55)
	rig._head(asset, reference)
	for side in ["L", "R"]:
		rig._capsule(asset, reference, "UpperArm." + side, "LowerArm." + side, 0.075, 2.2, Part.TORSO, Joint.SWING_TWIST, 1.1)
		rig._capsule(asset, reference, "LowerArm." + side, "Palm1." + side, 0.065, 1.7, rig.parts.size() - 1, Joint.HINGE, 1.25)
	for side in ["L", "R"]:
		rig._capsule(asset, reference, "UpperLeg." + side, "LowerLeg." + side, 0.105, 6, Part.HIPS, Joint.SWING_TWIST, 0.85)
		rig._capsule(asset, reference, "LowerLeg." + side, "Foot." + side, 0.09, 4, rig.parts.size() - 1, Joint.HINGE, 1.15)
		rig._box(asset, reference, "Foot." + side, Vector3(0.081, 0.071, 0.137), 1.2, rig.parts.size() - 1, Joint.POINT, 0,
			Vector3(0, -0.048, 0.055))
	var needed := {}
	for i in rig.parts.size():
		var part := rig.parts[i]
		rig.part_of_bone[part.bone] = i
		part.to_part = bone_world(reference, part.bone).affine_inverse() * part.reference
		var bone := part.bone
		while bone >= 0:
			needed[bone] = true
			bone = reference.get_bone_parent(bone)
	for bone in reference.get_bone_count():
		if needed.has(bone):
			rig.moved.append(bone)
	rig.is_above_hips.resize(reference.get_bone_count())
	var above := reference.get_bone_parent(rig.parts[Part.HIPS].bone)
	while above >= 0:
		rig.above_hips.append(above)
		rig.is_above_hips[above] = 1
		above = reference.get_bone_parent(above)
	return rig


## bone_world is where a bone of a skeleton is in the world, with a basis
## without scale: the frame a body of the ragdoll can take.
static func bone_world(skeleton: Skeleton3D, bone: int) -> Transform3D:
	var world := skeleton.global_transform * skeleton.get_bone_global_pose(bone)
	return Transform3D(world.basis.orthonormalized(), world.origin)


func _bone(skeleton: Skeleton3D, name: String) -> int:
	var bone := skeleton.find_bone(name)
	assert(bone >= 0, "the infantry skeleton has no bone %s" % name)
	return bone


func _add(part: PartSpec) -> void:
	parts.append(part)


func _box(_asset: CharacterAsset, skeleton: Skeleton3D, name: String, half: Vector3, mass: float, parent: int, joint: int, limit: float,
		center := Vector3.ZERO) -> void:
	var part := PartSpec.new()
	part.bone = _bone(skeleton, name)
	var at := bone_world(skeleton, part.bone)
	part.reference = Transform3D(at.basis, at * center)
	part.shape = Shape.BOX
	part.size = half
	part.mass = mass
	part.parent = parent
	part.joint = joint
	part.pivot = at.origin
	part.axis = at.basis.z
	part.limit = limit
	_add(part)


## _capsule makes a part from one bone's joint to the next's, turned so that
## its axis runs between them.
func _capsule(_asset: CharacterAsset, skeleton: Skeleton3D, start_name: String, end_name: String, radius: float, mass: float, parent: int, joint: int, limit: float) -> void:
	var part := PartSpec.new()
	part.bone = _bone(skeleton, start_name)
	var start := bone_world(skeleton, part.bone)
	var end := bone_world(skeleton, _bone(skeleton, end_name)).origin
	var along := end - start.origin
	var length := along.length()
	assert(length >= 0.03, "bones %s and %s are too close" % [start_name, end_name])
	var y := along / length
	var x := (start.basis.x - y * start.basis.x.dot(y)).normalized()
	part.reference = Transform3D(Basis(x, y, x.cross(y)), (start.origin + end) * 0.5)
	part.shape = Shape.CAPSULE
	part.size = Vector3(radius, maxf(0.02, (length - 2 * radius) * 0.5), 0)
	part.mass = mass
	part.parent = parent
	part.joint = joint
	part.pivot = start.origin
	part.axis = start.basis.x if joint == Joint.HINGE else y
	part.limit = limit
	_add(part)


func _head(_asset: CharacterAsset, skeleton: Skeleton3D) -> void:
	var part := PartSpec.new()
	part.bone = _bone(skeleton, "Head_2")
	var at := bone_world(skeleton, part.bone)
	part.reference = Transform3D(at.basis, at.origin + at.basis * Vector3(0, 0.115, 0))
	part.shape = Shape.SPHERE
	part.size = Vector3(0.115, 0, 0)
	part.mass = 4
	part.parent = Part.TORSO
	part.joint = Joint.SWING_TWIST
	part.pivot = at.origin
	part.axis = Vector3.UP
	part.limit = 0.65
	_add(part)


## PartSpec is one body of the ragdoll: its shape and mass, the bone it moves,
## where it sits on that bone, and the joint to its parent part, all in the
## reference pose.
class PartSpec:
	var bone := -1
	var shape := 0
	## size is the half extents of a box, the radius and the half height of the
	## cylinder of a capsule, or the radius of a sphere in x.
	var size := Vector3.ZERO
	var mass := 1.0
	var parent := -1
	var joint := 0
	var pivot := Vector3.ZERO
	var axis := Vector3.UP
	var limit := 0.0
	var reference := Transform3D()
	## to_part is the part relative to its bone, which holds in any pose.
	var to_part := Transform3D()

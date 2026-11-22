extends TestCase


func test_authored_infantry_follows_the_live_weapon_and_team() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var weapons := ViewModel.new()
	tree.root.add_child(weapons)
	cleanup(weapons.free)
	var view := CharacterAsset.load_asset().instantiate()
	var blue: Color = SoldierViews.TEAM_COLORS[Game.Team.BLUE]
	var red: Color = SoldierViews.TEAM_COLORS[Game.Team.RED]
	view.set_tint(blue)
	tree.root.add_child(view)
	cleanup(view.free)
	view.set_detail(false)
	view.face(Vector3(5.0, 2.0, 10.0), 0.71)
	var authored := view.authored
	check(not view.body.visible, "the original skinned body is hidden on the live view")
	var helmet := authored.find_child("Object_109", true, false) as MeshInstance3D
	var blue_helmet := helmet.material_override as ShaderMaterial
	check_equal(blue_helmet.get_shader_parameter("team_color"), blue, "team before entering the tree")
	view.set_tint(red)
	var red_helmet := helmet.material_override as ShaderMaterial
	check_equal(red_helmet.get_shader_parameter("team_color"), red, "team changes reach the imported equipment")
	var teammate := view.asset.instantiate()
	teammate.set_tint(blue)
	tree.root.add_child(teammate)
	cleanup(teammate.free)
	var teammate_helmet := teammate.authored.find_child("Object_109", true, false) as MeshInstance3D
	check_equal(teammate_helmet.material_override, blue_helmet, "the same layout and team share a material")
	check_equal(blue_helmet.get_shader_parameter("team_color"), blue, "changing one soldier leaves its teammate blue")
	teammate.set_tint(red)
	check_equal(teammate_helmet.material_override, red_helmet, "switching teams uses the cached red material")

	var stances := [
		Vector3.ZERO, Vector3(4.25, 0, 0), Vector3(6.65, 0, 0), Vector3(0, 1, 0),
		Vector3(1.67, 1, 0), Vector3(0, 0, 1), Vector3(0, 1, 1),
	]
	var support_back := {
		WeaponTuning.Kind.ASSAULT_RIFLE: 0.12,
		WeaponTuning.Kind.RIFLE: 0.06,
		WeaponTuning.Kind.PISTOL: 0.0,
	}
	for stance: Vector3 in stances:
		view.animate(0.3, stance.x, stance.y > 0.0, stance.z > 0.0)
		for phase: float in [0.0, 0.23, 0.48, 0.65, 0.88]:
			for kind: int in support_back:
				for pitch: float in [-0.75, 0.0, 0.75]:
					view.player.seek(view.player.current_animation_length * phase, true)
					var carried := view.carry(weapons, kind, pitch)
					await tree.process_frame
					await tree.process_frame
					for support: bool in [false, true]:
						var hand_name := "LeftHand_035" if support else "RightHand_011"
						var palm := authored.skeleton.get_bone_global_pose(authored._bone(hand_name))
						var contact := authored.skeleton.global_transform * (palm * AuthoredSoldier.PALM_CONTACT)
						var anchor := weapons.held_grip(kind, support)
						if support:
							anchor.z += support_back[kind]
						var gap := (carried * anchor).distance_to(contact)
						check(gap < 0.025, "%s stays within 25 mm of weapon %d at clip %s, phase %.2f, pitch %.2f (%.4f m)" % [
							hand_name, kind, view.player.current_animation, phase, pitch, gap])


func test_authored_infantry_contacts_the_slope_and_follows_a_frozen_body() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var asset := CharacterAsset.load_asset()
	var view := asset.instantiate()
	tree.root.add_child(view)
	cleanup(view.free)
	view.face(Vector3.ZERO, 0.71)
	view.animate(0.3, 0.0, true, true)
	view.player.seek(view.player.current_animation_length * 0.24, true)
	var slope := Terrain.create(6, func(x: float, z: float) -> float: return 0.75 * x + 0.24 * z)
	view.set_foot_terrain(slope)
	await tree.process_frame
	await tree.process_frame
	var boots := view.authored.find_child("Object_123", true, false) as MeshInstance3D
	var sole := _lowest_vertices(boots, view.authored.skeleton, slope)
	for clearance: float in sole:
		check(absf(clearance) < 0.015, "authored boot touches the slope within 15 mm (%.4f m)" % clearance)

	var rig := RagdollRig.build(asset, view.skeleton)
	var pool := RagdollPool.new(rig, view.get_world_3d().space)
	cleanup(pool.close)
	var authored := view.authored
	var hips := authored._bone("Hips_01")
	var before := authored.skeleton.get_bone_global_pose(hips)
	if not check(view.fall(pool, Vector3(3.0, 0.0, 0.0), CharacterView.Strike.new(-1, Vector3.ZERO, Vector3.ZERO)),
			"the live body enters the ragdoll pool"):
		return
	for frame in 8:
		await tree.physics_frame
		view.update_fall(1.0 / 60.0)
	await tree.process_frame
	await tree.process_frame
	var in_fall := authored.skeleton.get_bone_global_pose(hips)
	check(in_fall.origin.distance_to(before.origin) > 0.05, "authored hips follow the moving ragdoll")
	view.freeze()
	await tree.process_frame
	await tree.process_frame
	check_equal(pool.lent(), 0, "frozen body releases the ragdoll")
	check(authored.skeleton.get_bone_global_pose(hips).is_equal_approx(in_fall), "the authored body holds the frozen pose")


## Skin the imported sole vertices so this check uses the drawn mesh itself.
func _lowest_vertices(mesh: MeshInstance3D, skeleton: Skeleton3D, slope: Terrain) -> PackedFloat32Array:
	var surface := mesh.mesh.surface_get_arrays(0)
	var points := surface[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var bones := surface[Mesh.ARRAY_BONES] as PackedInt32Array
	var weights := surface[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array
	var lowest := PackedFloat32Array([INF, INF])
	var influences := bones.size() / points.size()
	for i in points.size():
		var point := Vector3.ZERO
		for j in influences:
			var influence := i * influences + j
			if weights[influence] <= 0.0:
				continue
			var bind := bones[influence]
			var bone := skeleton.find_bone(mesh.skin.get_bind_name(bind))
			point += (skeleton.get_bone_global_pose(bone) * mesh.skin.get_bind_pose(bind) * points[i]) * weights[influence]
		var side := int(point.x > 0.0)
		var world := mesh.global_transform * point
		lowest[side] = minf(lowest[side], world.y - slope.height_at(world.x, world.z))
	return lowest

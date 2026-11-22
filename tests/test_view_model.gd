extends TestCase


func test_reload_anchors_the_support_elbow_and_reseats_the_magazine() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var view := ViewModel.new()
	tree.root.add_child(view)
	cleanup(func() -> void: view.free())
	for kind: int in [WeaponTuning.Kind.ASSAULT_RIFLE, WeaponTuning.Kind.RIFLE, WeaponTuning.Kind.PISTOL]:
		var shape := view._shape_of(kind)
		var elbow := ViewModel._forward(shape.support_elbow)
		var grip := ViewModel._forward(shape.support_grip)
		for progress: float in [0.22, 0.36, 0.49, 0.64, 0.75, 0.88]:
			view._reload_parts(kind, shape, progress)
			var sleeve := view._support_sleeves[kind].transform
			var hand := view._support_hands[kind].position
			check((sleeve * elbow).is_equal_approx(elbow), "the sleeve pivots around the elbow")
			check((sleeve * grip).is_equal_approx(grip + hand), "the cuff follows the support hand")
		view._reload_parts(kind, shape, 0.49)
		check(not view._magazines[kind].visible, "the spent magazine clears the image")
		view._reload_parts(kind, shape, ViewModel.RELOAD_SEAT_PROGRESS)
		check(view._magazines[kind].visible, "the replacement is visible when seated")
		check_equal(view._magazines[kind].position, Vector3.ZERO, "the replacement reaches its final position")
		view._reload_parts(kind, shape, 0.0)
		check_equal(view._support_sleeves[kind].transform, Transform3D.IDENTITY, "return to the ready sleeve pose")



func test_carbine_stock_connects_to_receiver_in_both_meshes() -> void:
	var view := ViewModel.new()
	cleanup(view.free)
	var kind := WeaponTuning.Kind.ASSAULT_RIFLE
	var shape := view._shape_of(kind)
	var held := view.make_held(kind) as MeshInstance3D
	cleanup(held.free)
	for mesh: ArrayMesh in [held.mesh, view._mesh(shape.gun + shape.magazine)]:
		var missing := 0
		for index in 10:
			var from := Vector3(0, 0.03, 0.110 + index * 0.006)
			if not _has_surface_below(mesh, from):
				missing += 1
		check_equal(missing, 0, "stock collar and rail cover the space between the stock and receiver")


func _has_surface_below(mesh: ArrayMesh, point: Vector3) -> bool:
	for surface in mesh.get_surface_count():
		var vertices: PackedVector3Array = mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		for corner in range(0, vertices.size(), 3):
			var hit: Variant = Geometry3D.ray_intersects_triangle(point, Vector3.DOWN,
				vertices[corner], vertices[corner + 1], vertices[corner + 2])
			if hit != null:
				return true
	return false

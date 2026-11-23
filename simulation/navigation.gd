class_name Navigation
extends RefCounted
## Navigation is the navigation mesh of a map on the server, where bots find
## their way. It is baked by the NavigationServer3D of
## the engine from the terrain and the boxes of the map, for a soldier 0.4 m
## in radius and 1.8 m tall that climbs steps of 0.4 m and slopes of 40
## degrees. Bots take their height from the map rather than from the mesh, so
## the mesh follows the terrain only roughly: a fine one would have tens of
## thousands of polygons, and every query looks through all of them. A mesh
## is kept for the process by the hash of its map.
##
## The navigation map is synchronised at once rather than on the next
## physics frame, so that the server can ask for paths in the tick it was
## made in, and tests without frames too.

const CELL_SIZE := 0.4
const CELL_HEIGHT := 0.1

static var _baked := {}

var map: RID
var region: RID
var navigation_mesh: NavigationMesh
var _query := NavigationPathQueryParameters3D.new()
var _result := NavigationPathQueryResult3D.new()


## create bakes or finds the navigation mesh of a map and puts it into a
## navigation map of its own.
static func create(scene: MapScene) -> Navigation:
	var navigation := Navigation.new()
	navigation.navigation_mesh = _mesh_of(scene)
	navigation.map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_cell_size(navigation.map, CELL_SIZE)
	NavigationServer3D.map_set_cell_height(navigation.map, CELL_HEIGHT)
	NavigationServer3D.map_set_use_async_iterations(navigation.map, false)
	NavigationServer3D.map_set_active(navigation.map, true)
	navigation.region = NavigationServer3D.region_create()
	NavigationServer3D.region_set_use_async_iterations(navigation.region, false)
	NavigationServer3D.region_set_map(navigation.region, navigation.map)
	NavigationServer3D.region_set_navigation_mesh(navigation.region, navigation.navigation_mesh)
	NavigationServer3D.map_force_update(navigation.map)
	navigation._query.path_search_max_polygons = 0
	return navigation


func close() -> void:
	if region.is_valid():
		NavigationServer3D.free_rid(region)
	if map.is_valid():
		NavigationServer3D.free_rid(map)
	region = RID()
	map = RID()


## path is the way from one point to another along the mesh, its corners from
## the start to the end; it is empty when there is none. The search is not
## cut short: the way across the valley goes over thousands of polygons.
func path(from: Vector3, to: Vector3) -> PackedVector3Array:
	_query.map = map
	_query.start_position = from
	_query.target_position = to
	NavigationServer3D.query_path(_query, _result)
	return _result.path


## closest is the point of the mesh nearest to a point.
func closest(point: Vector3) -> Vector3:
	return NavigationServer3D.map_get_closest_point(map, point)


static func _mesh_of(scene: MapScene) -> NavigationMesh:
	var key := "%s-%016x" % [scene.name, scene.hash_value()]
	if not _baked.has(key):
		_baked[key] = bake(scene)
	return _baked[key]


## bake builds the navigation mesh of a map within its play area.
static func bake(scene: MapScene) -> NavigationMesh:
	var mesh := NavigationMesh.new()
	mesh.cell_size = CELL_SIZE
	mesh.cell_height = CELL_HEIGHT
	mesh.agent_radius = 0.4
	mesh.agent_height = 1.8
	mesh.agent_max_climb = 0.4
	mesh.agent_max_slope = 40.0
	mesh.region_min_size = 4.0
	# Long edges over the rolling terrain end up too close to join; shorter
	# ones join cleanly.
	mesh.edge_max_length = 8.0
	mesh.detail_sample_distance = 12.0
	mesh.detail_sample_max_error = 1.0
	var area := scene.play_area
	mesh.filter_baking_aabb = AABB(Vector3(-area, -50, -area), Vector3(2 * area, 100, 2 * area))
	var source := NavigationMeshSourceGeometryData3D.new()
	if scene.terrain != null:
		source.add_faces(scene.terrain.faces(area + 2), Transform3D())
	source.add_faces(_box_faces(scene.boxes), Transform3D())
	NavigationServer3D.bake_from_source_geometry_data(mesh, source)
	return mesh


## _box_faces are the triangles of the sides of boxes.
static func _box_faces(boxes: Array[MapScene.Box]) -> PackedVector3Array:
	const CORNERS := [Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1),
		Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1)]
	const SIDES := [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2], [3, 2, 6, 7], [4, 5, 1, 0]]
	var faces := PackedVector3Array()
	for box in boxes:
		var points: Array[Vector3] = []
		for corner: Vector3 in CORNERS:
			points.append(box.transform * (corner * box.half_extents))
		for side: Array in SIDES:
			faces.append_array([points[side[0]], points[side[1]], points[side[2]], points[side[0]], points[side[2]], points[side[3]]])
	return faces

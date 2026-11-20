class_name Terrain
extends RefCounted
## Terrain is the ground of a map: heights on a square grid one metre apart,
## centred on the origin. The server and the client build the same heightmap
## collision from it, the navigation of bots is baked over it, and bots read
## the height under them from it without a ray. Each cell is split into two
## triangles along the diagonal from its corner at x + 1, z to the one at x,
## z + 1, as the physics engine splits it.

## samples is the number of heights along a side.
var samples := 0
## heights[z * samples + x] is the height at the grid point x, z.
var heights := PackedFloat32Array()
var min_height := 0.0
var max_height := 0.0


## create samples height(x, z) over a square of size metres around the
## origin; size must be even.
static func create(size: int, height: Callable) -> Terrain:
	var terrain := Terrain.new()
	terrain.samples = size + 1
	terrain.heights.resize(terrain.samples * terrain.samples)
	var half := size / 2.0
	for z in terrain.samples:
		for x in terrain.samples:
			terrain.heights[z * terrain.samples + x] = height.call(x - half, z - half)
	terrain.min_height = Array(terrain.heights).min()
	terrain.max_height = Array(terrain.heights).max()
	return terrain


## half_size is how far the terrain reaches from the origin along each axis.
func half_size() -> float:
	return (samples - 1) / 2.0


func sample(x: int, z: int) -> float:
	return heights[clampi(z, 0, samples - 1) * samples + clampi(x, 0, samples - 1)]


## height_at is the height of the ground at x, z, on the triangles the
## collision has.
func height_at(x: float, z: float) -> float:
	var half := half_size()
	var gx := clampf(x + half, 0.0, samples - 1.001)
	var gz := clampf(z + half, 0.0, samples - 1.001)
	var ix := floori(gx)
	var iz := floori(gz)
	var fx := gx - ix
	var fz := gz - iz
	var row := iz * samples + ix
	var h10 := heights[row + 1]
	var h01 := heights[row + samples]
	if fx + fz <= 1.0:
		var h00 := heights[row]
		return h00 + (h10 - h00) * fx + (h01 - h00) * fz
	var h11 := heights[row + samples + 1]
	return h11 + (h01 - h11) * (1.0 - fx) + (h10 - h11) * (1.0 - fz)


## normal_at is the upward normal of the ground at x, z.
func normal_at(x: float, z: float) -> Vector3:
	var dx := height_at(x + 0.5, z) - height_at(x - 0.5, z)
	var dz := height_at(x, z + 0.5) - height_at(x, z - 0.5)
	return Vector3(-dx, 1.0, -dz).normalized()


## build_collision adds the heightmap to a physics space and returns its body
## and shape, for MapScene.free_collision.
func build_collision(space: RID) -> Array[RID]:
	var shape := PhysicsServer3D.heightmap_shape_create()
	PhysicsServer3D.shape_set_data(shape, {
		"width": samples, "depth": samples, "heights": heights, "min_height": min_height, "max_height": max_height,
	})
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_add_shape(body, shape)
	PhysicsServer3D.body_set_collision_layer(body, Game.LAYER_STATIC)
	PhysicsServer3D.body_set_collision_mask(body, 0)
	PhysicsServer3D.body_set_space(body, space)
	return [body, shape]


## faces are the triangles of the terrain within reach of the origin, as
## navigation baking takes them.
func faces(reach: float) -> PackedVector3Array:
	var half := half_size()
	var low := maxi(0, floori(half - reach))
	var high := mini(samples - 1, ceili(half + reach))
	var result := PackedVector3Array()
	result.resize((high - low) * (high - low) * 6)
	var at := 0
	for z in range(low, high):
		for x in range(low, high):
			var a := Vector3(x - half, heights[z * samples + x], z - half)
			var b := Vector3(x + 1 - half, heights[z * samples + x + 1], z - half)
			var c := Vector3(x - half, heights[(z + 1) * samples + x], z + 1 - half)
			var d := Vector3(x + 1 - half, heights[(z + 1) * samples + x + 1], z + 1 - half)
			result[at] = a
			result[at + 1] = b
			result[at + 2] = c
			result[at + 3] = b
			result[at + 4] = d
			result[at + 5] = c
			at += 6
	return result


## bytes are the heights as they go into the hash of the map.
func bytes() -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(4)
	result.encode_u32(0, samples)
	return result + heights.to_byte_array()

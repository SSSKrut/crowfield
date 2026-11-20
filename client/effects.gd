class_name Effects
extends Node3D
## Effects are what shots leave in the world: tracers, bullet holes, the dust
## they kick up, the flashes of other soldiers' shots and the sparks of hits on
## soldiers. They are cosmetic; where a shot hits is the server's call, and the
## client only shows its own guess of the wall it struck. Pools have limits
## (ARCHITECTURE.md, 10.3): past a limit the oldest gives way.
##
## The app calls update once a frame; every pool is drawn by one multimesh.

const MAX_TRACERS := 64
const MAX_IMPACTS := 128
const MAX_SPARKS := 256
const MAX_FLASHES := 32
## A tracer is a streak TRACER_LENGTH long flying at TRACER_SPEED, thinner at
## its tail than at its head.
const TRACER_SPEED := 400.0
const TRACER_LENGTH := 3.0
const TRACER_TAIL_RADIUS := 0.004
const TRACER_HEAD_RADIUS := 0.012
## A bullet hole stays IMPACT_LIFETIME seconds and fades in the last one.
const IMPACT_LIFETIME := 20.0
const IMPACT_SIZE := 0.045
const SPARKS_PER_HIT := 6
const SPARK_LIFETIME := 0.45
const SPARK_SIZE := 0.025
const SPARK_GRAVITY := 9.81
## A muzzle flash of another soldier's shot glows FLASH_TIME and shrinks.
const FLASH_TIME := 0.05
const FLASH_RADIUS := 0.07

const TRACER_COLOR := Color8(255, 214, 140, 210)
const IMPACT_COLOR := Color8(28, 26, 24, 255)
const SPARK_COLORS := [Color8(170, 160, 140), Color8(130, 120, 105), Color8(255, 200, 110)]
## A bullet strikes sparks from a robot.
const HIT_COLORS := [Color8(255, 220, 120), Color8(255, 150, 60), Color8(80, 80, 85)]
const FLASH_COLOR := Color8(255, 200, 110)

var random := RandomNumberGenerator.new()

var _tracer_from := PackedVector3Array()
var _tracer_direction := PackedVector3Array()
var _tracer_length := PackedFloat32Array()
var _tracer_flown := PackedFloat32Array()
var _impact_position := PackedVector3Array()
var _impact_age := PackedFloat32Array()
var _spark_position := PackedVector3Array()
var _spark_velocity := PackedVector3Array()
var _spark_age := PackedFloat32Array()
var _spark_color := PackedColorArray()
var _flash_position := PackedVector3Array()
var _flash_age := PackedFloat32Array()

var _tracers: MultiMesh
var _impacts: MultiMesh
var _sparks: MultiMesh
var _flashes: MultiMesh


func _init() -> void:
	name = "Effects"
	random.seed = 1
	var cylinder := CylinderMesh.new()
	cylinder.height = 1.0
	cylinder.bottom_radius = TRACER_TAIL_RADIUS
	cylinder.top_radius = TRACER_HEAD_RADIUS
	cylinder.radial_segments = 4
	cylinder.rings = 0
	_tracers = _pool(cylinder, MAX_TRACERS, _material(true, false))
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE
	_impacts = _pool(cube, MAX_IMPACTS, _material(false, true))
	_sparks = _pool(cube, MAX_SPARKS, _material(false, false))
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	_flashes = _pool(sphere, MAX_FLASHES, _material(true, false))


## flash shows the muzzle flash of another soldier's shot.
func flash(muzzle: Vector3) -> void:
	if _flash_position.size() == MAX_FLASHES:
		_flash_position.remove_at(0)
		_flash_age.remove_at(0)
	_flash_position.append(muzzle)
	_flash_age.append(0.0)


## hit throws sparks off a soldier struck at point by a shot travelling along
## direction.
func hit(point: Vector3, direction: Vector3) -> void:
	for i in 2 * SPARKS_PER_HIT:
		var scatter := Vector3(random.randf() * 2 - 1, random.randf() * 2 - 1, random.randf() * 2 - 1)
		var velocity := direction * (-1.5 + 4 * random.randf()) + scatter * 1.5 + Vector3.UP
		_spark(point, velocity, HIT_COLORS[random.randi_range(0, HIT_COLORS.size() - 1)])


## shot adds the tracer of a shot from the muzzle to where it ends, and a hole
## with dust when it struck something there.
func shot(muzzle: Vector3, end: Vector3, struck: bool) -> void:
	var path := end - muzzle
	var length := path.length()
	if length > 0.5:
		if _tracer_from.size() == MAX_TRACERS:
			_tracer_from.remove_at(0)
			_tracer_direction.remove_at(0)
			_tracer_length.remove_at(0)
			_tracer_flown.remove_at(0)
		_tracer_from.append(muzzle)
		_tracer_direction.append(path / length)
		_tracer_length.append(length)
		_tracer_flown.append(0.0)
	if not struck:
		return
	if _impact_position.size() == MAX_IMPACTS:
		_impact_position.remove_at(0)
		_impact_age.remove_at(0)
	_impact_position.append(end)
	_impact_age.append(0.0)
	var back := path * (-1.0 / maxf(length, 1e-3))
	for i in SPARKS_PER_HIT:
		var scatter := Vector3(random.randf() * 2 - 1, random.randf() * 2 - 1, random.randf() * 2 - 1)
		var velocity := back * (1.5 + 2 * random.randf()) + scatter * 1.2 + Vector3.UP
		_spark(end, velocity, SPARK_COLORS[random.randi_range(0, SPARK_COLORS.size() - 1)])


func _spark(at: Vector3, velocity: Vector3, color: Color) -> void:
	if _spark_position.size() == MAX_SPARKS:
		_spark_position.remove_at(0)
		_spark_velocity.remove_at(0)
		_spark_age.remove_at(0)
		_spark_color.remove_at(0)
	_spark_position.append(at)
	_spark_velocity.append(velocity)
	_spark_age.append(0.0)
	_spark_color.append(color)


## update advances every effect by a frame, drops the finished ones and shows
## the rest.
func update(delta: float) -> void:
	_update_tracers(delta)
	_update_impacts(delta)
	_update_sparks(delta)
	_update_flashes(delta)


func _update_tracers(delta: float) -> void:
	var kept := 0
	for i in _tracer_from.size():
		var flown := _tracer_flown[i] + TRACER_SPEED * delta
		if flown - TRACER_LENGTH >= _tracer_length[i]:
			continue
		_tracer_from[kept] = _tracer_from[i]
		_tracer_direction[kept] = _tracer_direction[i]
		_tracer_length[kept] = _tracer_length[i]
		_tracer_flown[kept] = flown
		kept += 1
	_tracer_from.resize(kept)
	_tracer_direction.resize(kept)
	_tracer_length.resize(kept)
	_tracer_flown.resize(kept)
	var shown := 0
	for i in kept:
		var head := minf(_tracer_flown[i], _tracer_length[i])
		var tail := maxf(0.0, _tracer_flown[i] - TRACER_LENGTH)
		if head <= tail:
			continue
		var direction := _tracer_direction[i]
		var start := _tracer_from[i] + direction * tail
		# The cylinder runs along Y from its thin end to its thick one.
		var helper := Vector3.UP if absf(direction.y) < 0.99 else Vector3.RIGHT
		var x := direction.cross(helper).normalized()
		var z := x.cross(direction).normalized()
		var basis := Basis(x, direction * (head - tail), z)
		_tracers.set_instance_transform(shown, Transform3D(basis, start + direction * ((head - tail) / 2)))
		_tracers.set_instance_color(shown, TRACER_COLOR)
		shown += 1
	_tracers.visible_instance_count = shown


func _update_impacts(delta: float) -> void:
	var kept := 0
	for i in _impact_position.size():
		var age := _impact_age[i] + delta
		if age >= IMPACT_LIFETIME:
			continue
		_impact_position[kept] = _impact_position[i]
		_impact_age[kept] = age
		var tint := IMPACT_COLOR
		tint.a = minf(1.0, IMPACT_LIFETIME - age)
		_impacts.set_instance_transform(kept, Transform3D(Basis.from_scale(Vector3.ONE * IMPACT_SIZE), _impact_position[i]))
		_impacts.set_instance_color(kept, tint)
		kept += 1
	_impact_position.resize(kept)
	_impact_age.resize(kept)
	_impacts.visible_instance_count = kept


func _update_sparks(delta: float) -> void:
	var kept := 0
	for i in _spark_position.size():
		var age := _spark_age[i] + delta
		if age >= SPARK_LIFETIME:
			continue
		var velocity := _spark_velocity[i]
		velocity.y -= SPARK_GRAVITY * delta
		var position := _spark_position[i] + velocity * delta
		_spark_position[kept] = position
		_spark_velocity[kept] = velocity
		_spark_age[kept] = age
		_spark_color[kept] = _spark_color[i]
		var size := SPARK_SIZE * (1.0 - age / SPARK_LIFETIME)
		_sparks.set_instance_transform(kept, Transform3D(Basis.from_scale(Vector3.ONE * size), position))
		_sparks.set_instance_color(kept, _spark_color[i])
		kept += 1
	_spark_position.resize(kept)
	_spark_velocity.resize(kept)
	_spark_age.resize(kept)
	_spark_color.resize(kept)
	_sparks.visible_instance_count = kept


func _update_flashes(delta: float) -> void:
	var kept := 0
	for i in _flash_position.size():
		var age := _flash_age[i] + delta
		if age >= FLASH_TIME:
			continue
		_flash_position[kept] = _flash_position[i]
		_flash_age[kept] = age
		var radius := FLASH_RADIUS * (1.0 - age / FLASH_TIME)
		_flashes.set_instance_transform(kept, Transform3D(Basis.from_scale(Vector3.ONE * radius), _flash_position[i]))
		_flashes.set_instance_color(kept, FLASH_COLOR)
		kept += 1
	_flash_position.resize(kept)
	_flash_age.resize(kept)
	_flashes.visible_instance_count = kept


## _pool makes the multimesh of a pool, drawn by a child of the node.
func _pool(mesh: Mesh, size: int, material: Material) -> MultiMesh:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = mesh
	multimesh.instance_count = size
	multimesh.visible_instance_count = 0
	# Effects lie anywhere on the map; a fixed box spares the engine from
	# measuring the instances every frame.
	multimesh.custom_aabb = AABB(Vector3(-2048, -512, -2048), Vector3(4096, 1024, 4096))
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return multimesh


## _material is unlit and coloured by its instances: glowing and added to what
## is behind it, or fading with the alpha of its colour.
static func _material(glowing: bool, fading: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	if glowing:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	elif fading:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material

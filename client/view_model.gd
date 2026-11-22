class_name ViewModel
extends Node
## ViewModel is the weapon in the player's hands as the player sees it, and
## the weapons other soldiers carry. Its motion is cosmetic: it comes from the
## predicted arsenal and from how the player moves and looks, never back.
##
## The weapon in hand is drawn in an overlay of its own over the world: a
## SubViewport with its own world, a camera with a constant field of view and
## a light turned like the sun of the world, shown through a full-screen
## SubViewportContainer. So a weapon held against a wall does not sink into it,
## and it does not grow when aiming narrows the field of view of the world.
## The node adds the overlay itself, under a CanvasLayer of layer -1: a HUD on
## the default canvas or any layer from 0 up is drawn over it.
##
## Weapon parts are built in a space where X points right, Y up and Z
## forward, with the line of its sights along +Z through the origin, so that
## aiming puts that line on the crosshair. Its meshes have Z pointing
## backwards, as Godot cameras look along -Z: _forward turns a point of the
## author's space into mesh space.

## FIELD_OF_VIEW draws the weapon in hand at a constant size, while the world
## zooms when aiming.
const FIELD_OF_VIEW := 58.0
## The weapon in hand comes to the sights in AIM_TIME and leaves them in the
## same; a shot's kick of the model fades with RECOIL_TIME.
const AIM_TIME := 0.15
const RECOIL_TIME := 0.06
const FLASH_TIME := 0.05
const RELOAD_RELEASE_PROGRESS := 0.22
const RELOAD_SEAT_PROGRESS := 0.75
const FULL_HD_PIXELS := 1920.0 * 1080.0

enum Footfall { NONE, STEP, LAND }
## A soldier holds its weapon at its right side, at the height of the chest and
## somewhat forward, along its aim.
const HELD_SCALE := 0.94
const HELD_OFFSET := Vector3(0.085, 1.29, 0.30)
## LIGHT is where the light of the world comes from when no sun is given: the
## direction the box models of the prototype were lit from.
const LIGHT := Vector3(0.4, 1.0, 0.3)

enum Finish { STEEL, POLYMER, CANVAS, WOOD, TEAM, OPTIC }
const GUN_METAL := Color8(72, 80, 82)
const GUN_DARK := Color8(42, 50, 52)
const GUN_EDGE := Color8(108, 119, 116)
const GUN_POLYMER := Color8(109, 111, 86)
const GUN_WOOD := Color8(133, 86, 52)
const SLEEVE := Color8(102, 117, 91)
const SLEEVE_SEAM := Color8(70, 82, 66)
const GLOVE := Color8(58, 65, 57)
const SIGHT := Color8(231, 181, 90)
const FLASH_CORE := Color8(255, 214, 120)
const FLASH_FLAME := Color8(255, 170, 60, 220)

## aim goes from 0 at the hip to 1 down the sights.
var aim := 0.0
## sun is the light of the world, which the overlay copies; without one the
## overlay is lit from LIGHT.
var sun: DirectionalLight3D
var performance_mode := false
## overlay shows the weapon in hand over the world; layer holds it.
var overlay: SubViewportContainer
var layer: CanvasLayer

## _shapes are the weapon models by kind, null for none; _models their meshes
## in first person, with the arms, and _held the guns alone, as other soldiers
## carry them. Both are built once and shared.
var _shapes: Array[Shape] = []
var _models: Array[ArrayMesh] = []
var _held: Array[ArrayMesh] = []
var _support_meshes: Array[ArrayMesh] = []
var _support_sleeve_meshes: Array[ArrayMesh] = []
var _magazine_meshes: Array[ArrayMesh] = []
var _finishes: Array[StandardMaterial3D] = []
var _held_material: StandardMaterial3D
var _viewport: SubViewport
var _camera: Camera3D
var _light: DirectionalLight3D
var _instances: Array[MeshInstance3D] = []
var _support_hands: Array[MeshInstance3D] = []
var _support_sleeves: Array[MeshInstance3D] = []
var _magazines: Array[MeshInstance3D] = []
var _flash_core: MeshInstance3D
var _flash_flame: MeshInstance3D
var _flash_light: OmniLight3D
var _shown := WeaponTuning.Kind.NONE
## One unit of step phase is one footfall. The weapon follows the same cadence.
var _step_phase := 0.0
var _foot_position := Vector3.INF
var _was_grounded := false
var _air_time := 0.0
var _air_peak := 0.0
var _landing_dip := 0.0
var _stride := 0.0
var _sway := Vector2.ZERO
var _sprint := 0.0
var _recoil := 0.0
var _flash := 0.0
var _flash_turn := 0.0
## _muzzle is where the muzzle of the model placed for this frame is, in the
## space of the eye: X right, Y up, -Z forward.
var _muzzle := Vector3.ZERO


func _init() -> void:
	name = "ViewModel"
	_finishes = [
		_finish(0.52, 0.32, 61, 0.22),
		_finish(0.78, 0.04, 43, 0.09),
		_finish(0.95, 0.0, 50, 0.14),
		_finish(0.76, 0.0, 23, 0.20),
		_finish(0.87, 0.0, 40, 0.10, false),
		_finish(0.38, 0.08),
	]
	_held_material = _finish(0.83, 0.0)
	_shapes = _weapon_shapes()
	_models.resize(WeaponTuning.KINDS)
	_support_meshes.resize(WeaponTuning.KINDS)
	_support_sleeve_meshes.resize(WeaponTuning.KINDS)
	_magazine_meshes.resize(WeaponTuning.KINDS)
	_held.resize(WeaponTuning.KINDS)
	for kind in WeaponTuning.KINDS:
		var shape := _shapes[kind]
		if shape == null:
			continue
		var elbow := shape.support_elbow
		var upper_sleeve := _limb(elbow + Vector3(-0.060, -0.43, -0.16),
			elbow + (shape.support_grip - elbow) * 0.08, Vector2(0.051, 0.048), SLEEVE, Finish.CANVAS)
		var upper: Array[Piece] = shape.gun + shape.right_arm
		upper.append(upper_sleeve)
		_models[kind] = _mesh(upper)
		_support_meshes[kind] = _mesh(_glove(shape.support_grip, -1.0))
		_support_sleeve_meshes[kind] = _mesh(_sleeve(shape.support_grip, shape.support_elbow))
		_magazine_meshes[kind] = _mesh(shape.magazine)
		_held[kind] = _mesh(shape.gun + shape.magazine, true)


static func _finish(roughness: float, metal: float, detail_scale: int = 0,
		amount: float = 0.0, vertex_color: bool = true) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.roughness = roughness
	material.metallic = metal
	material.metallic_specular = 0.35
	material.vertex_color_use_as_albedo = vertex_color
	material.vertex_color_is_srgb = true
	if detail_scale > 0:
		var noise := FastNoiseLite.new()
		noise.frequency = 0.09
		noise.fractal_octaves = 2
		var ramp := Gradient.new()
		ramp.set_color(0, Color.WHITE * (1.0 - amount))
		ramp.set_color(1, Color.WHITE)
		var texture := NoiseTexture2D.new()
		texture.width = 96
		texture.height = 96
		texture.seamless = true
		texture.noise = noise
		texture.color_ramp = ramp
		material.albedo_texture = texture
		material.uv1_triplanar = true
		material.uv1_scale = Vector3.ONE * detail_scale
	return material


func _ready() -> void:
	layer = CanvasLayer.new()
	layer.name = "ViewModelLayer"
	layer.layer = -1
	layer.visible = false
	add_child(layer)
	overlay = SubViewportContainer.new()
	overlay.name = "Overlay"
	overlay.stretch = true
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(overlay)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.gui_disable_input = true
	_viewport.msaa_3d = Viewport.MSAA_2X if performance_mode else Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	overlay.add_child(_viewport)
	if performance_mode:
		overlay.resized.connect(_update_overlay_resolution)
		_update_overlay_resolution()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.84, 0.91, 1.0)
	environment.ambient_light_energy = 0.69
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world := WorldEnvironment.new()
	world.environment = environment
	_viewport.add_child(world)
	_camera = Camera3D.new()
	_camera.fov = FIELD_OF_VIEW
	_camera.near = 0.01
	_camera.far = 10.0
	_camera.current = true
	_viewport.add_child(_camera)
	_light = DirectionalLight3D.new()
	_light.light_energy = 0.75
	_light.shadow_enabled = false
	_viewport.add_child(_light)
	_instances.resize(WeaponTuning.KINDS)
	_support_hands.resize(WeaponTuning.KINDS)
	_support_sleeves.resize(WeaponTuning.KINDS)
	_magazines.resize(WeaponTuning.KINDS)
	for kind in WeaponTuning.KINDS:
		if _models[kind] == null:
			continue
		var root := _mesh_part(_models[kind], _viewport)
		root.visible = false
		_instances[kind] = root
		_support_hands[kind] = _mesh_part(_support_meshes[kind], root)
		_support_sleeves[kind] = _mesh_part(_support_sleeve_meshes[kind], root)
		_magazines[kind] = _mesh_part(_magazine_meshes[kind], root)
	var core := SphereMesh.new()
	core.radius = 1.0
	core.height = 2.0
	core.radial_segments = 12
	core.rings = 6
	_flash_core = _flash_part(core, FLASH_CORE)
	var flame := CylinderMesh.new()
	flame.top_radius = 0.0
	flame.bottom_radius = 1.0
	flame.height = 1.0
	flame.radial_segments = 6
	flame.rings = 1
	_flash_flame = _flash_part(flame, FLASH_FLAME)
	_flash_light = OmniLight3D.new()
	_flash_light.light_color = Color8(255, 169, 77)
	_flash_light.omni_range = 0.83
	_flash_light.visible = false
	_viewport.add_child(_flash_light)


## The alpha overlay is a separate render target from the scaled world. At
## large window sizes, keep its projection and spend fewer samples on it.
func _update_overlay_resolution() -> void:
	var pixels := overlay.size.x * overlay.size.y
	overlay.stretch_shrink = maxi(1, ceili(sqrt(pixels / FULL_HD_PIXELS)))


static func _mesh_part(mesh: Mesh, parent: Node) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
	return instance


func _flash_part(mesh: PrimitiveMesh, color: Color) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = color
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.visible = false
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_viewport.add_child(instance)
	return instance


## show_weapon shows the model of a kind in first person, its hands in the
## team wrist bands.
func show_weapon(kind: int, tint: Color) -> void:
	if layer == null:
		return
	_finishes[Finish.TEAM].albedo_color = tint.lerp(Color8(105, 117, 109), 0.27)
	if kind != _shown:
		for instance in _instances:
			if instance != null:
				instance.visible = false
		_shown = kind
		if _shape_of(kind) != null:
			_instances[kind].visible = true
	layer.visible = _shape_of(kind) != null


## hide_weapon hides the weapon in hand, for the views that are not first
## person.
func hide_weapon() -> void:
	if layer != null:
		layer.visible = false


## fired starts the kick of the model and the muzzle flash; turn in [0, 1)
## varies the flash from shot to shot.
func fired(turn: float) -> void:
	_recoil = 1.0
	_flash = FLASH_TIME
	_flash_turn = turn


## footing uses the drawn feet, so a blocked movement key or a stationary
## correction cannot roll the gait forward. Reset the sample after a discontinuity
## such as spawning, focus loss or switching away from the first-person view.
func footing(delta: float, feet: Vector3, grounded: bool, speed: float, active: bool) -> Footfall:
	if not active:
		_foot_position = Vector3.INF
		return Footfall.NONE
	var offset := feet - _foot_position
	_foot_position = feet
	if not offset.is_finite() or offset.length_squared() > pow(maxf(0.9, delta * 12.0), 2):
		_step_phase = 0.0
		_air_time = 0.0
		_air_peak = feet.y
		_was_grounded = grounded
		_landing_dip = 0.0
		return Footfall.NONE
	if not grounded:
		if _was_grounded:
			_air_peak = feet.y - offset.y
			_air_time = 0.0
		_air_peak = maxf(_air_peak, feet.y)
		_air_time += delta
		_was_grounded = false
		return Footfall.NONE
	if not _was_grounded:
		_was_grounded = true
		var fall := _air_peak - feet.y
		if _air_time >= 0.10 and fall >= 0.18:
			_landing_dip = clampf(fall * 0.052, 0.009, 0.026)
			_step_phase = 0.0
			return Footfall.LAND
		return Footfall.NONE
	if speed < 0.04:
		return Footfall.NONE
	var stride_length := lerpf(0.80, 2.0, clampf(speed, 0.0, 1.0))
	var next := _step_phase + Vector2(offset.x, offset.z).length() / stride_length
	var planted := floori(next) > floori(_step_phase)
	_step_phase = fposmod(next, 2.0)
	return Footfall.STEP if planted else Footfall.NONE


## update moves the model for a frame. speed is the soldier's share of the
## sprint speed; look is how far the view turned this frame, in radians: yaw
## to the right, pitch up.
func update(delta: float, aiming: bool, sprinting: bool, grounded: bool, speed: float, look: Vector2) -> void:
	var rate := delta / AIM_TIME
	aim = minf(1.0, aim + rate) if aiming else maxf(0.0, aim - rate)
	var stride := minf(1.0, speed) if grounded else 0.0
	_stride += (stride - _stride) * minf(1.0, delta * 8)
	_landing_dip *= exp(-delta / 0.115)
	_sprint += ((1.0 if sprinting else 0.0) - _sprint) * minf(1.0, delta * 10)
	var eye_turn := look / maxf(1.0, delta * 60.0)
	var target := (-eye_turn * 0.45).clamp(Vector2(-0.032, -0.032), Vector2(0.032, 0.032))
	_sway = _sway.lerp(target, 1.0 - exp(-delta * 15.0))
	_recoil *= exp(-delta / RECOIL_TIME)
	_flash = maxf(0.0, _flash - delta)


## place puts the model of the weapon in hand in front of the eye of camera,
## lowered by the action of the arsenal: progress runs from 0 to 1 through an
## equip or a reload. It returns false when the kind has no model.
func place(camera: Camera3D, kind: int, action: int, progress: float) -> bool:
	var shape := _shape_of(kind)
	if shape == null:
		return false
	var calm := 1 - 0.85 * aim
	var phase := PI * _step_phase
	var offset := shape.hip + (shape.aim - shape.hip) * aim
	offset += Vector3(
		0.012 * _stride * sin(phase) * calm + _sway.x * calm,
		(-0.009 * _stride * absf(cos(phase)) + _sway.y - _landing_dip) * calm,
		-shape.kick_back * _recoil * (1 - 0.5 * aim))
	# Lower and cant the weapon while keeping the fore-end in the frame.
	offset += Vector3(-0.03, -0.012, -0.04) * _sprint
	var pitch := shape.kick_pitch * _recoil * calm - 0.13 * _sprint
	var yaw := -0.42 * _sprint
	var roll := (_sway.x * -0.5 + 0.018 * sin(phase) * _stride) * calm + 0.26 * _sprint
	match action:
		Arsenal.Action.EQUIPPING:
			var lower := (1 - progress) * (1 - progress)
			offset += Vector3(0, -0.25 * lower, 0)
			pitch -= 0.7 * lower
		Arsenal.Action.RELOADING:
			var dip := sin(PI * progress)
			offset += Vector3(-0.081, 0.178, 0.29) * dip
			pitch += 0.105 * dip
			yaw -= 0.25 * dip
			roll += 0.82 * dip
	var basis := Basis(Vector3.UP, -yaw) * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)
	var local := Transform3D(basis, _forward(offset))
	_muzzle = local * _forward(shape.muzzle)
	if _viewport == null:
		return true
	var visible := not scoped(kind)
	var instance := _instances[kind]
	instance.transform = local
	_reload_parts(kind, shape, progress if action == Arsenal.Action.RELOADING else 0.0)
	instance.visible = visible and kind == _shown
	_place_flash(visible and kind == _shown, basis)
	_place_light(camera)
	return true


## The magazine slides out along the well; the support hand reaches for it,
## drops out of frame, seats the replacement and returns to its foregrip.
func _reload_parts(kind: int, shape: Shape, progress: float) -> void:
	var hand := _support_hands[kind]
	var magazine := _magazines[kind]
	var sleeve := _support_sleeves[kind]
	var reach := smoothstep(0.08, RELOAD_RELEASE_PROGRESS, progress) \
		* (1.0 - smoothstep(RELOAD_SEAT_PROGRESS, 0.97, progress))
	var pull := smoothstep(RELOAD_RELEASE_PROGRESS, 0.44, progress) \
		* (1.0 - smoothstep(0.55, RELOAD_SEAT_PROGRESS, progress))
	var travel := Vector3(-0.018, -shape.magazine_throw, -0.027) * pull
	magazine.position = _forward(travel)
	magazine.visible = progress <= 0.44 or progress >= 0.55
	var motion := _forward((shape.magazine_grip - shape.support_grip) * reach + travel)
	hand.position = motion
	if motion == Vector3.ZERO:
		sleeve.transform = Transform3D.IDENTITY
		return
	# Pivot the sleeve at the elbow while its cuff follows the glove.
	var elbow := _forward(shape.support_elbow)
	var rest := _forward(shape.support_grip) - elbow
	var extended := rest + motion
	var axis := Basis.looking_at(rest, Vector3.UP)
	var length_scale := axis.scaled_local(Vector3(1, 1, extended.length() / rest.length())) * axis.transposed()
	var flex := Basis(Quaternion(rest.normalized(), extended.normalized())) * length_scale
	sleeve.transform = Transform3D(flex, elbow - flex * elbow)


func _place_flash(visible: bool, weapon_basis: Basis) -> void:
	if not visible or _flash <= 0:
		_flash_core.visible = false
		_flash_flame.visible = false
		_flash_light.visible = false
		return
	var size := _flash / FLASH_TIME
	_flash_core.visible = true
	_flash_core.transform = Transform3D(Basis.from_scale(Vector3.ONE * 0.028 * size), _muzzle)
	var length := (0.12 + 0.09 * _flash_turn) * size
	var radius := 0.032 * size
	var along := -weapon_basis.z
	_flash_flame.visible = true
	_flash_flame.transform = Transform3D(
		Basis(weapon_basis.x * radius, along * length, weapon_basis.y * radius),
		_muzzle + along * length * 0.5)
	_flash_light.visible = true
	_flash_light.position = _muzzle
	_flash_light.light_energy = 2.0 * size


## _place_light turns the light of the overlay so that it falls on the model in
## the space of the eye as the sun falls on the world.
func _place_light(camera: Camera3D) -> void:
	var toward := LIGHT.normalized()
	if sun != null:
		toward = sun.global_basis.z.normalized()
		_light.light_color = sun.light_color
	var eye := camera.global_basis.orthonormalized().inverse() * toward
	var up := Vector3.UP if absf(eye.y) < 0.99 else Vector3.BACK
	_light.basis = Basis.looking_at(-eye, up)


## scoped reports whether the player looks through a scope instead of at the
## weapon.
func scoped(kind: int) -> bool:
	var shape := _shape_of(kind)
	return shape != null and shape.scope and aim > 0.95


## muzzle_in_world is where the muzzle of the model placed last appears in the
## world drawn by camera: the model is drawn with its own field of view, so the
## point on the screen is carried back into the world at the same distance
## from the eye.
func muzzle_in_world(camera: Camera3D) -> Vector3:
	var size := camera.get_viewport().get_visible_rect().size
	var depth := maxf(-_muzzle.z, 1e-4)
	var half := tan(deg_to_rad(FIELD_OF_VIEW) / 2)
	var aspect := size.x / maxf(size.y, 1.0)
	var ndc := Vector2(_muzzle.x / depth / (half * aspect), _muzzle.y / depth / half)
	var screen := Vector2((ndc.x + 1) / 2 * size.x, (1 - ndc.y) / 2 * size.y)
	return camera.project_ray_origin(screen) + camera.project_ray_normal(screen) * _muzzle.length()


## make_held returns a new node showing the weapon of a kind as soldiers carry
## it, or null for none. Place it with held_transform every frame.
func make_held(kind: int, _tint: Color = Color.WHITE) -> Node3D:
	if _shape_of(kind) == null:
		return null
	var instance := MeshInstance3D.new()
	instance.name = "Held"
	instance.mesh = _held[kind]
	return instance


## held_transform places the weapon a soldier standing at position carries,
## looking along yaw and pitch: forward is (sin yaw, 0, -cos yaw).
static func held_transform(position: Vector3, yaw: float, pitch: float) -> Transform3D:
	var right := Vector3(cos(yaw), 0, sin(yaw))
	var forward := Vector3(sin(yaw), 0, -cos(yaw))
	var at := position + right * HELD_OFFSET.x + Vector3(0, HELD_OFFSET.y, 0) + forward * HELD_OFFSET.z
	var basis := Basis(Vector3.UP, -yaw) * Basis(Vector3.RIGHT, pitch) * Basis.from_scale(Vector3.ONE * HELD_SCALE)
	return Transform3D(basis, at)


## held_muzzle is where the weapon a soldier carries fires from, or
## Vector3.INF when the kind has no model.
func held_muzzle(kind: int, position: Vector3, yaw: float, pitch: float) -> Vector3:
	var shape := _shape_of(kind)
	if shape == null:
		return Vector3.INF
	return held_transform(position, yaw, pitch) * _forward(shape.muzzle)


func _shape_of(kind: int) -> Shape:
	if kind < 0 or kind >= _shapes.size():
		return null
	return _shapes[kind]


## _forward turns a point of the space boxes are given in, Z forward, into
## mesh space, Z backward.
static func _forward(point: Vector3) -> Vector3:
	return Vector3(point.x, point.y, -point.z)


## Held versions use one surface across the whole weapon. The close-up
## version gives canvas, polymer, steel and wood their own light response.
func _mesh(pieces: Array[Piece], held: bool = false) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for finish in (1 if held else _finishes.size()):
		var surface := Surface.new()
		for piece in pieces:
			if held and minf(piece.half.x, minf(piece.half.y, piece.half.z)) < 0.0045:
				continue
			if held or piece.finish == finish:
				_add_piece(surface, piece, held)
		if surface.vertices.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = surface.vertices
		arrays[Mesh.ARRAY_NORMAL] = surface.normals
		arrays[Mesh.ARRAY_COLOR] = surface.colors
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _held_material if held else _finishes[finish])
	return mesh


## Extrude a rounded or chamfered cross section, with a beveled edge at both
## ends. The small facets keep the clean silhouette of the stylized models.
static func _add_piece(surface: Surface, piece: Piece, held: bool) -> void:
	var profile := PackedVector2Array()
	var width := piece.half.x
	var height := piece.half.y
	if piece.round:
		var sides := 8 if held else 12
		for i in sides:
			var point := Vector2.from_angle(TAU * i / sides)
			profile.append(point * Vector2(width, height))
	else:
		var bevel := minf(width, height) * 0.33
		profile = PackedVector2Array([
			Vector2(-width + bevel, -height), Vector2(width - bevel, -height),
			Vector2(width, -height + bevel), Vector2(width, height - bevel),
			Vector2(width - bevel, height), Vector2(-width + bevel, height),
			Vector2(-width, height - bevel), Vector2(-width, -height + bevel),
		])
	var length := piece.half.z
	var end_bevel := minf(length * 0.40, minf(width, height) * 0.22)
	var basis := Basis(Vector3.UP, -piece.yaw) * Basis(Vector3.RIGHT, piece.pitch)
	var center := _forward(piece.center)
	var rings: Array[PackedVector3Array] = []
	var ring_count := 2 if held else 4
	for ring_index in ring_count:
		var at_end := ring_index == 0 or ring_index == ring_count - 1
		var depth := (length if at_end else length - end_bevel) * (1.0 if ring_index < ring_count / 2 else -1.0)
		var ring := PackedVector3Array()
		for p in profile:
			var inset := p * (0.82 if at_end and not held else 1.0)
			ring.append(center + basis * Vector3(inset.x, inset.y, depth))
		rings.append(ring)
	for ring_index in ring_count - 1:
		for i in profile.size():
			var j := (i + 1) % profile.size()
			var a := rings[ring_index][i]
			var b := rings[ring_index][j]
			var c := rings[ring_index + 1][j]
			var d := rings[ring_index + 1][i]
			var outward := (a + b + c + d) * 0.25 - center
			# The long middle ring is the body color; the end chamfers catch light.
			var color := piece.tint if held or ring_index == 1 else piece.tint.lightened(0.06)
			_triangle(surface, a, b, c, outward, color)
			_triangle(surface, a, c, d, outward, color)
	for ring_index in [0, ring_count - 1]:
		var direction := basis.z * (1.0 if ring_index == 0 else -1.0)
		var cap_center := center + direction * length
		for i in profile.size():
			_triangle(surface, cap_center, rings[ring_index][i],
				rings[ring_index][(i + 1) % profile.size()], direction, piece.tint)


static func _triangle(surface: Surface, a: Vector3, b: Vector3, c: Vector3,
		outward: Vector3, color: Color) -> void:
	var normal := (b - a).cross(c - a).normalized()
	var clockwise := normal.dot(outward) < 0.0
	var points := PackedVector3Array([a, b, c] if clockwise else [a, c, b])
	for vertex in points:
		surface.vertices.append(vertex)
		surface.normals.append(-normal if clockwise else normal)
		surface.colors.append(color)


class Surface:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()


class Piece:
	var center: Vector3
	var half: Vector3
	var tint: Color
	var finish: Finish
	var round: bool
	var pitch := 0.0
	var yaw := 0.0

	func _init(at: Vector3, size: Vector3, color: Color, material: Finish = Finish.STEEL,
			rounded: bool = false, tip: float = 0.0) -> void:
		center = at
		half = size
		tint = color
		finish = material
		round = rounded
		pitch = tip


class Shape:
	var gun: Array[Piece] = []
	var magazine: Array[Piece] = []
	var right_arm: Array[Piece] = []
	var support_elbow: Vector3
	var magazine_grip: Vector3
	var support_grip: Vector3
	var magazine_throw := 0.19
	var muzzle: Vector3
	var hip: Vector3
	var aim: Vector3
	var kick_back: float
	var kick_pitch: float
	var scope := false


static func _limb(from: Vector3, to: Vector3, radius: Vector2, tint: Color, finish: Finish) -> Piece:
	var d := to - from
	var piece := Piece.new((from + to) * 0.5, Vector3(radius.x, radius.y, d.length() / 2),
		tint, finish, true)
	piece.pitch = atan2(d.y, Vector2(d.x, d.z).length())
	piece.yaw = atan2(d.x, d.z)
	return piece


## An overlapping cuff, reinforced knuckles and separate fingers make the
## glove read as a hand even at the extreme first-person camera distance.
static func _arm(grip: Vector3, elbow: Vector3, side: float) -> Array[Piece]:
	return _sleeve(grip, elbow) + _glove(grip, side)


static func _sleeve(grip: Vector3, elbow: Vector3) -> Array[Piece]:
	var wrist := grip.lerp(elbow, 0.13)
	return [
		_limb(elbow, grip.lerp(elbow, 0.37), Vector2(0.047, 0.044), SLEEVE, Finish.CANVAS),
		_limb(grip.lerp(elbow, 0.42), wrist, Vector2(0.039, 0.037), SLEEVE, Finish.CANVAS),
		_limb(grip.lerp(elbow, 0.28), grip.lerp(elbow, 0.37), Vector2(0.040, 0.038), SLEEVE_SEAM, Finish.CANVAS),
		_limb(grip.lerp(elbow, 0.15), grip.lerp(elbow, 0.27), Vector2(0.041, 0.039), Color.WHITE, Finish.TEAM),
		_limb(grip.lerp(elbow, 0.06), grip.lerp(elbow, 0.15), Vector2(0.034, 0.033), GLOVE, Finish.CANVAS),
	]


static func _glove(grip: Vector3, side: float) -> Array[Piece]:
	var pieces: Array[Piece] = [
		Piece.new(grip, Vector3(0.034, 0.027, 0.045), GLOVE, Finish.CANVAS, true, -0.25),
		Piece.new(grip + Vector3(side * 0.02, 0.016, -0.014), Vector3(0.019, 0.01, 0.032),
			GLOVE.lightened(0.065), Finish.POLYMER, false, -0.30),
		Piece.new(grip + Vector3(-side * 0.023, 0.017, 0.010), Vector3(0.013, 0.012, 0.027),
			GLOVE, Finish.CANVAS, true, 0.32),
	]
	for i in 4:
		var finger := grip + Vector3(side * (0.025 - 0.014 * i), -0.015, 0.035 - 0.005 * absf(i - 1))
		pieces.append(Piece.new(finger, Vector3(0.008, 0.016, 0.018), GLOVE, Finish.CANVAS, true, -0.55))
	return pieces


static func _weapon_shapes() -> Array[Shape]:
	return [null, _carbine(), _marksman(), _sidearm()]


static func _carbine() -> Shape:
	var shape := Shape.new()
	shape.gun = [
		Piece.new(Vector3(0, -0.050, 0.070), Vector3(0.025, 0.031, 0.170), GUN_METAL),
		Piece.new(Vector3(0, -0.074, 0.045), Vector3(0.022, 0.020, 0.150), GUN_DARK),
		Piece.new(Vector3(0, -0.017, 0.076), Vector3(0.018, 0.006, 0.146), GUN_DARK),
		Piece.new(Vector3(0, -0.049, 0.311), Vector3(0.025, 0.024, 0.106), GUN_POLYMER, Finish.POLYMER),
		Piece.new(Vector3(0, -0.029, 0.311), Vector3(0.021, 0.010, 0.109), GUN_DARK),
		Piece.new(Vector3(0, -0.045, 0.473), Vector3(0.009, 0.009, 0.080), GUN_DARK, Finish.STEEL, true),
		Piece.new(Vector3(0, -0.045, 0.565), Vector3(0.014, 0.014, 0.032), GUN_METAL, Finish.STEEL, true),
		Piece.new(Vector3(0, -0.045, 0.597), Vector3(0.009, 0.009, 0.001), GUN_DARK.darkened(0.72),
			Finish.STEEL, true),
		Piece.new(Vector3(0, -0.026, 0.398), Vector3(0.015, 0.009, 0.010), GUN_DARK),
		Piece.new(Vector3(0, -0.008, 0.398), Vector3(0.002, 0.008, 0.005), GUN_DARK),
		Piece.new(Vector3(0, -0.001, 0.398), Vector3(0.0018, 0.0018, 0.004), SIGHT),
		Piece.new(Vector3(0, -0.017, -0.050), Vector3(0.019, 0.005, 0.014), GUN_DARK),
		Piece.new(Vector3(0, -0.123, -0.076), Vector3(0.017, 0.045, 0.021), GUN_POLYMER, Finish.POLYMER, false, -0.35),
		Piece.new(Vector3(0, -0.100, 0.125), Vector3(0.020, 0.023, 0.044), GUN_DARK),
		Piece.new(Vector3(0, -0.048, -0.110), Vector3(0.020, 0.025, 0.026), GUN_METAL),
		Piece.new(Vector3(0, -0.052, -0.202), Vector3(0.014, 0.015, 0.087), GUN_DARK, Finish.STEEL, true),
		Piece.new(Vector3(0, -0.083, -0.268), Vector3(0.026, 0.038, 0.075), GUN_POLYMER, Finish.POLYMER),
		Piece.new(Vector3(0, -0.087, -0.342), Vector3(0.028, 0.042, 0.007), GUN_DARK, Finish.POLYMER),
		Piece.new(Vector3(0.025, -0.045, 0.103), Vector3(0.003, 0.009, 0.041), GUN_DARK),
		Piece.new(Vector3(0.027, -0.045, 0.105), Vector3(0.004, 0.004, 0.027), GUN_EDGE),
		Piece.new(Vector3(0.029, -0.059, 0.047), Vector3(0.008, 0.007, 0.010), GUN_DARK),
	]
	for side: int in [-1, 1]:
		shape.gun.append(Piece.new(Vector3(0.010 * side, -0.007, -0.050), Vector3(0.007, 0.009, 0.011), GUN_DARK))
		shape.gun.append(Piece.new(Vector3(0.016 * side, -0.013, 0.398), Vector3(0.003, 0.012, 0.009), GUN_DARK))
		for i in 5:
			shape.gun.append(Piece.new(Vector3(0.024 * side, -0.046, 0.251 + i * 0.029),
				Vector3(0.003, 0.006, 0.009), GUN_DARK, Finish.POLYMER))
		for i in 2:
			shape.gun.append(Piece.new(Vector3(0.026 * side, -0.060, -0.017 + i * 0.149),
				Vector3(0.002, 0.004, 0.004), GUN_EDGE, Finish.STEEL, true))
	for i in 12:
		shape.gun.append(Piece.new(Vector3(0, -0.012, -0.052 + i * 0.021),
			Vector3(0.017, 0.0028, 0.0054), GUN_EDGE.darkened(0.31)))
	# Extrude the magazine along one tilted axis so its shell, floorplate
	# and ribs follow the same continuous profile through ejection.
	const MAGAZINE_PITCH := 1.36
	shape.magazine = [
		Piece.new(Vector3(0, -0.169, 0.111), Vector3(0.018, 0.031, 0.057),
			GUN_DARK, Finish.POLYMER, false, MAGAZINE_PITCH),
		Piece.new(Vector3(0, -0.224, 0.099), Vector3(0.020, 0.032, 0.006),
			GUN_EDGE.darkened(0.28), Finish.POLYMER, false, MAGAZINE_PITCH),
	]
	for side: int in [-1, 1]:
		for rib in 3:
			shape.magazine.append(Piece.new(Vector3(0.018 * side, -0.151 - 0.015 * rib, 0.115 - 0.0032 * rib),
				Vector3(0.002, 0.025, 0.003), GUN_EDGE.darkened(0.34), Finish.POLYMER, false, MAGAZINE_PITCH))
	shape.support_grip = Vector3(-0.014, -0.085, 0.307)
	shape.magazine_grip = Vector3(-0.019, -0.178, 0.107)
	shape.right_arm = _arm(Vector3(0.004, -0.119, -0.073), Vector3(0.115, -0.28, -0.42), 1.0)
	shape.support_elbow = Vector3(-0.18, -0.29, 0.017)
	shape.muzzle = Vector3(0, -0.045, 0.601)
	shape.hip = Vector3(0.152, -0.148, 0.245)
	shape.aim = Vector3(0, 0, 0.220)
	shape.kick_back = 0.035
	shape.kick_pitch = 0.05
	return shape


static func _marksman() -> Shape:
	const RECEIVER := Color8(104, 113, 110)
	const SCOPE_BODY := Color8(62, 72, 72)
	const SCOPE_RING := Color8(120, 130, 122)
	const LENS := Color8(52, 85, 89)
	var shape := Shape.new()
	shape.gun = [
		Piece.new(Vector3(0, -0.069, 0.025), Vector3(0.027, 0.028, 0.258), GUN_WOOD, Finish.WOOD),
		Piece.new(Vector3(0, -0.088, -0.237), Vector3(0.022, 0.039, 0.140), GUN_WOOD, Finish.WOOD),
		Piece.new(Vector3(0, -0.089, -0.378), Vector3(0.025, 0.043, 0.007), GUN_DARK, Finish.POLYMER),
		Piece.new(Vector3(0, -0.044, 0.059), Vector3(0.023, 0.020, 0.145), RECEIVER),
		Piece.new(Vector3(0, -0.042, 0.389), Vector3(0.010, 0.010, 0.279), GUN_DARK, Finish.STEEL, true),
		Piece.new(Vector3(0, -0.042, 0.653), Vector3(0.014, 0.014, 0.019), GUN_METAL, Finish.STEEL, true),
		Piece.new(Vector3(0, -0.042, 0.672), Vector3(0.009, 0.009, 0.001), GUN_DARK.darkened(0.65),
			Finish.STEEL, true),
		Piece.new(Vector3(0, -0.024, 0.054), Vector3(0.018, 0.007, 0.131), GUN_DARK),
		Piece.new(Vector3(0, 0.002, 0.054), Vector3(0.018, 0.018, 0.140), SCOPE_BODY, Finish.STEEL, true),
		Piece.new(Vector3(0, 0.002, 0.179), Vector3(0.030, 0.030, 0.054), SCOPE_BODY, Finish.STEEL, true),
		Piece.new(Vector3(0, 0.002, 0.223), Vector3(0.031, 0.031, 0.009), SCOPE_RING, Finish.STEEL, true),
		Piece.new(Vector3(0, 0.002, 0.233), Vector3(0.024, 0.024, 0.003), LENS, Finish.OPTIC, true),
		Piece.new(Vector3(0, 0.002, -0.088), Vector3(0.024, 0.024, 0.033), GUN_DARK, Finish.POLYMER, true),
		Piece.new(Vector3(0, 0.002, -0.117), Vector3(0.025, 0.025, 0.006), SCOPE_RING, Finish.STEEL, true),
		Piece.new(Vector3(0, 0.002, -0.124), Vector3(0.018, 0.018, 0.003), LENS, Finish.OPTIC, true),
		Piece.new(Vector3(0, 0.023, 0.029), Vector3(0.012, 0.011, 0.012), GUN_EDGE.darkened(0.3), Finish.STEEL, true),
		Piece.new(Vector3(0.027, -0.047, -0.016), Vector3(0.008, 0.006, 0.032), GUN_EDGE),
		Piece.new(Vector3(0.043, -0.066, -0.038), Vector3(0.009, 0.010, 0.013), GUN_DARK, Finish.STEEL, true),
		Piece.new(Vector3(0, -0.108, -0.124), Vector3(0.019, 0.036, 0.060), GUN_WOOD, Finish.WOOD, false, -0.30),
	]
	for position: float in [-0.019, 0.103]:
		shape.gun.append(Piece.new(Vector3(0, -0.023, position), Vector3(0.013, 0.013, 0.013), RECEIVER))
		shape.gun.append(Piece.new(Vector3(0, 0.002, position), Vector3(0.020, 0.020, 0.006), SCOPE_RING,
			Finish.STEEL, true))
	shape.magazine = [
		Piece.new(Vector3(0, -0.111, 0.089), Vector3(0.020, 0.028, 0.039), GUN_DARK),
		Piece.new(Vector3(0, -0.136, 0.089), Vector3(0.022, 0.005, 0.039), GUN_EDGE.darkened(0.3)),
	]
	shape.support_grip = Vector3(-0.025, -0.096, 0.244)
	shape.magazine_grip = Vector3(-0.024, -0.130, 0.089)
	shape.magazine_throw = 0.15
	shape.right_arm = _arm(Vector3(0.006, -0.120, -0.123), Vector3(0.124, -0.28, -0.47), 1.0)
	shape.support_elbow = Vector3(-0.168, -0.26, -0.02)
	shape.muzzle = Vector3(0, -0.042, 0.674)
	shape.hip = Vector3(0.143, -0.127, 0.285)
	shape.aim = Vector3(0, 0, 0.17)
	shape.kick_back = 0.07
	shape.kick_pitch = 0.12
	shape.scope = true
	return shape


static func _sidearm() -> Shape:
	var shape := Shape.new()
	shape.gun = [
		Piece.new(Vector3(0, -0.013, 0.024), Vector3(0.015, 0.015, 0.095), GUN_METAL),
		Piece.new(Vector3(0, -0.036, 0.024), Vector3(0.014, 0.010, 0.085), GUN_POLYMER, Finish.POLYMER),
		Piece.new(Vector3(0, -0.086, -0.047), Vector3(0.017, 0.052, 0.022), GUN_POLYMER, Finish.POLYMER, false, -0.24),
		Piece.new(Vector3(0, -0.013, 0.118), Vector3(0.009, 0.009, 0.005), GUN_DARK, Finish.STEEL, true),
		Piece.new(Vector3(0, -0.013, 0.123), Vector3(0.005, 0.005, 0.001), GUN_DARK.darkened(0.7), Finish.STEEL, true),
		Piece.new(Vector3(0, -0.065, 0.030), Vector3(0.005, 0.004, 0.027), GUN_DARK, Finish.POLYMER),
		Piece.new(Vector3(0, -0.052, 0.053), Vector3(0.005, 0.015, 0.005), GUN_DARK, Finish.POLYMER, false, 0.35),
		Piece.new(Vector3(0, 0.003, 0.107), Vector3(0.003, 0.004, 0.006), GUN_DARK),
		Piece.new(Vector3(0, 0.003, 0.102), Vector3(0.0018, 0.0018, 0.001), SIGHT),
		Piece.new(Vector3(0.015, -0.010, 0.021), Vector3(0.002, 0.007, 0.025), GUN_DARK),
		Piece.new(Vector3(0.017, -0.011, 0.012), Vector3(0.0025, 0.003, 0.015), GUN_EDGE),
	]
	for side: int in [-1, 1]:
		shape.gun.append(Piece.new(Vector3(0.010 * side, 0.003, -0.060), Vector3(0.005, 0.005, 0.009), GUN_DARK))
		for i in 5:
			shape.gun.append(Piece.new(Vector3(0.015 * side, -0.014, -0.057 + i * 0.006),
				Vector3(0.0014, 0.011, 0.0015), GUN_DARK, Finish.STEEL, false, -0.22))
	shape.magazine = [
		Piece.new(Vector3(0, -0.116, -0.052), Vector3(0.012, 0.024, 0.014), GUN_METAL, Finish.STEEL, false, -0.24),
		Piece.new(Vector3(0, -0.140, -0.058), Vector3(0.017, 0.006, 0.021), GUN_DARK, Finish.POLYMER, false, -0.24),
	]
	shape.support_grip = Vector3(-0.024, -0.090, -0.034)
	shape.magazine_grip = Vector3(-0.020, -0.140, -0.054)
	shape.magazine_throw = 0.18
	shape.right_arm = _arm(Vector3(0.006, -0.077, -0.045), Vector3(0.113, -0.234, -0.408), 1.0)
	shape.support_elbow = Vector3(-0.146, -0.232, -0.363)
	shape.muzzle = Vector3(0, -0.013, 0.126)
	shape.hip = Vector3(0.105, -0.103, 0.388)
	shape.aim = Vector3(0, -0.004, 0.36)
	shape.kick_back = 0.03
	shape.kick_pitch = 0.18
	return shape

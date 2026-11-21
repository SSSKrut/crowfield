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
## A weapon model is built of boxes in a space where X points right, Y up and Z
## forward, with the line of its sights along +Z through the origin, so that
## aiming puts that line on the crosshair. Its meshes have Z pointing
## backwards, as Godot cameras look along -Z: _forward turns a point of the
## boxes' space into mesh space.

## FIELD_OF_VIEW draws the weapon in hand at a constant size, while the world
## zooms when aiming.
const FIELD_OF_VIEW := 58.0
## The weapon in hand comes to the sights in AIM_TIME and leaves them in the
## same; a shot's kick of the model fades with RECOIL_TIME.
const AIM_TIME := 0.15
const RECOIL_TIME := 0.06
const FLASH_TIME := 0.05
## A soldier holds its weapon at its right side, at the height of the chest and
## somewhat forward, along its aim.
const HELD_SCALE := 0.94
const HELD_OFFSET := Vector3(0.085, 1.29, 0.30)
## LIGHT is where the light of the world comes from when no sun is given: the
## direction the box models of the prototype were lit from.
const LIGHT := Vector3(0.4, 1.0, 0.3)

const GUN_METAL := Color8(58, 60, 64)
const GUN_DARK := Color8(32, 33, 36)
const GUN_POLYMER := Color8(74, 76, 66)
const GUN_WOOD := Color8(124, 82, 47)
const SLEEVE := Color8(98, 106, 78)
const GLOVE := Color8(46, 50, 44)
const FLASH_CORE := Color8(255, 214, 120)
const FLASH_FLAME := Color8(255, 170, 60, 220)

## aim goes from 0 at the hip to 1 down the sights.
var aim := 0.0
## sun is the light of the world, which the overlay copies; without one the
## overlay is lit from LIGHT.
var sun: DirectionalLight3D
## overlay shows the weapon in hand over the world; layer holds it.
var overlay: SubViewportContainer
var layer: CanvasLayer

## _shapes are the weapon models by kind, null for none; _models their meshes
## in first person, with the arms, and _held the guns alone, as other soldiers
## carry them. Both are built once and shared.
var _shapes: Array[Shape] = []
var _models: Array[ArrayMesh] = []
var _held: Array[ArrayMesh] = []
var _gun_material := StandardMaterial3D.new()
var _accent_material := StandardMaterial3D.new()
var _viewport: SubViewport
var _camera: Camera3D
var _light: DirectionalLight3D
var _instances: Array[MeshInstance3D] = []
var _flash_core: MeshInstance3D
var _flash_flame: MeshInstance3D
var _shown := WeaponTuning.Kind.NONE
## The walk sways the model: _bob is its phase, _stride its strength.
var _bob := 0.0
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
	for material in [_gun_material, _accent_material]:
		material.roughness = 1.0
		material.metallic_specular = 0.2
	_gun_material.vertex_color_use_as_albedo = true
	_gun_material.vertex_color_is_srgb = true
	_shapes = _weapon_shapes()
	_models.resize(WeaponTuning.KINDS)
	_held.resize(WeaponTuning.KINDS)
	for kind in WeaponTuning.KINDS:
		var shape := _shapes[kind]
		if shape != null:
			var all: Array[Box] = []
			all.append_array(shape.gun)
			all.append_array(shape.arms)
			_models[kind] = _mesh(all)
			_held[kind] = _mesh(shape.gun)


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
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	overlay.add_child(_viewport)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(1, 1, 1)
	environment.ambient_light_energy = 0.55
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
	for kind in WeaponTuning.KINDS:
		if _models[kind] == null:
			continue
		var instance := MeshInstance3D.new()
		instance.mesh = _models[kind]
		instance.visible = false
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_viewport.add_child(instance)
		_instances[kind] = instance
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
	_accent_material.albedo_color = tint
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


## update moves the model for a frame. speed is the soldier's share of the
## sprint speed; look is how far the view turned this frame, in radians: yaw
## to the right, pitch up.
func update(delta: float, aiming: bool, sprinting: bool, grounded: bool, speed: float, look: Vector2) -> void:
	var rate := delta / AIM_TIME
	aim = minf(1.0, aim + rate) if aiming else maxf(0.0, aim - rate)
	var stride := minf(1.0, speed) if grounded else 0.0
	_stride += (stride - _stride) * minf(1.0, delta * 8)
	_bob += delta * (5 + 6 * speed)
	_sprint += ((1.0 if sprinting else 0.0) - _sprint) * minf(1.0, delta * 10)
	for i in 2:
		var target := clampf(-look[i] * 0.6, -0.04, 0.04)
		_sway[i] += (target - _sway[i]) * minf(1.0, delta * 12)
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
	var offset := shape.hip + (shape.aim - shape.hip) * aim
	offset += Vector3(
		0.012 * _stride * sin(_bob) * calm + _sway.x * calm,
		-0.01 * _stride * absf(cos(_bob)) * calm + _sway.y * calm,
		-shape.kick_back * _recoil * (1 - 0.5 * aim))
	offset += Vector3(-0.03, -0.06, -0.06) * _sprint
	var pitch := shape.kick_pitch * _recoil * calm - 0.45 * _sprint
	# Sprinting carries the weapon across the body, muzzle down and left.
	var yaw := -0.55 * _sprint
	var roll := 0.0
	match action:
		Arsenal.Action.EQUIPPING:
			var lower := (1 - progress) * (1 - progress)
			offset += Vector3(0, -0.25 * lower, 0)
			pitch -= 0.7 * lower
		Arsenal.Action.RELOADING:
			var dip := sin(PI * progress)
			offset += Vector3(0, -0.07 * dip, -0.03 * dip)
			pitch -= 0.25 * dip
			roll += 0.6 * dip
	var basis := Basis(Vector3.UP, -yaw) * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)
	var local := Transform3D(basis, _forward(offset))
	_muzzle = local * _forward(shape.muzzle)
	if _viewport == null:
		return true
	var visible := not scoped(kind)
	var instance := _instances[kind]
	instance.transform = local
	instance.visible = visible and kind == _shown
	_place_flash(visible and kind == _shown)
	_place_light(camera)
	return true


func _place_flash(visible: bool) -> void:
	if not visible or _flash <= 0:
		_flash_core.visible = false
		_flash_flame.visible = false
		return
	var size := _flash / FLASH_TIME
	_flash_core.visible = true
	_flash_core.transform = Transform3D(Basis.from_scale(Vector3.ONE * 0.028 * size), _muzzle)
	var length := 0.09 + 0.05 * _flash_turn
	var radius := 0.03 * size
	_flash_flame.visible = true
	# The flame points along the view: -Z of the eye.
	_flash_flame.transform = Transform3D(Basis(Vector3(radius, 0, 0), Vector3(0, 0, -length), Vector3(0, radius, 0)),
		_muzzle + Vector3(0, 0, -length / 2))


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
## it, or null for none. Place it with held_transform every frame. tint is the
## colour of team-coloured parts; the guns have none yet.
func make_held(kind: int, tint: Color = Color.WHITE) -> Node3D:
	if _shape_of(kind) == null:
		return null
	var instance := MeshInstance3D.new()
	instance.name = "Held"
	instance.mesh = _held[kind]
	if _held[kind].get_surface_count() > 1:
		var accent := _accent_material.duplicate() as StandardMaterial3D
		accent.albedo_color = tint
		instance.set_surface_override_material(1, accent)
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


## _mesh builds boxes into one mesh with flat faces: a surface of the coloured
## boxes, and one of the accent boxes, which take the team colour.
func _mesh(boxes: Array[Box]) -> ArrayMesh:
	var plain := Part.new()
	var accent := Part.new()
	for box in boxes:
		_add_box(accent if box.accent else plain, box)
	var mesh := ArrayMesh.new()
	for part: Part in [plain, accent]:
		if part.vertices.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = part.vertices
		arrays[Mesh.ARRAY_NORMAL] = part.normals
		arrays[Mesh.ARRAY_COLOR] = part.colors
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _accent_material if part == accent else _gun_material)
	return mesh


## Every face of a box by its corners in turn; bits 0, 1 and 2 of a corner's
## index choose its side in X, Y and Z.
const _FACES := [[0, 2, 6, 4], [1, 5, 7, 3], [0, 4, 5, 1], [2, 3, 7, 6], [0, 1, 3, 2], [4, 6, 7, 5]]


func _add_box(part: Part, box: Box) -> void:
	var center := _forward(box.center)
	# A turn about X by the pitch lifts what points along -Z, and a turn about
	# Y against the yaw takes it to the right.
	var turn := Basis(Vector3.UP, -box.yaw) * Basis(Vector3.RIGHT, box.pitch)
	var corners: Array[Vector3] = []
	for i in 8:
		var corner := Vector3(box.half.x * ((i & 1) * 2 - 1), box.half.y * (((i >> 1) & 1) * 2 - 1),
			box.half.z * (((i >> 2) & 1) * 2 - 1))
		corners.append(center + turn * _forward(corner))
	var color := Color.WHITE if box.accent else box.color
	for face in _FACES:
		var a := corners[face[0]]
		var b := corners[face[1]]
		var c := corners[face[2]]
		var d := corners[face[3]]
		var normal := (b - a).cross(c - a).normalized()
		var outward := normal if normal.dot((a + c) * 0.5 - center) >= 0 else -normal
		# Godot draws the faces wound clockwise as seen from outside.
		var triangles := [a, c, b, a, d, c] if normal.dot(outward) > 0 else [a, b, c, a, c, d]
		for vertex: Vector3 in triangles:
			part.vertices.append(vertex)
			part.normals.append(outward)
			part.colors.append(color)


## Part is a surface of a mesh being built.
class Part:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()


## Box is a part of a model built of boxes. Its center and half size are in the
## model's space, where X points right, Y up and Z forward. pitch tips its
## front up, and then yaw turns it to the right, in radians. Accent parts take
## the team colour.
class Box:
	var center: Vector3
	var half: Vector3
	var color: Color
	var pitch := 0.0
	var yaw := 0.0
	var accent := false

	func _init(at: Vector3, size: Vector3, tint: Color, tip: float = 0.0) -> void:
		center = at
		half = size
		color = tint
		pitch = tip


## Shape is how a weapon looks in the player's hands.
class Shape:
	## gun is the weapon itself, arms the hands that hold it in first person.
	var gun: Array[Box] = []
	var arms: Array[Box] = []
	var muzzle: Vector3
	## hip and aim place the origin of the model in front of the eye: X right,
	## Y up, Z forward.
	var hip: Vector3
	var aim: Vector3
	## A shot throws the model back by kick_back metres and its muzzle up by
	## kick_pitch radians.
	var kick_back: float
	var kick_pitch: float
	## scope replaces the model with the view through a scope when aiming.
	var scope := false


## _limb is a box from one point to another, for arms.
static func _limb(from: Vector3, to: Vector3, half: float, tint: Color) -> Box:
	var d := to - from
	var box := Box.new((from + to) * 0.5, Vector3(half, half, d.length() / 2), tint)
	box.pitch = atan2(d.y, Vector2(d.x, d.z).length())
	box.yaw = atan2(d.x, d.z)
	return box


## _arms adds uniform sleeves, team wrist bands and gloves around the grips.
static func _arms(right: Vector3, right_elbow: Vector3, left: Vector3, left_elbow: Vector3) -> Array[Box]:
	var hand := Vector3(0.032, 0.036, 0.042)
	var right_band := _limb(right.lerp(right_elbow, 0.12), right.lerp(right_elbow, 0.23), 0.040, Color.WHITE)
	var left_band := _limb(left.lerp(left_elbow, 0.12), left.lerp(left_elbow, 0.23), 0.038, Color.WHITE)
	right_band.accent = true
	left_band.accent = true
	return [_limb(right_elbow, right, 0.038, SLEEVE), _limb(left_elbow, left, 0.036, SLEEVE),
		right_band, left_band, Box.new(right, hand, GLOVE), Box.new(left, hand, GLOVE)]


static func _weapon_shapes() -> Array[Shape]:
	var shapes: Array[Shape] = []
	shapes.resize(WeaponTuning.KINDS)
	var rifle := Shape.new()
	rifle.gun = [
		Box.new(Vector3(0, -0.055, 0.06), Vector3(0.024, 0.034, 0.17), GUN_METAL),
		Box.new(Vector3(0, -0.019, 0.07), Vector3(0.01, 0.004, 0.15), GUN_DARK),
		Box.new(Vector3(0, -0.05, 0.31), Vector3(0.028, 0.03, 0.09), GUN_POLYMER),
		Box.new(Vector3(0, -0.045, 0.47), Vector3(0.009, 0.009, 0.08), GUN_DARK),
		Box.new(Vector3(0, -0.045, 0.57), Vector3(0.013, 0.013, 0.025), GUN_DARK),
		Box.new(Vector3(0, -0.009, 0.37), Vector3(0.0018, 0.009, 0.003), GUN_DARK),
		Box.new(Vector3(0, -0.026, 0.37), Vector3(0.012, 0.008, 0.006), GUN_DARK),
		Box.new(Vector3(-0.0065, -0.007, -0.045), Vector3(0.002, 0.009, 0.003), GUN_DARK),
		Box.new(Vector3(0.0065, -0.007, -0.045), Vector3(0.002, 0.009, 0.003), GUN_DARK),
		Box.new(Vector3(0, -0.16, 0.12), Vector3(0.015, 0.07, 0.028), GUN_DARK, 0.3),
		Box.new(Vector3(0, -0.125, -0.06), Vector3(0.015, 0.05, 0.02), GUN_POLYMER, -0.35),
		Box.new(Vector3(0, -0.07, -0.24), Vector3(0.02, 0.04, 0.09), GUN_POLYMER),
	]
	rifle.arms = _arms(Vector3(0.004, -0.11, -0.05), Vector3(0.11, -0.3, -0.42), Vector3(-0.006, -0.085, 0.3), Vector3(-0.17, -0.3, 0.02))
	rifle.muzzle = Vector3(0, -0.045, 0.6)
	rifle.hip = Vector3(0.15, -0.16, 0.26)
	rifle.aim = Vector3(0, 0, 0.23)
	rifle.kick_back = 0.035
	rifle.kick_pitch = 0.05
	shapes[WeaponTuning.Kind.ASSAULT_RIFLE] = rifle
	var marksman := Shape.new()
	marksman.gun = [
		Box.new(Vector3(0, -0.065, 0), Vector3(0.022, 0.035, 0.3), GUN_WOOD),
		Box.new(Vector3(0, -0.04, 0.08), Vector3(0.018, 0.018, 0.13), GUN_METAL),
		Box.new(Vector3(0, -0.04, 0.45), Vector3(0.01, 0.01, 0.22), GUN_DARK),
		Box.new(Vector3(0, 0, 0.05), Vector3(0.018, 0.018, 0.12), GUN_DARK),
		Box.new(Vector3(0, 0, 0.19), Vector3(0.026, 0.026, 0.03), GUN_DARK),
		Box.new(Vector3(0, 0, -0.085), Vector3(0.022, 0.022, 0.025), GUN_DARK),
		Box.new(Vector3(0, -0.024, 0), Vector3(0.008, 0.008, 0.01), GUN_METAL),
		Box.new(Vector3(0, -0.024, 0.11), Vector3(0.008, 0.008, 0.01), GUN_METAL),
		Box.new(Vector3(0, -0.11, 0.06), Vector3(0.014, 0.025, 0.035), GUN_DARK),
		Box.new(Vector3(0, -0.11, -0.15), Vector3(0.018, 0.045, 0.06), GUN_WOOD, -0.3),
		Box.new(Vector3(0, -0.09, -0.32), Vector3(0.02, 0.05, 0.07), GUN_WOOD),
	]
	marksman.arms = _arms(Vector3(0.004, -0.11, -0.13), Vector3(0.12, -0.3, -0.48), Vector3(-0.006, -0.095, 0.24), Vector3(-0.17, -0.3, -0.02))
	marksman.muzzle = Vector3(0, -0.04, 0.67)
	marksman.hip = Vector3(0.15, -0.15, 0.24)
	marksman.aim = Vector3(0, 0, 0.16)
	marksman.kick_back = 0.07
	marksman.kick_pitch = 0.12
	marksman.scope = true
	shapes[WeaponTuning.Kind.RIFLE] = marksman
	var pistol := Shape.new()
	pistol.gun = [
		Box.new(Vector3(0, -0.012, 0.03), Vector3(0.013, 0.016, 0.09), GUN_METAL),
		Box.new(Vector3(0, -0.036, 0.025), Vector3(0.012, 0.009, 0.08), GUN_DARK),
		Box.new(Vector3(0, -0.085, -0.04), Vector3(0.013, 0.048, 0.022), GUN_DARK, -0.25),
		Box.new(Vector3(0, -0.055, 0.03), Vector3(0.003, 0.012, 0.02), GUN_DARK),
		Box.new(Vector3(0, 0.006, 0.11), Vector3(0.002, 0.003, 0.003), GUN_DARK),
		Box.new(Vector3(-0.006, 0.006, -0.05), Vector3(0.003, 0.003, 0.003), GUN_DARK),
		Box.new(Vector3(0.006, 0.006, -0.05), Vector3(0.003, 0.003, 0.003), GUN_DARK),
	]
	pistol.arms = _arms(Vector3(0.006, -0.08, -0.05), Vector3(0.1, -0.24, -0.38), Vector3(-0.024, -0.088, -0.035), Vector3(-0.15, -0.24, -0.36))
	pistol.muzzle = Vector3(0, -0.012, 0.125)
	pistol.hip = Vector3(0.1, -0.095, 0.4)
	pistol.aim = Vector3(0, -0.003, 0.36)
	pistol.kick_back = 0.03
	pistol.kick_pitch = 0.18
	shapes[WeaponTuning.Kind.PISTOL] = pistol
	return shapes

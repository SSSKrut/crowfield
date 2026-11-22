class_name VehicleViews
extends Node3D
## VehicleViews draws the tanks the server reports: the CF-27 model with its
## hull on the ground, its turret turned and its gun raised. They are drawn
## between snapshots like the soldiers, in the past, and the player's own tank
## one snapshot nearer the present. Each tank has a copy of its body in the
## client's world, so the player's soldier, shots and camera meet it where the
## server has it.

const MODEL := preload("res://assets/vehicles/tank_cf27.glb")
## The gun kicks back RECOIL metres when it fires and returns in RECOIL_TIME.
const RECOIL := 0.35
const RECOIL_TIME := 0.35
## How long the snapshot history reaches back, in snapshots.
const HISTORY := 12

var scene: MapScene
var effects: Effects
## volume is the master volume; with none the tanks are silent.
var volume := 0.0
var _space: RID
var _ground: RID
var _views := {}
## _history holds [server tick, {id: Vehicle}] of the latest snapshots.
var _history: Array[Array] = []
var _wreck: StandardMaterial3D


## View is a tank as drawn: its model, the nodes that turn, the copy of its
## body, and the state drawn last.
class View:
	var node: Node3D
	var turret: Node3D
	var gun: Node3D
	var controller: TankController
	var drawn: Vehicle
	var shots := -1
	var recoil := 0.0
	var wrecked := false
	var engine: AudioStreamPlayer3D


func _init(map: MapScene, space: RID, ground: RID) -> void:
	name = "Vehicles"
	scene = map
	_space = space
	_ground = ground
	_wreck = StandardMaterial3D.new()
	_wreck.albedo_color = Color(0.05, 0.045, 0.04, 0.78)
	_wreck.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_wreck.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


func _exit_tree() -> void:
	for view: View in _views.values():
		view.controller.close()


## observe keeps the vehicles of a snapshot.
func observe(server_tick: int, vehicles: Array[VehicleState]) -> void:
	if not _history.is_empty() and server_tick <= _history[-1][0]:
		return
	var states := {}
	for state in vehicles:
		states[state.id] = state.vehicle()
	_history.append([server_tick, states])
	if _history.size() > HISTORY:
		_history.pop_front()


## update draws every tank at the time the player sees it: own, the tank the
## player drives, nearer the present.
func update(delta: float, render: float, own_render: float, own_soldier: int) -> void:
	if _history.is_empty():
		return
	var latest: Dictionary = _history[-1][1]
	for id: int in latest:
		var newest: Vehicle = latest[id]
		var vehicle := sample(id, own_render if own_soldier != 0 and newest.driver == own_soldier else render)
		var view: View = _views.get(id)
		if view == null:
			view = _make(id)
		_draw(view, vehicle, delta)


## sample is a tank as it was at a time, between the snapshots around it.
func sample(id: int, at: float) -> Vehicle:
	var before: Vehicle = null
	var before_tick := 0
	for entry in _history:
		var vehicle: Vehicle = entry[1].get(id)
		if vehicle == null:
			continue
		if entry[0] <= at:
			before = vehicle
			before_tick = entry[0]
			continue
		if before == null or vehicle.wrecked != before.wrecked or before.position.distance_to(vehicle.position) > 20.0:
			return vehicle
		var after_tick: int = entry[0]
		var share := (at - before_tick) / float(after_tick - before_tick)
		var blended := vehicle.copy()
		blended.position = before.position.lerp(vehicle.position, share)
		blended.yaw = lerp_angle(before.yaw, vehicle.yaw, share)
		blended.turret = lerp_angle(before.turret, vehicle.turret, share)
		blended.gun = lerpf(before.gun, vehicle.gun, share)
		blended.speed = lerpf(before.speed, vehicle.speed, share)
		return blended
	return before


## driven is the tank a soldier drives as drawn last, or null.
func driven(soldier: int) -> Vehicle:
	if soldier == 0:
		return null
	for view: View in _views.values():
		if view.drawn != null and view.drawn.driver == soldier and not view.drawn.wrecked:
			return view.drawn
	return null


## drivers are the soldiers in the tanks, whom no one sees.
func drivers() -> Dictionary:
	var found := {}
	if not _history.is_empty():
		for vehicle: Vehicle in _history[-1][1].values():
			if vehicle.driver != 0:
				found[vehicle.driver] = true
	return found


## nearest_empty is the empty tank within reach of a point, or null.
func nearest_empty(at: Vector3) -> Vehicle:
	for view: View in _views.values():
		var vehicle := view.drawn
		if vehicle == null or vehicle.wrecked or vehicle.driver != 0:
			continue
		var local := TankController.hull_transform(scene, vehicle.position, vehicle.yaw).affine_inverse() * at
		var reach := (local - Vehicle.HULL_CENTER) - (local - Vehicle.HULL_CENTER).clamp(-Vehicle.HULL_HALF, Vehicle.HULL_HALF)
		if reach.length() <= Vehicle.REACH:
			return vehicle
	return null


func _make(id: int) -> View:
	var view := View.new()
	view.node = MODEL.instantiate()
	view.node.name = "Tank%d" % id
	add_child(view.node)
	view.turret = view.node.find_child("Turret_Pivot", true, false) as Node3D
	view.gun = view.node.find_child("Gun_Pivot", true, false) as Node3D
	view.controller = TankController.new(_space, scene, _ground)
	if volume > 0.0:
		view.engine = AudioStreamPlayer3D.new()
		view.engine.stream = _engine_sound()
		view.engine.unit_size = 14.0
		view.engine.volume_db = linear_to_db(0.45 * volume)
		view.node.add_child(view.engine)
		view.engine.play()
	_views[id] = view
	return view


## _engine_sound is the loop of a diesel at idle: a low hum of a few
## harmonics, beating with its cylinders. Its partials fit a whole number of
## times into the loop, so it repeats without a seam.
static func _engine_sound() -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	samples.resize(Sounds.SAMPLE_RATE)
	for i in samples.size():
		var t := float(i) / Sounds.SAMPLE_RATE
		var beat := 0.72 + 0.28 * sin(TAU * 9.0 * t)
		samples[i] = beat * (0.55 * sin(TAU * 38.0 * t) + 0.3 * sin(TAU * 76.0 * t + 0.6)
			+ 0.18 * sin(TAU * 114.0 * t + 1.1) + 0.07 * sin(TAU * 190.0 * t + 2.0))
	var stream := Sounds._to_stream(samples)
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = samples.size()
	return stream


func _draw(view: View, vehicle: Vehicle, delta: float) -> void:
	var first := view.drawn == null
	view.drawn = vehicle
	# The model looks along +Z; vehicle space along -Z.
	view.node.global_transform = TankController.hull_transform(scene, vehicle.position, vehicle.yaw) * Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	view.recoil = maxf(0.0, view.recoil - delta / RECOIL_TIME)
	if view.shots != vehicle.shots and not first and not vehicle.wrecked:
		view.recoil = 1.0
		_fired(vehicle)
	view.shots = vehicle.shots
	if view.turret != null:
		view.turret.rotation.y = -vehicle.turret
	if view.gun != null:
		view.gun.rotation.x = -vehicle.gun
		view.gun.position.z = Vehicle.GUN_PIVOT.z * -1.0 - RECOIL * view.recoil * view.recoil
	if view.engine != null:
		view.engine.pitch_scale = 0.75 + 0.5 * absf(vehicle.speed) / TankController.MAX_SPEED
	if vehicle.wrecked != view.wrecked:
		view.wrecked = vehicle.wrecked
		if view.engine != null:
			view.engine.playing = not vehicle.wrecked
		for found in view.node.find_children("*", "MeshInstance3D", true, false):
			(found as MeshInstance3D).material_overlay = _wreck if vehicle.wrecked else null
	view.controller.place(vehicle)


## _fired shows the blast of the gun at its muzzle.
func _fired(vehicle: Vehicle) -> void:
	if effects == null:
		return
	var gun := TankController.gun_of(scene, vehicle)
	var muzzle := gun * Vector3(0, 0, -Vehicle.MUZZLE)
	effects.blast(muzzle + gun.basis * Vector3(0, 0, -0.6), 1.6)
	effects.flash(muzzle)

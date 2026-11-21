class_name Sounds
extends Node
## Local feedback, spatial combat sounds and Valley ambience.
## With a volume of zero the game is silent and creates no players.

const SAMPLE_RATE := 44100
## Rapid fire overlaps: every weapon sound plays on SHOT_VOICES voices in turn.
const SHOT_VOICES := 6
## Shots of other soldiers play on this many positional voices in turn.
const POSITIONAL_VOICES := 24
## Movement has its own voices so a passing group cannot cut off gunfire.
const REMOTE_FOOTSTEP_VOICES := 8
const REMOTE_FOOTSTEP_RANGE := 16.0
## A distant shot is half as loud at this distance, before the spatial mix.
const FALLOFF_DISTANCE := 20.0
const QUIETEST := 0.03
const SHOT_COVER_RAYS_PER_FRAME := 8
const SHOT_COVER_GAIN := 0.60
const COVER_FILTER_HZ := 1500.0
const DIRECT_FILTER_HZ := 5000.0
const WIND := preload("res://assets/audio/ambience/wind.ogg")
const RIVER := preload("res://assets/audio/ambience/river.ogg")

const SHOT_VOLUMES := [0.0, 0.70, 0.82, 0.62]
const SHOT_PITCHES := [1.0, 0.98, 1.02, 0.99, 1.01, 1.0]
const GUNSHOTS := {
	WeaponTuning.Kind.ASSAULT_RIFLE: preload("res://assets/audio/assault-shot.wav"),
	WeaponTuning.Kind.RIFLE: preload("res://assets/audio/rifle-shot.wav"),
	WeaponTuning.Kind.PISTOL: preload("res://assets/audio/pistol-shot.wav"),
}

enum Surface { FIELD, HARD, WOOD, MUD }
const FOOTSTEPS := [
	[preload("res://assets/audio/footing/grass-1.wav"), preload("res://assets/audio/footing/grass-2.wav"),
		preload("res://assets/audio/footing/grass-3.wav")],
	[preload("res://assets/audio/footing/concrete-1.wav"), preload("res://assets/audio/footing/concrete-2.wav"),
		preload("res://assets/audio/footing/concrete-3.wav")],
	[preload("res://assets/audio/footing/wood-1.wav"), preload("res://assets/audio/footing/wood-2.wav"),
		preload("res://assets/audio/footing/wood-3.wav")],
	[preload("res://assets/audio/footing/mud.wav")],
]
const LAND := preload("res://assets/audio/footing/land.wav")
const STRIKE := preload("res://assets/audio/footing/strike.wav")
const DAMAGE := preload("res://assets/audio/footing/damage.wav")

var _volume := 0.0
var _audible := false
## _shots holds, by weapon kind, its voices; _next the voice to play next.
var _shots := {}
var _next := {}
var _positional: Array[AudioStreamPlayer3D] = []
var _next_positional := 0
var _shot_cover_query := PhysicsRayQueryParameters3D.new()
var _shot_cover_frame := -1
var _shot_cover_rays := 0
var _remote_boots: Array[AudioStreamPlayer3D] = []
var _remote_step_number := 0
var _dry: AudioStreamPlayer
var _magazine_out: AudioStreamPlayer
var _magazine_in: AudioStreamPlayer
var _equip: AudioStreamPlayer
## _marker ticks when a shot of the player hurt someone.
var _marker: AudioStreamPlayer
var _kill_marker: AudioStreamPlayer
var _flag_captured: AudioStreamPlayer
var _flag_lost: AudioStreamPlayer
var _boots: Array[AudioStreamPlayer] = []
var _landing: AudioStreamPlayer
var _damage: AudioStreamPlayer
var _step_number := 0
var _last_impact_usec := -1000000
var _river: AudioStreamPlayer3D
var _river_water: MapScene.Water
var _river_gain := 0.0


## volume is the master volume from 0 to 1.
func _init(volume: float) -> void:
	name = "Sounds"
	_volume = clampf(volume, 0.0, 1.0)
	if _volume <= 0:
		return
	_audible = true
	_shot_cover_query.collision_mask = Game.LAYER_STATIC | Game.LAYER_VEHICLE
	for kind in GUNSHOTS:
		var stream: AudioStreamWAV = GUNSHOTS[kind]
		var voices: Array[AudioStreamPlayer] = []
		for i in SHOT_VOICES:
			var voice := _player(stream, SHOT_VOLUMES[kind])
			voice.pitch_scale = SHOT_PITCHES[i]
			voices.append(voice)
		_shots[kind] = voices
		_next[kind] = 0
	_dry = _player(_to_stream(_click(0.05, 0.004, 0.9, 0.0, 7)), 0.4)
	_magazine_out = _player(preload("res://assets/audio/magazine-out.wav"), 0.38)
	_magazine_in = _player(preload("res://assets/audio/magazine-in.wav"), 0.46)
	_equip = _player(_to_stream(_clicks(0.2, 0.0, 0.06)), 0.3)
	_marker = _player(_cue(1400.0), 0.30)
	_kill_marker = _player(_cue(875.0, 1312.5), 0.40)
	_flag_captured = _player(_cue(440.0, 660.0), 0.31)
	_flag_lost = _player(_cue(392.0, 294.0), 0.23)
	for voice in 2:
		_boots.append(_player(null, 0.23))
	_landing = _player(LAND, 0.26)
	_landing.pitch_scale = 0.84
	_damage = _player(DAMAGE, 0.36)
	for i in POSITIONAL_VOICES:
		_positional.append(_spatial_player())
	for i in REMOTE_FOOTSTEP_VOICES:
		_remote_boots.append(_spatial_player())


## Valley has one water surface. The visible river meanders across it.
func start_ambience(scene: MapScene) -> void:
	if not _audible or _river != null or scene.name != "valley" or scene.waters.is_empty():
		return
	var wind := _player(WIND, 0.12)
	wind.name = "ValleyWind"
	wind.play()
	_river_water = scene.waters[0]
	_river = _spatial_player()
	_river.name = "ValleyRiver"
	_river.stream = RIVER
	_river.volume_db = -80.0
	_river.play()


## Move a single positional voice along the river, so it follows the bank
## at each crossing without overlapping loop phases from several emitters.
func update_ambience(listener: Vector3, delta: float) -> void:
	if _river == null:
		return
	var center := _river_water.center
	var half_width := _river_water.half_extents.x
	var x := clampf(listener.x, center.x - half_width, center.x + half_width)
	var source := Vector3(x, center.y, ValleyMap.river_z(x))
	_river.global_position = source
	var distance := listener.distance_to(source)
	var target := 0.17 * (1.0 - smoothstep(5.0, 32.0, distance))
	_river_gain = move_toward(_river_gain, target, delta * 1.4)
	_river.volume_db = linear_to_db(maxf(0.0001, _river_gain * _volume))


## weapon plays what the player's own weapon did in a tick: the bits of
## Arsenal.EVENT_*.
func weapon(kind: int, events: int) -> void:
	if not _audible or not is_inside_tree():
		return
	if events & Arsenal.EVENT_FIRED and _shots.has(kind):
		var voices: Array[AudioStreamPlayer] = _shots[kind]
		var voice := voices[_next[kind]]
		_next[kind] = (_next[kind] + 1) % SHOT_VOICES
		voice.play()
	if events & Arsenal.EVENT_DRY_FIRE:
		_dry.play()
	if events & Arsenal.EVENT_RELOAD_STARTED:
		_magazine_out.play()
	if events & Arsenal.EVENT_RELOADED:
		_magazine_in.play()
	if events & Arsenal.EVENT_EQUIP_STARTED:
		_equip.play()


## shot_at plays another soldier's shot from where it was fired, quieter with
## the distance to the camera, to the side it came from.
func shot_at(kind: int, position: Vector3) -> void:
	if not _audible or not is_inside_tree() or not GUNSHOTS.has(kind):
		return
	var distance := 0.0
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		distance = camera.global_position.distance_to(position)
	var relative_distance := distance / FALLOFF_DISTANCE
	var gain := 1.0 / (1.0 + relative_distance * relative_distance)
	if gain < QUIETEST:
		return
	var covered := camera != null and distance > 0.1 and _shot_is_covered(camera, position)
	if covered:
		gain *= SHOT_COVER_GAIN
	_play_at(GUNSHOTS[kind], position, gain * SHOT_VOLUMES[kind], covered)


## Only spend ray queries on audible shots, with a per-frame budget for big
## volleys. Beyond that budget the existing distance and direction cue plays.
func _shot_is_covered(camera: Camera3D, position: Vector3) -> bool:
	var frame := Engine.get_process_frames()
	if frame != _shot_cover_frame:
		_shot_cover_frame = frame
		_shot_cover_rays = 0
	if _shot_cover_rays >= SHOT_COVER_RAYS_PER_FRAME:
		return false
	_shot_cover_rays += 1
	_shot_cover_query.from = camera.global_position
	_shot_cover_query.to = position
	return not camera.get_world_3d().direct_space_state.intersect_ray(_shot_cover_query).is_empty()


## Nearby bullet strikes add a dry localized cue. A short rate limit keeps
## a burst from masking the shot or confirmed hits.
func impact_at(position: Vector3) -> void:
	if not _audible or not is_inside_tree():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var distance := camera.global_position.distance_to(position)
	var now := Time.get_ticks_usec()
	if distance >= 16.0 or now - _last_impact_usec < 65000:
		return
	_last_impact_usec = now
	_play_at(STRIKE, position, 0.29 * (1.0 - distance / 16.0))


func _play_at(stream: AudioStreamWAV, position: Vector3, volume: float, covered: bool = false) -> void:
	var player := _positional[_next_positional]
	player.attenuation_filter_cutoff_hz = COVER_FILTER_HZ if covered else DIRECT_FILTER_HZ
	_next_positional = (_next_positional + 1) % POSITIONAL_VOICES
	_play_spatial(player, stream, position, volume, SHOT_PITCHES[_next_positional % SHOT_VOICES])


## Nearby movement carries much less far than a weapon report. When a group
## is already loud enough to use the whole pool, keep its current steps intact.
func footstep_at(feet: Vector3, scene: MapScene, distance: float) -> void:
	if not _audible or not is_inside_tree() or distance >= REMOTE_FOOTSTEP_RANGE:
		return
	var gain := 1.0 - distance / REMOTE_FOOTSTEP_RANGE
	for voice in _remote_boots:
		if voice.playing:
			continue
		var variants: Array = FOOTSTEPS[_surface_at(feet, scene)]
		var sample: AudioStreamWAV = variants[_remote_step_number % variants.size()]
		var pitch: float = SHOT_PITCHES[_remote_step_number % SHOT_VOICES]
		_remote_step_number += 1
		_play_spatial(voice, sample, feet + Vector3.UP * 0.15, 0.34 * gain * gain, pitch)
		return


func _play_spatial(player: AudioStreamPlayer3D, stream: AudioStreamWAV, position: Vector3, volume: float, pitch: float) -> void:
	player.stream = stream
	player.pitch_scale = pitch
	player.global_position = position
	player.volume_db = linear_to_db(volume * _volume)
	player.play()


func footstep(feet: Vector3, scene: MapScene, landed: bool) -> void:
	if not _audible or not is_inside_tree():
		return
	var surface := _surface_at(feet, scene)
	var variants: Array = FOOTSTEPS[surface]
	var boot := _boots[_step_number % _boots.size()]
	boot.stream = variants[_step_number % variants.size()]
	_step_number += 1
	boot.pitch_scale = 0.87 if landed else SHOT_PITCHES[_step_number % SHOT_VOICES]
	var gain := 0.36 if landed else 0.28
	boot.volume_db = linear_to_db(gain * _volume)
	boot.play()
	if landed:
		_landing.play()


## Match walkable box tops before the terrain. This matters for a wooden
## deck over water and for the ramps laid at an angle to the floor.
static func _surface_at(feet: Vector3, scene: MapScene) -> Surface:
	var surface := Surface.FIELD
	var closest := INF
	for box in scene.boxes:
		if box.kind == MapScene.Kind.INVISIBLE:
			continue
		var offset := feet - box.transform.origin
		var reach := box.half_extents + Vector3(0.07, 0.19, 0.07)
		if offset.length_squared() > reach.length_squared():
			continue
		var local := box.transform.basis.transposed() * offset
		if absf(local.x) > box.half_extents.x + 0.07 or absf(local.z) > box.half_extents.z + 0.07:
			continue
		var gap := absf(local.y - box.half_extents.y)
		if gap > 0.19 or gap >= closest:
			continue
		closest = gap
		match box.kind:
			MapScene.Kind.WOOD, MapScene.Kind.PLANKS, MapScene.Kind.TRUNK:
				surface = Surface.WOOD
			MapScene.Kind.GROUND, MapScene.Kind.SANDBAG, MapScene.Kind.HAY:
				surface = Surface.FIELD
			_:
				surface = Surface.HARD
	if surface != Surface.FIELD:
		return surface
	for water in scene.waters:
		var offset := feet - water.center
		if offset.y <= 0.08 and absf(offset.x) <= water.half_extents.x and absf(offset.z) <= water.half_extents.y:
			return Surface.MUD
	return surface


func take_damage() -> void:
	if _audible and is_inside_tree():
		_damage.play()


## A kill has its own confirmation so it is recognizable in a firefight.
func hit_marker(killed: bool) -> void:
	if not _audible or not is_inside_tree():
		return
	var cue := _kill_marker if killed else _marker
	cue.play()


## Plays when the player's team gains or loses control of a flag.
func flag_changed(captured: bool) -> void:
	if not _audible or not is_inside_tree():
		return
	var cue := _flag_captured if captured else _flag_lost
	cue.play()


func _spatial_player() -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	# The engine pans the source. Each cue controls its own distance falloff.
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	player.max_db = 0.0
	add_child(player)
	return player


func _player(stream: AudioStream, volume: float) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = linear_to_db(volume * _volume)
	add_child(player)
	return player


## _click renders a short tick of bright noise starting at a time.
static func _click(seconds: float, decay: float, smoothing: float, at: float, seed: int) -> PackedFloat32Array:
	var random := RandomNumberGenerator.new()
	random.seed = seed * 0xc11c + 1
	var count := int(seconds * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(count)
	var filtered := 0.0
	for i in count:
		var t := float(i) / SAMPLE_RATE
		filtered += smoothing * (random.randf() * 2 - 1 - filtered)
		samples[i] = 0.0 if t < at else filtered * exp(-(t - at) / decay)
	return samples


## _clicks renders the two clicks of a magazine or a slide, at the given times.
static func _clicks(seconds: float, first: float, second: float) -> PackedFloat32Array:
	var samples := _click(seconds, 0.006, 0.8, first, 3)
	var other := _click(seconds, 0.01, 0.6, second, 5)
	for i in samples.size():
		samples[i] += other[i]
	return samples


## Add a second note for confirmations that must be distinct from a hit.
static func _cue(pitch: float, followup: float = 0.0) -> AudioStreamWAV:
	const FOLLOWUP_TIME := 0.065
	var seconds := 0.11 if followup == 0.0 else 0.23
	var count := int(seconds * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(count)
	for i in count:
		var time := float(i) / SAMPLE_RATE
		samples[i] = _cue_note(pitch, time)
		if followup > 0.0 and time >= FOLLOWUP_TIME:
			samples[i] += _cue_note(followup, time - FOLLOWUP_TIME)
	return _to_stream(samples)


static func _cue_note(pitch: float, time: float) -> float:
	var phase := TAU * pitch * time
	var envelope := minf(time / 0.004, 1.0) * exp(-time / 0.022)
	return (sin(phase) + 0.2 * sin(phase * 2.0)) * envelope


## _to_stream makes 16-bit sound of samples, scaled so that its loudest sample
## is at 0.9 of the full range.
static func _to_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var peak := 1e-6
	for value in samples:
		peak = maxf(peak, absf(value))
	var data := PackedByteArray()
	data.resize(2 * samples.size())
	for i in samples.size():
		data.encode_s16(2 * i, int(samples[i] / peak * 0.9 * 32767))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

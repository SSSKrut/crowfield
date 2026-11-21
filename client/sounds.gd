class_name Sounds
extends Node
## Local weapon and feedback cues, and spatial shots from other soldiers.
## With a volume of zero the game is silent and creates no players.

const SAMPLE_RATE := 44100
## Rapid fire overlaps: every weapon sound plays on SHOT_VOICES voices in turn.
const SHOT_VOICES := 6
## Shots of other soldiers play on this many positional voices in turn.
const POSITIONAL_VOICES := 24
## A distant shot is half as loud at this distance, before the spatial mix.
const FALLOFF_DISTANCE := 20.0
const QUIETEST := 0.03

const SHOT_VOLUMES := [0.0, 0.70, 0.82, 0.62]
const SHOT_PITCHES := [1.0, 0.98, 1.02, 0.99, 1.01, 1.0]
const GUNSHOTS := {
	WeaponTuning.Kind.ASSAULT_RIFLE: preload("res://assets/audio/assault-shot.wav"),
	WeaponTuning.Kind.RIFLE: preload("res://assets/audio/rifle-shot.wav"),
	WeaponTuning.Kind.PISTOL: preload("res://assets/audio/pistol-shot.wav"),
}

var _volume := 0.0
var _audible := false
## _shots holds, by weapon kind, its voices; _next the voice to play next.
var _shots := {}
var _next := {}
var _positional: Array[AudioStreamPlayer3D] = []
var _next_positional := 0
var _dry: AudioStreamPlayer
var _magazine_out: AudioStreamPlayer
var _magazine_in: AudioStreamPlayer
var _equip: AudioStreamPlayer
## _marker ticks when a shot of the player hurt someone.
var _marker: AudioStreamPlayer
var _kill_marker: AudioStreamPlayer
var _flag_captured: AudioStreamPlayer
var _flag_lost: AudioStreamPlayer


## volume is the master volume from 0 to 1.
func _init(volume: float) -> void:
	name = "Sounds"
	_volume = clampf(volume, 0.0, 1.0)
	if _volume <= 0:
		return
	_audible = true
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
	for i in POSITIONAL_VOICES:
		var player := AudioStreamPlayer3D.new()
		# The fall with distance is the game's own, below; the engine only
		# places the sound to the side it came from.
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		player.max_db = 0.0
		add_child(player)
		_positional.append(player)


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
	var player := _positional[_next_positional]
	_next_positional = (_next_positional + 1) % POSITIONAL_VOICES
	player.stream = GUNSHOTS[kind]
	player.pitch_scale = SHOT_PITCHES[_next_positional % SHOT_VOICES]
	player.global_position = position
	player.volume_db = linear_to_db(gain * SHOT_VOLUMES[kind] * _volume)
	player.play()


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


func _player(stream: AudioStreamWAV, volume: float) -> AudioStreamPlayer:
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

class_name Sounds
extends Node
## Sounds are the sounds of the weapons: the player's own, and the shots of
## other soldiers from where they were fired. There are no sound files yet:
## they are made at start from noise and tones. With a volume of zero the game
## is silent and no players are made.

const SAMPLE_RATE := 44100
## Rapid fire overlaps: every weapon sound plays on SHOT_VOICES voices in turn.
const SHOT_VOICES := 6
## Shots of other soldiers play on this many positional voices in turn.
const POSITIONAL_VOICES := 24
## Another soldier's shot is as loud as 1 / (1 + distance / FALLOFF_DISTANCE)
## of the shot at its muzzle, and silent below QUIETEST.
const FALLOFF_DISTANCE := 12.0
const QUIETEST := 0.03

## SHOT_VOLUMES are the volumes of the weapons' shots, at the shooter.
const SHOT_VOLUMES := [0.0, 0.85, 1.0, 0.7]
## A gunshot is a burst of filtered noise over a falling thump: decay is the
## time constant of the noise in seconds, smoothing how much of each new noise
## sample passes the low-pass filter, thump the starting pitch of the low
## tone, in Hz.
const GUNSHOTS := {
	WeaponTuning.Kind.ASSAULT_RIFLE: {"decay": 0.07, "smoothing": 0.32, "thump": 115.0},
	WeaponTuning.Kind.RIFLE: {"decay": 0.13, "smoothing": 0.22, "thump": 85.0},
	WeaponTuning.Kind.PISTOL: {"decay": 0.045, "smoothing": 0.5, "thump": 160.0},
}

var _volume := 0.0
var _audible := false
## _shots holds, by weapon kind, its voices; _next the voice to play next.
var _shots := {}
var _next := {}
var _streams := {}
var _positional: Array[AudioStreamPlayer3D] = []
var _next_positional := 0
var _dry: AudioStreamPlayer
var _magazine_out: AudioStreamPlayer
var _magazine_in: AudioStreamPlayer
var _equip: AudioStreamPlayer
## _marker ticks when a shot of the player hurt someone.
var _marker: AudioStreamPlayer


## volume is the master volume from 0 to 1.
func _init(volume: float) -> void:
	name = "Sounds"
	_volume = clampf(volume, 0.0, 1.0)
	if _volume <= 0:
		return
	_audible = true
	for kind in GUNSHOTS:
		var voice: Dictionary = GUNSHOTS[kind]
		var stream := _to_stream(_gunshot(0.5, voice["decay"], voice["smoothing"], voice["thump"], kind))
		_streams[kind] = stream
		var voices: Array[AudioStreamPlayer] = []
		for i in SHOT_VOICES:
			voices.append(_player(stream, SHOT_VOLUMES[kind]))
		_shots[kind] = voices
		_next[kind] = 0
	_dry = _player(_to_stream(_click(0.05, 0.004, 0.9, 0.0, 7)), 0.4)
	_magazine_out = _player(_to_stream(_clicks(0.25, 0.0, 0.09)), 0.35)
	_magazine_in = _player(_to_stream(_clicks(0.25, 0.0, 0.12)), 0.5)
	_equip = _player(_to_stream(_clicks(0.2, 0.0, 0.06)), 0.3)
	_marker = _player(_to_stream(_tone(0.08, 2400.0, 0.015)), 0.35)
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
		voice.volume_db = linear_to_db(SHOT_VOLUMES[kind] * _volume)
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
	if not _audible or not is_inside_tree() or not _streams.has(kind):
		return
	var distance := 0.0
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		distance = camera.global_position.distance_to(position)
	var gain := 1.0 / (1.0 + distance / FALLOFF_DISTANCE)
	if gain < QUIETEST:
		return
	var player := _positional[_next_positional]
	_next_positional = (_next_positional + 1) % POSITIONAL_VOICES
	player.stream = _streams[kind]
	player.global_position = position
	player.volume_db = linear_to_db(gain * SHOT_VOLUMES[kind] * _volume)
	player.play()


## hit_marker ticks for a shot that hurt someone, lower for a kill.
func hit_marker(killed: bool) -> void:
	if not _audible or not is_inside_tree():
		return
	_marker.pitch_scale = 0.75 if killed else 1.0
	_marker.play()


func _player(stream: AudioStreamWAV, volume: float) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = linear_to_db(volume * _volume)
	add_child(player)
	return player


## _gunshot renders a gunshot of the given voice; seed varies the noise from
## weapon to weapon.
static func _gunshot(seconds: float, decay: float, smoothing: float, thump: float, seed: int) -> PackedFloat32Array:
	var random := RandomNumberGenerator.new()
	random.seed = seed * 0x5a11 + 1
	var count := int(seconds * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(count)
	var filtered := 0.0
	var phase := 0.0
	for i in count:
		var t := float(i) / SAMPLE_RATE
		filtered += smoothing * (random.randf() * 2 - 1 - filtered)
		var noise := filtered * exp(-t / decay)
		var pitch := thump * (0.5 + 0.5 * exp(-t / 0.04))
		phase += TAU * pitch / SAMPLE_RATE
		var tone := sin(phase) * exp(-t / 0.035)
		var attack := minf(1.0, t / 0.0015)
		samples[i] = attack * (1.6 * noise + 0.8 * tone)
	return samples


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


## _tone renders a short beep of the given pitch that fades with decay.
static func _tone(seconds: float, pitch: float, decay: float) -> PackedFloat32Array:
	var count := int(seconds * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(count)
	for i in count:
		var t := float(i) / SAMPLE_RATE
		samples[i] = sin(TAU * pitch * t) * exp(-t / decay)
	return samples


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

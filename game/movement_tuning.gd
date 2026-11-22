class_name MovementTuning
extends RefCounted
## MovementTuning holds the parameters that decide where a human soldier ends
## up after a command, so the client and the server must use the same values.

const FIELDS := [
	"walk_speed", "sprint_speed", "jump_speed", "gravity", "ground_stick_speed",
	"capsule_half_height", "capsule_radius", "max_slope_degrees", "eye_height", "step_height",
]

const CROUCH_SPEED_SHARE := 0.52
const CROUCH_HEIGHT_SHARE := 0.49
const CROUCH_EYE_SHARE := 0.51

var walk_speed := 5.0
var sprint_speed := 8.0
# Use a short jump that clears low cover and lands quickly.
var jump_speed := 4.8
var gravity := 17.5
var ground_stick_speed := 0.5
var capsule_half_height := 0.55
var capsule_radius := 0.35
var max_slope_degrees := 50.0
var eye_height := 1.55
## step_height is the tallest step a soldier walks up without jumping, like a
## stair; it also keeps a soldier on the ground going down one.
var step_height := 0.4


func copy() -> MovementTuning:
	var tuning := MovementTuning.new()
	for field in FIELDS:
		tuning.set(field, get(field))
	return tuning


## validate returns why the tuning is unusable, or "".
func validate() -> String:
	if walk_speed <= 0 or sprint_speed <= 0:
		return "walk and sprint speeds must be positive"
	if jump_speed < 0 or ground_stick_speed < 0:
		return "jump and ground stick speeds must not be negative"
	if gravity <= 0:
		return "gravity must be positive"
	if capsule_half_height <= 0 or capsule_radius <= 0:
		return "capsule dimensions must be positive"
	if max_slope_degrees <= 0 or max_slope_degrees >= 90:
		return "max slope must be between 0 and 90 degrees"
	if eye_height <= 0 or eye_height > 2 * center_height():
		return "eye height must be inside the capsule"
	if step_height < 0 or step_height >= 2 * center_height():
		return "step height must be lower than the capsule"
	return ""


## center_height is the distance from the feet to the capsule center.
func center_height(crouched := false) -> float:
	var height := capsule_half_height + capsule_radius
	return maxf(capsule_radius, height * CROUCH_HEIGHT_SHARE) if crouched else height


## view_height is shared by the camera, the authoritative muzzle ray and bots.
func view_height(crouched := false) -> float:
	if not crouched:
		return eye_height
	return minf(eye_height * CROUCH_EYE_SHARE, 2.0 * center_height(true) - capsule_radius * 0.20)


## hash identifies the tuning. The server sends it in Welcome, and a client
## with a different tuning refuses to play, because its prediction would not
## match.
func hash_value() -> int:
	var bytes := PackedByteArray()
	bytes.resize(4 * FIELDS.size())
	for i in FIELDS.size():
		bytes.encode_float(4 * i, get(FIELDS[i]))
	return Game.fnv64(bytes)


## load_json reads a JSON file on top of the values the tuning has, so the
## file only needs the values it changes. It returns an error or "".
func load_json(path: String) -> String:
	var error := Rules.apply_json_file(self, FIELDS, path)
	if error != "":
		return "movement tuning %s: %s" % [path, error]
	error = validate()
	if error != "":
		return "movement tuning %s: %s" % [path, error]
	return ""

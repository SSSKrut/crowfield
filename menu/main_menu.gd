class_name MainMenu
extends Control
## MainMenu is the first screen: it starts solo play, a game hosted for
## friends or a game on someone else's server. It keeps what the player typed
## in user://settings.cfg for the next run.

## play asks to start the client with these flags.
signal play(arguments: PackedStringArray)

const SETTINGS := "user://settings.cfg"
const BASE_SENSITIVITY := 0.0025
const GRAPHICS_MODES := ["auto", "performance", "quality"]

var _volume := 50.0
var _sensitivity := 1.0
var _fov := 75.0
var _graphics := "auto"

## message is an error to show, of the game the player has just left.
var message := ""

@onready var _name: LineEdit = %Name
@onready var _bots: SpinBox = %Bots
@onready var _map: OptionButton = %Map
@onready var _port: SpinBox = %Port
@onready var _address: LineEdit = %Address
@onready var _status: Label = %Status


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	resized.connect(_position_panel)
	_position_panel()
	_port.value = ENetTransport.DEFAULT_PORT
	for map_name in MapScene.MAPS:
		_map.add_item(map_name.capitalize())
	_load()
	_on_map_selected(_map.selected)
	_show_status(message)
	%Solo.grab_focus()


func _position_panel() -> void:
	# Keep the entire menu reachable in a short window and leave the view open on the right.
	var layout := %Center as CenterContainer
	layout.anchor_right = clampf(550.0 / maxf(size.x, 1.0), 0.46, 1.0)
	layout.pivot_offset = Vector2(size.x * layout.anchor_right, size.y) * 0.5
	var factor := minf(size.x / 440.0, size.y / 550.0)
	layout.scale = Vector2.ONE * clampf(factor, 0.25, 1.0)


func _on_map_selected(index: int) -> void:
	var valley: bool = MapScene.MAPS[index] == "valley"
	%Mode.text = "VALLEY  /  FLAG CONTROL" if valley else "PRACTICE RANGE"
	%Subtitle.text = "Hold crossings to score and open forward reinforcements." if valley else "Practice movement and combat."
	%Solo.text = "Play Valley solo" if valley else "Play practice map solo"


func _on_multiplayer_pressed() -> void:
	%NetworkStatus.hide()
	%NetworkDialog.popup_centered()
	_address.grab_focus()


func _on_solo_pressed() -> void:
	_start(_own_server())


func _on_host_pressed() -> void:
	_start(_own_server() + ["-host=:%d" % _port.value])


## _own_server are the flags of the server the player starts: its map and bots.
func _own_server() -> Array:
	return ["-map=" + MapScene.MAPS[_map.selected], "-bots=%d" % _bots.value]


func _on_join_pressed() -> void:
	var address := _address.text.strip_edges()
	if address == "":
		_show_network_status("Enter the server address, such as 192.168.1.20 or 192.168.1.20:7777.")
		_address.grab_focus()
		return
	if ENetTransport.split_address(address).is_empty():
		_show_network_status("Enter a valid host or host:port.")
		_address.grab_focus()
		return
	_start(["-connect=" + address])


func _show_network_status(text: String) -> void:
	%NetworkStatus.text = text
	%NetworkStatus.show()


func _on_address_submitted(_text: String) -> void:
	_on_join_pressed()


func _on_settings_pressed() -> void:
	%Volume.value = _volume
	%Sensitivity.value = _sensitivity
	%Fov.value = _fov
	%Graphics.select(GRAPHICS_MODES.find(_graphics))
	_display_settings()
	%Settings.popup_centered()
	%Volume.grab_focus()


func _display_settings(_value: float = 0.0) -> void:
	%VolumeValue.text = "%d%%" % %Volume.value
	%SensitivityValue.text = "%.2f×" % %Sensitivity.value
	%FovValue.text = "%d°" % %Fov.value


func _on_settings_confirmed() -> void:
	_volume = %Volume.value
	_sensitivity = %Sensitivity.value
	_fov = %Fov.value
	_graphics = GRAPHICS_MODES[%Graphics.selected]
	_save()


func _on_credits_pressed() -> void:
	%Credits.popup_centered()


func _on_credit_link_clicked(url: Variant) -> void:
	OS.shell_open(str(url))


func _on_quit_pressed() -> void:
	get_tree().quit()


func _start(arguments: Array) -> void:
	var player_name := _name.text.strip_edges()
	if player_name == "":
		player_name = "Player"
	if player_name.to_utf8_buffer().size() > Protocol.MAX_NAME_BYTES:
		_show_status("The name is too long: at most %d bytes." % Protocol.MAX_NAME_BYTES)
		%NetworkDialog.hide()
		_name.grab_focus()
		return
	%NetworkDialog.hide()
	_save()
	var preferences := [
		"-name=" + player_name,
		"-volume=%.2f" % (_volume / 100.0),
		"-sensitivity=%.6f" % (_sensitivity * BASE_SENSITIVITY),
		"-fov=%.0f" % _fov,
	]
	if _graphics != "auto":
		preferences.append("-graphics=" + _graphics)
	play.emit(PackedStringArray(preferences + arguments))


func _show_status(text: String) -> void:
	_status.text = text
	_status.visible = text != ""


func _load() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS) != OK:
		return
	_name.text = config.get_value("player", "name", _name.text)
	_bots.value = config.get_value("game", "bots", _bots.value)
	var map_index := MapScene.MAPS.find(config.get_value("game", "map", ""))
	if map_index >= 0:
		_map.selected = map_index
	_port.value = config.get_value("host", "port", _port.value)
	_address.text = config.get_value("join", "address", _address.text)
	_volume = clampf(config.get_value("settings", "volume", _volume), 0.0, 100.0)
	_sensitivity = clampf(config.get_value("settings", "sensitivity", _sensitivity), 0.25, 3.0)
	_fov = clampf(config.get_value("settings", "fov", _fov), 55.0, 100.0)
	var graphics: String = config.get_value("settings", "graphics", _graphics)
	if graphics in GRAPHICS_MODES:
		_graphics = graphics


func _save() -> void:
	var config := ConfigFile.new()
	config.set_value("player", "name", _name.text.strip_edges())
	config.set_value("game", "bots", int(_bots.value))
	config.set_value("game", "map", MapScene.MAPS[_map.selected])
	config.set_value("host", "port", int(_port.value))
	config.set_value("join", "address", _address.text.strip_edges())
	config.set_value("settings", "volume", _volume)
	config.set_value("settings", "sensitivity", _sensitivity)
	config.set_value("settings", "fov", _fov)
	config.set_value("settings", "graphics", _graphics)
	config.save(SETTINGS)

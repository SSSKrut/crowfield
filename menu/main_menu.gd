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
var _hosting := false

## message is an error to show, of the game the player has just left.
var message := ""

@onready var _map: OptionButton = %Map
@onready var _name: LineEdit = %Name
@onready var _join_name: LineEdit = %JoinName
@onready var _bots: SpinBox = %Bots
@onready var _port: SpinBox = %Port
@onready var _address: LineEdit = %Address
@onready var _status: Label = %Status


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	resized.connect(_position_panel)
	_position_panel()
	_port.value = ENetTransport.DEFAULT_PORT
	for map_name in MapScene.MAPS:
		_map.add_item("Practice Range" if map_name == "prototype" else map_name.capitalize())
	_map.select(0)
	_load()
	_show_status(message)
	%Solo.grab_focus()


func _position_panel() -> void:
	const PAGE_WIDTH := 462.0
	var layout := %Pages as VBoxContainer
	layout.offset_left = size.x * 0.09
	layout.offset_right = layout.offset_left + PAGE_WIDTH
	layout.pivot_offset = Vector2(0.0, size.y * 0.5)
	var factor := minf((size.x - layout.offset_left - 16.0) / PAGE_WIDTH, size.y / 475.0)
	layout.scale = Vector2.ONE * clampf(factor, 0.25, 1.0)


func _show_page(page: Control, focus: Control) -> void:
	for child: Control in %Pages.get_children():
		child.visible = child == page
	focus.grab_focus()


func _show_setup(hosting: bool) -> void:
	_hosting = hosting
	%SetupPageTitle.text = "Host Game" if hosting else "Singleplayer Setup"
	%Start.text = "Host Match" if hosting else "Start Match"
	%PortLabel.visible = hosting
	_port.visible = hosting
	%SetupStatus.hide()
	_show_page(%SetupPage, _map)


func _go_back() -> void:
	if %JoinPage.visible:
		_name.text = _join_name.text
		_show_page(%MultiplayerPage, %Join)
	elif %SetupPage.visible:
		if _hosting:
			_show_page(%MultiplayerPage, %Host)
		else:
			_show_page(%Home, %Solo)
	elif %MultiplayerPage.visible:
		_show_page(%Home, %Multiplayer)


func _input(event: InputEvent) -> void:
	if not %Home.visible and not _map.get_popup().visible and event.is_action_pressed("menu"):
		get_viewport().set_input_as_handled()
		_go_back()


func _on_solo_pressed() -> void:
	_show_setup(false)


func _on_multiplayer_pressed() -> void:
	_show_page(%MultiplayerPage, %Host)


func _on_host_pressed() -> void:
	_show_setup(true)


func _on_join_pressed() -> void:
	_join_name.text = _name.text
	%JoinStatus.hide()
	_show_page(%JoinPage, _address)


func _on_start_pressed() -> void:
	_bots.apply()
	var arguments := ["-map=" + MapScene.MAPS[_map.selected], "-bots=%d" % _bots.value]
	if _hosting:
		_port.apply()
		arguments.append("-host=:%d" % _port.value)
	_start(arguments, _name, %SetupStatus)


func _on_join_match_pressed() -> void:
	var address := _address.text.strip_edges()
	if address == "":
		_field_error(%JoinStatus, "Enter the server address, such as 192.168.1.20 or 192.168.1.20:7777.", _address)
		return
	if ENetTransport.split_address(address).is_empty():
		_field_error(%JoinStatus, "Enter a valid host or host:port.", _address)
		return
	_start(["-connect=" + address], _join_name, %JoinStatus)


func _field_error(status: Label, text: String, field: Control) -> void:
	status.text = text
	status.show()
	field.grab_focus()


func _on_address_submitted(_text: String) -> void:
	_on_join_match_pressed()


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


func _on_settings_visibility_changed() -> void:
	if not %Settings.visible:
		%SettingsButton.grab_focus.call_deferred()


func _on_settings_confirmed() -> void:
	_volume = %Volume.value
	_sensitivity = %Sensitivity.value
	_fov = %Fov.value
	_graphics = GRAPHICS_MODES[%Graphics.selected]
	_save()


func _on_credits_pressed() -> void:
	%Credits.popup_centered()


func _on_credits_visibility_changed() -> void:
	if not %Credits.visible:
		%CreditsButton.grab_focus.call_deferred()


func _on_credit_link_clicked(url: Variant) -> void:
	OS.shell_open(str(url))


func _on_quit_pressed() -> void:
	get_tree().quit()


func _start(arguments: Array, name_field: LineEdit, status: Label) -> void:
	var player_name := name_field.text.strip_edges()
	if player_name == "":
		player_name = "Player"
	if player_name.to_utf8_buffer().size() > Protocol.MAX_NAME_BYTES:
		_field_error(status, "The name is too long: at most %d bytes." % Protocol.MAX_NAME_BYTES, name_field)
		return
	_name.text = name_field.text
	status.hide()
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
		_map.select(map_index)
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

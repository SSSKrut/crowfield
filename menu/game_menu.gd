class_name GameMenu
extends Control
## Keep the menu responsive over paused solo matches and live online matches.

signal resumed
signal left
signal replayed

## about tells what game this is: solo, hosted, with the addresses friends
## join, or on someone else's server.
var about := "":
	set(value):
		about = value
		if is_node_ready():
			%About.text = value


func _ready() -> void:
	%About.text = about
	resized.connect(_position_actions)
	_position_actions()


func _position_actions() -> void:
	var center := %Center as CenterContainer
	center.anchor_right = clampf(480.0 / maxf(size.x, 1.0), 0.43, 1.0)
	center.pivot_offset = Vector2(size.x * center.anchor_right, size.y) * 0.5
	center.scale = Vector2.ONE * clampf(minf(size.x / 400.0, size.y / 450.0), 0.25, 1.0)


func open(can_replay: bool, paused: bool) -> void:
	%Title.text = "Paused" if paused else "Match menu"
	%ControlsButton.set_pressed_no_signal(false)
	%Controls.hide()
	visible = true
	%Replay.visible = can_replay
	if can_replay:
		%Replay.grab_focus()
	else:
		%Resume.grab_focus()


func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("menu"):
		get_viewport().set_input_as_handled()
		resumed.emit()


func _on_controls_toggled(expanded: bool) -> void:
	%Controls.visible = expanded


func _on_replay_pressed() -> void:
	replayed.emit()


func _on_resume_pressed() -> void:
	resumed.emit()


func _on_leave_pressed() -> void:
	left.emit()


func _on_quit_pressed() -> void:
	get_tree().quit()

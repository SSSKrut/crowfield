class_name GameMenu
extends Control
## GameMenu opens over the game with Esc. The game goes on behind it: the
## server waits for no one.

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


func open(can_replay: bool = false) -> void:
	visible = true
	%Replay.visible = can_replay
	if can_replay:
		%Replay.grab_focus()
	else:
		%Resume.grab_focus()


func _on_replay_pressed() -> void:
	replayed.emit()


func _on_resume_pressed() -> void:
	resumed.emit()


func _on_leave_pressed() -> void:
	left.emit()


func _on_quit_pressed() -> void:
	get_tree().quit()

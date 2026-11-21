class_name Main
extends Node
## Main starts what the command line asks for. Without arguments it shows the
## main menu, or runs a dedicated server when there is no window: under
## --headless and in an export with the dedicated_server feature. Everything
## after -- belongs to the game:
##
##   godot --path .                              the main menu
##   godot --path . -- [client flags]            play straight away, solo or on a server
##   godot --headless --path . -- [server flags] run a dedicated server
##   godot --headless --path . -- loadtest [...] load a server with headless clients
##   godot --headless --path . -- test [filter]  run the automatic tests
##
## A mode word (client, server, loadtest, test) may come first; -help after it
## lists the flags.

const MENU := preload("res://menu/main_menu.tscn")
const MENU_FPS := 30


func _ready() -> void:
	var arguments := OS.get_cmdline_user_args()
	var mode := "client"
	if arguments.size() > 0 and not arguments[0].begins_with("-"):
		mode = arguments[0]
		arguments = arguments.slice(1)
	elif OS.has_feature("dedicated_server") or DisplayServer.get_name() == "headless":
		mode = "server"
	elif arguments.is_empty():
		mode = "menu"
	match mode:
		"menu":
			_show_menu("")
		"test":
			var filter := arguments[0] if arguments.size() > 0 else ""
			var failed := await TestRunner.run(filter)
			get_tree().quit(1 if failed > 0 else 0)
		"server":
			add_child(DedicatedServer.create(arguments))
		"loadtest":
			add_child(LoadTest.create(arguments))
		"loadclient":
			add_child(LoadClient.create(arguments))
		"client":
			_play(arguments, false)
		_:
			printerr("unknown mode %s: want client, server, loadtest or test" % mode)
			get_tree().quit(2)


func _show_menu(message: String) -> void:
	OS.low_processor_usage_mode = true
	Engine.max_fps = MENU_FPS
	var menu: MainMenu = MENU.instantiate()
	menu.message = message
	menu.play.connect(func(arguments: PackedStringArray) -> void:
		menu.queue_free()
		_play(arguments, true))
	add_child(menu)


## _play starts the client. One started from the menu goes back to it when
## the game ends; one started by flags ends the program when the game fails,
## for scripts that check how it ended.
func _play(arguments: PackedStringArray, from_menu: bool) -> void:
	OS.low_processor_usage_mode = false
	var app := ClientApp.create(arguments)
	app.allow_solo_replay = from_menu
	app.replay_requested.connect(func() -> void:
		app.tree_exited.connect(func() -> void: _play.call_deferred(arguments, true), CONNECT_ONE_SHOT)
		app.queue_free())
	app.left.connect(func(message: String) -> void:
		app.queue_free()
		if message != "" and not from_menu:
			printerr(message)
			get_tree().quit(1)
			return
		if app.settings.get("exit-on-leave", false):
			get_tree().quit()
			return
		_show_menu(message), CONNECT_DEFERRED)
	add_child(app)


## fail reports an error of startup and ends the program.
static func fail(node: Node, message: String) -> void:
	printerr(message)
	node.get_tree().quit(1)

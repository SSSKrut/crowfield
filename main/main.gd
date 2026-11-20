class_name Main
extends Node
## Main starts what the command line asks for. Everything after -- belongs to
## the game:
##
##   godot --path . -- [client flags]           play, solo or on a server
##   godot --headless --path . -- server [...]  run a dedicated server
##   godot --headless --path . -- loadtest [...] load a server with headless clients
##   godot --headless --path . -- test [filter] run the automatic tests
##
## -help after the mode lists its flags.


func _ready() -> void:
	var arguments := OS.get_cmdline_user_args()
	var mode := "client"
	if arguments.size() > 0 and not arguments[0].begins_with("-"):
		mode = arguments[0]
		arguments = arguments.slice(1)
	match mode:
		"test":
			var filter := arguments[0] if arguments.size() > 0 else ""
			var failed := TestRunner.run(filter)
			get_tree().quit(1 if failed > 0 else 0)
		"server":
			add_child(DedicatedServer.create(arguments))
		"loadtest":
			add_child(LoadTest.create(arguments))
		"loadclient":
			add_child(LoadClient.create(arguments))
		"client":
			add_child(ClientApp.create(arguments))
		_:
			printerr("unknown mode %s: want client, server, loadtest or test" % mode)
			get_tree().quit(2)


## fail reports an error of startup and ends the program.
static func fail(node: Node, message: String) -> void:
	printerr(message)
	node.get_tree().quit(1)

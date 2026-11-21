extends Node
## Runs the automatic tests from the editor: open tests.tscn and press F6
## (Run Current Scene). The output panel shows the results.


func _ready() -> void:
	var failed := await TestRunner.run()
	get_tree().quit(1 if failed > 0 else 0)

extends TestCase


## Every script compiles, including those that no game mode or other test
## loads, such as the tools run with --script.
func test_every_script_compiles() -> void:
	var scripts := _scripts("res://")
	check(get_script().resource_path in scripts, "the search reaches the tests")
	for path in scripts:
		var script: GDScript = load(path)
		check(script != null and script.can_instantiate(), "%s compiles" % path)


## _scripts lists the scripts under directory, leaving out the folders Godot
## ignores.
func _scripts(directory: String) -> PackedStringArray:
	var found := PackedStringArray()
	if FileAccess.file_exists(directory.path_join(".gdignore")):
		return found
	for file in DirAccess.get_files_at(directory):
		if file.get_extension() == "gd":
			found.append(directory.path_join(file))
	for child in DirAccess.get_directories_at(directory):
		if not child.begins_with("."):
			found.append_array(_scripts(directory.path_join(child)))
	return found

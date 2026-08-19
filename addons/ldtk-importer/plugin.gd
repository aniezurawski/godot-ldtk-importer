@tool
extends EditorPlugin

const EXTERNAL_LEVEL_POLL_INTERVAL := 1.0

var ldtk_plugin
var config = ConfigFile.new()

var _world_paths_by_level_path := {}
var _level_paths_by_world_path := {}
var _level_modified_times := {}
var _pending_world_paths := {}
var _poll_time := 0.0

func _enter_tree() -> void:
	ldtk_plugin = preload("ldtk-importer.gd").new()
	ldtk_plugin.world_parsed.connect(_on_world_parsed)
	add_import_plugin(ldtk_plugin)
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_on_filesystem_changed)
	_discover_ldtk_worlds()

	var config = ConfigFile.new()
	var err = config.load("res://addons/ldtk-importer/plugin.cfg")
	var version = config.get_value("plugin", "version", "0.0")

	print_rich("[color=#ffcc00]█ Godot-LDtk-Importer █[/color] %s | [url=https://gleeson.dev]@gleeson.dev[/url] | [url=https://github.com/heygleeson/godot-ldtk-importer]View on Github[/url]" % [version])

func _exit_tree() -> void:
	EditorInterface.get_resource_filesystem().filesystem_changed.disconnect(_on_filesystem_changed)
	ldtk_plugin.world_parsed.disconnect(_on_world_parsed)
	remove_import_plugin(ldtk_plugin)
	ldtk_plugin = null

func _process(delta: float) -> void:
	_poll_time += delta
	if _poll_time >= EXTERNAL_LEVEL_POLL_INTERVAL:
		_poll_time = 0.0
		_detect_external_level_changes()

	if _pending_world_paths.is_empty():
		return

	var file_system := EditorInterface.get_resource_filesystem()
	if file_system.is_scanning() or file_system.is_importing():
		return

	var world_paths := PackedStringArray(_pending_world_paths.keys())
	_pending_world_paths.clear()
	file_system.reimport_files(world_paths)

func _on_filesystem_changed() -> void:
	var worlds_removed := false
	for world_path: String in _level_paths_by_world_path.keys():
		if FileAccess.file_exists(world_path):
			continue
		_level_paths_by_world_path.erase(world_path)
		worlds_removed = true

	if worlds_removed:
		_rebuild_external_level_dependencies()

func _on_world_parsed(world_path: String, world_data: Dictionary) -> void:
	_level_paths_by_world_path[world_path] = _get_world_external_level_paths(world_path, world_data)
	_rebuild_external_level_dependencies()

func _detect_external_level_changes() -> void:
	for level_path: String in _world_paths_by_level_path:
		var modified_time := FileAccess.get_modified_time(level_path)
		if _level_modified_times[level_path] == modified_time:
			continue

		_level_modified_times[level_path] = modified_time
		_queue_worlds(_world_paths_by_level_path[level_path])

func _discover_ldtk_worlds() -> void:
	var world_paths: Array[String] = []
	_find_ldtk_worlds("res://", world_paths)

	for world_path in world_paths:
		var world_data_variant: Variant = JSON.parse_string(FileAccess.get_file_as_string(world_path))
		if not (world_data_variant is Dictionary):
			continue

		_level_paths_by_world_path[world_path] = _get_world_external_level_paths(
			world_path,
			world_data_variant,
		)

	_rebuild_external_level_dependencies()

func _find_ldtk_worlds(directory_path: String, world_paths: Array[String]) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		return

	for file_name in directory.get_files():
		if file_name.get_extension().to_lower() == "ldtk":
			world_paths.append(directory_path.path_join(file_name))

	for child_name in directory.get_directories():
		if child_name.begins_with("."):
			continue
		_find_ldtk_worlds(directory_path.path_join(child_name), world_paths)

func _rebuild_external_level_dependencies() -> void:
	var previous_level_modified_times := _level_modified_times
	_world_paths_by_level_path = {}
	for world_path: String in _level_paths_by_world_path:
		for level_path: String in _level_paths_by_world_path[world_path]:
			if not _world_paths_by_level_path.has(level_path):
				_world_paths_by_level_path[level_path] = []
			_world_paths_by_level_path[level_path].append(world_path)

	_level_modified_times = {}
	for level_path: String in _world_paths_by_level_path:
		if previous_level_modified_times.has(level_path):
			_level_modified_times[level_path] = previous_level_modified_times[level_path]
		else:
			_level_modified_times[level_path] = FileAccess.get_modified_time(level_path)

func _get_world_external_level_paths(
	world_path: String,
	world_data: Dictionary,
) -> Array[String]:
	var level_paths: Array[String] = []
	if not world_data.get("externalLevels", false):
		return level_paths

	var level_headers: Array = world_data.get("levels", [])
	if world_data.get("worldLayout") == null:
		level_headers = []
		for world_variant: Variant in world_data.get("worlds", []):
			if world_variant is Dictionary:
				var world: Dictionary = world_variant
				level_headers.append_array(world.get("levels", []))

	for level_header_variant: Variant in level_headers:
		if not (level_header_variant is Dictionary):
			continue

		var level_header: Dictionary = level_header_variant
		var relative_path: String = level_header.get("externalRelPath", "")
		if relative_path.is_empty():
			continue

		var level_path := world_path.get_base_dir().path_join(relative_path).simplify_path()
		level_paths.append(level_path)

	return level_paths

func _queue_worlds(world_paths: Array) -> void:
	for world_path: String in world_paths:
		_pending_world_paths[world_path] = true

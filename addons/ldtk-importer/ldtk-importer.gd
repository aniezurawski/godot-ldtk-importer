@tool
extends EditorImportPlugin

const LDTK_LATEST_VERSION = "1.5.3"

enum Presets {DEFAULT}
enum LevelSaveExtensions {
	SCN,
	TSCN
}

const Util = preload("src/util/util.gd")
const World = preload("src/world.gd")
const Level = preload("src/level.gd")
const Tileset = preload("src/tileset.gd")
const DefinitionUtil = preload("src/util/definition_util.gd")

const LEVEL_HASH_CACHE_VERSION := 1

#region EditorImportPlugin Overrides

#region Simple
func _get_importer_name():
	return "ldtk.import"

func _get_visible_name():
	return "LDTK Scene"

func _get_priority():
	return 1.0

func _get_import_order():
	return IMPORT_ORDER_SCENE

func _get_resource_type():
	return "PackedScene"

func _get_recognized_extensions():
	return ["ldtk"]

func _get_save_extension():
	return LevelSaveExtensions.keys()[Util.options.level_save_extension].to_lower()

func _get_preset_count():
	return Presets.size()

func _get_preset_name(index):
	match index:
		Presets.DEFAULT:
			return "Default"
		_:
			return "Unknown"

func _get_option_visibility(path, option_name, options):
	match option_name:
		"skip_unchanged_levels":
			return options.get("pack_levels", true)
		_:
			return true
	return true

func _can_import_threaded() -> bool:
	return false

#endregion

func _get_import_options(path, index):
	return [
		# --- World --- #
		{"name": "World", "default_value":"", "usage": PROPERTY_USAGE_GROUP},
		{
			# Group LDTKLevels in 'LDTKWorldLayer' nodes if using LDTK's WorldDepth.
			"name": "group_world_layers",
			"default_value": false,
		},
		# --- Levels --- #
		{"name": "Level", "default_value":"", "usage": PROPERTY_USAGE_GROUP},
		{
			# Save LDTKLevels as PackedScenes.
			"name": "pack_levels",
			"default_value": true,
		},
		{
			# Reuse PackedScenes when their imported level data has not changed.
			"name": "skip_unchanged_levels",
			"default_value": true,
		},
		{
			# Define LDTKLevels save extension.
			"name": "level_save_extension",
			"default_value": 0,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": "scn,tscn",
		},
		# --- Layers --- #
		{"name": "Layer", "default_value":"", "usage": PROPERTY_USAGE_GROUP},
		{
			# Save LDTKLevels as PackedScenes.
			"name": "layers_always_visible",
			"default_value": false,
		},
		# --- Tileset --- #
		{"name": "Tileset", "default_value":"", "usage": PROPERTY_USAGE_GROUP},
		{
			# Add LDTK Custom Data to Tilesets
			"name": "tileset_custom_data",
			"default_value": false,
		},
		{
			# Create TileAtlasSources & TileMapLayers for IntGrid Layers
			"name": "integer_grid_tilesets",
			"default_value": false,
		},
		{
			# Define default texture type for TilesetAtlasSource (e.g. to apply normal maps to tilesets after import)
			"name": "atlas_texture_type",
			"default_value": 0,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": "CompressedTexture2D,CanvasTexture",
		},
		{
			# Define Godot tileset save extension.
			"name": "tileset_save_extension",
			"default_value": 0,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": "res,tres",
		},
		# --- Entities --- #
		{"name": "Entity", "default_value":"", "usage": PROPERTY_USAGE_GROUP},
		{
			#
			"name": "resolve_entityrefs",
			"default_value": true,
		},
		{
			# Create LDTKEntityPlaceholder nodes to help debug importing.
			"name": "use_entity_placeholders",
			"default_value": false,
		},
		# --- Post Import --- #
		{"name": "Post Import", "default_value":"", "usage": PROPERTY_USAGE_GROUP},
		{
			# Define a post-import script to apply on imported Tilesets.
			"name": "tileset_post_import",
			"default_value": "",
			"property_hint": PROPERTY_HINT_FILE,
			"hint_string": "*.gd;GDScript"
		},
		{
			# Define a post-import script to apply on imported Entities.
			"name": "entities_post_import",
			"default_value": "",
			"property_hint": PROPERTY_HINT_FILE,
			"hint_string": "*.gd;GDScript"
		},
		{
			# Define a post-import script to apply on imported Levels.
			"name": "level_post_import",
			"default_value": "",
			"property_hint": PROPERTY_HINT_FILE,
			"hint_string": "*.gd;GDScript"
		},
		{
			# Define a post-import script to apply on imported Worlds.
			"name": "world_post_import",
			"default_value": "",
			"property_hint": PROPERTY_HINT_FILE,
			"hint_string": "*.gd;GDScript"
		},
		# --- Debug --- #
		{"name": "Debug", "default_value":"", "usage": PROPERTY_USAGE_GROUP},
		{
			# Force Tilesets to be recreated, resetting modifications (if experiencing import issues)
			"name": "force_tileset_reimport",
			"default_value": false,
		},
		{
			# Debug: Enable Verbose Output (used by the importer)
			"name": "verbose_output", "default_value": false
		}
	]

func _import(
		source_file: String,
		save_path: String,
		options: Dictionary,
		platform_variants: Array[String],
		gen_files: Array[String]
) -> Error:

	Util.timer_reset()
	Util.timer_start(Util.DebugTime.TOTAL)
	Util.print("import_start", source_file)

	# Add options to static var in "Util", accessible from any script.
	Util.options = options

	# Parse source_file
	var base_dir := source_file.get_base_dir() + "/"
	var file_name := source_file.get_file()
	var world_name := file_name.split(".")[0]
	var import_cache_path := save_path + ".level_hashes.cfg"
	var import_cache := load_import_cache(import_cache_path)
	var main_source_hash := FileAccess.get_file_as_string(source_file).sha256_text()

	Util.timer_start(Util.DebugTime.LOAD)
	var world_data := Util.parse_file(source_file)
	var external_levels: bool = world_data.externalLevels
	Util.timer_finish("File parsed")

	# Check version
	if Util.check_version(world_data.jsonVersion, LDTK_LATEST_VERSION):
		Util.print("item_ok", "LDTK VERSION (%s) OK" % [world_data.jsonVersion])
	else:
		return ERR_PARSE_ERROR

	Util.timer_start(Util.DebugTime.GENERAL)
	var definitions := DefinitionUtil.build_definitions(world_data)
	var tileset_overrides := Tileset.get_tileset_overrides(world_data, base_dir, external_levels)
	Util.timer_finish("Definitions Created")

	# Build Tilesets and save as Resources
	if Util.options.verbose_output: Util.print("block", "Tilesets")
	var tileset_paths := Tileset.build_tilesets(definitions, base_dir, tileset_overrides)
	gen_files.append_array(tileset_paths)

	# Fetch EntityDef Tile textures
	Tileset.get_entity_def_tiles(definitions, Util.tilesets)

	# Detect Multi-Worlds
	var world_iid: String = world_data.iid

	var world: LDTKWorld
	if world_data.worldLayout == null:
		var world_nodes: Array[LDTKWorld] = []
		var world_instances: Array = world_data.worlds
		# Build each world instance
		for world_instance in world_instances:
			var world_instance_name: String = world_instance.identifier
			var world_instance_iid: String = world_instance.iid
			var levels := Level.build_levels(world_instance, definitions, base_dir, external_levels)
			var world_node := World.create_world(world_instance_name, world_instance_iid, levels, base_dir)
			world_nodes.append(world_node)

		world = World.create_multi_world(world_name, world_iid, world_nodes)
	else:
		if Util.options.verbose_output: Util.print("block", "Levels")
		var levels_path := base_dir + 'levels/'
		var skip_unchanged_levels: bool = options.pack_levels and options.skip_unchanged_levels
		var level_hashes := get_level_hashes(world_data, base_dir, external_levels)
		var previous_level_hashes: Dictionary = import_cache.level_hashes
		var can_reuse_levels: bool = (
			skip_unchanged_levels
			and import_cache.main_source_hash == main_source_hash
		)
		var reusable_level_hashes: Dictionary = previous_level_hashes if can_reuse_levels else {}
		var reused_levels := (
			load_unchanged_levels(
				world_data,
				level_hashes,
				reusable_level_hashes,
				levels_path
			)
			if can_reuse_levels
			else {}
		)
		var levels := Level.build_levels(
			world_data,
			definitions,
			base_dir,
			external_levels,
			reused_levels
		)

		# Save Levels (after Level Post-Import)
		if (Util.options.pack_levels):
			var directory = DirAccess.open(base_dir)
			if not directory.dir_exists(levels_path):
				directory.make_dir(levels_path)

			# Resolve Refs + Cleanup Resolvers. We don't want to save 'NodePathResolver' in the Level scene.
			#if (Util.options.verbose_output): Util.print("block", "References")
			if (Util.options.verbose_output): Util.print("block", "Save Levels")
			Util.handle_references()
			var packed_levels = save_levels(
				levels,
				levels_path,
				gen_files,
				reused_levels
			)
			if skip_unchanged_levels:
				save_import_cache(
					import_cache_path,
					main_source_hash,
					level_hashes
				)
				gen_files.append(import_cache_path)

			if (Util.options.verbose_output): Util.print("block", "Save World")
			world = World.create_world(world_name, world_iid, packed_levels, base_dir)
		else:
			if (Util.options.verbose_output): Util.print("block", "Save World")
			world = World.create_world(world_name, world_iid, levels, base_dir)

			Util.handle_references()

	# Save World as PackedScene
	Util.timer_start(Util.DebugTime.SAVE)
	var err = save_world(world, save_path, gen_files)
	Util.timer_finish("World Saved", 1)

	if Util.options.verbose_output: Util.print("block", "Results")

	Util.timer_finish("Completed.")

	var total_time: int = Util.DebugTime.get_total_time()
	var result_message: String = Util.DebugTime.get_result()

	if Util.options.verbose_output: Util.print("item_info", result_message)
	Util.print("import_finish", str(total_time))

	return err

#endregion

func save_world(
		world: LDTKWorld,
		save_path: String,
		gen_files: Array[String]
) -> Error:
	var packed_world = PackedScene.new()
	packed_world.pack(world)

	Util.print("item_save", "Saving World [color=#fe8019][i]'%s'[/i][/color]" % [save_path], 1)

	var world_path = "%s.%s" % [save_path, _get_save_extension()]
	var err = ResourceSaver.save(packed_world, world_path)
	if err == OK:
		gen_files.append(world_path)
	return err

func save_levels(
		levels: Array[LDTKLevel],
		save_path: String,
		gen_files: Array[String],
		reused_levels: Dictionary
) -> Array[LDTKLevel]:
	Util.timer_start(Util.DebugTime.SAVE)
	var packed_levels: Array[LDTKLevel] = []


	var level_names := levels.map(func(elem): return elem.name)
	Util.print("item_save", "Saving Levels: [color=#fe8019]%s[/color]" % [level_names], 1)

	for level in levels:
		if reused_levels.has(level.iid):
			gen_files.append(level.scene_file_path)
			packed_levels.append(level)
			continue

		for child in level.get_children():
			Util.recursive_set_owner(child, level)
		var level_path := save_level(level, save_path, gen_files)
		var packed_level = load(level_path).instantiate()
		packed_levels.append(packed_level)

	Util.timer_finish("%s Levels Saved" % [levels.size()], 1)
	return packed_levels

func save_level(
		level: LDTKLevel,
		save_path: String,
		gen_files: Array[String]
) -> String:
	var packed_level = PackedScene.new()
	packed_level.pack(level)
	var level_path = "%s%s.%s" % [save_path, level.name, _get_save_extension()]

	var err = ResourceSaver.save(packed_level, level_path)
	if err == OK:
		gen_files.append(level_path)
	else:
		push_error("Failed to save level '%s': %s" % [level_path, error_string(err)])

	return level_path

func get_level_hashes(
		world_data: Dictionary,
		base_dir: String,
		external_levels: bool
) -> Dictionary:
	var hashes := {}

	for level_header in world_data.levels:
		if external_levels:
			var level_path: String = base_dir + level_header.externalRelPath
			hashes[level_header.iid] = FileAccess.get_file_as_string(level_path).sha256_text()
		else:
			hashes[level_header.iid] = str(LEVEL_HASH_CACHE_VERSION)

	return hashes

func load_import_cache(cache_path: String) -> Dictionary:
	var cache := ConfigFile.new()
	if cache.load(cache_path) != OK:
		return {
			"main_source_hash": "",
			"level_hashes": {},
		}

	var hashes := {}
	for level_iid in cache.get_section_keys("levels"):
		hashes[level_iid] = cache.get_value("levels", level_iid, "")
	return {
		"main_source_hash": cache.get_value("metadata", "main_source_hash", ""),
		"level_hashes": hashes,
	}

func save_import_cache(
		cache_path: String,
		main_source_hash: String,
		level_hashes: Dictionary
) -> void:
	var cache := ConfigFile.new()
	cache.set_value("metadata", "main_source_hash", main_source_hash)
	for level_iid in level_hashes:
		cache.set_value("levels", level_iid, level_hashes[level_iid])
	cache.save(cache_path)

func load_unchanged_levels(
		world_data: Dictionary,
		level_hashes: Dictionary,
		previous_level_hashes: Dictionary,
		levels_path: String
) -> Dictionary:
	var levels := {}
	for level_header in world_data.levels:
		var level_iid: String = level_header.iid
		if previous_level_hashes.get(level_iid, "") != level_hashes[level_iid]:
			continue

		var level_path := "%s%s.%s" % [
			levels_path,
			level_header.identifier,
			_get_save_extension(),
		]
		var packed_scene: PackedScene = load(level_path) if FileAccess.file_exists(level_path) else null
		if packed_scene != null:
			levels[level_iid] = packed_scene.instantiate()

	return levels

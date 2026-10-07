extends GdUnitTestSuite

const ImportContext = preload("res://addons/ldtk-importer/src/import-context.gd")
const ImportJson = preload("res://addons/ldtk-importer/src/import-json.gd")
const Util = preload("res://addons/ldtk-importer/src/util/util.gd")
const PostImport = preload("res://addons/ldtk-importer/src/post-import.gd")
const Tileset = preload("res://addons/ldtk-importer/src/tileset.gd")

class Recorder extends RefCounted:
	var loads := 0
	var saved: Array = []
	var value: Variant = {}
	var save_error: Error = OK

	func load_value() -> Variant:
		loads += 1
		return value

	func save_value(key: String) -> Error:
		saved.append(key)
		return save_error

# Exercise the real import wrapper without reading or importing any LDtk data.
class StubImporter extends "res://addons/ldtk-importer/ldtk-importer.gd":
	const ImportJson = preload("res://addons/ldtk-importer/src/import-json.gd")
	var body_error: Error = OK
	var helper_error: Error = OK
	var saver_error: Error = OK
	var reusable := false
	var last_context: RefCounted
	var saved := 0
	var body_calls := 0
	var tileset_hook := ""

	func _import_impl(
			source_file: String, save_path: String, _options: Dictionary,
			_platform_variants: Array[String], _gen_files: Array[String],
			allow_cache_reuse: bool
	) -> Error:
		body_calls += 1
		last_context = Util.import_context
		var cache_path := save_path + ".level_hashes.cfg"
		var import_cache := load_import_cache(cache_path)
		reusable = allow_cache_reuse and import_cache.main_source_hash == "stub-source-hash"
		if not tileset_hook.is_empty():
			# LDtk JSON definitions use floating-point numeric keys and UIDs.
			Tileset.build_tilesets(
				{"layers": {1.0: {
					"uid": 1.0, "identifier": "Solid", "gridSize": 16, "type": "IntGrid",
					"intGridValues": [{"color": "#ffffff"}],
				}}, "tilesets": {}},
				source_file.get_base_dir() + "/", {}, "stub-source-hash", allow_cache_reuse
			)
		var path := source_file.get_base_dir().path_join("registry.json")
		var data: Dictionary = ImportJson.get_or_create(last_context, path, {})
		var index := data.size()
		data["entity-%d" % index] = str(index + 1)
		ImportJson.save_on_success(last_context, path, data)
		last_context.save_on_success("a.saver", _save_helper)
		last_context.fail(helper_error)
		save_import_cache(cache_path, "stub-source-hash", {"level-iid": "stub-level-hash"})
		return body_error

	func _save_helper() -> Error:
		saved += 1
		return saver_error

var _directory: String

func before_test() -> void:
	_directory = ProjectSettings.globalize_path("user://import-context/" + str(Time.get_ticks_usec()))
	assert_int(DirAccess.make_dir_recursive_absolute(_directory)).is_equal(OK)

func after_test() -> void:
	if Util.import_context != null:
		Util.import_context.clear()
		Util.import_context = null
	Util.tilesets.clear()
	Util.clean_references()
	var directory := DirAccess.open(_directory)
	var tilesets_path := _directory.path_join("tilesets")
	if directory.dir_exists("tilesets"):
		for file_name: String in DirAccess.get_files_at(tilesets_path):
			DirAccess.remove_absolute(tilesets_path.path_join(file_name))
		DirAccess.remove_absolute(tilesets_path)
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(_directory.path_join(file_name))
	DirAccess.remove_absolute(_directory)

func _context() -> ImportContext:
	return ImportContext.new()

func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_object(file).is_not_null()
	file.store_string(text)
	file.close()

func _run_import(importer: StubImporter) -> Error:
	return importer._import(
		_directory.path_join("source.json"), _directory.path_join("output"),
		{
			"verbose_output": false, "force_tileset_reimport": false,
			"tileset_save_extension": 0, "integer_grid_tilesets": true,
			"tileset_custom_data": false, "tileset_post_import": importer.tileset_hook,
		}, [], []
	)

func test_factory_runs_once_and_all_callers_share_mutations() -> void:
	var context := _context()
	var recorder := Recorder.new()
	var first: Dictionary = context.get_or_create("registry", recorder.load_value)
	first["iid"] = "42"
	for index in range(1000):
		var next: Dictionary = context.get_or_create("registry", recorder.load_value)
		assert_str(next["iid"]).is_equal("42")
	assert_int(recorder.loads).is_equal(1)
	context.clear()

func test_null_values_are_cached_and_new_contexts_reload() -> void:
	var recorder := Recorder.new()
	recorder.value = null
	var first := _context()
	first.get_or_create("nullable", recorder.load_value)
	first.get_or_create("nullable", recorder.load_value)
	assert_int(recorder.loads).is_equal(1)
	first.clear()
	var second := _context()
	second.get_or_create("nullable", recorder.load_value)
	assert_int(recorder.loads).is_equal(2)
	second.clear()

func test_saves_are_deferred_deduplicated_and_sorted() -> void:
	var context := _context()
	var recorder := Recorder.new()
	context.save_on_success("z", recorder.save_value.bind("z"))
	context.save_on_success("a", recorder.save_value.bind("a"))
	context.save_on_success("z", recorder.save_value.bind("duplicate"))
	assert_array(recorder.saved).is_empty()
	assert_int(context.flush()).is_equal(OK)
	assert_array(recorder.saved).contains_exactly(["a", "z"])
	assert_int(context.flush()).is_equal(OK)
	assert_array(recorder.saved).contains_exactly(["a", "z"])
	context.clear()

func test_failure_discards_saves_and_preserves_first_error() -> void:
	var context := _context()
	var recorder := Recorder.new()
	context.save_on_success("registry", recorder.save_value.bind("registry"))
	context.fail(ERR_PARSE_ERROR)
	context.fail(ERR_CANT_CREATE)
	assert_int(context.flush()).is_equal(ERR_PARSE_ERROR)
	assert_array(recorder.saved).is_empty()
	context.clear()

func test_failed_saver_stops_remaining_saves() -> void:
	var context := _context()
	var recorder := Recorder.new()
	recorder.save_error = ERR_CANT_CREATE
	context.save_on_success("a", recorder.save_value.bind("a"))
	context.save_on_success("z", recorder.save_value.bind("z"))
	await assert_error(context.flush).is_push_error(any_string())
	assert_int(context.error).is_equal(ERR_CANT_CREATE)
	assert_array(recorder.saved).contains_exactly(["a"])
	context.clear()

func test_clear_releases_cached_helpers_and_bound_savers() -> void:
	var context := _context()
	var recorder := Recorder.new()
	var reference: WeakRef = weakref(recorder)
	context.get_or_create("helper", recorder.load_value)
	context.save_on_success("helper", recorder.save_value.bind("helper"))
	recorder = null
	assert_bool(reference.get_ref() != null).is_true()
	context.clear()
	assert_bool(reference.get_ref() == null).is_true()
	await assert_error(context.flush).is_push_error(any_string())
	assert_int(context.error).is_equal(ERR_UNCONFIGURED)

func test_json_aliases_share_one_parse_until_the_next_import() -> void:
	var context := _context()
	var path := _directory.path_join("registry.json")
	_write(path, '{"iid": "42"}')
	var first: Dictionary = ImportJson.get_or_create(context, path)
	_write(path, '{"iid": "99"}')
	var alias: Dictionary = ImportJson.get_or_create(context, _directory.path_join("./registry.json"))
	assert_str(alias["iid"]).is_equal("42")
	first["other"] = "7"
	assert_str(alias["other"]).is_equal("7")
	context.clear()
	var next := _context()
	var reloaded: Dictionary = ImportJson.get_or_create(next, path)
	assert_str(reloaded["iid"]).is_equal("99")
	next.clear()

func test_json_missing_file_defaults_are_copied_and_not_saved_automatically() -> void:
	var context := _context()
	var defaults := {"nested": {"id": "42"}}
	var data: Dictionary = ImportJson.get_or_create(context, _directory.path_join("registry.json"), defaults)
	data["nested"]["id"] = "99"
	assert_str(defaults["nested"]["id"]).is_equal("42")
	assert_int(context.flush()).is_equal(OK)
	assert_bool(FileAccess.file_exists(_directory.path_join("registry.json"))).is_false()
	context.clear()

func test_json_save_includes_later_mutations_and_preserves_large_string_ids() -> void:
	var context := _context()
	var path := _directory.path_join("registry.json")
	var data: Dictionary = ImportJson.get_or_create(context, path)
	data["z"] = "9223372036854775807"
	ImportJson.save_on_success(context, path, data)
	data["a"] = "42"
	ImportJson.save_on_success(context, _directory.path_join("./registry.json"), data)
	assert_bool(FileAccess.file_exists(path)).is_false()
	assert_int(context.flush()).is_equal(OK)
	assert_str(FileAccess.get_file_as_string(path)).is_equal(
		'{\n\t"a": "42",\n\t"z": "9223372036854775807"\n}\n'
	)
	assert_bool(FileAccess.file_exists(_directory.path_join(".registry.json.tmp"))).is_false()
	context.clear()

func test_json_identical_save_does_not_replace_the_file() -> void:
	var context := _context()
	var path := _directory.path_join("registry.json")
	var contents := '{\n\t"id": "42"\n}\n'
	_write(path, contents)
	var data: Dictionary = ImportJson.get_or_create(context, path)
	var temporary_path := _directory.path_join(".registry.json.tmp")
	_write(temporary_path, "untouched")
	ImportJson.save_on_success(context, path, data)
	assert_int(context.flush()).is_equal(OK)
	assert_str(FileAccess.get_file_as_string(temporary_path)).is_equal("untouched")
	assert_str(FileAccess.get_file_as_string(path)).is_equal(contents)
	context.clear()

func test_json_rejects_incomplete_or_changed_temporary_files() -> void:
	var path := _directory.path_join("registry.json")
	var temporary_path := _directory.path_join(".registry.json.tmp")
	var original := '{"id":"old"}\n'
	var expected := '{"id":"new"}\n'
	_write(path, original)
	for damaged: String in ["", expected.left(5), original, expected + "extra"]:
		_write(temporary_path, damaged)
		assert_int(ImportJson._replace_verified_file(
			temporary_path, path, expected.to_utf8_buffer()
		)).is_equal(ERR_FILE_CANT_WRITE)
		assert_str(FileAccess.get_file_as_string(path)).is_equal(original)
		assert_bool(FileAccess.file_exists(temporary_path)).is_false()

func test_json_unreadable_temporary_file_preserves_original() -> void:
	var path := _directory.path_join("registry.json")
	var temporary_path := _directory.path_join(".registry.json.tmp")
	_write(path, "original")
	assert_int(ImportJson._replace_verified_file(
		temporary_path, path, "replacement".to_utf8_buffer()
	)).is_not_equal(OK)
	assert_str(FileAccess.get_file_as_string(path)).is_equal("original")

func test_json_save_verifies_utf8_bytes() -> void:
	var context := _context()
	var path := _directory.path_join("registry.json")
	var data := {"name": "Żółw 🚀"}
	ImportJson.save_on_success(context, path, data)
	assert_int(context.flush()).is_equal(OK)
	assert_dict(JSON.parse_string(FileAccess.get_file_as_string(path))).is_equal(data)
	context.clear()

func test_malformed_json_fails_without_overwriting_the_file() -> void:
	var context := _context()
	var path := _directory.path_join("registry.json")
	_write(path, "{bad")
	await assert_error(ImportJson.get_or_create.bind(context, path)).is_push_error(any_string())
	assert_int(context.error).is_equal(ERR_PARSE_ERROR)
	ImportJson.save_on_success(context, path, {"replacement": true})
	assert_int(context.flush()).is_equal(ERR_PARSE_ERROR)
	assert_str(FileAccess.get_file_as_string(path)).is_equal("{bad")
	context.clear()

func test_valid_json_null_is_distinct_from_parse_failure() -> void:
	var context := _context()
	var path := _directory.path_join("registry.json")
	_write(path, "null")
	assert_object(ImportJson.get_or_create(context, path)).is_null()
	assert_int(context.error).is_equal(OK)
	context.clear()

func test_json_rejects_relative_paths() -> void:
	var context := _context()
	await assert_error(ImportJson.get_or_create.bind(context, "registry.json")).is_push_error(any_string())
	assert_int(context.error).is_equal(ERR_INVALID_PARAMETER)
	assert_int(context.flush()).is_equal(ERR_INVALID_PARAMETER)
	context.clear()

func test_successful_import_saves_level_hashes_and_clears_context(
		_do_skip: bool = not Engine.is_editor_hint(),
		_skip_reason: String = "EditorImportPlugin requires editor mode."
) -> void:
	var importer := StubImporter.new()
	assert_int(_run_import(importer)).is_equal(OK)
	assert_bool(importer.reusable).is_false()
	assert_object(Util.import_context).is_null()
	assert_int(importer.saved).is_equal(1)
	assert_bool(FileAccess.file_exists(_directory.path_join("output.pending"))).is_false()
	var cache: Dictionary = importer.load_import_cache(_directory.path_join("output.level_hashes.cfg"))
	assert_str(cache.main_source_hash).is_equal("stub-source-hash")
	assert_dict(cache.level_hashes).is_equal({"level-iid": "stub-level-hash"})
	assert_int(_run_import(importer)).is_equal(OK)
	assert_bool(importer.reusable).is_true()
	assert_int(importer.saved).is_equal(2)
	importer = null

func test_registry_updates_preserve_level_reuse(
		_do_skip: bool = not Engine.is_editor_hint(),
		_skip_reason: String = "EditorImportPlugin requires editor mode."
) -> void:
	var importer := StubImporter.new()
	assert_int(_run_import(importer)).is_equal(OK)
	var cache_path := _directory.path_join("output.level_hashes.cfg")
	var previous_cache: Dictionary = importer.load_import_cache(cache_path)
	assert_int(_run_import(importer)).is_equal(OK)
	assert_bool(importer.reusable).is_true()
	var current_cache: Dictionary = importer.load_import_cache(cache_path)
	assert_dict(current_cache.level_hashes).is_equal(previous_cache.level_hashes)
	var registry: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(_directory.path_join("registry.json"))
	)
	assert_dict(registry).is_equal({"entity-0": "1", "entity-1": "2"})
	importer = null

func test_failed_import_discards_saves_and_bypasses_retained_cache_on_retry(
		_do_skip: bool = not Engine.is_editor_hint(),
		_skip_reason: String = "EditorImportPlugin requires editor mode."
) -> void:
	var importer := StubImporter.new()
	assert_int(_run_import(importer)).is_equal(OK)
	var path := _directory.path_join("registry.json")
	var original := FileAccess.get_file_as_string(path)
	importer.body_error = ERR_INVALID_DATA
	assert_int(_run_import(importer)).is_equal(ERR_INVALID_DATA)
	assert_int(importer.saved).is_equal(1)
	assert_str(FileAccess.get_file_as_string(path)).is_equal(original)
	assert_object(Util.import_context).is_null()
	assert_bool(FileAccess.file_exists(_directory.path_join("output.level_hashes.cfg"))).is_true()
	assert_bool(FileAccess.file_exists(_directory.path_join("output.pending"))).is_true()
	importer.body_error = OK
	assert_int(_run_import(importer)).is_equal(OK)
	assert_bool(importer.reusable).is_false()
	assert_bool(FileAccess.file_exists(_directory.path_join("output.pending"))).is_false()
	importer = null

func test_unfinished_import_bypasses_existing_level_cache(
		_do_skip: bool = not Engine.is_editor_hint(),
		_skip_reason: String = "EditorImportPlugin requires editor mode."
) -> void:
	var importer := StubImporter.new()
	assert_int(_run_import(importer)).is_equal(OK)
	_write(_directory.path_join("output.pending"), "")
	# Simulate a restart with a saved cache from an interrupted import.
	importer = StubImporter.new()
	assert_int(_run_import(importer)).is_equal(OK)
	assert_bool(importer.reusable).is_false()
	assert_bool(FileAccess.file_exists(_directory.path_join("output.pending"))).is_false()
	assert_int(_run_import(importer)).is_equal(OK)
	assert_bool(importer.reusable).is_true()
	importer = null

func test_marker_creation_failure_does_not_start_import(
		_do_skip: bool = not Engine.is_editor_hint(),
		_skip_reason: String = "EditorImportPlugin requires editor mode."
) -> void:
	var pending_path := _directory.path_join("output.pending")
	assert_int(DirAccess.make_dir_absolute(pending_path)).is_equal(OK)
	var importer := StubImporter.new()
	assert_int(_run_import(importer)).is_not_equal(OK)
	assert_int(importer.body_calls).is_equal(0)
	assert_object(Util.import_context).is_null()
	assert_bool(FileAccess.file_exists(_directory.path_join("registry.json"))).is_false()
	DirAccess.remove_absolute(pending_path)
	importer = null

func test_failed_tileset_helper_is_retried_by_fresh_importer(
		_do_skip: bool = not Engine.is_editor_hint(),
		_skip_reason: String = "EditorImportPlugin requires editor mode."
) -> void:
	var hook_path := _directory.path_join("tileset-hook.gd")
	_write(hook_path, '''@tool
extends RefCounted
const Util = preload("res://addons/ldtk-importer/src/util/util.gd")
const ImportJson = preload("res://addons/ldtk-importer/src/import-json.gd")
func post_import(tilesets: Dictionary) -> Dictionary:
	var tileset: TileSet = tilesets[16]
	var visits: int = tileset.get_meta("visits", 0) + 1
	tileset.set_meta("visits", visits)
	var path: String = get_script().resource_path.get_base_dir().path_join("tileset-helper.json")
	ImportJson.save_on_success(Util.import_context, path, {"visits": visits})
	return tilesets
''')
	var tileset := TileSet.new()
	tileset.resource_name = "tileset_16px"
	tileset.set_meta("manual_edit", "preserved")
	var tilesets_path := _directory.path_join("tilesets")
	assert_int(DirAccess.make_dir_absolute(tilesets_path)).is_equal(OK)
	var tileset_path := tilesets_path.path_join("tileset_16px.res")
	assert_int(ResourceSaver.save(tileset, tileset_path)).is_equal(OK)
	var importer := StubImporter.new()
	importer.tileset_hook = hook_path
	importer.body_error = ERR_INVALID_DATA
	assert_int(_run_import(importer)).is_equal(ERR_INVALID_DATA)
	var helper_path := _directory.path_join("tileset-helper.json")
	assert_bool(FileAccess.file_exists(helper_path)).is_false()
	assert_bool(FileAccess.file_exists(_directory.path_join("output.pending"))).is_true()
	importer = StubImporter.new()
	importer.tileset_hook = hook_path
	assert_int(_run_import(importer)).is_equal(OK)
	assert_dict(JSON.parse_string(FileAccess.get_file_as_string(helper_path))).is_equal({"visits": 2.0})
	var rebuilt: TileSet = load(tileset_path)
	assert_str(rebuilt.get_meta("manual_edit")).is_equal("preserved")
	assert_bool(FileAccess.file_exists(_directory.path_join("output.pending"))).is_false()
	assert_int(_run_import(importer)).is_equal(OK)
	assert_int(rebuilt.get_meta("visits")).is_equal(2)
	importer = null

func test_helper_failure_overrides_success_and_discards_saves(
		_do_skip: bool = not Engine.is_editor_hint(),
		_skip_reason: String = "EditorImportPlugin requires editor mode."
) -> void:
	var importer := StubImporter.new()
	importer.helper_error = ERR_PARSE_ERROR
	assert_int(_run_import(importer)).is_equal(ERR_PARSE_ERROR)
	assert_int(importer.saved).is_equal(0)
	assert_object(Util.import_context).is_null()
	assert_bool(FileAccess.file_exists(_directory.path_join("registry.json"))).is_false()
	importer = null

func test_saver_failure_fails_import_and_clears_context(
		_do_skip: bool = not Engine.is_editor_hint(),
		_skip_reason: String = "EditorImportPlugin requires editor mode."
) -> void:
	var importer := StubImporter.new()
	importer.saver_error = ERR_CANT_CREATE
	await assert_error(_run_import.bind(importer)).is_push_error(any_string())
	assert_object(Util.import_context).is_null()
	assert_bool(FileAccess.file_exists(_directory.path_join("output.level_hashes.cfg"))).is_true()
	# Earlier successful saves are not rolled back when a later saver fails.
	assert_bool(FileAccess.file_exists(_directory.path_join("output.pending"))).is_true()
	assert_bool(FileAccess.file_exists(_directory.path_join("registry.json"))).is_true()
	assert_int(importer.last_context.error).is_equal(ERR_CANT_CREATE)
	importer.saver_error = OK
	assert_int(_run_import(importer)).is_equal(OK)
	assert_bool(importer.reusable).is_false()
	assert_bool(FileAccess.file_exists(_directory.path_join("output.pending"))).is_false()
	importer = null

func test_fresh_hook_instances_share_state_and_keep_the_deferred_saver_alive() -> void:
	var path := _directory.path_join("shared-hook.gd")
	_write(path, '''@tool
extends RefCounted
const Util = preload("res://addons/ldtk-importer/src/util/util.gd")
var state: Dictionary
func post_import(element: Dictionary) -> Dictionary:
	state = Util.import_context.get_or_create("helper", _load.bind(element))
	state.visits += 1
	Util.import_context.save_on_success("helper", _save)
	element.state = state
	return element
func _load(element: Dictionary) -> Dictionary:
	element.loads += 1
	return {"visits": 0, "saves": 0}
func _save() -> Error:
	state.saves += 1
	return OK
''')
	var context := _context()
	Util.import_context = context
	var input := {"loads": 0}
	PostImport.run(input, path, [])
	PostImport.run(input, path, [])
	assert_int(input.loads).is_equal(1)
	assert_int(input.state.visits).is_equal(2)
	assert_int(input.state.saves).is_equal(0)
	assert_int(context.flush()).is_equal(OK)
	assert_int(input.state.saves).is_equal(1)
	context.clear()
	Util.import_context = null

func test_hook_validation_failure_retains_input_and_aborts_deferred_saves() -> void:
	var context := _context()
	Util.import_context = context
	var recorder := Recorder.new()
	context.save_on_success("registry", recorder.save_value.bind("registry"))
	var input := {"id": "42"}
	var results: Array = []
	await assert_error(func() -> void:
		results.append(PostImport.run(input, "res://addons/ldtk-importer/src/import-json.gd", []))
	).is_push_error(any_string())
	assert_dict(results[0]).is_equal(input)
	assert_int(context.error).is_equal(ERR_INVALID_PARAMETER)
	assert_int(context.flush()).is_equal(ERR_INVALID_PARAMETER)
	assert_array(recorder.saved).is_empty()
	context.clear()
	Util.import_context = null

extends RefCounted

const ImportContext = preload("import-context.gd")

## Return the same parsed JSON value for every spelling of the same path.
## Only missing files use defaults; unreadable or malformed files fail the import.
static func get_or_create(
		context: ImportContext,
		path: String,
		default_value: Variant = {}
) -> Variant:
	path = _normalize_path(context, path)
	return context.get_or_create(path, _load.bind(context, path, default_value))

## Call after changing the cached value. Dictionary/Array mutations made by later
## hooks are included in the save. For scalar values, bind the final value once.
static func save_on_success(context: ImportContext, path: String, data: Variant) -> void:
	path = _normalize_path(context, path)
	context.save_on_success(path, _save.bind(path, data))

static func _normalize_path(context: ImportContext, path: String) -> String:
	if path.is_relative_path():
		context.fail(ERR_INVALID_PARAMETER, "JSON helper requires a full path: '%s'." % path)
		return ""
	return ProjectSettings.localize_path(ProjectSettings.globalize_path(path)).simplify_path()

static func _load(context: ImportContext, path: String, default_value: Variant) -> Variant:
	if not FileAccess.file_exists(path):
		if default_value is Dictionary or default_value is Array:
			return default_value.duplicate(true)
		return default_value
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		context.fail(FileAccess.get_open_error(), "Cannot open JSON helper '%s'." % path)
		return null
	var text := file.get_as_text()
	var read_error := file.get_error()
	file.close()
	if read_error != OK and read_error != ERR_FILE_EOF:
		context.fail(read_error, "Cannot read JSON helper '%s'." % path)
		return null
	var json := JSON.new()
	var parse_error := json.parse(text)
	if parse_error != OK:
		context.fail(parse_error, "Invalid JSON helper '%s' at line %s: %s." % [
			path, json.get_error_line(), json.get_error_message(),
		])
		return null
	return json.data

static func _save(path: String, data: Variant) -> Error:
	var text := JSON.stringify(data, "\t", true, true) + "\n"
	if FileAccess.file_exists(path) and FileAccess.get_file_as_string(path) == text:
		return OK
	# A hidden sibling stays on the same filesystem and out of resource imports.
	var temporary_path := path.get_base_dir().path_join("." + path.get_file() + ".tmp")
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var bytes := text.to_utf8_buffer()
	file.store_buffer(bytes)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(temporary_path)
		return write_error
	return _replace_verified_file(temporary_path, path, bytes)

static func _replace_verified_file(temporary_path: String, path: String, expected: PackedByteArray) -> Error:
	# Buffered writes can fail on flush/close without updating get_error().
	var file := FileAccess.open(temporary_path, FileAccess.READ)
	var read_error := FileAccess.get_open_error()
	if file != null:
		var actual := file.get_buffer(expected.size() + 1)
		read_error = file.get_error()
		file.close()
		if read_error == OK or read_error == ERR_FILE_EOF:
			read_error = OK if actual == expected else ERR_FILE_CANT_WRITE
	if read_error != OK:
		DirAccess.remove_absolute(temporary_path)
		return read_error
	var rename_error := DirAccess.rename_absolute(temporary_path, path)
	if rename_error != OK:
		DirAccess.remove_absolute(temporary_path)
	return rename_error

extends RefCounted

var error: Error = OK

var _values: Dictionary = {}
var _savers: Dictionary = {}
var _active := true
var _saving := false

## Factories are called once per key. Mutable values are shared by all hooks.
func get_or_create(key: String, factory: Callable) -> Variant:
	if not _active:
		fail(ERR_UNCONFIGURED, "The import context is no longer active.")
	if error != OK:
		return null
	if _values.has(key):
		return _values[key]
	if not factory.is_valid():
		fail(ERR_INVALID_PARAMETER, "Invalid import helper factory for '%s'." % key)
		return null
	var value: Variant = factory.call()
	if error == OK:
		_values[key] = value
	return value

## Register only after a change. The first saver registered for a key wins.
## Savers take no arguments and return Error.
func save_on_success(key: String, saver: Callable) -> void:
	if not _active or _saving:
		fail(ERR_UNCONFIGURED, "Cannot register saves after the import has finished.")
	if error != OK:
		return
	if not saver.is_valid():
		fail(ERR_INVALID_PARAMETER, "Invalid import helper saver for '%s'." % key)
		return
	if not _savers.has(key):
		# A bound Callable alone does not keep a RefCounted receiver alive.
		_savers[key] = {"callback": saver, "owner": saver.get_object()}

func fail(code: Error, message: String = "") -> void:
	if error != OK or code == OK:
		return
	error = code
	if not message.is_empty():
		push_error(message)

## Called by the importer only after the import body succeeds.
func flush() -> Error:
	if not _active or _saving:
		fail(ERR_UNCONFIGURED, "Cannot flush an inactive import context.")
	if error != OK:
		return error
	_saving = true
	var keys: Array = _savers.keys()
	keys.sort()
	for key: String in keys:
		var result: Variant = _savers[key].callback.call()
		if not (result is int):
			fail(ERR_INVALID_DATA, "Import helper saver '%s' must return Error." % key)
		elif result != OK:
			fail(result, "Cannot save import helper '%s': %s." % [key, error_string(result)])
		if error != OK:
			break
	_savers.clear()
	_saving = false
	return error

func clear() -> void:
	_active = false
	_values.clear()
	_savers.clear()

extends RefCounted
## Offline interception: records the exact whole selected assembly context.
static func prepare(source, assemblies: Array, protected: Array, continuation: Callable = Callable()) -> Dictionary:
	if continuation.is_valid() and continuation.call("bunting_capture_write") != true: return {"ready": false, "reason": "cancelled"}
	var path := OS.get_environment("CITADEL_ORDERED_OPENING_REPORT").get_base_dir().path_join("input.bin")
	if FileAccess.file_exists(path): return {"ready": false, "reason": "capture_exists"}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return {"ready": false, "reason": "capture_write_failed"}
	file.store_var({"blueprint": source.snapshot(), "assemblies": assemblies.duplicate(true), "protected": protected.duplicate(true)}, false)
	file.flush(); var saved := file.get_error() == OK; file.close()
	return {"ready": false, "reason": "cancelled" if saved else "capture_write_failed"}

static func verify_stored(_source, _assemblies: Array, _protected: Array, _continuation: Callable = Callable()) -> Dictionary:
	return {"ready": false, "reason": "capture_must_not_reach_terminal_verification"}

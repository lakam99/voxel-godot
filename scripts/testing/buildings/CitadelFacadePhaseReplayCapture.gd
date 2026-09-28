extends RefCounted
## Offline pass-through only. Calls each production phase once with its actual
## orchestrator inputs; saves complete public results before snapshot removal.
const Opening = preload("res://scripts/buildings/OpeningHeadBandRecipe.gd")
const Lower = preload("res://scripts/buildings/LowerFacadeBearingRecipe.gd")
const MAX_BYTES := 64 * 1024 * 1024
static var receipts: Dictionary = {}

static func prepare_all_first_rows(source, policy: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	var snapshot: Dictionary = source.snapshot()
	var source_bytes := var_to_bytes(snapshot)
	var policy_bytes := var_to_bytes(policy)
	var parts: Array = source.parts.duplicate()
	if not write_value("opening-input.bin", {"blueprint": snapshot, "policy": policy.duplicate(true)}): return _fail("opening_input_write")
	var started := Time.get_ticks_usec()
	var result: Dictionary = Opening.prepare_all_first_rows(source, policy, continuation)
	var elapsed := Time.get_ticks_usec() - started
	var checks := {"callerSnapshotUnchanged": source_bytes == var_to_bytes(source.snapshot()),
		"callerPartObjectsUnchanged": parts == source.parts, "policyUnchanged": policy_bytes == var_to_bytes(policy),
		"outputSavedExactly": write_value("opening-expected.bin", result)}
	receipts["opening"] = {"checks": checks, "phaseCallElapsedUsec": elapsed}
	if not checks.values().all(func(value): return value == true): return _fail("opening_capture_checks")
	return result

static func prepare_all_bottom_rows(snapshot: Dictionary, policy: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	var source_bytes := var_to_bytes(snapshot)
	var policy_bytes := var_to_bytes(policy)
	var opening := read_value("opening-expected.bin")
	if not opening.get("ready", false) or source_bytes != var_to_bytes(opening.get("candidateSnapshot")): return _fail("lower_input_binding")
	if not write_value("lower-input.bin", {"blueprint": snapshot.duplicate(true), "policy": policy.duplicate(true)}): return _fail("lower_input_write")
	var started := Time.get_ticks_usec()
	var result: Dictionary = Lower.prepare_all_bottom_rows(snapshot, policy, continuation)
	var elapsed := Time.get_ticks_usec() - started
	var checks := {"callerSnapshotUnchanged": source_bytes == var_to_bytes(snapshot), "policyUnchanged": policy_bytes == var_to_bytes(policy),
		"actualOpeningOutputBound": true, "outputSavedExactly": write_value("lower-expected.bin", result)}
	receipts["lower"] = {"checks": checks, "phaseCallElapsedUsec": elapsed}
	if not checks.values().all(func(value): return value == true): return _fail("lower_capture_checks")
	return result

static func artifact_path(name: String) -> String:
	return OS.get_environment("CITADEL_FACADE_PHASE_REPORT").get_base_dir().path_join(name)

static func write_value(name: String, value: Dictionary) -> bool:
	if not _object_free(value, 0, {"nodes": 0}): return false
	var bytes := var_to_bytes(value)
	if bytes.is_empty() or bytes.size() > MAX_BYTES or FileAccess.file_exists(artifact_path(name)): return false
	var file := FileAccess.open(artifact_path(name), FileAccess.WRITE)
	if file == null: return false
	file.store_var(value, false); file.flush()
	var saved := file.get_error() == OK; file.close()
	return saved and var_to_bytes(read_value(name)) == bytes

static func read_value(name: String) -> Dictionary:
	return read_path(artifact_path(name))

static func read_path(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	if file.get_length() <= 0 or file.get_length() > MAX_BYTES: file.close(); return {}
	var value: Variant = file.get_var(false)
	var complete := file.get_error() == OK and file.get_position() == file.get_length(); file.close()
	if not complete or not value is Dictionary or not _object_free(value, 0, {"nodes": 0}): return {}
	return value

static func _object_free(value: Variant, depth: int, work: Dictionary) -> bool:
	work.nodes += 1
	if depth > 32 or work.nodes > 1000000 or typeof(value) in [TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID]: return false
	if value is Dictionary:
		for key: Variant in value:
			if not _object_free(key, depth + 1, work) or not _object_free(value[key], depth + 1, work): return false
	elif value is Array:
		for item: Variant in value:
			if not _object_free(item, depth + 1, work): return false
	return true

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": "diagnostic_" + reason}

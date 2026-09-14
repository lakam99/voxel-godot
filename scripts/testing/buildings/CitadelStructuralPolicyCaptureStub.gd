extends RefCounted
## Offline interception only; never returns ready or publishable source.
static func prepare(blueprint, policy: Dictionary, _continuation: Callable = Callable(), _raw_stage_observer: Callable = Callable()) -> Dictionary:
	var path := OS.get_environment("CITADEL_POLICY_CAPTURE_REPORT").get_base_dir().path_join("input.bin")
	if FileAccess.file_exists(path): return {"ready": false, "reason": "capture_exists"}
	var lookup_mismatches: Array = []
	for part in blueprint.parts:
		if blueprint.find_part(part.id) != part and lookup_mismatches.size() < 16: lookup_mismatches.append(part.id)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return {"ready": false, "reason": "capture_write_failed"}
	file.store_var({"blueprint": blueprint.snapshot(), "policy": policy.duplicate(true),
		"lookupMismatchExamples": lookup_mismatches, "validationCacheActive": blueprint._validation_cache_active}, false)
	file.flush(); var saved := file.get_error() == OK; file.close()
	return {"ready": false, "reason": "cancelled" if saved else "capture_write_failed"}

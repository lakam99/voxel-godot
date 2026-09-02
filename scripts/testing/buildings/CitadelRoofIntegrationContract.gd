extends SceneTree

## Source/service parity only. Capture BEFORE composer integration using
## -- --capture-prototype; default comparison NEVER calls Frame.add_frame.
## Set distinct absolute VOXEL_ROOF_INTEGRATION_BASELINE (binary evidence) and
## VOXEL_ROOF_INTEGRATION_REPORT (JSON) paths. Existing evidence is never replaced.
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Frame = preload("res://scripts/buildings/GablePurlinFrameBuilder.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Furniture = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const FIXTURE := {"seed": 208159, "biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25, "furnitureSeed": 208159 * 7919 + 37}
const OUTPUT_FIELDS := ["fixture", "sourceSnapshot", "resolvedSnapshot", "physicalValidation", "furnitureSnapshot", "protectedReservations"]
var _report_path := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var started := Time.get_ticks_msec()
	var capture := OS.get_cmdline_user_args().has("--capture-prototype")
	var baseline_path := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE").strip_edges().simplify_path()
	_report_path = OS.get_environment("VOXEL_ROOF_INTEGRATION_REPORT").strip_edges().simplify_path()
	var report := {"evidenceLevel": "source_service_exact_parity", "mode": "capture-prototype" if capture else "compare-integrated",
		"passed": false, "checks": {}, "baselinePath": baseline_path, "sourceScriptSha256": _script_hashes(),
		"doesNotProve": "No headed rendering, published mesh/material parity, live physics/navigation, gameplay acceptance or general-seed coverage. Whole-blueprint physical failures are retained, not required to disappear. Equality includes all captured values and array order; dictionary insertion order is canonicalized. Furniture is the actual CastleFurnishingPlanner service on an independent complete copy."}
	if not baseline_path.is_absolute_path() or not _report_path.is_absolute_path() or baseline_path.to_lower() == _report_path.to_lower():
		_report_path = "" # Never risk writing the report over binary evidence.
		_finish(report, "require_distinct_absolute_baseline_and_report_paths", 2)
		return
	if capture and FileAccess.file_exists(baseline_path):
		_finish(report, "refusing_existing_baseline", 2)
		return
	var frozen: Dictionary = {}
	var baseline_file_sha := ""
	if not capture:
		var loaded := _read_baseline(baseline_path)
		if not bool(loaded.get("ready", false)):
			_finish(report, String(loaded.get("reason", "invalid_baseline")), 2)
			return
		frozen = loaded["output"]
		baseline_file_sha = String(loaded.fileSha256)
		report["baselineFileSha256"] = baseline_file_sha
		report["baselineSourceScriptSha256"] = loaded.scriptHashes
		report["unframedSourceDigest"] = loaded.unframedSourceDigest
	print("roof integration: build actual fixture; mode=", report.mode)
	var blueprint = Castle.build(FIXTURE.seed, {"biome": FIXTURE.biome, "siteKey": FIXTURE.siteKey, "citadelScale": FIXTURE.citadelScale})
	if blueprint == null or Urban.compose(blueprint, FIXTURE.seed) == null:
		_finish(report, "castle_or_composer_returned_null", 1)
		return
	var unframed_source: Dictionary = {}
	if capture:
		# Immutable input for the later VisualProbe, deliberately separate from
		# parity output: integrated comparison must not manufacture an unframed world.
		unframed_source = blueprint.snapshot()
		var setups := _add_prototype_frames(blueprint)
		report["prototypeSetups"] = setups
		if setups.size() != 16 or not setups.all(func(value): return bool(value.get("ready", false))):
			_finish(report, "prototype_frame_setup_failed", 1)
			return
	# In compare mode, integrated Urban.compose above is the ONLY frame source.
	var source: Dictionary = blueprint.snapshot()
	print("roof integration: resolve physical contracts")
	var physical: Dictionary = blueprint.validate_physical_integrity()
	var resolved: Dictionary = blueprint.snapshot()
	print("roof integration: actual furniture planner on independent copy")
	var furniture = Furniture.build(_copy_blueprint(blueprint), FIXTURE.furnitureSeed)
	if furniture == null:
		_finish(report, "furniture_planner_returned_null", 1)
		return
	var output := {"fixture": FIXTURE.duplicate(true), "sourceSnapshot": source, "resolvedSnapshot": resolved,
		"physicalValidation": physical, "furnitureSnapshot": furniture.snapshot(),
		"protectedReservations": furniture.protected_access_reservations.duplicate(true)}
	if not _object_free(output) or not _object_free(unframed_source):
		_finish(report, "output_contains_object_rid_callable_or_signal", 1)
		return
	var indices := _indices(output)
	var checks: Dictionary = report.checks
	checks["unique_nonempty_record_ids"] = indices.values().all(func(index): return (index.errors as Array).is_empty())
	checks["nonempty_source_and_furniture"] = not (source.parts as Array).is_empty() and not (output.furnitureSnapshot.parts as Array).is_empty()
	checks["planner_did_not_mutate_probe_source"] = _digest(resolved) == _digest(blueprint.snapshot())
	var frame_ids: Array = []
	var role_counts := {"gable_roof_panel": 0, "gable_roof_purlin": 0, "gable_roof_post": 0}
	for part in blueprint.parts:
		var role := String(part.recipe.get("physicalAssemblyRole", ""))
		if role_counts.has(role):
			role_counts[role] += 1
			frame_ids.append(String(part.id))
	var frame_checks: Array = physical.checks.filter(func(check): return frame_ids.has(String(check.partId)))
	checks["expected_frame_members_present"] = role_counts == {"gable_roof_panel": 32, "gable_roof_purlin": 64, "gable_roof_post": 128}
	checks["frame_physical_checks_pass"] = frame_checks.size() == 224 and frame_checks.all(func(check): return bool(check.passed))
	report["roleCounts"] = role_counts
	report["physicalPassed"] = physical.passed
	report["physicalViolationCount"] = physical.violations.size()
	report["current"] = _summary(output, indices)
	if not checks.values().all(func(value): return bool(value)):
		_finish(report, "current_output_setup_failed", 1)
		return
	if capture:
		# Recheck immediately before opening; this is a single-writer capture.
		# Do not delete a failed/partial file: its presence prevents recapture.
		if FileAccess.file_exists(baseline_path):
			_finish(report, "baseline_appeared_during_capture_refusing_overwrite", 2)
			return
		var file := FileAccess.open(baseline_path, FileAccess.WRITE)
		if file == null:
			_finish(report, "cannot_create_baseline", 2)
			return
		file.store_var({"schemaVersion": 1, "provenance": "manual_prototype", "output": output, "digest": _digest(output),
			"unframedSource": unframed_source, "unframedSourceDigest": _digest(unframed_source),
			"scriptHashes": report.sourceScriptSha256}, false)
		file.flush()
		var write_error := file.get_error()
		file.close()
		if write_error != OK:
			_finish(report, "baseline_write_failed_retained_for_inspection", 2)
			return
		var reread := _read_baseline(baseline_path)
		checks["binary_roundtrip_exact"] = bool(reread.get("ready", false)) and _digest(reread.get("output", {})) == _digest(output)
		checks["unframed_source_roundtrip_exact"] = bool(reread.get("ready", false)) and String(reread.get("unframedSourceDigest", "")) == _digest(unframed_source)
		report["baselineFileSha256"] = reread.get("fileSha256", "")
		report["unframedSourceDigest"] = _digest(unframed_source)
	else:
		var frozen_indices := _indices(frozen)
		report["baseline"] = _summary(frozen, frozen_indices)
		checks["baseline_record_ids_valid"] = frozen_indices.values().all(func(index): return (index.errors as Array).is_empty())
		for field in OUTPUT_FIELDS:
			checks[String(field) + "_exact"] = _digest(frozen[field]) == _digest(output[field])
		var changes: Dictionary = {}
		for label in indices:
			var old: Dictionary = frozen_indices[label]
			var current: Dictionary = indices[label]
			checks[String(label) + "_by_id_exact"] = _digest(old.byId) == _digest(current.byId)
			checks[String(label) + "_order_exact"] = _digest(old.order) == _digest(current.order)
			changes[label] = _changed_ids(old.byId, current.byId)
		report["changedRecordIds"] = changes
		checks["whole_output_exact"] = _digest(frozen) == _digest(output)
		# Read-only integrity recheck, never an update or fallback recapture.
		var reread := _read_baseline(baseline_path)
		checks["baseline_unchanged"] = bool(reread.get("ready", false)) and String(reread.get("fileSha256", "")) == baseline_file_sha
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	report["passed"] = checks.values().all(func(value): return bool(value))
	_finish(report, "captured" if capture and report.passed else "exact_parity" if report.passed else "parity_or_roundtrip_failed", 0 if report.passed else 1)


func _add_prototype_frames(blueprint) -> Array:
	var prefixes: Array = []
	for part in blueprint.parts:
		if String(part.semantic) == "citadel_urban_roof" and String(part.id).ends_with("_roof_left"):
			prefixes.append(String(part.id).trim_suffix("_roof_left"))
	var results: Array = []
	# Preserve probe08's source order; do not sort or change RNG/query order.
	for prefix in prefixes:
		results.append(Frame.add_frame(blueprint, [prefix + "_roof_left", prefix + "_roof_right"],
			[prefix + "_upper_shell_side_-1", prefix + "_upper_shell_side_1"], prefix + "_purlin_frame"))
	return results


func _read_baseline(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ready": false, "reason": "missing_baseline"}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ready": false, "reason": "cannot_read_baseline"}
	var envelope = file.get_var(false) # Object deserialization is forbidden.
	var read_error := file.get_error()
	var fully_consumed := file.get_position() == file.get_length()
	file.close()
	if read_error != OK or not fully_consumed or not envelope is Dictionary or not _object_free(envelope):
		return {"ready": false, "reason": "malformed_baseline"}
	if envelope.get("schemaVersion") != 1 or envelope.get("provenance") != "manual_prototype" or not envelope.get("output") is Dictionary:
		return {"ready": false, "reason": "wrong_baseline_schema"}
	var output: Dictionary = envelope.output
	if not OUTPUT_FIELDS.all(func(field): return output.has(field)) or _digest(output.get("fixture")) != _digest(FIXTURE) or String(envelope.get("digest", "")) != _digest(output):
		return {"ready": false, "reason": "baseline_fixture_or_digest_mismatch"}
	if not envelope.get("unframedSource") is Dictionary or String(envelope.get("unframedSourceDigest", "")) != _digest(envelope.unframedSource):
		return {"ready": false, "reason": "baseline_unframed_source_missing_or_corrupt"}
	for field in ["sourceSnapshot", "resolvedSnapshot", "furnitureSnapshot"]:
		if not output[field] is Dictionary or not output[field].get("parts") is Array:
			return {"ready": false, "reason": "invalid_snapshot_shape"}
	if not output.sourceSnapshot.get("rooms") is Array or not output.resolvedSnapshot.get("rooms") is Array or not output.get("physicalValidation") is Dictionary or not output.physicalValidation.get("checks") is Array or not output.get("protectedReservations") is Array:
		return {"ready": false, "reason": "invalid_validation_or_reservation_shape"}
	return {"ready": true, "output": output, "fileSha256": FileAccess.get_sha256(path),
		"unframedSourceDigest": envelope.unframedSourceDigest, "scriptHashes": envelope.get("scriptHashes", {})}


func _indices(output: Dictionary) -> Dictionary:
	return {"sourceParts": _index(output.sourceSnapshot.parts, "id"), "resolvedParts": _index(output.resolvedSnapshot.parts, "id"),
		"sourceRooms": _index(output.sourceSnapshot.rooms, "id"), "resolvedRooms": _index(output.resolvedSnapshot.rooms, "id"),
		"physicalChecks": _index(output.physicalValidation.checks, "partId"), "furnitureParts": _index(output.furnitureSnapshot.parts, "id")}


func _index(records: Array, id_key: String) -> Dictionary:
	var by_id: Dictionary = {}
	var order: Array = []
	var errors: Array = []
	for record in records:
		if not record is Dictionary or not record.get(id_key) is String or String(record[id_key]).is_empty():
			errors.append("invalid_record_id_at_%d" % order.size())
			continue
		var id: String = record[id_key]
		order.append(id)
		if by_id.has(id):
			errors.append("duplicate:" + id)
		by_id[id] = record
	return {"byId": by_id, "order": order, "errors": errors}


func _summary(output: Dictionary, indices: Dictionary) -> Dictionary:
	var result := {"wholeDigest": _digest(output), "sections": {}, "records": {}, "reservationCount": output.protectedReservations.size()}
	for field in OUTPUT_FIELDS:
		result.sections[field] = _digest(output[field])
	for label in indices:
		var index: Dictionary = indices[label]
		result.records[label] = {"count": index.order.size(), "byIdDigest": _digest(index.byId), "orderDigest": _digest(index.order), "idErrors": index.errors}
	return result


func _changed_ids(before: Dictionary, after: Dictionary) -> Dictionary:
	var result := {"removed": [], "added": [], "changed": []}
	for id in before:
		if not after.has(id): result.removed.append(id)
		elif _digest(before[id]) != _digest(after[id]): result.changed.append(id)
	for id in after:
		if not before.has(id): result.added.append(id)
	for values in result.values(): values.sort()
	return result


func _copy_blueprint(source):
	var copy = Blueprint.new(source.id, source.seed, source.style)
	copy.recipe = source.recipe.duplicate(true)
	copy.rooms = source.rooms.duplicate(true)
	for part in source.parts: copy.add_part(part.snapshot())
	return copy


func _object_free(value: Variant) -> bool:
	if typeof(value) in [TYPE_OBJECT, TYPE_RID, TYPE_CALLABLE, TYPE_SIGNAL]: return false
	if value is Dictionary:
		for key in value:
			if not _object_free(key) or not _object_free(value[key]): return false
	elif value is Array:
		for item in value:
			if not _object_free(item): return false
	return true


func _canonical(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort_custom(func(a, b): return var_to_bytes(a).hex_encode() < var_to_bytes(b).hex_encode())
		for key in keys: result[key] = _canonical(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value: result.append(_canonical(item))
		return result
	return value


func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(_canonical(value)))
	return context.finish().hex_encode()


func _script_hashes() -> Dictionary:
	var result: Dictionary = {}
	for name in ["CastleCompoundBlueprintBuilder", "CitadelUrbanPocComposer", "GablePurlinFrameBuilder", "GablePurlinFrameValidator", "BuildingBlueprint", "CastleFurnishingPlanner", "BuildingPartPublisher"]:
		var path := "res://scripts/buildings/%s.gd" % name
		result[path] = FileAccess.get_sha256(path)
	return result # Provenance only, NOT a claim of publication-payload parity.


func _finish(report: Dictionary, status: String, exit_code: int) -> void:
	report["status"] = status
	print("SOURCE/SERVICE roof integration: ", status)
	if _report_path.is_empty():
		quit(2)
		return
	var file := FileAccess.open(_report_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write roof integration JSON report")
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	quit(exit_code)

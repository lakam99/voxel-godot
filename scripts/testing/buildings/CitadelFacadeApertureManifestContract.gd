extends SceneTree
## Source-only manifest contract; no GPU, publication, integration or gameplay acceptance.
const Runtime = preload("res://scripts/testing/buildings/CitadelUrbanPocRunner.gd")
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Declaration = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const MAX_MSEC := 120000
var _worker: Thread
var _path := ""
var _progress := ""
var _artifact := ""
var _started := 0
var _frames := 0
var _progress_ok := true
var _checks: Dictionary = {}
var _report: Dictionary = {"evidenceScope": "source_service_and_named_synthetic_manifest_contract", "doesNotProve": "No GPU, actual publication, visual, integration acceptance, critic approval or gameplay proof."}

func _initialize() -> void: call_deferred("_run")

func _write(path: String, bytes: PackedByteArray) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_buffer(bytes)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_position() == bytes.size()
	file.close()
	return written

func _stage(status: String) -> void:
	_progress_ok = _write(_progress, JSON.stringify({"status": status, "elapsedMsec": Time.get_ticks_msec() - _started, "mainLoopFrames": _frames}).to_utf8_buffer()) and _progress_ok

func _run() -> void:
	_path = OS.get_environment("VOXEL_FACADE_APERTURE_REPORT")
	_progress = _path.get_basename() + "-progress.json"
	_artifact = _path.get_base_dir().path_join("source.bin")
	if not _path.is_absolute_path() or _path.get_extension() != "json" or not DirAccess.dir_exists_absolute(_path.get_base_dir()) or FileAccess.file_exists(_path) or FileAccess.file_exists(_progress) or FileAccess.file_exists(_artifact):
		quit(2)
		return
	_started = Time.get_ticks_msec()
	_stage("read_frozen_whole09")
	var candidate: Dictionary = Plan.read_input("candidate")
	if candidate.is_empty() or not candidate.get("afterSnapshot") is Dictionary or not candidate.get("fixture") is Dictionary:
		_finish("invalid_candidate")
		return
	var frozen: PackedByteArray = var_to_bytes(candidate)
	_checks["fixture208159_scale125"] = candidate.fixture.get("seed") == 208159 and candidate.fixture.get("citadelScale") == 1.25
	_worker = Thread.new()
	if _worker.start(Runtime._generate_citadel.bind(208159, 1.25)) != OK:
		_worker = null
		_finish("worker_start_failed")
		return
	var last_progress: int = _started
	while _worker.is_alive():
		await process_frame
		_frames += 1
		if Time.get_ticks_msec() - last_progress >= 500:
			_stage("deadline_exceeded_awaiting_owned_join" if Time.get_ticks_msec() - _started >= MAX_MSEC else "generating")
			last_progress = Time.get_ticks_msec()
	var prepared: Variant = _worker.wait_to_finish()
	_worker = null
	_checks["owned_worker_joined_with_frames"] = _frames > 0
	_stage("worker_joined")
	if Time.get_ticks_msec() - _started >= MAX_MSEC or not prepared is Dictionary or not prepared.get("ready", false) or prepared.get("blueprint") == null or prepared.get("furnishingPlan") == null:
		_finish("generation_failed_or_deadline")
		return
	var b: Variant = prepared.blueprint
	var furniture: Variant = prepared.furnishingPlan
	var raw: Dictionary = b.snapshot()
	var stripped: Dictionary = raw.duplicate(true)
	_checks["metadata_added_not_preexisting"] = stripped.recipe.has("facadeApertures") and not candidate.afterSnapshot.recipe.has("facadeApertures")
	stripped.recipe.erase("facadeApertures") # The ONLY permitted normalization.
	_checks["all_existing_source_and_recipes_exact"] = var_to_bytes(stripped) == var_to_bytes(candidate.afterSnapshot)
	_checks["4298_parts_152_furnishings"] = b.parts.size() == 4298 and furniture.parts.size() == 152
	_checks["furniture_exact"] = var_to_bytes(furniture.snapshot()) == var_to_bytes(candidate.furnitureSnapshot)
	_checks["reservations_exact"] = var_to_bytes(furniture.protected_access_reservations) == var_to_bytes(candidate.protectedReservations)
	_checks["32_producer_declarations_shared_binding_valid"] = _manifest(raw, b.parts)
	_checks["named_synthetic_original_inputs_full_volumes"] = _synthetic()
	var copy: Variant = Copy.copy_blueprint(raw)
	_checks["snapshot_copy_includes_exact_metadata"] = var_to_bytes(copy.snapshot()) == var_to_bytes(raw)
	if Time.get_ticks_msec() - _started >= MAX_MSEC or not Copy.validation_grid_work(copy).get("ready", false):
		_finish("validation_budget_failed")
		return
	_stage("one_fresh_physical_validation")
	Copy.clear_caches(copy)
	var physical: Dictionary = copy.validate_physical_integrity() # Exactly one fresh validation, on the copy.
	var failed_ids: Array = Copy.failed_ids(physical)
	_checks["170_remaining_gate_false"] = failed_ids.size() == 170 and physical.get("passed") == false
	_checks["raw_source_frozen_input_immutable"] = var_to_bytes(b.snapshot()) == var_to_bytes(raw) and var_to_bytes(candidate) == frozen
	_report["failedIds"] = failed_ids
	var payload: Dictionary = {"fixture": candidate.fixture, "afterSnapshot": raw, "furnitureSnapshot": furniture.snapshot(), "protectedReservations": furniture.protected_access_reservations}
	_finish("checks_complete", payload)

func _finite(box: AABB) -> bool:
	return box.position.is_finite() and box.size.is_finite() and box.end.is_finite() and box.size.x > 0.0 and box.size.y > 0.0 and box.size.z > 0.0

func _manifest(raw: Dictionary, parts: Array) -> bool:
	var declarations: Variant = raw.recipe.get("facadeApertures")
	if not declarations is Dictionary or declarations.size() != 32: return false
	var by_id: Dictionary = {}
	for part: Variant in parts:
		if by_id.has(part.id): return false
		by_id[part.id] = part
	var expected: Dictionary = {}
	for record: Dictionary in raw.parts:
		if record.get("semantic") != "citadel_urban_door" or not String(record.id).ends_with("_door"): continue
		var prefix: String = String(record.id).trim_suffix("_door")
		expected[prefix + "_stone_facade"] = "citadel_urban_stone_base"
		expected[prefix + "_upper_facade"] = "citadel_urban_facade"
	if expected.size() != 32: return false
	for prefix: String in expected:
		var entry: Variant = declarations.get(prefix)
		if not entry is Dictionary or entry.get("producerPrefix") != prefix or entry.get("semantic") != expected[prefix] or not entry.get("wallDomain") is AABB or not entry.get("openings") is Array: return false
		if not Declaration.validate(entry, by_id): return false
		var domain: AABB = entry.wallDomain
		if not _finite(domain) or entry.openings.is_empty() or entry.openings.size() > 128: return false
		for index: int in range(entry.openings.size()):
			var opening: Variant = entry.openings[index]
			if not opening is Dictionary or opening.get("id") != "%s_opening_%03d" % [prefix, index] or not opening.get("input") is Dictionary or not opening.get("fullVolume") is AABB: return false
			var input: Dictionary = opening.input
			for field: String in ["centerY", "centerZ", "height", "width"]:
				if not (input.get(field) is float or input.get(field) is int) or not is_finite(float(input[field])): return false
			var volume: AABB = AABB(Vector3(domain.position.x, float(input.centerY) - float(input.height) * 0.5, float(input.centerZ) - float(input.width) * 0.5), Vector3(domain.size.x, float(input.height), float(input.width)))
			if not _finite(opening.fullVolume) or var_to_bytes(volume) != var_to_bytes(opening.fullVolume): return false
	return true

func _synthetic() -> bool:
	var b: Variant = Blueprint.new()
	var openings: Array[Dictionary] = [{"centerY": 1.0, "height": 4.0, "centerZ": 2.0, "width": 1.5, "extra": {"label": "preserve"}}]
	var original: Dictionary = openings[0].duplicate(true)
	Urban.add_partitioned_street_facade(b, "synthetic", 3.0, 2.0, 6.0, 0.0, 2.0, 0.25, "stone_foundation", 0.0, openings, "synthetic_facade")
	var expected: Dictionary = {"producerPrefix": "synthetic", "semantic": "synthetic_facade", "wallDomain": AABB(Vector3(2.875, 0.0, -1.0), Vector3(0.25, 2.0, 6.0)), "openings": [{"id": "synthetic_opening_000", "input": original, "fullVolume": AABB(Vector3(2.875, -1.0, 1.25), Vector3(0.25, 4.0, 1.5))}]}
	var unchanged: bool = var_to_bytes(openings[0]) == var_to_bytes(original)
	openings[0].extra.label = "mutated_after_call"
	var sealed: Dictionary = b.recipe.facadeApertures.synthetic
	var payload: Dictionary = sealed.duplicate(true)
	payload.erase("partIds")
	payload.erase("sourceBinding") # Actual shared schema: SHA-256 field is sourceBinding.
	var by_id: Dictionary = {}
	var emitted_ids: Array = []
	for part: Variant in b.parts:
		by_id[part.id] = part
		emitted_ids.append(part.id)
	var before: PackedByteArray = var_to_bytes(b.snapshot())
	var valid: bool = Declaration.validate(sealed, by_id)
	_checks["synthetic_seal_lists_actual_partition_parts"] = valid and var_to_bytes(sealed.get("partIds")) == var_to_bytes(emitted_ids)
	var changed_opening: Dictionary = sealed.duplicate(true)
	changed_opening.openings[0].input.width += 0.125
	changed_opening.openings[0].fullVolume.position.z -= 0.0625
	changed_opening.openings[0].fullVolume.size.z += 0.125
	_checks["synthetic_changed_opening_invalid_binding"] = valid and not Declaration.validate(changed_opening, by_id)
	var changed_parts: Dictionary = by_id.duplicate()
	if not emitted_ids.is_empty():
		changed_parts[emitted_ids[0]] = Part.new(by_id[emitted_ids[0]].snapshot())
		changed_parts[emitted_ids[0]].position.x += 0.125
	_checks["synthetic_changed_part_invalid_binding"] = valid and not emitted_ids.is_empty() and not Declaration.validate(sealed, changed_parts)
	_checks["synthetic_binding_inputs_immutable"] = before == var_to_bytes(b.snapshot())
	return unchanged and valid and var_to_bytes(payload) == var_to_bytes(expected)

func _finish(status: String, payload: Dictionary = {}) -> void:
	_stage(status)
	_checks["progress_written"] = _progress_ok
	_checks["bounded_elapsed"] = Time.get_ticks_msec() - _started < MAX_MSEC
	var passed: bool = status == "checks_complete" and not _checks.values().has(false)
	if passed:
		var bytes: PackedByteArray = var_to_bytes(payload)
		var hash: HashingContext = HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(bytes)
		var sha: String = hash.finish().hex_encode()
		_checks["artifact_flush_sha_verified"] = not FileAccess.file_exists(_artifact) and _write(_artifact, bytes) and FileAccess.get_sha256(_artifact) == sha
		_report.merge({"artifactPath": _artifact, "artifactSha256": sha, "artifactBytes": bytes.size()})
		passed = _checks.artifact_flush_sha_verified and Time.get_ticks_msec() - _started < MAX_MSEC
	_report.merge({"passed": passed, "status": status, "checks": _checks, "elapsedMsec": Time.get_ticks_msec() - _started, "workerJoined": _worker == null, "mainLoopFrames": _frames, "candidateBinding": Plan.INPUTS.candidate})
	var written: bool = _write(_path, JSON.stringify(_report, "  ").to_utf8_buffer())
	quit(0 if passed and written else 2)

func _finalize() -> void:
	if _worker != null and _worker.is_started(): _worker.wait_to_finish()

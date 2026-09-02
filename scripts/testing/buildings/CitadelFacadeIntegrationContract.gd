extends SceneTree
## Normal source-service integration only; never publisher/headed/NPC evidence.
const Runtime = preload("res://scripts/testing/buildings/CitadelUrbanPocRunner.gd")
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const Recipe = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const CANDIDATE_SHA := "36ed79a46e014afd35c78fdf54cbbbb88730241165bd72c3c9491c8c7eb4d004"
const MAX_MSEC := 120000
var _worker: Thread
var _path := ""
var _progress_path := ""
var _started := 0
var _frames := 0
var _progress_ok := true
var _timed_out := false
var _checks: Dictionary = {}
var _stages: Array = []
var _report: Dictionary = {"evidenceScope": "normal_generate_citadel_source_service_integration",
	"doesNotProve": "No actual publication, renderer, headed visuals, gameplay or NPC acceptance.",
	"expectedRemainingFailures": 170, "physicalGatePassed": false, "candidateSha256": CANDIDATE_SHA}

func _initialize() -> void: call_deferred("_run")

func _write(path: String, value: Dictionary) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(value, "  "))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	return written

func _stage(name: String) -> void:
	var elapsed: int = Time.get_ticks_msec() - _started
	_stages.append({"stage": name, "elapsedMsec": elapsed})
	_progress_ok = _write(_progress_path, {"status": name, "elapsedMsec": elapsed, "mainLoopFrames": _frames}) and _progress_ok

func _run() -> void:
	_path = OS.get_environment("VOXEL_FACADE_INTEGRATION_REPORT")
	_progress_path = _path.get_basename() + "-progress.json"
	if not _path.is_absolute_path() or _path.get_extension() != "json" or FileAccess.file_exists(_path) or FileAccess.file_exists(_progress_path) or not DirAccess.dir_exists_absolute(_path.get_base_dir()):
		quit(2)
		return
	_started = Time.get_ticks_msec()
	_stage("read_bound_candidate")
	var candidate: Dictionary = Plan.read_input("candidate") # Artifact-only: intentional composer edits are not rejected.
	if candidate.is_empty() or Plan.INPUTS.candidate[1] != CANDIDATE_SHA or not candidate.get("afterSnapshot") is Dictionary or not candidate.get("fixture") is Dictionary:
		_finish("candidate_binding_failed")
		return
	var fixture: Dictionary = candidate.fixture
	if not fixture.get("seed") is int or not fixture.get("citadelScale") is float or not is_finite(fixture.citadelScale) or fixture.citadelScale <= 0:
		_finish("invalid_candidate_fixture")
		return
	_report.merge({"seed": fixture.seed, "scale": fixture.citadelScale, "expectedSourceDigest": Plan.digest(candidate.afterSnapshot)})
	var candidate_digest: String = Plan.digest(candidate)
	_stage("normal_generation_worker")
	_worker = Thread.new()
	if _worker.start(Runtime._generate_citadel.bind(fixture.seed, fixture.citadelScale)) != OK:
		_finish("generation_worker_start_failed")
		return
	var last_progress: int = Time.get_ticks_msec()
	while _worker.is_alive():
		await process_frame
		_frames += 1
		var now: int = Time.get_ticks_msec()
		_timed_out = _timed_out or now - _started >= MAX_MSEC
		if now - last_progress >= 500:
			_progress_ok = _write(_progress_path, {"status": "deadline_exceeded_awaiting_safe_join" if _timed_out else "normal_generation_worker", "elapsedMsec": now - _started, "mainLoopFrames": _frames}) and _progress_ok
			last_progress = now
	var prepared: Variant = _worker.wait_to_finish()
	_worker = null
	_stage("worker_joined")
	_checks["ownedWorkerJoinedWithMainLoopProgress"] = _frames > 0
	if _timed_out:
		_finish("deadline_exceeded_after_safe_join")
		return
	if not prepared is Dictionary or not prepared.get("ready", false) or prepared.get("blueprint") == null or prepared.get("furnishingPlan") == null or not prepared.get("interiorProgram") is Dictionary:
		_finish("normal_generation_not_ready")
		return
	var b = prepared.blueprint
	var furniture = prepared.furnishingPlan
	var raw: Dictionary = b.snapshot()
	var lookup_exact: bool = b.physical_parts_by_id.size() == b.parts.size()
	var seen_ids: Dictionary = {}
	for part in b.parts:
		if part == null:
			lookup_exact = false
			continue
		lookup_exact = lookup_exact and not seen_ids.has(part.id) and is_same(b.physical_parts_by_id.get(part.id), part) and is_same(b.find_part(part.id), part)
		seen_ids[part.id] = true
	_checks["rebuiltLookupEveryGeneratedPartSameObject"] = lookup_exact
	_checks["rawBlueprintExact"] = var_to_bytes(raw) == var_to_bytes(candidate.afterSnapshot)
	_checks["handedFurnitureExact"] = var_to_bytes(furniture.snapshot()) == var_to_bytes(candidate.furnitureSnapshot)
	_checks["handedReservationsExact"] = var_to_bytes(furniture.protected_access_reservations) == var_to_bytes(candidate.protectedReservations)
	_report.merge({"actualSourceDigest": Plan.digest(raw), "sourcePartCount": b.parts.size(), "furnitureCount": furniture.parts.size()})
	var consumer = Runtime.new() # Off-tree adapter: no _ready, publication or scene setup.
	consumer.blueprint = Recipe.copy_blueprint(raw)
	consumer._prepared_furnishing_plan = furniture
	consumer._prepared_interior_program = prepared.interiorProgram.duplicate(true)
	var consumed = consumer.prepare_castle_furnishings()
	_checks["handoffAnnotationExact"] = var_to_bytes(consumer.blueprint.recipe.interiorProgram) == var_to_bytes(prepared.interiorProgram)
	var after_first: PackedByteArray = var_to_bytes(consumer.blueprint.snapshot())
	var consumed_again = consumer.prepare_castle_furnishings()
	_checks["handoffReturnsPreparedObjectIdentity"] = is_same(consumed, furniture)
	_checks["samePlanConsumedExactlyOnce"] = is_same(consumed, furniture) and consumed_again == null and consumer._prepared_furnishing_plan == null
	_checks["repeatHandoffNoSourceMutation"] = after_first == var_to_bytes(consumer.blueprint.snapshot())
	consumer.free()
	var failed_sets: Array = []
	for entry in [{"name": "generated", "snapshot": raw}, {"name": "candidate", "snapshot": candidate.afterSnapshot}]:
		if Time.get_ticks_msec() - _started >= MAX_MSEC:
			_finish("deadline_exceeded_before_validation")
			return
		_stage("independent_physical_" + entry.name)
		var copy = Recipe.copy_blueprint(entry.snapshot)
		_checks[entry.name + "ValidationCopyExact"] = var_to_bytes(copy.snapshot()) == var_to_bytes(entry.snapshot)
		var bounded: Dictionary = Recipe.validation_grid_work(copy)
		if not bounded.get("ready", false):
			_finish("physical_validation_bounds_failed:" + entry.name)
			return
		Recipe.clear_caches(copy)
		var physical: Dictionary = copy.validate_physical_integrity()
		var ids: Array = Recipe.failed_ids(physical)
		ids.sort()
		failed_sets.append(ids)
		_report[entry.name + "FailedIds"] = ids
		_checks[entry.name + "Expected170Remaining"] = ids.size() == 170
		_checks[entry.name + "PhysicalGateStillFalse"] = not bool(physical.get("passed", true))
	_checks["independentFailureIdsExact"] = var_to_bytes(failed_sets[0]) == var_to_bytes(failed_sets[1])
	_checks["rawAndHandedSnapshotsUnchanged"] = var_to_bytes(b.snapshot()) == var_to_bytes(raw) and var_to_bytes(furniture.snapshot()) == var_to_bytes(candidate.furnitureSnapshot) and var_to_bytes(furniture.protected_access_reservations) == var_to_bytes(candidate.protectedReservations)
	_checks["immutableCandidateUnchanged"] = Plan.digest(candidate) == candidate_digest and Plan.digest(Plan.read_input("candidate")) == candidate_digest
	_finish("integration_exact_remaining_gate_false")

func _finish(status: String) -> void:
	_stage(status)
	_checks["boundedElapsed"] = not _timed_out and Time.get_ticks_msec() - _started < MAX_MSEC
	_checks["progressWritten"] = _progress_ok
	var passed: bool = status == "integration_exact_remaining_gate_false" and not _checks.values().has(false)
	_report.merge({"passed": passed, "status": status if passed else "integration_failed:" + status, "checks": _checks,
		"elapsedMsec": Time.get_ticks_msec() - _started, "stages": _stages, "mainLoopFramesDuringWorker": _frames,
		"workerJoined": _worker == null, "wholeGateAccepted": false})
	var written: bool = _write(_path, _report)
	var complete: bool = passed and written and Time.get_ticks_msec() - _started < MAX_MSEC
	print(JSON.stringify({"passed": complete, "status": _report.status, "report": _path}))
	quit(0 if complete else 2)

func _finalize() -> void:
	if _worker != null and _worker.is_started():
		_worker.wait_to_finish()
		_worker = null

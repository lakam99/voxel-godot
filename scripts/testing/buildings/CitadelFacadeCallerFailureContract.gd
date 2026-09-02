extends SceneTree
## Source-service fault injection through the real public composer. No live
## player/publisher admission is exercised. A failed result must expose neither
## blueprint nor prepared furniture; caller-input rollback is NOT promised.
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const Recipe = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
var _worker: Thread
var _frames := 0

func _initialize() -> void: call_deferred("_run")

func _failure_case(candidate: Dictionary) -> Dictionary:
	var fixture: Dictionary = candidate.fixture
	var before = Recipe.copy_blueprint(candidate.beforeSnapshot)
	var membership := Recipe.street_house_memberships(before)
	if not membership.ready: return {"passed": false, "reason": "bound_baseline_membership_invalid"}
	var prefix: String = membership.houses[0].prefix
	var b = Castle.build(fixture.seed, {"biome": fixture.biome, "siteKey": fixture.siteKey, "citadelScale": fixture.citadelScale})
	if b == null: return {"passed": false, "reason": "castle_generation_failed"}
	var original_objects: Array = b.parts.duplicate()
	# Deliberately malformed producer inventory, only in this negative fixture.
	# Finite remote decorations survive ordinary shop planning, then exceed the
	# facade owner's per-house cap. Production receives no fault/bypass flag.
	for index in range(Recipe.MAX_PRODUCER_PARTS + 1):
		b.add_part({"id": prefix + "_synthetic_overflow_%04d" % index, "kind": "decor", "material": "timber_board",
			"position": Vector3(9000 + index, 10, 9000), "size": Vector3(0.1, 0.1, 0.1), "collision": false,
			"semantic": "synthetic_failure_inventory"})
	var result: Dictionary = Urban.compose_prepared(b, fixture.seed)
	var observed := Recipe.street_house_memberships(b)
	var after: Dictionary = {}
	for part in b.parts: after[part.id] = part
	var baseline_exact := true
	for record in candidate.beforeSnapshot.parts:
		if not after.has(record.id) or var_to_bytes(after[record.id].snapshot()) != var_to_bytes(record): baseline_exact = false
	var aliases := true
	# Only retained original castle records are compared; ordinary composition
	# intentionally replaces courtyard records under its existing contract.
	for part in original_objects:
		if after.has(part.id) and not is_same(after[part.id], part): aliases = false
	var added_facade: bool = candidate.partIds.any(func(id): return after.has(id))
	var checks := {
		"realCallerReturnsNotReady": not result.get("ready", true),
		"realCallerExposesNoPartialBlueprintOrFurniture": not result.has("blueprint") and not result.has("furnishingPlan") and not result.has("interiorProgram"),
		"facadeOwnershipLimitActuallyTriggered": not observed.ready and observed.get("reason") == "batch_producer_part_limit",
		"normalShopCompositionReachedExactBaseline": baseline_exact,
		"failedFacadeAddsNoCandidateMembers": not added_facade,
		"retainedCastleRecordIdentitiesPreserved": aliases}
	return {"passed": not checks.values().has(false), "checks": checks, "seed": fixture.seed, "scale": fixture.citadelScale,
		"publicResult": result, "observedFacadeFailure": observed, "injectedInventoryCount": Recipe.MAX_PRODUCER_PARTS + 1,
		"expectedDomainError": "Citadel facade composition failed: batch_producer_part_limit"}

func _run() -> void:
	var path := OS.get_environment("VOXEL_FACADE_CALLER_FAILURE_REPORT")
	var progress := path.get_basename() + "-progress.json"
	if not path.is_absolute_path() or FileAccess.file_exists(path) or FileAccess.file_exists(progress) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var candidate := Plan.read_input("candidate")
	if candidate.is_empty():
		quit(2)
		return
	var started := Time.get_ticks_msec()
	_worker = Thread.new()
	if _worker.start(_failure_case.bind(candidate)) != OK:
		quit(2)
		return
	var next_progress := started
	var progress_ok := true
	while _worker.is_alive():
		await process_frame
		_frames += 1
		if Time.get_ticks_msec() >= next_progress:
			next_progress = Time.get_ticks_msec() + 1000
			progress_ok = _write(progress, {"stage": "real_caller_failure_worker", "elapsedMsec": Time.get_ticks_msec() - started, "mainLoopFrames": _frames}) and progress_ok
	var report: Dictionary = _worker.wait_to_finish()
	_worker = null
	report.merge({"evidence": "fault_injected_source_service_caller_failure_not_live_admission", "elapsedMsec": Time.get_ticks_msec() - started,
		"mainLoopFrames": _frames, "workerJoined": true, "candidateSha256": Plan.INPUTS.candidate[1],
		"doesNotProve": "No whole-composer caller-input rollback, headed loading, live player/publisher admission or gate-zero acceptance."})
	report.passed = report.get("passed", false) and _frames > 0 and progress_ok and report.elapsedMsec < 90000
	var written := _write(path, report)
	_write(progress, {"finished": true, "passed": report.passed})
	print("Facade real-caller failure contract passed=", report.passed)
	quit(0 if report.passed and written else 2)

func _write(path: String, data: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(data, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	return written

func _finalize() -> void:
	if _worker != null and _worker.is_started(): _worker.wait_to_finish()

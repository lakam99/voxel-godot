extends SceneTree

## Exact source/service integration parity; no scene, physics or live acceptance.
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Shops = preload("res://scripts/buildings/CitadelShopRecipe.gd")
const Furniture = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const REVIEW_SHA := "e43b972eface80bbcbc015ef55ac0c21a5cb99083dcfa9aabbb5a407f9832038"
const RAW_SHA := "7d218cb03d293304bb06f2f4dce492db503ff54a8091b525de93563b42549ec5"
const Runtime = preload("res://scripts/testing/buildings/CitadelUrbanPocRunner.gd")
var _late_called := false
var _late_private_changed := false
var _raw_bytes := PackedByteArray()

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_SHOP_INTEGRATION_REPORT")
	var baseline := OS.get_environment("VOXEL_MARKET_REVIEWED_COMPARE")
	var raw_path := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not baseline.is_absolute_path() or FileAccess.get_sha256(baseline) != REVIEW_SHA or FileAccess.get_sha256(raw_path) != RAW_SHA:
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var f := FileAccess.open(baseline, FileAccess.READ)
	var reference: Dictionary = f.get_var(false)
	f.close()
	var fixture: Dictionary = reference.fixture
	var worker_mode := OS.get_environment("VOXEL_SHOP_USE_WORKER") == "1"
	var worker_frames := 0
	var b
	var prepared_plan
	var prepared_program: Dictionary = {}
	if worker_mode:
		var worker := Thread.new()
		if worker.start(Runtime._generate_citadel.bind(fixture.seed, fixture.citadelScale)) != OK:
			quit(2)
			return
		while worker.is_alive():
			await process_frame
			worker_frames += 1
		var prepared: Dictionary = worker.wait_to_finish()
		if not prepared.get("ready", false):
			quit(1)
			return
		b = prepared.blueprint
		prepared_plan = prepared.furnishingPlan
		prepared_program = prepared.interiorProgram.duplicate(true)
	else:
		b = Castle.build(fixture.seed, {"biome": fixture.biome, "siteKey": fixture.siteKey, "citadelScale": fixture.citadelScale})
		if b != null: b = Urban.compose(b, fixture.seed)
	if b == null:
		printerr("Integrated citadel generation failed")
		quit(1)
		return
	var raw_snapshot: Dictionary = b.snapshot()
	var physical: Dictionary = b.validate_physical_integrity()
	var furniture_source = Shops.copy_source(b.snapshot())
	var furniture = Furniture.build(furniture_source, fixture.furnitureSeed)
	if furniture == null:
		quit(1)
		return
	var actual := {"fixture": fixture, "sourceSnapshot": raw_snapshot, "resolvedSnapshot": b.snapshot(),
		"physicalValidation": physical, "furnitureSnapshot": furniture.snapshot(),
		"protectedReservations": furniture.protected_access_reservations.duplicate(true)}
	var checks: Dictionary = {}
	if worker_mode:
		checks["ownedWorkerJoinedWithMainLoopProgress"] = worker_frames > 0
		checks["workerFurnishingPlanExact"] = var_to_bytes(prepared_plan.snapshot()) == var_to_bytes(furniture.snapshot())
		checks["workerAnnotationExact"] = var_to_bytes(prepared_program) == var_to_bytes(furniture_source.recipe.interiorProgram)
		var consumer = Runtime.new()
		consumer.blueprint = Shops.copy_source(b.snapshot())
		consumer._prepared_furnishing_plan = prepared_plan
		consumer._prepared_interior_program = prepared_program.duplicate(true)
		var consumed = consumer.prepare_castle_furnishings()
		checks["furnishingHandoffConsumesSamePlanOnce"] = consumed == prepared_plan and consumer.prepare_castle_furnishings() == null
		checks["annotationAppliedAtFurnishingHandoff"] = var_to_bytes(consumer.blueprint.recipe.interiorProgram) == var_to_bytes(prepared_program)
		consumer.free()
	for key in actual: checks[key + "Exact"] = var_to_bytes(actual[key]) == var_to_bytes(reference[key])
	var obstacles: Dictionary = Shops.furnishing_obstacles(furniture.snapshot(), furniture.protected_access_reservations)
	var before := var_to_bytes(b.snapshot())
	var duplicate: Dictionary = Shops.prepare(b, obstacles.obstacles, Urban.add_market_stall_household, Urban.add_terminal_shop_row, Urban.plan_courtyard_household, Urban.plan_terminal_shop_household)
	checks["duplicateApplicationRejectedWithoutMutation"] = not duplicate.ready and before == var_to_bytes(b.snapshot())
	f = FileAccess.open(raw_path, FileAccess.READ)
	var raw: Dictionary = f.get_var(false).output
	f.close()
	var source = Shops.copy_source(raw.sourceSnapshot)
	_raw_bytes = var_to_bytes(source.snapshot())
	var aliases: Array = source.parts.duplicate()
	var late: Dictionary = Shops.prepare(source, obstacles.obstacles, Urban.add_market_stall_household, Urban.add_terminal_shop_row, Urban.plan_courtyard_household, _fail_late)
	checks["lateFailureActuallyReachedAfterPrivateChanges"] = _late_called and _late_private_changed
	checks["lateFailureNoPartialCommit"] = not late.ready and _raw_bytes == var_to_bytes(source.snapshot()) and aliases == source.parts
	checks["immutableInputsUnchanged"] = FileAccess.get_sha256(baseline) == REVIEW_SHA and FileAccess.get_sha256(raw_path) == RAW_SHA
	var passed := checks.values().all(func(value): return value)
	var report := {"passed": passed, "checks": checks, "violations": physical.violations.size(), "furnitureCount": furniture.parts.size(),
		"lateFailure": late.get("reason", ""), "duplicateFailure": duplicate.get("reason", ""), "elapsedMsec": Time.get_ticks_msec() - started,
		"workerMode": worker_mode, "mainLoopFramesDuringWorker": worker_frames,
		"evidenceLevel": "source_service_integrated_generation_exact_parity",
		"doesNotProve": "No actual publisher primitives, headed images, gameplay, NPC routing, runtime frame timing or whole physical gate acceptance."}
	f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		quit(2)
		return
	f.store_string(JSON.stringify(report, "\t"))
	f.close()
	print("Shop integration parity: %s; physical=%d" % [passed, physical.violations.size()])
	quit(0 if passed else 1)

func _fail_late(private_source, _ids: Array, _front: Vector3, _reservations: Array[Rect2]) -> Dictionary:
	_late_called = true
	_late_private_changed = _raw_bytes != var_to_bytes(private_source.snapshot())
	return {"ready": false, "reason": "injected_terminal_planning_failure"}

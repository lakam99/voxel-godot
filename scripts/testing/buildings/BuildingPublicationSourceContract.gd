extends SceneTree
## Source decoding only. No recipe generation, publisher, scene or gameplay.
const Source = preload("res://scripts/buildings/BuildingPublicationSource.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var worker := Thread.new()
	if worker.start(_work)!=OK: quit(2); return
	while worker.is_alive(): await process_frame
	var result: Dictionary = worker.wait_to_finish()
	result["workerThreadDifferent"] = result.get("threadId") is int and result.threadId!=OS.get_thread_caller_id()
	result.passed = result.get("passed",false) and result.workerThreadDifferent
	var f := FileAccess.open(OS.get_environment("BUILDING_SOURCE_REPORT"),FileAccess.WRITE)
	f.store_string(JSON.stringify(result,"\t")); f.close()
	print("PUBLICATION SOURCE ",JSON.stringify({"passed":result.passed,"checks":result.get("checks",{}).size()}))
	quit(0 if result.passed else 1)

static func _work() -> Dictionary:
	var checks := {}
	if FileAccess.get_sha256(INPUT)!=SHA: return {"passed":false,"reason":"fixture_hash"}
	var f := FileAccess.open(INPUT,FileAccess.READ)
	var fixture: Dictionary = f.get_var(false); f.close()
	var building: Dictionary = fixture.blueprint
	var furniture: Dictionary = fixture.furnishingPlan
	var before := var_to_bytes([building,furniture])
	var started := Time.get_ticks_usec()
	var actual := Source.restore(building,furniture)
	var elapsed := Time.get_ticks_usec()-started
	checks.actual_ready = actual.ready
	checks.actual_input_unchanged = before==var_to_bytes([building,furniture])
	if actual.ready:
		checks.actual_building_exact = var_to_bytes(actual.blueprint.snapshot())==var_to_bytes(building)
		var expected := furniture.duplicate(); expected.erase("accessReservations")
		checks.actual_furnishings_exact = var_to_bytes(actual.furnishingPlan.snapshot())==var_to_bytes(expected)
		checks.actual_reservations_exact = actual.furnishingPlan.access_reservations_snapshot()==furniture.get("accessReservations",[])
		actual.blueprint.recipe["mutation_test"] = true
		checks.actual_output_detached = before==var_to_bytes([building,furniture])
	var b := Blueprint.new("synthetic",7,"timber")
	var part = b.add_part({"id":"thin","kind":"beam","size":Vector3.ONE})
	part.size.y = 0.007
	var p := Plan.new("furnishings",7,"synthetic")
	var furnishing = p.add_part({"id":"thin-furnishing","occupiedSize":Vector3.ONE})
	furnishing.occupied_size.y = 0.009
	p.protected_access_reservations.append(AABB(Vector3.ZERO,Vector3.ONE*2))
	var bs: Dictionary = b.snapshot(); var ps: Dictionary = p.snapshot()
	ps.accessReservations = p.access_reservations_snapshot()
	var thin := Source.restore(bs,ps)
	checks.thin_geometry_exact = thin.ready and thin.blueprint.parts[0].size==part.size and thin.furnishingPlan.parts[0].occupied_size==furnishing.occupied_size
	checks.reservation_does_not_refilter_accepted_furniture = thin.ready and thin.furnishingPlan.parts.size()==1
	var missing_reservations := ps.duplicate()
	missing_reservations.erase("accessReservations")
	checks.missing_reservations_rejected = not Source.restore(bs,missing_reservations).ready
	for stage in ["publication_source_begin","publication_source_building","publication_source_furnishing","publication_source_reservation","publication_source_verify","publication_source_ready"]:
		var result := Source.restore(bs,ps,func(current):return current!=stage)
		checks[stage+"_cancelled_without_output"] = result=={"ready":false,"reason":"cancelled"}
	var invalid := bs.duplicate(true); invalid.parts.append(invalid.parts[0])
	checks.duplicate_ids_rejected = not Source.restore(invalid,ps).ready
	invalid = bs.duplicate(true); invalid.parts[0].size.x = NAN
	checks.nonfinite_rejected = not Source.restore(invalid,ps).ready
	invalid = bs.duplicate(true); invalid.parts[0].id = " normalized "
	checks.constructor_normalization_rejected = Source.restore(invalid,ps).reason=="publication_source_roundtrip_mismatch"
	checks.fixture_hash_preserved = FileAccess.get_sha256(INPUT)==SHA
	return {"passed":false not in checks.values(),"checks":checks,"threadId":OS.get_thread_caller_id(),"actualRestoreUsec":elapsed,
		"actualReason":actual.reason,"buildingParts":building.parts.size(),"furnishings":furniture.parts.size(),"fixtureSha256":SHA,
		"reservationCount":furniture.get("accessReservations",[]).size(),"fixtureKeys":fixture.keys(),
		"evidenceLevel":"actual_source_and_synthetic_decoding_contract","doesNotProve":"No source generation, publication, collision, visual fidelity, streaming, doors or gameplay acceptance. Whole-copy operations run on an owned worker, not a frame-time claim."}

extends SceneTree

const CELL := 1.35
const SEED := "n3-native-projection-contract"

var failures: Array[String] = []

func check(value: bool, label: String) -> void:
	if not value:
		failures.append(label)

func failed(value: Dictionary, reason: String, label: String) -> void:
	check(value.get("status") == "failed", label + " status")
	check(String(value.get("reason", "")).contains(reason), label + " reason: " + String(value.get("reason", "")))

func initialization() -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":SEED,
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
			"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":CELL,"cellCenterOffsetCells":0.5,
			"worldBottomCellY":-64,"waterLevelMeters":11.1,
			"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
			"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func find_ready_page(backend) -> Dictionary:
	for z in range(-12, 13):
		for x in range(-12, 13):
			var key := Vector2i(x, z)
			if backend.shaping_requests(key).get("status") == "ready":
				return {"key":key,"pin":backend.pin_effective_page(key)}
	return {}

func state(cell: Vector3i, solid: bool, material_id: int, fluid_id: int, marker: String) -> Dictionary:
	return {"materialId":material_id,"biomeId":0,"solid":solid,
		"density":1.0 if solid else -0.5,"fluidId":fluid_id,"light":Vector2i(4,9),
		"metadata":{"source":"terrain_edit","terrainMeshAffects":true,
			"marker":marker,"nested":[{"value":17.25}],"padding":"p".repeat(2048)},
		"blockId":"projection_" + marker,"editReason":"projection-contract-" + marker}

func transaction(page: Vector2i) -> Dictionary:
	var x := page.x * 280 + 5
	var z := page.y * 280 + 7
	var operations := []
	for row in [
		[Vector3i(x,10,z),true,3,0,"solid"],
		[Vector3i(x,11,z),false,15,1,"water_air"],
		[Vector3i(x,12,z),false,0,0,"headroom"],
		[Vector3i(x+1,10,z),true,3,0,"known_solid"],
		[Vector3i(x+1,11,z),false,0,0,"known_air"],
		[Vector3i(x+1,12,z),false,0,0,"known_headroom"],
	]:
		operations.append({"namespace":"durable_terrain","kind":"set","cell":row[0],
			"state":state(row[0],row[1],row[2],row[3],row[4])})
	return {"schema":"n3-native-typed-cell-transaction/v1",
		"transactionId":"projection-contract:edit","expectedRevision":0,"operations":operations}

func empty_request() -> Dictionary:
	return {"schema":"n3-effective-terrain-projection-batch-request/v1",
		"surfaceProjections":[],"walkableProjections":[],"knownHeightProjections":[]}

func scan(cell: Vector3i) -> Dictionary:
	return {"startCell":cell,"maxUpCells":1,"maxDownCells":1,
		"intent":"gameplay","semanticRevision":1}

func known(cell: Vector3i) -> Dictionary:
	return {"columnCell":cell,"surfaceY":10.25*CELL,
		"intent":"gameplay","semanticRevision":1}

func repeated(value: Dictionary, count: int) -> Array:
	var values: Array = []
	values.resize(count)
	values.fill(value)
	return values

func valid_identity(value: Variant, label: String) -> void:
	check(value is Dictionary, label + " dictionary")
	if value is Dictionary:
		var digest := String(value.get("hex", ""))
		check(value.get("algorithm") == "sha256" and digest.length() == 64,
			label + " sha256")

func run_contract() -> Dictionary:
	check(ClassDB.class_exists("NativeEffectiveTerrainPage"), "page class exists")
	var uninitialized = ClassDB.instantiate("NativeEffectiveTerrainPage")
	failed(uninitialized.project_surfaces(empty_request()), "page_has_no_pin", "uninitialized")
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "backend exists")
	if backend == null:
		return {}
	check(backend.initialize(initialization()).get("status") == "ready", "initialize")
	var ready := find_ready_page(backend)
	var old_pin: Dictionary = ready.get("pin", {})
	check(old_pin.get("status") == "ready", "old pin ready")
	if old_pin.get("status") != "ready":
		return {}
	var page_key: Vector2i = ready.get("key", Vector2i.ZERO)
	var x := page_key.x * 280 + 5
	var z := page_key.y * 280 + 7
	var old_page = old_pin.page
	var commit: Dictionary = backend.commit_typed_cells(transaction(page_key))
	check(commit.get("status") == "ready" and commit.get("revision") == 1, "commit revision")
	var new_pin: Dictionary = backend.pin_effective_page(page_key)
	var page = new_pin.get("page")
	check(new_pin.get("status") == "ready" and page != null, "new pin ready")
	if page == null:
		return {}
	backend = null
	await process_frame
	var page_status: Dictionary = page.status()
	check(page_status.get("projectionBatchSupported") == true and page_status.get("projectionBatchRequestSchema") == "n3-effective-terrain-projection-batch-request/v1", "page capability")
	check(page_status.get("projectionLimits", {}).get("maxVerticalCandidatesPerQuery") == 512 and page_status.get("projectionLimits", {}).get("knownHeightCandidates") == 3, "page projection limits")

	var request := empty_request()
	var surface := scan(Vector3i(x,10,z))
	var known_query := known(Vector3i(x+1,999,z))
	request.surfaceProjections = [surface, surface]
	request.walkableProjections = [surface, surface]
	request.knownHeightProjections = [known_query, known_query]
	var result: Dictionary = page.project_surfaces(request)
	check(result.get("status") == "ready", "projection ready")
	check(result.get("operation") == "project_surfaces", "operation")
	check(result.get("resultSchema") == "n3-effective-terrain-projection-batch-result/v1", "result schema")
	check(result.get("schemaRevision") == 1, "schema revision")
	check(result.get("primaryPage") == page_key, "primary page")
	check(result.get("terrainDeltaRevision") == 1, "terrain revision")
	check(result.get("admittedVerticalCandidates") == 18, "candidate budget")
	check(result.get("admittedCellReads") == 36, "cell-read budget")
	check(result.get("preparedPayloadBytes", 0) > 0, "payload budget")
	for key in ["sourceIdentity","pinIdentity","shapingRegistryIdentity"]:
		valid_identity(result.get(key), key)
	check(result.surfaceProjections.size() == 2 and result.surfaceProjections[0] == result.surfaceProjections[1], "surface order duplicate")
	check(result.walkableProjections.size() == 2 and result.walkableProjections[0] == result.walkableProjections[1], "walkable order duplicate")
	check(result.knownHeightProjections.size() == 2 and result.knownHeightProjections[0] == result.knownHeightProjections[1], "known order duplicate")
	var projected: Dictionary = result.surfaceProjections[0]
	check(projected.found and projected.solidCell == Vector3i(x,10,z) and projected.airCell == Vector3i(x,11,z), "surface cells")
	check(projected.position == Vector3((float(x)+0.5)*CELL,11.0*CELL,(float(z)+0.5)*CELL), "surface centered position")
	check(projected.solidState.metadata.marker == "solid" and projected.solidState.blockId == "projection_solid" and projected.solidState.editReason == "projection-contract-solid", "full solid state")
	check(projected.airState.fluid == "water" and projected.airState.metadata.marker == "water_air", "full fluid air state")
	var walkable: Dictionary = result.walkableProjections[0]
	check(walkable.walkable and walkable.headroomState.metadata.marker == "headroom", "walkable headroom")
	check(walkable.occupancy.walkableAir and walkable.occupancy.floorSolid and not walkable.occupancy.ceilingSolid, "walkable occupancy")
	check(walkable.occupancy.fluid == "water" and walkable.occupancy.light == {"sky":4,"block":9}, "occupancy fluid/light")
	var known_result: Dictionary = result.knownHeightProjections[0]
	check(known_result.status == "ready" and known_result.reason == "" and known_result.volumeRevision == 1, "known status/revision")
	check(known_result.position == Vector3(float(x+1)*CELL,10.25*CELL,float(z)*CELL), "known corner/exact position")
	check(known_result.requested.columnCell == Vector3i(x+1,999,z), "known caller column retained")

	var old_request := empty_request()
	old_request.surfaceProjections = [surface]
	var old_result: Dictionary = old_page.project_surfaces(old_request)
	check(old_result.get("status") == "ready" and old_result.terrainDeltaRevision == 0, "old pin immutable revision")
	check(old_result.pinIdentity != result.pinIdentity and old_result.sourceIdentity == result.sourceIdentity, "identity/revision split")
	var no_result_request := empty_request()
	no_result_request.surfaceProjections = [scan(Vector3i(x,-1000,z))]
	var no_result: Dictionary = page.project_surfaces(no_result_request)
	check(no_result.get("status") == "ready" and no_result.surfaceProjections.size() == 1, "no-result projection ready")
	check(not no_result.surfaceProjections[0].found and no_result.surfaceProjections[0].columnCell == Vector3i(x,-1000,z), "no-result identity")
	check(no_result.surfaceProjections[0].solidState == null and no_result.surfaceProjections[0].airState == null, "no-result null states")

	var invalid := empty_request()
	invalid.schema = "n3-effective-terrain-projection-batch-request/v999"
	failed(page.project_surfaces(invalid), "unsupported", "schema revision")
	invalid = empty_request()
	invalid.surfaceProjections = {}
	failed(page.project_surfaces(invalid), "Array", "channel schema type")
	invalid = empty_request()
	invalid["extra"] = true
	failed(page.project_surfaces(invalid), "unsupported field set", "top-level exact keys")
	invalid = empty_request()
	invalid.surfaceProjections = [{"startCell":Vector3i(x,10,z),"maxUpCells":1,
		"maxDownCells":1,"intent":"gameplay","semanticRevision":1,"extra":true}]
	failed(page.project_surfaces(invalid), "unsupported field set", "nested exact keys")
	invalid = empty_request()
	invalid.walkableProjections = [{"startCell":"bad","maxUpCells":1,
		"maxDownCells":1,"intent":"gameplay","semanticRevision":1}]
	failed(page.project_surfaces(invalid), "Vector3i", "nested type")
	invalid = empty_request()
	invalid.surfaceProjections = [{"startCell":Vector3i(x,10,z),"maxUpCells":1,
		"maxDownCells":1,"intent":"gameplay","semanticRevision":2}]
	failed(page.project_surfaces(invalid), "query is invalid", "nested semantic revision")
	invalid = empty_request()
	invalid.knownHeightProjections = [{"columnCell":Vector3i(x,10,z),"surfaceY":NAN,
		"intent":"gameplay","semanticRevision":1}]
	failed(page.project_surfaces(invalid), "finite", "nonfinite height")
	invalid = empty_request()
	invalid.surfaceProjections = repeated(surface, 4097)
	failed(page.project_surfaces(invalid), "projection adapter query limit exceeded",
		"surface channel cap")
	check(page.project_surfaces(request) == result, "recovery after channel cap")
	invalid = empty_request()
	invalid.surfaceProjections = repeated(surface, 2049)
	invalid.walkableProjections = repeated(surface, 2048)
	failed(page.project_surfaces(invalid), "projection adapter query limit exceeded",
		"aggregate query cap")
	check(page.project_surfaces(request) == result, "recovery after aggregate cap")
	var broad_scan := {"startCell":Vector3i(x,10,z),"maxUpCells":512,
		"maxDownCells":512,"intent":"gameplay","semanticRevision":1}
	invalid = empty_request()
	invalid.surfaceProjections = repeated(broad_scan, 4096)
	failed(page.project_surfaces(invalid), "projection total vertical limit",
		"vertical cap")
	check(page.project_surfaces(request) == result, "recovery after vertical cap")
	var read_scan := {"startCell":Vector3i(x,10,z),"maxUpCells":8,
		"maxDownCells":7,"intent":"gameplay","semanticRevision":1}
	invalid = empty_request()
	invalid.walkableProjections = repeated(read_scan, 4096)
	failed(page.project_surfaces(invalid), "projection total cell-read limit",
		"cell-read cap")
	check(page.project_surfaces(request) == result, "recovery after cell-read cap")
	invalid = empty_request()
	invalid.knownHeightProjections = repeated(known_query, 4096)
	failed(page.project_surfaces(invalid), "projection payload limit",
		"known-height payload cap")
	check(page.project_surfaces(request) == result, "recovery after payload cap")
	invalid = empty_request()
	invalid.surfaceProjections = [surface, {"startCell":Vector3i(1000000,10,1000000),
		"maxUpCells":1,"maxDownCells":1,"intent":"gameplay","semanticRevision":1}]
	failed(page.project_surfaces(invalid), "outside the primary page", "mixed atomic rejection")
	check(page.project_surfaces(request) == result, "valid result stable after failures")
	return {"page":page_key,"revision":result.terrainDeltaRevision,
		"pinIdentity":result.pinIdentity,"candidateBudget":result.admittedVerticalCandidates,
		"cellReadBudget":result.admittedCellReads,"payloadBytes":result.preparedPayloadBytes,
		"staleCommentParity":"three_candidates_range_probe_y_to_probe_y_minus_3_exclusive"}

func _initialize() -> void:
	var details := await run_contract()
	var report := {"schema":"n3-native-terrain-projection-contract/v1",
		"passed":failures.is_empty(),"failures":failures,"details":details,
		"productionCutover":false,
		"proves":["native projection adapter schema/order/revision/identity",
			"full effective states, fluid-preserving walkability, admitted candidate/cell-read budgets",
			"adapter preallocation channel/aggregate rejection plus vertical/read/payload rejection and recovery",
			"atomic malformed/mixed-query rejection and immutable pin behavior"],
		"doesNotProve":["production WorldGenerationSystem activation",
			"live navigation, collision publication, or gameplay acceptance"]}
	var path := OS.get_environment("VWB_TERRAIN_PROJECTION_REPORT")
	if path.is_empty():
		path = "res://artifacts/native-world-backend/n3-native-terrain-projection-contract.json"
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	if failures.is_empty():
		print("N3_NATIVE_TERRAIN_PROJECTION_CONTRACT_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

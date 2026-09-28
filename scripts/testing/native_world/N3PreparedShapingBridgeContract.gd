extends SceneTree

# Synthetic prepared receipt at the production admission boundary. This checks
# bridge identity and native registry plumbing, not Citadel recipe construction.
const Bridge = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const SEED := "atlas-1492"
const SIGNATURE := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
var failures: Array[String] = []
var observations := {}

func _init() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if not ok: failures.append(label)

func initialization() -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":SEED,
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,"worldBottomCellY":-64,"waterLevelMeters":11.1,"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func profile_for(candidate: Dictionary) -> Dictionary:
	var center: Vector2i = candidate.centerCell
	var envelope := Rect2i(center - Vector2i(2, 2), Vector2i(5, 5))
	var support := [0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0]
	var distances := []
	distances.resize(25)
	distances.fill(1.0)
	distances[12] = 0.0
	var root := Vector3(center.x * 1.35, 12.0, center.y * 1.35)
	var roots := [root, root, root, root]
	support.make_read_only()
	distances.make_read_only()
	roots.make_read_only()
	var profile := {"version":1,"worldSeed":SEED,"siteId":candidate.siteId,"sourceSignature":SIGNATURE,
		"cellSize":1.35,"coreCells":envelope.grow(-1),"envelopeCells":envelope,
		"reservationCells":Rect2i(center - Vector2i.ONE,Vector2i(3,3)),
		"origin":roots[0],"level":12.0,"apronCells":1,
		"supportMask":support,"distanceCells":distances,"groundRootPoints":roots}
	profile.make_read_only()
	return profile

func setup_case(mismatch: bool) -> Dictionary:
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "native_backend_available")
	if backend == null: return {}
	check(backend.initialize(initialization()).get("status") == "ready", "native_initialized")
	var admission = Admission.new()
	admission.configure(SEED, {}, {"regionCells":140,"spawnChance":0.08})
	check(admission.finalize_town_inputs({}).get("status") == "ready", "admission_finalized")
	var page := Vector2i.ZERO
	var requests: Array = []
	for z in range(-3, 4):
		for x in range(-3, 4):
			var trial := Vector2i(x,z)
			var readiness: Dictionary = backend.shaping_requests(trial)
			if readiness.get("status") == "pending" and not (readiness.get("requests",[]) as Array).is_empty():
				page = trial
				requests = readiness.requests
				break
		if not requests.is_empty(): break
	check(not requests.is_empty(), "pending_request_found")
	if requests.is_empty(): return {}
	var target: Dictionary = requests[0]
	var region: Vector2i = target.region
	var candidate: Dictionary = Field.candidate_for_region(SEED,region)
	check(candidate.get("siteId") == target.get("siteId") and candidate.get("centerCell") == target.get("centerCell") and candidate.get("recipeSeed") == target.get("recipeSeed"), "canonical_candidate_identity")
	var profile: Dictionary = profile_for(candidate)
	check(admission.profile_store.append_prepared_profile(profile), "profile_store_admitted")
	admission._decisions[region] = {"status":"prepared","reason":"","sourceKey":"synthetic-contract",
		"sourceSignature": "b".repeat(64) if mismatch else SIGNATURE,
		"siteId":candidate.siteId,"reservationCells":profile.envelopeCells.grow(1).merge(profile.reservationCells),
		"level":profile.level,"envelopeCells":profile.envelopeCells,"apronCells":profile.apronCells}
	admission._sources[region] = {"contractPrepared":true}
	for request in requests.slice(1):
		admission._decisions[request.region] = {"status":"absent","reason":"contract_other_region"}
	var bridge = Bridge.new()
	check(bridge.setup(backend,admission).get("status") == "ready", "bridge_configured")
	return {"backend":backend,"admission":admission,"bridge":bridge,"page":page,"request":target,"candidate":candidate}

func run() -> void:
	var positive := setup_case(false)
	if not positive.is_empty():
		var result: Dictionary = positive.bridge.request_page(positive.page)
		observations.positive = {"result":result,"native":positive.backend.shaping_requests(positive.page).get("status"),"region":positive.request.region}
		check(result.get("status") == "ready", "prepared_bridge_page_ready")
		check(positive.backend.shaping_requests(positive.page).get("status") == "ready", "native_registry_prepared_ready")
		check(positive.bridge.request_page(positive.page).get("status") == "ready", "prepared_replay_ready")
	var negative := setup_case(true)
	if not negative.is_empty():
		var rejected: Dictionary = negative.bridge.request_page(negative.page)
		observations.negative = {"status":rejected.get("status"),"reason":rejected.get("reason"),"native":negative.backend.shaping_requests(negative.page).get("status")}
		check(rejected.get("status") == "failed" and rejected.get("reason") == "prepared_source_profile_mismatch", "signature_mismatch_rejected")
		check(negative.backend.shaping_requests(negative.page).get("status") == "pending", "signature_mismatch_not_published")
	var report := {"schema":"n3-prepared-shaping-bridge-contract/v1","passed":failures.is_empty(),
		"evidenceLevel":"synthetic-prepared-admission-real-native-registry","productionCutover":false,
		"failures":failures,"observations":observations}
	var path := OS.get_environment("VWB_PREPARED_BRIDGE_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path,FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report,"\t"))
	quit(0 if report.passed else 1)

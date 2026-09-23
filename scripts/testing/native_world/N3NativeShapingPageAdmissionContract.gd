extends SceneTree

const Bridge = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const SEED := "atlas-1492"
var failures: Array[String] = []
var observations := {}

func _init() -> void:
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)

func run() -> void:
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "backend_class_available")
	if backend == null:
		finish()
		return
	var initialized: Dictionary = backend.initialize({
		"schema":"n3-native-world-backend-initialize/v1", "seedText":SEED,
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
			"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,
			"worldBottomCellY":-64,"waterLevelMeters":11.1,
			"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
			"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}})
	check(initialized.get("status") == "ready", "backend_initialized")
	var admission = Admission.new()
	admission.configure(SEED, {}, {"regionCells":140,"spawnChance":0.08})
	check(admission.finalize_town_inputs({}).get("status") == "ready", "real_admission_finalized")
	var bridge = Bridge.new()
	check(bridge.setup(backend, admission).get("status") == "ready", "bridge_configured")
	var page := Vector2i.ZERO
	for z in range(-3, 4):
		for x in range(-3, 4):
			var candidate_page := Vector2i(x, z)
			if backend.shaping_requests(candidate_page).get("status") == "pending":
				page = candidate_page
				break
		if backend.shaping_requests(page).get("status") == "pending":
			break
	var before: Dictionary = backend.shaping_requests(page)
	check(before.get("status") == "pending", "pending_page_found")
	observations.page = page
	observations.before = before.get("status")
	var first: Dictionary = bridge.request_page(page)
	observations.first = first
	check(first.get("status") != "failed", "first_page_request_valid")
	if before.get("status") == "pending":
		check(first.get("status") == "pending", "unresolved_source_retained")
		check(backend.shaping_requests(page).get("status") == "pending", "no_synthetic_absence")
	var second: Dictionary = bridge.request_page(page)
	observations.second = second
	check(second.get("status") == "pending", "repeated_pending_retained")
	check(backend.shaping_requests(page).get("status") == "pending", "native_bridge_agreement")
	var ready_page := Vector2i.ZERO
	var ready: Dictionary = bridge.request_page(ready_page)
	observations.ready = ready.get("status")
	check(ready.get("status") == "ready", "already_ready_page_preserved")
	if OS.get_environment("VWB_SHAPING_ADVANCE") == "1":
		var deadline := Time.get_ticks_msec() + 30000
		var final: Dictionary = {}
		while Time.get_ticks_msec() < deadline:
			admission.advance()
			final = bridge.request_page(page)
			if final.get("status") in ["ready", "failed"]:
				break
			await process_frame
		observations.completion = final
		check(final.get("status") == "ready", "real_site_source_reaches_native_page_ready")
		admission.request_shutdown()
		var drain_deadline := Time.get_ticks_msec() + 8000
		while Time.get_ticks_msec() < drain_deadline:
			if admission.advance().get("shutdownComplete", false):
				break
			await process_frame
		check(admission.stats().get("shutdownComplete", false), "source_worker_drained")
	finish()

func finish() -> void:
	var report := {"schema":"n3-native-shaping-page-admission-contract/v1",
		"passed":failures.is_empty(),"evidenceLevel":"real-admission-shadow-contract",
		"productionCutover":false,"failures":failures,"observations":observations}
	var path := OS.get_environment("VWB_SHAPING_BRIDGE_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)

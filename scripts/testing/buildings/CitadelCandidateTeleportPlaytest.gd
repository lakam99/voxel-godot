extends SceneTree
## Headed teleport-assisted diagnostic, never continuous-travel/NPC acceptance.
## Two bounded setup placements are supported; all generated content is ordinary.
const MainScene = preload("res://scenes/Main.tscn")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Gate = preload("res://scripts/terrain/VoxelTerrainSiteGate.gd")
const Clearance = preload("res://scripts/world/GeneratedStructurePlayerClearance.gd")
const RenderObservation = preload("res://scripts/perf/RuntimeRenderObservation.gd")
const Streaming = preload("res://scripts/world/WorldStreamingCoordinator.gd")
const SEARCH_RING := 2
const VIEW_CELLS := 112
const MAX_SETUP_WRITES := 2

class SeededMain extends "res://scripts/Main.gd":
	# The title UI has no seed entry. Seed and optional initial cell are fixture-owned:
	# actual New Game, tutorial, systems, terrain and observer startup are inherited.
	var diagnostic_seed := "atlas-30895044"
	var diagnostic_spawn_cell := ""
	var diagnostic_spawn_evidence: Dictionary = {}
	var diagnostic_setup_spans: Array[Dictionary] = []
	func _record_setup_span(label: String, before: int) -> void:
		var after := Time.get_ticks_usec()
		if diagnostic_setup_spans.size() < 32:
			diagnostic_setup_spans.append({"stage":label,"startUsec":before,"endUsec":after,
				"durationMs":float(after-before)/1000.0})
	# Observe inherited synchronous setup without yielding or replacing its work.
	func setup_audio_effects() -> void:
		var before := Time.get_ticks_usec()
		super.setup_audio_effects()
		_record_setup_span("audio",before)
	func setup_tutorial_system() -> void:
		var before := Time.get_ticks_usec()
		super.setup_tutorial_system()
		_record_setup_span("tutorial",before)
	func setup_player() -> void:
		var before := Time.get_ticks_usec()
		super.setup_player()
		_record_setup_span("player",before)
	func setup_hostiles() -> void:
		var before := Time.get_ticks_usec()
		super.setup_hostiles()
		_record_setup_span("hostiles",before)
	func setup_npc_system() -> void:
		var before := Time.get_ticks_usec()
		super.setup_npc_system()
		_record_setup_span("npcs",before)
	func setup_held_item() -> void:
		var before := Time.get_ticks_usec()
		super.setup_held_item()
		_record_setup_span("held_item",before)
	func setup_hud() -> void:
		var before := Time.get_ticks_usec()
		super.setup_hud()
		_record_setup_span("hud",before)
	func random_world_seed(_exclude_seed := "") -> String:
		return diagnostic_seed
	func find_spawn_position() -> Vector3:
		if diagnostic_spawn_cell.is_empty(): return super.find_spawn_position()
		var coordinates := diagnostic_spawn_cell.split(",")
		var cell := Vector3i(int(coordinates[0]),0,int(coordinates[1]))
		var position := Vector3(cell.x*CELL,surface_y_at_cell(cell)+5.0,cell.z*CELL)
		diagnostic_spawn_evidence = {"requestedCell":diagnostic_spawn_cell,"position":position,
			"beforePlayerAttachment":not player.is_inside_tree(),"beforeTerrainRuntime":voxel_terrain_runtime==null,
			"selectionMsec":Time.get_ticks_msec(),"heightPolicy":"ordinary authoritative surface plus standard five-metre spawn offset"}
		return position

var main
var player: CharacterBody3D
var output := ""
var requested_seed := "atlas-30895044"
var requested_region := ""
var spawn_cell := ""
var started := 0
var deadline := 0
var startup_elapsed := 0
var test_started := 0
var startup_ready := false
var startup_failure := ""
var render_observation
var phase := "initializing":
	set(value):
		phase = value
		if is_instance_valid(render_observation): render_observation.phase = value
var candidate: Dictionary = {}
var region := Vector2i.ZERO
var declared := Rect2i()
var reservation := Rect2i()
var search: Dictionary = {}
var placements: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var timeline_dropped := 0
var startup_messages: Array[Dictionary] = []
var startup_message_index: Dictionary = {}
var startup_message_count := 0
var startup_message_overflow := 0
var checks: Dictionary = {}
var evidence: Dictionary = {}
var next_progress := 0
var last_observation: Dictionary = {}
var source_binding: Dictionary = {}
var source_signature := ""
var original_position := Vector3.ZERO
var finished := false
var manual_seconds := 0
var last_timeline_state := ""
var evidence_error: Dictionary = {}
var accepted_owners: Dictionary = {} # Weak identity pins, never scene ownership.
var worker_samples: Array[Dictionary] = []
var worker_samples_dropped := 0
var navigation_demand_samples: Array[Dictionary] = []
var navigation_demand_samples_dropped := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	output = OS.get_environment("CITADEL_CANDIDATE_TELEPORT_OUTPUT")
	var selected := OS.get_environment("CITADEL_CANDIDATE_TELEPORT_SEED").strip_edges()
	if not selected.is_empty(): requested_seed = selected
	requested_region = OS.get_environment("CITADEL_CANDIDATE_TELEPORT_REGION")
	spawn_cell = OS.get_environment("CITADEL_CANDIDATE_SPAWN_CELL")
	if not spawn_cell.is_empty() and (not valid_region_request(spawn_cell) or requested_region.is_empty()):
		printerr("Invalid initial spawn request"); quit(2); return
	if not valid_region_request(requested_region):
		printerr("Invalid diagnostic candidate region"); quit(2); return
	var limit := int(OS.get_environment("CITADEL_CANDIDATE_TELEPORT_SECONDS"))
	var startup_limit := int(OS.get_environment("CITADEL_CANDIDATE_STARTUP_SECONDS"))
	manual_seconds=int(OS.get_environment("CITADEL_CANDIDATE_MANUAL_SECONDS"))
	if manual_seconds not in [0,1800]:
		printerr("Invalid manual inspection allowance"); quit(2); return
	if output.is_empty() or not output.is_absolute_path() or limit < 90 or limit > 600 or startup_limit < 15 or startup_limit > 180:
		printerr("Missing/invalid owned runner output or deadline"); quit(2); return
	started = Time.get_ticks_msec()
	deadline = started + startup_limit*1000
	if DisplayServer.get_name() == "headless":
		await _finish("failed", "headed_renderer_required"); return
	var resolution := OS.get_environment("CITADEL_CANDIDATE_RESOLUTION")
	if resolution.is_empty(): resolution = "1280x720"
	if resolution not in ["1280x720", "1920x1080"]:
		printerr("Invalid diagnostic resolution"); quit(2); return
	var dimensions := resolution.split("x")
	root.size = Vector2i(int(dimensions[0]),int(dimensions[1]))
	render_observation = RenderObservation.new()
	root.add_child(render_observation)
	checks.render_observation_started = render_observation.start(root)
	main = MainScene.instantiate() as Node3D
	main.set_script(SeededMain)
	evidence.seedSelection = {"mechanism":"fixture-only script replacement with subclass overriding random_world_seed",
		"originalScript":"res://scripts/Main.gd","inheritedStartupMode":"new_game","requestedSeed":requested_seed,
		"excludeSeedDeliberatelyIgnored":true,"voxelTestSeedEnvironmentUsed":false,"globalRngSeedOverride":false,
		"notEquivalentToExistingTestSeedMode":"VOXEL_TEST_SEED also seeds the global RNG; deterministic sequence additionally requires a test/performance token. Neither mechanism is enabled here."}
	main.set("diagnostic_seed",requested_seed)
	main.set("diagnostic_spawn_cell",spawn_cell)
	main.set("startup_mode","new_game")
	main.connect("startup_loading_completed",_startup_completed)
	main.connect("startup_loading_failed",_startup_failed)
	main.connect("startup_loading_step",_startup_step)
	root.add_child(main)
	current_scene = main
	phase = "ordinary_new_game_startup"
	while not startup_ready and startup_failure.is_empty() and _within_deadline():
		await _frame()
	checks.startup_completed = startup_ready and startup_failure.is_empty()
	if not checks.startup_completed:
		await _finish("failed",startup_failure if not startup_failure.is_empty() else "startup_timeout"); return
	startup_elapsed = _elapsed()
	test_started = Time.get_ticks_msec()
	deadline = test_started + (limit-45)*1000 # Separate test clock; reserve ordinary shutdown.
	evidence.launchOptions=main.launch_options.duplicate()
	checks.tutorial_skip_applied=not main.launch_options.skipTutorial or not bool(main.tutorial_system.started)
	evidence.launchEnvironment={"clockPhase":main.clock_phase(),"weather":main.weather_system.snapshot()}
	checks.forced_daytime_applied=not main.launch_options.forceDaytime or is_equal_approx(main.clock_phase(),0.5)
	checks.forced_clear_weather_applied=not main.launch_options.forceClearWeather or (main.weather_system.kind=="clear" and is_zero_approx(main.weather_system.intensity))
	checks.no_daytime_stars=not main.launch_options.forceDaytime or not bool(main.weather_system.snapshot().get("starsVisible",false))
	if not checks.tutorial_skip_applied or not checks.forced_daytime_applied or not checks.forced_clear_weather_applied or not checks.no_daytime_stars:
		await _finish("failed","launch_options_not_applied"); return
	checks.exact_seed = String(main.get("seed_text")) == requested_seed
	var domains: Dictionary = main.get("startup_readiness_domains")
	checks.startup_gameplay_domain_ready = domains.get("gameplay",{}).get("status") == "ready"
	evidence.startupReadiness = domains.duplicate(true)
	player = main.get("player") as CharacterBody3D
	if not checks.exact_seed or not checks.startup_gameplay_domain_ready or not is_instance_valid(player):
		await _finish("failed","startup_identity_or_readiness_mismatch"); return
	if not spawn_cell.is_empty():
		var initial_readiness := _initial_spawn_physical_readiness()
		evidence.initialSpawnPhysicalReadiness = initial_readiness
		checks.initial_spawn_physical_publication_ready = initial_readiness.get("status")=="ready"
		checks.initial_spawn_does_not_require_citadel_scene = not bool(initial_readiness.get("required",true))
		if not checks.initial_spawn_physical_publication_ready:
			await _finish("failed",String(initial_readiness.get("reason","initial_spawn_physical_publication_pending"))); return
		if not checks.initial_spawn_does_not_require_citadel_scene:
			await _finish("failed","initial_spawn_unexpectedly_requires_citadel_scene"); return
	checks.runtime_owners_available = main.structure_system.citadel_runtime_bindings != null and main.structure_system.citadel_runtime_bindings.available()
	if not checks.runtime_owners_available:
		await _finish("failed","ordinary_runtime_owners_missing"); return
	original_position = player.global_position
	if not spawn_cell.is_empty():
		evidence.initialSpawn = main.diagnostic_spawn_evidence.duplicate(true)
		checks.initial_spawn_selected_before_attachment = evidence.initialSpawn.get("beforePlayerAttachment",false) and evidence.initialSpawn.get("beforeTerrainRuntime",false)
		checks.initial_spawn_tutorial_disabled = main.launch_options.skipTutorial
		var selected_position: Vector3 = evidence.initialSpawn.get("position",Vector3.INF)
		checks.initial_spawn_horizontal_position_preserved = Vector2(original_position.x,original_position.z).distance_to(Vector2(selected_position.x,selected_position.z))<0.1
		if not checks.initial_spawn_selected_before_attachment or not checks.initial_spawn_tutorial_disabled or not checks.initial_spawn_horizontal_position_preserved:
			await _finish("failed","initial_spawn_contract_failed"); return
	if not await _capture("preteleport" if spawn_cell.is_empty() else "initial_spawn_ready"):
		await _finish("failed","preteleport_capture_failed"); return
	search = _nearest_candidate(original_position)
	candidate = search.get("selected",{})
	if candidate.is_empty():
		await _finish("absent","no_candidate_in_bounded_ring" if requested_region.is_empty() else "requested_candidate_not_in_bounded_field"); return
	region = candidate.region
	declared = Admission.declared_influence(candidate)
	if spawn_cell.is_empty() and main.has_method("show_streaming_loading_overlay"):
		main.show_streaming_loading_overlay("Preparing Citadel region…","citadel_fixture")
	if spawn_cell.is_empty() and not _place_outside(declared,"declared_influence_exterior"):
		await _finish("failed","initial_staging_invalid"); return
	if not await _capture("pending"):
		await _finish("failed","pending_capture_failed"); return
	phase = "ordinary_source_discovery"
	while _within_deadline():
		await _frame()
		var source := _source_summary()
		if source.get("status") in ["failed","absent"]:
			await _finish(String(source.status),String(source.get("reason","source_rejected"))); return
		if source.get("status") in ["ready","prepared"]:
			reservation = source.reservationCells
			source_binding = source.binding.duplicate()
			source_signature = source.sourceSignature
			break
	if reservation.size.x <= 0 or reservation.size.y <= 0:
		await _finish("timeout","ordinary_source_not_accepted"); return
	if not _pin_accepted_owners():
		await _finish("failed","accepted_source_owners_missing"); return
	checks.accepted_reservation_within_declared = declared.encloses(reservation)
	checks.initial_capsule_outside_accepted_reservation = _outside(reservation)
	if not checks.accepted_reservation_within_declared or not checks.initial_capsule_outside_accepted_reservation:
		await _finish("failed","accepted_reservation_boundary_mismatch"); return
	# No long scripted walk or source prewarm. The second explicitly reported
	# setup placement is derived ONLY from the now accepted production manifest.
	if spawn_cell.is_empty() and not _place_outside(reservation,"accepted_reservation_exterior"):
		await _finish("failed","accepted_staging_invalid"); return
	if not await _capture("pending_publication"):
		await _finish("failed","publication_capture_failed"); return
	phase = "native_collision_and_capsule_clearance"
	var clear_frames := 0
	var clearance: Dictionary = {}
	var mesh: Dictionary = {}
	var support: Dictionary = {}
	var clearance_failure := ""
	while _within_deadline():
		await physics_frame
		await _frame()
		# Rejection/identity checks precede the successful-clearance exit. A stale
		# collision observation cannot authorize physics against another source.
		var identity := _accepted_current()
		if not identity.passed:
			clearance_failure=String(identity.reason)
			clear_frames=0
			break
		var runtime = main.get("voxel_terrain_runtime")
		mesh = runtime.collision_mesh_ready_for_body_position(player.global_position,_capsule_radius())
		support = runtime.collision_proof_for_world_position(player.global_position,_capsule_radius())
		clearance = Clearance.inspect(player)
		var valid: bool = runtime.generation_context_current() and mesh.get("passed",false) and support.get("passed",false) and clearance.get("passed",false) and _outside(reservation)
		clear_frames = clear_frames+1 if valid else 0
		if clear_frames >= 2: break
	evidence.setupClearance = {"freshPhysicsFrames":clear_frames,"mesh":mesh,"support":support,"capsule":clearance}
	checks.setup_clearance_before_resume = clear_frames >= 2
	if not checks.setup_clearance_before_resume:
		await _finish("failed",clearance_failure if not clearance_failure.is_empty() else "staging_collision_or_capsule_clearance_unresolved"); return
	var resume_identity := _accepted_current()
	evidence.beforePhysicsResume = resume_identity
	checks.accepted_identity_before_resume = resume_identity.passed and _outside(reservation)
	if not checks.accepted_identity_before_resume:
		await _finish("failed",String(resume_identity.reason) if not resume_identity.passed else "capsule_not_outside_before_resume"); return
	player.set_physics_process(true)
	evidence.physicsResumedMsec = _elapsed()
	# Packet-mode scenes deliberately retain no physical packet while the current
	# playable window has no citadel group.  Advance through the ordinary player
	# input path until that window first reaches the source, but never cross the
	# accepted reservation to make a scene appear.  This keeps the diagnostic on
	# the same streaming demand path as a player approaching the citadel.
	evidence.prePublicationApproach = await _approach_until_scene_publication()
	checks.no_modal_loading_during_publication_approach = int(evidence.prePublicationApproach.get("modalLoadingVisibleFrames",-1))==0
	checks.pre_publication_approach = evidence.prePublicationApproach.get("passed",false)
	if not checks.pre_publication_approach:
		await _finish("failed",String(evidence.prePublicationApproach.get("reason","publication_demand_not_reached"))); return
	phase = "ordinary_scene_publication"
	while _within_deadline():
		await _frame()
		if not _outside(reservation):
			await _finish("failed","player_entered_reservation_before_scene_ready"); return
		var observed := _observe()
		var scene: Dictionary = observed.get("scene",{})
		var source: Dictionary = observed.get("source",{})
		if source.get("status") in ["failed","absent"]:
			await _finish(String(source.status),String(source.get("reason","source_rejected"))); return
		if scene.get("status") == "failed":
			await _finish("failed",String(scene.get("reason","publication_failed"))); return
		if scene.get("status") == "scene_ready":
			checks.scene_source_binding_matches = scene.get("binding",{}) == source_binding and source.get("binding",{}) == source_binding and source.get("sourceSignature") == source_signature
			break
	if not checks.get("scene_source_binding_matches",false):
		await _finish("timeout","ordinary_scene_not_ready_from_manifest_exterior"); return
	phase = "ready_scene_observation"
	if main.has_method("hide_streaming_loading_overlay"):
		main.hide_streaming_loading_overlay("citadel_fixture")
	await physics_frame
	await _frame()
	evidence.sceneAudit = await _audit_scene()
	checks.scene_audit = evidence.sceneAudit.get("passed",false)
	checks.urban_home_interiors_live = evidence.sceneAudit.get("urbanHomeInteriorReady",false)
	evidence.structuralClearance = _audit_stair_clearance()
	checks.structural_clearance = evidence.structuralClearance.passed
	checks.camera_facing_candidate = await _look_toward_candidate()
	evidence.visibility = _inspect_visibility()
	if not checks.camera_facing_candidate:
		await _finish("failed","ordinary_mouse_look_did_not_face_candidate"); return
	if not await _capture("ready"):
		await _finish("failed","ready_capture_failed"); return
	checks.ready_capture_still_owned = main.structure_system.citadel_runtime_bindings.available() and main.structure_system.citadel_publication.scene_state(region).get("binding",{}) == source_binding and main.structure_system.citadel_publication.scene_state(region).get("status") == "scene_ready"
	if manual_seconds>0 and checks.scene_audit and checks.ready_capture_still_owned:
		await _finish("scene_ready",""); return
	if checks.scene_audit and checks.ready_capture_still_owned:
		evidence.approach=await _approach_scene()
		checks.no_modal_loading_during_close_approach = int(evidence.approach.get("modalLoadingVisibleFrames",-1))==0
		checks.close_approach=evidence.approach.get("reached",false)
		if not await _capture("close"):
			await _finish("failed","close_capture_failed"); return
		if not _write_approach_checkpoint():
			await _finish("failed","approach_checkpoint_write_failed"); return
		if not checks.close_approach:
			await _finish("failed",String(evidence.approach.get("reason","approach_blocked"))); return
		var navigation_inventory := _navigation_domain_inventory()
		evidence.navigationInventory = navigation_inventory
		if not navigation_inventory.get("passed",false):
			await _finish("failed",String(navigation_inventory.get("reason","navigation_domain_unavailable"))); return
		evidence.inspectionViews=await _capture_inspection_views()
		checks.inspection_views=evidence.inspectionViews.passed
		if not checks.inspection_views:
			await _finish("failed","inspection_capture_failed"); return
		checks.finalization_status_presented = await _begin_finalization()
		if not checks.finalization_status_presented:
			await _finish("failed","finalization_status_failed"); return
		evidence.navigationPublication = await _audit_navigation_publication(navigation_inventory.tileKeys)
		checks.navigation_publication = evidence.navigationPublication.get("passed",false) == true and evidence.navigationPublication.get("complete",false) == true
		if not checks.navigation_publication:
			await _finish("failed",String(evidence.navigationPublication.get("reason","navigation_publication_incomplete"))); return
	await _finish("scene_ready" if checks.scene_audit else "failed","" if checks.scene_audit else "scene_observation_failed")

func _navigation_domain_inventory() -> Dictionary:
	var result := {"passed":false,"reason":"navigation_domain_owner_unavailable","tileKeys":[]}
	if not is_instance_valid(main) or main.structure_system == null: return result
	var service = main.structure_system.citadel_publication
	if service == null or not service.has_method("navigation_source_domain"): return result
	var described: Dictionary = service.navigation_source_domain(region,source_binding)
	if described.get("status") != "described" or described.get("binding",{}) != source_binding:
		result.reason = String(described.get("reason","navigation_domain_not_current")); return result
	var domain: Dictionary = described.get("domain",{})
	if domain.get("status") != "complete" or domain.get("scope") != "source_navigation_output" \
			or not domain.is_read_only() or not domain.get("tileKeys") is Array or domain.tileKeys.is_empty():
		result.reason = "navigation_domain_missing_or_empty"; return result
	# The service validates canonical unique keys on admission. Copy only its
	# frozen inventory; never retain or inspect the worker-owned producer.
	result.tileKeys = domain.tileKeys.duplicate()
	result["binding"] = source_binding.duplicate()
	result["declaredTileCount"] = result.tileKeys.size()
	result["scope"] = "Complete conservative structure-output domain; combined terrain is captured per tile. Not regional crossing or movement acceptance."
	result.reason = "navigation_domain_complete"
	result.passed = true
	return result

func _initial_spawn_physical_readiness() -> Dictionary:
	var result := {"status":"pending","reason":"structure_owner_unavailable","bounds":Rect2i(),"required":true,
		"sceneInstanceIds":[]}
	if not is_instance_valid(main) or main.structure_system==null: return result
	var bounds: Rect2i = Streaming.playable_bounds(player.global_position)
	var physical: Dictionary = main.structure_system.citadel_physical_publication_state(bounds)
	result = physical.duplicate(true)
	result["bounds"] = bounds
	return result

func _observe_navigation_work(key: String, collector: Dictionary, force := false) -> void:
	var now := Time.get_ticks_msec()
	if not force and now-int(collector.lastSampleMsec)<1000: return
	collector.lastSampleMsec = now
	var begun := Time.get_ticks_usec()
	var service = main.structure_system.citadel_publication
	var binding: Dictionary = _source_summary().get("binding",{})
	var request: Dictionary = service.navigation_request_observation(region,key,binding)
	var worker: Dictionary = service._worker.navigation_timing()
	var report: Dictionary = collector.report
	if report.requestSamples.size()<64: report.requestSamples.append(request)
	else: report.droppedRequestSamples += 1
	report.lastRequest = request
	# Rows can gain joined/taken timestamps after their first observation.
	# Update existing records; retain at most512 unique epoch/token pairs.
	for row: Dictionary in worker.history:
		var id := "%d:%d" % [int(row.epoch),int(row.token)]
		if collector.batchIndex.has(id): report.batches[int(collector.batchIndex[id])] = row
		elif report.batches.size()<512:
			collector.batchIndex[id] = report.batches.size()
			report.batches.append(row)
		else: report.unretainedBatchObservations += 1
	report.lastWorker = worker # Also retains the final64 rows if the512 cap fills.
	var elapsed := Time.get_ticks_usec()-begun
	report.observerTotalUsec += elapsed
	report.observerMaxUsec = maxi(int(report.observerMaxUsec),elapsed)
	report.observations += 1

func _audit_navigation_publication(expected_keys: Array) -> Dictionary:
	return await _audit_foreground_navigation_publication(expected_keys)
	# Historical exhaustive diagnostic retained below for source comparison. It
	# is intentionally unreachable: registering all source tiles here made the
	# headed fixture a second publisher beside the production coordinator.
	# Production async publication diagnostic in the actual Main scene. This
	# proves worker preparation and owner acknowledgements, not NPC traversal.
	phase = "diagnostic_navigation_publication"
	var result := {"passed":false,"complete":false,"evidenceLevel":"live_scene_publication_diagnostic","tiles":[],
		"declaredTileCount":expected_keys.size(),"acknowledgedEmptyTiles":0,"acknowledgedNonemptyTiles":0,
		"doesNotProve":"NPC movement, connected routes, ordinary traversal, regional loading or frame pacing"}
	var inventory := _navigation_domain_inventory()
	if not inventory.get("passed",false) or inventory.get("tileKeys",[]) != expected_keys:
		result["reason"] = "navigation_domain_changed_before_audit"; return result
	if main.npc_system == null or main.npc_system.pathing == null or main.npc_system.autonomy_system == null:
		result["reason"] = "navigation_owners_unavailable"; return result
	var adapter = main.npc_system.pathing.navigation_world
	var nav = main.npc_system.autonomy_system.navmesh_world
	if adapter == null or nav == null:
		result["reason"] = "navigation_owners_unavailable"; return result
	# Retain the complete declared demand before observing any one tile. The
	# production coordinator then owns capture, Citadel source batching, worker
	# preparation, upload, synchronization and acknowledgement. Sequential raw
	# probes used to reveal each source only after the previous one finished and
	# could starve behind the sole capture slot until the global run deadline.
	var retained_demand := _retain_navigation_audit_demand(expected_keys)
	result["demandRetention"] = retained_demand
	if not retained_demand.get("passed",false):
		result["reason"] = String(retained_demand.get("reason","navigation_demand_retention_unavailable")); return result
	var rejection_diagnostics_enabled: bool = adapter.navigation_rejection_diagnostics_enabled
	var work_observation := {"report":{"schema":"citadel-navigation-work-observation/v1",
		"scope":"Read-only owner request ranks and worker wall-clock boundaries; no priority, polling or readiness changes. Zero timestamp means boundary not reached.",
		"requestSamples":[],"batches":[],"lastRequest":{},"lastWorker":{},
		"droppedRequestSamples":0,"unretainedBatchObservations":0,
		"observerTotalUsec":0,"observerMaxUsec":0,"observations":0},"lastSampleMsec":0,"batchIndex":{}}
	result["workObservation"] = work_observation.report
	var keys: Array = expected_keys.duplicate()
	result["rejectionDiagnosticsEnabled"] = rejection_diagnostics_enabled
	var audit_passed := true
	for key: String in keys:
		if not _within_deadline(): audit_passed=false; result["reason"]="navigation_diagnostic_deadline"; break
		var current_identity := _accepted_current()
		if not current_identity.get("passed",false):
			audit_passed=false; result["reason"]="navigation_source_changed_during_audit"; break
		var begun := Time.get_ticks_msec()
		var tile_deadline := mini(deadline, begun+30000)
		var installed: Dictionary = {"status":"pending","installed":false,"reason":"source_pending"}
		var saved: Dictionary = {}
		var capture_profile: Dictionary = {}
		var rejection_diagnostics: Dictionary = {}
		var attempts := 0
		var observed_first_query := false
		_observe_navigation_work(key,work_observation,true)
		while _within_deadline() and Time.get_ticks_msec()<tile_deadline:
			# Re-read the authoritative producer on every retry: a changed source
			# must not leave the diagnostic resubmitting a stale captured packet.
			var snapshot: Dictionary = adapter.build_navmesh_tile_snapshot(key)
			_observe_navigation_work(key,work_observation,not observed_first_query)
			observed_first_query = true
			var source_status := String(snapshot.get("publicationStatus","pending"))
			if source_status == "ready":
				attempts+=1
				installed=nav.register_tile_snapshot(snapshot)
				var source: Dictionary = snapshot.get("publicationSource",{})
				if (installed.get("installed",false) or installed.get("status") == "empty") and source.get("status") != "prepared":
					installed={"status":"failed","installed":false,"reason":source.get("reason","missing_prepared_publication_source")}
					break
				# This exact whitelist capture excludes live collision snapshots,
				# publicationOwner/WeakRef and the outer worker envelope.
				if source.get("status") == "prepared":
					saved=source.snapshot
					capture_profile=snapshot.get("publicationCaptureProfile",source.profile)
					rejection_diagnostics=snapshot.get("publicationDiagnostics",{})
				if installed.get("installed",false) or installed.get("status") in ["failed","rejected","empty","unloaded"]:
					break
				if installed.get("status") != "pending":
					installed={"status":"failed","installed":false,"reason":"unexpected_registration_status","returnedStatus":installed.get("status")}
					break
			elif source_status == "pending":
				installed={"status":"pending","installed":false,"reason":snapshot.get("reason","source_pending")}
			else:
				installed={"status":"failed","installed":false,"reason":snapshot.get("reason","source_not_ready"),"sourceStatus":source_status}
				break
			last_observation["navigationPublication"]={"tileKey":key,"attempts":attempts,
				"elapsedMsec":Time.get_ticks_msec()-begun,"status":installed.get("status"),"reason":installed.get("reason","")}
			# Ordinary frames drive the production worker/upload queue. No direct
			# descriptor construction, worker polling or unbudgeted install bypass.
			await physics_frame
			await _frame()
		_observe_navigation_work(key,work_observation,true)
		if installed.get("status") == "pending":
			installed={"status":"timeout","installed":false,"reason":"navigation_installation_timeout",
				"pendingReason":installed.get("reason",""),"deadlineReached":not _within_deadline()}
		if not saved.is_empty():
			var file := FileAccess.open(output+"/navigation-tile-"+key+".bin",FileAccess.WRITE)
			if file==null: audit_passed=false; result["reason"]="navigation_snapshot_write_failed"; break
			file.store_var(saved,false)
			var write_error := file.get_error()
			file.close()
			if write_error!=OK: audit_passed=false; result["reason"]="navigation_snapshot_write_failed"; break
		var rejection_summary := {}
		if rejection_diagnostics_enabled and not saved.is_empty():
			var matched := not rejection_diagnostics.is_empty()
			for field: String in ["tileKey","sourceKey","sourceRevision","semanticRevision","worldSeed"]:
				matched = matched and rejection_diagnostics.get(field)==saved.get(field)
			matched = matched and rejection_diagnostics.get("acceptedBuildingSurfaceCount",-1)==saved.get("buildingSurfaces",[]).size() \
				and rejection_diagnostics.get("acceptedTerrainSurfaceCount",-1)==saved.get("surfaces",[]).size()
			if not matched: audit_passed=false; result["reason"]="navigation_rejection_evidence_identity_mismatch"; break
			var diagnostic_path := output+"/navigation-rejections-"+key+".bin"
			var diagnostic_file := FileAccess.open(diagnostic_path,FileAccess.WRITE)
			if diagnostic_file==null: audit_passed=false; result["reason"]="navigation_rejection_evidence_write_failed"; break
			# Binary preserves INF declared bounds and shape transforms; no live
			# references or diagnostic data enter the worker source snapshot.
			diagnostic_file.store_var(rejection_diagnostics,false)
			var diagnostic_error := diagnostic_file.get_error()
			diagnostic_file.close()
			if diagnostic_error!=OK: audit_passed=false; result["reason"]="navigation_rejection_evidence_write_failed"; break
			rejection_summary={"path":diagnostic_path,"blockerGroupCount":rejection_diagnostics.blockers.size()}
			for field: String in ["rawBuildingSurfaceCount","acceptedBuildingSurfaceCount","rejectedBuildingSurfaceCount",
					"rawTerrainCellCount","acceptedTerrainSurfaceCount","rejectedTerrainCellCount","terrainRejectionReasons","recordUsec"]:
				rejection_summary[field]=rejection_diagnostics[field]
		var surfaces: Array = []
		var links: Array = []
		var receipt: Dictionary = {"status":"pending","reason":"installation_not_completed"}
		var worker_thread := 0
		var empty_install: bool = installed.get("status") == "empty"
		if (installed.get("installed",false) or empty_install) and not saved.is_empty():
			# Expected IDs derive from the source, never the installed subset.
			# Preserve the descriptor's terrain ID convention without constructing
			# another full descriptor on the main thread just to obtain its IDs.
			var terrain: Array = saved.get("surfaces",[])
			for index in terrain.size():
				var fact: Dictionary = terrain[index]
				if fact.get("blocked",false): continue
				var cell: Vector3i = fact.get("cell",Vector3i.ZERO)
				surfaces.append("surface:%s:%d,%d,%d:%d" % [key,cell.x,cell.y,cell.z,int(fact.get("spanIndex",index))])
			for fact: Dictionary in saved.get("buildingSurfaces",[]): surfaces.append(String(fact.id))
			for fact: Dictionary in saved.get("crossingLinks",[])+saved.get("doorLinks",[]): links.append(String(fact.id))
			var descriptor = nav.descriptors_by_region.get(String(saved.regionId))
			if descriptor!=null and descriptor.has_method("prepared_geometry"):
				worker_thread=int(descriptor.prepared_geometry().get("threadId",0))
			nav.sync_navigation_map_if_dirty()
			await physics_frame
			await _frame()
			receipt=_navigation_audit_receipt(nav,adapter,key,saved,surfaces,links,empty_install)
			var sync_deadline := mini(deadline,Time.get_ticks_msec()+3000)
			while receipt.status=="pending" and receipt.reason=="installation_sync_pending" and _within_deadline() and Time.get_ticks_msec()<sync_deadline:
				await physics_frame
				await _frame()
				nav.sync_navigation_map_if_dirty()
				receipt=_navigation_audit_receipt(nav,adapter,key,saved,surfaces,links,empty_install)
		var install_summary := {}
		for field: String in ["status","reason","installed","cached","regionId","tileKey","returnedStatus","sourceStatus","pendingReason","deadlineReached"]:
			if installed.has(field): install_summary[field]=installed[field]
		if installed.get("install") is Dictionary:
			var metrics := {}
			for field: String in ["status","polygonCount","vertexCount","durationUsec","doorLinks","crossingLinks"]:
				if installed.install.has(field): metrics[field]=installed.install[field]
			install_summary["install"]=metrics
		# Full source geometry lives in the value-only binary. Keep JSON bounded.
		receipt.erase("signature")
		var worker_prepared := worker_thread>0 and worker_thread!=OS.get_thread_caller_id()
		result.tiles.append({"tileKey":key,"install":install_summary,"receipt":receipt,
			"surfaceCount":surfaces.size(),"linkCount":links.size(),"registrationAttempts":attempts,
			"elapsedMsec":Time.get_ticks_msec()-begun,"captureProfile":capture_profile,
			"workerPrepared":worker_prepared,"preparationThreadId":worker_thread,"rejectionDiagnostics":rejection_summary})
		var tile_passed: bool = receipt.get("status") == "ready" and worker_prepared
		if tile_passed:
			result["acknowledgedEmptyTiles" if empty_install else "acknowledgedNonemptyTiles"] += 1
		else:
			audit_passed = false
			# Preserve the actual publication/deadline failure. Worker provenance is
			# meaningful only after an installation produced a descriptor.
			if installed.get("status") in ["timeout","failed","rejected","unloaded"]:
				result["reason"] = String(installed.get("reason","navigation_tile_not_installed"))
			elif receipt.get("status") == "failed":
				result["reason"] = String(receipt.get("reason","navigation_tile_not_acknowledged"))
			elif not worker_prepared:
				result["reason"] = "navigation_tile_worker_preparation_unproven"
			else:
				result["reason"] = String(receipt.get("reason","navigation_tile_not_acknowledged"))
		var report := FileAccess.open(output+"/navigation-publication.json",FileAccess.WRITE)
		if report==null: audit_passed=false; result["reason"]="navigation_report_write_failed"; break
		report.store_string(JSON.stringify(result,"\t"))
		report.close()
		if not tile_passed: break # Preserve the first failed tile; do not continue blind retries.
	var queue_stats: Dictionary = nav._publication_queue.stats()
	var queue_summary := {"scope":"Cumulative production queue advance; excludes upstream source filtering and capture","worker":{}}
	for field: String in ["status","busy","preparedCount","uploadedCount","retiredBatchCount","maxAdvanceUsec","shutdownComplete"]:
		if queue_stats.has(field): queue_summary[field]=queue_stats[field]
	for field in queue_stats.get("worker",{}):
		var value: Variant = queue_stats.worker[field]
		if value is int or value is float or value is bool: queue_summary.worker[field]=value
	result["publicationQueue"]=queue_summary
	var final_inventory := _navigation_domain_inventory()
	result.complete = result.tiles.size() == keys.size() and final_inventory.get("passed",false) \
		and final_inventory.get("tileKeys",[]) == keys
	result.passed = audit_passed and result.complete \
		and result.acknowledgedEmptyTiles + result.acknowledgedNonemptyTiles == keys.size()
	if not result.passed and not result.has("reason"): result["reason"] = "navigation_domain_audit_incomplete"
	var final_report := FileAccess.open(output+"/navigation-publication.json",FileAccess.WRITE)
	if final_report==null: result.passed=false; result["reason"]="navigation_report_write_failed"
	else:
		final_report.store_string(JSON.stringify(result,"\t"))
		final_report.close()
	return result

func _audit_foreground_navigation_publication(expected_keys: Array) -> Dictionary:
	phase="diagnostic_navigation_publication"
	var result:={"passed":false,"complete":false,"evidenceLevel":"live_scene_foreground_production_publication",
		"declaredTileCount":expected_keys.size(),"tiles":[],
		"doesNotProve":"Exhaustive whole-Citadel navigation coverage, connected NPC routes or NPC movement"}
	var inventory:=_navigation_domain_inventory()
	if not inventory.get("passed",false) or inventory.get("tileKeys",[])!=expected_keys:
		result["reason"]="navigation_domain_changed_before_audit"
		return result
	if not is_instance_valid(main) or main.regional_navigation==null or main.npc_system==null \
			or main.npc_system.pathing==null or main.npc_system.autonomy_system==null:
		result["reason"]="navigation_owners_unavailable"
		return result
	var foreground: Dictionary=main.player_foreground_streaming_intent()
	var keys: Array[String]=[]
	for raw_tile: Variant in foreground.get("navigationTiles",[]):
		if not raw_tile is Vector2i:
			result["reason"]="invalid_foreground_navigation_tile"
			return result
		var tile: Vector2i=raw_tile
		keys.append("%d,%d" % [tile.x,tile.y])
	keys.sort()
	var expected_set:={}
	for key: String in expected_keys: expected_set[key]=true
	var citadel_keys: Array[String]=[]
	for key: String in keys:
		if expected_set.has(key): citadel_keys.append(key)
	if keys.is_empty() or citadel_keys.is_empty():
		result["reason"]="foreground_does_not_intersect_citadel_navigation_domain"
		return result
	result["foregroundTileKeys"]=keys
	result["citadelForegroundTileKeys"]=citadel_keys
	result["ordinaryForegroundTileCount"]=keys.size()-citadel_keys.size()
	result["auditedTileCount"]=keys.size()
	result["queryBounds"]=foreground.get("bounds",Rect2i())
	var retained:=_retain_navigation_audit_demand(keys)
	result["demandRetention"]=retained
	if not retained.get("passed",false):
		result["reason"]=retained.get("reason","navigation_demand_retention_unavailable")
		return result
	var readiness: Dictionary={"status":"pending","reason":"navigation_publication_pending"}
	var audit_deadline:=mini(deadline,Time.get_ticks_msec()+30000)
	while _within_deadline() and Time.get_ticks_msec()<audit_deadline:
		readiness=main.regional_navigation.tiles_publication_readiness(keys,foreground.bounds)
		last_observation["navigationPublication"]={"auditedTileCount":keys.size(),
			"status":readiness.get("status"),"reason":readiness.get("reason","")}
		if readiness.get("status") in ["ready","failed"]: break
		await physics_frame
		await _frame()
	result["readiness"]=readiness
	if readiness.get("status")!="ready":
		result["reason"]=readiness.get("reason","foreground_navigation_publication_timeout")
		return result
	var adapter=main.npc_system.pathing.navigation_world
	var nav=main.npc_system.autonomy_system.navmesh_world
	for key: String in citadel_keys:
		var source_key: String=String(adapter.navmesh_tile_source_key_for_tile(key))
		var accepted: Dictionary=nav.accepted_tile_state(key,source_key,String(main.seed_text),adapter)
		result.tiles.append({"tileKey":key,"sourceKey":source_key,
			"acceptedStatus":accepted.get("status","absent"),
			"acceptedSerial":accepted.get("accepted",{}).get("serial",0)})
		if accepted.get("status")!="acknowledged":
			result["reason"]="foreground_navigation_accepted_source_pending"
			return result
	var final_inventory:=_navigation_domain_inventory()
	result.complete=final_inventory.get("passed",false) and final_inventory.get("tileKeys",[])==expected_keys \
		and result.tiles.size()==citadel_keys.size()
	result.passed=result.complete
	result["reason"]="foreground_navigation_publication_acknowledged" if result.passed else "navigation_domain_changed_after_audit"
	return result

func _retain_navigation_audit_demand(tile_keys: Array) -> Dictionary:
	var result := {"passed":false,"reason":"navigation_route_publisher_unavailable",
		"declaredTileCount":tile_keys.size(),"newlyQueuedCount":0}
	if main.npc_system == null or main.npc_system.pathing == null: return result
	var pathing = main.npc_system.pathing
	if pathing.has_method("ensure_ready"): pathing.ensure_ready()
	var authority = pathing.get("route_planner")
	var publisher = authority.get("delegate") if authority != null else null
	if publisher == null or not publisher.has_method("queue_navmesh_tile_publish"): return result
	for key: String in tile_keys:
		if publisher.queue_navmesh_tile_publish(key,true): result.newlyQueuedCount += 1
	result.passed = true
	result.reason = "navigation_demand_retained"
	result["scope"] = "Public production queue demand; false queue returns may already have an acknowledged current source. Per-tile receipts remain authoritative."
	return result

func _navigation_audit_receipt(nav, adapter, key: String, saved: Dictionary, surfaces: Array, links: Array, expect_empty: bool) -> Dictionary:
	# The borrowed accepted source stays within this synchronous helper. Only
	# its compact receipt crosses an await; no worker/source graph is retained.
	var accepted: Dictionary = nav.accepted_tile_state(key,String(saved.get("sourceKey","")),String(saved.get("worldSeed","")),adapter)
	if accepted.get("status") != "acknowledged":
		return {"status":"pending" if accepted.get("status") == "retained" else "failed",
			"reason":accepted.get("reason","navigation_accepted_source_missing")}
	if bool(accepted.get("empty",false)) != expect_empty:
		return {"status":"failed","reason":"navigation_empty_receipt_changed"}
	if expect_empty:
		if not surfaces.is_empty() or not links.is_empty():
			return {"status":"failed","reason":"navigation_empty_receipt_has_expected_geometry"}
		return accepted.get("receipt",{}).duplicate()
	return nav.tile_publication_readiness(key,String(saved.sourceKey),surfaces,links)

func _capture_inspection_views() -> Dictionary:
	# Render the existing live world from explicitly diagnostic cameras. This does
	# not move the player, publish geometry, change lighting or prove traversal.
	phase="diagnostic_visual_inspection"
	var bounds: AABB=evidence.sceneAudit.visualBounds
	var center := bounds.get_center()
	var radius := maxf(bounds.size.x,bounds.size.z)*0.85
	var views: Array=[]
	for side in range(4):
		var direction := Vector3(sin(float(side)*PI*0.5+PI*0.25),0.0,cos(float(side)*PI*0.5+PI*0.25))
		views.append({"label":"overview_%d"%side,"position":center+direction*radius+Vector3.UP*bounds.size.y,"target":center})
	views.append({"label":"courtyard_overview","position":center+Vector3(0,bounds.size.y*1.6,bounds.size.z*0.12),"target":center})
	var street_doors: Dictionary={}
	for sample: Dictionary in evidence.sceneAudit.get("structureSamples",[]):
		var pose: Transform3D=sample.transform
		var local_view := Vector3(0,sample.size.y*0.5+1.6,0.0)
		var local_target := Vector3(0,sample.size.y*0.5+0.3,1.5)
		if sample.kind=="door":
			# Frame the whole facade from across the street. The old two-metre,
			# waist-height view mostly photographed a dark door leaf and hid the
			# house and lane that a player would actually read while approaching.
			local_view=Vector3(sample.size.x*1.4,1.65,-5.0)
			local_target=Vector3(0,0.45,0)
			street_doors[String(sample.id)]=sample
		elif sample.kind=="foundation":
			# Foundation samples are solid volumes; do not place the observer at
			# their centre. Look back from the open lane and above the roof line.
			local_view=Vector3(sample.size.x*0.8,sample.size.y+2.5,-sample.size.z*1.4)
			local_target=Vector3(0,sample.size.y*0.55,0)
		var view_position := pose*local_view
		if sample.kind in ["door","foundation"]:
			# A narrow street can put the nominal camera inside the opposite wall.
			# Clamp only the observer against actual live collision, not the player.
			var start := pose*Vector3(0,0.8,-0.3) if sample.kind=="door" else pose*Vector3(0,sample.size.y+0.4,0)
			view_position=_clamp_inspection_camera(start,view_position)
		views.append({"label":sample.id,"position":view_position,"target":pose*local_target})
	# These two views use paired, declared house doors to photograph the real
	# open street between them. They are diagnostic cameras only: the world,
	# player, collision and navigation state remain untouched.
	for row_id: String in ["03","00"]:
		var right_id := "urban_row_%s_right_door"%row_id
		var left_id := "urban_row_%s_left_door"%row_id
		if not street_doors.has(right_id) or not street_doors.has(left_id): continue
		var right_pose: Transform3D=street_doors[right_id].transform
		var left_pose: Transform3D=street_doors[left_id].transform
		var lane_center := (right_pose.origin+left_pose.origin)*0.5
		var lane_axis := right_pose.basis.x.normalized()
		var target := lane_center+Vector3.UP*1.6
		var desired := target+lane_axis*12.0+Vector3.UP*2.2
		views.append({"label":"urban_street_%s_houses"%row_id,
			"position":_clamp_inspection_camera(target,desired),"target":target})
	var interior_home_ids: Array[String] = []
	for home_value in evidence.sceneAudit.get("urbanHomeInteriors",[]):
		if interior_home_ids.size()>=2: break
		if not home_value is Dictionary or not bool((home_value as Dictionary).get("complete",false)): continue
		var home: Dictionary=home_value as Dictionary
		var room_bounds: AABB=home.get("worldBounds",AABB())
		var street_side:=signf(float(home.get("streetSide",0.0)))
		if room_bounds.size.x<=1.8 or room_bounds.size.z<=1.8 or is_zero_approx(street_side): continue
		var home_id:=String(home.get("id",""))
		var room_center:=room_bounds.get_center()
		var street_x:=room_bounds.end.x-0.72 if street_side>0.0 else room_bounds.position.x+0.72
		var rear_x:=room_bounds.position.x+0.72 if street_side>0.0 else room_bounds.end.x-0.72
		var first_position:=Vector3(street_x,room_bounds.position.y+1.45,room_bounds.position.z+minf(0.92,room_bounds.size.z*0.25))
		var second_position:=Vector3(rear_x,room_bounds.position.y+1.55,room_bounds.end.z-minf(0.92,room_bounds.size.z*0.25))
		var target:=Vector3(room_center.x,room_bounds.position.y+0.95,room_center.z)
		views.append({"label":"home_interior_%s_door_side"%home_id,"position":first_position,"target":target,"urbanHome":home})
		views.append({"label":"home_interior_%s_rear_side"%home_id,"position":second_position,"target":target,"urbanHome":home})
		interior_home_ids.append(home_id)
	if interior_home_ids.size()<2:
		return {"passed":false,"reason":"fewer_than_two_complete_live_urban_home_interiors","homeIds":interior_home_ids}
	var observer := Camera3D.new()
	observer.name="DiagnosticCitadelInspectionCamera"
	observer.fov=72.0
	observer.far=player.camera.far
	observer.cull_mask=player.camera.cull_mask
	main.add_child(observer)
	observer.make_current()
	var passed := true
	for view: Dictionary in views:
		if not _within_deadline(): passed=false; break
		phase="diagnostic_visual_inspection"
		observer.global_position=view.position
		observer.look_at(view.target)
		await _frame()
		await _frame()
		if view.label in ["overview_0","courtyard_overview","urban_row_00_left_door"]:
			phase="fixed_view:"+String(view.label)
			var view_until := Time.get_ticks_msec()+2000
			while Time.get_ticks_msec()<view_until and _within_deadline(): await _frame()
		phase="diagnostic_visual_inspection"
		if not await _capture(view.label,"diagnostic_inspection_camera"): passed=false; break
	player.camera.make_current()
	observer.queue_free()
	await _frame()
	var identity := _accepted_current()
	return {"passed":passed and identity.passed and root.get_camera_3d()==player.camera,"views":views,"identity":identity,
		"interiorHomeIds":interior_home_ids,
		"scope":"Diagnostic camera views of unchanged production scene; no player placement, movement, interaction or navigation acceptance."}

func _begin_finalization() -> bool:
	# Captures are complete at this boundary. Keep the remaining navigation audit
	# and report write visible so a headed run never looks abandoned while it is
	# still producing acceptance evidence.
	phase = "finalizing_citadel_capture"
	if is_instance_valid(main) and main.has_method("show_streaming_loading_overlay"):
		main.show_streaming_loading_overlay("Finalizing Citadel capture…", "citadel_fixture_finalization")
	var labels: Array[String] = []
	for capture: Dictionary in captures:
		labels.append(String(capture.get("label", "")))
	var receipt := {"phase":phase,"status":"finalizing","message":"Finalizing Citadel capture…",
		"elapsedMsec":_elapsed(),"captureCount":captures.size(),"captureLabels":labels,
		"remaining":["navigation_publication_acceptance","report_write","owned_shutdown"],
		"automaticExit":true}
	evidence.finalization = receipt.duplicate(true)
	if not _write("progress.json", receipt): return false
	print("CITADEL CAPTURES COMPLETE: finalizing navigation acceptance and report; automatic exit follows")
	# Give the headed renderer two ordinary frames to present the overlay before
	# the final audit begins. This changes only diagnostic presentation.
	await process_frame
	await process_frame
	return true

func _clamp_inspection_camera(start: Vector3, desired: Vector3) -> Vector3:
	var direction := desired-start
	if direction.length_squared()<=0.0001: return desired
	var query := PhysicsRayQueryParameters3D.create(start,desired,player.collision_mask,[player.get_rid()])
	var hit: Dictionary=main.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty(): return desired
	return hit.position-direction.normalized()*0.35

func _movement_key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode=key
	event.physical_keycode=key
	event.pressed=pressed
	Input.parse_input_event(event)

func _release_approach_keys() -> void:
	for key: Key in [KEY_W,KEY_A,KEY_D,KEY_SPACE,KEY_SHIFT]: _movement_key(key,false)

func _approach_motion_snapshot() -> Dictionary:
	var contacts: Array=[]
	for index in range(mini(player.get_slide_collision_count(),8)):
		var contact: KinematicCollision3D=player.get_slide_collision(index)
		var collider=contact.get_collider()
		contacts.append({"path":String(collider.get_path()) if collider is Node else str(collider),"position":contact.get_position(),"normal":contact.get_normal()})
	return {"velocity":player.velocity,"onFloor":player.is_on_floor(),"terrainGrounded":player.get("terrain_grounded"),
		"terrainHold":player.get_meta("terrain_collision_hold",false),"terrainProof":player.get("last_terrain_collision_proof"),
		"groundY":main.ground_y_near_position(player.global_position),"contacts":contacts,
		"modalLoadingVisible":_modal_loading_visible()}

func _modal_loading_visible() -> bool:
	if not is_instance_valid(main): return false
	if bool(main.get("streaming_loading_overlay_active")): return true
	var hud_value = main.get("hud")
	if is_instance_valid(hud_value):
		var overlay = hud_value.get("loading_overlay")
		if is_instance_valid(overlay) and bool(overlay.visible): return true
	var startup_value = main.get("startup_overlay")
	return is_instance_valid(startup_value) and bool(startup_value.visible)

func _approach_until_scene_publication() -> Dictionary:
	phase="ordinary_input_publication_demand"
	var begun := Time.get_ticks_msec()
	var until := mini(deadline-10000,begun+20000)
	var next_sample := begun
	var strafe_until := 0
	var jump_until := 0
	var recovery_count := 0
	var previous := player.global_position
	var start_position := previous
	var samples: Array=[]
	var modal_loading_visible_frames := 0
	var reason := "publication_demand_time_limit"
	var reached := false
	if bool(player.get("automated_input")) or not player.is_physics_processing():
		return {"passed":false,"reason":"ordinary_player_input_unavailable"}
	_movement_key(KEY_W,true)
	_movement_key(KEY_SHIFT,true)
	while Time.get_ticks_msec()<until and _within_deadline():
		await physics_frame
		await _frame()
		if _modal_loading_visible(): modal_loading_visible_frames+=1
		if not _outside(reservation):
			reason="player_entered_reservation_before_publication_demand"
			break
		var observed := _observe()
		var scene: Dictionary = observed.get("scene",{})
		if scene.get("status")=="failed":
			reason=String(scene.get("reason","publication_failed"))
			break
		if scene.get("status")=="scene_ready" or _packet_scene_publication_started(scene):
			reached=true
			reason="scene_publication_demanded"
			break
		var now := Time.get_ticks_msec()
		_movement_key(KEY_SPACE,now<jump_until)
		_movement_key(KEY_W,now>=strafe_until)
		_movement_key(KEY_A,now<strafe_until and recovery_count%4==2)
		_movement_key(KEY_D,now<strafe_until and recovery_count%4==0)
		if now<next_sample: continue
		next_sample=now+1000
		var identity := _accepted_current()
		if not identity.passed:
			reason=String(identity.reason)
			break
		if now-begun>1000 and player.global_position.distance_to(previous)<0.30 and now>=strafe_until:
			recovery_count+=1
			if recovery_count%2==1: jump_until=now+250
			else: strafe_until=now+1500
		samples.append({"elapsedMsec":now-begun,"position":player.global_position,
			"distanceMoved":player.global_position.distance_to(start_position),"ordinaryWPressed":Input.is_key_pressed(KEY_W),
			"sprinting":player.get("is_sprinting"),"recoveryCount":recovery_count,"motion":_approach_motion_snapshot()})
		previous=player.global_position
		if not await _look_toward_candidate():
			reason="approach_mouse_look_failed"
			break
	_release_approach_keys()
	await physics_frame
	await _frame()
	var identity := _accepted_current()
	var capsule := Clearance.inspect(player)
	var result_reason := reason if identity.passed and capsule.passed and _outside(reservation) else "publication_demand_identity_or_capsule_failed"
	if modal_loading_visible_frames>0: result_reason="modal_loading_visible_during_publication_approach"
	return {"passed":reached and identity.passed and capsule.passed and _outside(reservation) and modal_loading_visible_frames==0,
		"reason":result_reason,
		"elapsedMsec":Time.get_ticks_msec()-begun,"from":start_position,"to":player.global_position,
		"distanceMoved":player.global_position.distance_to(start_position),"samples":samples,"identity":identity,"capsule":capsule,
		"modalLoadingVisibleFrames":modal_loading_visible_frames,
		"keysReleased":not Input.is_key_pressed(KEY_W) and not Input.is_key_pressed(KEY_SHIFT),
		"scope":"Ordinary key-input approach until the source publishes its first demanded packet; no transform write, route command or reservation entry."}

func _packet_scene_publication_started(scene: Dictionary) -> bool:
	if main.structure_system==null: return false
	var publication = main.structure_system.citadel_publication
	# Source preparation is already the retained production publication job for
	# this exact binding. Treat it as the demand boundary so the runner can keep
	# the loading overlay active while preparation completes, instead of failing
	# an arbitrary 20-second approach window before the scene job can exist.
	var inflight: Dictionary = publication._inflight
	if inflight.get("region") == region and inflight.get("binding",{}) == source_binding \
			and inflight.get("kind") in ["publication_base","publication_base_navigation","preparation","physical_group_packet"]:
		return true
	if scene.get("status")!="publishing": return false
	var entry: Dictionary = publication._scenes.get(region,{})
	if entry.get("binding",{})!=source_binding or not entry.has("job"): return false
	var phase: String = String(entry.job.status_count().get("phase",""))
	# `packet_wait` is a resident source shell only.  Any later phase can occur
	# only after the exact packet selected by ordinary streaming demand is owned
	# by the scene job.
	return not phase.is_empty() and phase!="packet_wait"

func _approach_scene() -> Dictionary:
	phase="ordinary_input_approach"
	var begun := Time.get_ticks_msec()
	var until := mini(deadline-10000,begun+45000)
	var next_sample := begun
	var strafe_until := 0
	var jump_until := 0
	var recovery_count := 0
	var previous := player.global_position
	var start_position := previous
	var samples: Array=[]
	var modal_loading_visible_frames := 0
	var reason := "approach_time_limit"
	var reached := false
	var distance := INF
	var bounds: AABB=evidence.sceneAudit.visualBounds
	# These are ordinary key states consumed by PlayerController. No automated
	# movement property, direct motor call or player transform write during act.
	if bool(player.get("automated_input")) or not player.is_physics_processing(): return {"reached":false,"reason":"ordinary_player_input_unavailable"}
	_movement_key(KEY_W,true)
	_movement_key(KEY_SHIFT,true)
	while Time.get_ticks_msec()<until and _within_deadline():
		await physics_frame
		await _frame()
		if _modal_loading_visible(): modal_loading_visible_frames+=1
		var position: Vector3=player.global_position
		distance=Vector2(maxf(maxf(bounds.position.x-position.x,position.x-bounds.end.x),0.0),maxf(maxf(bounds.position.z-position.z,position.z-bounds.end.z),0.0)).length()
		if distance<=8.0:
			reached=true; reason="close_exterior_reached"; break
		var now := Time.get_ticks_msec()
		_movement_key(KEY_SPACE,now<jump_until)
		_movement_key(KEY_W,now>=strafe_until)
		_movement_key(KEY_A,now<strafe_until and recovery_count%4==2)
		_movement_key(KEY_D,now<strafe_until and recovery_count%4==0)
		if now<next_sample: continue
		next_sample=now+1000
		var identity := _accepted_current()
		if not identity.passed: reason=String(identity.reason); break
		if now-begun>1000 and position.distance_to(previous)<0.30 and now>=strafe_until:
			recovery_count+=1
			if recovery_count%2==1: jump_until=now+250
			else: strafe_until=now+1500
		samples.append({"elapsedMsec":now-begun,"position":position,"distanceToVisualBounds":distance,"sprinting":player.get("is_sprinting"),"ordinaryWPressed":Input.is_key_pressed(KEY_W),"strafe":now<strafe_until,
			"recoveryCount":recovery_count,"motion":_approach_motion_snapshot(),"performance":_compact_performance_snapshot()})
		previous=position
		if not await _look_toward_candidate(): reason="approach_mouse_look_failed"; break
	_release_approach_keys()
	await physics_frame
	await _frame()
	await _look_toward_candidate()
	var identity := _accepted_current()
	var capsule := Clearance.inspect(player)
	evidence.closeVisibility=_inspect_visibility()
	var result_reason := reason if identity.passed and capsule.passed else "approach_identity_or_capsule_failed"
	if modal_loading_visible_frames>0: result_reason="modal_loading_visible_during_close_approach"
	return {"reached":reached and identity.passed and capsule.passed and modal_loading_visible_frames==0,"reason":result_reason,
		"elapsedMsec":Time.get_ticks_msec()-begun,"from":start_position,"to":player.global_position,"distanceToVisualBounds":distance,"samples":samples,"capsule":capsule,"identity":identity,
		"modalLoadingVisibleFrames":modal_loading_visible_frames,
		"keysReleased":not Input.is_key_pressed(KEY_W) and not Input.is_key_pressed(KEY_A) and not Input.is_key_pressed(KEY_D) and not Input.is_key_pressed(KEY_SPACE) and not Input.is_key_pressed(KEY_SHIFT),
		"scope":"Ordinary key-input approach from initial spawn; not interior/furniture interaction or NPC acceptance." if not spawn_cell.is_empty() else "Ordinary key-input approach after two setup teleports; not continuous travel from initial spawn, interior/furniture interaction or NPC acceptance."}

func _nearest_candidate(position: Vector3) -> Dictionary:
	var cell := Vector2i(floori(position.x/float(main.CELL)),floori(position.z/float(main.CELL)))
	var origin := Field.region_for_cell(cell)
	var found: Array[Dictionary] = []
	for z in range(origin.y-SEARCH_RING,origin.y+SEARCH_RING+1):
		for x in range(origin.x-SEARCH_RING,origin.x+SEARCH_RING+1):
			var value := Field.candidate_for_region(requested_seed,Vector2i(x,z))
			if value.is_empty(): continue
			var center: Vector2i = value.centerCell
			var distance := Vector2(center.x*float(main.CELL)-position.x,center.y*float(main.CELL)-position.z).length()
			found.append({"candidate":value,"distanceWorld":distance})
	found.sort_custom(func(a: Dictionary,b: Dictionary)->bool:
		return a.distanceWorld < b.distanceWorld or a.distanceWorld == b.distanceWorld and String(a.candidate.siteId) < String(b.candidate.siteId))
	return {"originRegion":origin,"ringRadius":SEARCH_RING,"regionsExamined":(SEARCH_RING*2+1)*(SEARCH_RING*2+1),"candidates":found,
		"selected":select_candidate(found,requested_region),"nearestWithinSearchOnly":requested_region.is_empty(),
		"requestedRegion":requested_region,"selectionMode":"nearest" if requested_region.is_empty() else "explicit_bounded_field_region","acceptedSiteNotGuaranteed":true}

static func valid_region_request(request: String) -> bool:
	if request.is_empty(): return true
	var fields := request.split(",")
	if fields.size()!=2: return false
	for field: String in fields:
		if field.is_empty() or field.length()>8 or not field.is_valid_int() or str(int(field))!=field: return false
		if int(field)<Field.MIN_REGION_COORD or int(field)>Field.MAX_REGION_COORD: return false
	return true

## Test-only selection among the already enumerated production candidates.
## Never creates a candidate, retries an absent site, or certifies eligibility.
static func select_candidate(found: Array[Dictionary], request: String) -> Dictionary:
	if not valid_region_request(request) or found.is_empty(): return {}
	if request.is_empty(): return found[0].candidate
	var fields := request.split(",")
	var selected_region := Vector2i(int(fields[0]),int(fields[1]))
	for row: Dictionary in found:
		if row.candidate.region==selected_region: return row.candidate
	return {}

func _place_outside(bounds: Rect2i,label: String) -> bool:
	if not spawn_cell.is_empty(): return false # Initial-location mode forbids all fixture transform writes.
	if placements.size() >= MAX_SETUP_WRITES or bounds.size.x <= 0 or bounds.size.y <= 0: return false
	var collider := player.get_node_or_null("PlayerCollider") as CollisionShape3D
	if collider == null or collider.disabled or not collider.shape is CapsuleShape3D: return false
	var capsule: CapsuleShape3D = collider.shape
	if not collider.global_basis.y.is_equal_approx(Vector3.UP): return false
	var cell_size := float(main.CELL)
	var radius := _capsule_radius()
	var margin := ceili(radius/cell_size)+3
	var old_cell := Vector2i(floori(player.global_position.x/cell_size),floori(player.global_position.z/cell_size))
	var clamped := Vector2i(clampi(old_cell.x,bounds.position.x,bounds.end.x-1),clampi(old_cell.y,bounds.position.y,bounds.end.y-1))
	if label=="accepted_reservation_exterior": clamped=bounds.position+bounds.size/2
	var choices: Array[Vector2i] = [Vector2i(bounds.position.x-margin,clamped.y),Vector2i(bounds.end.x+margin,clamped.y),Vector2i(clamped.x,bounds.position.y-margin),Vector2i(clamped.x,bounds.end.y+margin)]
	var heights: Dictionary={}
	var entry_choice := {}
	if label=="accepted_reservation_exterior":
		# The reservation is intentionally much larger than the visible
		# landmark. Its highest boundary point can be a real terrain cliff,
		# while the generated gate is an explicit collision-backed approach in
		# the immutable source. Stage on that gate axis, outside the reservation,
		# so the headed input test exercises a real exterior approach rather than
		# a blind hike across unrelated terrain.
		entry_choice = _accepted_gate_exterior_cell(bounds,margin)
		if entry_choice.is_empty():
			for choice: Vector2i in choices: heights[choice]=_staging_surface(choice,ceili(radius/cell_size))
	choices.sort_custom(func(a: Vector2i,b: Vector2i)->bool:
		if not entry_choice.is_empty():
			return a==entry_choice.get("cell") or b!=entry_choice.get("cell") and (a.x<b.x or a.x==b.x and a.y<b.y)
		if not heights.is_empty() and heights[a]!=heights[b]: return heights[a]>heights[b]
		return a.distance_squared_to(old_cell)<b.distance_squared_to(old_cell) or a.distance_squared_to(old_cell)==b.distance_squared_to(old_cell) and (a.x<b.x or a.x==b.x and a.y<b.y))
	var target := choices[0]
	var bare_view := Rect2i(target-Vector2i.ONE*VIEW_CELLS,Vector2i.ONE*(VIEW_CELLS*2+1))
	if bounds.has_point(target) or not bare_view.intersects(bounds): return false
	# Use current production generation over the capsule's real horizontal extent.
	# No terrain chunk creation, Source call, injected profile or guessed Y.
	var radius_cells := ceili(radius/cell_size)
	var surface := _staging_surface(target,radius_cells)
	var bottom_offset := collider.global_position.y-player.global_position.y-capsule.height*0.5
	var destination := Vector3(target.x*cell_size,surface-bottom_offset+capsule.radius*0.25,target.y*cell_size)
	if not destination.is_finite(): return false
	if placements.size()==1:
		var identity := _accepted_current()
		evidence.beforeSecondPlacement = identity
		checks.accepted_identity_before_second_placement = identity.passed and bounds==reservation
		if not checks.accepted_identity_before_second_placement: return false
	player.set_physics_process(false)
	var before := player.global_transform
	var placed := before
	placed.origin = destination
	player.global_transform = placed # The ONLY fixture player transform-write site.
	player.velocity = Vector3.ZERO # Setup only; no ongoing motion correction.
	placements.append({"index":placements.size()+1,"label":label,"elapsedMsec":_elapsed(),"from":before.origin,"to":destination,
		"cell":target,"excludedBounds":bounds,"ordinary112CellView":bare_view,"productionSurfaceY":surface,"capsuleBottomOffset":bottom_offset,
		"capsuleRadius":radius,"capsuleHeight":capsule.height,"physicsFrozen":true,
		"viewpointPolicy":"accepted source gate-axis exterior" if not entry_choice.is_empty() else "highest ordinary-ground side midpoint" if not heights.is_empty() else "nearest exterior",
		"acceptedGateExterior":entry_choice,"candidateGroundHeights":heights})
	return _outside(bounds)

## Find the real gate declared by the accepted immutable source, then project
## that entry axis beyond the reservation boundary. This is fixture placement
## only: publication, collision, movement and all later observations remain
## production-owned and the act phase still uses ordinary input exclusively.
func _accepted_gate_exterior_cell(bounds: Rect2i, margin: int) -> Dictionary:
	if source_binding.is_empty() or source_signature.is_empty(): return {}
	var source: Dictionary = main.structure_system.citadel_terrain_admission.prepared_sources().get(region,{})
	var blueprint: Dictionary = source.get("blueprint",{})
	var origin := Vector3.INF
	for profile: Dictionary in main.structure_system.citadel_terrain_admission.profile_store.snapshot():
		if profile.get("siteId")==source_binding.get("siteId") and profile.get("sourceSignature")==source_signature:
			origin=profile.get("origin",Vector3.INF)
			break
	if not origin.is_finite(): return {}
	for part: Dictionary in blueprint.get("parts",[]):
		var semantic := String(part.get("semantic",part.get("recipe",{}).get("semantic","")))
		if String(part.get("id",""))!="castle_gatehouse_portcullis" and semantic!="castle_portcullis": continue
		var position: Variant = part.get("position",Vector3.INF)
		if not position is Vector3 or not (position as Vector3).is_finite(): continue
		var entry := Vector2i(roundi((origin.x+(position as Vector3).x)/float(main.CELL)),roundi((origin.z+(position as Vector3).z)/float(main.CELL)))
		var center := bounds.get_center()
		var delta := Vector2(entry-center)
		var cell := Vector2i.ZERO
		if absf(delta.y)>=absf(delta.x):
			cell=Vector2i(clampi(entry.x,bounds.position.x,bounds.end.x-1),bounds.position.y-margin if delta.y<0.0 else bounds.end.y+margin)
		else:
			cell=Vector2i(bounds.position.x-margin if delta.x<0.0 else bounds.end.x+margin,clampi(entry.y,bounds.position.y,bounds.end.y-1))
		return {"cell":cell,"entryCell":entry,"entryPartId":String(part.get("id","")),"semantic":semantic,"profileOrigin":origin}
	return {}

func _staging_surface(cell: Vector2i, radius_cells: int) -> float:
	var surface := -INF
	for z in range(cell.y-radius_cells,cell.y+radius_cells+1):
		for x in range(cell.x-radius_cells,cell.x+radius_cells+1):
			surface=maxf(surface,float(main.surface_y_at_cell(Vector3i(x,0,z))))
	return surface

func _capsule_radius() -> float:
	var collider := player.get_node("PlayerCollider") as CollisionShape3D
	var capsule: CapsuleShape3D = collider.shape
	return capsule.radius*maxf(collider.global_basis.x.length(),collider.global_basis.z.length())

func _outside(bounds: Rect2i) -> bool:
	# Independently prove geometry; construction_allowed has a loading exemption
	# for disabled physics and therefore cannot certify diagnostic staging alone.
	if not is_instance_valid(player) or not player.is_inside_tree() or bounds.size.x<=0 or bounds.size.y<=0: return false
	var collider := player.get_node_or_null("PlayerCollider") as CollisionShape3D
	if collider==null or collider.disabled or not collider.shape is CapsuleShape3D: return false
	var capsule: CapsuleShape3D = collider.shape
	var center := collider.global_position
	var basis := collider.global_basis
	var cell_size := float(main.CELL)
	if not center.is_finite() or not basis.x.is_finite() or not basis.y.is_finite() or not basis.z.is_finite() or not is_finite(cell_size) or cell_size<=0.0: return false
	if basis.y.length_squared()<=0.0 or not is_zero_approx(basis.y.x) or not is_zero_approx(basis.y.z): return false
	var radius_x := capsule.radius*Vector2(basis.x.x,basis.z.x).length()
	var radius_z := capsule.radius*Vector2(basis.x.z,basis.z.z).length()
	if not is_finite(radius_x) or not is_finite(radius_z) or radius_x<=0.0 or radius_z<=0.0: return false
	var low := Vector2i(floori((center.x-radius_x)/cell_size),floori((center.z-radius_z)/cell_size))
	var high := Vector2i(ceili((center.x+radius_x)/cell_size)+1,ceili((center.z+radius_z)/cell_size)+1)
	if bounds.intersects(Rect2i(low,high-low)): return false
	var bindings = main.structure_system.citadel_runtime_bindings
	return bindings!=null and bindings.available() and bindings.construction_allowed(bounds)

func _owner_objects() -> Dictionary:
	if not is_instance_valid(main) or main.get("structure_system")==null or not is_instance_valid(main.get("npc_system")): return {}
	var structures = main.structure_system
	var autonomy = main.npc_system.autonomy_system
	if not is_instance_valid(autonomy): return {}
	var values := {"main":main,"player":main.player,"structures":structures,"admission":structures.citadel_terrain_admission,
		"store":structures.citadel_terrain_admission.profile_store,"service":structures.citadel_publication,
		"bindings":structures.citadel_runtime_bindings,"npc":main.npc_system,"autonomy":autonomy,
		"smart":autonomy.smart_objects,"portals":autonomy.door_portals,
		"runtime":main.get("voxel_terrain_runtime")}
	for key: String in values:
		if not is_instance_valid(values[key]):
			evidence.missingOwner=key
			return {}
	return values

func _tree_owner_current() -> bool:
	# Main creates this queue lazily when the first procedural tree is submitted.
	# A treeless startup is valid; once observed, replacement/loss is still fatal.
	var queue = main.tree_publication_queue
	if accepted_owners.has("trees"):
		return is_instance_valid(queue) and is_same(accepted_owners.trees.get_ref(),queue)
	if is_instance_valid(queue):
		accepted_owners.trees=weakref(queue)
		evidence.treeOwner={"instanceId":queue.get_instance_id(),"observedMsec":_elapsed()}
	return true

func _pin_accepted_owners() -> bool:
	var owners := _owner_objects()
	if owners.is_empty(): return false
	var ids := {}
	for key: String in owners:
		accepted_owners[key]=weakref(owners[key])
		ids[key]=owners[key].get_instance_id()
	evidence.acceptedIdentity={"binding":source_binding.duplicate(),"sourceSignature":source_signature,"reservationCells":reservation,"ownerInstanceIds":ids}
	return _tree_owner_current()

func _accepted_current() -> Dictionary:
	var owners := _owner_objects()
	if accepted_owners.is_empty() or owners.size()!=accepted_owners.size()-(1 if accepted_owners.has("trees") else 0): return {"passed":false,"reason":"accepted_owner_missing"}
	for key: String in accepted_owners:
		if key=="trees": continue
		if not is_same(accepted_owners[key].get_ref(),owners.get(key)): return {"passed":false,"reason":"accepted_owner_replaced:"+key}
	if not _tree_owner_current(): return {"passed":false,"reason":"accepted_owner_replaced:trees"}
	var source := _source_summary()
	if source.get("status") not in ["ready","prepared"]: return {"passed":false,"reason":String(source.get("reason","accepted_source_unavailable"))}
	if source.get("binding",{})!=source_binding or source.get("sourceSignature")!=source_signature or source.get("reservationCells")!=reservation:
		return {"passed":false,"reason":"accepted_source_identity_changed"}
	var admitted: Dictionary = owners.admission.stats()
	var publication: Dictionary = owners.service.stats()
	var generation := int(source_binding.get("generation",-1))
	if generation<0 or int(admitted.get("generation",-2))!=generation or int(publication.get("generation",-2))!=generation \
			or String(main.seed_text)!=requested_seed or admitted.get("worldSeed")!=requested_seed or publication.get("worldSeed")!=requested_seed \
			or not owners.runtime.generation_context_current() or not owners.bindings.available() or publication.get("worldResetPending",true):
		return {"passed":false,"reason":"accepted_generation_or_runtime_owner_changed"}
	var scene: Dictionary = owners.service.scene_state(region)
	if scene.get("status")=="failed": return {"passed":false,"reason":String(scene.get("reason","publication_failed"))}
	return {"passed":true,"reason":"accepted_source_and_owners_current","generation":generation,"sourceSignature":source_signature,"reservationCells":reservation}

func _source_summary() -> Dictionary:
	# source_state is explicitly non-enqueuing. Never retain/copy its source payload.
	var value: Dictionary = main.structure_system.citadel_terrain_admission.source_state(region)
	var result := {}
	for key: String in ["status","reason","binding","sourceSignature","reservationCells"]:
		if value.has(key): result[key] = value[key]
	return result

func _observe() -> Dictionary:
	if not is_instance_valid(main) or main.get("structure_system") == null: return {}
	var structures = main.structure_system
	var admission_stats: Dictionary = structures.citadel_terrain_admission.stats()
	var service_stats: Dictionary = structures.citadel_publication.stats()
	var value := {"source":_source_summary() if not candidate.is_empty() else {},
		"scene":structures.citadel_publication.scene_state(region) if not candidate.is_empty() else {},
		"admission":admission_stats,"publication":service_stats,
		"ownersAvailable":structures.citadel_runtime_bindings != null and structures.citadel_runtime_bindings.available()}
	# Read bounded existing loading telemetry; never drive readiness from the
	# observer. Preserve pending domains even when startup never completes.
	value["initialRegion"] = main.startup_readiness_domains.get("initial_region",{})
	value["regionalNavigationQueue"] = main.regional_navigation._stats()
	var navigation_owners: Dictionary = main.regional_navigation._owners(main)
	if not navigation_owners.is_empty():
		value["navigationPublicationWorker"] = navigation_owners.nav._publication_queue.stats()
		value["navigationPublicationAttempts"] = navigation_owners.publisher.last_navmesh_tile_queue_debug.duplicate(true)
		var demand_started := Time.get_ticks_usec()
		value["navigationDemandFacts"] = _navigation_demand_facts(navigation_owners)
		value["navigationDemandObservationUsec"] = Time.get_ticks_usec()-demand_started
	if is_instance_valid(player): value.playerPosition = player.global_position; value.playerPhysics = player.is_physics_processing()
	return value

func _navigation_demand_facts(owners: Dictionary) -> Array[Dictionary]:
	# Stored scheduling/acceptance facts only: never request a source, recompute
	# readiness or drive a queue from this observer. No geometry is retained.
	var regional = main.regional_navigation
	var publisher = owners.publisher
	var nav = owners.nav
	var keys: Array[String] = []
	var last_key := String(regional._last_tile_work.get("tileKey",""))
	if not last_key.is_empty(): keys.append(last_key)
	for key: String in regional._order:
		if keys.size() >= 8: break
		if regional._tiles[key].status != "ready" and not keys.has(key): keys.append(key)
	var rows: Array[Dictionary] = []
	for key: String in keys:
		var tile: Dictionary = regional._tiles.get(key,{})
		var context: Dictionary = publisher.queued_navmesh_tile_contexts.get(key,{})
		var region_id := "region:chunk:"+key
		var accepted: Dictionary = nav._accepted_tile_sources.get(region_id,{})
		var descriptor = nav.descriptors_by_region.get(region_id)
		var row := {"tileKey":key,"regionalStatus":tile.get("status",""),"regionalReason":tile.get("reason",""),
			"regionalSourceKey":tile.get("sourceKey",""),"regionalPriority":regional._priority(key),
			"queueSourceKey":publisher.queued_navmesh_tile_source_keys.get(key,""),
			"queuePosition":publisher.queued_navmesh_tile_keys.find(key),
			"queuePriority":publisher.queued_navmesh_tile_priority_keys.has(key),
			"deferred":publisher.deferred_navmesh_tile_keys.has(key),
			"firstQueuedFrame":context.get("firstQueuedFrame",-1),"queueSequence":context.get("queueSequence",-1),
			"ageFrames":Engine.get_process_frames()-int(context.firstQueuedFrame) if context.has("firstQueuedFrame") else -1,
			"acceptedPresent":not accepted.is_empty(),"dirty":nav.dirty_regions_by_region.has(region_id),
			"regionState":nav.region_states.get(region_id,""),"regionRidPresent":nav.region_rids_by_region.has(region_id),
			"emptyMarker":publisher.empty_navmesh_tile_keys.get(key,"")}
		if not accepted.is_empty():
			var snapshot: Dictionary = accepted.source.snapshot
			var receipt: Dictionary = nav._tile_publication_receipts.get(region_id,{})
			row["acceptedFacts"] = {"ownerMatches":accepted.owner.get_ref()==owners.adapter,
				"sourceKey":snapshot.get("sourceKey",""),"worldSeed":snapshot.get("worldSeed",""),
				"serial":accepted.serial,"empty":accepted.empty,
				"descriptorMatches":is_instance_valid(descriptor) and descriptor.get_instance_id()==accepted.descriptorId,
				"descriptorValid":is_instance_valid(descriptor) and descriptor.has_method("preparation_valid") and descriptor.preparation_valid(),
				"bindingMatches":nav._publication_bindings.get(region_id,{})==accepted.binding,
				"installationSerial":accepted.installationSerial,"receiptSerial":receipt.get("installationSerial",-1),
				"receiptSourceKey":receipt.get("sourceKey",""),"receiptDescriptorId":receipt.get("descriptorId",-1),
				"acceptedDescriptorId":accepted.descriptorId}
		rows.append(row)
	return rows

func _audit_scene() -> Dictionary:
	var service = main.structure_system.citadel_publication
	var site: Node3D = service.scene_root(region)
	var result := {"passed":false,"nodeCount":0,"meshes":0,"multiMeshes":0,"instances":0,"collisionShapes":0,"furnitureBodies":0,
		"urbanFurnitureBodies":0,"urbanHomeInteriorReady":false,"urbanHomeInteriors":[],"trees":0,"doors":0,"badBindings":[],"physicsProbes":[]}
	if not is_instance_valid(site) or site.get_parent()!=main: return result
	# Retain existing bounded counters once, after publication. These are
	# observations only and must never participate in scene acceptance.
	var publication_entry: Dictionary = service._scenes.get(region,{})
	if publication_entry.get("binding",{}) == source_binding and publication_entry.has("job"):
		var publication_job = publication_entry.job
		result["publicationJobMetrics"] = publication_job.status()
		# Packet mode does not retain one whole-scene `buildingBegin` result. Its
		# final packet would otherwise overwrite the source-preparation fields and
		# make a completed scene look unmeasured. Inspect the lifecycle telemetry
		# that owns the actual preparation/upload/install/commit work instead.
		var lifecycle: Dictionary = result.publicationJobMetrics
		var phases: Dictionary = lifecycle.get("phaseMetrics",{})
		var phase_summary := {}
		checks.preparation_timing_complete = int(lifecycle.get("advanceCalls",0))>0 \
			and int(lifecycle.get("advanceCpuUsec",-1))>=0 and int(lifecycle.get("physicalGroupsComplete",0))>0
		for phase_name: String in ["building_begin","building","publication_boundary","group_commit"]:
			var metric: Variant = phases.get(phase_name,{})
			var measured := metric is Dictionary and int(metric.get("units",0))>0 \
				and int(metric.get("maxAtomicUsec",-1))>=0 and int(metric.get("maxSliceUsec",-1))>=0
			checks.preparation_timing_complete = checks.preparation_timing_complete and measured
			phase_summary[phase_name] = metric if metric is Dictionary else {}
		result.preparationTimings = {"schema":"packet-publication-lifecycle/v1",
			"advanceCalls":lifecycle.get("advanceCalls",0),"advanceCpuUsec":lifecycle.get("advanceCpuUsec",0),
			"physicalGroupsComplete":lifecycle.get("physicalGroupsComplete",0),"phases":phase_summary}
		if publication_job._building != null:
			result["publicationTiming"] = publication_job._building.publication_timing()
			if publication_job._building._masonry_preparation != null:
				result["aperturePreparationMetrics"] = publication_job._building._masonry_preparation.metrics.duplicate(true)
	var expected_origin := Vector3.INF
	for profile: Dictionary in main.structure_system.citadel_terrain_admission.profile_store.snapshot():
		if profile.get("siteId") == candidate.siteId and profile.get("sourceSignature") == source_signature: expected_origin = profile.origin
	result.rootInstanceId = site.get_instance_id()
	result.rootVisible=site.is_visible_in_tree()
	result.visualBounds=AABB()
	result.visibleGeometry=0
	result.visualSamples=[]
	result.furnitureSamples=[]
	result.structureSamples=[]
	result.collisionMismatches=[]
	var source_parts := {}
	var seen_collisions := {}
	var accepted_source: Dictionary=main.structure_system.citadel_terrain_admission.prepared_sources().get(region,{})
	var accepted_blueprint: Dictionary=accepted_source.get("blueprint",{})
	var urban_live: Dictionary={}
	# Packet publication deliberately keeps non-foreground groups deferred.  This
	# headed audit compares every collider in the acknowledged packet closure to
	# its accepted source record; it must not require undispatched background
	# geometry merely because it exists in the same Citadel source.
	var published_building_members := {}
	if publication_entry.get("binding",{}) == source_binding and publication_entry.has("job"):
		var packet_job = publication_entry.job
		for group_id: String in packet_job._group_receipts:
			for member_key: String in packet_job._groups.get("groups",{}).get(group_id,{}).get("members",[]):
				# Publication groups use namespaced member keys so furniture and
				# building records cannot collide. Blueprint records use bare IDs.
				# Keep that translation at this diagnostic boundary; it must never
				# influence packet selection or physical publication.
				if member_key.begins_with("building:"):
					published_building_members[member_key.trim_prefix("building:")] = true
	result["collisionAuditScope"] = "acknowledged_packet_groups"
	result["acknowledgedPhysicalBuildingMembers"] = published_building_members.size()
	# One post-publication source capture for exact offline comparison. No runtime
	# injection and no timed generation/publication work is bypassed by this file.
	var source_path := output.path_join("accepted-source.bin")
	var source_started := Time.get_ticks_usec()
	var source_file := FileAccess.open(source_path,FileAccess.WRITE)
	if source_file==null:
		_evidence_failure("accepted-source.bin",FileAccess.get_open_error())
	else:
		source_file.store_var({"binding":source_binding,"blueprint":accepted_source.get("blueprint",{}),"furnishingPlan":accepted_source.get("furnishingPlan",{})},false)
		source_file.flush()
		var source_error := source_file.get_error()
		source_file.close()
		if source_error!=OK: _evidence_failure("accepted-source.bin",source_error)
		else: result["sourceCapture"]={"path":source_path,"sha256":FileAccess.get_sha256(source_path),"elapsedUsec":Time.get_ticks_usec()-source_started}
	for record: Dictionary in accepted_source.get("blueprint",{}).get("parts",[]):
		if record.get("collision",false) and published_building_members.has(String(record.id)):
			source_parts[record.id]=record
	var have_bounds := false
	result.rootPosition = site.global_position
	result.sourceOrigin = expected_origin
	result.rootMatchesProfile = expected_origin.is_finite() and site.global_transform.is_equal_approx(Transform3D(Basis.IDENTITY,expected_origin))
	var autonomy = main.npc_system.autonomy_system
	var portals = autonomy.door_portals
	var smart = autonomy.smart_objects
	var stack: Array[Node] = [site]
	while not stack.is_empty() and _within_deadline() and result.nodeCount < 100000:
		for unit in range(128):
			if stack.is_empty(): break
			var node: Node = stack.pop_back()
			if not is_instance_valid(node): result.badBindings.append("node_disappeared"); continue
			result.nodeCount += 1
			for child: Node in node.get_children(): stack.append(child)
			if node is MeshInstance3D and node.mesh != null: result.meshes += 1
			if node is MultiMeshInstance3D and node.multimesh != null:
				result.multiMeshes += 1; result.instances += node.multimesh.instance_count
			if node is MeshInstance3D and node.mesh!=null or node is MultiMeshInstance3D and node.multimesh!=null:
				var geometry := node as GeometryInstance3D
				var bounds: AABB=geometry.global_transform*geometry.get_aabb()
				if bounds.position.is_finite() and bounds.size.is_finite() and bounds.size.length_squared()>0.0:
					result.visualBounds=result.visualBounds.merge(bounds) if have_bounds else bounds
					have_bounds=true
				if geometry.is_visible_in_tree(): result.visibleGeometry+=1
				if result.visualSamples.size()<12:
					result.visualSamples.append({"path":str(site.get_path_to(geometry)),"visible":geometry.is_visible_in_tree(),"layers":geometry.layers,"rangeBegin":geometry.visibility_range_begin,"rangeEnd":geometry.visibility_range_end,"bounds":bounds})
			if node is CollisionShape3D and node.shape != null and not node.disabled:
				result.collisionShapes += 1
				if node.get_meta("building_collision_role","")=="blocking_part" and node.get_parent() is StaticBody3D:
					var part_id := String(node.get_meta("building_part_id",""))
					var record: Dictionary=source_parts.get(part_id,{})
					if record.is_empty() or seen_collisions.has(part_id): result.collisionMismatches.append(part_id)
					else:
						var expected: Transform3D=site.global_transform*Transform3D(Basis.from_euler(record.rotation),record.position)
						if not node.shape is BoxShape3D or node.shape.size!=record.size or not node.global_transform.is_equal_approx(expected): result.collisionMismatches.append(part_id)
						seen_collisions[part_id]=true
						var semantic := String(record.get("semantic",""))
						if semantic in ["castle_keep_stair_exit","castle_keep_stair_landing","castle_gatehouse_wall_stair_exit","castle_gatehouse_wall_stair_landing","citadel_upper_lane"] or part_id in ["urban_row_00_left_door","urban_row_00_right_door","urban_row_03_left_door","urban_row_03_right_door","castle_gatehouse_wall_stair_door","castle_gatehouse_portcullis","castle_keep_rear_secondary_door","urban_civic_house_wall_door"]:
							result.structureSamples.append({"id":part_id,"kind":record.kind,"semantic":semantic,"transform":node.global_transform,"size":record.size})
				if result.physicsProbes.size()<8 and node.get_parent() is StaticBody3D:
					var query := PhysicsShapeQueryParameters3D.new()
					query.shape = node.shape; query.transform = node.global_transform
					query.collision_mask = node.get_parent().collision_layer
					var hits := site.get_world_3d().direct_space_state.intersect_shape(query,64)
					var found := false
					for hit: Dictionary in hits:
						if hit.get("collider") == node.get_parent(): found = true
					result.physicsProbes.append({"bodyId":node.get_parent().get_instance_id(),"registeredInPhysics":found})
			if node is StaticBody3D and node.has_meta("furnishing_part_record"):
				result.furnitureBodies += 1
				var archetype := String(node.get_meta("furnishing_archetype",""))
				var furnishing_record: Dictionary=node.get_meta("furnishing_part_record")
				var furnishing_recipe: Dictionary=furnishing_record.get("recipe",{})
				if String(furnishing_recipe.get("castleResidenceFamily",""))=="urban_home":
					result.urbanFurnitureBodies += 1
					var home_id:=String(furnishing_recipe.get("citadelUrbanHomeId",""))
					var home: Dictionary=urban_live.get(home_id,{"id":home_id,"roomId":String(furnishing_record.get("roomId","")),"archetypes":{},"samples":[]})
					home.archetypes[archetype]=int(home.archetypes.get(archetype,0))+1
					if home.samples.size()<24:
						home.samples.append({"path":String(main.get_path_to(node)),"id":String(node.get_meta("furnishing_part_id","")),
							"archetype":archetype,"position":node.global_position,"occupiedSize":furnishing_record.get("occupiedSize",Vector3.ZERO)})
					urban_live[home_id]=home
				if result.furnitureSamples.size()<2 and not result.furnitureSamples.any(func(sample):return sample.archetype==archetype):
					result.furnitureSamples.append({"path":String(main.get_path_to(node)),"archetype":archetype,"id":String(node.get_meta("furnishing_part_id",""))})
			if node is StaticBody3D and node.has_meta("tree_visual_state"):
				result.trees += 1
				var prop_id := String(node.get_meta("prop_id",""))
				var registered = smart.registrations.get("prop:"+prop_id)
				if node.get_meta("tree_visual_state")!="published" or node.get_node_or_null("GeneratedTreeVisual")==null or registered==null or registered.node!=node:
					result.badBindings.append("tree:"+prop_id)
			if node is StaticBody3D and node.has_meta("door_portal_id"):
				result.doors += 1
				var portal_id := String(node.get_meta("door_portal_id"))
				var portal = portals.portal_for_door(node)
				var registered = smart.registrations.get(portal_id)
				if portals.door_to_portal.get(node.get_instance_id())!=portal_id or portal==null or not portal.leaf_nodes.has(node) or registered==null or registered.kind!="door" or not portal.leaf_nodes.has(registered.node):
					result.badBindings.append("door:"+portal_id)
		await _frame()
	result.ownersAvailable = main.structure_system.citadel_runtime_bindings.available() and _tree_owner_current() and (result.trees==0 or accepted_owners.has("trees"))
	result.sourceStillMatches = _source_summary().get("binding",{})==source_binding and service.scene_state(region).get("binding",{})==source_binding and service.scene_state(region).status=="scene_ready"
	result.capsule = Clearance.inspect(player)
	result.sourceCollisionCount=source_parts.size()
	result.publishedSourceCollisionCount=seen_collisions.size()
	# The count comparison below is the acceptance condition. Preserve a small,
	# deterministic census when it fails so a headed run identifies the omitted
	# source family without dumping thousands of records or guessing from a
	# screenshot.
	result.missingSourceCollisionIds=[]
	result.missingSourceCollisionSemantics={}
	for part_id: String in source_parts:
		if seen_collisions.has(part_id): continue
		if result.missingSourceCollisionIds.size()<48:
			result.missingSourceCollisionIds.append(part_id)
		var semantic := String(source_parts[part_id].get("semantic",""))
		result.missingSourceCollisionSemantics[semantic]=int(result.missingSourceCollisionSemantics.get(semantic,0))+1
	result.missingSourceCollisionIds.sort()
	var rooms_by_id: Dictionary={}
	for room_value in accepted_blueprint.get("rooms",[]):
		if room_value is Dictionary: rooms_by_id[String((room_value as Dictionary).get("id",""))]=room_value
	var required_archetypes: Array[String]=["bed","table","chair","hearth"]
	var complete_home_count:=0
	for descriptor_value in accepted_blueprint.get("recipe",{}).get("citadelUrbanHomes",[]):
		if not descriptor_value is Dictionary: continue
		var descriptor: Dictionary=descriptor_value as Dictionary
		var home_id:=String(descriptor.get("id",""))
		var room_id:=String(descriptor.get("roomId",""))
		var live: Dictionary=urban_live.get(home_id,{"id":home_id,"roomId":room_id,"archetypes":{},"samples":[]})
		var room: Dictionary=rooms_by_id.get(room_id,{})
		var local_bounds: AABB=room.get("bounds",AABB())
		var complete:=not room.is_empty() and required_archetypes.all(func(archetype):return int(live.archetypes.get(archetype,0))>0)
		if complete: complete_home_count+=1
		result.urbanHomeInteriors.append({"id":home_id,"roomId":room_id,"streetSide":descriptor.get("streetSide",0.0),
			"worldBounds":site.global_transform*local_bounds,"archetypes":live.archetypes,"samples":live.samples,"complete":complete})
	result.urbanHomeInteriorReady=complete_home_count>=2 and result.urbanFurnitureBodies>0
	result["completeUrbanHomeInteriorCount"]=complete_home_count
	result["generatedUrbanHomeCount"]=(accepted_blueprint.get("recipe",{}).get("citadelUrbanHomes",[]) as Array).size()
	result.passed = stack.is_empty() and result.rootMatchesProfile and result.rootVisible and result.visibleGeometry>0 and have_bounds and result.ownersAvailable and result.sourceStillMatches and result.badBindings.is_empty() and result.meshes+result.instances>0 and result.collisionShapes>0 and result.furnitureBodies>0 and result.urbanHomeInteriorReady and result.doors>0 and not result.physicsProbes.is_empty() and result.physicsProbes.all(func(p):return p.registeredInPhysics) and result.capsule.passed
	result.passed = result.passed and result.collisionMismatches.is_empty() and source_parts.size()==seen_collisions.size() and not source_parts.is_empty()
	return result

func _audit_stair_clearance() -> Dictionary:
	var observations := []
	var capsule := CapsuleShape3D.new()
	capsule.radius=0.42; capsule.height=1.72
	for sample: Dictionary in evidence.sceneAudit.get("structureSamples",[]):
		# Door inspection views are not standing surfaces. Preserve every stair
		# landing probe when adding other source parts to the capture inventory.
		if sample.kind != "floor" or not String(sample.semantic).begins_with("castle_"): continue
		var pose: Transform3D=sample.transform
		var lateral: float=(float(sample.size.x)+0.18)*0.20
		for offset: float in [-lateral,0.0,lateral]:
			var expected: Vector3=pose*Vector3(offset,sample.size.y*0.5,0)
			var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
			var support := space.intersect_ray(PhysicsRayQueryParameters3D.create(expected+Vector3.UP*0.24,expected-Vector3.UP*0.24,player.collision_mask,[player.get_rid()]))
			var blockers := []
			if support.is_empty(): blockers.append("missing_walkable_support")
			else:
				var query := PhysicsShapeQueryParameters3D.new()
				query.shape=capsule; query.collision_mask=player.collision_mask; query.exclude=[player.get_rid()]
				var slope_lift: float=capsule.radius*(1.0/maxf(support.normal.y,0.01)-1.0)
				query.transform=Transform3D(Basis.IDENTITY,support.position+Vector3.UP*(capsule.height*0.5+slope_lift+0.02))
				for hit: Dictionary in space.intersect_shape(query,32):
					var collider: CollisionObject3D=hit.collider
					var owner: Object=collider.shape_owner_get_owner(collider.shape_find_owner(hit.shape))
					blockers.append(String(owner.get_meta("building_part_id",str(collider.get_path()))) if owner!=null else str(collider.get_path()))
			observations.append({"id":sample.id,"offset":offset,"expected":expected,"support":support.get("position"),"blockers":blockers,"passed":blockers.is_empty()})
	return {"passed":not observations.is_empty() and observations.all(func(row):return row.passed),"observations":observations,"scope":"Actual Main scene physics queries with player-sized capsule; no traversal or interaction claim."}

func _look_toward_candidate() -> bool:
	# Camera adjustment uses the ordinary viewport mouse-look consumer. No camera
	# transform write, detached observer, clock/light override or OS input automation.
	# Headed capture can temporarily release OS mouse capture. Reacquire it only
	# through the production modal-aware command; a real open modal still blocks
	# the input and remains a failure.
	main.capture_mouse_if_no_modal()
	await _frame()
	var attempts := 0
	var initial_error := _candidate_yaw_error()
	for attempt in range(12):
		var error := _candidate_yaw_error()
		var pitch_error := _candidate_pitch_error()
		if absf(error)<0.03 and absf(pitch_error)<0.03: break
		var sensitivity := float(player.get("mouse_sensitivity"))
		if sensitivity<=0.0: break
		var motion := InputEventMouseMotion.new()
		motion.relative = Vector2(clampf(-error/sensitivity,-600,600),clampf(-pitch_error/sensitivity,-600,600)*( -1.0 if bool(player.get("invert_y")) else 1.0))
		root.push_input(motion)
		attempts += 1
		await _frame()
	var final_error := _candidate_yaw_error()
	var final_pitch := _candidate_pitch_error()
	var passed := is_finite(final_error) and absf(final_error)<0.03 and is_finite(final_pitch) and absf(final_pitch)<0.03
	var modal_state := {
		"inventory":main.hud.is_inventory_open(),"utility":main.hud.is_utility_open(),
		"teleport":main.hud.is_teleport_open(),"objectives":main.hud.is_objectives_open(),
		"contracts":main.hud.is_contracts_open(),"settings":main.hud.is_settings_open(),
		"playtest":main.hud.is_playtest_open(),"gameMenu":main.hud.is_game_menu_open(),
		"dialogue":main.hud.is_dialogue_open()
	}
	evidence.cameraLook = {"passed":passed,"inputEvents":attempts,"initialYawErrorRadians":initial_error,"finalYawErrorRadians":final_error,
		"finalPitchErrorRadians":final_pitch,"target":_inspection_target(),
		"toleranceRadians":0.03,"ordinaryMouseGuardAccepts":main.should_accept_mouse_look(),
		"mouseMode":Input.get_mouse_mode(),"modalState":modal_state,"guardBypassed":false}
	return passed

func _candidate_yaw_error() -> float:
	var target := _inspection_target()
	var direction := target-player.global_position
	return wrapf(atan2(-direction.x,-direction.z)-player.global_rotation.y,-PI,PI)

func _inspection_target() -> Vector3:
	var bounds: AABB=evidence.get("sceneAudit",{}).get("visualBounds",AABB())
	return bounds.get_center() if bounds.size.length_squared()>0.0 else Vector3(candidate.centerCell.x*float(main.CELL),player.global_position.y,candidate.centerCell.y*float(main.CELL))

func _candidate_pitch_error() -> float:
	var camera: Camera3D=player.get_node("Camera3D")
	var direction := _inspection_target()-camera.global_position
	return atan2(direction.y,Vector2(direction.x,direction.z).length())-float(player.get("pitch"))

func _inspect_visibility() -> Dictionary:
	var camera := root.get_camera_3d()
	var site: Node3D=main.structure_system.citadel_publication.scene_root(region)
	if camera==null or site==null: return {"available":false}
	var bounds: AABB=evidence.sceneAudit.visualBounds
	var points: Array[Vector3]=[bounds.get_center()]
	for index in range(8): points.append(bounds.get_endpoint(index))
	var samples: Array=[]
	for target: Vector3 in points:
		var query := PhysicsRayQueryParameters3D.create(camera.global_position,target,player.collision_mask,[player.get_rid()])
		var hit := site.get_world_3d().direct_space_state.intersect_ray(query)
		var collider: Node=hit.get("collider")
		samples.append({"target":target,"inFrustum":camera.is_position_in_frustum(target),"screen":camera.unproject_position(target),
			"hit":hit.get("position"),"hitPath":str(collider.get_path()) if is_instance_valid(collider) else "","hitCitadel":is_instance_valid(collider) and (collider==site or site.is_ancestor_of(collider)),
			"terrainSurfaceY":main.surface_y_at_position(target)})
	return {"available":true,"activeCamera":str(camera.get_path()),"isPlayerCamera":camera==player.get_node("Camera3D"),"transform":camera.global_transform,
		"projection":camera.get_camera_projection(),"cullMask":camera.cull_mask,"near":camera.near,"far":camera.far,"rootVisible":site.is_visible_in_tree(),"bounds":bounds,"samples":samples,
		"scope":"Frustum, visibility and collision-ray observations only; screenshot inspection remains required."}

func _startup_completed() -> void: startup_ready = true
func _startup_failed(message: String) -> void: startup_failure = message
func _startup_step(message: String) -> void:
	# Startup can repeat collision waits every frame. Aggregate exact messages
	# separately; never spend source/publication transition slots on this stream.
	startup_message_count += 1
	var now_usec := Time.get_ticks_usec()
	if startup_message_index.has(message):
		var index: int = startup_message_index[message]
		startup_messages[index].count += 1
		startup_messages[index].lastElapsedMsec = _elapsed()
		startup_messages[index].lastUsec = now_usec
		return
	if startup_messages.size()>=128:
		startup_message_overflow += 1
		return
	startup_message_index[message]=startup_messages.size()
	startup_messages.append({"message":message,"count":1,"firstElapsedMsec":_elapsed(),"lastElapsedMsec":_elapsed(),
		"firstUsec":now_usec,"lastUsec":now_usec})

func _append_timeline(entry: Dictionary) -> void:
	if timeline.size()>=256:
		timeline.pop_front()
		timeline_dropped += 1
	timeline.append(entry)

func _within_deadline() -> bool: return evidence_error.is_empty() and Time.get_ticks_msec()<deadline
func _elapsed() -> int: return Time.get_ticks_msec()-started

func _compact_performance_snapshot() -> Dictionary:
	# Movement evidence must not deep-copy and sort the monitor's ten-second
	# section/counter history inside the measured approach. The render observer
	# records every presented-frame interval independently.
	if main.runtime_perf_monitor==null: return {}
	var monitor=main.runtime_perf_monitor
	return {"frameMetricScope":"Main game script _process callback only; compact live sample.",
		"frameMs":monitor.last_frame_ms,"lastSpikeReason":String(monitor.last_spike.get("reason","")),
		"lastSpikeFrameMs":float(monitor.last_spike.get("frameMs",0.0)),"sampleCount":monitor.frame_samples.size()}

func _frame() -> void:
	await process_frame
	if Time.get_ticks_msec()>=next_progress:
		next_progress = Time.get_ticks_msec()+1000
		var compact_movement_observer := phase=="ordinary_input_approach"
		var observation_started := Time.get_ticks_usec()
		if compact_movement_observer:
			# This progress heartbeat observes only bounded values already owned by
			# production. Full service graphs and JSON statistics are collected
			# outside the player-visible performance phase.
			last_observation={"source":_source_summary(),
				"scene":main.structure_system.citadel_publication.scene_state(region),
				"playerPosition":player.global_position if is_instance_valid(player) else Vector3.ZERO,
				"playerPhysics":player.is_physics_processing() if is_instance_valid(player) else false,
				"runtimePerformance":_compact_performance_snapshot(),
				"observationScope":"bounded movement heartbeat; full observer deferred"}
		else:
			last_observation = _observe()
		last_observation["observationUsec"]=Time.get_ticks_usec()-observation_started
		if main.structure_system != null and main.structure_system.citadel_terrain_admission != null:
			last_observation["citadelSourceTiming"] = main.structure_system.citadel_terrain_admission.source_timing()
		if not compact_movement_observer:
			var demand_sample := {"elapsedMsec":_elapsed(),"usec":Time.get_ticks_usec(),"phase":phase,
				"facts":last_observation.get("navigationDemandFacts",[]),
				"observationUsec":last_observation.get("navigationDemandObservationUsec",0),
				"worker":last_observation.get("navigationPublicationWorker",{})}
			# Preserve startup context and the terminal interval. A first-N cap lost
			# the decisive late acceptance/acknowledgement evidence on long runs.
			if navigation_demand_samples.size() >= 256:
				navigation_demand_samples.remove_at(128)
				navigation_demand_samples_dropped += 1
			navigation_demand_samples.append(demand_sample)
		# Once per progress tick: actual engine gauges, never summed frame counters.
		if not compact_movement_observer and Engine.has_singleton("VoxelEngine"):
			var voxel_engine = Engine.get_singleton("VoxelEngine")
			var sample := {"elapsedMsec":_elapsed(),"phase":phase,"stats":voxel_engine.get_stats()}
			last_observation["voxelWorkers"] = sample
			if worker_samples.size()<720: worker_samples.append(sample)
			else: worker_samples_dropped += 1
		if not compact_movement_observer and main.runtime_perf_monitor != null:
			last_observation.runtimePerformance = main.runtime_perf_monitor.summary()
		var state_key := phase+":"+String(last_observation.get("source",{}).get("status",""))+":"+String(last_observation.get("scene",{}).get("status",""))
		if state_key!=last_timeline_state:
			last_timeline_state=state_key
			_append_timeline({"elapsedMsec":_elapsed(),"phase":phase,"source":last_observation.get("source",{}),"scene":last_observation.get("scene",{})})
		_write("progress.json",{"elapsedMsec":_elapsed(),"phase":phase,"placementCount":placements.size(),"observation":last_observation})

func _capture(label: String, camera_kind := "ordinary_player_viewport") -> bool:
	if DisplayServer.get_name()=="headless":
		captures.append({"label":label,"saved":false,"reason":"headless_capture_skipped","elapsedMsec":_elapsed()})
		return false # Headless servers need not ever emit frame_post_draw.
	if is_instance_valid(render_observation): render_observation.phase = "capture:"+label
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := output.path_join(label+".png")
	var code := ERR_UNAVAILABLE
	if image!=null and not image.is_empty(): code=image.save_png(path)
	if is_instance_valid(render_observation): render_observation.phase = phase
	captures.append({"label":label,"path":path,"saved":code==OK,"error":code,"elapsedMsec":_elapsed(),
		"playerPosition":player.global_position if is_instance_valid(player) else Vector3.ZERO,"camera":camera_kind,
		"cameraTransform":root.get_camera_3d().global_transform if root.get_camera_3d()!=null else Transform3D.IDENTITY,"inspectionRequired":true})
	if code!=OK: _evidence_failure(label+".png",code)
	return code==OK

func _checkpoint_fields(value: Dictionary, fields: Array[String]) -> Dictionary:
	# Whitelisted value types only: never retain a source graph or live owner.
	var result: Dictionary = {}
	for key: String in fields:
		if value.has(key) and typeof(value[key]) in [TYPE_NIL,TYPE_BOOL,TYPE_INT,TYPE_FLOAT,TYPE_STRING,
				TYPE_VECTOR2,TYPE_VECTOR2I,TYPE_VECTOR3,TYPE_VECTOR3I,TYPE_RECT2I]:
			result[key] = value[key]
	return result

func _checkpoint_missing(regional: Dictionary) -> Dictionary:
	var rows: Array[Dictionary] = []
	var domains: Dictionary = regional.get("domains",{})
	var domain_rows: Array[Dictionary] = []
	var observed_count: int = 0
	# At most eight known domain summaries and sixteen missing rows in total.
	# Counts disclose truncation; nested proof/requirements graphs are excluded.
	var sources: Array[Dictionary] = [{"domain":"regional","value":regional}]
	for key: Variant in domains.keys().slice(0,8):
		if domains[key] is Dictionary: sources.append({"domain":String(key),"value":domains[key]})
	for source: Dictionary in sources:
		var value: Dictionary = source.value
		var domain_row: Dictionary = _checkpoint_fields(value,["status","reason","publicationAcknowledged"])
		domain_row["domain"] = source.domain
		if source.domain != "regional": domain_rows.append(domain_row)
		var missing: Array = value.get("missing",[])
		observed_count += missing.size()
		for item: Variant in missing.slice(0,maxi(0,16-rows.size())):
			if not item is Dictionary: continue
			var row: Dictionary = _checkpoint_fields(item,["domain","tileKey","sourceId","status","reason"])
			if not row.has("domain"): row["domain"] = source.domain
			rows.append(row)
	return {"domains":domain_rows,"domainCount":domains.size(),"domainsDropped":maxi(0,domains.size()-8),
		"missing":rows,"observedMissingCount":observed_count,"missingRowsDropped":observed_count-rows.size()}

func _write_approach_checkpoint() -> bool:
	# One synchronous snapshot after ordinary input and close capture, before
	# fallible long inspection/audit work. It is never a final acceptance report.
	var snapshot_usec: int = Time.get_ticks_usec()
	var approach: Dictionary = evidence.get("approach",{})
	var original_samples: Array = approach.get("samples",[])
	var samples: Array[Dictionary] = []
	for sample: Dictionary in original_samples.slice(0,48):
		var row: Dictionary = _checkpoint_fields(sample,["elapsedMsec","position","distanceToVisualBounds",
			"sprinting","ordinaryWPressed","strafe","recoveryCount"])
		var motion: Dictionary = sample.get("motion",{})
		row["motion"] = _checkpoint_fields(motion,["velocity","onFloor","terrainGrounded","terrainHold","groundY"])
		var proof: Dictionary = motion.get("terrainProof",{})
		row.motion["proof"] = _checkpoint_fields(proof,["passed","reason"])
		row.motion.proof["regional"] = _checkpoint_missing(proof.get("regionalPublication",{}))
		row["performance"] = _checkpoint_fields(sample.get("performance",{}),["frameMs","frameMaxMs",
			"frameP95Ms","frameP99Ms","lastSpikeReason","lastSpikeFrameMs","sampleCount","frameMetricScope"])
		samples.append(row)
	var approach_summary: Dictionary = _checkpoint_fields(approach,["reached","reason","elapsedMsec","from","to",
		"distanceToVisualBounds","keysReleased","scope"])
	approach_summary["identity"] = _checkpoint_fields(approach.get("identity",{}),["passed","reason","generation","sourceSignature","reservationCells"])
	approach_summary["capsule"] = _checkpoint_fields(approach.get("capsule",{}),["passed","reason"])
	approach_summary["samples"] = samples
	approach_summary["sampleCount"] = original_samples.size()
	approach_summary["samplesDropped"] = maxi(0,original_samples.size()-samples.size())
	var publication: Dictionary = main.structure_system.citadel_publication.stats()
	var scene: Dictionary = main.structure_system.citadel_publication.scene_state(region)
	var physical_proof: Dictionary = {}
	var entry: Dictionary = main.structure_system.citadel_publication._scenes.get(region,{})
	if entry.get("job") != null and entry.get("binding",{}) == source_binding:
		var job_status: Dictionary = entry.job.status()
		physical_proof = job_status.get("physicalProof",{}).duplicate(true)
	var render_summary: Dictionary = render_observation.summary() if is_instance_valid(render_observation) else {}
	var runtime_summary: Dictionary = main.runtime_perf_monitor.summary() if main.runtime_perf_monitor != null else {}
	var checkpoint: Dictionary = {"schema":"citadel-approach-checkpoint/v1","complete":false,"passed":false,
		"checkpointComplete":true,"checkpoint":"after_ordinary_approach_and_close_capture","snapshotUsec":snapshot_usec,
		"elapsedMsec":_elapsed(),"startupElapsedMsec":startup_elapsed,"testElapsedMsec":Time.get_ticks_msec()-test_started,
		"completedPhases":["ordinary_new_game_startup","ordinary_scene_publication","ordinary_input_approach","capture:close"],
		"unevaluatedPhases":["diagnostic_visual_inspection","diagnostic_navigation_publication","shutdown"],
		"checksAtCheckpoint":checks.duplicate(true),"seed":requested_seed,"actualSeed":String(main.seed_text),
		"candidate":candidate.duplicate(true),"binding":source_binding.duplicate(true),"sourceSignature":source_signature,
		"reservationCells":reservation,"declaredInfluence":declared,"launchOptions":main.launch_options.duplicate(true),
		"requestedRegion":requested_region,"requestedSpawnCell":spawn_cell,"placementMode":"initial_spawn" if not spawn_cell.is_empty() else "teleport",
		"setupPlacementCount":placements.size(),"captures":captures.duplicate(true),"approach":approach_summary,
		"startupMessages":{"records":startup_messages.duplicate(true),"totalMessages":startup_message_count,"unrecordedMessages":startup_message_overflow},
		"synchronousSetupSpans":main.diagnostic_setup_spans.duplicate(true),"renderObservation":render_summary,
		"runtimePerformance":runtime_summary,"scene":_checkpoint_fields(scene,["status","reason","gameplayReady"]),
		"publication":_checkpoint_fields(publication,["sceneStartedCount","sceneCompletedCount","sceneMaxStepUsec","maxAdvanceUsec","activeToken","publicationReady"]),
		# Worker stats contain bounded scalar progress and <=8 selected/pending keys;
		# this is the SOURCE worker, not the downstream navigation upload worker.
		"sourcePublicationWorker":publication.get("worker",{}).duplicate(true),"physicalProof":physical_proof,
		"bounds":{"approachSamples":48,"missingRowsPerSample":16,"domainsPerSample":8,"startupMessages":128},
		"doesNotProve":"Incomplete diagnostic only: no final navigation audit, inspection, shutdown, interior/NPC traversal or gameplay/performance acceptance. Main frame metrics are a rolling callback window; render cadence is not OS presentation timing."}
	var previous_phase: String = phase
	phase = "diagnostic_checkpoint_write"
	var written: bool = _write("approach-checkpoint.json",checkpoint)
	phase = previous_phase
	return written

func _write(name: String,value: Dictionary) -> bool:
	var file := FileAccess.open(output.path_join(name),FileAccess.WRITE)
	if file==null:
		_evidence_failure(name,FileAccess.get_open_error()); return false
	file.store_string(JSON.stringify(value,"\t")); file.flush()
	var error := file.get_error()
	file.close()
	if error!=OK: _evidence_failure(name,error)
	return error==OK

func _evidence_failure(name: String,error: int) -> void:
	if not evidence_error.is_empty(): return
	evidence_error={"passed":false,"reason":"evidence_write_failed","file":name,"error":error,"phase":phase,"elapsedMsec":_elapsed()}
	# Best effort independent failure receipt, never recursively call _write.
	# If the entire directory/storage is unavailable the engine log + watchdog
	# remain authoritative: immediate ERROR stops the owned job, never a pass.
	var fallback := FileAccess.open(output.path_join("evidence-failure.json"),FileAccess.WRITE)
	if fallback!=null:
		fallback.store_string(JSON.stringify(evidence_error)); fallback.flush(); fallback.close()
	push_error("Citadel diagnostic evidence failure: "+JSON.stringify(evidence_error))

func _finish(outcome: String,reason: String) -> void:
	if finished: return
	_release_approach_keys()
	finished = true
	if not spawn_cell.is_empty() and is_instance_valid(main):
		evidence.initialSpawn = main.diagnostic_spawn_evidence.duplicate(true)
	if is_instance_valid(main):
		evidence.synchronousSetupSpans = main.diagnostic_setup_spans.duplicate(true)
		evidence.synchronousSetupScope = "Fixture-only timing of inherited setup calls; same order and work, no yields. Absolute monotonic clock, first 32 spans."
		evidence.startupReadiness = main.startup_readiness_domains.duplicate(true)
		evidence.startupFailure = main.startup_loading_failure_result.duplicate(true)
		if main.streaming_request_bounds.has("player"):
			evidence.regionalReadiness = main.world_streaming.region_readiness(main.streaming_request_bounds.player)
		if main.streaming_request_foreground_bounds.has("player"):
			evidence.foregroundRegionalReadiness = main.world_streaming.region_readiness(
				main.streaming_request_foreground_bounds.player,int(main.streaming_requests.get("player",-1)))
	phase = "terminal_"+outcome
	_append_timeline({"elapsedMsec":_elapsed(),"phase":phase,"outcome":outcome,"reason":reason})
	if outcome!="scene_ready" and evidence_error.is_empty(): await _capture("failed")
	checks.evidence_writes_succeeded=evidence_error.is_empty()
	checks.all_captures_saved = not captures.is_empty() and captures.all(func(c):return c.saved)
	checks.setup_write_limit = placements.is_empty() if not spawn_cell.is_empty() else (placements.size()==MAX_SETUP_WRITES if outcome=="scene_ready" else placements.size()<=MAX_SETUP_WRITES)
	if is_instance_valid(main) and main.runtime_perf_monitor != null:
		evidence.runtimePerformance = main.runtime_perf_monitor.summary()
	if is_instance_valid(render_observation):
		evidence.renderObservation = render_observation.summary()
		render_observation.stop()
	var passed := outcome=="scene_ready" and not checks.values().has(false)
	var report_written := _write("report.json",{"schema":"citadel-candidate-teleport-playtest/v1","passed":passed,"outcome":outcome,"reason":reason,"checks":checks,"evidenceWriteFailure":evidence_error,
		"seed":requested_seed,"actualSeed":main.get("seed_text") if is_instance_valid(main) else "","elapsedMsec":_elapsed(),"engine":Engine.get_version_info(),
		"startupElapsedMsec":startup_elapsed if test_started>0 else _elapsed(),"testElapsedMsec":Time.get_ticks_msec()-test_started if test_started>0 else 0,
		"launchOptions":main.launch_options if is_instance_valid(main) else {},
		"placementMode":"initial_spawn" if not spawn_cell.is_empty() else "teleport","initialSpawn":evidence.get("initialSpawn",{}),
		"originalPlayerPosition":original_position,"search":search,"candidate":candidate,"declaredInfluence":declared,"acceptedReservation":reservation,
		"setupPlacements":placements,"captures":captures,"timeline":timeline,"timelineDropped":timeline_dropped,
		"voxelWorkerSamples":worker_samples,"voxelWorkerSamplesDropped":worker_samples_dropped,
		"navigationDemandSamples":navigation_demand_samples,"navigationDemandSamplesDropped":navigation_demand_samples_dropped,
		"startupMessages":{"records":startup_messages,"totalMessages":startup_message_count,"unrecordedMessages":startup_message_overflow,"aggregation":"exact message; count and first/last timestamps, separate from phase timeline"},
		"evidence":evidence,"finalObservation":_observe(),
		"evidenceLevel":"headed initial-location New Game diagnostic; title UI bypassed; ordinary observer admission and service publication" if not spawn_cell.is_empty() else "headed teleport-assisted diagnostic using production New Game systems, ordinary observer admission and service publication",
		"fixtureChanges":["Main seed and optional initial spawn selection before attachment; no generated artifact prewarm","zero setup teleports; production startup physics readiness" if not spawn_cell.is_empty() else "up to two counted setup exterior teleports and setup physics freeze","ordinary viewport mouse-look events for player approach","bounded ordinary W/Shift approach with brief jumps and lateral recovery","labelled diagnostic inspection cameras after player approach","isolated ordinary save directory"],
		"doesNotProve":["continuous travel from tutorial town","NPC routing or door traversal","live gameplay acceptance","all geometry collision or visual correctness","performance acceptance; captures and audits add overhead"],
		"manualInspectionSeconds":manual_seconds,
		"shutdown":"manual inspection follows readiness; user exit or bounded session expiry" if manual_seconds>0 and passed else "ordinary Main.request_graceful_quit requested after report; owned watchdog is cleanup authority"})
	passed=passed and report_written
	print("CITADEL CANDIDATE TELEPORT outcome=",outcome," reason=",reason," placements=",placements.size()," passed=",passed)
	if passed and manual_seconds>0:
		phase="manual_inspection"
		player.camera.make_current()
		var ready := {"phase":phase,"ready":true,"manualAcceptance":"not evaluated","durationSeconds":manual_seconds,
			"playerPosition":player.global_position,"controls":"WASD move, mouse look, Shift sprint, Space jump, right-click use/interact, Esc menu; close game when finished"}
		if not _write("manual-ready.json",ready):
			main.request_graceful_quit(1); return
		_write("progress.json",ready)
		main.show_action_message("Citadel ready — manual controls enabled (30 minutes)")
		print("CITADEL MANUAL READY: ordinary controls enabled for ",manual_seconds," seconds; close game when finished")
		await create_timer(float(manual_seconds)).timeout
		if is_instance_valid(main): main.request_graceful_quit(0)
		return
	if is_instance_valid(main): main.request_graceful_quit(0 if passed else 1)
	else: quit(1)

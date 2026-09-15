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
const SurvivalPolicy = preload("res://scripts/testing/PlaytestSurvivalPolicy.gd")
const SEARCH_RING := 2
const VIEW_CELLS := 112
const MAX_SETUP_WRITES := 2
const FAR_SOURCE_DISCOVERY_APPROACH_METERS := 800.0
const SCALE_SOAK_CYCLES := 3
const SCALE_SOAK_AWAY_METERS := 460.0
const SCALE_SOAK_SAMPLE_MSEC := 10000

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
var scale_soak_seconds := 0
var player_inspection_only := false
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
	scale_soak_seconds=int(OS.get_environment("CITADEL_CANDIDATE_SCALE_SOAK_SECONDS"))
	player_inspection_only=OS.get_environment("CITADEL_CANDIDATE_PLAYER_INSPECTION_ONLY")=="1"
	if manual_seconds not in [0,1800]:
		printerr("Invalid manual inspection allowance"); quit(2); return
	if (scale_soak_seconds!=0 and (scale_soak_seconds<180 or scale_soak_seconds>1800)) \
			or (manual_seconds>0 and scale_soak_seconds>0) or (player_inspection_only and (manual_seconds>0 or scale_soak_seconds>0)):
		printerr("Invalid scale soak allowance"); quit(2); return
	if output.is_empty() or not output.is_absolute_path() or limit < 90 or limit > 1200 or startup_limit < 15 or startup_limit > 180:
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
	if scale_soak_seconds>0 or player_inspection_only:
		# This gate observes streaming ownership for as long as 30 minutes. Protect
		# the production player from starvation/death without altering movement,
		# collision, world time, weather, hostiles, NPCs or autosave behavior.
		evidence.scaleSoakSurvivalPolicy=SurvivalPolicy.enable_player_god_mode(main,"citadel_scale_retirement_soak")
		checks.scale_soak_survival_policy=evidence.scaleSoakSurvivalPolicy.get("enabled",false) \
			and evidence.scaleSoakSurvivalPolicy.get("reason","")=="citadel_scale_retirement_soak" \
			and evidence.scaleSoakSurvivalPolicy.get("scope","")=="player_survival_damage_only"
		if not checks.scale_soak_survival_policy:
			await _finish("failed",String(evidence.scaleSoakSurvivalPolicy.get("failure","scale_soak_survival_policy_failed"))); return
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
	if scale_soak_seconds>0:
		evidence.scaleSoakProcessBaseline=await _resource_census("process_baseline")
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
	var discovery_motion := not spawn_cell.is_empty() and float(search.get("selectedDistanceWorld",0.0))>FAR_SOURCE_DISCOVERY_APPROACH_METERS
	var discovery_started := Time.get_ticks_msec()
	var discovery_from := player.global_position
	var discovery_samples: Array=[]
	var discovery_next_sample := discovery_started
	var discovery_modal_frames := 0
	var discovery_previous := discovery_from
	var discovery_recovery_count := 0
	var discovery_strafe_until := 0
	var discovery_jump_until := 0
	var discovery_look_ready := true
	if discovery_motion: discovery_look_ready=await _look_toward_candidate()
	if discovery_motion and discovery_look_ready:
		_movement_key(KEY_W,true)
		_movement_key(KEY_SHIFT,true)
	while _within_deadline():
		if discovery_motion: await physics_frame
		await _frame()
		if discovery_motion:
			if _modal_loading_visible(): discovery_modal_frames+=1
			var discovery_now := Time.get_ticks_msec()
			_movement_key(KEY_SPACE,discovery_now<discovery_jump_until)
			_movement_key(KEY_W,discovery_now>=discovery_strafe_until)
			_movement_key(KEY_A,discovery_now<discovery_strafe_until and discovery_recovery_count%4==2)
			_movement_key(KEY_D,discovery_now<discovery_strafe_until and discovery_recovery_count%4==0)
			if discovery_now>=discovery_next_sample:
				discovery_next_sample=discovery_now+1000
				if discovery_now-discovery_started>1000 and player.global_position.distance_to(discovery_previous)<0.30 \
						and discovery_now>=discovery_strafe_until:
					discovery_recovery_count+=1
					if discovery_recovery_count%2==1: discovery_jump_until=discovery_now+250
					else: discovery_strafe_until=discovery_now+1500
				if discovery_samples.size()<96:
					discovery_samples.append({"elapsedMsec":discovery_now-discovery_started,"position":player.global_position,
						"distanceMoved":player.global_position.distance_to(discovery_from),"ordinaryWPressed":Input.is_key_pressed(KEY_W),
						"sprinting":player.get("is_sprinting"),"recoveryCount":discovery_recovery_count,"motion":_approach_motion_snapshot()})
				discovery_previous=player.global_position
			if not await _look_toward_candidate(): discovery_look_ready=false; break
		var source := _source_summary()
		if source.get("status") in ["failed","absent"]:
			if discovery_motion: _release_approach_keys()
			await _finish(String(source.status),String(source.get("reason","source_rejected"))); return
		if source.get("status") in ["ready","prepared"]:
			reservation = source.reservationCells
			source_binding = source.binding.duplicate()
			source_signature = source.sourceSignature
			break
	if discovery_motion:
		_release_approach_keys()
		await physics_frame
		await _frame()
	evidence.sourceDiscoveryApproach={"active":discovery_motion,"lookReady":discovery_look_ready,
		"elapsedMsec":Time.get_ticks_msec()-discovery_started,"from":discovery_from,"to":player.global_position,
		"distanceMoved":player.global_position.distance_to(discovery_from),"modalLoadingVisibleFrames":discovery_modal_frames,
		"completionMode":"ahead_of_travel" if player.global_position.distance_to(discovery_from)<100.0 else "sustained_moving_preparation",
		"samples":discovery_samples,"keysReleased":not Input.is_key_pressed(KEY_W) and not Input.is_key_pressed(KEY_SHIFT),
		"scope":"Ordinary W/Shift and viewport look while production ahead-of-player source preparation runs; no transform write or generated-artifact prewarm."}
	var discovery_elapsed:=Time.get_ticks_msec()-discovery_started
	var preparation_overlapped_motion: bool=discovery_samples.any(func(row: Dictionary): return row.get("ordinaryWPressed",false)) \
		and (discovery_elapsed<2000 or player.global_position.distance_to(discovery_from)>5.0 and discovery_samples.size()>=2)
	checks.source_discovery_approach = not discovery_motion or discovery_look_ready and discovery_modal_frames==0 \
		and preparation_overlapped_motion
	if not checks.source_discovery_approach:
		await _finish("failed","source_discovery_approach_failed"); return
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
		if not player_inspection_only:
			evidence.demandDrain=await _wait_for_demanded_window()
			checks.demanded_window_drains_within_target=evidence.demandDrain.get("passed",false)
			if not checks.demanded_window_drains_within_target:
				await _finish("failed",String(evidence.demandDrain.get("reason","demanded_window_did_not_drain"))); return
		else:
			evidence.demandDrain={"passed":false,"reason":"focused_player_inspection_excludes_timing_acceptance",
				"scope":"The focused itinerary shakedown omits timing and retirement acceptance; the full scale-soak mode remains authoritative."}
		if scale_soak_seconds>0:
			evidence.scaleSoak=await _run_scale_soak()
			checks.scale_soak_duration=evidence.scaleSoak.get("durationPassed",false)
			checks.scale_soak_cycles=evidence.scaleSoak.get("cyclesPassed",false)
			checks.scale_soak_autosave=evidence.scaleSoak.get("autosavePassed",false)
			checks.scale_soak_resources_settle=evidence.scaleSoak.get("settlementPassed",false)
			checks.scale_soak_no_modal=evidence.scaleSoak.get("modalLoadingVisibleFrames",-1)==0
			if not evidence.scaleSoak.get("passed",false):
				await _finish("failed",String(evidence.scaleSoak.get("reason","scale_soak_failed"))); return
		if scale_soak_seconds>0 or player_inspection_only:
			evidence.playerScaleInspection=await _run_player_scale_inspection()
			checks.scale_soak_player_inspection=evidence.playerScaleInspection.get("passed",false)
			if not checks.scale_soak_player_inspection:
				await _finish("failed",String(evidence.playerScaleInspection.get("reason","player_scale_inspection_failed"))); return
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

func _wait_for_demanded_window() -> Dictionary:
	phase="demanded_window_drain"
	var begun:=Time.get_ticks_msec()
	var until:=mini(deadline-10000,begun+60000)
	var samples: Array=[]
	var modal_frames:=0
	while Time.get_ticks_msec()<until and _within_deadline():
		await physics_frame
		await _frame()
		if _modal_loading_visible(): modal_frames+=1
		var publication: Dictionary=main.structure_system.citadel_publication.stats()
		var diagnostic: Dictionary={}
		for row: Dictionary in publication.get("sceneDiagnostics",[]):
			if row.get("region") == region: diagnostic=row; break
		var milestones: Dictionary=diagnostic.get("publicationMilestones",{})
		var complete_usec:=int(milestones.get("completeDemandedUsec",-1))
		if samples.is_empty() or Time.get_ticks_msec()-int(samples.back().get("sampledMsec",0))>=1000:
			samples.append({"sampledMsec":Time.get_ticks_msec(),"elapsedMsec":Time.get_ticks_msec()-begun,
				"completeDemandedUsec":complete_usec,"physicalGroupsComplete":diagnostic.get("physicalGroupsComplete",0),
				"foregroundGroups":diagnostic.get("packetForegroundGroups",0),"deferredGroups":diagnostic.get("packetDeferredGroups",0)})
		if complete_usec>=0:
			return {"passed":complete_usec<=45000000 and modal_frames==0,
				"reason":"demanded_window_complete" if complete_usec<=45000000 else "demanded_window_exceeded_target",
				"completeDemandedUsec":complete_usec,"elapsedMsec":Time.get_ticks_msec()-begun,
				"modalLoadingVisibleFrames":modal_frames,"samples":samples,
				"scope":"Stationary ordinary gameplay frames after the collision-backed approach; no direct publication polling, helper completion or transform write."}
	return {"passed":false,"reason":"demanded_window_drain_timeout","elapsedMsec":Time.get_ticks_msec()-begun,
		"modalLoadingVisibleFrames":modal_frames,"samples":samples,
		"scope":"Stationary ordinary gameplay frames after the collision-backed approach; no direct publication polling, helper completion or transform write."}

func _run_scale_soak() -> Dictionary:
	var soak_started:=Time.get_ticks_msec()
	var soak_deadline:=soak_started+scale_soak_seconds*1000
	# The requested interval is a minimum observation duration, not a timeout for
	# completing three collision-backed 920 m round trips. Keep a separate bounded
	# completion/audit reserve so slow deterministic rebuilds cannot truncate the
	# required third cycle. The outer owned-process watchdog remains authoritative.
	deadline=soak_deadline+900000
	var near_target:=player.global_position
	var center:=Vector3(candidate.centerCell.x*float(main.CELL),near_target.y,candidate.centerCell.y*float(main.CELL))
	var away_direction:=Vector2(near_target.x-center.x,near_target.z-center.z).normalized()
	if away_direction.length_squared()<0.5: away_direction=Vector2(0.0,1.0)
	var away_target:=near_target+Vector3(away_direction.x,0.0,away_direction.y)*SCALE_SOAK_AWAY_METERS
	var cycles: Array[Dictionary]=[]
	var samples: Array[Dictionary]=[]
	var next_sample:=soak_started
	var modal_frames:=0
	var peak_static_memory:=int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var autosave_started_before:=int(main.autosave_jobs_started)
	var autosave_completed_before:=int(main.autosave_jobs_completed)
	var autosave_failed_before:=int(main.autosave_jobs_failed)
	for cycle_index in SCALE_SOAK_CYCLES:
		var cycle_started:=Time.get_ticks_msec()
		var away_move:=await _ordinary_move_to(away_target,150000,18.0,"scale_soak_leave_%02d"%(cycle_index+1))
		modal_frames+=int(away_move.get("modalLoadingVisibleFrames",0))
		if not away_move.get("passed",false):
			cycles.append({"cycle":cycle_index+1,"leave":away_move})
			return _scale_soak_result(false,"leave_movement_failed",soak_started,cycles,samples,modal_frames,peak_static_memory,autosave_started_before,autosave_completed_before,autosave_failed_before)
		var retired:=await _wait_for_citadel_retirement(120000)
		modal_frames+=int(retired.get("modalLoadingVisibleFrames",0))
		if not retired.get("passed",false):
			return _scale_soak_result(false,"retirement_did_not_settle",soak_started,cycles,samples,modal_frames,peak_static_memory,autosave_started_before,autosave_completed_before,autosave_failed_before)
		var away_world_settlement:=await _wait_for_world_streaming_settlement(60000,"away_%02d"%(cycle_index+1))
		modal_frames+=int(away_world_settlement.get("modalLoadingVisibleFrames",0))
		if not away_world_settlement.get("passed",false):
			cycles.append({"cycle":cycle_index+1,"leave":away_move,"retirement":retired,
				"awayWorldSettlement":away_world_settlement})
			return _scale_soak_result(false,"away_world_did_not_settle",soak_started,cycles,samples,modal_frames,peak_static_memory,autosave_started_before,autosave_completed_before,autosave_failed_before)
		var away_census:=await _resource_census("away_settled_%02d"%(cycle_index+1))
		var revisit_move:=await _ordinary_move_to(near_target,180000,2.5,"scale_soak_revisit_%02d"%(cycle_index+1))
		modal_frames+=int(revisit_move.get("modalLoadingVisibleFrames",0))
		if not revisit_move.get("passed",false):
			cycles.append({"cycle":cycle_index+1,"leave":away_move,"retirement":retired,
				"awayWorldSettlement":away_world_settlement,"awayCensus":away_census,"revisit":revisit_move})
			return _scale_soak_result(false,"revisit_movement_failed",soak_started,cycles,samples,modal_frames,peak_static_memory,autosave_started_before,autosave_completed_before,autosave_failed_before)
		await _look_toward_candidate()
		var revisited:=await _wait_for_revisit_settlement(180000)
		modal_frames+=int(revisited.get("modalLoadingVisibleFrames",0))
		if not revisited.get("passed",false):
			return _scale_soak_result(false,"revisit_did_not_settle",soak_started,cycles,samples,modal_frames,peak_static_memory,autosave_started_before,autosave_completed_before,autosave_failed_before)
		var revisit_world_settlement:=await _wait_for_world_streaming_settlement(60000,"revisit_%02d"%(cycle_index+1))
		modal_frames+=int(revisit_world_settlement.get("modalLoadingVisibleFrames",0))
		if not revisit_world_settlement.get("passed",false):
			cycles.append({"cycle":cycle_index+1,"leave":away_move,"retirement":retired,
				"awayWorldSettlement":away_world_settlement,"awayCensus":away_census,"revisit":revisit_move,
				"settlement":revisited,"revisitWorldSettlement":revisit_world_settlement})
			return _scale_soak_result(false,"revisit_world_did_not_settle",soak_started,cycles,samples,modal_frames,peak_static_memory,autosave_started_before,autosave_completed_before,autosave_failed_before)
		var revisit_census:=await _resource_census("revisit_settled_%02d"%(cycle_index+1))
		cycles.append({"cycle":cycle_index+1,"elapsedMsec":Time.get_ticks_msec()-soak_started,
			"durationMsec":Time.get_ticks_msec()-cycle_started,"leave":away_move,"retirement":retired,
			"awayWorldSettlement":away_world_settlement,"awayCensus":away_census,"revisit":revisit_move,
			"settlement":revisited,"revisitWorldSettlement":revisit_world_settlement,"revisitCensus":revisit_census})
		# Spread the three real retirement/revisit cycles over the requested soak
		# interval. Stationary time remains ordinary gameplay with autosave active.
		var cycle_boundary:=soak_started+int(float(scale_soak_seconds*1000)*float(cycle_index+1)/float(SCALE_SOAK_CYCLES))
		phase="scale_soak_stationary_%02d"%(cycle_index+1)
		while Time.get_ticks_msec()<mini(cycle_boundary,soak_deadline):
			await _frame()
			if _modal_loading_visible(): modal_frames+=1
			var now:=Time.get_ticks_msec()
			if now>=next_sample:
				next_sample=now+SCALE_SOAK_SAMPLE_MSEC
				var sample:=_resource_sample("stationary_%02d"%(cycle_index+1))
				peak_static_memory=maxi(peak_static_memory,int(sample.staticMemoryBytes))
				samples.append(sample)
	while Time.get_ticks_msec()<soak_deadline:
		await _frame()
		if _modal_loading_visible(): modal_frames+=1
		var now:=Time.get_ticks_msec()
		if now>=next_sample:
			next_sample=now+SCALE_SOAK_SAMPLE_MSEC
			var sample:=_resource_sample("terminal_settle")
			peak_static_memory=maxi(peak_static_memory,int(sample.staticMemoryBytes))
			samples.append(sample)
	return _scale_soak_result(true,"",soak_started,cycles,samples,modal_frames,peak_static_memory,autosave_started_before,autosave_completed_before,autosave_failed_before)

func _scale_soak_result(flow_passed: bool, flow_reason: String, soak_started: int, cycles: Array[Dictionary], samples: Array[Dictionary],
		modal_frames: int, peak_static_memory: int, autosave_started_before: int, autosave_completed_before: int, autosave_failed_before: int) -> Dictionary:
	var duration_msec:=Time.get_ticks_msec()-soak_started
	var duration_passed:=duration_msec>=scale_soak_seconds*1000
	var cycles_passed:=cycles.size()==SCALE_SOAK_CYCLES and cycles.all(func(row: Dictionary):
		return row.leave.get("passed",false) and row.retirement.get("passed",false) \
			and row.awayWorldSettlement.get("passed",false) and row.revisit.get("passed",false) \
			and row.settlement.get("passed",false) and row.revisitWorldSettlement.get("passed",false))
	var autosave_started:=int(main.autosave_jobs_started)-autosave_started_before
	var autosave_completed:=int(main.autosave_jobs_completed)-autosave_completed_before
	var autosave_failed:=int(main.autosave_jobs_failed)-autosave_failed_before
	var autosave_passed:=bool(main.autosave_enabled) and autosave_started>0 and autosave_completed>0 and autosave_failed==0
	var settlement:=_settlement_comparison(cycles)
	var settlement_passed: bool=bool(settlement.get("passed",false))
	var passed: bool=flow_passed and duration_passed and cycles_passed and autosave_passed and settlement_passed and modal_frames==0
	var reason:=flow_reason
	if reason.is_empty() and not duration_passed: reason="scale_soak_duration_short"
	if reason.is_empty() and not cycles_passed: reason="scale_soak_cycles_incomplete"
	if reason.is_empty() and not autosave_passed: reason="scale_soak_autosave_incomplete"
	if reason.is_empty() and not settlement_passed: reason="scale_soak_resource_growth"
	if reason.is_empty() and modal_frames>0: reason="modal_loading_during_scale_soak"
	return {"passed":passed,"reason":reason,"requestedSeconds":scale_soak_seconds,"durationMsec":duration_msec,
		"durationPassed":duration_passed,"cyclesPassed":cycles_passed,"autosavePassed":autosave_passed,
		"settlementPassed":settlement_passed,"modalLoadingVisibleFrames":modal_frames,"cycleCount":cycles.size(),
		"cycles":cycles,"samples":samples,"sampleIntervalMsec":SCALE_SOAK_SAMPLE_MSEC,"peakStaticMemoryBytes":peak_static_memory,
		"autosave":{"enabled":main.autosave_enabled,"started":autosave_started,"completed":autosave_completed,"failed":autosave_failed},
		"settlement":settlement,"processBaseline":evidence.get("scaleSoakProcessBaseline",{}),
		"scope":"Headed ordinary gameplay with ordinary key/mouse movement, real streaming retirement/revisit, autosave, engine memory monitors and live scene-tree census. No player transform write or publication helper completion."}

func _settlement_comparison(cycles: Array[Dictionary]) -> Dictionary:
	if cycles.size()<SCALE_SOAK_CYCLES: return {"passed":false,"reason":"insufficient_comparable_checkpoints"}
	# The first complete leave/rebuild is the stated warmup cycle: it populates
	# renderer, allocator and incremental-publication caches. Cycle two is the
	# first post-warmup settled checkpoint; later cycles may not grow >5% from it.
	var warm: Dictionary=cycles[1].revisitCensus
	var comparisons: Array[Dictionary]=[]
	var checkpoint_comparisons: Array[Dictionary]=[]
	var metrics: Array[String]=["staticMemoryBytes","nodeCount","resourceCount","orphanNodeCount","siteNodes","siteGeometry","siteCollisionShapes","siteStaticBodies","siteMultiMeshes","siteMultiMeshInstances","siteShadowCasters","citadelPreparedRepresentations","citadelCompactCaches","citadelLiveSceneSites","citadelResidentSites","citadelRetainedBounds"]
	var group_accountable_metrics: Array[String]=["siteNodes","siteGeometry","siteCollisionShapes","siteMultiMeshes","siteMultiMeshInstances","siteShadowCasters"]
	for cycle_index in range(2,cycles.size()):
		var current: Dictionary=cycles[cycle_index].revisitCensus
		var warm_world: Dictionary=warm.get("worldStreaming",{})
		var current_world: Dictionary=current.get("worldStreaming",{})
		var same_world_signature: bool=not String(warm_world.get("settlementSignature","")).is_empty() \
			and warm_world.get("settlementSignature")==current_world.get("settlementSignature")
		checkpoint_comparisons.append({"cycle":cycle_index+1,"passed":same_world_signature,
			"baselineSignature":warm_world.get("settlementSignature",""),
			"currentSignature":current_world.get("settlementSignature",""),
			"reason":"equivalent_authoritative_world_state" if same_world_signature else "world_state_not_equivalent"})
		for metric: String in metrics:
			var baseline_value:=int(warm.get(metric,0))
			var current_value:=int(current.get(metric,0))
			var limit:=ceili(float(baseline_value)*1.05)
			var raw_passed:=current_value<=limit
			var baseline_groups:=int(warm.get("citadelPhysicalGroupsComplete",0))
			var current_groups:=int(current.get("citadelPhysicalGroupsComplete",0))
			var baseline_density:=float(baseline_value)/float(baseline_groups) if baseline_groups>0 else 0.0
			var current_density:=float(current_value)/float(current_groups) if current_groups>0 else 0.0
			var density_limit:=baseline_density*1.05
			var group_accounted:=not raw_passed and metric in group_accountable_metrics and current_groups>baseline_groups \
				and baseline_groups>0 and current_density<=density_limit
			comparisons.append({"cycle":cycle_index+1,"metric":metric,"warmValue":baseline_value,"currentValue":current_value,
				"limit":limit,"growthRatio":float(current_value)/float(baseline_value) if baseline_value>0 else (0.0 if current_value==0 else -1.0),
				"rawPassed":raw_passed,"accounted":group_accounted,
				"accountedBy":"additional deterministic physical groups at stable or lower per-group density" if group_accounted else "",
				"baselinePhysicalGroups":baseline_groups,"currentPhysicalGroups":current_groups,
				"baselinePerGroup":baseline_density,"currentPerGroup":current_density,"perGroupLimit":density_limit,
				"passed":raw_passed or group_accounted})
	return {"passed":checkpoint_comparisons.all(func(row: Dictionary):return row.passed) \
		and comparisons.all(func(row: Dictionary):return row.passed),"warmupCycle":1,"baselineCycle":2,
		"checkpointComparisons":checkpoint_comparisons,"comparisons":comparisons,
		"criterion":"After one complete warmup cycle, no unaccounted positive growth above five percent from the first post-warmup settled revisit. Only live Citadel subtree counts may be accounted by additional deterministic physical groups when per-group density stays within five percent; process-wide and lifecycle/cache counts always use the raw ceiling."}

func _wait_for_citadel_retirement(timeout_msec: int) -> Dictionary:
	phase="scale_soak_retirement"
	var begun:=Time.get_ticks_msec()
	var stable_frames:=0
	var modal_frames:=0
	var last_state: Dictionary={}
	while Time.get_ticks_msec()-begun<timeout_msec and _within_deadline():
		await _frame()
		if _modal_loading_visible(): modal_frames+=1
		last_state=main.structure_system.citadel_publication.scene_state(region)
		var stats: Dictionary=main.structure_system.citadel_publication.stats()
		# A forward prefetch may intentionally retain one immutable description/base.
		# Retirement means player-facing nodes, scene preparation and callbacks are
		# gone; it does not require throwing away that bounded compact cache.
		var compact_caches:=int(stats.get("describedSites",0))+int(stats.get("bootstrapBases",0))
		var settled: bool=last_state.get("status")=="absent" and int(stats.get("constructedScenes",-1))==0 \
			and int(stats.get("publishingScenes",-1))==0 and int(stats.get("preparedSites",-1))==0 \
			and int(stats.get("retiringScenes",-1))==0 and int(stats.get("pendingRetirements",-1))==0
		settled=settled and int(stats.get("residentSites",Admission.MAX_PREFETCH_REGIONS+1))<=Admission.MAX_PREFETCH_REGIONS \
			and compact_caches<=Admission.MAX_PREFETCH_REGIONS*2
		stable_frames=stable_frames+1 if settled else 0
		if stable_frames>=30:
			return {"passed":modal_frames==0,"reason":"retired_and_disposed","elapsedMsec":Time.get_ticks_msec()-begun,
				"stableFrames":stable_frames,"modalLoadingVisibleFrames":modal_frames,"scene":last_state,"publication":stats}
	return {"passed":false,"reason":"retirement_timeout","elapsedMsec":Time.get_ticks_msec()-begun,
		"stableFrames":stable_frames,"modalLoadingVisibleFrames":modal_frames,"scene":last_state}

func _wait_for_revisit_settlement(timeout_msec: int) -> Dictionary:
	phase="scale_soak_revisit_settlement"
	var begun:=Time.get_ticks_msec()
	var stable_frames:=0
	var modal_frames:=0
	var last_status: Dictionary={}
	while Time.get_ticks_msec()-begun<timeout_msec and _within_deadline():
		await _frame()
		if _modal_loading_visible(): modal_frames+=1
		var scene: Dictionary=main.structure_system.citadel_publication.scene_state(region)
		var publication: Dictionary=main.structure_system.citadel_publication.stats()
		var entry: Dictionary=main.structure_system.citadel_publication._scenes.get(region,{})
		var job_status: Dictionary=entry.job.status_count() if entry.get("job")!=null else {}
		var diagnostic: Dictionary={}
		for row: Dictionary in publication.get("sceneDiagnostics",[]):
			if row.get("region")==region: diagnostic=row; break
		var milestones: Dictionary=diagnostic.get("publicationMilestones",{})
		var foreground: Dictionary=main.player_foreground_streaming_intent()
		var physical: Dictionary=main.structure_system.citadel_physical_publication_state(
			foreground.get("bounds",Rect2i())) if foreground.get("bounds") is Rect2i else {}
		# A resident packet deliberately continues view-ranked detail after the
		# current player closure is acknowledged, so packet_wait is not an idle or
		# gameplay-readiness contract. Settle on the authoritative current physical
		# receipt and source owner; the later census accounts for ongoing detail.
		var settled: bool=scene.get("status") in ["scene_ready","publishing"] \
			and scene.get("binding",{})==source_binding and physical.get("status")=="ready" \
			and physical.get("required",false) and int(milestones.get("completeDemandedUsec",-1))>=0 \
			and int(job_status.get("occupiedTransactions",-1))==0 and publication.get("failures",{}).is_empty()
		stable_frames=stable_frames+1 if settled else 0
		last_status={"scene":scene,"job":job_status,"physical":physical,"diagnostic":diagnostic,"publication":publication}
		if stable_frames>=30:
			return {"passed":modal_frames==0,"reason":"revisit_foreground_physical_settled","elapsedMsec":Time.get_ticks_msec()-begun,
				"stableFrames":stable_frames,"modalLoadingVisibleFrames":modal_frames,"status":last_status}
	return {"passed":false,"reason":"revisit_settlement_timeout","elapsedMsec":Time.get_ticks_msec()-begun,
		"stableFrames":stable_frames,"modalLoadingVisibleFrames":modal_frames,"status":last_status}

func _wait_for_route_physical_settlement(bounds: Rect2i, timeout_msec: int, label: String) -> Dictionary:
	phase="scale_inspection_physical_settlement:"+label
	var begun:=Time.get_ticks_msec()
	var stable_frames:=0
	var modal_frames:=0
	var last_status: Dictionary={}
	while Time.get_ticks_msec()-begun<timeout_msec and _within_deadline():
		await _frame()
		if _modal_loading_visible(): modal_frames+=1
		var scene: Dictionary=main.structure_system.citadel_publication.scene_state(region)
		var physical: Dictionary=main.structure_system.citadel_physical_publication_state(bounds)
		var publication: Dictionary=main.structure_system.citadel_publication.stats()
		var settled: bool=scene.get("status") in ["scene_ready","publishing"] \
			and scene.get("binding",{})==source_binding and physical.get("status")=="ready" \
			and physical.get("required",false) and publication.get("failures",{}).is_empty()
		stable_frames=stable_frames+1 if settled else 0
		last_status={"bounds":bounds,"scene":scene,"physical":physical,"publication":publication}
		if stable_frames>=30:
			return {"passed":modal_frames==0,"reason":"route_physical_settled","elapsedMsec":Time.get_ticks_msec()-begun,
				"stableFrames":stable_frames,"modalLoadingVisibleFrames":modal_frames,"status":last_status,
				"scope":"Exact source-derived route bounds and production physical receipts; unrelated occupied transactions remain retryable."}
	return {"passed":false,"reason":"route_physical_settlement_timeout","elapsedMsec":Time.get_ticks_msec()-begun,
		"stableFrames":stable_frames,"modalLoadingVisibleFrames":modal_frames,"status":last_status,
		"scope":"Exact source-derived route bounds and production physical receipts; unrelated occupied transactions remain retryable."}

func _route_bounds_for_world_points(points: Array[Vector3], margin_cells: int) -> Rect2i:
	if points.is_empty(): return Rect2i()
	var minimum:=Vector2(INF,INF)
	var maximum:=Vector2(-INF,-INF)
	for point: Vector3 in points:
		minimum=minimum.min(Vector2(point.x,point.z))
		maximum=maximum.max(Vector2(point.x,point.z))
	var cell_size:=float(main.CELL)
	var low:=Vector2i(floori(minimum.x/cell_size),floori(minimum.y/cell_size))-Vector2i.ONE*margin_cells
	var high:=Vector2i(ceili(maximum.x/cell_size),ceili(maximum.y/cell_size))+Vector2i.ONE*(margin_cells+1)
	return Rect2i(low,high-low)

func _wait_for_world_streaming_settlement(timeout_msec: int, label: String) -> Dictionary:
	phase="scale_soak_world_settlement:"+label
	var begun:=Time.get_ticks_msec()
	var ready_since:=-1
	var stable_signature:=""
	var modal_frames:=0
	var samples: Array[Dictionary]=[]
	var next_sample:=begun
	var last_state: Dictionary={}
	while Time.get_ticks_msec()-begun<timeout_msec and _within_deadline():
		await _frame()
		if _modal_loading_visible(): modal_frames+=1
		last_state=_world_streaming_settlement_snapshot()
		var now:=Time.get_ticks_msec()
		if now>=next_sample:
			next_sample=now+1000
			samples.append(last_state.duplicate(true))
		if bool(last_state.get("ready",false)):
			var current_signature:=String(last_state.get("settlementSignature",""))
			if ready_since<0 or current_signature!=stable_signature:
				ready_since=now
				stable_signature=current_signature
			# A real ten-second quiet window catches deferred prop and native terrain
			# publications without using resource counts as an acceptance predicate.
			if now-ready_since>=10000:
				return {"passed":modal_frames==0,"reason":"authoritative_world_queues_quiet",
					"elapsedMsec":now-begun,"quietMsec":now-ready_since,
					"modalLoadingVisibleFrames":modal_frames,"state":last_state,"samples":samples,
					"scope":"Read-only observation of production chunk, prop, terrain, collision, structure and voxel-runtime queues; no helper processing or resource-count targeting."}
		else:
			ready_since=-1
			stable_signature=""
	return {"passed":false,"reason":"world_streaming_settlement_timeout","elapsedMsec":Time.get_ticks_msec()-begun,
		"quietMsec":0 if ready_since<0 else Time.get_ticks_msec()-ready_since,
		"modalLoadingVisibleFrames":modal_frames,"state":last_state,"samples":samples}

func _world_streaming_settlement_snapshot() -> Dictionary:
	var voxel: Dictionary=main.voxel_terrain_runtime.stats() if main.voxel_terrain_runtime!=null \
		and main.voxel_terrain_runtime.has_method("stats") else {}
	var meshing_pending:=int(main.terrain_meshing_service.pending_job_count()) if main.terrain_meshing_service!=null \
		and main.terrain_meshing_service.has_method("pending_job_count") else 0
	var meshing_completed:=int(main.terrain_meshing_service.completed_job_count()) if main.terrain_meshing_service!=null \
		and main.terrain_meshing_service.has_method("completed_job_count") else 0
	var expected_chunks:=maxi(1,(int(main.render_distance)*2+1)*(int(main.render_distance)*2+1))
	var chunk_keys: Array[String]=[]
	for key_value in main.chunks.keys(): chunk_keys.append(str(key_value))
	chunk_keys.sort()
	var result:={"sampledMsec":Time.get_ticks_msec(),"chunkNodes":main.chunks.size(),"expectedChunkNodes":expected_chunks,
		"playerChunk":str(main.world_to_chunk(player.position.x,player.position.z)),"chunkKeySignature":"|".join(chunk_keys),
		"pendingChunkLoads":main.pending_chunk_loads.size(),"pendingChunkProps":main.pending_chunk_prop_spawns.size(),
		"pendingTerrainRefreshes":main.pending_chunk_terrain_refreshes.size(),
		"pendingCollisionRefreshes":main.pending_chunk_collision_refreshes.size(),
		"pendingExposureScans":main.pending_generated_volume_exposure_scans.size(),
		"pendingStructureOps":int(main.pending_streaming_structure_work_count()),
		"terrainMeshingPending":meshing_pending,"terrainMeshingCompleted":meshing_completed,
		"voxelDesiredGameplayChunks":int(voxel.get("desiredGameplayChunks",0)),
		"voxelPendingGameplayChunks":int(voxel.get("pendingGameplayChunks",0)),
		"voxelPendingGameplayChunkQueue":int(voxel.get("pendingGameplayChunkQueue",0)),
		"voxelPublishedGameplayChunks":int(voxel.get("publishedGameplayChunks",0)),
		"voxelPendingEditSections":int(voxel.get("pendingEditSections",0))}
	# Native terrain meshing, exposure and prop queues may intentionally retain
	# background work outside the current 7x7 gameplay view. They are included in
	# the stable signature and evidence, but are not falsely required to reach zero.
	# The foreground view is ready when its ordinary chunk coverage is published
	# and its directly blocking refresh/structure queues are empty.
	result.ready=int(result.chunkNodes)>=expected_chunks and int(result.pendingChunkLoads)==0 \
		and int(result.pendingTerrainRefreshes)==0 and int(result.pendingCollisionRefreshes)==0 \
		and int(result.pendingStructureOps)==0 and meshing_completed==0 \
		and int(result.voxelPendingEditSections)==0 and int(result.voxelPublishedGameplayChunks)>=expected_chunks
	result.settlementSignature=str([result.playerChunk,result.chunkKeySignature,result.chunkNodes,result.pendingChunkProps,
		result.pendingExposureScans,result.voxelDesiredGameplayChunks,result.voxelPendingGameplayChunks,
		result.voxelPendingGameplayChunkQueue,result.voxelPublishedGameplayChunks])
	return result

func _ordinary_move_to(target: Vector3, timeout_msec: int, stop_distance: float, phase_name: String,
		allow_lateral_recovery := true, hold_jump := false, sprint := true) -> Dictionary:
	phase=phase_name
	var begun:=Time.get_ticks_msec()
	var from:=player.global_position
	var previous:=from
	var frame_previous:=from
	var path_distance:=0.0
	var next_sample:=begun
	var recovery_count:=0
	var strafe_until:=0
	var jump_until:=0
	var modal_frames:=0
	var aim_convergence_misses:=0
	var first_modal: Dictionary={}
	var samples: Array[Dictionary]=[]
	var discontinuity: Dictionary={}
	var target_reached_during_motion:=false
	var minimum_remaining:=INF
	if bool(player.get("automated_input")) or not player.is_physics_processing(): return {"passed":false,"reason":"ordinary_player_input_unavailable"}
	# Turn in place before advancing into the next waypoint leg. Keeping W held
	# while rotating from a lateral leg into a narrow street makes an artificial
	# arc that a human player naturally avoids.
	_movement_key(KEY_W,false); _movement_key(KEY_SHIFT,sprint)
	if not await _look_toward_world_xz(target): aim_convergence_misses+=1
	_movement_key(KEY_W,true)
	while Time.get_ticks_msec()-begun<timeout_msec and _within_deadline():
		await physics_frame
		await _frame()
		var frame_distance:=player.global_position.distance_to(frame_previous)
		if frame_distance>30.0:
			discontinuity={"elapsedMsec":Time.get_ticks_msec()-begun,"from":frame_previous,
				"to":player.global_position,"distance":frame_distance,
				"reason":"Frame-to-frame displacement exceeded ordinary player movement; death/respawn or an external transform write invalidates this route."}
			break
		path_distance+=frame_distance
		frame_previous=player.global_position
		if _modal_loading_visible():
			modal_frames+=1
			if first_modal.is_empty():
				first_modal={"elapsedMsec":Time.get_ticks_msec()-begun,
					"streamingActive":bool(main.get("streaming_loading_overlay_active")),
					"streamingHolds":main.get("streaming_loading_overlay_holds").duplicate(true),
					"startupActive":bool(main.get("startup_loading_active")),
					"runtimeActive":bool(main.get("runtime_loading_active"))}
		var planar_distance:=Vector2(player.global_position.x-target.x,player.global_position.z-target.z).length()
		minimum_remaining=minf(minimum_remaining,planar_distance)
		if planar_distance<=stop_distance:
			target_reached_during_motion=true
			break
		var now:=Time.get_ticks_msec()
		_movement_key(KEY_SPACE,hold_jump or now<jump_until)
		_movement_key(KEY_W,not allow_lateral_recovery or now>=strafe_until)
		_movement_key(KEY_A,allow_lateral_recovery and now<strafe_until and recovery_count%4==2)
		_movement_key(KEY_D,allow_lateral_recovery and now<strafe_until and recovery_count%4==0)
		if now>=next_sample:
			next_sample=now+1000
			if now-begun>1000 and player.global_position.distance_to(previous)<0.30 and now>=strafe_until:
				recovery_count+=1
				if not allow_lateral_recovery or recovery_count%2==1: jump_until=now+250
				else: strafe_until=now+1500
			if samples.size()<180: samples.append({"elapsedMsec":now-begun,"position":player.global_position,
				"distanceToTarget":planar_distance,"pathDistance":path_distance,"ordinaryWPressed":Input.is_key_pressed(KEY_W),
				"sprinting":player.get("is_sprinting"),"recoveryCount":recovery_count,"motion":_approach_motion_snapshot()})
			previous=player.global_position
		# Mouse smoothing and an airborne close-range target can need more than one
		# correction window. A human does not abandon the route after one such
		# miss; keep feeding ordinary mouse input and retain the miss as evidence.
		# At close range, release forward while turning so input latency cannot make
		# the player orbit a narrow waypoint indefinitely.
		var pause_for_close_aim:=planar_distance<=maxf(5.0,stop_distance*3.0)
		if pause_for_close_aim: _movement_key(KEY_W,false)
		if not await _look_toward_world_xz(target): aim_convergence_misses+=1
		if pause_for_close_aim: _movement_key(KEY_W,true)
	_release_approach_keys()
	await physics_frame; await _frame()
	var remaining:=Vector2(player.global_position.x-target.x,player.global_position.z-target.z).length()
	var reached:=target_reached_during_motion or remaining<=stop_distance
	var result_reason:="unexpected_player_discontinuity" if not discontinuity.is_empty() else \
		("modal_loading_during_movement" if modal_frames>0 else ("target_reached" if reached else "movement_timeout"))
	return {"passed":reached and modal_frames==0 and discontinuity.is_empty(),"reason":result_reason,
		"elapsedMsec":Time.get_ticks_msec()-begun,"from":from,"to":player.global_position,"target":target,"remainingDistance":remaining,
		"pathDistance":path_distance,"displacement":player.global_position.distance_to(from),"samples":samples,
		"minimumRemainingDistance":minimum_remaining,"targetReachedDuringMotion":target_reached_during_motion,
		"discontinuity":discontinuity,
		"aimConvergenceMisses":aim_convergence_misses,
		"modalLoadingVisibleFrames":modal_frames,"firstModal":first_modal,
		"keysReleased":not Input.is_key_pressed(KEY_W) and not Input.is_key_pressed(KEY_SHIFT),
		"scope":"Ordinary W/Shift, mouse-look, jump and lateral recovery through the production player controller and collision.",
		"heldJump":hold_jump,"sprintInput":sprint}

func _look_toward_world_xz(target: Vector3) -> bool:
	main.capture_mouse_if_no_modal()
	var direction:=target-player.global_position
	var sensitivity:=float(player.get("mouse_sensitivity"))
	if Vector2(direction.x,direction.z).length()<0.01 or sensitivity<=0.0: return false
	for attempt in range(12):
		var error:=wrapf(atan2(-direction.x,-direction.z)-player.global_rotation.y,-PI,PI)
		if absf(error)<0.04: return true
		var motion:=InputEventMouseMotion.new()
		motion.relative=Vector2(clampf(-error/sensitivity,-600,600),0.0)
		root.push_input(motion)
		await _frame()
		direction=target-player.global_position
	return absf(wrapf(atan2(-direction.x,-direction.z)-player.global_rotation.y,-PI,PI))<0.04

func _resource_sample(label: String) -> Dictionary:
	var service=main.structure_system.citadel_publication
	var stats: Dictionary=service.stats()
	var world_state:=_world_streaming_settlement_snapshot()
	return {"label":label,"elapsedMsec":_elapsed(),"staticMemoryBytes":int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"nodeCount":int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),"resourceCount":int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"orphanNodeCount":int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"renderObjects":int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"drawCalls":int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"primitives":int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"citadelResidentSites":int(stats.get("residentSites",0)),"citadelRetainedBounds":int(stats.get("retainedBounds",0)),
		"citadelRetiringScenes":int(stats.get("retiringScenes",0)),"citadelPendingRetirements":int(stats.get("pendingRetirements",0)),
		"citadelPreparedRepresentations":int(stats.get("describedSites",0))+int(stats.get("preparedSites",0))+int(stats.get("bootstrapBases",0)),
		"citadelCompactCaches":int(stats.get("describedSites",0))+int(stats.get("bootstrapBases",0)),
		"citadelLiveSceneSites":int(stats.get("constructedScenes",0))+int(stats.get("publishingScenes",0)),"worldStreaming":world_state,
		"autosaveStarted":int(main.autosave_jobs_started),"autosaveCompleted":int(main.autosave_jobs_completed),"autosaveFailed":int(main.autosave_jobs_failed)}

func _resource_census(label: String) -> Dictionary:
	phase="scale_soak_census:"+label
	var result: Dictionary=_resource_sample(label)
	var service=main.structure_system.citadel_publication
	var site: Node3D=service.scene_root(region) if not candidate.is_empty() else null
	var physical_groups_complete:=0
	var physical_groups_total:=0
	for diagnostic: Dictionary in service.stats().get("sceneDiagnostics",[]):
		if diagnostic.get("region")!=region: continue
		physical_groups_complete=int(diagnostic.get("physicalGroupsComplete",0))
		physical_groups_total=int(diagnostic.get("physicalGroupsTotal",0))
		break
	var stack: Array[Node]=[]
	if is_instance_valid(site): stack.append(site)
	var mesh_resources: Dictionary={}
	var material_resources: Dictionary={}
	var shape_resources: Dictionary={}
	result.merge({"citadelPhysicalGroupsComplete":physical_groups_complete,"citadelPhysicalGroupsTotal":physical_groups_total,
		"siteNodes":0,"siteGeometry":0,"siteMeshes":0,"siteMultiMeshes":0,"siteMultiMeshInstances":0,
		"siteCollisionShapes":0,"siteStaticBodies":0,"siteShadowCasters":0,"siteVisibilityRanged":0,
		"uniqueMeshResources":0,"uniqueMaterialResources":0,"uniqueShapeResources":0},true)
	while not stack.is_empty() and _within_deadline():
		for unit in range(256):
			if stack.is_empty(): break
			var node: Node=stack.pop_back()
			if not is_instance_valid(node): continue
			result.siteNodes+=1
			for child: Node in node.get_children(): stack.append(child)
			if node is StaticBody3D: result.siteStaticBodies+=1
			if node is CollisionShape3D and node.shape!=null and not node.disabled:
				result.siteCollisionShapes+=1; shape_resources[node.shape.get_instance_id()]=true
			if node is GeometryInstance3D:
				result.siteGeometry+=1
				if node.cast_shadow!=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF: result.siteShadowCasters+=1
				if node.visibility_range_begin>0.0 or node.visibility_range_end>0.0: result.siteVisibilityRanged+=1
				if node.material_override!=null: material_resources[node.material_override.get_instance_id()]=true
			if node is MeshInstance3D and node.mesh!=null:
				result.siteMeshes+=1; mesh_resources[node.mesh.get_instance_id()]=true
				for surface_index in node.mesh.get_surface_count():
					var material: Material=node.mesh.surface_get_material(surface_index)
					if material!=null: material_resources[material.get_instance_id()]=true
			if node is MultiMeshInstance3D and node.multimesh!=null:
				result.siteMultiMeshes+=1; result.siteMultiMeshInstances+=node.multimesh.instance_count
				if node.multimesh.mesh!=null: mesh_resources[node.multimesh.mesh.get_instance_id()]=true
		await _frame()
	result.uniqueMeshResources=mesh_resources.size(); result.uniqueMaterialResources=material_resources.size(); result.uniqueShapeResources=shape_resources.size()
	result.censusComplete=stack.is_empty()
	result.censusScope="Live Citadel scene subtree and its deterministic physical-group progress plus engine-wide Performance memory/node/resource/render monitors. Counts do not estimate GPU allocation bytes."
	return result

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

func _run_player_scale_inspection() -> Dictionary:
	# This itinerary is derived from the accepted source samples and bounds. It
	# drives only ordinary key/mouse input through PlayerController and uses the
	# production interaction ray for doors; no transform, motor or door API call.
	phase="scale_player_inspection_prepare"
	var bounds: AABB=evidence.sceneAudit.visualBounds
	var gate_sample: Dictionary={}
	var stair_sample: Dictionary={}
	for sample: Dictionary in evidence.sceneAudit.get("structureSamples",[]):
		if sample.id=="castle_gatehouse_portcullis": gate_sample=sample
		elif String(sample.semantic)=="castle_gatehouse_wall_stair_landing": stair_sample=sample
	if gate_sample.is_empty() or stair_sample.is_empty():
		return {"passed":false,"reason":"required_gate_or_stair_sample_missing"}
	var homes: Array[Dictionary]=[]
	for home_value in evidence.sceneAudit.get("urbanHomeInteriors",[]):
		if home_value is Dictionary and bool((home_value as Dictionary).get("complete",false)):
			homes.append(home_value as Dictionary)
	if homes.is_empty(): return {"passed":false,"reason":"complete_urban_home_sample_missing"}
	var home: Dictionary=homes[0]
	var gate_pose: Transform3D=gate_sample.transform
	var gate_position:=gate_pose.origin
	var center:=bounds.get_center()
	var outward_2d:=Vector2(gate_position.x-center.x,gate_position.z-center.z)
	if absf(outward_2d.x)>=absf(outward_2d.y): outward_2d=Vector2(signf(outward_2d.x),0.0)
	else: outward_2d=Vector2(0.0,signf(outward_2d.y))
	if outward_2d.length_squared()<0.5: return {"passed":false,"reason":"gate_outward_axis_unresolved"}
	var outward:=Vector3(outward_2d.x,0.0,outward_2d.y)
	var tangent:=Vector3(outward.z,0.0,-outward.x)
	var half_outward:=absf(outward.x)*bounds.size.x*0.5+absf(outward.z)*bounds.size.z*0.5
	var half_tangent:=absf(tangent.x)*bounds.size.x*0.5+absf(tangent.z)*bounds.size.z*0.5
	var side_sign:=1.0 if player.global_position.distance_to(center-outward*half_outward+tangent*half_tangent) \
		<=player.global_position.distance_to(center-outward*half_outward-tangent*half_tangent) else -1.0
	var margin:=14.0
	var perimeter_side:=tangent*side_sign
	var corner_near:=center-outward*(half_outward+margin)+perimeter_side*(half_tangent+margin)
	var corner_gate:=center+outward*(half_outward+margin)+perimeter_side*(half_tangent+margin)
	# The approach finishes close enough to read the opposite curtain wall. Move
	# straight out to its clear perimeter lane before turning toward the corner;
	# a diagonal chord can legitimately clip a buttress even though both endpoints
	# are outside. This remains ordinary player motion over production terrain.
	var approach_tangent_offset:=clampf((player.global_position-center).dot(tangent),
		-half_tangent-margin,half_tangent+margin)
	var curtain_clearance:=center-outward*(half_outward+margin)+tangent*approach_tangent_offset
	# The operable stance is measured from the source gate plane. Keep the
	# capsule just outside the closed grille while remaining inside ordinary
	# action reach; the approach landing itself extends farther outward.
	var gate_outside:=gate_position+outward*0.65
	var gate_staging:=gate_outside+perimeter_side*10.0
	var gate_inside:=gate_position-outward*3.2
	var stages: Array[Dictionary]=[]
	for move_spec: Dictionary in [
		{"label":"curtain_clearance","target":curtain_clearance,"stop":4.0},
		{"label":"curtain_near_corner","target":corner_near,"stop":3.0},
		{"label":"curtain_gate_corner","target":corner_gate,"stop":3.2}]:
		var moved:=await _ordinary_move_to(move_spec.target,180000,float(move_spec.stop),"scale_inspection_"+String(move_spec.label))
		stages.append({"stage":move_spec.label,"movement":moved})
		if not moved.get("passed",false): return {"passed":false,"reason":"inspection_route_"+String(move_spec.label),"stages":stages}
	var gate_staging_move:=await _ordinary_move_to(gate_staging,180000,3.0,"scale_inspection_gate_staging")
	stages.append({"stage":"gate_staging","movement":gate_staging_move})
	if not gate_staging_move.get("passed",false): return {"passed":false,"reason":"inspection_route_gate_staging","stages":stages}
	var gate_route_bounds:=_route_bounds_for_world_points([gate_outside,gate_position,gate_inside],2)
	var gate_settlement:=await _wait_for_route_physical_settlement(gate_route_bounds,120000,"gate")
	stages.append({"stage":"gate_settlement","settlement":gate_settlement})
	if not gate_settlement.get("passed",false): return {"passed":false,"reason":"gate_detail_did_not_settle","stages":stages}
	var gate_door_settlement:=await _wait_for_live_door(String(gate_sample.id),gate_position,120000,"gate")
	stages.append({"stage":"gate_door_settlement","settlement":gate_door_settlement})
	if not gate_door_settlement.get("passed",false): return {"passed":false,"reason":"live_gate_door_missing","stages":stages}
	# Publish the exact gate route while the player is still at the clear corner.
	# Walking to the leaf first can legitimately make the occupancy guard retain
	# an overlapping collision packet indefinitely.
	var gate_alignment:=gate_position+outward*5.0
	var gate_alignment_move:=await _ordinary_move_to(gate_alignment,180000,3.0,"scale_inspection_gate_alignment",false)
	stages.append({"stage":"gate_alignment","movement":gate_alignment_move})
	if not gate_alignment_move.get("passed",false): return {"passed":false,"reason":"inspection_route_gate_alignment","stages":stages}
	# The source-derived point is measured from the leaf centre.  A closed
	# portcullis and the player's capsule reserve the final portion of that line;
	# standing on the approach's top landing is the intended usable exterior
	# pose.  The production interaction ray and post-open crossing below remain
	# the acceptance authorities for reachability and passage.
	var gate_approach:=await _ordinary_move_to(gate_outside,180000,0.85,"scale_inspection_gate_exterior",false,true)
	stages.append({"stage":"gate_exterior","movement":gate_approach})
	if not gate_approach.get("passed",false): return {"passed":false,"reason":"inspection_route_gate_exterior","stages":stages}
	var gate_door:=_live_door_by_part_id(String(gate_sample.id))
	if gate_door==null: return {"passed":false,"reason":"live_gate_door_missing","stages":stages}
	var gate_views:=await _capture_day_night_player_view("gate_exterior",gate_position+Vector3.UP*1.2)
	stages.append({"stage":"gate_views","views":gate_views})
	if not gate_views.get("passed",false): return {"passed":false,"reason":"gate_day_night_capture_failed","stages":stages}
	var gate_open:=await _toggle_door_with_player_input(gate_door,true,"citadel_gate_open")
	stages.append({"stage":"gate_open","interaction":gate_open})
	if not gate_open.get("passed",false): return {"passed":false,"reason":"gate_did_not_open_through_player_input","stages":stages}
	var gate_cross:=await _ordinary_move_to(gate_inside,45000,2.1,"scale_inspection_gate_cross",false,true)
	var gate_interior_clearance:=(player.global_position-gate_position).dot(-outward)
	gate_cross["gateInteriorClearance"]=gate_interior_clearance
	stages.append({"stage":"gate_cross","movement":gate_cross})
	if not gate_cross.get("passed",false) or gate_interior_clearance<=1.0:
		return {"passed":false,"reason":"gate_crossing_failed","stages":stages}
	var room_bounds: AABB=home.worldBounds
	var street_side:=signf(float(home.streetSide))
	var home_outside_x:=room_bounds.end.x+1.4 if street_side>0.0 else room_bounds.position.x-1.4
	var home_outside:=Vector3(home_outside_x,room_bounds.position.y,room_bounds.get_center().z)
	var home_staging_x:=room_bounds.end.x+8.0 if street_side>0.0 else room_bounds.position.x-8.0
	var home_staging:=Vector3(home_staging_x,room_bounds.position.y,room_bounds.get_center().z)
	var home_inside:=Vector3(room_bounds.get_center().x,room_bounds.position.y+0.2,room_bounds.get_center().z)
	# Each generated civic row can shift laterally with the terrace. Derive the
	# real gap between its paired façades; assuming one straight central X line
	# cuts through later offset rows on this valid seed.
	var civic_rows: Dictionary={}
	for home_value in evidence.sceneAudit.get("urbanHomeInteriors",[]):
		if not home_value is Dictionary: continue
		var row_home:=home_value as Dictionary
		var row_id:=String(row_home.get("id",""))
		var side:="left" if row_id.ends_with("_left") else ("right" if row_id.ends_with("_right") else "")
		if not row_id.begins_with("urban_row_") or side.is_empty(): continue
		var row_key:=row_id.trim_suffix("_"+side)
		if not civic_rows.has(row_key): civic_rows[row_key]={}
		civic_rows[row_key][side]=row_home
	var civic_row_spans: Array[Dictionary]=[]
	for row_key: String in civic_rows:
		var pair: Dictionary=civic_rows[row_key]
		if not pair.has("left") or not pair.has("right"): continue
		var first_bounds: AABB=(pair.left as Dictionary).worldBounds
		var second_bounds: AABB=(pair.right as Dictionary).worldBounds
		var west: AABB=first_bounds if first_bounds.position.x<second_bounds.position.x else second_bounds
		var east: AABB=second_bounds if first_bounds.position.x<second_bounds.position.x else first_bounds
		var gap_low:=west.end.x
		var gap_high:=east.position.x
		var overlap_low:=maxf(west.position.z,east.position.z)
		var overlap_high:=minf(west.end.z,east.end.z)
		if gap_high-gap_low<1.2 or overlap_high<=overlap_low: continue
		var row_floor_y:=(first_bounds.position.y+second_bounds.position.y)*0.5
		civic_row_spans.append({"point":Vector3((gap_low+gap_high)*0.5,row_floor_y,(overlap_low+overlap_high)*0.5),
			"lowZ":overlap_low,"highZ":overlap_high,"lowX":west.position.x,"highX":east.end.x,"rowId":row_key})
	civic_row_spans.sort_custom(func(a: Dictionary,b: Dictionary): return (a.point as Vector3).distance_squared_to(gate_position)<(b.point as Vector3).distance_squared_to(gate_position))
	if civic_row_spans.is_empty(): return {"passed":false,"reason":"source_civic_street_spine_missing","stages":stages}
	var travel_sign:=signf(home_staging.z-gate_position.z)
	if is_zero_approx(travel_sign): return {"passed":false,"reason":"source_civic_street_direction_missing","stages":stages}
	var civic_route_points: Array[Vector3]=[civic_row_spans[0].point]
	for row_index in range(1,civic_row_spans.size()):
		var previous: Dictionary=civic_row_spans[row_index-1]
		var following: Dictionary=civic_row_spans[row_index]
		var previous_edge:=float(previous.highZ if travel_sign>0.0 else previous.lowZ)
		var following_edge:=float(following.lowZ if travel_sign>0.0 else following.highZ)
		if (following_edge-previous_edge)*travel_sign<=0.2:
			return {"passed":false,"reason":"source_civic_row_transition_missing","stages":stages,
				"previousRow":previous.rowId,"followingRow":following.rowId}
		var transition_z:=(previous_edge+following_edge)*0.5
		civic_route_points.append(Vector3((previous.point as Vector3).x,room_bounds.position.y,transition_z))
		# The last paired row can carry an authored cross-lane structural span.
		# When the selected home is beyond that pair, remain in the open band
		# between rows, go around the pair's source AABB, then continue on its far
		# side. This uses generated extents and destination direction, not a seed or
		# collision-specific coordinate exception.
		var home_side:=signf(home_staging.x-(following.point as Vector3).x)
		var home_beyond_pair:=row_index==civic_row_spans.size()-1 and not is_zero_approx(home_side) \
			and (home_staging.x>float(following.highX) or home_staging.x<float(following.lowX))
		if home_beyond_pair:
			var bypass_x:=float(following.highX)+4.0 if home_side>0.0 else float(following.lowX)-4.0
			civic_route_points.append(Vector3(bypass_x,room_bounds.position.y,transition_z))
			civic_route_points.append(Vector3(bypass_x,room_bounds.position.y,
				float(following.highZ)+4.0 if travel_sign>0.0 else float(following.lowZ)-4.0))
		else:
			civic_route_points.append(Vector3((following.point as Vector3).x,room_bounds.position.y,transition_z))
			civic_route_points.append(following.point)
	# Shift from the final row gap toward the selected home's street side only
	# in the source-declared open band between that row and the home footprint.
	var last_span: Dictionary=civic_row_spans.back()
	var last_edge:=float(last_span.highZ if travel_sign>0.0 else last_span.lowZ)
	var home_near_edge:=room_bounds.position.z if travel_sign>0.0 else room_bounds.end.z
	if (home_near_edge-last_edge)*travel_sign<=0.2:
		return {"passed":false,"reason":"source_civic_home_transition_missing","stages":stages}
	var home_transition_z:=(last_edge+home_near_edge)*0.5
	civic_route_points.append(Vector3((civic_route_points.back() as Vector3).x,room_bounds.position.y,home_transition_z))
	civic_route_points.append(Vector3(home_staging.x,room_bounds.position.y,home_transition_z))
	civic_route_points.append(home_staging)
	var market_platform_target:=Vector3.INF
	for span: Dictionary in civic_row_spans:
		if String(span.rowId)=="urban_row_02":
			market_platform_target=span.point
			break
	if not market_platform_target.is_finite():
		return {"passed":false,"reason":"source_market_platform_row_missing","stages":stages}
	var market_capture_route_index:=0
	var market_capture_distance:=INF
	for route_index in range(civic_route_points.size()):
		var distance:=(civic_route_points[route_index] as Vector3).distance_squared_to(market_platform_target)
		if distance<market_capture_distance:
			market_capture_distance=distance
			market_capture_route_index=route_index
	# Photograph from the preceding ordinary street waypoint, rather than from
	# the plaza centre where its four approaches would be hidden beneath the
	# player's feet. The route remains generated-row-derived and collision-backed.
	market_capture_route_index=maxi(0,market_capture_route_index-1)
	var civic_lane_alignment:=Vector3(civic_route_points[0].x,room_bounds.position.y,player.global_position.z)
	var lane_alignment_move:=await _ordinary_move_to(civic_lane_alignment,45000,0.75,"scale_inspection_civic_lane_alignment",true,false,false)
	stages.append({"stage":"civic_lane_alignment","movement":lane_alignment_move})
	if not lane_alignment_move.get("passed",false): return {"passed":false,"reason":"civic_lane_alignment_failed","stages":stages}
	for route_index in range(civic_route_points.size()):
		# The generated street spine climbs successive source-authored terraces.
		# Hold ordinary jump across the lane rather than treating a terrace riser as
		# a flat-ground obstruction and oscillating against its static collider.
		var route_move:=await _ordinary_move_to(civic_route_points[route_index],60000,0.65,"scale_inspection_civic_route_%02d"%route_index,true,true)
		stages.append({"stage":"civic_route_%02d"%route_index,"movement":route_move,"sourcePoint":civic_route_points[route_index]})
		if not route_move.get("passed",false): return {"passed":false,"reason":"civic_route_failed","stages":stages}
	# Reaching the home tile submits its exact foreground closure through the
	# ordinary streaming owner. Give that handoff several real frames, then leave
	# the not-yet-active shared civic paving by the same collision-backed route.
	# The accepted packet remains retryable; activation must never occur beneath
	# the player merely to make this inspection proceed.
	for handoff_frame in range(30): await _frame()
	for route_index in range(civic_route_points.size()-1,-1,-1):
		var reverse_route:=await _ordinary_move_to(civic_route_points[route_index],60000,0.65,"scale_inspection_home_clearance_route_%02d"%route_index,true,true)
		stages.append({"stage":"home_clearance_route_%02d"%route_index,"movement":reverse_route,"sourcePoint":civic_route_points[route_index]})
		if not reverse_route.get("passed",false): return {"passed":false,"reason":"home_clearance_route_failed","stages":stages}
	# A home transaction may depend on shared civic paving whose collision spans
	# the gate landing. Wait at the already traversed exterior corner, beyond the
	# accepted visual/collision envelope, so the pinned packet can finish without
	# publishing beneath the player.
	var home_publication_clearance:=await _ordinary_move_to(corner_gate,180000,3.2,"scale_inspection_home_publication_clearance")
	stages.append({"stage":"home_publication_clearance","movement":home_publication_clearance})
	if not home_publication_clearance.get("passed",false):
		return {"passed":false,"reason":"home_publication_clearance_failed","stages":stages}
	var home_low:=room_bounds.position
	var home_high:=room_bounds.end
	var home_route_bounds:=_route_bounds_for_world_points([
		Vector3(home_low.x,home_low.y,home_low.z),Vector3(home_high.x,home_high.y,home_high.z),
		home_outside,home_inside],1)
	# Require the complete source-derived room, doorway and one-cell physical
	# border.  The separate staging point deliberately stays outside this proof:
	# including the player's current capsule in a replacement-collision query
	# correctly leaves its overlapping paving transactions occupancy-blocked and
	# would make an otherwise ready furnished room impossible to acknowledge.
	var home_settlement:=await _wait_for_route_physical_settlement(home_route_bounds,240000,"home")
	stages.append({"stage":"home_settlement","settlement":home_settlement})
	if not home_settlement.get("passed",false): return {"passed":false,"reason":"home_detail_did_not_settle","stages":stages}
	var home_door_id:=String(home.id)+"_door"
	var home_door_settlement:=await _wait_for_live_door(home_door_id,home_outside,120000,"home")
	stages.append({"stage":"home_door_settlement","settlement":home_door_settlement})
	if not home_door_settlement.get("passed",false): return {"passed":false,"reason":"live_home_door_missing","stages":stages}
	var return_gate_staging:=await _ordinary_move_to(gate_staging,180000,3.0,"scale_inspection_return_gate_staging")
	stages.append({"stage":"return_gate_staging","movement":return_gate_staging})
	if not return_gate_staging.get("passed",false): return {"passed":false,"reason":"return_gate_staging_failed","stages":stages}
	var return_gate_alignment:=await _ordinary_move_to(gate_alignment,60000,2.5,"scale_inspection_return_gate_alignment",false)
	stages.append({"stage":"return_gate_alignment","movement":return_gate_alignment})
	if not return_gate_alignment.get("passed",false): return {"passed":false,"reason":"return_gate_alignment_failed","stages":stages}
	var return_gate_cross:=await _ordinary_move_to(gate_inside,45000,2.0,"scale_inspection_return_gate_cross",false,true)
	stages.append({"stage":"return_gate_cross","movement":return_gate_cross})
	if not return_gate_cross.get("passed",false): return {"passed":false,"reason":"return_gate_cross_failed","stages":stages}
	var return_lane_alignment:=await _ordinary_move_to(civic_lane_alignment,45000,0.75,"scale_inspection_return_lane_alignment",true,false,false)
	stages.append({"stage":"return_lane_alignment","movement":return_lane_alignment})
	if not return_lane_alignment.get("passed",false): return {"passed":false,"reason":"return_lane_alignment_failed","stages":stages}
	for route_index in range(civic_route_points.size()):
		var return_route:=await _ordinary_move_to(civic_route_points[route_index],60000,0.65,"scale_inspection_return_route_%02d"%route_index,true,true)
		stages.append({"stage":"return_route_%02d"%route_index,"movement":return_route,"sourcePoint":civic_route_points[route_index]})
		if not return_route.get("passed",false): return {"passed":false,"reason":"return_route_failed","stages":stages}
		if route_index==market_capture_route_index:
			var market_views:=await _capture_day_night_player_view("market_platform_slope",market_platform_target+Vector3.UP*0.8)
			stages.append({"stage":"market_platform_slope_views","views":market_views,
				"sourceTarget":market_platform_target,"routeIndex":route_index})
			if not market_views.get("passed",false):
				return {"passed":false,"reason":"market_platform_slope_capture_failed","stages":stages}
	var street_move:=await _ordinary_move_to(home_outside,120000,0.65,"scale_inspection_civic_street",false,true)
	stages.append({"stage":"civic_street","movement":street_move})
	if not street_move.get("passed",false): return {"passed":false,"reason":"civic_street_route_failed","stages":stages}
	var home_door:=_live_door_by_part_id(home_door_id)
	if home_door==null: return {"passed":false,"reason":"live_home_door_missing","stages":stages}
	var street_views:=await _capture_day_night_player_view("civic_street",home_door.global_position+Vector3.UP*1.0)
	stages.append({"stage":"street_views","views":street_views})
	if not street_views.get("passed",false): return {"passed":false,"reason":"street_day_night_capture_failed","stages":stages}
	var home_open:=await _toggle_door_with_player_input(home_door,true,"citadel_home_open")
	stages.append({"stage":"home_open","interaction":home_open})
	if not home_open.get("passed",false): return {"passed":false,"reason":"home_door_did_not_open_through_player_input","stages":stages}
	var home_entry:=await _ordinary_move_to(home_inside,45000,1.25,"scale_inspection_home_entry",false,true)
	stages.append({"stage":"home_entry","movement":home_entry})
	var strict_room_xz:=Rect2(Vector2(room_bounds.position.x,room_bounds.position.z)+Vector2.ONE*0.45,
		Vector2(room_bounds.size.x,room_bounds.size.z)-Vector2.ONE*0.90)
	var strict_inside:=strict_room_xz.has_point(Vector2(player.global_position.x,player.global_position.z)) \
		and player.global_position.y>=room_bounds.position.y-0.20 and player.global_position.y<=room_bounds.end.y
	if not home_entry.get("passed",false) or not strict_inside:
		return {"passed":false,"reason":"strict_furnished_home_entry_failed","stages":stages,"roomBounds":room_bounds}
	var furniture_target:=home_inside+Vector3.UP*0.8
	var furniture_samples: Array=home.get("samples",[])
	if not furniture_samples.is_empty(): furniture_target=(furniture_samples[0] as Dictionary).get("position",furniture_target)+Vector3.UP*0.4
	var interior_views:=await _capture_day_night_player_view("furnished_home_interior",furniture_target)
	stages.append({"stage":"interior_views","views":interior_views,"strictInside":true,"roomBounds":room_bounds})
	if not interior_views.get("passed",false): return {"passed":false,"reason":"interior_day_night_capture_failed","stages":stages}
	var home_exit:=await _ordinary_move_to(home_outside,45000,1.0,"scale_inspection_home_exit",false,true)
	stages.append({"stage":"home_exit","movement":home_exit})
	if not home_exit.get("passed",false): return {"passed":false,"reason":"home_exit_failed","stages":stages}
	var home_close:=await _toggle_door_with_player_input(home_door,false,"citadel_home_close")
	stages.append({"stage":"home_close","interaction":home_close})
	if not home_close.get("passed",false): return {"passed":false,"reason":"home_door_close_failed","stages":stages}
	var stair_pose: Transform3D=stair_sample.transform
	var stair_target:=stair_pose*Vector3(0.0,float(stair_sample.size.y)*0.5+0.1,0.0)
	var stair_move:=await _ordinary_move_to(stair_target,120000,1.0,"scale_inspection_gate_stair")
	stages.append({"stage":"gate_stair","movement":stair_move})
	if not stair_move.get("passed",false): return {"passed":false,"reason":"gate_stair_route_failed","stages":stages}
	var stair_views:=await _capture_day_night_player_view("gate_stair",stair_target+Vector3.UP*1.0)
	stages.append({"stage":"stair_views","views":stair_views})
	if not stair_views.get("passed",false): return {"passed":false,"reason":"stair_day_night_capture_failed","stages":stages}
	return {"passed":true,"reason":"ordinary_player_scale_inspection_complete","stages":stages,
		"homeId":home.id,"roomBounds":room_bounds,"scope":"Source-derived perimeter itinerary, ordinary W/Shift/mouse input, production collision and right-click door interactions; no transform, motor or door-authority helper call."}

func _nearest_live_door(target: Vector3, max_distance: float) -> Node3D:
	var site: Node3D=main.structure_system.citadel_publication.scene_root(region)
	if not is_instance_valid(site): return null
	var best: Node3D=null
	var best_distance:=max_distance
	var stack: Array[Node]=[site]
	while not stack.is_empty():
		var node: Node=stack.pop_back()
		for child: Node in node.get_children(): stack.append(child)
		if node is Node3D and String(node.get_meta("block_type",""))=="door":
			var distance:=Vector2(node.global_position.x-target.x,node.global_position.z-target.z).length()
			if distance<=best_distance: best=node; best_distance=distance
	return best


func _live_door_by_part_id(part_id: String) -> Node3D:
	var site: Node3D=main.structure_system.citadel_publication.scene_root(region)
	if not is_instance_valid(site) or part_id.is_empty(): return null
	var stack: Array[Node]=[site]
	while not stack.is_empty():
		var node: Node=stack.pop_back()
		for child: Node in node.get_children(): stack.append(child)
		if node is Node3D and String(node.get_meta("block_type",""))=="door" \
				and String(node.get_meta("building_part_id",""))==part_id:
			return node as Node3D
	return null


func _wait_for_live_door(part_id: String, expected_position: Vector3, timeout_msec: int, label: String) -> Dictionary:
	phase="scale_inspection_live_door_settlement:"+label
	var begun:=Time.get_ticks_msec()
	var stable_frames:=0
	var last_publication: Dictionary={}
	while Time.get_ticks_msec()-begun<timeout_msec and _within_deadline():
		await _frame()
		var door:=_live_door_by_part_id(part_id)
		last_publication=main.structure_system.citadel_publication.stats()
		var current: bool=is_instance_valid(door) and door.global_position.distance_to(expected_position)<=0.25 \
			and last_publication.get("failures",{}).is_empty()
		stable_frames=stable_frames+1 if current else 0
		if stable_frames>=30:
			return {"passed":true,"reason":"source_door_live","partId":part_id,
				"elapsedMsec":Time.get_ticks_msec()-begun,"stableFrames":stable_frames,
				"position":door.global_position,"expectedPosition":expected_position}
	return {"passed":false,"reason":"source_door_not_live","partId":part_id,
		"elapsedMsec":Time.get_ticks_msec()-begun,"stableFrames":stable_frames,"publication":last_publication}

func _toggle_door_with_player_input(door: Node3D, desired_open: bool, label: String) -> Dictionary:
	if not is_instance_valid(door): return {"passed":false,"reason":"door_missing"}
	main.capture_mouse_if_no_modal()
	var hit: Dictionary={}
	var attempts:=0
	for attempt in range(120):
		attempts=attempt+1
		var target:=door.global_position+Vector3.UP*0.65
		var direction: Vector3=(target-player.camera.global_position).normalized()
		var yaw_delta:=wrapf(atan2(-direction.x,-direction.z)-player.global_rotation.y,-PI,PI)
		var pitch_delta:=atan2(direction.y,Vector2(direction.x,direction.z).length())-float(player.get("pitch"))
		var motion:=InputEventMouseMotion.new()
		motion.relative=Vector2(-yaw_delta,-pitch_delta)*0.12/maxf(0.0001,float(player.get("mouse_sensitivity")))
		if bool(player.get("invert_y")): motion.relative.y=-motion.relative.y
		root.push_input(motion)
		await physics_frame
		await _frame()
		hit=main.focused_interaction_hit()
		if main.interaction_block_from_collider(hit.get("collider"))==door: break
	if main.interaction_block_from_collider(hit.get("collider"))!=door:
		return {"passed":false,"reason":"door_not_in_production_interaction_ray","attempts":attempts,"hit":hit}
	for pressed: bool in [true,false]:
		var click:=InputEventMouseButton.new()
		click.button_index=MOUSE_BUTTON_RIGHT; click.pressed=pressed
		click.position=root.get_visible_rect().size*0.5; click.global_position=click.position
		root.push_input(click)
	for frame in range(24): await physics_frame
	var actual_open:=bool(door.get_meta("open",false))
	return {"passed":actual_open==desired_open,"reason":"door_state_reached" if actual_open==desired_open else "door_state_mismatch",
		"label":label,"attempts":attempts,"desiredOpen":desired_open,"actualOpen":actual_open,
		"doorPath":String(main.get_path_to(door)),"scope":"Production focus ray and ordinary viewport right-click input."}

func _capture_day_night_player_view(label: String, target: Vector3) -> Dictionary:
	var aimed:=false
	var aim_attempts:=0
	for attempt in range(10):
		aim_attempts=attempt+1
		if await _look_toward_world_xz(target):
			aimed=true
			break
		await physics_frame
	if not aimed: return {"passed":false,"reason":"player_view_aim_failed","aimAttempts":aim_attempts}
	var day_saved:=await _capture("player_day_"+label,"ordinary_player_viewport")
	var original_launch_options: Dictionary=main.launch_options
	var original_force_daytime:=bool(original_launch_options.forceDaytime)
	var original_time:=float(main.time_of_day)
	var inspection_launch_options: Dictionary=original_launch_options.duplicate(true)
	inspection_launch_options.forceDaytime=false
	main.launch_options=inspection_launch_options
	main.time_of_day=0.75
	for frame in range(12): await _frame()
	var night_environment:={"clockPhase":main.clock_phase(),"nightFactor":main.clock_night_factor(),"weather":main.weather_system.snapshot()}
	var night_saved:=await _capture("player_night_"+label,"ordinary_player_viewport")
	main.launch_options=original_launch_options
	main.time_of_day=original_time
	for frame in range(12): await _frame()
	var restored:=not original_force_daytime or is_equal_approx(main.clock_phase(),0.5)
	return {"passed":day_saved and night_saved and float(night_environment.nightFactor)>0.75 and restored,
		"daySaved":day_saved,"nightSaved":night_saved,"nightEnvironment":night_environment,"daytimeRestored":restored,
		"aimAttempts":aim_attempts,
		"scope":"Same live player pose/camera under production day and night sky updates; a delimited diagnostic clock change is restored after capture."}

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
	# A near-spawn diagnostic needs only a short demand window.  The explicit
	# far-start mode keeps using ordinary input across the wilderness until the
	# accepted reservation actually enters the production view; do not turn its
	# representative journey into a 20-second stationary/timeout artefact.
	var far_discovery: bool=bool(evidence.get("sourceDiscoveryApproach",{}).get("active",false))
	# The measured wilderness route can include several collision-recovery
	# detours before the retained window reaches a roughly 400 m Citadel.  Keep
	# this below the overall watchdog while allowing representative sprint travel
	# to reach exact demand without changing position or bypassing collision.
	# A scale soak must first earn its comparable near state through the same
	# kilometre-scale ordinary approach. Allow recovery around generated cliffs
	# without weakening the ordinary-input or collision requirements.
	var far_budget_msec:=360000 if scale_soak_seconds>0 else 240000
	var until := mini(deadline-10000,begun+(far_budget_msec if far_discovery else 20000))
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
	# A speculative publication-base job is intentionally allowed to finish well
	# before the player reaches the accepted reservation.  It cannot end this
	# movement proof.  Only an exact source demand may promote worker activity to
	# the demanded-packet boundary observed by the fixture.
	var inflight: Dictionary = publication._inflight
	var exact_demand: bool = publication._desired.has(region) or publication._demand_started_usec.has(region)
	if exact_demand and inflight.get("region") == region and inflight.get("binding",{}) == source_binding \
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
	var selected: Dictionary=select_candidate(found,requested_region)
	var selected_distance := 0.0
	for row: Dictionary in found:
		if row.candidate==selected: selected_distance=float(row.distanceWorld); break
	return {"originRegion":origin,"ringRadius":SEARCH_RING,"regionsExamined":(SEARCH_RING*2+1)*(SEARCH_RING*2+1),"candidates":found,
		"selected":selected,"selectedDistanceWorld":selected_distance,"nearestWithinSearchOnly":requested_region.is_empty(),
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
		var compact_movement_observer := phase.begins_with("ordinary_input_") or phase.begins_with("scale_soak_leave_") or phase.begins_with("scale_soak_revisit_")
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
	if is_instance_valid(main) and main.structure_system != null \
			and main.structure_system.citadel_publication != null \
			and main.structure_system.citadel_publication.has_method("profile_scene_unit_metrics"):
		evidence.publicationStageProfile = main.structure_system.citadel_publication.profile_scene_unit_metrics()
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
		"manualInspectionSeconds":manual_seconds,"scaleSoakSeconds":scale_soak_seconds,
		"playerInspectionOnly":player_inspection_only,
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

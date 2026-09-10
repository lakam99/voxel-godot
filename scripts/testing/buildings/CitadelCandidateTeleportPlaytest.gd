extends SceneTree
## Headed teleport-assisted diagnostic, never continuous-travel/NPC acceptance.
## Two bounded setup placements are supported; all generated content is ordinary.
const MainScene = preload("res://scenes/Main.tscn")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Gate = preload("res://scripts/terrain/VoxelTerrainSiteGate.gd")
const Clearance = preload("res://scripts/world/GeneratedStructurePlayerClearance.gd")
const RenderObservation = preload("res://scripts/perf/RuntimeRenderObservation.gd")
const SEARCH_RING := 2
const VIEW_CELLS := 112
const MAX_SETUP_WRITES := 2

class SeededMain extends "res://scripts/Main.gd":
	# The title UI has no seed entry. Seed and optional initial cell are fixture-owned:
	# actual New Game, tutorial, systems, terrain and observer startup are inherited.
	var diagnostic_seed := "atlas-30895044"
	var diagnostic_spawn_cell := ""
	var diagnostic_spawn_evidence: Dictionary = {}
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
	main.set("deferred_startup_boot",true)
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
	await physics_frame
	await _frame()
	evidence.sceneAudit = await _audit_scene()
	checks.scene_audit = evidence.sceneAudit.get("passed",false)
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
		checks.close_approach=evidence.approach.get("reached",false)
		if not await _capture("close"):
			await _finish("failed","close_capture_failed"); return
		if not checks.close_approach:
			await _finish("failed",String(evidence.approach.get("reason","approach_blocked"))); return
		evidence.inspectionViews=await _capture_inspection_views()
		checks.inspection_views=evidence.inspectionViews.passed
		if not checks.inspection_views:
			await _finish("failed","inspection_capture_failed"); return
	await _finish("scene_ready" if checks.scene_audit else "failed","" if checks.scene_audit else "scene_observation_failed")

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
	for sample: Dictionary in evidence.sceneAudit.get("structureSamples",[]):
		var pose: Transform3D=sample.transform
		var local_view := Vector3(0,sample.size.y*0.5+1.6,-1.0)
		var local_target := Vector3(0,sample.size.y*0.5+0.3,1.5)
		if sample.kind=="door": local_view=Vector3(0,0.3,-2.0); local_target=Vector3.ZERO
		views.append({"label":sample.id,"position":pose*local_view,"target":pose*local_target})
	for sample: Dictionary in evidence.sceneAudit.furnitureSamples.slice(0,2):
		var body := main.get_node_or_null(NodePath(sample.path)) as Node3D
		if body==null: return {"passed":false,"reason":"furniture_sample_disappeared"}
		var record: Dictionary=body.get_meta("furnishing_part_record")
		var size: Vector3=record.occupiedSize
		views.append({"label":"furniture_%d"%views.size(),"position":body.to_global(Vector3(0,size.y+0.8,maxf(size.x,size.z)+1.0)),
			"target":body.to_global(Vector3(0,size.y*0.5,0)),"furniture":sample})
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
		"scope":"Diagnostic camera views of unchanged production scene; no player placement, movement, interaction or navigation acceptance."}

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
		"groundY":main.ground_y_near_position(player.global_position),"contacts":contacts}

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
			"recoveryCount":recovery_count,"motion":_approach_motion_snapshot(),"performance":main.runtime_perf_monitor.summary()})
		previous=position
		if not await _look_toward_candidate(): reason="approach_mouse_look_failed"; break
	_release_approach_keys()
	await physics_frame
	await _frame()
	await _look_toward_candidate()
	var identity := _accepted_current()
	var capsule := Clearance.inspect(player)
	evidence.closeVisibility=_inspect_visibility()
	return {"reached":reached and identity.passed and capsule.passed,"reason":reason if identity.passed and capsule.passed else "approach_identity_or_capsule_failed",
		"elapsedMsec":Time.get_ticks_msec()-begun,"from":start_position,"to":player.global_position,"distanceToVisualBounds":distance,"samples":samples,"capsule":capsule,"identity":identity,
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
	if label=="accepted_reservation_exterior":
		for choice: Vector2i in choices: heights[choice]=_staging_surface(choice,ceili(radius/cell_size))
	choices.sort_custom(func(a: Vector2i,b: Vector2i)->bool:
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
		"viewpointPolicy":"highest ordinary-ground side midpoint" if not heights.is_empty() else "nearest exterior","candidateGroundHeights":heights})
	return _outside(bounds)

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
	if is_instance_valid(player): value.playerPosition = player.global_position; value.playerPhysics = player.is_physics_processing()
	return value

func _audit_scene() -> Dictionary:
	var service = main.structure_system.citadel_publication
	var site: Node3D = service.scene_root(region)
	var result := {"passed":false,"nodeCount":0,"meshes":0,"multiMeshes":0,"instances":0,"collisionShapes":0,"furnitureBodies":0,"trees":0,"doors":0,"badBindings":[],"physicsProbes":[]}
	if not is_instance_valid(site) or site.get_parent()!=main: return result
	# Retain existing bounded counters once, after publication. These are
	# observations only and must never participate in scene acceptance.
	var publication_entry: Dictionary = service._scenes.get(region,{})
	if publication_entry.get("binding",{}) == source_binding and publication_entry.has("job"):
		var publication_job = publication_entry.job
		result["publicationJobMetrics"] = publication_job.status()
		result["preparationTimings"] = {}
		var begin_metrics: Dictionary = publication_job._cpu.get("buildingBegin",{})
		checks.preparation_timing_complete = true
		for key in ["preparationUsec","routeUsec","physicalUsec","metadataPreparationUsec","historyPreparationUsec","masonryPreparationUsec"]:
			var value: Variant = begin_metrics.get(key)
			checks.preparation_timing_complete = checks.preparation_timing_complete and value is int and value>=0
			result.preparationTimings[key] = value
		var surfaces: Dictionary=begin_metrics.get("surfacePreparationUsec",{})
		for family: String in ["paving","roof"]:
			var value: Variant=surfaces.get(family)
			checks.preparation_timing_complete=checks.preparation_timing_complete and value is int and value>=0
			result.preparationTimings[family+"PreparationUsec"]=value
		result.preparationTimings["unavailable"] = []
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
		if record.get("collision",false): source_parts[record.id]=record
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
						if semantic in ["castle_keep_stair_exit","castle_keep_stair_landing","castle_gatehouse_wall_stair_exit","castle_gatehouse_wall_stair_landing","citadel_upper_lane"] or part_id in ["urban_row_00_left_door","urban_row_00_right_door","urban_row_03_left_door","urban_row_03_right_door"]:
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
	result.passed = stack.is_empty() and result.rootMatchesProfile and result.rootVisible and result.visibleGeometry>0 and have_bounds and result.ownersAvailable and result.sourceStillMatches and result.badBindings.is_empty() and result.meshes+result.instances>0 and result.collisionShapes>0 and result.furnitureBodies>0 and result.doors>0 and not result.physicsProbes.is_empty() and result.physicsProbes.all(func(p):return p.registeredInPhysics) and result.capsule.passed
	result.passed = result.passed and result.collisionMismatches.is_empty() and source_parts.size()==seen_collisions.size() and not source_parts.is_empty()
	return result

func _audit_stair_clearance() -> Dictionary:
	var observations := []
	var capsule := CapsuleShape3D.new()
	capsule.radius=0.42; capsule.height=1.72
	for sample: Dictionary in evidence.sceneAudit.get("structureSamples",[]):
		if not String(sample.semantic).begins_with("castle_"): continue
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
	evidence.cameraLook = {"passed":passed,"inputEvents":attempts,"initialYawErrorRadians":initial_error,"finalYawErrorRadians":final_error,
		"finalPitchErrorRadians":final_pitch,"target":_inspection_target(),
		"toleranceRadians":0.03,"ordinaryMouseGuardAccepts":main.should_accept_mouse_look(),"guardBypassed":false}
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
	if startup_message_index.has(message):
		var index: int = startup_message_index[message]
		startup_messages[index].count += 1
		startup_messages[index].lastElapsedMsec = _elapsed()
		return
	if startup_messages.size()>=128:
		startup_message_overflow += 1
		return
	startup_message_index[message]=startup_messages.size()
	startup_messages.append({"message":message,"count":1,"firstElapsedMsec":_elapsed(),"lastElapsedMsec":_elapsed()})

func _append_timeline(entry: Dictionary) -> void:
	if timeline.size()>=256:
		timeline.pop_front()
		timeline_dropped += 1
	timeline.append(entry)

func _within_deadline() -> bool: return evidence_error.is_empty() and Time.get_ticks_msec()<deadline
func _elapsed() -> int: return Time.get_ticks_msec()-started

func _frame() -> void:
	await process_frame
	if Time.get_ticks_msec()>=next_progress:
		next_progress = Time.get_ticks_msec()+1000
		last_observation = _observe()
		# Once per progress tick: actual engine gauges, never summed frame counters.
		if Engine.has_singleton("VoxelEngine"):
			var voxel_engine = Engine.get_singleton("VoxelEngine")
			var sample := {"elapsedMsec":_elapsed(),"phase":phase,"stats":voxel_engine.get_stats()}
			last_observation["voxelWorkers"] = sample
			if worker_samples.size()<720: worker_samples.append(sample)
			else: worker_samples_dropped += 1
		if main.runtime_perf_monitor != null:
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

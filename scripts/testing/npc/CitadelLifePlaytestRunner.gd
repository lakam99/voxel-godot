extends Node

## Interactive visual composition of a seeded citadel with the production NPC
## registry, CharacterBody3D agents, collision-backed route authority and door
## portals. The fixture owns only its seed, civic orders and presentation.
## It does not introduce a citadel-specific movement, door or home system.

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const CastleFurnishingPlannerScript := preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const BuildingBlueprintScript := preload("res://scripts/buildings/BuildingBlueprint.gd")
const FurnishingPlanScript := preload("res://scripts/buildings/FurnishingPlan.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")
const FurnishingPublisherScript := preload("res://scripts/buildings/FurnishingPublisher.gd")
const CitadelResidenceManifestBuilderScript := preload("res://scripts/buildings/CitadelResidenceManifestBuilder.gd")
const PlaytestSurvivalPolicyScript := preload("res://scripts/testing/PlaytestSurvivalPolicy.gd")
const NpcBipedRecipeBuilderScript := preload("res://scripts/characters/NpcBipedRecipeBuilder.gd")
const NpcBipedVisualFactoryScript := preload("res://scripts/characters/NpcBipedVisualFactory.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const CELL := 1.35
const WATER_LEVEL := 11.1
const DEFAULT_SEED := 208158
const DEFAULT_CITADEL_SCALE := 1.25
const NAV_PUBLICATION_SETTLE_FRAMES := 180
const CIVIC_ORDERS_PER_FRAME := 2
const TERRAIN_SITE_SAMPLE_GRID := 8
const DEFAULT_TERRAIN_SITE_READINESS_MAX_FRAMES := 3600
const MAX_TERRAIN_SITE_READINESS_MAX_FRAMES := 7200
const TERRAIN_CHUNK_SIZE := 28
const INITIAL_RELEVANT_DISTRICTS := 3
const DISTRICT_PREFETCH_INTERVAL := 0.40
const CITIZEN_SPAWNS_PER_FRAME := 1
const CITIZEN_SPAWN_MAX_ATTEMPTS := 16
const MAX_FAILURE_DIAGNOSTIC_CAPTURES := 12
const MAX_DAY_DEPARTURE_TIMEOUT_CAPTURES := 3
const DEFAULT_ACCEPTANCE_DAY_SECONDS := 12.0
const DEFAULT_ACCEPTANCE_NIGHT_SECONDS := 24.0
const CROWD_LINEUP_MIN_SECONDS := 18.0
const CROWD_LINEUP_MAX_SECONDS := 240.0
const CROWD_LINEUP_MIN_PROGRESS_MPS := 0.55
const CROWD_LINEUP_ROUTE_GRACE_SECONDS := 15.0
const CROWD_LINEUP_ROUTE_PUBLICATION_SECONDS := 60.0
const CROWD_LINEUP_STABLE_PHYSICS_FRAMES := 30
const CROWD_CROSSING_SECONDS := 24.0
const CROWD_FORMATION_SLOT_MARGIN := 0.28
const CROWD_FORMATION_LANE_OFFSET := 0.65
const CROWD_FORMATION_ARRIVAL_RADIUS := 0.36
const ACCEPTANCE_ORDER_ADMISSION_TIMEOUT_MS := 8000.0
const ACCEPTANCE_ORDER_ADMISSION_MAX_MS := 2000.0
const ACCEPTANCE_ORDER_ADMISSION_MAX_PROCESS_FRAMES := 120

var main: Node3D
var player: CharacterBody3D
var npc_system: Node
var citadel_root: Node3D
var furnishing_root: Node3D
var building_publisher
var furnishing_publisher
var building_publishers: Array = []
var registered_building_navigation_ids: Dictionary = {}
var furnishing_publishers: Array = []
var registered_navigation_collision_manifest_ids: Dictionary = {}
var blueprint
var furnishing_plan
var core_blueprint
var residence_manifest: Dictionary = {}
var fixture_origin := Vector3.ZERO
var fixture_center := Vector2i.ZERO
var fixture_level := 0.0
var fixture_site: Dictionary = {}
var selected_seed := DEFAULT_SEED
var selected_citadel_scale := DEFAULT_CITADEL_SCALE
var observed_world_phase := ""
var civic_order_elapsed := 0.0
var civic_order_round := 0
var civic_order_generation := 0
var civic_order_queue: Array[Dictionary] = []
var civic_order_metrics := {
	"queued": 0,
	"submitted": 0,
	"superseded": 0,
	"discarded": 0
}
var civic_order_batches: Array[Dictionary] = []
var rebuilding := false
var fixture_failure_reason := ""
var citizens: Array[Dictionary] = []
var spawned_citizen_ids := {}
var queued_citizen_ids := {}
var pending_citizen_spawns: Array[Dictionary] = []
var citizen_spawn_metrics := {
	"queued": 0,
	"placed": 0,
	"retries": 0,
	"terminalFailures": 0,
	"lastFailureReasons": {},
	"lastFailureDetails": {},
	"collisionAudits": {}
}
var district_catalog: Array[Dictionary] = []
var active_district_ids := {}
var registered_door_instance_ids := {}
var district_publication_running := false
var district_publication_generation := 0
var district_prefetch_elapsed := 0.0
var status_label: Label
var loading_overlay: Control
var loading_label: Label
var loading_elapsed := 0.0
var loading_message := "Preparing Citadel Life"
var profile_mode := false
var profile_seconds := 20.0
var profile_started_usec := 0
var profile_load_completed_usec := 0
var profile_stage_name := ""
var profile_stage_started_usec := 0
var profile_stages: Array[Dictionary] = []
var profile_phase_samples: Array[Dictionary] = []
var profile_report_path := ""
var profile_progress_path := ""
var profile_run_token := ""
var profile_screenshot_dir := ""
var visual_captures: Array[Dictionary] = []
var acceptance_mode := false
var acceptance_timeline: Array[Dictionary] = []
var acceptance_result: Dictionary = {}
var acceptance_failure_diagnostics: Array[Dictionary] = []
var acceptance_post_navigation_audit: Dictionary = {}
var acceptance_order_admissions: Dictionary = {}
var acceptance_day_seconds := DEFAULT_ACCEPTANCE_DAY_SECONDS
var acceptance_night_seconds := DEFAULT_ACCEPTANCE_NIGHT_SECONDS
var link_diagnostics_mode := false
var link_diagnostics: Array[Dictionary] = []
var profile_status_elapsed := 0.0
var status_elapsed := 0.0
var crowd_physics_evidence: Dictionary = {}
var crowd_capture_pending := false
var crowd_capture_count := 0
var crowd_first_encounter_capture_requested := false
var crowd_reverse_capture_requested := false
var crowd_recovery_capture_requested := false
var crowd_recovery_baseline_by_actor_id: Dictionary = {}
var crowd_stress_result: Dictionary = {}
var crowd_stress_active := false
var crowd_formation_assignment_by_actor_id: Dictionary = {}
var crowd_crossing_targets_by_actor_id: Dictionary = {}


func _ready() -> void:
	read_arguments()
	build_overlay()
	request_visual_capture("loading_boot")
	call_deferred("bootstrap")


func read_arguments() -> void:
	profile_report_path = OS.get_environment("VOXEL_CITADEL_LIFE_REPORT").strip_edges()
	profile_progress_path = OS.get_environment("VOXEL_CITADEL_LIFE_PROGRESS").strip_edges()
	profile_run_token = OS.get_environment("VOXEL_CITADEL_LIFE_RUN_TOKEN").strip_edges()
	profile_screenshot_dir = OS.get_environment("VOXEL_CITADEL_LIFE_SCREENSHOT_DIR").strip_edges()
	var args := OS.get_cmdline_user_args()
	for index in range(args.size()):
		var argument := String(args[index])
		if argument == "--seed" and index + 1 < args.size():
			selected_seed = int(String(args[index + 1]))
		elif argument == "--citadel-scale" and index + 1 < args.size():
			selected_citadel_scale = clampf(float(String(args[index + 1])), 0.75, 2.25)
		elif argument == "--profile":
			profile_mode = true
		elif argument == "--profile-seconds" and index + 1 < args.size():
			profile_mode = true
			profile_seconds = clampf(float(String(args[index + 1])), 4.0, 120.0)
		elif argument == "--acceptance":
			profile_mode = true
			acceptance_mode = true
		elif argument == "--acceptance-day-seconds" and index + 1 < args.size():
			acceptance_day_seconds = clampf(float(String(args[index + 1])), 4.0, 120.0)
		elif argument == "--acceptance-night-seconds" and index + 1 < args.size():
			acceptance_night_seconds = clampf(float(String(args[index + 1])), 4.0, 120.0)
		elif argument == "--link-diagnostics":
			profile_mode = true
			link_diagnostics_mode = true


func bootstrap() -> void:
	profile_started_usec = Time.get_ticks_usec()
	profile_stages.clear()
	profile_phase_samples.clear()
	visual_captures.clear()
	acceptance_timeline.clear()
	acceptance_result.clear()
	crowd_stress_result.clear()
	acceptance_failure_diagnostics.clear()
	acceptance_post_navigation_audit.clear()
	acceptance_order_admissions.clear()
	link_diagnostics.clear()
	reset_crowd_physics_evidence()
	profile_begin_stage("ordinary_game_boot")
	set_loading("Starting the ordinary game scene")
	OS.set_environment("VOXEL_TEST_SEED", "citadel-life-world-%d" % selected_seed)
	OS.set_environment("VOXEL_PLAYTEST", "1")
	main = MAIN_SCENE.instantiate() as Node3D
	add_child(main)
	await get_tree().process_frame
	bind_scene_nodes()
	profile_end_stage("ordinary_game_boot")
	if main == null or player == null or npc_system == null:
		fail_fixture_loading("Citadel Life could not bind the production player or NPC system")
		return
	configure_live_fixture()
	profile_begin_stage("ordinary_world_startup_settle")
	set_loading("Waiting for the ordinary world startup to settle")
	await wait_physics_frames(36)
	profile_end_stage("ordinary_world_startup_settle")
	await rebuild_citadel()
	if profile_mode and not rebuilding and main != null and not citizens.is_empty():
		if link_diagnostics_mode:
			collect_manor_stair_link_diagnostics()
			write_profile_report("completed")
		elif acceptance_mode:
			await run_citadel_life_acceptance()
		else:
			await run_profile_observation()
		await prepare_profile_shutdown()
		get_tree().quit()


func bind_scene_nodes() -> void:
	if main == null:
		return
	player = main.get("player") as CharacterBody3D
	npc_system = main.get("npc_system") as Node


func configure_live_fixture() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if main.has_method("apply_runtime_setting"):
		main.call("apply_runtime_setting", "headBob", false, false)
		main.call("apply_runtime_setting", "handSway", false, false)
	var hud = main.get("hud")
	if hud != null and hud.get("hud_root") is Control:
		(hud.get("hud_root") as Control).visible = false
	ensure_fixture_clock_is_unlocked()
	PlaytestSurvivalPolicyScript.enable_player_god_mode(main, "citadel_life_playtest")
	enable_interactive_player()


func enable_interactive_player() -> void:
	# This is an interactive fixture layered over Main's staged startup. Its real
	# CharacterBody3D is deliberately returned to normal player authority after
	# fixture setup; no synthetic movement path is introduced.
	if player == null:
		return
	player.set("automated_input", false)
	player.set("automated_move", Vector3.ZERO)
	player.set("automated_sprint", false)
	player.set("automated_jump", false)
	player.set_physics_process(true)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func rebuild_citadel() -> void:
	if rebuilding:
		return
	rebuilding = true
	fixture_failure_reason = ""
	observed_world_phase = ""
	civic_order_queue.clear()
	civic_order_metrics = {"queued": 0, "submitted": 0, "superseded": 0, "discarded": 0}
	civic_order_batches.clear()
	if not profile_mode:
		profile_stages.clear()
		profile_phase_samples.clear()
	profile_begin_stage("fixture_reset")
	set_loading("Retiring the previous published citadel")
	if npc_system != null and npc_system.has_method("clear"):
		npc_system.call("clear")
	citizens.clear()
	spawned_citizen_ids.clear()
	queued_citizen_ids.clear()
	pending_citizen_spawns.clear()
	citizen_spawn_metrics = {"queued": 0, "placed": 0, "retries": 0, "terminalFailures": 0, "lastFailureReasons": {}, "lastFailureDetails": {}, "collisionAudits": {}}
	district_catalog.clear()
	active_district_ids.clear()
	registered_door_instance_ids.clear()
	for building_id_value in registered_building_navigation_ids.keys():
		if npc_system != null and npc_system.has_method("unregister_building_navigation_manifest"):
			npc_system.call("unregister_building_navigation_manifest", String(building_id_value))
	registered_building_navigation_ids.clear()
	for manifest_id_value in registered_navigation_collision_manifest_ids.keys():
		if npc_system != null and npc_system.has_method("unregister_navigation_collision_manifest"):
			npc_system.call("unregister_navigation_collision_manifest", String(manifest_id_value))
	registered_navigation_collision_manifest_ids.clear()
	district_publication_generation += 1
	district_publication_running = false
	district_prefetch_elapsed = 0.0
	building_publishers.clear()
	furnishing_publishers.clear()
	if citadel_root != null and is_instance_valid(citadel_root):
		citadel_root.queue_free()
	if furnishing_root != null and is_instance_valid(furnishing_root):
		furnishing_root.queue_free()
	citadel_root = null
	furnishing_root = null
	await get_tree().process_frame
	profile_end_stage("fixture_reset")

	profile_begin_stage("recipe_and_site_selection")
	set_loading("Sampling seed %d castle and residence recipes" % selected_seed)
	await get_tree().process_frame
	blueprint = CastleCompoundBlueprintBuilderScript.build(selected_seed, {
		"biome": "forest",
		"siteKey": "citadel-life",
		"citadelScale": selected_citadel_scale
	})
	var recipe: Dictionary = blueprint.recipe if blueprint != null else {}
	var span := maxf(float(recipe.get("width", 80.0)), float(recipe.get("depth", 80.0)))
	fixture_site = select_fixture_site(span)
	fixture_center = fixture_site.get("center", Vector2i.ZERO) as Vector2i
	fixture_level = float(fixture_site.get("level", WATER_LEVEL + 3.0))
	fixture_origin = Vector3(float(fixture_center.x) * CELL, fixture_level, float(fixture_center.y) * CELL)
	var terrain_radius := int(fixture_site.get("radius", ceili(span / CELL * 0.50) + 6))
	profile_end_stage("recipe_and_site_selection", {
		"blueprintPartCount": blueprint.parts.size() if blueprint != null else 0,
		"terrainRadius": terrain_radius,
		"span": span,
		"site": fixture_site.duplicate(true)
	})

	profile_begin_stage("terrain_site_preparation")
	set_loading("Reserving the selected Citadel site through terrain authority")
	move_player_for_streaming(span)
	fixture_site["streaming"] = configure_fixture_streaming_window(span)
	var site_reservation := await reserve_fixture_terrain_site()
	if not bool(site_reservation.get("ready", false)):
		profile_end_stage("terrain_site_preparation", site_reservation)
		fail_fixture_loading("The deterministic Citadel site could not reach terrain authority", site_reservation)
		return
	fixture_site["terrainReservation"] = site_reservation.duplicate(true)
	fixture_site["foundationMode"] = "terrain_generation_reservation"
	set_loading("Staging authoritative terrain collision for the reserved site")
	clear_blocks_near_cell(fixture_center, terrain_radius)
	clear_props_near_cell(fixture_center, terrain_radius + 8)
	if main.has_method("update_chunks"):
		main.call("update_chunks", false)
	var terrain_readiness := await wait_for_fixture_terrain_readiness(span)
	terrain_readiness["siteReservation"] = site_reservation.duplicate(true)
	if not bool(terrain_readiness.get("ready", false)):
		profile_end_stage("terrain_site_preparation", terrain_readiness)
		fail_fixture_loading("Terrain and collision did not finish publishing", terrain_readiness)
		return
	var surface_contract := reserved_site_surface_contract()
	terrain_readiness["siteSurfaceContract"] = surface_contract
	if not bool(surface_contract.get("ready", false)):
		profile_end_stage("terrain_site_preparation", terrain_readiness)
		fail_fixture_loading("Reserved terrain site did not publish an agreed foundation surface", terrain_readiness)
		return
	await claim_fixture_population_ownership()
	profile_end_stage("terrain_site_preparation", terrain_readiness)

	profile_begin_stage("furnishing_recipe")
	set_loading("Planning seeded interiors before district publication")
	await get_tree().process_frame
	furnishing_plan = CastleFurnishingPlannerScript.build(blueprint, selected_seed * 7919 + 37, fixture_origin)
	profile_end_stage("furnishing_recipe", {"furnishingPartCount": furnishing_plan.parts.size() if furnishing_plan != null else 0})

	core_blueprint = core_blueprint_slice(blueprint)
	district_catalog = district_catalog_from(blueprint, furnishing_plan)
	profile_begin_stage("structure_publication")
	set_loading("Publishing the shared castle core (%d records)" % core_blueprint.parts.size())
	citadel_root = Node3D.new()
	citadel_root.name = "CitadelLifePublishedShell"
	citadel_root.position = fixture_origin
	add_child(citadel_root)
	furnishing_root = Node3D.new()
	furnishing_root.name = "CitadelLifePublishedFurnishings"
	furnishing_root.position = fixture_origin
	add_child(furnishing_root)
	building_publisher = BuildingPartPublisherScript.new()
	await building_publisher.publish_incremental(core_blueprint, citadel_root, loading_frame_budget(core_blueprint.parts.size()), {"batchStaticParts": true})
	building_publishers.append(building_publisher)
	register_published_building_navigation_manifest(building_publisher)
	for _district_index in range(mini(INITIAL_RELEVANT_DISTRICTS, district_catalog.size())):
		await publish_next_relevant_district(district_publication_generation, true)
	if profile_mode:
		set_loading("Completing all districts for the full Citadel performance profile")
		while active_district_ids.size() < district_catalog.size():
			await publish_next_relevant_district(district_publication_generation, true)
	# District publication deliberately contains both construction and furnishing
	# work, so preserve one truthful wall-clock stage and retain the publishers'
	# independent measured work totals in its metrics.  Do not emit a misleading
	# near-zero furnishing stage after its work has already completed.
	profile_end_stage("structure_publication", {
		"buildingPublication": building_publication_summary(),
		"furnishingPublication": furnishing_publication_summary()
	})

	profile_begin_stage("navigation_publication")
	set_loading("Publishing ordinary structure and door facts to NPC systems")
	publish_structure_navigation_fact(span)
	register_published_doors()
	if npc_system.has_method("flush_navigation_change_bus"):
		npc_system.call("flush_navigation_change_bus")
	await wait_physics_frames(8)
	var topology_prebake: Dictionary = npc_system.call("prebake_building_navigation_topology") as Dictionary if npc_system.has_method("prebake_building_navigation_topology") else { "ok": false, "reason": "missing_topology_prebake" }
	if not bool(topology_prebake.get("ok", false)):
		profile_end_stage("navigation_publication", { "buildingTopologyPrebake": topology_prebake })
		fail_fixture_loading("Published Citadel building topology could not pre-bake into NavMesh tiles", topology_prebake)
		return
	profile_end_stage("navigation_publication", { "buildingTopologyPrebake": topology_prebake })

	profile_begin_stage("residence_manifest")
	set_loading("Resolving every bed into a deterministic citizen home")
	residence_manifest = CitadelResidenceManifestBuilderScript.build(blueprint, furnishing_plan, CELL, fixture_origin)
	profile_end_stage("residence_manifest", {"residentCount": (residence_manifest.get("citizens", []) as Array).size()})
	profile_begin_stage("navigation_settle")
	set_loading("Allowing published terrain, doors and collision-backed navigation to settle")
	await wait_physics_frames(NAV_PUBLICATION_SETTLE_FRAMES)
	profile_end_stage("navigation_settle")
	profile_begin_stage("citizen_materialization")
	queue_manifest_citizens()
	var citizen_materialization: Dictionary = await wait_for_initial_citizen_materialization()
	if not bool(citizen_materialization.get("ready", false)):
		profile_end_stage("citizen_materialization", citizen_materialization)
		fail_fixture_loading("Citadel residents could not safely materialize from their bed manifest", citizen_materialization)
		return
	profile_end_stage("citizen_materialization", citizen_materialization)
	place_player_at_gate(recipe)
	enable_interactive_player()
	rebuilding = false
	set_world_display_hour(11.0)
	refresh_world_phase(true)
	profile_begin_stage("fixture_hud_presentation")
	update_status()
	await get_tree().process_frame
	profile_end_stage("fixture_hud_presentation")
	set_loading_visible(false)
	await capture_viewport("interactive_ready")
	profile_load_completed_usec = Time.get_ticks_usec()
	write_profile_report("ready")
	print("[Citadel Life] Ready: seed %d, %d citizens, %d furnished beds" % [selected_seed, citizens.size(), (residence_manifest.get("citizens", []) as Array).size()])
	if not profile_mode:
		request_relevant_district_publication()


func publish_structure_navigation_fact(span: float) -> void:
	if npc_system == null or not npc_system.has_method("notify_navigation_structure_metadata_changed"):
		return
	var height := maxf(float(blueprint.recipe.get("wallHeight", 16.0)), 12.0)
	var bounds := AABB(
		fixture_origin + Vector3(-span * 0.5, 0.0, -span * 0.5),
		Vector3(span, height + 8.0, span)
	)
	npc_system.call("notify_navigation_structure_metadata_changed", String(blueprint.id), bounds, {
		"source": "citadel_life_playtest",
		"family": "castle",
		"published": true
	})


func register_published_building_navigation_manifest(publisher) -> void:
	if publisher == null or npc_system == null or not npc_system.has_method("register_building_navigation_manifest"):
		return
	var publication: Dictionary = publisher.summary() if publisher.has_method("summary") else {}
	var manifest: Dictionary = publication.get("navigationManifest", {}) if publication.get("navigationManifest", {}) is Dictionary else {}
	if manifest.is_empty():
		return
	var result: Dictionary = npc_system.call("register_building_navigation_manifest", manifest)
	if bool(result.get("ok", false)):
		registered_building_navigation_ids[String(result.get("buildingId", ""))] = true


func register_published_furnishing_navigation_manifest(publisher) -> void:
	if publisher == null or npc_system == null or not npc_system.has_method("register_navigation_collision_manifest"):
		return
	var publication: Dictionary = publisher.summary() if publisher.has_method("summary") else {}
	var manifest: Dictionary = publication.get("navigationManifest", {}) if publication.get("navigationManifest", {}) is Dictionary else {}
	if manifest.is_empty():
		return
	var result: Dictionary = npc_system.call("register_navigation_collision_manifest", manifest)
	if bool(result.get("ok", false)):
		registered_navigation_collision_manifest_ids[String(result.get("manifestId", ""))] = true


func core_blueprint_slice(source):
	var core = BuildingBlueprintScript.new("%s.core" % String(source.id), int(source.seed), String(source.style))
	var source_recipe: Dictionary = source.recipe.duplicate(true)
	source_recipe["sourceBlueprintId"] = String(source.id)
	core.set_recipe(source_recipe)
	var core_rooms: Array = []
	for room_value in source.rooms:
		if room_value is Dictionary and not bool((room_value as Dictionary).get("castleCourtyardResidence", false)):
			core_rooms.append(room_value)
	core.set_room_records(core_rooms)
	for part in source.parts:
		if part == null:
			continue
		if String(part.recipe.get("castleResidenceId", "")).is_empty():
			core.parts.append(part)
	return core


func district_catalog_from(source, source_furnishing_plan) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var residences: Array = source.recipe.get("courtyardResidences", []) as Array
	for residence_value in residences:
		if not (residence_value is Dictionary):
			continue
		var residence: Dictionary = residence_value as Dictionary
		var residence_id := String(residence.get("id", "")).strip_edges()
		if residence_id.is_empty():
			continue
		var district_blueprint = BuildingBlueprintScript.new("%s.district.%s" % [String(source.id), residence_id], int(source.seed), String(source.style))
		var source_recipe: Dictionary = source.recipe.duplicate(true)
		source_recipe["sourceBlueprintId"] = String(source.id)
		district_blueprint.set_recipe(source_recipe)
		var rooms: Array = []
		for room_value in source.rooms:
			if room_value is Dictionary and String((room_value as Dictionary).get("id", "")).begins_with("%s_" % residence_id):
				rooms.append(room_value)
		district_blueprint.set_room_records(rooms)
		for part in source.parts:
			if part != null and String(part.recipe.get("castleResidenceId", "")) == residence_id:
				district_blueprint.parts.append(part)
		var district_plan = FurnishingPlanScript.new("%s.district.%s" % [String(source_furnishing_plan.id), residence_id], int(source_furnishing_plan.seed), String(source.id))
		for furnishing_part in source_furnishing_plan.parts:
			if furnishing_part != null and String(furnishing_part.recipe.get("castleResidenceId", "")) == residence_id:
				district_plan.parts.append(furnishing_part)
		var center: Vector3 = residence.get("center", Vector3.ZERO) as Vector3
		records.append({
			"id": residence_id,
			"center": center,
			"blueprint": district_blueprint,
			"furnishingPlan": district_plan
		})
	records.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return String(left.get("id", "")) < String(right.get("id", ""))
	)
	return records


func publish_next_relevant_district(generation: int, loading_publication := false) -> bool:
	if generation != district_publication_generation or citadel_root == null or furnishing_root == null:
		return false
	var selected := next_relevant_district()
	if selected.is_empty():
		return false
	var district_id := String(selected.get("id", ""))
	if district_id.is_empty():
		return false
	if loading_publication:
		set_loading("Publishing nearby district %s (%d/%d)" % [district_id, active_district_ids.size() + 1, district_catalog.size()])
	var shell_root := Node3D.new()
	shell_root.name = "CitadelDistrict_%s" % district_id
	citadel_root.add_child(shell_root)
	var district_blueprint = selected.get("blueprint")
	if district_blueprint == null:
		shell_root.queue_free()
		return false
	var building = BuildingPartPublisherScript.new()
	await building.publish_incremental(district_blueprint, shell_root, loading_frame_budget(district_blueprint.parts.size()), {"batchStaticParts": true})
	if generation != district_publication_generation or not is_instance_valid(citadel_root):
		shell_root.queue_free()
		return false
	var decor_root := Node3D.new()
	decor_root.name = "CitadelDistrictFurnishings_%s" % district_id
	furnishing_root.add_child(decor_root)
	var district_furnishing_plan = selected.get("furnishingPlan")
	if district_furnishing_plan == null:
		shell_root.queue_free()
		decor_root.queue_free()
		return false
	var furnishing = FurnishingPublisherScript.new()
	await furnishing.publish_incremental(district_furnishing_plan, decor_root, loading_frame_budget(district_furnishing_plan.parts.size()))
	if generation != district_publication_generation or not is_instance_valid(furnishing_root):
		shell_root.queue_free()
		decor_root.queue_free()
		return false
	active_district_ids[district_id] = true
	building_publishers.append(building)
	register_published_building_navigation_manifest(building)
	furnishing_publishers.append(furnishing)
	register_published_furnishing_navigation_manifest(furnishing)
	register_published_doors()
	if npc_system != null and npc_system.has_method("flush_navigation_change_bus"):
		npc_system.call("flush_navigation_change_bus")
	if npc_system != null and npc_system.has_method("prebake_building_navigation_topology"):
		npc_system.call("prebake_building_navigation_topology")
	queue_manifest_citizens()
	return true


func next_relevant_district() -> Dictionary:
	var candidates: Array[Dictionary] = []
	var origin := player.global_position if player != null else fixture_origin
	var facing := Vector3.FORWARD.rotated(Vector3.UP, player.global_rotation.y) if player != null else Vector3.FORWARD
	for district_value in district_catalog:
		if not (district_value is Dictionary):
			continue
		var district: Dictionary = district_value as Dictionary
		var district_id := String(district.get("id", ""))
		if district_id.is_empty() or active_district_ids.has(district_id):
			continue
		var local_center: Vector3 = district.get("center", Vector3.ZERO) as Vector3
		var offset := fixture_origin + local_center - origin
		var horizontal := Vector3(offset.x, 0.0, offset.z)
		var distance := horizontal.length()
		var direction := horizontal.normalized() if distance > 0.001 else facing
		# Distance is the principal order. Facing content wins only as a small,
		# deterministic tie-break so walking toward a street never leaves invisible
		# collision in front of the player.
		var score := distance - maxf(0.0, facing.dot(direction)) * CELL * 5.0
		var candidate := district.duplicate()
		candidate["relevanceScore"] = score
		candidates.append(candidate)
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_score := float(left.get("relevanceScore", INF))
		var right_score := float(right.get("relevanceScore", INF))
		if not is_equal_approx(left_score, right_score):
			return left_score < right_score
		return String(left.get("id", "")) < String(right.get("id", ""))
	)
	return candidates[0] if not candidates.is_empty() else {}


func request_relevant_district_publication() -> void:
	if rebuilding or district_publication_running or active_district_ids.size() >= district_catalog.size():
		return
	district_publication_running = true
	call_deferred("publish_relevant_district_background", district_publication_generation)


func publish_relevant_district_background(generation: int) -> void:
	await publish_next_relevant_district(generation, false)
	district_publication_running = false


func building_publication_summary() -> Dictionary:
	var summary := {"publisherCount": building_publishers.size(), "publishedPartCount": 0, "collisionPartCount": 0, "publishedNodeCount": 0, "visualBatchCount": 0, "publicationUsec": 0, "recipeBuildUsec": 0}
	for publisher in building_publishers:
		if publisher == null or not publisher.has_method("summary"):
			continue
		var item: Dictionary = publisher.summary()
		for key in ["publishedPartCount", "collisionPartCount", "publishedNodeCount", "visualBatchCount", "publicationUsec", "recipeBuildUsec"]:
			summary[key] = int(summary.get(key, 0)) + int(item.get(key, 0))
	summary["batchedStaticParts"] = true
	return summary


func furnishing_publication_summary() -> Dictionary:
	var summary := {"publisherCount": furnishing_publishers.size(), "publishedPartCount": 0, "collisionPartCount": 0, "visualPieceCount": 0, "publicationUsec": 0}
	for publisher in furnishing_publishers:
		if publisher == null or not publisher.has_method("summary"):
			continue
		var item: Dictionary = publisher.summary()
		for key in ["publishedPartCount", "collisionPartCount", "visualPieceCount", "publicationUsec"]:
			summary[key] = int(summary.get(key, 0)) + int(item.get(key, 0))
	return summary


func register_published_doors() -> void:
	if citadel_root == null or npc_system == null or not npc_system.has_method("notify_navigation_door_registered"):
		return
	register_published_doors_recursive(citadel_root)


func register_published_doors_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is StaticBody3D:
			var body := child as StaticBody3D
			var instance_id := body.get_instance_id()
			if String(body.get_meta("building_part_kind", "")) == "door" and not registered_door_instance_ids.has(instance_id):
				# BuildingPartPublisher has already created this exact collision body and
				# DoorPortalService will own its open/close state.  Give the ordinary
				# generated-world navigation index that same body and its world cell so a
				# route can prove a legal door edge rather than treating the house wall as
				# an opaque static barrier.  This is classification of the published door,
				# not a proxy collider or an alternate structure representation.
				register_published_door_navigation_body(body)
				npc_system.call("notify_navigation_door_registered", body)
				registered_door_instance_ids[instance_id] = true
		register_published_doors_recursive(child)


func register_published_door_navigation_body(door: StaticBody3D) -> void:
	if door == null or not is_instance_valid(door) or main == null:
		return
	var blocks_value = main.get("blocks")
	if not (blocks_value is Dictionary):
		return
	var door_cell := Vector3i(
		roundi(door.global_position.x / CELL),
		roundi(door.global_position.y / CELL),
		roundi(door.global_position.z / CELL)
	)
	door.set_meta("cell", door_cell)
	door.set_meta("block_type", "door")
	door.set_meta("building_navigation_source", "published_building_part")
	var blocks: Dictionary = blocks_value
	blocks[door_cell] = door
	if npc_system.has_method("notify_navigation_block_created"):
		npc_system.call("notify_navigation_block_created", door_cell, "door", door)


func claim_fixture_population_ownership() -> void:
	# Main may still finish publishing its ordinary tutorial/town roster after the
	# first setup frames. Claiming those generic population domains is the public
	# scenario composition contract; the fixture then registers exactly the
	# bed-derived Citadel Life citizens through the same production NpcSystem.
	if npc_system == null:
		return
	if npc_system.has_method("clear"):
		npc_system.call("clear")
	if npc_system.has_method("claim_town_population"):
		var structure_system = main.get("structure_system") if main != null else null
		if structure_system != null and structure_system.has_method("town_home_records_snapshot"):
			var records_by_town: Dictionary = structure_system.call("town_home_records_snapshot")
			for town_key_value in records_by_town.keys():
				npc_system.call("claim_town_population", String(town_key_value), "citadel_life_fixture")
		npc_system.call("claim_town_population", "citadel-life-fixture", "citadel_life_fixture")
	await wait_physics_frames(2)
func queue_manifest_citizens() -> void:
	if npc_system == null:
		return
	var citizen_records: Array = residence_manifest.get("citizens", []) as Array
	for index in range(citizen_records.size()):
		var citizen: Dictionary = citizen_records[index] as Dictionary
		var citizen_id := String(citizen.get("id", ""))
		var residence_id := String(citizen.get("residenceId", ""))
		if citizen_id.is_empty() or not active_district_ids.has(residence_id) or spawned_citizen_ids.has(citizen_id) or queued_citizen_ids.has(citizen_id):
			continue
		queued_citizen_ids[citizen_id] = true
		pending_citizen_spawns.append({
			"citizen": citizen,
			"index": index,
			"attempt": 0,
			"retryAfterFrame": Engine.get_process_frames()
		})
	citizen_spawn_metrics["queued"] = pending_citizen_spawns.size()


func process_citizen_materialization_queue() -> void:
	if npc_system == null or pending_citizen_spawns.is_empty():
		return
	var spawned_this_frame := 0
	var frame := Engine.get_process_frames()
	while spawned_this_frame < CITIZEN_SPAWNS_PER_FRAME and not pending_citizen_spawns.is_empty():
		var request: Dictionary = pending_citizen_spawns.pop_front() as Dictionary
		if frame < int(request.get("retryAfterFrame", frame)):
			pending_citizen_spawns.append(request)
			break
		var citizen: Dictionary = request.get("citizen", {}) as Dictionary
		var citizen_id := String(citizen.get("id", ""))
		if citizen_id.is_empty() or spawned_citizen_ids.has(citizen_id):
			queued_citizen_ids.erase(citizen_id)
			continue
		var index := int(request.get("index", 0))
		var attempt := int(request.get("attempt", 0))
		# Residents enter the real fixture at their assigned bed-side home cell.
		# Daytime civic movement starts only after every body has passed placement,
		# preventing several citizens from contending for a few street anchors while
		# still claiming to originate from their declared homes.
		var home_cell: Vector2i = citizen.get("homeCell", Vector2i.ZERO) as Vector2i
		var home_level := float(citizen.get("level", fixture_level))
		var spawn_position: Vector3 = npc_system.call("cell_to_position", home_cell, home_level) as Vector3
		var spawn_result: Dictionary = spawn_citizen(citizen, spawn_position, index)
		if bool(spawn_result.get("ok", false)):
			var body := spawn_result.get("body") as CharacterBody3D
			if body != null:
				citizens.append({"body": body, "manifest": citizen, "index": index, "locomotion": body.get_node_or_null("NpcBipedVisual/NpcBipedLocomotionPresenter")})
				spawned_citizen_ids[citizen_id] = true
				queued_citizen_ids.erase(citizen_id)
				citizen_spawn_metrics["placed"] = int(citizen_spawn_metrics.get("placed", 0)) + 1
				spawned_this_frame += 1
				continue
		var reason := String(spawn_result.get("reason", "unknown_spawn_rejection"))
		var reasons: Dictionary = citizen_spawn_metrics.get("lastFailureReasons", {}) as Dictionary
		reasons[reason] = int(reasons.get(reason, 0)) + 1
		citizen_spawn_metrics["lastFailureReasons"] = reasons
		var placement: Dictionary = spawn_result.get("placement", {}) as Dictionary
		var detail := "%s:%s@%s" % [reason, String(placement.get("collider", "")), str(spawn_position)]
		var details: Dictionary = citizen_spawn_metrics.get("lastFailureDetails", {}) as Dictionary
		details[detail] = int(details.get(detail, 0)) + 1
		citizen_spawn_metrics["lastFailureDetails"] = details
		var collision_audits: Dictionary = citizen_spawn_metrics.get("collisionAudits", {}) as Dictionary
		if not collision_audits.has(detail):
			collision_audits[detail] = spawn_occupancy_audit(spawn_result.get("body") as CharacterBody3D, spawn_position)
			citizen_spawn_metrics["collisionAudits"] = collision_audits
		if attempt + 1 >= CITIZEN_SPAWN_MAX_ATTEMPTS:
			queued_citizen_ids.erase(citizen_id)
			citizen_spawn_metrics["terminalFailures"] = int(citizen_spawn_metrics.get("terminalFailures", 0)) + 1
			continue
		request["attempt"] = attempt + 1
		request["retryAfterFrame"] = frame + mini(90, 4 + (attempt + 1) * 6)
		pending_citizen_spawns.append(request)
		citizen_spawn_metrics["retries"] = int(citizen_spawn_metrics.get("retries", 0)) + 1
		spawned_this_frame += 1
	citizen_spawn_metrics["queued"] = pending_citizen_spawns.size()


func spawn_occupancy_audit(body: CharacterBody3D, position: Vector3) -> Array[Dictionary]:
	# Diagnostic only: mirrors the public safe-placement shape query so a fixture
	# failure names the actual production collider.  It never decides placement or
	# alters collision/routing policy.
	var records: Array[Dictionary] = []
	if body == null or body.get_world_3d() == null:
		return records
	var motor_profile = CharacterMotorProfileScript.npc_default()
	var capsule := CapsuleShape3D.new()
	capsule.radius = float(motor_profile.get("capsule_radius"))
	capsule.height = float(motor_profile.get("capsule_height"))
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.transform = Transform3D(Basis(), position + Vector3(0.0, capsule.height * 0.5, 0.0))
	query.collision_mask = NpcConstantsScript.COLLISION_NPC_SAFE_PLACEMENT_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [body.get_rid()]
	var hits: Array = body.get_world_3d().direct_space_state.intersect_shape(query, 12)
	for hit in hits:
		var hit_dict: Dictionary = hit as Dictionary
		var collider := hit_dict.get("collider") as Node
		if collider == null or collider == body:
			continue
		records.append({
			"name": collider.name,
			"path": String(collider.get_path()),
			"class": collider.get_class(),
			"kind": String(collider.get_meta("kind", "")),
			"blockType": String(collider.get_meta("block_type", "")),
			"buildingKind": String(collider.get_meta("building_part_kind", "")),
			"buildingSemantic": String(collider.get_meta("building_semantic", "")),
			"collisionLayer": int((collider as CollisionObject3D).collision_layer) if collider is CollisionObject3D else 0
		})
	return records


func wait_for_initial_citizen_materialization() -> Dictionary:
	var expected_count := expected_active_citizen_count()
	for frame in range(720):
		process_citizen_materialization_queue()
		if citizens.size() == expected_count and pending_citizen_spawns.is_empty():
			return {"ready": true, "expectedCitizenCount": expected_count, "activeCitizenCount": citizens.size(), "waitedFrames": frame, "spawnQueue": citizen_spawn_metrics.duplicate(true)}
		await get_tree().process_frame
	return {"ready": false, "reason": "citizen_materialization_timeout", "expectedCitizenCount": expected_count, "activeCitizenCount": citizens.size(), "waitedFrames": 720, "spawnQueue": citizen_spawn_metrics.duplicate(true)}


func expected_active_citizen_count() -> int:
	var count := 0
	for citizen_value in residence_manifest.get("citizens", []) as Array:
		if citizen_value is Dictionary and active_district_ids.has(String((citizen_value as Dictionary).get("residenceId", ""))):
			count += 1
	return count


func spawn_citizen(citizen: Dictionary, position: Vector3, index: int) -> Dictionary:
	var body := npc_system.call("create_npc_body", "CitadelCitizen%02d" % (index + 1), "npc") as CharacterBody3D
	if body == null:
		return {"ok": false, "reason": "create_npc_body_failed"}
	npc_system.call("add_npc_collider", body)
	var npc_root := npc_system.get("npc_root") as Node3D
	if npc_root != null:
		npc_root.add_child(body)
	else:
		npc_system.add_child(body)
	var placement: Dictionary = npc_system.call("safe_place_npc", body, position, null, "citadel_life_day_spawn") as Dictionary
	if not bool(placement.get("ok", false)):
		body.queue_free()
		return {"ok": false, "reason": String(placement.get("reason", "safe_placement_rejected")), "placement": placement, "body": body}
	# Attach the visual only after the real CharacterBody3D has completed the
	# production safe-placement contract, so a rejected body never becomes a
	# visible origin placeholder.
	var profile_id := String(citizen.get("id", "citadel_citizen_%d" % index))
	var appearance_recipe := NpcBipedRecipeBuilderScript.build(selected_seed + index * 104729, profile_id)
	NpcBipedVisualFactoryScript.add_biped(body, appearance_recipe, "Citizen %02d" % (index + 1))
	var profile := citizen.duplicate(true)
	profile.merge({
		"name": "Citizen %02d" % (index + 1),
		"displayRole": "Citizen",
		"townKey": "citadel-life:%s" % String(blueprint.id),
		"job": "civic",
		"canFight": false,
		"nightGuard": false
	}, true)
	npc_system.call("register_npc", body, profile)
	return {"ok": true, "body": body, "placement": placement}


func begin_civic_day() -> void:
	civic_order_elapsed = 0.0
	issue_civic_orders()


func issue_civic_orders() -> void:
	civic_order_round += 1
	var staged: Array[Dictionary] = []
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		var index := int(citizen_entry.get("index", 0))
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		var is_departure_round := civic_order_round == 1
		var target := civic_departure_anchor(manifest) if is_departure_round else civic_anchor_for(index, civic_order_round)
		# Civic targets live on the shared courtyard/street surface, not on the
		# citizen's bed storey. A manor resident can sleep upstairs but must still
		# receive a ground-level public target when leaving home for the day.
		if not is_departure_round:
			target.y = civic_walk_level() + 0.04
		staged.append({
			"body": body,
			"kind": "go_to",
			"target": target,
			"arrivalRadius": CELL * 1.10,
			"reason": "citadel_life_civic_departure" if is_departure_round else "citadel_life_civic_day",
			"index": index
		})
	replace_civic_order_queue(staged, "day")


func civic_departure_anchor(manifest: Dictionary) -> Vector3:
	# The first daytime objective is a normal public go-to order at the resident's
	# declared porch. This proves the home/door boundary before the subsequent
	# wider street-wander orders begin, without embedding a city-specific route.
	var porch_position = manifest.get("porchPosition", Vector3.INF)
	if porch_position is Vector3 and (porch_position as Vector3).is_finite():
		return porch_position
	var porch_cell: Vector2i = manifest.get("porchCell", manifest.get("homeCell", Vector2i.ZERO)) as Vector2i
	# A citizen may sleep on an upper interior floor, while the porch is always
	# part of the shared exterior paving.  Use that published surface height for
	# the public target; sending an upstairs bed height to an outdoor porch leaves
	# the regular collision-backed planner no physically valid endpoint.
	return npc_system.call("cell_to_position", porch_cell, civic_walk_level() + 0.04) as Vector3


func begin_civic_night() -> void:
	var staged: Array[Dictionary] = []
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		if body != null and is_instance_valid(body):
			staged.append({
				"body": body,
				"kind": "go_home",
				"reason": "citadel_life_world_clock_return",
				"index": int(citizen_entry.get("index", 0))
			})
	replace_civic_order_queue(staged, "night")


func stage_crowd_crossing_orders(crossing: bool) -> Dictionary:
	var endpoints := crowd_crossing_endpoints()
	if endpoints.is_empty():
		return {"ok": false, "reason": "missing_crowd_crossing_endpoints"}
	var left: Vector3 = endpoints.get("left", Vector3.ZERO)
	var right: Vector3 = endpoints.get("right", Vector3.ZERO)
	var axis := right - left
	axis.y = 0.0
	if axis.length_squared() <= 0.001:
		return {"ok": false, "reason": "degenerate_crowd_crossing_axis"}
	var side := Vector3(-axis.z, 0.0, axis.x).normalized()
	if not crossing:
		crowd_formation_assignment_by_actor_id = _build_crowd_formation_assignment(left, right, side)
	if crowd_formation_assignment_by_actor_id.size() != citizens.size():
		return {"ok": false, "reason": "incomplete_crowd_formation_assignment", "assignmentCount": crowd_formation_assignment_by_actor_id.size()}
	var staged: Array[Dictionary] = []
	var targets := {}
	var initial_distances := {}
	var maximum_initial_distance := 0.0
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		var index := int(citizen_entry.get("index", 0))
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		var actor_id := String(manifest.get("id", body.name))
		var assignment: Dictionary = crowd_formation_assignment_by_actor_id.get(actor_id, {}) if crowd_formation_assignment_by_actor_id.get(actor_id, {}) is Dictionary else {}
		var group_index := int(assignment.get("slotIndex", 0))
		var group_size := maxi(1, int(assignment.get("groupSize", 1)))
		var starts_left := String(assignment.get("source", "left")) == "left"
		var source_endpoint := left if starts_left else right
		var destination_endpoint := right if starts_left else left
		var travel_direction := axis.normalized() if starts_left else -axis.normalized()
		var travel_right := Vector3(-travel_direction.z, 0.0, travel_direction.x)
		var centered_slot := float(group_index) - float(group_size - 1) * 0.5
		var queue_offset := -travel_direction * centered_slot * crowd_formation_slot_spacing()
		var target := destination_endpoint if crossing else source_endpoint
		target += travel_right * CROWD_FORMATION_LANE_OFFSET + queue_offset
		target.y = civic_walk_level() + 0.04
		var initial_distance := Vector2(body.global_position.x - target.x, body.global_position.z - target.z).length()
		targets[actor_id] = target
		initial_distances[actor_id] = initial_distance
		maximum_initial_distance = maxf(maximum_initial_distance, initial_distance)
		var staged_entry := {
			"body": body,
			"kind": "go_to" if crossing else "wait",
			"reason": "citadel_life_crowd_crossing" if crossing else "citadel_life_crowd_lineup",
			"index": index
		}
		if crossing:
			staged_entry["target"] = target
			staged_entry["arrivalRadius"] = CROWD_FORMATION_ARRIVAL_RADIUS
		staged.append(staged_entry)
	var phase := "crowd_crossing" if crossing else "crowd_lineup"
	var envelope_validation := validate_crowd_target_arrival_envelopes(targets)
	if crossing:
		crowd_crossing_targets_by_actor_id = targets.duplicate(true)
	replace_civic_order_queue(staged, phase)
	return {
		"ok": staged.size() == citizens.size() and bool(envelope_validation.get("ok", false)),
		"phase": phase,
		"expectedCount": citizens.size(),
		"queuedCount": staged.size(),
		"endpoints": endpoints,
		"targets": targets,
		"initialDistances": initial_distances,
		"maximumInitialDistance": maximum_initial_distance,
		"arrivalEnvelopeValidation": envelope_validation
	}


func crowd_formation_required_separation() -> float:
	var maximum_navigation_radius := float(CharacterMotorProfileScript.npc_default().get("capsule_radius"))
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		var npc_entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
		var profile = npc_entry.get("motorProfile")
		if profile != null:
			maximum_navigation_radius = maxf(maximum_navigation_radius, float(profile.get("capsule_radius")))
	return (maximum_navigation_radius + NpcConstantsScript.AVOIDANCE_RADIUS_SAFETY_MARGIN) * 2.0


func crowd_formation_slot_spacing() -> float:
	return crowd_formation_required_separation() + CROWD_FORMATION_ARRIVAL_RADIUS * 2.0 + CROWD_FORMATION_SLOT_MARGIN


func validate_crowd_target_arrival_envelopes(targets: Dictionary) -> Dictionary:
	var actor_ids := targets.keys()
	actor_ids.sort()
	var minimum_distance := INF
	var minimum_pair: Array[String] = []
	for left_index in range(actor_ids.size()):
		var left = targets.get(actor_ids[left_index])
		if not (left is Vector3):
			continue
		for right_index in range(left_index + 1, actor_ids.size()):
			var right = targets.get(actor_ids[right_index])
			if not (right is Vector3):
				continue
			var distance := Vector2(left.x - right.x, left.z - right.z).length()
			if distance < minimum_distance:
				minimum_distance = distance
				minimum_pair = [String(actor_ids[left_index]), String(actor_ids[right_index])]
	var required := crowd_formation_slot_spacing()
	return {
		"ok": minimum_distance + 0.001 >= required,
		"minimumTargetDistance": minimum_distance,
		"requiredTargetDistance": required,
		"minimumPair": minimum_pair,
		"arrivalRadius": CROWD_FORMATION_ARRIVAL_RADIUS,
		"avoidanceRequired": crowd_formation_required_separation()
	}


func _build_crowd_formation_assignment(left: Vector3, right: Vector3, side: Vector3) -> Dictionary:
	var candidates: Array = []
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		var actor_id := String(manifest.get("id", body.name))
		var left_distance := Vector2(body.global_position.x - left.x, body.global_position.z - left.z).length()
		var right_distance := Vector2(body.global_position.x - right.x, body.global_position.z - right.z).length()
		candidates.append({
			"actorId": actor_id,
			"body": body,
			"sideScore": left_distance - right_distance
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var score_a := float(a.get("sideScore", 0.0))
		var score_b := float(b.get("sideScore", 0.0))
		if not is_equal_approx(score_a, score_b):
			return score_a < score_b
		return String(a.get("actorId", "")) < String(b.get("actorId", ""))
	)
	var left_count := ceili(float(candidates.size()) * 0.5)
	var left_group: Array = candidates.slice(0, left_count)
	var right_group: Array = candidates.slice(left_count)
	var result := {}
	_assign_crowd_group_slots(result, left_group, "left", left, side)
	_assign_crowd_group_slots(result, right_group, "right", right, side)
	return result


func _assign_crowd_group_slots(result: Dictionary, group: Array, source: String, endpoint: Vector3, side: Vector3) -> void:
	group.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var body_a := a.get("body") as CharacterBody3D
		var body_b := b.get("body") as CharacterBody3D
		var lateral_a := (body_a.global_position - endpoint).dot(side) if body_a != null else 0.0
		var lateral_b := (body_b.global_position - endpoint).dot(side) if body_b != null else 0.0
		if not is_equal_approx(lateral_a, lateral_b):
			return lateral_a < lateral_b
		return String(a.get("actorId", "")) < String(b.get("actorId", ""))
	)
	for slot_index in range(group.size()):
		var actor_id := String((group[slot_index] as Dictionary).get("actorId", ""))
		result[actor_id] = {
			"source": source,
			"slotIndex": slot_index,
			"groupSize": group.size()
		}


func place_crowd_lineup_fixture(setup: Dictionary) -> Dictionary:
	var targets: Dictionary = setup.get("targets", {}) if setup.get("targets", {}) is Dictionary else {}
	var endpoints: Dictionary = setup.get("endpoints", {}) if setup.get("endpoints", {}) is Dictionary else {}
	var left_endpoint: Vector3 = endpoints.get("left", Vector3.ZERO)
	var right_endpoint: Vector3 = endpoints.get("right", Vector3.ZERO)
	var crossing_axis := right_endpoint - left_endpoint
	crossing_axis.y = 0.0
	var crossing_side := Vector3(-crossing_axis.z, 0.0, crossing_axis.x).normalized() if crossing_axis.length_squared() > 0.001 else Vector3.RIGHT
	var placements := {}
	var placed_count := 0
	var retry_entries: Array[Dictionary] = []
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		var actor_id := String(manifest.get("id", body.name if body != null else ""))
		if body == null or not is_instance_valid(body) or not (targets.get(actor_id) is Vector3):
			placements[actor_id] = {"ok": false, "reason": "missing_body_or_target"}
			continue
		var target: Vector3 = targets.get(actor_id)
		var placement: Dictionary = npc_system.call("safe_place_npc", body, target, null, "citadel_crowd_pre_act_lineup") as Dictionary
		placements[actor_id] = placement.duplicate(true)
		if bool(placement.get("ok", false)):
			body.velocity = Vector3.ZERO
			body.set_meta("npc_requested_velocity", Vector3.ZERO)
			body.set_meta("npc_applied_velocity", Vector3.ZERO)
			placed_count += 1
			await get_tree().physics_frame
		else:
			retry_entries.append({"actorId": actor_id, "body": body, "target": target, "attempts": [placement.duplicate(true)]})
	if not retry_entries.is_empty():
		await get_tree().physics_frame
		for retry_entry in retry_entries:
			var actor_id := String(retry_entry.get("actorId", ""))
			var body := retry_entry.get("body") as CharacterBody3D
			var target: Vector3 = retry_entry.get("target", Vector3.INF)
			if body == null or not is_instance_valid(body) or not target.is_finite():
				continue
			var attempts: Array = retry_entry.get("attempts", []) if retry_entry.get("attempts", []) is Array else []
			var lateral_sign := signf((target - left_endpoint).dot(crossing_side))
			var inward := -crossing_side * lateral_sign if not is_zero_approx(lateral_sign) else Vector3.ZERO
			var placement: Dictionary = {}
			for inward_distance in [0.0, 0.1, 0.2]:
				var candidate := target + inward * float(inward_distance)
				placement = npc_system.call("safe_place_npc", body, candidate, null, "citadel_crowd_pre_act_lineup") as Dictionary
				placement["inwardOffset"] = float(inward_distance)
				attempts.append(placement.duplicate(true))
				if bool(placement.get("ok", false)):
					targets[actor_id] = candidate
					break
			placement["attempts"] = attempts
			placements[actor_id] = placement.duplicate(true)
			if not bool(placement.get("ok", false)):
				continue
			body.velocity = Vector3.ZERO
			body.set_meta("npc_requested_velocity", Vector3.ZERO)
			body.set_meta("npc_applied_velocity", Vector3.ZERO)
			placed_count += 1
			await get_tree().physics_frame
	return {
		"ok": placed_count == citizens.size(),
		"placedCount": placed_count,
		"expectedCount": citizens.size(),
		"authority": "NpcSystem fixture placement",
		"phase": "pre_act_fixture_setup",
		"placements": placements
	}


func crowd_crossing_endpoints() -> Dictionary:
	var anchors := civic_street_anchors()
	if anchors.size() < 2:
		var recipe: Dictionary = blueprint.recipe if blueprint != null else {}
		var grammar: Dictionary = recipe.get("castleGrammar", {}) as Dictionary
		var depth := float(recipe.get("depth", 64.0))
		var gate_depth := float(grammar.get("gateDepth", 9.0))
		var keep_depth := float(grammar.get("keepDepth", depth * 0.24))
		var keep_offset: Dictionary = grammar.get("keepOffset", {}) as Dictionary
		var keep_z := depth * float(keep_offset.get("z", 0.14))
		var route_start := -depth * 0.5 + gate_depth + CELL * 2.0
		var route_end := keep_z - keep_depth * 0.5 - CELL * 2.0
		anchors = [
			fixture_origin + Vector3(0.0, 0.0, lerpf(route_start, route_end, 0.28)),
			fixture_origin + Vector3(0.0, 0.0, lerpf(route_start, route_end, 0.72))
		]
	var best_left := anchors[0]
	var best_right := anchors[1]
	var best_score := INF
	for left_index in range(anchors.size()):
		for right_index in range(left_index + 1, anchors.size()):
			var distance := Vector2(anchors[left_index].x - anchors[right_index].x, anchors[left_index].z - anchors[right_index].z).length()
			if distance < 12.0 or distance > 26.0:
				continue
			var score := absf(distance - 18.0)
			if score < best_score:
				best_score = score
				best_left = anchors[left_index]
				best_right = anchors[right_index]
	return {"left": best_left, "right": best_right, "distance": Vector2(best_left.x - best_right.x, best_left.z - best_right.z).length()}


func replace_civic_order_queue(staged: Array[Dictionary], phase: String) -> void:
	# The fixture owns only *when* generic public orders are submitted.  It never
	# touches route state, movement, doors, traffic, or navigation internals.  A
	# replacement phase makes every not-yet-submitted request explicitly
	# superseded instead of losing it inside a same-frame route burst.
	civic_order_generation += 1
	civic_order_metrics["superseded"] = int(civic_order_metrics.get("superseded", 0)) + civic_order_queue.size()
	civic_order_queue.clear()
	var queued_usec := Time.get_ticks_usec()
	civic_order_batches.append({
		"generation": civic_order_generation,
		"phase": phase,
		"expectedCount": staged.size(),
		"queuedUsec": queued_usec,
		"queuedProcessFrame": Engine.get_process_frames(),
		"queuedPhysicsFrame": Engine.get_physics_frames(),
		"submittedCount": 0,
		"discardedCount": 0,
		"submissions": [],
		"drainedUsec": 0,
		"drainedProcessFrame": -1,
		"drainedPhysicsFrame": -1
	})
	while civic_order_batches.size() > 8:
		civic_order_batches.pop_front()
	for request in staged:
		var entry := request.duplicate(true)
		entry["generation"] = civic_order_generation
		entry["phase"] = phase
		civic_order_queue.append(entry)
	civic_order_metrics["queued"] = civic_order_queue.size()


func drain_civic_order_queue() -> void:
	if npc_system == null or civic_order_queue.is_empty():
		return
	var submitted := 0
	while submitted < CIVIC_ORDERS_PER_FRAME and not civic_order_queue.is_empty():
		var request: Dictionary = civic_order_queue.pop_front() as Dictionary
		var body := request.get("body") as CharacterBody3D
		var batch_index := civic_order_batch_index(int(request.get("generation", -1)))
		if body == null or not is_instance_valid(body):
			civic_order_metrics["discarded"] = int(civic_order_metrics.get("discarded", 0)) + 1
			record_civic_order_submission(batch_index, request, {}, false, "missing_body")
			continue
		var result: Dictionary = {}
		if String(request.get("kind", "")) == "go_home":
			result = npc_system.call("order_go_home", body, String(request.get("reason", "citadel_life_world_clock_return"))) as Dictionary
		elif String(request.get("kind", "")) == "wait":
			result = npc_system.call("order_wait", body, String(request.get("reason", "citadel_life_fixture_wait"))) as Dictionary
		else:
			result = npc_system.call(
				"order_go_to",
				body,
				request.get("target", body.global_position) as Vector3,
				String(request.get("reason", "citadel_life_civic_day")),
				float(request.get("arrivalRadius", CELL * 1.10))
			) as Dictionary
		var accepted := String(result.get("state", "")) != "FAILED_TARGET_GONE"
		record_civic_order_submission(batch_index, request, result, accepted)
		if not accepted:
			civic_order_metrics["discarded"] = int(civic_order_metrics.get("discarded", 0)) + 1
			continue
		submitted += 1
		civic_order_metrics["submitted"] = int(civic_order_metrics.get("submitted", 0)) + 1
	civic_order_metrics["queued"] = civic_order_queue.size()
	if civic_order_queue.is_empty():
		mark_civic_order_batch_drained(civic_order_generation)


func civic_order_batch_index(generation: int) -> int:
	for index in range(civic_order_batches.size() - 1, -1, -1):
		var batch: Dictionary = civic_order_batches[index] as Dictionary
		if int(batch.get("generation", -1)) == generation:
			return index
	return -1


func record_civic_order_submission(batch_index: int, request: Dictionary, result: Dictionary, accepted: bool, failure_reason := "") -> void:
	if batch_index < 0 or batch_index >= civic_order_batches.size():
		return
	var batch: Dictionary = civic_order_batches[batch_index] as Dictionary
	var body := request.get("body") as CharacterBody3D
	var entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary if npc_system != null and body != null and is_instance_valid(body) else {}
	var now_usec := Time.get_ticks_usec()
	var submissions: Array = batch.get("submissions", []) as Array
	submissions.append({
		"actorId": String(entry.get("id", body.name if body != null and is_instance_valid(body) else "")),
		"kind": String(request.get("kind", "")),
		"accepted": accepted,
		"state": String(result.get("state", "")),
		"reason": String(result.get("reason", failure_reason)),
		"failureReason": String(result.get("failureReason", failure_reason)),
		"submittedUsec": now_usec,
		"submittedElapsedMs": float(now_usec - int(batch.get("queuedUsec", now_usec))) / 1000.0,
		"submittedProcessFrame": Engine.get_process_frames(),
		"submittedPhysicsFrame": Engine.get_physics_frames(),
		"baselineRouteServiceAdvancedTicks": int(entry.get("routePhysicsServiceAdvancedTicks", 0)),
		"baselineRouteServiceMovedTicks": int(entry.get("routePhysicsServiceMovedTicks", 0)),
		"baselineRouteServiceMovedDistance": float(entry.get("routePhysicsServiceMovedDistance", 0.0)),
		"firstAdvancedPhysicsFrame": -1,
		"firstMovedPhysicsFrame": -1
	})
	batch["submissions"] = submissions
	if accepted:
		batch["submittedCount"] = int(batch.get("submittedCount", 0)) + 1
	else:
		batch["discardedCount"] = int(batch.get("discardedCount", 0)) + 1
	civic_order_batches[batch_index] = batch


func mark_civic_order_batch_drained(generation: int) -> void:
	var batch_index := civic_order_batch_index(generation)
	if batch_index < 0:
		return
	var batch: Dictionary = civic_order_batches[batch_index] as Dictionary
	if int(batch.get("drainedUsec", 0)) > 0:
		return
	batch["drainedUsec"] = Time.get_ticks_usec()
	batch["drainedProcessFrame"] = Engine.get_process_frames()
	batch["drainedPhysicsFrame"] = Engine.get_physics_frames()
	civic_order_batches[batch_index] = batch


func update_civic_order_batch_motion_evidence() -> void:
	if npc_system == null:
		return
	for batch_index in range(civic_order_batches.size()):
		var batch: Dictionary = civic_order_batches[batch_index] as Dictionary
		var submissions: Array = batch.get("submissions", []) as Array
		var changed := false
		for submission_index in range(submissions.size()):
			var submission: Dictionary = submissions[submission_index] as Dictionary
			if not bool(submission.get("accepted", false)):
				continue
			var actor_id := String(submission.get("actorId", ""))
			var body := citizen_body_for_id(actor_id)
			if body == null:
				continue
			var entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
			if int(submission.get("firstAdvancedPhysicsFrame", -1)) < 0 \
					and int(entry.get("routePhysicsServiceAdvancedTicks", 0)) > int(submission.get("baselineRouteServiceAdvancedTicks", 0)):
				submission["firstAdvancedPhysicsFrame"] = int(entry.get("routePhysicsServiceLastFrame", Engine.get_physics_frames()))
				changed = true
			if int(submission.get("firstMovedPhysicsFrame", -1)) < 0 \
					and int(entry.get("routePhysicsServiceMovedTicks", 0)) > int(submission.get("baselineRouteServiceMovedTicks", 0)):
				submission["firstMovedPhysicsFrame"] = int(entry.get("routePhysicsServiceLastFrame", Engine.get_physics_frames()))
				changed = true
			submissions[submission_index] = submission
		if changed:
			batch["submissions"] = submissions
			civic_order_batches[batch_index] = batch


func civic_order_batch_snapshot(generation: int) -> Dictionary:
	var batch_index := civic_order_batch_index(generation)
	if batch_index < 0:
		return {"generation": generation, "ready": false, "reason": "missing_batch"}
	var batch: Dictionary = civic_order_batches[batch_index] as Dictionary
	var expected_count := int(batch.get("expectedCount", 0))
	var submitted_count := int(batch.get("submittedCount", 0))
	var discarded_count := int(batch.get("discardedCount", 0))
	var drained_usec := int(batch.get("drainedUsec", 0))
	var queued_usec := int(batch.get("queuedUsec", 0))
	var drained := drained_usec > 0 and submitted_count + discarded_count >= expected_count
	var elapsed_ms := float((drained_usec if drained else Time.get_ticks_usec()) - queued_usec) / 1000.0 if queued_usec > 0 else INF
	var process_frames := int((int(batch.get("drainedProcessFrame", Engine.get_process_frames())) if drained else Engine.get_process_frames()) - int(batch.get("queuedProcessFrame", Engine.get_process_frames())))
	var all_accepted := drained and submitted_count == expected_count and discarded_count == 0
	return {
		"generation": generation,
		"phase": String(batch.get("phase", "")),
		"expectedCount": expected_count,
		"submittedCount": submitted_count,
		"discardedCount": discarded_count,
		"drained": drained,
		"allAccepted": all_accepted,
		"elapsedMs": elapsed_ms,
		"processFrames": process_frames,
		"queuedProcessFrame": int(batch.get("queuedProcessFrame", -1)),
		"queuedPhysicsFrame": int(batch.get("queuedPhysicsFrame", -1)),
		"drainedProcessFrame": int(batch.get("drainedProcessFrame", -1)),
		"drainedPhysicsFrame": int(batch.get("drainedPhysicsFrame", -1)),
		"submissions": (batch.get("submissions", []) as Array).duplicate(true)
	}


func await_civic_order_batch_admission(phase: String, generation: int) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - started_usec) / 1000.0 < ACCEPTANCE_ORDER_ADMISSION_TIMEOUT_MS:
		var snapshot := civic_order_batch_snapshot(generation)
		if bool(snapshot.get("drained", false)):
			snapshot["timely"] = bool(snapshot.get("allAccepted", false)) \
				and float(snapshot.get("elapsedMs", INF)) <= ACCEPTANCE_ORDER_ADMISSION_MAX_MS \
				and int(snapshot.get("processFrames", ACCEPTANCE_ORDER_ADMISSION_MAX_PROCESS_FRAMES + 1)) <= ACCEPTANCE_ORDER_ADMISSION_MAX_PROCESS_FRAMES
			snapshot["reason"] = "" if bool(snapshot.get("timely", false)) else "order_admission_slow_or_rejected"
			return snapshot
		await get_tree().process_frame
	var timed_out := civic_order_batch_snapshot(generation)
	timed_out["phase"] = phase
	timed_out["timely"] = false
	timed_out["reason"] = "order_admission_timeout"
	return timed_out


func set_world_display_hour(hour: float) -> void:
	if main == null:
		return
	# Main's real clock remains authoritative. This fixture only clears the
	# tutorial's introductory night hold so a requested day/night presentation is
	# not overwritten on the next production frame.
	ensure_fixture_clock_is_unlocked()
	main.set("time_of_day", fposmod((hour / 24.0) - 0.25, 1.0))
	if main.has_method("update_sky"):
		main.call("update_sky", 0.0)


func ensure_fixture_clock_is_unlocked() -> void:
	if main == null:
		return
	var tutorial = main.get("tutorial_system")
	if tutorial == null:
		return
	tutorial.set("intro_bed_used", true)
	tutorial.set("intro_repair_active", false)
	tutorial.set("intro_repair_complete", true)
	tutorial.set("final_night_active", false)
	tutorial.set("final_night_complete", true)


func world_phase() -> String:
	# Keep the fixture's scenario composition aligned with the production
	# schedule service: daytime civic orders may exist only during the ordinary
	# day window. Dusk, night and dawn all let the existing home schedule win.
	if main != null and main.has_method("clock_phase"):
		var phase := float(main.call("clock_phase"))
		return "day" if phase >= 7.0 / 24.0 and phase < 18.25 / 24.0 else "night"
	return "day"


func refresh_world_phase(force := false) -> void:
	if rebuilding or main == null or citizens.is_empty():
		return
	var next_phase := world_phase()
	if not force and next_phase == observed_world_phase:
		return
	observed_world_phase = next_phase
	if observed_world_phase == "day" and not crowd_stress_active:
		begin_civic_day()
	else:
		begin_civic_night()


func civic_anchor_for(index: int, round_index: int) -> Vector3:
	var anchors := civic_street_anchors()
	if anchors.is_empty():
		var recipe: Dictionary = blueprint.recipe if blueprint != null else {}
		var grammar: Dictionary = recipe.get("castleGrammar", {}) as Dictionary
		var width := float(recipe.get("width", 72.0))
		var depth := float(recipe.get("depth", 64.0))
		var gate_depth := float(grammar.get("gateDepth", 9.0))
		var keep_depth := float(grammar.get("keepDepth", depth * 0.24))
		var keep_offset: Dictionary = grammar.get("keepOffset", {}) as Dictionary
		var keep_z := depth * float(keep_offset.get("z", 0.14))
		var route_start := -depth * 0.5 + gate_depth + CELL * 1.5
		var route_end := keep_z - keep_depth * 0.5 - CELL * 1.5
		for fraction in [0.16, 0.36, 0.56, 0.76]:
			anchors.append(fixture_origin + Vector3(0.0, 0.0, lerpf(route_start, route_end, fraction)))
	var pick := posmod(index * 3 + round_index * 5 + selected_seed, anchors.size())
	return anchors[pick]


func civic_street_anchors() -> Array[Vector3]:
	var anchors: Array[Vector3] = []
	if blueprint == null:
		return anchors
	var recipe: Dictionary = blueprint.recipe
	var grammar: Dictionary = recipe.get("castleGrammar", {}) as Dictionary
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	var records: Array = (grid.get("streetRecords", []) as Array).duplicate()
	records.sort_custom(func(left, right) -> bool:
		var left_id := String((left as Dictionary).get("id", "")) if left is Dictionary else ""
		var right_id := String((right as Dictionary).get("id", "")) if right is Dictionary else ""
		return left_id < right_id
	)
	for value in records:
		if not (value is Dictionary):
			continue
		var record: Dictionary = value as Dictionary
		var width := float(record.get("width", 0.0))
		var depth := float(record.get("depth", 0.0))
		if width < CELL * 1.5 or depth < CELL * 1.5:
			continue
		var center := fixture_origin + Vector3(float(record.get("x", 0.0)), 0.0, float(record.get("z", 0.0)))
		var offset_span := maxf(0.0, maxf(width, depth) * 0.24 - CELL * 0.75)
		for offset in [0.0, -offset_span, offset_span]:
			var candidate := center
			if width >= depth:
				candidate.x += offset
			else:
				candidate.z += offset
			anchors.append(candidate)
	return anchors


func civic_walk_level() -> float:
	# The same castle part records publish both the visible paving and its physical
	# support. Resolve the highest shared courtyard/street surface once, so every
	# daytime order uses a real ground elevation rather than a home-storey level.
	var level := fixture_level
	if blueprint == null:
		return level
	for part in blueprint.parts:
		if part == null:
			continue
		var semantic := String(part.semantic)
		if semantic not in ["castle_courtyard_paving", "castle_courtyard_street"]:
			continue
		level = maxf(level, fixture_origin.y + part.position.y + part.size.y * 0.5)
	return level


func place_player_at_gate(recipe: Dictionary) -> void:
	if player == null:
		return
	var depth := float(recipe.get("depth", 72.0))
	var gate_depth := float((recipe.get("castleGrammar", {}) as Dictionary).get("gateDepth", 10.0))
	# PlayerController's capsule feet sit at its root origin. Use the same
	# collision-safe surface placement as the established walkthrough fixtures;
	# spawning a metre in the air can make terrain motion proof reject input
	# before gravity gets a valid landing frame.
	player.global_position = fixture_origin + Vector3(0.0, 0.15, -depth * 0.5 - gate_depth * 0.82 - 3.0)
	player.velocity = Vector3.ZERO
	player.rotation.y = PI
	var camera_pitch := player.get("camera_pitch") as Node3D
	if camera_pitch != null:
		camera_pitch.rotation.x = 0.0


func move_player_for_streaming(_span: float) -> void:
	if player == null:
		return
	player.global_position = fixture_origin + fixture_streaming_focus_offset()
	player.velocity = Vector3.ZERO


func fixture_streaming_focus_offset() -> Vector3:
	return Vector3(0.0, 0.15, 0.0)


func select_fixture_site(span: float) -> Dictionary:
	# A citadel is sited from the same terrain volume queried by normal play.  The
	# old fixture wrote a parallel grid of legacy surface markers and forced a
	# world-sized refresh.  Sampling candidates makes the terrain authority the
	# source of truth and leaves no transient terrain mode behind the castle.
	var candidates: Array[Vector2i] = [
		Vector2i(240, -220), Vector2i(-240, 220), Vector2i(300, 180), Vector2i(-300, -180),
		Vector2i(420, -320), Vector2i(-420, 320), Vector2i(360, 380), Vector2i(-360, -380)
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(("%d|citadel.life.terrain.site" % selected_seed).hash())
	for index in range(32):
		var angle := rng.randf_range(-PI, PI)
		var distance := rng.randf_range(620.0, 2600.0)
		candidates.append(Vector2i(roundi(cos(angle) * distance), roundi(sin(angle) * distance)))
	var radius := ceili(span / CELL * 0.50) + 6
	var coarse_profiles: Array[Dictionary] = []
	for candidate in candidates:
		var coarse: Dictionary = terrain_site_profile(candidate, radius, 3)
		if float(coarse.get("minimumSurfaceY", -INF)) > WATER_LEVEL + 2.5:
			coarse_profiles.append(coarse)
	coarse_profiles.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return fixture_site_score(left) < fixture_site_score(right)
	)
	var best: Dictionary = {}
	for index in range(mini(6, coarse_profiles.size())):
		var coarse: Dictionary = coarse_profiles[index]
		var profile: Dictionary = terrain_site_profile(coarse.get("center", Vector2i.ZERO) as Vector2i, radius, TERRAIN_SITE_SAMPLE_GRID)
		if best.is_empty() or fixture_site_score(profile) < fixture_site_score(best):
			best = profile
	if best.is_empty():
		best = terrain_site_profile(candidates[0], radius, TERRAIN_SITE_SAMPLE_GRID)
	var maximum_surface := float(best.get("maximumSurfaceY", WATER_LEVEL + 3.0))
	# The reservation is always snapped upward to preserve natural material below
	# it; the terrain generator then produces the actual flat foundation volume.
	best["level"] = maxf(float(ceili(maximum_surface / CELL)) * CELL, WATER_LEVEL + CELL * 3.0)
	best["radius"] = radius
	best["candidateCount"] = candidates.size()
	best["coarseCandidateCount"] = coarse_profiles.size()
	best["naturalSurfaceCompatible"] = float(best.get("surfaceVariance", INF)) <= CELL * 1.15
	best["foundationMode"] = "pending_terrain_generation_reservation"
	return best


func reserve_fixture_terrain_site() -> Dictionary:
	if main == null or not main.has_method("register_settlement_site"):
		return {"ready": false, "reason": "settlement_site_registration_missing"}
	var site_id := "citadel-life:%d:%.2f" % [selected_seed, selected_citadel_scale]
	var registration: Dictionary = main.call("register_settlement_site", {
		"id": site_id,
		"center": fixture_center,
		"radius": int(fixture_site.get("radius", 1)),
		"level": fixture_level,
		"kind": "citadel",
		"source": "citadel_life_fixture"
	})
	if not bool(registration.get("accepted", false)):
		return {"ready": false, "reason": "settlement_site_rejected", "registration": registration}
	var runtime = main.get("voxel_terrain_runtime")
	if runtime == null or not runtime.has_method("refresh_generation_for_world_authority"):
		return {"ready": false, "reason": "terrain_authority_refresh_missing", "registration": registration}
	set_loading("Publishing reserved site geometry into the terrain volume")
	var refresh: Dictionary = await runtime.call("refresh_generation_for_world_authority", "citadel_life_settlement_site")
	if not bool(refresh.get("ok", false)):
		return {"ready": false, "reason": "terrain_authority_refresh_failed", "registration": registration, "refresh": refresh}
	return {
		"ready": true,
		"registration": registration,
		"refresh": refresh,
		"siteId": site_id
	}


func reserved_site_surface_contract() -> Dictionary:
	var radius := maxi(1, int(fixture_site.get("radius", 1)) - 2)
	var step := maxi(1, ceili(float(radius) / float(TERRAIN_SITE_SAMPLE_GRID)))
	var minimum_surface := INF
	var maximum_surface := -INF
	var sample_count := 0
	for z in range(fixture_center.y - radius, fixture_center.y + radius + 1, step):
		for x in range(fixture_center.x - radius, fixture_center.x + radius + 1, step):
			if Vector2(float(x - fixture_center.x), float(z - fixture_center.y)).length() > float(radius):
				continue
			var surface := authoritative_surface_y(Vector2i(x, z))
			minimum_surface = minf(minimum_surface, surface)
			maximum_surface = maxf(maximum_surface, surface)
			sample_count += 1
	var variance := maximum_surface - minimum_surface
	var expected_delta := maxf(absf(maximum_surface - fixture_level), absf(minimum_surface - fixture_level))
	return {
		"ready": sample_count > 0 and variance <= CELL * 0.25 and expected_delta <= CELL * 0.25,
		"authority": "terrain_volume",
		"expectedFoundationY": fixture_level,
		"minimumSurfaceY": minimum_surface,
		"maximumSurfaceY": maximum_surface,
		"surfaceVariance": variance,
		"expectedDelta": expected_delta,
		"sampleCount": sample_count
	}


func terrain_site_profile(center: Vector2i, radius: int, grid_density: int) -> Dictionary:
	var minimum_surface := INF
	var maximum_surface := -INF
	var sample_count := 0
	var step := maxi(1, ceili(float(radius) / float(maxi(1, grid_density))))
	for z in range(center.y - radius, center.y + radius + 1, step):
		for x in range(center.x - radius, center.x + radius + 1, step):
			var surface := authoritative_surface_y(Vector2i(x, z))
			minimum_surface = minf(minimum_surface, surface)
			maximum_surface = maxf(maximum_surface, surface)
			sample_count += 1
	return {
		"center": center,
		"minimumSurfaceY": minimum_surface,
		"maximumSurfaceY": maximum_surface,
		"surfaceVariance": maximum_surface - minimum_surface,
		"sampleCount": sample_count,
		"sampleStepCells": step,
		"authority": "terrain_volume"
	}


func authoritative_surface_y(cell: Vector2i) -> float:
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation != null and world_generation.has_method("surface_y_for_cell"):
		return float(world_generation.call("surface_y_for_cell", Vector3i(cell.x, 0, cell.y)))
	return float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y)))


func fixture_site_score(profile: Dictionary) -> float:
	# A bounded dry, low-variance site is better than a closer or specially
	# authored location.  The candidate order remains a deterministic tiebreak.
	return float(profile.get("surfaceVariance", INF)) * 10.0 - float(profile.get("minimumSurfaceY", -INF)) * 0.02


func wait_for_fixture_terrain_readiness(span: float) -> Dictionary:
	var runtime = main.get("voxel_terrain_runtime") if main != null else null
	if runtime == null or not runtime.has_method("gameplay_chunks_published"):
		return {"ready": false, "reason": "terrain_runtime_missing", "waitedFrames": 0}
	var required := fixture_terrain_chunk_keys(span)
	var max_frames := terrain_site_readiness_max_frames()
	if runtime.has_method("configure_startup_collision_bounds"):
		# Reuse the terrain authority's ordinary startup-viewer contract so the
		# selected site receives visual and collision publication together.
		runtime.call("configure_startup_collision_bounds", required)
	for frame in range(max_frames):
		if bool(runtime.call("gameplay_chunks_published", required)):
			return {"ready": true, "waitedFrames": frame, "requiredChunkCount": required.size()}
		if main.has_method("update_chunks"):
			main.call("update_chunks", false)
		if frame % 45 == 0:
			set_loading("Publishing real terrain and collision (%d/%d chunks)" % [int(runtime.call("published_gameplay_chunk_count", required)), required.size()])
		await get_tree().physics_frame
	var publication_diagnostics: Dictionary = runtime.call("gameplay_publication_diagnostics", required) if runtime.has_method("gameplay_publication_diagnostics") else {}
	return {
		"ready": false,
		"reason": "terrain_publication_timeout",
		"waitedFrames": max_frames,
		"requiredChunkCount": required.size(),
		"publishedChunkCount": int(runtime.call("published_gameplay_chunk_count", required)),
		"publicationDiagnostics": publication_diagnostics
	}


func terrain_site_readiness_max_frames() -> int:
	var requested := int(OS.get_environment("VOXEL_CITADEL_TERRAIN_READY_MAX_FRAMES"))
	if requested <= 0:
		return DEFAULT_TERRAIN_SITE_READINESS_MAX_FRAMES
	return clampi(requested, 60, MAX_TERRAIN_SITE_READINESS_MAX_FRAMES)


func fixture_terrain_chunk_keys(span: float) -> Array[Vector2i]:
	var center_chunk := Vector2i(floori(float(fixture_center.x) / float(TERRAIN_CHUNK_SIZE)), floori(float(fixture_center.y) / float(TERRAIN_CHUNK_SIZE)))
	var radius := maxi(1, ceili((span / CELL * 0.5 + 4.0) / float(TERRAIN_CHUNK_SIZE)))
	var keys: Array[Vector2i] = []
	for z in range(center_chunk.y - radius, center_chunk.y + radius + 1):
		for x in range(center_chunk.x - radius, center_chunk.x + radius + 1):
			keys.append(Vector2i(x, z))
	return keys


func configure_fixture_streaming_window(span: float) -> Dictionary:
	var required := fixture_terrain_chunk_keys(span)
	var center_chunk := Vector2i(floori(float(fixture_center.x) / float(TERRAIN_CHUNK_SIZE)), floori(float(fixture_center.y) / float(TERRAIN_CHUNK_SIZE)))
	var required_radius := 0
	for chunk_key in required:
		required_radius = maxi(required_radius, maxi(absi(chunk_key.x - center_chunk.x), absi(chunk_key.y - center_chunk.y)))
	var previous_radius := int(main.get("render_distance")) if main != null else 0
	var configured_radius := maxi(previous_radius, required_radius)
	if main != null:
		main.set("render_distance", configured_radius)
	return {
		"centerChunk": center_chunk,
		"previousRenderDistance": previous_radius,
		"renderDistance": configured_radius,
		"requiredChunkCount": required.size(),
		"requiredRadius": required_radius
	}


func clear_blocks_near_cell(center: Vector2i, radius: int) -> void:
	var blocks: Dictionary = main.get("blocks")
	for key in blocks.keys():
		var cell: Vector3i = key
		if abs(cell.x - center.x) > radius or abs(cell.z - center.y) > radius:
			continue
		var body := blocks[key] as Node
		if body != null:
			body.queue_free()
		blocks.erase(key)


func clear_props_near_cell(center: Vector2i, radius: int) -> void:
	for root_value in [main.get("chunk_root"), main.get("prop_root")]:
		clear_props_recursive(root_value as Node, center, radius)


func clear_props_recursive(node: Node, center: Vector2i, radius: int) -> void:
	if node == null:
		return
	for child in node.get_children():
		if child is Node3D and String(child.get_meta("kind", "")) == "prop":
			var prop := child as Node3D
			var cell := flat_cell(prop.global_position)
			if abs(cell.x - center.x) <= radius and abs(cell.y - center.y) <= radius:
				child.queue_free()
				continue
		clear_props_recursive(child, center, radius)


func loading_frame_budget(record_count: int) -> int:
	return clampi(ceili(float(maxi(record_count, 1)) / 540.0), 5, 36)


func wait_physics_frames(count: int) -> void:
	for _frame in range(count):
		await get_tree().physics_frame


func flat_cell(position: Vector3) -> Vector2i:
	return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))


func _process(delta: float) -> void:
	if loading_overlay != null and loading_overlay.visible:
		loading_elapsed += delta
		update_loading_label()
	if rebuilding:
		return
	district_prefetch_elapsed += delta
	if district_prefetch_elapsed >= DISTRICT_PREFETCH_INTERVAL:
		district_prefetch_elapsed = 0.0
		request_relevant_district_publication()
	if player != null and not player.is_physics_processing():
		# Main's normal staged boot can finish on a later frame than this fixture's
		# first presentation pass. Keep the real player interactive once fixture
		# publication has completed instead of leaving a visible but inert avatar.
		enable_interactive_player()
	process_citizen_materialization_queue()
	if main == null or citizens.is_empty():
		return
	refresh_world_phase()
	if observed_world_phase == "day" and not crowd_stress_active:
		civic_order_elapsed += delta
		if civic_order_elapsed >= 14.0:
			civic_order_elapsed = 0.0
			issue_civic_orders()
	drain_civic_order_queue()
	update_civic_order_batch_motion_evidence()
	update_biped_presenters(delta)
	status_elapsed += delta
	if status_elapsed >= 0.25:
		status_elapsed = 0.0
		update_status()


func _physics_process(delta: float) -> void:
	if not acceptance_mode or rebuilding or citizens.size() < 2:
		return
	observe_crowd_physics_frame(delta)


func reset_crowd_physics_evidence() -> void:
	crowd_physics_evidence = {
		"sampleCount": 0,
		"minimumSeparation": INF,
		"minimumFrame": -1,
		"minimumPair": {},
		"firstBelowAvoidancePair": {},
		"overlapFrameCount": 0,
		"belowAvoidanceFrameCount": 0,
		"currentBelowAvoidanceFrames": 0,
		"maxBelowAvoidanceFrames": 0,
		"maxBelowAvoidanceSeconds": 0.0,
		"separationTimeline": [],
		"commandedStationaryFramesByActor": {},
		"maxCommandedStationaryFramesByActor": {},
		"stableSemanticArrivalFramesByActor": {},
		"maxStableSemanticArrivalFramesByActor": {}
	}
	crowd_capture_pending = false
	crowd_capture_count = 0
	crowd_first_encounter_capture_requested = false
	crowd_reverse_capture_requested = false
	crowd_recovery_capture_requested = false
	crowd_recovery_baseline_by_actor_id.clear()
	for citizen_entry in citizens:
		var body := valid_citizen_body(citizen_entry)
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		if body == null:
			continue
		var actor_id := String(manifest.get("id", body.name))
		var npc_entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
		crowd_recovery_baseline_by_actor_id[actor_id] = int(npc_entry.get("crowdAvoidanceRecoveryCount", 0))


func observe_crowd_physics_frame(delta: float) -> void:
	var closest := closest_crowd_pair_record()
	if closest.is_empty():
		return
	var separation := float(closest.get("separation", INF))
	var required := float(closest.get("required", 0.68))
	var avoidance_required := float(closest.get("avoidanceRequired", required + NpcConstantsScript.AVOIDANCE_RADIUS_SAFETY_MARGIN * 2.0))
	crowd_physics_evidence["sampleCount"] = int(crowd_physics_evidence.get("sampleCount", 0)) + 1
	if separation + 0.015 < required:
		crowd_physics_evidence["overlapFrameCount"] = int(crowd_physics_evidence.get("overlapFrameCount", 0)) + 1
	if separation < avoidance_required:
		if (crowd_physics_evidence.get("firstBelowAvoidancePair", {}) as Dictionary).is_empty():
			crowd_physics_evidence["firstBelowAvoidancePair"] = closest.duplicate(true)
		var streak := int(crowd_physics_evidence.get("currentBelowAvoidanceFrames", 0)) + 1
		crowd_physics_evidence["belowAvoidanceFrameCount"] = int(crowd_physics_evidence.get("belowAvoidanceFrameCount", 0)) + 1
		crowd_physics_evidence["currentBelowAvoidanceFrames"] = streak
		crowd_physics_evidence["maxBelowAvoidanceFrames"] = maxi(int(crowd_physics_evidence.get("maxBelowAvoidanceFrames", 0)), streak)
		crowd_physics_evidence["maxBelowAvoidanceSeconds"] = maxf(float(crowd_physics_evidence.get("maxBelowAvoidanceSeconds", 0.0)), float(streak) * delta)
	else:
		crowd_physics_evidence["currentBelowAvoidanceFrames"] = 0
	if Engine.get_physics_frames() % 6 == 0 and (separation < 1.5 or int(crowd_physics_evidence.get("currentBelowAvoidanceFrames", 0)) > 0):
		var separation_timeline: Array = crowd_physics_evidence.get("separationTimeline", []) as Array
		separation_timeline.append({
			"physicsFrame": Engine.get_physics_frames(),
			"left": String(closest.get("left", "")),
			"right": String(closest.get("right", "")),
			"separation": separation,
			"leftVelocity": closest.get("leftVelocity", Vector3.ZERO),
			"rightVelocity": closest.get("rightVelocity", Vector3.ZERO)
		})
		while separation_timeline.size() > 240:
			separation_timeline.pop_front()
		crowd_physics_evidence["separationTimeline"] = separation_timeline
	observe_commanded_stationary_frames()
	observe_stable_semantic_arrivals()
	request_crossing_diagnostic_captures()
	if separation < float(crowd_physics_evidence.get("minimumSeparation", INF)):
		crowd_physics_evidence["minimumSeparation"] = separation
		crowd_physics_evidence["minimumFrame"] = Engine.get_physics_frames()
		crowd_physics_evidence["minimumPair"] = closest.duplicate(true)
		if separation < 1.0 and crowd_capture_count < 3 and not crowd_capture_pending:
			crowd_capture_pending = true
			call_deferred("capture_crowd_minimum_pair", closest.duplicate(true), crowd_capture_count + 1)


func request_crossing_diagnostic_captures() -> void:
	for citizen_entry in citizens:
		var body := valid_citizen_body(citizen_entry)
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		if body == null:
			continue
		var actor_id := String(manifest.get("id", body.name))
		var npc_entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
		var avoidance: Dictionary = npc_entry.get("routeLeaseAvoidance", {}) if npc_entry.get("routeLeaseAvoidance", {}) is Dictionary else {}
		var reverse_yield: Dictionary = avoidance.get("reverseYield", {}) if avoidance.get("reverseYield", {}) is Dictionary else {}
		var encounter_actor_id := String(reverse_yield.get("encounterActorId", ""))
		if actor_id == "" or encounter_actor_id == "":
			continue
		if not crowd_first_encounter_capture_requested:
			crowd_first_encounter_capture_requested = true
			call_deferred("capture_crowd_crossing_event", "crowd_first_encounter", actor_id, encounter_actor_id)
		if not crowd_reverse_capture_requested and int(reverse_yield.get("consecutiveReverseFrames", 0)) >= 6:
			crowd_reverse_capture_requested = true
			call_deferred("capture_crowd_crossing_event", "crowd_first_sustained_reversal", actor_id, encounter_actor_id)
		var recovery_baseline := int(crowd_recovery_baseline_by_actor_id.get(actor_id, 0))
		if not crowd_recovery_capture_requested and int(reverse_yield.get("recoveryCount", 0)) > recovery_baseline:
			crowd_recovery_capture_requested = true
			call_deferred("capture_crowd_crossing_event", "crowd_first_recovery", actor_id, encounter_actor_id)


func capture_crowd_crossing_event(capture_id: String, actor_id: String, encounter_actor_id: String) -> void:
	await capture_crowd_encounter_view(capture_id, actor_id, encounter_actor_id)


func observe_stable_semantic_arrivals() -> void:
	var current: Dictionary = crowd_physics_evidence.get("stableSemanticArrivalFramesByActor", {}) as Dictionary
	var maximum: Dictionary = crowd_physics_evidence.get("maxStableSemanticArrivalFramesByActor", {}) as Dictionary
	for citizen_entry in citizens:
		var body := valid_citizen_body(citizen_entry)
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		var actor_id := String(manifest.get("id", body.name if body != null else ""))
		if body == null or not (crowd_crossing_targets_by_actor_id.get(actor_id) is Vector3):
			continue
		var target: Vector3 = crowd_crossing_targets_by_actor_id.get(actor_id)
		var distance := Vector2(body.global_position.x - target.x, body.global_position.z - target.z).length()
		var npc_entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
		var scripted_order: Dictionary = npc_entry.get("scriptedOrder", {}) if npc_entry.get("scriptedOrder", {}) is Dictionary else {}
		var stable := distance <= CROWD_FORMATION_ARRIVAL_RADIUS and String(scripted_order.get("state", "")) == "ARRIVED"
		var frames := int(current.get(actor_id, 0)) + 1 if stable else 0
		current[actor_id] = frames
		maximum[actor_id] = maxi(int(maximum.get(actor_id, 0)), frames)
	crowd_physics_evidence["stableSemanticArrivalFramesByActor"] = current
	crowd_physics_evidence["maxStableSemanticArrivalFramesByActor"] = maximum


func observe_commanded_stationary_frames() -> void:
	var current: Dictionary = crowd_physics_evidence.get("commandedStationaryFramesByActor", {}) as Dictionary
	var maximum: Dictionary = crowd_physics_evidence.get("maxCommandedStationaryFramesByActor", {}) as Dictionary
	for citizen_entry in citizens:
		var body := valid_citizen_body(citizen_entry)
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		if body == null:
			continue
		var actor_id := String(manifest.get("id", body.name))
		var requested: Vector3 = body.get_meta("npc_requested_velocity", Vector3.ZERO)
		var applied: Vector3 = body.get_meta("npc_applied_velocity", Vector3.ZERO)
		var frames := int(current.get(actor_id, 0)) + 1 if requested.length() > 0.2 and applied.length() < 0.05 else 0
		current[actor_id] = frames
		maximum[actor_id] = maxi(int(maximum.get(actor_id, 0)), frames)
	crowd_physics_evidence["commandedStationaryFramesByActor"] = current
	crowd_physics_evidence["maxCommandedStationaryFramesByActor"] = maximum


func closest_crowd_pair_record() -> Dictionary:
	var closest: Dictionary = {}
	var closest_distance := INF
	for left_index in range(citizens.size()):
		var left_body := valid_citizen_body(citizens[left_index] as Dictionary)
		if left_body == null:
			continue
		var left_entry: Dictionary = npc_system.call("npc_entry_for_actor", left_body) as Dictionary
		var left_profile = left_entry.get("motorProfile")
		var left_radius := npc_body_collision_radius(left_body)
		var left_navigation_radius := float(left_profile.capsule_radius) if left_profile != null else left_radius
		for right_index in range(left_index + 1, citizens.size()):
			var right_body := valid_citizen_body(citizens[right_index] as Dictionary)
			if right_body == null:
				continue
			var separation := Vector2(left_body.global_position.x - right_body.global_position.x, left_body.global_position.z - right_body.global_position.z).length()
			if separation >= closest_distance:
				continue
			var right_entry: Dictionary = npc_system.call("npc_entry_for_actor", right_body) as Dictionary
			var right_profile = right_entry.get("motorProfile")
			var right_radius := npc_body_collision_radius(right_body)
			var right_navigation_radius := float(right_profile.capsule_radius) if right_profile != null else right_radius
			closest_distance = separation
			closest = {
				"left": String(left_entry.get("id", left_body.name)),
				"right": String(right_entry.get("id", right_body.name)),
				"leftPosition": left_body.global_position,
				"rightPosition": right_body.global_position,
				"leftVelocity": left_body.get_meta("npc_applied_velocity", Vector3.ZERO),
				"rightVelocity": right_body.get_meta("npc_applied_velocity", Vector3.ZERO),
				"leftAvoidance": left_entry.get("routeLeaseAvoidance", {}),
				"rightAvoidance": right_entry.get("routeLeaseAvoidance", {}),
				"separation": separation,
				"required": left_radius + right_radius,
				"avoidanceRequired": left_navigation_radius + right_navigation_radius + NpcConstantsScript.AVOIDANCE_RADIUS_SAFETY_MARGIN * 2.0,
				"leftNavigationRadius": left_navigation_radius,
				"rightNavigationRadius": right_navigation_radius
			}
	return closest


func valid_citizen_body(citizen_entry: Dictionary) -> CharacterBody3D:
	var body_value = citizen_entry.get("body")
	if body_value == null or not is_instance_valid(body_value):
		return null
	return body_value as CharacterBody3D


func npc_body_collision_radius(body: CharacterBody3D) -> float:
	if body == null:
		return 0.34
	var collider := body.get_node_or_null("NpcCollider") as CollisionShape3D
	if collider != null and collider.shape is CapsuleShape3D:
		return float((collider.shape as CapsuleShape3D).radius)
	return 0.34


func capture_crowd_minimum_pair(pair: Dictionary, capture_index: int) -> void:
	var snapshot := citizen_observation_snapshot("crowd_minimum_%02d" % capture_index)
	await capture_closest_crowd_pair_view("crowd_minimum_%02d" % capture_index, snapshot)
	crowd_capture_count = maxi(crowd_capture_count, capture_index)
	crowd_capture_pending = false


func update_biped_presenters(delta: float) -> void:
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		var locomotion = citizen_entry.get("locomotion")
		if body == null or not is_instance_valid(body) or locomotion == null or not is_instance_valid(locomotion):
			continue
		locomotion.apply_body_motion(body, delta)


func settle_biped_presentation() -> void:
	await get_tree().process_frame
	update_biped_presenters(0.0)
	await RenderingServer.frame_post_draw


func lineup_presentation_summary(snapshot: Dictionary) -> Dictionary:
	var idle_count := 0
	var available_count := 0
	var details := {}
	for citizen_value in snapshot.get("citizens", []) as Array:
		if not (citizen_value is Dictionary):
			continue
		var citizen: Dictionary = citizen_value
		var presentation: Dictionary = citizen.get("presentation", {}) as Dictionary
		var actor_id := String(citizen.get("id", ""))
		if bool(presentation.get("available", false)):
			available_count += 1
		if bool(presentation.get("idle", false)):
			idle_count += 1
		details[actor_id] = presentation.duplicate(true)
	return {
		"expectedCount": citizens.size(),
		"availableCount": available_count,
		"idleCount": idle_count,
		"allIdle": available_count == citizens.size() and idle_count == citizens.size(),
		"citizens": details
	}



func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_R:
			call_deferred("rebuild_citadel")
			get_viewport().set_input_as_handled()
		KEY_F6:
			set_world_display_hour(11.0)
			get_viewport().set_input_as_handled()
		KEY_F7:
			set_world_display_hour(21.0)
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func build_overlay() -> void:
	# The scene owns a minimal fallback panel so a parser/load failure cannot
	# devolve into a bare blue window. Once this script is live, replace it with
	# the animated status overlay below.
	var fallback := get_node_or_null("StartupLoadingLayer")
	if fallback != null:
		fallback.queue_free()
	var layer := CanvasLayer.new()
	layer.layer = 30
	add_child(layer)
	status_label = Label.new()
	status_label.position = Vector2(18, 16)
	status_label.size = Vector2(720, 114)
	status_label.add_theme_font_size_override("font_size", 18)
	status_label.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layer.add_child(status_label)
	loading_overlay = ColorRect.new()
	# Opaque by design: the old translucent fallback let the engine's empty
	# clear colour show through while real world work was still running, which
	# read as a broken blue screen rather than loading feedback.
	loading_overlay.color = Color(0.015, 0.025, 0.05, 1.0)
	loading_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(loading_overlay)
	loading_label = Label.new()
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	loading_label.set_anchors_preset(Control.PRESET_CENTER)
	loading_label.offset_left = -460.0
	loading_label.offset_top = -150.0
	loading_label.offset_right = 460.0
	loading_label.offset_bottom = 150.0
	loading_label.add_theme_font_size_override("font_size", 28)
	loading_label.add_theme_color_override("font_color", Color(0.93, 0.96, 1.0))
	loading_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	loading_overlay.add_child(loading_label)
	update_loading_label()


func set_loading(message: String) -> void:
	loading_message = message
	set_loading_visible(true)
	update_loading_label()


func set_loading_visible(visible: bool) -> void:
	if loading_overlay != null:
		loading_overlay.visible = visible


func update_loading_label() -> void:
	if loading_label == null:
		return
	var dots := ".".repeat(int(floor(loading_elapsed * 4.0)) % 4)
	var detail := "The loading display continues updating while recipe, terrain, collision and resident publication are staged."
	if not fixture_failure_reason.is_empty():
		detail = "%s\n\n%s\nPress R to retry this deterministic fixture seed." % [detail, fixture_failure_reason]
	loading_label.text = "CITADEL LIFE PLAYTEST\n%s%s\n\n%s" % [loading_message, dots, detail]


func request_visual_capture(capture_id: String) -> void:
	if profile_screenshot_dir.is_empty():
		return
	call_deferred("capture_viewport", capture_id)


func capture_viewport(capture_id: String) -> void:
	if profile_screenshot_dir.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(profile_screenshot_dir)
	await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		return
	var path: String = profile_screenshot_dir.path_join("%s.png" % capture_id)
	var save_error: int = image.save_png(path)
	if save_error == OK:
		visual_captures.append({"id": capture_id, "path": path})


func save_current_viewport(capture_id: String) -> void:
	if profile_screenshot_dir.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(profile_screenshot_dir)
	var image: Image = get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		return
	var path: String = profile_screenshot_dir.path_join("%s.png" % capture_id)
	if image.save_png(path) == OK:
		visual_captures.append({"id": capture_id, "path": path})


func fail_fixture_loading(message: String, details: Dictionary = {}) -> void:
	fixture_failure_reason = "%s: %s" % [message, JSON.stringify(details)]
	loading_message = "Setup remains incomplete"
	rebuilding = false
	set_loading_visible(true)
	update_loading_label()
	write_profile_report("failed", fixture_failure_reason)
	if profile_mode:
		call_deferred("quit_failed_profile")


func quit_failed_profile() -> void:
	await prepare_profile_shutdown()
	get_tree().quit()


func update_status() -> void:
	if status_label == null:
		return
	var inside_count := 0
	var route_states := {}
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		if bool(body.get_meta("npc_inside_home", false)):
			inside_count += 1
		var entry: Dictionary = npc_system.call("npc_entry_for_actor", body)
		var state := String(entry.get("routeStatus", "idle"))
		route_states[state] = int(route_states.get(state, 0)) + 1
	var phase_name := "DAY ? civic wandering" if observed_world_phase == "day" else "NIGHT ? returning home"
	var player_ready := player != null and player.is_physics_processing() and not bool(player.get("automated_input"))
	var district_state := "publishing the next relevant district" if district_publication_running else "district queue settled"
	status_label.text = "CITADEL LIFE  |  %s\nseed %d  ?  %.2fx citadel  ?  %d/%d districts published (%s)  ?  %d citizens / %d furnished beds  ?  %d strictly indoors  ?  player %s\n[WASD] move  [F6] set daylight  [F7] set night  [R] retry fixture  [Esc] release mouse\nWorld clock drives the citizen phase. Production NPC bodies, real collision, registered door portals and ordinary public civic/home orders. Route states: %s  ?  staged orders: %d" % [phase_name, selected_seed, selected_citadel_scale, active_district_ids.size(), district_catalog.size(), district_state, citizens.size(), (residence_manifest.get("citizens", []) as Array).size(), inside_count, "interactive" if player_ready else "not-ready", JSON.stringify(route_states), civic_order_queue.size()]


func profile_begin_stage(stage_name: String) -> void:
	profile_stage_name = stage_name
	profile_stage_started_usec = Time.get_ticks_usec()
	write_profile_progress("stage=%s" % stage_name)


func profile_end_stage(stage_name: String, metrics: Dictionary = {}) -> void:
	if profile_stage_name != stage_name or profile_stage_started_usec <= 0:
		return
	var duration_ms := float(Time.get_ticks_usec() - profile_stage_started_usec) / 1000.0
	var record := {
		"name": stage_name,
		"durationMs": duration_ms,
		"metrics": metrics.duplicate(true)
	}
	profile_stages.append(record)
	# Stage timings span many yielded frames. They belong in the dedicated load
	# report, not RuntimePerformanceMonitor's per-frame section samples.
	profile_stage_name = ""
	profile_stage_started_usec = 0
	write_profile_progress("stage=%s durationMs=%.3f" % [stage_name, duration_ms])


func run_profile_observation() -> void:
	var monitor = main.get("runtime_perf_monitor") if main != null else null
	if monitor != null and monitor.has_method("reset"):
		monitor.call("reset")
	profile_phase_samples.clear()
	var half_duration := maxf(2.0, profile_seconds * 0.5)
	set_world_display_hour(11.0)
	refresh_world_phase(true)
	await profile_phase("day", half_duration)
	set_world_display_hour(21.0)
	refresh_world_phase(true)
	await profile_phase("night", half_duration)
	set_world_display_hour(11.0)
	refresh_world_phase(true)
	write_profile_report("completed")


func run_citadel_life_acceptance() -> void:
	# This is a headed, production-scene exercise. It gives the real, interactive
	# player a fixed pre-act view of the gate and uses only public NpcSystem orders
	# for citizens during the act phase. The crowd crossing uses production safe
	# placement to establish its lineup before the act; afterward the fixture never
	# supplies a route, opens a door, moves an NPC, or marks an arrival.
	acceptance_timeline.clear()
	acceptance_result.clear()
	var monitor = main.get("runtime_perf_monitor") if main != null else null
	if monitor != null and monitor.has_method("reset"):
		monitor.call("reset")
	set_world_display_hour(11.0)
	refresh_world_phase(true)
	var day_generation := civic_order_generation
	var day_admission := await await_civic_order_batch_admission("day", day_generation)
	acceptance_order_admissions["day"] = day_admission.duplicate(true)
	acceptance_timeline.append({
		"label": "day_civic_order_admission",
		"processFrame": Engine.get_process_frames(),
		"physicsFrame": Engine.get_physics_frames(),
		"civicOrderAdmission": day_admission.duplicate(true)
	})
	await acceptance_observation_phase("day_civic", acceptance_day_seconds, "day_civic")
	var day_snapshot: Dictionary = citizen_observation_snapshot("day_civic_complete")
	acceptance_timeline.append(day_snapshot)
	await capture_representative_citizen_view("day_civic_citizen", day_snapshot)
	await capture_closest_crowd_pair_view("day_civic_closest_pair", day_snapshot)
	await capture_route_failure_evidence(day_snapshot)
	crowd_stress_active = true
	var lineup_setup := stage_crowd_crossing_orders(false)
	var lineup_generation := civic_order_generation
	var lineup_admission := await await_civic_order_batch_admission("crowd_lineup", lineup_generation)
	var lineup_placement := await place_crowd_lineup_fixture(lineup_setup)
	lineup_setup["preActPlacement"] = lineup_placement
	lineup_setup["evidenceBoundary"] = "fixture setup uses public wait orders and safe placement; crossing movement is live acceptance evidence"
	await settle_biped_presentation()
	var lineup_snapshot: Dictionary = citizen_observation_snapshot("crowd_lineup_pre_act")
	lineup_setup["presentation"] = lineup_presentation_summary(lineup_snapshot)
	acceptance_timeline.append(lineup_snapshot)
	await capture_closest_crowd_pair_view("crowd_lineup_1", lineup_snapshot)
	var lineup_convergence := {
		"passed": bool(lineup_admission.get("allAccepted", false)) and bool(lineup_placement.get("ok", false)) and bool((lineup_setup.get("presentation", {}) as Dictionary).get("allIdle", false)),
		"reason": "" if bool((lineup_setup.get("presentation", {}) as Dictionary).get("allIdle", false)) else "lineup_biped_presentation_not_idle",
		"convergedCount": int(lineup_placement.get("placedCount", 0)),
		"expectedCount": citizens.size()
	}
	await capture_viewport("crowd_lineup_2")
	lineup_setup["convergence"] = lineup_convergence
	lineup_setup["ok"] = bool(lineup_setup.get("ok", false)) and bool(lineup_placement.get("ok", false)) and bool(lineup_convergence.get("passed", false))
	var crossing_start_positions := citizen_positions_by_id()
	var crossing_setup: Dictionary = {"ok": false, "reason": "lineup_not_converged"}
	var crossing_admission: Dictionary = {"timely": false, "allAccepted": false, "reason": "lineup_not_converged"}
	reset_crowd_physics_evidence()
	if bool(lineup_convergence.get("passed", false)):
		crossing_setup = stage_crowd_crossing_orders(true)
		var crossing_generation := civic_order_generation
		crossing_admission = await await_civic_order_batch_admission("crowd_crossing", crossing_generation)
		await acceptance_observation_phase("crowd_crossing", CROWD_CROSSING_SECONDS, "crowd_crossing")
		var crossing_snapshot := citizen_observation_snapshot("crowd_crossing_complete")
		acceptance_timeline.append(crossing_snapshot)
		await capture_closest_crowd_pair_view("crowd_crossing_closest_pair", crossing_snapshot)
		await capture_closest_crowd_pair_view("crowd_final_docking", crossing_snapshot)
	crowd_stress_result = crowd_crossing_summary(crossing_start_positions, lineup_setup, lineup_admission, crossing_setup, crossing_admission)
	crowd_stress_active = false
	set_world_display_hour(19.0)
	refresh_world_phase(true)
	var night_generation := civic_order_generation
	var night_admission := await await_civic_order_batch_admission("night", night_generation)
	acceptance_order_admissions["night"] = night_admission.duplicate(true)
	acceptance_timeline.append({
		"label": "night_home_order_admission",
		"processFrame": Engine.get_process_frames(),
		"physicsFrame": Engine.get_physics_frames(),
		"civicOrderAdmission": night_admission.duplicate(true)
	})
	await acceptance_observation_phase("night_home", acceptance_night_seconds, "night_home")
	var final_snapshot: Dictionary = citizen_observation_snapshot("night_home_complete")
	acceptance_timeline.append(final_snapshot)
	await capture_representative_citizen_view("night_home_citizen", final_snapshot)
	acceptance_post_navigation_audit = post_acceptance_navigation_audit(final_snapshot)
	acceptance_result = acceptance_summary(final_snapshot, day_snapshot, acceptance_order_admissions)
	write_profile_report("completed" if bool(acceptance_result.get("passed", false)) else "failed", String(acceptance_result.get("reason", "")))


func acceptance_observation_phase(phase_name: String, duration_seconds: float, capture_prefix: String) -> void:
	profile_begin_stage("acceptance_%s" % phase_name)
	var started_usec := Time.get_ticks_usec()
	var next_sample_seconds := 0.0
	var capture_index := 0
	while float(Time.get_ticks_usec() - started_usec) / 1000000.0 < duration_seconds:
		var elapsed_seconds := float(Time.get_ticks_usec() - started_usec) / 1000000.0
		if elapsed_seconds >= next_sample_seconds:
			acceptance_timeline.append(citizen_observation_snapshot("%s_%02d" % [phase_name, int(floor(elapsed_seconds))]))
			next_sample_seconds += 1.0
			if capture_index < 2 and elapsed_seconds >= float(capture_index) * maxf(3.0, duration_seconds * 0.45):
				await capture_viewport("%s_%d" % [capture_prefix, capture_index + 1])
				capture_index += 1
		await get_tree().process_frame
	profile_end_stage("acceptance_%s" % phase_name, {
		"activeCitizenCount": citizens.size(),
		"sceneNodeCount": count_scene_nodes(get_tree().root)
	})


func await_crowd_lineup_route_commitment(setup: Dictionary, publication_timeout_seconds: float) -> Dictionary:
	var targets: Dictionary = setup.get("targets", {}) if setup.get("targets", {}) is Dictionary else {}
	var started_usec := Time.get_ticks_usec()
	var route_diagnostics := {}
	var committed_actors := {}
	var committed_route_lengths := {}
	var committed_count := 0
	while float(Time.get_ticks_usec() - started_usec) / 1000000.0 < publication_timeout_seconds:
		route_diagnostics.clear()
		for citizen_entry in citizens:
			var body := valid_citizen_body(citizen_entry)
			var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
			var actor_id := String(manifest.get("id", body.name if body != null else ""))
			if body == null or not (targets.get(actor_id) is Vector3):
				continue
			var target: Vector3 = targets.get(actor_id)
			var npc_entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
			var lease: Dictionary = npc_entry.get("routeLease", {}) if npc_entry.get("routeLease", {}) is Dictionary else {}
			var waypoints: Array = lease.get("waypoints", []) if lease.get("waypoints", []) is Array else []
			var final_matches := false
			if not waypoints.is_empty() and waypoints.back() is Vector3:
				var final_waypoint: Vector3 = waypoints.back()
				final_matches = Vector2(final_waypoint.x - target.x, final_waypoint.z - target.z).length() <= CROWD_FORMATION_ARRIVAL_RADIUS
			var diagnostic := crowd_lineup_actor_diagnostic(body, npc_entry, target)
			var scripted_order: Dictionary = npc_entry.get("scriptedOrder", {}) if npc_entry.get("scriptedOrder", {}) is Dictionary else {}
			var terminal_at_target := String(scripted_order.get("state", "")) == "ARRIVED" \
				and float(diagnostic.get("distance", INF)) <= CELL * 0.38
			if not committed_actors.has(actor_id) and ((String(lease.get("state", "")) == "ready" and final_matches) or terminal_at_target):
				committed_actors[actor_id] = {
					"physicsFrame": Engine.get_physics_frames(),
					"kind": "terminal_arrival" if terminal_at_target else "target_matching_lease"
				}
				committed_route_lengths[actor_id] = float(diagnostic.get("remainingRouteLength", 0.0))
			diagnostic["commitmentLatched"] = committed_actors.get(actor_id, {})
			route_diagnostics[actor_id] = diagnostic
		committed_count = committed_actors.size()
		if committed_count == citizens.size():
			break
		await get_tree().process_frame
	var maximum_route_length := 0.0
	for route_length_value in committed_route_lengths.values():
		maximum_route_length = maxf(maximum_route_length, float(route_length_value))
	var calculated_timeout := maxf(CROWD_LINEUP_MIN_SECONDS, maximum_route_length / CROWD_LINEUP_MIN_PROGRESS_MPS + CROWD_LINEUP_ROUTE_GRACE_SECONDS)
	var passed := committed_count == citizens.size() and calculated_timeout <= CROWD_LINEUP_MAX_SECONDS
	var reason := ""
	if committed_count != citizens.size():
		reason = "lineup_route_publication_timeout"
	elif calculated_timeout > CROWD_LINEUP_MAX_SECONDS:
		reason = "fixture_configuration_unbounded"
	return {
		"passed": passed,
		"reason": reason,
		"committedCount": committed_count,
		"expectedCount": citizens.size(),
		"elapsedMs": float(Time.get_ticks_usec() - started_usec) / 1000.0,
		"maximumRemainingRouteLength": maximum_route_length,
		"minimumProgressMetersPerSecond": CROWD_LINEUP_MIN_PROGRESS_MPS,
		"routeGraceSeconds": CROWD_LINEUP_ROUTE_GRACE_SECONDS,
		"timeoutSeconds": calculated_timeout,
		"committedActors": committed_actors.duplicate(true),
		"committedRouteLengths": committed_route_lengths.duplicate(true),
		"actorDiagnostics": route_diagnostics.duplicate(true)
	}


func crowd_lineup_actor_diagnostic(body: CharacterBody3D, npc_entry: Dictionary, target: Vector3) -> Dictionary:
	var lease: Dictionary = npc_entry.get("routeLease", {}) if npc_entry.get("routeLease", {}) is Dictionary else {}
	var waypoints: Array = lease.get("waypoints", []) if lease.get("waypoints", []) is Array else []
	var waypoint_index := clampi(int(npc_entry.get("_v2LeaseExecutorWaypointIndex", 0)), 0, waypoints.size())
	var remaining_route_length := 0.0
	var previous := body.global_position
	for index in range(waypoint_index, waypoints.size()):
		if not (waypoints[index] is Vector3):
			continue
		var waypoint: Vector3 = waypoints[index]
		remaining_route_length += Vector2(previous.x - waypoint.x, previous.z - waypoint.z).length()
		previous = waypoint
	var execution: Dictionary = npc_entry.get("routineRouteV2LastExecution", {}) if npc_entry.get("routineRouteV2LastExecution", {}) is Dictionary else {}
	var scripted_order: Dictionary = npc_entry.get("scriptedOrder", {}) if npc_entry.get("scriptedOrder", {}) is Dictionary else {}
	return {
		"position": body.global_position,
		"target": target,
		"distance": Vector2(body.global_position.x - target.x, body.global_position.z - target.z).length(),
		"routeStatus": String(npc_entry.get("routeStatus", "")),
		"routeReason": String(npc_entry.get("routeReason", "")),
		"scriptedOrderId": String(scripted_order.get("id", "")),
		"scriptedOrderState": String(scripted_order.get("state", "")),
		"scriptedOrderReason": String(scripted_order.get("statusReason", scripted_order.get("reason", ""))),
		"scriptedOrderTarget": scripted_order.get("target", Vector3.INF),
		"endpointShortfall": npc_entry.get("scriptedRouteEndpointShortfall", {}),
		"leaseId": String(lease.get("leaseId", "")),
		"leaseState": String(lease.get("state", "")),
		"waypointIndex": waypoint_index,
		"waypointCount": waypoints.size(),
		"remainingRouteLength": remaining_route_length,
		"blocker": String(execution.get("blocker", "")),
		"requestedVelocity": body.get_meta("npc_requested_velocity", Vector3.ZERO),
		"appliedVelocity": body.get_meta("npc_applied_velocity", Vector3.ZERO),
		"crowdAvoidance": npc_entry.get("routeLeaseAvoidance", {})
	}


func await_crowd_target_convergence(setup: Dictionary, timeout_seconds: float) -> Dictionary:
	profile_begin_stage("acceptance_crowd_lineup")
	var targets: Dictionary = setup.get("targets", {}) if setup.get("targets", {}) is Dictionary else {}
	var started_usec := Time.get_ticks_usec()
	var converged_count := 0
	var target_distances := {}
	var actor_diagnostics := {}
	var stable_frames := {}
	var arrival_frames := {}
	var midpoint_captured := false
	var reversal_captured := false
	var recovery_captured := false
	var diagnostic_screenshots := {}
	while float(Time.get_ticks_usec() - started_usec) / 1000000.0 < timeout_seconds:
		var elapsed_seconds := float(Time.get_ticks_usec() - started_usec) / 1000000.0
		converged_count = 0
		target_distances.clear()
		actor_diagnostics.clear()
		for citizen_entry in citizens:
			var body := valid_citizen_body(citizen_entry)
			var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
			var actor_id := String(manifest.get("id", body.name if body != null else ""))
			if body == null or not (targets.get(actor_id) is Vector3):
				continue
			var target: Vector3 = targets.get(actor_id)
			var distance := Vector2(body.global_position.x - target.x, body.global_position.z - target.z).length()
			target_distances[actor_id] = distance
			var npc_entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
			var scripted_order: Dictionary = npc_entry.get("scriptedOrder", {}) if npc_entry.get("scriptedOrder", {}) is Dictionary else {}
			var terminal_order_state := String(scripted_order.get("state", "")) == "ARRIVED"
			var within_arrival := distance <= CROWD_FORMATION_ARRIVAL_RADIUS and terminal_order_state
			stable_frames[actor_id] = int(stable_frames.get(actor_id, 0)) + 1 if within_arrival else 0
			if within_arrival and not arrival_frames.has(actor_id):
				arrival_frames[actor_id] = Engine.get_physics_frames()
			elif not within_arrival:
				arrival_frames.erase(actor_id)
			var diagnostic := crowd_lineup_actor_diagnostic(body, npc_entry, target)
			diagnostic["stablePhysicsFrames"] = int(stable_frames.get(actor_id, 0))
			diagnostic["arrivalPhysicsFrame"] = int(arrival_frames.get(actor_id, -1))
			actor_diagnostics[actor_id] = diagnostic
			var reverse_yield: Dictionary = (diagnostic.get("crowdAvoidance", {}) as Dictionary).get("reverseYield", {}) if diagnostic.get("crowdAvoidance", {}) is Dictionary else {}
			var encounter_actor_id := String(reverse_yield.get("encounterActorId", ""))
			if not reversal_captured and int(reverse_yield.get("consecutiveReverseFrames", 0)) >= 6 and encounter_actor_id != "":
				await capture_crowd_encounter_view("crowd_first_sustained_reversal", actor_id, encounter_actor_id)
				diagnostic_screenshots["firstSustainedReversal"] = profile_screenshot_dir.path_join("crowd_first_sustained_reversal.png")
				reversal_captured = true
			if not recovery_captured and int(reverse_yield.get("recoveryCount", 0)) > 0 and encounter_actor_id != "":
				await capture_crowd_encounter_view("crowd_first_recovery", actor_id, encounter_actor_id)
				diagnostic_screenshots["firstRecovery"] = profile_screenshot_dir.path_join("crowd_first_recovery.png")
				recovery_captured = true
			if int(stable_frames.get(actor_id, 0)) >= CROWD_LINEUP_STABLE_PHYSICS_FRAMES:
				converged_count += 1
		if converged_count == citizens.size():
			break
		if not midpoint_captured and elapsed_seconds >= timeout_seconds * 0.5:
			await capture_closest_crowd_pair_view("crowd_lineup_midpoint", citizen_observation_snapshot("crowd_lineup_midpoint"))
			diagnostic_screenshots["midpoint"] = profile_screenshot_dir.path_join("crowd_lineup_midpoint.png")
			midpoint_captured = true
		await get_tree().process_frame
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	if converged_count != citizens.size() and not actor_diagnostics.is_empty():
		var farthest_actor_id := ""
		var farthest_distance := -1.0
		var farthest_encounter_id := ""
		for actor_id_value in actor_diagnostics.keys():
			var actor_id := String(actor_id_value)
			var diagnostic: Dictionary = actor_diagnostics.get(actor_id, {})
			var distance := float(diagnostic.get("distance", -1.0))
			if distance > farthest_distance:
				farthest_distance = distance
				farthest_actor_id = actor_id
				var avoidance: Dictionary = diagnostic.get("crowdAvoidance", {}) if diagnostic.get("crowdAvoidance", {}) is Dictionary else {}
				var reverse_yield: Dictionary = avoidance.get("reverseYield", {}) if avoidance.get("reverseYield", {}) is Dictionary else {}
				farthest_encounter_id = String(reverse_yield.get("encounterActorId", ""))
		if farthest_actor_id != "":
			await capture_crowd_encounter_view("crowd_final_stall", farthest_actor_id, farthest_encounter_id)
			diagnostic_screenshots["finalStall"] = profile_screenshot_dir.path_join("crowd_final_stall.png")
	var result := {
		"passed": converged_count == citizens.size(),
		"convergedCount": converged_count,
		"expectedCount": citizens.size(),
		"elapsedMs": elapsed_ms,
		"timeoutSeconds": timeout_seconds,
		"requiredStablePhysicsFrames": CROWD_LINEUP_STABLE_PHYSICS_FRAMES,
		"targetDistances": target_distances.duplicate(true),
		"actorDiagnostics": actor_diagnostics.duplicate(true),
		"diagnosticScreenshots": diagnostic_screenshots.duplicate(true)
	}
	acceptance_timeline.append({
		"label": "crowd_lineup_convergence",
		"processFrame": Engine.get_process_frames(),
		"physicsFrame": Engine.get_physics_frames(),
		"convergence": result.duplicate(true)
	})
	profile_end_stage("acceptance_crowd_lineup", result)
	return result


func citizen_positions_by_id() -> Dictionary:
	var result := {}
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		if body != null and is_instance_valid(body):
			result[String(manifest.get("id", body.name))] = body.global_position
	return result


func crowd_crossing_summary(start_positions: Dictionary, lineup_setup: Dictionary, lineup_admission: Dictionary, crossing_setup: Dictionary, crossing_admission: Dictionary) -> Dictionary:
	var moved_count := 0
	var arrived_count := 0
	var semantic_arrival_count := 0
	var unchanged_target_count := 0
	var crowd_replan_count := 0
	var distances := {}
	var target_distances := {}
	var crossing_targets: Dictionary = crossing_setup.get("targets", {}) if crossing_setup.get("targets", {}) is Dictionary else {}
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		var actor_id := String(manifest.get("id", body.name if body != null else ""))
		if body == null or not is_instance_valid(body) or not start_positions.has(actor_id):
			continue
		var distance := Vector2(body.global_position.x - (start_positions[actor_id] as Vector3).x, body.global_position.z - (start_positions[actor_id] as Vector3).z).length()
		distances[actor_id] = distance
		if distance >= 4.0:
			moved_count += 1
		if crossing_targets.get(actor_id) is Vector3:
			var target: Vector3 = crossing_targets.get(actor_id)
			var target_distance := Vector2(body.global_position.x - target.x, body.global_position.z - target.z).length()
			target_distances[actor_id] = target_distance
			var npc_entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
			var scripted_order: Dictionary = npc_entry.get("scriptedOrder", {}) if npc_entry.get("scriptedOrder", {}) is Dictionary else {}
			var scripted_target: Vector3 = scripted_order.get("target", Vector3.INF) if scripted_order.get("target", Vector3.INF) is Vector3 else Vector3.INF
			var stable_frames := int((crowd_physics_evidence.get("maxStableSemanticArrivalFramesByActor", {}) as Dictionary).get(actor_id, 0))
			if target_distance <= CROWD_FORMATION_ARRIVAL_RADIUS and String(scripted_order.get("state", "")) == "ARRIVED" and stable_frames >= CROWD_LINEUP_STABLE_PHYSICS_FRAMES:
				arrived_count += 1
				semantic_arrival_count += 1
			if scripted_target.is_finite() and scripted_target.distance_to(target) <= 0.01:
				unchanged_target_count += 1
			crowd_replan_count += int(npc_entry.get("crowdAvoidanceReplanCount", 0))
	var minimum_separation := float(crowd_physics_evidence.get("minimumSeparation", INF))
	var minimum_pair: Dictionary = crowd_physics_evidence.get("minimumPair", {}) if crowd_physics_evidence.get("minimumPair", {}) is Dictionary else {}
	var required_separation := float(minimum_pair.get("avoidanceRequired", float(minimum_pair.get("required", 0.68)) + NpcConstantsScript.AVOIDANCE_RADIUS_SAFETY_MARGIN * 2.0))
	var overlap_frames := int(crowd_physics_evidence.get("overlapFrameCount", 0))
	var max_stationary_frames := 0
	for value in (crowd_physics_evidence.get("maxCommandedStationaryFramesByActor", {}) as Dictionary).values():
		max_stationary_frames = maxi(max_stationary_frames, int(value))
	var admission_ok := bool(lineup_admission.get("allAccepted", false)) and bool(crossing_admission.get("timely", false))
	var congestion_observed := minimum_separation < 2.0
	var movement_ok := moved_count == citizens.size() and arrived_count == citizens.size() and unchanged_target_count == citizens.size() and crowd_replan_count == 0
	return {
		"passed": bool(lineup_setup.get("ok", false)) and bool(crossing_setup.get("ok", false)) and admission_ok and congestion_observed and overlap_frames == 0 and minimum_separation >= required_separation and max_stationary_frames <= 90 and movement_ok,
		"lineupSetup": lineup_setup,
		"lineupAdmission": lineup_admission,
		"crossingSetup": crossing_setup,
		"crossingAdmission": crossing_admission,
		"minimumSeparation": minimum_separation,
		"requiredSeparation": required_separation,
		"overlapFrameCount": overlap_frames,
		"maxCommandedStationaryFrames": max_stationary_frames,
		"movedAtLeastFourMetersCount": moved_count,
		"arrivedAtCrossingEndpointCount": arrived_count,
		"semanticStableArrivalCount": semantic_arrival_count,
		"unchangedTargetCount": unchanged_target_count,
		"crowdReplanCount": crowd_replan_count,
		"expectedCitizenCount": citizens.size(),
		"distances": distances,
		"targetDistances": target_distances,
		"physicsEvidence": crowd_physics_evidence.duplicate(true)
	}


func citizen_observation_snapshot(label: String) -> Dictionary:
	var records: Array[Dictionary] = []
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		var body_cell: Vector2i = flat_cell(body.global_position)
		var interior_min: Vector2i = manifest.get("interiorMinCell", Vector2i.ZERO) as Vector2i
		var interior_max: Vector2i = manifest.get("interiorMaxCell", Vector2i.ZERO) as Vector2i
		var physically_inside := body_cell.x >= interior_min.x and body_cell.x <= interior_max.x and body_cell.y >= interior_min.y and body_cell.y <= interior_max.y
		var entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
		var order: Dictionary = entry.get("scriptedOrder", {}) as Dictionary
		var autonomy = npc_system.get("autonomy_system")
		var route_debug: Dictionary = autonomy.call("route_authority_v2_debug_for_entry", entry) as Dictionary if autonomy != null and autonomy.has_method("route_authority_v2_debug_for_entry") else {}
		var navmesh_world = autonomy.get("navmesh_world") if autonomy != null else null
		var navmesh_path: Dictionary = navmesh_world.call("actor_path_status", String(manifest.get("id", body.name))) as Dictionary if navmesh_world != null and navmesh_world.has_method("actor_path_status") else {}
		var motor_profile = entry.get("motorProfile")
		var body_radius := npc_body_collision_radius(body)
		var navigation_body_radius := float(motor_profile.capsule_radius) if motor_profile != null else body_radius
		var locomotion = citizen_entry.get("locomotion")
		var presentation := biped_presentation_snapshot(locomotion)
		records.append({
			"id": String(manifest.get("id", body.name)),
			"residenceId": String(manifest.get("residenceId", "")),
			"position": body.global_position,
			"cell": body_cell,
			"homeCell": manifest.get("homeCell", Vector2i.ZERO),
			"doorCell": manifest.get("doorCell", Vector2i.ZERO),
			"porchCell": manifest.get("porchCell", Vector2i.ZERO),
			"interiorLandingCell": manifest.get("interiorLandingCell", Vector2i.ZERO),
			"orderTarget": order.get("target", Vector3.INF),
			"orderState": String(order.get("state", "")),
			"routeStatus": String(entry.get("routeStatus", "")),
			"routeReason": String(entry.get("routeReason", "")),
			"routeAuthority": route_debug,
			"navmeshPath": navmesh_path,
			"routeCandidates": entry.get("routineRouteV2LastCandidates", {}),
			"routePlan": entry.get("routineRouteV2LastPlan", {}),
			"routeExecution": entry.get("routineRouteV2LastExecution", {}),
			"crowdAvoidance": entry.get("routeLeaseAvoidance", {}),
			"bodyRadius": body_radius,
			"navigationBodyRadius": navigation_body_radius,
			"requestedVelocity": body.get_meta("npc_requested_velocity", Vector3.ZERO),
			"appliedVelocity": body.get_meta("npc_applied_velocity", Vector3.ZERO),
			"presentation": presentation,
			"doorWaypointBindings": entry.get("routeDoorWaypointBindings", []),
			"homeDepartureState": String(entry.get("homeDepartureState", "")),
			"homeDepartureLastTransition": entry.get("homeDepartureLastTransition", {}),
			"motion": {
				"updates": int(entry.get("npc_motion_updates", 0)),
				"lastTick": int(entry.get("npc_last_motion_tick", -1)),
				"skippedReason": String(entry.get("npc_motion_skipped_reason", "")),
				"skipped": int(entry.get("npc_motion_skipped", 0)),
				"budgetSkipped": int(entry.get("npc_motion_budget_skipped", 0)),
				"handoffSkipped": int(entry.get("npc_motion_handoff_skipped", 0)),
				"activeRouteTicks": int(entry.get("npc_active_route_motion_ticks", 0)),
				"scriptedOrderTicks": int(entry.get("npc_scripted_order_motion_ticks", 0)),
				"doorActionTicks": int(entry.get("npc_door_action_motion_ticks", 0)),
				"routePhysicsServiceTicks": int(entry.get("routePhysicsServiceTicks", 0)),
				"routePhysicsServiceAdvancedTicks": int(entry.get("routePhysicsServiceAdvancedTicks", 0)),
				"routePhysicsServiceMovedTicks": int(entry.get("routePhysicsServiceMovedTicks", 0)),
				"routePhysicsServiceMovedDistance": float(entry.get("routePhysicsServiceMovedDistance", 0.0)),
				"routePhysicsServiceLastFrame": int(entry.get("routePhysicsServiceLastFrame", -1)),
				"routePhysicsServiceKind": String(entry.get("routePhysicsServiceKind", "")),
				"routePhysicsServiceReason": String(entry.get("routePhysicsServiceReason", "")),
				"routePhysicsServiceSinceBrainFrames": int(entry.get("routePhysicsServiceSinceBrainFrames", -1)),
				"routePhysicsServiceLastResult": entry.get("routePhysicsServiceLastResult", {}),
				"routePhysicsServiceResultCounts": entry.get("routePhysicsServiceResultCounts", {})
			},
			"activeDoor": {
				"portalId": String(entry.get("activeDoorPortalId", "")),
				"direction": String(entry.get("activeDoorDirection", "")),
				"trafficGroupId": String(entry.get("activeDoorTrafficGroupId", "")),
				"stageActive": bool(entry.get("doorStageActive", false)),
				"stagePosition": entry.get("doorStagePosition", Vector3.INF)
			},
			"physicallyInsideStrictInterior": physically_inside
		})
	var crowd_summary := crowd_proximity_summary(records)
	if npc_system != null:
		var autonomy = npc_system.get("autonomy_system")
		var crowd_service = autonomy.get("crowd_velocity_service") if autonomy != null else null
		if crowd_service != null and crowd_service.has_method("stats"):
			crowd_summary["solver"] = crowd_service.stats()
	return {
		"label": label,
		"worldPhase": observed_world_phase,
		"clockTime": main.call("clock_time_text") if main != null and main.has_method("clock_time_text") else "",
		"processFrame": Engine.get_process_frames(),
		"physicsFrame": Engine.get_physics_frames(),
		"civicOrderBatch": civic_order_batch_snapshot(civic_order_generation),
		"crowd": crowd_summary,
		"citizens": records
	}


func biped_presentation_snapshot(locomotion) -> Dictionary:
	if locomotion == null or not is_instance_valid(locomotion):
		return {"available": false}
	var skeleton = locomotion.get("skeleton") as Skeleton3D
	var leg_rotation := Quaternion.IDENTITY
	var anatomy_y := 0.0
	if skeleton != null:
		var leg_index := skeleton.find_bone("LegLeft")
		if leg_index >= 0:
			leg_rotation = skeleton.get_bone_pose_rotation(leg_index)
		var anatomy := skeleton.get_node_or_null("NpcTorsoAttachment/NpcBipedAnatomy") as Node3D
		if anatomy != null:
			anatomy_y = anatomy.position.y
	return {
		"available": true,
		"gaitWeight": float(locomotion.get("gait_weight")),
		"legLeftRotation": leg_rotation,
		"anatomyY": anatomy_y,
		"idle": is_zero_approx(float(locomotion.get("gait_weight"))) and leg_rotation.is_equal_approx(Quaternion.IDENTITY) and is_zero_approx(anatomy_y)
	}


func crowd_proximity_summary(records: Array[Dictionary]) -> Dictionary:
	var minimum_separation := INF
	var overlap_pairs: Array[Dictionary] = []
	for left_index in range(records.size()):
		var left: Dictionary = records[left_index]
		var left_position: Vector3 = left.get("position", Vector3.ZERO)
		for right_index in range(left_index + 1, records.size()):
			var right: Dictionary = records[right_index]
			var right_position: Vector3 = right.get("position", Vector3.ZERO)
			var separation := Vector2(left_position.x - right_position.x, left_position.z - right_position.z).length()
			minimum_separation = minf(minimum_separation, separation)
			var required := float(left.get("bodyRadius", 0.34)) + float(right.get("bodyRadius", 0.34))
			if separation + 0.015 < required:
				overlap_pairs.append({
					"left": String(left.get("id", "")),
					"right": String(right.get("id", "")),
					"separation": separation,
					"required": required
				})
	return {
		"minimumSeparation": minimum_separation if minimum_separation < INF else -1.0,
		"overlapCount": overlap_pairs.size(),
		"overlapPairs": overlap_pairs
	}


func capture_route_failure_evidence(snapshot: Dictionary) -> void:
	if profile_screenshot_dir.is_empty():
		return
	var selected: Array[Dictionary] = []
	var departure_timeout_count := 0
	for record_value in snapshot.get("citizens", []) as Array:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value
		var route_status := String(record.get("routeStatus", ""))
		var route_reason := String(record.get("routeReason", ""))
		var evidence_kind := ""
		if route_status in ["unreachable", "blocked", "pending"] and not route_reason.is_empty():
			evidence_kind = "route_failure"
		elif snapshot.get("worldPhase", "") == "day" \
				and bool(record.get("physicallyInsideStrictInterior", false)) \
				and route_status in ["moving", "waiting", "pending"] \
				and departure_timeout_count < MAX_DAY_DEPARTURE_TIMEOUT_CAPTURES:
			evidence_kind = "day_departure_timeout"
			departure_timeout_count += 1
		if evidence_kind.is_empty():
			continue
		var evidence_record := record.duplicate(true)
		evidence_record["acceptanceEvidenceKind"] = evidence_kind
		selected.append(evidence_record)
	selected.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return String(left.get("id", "")) < String(right.get("id", ""))
	)
	for index in range(mini(MAX_FAILURE_DIAGNOSTIC_CAPTURES, selected.size())):
		var record: Dictionary = selected[index]
		var evidence_kind := String(record.get("acceptanceEvidenceKind", "route_failure"))
		var capture_paths := await capture_route_failure_views(record, index + 1, evidence_kind)
		var route_plan: Dictionary = record.get("routePlan", {}) as Dictionary
		acceptance_failure_diagnostics.append({
			"evidenceKind": evidence_kind,
			"actorId": String(record.get("id", "")),
			"residenceId": String(record.get("residenceId", "")),
			"routeStatus": String(record.get("routeStatus", "")),
			"routeReason": String(record.get("routeReason", "")),
			"orderState": String(record.get("orderState", "")),
			"routeAuthority": record.get("routeAuthority", {}),
			"navmeshPath": record.get("navmeshPath", {}),
			"navmeshValidation": route_plan.get("navmeshValidation", {}),
			"routeCandidates": record.get("routeCandidates", {}),
			"routeExecution": record.get("routeExecution", {}),
			"doorWaypointBindings": record.get("doorWaypointBindings", []),
			"motion": record.get("motion", {}),
			"activeDoor": record.get("activeDoor", {}),
			"sourceNavigation": source_navigation_facts_for_failure(record),
			"navmeshContext": navmesh_context_for_failure(record),
			"screenshots": capture_paths
		})


func capture_representative_citizen_view(capture_id: String, snapshot: Dictionary) -> void:
	if profile_screenshot_dir.is_empty():
		return
	var candidates: Array[Dictionary] = []
	for record_value in snapshot.get("citizens", []) as Array:
		if record_value is Dictionary:
			candidates.append(record_value as Dictionary)
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return String(left.get("id", "")) < String(right.get("id", ""))
	)
	for record in candidates:
		var body := citizen_body_for_id(String(record.get("id", "")))
		if body == null:
			continue
		var viewport := get_viewport()
		var previous_camera := viewport.get_camera_3d()
		var observation_camera := Camera3D.new()
		add_child(observation_camera)
		var capture_light := OmniLight3D.new()
		observation_camera.add_child(capture_light)
		capture_light.light_energy = 2.0
		capture_light.omni_range = 10.0
		capture_light.shadow_enabled = false
		var target := body.global_position + Vector3(0.0, 0.9, 0.0)
		observation_camera.global_position = nearby_observation_camera_position(body, target)
		observation_camera.look_at(target, Vector3.UP)
		observation_camera.current = true
		await get_tree().process_frame
		await capture_viewport(capture_id)
		if previous_camera != null and is_instance_valid(previous_camera):
			previous_camera.current = true
		observation_camera.queue_free()
		return


func capture_closest_crowd_pair_view(capture_id: String, snapshot: Dictionary) -> void:
	if profile_screenshot_dir.is_empty():
		return
	var records: Array = snapshot.get("citizens", []) as Array
	var closest_left: Dictionary = {}
	var closest_right: Dictionary = {}
	var closest_distance := INF
	for left_index in range(records.size()):
		if not (records[left_index] is Dictionary):
			continue
		var left: Dictionary = records[left_index]
		var left_position: Vector3 = left.get("position", Vector3.ZERO)
		for right_index in range(left_index + 1, records.size()):
			if not (records[right_index] is Dictionary):
				continue
			var right: Dictionary = records[right_index]
			var right_position: Vector3 = right.get("position", Vector3.ZERO)
			var distance := Vector2(left_position.x - right_position.x, left_position.z - right_position.z).length()
			if distance < closest_distance:
				closest_distance = distance
				closest_left = left
				closest_right = right
	if closest_left.is_empty() or closest_right.is_empty():
		return
	var left_body := citizen_body_for_id(String(closest_left.get("id", "")))
	var right_body := citizen_body_for_id(String(closest_right.get("id", "")))
	if left_body == null or right_body == null:
		return
	var viewport := get_viewport()
	var previous_camera := viewport.get_camera_3d()
	if previous_camera != null and is_instance_valid(previous_camera):
		previous_camera.current = false
	var observation_camera := Camera3D.new()
	add_child(observation_camera)
	var capture_light := OmniLight3D.new()
	observation_camera.add_child(capture_light)
	capture_light.light_energy = 2.0
	capture_light.omni_range = 12.0
	capture_light.shadow_enabled = false
	var midpoint := (left_body.global_position + right_body.global_position) * 0.5 + Vector3(0.0, 0.9, 0.0)
	var pair_axis := right_body.global_position - left_body.global_position
	pair_axis.y = 0.0
	var view_axis := Vector3(-pair_axis.z, 0.0, pair_axis.x).normalized() if pair_axis.length_squared() > 0.001 else Vector3.FORWARD
	observation_camera.global_position = midpoint + view_axis * 4.2 + Vector3(0.0, 2.2, 0.0)
	observation_camera.look_at(midpoint, Vector3.UP)
	observation_camera.make_current()
	await get_tree().process_frame
	observation_camera.make_current()
	await RenderingServer.frame_post_draw
	save_current_viewport(capture_id)
	if previous_camera != null and is_instance_valid(previous_camera):
		previous_camera.current = true
	observation_camera.queue_free()


func capture_crowd_encounter_view(capture_id: String, actor_id: String, encounter_actor_id: String) -> void:
	if profile_screenshot_dir.is_empty():
		return
	var actor := citizen_body_for_id(actor_id)
	var encounter := citizen_body_for_id(encounter_actor_id)
	if actor == null:
		return
	var viewport := get_viewport()
	var previous_camera := viewport.get_camera_3d()
	if previous_camera != null and is_instance_valid(previous_camera):
		previous_camera.current = false
	var observation_camera := Camera3D.new()
	add_child(observation_camera)
	var capture_light := OmniLight3D.new()
	observation_camera.add_child(capture_light)
	capture_light.light_energy = 2.4
	capture_light.omni_range = 14.0
	capture_light.shadow_enabled = false
	var midpoint := actor.global_position
	var pair_axis := Vector3.FORWARD
	if encounter != null:
		midpoint = (actor.global_position + encounter.global_position) * 0.5
		pair_axis = encounter.global_position - actor.global_position
	pair_axis.y = 0.0
	var view_axis := Vector3(-pair_axis.z, 0.0, pair_axis.x).normalized() if pair_axis.length_squared() > 0.001 else Vector3.FORWARD
	var target := midpoint + Vector3(0.0, 0.9, 0.0)
	observation_camera.global_position = target + view_axis * 4.8 + Vector3(0.0, 2.4, 0.0)
	observation_camera.look_at(target, Vector3.UP)
	observation_camera.make_current()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	save_current_viewport(capture_id)
	if previous_camera != null and is_instance_valid(previous_camera):
		previous_camera.current = true
	observation_camera.queue_free()


func capture_route_failure_views(record: Dictionary, capture_index: int, evidence_kind := "route_failure") -> Dictionary:
	var body := citizen_body_for_id(String(record.get("id", "")))
	if body == null:
		return {}
	var viewport := get_viewport()
	var previous_camera := viewport.get_camera_3d()
	var observation_camera := Camera3D.new()
	add_child(observation_camera)
	var capture_light := OmniLight3D.new()
	observation_camera.add_child(capture_light)
	capture_light.light_energy = 2.0
	capture_light.omni_range = 12.0
	capture_light.shadow_enabled = false
	var visual_points := route_failure_visual_points(record, body.global_position)
	var markers := create_route_failure_markers(visual_points)
	var target := body.global_position + Vector3(0.0, 1.0, 0.0)
	observation_camera.global_position = nearby_observation_camera_position(body, target)
	observation_camera.look_at(target, Vector3.UP)
	observation_camera.current = true
	await get_tree().process_frame
	var capture_slug := "%02d_%s" % [capture_index, route_failure_capture_slug(String(record.get("id", "")))]
	var close_capture_id := "day_%s_close_%s" % [evidence_kind, capture_slug]
	await capture_viewport(close_capture_id)
	var overview := route_failure_overview(visual_points, body.global_position)
	var overview_target: Vector3 = overview.get("target", target) as Vector3
	var overview_position: Vector3 = overview.get("position", observation_camera.global_position) as Vector3
	observation_camera.global_position = nearby_observation_camera_position(body, overview_target, overview_position)
	observation_camera.look_at(overview_target, Vector3.UP)
	capture_light.omni_range = maxf(12.0, float(overview.get("radius", 4.0)) * 2.4)
	await get_tree().process_frame
	var overview_capture_id := "day_%s_overview_%s" % [evidence_kind, capture_slug]
	await capture_viewport(overview_capture_id)
	if previous_camera != null and is_instance_valid(previous_camera):
		previous_camera.current = true
	observation_camera.queue_free()
	for marker in markers:
		if marker != null and is_instance_valid(marker):
			marker.queue_free()
	return {
		"close": profile_screenshot_dir.path_join("%s.png" % close_capture_id),
		"overview": profile_screenshot_dir.path_join("%s.png" % overview_capture_id)
	}


func route_failure_visual_points(record: Dictionary, body_position: Vector3) -> Array[Dictionary]:
	const MAX_ROUTE_FAILURE_VISUAL_DISTANCE := 24.0
	var points: Array[Dictionary] = []
	var navmesh_path: Dictionary = record.get("navmeshPath", {}) as Dictionary
	var route_plan: Dictionary = record.get("routePlan", {}) as Dictionary
	var validation: Dictionary = route_plan.get("navmeshValidation", {}) as Dictionary
	append_route_failure_visual_point(points, navmesh_path.get("target", record.get("orderTarget", body_position)), body_position, MAX_ROUTE_FAILURE_VISUAL_DISTANCE, Color(1.0, 0.25, 0.18, 1.0), 0.22)
	append_route_failure_visual_point(points, validation.get("point", body_position), body_position, MAX_ROUTE_FAILURE_VISUAL_DISTANCE, Color(1.0, 0.78, 0.12, 1.0), 0.18)
	for path_key in ["path", "rawPath", "fallbackRawPath"]:
		for path_point in navmesh_path.get(path_key, []) as Array:
			append_route_failure_visual_point(points, path_point, body_position, MAX_ROUTE_FAILURE_VISUAL_DISTANCE, Color(0.20, 0.72, 1.0, 1.0), 0.13)
	var source_navigation := source_navigation_facts_for_failure(record)
	var door: Dictionary = source_navigation.get("door", {}) as Dictionary
	append_route_failure_visual_point(points, door.get("interior", Vector3.INF), body_position, MAX_ROUTE_FAILURE_VISUAL_DISTANCE, Color(0.30, 1.0, 0.42, 1.0), 0.20)
	append_route_failure_visual_point(points, door.get("exterior", Vector3.INF), body_position, MAX_ROUTE_FAILURE_VISUAL_DISTANCE, Color(0.12, 0.84, 0.82, 1.0), 0.18)
	for passage_value in source_navigation.get("interiorPassageLinks", []) as Array:
		if not (passage_value is Dictionary):
			continue
		var passage: Dictionary = passage_value
		append_route_failure_visual_point(points, passage.get("start", Vector3.INF), body_position, MAX_ROUTE_FAILURE_VISUAL_DISTANCE, Color(0.72, 0.38, 1.0, 1.0), 0.12)
		append_route_failure_visual_point(points, passage.get("end", Vector3.INF), body_position, MAX_ROUTE_FAILURE_VISUAL_DISTANCE, Color(0.72, 0.38, 1.0, 1.0), 0.12)
	for vertical_value in source_navigation.get("verticalLinks", []) as Array:
		if not (vertical_value is Dictionary):
			continue
		var vertical: Dictionary = vertical_value
		append_route_failure_visual_point(points, vertical.get("start", Vector3.INF), body_position, MAX_ROUTE_FAILURE_VISUAL_DISTANCE, Color(1.0, 0.46, 0.16, 1.0), 0.15)
		append_route_failure_visual_point(points, vertical.get("end", Vector3.INF), body_position, MAX_ROUTE_FAILURE_VISUAL_DISTANCE, Color(1.0, 0.86, 0.18, 1.0), 0.15)
	return points


func append_route_failure_visual_point(points: Array[Dictionary], value, body_position: Vector3, max_distance: float, color: Color, scale: float) -> void:
	var position := diagnostic_vector3(value, Vector3.INF)
	if not position.is_finite() or body_position.distance_to(position) > max_distance:
		return
	points.append({"position": position, "color": color, "scale": scale})


func create_route_failure_markers(positions: Array[Dictionary]) -> Array[MeshInstance3D]:
	var markers: Array[MeshInstance3D] = []
	for marker_data in positions:
		var marker := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		var scale := float(marker_data.get("scale", 0.16))
		sphere.radius = scale
		sphere.height = scale * 2.0
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = marker_data.get("color", Color.WHITE) as Color
		material.emission_enabled = true
		material.emission = marker_data.get("color", Color.WHITE) as Color
		marker.mesh = sphere
		marker.material_override = material
		add_child(marker)
		marker.global_position = marker_data.get("position", Vector3.ZERO) as Vector3
		markers.append(marker)
	return markers


func route_failure_overview(visual_points: Array[Dictionary], body_position: Vector3) -> Dictionary:
	var points: Array[Vector3] = [body_position]
	for point_value in visual_points:
		if point_value is Dictionary:
			var point := diagnostic_vector3((point_value as Dictionary).get("position", Vector3.INF), Vector3.INF)
			if point.is_finite():
				points.append(point)
	var center := Vector3.ZERO
	for point in points:
		center += point
	center /= float(maxi(1, points.size()))
	var radius := 4.0
	for point in points:
		radius = maxf(radius, Vector2(point.x - center.x, point.z - center.z).length())
	var horizontal_offset := Vector2(body_position.x - center.x, body_position.z - center.z)
	if horizontal_offset.length_squared() < 0.01:
		horizontal_offset = Vector2(1.0, 1.0)
	else:
		horizontal_offset = horizontal_offset.normalized()
	var overview_distance := clampf(radius * 0.65, 1.8, 3.2)
	return {
		"target": center + Vector3(0.0, 0.75, 0.0),
		"position": body_position + Vector3(horizontal_offset.x * overview_distance, 1.65, horizontal_offset.y * overview_distance),
		"radius": radius
	}


func diagnostic_vector3(value, fallback: Vector3) -> Vector3:
	if value is Vector3:
		var candidate: Vector3 = value
		if candidate.is_finite():
			return candidate
	return fallback


func source_navigation_facts_for_failure(record: Dictionary) -> Dictionary:
	var citizen := residence_citizen_for_actor(String(record.get("id", "")))
	var residence_id := String(citizen.get("residenceId", record.get("residenceId", "")))
	var residence := residence_record_for_id(residence_id)
	var route_plan: Dictionary = record.get("routePlan", {}) as Dictionary
	var validation: Dictionary = route_plan.get("navmeshValidation", {}) as Dictionary
	var navmesh_path: Dictionary = record.get("navmeshPath", {}) as Dictionary
	var collision: Dictionary = validation.get("collision", {}) as Dictionary
	var source_part_id := String(collision.get("sourcePartId", ""))
	var door_part_id := String(citizen.get("doorPartId", residence.get("doorPartId", "")))
	var residence_part_prefix := door_part_id
	var manor_marker := residence_part_prefix.find("__manor_")
	if manor_marker > 0:
		residence_part_prefix = residence_part_prefix.left(manor_marker)
	var route_start: Vector3 = navmesh_path.get("startPosition", Vector3.ZERO) as Vector3
	var route_target: Vector3 = navmesh_path.get("targetPosition", Vector3.ZERO) as Vector3
	var route_corridor := AABB(route_start, Vector3.ZERO).expand(route_target).grow(0.64)
	var support_ids := {}
	for support_id in [
		String(citizen.get("porchSupportId", residence.get("porchSupportId", ""))),
		String(citizen.get("interiorSupportId", residence.get("interiorSupportId", "")))
	]:
		if not support_id.is_empty():
			support_ids[support_id] = true
	var source_door := {}
	var source_supports: Array[Dictionary] = []
	var source_support_seam_links: Array[Dictionary] = []
	var source_interior_passage_links: Array[Dictionary] = []
	var source_vertical_links: Array[Dictionary] = []
	var source_collision := {}
	var route_corridor_collision: Array[Dictionary] = []
	if npc_system != null and npc_system.has_method("building_navigation_manifest_snapshot"):
		for manifest_value in npc_system.call("building_navigation_manifest_snapshot") as Array:
			if not (manifest_value is Dictionary):
				continue
			var manifest: Dictionary = manifest_value
			for door_value in manifest.get("doors", []) as Array:
				if door_value is Dictionary and String((door_value as Dictionary).get("sourcePartId", "")) == door_part_id:
					source_door = (door_value as Dictionary).duplicate(true)
					support_ids[String(source_door.get("interiorSupportId", ""))] = true
					support_ids[String(source_door.get("exteriorSupportId", ""))] = true
			for seam_link_value in manifest.get("supportSeamLinks", []) as Array:
				if seam_link_value is Dictionary and support_ids.has(String((seam_link_value as Dictionary).get("supportId", ""))):
					source_support_seam_links.append((seam_link_value as Dictionary).duplicate(true))
			for passage_link_value in manifest.get("interiorPassageLinks", []) as Array:
				if not (passage_link_value is Dictionary):
					continue
				var passage_link: Dictionary = passage_link_value
				if support_ids.has(String(passage_link.get("firstSupportId", ""))) or support_ids.has(String(passage_link.get("secondSupportId", ""))):
					source_interior_passage_links.append(passage_link.duplicate(true))
			for vertical_link_value in manifest.get("verticalLinks", []) as Array:
				if not (vertical_link_value is Dictionary):
					continue
				var vertical_link: Dictionary = vertical_link_value
				if not String(vertical_link.get("sourcePartId", "")).begins_with(residence_part_prefix):
					continue
				source_vertical_links.append(vertical_link.duplicate(true))
				support_ids[String(vertical_link.get("startSupportId", ""))] = true
				support_ids[String(vertical_link.get("endSupportId", ""))] = true
			for collision_value in manifest.get("staticCollision", []) as Array:
				if collision_value is Dictionary:
					var collision_fact: Dictionary = collision_value
					if String(collision_fact.get("sourcePartId", "")) == source_part_id:
						source_collision = collision_fact.duplicate(true)
					if route_corridor_contains_residence_collision(route_corridor, residence_part_prefix, collision_fact):
						route_corridor_collision.append(collision_fact.duplicate(true))
	if npc_system != null and npc_system.has_method("navigation_collision_manifest_snapshot"):
		for manifest_value in npc_system.call("navigation_collision_manifest_snapshot") as Array:
			if not (manifest_value is Dictionary):
				continue
			var collision_manifest: Dictionary = manifest_value
			for collision_value in collision_manifest.get("staticCollision", []) as Array:
				if collision_value is Dictionary:
					var collision_fact: Dictionary = collision_value
					if route_corridor_contains_residence_collision(route_corridor, residence_part_prefix, collision_fact):
						route_corridor_collision.append(collision_fact.duplicate(true))
	if npc_system != null and npc_system.has_method("building_navigation_manifest_snapshot"):
		for manifest_value in npc_system.call("building_navigation_manifest_snapshot") as Array:
			if not (manifest_value is Dictionary):
				continue
			for support_value in (manifest_value as Dictionary).get("supports", []) as Array:
				if support_value is Dictionary and support_ids.has(String((support_value as Dictionary).get("id", ""))):
					source_supports.append((support_value as Dictionary).duplicate(true))
	route_corridor_collision.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
	source_vertical_links.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
	var portal_id := String(citizen.get("doorPortalId", residence.get("doorPortalId", "")))
	return {
		"resident": citizen,
		"residence": residence,
		"portalId": portal_id,
		"door": source_door,
		"supports": source_supports,
		"supportSeamLinks": source_support_seam_links,
		"interiorPassageLinks": source_interior_passage_links,
		"verticalLinks": source_vertical_links,
		"verticalLinkPublication": vertical_link_publication_for_failure(source_vertical_links),
		"blockingStaticCollision": source_collision,
		"routeCorridorBounds": route_corridor,
		"routeCorridorStaticCollision": route_corridor_collision,
		"supportNavigationSamples": support_navigation_samples_for_failure(record, source_door, source_support_seam_links)
	}


func vertical_link_publication_for_failure(vertical_links: Array[Dictionary]) -> Array[Dictionary]:
	var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
	var adapter = autonomy.call("generated_navigation_adapter") if autonomy != null and autonomy.has_method("generated_navigation_adapter") else null
	var result: Array[Dictionary] = []
	for vertical_link in vertical_links:
		var link_id := String(vertical_link.get("id", ""))
		var owner_tile_key := String(vertical_link.get("ownerTileKey", ""))
		var published := false
		var tile_links: Array[Dictionary] = []
		var resolution_diagnostics: Array = []
		if adapter != null and adapter.has_method("build_navmesh_tile_snapshot") and not owner_tile_key.is_empty():
			var snapshot_value = adapter.call("build_navmesh_tile_snapshot", owner_tile_key)
			if snapshot_value is Dictionary:
				for link_value in (snapshot_value as Dictionary).get("navigationLinks", []) as Array:
					if link_value is Dictionary and String((link_value as Dictionary).get("id", "")) == link_id:
						published = true
						tile_links.append((link_value as Dictionary).duplicate(true))
			if adapter.has_method("building_navigation_link_resolution_diagnostics"):
				resolution_diagnostics = adapter.call("building_navigation_link_resolution_diagnostics", owner_tile_key, [link_id]) as Array
		result.append({
			"id": link_id,
			"ownerTileKey": owner_tile_key,
			"startSupportId": String(vertical_link.get("startSupportId", "")),
			"endSupportId": String(vertical_link.get("endSupportId", "")),
			"publishedToTile": published,
			"tileLinks": tile_links,
			"resolutionDiagnostics": resolution_diagnostics
		})
	return result


func collect_manor_stair_link_diagnostics() -> void:
	link_diagnostics.clear()
	var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
	var adapter = autonomy.call("generated_navigation_adapter") if autonomy != null and autonomy.has_method("generated_navigation_adapter") else null
	if adapter == null or not adapter.has_method("building_navigation_link_resolution_diagnostics"):
		link_diagnostics.append({"diagnosticOnly": true, "reason": "missing_navigation_adapter"})
		return
	var links_by_tile := {}
	if npc_system != null and npc_system.has_method("building_navigation_manifest_snapshot"):
		for manifest_value in npc_system.call("building_navigation_manifest_snapshot") as Array:
			if not (manifest_value is Dictionary):
				continue
			for link_value in (manifest_value as Dictionary).get("verticalLinks", []) as Array:
				if not (link_value is Dictionary):
					continue
				var link: Dictionary = link_value
				if not String(link.get("sourcePartId", "")).contains("__manor_stair_"):
					continue
				var owner_tile_key := String(link.get("ownerTileKey", ""))
				if owner_tile_key.is_empty():
					continue
				if not links_by_tile.has(owner_tile_key):
					links_by_tile[owner_tile_key] = []
				(links_by_tile[owner_tile_key] as Array).append(link.duplicate(true))
	var tile_keys: Array = links_by_tile.keys()
	tile_keys.sort()
	for tile_key_value in tile_keys:
		var tile_key := String(tile_key_value)
		var links: Array = links_by_tile.get(tile_key, []) as Array
		var link_ids: Array = []
		for link_value in links:
			if link_value is Dictionary:
				link_ids.append(String((link_value as Dictionary).get("id", "")))
		var resolution_diagnostics = adapter.call("building_navigation_link_resolution_diagnostics", tile_key, link_ids)
		link_diagnostics.append({
			"diagnosticOnly": true,
			"tileKey": tile_key,
			"verticalLinks": links,
			"resolutionDiagnostics": resolution_diagnostics if resolution_diagnostics is Array else []
		})


func route_corridor_contains_residence_collision(corridor: AABB, residence_part_prefix: String, collision_fact: Dictionary) -> bool:
	if residence_part_prefix.is_empty() or not String(collision_fact.get("sourcePartId", "")).begins_with(residence_part_prefix):
		return false
	var bounds: AABB = collision_fact.get("bounds", AABB()) if collision_fact.get("bounds", AABB()) is AABB else AABB()
	return bounds.size.length_squared() > 0.0 and bounds.intersects(corridor)


func support_navigation_samples_for_failure(record: Dictionary, door: Dictionary, support_seam_links: Array[Dictionary]) -> Dictionary:
	var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
	var adapter = autonomy.call("generated_navigation_adapter") if autonomy != null and autonomy.has_method("generated_navigation_adapter") else null
	var support_id := String(door.get("interiorSupportId", ""))
	if adapter == null or not adapter.has_method("building_support_navigation_sample_diagnostics") or support_id.is_empty():
		return {"diagnosticOnly": true, "reason": "missing_support_navigation_diagnostic_inputs", "supportId": support_id}
	var navmesh_path: Dictionary = record.get("navmeshPath", {}) as Dictionary
	var route_plan: Dictionary = record.get("routePlan", {}) as Dictionary
	var validation: Dictionary = route_plan.get("navmeshValidation", {}) as Dictionary
	var probes: Array[Dictionary] = []
	var interior_support_id := String(door.get("interiorSupportId", ""))
	var interior_support_seams: Array[Dictionary] = []
	for seam_link in support_seam_links:
		if String(seam_link.get("supportId", "")) == interior_support_id:
			interior_support_seams.append(seam_link)
	var start: Vector3 = navmesh_path.get("startPosition", Vector3.INF) as Vector3
	var interior: Vector3 = door.get("interior", Vector3.INF) as Vector3
	if start.is_finite():
		probes.append({"id": "route_start", "position": start})
	if interior.is_finite():
		probes.append({"id": "door_interior", "position": interior})
	var validation_point: Vector3 = validation.get("point", Vector3.INF) as Vector3
	if validation_point.is_finite():
		probes.append({"id": "route_validation", "position": validation_point})
	for seam_link in interior_support_seams:
		for endpoint_key in ["start", "end"]:
			var endpoint: Vector3 = seam_link.get(endpoint_key, Vector3.INF) as Vector3
			if endpoint.is_finite():
				probes.append({"id": "%s_%s" % [String(seam_link.get("id", "support_seam")), endpoint_key], "position": endpoint})
	var probes_by_tile := {}
	for probe in probes:
		var position: Vector3 = probe.get("position", Vector3.INF) as Vector3
		if not position.is_finite():
			continue
		var cell_value = adapter.call("world_cell", position)
		if not (cell_value is Vector2i):
			continue
		var tile_key := String(adapter.call("tile_key_for_cell", cell_value as Vector2i))
		if tile_key.is_empty():
			continue
		if not probes_by_tile.has(tile_key):
			probes_by_tile[tile_key] = []
		(probes_by_tile[tile_key] as Array).append(probe)
	var tile_keys: Array = probes_by_tile.keys()
	tile_keys.sort()
	var tile_diagnostics: Array[Dictionary] = []
	var furniture_ablation_tiles: Array[Dictionary] = []
	for tile_key_value in tile_keys:
		var tile_key := String(tile_key_value)
		var diagnostic_value = adapter.call("building_support_navigation_sample_diagnostics", support_id, tile_key, probes_by_tile[tile_key])
		if diagnostic_value is Dictionary:
			tile_diagnostics.append(diagnostic_value as Dictionary)
		var furniture_ablation_value = adapter.call("building_support_navigation_sample_diagnostics", support_id, tile_key, probes_by_tile[tile_key], {"excludeFurnishings": true})
		if furniture_ablation_value is Dictionary:
			furniture_ablation_tiles.append(furniture_ablation_value as Dictionary)
	return {
		"diagnosticOnly": true,
		"supportId": support_id,
		"tiles": tile_diagnostics,
		"withoutFurnishings": furniture_ablation_tiles
	}


func navmesh_context_for_failure(record: Dictionary) -> Dictionary:
	var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
	var navmesh_world = autonomy.get("navmesh_world") if autonomy != null else null
	if navmesh_world == null or not navmesh_world.has_method("debug_snapshot"):
		return {"reason": "missing_navmesh_world"}
	var snapshot: Dictionary = navmesh_world.call("debug_snapshot") as Dictionary
	var navmesh_path: Dictionary = record.get("navmeshPath", {}) as Dictionary
	var start_walkable: Dictionary = navmesh_path.get("startWalkable", {}) as Dictionary
	var target_walkable: Dictionary = navmesh_path.get("targetWalkable", {}) as Dictionary
	var regions: Dictionary = snapshot.get("regions", {}) as Dictionary
	var source_facts := source_navigation_facts_for_failure(record)
	var portal_id := String(source_facts.get("portalId", ""))
	var door_links: Dictionary = snapshot.get("doorLinks", {}) as Dictionary
	var portal_states: Dictionary = snapshot.get("doorPortalStates", {}) as Dictionary
	var publication_telemetry: Dictionary = snapshot.get("publicationTelemetry", {}) as Dictionary
	var seam_ids := {}
	for links_key in ["supportSeamLinks", "interiorPassageLinks", "verticalLinks"]:
		for link_value in source_facts.get(links_key, []) as Array:
			if link_value is Dictionary:
				seam_ids[String((link_value as Dictionary).get("id", ""))] = true
	var required_navigation_links: Array[Dictionary] = []
	for link_value in snapshot.get("navigationLinks", []) as Array:
		if link_value is Dictionary and seam_ids.has(String((link_value as Dictionary).get("id", ""))):
			required_navigation_links.append((link_value as Dictionary).duplicate(true))
	var pending_navigation_links: Array[Dictionary] = []
	for link_value in snapshot.get("pendingNavigationLinks", []) as Array:
		if link_value is Dictionary:
			pending_navigation_links.append((link_value as Dictionary).duplicate(true))
	return {
		"topologyRevision": snapshot.get("topologyRevision", 0),
		"dynamicRevision": snapshot.get("dynamicRevision", 0),
		"navigationMapReadiness": snapshot.get("navigationMapReadiness", {}),
		"startRegion": navmesh_region_context(regions, String(start_walkable.get("regionId", "")), String(start_walkable.get("surfaceId", "")), source_facts.get("routeCorridorBounds", AABB())),
		"targetRegion": navmesh_region_context(regions, String(target_walkable.get("regionId", "")), String(target_walkable.get("surfaceId", "")), source_facts.get("routeCorridorBounds", AABB())),
		"startRegionPublication": publication_telemetry.get(String(start_walkable.get("regionId", "")), {}),
		"targetRegionPublication": publication_telemetry.get(String(target_walkable.get("regionId", "")), {}),
		"requiredDoorLinks": door_links.get(portal_id, []),
		"requiredNavigationLinks": required_navigation_links,
		"pendingNavigationLinks": pending_navigation_links,
		"requiredDoorState": portal_states.get(portal_id, {}),
		"diagnosticProbes": navmesh_diagnostic_probes(navmesh_world, navmesh_path, source_facts, required_navigation_links)
	}


func post_acceptance_navigation_audit(final_snapshot: Dictionary) -> Dictionary:
	var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
	var navmesh_world = autonomy.get("navmesh_world") if autonomy != null else null
	if navmesh_world == null or not navmesh_world.has_method("query_route"):
		return {"reason": "missing_navmesh_world"}
	var routes: Array[Dictionary] = []
	for record_value in final_snapshot.get("citizens", []) as Array:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value as Dictionary
		var navmesh_path: Dictionary = record.get("navmeshPath", {}) as Dictionary
		var start: Vector3 = navmesh_path.get("startPosition", Vector3.INF) as Vector3
		var target: Vector3 = navmesh_path.get("targetPosition", Vector3.INF) as Vector3
		if not start.is_finite() or not target.is_finite():
			routes.append({
				"actorId": String(record.get("id", "")),
				"residenceId": String(record.get("residenceId", "")),
				"reason": "missing_route_endpoints"
			})
			continue
		routes.append({
			"actorId": String(record.get("id", "")),
			"residenceId": String(record.get("residenceId", "")),
			"recordedRouteStatus": String(record.get("routeStatus", "")),
			"recordedRouteReason": String(record.get("routeReason", "")),
			"serverRoute": navmesh_diagnostic_route(navmesh_world, start, target, false),
			"descriptorRoute": navmesh_diagnostic_route(navmesh_world, start, target, true)
		})
	return {
		"navigationMapReadiness": navmesh_world.call("navigation_map_readiness") if navmesh_world.has_method("navigation_map_readiness") else {},
		"stats": navmesh_world.call("stats") if navmesh_world.has_method("stats") else {},
		"routes": routes
	}


func navmesh_diagnostic_probes(navmesh_world, navmesh_path: Dictionary, source_facts: Dictionary, installed_navigation_links: Array[Dictionary]) -> Dictionary:
	var door: Dictionary = source_facts.get("door", {}) as Dictionary
	var portal_id := String(source_facts.get("portalId", ""))
	var interior: Vector3 = door.get("interior", Vector3.ZERO) as Vector3
	var exterior: Vector3 = door.get("exterior", Vector3.ZERO) as Vector3
	var start: Vector3 = navmesh_path.get("startPosition", Vector3.ZERO) as Vector3
	var target: Vector3 = navmesh_path.get("targetPosition", Vector3.ZERO) as Vector3
	if portal_id.is_empty() or interior == Vector3.ZERO or exterior == Vector3.ZERO:
		return {"diagnosticOnly": true, "reason": "missing_door_probe_inputs"}
	var installed_links_by_id := {}
	for installed_link in installed_navigation_links:
		installed_links_by_id[String(installed_link.get("id", ""))] = installed_link
	var closest_point_inputs: Dictionary = {
		"route_start": start,
		"route_target": target,
		"door_interior": interior,
		"door_exterior": exterior
	}
	var support_seams: Array = source_facts.get("supportSeamLinks", []) as Array
	var interior_passages: Array = source_facts.get("interiorPassageLinks", []) as Array
	var vertical_links: Array = source_facts.get("verticalLinks", []) as Array
	var interior_support_id := String(door.get("interiorSupportId", ""))
	var seam_probes: Dictionary = {}
	for seam_value in support_seams:
		if not (seam_value is Dictionary):
			continue
		var seam_link: Dictionary = seam_value
		if String(seam_link.get("supportId", "")) != interior_support_id:
			continue
		var seam_id := String(seam_link.get("id", "support_seam"))
		var probe_link: Dictionary = seam_link
		var endpoint_source := "authored"
		if installed_links_by_id.has(seam_id):
			probe_link = installed_links_by_id.get(seam_id, {}) as Dictionary
			endpoint_source = "installed"
		var seam_start: Vector3 = probe_link.get("start", Vector3.ZERO) as Vector3
		var seam_end: Vector3 = probe_link.get("end", Vector3.ZERO) as Vector3
		if not seam_start.is_finite() or not seam_end.is_finite():
			continue
		closest_point_inputs["%s:start" % seam_id] = seam_start
		closest_point_inputs["%s:end" % seam_id] = seam_end
		seam_probes[seam_id] = {
			"endpointSource": endpoint_source,
			"authoredStart": seam_link.get("start", Vector3.INF),
			"authoredEnd": seam_link.get("end", Vector3.INF),
			"startToSeamEnd": navmesh_diagnostic_probe(navmesh_world, start, seam_end, portal_id),
			"startToSeamStart": navmesh_diagnostic_probe(navmesh_world, start, seam_start, portal_id),
			"throughSeam": navmesh_diagnostic_probe(navmesh_world, seam_start, seam_end, portal_id),
			"throughSeamReverse": navmesh_diagnostic_probe(navmesh_world, seam_end, seam_start, portal_id),
			"seamStartToInterior": navmesh_diagnostic_probe(navmesh_world, seam_start, interior, portal_id),
			"seamEndToInterior": navmesh_diagnostic_probe(navmesh_world, seam_end, interior, portal_id)
		}
	var passage_probes: Dictionary = {}
	for passage_value in interior_passages:
		if not (passage_value is Dictionary):
			continue
		var passage_link: Dictionary = passage_value
		var passage_id := String(passage_link.get("id", "interior_passage"))
		var probe_link: Dictionary = passage_link
		var endpoint_source := "authored"
		if installed_links_by_id.has(passage_id):
			probe_link = installed_links_by_id.get(passage_id, {}) as Dictionary
			endpoint_source = "installed"
		var passage_start: Vector3 = probe_link.get("start", Vector3.ZERO) as Vector3
		var passage_end: Vector3 = probe_link.get("end", Vector3.ZERO) as Vector3
		if not passage_start.is_finite() or not passage_end.is_finite():
			continue
		closest_point_inputs["%s:start" % passage_id] = passage_start
		closest_point_inputs["%s:end" % passage_id] = passage_end
		passage_probes[passage_id] = {
			"endpointSource": endpoint_source,
			"authoredStart": passage_link.get("start", Vector3.INF),
			"authoredEnd": passage_link.get("end", Vector3.INF),
			"homeToPassageStart": navmesh_diagnostic_probe(navmesh_world, start, passage_start, portal_id),
			"homeToPassageEnd": navmesh_diagnostic_probe(navmesh_world, start, passage_end, portal_id),
			"throughPassage": navmesh_diagnostic_probe(navmesh_world, passage_start, passage_end, portal_id),
			"throughPassageReverse": navmesh_diagnostic_probe(navmesh_world, passage_end, passage_start, portal_id),
			"passageEndToInterior": navmesh_diagnostic_probe(navmesh_world, passage_end, interior, portal_id),
			"passageStartToInterior": navmesh_diagnostic_probe(navmesh_world, passage_start, interior, portal_id)
		}
	var vertical_probes: Dictionary = {}
	for vertical_value in vertical_links:
		if not (vertical_value is Dictionary):
			continue
		var vertical_link: Dictionary = vertical_value
		var vertical_id := String(vertical_link.get("id", "vertical_link"))
		var probe_link: Dictionary = vertical_link
		var endpoint_source := "authored"
		if installed_links_by_id.has(vertical_id):
			probe_link = installed_links_by_id.get(vertical_id, {}) as Dictionary
			endpoint_source = "installed"
		var vertical_start: Vector3 = probe_link.get("start", Vector3.ZERO) as Vector3
		var vertical_end: Vector3 = probe_link.get("end", Vector3.ZERO) as Vector3
		if not vertical_start.is_finite() or not vertical_end.is_finite():
			continue
		closest_point_inputs["%s:start" % vertical_id] = vertical_start
		closest_point_inputs["%s:end" % vertical_id] = vertical_end
		vertical_probes[vertical_id] = {
			"endpointSource": endpoint_source,
			"authoredStart": vertical_link.get("start", Vector3.INF),
			"authoredEnd": vertical_link.get("end", Vector3.INF),
			"homeToVerticalStart": navmesh_diagnostic_probe(navmesh_world, start, vertical_start, portal_id),
			"homeToVerticalEnd": navmesh_diagnostic_probe(navmesh_world, start, vertical_end, portal_id),
			"throughVertical": navmesh_diagnostic_probe(navmesh_world, vertical_start, vertical_end, portal_id),
			"throughVerticalReverse": navmesh_diagnostic_probe(navmesh_world, vertical_end, vertical_start, portal_id),
			"verticalStartToInterior": navmesh_diagnostic_probe(navmesh_world, vertical_start, interior, portal_id),
			"verticalEndToInterior": navmesh_diagnostic_probe(navmesh_world, vertical_end, interior, portal_id)
		}
	var interior_passage_ids: Array[String] = []
	for passage_id_value in passage_probes.keys():
		interior_passage_ids.append(String(passage_id_value))
	interior_passage_ids.sort()
	return {
		"diagnosticOnly": true,
		"serverClosestPoints": navmesh_server_closest_points(navmesh_world, closest_point_inputs),
		"fullRouteServerEndpoints": navmesh_diagnostic_route(navmesh_world, start, target, false),
		"fullRouteDescriptorEndpoints": navmesh_diagnostic_route(navmesh_world, start, target, true),
		"homeToInterior": navmesh_diagnostic_probe(navmesh_world, start, interior, portal_id),
		"homeToInteriorWithoutPassageLinks": navmesh_diagnostic_probe_without_navigation_links(navmesh_world, start, interior, portal_id, interior_passage_ids),
		"supportSeams": seam_probes,
		"interiorPassages": passage_probes,
		"verticalLinks": vertical_probes,
		"throughDoor": navmesh_diagnostic_probe(navmesh_world, interior, exterior, portal_id),
		"exteriorToTarget": navmesh_diagnostic_probe(navmesh_world, exterior, target, portal_id)
	}


func navmesh_server_closest_points(navmesh_world, inputs: Dictionary) -> Dictionary:
	if navmesh_world == null or not navmesh_world.has_method("_closest_walkable_from_server"):
		return {"reason": "missing_server_closest_query"}
	var results: Dictionary = {}
	var labels: Array = inputs.keys()
	labels.sort()
	for label_value in labels:
		var label := String(label_value)
		var position_value = inputs.get(label, Vector3.INF)
		if not (position_value is Vector3) or not (position_value as Vector3).is_finite():
			continue
		var position: Vector3 = position_value as Vector3
		var closest_value = navmesh_world.call("_closest_walkable_from_server", position, 4.0)
		results[label] = {
			"inputPosition": position,
			"result": closest_value if closest_value is Dictionary else {"reason": "invalid_server_closest_result"}
		}
	return results


func navmesh_diagnostic_route(navmesh_world, start: Vector3, target: Vector3, prefer_descriptor_endpoint: bool) -> Dictionary:
	if navmesh_world == null or not navmesh_world.has_method("query_route"):
		return {"reason": "missing_navmesh_route_query"}
	var route_value = navmesh_world.call("query_route", start, target, {
		"kind": "scripted",
		"arrivalRadius": 1.0125,
		"maxSnapDistance": 1.2825,
		"startMaxSnapDistance": 1.2825,
		"targetMaxSnapDistance": 1.2825,
		"queryApi": "query_path",
		"preferDescriptorEndpoint": prefer_descriptor_endpoint
	})
	if not (route_value is Dictionary):
		return {"reason": "invalid_navmesh_route_result"}
	var route: Dictionary = route_value
	return {
		"preferDescriptorEndpoint": prefer_descriptor_endpoint,
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"pointCount": int(route.get("pointCount", 0)),
		"queryApi": String(route.get("queryApi", "")),
		"startPosition": route.get("startPosition", Vector3.INF),
		"targetPosition": route.get("targetPosition", Vector3.INF),
		"startWalkable": route.get("startWalkable", {}),
		"targetWalkable": route.get("targetWalkable", {}),
		"path": route.get("path", []),
		"details": route.get("details", {})
	}


func navmesh_diagnostic_probe(navmesh_world, start: Vector3, target: Vector3, portal_id: String) -> Dictionary:
	if navmesh_world == null or not navmesh_world.has_method("_query_path_points"):
		return {"reason": "missing_raw_navmesh_query"}
	var points_value = navmesh_world.call("_query_path_points", start, target, {"queryApi": "query_path"})
	var points: Array = points_value if points_value is Array else []
	var door_actions_value = navmesh_world.call("_door_actions_for_path", points, {}) if navmesh_world.has_method("_door_actions_for_path") else {}
	var door_actions: Dictionary = door_actions_value as Dictionary if door_actions_value is Dictionary else {}
	var matched_portal := false
	for action_value in door_actions.values():
		if action_value is Dictionary and String((action_value as Dictionary).get("portalId", "")) == portal_id:
			matched_portal = true
	var endpoint := Vector3.INF
	if not points.is_empty() and points[points.size() - 1] is Vector3:
		endpoint = points[points.size() - 1] as Vector3
	return {
		"start": start,
		"target": target,
		"pointCount": points.size(),
		"path": points,
		"endpoint": endpoint,
		"endpointDistance": endpoint.distance_to(target),
		"usesExpectedDoorPortal": matched_portal
	}


func navmesh_diagnostic_probe_without_navigation_links(navmesh_world, start: Vector3, target: Vector3, portal_id: String, link_ids: Array[String]) -> Dictionary:
	if navmesh_world == null or not navmesh_world.has_method("diagnostic_query_path_without_navigation_links"):
		return {"reason": "missing_navigation_link_diagnostic"}
	var points_value = navmesh_world.call("diagnostic_query_path_without_navigation_links", start, target, link_ids, {"queryApi": "query_path"})
	var points: Array = points_value if points_value is Array else []
	var door_actions_value = navmesh_world.call("_door_actions_for_path", points, {}) if navmesh_world.has_method("_door_actions_for_path") else {}
	var door_actions: Dictionary = door_actions_value as Dictionary if door_actions_value is Dictionary else {}
	var matched_portal := false
	for action_value in door_actions.values():
		if action_value is Dictionary and String((action_value as Dictionary).get("portalId", "")) == portal_id:
			matched_portal = true
	var endpoint := Vector3.INF
	if not points.is_empty() and points[points.size() - 1] is Vector3:
		endpoint = points[points.size() - 1] as Vector3
	return {
		"diagnosticOnly": true,
		"disabledNavigationLinkIds": link_ids,
		"start": start,
		"target": target,
		"pointCount": points.size(),
		"path": points,
		"endpoint": endpoint,
		"endpointDistance": endpoint.distance_to(target),
		"usesExpectedDoorPortal": matched_portal
	}


func navmesh_region_context(regions: Dictionary, region_id: String, surface_id: String, corridor := AABB()) -> Dictionary:
	if region_id.is_empty() or not regions.has(region_id):
		return {"regionId": region_id, "reason": "region_not_registered"}
	var region: Dictionary = regions.get(region_id, {}) as Dictionary
	var matching_surface := {}
	var nearby_surfaces: Array[Dictionary] = []
	for surface_value in region.get("walkableSurfaces", []) as Array:
		if not (surface_value is Dictionary):
			continue
		var surface: Dictionary = surface_value as Dictionary
		if String(surface.get("id", "")) == surface_id:
			matching_surface = surface.duplicate(true)
		if corridor.size.length_squared() > 0.0 and navmesh_debug_surface_bounds(surface).intersects(corridor):
			nearby_surfaces.append(surface.duplicate(true))
	nearby_surfaces.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
	return {
		"regionId": region_id,
		"loaded": bool(region.get("loaded", false)),
		"bounds": region.get("bounds", {}),
		"installMetrics": region.get("installMetrics", {}),
		"surface": matching_surface,
		"nearbySurfaces": nearby_surfaces,
		"navigationLinks": region.get("navigationLinks", [])
	}


func navmesh_debug_surface_bounds(surface: Dictionary) -> AABB:
	var has_point := false
	var result := AABB()
	for point_value in surface.get("polygon", []) as Array:
		var point := navmesh_debug_vector3(point_value)
		if not point.is_finite():
			continue
		result = AABB(point, Vector3.ZERO) if not has_point else result.expand(point)
		has_point = true
	if has_point:
		return result
	var center := navmesh_debug_vector3(surface.get("center", Vector3.INF))
	var size := navmesh_debug_vector3(surface.get("size", Vector3.ZERO))
	if not center.is_finite():
		return AABB()
	return AABB(center - size * 0.5, size)


func navmesh_debug_vector3(value) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Array and (value as Array).size() == 3:
		var values: Array = value as Array
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3.INF


func residence_citizen_for_actor(actor_id: String) -> Dictionary:
	for citizen_value in residence_manifest.get("citizens", []) as Array:
		if citizen_value is Dictionary and String((citizen_value as Dictionary).get("id", "")) == actor_id:
			return (citizen_value as Dictionary).duplicate(true)
	return {}


func residence_record_for_id(residence_id: String) -> Dictionary:
	for residence_value in residence_manifest.get("residences", []) as Array:
		if residence_value is Dictionary and String((residence_value as Dictionary).get("residenceId", "")) == residence_id:
			return (residence_value as Dictionary).duplicate(true)
	return {}


func nearby_observation_camera_position(body: CharacterBody3D, target: Vector3, preferred_position := Vector3.INF) -> Vector3:
	var space_state := body.get_world_3d().direct_space_state
	var candidates: Array[Vector3] = []
	if preferred_position.is_finite():
		candidates.append(preferred_position)
	for offset in [
		Vector3(2.5, 1.45, 2.5),
		Vector3(-2.5, 1.45, 2.5),
		Vector3(2.5, 1.45, -2.5),
		Vector3(-2.5, 1.45, -2.5),
		Vector3(0.0, 1.65, 3.3),
		Vector3(3.3, 1.65, 0.0),
		Vector3(0.0, 1.65, -3.3),
		Vector3(-3.3, 1.65, 0.0)
	]:
		candidates.append(target + offset)
	for candidate in candidates:
		if not observation_camera_position_is_clear(space_state, body, candidate):
			continue
		var query := PhysicsRayQueryParameters3D.create(candidate, target)
		query.exclude = [body.get_rid()]
		if space_state.intersect_ray(query).is_empty():
			return candidate
	for candidate in candidates:
		if observation_camera_position_is_clear(space_state, body, candidate):
			return candidate
	return target + Vector3(0.0, 1.7, 3.3)


func observation_camera_position_is_clear(space_state, body: CharacterBody3D, candidate: Vector3) -> bool:
	var shape := SphereShape3D.new()
	shape.radius = 0.18
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, candidate)
	query.exclude = [body.get_rid()]
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return space_state.intersect_shape(query, 1).is_empty()


func citizen_body_for_id(actor_id: String) -> CharacterBody3D:
	for citizen_entry in citizens:
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		if String(manifest.get("id", "")) == actor_id:
			var body := citizen_entry.get("body") as CharacterBody3D
			if body != null and is_instance_valid(body):
				return body
	return null


func route_failure_capture_slug(reason: String) -> String:
	var result := reason.to_lower()
	for character in [" ", "/", "\\", ":"]:
		result = result.replace(character, "_")
	return result if not result.is_empty() else "unknown"


func acceptance_summary(final_snapshot: Dictionary, day_snapshot: Dictionary = {}, order_admissions: Dictionary = {}) -> Dictionary:
	var records: Array = final_snapshot.get("citizens", []) as Array
	var inside_count := 0
	var blocked_count := 0
	for record_value in records:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value as Dictionary
		if bool(record.get("physicallyInsideStrictInterior", false)):
			inside_count += 1
		if String(record.get("routeStatus", "")) in ["unreachable_static", "invalid_goal"]:
			blocked_count += 1
	var day_records: Array = day_snapshot.get("citizens", []) as Array
	var day_outside_count := 0
	var day_blocked_count := 0
	for record_value in day_records:
		if not (record_value is Dictionary):
			continue
		var day_record: Dictionary = record_value as Dictionary
		if not bool(day_record.get("physicallyInsideStrictInterior", false)):
			day_outside_count += 1
		if String(day_record.get("routeStatus", "")) in ["unreachable_static", "invalid_goal"]:
			day_blocked_count += 1
	var expected_count := (residence_manifest.get("citizens", []) as Array).size()
	var day_admission: Dictionary = order_admissions.get("day", {}) if order_admissions.get("day", {}) is Dictionary else {}
	var night_admission: Dictionary = order_admissions.get("night", {}) if order_admissions.get("night", {}) is Dictionary else {}
	var orders_admitted := bool(day_admission.get("timely", false)) and bool(night_admission.get("timely", false))
	var route_outcome_passed := expected_count > 0 and records.size() == expected_count and inside_count == expected_count and blocked_count == 0 and day_records.size() == expected_count and day_outside_count == expected_count and day_blocked_count == 0
	var crowd_stress_passed := bool(crowd_stress_result.get("passed", false))
	var passed := route_outcome_passed and orders_admitted and crowd_stress_passed
	var reason := ""
	if not orders_admitted:
		reason = "Citadel civic orders were not all accepted promptly through the public NPC order contract"
	elif not crowd_stress_passed:
		reason = "Citadel production citizens did not complete the headed bidirectional crowd crossing without overlap"
	elif not route_outcome_passed:
		reason = "Citadel citizens did not all leave through the real home/door boundary by day and return to their strict interior bounds by night"
	return {
		"passed": passed,
		"expectedCitizenCount": expected_count,
		"observedCitizenCount": records.size(),
		"strictInteriorCount": inside_count,
		"blockedRouteCount": blocked_count,
		"dayOutsideCount": day_outside_count,
		"dayBlockedRouteCount": day_blocked_count,
		"crowdStress": crowd_stress_result.duplicate(true),
		"orderAdmissions": {
			"day": day_admission,
			"night": night_admission
		},
		"reason": reason
	}


func prepare_profile_shutdown() -> void:
	# The profile has already written its report. Stop the child Main scene before
	# the fixture asks SceneTree to quit, avoiding a final Main frame that can
	# observe a terrain runtime already being released during application teardown.
	set_process(false)
	set_physics_process(false)
	if main != null and is_instance_valid(main):
		main.set_process(false)
		main.set_physics_process(false)
		main.queue_free()
		await get_tree().process_frame
	main = null


func profile_phase(phase_name: String, duration_seconds: float) -> void:
	profile_begin_stage("steady_%s" % phase_name)
	var started_usec := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - started_usec) / 1000000.0 < duration_seconds:
		profile_status_elapsed += get_process_delta_time()
		if profile_status_elapsed >= 0.50:
			profile_status_elapsed = 0.0
			var elapsed := float(Time.get_ticks_usec() - started_usec) / 1000000.0
			write_profile_progress("steadyPhase=%s elapsed=%.2f" % [phase_name, elapsed])
		await get_tree().process_frame
	var monitor = main.get("runtime_perf_monitor") if main != null else null
	var summary: Dictionary = monitor.call("summary") if monitor != null and monitor.has_method("summary") else {}
	profile_phase_samples.append({
		"phase": phase_name,
		"durationSeconds": duration_seconds,
		"runtime": summary,
		"performanceEvidence": runtime_performance_evidence(summary),
		"activeCitizenCount": citizens.size(),
		"sceneNodeCount": count_scene_nodes(get_tree().root)
	})
	profile_end_stage("steady_%s" % phase_name, {
		"activeCitizenCount": citizens.size(),
		"sceneNodeCount": count_scene_nodes(get_tree().root)
	})


func write_profile_report(status: String, failure_reason := "") -> void:
	if profile_report_path.is_empty():
		return
	var monitor = main.get("runtime_perf_monitor") if main != null else null
	var summary: Dictionary = monitor.call("summary") if monitor != null and monitor.has_method("summary") else {}
	var recipe: Dictionary = blueprint.recipe if blueprint != null else {}
	var report := {
		"runner": "citadel_life_playtest",
		"runToken": profile_run_token,
		"status": status,
		"passed": status != "failed" and (not acceptance_mode or bool(acceptance_result.get("passed", false))),
		"failureCount": 1 if status == "failed" else 0,
		"evidenceLevel": "integration",
		"scope": "Headed Citadel Life loading and steady-state performance diagnostic. It measures the real fixture's production Main scene, terrain collision, published building records, doors, NPC bodies and clock, but is not a player gameplay acceptance claim.",
		"seed": selected_seed,
		"citadelScale": selected_citadel_scale,
		"citadelSpan": maxf(float(recipe.get("width", 0.0)), float(recipe.get("depth", 0.0))),
		"terrainSite": fixture_site.duplicate(true),
		"loadDurationMs": float((profile_load_completed_usec if profile_load_completed_usec > 0 else Time.get_ticks_usec()) - profile_started_usec) / 1000.0,
		"loadingStages": profile_stages.duplicate(true),
		"steadyStateSamples": profile_phase_samples.duplicate(true),
		"acceptance": acceptance_result.duplicate(true),
		"acceptanceConfiguration": {
			"daySeconds": acceptance_day_seconds,
			"nightSeconds": acceptance_night_seconds,
			"defaultDaySeconds": DEFAULT_ACCEPTANCE_DAY_SECONDS,
			"defaultNightSeconds": DEFAULT_ACCEPTANCE_NIGHT_SECONDS
		},
		"failureDiagnostics": acceptance_failure_diagnostics.duplicate(true),
		"postAcceptanceNavigationAudit": acceptance_post_navigation_audit.duplicate(true),
		"linkDiagnostics": link_diagnostics.duplicate(true),
		"timeline": acceptance_timeline.duplicate(true),
		"crowdPhysicsEvidence": crowd_physics_evidence.duplicate(true),
		"crowdStress": crowd_stress_result.duplicate(true),
		"runtime": summary,
		"sourceCounts": {
			"blueprintParts": blueprint.parts.size() if blueprint != null else 0,
			"furnishingParts": furnishing_plan.parts.size() if furnishing_plan != null else 0,
			"districtCount": district_catalog.size(),
			"activeDistrictCount": active_district_ids.size(),
			"residentManifestCount": (residence_manifest.get("citizens", []) as Array).size(),
			"activeCitizenCount": citizens.size(),
			"sceneNodeCount": count_scene_nodes(get_tree().root)
		},
		"civicOrderQueue": civic_order_metrics.duplicate(true),
		"civicOrderBatches": civic_order_batches.duplicate(true),
		"citizenSpawnQueue": citizen_spawn_metrics.duplicate(true),
		"buildingNavigation": building_navigation_summary(),
		"buildingPublication": building_publication_summary(),
		"furnishingPublication": furnishing_publication_summary(),
		"captures": visual_captures.duplicate(true),
		"failureReason": failure_reason,
		"finishedUtc": Time.get_datetime_string_from_system(true, true)
	}
	write_text_file(profile_report_path, JSON.stringify(report, "\t"))
	write_profile_progress("status=%s loadDurationMs=%.3f" % [status, float(report.get("loadDurationMs", 0.0))])


func building_navigation_summary() -> Dictionary:
	var result := {
		"registeredManifestCount": registered_building_navigation_ids.size(),
		"supportCount": 0,
		"verticalLinkCount": 0,
		"supportSeamLinkCount": 0,
		"interiorPassageLinkCount": 0,
		"navigationBackend": {}
	}
	if npc_system == null:
		return result
	var manifests: Array = npc_system.call("building_navigation_manifest_snapshot") if npc_system.has_method("building_navigation_manifest_snapshot") else []
	for manifest_value in manifests:
		if not (manifest_value is Dictionary):
			continue
		var manifest: Dictionary = manifest_value
		result["supportCount"] = int(result.get("supportCount", 0)) + int(manifest.get("supportCount", 0))
		result["verticalLinkCount"] = int(result.get("verticalLinkCount", 0)) + int(manifest.get("verticalLinkCount", 0))
		result["supportSeamLinkCount"] = int(result.get("supportSeamLinkCount", 0)) + int(manifest.get("supportSeamLinkCount", 0))
		result["interiorPassageLinkCount"] = int(result.get("interiorPassageLinkCount", 0)) + int(manifest.get("interiorPassageLinkCount", 0))
	var autonomy = npc_system.get("autonomy_system")
	if autonomy != null and autonomy.has_method("navigation_backend_summary"):
		result["navigationBackend"] = autonomy.call("navigation_backend_summary")
	return result


func runtime_performance_evidence(summary: Dictionary) -> Dictionary:
	var section_maxima: Dictionary = summary.get("sectionMaxMs", {}) as Dictionary
	var ranked: Array[Dictionary] = []
	for key_value in section_maxima.keys():
		var key := String(key_value)
		if key.begins_with("citadel_load_"):
			continue
		ranked.append({"section": key, "maxMs": float(section_maxima.get(key, 0.0))})
	ranked.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return float(left.get("maxMs", 0.0)) > float(right.get("maxMs", 0.0))
	)
	return {
		"worstFrameMs": float(summary.get("frameMaxMs", 0.0)),
		"p50Ms": float(summary.get("frameP50Ms", 0.0)),
		"p95Ms": float(summary.get("frameP95Ms", 0.0)),
		"p99Ms": float(summary.get("frameP99Ms", 0.0)),
		"lastSpikeReason": String(summary.get("lastSpikeReason", "")),
		"lastSpikeTopSections": (summary.get("lastSpikeTopSections", []) as Array).duplicate(true),
		"rankedTopSections": ranked.slice(0, mini(5, ranked.size()))
	}


func write_profile_progress(message: String) -> void:
	if profile_progress_path.is_empty():
		return
	write_text_file(profile_progress_path, "%s\n" % message)


func write_text_file(path: String, content: String) -> void:
	if path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(content)
	file.close()


func count_scene_nodes(node: Node) -> int:
	if node == null:
		return 0
	var count := 1
	for child in node.get_children():
		count += count_scene_nodes(child)
	return count

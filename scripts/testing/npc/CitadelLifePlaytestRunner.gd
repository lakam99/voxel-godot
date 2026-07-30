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
const CIVIC_ORDERS_PER_FRAME := 1
const TERRAIN_SITE_SAMPLE_GRID := 8
const TERRAIN_SITE_READINESS_MAX_FRAMES := 720
const TERRAIN_CHUNK_SIZE := 28
const INITIAL_RELEVANT_DISTRICTS := 3
const DISTRICT_PREFETCH_INTERVAL := 0.40
const CITIZEN_SPAWNS_PER_FRAME := 1
const CITIZEN_SPAWN_MAX_ATTEMPTS := 16

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
var profile_status_elapsed := 0.0
var status_elapsed := 0.0


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


func bootstrap() -> void:
	profile_started_usec = Time.get_ticks_usec()
	profile_stages.clear()
	profile_phase_samples.clear()
	visual_captures.clear()
	acceptance_timeline.clear()
	acceptance_result.clear()
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
		if acceptance_mode:
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
	move_player_for_streaming(span)
	if main.has_method("update_chunks"):
		main.call("update_chunks", false)
	var terrain_readiness := await wait_for_fixture_terrain_readiness(span)
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
	furnishing_plan = CastleFurnishingPlannerScript.build(blueprint, selected_seed * 7919 + 37)
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
	profile_end_stage("navigation_publication")

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


func core_blueprint_slice(source):
	var core = BuildingBlueprintScript.new("%s.core" % String(source.id), int(source.seed), String(source.style))
	core.set_recipe(source.recipe)
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
		district_blueprint.set_recipe(source.recipe)
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
	register_published_doors()
	if npc_system != null and npc_system.has_method("flush_navigation_change_bus"):
		npc_system.call("flush_navigation_change_bus")
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


func replace_civic_order_queue(staged: Array[Dictionary], phase: String) -> void:
	# The fixture owns only *when* generic public orders are submitted.  It never
	# touches route state, movement, doors, traffic, or navigation internals.  A
	# replacement phase makes every not-yet-submitted request explicitly
	# superseded instead of losing it inside a same-frame route burst.
	civic_order_generation += 1
	civic_order_metrics["superseded"] = int(civic_order_metrics.get("superseded", 0)) + civic_order_queue.size()
	civic_order_queue.clear()
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
		if body == null or not is_instance_valid(body):
			civic_order_metrics["discarded"] = int(civic_order_metrics.get("discarded", 0)) + 1
			continue
		var result: Dictionary = {}
		if String(request.get("kind", "")) == "go_home":
			result = npc_system.call("order_go_home", body, String(request.get("reason", "citadel_life_world_clock_return"))) as Dictionary
		else:
			result = npc_system.call(
				"order_go_to",
				body,
				request.get("target", body.global_position) as Vector3,
				String(request.get("reason", "citadel_life_civic_day")),
				float(request.get("arrivalRadius", CELL * 1.10))
			) as Dictionary
		if String(result.get("state", "")) == "FAILED_TARGET_GONE":
			civic_order_metrics["discarded"] = int(civic_order_metrics.get("discarded", 0)) + 1
			continue
		submitted += 1
		civic_order_metrics["submitted"] = int(civic_order_metrics.get("submitted", 0)) + 1
	civic_order_metrics["queued"] = civic_order_queue.size()


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
	if observed_world_phase == "day":
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


func move_player_for_streaming(span: float) -> void:
	if player == null:
		return
	player.global_position = fixture_origin + Vector3(0.0, 0.15, -span * 0.5 - 5.0)
	player.velocity = Vector3.ZERO


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
	if runtime.has_method("configure_startup_collision_bounds"):
		# Reuse the terrain authority's ordinary startup-viewer contract so the
		# selected site receives visual and collision publication together.
		runtime.call("configure_startup_collision_bounds", required)
	for frame in range(TERRAIN_SITE_READINESS_MAX_FRAMES):
		if bool(runtime.call("gameplay_chunks_published", required)):
			return {"ready": true, "waitedFrames": frame, "requiredChunkCount": required.size()}
		if main.has_method("update_chunks"):
			main.call("update_chunks", false)
		if frame % 45 == 0:
			set_loading("Publishing real terrain and collision (%d/%d chunks)" % [int(runtime.call("published_gameplay_chunk_count", required)), required.size()])
		await get_tree().physics_frame
	return {
		"ready": false,
		"reason": "terrain_publication_timeout",
		"waitedFrames": TERRAIN_SITE_READINESS_MAX_FRAMES,
		"requiredChunkCount": required.size(),
		"publishedChunkCount": int(runtime.call("published_gameplay_chunk_count", required))
	}


func fixture_terrain_chunk_keys(span: float) -> Array[Vector2i]:
	var center_chunk := Vector2i(floori(float(fixture_center.x) / float(TERRAIN_CHUNK_SIZE)), floori(float(fixture_center.y) / float(TERRAIN_CHUNK_SIZE)))
	var radius := maxi(1, ceili((span / CELL * 0.5 + 4.0) / float(TERRAIN_CHUNK_SIZE)))
	var keys: Array[Vector2i] = []
	for z in range(center_chunk.y - radius, center_chunk.y + radius + 1):
		for x in range(center_chunk.x - radius, center_chunk.x + radius + 1):
			keys.append(Vector2i(x, z))
	return keys


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
	if observed_world_phase == "day":
		civic_order_elapsed += delta
		if civic_order_elapsed >= 14.0:
			civic_order_elapsed = 0.0
			issue_civic_orders()
	drain_civic_order_queue()
	update_biped_presenters(delta)
	status_elapsed += delta
	if status_elapsed >= 0.25:
		status_elapsed = 0.0
		update_status()


func update_biped_presenters(delta: float) -> void:
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		var locomotion = citizen_entry.get("locomotion")
		if body == null or not is_instance_valid(body) or locomotion == null or not is_instance_valid(locomotion):
			continue
		locomotion.apply_velocity(body.velocity, delta)



func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_R:
			selected_seed += 1
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
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		return
	var path: String = profile_screenshot_dir.path_join("%s.png" % capture_id)
	var save_error: int = image.save_png(path)
	if save_error == OK:
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
	status_label.text = "CITADEL LIFE  |  %s\nseed %d  ?  %.2fx citadel  ?  %d/%d districts published (%s)  ?  %d citizens / %d furnished beds  ?  %d strictly indoors  ?  player %s\n[WASD] move  [F6] set daylight  [F7] set night  [R] next seed  [Esc] release mouse\nWorld clock drives the citizen phase. Production NPC bodies, real collision, registered door portals and ordinary public civic/home orders. Route states: %s  ?  staged orders: %d" % [phase_name, selected_seed, selected_citadel_scale, active_district_ids.size(), district_catalog.size(), district_state, citizens.size(), (residence_manifest.get("citizens", []) as Array).size(), inside_count, "interactive" if player_ready else "not-ready", JSON.stringify(route_states), civic_order_queue.size()]


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
	# for citizens. The fixture never supplies a route, opens a door, moves an NPC,
	# or marks an arrival; positions and screenshots are observations afterward.
	acceptance_timeline.clear()
	acceptance_result.clear()
	var monitor = main.get("runtime_perf_monitor") if main != null else null
	if monitor != null and monitor.has_method("reset"):
		monitor.call("reset")
	set_world_display_hour(11.0)
	refresh_world_phase(true)
	await acceptance_observation_phase("day_civic", 12.0, "day_civic")
	var day_snapshot: Dictionary = citizen_observation_snapshot("day_civic_complete")
	acceptance_timeline.append(day_snapshot)
	set_world_display_hour(19.0)
	refresh_world_phase(true)
	await acceptance_observation_phase("night_home", 24.0, "night_home")
	var final_snapshot: Dictionary = citizen_observation_snapshot("night_home_complete")
	acceptance_timeline.append(final_snapshot)
	acceptance_result = acceptance_summary(final_snapshot, day_snapshot)
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
			"physicallyInsideStrictInterior": physically_inside
		})
	return {
		"label": label,
		"worldPhase": observed_world_phase,
		"clockTime": main.call("clock_time_text") if main != null and main.has_method("clock_time_text") else "",
		"citizens": records
	}


func acceptance_summary(final_snapshot: Dictionary, day_snapshot: Dictionary = {}) -> Dictionary:
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
	var passed := expected_count > 0 and records.size() == expected_count and inside_count == expected_count and blocked_count == 0 and day_records.size() == expected_count and day_outside_count == expected_count and day_blocked_count == 0
	return {
		"passed": passed,
		"expectedCitizenCount": expected_count,
		"observedCitizenCount": records.size(),
		"strictInteriorCount": inside_count,
		"blockedRouteCount": blocked_count,
		"dayOutsideCount": day_outside_count,
		"dayBlockedRouteCount": day_blocked_count,
		"reason": "" if passed else "Citadel citizens did not all leave through the real home/door boundary by day and return to their strict interior bounds by night"
	}


func prepare_profile_shutdown() -> void:
	# The profile has already written its report. Stop the child Main scene before
	# the fixture asks SceneTree to quit, avoiding a final Main frame that can
	# observe a terrain runtime already being released during application teardown.
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
		"timeline": acceptance_timeline.duplicate(true),
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

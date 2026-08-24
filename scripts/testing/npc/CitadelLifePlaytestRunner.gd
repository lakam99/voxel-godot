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
const CitadelUrbanPocComposerScript := preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const BuildingInteriorProgramScript := preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const BuildingCollisionProbeScript := preload("res://scripts/buildings/BuildingCollisionProbe.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const PlaytestSurvivalPolicyScript := preload("res://scripts/testing/PlaytestSurvivalPolicy.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const HomeInteriorServiceScript := preload("res://scripts/npc_ai/behavior/HomeInteriorService.gd")
const CitadelSiteManifestPlannerScript := preload("res://scripts/world/CitadelSiteManifestPlanner.gd")

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
const DAY_ROUTE_COMMITMENT_SECONDS := 60.0
const DAY_DEPARTURE_MIN_PROGRESS_MPS := 0.55
const DAY_DEPARTURE_ROUTE_OVERHEAD_SECONDS := 12.0
const DAY_DEPARTURE_MAX_SECONDS := 120.0
const NIGHT_HOME_ROUTE_SETTLE_FRAMES := 12
const NIGHT_HOME_MIN_PROGRESS_MPS := 0.55
const NIGHT_HOME_ROUTE_OVERHEAD_SECONDS := 10.0
const NIGHT_HOME_MAX_SECONDS := 120.0
const NIGHT_HOME_PROGRESS_GRACE_SECONDS := 8.0
const NIGHT_HOME_PROGRESS_DELTA := 0.12
const DOOR_LIFECYCLE_SAMPLE_INTERVAL_FRAMES := 6
const ACCEPTANCE_SNAPSHOT_INTERVAL_SECONDS := 3.0
const NIGHT_CHECKPOINT_INTERVAL_SECONDS := 15
const DOOR_CLEARANCE_ARRIVAL_RADIUS := 0.32
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
const CROWD_FIXTURE_CONTACT_BAND := 0.16
const CROWD_FIXTURE_SPAWN_LIFT := 0.16
const SURFACE_CONTINUITY_SEAM_HALF_BAND := 0.90
const SURFACE_CONTINUITY_SEAM_LATERAL_LIMIT := 0.55
const SURFACE_CONTINUITY_SEAM_ARM_DISTANCE := 0.12
const SURFACE_CONTINUITY_TIMELINE_INTERVAL_FRAMES := 6
const ACCEPTANCE_ORDER_ADMISSION_TIMEOUT_MS := 8000.0
const ACCEPTANCE_ORDER_ADMISSION_MAX_MS := 2000.0
const ACCEPTANCE_ORDER_ADMISSION_MAX_PROCESS_FRAMES := 120
const PRODUCTION_INPUT_READY_MAX_FRAMES := 7200

var main: Node3D
var player: CharacterBody3D
var npc_system: Node
var citadel_root: Node3D
var furnishing_root: Node3D
var living_tree_root: Node3D
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
var living_tree_records: Array[Dictionary] = []
var generated_living_tree_count := 0
var keep_entry_collision_evidence: Dictionary = {}
var keep_entry_player_sweep_evidence: Dictionary = {}
var raised_route_transition_handoff_evidence: Dictionary = {}
var raised_route_junction_traversal_evidence: Dictionary = {}
var raised_route_junction_captures: Array[Dictionary] = []
var raised_route_roadbed_evidence: Dictionary = {}
var raised_route_collision_negative_controls: Dictionary = {}
var residence_foundation_support_evidence: Dictionary = {}
var walkable_surface_collision_evidence: Dictionary = {}
var fixture_origin := Vector3.ZERO
var fixture_center := Vector2i.ZERO
var fixture_level := 0.0
var fixture_site: Dictionary = {}
var fixture_site_search_diagnostics: Dictionary = {}
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
var fixture_failure_details := {}
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
var acceptance_door_lifecycle: Dictionary = {}
var acceptance_day_door_lifecycle: Dictionary = {}
var acceptance_door_lifecycle_summary: Dictionary = {}
var acceptance_night_progress: Dictionary = {}
var acceptance_day_route_commitment: Dictionary = {}
var acceptance_day_generation := -1
var acceptance_day_started_physics_frame := -1
var acceptance_day_started_msec := 0
var acceptance_night_started_msec := 0
var acceptance_door_lifecycle_capture_ids := {}
var acceptance_day_seconds := DEFAULT_ACCEPTANCE_DAY_SECONDS
var acceptance_night_seconds := DEFAULT_ACCEPTANCE_NIGHT_SECONDS
var link_diagnostics_mode := false
var link_diagnostics: Array[Dictionary] = []
var surface_continuity_acceptance_mode := false
var surface_continuity_acceptance_result: Dictionary = {}
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
		elif argument == "--surface-continuity-acceptance":
			profile_mode = true
			surface_continuity_acceptance_mode = true


func bootstrap() -> void:
	profile_started_usec = Time.get_ticks_usec()
	profile_stages.clear()
	profile_phase_samples.clear()
	visual_captures.clear()
	acceptance_timeline.clear()
	acceptance_result.clear()
	acceptance_door_lifecycle.clear()
	acceptance_day_door_lifecycle.clear()
	acceptance_door_lifecycle_summary.clear()
	acceptance_night_progress.clear()
	acceptance_day_route_commitment.clear()
	acceptance_day_generation = -1
	acceptance_day_started_physics_frame = -1
	acceptance_door_lifecycle_capture_ids.clear()
	crowd_stress_result.clear()
	acceptance_failure_diagnostics.clear()
	acceptance_post_navigation_audit.clear()
	acceptance_order_admissions.clear()
	acceptance_door_lifecycle.clear()
	acceptance_day_door_lifecycle.clear()
	acceptance_door_lifecycle_summary.clear()
	acceptance_night_progress.clear()
	link_diagnostics.clear()
	surface_continuity_acceptance_result.clear()
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
	if profile_mode and not rebuilding and main != null and (link_diagnostics_mode or surface_continuity_acceptance_mode or not citizens.is_empty()):
		var diagnostics_passed := true
		if surface_continuity_acceptance_mode:
			var publication_probe := collect_citadel_surface_transition_publication_probe()
			link_diagnostics.append(publication_probe)
			if bool(publication_probe.get("passed", false)):
				var materialization := await materialize_surface_continuity_acceptance_actors(publication_probe)
				if bool(materialization.get("passed", false)):
					await run_surface_continuity_actor_acceptance(publication_probe)
				else:
					surface_continuity_acceptance_result = materialization
			else:
				surface_continuity_acceptance_result = {"passed": false, "reason": String(publication_probe.get("reason", "surface_continuity_publication_failed"))}
			diagnostics_passed = bool(surface_continuity_acceptance_result.get("passed", false))
			write_profile_report("completed" if diagnostics_passed else "failed", String(surface_continuity_acceptance_result.get("reason", "surface_continuity_actor_acceptance_failed")))
		elif link_diagnostics_mode:
			collect_manor_stair_link_diagnostics()
			var publication_probe := collect_citadel_surface_transition_publication_probe()
			diagnostics_passed = bool(publication_probe.get("passed", false))
			link_diagnostics.append(publication_probe)
			write_profile_report("completed" if diagnostics_passed else "failed", String(publication_probe.get("reason", "citadel_surface_transition_publication_probe_failed")))
		elif acceptance_mode:
			await run_citadel_life_acceptance()
		else:
			await run_profile_observation()
		await prepare_profile_shutdown()
		get_tree().quit(0 if diagnostics_passed else 1)


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
	fixture_failure_details = {}
	set_loading("Locating a seeded Citadel in the ordinary world")
	var structure_system = main.get("structure_system") if main != null else null
	if structure_system == null or not structure_system.has_method("citadel_runtime_record"):
		fail_fixture_loading("The ordinary structure authority is unavailable")
		return
	fixture_site = nearest_normal_world_citadel_manifest()
	if fixture_site.is_empty():
		fail_fixture_loading("No deterministic Citadel manifest was found in the search window", fixture_site_search_diagnostics)
		return
	fixture_center = fixture_site.get("center", Vector2i.ZERO) as Vector2i
	fixture_level = float(fixture_site.get("level", WATER_LEVEL + 3.0))
	fixture_origin = Vector3(float(fixture_center.x) * CELL, fixture_level, float(fixture_center.y) * CELL)
	player.global_position = fixture_origin + Vector3(0.0, 3.0, -float(int(fixture_site.get("radius", 76))) * CELL)
	set_loading("Streaming the ordinary Citadel structure, collision and navigation")
	var runtime_record := {}
	var failed_publication_state := {}
	for _frame in range(14400):
		structure_system.call("update_around_budgeted", fixture_center, true)
		runtime_record = structure_system.call("citadel_runtime_record", String(fixture_site.get("id", "")))
		if not runtime_record.is_empty():
			break
		var publication_states: Array = structure_system.call("citadel_publication_snapshot") as Array
		var fixture_publication_state := {}
		for state_value in publication_states:
			var state: Dictionary = state_value as Dictionary if state_value is Dictionary else {}
			var state_manifest: Dictionary = state.get("manifest", {}) if state.get("manifest", {}) is Dictionary else {}
			if String(state_manifest.get("id", "")) != String(fixture_site.get("id", "")):
				continue
			fixture_publication_state = state
			if String(state.get("status", "")) == "failed":
				failed_publication_state = state.duplicate(true)
			break
		if _frame % 120 == 0 and not fixture_publication_state.is_empty():
			var last_failure: Dictionary = fixture_publication_state.get("lastRegistrationFailure", {}) as Dictionary
			var failure_details: Dictionary = last_failure.get("details", {}) as Dictionary
			var map_readiness: Dictionary = failure_details.get("mapReadiness", {}) as Dictionary
			var failed_proof_summary := {}
			for proof_value in failure_details.get("tileProofs", failure_details.get("proofs", [])) as Array:
				if not (proof_value is Dictionary) or bool((proof_value as Dictionary).get("passed", false)):
					continue
				var proof: Dictionary = proof_value
				failed_proof_summary = {
					"portalId": String(proof.get("portalId", "")),
					"descriptor": not (proof.get("descriptorLink", {}) as Dictionary).is_empty(),
					"installedLinkCount": (proof.get("installedLinks", []) as Array).size(),
					"supportMatch": bool(proof.get("supportProvenanceMatch", false)),
					"sourcePortalReady": bool(proof.get("sourcePortalReady", false)),
					"publishedAfterInstall": bool(proof.get("publishedAfterInstall", false)),
					"homeOwned": bool((proof.get("homeServerOwner", {}) as Dictionary).get("found", false)),
					"porchOwned": bool((proof.get("porchServerOwner", {}) as Dictionary).get("found", false)),
					"startOwned": bool((proof.get("serverStartOwner", {}) as Dictionary).get("found", false)),
					"endOwned": bool((proof.get("serverEndOwner", {}) as Dictionary).get("found", false)),
					"homeReachesDoor": bool(proof.get("homeReachesDoor", false)),
					"requiresTransition": bool(proof.get("requiresDeclaredTransition", false)),
					"requiresLinks": bool(proof.get("homeRequiresDeclaredLinks", false)),
					"enabledPathCount": (proof.get("enabledPath", []) as Array).size(),
					"porch": proof.get("porchPosition", Vector3.INF),
					"porchServer": proof.get("porchServerPosition", Vector3.INF),
					"enabledEndpoint": proof.get("enabledEndpoint", Vector3.INF),
					"enabledEndpointDistance": float(proof.get("enabledEndpointDistance", INF)),
					"enabledCrosses": bool(proof.get("enabledCrosses", false)),
					"doorActionCount": (proof.get("enabledDoorActions", {}) as Dictionary).size(),
					"exactPortalAction": bool(proof.get("exactPortalAction", false)),
					"disabledPathCount": (proof.get("disabledPath", []) as Array).size(),
					"disabledEndpoint": proof.get("disabledEndpoint", Vector3.INF),
					"disabledEndpointDistance": float(proof.get("disabledEndpointDistance", INF)),
					"disabledCrosses": bool(proof.get("disabledCrosses", false))
				}
				break
			var pending_structure_operations := int(structure_system.call("pending_structure_op_count")) if structure_system.has_method("pending_structure_op_count") else -1
			var pathing_stats: Dictionary = npc_system.get("pathing").call("stats") if npc_system != null and npc_system.get("pathing") != null and npc_system.get("pathing").has_method("stats") else {}
			var route_authority_stats: Dictionary = pathing_stats.get("routePlanner", {}) if pathing_stats.get("routePlanner", {}) is Dictionary else {}
			var route_delegate_stats: Dictionary = route_authority_stats.get("delegate", {}) if route_authority_stats.get("delegate", {}) is Dictionary else {}
			write_profile_progress("stage=normal_world_citadel_publication status=%s shell=%d/%d furnishings=%d/%d pendingStructureOps=%d attempts=%d reason=%s detail=%s pendingTiles=%s queue=%s lastQueue=%s dirtySerial=%d syncedSerial=%d iteration=%d firstFailedProof=%s" % [
				String(fixture_publication_state.get("status", "")),
				int(fixture_publication_state.get("publishedPartCount", 0)),
				int(fixture_publication_state.get("partCount", 0)),
				int(fixture_publication_state.get("publishedFurnishingPartCount", 0)),
				int(fixture_publication_state.get("furnishingPartCount", 0)),
				pending_structure_operations,
				int(fixture_publication_state.get("registrationAttempts", 0)),
				String(last_failure.get("reason", "")),
				String(failure_details.get("reason", "")),
				JSON.stringify(failure_details.get("pendingTiles", [])),
				JSON.stringify(route_delegate_stats.get("queuedNavmeshTileKeys", [])),
				JSON.stringify(route_delegate_stats.get("lastNavmeshTileQueueDebug", [])),
				int(map_readiness.get("dirtySerial", -1)),
				int(map_readiness.get("syncedSerial", -1)),
				int(map_readiness.get("iterationId", -1)),
				JSON.stringify(failed_proof_summary)
			])
		if not failed_publication_state.is_empty():
			break
		await get_tree().process_frame
	if runtime_record.is_empty():
		fail_fixture_loading("The normal-world Citadel did not finish publication", {"site": fixture_site, "failedState": failed_publication_state, "states": structure_system.call("citadel_publication_snapshot")})
		return
	citadel_root = runtime_record.get("root") as Node3D
	blueprint = runtime_record.get("blueprint")
	core_blueprint = blueprint
	furnishing_plan = runtime_record.get("furnishingPlan")
	building_publisher = runtime_record.get("buildingPublisher")
	furnishing_publisher = runtime_record.get("furnishingPublisher")
	residence_manifest = runtime_record.get("residenceManifest", {}) as Dictionary
	building_publishers = [building_publisher] if building_publisher != null else []
	furnishing_publishers = [furnishing_publisher] if furnishing_publisher != null else []
	active_district_ids.clear()
	for residence_value in residence_manifest.get("residences", []) as Array:
		if residence_value is Dictionary:
			active_district_ids[String((residence_value as Dictionary).get("residenceId", ""))] = true
	if link_diagnostics_mode or surface_continuity_acceptance_mode:
		rebuilding = false
		profile_load_completed_usec = Time.get_ticks_usec()
		set_loading_visible(false)
		return
	set_loading("Waiting for ordinary generated residents")
	await bind_normal_world_residents()
	if citizens.size() != (residence_manifest.get("citizens", []) as Array).size():
		var spawn_diagnostics: Dictionary = npc_system.call("generated_resident_spawn_diagnostics_snapshot") if npc_system.has_method("generated_resident_spawn_diagnostics_snapshot") else {}
		fail_fixture_loading("The normal NPC population authority did not materialize every Citadel resident", {"expected": (residence_manifest.get("citizens", []) as Array).size(), "actual": citizens.size(), "spawnDiagnostics": spawn_diagnostics})
		return
	place_player_at_gate(blueprint.recipe if blueprint != null else {})
	enable_interactive_player()
	rebuilding = false
	set_world_display_hour(11.0)
	refresh_world_phase(true)
	acceptance_day_started_msec = Time.get_ticks_msec()
	update_status()
	set_loading_visible(false)
	profile_load_completed_usec = Time.get_ticks_usec()
	write_profile_report("ready")
	print("[Citadel Life] Observing normal-world site %s: %d residents" % [String(fixture_site.get("id", "")), citizens.size()])

func nearest_normal_world_citadel_manifest() -> Dictionary:
	if main == null or not main.has_method("landmark_sites_for_region"):
		return {}
	var player_cell := Vector2i(roundi(player.global_position.x / CELL), roundi(player.global_position.z / CELL)) if player != null else Vector2i.ZERO
	var center_region := Vector2i(floori(float(player_cell.x) / 420.0), floori(float(player_cell.y) / 420.0))
	var scanned_regions := {}
	var candidates: Array[Dictionary] = []
	for radius in range(0, 13):
		for region_z in range(center_region.y - radius, center_region.y + radius + 1):
			for region_x in range(center_region.x - radius, center_region.x + radius + 1):
				if radius > 0 and absi(region_x - center_region.x) < radius and absi(region_z - center_region.y) < radius:
					continue
				scanned_regions[Vector2i(region_x, region_z)] = true
				for site_value in main.call("landmark_sites_for_region", region_x, region_z, 420) as Array:
					if site_value is Dictionary and String((site_value as Dictionary).get("kind", "")) == "citadel":
						candidates.append((site_value as Dictionary).duplicate(true))
		if not candidates.is_empty():
			break
	var distant_windows: Array[Dictionary] = []
	if candidates.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.seed = int(("%d|citadel-life-normal-world-search" % selected_seed).hash())
		for window_index in range(12):
			var angle := rng.randf_range(-PI, PI)
			var distance := rng.randi_range(28, 72)
			var window_center := center_region + Vector2i(roundi(cos(angle) * float(distance)), roundi(sin(angle) * float(distance)))
			var window_record := {"index": window_index, "center": window_center, "scannedRegionCount": 0, "candidateCount": 0}
			for region_z in range(window_center.y - 4, window_center.y + 5):
				for region_x in range(window_center.x - 4, window_center.x + 5):
					var region := Vector2i(region_x, region_z)
					if scanned_regions.has(region):
						continue
					scanned_regions[region] = true
					window_record["scannedRegionCount"] = int(window_record["scannedRegionCount"]) + 1
					for site_value in main.call("landmark_sites_for_region", region_x, region_z, 420) as Array:
						if site_value is Dictionary and String((site_value as Dictionary).get("kind", "")) == "citadel":
							candidates.append((site_value as Dictionary).duplicate(true))
			window_record["candidateCount"] = candidates.size()
			distant_windows.append(window_record)
			if not candidates.is_empty():
				break
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
	fixture_site_search_diagnostics = {"centerRegion": center_region, "scannedRegionCount": scanned_regions.size(), "distantWindows": distant_windows, "candidateCount": candidates.size()}
	if candidates.is_empty():
		fixture_site_search_diagnostics["rejectionBreakdown"] = citadel_site_rejection_breakdown(scanned_regions.keys())
	return candidates[0] if not candidates.is_empty() else {}

func citadel_site_rejection_breakdown(region_values: Array) -> Dictionary:
	var regions: Array[Vector2i] = []
	for region_value in region_values:
		if region_value is Vector2i:
			regions.append(region_value)
	regions.sort_custom(func(left: Vector2i, right: Vector2i) -> bool: return left.y < right.y or (left.y == right.y and left.x < right.x))
	var spawn_eligible := 0
	var terrain_eligible := 0
	var examples: Array[Dictionary] = []
	for region in regions:
		var flat_manifest: Dictionary = CitadelSiteManifestPlannerScript.manifest_for_region(String(main.get("seed_text")), region.x, region.y, 420, Callable(self, "flat_landmark_sample"))
		if flat_manifest.is_empty():
			continue
		spawn_eligible += 1
		var terrain_manifest: Dictionary = CitadelSiteManifestPlannerScript.manifest_for_region(String(main.get("seed_text")), region.x, region.y, 420, Callable(self, "production_landmark_sample"))
		if not terrain_manifest.is_empty():
			terrain_eligible += 1
		if examples.size() < 8:
			examples.append(citadel_region_terrain_diagnostic(region, not terrain_manifest.is_empty()))
	return {"spawnEligibleRegionCount": spawn_eligible, "terrainEligibleRegionCount": terrain_eligible, "examples": examples}

func flat_landmark_sample(_cell: Vector3i) -> Dictionary:
	return {"surfaceY": 27.0, "solid": true, "fluid": "", "biome": "plains"}

func production_landmark_sample(cell: Vector3i) -> Dictionary:
	var generation = main.get("world_generation_system") if main != null else null
	if generation == null or not generation.has_method("natural_landmark_site_sample"):
		return {}
	var sample_value = generation.call("natural_landmark_site_sample", Vector2i(cell.x, cell.z))
	return sample_value if sample_value is Dictionary else {}

func citadel_region_terrain_diagnostic(region: Vector2i, terrain_eligible: bool) -> Dictionary:
	var candidate_records: Array[Dictionary] = []
	for candidate_value in CitadelSiteManifestPlannerScript._candidates(String(main.get("seed_text")), region.x, region.y):
		var candidate: Dictionary = candidate_value
		var center: Vector2i = candidate.get("center", Vector2i.ZERO)
		var minimum := INF
		var maximum := -INF
		var invalid_sample_count := 0
		for offset in CitadelSiteManifestPlannerScript._support_sample_offsets():
			var sample := production_landmark_sample(Vector3i(center.x + offset.x, 0, center.y + offset.y))
			var surface_y := float(sample.get("surfaceY", NAN))
			var biome := String(sample.get("biome", ""))
			if is_nan(surface_y) or not bool(sample.get("solid", false)) or String(sample.get("fluid", "")) != "" or biome in ["", "ocean", "beach", "underground", "underground_air"]:
				invalid_sample_count += 1
			else:
				minimum = minf(minimum, surface_y)
				maximum = maxf(maximum, surface_y)
		candidate_records.append({"center": center, "minimumSurfaceY": minimum, "maximumSurfaceY": maximum, "surfaceVariance": maximum - minimum, "invalidSampleCount": invalid_sample_count})
	return {"region": region, "terrainEligible": terrain_eligible, "candidates": candidate_records}

func bind_normal_world_residents() -> void:
	citizens.clear()
	for _frame in range(3600):
		citizens.clear()
		for index in range((residence_manifest.get("citizens", []) as Array).size()):
			var citizen: Dictionary = (residence_manifest.get("citizens", []) as Array)[index] as Dictionary
			var entry: Dictionary = npc_system.call("npc_entry_for_actor", String(citizen.get("id", ""))) as Dictionary
			var body := entry.get("body") as CharacterBody3D
			if body != null and is_instance_valid(body):
				citizens.append({"body": body, "manifest": citizen, "index": index, "locomotion": body.get_node_or_null("NpcBipedVisual/NpcBipedLocomotionPresenter")})
		if citizens.size() == (residence_manifest.get("citizens", []) as Array).size():
			return
		await get_tree().process_frame

func rebuild_legacy_fixture_citadel() -> void:
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
	living_tree_records.clear()
	generated_living_tree_count = 0
	keep_entry_collision_evidence.clear()
	keep_entry_player_sweep_evidence.clear()
	raised_route_transition_handoff_evidence.clear()
	raised_route_junction_traversal_evidence.clear()
	raised_route_junction_captures.clear()
	raised_route_roadbed_evidence.clear()
	residence_foundation_support_evidence.clear()
	walkable_surface_collision_evidence.clear()
	if citadel_root != null and is_instance_valid(citadel_root):
		citadel_root.queue_free()
	if furnishing_root != null and is_instance_valid(furnishing_root):
		furnishing_root.queue_free()
	citadel_root = null
	furnishing_root = null
	living_tree_root = null
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
	integrate_living_surface_tree_facts()
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
	var core_route_preflight := CastleCompoundBlueprintBuilderScript.validate_raised_route_coverage(core_blueprint)
	if not bool(core_route_preflight.get("passed", false)):
		fail_fixture_loading("Citadel core slice omitted a required raised-route owner or support", {"raisedRouteCoverage": core_route_preflight})
		return
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
	await building_publisher.publish_incremental(core_blueprint, citadel_root, loading_frame_budget(core_blueprint.parts.size()), {"batchStaticParts": true, "progressCallback": Callable(self, "record_core_publication_progress")})
	building_publishers.append(building_publisher)
	var core_physical_integrity: Dictionary = (building_publisher.summary().get("physicalIntegrity", {}) as Dictionary).duplicate(true)
	if not bool(core_physical_integrity.get("passed", false)):
		profile_end_stage("structure_publication", {"physicalIntegrity": core_physical_integrity})
		fail_fixture_loading("Citadel core publication was blocked by an invalid physical support contract", core_physical_integrity)
		return
	var core_route_coverage: Dictionary = (building_publisher.summary().get("raisedRouteCoverage", {}) as Dictionary).duplicate(true)
	if not bool(core_route_coverage.get("passed", false)):
		profile_end_stage("structure_publication", {"raisedRouteCoverage": core_route_coverage})
		fail_fixture_loading("Citadel core publication did not prove complete raised-route coverage", core_route_coverage)
		return
	write_profile_progress("stage=structure_publication checkpoint=core_published")
	register_published_building_navigation_manifest(building_publisher)
	write_profile_progress("stage=structure_publication checkpoint=navigation_manifest_registered")
	publish_living_surface_trees()
	write_profile_progress("stage=structure_publication checkpoint=living_trees_published")
	write_profile_progress("stage=structure_publication audit=keep_entry_supports")
	keep_entry_collision_evidence = await BuildingCollisionProbeScript.audit_keep_entry_supports(self, citadel_root, core_blueprint.parts)
	if not bool(keep_entry_collision_evidence.get("passed", false)):
		profile_end_stage("structure_publication", {"keepEntryCollision": keep_entry_collision_evidence})
		fail_fixture_loading("Published keep approach has no authoritative player collision", keep_entry_collision_evidence)
		return
	write_profile_progress("stage=structure_publication audit=raised_route_transition_handoff")
	raised_route_transition_handoff_evidence = await BuildingCollisionProbeScript.audit_player_raised_route_transition_handoff(self, player, citadel_root, core_route_coverage.get("records", []) as Array)
	if not bool(raised_route_transition_handoff_evidence.get("passed", false)):
		profile_end_stage("structure_publication", {"raisedRouteTransitionHandoff": raised_route_transition_handoff_evidence})
		fail_fixture_loading("The real player could not cross the published processional route into the keep entry", raised_route_transition_handoff_evidence)
		return
	write_profile_progress("stage=structure_publication audit=raised_route_junction_traversals")
	raised_route_junction_traversal_evidence = await BuildingCollisionProbeScript.audit_player_raised_route_junction_traversals(self, player, citadel_root, core_route_coverage.get("records", []) as Array)
	if not bool(raised_route_junction_traversal_evidence.get("passed", false)):
		profile_end_stage("structure_publication", {"raisedRouteJunctionTraversals": raised_route_junction_traversal_evidence})
		fail_fixture_loading("The real player could not cross every published raised-route junction", raised_route_junction_traversal_evidence)
		return
	write_profile_progress("stage=structure_publication audit=raised_route_roadbeds")
	raised_route_roadbed_evidence = await BuildingCollisionProbeScript.audit_citadel_raised_route_roadbeds(self, citadel_root, core_blueprint.parts, core_route_coverage.get("records", []) as Array)
	if not bool(raised_route_roadbed_evidence.get("passed", false)):
		profile_end_stage("structure_publication", {"raisedRouteRoadbeds": raised_route_roadbed_evidence})
		fail_fixture_loading("Raised Citadel routes are not continuously supported by published collision", raised_route_roadbed_evidence)
		return
	write_profile_progress("stage=structure_publication audit=raised_route_collision_negative_controls")
	raised_route_collision_negative_controls = await BuildingCollisionProbeScript.audit_raised_route_collision_negative_controls(self, player, citadel_root, core_blueprint.parts, core_route_coverage.get("records", []) as Array)
	if not bool(raised_route_collision_negative_controls.get("passed", false)):
		profile_end_stage("structure_publication", {"raisedRouteCollisionNegativeControls": raised_route_collision_negative_controls})
		fail_fixture_loading("Raised Citadel collision contracts did not fail closed when their named support was removed", raised_route_collision_negative_controls)
		return
	write_profile_progress("stage=structure_publication audit=walkable_surface_collision")
	walkable_surface_collision_evidence = await BuildingCollisionProbeScript.audit_citadel_walkable_surface_collision(self, player, citadel_root, core_blueprint.parts)
	if not bool(walkable_surface_collision_evidence.get("passed", false)):
		profile_end_stage("structure_publication", {"walkableSurfaceCollision": walkable_surface_collision_evidence})
		fail_fixture_loading("Citadel walkable surfaces do not match published collision", walkable_surface_collision_evidence)
		return
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
	acceptance_day_started_msec = Time.get_ticks_msec()
	profile_begin_stage("fixture_hud_presentation")
	update_status()
	await get_tree().process_frame
	profile_end_stage("fixture_hud_presentation")
	set_loading_visible(false)
	# A production input event cannot be accepted while the fixture loading overlay
	# owns the viewport. Keep collision/fall proof in the loading phase, then run
	# the actual player right-click and threshold crossing only after the ordinary
	# Main scene has returned its unhandled-input authority.
	var production_input_readiness := await wait_for_production_input_readiness()
	if not bool(production_input_readiness.get("ready", false)):
		fail_fixture_loading("The ordinary game never returned player input before Citadel entry acceptance", production_input_readiness)
		return
	var post_load_keep_sweep := await BuildingCollisionProbeScript.audit_player_keep_entry_sweep(self, player, citadel_root, core_blueprint.parts)
	keep_entry_player_sweep_evidence = post_load_keep_sweep.duplicate(true)
	keep_entry_player_sweep_evidence["productionInputReadiness"] = production_input_readiness
	keep_entry_player_sweep_evidence["preInteractiveCollision"] = keep_entry_collision_evidence.duplicate(true)
	if not bool(post_load_keep_sweep.get("passed", false)):
		fail_fixture_loading("The real player could not cross the keep approach after interactive presentation", post_load_keep_sweep)
		return
	await capture_viewport("keep_entry_player_collision_sweep")
	place_player_at_gate(recipe)
	await capture_viewport("interactive_ready")
	raised_route_junction_captures = await capture_raised_route_junction_views()
	profile_load_completed_usec = Time.get_ticks_usec()
	write_profile_report("ready")
	print("[Citadel Life] Ready: seed %d, %d citizens, %d furnished beds" % [selected_seed, citizens.size(), (residence_manifest.get("citizens", []) as Array).size()])
	if not profile_mode:
		request_relevant_district_publication()


func wait_for_production_input_readiness() -> Dictionary:
	for frame in range(PRODUCTION_INPUT_READY_MAX_FRAMES):
		if main != null and not bool(main.get("startup_loading_active")) and main.is_processing_unhandled_input():
			return {"ready": true, "frames": frame, "startupLoadingActive": false, "unhandledInputEnabled": true}
		await get_tree().physics_frame
	return {
		"ready": false,
		"frames": PRODUCTION_INPUT_READY_MAX_FRAMES,
		"startupLoadingActive": bool(main.get("startup_loading_active")) if main != null else true,
		"unhandledInputEnabled": main.is_processing_unhandled_input() if main != null else false
	}


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


func integrate_living_surface_tree_facts() -> void:
	# The life fixture keeps the production residence blueprint intact. It only
	# derives stable landscape records from open, already-published courtyard
	# paving, then both the surface-history publisher and tree service consume
	# those same records.
	living_tree_records.clear()
	if blueprint == null:
		return
	var sites: Array = CitadelUrbanPocComposerScript.select_open_paving_tree_sites(blueprint, selected_seed)
	var records: Array = CitadelUrbanPocComposerScript.build_tree_placement_records(sites, selected_seed)
	for record_value in records:
		if record_value is Dictionary:
			living_tree_records.append((record_value as Dictionary).duplicate(true))
	if living_tree_records.is_empty():
		return
	var recipe: Dictionary = blueprint.recipe.duplicate(true)
	recipe["landscapeTrees"] = living_tree_records.duplicate(true)
	blueprint.set_recipe(recipe)


func publish_living_surface_trees() -> void:
	generated_living_tree_count = 0
	if citadel_root == null or living_tree_records.is_empty():
		return
	living_tree_root = Node3D.new()
	living_tree_root.name = "CitadelLifeGeneratedTrees"
	citadel_root.add_child(living_tree_root)
	var tree_service = TreeSpawnServiceScript.new()
	for index in range(living_tree_records.size()):
		var record: Dictionary = living_tree_records[index]
		var request: Dictionary = record.get("treeRequest", {}) as Dictionary
		var position: Vector3 = record.get("position", Vector3.ZERO) as Vector3
		var tree_id := String(record.get("id", "citadel-life-tree-%d" % index))
		if request.is_empty():
			continue
		request = request.duplicate(true)
		request["treeId"] = tree_id
		request["worldPosition"] = position
		request["worldRotationY"] = float(record.get("rotationY", 0.0))
		var tree_recipe: Dictionary = tree_service.build_recipe(request)
		if tree_recipe.is_empty():
			continue
		var tree: Node3D = tree_service.instantiate_recipe(tree_recipe, String(request.get("biome", "town")), tree_id)
		if tree == null:
			continue
		tree.name = "CitadelLifeTree%02d" % index
		tree.position = position
		tree.rotation.y = float(record.get("rotationY", 0.0))
		tree.set_meta("citadel_life_generated_tree", true)
		living_tree_root.add_child(tree)
		generated_living_tree_count += 1


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
	var required_route_part_ids := core_route_part_dependency_ids(source)
	for part in source.parts:
		if part == null:
			continue
		if String(part.recipe.get("castleResidenceId", "")).is_empty() or required_route_part_ids.has(String(part.id)):
			core.parts.append(part)
	return core


func core_route_part_dependency_ids(source) -> Dictionary:
	var required := {}
	var changed := true
	while changed:
		changed = false
		for part in source.parts:
			if part == null:
				continue
			var part_id := String(part.id)
			var semantic := String(part.semantic)
			var is_route_surface := String(part.recipe.get("routeStreetId", "")) != "" or semantic in ["castle_processional_step", "castle_keep_palace_entry_forecourt", "castle_keep_palace_entry_forecourt_root"]
			if not is_route_surface and not required.has(part_id):
				continue
			if is_route_surface and not required.has(part_id):
				required[part_id] = true
				changed = true
			for relationship_key in ["physicalRequiredSupportPartIds", "routeTransitionRootPartIds"]:
				for dependency_value in part.recipe.get(relationship_key, []) as Array:
					var dependency_id := String(dependency_value)
					if not dependency_id.is_empty() and not required.has(dependency_id):
						required[dependency_id] = true
						changed = true
	return required


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
		source_recipe["publicationScope"] = "residence_district"
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
			"structuralAuthorityBlueprint": source,
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
	await building.publish_incremental(district_blueprint, shell_root, loading_frame_budget(district_blueprint.parts.size()), {"batchStaticParts": true, "structuralAuthorityBlueprint": selected.get("structuralAuthorityBlueprint")})
	if generation != district_publication_generation or not is_instance_valid(citadel_root):
		shell_root.queue_free()
		return false
	var district_physical_integrity: Dictionary = (building.summary().get("physicalIntegrity", {}) as Dictionary).duplicate(true)
	if not bool(district_physical_integrity.get("passed", false)):
		shell_root.queue_free()
		profile_end_stage("structure_publication", {"districtId": district_id, "physicalIntegrity": district_physical_integrity})
		fail_fixture_loading("Citadel district publication was blocked by an invalid physical support contract", district_physical_integrity)
		return false
	var district_foundation_support := BuildingCollisionProbeScript.audit_citadel_residence_foundation_supports(citadel_root, district_blueprint.parts)
	record_residence_foundation_support(district_id, district_foundation_support)
	if not bool(district_foundation_support.get("passed", false)):
		profile_end_stage("structure_publication", {"residenceFoundationSupports": residence_foundation_support_evidence})
		fail_fixture_loading("Published Citadel residence foundations are not structurally rooted in the compound base", residence_foundation_support_evidence)
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


func record_residence_foundation_support(district_id: String, evidence: Dictionary) -> void:
	if not residence_foundation_support_evidence.has("districts"):
		residence_foundation_support_evidence = {"passed": true, "districts": {}, "checkedFoundationCount": 0, "checkedSampleCount": 0, "checks": [], "violations": []}
	var districts: Dictionary = residence_foundation_support_evidence.get("districts", {}) as Dictionary
	districts[district_id] = evidence.duplicate(true)
	residence_foundation_support_evidence["districts"] = districts
	residence_foundation_support_evidence["checkedFoundationCount"] = int(residence_foundation_support_evidence.get("checkedFoundationCount", 0)) + int(evidence.get("checkedFoundationCount", 0))
	residence_foundation_support_evidence["checkedSampleCount"] = int(residence_foundation_support_evidence.get("checkedSampleCount", 0)) + int(evidence.get("checkedSampleCount", 0))
	var checks: Array = residence_foundation_support_evidence.get("checks", []) as Array
	for check_value in evidence.get("checks", []) as Array:
		if not check_value is Dictionary:
			continue
		var check: Dictionary = (check_value as Dictionary).duplicate(true)
		check["districtId"] = district_id
		checks.append(check)
	residence_foundation_support_evidence["checks"] = checks
	if not bool(evidence.get("passed", false)):
		residence_foundation_support_evidence["passed"] = false
		var violations: Array = residence_foundation_support_evidence.get("violations", []) as Array
		violations.append_array(evidence.get("violations", []) as Array)
		residence_foundation_support_evidence["violations"] = violations


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
	var summary := {"publisherCount": building_publishers.size(), "publishedPartCount": 0, "collisionPartCount": 0, "publishedNodeCount": 0, "visualBatchCount": 0, "publicationUsec": 0, "recipeBuildUsec": 0, "physicalIntegrityPassed": true, "physicalIntegrity": []}
	for publisher in building_publishers:
		if publisher == null or not publisher.has_method("summary"):
			continue
		var item: Dictionary = publisher.summary()
		for key in ["publishedPartCount", "collisionPartCount", "publishedNodeCount", "visualBatchCount", "publicationUsec", "recipeBuildUsec"]:
			summary[key] = int(summary.get(key, 0)) + int(item.get(key, 0))
		var physical_integrity: Dictionary = item.get("physicalIntegrity", {}) as Dictionary
		summary["physicalIntegrity"].append({"sourceBlueprintId": String(item.get("sourceBlueprintId", "")), "passed": bool(physical_integrity.get("passed", false)), "checkedPartCount": int(physical_integrity.get("checkedPartCount", 0)), "violations": physical_integrity.get("violations", [])})
		if not bool(physical_integrity.get("passed", false)):
			summary["physicalIntegrityPassed"] = false
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
		var target := civic_anchor_for(index, maxi(2, civic_order_round))
		# Civic targets live on the shared courtyard/street surface, not on the
		# citizen's bed storey. A manor resident can sleep upstairs but must still
		# receive a ground-level public target when leaving home for the day.
		target = published_navigation_position(target)
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
	var porch_navigation_seed := npc_system.call("cell_to_position", porch_cell, fixture_level) as Vector3
	return published_navigation_position(porch_navigation_seed)


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


func stage_crowd_crossing_orders(crossing: bool, source_positions := {}, publish_orders := true) -> Dictionary:
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
	var route_certifications := {}
	var all_routes_certified := true
	var initial_distances := {}
	var maximum_initial_distance := 0.0
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		var index := int(citizen_entry.get("index", 0))
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		var actor_id := String(manifest.get("id", body.name))
		var route_start: Vector3 = source_positions.get(actor_id, body.global_position) as Vector3 if source_positions is Dictionary and source_positions.get(actor_id, body.global_position) is Vector3 else body.global_position
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
		target = published_navigation_position(target)
		var initial_distance := Vector2(route_start.x - target.x, route_start.z - target.z).length()
		targets[actor_id] = target
		if crossing:
			var route_certification := certify_crowd_lane_route(route_start, target)
			route_certifications[actor_id] = route_certification
			all_routes_certified = all_routes_certified and bool(route_certification.get("passed", false))
		initial_distances[actor_id] = initial_distance
		maximum_initial_distance = maxf(maximum_initial_distance, initial_distance)
		var staged_entry := {
			"body": body,
			"kind": "go_to" if crossing else "wait",
			"reason": "citadel_life_crowd_crossing" if crossing else "citadel_life_crowd_lineup",
			"index": index
		}
		if crossing and bool((route_certifications.get(actor_id, {}) as Dictionary).get("passed", false)):
			staged_entry["target"] = target
			staged_entry["arrivalRadius"] = CROWD_FORMATION_ARRIVAL_RADIUS
		staged.append(staged_entry)
	var phase := "crowd_crossing" if crossing else "crowd_lineup"
	var envelope_validation := validate_crowd_target_arrival_envelopes(targets)
	if crossing and publish_orders:
		crowd_crossing_targets_by_actor_id = targets.duplicate(true)
	if publish_orders and (not crossing or all_routes_certified):
		replace_civic_order_queue(staged, phase)
	return {
		"ok": staged.size() == citizens.size() and bool(envelope_validation.get("ok", false)) and (not crossing or all_routes_certified),
		"reason": "" if not crossing or all_routes_certified else "crowd_lane_route_certification_failed",
		"phase": phase,
		"preview": not publish_orders,
		"expectedCount": citizens.size(),
		"queuedCount": staged.size(),
		"endpoints": endpoints,
		"targets": targets,
		"initialDistances": initial_distances,
		"maximumInitialDistance": maximum_initial_distance,
		"arrivalEnvelopeValidation": envelope_validation,
		"routeCertifications": route_certifications
	}


func certify_crowd_lane_route(start: Vector3, target: Vector3) -> Dictionary:
	var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
	var navmesh_world = autonomy.get("navmesh_world") if autonomy != null else null
	if navmesh_world == null or not navmesh_world.has_method("query_route"):
		return {"passed": false, "reason": "missing_navmesh_world"}
	var options := {
		"kind": "scripted",
		"arrivalRadius": CROWD_FORMATION_ARRIVAL_RADIUS,
		"maxSnapDistance": CELL * 0.95,
		"startMaxSnapDistance": CELL * 0.95,
		"targetMaxSnapDistance": CELL * 0.95,
		"queryApi": "query_path"
	}
	var forward: Dictionary = navmesh_world.call("query_route", start, target, options) as Dictionary
	var reverse: Dictionary = navmesh_world.call("query_route", target, start, options) as Dictionary
	var forward_target: Vector3 = forward.get("targetPosition", Vector3.INF) as Vector3
	var reverse_target: Vector3 = reverse.get("targetPosition", Vector3.INF) as Vector3
	var forward_endpoint_distance := forward_target.distance_to(target) if forward_target.is_finite() else INF
	var reverse_endpoint_distance := reverse_target.distance_to(start) if reverse_target.is_finite() else INF
	var passed := bool(forward.get("ok", false)) \
		and bool(reverse.get("ok", false)) \
		and String(forward.get("source", "")) == "navmesh" \
		and String(reverse.get("source", "")) == "navmesh" \
		and String(forward.get("queryApi", "")) == "query_path" \
		and String(reverse.get("queryApi", "")) == "query_path" \
		and forward_endpoint_distance <= CROWD_FORMATION_ARRIVAL_RADIUS \
		and reverse_endpoint_distance <= CROWD_FORMATION_ARRIVAL_RADIUS
	return {
		"passed": passed,
		"reason": "" if passed else "bidirectional_navigation_server_route_incomplete",
		"start": start,
		"target": target,
		"forwardEndpointDistance": forward_endpoint_distance,
		"reverseEndpointDistance": reverse_endpoint_distance,
		"forward": forward,
		"reverse": reverse
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
		var placement := await fixture_place_crowd_lineup_actor(body, target)
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
				placement = await fixture_place_crowd_lineup_actor(body, candidate)
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
	var negative_control := fixture_crowd_lineup_negative_control()
	return {
		"ok": placed_count == citizens.size() and bool(negative_control.get("passed", false)),
		"placedCount": placed_count,
		"expectedCount": citizens.size(),
		"authority": "NpcSystem fixture placement",
		"phase": "pre_act_fixture_setup",
		"placements": placements,
		"negativeControl": negative_control
	}


func fixture_place_crowd_lineup_actor(body: CharacterBody3D, target: Vector3) -> Dictionary:
	var support := fixture_crowd_lineup_support(target)
	var contact_overlap := fixture_crowd_lineup_overlap_report(body, target, support)
	if not bool(contact_overlap.get("ok", false)):
		return {
			"ok": false,
			"position": target,
			"reason": String(contact_overlap.get("reason", "occupied_capsule")),
			"fixtureSetup": {
				"target": target,
				"contactBand": CROWD_FIXTURE_CONTACT_BAND,
				"support": support,
				"contactOverlap": contact_overlap
			}
		}
	var spawn_position := target + Vector3.UP * CROWD_FIXTURE_SPAWN_LIFT
	var placement: Dictionary = npc_system.call("safe_place_npc", body, spawn_position, null, "citadel_crowd_pre_act_lineup") as Dictionary
	annotate_crowd_fixture_collision(placement)
	var spawn_overlap := fixture_crowd_lineup_overlap_report(body, spawn_position, support)
	placement["fixtureSetup"] = {
		"target": target,
		"spawnPosition": spawn_position,
		"contactBand": CROWD_FIXTURE_CONTACT_BAND,
		"support": support,
		"contactOverlap": contact_overlap,
		"spawnOverlap": spawn_overlap,
		"usesSafePlacement": true
	}
	if not bool(placement.get("ok", false)) or not bool(spawn_overlap.get("ok", false)):
		placement["ok"] = false
		placement["reason"] = String(placement.get("reason", "occupied_capsule")) if not bool(placement.get("ok", false)) else String(spawn_overlap.get("reason", "occupied_capsule"))
		return placement
	await get_tree().physics_frame
	var fixture_setup: Dictionary = placement.get("fixtureSetup", {}) as Dictionary
	fixture_setup["settle"] = {
		"position": body.global_position,
		"grounded": body.is_on_floor(),
		"horizontalDelta": Vector2(body.global_position.x - target.x, body.global_position.z - target.z).length(),
		"overlap": fixture_crowd_lineup_overlap_report(body, body.global_position, support)
	}
	placement["fixtureSetup"] = fixture_setup
	return placement


func fixture_crowd_lineup_support(target: Vector3) -> Dictionary:
	if citadel_root == null or citadel_root.get_world_3d() == null:
		return {"ok": false, "reason": "missing_collision_world", "target": target}
	var query := PhysicsRayQueryParameters3D.create(target + Vector3.UP * 1.0, target - Vector3.UP * 1.0, NpcConstantsScript.COLLISION_NPC_SAFE_PLACEMENT_MASK)
	query.collide_with_areas = false
	var hit: Dictionary = citadel_root.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {"ok": false, "reason": "missing_floor_support", "target": target, "rayHit": {}}
	var surface: Vector3 = hit.get("position", Vector3.INF) as Vector3
	var source := BuildingCollisionProbeScript._part_collision_source_for_ray(hit)
	var candidates := BuildingCollisionProbeScript._part_collision_candidates_at_contact(citadel_root, surface)
	var support_part_ids := {}
	for candidate_value in candidates:
		if not (candidate_value is Dictionary):
			continue
		var candidate: Dictionary = candidate_value
		var shape_size: Vector3 = candidate.get("shapeSize", Vector3.ZERO) as Vector3
		var local_contact: Vector3 = candidate.get("localContact", Vector3.INF) as Vector3
		var part_id := String(candidate.get("partId", ""))
		if part_id.is_empty() or shape_size.y <= 0.0 or not local_contact.is_finite():
			continue
		if absf(local_contact.y - shape_size.y * 0.5) <= CROWD_FIXTURE_CONTACT_BAND:
			support_part_ids[part_id] = true
	var primary_part_id := String(source.get("partId", ""))
	if not primary_part_id.is_empty():
		support_part_ids[primary_part_id] = true
	var selected_part_ids: Array[String] = []
	for part_id_value in support_part_ids.keys():
		selected_part_ids.append(String(part_id_value))
	selected_part_ids.sort()
	return {
		"ok": not selected_part_ids.is_empty() and surface.is_finite(),
		"reason": "" if not selected_part_ids.is_empty() and surface.is_finite() else "missing_selected_floor_support",
		"target": target,
		"surface": surface,
		"primarySource": source,
		"selectedPartIds": selected_part_ids,
		"surfaceCandidates": candidates
	}


func fixture_crowd_lineup_overlap_report(body: CharacterBody3D, position: Vector3, support: Dictionary) -> Dictionary:
	if body == null or body.get_world_3d() == null:
		return {"ok": false, "reason": "missing_body_or_world", "rawHits": [], "filteredHits": []}
	var profile = CharacterMotorProfileScript.npc_default()
	var shape := CapsuleShape3D.new()
	shape.radius = float(profile.get("capsule_radius"))
	shape.height = float(profile.get("capsule_height"))
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), position + Vector3.UP * (shape.height * 0.5))
	query.collision_mask = NpcConstantsScript.COLLISION_NPC_SAFE_PLACEMENT_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [body.get_rid()]
	var selected_part_ids := {}
	for part_id_value in support.get("selectedPartIds", []) as Array:
		selected_part_ids[String(part_id_value)] = true
	var surface: Vector3 = support.get("surface", Vector3.INF) as Vector3
	var raw_hits: Array = body.get_world_3d().direct_space_state.intersect_shape(query, 16)
	var raw_report: Array[Dictionary] = []
	var filtered_report: Array[Dictionary] = []
	for hit_value in raw_hits:
		if not (hit_value is Dictionary):
			continue
		var hit: Dictionary = hit_value
		var source := BuildingCollisionProbeScript._part_collision_source_for_ray(hit)
		var part_id := String(source.get("partId", ""))
		var allowed_support := selected_part_ids.has(part_id) and surface.is_finite() and absf(position.y - surface.y) <= CROWD_FIXTURE_CONTACT_BAND
		var record := {
			"collider": String((hit.get("collider") as Node).name) if hit.get("collider") is Node else "",
			"shapeIndex": int(hit.get("shape", -1)),
			"source": source,
			"allowedSupportContact": allowed_support
		}
		raw_report.append(record)
		if not allowed_support:
			filtered_report.append(record)
	return {
		"ok": bool(support.get("ok", false)) and filtered_report.is_empty(),
		"reason": "" if bool(support.get("ok", false)) and filtered_report.is_empty() else "occupied_capsule",
		"position": position,
		"capsuleRadius": shape.radius,
		"capsuleHeight": shape.height,
		"rawHits": raw_report,
		"filteredHits": filtered_report
	}


func fixture_crowd_lineup_negative_control() -> Dictionary:
	if citadel_root == null:
		return {"passed": false, "reason": "missing_citadel_root"}
	for collision_value in citadel_root.find_children("*", "CollisionShape3D", true, false):
		var collision := collision_value as CollisionShape3D
		if collision == null or collision.disabled or String(collision.get_meta("building_part_kind", "")) != "wall":
			continue
		var box := collision.shape as BoxShape3D
		if box == null:
			continue
		var local_position := Vector3(0.0, -box.size.y * 0.5 + 0.04, 0.0)
		var position := collision.global_transform * local_position
		var probe_body := valid_citizen_body(citizens[0] as Dictionary) if not citizens.is_empty() else null
		var overlap := fixture_crowd_lineup_overlap_report(probe_body, position, {"ok": true, "selectedPartIds": [], "surface": Vector3.INF})
		return {
			"passed": not bool(overlap.get("ok", true)) and not (overlap.get("rawHits", []) as Array).is_empty(),
			"partId": String(collision.get_meta("building_part_id", "")),
			"position": position,
			"overlap": overlap
		}
	return {"passed": false, "reason": "missing_wall_collision"}


func annotate_crowd_fixture_collision(placement: Dictionary) -> void:
	if bool(placement.get("ok", false)) or citadel_root == null:
		return
	var rejected_position: Vector3 = placement.get("position", Vector3.INF) as Vector3
	if not rejected_position.is_finite():
		return
	placement["publishedCollisionSources"] = BuildingCollisionProbeScript._part_collision_candidates_at_contact(citadel_root, rejected_position)


func crowd_crossing_endpoints() -> Dictionary:
	var processional_endpoints := processional_crowd_crossing_endpoints()
	if not processional_endpoints.is_empty():
		return processional_endpoints
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


func processional_crowd_crossing_endpoints() -> Dictionary:
	if blueprint == null:
		return {}
	var grammar: Dictionary = blueprint.recipe.get("castleGrammar", {}) as Dictionary
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	if String(grid.get("layoutFamily", "")) != "bent_processional":
		return {}
	var candidates: Array[Dictionary] = []
	for record_value in grid.get("streetRecords", []) as Array:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value as Dictionary
		var width := float(record.get("width", 0.0))
		var depth := float(record.get("depth", 0.0))
		var runs_along_z := depth >= width
		var longitudinal_span := depth if runs_along_z else width
		var cross_span := width if runs_along_z else depth
		# Street records include their structural joins at both ends.  Those joins
		# can meet a stair, terrace, or facade, so a head-on crowd fixture must use
		# the record's pedestrian interior rather than its decorative extents.
		var endpoint_inset := maxf(CELL * 1.1, minf(3.0, longitudinal_span * 0.20))
		var usable_span := longitudinal_span - endpoint_inset * 2.0
		if usable_span < 8.0 or cross_span < CELL * 1.5:
			continue
		var travel_distance := minf(18.0, minf(26.0, usable_span))
		var center := fixture_origin + Vector3(float(record.get("x", 0.0)), 0.0, float(record.get("z", 0.0)))
		var axis := Vector3.FORWARD if runs_along_z else Vector3.RIGHT
		var half_distance := travel_distance * 0.5
		var record_id := String(record.get("id", "processional"))
		var corridor_rank := 0 if record_id in ["processional_00_gate_lane", "processional_02a_civic_approach", "processional_04a_palace_approach"] else 1
		candidates.append({
			"id": record_id,
			"left": center - axis * half_distance,
			"right": center + axis * half_distance,
			"distance": travel_distance,
			"endpointInset": endpoint_inset,
			"corridorRank": corridor_rank,
			"score": absf(travel_distance - 18.0)
		})
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_corridor_rank := int(left.get("corridorRank", 1))
		var right_corridor_rank := int(right.get("corridorRank", 1))
		if left_corridor_rank != right_corridor_rank:
			return left_corridor_rank < right_corridor_rank
		var left_score := float(left.get("score", INF))
		var right_score := float(right.get("score", INF))
		if not is_equal_approx(left_score, right_score):
			return left_score < right_score
		return String(left.get("id", "")) < String(right.get("id", ""))
	)
	var selected: Dictionary = candidates.front() as Dictionary
	return {
		"left": selected.get("left", Vector3.ZERO),
		"right": selected.get("right", Vector3.ZERO),
		"distance": float(selected.get("distance", 0.0)),
		"source": "generated_processional_street_record",
		"streetRecordId": String(selected.get("id", "")),
		"endpointInset": float(selected.get("endpointInset", 0.0))
	}


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
		"orderId": String(result.get("id", "")),
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
			decorate_order_admission_timing(snapshot, false)
			return snapshot
		await get_tree().process_frame
	var timed_out := civic_order_batch_snapshot(generation)
	timed_out["phase"] = phase
	decorate_order_admission_timing(timed_out, true)
	return timed_out


func decorate_order_admission_timing(snapshot: Dictionary, timed_out: bool) -> void:
	var process_frames := int(snapshot.get("processFrames", ACCEPTANCE_ORDER_ADMISSION_MAX_PROCESS_FRAMES + 1))
	var elapsed_ms := float(snapshot.get("elapsedMs", INF))
	var admission_correct := not timed_out \
		and bool(snapshot.get("allAccepted", false)) \
		and process_frames <= ACCEPTANCE_ORDER_ADMISSION_MAX_PROCESS_FRAMES
	var wall_performance_passed := not timed_out and elapsed_ms <= ACCEPTANCE_ORDER_ADMISSION_MAX_MS
	snapshot["timely"] = admission_correct
	snapshot["admissionCorrect"] = admission_correct
	snapshot["wallPerformancePassed"] = wall_performance_passed
	snapshot["wallMsPerProcessFrame"] = elapsed_ms / float(maxi(1, process_frames)) if is_finite(elapsed_ms) else INF
	snapshot["reason"] = "" if admission_correct else ("order_admission_timeout" if timed_out else "order_admission_rejected_or_frame_budget_exceeded")
	snapshot["performanceReason"] = "" if wall_performance_passed else "order_admission_wall_stall"


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
		if absf(float(record.get("elevation", 0.0))) > 0.01:
			continue
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


func published_navigation_position(position: Vector3) -> Vector3:
	if npc_system == null:
		return position
	var autonomy = npc_system.get("autonomy_system")
	if autonomy == null or not autonomy.has_method("generated_navigation_adapter"):
		return position
	var adapter = autonomy.call("generated_navigation_adapter")
	if adapter == null or not adapter.has_method("navigation_query_position"):
		return position
	var resolved: Variant = adapter.call("navigation_query_position", position)
	return resolved as Vector3 if resolved is Vector3 and (resolved as Vector3).is_finite() else position


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


func record_core_publication_progress(progress: Dictionary) -> void:
	write_profile_progress("stage=structure_publication publisher=core reason=%s parts=%d/%d pendingInstances=%d staticFlushes=%d" % [String(progress.get("reason", "")), int(progress.get("publishedParts", 0)), int(progress.get("totalParts", 0)), int(progress.get("pendingStaticVisualInstances", 0)), int(progress.get("staticFlushCount", 0))])


func report_collision_probe_progress(probe_id: String, completed_count: int, total_count: int) -> void:
	write_profile_progress("stage=structure_publication audit=%s sample=%d/%d fps=%.2f processMs=%.3f physicsMs=%.3f" % [probe_id, completed_count, total_count, Engine.get_frames_per_second(), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0])


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
	if observed_world_phase == "day" and not crowd_stress_active and not acceptance_mode:
		civic_order_elapsed += delta
		if civic_order_elapsed >= 14.0:
			civic_order_elapsed = 0.0
			issue_civic_orders()
	drain_civic_order_queue()
	update_civic_order_batch_motion_evidence()
	status_elapsed += delta
	if status_elapsed >= 0.25:
		status_elapsed = 0.0
		update_status()


func _physics_process(delta: float) -> void:
	if not acceptance_mode or rebuilding or citizens.size() < 2:
		return
	# Citizens begin their ordinary daytime departure as soon as the published
	# fixture becomes playable. Keep the door observer on the real physics loop
	# from that point, rather than beginning evidence after the departure has
	# already crossed and released its portal.
	if acceptance_day_started_msec > 0:
		record_door_lifecycle_observations("night_home" if observed_world_phase == "night" else "day_civic")
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


func settle_biped_presentation() -> void:
	await get_tree().process_frame
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
	var failed_state: Dictionary = details.get("failedState", {}) if details.get("failedState", {}) is Dictionary else {}
	var concise_reason := String(failed_state.get("failureReason", details.get("reason", ""))).strip_edges()
	concise_reason = " ".join(concise_reason.replace("\r", "\n").split("\n", false)).strip_edges()
	if concise_reason.length() > 160:
		concise_reason = "%s..." % concise_reason.left(157)
	fixture_failure_reason = message if concise_reason.is_empty() else "%s: %s" % [message, concise_reason]
	if fixture_failure_reason.length() > 240:
		fixture_failure_reason = "%s..." % fixture_failure_reason.left(237)
	fixture_failure_details = details.duplicate(true)
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


func materialize_surface_continuity_acceptance_actors(publication_probe: Dictionary) -> Dictionary:
	var certificates: Array = publication_probe.get("continuityCertificates", []) as Array
	if certificates.size() != 1 or not (certificates[0] is Dictionary):
		return {"passed": false, "reason": "missing_unique_surface_continuity_certificate"}
	var lane_positions: Array = (certificates[0] as Dictionary).get("lanePositions", []) as Array
	var resident_records: Array = residence_manifest.get("citizens", []) as Array
	if lane_positions.size() < 2 or resident_records.size() < 2:
		return {"passed": false, "reason": "insufficient_surface_continuity_fixture_inputs", "laneCount": lane_positions.size(), "residentRecordCount": resident_records.size()}
	var spawn_results: Array[Dictionary] = []
	for index in range(2):
		if not (resident_records[index] is Dictionary):
			return {"passed": false, "reason": "invalid_surface_continuity_resident_record", "index": index}
		var body := npc_system.call("spawn_generated_resident", (resident_records[index] as Dictionary).duplicate(true), index) as CharacterBody3D if npc_system.has_method("spawn_generated_resident") else null
		if body == null or not is_instance_valid(body):
			spawn_results.append({"ok": false, "index": index, "reason": "production_generated_resident_spawn_failed"})
			return {"passed": false, "reason": "surface_continuity_actor_materialization_failed", "spawnResults": spawn_results}
		var locomotion := body.get_node_or_null("NpcBipedVisual/NpcBipedLocomotionPresenter")
		var locomotion_script = locomotion.get_script() if locomotion != null else null
		var locomotion_script_path := String(locomotion_script.resource_path) if locomotion_script is Script else ""
		var production_biped := locomotion != null \
			and locomotion.has_method("apply_body_motion") \
			and locomotion_script_path == "res://scripts/characters/NpcBipedLocomotionPresenter.gd"
		spawn_results.append({"ok": production_biped, "index": index, "actorId": String((resident_records[index] as Dictionary).get("id", "")), "productionSpawnApi": "NpcSystem.spawn_generated_resident", "locomotionPresenterPath": locomotion_script_path})
		if not production_biped:
			return {"passed": false, "reason": "surface_continuity_production_biped_presenter_missing", "spawnResults": spawn_results}
		citizens.append({"body": body, "manifest": (resident_records[index] as Dictionary).duplicate(true), "index": index, "locomotion": locomotion})
	await wait_physics_frames(8)
	return {"passed": citizens.size() == 2, "reason": "" if citizens.size() == 2 else "surface_continuity_actor_count_mismatch", "actorCount": citizens.size(), "spawnResults": spawn_results}


func run_surface_continuity_actor_acceptance(publication_probe: Dictionary) -> void:
	var certificates: Array = publication_probe.get("continuityCertificates", []) as Array
	if certificates.size() != 1 or not (certificates[0] is Dictionary):
		surface_continuity_acceptance_result = {"passed": false, "reason": "missing_unique_surface_continuity_certificate"}
		return
	var certificate: Dictionary = certificates[0]
	var lane_positions: Array = certificate.get("lanePositions", []) as Array
	if lane_positions.size() < 2 or citizens.size() < 2 or not (lane_positions[0] is Vector3) or not (lane_positions[1] is Vector3):
		surface_continuity_acceptance_result = {"passed": false, "reason": "insufficient_live_actor_or_lane_capacity"}
		return
	var forecourt_id := ""
	var segment_03_id := ""
	for owner_value in certificate.get("sourceOwners", []) as Array:
		var owner_id := String(owner_value)
		if owner_id.contains("castle_keep_palace_entry_forecourt"):
			forecourt_id = owner_id
		elif owner_id.contains("castle_compound_paving_segment_03"):
			segment_03_id = owner_id
	if forecourt_id.is_empty() or segment_03_id.is_empty():
		surface_continuity_acceptance_result = {"passed": false, "reason": "surface_continuity_support_owners_missing", "sourceOwners": certificate.get("sourceOwners", [])}
		return
	var selected: Array[Dictionary] = [citizens[0] as Dictionary, citizens[1] as Dictionary]
	var selected_bodies: Array[CharacterBody3D] = []
	var actor_ids: Array[String] = []
	for citizen_entry in selected:
		var body := valid_citizen_body(citizen_entry)
		if body == null:
			surface_continuity_acceptance_result = {"passed": false, "reason": "surface_continuity_actor_missing"}
			return
		selected_bodies.append(body)
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		actor_ids.append(String(manifest.get("id", body.name)))
	crowd_stress_active = true
	var autonomy = npc_system.get("autonomy_system")
	var adapter = autonomy.call("generated_navigation_adapter") if autonomy != null and autonomy.has_method("generated_navigation_adapter") else null
	var crowd_service = autonomy.get("crowd_velocity_service") if autonomy != null else null
	var traffic_service = autonomy.get("traffic_reservations") if autonomy != null else null
	var wait_orders: Array[Dictionary] = []
	for citizen_entry in citizens:
		var body := valid_citizen_body(citizen_entry as Dictionary)
		if body != null:
			wait_orders.append({"body": body, "kind": "wait", "reason": "citadel_surface_continuity_pre_act_wait"})
	replace_civic_order_queue(wait_orders, "surface_continuity_pre_act_wait")
	var wait_admission := await await_civic_order_batch_admission("surface_continuity_pre_act_wait", civic_order_generation)
	await wait_physics_frames(8)
	var source_positions: Array[Vector3] = [(lane_positions[0] as Vector3) + Vector3(0.0, 0.04, -2.0), (lane_positions[1] as Vector3) + Vector3(0.0, 0.04, 2.0)]
	var targets: Array[Vector3] = [(lane_positions[0] as Vector3) + Vector3(0.0, 0.04, 2.0), (lane_positions[1] as Vector3) + Vector3(0.0, 0.04, -2.0)]
	var expected_source_owners: Array[String] = [forecourt_id, segment_03_id]
	var expected_target_owners: Array[String] = [segment_03_id, forecourt_id]
	var placements: Array[Dictionary] = []
	var pre_act_owner_certifications: Array[Dictionary] = []
	for actor_index in range(selected_bodies.size()):
		var placement: Dictionary = npc_system.call("safe_place_npc", selected_bodies[actor_index], source_positions[actor_index], null, "citadel_surface_continuity_pre_act_lineup") as Dictionary
		placements.append(placement.duplicate(true))
		if not bool(placement.get("ok", false)):
			crowd_stress_active = false
			surface_continuity_acceptance_result = {"passed": false, "reason": "surface_continuity_pre_act_placement_failed", "placements": placements}
			return
	await wait_physics_frames(6)
	var all_pre_act_owners_certified := true
	for actor_index in range(selected_bodies.size()):
		var source_owner: Dictionary = adapter.call("building_support_for_position", selected_bodies[actor_index].global_position, CELL * 0.92) as Dictionary if adapter != null and adapter.has_method("building_support_for_position") else {}
		var source_owner_certified := String(source_owner.get("id", "")) == expected_source_owners[actor_index] \
			and Vector2(selected_bodies[actor_index].global_position.x - source_positions[actor_index].x, selected_bodies[actor_index].global_position.z - source_positions[actor_index].z).length() <= 0.45
		all_pre_act_owners_certified = all_pre_act_owners_certified and source_owner_certified
		pre_act_owner_certifications.append({"actorId": actor_ids[actor_index], "passed": source_owner_certified, "expectedSupportId": expected_source_owners[actor_index], "actualSupportId": String(source_owner.get("id", "")), "requestedPosition": source_positions[actor_index], "resolvedPosition": selected_bodies[actor_index].global_position})
	if not all_pre_act_owners_certified:
		crowd_stress_active = false
		surface_continuity_acceptance_result = {"passed": false, "reason": "surface_continuity_pre_act_owner_mismatch", "placements": placements, "preActOwnerCertifications": pre_act_owner_certifications}
		return
	await capture_crowd_encounter_view("surface_continuity_pre_act", actor_ids[0], actor_ids[1])
	var staged: Array[Dictionary] = []
	for actor_index in range(selected_bodies.size()):
		staged.append({"body": selected_bodies[actor_index], "kind": "go_to", "target": targets[actor_index], "arrivalRadius": 0.32, "reason": "citadel_surface_continuity_live_crossing"})
	replace_civic_order_queue(staged, "surface_continuity_live_crossing")
	var crossing_admission := await await_civic_order_batch_admission("surface_continuity_live_crossing", civic_order_generation)
	var crowd_stats_before: Dictionary = crowd_service.call("stats") as Dictionary if crowd_service != null and crowd_service.has_method("stats") else {}
	var airborne_frames := {}
	var actor_collision_frames := {}
	var active_transition_frames := {}
	var scripted_action_frames := {}
	var maximum_active_traffic_reservations := 0
	var minimum_separation := INF
	var stable_arrival_frames := 0
	var sampled_frames := 0
	var midpoint_capture_taken := false
	var seam_crossings := {}
	var previous_signed_seam_distances := {}
	var owner_sequences := {}
	var maximum_lane_deviation := {}
	var matched_crowd_callback_frames := {}
	for actor_index in range(selected_bodies.size()):
		var actor_id := actor_ids[actor_index]
		var direction := (targets[actor_index] - source_positions[actor_index]).normalized()
		previous_signed_seam_distances[actor_id] = (selected_bodies[actor_index].global_position - (lane_positions[actor_index] as Vector3)).dot(direction)
		owner_sequences[actor_id] = [expected_source_owners[actor_index]]
		maximum_lane_deviation[actor_id] = 0.0
		matched_crowd_callback_frames[actor_id] = 0
	for frame_index in range(1800):
		await get_tree().physics_frame
		sampled_frames += 1
		var all_arrived := true
		var both_in_motion_window := true
		for actor_index in range(selected_bodies.size()):
			var body := selected_bodies[actor_index]
			var actor_id := actor_ids[actor_index]
			var npc_entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
			var lease: Dictionary = npc_entry.get("routeLease", {}) if npc_entry.get("routeLease", {}) is Dictionary else {}
			if not (lease.get("actions", {}) as Dictionary).is_empty():
				scripted_action_frames[actor_id] = int(scripted_action_frames.get(actor_id, 0)) + 1
			if not (npc_entry.get("activeNavigationTransition", {}) as Dictionary).is_empty():
				active_transition_frames[actor_id] = int(active_transition_frames.get(actor_id, 0)) + 1
			if frame_index >= 4 and not body.is_on_floor():
				airborne_frames[actor_id] = int(airborne_frames.get(actor_id, 0)) + 1
			for collision_index in range(body.get_slide_collision_count()):
				var collision := body.get_slide_collision(collision_index)
				if collision != null and collision.get_collider() in selected_bodies:
					actor_collision_frames[actor_id] = int(actor_collision_frames.get(actor_id, 0)) + 1
			var target_distance := Vector2(body.global_position.x - targets[actor_index].x, body.global_position.z - targets[actor_index].z).length()
			var order: Dictionary = npc_entry.get("scriptedOrder", {}) if npc_entry.get("scriptedOrder", {}) is Dictionary else {}
			all_arrived = all_arrived and target_distance <= 0.40 and String(order.get("state", "")) == "ARRIVED"
			var lane_position: Vector3 = lane_positions[actor_index]
			var travel_direction := (targets[actor_index] - source_positions[actor_index]).normalized()
			var signed_seam_distance := (body.global_position - lane_position).dot(travel_direction)
			var previous_signed_distance := float(previous_signed_seam_distances.get(actor_id, signed_seam_distance))
			if previous_signed_distance < -0.05 and signed_seam_distance > 0.05 and not seam_crossings.has(actor_id):
				seam_crossings[actor_id] = {"physicsFrame": Engine.get_physics_frames(), "position": body.global_position, "previousSignedDistance": previous_signed_distance, "signedDistance": signed_seam_distance, "lanePosition": lane_position}
			previous_signed_seam_distances[actor_id] = signed_seam_distance
			if absf(signed_seam_distance) <= 0.80:
				var lateral_axis := Vector3(-travel_direction.z, 0.0, travel_direction.x)
				maximum_lane_deviation[actor_id] = maxf(float(maximum_lane_deviation.get(actor_id, 0.0)), absf((body.global_position - lane_position).dot(lateral_axis)))
			var current_owner: Dictionary = adapter.call("building_support_for_position", body.global_position, CELL * 0.92) as Dictionary if adapter != null and adapter.has_method("building_support_for_position") else {}
			var current_owner_id := String(current_owner.get("id", ""))
			var owner_sequence: Array = owner_sequences.get(actor_id, []) as Array
			if not current_owner_id.is_empty() and (owner_sequence.is_empty() or String(owner_sequence.back()) != current_owner_id):
				owner_sequence.append(current_owner_id)
				owner_sequences[actor_id] = owner_sequence
			var solver_adapter = crowd_service.get("adapter") if crowd_service != null else null
			var solver_diagnostics: Dictionary = solver_adapter.call("agent_diagnostics", actor_id) as Dictionary if solver_adapter != null and solver_adapter.has_method("agent_diagnostics") else {}
			var submission: Dictionary = solver_diagnostics.get("submission", {}) as Dictionary
			var callback: Dictionary = solver_diagnostics.get("callback", {}) as Dictionary
			if not String(submission.get("submissionKey", "")).is_empty() \
			and String(submission.get("submissionKey", "")) == String(callback.get("submissionKey", "")) \
			and String(submission.get("requestKey", "")) == String(callback.get("requestKey", "")) \
			and callback.get("safeVelocity") is Vector3:
				matched_crowd_callback_frames[actor_id] = int(matched_crowd_callback_frames.get(actor_id, 0)) + 1
			var route_span := Vector2(targets[actor_index].x - source_positions[actor_index].x, targets[actor_index].z - source_positions[actor_index].z).length()
			var progress := Vector2(body.global_position.x - source_positions[actor_index].x, body.global_position.z - source_positions[actor_index].z).length() / maxf(route_span, 0.001)
			both_in_motion_window = both_in_motion_window and progress >= 0.25 and progress <= 0.85
		var separation := Vector2(selected_bodies[0].global_position.x - selected_bodies[1].global_position.x, selected_bodies[0].global_position.z - selected_bodies[1].global_position.z).length()
		minimum_separation = minf(minimum_separation, separation)
		if traffic_service != null and traffic_service.has_method("stats"):
			maximum_active_traffic_reservations = maxi(maximum_active_traffic_reservations, int((traffic_service.call("stats") as Dictionary).get("activeReservations", 0)))
		if not midpoint_capture_taken and both_in_motion_window:
			midpoint_capture_taken = true
			await capture_crowd_encounter_view("surface_continuity_live_crossing", actor_ids[0], actor_ids[1])
		if all_arrived:
			stable_arrival_frames += 1
			if stable_arrival_frames >= 12:
				break
		else:
			stable_arrival_frames = 0
	await capture_crowd_encounter_view("surface_continuity_arrived", actor_ids[0], actor_ids[1])
	var crowd_stats_after: Dictionary = crowd_service.call("stats") as Dictionary if crowd_service != null and crowd_service.has_method("stats") else {}
	var actor_results: Array[Dictionary] = []
	var all_endpoint_owners_certified := true
	var all_seam_crossings_certified := true
	for actor_index in range(selected_bodies.size()):
		var body := selected_bodies[actor_index]
		var npc_entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
		var order: Dictionary = npc_entry.get("scriptedOrder", {}) if npc_entry.get("scriptedOrder", {}) is Dictionary else {}
		var owner: Dictionary = adapter.call("building_support_for_position", body.global_position, CELL * 0.92) as Dictionary if adapter != null and adapter.has_method("building_support_for_position") else {}
		var owner_certified := String(owner.get("id", "")) == expected_target_owners[actor_index]
		all_endpoint_owners_certified = all_endpoint_owners_certified and owner_certified
		var owner_sequence: Array = owner_sequences.get(actor_ids[actor_index], []) as Array
		var source_owner_index := owner_sequence.find(expected_source_owners[actor_index])
		var target_owner_index := owner_sequence.find(expected_target_owners[actor_index])
		var seam_crossing_certified := seam_crossings.has(actor_ids[actor_index]) \
			and source_owner_index >= 0 \
			and target_owner_index > source_owner_index \
			and float(maximum_lane_deviation.get(actor_ids[actor_index], INF)) <= 0.55 \
			and int(matched_crowd_callback_frames.get(actor_ids[actor_index], 0)) > 0
		all_seam_crossings_certified = all_seam_crossings_certified and seam_crossing_certified
		actor_results.append({"actorId": actor_ids[actor_index], "source": source_positions[actor_index], "target": targets[actor_index], "finalPosition": body.global_position, "targetDistance": Vector2(body.global_position.x - targets[actor_index].x, body.global_position.z - targets[actor_index].z).length(), "orderState": String(order.get("state", "")), "expectedSourceSupportId": expected_source_owners[actor_index], "expectedTargetSupportId": expected_target_owners[actor_index], "actualTargetSupportId": String(owner.get("id", "")), "endpointOwnerCertified": owner_certified, "ownerSequence": owner_sequence, "seamCrossing": seam_crossings.get(actor_ids[actor_index], {}), "maximumLaneDeviation": float(maximum_lane_deviation.get(actor_ids[actor_index], INF)), "matchedCrowdCallbackFrames": int(matched_crowd_callback_frames.get(actor_ids[actor_index], 0)), "seamCrossingCertified": seam_crossing_certified, "routeLease": (npc_entry.get("routeLease", {}) as Dictionary).duplicate(true), "avoidance": (npc_entry.get("routeLeaseAvoidance", {}) as Dictionary).duplicate(true)})
	var required_separation := npc_body_collision_radius(selected_bodies[0]) + npc_body_collision_radius(selected_bodies[1])
	var orca_callbacks_certified := int(crowd_stats_after.get("computeCalls", 0)) > int(crowd_stats_before.get("computeCalls", 0)) and int(crowd_stats_after.get("registeredAgents", 0)) >= 2 and matched_crowd_callback_frames.values().all(func(value) -> bool: return int(value) > 0)
	var passed := bool(wait_admission.get("allAccepted", false)) and bool(crossing_admission.get("allAccepted", false)) and all_pre_act_owners_certified and stable_arrival_frames >= 12 and all_endpoint_owners_certified and all_seam_crossings_certified and airborne_frames.is_empty() and actor_collision_frames.is_empty() and active_transition_frames.is_empty() and scripted_action_frames.is_empty() and maximum_active_traffic_reservations == 0 and minimum_separation + 0.015 >= required_separation and midpoint_capture_taken and orca_callbacks_certified
	surface_continuity_acceptance_result = {"passed": passed, "reason": "" if passed else "surface_continuity_live_actor_contract_failed", "evidenceBoundary": "Actors are placed only before the act; production public go_to orders, planner, collision-backed lease executor, CharacterBody3D motor and ORCA own every crossing frame.", "seamCertificate": certificate.duplicate(true), "waitAdmission": wait_admission, "crossingAdmission": crossing_admission, "placements": placements, "preActOwnerCertifications": pre_act_owner_certifications, "actors": actor_results, "sampledPhysicsFrames": sampled_frames, "stableArrivalFrames": stable_arrival_frames, "airborneFrames": airborne_frames, "actorCollisionFrames": actor_collision_frames, "activeTransitionFrames": active_transition_frames, "scriptedActionFrames": scripted_action_frames, "maximumActiveTrafficReservations": maximum_active_traffic_reservations, "minimumSeparation": minimum_separation, "requiredSeparation": required_separation, "midpointCaptureTaken": midpoint_capture_taken, "seamCrossings": seam_crossings, "ownerSequences": owner_sequences, "maximumLaneDeviation": maximum_lane_deviation, "matchedCrowdCallbackFrames": matched_crowd_callback_frames, "orcaCallbacksCertified": orca_callbacks_certified, "crowdStatsBefore": crowd_stats_before, "crowdStatsAfter": crowd_stats_after}
	crowd_stress_active = false


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
	acceptance_door_lifecycle.clear()
	acceptance_day_door_lifecycle.clear()
	acceptance_day_route_commitment.clear()
	acceptance_door_lifecycle_capture_ids.clear()
	acceptance_day_started_msec = Time.get_ticks_msec()
	acceptance_day_started_physics_frame = Engine.get_physics_frames()
	record_door_lifecycle_observations("acceptance_start")
	civic_order_round = 0
	set_world_display_hour(11.0)
	refresh_world_phase(true)
	var day_generation := civic_order_generation
	acceptance_day_generation = day_generation
	var day_commitment := await await_day_departure_route_commitment(day_generation, DAY_ROUTE_COMMITMENT_SECONDS)
	acceptance_day_route_commitment = day_commitment.duplicate(true)
	var day_admission: Dictionary = day_commitment.get("admission", {}) if day_commitment.get("admission", {}) is Dictionary else {}
	acceptance_order_admissions["day"] = day_admission.duplicate(true)
	acceptance_timeline.append({
		"label": "day_civic_order_admission",
		"processFrame": Engine.get_process_frames(),
		"physicsFrame": Engine.get_physics_frames(),
		"civicOrderAdmission": day_admission.duplicate(true)
	})
	acceptance_timeline.append({
		"label": "day_civic_route_commitment",
		"processFrame": Engine.get_process_frames(),
		"physicsFrame": Engine.get_physics_frames(),
		"dayRouteCommitment": day_commitment.duplicate(true)
	})
	if not bool(day_commitment.get("passed", false)):
		acceptance_day_door_lifecycle = acceptance_door_lifecycle.duplicate(true)
		acceptance_result = {
			"passed": false,
			"reason": "Citadel civic departures did not publish accepted collision-backed leases for every resident",
			"phase": "day_civic_route_commitment",
			"dayRouteCommitment": day_commitment,
			"dayDoorLifecycleTrace": compact_door_lifecycle_map(acceptance_day_door_lifecycle)
		}
		write_profile_report("failed", String(acceptance_result.get("reason", "")))
		return
	var day_budget := acceptance_day_observation_budget(day_commitment)
	acceptance_timeline.append({
		"label": "day_civic_time_budget",
		"processFrame": Engine.get_process_frames(),
		"physicsFrame": Engine.get_physics_frames(),
		"dayBudget": day_budget.duplicate(true)
	})
	await acceptance_observation_phase("day_civic", float(day_budget.get("effectiveSeconds", acceptance_day_seconds)), "day_civic")
	var day_snapshot: Dictionary = citizen_observation_snapshot("day_civic_complete")
	acceptance_timeline.append(day_snapshot)
	record_door_lifecycle_observations("day_civic_complete")
	var day_lifecycle_evidence := day_departure_lifecycle_evidence_map()
	var day_departures_complete := _observation_all_civic_departures_complete(day_snapshot)
	acceptance_day_door_lifecycle = acceptance_door_lifecycle.duplicate(true)
	acceptance_door_lifecycle.clear()
	await capture_representative_citizen_view("day_civic_citizen", day_snapshot)
	await capture_closest_crowd_pair_view("day_civic_closest_pair", day_snapshot)
	await capture_route_failure_evidence(day_snapshot)
	write_profile_report("acceptance_day_civic_checkpoint")
	if not day_departures_complete:
		acceptance_result = {
			"passed": false,
			"reason": "Citadel civic departures did not complete within their route-derived budget; crowd fixture staging was not started",
			"phase": "day_civic",
			"dayBudget": day_budget,
			"daySnapshot": day_snapshot,
			"dayLifecycleEvidence": day_lifecycle_evidence
		}
		write_profile_report("failed", String(acceptance_result.get("reason", "")))
		return
	var lineup_preview := stage_crowd_crossing_orders(false, {}, false)
	var preview_source_positions: Dictionary = lineup_preview.get("targets", {}) if lineup_preview.get("targets", {}) is Dictionary else {}
	var crossing_preview := stage_crowd_crossing_orders(true, preview_source_positions, false)
	acceptance_timeline.append({
		"label": "crowd_fixture_route_preflight",
		"processFrame": Engine.get_process_frames(),
		"physicsFrame": Engine.get_physics_frames(),
		"lineupPreview": lineup_preview.duplicate(true),
		"crossingPreview": crossing_preview.duplicate(true)
	})
	if not bool(lineup_preview.get("ok", false)) or not bool(crossing_preview.get("ok", false)):
		acceptance_result = {
			"passed": false,
			"reason": "Crowd fixture route preflight failed; no wait orders or safe-placement teleports were published",
			"phase": "crowd_fixture_route_preflight",
			"lineupPreview": lineup_preview,
			"crossingPreview": crossing_preview
		}
		write_profile_report("failed", String(acceptance_result.get("reason", "")))
		return
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
		if bool(crossing_setup.get("ok", false)):
			var crossing_generation := civic_order_generation
			crossing_admission = await await_civic_order_batch_admission("crowd_crossing", crossing_generation)
			await acceptance_observation_phase("crowd_crossing", CROWD_CROSSING_SECONDS, "crowd_crossing")
			var crossing_snapshot := citizen_observation_snapshot("crowd_crossing_complete")
			acceptance_timeline.append(crossing_snapshot)
			await capture_closest_crowd_pair_view("crowd_crossing_closest_pair", crossing_snapshot)
			await capture_closest_crowd_pair_view("crowd_final_docking", crossing_snapshot)
	crowd_stress_result = crowd_crossing_summary(crossing_start_positions, lineup_setup, lineup_admission, crossing_setup, crossing_admission)
	crowd_stress_active = false
	write_profile_report("acceptance_crowd_crossing_checkpoint")
	acceptance_door_lifecycle.clear()
	set_world_display_hour(19.0)
	refresh_world_phase(true)
	acceptance_night_started_msec = Time.get_ticks_msec()
	var night_generation := civic_order_generation
	var night_admission := await await_civic_order_batch_admission("night", night_generation)
	acceptance_order_admissions["night"] = night_admission.duplicate(true)
	acceptance_timeline.append({
		"label": "night_home_order_admission",
		"processFrame": Engine.get_process_frames(),
		"physicsFrame": Engine.get_physics_frames(),
		"civicOrderAdmission": night_admission.duplicate(true)
	})
	await wait_physics_frames(NIGHT_HOME_ROUTE_SETTLE_FRAMES)
	var night_budget := acceptance_night_observation_budget()
	acceptance_timeline.append({
		"label": "night_home_time_budget",
		"processFrame": Engine.get_process_frames(),
		"physicsFrame": Engine.get_physics_frames(),
		"nightBudget": night_budget.duplicate(true)
	})
	write_profile_report("acceptance_night_admission_checkpoint")
	await acceptance_observation_phase("night_home", float(night_budget.get("effectiveSeconds", acceptance_night_seconds)), "night_home")
	var final_snapshot: Dictionary = citizen_observation_snapshot("night_home_complete")
	acceptance_timeline.append(final_snapshot)
	record_door_lifecycle_observations("night_home_complete")
	acceptance_night_progress = night_home_progress_evidence()
	acceptance_door_lifecycle_summary = door_lifecycle_acceptance_evidence(acceptance_day_door_lifecycle, acceptance_door_lifecycle)
	acceptance_timeline.append({
		"label": "night_home_progress_evidence",
		"processFrame": Engine.get_process_frames(),
		"physicsFrame": Engine.get_physics_frames(),
		"nightProgress": acceptance_night_progress.duplicate(true)
	})
	acceptance_timeline.append({
		"label": "door_lifecycle_evidence",
		"processFrame": Engine.get_process_frames(),
		"physicsFrame": Engine.get_physics_frames(),
		"doorLifecycle": acceptance_door_lifecycle_summary.duplicate(true)
	})
	write_profile_report("acceptance_night_observation_checkpoint")
	await capture_representative_citizen_view("night_home_citizen", final_snapshot)
	acceptance_post_navigation_audit = post_acceptance_navigation_audit(final_snapshot)
	acceptance_result = acceptance_summary(final_snapshot, day_snapshot, acceptance_order_admissions)
	write_profile_report("completed" if bool(acceptance_result.get("passed", false)) else "failed", String(acceptance_result.get("reason", "")))


func acceptance_night_observation_budget() -> Dictionary:
	var route_distances := {}
	var maximum_route_distance := 0.0
	var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
	var navmesh_world = autonomy.get("navmesh_world") if autonomy != null else null
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		var actor_id := String(manifest.get("id", body.name if body != null else ""))
		if actor_id.is_empty() or navmesh_world == null or not navmesh_world.has_method("actor_path_status"):
			continue
		var path_status: Dictionary = navmesh_world.call("actor_path_status", actor_id) as Dictionary
		var route_distance := maxf(0.0, float(path_status.get("distance", 0.0)))
		if route_distance <= 0.0:
			continue
		route_distances[actor_id] = route_distance
		maximum_route_distance = maxf(maximum_route_distance, route_distance)
	var route_seconds := maximum_route_distance / NIGHT_HOME_MIN_PROGRESS_MPS + NIGHT_HOME_ROUTE_OVERHEAD_SECONDS
	var effective_seconds := clampf(maxf(acceptance_night_seconds, route_seconds), acceptance_night_seconds, NIGHT_HOME_MAX_SECONDS)
	return {
		"requestedSeconds": acceptance_night_seconds,
		"effectiveSeconds": effective_seconds,
		"maximumSeconds": NIGHT_HOME_MAX_SECONDS,
		"minimumProgressMps": NIGHT_HOME_MIN_PROGRESS_MPS,
		"routeOverheadSeconds": NIGHT_HOME_ROUTE_OVERHEAD_SECONDS,
		"maximumRouteDistance": maximum_route_distance,
		"routeDistances": route_distances
	}


func acceptance_day_observation_budget(commitment: Dictionary) -> Dictionary:
	var route_distances: Dictionary = commitment.get("committedRouteLengths", {}) if commitment.get("committedRouteLengths", {}) is Dictionary else {}
	var maximum_route_distance := maxf(0.0, float(commitment.get("maximumRouteLength", 0.0)))
	var route_seconds := maximum_route_distance / DAY_DEPARTURE_MIN_PROGRESS_MPS + DAY_DEPARTURE_ROUTE_OVERHEAD_SECONDS
	return {
		"requestedSeconds": acceptance_day_seconds,
		"effectiveSeconds": clampf(maxf(acceptance_day_seconds, route_seconds), acceptance_day_seconds, DAY_DEPARTURE_MAX_SECONDS),
		"maximumSeconds": DAY_DEPARTURE_MAX_SECONDS,
		"minimumProgressMps": DAY_DEPARTURE_MIN_PROGRESS_MPS,
		"routeOverheadSeconds": DAY_DEPARTURE_ROUTE_OVERHEAD_SECONDS,
		"maximumRouteDistance": maximum_route_distance,
		"routeDistances": route_distances.duplicate(true),
		"source": "accepted_collision_backed_route_lease_waypoints"
	}


func await_day_departure_route_commitment(day_generation: int, publication_timeout_seconds: float) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var committed_actors := {}
	var committed_route_lengths := {}
	var route_chains := {}
	var actor_diagnostics := {}
	var expected_orders := {}
	var admitted_batch := {}
	var admission_timed_out := false
	while float(Time.get_ticks_usec() - started_usec) / 1000000.0 < publication_timeout_seconds:
		admitted_batch = civic_order_batch_snapshot(day_generation)
		for submission_value in admitted_batch.get("submissions", []) as Array:
			if not (submission_value is Dictionary):
				continue
			var submission: Dictionary = submission_value as Dictionary
			if bool(submission.get("accepted", false)):
				expected_orders[String(submission.get("actorId", ""))] = String(submission.get("orderId", ""))
		actor_diagnostics.clear()
		for citizen_entry in citizens:
			var body := valid_citizen_body(citizen_entry)
			var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
			var actor_id := String(manifest.get("id", body.name if body != null else ""))
			if body == null or actor_id.is_empty():
				continue
			var npc_entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
			var order: Dictionary = npc_entry.get("scriptedOrder", {}) if npc_entry.get("scriptedOrder", {}) is Dictionary else {}
			var lease: Dictionary = npc_entry.get("routeLease", {}) if npc_entry.get("routeLease", {}) is Dictionary else {}
			var intent: Dictionary = npc_entry.get("_routineRouteV2Intent", {}) if npc_entry.get("_routineRouteV2Intent", {}) is Dictionary else {}
			var autonomy = npc_system.get("autonomy_system")
			var navmesh_world = autonomy.get("navmesh_world") if autonomy != null else null
			var route_authority = autonomy.get("route_authority_v2") if autonomy != null else null
			var authority_debug: Dictionary = autonomy.call("route_authority_v2_debug_for_entry", npc_entry) as Dictionary if autonomy != null and autonomy.has_method("route_authority_v2_debug_for_entry") else {}
			var certificate: Dictionary = lease.get("probeCertificate", {}) if lease.get("probeCertificate", {}) is Dictionary else {}
			var endpoint_policy: Dictionary = lease.get("endpointPolicy", {}) if lease.get("endpointPolicy", {}) is Dictionary else {}
			var waypoints: Array = lease.get("waypoints", []) if lease.get("waypoints", []) is Array else []
			var order_target_value = order.get("target", Vector3.INF)
			var order_target: Vector3 = order_target_value as Vector3 if order_target_value is Vector3 else Vector3.INF
			var intent_target_value = intent.get("target", Vector3.INF)
			var intent_target: Vector3 = intent_target_value as Vector3 if intent_target_value is Vector3 else Vector3.INF
			var endpoint_certificate := {}
			if intent_target.is_finite() and not waypoints.is_empty() and waypoints.back() is Vector3:
				var final_waypoint: Vector3 = waypoints.back() as Vector3
				var target_snap_distance := float(endpoint_policy.get("targetMaxSnapDistance", INF))
				if navmesh_world != null and navmesh_world.has_method("certify_route_endpoint") and is_finite(target_snap_distance) and target_snap_distance > 0.0:
					endpoint_certificate = navmesh_world.call("certify_route_endpoint", final_waypoint, intent_target, endpoint_policy) as Dictionary
			var final_matches := bool(endpoint_certificate.get("ok", false))
			var current_request_id := String(npc_entry.get("routineRouteV2RequestId", ""))
			var expected_order_id := String(expected_orders.get(actor_id, ""))
			var current_order_bound := not expected_order_id.is_empty() \
				and String(order.get("id", "")) == expected_order_id \
				and String(order.get("kind", "")) == "go_to"
			var current_request_bound := not current_request_id.is_empty() \
				and String(authority_debug.get("requestId", "")) == current_request_id \
				and int(authority_debug.get("generation", -1)) == int(lease.get("generation", -2))
			var semantic_kind := String(intent.get("semanticKind", ""))
			var intent_reason := String(intent.get("reason", ""))
			var current_intent_bound := String(intent.get("kind", "")) == "scripted" \
				and order_target.is_finite() and intent_target.is_finite() \
				and ((semantic_kind == "home_departure_clearance" and intent_reason == "scripted_departure_home_exit") \
					or (semantic_kind == "scripted_target" and intent_reason == "scripted_go_to" and intent_target.distance_to(order_target) <= 0.01))
			var authority_proof: Dictionary = authority_debug.get("proof", {}) if authority_debug.get("proof", {}) is Dictionary else {}
			var accepted_collision_backed := String(lease.get("state", "")) == "ready" \
				and not String(lease.get("leaseId", "")).is_empty() \
				and String(lease.get("ownerNpcId", "")) == actor_id \
				and current_order_bound \
				and current_request_bound \
				and current_intent_bound \
				and bool(authority_proof.get("ok", false)) \
				and bool(authority_proof.get("authoritative", false)) \
				and bool(authority_proof.get("collisionBacked", false)) \
				and bool(certificate.get("ok", false)) \
				and bool(certificate.get("authoritative", false)) \
				and String(certificate.get("status", "")) == "passed" \
				and final_matches
			var route_length := route_waypoint_length(body.global_position, waypoints)
			var chain: Dictionary = route_chains.get(actor_id, {"orderId": expected_order_id}) if route_chains.get(actor_id, {}) is Dictionary else {"orderId": expected_order_id}
			if String(chain.get("orderId", "")).is_empty() and not expected_order_id.is_empty():
				chain["orderId"] = expected_order_id
			var generation := int(lease.get("generation", -1))
			var porch_target_value = npc_entry.get("porchPosition", Vector3.INF)
			var porch_target: Vector3 = porch_target_value as Vector3 if porch_target_value is Vector3 else Vector3.INF
			var door_snapshot := door_lifecycle_snapshot(npc_entry, body)
			var home_portal = door_portal_for_lifecycle(autonomy, door_snapshot)
			var door_exterior_value = npc_entry.get("doorExteriorPosition", Vector3.INF)
			var door_exterior: Vector3 = door_exterior_value as Vector3 if door_exterior_value is Vector3 else Vector3.INF
			var clearance_target := HomeInteriorServiceScript.exterior_clearance_target(npc_entry, home_portal, door_exterior, DOOR_CLEARANCE_ARRIVAL_RADIUS) if home_portal != null and door_exterior.is_finite() else Vector3.INF
			var door_target_certificate := certify_expected_route_target(navmesh_world, intent_target, porch_target, endpoint_policy)
			var clearance_target_certificate := certify_expected_route_target(navmesh_world, intent_target, clearance_target, endpoint_policy)
			var matches_door_target := strict_position_matches(intent_target, porch_target) and bool(door_target_certificate.get("ok", false))
			var matches_clearance_target := strict_position_matches(intent_target, clearance_target) and bool(clearance_target_certificate.get("ok", false))
			if accepted_collision_backed and semantic_kind == "home_departure_clearance":
				record_day_departure_stage(chain, "door" if matches_door_target else ("clearance" if matches_clearance_target else "other"), current_request_id, generation)
			var leg := {
					"physicsFrame": Engine.get_physics_frames(),
					"orderId": String(order.get("id", "")),
					"requestId": current_request_id,
					"leaseId": String(lease.get("leaseId", "")),
					"generation": generation,
					"source": String(lease.get("source", "")),
					"semanticKind": semantic_kind,
					"reason": intent_reason,
					"target": intent_target,
					"routeLength": route_length,
					"probeCertificate": certificate.duplicate(true),
					"endpointCertificate": endpoint_certificate.duplicate(true)
				}
			leg["portalId"] = String(door_snapshot.get("portalId", ""))
			var door_edges: Array = authority_proof.get("doorProbeEdges", []) if authority_proof.get("doorProbeEdges", []) is Array else []
			var owns_door_edge := route_proof_owns_portal(door_edges, String(npc_entry.get("doorPortalId", "")))
			var door_exit_history := route_request_runtime(route_authority, String((chain.get("doorExit", {}) as Dictionary).get("requestId", "")))
			var door_exit_handoff := day_door_leg_handoff_observed(
				actor_id,
				expected_order_id,
				chain.get("doorExit", {}) as Dictionary,
				current_request_id,
				generation,
				String(lease.get("leaseId", "")),
				door_exit_history
			)
			var direct_clearance_transaction := matches_clearance_target and day_direct_clearance_transaction_observed(
				actor_id,
				expected_order_id,
				current_request_id,
				generation,
				String(lease.get("leaseId", "")),
				String(door_snapshot.get("portalId", ""))
			)
			var candidate_leg_kind := classify_day_departure_chain_leg(chain, {
				"accepted": accepted_collision_backed,
				"semanticKind": semantic_kind,
				"matchesDoorTarget": matches_door_target,
				"matchesClearanceTarget": matches_clearance_target,
				"ownsDoorEdge": owns_door_edge,
				"requestId": current_request_id,
				"generation": generation,
				"doorExitHandoff": door_exit_handoff,
				"directDoorClearance": direct_clearance_transaction,
				"stageCycleDetected": bool(chain.get("stageCycleDetected", false)),
				"exteriorClearanceArrived": route_request_has_arrived(route_authority, String((chain.get("exteriorClearance", {}) as Dictionary).get("requestId", ""))) \
					or day_clearance_release_observed(actor_id, expected_order_id, chain)
			})
			if accepted_collision_backed and candidate_leg_kind.is_empty() and chain.has("doorExit"):
				var rejected_candidates: Array = chain.get("rejectedCandidates", []) if chain.get("rejectedCandidates", []) is Array else []
				var rejected_candidate := {
						"physicsFrame": Engine.get_physics_frames(),
						"requestId": current_request_id,
						"generation": generation,
						"semanticKind": semantic_kind,
						"intentTarget": intent_target,
						"expectedDoorTarget": porch_target,
						"expectedClearanceTarget": clearance_target,
						"matchesDoorTarget": matches_door_target,
						"matchesClearanceTarget": matches_clearance_target,
						"doorExitHandoff": door_exit_handoff,
						"doorExitHistory": door_exit_history,
						"exteriorClearanceHistory": route_request_runtime(route_authority, String((chain.get("exteriorClearance", {}) as Dictionary).get("requestId", "")))
					}
				var existing_rejection_index := -1
				for rejection_index in range(rejected_candidates.size()):
					if rejected_candidates[rejection_index] is Dictionary \
							and String((rejected_candidates[rejection_index] as Dictionary).get("requestId", "")) == current_request_id:
						existing_rejection_index = rejection_index
						break
				if existing_rejection_index >= 0:
					rejected_candidates[existing_rejection_index] = rejected_candidate
				elif rejected_candidates.size() < 12:
					rejected_candidates.append(rejected_candidate)
				chain["rejectedCandidates"] = rejected_candidates
			if accepted_collision_backed:
				if candidate_leg_kind == "doorExit":
					chain["doorExit"] = leg.duplicate(true)
				elif candidate_leg_kind == "exteriorClearance":
					chain["exteriorClearance"] = leg.duplicate(true)
				elif candidate_leg_kind == "directClearance":
					chain["doorExit"] = leg.duplicate(true)
					chain["exteriorClearance"] = leg.duplicate(true)
					chain["directClearanceTransaction"] = true
				elif candidate_leg_kind == "civicTarget":
					chain["civicTarget"] = leg.duplicate(true)
			route_chains[actor_id] = chain
			if chain.has("doorExit") and chain.has("exteriorClearance") and chain.has("civicTarget") and not committed_actors.has(actor_id):
				committed_actors[actor_id] = chain.duplicate(true)
				committed_route_lengths[actor_id] = float((chain.get("exteriorClearance", {}) as Dictionary).get("routeLength", 0.0)) \
					+ float((chain.get("civicTarget", {}) as Dictionary).get("routeLength", 0.0))
				if not bool(chain.get("directClearanceTransaction", false)):
					committed_route_lengths[actor_id] += float((chain.get("doorExit", {}) as Dictionary).get("routeLength", 0.0))
			actor_diagnostics[actor_id] = {
				"expectedOrderId": expected_order_id,
				"orderId": String(order.get("id", "")),
				"orderState": String(order.get("state", "")),
				"orderTarget": order_target,
				"departureTarget": intent_target,
				"leaseId": String(lease.get("leaseId", "")),
				"leaseState": String(lease.get("state", "")),
				"leaseOwnerNpcId": String(lease.get("ownerNpcId", "")),
				"leaseSource": String(lease.get("source", "")),
				"currentOrderBound": current_order_bound,
				"currentRequestId": current_request_id,
				"authorityRequestId": String(authority_debug.get("requestId", "")),
				"currentRequestBound": current_request_bound,
				"currentIntentBound": current_intent_bound,
				"intent": intent.duplicate(true),
				"authorityProof": authority_proof.duplicate(true),
				"waypointCount": waypoints.size(),
				"waypointLength": route_length,
				"finalMatchesOrderTarget": final_matches,
				"matchesDoorExitTarget": matches_door_target,
				"matchesExteriorClearanceTarget": matches_clearance_target,
				"doorExitTargetCertificate": door_target_certificate.duplicate(true),
				"exteriorClearanceTargetCertificate": clearance_target_certificate.duplicate(true),
				"ownsResidentDoorEdge": owns_door_edge,
				"endpointCertificate": endpoint_certificate.duplicate(true),
				"endpointPolicy": endpoint_policy.duplicate(true),
				"probeCertificate": certificate.duplicate(true),
				"routeChain": chain.duplicate(true),
				"commitmentLatched": committed_actors.get(actor_id, {})
			}
		if committed_actors.size() == citizens.size() and bool(admitted_batch.get("drained", false)):
			break
		if not bool(admitted_batch.get("drained", false)) and float(Time.get_ticks_usec() - started_usec) / 1000.0 >= ACCEPTANCE_ORDER_ADMISSION_TIMEOUT_MS:
			admission_timed_out = true
			break
		record_door_lifecycle_observations("day_civic")
		await get_tree().physics_frame
	admitted_batch = civic_order_batch_snapshot(day_generation)
	var admission_timely := not admission_timed_out \
		and bool(admitted_batch.get("allAccepted", false)) \
		and int(admitted_batch.get("processFrames", ACCEPTANCE_ORDER_ADMISSION_MAX_PROCESS_FRAMES + 1)) <= ACCEPTANCE_ORDER_ADMISSION_MAX_PROCESS_FRAMES
	decorate_order_admission_timing(admitted_batch, admission_timed_out)
	var maximum_route_length := 0.0
	for route_length_value in committed_route_lengths.values():
		maximum_route_length = maxf(maximum_route_length, float(route_length_value))
	var passed := admission_timely and committed_actors.size() == citizens.size() and not committed_actors.is_empty()
	return {
		"passed": passed,
		"reason": "" if passed else (String(admitted_batch.get("reason", "")) if not admission_timely else "day_route_publication_timeout"),
		"committedCount": committed_actors.size(),
		"expectedCount": citizens.size(),
		"elapsedMs": float(Time.get_ticks_usec() - started_usec) / 1000.0,
		"maximumRouteLength": maximum_route_length,
		"committedActors": committed_actors.duplicate(true),
		"committedRouteLengths": committed_route_lengths.duplicate(true),
		"routeChains": route_chains.duplicate(true),
		"admission": admitted_batch.duplicate(true),
		"admittedBatch": admitted_batch.duplicate(true),
		"actorDiagnostics": actor_diagnostics.duplicate(true)
	}


func route_waypoint_length(start_position: Vector3, waypoints: Array) -> float:
	var length := 0.0
	var previous := start_position
	for waypoint_value in waypoints:
		if not (waypoint_value is Vector3):
			continue
		var waypoint: Vector3 = waypoint_value as Vector3
		length += Vector2(previous.x - waypoint.x, previous.z - waypoint.z).length()
		previous = waypoint
	return length


func classify_day_departure_chain_leg(chain: Dictionary, candidate: Dictionary) -> String:
	if not bool(candidate.get("accepted", false)):
		return ""
	var semantic_kind := String(candidate.get("semanticKind", ""))
	var request_id := String(candidate.get("requestId", ""))
	var generation := int(candidate.get("generation", -1))
	if semantic_kind == "home_departure_clearance" \
			and bool(candidate.get("matchesClearanceTarget", false)) \
			and bool(candidate.get("ownsDoorEdge", false)) \
			and bool(candidate.get("directDoorClearance", false)) \
			and not bool(candidate.get("stageCycleDetected", false)):
		return "directClearance"
	if not chain.has("doorExit"):
		return "doorExit" if semantic_kind == "home_departure_clearance" \
			and bool(candidate.get("matchesDoorTarget", false)) \
			and bool(candidate.get("ownsDoorEdge", false)) else ""
	var door_leg: Dictionary = chain.get("doorExit", {}) as Dictionary
	if not chain.has("exteriorClearance"):
		return "exteriorClearance" if semantic_kind == "home_departure_clearance" \
			and bool(candidate.get("matchesClearanceTarget", false)) \
			and request_id != String(door_leg.get("requestId", "")) \
			and generation > int(door_leg.get("generation", -1)) \
			and bool(candidate.get("doorExitHandoff", false)) else ""
	var clearance_leg: Dictionary = chain.get("exteriorClearance", {}) as Dictionary
	if not chain.has("civicTarget"):
		return "civicTarget" if semantic_kind == "scripted_target" \
			and request_id != String(clearance_leg.get("requestId", "")) \
			and generation > int(clearance_leg.get("generation", -1)) \
			and bool(candidate.get("exteriorClearanceArrived", false)) else ""
	return ""

func record_day_departure_stage(chain: Dictionary, stage_kind: String, request_id: String, generation: int) -> void:
	if stage_kind not in ["door", "clearance"] or request_id.is_empty() or generation < 0:
		return
	var history: Array = chain.get("departureStageHistory", []) if chain.get("departureStageHistory", []) is Array else []
	if not history.is_empty() and history.back() is Dictionary and String((history.back() as Dictionary).get("requestId", "")) == request_id:
		return
	var previous_kind := String((history.back() as Dictionary).get("kind", "")) if not history.is_empty() and history.back() is Dictionary else ""
	if previous_kind == "clearance" and stage_kind == "door":
		chain["stageCycleDetected"] = true
	history.append({"kind": stage_kind, "requestId": request_id, "generation": generation})
	chain["departureStageHistory"] = history


func strict_position_matches(first: Vector3, second: Vector3, tolerance := 0.03) -> bool:
	return first.is_finite() and second.is_finite() and first.distance_to(second) <= tolerance


func certify_expected_route_target(navmesh_world, intent_target: Vector3, expected_target: Vector3, endpoint_policy: Dictionary) -> Dictionary:
	if navmesh_world == null or not navmesh_world.has_method("certify_route_endpoint") \
			or not intent_target.is_finite() or not expected_target.is_finite():
		return {"ok": false, "reason": "expected_target_authority_unavailable"}
	var target_snap_distance := float(endpoint_policy.get("targetMaxSnapDistance", INF))
	if not is_finite(target_snap_distance) or target_snap_distance <= 0.0:
		return {"ok": false, "reason": "missing_target_snap_policy"}
	return navmesh_world.call("certify_route_endpoint", intent_target, expected_target, endpoint_policy) as Dictionary


func route_proof_owns_portal(door_edges: Array, portal_id: String) -> bool:
	if portal_id.is_empty():
		return false
	for edge_value in door_edges:
		if edge_value is Dictionary and String((edge_value as Dictionary).get("portalId", "")) == portal_id:
			return true
	return false


func day_door_leg_handoff_observed(actor_id: String, order_id: String, door_leg: Dictionary, successor_request_id: String, successor_generation: int, successor_lease_id: String, door_exit_history: Dictionary) -> bool:
	if actor_id.is_empty() or order_id.is_empty() or door_leg.is_empty() or successor_request_id.is_empty() or successor_generation < 0 or successor_lease_id.is_empty():
		return false
	if not valid_door_exit_supersession(door_exit_history):
		return false
	var tracker: Dictionary = acceptance_door_lifecycle.get(actor_id, {}) if acceptance_door_lifecycle.get(actor_id, {}) is Dictionary else {}
	var initiating_request_id := String(door_leg.get("requestId", ""))
	var initiating_generation := int(door_leg.get("generation", -1))
	var initiating_lease_id := String(door_leg.get("leaseId", ""))
	var portal_id := String(door_leg.get("portalId", ""))
	if initiating_lease_id.is_empty():
		return false
	var interior_side := manifest_door_plane_side(actor_id, true)
	var crossing_id := ""
	var traffic_group_id := ""
	var previous_frame := -1
	for event_value in tracker.get("events", []) as Array:
		if not (event_value is Dictionary):
			continue
		var event: Dictionary = event_value as Dictionary
		if String(event.get("phase", "")) != "day_civic" \
				or String(event.get("scriptedOrderId", "")) != order_id:
			continue
		if String(event.get("crossingInitiatingRequestId", "")) != initiating_request_id \
				or int(event.get("crossingInitiatingGeneration", -1)) != initiating_generation \
				or String(event.get("crossingInitiatingLeaseId", "")) != initiating_lease_id:
			if not crossing_id.is_empty():
				return false
			continue
		var event_crossing_id := String(event.get("crossingId", ""))
		var event_traffic_group_id := String(event.get("crossingTrafficGroupId", ""))
		if event_crossing_id.is_empty() or event_traffic_group_id.is_empty() \
				or String(event.get("crossingPortalId", "")) != portal_id \
				or String(event.get("activeDoorPortalId", "")) != portal_id \
				or (event.get("crossingReservationIds", []) as Array).is_empty():
			return false
		if not bool((event.get("crossingTrafficContinuity", {}) as Dictionary).get("ok", false)):
			return false
		if crossing_id.is_empty():
			crossing_id = event_crossing_id
			traffic_group_id = event_traffic_group_id
		elif event_crossing_id != crossing_id or event_traffic_group_id != traffic_group_id:
			return false
		var physics_frame := int(event.get("physicsFrame", -1))
		if previous_frame >= 0 and physics_frame != previous_frame + 1:
			return false
		previous_frame = physics_frame
		if not bool(event.get("allLeafCollisionDisabled", false)):
			return false
		var bound_successor_id := String(event.get("crossingSuccessorRequestId", ""))
		if not bound_successor_id.is_empty() and (bound_successor_id != successor_request_id \
				or int(event.get("crossingSuccessorGeneration", -1)) != successor_generation \
				or String(event.get("crossingSuccessorLeaseId", "")) != successor_lease_id):
			return false
		if not bool(event.get("strictInside", false)) \
				and bound_successor_id == successor_request_id \
				and String(event.get("crossingSuccessorLeaseId", "")) == successor_lease_id \
				and String(event.get("routeRequestId", "")) == successor_request_id \
				and int(event.get("routeGeneration", -1)) == successor_generation \
				and String(event.get("routeLeaseId", "")) == successor_lease_id \
				and opposite_door_side(float(event.get("doorPlaneSide", 0.0)), interior_side):
			return true
	return false

func valid_door_exit_supersession(history: Dictionary) -> bool:
	return String(history.get("state", "")) == "cancelled" \
		and String(history.get("reason", "")) == "routine_route_key_changed"

func day_direct_clearance_transaction_observed(actor_id: String, order_id: String, request_id: String, generation: int, lease_id: String, portal_id: String) -> bool:
	if actor_id.is_empty() or order_id.is_empty() or request_id.is_empty() or generation < 0 or lease_id.is_empty() or portal_id.is_empty():
		return false
	var tracker: Dictionary = acceptance_door_lifecycle.get(actor_id, {}) if acceptance_door_lifecycle.get(actor_id, {}) is Dictionary else {}
	var crossing_id := ""
	var traffic_group_id := ""
	var previous_frame := -1
	var interior_side := manifest_door_plane_side(actor_id, true)
	for event_value in tracker.get("events", []) as Array:
		if not (event_value is Dictionary):
			continue
		var event: Dictionary = event_value as Dictionary
		if String(event.get("phase", "")) != "day_civic" or String(event.get("scriptedOrderId", "")) != order_id:
			continue
		if String(event.get("crossingInitiatingRequestId", "")) != request_id \
				or int(event.get("crossingInitiatingGeneration", -1)) != generation \
				or String(event.get("crossingInitiatingLeaseId", "")) != lease_id:
			if not crossing_id.is_empty():
				return false
			continue
		var event_crossing_id := String(event.get("crossingId", ""))
		var event_traffic_group_id := String(event.get("crossingTrafficGroupId", ""))
		if event_crossing_id.is_empty() or event_traffic_group_id.is_empty() \
				or String(event.get("crossingPortalId", "")) != portal_id \
				or String(event.get("activeDoorPortalId", "")) != portal_id \
				or (event.get("crossingReservationIds", []) as Array).is_empty() \
				or not bool((event.get("crossingTrafficContinuity", {}) as Dictionary).get("ok", false)) \
				or not bool(event.get("allLeafCollisionDisabled", false)):
			return false
		if crossing_id.is_empty():
			crossing_id = event_crossing_id
			traffic_group_id = event_traffic_group_id
		elif event_crossing_id != crossing_id or event_traffic_group_id != traffic_group_id:
			return false
		var physics_frame := int(event.get("physicsFrame", -1))
		if previous_frame >= 0 and physics_frame != previous_frame + 1:
			return false
		previous_frame = physics_frame
		if String(event.get("routeRequestId", "")) == request_id \
				and int(event.get("routeGeneration", -1)) == generation \
				and String(event.get("routeLeaseId", "")) == lease_id \
				and String(event.get("crossingSuccessorRequestId", "")).is_empty() \
				and String(event.get("crossingSuccessorLeaseId", "")).is_empty() \
				and not bool(event.get("strictInside", false)) \
				and opposite_door_side(float(event.get("doorPlaneSide", 0.0)), interior_side):
			return true
	return false


func day_clearance_release_observed(actor_id: String, order_id: String, chain: Dictionary) -> bool:
	var door_leg: Dictionary = chain.get("doorExit", {}) if chain.get("doorExit", {}) is Dictionary else {}
	var clearance_leg: Dictionary = chain.get("exteriorClearance", {}) if chain.get("exteriorClearance", {}) is Dictionary else {}
	if actor_id.is_empty() or order_id.is_empty() or door_leg.is_empty() or clearance_leg.is_empty():
		return false
	var direct := bool(chain.get("directClearanceTransaction", false))
	var tracker: Dictionary = acceptance_door_lifecycle.get(actor_id, {}) if acceptance_door_lifecycle.get(actor_id, {}) is Dictionary else {}
	for event_value in tracker.get("events", []) as Array:
		if not (event_value is Dictionary):
			continue
		var event: Dictionary = event_value as Dictionary
		if String(event.get("phase", "")) != "day_civic" or String(event.get("scriptedOrderId", "")) != order_id:
			continue
		var matches := String(event.get("completedCrossingPortalId", "")) == String(door_leg.get("portalId", "")) \
			and String(event.get("completedCrossingInitiatingRequestId", "")) == String(door_leg.get("requestId", "")) \
			and int(event.get("completedCrossingInitiatingGeneration", -1)) == int(door_leg.get("generation", -1)) \
			and String(event.get("completedCrossingInitiatingLeaseId", "")) == String(door_leg.get("leaseId", ""))
		if matches and direct:
			matches = String(event.get("completedCrossingSuccessorRequestId", "")).is_empty() \
				and String(event.get("completedCrossingSuccessorLeaseId", "")).is_empty()
		elif matches:
			matches = String(event.get("completedCrossingSuccessorRequestId", "")) == String(clearance_leg.get("requestId", "")) \
				and int(event.get("completedCrossingSuccessorGeneration", -1)) == int(clearance_leg.get("generation", -1)) \
				and String(event.get("completedCrossingSuccessorLeaseId", "")) == String(clearance_leg.get("leaseId", ""))
		if matches \
				and bool((event.get("completedCrossingTrafficContinuity", {}) as Dictionary).get("ok", false)) \
				and bool(completed_crossing_release_certificate(actor_id, event).get("ok", false)):
			return true
	return false


func route_request_has_arrived(route_authority, request_id: String) -> bool:
	var summary := route_request_runtime(route_authority, request_id)
	if String(summary.get("state", "")) == "arrived":
		return true
	for event_value in summary.get("recentEvents", []) as Array:
		if event_value is Dictionary and String((event_value as Dictionary).get("state", "")) == "arrived":
			return true
	return false


func route_request_runtime(route_authority, request_id: String) -> Dictionary:
	if route_authority == null or request_id.is_empty() or not route_authority.has_method("runtime_for_request"):
		return {"hasRequest": false, "requestId": request_id, "reason": "request_history_unavailable"}
	return route_authority.call("runtime_for_request", request_id) as Dictionary


func acceptance_observation_phase(phase_name: String, duration_seconds: float, capture_prefix: String) -> void:
	profile_begin_stage("acceptance_%s" % phase_name)
	var started_usec := Time.get_ticks_usec()
	var started_physics_frame := Engine.get_physics_frames()
	var duration_frames := maxi(1, ceili(duration_seconds * float(Engine.physics_ticks_per_second)))
	var next_sample_seconds := 0.0
	var capture_index := 0
	var last_progress_seconds := -1
	var last_night_checkpoint_seconds := 0
	while Engine.get_physics_frames() - started_physics_frame < duration_frames:
		var elapsed_seconds := float(Engine.get_physics_frames() - started_physics_frame) / float(Engine.physics_ticks_per_second)
		var elapsed_whole_seconds := int(floor(elapsed_seconds))
		if elapsed_whole_seconds != last_progress_seconds:
			last_progress_seconds = elapsed_whole_seconds
			var wall_elapsed_seconds := float(Time.get_ticks_usec() - started_usec) / 1000000.0
			write_profile_progress("acceptancePhase=%s simulatedElapsed=%.2f wallElapsed=%.2f" % [phase_name, elapsed_seconds, wall_elapsed_seconds])
		if elapsed_seconds >= next_sample_seconds:
			var observation := citizen_observation_snapshot("%s_%02d" % [phase_name, int(floor(elapsed_seconds))])
			acceptance_timeline.append(observation)
			next_sample_seconds += ACCEPTANCE_SNAPSHOT_INTERVAL_SECONDS
			if capture_index < 2 and elapsed_seconds >= float(capture_index) * maxf(3.0, duration_seconds * 0.45):
				await capture_viewport("%s_%d" % [capture_prefix, capture_index + 1])
				capture_index += 1
			if phase_name == "night_home" and _observation_all_citizens_strictly_inside(observation):
				break
			if phase_name == "day_civic" and _observation_all_civic_departures_complete(observation):
				break
		if phase_name == "night_home" \
				and elapsed_whole_seconds >= last_night_checkpoint_seconds + NIGHT_CHECKPOINT_INTERVAL_SECONDS:
			last_night_checkpoint_seconds = elapsed_whole_seconds
			acceptance_night_progress = night_home_progress_evidence()
			write_profile_report("acceptance_night_progress_checkpoint")
		record_door_lifecycle_observations(phase_name)
		await get_tree().physics_frame
	profile_end_stage("acceptance_%s" % phase_name, {
		"activeCitizenCount": citizens.size(),
		"sceneNodeCount": count_scene_nodes(get_tree().root)
	})


func _observation_all_citizens_strictly_inside(observation: Dictionary) -> bool:
	var records: Array = observation.get("citizens", []) if observation.get("citizens", []) is Array else []
	if records.size() != citizens.size() or records.is_empty():
		return false
	for record_value in records:
		if not (record_value is Dictionary) or not bool((record_value as Dictionary).get("physicallyInsideStrictInterior", false)):
			return false
	return true


func _observation_all_civic_departures_complete(observation: Dictionary) -> bool:
	var records: Array = observation.get("citizens", []) if observation.get("citizens", []) is Array else []
	if records.size() != citizens.size() or records.is_empty():
		return false
	for record_value in records:
		if not (record_value is Dictionary):
			return false
		var record: Dictionary = record_value as Dictionary
		if bool(record.get("physicallyInsideStrictInterior", true)):
			return false
		if String(record.get("orderState", "")) != "ARRIVED" or String(record.get("routeStatus", "")) != "arrived":
			return false
		if String(record.get("homeDepartureState", "")) != "outside":
			return false
		var active_door: Dictionary = record.get("activeDoor", {}) if record.get("activeDoor", {}) is Dictionary else {}
		if not String(active_door.get("portalId", "")).is_empty() \
				or not String(active_door.get("trafficGroupId", "")).is_empty() \
				or bool(active_door.get("stageActive", false)) \
				or not String(record.get("activeTrafficStepGroup", "")).is_empty():
			return false
		if not (record.get("activeNavigationTransition", {}) as Dictionary).is_empty():
			return false
		if not day_departure_lifecycle_evidence(String(record.get("id", ""))).get("passed", false):
			return false
	return true


func day_departure_lifecycle_evidence_map() -> Dictionary:
	var result := {}
	for citizen_entry in citizens:
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		var actor_id := String(manifest.get("id", ""))
		if not actor_id.is_empty():
			result[actor_id] = day_departure_lifecycle_evidence(actor_id)
	return result


func day_departure_lifecycle_evidence(actor_id: String) -> Dictionary:
	var tracker: Dictionary = acceptance_door_lifecycle.get(actor_id, {}) if acceptance_door_lifecycle.get(actor_id, {}) is Dictionary else {}
	var events: Array = tracker.get("events", []) if tracker.get("events", []) is Array else []
	var committed_actors: Dictionary = acceptance_day_route_commitment.get("committedActors", {}) if acceptance_day_route_commitment.get("committedActors", {}) is Dictionary else {}
	var commitment: Dictionary = committed_actors.get(actor_id, {}) if committed_actors.get(actor_id, {}) is Dictionary else {}
	var expected_order_id := String(commitment.get("orderId", ""))
	var door_leg: Dictionary = commitment.get("doorExit", {}) if commitment.get("doorExit", {}) is Dictionary else {}
	var clearance_leg: Dictionary = commitment.get("exteriorClearance", {}) if commitment.get("exteriorClearance", {}) is Dictionary else {}
	var civic_leg: Dictionary = commitment.get("civicTarget", {}) if commitment.get("civicTarget", {}) is Dictionary else {}
	var expected_door_request_id := String(door_leg.get("requestId", ""))
	var expected_door_generation := int(door_leg.get("generation", -1))
	var expected_door_lease_id := String(door_leg.get("leaseId", ""))
	var expected_clearance_request_id := String(clearance_leg.get("requestId", ""))
	var expected_clearance_generation := int(clearance_leg.get("generation", -1))
	var expected_clearance_lease_id := String(clearance_leg.get("leaseId", ""))
	var direct_clearance_transaction := bool(commitment.get("directClearanceTransaction", false))
	var day_order_events: Array = events.filter(func(event: Dictionary) -> bool:
		return (String(event.get("phase", "")) == "day_civic" or String(event.get("phase", "")) == "day_civic_complete") \
			and int(event.get("physicsFrame", -1)) >= acceptance_day_started_physics_frame \
			and int(event.get("acceptanceDayGeneration", -1)) == acceptance_day_generation \
			and not expected_order_id.is_empty() and String(event.get("scriptedOrderId", "")) == expected_order_id
	)
	var transaction_events: Array = day_order_events.filter(func(event: Dictionary) -> bool:
		return not expected_door_request_id.is_empty() \
			and String(event.get("crossingInitiatingRequestId", "")) == expected_door_request_id \
			and expected_door_generation > 0 and int(event.get("crossingInitiatingGeneration", -1)) == expected_door_generation \
			and not expected_door_lease_id.is_empty() and String(event.get("crossingInitiatingLeaseId", "")) == expected_door_lease_id
	)
	var clearance_events: Array = day_order_events.filter(func(event: Dictionary) -> bool:
		return not expected_clearance_request_id.is_empty() \
			and String(event.get("routeRequestId", "")) == expected_clearance_request_id \
			and expected_clearance_generation > 0 and int(event.get("routeGeneration", -1)) == expected_clearance_generation \
			and not expected_clearance_lease_id.is_empty() and String(event.get("routeLeaseId", "")) == expected_clearance_lease_id
	)
	var interior_side := manifest_door_plane_side(actor_id, true)
	if is_zero_approx(interior_side):
		interior_side = first_signed_door_side(transaction_events, true)
	var open_index := -1
	var crossing_index := -1
	var clearance_index := -1
	var release_index := -1
	var closed_index := -1
	var crossing_frame := -1
	var clearance_frame := -1
	var clearance_evidence := {}
	var release_certificate := {}
	for index in range(transaction_events.size()):
		if not (transaction_events[index] is Dictionary):
			continue
		var event: Dictionary = transaction_events[index] as Dictionary
		if open_index < 0 and String(event.get("portalState", "")) == "open" and bool(event.get("allLeafCollisionDisabled", false)):
			open_index = index
		if open_index >= 0 and crossing_index < 0 \
				and ((direct_clearance_transaction \
						and expected_door_lease_id == expected_clearance_lease_id \
						and String(event.get("crossingSuccessorRequestId", "")).is_empty() \
						and String(event.get("crossingSuccessorLeaseId", "")).is_empty()) \
					or (String(event.get("crossingSuccessorRequestId", "")) == expected_clearance_request_id \
						and int(event.get("crossingSuccessorGeneration", -1)) == expected_clearance_generation \
						and String(event.get("crossingSuccessorLeaseId", "")) == expected_clearance_lease_id)) \
				and String(event.get("routeRequestId", "")) == expected_clearance_request_id \
				and String(event.get("routeLeaseId", "")) == expected_clearance_lease_id \
				and not bool(event.get("strictInside", false)) \
				and opposite_door_side(float(event.get("doorPlaneSide", 0.0)), interior_side):
			crossing_index = index
			crossing_frame = int(event.get("physicsFrame", -1))
	var crossing_id := String((transaction_events.front() as Dictionary).get("crossingId", "")) if not transaction_events.is_empty() and transaction_events.front() is Dictionary else ""
	for index in range(day_order_events.size()):
		if not (day_order_events[index] is Dictionary):
			continue
		var event: Dictionary = day_order_events[index] as Dictionary
		var completed_matches := not crossing_id.is_empty() \
			and String(event.get("completedCrossingId", "")) == crossing_id \
			and String(event.get("completedCrossingPortalId", "")) == String(door_leg.get("portalId", "")) \
			and String(event.get("completedCrossingInitiatingRequestId", "")) == expected_door_request_id \
			and int(event.get("completedCrossingInitiatingGeneration", -1)) == expected_door_generation \
			and String(event.get("completedCrossingInitiatingLeaseId", "")) == expected_door_lease_id
		if completed_matches and direct_clearance_transaction:
			completed_matches = String(event.get("completedCrossingSuccessorRequestId", "")).is_empty() \
				and String(event.get("completedCrossingSuccessorLeaseId", "")).is_empty()
		elif completed_matches:
			completed_matches = String(event.get("completedCrossingSuccessorRequestId", "")) == expected_clearance_request_id \
				and int(event.get("completedCrossingSuccessorGeneration", -1)) == expected_clearance_generation \
				and String(event.get("completedCrossingSuccessorLeaseId", "")) == expected_clearance_lease_id
		var candidate_release_certificate := completed_crossing_release_certificate(actor_id, event) if completed_matches else {}
		if release_index < 0 and crossing_frame >= 0 and completed_matches \
				and int(event.get("completedCrossingReleaseFrame", -1)) >= crossing_frame \
				and bool(candidate_release_certificate.get("ok", false)) \
				and bool((event.get("completedCrossingTrafficContinuity", {}) as Dictionary).get("ok", false)) \
				and String(event.get("activeDoorPortalId", "")).is_empty() \
				and String(event.get("crossingId", "")).is_empty():
			clearance_index = index
			clearance_frame = int(event.get("completedCrossingReleaseFrame", -1))
			clearance_evidence = (candidate_release_certificate.get("observation", {}) as Dictionary).duplicate(true)
			release_certificate = candidate_release_certificate.duplicate(true)
			release_index = index
		if release_index >= 0 and closed_index < 0 and index >= release_index \
				and String(event.get("portalState", "")) == "closed" \
				and not bool(event.get("collisionDisabled", false)):
			closed_index = index
	var portal_id := String((transaction_events.front() as Dictionary).get("portalId", "")) if not transaction_events.is_empty() and transaction_events.front() is Dictionary else ""
	var trace_end_msec := acceptance_night_started_msec if acceptance_night_started_msec > acceptance_day_started_msec else -1
	var trace := actor_door_lifecycle_trace(actor_id, portal_id, acceptance_day_started_msec, trace_end_msec)
	var open_transition_msec := actor_door_trace_success_msec(trace, ["open", "hold"], "open", expected_door_request_id, expected_door_generation)
	var open_observation_msec := int((transaction_events[open_index] as Dictionary).get("elapsedMsec", -1)) if open_index >= 0 else -1
	var actor_opened := open_transition_msec >= 0 and open_observation_msec >= open_transition_msec
	var collision_clear_before_crossing := open_index >= 0 and crossing_index >= open_index + 1 and interior_side != 0.0
	var clearance_verified := crossing_frame >= 0 and clearance_index >= 0 and bool(clearance_evidence.get("satisfied", false))
	return {
		"passed": not door_leg.is_empty() and not clearance_leg.is_empty() and not civic_leg.is_empty() and actor_opened and collision_clear_before_crossing and clearance_verified and release_index >= 0 and closed_index >= release_index,
		"actorId": actor_id,
		"acceptanceDayGeneration": acceptance_day_generation,
		"acceptanceDayStartedPhysicsFrame": acceptance_day_started_physics_frame,
		"expectedOrderId": expected_order_id,
		"doorExitLeg": door_leg.duplicate(true),
		"exteriorClearanceLeg": clearance_leg.duplicate(true),
		"civicTargetLeg": civic_leg.duplicate(true),
		"dayEventCount": day_order_events.size(),
		"dayDoorEventCount": transaction_events.size(),
		"dayClearanceEventCount": clearance_events.size(),
		"dayInteriorSide": interior_side,
		"dayOpenCollisionClearIndex": open_index,
		"dayExteriorPlaneCrossingIndex": crossing_index,
		"dayExteriorClearanceIndex": clearance_index,
		"dayCrossingReleaseIndex": release_index,
		"dayClosedCollisionRestoredIndex": closed_index,
		"dayActorOpenedDoor": actor_opened,
		"dayCollisionClearObservedBeforeCrossing": collision_clear_before_crossing,
		"dayExteriorClearanceVerified": clearance_verified,
		"dayExteriorClearance": clearance_evidence,
		"dayCompletedCrossingReleaseCertificate": release_certificate,
		"directClearanceTransaction": direct_clearance_transaction,
		"dayOpenTransitionMsec": open_transition_msec,
		"dayActorTrace": compact_door_trace(trace),
		"dayEvents": compact_door_events(day_order_events)
	}


func completed_crossing_release_certificate(actor_id: String, event: Dictionary) -> Dictionary:
	var portal_id := String(event.get("completedCrossingPortalId", ""))
	if actor_id.is_empty() or portal_id.is_empty():
		return {"ok": false, "reason": "missing_completed_crossing_owner"}
	for citizen_entry in citizens:
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		if String(manifest.get("id", "")) != actor_id:
			continue
		var body := valid_citizen_body(citizen_entry)
		if body == null or npc_system == null:
			return {"ok": false, "reason": "missing_completed_crossing_actor"}
		var entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
		var autonomy = npc_system.get("autonomy_system")
		var portal = door_portal_for_lifecycle(autonomy, {"portalId": portal_id})
		return certify_completed_crossing_release(entry, manifest, portal, event)
	return {"ok": false, "reason": "completed_crossing_actor_not_found"}


func certify_completed_crossing_release(entry: Dictionary, manifest: Dictionary, portal, event: Dictionary) -> Dictionary:
	var evidence: Dictionary = event.get("completedCrossingReleaseEvidence", {}) if event.get("completedCrossingReleaseEvidence", {}) is Dictionary else {}
	var position_value = evidence.get("position", Vector3.INF)
	var position: Vector3 = position_value as Vector3 if position_value is Vector3 else Vector3.INF
	var expected_portal_id := String(event.get("completedCrossingPortalId", ""))
	var actual_portal_id := String(portal.get("portal_id")) if portal != null else ""
	if not bool(evidence.get("exteriorClearanceCertified", false)):
		return {"ok": false, "reason": "release_clearance_not_certified"}
	if not position.is_finite():
		return {"ok": false, "reason": "release_position_invalid"}
	if expected_portal_id.is_empty() or actual_portal_id != expected_portal_id:
		return {"ok": false, "reason": "release_portal_mismatch", "expectedPortalId": expected_portal_id, "actualPortalId": actual_portal_id}
	var observation := exterior_clearance_observation(entry, manifest, portal, position)
	return {
		"ok": bool(observation.get("satisfied", false)),
		"reason": "" if bool(observation.get("satisfied", false)) else "release_position_not_exterior_clearance",
		"portalId": expected_portal_id,
		"releasePosition": position,
		"observation": observation
	}


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
	var avoidance_observed := false
	for actor_key in ["leftAvoidance", "rightAvoidance"]:
		var avoidance: Dictionary = minimum_pair.get(actor_key, {}) as Dictionary
		var metrics: Dictionary = avoidance.get("metrics", {}) as Dictionary
		if bool(avoidance.get("active", false)) and int(metrics.get("callbackHits", 0)) > 0:
			avoidance_observed = true
			break
	var movement_ok := moved_count == citizens.size() and arrived_count == citizens.size() and unchanged_target_count == citizens.size() and crowd_replan_count == 0
	return {
		"passed": bool(lineup_setup.get("ok", false)) and bool(crossing_setup.get("ok", false)) and admission_ok and avoidance_observed and overlap_frames == 0 and minimum_separation >= required_separation and max_stationary_frames <= 90 and movement_ok,
		"lineupSetup": lineup_setup,
		"lineupAdmission": lineup_admission,
		"crossingSetup": crossing_setup,
		"crossingAdmission": crossing_admission,
		"minimumSeparation": minimum_separation,
		"requiredSeparation": required_separation,
		"avoidanceObserved": avoidance_observed,
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
		var home_status: Dictionary = autonomy.call("home_interior_status", entry, body.global_position) as Dictionary if autonomy != null and autonomy.has_method("home_interior_status") else {}
		var route_debug: Dictionary = autonomy.call("route_authority_v2_debug_for_entry", entry) as Dictionary if autonomy != null and autonomy.has_method("route_authority_v2_debug_for_entry") else {}
		var navmesh_world = autonomy.get("navmesh_world") if autonomy != null else null
		var navmesh_path: Dictionary = navmesh_world.call("actor_path_status", String(manifest.get("id", body.name))) as Dictionary if navmesh_world != null and navmesh_world.has_method("actor_path_status") else {}
		var motor_profile = entry.get("motorProfile")
		var body_radius := npc_body_collision_radius(body)
		var navigation_body_radius := float(motor_profile.capsule_radius) if motor_profile != null else body_radius
		var locomotion = citizen_entry.get("locomotion")
		var presentation := biped_presentation_snapshot(locomotion)
		var route_service_kind := String(entry.get("routePhysicsServiceKind", ""))
		var route_plan: Dictionary = entry.get("homeRouteV2LastPlan", {}) if route_service_kind == "home" else entry.get("routineRouteV2LastPlan", {})
		var route_execution: Dictionary = entry.get("homeRouteV2LastExecution", {}) if route_service_kind == "home" else entry.get("routineRouteV2LastExecution", {})
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
			"routePlan": route_plan,
			"routeExecution": route_execution,
			"homeRouteExecution": entry.get("homeRouteV2LastExecution", {}),
			"routineRouteExecution": entry.get("routineRouteV2LastExecution", {}),
			"deferredRouteExecution": entry.get("routeLeaseDeferredExecution", {}),
			"activeNavigationTransition": entry.get("activeNavigationTransition", {}),
			"pendingNavigationTransition": entry.get("pendingNavigationTransition", {}),
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
			"activeTrafficStepGroup": String(entry.get("activeTrafficStepGroup", "")),
			"homeInteriorStatus": home_status,
			"doorLifecycle": door_lifecycle_snapshot(entry, body),
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


func door_lifecycle_snapshot(entry: Dictionary, body: CharacterBody3D) -> Dictionary:
	var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
	var door_portals = autonomy.get("door_portals") if autonomy != null else null
	var portal_id := String(entry.get("doorPortalId", ""))
	var result := {
		"portalId": portal_id,
		"portalState": "missing",
		"leafCount": 0,
		"collisionDisabled": false,
		"allLeafCollisionDisabled": false
	}
	if portal_id.is_empty() or door_portals == null:
		return result
	var portal = (door_portals.get("portals") as Dictionary).get(portal_id)
	if portal == null:
		return result
	result["portalState"] = String(portal.get("state"))
	var leaf_count := 0
	var disabled_count := 0
	for leaf_value in portal.get("leaf_nodes") as Array:
		var leaf := leaf_value as Node
		if leaf == null or not is_instance_valid(leaf):
			continue
		for collision_value in leaf.find_children("*", "CollisionShape3D", true, false):
			var collision := collision_value as CollisionShape3D
			if collision == null:
				continue
			leaf_count += 1
			if collision.disabled or leaf.collision_layer == 0:
				disabled_count += 1
	result["leafCount"] = leaf_count
	result["collisionDisabled"] = disabled_count > 0
	result["allLeafCollisionDisabled"] = leaf_count > 0 and disabled_count == leaf_count
	return result


func record_door_lifecycle_observations(phase: String) -> void:
	if npc_system == null:
		return
	var physics_frame := Engine.get_physics_frames()
	for citizen_entry in citizens:
		var body := citizen_entry.get("body") as CharacterBody3D
		if body == null or not is_instance_valid(body):
			continue
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		var actor_id := String(manifest.get("id", body.name))
		var entry: Dictionary = npc_system.call("npc_entry_for_actor", body) as Dictionary
		var scripted_order: Dictionary = entry.get("scriptedOrder", {}) if entry.get("scriptedOrder", {}) is Dictionary else {}
		var autonomy = npc_system.get("autonomy_system")
		var route_authority: Dictionary = autonomy.call("route_authority_v2_debug_for_entry", entry) as Dictionary if autonomy != null and autonomy.has_method("route_authority_v2_debug_for_entry") else {}
		var crossing_transaction: Dictionary = autonomy.call("npc_door_crossing_transaction", entry) as Dictionary if autonomy != null and autonomy.has_method("npc_door_crossing_transaction") else {}
		var completed_crossing: Dictionary = autonomy.call("npc_completed_door_crossing", entry) as Dictionary if autonomy != null and autonomy.has_method("npc_completed_door_crossing") else {}
		var force_sample := phase.ends_with("complete") or phase == "acceptance_start"
		var owned_door_traversal := not String(entry.get("activeDoorPortalId", "")).is_empty() or bool(entry.get("doorStageActive", false))
		if physics_frame % DOOR_LIFECYCLE_SAMPLE_INTERVAL_FRAMES != 0 and not owned_door_traversal and not force_sample:
			continue
		var home_status: Dictionary = autonomy.call("home_interior_status", entry, body.global_position) as Dictionary if autonomy != null and autonomy.has_method("home_interior_status") else {}
		var door: Dictionary = door_lifecycle_snapshot(entry, body)
		var portal = door_portal_for_lifecycle(autonomy, door)
		var interior_position: Vector3 = manifest.get("doorInteriorPosition", Vector3.INF) as Vector3
		var exterior_position: Vector3 = manifest.get("doorExteriorPosition", Vector3.INF) as Vector3
		var plane_side := 0.0
		if interior_position.is_finite() and exterior_position.is_finite():
			var door_axis := exterior_position - interior_position
			door_axis.y = 0.0
			if door_axis.length_squared() > 0.0001:
				plane_side = (body.global_position - (interior_position + exterior_position) * 0.5).dot(door_axis.normalized())
		var current := {
			"phase": phase,
			"acceptanceDayGeneration": acceptance_day_generation,
			"scriptedOrderId": String(scripted_order.get("id", "")),
			"routeRequestId": String(route_authority.get("requestId", "")),
			"routeGeneration": int(route_authority.get("generation", -1)),
			"routeLeaseId": String((entry.get("routeLease", {}) as Dictionary).get("leaseId", "")) if entry.get("routeLease", {}) is Dictionary else "",
			"position": body.global_position,
			"strictInside": bool(home_status.get("strictInside", false)),
			"clearOfDoor": bool(home_status.get("clearOfDoor", false)),
			"homeDepartureState": String(entry.get("homeDepartureState", "")),
			"portalId": String(door.get("portalId", "")),
			"portalState": String(door.get("portalState", "")),
			"leafCount": int(door.get("leafCount", 0)),
			"collisionDisabled": bool(door.get("collisionDisabled", false)),
			"allLeafCollisionDisabled": bool(door.get("allLeafCollisionDisabled", false)),
			"activeDoorPortalId": String(entry.get("activeDoorPortalId", "")),
			"crossingId": String(crossing_transaction.get("crossingId", "")),
			"crossingPortalId": String(crossing_transaction.get("portalId", "")),
			"crossingTrafficGroupId": String(crossing_transaction.get("groupId", "")),
			"crossingReservationIds": (crossing_transaction.get("reservationIds", []) as Array).duplicate(),
			"crossingTrafficContinuity": (crossing_transaction.get("trafficContinuity", {}) as Dictionary).duplicate(true),
			"crossingInitiatingRequestId": String(crossing_transaction.get("initiatingRouteRequestId", "")),
			"crossingInitiatingGeneration": int(crossing_transaction.get("initiatingRouteGeneration", -1)),
			"crossingInitiatingLeaseId": String(crossing_transaction.get("initiatingRouteLeaseId", "")),
			"crossingSuccessorRequestId": String(crossing_transaction.get("successorRouteRequestId", "")),
			"crossingSuccessorGeneration": int(crossing_transaction.get("successorRouteGeneration", -1)),
			"crossingSuccessorLeaseId": String(crossing_transaction.get("successorRouteLeaseId", "")),
			"completedCrossingId": String(completed_crossing.get("crossingId", "")),
			"completedCrossingPortalId": String(completed_crossing.get("portalId", "")),
			"completedCrossingInitiatingRequestId": String(completed_crossing.get("initiatingRouteRequestId", "")),
			"completedCrossingInitiatingGeneration": int(completed_crossing.get("initiatingRouteGeneration", -1)),
			"completedCrossingInitiatingLeaseId": String(completed_crossing.get("initiatingRouteLeaseId", "")),
			"completedCrossingSuccessorRequestId": String(completed_crossing.get("successorRouteRequestId", "")),
			"completedCrossingSuccessorGeneration": int(completed_crossing.get("successorRouteGeneration", -1)),
			"completedCrossingSuccessorLeaseId": String(completed_crossing.get("successorRouteLeaseId", "")),
			"completedCrossingReleaseFrame": int(completed_crossing.get("releaseFrame", -1)),
			"completedCrossingReleaseEvidence": (completed_crossing.get("releaseEvidence", {}) as Dictionary).duplicate(true),
			"completedCrossingTrafficContinuity": (completed_crossing.get("releaseTrafficContinuity", {}) as Dictionary).duplicate(true),
			"routeStatus": String(entry.get("routeStatus", "")),
			"movedDistance": float(entry.get("routePhysicsServiceMovedDistance", 0.0)),
			"doorPlaneSide": plane_side,
			"exteriorClearance": exterior_clearance_observation(entry, manifest, portal, body.global_position)
		}
		var tracker: Dictionary = acceptance_door_lifecycle.get(actor_id, {"events": [], "last": {}}) as Dictionary
		var last: Dictionary = tracker.get("last", {}) as Dictionary
		if int(last.get("physicsFrame", -1)) == physics_frame:
			continue
		current["physicsFrame"] = physics_frame
		current["elapsedMsec"] = Time.get_ticks_msec()
		var capture_id := door_lifecycle_capture_id(actor_id, phase, last, current)
		if not capture_id.is_empty():
			current["visualCapturePath"] = profile_screenshot_dir.path_join("%s.png" % capture_id)
			call_deferred("capture_doorway_lifecycle_view", capture_id, body)
		var events: Array = tracker.get("events", []) as Array
		events.append(current.duplicate(true))
		tracker["events"] = events
		tracker["last"] = current.duplicate(true)
		acceptance_door_lifecycle[actor_id] = tracker


func door_portal_for_lifecycle(autonomy, door: Dictionary):
	if autonomy == null:
		return null
	var door_portals = autonomy.get("door_portals")
	if door_portals == null or not (door_portals.get("portals") is Dictionary):
		return null
	return (door_portals.get("portals") as Dictionary).get(String(door.get("portalId", "")))


func exterior_clearance_observation(entry: Dictionary, manifest: Dictionary, portal, position: Vector3) -> Dictionary:
	var geometry_entry := entry.duplicate(false)
	for key in ["doorInteriorPosition", "doorExteriorPosition"]:
		var value = geometry_entry.get(key, Vector3.INF)
		if not (value is Vector3) or not (value as Vector3).is_finite():
			geometry_entry[key] = manifest.get(key, Vector3.INF)
	var exterior = geometry_entry.get("doorExteriorPosition", Vector3.INF)
	var target := exterior as Vector3 if exterior is Vector3 else Vector3.INF
	if target.is_finite():
		target = HomeInteriorServiceScript.exterior_clearance_target(geometry_entry, portal, target, DOOR_CLEARANCE_ARRIVAL_RADIUS)
	var outward := HomeInteriorServiceScript.exterior_direction_for_entry(geometry_entry)
	var signed_distance := 0.0
	var interior = geometry_entry.get("doorInteriorPosition", Vector3.INF)
	if interior is Vector3 and exterior is Vector3 and (interior as Vector3).is_finite() and (exterior as Vector3).is_finite() and outward.length_squared() > 0.0001:
		signed_distance = (position - ((interior as Vector3 + exterior as Vector3) * 0.5)).dot(outward)
	return {
		"target": target,
		"actualPosition": position,
		"targetDistance": position.distance_to(target) if target.is_finite() else INF,
		"signedExteriorPlaneDistance": signed_distance,
		"satisfied": HomeInteriorServiceScript.has_exterior_clearance(geometry_entry, portal, position)
	}


func door_lifecycle_capture_id(actor_id: String, phase: String, previous: Dictionary, current: Dictionary) -> String:
	if profile_screenshot_dir.is_empty() or phase not in ["day_civic", "night_home"]:
		return ""
	var state := String(current.get("portalState", ""))
	var previous_state := String(previous.get("portalState", ""))
	var stage := ""
	if state == "open" and bool(current.get("allLeafCollisionDisabled", false)) and previous_state != "open":
		stage = "open_collision_clear"
	elif bool(previous.get("strictInside", false)) != bool(current.get("strictInside", false)):
		stage = "door_plane_crossing"
	elif state == "closed" and previous_state != "closed" and not bool(current.get("collisionDisabled", false)):
		stage = "closed_collision_restored"
	if stage.is_empty():
		return ""
	var capture_id := "door_%s_%s_%s_%s" % [phase, stage, actor_id.validate_filename().left(44), actor_id.md5_text().left(8)]
	if acceptance_door_lifecycle_capture_ids.has(capture_id):
		return ""
	acceptance_door_lifecycle_capture_ids[capture_id] = true
	return capture_id


func capture_doorway_lifecycle_view(capture_id: String, body: CharacterBody3D) -> void:
	if body == null or not is_instance_valid(body) or profile_screenshot_dir.is_empty():
		return
	var viewport := get_viewport()
	var previous_camera := viewport.get_camera_3d()
	var observation_camera := Camera3D.new()
	add_child(observation_camera)
	var capture_light := OmniLight3D.new()
	observation_camera.add_child(capture_light)
	capture_light.light_energy = 2.4
	capture_light.omni_range = 12.0
	capture_light.shadow_enabled = false
	var target := body.global_position + Vector3(0.0, 0.9, 0.0)
	observation_camera.global_position = nearby_observation_camera_position(body, target)
	observation_camera.look_at(target, Vector3.UP)
	observation_camera.make_current()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	save_current_viewport(capture_id)
	if previous_camera != null and is_instance_valid(previous_camera):
		previous_camera.current = true
	observation_camera.queue_free()


func night_home_progress_evidence() -> Dictionary:
	var actors := {}
	var passed := true
	for actor_id_value in acceptance_door_lifecycle.keys():
		var actor_id := String(actor_id_value)
		var tracker: Dictionary = acceptance_door_lifecycle.get(actor_id, {}) as Dictionary
		var events: Array = tracker.get("events", []) as Array
		var night_events: Array = []
		for event_value in events:
			if event_value is Dictionary and String((event_value as Dictionary).get("phase", "")) == "night_home":
				night_events.append(event_value as Dictionary)
		var last_progress_frame := -1
		var last_moved_distance := -INF
		var stalled := false
		var final_inside := false
		var arrival_frame := -1
		var final_frame := -1
		for event_value in night_events:
			var event: Dictionary = event_value as Dictionary
			var moved_distance := float(event.get("movedDistance", 0.0))
			var physics_frame := int(event.get("physicsFrame", -1))
			final_frame = physics_frame
			if moved_distance >= last_moved_distance + NIGHT_HOME_PROGRESS_DELTA:
				last_moved_distance = moved_distance
				last_progress_frame = physics_frame
			if bool(event.get("strictInside", false)) and not final_inside:
				final_inside = true
				arrival_frame = physics_frame
			if not final_inside and last_progress_frame >= 0 and physics_frame - last_progress_frame > roundi(NIGHT_HOME_PROGRESS_GRACE_SECONDS * float(Engine.physics_ticks_per_second)):
				stalled = true
		if not final_inside and last_progress_frame >= 0 and final_frame - last_progress_frame > roundi(NIGHT_HOME_PROGRESS_GRACE_SECONDS * float(Engine.physics_ticks_per_second)):
			stalled = true
		var actor_passed := not night_events.is_empty() and final_inside and not stalled
		actors[actor_id] = {
			"passed": actor_passed,
			"eventCount": night_events.size(),
			"finalStrictInside": final_inside,
			"stalled": stalled,
			"arrivalFrame": arrival_frame,
			"finalObservationFrame": final_frame,
			"lastProgressFrame": last_progress_frame,
			"lastMovedDistance": last_moved_distance if last_moved_distance > -INF else 0.0
		}
		passed = passed and actor_passed
	return {
		"passed": passed and not actors.is_empty(),
		"sampleIntervalFrames": DOOR_LIFECYCLE_SAMPLE_INTERVAL_FRAMES,
		"progressGraceSeconds": NIGHT_HOME_PROGRESS_GRACE_SECONDS,
		"progressDelta": NIGHT_HOME_PROGRESS_DELTA,
		"actors": actors
	}


func door_lifecycle_acceptance_evidence(day_lifecycle: Dictionary, night_lifecycle: Dictionary) -> Dictionary:
	var actors := {}
	var passed := true
	for actor_id_value in day_lifecycle.keys():
		var actor_id := String(actor_id_value)
		var day_tracker: Dictionary = day_lifecycle.get(actor_id, {}) as Dictionary
		var night_tracker: Dictionary = night_lifecycle.get(actor_id, {}) as Dictionary
		var day_events: Array = day_tracker.get("events", []) as Array
		var night_events: Array = night_tracker.get("events", []) as Array
		night_events = night_events.filter(func(event: Dictionary) -> bool: return String(event.get("phase", "")) == "night_home" or String(event.get("phase", "")) == "night_home_complete")
		var baseline_leaf_count := 0
		var day_open_index := -1
		var day_crossing_index := -1
		var day_clearance_index := -1
		var day_clearance_verified := false
		var day_clearance_evidence := {}
		var day_interior_side := manifest_door_plane_side(actor_id, true)
		if is_zero_approx(day_interior_side):
			day_interior_side = first_signed_door_side(day_events, true)
		for index in range(day_events.size()):
			if not (day_events[index] is Dictionary):
				continue
			var event: Dictionary = day_events[index] as Dictionary
			baseline_leaf_count = max(baseline_leaf_count, int(event.get("leafCount", 0)))
			if day_open_index < 0 and String(event.get("portalState", "")) == "open" and bool(event.get("allLeafCollisionDisabled", false)):
				day_open_index = index
			if day_open_index >= 0 and day_crossing_index < 0 and not bool(event.get("strictInside", false)) and bool(event.get("clearOfDoor", false)) and opposite_door_side(float(event.get("doorPlaneSide", 0.0)), day_interior_side):
				day_crossing_index = index
			if day_crossing_index >= 0 and day_clearance_index < 0 and not bool(event.get("strictInside", false)) and opposite_door_side(float(event.get("doorPlaneSide", 0.0)), day_interior_side) and bool((event.get("exteriorClearance", {}) as Dictionary).get("satisfied", false)):
				day_clearance_index = index
				day_clearance_evidence = event.get("exteriorClearance", {}) as Dictionary
				day_clearance_verified = bool(day_clearance_evidence.get("satisfied", false))
		var night_open_index := -1
		var night_return_index := -1
		var night_closed_index := -1
		var night_exterior_side := manifest_door_plane_side(actor_id, false)
		if is_zero_approx(night_exterior_side):
			night_exterior_side = first_signed_door_side(night_events, false)
		for index in range(night_events.size()):
			if not (night_events[index] is Dictionary):
				continue
			var event: Dictionary = night_events[index] as Dictionary
			if night_open_index < 0 and String(event.get("portalState", "")) == "open" and bool(event.get("allLeafCollisionDisabled", false)):
				night_open_index = index
			if night_open_index >= 0 and night_return_index < 0 and bool(event.get("strictInside", false)) and opposite_door_side(float(event.get("doorPlaneSide", 0.0)), night_exterior_side):
				night_return_index = index
			if night_return_index >= 0 and night_closed_index < 0 and String(event.get("portalState", "")) == "closed" and not bool(event.get("collisionDisabled", false)) and int(event.get("leafCount", 0)) == baseline_leaf_count and baseline_leaf_count > 0:
				night_closed_index = index
		var portal_id := String((day_events.front() as Dictionary).get("portalId", "")) if not day_events.is_empty() and day_events.front() is Dictionary else ""
		var day_trace := actor_door_lifecycle_trace(actor_id, portal_id, acceptance_day_started_msec, acceptance_night_started_msec)
		var night_trace := actor_door_lifecycle_trace(actor_id, portal_id, acceptance_night_started_msec)
		var day_open_transition_msec := actor_door_trace_success_msec(day_trace, ["open", "hold"], "open")
		var night_open_transition_msec := actor_door_trace_success_msec(night_trace, ["open", "hold"], "open")
		var night_release_transition_msec := actor_door_trace_success_msec(night_trace, ["release"])
		var day_open_elapsed_msec := int((day_events[day_open_index] as Dictionary).get("elapsedMsec", -1)) if day_open_index >= 0 else -1
		var night_open_elapsed_msec := int((night_events[night_open_index] as Dictionary).get("elapsedMsec", -1)) if night_open_index >= 0 else -1
		var day_actor_opened := day_open_transition_msec >= 0 and day_open_elapsed_msec >= day_open_transition_msec
		var night_actor_opened := night_open_transition_msec >= 0 and night_open_elapsed_msec >= night_open_transition_msec
		var night_actor_released := night_release_transition_msec >= 0
		var day_open_delayed := day_open_index >= 0 and day_crossing_index >= day_open_index + 1 and day_interior_side != 0.0
		var night_open_delayed := night_open_index >= 0 and night_return_index >= night_open_index + 1 and night_exterior_side != 0.0
		var close_delayed := false
		if night_return_index >= 0 and night_closed_index >= night_return_index:
			if night_closed_index > night_return_index:
				close_delayed = true
			else:
				var closing_event: Dictionary = night_events[night_closed_index] as Dictionary
				close_delayed = bool(closing_event.get("strictInside", false)) and bool(closing_event.get("clearOfDoor", false))
		var actor_passed := day_actor_opened and night_actor_opened and night_actor_released and day_open_delayed and day_clearance_verified and night_open_delayed and close_delayed
		actors[actor_id] = {
			"passed": actor_passed,
			"dayEventCount": day_events.size(),
			"nightEventCount": night_events.size(),
			"baselineLeafColliderCount": baseline_leaf_count,
			"dayInteriorSide": day_interior_side,
			"nightExteriorSide": night_exterior_side,
			"dayOpenCollisionClearIndex": day_open_index,
			"dayExteriorPlaneCrossingIndex": day_crossing_index,
			"dayExteriorClearanceIndex": day_clearance_index,
			"nightOpenCollisionClearIndex": night_open_index,
			"nightStrictInteriorPlaneCrossingIndex": night_return_index,
			"nightClosedCollisionRestoredIndex": night_closed_index,
			"dayActorOpenedDoor": day_actor_opened,
			"dayExteriorClearanceVerified": day_clearance_verified,
			"dayExteriorClearance": day_clearance_evidence,
			"nightActorOpenedDoor": night_actor_opened,
			"nightActorReleasedDoor": night_actor_released,
			"dayOpenTransitionMsec": day_open_transition_msec,
			"nightOpenTransitionMsec": night_open_transition_msec,
			"nightReleaseTransitionMsec": night_release_transition_msec,
			"dayCollisionClearObservedBeforeCrossing": day_open_delayed,
			"nightCollisionClearObservedBeforeCrossing": night_open_delayed,
			"collisionRestoredAfterReturn": close_delayed,
			"dayActorTrace": compact_door_trace(day_trace),
			"nightActorTrace": compact_door_trace(night_trace),
			"dayEvents": compact_door_events(day_events),
			"nightEvents": compact_door_events(night_events)
		}
		passed = passed and actor_passed
	return {"passed": passed and not actors.is_empty(), "actors": actors}


func actor_door_lifecycle_trace(actor_id: String, portal_id: String, start_msec: int, end_msec := -1) -> Array[Dictionary]:
	var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
	var door_portals = autonomy.get("door_portals") if autonomy != null else null
	var rows: Array[Dictionary] = []
	if portal_id.is_empty() or door_portals == null or not door_portals.has_method("lifecycle_trace_snapshot"):
		return rows
	for row_value in door_portals.call("lifecycle_trace_snapshot", portal_id, 256):
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = row_value as Dictionary
		var elapsed_msec := int(row.get("elapsedMsec", -1))
		if elapsed_msec < start_msec or (end_msec >= 0 and elapsed_msec >= end_msec):
			continue
		var metadata: Dictionary = row.get("metadata", {}) as Dictionary
		var request: Dictionary = metadata.get("request", {}) as Dictionary
		if String(request.get("actorId", "")) != actor_id:
			continue
		rows.append(row.duplicate(true))
	return rows


func first_signed_door_side(events: Array, strict_inside: bool) -> float:
	for event_value in events:
		if not (event_value is Dictionary):
			continue
		var event: Dictionary = event_value as Dictionary
		var side := float(event.get("doorPlaneSide", 0.0))
		if bool(event.get("strictInside", false)) == strict_inside and absf(side) > 0.20:
			return side
	return 0.0


func manifest_door_plane_side(actor_id: String, interior: bool) -> float:
	for citizen_entry in citizens:
		var manifest: Dictionary = citizen_entry.get("manifest", {}) as Dictionary
		if String(manifest.get("id", "")) != actor_id:
			continue
		var interior_position: Vector3 = manifest.get("doorInteriorPosition", Vector3.INF) as Vector3
		var exterior_position: Vector3 = manifest.get("doorExteriorPosition", Vector3.INF) as Vector3
		if not interior_position.is_finite() or not exterior_position.is_finite():
			return 0.0
		var axis := exterior_position - interior_position
		axis.y = 0.0
		if axis.length_squared() <= 0.0001:
			return 0.0
		var point := interior_position if interior else exterior_position
		return (point - (interior_position + exterior_position) * 0.5).dot(axis.normalized())
	return 0.0


func opposite_door_side(side: float, baseline_side: float) -> bool:
	return absf(side) > 0.20 and absf(baseline_side) > 0.20 and side * baseline_side < -0.04


func actor_door_trace_success_msec(rows: Array[Dictionary], commands: Array[String], expected_state := "", route_request_id := "", route_generation := -1) -> int:
	for row in rows:
		var metadata: Dictionary = row.get("metadata", {}) as Dictionary
		var request: Dictionary = metadata.get("request", {}) as Dictionary
		var result: Dictionary = metadata.get("result", {}) as Dictionary
		var request_metadata: Dictionary = request.get("metadata", {}) if request.get("metadata", {}) is Dictionary else {}
		if not route_request_id.is_empty() and String(request_metadata.get("routeRequestId", "")) != route_request_id:
			continue
		if route_generation > 0 and int(request_metadata.get("routeGeneration", -1)) != route_generation:
			continue
		if String(request.get("command", "")) in commands and String(result.get("status", "")) == "succeeded" and (expected_state.is_empty() or String(metadata.get("stateAfter", "")) == expected_state):
			return int(row.get("elapsedMsec", -1))
	return -1


func compact_door_trace(rows: Array[Dictionary]) -> Array[Dictionary]:
	var compact: Array[Dictionary] = []
	for row in rows:
		var metadata: Dictionary = row.get("metadata", {}) as Dictionary
		var request: Dictionary = metadata.get("request", {}) as Dictionary
		var result: Dictionary = metadata.get("result", {}) as Dictionary
		var request_metadata: Dictionary = request.get("metadata", {}) if request.get("metadata", {}) is Dictionary else {}
		compact.append({"elapsedMsec": int(row.get("elapsedMsec", -1)), "kind": String(row.get("kind", "")), "command": String(request.get("command", "")), "status": String(result.get("status", "")), "stateAfter": String(metadata.get("stateAfter", "")), "routeRequestId": String(request_metadata.get("routeRequestId", "")), "routeGeneration": int(request_metadata.get("routeGeneration", -1)), "routeLeaseId": String(request_metadata.get("routeLeaseId", ""))})
	return compact


func compact_door_events(events: Array) -> Array[Dictionary]:
	var compact: Array[Dictionary] = []
	for event_value in events:
		if not (event_value is Dictionary):
			continue
		var event: Dictionary = event_value as Dictionary
		if String(event.get("portalState", "")) == "open" or not bool(event.get("clearOfDoor", true)) or not bool(event.get("strictInside", false)) or event.has("visualCapturePath"):
			compact.append({"physicsFrame": int(event.get("physicsFrame", -1)), "elapsedMsec": int(event.get("elapsedMsec", -1)), "acceptanceDayGeneration": int(event.get("acceptanceDayGeneration", -1)), "scriptedOrderId": String(event.get("scriptedOrderId", "")), "routeRequestId": String(event.get("routeRequestId", "")), "routeGeneration": int(event.get("routeGeneration", -1)), "routeLeaseId": String(event.get("routeLeaseId", "")), "portalState": String(event.get("portalState", "")), "portalId": String(event.get("portalId", "")), "activeDoorPortalId": String(event.get("activeDoorPortalId", "")), "crossingId": String(event.get("crossingId", "")), "crossingPortalId": String(event.get("crossingPortalId", "")), "crossingTrafficGroupId": String(event.get("crossingTrafficGroupId", "")), "crossingReservationIds": event.get("crossingReservationIds", []), "crossingTrafficContinuity": event.get("crossingTrafficContinuity", {}), "crossingInitiatingRequestId": String(event.get("crossingInitiatingRequestId", "")), "crossingInitiatingGeneration": int(event.get("crossingInitiatingGeneration", -1)), "crossingInitiatingLeaseId": String(event.get("crossingInitiatingLeaseId", "")), "crossingSuccessorRequestId": String(event.get("crossingSuccessorRequestId", "")), "crossingSuccessorGeneration": int(event.get("crossingSuccessorGeneration", -1)), "crossingSuccessorLeaseId": String(event.get("crossingSuccessorLeaseId", "")), "completedCrossingId": String(event.get("completedCrossingId", "")), "completedCrossingReleaseFrame": int(event.get("completedCrossingReleaseFrame", -1)), "completedCrossingReleaseEvidence": event.get("completedCrossingReleaseEvidence", {}), "completedCrossingTrafficContinuity": event.get("completedCrossingTrafficContinuity", {}), "allLeafCollisionDisabled": bool(event.get("allLeafCollisionDisabled", false)), "strictInside": bool(event.get("strictInside", false)), "clearOfDoor": bool(event.get("clearOfDoor", false)), "doorPlaneSide": float(event.get("doorPlaneSide", 0.0)), "routeStatus": String(event.get("routeStatus", "")), "exteriorClearance": event.get("exteriorClearance", {}), "visualCapturePath": String(event.get("visualCapturePath", ""))})
	return compact


func compact_door_lifecycle_map(lifecycle: Dictionary) -> Dictionary:
	var compact := {}
	for actor_id in lifecycle.keys():
		var tracker: Dictionary = lifecycle.get(actor_id, {}) if lifecycle.get(actor_id, {}) is Dictionary else {}
		compact[String(actor_id)] = compact_door_events(tracker.get("events", []) as Array)
	return compact


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


func capture_raised_route_junction_views() -> Array[Dictionary]:
	var captures: Array[Dictionary] = []
	if profile_screenshot_dir.is_empty() or citadel_root == null or core_blueprint == null:
		return captures
	var viewport := get_viewport()
	var previous_camera := viewport.get_camera_3d()
	if previous_camera != null and is_instance_valid(previous_camera):
		previous_camera.current = false
	var capture_index := 0
	for part in core_blueprint.parts:
		if part == null or String(part.semantic) != "castle_route_junction":
			continue
		capture_index += 1
		var observation_camera := Camera3D.new()
		add_child(observation_camera)
		var capture_light := OmniLight3D.new()
		observation_camera.add_child(capture_light)
		capture_light.light_energy = 2.4
		capture_light.omni_range = 20.0
		capture_light.shadow_enabled = false
		var target := citadel_root.to_global(part.position) + Vector3.UP * maxf(0.35, part.size.y * 0.4)
		var lateral := Vector3(1.0 if capture_index % 2 == 0 else -1.0, 0.0, 1.0).normalized()
		observation_camera.global_position = target + lateral * 7.0 + Vector3.UP * 5.2
		observation_camera.look_at(target, Vector3.UP)
		observation_camera.make_current()
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var capture_id := "interactive_route_junction_%02d" % capture_index
		save_current_viewport(capture_id)
		captures.append({"junctionId": String(part.id), "path": profile_screenshot_dir.path_join("%s.png" % capture_id)})
		observation_camera.queue_free()
	if previous_camera != null and is_instance_valid(previous_camera):
		previous_camera.current = true
	return captures


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
	var part_delimiter := residence_part_prefix.find("__")
	if part_delimiter > 0:
		residence_part_prefix = residence_part_prefix.left(part_delimiter + 2)
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


func collect_citadel_surface_transition_publication_probe() -> Dictionary:
	var expected_source_part_ids := [
		"castle_compound_paving_segment_02",
		"castle_keep_palace_entry_forecourt",
		"castle_compound_paving_segment_03"
	]
	var support_records := {}
	for source_part_id in expected_source_part_ids:
		support_records[source_part_id] = []
	if npc_system != null and npc_system.has_method("building_navigation_manifest_snapshot"):
		for manifest_value in npc_system.call("building_navigation_manifest_snapshot") as Array:
			if not (manifest_value is Dictionary):
				continue
			var manifest: Dictionary = manifest_value
			for support_value in manifest.get("supports", []) as Array:
				if not (support_value is Dictionary):
					continue
				var support: Dictionary = support_value
				var source_part_id := String(support.get("sourcePartId", ""))
				if not support_records.has(source_part_id):
					continue
				(support_records[source_part_id] as Array).append({
					"id": String(support.get("id", "")),
					"sourcePartId": source_part_id,
					"sourceCollisionPartId": String(support.get("sourceCollisionPartId", "")),
					"producerTileKey": String(support.get("producerTileKey", "")),
					"tileKeys": (support.get("tileKeys", []) as Array).duplicate(),
					"polygon": (support.get("polygon", []) as Array).duplicate(true)
				})
	var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
	var adapter = autonomy.call("generated_navigation_adapter") if autonomy != null and autonomy.has_method("generated_navigation_adapter") else null
	var navmesh_world = autonomy.get("navmesh_world") if autonomy != null else null
	var requested_tile_keys := ["-17,146", "-17,147"]
	var tile_snapshots := {}
	if adapter != null and adapter.has_method("build_navmesh_tile_snapshot"):
		for tile_key in requested_tile_keys:
			var snapshot_value = adapter.call("build_navmesh_tile_snapshot", tile_key)
			tile_snapshots[tile_key] = (snapshot_value as Dictionary).duplicate(true) if snapshot_value is Dictionary else {}
	var navmesh_snapshot: Dictionary = navmesh_world.call("debug_snapshot") as Dictionary if navmesh_world != null and navmesh_world.has_method("debug_snapshot") else {}
	var forecourt_records: Array = support_records.get("castle_keep_palace_entry_forecourt", []) as Array
	var segment_03_records: Array = support_records.get("castle_compound_paving_segment_03", []) as Array
	var forecourt_id := String((forecourt_records[0] as Dictionary).get("id", "")) if forecourt_records.size() == 1 and forecourt_records[0] is Dictionary else ""
	var segment_03_id := String((segment_03_records[0] as Dictionary).get("id", "")) if segment_03_records.size() == 1 and segment_03_records[0] is Dictionary else ""
	var selected_tile_links: Array[Dictionary] = []
	var selected_ids := {}
	for tile_key in requested_tile_keys:
		var tile_snapshot: Dictionary = tile_snapshots.get(tile_key, {}) as Dictionary
		for link_value in tile_snapshot.get("navigationLinks", []) as Array:
			if not (link_value is Dictionary):
				continue
			var link: Dictionary = link_value
			var start_support_id := String(link.get("startSupportId", ""))
			var end_support_id := String(link.get("endSupportId", ""))
			if not ((start_support_id == forecourt_id and end_support_id == segment_03_id) or (start_support_id == segment_03_id and end_support_id == forecourt_id)):
				continue
			var link_id := String(link.get("id", ""))
			if selected_ids.has(link_id):
				continue
			selected_ids[link_id] = true
			selected_tile_links.append(link.duplicate(true))
	var installed_by_id := {}
	var installed_support_pair_links: Array[Dictionary] = []
	for link_value in navmesh_snapshot.get("navigationLinks", []) as Array:
		if link_value is Dictionary:
			var installed_link: Dictionary = link_value
			installed_by_id[String(installed_link.get("id", ""))] = installed_link
			var installed_start_support_id := String(installed_link.get("startSupportId", ""))
			var installed_end_support_id := String(installed_link.get("endSupportId", ""))
			if (installed_start_support_id == forecourt_id and installed_end_support_id == segment_03_id) \
			or (installed_start_support_id == segment_03_id and installed_end_support_id == forecourt_id):
				installed_support_pair_links.append(installed_link.duplicate(true))
	var pending_matches: Array[Dictionary] = []
	for link_value in navmesh_snapshot.get("pendingNavigationLinks", []) as Array:
		if not (link_value is Dictionary):
			continue
		var pending_link: Dictionary = link_value
		var pending_id := String(pending_link.get("id", pending_link.get("linkId", "")))
		if selected_ids.has(pending_id):
			pending_matches.append(pending_link.duplicate(true))
	var publication_failures: Array[Dictionary] = []
	var continuity_certificates: Array[Dictionary] = []
	var continuity_by_id := {}
	if adapter != null:
		var failure_value = adapter.get("surface_transition_publication_failures")
		if failure_value is Array:
			for failure_entry_value in failure_value as Array:
				if not (failure_entry_value is Dictionary):
					continue
				var serialized_failure := JSON.stringify(failure_entry_value)
				if serialized_failure.contains("castle_keep_palace_entry_forecourt") or serialized_failure.contains("castle_compound_paving_segment_03"):
					publication_failures.append((failure_entry_value as Dictionary).duplicate(true))
		var continuity_value = adapter.get("continuous_surface_transition_certificates")
		if continuity_value is Array:
			for certificate_value in continuity_value as Array:
				if not (certificate_value is Dictionary):
					continue
				var certificate: Dictionary = certificate_value
				var owners_serialized := JSON.stringify(certificate.get("sourceOwners", []))
				if owners_serialized.contains(forecourt_id) and owners_serialized.contains(segment_03_id):
					continuity_by_id[String(certificate.get("seamCorridorId", ""))] = certificate.duplicate(true)
		var continuity_ids: Array = continuity_by_id.keys()
		continuity_ids.sort()
		for continuity_id in continuity_ids:
			continuity_certificates.append(continuity_by_id.get(continuity_id, {}) as Dictionary)
	var support_sample_diagnostics: Array[Dictionary] = []
	if adapter != null and adapter.has_method("building_support_navigation_sample_diagnostics"):
		for support_id in [forecourt_id, segment_03_id]:
			for tile_key in requested_tile_keys:
				var sample_value = adapter.call("building_support_navigation_sample_diagnostics", support_id, tile_key)
				if sample_value is Dictionary:
					support_sample_diagnostics.append((sample_value as Dictionary).duplicate(true))
	var seam_collision: Array[Dictionary] = []
	var seam_bounds := AABB(Vector3(-365.2, 22.8, 3170.8), Vector3(9.5, 2.8, 6.2))
	for tile_key in requested_tile_keys:
		var tile_snapshot: Dictionary = tile_snapshots.get(tile_key, {}) as Dictionary
		for collision_value in tile_snapshot.get("staticCollision", []) as Array:
			if not (collision_value is Dictionary):
				continue
			var collision: Dictionary = collision_value
			var bounds: AABB = collision.get("bounds", AABB()) if collision.get("bounds", AABB()) is AABB else AABB()
			if bounds.size.length_squared() > 0.0 and bounds.intersects(seam_bounds):
				seam_collision.append(collision.duplicate(true))
	var lane_numbers: Array[int] = []
	var installed_links: Array[Dictionary] = []
	var invalid_installed_links: Array[Dictionary] = []
	var endpoint_tiles := {}
	for tile_link in selected_tile_links:
		var lane_number := int(tile_link.get("laneNumber", -1))
		if not lane_numbers.has(lane_number):
			lane_numbers.append(lane_number)
		endpoint_tiles[String(tile_link.get("startTileKey", ""))] = true
		endpoint_tiles[String(tile_link.get("endTileKey", ""))] = true
		var link_id := String(tile_link.get("id", ""))
		var installed_link: Dictionary = installed_by_id.get(link_id, {}) as Dictionary
		var link_rid = installed_link.get("linkRid")
		var valid_rid: bool = typeof(link_rid) == TYPE_RID and link_rid.is_valid()
		var valid: bool = not installed_link.is_empty() \
			and bool(installed_link.get("enabled", false)) \
			and bool(installed_link.get("bidirectional", false)) \
			and valid_rid
		var installed_summary := {
			"id": link_id,
			"laneNumber": lane_number,
			"ownerTileKey": String(installed_link.get("ownerTileKey", "")),
			"startTileKey": String(installed_link.get("startTileKey", "")),
			"endTileKey": String(installed_link.get("endTileKey", "")),
			"startTileSourceKey": String(installed_link.get("startTileSourceKey", "")),
			"endTileSourceKey": String(installed_link.get("endTileSourceKey", "")),
			"enabled": bool(installed_link.get("enabled", false)),
			"bidirectional": bool(installed_link.get("bidirectional", false)),
			"validRid": valid_rid,
			"valid": valid
		}
		installed_links.append(installed_summary)
		if not valid:
			invalid_installed_links.append(installed_summary)
	lane_numbers.sort()
	var support_counts_valid := true
	for source_part_id in expected_source_part_ids:
		if (support_records.get(source_part_id, []) as Array).size() != 1:
			support_counts_valid = false
	var expected_endpoint_tiles := {"-17,146": true, "-17,147": true}
	var endpoint_tiles_valid := endpoint_tiles.size() == expected_endpoint_tiles.size()
	for tile_key in expected_endpoint_tiles.keys():
		endpoint_tiles_valid = endpoint_tiles_valid and endpoint_tiles.has(tile_key)
	var lanes_valid := lane_numbers == [0, 1, 2, 3, 4, 5]
	var owners_valid := selected_tile_links.all(func(link: Dictionary) -> bool: return String(link.get("ownerTileKey", "")) == "-17,146")
	var source_keys_valid := true
	for tile_key in requested_tile_keys:
		source_keys_valid = source_keys_valid and not String((tile_snapshots.get(tile_key, {}) as Dictionary).get("sourceKey", "")).is_empty()
	var direct_route_probes: Array[Dictionary] = []
	for continuity_certificate in continuity_certificates:
		for lane_position_value in continuity_certificate.get("lanePositions", []) as Array:
			if not (lane_position_value is Vector3):
				continue
			var lane_position: Vector3 = lane_position_value
			var route_start := lane_position + Vector3(0.0, 0.04, -2.0)
			var route_target := lane_position + Vector3(0.0, 0.04, 2.0)
			var forward_route: Dictionary = navmesh_world.call("query_route", route_start, route_target, {"maxSnapDistance": 1.0, "queryApi": "query_path"}) as Dictionary if navmesh_world != null and navmesh_world.has_method("query_route") else {}
			var reverse_route: Dictionary = navmesh_world.call("query_route", route_target, route_start, {"maxSnapDistance": 1.0, "queryApi": "query_path"}) as Dictionary if navmesh_world != null and navmesh_world.has_method("query_route") else {}
			var forward_path: Array = forward_route.get("path", []) as Array
			var reverse_path: Array = reverse_route.get("path", []) as Array
			var forward_endpoint: Vector3 = forward_path.back() as Vector3 if not forward_path.is_empty() and forward_path.back() is Vector3 else Vector3.INF
			var reverse_endpoint: Vector3 = reverse_path.back() as Vector3 if not reverse_path.is_empty() and reverse_path.back() is Vector3 else Vector3.INF
			var forward_owner: Dictionary = adapter.call("building_support_for_position", forward_endpoint, CELL * 0.92) as Dictionary if adapter != null and forward_endpoint.is_finite() and adapter.has_method("building_support_for_position") else {}
			var reverse_owner: Dictionary = adapter.call("building_support_for_position", reverse_endpoint, CELL * 0.92) as Dictionary if adapter != null and reverse_endpoint.is_finite() and adapter.has_method("building_support_for_position") else {}
			var forward_endpoint_certified := forward_endpoint.is_finite() \
				and Vector2(forward_endpoint.x - route_target.x, forward_endpoint.z - route_target.z).length() <= 0.05 \
				and String(forward_owner.get("id", "")) == segment_03_id
			var reverse_endpoint_certified := reverse_endpoint.is_finite() \
				and Vector2(reverse_endpoint.x - route_start.x, reverse_endpoint.z - route_start.z).length() <= 0.05 \
				and String(reverse_owner.get("id", "")) == forecourt_id
			direct_route_probes.append({
				"lanePosition": lane_position,
				"forward": forward_route,
				"reverse": reverse_route,
				"forwardEndpointCertification": {"passed": forward_endpoint_certified, "endpoint": forward_endpoint, "expectedSupportId": segment_03_id, "actualSupportId": String(forward_owner.get("id", ""))},
				"reverseEndpointCertification": {"passed": reverse_endpoint_certified, "endpoint": reverse_endpoint, "expectedSupportId": forecourt_id, "actualSupportId": String(reverse_owner.get("id", ""))},
				"passed": bool(forward_route.get("ok", false)) and bool(reverse_route.get("ok", false)) \
					and String(forward_route.get("status", "")) == "complete" \
					and String(reverse_route.get("status", "")) == "complete" \
					and (forward_route.get("actions", {}) as Dictionary).is_empty() \
					and (reverse_route.get("actions", {}) as Dictionary).is_empty() \
					and forward_endpoint_certified \
					and reverse_endpoint_certified
			})
	var continuity_valid := continuity_certificates.size() == 1 \
		and bool(continuity_certificates[0].get("passed", false)) \
		and int(continuity_certificates[0].get("laneCount", 0)) >= 2 \
		and not bool(continuity_certificates[0].get("positiveOverlap", true)) \
		and float(continuity_certificates[0].get("maximumContactGap", INF)) <= 0.01 \
		and float(continuity_certificates[0].get("maximumHeightDelta", INF)) <= 0.01
	var direct_routes_valid := direct_route_probes.size() >= 2 and direct_route_probes.all(func(probe: Dictionary) -> bool: return bool(probe.get("passed", false)))
	var passed := support_counts_valid \
		and continuity_valid \
		and direct_routes_valid \
		and selected_tile_links.is_empty() \
		and installed_support_pair_links.is_empty() \
		and installed_links.is_empty() \
		and invalid_installed_links.is_empty() \
		and pending_matches.is_empty() \
		and source_keys_valid
	return {
		"diagnosticOnly": true,
		"probe": "citadel_surface_transition_publication",
		"passed": passed,
		"reason": "" if passed else "citadel_surface_transition_publication_contract_failed",
		"seed": selected_seed,
		"supportRecords": support_records,
		"supportCountsValid": support_counts_valid,
		"requestedTileKeys": requested_tile_keys,
		"tileSourceKeys": {
			"-17,146": String((tile_snapshots.get("-17,146", {}) as Dictionary).get("sourceKey", "")),
			"-17,147": String((tile_snapshots.get("-17,147", {}) as Dictionary).get("sourceKey", ""))
		},
		"selectedTileLinks": selected_tile_links,
		"selectedLinkCount": selected_tile_links.size(),
		"laneNumbers": lane_numbers,
		"ownersValid": owners_valid,
		"endpointTiles": endpoint_tiles.keys(),
		"installedLinks": installed_links,
		"installedSupportPairLinks": installed_support_pair_links,
		"invalidInstalledLinks": invalid_installed_links,
		"pendingMatches": pending_matches,
		"continuityCertificates": continuity_certificates,
		"directRouteProbes": direct_route_probes,
		"publicationFailures": publication_failures,
		"supportSampleDiagnostics": support_sample_diagnostics,
		"seamCollision": seam_collision,
		"navigationMapReadiness": navmesh_snapshot.get("navigationMapReadiness", {}),
		"navmeshStats": navmesh_world.call("stats") if navmesh_world != null and navmesh_world.has_method("stats") else {}
	}


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
	var navmesh_snapshot: Dictionary = navmesh_world.call("debug_snapshot") as Dictionary if navmesh_world.has_method("debug_snapshot") else {}
	var installed_door_links: Dictionary = navmesh_snapshot.get("doorLinks", {}) as Dictionary
	var routes: Array[Dictionary] = []
	var source_portals: Array[Dictionary] = []
	var source_portals_passed := true
	for record_value in final_snapshot.get("citizens", []) as Array:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value as Dictionary
		var source_navigation := source_navigation_facts_for_failure(record)
		var source_door: Dictionary = source_navigation.get("door", {}) as Dictionary
		var portal_id := String(source_navigation.get("portalId", ""))
		var link_records: Array = installed_door_links.get(portal_id, []) as Array
		var source_links: Array[Dictionary] = []
		var fallback_links: Array[Dictionary] = []
		for link_value in link_records:
			if not (link_value is Dictionary):
				continue
			var link: Dictionary = link_value as Dictionary
			if bool(link.get("sourceDoor", false)):
				source_links.append(link.duplicate(true))
			else:
				fallback_links.append(link.duplicate(true))
		var source_interior: Vector3 = source_door.get("interior", Vector3.INF) as Vector3
		var source_exterior: Vector3 = source_door.get("exterior", Vector3.INF) as Vector3
		var endpoint_match := false
		var support_provenance_match := false
		var topology_proof := {}
		for source_link in source_links:
			var start: Vector3 = source_link.get("startPosition", Vector3.INF) as Vector3
			var end: Vector3 = source_link.get("endPosition", Vector3.INF) as Vector3
			var endpoint_resolution: Dictionary = source_link.get("endpointResolution", {}) as Dictionary
			var resolved_interior: Vector3 = endpoint_resolution.get("interior", Vector3.INF) as Vector3
			var resolved_exterior: Vector3 = endpoint_resolution.get("exterior", Vector3.INF) as Vector3
			if not start.is_finite() or not end.is_finite() or not resolved_interior.is_finite() or not resolved_exterior.is_finite():
				continue
			endpoint_match = endpoint_match or (start.distance_to(resolved_interior) <= 0.001 and end.distance_to(resolved_exterior) <= 0.001) or (start.distance_to(resolved_exterior) <= 0.001 and end.distance_to(resolved_interior) <= 0.001)
			support_provenance_match = String(source_link.get("startSupportId", "")) == String(source_door.get("interiorSupportId", "")) and String(source_link.get("endSupportId", "")) == String(source_door.get("exteriorSupportId", ""))
			var enabled_probe := navmesh_diagnostic_probe(navmesh_world, start, end, portal_id)
			var disabled_probe := navmesh_diagnostic_probe_without_door_links(navmesh_world, start, end, portal_id)
			var server_owners := navmesh_server_closest_points(navmesh_world, {"interior": start, "exterior": end})
			var interior_owner: Dictionary = (server_owners.get("interior", {}) as Dictionary).get("result", {}) as Dictionary
			var exterior_owner: Dictionary = (server_owners.get("exterior", {}) as Dictionary).get("result", {}) as Dictionary
			var enabled_crosses := bool(enabled_probe.get("usesExpectedDoorPortal", false)) and float(enabled_probe.get("endpointDistance", INF)) <= 0.001
			var disabled_crosses := float(disabled_probe.get("endpointDistance", INF)) <= 0.001
			topology_proof = {
				"enabled": enabled_probe,
				"disabled": disabled_probe,
				"serverOwners": server_owners,
				"serverEndpointsOwned": bool(interior_owner.get("found", false)) and bool(exterior_owner.get("found", false)) and not String(interior_owner.get("regionId", "")).is_empty() and not String(exterior_owner.get("regionId", "")).is_empty(),
				"enabledCrossesExactLink": enabled_crosses,
				"disabledFailsCrossing": not disabled_crosses
			}
		var readiness: Dictionary = navmesh_snapshot.get("navigationMapReadiness", {}) as Dictionary
		var topology_passed := bool(topology_proof.get("serverEndpointsOwned", false)) and bool(readiness.get("ready", false)) and int(readiness.get("iterationId", 0)) > 0
		var source_portal_passed := not portal_id.is_empty() and bool(source_door.get("sourcePortalReady", false)) and source_links.size() == 1 and fallback_links.is_empty() and endpoint_match and support_provenance_match and topology_passed
		source_portals.append({
			"actorId": String(record.get("id", "")),
			"residenceId": String(record.get("residenceId", "")),
			"portalId": portal_id,
			"sourcePortalReady": bool(source_door.get("sourcePortalReady", false)),
			"sourceDoor": source_door,
			"sourceLinks": source_links,
			"fallbackLinks": fallback_links,
			"endpointMatch": endpoint_match,
			"supportProvenanceMatch": support_provenance_match,
			"topologyProof": topology_proof,
			"passed": source_portal_passed
		})
		source_portals_passed = source_portals_passed and source_portal_passed
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
		"sourcePortalRoutes": {
			"passed": source_portals_passed and not source_portals.is_empty(),
			"portals": source_portals
		},
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
		"throughDoorWithoutDoorLink": navmesh_diagnostic_probe_without_door_links(navmesh_world, interior, exterior, portal_id),
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
	var query_value = navmesh_world.call("_query_path_points", start, target, {"queryApi": "query_path"})
	var query: Dictionary = query_value as Dictionary if query_value is Dictionary else {}
	var points: Array[Vector3] = []
	for point_value in query.get("path", []) as Array:
		if point_value is Vector3:
			points.append(point_value as Vector3)
	var door_actions_value = navmesh_world.call("diagnostic_door_actions_for_path", points, {}) if navmesh_world.has_method("diagnostic_door_actions_for_path") else {}
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


func navmesh_diagnostic_probe_without_door_links(navmesh_world, start: Vector3, target: Vector3, portal_id: String) -> Dictionary:
	if navmesh_world == null or not navmesh_world.has_method("diagnostic_query_path_without_door_links"):
		return {"reason": "missing_door_link_diagnostic"}
	var points_value = navmesh_world.call("diagnostic_query_path_without_door_links", start, target, [portal_id], {"queryApi": "query_path"})
	var points: Array = points_value if points_value is Array else []
	var endpoint := Vector3.INF
	if not points.is_empty() and points[points.size() - 1] is Vector3:
		endpoint = points[points.size() - 1] as Vector3
	return {
		"diagnosticOnly": true,
		"disabledDoorPortalId": portal_id,
		"start": start,
		"target": target,
		"pointCount": points.size(),
		"path": points,
		"endpoint": endpoint,
		"endpointDistance": endpoint.distance_to(target)
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


func route_record_is_terminal_failure(record: Dictionary) -> bool:
	if String(record.get("routeStatus", "")) in ["unreachable", "unreachable_static", "invalid_goal", "failed_internal"]:
		return true
	if String(record.get("routeReason", "")) == "path_endpoint_mismatch":
		return true
	var authority: Dictionary = record.get("routeAuthority", {}) if record.get("routeAuthority", {}) is Dictionary else {}
	if String(authority.get("state", "")) in ["unreachable", "unreachable_static", "invalid_goal", "failed_internal"]:
		return true
	if String(authority.get("reason", "")) == "path_endpoint_mismatch":
		return true
	var authority_route: Dictionary = authority.get("route", {}) if authority.get("route", {}) is Dictionary else {}
	return String(authority_route.get("reason", "")) == "path_endpoint_mismatch"


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
		if route_record_is_terminal_failure(record):
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
		if route_record_is_terminal_failure(day_record):
			day_blocked_count += 1
	var expected_count := (residence_manifest.get("citizens", []) as Array).size()
	var day_admission: Dictionary = order_admissions.get("day", {}) if order_admissions.get("day", {}) is Dictionary else {}
	var night_admission: Dictionary = order_admissions.get("night", {}) if order_admissions.get("night", {}) is Dictionary else {}
	var orders_admitted := bool(day_admission.get("timely", false)) and bool(night_admission.get("timely", false))
	var order_admission_performance_passed := bool(day_admission.get("wallPerformancePassed", false)) and bool(night_admission.get("wallPerformancePassed", false))
	var route_outcome_passed := expected_count > 0 and records.size() == expected_count and inside_count == expected_count and blocked_count == 0 and day_records.size() == expected_count and day_outside_count == expected_count and day_blocked_count == 0
	var crowd_stress_passed := bool(crowd_stress_result.get("passed", false))
	var door_lifecycle_passed := bool(acceptance_door_lifecycle_summary.get("passed", false))
	var night_progress_passed := bool(acceptance_night_progress.get("passed", false))
	var source_portal_routes_passed := bool((acceptance_post_navigation_audit.get("sourcePortalRoutes", {}) as Dictionary).get("passed", false))
	var passed := route_outcome_passed and orders_admitted and order_admission_performance_passed and crowd_stress_passed and door_lifecycle_passed and night_progress_passed and source_portal_routes_passed
	var reason := ""
	if not orders_admitted:
		reason = "Citadel civic orders were not all accepted promptly through the public NPC order contract"
	elif not order_admission_performance_passed:
		reason = "Citadel civic order admission encountered a wall-clock frame stall"
	elif not source_portal_routes_passed:
		reason = "Citadel residents did not retain source-authored door portal links through the live navigation lifecycle"
	elif not door_lifecycle_passed:
		reason = "Citadel citizens did not prove open, collision-clear, exterior-clearance, strict-return, and close through their real home doors"
	elif not night_progress_passed:
		reason = "Citadel night routes exhausted their progress grace without reaching strict interiors"
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
		"doorLifecycle": acceptance_door_lifecycle_summary.duplicate(true),
		"nightProgress": acceptance_night_progress.duplicate(true),
		"sourcePortalRoutes": (acceptance_post_navigation_audit.get("sourcePortalRoutes", {}) as Dictionary).duplicate(true),
		"orderAdmissionPerformancePassed": order_admission_performance_passed,
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
		"passed": status != "failed" \
			and (not acceptance_mode or bool(acceptance_result.get("passed", false))) \
			and (not surface_continuity_acceptance_mode or bool(surface_continuity_acceptance_result.get("passed", false))),
		"failureCount": 1 if status == "failed" else 0,
		"evidenceLevel": "acceptance" if surface_continuity_acceptance_mode else "integration",
		"scope": "Headed normal-world Citadel seam acceptance with production NPC bodies, routing, motor, collision and ORCA." if surface_continuity_acceptance_mode else "Headed Citadel Life loading and steady-state performance diagnostic. It measures the real fixture's production Main scene, terrain collision, published building records, doors, NPC bodies and clock, but is not a player gameplay acceptance claim.",
		"seed": selected_seed,
		"citadelScale": selected_citadel_scale,
		"citadelSpan": maxf(float(recipe.get("width", 0.0)), float(recipe.get("depth", 0.0))),
		"terrainSite": fixture_site.duplicate(true),
		"loadDurationMs": float((profile_load_completed_usec if profile_load_completed_usec > 0 else Time.get_ticks_usec()) - profile_started_usec) / 1000.0,
		"loadingStages": profile_stages.duplicate(true),
		"steadyStateSamples": profile_phase_samples.duplicate(true),
		"acceptance": acceptance_result.duplicate(true),
		"doorLifecycle": acceptance_door_lifecycle_summary.duplicate(true),
		"nightProgress": acceptance_night_progress.duplicate(true),
		"acceptanceConfiguration": {
			"daySeconds": acceptance_day_seconds,
			"nightSeconds": acceptance_night_seconds,
			"defaultDaySeconds": DEFAULT_ACCEPTANCE_DAY_SECONDS,
			"defaultNightSeconds": DEFAULT_ACCEPTANCE_NIGHT_SECONDS
		},
		"failureDiagnostics": acceptance_failure_diagnostics.duplicate(true),
		"fixtureFailureDetails": fixture_failure_details.duplicate(true),
		"postAcceptanceNavigationAudit": acceptance_post_navigation_audit.duplicate(true),
		"linkDiagnostics": link_diagnostics.duplicate(true),
		"surfaceContinuityAcceptance": surface_continuity_acceptance_result.duplicate(true),
		"timeline": acceptance_timeline.duplicate(true),
		"crowdPhysicsEvidence": crowd_physics_evidence.duplicate(true),
		"crowdStress": crowd_stress_result.duplicate(true),
		"runtime": summary,
		"sourceCounts": {
			"blueprintParts": blueprint.parts.size() if blueprint != null else 0,
			"furnishingParts": furnishing_plan.parts.size() if furnishing_plan != null else 0,
			"livingSurfaceTreeRecordCount": living_tree_records.size(),
			"generatedLivingTreeCount": generated_living_tree_count,
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
		"keepEntryCollision": keep_entry_collision_evidence.duplicate(true),
		"keepEntryPlayerSweep": keep_entry_player_sweep_evidence.duplicate(true),
		"raisedRouteTransitionHandoff": raised_route_transition_handoff_evidence.duplicate(true),
		"raisedRouteJunctionTraversals": raised_route_junction_traversal_evidence.duplicate(true),
		"raisedRouteJunctionCaptures": raised_route_junction_captures.duplicate(true),
		"raisedRouteRoadbeds": raised_route_roadbed_evidence.duplicate(true),
		"raisedRouteCollisionNegativeControls": raised_route_collision_negative_controls.duplicate(true),
		"residenceFoundationSupports": residence_foundation_support_evidence.duplicate(true),
		"walkableSurfaceCollision": walkable_surface_collision_evidence.duplicate(true),
		"livedInSurfaceEvidence": lived_in_surface_evidence(),
		"captures": visual_captures.duplicate(true),
		"failureReason": failure_reason,
		"finishedUtc": Time.get_datetime_string_from_system(true, true)
	}
	write_text_file(profile_report_path, JSON.stringify(report, "\t"))
	write_profile_progress("status=%s loadDurationMs=%.3f" % [status, float(report.get("loadDurationMs", 0.0))])


func lived_in_surface_evidence() -> Dictionary:
	var history_event_counts := {}
	var repair_cluster_count := 0
	var published_tree_ids: Array[String] = []
	if living_tree_root != null and is_instance_valid(living_tree_root):
		for tree in living_tree_root.get_children():
			if tree is Node3D and bool((tree as Node3D).get_meta("citadel_life_generated_tree", false)):
				published_tree_ids.append(String((tree as Node3D).name))
	for publisher in building_publishers:
		if publisher == null or not publisher.has_method("summary"):
			continue
		var publication: Dictionary = publisher.summary()
		repair_cluster_count += int(publication.get("masonryRepairClusterCount", 0))
		var history: Dictionary = publication.get("surfaceHistory", {}) as Dictionary
		var publisher_counts: Dictionary = history.get("eventCounts", {}) as Dictionary
		for kind_value in publisher_counts.keys():
			var kind := String(kind_value)
			history_event_counts[kind] = int(history_event_counts.get(kind, 0)) + int(publisher_counts.get(kind, 0))
	var window_program := BuildingInteriorProgramScript.audit_plan(blueprint, furnishing_plan) if blueprint != null and furnishing_plan != null else {}
	return {
		"usesSharedBuildingPartPublisher": not building_publishers.is_empty(),
		"usesProductionTreeSpawnService": generated_living_tree_count == living_tree_records.size(),
		"treeRecordCount": living_tree_records.size(),
		"publishedTreeCount": generated_living_tree_count,
		"publishedTreeIds": published_tree_ids,
		"surfaceHistoryEventCounts": history_event_counts,
		"masonryRepairClusterCount": repair_cluster_count,
		"windowInteriorProgram": window_program
	}


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

extends Node

const NpcTestClockScript := preload("res://scripts/testing/npc/NpcTestClock.gd")
const NpcTestAssertionsScript := preload("res://scripts/testing/npc/NpcTestAssertions.gd")
const PlayerControllerScript := preload("res://scripts/PlayerController.gd")
const SaveSystemScript := preload("res://scripts/SaveSystem.gd")
const NpcSystemScript := preload("res://scripts/NpcSystem.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcAgentContextScript := preload("res://scripts/npc_ai/NpcAgentContext.gd")
const NpcBlackboardScript := preload("res://scripts/npc_ai/NpcBlackboard.gd")
const NpcBrainSchedulerScript := preload("res://scripts/npc_ai/NpcBrainScheduler.gd")
const NpcAutonomySystemScript := preload("res://scripts/npc_ai/NpcAutonomySystem.gd")
const TraversalProfileScript := preload("res://scripts/npc_ai/contracts/TraversalProfile.gd")
const RouteRequestScript := preload("res://scripts/npc_ai/contracts/RouteRequest.gd")
const RouteResultScript := preload("res://scripts/npc_ai/contracts/RouteResult.gd")
const NpcActionInstanceScript := preload("res://scripts/npc_ai/contracts/NpcActionInstance.gd")
const InteractionResultScript := preload("res://scripts/npc_ai/contracts/InteractionResult.gd")
const NpcTelemetryServiceScript := preload("res://scripts/npc_ai/debug/NpcTelemetryService.gd")
const NavigationChangeBusScript := preload("res://scripts/npc_ai/navigation/NavigationChangeBus.gd")
const NavigationWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavigationWorldService.gd")
const GeneratedWorldNavigationAdapterScript := preload("res://scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd")
const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavmeshWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
const NavigationSemanticServiceScript := preload("res://scripts/npc_ai/navigation/NavigationSemanticService.gd")
const NavigationBakeDescriptorScript := preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const CharacterMotor3DScript := preload("res://scripts/npc_ai/motor/CharacterMotor3D.gd")
const CharacterMotorCommandScript := preload("res://scripts/npc_ai/contracts/CharacterMotorCommand.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const RouteLeaseScript := preload("res://scripts/npc_ai/contracts/RouteLease.gd")
const RouteTicketScript := preload("res://scripts/npc_ai/contracts/RouteTicket.gd")
const NpcRouteAuthorityScript := preload("res://scripts/npc_ai/routing/NpcRouteAuthority.gd")
const NpcRouteAuthorityV2Script := preload("res://scripts/npc_ai/routing/NpcRouteAuthorityV2.gd")
const NavDataReadinessServiceScript := preload("res://scripts/npc_ai/routing/NavDataReadinessService.gd")
const NpcMotionControllerScript := preload("res://scripts/npc_ai/NpcMotionController.gd")
const NpcSafePlacementServiceScript := preload("res://scripts/npc_ai/NpcSafePlacementService.gd")
const NpcNavigationCoordinatorScript := preload("res://scripts/npc_ai/routing/NpcNavigationCoordinator.gd")
const NpcRouteMovementControllerScript := preload("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")
const NpcRouteLeaseExecutorScript := preload("res://scripts/npc_ai/movement/NpcRouteLeaseExecutor.gd")
const NpcAgentScript := preload("res://scripts/npc_ai/NpcAgent.gd")

class PassthroughCrowdVelocityService:
	extends RefCounted

	func resolve_safe_velocity(_entry: Dictionary, _body: CharacterBody3D, desired_velocity: Vector3, _context := {}) -> Dictionary:
		return {
			"active": false,
			"safeVelocity": desired_velocity,
			"status": "synthetic_callback",
			"reason": "route_executor_contract",
			"callbackFresh": true,
			"fallbackUsed": false,
			"movementBlocked": false,
			"activeRegistrationCount": 1
		}

class FakeAuthorityRouteDelegate:
	extends RefCounted
	var route := {}
	var calls := 0

	func plan_route(_entry: Dictionary, _intent: Dictionary) -> Dictionary:
		calls += 1
		return route.duplicate(true)

	func stats() -> Dictionary:
		return { "calls": calls }

class FakeCursorCollisionProbe:
	extends RefCounted
	var calls: Array[Dictionary] = []

	func probe_route(_entry: Dictionary, _route: Dictionary, _intent: Dictionary, options := {}) -> Dictionary:
		var cursor: Dictionary = options.get("cursor", {}) if options.get("cursor", {}) is Dictionary else {}
		calls.append({
			"maxSamples": int(options.get("maxSamples", 0)),
			"cursor": cursor.duplicate(true)
		})
		if cursor.is_empty():
			return {
				"ok": false,
				"status": "pending_probe",
				"reason": "collision_probe_budget",
				"authoritative": true,
				"sampleCount": 3,
				"details": {
					"segmentIndex": 2,
					"sampleIndex": 4,
					"completedSamples": 3,
					"cursor": {
						"segmentIndex": 2,
						"sampleIndex": 4,
						"completedSamples": 3
					}
				}
			}
		return {
			"ok": true,
			"status": "passed",
			"reason": "",
			"authoritative": true,
			"sampleCount": 2,
			"details": {
				"completedSamples": int(cursor.get("completedSamples", 0)) + 2,
				"resumedSegment": int(cursor.get("segmentIndex", -1)),
				"resumedSample": int(cursor.get("sampleIndex", -1))
			}
		}

class FakeRouteAuthorityV2Probe:
	extends RefCounted
	var response := {}
	var calls: Array[Dictionary] = []

	func probe_route(_entry: Dictionary, _route: Dictionary, _intent: Dictionary, options := {}) -> Dictionary:
		var cursor: Dictionary = options.get("cursor", {}) if options.get("cursor", {}) is Dictionary else {}
		calls.append({
			"maxSamples": int(options.get("maxSamples", 0)),
			"cursor": cursor.duplicate(true)
		})
		return response.duplicate(true)

class FakeSequenceRouteAuthorityV2Probe:
	extends RefCounted
	var responses: Array[Dictionary] = []
	var calls: Array[Dictionary] = []

	func probe_route(_entry: Dictionary, route: Dictionary, _intent: Dictionary, options := {}) -> Dictionary:
		var cursor: Dictionary = options.get("cursor", {}) if options.get("cursor", {}) is Dictionary else {}
		calls.append({
			"source": String(route.get("source", "")),
			"targetCell": route.get("targetCell", Vector2i(999999, 999999)),
			"maxSamples": int(options.get("maxSamples", 0)),
			"cursor": cursor.duplicate(true)
		})
		var index := mini(calls.size() - 1, maxi(0, responses.size() - 1))
		if responses.is_empty():
			return {}
		return responses[index].duplicate(true)

class FakeProbeRepairSubstrate:
	extends RefCounted
	var repaired_route := {}
	var calls: Array[Dictionary] = []

	func repair_route_after_probe(_entry: Dictionary, start_cell: Vector2i, candidate_cells: Array, failed_route: Dictionary, probe_certificate: Dictionary, options := {}) -> Dictionary:
		calls.append({
			"startCell": start_cell,
			"candidateCells": candidate_cells.duplicate(),
			"failedSource": String(failed_route.get("source", "")),
			"blockedReason": String(probe_certificate.get("reason", "")),
			"avoidCells": (options.get("avoidCells", []) as Array).duplicate() if options.get("avoidCells", []) is Array else []
		})
		return repaired_route.duplicate(true)

class FakeNavDataReadinessOwner:
	extends RefCounted
	var mark_loading := false
	var ready := true

	func _ensure_navmesh_route_tiles(entry: Dictionary, _intent: Dictionary) -> bool:
		entry["navmeshRouteTilesStillLoading"] = mark_loading
		return ready

var suite_filter := "contract"
var case_filter := ""
var time_mode := "both"
var seed := "atlas-1492"
var report_path := ""
var progress_path := ""
var trace_dir := ""
var screenshot_dir := ""
var run_token := ""
var branch := ""
var git_commit := ""
var started_utc := ""
var finished_utc := ""
var started_unix := 0.0
var watchdog_seconds := 18.0
var elapsed := 0.0
var finished := false
var failed := false
var results: Array[Dictionary] = []
var route_case_provider = null
var repair_case_provider = null
var door_case_provider = null
var avoidance_case_provider = null
var traffic_case_provider = null
var behavior_case_provider = null
var interaction_case_provider = null
var streaming_save_case_provider = null
var soak_case_provider = null
var metrics := {
	"assertions": 0,
	"selectedCases": 0,
	"selectedRuns": 0
}

class FakeRouteWorld:
	var revision_value := "rev-b"

	func revision() -> String:
		return revision_value

	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x), roundi(position.z))

class FakeRoutePlanner:
	var result := {}
	var calls := 0

	func _init(route_result := {}) -> void:
		result = route_result

	func plan_route(_entry: Dictionary, _intent: Dictionary) -> Dictionary:
		calls += 1
		return result.duplicate(true)

	func begin_frame() -> void:
		pass

	func stats() -> Dictionary:
		return {}

class FakeCoordinatorWorld:
	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x), roundi(position.z))

	func revision() -> String:
		return "fake-coordinator-rev"

class FakeCoordinatorGoalPlanner:
	func make_intent(_entry: Dictionary, target: Vector3, _max_distance: float, moving_home := false, allow_outside := false) -> Dictionary:
		return {
			"kind": "move",
			"target": target,
			"targetCell": Vector2i(roundi(target.x), roundi(target.z)),
			"movingHome": moving_home,
			"allowOutside": allow_outside
		}

class FakeCoordinatorLocomotion:
	var deltas: Array = []

	func begin_frame() -> void:
		pass

	func move(_entry: Dictionary, intent: Dictionary, max_distance: float, _planner, _world) -> Dictionary:
		deltas.append(float(intent.get("physicsDelta", -1.0)))
		return { "moved": max_distance, "status": "moving", "reason": "" }

class FakeGeneratedWorldMain:
	extends Node
	var WATER_LEVEL := -1000.0
	var blocks := {}

	func surface_y_at_cell(_cell) -> float:
		return 0.0

func _ready() -> void:
	configure_from_environment()
	started_unix = Time.get_unix_time_from_system()
	started_utc = Time.get_datetime_string_from_system(true)
	write_progress("start")
	call_deferred("run")

func _process(delta: float) -> void:
	if finished:
		return
	elapsed += delta
	if elapsed > watchdog_seconds:
		add_result(
			"npc_contract_runner_watchdog",
			time_mode,
			false,
			"watchdog %.2fs exceeded" % watchdog_seconds,
			["watchdog_seconds"],
			{ "elapsed": elapsed }
		)
		finish()

func configure_from_environment() -> void:
	suite_filter = OS.get_environment("VOXEL_NPC_TEST_SUITE").to_lower()
	if suite_filter == "":
		suite_filter = "contract"
	case_filter = OS.get_environment("VOXEL_NPC_TEST_CASE")
	time_mode = OS.get_environment("VOXEL_NPC_TIME_MODE").to_lower()
	if time_mode == "":
		time_mode = "both"
	seed = OS.get_environment("VOXEL_NPC_TEST_SEED")
	if seed == "":
		seed = "atlas-1492"
	report_path = OS.get_environment("VOXEL_NPC_TEST_REPORT")
	if report_path == "":
		report_path = "user://npc-contract-report.json"
	progress_path = OS.get_environment("VOXEL_NPC_TEST_PROGRESS")
	trace_dir = OS.get_environment("VOXEL_NPC_TEST_TRACE_DIR")
	screenshot_dir = OS.get_environment("VOXEL_NPC_TEST_SCREENSHOT_DIR")
	run_token = OS.get_environment("VOXEL_NPC_TEST_RUN_TOKEN")
	branch = OS.get_environment("VOXEL_GIT_BRANCH")
	git_commit = OS.get_environment("VOXEL_GIT_COMMIT")
	var watchdog_value := OS.get_environment("VOXEL_NPC_TEST_WATCHDOG_SECONDS")
	if watchdog_value != "":
		watchdog_seconds = maxf(1.0, float(watchdog_value))

func run() -> void:
	var cases := contract_cases()
	var matched_case_count := 0
	var matched_run_count := 0
	for test_case in cases:
		if not suite_matches(String(test_case.get("suite", ""))):
			continue
		if case_filter != "" and String(test_case.get("id", "")) != case_filter:
			continue
		var modes := selected_modes(test_case)
		if modes.is_empty():
			continue
		matched_case_count += 1
		for mode in modes:
			matched_run_count += 1
			if finished:
				return
			write_progress("%s:%s" % [String(test_case.get("id", "")), mode])
			var case_start := Time.get_unix_time_from_system()
			var outcome: Dictionary = test_case["callable"].call(mode)
			var duration := Time.get_unix_time_from_system() - case_start
			add_result(
				String(test_case.get("id", "")),
				mode,
				bool(outcome.get("passed", false)),
				String(outcome.get("details", "")),
				outcome.get("assertions", []),
				outcome.get("keyState", {}),
				duration
			)
	metrics["selectedCases"] = matched_case_count
	metrics["selectedRuns"] = matched_run_count
	if matched_run_count == 0:
		add_result(
			"npc_contract_no_matching_tests",
			time_mode,
			false,
			"suite='%s' case='%s' time='%s'" % [suite_filter, case_filter, time_mode],
			["matching_case"],
			{}
		)
	finish()

func contract_cases() -> Array[Dictionary]:
	var cases: Array[Dictionary] = [
		{
			"id": "npc_contract_clock_day_snapshot",
			"suite": "contract",
			"timeModes": ["day"],
			"callable": Callable(self, "test_clock_day_snapshot")
		},
		{
			"id": "npc_contract_clock_night_snapshot",
			"suite": "contract",
			"timeModes": ["night"],
			"callable": Callable(self, "test_clock_night_snapshot")
		},
		{
			"id": "npc_contract_runner_filters",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_runner_filters")
		},
		{
			"id": "npc_contract_report_freshness",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_report_freshness")
		},
		{
			"id": "npc_contract_report_schema",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_report_schema")
		},
		{
			"id": "npc_contract_route_status_terminal",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_status_terminal")
		},
		{
			"id": "npc_contract_partial_never_arrival",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_partial_never_arrival")
		},
		{
			"id": "npc_contract_route_authority_state_mapping",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_state_mapping")
		},
		{
			"id": "npc_contract_route_authority_attaches_probe_certificate",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_attaches_probe_certificate")
		},
		{
			"id": "npc_contract_route_authority_requires_authoritative_probe_for_ready",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_requires_authoritative_probe_for_ready")
		},
		{
			"id": "npc_contract_route_authority_resumes_collision_probe",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_resumes_collision_probe")
		},
		{
			"id": "npc_contract_route_authority_v2_lifecycle",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_v2_lifecycle")
		},
		{
			"id": "npc_contract_route_authority_v2_cancellation",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_v2_cancellation")
		},
		{
			"id": "npc_contract_route_authority_v2_requires_probe_certificate",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_v2_requires_probe_certificate")
		},
		{
			"id": "npc_contract_route_authority_v2_probe_commit_ready",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_v2_probe_commit_ready")
		},
		{
			"id": "npc_contract_route_authority_v2_probe_blocked_before_movement",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_v2_probe_blocked_before_movement")
		},
		{
			"id": "npc_contract_route_authority_v2_dynamic_static_body_is_retryable",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_v2_dynamic_static_body_is_retryable")
		},
		{
			"id": "npc_contract_dynamic_actor_not_baked_as_static_prop",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_dynamic_actor_not_baked_as_static_prop")
		},
		{
			"id": "npc_contract_static_prop_reserves_actor_clearance",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_static_prop_reserves_actor_clearance")
		},
		{
			"id": "npc_contract_route_authority_v2_repairs_static_probe_block",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_v2_repairs_static_probe_block")
		},
		{
			"id": "npc_contract_route_authority_v2_defers_probe_repair_under_budget",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_v2_defers_probe_repair_under_budget")
		},
		{
			"id": "npc_contract_route_authority_v2_probe_pending_budget",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_authority_v2_probe_pending_budget")
		},
		{
			"id": "npc_contract_route_lease_executor_follows_v2_lease",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_lease_executor_follows_v2_lease")
		},
		{
			"id": "npc_contract_route_lease_executor_requires_crowd_authority",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_lease_executor_requires_crowd_authority")
		},
		{
			"id": "npc_contract_route_lease_executor_accepts_crossed_waypoint",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_lease_executor_accepts_crossed_waypoint")
		},
		{
			"id": "npc_contract_route_lease_executor_preserves_moving_home_semantics",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_lease_executor_preserves_moving_home_semantics")
		},
		{
			"id": "npc_contract_route_lease_executor_rejects_unready_lease",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_lease_executor_rejects_unready_lease")
		},
		{
			"id": "npc_contract_route_ticket_diagnostic_state_names",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_ticket_diagnostic_state_names")
		},
		{
			"id": "npc_contract_nav_data_readiness_missing_tiles_pending",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_nav_data_readiness_missing_tiles_pending")
		},
		{
			"id": "npc_contract_navigation_map_sync_pending_is_nav_data",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_navigation_map_sync_pending_is_nav_data")
		},
		{
			"id": "npc_contract_stable_tie_break",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_stable_tie_break")
		},
		{
			"id": "npc_contract_urgent_brain_admission_is_fair",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_urgent_brain_admission_is_fair")
		},
		{
			"id": "npc_contract_scripted_order_stall_trace_precedes_route_request",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_scripted_order_stall_trace_precedes_route_request")
		},
		{
			"id": "npc_contract_collision_recovery_stall_trace",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_collision_recovery_stall_trace")
		},
		{
			"id": "npc_contract_profile_capability_filter",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_profile_capability_filter")
		},
		{
			"id": "npc_contract_rng_stream_isolation",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_rng_stream_isolation")
		},
		{
			"id": "npc_contract_bounded_trace_and_cache",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_bounded_trace_and_cache")
		},
		{
			"id": "npc_contract_cancellation_generation",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_cancellation_generation")
		},
		{
			"id": "npc_contract_change_bus_coalesces_tiles",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_change_bus_coalesces_tiles")
		},
		{
			"id": "npc_contract_change_bus_monotonic_revision",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_change_bus_monotonic_revision")
		},
		{
			"id": "npc_contract_guard_duty_not_can_fight",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_guard_duty_not_can_fight")
		},
		{
			"id": "npc_contract_autonomy_composition_no_main_layer",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_autonomy_composition_no_main_layer")
		},
		{
			"id": "npc_contract_rng_stream_isolation_baseline",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_rng_stream_isolation_baseline")
		},
		{
			"id": "npc_contract_player_motor_characterization_baseline",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_player_motor_characterization_baseline")
		},
		{
			"id": "npc_contract_existing_save_defaults_baseline",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_existing_save_defaults_baseline")
		},
		{
			"id": "npc_contract_existing_npc_navigation_runner_callable",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_existing_npc_navigation_runner_callable")
		},
		{
			"id": "npc_contract_all_runner_registry_baseline",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_all_runner_registry_baseline")
		}
	]
	cases.append_array(motor_cases())
	cases.append_array(nav_world_cases())
	if suite_filter == "route" or suite_filter == "all" or suite_filter == "":
		cases.append_array(route_cases())
	if suite_filter == "repair" or suite_filter == "all" or suite_filter == "":
		cases.append_array(repair_cases())
	if suite_filter == "door" or suite_filter == "all" or suite_filter == "":
		cases.append_array(door_cases())
	if suite_filter == "avoidance" or suite_filter == "all" or suite_filter == "":
		cases.append_array(avoidance_cases())
	if suite_filter == "traffic" or suite_filter == "all" or suite_filter == "":
		cases.append_array(traffic_cases())
	if suite_filter == "behavior" or suite_filter == "all" or suite_filter == "":
		cases.append_array(behavior_cases())
	if suite_filter == "interaction" or suite_filter == "all" or suite_filter == "":
		cases.append_array(interaction_cases())
	if suite_filter == "streaming_save" or suite_filter == "all" or suite_filter == "":
		cases.append_array(streaming_save_cases())
	if suite_filter == "soak" or suite_filter == "all" or suite_filter == "":
		cases.append_array(soak_cases())
	return cases

func motor_cases() -> Array[Dictionary]:
	var ids := [
		["npc_motor_substep_uses_step_delta", "test_npc_motor_substep_uses_step_delta"],
		["npc_motor_route_replans_after_actor_displacement", "test_npc_motor_route_replans_after_actor_displacement"],
		["npc_motor_trims_reinstalled_route_prefix_to_current_cell", "test_npc_motor_trims_reinstalled_route_prefix_to_current_cell"],
		["npc_motor_player_characterization_flat", "test_motor_player_characterization_flat"],
		["npc_motor_player_characterization_slope", "test_motor_player_characterization_slope"],
		["npc_motor_player_characterization_jump", "test_motor_player_characterization_jump"],
		["npc_motor_npc_flat_acceleration", "test_motor_npc_flat_acceleration"],
		["npc_motor_npc_slope_limit", "test_motor_npc_slope_limit"],
		["npc_motor_npc_step_up_limit", "test_motor_npc_step_up_limit"],
		["npc_motor_npc_safe_drop", "test_motor_npc_safe_drop"],
		["npc_motor_wall_slide_no_penetration", "test_motor_wall_slide_no_penetration"],
		["npc_motor_fence_window_corner_no_penetration", "test_motor_fence_window_corner_no_penetration"],
		["npc_motor_closed_door_blocks", "test_motor_closed_door_blocks"],
		["npc_motor_open_door_clears", "test_motor_open_door_clears"],
		["npc_motor_door_action_matches_portal_id", "test_motor_door_action_matches_portal_id"],
		["npc_motor_player_npc_solid_separation", "test_motor_player_npc_solid_separation"],
		["npc_motor_decorative_path_torch_nonblocking_mask", "test_motor_decorative_path_torch_nonblocking_mask"],
		["npc_motor_no_route_transform_write", "test_motor_no_route_transform_write"],
		["npc_motor_no_unstick_teleport", "test_motor_no_unstick_teleport"],
		["npc_motor_preserves_active_route_on_transient_replan_failure", "test_motor_preserves_active_route_on_transient_replan_failure"],
		["npc_motor_skips_optional_home_threshold_on_endpoint_snap_failure", "test_motor_skips_optional_home_threshold_on_endpoint_snap_failure"],
		["npc_motor_spawn_safe_placement", "test_motor_spawn_safe_placement"],
		["npc_motor_spawn_rejects_occupied_capsule", "test_motor_spawn_rejects_occupied_capsule"],
		["npc_motor_every_active_actor_physics_tick", "test_motor_every_active_actor_physics_tick"]
	]
	var cases: Array[Dictionary] = []
	for spec in ids:
		cases.append({
			"id": String(spec[0]),
			"suite": "motor",
			"timeModes": ["day", "night"],
			"callable": Callable(self, String(spec[1]))
		})
	return cases

func nav_world_cases() -> Array[Dictionary]:
	var ids := [
		["npc_navworld_live_tile_snapshot_includes_collision_records", "test_npc_navworld_live_tile_snapshot_includes_collision_records"],
		["npc_navworld_event_block_add_dirty_exact_tiles", "test_navworld_event_block_add_dirty_exact_tiles"],
		["npc_navworld_event_block_remove_dirty_exact_tiles", "test_navworld_event_block_remove_dirty_exact_tiles"],
		["npc_navworld_event_prop_remove_dirty_exact_tiles", "test_navworld_event_prop_remove_dirty_exact_tiles"],
		["npc_navworld_event_terrain_edit_dirty_exact_tiles", "test_navworld_event_terrain_edit_dirty_exact_tiles"],
		["npc_navworld_event_chunk_load_unload", "test_navworld_event_chunk_load_unload"],
		["npc_navworld_tile_source_key_is_tile_stable", "test_navworld_tile_source_key_is_tile_stable"],
		["npc_navworld_incremental_prop_change_keeps_unrelated_tile_cache", "test_navworld_incremental_prop_change_keeps_unrelated_tile_cache"],
		["npc_navworld_semantic_change_preserves_geometry_tile_cache", "test_navworld_semantic_change_preserves_geometry_tile_cache"],
		["npc_navworld_no_scene_scan_revision", "test_navworld_no_scene_scan_revision"],
		["npc_navworld_multisurface_bridge", "test_navworld_multisurface_bridge"],
		["npc_navworld_tunnel_headroom", "test_navworld_tunnel_headroom"],
		["npc_navworld_stacked_surfaces_disconnected", "test_navworld_stacked_surfaces_disconnected"],
		["npc_navworld_profile_clearance_small_large", "test_navworld_profile_clearance_small_large"],
		["npc_navworld_slope_step_drop_edges", "test_navworld_slope_step_drop_edges"],
		["npc_navworld_corner_cut_rejected", "test_navworld_corner_cut_rejected"],
		["npc_navworld_door_portal_edge_registered", "test_navworld_door_portal_edge_registered"],
		["npc_navworld_door_axis_uses_wall_blockers", "test_navworld_door_axis_uses_wall_blockers"],
		["npc_navworld_semantic_home_interior", "test_navworld_semantic_home_interior"],
		["npc_navworld_semantic_guard_post", "test_navworld_semantic_guard_post"],
		["npc_navworld_semantic_road_and_work_anchor", "test_navworld_semantic_road_and_work_anchor"],
		["npc_navworld_unloaded_tile_not_traversable", "test_navworld_unloaded_tile_not_traversable"],
		["npc_navworld_build_budget_yields_and_resumes", "test_navworld_build_budget_yields_and_resumes"],
		["npc_navworld_deterministic_tile_output", "test_navworld_deterministic_tile_output"],
		["npc_navmesh_backend_default_navmesh", "test_navmesh_backend_default_navmesh"],
		["npc_navmesh_backend_explicit_navmesh", "test_navmesh_backend_explicit_navmesh"],
		["npc_navmesh_backend_custom_alias_navmesh", "test_navmesh_backend_custom_alias_navmesh"],
		["npc_navmesh_descriptor_deterministic_signature", "test_navmesh_descriptor_deterministic_signature"],
		["npc_navmesh_tile_snapshot_descriptor_deterministic", "test_navmesh_tile_snapshot_descriptor_deterministic"],
		["npc_navmesh_adjacent_tile_collision_clearance", "test_navmesh_adjacent_tile_collision_clearance"],
		["npc_navmesh_source_door_portal_physical_clearance", "test_navmesh_source_door_portal_physical_clearance"],
		["npc_navmesh_building_topology_tile_closure", "test_navmesh_building_topology_tile_closure"],
		["npc_navmesh_invalidated_static_snapshot_rebuilds", "test_navmesh_invalidated_static_snapshot_rebuilds"],
		["npc_navmesh_cross_tile_link_survives_endpoint_rebuild", "test_navmesh_cross_tile_link_survives_endpoint_rebuild"],
		["npc_navmesh_descriptor_keeps_door_links", "test_navmesh_descriptor_keeps_door_links"],
		["npc_navmesh_service_installs_navigation_region", "test_navmesh_service_installs_navigation_region"],
		["npc_navmesh_conforming_support_cells", "test_navmesh_conforming_support_cells"],
		["npc_navmesh_unified_tile_support_cells", "test_navmesh_unified_tile_support_cells"],
		["npc_navmesh_discards_unresolved_building_link_endpoints", "test_navmesh_discards_unresolved_building_link_endpoints"],
		["npc_navmesh_chunk_unload_cleans_region", "test_navmesh_chunk_unload_cleans_region"],
		["npc_navmesh_door_portal_installs_nav_link", "test_navmesh_door_portal_installs_nav_link"],
		["npc_navmesh_cross_region_door_link_lifecycle", "test_navmesh_cross_region_door_link_lifecycle"],
		["npc_navmesh_route_through_door_link_emits_action", "test_navmesh_route_through_door_link_emits_action"],
		["npc_navmesh_actor_path_status", "test_navmesh_actor_path_status"],
		["npc_navmesh_door_state_toggles_nav_link", "test_navmesh_door_state_toggles_nav_link"],
		["npc_navmesh_dirty_region_rebuild_after_world_edit", "test_navmesh_dirty_region_rebuild_after_world_edit"],
		["npc_navmesh_semantic_event_preserves_geometry_region", "test_navmesh_semantic_event_preserves_geometry_region"],
		["npc_navmesh_chunk_unload_cleans_door_links", "test_navmesh_chunk_unload_cleans_door_links"],
		["npc_navmesh_semantic_interior_descriptor_registered", "test_navmesh_semantic_interior_descriptor_registered"],
		["npc_navmesh_autonomy_semantic_backend_registers", "test_navmesh_autonomy_semantic_backend_registers"],
		["npc_navmesh_autonomy_prefetch_preserves_published_tile", "test_navmesh_autonomy_prefetch_preserves_published_tile"],
		["npc_navmesh_service_register_unregister_descriptor", "test_navmesh_service_register_unregister_descriptor"],
		["npc_navmesh_closest_walkable_descriptor_point", "test_navmesh_closest_walkable_descriptor_point"],
		["npc_navmesh_no_scene_visual_mesh_scan", "test_navmesh_no_scene_visual_mesh_scan"],
		["npc_navmesh_live_legacy_audit_passes", "test_navmesh_live_legacy_audit_passes"]
	]
	var cases: Array[Dictionary] = []
	for spec in ids:
		cases.append({
			"id": String(spec[0]),
			"suite": "nav_world",
			"timeModes": ["day", "night"],
			"callable": Callable(self, String(spec[1]))
		})
	return cases

func route_cases() -> Array[Dictionary]:
	if route_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcRouteTestCases.gd")
		route_case_provider = provider_script.new()
		route_case_provider.call("setup", self)
	return route_case_provider.call("cases")

func repair_cases() -> Array[Dictionary]:
	if repair_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcRepairTestCases.gd")
		repair_case_provider = provider_script.new()
		repair_case_provider.call("setup", self)
	return repair_case_provider.call("cases")

func door_cases() -> Array[Dictionary]:
	if door_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcDoorTestCases.gd")
		door_case_provider = provider_script.new()
		door_case_provider.call("setup", self)
	return door_case_provider.call("cases")

func avoidance_cases() -> Array[Dictionary]:
	if avoidance_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcAvoidanceTestCases.gd")
		avoidance_case_provider = provider_script.new()
		avoidance_case_provider.call("setup", self)
	return avoidance_case_provider.call("cases")

func traffic_cases() -> Array[Dictionary]:
	if traffic_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcTrafficTestCases.gd")
		traffic_case_provider = provider_script.new()
		traffic_case_provider.call("setup", self)
	return traffic_case_provider.call("cases")

func behavior_cases() -> Array[Dictionary]:
	if behavior_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcBehaviorTestCases.gd")
		behavior_case_provider = provider_script.new()
		behavior_case_provider.call("setup", self)
	return behavior_case_provider.call("cases")

func interaction_cases() -> Array[Dictionary]:
	if interaction_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcInteractionTestCases.gd")
		interaction_case_provider = provider_script.new()
		interaction_case_provider.call("setup", self)
	return interaction_case_provider.call("cases")

func streaming_save_cases() -> Array[Dictionary]:
	if streaming_save_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcStreamingSaveTestCases.gd")
		streaming_save_case_provider = provider_script.new()
		streaming_save_case_provider.call("setup", self)
	return streaming_save_case_provider.call("cases")

func soak_cases() -> Array[Dictionary]:
	if soak_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcSoakTestCases.gd")
		soak_case_provider = provider_script.new()
		soak_case_provider.call("setup", self)
	return soak_case_provider.call("cases")

func suite_matches(case_suite: String) -> bool:
	return suite_filter == "" or suite_filter == "all" or suite_filter == case_suite

func selected_modes(test_case: Dictionary) -> Array[String]:
	var supported: Array = test_case.get("timeModes", ["day", "night"])
	var modes: Array[String] = []
	if time_mode == "both":
		for candidate in ["day", "night"]:
			if supported.has(candidate):
				modes.append(candidate)
	elif supported.has(time_mode):
		modes.append(time_mode)
	return modes

func test_npc_motor_substep_uses_step_delta(_mode: String) -> Dictionary:
	var coordinator = NpcNavigationCoordinatorScript.new()
	var fake_locomotion = FakeCoordinatorLocomotion.new()
	coordinator.set("system", self)
	coordinator.set("main", self)
	coordinator.set("navigation_world", FakeCoordinatorWorld.new())
	coordinator.set("route_planner", FakeRoutePlanner.new({}))
	coordinator.set("route_ticket_broker", FakeRoutePlanner.new({}))
	coordinator.set("locomotion", fake_locomotion)
	coordinator.set("goal_planner", FakeCoordinatorGoalPlanner.new())

	var body := CharacterBody3D.new()
	add_child(body)
	body.global_position = Vector3.ZERO
	var entry := { "id": "npc:test:substep", "body": body }
	var moved := coordinator.move_npc(entry, Vector3(10.0, 0.0, 0.0), 4.0, false, true, 0.24)
	body.queue_free()

	var deltas: Array = fake_locomotion.deltas
	var total_delta := 0.0
	var passed := moved > 0.0 and deltas.size() > 1
	for delta_value in deltas:
		var delta := float(delta_value)
		total_delta += delta
		if delta <= 0.0 or delta >= 0.24:
			passed = false
	passed = passed and absf(total_delta - 0.24) <= 0.001
	return outcome(
		passed,
		"moved=%.3f deltas=%s totalDelta=%.3f" % [moved, JSON.stringify(deltas), total_delta],
		["substep_count_gt_one", "each_substep_uses_fractional_delta", "substeps_preserve_frame_delta"],
		{ "moved": moved, "deltas": deltas, "totalDelta": total_delta }
	)

func test_npc_motor_route_replans_after_actor_displacement(_mode: String) -> Dictionary:
	var controller = NpcRouteMovementControllerScript.new()
	controller.setup(self, self)

	var body := CharacterBody3D.new()
	add_child(body)
	body.global_position = Vector3.ZERO

	var target_cell := Vector2i(10, 0)
	var arrival_radius := NpcConstantsScript.CELL_SIZE * 0.75
	var goal_key := "%s:%d,%d:%s:%s:%s:%s:%.3f" % ["move", target_cell.x, target_cell.y, str(true), str(false), "", str(false), arrival_radius]
	var entry := {
		"id": "npc:test:route-drift",
		"body": body,
		"routeStatus": "moving",
		"routeGoalKey": goal_key,
		"routeKey": "0,0->%s" % goal_key,
		"routeSnapshotRevision": "rev-a",
		"routeStartCell": Vector2i(0, 0),
		"routeLastKnownCell": Vector2i(0, 0),
		"pathWaypoints": [Vector3(1.0, 0.0, 0.0)],
		"routeCells": [Vector2i(0, 0), Vector2i(1, 0)],
		"routeActions": {},
		"routeLease": { "leaseId": "lease:old" },
		"routeLeaseId": "lease:old"
	}
	var world = FakeRouteWorld.new()
	world.revision_value = "rev-a"
	var planner = FakeRoutePlanner.new({
		"ok": true,
		"status": "routed",
		"reason": "",
		"cells": [Vector2i(20, 0), Vector2i(21, 0)],
		"waypoints": [Vector3(20.0, 0.0, 0.0), Vector3(21.0, 0.0, 0.0)],
		"actions": {},
		"targetCell": target_cell,
		"fallbackCell": target_cell,
		"snapshotRevision": "rev-a",
		"routeAuthorityReady": true,
		"routeAuthorityState": String(NpcEnumsScript.ROUTE_AUTHORITY_READY),
		"routeLease": { "leaseId": "lease:new" },
		"routeLeaseId": "lease:new"
	})
	body.global_position = Vector3(20.0, 0.0, 0.0)
	var intent := {
		"kind": "move",
		"target": Vector3(10.0, 0.0, 0.0),
		"targetCell": target_cell,
		"allowOutside": true,
		"movingHome": false,
		"arrivalRadius": arrival_radius
	}
	var route: Dictionary = controller.ensure_route(entry, intent, planner, world)
	body.queue_free()

	var passed: bool = planner.calls >= 1 \
		and String(entry.get("routeLeaseId", "")) == "lease:new" \
		and not (entry.get("pathWaypoints", []) as Array).is_empty() \
		and entry.get("routeStartCell", Vector2i.ZERO) == Vector2i(20, 0)
	return outcome(
		passed,
		"plannerCalls=%d route=%s entryKey=%s lease=%s" % [planner.calls, JSON.stringify(route), String(entry.get("routeKey", "")), String(entry.get("routeLeaseId", ""))],
		["displaced_actor_forces_replan", "new_lease_installed"],
		{ "plannerCalls": planner.calls, "route": route, "entryRouteKey": String(entry.get("routeKey", "")), "entryRouteLeaseId": String(entry.get("routeLeaseId", "")) }
	)

func test_npc_motor_trims_reinstalled_route_prefix_to_current_cell(_mode: String) -> Dictionary:
	var controller = NpcRouteMovementControllerScript.new()
	controller.setup(self, self)

	var body := CharacterBody3D.new()
	add_child(body)
	body.global_position = Vector3(3.0, 0.0, 0.0)

	var target_cell := Vector2i(6, 0)
	var arrival_radius := NpcConstantsScript.CELL_SIZE * 0.75
	var entry := {
		"id": "npc:test:route-prefix-trim",
		"body": body,
		"routeStatus": "moving",
		"routeForceReplan": true,
		"routeSnapshotRevision": "rev-a",
		"pathWaypoints": [Vector3(3.0, 0.0, 0.0)],
		"routeCells": [Vector2i(3, 0)],
		"routeActions": {},
		"routeLease": { "leaseId": "lease:old" },
		"routeLeaseId": "lease:old"
	}
	var stale_prefix_cells := [Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0), Vector2i(5, 0), Vector2i(6, 0)]
	var stale_prefix_waypoints := [
		Vector3(1.0, 0.0, 0.0),
		Vector3(2.0, 0.0, 0.0),
		Vector3(3.0, 0.0, 0.0),
		Vector3(4.0, 0.0, 0.0),
		Vector3(5.0, 0.0, 0.0),
		Vector3(6.0, 0.0, 0.0)
	]
	var planner = FakeRoutePlanner.new({
		"ok": true,
		"status": "routed",
		"reason": "exact_collision_lattice_home",
		"cells": stale_prefix_cells,
		"waypoints": stale_prefix_waypoints,
		"actions": { "2,0": { "kind": "door" }, "4,0": { "kind": "door" } },
		"targetCell": target_cell,
		"fallbackCell": target_cell,
		"snapshotRevision": "rev-a",
		"routeAuthorityReady": true,
		"routeAuthorityState": String(NpcEnumsScript.ROUTE_AUTHORITY_READY),
		"routeLease": { "leaseId": "lease:new" },
		"routeLeaseId": "lease:new"
	})
	var world = FakeRouteWorld.new()
	world.revision_value = "rev-a"
	var intent := {
		"kind": "home",
		"target": Vector3(6.0, 0.0, 0.0),
		"targetCell": target_cell,
		"allowOutside": false,
		"movingHome": true,
		"arrivalRadius": arrival_radius
	}
	var route: Dictionary = controller.ensure_route(entry, intent, planner, world)
	var remaining_cells: Array = entry.get("routeCells", []) if entry.get("routeCells", []) is Array else []
	var remaining_waypoints: Array = entry.get("pathWaypoints", []) if entry.get("pathWaypoints", []) is Array else []
	var actions: Dictionary = entry.get("routeActions", {}) if entry.get("routeActions", {}) is Dictionary else {}
	body.queue_free()

	var first_cell: Vector2i = remaining_cells[0] if not remaining_cells.is_empty() and remaining_cells[0] is Vector2i else Vector2i(999999, 999999)
	var first_waypoint: Vector3 = remaining_waypoints[0] if not remaining_waypoints.is_empty() and remaining_waypoints[0] is Vector3 else Vector3.INF
	var remaining_cell_summary := []
	for cell_value in remaining_cells:
		if cell_value is Vector2i:
			var cell: Vector2i = cell_value
			remaining_cell_summary.append([cell.x, cell.y])
	var remaining_waypoint_summary := []
	for waypoint_value in remaining_waypoints:
		if waypoint_value is Vector3:
			var waypoint: Vector3 = waypoint_value
			remaining_waypoint_summary.append([waypoint.x, waypoint.y, waypoint.z])
	var passed := bool(route.get("ok", false)) \
		and String(entry.get("routeLeaseId", "")) == "lease:new" \
		and int(entry.get("routeTrimmedPrefixCells", 0)) == 3 \
		and first_cell == Vector2i(4, 0) \
		and first_waypoint == Vector3(4.0, 0.0, 0.0) \
		and not actions.has("2,0") \
		and actions.has("4,0")
	return outcome(
		passed,
		"trimmed=%d cells=%s waypoints=%s actions=%s route=%s" % [
			int(entry.get("routeTrimmedPrefixCells", 0)),
			JSON.stringify(remaining_cell_summary),
			JSON.stringify(remaining_waypoint_summary),
			JSON.stringify(actions.keys()),
			JSON.stringify(route)
		],
		["reinstalled_route_prefix_trimmed", "current_cell_not_replayed", "future_actions_preserved"],
		{ "route": route, "remainingCells": remaining_cell_summary, "remainingWaypoints": remaining_waypoint_summary, "actions": actions.keys() }
	)

func test_npc_navworld_live_tile_snapshot_includes_collision_records(_mode: String) -> Dictionary:
	var main := FakeGeneratedWorldMain.new()
	var wall_cell := Vector2i(1, 0)
	var door_cell := Vector2i(3, 0)
	var wall := live_nav_block(wall_cell, "woodBlock")
	var door := live_nav_block(door_cell, "door", Vector3(NpcConstantsScript.CELL_SIZE * 0.92, NpcConstantsScript.CELL_SIZE * 1.6, NpcConstantsScript.CELL_SIZE * 0.16))
	door.set_meta("door_state", String(NpcEnumsScript.DOOR_STATE_CLOSED))
	door.set_meta("door_portal_id", "door:test:live-snapshot")
	door.set_meta("door_group_id", "door-group:test:live-snapshot")
	main.add_child(wall)
	main.add_child(door)
	main.blocks[Vector3i(wall_cell.x, 0, wall_cell.y)] = wall
	main.blocks[Vector3i(door_cell.x, 0, door_cell.y)] = door

	var adapter := GeneratedWorldNavigationAdapterScript.new()
	adapter.setup(null, main)
	var snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("0,0")
	var blocked: Dictionary = snapshot.get("blocked", {}) if snapshot.get("blocked", {}) is Dictionary else {}
	var doors: Dictionary = snapshot.get("doors", {}) if snapshot.get("doors", {}) is Dictionary else {}
	var static_records: Array = snapshot.get("staticCollision", []) if snapshot.get("staticCollision", []) is Array else []
	var static_by_cell: Dictionary = snapshot.get("staticCollisionByCell", {}) if snapshot.get("staticCollisionByCell", {}) is Dictionary else {}
	var door_records: Array = snapshot.get("doorCollision", []) if snapshot.get("doorCollision", []) is Array else []
	var door_by_cell: Dictionary = snapshot.get("doorCollisionByCell", {}) if snapshot.get("doorCollisionByCell", {}) is Dictionary else {}
	var surfaces: Array = snapshot.get("surfaces", []) if snapshot.get("surfaces", []) is Array else []
	var blocked_cell_published := false
	var open_cell_published := false
	for surface_value in surfaces:
		if not (surface_value is Dictionary):
			continue
		var surface: Dictionary = surface_value
		var cell: Vector3i = surface.get("cell", Vector3i.ZERO)
		if cell.x == wall_cell.x and cell.z == wall_cell.y:
			blocked_cell_published = true
		if cell.x == 0 and cell.z == 0:
			open_cell_published = true
	var passed := blocked.has(wall_cell) \
		and doors.has(door_cell) \
		and not static_records.is_empty() \
		and not door_records.is_empty() \
		and static_by_cell.has(wall_cell) \
		and door_by_cell.has(door_cell) \
		and not blocked_cell_published \
		and open_cell_published
	main.free()
	return outcome(
		passed,
		"blocked=%s doors=%s staticRecords=%d doorRecords=%d blockedSurface=%s openSurface=%s" % [JSON.stringify(blocked.keys()), JSON.stringify(doors.keys()), static_records.size(), door_records.size(), str(blocked_cell_published), str(open_cell_published)],
		["live_static_block_updates_static_collision", "live_door_updates_door_collision", "collision_by_cell_matches_records"],
		{ "blockedCells": blocked.keys(), "doorCells": doors.keys(), "staticRecordCount": static_records.size(), "doorRecordCount": door_records.size(), "blockedCellPublished": blocked_cell_published, "openCellPublished": open_cell_published }
	)

func test_clock_day_snapshot(_mode: String) -> Dictionary:
	var clock = NpcTestClockScript.new()
	clock.set_canonical_day()
	clock.freeze()
	var snapshot: Dictionary = clock.snapshot()
	var passed := (
		NpcTestAssertionsScript.approx_equal(float(snapshot.get("timeOfDay", -1.0)), 0.25)
		and NpcTestAssertionsScript.approx_equal(float(snapshot.get("clockPhase", -1.0)), 0.5)
		and NpcTestAssertionsScript.approx_equal(float(snapshot.get("displayHour", -1.0)), 12.0)
		and String(snapshot.get("scheduleState", "")) == "day"
		and bool(snapshot.get("frozen", false))
	)
	return outcome(
		passed,
		"snapshot %s" % JSON.stringify(snapshot),
		["time_of_day", "clock_phase", "display_hour", "schedule_state"],
		{ "snapshot": snapshot }
	)

func test_clock_night_snapshot(_mode: String) -> Dictionary:
	var clock = NpcTestClockScript.new()
	clock.set_canonical_night()
	clock.freeze()
	var snapshot: Dictionary = clock.snapshot()
	var passed := (
		NpcTestAssertionsScript.approx_equal(float(snapshot.get("timeOfDay", -1.0)), 0.75)
		and NpcTestAssertionsScript.approx_equal(float(snapshot.get("clockPhase", -1.0)), 0.0)
		and NpcTestAssertionsScript.approx_equal(float(snapshot.get("displayHour", -1.0)), 0.0)
		and String(snapshot.get("scheduleState", "")) == "night"
		and bool(snapshot.get("frozen", false))
	)
	return outcome(
		passed,
		"snapshot %s" % JSON.stringify(snapshot),
		["time_of_day", "clock_phase", "display_hour", "schedule_state"],
		{ "snapshot": snapshot }
	)

func test_runner_filters(mode: String) -> Dictionary:
	var valid_mode := time_mode in ["day", "night", "both", "transition"]
	var case_ok := case_filter == "" or case_filter.begins_with("npc_contract_")
	var passed := suite_filter == "contract" and valid_mode and case_ok and mode in ["day", "night"]
	return outcome(
		passed,
		"suite=%s case=%s time=%s activeMode=%s seed=%s" % [suite_filter, case_filter, time_mode, mode, seed],
		["suite_filter", "case_filter", "time_mode", "seed"],
		{ "suite": suite_filter, "case": case_filter, "timeMode": time_mode, "activeMode": mode, "seed": seed }
	)

func test_report_freshness(_mode: String) -> Dictionary:
	var passed := run_token.length() >= 16 and report_path != "" and progress_path != "" and started_unix > 0.0
	return outcome(
		passed,
		"token=%s report=%s progress=%s started=%.0f" % [run_token, report_path, progress_path, started_unix],
		["run_token", "report_path", "progress_path", "started_unix"],
		{ "runToken": run_token, "report": report_path, "progress": progress_path, "startedUnix": started_unix }
	)

func test_report_schema(_mode: String) -> Dictionary:
	var report := build_report(false)
	var required := NpcTestAssertionsScript.required_report_schema_keys()
	var passed := NpcTestAssertionsScript.dictionary_has_keys(report, required)
	return outcome(
		passed,
		"keys=%s" % JSON.stringify(report.keys()),
		["required_schema_keys"],
		{ "required": required, "actual": report.keys() }
	)

func test_rng_stream_isolation_baseline(mode: String) -> Dictionary:
	var seed_a := NpcTestAssertionsScript.rng_seed(seed, "npc-a", "goal", mode)
	var seed_a_again := NpcTestAssertionsScript.rng_seed(seed, "npc-a", "goal", mode)
	var seed_b := NpcTestAssertionsScript.rng_seed(seed, "npc-b", "goal", mode)
	var seq_a := NpcTestAssertionsScript.deterministic_sequence(seed_a, 5)
	var seq_a_again := NpcTestAssertionsScript.deterministic_sequence(seed_a_again, 5)
	var seq_b := NpcTestAssertionsScript.deterministic_sequence(seed_b, 5)
	var sorted_ids := NpcTestAssertionsScript.stable_sorted_strings(["npc-10", "npc-02", "npc-01"])
	var passed := seed_a == seed_a_again and seed_a != seed_b and seq_a == seq_a_again and seq_a != seq_b and sorted_ids == ["npc-01", "npc-02", "npc-10"]
	return outcome(
		passed,
		"seedA=%d seedB=%d seqA=%s seqB=%s sorted=%s" % [seed_a, seed_b, JSON.stringify(seq_a), JSON.stringify(seq_b), JSON.stringify(sorted_ids)],
		["per_npc_seed", "repeatable_sequence", "stable_sort"],
		{ "seedA": seed_a, "seedB": seed_b, "sequenceA": seq_a, "sequenceB": seq_b, "sortedIds": sorted_ids }
	)

func test_player_motor_characterization_baseline(_mode: String) -> Dictionary:
	var metrics_state := {
		"walkSpeed": PlayerControllerScript.WALK_SPEED,
		"sprintSpeed": PlayerControllerScript.SPRINT_SPEED,
		"acceleration": PlayerControllerScript.ACCELERATION,
		"airControl": PlayerControllerScript.AIR_CONTROL,
		"jumpSpeed": PlayerControllerScript.JUMP_SPEED,
		"gravity": PlayerControllerScript.GRAVITY,
		"terrainWalkableRise": PlayerControllerScript.TERRAIN_WALKABLE_RISE,
		"terrainWalkableDrop": PlayerControllerScript.TERRAIN_WALKABLE_DROP,
		"terrainAscendSpeed": PlayerControllerScript.TERRAIN_ASCEND_SPEED,
		"terrainDescendSpeed": PlayerControllerScript.TERRAIN_DESCEND_SPEED,
		"floorSnapLength": PlayerControllerScript.FLOOR_SNAP_LENGTH,
		"jumpSnapSuppression": PlayerControllerScript.JUMP_SNAP_SUPPRESSION,
		"capsuleRadius": 0.42,
		"capsuleHeight": 1.72,
		"floorMaxAngleDegrees": 46.0
	}
	var passed := (
		NpcTestAssertionsScript.approx_equal(float(metrics_state.walkSpeed), 9.5)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.sprintSpeed), 15.5)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.acceleration), 14.0)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.jumpSpeed), 8.9)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.gravity), 26.0)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.terrainWalkableRise), 1.55)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.terrainWalkableDrop), 1.55)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.floorSnapLength), 0.32)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.capsuleRadius), 0.42)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.capsuleHeight), 1.72)
	)
	return outcome(
		passed,
		"metrics=%s" % JSON.stringify(metrics_state),
		["player_constants", "capsule_metrics", "floor_snap"],
		metrics_state
	)

func test_existing_save_defaults_baseline(mode: String) -> Dictionary:
	var path := "user://npc_contract_save_defaults_%s_%s.json" % [mode, run_token]
	var absolute_path := ProjectSettings.globalize_path(path)
	DirAccess.remove_absolute(absolute_path)
	var save_system = SaveSystemScript.new(path)
	var missing_load: Dictionary = save_system.load("atlas-1492")
	var fallback_seed := save_system.active_seed("atlas-1492")
	var wrote_wrong_version := save_system.write_all({
		"atlas-1492": {
			"seed": "atlas-1492",
			"version": 0
		}
	})
	var wrong_version_load: Dictionary = save_system.load("atlas-1492")
	var saved := save_system.save("atlas-1492", { "custom": "value" })
	var loaded: Dictionary = save_system.load("atlas-1492")
	var deleted := save_system.delete("atlas-1492")
	var passed := (
		missing_load.is_empty()
		and fallback_seed == "atlas-1492"
		and wrote_wrong_version
		and wrong_version_load.is_empty()
		and saved
		and int(loaded.get("version", 0)) == SaveSystemScript.SAVE_VERSION
		and String(loaded.get("seed", "")) == "atlas-1492"
		and String(loaded.get("custom", "")) == "value"
		and deleted
	)
	DirAccess.remove_absolute(absolute_path)
	return outcome(
		passed,
		"missing=%s fallback=%s wrongEmpty=%s saved=%s loaded=%s deleted=%s" % [str(missing_load.is_empty()), fallback_seed, str(wrong_version_load.is_empty()), str(saved), JSON.stringify(loaded), str(deleted)],
		["missing_load_defaults", "version_rejection", "round_trip_version"],
		{ "missingLoad": missing_load, "fallbackSeed": fallback_seed, "wrongVersionLoad": wrong_version_load, "loaded": loaded }
	)

func test_existing_npc_navigation_runner_callable(_mode: String) -> Dictionary:
	var tool_exists := FileAccess.file_exists("res://tools/run-npc-navigation-tests.ps1")
	var scene_exists := FileAccess.file_exists("res://scenes/NpcNavigationTest.tscn")
	var script_exists := FileAccess.file_exists("res://scripts/NpcNavigationTestRunner.gd")
	var passed := tool_exists and scene_exists and script_exists
	return outcome(
		passed,
		"tool=%s scene=%s script=%s" % [str(tool_exists), str(scene_exists), str(script_exists)],
		["npc_navigation_runner_files"],
		{ "tool": tool_exists, "scene": scene_exists, "script": script_exists }
	)

func test_all_runner_registry_baseline(_mode: String) -> Dictionary:
	var parsed = read_json_file("res://tools/test-runner-registry.json")
	var ids: Array = []
	if parsed is Dictionary:
		for runner in parsed.get("runners", []):
			if runner is Dictionary:
				ids.append(String(runner.get("id", "")))
	var required := [
		"npc_focused",
		"npc_navigation_integration",
		"story_playtest",
		"world_signature",
		"visual_captures",
		"visual_manifest"
	]
	var missing: Array[String] = []
	for id in required:
		if not ids.has(id):
			missing.append(id)
	var passed := parsed is Dictionary and missing.is_empty()
	return outcome(
		passed,
		"ids=%s missing=%s" % [JSON.stringify(ids), JSON.stringify(missing)],
		["runner_registry_present", "mandatory_runner_ids"],
		{ "ids": ids, "missing": missing }
	)

func test_route_status_terminal(_mode: String) -> Dictionary:
	var route_terminal := [
		NpcEnumsScript.ROUTE_STATUS_COMPLETE,
		NpcEnumsScript.ROUTE_STATUS_PARTIAL,
		NpcEnumsScript.ROUTE_STATUS_UNREACHABLE,
		NpcEnumsScript.ROUTE_STATUS_INVALIDATED,
		NpcEnumsScript.ROUTE_STATUS_CANCELLED,
		NpcEnumsScript.ROUTE_STATUS_FAILED_INTERNAL
	]
	var route_nonterminal := [
		NpcEnumsScript.ROUTE_STATUS_PENDING,
		NpcEnumsScript.ROUTE_STATUS_SEARCHING
	]
	var route_ok := true
	for status in route_terminal:
		var terminal_result = RouteResultScript.make(status, NpcEnumsScript.ROUTE_REASON_NONE, 1)
		route_ok = route_ok and terminal_result.is_terminal()
	for status in route_nonterminal:
		var nonterminal_result = RouteResultScript.make(status, NpcEnumsScript.ROUTE_REASON_NONE, 1)
		route_ok = route_ok and not nonterminal_result.is_terminal()
	var terminal_labels: Array[String] = []
	for status in route_terminal:
		terminal_labels.append(String(status))
	var nonterminal_labels: Array[String] = []
	for status in route_nonterminal:
		nonterminal_labels.append(String(status))
	var action := NpcActionInstanceScript.new()
	var action_generation: int = action.next_generation()
	var action_ok: bool = action.apply_terminal(action_generation, NpcEnumsScript.ACTION_STATUS_SUCCEEDED) and action.is_terminal()
	var interaction = InteractionResultScript.make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"contract", 4)
	var interaction_ok: bool = interaction.is_terminal()
	var passed: bool = route_ok and action_ok and interaction_ok
	return outcome(
		passed,
		"routeTerminal=%s action=%s interaction=%s" % [str(route_ok), str(action_ok), str(interaction_ok)],
		["route_terminal_states", "action_terminal_states", "interaction_terminal_states"],
		{
			"routeTerminal": terminal_labels,
			"routeNonterminal": nonterminal_labels,
			"actionStatus": String(action.status),
			"interactionStatus": String(interaction.status)
		}
	)

func test_partial_never_arrival(_mode: String) -> Dictionary:
	var partial = RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_PARTIAL, NpcEnumsScript.ROUTE_REASON_PARTIAL_ONLY, 2)
	partial.arrival_contract = "home"
	var complete = RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_COMPLETE, NpcEnumsScript.ROUTE_REASON_NONE, 2)
	complete.arrival_contract = "home"
	var passed: bool = partial.is_terminal() and not partial.is_arrival() and not partial.satisfies_arrival_contract("home") and complete.is_arrival() and complete.satisfies_arrival_contract("home")
	return outcome(
		passed,
		"partial=%s complete=%s" % [JSON.stringify(partial.to_summary()), JSON.stringify(complete.to_summary())],
		["partial_terminal", "partial_not_arrival", "arrival_contract_requires_complete"],
		{ "partial": partial.to_summary(), "complete": complete.to_summary() }
	)

func test_route_authority_state_mapping(_mode: String) -> Dictionary:
	var ready_route := {
		"ok": true,
		"status": "routed",
		"reason": "",
		"source": "navmesh",
		"targetCell": Vector2i(1, 0),
		"fallbackCell": Vector2i(1, 0),
		"snapshotRevision": "contract",
		"cells": [Vector2i(1, 0)],
		"waypoints": [Vector3(NpcConstantsScript.CELL_SIZE, 0.0, 0.0)],
		"actions": {}
	}
	var ready_state := NpcRouteAuthorityScript.canonical_state_for_route(ready_route, {})
	var pending_nav_state := NpcRouteAuthorityScript.canonical_state_for_route({
		"ok": false,
		"status": "pending",
		"reason": "navmesh_tile_budget",
		"waypoints": []
	}, {})
	var pending_budget_state := NpcRouteAuthorityScript.canonical_state_for_route({
		"ok": false,
		"status": "pending",
		"reason": "route_budget",
		"waypoints": []
	}, {})
	var invalid_goal_state := NpcRouteAuthorityScript.canonical_state_for_route({
		"ok": false,
		"status": "blocked",
		"reason": "target_blocked",
		"waypoints": []
	}, {})
	var static_state := NpcRouteAuthorityScript.canonical_state_for_route({
		"ok": false,
		"status": "blocked",
		"reason": "path_crosses_static_collision",
		"waypoints": []
	}, {})
	var lease = RouteLeaseScript.from_route(ready_route, "contract-npc", 1, ready_state, NpcEnumsScript.ROUTE_REASON_NONE)
	var passed: bool = ready_state == NpcEnumsScript.ROUTE_AUTHORITY_READY \
		and pending_nav_state == NpcEnumsScript.ROUTE_AUTHORITY_PENDING_NAV_DATA \
		and pending_budget_state == NpcEnumsScript.ROUTE_AUTHORITY_PENDING_BUDGET \
		and invalid_goal_state == NpcEnumsScript.ROUTE_AUTHORITY_INVALID_GOAL \
		and static_state == NpcEnumsScript.ROUTE_AUTHORITY_UNREACHABLE_STATIC \
		and lease.is_ready() \
		and lease.waypoints.size() == 1
	return outcome(
		passed,
		"ready=%s nav=%s budget=%s invalid=%s static=%s lease=%s" % [String(ready_state), String(pending_nav_state), String(pending_budget_state), String(invalid_goal_state), String(static_state), JSON.stringify(lease.to_summary())],
		["authority_ready_requires_route_lease", "pending_nav_data_distinct_from_budget", "invalid_goal_distinct_from_static_unreachable"],
		{
			"ready": String(ready_state),
			"pendingNav": String(pending_nav_state),
			"pendingBudget": String(pending_budget_state),
			"invalidGoal": String(invalid_goal_state),
			"unreachableStatic": String(static_state),
			"lease": lease.to_summary()
		}
	)

func test_route_authority_attaches_probe_certificate(_mode: String) -> Dictionary:
	var delegate := FakeAuthorityRouteDelegate.new()
	delegate.route = {
		"ok": true,
		"status": "routed",
		"reason": "",
		"source": "navmesh",
		"targetCell": Vector2i(1, 0),
		"fallbackCell": Vector2i(1, 0),
		"snapshotRevision": "contract",
		"cells": [Vector2i(1, 0)],
		"waypoints": [Vector3(NpcConstantsScript.CELL_SIZE, 0.0, 0.0)],
		"actions": {}
	}
	var authority := NpcRouteAuthorityScript.new()
	authority.setup(null, null, null, delegate)
	var body := CharacterBody3D.new()
	body.collision_mask = NpcConstantsScript.COLLISION_WORLD_QUERY | NpcConstantsScript.COLLISION_TERRAIN_BODY
	add_child(body)
	body.global_position = Vector3.ZERO
	var entry := { "id": "contract-npc", "body": body }
	var route: Dictionary = authority.plan_route(entry, { "kind": "move", "targetCell": Vector2i(1, 0) })
	body.queue_free()
	var certificate: Dictionary = route.get("probeCertificate", {}) if route.get("probeCertificate", {}) is Dictionary else {}
	var lease: Dictionary = route.get("routeLease", {}) if route.get("routeLease", {}) is Dictionary else {}
	var lease_probe: Dictionary = lease.get("probeCertificate", {}) if lease.get("probeCertificate", {}) is Dictionary else {}
	var entry_authority: Dictionary = entry.get("lastRouteAuthority", {}) if entry.get("lastRouteAuthority", {}) is Dictionary else {}
	var passed := bool(route.get("routeAuthorityReady", false)) \
		and String(route.get("routeAuthorityState", "")) == String(NpcEnumsScript.ROUTE_AUTHORITY_READY) \
		and String(certificate.get("status", "")) == "passed" \
		and bool(certificate.get("authoritative", false)) \
		and not lease.is_empty() \
		and String(lease_probe.get("status", "")) == "passed" \
		and bool(lease_probe.get("authoritative", false)) \
		and String(entry_authority.get("state", "")) == String(NpcEnumsScript.ROUTE_AUTHORITY_READY)
	return outcome(
		passed,
		"certificate=%s lease=%s" % [JSON.stringify(certificate), JSON.stringify(lease)],
		["ready_routes_receive_probe_certificate", "audit_probe_skips_are_not_live_acceptance", "lease_carries_probe_certificate"],
		{
			"certificate": certificate,
			"lease": lease,
			"authorityStats": authority.stats(),
			"entryAuthority": entry_authority
		}
	)

func test_route_authority_requires_authoritative_probe_for_ready(_mode: String) -> Dictionary:
	var delegate := FakeAuthorityRouteDelegate.new()
	delegate.route = {
		"ok": true,
		"status": "routed",
		"reason": "",
		"source": "navmesh",
		"targetCell": Vector2i(1, 0),
		"fallbackCell": Vector2i(1, 0),
		"snapshotRevision": "contract",
		"cells": [Vector2i(1, 0)],
		"waypoints": [Vector3(NpcConstantsScript.CELL_SIZE, 0.0, 0.0)],
		"actions": {}
	}
	var authority := NpcRouteAuthorityScript.new()
	authority.setup(null, null, null, delegate)
	var entry := { "id": "contract-npc" }
	var route: Dictionary = authority.plan_route(entry, { "kind": "move", "targetCell": Vector2i(1, 0) })
	var certificate: Dictionary = route.get("probeCertificate", {}) if route.get("probeCertificate", {}) is Dictionary else {}
	var passed := not bool(route.get("routeAuthorityReady", true)) \
		and String(route.get("routeAuthorityState", "")) == String(NpcEnumsScript.ROUTE_AUTHORITY_PENDING_PROBE) \
		and String(route.get("routeAuthorityReason", "")) == "missing_body" \
		and String(certificate.get("status", "")) == "skipped" \
		and not bool(certificate.get("authoritative", true)) \
		and (route.get("routeLease", {}) as Dictionary).is_empty()
	return outcome(
		passed,
		"state=%s reason=%s certificate=%s" % [String(route.get("routeAuthorityState", "")), String(route.get("routeAuthorityReason", "")), JSON.stringify(certificate)],
		["ready_requires_authoritative_probe", "skipped_probe_is_pending_probe", "no_lease_without_probe_authority"],
		{
			"state": String(route.get("routeAuthorityState", "")),
			"reason": String(route.get("routeAuthorityReason", "")),
			"certificate": certificate,
			"lease": route.get("routeLease", {})
		}
	)

func test_route_authority_resumes_collision_probe(_mode: String) -> Dictionary:
	var delegate := FakeAuthorityRouteDelegate.new()
	delegate.route = {
		"ok": true,
		"status": "routed",
		"reason": "",
		"source": "collision_lattice",
		"targetCell": Vector2i(0, 12),
		"fallbackCell": Vector2i(0, 12),
		"snapshotRevision": "cursor-contract",
		"cells": [Vector2i(0, 6), Vector2i(0, 12)],
		"waypoints": [Vector3(0.0, 0.0, 6.0), Vector3(0.0, 0.0, 12.0)],
		"actions": {}
	}
	var authority := NpcRouteAuthorityScript.new()
	authority.setup(null, null, null, delegate)
	var fake_probe := FakeCursorCollisionProbe.new()
	authority.collision_probe = fake_probe
	authority.probe_sample_budget_per_frame = 3
	var entry := { "id": "contract-cursor-npc" }
	var intent := { "kind": "home", "targetCell": Vector2i(0, 12), "movingHome": true }
	var first: Dictionary = authority.plan_route(entry, intent)
	authority.begin_frame()
	var second: Dictionary = authority.plan_route(entry, intent)
	var second_call: Dictionary = fake_probe.calls[1] if fake_probe.calls.size() > 1 else {}
	var resumed_cursor: Dictionary = second_call.get("cursor", {}) if second_call.get("cursor", {}) is Dictionary else {}
	var first_certificate: Dictionary = first.get("probeCertificate", {}) if first.get("probeCertificate", {}) is Dictionary else {}
	var first_details: Dictionary = first_certificate.get("details", {}) if first_certificate.get("details", {}) is Dictionary else {}
	var second_certificate: Dictionary = second.get("probeCertificate", {}) if second.get("probeCertificate", {}) is Dictionary else {}
	var passed := String(first.get("routeAuthorityState", "")) == String(NpcEnumsScript.ROUTE_AUTHORITY_PENDING_PROBE) \
		and String(first.get("routeAuthorityReason", "")) == "collision_probe_budget" \
		and (first.get("routeLease", {}) as Dictionary).is_empty() \
		and fake_probe.calls.size() == 2 \
		and int(resumed_cursor.get("segmentIndex", -1)) == 2 \
		and int(resumed_cursor.get("sampleIndex", -1)) == 4 \
		and bool(second.get("routeAuthorityReady", false)) \
		and not (second.get("routeLease", {}) as Dictionary).is_empty() \
		and int((second_certificate.get("details", {}) as Dictionary).get("resumedSegment", -1)) == 2
	return outcome(
		passed,
		"first=%s firstDetails=%s second=%s calls=%s stats=%s" % [String(first.get("routeAuthorityState", "")), JSON.stringify(first_details), String(second.get("routeAuthorityState", "")), JSON.stringify(fake_probe.calls), JSON.stringify(authority.stats())],
		["pending_probe_stores_cursor", "next_attempt_resumes_probe_cursor", "resumed_probe_can_lease_route"],
		{
			"first": {
				"state": String(first.get("routeAuthorityState", "")),
				"reason": String(first.get("routeAuthorityReason", "")),
				"certificate": first_certificate
			},
			"second": {
				"state": String(second.get("routeAuthorityState", "")),
				"ready": bool(second.get("routeAuthorityReady", false)),
				"certificate": second_certificate,
				"lease": second.get("routeLease", {})
			},
			"probeCalls": fake_probe.calls,
			"stats": authority.stats()
		}
	)

func test_route_authority_v2_lifecycle(_mode: String) -> Dictionary:
	var authority := NpcRouteAuthorityV2Script.new()
	var entry := { "id": "v2-contract-npc" }
	var registered: Dictionary = authority.register_actor(entry)
	var request: Dictionary = authority.submit_request(entry, { "kind": "home", "targetCell": Vector2i(3, 4) }, { "priority": 140 })
	var request_id := String(request.get("requestId", ""))
	authority.begin_frame()
	authority.begin_frame()
	var budget: Dictionary = authority.mark_pending_budget(request_id, "route_budget")
	authority.begin_frame()
	var nav_data: Dictionary = authority.mark_pending_nav_data(request_id, "navmesh_tile_budget")
	authority.begin_frame()
	var probing: Dictionary = authority.mark_probing(request_id, "collision_probe")
	authority.begin_frame()
	var ready: Dictionary = authority.mark_ready(request_id, {
		"ok": true,
		"status": "routed",
		"reason": "",
		"source": "v2_contract",
		"targetCell": Vector2i(3, 4),
		"fallbackCell": Vector2i(3, 4),
		"snapshotRevision": "v2-contract",
		"cells": [Vector2i(1, 1), Vector2i(3, 4)],
		"waypoints": [Vector3(1.0, 0.0, 1.0), Vector3(3.0, 0.0, 4.0)],
		"actions": {}
	}, {
		"ok": true,
		"authoritative": true,
		"status": "passed",
		"reason": ""
	})
	var moving: Dictionary = authority.begin_moving(request_id, "lease_following")
	var arrived: Dictionary = authority.report_arrived(request_id, "strict_arrival")
	var debug: Dictionary = authority.debug_for_entry(entry)
	var passed := String(registered.get("state", "")) == "none" \
		and String(request.get("state", "")) == "queued" \
		and String(budget.get("state", "")) == "pending_budget" \
		and String(nav_data.get("state", "")) == "pending_nav_data" \
		and String(probing.get("state", "")) == "probing" \
		and bool(ready.get("hasLease", false)) \
		and String(moving.get("state", "")) == "moving" \
		and String(arrived.get("state", "")) == "arrived" \
		and String(debug.get("state", "")) == "arrived" \
		and int(debug.get("queuedFrames", 0)) > 0 \
		and int(debug.get("pendingBudgetFrames", 0)) > 0 \
		and int(debug.get("pendingNavDataFrames", 0)) > 0 \
		and int(debug.get("pendingProbeFrames", 0)) > 0 \
		and String(debug.get("leaseId", "")) != ""
	return outcome(
		passed,
		"request=%s ready=%s arrived=%s debug=%s" % [JSON.stringify(request), JSON.stringify(ready), JSON.stringify(arrived), JSON.stringify(debug)],
		["v2_request_id_created", "v2_lifecycle_transitions", "v2_ready_issues_lease", "v2_starvation_counts_recorded", "v2_debug_export_per_actor"],
		{
			"request": request,
			"ready": ready,
			"arrived": arrived,
			"debug": debug,
			"stats": authority.stats()
		}
	)

func test_route_authority_v2_cancellation(_mode: String) -> Dictionary:
	var authority := NpcRouteAuthorityV2Script.new()
	var entry := { "id": "v2-cancel-npc" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "forage", "targetCell": Vector2i(8, 9) }, { "priority": 80 })
	var request_id := String(request.get("requestId", ""))
	authority.begin_frame()
	authority.mark_pending_budget(request_id, "route_budget")
	authority.begin_frame()
	var cancelled: Dictionary = authority.cancel_request(request_id, "superseded_intent")
	var debug: Dictionary = authority.debug_for_entry(entry)
	var stats: Dictionary = authority.stats()
	var counters: Dictionary = stats.get("counters", {}) if stats.get("counters", {}) is Dictionary else {}
	var passed := String(cancelled.get("state", "")) == "cancelled" \
		and String(cancelled.get("reason", "")) == "superseded_intent" \
		and not bool(cancelled.get("hasLease", true)) \
		and String(debug.get("state", "")) == "cancelled" \
		and int(debug.get("pendingBudgetFrames", 0)) > 0 \
		and int(debug.get("lastServicedFrame", -1)) >= 0 \
		and int(counters.get("cancelled", 0)) == 1
	return outcome(
		passed,
		"cancelled=%s debug=%s stats=%s" % [JSON.stringify(cancelled), JSON.stringify(debug), JSON.stringify(stats)],
		["v2_cancel_terminal_state", "v2_cancel_has_no_lease", "v2_cancel_preserves_starvation_accounting"],
		{
			"cancelled": cancelled,
			"debug": debug,
			"stats": stats
		}
	)

func test_route_authority_v2_requires_probe_certificate(_mode: String) -> Dictionary:
	var authority := NpcRouteAuthorityV2Script.new()
	var entry := { "id": "v2-probe-required-npc" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "move", "targetCell": Vector2i(2, 0) }, { "priority": 90 })
	var request_id := String(request.get("requestId", ""))
	var route := v2_probe_contract_route()
	var missing: Dictionary = authority.mark_ready(request_id, route, {})
	var failed: Dictionary = authority.mark_ready(request_id, route, {
		"ok": false,
		"status": "blocked",
		"reason": "blocked_capsule_probe",
		"authoritative": true
	})
	var debug: Dictionary = authority.debug_for_entry(entry)
	var passed := not bool(missing.get("ok", true)) \
		and String(missing.get("reason", "")) == "missing_successful_probe_certificate" \
		and not bool(failed.get("ok", true)) \
		and not bool(debug.get("hasLease", true)) \
		and String(debug.get("state", "")) == "queued"
	return outcome(
		passed,
		"missing=%s failed=%s debug=%s" % [JSON.stringify(missing), JSON.stringify(failed), JSON.stringify(debug)],
		["v2_ready_requires_probe_certificate", "v2_failed_probe_cannot_lease", "v2_request_remains_unleased"],
		{ "missing": missing, "failed": failed, "debug": debug }
	)

func test_route_authority_v2_probe_commit_ready(_mode: String) -> Dictionary:
	var probe := FakeRouteAuthorityV2Probe.new()
	probe.response = {
		"ok": true,
		"status": "passed",
		"reason": "",
		"authoritative": true,
		"sampleCount": 5,
		"details": { "completedSamples": 5 }
	}
	var authority := NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, probe)
	var entry := { "id": "v2-probe-ready-npc" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "home", "targetCell": Vector2i(2, 0) }, { "priority": 120 })
	var request_id := String(request.get("requestId", ""))
	var ready: Dictionary = authority.commit_route_after_probe(entry, request_id, v2_probe_contract_route(true), { "kind": "home", "targetCell": Vector2i(2, 0) })
	var proof: Dictionary = ready.get("proof", {}) if ready.get("proof", {}) is Dictionary else {}
	var certificate: Dictionary = proof.get("probeCertificate", {}) if proof.get("probeCertificate", {}) is Dictionary else {}
	var door_edges: Array = proof.get("doorProbeEdges", []) if proof.get("doorProbeEdges", []) is Array else []
	var lease: Dictionary = ready.get("routeLease", {}) if ready.get("routeLease", {}) is Dictionary else {}
	var lease_certificate: Dictionary = lease.get("probeCertificate", {}) if lease.get("probeCertificate", {}) is Dictionary else {}
	var passed := String(ready.get("state", "")) == "ready" \
		and bool(ready.get("hasLease", false)) \
		and String(certificate.get("status", "")) == "passed" \
		and bool(certificate.get("authoritative", false)) \
		and door_edges.size() >= 1 \
		and String(lease_certificate.get("status", "")) == "passed" \
		and probe.calls.size() == 1
	return outcome(
		passed,
		"ready=%s proof=%s calls=%s" % [JSON.stringify(ready), JSON.stringify(proof), JSON.stringify(probe.calls)],
		["v2_probe_pass_can_issue_lease", "v2_lease_carries_probe_certificate", "v2_door_edges_are_structured_probe_edges"],
		{ "ready": ready, "proof": proof, "probeCalls": probe.calls }
	)

func test_route_authority_v2_probe_blocked_before_movement(_mode: String) -> Dictionary:
	var probe := FakeRouteAuthorityV2Probe.new()
	probe.response = {
		"ok": false,
		"status": "blocked",
		"reason": "blocked_capsule_probe",
		"authoritative": true,
		"sampleCount": 2,
		"details": {
			"collider": "fixture-wall",
			"class": "StaticBody3D",
			"kind": "block",
			"blockType": "generated_house_wall",
			"cell": Vector2i(1, 0)
		}
	}
	var authority := NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, probe)
	var entry := { "id": "v2-probe-blocked-npc" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "move", "targetCell": Vector2i(2, 0) }, { "priority": 120 })
	var request_id := String(request.get("requestId", ""))
	var blocked: Dictionary = authority.commit_route_after_probe(entry, request_id, v2_probe_contract_route(), { "kind": "move", "targetCell": Vector2i(2, 0) })
	var moving: Dictionary = authority.begin_moving(request_id, "should_not_move")
	var proof: Dictionary = blocked.get("proof", {}) if blocked.get("proof", {}) is Dictionary else {}
	var certificate: Dictionary = proof.get("probeCertificate", {}) if proof.get("probeCertificate", {}) is Dictionary else {}
	var details: Dictionary = certificate.get("details", {}) if certificate.get("details", {}) is Dictionary else {}
	var passed := String(blocked.get("state", "")) == "unreachable_static" \
		and not bool(blocked.get("hasLease", true)) \
		and not bool(moving.get("ok", true)) \
		and String(moving.get("reason", "")) == "route_not_ready" \
		and String(details.get("collider", "")) == "fixture-wall" \
		and String(details.get("blockType", "")) == "generated_house_wall"
	return outcome(
		passed,
		"blocked=%s moving=%s proof=%s" % [JSON.stringify(blocked), JSON.stringify(moving), JSON.stringify(proof)],
		["v2_blocked_probe_is_terminal_before_movement", "v2_blocked_probe_has_blocker_identity", "v2_blocked_route_cannot_begin_moving"],
		{ "blocked": blocked, "moving": moving, "proof": proof }
	)

func test_route_authority_v2_dynamic_static_body_is_retryable(_mode: String) -> Dictionary:
	var probe := FakeRouteAuthorityV2Probe.new()
	probe.response = {
		"ok": false,
		"status": "blocked",
		"reason": "blocked_capsule_probe",
		"authoritative": true,
		"sampleCount": 2,
		"details": {
			"collider": "Wildlife_boar",
			"class": "StaticBody3D",
			"kind": "prop",
			"obstacleClass": "dynamic_actor",
			"cell": Vector2i(1, 0)
		}
	}
	var authority := NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, probe)
	var entry := { "id": "v2-dynamic-static-body-npc" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "move", "targetCell": Vector2i(2, 0) }, { "priority": 120 })
	var request_id := String(request.get("requestId", ""))
	var blocked: Dictionary = authority.commit_route_after_probe(entry, request_id, v2_probe_contract_route(), { "kind": "move", "targetCell": Vector2i(2, 0) })
	var moving: Dictionary = authority.begin_moving(request_id, "should_wait_for_dynamic_clearance")
	var passed := String(blocked.get("state", "")) == "blocked_dynamic" \
		and not bool(blocked.get("hasLease", true)) \
		and not bool(moving.get("ok", true)) \
		and String(moving.get("reason", "")) == "route_not_ready"
	return outcome(
		passed,
		"blocked=%s moving=%s" % [JSON.stringify(blocked), JSON.stringify(moving)],
		["v2_moving_static_body_is_dynamic_block", "v2_dynamic_block_remains_unleased", "v2_static_wall_contract_remains_separate"],
		{ "blocked": blocked, "moving": moving }
	)

func test_dynamic_actor_not_baked_as_static_prop(_mode: String) -> Dictionary:
	var adapter := GeneratedWorldNavigationAdapterScript.new()
	var wildlife := StaticBody3D.new()
	wildlife.set_meta("kind", "prop")
	wildlife.set_meta("material", "wildlife")
	wildlife.set_meta("navigation_obstacle_class", "dynamic_actor")
	var ore := StaticBody3D.new()
	ore.set_meta("kind", "prop")
	ore.set_meta("material", "ironOre")
	var wildlife_static := adapter.prop_blocks_npc(wildlife)
	var ore_static := adapter.prop_blocks_npc(ore)
	wildlife.free()
	ore.free()
	var passed := not wildlife_static and ore_static
	return outcome(
		passed,
		"wildlifeStatic=%s oreStatic=%s" % [str(wildlife_static), str(ore_static)],
		["moving_wildlife_excluded_from_static_nav_publication", "ordinary_props_remain_static_blockers"],
		{ "wildlifeStatic": wildlife_static, "oreStatic": ore_static }
	)

func test_static_prop_reserves_actor_clearance(_mode: String) -> Dictionary:
	var adapter := GeneratedWorldNavigationAdapterScript.new()
	var prop := StaticBody3D.new()
	add_child(prop)
	prop.global_position = Vector3.ZERO
	adapter.call("_index_prop_clearance", prop, Vector2i.ZERO)
	var clearance: Dictionary = adapter.get("cached_prop_clearance")
	var cardinal_cells := [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
	var cardinal_reserved := true
	for cell in cardinal_cells:
		if clearance.get(cell, null) != prop:
			cardinal_reserved = false
	var diagonals_reserved := clearance.has(Vector2i(1, 1))
	remove_child(prop)
	prop.free()
	var passed := cardinal_reserved and not diagonals_reserved
	return outcome(
		passed,
		"clearanceCells=%s" % JSON.stringify(clearance.keys()),
		["static_prop_reserves_npc_radius", "clearance_is_bounded_to_required_cells"],
		{ "clearanceCells": clearance.keys(), "cardinalReserved": cardinal_reserved, "diagonalsReserved": diagonals_reserved }
	)

func test_route_authority_v2_repairs_static_probe_block(_mode: String) -> Dictionary:
	var probe := FakeSequenceRouteAuthorityV2Probe.new()
	probe.responses = [
		{
			"ok": false,
			"status": "blocked",
			"reason": "blocked_capsule_probe",
			"authoritative": true,
			"sampleCount": 2,
			"details": {
				"collider": "fixture-rock",
				"class": "StaticBody3D",
				"kind": "prop",
				"blockType": "prop",
				"cell": Vector2i(1, 0)
			}
		},
		{
			"ok": true,
			"status": "passed",
			"reason": "",
			"authoritative": true,
			"sampleCount": 4,
			"details": { "completedSamples": 4 }
		}
	]
	var repair_substrate := FakeProbeRepairSubstrate.new()
	var repaired_route := v2_probe_contract_route()
	repaired_route["source"] = "fixture_probe_repair_route"
	repaired_route["cells"] = [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(2, 0)]
	repaired_route["waypoints"] = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(0.0, 0.0, 1.35),
		Vector3(1.35, 0.0, 1.35),
		Vector3(2.7, 0.0, 1.35),
		Vector3(2.7, 0.0, 0.0)
	]
	repaired_route["probeRepair"] = { "ok": true, "reason": "blocked_capsule_probe" }
	repair_substrate.repaired_route = repaired_route
	var authority := NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, probe)
	var entry := { "id": "v2-probe-repair-npc" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "home", "targetCell": Vector2i(2, 0) }, { "priority": 140 })
	var request_id := String(request.get("requestId", ""))
	var ready: Dictionary = authority.commit_route_after_probe(entry, request_id, v2_probe_contract_route(), { "kind": "home", "targetCell": Vector2i(2, 0) }, {
		"repairSubstrate": repair_substrate,
		"repairStartCell": Vector2i(0, 0),
		"repairCandidateCells": [Vector2i(2, 0)],
		"repairPlanOptions": { "allowOutside": false, "movingHome": true }
	})
	var lease: Dictionary = ready.get("routeLease", {}) if ready.get("routeLease", {}) is Dictionary else {}
	var route_summary: Dictionary = ready.get("route", {}) if ready.get("route", {}) is Dictionary else {}
	var repair_summary: Dictionary = route_summary.get("probeRepair", {}) if route_summary.get("probeRepair", {}) is Dictionary else {}
	var repair_call: Dictionary = repair_substrate.calls[0] if not repair_substrate.calls.is_empty() else {}
	var avoid_cells: Array = repair_call.get("avoidCells", []) if repair_call.get("avoidCells", []) is Array else []
	var passed := String(ready.get("state", "")) == "ready" \
		and bool(ready.get("hasLease", false)) \
		and String(lease.get("source", "")) == "fixture_probe_repair_route" \
		and probe.calls.size() == 2 \
		and repair_substrate.calls.size() == 1 \
		and bool(repair_summary.get("ok", false)) \
		and avoid_cells.has(Vector2i(1, 0))
	return outcome(
		passed,
		"ready=%s probeCalls=%s repairCalls=%s" % [JSON.stringify(ready), JSON.stringify(probe.calls), JSON.stringify(repair_substrate.calls)],
		["v2_static_probe_block_can_repair_before_lease", "v2_repairs_then_reprobes", "v2_repaired_lease_uses_repaired_route"],
		{ "ready": ready, "probeCalls": probe.calls, "repairCalls": repair_substrate.calls }
	)

func test_route_authority_v2_defers_probe_repair_under_budget(_mode: String) -> Dictionary:
	var probe := FakeRouteAuthorityV2Probe.new()
	probe.response = {
		"ok": false,
		"status": "blocked",
		"reason": "blocked_capsule_probe",
		"authoritative": true,
		"sampleCount": 2,
		"details": {
			"collider": "fixture-tree",
			"class": "StaticBody3D",
			"kind": "prop",
			"blockType": "prop",
			"cell": Vector2i(1, 0)
		}
	}
	var repair_substrate := FakeProbeRepairSubstrate.new()
	repair_substrate.repaired_route = {
		"ok": false,
		"status": "pending_budget",
		"classification": "pending_budget",
		"reason": "search_budget_deferred",
		"probeRepair": { "ok": false, "reason": "blocked_capsule_probe" }
	}
	var authority := NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, probe)
	var entry := { "id": "v2-probe-repair-budget-npc" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "forage", "targetCell": Vector2i(2, 0) }, { "priority": 90 })
	var pending: Dictionary = authority.commit_route_after_probe(entry, String(request.get("requestId", "")), v2_probe_contract_route(), { "kind": "forage", "targetCell": Vector2i(2, 0) }, {
		"repairSubstrate": repair_substrate,
		"repairStartCell": Vector2i(0, 0),
		"repairCandidateCells": [Vector2i(2, 0)],
		"repairPlanOptions": { "allowOutside": true, "semanticKind": "forage_target" }
	})
	var avoid_cells: Array = pending.get("probeRepairAvoidCells", []) if pending.get("probeRepairAvoidCells", []) is Array else []
	var passed := String(pending.get("state", "")) == "pending_budget" \
		and String(pending.get("reason", "")) == "search_budget_deferred" \
		and not bool(pending.get("hasLease", true)) \
		and repair_substrate.calls.size() == 1 \
		and avoid_cells.has(Vector2i(1, 0))
	return outcome(
		passed,
		"pending=%s repairCalls=%s" % [JSON.stringify(pending), JSON.stringify(repair_substrate.calls)],
		["v2_probe_repair_budget_is_pending_not_terminal", "v2_probe_repair_retains_blocked_cell_avoidance"],
		{ "pending": pending, "repairCalls": repair_substrate.calls }
	)

func test_route_authority_v2_probe_pending_budget(_mode: String) -> Dictionary:
	var probe := FakeRouteAuthorityV2Probe.new()
	probe.response = {
		"ok": false,
		"status": "pending_probe",
		"reason": "collision_probe_budget",
		"authoritative": true,
		"sampleCount": 3,
		"details": {
			"cursor": {
				"segmentIndex": 1,
				"sampleIndex": 2,
				"completedSamples": 3
			}
		}
	}
	var authority := NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, probe)
	var entry := { "id": "v2-probe-budget-npc" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "home", "targetCell": Vector2i(2, 0) }, { "priority": 120 })
	var request_id := String(request.get("requestId", ""))
	var pending: Dictionary = authority.commit_route_after_probe(entry, request_id, v2_probe_contract_route(), { "kind": "home", "targetCell": Vector2i(2, 0) })
	# Pending-state duration is measured only after a physics-frame clock advance.
	authority.begin_frame()
	var pending_debug: Dictionary = authority.debug_for_entry(entry)
	var stats: Dictionary = authority.stats()
	var passed := String(pending.get("state", "")) == "probing" \
		and String(pending.get("reason", "")) == "collision_probe_budget" \
		and not bool(pending.get("hasLease", true)) \
		and int(pending_debug.get("pendingProbeFrames", 0)) > 0 \
		and int(stats.get("probeCursors", 0)) == 1
	return outcome(
		passed,
		"pending=%s pendingDebug=%s stats=%s calls=%s" % [JSON.stringify(pending), JSON.stringify(pending_debug), JSON.stringify(stats), JSON.stringify(probe.calls)],
		["v2_probe_budget_stays_pending", "v2_probe_budget_does_not_block_target", "v2_probe_cursor_retained"],
		{ "pending": pending, "pendingDebug": pending_debug, "stats": stats, "probeCalls": probe.calls }
	)

func v2_probe_contract_route(with_door := false) -> Dictionary:
	var route := {
		"ok": true,
		"status": "routed",
		"reason": "",
		"source": "v2_probe_contract",
		"targetCell": Vector2i(2, 0),
		"fallbackCell": Vector2i(2, 0),
		"snapshotRevision": "v2-probe-contract",
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],
		"waypoints": [Vector3(0.0, 0.0, 0.0), Vector3(1.35, 0.0, 0.0), Vector3(2.7, 0.0, 0.0)],
		"actions": {},
		"proof": {}
	}
	if with_door:
		route["actions"] = { "1,0": { "kind": "door", "portalId": "fixture:door" } }
		route["proof"] = {
			"doorEdges": [{
				"fromCell": Vector2i(0, 0),
				"toCell": Vector2i(1, 0),
				"door": { "portalId": "fixture:door" }
			}]
		}
	return route

func test_route_lease_executor_follows_v2_lease(_mode: String) -> Dictionary:
	var authority := NpcRouteAuthorityV2Script.new()
	var body := CharacterBody3D.new()
	add_child(body)
	body.global_position = Vector3.ZERO
	var entry := {
		"id": "v2-executor-npc",
		"body": body,
		"motorProfile": CharacterMotorProfileScript.npc_default()
	}
	var request: Dictionary = authority.submit_request(entry, { "kind": "move", "targetCell": Vector2i(1, 0) }, { "priority": 100 })
	var request_id := String(request.get("requestId", ""))
	var route := v2_probe_contract_route()
	route["targetCell"] = Vector2i(1, 0)
	route["fallbackCell"] = Vector2i(1, 0)
	route["cells"] = [Vector2i(0, 0), Vector2i(1, 0)]
	route["waypoints"] = [Vector3.ZERO, Vector3(0.65, 0.0, 0.0)]
	var ready: Dictionary = authority.mark_ready(request_id, route, {
		"ok": true,
		"status": "passed",
		"reason": "",
		"authoritative": true
	})
	var lease: Dictionary = ready.get("routeLease", {}) if ready.get("routeLease", {}) is Dictionary else {}
	var executor = NpcRouteLeaseExecutorScript.new()
	executor.setup(authority, self, null, PassthroughCrowdVelocityService.new())
	var last := {}
	for _i in range(16):
		authority.begin_frame()
		last = executor.execute(entry, request_id, lease, 0.1, { "waypointRadius": 0.12 })
		if String(last.get("status", "")) == "arrived":
			break
	var debug: Dictionary = authority.debug_for_entry(entry)
	var events: Array = debug.get("recentEvents", []) if debug.get("recentEvents", []) is Array else []
	var saw_started := false
	var saw_completed := false
	for event_value in events:
		if not (event_value is Dictionary):
			continue
		var event: Dictionary = event_value
		if String(event.get("state", "")) == "execution:segment_started":
			saw_started = true
		if String(event.get("state", "")) == "execution:segment_completed":
			saw_completed = true
	var final_distance := Vector2(body.global_position.x - 0.65, body.global_position.z).length()
	body.queue_free()
	var passed := String(last.get("status", "")) == "arrived" \
		and String(debug.get("state", "")) == "arrived" \
		and saw_started \
		and saw_completed \
		and final_distance <= 0.16 \
		and String((lease.get("probeCertificate", {}) as Dictionary).get("status", "")) == "passed"
	return outcome(
		passed,
		"last=%s debug=%s finalDistance=%.3f events=%s" % [JSON.stringify(last), JSON.stringify(debug), final_distance, JSON.stringify(events)],
		["v2_executor_consumes_ready_lease", "v2_executor_uses_motor_to_arrive", "v2_executor_reports_segments_to_authority"],
		{ "last": last, "debug": debug, "finalDistance": final_distance, "events": events }
	)


func test_route_lease_executor_requires_crowd_authority(_mode: String) -> Dictionary:
	var authority := NpcRouteAuthorityV2Script.new()
	var body := CharacterBody3D.new()
	add_child(body)
	body.global_position = Vector3.ZERO
	var entry := {
		"id": "v2-executor-missing-crowd",
		"body": body,
		"motorProfile": CharacterMotorProfileScript.npc_default()
	}
	var request: Dictionary = authority.submit_request(entry, { "kind": "move", "targetCell": Vector2i(1, 0) }, { "priority": 100 })
	var request_id := String(request.get("requestId", ""))
	var route := v2_probe_contract_route()
	route["targetCell"] = Vector2i(1, 0)
	route["fallbackCell"] = Vector2i(1, 0)
	route["cells"] = [Vector2i(0, 0), Vector2i(1, 0)]
	route["waypoints"] = [Vector3.ZERO, Vector3(0.65, 0.0, 0.0)]
	var ready: Dictionary = authority.mark_ready(request_id, route, {
		"ok": true,
		"status": "passed",
		"reason": "",
		"authoritative": true
	})
	var lease: Dictionary = ready.get("routeLease", {}) if ready.get("routeLease", {}) is Dictionary else {}
	var executor := NpcRouteLeaseExecutorScript.new()
	executor.setup(authority, self)
	authority.begin_frame()
	var result: Dictionary = executor.execute(entry, request_id, lease, 0.1, { "waypointRadius": 0.12 })
	var avoidance: Dictionary = result.get("avoidance", {}) if result.get("avoidance", {}) is Dictionary else {}
	body.queue_free()
	var passed := String(result.get("status", "")) == "waiting" \
		and String(result.get("reason", "")) == "blocked_dynamic" \
		and String(avoidance.get("reason", "")) == "missing_crowd_authority" \
		and float(result.get("moved", -1.0)) == 0.0
	return outcome(
		passed,
		"result=%s avoidance=%s" % [JSON.stringify(result), JSON.stringify(avoidance)],
		["v2_executor_requires_crowd_authority", "v2_executor_missing_crowd_fails_closed", "v2_executor_missing_crowd_never_moves"],
		{ "result": result, "avoidance": avoidance }
	)


func test_route_lease_executor_accepts_crossed_waypoint(_mode: String) -> Dictionary:
	var executor = NpcRouteLeaseExecutorScript.new()
	var crossed := bool(executor.call(
		"_crossed_waypoint",
		Vector3(0.0, 0.0, 0.0),
		Vector3(0.74, 0.0, 0.0),
		Vector3(0.38, 0.0, 0.0),
		0.12
	))
	var near_miss := bool(executor.call(
		"_crossed_waypoint",
		Vector3(0.0, 0.0, 0.0),
		Vector3(0.74, 0.0, 0.0),
		Vector3(0.38, 0.0, 0.20),
		0.12
	))
	var before_target := bool(executor.call(
		"_crossed_waypoint",
		Vector3(0.0, 0.0, 0.0),
		Vector3(0.22, 0.0, 0.0),
		Vector3(0.38, 0.0, 0.0),
		0.12
	))
	var passed := crossed and not near_miss and not before_target
	return outcome(
		passed,
		"crossed=%s nearMiss=%s beforeTarget=%s" % [str(crossed), str(near_miss), str(before_target)],
		["crossed_waypoint_completes_segment", "near_miss_does_not_cut_route_corner", "pre_target_motion_does_not_complete_segment"],
		{ "crossed": crossed, "nearMiss": near_miss, "beforeTarget": before_target }
	)

func test_route_lease_executor_preserves_moving_home_semantics(_mode: String) -> Dictionary:
	var routine := _execute_single_v2_lease_for_semantic("forage", "work_area", false)
	var home := _execute_single_v2_lease_for_semantic("home", "home_interior", true)
	var passed := bool(routine.get("ok", false)) \
		and bool(home.get("ok", false)) \
		and not bool(routine.get("routeMovingHome", true)) \
		and not bool(routine.get("movingHome", true)) \
		and bool(home.get("routeMovingHome", false)) \
		and bool(home.get("movingHome", false))
	return outcome(
		passed,
		"routine=%s home=%s" % [JSON.stringify(routine), JSON.stringify(home)],
		["routine_v2_leases_do_not_masquerade_as_home_routes", "home_v2_leases_keep_moving_home_semantics"],
		{ "routine": routine, "home": home }
	)

func _execute_single_v2_lease_for_semantic(intent_kind: String, semantic_kind: String, moving_home: bool) -> Dictionary:
	var authority := NpcRouteAuthorityV2Script.new()
	var body := CharacterBody3D.new()
	add_child(body)
	body.global_position = Vector3.ZERO
	var entry := {
		"id": "v2-semantic-%s-%s" % [intent_kind, semantic_kind],
		"body": body,
		"motorProfile": CharacterMotorProfileScript.npc_default()
	}
	var request: Dictionary = authority.submit_request(entry, {
		"kind": intent_kind,
		"semanticKind": semantic_kind,
		"targetCell": Vector2i(0, 0),
		"movingHome": moving_home
	}, { "priority": 100 })
	var request_id := String(request.get("requestId", ""))
	var route := v2_probe_contract_route()
	route["targetCell"] = Vector2i(0, 0)
	route["fallbackCell"] = Vector2i(0, 0)
	route["cells"] = [Vector2i(0, 0)]
	route["waypoints"] = [Vector3.ZERO]
	var ready: Dictionary = authority.mark_ready(request_id, route, {
		"ok": true,
		"status": "passed",
		"reason": "",
		"authoritative": true
	})
	var lease: Dictionary = ready.get("routeLease", {}) if ready.get("routeLease", {}) is Dictionary else {}
	var executor = NpcRouteLeaseExecutorScript.new()
	executor.setup(authority, self)
	authority.begin_frame()
	var result: Dictionary = executor.execute(entry, request_id, lease, 0.1, {
		"waypointRadius": 0.12,
		"intentKind": intent_kind,
		"semanticKind": semantic_kind,
		"movingHome": moving_home
	})
	var summary := {
		"ok": String(result.get("status", "")) == "arrived",
		"result": result,
		"routeMovingHome": bool(entry.get("routeMovingHome", false)),
		"movingHome": bool(entry.get("movingHome", false))
	}
	body.queue_free()
	return summary

func test_route_lease_executor_rejects_unready_lease(_mode: String) -> Dictionary:
	var authority := NpcRouteAuthorityV2Script.new()
	var body := CharacterBody3D.new()
	add_child(body)
	body.global_position = Vector3.ZERO
	var entry := { "id": "v2-executor-reject-npc", "body": body }
	var request: Dictionary = authority.submit_request(entry, { "kind": "move", "targetCell": Vector2i(1, 0) }, { "priority": 100 })
	var request_id := String(request.get("requestId", ""))
	var executor = NpcRouteLeaseExecutorScript.new()
	executor.setup(authority, self)
	var unprobed := v2_probe_contract_route()
	var unprobed_lease := {
		"state": "ready",
		"waypoints": unprobed.get("waypoints", []),
		"probeCertificate": {}
	}
	var missing_probe: Dictionary = executor.execute(entry, request_id, unprobed_lease, 0.1)
	var forged_lease := {
		"state": "ready",
		"waypoints": unprobed.get("waypoints", []),
		"probeCertificate": {
			"ok": true,
			"status": "passed",
			"authoritative": true
		}
	}
	var unready: Dictionary = executor.execute(entry, request_id, forged_lease, 0.1)
	var debug: Dictionary = authority.debug_for_entry(entry)
	body.queue_free()
	var passed := String(missing_probe.get("status", "")) == "rejected" \
		and String(missing_probe.get("reason", "")) == "lease_missing_probe_certificate" \
		and String(unready.get("status", "")) == "rejected" \
		and String(unready.get("reason", "")) == "route_not_ready" \
		and String(debug.get("state", "")) == "queued" \
		and not bool(debug.get("hasLease", true))
	return outcome(
		passed,
		"missingProbe=%s unready=%s debug=%s" % [JSON.stringify(missing_probe), JSON.stringify(unready), JSON.stringify(debug)],
		["v2_executor_rejects_unprobed_lease", "v2_executor_rejects_non_ready_authority_request", "v2_executor_does_not_invent_route_truth"],
		{ "missingProbe": missing_probe, "unready": unready, "debug": debug }
	)

func test_route_ticket_diagnostic_state_names(_mode: String) -> Dictionary:
	var ticket := RouteTicketScript.new()
	ticket.configure("ticket:test", "npc:test", "start->goal", "goal", Vector2i.ZERO, Vector2i(1, 0), { "kind": "move" }, 1)
	var expected_states := [
		{ "state": RouteTicketScript.State.QUEUED, "name": "queued", "pending": true },
		{ "state": RouteTicketScript.State.WAITING_NAV_DATA, "name": "waiting_nav_data", "pending": true },
		{ "state": RouteTicketScript.State.PLANNING, "name": "planning", "pending": true },
		{ "state": RouteTicketScript.State.PROBING, "name": "probing", "pending": true },
		{ "state": RouteTicketScript.State.READY, "name": "ready", "pending": false }
	]
	var names := {}
	var pending_route_states := {}
	var passed := true
	for expected in expected_states:
		ticket.state = int(expected.get("state", RouteTicketScript.State.QUEUED))
		ticket.reason = String(expected.get("name", ""))
		var state_name := ticket.state_name()
		names[state_name] = true
		if state_name != String(expected.get("name", "")):
			passed = false
		if bool(expected.get("pending", false)):
			var pending_route: Dictionary = ticket.to_pending_route()
			var pending_state := String(pending_route.get("routeTicketState", ""))
			pending_route_states[pending_state] = String(pending_route.get("reason", ""))
			if pending_state != state_name:
				passed = false
	for required in ["queued", "waiting_nav_data", "planning", "probing", "ready"]:
		if not bool(names.get(required, false)):
			passed = false
	return outcome(
		passed,
		"states=%s pendingRoutes=%s" % [JSON.stringify(names), JSON.stringify(pending_route_states)],
		["route_ticket_diagnostics_include_queued_waiting_planning_probing_ready", "pending_routes_emit_route_ticket_state"],
		{
			"states": names,
			"pendingRouteStates": pending_route_states
		}
	)

func test_nav_data_readiness_missing_tiles_pending(_mode: String) -> Dictionary:
	var owner := FakeNavDataReadinessOwner.new()
	var service := NavDataReadinessServiceScript.new()
	service.setup(owner)
	var ready_entry := {}
	owner.mark_loading = false
	var ready: Dictionary = service.ensure_ready_for_route(ready_entry, { "kind": "work" })
	var loading_ready_entry := {}
	owner.mark_loading = true
	owner.ready = true
	var loading_ready: Dictionary = service.ensure_ready_for_route(loading_ready_entry, { "kind": "work" })
	var pending_entry := {}
	owner.ready = false
	var pending: Dictionary = service.ensure_ready_for_route(pending_entry, { "kind": "work" })
	var passed := bool(ready.get("ready", false)) \
		and String(ready.get("state", "")) == String(NpcEnumsScript.ROUTE_AUTHORITY_READY) \
		and not bool(loading_ready.get("ready", true)) \
		and String(loading_ready.get("state", "")) == String(NpcEnumsScript.ROUTE_AUTHORITY_PENDING_NAV_DATA) \
		and String(loading_ready.get("detail", "")) == "route_tiles_still_loading" \
		and not bool(pending.get("ready", true)) \
		and String(pending.get("state", "")) == String(NpcEnumsScript.ROUTE_AUTHORITY_PENDING_NAV_DATA) \
		and String(pending.get("reason", "")) == "navmesh_tile_budget"
	return outcome(
		passed,
		"ready=%s loadingReady=%s pending=%s" % [JSON.stringify(ready), JSON.stringify(loading_ready), JSON.stringify(pending)],
		["tile_readiness_is_explicit", "background_loading_is_pending_nav_data", "missing_tiles_are_pending_nav_data", "pending_nav_data_not_unreachable"],
		{ "ready": ready, "loadingReady": loading_ready, "pending": pending, "stats": service.stats() }
	)

func test_navigation_map_sync_pending_is_nav_data(_mode: String) -> Dictionary:
	var canonical := NpcRouteAuthorityScript.canonical_state_for_route({
		"ok": false,
		"status": "pending",
		"reason": "navigation_map_sync_pending",
		"waypoints": []
	}, {})
	var pending := NpcRouteAuthorityScript.pending_state_for_reason("navigation_map_sync_pending")
	var service := NavmeshWorldServiceScript.new()
	var readiness: Dictionary = service.navigation_map_readiness()
	var passed := canonical == NpcEnumsScript.ROUTE_AUTHORITY_PENDING_NAV_DATA \
		and pending == NpcEnumsScript.ROUTE_AUTHORITY_PENDING_NAV_DATA \
		and readiness.has("ready") \
		and readiness.has("reason") \
		and readiness.has("iterationId")
	return outcome(
		passed,
		"canonical=%s pending=%s readiness=%s" % [String(canonical), String(pending), JSON.stringify(readiness)],
		["navigation_map_sync_pending_is_nav_data", "navigation_map_readiness_reports_iteration", "sync_pending_not_static_unreachable"],
		{
			"canonical": String(canonical),
			"pending": String(pending),
			"readiness": readiness
		}
	)

func test_stable_tie_break(_mode: String) -> Dictionary:
	var body_10 := CharacterBody3D.new()
	body_10.name = "fallback-10"
	var body_02 := CharacterBody3D.new()
	body_02.name = "fallback-02"
	var context_10 = NpcAgentContextScript.from_profile(body_10, { "id": "npc-10", "name": "Ten" })
	var context_02 = NpcAgentContextScript.from_profile(body_02, { "id": "npc-02", "name": "Two" })
	var sorted := NpcAgentContextScript.stable_sort_ids([context_10, { "stableId": "npc-01" }, context_02])
	var scheduler := NpcBrainSchedulerScript.new()
	scheduler.register_agent("npc-10")
	scheduler.register_agent("npc-02")
	scheduler.register_agent("npc-01")
	var first_slice := scheduler.next_update_slice()
	body_10.free()
	body_02.free()
	var passed: bool = sorted == ["npc-01", "npc-02", "npc-10"] and first_slice == ["npc-01", "npc-02", "npc-10"]
	return outcome(
		passed,
		"sorted=%s slice=%s" % [JSON.stringify(sorted), JSON.stringify(first_slice)],
		["stable_id_order", "scheduler_sorted_order"],
		{ "stableSorted": sorted, "schedulerSlice": first_slice }
	)

func test_urgent_brain_admission_is_fair(_mode: String) -> Dictionary:
	var autonomy := NpcAutonomySystemScript.new()
	autonomy.setup(null, null)
	var urgent_entries: Array = []
	for index in range(25):
		urgent_entries.append({ "id": "urgent-%02d" % index })
	var first_slice: Array = autonomy.select_urgent_brain_entries(urgent_entries, 12)
	var second_slice: Array = autonomy.select_urgent_brain_entries(urgent_entries, 12)
	var third_slice: Array = autonomy.select_urgent_brain_entries(urgent_entries, 12)
	var admitted := {}
	for slice in [first_slice, second_slice, third_slice]:
		for entry_value in slice:
			if entry_value is Dictionary:
				admitted[String((entry_value as Dictionary).get("id", ""))] = true
	var system_source := read_text("res://scripts/NpcSystem.gd")
	var passed := first_slice.size() == 12 \
		and second_slice.size() == 12 \
		and third_slice.size() == 12 \
		and admitted.size() == 25 \
		and system_source.find("select_urgent_brain_entries") >= 0
	autonomy.free()
	return outcome(
		passed,
		"first=%s second=%s third=%s admitted=%d" % [JSON.stringify(first_slice), JSON.stringify(second_slice), JSON.stringify(third_slice), admitted.size()],
		["urgent_brain_round_robin", "lower_list_urgent_actor_admitted", "npc_system_uses_fair_urgent_selection"],
		{
			"first": first_slice,
			"second": second_slice,
			"third": third_slice,
			"admittedCount": admitted.size()
		}
	)

func test_scripted_order_stall_trace_precedes_route_request(_mode: String) -> Dictionary:
	var trace_path := "user://npc_scripted_order_stall_trace.json"
	var prior_trace := isolate_trace_file(trace_path)
	var authority := NpcRouteAuthorityV2Script.new()
	var actor_id := "trace-order-actor"
	var entry := {
		"id": actor_id,
		"scriptedOrder": {
			"id": "trace-order-actor:go_home:1",
			"kind": "go_home",
			"state": "PENDING",
			"usesRouteStack": true,
			"submittedPhysicsFrame": 41,
			"submittedWallMsec": Time.get_ticks_msec() - 9000
		}
	}
	authority.actor_entries[actor_id] = entry
	authority.begin_frame()
	var trace_value = read_json_file(trace_path)
	var traces: Array = trace_value.get("traces", []) if trace_value is Dictionary and trace_value.get("traces", []) is Array else []
	var trace: Dictionary = traces[0] if not traces.is_empty() and traces[0] is Dictionary else {}
	var source := read_text("res://scripts/NpcSystem.gd")
	var passed := String(trace.get("actorId", "")) == actor_id \
		and String(trace.get("activeRequestId", "")) == "" \
		and int(trace.get("wallWaitMsec", 0)) >= 8000 \
		and source.find("submittedWallMsec") >= 0
	restore_isolated_trace_file(trace_path, prior_trace)
	var trace_restored := trace_file_matches_prior(trace_path, prior_trace)
	passed = passed and trace_restored
	return outcome(
		passed,
		"trace=%s restored=%s" % [JSON.stringify(trace), str(trace_restored)],
		["scripted_order_trace", "pre_request_stall_capture", "generic_route_stack_order", "preexisting_trace_preserved"],
		{ "trace": trace, "traceRestored": trace_restored }
	)


func test_collision_recovery_stall_trace(_mode: String) -> Dictionary:
	var trace_path := "user://npc_route_collision_recovery_stall_trace.json"
	var prior_trace := isolate_trace_file(trace_path)
	var authority := NpcRouteAuthorityV2Script.new()
	var actor_id := "collision-recovery-actor"
	var entry := {
		"id": actor_id,
		"scriptedOrder": {
			"id": "collision-recovery-actor:go_home:1",
			"kind": "go_home",
			"state": "ACTIVE",
			"usesRouteStack": true
		}
	}
	var request: Dictionary = authority.submit_request(entry, { "kind": "home", "targetCell": Vector2i(3, 4) }, { "priority": 180 })
	var request_id := String(request.get("requestId", ""))
	authority.collision_recovery_stalls_by_actor[actor_id] = {
		"firstWallMsec": Time.get_ticks_msec() - 9000,
		"collisionCount": 1,
		"captured": false
	}
	authority.report_unexpected_collision(request_id, "unexpected_collision", {
		"blockedContactName": "Fence",
		"blockedContactKind": "static_body"
	})
	var trace_value = read_json_file(trace_path)
	var traces: Array = trace_value.get("traces", []) if trace_value is Dictionary and trace_value.get("traces", []) is Array else []
	var trace: Dictionary = traces[0] if not traces.is_empty() and traces[0] is Dictionary else {}
	var collision: Dictionary = trace.get("lastCollision", {}) if trace.get("lastCollision", {}) is Dictionary else {}
	var passed := String(trace.get("actorId", "")) == actor_id \
		and int(trace.get("collisionCount", 0)) >= 2 \
		and int(trace.get("wallRecoveryMsec", 0)) >= 8000 \
		and String(collision.get("blockedContactName", "")) == "Fence" \
		and String((trace.get("activeRequest", {}) as Dictionary).get("requestId", "")) == request_id
	restore_isolated_trace_file(trace_path, prior_trace)
	var trace_restored := trace_file_matches_prior(trace_path, prior_trace)
	passed = passed and trace_restored
	return outcome(
		passed,
		"trace=%s restored=%s" % [JSON.stringify(trace), str(trace_restored)],
		["collision_recovery_trace", "repeated_collision_loop_capture", "route_repair_observation", "preexisting_trace_preserved"],
		{ "trace": trace, "traceRestored": trace_restored }
	)

func test_profile_capability_filter(_mode: String) -> Dictionary:
	var villager = TraversalProfileScript.from_profile({ "job": "forage" }, false)
	var worker = TraversalProfileScript.from_profile({ "job": "wood" }, false)
	var fighter = TraversalProfileScript.from_profile({ "job": "stone" }, true)
	var passed: bool = (
		villager.can(&"walk")
		and villager.can(&"open_doors")
		and not villager.can(&"use_locked_doors")
		and not villager.can(&"sprint")
		and worker.can(&"carry_bulky_item")
		and fighter.can(&"sprint")
		and fighter.can(&"carry_bulky_item")
	)
	return outcome(
		passed,
		"villager=%s worker=%s fighter=%s" % [JSON.stringify(villager.to_summary()), JSON.stringify(worker.to_summary()), JSON.stringify(fighter.to_summary())],
		["profile_abilities", "capability_filter"],
		{ "villager": villager.to_summary(), "worker": worker.to_summary(), "fighter": fighter.to_summary() }
	)

func test_rng_stream_isolation(mode: String) -> Dictionary:
	var body_a := CharacterBody3D.new()
	body_a.name = "NpcA"
	var body_b := CharacterBody3D.new()
	body_b.name = "NpcB"
	var context_a = NpcAgentContextScript.from_profile(body_a, { "id": "npc-a" })
	var context_b = NpcAgentContextScript.from_profile(body_b, { "id": "npc-b" })
	var seed_a: int = context_a.rng_seed(seed, "goal", mode)
	var seed_a_again: int = context_a.rng_seed(seed, "goal", mode)
	var seed_b: int = context_b.rng_seed(seed, "goal", mode)
	var seed_a_combat: int = context_a.rng_seed(seed, "combat", mode)
	var seq_a: Array[int] = []
	var seq_a_again: Array[int] = []
	var rng_a: RandomNumberGenerator = context_a.rng_stream(seed, "goal", mode)
	var rng_a_again: RandomNumberGenerator = context_a.rng_stream(seed, "goal", mode)
	for i in range(5):
		seq_a.append(rng_a.randi())
		seq_a_again.append(rng_a_again.randi())
	var control := RandomNumberGenerator.new()
	control.seed = 123456
	var expected_first := control.randi()
	var expected_second := control.randi()
	var probe := RandomNumberGenerator.new()
	probe.seed = 123456
	var observed_first := probe.randi()
	context_a.rng_stream(seed, "utility", mode).randi()
	context_b.rng_stream(seed, "utility", mode).randi()
	var observed_second := probe.randi()
	body_a.free()
	body_b.free()
	var passed: bool = seed_a == seed_a_again and seed_a != seed_b and seed_a != seed_a_combat and seq_a == seq_a_again and observed_first == expected_first and observed_second == expected_second
	return outcome(
		passed,
		"seedA=%d seedB=%d seedCombat=%d seq=%s probe=%d/%d" % [seed_a, seed_b, seed_a_combat, JSON.stringify(seq_a), observed_first, observed_second],
		["per_npc_rng_seed", "per_domain_rng_seed", "rng_sequence_repeatable", "world_rng_not_consumed"],
		{
			"seedA": seed_a,
			"seedB": seed_b,
			"seedCombat": seed_a_combat,
			"sequenceA": seq_a,
			"probe": [observed_first, observed_second]
		}
	)

func test_bounded_trace_and_cache(_mode: String) -> Dictionary:
	var telemetry := NpcTelemetryServiceScript.new()
	telemetry.ring_capacity = 4
	for i in range(6):
		telemetry.record_event("npc-a", &"trace", "event_%d" % i)
	var telemetry_events := telemetry.events_for("npc-a")
	var telemetry_stats: Dictionary = telemetry.stats()
	var scheduler := NpcBrainSchedulerScript.new()
	scheduler.max_registered_agents = 3
	var scheduler_accepts := [
		scheduler.register_agent("npc-1"),
		scheduler.register_agent("npc-2"),
		scheduler.register_agent("npc-3"),
		scheduler.register_agent("npc-4")
	]
	var change_bus := NavigationChangeBusScript.new()
	change_bus.max_pending_tiles = 2
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED, "block-a", AABB(Vector3.ZERO, Vector3.ONE), ["0,0"])
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED, "block-b", AABB(Vector3.ONE, Vector3.ONE), ["1,0"])
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED, "block-c", AABB(Vector3(2, 0, 0), Vector3.ONE), ["2,0"])
	var change_stats: Dictionary = change_bus.stats()
	var passed: bool = (
		telemetry_events.size() == 4
		and int(telemetry_stats.get("droppedEvents", {}).get("npc-a", 0)) == 2
		and scheduler_accepts == [true, true, true, false]
		and int(scheduler.stats().get("deniedRegistrations", 0)) == 1
		and int(change_stats.get("pendingTiles", 0)) == 2
		and int(change_stats.get("droppedEvents", 0)) == 1
	)
	return outcome(
		passed,
		"telemetry=%s scheduler=%s changeBus=%s" % [JSON.stringify(telemetry_stats), JSON.stringify(scheduler.stats()), JSON.stringify(change_stats)],
		["bounded_telemetry_ring", "bounded_scheduler_registry", "bounded_change_cache"],
		{ "telemetry": telemetry_stats, "scheduler": scheduler.stats(), "changeBus": change_stats }
	)

func test_cancellation_generation(_mode: String) -> Dictionary:
	var request := RouteRequestScript.new()
	var generation := request.next_generation()
	var stale_cancel := request.cancel(generation - 1)
	var current_before_cancel := request.is_current_generation(generation)
	var current_cancel := request.cancel(generation)
	var current_after_cancel := request.is_current_generation(generation)
	var blackboard := NpcBlackboardScript.new()
	var route_generation := blackboard.next_route_generation()
	var stale_result = RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_COMPLETE, NpcEnumsScript.ROUTE_REASON_NONE, route_generation - 1)
	var current_result = RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_COMPLETE, NpcEnumsScript.ROUTE_REASON_NONE, route_generation)
	var stale_accept := blackboard.accept_route_result(stale_result)
	var current_accept := blackboard.accept_route_result(current_result)
	blackboard.next_route_generation()
	var old_accept_after_advance := blackboard.accept_route_result(current_result)
	var action := NpcActionInstanceScript.new()
	var action_generation := action.next_generation()
	var stale_action := action.apply_terminal(action_generation - 1, NpcEnumsScript.ACTION_STATUS_FAILED, NpcEnumsScript.ROUTE_REASON_STALE_GENERATION)
	var current_action := action.apply_terminal(action_generation, NpcEnumsScript.ACTION_STATUS_CANCELLED, NpcEnumsScript.ROUTE_REASON_CANCELLED)
	var duplicate_action := action.apply_terminal(action_generation, NpcEnumsScript.ACTION_STATUS_FAILED)
	var passed: bool = (
		generation == 1
		and not stale_cancel
		and current_before_cancel
		and current_cancel
		and not current_after_cancel
		and not stale_accept
		and current_accept
		and not old_accept_after_advance
		and not stale_action
		and current_action
		and not duplicate_action
	)
	return outcome(
		passed,
		"request=%s blackboard=%s action=%s" % [JSON.stringify(request.to_summary()), JSON.stringify(blackboard.to_summary()), JSON.stringify(action.to_summary())],
		["route_cancellation_generation", "blackboard_stale_route_rejection", "action_terminal_generation"],
		{ "request": request.to_summary(), "blackboard": blackboard.to_summary(), "action": action.to_summary() }
	)

func test_change_bus_coalesces_tiles(_mode: String) -> Dictionary:
	var autonomy := NpcAutonomySystemScript.new()
	autonomy.setup(null, null)
	var cell := Vector3i(3, 1, 3)
	autonomy.notify_block_created(cell, "woodBlock")
	autonomy.notify_block_removed(cell, "woodBlock")
	var change_bus = autonomy.get("change_bus")
	var events: Array = change_bus.call("flush_frame")
	var event: Dictionary = events[0] if events.size() > 0 else {}
	var passed: bool = (
		events.size() == 1
		and String(event.get("tileKey", "")) == "0,0"
		and int(event.get("coalescedCount", 0)) == 2
		and (event.get("changeKinds", []) as Array).has(String(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED))
		and (event.get("changeKinds", []) as Array).has(String(NpcEnumsScript.CHANGE_KIND_BLOCK_REMOVED))
		and (event.get("objectIds", []) as Array).has("block:3,1,3:woodBlock")
		and int(change_bus.call("pending_count")) == 0
	)
	autonomy.free()
	return outcome(
		passed,
		"events=%s stats=%s" % [JSON.stringify(events), JSON.stringify(change_bus.call("stats"))],
		["change_bus_tile_coalescing", "change_bus_flush_clears_pending", "block_change_adapter"],
		{ "events": events, "stats": change_bus.call("stats") }
	)

func test_change_bus_monotonic_revision(_mode: String) -> Dictionary:
	var bus := NavigationChangeBusScript.new()
	var first := bus.emit_change(NpcEnumsScript.CHANGE_KIND_CHUNK_LOADED, "chunk:0,0", AABB(Vector3.ZERO, Vector3.ONE), ["0,0"])
	var first_events := bus.flush_frame()
	var second := bus.emit_change(NpcEnumsScript.CHANGE_KIND_DOOR_STATE, "door:a", AABB(Vector3.ONE, Vector3.ONE), ["0,0"])
	var second_events := bus.flush_frame()
	var third := bus.emit_change(NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED, "chunk:0,0", AABB(Vector3.ZERO, Vector3.ONE), ["0,0"])
	var passed: bool = (
		first == 1
		and second == 2
		and third == 3
		and first_events.size() == 1
		and second_events.size() == 1
		and int(first_events[0].get("revision", 0)) == 1
		and int(second_events[0].get("revision", 0)) == 2
		and int(bus.stats().get("revision", 0)) == 3
	)
	return outcome(
		passed,
		"first=%d second=%d third=%d firstEvents=%s secondEvents=%s" % [first, second, third, JSON.stringify(first_events), JSON.stringify(second_events)],
		["change_bus_monotonic_revision", "change_bus_event_revision"],
		{ "first": first, "second": second, "third": third, "firstEvents": first_events, "secondEvents": second_events, "stats": bus.stats() }
	)

func test_guard_duty_not_can_fight(_mode: String) -> Dictionary:
	var fighter_body := CharacterBody3D.new()
	fighter_body.name = "Fighter"
	var night_body := CharacterBody3D.new()
	night_body.name = "NightWatcher"
	var fighter = NpcAgentContextScript.from_profile(fighter_body, { "id": "fighter", "canFight": true, "nightGuard": false })
	var watcher = NpcAgentContextScript.from_profile(night_body, { "id": "watcher", "canFight": false, "nightGuard": true })
	fighter_body.free()
	night_body.free()
	var passed: bool = bool(fighter.get("can_fight")) and fighter.get("guard_duty_kind") == NpcEnumsScript.GUARD_DUTY_NONE and not bool(watcher.get("can_fight")) and watcher.get("guard_duty_kind") == NpcEnumsScript.GUARD_DUTY_NIGHT
	return outcome(
		passed,
		"fighter=%s watcher=%s" % [JSON.stringify(fighter.to_summary()), JSON.stringify(watcher.to_summary())],
		["guard_duty_separate_from_can_fight"],
		{ "fighter": fighter.to_summary(), "watcher": watcher.to_summary() }
	)

func test_autonomy_composition_no_main_layer(_mode: String) -> Dictionary:
	var system := NpcSystemScript.new()
	system.setup(null, null)
	var body := CharacterBody3D.new()
	body.name = "ContractNPC"
	system.add_child(body)
	var entry: Dictionary = system.register_npc(body, {
		"id": "contract-npc",
		"name": "Contract NPC",
		"role": "Villager",
		"canFight": false,
		"nightGuard": false,
		"homeCell": Vector2i(1, 2),
		"porchCell": Vector2i(1, 3),
		"guardCell": Vector2i(2, 3),
		"townKey": "contract-town"
	})
	var context = entry.get("agentContext")
	var blackboard = entry.get("blackboard")
	var autonomy_node = system.get("autonomy_system") as Node
	var autonomy_child_ok: bool = autonomy_node != null and autonomy_node.get_parent() == system and autonomy_node.get_script() == NpcAutonomySystemScript
	var context_ok: bool = context != null and context.get_script() == NpcAgentContextScript and String(context.get("stable_id")) == "contract-npc"
	var blackboard_ok: bool = blackboard != null and blackboard.get_script() == NpcBlackboardScript
	var stats: Dictionary = autonomy_node.call("stats") if autonomy_node != null else {}
	var allowed_main_scripts := [
		"Main.gd",
		"MainPropFactory.gd",
		"MainChunkTerrain.gd",
		"MainInteractionFlow.gd",
		"MainPlaytestTools.gd",
		"MainRuntimeTools.gd",
		"MainDiscoveryFlow.gd",
		"MainHudFlow.gd",
		"MainWorldEntities.gd",
		"MainCharacterState.gd",
		"MainGameLoop.gd",
		"MainSetupScene.gd",
		"MainSaveState.gd",
		"MainCore.gd",
		"MainInterface.gd"
	]
	var main_scripts: Array[String] = []
	var unexpected_main_scripts: Array[String] = []
	var dir := DirAccess.open("res://scripts")
	if dir != null:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.begins_with("Main") and file_name.ends_with(".gd"):
				main_scripts.append(file_name)
				if not allowed_main_scripts.has(file_name):
					unexpected_main_scripts.append(file_name)
			file_name = dir.get_next()
		dir.list_dir_end()
	main_scripts.sort()
	unexpected_main_scripts.sort()
	system.unregister_npc(body)
	body.free()
	system.free()
	var passed: bool = autonomy_child_ok and context_ok and blackboard_ok and int(stats.get("contexts", 0)) == 1 and unexpected_main_scripts.is_empty() and String(entry.get("id", "")) == "contract-npc"
	return outcome(
		passed,
		"autonomyChild=%s context=%s blackboard=%s stats=%s unexpectedMain=%s" % [str(autonomy_child_ok), str(context_ok), str(blackboard_ok), JSON.stringify(stats), JSON.stringify(unexpected_main_scripts)],
		["autonomy_system_child", "typed_context_association", "no_new_main_layer", "entry_preserved"],
		{ "stats": stats, "mainScripts": main_scripts, "unexpectedMainScripts": unexpected_main_scripts, "entryId": entry.get("id", "") }
	)

func test_motor_player_characterization_flat(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.player_default()
	var result := run_motor_once(profile, CharacterMotorCommandScript.from_direction(Vector3.RIGHT, float(profile.get("walk_speed"))), true)
	var state = result.get("state")
	var applied: Vector3 = state.get("applied_velocity") if state != null else Vector3.ZERO
	var passed := (
		NpcTestAssertionsScript.approx_equal(float(profile.get("walk_speed")), 9.5)
		and NpcTestAssertionsScript.approx_equal(float(profile.get("sprint_speed")), 15.5)
		and NpcTestAssertionsScript.approx_equal(float(profile.get("acceleration")), 14.0)
		and applied.x > 0.1
	)
	return outcome(
		passed,
		"profile=%s applied=%s" % [JSON.stringify(profile.to_summary()), str(applied)],
		["player_walk_speed", "player_sprint_speed", "player_acceleration", "motor_applies_flat_velocity"],
		{ "profile": profile.to_summary(), "appliedVelocity": [applied.x, applied.y, applied.z] }
	)

func test_motor_player_characterization_slope(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.player_default()
	var passed := (
		NpcTestAssertionsScript.approx_equal(float(profile.get("floor_max_angle_degrees")), 46.0)
		and NpcTestAssertionsScript.approx_equal(float(profile.get("floor_snap_length")), 0.32)
		and NpcTestAssertionsScript.approx_equal(float(profile.get("terrain_walkable_rise")), 1.55)
		and NpcTestAssertionsScript.approx_equal(float(profile.get("terrain_walkable_drop")), 1.55)
	)
	return outcome(
		passed,
		"profile=%s" % JSON.stringify(profile.to_summary()),
		["player_floor_angle", "player_floor_snap", "player_walkable_rise", "player_walkable_drop"],
		{ "profile": profile.to_summary() }
	)

func test_motor_player_characterization_jump(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.player_default()
	var command = CharacterMotorCommandScript.from_direction(Vector3.ZERO, 0.0, true, false)
	var result := run_motor_once(profile, command, true)
	var state = result.get("state")
	var velocity: Vector3 = state.get("velocity") if state != null else Vector3.ZERO
	var passed := (
		state != null
		and bool(state.get("jumped"))
		and velocity.y >= float(profile.get("jump_speed")) - 0.01
		and NpcTestAssertionsScript.approx_equal(float(profile.get("jump_speed")), 8.9)
		and NpcTestAssertionsScript.approx_equal(float(profile.get("gravity")), 26.0)
	)
	return outcome(
		passed,
		"jumped=%s velocity=%s profile=%s" % [str(state != null and bool(state.get("jumped"))), str(velocity), JSON.stringify(profile.to_summary())],
		["player_jump_speed", "player_gravity", "motor_jump_state"],
		{ "velocity": [velocity.x, velocity.y, velocity.z], "profile": profile.to_summary() }
	)

func test_motor_npc_flat_acceleration(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.npc_default()
	var command = CharacterMotorCommandScript.from_velocity(Vector3(float(profile.get("walk_speed")), 0.0, 0.0))
	var result := run_motor_once(profile, command, true)
	var state = result.get("state")
	var requested: Vector3 = state.get("requested_velocity") if state != null else Vector3.ZERO
	var velocity: Vector3 = state.get("velocity") if state != null else Vector3.ZERO
	var passed := (
		state != null
		and bool(profile.get("instant_horizontal_velocity"))
		and NpcTestAssertionsScript.approx_equal(float(profile.get("walk_speed")), 2.6)
		and absf(velocity.x - requested.x) <= 0.05
	)
	return outcome(
		passed,
		"requested=%s velocity=%s profile=%s" % [str(requested), str(velocity), JSON.stringify(profile.to_summary())],
		["npc_profile_instant_velocity", "npc_walk_speed", "npc_motor_velocity_matches_request"],
		{ "requestedVelocity": [requested.x, requested.y, requested.z], "velocity": [velocity.x, velocity.y, velocity.z], "profile": profile.to_summary() }
	)

func test_motor_npc_slope_limit(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.npc_default()
	var passed := NpcTestAssertionsScript.approx_equal(float(profile.get("floor_max_angle_degrees")), 46.0)
	return outcome(passed, "floorMax=%.2f" % float(profile.get("floor_max_angle_degrees")), ["npc_floor_angle_shared"], profile.to_summary())

func test_motor_npc_step_up_limit(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.npc_default()
	var passed := float(profile.get("terrain_walkable_rise")) <= 1.20 and float(profile.get("terrain_walkable_rise")) > 0.4
	return outcome(passed, "stepUp=%.2f" % float(profile.get("terrain_walkable_rise")), ["npc_step_up_limit"], profile.to_summary())

func test_motor_npc_safe_drop(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.npc_default()
	var passed := float(profile.get("terrain_walkable_drop")) <= 1.35 and float(profile.get("terrain_landing_distance")) <= 0.20
	return outcome(passed, "drop=%.2f landing=%.2f" % [float(profile.get("terrain_walkable_drop")), float(profile.get("terrain_landing_distance"))], ["npc_safe_drop_limit", "npc_landing_snap_limit"], profile.to_summary())

func test_motor_wall_slide_no_penetration(_mode: String) -> Dictionary:
	var locomotion_text := read_text("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")
	var motor_text := read_text("res://scripts/npc_ai/motor/CharacterMotor3D.gd")
	var passed := locomotion_text.find("global_position =") < 0 and motor_text.find("global_position.x =") < 0 and motor_text.find("global_position.z =") < 0 and motor_text.find("move_and_slide()") >= 0
	return outcome(
		passed,
		"locomotionGlobalWrite=%d motorHorizontalWriteX=%d motorHorizontalWriteZ=%d" % [locomotion_text.find("global_position ="), motor_text.find("global_position.x ="), motor_text.find("global_position.z =")],
		["route_motion_no_transform_write", "motor_uses_move_and_slide", "motor_no_horizontal_teleport"],
		{ "locomotionGlobalWrite": locomotion_text.find("global_position ="), "motorMoveAndSlide": motor_text.find("move_and_slide()") }
	)

func test_motor_fence_window_corner_no_penetration(_mode: String) -> Dictionary:
	var locomotion_text := read_text("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")
	var passed := (
		locomotion_text.find("capsule_hits_obstacle") >= 0
		and locomotion_text.find("collider_blocks_capsule") >= 0
		and locomotion_text.find("\"prop\", \"npc\", \"hostile\"") >= 0
		and locomotion_text.find("move_and_collide(delta, true") >= 0
	)
	return outcome(
		passed,
		"capsule=%d blockers=%d testMove=%d" % [locomotion_text.find("capsule_hits_obstacle"), locomotion_text.find("collider_blocks_capsule"), locomotion_text.find("move_and_collide(delta, true")],
		["capsule_probe", "dynamic_blockers_include_npcs", "actual_body_test_only_collision_probe"],
		{}
	)

func test_motor_closed_door_blocks(_mode: String) -> Dictionary:
	var controller = NpcRouteMovementControllerScript.new()
	var door := Node3D.new()
	var body := CharacterBody3D.new()
	door.set_meta("kind", "block")
	door.set_meta("block_type", "door")
	door.set_meta("open", false)
	var blocks := bool(controller.collider_blocks_capsule({}, door, body))
	door.free()
	body.free()
	return outcome(blocks, "closedDoorBlocks=%s" % str(blocks), ["closed_door_blocks_capsule"], { "closedDoorBlocks": blocks })

func test_motor_open_door_clears(_mode: String) -> Dictionary:
	var controller = NpcRouteMovementControllerScript.new()
	var door := Node3D.new()
	var body := CharacterBody3D.new()
	door.set_meta("kind", "block")
	door.set_meta("block_type", "door")
	door.set_meta("open", true)
	var clears := not bool(controller.collider_blocks_capsule({}, door, body))
	door.free()
	body.free()
	return outcome(clears, "openDoorClears=%s" % str(clears), ["open_door_clears_capsule"], { "openDoorClears": clears })

func test_motor_door_action_matches_portal_id(_mode: String) -> Dictionary:
	var controller = NpcRouteMovementControllerScript.new()
	var portal_id := "door:door-group:10,0,4:0"
	var group_id := "door-group:10,0,4:0"
	var primary := motor_door_leaf("PrimaryDoorLeaf", portal_id, group_id)
	var sibling := motor_door_leaf("SiblingDoorLeaf", portal_id, group_id)
	var portal_only_entry := {
		"routeActions": {
			"10,5": {
				"kind": "door",
				"portalId": portal_id,
				"cell": Vector2i(10, 5)
			}
		}
	}
	var sibling_leaf_entry := {
		"routeActions": {
			"10,5": {
				"kind": "door",
				"portalId": portal_id,
				"door": primary,
				"cell": Vector2i(10, 5)
			}
		}
	}
	var portal_only_action: Dictionary = controller.route_door_action(portal_only_entry, sibling)
	var sibling_leaf_action: Dictionary = controller.route_door_action(sibling_leaf_entry, sibling)
	var portal_only_summary := {
		"matched": not portal_only_action.is_empty(),
		"portalId": String(portal_only_action.get("portalId", ""))
	}
	var sibling_leaf_summary := {
		"matched": not sibling_leaf_action.is_empty(),
		"portalId": String(sibling_leaf_action.get("portalId", ""))
	}
	var passed := (
		bool(portal_only_summary.get("matched", false))
		and String(portal_only_summary.get("portalId", "")) == portal_id
		and bool(sibling_leaf_summary.get("matched", false))
		and String(sibling_leaf_summary.get("portalId", "")) == portal_id
	)
	primary.free()
	sibling.free()
	return outcome(
		passed,
		"portalOnly=%s siblingLeaf=%s" % [JSON.stringify(portal_only_summary), JSON.stringify(sibling_leaf_summary)],
		["door_action_matches_portal_id", "double_door_sibling_leaf_matches_route_action"],
		{ "portalOnly": portal_only_summary, "siblingLeaf": sibling_leaf_summary }
	)

func test_motor_player_npc_solid_separation(_mode: String) -> Dictionary:
	var npc_mask: int = NpcConstantsScript.COLLISION_NPC_BODY_MASK
	var passed := (
		(npc_mask & NpcConstantsScript.COLLISION_PLAYER_BODY) != 0
		and (npc_mask & NpcConstantsScript.COLLISION_NPC_BODY) != 0
		and (npc_mask & NpcConstantsScript.COLLISION_WORLD_QUERY) != 0
		and (npc_mask & NpcConstantsScript.COLLISION_TERRAIN_BODY) != 0
	)
	return outcome(
		passed,
		"npcMask=%d playerLayer=%d npcLayer=%d worldLayer=%d terrainLayer=%d" % [npc_mask, NpcConstantsScript.COLLISION_PLAYER_BODY, NpcConstantsScript.COLLISION_NPC_BODY, NpcConstantsScript.COLLISION_WORLD_QUERY, NpcConstantsScript.COLLISION_TERRAIN_BODY],
		["npc_collides_with_player_layer", "npc_collides_with_npc_layer", "npc_collides_with_world_layer", "npc_collides_with_terrain_layer"],
		{ "npcMask": npc_mask, "playerLayer": NpcConstantsScript.COLLISION_PLAYER_BODY, "npcLayer": NpcConstantsScript.COLLISION_NPC_BODY }
	)

func test_motor_decorative_path_torch_nonblocking_mask(_mode: String) -> Dictionary:
	var npc_mask: int = NpcConstantsScript.COLLISION_NPC_BODY_MASK
	var safe_mask: int = NpcConstantsScript.COLLISION_NPC_SAFE_PLACEMENT_MASK
	var static_query_mask: int = NpcConstantsScript.COLLISION_NPC_STATIC_QUERY_MASK
	var decorative_layer: int = NpcConstantsScript.COLLISION_NONBLOCKING_PATH
	var chunk_text := read_text("res://scripts/MainChunkTerrain.gd")
	var creation_assigns_nonblocking := (
		chunk_text.find("block_type == \"cobblestonePath\" or block_type == \"torch\"") >= 0
		and chunk_text.find("COLLISION_NONBLOCKING_PATH") >= 0
	)
	var masks_exclude_decorative := (
		(npc_mask & decorative_layer) == 0
		and (safe_mask & decorative_layer) == 0
		and (static_query_mask & decorative_layer) == 0
	)
	var passed := creation_assigns_nonblocking and masks_exclude_decorative
	return outcome(
		passed,
		"npcMask=%d safeMask=%d staticMask=%d decorative=%d creation=%s" % [npc_mask, safe_mask, static_query_mask, decorative_layer, str(creation_assigns_nonblocking)],
		["decorative_layer_excluded_from_npc_masks", "path_torch_assigned_nonblocking_layer"],
		{ "npcMask": npc_mask, "safeMask": safe_mask, "staticQueryMask": static_query_mask, "decorativeLayer": decorative_layer, "creationAssignsNonblocking": creation_assigns_nonblocking }
	)

func test_motor_no_route_transform_write(_mode: String) -> Dictionary:
	var files := {
		"NpcSystem": read_text("res://scripts/NpcSystem.gd"),
		"NpcPathing": read_text("res://scripts/NpcPathing.gd"),
		"NpcRouteMovementController": read_text("res://scripts/npc_ai/movement/NpcRouteMovementController.gd"),
		"NpcMotionController": read_text("res://scripts/npc_ai/NpcMotionController.gd")
	}
	var offenders: Array[String] = []
	for key in files.keys():
		var text: String = files[key]
		if text.find("global_position =") >= 0 or text.find(".position =") >= 0:
			offenders.append(String(key))
	var passed := offenders.is_empty()
	return outcome(passed, "offenders=%s" % JSON.stringify(offenders), ["no_route_global_position_assignment", "no_route_position_assignment"], { "offenders": offenders })

func test_motor_no_unstick_teleport(_mode: String) -> Dictionary:
	var locomotion_text := read_text("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")
	var passed := (
		locomotion_text.find("increment_stuck_recovery") >= 0
		and locomotion_text.find("safe_place_npc") < 0
		and locomotion_text.find("teleport") < 0
		and locomotion_text.find("global_position =") < 0
	)
	return outcome(
		passed,
		"stuck=%d safePlace=%d teleport=%d globalWrite=%d" % [locomotion_text.find("increment_stuck_recovery"), locomotion_text.find("safe_place_npc"), locomotion_text.find("teleport"), locomotion_text.find("global_position =")],
		["stuck_recovery_replans_only", "no_locomotion_safe_placement", "no_teleport_keyword"],
		{}
	)

func test_motor_preserves_active_route_on_transient_replan_failure(_mode: String) -> Dictionary:
	var controller = NpcRouteMovementControllerScript.new()
	var target_cell := Vector2i(8, 4)
	var old_waypoints := [Vector3(1.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0)]
	var old_cells := [Vector2i(1, 0), Vector2i(2, 0)]
	var arrival_radius := NpcConstantsScript.CELL_SIZE * 0.75
	var route_key := "%s:%d,%d:%s:%s:%s:%s:%.3f" % ["job", target_cell.x, target_cell.y, str(true), str(false), "", str(false), arrival_radius]
	var entry := {
		"id": "niko",
		"routeKey": route_key,
		"routeSnapshotRevision": "rev-b",
		"routeForceReplan": true,
		"routeStatus": "moving",
		"routeReason": "",
		"pathWaypoints": old_waypoints.duplicate(),
		"routeCells": old_cells.duplicate(),
		"routeActions": {},
		"routeLeaseId": "test-active-lease",
		"routeLease": {
			"leaseId": "test-active-lease",
			"ownerNpcId": "niko",
			"generation": 1,
			"state": String(NpcEnumsScript.ROUTE_AUTHORITY_READY),
			"reason": String(NpcEnumsScript.ROUTE_REASON_NONE),
			"cells": old_cells.duplicate(),
			"waypoints": old_waypoints.duplicate(),
			"actions": {},
			"probeCertificate": {
				"ok": true,
				"status": "passed",
				"reason": "",
				"authoritative": true,
				"sampleCount": 2
			}
		},
		"routeFallbackCell": old_cells[old_cells.size() - 1]
	}
	var intent := {
		"kind": "job",
		"target": Vector3(8.0, 0.0, 4.0),
		"targetCell": target_cell,
		"allowOutside": true,
		"movingHome": false,
		"action": "",
		"strictArrival": false,
		"arrivalRadius": arrival_radius
	}
	var failed_route := {
		"ok": false,
		"status": "blocked",
		"reason": "endpoint_not_server_walkable",
		"cells": [],
		"waypoints": [],
		"actions": {},
		"targetCell": target_cell,
		"fallbackCell": Vector2i(999999, 999999),
		"snapshotRevision": "",
		"navmeshRoute": {
			"reason": "endpoint_not_server_walkable",
			"startWalkable": { "found": false, "source": "installed_descriptor_endpoint" },
			"targetWalkable": { "found": true, "source": "navigation_server" }
		}
	}
	var planner = FakeRoutePlanner.new(failed_route)
	var world = FakeRouteWorld.new()
	var route: Dictionary = controller.ensure_route(entry, intent, planner, world)
	var preserved_waypoints := (entry.get("pathWaypoints", []) as Array)
	var preserved_cells := (entry.get("routeCells", []) as Array)
	var passed := (
		bool(route.get("ok", false))
		and String(route.get("status", "")) == "routed"
		and String(route.get("reason", "")) == "endpoint_not_server_walkable"
		and bool(entry.get("routeForceReplan", false))
		and String(entry.get("routeStatus", "")) == "moving"
		and String(entry.get("routeReason", "")) == "endpoint_not_server_walkable"
		and preserved_waypoints == old_waypoints
		and preserved_cells == old_cells
		and int(planner.get("calls")) == 1
	)
	return outcome(
		passed,
		"route=%s entryStatus=%s force=%s calls=%d" % [JSON.stringify(route), String(entry.get("routeStatus", "")), str(entry.get("routeForceReplan", false)), int(planner.get("calls"))],
		["active_route_survives_endpoint_transient", "same_target_retry_preserved"],
		{ "route": route, "entryRouteReason": entry.get("routeReason", ""), "lastDebug": entry.get("lastRoutePlanDebug", {}) }
	)

func test_motor_skips_optional_home_threshold_on_endpoint_snap_failure(_mode: String) -> Dictionary:
	var controller = NpcRouteMovementControllerScript.new()
	var body := motor_body("HomeThresholdEndpointNPC")
	body.global_position = Vector3(0.0, 0.0, 0.0)
	var entry := {
		"id": "mira",
		"body": body,
		"routeMovingHome": true,
		"homeRouteIndex": 1,
		"homeRoutePositions": [
			Vector3(0.0, 0.0, 1.35),
			Vector3(0.0, 0.0, 0.0),
			Vector3(0.0, 0.0, -1.35),
			Vector3(1.35, 0.0, -1.35)
		],
		"homeActiveTargetCell": Vector2i(0, -1),
		"routeGoalCell": Vector2i(0, -1),
		"porchCell": Vector2i(0, 0),
		"homeCell": Vector2i(1, -1),
		"interiorMinCell": Vector2i(0, -1),
		"interiorMaxCell": Vector2i(1, -1),
		"porchPosition": Vector3(0.0, 0.0, 0.0),
		"routeCells": [Vector2i(0, -1)],
		"pathWaypoints": [],
		"routeActions": {}
	}
	var original_index := int(entry.get("homeRouteIndex", 0))
	var endpoint_not_skipped := not controller.skip_optional_home_waypoint_if_endpoint_unsnappable(entry, "endpoint_not_server_walkable")
	var static_not_skipped := not controller.skip_optional_home_waypoint_if_static_blocked(entry, "blocked_capsule")
	var oscillation_not_skipped := not controller.skip_optional_home_approach_if_oscillating(entry)
	var index_unchanged := int(entry.get("homeRouteIndex", 0)) == original_index
	var force_replan_unchanged := not bool(entry.get("routeForceReplan", false))
	var passed := endpoint_not_skipped \
		and static_not_skipped \
		and oscillation_not_skipped \
		and index_unchanged \
		and force_replan_unchanged
	body.queue_free()
	return outcome(
		passed,
		"endpointNotSkipped=%s staticNotSkipped=%s oscillationNotSkipped=%s index=%d force=%s" % [
			str(endpoint_not_skipped),
			str(static_not_skipped),
			str(oscillation_not_skipped),
			int(entry.get("homeRouteIndex", 0)),
			str(bool(entry.get("routeForceReplan", false)))
		],
		["home_navigation_no_authored_waypoint_skip", "home_navigation_surfaces_route_failures"],
		{
			"homeRouteIndex": int(entry.get("homeRouteIndex", 0)),
			"routeForceReplan": bool(entry.get("routeForceReplan", false))
		}
	)

func test_motor_spawn_safe_placement(_mode: String) -> Dictionary:
	var service = NpcSafePlacementServiceScript.new()
	service.setup(null, null)
	var body := motor_body("SafePlacementNPC")
	var result: Dictionary = service.place_spawn(body, Vector3(2.0, 1.0, 3.0), CharacterMotorProfileScript.npc_default(), "test_spawn")
	var passed := bool(result.get("ok", false)) and bool(body.get_meta("npc_safe_placement_validated", false)) and body.global_position.distance_to(Vector3(2.0, 1.0, 3.0)) <= 0.001
	body.queue_free()
	return outcome(
		passed,
		"result=%s position=%s" % [JSON.stringify(result), str(result.get("position", Vector3.ZERO))],
		["safe_placement_ok", "safe_placement_sets_meta", "safe_placement_applies_position"],
		{ "result": result }
	)

func test_motor_spawn_rejects_occupied_capsule(_mode: String) -> Dictionary:
	var text := read_text("res://scripts/npc_ai/NpcSafePlacementService.gd")
	var passed := text.find("intersect_shape") >= 0 and text.find("\"occupied_capsule\"") >= 0 and text.find("COLLISION_NPC_SAFE_PLACEMENT_MASK") >= 0
	return outcome(
		passed,
		"intersect=%d occupied=%d mask=%d" % [text.find("intersect_shape"), text.find("\"occupied_capsule\""), text.find("COLLISION_NPC_SAFE_PLACEMENT_MASK")],
		["safe_placement_uses_shape_query", "safe_placement_rejects_occupied_capsule", "safe_placement_uses_central_mask"],
		{}
	)

func test_motor_every_active_actor_physics_tick(_mode: String) -> Dictionary:
	var agent := NpcAgentScript.new() as CharacterBody3D
	agent.name = "PhysicsTickNPC"
	add_child(agent)
	for i in range(5):
		agent.call("_physics_process", 1.0 / 60.0)
	var ticks := int(agent.get("physics_tick_count"))
	var meta_ticks := int(agent.get_meta("npc_physics_ticks", 0))
	agent.queue_free()
	var passed := ticks == 5 and meta_ticks == 5
	return outcome(passed, "ticks=%d meta=%d" % [ticks, meta_ticks], ["agent_physics_process_ticks", "agent_tick_meta"], { "ticks": ticks, "metaTicks": meta_ticks })

func test_navworld_event_block_add_dirty_exact_tiles(_mode: String) -> Dictionary:
	var setup := nav_event_setup()
	var bus = setup.bus
	var service = setup.service
	var cell := Vector3i(17, 1, 2)
	var tile_key := NavigationChangeBusScript.tile_key_for_cell(cell)
	bus.emit_change(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED, "block:add", AABB(Vector3(17.0, 1.0, 2.0) * NpcConstantsScript.CELL_SIZE, Vector3.ONE), [tile_key])
	var events: Array = service.process_change_bus()
	var dirty: Dictionary = service.get("dirty_tiles")
	var passed := events.size() == 1 and dirty.keys() == [tile_key] and int(service.stats().get("topologyRevision", 0)) == 1
	return outcome(passed, "tile=%s events=%s stats=%s" % [tile_key, JSON.stringify(events), JSON.stringify(service.stats())], ["block_add_exact_tile_dirty", "topology_revision_from_event"], { "events": events, "dirty": dirty.keys(), "stats": service.stats() })

func test_navworld_event_block_remove_dirty_exact_tiles(_mode: String) -> Dictionary:
	var setup := nav_event_setup()
	var bus = setup.bus
	var service = setup.service
	var cell := Vector3i(-1, 1, 33)
	var tile_key := NavigationChangeBusScript.tile_key_for_cell(cell)
	bus.emit_change(NpcEnumsScript.CHANGE_KIND_BLOCK_REMOVED, "block:remove", AABB(Vector3(float(cell.x), 0.0, float(cell.z)) * NpcConstantsScript.CELL_SIZE, Vector3.ONE), [tile_key])
	var events: Array = service.process_change_bus()
	var dirty: Dictionary = service.get("dirty_tiles")
	var passed := events.size() == 1 and dirty.keys() == [tile_key] and int(service.stats().get("topologyRevision", 0)) == 1
	return outcome(passed, "tile=%s dirty=%s" % [tile_key, JSON.stringify(dirty.keys())], ["block_remove_exact_tile_dirty"], { "events": events, "dirty": dirty.keys() })

func test_navworld_event_prop_remove_dirty_exact_tiles(_mode: String) -> Dictionary:
	var autonomy := NpcAutonomySystemScript.new()
	autonomy.setup(null, null)
	var prop := Node3D.new()
	prop.name = "BerryProp"
	add_child(prop)
	prop.global_position = Vector3(2.0 * NpcConstantsScript.CELL_SIZE, 0.0, 1.0 * NpcConstantsScript.CELL_SIZE)
	autonomy.notify_prop_removed("berry-1", prop)
	var events: Array = autonomy.process_navigation_changes()
	prop.queue_free()
	autonomy.free()
	var event: Dictionary = events[0] if events.size() > 0 else {}
	var passed := events.size() == 1 and String(event.get("tileKey", "")) == "0,0" and (event.get("changeKinds", []) as Array).has(String(NpcEnumsScript.CHANGE_KIND_PROP_REMOVED))
	return outcome(passed, "events=%s" % JSON.stringify(events), ["prop_remove_exact_tile_dirty", "prop_remove_change_kind"], { "events": events })

func test_navworld_event_terrain_edit_dirty_exact_tiles(_mode: String) -> Dictionary:
	var autonomy := NpcAutonomySystemScript.new()
	autonomy.setup(null, null)
	autonomy.notify_terrain_edited(Vector2i(17, 17), 4.0, 2.65)
	var events: Array = autonomy.process_navigation_changes()
	autonomy.free()
	var event: Dictionary = events[0] if events.size() > 0 else {}
	var passed := events.size() == 1 and String(event.get("tileKey", "")) == "1,1" and (event.get("changeKinds", []) as Array).has(String(NpcEnumsScript.CHANGE_KIND_TERRAIN_EDIT))
	return outcome(passed, "events=%s" % JSON.stringify(events), ["terrain_edit_exact_tile_dirty", "terrain_edit_change_kind"], { "events": events })

func test_navworld_event_chunk_load_unload(_mode: String) -> Dictionary:
	var setup := nav_event_setup()
	var bus = setup.bus
	var service = setup.service
	var key := Vector2i(2, -1)
	var tile_key := NavigationChangeBusScript.tile_key_for_chunk(key)
	bus.emit_change(NpcEnumsScript.CHANGE_KIND_CHUNK_LOADED, "chunk:load", AABB(Vector3.ZERO, Vector3.ONE), [tile_key])
	service.process_change_bus()
	var after_load: Dictionary = service.stats()
	bus.emit_change(NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED, "chunk:unload", AABB(Vector3.ZERO, Vector3.ONE), [tile_key])
	service.process_change_bus()
	var states: Dictionary = service.get("tile_states")
	var passed: bool = int(after_load.get("dirtyTileCount", 0)) == 1 and String(states.get(tile_key, "")) == "unloaded" and not service.is_tile_traversable(tile_key)
	return outcome(passed, "load=%s states=%s" % [JSON.stringify(after_load), JSON.stringify(states)], ["chunk_load_dirty", "chunk_unload_explicit_state", "unloaded_not_traversable"], { "afterLoad": after_load, "tileStates": states })

func test_navworld_tile_source_key_is_tile_stable(_mode: String) -> Dictionary:
	var adapter := GeneratedWorldNavigationAdapterScript.new()
	var tile_key := "4,4"
	var unrelated_tile_key := "9,9"
	var initial_key := adapter.navmesh_tile_source_key_for_tile(tile_key)
	adapter.apply_navigation_events([{
		"tileKey": unrelated_tile_key,
		"changeKinds": [String(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED)],
		"revision": 8
	}])
	var after_unrelated_key := adapter.navmesh_tile_source_key_for_tile(tile_key)
	adapter.apply_navigation_events([{
		"tileKey": tile_key,
		"changeKinds": [String(NpcEnumsScript.CHANGE_KIND_TERRAIN_EDIT)],
		"revision": 11
	}])
	var after_related_key := adapter.navmesh_tile_source_key_for_tile(tile_key)
	var door_adapter := GeneratedWorldNavigationAdapterScript.new()
	var door_initial_key := door_adapter.navmesh_tile_source_key_for_tile(tile_key)
	door_adapter.apply_navigation_events([{
		"tileKey": unrelated_tile_key,
		"changeKinds": [String(NpcEnumsScript.CHANGE_KIND_DOOR_STATE)],
		"revision": 14
	}])
	var after_unrelated_door_key := door_adapter.navmesh_tile_source_key_for_tile(tile_key)
	door_adapter.apply_navigation_events([{
		"tileKey": tile_key,
		"changeKinds": [String(NpcEnumsScript.CHANGE_KIND_DOOR_STATE)],
		"revision": 17
	}])
	var after_related_door_key := door_adapter.navmesh_tile_source_key_for_tile(tile_key)
	var passed := initial_key == after_unrelated_key \
		and after_related_key != initial_key \
		and door_initial_key == after_unrelated_door_key \
		and after_related_door_key != door_initial_key
	return outcome(
		passed,
		"initial=%s unrelated=%s related=%s doorInitial=%s doorUnrelated=%s doorRelated=%s" % [initial_key, after_unrelated_key, after_related_key, door_initial_key, after_unrelated_door_key, after_related_door_key],
		["navmesh_tile_source_key_ignores_unrelated_static_revision", "navmesh_tile_source_key_updates_for_own_tile", "navmesh_tile_source_key_ignores_unrelated_door_revision", "navmesh_tile_source_key_updates_for_own_door"],
		{
			"initialKey": initial_key,
			"afterUnrelatedKey": after_unrelated_key,
			"afterRelatedKey": after_related_key,
			"doorInitialKey": door_initial_key,
			"afterUnrelatedDoorKey": after_unrelated_door_key,
			"afterRelatedDoorKey": after_related_door_key
		}
	)


func test_navworld_incremental_prop_change_keeps_unrelated_tile_cache(_mode: String) -> Dictionary:
	var adapter := GeneratedWorldNavigationAdapterScript.new()
	adapter.cached_revision = "1"
	var changed_tile_key := "4,4"
	var unrelated_tile_key := "9,9"
	var changed_source_key := adapter.navmesh_tile_source_key_for_tile(changed_tile_key)
	var unrelated_source_key := adapter.navmesh_tile_source_key_for_tile(unrelated_tile_key)
	var changed_cache_key := "%s|%s" % [changed_tile_key, changed_source_key]
	var unrelated_cache_key := "%s|%s" % [unrelated_tile_key, unrelated_source_key]
	adapter.navmesh_tile_snapshot_cache[changed_cache_key] = { "tileKey": changed_tile_key }
	adapter.navmesh_tile_snapshot_cache[unrelated_cache_key] = { "tileKey": unrelated_tile_key }
	adapter.navmesh_tile_snapshot_cache_order = [changed_cache_key, unrelated_cache_key]
	adapter.apply_navigation_events([{
		"tileKey": changed_tile_key,
		"changeKinds": [String(NpcEnumsScript.CHANGE_KIND_PROP_CREATED)],
		"objectIds": ["prop:missing"],
		"revision": 8
	}])
	var changed_source_after := adapter.navmesh_tile_source_key_for_tile(changed_tile_key)
	var unrelated_source_after := adapter.navmesh_tile_source_key_for_tile(unrelated_tile_key)
	var passed := not adapter.navmesh_tile_snapshot_cache.has(changed_cache_key) \
		and adapter.navmesh_tile_snapshot_cache.has(unrelated_cache_key) \
		and changed_source_after != changed_source_key \
		and unrelated_source_after == unrelated_source_key
	return outcome(
		passed,
		"changed=%s->%s unrelated=%s->%s cache=%s" % [changed_source_key, changed_source_after, unrelated_source_key, unrelated_source_after, JSON.stringify(adapter.navmesh_tile_snapshot_cache.keys())],
		["incremental_prop_change_evicts_changed_tile", "incremental_prop_change_preserves_unrelated_tile_cache", "unrelated_tile_source_key_stays_stable"],
		{
			"changedSourceBefore": changed_source_key,
			"changedSourceAfter": changed_source_after,
			"unrelatedSourceBefore": unrelated_source_key,
			"unrelatedSourceAfter": unrelated_source_after,
			"cacheKeys": adapter.navmesh_tile_snapshot_cache.keys()
		}
	)


func test_navworld_semantic_change_preserves_geometry_tile_cache(_mode: String) -> Dictionary:
	var adapter := GeneratedWorldNavigationAdapterScript.new()
	adapter.cached_revision = "1"
	var tile_key := "4,4"
	var source_key := adapter.navmesh_tile_source_key_for_tile(tile_key)
	var cache_key := "%s|%s" % [tile_key, source_key]
	adapter.navmesh_tile_snapshot_cache[cache_key] = { "tileKey": tile_key }
	adapter.navmesh_tile_snapshot_cache_order = [cache_key]
	adapter.apply_navigation_events([{
		"tileKey": tile_key,
		"changeKinds": [String(NpcEnumsScript.CHANGE_KIND_SEMANTIC_CHANGED)],
		"revision": 8
	}])
	var source_after := adapter.navmesh_tile_source_key_for_tile(tile_key)
	var passed := source_after == source_key and adapter.navmesh_tile_snapshot_cache.has(cache_key)
	return outcome(
		passed,
		"source=%s->%s cache=%s semanticRevision=%d" % [source_key, source_after, JSON.stringify(adapter.navmesh_tile_snapshot_cache.keys()), adapter.semantic_revision],
		["semantic_change_keeps_geometry_tile_source", "semantic_change_preserves_geometry_tile_cache", "semantic_revision_remains_observable"],
		{
			"sourceBefore": source_key,
			"sourceAfter": source_after,
			"cacheKeys": adapter.navmesh_tile_snapshot_cache.keys(),
			"semanticRevision": adapter.semantic_revision
		}
	)


func test_navworld_no_scene_scan_revision(_mode: String) -> Dictionary:
	var service_text := read_text("res://scripts/npc_ai/navigation/NavigationWorldService.gd")
	var builder_text := read_text("res://scripts/npc_ai/navigation/NavigationTileBuilder.gd")
	var autonomy_text := read_text("res://scripts/npc_ai/NpcAutonomySystem.gd")
	var passed := (
		service_text.find("get_tree(") < 0
		and service_text.find("find_children") < 0
		and service_text.find("hash(") < 0
		and builder_text.find("get_tree(") < 0
		and autonomy_text.find("process_navigation_changes") >= 0
		and autonomy_text.find("NavigationChangeBus") >= 0
	)
	return outcome(passed, "serviceScan=%d find=%d hash=%d" % [service_text.find("get_tree("), service_text.find("find_children"), service_text.find("hash(")], ["new_stack_no_scene_scan_revision", "change_bus_drives_nav_world"], {})

func test_navworld_multisurface_bridge(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now(nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0), { "worldPosition": Vector3(0.0, 0.0, 0.0), "semanticRegionIds": ["terrain"] }),
		nav_surface(Vector3i(0, 2, 0), { "worldPosition": Vector3(0.0, 2.7, 0.0), "semanticRegionIds": ["bridge"] })
	]))
	var spans: Array = tile.spans_for_column(Vector3i(0, 0, 0))
	var passed: bool = spans.size() == 2 and int(tile.to_summary().get("spanCount", 0)) == 2
	return outcome(passed, "summary=%s spans=%d" % [JSON.stringify(tile.to_summary()), spans.size()], ["multiple_vertical_spans_same_xz"], { "tile": tile.to_summary(), "spans": spans.size() })

func test_navworld_tunnel_headroom(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now(nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0), { "headroom": 1.2 }),
		nav_surface(Vector3i(1, 0, 0), { "headroom": 2.2 })
	]))
	var low_span = tile.spans_for_column(Vector3i(0, 0, 0))[0]
	var clear_span = tile.spans_for_column(Vector3i(1, 0, 0))[0]
	var passed := not bool(low_span.get("walkable")) and bool(clear_span.get("walkable"))
	return outcome(passed, "low=%s clear=%s" % [JSON.stringify(low_span.to_summary()), JSON.stringify(clear_span.to_summary())], ["headroom_rejects_low_tunnel", "headroom_accepts_clear_tunnel"], { "low": low_span.to_summary(), "clear": clear_span.to_summary() })

func test_navworld_stacked_surfaces_disconnected(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now(nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0), { "worldPosition": Vector3(0, 0, 0) }),
		nav_surface(Vector3i(0, 3, 0), { "worldPosition": Vector3(0, 4.0, 0) })
	]))
	var spans: Array = tile.spans_for_column(Vector3i(0, 0, 0))
	var edge = tile.edge_between(spans[0].key_string(), spans[1].key_string()) if spans.size() == 2 else null
	var passed: bool = spans.size() == 2 and edge == null
	return outcome(passed, "spans=%d edge=%s" % [spans.size(), str(edge != null)], ["stacked_surfaces_no_magic_vertical_edge"], { "tile": tile.to_summary() })

func test_navworld_profile_clearance_small_large(_mode: String) -> Dictionary:
	var small = TraversalProfileScript.default_adult_npc()
	small.body_radius = 0.22
	small.personal_space_margin = 0.04
	var large = TraversalProfileScript.default_adult_npc()
	large.body_radius = 0.55
	large.personal_space_margin = 0.10
	var snapshot := nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0), { "lateralClearance": 0.40 })
	])
	var small_tile = NavigationWorldServiceScript.new().build_tile_now(snapshot, small)
	var large_tile = NavigationWorldServiceScript.new().build_tile_now(snapshot, large)
	var small_span = small_tile.spans_for_column(Vector3i(0, 0, 0))[0]
	var large_span = large_tile.spans_for_column(Vector3i(0, 0, 0))[0]
	var passed: bool = bool(small_span.get("walkable")) and not bool(large_span.get("walkable"))
	return outcome(passed, "small=%s large=%s" % [JSON.stringify(small_span.to_summary()), JSON.stringify(large_span.to_summary())], ["profile_clearance_small_passes", "profile_clearance_large_rejected"], { "small": small_span.to_summary(), "large": large_span.to_summary() })

func test_navworld_slope_step_drop_edges(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now(nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0), { "worldPosition": Vector3(0.0, 0.0, 0.0) }),
		nav_surface(Vector3i(1, 0, 0), { "worldPosition": Vector3(NpcConstantsScript.CELL_SIZE, 0.75, 0.0) }),
		nav_surface(Vector3i(-1, 0, 0), { "worldPosition": Vector3(-NpcConstantsScript.CELL_SIZE, -0.75, 0.0) })
	]))
	var base = tile.spans_for_column(Vector3i(0, 0, 0))[0]
	var up = tile.spans_for_column(Vector3i(1, 0, 0))[0]
	var down = tile.spans_for_column(Vector3i(-1, 0, 0))[0]
	var up_edge = tile.edge_between(base.key_string(), up.key_string())
	var down_edge = tile.edge_between(base.key_string(), down.key_string())
	var passed: bool = up_edge != null and up_edge.get("traversal_kind") == NpcEnumsScript.TRAVERSAL_KIND_STEP and down_edge != null and down_edge.get("traversal_kind") == NpcEnumsScript.TRAVERSAL_KIND_DROP
	return outcome(passed, "up=%s down=%s" % [JSON.stringify(up_edge.to_summary() if up_edge else {}), JSON.stringify(down_edge.to_summary() if down_edge else {})], ["step_edge_built", "drop_edge_built"], { "up": up_edge.to_summary() if up_edge else {}, "down": down_edge.to_summary() if down_edge else {} })

func test_navworld_corner_cut_rejected(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now(nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0)),
		nav_surface(Vector3i(1, 0, 1)),
		nav_surface(Vector3i(1, 0, 0), { "blocked": true, "blockerKind": "wall" }),
		nav_surface(Vector3i(0, 0, 1), { "blocked": true, "blockerKind": "wall" })
	]))
	var base = tile.spans_for_column(Vector3i(0, 0, 0))[0]
	var diagonal = tile.spans_for_column(Vector3i(1, 0, 1))[0]
	var edge = tile.edge_between(base.key_string(), diagonal.key_string())
	var passed := edge == null
	return outcome(passed, "edge=%s summary=%s" % [str(edge != null), JSON.stringify(tile.to_summary())], ["diagonal_corner_cut_rejected"], { "tile": tile.to_summary() })

func test_navworld_door_portal_edge_registered(_mode: String) -> Dictionary:
	var from_key := "0,0:0,0,0:0"
	var to_key := "0,0:1,0,0:1"
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now(nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0)),
		nav_surface(Vector3i(1, 0, 0))
	], {
		"doorPortals": [{ "id": "door:home-a", "kind": "single", "width": 1.0 }],
		"doorLinks": [{ "from": from_key, "to": to_key, "portalId": "door:home-a", "cost": 2.0 }]
	}))
	var edge = tile.edge_between(from_key, to_key)
	var passed: bool = edge != null and edge.get("traversal_kind") == NpcEnumsScript.TRAVERSAL_KIND_DOOR and tile.door_portals.has("door:home-a")
	return outcome(passed, "edge=%s portals=%s" % [JSON.stringify(edge.to_summary() if edge else {}), JSON.stringify(tile.door_portals.keys())], ["door_portal_registered", "door_edge_explicit"], { "edge": edge.to_summary() if edge else {}, "portals": tile.door_portals.keys() })

func test_navworld_door_axis_uses_wall_blockers(_mode: String) -> Dictionary:
	var adapter := GeneratedWorldNavigationAdapterScript.new()
	var door := Node3D.new()
	var z_wall_a := Node3D.new()
	var z_wall_b := Node3D.new()
	var x_wall_a := Node3D.new()
	var x_wall_b := Node3D.new()
	var door_cell := Vector2i(10, 10)
	var z_wall_snapshot := {
		"doors": { door_cell: door },
		"blocked": {
			door_cell + Vector2i(0, -1): z_wall_a,
			door_cell + Vector2i(0, 1): z_wall_b
		}
	}
	var x_wall_snapshot := {
		"doors": { door_cell: door },
		"blocked": {
			door_cell + Vector2i(-1, 0): x_wall_a,
			door_cell + Vector2i(1, 0): x_wall_b
		}
	}
	var z_wall_axis := adapter._door_crossing_axis(door, z_wall_snapshot, door_cell)
	var x_wall_axis := adapter._door_crossing_axis(door, x_wall_snapshot, door_cell)
	door.free()
	z_wall_a.free()
	z_wall_b.free()
	x_wall_a.free()
	x_wall_b.free()
	var passed := z_wall_axis == "x" and x_wall_axis == "z"
	return outcome(passed, "zWall=%s xWall=%s" % [z_wall_axis, x_wall_axis], ["north_south_wall_crosses_x", "east_west_wall_crosses_z"], { "zWallAxis": z_wall_axis, "xWallAxis": x_wall_axis })

func test_navworld_semantic_home_interior(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var semantic = service.get("semantic_service")
	semantic.register_home("home-a", AABB(Vector3.ZERO, Vector3(4, 3, 4)), { "bed": Vector3(1, 0, 1) }, { "portalId": "door:home-a" })
	var homes: Array = semantic.regions_for_kind(&"home_interior")
	var at_point: Array = semantic.regions_at_position(Vector3(1, 1, 1), &"home_interior")
	var passed := homes.size() == 1 and at_point.size() == 1 and bool(homes[0].get("metadata", {}).get("inside", false))
	return outcome(passed, "homes=%s" % JSON.stringify(homes), ["home_interior_semantic_region", "home_inside_metadata", "home_entrance_metadata"], { "homes": homes, "atPoint": at_point })

func test_navworld_semantic_guard_post(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var semantic = service.get("semantic_service")
	semantic.register_guard_post("north", AABB(Vector3(8, 0, 0), Vector3(2, 3, 2)), { "patrol": "north-road" })
	var guards: Array = semantic.regions_for_kind(&"guard_post")
	var passed := guards.size() == 1 and String(guards[0].get("id", "")) == "guard:north"
	return outcome(passed, "guards=%s" % JSON.stringify(guards), ["guard_post_semantic_region"], { "guards": guards })

func test_navworld_semantic_road_and_work_anchor(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var semantic = service.get("semantic_service")
	semantic.register_road("main", AABB(Vector3.ZERO, Vector3(10, 1, 2)), { "surface": "cobblestonePath" })
	semantic.register_work_anchor("woodpile", AABB(Vector3(4, 0, 4), Vector3(2, 2, 2)), { "job": "wood" })
	var roads: Array = semantic.regions_for_kind(&"road")
	var work: Array = semantic.regions_for_kind(&"work_anchor")
	var passed := roads.size() == 1 and work.size() == 1 and int(semantic.stats().get("regionCount", 0)) == 2
	return outcome(passed, "semantic=%s" % JSON.stringify(semantic.stats()), ["road_semantic_region", "work_anchor_semantic_region"], { "roads": roads, "work": work, "stats": semantic.stats() })

func test_navworld_unloaded_tile_not_traversable(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now({ "tileKey": "3,3", "unloaded": true, "surfaces": [] })
	var passed := bool(tile.get("unloaded")) and not service.is_tile_traversable("3,3")
	return outcome(passed, "tile=%s traversable=%s" % [JSON.stringify(tile.to_summary()), str(service.is_tile_traversable("3,3"))], ["unloaded_tile_explicit", "unloaded_tile_not_traversable"], { "tile": tile.to_summary() })

func test_navworld_build_budget_yields_and_resumes(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	for i in range(3):
		service.request_tile(nav_snapshot("%d,0" % i, [nav_surface(Vector3i(i * 16, 0, 0))]), 1)
	var first: Array = service.build_next_tiles(1, 4000)
	var after_first := service.stats()
	var second: Array = service.build_next_tiles(1, 4000)
	var third: Array = service.build_next_tiles(1, 4000)
	var after_all := service.stats()
	var passed: bool = first.size() == 1 and second.size() == 1 and third.size() == 1 and int(after_first.get("buildQueue", {}).get("pending", 0)) == 2 and int(after_all.get("buildQueue", {}).get("pending", 0)) == 0 and int(after_all.get("buildQueue", {}).get("yieldedJobs", 0)) >= 1
	return outcome(passed, "first=%s afterAll=%s" % [JSON.stringify(after_first), JSON.stringify(after_all)], ["build_budget_yields", "build_budget_resumes", "build_queue_drains"], { "afterFirst": after_first, "afterAll": after_all })

func test_navworld_deterministic_tile_output(_mode: String) -> Dictionary:
	var snapshot := nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0), { "semanticRegionIds": ["road"] }),
		nav_surface(Vector3i(1, 0, 0), { "semanticRegionIds": ["road"] }),
		nav_surface(Vector3i(1, 1, 1), { "worldPosition": Vector3(NpcConstantsScript.CELL_SIZE, 0.75, NpcConstantsScript.CELL_SIZE), "semanticRegionIds": ["bridge"] })
	], {
		"semanticRegions": [{ "id": "road:main", "kind": "road" }]
	})
	var first = NavigationWorldServiceScript.new().build_tile_now(snapshot)
	var second = NavigationWorldServiceScript.new().build_tile_now(snapshot)
	var passed: bool = first.stable_signature() == second.stable_signature()
	return outcome(passed, "first=%s second=%s" % [first.stable_signature(), second.stable_signature()], ["deterministic_tile_signature"], { "first": first.stable_signature(), "second": second.stable_signature() })

func test_navmesh_backend_default_navmesh(_mode: String) -> Dictionary:
	var config = NavigationBackendConfigScript.default_config()
	var explicit_empty = NavigationBackendConfigScript.from_value("", "test")
	var autonomy := NpcAutonomySystemScript.new()
	autonomy.setup(null, null)
	var summary: Dictionary = autonomy.navigation_backend_summary()
	autonomy.free()
	var passed: bool = String(config.backend) == NavigationBackendConfigScript.BACKEND_NAVMESH and String(explicit_empty.backend) == NavigationBackendConfigScript.BACKEND_NAVMESH and String(summary.get("backend", "")) == NavigationBackendConfigScript.BACKEND_NAVMESH and bool(summary.get("navmeshEnabled", false))
	return outcome(passed, "config=%s summary=%s" % [JSON.stringify(config.to_summary()), JSON.stringify(summary)], ["nav_backend_default_navmesh", "autonomy_reports_navmesh_backend"], { "config": config.to_summary(), "autonomy": summary })

func test_navmesh_backend_explicit_navmesh(_mode: String) -> Dictionary:
	var config = NavigationBackendConfigScript.from_value("navmesh", "test")
	var service = NavmeshWorldServiceScript.new()
	service.setup(config)
	var stats: Dictionary = service.stats()
	service.clear()
	var passed: bool = config.use_navmesh() and String(stats.get("backend", "")) == NavigationBackendConfigScript.BACKEND_NAVMESH and bool(stats.get("navmeshEnabled", false)) and bool(stats.get("hasNavigationMap", false))
	return outcome(passed, "stats=%s" % JSON.stringify(stats), ["nav_backend_explicit_navmesh", "navmesh_service_owns_map"], { "stats": stats })

func test_navmesh_backend_custom_alias_navmesh(_mode: String) -> Dictionary:
	var previous_backend := OS.get_environment(NavigationBackendConfigScript.ENV_BACKEND)
	var explicit_custom = NavigationBackendConfigScript.from_value("custom", "test")
	OS.set_environment(NavigationBackendConfigScript.ENV_BACKEND, "custom")
	var env_custom = NavigationBackendConfigScript.from_environment()
	OS.set_environment(NavigationBackendConfigScript.ENV_BACKEND, previous_backend)
	var passed: bool = String(explicit_custom.backend) == NavigationBackendConfigScript.BACKEND_NAVMESH and String(env_custom.backend) == NavigationBackendConfigScript.BACKEND_NAVMESH and explicit_custom.use_navmesh() and env_custom.use_navmesh()
	return outcome(passed, "explicit=%s env=%s" % [JSON.stringify(explicit_custom.to_summary()), JSON.stringify(env_custom.to_summary())], ["legacy_custom_backend_aliases_navmesh", "navmesh_backend_cannot_be_disabled_by_env"], { "explicit": explicit_custom.to_summary(), "environment": env_custom.to_summary() })

func test_navmesh_descriptor_deterministic_signature(_mode: String) -> Dictionary:
	var first = NavigationBakeDescriptorScript.create("region:town:0", "0,0", AABB(Vector3.ZERO, Vector3(4, 2, 4)))
	first.metadata = { "seed": seed, "source": "test" }
	first.add_walkable_surface("surface:b", Vector3(2, 0, 0), Vector3.ONE, { "semantic": ["road"] })
	first.add_walkable_surface("surface:a", Vector3.ZERO, Vector3.ONE, { "semantic": ["home"] })
	first.add_semantic_anchor("anchor:work", "work_anchor", Vector3(1, 0, 1))
	var second = NavigationBakeDescriptorScript.create("region:town:0", "0,0", AABB(Vector3.ZERO, Vector3(4, 2, 4)))
	second.metadata = { "source": "test", "seed": seed }
	second.add_semantic_anchor("anchor:work", "work_anchor", Vector3(1, 0, 1))
	second.add_walkable_surface("surface:a", Vector3.ZERO, Vector3.ONE, { "semantic": ["home"] })
	second.add_walkable_surface("surface:b", Vector3(2, 0, 0), Vector3.ONE, { "semantic": ["road"] })
	var passed: bool = first.stable_signature() == second.stable_signature()
	return outcome(passed, "signature=%s" % first.stable_signature(), ["navmesh_descriptor_signature_sorts_ids", "navmesh_descriptor_signature_sorts_metadata"], { "signature": first.stable_signature(), "summary": first.to_summary() })

func test_navmesh_tile_snapshot_descriptor_deterministic(_mode: String) -> Dictionary:
	var from_key := "surface:2,-1:32,0,-16:0"
	var to_key := "surface:2,-1:33,0,-16:1"
	var snapshot := nav_snapshot("2,-1", [
		nav_surface(Vector3i(32, 0, -16), { "semanticRegionIds": ["road:main"] }),
		nav_surface(Vector3i(33, 0, -16), { "semanticRegionIds": ["road:main"] }),
		nav_surface(Vector3i(34, 0, -16), { "blocked": true, "blockerKind": "wall" })
	], {
		"semanticRegions": [{ "id": "road:main", "kind": "road", "position": Vector3(43.875, 0.0, -21.6) }],
		"doorPortals": [{ "id": "door:test", "entrance": Vector3(43.2, 0.0, -21.6), "exit": Vector3(44.55, 0.0, -21.6) }],
		"doorLinks": [{ "from": from_key, "to": to_key, "portalId": "door:test", "cost": 1.25 }]
	})
	var first = NavigationBakeDescriptorScript.from_tile_snapshot(snapshot)
	var second = NavigationBakeDescriptorScript.from_tile_snapshot(snapshot)
	var summary: Dictionary = first.to_summary()
	var passed: bool = first.stable_signature() == second.stable_signature() and String(first.get("region_id")) == "region:chunk:2,-1" and summary.get("walkableSurfaces", []).size() == 2 and summary.get("blockers", []).size() == 1 and summary.get("doorPortals", []).size() == 1 and summary.get("doorLinks", []).size() == 1
	return outcome(passed, "signature=%s summary=%s" % [first.stable_signature(), JSON.stringify(summary)], ["tile_snapshot_descriptor_deterministic", "tile_snapshot_keeps_blockers", "tile_snapshot_keeps_door_portals", "tile_snapshot_keeps_door_links"], { "summary": summary })


func test_navmesh_adjacent_tile_collision_clearance(_mode: String) -> Dictionary:
	var adapter := GeneratedWorldNavigationAdapterScript.new()
	var divider := {
		"minX": 438.20,
		"maxX": 441.34,
		"minZ": 538.89,
		"maxZ": 539.15,
		"inflation": 0.52
	}
	var source_tile := bool(adapter.call("_collision_record_overlaps_tile", divider, "20,24"))
	var clearance_tile := bool(adapter.call("_collision_record_overlaps_tile", divider, "20,25"))
	var unrelated_tile := bool(adapter.call("_collision_record_overlaps_tile", divider, "20,26"))
	var passed := source_tile and clearance_tile and not unrelated_tile
	return outcome(
		passed,
		"source=%s clearance=%s unrelated=%s" % [str(source_tile), str(clearance_tile), str(unrelated_tile)],
		["collision_clearance_publishes_across_cell_center_tile_boundary", "adjacent_tile_support_mesh_receives_neighboring_static_collision"],
		{ "sourceTile": source_tile, "clearanceTile": clearance_tile, "unrelatedTile": unrelated_tile }
	)


func test_navmesh_source_door_portal_physical_clearance(_mode: String) -> Dictionary:
	var adapter := GeneratedWorldNavigationAdapterScript.new()
	var support := {
		"id": "support:door-portal",
		"cell": Vector3i.ZERO,
		"worldPosition": Vector3.ZERO,
		"floorNormal": Vector3.UP,
		"headroom": 3.0,
		"lateralClearance": 1.0,
		"sourcePartId": "floor:door-portal",
		"sourceCollisionPartId": "floor:door-portal",
		"polygon": [Vector3(-1.5, 0.0, -1.0), Vector3(-1.5, 0.0, 1.0), Vector3(1.5, 0.0, 1.0), Vector3(1.5, 0.0, -1.0)]
	}
	var supports: Array[Dictionary] = [support]
	adapter.cached_building_supports = supports
	adapter.cached_building_doors = [{
		"id": "door:physical-clearance",
		"sourcePortalReady": true,
		"interior": Vector3(-0.5, 0.04, 0.0),
		"exterior": Vector3(0.5, 0.04, 0.0)
	}]
	var near_jamb := {
		"id": "collision:door:jamb",
		"sourcePartId": "wall:door:jamb",
		"minX": -0.10,
		"maxX": 0.10,
		"minY": 0.0,
		"maxY": 2.4,
		"minZ": 0.47,
		"maxZ": 0.70,
		"inflation": 0.52
	}
	var snapshot := { "staticCollisionByCell": {}, "staticCollisionBroad": [near_jamb] }
	var points: Array[Vector3] = [Vector3(-1.2, 0.04, 0.0), Vector3(-0.5, 0.04, 0.0), Vector3(0.5, 0.04, 0.0), Vector3(1.2, 0.04, 0.0)]
	var strict: Dictionary = adapter.validate_waypoint_route({}, snapshot, points, {}, true)
	var actions := {
		"door:physical-clearance": {
			"kind": "door",
			"navLink": true,
			"portalId": "door:physical-clearance",
			"entryPosition": points[1],
			"exitPosition": points[2]
		}
	}
	var portal_checked: Dictionary = adapter.validate_waypoint_route({}, snapshot, points, {}, true, actions)
	var passed := not bool(strict.get("ok", true)) and String(strict.get("reason", "")) == "layered_static_collision" and bool(portal_checked.get("ok", false))
	return outcome(passed, "strict=%s portalChecked=%s" % [JSON.stringify(strict), JSON.stringify(portal_checked)], ["ordinary_routes_keep_social_collision_margin", "published_source_door_segments_use_capsule_clearance", "door_portal_exception_remains_action_scoped"], { "strict": strict, "portalChecked": portal_checked })

func test_navmesh_building_topology_tile_closure(_mode: String) -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	adapter.cached_revision = "test"
	var supports: Array[Dictionary] = [
		{ "id": "support:west", "tileKeys": ["-1,0", "0,0"] },
		{ "id": "support:east", "tileKeys": ["1,0"] }
	]
	var doors: Array[Dictionary] = [{ "id": "door:boundary", "tileKeys": ["0,0", "0,1"] }]
	var vertical_links: Array[Dictionary] = [{
		"id": "link:stairs",
		"ownerTileKey": "0,0",
		"startTileKey": "0,0",
		"endTileKey": "1,0",
		"tileKeys": ["0,0", "1,0"]
	}]
	var support_seam_links: Array[Dictionary] = [{
		"id": "link:seam",
		"ownerTileKey": "0,1",
		"startTileKey": "0,1",
		"endTileKey": "0,2",
		"tileKeys": ["0,1", "0,2"]
	}]
	adapter.cached_building_supports = supports
	adapter.cached_building_doors = doors
	adapter.cached_building_vertical_links = vertical_links
	adapter.cached_building_support_seam_links = support_seam_links
	var interior_passage_links: Array[Dictionary] = []
	adapter.cached_building_interior_passage_links = interior_passage_links
	var keys: Array = adapter.building_navigation_topology_tile_keys()
	var expected := ["-1,0", "0,0", "0,1", "0,2", "1,0"]
	var passed := keys == expected
	return outcome(passed, "keys=%s" % JSON.stringify(keys), ["building_topology_prebake_covers_supports_doors_and_link_endpoints", "building_topology_tile_closure_is_sorted"], { "keys": keys, "expected": expected })

func test_navmesh_invalidated_static_snapshot_rebuilds(_mode: String) -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	adapter.cached_revision = ""
	adapter.cached_blocked[Vector2i.ZERO] = true
	adapter.building_navigation_topology_tile_keys()
	var passed: bool = adapter.nav_static_rebuild_count == 1 and adapter.cached_blocked.is_empty()
	return outcome(passed, "rebuilds=%d blocked=%s" % [adapter.nav_static_rebuild_count, JSON.stringify(adapter.cached_blocked)], ["invalidated_static_snapshot_rebuilds_despite_previous_cached_cells", "topology_prebake_never_reads_pre_manifest_static_cache"], { "rebuilds": adapter.nav_static_rebuild_count, "blocked": adapter.cached_blocked })

func test_navmesh_cross_tile_link_survives_endpoint_rebuild(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	var left = NavigationBakeDescriptorScript.create("region:chunk:0,0", "0,0", AABB(Vector3(-1.0, -0.1, -1.0), Vector3(2.0, 0.2, 2.0)))
	left.add_walkable_surface("surface:left", Vector3.ZERO, Vector3(1.0, 0.05, 1.0))
	left.add_navigation_link("link:left-to-right", Vector3(0.45, 0.0, 0.0), Vector3(1.55, 0.0, 0.0), {
		"startTileKey": "0,0",
		"endTileKey": "1,0"
	})
	var right = NavigationBakeDescriptorScript.create("region:chunk:1,0", "1,0", AABB(Vector3(1.0, -0.1, -1.0), Vector3(2.0, 0.2, 2.0)))
	right.add_walkable_surface("surface:right", Vector3(1.6, 0.0, 0.0), Vector3(1.0, 0.05, 1.0))
	service.register_chunk_descriptor(left)
	service.register_chunk_descriptor(right)
	for _pass in range(4):
		service.process_dirty_regions(1, 100000)
	var before_rebuild: Dictionary = service.stats()
	service.apply_navigation_events([{ "tileKey": "1,0", "changeKinds": ["block_removed"], "revision": 7 }])
	var rebuilt: Array = service.process_dirty_regions(1, 100000)
	var after_rebuild: Dictionary = service.stats()
	var snapshot: Dictionary = service.debug_snapshot()
	service.apply_navigation_events([{ "tileKey": "1,0", "changeKinds": ["chunk_unloaded"], "revision": 8 }])
	var after_unload: Dictionary = service.stats()
	service.clear()
	var installed_links: Array = snapshot.get("navigationLinks", []) as Array
	var passed: bool = int(before_rebuild.get("pendingNavigationLinkCount", -1)) == 0 \
		and int(before_rebuild.get("installedNavigationLinkCount", 0)) == 1 \
		and not rebuilt.is_empty() \
		and int(after_rebuild.get("pendingNavigationLinkCount", -1)) == 0 \
		and int(after_rebuild.get("installedNavigationLinkCount", 0)) == 1 \
		and installed_links.size() == 1 \
		and int(after_unload.get("pendingNavigationLinkCount", 0)) == 1 \
		and int(after_unload.get("installedNavigationLinkCount", -1)) == 0
	return outcome(passed, "before=%s rebuilt=%s after=%s unload=%s" % [JSON.stringify(before_rebuild), JSON.stringify(rebuilt), JSON.stringify(after_rebuild), JSON.stringify(after_unload)], ["cross_tile_link_survives_atomic_endpoint_rebuild", "endpoint_unload_defers_cross_tile_link"], { "before": before_rebuild, "rebuilt": rebuilt, "after": after_rebuild, "unload": after_unload, "snapshot": snapshot })

func test_navmesh_descriptor_keeps_door_links(_mode: String) -> Dictionary:
	var first = NavigationBakeDescriptorScript.create("region:chunk:links", "links", AABB(Vector3.ZERO, Vector3(6, 2, 6)))
	first.add_walkable_surface("surface:left", Vector3(0.0, 0.0, 0.0))
	first.add_walkable_surface("surface:right", Vector3(0.0, 0.0, 2.7))
	first.add_door_portal("door:links", Vector3(0.0, 0.0, 0.65), Vector3(0.0, 0.0, 2.05), { "state": "closed", "openable": true })
	first.add_door_link("surface:left", "surface:right", "door:links", { "cost": 2.0, "actionId": "open" })
	var second = NavigationBakeDescriptorScript.create("region:chunk:links", "links", AABB(Vector3.ZERO, Vector3(6, 2, 6)))
	second.add_door_link("surface:left", "surface:right", "door:links", { "actionId": "open", "cost": 2.0 })
	second.add_door_portal("door:links", Vector3(0.0, 0.0, 0.65), Vector3(0.0, 0.0, 2.05), { "openable": true, "state": "closed" })
	second.add_walkable_surface("surface:right", Vector3(0.0, 0.0, 2.7))
	second.add_walkable_surface("surface:left", Vector3(0.0, 0.0, 0.0))
	var summary: Dictionary = first.to_summary()
	var link: Dictionary = summary.get("doorLinks", [])[0] if summary.get("doorLinks", []).size() > 0 else {}
	var passed: bool = first.stable_signature() == second.stable_signature() and summary.get("doorLinks", []).size() == 1 and String(link.get("portalId", "")) == "door:links" and String(link.get("actionId", "")) == "open"
	return outcome(passed, "summary=%s" % JSON.stringify(summary), ["navmesh_descriptor_keeps_door_links", "door_link_signature_deterministic"], { "summary": summary })

func test_navmesh_service_installs_navigation_region(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	var descriptor = navmesh_descriptor("region:chunk:install", "install")
	var registered: Dictionary = service.register_chunk_descriptor(descriptor)
	var stats: Dictionary = service.stats()
	var snapshot: Dictionary = service.debug_snapshot()
	service.clear()
	var passed: bool = String(registered.get("status", "")) == "installed" and bool(registered.get("installed", false)) and int(stats.get("installedRegionCount", 0)) == 1 and int(stats.get("installedSurfaceCount", 0)) == 2 and bool(snapshot.get("hasNavigationMap", false))
	return outcome(passed, "registered=%s stats=%s" % [JSON.stringify(registered), JSON.stringify(stats)], ["navmesh_descriptor_installs_region_rid", "navmesh_install_counts_surfaces", "navmesh_debug_reports_map"], { "registered": registered, "stats": stats, "snapshot": snapshot })

func test_navmesh_conforming_support_cells(_mode: String) -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	var support := {
		"id": "support:conforming-test",
		"cell": Vector3i.ZERO,
		"worldPosition": Vector3(0.16, 0.04, 0.16),
		"floorNormal": Vector3.UP,
		"headroom": 3.0,
		"lateralClearance": 1.0,
		"traversalTags": ["building", "support"],
		"sourcePartId": "floor:conforming-test",
		"sourceCollisionPartId": "floor:conforming-test"
	}
	var cells := {
		Vector2i(0, 0): true,
		Vector2i(1, 0): true,
		Vector2i(2, 0): true,
		Vector2i(2, 1): true,
		Vector2i(2, 2): true
	}
	var surface_value = adapter.call("_merged_building_support_navmesh_surfaces", support, cells, 1)
	var surfaces: Array = surface_value if surface_value is Array else []
	var every_surface_is_row_segment := true
	for surface_value_item in surfaces:
		if not (surface_value_item is Dictionary):
			every_surface_is_row_segment = false
			break
		var polygon: Array = (surface_value_item as Dictionary).get("polygon", []) if (surface_value_item as Dictionary).get("polygon", []) is Array else []
		if polygon.size() != 4:
			every_surface_is_row_segment = false
			break
		var minimum := Vector2(INF, INF)
		var maximum := Vector2(-INF, -INF)
		for point_value in polygon:
			if not (point_value is Vector3):
				every_surface_is_row_segment = false
				break
			var point: Vector3 = point_value
			minimum.x = minf(minimum.x, point.x)
			minimum.y = minf(minimum.y, point.z)
			maximum.x = maxf(maximum.x, point.x)
			maximum.y = maxf(maximum.y, point.z)
		if not every_surface_is_row_segment:
			break
		if maximum.x - minimum.x < 0.3199 or absf((maximum.y - minimum.y) - 0.32) > 0.0001:
			every_surface_is_row_segment = false
			break
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	var registered := service.register_tile_snapshot(nav_snapshot("conforming-support", surfaces))
	var stats: Dictionary = service.stats()
	service.clear()
	var passed: bool = bool(registered.get("installed", false)) \
		and surfaces.size() == 4 \
		and every_surface_is_row_segment \
		and int(stats.get("installedSurfaceCount", 0)) == surfaces.size()
	return outcome(passed, "registered=%s surfaces=%d rowSegments=%s stats=%s" % [JSON.stringify(registered), surfaces.size(), str(every_surface_is_row_segment), JSON.stringify(stats)], ["building_support_cells_share_complete_navmesh_edges", "support_rows_split_at_neighboring_boundaries", "support_navmesh_surface_count_stays_compact"], { "registered": registered, "surfaceCount": surfaces.size(), "rowSegments": every_surface_is_row_segment, "stats": stats })


func test_navmesh_unified_tile_support_cells(_mode: String) -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	var first_support := {
		"id": "support:unified:first",
		"cell": Vector3i.ZERO,
		"worldPosition": Vector3(0.32, 0.0, 0.16),
		"floorNormal": Vector3.UP,
		"headroom": 3.0,
		"lateralClearance": 1.0,
		"traversalTags": ["building", "support"],
		"sourcePartId": "floor:unified:first",
		"sourceCollisionPartId": "floor:unified:first",
		"tileKeys": ["0,0"],
		"polygon": [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 0.32), Vector3(0.64, 0.0, 0.32), Vector3(0.64, 0.0, 0.0)]
	}
	var second_support := {
		"id": "support:unified:second",
		"cell": Vector3i.ZERO,
		"worldPosition": Vector3(0.96, 0.0, 0.16),
		"floorNormal": Vector3.UP,
		"headroom": 3.0,
		"lateralClearance": 1.0,
		"traversalTags": ["building", "support"],
		"sourcePartId": "floor:unified:second",
		"sourceCollisionPartId": "floor:unified:second",
		"tileKeys": ["0,0"],
		"polygon": [Vector3(0.64, 0.0, 0.0), Vector3(0.64, 0.0, 0.32), Vector3(1.28, 0.0, 0.32), Vector3(1.28, 0.0, 0.0)]
	}
	var supports: Array[Dictionary] = [first_support, second_support]
	adapter.cached_building_supports = supports
	adapter.cached_building_supports_by_tile = { "0,0": supports }
	var surface_value = adapter.call("_navmesh_surfaces_from_building_tile", { "staticCollisionByCell": {} }, "0,0", 1)
	var surfaces: Array = surface_value if surface_value is Array else []
	var polygon: Array = surfaces[0].get("polygon", []) if surfaces.size() == 1 and surfaces[0] is Dictionary else []
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	var valid_polygon := polygon.size() == 4
	for point_value in polygon:
		if not (point_value is Vector3):
			valid_polygon = false
			break
		var point: Vector3 = point_value
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.z)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.z)
	var passed := valid_polygon \
		and surfaces.size() == 1 \
		and absf(minimum.x) <= 0.0001 \
		and absf(maximum.x - 1.28) <= 0.0001 \
		and absf(minimum.y) <= 0.0001 \
		and absf(maximum.y - 0.32) <= 0.0001
	return outcome(passed, "surfaces=%s bounds=(%s,%s)" % [JSON.stringify(surfaces), minimum, maximum], ["adjacent_building_supports_share_one_tile_walkability_mesh", "unified_support_mesh_has_no_part_boundary_gap", "unified_support_mesh_stays_compact"], { "surfaces": surfaces, "minimum": minimum, "maximum": maximum })


func test_navmesh_discards_unresolved_building_link_endpoints(_mode: String) -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	var support := {
		"id": "support:unresolved-link",
		"cell": Vector3i.ZERO,
		"worldPosition": Vector3(0.64, 0.0, 0.16),
		"floorNormal": Vector3.UP,
		"headroom": 3.0,
		"lateralClearance": 1.0,
		"traversalTags": ["building", "support"],
		"sourcePartId": "floor:unresolved-link",
		"sourceCollisionPartId": "floor:unresolved-link",
		"tileKeys": ["0,0"],
		"polygon": [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 0.32), Vector3(1.28, 0.0, 0.32), Vector3(1.28, 0.0, 0.0)]
	}
	var supports: Array[Dictionary] = [support]
	adapter.cached_building_supports = supports
	adapter.cached_building_supports_by_tile = { "0,0": supports }
	var links: Array[Dictionary] = [{
		"id": "link:unresolved-endpoint",
		"kind": "support_seam",
		"supportId": "support:unresolved-link",
		"start": Vector3(0.32, 0.0, 0.16),
		"end": Vector3(22.0, 0.0, 0.16),
		"startTileKey": "0,0",
		"endTileKey": "1,0"
	}]
	var resolved_value = adapter.call("_resolve_building_navigation_link_endpoints", { "staticCollisionByCell": {} }, links)
	var resolved_links: Array = resolved_value if resolved_value is Array else []
	var passed := resolved_links.is_empty()
	return outcome(passed, "resolvedLinks=%s" % JSON.stringify(resolved_links), ["building_link_requires_two_collision_screened_endpoints", "unresolved_cross_tile_link_is_not_published"], { "resolvedLinks": resolved_links })


func test_navmesh_chunk_unload_cleans_region(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	service.register_tile_snapshot(nav_snapshot("4,5", [
		nav_surface(Vector3i(64, 0, 80)),
		nav_surface(Vector3i(65, 0, 80))
	]))
	var after_register: Dictionary = service.stats()
	var events := [{ "tileKey": "4,5", "changeKinds": ["chunk_unloaded"] }]
	var responses: Array = service.apply_navigation_events(events)
	var after_unload: Dictionary = service.stats()
	service.clear()
	var passed: bool = int(after_register.get("installedRegionCount", 0)) == 1 and int(after_unload.get("installedRegionCount", -1)) == 0 and int(after_unload.get("regionCount", -1)) == 0 and not responses.is_empty() and String((responses[0] as Dictionary).get("status", "")) == "unregistered"
	return outcome(passed, "afterRegister=%s afterUnload=%s responses=%s" % [JSON.stringify(after_register), JSON.stringify(after_unload), JSON.stringify(responses)], ["chunk_unload_unregisters_navmesh_region", "chunk_unload_releases_region_rid"], { "afterRegister": after_register, "afterUnload": after_unload, "responses": responses })

func test_navmesh_door_portal_installs_nav_link(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	var descriptor = navmesh_door_descriptor("region:chunk:door-link", "door-link", "door:phase3")
	var registered: Dictionary = service.register_chunk_descriptor(descriptor)
	var stats: Dictionary = service.stats()
	var snapshot: Dictionary = service.debug_snapshot()
	service.clear()
	var links: Array = (snapshot.get("doorLinks", {}) as Dictionary).get("door:phase3", [])
	var link: Dictionary = links[0] if not links.is_empty() and links[0] is Dictionary else {}
	var passed: bool = String(registered.get("status", "")) == "installed" and int(stats.get("installedDoorLinkCount", 0)) == 1 and not links.is_empty() and bool(link.get("enabled", false)) and String(link.get("state", "")) == "closed"
	return outcome(passed, "registered=%s stats=%s links=%s" % [JSON.stringify(registered), JSON.stringify(stats), JSON.stringify(links)], ["door_portal_installs_nav_link_rid", "closed_openable_door_link_enabled"], { "registered": registered, "stats": stats, "links": links })

func test_navmesh_cross_region_door_link_lifecycle(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	var interior = NavigationBakeDescriptorScript.create("region:door:interior", "door-interior", AABB(Vector3(-1.0, -0.1, -1.0), Vector3(2.0, 0.2, 1.2)))
	interior.add_walkable_surface("surface:door:interior", Vector3(0.0, 0.0, -0.45), Vector3(1.35, 0.05, 0.9))
	interior.add_door_portal("door:cross-region", Vector3(0.0, 0.0, -0.12), Vector3(0.0, 0.0, 0.12), {"state": "closed", "openable": true})
	interior.add_door_link("surface:door:interior", "surface:door:exterior", "door:cross-region", {"id": "door-link:cross-region", "sourceDoor": true, "startRegionId": "region:door:interior", "endRegionId": "region:door:exterior"})
	var exterior = NavigationBakeDescriptorScript.create("region:door:exterior", "door-exterior", AABB(Vector3(-1.0, -0.1, 0.0), Vector3(2.0, 0.2, 1.2)))
	exterior.add_walkable_surface("surface:door:exterior", Vector3(0.0, 0.0, 0.45), Vector3(1.35, 0.05, 0.9))
	service.register_chunk_descriptor(interior)
	var pending_before_endpoint: Dictionary = service.stats()
	service.register_chunk_descriptor(exterior)
	for _pass in range(4):
		service.process_dirty_regions(1, 100000)
	service.sync_navigation_map_if_dirty()
	var installed: Dictionary = service.stats()
	var installed_snapshot: Dictionary = service.debug_snapshot()
	service.unregister_chunk("region:door:exterior")
	var deferred: Dictionary = service.stats()
	service.register_chunk_descriptor(exterior)
	for _pass in range(4):
		service.process_dirty_regions(1, 100000)
	service.sync_navigation_map_if_dirty()
	var recovered: Dictionary = service.stats()
	service.clear()
	var installed_links: Array = (installed_snapshot.get("doorLinks", {}) as Dictionary).get("door:cross-region", []) as Array
	var passed := int(pending_before_endpoint.get("pendingNavigationLinkCount", 0)) == 1 and int(pending_before_endpoint.get("installedDoorLinkCount", 0)) == 0 and int(installed.get("pendingNavigationLinkCount", -1)) == 0 and int(installed.get("installedDoorLinkCount", 0)) == 1 and installed_links.size() == 1 and int(deferred.get("pendingNavigationLinkCount", 0)) == 1 and int(deferred.get("installedDoorLinkCount", -1)) == 0 and int(recovered.get("pendingNavigationLinkCount", -1)) == 0 and int(recovered.get("installedDoorLinkCount", 0)) == 1
	return outcome(passed, "pending=%s installed=%s deferred=%s recovered=%s" % [JSON.stringify(pending_before_endpoint), JSON.stringify(installed), JSON.stringify(deferred), JSON.stringify(recovered)], ["door_link_waits_for_both_endpoint_regions", "endpoint_unload_defers_door_link", "endpoint_republication_restores_door_link"], {"pending": pending_before_endpoint, "installed": installed, "installedSnapshot": installed_snapshot, "deferred": deferred, "recovered": recovered})

func test_navmesh_route_through_door_link_emits_action(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	service.register_chunk_descriptor(navmesh_door_descriptor("region:chunk:door-route", "door-route", "door:route"))
	service.sync_navigation_map_if_dirty()
	var route: Dictionary = service.query_route(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 2.7), { "maxSnapDistance": 4.0 })
	var endpoint_certificate: Dictionary = service.certify_route_endpoint(Vector3(0.0, 0.0, 2.7), Vector3(0.0, 0.0, 2.7), { "maxSnapDistance": 4.0 })
	var wrong_elevation_certificate: Dictionary = service.certify_route_endpoint(Vector3(0.0, 4.0, 2.7), Vector3(0.0, 0.0, 2.7), { "maxSnapDistance": 4.0 })
	var beyond_snap_certificate: Dictionary = service.certify_route_endpoint(Vector3(20.0, 0.0, 20.0), Vector3(20.0, 0.0, 20.0), { "maxSnapDistance": 0.5, "targetMaxSnapDistance": 0.5 })
	var actions: Dictionary = route.get("actions", {})
	var door_action := {}
	for action_value in actions.values():
		if action_value is Dictionary and String((action_value as Dictionary).get("portalId", "")) == "door:route":
			door_action = action_value
			break
	var raw_path: Array[Vector3] = [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 2.7)]
	var raw_actions := {
		"0,2": {
			"kind": "door",
			"portalId": "door:route",
			"entryPosition": Vector3(0.0, 0.0, 0.9),
			"exitPosition": Vector3(0.0, 0.0, 1.8),
			"pathSegmentIndex": 1
		}
	}
	var sequenced_result: Dictionary = service.call("_scripted_navigation_waypoint_result", raw_path, raw_actions) as Dictionary
	var sequenced_path: Array = sequenced_result.get("path", []) if sequenced_result.get("path", []) is Array else []
	var has_entry := sequenced_path.size() >= 4 and sequenced_path[1] is Vector3 and (sequenced_path[1] as Vector3).distance_to(Vector3(0.0, 0.0, 0.9)) <= 0.001
	var has_exit := sequenced_path.size() >= 4 and sequenced_path[2] is Vector3 and (sequenced_path[2] as Vector3).distance_to(Vector3(0.0, 0.0, 1.8)) <= 0.001
	var stats: Dictionary = service.stats()
	service.clear()
	var passed: bool = bool(route.get("ok", false)) and not door_action.is_empty() and String(door_action.get("kind", "")) == "door" and bool(door_action.get("requiresSmartObject", false)) and bool(door_action.get("navLink", false)) and bool(endpoint_certificate.get("ok", false)) and not bool(wrong_elevation_certificate.get("ok", true)) and not bool(beyond_snap_certificate.get("ok", true)) and bool(sequenced_result.get("ok", false)) and has_entry and has_exit and int(stats.get("pathQueryFailureCount", 0)) == 0
	return outcome(passed, "route=%s action=%s endpoint=%s wrongElevation=%s beyondSnap=%s sequenced=%s stats=%s" % [JSON.stringify(route), JSON.stringify(door_action), JSON.stringify(endpoint_certificate), JSON.stringify(wrong_elevation_certificate), JSON.stringify(beyond_snap_certificate), JSON.stringify(sequenced_result), JSON.stringify(stats)], ["navmesh_query_uses_door_link", "door_link_route_emits_smart_object_action", "route_endpoint_matches_support_owner_and_plane", "wrong_elevation_endpoint_rejected", "coincident_endpoint_beyond_snap_policy_rejected", "door_action_materialization_succeeds", "door_action_inserts_entry_and_exit_waypoints"], { "route": route, "action": door_action, "endpointCertificate": endpoint_certificate, "wrongElevationCertificate": wrong_elevation_certificate, "beyondSnapCertificate": beyond_snap_certificate, "sequencedResult": sequenced_result, "sequencedPath": sequenced_path, "stats": stats })

func test_navmesh_actor_path_status(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	service.register_chunk_descriptor(navmesh_door_descriptor("region:chunk:actor-status", "actor-status", "door:actor-status"))
	var route: Dictionary = service.query_route(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 2.7), { "actorId": "npc:test:actor-status", "kind": "scripted", "maxSnapDistance": 4.0 })
	var status: Dictionary = service.actor_path_status("npc:test:actor-status")
	var unknown: Dictionary = service.actor_path_status("npc:missing")
	var snapshot: Dictionary = service.debug_snapshot()
	var all_status: Dictionary = snapshot.get("actorPathStatus", {})
	service.clear()
	var passed: bool = bool(route.get("ok", false)) and bool(status.get("ok", false)) and String(status.get("actorId", "")) == "npc:test:actor-status" and String(status.get("source", "")) == "navmesh" and String(status.get("nextDoorPortalId", "")) == "door:actor-status" and int(status.get("pathPointCount", 0)) >= 2 and String(unknown.get("reason", "")) == "no_query_record" and int(all_status.get("count", 0)) == 1
	return outcome(passed, "route=%s status=%s unknown=%s all=%s" % [JSON.stringify(route), JSON.stringify(status), JSON.stringify(unknown), JSON.stringify(all_status)], ["navmesh_records_actor_path_status", "navmesh_debug_exports_actor_path_status"], { "route": route, "status": status, "unknown": unknown, "all": all_status })

func test_navmesh_door_state_toggles_nav_link(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	service.register_chunk_descriptor(navmesh_door_descriptor("region:chunk:door-toggle", "door-toggle", "door:toggle"))
	var closed: Dictionary = service.set_door_portal_state("door:toggle", "closed", { "openable": true, "locked": false })
	var closed_snapshot: Dictionary = service.debug_snapshot()
	var locked: Dictionary = service.set_door_portal_state("door:toggle", "locked", { "locked": true })
	var locked_snapshot: Dictionary = service.debug_snapshot()
	var reopened: Dictionary = service.set_door_portal_state("door:toggle", "open", { "locked": false, "jammed": false, "destroyed": false, "unloaded": false })
	var reopened_snapshot: Dictionary = service.debug_snapshot()
	var stats: Dictionary = service.stats()
	service.clear()
	var closed_link: Dictionary = _first_portal_debug_link(closed_snapshot, "door:toggle")
	var locked_link: Dictionary = _first_portal_debug_link(locked_snapshot, "door:toggle")
	var reopened_link: Dictionary = _first_portal_debug_link(reopened_snapshot, "door:toggle")
	var passed: bool = bool(closed_link.get("enabled", false)) and not bool(locked_link.get("enabled", true)) and bool(reopened_link.get("enabled", false)) and int(closed.get("updatedLinks", 0)) == 1 and int(locked.get("updatedLinks", 0)) == 1 and int(reopened.get("updatedLinks", 0)) == 1 and int(stats.get("doorLinkStateRevision", 0)) >= 3
	return outcome(passed, "closed=%s locked=%s reopened=%s stats=%s" % [JSON.stringify(closed_link), JSON.stringify(locked_link), JSON.stringify(reopened_link), JSON.stringify(stats)], ["closed_openable_link_remains_enabled", "locked_door_disables_nav_link", "reopened_door_enables_nav_link"], { "closed": closed, "locked": locked, "reopened": reopened, "stats": stats })

func test_navmesh_dirty_region_rebuild_after_world_edit(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	service.register_tile_snapshot(nav_snapshot("6,6", [
		nav_surface(Vector3i(96, 0, 96)),
		nav_surface(Vector3i(97, 0, 96))
	]))
	var responses: Array = service.apply_navigation_events([{ "tileKey": "6,6", "changeKinds": ["block_removed"], "revision": 7 }])
	var dirty_stats: Dictionary = service.stats()
	var dirty_snapshot: Dictionary = service.debug_snapshot()
	var rebuilt: Array = service.process_dirty_regions(1, 100000)
	var rebuilt_stats: Dictionary = service.stats()
	service.clear()
	var dirty_state := String((dirty_snapshot.get("regionStates", {}) as Dictionary).get("region:chunk:6,6", ""))
	var passed: bool = not responses.is_empty() and String((responses[0] as Dictionary).get("status", "")) == "dirty" and dirty_state == "dirty" and int(dirty_stats.get("dirtyRegionCount", 0)) == 1 and not rebuilt.is_empty() and String((rebuilt[0] as Dictionary).get("status", "")) == "rebuilt" and int(rebuilt_stats.get("dirtyRegionCount", -1)) == 0 and int(rebuilt_stats.get("rebuildCount", 0)) == 1 and int(rebuilt_stats.get("installedRegionCount", 0)) == 1
	return outcome(passed, "responses=%s dirty=%s rebuilt=%s stats=%s" % [JSON.stringify(responses), JSON.stringify(dirty_stats), JSON.stringify(rebuilt), JSON.stringify(rebuilt_stats)], ["world_edit_marks_navmesh_region_dirty", "dirty_region_rebuild_clears_queue"], { "responses": responses, "dirtyStats": dirty_stats, "rebuilt": rebuilt, "rebuiltStats": rebuilt_stats })


func test_navmesh_semantic_event_preserves_geometry_region(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	service.register_tile_snapshot(nav_snapshot("6,6", [
		nav_surface(Vector3i(96, 0, 96)),
		nav_surface(Vector3i(97, 0, 96))
	]))
	var topology_before: int = service.topology_revision
	var responses: Array = service.apply_navigation_events([{ "tileKey": "6,6", "changeKinds": [String(NpcEnumsScript.CHANGE_KIND_SEMANTIC_CHANGED)], "revision": 8 }])
	var stats: Dictionary = service.stats()
	var topology_after: int = service.topology_revision
	var queued_dirty_regions: Array = service.dirty_region_queue.duplicate()
	service.clear()
	var response: Dictionary = responses[0] if not responses.is_empty() and responses[0] is Dictionary else {}
	var passed: bool = String(response.get("status", "")) == "semantic" \
		and queued_dirty_regions.is_empty() \
		and topology_after == topology_before \
		and int(stats.get("dirtyRegionCount", -1)) == 0
	return outcome(passed, "response=%s topology=%d->%d queued=%s stats=%s" % [JSON.stringify(response), topology_before, topology_after, JSON.stringify(queued_dirty_regions), JSON.stringify(stats)], ["semantic_event_keeps_geometry_region_published", "semantic_event_does_not_queue_navmesh_rebuild"], { "response": response, "topologyBefore": topology_before, "topologyAfter": topology_after, "queuedDirtyRegions": queued_dirty_regions, "stats": stats })


func test_navmesh_chunk_unload_cleans_door_links(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	service.register_chunk_descriptor(navmesh_door_descriptor("region:chunk:8,8", "8,8", "door:unload"))
	var after_register: Dictionary = service.stats()
	var responses: Array = service.apply_navigation_events([{ "tileKey": "8,8", "changeKinds": ["chunk_unloaded"], "revision": 8 }])
	var after_unload: Dictionary = service.stats()
	var snapshot: Dictionary = service.debug_snapshot()
	service.clear()
	var passed: bool = int(after_register.get("installedDoorLinkCount", 0)) == 1 and int(after_unload.get("installedDoorLinkCount", -1)) == 0 and int(after_unload.get("installedRegionCount", -1)) == 0 and (snapshot.get("doorLinks", {}) as Dictionary).is_empty() and not responses.is_empty() and String((responses[0] as Dictionary).get("status", "")) == "unregistered"
	return outcome(passed, "afterRegister=%s afterUnload=%s responses=%s" % [JSON.stringify(after_register), JSON.stringify(after_unload), JSON.stringify(responses)], ["chunk_unload_releases_door_link_rids", "chunk_unload_clears_door_link_debug_state"], { "afterRegister": after_register, "afterUnload": after_unload, "responses": responses, "snapshot": snapshot })

func test_navmesh_semantic_interior_descriptor_registered(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	var bounds := AABB(Vector3(10.0, 0.0, 20.0), Vector3(5.4, 3.0, 4.05))
	var registered: Dictionary = service.register_semantic_descriptor("home_interior", "home:starter:mira", bounds, { "npcId": "mira", "inside": true, "tileKey": "starter-home" })
	var closest: Dictionary = service.closest_walkable(bounds.position + bounds.size * 0.5, 10.0)
	var snapshot: Dictionary = service.debug_snapshot()
	service.clear()
	var region: Dictionary = (snapshot.get("regions", {}) as Dictionary).get("region:semantic:home:starter:mira", {})
	var passed: bool = String(registered.get("status", "")) == "installed" and bool(closest.get("found", false)) and String(region.get("metadata", {}).get("semanticKind", "")) == "home_interior" and int(snapshot.get("installedRegionCount", 0)) == 1
	return outcome(passed, "registered=%s closest=%s" % [JSON.stringify(registered), JSON.stringify(closest)], ["semantic_home_interior_installs_navmesh_region", "semantic_home_interior_closest_walkable"], { "registered": registered, "closest": closest, "region": region })

func test_navmesh_autonomy_semantic_backend_registers(_mode: String) -> Dictionary:
	var previous_backend := OS.get_environment(NavigationBackendConfigScript.ENV_BACKEND)
	OS.set_environment(NavigationBackendConfigScript.ENV_BACKEND, "navmesh")
	var autonomy := NpcAutonomySystemScript.new()
	autonomy.setup(null, null)
	var revision := autonomy.register_semantic_region(&"home_interior", "home:test:niko", AABB(Vector3(2.0, 0.0, 3.0), Vector3(4.05, 2.7, 4.05)), { "npcId": "niko", "inside": true })
	var stats: Dictionary = autonomy.stats()
	var summary: Dictionary = autonomy.navigation_backend_summary()
	autonomy.free()
	OS.set_environment(NavigationBackendConfigScript.ENV_BACKEND, previous_backend)
	var navmesh_stats: Dictionary = stats.get("navmeshWorld", {})
	var passed: bool = revision > 0 and bool(summary.get("navmeshEnabled", false)) and int(navmesh_stats.get("installedRegionCount", 0)) == 1 and int(navmesh_stats.get("installedSurfaceCount", 0)) == 1
	return outcome(passed, "summary=%s navmesh=%s revision=%d" % [JSON.stringify(summary), JSON.stringify(navmesh_stats), revision], ["autonomy_navmesh_backend_enabled", "autonomy_semantic_registers_navmesh_region"], { "summary": summary, "navmesh": navmesh_stats, "revision": revision })

func test_navmesh_autonomy_prefetch_preserves_published_tile(_mode: String) -> Dictionary:
	var previous_backend := OS.get_environment(NavigationBackendConfigScript.ENV_BACKEND)
	OS.set_environment(NavigationBackendConfigScript.ENV_BACKEND, "navmesh")
	var autonomy := NpcAutonomySystemScript.new()
	autonomy.setup(null, null)
	var published_snapshot := nav_snapshot("7,7", [
		nav_surface(Vector3i(112, 0, 112)),
		nav_surface(Vector3i(113, 0, 112))
	], { "regionId": "region:chunk:7,7" })
	var published: Dictionary = autonomy.navmesh_world.register_tile_snapshot(published_snapshot)
	var prefetch: Dictionary = autonomy.request_navigation_tile({ "tileKey": "7,7", "centerCell": Vector2i(112, 112) }, 10)
	var navmesh_stats: Dictionary = autonomy.navmesh_world.stats()
	var navmesh_snapshot: Dictionary = autonomy.navmesh_world.debug_snapshot()
	autonomy.free()
	OS.set_environment(NavigationBackendConfigScript.ENV_BACKEND, previous_backend)
	var region: Dictionary = (navmesh_snapshot.get("regions", {}) as Dictionary).get("region:chunk:7,7", {}) as Dictionary
	var published_surfaces: Array = region.get("walkableSurfaces", []) as Array
	var passed := bool(published.get("installed", false)) \
		and String(prefetch.get("status", "")) == String(NpcEnumsScript.ROUTE_STATUS_PENDING) \
		and int(navmesh_stats.get("installedRegionCount", 0)) == 1 \
		and int(navmesh_stats.get("installedSurfaceCount", 0)) > 0 \
		and published_surfaces.size() == 2
	return outcome(passed, "published=%s prefetch=%s stats=%s region=%s" % [JSON.stringify(published), JSON.stringify(prefetch), JSON.stringify(navmesh_stats), JSON.stringify(region)], ["lod_prefetch_requests_topology_without_replacing_navmesh_descriptor", "published_navmesh_tile_retains_walkable_surfaces"], { "published": published, "prefetch": prefetch, "navmesh": navmesh_stats, "region": region })

func test_navmesh_service_register_unregister_descriptor(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	var descriptor = navmesh_descriptor("region:chunk:0,0", "0,0")
	var registered: Dictionary = service.register_chunk_descriptor(descriptor)
	var after_register: Dictionary = service.stats()
	var unregistered: Dictionary = service.unregister_chunk("region:chunk:0,0")
	var after_unregister: Dictionary = service.stats()
	service.clear()
	var passed: bool = String(registered.get("status", "")) == "installed" and int(after_register.get("regionCount", 0)) == 1 and int(after_register.get("installedRegionCount", 0)) == 1 and String(unregistered.get("status", "")) == "unregistered" and int(after_unregister.get("regionCount", -1)) == 0 and int(after_unregister.get("installedRegionCount", -1)) == 0 and int(after_unregister.get("topologyRevision", 0)) == 2
	return outcome(passed, "registered=%s unregistered=%s" % [JSON.stringify(registered), JSON.stringify(unregistered)], ["navmesh_descriptor_registers_region", "navmesh_descriptor_unregisters_region", "navmesh_topology_revision_tracks_cleanup"], { "registered": registered, "afterRegister": after_register, "unregistered": unregistered, "afterUnregister": after_unregister })

func test_navmesh_closest_walkable_descriptor_point(_mode: String) -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	var descriptor = NavigationBakeDescriptorScript.create("region:chunk:near", "0,0", AABB(Vector3.ZERO, Vector3(8, 2, 8)))
	descriptor.add_walkable_surface("surface:far", Vector3(7.0, 0.0, 7.0))
	descriptor.add_walkable_surface("surface:near", Vector3(2.0, 0.0, 1.0))
	service.register_chunk_descriptor(descriptor)
	var closest: Dictionary = service.closest_walkable(Vector3(2.2, 0.0, 1.1), 2.0)
	var missed: Dictionary = service.closest_walkable(Vector3(40.0, 0.0, 40.0), 2.0)
	service.clear()
	var passed: bool = bool(closest.get("found", false)) and String(closest.get("surfaceId", "")) == "surface:near" and not bool(missed.get("found", true))
	return outcome(passed, "closest=%s missed=%s" % [JSON.stringify(closest), JSON.stringify(missed)], ["closest_walkable_from_descriptor_surface", "closest_walkable_honors_max_distance"], { "closest": closest, "missed": missed })

func test_navmesh_no_scene_visual_mesh_scan(_mode: String) -> Dictionary:
	var service_text := read_text("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
	var descriptor_text := read_text("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
	var passed := (
		service_text.find("get_tree(") < 0
		and service_text.find("find_children") < 0
		and service_text.find("MeshInstance3D") < 0
		and service_text.find("parse_source_geometry_data") < 0
		and service_text.find(".mesh") < 0
		and descriptor_text.find("stable_signature") >= 0
	)
	return outcome(passed, "getTree=%d meshInstance=%d parse=%d" % [service_text.find("get_tree("), service_text.find("MeshInstance3D"), service_text.find("parse_source_geometry_data")], ["navmesh_service_uses_explicit_descriptors", "navmesh_descriptor_owns_deterministic_signature"], {})

func test_navmesh_live_legacy_audit_passes(_mode: String) -> Dictionary:
	var audit_text := read_text("res://tools/npc/audit-npc-navmesh-backend.ps1")
	var planner_text := read_text("res://scripts/npc_ai/routing/HierarchicalRoutePlanner.gd")
	var route_adapter_text := read_text("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")
	var coordinator_text := read_text("res://scripts/npc_ai/routing/NpcNavigationCoordinator.gd")
	var passed := (
		audit_text.find("LocalAStarPlannerScript") >= 0
		and audit_text.find("HierarchicalRoutePlannerScript") >= 0
		and audit_text.find("LiveRuntimeFiles") >= 0
		and planner_text.find("LocalAStarPlannerScript") >= 0
		and route_adapter_text.find("HierarchicalRoutePlannerScript") < 0
		and route_adapter_text.find("LocalAStarPlannerScript") < 0
		and route_adapter_text.find("navmesh_planner.plan_runtime_route") >= 0
		and coordinator_text.find("NpcRouteCoordinatorAdapterScript") >= 0
		and coordinator_text.find("GeneratedWorldNavigationAdapterScript") >= 0
	)
	return outcome(passed, "audit=%d planner=%d adapterLegacy=%d coordinator=%d" % [audit_text.length(), planner_text.find("LocalAStarPlannerScript"), route_adapter_text.find("HierarchicalRoutePlannerScript"), coordinator_text.find("NpcRouteCoordinatorAdapterScript")], ["navmesh_audit_scans_live_runtime", "live_adapter_has_no_legacy_planner_dependency"], {})

func nav_event_setup() -> Dictionary:
	var bus := NavigationChangeBusScript.new()
	var service := NavigationWorldServiceScript.new()
	service.setup(null, bus)
	return { "bus": bus, "service": service }

func nav_snapshot(tile_key: String, surfaces: Array, extra := {}) -> Dictionary:
	var snapshot := {
		"tileKey": tile_key,
		"surfaces": surfaces
	}
	for key in extra.keys():
		snapshot[key] = extra[key]
	return snapshot

func nav_surface(cell: Vector3i, extra := {}) -> Dictionary:
	var surface := {
		"cell": cell,
		"worldPosition": Vector3(float(cell.x) * NpcConstantsScript.CELL_SIZE, float(cell.y) * NpcConstantsScript.CELL_SIZE, float(cell.z) * NpcConstantsScript.CELL_SIZE),
		"floorNormal": Vector3.UP,
		"headroom": 2.4,
		"lateralClearance": 1.0,
		"blocked": false,
		"semanticRegionIds": [],
		"traversalTags": ["terrain"]
	}
	for key in extra.keys():
		surface[key] = extra[key]
	return surface

func navmesh_descriptor(region_id: String, tile_key: String):
	var descriptor = NavigationBakeDescriptorScript.create(region_id, tile_key, AABB(Vector3.ZERO, Vector3(4, 2, 4)))
	descriptor.add_walkable_surface("surface:a", Vector3.ZERO)
	descriptor.add_walkable_surface("surface:b", Vector3(2.0, 0.0, 0.0))
	descriptor.add_blocker("blocker:wall", AABB(Vector3(3.0, 0.0, 0.0), Vector3(1.0, 2.0, 1.0)))
	descriptor.add_semantic_anchor("anchor:guard", "guard_post", Vector3(1.0, 0.0, 1.0))
	descriptor.add_door_portal("door:home", Vector3(0.5, 0.0, 0.0), Vector3(0.5, 0.0, 1.0))
	return descriptor

func navmesh_door_descriptor(region_id: String, tile_key: String, portal_id: String):
	var descriptor = NavigationBakeDescriptorScript.create(region_id, tile_key, AABB(Vector3(-1.5, -0.1, -1.5), Vector3(3.0, 1.2, 5.7)))
	descriptor.add_walkable_surface("surface:%s:left" % tile_key, Vector3(0.0, 0.0, 0.0), Vector3(1.35, 0.05, 1.35))
	descriptor.add_walkable_surface("surface:%s:right" % tile_key, Vector3(0.0, 0.0, 2.7), Vector3(1.35, 0.05, 1.35))
	descriptor.add_door_portal(portal_id, Vector3(0.0, 0.0, 0.65), Vector3(0.0, 0.0, 2.05), { "state": "closed", "openable": true })
	descriptor.add_door_link("surface:%s:left" % tile_key, "surface:%s:right" % tile_key, portal_id, { "cost": 1.0, "actionId": "open" })
	return descriptor

func _first_portal_debug_link(snapshot: Dictionary, portal_id: String) -> Dictionary:
	var links_by_portal: Dictionary = snapshot.get("doorLinks", {})
	var links: Array = links_by_portal.get(portal_id, [])
	if links.is_empty() or not (links[0] is Dictionary):
		return {}
	return links[0]

func motor_body(node_name: String) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.name = node_name
	body.collision_layer = NpcConstantsScript.COLLISION_NPC_BODY
	body.collision_mask = NpcConstantsScript.COLLISION_NPC_BODY_MASK
	var shape := CapsuleShape3D.new()
	shape.radius = 0.34
	shape.height = 1.62
	var collider := CollisionShape3D.new()
	collider.name = "MotorTestCollider"
	collider.shape = shape
	collider.position.y = 0.84
	body.add_child(collider)
	add_child(body)
	return body

func motor_door_leaf(node_name: String, portal_id: String, group_id: String) -> Node3D:
	var door := Node3D.new()
	door.name = node_name
	door.set_meta("kind", "block")
	door.set_meta("block_type", "door")
	door.set_meta("open", false)
	door.set_meta("door_portal_id", portal_id)
	door.set_meta("door_group_id", group_id)
	add_child(door)
	return door

func live_nav_block(cell: Vector2i, block_type := "woodBlock", size := Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "LiveNavBlock_%s_%d_%d" % [block_type, cell.x, cell.y]
	body.position = Vector3(float(cell.x) * NpcConstantsScript.CELL_SIZE, 0.0, float(cell.y) * NpcConstantsScript.CELL_SIZE)
	body.set_meta("kind", "block")
	body.set_meta("cell", Vector3i(cell.x, 0, cell.y))
	body.set_meta("block_type", block_type)
	if block_type == "door":
		body.set_meta("door_policy", "public_gate")
		body.set_meta("open", false)
	var shape := BoxShape3D.new()
	shape.size = size if size != Vector3.ZERO else Vector3(NpcConstantsScript.CELL_SIZE * 0.96, NpcConstantsScript.CELL_SIZE, NpcConstantsScript.CELL_SIZE * 0.96)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)
	return body

func run_motor_once(profile, command, grounded := true) -> Dictionary:
	var body := motor_body("MotorTestBody")
	var motor = CharacterMotor3DScript.new()
	command.terrain_grounded = grounded
	command.grounded_hint = grounded
	command.jump_snap_time = 0.0
	var state = motor.call("apply", body, command, profile, 1.0 / 60.0, null)
	var result := {
		"state": state,
		"position": body.global_position,
		"velocity": body.velocity
	}
	body.queue_free()
	return result

func read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func isolate_trace_file(path: String) -> Dictionary:
	var existed := FileAccess.file_exists(path)
	var contents := read_text(path) if existed else ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return {
		"existed": existed,
		"contents": contents
	}


func restore_isolated_trace_file(path: String, prior_trace: Dictionary) -> void:
	if not bool(prior_trace.get("existed", false)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(String(prior_trace.get("contents", "")))
	file.close()


func trace_file_matches_prior(path: String, prior_trace: Dictionary) -> bool:
	var existed := bool(prior_trace.get("existed", false))
	if not existed:
		return not FileAccess.file_exists(path)
	return FileAccess.file_exists(path) and read_text(path) == String(prior_trace.get("contents", ""))

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	return {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}

func add_result(id: String, mode: String, passed: bool, details: String, assertions: Array, key_state: Dictionary, duration := 0.0) -> void:
	var result := {
		"id": id,
		"timeMode": mode,
		"seed": seed,
		"passed": passed,
		"durationSeconds": snap_seconds(duration),
		"assertions": assertions,
		"keyState": key_state,
		"details": details,
		"artifacts": {}
	}
	if not passed and trace_dir != "":
		result["artifacts"] = { "traceDir": trace_dir }
	results.append(result)
	metrics["assertions"] = int(metrics.get("assertions", 0)) + assertions.size()
	if not passed:
		failed = true
	print("[%s] %s %s %s" % ["PASS" if passed else "FAIL", id, mode, details])
	save_report(false)

func finish() -> void:
	if finished:
		return
	finished = true
	finished_utc = Time.get_datetime_string_from_system(true)
	write_progress("finished")
	save_report(true)
	get_tree().quit(1 if failed else 0)

func build_report(include_finished: bool) -> Dictionary:
	var failures := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failures += 1
	var version_info: Dictionary = Engine.get_version_info()
	return {
		"schemaVersion": 1,
		"suite": suite_filter,
		"caseFilter": case_filter,
		"timeMode": time_mode,
		"seed": seed,
		"branch": branch,
		"gitCommit": git_commit,
		"engineVersion": version_info,
		"startedUtc": started_utc,
		"finishedUtc": finished_utc if include_finished else "",
		"durationSeconds": snap_seconds(Time.get_unix_time_from_system() - started_unix),
		"resultCount": results.size(),
		"failureCount": failures,
		"results": results,
		"metrics": metrics,
		"artifacts": {
			"report": report_path,
			"progress": progress_path,
			"traceDir": trace_dir,
			"screenshotDir": screenshot_dir
		},
		"runToken": run_token
	}

func save_report(verbose := true) -> void:
	if report_path == "":
		return
	var report := build_report(finished)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write NPC test report: %s" % report_path)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	if verbose:
		print("NPC test report: %s" % report_path)

func write_progress(label: String) -> void:
	if progress_path == "":
		return
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string("%s\nelapsed=%.3f\nresults=%d\nfailed=%s\ntoken=%s\n" % [label, elapsed, results.size(), str(failed), run_token])
	file.close()

func read_json_file(path: String):
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	return JSON.parse_string(text)

func snap_seconds(value: float) -> float:
	return snappedf(value, 0.001)

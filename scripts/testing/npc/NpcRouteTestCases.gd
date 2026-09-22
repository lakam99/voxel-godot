extends RefCounted

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const TraversalProfileScript := preload("res://scripts/npc_ai/contracts/TraversalProfile.gd")
const RouteRequestScript := preload("res://scripts/npc_ai/contracts/RouteRequest.gd")
const NavigationChangeBusScript := preload("res://scripts/npc_ai/navigation/NavigationChangeBus.gd")
const NavigationWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavigationWorldService.gd")
const NavigationBakeDescriptorScript := preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavmeshWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
const GeneratedWorldNavigationAdapterScript := preload("res://scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd")
const HierarchicalRoutePlannerScript := preload("res://scripts/npc_ai/routing/HierarchicalRoutePlanner.gd")
const NavmeshRoutePlannerScript := preload("res://scripts/npc_ai/routing/NavmeshRoutePlanner.gd")
const NpcRouteCoordinatorAdapterScript := preload("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")
const CollisionProbeServiceScript := preload("res://scripts/npc_ai/routing/CollisionProbeService.gd")
const CollisionBackedRouteSubstrateScript := preload("res://scripts/npc_ai/routing/CollisionBackedRouteSubstrate.gd")
const NpcRouteAuthorityV2Script := preload("res://scripts/npc_ai/routing/NpcRouteAuthorityV2.gd")
const NpcRouteLeaseExecutorScript := preload("res://scripts/npc_ai/movement/NpcRouteLeaseExecutor.gd")
const NpcPlanExecutorScript := preload("res://scripts/npc_ai/behavior/NpcPlanExecutor.gd")
const LiveRoutePlanningProgressWatchdogScript := preload("res://scripts/testing/player/LiveRoutePlanningProgressWatchdog.gd")
const CELL := NpcConstantsScript.CELL_SIZE

var runner = null

class RouteTestMain:
	extends Node
	var seed_text := "synthetic-route-filter-contract"
	var WATER_LEVEL := -1000.0
	var blocks := {}
	var chunk_root := Node.new()
	var prop_root := Node.new()

	func _init() -> void:
		add_child(chunk_root)
		add_child(prop_root)

	func surface_y_at_cell(_cell) -> float:
		return 0.0

class ElevationRouteTestMain:
	extends RouteTestMain

	func surface_y_at_position(position: Vector3) -> float:
		return position.x * 0.2 + position.z * 0.1

class FakeNavmeshRouteService:
	extends RefCounted
	var query_count := 0

	func query_route(start: Vector3, target: Vector3, _options := {}) -> Dictionary:
		query_count += 1
		return {
			"ok": true,
			"status": "complete",
			"reason": "",
			"source": "navmesh",
			"queryApi": "fake_direct",
			"startPosition": start,
			"targetPosition": target,
			"path": [start, target],
			"actions": {},
			"snapshotRevision": "fake:%d" % query_count,
			"pointCount": 2,
			"distance": start.distance_to(target)
		}

	func stats() -> Dictionary:
		return { "pathQueryCount": query_count }

class BudgetedCollisionProbe:
	extends RefCounted
	var required_samples := 3

	func setup(_system_node, _main_node) -> void:
		pass

	func probe_route(_entry: Dictionary, route: Dictionary, _intent: Dictionary, options := {}) -> Dictionary:
		var waypoints: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
		if waypoints.is_empty():
			return {
				"ok": false,
				"status": "invalid_goal",
				"reason": "empty_waypoints",
				"authoritative": true,
				"sampleCount": 0,
				"details": {}
			}
		var cursor: Dictionary = options.get("cursor", {}) if options.get("cursor", {}) is Dictionary else {}
		var completed := int(cursor.get("completedSamples", 0))
		var remaining := maxi(0, required_samples - completed)
		var max_samples := maxi(0, int(options.get("maxSamples", remaining)))
		var sampled := mini(remaining, max_samples)
		completed += sampled
		if completed < required_samples:
			return {
				"ok": false,
				"status": "pending_probe",
				"reason": "collision_probe_budget",
				"authoritative": true,
				"sampleCount": sampled,
				"details": {
					"completedSamples": completed,
					"cursor": { "completedSamples": completed }
				}
			}
		return {
			"ok": true,
			"status": "passed",
			"reason": "",
			"authoritative": true,
			"sampleCount": sampled,
			"details": { "completedSamples": completed }
		}

class CrossFrameRepairProbe:
	extends RefCounted
	var probe_calls := 0

	func setup(_system_node, _main_node) -> void:
		pass

	func probe_route(_entry: Dictionary, _route: Dictionary, _intent: Dictionary, _options := {}) -> Dictionary:
		probe_calls += 1
		if probe_calls == 1 or probe_calls == 3:
			var blocked_cell := Vector2i(2, 0) if probe_calls == 1 else Vector2i(3, 0)
			return {
				"ok": false,
				"status": "failed",
				"reason": "blocked_capsule_probe",
				"authoritative": true,
				"sampleCount": 1,
				"details": { "cell": blocked_cell, "sample": blocked_cell }
			}
		if probe_calls == 2:
			return {
				"ok": false,
				"status": "pending_probe",
				"reason": "collision_probe_budget",
				"authoritative": true,
				"sampleCount": 1,
				"details": { "completedSamples": 1, "cursor": { "completedSamples": 1 } }
			}
		return {
			"ok": true,
			"status": "passed",
			"reason": "",
			"authoritative": true,
			"sampleCount": 1,
			"details": {}
		}

class DynamicActorRepairProbe:
	extends RefCounted
	var probe_calls := 0

	func setup(_system_node, _main_node) -> void:
		pass

	func probe_route(_entry: Dictionary, _route: Dictionary, _intent: Dictionary, _options := {}) -> Dictionary:
		probe_calls += 1
		if probe_calls == 1:
			return {
				"ok": false,
				"status": "failed",
				"reason": "blocked_capsule_probe",
				"authoritative": true,
				"sampleCount": 1,
				"details": {
					"cell": Vector2i(2, 0),
					"sample": Vector2i(2, 0),
					"collider": "Player",
					"class": "CharacterBody3D",
					"kind": "player"
				}
			}
		return {
			"ok": true,
			"status": "passed",
			"reason": "",
			"authoritative": true,
			"sampleCount": 1,
			"details": {}
		}

class TerrainMotionRepairProbe:
	extends RefCounted
	var probe_calls := 0

	func setup(_system_node, _main_node) -> void:
		pass

	func probe_route(_entry: Dictionary, _route: Dictionary, _intent: Dictionary, _options := {}) -> Dictionary:
		probe_calls += 1
		if probe_calls == 1:
			return {
				"ok": false,
				"status": "failed",
				"reason": "blocked_terrain_motion_probe",
				"authoritative": true,
				"sampleCount": 1,
				# Production terrain probes supply a sampled world position; the
				# authority must turn it into a collision repair avoid cell.
				"details": { "sample": Vector3(CELL * 2.0, 0.0, 0.0) }
			}
		return {
			"ok": true,
			"status": "passed",
			"reason": "",
			"authoritative": true,
			"sampleCount": 1,
			"details": {}
		}

class RepeatingTerrainMotionRepairProbe:
	extends RefCounted
	var probe_calls := 0

	func setup(_system_node, _main_node) -> void:
		pass

	func probe_route(_entry: Dictionary, _route: Dictionary, _intent: Dictionary, _options := {}) -> Dictionary:
		probe_calls += 1
		return {
			"ok": false,
			"status": "failed",
			"reason": "blocked_terrain_motion_probe",
			"authoritative": true,
			"sampleCount": 1,
			"details": { "sample": Vector3(CELL * 2.0, 0.0, 0.0) }
		}

class RecordingRepairSubstrate:
	extends RefCounted
	var avoid_history: Array = []
	var repair_radius_history: Array = []

	func repair_route_after_probe(_entry: Dictionary, _start_cell: Vector2i, _candidate_cells: Array, failed_route: Dictionary, _certificate: Dictionary, options := {}) -> Dictionary:
		avoid_history.append((options.get("avoidCells", []) as Array).duplicate())
		repair_radius_history.append(int(options.get("probeRepairAvoidRadius", 0)))
		var repaired := failed_route.duplicate(true)
		repaired["ok"] = true
		repaired["status"] = "reachable"
		repaired["reason"] = "test_repair"
		return repaired

class InstrumentedRepairSubstrate:
	extends RefCounted
	var inner = null
	var requested_expansions: Array[int] = []
	var requested_validation_steps: Array[int] = []
	var actual_expansions: Array[int] = []
	var results: Array[Dictionary] = []

	func repair_route_after_probe(entry: Dictionary, start_cell: Vector2i, candidate_cells: Array, failed_route: Dictionary, certificate: Dictionary, options := {}) -> Dictionary:
		requested_expansions.append(int(options.get("expansionsPerCall", 0)))
		requested_validation_steps.append(int(options.get("validationStepsPerCall", 0)))
		var result: Dictionary = inner.repair_route_after_probe(entry, start_cell, candidate_cells, failed_route, certificate, options)
		var proof: Dictionary = result.get("proof", {}) if result.get("proof", {}) is Dictionary else {}
		actual_expansions.append(int(proof.get("expansionsThisCall", -1)))
		results.append(result.duplicate(true))
		return result

class GeneratedFallbackWorld:
	extends RefCounted

	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / 1.35), roundi(position.z / 1.35))

class IncrementalApproachAdapter:
	extends GeneratedWorldNavigationAdapter
	var ordered_cells: Array[Vector2i] = []
	var captured_standable := {}
	var live_standable := {}
	var validations: Array[Vector2i] = []
	var snapshot_calls := 0
	var use_tile_local_identity := false

	func approach_candidate_cells_for_target(_entry: Dictionary, _target_position: Vector3, _allow_outside := true) -> Array[Vector2i]:
		return ordered_cells.duplicate()

	func cached_validation_snapshot(_entry: Dictionary, _allow_outside := false, _moving_home := false) -> Dictionary:
		snapshot_calls += 1
		return {"standable":captured_standable.duplicate() if snapshot_calls == 1 else live_standable.duplicate(), "dynamic":{}}

	func cell_is_standable_goal_in_snapshot(_entry: Dictionary, snapshot: Dictionary, cell: Vector2i, _allow_outside := false, _moving_home := false) -> bool:
		validations.append(cell)
		if snapshot.has("standable"):
			return (snapshot.get("standable", {}) as Dictionary).has(cell)
		return live_standable.has(cell)

	func _approach_source_identity_for_tiles(tile_keys: Array) -> String:
		if use_tile_local_identity:
			return super._approach_source_identity_for_tiles(tile_keys)
		return "%d:%d:%d:%d" % [static_snapshot_revision, semantic_revision, door_state_revision, terrain_revision_clock]

	func _approach_input_identity(entry: Dictionary) -> String:
		return String(entry.get("inputIdentity", "stable"))

	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

class FakeLeaseAuthority:
	extends RefCounted
	var completed_segments := []
	var started_segments := []
	var door_waits := []
	var stuck_reports := []

	func begin_moving(_request_id: String, _reason := "") -> Dictionary:
		return { "ok": true, "state": "moving" }

	func report_segment_started(_request_id: String, index: int, _details := {}) -> void:
		started_segments.append(index)

	func report_segment_completed(_request_id: String, index: int, _details := {}) -> void:
		completed_segments.append(index)

	func report_arrived(_request_id: String, _reason := "") -> Dictionary:
		return { "ok": true, "state": "arrived" }

	func report_door_wait(_request_id: String, reason: String, details := {}) -> void:
		door_waits.append({ "reason": reason, "details": details })

	func report_unexpected_collision(_request_id: String, _reason := "", _details := {}) -> void:
		pass

	func report_stuck(_request_id: String, _reason := "", _details := {}) -> void:
		stuck_reports.append({ "reason": _reason, "details": _details })

class FakeNoProgressMotor:
	extends RefCounted
	var lateral_step := 0.08

	func apply(body: CharacterBody3D, _command, _profile, _delta: float, _terrain_provider):
		body.global_position += Vector3(0.0, 0.0, lateral_step)
		return { "blocked": false }

class GeneratedTownRouteSubstrateFixtureWorld:
	extends RefCounted
	var standable := {}
	var blocked := {}
	var static_collision := {}
	var dynamic := {}
	var doors := {}
	var pending_nav_data := false
	var revision := 0
	var static_snapshot_revision := 1
	var semantic_revision := 1
	var door_state_revision := 1
	var dynamic_revision := 1
	var terrain_revision := 0

	func _init() -> void:
		add_standable_rect(Vector2i(0, -2), Vector2i(5, 2))

	func add_standable_rect(min_cell: Vector2i, max_cell: Vector2i) -> void:
		for z in range(min_cell.y, max_cell.y + 1):
			for x in range(min_cell.x, max_cell.x + 1):
				standable[Vector2i(x, z)] = true

	func generated_town_entry() -> Dictionary:
		return {
			"id": "substrate-fixture-npc",
			"townCenter": Vector2i(2, 0),
			"townRadius": 8,
			"porchCell": Vector2i(1, 0),
			"homeInteriorMinCell": Vector2i(4, -1),
			"homeInteriorMaxCell": Vector2i(5, 1),
			"guardCell": Vector2i(0, 1),
			"workMinCell": Vector2i(3, -1),
			"workMaxCell": Vector2i(5, 1)
		}

	func build_snapshot(_entry: Dictionary, allow_outside := false, moving_home := false) -> Dictionary:
		if pending_nav_data:
			return {
				"status": "pending_nav_data",
				"pendingNavData": true,
				"reason": "fixture_nav_tiles_unpublished",
				"revision": "fixture:pending"
			}
		return {
			"revision": "fixture:%d" % revision,
			"staticSnapshotRevision": static_snapshot_revision,
			"semanticRevision": semantic_revision,
			"doorStateRevision": door_state_revision,
			"dynamicRevision": dynamic_revision,
			"terrainRevision": terrain_revision,
			"blocked": blocked,
			"staticCollisionByCell": static_collision_index(),
			"staticCollision": static_collision.values(),
			"dynamic": dynamic,
			"doors": doors,
			"allowOutside": allow_outside,
			"movingHome": moving_home
		}

	func static_collision_index() -> Dictionary:
		var result := {}
		for cell in static_collision.keys():
			result[cell] = [static_collision[cell]]
		return result

	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

	func cell_position(cell: Vector2i) -> Vector3:
		return Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)

	func static_blocker(snapshot: Dictionary, cell: Vector2i):
		if door_at(snapshot, cell) != null:
			return null
		var snapshot_blocked: Dictionary = snapshot.get("blocked", {})
		return snapshot_blocked.get(cell, null)

	func static_collision_blocker(snapshot: Dictionary, cell: Vector2i) -> Dictionary:
		if door_at(snapshot, cell) != null:
			return {}
		var index: Dictionary = snapshot.get("staticCollisionByCell", {})
		var records: Array = index.get(cell, [])
		if records.is_empty():
			return {}
		var record = records[0]
		return record if record is Dictionary else {}

	func dynamic_blocker(snapshot: Dictionary, cell: Vector2i):
		var snapshot_dynamic: Dictionary = snapshot.get("dynamic", {})
		return snapshot_dynamic.get(cell, null)

	func door_at(snapshot: Dictionary, cell: Vector2i):
		var snapshot_doors: Dictionary = snapshot.get("doors", {})
		return snapshot_doors.get(cell, null)

	func cell_transition_pathable(_entry: Dictionary, snapshot: Dictionary, from_cell: Vector2i, to_cell: Vector2i, _target_cells: Dictionary, ignore_dynamic := false) -> Dictionary:
		if not standable.has(to_cell):
			return { "ok": false, "reason": "no_walkable_surface" }
		if abs(to_cell.x - from_cell.x) + abs(to_cell.y - from_cell.y) != 1:
			return { "ok": false, "reason": "non_cardinal_transition" }
		if static_blocker(snapshot, to_cell) != null:
			return { "ok": false, "reason": "blocked_static", "blockerCell": to_cell }
		var collision := static_collision_blocker(snapshot, to_cell)
		if not collision.is_empty():
			return { "ok": false, "reason": "blocked_static_collision", "blockerCell": to_cell, "blockType": collision.get("blockType", "") }
		if not ignore_dynamic and dynamic_blocker(snapshot, to_cell) != null:
			return { "ok": false, "reason": "blocked_dynamic", "blockerCell": to_cell }
		return { "ok": true, "reason": "" }

	func cell_is_standable_goal(_entry: Dictionary, cell: Vector2i, _allow_outside := false, _moving_home := false) -> bool:
		return standable.has(cell)
	func point_inside_town(entry: Dictionary, position: Vector3) -> bool:
		var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
		var radius := float(entry.get("townRadius", 18)) * CELL
		var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
		return flat.length() <= radius

	func point_inside_work_area(entry: Dictionary, position: Vector3) -> bool:
		var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
		var radius_cells := float(entry.get("townRadius", 18))
		if String(entry.get("job", "")) == "forage":
			radius_cells += 24.0
		var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
		return flat.length() <= radius_cells * CELL

	func approach_cells_for_target(_entry: Dictionary, target_position: Vector3, _allow_outside := true) -> Array[Vector2i]:
		var target := world_cell(target_position)
		return [
			target + Vector2i(1, 0),
			target + Vector2i(-1, 0),
			target + Vector2i(0, 1),
			 target + Vector2i(0, -1)
		]


class LocalRevisionRouteSubstrateFixtureWorld:
	extends GeneratedTownRouteSubstrateFixtureWorld
	var tile_source_revisions := {Vector2i(0, 0): 1}

	func route_source_revision_for_cells(cells: Array) -> String:
		var tiles := {}
		for value in cells:
			if value is Vector2i:
				var cell: Vector2i = value
				tiles[Vector2i(floori(float(cell.x) / 16.0), floori(float(cell.y) / 16.0))] = true
		var keys: Array = tiles.keys()
		keys.sort()
		var parts: Array[String] = []
		for tile in keys:
			parts.append("%s:%d" % [str(tile), int(tile_source_revisions.get(tile, 1))])
		return "|".join(parts)

class SnapshotReuseRouteSubstrateFixtureWorld:
	extends GeneratedTownRouteSubstrateFixtureWorld
	var snapshot_build_count := 0
	var snapshot_aware_standability_count := 0
	var legacy_standability_count := 0

	func build_snapshot(entry: Dictionary, allow_outside := false, moving_home := false) -> Dictionary:
		snapshot_build_count += 1
		return super.build_snapshot(entry, allow_outside, moving_home)

	func cell_is_standable_goal_in_snapshot(_entry: Dictionary, snapshot: Dictionary, cell: Vector2i, _allow_outside := false, _moving_home := false) -> bool:
		snapshot_aware_standability_count += 1
		return snapshot.get("blocked", {}) is Dictionary and standable.has(cell)

	func cell_is_standable_goal(_entry: Dictionary, cell: Vector2i, _allow_outside := false, _moving_home := false) -> bool:
		legacy_standability_count += 1
		return standable.has(cell)


class CandidateOrderRouteSubstrateFixtureWorld:
	extends SnapshotReuseRouteSubstrateFixtureWorld
	var validated_cells: Array[Vector2i] = []

	func cell_is_standable_goal_in_snapshot(_entry: Dictionary, snapshot: Dictionary, cell: Vector2i, _allow_outside := false, _moving_home := false) -> bool:
		validated_cells.append(cell)
		return super.cell_is_standable_goal_in_snapshot(_entry, snapshot, cell, _allow_outside, _moving_home)


class ValidationCountingRouteSubstrateFixtureWorld:
	extends GeneratedTownRouteSubstrateFixtureWorld
	var validator_calls := 0
	var standable_validator_calls := 0
	var transition_validator_calls := 0

	func cell_is_standable_goal(_entry: Dictionary, cell: Vector2i, _allow_outside := false, _moving_home := false) -> bool:
		validator_calls += 1
		standable_validator_calls += 1
		return super.cell_is_standable_goal(_entry, cell, _allow_outside, _moving_home)

	func cell_transition_pathable(_entry: Dictionary, snapshot: Dictionary, from_cell: Vector2i, to_cell: Vector2i, target_cells: Dictionary, ignore_dynamic := false) -> Dictionary:
		validator_calls += 1
		transition_validator_calls += 1
		return super.cell_transition_pathable(_entry, snapshot, from_cell, to_cell, target_cells, ignore_dynamic)


class PlanTimingRecordingMonitor:
	extends RefCounted
	var events: Array[String] = []
	var durations := {}
	var counters := {}
	var gauges := {}

	func begin_section(name: String) -> int:
		events.append("begin:%s" % name)
		return events.size()

	func end_section(name: String, _start_usec: int) -> float:
		events.append("end:%s" % name)
		return 2.0 if name == "npc_routine_v2_plan" else 0.1

	func observe_external_duration(name: String, duration_ms: float) -> float:
		events.append("observe:%s" % name)
		durations[name] = duration_ms
		return duration_ms

	func increment_counter(name: String, amount := 1) -> void:
		events.append("counter:%s" % name)
		counters[name] = int(counters.get(name, 0)) + int(amount)

	func observe_gauge(name: String, value: float) -> void:
		events.append("gauge:%s" % name)
		gauges[name] = value


class PlanTimingProfileSubstrate:
	extends RefCounted
	var monitor = null
	var take_count := 0
	var last_plan_options := {}
	var timing_profile := {
		"snapshotUsec": 100,
		"validationUsec": 150,
		"validationCount": 1,
		"validationPreflightGoalUsec": 0,
		"validationPreflightGoalCount": 0,
		"validationPreflightStartUsec": 0,
		"validationPreflightStartCount": 0,
		"validationSearchTransitionUsec": 150,
		"validationSearchTransitionCount": 1,
		"validationFinalizeStartUsec": 0,
		"validationFinalizeStartCount": 0,
		"validationFinalizeTransitionUsec": 0,
		"validationFinalizeTransitionCount": 0,
		"loopGrossUsec": 1000,
		"doorSignatureUsec": 60,
		"doorSignatureCells": 6,
		"doorSignatureDoors": 1,
		"dynamicSignatureUsec": 70,
		"dynamicSignatureCells": 8,
		"dynamicSignatureOccupied": 2,
		"finalizationAssemblyUsec": 80,
		"cheapBookkeepingResidualUsec": 640,
		"cheapStepsThisCall": 37,
		"setupResidualUsec": 200,
		"totalUsec": 1300,
		"accountedUsec": 1300,
		"arithmeticBalanced": true
	}

	func candidate_poses_for_target(_entry: Dictionary, target: Dictionary, _semantic_kind: String, _options := {}) -> Dictionary:
		var target_cell: Vector2i = target.get("exactSlotCell", Vector2i(4, 0))
		return {
			"ok": true,
			"classification": "reachable",
			"candidates": [{ "cell": target_cell, "position": Vector3(float(target_cell.x) * CELL, 0.0, float(target_cell.y) * CELL) }],
			"candidateValidationsThisCall": 1,
			"candidateSnapshotRevision": "timing-profile-snapshot"
		}

	func plan_route(_entry: Dictionary, _start_cell: Vector2i, _candidate_cells: Array, options := {}) -> Dictionary:
		last_plan_options = options.duplicate(true) if options is Dictionary else {}
		return {
			"ok": false,
			"status": "pending_budget",
			"classification": "pending_budget",
			"reason": "validation_step_budget_deferred",
			"proof": { "validationStepsThisCall": 1, "expansionsThisCall": 0 }
		}

	func take_last_plan_timing_profile() -> Dictionary:
		take_count += 1
		if monitor != null:
			monitor.events.append("substrate:take_profile")
		var result := timing_profile.duplicate(true)
		timing_profile.clear()
		return result

func setup(owner) -> void:
	runner = owner

func cases() -> Array[Dictionary]:
	var ids = [
		["npc_route_same_tile_optimal_oracle", "test_route_same_tile_optimal_oracle"],
		["npc_route_multi_tile_hierarchy", "test_route_multi_tile_hierarchy"],
		["npc_route_cross_loaded_chunks", "test_route_cross_loaded_chunks"],
		["npc_route_road_preferred_equal_time", "test_route_road_preferred_equal_time"],
		["npc_route_hazard_avoided_by_civilian", "test_route_hazard_avoided_by_civilian"],
		["npc_route_guard_semantic_preference", "test_route_guard_semantic_preference"],
		["npc_route_profile_large_rejects_narrow_small_accepts", "test_route_profile_large_rejects_narrow_small_accepts"],
		["npc_route_closed_openable_door_action", "test_route_closed_openable_door_action"],
		["npc_route_locked_unauthorized_alternate", "test_route_locked_unauthorized_alternate"],
		["npc_route_start_snap_no_wall_cross", "test_route_start_snap_no_wall_cross"],
		["npc_route_goal_snap_correct_vertical_layer", "test_route_goal_snap_correct_vertical_layer"],
		["npc_route_corner_smoothing_capsule_safe", "test_route_corner_smoothing_capsule_safe"],
		["npc_route_mandatory_action_not_smoothed_out", "test_route_mandatory_action_not_smoothed_out"],
		["npc_route_no_iteration_cap_false_failure", "test_route_no_iteration_cap_false_failure"],
		["npc_route_pending_budget_resumes", "test_route_pending_budget_resumes"],
		["npc_route_authority_planning_budget_fairness", "test_route_authority_planning_budget_fairness"],
		["npc_route_authority_process_epoch_prevents_physics_budget_multiplication", "test_route_authority_process_epoch_prevents_physics_budget_multiplication"],
		["npc_route_authority_urgent_slice_preserves_normal_service", "test_route_authority_urgent_slice_preserves_normal_service"],
		["npc_route_authority_urgent_and_normal_atoms_share_hard_cap", "test_route_authority_urgent_and_normal_atoms_share_hard_cap"],
		["npc_route_authority_planning_grants_ignore_actor_update_order", "test_route_authority_planning_grants_ignore_actor_update_order"],
		["npc_route_authority_probe_budget_starvation_recovery", "test_route_authority_probe_budget_starvation_recovery"],
		["npc_route_authority_probe_repair_avoids_persist_across_budget", "test_route_authority_probe_repair_avoids_persist_across_budget"],
		["npc_route_authority_probe_repair_charges_actual_expansions", "test_route_authority_probe_repair_charges_actual_expansions"],
		["npc_route_authority_probe_repair_search_is_request_owned", "test_route_authority_probe_repair_search_is_request_owned"],
		["npc_route_player_watchdog_retains_collision_repair_progress", "test_route_player_watchdog_retains_collision_repair_progress"],
		["npc_route_authority_dynamic_probe_repairs_before_blocking", "test_route_authority_dynamic_probe_repairs_before_blocking"],
		["npc_route_authority_terrain_motion_probe_repairs_before_blocking", "test_route_authority_terrain_motion_probe_repairs_before_blocking"],
		["npc_route_authority_failed_goal_cells_exclude_only_failed_destinations", "test_route_authority_failed_goal_cells_exclude_only_failed_destinations"],
		["npc_route_authority_phase10_counters", "test_route_authority_phase10_counters"],
		["npc_route_authority_stuck_revokes_moving_lease", "test_route_authority_stuck_revokes_moving_lease"],
		["npc_route_lease_executor_skips_passed_non_door_waypoint", "test_route_lease_executor_skips_passed_non_door_waypoint"],
		["npc_route_lease_executor_reports_no_target_progress", "test_route_lease_executor_reports_no_target_progress"],
		["npc_route_partial_explicit_only", "test_route_partial_explicit_only"],
		["npc_route_unreachable_terminal_reason", "test_route_unreachable_terminal_reason"],
		["npc_route_deterministic_replay", "test_route_deterministic_replay"],
		["npc_route_navmesh_query_or_same_surface_returns_route", "test_route_navmesh_query_or_same_surface_returns_route"],
		["npc_route_navmesh_preserves_door_action_cells", "test_route_navmesh_preserves_door_action_cells"],
		["npc_route_navmesh_planner_goal_kinds", "test_route_navmesh_planner_goal_kinds"],
		["npc_route_navmesh_adapter_no_legacy_fallback", "test_route_navmesh_adapter_no_legacy_fallback"],
		["npc_route_routine_jobs_do_not_use_generated_cell_bridge", "test_route_routine_jobs_do_not_use_generated_cell_bridge"],
		["npc_route_runtime_planner_rejects_generated_cell_bridge", "test_route_runtime_planner_rejects_generated_cell_bridge"],
		["npc_route_generated_fallback_disabled_in_production", "test_route_generated_fallback_open_terrain_only"],
		["npc_route_diagnostic_generated_fallback_rejects_no_progress_partial", "test_route_generated_fallback_rejects_no_progress_partial"],
		["npc_route_probe_start_overlap_escape_outward_only", "test_route_probe_start_overlap_escape_outward_only"],
		["npc_route_probe_covers_terrain_body_layer", "test_route_probe_covers_terrain_body_layer"],
		["npc_route_probe_slice_preserves_grounded_sample_continuity", "test_route_probe_slice_preserves_grounded_sample_continuity"],
		["npc_route_probe_repair_cell_bridge_uses_fallback_goal", "test_route_probe_repair_cell_bridge_uses_fallback_goal"],
		["npc_route_probe_avoid_excludes_failed_candidate_goal", "test_route_probe_avoid_excludes_failed_candidate_goal"],
		["npc_route_runtime_door_uses_group_portal_id", "test_route_runtime_door_uses_group_portal_id"],
		["npc_route_collision_boundary_blocks_open_destination", "test_route_collision_boundary_blocks_open_destination"],
		["npc_route_collision_occupied_cell_blocks_node", "test_route_collision_occupied_cell_blocks_node"],
		["npc_route_navmesh_surfaces_exclude_collision_occupied_cells", "test_route_navmesh_surfaces_exclude_collision_occupied_cells"],
		["npc_route_diagnostic_home_collision_lattice_exact_detour", "test_route_home_collision_lattice_exact_detour"],
		["npc_route_scripted_collision_lattice_exact_detour", "test_route_scripted_collision_lattice_exact_detour"],
		["npc_route_diagnostic_home_collision_lattice_recenters_off_cell_start", "test_route_home_collision_lattice_recenters_off_cell_start"],
		["npc_route_home_egress_rejects_exact_collision_lattice", "test_route_home_egress_uses_exact_collision_lattice"],
		["npc_route_collision_door_requires_portal_axis", "test_route_collision_door_requires_portal_axis"],
		["npc_route_collision_rejects_diagonal_corner_cut", "test_route_collision_rejects_diagonal_corner_cut"],
		["npc_route_navmesh_post_validation_rejects_wall_cross", "test_route_navmesh_post_validation_rejects_wall_cross"],
		["npc_route_scripted_target_expands_navmesh_tiles", "test_route_scripted_target_expands_navmesh_tiles"],
		["npc_route_runtime_goal_adapter_uses_new_corridor", "test_route_runtime_goal_adapter_uses_new_corridor"],
		["npc_route_substrate_reachable_generated_town_fixture", "test_route_substrate_reachable_generated_town_fixture"],
		["npc_route_substrate_reuses_authoritative_snapshot_for_standability", "test_route_substrate_reuses_authoritative_snapshot_for_standability"],
		["npc_route_substrate_sliced_search_matches_unsliced", "test_route_substrate_sliced_search_matches_unsliced"],
		["npc_route_substrate_lazy_frontier_preserves_frozen_eager_tie_route", "test_route_substrate_lazy_frontier_preserves_frozen_eager_tie_route"],
		["npc_route_substrate_four_cardinal_production_budget_latency", "test_route_substrate_four_cardinal_production_budget_latency"],
		["npc_route_substrate_plan_timing_profile_contract", "test_route_substrate_plan_timing_profile_contract"],
		["npc_route_substrate_dynamic_signature_32_actor_progress", "test_route_substrate_dynamic_signature_32_actor_progress"],
		["npc_route_substrate_deferred_heap_exact_order", "test_route_substrate_deferred_heap_exact_order"],
		["npc_route_incremental_approach_certification", "test_route_incremental_approach_certification"],
		["npc_route_tile_local_search_source_revision", "test_route_tile_local_search_source_revision"],
		["npc_route_substrate_lazy_frontier_honors_cheaper_deferred_goal", "test_route_substrate_lazy_frontier_honors_cheaper_deferred_goal"],
		["npc_route_substrate_lazy_frontier_exhaustion_cleans_deferred_records", "test_route_substrate_lazy_frontier_exhaustion_cleans_deferred_records"],
		["npc_route_substrate_reordered_candidates_resume_job_order", "test_route_substrate_reordered_candidates_resume_job_order"],
		["npc_route_substrate_validation_microphases_resume_fresh_snapshot", "test_route_substrate_validation_microphases_resume_fresh_snapshot"],
		["npc_route_substrate_source_revision_invalidates_partial_neighbor", "test_route_substrate_source_revision_invalidates_partial_neighbor"],
		["npc_route_substrate_unrelated_static_publication_preserves_search", "test_route_substrate_unrelated_static_publication_preserves_search"],
		["npc_route_substrate_source_revision_invalidates_finalization", "test_route_substrate_source_revision_invalidates_finalization"],
		["npc_route_substrate_live_occupancy_restarts_finalization", "test_route_substrate_live_occupancy_restarts_finalization"],
		["npc_route_substrate_door_revision_restarts_finalization", "test_route_substrate_door_revision_restarts_finalization"],
		["npc_route_substrate_same_instance_door_lock_restarts_finalization", "test_route_substrate_same_instance_door_lock_restarts_finalization"],
		["npc_route_substrate_unrelated_door_change_preserves_finalization", "test_route_substrate_unrelated_door_change_preserves_finalization"],
		["npc_route_executor_shares_candidate_and_plan_validation_cap", "test_route_executor_shares_candidate_and_plan_validation_cap"],
		["npc_route_executor_plan_timing_minimal_publication_contract", "test_route_executor_plan_timing_minimal_publication_contract"],
		["npc_route_executor_plan_timing_publication_contract", "test_route_executor_plan_timing_publication_contract"],
		["npc_route_candidate_cache_is_request_and_revision_safe", "test_route_candidate_cache_is_request_and_revision_safe"],
		["npc_route_substrate_terminal_revalidation_evicts_search", "test_route_substrate_terminal_revalidation_evicts_search"],
		["npc_route_substrate_uses_actual_start_waypoint", "test_route_substrate_uses_actual_start_waypoint"],
		["npc_route_substrate_home_departure_clearance_exact_goal", "test_route_substrate_home_departure_clearance_exact_goal"],
		["npc_route_substrate_forage_search_anchor_exact_outside_goal", "test_route_substrate_forage_search_anchor_exact_outside_goal"],
		["npc_route_substrate_blocked_generated_town_fixture", "test_route_substrate_blocked_generated_town_fixture"],
		["npc_route_substrate_invalid_goal_generated_town_fixture", "test_route_substrate_invalid_goal_generated_town_fixture"],
		["npc_route_substrate_pending_generated_town_fixture", "test_route_substrate_pending_generated_town_fixture"],
		["npc_route_substrate_unrelated_door_state_preserves_incremental_search", "test_route_substrate_unrelated_door_state_preserves_incremental_search"],
		["npc_route_substrate_source_revision_restarts_incremental_search", "test_route_substrate_source_revision_restarts_incremental_search"],
		["npc_route_substrate_terrain_edit_revalidates_before_commit", "test_route_substrate_terrain_edit_revalidates_before_commit"],
		["npc_route_substrate_changed_collision_revalidates_before_commit", "test_route_substrate_changed_collision_revalidates_before_commit"]
	]
	var result: Array[Dictionary] = []
	for spec in ids:
		result.append({
			"id": str(spec[0]),
			"suite": "route",
			"timeModes": ["day", "night"],
			"callable": Callable(self, str(spec[1]))
		})
	return result

func test_route_same_tile_optimal_oracle(_mode: String) -> Dictionary:
	var setup = route_line_service(0, 2)
	var result = route_plan(setup.service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(2, 0, 0)) })
	var corridor = result.get("corridor")
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and corridor != null and corridor.steps.size() == 2
	return outcome(passed, "summary=%s" % JSON.stringify(route_summary(result)), ["same_tile_complete", "oracle_step_count"], { "route": route_summary(result) })

func test_route_multi_tile_hierarchy(_mode: String) -> Dictionary:
	var setup = route_line_service(14, 18)
	var result = route_plan(setup.service, route_span_key(Vector3i(14, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(18, 0, 0)) })
	var hierarchy: Dictionary = route_metrics(result).get("hierarchy", {})
	var corridor = result.get("corridor")
	var deps: Dictionary = corridor.dependencies if corridor != null else {}
	var tiles: Array = deps.get("tiles", [])
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and int(hierarchy.get("entranceCount", 0)) > 0 and tiles.has("0,0") and tiles.has("1,0")
	return outcome(passed, "hierarchy=%s deps=%s" % [JSON.stringify(hierarchy), JSON.stringify(deps)], ["abstract_entrance", "multi_tile_dependencies"], { "hierarchy": hierarchy, "dependencies": deps })

func test_route_cross_loaded_chunks(_mode: String) -> Dictionary:
	var setup = route_line_service(0, 34)
	var result = route_plan(setup.service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(34, 0, 0)) })
	var corridor = result.get("corridor")
	var tiles: Array = corridor.dependencies.get("tiles", []) if corridor != null else []
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and tiles.has("0,0") and tiles.has("1,0") and tiles.has("2,0")
	return outcome(passed, "tiles=%s cost=%.2f" % [JSON.stringify(tiles), float(result.get("cost"))], ["cross_loaded_chunks", "three_tile_path"], { "tiles": tiles, "route": route_summary(result) })

func test_route_road_preferred_equal_time(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(2, 0, 0)),
			nav_surface(Vector3i(0, 0, -1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(1, 0, -1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(2, 0, -1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(0, 0, 1), { "semanticRegionIds": ["terrain"] }),
			nav_surface(Vector3i(1, 0, 1), { "semanticRegionIds": ["terrain"] }),
			nav_surface(Vector3i(2, 0, 1), { "semanticRegionIds": ["terrain"] })
		]
	})
	var result = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(2, 0, 0)) })
	var semantics = corridor_semantics(result)
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and semantics.has("road") and not semantics.has("terrain")
	return outcome(passed, "semantics=%s summary=%s" % [JSON.stringify(semantics), JSON.stringify(route_summary(result))], ["road_preferred_equal_time", "semantic_cost_explainable"], { "semantics": semantics, "route": route_summary(result) })

func test_route_hazard_avoided_by_civilian(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(2, 0, 0)),
			nav_surface(Vector3i(0, 0, -1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(1, 0, -1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(2, 0, -1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(0, 0, 1), { "semanticRegionIds": ["hazard:bog"], "flags": { "hazard": true } }),
			nav_surface(Vector3i(1, 0, 1), { "semanticRegionIds": ["hazard:bog"], "flags": { "hazard": true } }),
			nav_surface(Vector3i(2, 0, 1), { "semanticRegionIds": ["hazard:bog"], "flags": { "hazard": true } })
		]
	})
	var result = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(2, 0, 0)) }, false, "work")
	var semantics = corridor_semantics(result)
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and not semantics.has("hazard:bog")
	return outcome(passed, "semantics=%s cost=%s" % [JSON.stringify(semantics), JSON.stringify(route_metrics(result).get("costBreakdown", {}))], ["civilian_hazard_avoided", "nonnegative_hazard_penalty"], { "semantics": semantics, "route": route_summary(result) })

func test_route_guard_semantic_preference(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(2, 0, 0)),
			nav_surface(Vector3i(0, 0, -1), { "semanticRegionIds": ["guard_post"] }),
			nav_surface(Vector3i(1, 0, -1), { "semanticRegionIds": ["guard_post"] }),
			nav_surface(Vector3i(2, 0, -1), { "semanticRegionIds": ["guard_post"] }),
			nav_surface(Vector3i(0, 0, 1), { "semanticRegionIds": ["terrain"] }),
			nav_surface(Vector3i(1, 0, 1), { "semanticRegionIds": ["terrain"] }),
			nav_surface(Vector3i(2, 0, 1), { "semanticRegionIds": ["terrain"] })
		]
	})
	var result = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(2, 0, 0)) }, false, "guard")
	var semantics = corridor_semantics(result)
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and semantics.has("guard_post")
	return outcome(passed, "semantics=%s" % JSON.stringify(semantics), ["guard_semantic_preference"], { "semantics": semantics, "route": route_summary(result) })

func test_route_profile_large_rejects_narrow_small_accepts(_mode: String) -> Dictionary:
	var small = TraversalProfileScript.default_adult_npc()
	small.body_radius = 0.20
	small.personal_space_margin = 0.04
	var large = TraversalProfileScript.default_adult_npc()
	large.body_radius = 0.55
	large.personal_space_margin = 0.10
	var surfaces = [nav_surface(Vector3i(0, 0, 0), { "lateralClearance": 0.40 }), nav_surface(Vector3i(1, 0, 0), { "lateralClearance": 0.40 })]
	var small_service = NavigationWorldServiceScript.new()
	small_service.build_tile_now(nav_snapshot("0,0", surfaces), small)
	var large_service = NavigationWorldServiceScript.new()
	large_service.build_tile_now(nav_snapshot("0,0", surfaces), large)
	var small_result = route_plan(small_service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(1, 0, 0)), "profile": small })
	var large_result = route_plan(large_service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(1, 0, 0)), "profile": large })
	var passed = small_result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and large_result.get("status") == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE
	return outcome(passed, "small=%s large=%s" % [JSON.stringify(route_summary(small_result)), JSON.stringify(route_summary(large_result))], ["small_profile_accepts", "large_profile_rejects"], { "small": route_summary(small_result), "large": route_summary(large_result) })

func test_route_closed_openable_door_action(_mode: String) -> Dictionary:
	var from_key = route_span_key(Vector3i(0, 0, 0))
	var to_key = route_span_key(Vector3i(1, 0, 0))
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(1, 0, 0))
		]
	}, {
		"0,0": {
			"doorPortals": [{ "id": "door:test", "state": "closed", "openable": true }],
			"doorLinks": [{ "from": from_key, "to": to_key, "portalId": "door:test", "cost": 1.0 }]
		}
	})
	var result = route_plan(service, from_key, { "kind": "exact_span", "spanKey": to_key })
	var corridor = result.get("corridor")
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and corridor != null and corridor.mandatory_action_count() == 1 and corridor.actions_by_cell().size() == 1
	var corridor_summary = corridor.to_summary() if corridor != null else {}
	return outcome(passed, "corridor=%s" % JSON.stringify(corridor_summary), ["closed_openable_door_action", "mandatory_action_present"], { "route": route_summary(result) })

func test_route_locked_unauthorized_alternate(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(1, 0, 0)),
			nav_surface(Vector3i(2, 0, 0)),
			nav_surface(Vector3i(0, 0, 1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(1, 0, 1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(2, 0, 1), { "semanticRegionIds": ["road"] })
		]
	})
	var tile = service.get_tile("0,0")
	var start_key = route_span_key(Vector3i(0, 0, 0))
	var locked_key = route_span_key(Vector3i(1, 0, 0))
	var locked_edge = tile.edge_between(start_key, locked_key)
	if locked_edge != null:
		locked_edge.traversal_kind = NpcEnumsScript.TRAVERSAL_KIND_DOOR
		locked_edge.required_capabilities.append(&"use_locked_doors")
		locked_edge.portal_id = "door:locked"
	var result = route_plan(service, start_key, { "kind": "exact_span", "spanKey": route_span_key(Vector3i(2, 0, 0)) })
	var semantics = corridor_semantics(result)
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and semantics.has("road")
	return outcome(passed, "semantics=%s route=%s" % [JSON.stringify(semantics), JSON.stringify(route_summary(result))], ["locked_unauthorized_rejected", "alternate_selected"], { "semantics": semantics, "route": route_summary(result) })

func test_route_start_snap_no_wall_cross(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({ "0,0": [nav_surface(Vector3i(1, 0, 0))] })
	var request = RouteRequestScript.new()
	request.request_id = "start-wall"
	request.start_position = Vector3.ZERO
	request.goal_spec = { "kind": "exact_span", "spanKey": route_span_key(Vector3i(1, 0, 0)), "maxStartSnap": 0.25 }
	var planner = HierarchicalRoutePlannerScript.new()
	planner.setup(service)
	var result = planner.plan_route(request, 32)
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE and str(result.get("reason")) == "no_start_span"
	return outcome(passed, "result=%s" % JSON.stringify(route_summary(result)), ["start_snap_no_wall_cross", "no_start_span_reason"], { "route": route_summary(result) })

func test_route_goal_snap_correct_vertical_layer(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 2, 0), { "worldPosition": Vector3(0.0, 2.7, 0.0) }),
			nav_surface(Vector3i(1, 2, 0), { "worldPosition": Vector3(NpcConstantsScript.CELL_SIZE, 2.7, 0.0) }),
			nav_surface(Vector3i(1, 0, 0), { "worldPosition": Vector3(NpcConstantsScript.CELL_SIZE, 0.0, 0.0) })
		]
	})
	var result = route_plan(service, route_span_key(Vector3i(0, 2, 0)), { "kind": "point_region", "center": Vector3(NpcConstantsScript.CELL_SIZE, 2.7, 0.0), "radius": 0.2, "verticalTolerance": 0.25 })
	var corridor = result.get("corridor")
	var last_cell = Vector3i.ZERO
	if corridor != null and not corridor.steps.is_empty():
		last_cell = corridor.steps[corridor.steps.size() - 1].get("cell")
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and last_cell.y == 2
	return outcome(passed, "last=%s route=%s" % [str(last_cell), JSON.stringify(route_summary(result))], ["goal_snap_vertical_layer"], { "lastCell": [last_cell.x, last_cell.y, last_cell.z], "route": route_summary(result) })

func test_route_corner_smoothing_capsule_safe(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(1, 0, 0)),
			nav_surface(Vector3i(2, 0, 0)),
			nav_surface(Vector3i(2, 0, 1))
		]
	})
	var result = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(2, 0, 1)) })
	var corridor = result.get("corridor")
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and corridor != null and corridor.smoothed and corridor.waypoints.size() <= corridor.steps.size() and not corridor.smoothing_rejected
	var corridor_summary = corridor.to_summary() if corridor != null else {}
	return outcome(passed, "corridor=%s" % JSON.stringify(corridor_summary), ["capsule_safe_smoothing", "smoothing_deterministic"], { "route": route_summary(result) })

func test_route_mandatory_action_not_smoothed_out(_mode: String) -> Dictionary:
	var from_key = route_span_key(Vector3i(0, 0, 0))
	var door_key = route_span_key(Vector3i(1, 0, 0))
	var goal_key = route_span_key(Vector3i(2, 0, 0))
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(1, 0, 0)),
			nav_surface(Vector3i(2, 0, 0))
		]
	}, {
		"0,0": {
			"doorPortals": [{ "id": "door:mid", "state": "closed", "openable": true }],
			"doorLinks": [{ "from": from_key, "to": door_key, "portalId": "door:mid", "cost": 1.0 }]
		}
	})
	var result = route_plan(service, from_key, { "kind": "exact_span", "spanKey": goal_key })
	var corridor = result.get("corridor")
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and corridor != null and corridor.mandatory_action_count() == 1 and corridor.waypoints.has(corridor.steps[0].get("world_position"))
	var corridor_summary = corridor.to_summary() if corridor != null else {}
	return outcome(passed, "corridor=%s" % JSON.stringify(corridor_summary), ["mandatory_action_preserved", "smoothing_keeps_action_waypoint"], { "route": route_summary(result) })

func test_route_no_iteration_cap_false_failure(_mode: String) -> Dictionary:
	var setup = route_line_service(0, 420)
	var result = route_plan(setup.service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(420, 0, 0), "26,0") }, false, "move", 200000)
	var corridor = result.get("corridor")
	var step_count = corridor.steps.size() if corridor != null else 0
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and step_count > 384
	return outcome(passed, "steps=%d status=%s" % [step_count, str(result.get("status"))], ["long_route_over_removed_cap", "no_false_iteration_failure"], { "steps": step_count, "route": route_summary(result) })

func test_route_pending_budget_resumes(_mode: String) -> Dictionary:
	var setup = route_line_service(0, 12)
	var request = route_request(route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(12, 0, 0)) })
	request.request_id = "pending-resume"
	var planner = HierarchicalRoutePlannerScript.new()
	planner.setup(setup.service)
	var first = planner.plan_route(request, 1)
	var final = first
	for _i in range(40):
		if final.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE:
			break
		final = planner.plan_route(request, 2)
	var passed = first.get("status") == NpcEnumsScript.ROUTE_STATUS_PENDING and final.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE
	return outcome(passed, "first=%s final=%s" % [str(first.get("status")), JSON.stringify(route_summary(final))], ["pending_budget", "resumes_to_terminal"], { "first": route_summary(first), "final": route_summary(final) })

func test_route_authority_planning_budget_fairness(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, BudgetedCollisionProbe.new())
	authority.plan_attempt_budget_per_frame = 1
	var first_entry := { "id": "budget-a" }
	var second_entry := { "id": "budget-b" }
	var first_request: Dictionary = authority.submit_request(first_entry, { "kind": "work", "priority": 10 }, { "priority": 10 })
	var second_request: Dictionary = authority.submit_request(second_entry, { "kind": "work", "priority": 10 }, { "priority": 10 })
	var first_claim: Dictionary = authority.claim_planning_budget(String(first_request.get("requestId", "")), "test_plan")
	var deferred: Dictionary = authority.claim_planning_budget(String(second_request.get("requestId", "")), "test_plan")
	for _frame in range(NpcRouteAuthorityV2Script.PLANNING_STARVATION_FRAME_LIMIT):
		authority.begin_frame()
	authority.claim_planning_budget(String(first_request.get("requestId", "")), "test_plan")
	var recovered: Dictionary = authority.claim_planning_budget(String(second_request.get("requestId", "")), "test_plan")
	var stats: Dictionary = authority.stats()
	var counters: Dictionary = stats.get("counters", {})
	var passed := bool(first_claim.get("granted", false)) \
		and not bool(deferred.get("granted", true)) \
		and String(deferred.get("state", "")) == "pending_budget" \
		and bool(recovered.get("granted", false)) \
		and bool(recovered.get("starvationOverride", false)) \
		and int(counters.get("planningBudgetDeferrals", 0)) >= 1 \
		and int(counters.get("planningStarvationOverrides", 0)) >= 1 \
		and int(counters.get("maxPlanningWaitFrames", 0)) >= NpcRouteAuthorityV2Script.PLANNING_STARVATION_FRAME_LIMIT
	return outcome(
		passed,
		"first=%s deferred=%s recovered=%s counters=%s" % [JSON.stringify(authority_summary(first_claim)), JSON.stringify(authority_summary(deferred)), JSON.stringify(authority_summary(recovered)), JSON.stringify(counters)],
		["planning_budget_bounded", "planning_starvation_override", "queue_wait_counted"],
		{ "first": authority_summary(first_claim), "deferred": authority_summary(deferred), "recovered": authority_summary(recovered), "counters": counters }
	)


func test_route_authority_process_epoch_prevents_physics_budget_multiplication(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, BudgetedCollisionProbe.new())
	var requests: Array[Dictionary] = []
	for index in range(5):
		var entry := { "id": "process-epoch-%d" % index }
		requests.append(authority.submit_request(entry, { "kind": "work", "priority": 50 }, { "priority": 50 }))
	authority.begin_frame(101)
	var first_epoch_grants := 0
	for index in range(4):
		var claim: Dictionary = authority.claim_planning_budget(String(requests[index].get("requestId", "")), "first_physics_tick")
		if bool(claim.get("granted", false)):
			first_epoch_grants += 1
	var serial_after_first: int = int(authority.frame_serial)
	authority.begin_frame(101)
	var repeated_epoch_claim: Dictionary = authority.claim_planning_budget(String(requests[4].get("requestId", "")), "second_physics_tick_same_process_frame")
	var serial_after_repeat: int = int(authority.frame_serial)
	authority.begin_frame(102)
	var next_epoch_claim: Dictionary = authority.claim_planning_budget(String(requests[4].get("requestId", "")), "next_process_frame")
	var passed: bool = first_epoch_grants == int(authority.plan_attempt_budget_per_frame) \
		and not bool(repeated_epoch_claim.get("granted", true)) \
		and serial_after_repeat == serial_after_first \
		and bool(next_epoch_claim.get("granted", false)) \
		and authority.frame_serial == serial_after_first + 1
	return outcome(
		passed,
		"first=%d serial=%d repeated=%s next=%s finalSerial=%d" % [first_epoch_grants, serial_after_first, JSON.stringify(authority_summary(repeated_epoch_claim)), JSON.stringify(authority_summary(next_epoch_claim)), authority.frame_serial],
		["planning_budget_resets_once_per_process_epoch", "physics_catchup_does_not_multiply_route_work", "next_process_epoch_restores_service"],
		{ "firstEpochGrants": first_epoch_grants, "serialAfterFirst": serial_after_first, "serialAfterRepeat": serial_after_repeat, "repeatedEpoch": authority_summary(repeated_epoch_claim), "nextEpoch": authority_summary(next_epoch_claim), "finalSerial": authority.frame_serial }
	)


func test_route_authority_urgent_slice_preserves_normal_service(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, BudgetedCollisionProbe.new())
	authority.plan_attempt_budget_per_frame = 4
	authority.route_search_expansion_budget_per_frame = 8
	var urgent_request: Dictionary = authority.submit_request({ "id": "urgent-home" }, { "kind": "home", "priority": 190 }, { "priority": 190 })
	var normal_request: Dictionary = authority.submit_request({ "id": "normal-work" }, { "kind": "work", "priority": 140 }, { "priority": 140 })
	authority.begin_frame()
	# Claim in the less favorable order: grants must be decided independently of actor update order.
	var normal_claim: Dictionary = authority.claim_planning_budget(String(normal_request.get("requestId", "")), "normal_first")
	var urgent_claim: Dictionary = authority.claim_planning_budget(String(urgent_request.get("requestId", "")), "urgent_second")
	var stats: Dictionary = authority.stats()
	var urgent_expansions := int(urgent_claim.get("routeSearchExpansions", 0))
	var normal_expansions := int(normal_claim.get("routeSearchExpansions", 0))
	var used_expansions := int(stats.get("routeSearchExpansionsUsedThisFrame", 0))
	var passed: bool = bool(urgent_claim.get("granted", false)) \
		and bool(normal_claim.get("granted", false)) \
		and urgent_expansions == NpcRouteAuthorityV2Script.URGENT_ROUTE_SEARCH_EXPANSIONS_PER_REQUEST \
		and normal_expansions == NpcRouteAuthorityV2Script.DEFAULT_ROUTE_SEARCH_EXPANSIONS_PER_REQUEST \
		and urgent_expansions == normal_expansions \
		and used_expansions <= authority.route_search_expansion_budget_per_frame
	return outcome(
		passed,
		"urgent=%s normal=%s stats=%s" % [JSON.stringify(authority_summary(urgent_claim)), JSON.stringify(authority_summary(normal_claim)), JSON.stringify(stats)],
		["urgent_collision_search_slice", "normal_service_reserved", "route_search_budget_bounded"],
		{ "urgent": authority_summary(urgent_claim), "normal": authority_summary(normal_claim), "stats": stats }
	)

func test_route_authority_planning_grants_ignore_actor_update_order(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, BudgetedCollisionProbe.new())
	authority.plan_attempt_budget_per_frame = 4
	var requests: Array[Dictionary] = []
	for actor_index in range(6):
		var actor_id := "ordered-%d" % actor_index
		var priority := 190 if actor_index == 5 else 140
		requests.append(authority.submit_request({ "id": actor_id }, { "kind": "home", "priority": priority }, { "priority": priority }))
	authority.begin_frame()
	var first_frame_grants: Array[String] = []
	var serviced := {}
	for request in requests:
		var request_id := String(request.get("requestId", ""))
		var claim: Dictionary = authority.claim_planning_budget(request_id, "ordered_actor_update")
		if bool(claim.get("granted", false)):
			first_frame_grants.append(request_id)
			serviced[request_id] = true
	var high_request_id := String(requests[5].get("requestId", ""))
	authority.begin_frame()
	var second_frame_grants: Array[String] = []
	for request in requests:
		var request_id := String(request.get("requestId", ""))
		var claim: Dictionary = authority.claim_planning_budget(request_id, "ordered_actor_update")
		if bool(claim.get("granted", false)):
			second_frame_grants.append(request_id)
			serviced[request_id] = true
	var passed: bool = first_frame_grants.size() == 4 \
		and first_frame_grants.has(high_request_id) \
		and second_frame_grants.size() == 4 \
		and second_frame_grants.has(high_request_id) \
		and serviced.size() == requests.size()
	return outcome(
		passed,
		"first=%s second=%s high=%s serviced=%d" % [JSON.stringify(first_frame_grants), JSON.stringify(second_frame_grants), high_request_id, serviced.size()],
		["planning_priority_independent_of_update_order", "mixed_queue_fills_all_four_attempts", "normal_requests_rotate_fairly"],
		{
			"firstFrameGrants": first_frame_grants,
			"secondFrameGrants": second_frame_grants,
			"highPriorityRequestId": high_request_id,
			"servicedRequestCount": serviced.size()
		}
	)

func test_route_authority_probe_budget_starvation_recovery(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	var probe := BudgetedCollisionProbe.new()
	probe.required_samples = 3
	authority.setup(null, null, probe)
	authority.probe_sample_budget_per_frame = 1
	var entry := { "id": "probe-starved" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "work", "priority": 10 }, { "priority": 10 })
	var request_id := String(request.get("requestId", ""))
	var route := authority_test_route(3)
	var intent := { "kind": "work", "targetCell": Vector2i(3, 0) }
	var first: Dictionary = authority.commit_route_after_probe(entry, request_id, route, intent, {})
	authority.probe_samples_used_this_frame = authority.probe_sample_budget_per_frame
	var deferred: Dictionary = authority.commit_route_after_probe(entry, request_id, route, intent, {})
	for _frame in range(NpcRouteAuthorityV2Script.PROBE_STARVATION_FRAME_LIMIT):
		authority.begin_frame()
	var final := deferred
	for _attempt in range(4):
		authority.probe_samples_used_this_frame = authority.probe_sample_budget_per_frame
		final = authority.commit_route_after_probe(entry, request_id, route, intent, {})
		if String(final.get("state", "")) == "ready":
			break
		authority.begin_frame()
	var stats: Dictionary = authority.stats()
	var counters: Dictionary = stats.get("counters", {})
	var passed := String(first.get("state", "")) == "probing" \
		and String(deferred.get("state", "")) == "probing" \
		and String(final.get("state", "")) == "ready" \
		and int(counters.get("probeBudgetDeferrals", 0)) >= 1 \
		and int(counters.get("probeStarvationOverrides", 0)) >= 1 \
		and int(counters.get("maxProbeWaitFrames", 0)) >= NpcRouteAuthorityV2Script.PROBE_STARVATION_FRAME_LIMIT
	return outcome(
		passed,
		"first=%s deferred=%s final=%s counters=%s" % [JSON.stringify(authority_summary(first)), JSON.stringify(authority_summary(deferred)), JSON.stringify(authority_summary(final)), JSON.stringify(counters)],
		["probe_budget_bounded", "probe_starvation_override", "probe_wait_counted"],
		{ "first": authority_summary(first), "deferred": authority_summary(deferred), "final": authority_summary(final), "counters": counters }
	)

func test_route_authority_probe_repair_avoids_persist_across_budget(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	var probe := CrossFrameRepairProbe.new()
	var substrate := RecordingRepairSubstrate.new()
	authority.setup(null, null, probe)
	var entry := { "id": "probe-repair-persistent" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "forage", "targetCell": Vector2i(4, 0) }, {})
	var request_id := String(request.get("requestId", ""))
	var route := authority_test_route(4)
	var intent := { "kind": "forage", "targetCell": Vector2i(4, 0) }
	var options := {
		"repairSubstrate": substrate,
		"repairStartCell": Vector2i.ZERO,
		"repairCandidateCells": [Vector2i(4, 0)],
		"repairPlanOptions": {},
		"maxProbeRepairAttempts": 3
	}
	var first: Dictionary = authority.commit_route_after_probe(entry, request_id, route, intent, options)
	var resumed: Dictionary = authority.runtime_for_entry(entry)
	var resumed_avoids: Array = resumed.get("probeRepairAvoidCells", []) if resumed.get("probeRepairAvoidCells", []) is Array else []
	var final := first
	for _attempt in range(8):
		if String(final.get("state", "")) in ["ready", "unreachable_static", "blocked_dynamic", "invalid_goal"]:
			break
		authority.begin_frame()
		var runtime: Dictionary = authority.runtime_for_entry(entry)
		var continued_route: Dictionary = runtime.get("route", {}) if runtime.get("route", {}) is Dictionary else {}
		if continued_route.is_empty():
			continued_route = route
		final = authority.commit_route_after_probe(entry, request_id, continued_route, intent, options)
	var second_avoids: Array = substrate.avoid_history[1] if substrate.avoid_history.size() > 1 and substrate.avoid_history[1] is Array else []
	var passed := String(first.get("state", "")) == "probing" \
		and String(final.get("state", "")) == "ready" \
		and resumed_avoids.has(Vector2i(2, 0)) \
		and second_avoids.has(Vector2i(2, 0)) \
		and second_avoids.has(Vector2i(3, 0))
	return outcome(
		passed,
		"first=%s resumed=%s final=%s avoids=%s" % [JSON.stringify(authority_summary(first)), JSON.stringify(authority_summary(resumed)), JSON.stringify(authority_summary(final)), JSON.stringify(substrate.avoid_history)],
		["probe_repair_avoids_survive_budget_boundary", "runtime_summary_preserves_probe_repair_avoidance", "probe_repair_does_not_rediscover_prior_blocker"],
		{ "first": authority_summary(first), "resumed": authority_summary(resumed), "final": authority_summary(final), "avoidHistory": substrate.avoid_history }
	)

func test_route_authority_probe_repair_charges_actual_expansions(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	var probe := DynamicActorRepairProbe.new()
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var real_substrate = CollisionBackedRouteSubstrateScript.new()
	real_substrate.setup(fixture)
	var substrate := InstrumentedRepairSubstrate.new()
	substrate.inner = real_substrate
	authority.setup(null, null, probe)
	var entry := fixture.generated_town_entry()
	entry["id"] = "actual-repair-expansions"
	var request: Dictionary = authority.submit_request(entry, { "kind": "home", "targetCell": Vector2i(4, 0) }, { "priority": 140 })
	var request_id := String(request.get("requestId", ""))
	var route := authority_test_route(4)
	var intent := { "kind": "home", "targetCell": Vector2i(4, 0) }
	var options := {
		"repairSubstrate": substrate,
		"repairStartCell": Vector2i.ZERO,
		"repairCandidateCells": [Vector2i(4, 0)],
		"repairPlanOptions": { "allowOutside": true, "maxExpansions": 128 },
		"maxProbeRepairAttempts": 3
	}
	var result: Dictionary = authority.commit_route_after_probe(entry, request_id, route, intent, options)
	var used_per_repair_call: Array[int] = []
	for _attempt in range(128):
		if String(result.get("state", "")) in ["ready", "unreachable_static", "blocked_dynamic", "invalid_goal"]:
			break
		authority.begin_frame()
		var history_before := substrate.actual_expansions.size()
		var runtime: Dictionary = authority.runtime_for_entry(entry)
		var current_route: Dictionary = runtime.get("route", {}) if runtime.get("route", {}) is Dictionary else {}
		if current_route.is_empty():
			current_route = route
		result = authority.commit_route_after_probe(entry, request_id, current_route, intent, options)
		if substrate.actual_expansions.size() > history_before:
			used_per_repair_call.append(int(authority.stats().get("routeSearchExpansionsUsedThisFrame", 0)))
	var all_requested_two := not substrate.requested_expansions.is_empty()
	var all_validation_steps_two := substrate.requested_validation_steps.size() == substrate.requested_expansions.size()
	var all_actual_bounded := not substrate.actual_expansions.is_empty()
	var actual_expansion_total := 0
	for value in substrate.requested_expansions:
		all_requested_two = all_requested_two and value == 2
	for value in substrate.requested_validation_steps:
		all_validation_steps_two = all_validation_steps_two and value == 2
	for value in substrate.actual_expansions:
		all_actual_bounded = all_actual_bounded and value >= 0 and value <= 2
		actual_expansion_total += value
	var charges_match_actual := used_per_repair_call.size() == substrate.actual_expansions.size()
	var saw_zero_expansion_refund := false
	for index in range(used_per_repair_call.size()):
		var charged := used_per_repair_call[index]
		var actual := substrate.actual_expansions[index] if index < substrate.actual_expansions.size() else -1
		charges_match_actual = charges_match_actual and charged == actual and charged <= authority.route_search_expansion_budget_per_frame
		saw_zero_expansion_refund = saw_zero_expansion_refund or (actual == 0 and charged == 0)
	var passed := String(result.get("state", "")) == "ready" \
		and probe.probe_calls == 2 \
		and substrate.actual_expansions.size() > 1 \
		and actual_expansion_total > 0 \
		and all_requested_two \
		and all_validation_steps_two \
		and all_actual_bounded \
		and charges_match_actual \
		and saw_zero_expansion_refund
	return outcome(
		passed,
		"result=%s probes=%d requested=%s validationSteps=%s actual=%s charged=%s" % [JSON.stringify(authority_summary(result)), probe.probe_calls, JSON.stringify(substrate.requested_expansions), JSON.stringify(substrate.requested_validation_steps), JSON.stringify(substrate.actual_expansions), JSON.stringify(used_per_repair_call)],
		["probe_failure_queues_repair_without_inline_search", "real_repair_search_expands_at_most_two_nodes_per_call", "repair_route_validation_is_capped_at_two_steps_per_call", "repair_slices_charge_only_actual_expansions", "zero_expansion_slice_refunds_full_reservation", "repaired_route_is_probed_before_ready"],
		{ "result": authority_summary(result), "probeCalls": probe.probe_calls, "requestedExpansions": substrate.requested_expansions, "requestedValidationSteps": substrate.requested_validation_steps, "actualExpansions": substrate.actual_expansions, "chargedExpansions": used_per_repair_call }
	)

func test_route_authority_probe_repair_search_is_request_owned(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	var probe := DynamicActorRepairProbe.new()
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	authority.setup(null, null, probe)
	var entry := fixture.generated_town_entry()
	entry["id"] = "repair-request-owned"
	var request: Dictionary = authority.submit_request(entry, { "kind": "home", "targetCell": Vector2i(5, 0) }, { "priority": 140 })
	var request_id := String(request.get("requestId", ""))
	var route := authority_test_route(5)
	var intent := { "kind": "home", "targetCell": Vector2i(5, 0) }
	var options := {
		"repairSubstrate": substrate,
		"repairStartCell": Vector2i.ZERO,
		"repairCandidateCells": [Vector2i(5, 0)],
		# Deliberately omit requestIdentity: the authority must impose ownership.
		"repairPlanOptions": { "allowOutside": true, "maxExpansions": 128 },
		"maxProbeRepairAttempts": 3
	}
	var queued: Dictionary = authority.commit_route_after_probe(entry, request_id, route, intent, options)
	authority.begin_frame()
	var pending: Dictionary = authority.commit_route_after_probe(entry, request_id, route, intent, options)
	var census_before: Dictionary = substrate.candidate_cache_census()
	var executor = NpcPlanExecutorScript.new()
	executor.home_route_substrate = substrate
	authority.cancel_request(request_id, "repair_request_cancelled")
	var removed := executor.evict_route_candidate_cache_for_request(request_id)
	var census_after: Dictionary = substrate.candidate_cache_census()
	var passed := String(queued.get("state", "")) == "probing" \
		and String(pending.get("state", "")) == "probing" \
		and int(census_before.get("searchJobCount", 0)) == 1 \
		and int(census_before.get("searchActorCount", 0)) == 1 \
		and removed == 1 \
		and int(census_after.get("searchJobCount", -1)) == 0 \
		and int(census_after.get("searchActorCount", -1)) == 0
	return outcome(
		passed,
		"queued=%s pending=%s removed=%d before=%s after=%s" % [JSON.stringify(authority_summary(queued)), JSON.stringify(authority_summary(pending)), removed, JSON.stringify(census_before), JSON.stringify(census_after)],
		["resumed_probe_repair_search_inherits_request_identity", "cancelled_probe_repair_search_is_evicted", "repair_search_actor_census_returns_to_zero"],
		{ "queued": authority_summary(queued), "pending": authority_summary(pending), "removed": removed, "censusBefore": census_before, "censusAfter": census_after }
	)

func test_route_player_watchdog_retains_collision_repair_progress(_mode: String) -> Dictionary:
	var watchdog = LiveRoutePlanningProgressWatchdogScript.new()
	watchdog.setup(0.0, 4.0, 3.0, 20.0)
	var base := {
		"requestId": "player:v2:repair:1",
		"status": "pending_budget",
		"reason": "search_budget_deferred",
		"authority": {
			"requestId": "player:v2:repair:1",
			"state": "pending_budget",
			"lastServicedFrame": 10,
			"pendingBudgetFrames": 1,
			"probeRepairAvoidCells": []
		},
		"details": {
			"route": {
				"searchExpansions": 16,
				"searchVisited": 16,
				"probeSamples": 0,
				"repairAttempt": 0
			}
		}
	}
	var initial: Dictionary = watchdog.observe(base, 0.25)
	var repaired := base.duplicate(true)
	repaired["authority"]["lastServicedFrame"] = 260
	repaired["authority"]["pendingBudgetFrames"] = 251
	repaired["authority"]["probeRepairAvoidCells"] = [Vector2i(7, 3)]
	repaired["details"]["route"]["repairAttempt"] = 1
	var beyond_soft: Dictionary = watchdog.observe(repaired, 4.5)
	var resumed := repaired.duplicate(true)
	resumed["authority"]["lastServicedFrame"] = 370
	resumed["details"]["route"]["searchExpansions"] = 48
	resumed["details"]["route"]["searchVisited"] = 44
	var continued: Dictionary = watchdog.observe(resumed, 6.25)
	var stalled: Dictionary = watchdog.observe(resumed, 9.5)
	var hard_watchdog = LiveRoutePlanningProgressWatchdogScript.new()
	hard_watchdog.setup(0.0, 4.0, 3.0, 20.0)
	hard_watchdog.observe(base, 0.25)
	var hard_stopped: Dictionary = hard_watchdog.observe(repaired, 20.0)
	var passed := bool(initial.get("continue", false)) \
		and bool(beyond_soft.get("continue", false)) \
		and bool(beyond_soft.get("softExceeded", false)) \
		and bool(beyond_soft.get("progressed", false)) \
		and bool(continued.get("continue", false)) \
		and bool(continued.get("progressed", false)) \
		and not bool(stalled.get("continue", true)) \
		and String(stalled.get("reason", "")) == "no_progress_timeout" \
		and not bool(hard_stopped.get("continue", true)) \
		and String(hard_stopped.get("reason", "")) == "hard_timeout" \
		and String((continued.get("marker", {}) as Dictionary).get("requestId", "")) == "player:v2:repair:1"
	return outcome(
		passed,
		"initial=%s beyondSoft=%s continued=%s stalled=%s hard=%s" % [JSON.stringify(initial), JSON.stringify(beyond_soft), JSON.stringify(continued), JSON.stringify(stalled), JSON.stringify(hard_stopped)],
		["same_request_retained_beyond_four_seconds_while_repair_progresses", "search_progress_extends_bounded_window", "no_progress_stops_diagnostically", "hard_timeout_remains_bounded"],
		{
			"initial": initial,
			"beyondSoft": beyond_soft,
			"continued": continued,
			"stalled": stalled,
			"hard": hard_stopped
		}
	)


func test_route_authority_dynamic_probe_repairs_before_blocking(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	var probe := DynamicActorRepairProbe.new()
	var substrate := RecordingRepairSubstrate.new()
	authority.setup(null, null, probe)
	var entry := { "id": "dynamic-probe-repair" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "home", "targetCell": Vector2i(4, 0) }, { "priority": 140 })
	var request_id := String(request.get("requestId", ""))
	var route := authority_test_route(4)
	var options := {
		"repairSubstrate": substrate,
		"repairStartCell": Vector2i.ZERO,
		"repairCandidateCells": [Vector2i(4, 0)],
		"repairPlanOptions": { "probeRepairAvoidRadius": 1 },
		"maxProbeRepairAttempts": 3
	}
	var intent := { "kind": "home", "targetCell": Vector2i(4, 0) }
	var result: Dictionary = authority.commit_route_after_probe(entry, request_id, route, intent, options)
	for _attempt in range(4):
		if String(result.get("state", "")) == "ready":
			break
		authority.begin_frame()
		var runtime: Dictionary = authority.runtime_for_entry(entry)
		var current_route: Dictionary = runtime.get("route", {}) if runtime.get("route", {}) is Dictionary else {}
		result = authority.commit_route_after_probe(entry, request_id, current_route if not current_route.is_empty() else route, intent, options)
	var first_avoids: Array = substrate.avoid_history[0] if not substrate.avoid_history.is_empty() and substrate.avoid_history[0] is Array else []
	var first_radius := int(substrate.repair_radius_history[0]) if not substrate.repair_radius_history.is_empty() else 0
	var passed := String(result.get("state", "")) == "ready" \
		and probe.probe_calls == 2 \
		and first_avoids.has(Vector2i(2, 0)) \
		and first_radius == 1
	return outcome(
		passed,
		"result=%s probes=%d avoids=%s radius=%d" % [JSON.stringify(authority_summary(result)), probe.probe_calls, JSON.stringify(first_avoids), first_radius],
		["dynamic_character_body_probe_classified", "dynamic_probe_repaired_before_commit", "dynamic_clearance_cells_avoided", "repaired_route_requires_clear_probe"],
		{ "result": authority_summary(result), "probeCalls": probe.probe_calls, "avoidCells": first_avoids, "repairAvoidRadius": first_radius }
	)

func test_route_authority_terrain_motion_probe_repairs_before_blocking(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	var probe := TerrainMotionRepairProbe.new()
	var substrate := RecordingRepairSubstrate.new()
	authority.setup(null, null, probe)
	var entry := { "id": "terrain-motion-probe-repair" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "home", "targetCell": Vector2i(4, 0) }, { "priority": 140 })
	var request_id := String(request.get("requestId", ""))
	var route := authority_test_route(4)
	var options := {
		"repairSubstrate": substrate,
		"repairStartCell": Vector2i.ZERO,
		"repairCandidateCells": [Vector2i(4, 0)],
		"repairPlanOptions": {},
		"maxProbeRepairAttempts": 3
	}
	var intent := { "kind": "home", "targetCell": Vector2i(4, 0) }
	var result: Dictionary = authority.commit_route_after_probe(entry, request_id, route, intent, options)
	for _attempt in range(4):
		if String(result.get("state", "")) == "ready":
			break
		authority.begin_frame()
		var runtime: Dictionary = authority.runtime_for_entry(entry)
		var current_route: Dictionary = runtime.get("route", {}) if runtime.get("route", {}) is Dictionary else {}
		result = authority.commit_route_after_probe(entry, request_id, current_route if not current_route.is_empty() else route, intent, options)
	var first_avoids: Array = substrate.avoid_history[0] if not substrate.avoid_history.is_empty() and substrate.avoid_history[0] is Array else []
	var first_radius := int(substrate.repair_radius_history[0]) if not substrate.repair_radius_history.is_empty() else 0
	var passed: bool = String(result.get("state", "")) == "ready" \
		and probe.probe_calls == 2 \
		and first_avoids.has(Vector2i(2, 0)) \
		and first_radius == 0
	return outcome(
		passed,
		"result=%s probes=%d avoids=%s radius=%d" % [JSON.stringify(authority_summary(result)), probe.probe_calls, JSON.stringify(first_avoids), first_radius],
		["terrain_motion_probe_classified_as_static", "terrain_motion_probe_repaired_before_commit", "sample_world_position_becomes_repair_avoid_cell", "terrain_motion_repair_avoids_exact_failed_sample"],
		{ "result": authority_summary(result), "probeCalls": probe.probe_calls, "avoidCells": first_avoids, "repairAvoidRadius": first_radius }
	)

func test_route_authority_failed_goal_cells_exclude_only_failed_destinations(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	var probe := RepeatingTerrainMotionRepairProbe.new()
	var substrate := RecordingRepairSubstrate.new()
	authority.setup(null, null, probe)
	var entry := { "id": "failed-goal-cell-recording" }
	var target := Vector2i(4, 0)
	var request: Dictionary = authority.submit_request(entry, { "kind": "scripted", "targetCell": target }, { "priority": 140 })
	var request_id := String(request.get("requestId", ""))
	var route := authority_test_route(4)
	var intent := { "kind": "scripted", "targetCell": target }
	var options := {
		"repairSubstrate": substrate,
		"repairStartCell": Vector2i.ZERO,
		"repairCandidateCells": [target],
		"repairPlanOptions": {},
		"maxProbeRepairAttempts": 3
	}
	var result: Dictionary = authority.commit_route_after_probe(entry, request_id, route, intent, options)
	for _attempt in range(10):
		if String(result.get("state", "")) in ["unreachable_static", "blocked_dynamic", "invalid_goal", "ready"]:
			break
		authority.begin_frame()
		var runtime: Dictionary = authority.runtime_for_entry(entry)
		var current_route: Dictionary = runtime.get("route", {}) if runtime.get("route", {}) is Dictionary else {}
		result = authority.commit_route_after_probe(entry, request_id, current_route if not current_route.is_empty() else route, intent, options)
	var failed_goals: Array = result.get("probeRepairFailedGoalCells", []) if result.get("probeRepairFailedGoalCells", []) is Array else []
	var passed: bool = String(result.get("state", "")) == "unreachable_static" \
		and probe.probe_calls == 4 \
		and failed_goals.size() == 1 \
		and failed_goals.has(target)
	return outcome(
		passed,
		"result=%s probes=%d failedGoals=%s" % [JSON.stringify(authority_summary(result)), probe.probe_calls, JSON.stringify(failed_goals)],
		["terrain_probe_failure_records_failed_goal", "failed_goal_cells_do_not_expand_to_intermediate_repair_avoids"],
		{ "result": authority_summary(result), "probeCalls": probe.probe_calls, "failedGoals": failed_goals }
	)

func test_route_authority_phase10_counters(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, BudgetedCollisionProbe.new())
	var arrived_entry := { "id": "counter-arrived" }
	var dynamic_entry := { "id": "counter-dynamic" }
	var static_entry := { "id": "counter-static" }
	var repair_entry := { "id": "counter-repair" }
	var arrived_request: Dictionary = authority.submit_request(arrived_entry, { "kind": "work" }, {})
	var dynamic_request: Dictionary = authority.submit_request(dynamic_entry, { "kind": "work" }, {})
	var static_request: Dictionary = authority.submit_request(static_entry, { "kind": "work" }, {})
	var repair_request: Dictionary = authority.submit_request(repair_entry, { "kind": "work" }, {})
	authority.report_arrived(String(arrived_request.get("requestId", "")), "test_arrived")
	authority.report_blocked_dynamic(String(dynamic_request.get("requestId", "")), "test_dynamic")
	authority.report_unreachable_static(String(static_request.get("requestId", "")), "test_static")
	authority.report_route_repair(String(repair_request.get("requestId", "")), "test_route_repair", {})
	authority.report_stuck(String(repair_request.get("requestId", "")), "test_stuck", {})
	var counters: Dictionary = authority.stats().get("counters", {})
	var passed := int(counters.get("successfulArrivals", 0)) >= 1 \
		and int(counters.get("dynamicBlocks", 0)) >= 1 \
		and int(counters.get("staticUnreachable", 0)) >= 1 \
		and int(counters.get("routeRepairs", 0)) >= 1 \
		and int(counters.get("stuckRecovery", 0)) >= 1
	return outcome(
		passed,
		"counters=%s" % JSON.stringify(counters),
		["successful_arrivals_counted", "dynamic_blocks_counted", "static_unreachable_counted", "route_repairs_counted", "stuck_recovery_counted"],
		{ "counters": counters }
	)

func test_route_authority_stuck_revokes_moving_lease(_mode: String) -> Dictionary:
	var probe := BudgetedCollisionProbe.new()
	probe.required_samples = 1
	var authority = NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, probe)
	var entry := { "id": "stuck-authority-npc" }
	var request: Dictionary = authority.submit_request(entry, { "kind": "home", "targetCell": Vector2i(1, 0) }, { "priority": 120 })
	var request_id := String(request.get("requestId", ""))
	var route := {
		"ok": true,
		"status": "reachable",
		"reason": "route_found",
		"source": "test_collision_route",
		"cells": [Vector2i(0, 0), Vector2i(1, 0)],
		"waypoints": [Vector3.ZERO, Vector3(CELL, 0.0, 0.0)],
		"actions": {},
		"targetCell": Vector2i(1, 0)
	}
	var ready: Dictionary = authority.commit_route_after_probe(entry, request_id, route, { "kind": "home", "targetCell": Vector2i(1, 0) })
	var moving: Dictionary = authority.begin_moving(request_id, "test_move")
	var stuck: Dictionary = authority.report_stuck(request_id, "stuck", { "stuckKind": "no_target_progress" })
	var debug: Dictionary = authority.debug_for_entry(entry)
	var passed := String(ready.get("state", "")) == "ready" \
		and String(moving.get("state", "")) == "moving" \
		and String(stuck.get("state", "")) == "blocked_dynamic" \
		and String(stuck.get("reason", "")) == "stuck" \
		and not bool(stuck.get("hasLease", true)) \
		and String(debug.get("state", "")) == "blocked_dynamic" \
		and String(entry.get("routeStatus", "")) == "blocked" \
		and String(entry.get("routeReason", "")) == "stuck" \
		and not entry.has("routeLease")
	return outcome(
		passed,
		"ready=%s moving=%s stuck=%s debug=%s entry=%s" % [JSON.stringify(authority_summary(ready)), JSON.stringify(authority_summary(moving)), JSON.stringify(authority_summary(stuck)), JSON.stringify(authority_summary(debug)), JSON.stringify(entry)],
		["stuck_transitions_to_blocked_dynamic", "stuck_revokes_lease", "entry_publishes_blocked_status"],
		{ "ready": authority_summary(ready), "moving": authority_summary(moving), "stuck": authority_summary(stuck), "debug": authority_summary(debug), "entry": entry }
	)

func test_route_lease_executor_skips_passed_non_door_waypoint(_mode: String) -> Dictionary:
	var authority := FakeLeaseAuthority.new()
	var executor = NpcRouteLeaseExecutorScript.new()
	executor.setup(authority, null, null)
	var body := CharacterBody3D.new()
	if runner != null:
		runner.add_child(body)
	body.global_position = Vector3(0.0, 0.0, -0.30)
	var entry := {
		"id": "lease-skip-npc",
		"body": body
	}
	var lease := {
		"state": "ready",
		"cells": [Vector2i(0, 0), Vector2i(0, -1)],
		"waypoints": [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, -CELL)],
		"actions": {},
		"probeCertificate": { "ok": true, "authoritative": true }
	}
	var result: Dictionary = executor.execute(entry, "lease-skip-request", lease, 1.0 / 60.0, {
		"speed": 2.6,
		"waypointRadius": 0.18
	})
	var skip_completed := authority.completed_segments.duplicate()
	var skipped_non_door := authority.completed_segments.has(0) \
		and int(entry.get("_v2LeaseExecutorWaypointIndex", 0)) >= 1 \
		and body.global_position.z < -0.30
	executor = NpcRouteLeaseExecutorScript.new()
	authority = FakeLeaseAuthority.new()
	executor.setup(authority, null, null)
	var door := Node3D.new()
	if runner != null:
		runner.add_child(door)
	door.global_position = Vector3.ZERO
	body = CharacterBody3D.new()
	if runner != null:
		runner.add_child(body)
	body.global_position = Vector3(0.0, 0.0, -0.30)
	entry = {
		"id": "lease-door-npc",
		"body": body
	}
	var door_lease := {
		"state": "ready",
		"cells": [Vector2i(0, 0), Vector2i(0, -1)],
		"waypoints": [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, -CELL)],
		"actions": {
			"0,0": {
				"kind": "door",
				"enabled": true,
				"door": door,
				"entryPosition": Vector3.ZERO
			}
		},
		"probeCertificate": { "ok": true, "authoritative": true }
	}
	var door_result: Dictionary = executor.execute(entry, "lease-door-request", door_lease, 1.0 / 60.0, {
		"speed": 2.6,
		"waypointRadius": 0.18
	})
	var preserved_door_action := authority.completed_segments.is_empty() \
		and int(entry.get("_v2LeaseExecutorWaypointIndex", 0)) == 0 \
		and String(door_result.get("reason", "")) == "missing_door_traversal_service"
	var passed := skipped_non_door and preserved_door_action
	return outcome(
		passed,
		"skip=%s result=%s completed=%s doorResult=%s doorCompleted=%s" % [str(skipped_non_door), JSON.stringify(result), JSON.stringify(skip_completed), JSON.stringify(door_result), JSON.stringify(authority.completed_segments)],
		["lease_executor_skips_passed_non_door_waypoint", "lease_executor_preserves_door_action_waypoint"],
		{ "skipResult": result, "doorResult": door_result, "passedNonDoor": skipped_non_door, "preservedDoor": preserved_door_action }
	)

func test_route_lease_executor_reports_no_target_progress(_mode: String) -> Dictionary:
	var authority := FakeLeaseAuthority.new()
	var executor = NpcRouteLeaseExecutorScript.new()
	executor.setup(authority, null, null)
	executor.motor = FakeNoProgressMotor.new()
	var body := CharacterBody3D.new()
	if runner != null:
		runner.add_child(body)
	body.global_position = Vector3.ZERO
	var entry := {
		"id": "lease-no-progress-npc",
		"body": body
	}
	var lease := {
		"state": "ready",
		"cells": [Vector2i(0, 0), Vector2i(4, 0)],
		"waypoints": [Vector3(CELL * 4.0, 0.0, 0.0)],
		"actions": {},
		"probeCertificate": { "ok": true, "authoritative": true }
	}
	var result := {}
	for _i in range(12):
		result = executor.execute(entry, "lease-no-progress-request", lease, 0.10, {
			"speed": 2.6,
			"waypointRadius": 0.18
		})
		if String(result.get("reason", "")) == "stuck":
			break
	var details: Dictionary = result.get("details", {}) if result.get("details", {}) is Dictionary else {}
	var passed := String(result.get("reason", "")) == "stuck" \
		and String(details.get("stuckKind", "")) == "no_target_progress" \
		and not authority.stuck_reports.is_empty() \
		and int(entry.get("_v2LeaseExecutorWaypointIndex", 0)) == 0
	return outcome(
		passed,
		"result=%s stuckReports=%s position=%s" % [JSON.stringify(result), JSON.stringify(authority.stuck_reports), str(body.global_position)],
		["lease_executor_reports_slide_without_target_progress", "authority_receives_repairable_stuck_event"],
		{ "result": result, "stuckReports": authority.stuck_reports, "position": body.global_position }
	)

func test_route_partial_explicit_only(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(1, 0, 0)),
			nav_surface(Vector3i(5, 0, 0))
		]
	})
	var blocked = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(5, 0, 0)) }, false)
	var partial = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(5, 0, 0)) }, true)
	var passed = blocked.get("status") == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE and partial.get("status") == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE
	return outcome(passed, "blocked=%s partial=%s" % [JSON.stringify(route_summary(blocked)), JSON.stringify(route_summary(partial))], ["partial_endpoint_rejected", "partial_not_arrival"], { "blocked": route_summary(blocked), "partial": route_summary(partial) })

func test_route_unreachable_terminal_reason(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(4, 0, 0))
		]
	})
	var result = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(4, 0, 0)) })
	var passed = result.call("is_terminal") and result.get("status") == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE and result.get("reason") == NpcEnumsScript.ROUTE_REASON_NO_ROUTE
	return outcome(passed, "result=%s" % JSON.stringify(route_summary(result)), ["unreachable_terminal", "machine_reason"], { "route": route_summary(result) })

func test_route_deterministic_replay(_mode: String) -> Dictionary:
	var setup = route_line_service(0, 8)
	var first = route_plan(setup.service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(8, 0, 0)) })
	var second = route_plan(setup.service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(8, 0, 0)) })
	var first_summary = JSON.stringify(route_summary(first))
	var second_summary = JSON.stringify(route_summary(second))
	var passed = first_summary == second_summary
	return outcome(passed, "first=%s second=%s" % [first_summary, second_summary], ["deterministic_replay"], { "first": route_summary(first), "second": route_summary(second) })

func test_route_navmesh_query_or_same_surface_returns_route(_mode: String) -> Dictionary:
	var service = navmesh_test_service("query-path", Vector3(0.0, 0.0, 0.0), Vector3(10.8, 0.0, 5.4))
	var closest_start: Dictionary = service.closest_walkable(Vector3(0.2, 0.0, 0.2), 10.0)
	var closest_target: Dictionary = service.closest_walkable(Vector3(8.8, 0.0, 3.8), 10.0)
	var route: Dictionary = service.query_route(Vector3(0.2, 0.0, 0.2), Vector3(8.8, 0.0, 3.8), { "kind": "scripted" })
	var stats: Dictionary = service.stats()
	service.clear()
	var query_api := String(route.get("queryApi", ""))
	var same_surface_direct_ok := query_api != "descriptor_direct_endpoint" or (
		String(closest_start.get("surfaceId", "")) != ""
		and String(closest_start.get("surfaceId", "")) == String(closest_target.get("surfaceId", ""))
	)
	var passed := bool(route.get("ok", false)) \
		and String(route.get("source", "")) == "navmesh" \
		and query_api in ["query_path", "map_get_path", "descriptor_direct_endpoint"] \
		and same_surface_direct_ok \
		and (route.get("path", []) as Array).size() >= 1 \
		and int(stats.get("pathQueryCount", 0)) == 1 \
		and int(stats.get("pathQueryFailureCount", -1)) == 0
	return outcome(passed, "route=%s start=%s target=%s stats=%s" % [JSON.stringify(navmesh_route_summary(route)), JSON.stringify(closest_start), JSON.stringify(closest_target), JSON.stringify(stats)], ["navmesh_query_or_same_surface_returns_route", "descriptor_direct_requires_same_surface", "navmesh_query_records_metrics"], { "route": navmesh_route_summary(route), "closestStart": closest_start, "closestTarget": closest_target, "stats": stats })

func test_route_navmesh_preserves_door_action_cells(_mode: String) -> Dictionary:
	var planner = NavmeshRoutePlannerScript.new()
	var action_cell := Vector2i(280, 26)
	var actions := {
		"280,26": {
			"kind": "door",
			"cell": action_cell,
			"entryCell": Vector2i(280, 25),
			"direction": "z+"
		}
	}
	var condensed_cells: Array[Vector2i] = [Vector2i(279, 26), Vector2i(278, 26), Vector2i(276, 26)]
	var preserved: Array[Vector2i] = planner._preserve_route_action_cells(condensed_cells, actions)
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	service.register_chunk_descriptor(navmesh_door_descriptor("region:chunk:door-action-cell", "door-action-cell", "door:action-cell"))
	var route: Dictionary = service.query_route(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 2.7), { "maxSnapDistance": 4.0 })
	var route_actions: Dictionary = route.get("actions", {})
	var emitted_action := {}
	for action_value in route_actions.values():
		if action_value is Dictionary and String((action_value as Dictionary).get("portalId", "")) == "door:action-cell":
			emitted_action = action_value
			break
	var stats: Dictionary = service.stats()
	service.clear()
	var action_preserved := not preserved.is_empty() and preserved[0] == action_cell
	var direction_preserved := String(emitted_action.get("direction", "")) == "z+"
	var entry_cell_preserved := emitted_action.get("entryCell") is Vector2i
	var passed := action_preserved and bool(route.get("ok", false)) and not emitted_action.is_empty() and direction_preserved and entry_cell_preserved and int(stats.get("pathQueryFailureCount", 0)) == 0
	return outcome(passed, "preserved=%s route=%s action=%s stats=%s" % [JSON.stringify(vec2i_array_summary(preserved)), JSON.stringify(navmesh_route_summary(route)), JSON.stringify(emitted_action), JSON.stringify(stats)], ["navmesh_preserves_door_action_cell_after_waypoint_prune", "navmesh_door_action_direction_matches_link"], { "preserved": vec2i_array_summary(preserved), "route": navmesh_route_summary(route), "action": emitted_action, "stats": stats })

func test_route_navmesh_planner_goal_kinds(_mode: String) -> Dictionary:
	var service = navmesh_test_service("goal-kinds", Vector3(-2.7, 0.0, -2.7), Vector3(14.85, 0.0, 6.75))
	service.sync_navigation_map_if_dirty()
	var planner = NavmeshRoutePlannerScript.new()
	planner.setup(service, null, null, null)
	var body := Node3D.new()
	runner.add_child(body)
	body.global_position = Vector3(0.0, 0.0, 0.0)
	var entry := {
		"id": "navmesh_goal_test",
		"body": body,
		"porchPosition": Vector3.ZERO,
		"townCenter": Vector2i.ZERO,
		"townRadius": 12
	}
	var kinds := ["home", "guard", "job", "forage", "scripted"]
	var results := {}
	for index in range(kinds.size()):
		var kind := String(kinds[index])
		var target := Vector3(2.7 + float(index) * 2.025, 0.0, 2.7)
		var intent := {
			"kind": kind,
			"target": target,
			"targetCell": Vector2i(roundi(target.x / NpcConstantsScript.CELL_SIZE), roundi(target.z / NpcConstantsScript.CELL_SIZE)),
			"allowOutside": kind in ["job", "forage"],
			"movingHome": kind == "home",
			"arrivalRadius": NpcConstantsScript.CELL_SIZE * 0.72,
			"strictArrival": kind == "scripted"
		}
		var route: Dictionary = planner.plan_runtime_route(entry, intent, null, 0)
		results[kind] = navmesh_route_dictionary_summary(route)
	body.free()
	var stats: Dictionary = service.stats()
	service.clear()
	var passed := true
	for kind in kinds:
		var summary: Dictionary = results.get(kind, {})
		passed = passed and bool(summary.get("ok", false)) and String(summary.get("source", "")) == "navmesh" and not bool(summary.get("legacyFallbackUsed", true))
	passed = passed and int(stats.get("pathQueryCount", 0)) == kinds.size()
	return outcome(passed, "results=%s stats=%s" % [JSON.stringify(results), JSON.stringify(stats)], ["navmesh_routes_home_guard_job_forage_scripted", "navmesh_planner_no_legacy_fallback"], { "results": results, "stats": stats })

func test_route_navmesh_adapter_no_legacy_fallback(_mode: String) -> Dictionary:
	var adapter_text = read_text("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")
	var planner_text = read_text("res://scripts/npc_ai/routing/NavmeshRoutePlanner.gd")
	var service_text = read_text("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
	var passed = adapter_text.find("NavmeshRoutePlannerScript") >= 0 \
		and adapter_text.find("navmesh_planner.plan_runtime_route") >= 0 \
		and adapter_text.find("generated_corridor_planner") < 0 \
		and adapter_text.find("HierarchicalRoutePlannerScript") < 0 \
		and adapter_text.find("route_from_cells") < 0 \
		and adapter_text.find("MAX_ITERATIONS") < 0 \
		and planner_text.find("path_crosses_static_collision") >= 0 \
		and planner_text.find("validate_waypoint_route") >= 0 \
		and planner_text.find("legacyFallbackUsed") >= 0 \
		and service_text.find("query_path") >= 0
	return outcome(passed, "adapterNavmesh=%d generatedFallback=%d validation=%d queryPath=%d" % [adapter_text.find("NavmeshRoutePlannerScript"), adapter_text.find("generated_corridor_planner"), planner_text.find("validate_waypoint_route"), service_text.find("query_path")], ["adapter_uses_navmesh_authority", "navmesh_routes_are_collision_validated_before_acceptance", "live_adapter_has_no_generated_corridor_fallback"], {})

func test_route_routine_jobs_do_not_use_generated_cell_bridge(_mode: String) -> Dictionary:
	var adapter = NpcRouteCoordinatorAdapterScript.new()
	adapter.world = RefCounted.new()
	adapter.navmesh_planner = RefCounted.new()
	var entry := {
		"id": "test-worker",
		"job": "forage",
		"jobPhase": "searching",
		"routePriority": 90
	}
	var results := {}
	var passed := true
	for kind in ["guard", "work", "forage", "job"]:
		var intent := {
			"kind": kind,
			"movingHome": false,
			"priority": 90,
			"target": Vector3(CELL * 4.0, 0.0, 0.0),
			"targetCell": Vector2i(4, 0)
		}
		var allowed := bool(adapter._should_try_generated_cell_job_route(entry, intent))
		results[kind] = allowed
		passed = passed and not allowed
	var forage_departure := bool(adapter._should_try_prebudget_forage_departure_route(entry, {
		"kind": "forage",
		"target": Vector3(CELL * 6.0, 0.0, 0.0),
		"targetCell": Vector2i(6, 0)
	}))
	results["prebudgetForageDeparture"] = forage_departure
	passed = passed and not forage_departure
	return outcome(passed, "generatedBridgeEligibility=%s" % JSON.stringify(results), ["routine_jobs_wait_for_collision_navmesh", "forage_departure_no_cell_bridge"], { "results": results })

func test_route_runtime_planner_rejects_generated_cell_bridge(_mode: String) -> Dictionary:
	var planner = NavmeshRoutePlannerScript.new()
	var results := {}
	var passed := true
	for kind in ["guard", "work", "forage", "job", "home", "scripted", "idle", "move"]:
		var intent := { "kind": kind, "movingHome": kind == "home" }
		var allowed := bool(planner._generated_cell_bridge_allowed_for_intent(intent))
		var initial_allowed := bool(planner._initial_failure_cell_bridge_allowed({}, intent, { "reason": "navmesh_tile_budget" }))
		var generated_route: Dictionary = planner.plan_generated_cell_route({}, intent, null)
		results[kind] = {
			"allowed": allowed,
			"initialAllowed": initial_allowed,
			"directRouteEmpty": generated_route.is_empty()
		}
		passed = passed and not allowed and not initial_allowed and generated_route.is_empty()
	return outcome(passed, "runtimeBridge=%s" % JSON.stringify(results), ["runtime_planner_rejects_cell_bridge", "npc_routes_require_collision_navmesh"], { "results": results })

func test_route_generated_fallback_open_terrain_only(_mode: String) -> Dictionary:
	var adapter = NpcRouteCoordinatorAdapterScript.new()
	adapter.world = GeneratedFallbackWorld.new()
	adapter.navmesh_planner = RefCounted.new()
	var body := Node3D.new()
	runner.add_child(body)
	body.global_position = Vector3.ZERO
	var entry := {
		"id": "test-open-forager",
		"body": body,
		"insideHome": false,
		"activeDoorPortalId": "",
		"doorCell": Vector2i(100, 100),
		"porchCell": Vector2i(100, 101),
		"homeCell": Vector2i(101, 100)
	}
	var open_intent := {
		"kind": "forage",
		"target": Vector3(CELL * 6.0, 0.0, 0.0),
		"targetCell": Vector2i(6, 0),
		"movingHome": false,
		"allowOutside": true
	}
	var home_intent := open_intent.duplicate(true)
	home_intent["kind"] = "home"
	home_intent["movingHome"] = true
	var inside_entry := entry.duplicate(true)
	inside_entry["insideHome"] = true
	var door_adjacent_entry := entry.duplicate(true)
	door_adjacent_entry["doorCell"] = Vector2i(1, 0)
	var long_intent := open_intent.duplicate(true)
	long_intent["target"] = Vector3(CELL * 40.0, 0.0, 0.0)
	long_intent["targetCell"] = Vector2i(40, 0)
	var action_intent := open_intent.duplicate(true)
	action_intent["action"] = "open_door"

	var planner = NavmeshRoutePlannerScript.new()
	var flagged_open_intent := open_intent.duplicate(true)
	flagged_open_intent["safeOpenTerrainGeneratedFallback"] = true
	var flagged_home_intent := home_intent.duplicate(true)
	flagged_home_intent["safeOpenTerrainGeneratedFallback"] = true
	var results := {
		"home": bool(adapter._should_try_generated_cell_home_route(entry, home_intent)),
		"insideHome": bool(adapter._should_try_generated_cell_job_route(inside_entry, open_intent)),
		"doorAdjacent": bool(adapter._should_try_generated_cell_job_route(door_adjacent_entry, open_intent)),
		"longRoute": bool(adapter._should_try_generated_cell_job_route(entry, long_intent)),
		"explicitAction": bool(adapter._should_try_generated_cell_job_route(entry, action_intent)),
		"openForage": bool(adapter._should_try_generated_cell_job_route(entry, open_intent)),
		"openForagePrebudget": bool(adapter._should_try_prebudget_forage_departure_route(entry, open_intent)),
		"plannerUnflagged": bool(planner._generated_cell_bridge_allowed_for_intent(open_intent)),
		"plannerFlaggedOpen": bool(planner._generated_cell_bridge_allowed_for_intent(flagged_open_intent)),
		"plannerFlaggedHome": bool(planner._generated_cell_bridge_allowed_for_intent(flagged_home_intent))
	}
	body.free()
	var passed := not bool(results["home"]) \
		and not bool(results["insideHome"]) \
		and not bool(results["doorAdjacent"]) \
		and not bool(results["longRoute"]) \
		and not bool(results["explicitAction"]) \
		and not bool(results["openForage"]) \
		and not bool(results["openForagePrebudget"]) \
		and not bool(results["plannerUnflagged"]) \
		and not bool(results["plannerFlaggedOpen"]) \
		and not bool(results["plannerFlaggedHome"])
	return outcome(
		passed,
		"generatedFallbackGuard=%s" % JSON.stringify(results),
		["home_route_fallback_disabled", "inside_home_fallback_disabled", "door_adjacent_fallback_disabled", "open_terrain_forage_fallback_disabled"],
		{ "results": results }
	)

func test_route_generated_fallback_rejects_no_progress_partial(_mode: String) -> Dictionary:
	var setup := collision_adapter_with_blocks([])
	var adapter = setup.get("adapter")
	var body := setup.get("body") as Node3D
	var start_cell := Vector2i.ZERO
	var target_cell := Vector2i(4, 0)
	body.position = adapter.cell_position(start_cell)
	body.global_position = body.position
	var entry := {
		"id": "generated-no-progress-guard",
		"body": body,
		"insideHome": false,
		"townCenter": Vector2i.ZERO,
		"townRadius": 128,
		"porchPosition": adapter.cell_position(start_cell)
	}
	var intent := {
		"kind": "guard",
		"target": adapter.cell_position(target_cell),
		"targetCell": target_cell,
		"allowOutside": true,
		"movingHome": false,
		"arrivalRadius": CELL * 0.72,
		"allowPartial": true,
		"safeOpenTerrainGeneratedFallback": true,
		"fallbackCells": [start_cell],
		"priority": 170
	}
	var failed_route := {
		"ok": false,
		"status": "blocked",
		"reason": "navmesh_tile_budget",
		"source": "navmesh",
		"targetCell": target_cell
	}
	var planner = NavmeshRoutePlannerScript.new()
	planner.setup(null, null, null, adapter)
	var route: Dictionary = planner.plan_generated_cell_route(entry, intent, adapter)
	var bridge_debug: Dictionary = failed_route.get("generatedCellBridge", {}) if failed_route.get("generatedCellBridge", {}) is Dictionary else {}
	var direct_failed_route := failed_route.duplicate(true)
	var direct_route: Dictionary = planner._plan_generated_cell_bridge_route(entry, intent, adapter, start_cell, target_cell, direct_failed_route)
	var direct_debug: Dictionary = direct_failed_route.get("generatedCellBridge", {}) if direct_failed_route.get("generatedCellBridge", {}) is Dictionary else {}
	var passed: bool = route.is_empty() \
		and direct_route.is_empty() \
		and String(direct_debug.get("reason", "")) == "generated_cell_bridge_no_progress" \
		and direct_debug.get("fallbackCell", Vector2i(999999, 999999)) == start_cell
	free_collision_setup(setup)
	return outcome(
		passed,
		"route=%s bridge=%s direct=%s directBridge=%s" % [JSON.stringify(route), JSON.stringify(bridge_debug), JSON.stringify(direct_route), JSON.stringify(direct_debug)],
		["generated_fallback_partial_requires_forward_progress", "no_progress_partial_not_authority_candidate"],
		{ "route": navmesh_route_dictionary_summary(route), "directRoute": navmesh_route_dictionary_summary(direct_route), "directBridge": direct_debug }
	)

func test_route_probe_start_overlap_escape_outward_only(_mode: String) -> Dictionary:
	var service = CollisionProbeServiceScript.new()
	var body := CharacterBody3D.new()
	runner.add_child(body)
	var current_sample := Vector3(CELL * 0.34, 0.0, 0.0)
	body.position = current_sample
	body.global_position = current_sample
	var block := collision_block(Vector2i.ZERO, "stoneBlock")
	runner.add_child(block)
	block.position = Vector3.ZERO
	block.global_position = Vector3.ZERO
	var door := collision_door(Vector2i.ZERO)
	runner.add_child(door)
	door.position = Vector3.ZERO
	door.global_position = Vector3.ZERO
	var outward_sample := Vector3(CELL * 0.90, 0.0, 0.0)
	var inward_sample := Vector3(CELL * 0.12, 0.0, 0.0)
	var lateral_sample := Vector3(CELL * 0.34, 0.0, CELL * 0.90)
	var supports_block_escape: bool = service._collider_type_supports_start_overlap_escape(block)
	var supports_door_escape: bool = service._collider_type_supports_start_overlap_escape(door)
	var outward_allowed: bool = service._sample_moves_away_from_collider(block, current_sample, outward_sample)
	var inward_allowed: bool = service._sample_moves_away_from_collider(block, current_sample, inward_sample)
	var lateral_allowed: bool = service._sample_moves_away_from_collider(block, current_sample, lateral_sample)
	var current_distance: float = service._flat_distance_to_collider(block, current_sample)
	var outward_distance: float = service._flat_distance_to_collider(block, outward_sample)
	var inward_distance: float = service._flat_distance_to_collider(block, inward_sample)
	var lateral_distance: float = service._flat_distance_to_collider(block, lateral_sample)
	var passed := supports_block_escape \
		and not supports_door_escape \
		and outward_allowed \
		and not inward_allowed \
		and not lateral_allowed
	body.free()
	block.free()
	door.free()
	return outcome(
		passed,
		"blockEscape=%s doorEscape=%s outward=%s inward=%s lateral=%s distances=%.3f/%.3f/%.3f/%.3f" % [str(supports_block_escape), str(supports_door_escape), str(outward_allowed), str(inward_allowed), str(lateral_allowed), current_distance, outward_distance, inward_distance, lateral_distance],
		["probe_escape_only_for_static_start_overlap", "probe_escape_requires_outward_motion", "door_overlap_not_silently_escaped"],
		{
			"supportsBlockEscape": supports_block_escape,
			"supportsDoorEscape": supports_door_escape,
			"outwardAllowed": outward_allowed,
			"inwardAllowed": inward_allowed,
			"lateralAllowed": lateral_allowed,
			"currentDistance": current_distance,
			"outwardDistance": outward_distance,
			"inwardDistance": inward_distance,
			"lateralDistance": lateral_distance
		}
	)

func test_route_probe_covers_terrain_body_layer(_mode: String) -> Dictionary:
	var service = CollisionProbeServiceScript.new()
	var terrain := StaticBody3D.new()
	terrain.set_meta("kind", "terrain")
	var path := collision_block(Vector2i.ZERO, "cobblestonePath")
	var body := CharacterBody3D.new()
	body.collision_mask = NpcConstantsScript.COLLISION_WORLD_QUERY | NpcConstantsScript.COLLISION_TERRAIN_BODY
	body.floor_max_angle = deg_to_rad(46.0)
	var static_mask := service.route_blocking_collision_mask()
	var terrain_motion_mask := service.terrain_motion_collision_mask(body)
	var terrain_is_motion_blocking := service._is_terrain_collider(terrain)
	var walkable_support_blocks := service._terrain_contact_blocks_motion(body, Vector3(0.0, 0.99, 0.0))
	var lateral_wall_blocks := service._terrain_contact_blocks_motion(body, Vector3(1.0, 0.0, 0.0))
	var over_limit_slope_blocks := service._terrain_contact_blocks_motion(body, Vector3(0.866, 0.50, 0.0))
	var path_is_nonblocking := service._collider_allowed_for_route({}, path, { "actions": {} })
	var passed := (static_mask & NpcConstantsScript.COLLISION_WORLD_QUERY) != 0 \
		and (static_mask & NpcConstantsScript.COLLISION_TERRAIN_BODY) == 0 \
		and (terrain_motion_mask & NpcConstantsScript.COLLISION_TERRAIN_BODY) != 0 \
		and (terrain_motion_mask & NpcConstantsScript.COLLISION_NONBLOCKING_PATH) == 0 \
		and terrain_is_motion_blocking \
		and not walkable_support_blocks \
		and lateral_wall_blocks \
		and over_limit_slope_blocks \
		and path_is_nonblocking
	terrain.free()
	path.free()
	body.free()
	return outcome(
		passed,
		"staticMask=%d terrainMotionMask=%d terrainMotionBlocking=%s walkableSupportBlocks=%s lateralWallBlocks=%s overLimitSlopeBlocks=%s pathNonblocking=%s" % [static_mask, terrain_motion_mask, str(terrain_is_motion_blocking), str(walkable_support_blocks), str(lateral_wall_blocks), str(over_limit_slope_blocks), str(path_is_nonblocking)],
		["static_overlap_excludes_support_floor", "terrain_uses_character_body_motion_probe", "walkable_terrain_support_does_not_block_route", "lateral_or_over_limit_terrain_blocks_route", "decorative_path_remains_nonblocking"],
		{
			"staticMask": static_mask,
			"terrainMotionMask": terrain_motion_mask,
			"terrainMotionBlocking": terrain_is_motion_blocking,
			"walkableSupportBlocks": walkable_support_blocks,
			"lateralWallBlocks": lateral_wall_blocks,
			"overLimitSlopeBlocks": over_limit_slope_blocks,
			"pathNonblocking": path_is_nonblocking
		}
	)

func test_route_probe_slice_preserves_grounded_sample_continuity(_mode: String) -> Dictionary:
	var main := ElevationRouteTestMain.new()
	runner.add_child(main)
	var body := CharacterBody3D.new()
	main.add_child(body)
	body.collision_mask = NpcConstantsScript.COLLISION_TERRAIN_BODY
	body.global_position = Vector3.ZERO
	var service = CollisionProbeServiceScript.new()
	service.setup(null, main)
	var entry := { "id": "probe-continuity", "body": body }
	var first_segment_end := Vector3(CollisionProbeServiceScript.MAX_SAMPLE_SPACING * 2.0, 0.0, 0.0)
	var route := {
		"waypoints": [
			first_segment_end,
			first_segment_end + Vector3(0.0, 0.0, CollisionProbeServiceScript.MAX_SAMPLE_SPACING * 2.0)
		],
		"actions": {}
	}
	var unsliced_pass: Dictionary = service.probe_route(entry, route, {}, { "maxSamples": 256 })
	var sliced_pass: Dictionary = {}
	var sliced_cursor := {}
	var boundary_cursor := {}
	var sliced_calls := 0
	while sliced_calls < 16:
		sliced_calls += 1
		sliced_pass = service.probe_route(entry, route, {}, { "maxSamples": 1, "cursor": sliced_cursor })
		var details: Dictionary = sliced_pass.get("details", {}) if sliced_pass.get("details", {}) is Dictionary else {}
		if String(sliced_pass.get("status", "")) != "pending_probe":
			break
		sliced_cursor = details.get("cursor", {}) if details.get("cursor", {}) is Dictionary else {}
		if int(sliced_cursor.get("segmentIndex", -1)) == 1 and boundary_cursor.is_empty():
			boundary_cursor = sliced_cursor.duplicate(true)
	var unsliced_pass_details: Dictionary = unsliced_pass.get("details", {}) if unsliced_pass.get("details", {}) is Dictionary else {}
	var sliced_pass_details: Dictionary = sliced_pass.get("details", {}) if sliced_pass.get("details", {}) is Dictionary else {}
	var boundary_previous = boundary_cursor.get("previousGroundedSample", null)
	var expected_boundary := first_segment_end
	expected_boundary.y = main.surface_y_at_position(first_segment_end) + CollisionProbeServiceScript.DEFAULT_GROUND_OFFSET
	# Missing the terrain motion mask deterministically blocks at the first sample.
	# Compare that failure certificate too, so splitting cannot turn pass/block into
	# different semantics while crossing the multi-segment elevation route above.
	body.collision_mask = 0
	var unsliced_blocked: Dictionary = service.probe_route(entry, route, {}, { "maxSamples": 256 })
	var sliced_blocked: Dictionary = service.probe_route(entry, route, {}, { "maxSamples": 1 })
	var unsliced_blocked_details: Dictionary = unsliced_blocked.get("details", {}) if unsliced_blocked.get("details", {}) is Dictionary else {}
	var sliced_blocked_details: Dictionary = sliced_blocked.get("details", {}) if sliced_blocked.get("details", {}) is Dictionary else {}
	var passed := bool(unsliced_pass.get("ok", false)) \
		and bool(sliced_pass.get("ok", false)) \
		and String(sliced_pass.get("status", "")) == String(unsliced_pass.get("status", "")) \
		and String(sliced_pass.get("reason", "")) == String(unsliced_pass.get("reason", "")) \
		and int(sliced_pass_details.get("completedSamples", -1)) == int(unsliced_pass_details.get("completedSamples", -2)) \
		and sliced_calls > 1 \
		and boundary_previous is Vector3 \
		and (boundary_previous as Vector3).distance_to(expected_boundary) <= 0.001 \
		and not bool(unsliced_blocked.get("ok", true)) \
		and not bool(sliced_blocked.get("ok", true)) \
		and String(sliced_blocked.get("status", "")) == String(unsliced_blocked.get("status", "")) \
		and String(sliced_blocked.get("reason", "")) == String(unsliced_blocked.get("reason", "")) \
		and int(sliced_blocked_details.get("segmentIndex", -1)) == int(unsliced_blocked_details.get("segmentIndex", -2)) \
		and int(sliced_blocked_details.get("sampleIndex", -1)) == int(unsliced_blocked_details.get("sampleIndex", -2)) \
		and int(sliced_blocked_details.get("completedSamples", -1)) == int(unsliced_blocked_details.get("completedSamples", -2))
	main.free()
	return outcome(
		passed,
		"unslicedPass=%s slicedPass=%s boundary=%s unslicedBlocked=%s slicedBlocked=%s" % [JSON.stringify(unsliced_pass), JSON.stringify(sliced_pass), JSON.stringify(boundary_cursor), JSON.stringify(unsliced_blocked), JSON.stringify(sliced_blocked)],
		["probe_cursor_retains_previous_grounded_sample_across_segment_boundary", "elevated_split_probe_matches_unsliced_pass_certificate", "split_probe_matches_unsliced_block_certificate", "completed_sample_counts_are_identical"],
		{ "unslicedPass": unsliced_pass, "slicedPass": sliced_pass, "slicedCalls": sliced_calls, "boundaryCursor": boundary_cursor, "expectedBoundary": expected_boundary, "unslicedBlocked": unsliced_blocked, "slicedBlocked": sliced_blocked }
	)

func test_route_probe_repair_cell_bridge_uses_fallback_goal(_mode: String) -> Dictionary:
	var planner = NavmeshRoutePlannerScript.new()
	var target_cell := Vector2i(10, 0)
	var fallback_cell := Vector2i(8, 0)
	var goals: Array[Vector2i] = planner._generated_bridge_goal_cells({
		"generatedBridgeFallbackOnly": true,
		"strictArrival": true,
		"fallbackCells": [fallback_cell, target_cell]
	}, target_cell)
	var passed := goals.has(fallback_cell) and not goals.has(target_cell) and goals.size() == 1
	return outcome(
		passed,
		"goals=%s" % JSON.stringify(vec2i_array_summary(goals)),
		["probe_repair_lattice_does_not_retry_blocked_target", "probe_repair_lattice_moves_to_fallback_first"],
		{ "goals": vec2i_array_summary(goals) }
	)

func test_route_probe_avoid_excludes_failed_candidate_goal(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	fixture.standable.clear()
	fixture.add_standable_rect(Vector2i(0, 0), Vector2i(2, 2))
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var blocked_goal := Vector2i(2, 0)
	var fallback_goal := Vector2i(0, 2)
	var route: Dictionary = substrate.plan_route(fixture.generated_town_entry(), Vector2i.ZERO, [blocked_goal, fallback_goal], {
		"allowOutside": true,
		"avoidCells": [blocked_goal],
		"maxExpansions": 128,
		"expansionsPerCall": 128
	})
	var proof: Dictionary = route.get("proof", {}) if route.get("proof", {}) is Dictionary else {}
	var passed: bool = bool(route.get("ok", false)) \
		and route.get("targetCell", Vector2i(2147483000, 2147483000)) == fallback_goal \
		and (proof.get("acceptedGoals", []) as Array).has(fallback_goal) \
		and not (proof.get("acceptedGoals", []) as Array).has(blocked_goal)
	return outcome(
		passed,
		"route=%s" % JSON.stringify(substrate_route_summary(route)),
		["probe_avoid_removes_failed_interaction_pose_from_goal_set", "alternate_collision_backed_goal_remains_routeable"],
		{ "route": substrate_route_summary(route), "blockedGoal": blocked_goal, "fallbackGoal": fallback_goal }
	)

func test_route_runtime_goal_adapter_uses_new_corridor(_mode: String) -> Dictionary:
	var adapter_text = read_text("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")
	var passed = adapter_text.find("MAX_ITERATIONS") < 0 \
		and adapter_text.find("navmesh_planner.plan_runtime_route") >= 0 \
		and adapter_text.find("generated_corridor_planner") < 0 \
		and adapter_text.find("HierarchicalRoutePlannerScript") < 0 \
		and adapter_text.find("coordinator.plan_runtime_route") < 0 \
		and adapter_text.find("route_from_cells") < 0
	return outcome(passed, "maxIterations=%d navmeshCall=%d generatedFallback=%d" % [adapter_text.find("MAX_ITERATIONS"), adapter_text.find("navmesh_planner.plan_runtime_route"), adapter_text.find("generated_corridor_planner")], ["runtime_adapter_delegates_navmesh_authority", "old_iteration_cap_removed", "generated_corridor_fallback_removed_from_live_adapter"], {})

func test_route_runtime_door_uses_group_portal_id(_mode: String) -> Dictionary:
	var planner = HierarchicalRoutePlannerScript.new()
	var door := Node3D.new()
	door.name = "Block_door_305_16_0"
	door.set_meta("door_portal_id", "door:door-group:305,16,0:1")
	door.set_meta("door_group_id", "door-group:305,16,0:1")
	door.set_meta("cell", Vector3i(305, 16, 0))
	var portal_id: String = planner.runtime_door_portal_id(door)
	var passed: bool = portal_id == "door:door-group:305,16,0:1" and not portal_id.contains("Block_door")
	door.free()
	return outcome(
		passed,
		"runtimePortalId=%s" % portal_id,
		["runtime_door_action_uses_group_portal_id", "runtime_door_action_not_leaf_node_id"],
		{ "portalId": portal_id }
	)

func test_route_collision_boundary_blocks_open_destination(_mode: String) -> Dictionary:
	var wall := collision_block(Vector2i(50, 0), "woodBlock", Vector3(CELL * 0.5, 0.0, 0.0), Vector3(CELL * 0.14, CELL * 1.8, CELL * 0.96))
	var setup := collision_adapter_with_blocks([wall])
	var adapter = setup.get("adapter")
	var snapshot: Dictionary = setup.get("snapshot", {})
	var entry: Dictionary = setup.get("entry", {})
	var destination_open := adapter.static_blocker(snapshot, Vector2i(1, 0)) == null
	var result: Dictionary = adapter.cell_transition_pathable(entry, snapshot, Vector2i(0, 0), Vector2i(1, 0), {}, true)
	var passed := destination_open and not bool(result.get("ok", true)) and String(result.get("reason", "")) == "blocked_static_transition"
	free_collision_setup(setup)
	return outcome(passed, "destinationOpen=%s result=%s" % [str(destination_open), JSON.stringify(result)], ["transition_checks_swept_collision", "open_destination_still_blocked_by_boundary_wall"], { "result": result })

func test_route_collision_occupied_cell_blocks_node(_mode: String) -> Dictionary:
	var wall := collision_block(Vector2i(50, 0), "woodBlock", Vector3(CELL, 0.0, 0.0), Vector3(CELL * 0.18, CELL * 1.8, CELL * 0.96))
	var setup := collision_adapter_with_blocks([wall])
	var adapter = setup.get("adapter")
	var snapshot: Dictionary = setup.get("snapshot", {})
	var entry: Dictionary = setup.get("entry", {})
	var metadata_open := adapter.static_blocker(snapshot, Vector2i(1, 0)) == null
	var collision_blocker: Dictionary = adapter.static_collision_blocker(snapshot, Vector2i(1, 0))
	var result: Dictionary = adapter.cell_pathable(entry, snapshot, Vector2i(0, 0), Vector2i(1, 0), {}, true)
	var passed := metadata_open and not collision_blocker.is_empty() and not bool(result.get("ok", true)) and String(result.get("reason", "")) == "blocked_static_collision"
	free_collision_setup(setup)
	return outcome(passed, "metadataOpen=%s collision=%s result=%s" % [str(metadata_open), JSON.stringify(collision_blocker), JSON.stringify(result)], ["collision_footprint_blocks_standing_cell", "route_nodes_use_physics_occupancy_not_metadata_only"], { "result": result, "collision": collision_blocker })

func test_route_navmesh_surfaces_exclude_collision_occupied_cells(_mode: String) -> Dictionary:
	var wall := collision_block(Vector2i(1, 0), "woodBlock", Vector3(CELL, 0.0, 0.0), Vector3(CELL * 0.18, CELL * 1.8, CELL * 0.96))
	var setup := collision_adapter_with_blocks([wall])
	# Synthetic collision/source contract; the real worker supplies accepted facts.
	var adapter = setup.get("adapter")
	var validation_snapshot: Dictionary = setup.get("snapshot", {})
	var navmesh_snapshot: Dictionary = await runner.synthetic_capture_navigation_snapshot(adapter,"0,0")
	var publication: Dictionary = await runner.synthetic_accept_navigation_snapshot(navmesh_snapshot)
	var surfaces: Array = navmesh_snapshot.get("surfaces", []) if navmesh_snapshot.get("surfaces", []) is Array else []
	var collision_blocker: Dictionary = adapter.static_collision_blocker(validation_snapshot, Vector2i(1, 0))
	var blocked_cell_surface := false
	var open_cell_surface := false
	for surface_value in surfaces:
		if not (surface_value is Dictionary):
			continue
		var surface: Dictionary = surface_value
		var cell: Vector3i = surface.get("cell", Vector3i.ZERO)
		if cell.x == 1 and cell.z == 0:
			blocked_cell_surface = true
		if cell.x == 0 and cell.z == 0:
			open_cell_surface = true
	var passed: bool = publication.accepted and publication.initialPending and publication.shutdownComplete \
		and not collision_blocker.is_empty() and not blocked_cell_surface and open_cell_surface
	free_collision_setup(setup)
	return outcome(
		passed,
		"collision=%s blockedSurface=%s openSurface=%s surfaceCount=%d" % [JSON.stringify(collision_blocker), str(blocked_cell_surface), str(open_cell_surface), surfaces.size()],
		["navmesh_surface_uses_collision_records", "collision_occupied_cell_not_published_as_walkable"],
		{ "evidenceLevel":"synthetic_contract", "publication":publication, "collision": collision_blocker, "blockedCellSurface": blocked_cell_surface, "openCellSurface": open_cell_surface, "surfaceCount": surfaces.size() }
	)

func test_route_authority_urgent_and_normal_atoms_share_hard_cap(_mode: String) -> Dictionary:
	var authority = NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, BudgetedCollisionProbe.new())
	var requests: Array[Dictionary] = []
	for actor_index in range(8):
		var priority := 190 if actor_index < 4 else 100
		requests.append(authority.submit_request(
			{ "id": "bounded-atom-%d" % actor_index },
			{ "kind": "home" if priority >= 180 else "work", "priority": priority },
			{ "priority": priority }
		))
	authority.begin_frame()
	var granted_slices: Array[int] = []
	var urgent_grants := 0
	var ordinary_grants := 0
	for request_index in range(requests.size()):
		var request: Dictionary = requests[request_index]
		var claim: Dictionary = authority.claim_planning_budget(String(request.get("requestId", "")), "bounded_atom")
		if bool(claim.get("granted", false)):
			granted_slices.append(int(claim.get("routeSearchExpansions", 0)))
			if request_index < 4:
				urgent_grants += 1
			else:
				ordinary_grants += 1
	var stats: Dictionary = authority.stats()
	var used := int(stats.get("routeSearchExpansionsUsedThisFrame", 0))
	var all_atoms_bounded := not granted_slices.is_empty()
	for slice in granted_slices:
		all_atoms_bounded = all_atoms_bounded and slice == 2
	var passed: bool = all_atoms_bounded \
		and granted_slices.size() == authority.plan_attempt_budget_per_frame \
		and used == granted_slices.size() * 2 \
		and used == authority.route_search_expansion_budget_per_frame \
		and urgent_grants > 0 \
		and ordinary_grants > 0
	return outcome(
		passed,
		"grants=%s used=%d budget=%d" % [JSON.stringify(granted_slices), used, authority.route_search_expansion_budget_per_frame],
		["urgent_priority_does_not_enlarge_atom", "normal_and_urgent_atoms_are_two_expansions", "mixed_queue_uses_exact_global_budget", "ordinary_work_remains_admitted"],
		{ "grantedSlices": granted_slices, "usedExpansions": used, "budget": authority.route_search_expansion_budget_per_frame, "urgentGrants": urgent_grants, "ordinaryGrants": ordinary_grants }
	)

func test_route_home_collision_lattice_exact_detour(_mode: String) -> Dictionary:
	var blocks := []
	var blocked_lookup := {}
	var setup := collision_adapter_with_blocks([])
	var main := setup.get("main") as Node
	for z in range(1, 5):
		var cell := Vector2i(0, z)
		var block := collision_block(cell)
		blocks.append(block)
		blocked_lookup[cell] = true
		if main != null:
			main.add_child(block)
			var live_blocks: Dictionary = main.get("blocks")
			live_blocks[Vector3i(cell.x, 0, cell.y)] = block
	setup["blocks"] = blocks
	var adapter = setup.get("adapter")
	var body := setup.get("body") as Node3D
	body.position = Vector3.ZERO
	body.global_position = Vector3.ZERO
	var target_cell := Vector2i(0, 5)
	var target_position: Vector3 = adapter.cell_position(target_cell)
	var entry := {
		"id": "home-lattice-detour",
		"body": body,
		"townCenter": Vector2i.ZERO,
		"townRadius": 128,
		"porchPosition": target_position,
		"porchCell": target_cell,
		"homeCell": target_cell + Vector2i(0, 1),
		"doorCell": target_cell + Vector2i(0, -1),
		"interiorMinCell": target_cell,
		"interiorMaxCell": target_cell + Vector2i(1, 1)
	}
	var coordinator = NpcRouteCoordinatorAdapterScript.new()
	coordinator.world = adapter
	var failed_route := {
		"ok": false,
		"status": "blocked",
		"reason": "no_route",
		"source": "navmesh",
		"cells": [],
		"waypoints": [],
		"actions": {},
		"targetCell": target_cell,
		"fallbackCell": Vector2i(999999, 999999)
	}
	var route: Dictionary = coordinator._plan_exact_home_collision_lattice_route(entry, {
		"kind": "home",
		"movingHome": true,
		"allowOutside": true,
		"strictArrival": true,
		"target": target_position,
		"targetCell": target_cell,
		"arrivalRadius": CELL * 0.5,
		"priority": 140
	}, failed_route)
	var cells: Array = route.get("cells", []) if route.get("cells", []) is Array else []
	var waypoints: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
	var crosses_blocked := false
	for cell_value in cells:
		if cell_value is Vector2i and blocked_lookup.has(cell_value):
			crosses_blocked = true
	var exact_target: bool = route.get("fallbackCell", Vector2i(999999, 999999)) == target_cell
	var passed: bool = bool(route.get("ok", false)) \
		and String(route.get("status", "")) == "routed" \
		and String(route.get("source", "")) == "collision_lattice" \
		and exact_target \
		and cells.has(target_cell) \
		and not waypoints.is_empty() \
		and not crosses_blocked \
		and not bool(route.get("generatedCellBridge", false))
	free_collision_setup(setup)
	return outcome(
		passed,
		"route=%s failedRoute=%s crossesBlocked=%s" % [JSON.stringify(navmesh_route_dictionary_summary(route)), JSON.stringify(failed_route), str(crosses_blocked)],
		["home_collision_lattice_exact_target", "home_collision_lattice_detours_static_collision", "home_collision_lattice_not_generated_bridge"],
		{ "route": navmesh_route_dictionary_summary(route), "failedRoute": failed_route, "cells": vec2i_array_summary(cells), "crossesBlocked": crosses_blocked }
	)

func test_route_scripted_collision_lattice_exact_detour(_mode: String) -> Dictionary:
	var blocks := []
	var blocked_lookup := {}
	var setup := collision_adapter_with_blocks([])
	var main := setup.get("main") as Node
	for z in range(1, 5):
		var cell := Vector2i(0, z)
		var block := collision_block(cell)
		blocks.append(block)
		blocked_lookup[cell] = true
		if main != null:
			main.add_child(block)
			var live_blocks: Dictionary = main.get("blocks")
			live_blocks[Vector3i(cell.x, 0, cell.y)] = block
	setup["blocks"] = blocks
	var adapter = setup.get("adapter")
	adapter.rebuild_static_cells()
	var body := setup.get("body") as Node3D
	body.position = Vector3.ZERO
	body.global_position = Vector3.ZERO
	var target_cell := Vector2i(0, 5)
	var target_position: Vector3 = adapter.cell_position(target_cell)
	var entry: Dictionary = setup.get("entry", {})
	entry["id"] = "scripted-lattice-detour"
	entry["body"] = body
	entry["townCenter"] = Vector2i.ZERO
	entry["townRadius"] = 128
	var failed_route := {
		"ok": false,
		"status": "blocked",
		"reason": "path_crosses_static_collision",
		"source": "navmesh",
		"cells": [],
		"waypoints": [],
		"actions": {},
		"targetCell": target_cell,
		"fallbackCell": Vector2i(999999, 999999)
	}
	var intent := {
		"kind": "scripted",
		"movingHome": false,
		"allowOutside": true,
		"strictArrival": true,
		"target": target_position,
		"targetCell": target_cell,
		"arrivalRadius": CELL * 0.5,
		"priority": 220
	}
	var low_priority_intent := intent.duplicate(true)
	low_priority_intent["priority"] = 90
	var coordinator = NpcRouteCoordinatorAdapterScript.new()
	coordinator.world = adapter
	var should_scripted := coordinator._should_try_exact_collision_lattice_route(entry, failed_route, intent)
	var should_low_priority := coordinator._should_try_exact_collision_lattice_route(entry, failed_route, low_priority_intent)
	var route: Dictionary = coordinator._plan_exact_collision_lattice_route(entry, intent, failed_route, "exact_collision_lattice")
	var cells: Array = route.get("cells", []) if route.get("cells", []) is Array else []
	var crosses_blocked := false
	for cell_value in cells:
		if cell_value is Vector2i and blocked_lookup.has(cell_value):
			crosses_blocked = true
	var passed: bool = should_scripted \
		and not should_low_priority \
		and bool(route.get("ok", false)) \
		and String(route.get("status", "")) == "routed" \
		and String(route.get("source", "")) == "collision_lattice" \
		and String(route.get("reason", "")) == "exact_collision_lattice" \
		and route.get("fallbackCell", Vector2i(999999, 999999)) == target_cell \
		and cells.has(target_cell) \
		and not crosses_blocked \
		and not bool(route.get("generatedCellBridge", false))
	free_collision_setup(setup)
	return outcome(
		passed,
		"shouldScripted=%s shouldLow=%s route=%s crossesBlocked=%s" % [str(should_scripted), str(should_low_priority), JSON.stringify(navmesh_route_dictionary_summary(route)), str(crosses_blocked)],
		["scripted_collision_lattice_exact_target", "scripted_collision_lattice_detours_static_collision", "scripted_collision_lattice_not_generated_bridge", "scripted_collision_lattice_priority_gated"],
		{ "route": navmesh_route_dictionary_summary(route), "cells": vec2i_array_summary(cells), "shouldScripted": should_scripted, "shouldLowPriority": should_low_priority, "crossesBlocked": crosses_blocked }
	)

func test_route_home_collision_lattice_recenters_off_cell_start(_mode: String) -> Dictionary:
	var side_block := collision_block(Vector2i(-1, 0), "stoneBlock")
	var setup := collision_adapter_with_blocks([side_block])
	var adapter = setup.get("adapter")
	var body := setup.get("body") as Node3D
	body.position = Vector3(CELL * -0.42, 0.0, CELL * 0.42)
	body.global_position = body.position
	var start_cell := Vector2i.ZERO
	var target_cell := Vector2i(0, 3)
	var target_position: Vector3 = adapter.cell_position(target_cell)
	var entry := {
		"id": "home-lattice-start-clearance",
		"body": body,
		"townCenter": Vector2i.ZERO,
		"townRadius": 128,
		"porchPosition": target_position,
		"porchCell": target_cell,
		"homeCell": target_cell + Vector2i(0, 1),
		"doorCell": target_cell + Vector2i(0, -1),
		"interiorMinCell": target_cell,
		"interiorMaxCell": target_cell + Vector2i(1, 1)
	}
	var coordinator = NpcRouteCoordinatorAdapterScript.new()
	coordinator.world = adapter
	var failed_route := {
		"ok": false,
		"status": "blocked",
		"reason": "no_route",
		"source": "navmesh",
		"cells": [],
		"waypoints": [],
		"actions": {},
		"targetCell": target_cell,
		"fallbackCell": Vector2i(999999, 999999)
	}
	var route: Dictionary = coordinator._plan_exact_home_collision_lattice_route(entry, {
		"kind": "home",
		"movingHome": true,
		"allowOutside": true,
		"strictArrival": true,
		"target": target_position,
		"targetCell": target_cell,
		"arrivalRadius": CELL * 0.5,
		"priority": 140
	}, failed_route)
	var cells: Array = route.get("cells", []) if route.get("cells", []) is Array else []
	var waypoints: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
	var debug: Dictionary = route.get("exactCollisionLatticeRoute", {}) if route.get("exactCollisionLatticeRoute", {}) is Dictionary else {}
	var start_center: Vector3 = adapter.cell_position(start_cell)
	var first_waypoint: Vector3 = waypoints[0] if not waypoints.is_empty() and waypoints[0] is Vector3 else Vector3(INF, INF, INF)
	var starts_with_center := first_waypoint.distance_to(start_center) <= 0.01
	var passed := bool(route.get("ok", false)) \
		and String(route.get("status", "")) == "routed" \
		and String(route.get("source", "")) == "collision_lattice" \
		and starts_with_center \
		and bool(debug.get("startClearanceWaypoint", false)) \
		and cells.has(target_cell) \
		and not cells.has(start_cell) \
		and not bool(route.get("generatedCellBridge", false))
	free_collision_setup(setup)
	return outcome(
		passed,
		"route=%s startsWithCenter=%s debug=%s" % [JSON.stringify(navmesh_route_dictionary_summary(route)), str(starts_with_center), JSON.stringify(debug)],
		["home_collision_lattice_recenters_off_cell_start", "home_start_clearance_keeps_action_cells_stable", "home_start_clearance_not_generated_bridge"],
		{ "route": navmesh_route_dictionary_summary(route), "cells": vec2i_array_summary(cells), "startsWithCenter": starts_with_center, "debug": debug }
	)

func test_route_home_egress_uses_exact_collision_lattice(_mode: String) -> Dictionary:
	var blocks := [
		collision_block(Vector2i(-1, 0), "woodBlock"),
		collision_door(Vector2i(0, 0), 0, "home"),
		collision_block(Vector2i(1, 0), "woodBlock")
	]
	var setup := collision_adapter_with_blocks(blocks)
	var adapter = setup.get("adapter")
	var body := setup.get("body") as Node3D
	var start_cell := Vector2i(0, 1)
	var door_cell := Vector2i(0, 0)
	var porch_cell := Vector2i(0, -1)
	body.position = adapter.cell_position(start_cell)
	body.global_position = body.position
	var entry := {
		"id": "home-egress-worker",
		"body": body,
		"job": "trade",
		"insideHome": false,
		"townCenter": Vector2i.ZERO,
		"townRadius": 128,
		"homeCell": start_cell,
		"homePosition": adapter.cell_position(start_cell),
		"doorCell": door_cell,
		"porchCell": porch_cell,
		"porchPosition": adapter.cell_position(porch_cell),
		"interiorMinCell": Vector2i(-1, 1),
		"interiorMaxCell": Vector2i(1, 3)
	}
	var intent := {
		"kind": "work",
		"movingHome": false,
		"allowOutside": true,
		"strictArrival": true,
		"target": adapter.cell_position(porch_cell),
		"targetCell": porch_cell,
		"arrivalRadius": CELL * 0.5,
		"priority": 90
	}
	var failed_route := {
		"ok": false,
		"status": "blocked",
		"reason": "path_crosses_static_collision",
		"source": "navmesh",
		"cells": [],
		"waypoints": [],
		"actions": {},
		"targetCell": porch_cell,
		"fallbackCell": Vector2i(999999, 999999)
	}
	var coordinator = NpcRouteCoordinatorAdapterScript.new()
	coordinator.world = adapter
	var should_exact := coordinator._should_try_exact_home_collision_lattice_route(entry, failed_route, intent)
	var open_fallback_allowed := coordinator._should_try_generated_cell_job_route(entry, intent)
	var passed := not should_exact and not open_fallback_allowed
	free_collision_setup(setup)
	return outcome(
		passed,
		"shouldExact=%s openFallback=%s" % [str(should_exact), str(open_fallback_allowed)],
		["home_egress_rejects_exact_collision_lattice", "home_egress_not_generated_bridge"],
		{ "shouldExact": should_exact, "openFallback": open_fallback_allowed }
	)

func test_route_collision_door_requires_portal_axis(_mode: String) -> Dictionary:
	var door := collision_door(Vector2i(0, 0), 0, "public_gate")
	var setup := collision_adapter_with_blocks([door])
	var adapter = setup.get("adapter")
	var snapshot: Dictionary = setup.get("snapshot", {})
	var entry: Dictionary = setup.get("entry", {})
	var through_portal: Dictionary = adapter.cell_transition_pathable(entry, snapshot, Vector2i(0, -1), Vector2i(0, 0), {}, true)
	var side_cut: Dictionary = adapter.cell_transition_pathable(entry, snapshot, Vector2i(-1, 0), Vector2i(0, 0), {}, true)
	var passed := bool(through_portal.get("ok", false)) and not bool(side_cut.get("ok", true)) and String(side_cut.get("reason", "")) == "door_transition_blocked"
	free_collision_setup(setup)
	return outcome(passed, "portal=%s side=%s" % [JSON.stringify(through_portal), JSON.stringify(side_cut)], ["door_crossing_requires_matching_axis", "sideways_door_collision_not_routeable"], { "portal": through_portal, "side": side_cut })

func test_route_collision_rejects_diagonal_corner_cut(_mode: String) -> Dictionary:
	var east_wall := collision_block(Vector2i(1, 0), "woodBlock")
	var north_wall := collision_block(Vector2i(0, 1), "woodBlock")
	var setup := collision_adapter_with_blocks([east_wall, north_wall])
	var adapter = setup.get("adapter")
	var snapshot: Dictionary = setup.get("snapshot", {})
	var entry: Dictionary = setup.get("entry", {})
	var destination_open := adapter.static_blocker(snapshot, Vector2i(1, 1)) == null
	var result: Dictionary = adapter.cell_transition_pathable(entry, snapshot, Vector2i(0, 0), Vector2i(1, 1), {}, true)
	var passed := destination_open and not bool(result.get("ok", true)) and String(result.get("reason", "")) == "blocked_static_transition"
	free_collision_setup(setup)
	return outcome(passed, "destinationOpen=%s result=%s" % [str(destination_open), JSON.stringify(result)], ["diagonal_corner_cut_checks_collision_sweep", "corner_wall_pair_blocks_diagonal_route"], { "result": result })

func test_route_navmesh_post_validation_rejects_wall_cross(_mode: String) -> Dictionary:
	var wall := collision_block(Vector2i(50, 0), "woodBlock", Vector3(CELL * 0.5, 0.0, 0.0), Vector3(CELL * 0.14, CELL * 1.8, CELL * 0.96))
	var setup := collision_adapter_with_blocks([wall])
	var adapter = setup.get("adapter")
	var service := FakeNavmeshRouteService.new()
	var planner := NavmeshRoutePlannerScript.new()
	planner.setup(service, null, null, adapter)
	var body := Node3D.new()
	runner.add_child(body)
	body.global_position = Vector3.ZERO
	var entry := {
		"id": "navmesh-wall-cross",
		"body": body,
		"townCenter": Vector2i.ZERO,
		"townRadius": 12,
		"porchPosition": Vector3.ZERO
	}
	var target := Vector3(CELL, 0.0, 0.0)
	var route: Dictionary = planner.plan_runtime_route(entry, {
		"kind": "scripted",
		"target": target,
		"targetCell": Vector2i(1, 0),
		"allowOutside": false,
		"movingHome": false,
		"arrivalRadius": CELL * 0.5,
		"strictArrival": true
	}, adapter, 0)
	var passed := not bool(route.get("ok", true)) and String(route.get("reason", "")) == "path_crosses_static_collision"
	body.free()
	free_collision_setup(setup)
	return outcome(passed, "route=%s" % JSON.stringify(navmesh_route_dictionary_summary(route)), ["navmesh_route_post_validation_rejects_wall_crossing", "bad_navmesh_path_not_accepted"], { "route": navmesh_route_dictionary_summary(route) })

func test_route_scripted_target_expands_navmesh_tiles(_mode: String) -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	var body := Node3D.new()
	runner.add_child(body)
	body.global_position = Vector3.ZERO
	var target_cell := Vector2i(110, -18)
	var target := Vector3(float(target_cell.x) * NpcConstantsScript.CELL_SIZE, 0.0, float(target_cell.y) * NpcConstantsScript.CELL_SIZE)
	body.set_meta("npc_scripted_target", target)
	body.set_meta("npc_scripted_allow_outside", true)
	var entry := {
		"id": "scripted_far_guard",
		"body": body,
		"townCenter": Vector2i.ZERO,
		"townRadius": 18,
		"job": "guard",
		"role": "Watch"
	}
	var keys: Array[String] = adapter.route_navmesh_tile_keys(entry, body.global_position, target, true, false, 12)
	var target_tile := "%d,%d" % [
		floori(float(target_cell.x) / float(NpcConstantsScript.NAV_TILE_CELL_SIZE)),
		floori(float(target_cell.y) / float(NpcConstantsScript.NAV_TILE_CELL_SIZE))
	]
	var start_tile := "%d,%d" % [0, 0]
	var passed := keys.has(target_tile) and keys.has(start_tile)
	body.free()
	return outcome(
		passed,
		"targetTile=%s startTile=%s keys=%s" % [target_tile, start_tile, JSON.stringify(keys)],
		["scripted_target_leash_included_in_navmesh_publication", "start_and_target_tiles_published"],
		{ "targetTile": target_tile, "startTile": start_tile, "keys": keys }
	)

func test_route_substrate_reachable_generated_town_fixture(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	fixture.doors[Vector2i(2, 0)] = { "portalId": "fixture:home-door", "doorId": "home-door" }
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	var poses: Dictionary = substrate.candidate_poses_for_target(entry, {
		"interiorMinCell": Vector2i(4, 0),
		"interiorMaxCell": Vector2i(4, 0)
	}, "home_interior", { "allowOutside": true })
	var route: Dictionary = substrate.plan_route(entry, Vector2i(0, 0), [Vector2i(4, 0)], {
		"allowOutside": true,
		"maxExpansions": 64
	})
	var proof: Dictionary = route.get("proof", {})
	var cells: Array = route.get("cells", [])
	var passed := bool(route.get("ok", false)) \
		and String(route.get("classification", "")) == "reachable" \
		and cells.has(Vector2i(2, 0)) \
		and bool(proof.get("collisionBacked", false)) \
		and bool(proof.get("generatedWorldInformed", false)) \
		and (proof.get("doorEdges", []) as Array).size() >= 1 \
		and bool(poses.get("ok", false))
	return outcome(
		passed,
		"route=%s poses=%s" % [JSON.stringify(substrate_route_summary(route)), JSON.stringify(substrate_pose_summary(poses))],
		["collision_backed_route_found", "door_cell_preserved_as_route_evidence", "semantic_candidate_pose_validated"],
		{ "route": substrate_route_summary(route), "poses": substrate_pose_summary(poses) }
	)


func test_route_substrate_reuses_authoritative_snapshot_for_standability(_mode: String) -> Dictionary:
	var fixture := SnapshotReuseRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "snapshot-reuse-route"
	var route: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 2,
		"ignoreDynamic": false
	})
	var passed := fixture.snapshot_build_count == 1 \
		and fixture.snapshot_aware_standability_count > 1 \
		and fixture.legacy_standability_count == 0 \
		and String(route.get("classification", "")) == "pending_budget"
	return outcome(
		passed,
		"builds=%d snapshotAware=%d legacy=%d route=%s" % [fixture.snapshot_build_count, fixture.snapshot_aware_standability_count, fixture.legacy_standability_count, JSON.stringify(substrate_route_summary(route))],
		["one_authoritative_snapshot_per_search_slice", "standability_reuses_supplied_snapshot", "legacy_snapshot_rebuild_path_not_called"],
		{ "snapshotBuilds": fixture.snapshot_build_count, "snapshotAwareCalls": fixture.snapshot_aware_standability_count, "legacyCalls": fixture.legacy_standability_count, "route": substrate_route_summary(route) }
	)


func test_route_substrate_sliced_search_matches_unsliced(_mode: String) -> Dictionary:
	var unsliced_world := GeneratedTownRouteSubstrateFixtureWorld.new()
	unsliced_world.doors[Vector2i(2, 0)] = { "portalId": "fixture:sliced-door", "doorId": "sliced-door" }
	var unsliced_substrate = CollisionBackedRouteSubstrateScript.new()
	unsliced_substrate.setup(unsliced_world)
	var unsliced_entry := unsliced_world.generated_town_entry()
	unsliced_entry["id"] = "unsliced-route"
	var unsliced: Dictionary = unsliced_substrate.plan_route(unsliced_entry, Vector2i.ZERO, [Vector2i(5, 0)], {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 128
	})

	var sliced_world := GeneratedTownRouteSubstrateFixtureWorld.new()
	sliced_world.doors[Vector2i(2, 0)] = { "portalId": "fixture:sliced-door", "doorId": "sliced-door" }
	var sliced_substrate = CollisionBackedRouteSubstrateScript.new()
	sliced_substrate.setup(sliced_world)
	var sliced_entry := sliced_world.generated_town_entry()
	sliced_entry["id"] = "sliced-route"
	var sliced: Dictionary = {}
	var call_count := 0
	while call_count < 128:
		call_count += 1
		sliced = sliced_substrate.plan_route(sliced_entry, Vector2i.ZERO, [Vector2i(5, 0)], {
			"allowOutside": true,
			"maxExpansions": 128,
			"expansionsPerCall": 2,
			"validationStepsPerCall": 2
		})
		var sliced_proof: Dictionary = sliced.get("proof", {}) if sliced.get("proof", {}) is Dictionary else {}
		if int(sliced_proof.get("validationStepsThisCall", 0)) > 2:
			break
		if bool(sliced.get("ok", false)) or String(sliced.get("classification", "")) != "pending_budget":
			break
	var unsliced_cells: Array = unsliced.get("cells", []) if unsliced.get("cells", []) is Array else []
	var sliced_cells: Array = sliced.get("cells", []) if sliced.get("cells", []) is Array else []
	var unsliced_actions: Dictionary = unsliced.get("actions", {}) if unsliced.get("actions", {}) is Dictionary else {}
	var sliced_actions: Dictionary = sliced.get("actions", {}) if sliced.get("actions", {}) is Dictionary else {}
	var passed: bool = bool(unsliced.get("ok", false)) \
		and bool(sliced.get("ok", false)) \
		and sliced_cells == unsliced_cells \
		and sliced_actions.keys() == unsliced_actions.keys() \
		and sliced.get("targetCell", Vector2i(999999, 999999)) == unsliced.get("targetCell", Vector2i(999999, 999999)) \
		and int((sliced.get("proof", {}) as Dictionary).get("validationStepsThisCall", 0)) <= 2 \
		and call_count > 1
	return outcome(
		passed,
		"calls=%d unsliced=%s sliced=%s" % [call_count, JSON.stringify(substrate_route_summary(unsliced)), JSON.stringify(substrate_route_summary(sliced))],
		["two_expansion_search_matches_unsliced_route", "sliced_search_preserves_door_actions", "sliced_search_reaches_same_goal"],
		{ "callCount": call_count, "unsliced": substrate_route_summary(unsliced), "sliced": substrate_route_summary(sliced) }
	)


func test_route_substrate_lazy_frontier_preserves_frozen_eager_tie_route(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	fixture.blocked[Vector2i(1, 0)] = { "id": "frozen-eager-center-block" }
	var expected := [Vector2i.ZERO, Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(2, 0)]
	var unsliced_substrate = CollisionBackedRouteSubstrateScript.new()
	unsliced_substrate.setup(fixture)
	var unsliced_entry := fixture.generated_town_entry()
	unsliced_entry["id"] = "frozen-eager-unsliced"
	var unsliced: Dictionary = unsliced_substrate.plan_route(unsliced_entry, Vector2i.ZERO, [Vector2i(2, 0)], {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 128,
		"validationStepsPerCall": 512
	})
	var sliced_substrate = CollisionBackedRouteSubstrateScript.new()
	sliced_substrate.setup(fixture)
	var sliced_entry := fixture.generated_town_entry()
	sliced_entry["id"] = "frozen-eager-sliced"
	var sliced: Dictionary = {}
	var calls := 0
	for _call_index in range(128):
		calls += 1
		sliced = sliced_substrate.plan_route(sliced_entry, Vector2i.ZERO, [Vector2i(2, 0)], {
			"allowOutside": true,
			"maxExpansions": 128,
			"expansionsPerCall": 2,
			"validationStepsPerCall": 2,
			"requestIdentity": "frozen-eager-sliced-request"
		})
		if bool(sliced.get("ok", false)) or String(sliced.get("classification", "")) != "pending_budget":
			break
	var unsliced_cells: Array = unsliced.get("cells", []) if unsliced.get("cells", []) is Array else []
	var sliced_cells: Array = sliced.get("cells", []) if sliced.get("cells", []) is Array else []
	var passed := bool(unsliced.get("ok", false)) \
		and bool(sliced.get("ok", false)) \
		and unsliced_cells == expected \
		and sliced_cells == expected \
		and calls > 1
	return outcome(
		passed,
		"calls=%d expected=%s unsliced=%s sliced=%s" % [calls, JSON.stringify(vec2i_array_summary(expected)), JSON.stringify(vec2i_array_summary(unsliced_cells)), JSON.stringify(vec2i_array_summary(sliced_cells))],
		["legacy_neighbor_order_selects_positive_z_equal_cost_detour", "lazy_slices_match_frozen_eager_route", "equal_cost_successor_ties_are_stable"],
		{ "calls": calls, "expected": vec2i_array_summary(expected), "unsliced": substrate_route_summary(unsliced), "sliced": substrate_route_summary(sliced) }
	)


func test_route_substrate_four_cardinal_production_budget_latency(_mode: String) -> Dictionary:
	const MAX_PRODUCTION_CALLS := 8
	const SHARED_VALIDATION_BUDGET := 2
	var direction_specs := [
		{ "label": "positive_x", "direction": Vector2i(1, 0) },
		{ "label": "negative_x", "direction": Vector2i(-1, 0) },
		{ "label": "positive_z", "direction": Vector2i(0, 1) },
		{ "label": "negative_z", "direction": Vector2i(0, -1) }
	]
	var all_exact_parity := true
	var all_exact_endpoints := true
	var all_calls_bounded := true
	var all_per_call_validations_bounded := true
	var all_per_call_cheap_steps_bounded := true
	var calls_by_direction := {}
	var validation_patterns := {}
	var cheap_step_patterns := {}
	var routes := {}
	var reference_call_count := -1
	var reference_validation_pattern: Array = []
	var direction_neutral_calls := true
	var direction_neutral_validations := true
	for spec_value in direction_specs:
		var spec: Dictionary = spec_value
		var label := String(spec.get("label", ""))
		var direction: Vector2i = spec.get("direction", Vector2i.ZERO)
		var target := direction * 4
		var expected: Array = [Vector2i.ZERO]
		for step in range(1, 5):
			expected.append(direction * step)

		var unsliced_fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
		unsliced_fixture.standable.clear()
		unsliced_fixture.add_standable_rect(Vector2i(-5, -5), Vector2i(5, 5))
		var unsliced_substrate = CollisionBackedRouteSubstrateScript.new()
		unsliced_substrate.setup(unsliced_fixture)
		var unsliced_entry := unsliced_fixture.generated_town_entry()
		unsliced_entry["id"] = "cardinal-unsliced-%s" % label
		unsliced_entry["homeInteriorMinCell"] = Vector2i(100, 100)
		unsliced_entry["homeInteriorMaxCell"] = Vector2i(101, 101)
		var unsliced: Dictionary = unsliced_substrate.plan_route(unsliced_entry, Vector2i.ZERO, [target], {
			"allowOutside": true,
			"maxExpansions": 128,
			"expansionsPerCall": 128,
			"validationStepsPerCall": 512,
			"cheapStepsPerCall": 512
		})

		var production_fixture := ValidationCountingRouteSubstrateFixtureWorld.new()
		production_fixture.standable.clear()
		production_fixture.add_standable_rect(Vector2i(-5, -5), Vector2i(5, 5))
		var production_substrate = CollisionBackedRouteSubstrateScript.new()
		production_substrate.setup(production_fixture)
		var production_entry := production_fixture.generated_town_entry()
		production_entry["id"] = "cardinal-production-%s" % label
		# Keep this open-grid contract free of the fixture's authored home rectangle;
		# forage targets correctly reject an NPC's own interior before route search.
		production_entry["homeInteriorMinCell"] = Vector2i(100, 100)
		production_entry["homeInteriorMaxCell"] = Vector2i(101, 101)
		var request_identity := "cardinal-production-request-%s" % label
		var final: Dictionary = {}
		var call_validation_pattern: Array = []
		var call_cheap_step_pattern: Array = []
		var call_count := 0
		for _call_index in range(MAX_PRODUCTION_CALLS):
			call_count += 1
			var validator_calls_before := production_fixture.validator_calls
			var candidate_result: Dictionary = production_substrate.candidate_poses_for_target(
				production_entry,
				{ "exactSlotCell": target },
				"forage_target",
				{
					"allowOutside": true,
					"candidateValidationsPerCall": SHARED_VALIDATION_BUDGET,
					"requestIdentity": request_identity
				}
			)
			var candidate_validations := int(candidate_result.get("candidateValidationsThisCall", 0))
			var remaining_validations := maxi(0, SHARED_VALIDATION_BUDGET - candidate_validations)
			var candidate_cells: Array = []
			for candidate_value in candidate_result.get("candidates", []):
				if candidate_value is Dictionary and candidate_value.get("cell", null) is Vector2i:
					candidate_cells.append(candidate_value.get("cell"))
			if String(candidate_result.get("classification", "")) != "pending_budget" and not candidate_cells.is_empty() and remaining_validations > 0:
				final = production_substrate.plan_route(production_entry, Vector2i.ZERO, candidate_cells, {
					"allowOutside": true,
					"maxExpansions": 128,
					"expansionsPerCall": 2,
					"validationStepsPerCall": remaining_validations,
					"cheapStepsPerCall": 48,
					"requestIdentity": request_identity,
					"prevalidatedGoalCells": candidate_cells.duplicate(),
					"prevalidatedGoalSnapshotRevision": String(candidate_result.get("candidateSnapshotRevision", ""))
				})
			else:
				final = { "ok": false, "classification": "pending_budget", "reason": "candidate_shared_budget" }
			var independent_validator_calls := production_fixture.validator_calls - validator_calls_before
			var final_proof: Dictionary = final.get("proof", {}) if final.get("proof", {}) is Dictionary else {}
			var plan_validations := int(final_proof.get("validationStepsThisCall", 0))
			var cheap_steps := int(final_proof.get("cheapStepsThisCall", 0))
			call_validation_pattern.append(independent_validator_calls)
			call_cheap_step_pattern.append(cheap_steps)
			all_per_call_validations_bounded = all_per_call_validations_bounded \
				and independent_validator_calls == candidate_validations + plan_validations \
				and independent_validator_calls <= SHARED_VALIDATION_BUDGET \
				and plan_validations <= remaining_validations
			all_per_call_cheap_steps_bounded = all_per_call_cheap_steps_bounded and cheap_steps <= 48
			if bool(final.get("ok", false)) or String(final.get("classification", "")) != "pending_budget":
				break

		var unsliced_cells: Array = unsliced.get("cells", []) if unsliced.get("cells", []) is Array else []
		var production_cells: Array = final.get("cells", []) if final.get("cells", []) is Array else []
		all_exact_parity = all_exact_parity \
			and bool(unsliced.get("ok", false)) \
			and bool(final.get("ok", false)) \
			and unsliced_cells == expected \
			and production_cells == unsliced_cells
		all_exact_endpoints = all_exact_endpoints \
			and not production_cells.is_empty() \
			and production_cells.front() == Vector2i.ZERO \
			and production_cells.back() == target
		all_calls_bounded = all_calls_bounded and call_count <= MAX_PRODUCTION_CALLS
		if reference_call_count < 0:
			reference_call_count = call_count
			reference_validation_pattern = call_validation_pattern.duplicate()
		else:
			direction_neutral_calls = direction_neutral_calls and call_count == reference_call_count
			direction_neutral_validations = direction_neutral_validations and call_validation_pattern == reference_validation_pattern
		calls_by_direction[label] = call_count
		validation_patterns[label] = call_validation_pattern
		cheap_step_patterns[label] = call_cheap_step_pattern
		routes[label] = {
			"expected": vec2i_array_summary(expected),
			"unsliced": vec2i_array_summary(unsliced_cells),
			"production": vec2i_array_summary(production_cells)
		}
	var passed := all_exact_parity \
		and all_exact_endpoints \
		and all_calls_bounded \
		and all_per_call_validations_bounded \
		and all_per_call_cheap_steps_bounded \
		and direction_neutral_calls \
		and direction_neutral_validations
	return outcome(
		passed,
		"calls=%s validations=%s cheapSteps=%s routes=%s" % [JSON.stringify(calls_by_direction), JSON.stringify(validation_patterns), JSON.stringify(cheap_step_patterns), JSON.stringify(routes)],
		["four_cardinal_routes_match_frozen_unsliced_cells", "four_cardinal_routes_have_exact_start_and_goal", "shared_candidate_and_plan_validator_calls_never_exceed_two", "production_cheap_steps_never_exceed_forty_eight", "four_cardinal_routes_complete_within_eight_production_calls", "four_cardinal_call_latency_is_direction_neutral", "four_cardinal_validation_pattern_is_direction_neutral"],
		{ "calls": calls_by_direction, "validationPatterns": validation_patterns, "cheapStepPatterns": cheap_step_patterns, "routes": routes }
	)


func test_route_substrate_plan_timing_profile_contract(_mode: String) -> Dictionary:
	var substrate = CollisionBackedRouteSubstrateScript.new()
	var missing_route: Dictionary = substrate.plan_route({}, Vector2i.ZERO, [Vector2i(1, 0)])
	var missing_profile: Dictionary = substrate.take_last_plan_timing_profile()
	var missing_profile_drained: Dictionary = substrate.take_last_plan_timing_profile()
	var terminal_profile_complete := String(missing_route.get("reason", "")) == "missing_world_adapter" \
		and String(missing_profile.get("reason", "")) == "missing_world_adapter" \
		and int(missing_profile.get("snapshotCount", -1)) == 0 \
		and missing_profile_drained.is_empty()

	var fixture := ValidationCountingRouteSubstrateFixtureWorld.new()
	fixture.standable.clear()
	fixture.add_standable_rect(Vector2i(-5, -5), Vector2i(5, 5))
	fixture.doors[Vector2i(2, 0)] = { "portalId": "fixture:timing-door", "doorId": "timing-door" }
	fixture.dynamic[Vector2i(5, 5)] = { "id": "off-route-timing-occupant" }
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "plan-timing-profile"
	entry["homeInteriorMinCell"] = Vector2i(100, 100)
	entry["homeInteriorMaxCell"] = Vector2i(101, 101)
	var final: Dictionary = {}
	var profiles: Array[Dictionary] = []
	var profile_validation_matches_proof := true
	var profile_cheap_steps_match_proof := true
	var profile_validation_matches_fixture := true
	var profile_phase_kinds_match_fixture := true
	for _call_index in range(64):
		var validator_calls_before := fixture.validator_calls
		var standable_calls_before := fixture.standable_validator_calls
		var transition_calls_before := fixture.transition_validator_calls
		final = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(4, 0)], {
			"allowOutside": true,
			"maxExpansions": 128,
			"expansionsPerCall": 2,
			"validationStepsPerCall": 2,
			"cheapStepsPerCall": 128,
			"requestIdentity": "plan-timing-profile-request"
		})
		var profile: Dictionary = substrate.take_last_plan_timing_profile()
		profiles.append(profile)
		var proof: Dictionary = final.get("proof", {}) if final.get("proof", {}) is Dictionary else {}
		profile_validation_matches_proof = profile_validation_matches_proof \
			and int(profile.get("validationCount", -1)) == int(proof.get("validationStepsThisCall", 0))
		profile_cheap_steps_match_proof = profile_cheap_steps_match_proof \
			and int(profile.get("cheapStepsThisCall", -1)) == int(proof.get("cheapStepsThisCall", 0))
		profile_validation_matches_fixture = profile_validation_matches_fixture \
			and int(profile.get("validationCount", -1)) == fixture.validator_calls - validator_calls_before
		profile_phase_kinds_match_fixture = profile_phase_kinds_match_fixture \
			and int(profile.get("validationPreflightGoalCount", 0)) \
				+ int(profile.get("validationPreflightStartCount", 0)) \
				+ int(profile.get("validationFinalizeStartCount", 0)) == fixture.standable_validator_calls - standable_calls_before \
			and int(profile.get("validationSearchTransitionCount", 0)) \
				+ int(profile.get("validationFinalizeTransitionCount", 0)) == fixture.transition_validator_calls - transition_calls_before
		if bool(final.get("ok", false)) or String(final.get("classification", "")) != "pending_budget":
			break

	var duration_fields := [
		"snapshotUsec",
		"validationUsec",
		"validationPreflightGoalUsec",
		"validationPreflightStartUsec",
		"validationSearchTransitionUsec",
		"validationFinalizeStartUsec",
		"validationFinalizeTransitionUsec",
		"loopGrossUsec",
		"doorSignatureUsec",
		"dynamicSignatureUsec",
		"finalizationAssemblyUsec",
		"cheapBookkeepingResidualUsec",
		"setupResidualUsec",
		"totalUsec"
	]
	var count_fields := [
		"snapshotCount",
		"validationCount",
		"validationPreflightGoalCount",
		"validationPreflightStartCount",
		"validationSearchTransitionCount",
		"validationFinalizeStartCount",
		"validationFinalizeTransitionCount",
		"doorSignatureCells",
		"doorSignatureDoors",
		"dynamicSignatureCells",
		"dynamicSignatureOccupied",
		"cheapStepsThisCall"
	]
	var all_nonnegative := true
	var all_arithmetic_balanced := true
	var all_phase_counts_balanced := true
	var all_snapshots_single_capture := true
	var phase_counts := {
		"preflightGoal": 0,
		"preflightStart": 0,
		"searchTransition": 0,
		"finalizeStart": 0,
		"finalizeTransition": 0
	}
	var door_signature_cells := 0
	var door_signature_doors := 0
	var dynamic_signature_cells := 0
	var cheap_step_counts: Array[int] = []
	for profile in profiles:
		for field_name in duration_fields:
			all_nonnegative = all_nonnegative and int(profile.get(field_name, -1)) >= 0
		for field_name in count_fields:
			all_nonnegative = all_nonnegative and int(profile.get(field_name, -1)) >= 0
		var validation_count := int(profile.get("validationCount", 0))
		var fixed_phase_count := int(profile.get("validationPreflightGoalCount", 0)) \
			+ int(profile.get("validationPreflightStartCount", 0)) \
			+ int(profile.get("validationSearchTransitionCount", 0)) \
			+ int(profile.get("validationFinalizeStartCount", 0)) \
			+ int(profile.get("validationFinalizeTransitionCount", 0))
		var nested_loop_usec := int(profile.get("validationUsec", 0)) \
			+ int(profile.get("doorSignatureUsec", 0)) \
			+ int(profile.get("dynamicSignatureUsec", 0)) \
			+ int(profile.get("finalizationAssemblyUsec", 0))
		all_phase_counts_balanced = all_phase_counts_balanced and validation_count == fixed_phase_count
		all_arithmetic_balanced = all_arithmetic_balanced \
			and bool(profile.get("arithmeticBalanced", false)) \
			and int(profile.get("nestedLoopUsec", -1)) == nested_loop_usec \
			and int(profile.get("loopGrossUsec", -1)) == nested_loop_usec + int(profile.get("cheapBookkeepingResidualUsec", -1)) \
			and int(profile.get("totalUsec", -1)) == int(profile.get("snapshotUsec", -1)) + int(profile.get("loopGrossUsec", -1)) + int(profile.get("setupResidualUsec", -1)) \
			and int(profile.get("accountedUsec", -1)) == int(profile.get("totalUsec", -1))
		all_snapshots_single_capture = all_snapshots_single_capture and int(profile.get("snapshotCount", 0)) == 1
		phase_counts["preflightGoal"] += int(profile.get("validationPreflightGoalCount", 0))
		phase_counts["preflightStart"] += int(profile.get("validationPreflightStartCount", 0))
		phase_counts["searchTransition"] += int(profile.get("validationSearchTransitionCount", 0))
		phase_counts["finalizeStart"] += int(profile.get("validationFinalizeStartCount", 0))
		phase_counts["finalizeTransition"] += int(profile.get("validationFinalizeTransitionCount", 0))
		door_signature_cells += int(profile.get("doorSignatureCells", 0))
		door_signature_doors += int(profile.get("doorSignatureDoors", 0))
		dynamic_signature_cells += int(profile.get("dynamicSignatureCells", 0))
		cheap_step_counts.append(int(profile.get("cheapStepsThisCall", 0)))
	var all_fixed_phases_observed := true
	for phase_count in phase_counts.values():
		all_fixed_phases_observed = all_fixed_phases_observed and int(phase_count) > 0
	var final_profile_drained: Dictionary = substrate.take_last_plan_timing_profile()
	var passed := terminal_profile_complete \
		and bool(final.get("ok", false)) \
		and not profiles.is_empty() \
		and profile_validation_matches_proof \
		and profile_cheap_steps_match_proof \
		and profile_validation_matches_fixture \
		and profile_phase_kinds_match_fixture \
		and all_nonnegative \
		and all_arithmetic_balanced \
		and all_phase_counts_balanced \
		and all_snapshots_single_capture \
		and all_fixed_phases_observed \
		and door_signature_cells > 0 \
		and door_signature_doors > 0 \
		and dynamic_signature_cells > 0 \
		and final_profile_drained.is_empty()
	return outcome(
		passed,
		"profiles=%d final=%s phases=%s cheapSteps=%s doorCells=%d doors=%d dynamicCells=%d terminal=%s arithmetic=%s" % [profiles.size(), JSON.stringify(substrate_route_summary(final)), JSON.stringify(phase_counts), JSON.stringify(cheap_step_counts), door_signature_cells, door_signature_doors, dynamic_signature_cells, terminal_profile_complete, all_arithmetic_balanced],
		["terminal_and_consumed_profiles_do_not_carry_stale_data", "validation_counts_match_fixed_phases_route_proof_and_independent_fixture", "standable_and_transition_fixture_counts_match_profile_phase_kinds", "cheap_step_profile_matches_route_proof", "nonnegative_phase_arithmetic_balances_to_total"],
		{ "profileCount": profiles.size(), "final": substrate_route_summary(final), "phaseCounts": phase_counts, "cheapStepCounts": cheap_step_counts, "doorSignatureCells": door_signature_cells, "doorSignatureDoors": door_signature_doors, "dynamicSignatureCells": dynamic_signature_cells }
	)


func test_route_substrate_dynamic_signature_32_actor_progress(_mode: String) -> Dictionary:
	var substrate = CollisionBackedRouteSubstrateScript.new()
	var route: Array = []
	var route_lookup := {}
	for x in range(80):
		var cell := Vector2i(x, 0)
		route.append(cell)
		route_lookup[cell] = true
	var dynamic := {}
	for actor_index in range(80):
		var cell := Vector2i(actor_index, 1)
		dynamic[cell] = { "id": "dynamic-%d" % actor_index }
	# Include one route occupant without changing the large actor cardinality.
	dynamic.erase(Vector2i(0, 1))
	dynamic[Vector2i(60, 0)] = { "id": "dynamic-route-occupant" }
	var snapshot := {
		"revision": "dynamic-80",
		"doorStateRevision": 1,
		"doors": {},
		"dynamic": dynamic
	}
	var job := {
		"pendingRoute": route,
		"pendingRouteLookup": route_lookup,
		"finalizationDoorScanRevision": "",
		"finalizationDoorScanIndex": 0,
		"finalizationDoorParts": [],
		"finalizationDynamicPhase": "capture",
		"finalizationDynamicIndex": 0,
		"finalizationDynamicOccupied": [],
		"finalizationDynamicExpected": []
	}
	substrate._begin_plan_timing_profile()
	var slices: Array[Dictionary] = []
	var completed := {}
	for _slice_index in range(12):
		var slice: Dictionary = substrate._advance_finalization_identity(snapshot, job, 48)
		slices.append(slice)
		if bool(slice.get("complete", false)):
			completed = slice
			break
	var every_pending_slice_progressed := true
	for slice in slices:
		if not bool(slice.get("complete", false)):
			every_pending_slice_progressed = every_pending_slice_progressed and int(slice.get("steps", 0)) > 0
	var passed := not completed.is_empty() \
		and slices.size() > 3 \
		and every_pending_slice_progressed \
		and int(completed.get("steps", -1)) > 0 \
		and int(completed.get("steps", 0)) <= 48 \
		and String(completed.get("signature", "")).contains("60,0")
	return outcome(
		passed,
		"slices=%s completed=%s dynamicCount=%d" % [JSON.stringify(slices), JSON.stringify(completed), dynamic.size()],
		["eighty_cell_identity_makes_bounded_cursor_progress", "capture_and_verification_complete_without_atomic_retry", "route_occupancy_is_included_in_signature", "each_slice_obeys_forty_eight_step_cap"],
		{ "slices": slices, "completed": completed, "dynamicCount": dynamic.size() }
	)


func test_route_substrate_deferred_heap_exact_order(_mode: String) -> Dictionary:
	var substrate = CollisionBackedRouteSubstrateScript.new()
	var heap: Array = []
	var records := [
		{"bound":7, "sequence":9},
		{"bound":3, "sequence":12},
		{"bound":3, "sequence":2},
		{"bound":5, "sequence":1},
		{"bound":3, "sequence":7}
	]
	for record in records:
		substrate._deferred_heap_push(heap, record)
	var popped: Array = []
	while not heap.is_empty():
		var record: Dictionary = substrate._deferred_heap_pop(heap)
		popped.append([int(record.get("bound", -1)), int(record.get("sequence", -1))])
	var expected := [[3, 2], [3, 7], [3, 12], [5, 1], [7, 9]]
	var passed := popped == expected and heap.is_empty()
	return outcome(
		passed,
		"popped=%s" % JSON.stringify(popped),
		["deferred_heap_orders_by_bound_then_reserved_sequence", "equal_bounds_preserve_exact_legacy_tie_order", "heap_drains_without_frontier_rescan"],
		{"popped":popped, "expected":expected}
	)


func test_route_tile_local_search_source_revision(_mode: String) -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	var observed := [Vector2i(15, 0)]
	var initial := adapter.route_source_revision_for_cells(observed)
	var initial_tiles := adapter.route_source_revision_for_tiles(["0,-1", "0,0", "1,-1", "1,0"])
	adapter.static_snapshot_revision += 1
	adapter.navmesh_tile_revision_by_key["99,99"] = adapter.static_snapshot_revision
	var unrelated := adapter.route_source_revision_for_cells(observed)
	adapter.static_snapshot_revision += 1
	adapter.navmesh_tile_revision_by_key["1,0"] = adapter.static_snapshot_revision
	var halo_changed := adapter.route_source_revision_for_cells(observed)
	adapter.route_global_source_revision += 1
	var global_changed := adapter.route_source_revision_for_cells(observed)
	var mixed_adapter = GeneratedWorldNavigationAdapterScript.new()
	var before_mixed := mixed_adapter.route_source_revision_for_cells(observed)
	mixed_adapter.apply_navigation_events([
		{ "revision": 10, "tileKey": "99,99", "changeKinds": [NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED] },
		{ "revision": 11, "tileKey": "", "changeKinds": [NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED] }
	])
	var after_mixed := mixed_adapter.route_source_revision_for_cells(observed)
	var passed: bool = initial == initial_tiles and initial == unrelated and unrelated != halo_changed and halo_changed != global_changed and before_mixed != after_mixed
	return outcome(passed,
		"initial=%s unrelated=%s halo=%s global=%s" % [initial, unrelated, halo_changed, global_changed],
		["unrelated_tile_publication_preserves_route_source", "neighboring_collision_halo_invalidates_route_source", "unscoped_change_invalidates_route_source", "mixed_scoped_and_unscoped_batch_invalidates_route_source"],
		{ "initial": initial, "unrelated": unrelated, "halo": halo_changed, "global": global_changed, "beforeMixed": before_mixed, "afterMixed": after_mixed })


func test_route_incremental_approach_certification(_mode: String) -> Dictionary:
	var adapter := IncrementalApproachAdapter.new()
	for index in range(12):
		adapter.ordered_cells.append(Vector2i(index + 1, 0))
	adapter.captured_standable[Vector2i(9, 0)] = true
	adapter.captured_standable[Vector2i(10, 0)] = true
	# The first captured match becomes occupied before publication; the adapter
	# must keep it invisible and continue to the next exact ordered candidate.
	adapter.live_standable[Vector2i(10, 0)] = true
	var entry := {"id":"incremental-approach", "inputIdentity":"stable"}
	var results: Array[Dictionary] = []
	for _call_index in range(8):
		var result: Dictionary = adapter.advance_first_approach_cell(entry, Vector3.ZERO, false, "approach-request", 4)
		results.append(result)
		if String(result.get("status", "")) in ["ready", "exhausted"]:
			break
	var final: Dictionary = results.back()
	var partials_hide_cells := true
	var bounded := true
	for result in results:
		bounded = bounded and int(result.get("validatedThisCall", 0)) <= 4
		if String(result.get("status", "")) == "pending":
			partials_hide_cells = partials_hide_cells and result.get("cell", Vector2i.ZERO) == Vector2i(999999, 999999)
	var census := adapter.approach_certification_census()
	var pending_before_source_change := adapter.advance_first_approach_cell(entry, Vector3.ZERO, false, "source-change-request", 4)
	adapter.static_snapshot_revision += 1
	var invalidated := adapter.advance_first_approach_cell(entry, Vector3.ZERO, false, "source-change-request", 4)
	var census_after_invalidation := adapter.approach_certification_census()
	var pending_before_cancel := adapter.advance_first_approach_cell(entry, Vector3.ZERO, false, "cancel-request", 4)
	var cancelled := adapter.cancel_approach_cell_certification(entry)
	var census_after_cancel := adapter.approach_certification_census()
	var local_adapter := IncrementalApproachAdapter.new()
	local_adapter.use_tile_local_identity = true
	for index in range(12):
		local_adapter.ordered_cells.append(Vector2i(index + 1, 0))
	local_adapter.captured_standable[Vector2i(12, 0)] = true
	local_adapter.live_standable[Vector2i(12, 0)] = true
	var unrelated_churn_results: Array[Dictionary] = []
	for churn_index in range(6):
		var churn_result: Dictionary = local_adapter.advance_first_approach_cell(entry, Vector3.ZERO, false, "unrelated-churn", 4)
		unrelated_churn_results.append(churn_result)
		if String(churn_result.get("status", "")) in ["ready", "exhausted"]:
			break
		local_adapter.static_snapshot_revision += 1
		local_adapter.semantic_revision += 1
		local_adapter.door_state_revision += 1
		local_adapter.terrain_revision_clock += 1
		local_adapter.navmesh_tile_revision_by_key["99,99"] = local_adapter.static_snapshot_revision
		local_adapter.navmesh_tile_semantic_revision_by_key["99,99"] = local_adapter.semantic_revision
		local_adapter.navmesh_tile_door_revision_by_key["99,99"] = local_adapter.door_state_revision
		local_adapter.navmesh_tile_terrain_revision_by_key["99,99"] = local_adapter.terrain_revision_clock
	var churn_final: Dictionary = unrelated_churn_results.back()
	var relevant_pending := local_adapter.advance_first_approach_cell(entry, Vector3.ZERO, false, "relevant-change", 4)
	var relevant_tile := local_adapter.tile_key_for_cell(Vector2i(1, 0))
	local_adapter.door_state_revision += 1
	local_adapter.navmesh_tile_door_revision_by_key[relevant_tile] = local_adapter.door_state_revision
	var relevant_invalidated := local_adapter.advance_first_approach_cell(entry, Vector3.ZERO, false, "relevant-change", 4)
	var passed: bool = results.size() >= 3 \
		and String(final.get("status", "")) == "ready" \
		and final.get("cell", Vector2i.ZERO) == Vector2i(10, 0) \
		and partials_hide_cells \
		and bounded \
		and int(census.get("jobCount", -1)) == 0 \
		and String(pending_before_source_change.get("status", "")) == "pending" \
		and String(invalidated.get("status", "")) == "invalidated" \
		and invalidated.get("cell", Vector2i.ZERO) == Vector2i(999999, 999999) \
		and int(census_after_invalidation.get("jobCount", -1)) == 0 \
		and String(pending_before_cancel.get("status", "")) == "pending" \
		and cancelled == 1 \
		and int(census_after_cancel.get("jobCount", -1)) == 0 \
		and String(churn_final.get("status", "")) == "ready" \
		and churn_final.get("cell", Vector2i.ZERO) == Vector2i(12, 0) \
		and String(relevant_pending.get("status", "")) == "pending" \
		and String(relevant_invalidated.get("status", "")) == "invalidated"
	return outcome(
		passed,
		"results=%s census=%s invalidated=%s cancelled=%d churn=%s relevant=%s validations=%s snapshots=%d" % [JSON.stringify(results), JSON.stringify(census), JSON.stringify(invalidated), cancelled, JSON.stringify(unrelated_churn_results), JSON.stringify(relevant_invalidated), JSON.stringify(vec2i_array_summary(adapter.validations)), adapter.snapshot_calls],
		["approach_certification_is_bounded_and_resumable", "partial_work_never_exposes_a_cell", "captured_first_match_is_live_revalidated", "next_exact_ordered_match_is_selected", "terminal_job_is_evicted", "source_change_atomically_invalidates_partial_job", "actor_cancel_evicts_partial_job", "unrelated_tile_revision_churn_does_not_starve_job", "relevant_tile_revision_invalidates_partial_job"],
		{"results":results, "census":census, "invalidated":invalidated, "cancelled":cancelled, "censusAfterCancel":census_after_cancel, "unrelatedChurn":unrelated_churn_results, "relevantInvalidated":relevant_invalidated, "validations":vec2i_array_summary(adapter.validations), "snapshotCalls":adapter.snapshot_calls}
	)


func test_route_substrate_lazy_frontier_honors_cheaper_deferred_goal(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "cheaper-deferred-goal"
	var final: Dictionary = {}
	var saw_deferred := false
	for _call_index in range(64):
		final = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(2, 0), Vector2i(0, 1)], {
			"allowOutside": true,
			"maxExpansions": 128,
			"expansionsPerCall": 2,
			"validationStepsPerCall": 1,
			"requestIdentity": "cheaper-deferred-goal-request"
		})
		saw_deferred = saw_deferred or int(substrate.candidate_cache_census().get("deferredRecordCount", 0)) > 0
		if bool(final.get("ok", false)) or String(final.get("classification", "")) != "pending_budget":
			break
	var cells: Array = final.get("cells", []) if final.get("cells", []) is Array else []
	var passed := saw_deferred \
		and bool(final.get("ok", false)) \
		and cells == [Vector2i.ZERO, Vector2i(0, 1)] \
		and int((final.get("proof", {}) as Dictionary).get("expansions", -1)) == 1 \
		and int(substrate.candidate_cache_census().get("searchJobCount", -1)) == 0
	return outcome(
		passed,
		"sawDeferred=%s final=%s cells=%s" % [str(saw_deferred), JSON.stringify(substrate_route_summary(final)), JSON.stringify(vec2i_array_summary(cells))],
		["deferred_sibling_is_observed_before_goal_commit", "unvalidated_sibling_lower_bound_prevents_costlier_frontier_pop", "cheapest_adjacent_goal_wins", "successful_lazy_search_cleans_frontier"],
		{ "sawDeferred": saw_deferred, "final": substrate_route_summary(final), "cells": vec2i_array_summary(cells), "census": substrate.candidate_cache_census() }
	)


func test_route_substrate_lazy_frontier_exhaustion_cleans_deferred_records(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	fixture.standable.clear()
	fixture.add_standable_rect(Vector2i(0, -1), Vector2i(4, 1))
	for z in range(-1, 2):
		fixture.blocked[Vector2i(3, z)] = { "id": "exhaustion-wall-%d" % z }
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "lazy-exhaustion"
	var final: Dictionary = {}
	var saw_deferred := false
	for _call_index in range(256):
		final = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(4, 0)], {
			"allowOutside": true,
			"maxExpansions": 128,
			"expansionsPerCall": 2,
			"validationStepsPerCall": 2,
			"requestIdentity": "lazy-exhaustion-request"
		})
		saw_deferred = saw_deferred or int(substrate.candidate_cache_census().get("deferredRecordCount", 0)) > 0
		if String(final.get("classification", "")) != "pending_budget":
			break
	var census := substrate.candidate_cache_census()
	var passed := saw_deferred \
		and not bool(final.get("ok", true)) \
		and String(final.get("classification", "")) == "unreachable_static" \
		and int(census.get("searchJobCount", -1)) == 0 \
		and int(census.get("deferredRecordCount", -1)) == 0
	return outcome(
		passed,
		"sawDeferred=%s final=%s census=%s" % [str(saw_deferred), JSON.stringify(substrate_route_summary(final)), JSON.stringify(census)],
		["deferred_edges_are_eventually_exhausted", "unreachable_result_remains_complete", "terminal_cleanup_removes_all_deferred_records"],
		{ "sawDeferred": saw_deferred, "final": substrate_route_summary(final), "census": census }
	)


func test_route_substrate_reordered_candidates_resume_job_order(_mode: String) -> Dictionary:
	var fixture := CandidateOrderRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "candidate-order-resume"
	var original := [Vector2i(5, 0), Vector2i(4, 1), Vector2i(3, -1)]
	var options := {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 2,
		"validationStepsPerCall": 1,
		"requestIdentity": "candidate-order-resume-request"
	}
	var first: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, original, options)
	var second: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(4, 1), Vector2i(3, -1), Vector2i(5, 0)], options)
	var third: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(3, -1), Vector2i(5, 0), Vector2i(4, 1)], options)
	var third_proof: Dictionary = third.get("proof", {}) if third.get("proof", {}) is Dictionary else {}
	var accepted: Array = third_proof.get("acceptedGoals", []) if third_proof.get("acceptedGoals", []) is Array else []
	var first_three_validations: Array = fixture.validated_cells.slice(0, mini(3, fixture.validated_cells.size()))
	var passed := String(first.get("classification", "")) == "pending_budget" \
		and String(second.get("classification", "")) == "pending_budget" \
		and String(third.get("classification", "")) == "pending_budget" \
		and first_three_validations == original \
		and accepted.size() == original.size()
	for candidate in original:
		passed = passed and accepted.has(candidate)
	return outcome(
		passed,
		"validated=%s accepted=%s proof=%s" % [JSON.stringify(vec2i_array_summary(first_three_validations)), JSON.stringify(vec2i_array_summary(accepted)), JSON.stringify(third_proof)],
		["canonical_goal_set_keeps_persisted_candidate_order", "reordered_resumed_calls_do_not_skip_or_duplicate_preflight", "all_equivalent_goals_are_accepted_once"],
		{ "validated": vec2i_array_summary(first_three_validations), "accepted": vec2i_array_summary(accepted), "third": substrate_route_summary(third) }
	)


func test_route_substrate_validation_microphases_resume_fresh_snapshot(_mode: String) -> Dictionary:
	var fixture := SnapshotReuseRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "validation-microphase-resume"
	var options := {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 2,
		"validationStepsPerCall": 2,
		"requestIdentity": "validation-microphase-request"
	}
	var results: Array[Dictionary] = []
	results.append(substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options))
	results.append(substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options))
	var census_partial: Dictionary = substrate.candidate_cache_census()
	# The goal-directed frontier has already validated cells 1 and 2. Block the
	# next not-yet-validated forward cell so the resumed slice must observe the
	# freshly captured dynamic snapshot rather than a deferred side branch.
	fixture.dynamic[Vector2i(3, 0)] = { "id": "late-dynamic-blocker", "kind": "npc" }
	results.append(substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options))
	var third_proof: Dictionary = results[2].get("proof", {}) if results[2].get("proof", {}) is Dictionary else {}
	var saw_fresh_dynamic_block := false
	for blocked_value in third_proof.get("blocked", []):
		if blocked_value is Dictionary and String((blocked_value as Dictionary).get("reason", "")) == "blocked_dynamic":
			saw_fresh_dynamic_block = true
			break
	fixture.dynamic.erase(Vector2i(3, 0))
	var saw_reconstruct := false
	var saw_materialize := false
	var saw_finalize := false
	var all_steps_capped := true
	var expansion_sum := 0
	for existing_result in results:
		var existing_proof: Dictionary = existing_result.get("proof", {}) if existing_result.get("proof", {}) is Dictionary else {}
		all_steps_capped = all_steps_capped and int(existing_proof.get("validationStepsThisCall", 0)) <= 2
		expansion_sum += int(existing_proof.get("expansionsThisCall", 0))
		saw_reconstruct = saw_reconstruct or String(existing_proof.get("searchPhase", "")) == "reconstruct"
		saw_materialize = saw_materialize or String(existing_proof.get("searchPhase", "")) == "materialize_route"
		saw_finalize = saw_finalize or String(existing_proof.get("searchPhase", "")) == "finalize"
	var final: Dictionary = results.back()
	for _call_index in range(128):
		if bool(final.get("ok", false)) or String(final.get("classification", "")) != "pending_budget":
			break
		final = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options)
		results.append(final)
		var proof: Dictionary = final.get("proof", {}) if final.get("proof", {}) is Dictionary else {}
		all_steps_capped = all_steps_capped and int(proof.get("validationStepsThisCall", 0)) <= 2
		expansion_sum += int(proof.get("expansionsThisCall", 0))
		saw_reconstruct = saw_reconstruct or String(proof.get("searchPhase", "")) == "reconstruct"
		saw_materialize = saw_materialize or String(proof.get("searchPhase", "")) == "materialize_route"
		saw_finalize = saw_finalize or String(proof.get("searchPhase", "")) == "finalize"
	var first_proof: Dictionary = results[0].get("proof", {}) if results[0].get("proof", {}) is Dictionary else {}
	var second_proof: Dictionary = results[1].get("proof", {}) if results[1].get("proof", {}) is Dictionary else {}
	var final_proof: Dictionary = final.get("proof", {}) if final.get("proof", {}) is Dictionary else {}
	var passed := String(first_proof.get("searchPhase", "")) == "search" \
		and int(first_proof.get("expansionsThisCall", -1)) == 1 \
		and int(second_proof.get("expansionsThisCall", -1)) == 2 \
		and int(third_proof.get("validationStepsThisCall", -1)) == 2 \
		and int(census_partial.get("deferredRecordCount", 0)) > 0 \
		and saw_fresh_dynamic_block \
		and saw_finalize \
		and all_steps_capped \
		and bool(final.get("ok", false)) \
		and expansion_sum == int(final_proof.get("expansions", -1)) \
		and fixture.snapshot_build_count == results.size()
	return outcome(
		passed,
		"calls=%d builds=%d partial=%s second=%s third=%s final=%s" % [results.size(), fixture.snapshot_build_count, JSON.stringify(census_partial), JSON.stringify(second_proof), JSON.stringify(third_proof), JSON.stringify(substrate_route_summary(final))],
		["partial_edge_queue_resumes_across_calls", "resumed_edge_uses_fresh_dynamic_snapshot", "each_call_obeys_two_validation_step_cap", "node_expansion_count_is_not_double_charged", "cheap_reconstruction_and_materialization_do_not_require_idle_calls", "route_revalidation_remains_staged"],
		{ "callCount": results.size(), "snapshotBuilds": fixture.snapshot_build_count, "partialCensus": census_partial, "secondProof": second_proof, "thirdProof": third_proof, "final": substrate_route_summary(final), "expansionSum": expansion_sum }
	)


func test_route_substrate_unrelated_static_publication_preserves_search(_mode: String) -> Dictionary:
	var fixture := LocalRevisionRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "local-source-revision"
	var options := {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 2,
		"validationStepsPerCall": 1,
		"requestIdentity": "local-source-revision-request"
	}
	var first: Dictionary = {}
	for _call_index in range(8):
		first = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options)
		if int((first.get("proof", {}) as Dictionary).get("expansions", 0)) > 0:
			break
	var first_expansions := int((first.get("proof", {}) as Dictionary).get("expansions", 0))
	fixture.static_snapshot_revision += 1
	fixture.tile_source_revisions[Vector2i(99, 99)] = 2
	var preserved: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options)
	var preserved_proof: Dictionary = preserved.get("proof", {}) if preserved.get("proof", {}) is Dictionary else {}
	fixture.static_snapshot_revision += 1
	fixture.tile_source_revisions[Vector2i(0, 0)] = 2
	var invalidated: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options)
	var passed: bool = first_expansions > 0 \
		and String(preserved.get("reason", "")) != "route_snapshot_changed" \
		and int(preserved_proof.get("expansions", 0)) >= first_expansions \
		and String(invalidated.get("reason", "")) == "route_snapshot_changed" \
		and substrate.candidate_cache_census().get("searchJobCount", -1) == 0
	return outcome(passed,
		"first=%d preserved=%s invalidated=%s" % [first_expansions, JSON.stringify(substrate_route_summary(preserved)), JSON.stringify(substrate_route_summary(invalidated))],
		["unrelated_static_publication_keeps_incremental_search", "touched_tile_change_invalidates_search", "no_stale_route_commits"],
		{ "firstExpansions": first_expansions, "preserved": substrate_route_summary(preserved), "invalidated": substrate_route_summary(invalidated) })


func test_route_substrate_source_revision_invalidates_partial_neighbor(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "partial-neighbor-revision"
	var options := {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 2,
		"validationStepsPerCall": 1,
		"requestIdentity": "partial-neighbor-revision-request"
	}
	var preflight: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options)
	var start: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options)
	var partial: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options)
	var partial_proof: Dictionary = partial.get("proof", {}) if partial.get("proof", {}) is Dictionary else {}
	var census_partial: Dictionary = substrate.candidate_cache_census()
	fixture.static_snapshot_revision += 1
	var invalidated: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options)
	var invalidated_proof: Dictionary = invalidated.get("proof", {}) if invalidated.get("proof", {}) is Dictionary else {}
	var census_after: Dictionary = substrate.candidate_cache_census()
	var passed := String(preflight.get("classification", "")) == "pending_budget" \
		and String(start.get("classification", "")) == "pending_budget" \
		and int(partial_proof.get("expansionsThisCall", -1)) == 1 \
		and int(census_partial.get("deferredRecordCount", 0)) > 0 \
		and String(invalidated.get("reason", "")) == "route_snapshot_changed" \
		and bool(invalidated_proof.get("searchSnapshotChanged", false)) \
		and String(invalidated_proof.get("invalidatedPhase", "")) == "search" \
		and int(invalidated_proof.get("invalidatedNeighborIndex", -1)) == int(partial_proof.get("neighborIndex", -2)) \
		and int(census_after.get("searchJobCount", -1)) == 0 \
		and int(census_after.get("searchActorCount", -1)) == 0
	return outcome(
		passed,
		"partial=%s invalidated=%s before=%s after=%s" % [JSON.stringify(partial_proof), JSON.stringify(invalidated_proof), JSON.stringify(census_partial), JSON.stringify(census_after)],
		["source_revision_invalidates_persisted_edge_queue", "invalidated_partial_search_does_not_commit", "revision_invalidation_cleans_request_owned_job"],
		{ "partial": substrate_route_summary(partial), "partialProof": partial_proof, "invalidated": substrate_route_summary(invalidated), "invalidatedProof": invalidated_proof, "censusBefore": census_partial, "censusAfter": census_after }
	)


func test_route_substrate_source_revision_invalidates_finalization(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "finalization-revision"
	var options := {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 2,
		"validationStepsPerCall": 1,
		"requestIdentity": "finalization-revision-request"
	}
	var partial_finalize: Dictionary = {}
	var all_steps_capped := true
	for _call_index in range(128):
		var result: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(2, 0)], options)
		var proof: Dictionary = result.get("proof", {}) if result.get("proof", {}) is Dictionary else {}
		all_steps_capped = all_steps_capped and int(proof.get("validationStepsThisCall", 0)) <= 1
		if String(proof.get("searchPhase", "")) == "finalize" and int(proof.get("finalizeIndex", 0)) > 0:
			partial_finalize = result
			break
	var partial_proof: Dictionary = partial_finalize.get("proof", {}) if partial_finalize.get("proof", {}) is Dictionary else {}
	var census_partial: Dictionary = substrate.candidate_cache_census()
	fixture.terrain_revision += 1
	var invalidated: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(2, 0)], options)
	var invalidated_proof: Dictionary = invalidated.get("proof", {}) if invalidated.get("proof", {}) is Dictionary else {}
	var census_after: Dictionary = substrate.candidate_cache_census()
	var passed := not partial_finalize.is_empty() \
		and all_steps_capped \
		and int(census_partial.get("finalizingJobCount", 0)) == 1 \
		and String(invalidated.get("reason", "")) == "route_snapshot_changed" \
		and String(invalidated_proof.get("invalidatedPhase", "")) == "finalize" \
		and int(invalidated_proof.get("invalidatedFinalizeIndex", 0)) == int(partial_proof.get("finalizeIndex", -1)) \
		and int(invalidated_proof.get("invalidatedFinalizeIndex", 0)) > 0 \
		and int(census_after.get("searchJobCount", -1)) == 0 \
		and int(census_after.get("searchActorCount", -1)) == 0
	return outcome(
		passed,
		"partial=%s invalidated=%s before=%s after=%s" % [JSON.stringify(partial_proof), JSON.stringify(invalidated_proof), JSON.stringify(census_partial), JSON.stringify(census_after)],
		["route_completion_is_persisted_across_calls", "source_revision_invalidates_mid_finalization", "stale_partially_validated_route_never_commits", "finalization_invalidation_cleans_request_owned_job"],
		{ "partial": substrate_route_summary(partial_finalize), "partialProof": partial_proof, "invalidated": substrate_route_summary(invalidated), "invalidatedProof": invalidated_proof, "censusBefore": census_partial, "censusAfter": census_after }
	)


func test_route_substrate_live_occupancy_restarts_finalization(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "dynamic-finalization-restart"
	var options := {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 2,
		"validationStepsPerCall": 1,
		"requestIdentity": "dynamic-finalization-restart-request"
	}
	var partial: Dictionary = {}
	for _call_index in range(128):
		var result: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(3, 0)], options)
		var proof: Dictionary = result.get("proof", {}) if result.get("proof", {}) is Dictionary else {}
		if String(proof.get("searchPhase", "")) == "finalize" and int(proof.get("finalizeIndex", 0)) >= 2:
			partial = result
			break
	var partial_proof: Dictionary = partial.get("proof", {}) if partial.get("proof", {}) is Dictionary else {}
	var completed_expansions := int(partial_proof.get("expansions", -1))
	fixture.dynamic[Vector2i(1, 0)] = { "id": "late-finalization-actor", "kind": "npc" }
	# Deliberately do not advance dynamic_revision: production live NPC/player
	# motion refreshes captured occupancy without advancing that counter.
	var restarted: Dictionary = {}
	var restarted_proof: Dictionary = {}
	var rejected: Dictionary = {}
	var stale_commit := false
	for _detection_call in range(16):
		var detection: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(3, 0)], options)
		var detection_proof: Dictionary = detection.get("proof", {}) if detection.get("proof", {}) is Dictionary else {}
		stale_commit = stale_commit or bool(detection.get("ok", false))
		if bool(detection_proof.get("finalizationRestartedThisCall", false)):
			restarted = detection
			restarted_proof = detection_proof
			break
	for _rejection_call in range(16):
		rejected = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(3, 0)], options)
		if bool(rejected.get("ok", false)) or String(rejected.get("classification", "")) != "pending_budget" or String(rejected.get("reason", "")) == "route_snapshot_changed":
			break
	var rejected_proof: Dictionary = rejected.get("proof", {}) if rejected.get("proof", {}) is Dictionary else {}
	var completed_validation: Dictionary = rejected_proof.get("completedRouteValidation", {}) if rejected_proof.get("completedRouteValidation", {}) is Dictionary else {}
	var census_after: Dictionary = substrate.candidate_cache_census()
	var passed := not partial.is_empty() \
		and not stale_commit \
		and bool(restarted_proof.get("finalizationRestartedThisCall", false)) \
		and int(restarted_proof.get("finalizationRestartCount", 0)) == 1 \
		and int(restarted_proof.get("expansions", -2)) == completed_expansions \
		and not bool(rejected.get("ok", true)) \
		and String(rejected.get("reason", "")) == "route_snapshot_changed" \
		and not bool(rejected_proof.get("finalizationRestartedThisCall", true)) \
		and String(completed_validation.get("reason", "")) == "blocked_dynamic" \
		and int(rejected_proof.get("expansions", -2)) == completed_expansions \
		and int(census_after.get("searchJobCount", -1)) == 0 \
		and int(census_after.get("searchActorCount", -1)) == 0
	return outcome(
		passed,
		"partial=%s restarted=%s rejected=%s census=%s" % [JSON.stringify(partial_proof), JSON.stringify(restarted_proof), JSON.stringify(rejected_proof), JSON.stringify(census_after)],
		["captured_live_occupancy_restarts_partial_finalization_without_dynamic_revision", "bounded_verification_detects_live_change_before_commit", "completed_search_expansions_are_preserved", "stale_prefix_cannot_commit_after_dynamic_block", "failed_refinalization_cleans_owned_job"],
		{ "partial": substrate_route_summary(partial), "restarted": substrate_route_summary(restarted), "restartedProof": restarted_proof, "rejected": substrate_route_summary(rejected), "rejectedProof": rejected_proof, "censusAfter": census_after }
	)


func test_route_substrate_door_revision_restarts_finalization(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var old_door := collision_door(Vector2i(1, 0))
	old_door.set_meta("door_portal_id", "door:test:old-finalization")
	fixture.doors[Vector2i(1, 0)] = old_door
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "door-finalization-restart"
	var options := {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 2,
		"validationStepsPerCall": 1,
		"requestIdentity": "door-finalization-restart-request"
	}
	var partial: Dictionary = {}
	for _call_index in range(128):
		var result: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(3, 0)], options)
		var proof: Dictionary = result.get("proof", {}) if result.get("proof", {}) is Dictionary else {}
		if String(proof.get("searchPhase", "")) == "finalize" and int(proof.get("finalizeIndex", 0)) >= 2:
			partial = result
			break
	var partial_proof: Dictionary = partial.get("proof", {}) if partial.get("proof", {}) is Dictionary else {}
	var completed_expansions := int(partial_proof.get("expansions", -1))
	var replacement_door := collision_door(Vector2i(1, 0))
	replacement_door.set_meta("door_portal_id", "door:test:replacement-finalization")
	fixture.doors[Vector2i(1, 0)] = replacement_door
	fixture.door_state_revision += 1
	var final: Dictionary = {}
	var saw_restart := false
	for _call_index in range(128):
		final = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(3, 0)], options)
		var proof: Dictionary = final.get("proof", {}) if final.get("proof", {}) is Dictionary else {}
		saw_restart = saw_restart or bool(proof.get("finalizationRestartedThisCall", false))
		if bool(final.get("ok", false)) or String(final.get("classification", "")) != "pending_budget":
			break
	var final_proof: Dictionary = final.get("proof", {}) if final.get("proof", {}) is Dictionary else {}
	var action_portals: Array[String] = []
	var actions: Dictionary = final.get("actions", {}) if final.get("actions", {}) is Dictionary else {}
	for action_value in actions.values():
		if action_value is Dictionary:
			action_portals.append(String((action_value as Dictionary).get("portalId", "")))
	var edge_portals: Array[String] = []
	for edge_value in final_proof.get("doorEdges", []):
		if not (edge_value is Dictionary):
			continue
		var door_summary: Dictionary = (edge_value as Dictionary).get("door", {}) if (edge_value as Dictionary).get("door", {}) is Dictionary else {}
		edge_portals.append(String(door_summary.get("portalId", "")))
	var all_current_actions := actions.size() == 2
	for portal_id in action_portals:
		all_current_actions = all_current_actions and portal_id == "door:test:replacement-finalization"
	var all_current_edges := edge_portals.size() == 2
	for portal_id in edge_portals:
		all_current_edges = all_current_edges and portal_id == "door:test:replacement-finalization"
	var census_after: Dictionary = substrate.candidate_cache_census()
	var passed := not partial.is_empty() \
		and saw_restart \
		and bool(final.get("ok", false)) \
		and int(final_proof.get("finalizationRestartCount", 0)) == 1 \
		and int(final_proof.get("expansions", -2)) == completed_expansions \
		and all_current_actions \
		and all_current_edges \
		and (final.get("cells", []) as Array) == [Vector2i.ZERO, Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)] \
		and int(census_after.get("searchJobCount", -1)) == 0 \
		and int(census_after.get("searchActorCount", -1)) == 0
	var summary := substrate_route_summary(final)
	old_door.free()
	replacement_door.free()
	return outcome(
		passed,
		"partial=%s final=%s actionPortals=%s edgePortals=%s census=%s" % [JSON.stringify(partial_proof), JSON.stringify(summary), JSON.stringify(action_portals), JSON.stringify(edge_portals), JSON.stringify(census_after)],
		["door_revision_restarts_partial_finalization_from_zero", "completed_search_expansions_are_preserved", "door_edges_and_actions_use_current_portal", "successful_refinalization_cleans_owned_job"],
		{ "partial": substrate_route_summary(partial), "final": summary, "actionPortals": action_portals, "edgePortals": edge_portals, "censusAfter": census_after }
	)


func test_route_substrate_unrelated_door_change_preserves_finalization(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "unrelated-door-finalization"
	var options := {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 2,
		"validationStepsPerCall": 1,
		"requestIdentity": "unrelated-door-finalization-request"
	}
	var partial: Dictionary = {}
	for _call_index in range(128):
		var result: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(3, 0)], options)
		var proof: Dictionary = result.get("proof", {}) if result.get("proof", {}) is Dictionary else {}
		if String(proof.get("searchPhase", "")) == "finalize" and int(proof.get("finalizeIndex", 0)) >= 1:
			partial = result
			break
	var partial_proof: Dictionary = partial.get("proof", {}) if partial.get("proof", {}) is Dictionary else {}
	var unrelated_door := collision_door(Vector2i(5, 2))
	unrelated_door.set_meta("door_portal_id", "door:test:unrelated-finalization")
	fixture.doors[Vector2i(5, 2)] = unrelated_door
	fixture.door_state_revision += 1
	var continued: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(3, 0)], options)
	var continued_proof: Dictionary = continued.get("proof", {}) if continued.get("proof", {}) is Dictionary else {}
	var final := continued
	for _call_index in range(128):
		if bool(final.get("ok", false)) or String(final.get("classification", "")) != "pending_budget":
			break
		final = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(3, 0)], options)
	var census := substrate.candidate_cache_census()
	var passed := not partial.is_empty() \
		and not bool(continued_proof.get("finalizationRestartedThisCall", false)) \
		and int(continued_proof.get("finalizationRestartCount", -1)) == 0 \
		and int(continued_proof.get("finalizeIndex", 0)) > int(partial_proof.get("finalizeIndex", -1)) \
		and bool(final.get("ok", false)) \
		and int(census.get("searchJobCount", -1)) == 0
	var summary := substrate_route_summary(final)
	unrelated_door.free()
	return outcome(
		passed,
		"partial=%s continued=%s final=%s census=%s" % [JSON.stringify(partial_proof), JSON.stringify(continued_proof), JSON.stringify(summary), JSON.stringify(census)],
		["unrelated_global_door_revision_does_not_restart_finalization", "route_local_door_signature_preserves_progress", "unrelated_door_change_keeps_exact_route", "successful_finalization_cleans_job"],
		{ "partial": substrate_route_summary(partial), "continued": substrate_route_summary(continued), "continuedProof": continued_proof, "final": summary, "census": census }
	)


func test_route_substrate_same_instance_door_lock_restarts_finalization(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var door := collision_door(Vector2i(1, 0))
	door.set_meta("door_portal_id", "door:test:same-instance-lock")
	fixture.doors[Vector2i(1, 0)] = door
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "same-instance-door-lock"
	var options := {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 2,
		"validationStepsPerCall": 1,
		"requestIdentity": "same-instance-door-lock-request"
	}
	var partial: Dictionary = {}
	for _call_index in range(128):
		var result: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(3, 0)], options)
		var proof: Dictionary = result.get("proof", {}) if result.get("proof", {}) is Dictionary else {}
		if String(proof.get("searchPhase", "")) == "finalize" and int(proof.get("finalizeIndex", 0)) >= 2:
			partial = result
			break
	door.set_meta("locked", true)
	fixture.door_state_revision += 1
	var rejected: Dictionary = {}
	var stale_commit := false
	for _detection_call in range(16):
		rejected = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(3, 0)], options)
		stale_commit = stale_commit or bool(rejected.get("ok", false))
		if bool(rejected.get("ok", false)) or String(rejected.get("classification", "")) != "pending_budget" or String(rejected.get("reason", "")) == "route_snapshot_changed":
			break
	var rejected_proof: Dictionary = rejected.get("proof", {}) if rejected.get("proof", {}) is Dictionary else {}
	var completed_validation: Dictionary = rejected_proof.get("completedRouteValidation", {}) if rejected_proof.get("completedRouteValidation", {}) is Dictionary else {}
	var census := substrate.candidate_cache_census()
	var passed := not partial.is_empty() \
		and not stale_commit \
		and not bool(rejected.get("ok", true)) \
		and String(rejected.get("reason", "")) == "route_snapshot_changed" \
		and String(completed_validation.get("reason", "")) == "door_locked" \
		and int(census.get("searchJobCount", -1)) == 0
	var partial_summary := substrate_route_summary(partial)
	door.free()
	return outcome(
		passed,
		"partial=%s rejected=%s census=%s" % [JSON.stringify(partial_summary), JSON.stringify(rejected_proof), JSON.stringify(census)],
		["same_instance_lock_fact_changes_live_transition_proof", "lock_change_is_detected_during_bounded_finalization", "locked_door_cannot_commit_stale_prefix", "failed_lock_revalidation_cleans_job"],
		{ "partial": partial_summary, "rejected": substrate_route_summary(rejected), "rejectedProof": rejected_proof, "census": census }
	)


func test_route_executor_shares_candidate_and_plan_validation_cap(_mode: String) -> Dictionary:
	var fixture := ValidationCountingRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var authority = NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, BudgetedCollisionProbe.new())
	var executor = NpcPlanExecutorScript.new()
	var body := Node3D.new()
	runner.add_child(body)
	body.position = Vector3.ZERO
	var entry := fixture.generated_town_entry()
	entry["id"] = "shared-validation-ledger"
	entry["body"] = body
	var all_capped := true
	var saw_candidate_only := false
	var saw_mixed_candidate_and_plan := false
	var ledgers: Array = []
	var active: Dictionary = {}
	for _call_index in range(8):
		authority.begin_frame()
		var validator_calls_before := fixture.validator_calls
		executor._plan_and_commit_routine_v2_route(
			entry, body, authority, substrate, fixture, active, 1.0 / 60.0, 2.0,
			"work", fixture.cell_position(Vector2i(4, 0)), "work_area", true, 90,
			"shared_validation_contract", "shared-validation-route-key"
		)
		active = authority.runtime_for_entry(entry)
		var ledger: Dictionary = entry.get("routineRouteV2LastValidationBudget", {}) if entry.get("routineRouteV2LastValidationBudget", {}) is Dictionary else {}
		if ledger.is_empty():
			continue
		var independent_used := fixture.validator_calls - validator_calls_before
		ledger["independentValidatorCalls"] = independent_used
		ledgers.append(ledger.duplicate(true))
		var candidate_used := int(ledger.get("candidateUsed", 0))
		var plan_used := int(ledger.get("planUsed", 0))
		all_capped = all_capped \
			and int(ledger.get("granted", -1)) == 2 \
			and int(ledger.get("totalUsed", 99)) <= 2 \
			and independent_used == int(ledger.get("totalUsed", -1)) \
			and independent_used <= 2
		saw_candidate_only = saw_candidate_only or (candidate_used == 2 and plan_used == 0)
		saw_mixed_candidate_and_plan = saw_mixed_candidate_and_plan or (candidate_used > 0 and plan_used > 0 and candidate_used + plan_used == 2)
		if saw_candidate_only and saw_mixed_candidate_and_plan:
			break
	var passed := not ledgers.is_empty() and all_capped and saw_candidate_only and saw_mixed_candidate_and_plan
	body.queue_free()
	return outcome(
		passed,
		"ledgers=%s" % JSON.stringify(ledgers),
		["candidate_and_plan_share_one_two_unit_grant", "candidate_exhaustion_defers_plan", "mixed_call_passes_only_remaining_validation_token", "independent_validator_counter_matches_ledger", "production_validator_calls_never_exceed_two"],
		{ "ledgers": ledgers, "sawCandidateOnly": saw_candidate_only, "sawMixed": saw_mixed_candidate_and_plan }
	)


func test_route_executor_plan_timing_minimal_publication_contract(_mode: String) -> Dictionary:
	var monitor := PlanTimingRecordingMonitor.new()
	var substrate := PlanTimingProfileSubstrate.new()
	substrate.monitor = monitor
	var authority = NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, BudgetedCollisionProbe.new())
	authority.begin_frame()
	var executor = NpcPlanExecutorScript.new()
	executor.route_plan_detailed_timing_enabled = false
	executor.main = { "runtime_perf_monitor": monitor }
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var body := Node3D.new()
	runner.add_child(body)
	body.position = Vector3.ZERO
	var entry := fixture.generated_town_entry()
	entry["id"] = "plan-timing-minimal-publication"
	entry["body"] = body
	executor._plan_and_commit_routine_v2_route(
		entry, body, authority, substrate, fixture, {}, 1.0 / 60.0, 2.0,
		"work", fixture.cell_position(Vector2i(4, 0)), "work_area", true, 90,
		"plan_timing_minimal_publication_contract", "plan-timing-minimal-publication-route-key"
	)
	var expected_gauges := {
		"npc_route_plan_cheap_bookkeeping_residual_ms": 0.64,
		"npc_route_plan_cheap_steps_this_call": 37.0,
		"npc_route_plan_validator_calls_this_call": 1.0
	}
	var exact_gauges := monitor.gauges.size() == expected_gauges.size()
	for gauge_name in expected_gauges.keys():
		exact_gauges = exact_gauges \
			and monitor.gauges.has(gauge_name) \
			and is_equal_approx(float(monitor.gauges.get(gauge_name, -1.0)), float(expected_gauges[gauge_name])) \
			and monitor.events.count("gauge:%s" % gauge_name) == 1
	var plan_end_index := monitor.events.find("end:npc_routine_v2_plan")
	var take_index := monitor.events.find("substrate:take_profile")
	var publication_after_plan_end := plan_end_index >= 0 and take_index > plan_end_index
	for gauge_name in expected_gauges.keys():
		publication_after_plan_end = publication_after_plan_end \
			and monitor.events.find("gauge:%s" % gauge_name) > take_index
	var stored_profile: Dictionary = entry.get("routineRouteV2LastPlanTimingProfile", {}) \
		if entry.get("routineRouteV2LastPlanTimingProfile", {}) is Dictionary else {}
	var passed := exact_gauges \
		and monitor.durations.is_empty() \
		and monitor.counters.is_empty() \
		and publication_after_plan_end \
		and substrate.take_count == 1 \
		and bool(stored_profile.get("outerArithmeticBalanced", false))
	body.queue_free()
	return outcome(
		passed,
		"gauges=%s durations=%s counters=%s events=%s" % [JSON.stringify(monitor.gauges), JSON.stringify(monitor.durations), JSON.stringify(monitor.counters), JSON.stringify(monitor.events)],
		["default_publication_is_exactly_three_compliance_gauges", "default_publication_omits_detailed_duration_and_counter_churn", "minimal_publication_occurs_after_outer_plan_timer_and_profile_drain", "full_entry_local_profile_remains_available"],
		{ "gauges": monitor.gauges, "durations": monitor.durations, "counters": monitor.counters, "events": monitor.events, "storedProfile": stored_profile }
	)


func test_route_executor_plan_timing_publication_contract(_mode: String) -> Dictionary:
	var monitor := PlanTimingRecordingMonitor.new()
	var substrate := PlanTimingProfileSubstrate.new()
	substrate.monitor = monitor
	var authority = NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, BudgetedCollisionProbe.new())
	authority.begin_frame()
	var executor = NpcPlanExecutorScript.new()
	executor.route_plan_detailed_timing_enabled = true
	executor.main = { "runtime_perf_monitor": monitor }
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var body := Node3D.new()
	runner.add_child(body)
	body.position = Vector3.ZERO
	var entry := fixture.generated_town_entry()
	entry["id"] = "plan-timing-publication"
	entry["body"] = body
	executor._plan_and_commit_routine_v2_route(
		entry, body, authority, substrate, fixture, {}, 1.0 / 60.0, 2.0,
		"work", fixture.cell_position(Vector2i(4, 0)), "work_area", true, 90,
		"plan_timing_publication_contract", "plan-timing-publication-route-key"
	)
	var expected_durations := {
		"npc_route_plan_snapshot_capture": 0.1,
		"npc_route_plan_validator_total": 0.15,
		"npc_route_plan_validator_preflight_goal": 0.0,
		"npc_route_plan_validator_preflight_start": 0.0,
		"npc_route_plan_validator_search_transition": 0.15,
		"npc_route_plan_validator_finalize_start": 0.0,
		"npc_route_plan_validator_finalize_transition": 0.0,
		"npc_route_plan_loop_gross": 1.0,
		"npc_route_plan_door_signature": 0.06,
		"npc_route_plan_dynamic_signature": 0.07,
		"npc_route_plan_finalization_assembly": 0.08,
		"npc_route_plan_cheap_bookkeeping_residual": 0.64,
		"npc_route_plan_setup_residual": 0.2,
		"npc_route_plan_outer_residual": 0.7
	}
	var expected_counters := {
		"npc_route_plan_validator_calls": 1,
		"npc_route_plan_validator_preflight_goal_calls": 0,
		"npc_route_plan_validator_preflight_start_calls": 0,
		"npc_route_plan_validator_search_transition_calls": 1,
		"npc_route_plan_validator_finalize_start_calls": 0,
		"npc_route_plan_validator_finalize_transition_calls": 0,
		"npc_route_plan_door_signature_cells": 6,
		"npc_route_plan_door_signature_doors": 1,
		"npc_route_plan_dynamic_signature_cells": 8,
		"npc_route_plan_dynamic_signature_occupied": 2,
		"npc_route_plan_cheap_steps": 37
	}
	var exact_durations := monitor.durations.size() == expected_durations.size()
	for duration_name in expected_durations.keys():
		exact_durations = exact_durations \
			and monitor.durations.has(duration_name) \
			and is_equal_approx(float(monitor.durations.get(duration_name, -1.0)), float(expected_durations[duration_name]))
	var exact_counters := monitor.counters == expected_counters
	var plan_end_index := monitor.events.find("end:npc_routine_v2_plan")
	var take_index := monitor.events.find("substrate:take_profile")
	var all_publication_after_plan_end := plan_end_index >= 0 and take_index > plan_end_index
	var every_duration_published_once := true
	var every_counter_published_once := true
	for duration_name in expected_durations.keys():
		var event_name := "observe:%s" % duration_name
		every_duration_published_once = every_duration_published_once and monitor.events.count(event_name) == 1
		var event_index := monitor.events.find(event_name)
		all_publication_after_plan_end = all_publication_after_plan_end and event_index > plan_end_index and event_index > take_index
	for counter_name in expected_counters.keys():
		var event_name := "counter:%s" % counter_name
		every_counter_published_once = every_counter_published_once and monitor.events.count(event_name) == 1
		all_publication_after_plan_end = all_publication_after_plan_end and monitor.events.find(event_name) > plan_end_index
	var stored_profile: Dictionary = entry.get("routineRouteV2LastPlanTimingProfile", {}) if entry.get("routineRouteV2LastPlanTimingProfile", {}) is Dictionary else {}
	var profile_consumed_once := substrate.take_count == 1 and substrate.timing_profile.is_empty()
	var outer_arithmetic_exact := int(stored_profile.get("outerPlanUsec", -1)) == 2000 \
		and int(stored_profile.get("outerResidualUsec", -1)) == 700 \
		and int(stored_profile.get("outerAccountedUsec", -1)) == 2000 \
		and bool(stored_profile.get("outerArithmeticBalanced", false))
	var production_cheap_cap_applied := int(substrate.last_plan_options.get("cheapStepsPerCall", 0)) == 48
	var passed := exact_durations \
		and exact_counters \
		and monitor.gauges.is_empty() \
		and all_publication_after_plan_end \
		and every_duration_published_once \
		and every_counter_published_once \
		and profile_consumed_once \
		and outer_arithmetic_exact \
		and production_cheap_cap_applied
	body.queue_free()
	return outcome(
		passed,
		"durations=%s counters=%s takeCount=%d outer=%s events=%s" % [JSON.stringify(monitor.durations), JSON.stringify(monitor.counters), substrate.take_count, JSON.stringify(stored_profile), JSON.stringify(monitor.events)],
		["outer_plan_timer_ends_before_profile_drain_and_external_publication", "fixed_duration_names_and_values_publish_once", "fixed_counter_names_and_values_publish_once", "substrate_profile_is_consumed_exactly_once", "outer_residual_arithmetic_is_exact", "production_route_options_apply_forty_eight_cheap_step_cap"],
		{ "durations": monitor.durations, "counters": monitor.counters, "takeCount": substrate.take_count, "storedProfile": stored_profile, "events": monitor.events }
	)


func test_route_candidate_cache_is_request_and_revision_safe(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var authority = NpcRouteAuthorityV2Script.new()
	authority.setup(null, null, BudgetedCollisionProbe.new())
	var entry := fixture.generated_town_entry()
	var first_request: Dictionary = authority.submit_request(entry, { "kind": "work" }, {})
	var first_id := String(first_request.get("requestId", ""))
	var target := {
		"workMinCell": Vector2i(3, -1),
		"workMaxCell": Vector2i(5, 1)
	}
	var options := {
		"allowOutside": true,
		"movingHome": false,
		"candidateValidationsPerCall": 2,
		"requestIdentity": first_id
	}
	var completed: Dictionary = {}
	var completion_calls := 0
	while completion_calls < 16:
		completion_calls += 1
		completed = substrate.candidate_poses_for_target(entry, target, "work_area", options)
		if String(completed.get("classification", "")) != "pending_budget":
			break
	var reused: Dictionary = substrate.candidate_poses_for_target(entry, target, "work_area", options)
	var first_search: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 1,
		"requestIdentity": first_id
	})
	var executor = NpcPlanExecutorScript.new()
	executor.home_route_substrate = substrate
	authority.cancel_request(first_id, "candidate_cache_contract_cancel")
	var removed_for_cancelled_id := executor.evict_route_candidate_cache_for_request(first_id)
	var census_after_cancel: Dictionary = substrate.candidate_cache_census()
	var second_request: Dictionary = authority.submit_request(entry, { "kind": "work" }, {})
	var second_options := options.duplicate(true)
	second_options["requestIdentity"] = String(second_request.get("requestId", ""))
	var after_cancel: Dictionary = substrate.candidate_poses_for_target(entry, target, "work_area", second_options)
	fixture.static_snapshot_revision += 1
	var after_revision: Dictionary = substrate.candidate_poses_for_target(entry, target, "work_area", second_options)
	var second_search: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 1,
		"requestIdentity": String(second_request.get("requestId", ""))
	})
	var removed_for_actor := executor.evict_route_candidate_cache_for_actor(entry)
	var census_after_actor_evict: Dictionary = substrate.candidate_cache_census()
	var after_cancel_progress: Dictionary = after_cancel.get("candidateProgress", {}) if after_cancel.get("candidateProgress", {}) is Dictionary else {}
	var after_revision_progress: Dictionary = after_revision.get("candidateProgress", {}) if after_revision.get("candidateProgress", {}) is Dictionary else {}
	var passed := bool(completed.get("ok", false)) \
		and completion_calls > 1 \
		and bool(reused.get("candidateResultReused", false)) \
		and String(first_search.get("classification", "")) == "pending_budget" \
		and removed_for_cancelled_id == 2 \
		and int(census_after_cancel.get("jobCount", -1)) == 0 \
		and int(census_after_cancel.get("actorCount", -1)) == 0 \
		and int(census_after_cancel.get("searchJobCount", -1)) == 0 \
		and int(census_after_cancel.get("searchActorCount", -1)) == 0 \
		and String(after_cancel.get("classification", "")) == "pending_budget" \
		and int(after_cancel_progress.get("validated", 0)) == 2 \
		and String(after_revision.get("classification", "")) == "pending_budget" \
		and int(after_revision_progress.get("validated", 0)) == 2 \
		and not bool(after_revision.get("candidateResultReused", false)) \
		and String(second_search.get("classification", "")) == "pending_budget" \
		and removed_for_actor == 2 \
		and int(census_after_actor_evict.get("jobCount", -1)) == 0 \
		and int(census_after_actor_evict.get("actorCount", -1)) == 0 \
		and int(census_after_actor_evict.get("searchJobCount", -1)) == 0 \
		and int(census_after_actor_evict.get("searchActorCount", -1)) == 0
	return outcome(
		passed,
		"calls=%d reused=%s afterCancel=%s afterRevision=%s" % [completion_calls, str(reused.get("candidateResultReused", false)), JSON.stringify(substrate_pose_summary(after_cancel)), JSON.stringify(substrate_pose_summary(after_revision))],
		["completed_candidates_reused_only_for_active_request_identity", "cancelled_request_evicts_candidate_and_partial_search", "cancelled_actor_cache_census_returns_to_zero", "source_revision_restarts_candidate_validation", "unregister_style_actor_eviction_clears_candidate_and_search_jobs"],
		{
			"completionCalls": completion_calls,
			"completed": substrate_pose_summary(completed),
			"reused": substrate_pose_summary(reused),
			"firstSearch": substrate_route_summary(first_search),
			"removedForCancelledId": removed_for_cancelled_id,
			"censusAfterCancel": census_after_cancel,
			"afterCancel": after_cancel,
			"afterRevision": after_revision,
			"secondSearch": substrate_route_summary(second_search),
			"removedForActor": removed_for_actor,
			"censusAfterActorEvict": census_after_actor_evict
		}
	)

func test_route_substrate_terminal_revalidation_evicts_search(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "terminal-revalidation-cleanup"
	var request_id := "terminal-revalidation-request"
	var options := {
		"allowOutside": true,
		"maxExpansions": 128,
		"expansionsPerCall": 1,
		"requestIdentity": request_id
	}
	var first: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options)
	var census_during: Dictionary = substrate.candidate_cache_census()
	fixture.standable.erase(Vector2i(5, 0))
	fixture.terrain_revision += 1
	var invalidated: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(5, 0)], options)
	var census_after: Dictionary = substrate.candidate_cache_census()
	var passed := String(first.get("classification", "")) == "pending_budget" \
		and int(census_during.get("searchJobCount", 0)) == 1 \
		and String(invalidated.get("classification", "")) == "pending_budget" \
		and String(invalidated.get("reason", "")) == "route_snapshot_changed" \
		and int(census_after.get("searchJobCount", -1)) == 0 \
		and int(census_after.get("searchActorCount", -1)) == 0
	return outcome(
		passed,
		"first=%s invalidated=%s during=%s after=%s" % [JSON.stringify(substrate_route_summary(first)), JSON.stringify(substrate_route_summary(invalidated)), JSON.stringify(census_during), JSON.stringify(census_after)],
		["mid_slice_source_revision_invalidates_owned_frontier", "revision_invalidation_evicts_owned_frontier", "terminal_actor_search_census_returns_to_zero"],
		{ "first": substrate_route_summary(first), "invalidated": substrate_route_summary(invalidated), "censusDuring": census_during, "censusAfter": census_after }
	)

func test_route_substrate_uses_actual_start_waypoint(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	var start_cell := Vector2i(0, 0)
	var actual_start := fixture.cell_position(start_cell) + Vector3(0.33, 0.0, 0.18)
	var route: Dictionary = substrate.plan_route(entry, start_cell, [Vector2i(4, 0)], {
		"allowOutside": true,
		"startPosition": actual_start,
		"maxExpansions": 64
	})
	var waypoints: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
	var first: Vector3 = waypoints[0] if waypoints.size() > 0 and waypoints[0] is Vector3 else Vector3(INF, INF, INF)
	var second: Vector3 = waypoints[1] if waypoints.size() > 1 and waypoints[1] is Vector3 else Vector3(INF, INF, INF)
	var passed := bool(route.get("ok", false)) \
		and first.distance_to(actual_start) <= 0.001 \
		and second.distance_to(fixture.cell_position(Vector2i(1, 0))) <= 0.001
	return outcome(
		passed,
		"first=%s actual=%s second=%s route=%s" % [str(first), str(actual_start), str(second), JSON.stringify(substrate_route_summary(route))],
		["substrate_route_starts_at_actor_pose", "substrate_second_waypoint_keeps_cell_route"],
		{ "route": substrate_route_summary(route), "first": first, "actualStart": actual_start, "second": second }
	)

func test_route_substrate_home_departure_clearance_exact_goal(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	var porch_cell: Vector2i = entry.get("porchCell", Vector2i(1, 0))
	var clearance_cell := porch_cell + Vector2i(2, 0)
	var poses: Dictionary = substrate.candidate_poses_for_target(entry, {
		"cell": clearance_cell,
		"position": fixture.cell_position(clearance_cell),
		"porchCell": porch_cell
	}, "home_departure_clearance", { "allowOutside": true })
	var candidate_cells: Array = []
	for candidate_value in poses.get("candidates", []):
		if candidate_value is Dictionary:
			candidate_cells.append((candidate_value as Dictionary).get("cell", Vector2i(999999, 999999)))
	var route: Dictionary = substrate.plan_route(entry, porch_cell, candidate_cells, {
		"allowOutside": true,
		"semanticKind": "home_departure_clearance",
		"maxExpansions": 64
	})
	var route_cells: Array = route.get("cells", []) if route.get("cells", []) is Array else []
	var passed: bool = bool(poses.get("ok", false)) \
		and candidate_cells.size() == 1 \
		and candidate_cells[0] == clearance_cell \
		and bool(route.get("ok", false)) \
		and String(route.get("reason", "")) != "already_at_goal" \
		and not route_cells.is_empty() \
		and route_cells[route_cells.size() - 1] == clearance_cell
	return outcome(
		passed,
		"clearance=%s poses=%s route=%s" % [str(clearance_cell), JSON.stringify(substrate_pose_summary(poses)), JSON.stringify(substrate_route_summary(route))],
		["departure_clearance_requires_requested_cell", "porch_is_not_clearance_arrival", "clearance_route_collision_backed"],
		{ "poses": substrate_pose_summary(poses), "route": substrate_route_summary(route), "candidateCells": vec2i_array_summary(candidate_cells) }
	)

func test_route_substrate_forage_search_anchor_exact_outside_goal(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	fixture.add_standable_rect(Vector2i(0, -1), Vector2i(9, 1))
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["job"] = "forage"
	entry["townCenter"] = Vector2i(0, 0)
	entry["townRadius"] = 2
	var target_cell := Vector2i(7, 0)
	var poses: Dictionary = substrate.candidate_poses_for_target(entry, {
		"cell": target_cell,
		"position": fixture.cell_position(target_cell),
		"workMinCell": Vector2i(0, -1),
		"workMaxCell": Vector2i(9, 1)
	}, "forage_search_anchor", { "allowOutside": true })
	var candidate_cells: Array = []
	for candidate_value in poses.get("candidates", []):
		if candidate_value is Dictionary:
			candidate_cells.append((candidate_value as Dictionary).get("cell", Vector2i(999999, 999999)))
	var route: Dictionary = substrate.plan_route(entry, Vector2i(1, 0), candidate_cells, {
		"allowOutside": true,
		"semanticKind": "forage_search_anchor",
		"maxExpansions": 64
	})
	var town_route: Dictionary = substrate.plan_route(entry, Vector2i(1, 0), [Vector2i(1, 0)], {
		"allowOutside": true,
		"semanticKind": "forage_search_anchor",
		"maxExpansions": 64
	})
	var route_cells: Array = route.get("cells", []) if route.get("cells", []) is Array else []
	var rejected_goals: Array = town_route.get("proof", {}).get("rejectedGoals", []) if town_route.get("proof", {}) is Dictionary else []
	var town_reject_reason := ""
	if not rejected_goals.is_empty() and rejected_goals[0] is Dictionary:
		town_reject_reason = String((rejected_goals[0] as Dictionary).get("reason", ""))
	var passed: bool = bool(poses.get("ok", false)) \
		and candidate_cells.size() == 1 \
		and candidate_cells[0] == target_cell \
		and bool(route.get("ok", false)) \
		and not route_cells.is_empty() \
		and route_cells[route_cells.size() - 1] == target_cell \
		and not bool(town_route.get("ok", true)) \
		and town_reject_reason == "forage_search_anchor_inside_town"
	return outcome(
		passed,
		"target=%s poses=%s route=%s townRoute=%s" % [str(target_cell), JSON.stringify(substrate_pose_summary(poses)), JSON.stringify(substrate_route_summary(route)), JSON.stringify(substrate_route_summary(town_route))],
		["forage_search_anchor_requires_exact_target_cell", "forage_search_anchor_rejects_inside_town_goal", "forage_search_route_collision_backed"],
		{ "poses": substrate_pose_summary(poses), "route": substrate_route_summary(route), "townRoute": substrate_route_summary(town_route), "candidateCells": vec2i_array_summary(candidate_cells), "townRejectReason": town_reject_reason }
	)

func test_route_substrate_blocked_generated_town_fixture(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	for z in range(-2, 3):
		fixture.static_collision[Vector2i(2, z)] = {
			"id": "fixture-wall-%d" % z,
			"cell": Vector2i(2, z),
			"blockType": "generated_house_wall",
			"minX": float(2) * CELL - 0.6,
			"maxX": float(2) * CELL + 0.6,
			"minZ": float(z) * CELL - 0.6,
			"maxZ": float(z) * CELL + 0.6
		}
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	var route: Dictionary = substrate.plan_route(entry, Vector2i(0, 0), [Vector2i(4, 0)], {
		"allowOutside": true,
		"maxExpansions": 128
	})
	var proof: Dictionary = route.get("proof", {})
	var blocked_records: Array = proof.get("blocked", [])
	var saw_collision := false
	for record in blocked_records:
		if record is Dictionary and String((record as Dictionary).get("reason", "")) == "blocked_static_collision":
			saw_collision = true
			break
	var passed := not bool(route.get("ok", true)) \
		and String(route.get("classification", "")) == "unreachable_static" \
		and saw_collision \
		and (route.get("cells", []) as Array).is_empty()
	return outcome(
		passed,
		"route=%s" % JSON.stringify(substrate_route_summary(route)),
		["static_collision_blocks_route", "no_partial_endpoint_success", "terminal_unreachable_static"],
		{ "route": substrate_route_summary(route), "blockedSample": blocked_records.slice(0, mini(4, blocked_records.size())) }
	)

func test_route_substrate_invalid_goal_generated_town_fixture(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	var route: Dictionary = substrate.plan_route(entry, Vector2i(0, 0), [Vector2i(99, 99)], {
		"allowOutside": true,
		"maxExpansions": 64
	})
	var proof: Dictionary = route.get("proof", {})
	var passed := not bool(route.get("ok", true)) \
		and String(route.get("classification", "")) == "invalid_goal" \
		and String(route.get("reason", "")) == "no_valid_goal_cell" \
		and (proof.get("rejectedGoals", []) as Array).size() == 1
	return outcome(
		passed,
		"route=%s" % JSON.stringify(substrate_route_summary(route)),
		["invalid_goal_not_routed", "goal_must_be_standable", "no_partial_endpoint_success"],
		{ "route": substrate_route_summary(route), "rejectedGoals": proof.get("rejectedGoals", []) }
	)

func test_route_substrate_pending_generated_town_fixture(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	fixture.pending_nav_data = true
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	var pending_nav: Dictionary = substrate.plan_route(entry, Vector2i(0, 0), [Vector2i(4, 0)], {
		"allowOutside": true,
		"maxExpansions": 64
	})
	fixture.pending_nav_data = false
	var pending_budget: Dictionary = substrate.plan_route(entry, Vector2i(0, 0), [Vector2i(4, 0)], {
		"allowOutside": true,
		"maxExpansions": 1
	})
	var passed := not bool(pending_nav.get("ok", true)) \
		and String(pending_nav.get("classification", "")) == "pending_nav_data" \
		and not bool(pending_budget.get("ok", true)) \
		and String(pending_budget.get("classification", "")) == "pending_budget"
	return outcome(
		passed,
		"pendingNav=%s pendingBudget=%s" % [JSON.stringify(substrate_route_summary(pending_nav)), JSON.stringify(substrate_route_summary(pending_budget))],
		["pending_nav_data_not_unreachable", "pending_budget_not_unreachable", "target_not_poisoned_by_missing_budget"],
		{ "pendingNav": substrate_route_summary(pending_nav), "pendingBudget": substrate_route_summary(pending_budget) }
	)

func test_route_substrate_unrelated_door_state_preserves_incremental_search(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	fixture.standable.clear()
	fixture.add_standable_rect(Vector2i(0, 0), Vector2i(260, 0))
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	var options := {
		"allowOutside": true,
		"maxExpansions": 512,
		"expansionsPerCall": 64
	}
	var results: Array[Dictionary] = []
	for call_index in range(16):
		var result: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(260, 0)], options)
		results.append(result)
		if bool(result.get("ok", false)):
			break
		fixture.door_state_revision += 1
	var first_expansions := int((results[0].get("proof", {}) as Dictionary).get("expansions", 0)) if not results.is_empty() else 0
	var second_expansions := int((results[1].get("proof", {}) as Dictionary).get("expansions", 0)) if results.size() > 1 else 0
	var final_result: Dictionary = results.back() if not results.is_empty() else {}
	var route_cells: Array = final_result.get("cells", []) if final_result.get("cells", []) is Array else []
	var passed: bool = first_expansions == 64 \
		and second_expansions > first_expansions \
		and bool(final_result.get("ok", false)) \
		and not route_cells.is_empty() \
		and route_cells.back() == Vector2i(260, 0)
	return outcome(
		passed,
		"calls=%d first=%d second=%d final=%s" % [results.size(), first_expansions, second_expansions, JSON.stringify(substrate_route_summary(final_result))],
		["incremental_search_survives_unrelated_door_state", "search_work_accumulates_across_frames", "collision_backed_route_eventually_commits"],
		{
			"callCount": results.size(),
			"firstExpansions": first_expansions,
			"secondExpansions": second_expansions,
			"final": substrate_route_summary(final_result)
		}
	)

func test_route_substrate_source_revision_restarts_incremental_search(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	fixture.standable.clear()
	fixture.add_standable_rect(Vector2i(0, 0), Vector2i(260, 0))
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	var options := {
		"allowOutside": true,
		"maxExpansions": 512,
		"expansionsPerCall": 64
	}
	var first: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(260, 0)], options)
	fixture.static_snapshot_revision += 1
	fixture.semantic_revision += 1
	var invalidated: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(260, 0)], options)
	var census_after_invalidation: Dictionary = substrate.candidate_cache_census()
	var final_result: Dictionary = invalidated
	var restart_calls := 0
	for _call_index in range(16):
		restart_calls += 1
		final_result = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(260, 0)], options)
		if bool(final_result.get("ok", false)):
			break
	var first_expansions := int((first.get("proof", {}) as Dictionary).get("expansions", 0))
	var invalidated_proof: Dictionary = invalidated.get("proof", {}) if invalidated.get("proof", {}) is Dictionary else {}
	var passed: bool = first_expansions == 64 \
		and String(invalidated.get("reason", "")) == "route_snapshot_changed" \
		and bool(invalidated_proof.get("searchSnapshotChanged", false)) \
		and int(census_after_invalidation.get("searchJobCount", -1)) == 0 \
		and int(census_after_invalidation.get("searchActorCount", -1)) == 0 \
		and bool(final_result.get("ok", false))
	return outcome(
		passed,
		"restartCalls=%d first=%d invalidated=%s census=%s final=%s" % [restart_calls, first_expansions, JSON.stringify(substrate_route_summary(invalidated)), JSON.stringify(census_after_invalidation), JSON.stringify(substrate_route_summary(final_result))],
		["source_revision_discards_stale_incremental_search", "revision_invalidation_cleans_owned_frontier", "fresh_search_eventually_commits"],
		{
			"restartCalls": restart_calls,
			"firstExpansions": first_expansions,
			"invalidated": substrate_route_summary(invalidated),
			"censusAfterInvalidation": census_after_invalidation,
			"final": substrate_route_summary(final_result)
		}
	)

func test_route_substrate_changed_collision_revalidates_before_commit(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	fixture.standable.clear()
	fixture.add_standable_rect(Vector2i(0, 0), Vector2i(260, 0))
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	var options := {
		"allowOutside": true,
		"maxExpansions": 512,
		"expansionsPerCall": 64
	}
	var first: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(260, 0)], options)
	fixture.static_collision[Vector2i(32, 0)] = {
		"id": "late-wall",
		"cell": Vector2i(32, 0),
		"blockType": "generated_wall"
	}
	fixture.static_snapshot_revision += 1
	var saw_revalidation_restart := false
	var final: Dictionary = first
	for _call_index in range(10):
		final = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(260, 0)], options)
		if String(final.get("reason", "")) == "route_snapshot_changed":
			saw_revalidation_restart = true
		if String(final.get("classification", "")) in ["unreachable_static", "invalid_goal"]:
			break
	var passed: bool = not bool(final.get("ok", true)) \
		and saw_revalidation_restart \
		and String(final.get("classification", "")) == "unreachable_static"
	return outcome(
		passed,
		"first=%s restart=%s final=%s" % [JSON.stringify(substrate_route_summary(first)), str(saw_revalidation_restart), JSON.stringify(substrate_route_summary(final))],
		["changed_collision_revalidates_completed_route", "stale_route_never_commits", "fresh_search_reports_terminal_block"],
		{
			"first": substrate_route_summary(first),
			"sawRevalidationRestart": saw_revalidation_restart,
			"final": substrate_route_summary(final)
		}
	)


func test_route_substrate_terrain_edit_revalidates_before_commit(_mode: String) -> Dictionary:
	var fixture := GeneratedTownRouteSubstrateFixtureWorld.new()
	fixture.standable.clear()
	fixture.add_standable_rect(Vector2i(0, 0), Vector2i(260, 0))
	var substrate = CollisionBackedRouteSubstrateScript.new()
	substrate.setup(fixture)
	var entry := fixture.generated_town_entry()
	entry["id"] = "terrain-edit-mid-slice"
	var options := {
		"allowOutside": true,
		"maxExpansions": 512,
		"expansionsPerCall": 64
	}
	var first: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(260, 0)], options)
	fixture.standable.erase(Vector2i(32, 0))
	fixture.terrain_revision += 1
	var saw_revalidation_restart := false
	var saw_terrain_revision_change := false
	var final: Dictionary = first
	for _call_index in range(10):
		final = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(260, 0)], options)
		var proof: Dictionary = final.get("proof", {}) if final.get("proof", {}) is Dictionary else {}
		saw_terrain_revision_change = saw_terrain_revision_change or bool(proof.get("searchSnapshotChanged", false))
		if String(final.get("reason", "")) == "route_snapshot_changed":
			saw_revalidation_restart = true
		if String(final.get("classification", "")) in ["unreachable_static", "invalid_goal"]:
			break
	var passed: bool = not bool(final.get("ok", true)) \
		and saw_terrain_revision_change \
		and saw_revalidation_restart \
		and String(final.get("classification", "")) == "unreachable_static"
	return outcome(
		passed,
		"first=%s revisionChanged=%s restart=%s final=%s" % [JSON.stringify(substrate_route_summary(first)), str(saw_terrain_revision_change), str(saw_revalidation_restart), JSON.stringify(substrate_route_summary(final))],
		["terrain_revision_changes_incremental_search_identity", "edited_surface_revalidates_completed_route", "stale_pre_edit_route_never_commits"],
		{ "first": substrate_route_summary(first), "sawTerrainRevisionChange": saw_terrain_revision_change, "sawRevalidationRestart": saw_revalidation_restart, "final": substrate_route_summary(final) }
	)

func collision_adapter_with_blocks(block_nodes: Array) -> Dictionary:
	var main := RouteTestMain.new()
	runner.add_child(main)
	for node_value in block_nodes:
		var body := node_value as Node
		if body == null:
			continue
		main.add_child(body)
		var cell_value = body.get_meta("cell", Vector3i.ZERO)
		main.blocks[cell_value] = body
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	adapter.setup(null, main)
	adapter.rebuild_static_cells()
	var body := Node3D.new()
	main.add_child(body)
	body.global_position = Vector3.ZERO
	var entry := {
		"id": "collision-route-test",
		"body": body,
		"townCenter": Vector2i.ZERO,
		"townRadius": 128,
		"porchPosition": Vector3.ZERO
	}
	var snapshot: Dictionary = adapter.cached_validation_snapshot(entry, false, false)
	return {
		"main": main,
		"adapter": adapter,
		"entry": entry,
		"snapshot": snapshot,
		"body": body,
		"blocks": block_nodes
	}

func free_collision_setup(setup: Dictionary) -> void:
	var body := setup.get("body") as Node
	if body != null and is_instance_valid(body):
		body.free()
	for block_value in setup.get("blocks", []):
		var block := block_value as Node
		if block != null and is_instance_valid(block):
			block.free()
	var main := setup.get("main") as Node
	if main != null and is_instance_valid(main):
		main.free()

func collision_block(cell: Vector2i, block_type := "woodBlock", position_value = null, size_value = null, yaw := 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "TestBlock_%s_%d_%d" % [block_type, cell.x, cell.y]
	var block_position: Vector3 = position_value if position_value is Vector3 else Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)
	body.position = block_position
	body.rotation.y = yaw
	body.set_meta("kind", "block")
	body.set_meta("cell", Vector3i(cell.x, 0, cell.y))
	body.set_meta("block_type", block_type)
	var shape := BoxShape3D.new()
	shape.size = size_value if size_value is Vector3 else Vector3(CELL * 0.96, CELL * 1.0, CELL * 0.96)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)
	return body

func collision_door(cell: Vector2i, side := 0, policy := "public_gate") -> StaticBody3D:
	var door := collision_block(cell, "door", Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL), Vector3(CELL * 0.92, CELL * 1.72, CELL * 0.16), 0.0)
	door.set_meta("door_side", side)
	door.set_meta("door_policy", policy)
	door.set_meta("door_portal_id", "door:test:%d,%d" % [cell.x, cell.y])
	door.set_meta("door_group_id", "door-test:%d,%d" % [cell.x, cell.y])
	door.set_meta("door_state", String(NpcEnumsScript.DOOR_STATE_CLOSED))
	door.set_meta("open", false)
	door.set_meta("locked", false)
	door.set_meta("jammed", false)
	door.set_meta("destroyed", false)
	door.set_meta("unloaded", false)
	return door

func navmesh_test_service(label: String, min_pos: Vector3, size: Vector3):
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	var center := min_pos + size * 0.5
	var descriptor = NavigationBakeDescriptorScript.create("region:chunk:%s" % label, label, AABB(min_pos, size))
	descriptor.add_walkable_surface("surface:%s:main" % label, center, Vector3(maxf(size.x, NpcConstantsScript.CELL_SIZE), 0.05, maxf(size.z, NpcConstantsScript.CELL_SIZE)), {
		"semanticRegionIds": ["test_navmesh"],
		"traversalTags": ["terrain"]
	})
	service.register_chunk_descriptor(descriptor)
	return service

func navmesh_door_descriptor(region_id: String, tile_key: String, portal_id: String):
	var descriptor = NavigationBakeDescriptorScript.create(region_id, tile_key, AABB(Vector3(-1.5, -0.1, -1.5), Vector3(3.0, 1.2, 5.7)))
	descriptor.add_walkable_surface("surface:%s:left" % tile_key, Vector3(0.0, 0.0, 0.0), Vector3(NpcConstantsScript.CELL_SIZE, 0.05, NpcConstantsScript.CELL_SIZE))
	descriptor.add_walkable_surface("surface:%s:right" % tile_key, Vector3(0.0, 0.0, 2.7), Vector3(NpcConstantsScript.CELL_SIZE, 0.05, NpcConstantsScript.CELL_SIZE))
	descriptor.add_door_portal(portal_id, Vector3(0.0, 0.0, 0.65), Vector3(0.0, 0.0, 2.05), { "state": "closed", "openable": true })
	descriptor.add_door_link("surface:%s:left" % tile_key, "surface:%s:right" % tile_key, portal_id, { "cost": 1.0, "actionId": "open" })
	return descriptor

func vec2i_array_summary(cells: Array) -> Array:
	var result := []
	for cell_value in cells:
		if cell_value is Vector2i:
			var cell: Vector2i = cell_value
			result.append([cell.x, cell.y])
	return result

func navmesh_route_summary(route: Dictionary) -> Dictionary:
	return {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"source": String(route.get("source", "")),
		"queryApi": String(route.get("queryApi", "")),
		"pointCount": int(route.get("pointCount", 0)),
		"distance": snappedf(float(route.get("distance", 0.0)), 0.001),
		"snapshotRevision": String(route.get("snapshotRevision", ""))
	}

func substrate_route_summary(route: Dictionary) -> Dictionary:
	var proof: Dictionary = route.get("proof", {})
	return {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"classification": String(route.get("classification", "")),
		"reason": String(route.get("reason", "")),
		"source": String(route.get("source", "")),
		"cellCount": (route.get("cells", []) as Array).size(),
		"visitedCount": (route.get("visited", []) as Array).size(),
		"collisionBacked": bool(proof.get("collisionBacked", false)),
		"generatedWorldInformed": bool(proof.get("generatedWorldInformed", false)),
		"doorEdgeCount": (proof.get("doorEdges", []) as Array).size(),
		"blockedCount": (proof.get("blocked", []) as Array).size(),
		"expansions": int(proof.get("expansions", 0))
	}

func substrate_pose_summary(poses: Dictionary) -> Dictionary:
	return {
		"ok": bool(poses.get("ok", false)),
		"classification": String(poses.get("classification", "")),
		"reason": String(poses.get("reason", "")),
		"candidateCount": (poses.get("candidates", []) as Array).size(),
		"rejectedCount": (poses.get("rejected", []) as Array).size(),
		"collisionBacked": bool(poses.get("collisionBacked", false)),
		"generatedWorldInformed": bool(poses.get("generatedWorldInformed", false))
	}

func authority_test_route(point_count: int) -> Dictionary:
	var waypoints: Array = []
	var cells: Array = []
	for index in range(maxi(1, point_count)):
		waypoints.append(Vector3(float(index + 1) * CELL, 0.0, 0.0))
		cells.append(Vector2i(index + 1, 0))
	return {
		"ok": true,
		"status": "reachable",
		"classification": "reachable",
		"reason": "test_route",
		"source": "test_authority_route",
		"waypoints": waypoints,
		"cells": cells,
		"actions": {},
		"targetCell": cells[cells.size() - 1],
		"snapshotRevision": "test"
	}

func authority_summary(summary: Dictionary) -> Dictionary:
	return {
		"ok": bool(summary.get("ok", false)),
		"granted": bool(summary.get("granted", false)),
		"state": String(summary.get("state", "")),
		"reason": String(summary.get("reason", "")),
		"requestId": String(summary.get("requestId", "")),
		"planningWaitFrames": int(summary.get("planningWaitFrames", 0)),
		"pendingProbeFrames": int(summary.get("pendingProbeFrames", 0)),
		"hasLease": bool(summary.get("hasLease", false)),
		"starvationOverride": bool(summary.get("starvationOverride", false))
	}

func navmesh_route_dictionary_summary(route: Dictionary) -> Dictionary:
	var navmesh_route: Dictionary = route.get("navmeshRoute", {})
	var start_walkable := navmesh_walkable_summary(navmesh_route, "startWalkable")
	var target_walkable := navmesh_walkable_summary(navmesh_route, "targetWalkable")
	return {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"source": String(route.get("source", "")),
		"legacyFallbackUsed": bool(route.get("legacyFallbackUsed", true)),
		"waypointCount": (route.get("waypoints", []) as Array).size(),
		"cellCount": (route.get("cells", []) as Array).size(),
		"snapshotRevision": String(route.get("snapshotRevision", "")),
		"navmeshReason": String(navmesh_route.get("reason", "")),
		"navmeshQueryApi": String(navmesh_route.get("queryApi", "")),
		"navmeshPointCount": int(navmesh_route.get("pointCount", 0)),
		"startWalkable": start_walkable,
		"targetWalkable": target_walkable
	}

func navmesh_walkable_summary(route: Dictionary, key: String) -> Dictionary:
	var value = route.get(key, {})
	if not (value is Dictionary) or (value is Dictionary and (value as Dictionary).is_empty()):
		var details: Dictionary = route.get("details", {})
		value = details.get(key, {})
	if not (value is Dictionary):
		return { "found": false }
	var walkable: Dictionary = value
	return {
		"found": bool(walkable.get("found", false)),
		"regionId": String(walkable.get("regionId", "")),
		"surfaceId": String(walkable.get("surfaceId", "")),
		"distance": snappedf(float(walkable.get("distance", 0.0)), 0.001)
	}

func route_line_service(start_x: int, end_x: int) -> Dictionary:
	var tiles = {}
	for x in range(start_x, end_x + 1):
		var cell = Vector3i(x, 0, 0)
		var tile_key = NavigationChangeBusScript.tile_key_for_cell(cell)
		if not tiles.has(tile_key):
			tiles[tile_key] = []
		(tiles[tile_key] as Array).append(nav_surface(cell, { "semanticRegionIds": ["road"] }))
	return { "service": route_service_from_surfaces(tiles), "tiles": tiles }

func route_service_from_surfaces(tiles: Dictionary, extras := {}) -> Object:
	var service = NavigationWorldServiceScript.new()
	var keys = tiles.keys()
	keys.sort()
	for tile_key in keys:
		var extra: Dictionary = extras.get(tile_key, {})
		service.build_tile_now(nav_snapshot(str(tile_key), tiles[tile_key], extra))
	return service

func route_plan(service, start_key: String, goal_spec: Dictionary, allow_partial := false, goal_kind := "move", max_expansions := 4096):
	var planner = HierarchicalRoutePlannerScript.new()
	planner.setup(service)
	var request = route_request(start_key, goal_spec, allow_partial, goal_kind)
	return planner.plan_route(request, max_expansions)

func route_request(start_key: String, goal_spec: Dictionary, allow_partial := false, goal_kind := "move"):
	var request = RouteRequestScript.new()
	request.request_id = "test:%s:%s" % [start_key, JSON.stringify(goal_spec)]
	request.owner_npc_id = "test-npc"
	request.start_span = start_key
	request.start_position = Vector3.ZERO
	request.goal_kind = StringName(goal_kind)
	request.goal_spec = goal_spec
	request.allow_partial = allow_partial
	request.maximum_acceptable_goal_distance = NpcConstantsScript.CELL_SIZE * 0.75
	request.next_generation()
	return request

func route_span_key(cell: Vector3i, tile_key := "", span_index := 0) -> String:
	var key = tile_key
	if key == "":
		key = NavigationChangeBusScript.tile_key_for_cell(cell)
	return "%s:%d,%d,%d:%d" % [key, cell.x, cell.y, cell.z, span_index]

func route_summary(result) -> Dictionary:
	if result == null:
		return {}
	var summary: Dictionary = result.to_summary()
	if result.get("corridor") != null:
		summary["corridor"] = _compact_corridor_summary(result.get("corridor").to_summary())
	summary["metrics"] = result.get("metrics")
	return summary

func route_metrics(result) -> Dictionary:
	if result == null:
		return {}
	var metrics = result.get("metrics")
	return metrics if metrics is Dictionary else {}

func _compact_corridor_summary(corridor_summary: Dictionary) -> Dictionary:
	var result = corridor_summary.duplicate(true)
	var steps: Array = result.get("steps", [])
	if steps.size() <= 12:
		return result
	var sample: Array = []
	for i in range(3):
		sample.append(steps[i])
	for i in range(steps.size() - 3, steps.size()):
		sample.append(steps[i])
	result["sampledSteps"] = sample
	result["omittedStepCount"] = steps.size() - sample.size()
	result.erase("steps")
	return result

func corridor_semantics(result) -> Array:
	var values: Array = []
	var corridor = result.get("corridor") if result != null else null
	if corridor == null:
		return values
	for step in corridor.steps:
		for semantic_id in step.get("semantic_region_ids"):
			if not values.has(str(semantic_id)):
				values.append(str(semantic_id))
	values.sort()
	return values

func nav_snapshot(tile_key: String, surfaces: Array, extra := {}) -> Dictionary:
	var snapshot = {
		"tileKey": tile_key,
		"surfaces": surfaces
	}
	for key in extra.keys():
		snapshot[key] = extra[key]
	return snapshot

func nav_surface(cell: Vector3i, extra := {}) -> Dictionary:
	var surface = {
		"cell": cell,
		"spanIndex": int(extra.get("spanIndex", 0)),
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

func read_text(path: String) -> String:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text = file.get_as_text()
	file.close()
	return text

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	if runner != null and runner.has_method("outcome"):
		return runner.call("outcome", passed, details, assertions, key_state)
	return {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}

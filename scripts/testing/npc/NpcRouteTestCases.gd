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
const CELL := NpcConstantsScript.CELL_SIZE

var runner = null

class RouteTestMain:
	extends Node
	var WATER_LEVEL := -1000.0
	var blocks := {}
	var chunk_root := Node.new()
	var prop_root := Node.new()

	func _init() -> void:
		add_child(chunk_root)
		add_child(prop_root)

	func surface_y_at_cell(_cell) -> float:
		return 0.0

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

class RecordingRepairSubstrate:
	extends RefCounted
	var avoid_history: Array = []

	func repair_route_after_probe(_entry: Dictionary, _start_cell: Vector2i, _candidate_cells: Array, failed_route: Dictionary, _certificate: Dictionary, options := {}) -> Dictionary:
		avoid_history.append((options.get("avoidCells", []) as Array).duplicate())
		var repaired := failed_route.duplicate(true)
		repaired["ok"] = true
		repaired["status"] = "reachable"
		repaired["reason"] = "test_repair"
		return repaired

class GeneratedFallbackWorld:
	extends RefCounted

	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / 1.35), roundi(position.z / 1.35))

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
		["npc_route_authority_planning_grants_ignore_actor_update_order", "test_route_authority_planning_grants_ignore_actor_update_order"],
		["npc_route_authority_probe_budget_starvation_recovery", "test_route_authority_probe_budget_starvation_recovery"],
		["npc_route_authority_probe_repair_avoids_persist_across_budget", "test_route_authority_probe_repair_avoids_persist_across_budget"],
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
		["npc_route_probe_repair_cell_bridge_uses_fallback_goal", "test_route_probe_repair_cell_bridge_uses_fallback_goal"],
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
		["npc_route_substrate_uses_actual_start_waypoint", "test_route_substrate_uses_actual_start_waypoint"],
		["npc_route_substrate_home_departure_clearance_exact_goal", "test_route_substrate_home_departure_clearance_exact_goal"],
		["npc_route_substrate_forage_search_anchor_exact_outside_goal", "test_route_substrate_forage_search_anchor_exact_outside_goal"],
		["npc_route_substrate_blocked_generated_town_fixture", "test_route_substrate_blocked_generated_town_fixture"],
		["npc_route_substrate_invalid_goal_generated_town_fixture", "test_route_substrate_invalid_goal_generated_town_fixture"],
		["npc_route_substrate_pending_generated_town_fixture", "test_route_substrate_pending_generated_town_fixture"],
		["npc_route_substrate_unrelated_door_state_preserves_incremental_search", "test_route_substrate_unrelated_door_state_preserves_incremental_search"],
		["npc_route_substrate_unrelated_topology_revision_preserves_incremental_search", "test_route_substrate_unrelated_topology_revision_preserves_incremental_search"],
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
		and serviced.size() == requests.size()
	return outcome(
		passed,
		"first=%s second=%s high=%s serviced=%d" % [JSON.stringify(first_frame_grants), JSON.stringify(second_frame_grants), high_request_id, serviced.size()],
		["planning_priority_independent_of_update_order", "planning_budget_remains_bounded", "equal_priority_requests_rotate_fairly"],
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
	authority.begin_frame()
	var continued_route: Dictionary = first.get("route", {}) if first.get("route", {}) is Dictionary else route
	var final: Dictionary = authority.commit_route_after_probe(entry, request_id, continued_route, intent, options)
	var second_avoids: Array = substrate.avoid_history[1] if substrate.avoid_history.size() > 1 and substrate.avoid_history[1] is Array else []
	var passed := String(first.get("state", "")) == "probing" \
		and String(final.get("state", "")) == "ready" \
		and second_avoids.has(Vector2i(2, 0)) \
		and second_avoids.has(Vector2i(3, 0))
	return outcome(
		passed,
		"first=%s final=%s avoids=%s" % [JSON.stringify(authority_summary(first)), JSON.stringify(authority_summary(final)), JSON.stringify(substrate.avoid_history)],
		["probe_repair_avoids_survive_budget_boundary", "probe_repair_does_not_rediscover_prior_blocker"],
		{ "first": authority_summary(first), "final": authority_summary(final), "avoidHistory": substrate.avoid_history }
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
	var current_sample := Vector3(CELL * 0.34, 0.0, 0.0)
	body.position = current_sample
	body.global_position = current_sample
	var block := collision_block(Vector2i.ZERO, "stoneBlock")
	block.position = Vector3.ZERO
	block.global_position = Vector3.ZERO
	var door := collision_door(Vector2i.ZERO)
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
	var adapter = setup.get("adapter")
	var validation_snapshot: Dictionary = setup.get("snapshot", {})
	var navmesh_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("0,0")
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
	var passed := not collision_blocker.is_empty() and not blocked_cell_surface and open_cell_surface
	free_collision_setup(setup)
	return outcome(
		passed,
		"collision=%s blockedSurface=%s openSurface=%s surfaceCount=%d" % [JSON.stringify(collision_blocker), str(blocked_cell_surface), str(open_cell_surface), surfaces.size()],
		["navmesh_surface_uses_collision_records", "collision_occupied_cell_not_published_as_walkable"],
		{ "collision": collision_blocker, "blockedCellSurface": blocked_cell_surface, "openCellSurface": open_cell_surface, "surfaceCount": surfaces.size() }
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
	for call_index in range(6):
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

func test_route_substrate_unrelated_topology_revision_preserves_incremental_search(_mode: String) -> Dictionary:
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
	for call_index in range(6):
		var result: Dictionary = substrate.plan_route(entry, Vector2i.ZERO, [Vector2i(260, 0)], options)
		results.append(result)
		if bool(result.get("ok", false)):
			break
		fixture.static_snapshot_revision += 1
		fixture.semantic_revision += 1
	var first_expansions := int((results[0].get("proof", {}) as Dictionary).get("expansions", 0)) if not results.is_empty() else 0
	var second_expansions := int((results[1].get("proof", {}) as Dictionary).get("expansions", 0)) if results.size() > 1 else 0
	var final_result: Dictionary = results.back() if not results.is_empty() else {}
	var passed: bool = first_expansions == 64 \
		and second_expansions > first_expansions \
		and bool(final_result.get("ok", false))
	return outcome(
		passed,
		"calls=%d first=%d second=%d final=%s" % [results.size(), first_expansions, second_expansions, JSON.stringify(substrate_route_summary(final_result))],
		["unrelated_topology_revision_does_not_discard_search", "search_uses_fresh_collision_snapshot_each_call", "route_eventually_commits"],
		{
			"callCount": results.size(),
			"firstExpansions": first_expansions,
			"secondExpansions": second_expansions,
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

func collision_adapter_with_blocks(block_nodes: Array) -> Dictionary:
	var main := RouteTestMain.new()
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

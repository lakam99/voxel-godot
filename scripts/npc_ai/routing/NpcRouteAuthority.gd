extends RefCounted
class_name NpcRouteAuthority

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const RouteLeaseScript := preload("res://scripts/npc_ai/contracts/RouteLease.gd")
const CollisionProbeServiceScript := preload("res://scripts/npc_ai/routing/CollisionProbeService.gd")
const NpcRouteStateStoreScript := preload("res://scripts/npc_ai/routing/NpcRouteStateStore.gd")

const DEFAULT_PROBE_SAMPLE_BUDGET_PER_FRAME := 160

var system = null
var main = null
var world = null
var delegate = null
var repair_service = null
var collision_probe = null
var collision_probe_required := true
var probe_sample_budget_per_frame := DEFAULT_PROBE_SAMPLE_BUDGET_PER_FRAME
var probe_samples_used_this_frame := 0
var route_generations := {}
var probe_cursors := {}
var counters := {
	"requests": 0,
	"ready": 0,
	"pendingNavData": 0,
	"pendingBudget": 0,
	"pendingProbe": 0,
	"blockedDynamic": 0,
	"unreachableStatic": 0,
	"invalidGoal": 0,
	"cancelled": 0,
	"invalidated": 0,
	"failedInternal": 0,
	"probePassed": 0,
	"probeFailed": 0,
	"probeSkipped": 0,
	"probeBudgetDeferrals": 0
}

func setup(system_node, main_node, navigation_world, route_delegate) -> void:
	system = system_node
	main = main_node
	world = navigation_world
	delegate = route_delegate
	repair_service = delegate.get("repair_service") if delegate != null else null
	collision_probe = CollisionProbeServiceScript.new()
	collision_probe.setup(system, main)

func begin_frame(allow_publication := true) -> void:
	probe_samples_used_this_frame = 0
	if delegate != null and delegate.has_method("begin_frame"):
		delegate.begin_frame(allow_publication)

func invalidate() -> void:
	route_generations.clear()
	probe_cursors.clear()
	if delegate != null and delegate.has_method("invalidate"):
		delegate.invalidate()

func process_navigation_events(events: Array, max_expansions := 128) -> Array[Dictionary]:
	if delegate != null and delegate.has_method("process_navigation_events"):
		return delegate.process_navigation_events(events, max_expansions)
	return []

func route_cost(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := 1.1475, approach_cells: Array = [], require_ready := false) -> float:
	if delegate != null and delegate.has_method("route_cost"):
		return delegate.route_cost(entry, target, allow_outside, moving_home, arrival_radius, approach_cells, require_ready)
	return INF

func prebake_area_tiles(center_cell: Vector2i, radius_cells: int) -> Dictionary:
	if delegate != null and delegate.has_method("prebake_area_tiles"):
		return delegate.prebake_area_tiles(center_cell, radius_cells)
	return { "ok": false, "reason": "missing_prebake_delegate" }

func plan_route(entry: Dictionary, intent: Dictionary) -> Dictionary:
	counters["requests"] = int(counters.get("requests", 0)) + 1
	if delegate == null or not delegate.has_method("plan_route"):
		var missing := _route_failure("blocked", "missing_route_delegate", intent.get("targetCell", Vector2i(999999, 999999)))
		return _annotate_authority(entry, intent, missing)
	var route: Dictionary = delegate.plan_route(entry, intent)
	return _annotate_authority(entry, intent, route)

func stats() -> Dictionary:
	var result := {
		"authority": counters.duplicate(true),
		"actorGenerations": route_generations.size(),
		"probeCursors": probe_cursors.size(),
		"probeSampleBudgetPerFrame": probe_sample_budget_per_frame,
		"probeSamplesUsedThisFrame": probe_samples_used_this_frame
	}
	if delegate != null and delegate.has_method("stats"):
		var delegate_stats = delegate.stats()
		result["delegate"] = delegate_stats if delegate_stats is Dictionary else {}
	return result

func _annotate_authority(entry: Dictionary, intent: Dictionary, route: Dictionary) -> Dictionary:
	var actor_id := String(entry.get("id", "npc"))
	var state: StringName = canonical_state_for_route(route, intent)
	var reason := StringName(String(route.get("reason", "")))
	if reason == &"":
		reason = NpcEnumsScript.ROUTE_REASON_NONE
	var probe_certificate := {}
	if state == NpcEnumsScript.ROUTE_AUTHORITY_READY:
		probe_certificate = _probe_ready_route(entry, route, intent)
		route["probeCertificate"] = probe_certificate.duplicate(true)
		route["collisionProbe"] = probe_certificate.duplicate(true)
		entry["lastRouteCollisionProbe"] = probe_certificate.duplicate(true)
		if collision_probe_required and (not bool(probe_certificate.get("ok", false)) or not bool(probe_certificate.get("authoritative", false))):
			var repair_route := _probe_repair_route(entry, route, intent, probe_certificate)
			if not repair_route.is_empty():
				return _annotate_authority(entry, _probe_repair_intent(intent), repair_route)
			state = _state_for_probe_failure(probe_certificate)
			reason = StringName(String(probe_certificate.get("reason", "collision_probe_failed")))
			_reject_unprobed_route(route, state, reason)
	route["routeAuthorityState"] = String(state)
	route["routeAuthorityReason"] = String(reason)
	route["routeAuthorityReady"] = state == NpcEnumsScript.ROUTE_AUTHORITY_READY
	route["routeAuthorityPending"] = NpcEnumsScript.route_authority_state_is_pending(state)
	route["routeAuthorityTerminalFailure"] = NpcEnumsScript.route_authority_state_is_terminal_failure(state)
	route["routeAuthoritySource"] = "NpcRouteAuthority"
	_increment_state_counter(state)
	if state == NpcEnumsScript.ROUTE_AUTHORITY_READY:
		var generation := _next_generation(actor_id)
		var lease = RouteLeaseScript.from_route(route, actor_id, generation, state, reason)
		route["routeLease"] = lease.to_dictionary()
		route["routeLeaseId"] = lease.lease_id
		route["routeLeaseGeneration"] = generation
		NpcRouteStateStoreScript.write_route_lease(entry, lease.to_dictionary(), lease.lease_id, generation, "NpcRouteAuthority.ready")
	else:
		route["routeLease"] = {}
		route["routeLeaseId"] = ""
		route["routeLeaseGeneration"] = int(route_generations.get(actor_id, 0))
		NpcRouteStateStoreScript.clear_route_lease(entry, "NpcRouteAuthority.not_ready")
	entry["lastRouteAuthority"] = {
		"state": String(state),
		"reason": String(reason),
		"ready": state == NpcEnumsScript.ROUTE_AUTHORITY_READY,
		"status": String(route.get("status", "")),
		"routeReason": String(route.get("reason", "")),
		"source": String(route.get("source", ""))
	}
	return route

static func canonical_state_for_route(route: Dictionary, intent := {}) -> StringName:
	var status := String(route.get("status", ""))
	var reason := String(route.get("reason", ""))
	var ok := bool(route.get("ok", false))
	var waypoints: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
	if ok and not waypoints.is_empty():
		if status == "partial" and not bool((intent as Dictionary).get("allowPartial", false)):
			if reason in ["path_endpoint_partial", "collision_lattice_probe_repair"]:
				return NpcEnumsScript.ROUTE_AUTHORITY_READY
			return NpcEnumsScript.ROUTE_AUTHORITY_UNREACHABLE_STATIC
		return NpcEnumsScript.ROUTE_AUTHORITY_READY
	if status in ["arrived", "complete"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_READY
	if status == "pending":
		return pending_state_for_reason(reason)
	if status in ["cancelled"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_CANCELLED
	if status in ["invalidated"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_INVALIDATED
	if status in ["failed", "failed_internal"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_FAILED_INTERNAL
	if reason in ["target_blocked", "outside_area", "no_target_server_walkable", "invalid_goal", "missing_world"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_INVALID_GOAL
	if reason in ["blocked_dynamic", "yielding", "traffic_wait", "door_wait", "local_blocked"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_BLOCKED_DYNAMIC
	if reason in ["route_budget", "frame_time_budget", "motion_budget"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_PENDING_BUDGET
	if reason in ["navmesh_tile_budget", "navmesh_tile_publish_frame_budget", "waiting_for_topology", "topology_unavailable", "probe_missing_ready_tile", "navigation_map_sync_pending"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_PENDING_NAV_DATA
	return NpcEnumsScript.ROUTE_AUTHORITY_UNREACHABLE_STATIC

static func pending_state_for_reason(reason: String) -> StringName:
	if reason in ["navmesh_tile_budget", "navmesh_tile_publish_frame_budget", "waiting_for_topology", "topology_unavailable", "probe_missing_ready_tile", "navigation_map_sync_pending"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_PENDING_NAV_DATA
	if reason in ["route_budget", "frame_time_budget", "motion_budget", "pending_budget"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_PENDING_BUDGET
	if reason in ["pending_probe", "collision_probe_budget"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_PENDING_PROBE
	if reason in ["blocked_dynamic", "yielding", "traffic_wait", "door_wait"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_BLOCKED_DYNAMIC
	return NpcEnumsScript.ROUTE_AUTHORITY_PENDING_BUDGET

func _next_generation(actor_id: String) -> int:
	var next_value := int(route_generations.get(actor_id, 0)) + 1
	route_generations[actor_id] = next_value
	return next_value

func _probe_ready_route(entry: Dictionary, route: Dictionary, intent: Dictionary) -> Dictionary:
	if collision_probe == null:
		return {
			"ok": true,
			"status": "skipped",
			"reason": "missing_collision_probe_service",
			"authoritative": false,
			"sampleCount": 0,
			"details": {}
		}
	var remaining_budget := maxi(0, probe_sample_budget_per_frame - probe_samples_used_this_frame)
	if remaining_budget <= 0:
		counters["probeBudgetDeferrals"] = int(counters.get("probeBudgetDeferrals", 0)) + 1
		return {
			"ok": false,
			"status": "pending_probe",
			"reason": "collision_probe_budget",
			"authoritative": true,
			"sampleCount": 0,
			"details": {
				"budgetPerFrame": probe_sample_budget_per_frame,
				"samplesUsedThisFrame": probe_samples_used_this_frame
			}
		}
	var cursor_key := _probe_cursor_key(entry, route, intent)
	var cursor: Dictionary = probe_cursors.get(cursor_key, {}) if probe_cursors.get(cursor_key, {}) is Dictionary else {}
	var probe_options := {
		"maxSamples": remaining_budget,
		"cursor": cursor
	}
	var certificate: Dictionary = collision_probe.probe_route(entry, route, intent, probe_options)
	probe_samples_used_this_frame += int(certificate.get("sampleCount", 0))
	if String(certificate.get("reason", "")) == "collision_probe_budget":
		var next_cursor := _probe_cursor_from_certificate(certificate, cursor)
		if not next_cursor.is_empty():
			probe_cursors[cursor_key] = next_cursor
			certificate["details"] = _probe_details_with_cursor_key(certificate, cursor_key, next_cursor)
	else:
		probe_cursors.erase(cursor_key)
	if bool(certificate.get("ok", false)) and bool(certificate.get("authoritative", false)):
		counters["probePassed"] = int(counters.get("probePassed", 0)) + 1
	elif String(certificate.get("status", "")) == "skipped":
		counters["probeSkipped"] = int(counters.get("probeSkipped", 0)) + 1
	else:
		counters["probeFailed"] = int(counters.get("probeFailed", 0)) + 1
	if String(certificate.get("reason", "")) == "collision_probe_budget":
		counters["probeBudgetDeferrals"] = int(counters.get("probeBudgetDeferrals", 0)) + 1
	return certificate

func _probe_cursor_key(entry: Dictionary, route: Dictionary, intent: Dictionary) -> String:
	var parts := PackedStringArray()
	parts.append(String(entry.get("id", "npc")))
	parts.append(String(intent.get("kind", "move")))
	parts.append(_probe_cell_key(intent.get("targetCell", route.get("targetCell", Vector2i(999999, 999999)))))
	parts.append(String(route.get("source", "")))
	parts.append(String(route.get("snapshotRevision", "")))
	parts.append(String(route.get("routeAuthoritySourceRevision", "")))
	var waypoints: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
	for waypoint_value in waypoints:
		if waypoint_value is Vector3:
			var waypoint: Vector3 = waypoint_value
			parts.append("%.3f,%.3f,%.3f" % [waypoint.x, waypoint.y, waypoint.z])
	var actions: Dictionary = route.get("actions", {}) if route.get("actions", {}) is Dictionary else {}
	var action_keys := actions.keys()
	action_keys.sort()
	for action_key in action_keys:
		parts.append("action:%s" % String(action_key))
	return "|".join(parts)

func _probe_cell_key(value) -> String:
	if value is Vector2i:
		var cell: Vector2i = value
		return "%d,%d" % [cell.x, cell.y]
	if value is Dictionary:
		var dictionary: Dictionary = value
		return "%d,%d" % [int(dictionary.get("x", 999999)), int(dictionary.get("z", dictionary.get("y", 999999)))]
	if value is Array and (value as Array).size() >= 2:
		var array_value: Array = value
		return "%d,%d" % [int(array_value[0]), int(array_value[1])]
	return "999999,999999"

func _probe_cursor_from_certificate(certificate: Dictionary, previous_cursor: Dictionary) -> Dictionary:
	var details: Dictionary = certificate.get("details", {}) if certificate.get("details", {}) is Dictionary else {}
	var cursor_value = details.get("cursor", {})
	if cursor_value is Dictionary and not (cursor_value as Dictionary).is_empty():
		return (cursor_value as Dictionary).duplicate(true)
	var segment_index := int(details.get("segmentIndex", -1))
	if segment_index < 0:
		return {}
	var sample_index := maxi(1, int(details.get("sampleIndex", 1)))
	var completed := int(details.get("completedSamples", int(previous_cursor.get("completedSamples", 0)) + int(certificate.get("sampleCount", 0))))
	return {
		"segmentIndex": segment_index,
		"sampleIndex": sample_index,
		"completedSamples": completed
	}

func _probe_details_with_cursor_key(certificate: Dictionary, cursor_key: String, cursor: Dictionary) -> Dictionary:
	var details: Dictionary = certificate.get("details", {}) if certificate.get("details", {}) is Dictionary else {}
	var result := details.duplicate(true)
	result["cursorKey"] = cursor_key
	result["cursor"] = cursor.duplicate(true)
	return result

func _state_for_probe_failure(certificate: Dictionary) -> StringName:
	var reason := String(certificate.get("reason", ""))
	var status := String(certificate.get("status", ""))
	if status == "skipped" or reason in ["collision_probe_budget", "missing_body", "missing_world_3d", "empty_waypoints", "single_point_route"]:
		return NpcEnumsScript.ROUTE_AUTHORITY_PENDING_PROBE
	return NpcEnumsScript.ROUTE_AUTHORITY_UNREACHABLE_STATIC

func _probe_repair_route(entry: Dictionary, route: Dictionary, intent: Dictionary, certificate: Dictionary) -> Dictionary:
	if delegate == null or not delegate.has_method("plan_probe_repair_route"):
		return {}
	if bool(intent.get("probeRepairAttempt", false)):
		return {}
	if String(certificate.get("reason", "")) != "blocked_capsule_probe":
		return {}
	var repair_route: Dictionary = delegate.plan_probe_repair_route(entry, intent, route, certificate)
	if repair_route.is_empty() or not bool(repair_route.get("ok", false)):
		return {}
	repair_route["probeRepairAttempt"] = true
	repair_route["probeRepairSource"] = route.duplicate(true)
	return repair_route

func _probe_repair_intent(intent: Dictionary) -> Dictionary:
	var repair_intent := intent.duplicate(true)
	repair_intent["probeRepairAttempt"] = true
	repair_intent["allowPartial"] = true
	return repair_intent

func _reject_unprobed_route(route: Dictionary, state: StringName, reason: StringName) -> void:
	route["ok"] = false
	route["status"] = "pending" if NpcEnumsScript.route_authority_state_is_pending(state) else "blocked"
	route["reason"] = String(reason)
	route["waypoints"] = []
	route["cells"] = []
	route["actions"] = {}

func _increment_state_counter(state: StringName) -> void:
	var key := "failedInternal"
	match state:
		NpcEnumsScript.ROUTE_AUTHORITY_READY:
			key = "ready"
		NpcEnumsScript.ROUTE_AUTHORITY_PENDING_NAV_DATA:
			key = "pendingNavData"
		NpcEnumsScript.ROUTE_AUTHORITY_PENDING_BUDGET:
			key = "pendingBudget"
		NpcEnumsScript.ROUTE_AUTHORITY_PENDING_PROBE:
			key = "pendingProbe"
		NpcEnumsScript.ROUTE_AUTHORITY_BLOCKED_DYNAMIC:
			key = "blockedDynamic"
		NpcEnumsScript.ROUTE_AUTHORITY_UNREACHABLE_STATIC:
			key = "unreachableStatic"
		NpcEnumsScript.ROUTE_AUTHORITY_INVALID_GOAL:
			key = "invalidGoal"
		NpcEnumsScript.ROUTE_AUTHORITY_CANCELLED:
			key = "cancelled"
		NpcEnumsScript.ROUTE_AUTHORITY_INVALIDATED:
			key = "invalidated"
		NpcEnumsScript.ROUTE_AUTHORITY_FAILED_INTERNAL:
			key = "failedInternal"
	counters[key] = int(counters.get(key, 0)) + 1

func _route_failure(status: String, reason: String, target_cell := Vector2i(999999, 999999)) -> Dictionary:
	return {
		"ok": false,
		"status": status,
		"reason": reason,
		"cells": [],
		"waypoints": [],
		"actions": {},
		"targetCell": target_cell,
		"fallbackCell": Vector2i(999999, 999999),
		"snapshotRevision": ""
	}

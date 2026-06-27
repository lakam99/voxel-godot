extends RefCounted
class_name AbstractNpcTransit

const STATE_PENDING := "pending"
const STATE_ACTIVE := "active"
const STATE_ARRIVED := "arrived"
const STATE_BLOCKED := "blocked"

var actor_id := ""
var from_region_id := ""
var to_region_id := ""
var portal_ids: Array[String] = []
var expected_duration := 0.0
var elapsed := 0.0
var state := STATE_PENDING
var access := "open"
var blocked_reason := ""
var requires_loaded_topology := false
var topology_known := true
var topology_loaded := true
var metadata := {}

static func edge_is_traversable(edge: Dictionary) -> Dictionary:
	var edge_access := String(edge.get("access", "open"))
	if bool(edge.get("locked", false)) or edge_access in ["locked", "denied", "unauthorized"]:
		return { "ok": false, "reason": "locked_portal" }
	if bool(edge.get("infeasible", false)) or edge_access == "infeasible":
		return { "ok": false, "reason": "infeasible_portal" }
	if bool(edge.get("unknown", false)) or not bool(edge.get("topologyKnown", true)):
		return { "ok": false, "reason": "unknown_topology" }
	if bool(edge.get("requiresLoadedTopology", false)) and not bool(edge.get("topologyLoaded", true)):
		return { "ok": false, "reason": "unloaded_topology" }
	return { "ok": true, "reason": "" }

static func from_edge(actor: String, edge: Dictionary):
	var transit = load("res://scripts/npc_ai/lifecycle/AbstractNpcTransit.gd").new()
	transit.configure(actor, edge)
	return transit

static func from_save(saved: Dictionary):
	var transit = load("res://scripts/npc_ai/lifecycle/AbstractNpcTransit.gd").new()
	transit.actor_id = String(saved.get("actorId", ""))
	transit.from_region_id = String(saved.get("fromRegionId", ""))
	transit.to_region_id = String(saved.get("toRegionId", ""))
	transit.portal_ids.clear()
	for value in saved.get("portalIds", []):
		transit.portal_ids.append(String(value))
	transit.expected_duration = maxf(0.0, float(saved.get("expectedDuration", 0.0)))
	transit.elapsed = clampf(float(saved.get("elapsed", 0.0)), 0.0, maxf(transit.expected_duration, 0.001))
	transit.state = String(saved.get("state", STATE_PENDING))
	transit.access = String(saved.get("access", "open"))
	transit.blocked_reason = String(saved.get("blockedReason", ""))
	transit.requires_loaded_topology = bool(saved.get("requiresLoadedTopology", false))
	transit.topology_known = bool(saved.get("topologyKnown", true))
	transit.topology_loaded = bool(saved.get("topologyLoaded", true))
	var saved_metadata = saved.get("metadata", {})
	transit.metadata = saved_metadata.duplicate(true) if saved_metadata is Dictionary else {}
	return transit

func configure(actor: String, edge: Dictionary) -> void:
	actor_id = actor
	from_region_id = String(edge.get("fromRegionId", edge.get("from", "")))
	to_region_id = String(edge.get("toRegionId", edge.get("to", "")))
	portal_ids.clear()
	if edge.has("portalIds") and edge["portalIds"] is Array:
		for portal in edge["portalIds"]:
			portal_ids.append(String(portal))
	elif String(edge.get("portalId", "")) != "":
		portal_ids.append(String(edge.get("portalId", "")))
	expected_duration = maxf(0.001, float(edge.get("durationSeconds", edge.get("expectedDuration", 1.0))))
	elapsed = clampf(float(edge.get("elapsed", 0.0)), 0.0, expected_duration)
	access = String(edge.get("access", "open"))
	requires_loaded_topology = bool(edge.get("requiresLoadedTopology", false))
	topology_known = bool(edge.get("topologyKnown", true))
	topology_loaded = bool(edge.get("topologyLoaded", true))
	metadata = edge.get("metadata", {}).duplicate(true) if edge.get("metadata", {}) is Dictionary else {}
	var allowed := edge_is_traversable(edge)
	if not bool(allowed.get("ok", false)):
		state = STATE_BLOCKED
		blocked_reason = String(allowed.get("reason", "blocked"))
	else:
		state = STATE_PENDING
		blocked_reason = ""

func advance(delta: float) -> Dictionary:
	if state == STATE_BLOCKED or state == STATE_ARRIVED:
		return to_summary()
	if state == STATE_PENDING:
		state = STATE_ACTIVE
	elapsed = minf(expected_duration, elapsed + maxf(0.0, delta))
	if elapsed >= expected_duration:
		state = STATE_ARRIVED
	return to_summary()

func is_terminal() -> bool:
	return state == STATE_ARRIVED or state == STATE_BLOCKED

func progress_ratio() -> float:
	if expected_duration <= 0.0:
		return 1.0
	return clampf(elapsed / expected_duration, 0.0, 1.0)

func to_save() -> Dictionary:
	return {
		"schemaVersion": 1,
		"actorId": actor_id,
		"fromRegionId": from_region_id,
		"toRegionId": to_region_id,
		"portalIds": portal_ids.duplicate(),
		"expectedDuration": expected_duration,
		"elapsed": elapsed,
		"state": state,
		"access": access,
		"blockedReason": blocked_reason,
		"requiresLoadedTopology": requires_loaded_topology,
		"topologyKnown": topology_known,
		"topologyLoaded": topology_loaded,
		"metadata": metadata.duplicate(true)
	}

func to_summary() -> Dictionary:
	return {
		"actorId": actor_id,
		"fromRegionId": from_region_id,
		"toRegionId": to_region_id,
		"portalIds": portal_ids.duplicate(),
		"state": state,
		"progress": progress_ratio(),
		"elapsed": elapsed,
		"expectedDuration": expected_duration,
		"reason": blocked_reason
	}

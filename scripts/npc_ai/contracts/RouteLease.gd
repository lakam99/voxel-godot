extends RefCounted
class_name RouteLease

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var lease_id := ""
var owner_npc_id := ""
var generation := 0
var state: StringName = NpcEnumsScript.ROUTE_AUTHORITY_READY
var reason: StringName = NpcEnumsScript.ROUTE_REASON_NONE
var issued_frame := 0
var source := ""
var target_cell := Vector2i(999999, 999999)
var fallback_cell := Vector2i(999999, 999999)
var snapshot_revision := ""
var cells: Array = []
var waypoints: Array = []
var actions := {}
var probe_certificate := {}
var route_summary := {}
var interaction_claim := {}

static func from_route(route: Dictionary, owner_id: String, generation_value: int, state_value: StringName, reason_value: StringName):
	var lease = load("res://scripts/npc_ai/contracts/RouteLease.gd").new()
	lease.owner_npc_id = owner_id
	lease.generation = generation_value
	lease.state = state_value
	lease.reason = reason_value
	lease.issued_frame = Engine.get_physics_frames()
	lease.lease_id = "%s:%d:%d" % [owner_id, generation_value, lease.issued_frame]
	lease.source = String(route.get("source", ""))
	lease.target_cell = route.get("targetCell", Vector2i(999999, 999999))
	lease.fallback_cell = route.get("fallbackCell", Vector2i(999999, 999999))
	lease.snapshot_revision = String(route.get("snapshotRevision", ""))
	lease.cells = (route.get("cells", []) as Array).duplicate()
	lease.waypoints = (route.get("waypoints", []) as Array).duplicate()
	lease.actions = (route.get("actions", {}) as Dictionary).duplicate(true)
	lease.probe_certificate = (route.get("probeCertificate", {}) as Dictionary).duplicate(true) if route.get("probeCertificate", {}) is Dictionary else {}
	lease.interaction_claim = (route.get("interactionClaim", {}) as Dictionary).duplicate(true) if route.get("interactionClaim", {}) is Dictionary else {}
	lease.route_summary = {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"source": lease.source,
		"waypointCount": lease.waypoints.size(),
		"cellCount": lease.cells.size(),
		"actionCount": lease.actions.size()
	}
	return lease

func is_ready() -> bool:
	return NpcEnumsScript.route_authority_state_is_ready(state)

func to_dictionary() -> Dictionary:
	return {
		"leaseId": lease_id,
		"ownerNpcId": owner_npc_id,
		"generation": generation,
		"state": String(state),
		"reason": String(reason),
		"issuedFrame": issued_frame,
		"source": source,
		"targetCell": target_cell,
		"fallbackCell": fallback_cell,
		"snapshotRevision": snapshot_revision,
		"cells": cells.duplicate(),
		"waypoints": waypoints.duplicate(),
		"actions": actions.duplicate(true),
		"probeCertificate": probe_certificate.duplicate(true),
		"interactionClaim": interaction_claim.duplicate(true),
		"route": route_summary.duplicate(true)
	}

func to_summary() -> Dictionary:
	return {
		"leaseId": lease_id,
		"ownerNpcId": owner_npc_id,
		"generation": generation,
		"state": String(state),
		"reason": String(reason),
		"source": source,
		"waypointCount": waypoints.size(),
		"cellCount": cells.size(),
		"actionCount": actions.size(),
		"snapshotRevision": snapshot_revision
	}

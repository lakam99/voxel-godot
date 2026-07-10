extends RefCounted
class_name NpcRouteStateStore

static func write_status(entry: Dictionary, status: String, reason: String = "", source: String = "") -> void:
	if entry.is_empty():
		return
	entry["routeStatus"] = status
	entry["routeReason"] = reason
	_record_writer(entry, source)
	_publish_body_status(entry, status, reason)

static func write_status_preserving_reason(entry: Dictionary, status: String, source: String = "") -> void:
	write_status(entry, status, String(entry.get("routeReason", "")), source)

static func write_reason(entry: Dictionary, reason: String, source: String = "") -> void:
	if entry.is_empty():
		return
	entry["routeReason"] = reason
	_record_writer(entry, source)
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body):
		body.set_meta("npc_route_reason", reason)

static func publish_to_body(entry: Dictionary) -> void:
	if entry.is_empty():
		return
	_publish_body_status(entry, String(entry.get("routeStatus", "idle")), String(entry.get("routeReason", "")))

static func write_route_lease(entry: Dictionary, lease: Dictionary, lease_id: String = "", generation: Variant = null, source: String = "") -> void:
	if entry.is_empty():
		return
	if lease.is_empty():
		clear_route_lease(entry, source)
		return
	entry["routeLease"] = lease.duplicate(true)
	entry["routeLeaseId"] = String(lease_id)
	if generation != null:
		entry["routeLeaseGeneration"] = int(generation)
	_record_writer(entry, source)

static func write_route_lease_from_route(entry: Dictionary, route: Dictionary, source: String = "") -> void:
	var lease: Dictionary = route.get("routeLease", {}) if route.get("routeLease", {}) is Dictionary else {}
	if lease.is_empty():
		clear_route_lease(entry, source)
		return
	write_route_lease(entry, lease, String(route.get("routeLeaseId", "")), route.get("routeLeaseGeneration", null), source)

static func clear_route_lease(entry: Dictionary, source: String = "") -> void:
	if entry.is_empty():
		return
	entry.erase("routeLease")
	entry.erase("routeLeaseId")
	_record_writer(entry, source)

static func mark_route_missing_lease(route: Dictionary) -> void:
	route["ok"] = false
	route["status"] = "pending"
	route["reason"] = "missing_route_lease"
	route["routeAuthorityState"] = "pending_probe"
	route["routeAuthorityReady"] = false

static func _publish_body_status(entry: Dictionary, status: String, reason: String) -> void:
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body):
		body.set_meta("npc_route_status", status)
		body.set_meta("npc_route_reason", reason)

static func _record_writer(entry: Dictionary, source: String) -> void:
	if source == "":
		source = "unspecified"
	entry["lastRouteStateWriter"] = source
	entry["routeStateWriteCount"] = int(entry.get("routeStateWriteCount", 0)) + 1

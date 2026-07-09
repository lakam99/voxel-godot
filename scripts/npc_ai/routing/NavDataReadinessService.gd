extends RefCounted
class_name NavDataReadinessService

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var adapter = null
var counters := {
	"requests": 0,
	"ready": 0,
	"pendingNavData": 0,
	"unavailable": 0
}

func setup(route_adapter) -> void:
	adapter = route_adapter

func ensure_ready_for_route(entry: Dictionary, intent: Dictionary) -> Dictionary:
	counters["requests"] = int(counters.get("requests", 0)) + 1
	if adapter == null or not adapter.has_method("_ensure_navmesh_route_tiles"):
		counters["unavailable"] = int(counters.get("unavailable", 0)) + 1
		return _result(true, NpcEnumsScript.ROUTE_AUTHORITY_READY, "", "no_tile_readiness_backend", entry)
	var ready := bool(adapter._ensure_navmesh_route_tiles(entry, intent))
	if ready and bool(entry.get("navmeshRouteTilesStillLoading", false)):
		counters["pendingNavData"] = int(counters.get("pendingNavData", 0)) + 1
		return _result(false, NpcEnumsScript.ROUTE_AUTHORITY_PENDING_NAV_DATA, "navmesh_tile_budget", "route_tiles_still_loading", entry)
	if ready:
		counters["ready"] = int(counters.get("ready", 0)) + 1
		return _result(true, NpcEnumsScript.ROUTE_AUTHORITY_READY, "", "tiles_ready", entry)
	counters["pendingNavData"] = int(counters.get("pendingNavData", 0)) + 1
	return _result(false, NpcEnumsScript.ROUTE_AUTHORITY_PENDING_NAV_DATA, "navmesh_tile_budget", "tiles_still_loading", entry)

func stats() -> Dictionary:
	return counters.duplicate(true)

func _result(ready: bool, state: StringName, reason: String, detail: String, entry: Dictionary) -> Dictionary:
	return {
		"ready": ready,
		"state": String(state),
		"reason": reason,
		"detail": detail,
		"navmeshRouteTilesStillLoading": bool(entry.get("navmeshRouteTilesStillLoading", false)),
		"lastNavmeshTilePublishDebug": (entry.get("lastNavmeshTilePublishDebug", []) as Array).duplicate(true) if entry.get("lastNavmeshTilePublishDebug", []) is Array else []
	}

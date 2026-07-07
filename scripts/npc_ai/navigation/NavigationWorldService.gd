extends RefCounted
class_name NavigationWorldService

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NavigationChangeBusScript := preload("res://scripts/npc_ai/navigation/NavigationChangeBus.gd")
const NavigationBuildQueueScript := preload("res://scripts/npc_ai/navigation/NavigationBuildQueue.gd")
const NavigationTileBuilderScript := preload("res://scripts/npc_ai/navigation/NavigationTileBuilder.gd")
const NavigationSemanticServiceScript := preload("res://scripts/npc_ai/navigation/NavigationSemanticService.gd")
const NavGraphQueryScript := preload("res://scripts/npc_ai/navigation/NavGraphQuery.gd")

var world_source = null
var change_bus = null
var build_queue = NavigationBuildQueueScript.new()
var tile_builder = NavigationTileBuilderScript.new()
var semantic_service = NavigationSemanticServiceScript.new()
var tiles_by_key := {}
var dirty_tiles := {}
var tile_states := {}
var topology_revision := 0
var dynamic_revision := 0
var semantic_revision := 0
var processed_event_count := 0
var debug_enabled := false

func setup(source = null, bus = null) -> void:
	world_source = source
	change_bus = bus if bus != null else NavigationChangeBusScript.new()

func clear() -> void:
	tiles_by_key.clear()
	dirty_tiles.clear()
	tile_states.clear()
	topology_revision = 0
	dynamic_revision = 0
	semantic_revision = 0
	processed_event_count = 0
	build_queue.clear()
	semantic_service.clear()

func process_change_bus(max_events := -1, max_object_ids := -1) -> Array:
	if change_bus == null:
		return []
	var events: Array = change_bus.flush_frame(max_events, max_object_ids)
	apply_events(events)
	return events

func apply_events(events: Array) -> void:
	for event in events:
		if not (event is Dictionary):
			continue
		processed_event_count += 1
		var tile_key := String(event.get("tileKey", ""))
		var kinds: Array = event.get("changeKinds", [])
		for kind_value in kinds:
			var kind := String(kind_value)
			if _is_topology_kind(kind):
				topology_revision += 1
				_mark_dirty(tile_key, event)
			elif _is_dynamic_kind(kind):
				dynamic_revision += 1
			elif _is_semantic_kind(kind):
				semantic_revision += 1
				_mark_dirty(tile_key, event)
			if kind == String(NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED):
				_mark_unloaded(tile_key)
			elif kind == String(NpcEnumsScript.CHANGE_KIND_CHUNK_LOADED):
				tile_states[tile_key] = "dirty"
				_mark_dirty(tile_key, event)

func request_tile(snapshot: Dictionary, priority := 0, profile = null) -> Dictionary:
	var tile_key := String(snapshot.get("tileKey", "0,0"))
	if String(tile_states.get(tile_key, "")) == "unloaded":
		return { "status": String(NpcEnumsScript.ROUTE_STATUS_PENDING), "reason": String(NpcEnumsScript.ROUTE_REASON_WAITING_FOR_TOPOLOGY), "tileKey": tile_key, "unloaded": true }
	if not tiles_by_key.has(tile_key) or dirty_tiles.has(tile_key):
		build_queue.schedule_tile(tile_key, snapshot, priority, topology_revision, profile)
		return { "status": String(NpcEnumsScript.ROUTE_STATUS_PENDING), "reason": String(NpcEnumsScript.ROUTE_REASON_WAITING_FOR_TOPOLOGY), "tileKey": tile_key }
	return { "status": String(NpcEnumsScript.ROUTE_STATUS_COMPLETE), "tileKey": tile_key, "revision": get_tile(tile_key).get("topology_revision") }

func build_next_tiles(max_jobs := 1, max_usec := 4000) -> Array:
	var built := build_queue.process_budget(tile_builder, topology_revision, max_jobs, max_usec)
	for tile in built:
		topology_revision = max(topology_revision, int(tile.get("topology_revision")))
		tiles_by_key[String(tile.get("tile_key"))] = tile
		dirty_tiles.erase(String(tile.get("tile_key")))
		if not bool(tile.get("unloaded")):
			tile_states[String(tile.get("tile_key"))] = "ready"
	return built

func build_tile_now(snapshot: Dictionary, profile = null):
	var tile_key := String(snapshot.get("tileKey", "0,0"))
	topology_revision += 1
	var tile = tile_builder.build_tile(snapshot, topology_revision, profile, topology_revision)
	tiles_by_key[tile_key] = tile
	dirty_tiles.erase(tile_key)
	tile_states[tile_key] = "unloaded" if bool(tile.get("unloaded")) else "ready"
	return tile

func get_tile(tile_key: String):
	return tiles_by_key.get(tile_key)

func is_tile_traversable(tile_key: String) -> bool:
	return tiles_by_key.has(tile_key) and String(tile_states.get(tile_key, "")) == "ready" and not bool(tiles_by_key[tile_key].get("unloaded")) and not bool(tiles_by_key[tile_key].get("stale"))

func query():
	var graph_query = NavGraphQueryScript.new()
	graph_query.setup(self)
	return graph_query

func register_semantic_region(kind: StringName, region_id: String, bounds: AABB, metadata := {}) -> int:
	var revision := semantic_service.register_region(kind, region_id, bounds, metadata)
	semantic_revision = max(semantic_revision, revision)
	return revision

func debug_export() -> Dictionary:
	var tile_summaries := {}
	var keys := tiles_by_key.keys()
	keys.sort()
	for tile_key in keys:
		tile_summaries[String(tile_key)] = tiles_by_key[tile_key].to_summary()
	return {
		"enabled": debug_enabled,
		"topologyRevision": topology_revision,
		"dynamicRevision": dynamic_revision,
		"semanticRevision": semantic_revision,
		"tiles": tile_summaries,
		"dirtyTiles": dirty_tiles.keys(),
		"tileStates": tile_states.duplicate(),
		"semantics": semantic_service.to_summary()
	}

func stats() -> Dictionary:
	return {
		"tileCount": tiles_by_key.size(),
		"dirtyTileCount": dirty_tiles.size(),
		"topologyRevision": topology_revision,
		"dynamicRevision": dynamic_revision,
		"semanticRevision": semantic_revision,
		"processedEvents": processed_event_count,
		"buildQueue": build_queue.stats(),
		"semantics": semantic_service.stats()
	}

func _mark_dirty(tile_key: String, event: Dictionary) -> void:
	if tile_key == "":
		return
	dirty_tiles[tile_key] = _dirty_event_summary(event)
	if tiles_by_key.has(tile_key):
		tiles_by_key[tile_key].mark_stale()
	if String(tile_states.get(tile_key, "")) != "unloaded":
		tile_states[tile_key] = "dirty"

func _dirty_event_summary(event: Dictionary) -> Dictionary:
	return {
		"tileKey": String(event.get("tileKey", "")),
		"revision": int(event.get("revision", 0)),
		"changeKinds": (event.get("changeKinds", []) as Array).duplicate(),
		"coalescedCount": int(event.get("coalescedCount", 0)),
		"bounds": event.get("bounds", AABB())
	}

func _mark_unloaded(tile_key: String) -> void:
	tile_states[tile_key] = "unloaded"
	dirty_tiles.erase(tile_key)
	if tiles_by_key.has(tile_key):
		tiles_by_key[tile_key].mark_unloaded()

func _is_topology_kind(kind: String) -> bool:
	return kind in [
		String(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED),
		String(NpcEnumsScript.CHANGE_KIND_BLOCK_REMOVED),
		String(NpcEnumsScript.CHANGE_KIND_TERRAIN_EDIT),
		String(NpcEnumsScript.CHANGE_KIND_PROP_REMOVED),
		String(NpcEnumsScript.CHANGE_KIND_CHUNK_LOADED),
		String(NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED),
		String(NpcEnumsScript.CHANGE_KIND_DOOR_REGISTERED),
		String(NpcEnumsScript.CHANGE_KIND_STRUCTURE_METADATA)
	]

func _is_dynamic_kind(kind: String) -> bool:
	return kind in [
		String(NpcEnumsScript.CHANGE_KIND_DOOR_STATE)
	]

func _is_semantic_kind(kind: String) -> bool:
	return kind in [
		String(NpcEnumsScript.CHANGE_KIND_SEMANTIC_CHANGED),
		String(NpcEnumsScript.CHANGE_KIND_STRUCTURE_METADATA)
	]

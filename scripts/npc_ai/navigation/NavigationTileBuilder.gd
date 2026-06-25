extends RefCounted
class_name NavigationTileBuilder

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const TraversalProfileScript := preload("res://scripts/npc_ai/contracts/TraversalProfile.gd")
const NavSpanDataScript := preload("res://scripts/npc_ai/contracts/NavSpanData.gd")
const NavEdgeDataScript := preload("res://scripts/npc_ai/contracts/NavEdgeData.gd")
const NavTileDataScript := preload("res://scripts/npc_ai/contracts/NavTileData.gd")

func build_tile(snapshot: Dictionary, topology_revision: int, profile = null, source_revision := 0):
	var started := Time.get_ticks_usec()
	var traversal_profile = profile if profile != null else TraversalProfileScript.default_adult_npc()
	var tile = NavTileDataScript.new()
	tile.tile_key = String(snapshot.get("tileKey", "0,0"))
	tile.topology_revision = topology_revision
	tile.source_revision = source_revision
	tile.dynamic_revision = int(snapshot.get("dynamicRevision", 0))
	tile.semantic_revision = int(snapshot.get("semanticRevision", 0))
	tile.unloaded = bool(snapshot.get("unloaded", false))
	if tile.unloaded:
		tile.build_metrics = { "durationUsec": Time.get_ticks_usec() - started, "unloaded": true }
		return tile
	var index := 0
	for surface in snapshot.get("surfaces", []):
		if not (surface is Dictionary):
			continue
		var span_index: int = int(surface.get("spanIndex", index))
		var span = NavSpanDataScript.from_surface(tile.tile_key, surface, span_index)
		span.walkable = span.walkable and span.supports_profile(traversal_profile)
		tile.add_span(span)
		index += 1
	for semantic in snapshot.get("semanticRegions", []):
		if semantic is Dictionary:
			tile.semantic_regions[String(semantic.get("id", ""))] = semantic
	_build_neighbor_edges(tile, traversal_profile)
	_register_door_links(tile, snapshot)
	tile.build_metrics = {
		"durationUsec": Time.get_ticks_usec() - started,
		"surfaceCount": index,
		"walkableSpanCount": _walkable_count(tile),
		"edgeCount": tile.edge_count()
	}
	return tile

func _build_neighbor_edges(tile, profile) -> void:
	var spans: Array = tile.spans_by_key.values()
	for from_span in spans:
		if from_span == null or not bool(from_span.get("walkable")):
			continue
		for to_span in spans:
			if to_span == null or from_span == to_span or not bool(to_span.get("walkable")):
				continue
			var dx: int = int(to_span.get("cell").x) - int(from_span.get("cell").x)
			var dz: int = int(to_span.get("cell").z) - int(from_span.get("cell").z)
			if maxi(abs(dx), abs(dz)) != 1:
				continue
			if dx != 0 and dz != 0 and not _diagonal_allowed(tile, from_span.get("cell"), dx, dz):
				continue
			var edge = _edge_for_spans(from_span, to_span, profile)
			if edge != null:
				tile.add_edge(edge)

func _edge_for_spans(from_span, to_span, profile):
	var vertical_delta: float = float(to_span.get("world_position").y) - float(from_span.get("world_position").y)
	var step_up := _profile_float(profile, "step_up_height", NpcConstantsScript.DEFAULT_NPC_STEP_UP)
	var safe_drop := _profile_float(profile, "safe_step_drop_height", NpcConstantsScript.DEFAULT_NPC_SAFE_DROP)
	var kind: StringName = NpcEnumsScript.TRAVERSAL_KIND_WALK
	if vertical_delta > 0.05:
		if vertical_delta > step_up:
			return null
		kind = NpcEnumsScript.TRAVERSAL_KIND_STEP
	elif vertical_delta < -0.05:
		if absf(vertical_delta) > safe_drop:
			return null
		kind = NpcEnumsScript.TRAVERSAL_KIND_DROP
	var flat_distance := Vector2(float(to_span.get("cell").x - from_span.get("cell").x), float(to_span.get("cell").z - from_span.get("cell").z)).length()
	var cost := maxf(0.001, flat_distance) + absf(vertical_delta) * 0.25
	return NavEdgeDataScript.make(from_span.key_string(), to_span.key_string(), kind, cost)

func _diagonal_allowed(tile, from_cell: Vector3i, dx: int, dz: int) -> bool:
	var side_a := Vector3i(from_cell.x + dx, from_cell.y, from_cell.z)
	var side_b := Vector3i(from_cell.x, from_cell.y, from_cell.z + dz)
	return _column_has_walkable(tile, side_a) and _column_has_walkable(tile, side_b)

func _column_has_walkable(tile, cell: Vector3i) -> bool:
	for span in tile.spans_for_column(cell):
		if span != null and bool(span.get("walkable")):
			return true
	return false

func _register_door_links(tile, snapshot: Dictionary) -> void:
	for portal in snapshot.get("doorPortals", []):
		if portal is Dictionary:
			var portal_id := String(portal.get("id", ""))
			if portal_id != "":
				tile.door_portals[portal_id] = portal
	for link in snapshot.get("doorLinks", []):
		if not (link is Dictionary):
			continue
		var from_key := String(link.get("from", ""))
		var to_key := String(link.get("to", ""))
		if from_key == "" or to_key == "":
			continue
		var edge = NavEdgeDataScript.make(from_key, to_key, NpcEnumsScript.TRAVERSAL_KIND_DOOR, float(link.get("cost", 1.5)))
		edge.portal_id = String(link.get("portalId", ""))
		edge.action_id = String(link.get("actionId", "open"))
		edge.required_capabilities.append(&"open_doors")
		edge.metadata = link.duplicate()
		tile.add_edge(edge)

func _profile_float(profile, property_name: String, fallback: float) -> float:
	if profile == null:
		return fallback
	var value = profile.get(property_name)
	if value == null:
		return fallback
	return float(value)

func _walkable_count(tile) -> int:
	var count := 0
	for span in tile.spans_by_key.values():
		if span != null and bool(span.get("walkable")):
			count += 1
	return count

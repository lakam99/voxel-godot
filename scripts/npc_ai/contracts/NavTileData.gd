extends RefCounted
class_name NavTileData

var tile_key := ""
var topology_revision := 0
var source_revision := 0
var dynamic_revision := 0
var semantic_revision := 0
var unloaded := false
var stale := false
var spans_by_key := {}
var spans_by_column := {}
var edges_by_from := {}
var semantic_regions := {}
var door_portals := {}
var build_metrics := {}

func add_span(span) -> void:
	var key: String = span.key_string()
	spans_by_key[key] = span
	var column_key: String = column_key_for_cell(span.cell)
	if not spans_by_column.has(column_key):
		spans_by_column[column_key] = []
	(spans_by_column[column_key] as Array).append(key)

func add_edge(edge) -> void:
	if not edges_by_from.has(edge.from_key):
		edges_by_from[edge.from_key] = {}
	(edges_by_from[edge.from_key] as Dictionary)[edge.to_key] = edge

func spans_for_column(cell) -> Array:
	var column_key := ""
	if cell is Vector3i:
		column_key = column_key_for_cell(cell)
	elif cell is Vector2i:
		column_key = "%d,%d" % [cell.x, cell.y]
	else:
		column_key = String(cell)
	var result: Array = []
	for key in spans_by_column.get(column_key, []):
		result.append(spans_by_key.get(key))
	return result

func edge_between(from_key: String, to_key: String):
	if not edges_by_from.has(from_key):
		return null
	return (edges_by_from[from_key] as Dictionary).get(to_key)

func edge_count() -> int:
	var total := 0
	for edges in edges_by_from.values():
		total += (edges as Dictionary).size()
	return total

func mark_stale() -> void:
	stale = true

func mark_unloaded() -> void:
	unloaded = true
	stale = true

static func column_key_for_cell(cell: Vector3i) -> String:
	return "%d,%d" % [cell.x, cell.z]

func stable_signature() -> String:
	var span_keys: Array = spans_by_key.keys()
	span_keys.sort()
	var edge_keys: Array[String] = []
	for from_key in edges_by_from.keys():
		var targets: Array = (edges_by_from[from_key] as Dictionary).keys()
		targets.sort()
		for to_key in targets:
			var edge = (edges_by_from[from_key] as Dictionary)[to_key]
			edge_keys.append("%s:%s:%.3f" % [String(from_key), String(edge.traversal_kind), float(edge.cost)])
	edge_keys.sort()
	var semantic_keys: Array = semantic_regions.keys()
	semantic_keys.sort()
	var portal_keys: Array = door_portals.keys()
	portal_keys.sort()
	return JSON.stringify({
		"tileKey": tile_key,
		"spans": span_keys,
		"edges": edge_keys,
		"semantics": semantic_keys,
		"portals": portal_keys
	})

func to_summary() -> Dictionary:
	return {
		"tileKey": tile_key,
		"topologyRevision": topology_revision,
		"sourceRevision": source_revision,
		"dynamicRevision": dynamic_revision,
		"semanticRevision": semantic_revision,
		"unloaded": unloaded,
		"stale": stale,
		"spanCount": spans_by_key.size(),
		"edgeCount": edge_count(),
		"semanticRegionCount": semantic_regions.size(),
		"doorPortalCount": door_portals.size(),
		"buildMetrics": build_metrics.duplicate()
	}

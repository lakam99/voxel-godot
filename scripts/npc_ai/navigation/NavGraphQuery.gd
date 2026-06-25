extends RefCounted
class_name NavGraphQuery

var world_service = null

func setup(service) -> void:
	world_service = service

func tile(tile_key: String):
	return world_service.get_tile(tile_key) if world_service != null else null

func spans_at(tile_key: String, cell) -> Array:
	var nav_tile = tile(tile_key)
	if nav_tile == null:
		return []
	return nav_tile.spans_for_column(cell)

func edge_between(tile_key: String, from_key: String, to_key: String):
	var nav_tile = tile(tile_key)
	if nav_tile == null:
		return null
	return nav_tile.edge_between(from_key, to_key)

func is_tile_traversable(tile_key: String) -> bool:
	if world_service == null:
		return false
	return world_service.is_tile_traversable(tile_key)

func tile_summary(tile_key: String) -> Dictionary:
	var nav_tile = tile(tile_key)
	return nav_tile.to_summary() if nav_tile != null else { "tileKey": tile_key, "missing": true }

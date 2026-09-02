extends RefCounted
class_name CitadelSiteField

## Candidate locations only. A candidate is NOT permission to publish terrain
## or a building: its complete geometry-derived reservation must be surveyed.
## Cells are world XZ cells, never chunk-local or underground coordinates.
const VERSION := 1
const REGION_CELLS := 2048
const JITTER_CELLS := 384
const OCCUPANCY_PER_THOUSAND := 350
const REGION_GUARD_CELLS := 1
const MIN_REGION_COORD := -1048576
const MAX_REGION_COORD := 1048575


static func region_for_cell(cell: Vector2i) -> Vector2i:
	return Vector2i(floori(float(cell.x) / REGION_CELLS), floori(float(cell.y) / REGION_CELLS))


static func candidate_for_region(world_seed: String, region: Vector2i) -> Dictionary:
	if world_seed.is_empty() or not _valid_region(region):
		return {}
	# Length-prefix the seed so punctuation in seed text cannot alias a region.
	var identity := "citadel-site-v%d:%d:%s:%d,%d" % [VERSION, world_seed.length(), world_seed, region.x, region.y]
	if _channel(identity, "presence") % 1000 >= OCCUPANCY_PER_THOUSAND:
		return {}
	var center := region * REGION_CELLS + Vector2i(REGION_CELLS / 2, REGION_CELLS / 2)
	center += Vector2i(_channel(identity, "x") % (JITTER_CELLS * 2 + 1) - JITTER_CELLS, _channel(identity, "z") % (JITTER_CELLS * 2 + 1) - JITTER_CELLS)
	return {
		"version": VERSION,
		"siteId": identity,
		"worldSeed": world_seed,
		"region": region,
		"centerCell": center,
		"recipeSeed": _channel(identity, "recipe") & 0x7fffffff,
		"surfaceOnly": true,
	}


static func reservation_fits_region(region: Vector2i, reservation: Rect2i) -> bool:
	if not _valid_region(region) or reservation.size.x <= 0 or reservation.size.y <= 0:
		return false
	var allowed := Rect2i(region * REGION_CELLS + Vector2i.ONE * REGION_GUARD_CELLS, Vector2i.ONE * (REGION_CELLS - REGION_GUARD_CELLS * 2))
	# Half-open bounds, including the caller's entire blend apron/clearance.
	# Disjoint region interiors remove query-order-dependent overlap arbitration.
	# Widen end arithmetic before adding: Rect2i.end can wrap at int32 bounds.
	return (
		int(reservation.position.x) >= int(allowed.position.x)
		and int(reservation.position.y) >= int(allowed.position.y)
		and int(reservation.position.x) + int(reservation.size.x) <= int(allowed.position.x) + int(allowed.size.x)
		and int(reservation.position.y) + int(reservation.size.y) <= int(allowed.position.y) + int(allowed.size.y)
	)


static func allows_surface_biome(biome: String) -> bool:
	# Do not add a forest/temperate whitelist: all land biomes are eligible.
	return not biome.is_empty() and biome not in ["ocean", "cave", "underground", "deep_underground", "underground_air", "town"]


static func _channel(identity: String, channel: String) -> int:
	return (identity + ":" + channel).sha256_text().substr(0, 8).hex_to_int()


static func _valid_region(region: Vector2i) -> bool:
	return region.x >= MIN_REGION_COORD and region.x <= MAX_REGION_COORD and region.y >= MIN_REGION_COORD and region.y <= MAX_REGION_COORD

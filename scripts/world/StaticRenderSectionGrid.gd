extends RefCounted
class_name StaticRenderSectionGrid

const TerrainRuntime = preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
const SpatialDependencies = preload("res://scripts/buildings/BuildingSpatialDependencies.gd")

## Static render pages are smaller than streamed chunk owners. This first
## spatial contract aligns candidate pages with the terrain mesher's 16-cell
## section grid while leaving visual sizing subject to runtime profiling.
const CELL_SIZE_METERS: float = TerrainRuntime.CELL
const SECTION_SIZE_CELLS: int = TerrainRuntime.SECTION_SIZE
const SECTION_SIZE_METERS := CELL_SIZE_METERS * float(SECTION_SIZE_CELLS)
const LOGICAL_OWNER_SIZE_CELLS: int = int(SpatialDependencies.OWNER_SIZE / CELL_SIZE_METERS)
const STREAM_CHUNK_SIZE_CELLS: int = TerrainRuntime.GAME_CHUNK_SIZE
const STREAM_CHUNK_SIZE_METERS := CELL_SIZE_METERS * float(STREAM_CHUNK_SIZE_CELLS)


static func key_for_cell(cell: Vector3i) -> Vector3i:
	return Vector3i(
		floori(float(cell.x) / float(SECTION_SIZE_CELLS)),
		floori(float(cell.y) / float(SECTION_SIZE_CELLS)),
		floori(float(cell.z) / float(SECTION_SIZE_CELLS)))


static func key_for_world_position(position: Vector3) -> Vector3i:
	return Vector3i(
		_floor_partition_coordinate(position.x,SECTION_SIZE_METERS),
		_floor_partition_coordinate(position.y,SECTION_SIZE_METERS),
		_floor_partition_coordinate(position.z,SECTION_SIZE_METERS))


static func origin_for_key(key: Vector3i) -> Vector3:
	return Vector3(key) * SECTION_SIZE_METERS


static func chunk_key_for_section(key: Vector3i) -> Vector2i:
	return chunk_key_for_world_position(origin_for_key(key))


static func stream_chunk_keys_intersecting_section(key: Vector3i) -> Array[Vector2i]:
	var origin := origin_for_key(key)
	var end := origin + Vector3.ONE * SECTION_SIZE_METERS
	var low_x := _floor_partition_coordinate(origin.x, STREAM_CHUNK_SIZE_METERS)
	var low_z := _floor_partition_coordinate(origin.z, STREAM_CHUNK_SIZE_METERS)
	var high_x := _ceil_partition_coordinate(end.x, STREAM_CHUNK_SIZE_METERS) - 1
	var high_z := _ceil_partition_coordinate(end.z, STREAM_CHUNK_SIZE_METERS) - 1
	var result: Array[Vector2i] = []
	for z in range(low_z, high_z + 1):
		for x in range(low_x, high_x + 1):
			result.append(Vector2i(x, z))
	return result


static func logical_owner_cell_for_world_position(position: Vector3) -> Vector2i:
	return Vector2i(_floor_partition_coordinate(position.x, SpatialDependencies.OWNER_SIZE),
		_floor_partition_coordinate(position.z, SpatialDependencies.OWNER_SIZE))


static func chunk_key_for_world_position(position: Vector3) -> Vector2i:
	return Vector2i(_floor_partition_coordinate(position.x,STREAM_CHUNK_SIZE_METERS),
		_floor_partition_coordinate(position.z,STREAM_CHUNK_SIZE_METERS))


static func keys_intersecting_bounds(bounds: AABB) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	if not bounds.position.is_finite() or not bounds.size.is_finite() \
			or bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		return result
	var low := Vector3i(
		_floor_partition_coordinate(bounds.position.x,SECTION_SIZE_METERS),
		_floor_partition_coordinate(bounds.position.y,SECTION_SIZE_METERS),
		_floor_partition_coordinate(bounds.position.z,SECTION_SIZE_METERS))
	# Bounds are half-open: a part ending on a section plane does not depend on
	# the section beyond that plane. ceil-minus-one remains correct at negatives.
	var high := Vector3i(
		_ceil_partition_coordinate(bounds.end.x,SECTION_SIZE_METERS) - 1,
		_ceil_partition_coordinate(bounds.end.y,SECTION_SIZE_METERS) - 1,
		_ceil_partition_coordinate(bounds.end.z,SECTION_SIZE_METERS) - 1)
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				result.append(Vector3i(x, y, z))
	return result


static func _floor_partition_coordinate(coordinate: float, grid_size_meters: float) -> int:
	var quotient := coordinate / grid_size_meters
	var nearest := roundf(quotient)
	if absf(quotient - nearest) <= 0.000001:
		quotient = nearest
	return floori(quotient)


static func _ceil_partition_coordinate(coordinate: float, grid_size_meters: float) -> int:
	var quotient := coordinate / grid_size_meters
	var nearest := roundf(quotient)
	if absf(quotient - nearest) <= 0.000001:
		quotient = nearest
	return ceili(quotient)

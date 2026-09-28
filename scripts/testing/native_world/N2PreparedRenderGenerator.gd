extends VoxelGeneratorScript
class_name N2PreparedRenderGenerator

const CELL := 1.35
const SAMPLE_MIN := Vector3i(-49, -17, -17)
const SAMPLE_MAX_EXCLUSIVE := Vector3i(-14, 34, 2)
const SAMPLE_SIZE := Vector3i(35, 51, 19)
const SAMPLE_COUNT := 33915

var _sdf_values := PackedFloat32Array()
var _indices := PackedByteArray()
var _data5 := PackedByteArray()
var _required_gap := ""
var _generated_block_count := 0
var _required_sample_write_count := 0
var _stats_mutex := Mutex.new()


func setup(render: Dictionary) -> Dictionary:
	_required_gap = ""
	_sdf_values = render.get("sdfValues", PackedFloat32Array())
	_indices = render.get("indices", PackedByteArray())
	_data5 = render.get("data5", PackedByteArray())
	if not _sdf_values is PackedFloat32Array or not _indices is PackedByteArray or not _data5 is PackedByteArray:
		return {"ok": false, "reason": "native_render_column_type_invalid"}
	if _sdf_values.size() != SAMPLE_COUNT or _indices.size() != SAMPLE_COUNT or _data5.size() != SAMPLE_COUNT:
		return {"ok": false, "reason": "native_render_sample_count_mismatch", "expected": SAMPLE_COUNT,
			"actual": {"sdf": _sdf_values.size(), "indices": _indices.size(), "data5": _data5.size()}}
	return {"ok": true, "sampleCount": SAMPLE_COUNT}


func _get_used_channels_mask() -> int:
	return (1 << VoxelBuffer.CHANNEL_SDF) | (1 << VoxelBuffer.CHANNEL_INDICES) | (1 << VoxelBuffer.CHANNEL_DATA5)


func _generate_block(out_buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	out_buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	out_buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	out_buffer.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	var size := out_buffer.get_size()
	var step := 1 << maxi(lod, 0)
	var required_writes := 0
	for z in range(size.z):
		for y in range(size.y):
			for x in range(size.x):
				var cell := origin_in_voxels + Vector3i(x, y, z) * step
				var ordinal := _ordinal(cell)
				if ordinal >= 0:
					required_writes += 1
					out_buffer.set_voxel_f(float(_sdf_values[ordinal]), x, y, z, VoxelBuffer.CHANNEL_SDF)
					out_buffer.set_voxel(int(_indices[ordinal]), x, y, z, VoxelBuffer.CHANNEL_INDICES)
					out_buffer.set_voxel(int(_data5[ordinal]), x, y, z, VoxelBuffer.CHANNEL_DATA5)
				elif _inside_required_snapshot(cell):
					var missing_key := _key(cell)
					_stats_mutex.lock()
					_required_gap = missing_key
					_stats_mutex.unlock()
					push_error("N2 required render sample missing: " + missing_key)
					out_buffer.set_voxel_f(1.0, x, y, z, VoxelBuffer.CHANNEL_SDF)
					out_buffer.set_voxel(0, x, y, z, VoxelBuffer.CHANNEL_INDICES)
					out_buffer.set_voxel(0, x, y, z, VoxelBuffer.CHANNEL_DATA5)
				else:
					# Voxel Tools requests blocks outside the bounded fixture snapshot.
					# Those cells are diagnostic-only and are never part of N2 parity.
					out_buffer.set_voxel_f(1.0, x, y, z, VoxelBuffer.CHANNEL_SDF)
					out_buffer.set_voxel(0, x, y, z, VoxelBuffer.CHANNEL_INDICES)
					out_buffer.set_voxel(0, x, y, z, VoxelBuffer.CHANNEL_DATA5)
	out_buffer.compress_uniform_channels()
	_stats_mutex.lock()
	_generated_block_count += 1
	_required_sample_write_count += required_writes
	_stats_mutex.unlock()


func _key(cell: Vector3i) -> String:
	return "%d,%d,%d" % [cell.x, cell.y, cell.z]


func required_gap() -> String:
	_stats_mutex.lock()
	var result := _required_gap
	_stats_mutex.unlock()
	return result


func consumption_stats() -> Dictionary:
	_stats_mutex.lock()
	var result := {"generatedBlockCount": _generated_block_count,
		"requiredSampleWriteCount": _required_sample_write_count}
	_stats_mutex.unlock()
	return result


func _inside_required_snapshot(cell: Vector3i) -> bool:
	return cell.x >= SAMPLE_MIN.x and cell.y >= SAMPLE_MIN.y and cell.z >= SAMPLE_MIN.z \
		and cell.x < SAMPLE_MAX_EXCLUSIVE.x and cell.y < SAMPLE_MAX_EXCLUSIVE.y and cell.z < SAMPLE_MAX_EXCLUSIVE.z


func _ordinal(cell: Vector3i) -> int:
	if not _inside_required_snapshot(cell): return -1
	return (cell.x - SAMPLE_MIN.x) + SAMPLE_SIZE.x * (cell.z - SAMPLE_MIN.z) \
		+ SAMPLE_SIZE.x * SAMPLE_SIZE.z * (cell.y - SAMPLE_MIN.y)

extends RefCounted
class_name NativeTerrainEditRepublicationPlan

## Maps a committed native cell transaction to the physical VoxelTerrain
## replacement set. This is planning only: installed data and collision remain
## old until the caller obtains a new generation-specific physics receipt.
const BLOCK_SIZE := 16
const MAX_CHANGED_BLOCKS := 64
const MAX_INPUT_BLOCKS := 4096

static func for_committed_cells(changed_cells: Array[Vector3i], affected_sections: Array) -> Dictionary:
	if changed_cells.is_empty() or affected_sections.is_empty():
		return {"status":"failed", "reason":"committed_edit_cells_required"}
	var receipt_sections := {}
	for section in affected_sections:
		if not section is Vector3i:
			return {"status":"failed", "reason":"invalid_affected_section"}
		receipt_sections[section] = true
	var replacement_set := {}
	for cell in changed_cells:
		var block := Vector3i(floori(float(cell.x) / BLOCK_SIZE),
			floori(float(cell.y) / BLOCK_SIZE), floori(float(cell.z) / BLOCK_SIZE))
		if not receipt_sections.has(block):
			return {"status":"failed", "reason":"changed_cell_absent_from_native_receipt"}
		replacement_set[block] = true
		if replacement_set.size() > MAX_CHANGED_BLOCKS:
			return {"status":"failed", "reason":"changed_block_limit"}
	var mesh_set := {}
	var input_set := {}
	for replacement: Vector3i in replacement_set:
		for z in range(replacement.z - 1, replacement.z + 2):
			for y in range(replacement.y - 1, replacement.y + 2):
				for x in range(replacement.x - 1, replacement.x + 2):
					var mesh_block := Vector3i(x, y, z)
					mesh_set[mesh_block] = true
					for input_z in range(z - 1, z + 2):
						for input_y in range(y - 1, y + 2):
							for input_x in range(x - 1, x + 2):
								input_set[Vector3i(input_x, input_y, input_z)] = true
								if input_set.size() > MAX_INPUT_BLOCKS:
									return {"status":"failed", "reason":"input_block_limit"}
	return {"status":"ready", "replacementDataBlocks":_sorted(replacement_set),
		"affectedMeshBlocks":_sorted(mesh_set), "requiredInputBlocks":_sorted(input_set)}

static func _sorted(keys: Dictionary) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for key: Vector3i in keys:
		result.append(key)
	result.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x))))
	return result

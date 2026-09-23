extends RefCounted
class_name NativeTerrainEditRepublicationPlan

## Maps a committed native cell transaction to the physical VoxelTerrain
## replacement set. This is planning only: installed data and collision remain
## old until the caller obtains a new generation-specific physics receipt.
const BLOCK_SIZE := 16
const MAX_CHANGED_BLOCKS := 64
const MAX_INPUT_BLOCKS := 4096
const Footprint = preload("res://scripts/terrain/NativeVoxelBlockDemandFootprint.gd")

static func for_committed_cells(changed_cells: Array[Vector3i], affected_sections: Array,
		native_revision := 0, source_epoch := "") -> Dictionary:
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
	var meshes := _sorted(mesh_set)
	var windows: Array[Dictionary] = []
	var current: Array[Vector3i] = []
	for mesh in meshes:
		var next := current.duplicate()
		next.append(mesh)
		var footprint: Dictionary = Footprint.data_blocks_for_mesh_blocks(next)
		if footprint.get("status") != "ready":
			if current.is_empty():
				return {"status":"failed", "reason":"single_mesh_footprint_unadmittable"}
			windows.append({"meshBlocks":current, "dataBlocks":Footprint.data_blocks_for_mesh_blocks(current).blocks})
			current = [mesh]
			footprint = Footprint.data_blocks_for_mesh_blocks(current)
			if footprint.get("status") != "ready":
				return {"status":"failed", "reason":"single_mesh_footprint_unadmittable"}
		else:
			current = next
	if not current.is_empty():
		windows.append({"meshBlocks":current, "dataBlocks":Footprint.data_blocks_for_mesh_blocks(current).blocks})
	var identity := "%s:%d:%s" % [source_epoch, native_revision,
		str(_sorted(replacement_set)).sha256_text()]
	for index in range(windows.size()):
		windows[index]["index"] = index
		windows[index]["token"] = "%s:%d" % [identity, index]
	return {"status":"ready", "replacementDataBlocks":_sorted(replacement_set),
		"affectedMeshBlocks":meshes, "requiredInputBlocks":_sorted(input_set),
		"subwindows":windows, "barrier":{"identity":identity,
			"nativeRevision":native_revision, "sourceEpoch":source_epoch,
			"subwindowCount":windows.size(), "activationEligible":native_revision > 0 and source_epoch != ""}}

## Only receipts from generation-specific physical publication may be passed
## here. Planning cannot itself prove an engine collider was replaced.
static func publication_barrier_status(plan: Dictionary, receipts: Array) -> Dictionary:
	if plan.get("status") != "ready":
		return {"status":"failed", "reason":"edit_plan_not_ready"}
	var barrier: Dictionary = plan.get("barrier", {})
	if not bool(barrier.get("activationEligible", false)):
		return {"status":"failed", "reason":"revision_epoch_required"}
	var windows: Array = plan.get("subwindows", [])
	if windows.size() != int(barrier.get("subwindowCount", -1)):
		return {"status":"failed", "reason":"subwindow_count_mismatch"}
	var seen := {}
	for receipt in receipts:
		if not receipt is Dictionary:
			return {"status":"failed", "reason":"invalid_physical_receipt"}
		var index := int(receipt.get("index", -1))
		if index < 0 or index >= windows.size() or seen.has(index):
			return {"status":"failed", "reason":"duplicate_or_unknown_subwindow"}
		if receipt.get("token") != windows[index].get("token") \
				or int(receipt.get("nativeRevision", -1)) != int(barrier.nativeRevision) \
				or receipt.get("status") != "ready":
			return {"status":"failed", "reason":"stale_or_unproven_physical_receipt"}
		var expected_meshes: Array = windows[index].get("meshBlocks", [])
		var block_receipts: Array = receipt.get("meshBlockReceipts", [])
		if block_receipts.size() != expected_meshes.size():
			return {"status":"failed", "reason":"mesh_physics_receipts_incomplete"}
		var proven := {}
		for block_receipt in block_receipts:
			if not block_receipt is Dictionary:
				return {"status":"failed", "reason":"invalid_mesh_physics_receipt"}
			var block = block_receipt.get("block", null)
			if not block is Vector3i or not expected_meshes.has(block) or proven.has(block) \
					or not bool(block_receipt.get("physicalReady", false)) \
					or int(block_receipt.get("generation", 0)) <= 0:
				return {"status":"failed", "reason":"stale_or_unproven_mesh_physics_receipt"}
			proven[block] = true
		seen[index] = true
	if seen.size() != windows.size():
		return {"status":"pending", "reason":"subwindows_not_physically_ready",
			"readyCount":seen.size(), "requiredCount":windows.size(),
			"barrierIdentity":barrier.identity}
	return {"status":"ready", "readyCount":seen.size(),
		"requiredCount":windows.size(), "barrierIdentity":barrier.identity}

static func _sorted(keys: Dictionary) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for key: Vector3i in keys:
		result.append(key)
	result.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x))))
	return result

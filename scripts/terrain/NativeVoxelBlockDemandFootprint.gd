extends RefCounted
class_name NativeVoxelBlockDemandFootprint

## Voxel Tools Transvoxel meshing reads adjacent data blocks. A mesh block is
## not publishable merely because its own data block was inserted. This helper
## returns the complete one-block input halo for a bounded set of mesh blocks.
const MAX_MESH_BLOCKS := 64
# The native retained queue currently holds at most 128 block keys. A single
# admitted footprint must fit that cap before other consumers compete for it.
const MAX_DATA_BLOCKS := 128

static func data_blocks_for_mesh_blocks(mesh_blocks: Array[Vector3i]) -> Dictionary:
	if mesh_blocks.is_empty() or mesh_blocks.size() > MAX_MESH_BLOCKS:
		return {"status":"failed", "reason":"mesh_block_demand_limit"}
	var unique := {}
	for mesh_block in mesh_blocks:
		for z in range(mesh_block.z - 1, mesh_block.z + 2):
			for y in range(mesh_block.y - 1, mesh_block.y + 2):
				for x in range(mesh_block.x - 1, mesh_block.x + 2):
					unique[Vector3i(x, y, z)] = true
					if unique.size() > MAX_DATA_BLOCKS:
						return {"status":"failed", "reason":"data_block_demand_limit"}
	var ordered: Array[Vector3i] = []
	for block: Vector3i in unique.keys():
		ordered.append(block)
	ordered.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x))))
	return {"status":"ready", "blocks":ordered}

extends VoxelGeneratorScript
class_name VoxelTerrainGenerator

const WORLD_GENERATION_SCRIPT := preload("res://scripts/WorldGenerationSystem.gd")

const CELL := 1.35
const MATERIAL_IDS := {
	"air": 0,
	"grass": 1,
	"dirt": 2,
	"stone": 3,
	"sand": 4,
	"snow": 5,
	"deepStone": 6,
	"bedrock": 7,
	"clay": 8,
	"gravel": 9,
	"coalOre": 10,
	"ironOre": 11,
	"crystalOre": 12,
	"copperOre": 13,
	"mud": 14,
	"water": 15
}

var context_template

func setup(context) -> void:
	context_template = context

func _get_used_channels_mask() -> int:
	return (1 << VoxelBuffer.CHANNEL_SDF) | (1 << VoxelBuffer.CHANNEL_INDICES) | (1 << VoxelBuffer.CHANNEL_DATA5)

func _generate_block(out_buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	if context_template == null:
		out_buffer.fill_f(1.0, VoxelBuffer.CHANNEL_SDF)
		return
	var context = context_template.clone_for_worker()
	var world_generation = WORLD_GENERATION_SCRIPT.new()
	world_generation.setup(context)
	context.set_generator(world_generation)
	out_buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	out_buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	out_buffer.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	var size := out_buffer.get_size()
	var voxel_scale := 1 << maxi(0, lod)
	for z in range(size.z):
		for y in range(size.y):
			for x in range(size.x):
				var cell := origin_in_voxels + Vector3i(x, y, z) * voxel_scale
				var position := Vector3(cell) * CELL
				var saved_edit: Dictionary = context.initial_terrain_edits.get(cell, {}) if context.initial_terrain_edits.get(cell, {}) is Dictionary else {}
				var density := -CELL
				var material_name := "air"
				if not saved_edit.is_empty():
					density = float(saved_edit.get("density", -CELL)) / float(voxel_scale)
					material_name = String(saved_edit.get("material", "air"))
				else:
					# The VoxelTerrain backend only consumes density and the final solid
					# material. Building the full gameplay sample dictionary here also
					# computed biome/material fields that were immediately discarded and
					# then recomputed by material_for_generated_density.
					var base_surface_y := world_generation.terrain_reference_surface_y_at(position)
					var surface_y := world_generation.terrain_deformed_surface_y_at(position)
					density = world_generation.density_from_components(position, surface_y, base_surface_y) / float(voxel_scale)
					material_name = material_for_generated_density(world_generation, cell, position, base_surface_y, density)
				var material_id := int(MATERIAL_IDS.get(material_name, MATERIAL_IDS["stone"]))
				out_buffer.set_voxel_f(-density / CELL, x, y, z, VoxelBuffer.CHANNEL_SDF)
				out_buffer.set_voxel(material_id, x, y, z, VoxelBuffer.CHANNEL_INDICES)
				out_buffer.set_voxel(material_id, x, y, z, VoxelBuffer.CHANNEL_DATA5)
	out_buffer.compress_uniform_channels()

func material_for_generated_density(world_generation, cell: Vector3i, position: Vector3, base_surface_y: float, density: float) -> String:
	if density < 0.0:
		return "air"
	if cell.y <= int(world_generation.world_bottom_cell_y()) + 1:
		return "bedrock"
	var surface_biome := String(world_generation.surface_biome_for_cell3(Vector3i(cell.x, 0, cell.z)))
	var depth := maxf(0.0, base_surface_y - position.y)
	return String(world_generation.generated_solid_material_for_cell(cell, base_surface_y, surface_biome, depth))

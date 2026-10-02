extends SceneTree

const CONTEXT := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const GENERATION := preload("res://scripts/WorldGenerationSystem.gd")
const WORKER := preload("res://scripts/terrain/VoxelTerrainGenerator.gd")
const CELL := 1.35
const BLOCK_SIZE := Vector3i(16, 16, 16)
const MAX_MISMATCHES := 8


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var rows: Array[Dictionary] = []
	for seed_text in ["atlas-1492", "atlas-75216765", "terrain-parity-4081"]:
		for block in [
			{"name": "surface", "origin": Vector3i(0, 4, 0), "lod": 0},
			{"name": "underground", "origin": Vector3i(32, -24, -16), "lod": 0},
			{"name": "deep_lod", "origin": Vector3i(-32, -60, 24), "lod": 1},
		]:
			rows.append(compare_block(seed_text, block))
	var passed := rows.all(func(row: Dictionary) -> bool:
		return row.passed and row.voxels == 4096 and row.savedEditVoxels == 2)
	var report := {"schema": "voxel-generator-exact-output-contract/v1",
		"evidenceLevel": "synthetic_service_contract", "liveGameplayAcceptance": false,
		"passed": passed, "complete": true, "blocks": rows}
	var report_path := OS.get_environment("VOXEL_GENERATOR_EXACT_OUTPUT_REPORT")
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path(
			"res://artifacts/terrain/voxel-generator-exact-output-report.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write voxel generator parity report: " + report_path)
		quit(1)
		return
	file.store_string(JSON.stringify(report, "  "))
	quit(0 if passed else 1)


func compare_block(seed_text: String, block: Dictionary) -> Dictionary:
	var origin: Vector3i = block.origin
	var lod: int = block.lod
	var voxel_scale := 1 << lod
	var context = CONTEXT.new()
	context.seed_text = seed_text
	context.seed_hash = context.hash_string(seed_text)
	context.setup_noise()
	# This is the durable edit snapshot consumed by the native worker context.
	# Exercise both a removed cell and a replacement solid at each block origin.
	context.initial_terrain_edits[origin + Vector3i(1, 1, 1) * voxel_scale] = {
		"density": -CELL, "material": "air"}
	context.initial_terrain_edits[origin + Vector3i(6, 5, 3) * voxel_scale] = {
		"density": CELL * 2.0, "material": "copperOre"}
	var worker = WORKER.new()
	worker.setup(context)
	var actual := make_buffer()
	var worker_started := Time.get_ticks_usec()
	worker._generate_block(actual, origin, lod)
	var worker_usec := Time.get_ticks_usec() - worker_started
	var reference := make_buffer()
	var direct_context = context.clone_for_worker()
	var world = GENERATION.new()
	world.setup(direct_context)
	direct_context.set_generator(world)
	var material_worker = WORKER.new()
	var reference_started := Time.get_ticks_usec()
	var saved_edit_voxels := fill_direct_reference(reference, direct_context, world,
		material_worker, origin, lod)
	var reference_usec := Time.get_ticks_usec() - reference_started
	var mismatch_count := 0
	var mismatches: Array[Dictionary] = []
	var material_ids: Dictionary = {}
	for z in BLOCK_SIZE.z:
		for y in BLOCK_SIZE.y:
			for x in BLOCK_SIZE.x:
				var at := Vector3i(x, y, z)
				var actual_sdf := actual.get_voxel_f(x, y, z, VoxelBuffer.CHANNEL_SDF)
				var reference_sdf := reference.get_voxel_f(x, y, z, VoxelBuffer.CHANNEL_SDF)
				var actual_indices := actual.get_voxel(x, y, z, VoxelBuffer.CHANNEL_INDICES)
				var reference_indices := reference.get_voxel(x, y, z, VoxelBuffer.CHANNEL_INDICES)
				var actual_data5 := actual.get_voxel(x, y, z, VoxelBuffer.CHANNEL_DATA5)
				var reference_data5 := reference.get_voxel(x, y, z, VoxelBuffer.CHANNEL_DATA5)
				material_ids[actual_indices] = true
				if actual_sdf != reference_sdf or actual_indices != reference_indices \
						or actual_data5 != reference_data5:
					mismatch_count += 1
					if mismatches.size() < MAX_MISMATCHES:
						mismatches.append({"cell": origin + at * voxel_scale,
							"actualSdf": actual_sdf, "referenceSdf": reference_sdf,
							"actualIndices": actual_indices, "referenceIndices": reference_indices,
							"actualData5": actual_data5, "referenceData5": reference_data5})
	return {"seed": seed_text, "block": block.name, "origin": origin, "lod": lod,
		"voxels": BLOCK_SIZE.x * BLOCK_SIZE.y * BLOCK_SIZE.z,
		"savedEditVoxels": saved_edit_voxels, "materialCount": material_ids.size(),
		"workerUsec": worker_usec, "referenceUsec": reference_usec,
		"mismatchCount": mismatch_count, "mismatches": mismatches,
		"passed": mismatch_count == 0}


func make_buffer() -> VoxelBuffer:
	var buffer := VoxelBuffer.new()
	buffer.create(BLOCK_SIZE.x, BLOCK_SIZE.y, BLOCK_SIZE.z)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	return buffer


func fill_direct_reference(buffer: VoxelBuffer, context, world, material_worker,
		origin: Vector3i, lod: int) -> int:
	var voxel_scale := 1 << lod
	var saved_edit_voxels := 0
	for z in BLOCK_SIZE.z:
		for y in BLOCK_SIZE.y:
			for x in BLOCK_SIZE.x:
				var cell := origin + Vector3i(x, y, z) * voxel_scale
				var saved_edit: Dictionary = context.initial_terrain_edits.get(cell, {})
				var density: float
				var material_name: String
				if not saved_edit.is_empty():
					saved_edit_voxels += 1
					density = float(saved_edit.get("density", -CELL)) / float(voxel_scale)
					material_name = String(saved_edit.get("material", "air"))
				else:
					var position := Vector3(cell) * CELL
					# This is the prior direct per-voxel loop, without the worker's
					# local x/z height and biome caches.
					var base_surface_y: float = world.terrain_reference_surface_y_at(position)
					var surface_y: float = world.terrain_deformed_surface_y_at(position)
					density = world.density_from_components(position, surface_y,
						base_surface_y) / float(voxel_scale)
					material_name = material_worker.material_for_generated_density(
						world, cell, position, base_surface_y, density)
				var material_id := int(WORKER.MATERIAL_IDS.get(material_name,
					WORKER.MATERIAL_IDS["stone"]))
				buffer.set_voxel_f(-density / CELL, x, y, z, VoxelBuffer.CHANNEL_SDF)
				buffer.set_voxel(material_id, x, y, z, VoxelBuffer.CHANNEL_INDICES)
				buffer.set_voxel(material_id, x, y, z, VoxelBuffer.CHANNEL_DATA5)
	buffer.compress_uniform_channels()
	return saved_edit_voxels

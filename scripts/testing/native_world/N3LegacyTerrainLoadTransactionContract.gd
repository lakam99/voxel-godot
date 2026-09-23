extends SceneTree

const MAIN := preload("res://scripts/Main.gd")
const STRUCTURES := preload("res://scripts/StructureSystem.gd")
const WORLD := preload("res://scripts/WorldGenerationSystem.gd")
const SOURCE := preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const CONVERTER := preload("res://scripts/terrain/NativeV2LegacyTerrainConverter.gd")
const TRANSACTION := preload("res://scripts/terrain/NativeTerrainLoadTransaction.gd")
const RUNTIME_OWNER := preload("res://scripts/terrain/NativeTerrainRuntimeOwner.gd")

var failures: Array[String] = []

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func _init() -> void:
	call_deferred("run")

func _semantic_cells(volume: Dictionary) -> Dictionary:
	var result := {}
	for section in volume.get("sections", []):
		for record in section.get("cells", []):
			var state: Dictionary = record.get("state", {})
			result[JSON.stringify(record.get("cell", []))] = {
				"material":state.get("material"), "biome":state.get("biome"),
				"solid":state.get("solid"), "density":state.get("density"),
				"fluid":state.get("fluid"), "metadata":state.get("metadata"),
				"blockId":state.get("blockId"), "editReason":state.get("editReason")}
	return result

func _make_terrain(main):
	var terrain = ClassDB.instantiate("VoxelTerrain")
	terrain.automatic_loading_enabled = false
	terrain.mesh_block_size = 16
	terrain.scale = Vector3.ONE * main.CELL
	var format = ClassDB.instantiate("VoxelFormat")
	format.set_channel_depth(ClassDB.class_get_integer_constant("VoxelBuffer", "CHANNEL_SDF"),
		ClassDB.class_get_integer_constant("VoxelBuffer", "DEPTH_16_BIT"))
	format.set_channel_depth(ClassDB.class_get_integer_constant("VoxelBuffer", "CHANNEL_INDICES"),
		ClassDB.class_get_integer_constant("VoxelBuffer", "DEPTH_8_BIT"))
	format.set_channel_depth(ClassDB.class_get_integer_constant("VoxelBuffer", "CHANNEL_DATA5"),
		ClassDB.class_get_integer_constant("VoxelBuffer", "DEPTH_8_BIT"))
	terrain.set_format(format)
	var mesher = ClassDB.instantiate("VoxelMesherTransvoxel")
	mesher.texturing_mode = ClassDB.class_get_integer_constant("VoxelMesherTransvoxel", "TEXTURES_SINGLE_S4")
	mesher.transitions_enabled = false
	terrain.mesher = mesher
	return terrain

func _drive_converter(converter, max_frames := 300) -> Dictionary:
	var result := {}
	for _frame in range(max_frames):
		result = converter.advance()
		if result.get("status") != "pending": return result
		await process_frame
	return {"status":"timeout", "reason":"legacy_conversion_contract_timeout"}

func _drive_candidate(transaction, max_frames := 1200) -> Dictionary:
	for _frame in range(max_frames):
		var result: Dictionary = transaction.advance()
		if result.get("reason") == "candidate_requires_explicit_commit" or result.get("status") == "failed":
			return result
		await process_frame
	return {"status":"timeout", "reason":"legacy_candidate_contract_timeout"}

func run() -> void:
	var started_usec := Time.get_ticks_usec()
	var main = MAIN.new()
	main.seed_text = "n3-legacy-load-transaction-parity"
	main.seed_hash = main.hash_string(main.seed_text)
	main.setup_noise()
	main.structure_system = STRUCTURES.new()
	main.structure_system.citadel_terrain_admission.configure(main.seed_text, {}, {
		"regionCells":main.STRUCTURE_REGION_CELLS,
		"spawnChance":float(main.STRUCTURE_SPAWN_CHANCE)})
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	var terrain_root := Node3D.new()
	root.add_child(terrain_root)
	var terrain = _make_terrain(main)
	terrain_root.add_child(terrain)

	var column := Vector3i(-17, 0, -1)
	var old_surface := float(main.world_generation_system.surface_y_for_cell(column))
	var edited_surface := old_surface - 2.0 * float(main.CELL)
	var legacy_save := {"version":2, "seed":main.seed_text,
		"terrain":[{"x":column.x, "z":column.z, "surfaceY":edited_surface}]}
	var converter = CONVERTER.new()
	var conversion_started: Dictionary = converter.setup(main, legacy_save)
	var converted: Dictionary = await _drive_converter(converter)
	var resolved: Dictionary = converter.resolved_save()
	var canonical_save: Dictionary = resolved.get("save", {})
	check(conversion_started.get("status") == "ready"
		and converted.get("status") == "ready"
		and resolved.get("status") == "ready"
		and canonical_save.get("terrain", []) == [],
		"legacy v2 surface column converts into a canonical volume-backed save")

	# Keep the old restore implementation as the parity oracle for this one
	# historical negative-coordinate excavation.
	main.restore_volume_edits(legacy_save.terrain)
	var restored_volume: Dictionary = main.world_generation_system.save_terrain_volume_deltas()
	var converted_volume: Dictionary = converted.get("terrainVolume", {})
	check(converted_volume == restored_volume
		and _semantic_cells(converted_volume) == _semantic_cells(restored_volume),
		"native column conversion exactly preserves script restore cells and volume revisions")
	var converted_source: Dictionary = SOURCE.from_main_with_v2_save(main, canonical_save)
	check(converted_source.get("status") == "ready"
		and converted_source.get("request", {}).get("terrainVolume") == restored_volume,
		"canonicalized legacy save is admitted by the ordinary native v2 source path")

	# Build an exclusive source lease over the canonicalized save, then exercise
	# the same staged candidate/identity commit/backend transfer used by Continue.
	var leased_source: Dictionary = SOURCE.from_main_with_v2_save_snapshot(main, canonical_save)
	var transaction = TRANSACTION.new()
	var begin_result: Dictionary = transaction.start(leased_source.get("request", {}), 32,
		leased_source.get("snapshotOwner"))
	var candidate: Dictionary = await _drive_candidate(transaction)
	var identity: Dictionary = transaction.candidate_source_identity()
	var committed: Dictionary = transaction.commit(identity) if candidate.get("reason") == "candidate_requires_explicit_commit" else {}
	var owner = RUNTIME_OWNER.new()
	var adopted: Dictionary = owner.call("setup_from_committed_transaction", main, terrain,
		transaction, committed, 713, 10) if committed.get("status") == "ready" else {}
	var owner_volume: Dictionary = owner.export_terrain_volume_v2().get("terrainVolume", {})
	check(begin_result.get("status") == "pending"
		and candidate.get("reason") == "candidate_requires_explicit_commit"
		and committed.get("status") == "ready" and committed.get("committed") == true
		and adopted.get("status") == "ready"
		and transaction.snapshot().get("state") == "transferred"
		and owner_volume == restored_volume,
		"committed native runtime owner exports the exact historically restored volume")
	check(transaction.take_backend() == null,
		"committed legacy conversion backend is transferred to exactly one runtime owner")
	var stopped: Dictionary = owner.stop()
	for _frame in range(120):
		if stopped.get("status") == "ready": break
		await process_frame
		stopped = owner.drain_step()
	check(stopped.get("status") == "ready", "legacy transaction runtime owner drains cleanly")

	var report := {"schema":"n3-legacy-terrain-load-transaction/v1",
		"passed":failures.is_empty(), "productionCutover":false,
		"evidenceLevel":"focused legacy-v2 conversion, exact restore parity, staged native transaction and committed owner contract",
		"failures":failures,
		"metrics":{"elapsedUsec":Time.get_ticks_usec() - started_usec,
			"legacyColumns":1, "convertedCells":_semantic_cells(converted_volume).size()},
		"lifecycle":{"conversion":converted.get("status"),
			"canonicalTerrainCount":canonical_save.get("terrain", []).size(),
			"candidate":candidate.get("reason", candidate.get("status", "")),
			"commit":committed.get("status", ""), "ownerAdoption":adopted.get("status", ""),
			"transactionState":transaction.snapshot().get("state", ""),
			"exactRestoreParity":converted_volume == restored_volume,
			"ownerMatchesRestore":owner_volume == restored_volume},
		"doesNotProve":"No Main New Game/Continue wiring, loading responsiveness, authoritative collision readiness, or headed gameplay acceptance."}
	var report_path := OS.get_environment("VWB_LEGACY_LOAD_TRANSACTION_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	main.free()
	await process_frame
	quit(0 if report.passed else 1)

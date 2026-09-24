extends SceneTree

const MAIN := preload("res://scripts/Main.gd")
const STRUCTURES := preload("res://scripts/StructureSystem.gd")
const WORLD := preload("res://scripts/WorldGenerationSystem.gd")
const SOURCE := preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const CONVERTER := preload("res://scripts/terrain/NativeV2LegacyTerrainConverter.gd")
const TRANSACTION := preload("res://scripts/terrain/NativeTerrainLoadTransaction.gd")
const RUNTIME_OWNER := preload("res://scripts/terrain/NativeTerrainRuntimeOwner.gd")
const PRIVATE_STAGE := preload("res://scripts/terrain/NativePrivateMainLoadStage.gd")
const TITLE_MENU := preload("res://scripts/TitleMenu.gd")

class RejectedSaveStub:
	extends RefCounted
	var snapshot: Dictionary = {}
	func load(_seed: String) -> Dictionary:
		return snapshot

class FailedMainOwnerFixture:
	extends Node
	var startup_loading_failure_result := {"reason":"fixture_load_failed"}
	var startup_operation_active := false
	var runtime_loading_active := false
	var shutdown_requested := false
	var drain_allowed := false
	var drain_calls := 0
	var terrain_drain_calls := 0
	func drain_private_save_owners_before_free() -> Dictionary:
		drain_calls += 1
		return {"status":"ready", "drained":true} if drain_allowed else \
			{"status":"failed", "reason":"fixture_owner_busy", "ownerMustBeRetained":true}
	func wait_for_terrain_workers_before_quit() -> void:
		terrain_drain_calls += 1
	func wait_for_npc_navigation_before_quit() -> void:
		pass

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

func _drive_private_stage(stage, max_frames := 1200) -> Dictionary:
	for _frame in range(max_frames):
		var result: Dictionary = stage.advance()
		if result.get("status") != "pending": return result
		await process_frame
	return {"status":"timeout", "reason":"private_stage_contract_timeout"}

func _stop_private_stage(stage, max_frames := 300) -> Dictionary:
	var result: Dictionary = stage.stop()
	for _frame in range(max_frames):
		if result.get("drained", false) or result.get("status") == "failed": return result
		await process_frame
		result = stage.advance_stop()
	return {"status":"timeout", "reason":"private_stage_stop_timeout"}

func run() -> void:
	var started_usec := Time.get_ticks_usec()
	var main = MAIN.new()
	main.seed_text = "n3-legacy-load-transaction-parity"
	main.seed_hash = main.hash_string(main.seed_text)
	var rejected_save := {"version":2, "seed":"different-seed",
		"terrainVolume":{"schemaVersion":1, "sectionSize":16,
			"revision":1, "sections":[{"cells":[]}]}, "terrain":[]}
	var rejected_loader = RejectedSaveStub.new()
	rejected_loader.snapshot = rejected_save
	main.save_system = rejected_loader
	main.autosave_enabled = true
	main.startup_loading_active = true
	var rejected_load: bool = main.try_load_world()
	var rejected_owner_retained: bool = not rejected_load \
		and main._native_startup_save_snapshot == rejected_save
	check(rejected_owner_retained,
		"Main retains decoded file save before a rejected script restore")
	main._native_startup_save_snapshot = {}
	main.startup_loading_active = false
	main.save_system = null
	main.setup_noise()
	main.structure_system = STRUCTURES.new()
	main.structure_system.citadel_terrain_admission.configure(main.seed_text, {}, {
		"regionCells":main.STRUCTURE_REGION_CELLS,
		"spawnChance":float(main.STRUCTURE_SPAWN_CHANCE)})
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	var admission = main.structure_system.citadel_terrain_admission
	var unfinalized_towns: Dictionary = admission._towns.duplicate(true)
	var unfinalized_generation: int = int(admission._generation)
	var premature_private = PRIVATE_STAGE.new()
	var premature_result: Dictionary = premature_private.start(main)
	var premature_stopped: Dictionary = premature_private.stop()
	check(premature_result.get("reason") == "citadel_town_inputs_unfinalized"
		and premature_stopped.get("drained") == true
		and admission._towns == unfinalized_towns
		and not admission._town_inputs_finalized
		and int(admission._generation) == unfinalized_generation,
		"private stage failure leaves unfinalized production town inputs untouched")
	var shadow_decision: Dictionary = main.private_native_load_decision(premature_result, false)
	var authority_decision: Dictionary = main.private_native_load_decision(premature_result, true)
	check(shadow_decision.get("status") == "ready"
		and shadow_decision.get("shadowFailure") == true
		and shadow_decision.get("sourceAuthority") == "script_and_voxel_tools_unchanged"
		and main.startup_loading_failure_result.is_empty(),
		"failed private shadow candidate permits legacy gameplay authority")
	check(authority_decision.get("status") == "failed"
		and authority_decision.get("shadowFailure") == false,
		"future authoritative native candidate remains fail closed")
	var production_finalized: Dictionary = admission.finalize_town_inputs(main.town_region_cache)
	check(production_finalized.get("status") == "ready", "production owner finalizes town inputs explicitly")
	var finalized_towns: Dictionary = admission._towns.duplicate(true)
	var finalized_generation: int = int(admission._generation)
	var terrain_root := Node3D.new()
	root.add_child(terrain_root)
	var terrain = _make_terrain(main)
	terrain_root.add_child(terrain)

	var column := Vector3i(-17, 0, -1)
	var old_surface := float(main.world_generation_system.surface_y_for_cell(column))
	var edited_surface := old_surface - 2.0 * float(main.CELL)
	var legacy_save := {"version":2, "seed":main.seed_text,
		"terrain":[{"x":column.x, "z":column.z, "surfaceY":edited_surface}],
		"inventory":{"retainedNestedPayload":[1, 2, 3]}}
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
	check(legacy_save.terrain.size() == 1
		and is_same(canonical_save.inventory, legacy_save.inventory)
		and is_same(canonical_save.inventory.retainedNestedPayload,
			legacy_save.inventory.retainedNestedPayload),
		"conversion retains the decoded nested snapshot and changes only its top-level envelope")

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

	var private_new = PRIVATE_STAGE.new()
	var private_new_start: Dictionary = private_new.start(main)
	var private_new_ready: Dictionary = await _drive_private_stage(private_new)
	var private_new_retained: bool = private_new.snapshot().get("backendRetained") == true
	var private_new_stopped: Dictionary = await _stop_private_stage(private_new)
	check(private_new_start.get("status") == "pending"
		and private_new_ready.get("status") == "ready"
		and private_new_retained
		and private_new_stopped.get("drained") == true
		and int(private_new_stopped.get("releaseUsec", -1)) >= 0,
		"private New Game candidate commits and releases without publishing")
	var stale_private = PRIVATE_STAGE.new()
	var stale_started: Dictionary = stale_private.start(main)
	var original_seed: String = main.seed_text
	main.seed_text = "different-source-during-private-import"
	var stale_result: Dictionary = await _drive_private_stage(stale_private)
	main.seed_text = original_seed
	var stale_stopped: Dictionary = stale_private.stop()
	for _frame in range(120):
		if stale_stopped.get("drained", false): break
		stale_stopped = stale_private.advance_stop()
		await process_frame
	check(stale_started.get("status") == "pending"
		and stale_result.get("reason") == "private_source_changed_during_import"
		and stale_stopped.get("drained") == true
		and admission._towns == finalized_towns
		and admission._town_inputs_finalized
		and int(admission._generation) == finalized_generation,
		"private candidate rejects changed current source and drains without publishing")
	var private_continue = PRIVATE_STAGE.new()
	var private_continue_start: Dictionary = private_continue.start(main, canonical_save)
	var private_continue_ready: Dictionary = await _drive_private_stage(private_continue)
	var private_continue_stopped: Dictionary = await _stop_private_stage(private_continue)
	check(private_continue_start.get("status") == "pending"
		and private_continue_ready.get("status") == "ready"
		and private_continue_stopped.get("drained") == true,
		"private full-v2 Continue candidate imports and releases")
	var private_historical = PRIVATE_STAGE.new()
	var decoded_historical: Dictionary = JSON.parse_string(JSON.stringify(legacy_save))
	var private_historical_start: Dictionary = private_historical.start(main, decoded_historical)
	var private_historical_ready: Dictionary = await _drive_private_stage(private_historical)
	var historical_admitted := int(private_historical.snapshot().get("transaction", {}).get("recordsAdmitted", 0))
	var private_historical_stopped: Dictionary = await _stop_private_stage(private_historical)
	check(private_historical_start.get("reason") == "legacy_v2_conversion_pending"
		and private_historical_ready.get("status") == "ready"
		and historical_admitted > 0
		and private_historical_stopped.get("drained") == true,
		"private JSON-decoded historical-v2 Continue candidate converts and imports")
	var private_cancelled = PRIVATE_STAGE.new()
	var private_cancel_start: Dictionary = private_cancelled.start(main, canonical_save)
	var private_cancel_request: Dictionary = private_cancelled.stop()
	var private_cancel_result: Dictionary = private_cancel_request
	for _frame in range(120):
		if private_cancel_result.get("drained", false): break
		private_cancel_result = private_cancelled.advance_stop()
		await process_frame
	check(private_cancel_start.get("status") == "pending"
		and private_cancel_result.get("drained") == true
		and private_cancelled.snapshot().get("backendRetained") == false
		and admission._towns == finalized_towns
		and admission._town_inputs_finalized
		and int(admission._generation) == finalized_generation,
		"private candidate cancellation drains its retained native owner")
	var private_legacy_cancel = PRIVATE_STAGE.new()
	var legacy_cancel_start: Dictionary = private_legacy_cancel.start(main, legacy_save)
	var legacy_cancel_result: Dictionary = private_legacy_cancel.stop()
	check(legacy_cancel_start.get("status") == "pending"
		and legacy_cancel_result.get("drained") == true
		and private_legacy_cancel.snapshot().get("saveRetained") == false,
		"private historical conversion cancellation releases its decoded save")
	var menu = TITLE_MENU.new()
	root.add_child(menu)
	var failed_owner = FailedMainOwnerFixture.new()
	menu.add_child(failed_owner)
	var refused_free: bool = await menu.retire_failed_game_instances()
	var owner_retained: bool = not refused_free and is_instance_valid(failed_owner) \
		and not failed_owner.is_queued_for_deletion() \
		and failed_owner.drain_calls == 1 and failed_owner.terrain_drain_calls == 0
	failed_owner.drain_allowed = true
	var acknowledged_free: bool = await menu.retire_failed_game_instances()
	check(owner_retained and acknowledged_free and not is_instance_valid(failed_owner),
		"title menu refuses failed Main replacement until private save owner drains")
	menu.queue_free()
	await process_frame

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
		"privateStage":{"newGame":private_new_ready.get("status"),
			"continue":private_continue_ready.get("status"),
			"historicalContinue":private_historical_ready.get("status"),
			"newGameReleaseUsec":private_new_stopped.get("releaseUsec", -1),
			"continueReleaseUsec":private_continue_stopped.get("releaseUsec", -1),
			"historicalReleaseUsec":private_historical_stopped.get("releaseUsec", -1),
			"cancelDrained":private_cancel_result.get("drained", false),
			"legacyCancelDrained":legacy_cancel_result.get("drained", false)},
		"shadowFailureDecision":{"privateStageReason":premature_result.get("reason", ""),
			"scriptAuthorityStatus":shadow_decision.get("status", ""),
			"authoritativeStatus":authority_decision.get("status", "")},
		"failedMainRetirement":{"refusedBeforeDrain":owner_retained,
			"freedAfterDrain":acknowledged_free,
			"rejectedRestoreOwnerRetained":rejected_owner_retained},
		"doesNotProve":"No actual Main boot under injected private failure, loading responsiveness, authoritative collision readiness, or headed gameplay acceptance."}
	var report_path := OS.get_environment("VWB_LEGACY_LOAD_TRANSACTION_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	main.free()
	await process_frame
	quit(0 if report.passed else 1)

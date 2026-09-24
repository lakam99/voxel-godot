extends SceneTree

const Main = preload("res://scripts/MainCore.gd")
const Structures = preload("res://scripts/StructureSystem.gd")
const World = preload("res://scripts/WorldGenerationSystem.gd")
const Stage = preload("res://scripts/terrain/NativePrivateMainLoadStage.gd")
const Owner = preload("res://scripts/terrain/NativeTerrainRuntimeOwner.gd")
const SourceRequest = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")

class BorrowFailureStage:
	extends "res://scripts/terrain/NativePrivateMainLoadStage.gd"
	func _borrow_committed_backend(_receipt: Dictionary) -> Dictionary:
		return {"status":"failed", "reason":"fixture_borrow_rejected_after_commit"}

var failures: Array[String] = []
var observations: Dictionary = {}

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func _init() -> void:
	call_deferred("run")

func make_main(seed: String):
	var main = Main.new()
	main.seed_text = seed
	main.seed_hash = main.hash_string(seed)
	main.setup_noise()
	main.structure_system = Structures.new()
	var admission = main.structure_system.citadel_terrain_admission
	admission.configure(seed, {}, {"regionCells":main.STRUCTURE_REGION_CELLS,
		"spawnChance":float(main.STRUCTURE_SPAWN_CHANCE)})
	var finalized: Dictionary = admission.finalize_town_inputs(main.town_region_cache)
	check(finalized.get("status") == "ready", "town source finalizes")
	main.world_generation_system = World.new()
	main.world_generation_system.setup(main)
	return main

func make_save(main) -> Dictionary:
	main.world_generation_system.terrain_volume_service.set_cell_state(Vector3i(-17, -1, -1), {
		"material":"stone", "biome":"deep_underground", "solid":true,
		"density":1.25, "fluid":"", "blockId":"stage-transfer-edit",
		"light":{"sky":0,"block":0},
		"metadata":{"saveDelta":true,"source":"terrain_edit"}}, "fixture", false)
	var volume: Dictionary = main.world_generation_system.save_terrain_volume_deltas()
	check(not volume.get("sections", []).is_empty(), "save contains durable edit")
	return {"version":2, "seed":main.seed_text, "terrain":[], "terrainVolume":volume}

func make_manual_terrain(main):
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
	root.add_child(terrain)
	return terrain

func drive_stage(stage, max_frames := 600) -> Dictionary:
	var result: Dictionary = {}
	for frame in range(max_frames):
		result = stage.advance()
		if result.get("status") != "pending":
			result["frames"] = frame + 1
			return result
		await process_frame
	return {"status":"failed", "reason":"stage_timeout", "frames":max_frames}

func drain_stage(stage, max_frames := 600) -> Dictionary:
	var result: Dictionary = stage.stop()
	for frame in range(max_frames):
		if result.get("drained", false) or result.get("status") == "failed":
			result["frames"] = frame + 1
			return result
		await process_frame
		result = stage.advance_stop()
	return {"status":"failed", "reason":"stage_drain_timeout"}

func drain_owner(owner, max_frames := 600) -> Dictionary:
	var result: Dictionary = owner.stop()
	for frame in range(max_frames):
		if result.get("drained", false) or result.get("status") == "failed":
			result["frames"] = frame + 1
			return result
		await process_frame
		result = owner.drain_step()
	return {"status":"failed", "reason":"owner_drain_timeout"}

func exercise_consumed_failure(kind: String) -> void:
	var main = make_main("n5-consumed-failure-" + kind)
	var save = make_save(main)
	var terrain = make_manual_terrain(main)
	var stage = Stage.new()
	var started: Dictionary = stage.start(main, save)
	var ready: Dictionary = await drive_stage(stage)
	var handoff: Dictionary = stage.take_committed_transaction()
	var transaction = handoff.get("transaction")
	var receipt: Dictionary = handoff.get("receipt", {})
	var original_backend_id := int(receipt.get("backendInstanceId", 0))
	var original_generation := int(receipt.get("generation", 0))
	var original_source = receipt.get("sourceIdentity")
	if kind == "source_drift":
		main.seed_text = "wrong-seed-after-transfer"
	else:
		main.structure_system.citadel_terrain_admission.world_seed = "wrong-admission-seed"
	var owner = Owner.new()
	var failed: Dictionary = owner.setup_from_committed_transaction(main, terrain,
		transaction, receipt, 45, 0)
	var after_failure: Dictionary = owner.snapshot()
	var stage_pending: Dictionary = stage.stop()
	var wrong_failure: Dictionary = failed.duplicate(true)
	wrong_failure["backendInstanceId"] = original_backend_id + 1
	var wrong_bind: Dictionary = stage.bind_failed_transferred_owner(owner, wrong_failure)
	var bound: Dictionary = stage.bind_failed_transferred_owner(owner, failed)
	var early_ack: Dictionary = stage.acknowledge_failed_transferred_owner_drain(owner,
		{"status":"ready", "drained":true})
	var reclaim: Dictionary = stage.reclaim_unadopted_transaction(transaction, receipt)
	var expected_reason := "initialized_backend_source_mismatch" if kind == "source_drift" \
		else "shaping_bridge_seed_mismatch"
	check(started.get("status") == "pending" and ready.get("status") == "ready"
		and handoff.get("status") == "ready" and original_backend_id != 0
		and failed.get("status") == "failed" and failed.get("reason") == expected_reason
		and failed.get("cleanupPending") == true and failed.get("drained") == false
		and failed.get("ownerMustBeRetained") == true
		and int(failed.get("backendInstanceId", 0)) == original_backend_id
		and int(failed.get("loadGeneration", 0)) == original_generation
		and failed.get("sourceIdentity") == original_source
		and transaction.snapshot().get("state") == "transferred"
		and after_failure.get("state") == "failed_transfer_retirement"
		and int(after_failure.get("backendInstanceId", 0)) == original_backend_id
		and stage_pending.get("status") == "pending" and stage_pending.get("drained") == false
		and wrong_bind.get("status") == "failed" and bound.get("status") == "ready"
		and early_ack.get("status") == "pending" and reclaim.get("status") == "failed",
		kind + " retains exact consumed backend and denies early release")
	var owner_drain: Dictionary = await drain_owner(owner)
	var terminal: Dictionary = owner.snapshot().get("asyncStopReceipt", {})
	var stale: Dictionary = terminal.duplicate(true)
	stale["loadGeneration"] = original_generation + 1
	var stale_ack: Dictionary = stage.acknowledge_failed_transferred_owner_drain(owner, stale)
	var exact_ack: Dictionary = stage.acknowledge_failed_transferred_owner_drain(owner, terminal)
	check(owner_drain.get("status") == "ready" and owner_drain.get("drained") == true
		and terminal.get("failedTransferRetired") == true
		and int(terminal.get("backendInstanceId", 0)) == original_backend_id
		and int(terminal.get("loadGeneration", 0)) == original_generation
		and terminal.get("sourceIdentity") == original_source
		and terminal.get("physicalBlocksUnloaded") == true
		and terminal.get("nativeWorkersDrained") == true
		and terminal.get("demandReleased") == true
		and terminal.get("leasesReleased") == true
		and owner.snapshot().get("backendInstanceId") == 0
		and stale_ack.get("status") == "pending" and stale_ack.get("drained") == false
		and exact_ack.get("status") == "ready" and exact_ack.get("drained") == true
		and stage.stop().get("drained") == true,
		kind + " joins only actual bounded owner retirement")
	observations[kind] = {"failure":failed, "beforeDrain":after_failure,
		"stagePending":stage_pending, "wrongBind":wrong_bind,
		"earlyAck":early_ack, "ownerDrain":owner_drain,
		"staleAck":stale_ack, "exactAck":exact_ack,
		"terminal":terminal}
	terrain.free()
	main.free()
	await process_frame

func exercise_descriptor_drift(kind: String) -> void:
	var main = make_main("n5-descriptor-drift-" + kind)
	var save = make_save(main)
	var terrain = make_manual_terrain(main)
	var stage = Stage.new()
	var started: Dictionary = stage.start(main, save)
	var ready: Dictionary = await drive_stage(stage)
	var handoff: Dictionary = stage.take_committed_transaction()
	var transaction = handoff.get("transaction")
	var receipt: Dictionary = handoff.get("receipt", {})
	var frozen: Dictionary = transaction.committed_source_descriptor(receipt)
	var original_revision := int(receipt.get("durableSourceRevision", -1))
	var bad_receipt: Dictionary = receipt.duplicate(true)
	var wrong_descriptor: Dictionary = bad_receipt.get("sourceDescriptor", {}).duplicate(true)
	wrong_descriptor["seedText"] = "forged-descriptor"
	bad_receipt["sourceDescriptor"] = wrong_descriptor
	var wrong_owner = Owner.new()
	var wrong_setup: Dictionary = wrong_owner.setup_from_committed_transaction(main,
		terrain, transaction, bad_receipt, 46, 0)
	var transaction_after_wrong: Dictionary = transaction.snapshot()
	var stale_reclaim: Dictionary = stage.reclaim_unadopted_transaction(transaction, bad_receipt)
	var before_current: Dictionary = SourceRequest.from_finalized_main(main)
	if kind == "town":
		var admission = main.structure_system.citadel_terrain_admission
		admission.configure(main.seed_text, {}, {"regionCells":main.STRUCTURE_REGION_CELLS,
			"spawnChance":float(main.STRUCTURE_SPAWN_CHANCE)})
		var finalized: Dictionary = admission.finalize_town_inputs({Vector2i(2, -1):{}})
		check(finalized.get("status") == "ready", "same-seed town source re-finalizes")
	else:
		main.world_generation_system.terrain_volume_service.set_cell_state(
			Vector3i(41, -4, 12), {"material":"stone", "biome":"deep_underground",
			"solid":true, "density":1.25, "fluid":"", "blockId":"later-durable-edit",
			"light":{"sky":0,"block":0},
			"metadata":{"saveDelta":true,"source":"terrain_edit"}}, "fixture", false)
	var after_current: Dictionary = SourceRequest.from_finalized_main(main)
	var current_revision := int(main.world_generation_system.terrain_volume_revision())
	var owner = Owner.new()
	var rejected: Dictionary = owner.setup_from_committed_transaction(main, terrain,
		transaction, receipt, 47, 0)
	var transaction_after: Dictionary = transaction.snapshot()
	var pending: Dictionary = stage.stop()
	var reclaimed: Dictionary = stage.reclaim_unadopted_transaction(transaction, receipt)
	var drained: Dictionary = await drain_stage(stage)
	var expected_reason := "committed_transaction_source_descriptor_mismatch" if kind == "town" \
		else "committed_transaction_durable_source_revision_changed"
	check(started.get("status") == "pending" and ready.get("status") == "ready"
		and handoff.get("status") == "ready"
		and frozen.get("status") == "ready"
		and frozen.get("sourceDescriptor") == receipt.get("sourceDescriptor")
		and original_revision >= 0
		and wrong_setup.get("reason") == "committed_transaction_descriptor_receipt_mismatch"
		and transaction_after_wrong.get("state") == "committed"
		and transaction_after_wrong.get("sourceIdentity") == receipt.get("sourceIdentity")
		and stale_reclaim.get("status") == "failed"
		and rejected.get("status") == "failed" and rejected.get("reason") == expected_reason
		and transaction_after.get("state") == "committed"
		and int(transaction_after.get("backendInstanceId", 0)) \
			== int(receipt.get("backendInstanceId", 0))
		and transaction_after.get("sourceIdentity") == receipt.get("sourceIdentity")
		and owner.snapshot().get("state") == "failed"
		and int(owner.snapshot().get("backendInstanceId", -1)) == 0
		and pending.get("status") == "pending" and pending.get("drained") == false
		and reclaimed.get("status") == "ready" and reclaimed.get("reclaimed") == true
		and drained.get("status") == "ready" and drained.get("drained") == true
		and transaction.snapshot().get("state") == "transferred"
		and stage.stop().get("drained") == true
		and ((kind == "town" and before_current.get("request") \
			!= after_current.get("request") and current_revision == original_revision) \
			or (kind == "durable" and before_current.get("request") \
			== after_current.get("request") and current_revision > original_revision)),
		kind + " drift denies adoption and reclaims exact committed backend")
	observations["descriptor_" + kind] = {"frozen":frozen,
		"originalDescriptor":before_current.get("request"),
		"currentDescriptor":after_current.get("request"),
		"originalRevision":original_revision, "currentRevision":current_revision,
		"wrongSetup":wrong_setup, "staleReclaim":stale_reclaim,
		"transactionAfterWrong":transaction_after_wrong,
		"rejected":rejected, "pending":pending,
		"transactionAfter":transaction_after, "reclaimed":reclaimed, "drained":drained}
	terrain.free()
	main.free()
	await process_frame

func run() -> void:
	var main = make_main("n5-committed-stage-transfer")
	var save = make_save(main)
	var terrain = make_manual_terrain(main)
	var stage = Stage.new()
	var started: Dictionary = stage.start(main, save)
	var ready: Dictionary = await drive_stage(stage)
	var before: Dictionary = stage.snapshot()
	var original_transaction_id := int(before.get("transaction", {}).get("transactionId", 0))
	var original_backend_id := int(before.get("transaction", {}).get("backendInstanceId", 0))
	var original_identity = ready.get("receipt", {}).get("sourceIdentity")
	var wrong_receipt: Dictionary = ready.get("receipt", {}).duplicate(true)
	wrong_receipt["generation"] = int(wrong_receipt.get("generation", 0)) + 1
	var rejected_borrow: Dictionary = stage._transaction.borrow_committed_backend(wrong_receipt)
	check(started.get("status") == "pending" and ready.get("status") == "ready"
		and original_transaction_id != 0 and original_backend_id != 0
		and before.get("backendRetained") == true
		and before.get("transaction", {}).get("state") == "committed"
		and before.get("transaction", {}).get("snapshotLeaseValid") == true,
		"committed private candidate retains exact transaction, backend and save lease")
	check(rejected_borrow.get("reason") == "committed_backend_receipt_mismatch"
		and stage._transaction.snapshot().get("state") == "committed",
		"wrong receipt cannot borrow or consume committed backend")
	var handoff: Dictionary = stage.take_committed_transaction()
	var transaction = handoff.get("transaction")
	var transferred_state: Dictionary = transaction.snapshot() if transaction != null else {}
	var stage_stop: Dictionary = stage.stop()
	var stage_stop_again: Dictionary = stage.advance_stop()
	check(handoff.get("status") == "ready" and transaction != null
		and int(handoff.get("transactionId", 0)) == original_transaction_id
		and int(handoff.get("backendInstanceId", 0)) == original_backend_id
		and handoff.get("receipt") == ready.get("receipt")
		and transferred_state.get("state") == "committed"
		and transferred_state.get("snapshotLeaseValid") == true
		and transferred_state.get("backendInstanceId") == original_backend_id
		and stage_stop.get("status") == "pending" and stage_stop.get("drained") == false
		and stage_stop.get("stageReleased") == true
		and stage_stop.get("ownershipTransferred") == true
		and stage_stop.get("ownerMustBeRetained") == true
		and stage_stop_again == stage_stop
		and transaction.snapshot().get("backendInstanceId") == original_backend_id,
		"stage transfers once and reports external owner drain as outstanding")
	var replay: Dictionary = stage.take_committed_transaction()
	check(replay.get("status") == "failed" and replay.get("reason") == "private_committed_transfer_unavailable",
		"stage rejects transfer replay")
	var owner = Owner.new()
	var adopted: Dictionary = owner.setup_from_committed_transaction(main, terrain,
		transaction, handoff.get("receipt", {}), 42, 0)
	var after_adoption: Dictionary = transaction.snapshot()
	var wrong_adoption: Dictionary = adopted.duplicate(true)
	wrong_adoption["backendInstanceId"] = 0
	var wrong_bind: Dictionary = stage.bind_transferred_owner(owner, wrong_adoption)
	var bound: Dictionary = stage.bind_transferred_owner(owner, adopted)
	var early_ack: Dictionary = stage.acknowledge_transferred_owner_drain(owner,
		{"status":"ready", "drained":true})
	var adopted_reclaim: Dictionary = stage.reclaim_unadopted_transaction(transaction,
		handoff.get("receipt", {}))
	check(adopted.get("status") == "ready" and adopted.get("adoptedCommittedBackend") == true
		and adopted.get("backendInstanceId") == original_backend_id
		and adopted.get("sourceIdentity") == original_identity
		and after_adoption.get("state") == "transferred"
		and after_adoption.get("backendInstanceId") == 0,
		"real native owner consumes exact committed backend once")
	check(wrong_bind.get("status") == "failed"
		and bound.get("status") == "ready"
		and adopted_reclaim.get("status") == "failed"
		and early_ack.get("status") == "pending" and early_ack.get("drained") == false,
		"stage binds exact live owner and rejects reclaim or early drain acknowledgement")
	var second_owner = Owner.new()
	var second_adoption: Dictionary = second_owner.setup_from_committed_transaction(main, terrain,
		transaction, handoff.get("receipt", {}), 43, 0)
	check(second_adoption.get("status") == "failed", "second owner cannot adopt transaction replay")
	var owner_drain: Dictionary = await drain_owner(owner)
	check(owner_drain.get("drained") == true, "adopted native owner drains")
	var final_receipt: Dictionary = owner.snapshot().get("asyncStopReceipt", {})
	var wrong_drain: Dictionary = final_receipt.duplicate(true)
	wrong_drain["ownerGeneration"] = int(wrong_drain.get("ownerGeneration", 0)) + 1
	var wrong_ack: Dictionary = stage.acknowledge_transferred_owner_drain(owner, wrong_drain)
	var acknowledged: Dictionary = stage.acknowledge_transferred_owner_drain(owner, final_receipt)
	check(wrong_ack.get("status") == "pending" and wrong_ack.get("drained") == false
		and acknowledged.get("status") == "ready" and acknowledged.get("drained") == true
		and stage.stop().get("drained") == true,
		"only exact live owner drain receipt lets transferred stage report drained")
	observations["handoff"] = {"transactionId":original_transaction_id,
		"backendInstanceId":original_backend_id, "sourceIdentity":original_identity,
		"adopted":adopted, "stageStop":stage_stop, "ownerDrain":owner_drain,
		"earlyAck":early_ack, "wrongAck":wrong_ack, "acknowledged":acknowledged}

	var private_stage = Stage.new()
	var private_started: Dictionary = private_stage.start(main, save)
	var private_ready: Dictionary = await drive_stage(private_stage)
	var rejected_private_borrow: Dictionary = private_stage._transaction.borrow_committed_backend(wrong_receipt)
	var private_drain: Dictionary = await drain_stage(private_stage)
	check(private_started.get("status") == "pending" and private_ready.get("status") == "ready"
		and rejected_private_borrow.get("status") == "failed"
		and rejected_private_borrow.get("reason") == "committed_backend_receipt_mismatch"
		and private_drain.get("drained") == true
		and private_stage.stop().get("drained") == true
		and private_stage.take_committed_transaction().get("status") == "failed",
		"failed post-commit borrow retains transaction for bounded private retirement")
	observations["privateRetirement"] = private_drain

	var failed_borrow_stage = BorrowFailureStage.new()
	var failed_borrow_started: Dictionary = failed_borrow_stage.start(main, save)
	var failed_borrow_result: Dictionary = await drive_stage(failed_borrow_stage)
	var failed_borrow_before: Dictionary = failed_borrow_stage.snapshot()
	var failed_borrow_drain: Dictionary = await drain_stage(failed_borrow_stage)
	check(failed_borrow_started.get("status") == "pending"
		and failed_borrow_result.get("reason") == "fixture_borrow_rejected_after_commit"
		and failed_borrow_result.get("ownerMustBeRetained") == true
		and failed_borrow_before.get("transaction", {}).get("state") == "committed"
		and failed_borrow_before.get("backendRetained") == false
		and failed_borrow_drain.get("drained") == true,
		"post-commit borrow failure retains real transaction until bounded retirement")
	observations["postCommitBorrowFailure"] = {"failure":failed_borrow_result,
		"beforeStop":failed_borrow_before, "drain":failed_borrow_drain}

	var failed_adoption_stage = Stage.new()
	var failed_adoption_started: Dictionary = failed_adoption_stage.start(main, save)
	var failed_adoption_ready: Dictionary = await drive_stage(failed_adoption_stage)
	var failed_adoption_transfer: Dictionary = failed_adoption_stage.take_committed_transaction()
	var failed_adoption_transaction = failed_adoption_transfer.get("transaction")
	var invalid_owner = Owner.new()
	var rejected_adoption: Dictionary = invalid_owner.setup_from_committed_transaction(main,
		null, failed_adoption_transaction, failed_adoption_transfer.get("receipt", {}), 44, 0)
	var transaction_after_failed_adoption: Dictionary = failed_adoption_transaction.snapshot()
	var pending_stop: Dictionary = failed_adoption_stage.stop()
	var stale_reclaim_receipt: Dictionary = failed_adoption_transfer.get("receipt", {}).duplicate(true)
	stale_reclaim_receipt["generation"] = int(stale_reclaim_receipt.get("generation", 0)) + 1
	var stale_reclaim: Dictionary = failed_adoption_stage.reclaim_unadopted_transaction(
		failed_adoption_transaction, stale_reclaim_receipt)
	var reclaimed: Dictionary = failed_adoption_stage.reclaim_unadopted_transaction(
		failed_adoption_transaction, failed_adoption_transfer.get("receipt", {}))
	var reclaimed_drain: Dictionary = await drain_stage(failed_adoption_stage)
	check(failed_adoption_started.get("status") == "pending"
		and failed_adoption_ready.get("status") == "ready"
		and failed_adoption_transfer.get("status") == "ready"
		and rejected_adoption.get("status") == "failed"
		and transaction_after_failed_adoption.get("state") == "committed"
		and pending_stop.get("status") == "pending" and pending_stop.get("drained") == false
		and stale_reclaim.get("status") == "failed"
		and reclaimed.get("status") == "ready" and reclaimed.get("reclaimed") == true
		and reclaimed_drain.get("drained") == true,
		"receiver setup failure permits exact single-use reclaim and bounded retirement")
	observations["failedAdoptionReclaim"] = {"adoption":rejected_adoption,
		"pendingStop":pending_stop, "staleReclaim":stale_reclaim,
		"reclaimed":reclaimed, "drain":reclaimed_drain}

	var cancelled_stage = Stage.new()
	var cancel_started: Dictionary = cancelled_stage.start(main, save)
	var cancel_drain: Dictionary = await drain_stage(cancelled_stage)
	check(cancel_started.get("status") == "pending" and cancel_drain.get("drained") == true
		and cancelled_stage.take_committed_transaction().get("status") == "failed",
		"in-flight import cancel drains without transfer")
	observations["cancel"] = cancel_drain

	var drift_stage = Stage.new()
	var drift_started: Dictionary = drift_stage.start(main, save)
	var drift_ready: Dictionary = await drive_stage(drift_stage)
	var old_seed: String = main.seed_text
	main.seed_text = "different-seed-before-transfer"
	var drift_handoff: Dictionary = drift_stage.take_committed_transaction()
	main.seed_text = old_seed
	var drift_drain: Dictionary = await drain_stage(drift_stage)
	check(drift_started.get("status") == "pending" and drift_ready.get("status") == "ready"
		and drift_handoff.get("reason") == "private_source_changed_before_transfer"
		and drift_handoff.get("ownerMustBeRetained") == true
		and drift_drain.get("drained") == true,
		"source drift rejects handoff and private stage retains drain ownership")
	observations["drift"] = {"rejection":drift_handoff, "drain":drift_drain}

	await exercise_consumed_failure("source_drift")
	await exercise_consumed_failure("page_setup")
	await exercise_descriptor_drift("town")
	await exercise_descriptor_drift("durable")

	var report_path := OS.get_environment("VWB_N5_COMMITTED_STAGE_TRANSFER_REPORT")
	terrain.free()
	main.free()
	await process_frame
	var report := {"finished":true, "passed":failures.is_empty(), "failures":failures,
		"observations":observations, "scope":"focused real transaction and owner contract; no production Main cutover"}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	quit(0 if failures.is_empty() else 1)

extends SceneTree

const TRANSACTION = preload("res://scripts/terrain/NativeTerrainLoadTransaction.gd")
const MAIN = preload("res://scripts/MainCore.gd")
const STRUCTURES = preload("res://scripts/StructureSystem.gd")
const WORLD = preload("res://scripts/WorldGenerationSystem.gd")
const SOURCE = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const RUNTIME_OWNER = preload("res://scripts/terrain/NativeTerrainRuntimeOwner.gd")

class FakeWorkerBackend extends RefCounted:
	var worker_in_flight := false
	var cancelled := false
	var drain_calls := 0
	var terminal_drain_failure := false

	func begin_staged_save_v2_initialization(_request: Dictionary, _identity: Dictionary) -> Dictionary:
		return {"status": "pending", "generation": 71}

	func append_terrain_volume_v2_import(_chunks: Array, _generation: int) -> Dictionary:
		return {"status": "pending"}

	func start_staged_save_v2_finalization(_generation: int) -> Dictionary:
		worker_in_flight = true
		return {"status": "pending"}

	func cancel_staged_save_v2_initialization(_generation: int) -> Dictionary:
		cancelled = true
		return {"status": "pending", "reason": "cancel_requested_worker_retained"}

	func drain_staged_save_v2_initialization(_generation: int) -> Dictionary:
		drain_calls += 1
		if terminal_drain_failure:
			return {"status": "failed", "reason": "synthetic_terminal_failure", "workerJoined": false}
		if worker_in_flight:
			worker_in_flight = false
			return {"status": "pending", "reason": "worker_drain_ack_pending", "workerJoined": false}
		if drain_calls == 2:
			return {"status": "pending", "reason": "bounded_cleanup_in_progress", "workerJoined": true}
		return {"status": "ready", "reason": "drained", "cleanupComplete": true,
			"workerJoined": true}

	func status() -> Dictionary:
		return {"status": "uninitialized"}

const RECORD_BUDGET := 128
var failures: Array[String] = []

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func _init() -> void:
	call_deferred("run")

func _state(cell: Array, local: Array, section_key: Array) -> Dictionary:
	return {"cell": cell.duplicate(), "sectionKey": section_key.duplicate(),
		"localCell": local.duplicate(), "blockId": "terrain.import.test",
		"material": "stone", "biome": "underground", "solid": true,
		"density": 1.25, "fluid": "", "light": {"sky": 3, "block": 7},
		"metadata": {"saveDelta": true}, "editReason": "n3_load_transaction",
		"generated": false, "edited": true}

func _section(cell_count: int, malformed_cell: int = -1) -> Dictionary:
	var section_key := [0, 0, 0]
	var cells: Array = []
	for index in range(cell_count):
		var cell := [index % 16, int(index / 16) % 16, int(index / 256)]
		var local := cell.duplicate()
		if index == malformed_cell: local = [0, 0, 0]
		cells.append({"cell": cell, "local": local,
			"state": _state(cell, local, section_key)})
	return {"schemaVersion": 1, "sectionKey": section_key,
		"originCell": [0, 0, 0], "revision": 7, "cells": cells}

func _volume(cell_count: int, malformed_cell: int = -1) -> Dictionary:
	var sections: Array = []
	if cell_count > 0: sections.append(_section(cell_count, malformed_cell))
	return {"schemaVersion": 1, "sectionSize": 16, "revision": 9, "sections": sections}

func _source(main, volume: Dictionary) -> Dictionary:
	var save := {"version": 2, "seed": String(main.seed_text),
		"terrain": [], "terrainVolume": volume}
	return SOURCE.from_main_with_v2_save_snapshot(main, save)

func _drive_to_candidate(transaction, max_frames: int = 1200) -> Dictionary:
	for _frame in range(max_frames):
		var result: Dictionary = transaction.advance()
		if result.get("reason") == "candidate_requires_explicit_commit": return result
		if result.get("status") == "failed": return result
		await process_frame
	return {"status": "timeout", "reason": "candidate_not_ready_within_contract_budget"}

func _drive_to_terminal(transaction, max_frames: int = 1200) -> Dictionary:
	var drain_polls := 0
	for _frame in range(max_frames):
		var result: Dictionary = transaction.advance()
		if result.get("drained") == true:
			result["drainPolls"] = drain_polls
			return result
		if transaction.snapshot().get("state") == "draining": drain_polls += 1
		if result.get("status") == "failed" and not transaction.snapshot().get("ownerMustBeRetained", false):
			return result
		await process_frame
	return {"status": "timeout", "reason": "cleanup_not_drained_within_contract_budget"}

func run() -> void:
	var started_usec := Time.get_ticks_usec()
	var main = MAIN.new()
	main.seed_text = "native-main-load-transaction-contract"
	main.structure_system = STRUCTURES.new()
	var policy := {"regionCells": main.STRUCTURE_REGION_CELLS,
		"spawnChance": float(main.STRUCTURE_SPAWN_CHANCE)}
	main.structure_system.citadel_terrain_admission.configure(main.seed_text, {}, policy)
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	var terrain_world := Node3D.new()
	root.add_child(terrain_world)
	var terrain := VoxelTerrain.new()
	terrain.automatic_loading_enabled = false
	terrain.mesh_block_size = 16
	terrain.scale = Vector3.ONE * main.CELL
	var terrain_format := VoxelFormat.new()
	terrain_format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	terrain_format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	terrain_format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	terrain.set_format(terrain_format)
	var terrain_mesher := VoxelMesherTransvoxel.new()
	terrain_mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	terrain_mesher.transitions_enabled = false
	terrain.mesher = terrain_mesher
	terrain_world.add_child(terrain)
	var base: Dictionary = SOURCE.from_main(main)
	check(base.get("status") == "ready", "fixture creates canonical native source descriptor")
	check(not main.has_method("begin_native_terrain_load_preparation")
		and not main.has_method("advance_native_terrain_load_preparation")
		and not main.has_method("stop_native_terrain_load_preparation"),
		"Main does not expose the old synchronous load hook")

	var volume := _volume(600)
	var built: Dictionary = _source(main, volume)
	check(built.get("status") == "ready", "fixture builds a v2 source request")
	var caller_request: Dictionary = built.get("request", {})
	var retained_sections = caller_request.get("terrainVolume", {}).get("sections", null)
	var original_volume := volume.duplicate(true)
	check(caller_request.terrainVolume == volume
		and built.snapshotOwner.retained_owner() is Dictionary
		and built.snapshotOwner.retained_owner().get("terrainVolume") == volume,
		"save snapshot constructor borrows the exact volume and retains its leased owner")
	var unleased = TRANSACTION.new()
	check(unleased.start(caller_request, RECORD_BUDGET).get("reason") == "save_snapshot_lease_required",
		"save-volume requests fail closed without a producer-issued snapshot lease")
	var bypass_request: Dictionary = base.request.duplicate(true)
	bypass_request["terrainVolume"] = volume
	var bypass_transaction = TRANSACTION.new()
	check(bypass_transaction.start(bypass_request, RECORD_BUDGET).get("reason")
		== "save_volume_requires_snapshot_lease",
		"ordinary source schema cannot smuggle in an unleased save volume")
	var descriptor_before := String(main.seed_text)
	caller_request.constants["waterLevelMeters"] = -777.0
	check(String(main.seed_text) == descriptor_before and float(main.WATER_LEVEL) != -777.0,
		"native source descriptor is isolated from caller gameplay/save state")
	# Restore the intentionally modified private request descriptor before start.
	caller_request.constants["waterLevelMeters"] = float(main.WATER_LEVEL)
	var transaction = TRANSACTION.new()
	var begun: Dictionary = transaction.start(caller_request, RECORD_BUDGET, built.snapshotOwner)
	check(begun.get("status") == "pending"
		and int(begun.get("maxRecordsPerAdvance", -1)) == RECORD_BUDGET,
		"transaction starts the native private candidate with an explicit bounded append budget")
	var backend = transaction._backend
	check(backend != null and backend.status().get("status") == "uninitialized",
		"staged backend is not authoritatively visible before candidate commit")
	check(transaction._input_request == caller_request
		and transaction._sections == retained_sections,
		"transaction retains the caller-owned canonical save snapshot without recursively cloning it")
	var append_calls := 0
	var append_total := 0
	for _frame in range(10):
		var step: Dictionary = transaction.advance()
		var appended := int(step.get("appendedRecords", 0))
		if appended > 0:
			append_calls += 1
			append_total += appended
			check(appended <= RECORD_BUDGET
				and int(transaction.snapshot().get("lastAdvanceRecords", -1)) == appended,
				"each Main-thread import advance stays within its admitted record budget")
		await process_frame
	check(append_calls == 5 and append_total == 600,
		"600 durable records are admitted through five bounded append calls")
	var candidate_result: Dictionary = await _drive_to_candidate(transaction)
	var candidate_identity: Dictionary = transaction.candidate_source_identity()
	check(candidate_result.get("reason") == "candidate_requires_explicit_commit"
		and candidate_identity.get("algorithm") == "sha256"
		and transaction.snapshot().get("state") == "candidate_ready"
		and backend.status().get("status") == "uninitialized",
		"private worker finalization returns a source-identified candidate but does not publish it")
	var bad_commit: Dictionary = transaction.commit({"algorithm": "sha256", "hex": "0".repeat(64)})
	check(bad_commit.get("status") == "failed"
		and transaction.snapshot().get("state") == "candidate_ready"
		and backend.status().get("status") == "uninitialized",
		"wrong source identity cannot consume the commit right or expose the candidate")
	var committed: Dictionary = transaction.commit(candidate_identity)
	check(committed.get("status") == "ready" and committed.get("committed") == true
		and backend.status().get("status") == "ready"
		and transaction.snapshot().get("inputSnapshotRetained") == true
		and caller_request.terrainVolume == original_volume,
		"native commit explicitly validates the candidate source identity")
	var runtime_owner = RUNTIME_OWNER.new()
	var adopted: Dictionary = runtime_owner.setup_from_committed_transaction(
		main, terrain, transaction, committed, 71, 10)
	var adopted_state: Dictionary = runtime_owner.snapshot()
	var adopted_save: Dictionary = runtime_owner.export_terrain_volume_v2()
	check(adopted.get("status") == "ready"
		and adopted.get("adoptedCommittedBackend") == true
		and adopted_state.get("state") == "active"
		and int(adopted_state.get("backendInstanceId", 0)) == int(committed.get("backendInstanceId", -1))
		and transaction.snapshot().get("state") == "transferred"
		and adopted_save.get("terrainVolume", {}) == original_volume
		and caller_request.terrainVolume == original_volume
		and transaction.snapshot().get("inputSnapshotRetained") == false,
		"runtime owner consumes the committed transaction receipt once and preserves exact v2 data")
	check(transaction.take_backend() == null,
		"runtime owner adoption leaves no second backend transfer available")
	var runtime_owner_stop: Dictionary = runtime_owner.stop()
	for _frame in range(120):
		if runtime_owner_stop.get("status") == "ready": break
		await process_frame
		runtime_owner_stop = runtime_owner.drain_step()
	check(runtime_owner_stop.get("status") == "ready",
		"runtime owner adopted from the load transaction drains cleanly")

	var revoked_commit_source: Dictionary = _source(main, _volume(4))
	var revoked_commit_transaction = TRANSACTION.new()
	revoked_commit_transaction.start(revoked_commit_source.request, 4, revoked_commit_source.snapshotOwner)
	await _drive_to_candidate(revoked_commit_transaction)
	var revoked_commit_backend = revoked_commit_transaction._backend
	var revoked_commit_identity := revoked_commit_transaction.candidate_source_identity()
	revoked_commit_source.snapshotOwner.invalidate("producer_released_before_commit")
	var rejected_revoked_commit: Dictionary = revoked_commit_transaction.commit(revoked_commit_identity)
	var revoked_commit_cleanup: Dictionary = await _drive_to_terminal(revoked_commit_transaction)
	check(rejected_revoked_commit.get("reason") == "save_snapshot_lease_revoked_before_commit"
		and revoked_commit_backend.status().get("status") == "uninitialized"
		and revoked_commit_cleanup.get("drained") == true
		and revoked_commit_transaction.take_backend() == null,
		"revoked snapshot lease after worker completion still blocks commit and drains private candidate")

	var revoked_source: Dictionary = _source(main, _volume(300))
	var revoked_transaction = TRANSACTION.new()
	revoked_transaction.start(revoked_source.request, 64, revoked_source.snapshotOwner)
	var revoked_first: Dictionary = revoked_transaction.advance()
	revoked_source.snapshotOwner.invalidate("producer_mutation")
	revoked_source.request.terrainVolume.sections[0].cells[64].state.material = "mutated_after_revoke"
	var revoked_mutation_step: Dictionary = revoked_transaction.advance()
	var revoked_cleanup: Dictionary = await _drive_to_terminal(revoked_transaction)
	check(revoked_first.get("appendedRecords") == 64
		and revoked_mutation_step.get("reason") == "native_load_cleanup_pending"
		and revoked_transaction.snapshot().get("recordsAdmitted") == 64
		and revoked_cleanup.get("drained") == true
		and revoked_transaction.commit({}).get("status") == "failed",
		"revoked producer lease stops bounded admission before a mixed snapshot can commit")

	var fake_backend := FakeWorkerBackend.new()
	var fake_transaction = TRANSACTION.new()
	fake_transaction._backend_factory = func(): return fake_backend
	fake_transaction.start(base.request)
	fake_transaction.advance()
	fake_transaction.cancel()
	var in_flight_poll: Dictionary = fake_transaction.advance()
	var retained_during_first_poll: bool = fake_transaction.snapshot().get("ownerMustBeRetained", false)
	var joined_poll: Dictionary = fake_transaction.advance()
	var disposed_poll: Dictionary = fake_transaction.advance()
	check(fake_backend.cancelled
		and in_flight_poll.get("status") == "pending"
		and in_flight_poll.get("workerJoined") == false
		and retained_during_first_poll
		and joined_poll.get("workerJoined") == true
		and joined_poll.get("drained") != true
		and disposed_poll.get("cleanupComplete") == true
		and fake_transaction.snapshot().get("backendInstanceId") == 0,
		"deterministic worker-in-flight cancellation waits through join and bounded disposal before release")

	var failed_drain_backend := FakeWorkerBackend.new()
	failed_drain_backend.terminal_drain_failure = true
	var failed_drain_transaction = TRANSACTION.new()
	failed_drain_transaction._backend_factory = func(): return failed_drain_backend
	failed_drain_transaction.start(base.request)
	failed_drain_transaction.advance()
	failed_drain_transaction.cancel()
	var terminal_drain: Dictionary = failed_drain_transaction.advance()
	check(terminal_drain.get("status") == "failed"
		and terminal_drain.get("ownerMustBeRetained") == true
		and failed_drain_transaction.snapshot().get("state") == "ownership_error"
		and failed_drain_transaction.snapshot().get("backendInstanceId") != 0,
		"terminal drain failure settles explicitly instead of pending forever, retaining unresolved owner")

	var accepting_cancel = TRANSACTION.new()
	var cancel_built: Dictionary = _source(main, _volume(600))
	var cancel_start := accepting_cancel.start(cancel_built.request, 64, cancel_built.snapshotOwner)
	var admitted_before_cancel := 0
	for _admission in range(10):
		var admission: Dictionary = accepting_cancel.advance()
		admitted_before_cancel += int(admission.get("appendedRecords", 0))
	var cancel_request: Dictionary = accepting_cancel.cancel()
	check(cancel_start.get("status") == "pending"
		and admitted_before_cancel == 600
		and cancel_request.get("status") == "pending"
		and accepting_cancel.snapshot().get("backendInstanceId") != 0,
		"accepting-state cancellation retains the backend and staged records for cleanup")
	var accepting_cancelled: Dictionary = await _drive_to_terminal(accepting_cancel)
	check(accepting_cancelled.get("drained") == true
		and accepting_cancelled.get("cancelled") == true
		and accepting_cancel.snapshot().get("backendInstanceId") == 0
		and int(accepting_cancelled.get("drainPolls", 0)) > 1,
		"accepting cancellation drains more than 64 retained records across bounded steps")

	var finalizing_cancel = TRANSACTION.new()
	var finalizing_built: Dictionary = _source(main, _volume(256))
	finalizing_cancel.start(finalizing_built.request, 256, finalizing_built.snapshotOwner)
	finalizing_cancel.advance() # admit bounded cell chunk
	finalizing_cancel.advance() # advance section cursor
	var finalizing_started: Dictionary = finalizing_cancel.advance()
	var finalizing_backend = finalizing_cancel._backend
	var cancel_during_finalize := finalizing_cancel.cancel()
	check(finalizing_started.get("reason") == "worker_finalizing_candidate"
		and cancel_during_finalize.get("status") == "pending"
		and finalizing_cancel.snapshot().get("backendInstanceId") != 0,
		"finalization cancellation retains the source/backend owner while worker acknowledgement is pending")
	var finalized_cancelled: Dictionary = await _drive_to_terminal(finalizing_cancel)
	check(finalized_cancelled.get("drained") == true
		and finalizing_backend.status().get("status") == "uninitialized",
		"worker cancellation drains before private candidate/source ownership is released")

	var malformed_source: Dictionary = _source(main, _volume(2, 1))
	var malformed = TRANSACTION.new()
	malformed.start(malformed_source.request, 1, malformed_source.snapshotOwner)
	var first_bad_step: Dictionary = malformed.advance()
	var second_bad_step: Dictionary = malformed.advance()
	check(first_bad_step.get("appendedRecords") == 1
		and second_bad_step.get("reason") == "native_load_cleanup_pending",
		"malformed chunk after partial admission enters retained failure cleanup")
	var malformed_cleanup: Dictionary = await _drive_to_terminal(malformed)
	check(malformed_cleanup.get("drained") == true
		and malformed_cleanup.get("status") == "failed"
		and not String(malformed_cleanup.get("reason", "")).is_empty(),
		"malformed save failure is reported and the partial native owner is drained")

	var stale = TRANSACTION.new()
	var stale_built: Dictionary = _source(main, _volume(2))
	stale.start(stale_built.request, 1, stale_built.snapshotOwner)
	var stale_generation := int(stale.snapshot().get("generation", -1)) + 1
	var stale_append: Dictionary = stale._backend.append_terrain_volume_v2_import(
		[_section(1)], stale_generation)
	check(stale_append.get("reason") == "stale_import_generation"
		and stale.snapshot().get("state") == "accepting",
		"stale generation is rejected without changing the active transaction")
	stale.cancel()
	var stale_cleanup: Dictionary = await _drive_to_terminal(stale)
	check(stale_cleanup.get("drained") == true,
		"stale generation probe leaves its real generation cancellable and drainable")

	var elapsed_usec := Time.get_ticks_usec() - started_usec
	var report := {"schema": "n3-native-terrain-load-transaction/v4",
		"passed": failures.is_empty(), "productionCutover": false,
		"evidenceLevel": "focused GDExtension staged save-v2 transaction contract",
		"failures": failures,
		"metrics": {"elapsedUsec": elapsed_usec, "recordsPerAdvance": RECORD_BUDGET,
			"appendCalls": append_calls, "appendRecords": append_total,
			"advanceCount": transaction.snapshot().get("advanceCount", 0),
			"maxAdvanceUsec": transaction.snapshot().get("maxAdvanceUsec", 0)},
		"lifecycle": {"commitIdentity": candidate_identity,
			"transferredBackendInstanceId": adopted.get("backendInstanceId", 0),
			"committedTransactionOwnerAdoption": adopted.get("status"),
			"acceptingCancelDrained": accepting_cancelled.get("cleanupComplete", false),
			"finalizingCancelDrained": finalized_cancelled.get("cleanupComplete", false),
			"malformedDrainStatus": malformed_cleanup.get("status"),
			"malformedFailure": malformed_cleanup.get("reason", ""),
			"staleGenerationRejected": stale_append.get("reason") == "stale_import_generation",
		"leaseRevocationStopsAdmission": revoked_cleanup.get("drained", false),
		"leaseRevokedCommitRejected": rejected_revoked_commit.get("reason"),
		"workerInFlightDrainCalls": fake_backend.drain_calls,
		"workerInFlightTrace": {"cancelled": fake_backend.cancelled,
			"firstStatus": in_flight_poll.get("status"),
			"firstJoined": in_flight_poll.get("workerJoined"),
			"retainedDuringFirst": retained_during_first_poll,
			"secondJoined": joined_poll.get("workerJoined"),
			"secondDrained": joined_poll.get("drained"),
			"thirdCleanupComplete": disposed_poll.get("cleanupComplete"),
			"backendAfterDrain": fake_transaction.snapshot().get("backendInstanceId")},
		"terminalDrainFailureSettled": terminal_drain.get("status") == "failed"},
		"timingInterpretation": "record-count and transaction diagnostics only; not a frame-time or headed responsiveness acceptance result",
		"doesNotProve": "No production Main New Game/Continue wiring, immutable save publisher, headed frame cadence, physical collision readiness or full N3 authority cutover."}
	var path := OS.get_environment("VWB_MAIN_LOAD_TRANSACTION_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	main.free()
	await process_frame
	quit(0 if report.passed else 1)

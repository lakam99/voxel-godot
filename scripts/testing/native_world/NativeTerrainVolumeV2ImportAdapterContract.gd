extends SceneTree

var failures: Array[String] = []

const SOURCE_REQUEST := preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const MAIN := preload("res://scripts/Main.gd")
const STRUCTURES := preload("res://scripts/StructureSystem.gd")


func check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func cell_state(metadata_override: Dictionary = {}) -> Dictionary:
	var metadata := metadata_override.duplicate(true) if not metadata_override.is_empty() else {"saveDelta": true}
	return {
		"blockId": "terrain.import.test",
		"material": "stone",
		"biome": "underground",
		"solid": true,
		"density": 1.25,
		"fluid": "",
		"light": {"sky": 3, "block": 7},
		"metadata": metadata,
		"editReason": "import_test",
		"generated": false,
		"edited": true,
	}


func section_chunk(cell_count: int, metadata_override: Dictionary = {}, start_index := 0) -> Dictionary:
	var section_key := [0, 0, 0]
	var cells: Array = []
	for index in range(start_index, start_index + cell_count):
		var cell := [index % 16, int(index / 16), 0]
		var local := cell.duplicate()
		var state := cell_state(metadata_override)
		state["cell"] = cell.duplicate()
		state["sectionKey"] = section_key.duplicate()
		state["localCell"] = local.duplicate()
		cells.append({"cell": cell, "local": local, "state": state})
	return {"schemaVersion": 1, "sectionKey": section_key, "originCell": [0, 0, 0],
		"revision": 7, "cells": cells}


func staged_source_request(seed: String) -> Dictionary:
	var main = MAIN.new()
	main.seed_text = seed
	main.seed_hash = main.hash_string(seed)
	main.setup_noise()
	main.structure_system = STRUCTURES.new()
	main.structure_system.citadel_terrain_admission.configure(seed, {}, {
		"regionCells": main.STRUCTURE_REGION_CELLS,
		"spawnChance": main.STRUCTURE_SPAWN_CHANCE})
	main.town_region_cache = {}
	var built: Dictionary = SOURCE_REQUEST.from_main(main)
	if built.get("status") != "ready":
		main.free()
		return {}
	var request: Dictionary = built.request.duplicate(true)
	request["saveSeedText"] = seed
	main.free()
	return request


func metadata_at_native_node_limit() -> Dictionary:
	var payload: Array = []
	for item_count in [1023, 1022, 1022, 1022]:
		var branch: Array[bool] = []
		branch.resize(item_count)
		branch.fill(true)
		payload.append(branch)
	return {"saveDelta": true, "payload": payload}


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var report_path := OS.get_environment("VWB_TERRAIN_IMPORT_ADAPTER_REPORT")
	if not report_path.is_empty() and not report_path.get_base_dir().is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(report_path.get_base_dir()))
	var report := {"schema": "native-terrain-volume-v2-import-adapter-contract/v1",
		"passed": false, "failures": failures, "timing": {},
		"timingInterpretation": "diagnostic only; not frame-responsiveness acceptance evidence",
		"evidenceLevel": "GDExtension staging API contract", "productionCutover": false}
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "NativeWorldBackend instantiates")
	if backend != null:
		for method in ["begin_terrain_volume_v2_import", "append_terrain_volume_v2_import",
				"cancel_terrain_volume_v2_import", "drain_terrain_volume_v2_import",
				"terrain_volume_v2_import_status"]:
			check(backend.has_method(method), "binding exists: " + method)
		var adapter_methods_available := true
		for method in ["begin_terrain_volume_v2_import", "append_terrain_volume_v2_import",
				"cancel_terrain_volume_v2_import", "drain_terrain_volume_v2_import",
				"terrain_volume_v2_import_status"]:
			adapter_methods_available = adapter_methods_available and backend.has_method(method)
		if adapter_methods_available:
			var identity := {"domain": "terrainVolume", "schemaVersion": 1,
				"sectionSize": 16, "revision": 9}
			var started := Time.get_ticks_usec()
			var begun: Dictionary = backend.begin_terrain_volume_v2_import(identity)
			check(begun.get("status") == "pending" and not bool(begun.get("finalizeAvailable", true)),
				"begin freezes identity and remains staging-only")
			var first_generation := int(begun.get("generation", -1))
			var append_started := Time.get_ticks_usec()
			var accepted: Dictionary = backend.append_terrain_volume_v2_import(
				[section_chunk(100)], first_generation)
			var append_wall_usec := Time.get_ticks_usec() - append_started
			check(accepted.get("status") == "pending" and int(accepted.get("recordsRetained", 0)) == 100,
				"bounded typed batch is retained without full-volume finalization")
			var initialize_while_importing: Dictionary = backend.initialize({})
			var save_initialize_while_importing: Dictionary = backend.initialize_from_save_v2({})
			var still_importing: Dictionary = backend.terrain_volume_v2_import_status(first_generation)
			check(initialize_while_importing.get("reason") == "terrain_volume_import_owner_not_drained"
				and save_initialize_while_importing.get("reason") == "terrain_volume_import_owner_not_drained",
				"New Game and Continue initialization are refused while staging data is retained")
			check(still_importing.get("status") == "pending"
				and int(still_importing.get("recordsRetained", 0)) == 100,
				"refused initialization leaves the active staging owner unchanged and drainable")
			var cancelled: Dictionary = backend.cancel_terrain_volume_v2_import(first_generation)
			check(cancelled.get("status") == "pending"
				and int(cancelled.get("recordsRetained", 0)) == 100
				and bool(cancelled.get("ownerMustBeRetainedUntilDrain", false)),
				"cancel retains owner and reports pending bounded disposal")
			var drain_started := Time.get_ticks_usec()
			var first_drain: Dictionary = backend.drain_terrain_volume_v2_import(first_generation)
			check(first_drain.get("status") == "pending"
				and int(first_drain.get("disposedItems", 0)) <= 64
				and int(first_drain.get("recordsRetained", 0)) > 0
				and is_instance_valid(backend)
				and bool(first_drain.get("ownerMustBeRetainedUntilDrain", false)),
				"first cancellation cleanup step is bounded while caller retains backend")
			var second_drain: Dictionary = backend.drain_terrain_volume_v2_import(first_generation)
			check(second_drain.get("status") == "ready" and bool(second_drain.get("cleanupComplete", false)),
				"second cancellation cleanup step releases the drained staging owner")
			var retry: Dictionary = backend.begin_terrain_volume_v2_import(identity)
			check(retry.get("status") == "pending", "new staging generation starts after disposal")
			var second_generation := int(retry.get("generation", -1))
			var stale_append: Dictionary = backend.append_terrain_volume_v2_import(
				[section_chunk(1)], first_generation)
			var stale_cancel: Dictionary = backend.cancel_terrain_volume_v2_import(first_generation)
			var stale_drain: Dictionary = backend.drain_terrain_volume_v2_import(first_generation)
			var stale_status: Dictionary = backend.terrain_volume_v2_import_status(first_generation)
			var untouched_status: Dictionary = backend.terrain_volume_v2_import_status(second_generation)
			check(stale_append.get("reason") == "stale_import_generation"
				and stale_cancel.get("reason") == "stale_import_generation"
				and stale_drain.get("reason") == "stale_import_generation"
				and stale_status.get("reason") == "stale_import_generation",
				"all calls carrying an old generation token fail without access to the new import")
			check(untouched_status.get("status") == "pending"
				and int(untouched_status.get("recordsRetained", -1)) == 0,
				"stale append/cancel/drain leave the current import active and empty")
			var cap_started := Time.get_ticks_usec()
			var cap_batch: Dictionary = backend.append_terrain_volume_v2_import(
				[section_chunk(256)], second_generation)
			var cap_wall_usec := Time.get_ticks_usec() - cap_started
			check(cap_batch.get("status") == "pending" and int(cap_batch.get("recordsRetained", 0)) == 256,
				"full 256-record per-call cap is accepted")
			var duplicate_batch: Dictionary = backend.append_terrain_volume_v2_import(
				[section_chunk(2)], second_generation)
			check(duplicate_batch.get("status") == "pending"
				and duplicate_batch.get("terminalStatus") == "failed"
				and int(duplicate_batch.get("recordsRetained", 0)) == 256
				and bool(duplicate_batch.get("ownerMustBeRetainedUntilDrain", false)),
				"rejected append retains prior data until bounded cleanup")
			var rejected_drain: Dictionary = backend.drain_terrain_volume_v2_import(second_generation)
			var disposal_steps := 1
			check(int(rejected_drain.get("disposedItems", 0)) <= 64
				and bool(rejected_drain.get("ownerMustBeRetainedUntilDrain", false)),
				"rejected append cleanup advances by at most 64 retained items per call")
			while rejected_drain.get("status") == "pending" and disposal_steps < 8:
				rejected_drain = backend.drain_terrain_volume_v2_import(second_generation)
				disposal_steps += 1
				check(int(rejected_drain.get("disposedItems", 0)) <= 64,
					"each rejected cleanup call stays within the 64-item bound")
			check(rejected_drain.get("status") == "failed"
				and bool(rejected_drain.get("cleanupComplete", false)),
				"rejected append becomes terminal only after bounded disposal completes")
			var metadata_retry: Dictionary = backend.begin_terrain_volume_v2_import(identity)
			check(metadata_retry.get("status") == "pending",
				"staging generation starts after rejected input has drained")
			var third_generation := int(metadata_retry.get("generation", -1))
			var metadata_started := Time.get_ticks_usec()
			var per_cell_metadata := metadata_at_native_node_limit()
			var per_cell_budget_batch: Dictionary = backend.append_terrain_volume_v2_import(
				[section_chunk(2, per_cell_metadata)], third_generation)
			var per_cell_metadata_wall_usec := Time.get_ticks_usec() - metadata_started
			check(per_cell_budget_batch.get("status") == "pending"
				and int(per_cell_budget_batch.get("recordsRetained", 0)) == 2,
				"each cell receives an independent 4096-node metadata budget")
			var metadata_cancel: Dictionary = backend.cancel_terrain_volume_v2_import(third_generation)
			var metadata_drain: Dictionary = backend.drain_terrain_volume_v2_import(third_generation)
			check(metadata_cancel.get("status") == "pending"
				and metadata_drain.get("status") == "ready"
				and bool(metadata_drain.get("cleanupComplete", false)),
				"per-cell metadata parity fixture drains its owner")
			report.timing = {"beginAndAppendElapsedUsec": Time.get_ticks_usec() - started,
				"appendCallUsec": append_wall_usec,
				"capAppendCallUsec": cap_wall_usec,
				"perCellBudgetBatchCallUsec": per_cell_metadata_wall_usec,
				"firstDrainUsec": Time.get_ticks_usec() - drain_started,
				"rejectedDisposalSteps": disposal_steps,
				"adapterParseUsec": accepted.get("parseUsec", -1),
				"nativeAppendUsec": accepted.get("appendUsec", -1)}

		var staged_methods := ["begin_staged_save_v2_initialization",
			"start_staged_save_v2_finalization", "staged_save_v2_initialization_status",
			"cancel_staged_save_v2_initialization", "drain_staged_save_v2_initialization",
			"commit_staged_save_v2_initialization"]
		var staged_available := true
		for method in staged_methods:
			check(backend.has_method(method), "staged binding exists: " + method)
			staged_available = staged_available and backend.has_method(method)
		if staged_available:
			var seed := "staged-import-adapter-contract"
			var source_request := staged_source_request(seed)
			var expected_volume := {"schemaVersion": 1, "sectionSize": 16, "revision": 9,
				"sections": [section_chunk(156, {}, 0)]}
			var oracle_request: Dictionary = source_request.duplicate(true)
			oracle_request["schema"] = "n3-native-world-backend-initialize-from-save-v2/v1"
			oracle_request["terrainVolume"] = expected_volume
			var oracle = ClassDB.instantiate("NativeWorldBackend")
			var oracle_ready: bool = oracle != null and oracle.initialize_from_save_v2(oracle_request).get("status") == "ready"
			check(oracle_ready, "sync v2 initializer remains a usable parity oracle")
			var identity := {"domain": "terrainVolume", "schemaVersion": 1,
				"sectionSize": 16, "revision": 9}
			var staged = ClassDB.instantiate("NativeWorldBackend")
			var staged_begin: Dictionary = staged.begin_staged_save_v2_initialization(source_request, identity)
			var staged_generation := int(staged_begin.get("generation", -1))
			check(staged_begin.get("status") == "pending" and staged_generation > 0
				and staged_begin.get("finalizeAvailable") == true,
				"staged initialization captures source/site metadata and opens bounded import")
			var first_part: Dictionary = staged.append_terrain_volume_v2_import(
				[section_chunk(100, {}, 0)], staged_generation)
			var second_part: Dictionary = staged.append_terrain_volume_v2_import(
				[section_chunk(56, {}, 100)], staged_generation)
			check(first_part.get("status") == "pending" and second_part.get("status") == "pending"
				and int(second_part.get("recordsRetained", 0)) == 156,
				"typed cell records append across calls while preserving one section revision")
			var competing_initialize: Dictionary = staged.initialize(source_request)
			var competing_save_initialize: Dictionary = staged.initialize_from_save_v2(oracle_request)
			check(competing_initialize.get("reason") == "terrain_volume_import_owner_not_drained"
				and competing_save_initialize.get("reason") == "terrain_volume_import_owner_not_drained"
				and staged.staged_save_v2_initialization_status(staged_generation).get("status") == "pending",
				"sync initializer paths are gated while staged import owns the backend, without consuming one-shot")
			var finalize_started: Dictionary = staged.start_staged_save_v2_finalization(staged_generation)
			check(finalize_started.get("status") == "pending"
				and finalize_started.get("ownerMustBeRetainedUntilDrain") == true,
				"finalize transfers owned POD to worker and retains backend owner")
			check(staged.status().get("status") == "uninitialized",
				"candidate state is not visible through backend before explicit commit")
			var staged_status: Dictionary = staged.staged_save_v2_initialization_status(staged_generation)
			var finalize_poll_count := 0
			while staged_status.get("status") == "pending" and finalize_poll_count < 1200:
				await process_frame
				staged_status = staged.staged_save_v2_initialization_status(staged_generation)
				finalize_poll_count += 1
			check(staged_status.get("status") == "ready"
				and staged_status.get("reason") == "candidate_ready_for_explicit_commit"
				and staged_status.get("candidateVisible") == true
				and staged.status().get("status") == "uninitialized",
				"worker candidate completes privately without precommit backend visibility")
			var wrong_commit: Dictionary = staged.commit_staged_save_v2_initialization(
				staged_generation, {"algorithm": "sha256", "hex": "0000000000000000000000000000000000000000000000000000000000000000"})
			check(wrong_commit.get("status") == "failed"
				and staged.status().get("status") == "uninitialized",
				"source identity mismatch fails atomically and does not publish candidate")
			var failed_cleanup: Dictionary = staged.drain_staged_save_v2_initialization(staged_generation)
			var cleanup_polls := 0
			while failed_cleanup.get("status") == "pending" and cleanup_polls < 1200:
				await process_frame
				failed_cleanup = staged.drain_staged_save_v2_initialization(staged_generation)
				cleanup_polls += 1
			check(failed_cleanup.get("cleanupComplete") == true,
				"mismatched candidate is worker-disposed and import sentinel drains before retry")
			var retry_begin: Dictionary = staged.begin_staged_save_v2_initialization(source_request, identity)
			var retry_generation := int(retry_begin.get("generation", -1))
			check(retry_begin.get("status") == "pending" and retry_generation > staged_generation,
				"new generation starts only after failed candidate owner has drained")
			staged.append_terrain_volume_v2_import([section_chunk(156)], retry_generation)
			staged.start_staged_save_v2_finalization(retry_generation)
			staged_status = staged.staged_save_v2_initialization_status(retry_generation)
			finalize_poll_count = 0
			while staged_status.get("status") == "pending" and finalize_poll_count < 1200:
				await process_frame
				staged_status = staged.staged_save_v2_initialization_status(retry_generation)
				finalize_poll_count += 1
			var expected_identity: Dictionary = staged_status.get("candidateSourceIdentity", {})
			var committed: Dictionary = staged.commit_staged_save_v2_initialization(
				retry_generation, expected_identity)
			check(staged_status.get("status") == "ready" and committed.get("status") == "ready"
				and committed.get("committed") == true
				and staged.export_terrain_volume_v2().get("terrainVolume", {})
				== oracle.export_terrain_volume_v2().get("terrainVolume", {}),
				"explicit source-checked commit exports the same v2 volume as sync initializer")
			check(staged.export_terrain_volume_v2().get("sourceIdentity", {})
				== oracle.export_terrain_volume_v2().get("sourceIdentity", {}),
				"staged commit preserves the sync initializer's authoritative source identity")
			var post_commit_begin: Dictionary = staged.begin_staged_save_v2_initialization(
				source_request, identity)
			check(post_commit_begin.get("status") == "failed"
				and post_commit_begin.get("reason") == "backend_initialization_already_started",
				"explicit staged commit consumes the same one-shot initialization right as sync init")

			var rejection_owner = ClassDB.instantiate("NativeWorldBackend")
			var rejection_begin: Dictionary = rejection_owner.begin_staged_save_v2_initialization(
				source_request, identity)
			var rejection_generation := int(rejection_begin.get("generation", -1))
			rejection_owner.append_terrain_volume_v2_import([section_chunk(1)], rejection_generation)
			var malformed_chunk := section_chunk(1)
			malformed_chunk["cells"][0]["local"] = [1, 0, 0]
			var rejected_append: Dictionary = rejection_owner.append_terrain_volume_v2_import(
				[malformed_chunk], rejection_generation)
			var rejection_status: Dictionary = rejection_owner.staged_save_v2_initialization_status(
				rejection_generation)
			check(rejected_append.get("status") == "pending"
				and rejected_append.get("terminalStatus") == "failed"
				and rejection_status.get("status") == "failed"
				and rejection_status.get("candidateVisible") == false
				and rejection_owner.status().get("status") == "uninitialized",
				"malformed append is terminal failure with retained owner and no candidate publication")
			var rejection_drain: Dictionary = rejection_owner.drain_staged_save_v2_initialization(
				rejection_generation)
			var rejection_polls := 0
			while rejection_drain.get("status") == "pending" and rejection_polls < 1200:
				await process_frame
				rejection_drain = rejection_owner.drain_staged_save_v2_initialization(
					rejection_generation)
				rejection_polls += 1
			check(rejection_drain.get("cleanupComplete") == true
				and rejection_drain.get("reason") == "terrainVolume import cell address is inconsistent"
				and rejection_owner.status().get("status") == "uninitialized",
				"rejected append preserves its cause through bounded owner drain")
			var retry_after_rejection: Dictionary = rejection_owner.begin_staged_save_v2_initialization(
				source_request, identity)
			check(retry_after_rejection.get("status") == "pending",
				"rejected uncommitted generation may retry only after cleanup acknowledgement")
			var rejection_retry_generation := int(retry_after_rejection.get("generation", -1))
			rejection_owner.cancel_staged_save_v2_initialization(rejection_retry_generation)
			rejection_owner.drain_staged_save_v2_initialization(rejection_retry_generation)

			var cancel_owner = ClassDB.instantiate("NativeWorldBackend")
			var cancel_begin: Dictionary = cancel_owner.begin_staged_save_v2_initialization(source_request, identity)
			var cancel_generation := int(cancel_begin.get("generation", -1))
			cancel_owner.append_terrain_volume_v2_import([section_chunk(256)], cancel_generation)
			cancel_owner.start_staged_save_v2_finalization(cancel_generation)
			var cancel_ack: Dictionary = cancel_owner.cancel_staged_save_v2_initialization(cancel_generation)
			check(cancel_ack.get("status") == "pending"
				and cancel_ack.get("ownerMustBeRetainedUntilDrain") == true
				and is_instance_valid(cancel_owner),
				"active finalize cancellation retains backend until worker acknowledgement")
			var cancel_drain: Dictionary = cancel_owner.drain_staged_save_v2_initialization(cancel_generation)
			var cancel_polls := 0
			while cancel_drain.get("status") == "pending" and cancel_polls < 1200:
				check(is_instance_valid(cancel_owner), "cancelled worker owner remains strongly retained during drain")
				await process_frame
				cancel_drain = cancel_owner.drain_staged_save_v2_initialization(cancel_generation)
				cancel_polls += 1
			check(cancel_drain.get("cleanupComplete") == true and is_instance_valid(cancel_owner)
				and cancel_owner.status().get("status") == "uninitialized",
				"cancel releases no candidate and reports drained only after worker/disposal acknowledgement")
			var retry_after_cancel: Dictionary = cancel_owner.begin_staged_save_v2_initialization(
				source_request, identity)
			check(retry_after_cancel.get("status") == "pending",
				"cancelled owner accepts a new generation only after acknowledged drain")
			var retry_cancel_generation := int(retry_after_cancel.get("generation", -1))
			var stale_append: Dictionary = cancel_owner.append_terrain_volume_v2_import(
				[section_chunk(1)], cancel_generation)
			var stale_cancel: Dictionary = cancel_owner.cancel_staged_save_v2_initialization(cancel_generation)
			var stale_drain: Dictionary = cancel_owner.drain_staged_save_v2_initialization(cancel_generation)
			var stale_status: Dictionary = cancel_owner.staged_save_v2_initialization_status(cancel_generation)
			var current_status: Dictionary = cancel_owner.staged_save_v2_initialization_status(
				retry_cancel_generation)
			check(stale_append.get("reason") == "stale_import_generation"
				and stale_cancel.get("reason") == "stale_import_generation"
				and stale_drain.get("reason") == "stale_import_generation"
				and stale_status.get("reason") == "stale_import_generation"
				and current_status.get("status") == "pending"
				and int(current_status.get("recordsRetained", -1)) == 0,
				"stale generation calls cannot append to, cancel, or drain a newer staged owner")
			cancel_owner.cancel_staged_save_v2_initialization(retry_cancel_generation)
			var retry_cancel_drain: Dictionary = cancel_owner.drain_staged_save_v2_initialization(
				retry_cancel_generation)
			check(retry_cancel_drain.get("cleanupComplete") == true,
				"empty retry transaction can be cancelled and disposed")
			backend = null
			staged = null
			cancel_owner = null
			oracle = null
			rejection_owner = null
	await process_frame
	report.failures = failures
	report.passed = failures.is_empty()
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if bool(report.passed) else 1)

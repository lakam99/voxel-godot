extends SceneTree

var failures: Array[String] = []


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


func section_chunk(cell_count: int, metadata_override: Dictionary = {}) -> Dictionary:
	var cells: Array = []
	for index in range(cell_count):
		var cell := [index % 16, int(index / 16), 0]
		var local := cell.duplicate()
		cells.append({"cell": cell, "local": local, "state": cell_state(metadata_override)})
	return {"schemaVersion": 1, "sectionKey": [0, 0, 0], "originCell": [0, 0, 0],
		"revision": 7, "cells": cells}


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
		backend = null
	await process_frame
	report.failures = failures
	report.passed = failures.is_empty()
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if bool(report.passed) else 1)

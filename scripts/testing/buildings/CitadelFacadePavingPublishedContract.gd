extends "res://scripts/testing/buildings/CitadelFacadePublishedContract.gd"

## Full real publication cycles, CPU argument/node matching only. No renderer
## readback, automatic contact approval, geometry replacement or source edits.
const APPROVED_CANDIDATE_SHA := "4fdf12e4b702efd29eac03532e64b93d4d28e6e06bbfabe09fd07884e5a1f31b"
const CycleBlueprint := preload("res://scripts/buildings/BuildingBlueprint.gd")
const CPU_CAPTURE_STAGES := ["before_standard", "after_standard", "before_static", "after_static"]
# Separate from the immutable source's 32 MiB bound. Encoded size is measured
# before writing; this is a fixed ceiling, not permission to grow on failure.
const MAX_CPU_ARTIFACT_BYTES := 256 * 1024 * 1024
const MAX_CPU_VALUE_VISITS := 16000000

class CyclePublisher:
	extends "res://scripts/buildings/BuildingPartPublisher.gd"
	var budget: Callable
	var record_limit: int = 0
	var error: String = ""
	var active_owner: String = ""
	var active_label: String = ""
	var ordinals: Dictionary = {}
	var captures: Dictionary = {} # Retained live mesh-node keys, checked later.
	var pending_owners: Dictionary = {} # Same material grouping as real flush.
	var flushing: bool = false
	var recorded: int = 0
	var scanned_nodes: int = 0
	var flushes: int = 0

	func _allowed() -> bool:
		return error.is_empty() and budget.is_valid() and bool(budget.call())

	func _identity(label: String) -> Dictionary:
		if not _allowed() or active_owner.is_empty() or recorded >= record_limit:
			error = "capture_owner_or_budget"
			return {}
		var ordinal: int = ordinals.get(active_owner, 0)
		ordinals[active_owner] = ordinal + 1
		recorded += 1
		return {"owner": active_owner, "ordinal": ordinal, "label": label}

	func publish_part(part, parent: Node3D) -> StaticBody3D:
		if not _allowed(): return null
		active_owner = part.id
		var first: int = parent.get_child_count()
		var result: StaticBody3D = super.publish_part(part, parent)
		# Covers direct meshes (cloth/ground detail) that bypass visual helpers.
		# Previously existing shared static nodes are audited in the final walk.
		for index in range(first, parent.get_child_count()): _scan_new(parent.get_child(index), 0)
		active_owner = ""
		return result

	func _scan_new(node: Node, depth: int) -> void:
		scanned_nodes += 1
		if not _allowed() or depth > 64 or scanned_nodes > 1000000:
			error = "capture_tree_budget"
			return
		if node is MeshInstance3D and not captures.has(node): _record_mesh(node, String(node.name))
		for child in node.get_children(): _scan_new(child, depth + 1)

	func _record_mesh(node: MeshInstance3D, label: String) -> void:
		var identity: Dictionary = _identity(label)
		if identity.is_empty(): return
		captures[node] = {"kind": "mesh", "node": node, "mesh": node.mesh, "parent": node.get_parent(),
			"nodeTransform": node.transform, "identities": [identity], "material": node.material_override, "matched": false}

	func add_box_visual(parent: Node3D, size: Vector3, position: Vector3, material: Material, label: String) -> void:
		var prior: String = active_label
		active_label = label
		var first: int = parent.get_child_count()
		super.add_box_visual(parent, size, position, material, label)
		if not static_visual_collecting:
			if parent.get_child_count() != first + 1 or not parent.get_child(first) is MeshInstance3D: error = "box_node_missing"
			else: _record_mesh(parent.get_child(first), label)
		active_label = prior

	func add_mesh_visual(parent: Node3D, mesh: Mesh, size: Vector3, position: Vector3, material: Material, label: String) -> void:
		var first: int = parent.get_child_count()
		super.add_mesh_visual(parent, mesh, size, position, material, label)
		if parent.get_child_count() != first + 1 or not parent.get_child(first) is MeshInstance3D: error = "mesh_node_missing"
		else: _record_mesh(parent.get_child(first), label)

	func collect_static_visual_transform(transform: Transform3D, material: Material, custom := Color(0.5, 0.5, 0.5, 1.0)) -> void:
		var identity: Dictionary = _identity(active_label)
		if not identity.is_empty() and material != null:
			var key: String = str(material.get_instance_id())
			if not pending_owners.has(key): pending_owners[key] = []
			pending_owners[key].append({"identity": identity, "transform": transform, "custom": custom})
		elif material == null: error = "null_static_material"
		super.collect_static_visual_transform(transform, material, custom)

	func add_box_batch(parent: Node3D, transforms: Array, material: Material, label: String, custom: Array = []) -> MultiMeshInstance3D:
		var collecting: bool = static_visual_collecting
		var prior: String = active_label
		active_label = label
		var result: MultiMeshInstance3D = super.add_box_batch(parent, transforms, material, label, custom)
		active_label = prior
		if collecting or transforms.is_empty(): return result
		var values: Array = custom.duplicate() if custom.size() == transforms.size() else build_batch_custom_data(transforms)
		var identities: Array = []
		if flushing:
			var key: String = str(material.get_instance_id())
			var owners: Array = pending_owners.get(key, [])
			if owners.size() != transforms.size(): error = "static_flush_owner_count"
			else:
				for index in range(owners.size()):
					if owners[index].transform != transforms[index] or owners[index].custom != values[index]: error = "static_flush_payload_order"
					identities.append(owners[index].identity)
			pending_owners.erase(key)
		else:
			for ignored in transforms: identities.append(_identity(label))
		_record_batch(result, parent, unit_box, transforms.duplicate(), values, material, identities)
		return result

	func add_mesh_batch(parent: Node3D, mesh: Mesh, transforms: Array, material: Material, label: String, custom: Array = []) -> MultiMeshInstance3D:
		var represented: Array = []
		for transform in transforms: represented.append(static_visual_part_transform * transform if static_visual_collecting else transform)
		var result: MultiMeshInstance3D = super.add_mesh_batch(parent, mesh, transforms, material, label, custom)
		if transforms.is_empty() or mesh == null: return result
		var values: Array = custom.duplicate() if custom.size() == transforms.size() else build_batch_custom_data(transforms)
		var identities: Array = []
		for ignored in transforms: identities.append(_identity(label))
		_record_batch(result, parent, mesh, represented, values, material, identities)
		return result

	func _record_batch(node: MultiMeshInstance3D, parent: Node3D, mesh: Mesh, transforms: Array, custom: Array, material: Material, identities: Array) -> void:
		if node == null or identities.size() != transforms.size() or identities.any(func(value): return value.is_empty()):
			error = "batch_node_or_identity_missing"
			return
		captures[node] = {"kind": "batch", "node": node, "parent": parent, "mesh": mesh, "nodeTransform": node.transform,
			"transforms": transforms, "custom": custom, "identities": identities, "material": material, "matched": false}

	func flush_static_batches(parent: Node3D) -> void:
		flushing = true
		var had_work: bool = not static_visual_batches.is_empty()
		super.flush_static_batches(parent)
		if had_work: flushes += 1
		flushing = false
		if not pending_owners.is_empty(): error = "unflushed_static_ownership"

var _cycle_meshes: Dictionary = {}
var _cycle_mesh_facts: Dictionary = {} # Retained immutable published Mesh keys.
var _finish_ids: Array = []
var _cycle_report_path: String = ""
var _cut_pair_tests: int = 0
var _checkpoint_capture: bool = false
var _cpu_value_visits: int = 0

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	_cycle_report_path = OS.get_environment("VOXEL_FACADE_PAVING_PUBLISHED_REPORT")
	var stage: String = OS.get_environment("VOXEL_FACADE_PAVING_STAGE")
	if stage.is_empty(): stage = "full"
	var input: String = OS.get_environment("VOXEL_FACADE_PAVING_CANDIDATE")
	var expected: String = OS.get_environment("VOXEL_FACADE_PAVING_CANDIDATE_SHA256")
	if not _cycle_report_path.is_absolute_path() or _cycle_report_path.get_extension() != "json" or FileAccess.file_exists(_cycle_report_path) or not DirAccess.dir_exists_absolute(_cycle_report_path.get_base_dir()):
		quit(2)
		return
	var report: Dictionary = {"passed": false, "diagnosticCompleted": false, "publicationAcceptance": false, "modes": [],
		"requestedStage": stage, "requestedStageCompleted": false,
		"evidenceLevel": "actual_full_source_CPU_publication_cycles_not_live_acceptance", "inputPath": input, "inputSha256": expected,
		"limits": {"softMsec": SOFT_LIMIT_MSEC, "sourceParts": MAX_SOURCE_PARTS, "publishedPrimitives": MAX_PUBLISHED_PRIMITIVES,
			"primitiveTests": MAX_PRIMITIVE_TESTS, "recordedContacts": MAX_RECORDED_CONTACTS, "nodes": MAX_COLLECTED_NODES},
		"doesNotProve": "No GPU buffer readback, shader execution, headed appearance, live collision/movement, navigation or automatic contact acceptance. Budgets accumulate over all four publication cycles."}
	if stage not in ["full", "standard_parity"] and stage not in CPU_CAPTURE_STAGES:
		_finish_cycle_report(report, "invalid_requested_stage")
		return
	if expected != APPROVED_CANDIDATE_SHA or not input.is_absolute_path() or FileAccess.get_sha256(input) != expected:
		_finish_cycle_report(report, "immutable_candidate_sha_mismatch")
		return
	var file: FileAccess = FileAccess.open(input, FileAccess.READ)
	if file == null or file.get_length() <= 0 or file.get_length() > MAX_ARTIFACT_BYTES:
		_finish_cycle_report(report, "candidate_size_or_open")
		return
	var length: int = file.get_length()
	var bytes: PackedByteArray = file.get_buffer(length)
	var complete: bool = bytes.size() == length and file.get_error() == OK
	file.close()
	var archive: Variant = bytes_to_var(bytes)
	if not complete or not _valid_assembly_archive(archive) or var_to_bytes(archive) != bytes:
		_finish_cycle_report(report, "candidate_schema_or_raw_digest")
		return
	report["fixture"] = archive.fixture
	_finish_ids = archive.pavingFinishPartIds.duplicate()
	report["sourceDigests"] = {"before": archive.sourceDigest, "after": archive.afterDigest, "policy": archive.policyDigest}
	var identity: Dictionary = _check_contract_identity(archive.contractIdentity)
	report["contractIdentity"] = identity
	if not identity.exact:
		_finish_cycle_report(report, "frozen_contract_identity_changed")
		return
	report["collectorControls"] = _collector_controls()
	if not report.collectorControls.passed or not _within_budget():
		_finish_cycle_report(report, "collector_controls_or_budget")
		return
	if stage in CPU_CAPTURE_STAGES:
		_run_checkpoint(archive, report, stage, input, expected)
		return
	var modes: Array = [false, true] if stage == "full" else [false]
	for static_mode in modes:
		if not _within_budget(): break
		var mode: String = "static" if static_mode else "standard"
		var before: Dictionary = _publication_cycle(archive.beforeSnapshot, static_mode, mode + ":before")
		var after: Dictionary = _publication_cycle(archive.afterSnapshot, static_mode, mode + ":after") if bool(before.get("complete", false)) and _within_budget() else {"complete": false}
		if not bool(before.get("complete", false)) or not bool(after.get("complete", false)):
			report.modes.append({"mode": mode, "complete": false, "beforeCycle": before.get("lifecycle", {}), "afterCycle": after.get("lifecycle", {})})
			break
		var result: Dictionary = _compare_mode(archive, before, after, mode, stage == "full")
		report.modes.append(result)
		_cycle_meshes.clear()
		_cycle_mesh_facts.clear()
		if not result.complete: break
	var identity_after: Dictionary = _check_contract_identity(archive.contractIdentity)
	report["postContractIdentity"] = identity_after
	report["immutableInputUnchanged"] = FileAccess.get_sha256(input) == expected
	report.requestedStageCompleted = report.modes.size() == modes.size() and report.modes.all(func(mode): return mode.complete) and identity_after.exact and report.immutableInputUnchanged and _within_budget()
	report.diagnosticCompleted = stage == "full" and report.requestedStageCompleted
	report["outstandingCoverage"] = ["static_before_after_lifecycle_and_parity", "both_modes_all_new_member_contacts"] if stage == "standard_parity" else []
	_finish_cycle_report(report, ("contact_review_required" if stage == "full" else "standard_parity_complete_static_and_contacts_pending") if report.requestedStageCompleted else "incomplete_or_parity_failed")

func _run_checkpoint(archive: Dictionary, report: Dictionary, stage: String, input: String, expected: String) -> void:
	var output: String = OS.get_environment("VOXEL_FACADE_PAVING_CPU_EXPORT")
	report["bindingCaptureControls"] = _binding_capture_controls()
	if not report.bindingCaptureControls.passed:
		_finish_cycle_report(report, "binding_capture_ownership_controls_failed")
		return
	report["limits"]["cpuArtifactBytes"] = MAX_CPU_ARTIFACT_BYTES
	report["limits"]["cpuValueVisits"] = MAX_CPU_VALUE_VISITS
	report["fixture"] = {"digest": archive.fixtureDigest}
	report["doesNotProve"] = "One CPU lifecycle checkpoint only; four bound checkpoints, original/finish/furniture parity and complete contacts remain required. No live or contact acceptance. Per-run budgets unchanged."
	report["outstandingCoverage"] = ["four_matching_cycle_checkpoints", "both_modes_original_and_finish_parity", "both_modes_152_furnishings_parity", "both_modes_all_seven_members_contacts", "external_contact_review"]
	if not output.is_absolute_path() or output.get_extension() != "bin" or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()):
		_finish_cycle_report(report, "fresh_absolute_cpu_export_required")
		return
	var code_identity: Dictionary = _checkpoint_code_identity()
	if code_identity.is_empty():
		_finish_cycle_report(report, "checkpoint_dependency_identity_failed")
		return
	var static_mode: bool = stage.ends_with("_static")
	var side: String = "before" if stage.begins_with("before_") else "after"
	var mode: String = "static" if static_mode else "standard"
	var snapshot: Dictionary = archive.beforeSnapshot if side == "before" else archive.afterSnapshot
	_checkpoint_capture = true
	var cycle: Dictionary = _publication_cycle(snapshot, static_mode, mode + ":" + side)
	_checkpoint_capture = false
	# Keep bulky physical reports and raw global ownership paths ONLY in binary.
	report["cycle"] = _compact_checkpoint_cycle(cycle)
	if not bool(cycle.get("complete", false)) or not _within_budget():
		_finish_cycle_report(report, "cycle_capture_incomplete")
		return
	var furniture: Dictionary = {}
	var plan = FurnishingPlanScript.new(archive.furnitureSnapshot.id, int(archive.furnitureSnapshot.seed), archive.furnitureSnapshot.sourceBlueprintId)
	for record in archive.furnitureSnapshot.parts: plan.add_part(record)
	var furnisher = Furnisher.new()
	for part in plan.parts:
		if not _within_budget(): break
		var payload: Dictionary = _furnishing_payload(furnisher, part)
		if not _valid_payload(payload.visual) or not _valid_payload(payload.collision): break
		furniture[part.id] = payload
	report["furnitureCaptureCount"] = furniture.size()
	if furniture.size() != 152 or not _within_budget():
		_finish_cycle_report(report, "furniture_capture_incomplete")
		return
	var checkpoint: Dictionary = {"schemaVersion": 1, "provenance": "successful_facade_paving_CPU_cycle_capture",
		"stage": stage, "mode": mode, "side": side, "captureComplete": true, "publicationAcceptance": false,
		"candidateSha256": expected, "sourceDigest": archive.sourceDigest, "afterDigest": archive.afterDigest,
		"fixtureDigest": archive.fixtureDigest, "policyDigest": archive.policyDigest, "furnitureDigest": archive.furnitureDigest,
		"reservationDigest": archive.reservationDigest, "contractIdentity": archive.contractIdentity,
		"implementationIdentity": code_identity, "memberIds": archive.memberIds, "partIds": archive.partIds,
		"pavingFinishPartIds": archive.pavingFinishPartIds, "cycle": cycle, "furniturePayloads": furniture,
		"counts": _counts.duplicate(true), "extractionWork": _work.duplicate(true), "limits": report.limits,
		"captureElapsedMsec": Time.get_ticks_msec() - _started_msec,
		"digestEncoding": "sha256(raw var_to_bytes bytes); no Objects or Resource IDs"}
	_cpu_value_visits = 0
	if not _checkpoint_value_only(checkpoint, 0) or not _within_budget():
		_finish_cycle_report(report, "cpu_payload_not_value_only_or_budget")
		return
	var encoded: PackedByteArray = var_to_bytes(checkpoint)
	report["cpuArtifactBytes"] = encoded.size()
	report["cpuValueVisits"] = _cpu_value_visits
	if encoded.is_empty() or encoded.size() > MAX_CPU_ARTIFACT_BYTES or not _within_budget():
		_finish_cycle_report(report, "cpu_artifact_size_or_budget")
		return
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(encoded)
	var digest: String = hash.finish().hex_encode()
	report["immutableInputUnchanged"] = FileAccess.get_sha256(input) == expected
	var identity_ok: bool = _check_contract_identity(archive.contractIdentity).exact and code_identity == _checkpoint_code_identity()
	report["implementationAndSourceIdentityUnchanged"] = identity_ok
	if not report.immutableInputUnchanged or not identity_ok or not _within_budget():
		_finish_cycle_report(report, "checkpoint_input_changed_or_budget")
		return
	# Recheck freshness immediately before opening; never overwrite old evidence.
	if FileAccess.file_exists(output):
		_finish_cycle_report(report, "cpu_export_already_exists")
		return
	var destination: FileAccess = FileAccess.open(output, FileAccess.WRITE)
	if destination == null:
		_finish_cycle_report(report, "cpu_export_open_failed")
		return
	destination.store_buffer(encoded)
	destination.flush()
	var written: bool = destination.get_error() == OK and destination.get_position() == encoded.size()
	destination.close()
	report["cpuArtifactPath"] = output
	report["cpuArtifactSha256"] = digest
	report["requestedStageCompleted"] = written and FileAccess.get_sha256(output) == digest and _within_budget()
	# Capture completion never stands in for the unperformed comparison gate.
	_finish_cycle_report(report, "cycle_export_complete_aggregation_pending" if report.requestedStageCompleted else "cpu_export_incomplete")

func _binding_capture_controls() -> Dictionary:
	# Service-level ownership control using actual publisher cleanup, not live
	# gameplay evidence. The actual capture also rechecks every retained digest.
	var publisher: CyclePublisher = CyclePublisher.new()
	publisher._paving_binding = PackedByteArray([1, 3, 5, 7])
	var retained: PackedByteArray = publisher._paving_binding.duplicate()
	var expected: String = _raw_digest(retained)
	publisher.clear_published()
	var checks: Dictionary = {
		"publisher_binding_cleared": publisher._paving_binding.is_empty(),
		"owned_capture_survives_cleanup": retained.size() == 4 and _raw_digest(retained) == expected
	}
	var altered: PackedByteArray = retained.duplicate()
	altered[0] = 2
	checks["altered_binding_rejected"] = _raw_digest(altered) != expected
	checks["original_unchanged_by_negative"] = _raw_digest(retained) == expected
	return {"passed": checks.values().all(func(value): return value == true), "checks": checks,
		"evidenceLevel": "publisher_cleanup_ownership_contract_not_gameplay"}

func _compact_checkpoint_cycle(cycle: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var lifecycle: Dictionary = cycle.get("lifecycle", {})
	for key in ["phase", "complete", "inputDigest", "copyExact", "beginReady", "beginElapsedMsec", "postValidationDigest", "postPublicationDigest", "sourceStableAfterValidation", "committedJointsUnchanged", "captureError", "capturePrimitiveCount", "staticFlushCount", "emittedParts", "elapsedMsec"]:
		if lifecycle.has(key): result[key] = lifecycle[key]
	result["matchedNodeCount"] = cycle.get("rawNodes", []).size()
	result["sourcePayloadCount"] = cycle.get("payloads", {}).size()
	result["finishVerificationComplete"] = cycle.get("finishValues", {}).get("complete", false)
	result["finishFailure"] = cycle.get("finishValues", {}).get("reason", "")
	return result

func _checkpoint_code_identity() -> Dictionary:
	# Bound the actual preloaded script closure, including inherited collectors,
	# publication, materials, source validation and furniture implementation.
	var pending: Array = [get_script(), load("res://scripts/buildings/BuildingPartPublisher.gd"), Furnisher, CycleBlueprint]
	var visited: Dictionary = {}
	var hashes: Dictionary = {}
	while not pending.is_empty():
		if not _within_budget() or visited.size() >= 512: return {}
		var script: Script = pending.pop_back()
		if script == null or visited.has(script): continue
		visited[script] = true
		var path: String = script.resource_path.get_slice("::", 0)
		if not path.is_empty():
			var digest: String = FileAccess.get_sha256(path)
			if digest.length() != 64: return {}
			hashes[path] = digest
		var base: Script = script.get_base_script()
		if base != null: pending.append(base)
		for value in script.get_script_constant_map().values():
			if value is Script: pending.append(value)
	return hashes

func _checkpoint_value_only(value: Variant, depth: int) -> bool:
	_cpu_value_visits += 1
	if depth > 64 or _cpu_value_visits > MAX_CPU_VALUE_VISITS: return false
	if _cpu_value_visits % 1024 == 0 and not _within_budget(): return false
	if typeof(value) in [TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID]: return false
	if value is Dictionary:
		for key in value:
			if not _checkpoint_value_only(key, depth + 1) or not _checkpoint_value_only(value[key], depth + 1): return false
	elif value is Array:
		for item in value:
			if not _checkpoint_value_only(item, depth + 1): return false
	return true

func _checkpoint_finish_values(payloads: Dictionary, artifacts: Dictionary, bindings: Dictionary, phase: String, static_mode: bool) -> Dictionary:
	var result: Dictionary = {"complete": false, "reason": "finish_mesh_or_frame_mismatch", "artifacts": {}, "emitted": {}}
	for id in _finish_ids:
		if not payloads.has(id) or not _within_budget(): return result
		var primitives: Array = payloads[id].visual.primitives
		var emitted: Array = []
		for primitive in primitives:
			var actual: Dictionary = _cycle_meshes.get(phase + ":" + id + ":" + primitive.id, {})
			if actual.is_empty() or not _within_budget(): return result
			emitted.append({"primitiveId": primitive.id, "transform": actual.transform, "arrays": actual.arrays,
				"arraysDigest": _raw_digest(actual.arrays)})
		result.emitted[id] = emitted
		if not artifacts.has(id): continue # Original uncut publication has no prepared cut artifact.
		if not bindings.get(id) is PackedByteArray or bindings[id].is_empty(): return result
		var artifact: Dictionary = artifacts[id]
		if not artifact.get("completed", false) or artifact.get("stage") != "represented_publication_geometry": return result
		var wired: Dictionary = artifact.duplicate()
		wired["entries"] = []
		var index: int = 0
		for entry in artifact.entries:
			if not _within_budget(): return result
			var row: Dictionary = entry.duplicate()
			row.erase("mesh")
			if not entry.unchanged and entry.mesh == null:
				if not entry.cells.is_empty(): return result
				row["emissionProof"] = {"removed": true, "noMeshAndNoCells": true}
				wired.entries.append(row)
				continue
			if index >= primitives.size(): return result
			var primitive: Dictionary = primitives[index]
			var actual: Dictionary = _cycle_meshes[phase + ":" + id + ":" + primitive.id]
			index += 1
			var expected_custom: Variant = entry.original.customData
			if entry.original.group == "bed": expected_custom = Color(0.5, 0.5, 0.5, 1.0) if static_mode else null
			if primitive.transform != entry.original.transform or actual.transform != entry.original.transform or primitive.customData != expected_custom: return result
			var proof: Dictionary = {"primitiveId": primitive.id, "frameExact": true, "customExact": true, "native": entry.unchanged}
			if entry.unchanged:
				if not actual.mesh is BoxMesh or actual.mesh.size != Vector3.ONE: return result
			else:
				if not entry.mesh is ArrayMesh or actual.mesh != entry.mesh or entry.mesh.get_surface_count() != 1 or actual.arrays.size() != 1: return result
				var prepared: Array = entry.mesh.surface_get_arrays(0)
				if var_to_bytes(prepared) != var_to_bytes(actual.arrays[0]): return result
				var cells: Dictionary = _represented_cells(entry, primitive, actual.arrays[0])
				if not cells.valid: return result
				row["preparedMeshArrays"] = [prepared]
				row["preparedMeshArraysDigest"] = _raw_digest([prepared])
				proof["liveResourceIdentityExact"] = true
				proof["preparedEmittedArraysExact"] = true
				proof["representedCellBounds"] = cells.bounds
			row["emissionProof"] = proof
			wired.entries.append(row)
		if index != primitives.size(): return result
		wired["sourceBindingDigest"] = _raw_digest(bindings[id])
		result.artifacts[id] = wired
	if phase.ends_with(":after") and result.artifacts.size() != _finish_ids.size(): return result
	result.complete = true
	result.reason = ""
	return result

func _raw_digest(value: Variant) -> String:
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(value))
	return hash.finish().hex_encode()

func _valid_assembly_archive(value: Variant) -> bool:
	if not value is Dictionary or value.get("provenance") != "successful_complete_facade_paving_assembly_contract" or value.get("sourceContractPassed") != true or value.get("publicationAcceptance") != false: return false
	var shape: Dictionary = value.duplicate()
	shape.provenance = "successful_full_facade_recipe_contract" # Reuse ID/shape checks ONLY.
	if not _valid_facade_archive(shape) or value.partIds.size() != 7 or value.furnitureSnapshot.parts.size() != 152: return false
	if not value.get("pavingFinishPartIds") is Array or value.pavingFinishPartIds.is_empty() or value.pavingFinishPartIds.size() > 4 or not value.get("contractIdentity") is Dictionary or value.contractIdentity.is_empty(): return false
	for mapping in [["beforeSnapshot", "sourceDigest"], ["afterSnapshot", "afterDigest"], ["policy", "policyDigest"], ["fixture", "fixtureDigest"], ["furnitureSnapshot", "furnitureDigest"], ["protectedReservations", "reservationDigest"]]:
		if not value.has(mapping[0]) or _raw_digest(value[mapping[0]]) != value.get(mapping[1]): return false
	var finishes: Dictionary = {}
	for id in value.pavingFinishPartIds:
		if not id is String or finishes.has(id) or not value.beforeSnapshot.parts.any(func(part): return part.id == id): return false
		finishes[id] = true
	var declared: Array = []
	for part in value.afterSnapshot.parts:
		if not part.get("recipe") is Dictionary: return false
		if part.recipe.has("pavingFootingJoints"): declared.append(part.id)
	if declared.size() != finishes.size() or not declared.all(func(id): return finishes.has(id)): return false
	var furniture_ids: Dictionary = {}
	for part in value.furnitureSnapshot.parts:
		if not part is Dictionary or not part.get("id") is String or part.id.is_empty() or furniture_ids.has(part.id): return false
		furniture_ids[part.id] = true
	return true

func _check_contract_identity(expected: Dictionary) -> Dictionary:
	var rows: Array = []
	var exact: bool = not expected.is_empty() and expected.size() <= 32
	if expected.size() > 32: return {"exact": false, "rows": []}
	for path in expected:
		if not path is String or not path.begins_with("res://scripts/") or not expected[path] is String:
			exact = false
			continue
		var actual: String = FileAccess.get_sha256(path)
		rows.append({"path": path, "expected": expected[path], "actual": actual})
		exact = exact and actual == expected[path] and actual.length() == 64
	return {"exact": exact, "rows": rows}

func _publication_cycle(snapshot: Dictionary, static_mode: bool, phase: String) -> Dictionary:
	var lifecycle: Dictionary = {"phase": phase, "complete": false, "inputDigest": _raw_digest(snapshot)}
	if not _within_budget(): return {"complete": false, "lifecycle": lifecycle}
	var b = FacadeRecipe.copy_blueprint(snapshot)
	lifecycle["copyExact"] = var_to_bytes(snapshot) == var_to_bytes(b.snapshot())
	if not lifecycle.copyExact:
		_stop_reason = "source_copy_changed"
		return {"complete": false, "lifecycle": lifecycle}
	var publisher: CyclePublisher = CyclePublisher.new()
	publisher.budget = _within_budget
	publisher.record_limit = MAX_PUBLISHED_PRIMITIVES - int(_counts.publishedPrimitives)
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	var joints: Dictionary = {}
	for part in b.parts:
		if part.recipe.has("pavingFootingJoints"): joints[part.id] = var_to_bytes(part.recipe.pavingFootingJoints)
	var started: int = Time.get_ticks_msec()
	var begun: bool = publisher.begin_publication(b, parent, {"batchStaticParts": static_mode})
	lifecycle["beginReady"] = begun
	lifecycle["beginElapsedMsec"] = Time.get_ticks_msec() - started
	var post_begin: Dictionary = b.snapshot()
	lifecycle["postValidationDigest"] = _raw_digest(post_begin)
	lifecycle["validationMutations"] = _validation_changes(snapshot, post_begin)
	var part_index: int = 0
	while begun and part_index < b.parts.size() and _within_budget() and publisher.error.is_empty():
		var next: int = publisher.publish_part_batch(b, parent, part_index, 6)
		if next <= part_index or next > b.parts.size():
			_stop_reason = "publication_batch_did_not_advance"
			break
		_counts.publishedParts += next - part_index
		part_index = next
	var summary: Dictionary = publisher.finish_publication(b, parent) if begun and part_index == b.parts.size() and _within_budget() and publisher.error.is_empty() else publisher.summary()
	lifecycle["summary"] = summary
	lifecycle["emittedParts"] = part_index
	lifecycle["postPublicationDigest"] = _raw_digest(b.snapshot())
	lifecycle["sourceStableAfterValidation"] = var_to_bytes(post_begin) == var_to_bytes(b.snapshot())
	lifecycle["committedJointsUnchanged"] = true
	for id in joints:
		if joints[id] != var_to_bytes(b.find_part(id).recipe.pavingFootingJoints): lifecycle.committedJointsUnchanged = false
	var ready: bool = begun and part_index == b.parts.size() and summary.publishedPartCount == b.parts.size() and publisher.incremental_published_parts == b.parts.size() and lifecycle.sourceStableAfterValidation and lifecycle.committedJointsUnchanged and publisher.error.is_empty() and publisher.pending_owners.is_empty() and _within_budget()
	if not joints.is_empty(): ready = ready and bool(summary.get("pavingFootingPublication", {}).get("complete", false))
	var payloads: Dictionary = {}
	var raw_nodes: Array = []
	var artifacts: Dictionary = {}
	var source_bindings: Dictionary = {}
	if ready:
		var collected: Dictionary = _collect_cycle(publisher, parent, b, phase)
		payloads = collected.payloads
		raw_nodes = collected.nodes
		lifecycle["rawCollisionPaths"] = collected.collisionPaths
		ready = collected.complete
		for id in publisher._paving_artifacts:
			artifacts[id] = publisher._paving_artifacts[id].artifact
			# Packed arrays are shared references; publisher cleanup clears its
			# binding. Evidence must own its bytes before that legitimate cleanup.
			source_bindings[id] = publisher._paving_artifacts[id].sourceBinding.duplicate()
	# Compare resource identity and actual arrays while the publication is alive.
	# Only this explicit Mesh field is converted; unexpected Objects fail export.
	var finish_values: Dictionary = {}
	if ready and _checkpoint_capture:
		finish_values = _checkpoint_finish_values(payloads, artifacts, source_bindings, phase, static_mode)
		ready = bool(finish_values.get("complete", false))
	lifecycle["captureError"] = publisher.error
	lifecycle["capturePrimitiveCount"] = publisher.recorded
	lifecycle["staticFlushCount"] = publisher.flushes
	lifecycle["elapsedMsec"] = Time.get_ticks_msec() - started
	lifecycle.complete = ready
	publisher.clear_published()
	parent.free()
	if _checkpoint_capture:
		for id in source_bindings:
			if source_bindings[id].is_empty() or _raw_digest(source_bindings[id]) != finish_values.get("artifacts", {}).get(id, {}).get("sourceBindingDigest"):
				ready = false
				lifecycle.complete = false
				lifecycle.captureError = "source_binding_changed_during_cleanup"
		return {"complete": ready, "lifecycle": lifecycle, "payloads": payloads, "rawNodes": raw_nodes,
			"finishValues": finish_values, "sourceBindings": source_bindings, "postValidationSnapshot": post_begin}
	return {"complete": ready, "lifecycle": lifecycle, "payloads": payloads, "rawNodes": raw_nodes, "artifacts": artifacts}

func _validation_changes(before: Dictionary, after: Dictionary) -> Dictionary:
	var changed: int = 0
	var rows: Array = []
	for index in range(mini(before.parts.size(), after.parts.size())):
		if var_to_bytes(before.parts[index]) == var_to_bytes(after.parts[index]): continue
		changed += 1
		if rows.size() < 16:
			rows.append({"partId": before.parts[index].id, "beforeDigest": _raw_digest(before.parts[index]), "afterDigest": _raw_digest(after.parts[index])})
	return {"changedPartCount": changed, "firstParts": rows, "rowsTruncated": changed > rows.size(), "blueprintRecipeChanged": var_to_bytes(before.recipe) != var_to_bytes(after.recipe)}

func _collect_cycle(publisher: CyclePublisher, parent: Node3D, b, phase: String) -> Dictionary:
	var captured: Dictionary = {}
	var payloads: Dictionary = {}
	for part in b.parts:
		captured[part.id] = {"primitives": [], "errors": [], "boxCount": 0, "nonBoxCount": 0}
		payloads[part.id] = {"collision": {"status": "no_collision", "primitives": [], "shapes": [], "bounds": []}}
	var nodes: Array = []
	var collision_paths: Array = []
	var collision_owners: Dictionary = {}
	var stack: Array = [parent]
	var seen_meshes: int = 0
	while not stack.is_empty() and _within_budget():
		var node: Node = stack.pop_back()
		_work.nodes += 1
		if node is MeshInstance3D or node is MultiMeshInstance3D:
			seen_meshes += 1
			if not publisher.captures.has(node):
				_stop_reason = "uncaptured_live_mesh_node"
				break
			var capture: Dictionary = publisher.captures[node]
			if not _capture_node_valid(capture):
				_stop_reason = "CPU_argument_node_mismatch"
				break
			capture.matched = true
			var surface: Dictionary = _mesh_surface_fact(capture.mesh)
			if not surface.valid: break
			var materials: Array = []
			for index in range(capture.mesh.get_surface_count()): materials.append(_material_digest(node.get_active_material(index)) if node is MeshInstance3D else _material_digest(capture.material if capture.material != null else capture.mesh.surface_get_material(index)))
			var raw: Dictionary = {"path": String(parent.get_path_to(node)), "class": node.get_class(), "name": String(node.name), "instanceCount": capture.identities.size(), "owners": [], "matched": true}
			for index in range(capture.identities.size()):
				if not _within_budget(): break
				var identity: Dictionary = capture.identities[index]
				if not captured.has(identity.owner):
					_stop_reason = "unknown_captured_source_owner"
					break
				var transform: Transform3D = node.global_transform * capture.transforms[index] if capture.kind == "batch" else node.global_transform
				var is_box: bool = capture.mesh is BoxMesh and capture.mesh.size == Vector3.ONE
				var id: String = "visual:%d" % int(identity.ordinal)
				var primitive: Dictionary = {"id": id, "type": "box" if is_box else "mesh", "transform": transform, "meshBounds": capture.mesh.get_aabb(),
					"meshClass": capture.mesh.get_class(), "meshDigest": surface.digest, "materialDigests": materials,
					"customData": capture.custom[index] if capture.kind == "batch" else null, "castShadow": node.cast_shadow,
					"publisherNodeIdentity": [{"sourcePartId": identity.owner, "emissionOrdinal": identity.ordinal, "requestedLabel": identity.label}]}
				captured[identity.owner].primitives.append(primitive)
				captured[identity.owner]["boxCount" if is_box else "nonBoxCount"] += 1
				if _finish_ids.has(identity.owner):
					_cycle_meshes[phase + ":" + identity.owner + ":" + id] = {"mesh": capture.mesh, "arrays": surface.arrays, "transform": transform}
				raw.owners.append({"partId": identity.owner, "ordinal": identity.ordinal, "instanceIndex": index})
			nodes.append(raw)
		for child in node.get_children(): stack.append(child)
	var collision: Dictionary = _collect_collision_payload(parent) if _within_budget() else {"shapes": []}
	for shape in collision.shapes:
		var owner: String = shape.state.partId
		if not payloads.has(owner):
			_stop_reason = "unowned_actual_collision_shape"
			break
		var result: Dictionary = payloads[owner].collision
		# Global tree indices shift when a finish adds meshes. Retain those paths
		# as raw evidence; compare exact collider state by source-local shape and
		# body ordinals, not by an unrelated earlier root-child insertion count.
		if not collision_owners.has(owner): collision_owners[owner] = []
		var owners: Array = collision_owners[owner]
		var raw_owner: String = shape.state.path
		if not owners.has(raw_owner): owners.append(raw_owner)
		collision_paths.append({"partId": owner, "rawShapeId": shape.id, "rawOwnerPath": raw_owner, "shapeOrdinal": result.shapes.size(), "ownerOrdinal": owners.find(raw_owner)})
		shape.id = "collision:%d" % result.shapes.size()
		shape.state.path = "owner:%d" % owners.find(raw_owner)
		result.shapes.append(shape)
		if shape.state.blocking:
			result.status = "published"
			result.primitives.append(shape)
			result.bounds = _union_intervals(result.bounds, shape.bounds)
	for part in b.parts:
		if not _within_budget(): break
		var data: Dictionary = captured[part.id]
		data.primitives.sort_custom(func(a, c): return int(a.publisherNodeIdentity[0].emissionOrdinal) < int(c.publisherNodeIdentity[0].emissionOrdinal))
		if not bool(part.recipe.get("visual", true)) and data.primitives.is_empty():
			payloads[part.id].visual = {"status": "no_collision", "primitives": [], "bounds": [], "sourceVisualFalse": true}
		else: payloads[part.id].visual = _visual_payload(data, "buildingVisualPrimitives")
		if not _valid_payload(payloads[part.id].visual) or not _valid_payload(payloads[part.id].collision): _stop_reason = "invalid_cycle_part_payload"
	var matched: bool = seen_meshes == publisher.captures.size() and publisher.captures.values().all(func(row): return row.matched)
	return {"complete": matched and _within_budget(), "payloads": payloads, "nodes": nodes, "collisionPaths": collision_paths}

func _capture_node_valid(capture: Dictionary) -> bool:
	var node = capture.node
	if not is_instance_valid(node) or node.get_parent() != capture.parent or node.transform != capture.nodeTransform or node.material_override != capture.material or capture.mesh == null or capture.mesh.get_surface_count() < 1: return false
	if node is MeshInstance3D: return capture.kind == "mesh" and node.mesh == capture.mesh and capture.identities.size() == 1
	if not node is MultiMeshInstance3D or capture.kind != "batch": return false
	var multi: MultiMesh = node.multimesh
	return multi != null and multi.mesh == capture.mesh and multi.instance_count == capture.identities.size() and multi.instance_count == capture.transforms.size() and multi.instance_count == capture.custom.size() and multi.transform_format == MultiMesh.TRANSFORM_3D and multi.use_custom_data and multi.visible_instance_count == -1

func _mesh_surface_fact(mesh: Mesh) -> Dictionary:
	if _cycle_mesh_facts.has(mesh): return _cycle_mesh_facts[mesh]
	var arrays: Array = []
	if mesh == null or mesh.get_surface_count() < 1 or mesh.get_surface_count() > 64 or _cycle_mesh_facts.size() >= MAX_PART_PRIMITIVES:
		_stop_reason = "missing_or_excessive_mesh_surfaces"
		return {"valid": false}
	for index in range(mesh.get_surface_count()):
		var surface: Array = mesh.get_mesh_arrays() if mesh is PrimitiveMesh else mesh.surface_get_arrays(index)
		if surface.size() != Mesh.ARRAY_MAX or not surface[Mesh.ARRAY_VERTEX] is PackedVector3Array or surface[Mesh.ARRAY_VERTEX].is_empty():
			_stop_reason = "actual_mesh_arrays_unavailable"
			return {"valid": false}
		arrays.append(surface)
	var result: Dictionary = {"valid": true, "arrays": arrays, "digest": _stable_digest(arrays)}
	_cycle_mesh_facts[mesh] = result
	return result

func _compare_mode(archive: Dictionary, before: Dictionary, after: Dictionary, mode: String, contacts_requested: bool) -> Dictionary:
	var originals: Array = []
	var furniture_rows: Array = []
	var cut_cells: Dictionary = {}
	var finish_rows: Array = []
	var parity: bool = true
	for record in archive.beforeSnapshot.parts:
		if not _within_budget(): break
		if archive.pavingFinishPartIds.has(record.id):
			var cut: Dictionary = _compare_finish(record.id, before.payloads[record.id], after.payloads[record.id], after.artifacts.get(record.id, {}), mode)
			finish_rows.append(cut.report)
			parity = parity and cut.exact
			cut_cells[record.id] = cut.cells
		else:
			var comparison: Dictionary = _compare_channels(before.payloads[record.id], after.payloads[record.id])
			comparison["partId"] = record.id
			originals.append(comparison)
			parity = parity and comparison.exact
	var plan = FurnishingPlanScript.new(archive.furnitureSnapshot.id, int(archive.furnitureSnapshot.seed), archive.furnitureSnapshot.sourceBlueprintId)
	for record in archive.furnitureSnapshot.parts: plan.add_part(record)
	var old_furnisher = Furnisher.new()
	var new_furnisher = Furnisher.new()
	for part in plan.parts:
		if not _within_budget(): break
		var old: Dictionary = _furnishing_payload(old_furnisher, part)
		var current: Dictionary = _furnishing_payload(new_furnisher, part)
		var comparison: Dictionary = _compare_channels(old, current)
		comparison["partId"] = part.id
		furniture_rows.append(comparison)
		parity = parity and comparison.exact
		after.payloads["furnishing:" + part.id] = current
	var contacts: Array = []
	var pairs: int = 0
	var scan_ids: Array = archive.partIds if contacts_requested else []
	for id in scan_ids:
		for other_id in after.payloads:
			if other_id == id: continue
			for channel in ["visual", "collision"]:
				if not _within_budget(): break
				var measurement: Dictionary = _classify_validated_overlap(after.payloads[id][channel], after.payloads[other_id][channel])
				pairs += 1
				_counts.partPairs += 1
				if measurement.status in ["certified_separated", "no_collision"]: continue
				var row: Dictionary = {"partId": id, "otherId": other_id, "channel": channel, "rawMeasurement": measurement, "reviewRequired": true}
				if channel == "visual" and cut_cells.has(other_id): row["representedCellRefinement"] = _refine_cut_contacts(measurement, cut_cells[other_id])
				contacts.append(row)
	var expected_pairs: int = 7 * (archive.afterSnapshot.parts.size() + 152 - 1) * 2
	var inventory: Array = []
	for id in after.payloads:
		var item: Dictionary = {"partId": id}
		for channel in ["visual", "collision"]:
			var payload: Dictionary = after.payloads[id][channel]
			item[channel] = {"primitiveCount": payload.primitives.size(), "bounds": payload.bounds, "digest": _stable_digest(payload)}
		inventory.append(item)
	var complete: bool = parity and originals.size() + finish_rows.size() == archive.beforeSnapshot.parts.size() and furniture_rows.size() == 152 and (not contacts_requested or pairs == expected_pairs) and after.payloads.size() == archive.afterSnapshot.parts.size() + 152 and _within_budget()
	return {"mode": mode, "complete": complete, "parityExactExceptVerifiedFinishCuts": parity, "beforeCycle": before.lifecycle, "afterCycle": after.lifecycle,
		"originalComparisons": originals, "finishComparisons": finish_rows, "furnishingComparisons": furniture_rows, "pairCount": pairs, "expectedPairCount": expected_pairs,
		"contactCoverageRequested": contacts_requested, "contactCoverageComplete": contacts_requested and pairs == expected_pairs,
		"contacts": contacts, "payloadInventory": inventory, "beforeNodeMatches": before.rawNodes, "afterNodeMatches": after.rawNodes,
		"contactAcceptance": false, "status": "raw_contacts_require_critic_review"}

func _compare_finish(id: String, before: Dictionary, after: Dictionary, artifact: Dictionary, mode: String) -> Dictionary:
	var rows: Array = []
	var cells: Dictionary = {}
	var valid: bool = artifact.get("completed", false) and artifact.get("stage") == "represented_publication_geometry" and artifact.get("entries", []).size() == before.visual.primitives.size()
	var output_index: int = 0
	if valid:
		for index in range(artifact.entries.size()):
			if not _within_budget():
				valid = false
				break
			var entry: Dictionary = artifact.entries[index]
			var old: Dictionary = before.visual.primitives[index]
			if not entry.unchanged and entry.mesh == null:
				valid = valid and entry.cells.is_empty()
				rows.append({"sourceEntry": entry.original.id, "removed": true, "noMeshAndNoCells": entry.cells.is_empty()})
				continue
			if output_index >= after.visual.primitives.size():
				valid = false
				break
			var current: Dictionary = after.visual.primitives[output_index]
			output_index += 1
			var actual: Dictionary = _cycle_meshes.get(mode + ":after:" + id + ":" + current.id, {})
			var frame_exact: bool = old.transform == entry.original.transform and current.transform == entry.original.transform
			var appearance_exact: bool = old.materialDigests == current.materialDigests and old.customData == current.customData and old.castShadow == current.castShadow
			var geometry_exact: bool = false
			if entry.unchanged:
				geometry_exact = old.type == current.type and old.localMeshBounds == current.localMeshBounds and old.meshDigest == current.meshDigest and old.meshClass == current.meshClass
			else:
				geometry_exact = not actual.is_empty() and actual.mesh == entry.mesh and actual.arrays.size() == 1 and var_to_bytes(actual.arrays[0]) == var_to_bytes(entry.mesh.surface_get_arrays(0))
				if geometry_exact:
					var reconstructed: Dictionary = _represented_cells(entry, current, actual.arrays[0])
					geometry_exact = reconstructed.valid
					if geometry_exact: cells[current.id] = reconstructed.bounds
			var exact: bool = frame_exact and appearance_exact and geometry_exact
			valid = valid and exact
			rows.append({"sourceEntry": entry.original.id, "originalIndex": index, "publishedId": current.id, "unchanged": entry.unchanged,
				"frameExact": frame_exact, "appearanceExact": appearance_exact, "geometryMatchesAuthority": geometry_exact, "exact": exact})
	valid = valid and output_index == after.visual.primitives.size() and var_to_bytes(before.collision) == var_to_bytes(after.collision)
	return {"exact": valid, "cells": cells, "report": {"partId": id, "exactDeclaredChange": valid, "entries": rows,
		"geometryDigest": artifact.get("geometryDigest", ""), "constructionDigest": artifact.get("constructionDigest", ""),
		"originalPrimitiveCount": before.visual.primitives.size(), "candidatePrimitiveCount": after.visual.primitives.size(), "bedCustomComparedWithinMode": true}}

func _represented_cells(entry: Dictionary, primitive: Dictionary, arrays: Array) -> Dictionary:
	var result: Dictionary = {"valid": false, "bounds": []}
	if not entry.get("faceProvenance") is Array or not entry.get("cells") is Array or entry.cells.is_empty() or entry.cells.size() > 256: return result
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var points: Array = []
	for ignored in entry.cells: points.append(PackedVector3Array())
	var covered: int = 0
	for face in entry.faceProvenance:
		if not _within_budget() or face.cellIndex < 0 or face.cellIndex >= points.size() or face.firstVertex != covered or face.vertexCount <= 0 or face.vertexCount % 3 != 0 or covered + face.vertexCount > vertices.size(): return result
		for index in range(face.firstVertex, face.firstVertex + face.vertexCount, 3):
			for vertex_index in [index, index + 2, index + 1]:
				var world: Vector3 = primitive.transform * vertices[vertex_index]
				if not world.is_finite(): return result
				points[face.cellIndex].append(world)
		covered += face.vertexCount
	if covered != vertices.size(): return result
	for index in range(points.size()):
		var expected: PackedVector3Array = PackedVector3Array()
		for face in entry.cells[index].faces: expected.append_array(face.worldVertices)
		if points[index].is_empty() or points[index] != expected: return result
		var lo: Vector3 = Vector3(INF, INF, INF)
		var hi: Vector3 = -lo
		for point in points[index]:
			lo = lo.min(point)
			hi = hi.max(point)
		result.bounds.append([float(lo.x), float(lo.y), float(lo.z), float(hi.x), float(hi.y), float(hi.z)])
	result.valid = true
	return result

func _refine_cut_contacts(measurement: Dictionary, cells: Dictionary) -> Dictionary:
	var rows: Array = []
	for pair in measurement.get("candidates", []):
		if not cells.has(pair.bPrimitive.id):
			rows.append({"primitiveId": pair.bPrimitive.id, "status": "native_or_unmatched_no_cut_exemption"})
			continue
		var separated: bool = true
		var tests: int = 0
		for bounds in cells[pair.bPrimitive.id]:
			_counts.primitiveTests += 1
			_cut_pair_tests += 1
			if not _within_budget(): return {"complete": false, "rows": rows}
			tests += 1
			separated = separated and _intervals_separate(pair.aPrimitive.bounds, bounds)
		rows.append({"primitiveId": pair.bPrimitive.id, "otherPrimitiveId": pair.aPrimitive.id, "cellCount": cells[pair.bPrimitive.id].size(), "pairTests": tests,
			"status": "all_actual_mesh_cell_bounds_separated" if separated else "actual_cell_envelope_overlap_unresolved", "automaticContactAcceptance": false})
	return {"complete": true, "rows": rows, "scope": "actual_matched_mesh_vertices_partitioned_by_verified_cell_provenance_not_whole_finish_exclusion"}

func _finish_cycle_report(report: Dictionary, reason: String) -> void:
	report["status"] = reason
	report["stopReason"] = _stop_reason
	report["counts"] = _counts
	report["extractionWork"] = _work
	report["representedCellPairTests"] = _cut_pair_tests
	report["elapsedMsec"] = Time.get_ticks_msec() - _started_msec
	report["publisherSha256"] = FileAccess.get_sha256("res://scripts/buildings/BuildingPartPublisher.gd")
	_write_facade_report(_cycle_report_path, report, 1 if bool(report.get("requestedStageCompleted", false)) else 2)

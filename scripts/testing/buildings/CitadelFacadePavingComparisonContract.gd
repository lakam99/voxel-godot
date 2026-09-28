extends "res://scripts/testing/buildings/CitadelFacadePavingPublishedContract.gd"

## Value-only replay. Never calls publication or changes the frozen capture.
## Manifest v1: {schemaVersion:1,candidate:{path,sha256},
## captures:{stage:{path,sha256,report:{path,sha256},watchdog:{path,sha256}}},
## shards:[{path,sha256,report:{path,sha256},watchdog:{path,sha256}}]}
## Shards required only for aggregate; final JSON + clean watchdog mandatory.
## Env: VOXEL_FACADE_PAVING_COMPARE_MANIFEST, _MANIFEST_SHA256, _JOB,
##      _REPORT (fresh JSON), _EXPORT (fresh raw-var .bin).
## JOB=inventory|controls|audit:<stage>|<mode>:originals:<slice>|<mode>:finishes|
##     <mode>:furniture|<mode>:contacts:<member-index>|aggregate.
const ORIGINAL_SLICE := 512
const MAX_MANIFEST_BYTES := 65536
const MAX_SHARD_BYTES := 32 * 1024 * 1024
const MAX_SHARDS := 64
const COMPARE_SCHEMA := 1
var _manifest: Dictionary = {}
var _assembly: Dictionary = {}
var _binding: Dictionary = {}
var _inputs_read: Dictionary = {}
var _loaded: Dictionary = {}
var _compare_path: String = ""
var _compare_export: String = ""
var _jobs: Dictionary = {}
var _admissions: Dictionary = {}

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	_compare_path = OS.get_environment("VOXEL_FACADE_PAVING_COMPARE_REPORT")
	_compare_export = OS.get_environment("VOXEL_FACADE_PAVING_COMPARE_EXPORT")
	var job: String = OS.get_environment("VOXEL_FACADE_PAVING_COMPARE_JOB")
	if not _fresh_path(_compare_path, "json") or not _fresh_path(_compare_export, "bin"):
		quit(2)
		return
	var manifest_path: String = OS.get_environment("VOXEL_FACADE_PAVING_COMPARE_MANIFEST")
	var manifest_sha: String = OS.get_environment("VOXEL_FACADE_PAVING_COMPARE_MANIFEST_SHA256")
	var raw: PackedByteArray = _bound_bytes({"path": manifest_path, "sha256": manifest_sha}, MAX_MANIFEST_BYTES)
	var decoded: Variant = JSON.parse_string(raw.get_string_from_utf8()) if not raw.is_empty() else null
	if not _manifest_valid(decoded):
		_finish_comparison(job, {"complete": false, "reason": "manifest_schema_or_hash"})
		return
	_manifest = decoded
	_assembly = _read_value(_manifest.candidate, MAX_ARTIFACT_BYTES)
	if not _valid_assembly_archive(_assembly) or _manifest.candidate.sha256 != APPROVED_CANDIDATE_SHA or not _check_contract_identity(_assembly.contractIdentity).exact:
		_finish_comparison(job, {"complete": false, "reason": "candidate_or_source_identity"})
		return
	_finish_ids = _assembly.pavingFinishPartIds.duplicate()
	var capture_hashes: Array = []
	for stage in CPU_CAPTURE_STAGES:
		var descriptor: Dictionary = _manifest.captures[stage]
		capture_hashes.append([stage, descriptor.sha256, descriptor.report.sha256, descriptor.watchdog.sha256])
	_binding = {"schemaVersion": COMPARE_SCHEMA, "candidateSha256": _manifest.candidate.sha256,
		"captures": capture_hashes, "comparisonSha256": FileAccess.get_sha256(get_script().resource_path),
		"originalSlice": ORIGINAL_SLICE}
	_jobs = _required_jobs(_assembly)
	if job == "inventory":
		_finish_comparison(job, {"complete": true, "requiredJobs": _jobs, "coverage": {}})
		return
	if job == "aggregate":
		_finish_comparison(job, _aggregate_shards())
		return
	if not _jobs.has(job):
		_finish_comparison(job, {"complete": false, "reason": "unknown_or_out_of_range_job"})
		return
	var spec: Dictionary = _jobs[job]
	var result: Dictionary
	if spec.kind == "controls": result = _comparison_controls()
	elif spec.kind == "audit": result = _audit_capture(_load_capture(spec.stage), spec.stage)
	else:
		var after: Dictionary = _load_capture("after_" + spec.mode)
		var before: Dictionary = {} if spec.kind == "contacts" else _load_capture("before_" + spec.mode)
		if after.is_empty() or (spec.kind != "contacts" and before.is_empty()):
			result = {"complete": false, "reason": "capture_binding_or_schema"}
		elif spec.kind == "originals": result = _original_slice(before, after, spec.ids)
		elif spec.kind == "furniture": result = _captured_furniture_parity(before, after, spec.ids)
		elif spec.kind == "finishes": result = _finish_parity(before, after, spec.ids)
		else: result = _contact_member(after, spec.memberId, spec.otherIds)
	result["coverage"] = spec
	_finish_comparison(job, result)

func _fresh_path(path: String, extension: String) -> bool:
	return path.is_absolute_path() and path.get_extension() == extension and not FileAccess.file_exists(path) and DirAccess.dir_exists_absolute(path.get_base_dir())

func _descriptor_valid(value: Variant) -> bool:
	return value is Dictionary and value.size() == 2 and value.get("path") is String and value.path.is_absolute_path() and value.get("sha256") is String and value.sha256.length() == 64 and value.sha256.is_valid_hex_number(false)

func _manifest_valid(value: Variant) -> bool:
	if not value is Dictionary or value.get("schemaVersion") != 1 or not _descriptor_valid(value.get("candidate")) or not value.get("captures") is Dictionary or value.captures.size() != 4: return false
	var paths: Dictionary = {value.candidate.path: true}
	for stage in CPU_CAPTURE_STAGES:
		var capture: Variant = value.captures.get(stage)
		if not capture is Dictionary or capture.size() != 4 or not _descriptor_valid(_binary_descriptor(capture)): return false
		for descriptor in [_binary_descriptor(capture), capture.get("report"), capture.get("watchdog")]:
			if not _descriptor_valid(descriptor) or paths.has(descriptor.path): return false
			paths[descriptor.path] = true
	if not value.get("shards", []) is Array or value.get("shards", []).size() > MAX_SHARDS: return false
	for descriptor in value.get("shards", []):
		if not descriptor is Dictionary or descriptor.size() != 4: return false
		for item in [_binary_descriptor(descriptor), descriptor.get("report"), descriptor.get("watchdog")]:
			if not _descriptor_valid(item) or paths.has(item.path): return false
			paths[item.path] = true
	return true

func _bound_bytes(descriptor: Dictionary, cap: int) -> PackedByteArray:
	if not _descriptor_valid(descriptor) or not _within_budget(): return PackedByteArray()
	var file: FileAccess = FileAccess.open(descriptor.path, FileAccess.READ)
	if file == null: return PackedByteArray()
	var length: int = file.get_length()
	if length <= 0 or length > cap:
		file.close()
		return PackedByteArray()
	var bytes: PackedByteArray = file.get_buffer(length)
	var read_ok: bool = bytes.size() == length and file.get_error() == OK
	file.close()
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	if not read_ok or hash.finish().hex_encode() != descriptor.sha256: return PackedByteArray()
	_inputs_read[descriptor.path] = descriptor.sha256
	return bytes

func _read_value(descriptor: Dictionary, cap: int) -> Dictionary:
	var bytes: PackedByteArray = _bound_bytes(descriptor, cap)
	if bytes.is_empty(): return {}
	var value: Variant = bytes_to_var(bytes)
	if not value is Dictionary or var_to_bytes(value) != bytes or not _within_budget(): return {}
	return value

func _source_ids(records: Array) -> Array:
	var ids: Array = []
	for record in records: ids.append(record.id)
	ids.sort()
	return ids

func _required_jobs(assembly: Dictionary) -> Dictionary:
	var jobs: Dictionary = {"controls": {"kind": "controls"}}
	for stage in CPU_CAPTURE_STAGES: jobs["audit:" + stage] = {"kind": "audit", "stage": stage}
	var original: Array = _source_ids(assembly.beforeSnapshot.parts).filter(func(id): return not assembly.pavingFinishPartIds.has(id))
	var finishes: Array = assembly.pavingFinishPartIds.duplicate()
	finishes.sort()
	var members: Array = assembly.partIds.duplicate()
	members.sort()
	var furniture: Array = _source_ids(assembly.furnitureSnapshot.parts)
	var others: Array = _source_ids(assembly.afterSnapshot.parts)
	for id in furniture: others.append("furnishing:" + id)
	others.sort()
	for mode in ["standard", "static"]:
		for start in range(0, original.size(), ORIGINAL_SLICE):
			jobs[mode + ":originals:" + str(start / ORIGINAL_SLICE)] = {"kind": "originals", "mode": mode, "ids": original.slice(start, mini(start + ORIGINAL_SLICE, original.size()))}
		jobs[mode + ":finishes"] = {"kind": "finishes", "mode": mode, "ids": finishes}
		jobs[mode + ":furniture"] = {"kind": "furniture", "mode": mode, "ids": furniture}
		for index in range(members.size()):
			var peer_ids: Array = others.filter(func(id): return id != members[index])
			jobs[mode + ":contacts:" + str(index)] = {"kind": "contacts", "mode": mode, "memberId": members[index], "otherIds": peer_ids, "channels": ["visual", "collision"], "pairCount": peer_ids.size() * 2}
	return jobs

func _identity_current(expected: Variant) -> bool:
	if not expected is Dictionary or expected.is_empty() or expected.size() > 512: return false
	for path in expected:
		if not path is String or not path.begins_with("res://scripts/") or not expected[path] is String or expected[path].length() != 64 or FileAccess.get_sha256(path) != expected[path] or not _within_budget(): return false
	return true

func _load_capture(stage: String) -> Dictionary:
	if _loaded.has(stage): return _loaded[stage]
	if not _admit_capture(stage): return {}
	var value: Dictionary = _read_value(_binary_descriptor(_manifest.captures[stage]), MAX_CPU_ARTIFACT_BYTES)
	if not _capture_header_valid(value, stage): return {}
	if _admissions[stage].report.publisherSha256 != value.implementationIdentity.get("res://scripts/buildings/BuildingPartPublisher.gd"): return {}
	_loaded[stage] = value
	return value

func _binary_descriptor(value: Dictionary) -> Dictionary:
	return {"path": value.get("path"), "sha256": value.get("sha256")}

func _read_json(descriptor: Dictionary, cap: int) -> Dictionary:
	var bytes: PackedByteArray = _bound_bytes(descriptor, cap)
	var value: Variant = JSON.parse_string(bytes.get_string_from_utf8()) if not bytes.is_empty() else null
	return value if value is Dictionary else {}

func _same_path(a: String, b: String) -> bool:
	return a.replace("\\", "/").simplify_path() == b.replace("\\", "/").simplify_path()

func _admit_capture(stage: String) -> bool:
	if _admissions.has(stage): return true
	var descriptor: Dictionary = _manifest.captures[stage]
	var report: Dictionary = _read_json(descriptor.report, 1024 * 1024)
	var watchdog: Dictionary = _read_json(descriptor.watchdog, MAX_MANIFEST_BYTES)
	if not _final_capture_report_valid(report, stage, descriptor) or not _clean_watchdog(watchdog): return false
	if watchdog.get("sceneArguments") != ["res://scripts/testing/buildings/CitadelFacadePavingPublishedContract.gd"] or watchdog.get("headless") != true: return false
	var directory: String = descriptor.report.path.get_base_dir()
	if not _same_path(directory, descriptor.path.get_base_dir()) or not _same_path(directory, descriptor.watchdog.path.get_base_dir()): return false
	for name in ["stdoutPath", "stderrPath"]:
		if not watchdog.get(name) is String or not _same_path(directory, watchdog[name].get_base_dir()): return false
		var log_file: FileAccess = FileAccess.open(watchdog[name], FileAccess.READ)
		if log_file == null: return false
		var length: int = log_file.get_length()
		if length > 1024 * 1024 or (name == "stderrPath" and length != 0):
			log_file.close()
			return false
		var text: String = log_file.get_as_text()
		log_file.close()
		if text.contains("SCRIPT ERROR:") or text.contains("ERROR:"): return false
		_inputs_read[watchdog[name]] = FileAccess.get_sha256(watchdog[name])
	var binary: FileAccess = FileAccess.open(descriptor.path, FileAccess.READ)
	if binary == null: return false
	var size: int = binary.get_length()
	binary.close()
	if size != int(report.cpuArtifactBytes) or size <= 0 or size > MAX_CPU_ARTIFACT_BYTES: return false
	_admissions[stage] = {"report": report, "watchdog": watchdog}
	return true

func _final_capture_report_valid(report: Dictionary, stage: String, descriptor: Dictionary) -> bool:
	if not report.get("contractIdentity") is Dictionary or not report.get("collectorControls") is Dictionary or not (report.get("cpuArtifactBytes") is int or report.get("cpuArtifactBytes") is float): return false
	if not report.get("bindingCaptureControls") is Dictionary or report.bindingCaptureControls.get("passed") != true: return false
	return report.get("requestedStage") == stage and report.get("requestedStageCompleted") == true and report.get("status") == "cycle_export_complete_aggregation_pending" and report.get("stopReason") == "" and report.get("immutableInputUnchanged") == true and report.get("implementationAndSourceIdentityUnchanged") == true and report.get("cpuArtifactSha256") == descriptor.sha256 and report.get("cpuArtifactBytes", 0) > 0 and report.get("cpuArtifactPath") is String and _same_path(report.cpuArtifactPath, descriptor.path) and report.get("inputSha256") == APPROVED_CANDIDATE_SHA and report.get("contractIdentity", {}).get("exact") == true and report.get("collectorControls", {}).get("passed") == true

func _clean_watchdog(value: Dictionary) -> bool:
	if value.get("schema") != "godot-scene-watchdog/v5": return false
	for key in ["rootExited", "cleanupPassed", "authoritativeZeroProven", "finalMembershipKnown"]:
		if value.get(key) != true: return false
	for key in ["timedOut", "stopRequested", "forcedCleanup", "cleanupUnresolved", "terminalCleanupExpired"]:
		if value.get(key) != false: return false
	return value.get("functionalExitCode") == 1 and value.get("overallExitCode") == 1 and value.get("finalJobMemberPids") == [] and value.get("monitoringException") == null and value.get("fatalException") == null

func _capture_header_valid(value: Dictionary, stage: String) -> bool:
	if value.get("schemaVersion") != 1 or value.get("provenance") != "successful_facade_paving_CPU_cycle_capture" or value.get("stage") != stage or value.get("captureComplete") != true or value.get("publicationAcceptance") != false: return false
	if value.get("mode") != ("static" if stage.ends_with("_static") else "standard") or value.get("side") != ("before" if stage.begins_with("before_") else "after"): return false
	if value.get("candidateSha256") != _manifest.candidate.sha256: return false
	for key in ["sourceDigest", "afterDigest", "fixtureDigest", "policyDigest", "furnitureDigest", "reservationDigest", "contractIdentity", "memberIds", "partIds", "pavingFinishPartIds"]:
		if var_to_bytes(value.get(key)) != var_to_bytes(_assembly.get(key)): return false
	if not _identity_current(value.get("implementationIdentity")): return false
	var capture_path: String = "res://scripts/testing/buildings/CitadelFacadePavingPublishedContract.gd"
	if not value.implementationIdentity.has(capture_path): return false
	for key in ["cycle", "furniturePayloads", "counts", "extractionWork", "limits"]:
		if not value.get(key) is Dictionary: return false
	for pair in [["softMsec", SOFT_LIMIT_MSEC], ["publishedPrimitives", MAX_PUBLISHED_PRIMITIVES], ["primitiveTests", MAX_PRIMITIVE_TESTS], ["recordedContacts", MAX_RECORDED_CONTACTS], ["nodes", MAX_COLLECTED_NODES], ["cpuArtifactBytes", MAX_CPU_ARTIFACT_BYTES]]:
		if value.limits.get(pair[0]) != pair[1]: return false
	var cycle: Dictionary = value.cycle
	if cycle.get("complete") != true: return false
	for key in ["lifecycle", "payloads", "finishValues", "sourceBindings", "postValidationSnapshot"]:
		if not cycle.get(key) is Dictionary: return false
	if not cycle.get("rawNodes") is Array or cycle.rawNodes.size() > MAX_COLLECTED_NODES: return false
	var expected_ids: Array = _source_ids(_assembly.beforeSnapshot.parts if value.side == "before" else _assembly.afterSnapshot.parts)
	var actual_ids: Array = cycle.payloads.keys()
	actual_ids.sort()
	if actual_ids != expected_ids or value.furniturePayloads.size() != 152: return false
	var actual_furniture: Array = value.furniturePayloads.keys()
	actual_furniture.sort()
	if actual_furniture != _source_ids(_assembly.furnitureSnapshot.parts): return false
	if cycle.finishValues.get("complete") != true or not cycle.finishValues.get("emitted") is Dictionary or not cycle.finishValues.get("artifacts") is Dictionary: return false
	return true

func _audit_capture(value: Dictionary, stage: String) -> Dictionary:
	var result: Dictionary = {"complete": false, "reason": "lifecycle_or_payload_audit", "sourceParts": 0, "furnitureParts": 0, "matchedVisualPrimitives": 0, "matchedCollisionShapes": 0}
	if value.is_empty(): return result
	var cycle: Dictionary = value.cycle
	var life: Dictionary = cycle.lifecycle
	var snapshot: Dictionary = _assembly.beforeSnapshot if value.side == "before" else _assembly.afterSnapshot
	for key in ["complete", "copyExact", "beginReady", "sourceStableAfterValidation", "committedJointsUnchanged"]:
		if life.get(key) != true: return result
	if life.get("phase") != value.mode + ":" + value.side or life.get("captureError") != "" or life.get("emittedParts") != snapshot.parts.size() or life.get("summary", {}).get("publishedPartCount") != snapshot.parts.size(): return result
	if life.get("inputDigest") != _raw_digest(snapshot) or life.get("postValidationDigest") != _raw_digest(cycle.postValidationSnapshot) or life.get("postPublicationDigest") != life.postValidationDigest: return result
	if not _bindings_valid(value):
		result.reason = "finish_source_binding_mismatch"
		return result
	if value.side == "after":
		result["bindingReplayControl"] = _binding_replay_control(value)
		if not result.bindingReplayControl.passed:
			result.reason = "binding_replay_negative_control_failed"
			return result
	var expected_visual: Dictionary = {}
	var expected_shapes: Dictionary = {}
	for id in cycle.payloads:
		if not _within_budget() or not _channels_valid(cycle.payloads[id]): return result
		for primitive in cycle.payloads[id].visual.primitives:
			var key: String = id + ":" + primitive.id
			expected_visual[key] = primitive
		for shape in cycle.payloads[id].collision.get("shapes", []): expected_shapes[id + ":" + shape.id] = shape
		result.sourceParts += 1
	for id in value.furniturePayloads:
		if not _within_budget() or not _channels_valid(value.furniturePayloads[id]): return result
		result.furnitureParts += 1
	var paths: Dictionary = {}
	for node in cycle.rawNodes:
		if not _within_budget() or not node is Dictionary or node.get("matched") != true or not node.get("path") is String or paths.has(node.path) or node.get("class") not in ["MeshInstance3D", "MultiMeshInstance3D"] or not node.get("owners") is Array or node.owners.is_empty() or node.get("instanceCount") != node.owners.size(): return result
		paths[node.path] = true
		for index in range(node.owners.size()):
			var owner: Variant = node.owners[index]
			if not owner is Dictionary or not owner.get("partId") is String or not owner.get("ordinal") is int or owner.ordinal < 0 or owner.get("instanceIndex") != index: return result
			var key: String = owner.partId + ":visual:" + str(owner.ordinal)
			if not expected_visual.has(key): return result
			var primitive: Dictionary = expected_visual[key]
			if primitive.get("publisherNodeIdentity", []).size() != 1: return result
			var identity: Dictionary = primitive.publisherNodeIdentity[0]
			if identity.get("sourcePartId") != owner.partId or identity.get("emissionOrdinal") != owner.ordinal: return result
			expected_visual.erase(key)
			result.matchedVisualPrimitives += 1
	if not expected_visual.is_empty() or result.matchedVisualPrimitives != life.get("capturePrimitiveCount"): return result
	if not life.get("rawCollisionPaths") is Array: return result
	if life.rawCollisionPaths.size() > MAX_PUBLISHED_PRIMITIVES: return result
	for row in life.rawCollisionPaths:
		if not _within_budget() or not row is Dictionary or not row.get("partId") is String or not row.get("shapeOrdinal") is int or not row.get("ownerOrdinal") is int or not row.get("rawShapeId") is String or not row.get("rawOwnerPath") is String: return result
		var key: String = row.partId + ":collision:" + str(row.shapeOrdinal)
		if not expected_shapes.has(key) or expected_shapes[key].state.get("path") != "owner:" + str(row.ownerOrdinal): return result
		expected_shapes.erase(key)
		result.matchedCollisionShapes += 1
	if not expected_shapes.is_empty(): return result
	for key in _counts:
		if not value.counts.get(key) is int or value.counts[key] < 0: return result
	for key in _work:
		if not value.extractionWork.get(key) is int or value.extractionWork[key] < 0: return result
	var admission: Dictionary = _admissions[stage]
	for key in value.counts:
		if admission.report.get("counts", {}).get(key) != value.counts[key]: return result
	_cpu_value_visits = 0
	if not _checkpoint_value_only(value, 0) or not _within_budget(): return result
	result["captureCounts"] = value.counts
	result["captureWork"] = value.extractionWork
	result["implementationIdentity"] = value.implementationIdentity
	result["postValidationDigest"] = life.postValidationDigest
	result["finalReportSha256"] = _manifest.captures[stage].report.sha256
	result["watchdogSha256"] = _manifest.captures[stage].watchdog.sha256
	result.complete = result.sourceParts == snapshot.parts.size() and result.furnitureParts == 152
	result.reason = "" if result.complete else result.reason
	return result

func _bindings_valid(value: Dictionary) -> bool:
	var cycle: Dictionary = value.cycle
	var wired: Dictionary = cycle.finishValues.artifacts
	if value.side == "before": return wired.is_empty() and cycle.sourceBindings.is_empty()
	if wired.size() != _finish_ids.size() or cycle.sourceBindings.size() != _finish_ids.size(): return false
	var post: Dictionary = cycle.postValidationSnapshot
	if not post.get("parts") is Array or not post.get("recipe") is Dictionary: return false
	var original: Dictionary = {}
	for record in _assembly.afterSnapshot.parts: original[record.id] = record
	var required: Dictionary = {}
	for id in _finish_ids:
		if not wired.has(id) or not cycle.sourceBindings.get(id) is PackedByteArray: return false
		var joint: Dictionary = original[id].recipe.pavingFootingJoints
		required[id] = true
		for foot_id in joint.footPartIds: required[foot_id] = true
		if wired[id].get("geometryDigest") != joint.geometryDigest or wired[id].get("constructionDigest") != joint.constructionDigest: return false
	var ids: Array = []
	var records: Array = []
	for record in post.parts:
		if not record is Dictionary or not record.get("recipe") is Dictionary or not original.has(record.get("id")): return false
		ids.append(record.id)
		if record.recipe.has("pavingFootingJoints") and var_to_bytes(record.recipe.pavingFootingJoints) != var_to_bytes(original[record.id].recipe.get("pavingFootingJoints")): return false
		# Persisted source-binding schema: all bound feet/finishes and every
		# history contributor, in actual source order; no cached root authority.
		if required.has(record.id) or record.recipe.has("pavingFootingJoints") or record.kind in ["door", "window"] or record.semantic.contains("eave") or bool(record.recipe.get("weatheringEave", false)): records.append(record)
	var expected: PackedByteArray = var_to_bytes([String(post.recipe.get("sourceBlueprintId", post.id)), post.recipe, ids, records])
	for id in _finish_ids:
		if cycle.sourceBindings[id] != expected or wired[id].get("sourceBindingDigest") != _raw_digest(expected): return false
	return true

func _binding_replay_control(value: Dictionary) -> Dictionary:
	# Only copy the binding ownership path, never the large immutable payload.
	# Packed bytes must be explicitly duplicated before corruption/clear.
	var before_digest: String = _raw_digest(value.cycle.sourceBindings)
	var checks: Dictionary = {"actual_binding_valid": _bindings_valid(value)}
	for id in _finish_ids:
		if not _within_budget(): return {"passed": false, "checks": checks}
		var altered: Dictionary = value.duplicate()
		altered.cycle = value.cycle.duplicate()
		altered.cycle.sourceBindings = value.cycle.sourceBindings.duplicate()
		var bytes: PackedByteArray = value.cycle.sourceBindings[id].duplicate()
		if bytes.is_empty(): return {"passed": false, "checks": checks}
		bytes[bytes.size() - 1] = bytes[bytes.size() - 1] ^ 1
		altered.cycle.sourceBindings[id] = bytes
		checks[id + ":changed_copy_rejected"] = not _bindings_valid(altered)
		bytes.clear()
		checks[id + ":cleared_copy_rejected"] = not _bindings_valid(altered)
	checks["original_binding_bytes_unchanged"] = before_digest == _raw_digest(value.cycle.sourceBindings)
	checks["original_still_valid"] = _bindings_valid(value)
	return {"passed": checks.values().all(func(check): return check == true), "checks": checks,
		"evidenceLevel": "actual_capture_binding_replay_negative_controls_no_publication"}

func _channels_valid(payload: Variant) -> bool:
	if not payload is Dictionary or not payload.get("visual") is Dictionary or not payload.get("collision") is Dictionary: return false
	if not _valid_payload(payload.visual) or not _valid_payload(payload.collision): return false
	for primitive in payload.visual.primitives:
		if not primitive.get("materialDigests") is Array or primitive.materialDigests.is_empty() or not primitive.has("customData") or not primitive.has("castShadow") or not primitive.get("meshDigest") is String or primitive.meshDigest.length() != 64: return false
		for digest in primitive.materialDigests:
			if not digest is String or digest.length() != 64: return false
	return true

func _original_slice(before: Dictionary, after: Dictionary, ids: Array) -> Dictionary:
	var rows: Array = []
	var exact: bool = true
	var before_nodes: Dictionary = _single_owner_node_index(before.cycle.rawNodes)
	var after_nodes: Dictionary = _single_owner_node_index(after.cycle.rawNodes)
	for id in ids:
		if not _within_budget() or not _channels_valid(before.cycle.payloads[id]) or not _channels_valid(after.cycle.payloads[id]): break
		var row: Dictionary = _compare_original_identity(before.cycle.payloads[id], after.cycle.payloads[id], id, before_nodes, after_nodes)
		row["partId"] = id
		rows.append(row)
		exact = exact and row.exact
	return {"complete": rows.size() == ids.size() and _within_budget(), "parityExact": exact and rows.size() == ids.size(), "rows": rows}

func _single_owner_node_index(nodes: Array) -> Dictionary:
	var result: Dictionary = {}
	var visited: int = 0
	for node in nodes:
		if not _within_budget(): break
		if not node is Dictionary or not node.get("owners") is Array: continue
		for owner in node.owners:
			visited += 1
			if visited > MAX_PUBLISHED_PRIMITIVES or not _within_budget():
				_stop_reason = "normalization_owner_index_budget"
				return {}
			if not owner is Dictionary or not owner.get("partId") is String or not owner.get("ordinal") is int: continue
			var key: String = owner.partId + ":" + str(owner.ordinal)
			# Include shared batch occurrences too: they cannot hide ambiguity.
			result[key] = {} if result.has(key) else node
	return result

func _project_generated_identity(payload: Dictionary, part_id: String, nodes: Dictionary) -> Dictionary:
	var projected: Dictionary = payload
	var records: Array = []
	for index in range(payload.visual.primitives.size()):
		if not _within_budget(): return {"ready": false, "records": records}
		var primitive: Dictionary = payload.visual.primitives[index]
		var identities: Variant = primitive.get("publisherNodeIdentity")
		if not identities is Array or identities.size() != 1 or not identities[0] is Dictionary: continue
		var identity: Dictionary = identities[0]
		var label: Variant = identity.get("requestedLabel")
		# Same @Class@integer rule as Chimney._mesh_identities; only the actual
		# single-instance MeshInstance3D path needs this comparison projection.
		var prefix: String = "@MeshInstance3D@"
		if not label is String or not label.begins_with(prefix) or not label.trim_prefix(prefix).is_valid_int(): continue
		if identity.get("sourcePartId") != part_id or not identity.get("emissionOrdinal") is int or identity.emissionOrdinal < 0 or primitive.id != "visual:" + str(identity.emissionOrdinal): return {"ready": false, "records": records}
		var node: Dictionary = nodes.get(part_id + ":" + str(identity.emissionOrdinal), {})
		if node.get("matched") != true or node.get("class") != "MeshInstance3D" or node.get("name") != label or node.get("instanceCount") != 1 or not node.get("path") is String or node.path.is_empty() or not node.get("owners") is Array or node.owners.size() != 1: return {"ready": false, "records": records}
		var owner: Dictionary = node.owners[0]
		if owner.get("partId") != part_id or owner.get("ordinal") != identity.emissionOrdinal or owner.get("instanceIndex") != 0: return {"ready": false, "records": records}
		if records.is_empty():
			projected = payload.duplicate()
			projected.visual = payload.visual.duplicate()
			projected.visual.primitives = payload.visual.primitives.duplicate()
		var copied: Dictionary = primitive.duplicate()
		copied.publisherNodeIdentity = identities.duplicate()
		copied.publisherNodeIdentity[0] = identity.duplicate()
		copied.publisherNodeIdentity[0].requestedLabel = "<engine-generated>"
		projected.visual.primitives[index] = copied
		records.append({"partId": part_id, "primitiveId": primitive.id, "ordinal": identity.emissionOrdinal,
			"nodeClass": node["class"], "rawNodePath": node.path, "rawRequestedLabel": label, "projectedLabel": "<engine-generated>"})
	return {"ready": true, "payload": projected, "records": records}

func _compare_original_identity(before: Dictionary, after: Dictionary, id: String, before_nodes: Dictionary, after_nodes: Dictionary) -> Dictionary:
	var old: Dictionary = _project_generated_identity(before, id, before_nodes)
	var current: Dictionary = _project_generated_identity(after, id, after_nodes)
	if not old.ready or not current.ready:
		return {"exact": false, "reason": "generated_label_raw_node_binding_failed", "identityNormalization": {"before": old.records, "after": current.records}}
	# Never collapse an authored literal (including the marker itself) into a
	# generated label, or silently change which primitive was normalized.
	var paired: bool = old.records.size() == current.records.size()
	if paired:
		for index in range(old.records.size()):
			for key in ["partId", "primitiveId", "ordinal", "nodeClass"]:
				paired = paired and old.records[index][key] == current.records[index][key]
	if not paired:
		return {"exact": false, "reason": "generated_label_projection_membership_changed", "identityNormalization": {"before": old.records, "after": current.records}}
	var comparison: Dictionary = _compare_channels(old.payload, current.payload)
	if not old.records.is_empty() or not current.records.is_empty():
		comparison["identityNormalization"] = {"before": old.records, "after": current.records,
			"scope": "raw_node_bound_generated_requested_label_only_other_fields_unchanged"}
	return comparison

func _captured_furniture_parity(before: Dictionary, after: Dictionary, ids: Array) -> Dictionary:
	var rows: Array = []
	var exact: bool = true
	for id in ids:
		if not _within_budget() or not _channels_valid(before.furniturePayloads[id]) or not _channels_valid(after.furniturePayloads[id]): break
		# Only raw generated-name diagnostics are outside the actual payload;
		# inherited comparison retains stable node identity and every material.
		var row: Dictionary = _compare_channels(before.furniturePayloads[id], after.furniturePayloads[id])
		row["partId"] = id
		rows.append(row)
		exact = exact and row.exact
	return {"complete": rows.size() == 152 and _within_budget(), "parityExact": exact and rows.size() == 152, "rows": rows}

func _verified_finish(value: Dictionary, id: String) -> Dictionary:
	var failure: Dictionary = {"complete": false, "cells": {}, "reason": "finish_arrays_frames_or_provenance"}
	var cycle: Dictionary = value.cycle
	if not cycle.payloads.has(id) or not _channels_valid(cycle.payloads[id]): return failure
	var primitives: Array = cycle.payloads[id].visual.primitives
	var emitted: Variant = cycle.finishValues.emitted.get(id)
	if not emitted is Array or emitted.size() != primitives.size(): return failure
	for index in range(emitted.size()):
		if not _within_budget(): return failure
		var row: Variant = emitted[index]
		var primitive: Dictionary = primitives[index]
		if not row is Dictionary or row.get("primitiveId") != primitive.id or row.get("transform") != primitive.transform or not row.get("arrays") is Array or row.arrays.is_empty() or row.arrays.size() > 64: return failure
		if row.get("arraysDigest") != _raw_digest(row.arrays) or primitive.meshDigest != _stable_digest(row.arrays): return failure
		for arrays in row.arrays:
			if not arrays is Array or arrays.size() != Mesh.ARRAY_MAX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array or arrays[Mesh.ARRAY_VERTEX].is_empty(): return failure
			for vertex in arrays[Mesh.ARRAY_VERTEX]:
				if not vertex.is_finite(): return failure
	if value.side == "before": return {"complete": true, "cells": {}}
	var artifact: Variant = cycle.finishValues.artifacts.get(id)
	if not artifact is Dictionary or artifact.get("completed") != true or artifact.get("stage") != "represented_publication_geometry" or not artifact.get("entries") is Array or artifact.entries.is_empty() or artifact.entries.size() > 8192: return failure
	var cells: Dictionary = {}
	var output: int = 0
	for entry in artifact.entries:
		if not _within_budget() or not entry is Dictionary or entry.has("mesh") or not entry.get("original") is Dictionary or not entry.get("unchanged") is bool or not entry.get("cells") is Array or not entry.get("emissionProof") is Dictionary: return failure
		var proof: Dictionary = entry.emissionProof
		if proof.get("removed", false):
			if entry.unchanged or not entry.cells.is_empty() or proof.get("noMeshAndNoCells") != true or entry.has("preparedMeshArrays"): return failure
			continue
		if output >= primitives.size(): return failure
		var primitive: Dictionary = primitives[output]
		var actual: Dictionary = emitted[output]
		output += 1
		if proof.get("primitiveId") != primitive.id or proof.get("frameExact") != true or primitive.transform != entry.original.get("transform") or proof.get("customExact") != true: return failure
		var custom: Variant = entry.original.get("customData")
		if entry.original.get("group") == "bed": custom = Color(0.5, 0.5, 0.5, 1.0) if value.mode == "static" else null
		if primitive.customData != custom: return failure
		if entry.unchanged:
			if primitive.type != "box" or primitive.meshClass != "BoxMesh" or entry.cells.size() != 1 or entry.cells[0].get("representation") != "native_box" or entry.cells[0].get("transform") != primitive.transform: return failure
			continue
		if proof.get("liveResourceIdentityExact") != true or proof.get("preparedEmittedArraysExact") != true or primitive.meshClass != "ArrayMesh" or not entry.get("preparedMeshArrays") is Array or entry.preparedMeshArrays.size() != 1: return failure
		if var_to_bytes(entry.preparedMeshArrays) != var_to_bytes(actual.arrays) or entry.get("preparedMeshArraysDigest") != _raw_digest(actual.arrays): return failure
		var reconstructed: Dictionary = _represented_cells(entry, primitive, actual.arrays[0])
		if not reconstructed.valid or var_to_bytes(reconstructed.bounds) != var_to_bytes(proof.get("representedCellBounds")): return failure
		cells[primitive.id] = reconstructed.bounds
	return {"complete": output == primitives.size() and _within_budget(), "cells": cells}

func _finish_parity(before: Dictionary, after: Dictionary, ids: Array) -> Dictionary:
	var rows: Array = []
	var bindings_exact: bool = _bindings_valid(after)
	var exact: bool = bindings_exact
	for id in ids:
		if not _within_budget(): break
		var old_verified: Dictionary = _verified_finish(before, id)
		var new_verified: Dictionary = _verified_finish(after, id)
		if not old_verified.complete or not new_verified.complete:
			rows.append({"partId": id, "exact": false, "reason": "replayed_finish_verification_failed"})
			exact = false
			continue
		var old: Dictionary = before.cycle.payloads[id]
		var current: Dictionary = after.cycle.payloads[id]
		var artifact: Dictionary = after.cycle.finishValues.artifacts[id]
		var valid: bool = artifact.entries.size() == old.visual.primitives.size() and var_to_bytes(old.collision) == var_to_bytes(current.collision)
		var details: Array = []
		var output: int = 0
		if valid:
			for index in range(artifact.entries.size()):
				if not _within_budget():
					valid = false
					break
				var entry: Dictionary = artifact.entries[index]
				var original: Dictionary = old.visual.primitives[index]
				if original.transform != entry.original.transform:
					valid = false
					break
				if entry.emissionProof.get("removed", false):
					details.append({"originalIndex": index, "sourceEntry": entry.original.id, "removed": true})
					continue
				var published: Dictionary = current.visual.primitives[output]
				var same: bool = original.transform == published.transform
				for key in ["materialDigests", "customData", "castShadow"]:
					same = same and var_to_bytes(original.get(key)) == var_to_bytes(published.get(key))
				if entry.unchanged:
					for key in ["type", "localMeshBounds", "meshDigest", "meshClass"]:
						same = same and var_to_bytes(original.get(key)) == var_to_bytes(published.get(key))
					same = same and var_to_bytes(before.cycle.finishValues.emitted[id][index].arrays) == var_to_bytes(after.cycle.finishValues.emitted[id][output].arrays)
				valid = valid and same
				details.append({"originalIndex": index, "sourceEntry": entry.original.id, "publishedId": published.id, "native": entry.unchanged, "exact": same})
				output += 1
		valid = valid and output == current.visual.primitives.size()
		rows.append({"partId": id, "exact": valid, "entries": details, "geometryDigest": artifact.geometryDigest, "constructionDigest": artifact.constructionDigest, "bedCustomComparedWithinMode": true})
		exact = exact and valid
	return {"complete": rows.size() == ids.size() and _within_budget(), "parityExact": exact and rows.size() == ids.size(), "rows": rows,
		"reason": "" if bindings_exact else "source_binding_mismatch"}

func _contact_member(after: Dictionary, member: String, others: Array) -> Dictionary:
	var rows: Array = []
	var pairs: int = 0
	var statuses: Dictionary = {}
	var order: HashingContext = HashingContext.new()
	order.start(HashingContext.HASH_SHA256)
	var cells: Dictionary = {}
	for id in _finish_ids:
		var verified: Dictionary = _verified_finish(after, id)
		if not verified.complete: return {"complete": false, "reason": "finish_geometry_not_verified", "rows": []}
		cells[id] = verified.cells
	var source: Dictionary = after.cycle.payloads[member]
	if not _channels_valid(source): return {"complete": false, "reason": "invalid_member_payload"}
	for other_id in others:
		if not _within_budget(): break
		var peer: Dictionary = after.furniturePayloads[other_id.trim_prefix("furnishing:")] if other_id.begins_with("furnishing:") else after.cycle.payloads[other_id]
		if not _channels_valid(peer): break
		for channel in ["visual", "collision"]:
			if not _within_budget(): break
			var measurement: Dictionary = _classify_validated_overlap(source[channel], peer[channel])
			if not _within_budget() or measurement.status in ["incomplete", "invalid_payload", "invalid"]: break
			pairs += 1
			_counts.partPairs += 1
			statuses[measurement.status] = int(statuses.get(measurement.status, 0)) + 1
			order.update(var_to_bytes([member, other_id, channel, measurement.status]))
			if measurement.status in ["certified_separated", "no_collision"]: continue
			var row: Dictionary = {"partId": member, "otherId": other_id, "channel": channel, "rawMeasurement": measurement, "reviewRequired": true}
			if channel == "visual" and cells.has(other_id):
				row["representedCellRefinement"] = _refine_cut_contacts(measurement, cells[other_id])
				if not row.representedCellRefinement.complete: break
			rows.append(row)
	return {"complete": pairs == others.size() * 2 and _within_budget(), "pairCount": pairs, "expectedPairCount": others.size() * 2,
		"statusCounts": statuses, "pairOrderDigest": order.finish().hex_encode(), "rows": rows, "contactAcceptance": false,
		"scope": "directed_new_member_vs_every_other_source_and_furnishing_both_channels_no_finish_exclusion"}

func _aggregate_shards() -> Dictionary:
	var result: Dictionary = {"complete": false, "reason": "missing_invalid_or_duplicate_shard", "acceptedJobs": [], "requiredJobCount": _jobs.size(), "contactArtifacts": []}
	if _jobs.size() > MAX_SHARDS or _manifest.get("shards", []).size() != _jobs.size(): return result
	var admitted: Dictionary = {}
	var totals: Dictionary = {}
	var work: Dictionary = {}
	for key in _counts: totals[key] = 0
	for key in _work: work[key] = 0
	var implementation: Dictionary = {}
	var pair_count: int = 0
	for descriptor in _manifest.shards:
		if not _within_budget(): return result
		var shard: Dictionary = _read_value(_binary_descriptor(descriptor), MAX_SHARD_BYTES)
		if not _shard_envelope_valid(shard) or admitted.has(shard.job) or not _admit_shard(descriptor, shard): return result
		var spec: Dictionary = _jobs[shard.job]
		var data: Dictionary = shard.result
		if not _result_coverage_valid(data, spec): return result
		admitted[shard.job] = spec
		if not _add_counters(totals, shard.counts) or not _add_counters(work, shard.extractionWork): return result
		if spec.kind == "audit":
			if not _add_counters(totals, data.get("captureCounts")) or not _add_counters(work, data.get("captureWork")): return result
			if implementation.is_empty(): implementation = data.implementationIdentity
			elif implementation != data.implementationIdentity:
				result.reason = "capture_implementation_identities_differ"
				return result
		elif spec.kind == "contacts":
			pair_count += data.pairCount
			result.contactArtifacts.append({"job": shard.job, "path": descriptor.path, "sha256": descriptor.sha256, "rawRows": data.rows.size(), "pairCount": data.pairCount})
		result.acceptedJobs.append(shard.job)
	if not _coverage_exact(_jobs, admitted): return result
	# Re-admit all captures from their terminal evidence, then hash binaries.
	# Never trust their earlier in-memory captureComplete flag alone.
	for stage in CPU_CAPTURE_STAGES:
		if not _admit_capture(stage): return result
		var descriptor: Dictionary = _manifest.captures[stage]
		if FileAccess.get_sha256(descriptor.path) != descriptor.sha256: return result
		_inputs_read[descriptor.path] = descriptor.sha256
	if not _identity_current(implementation): return result
	var expected_pairs: int = 2 * 7 * (_assembly.afterSnapshot.parts.size() + 152 - 1) * 2
	result["cumulativeCounts"] = totals
	result["cumulativeExtractionWork"] = work
	result["pairCount"] = pair_count
	result["expectedPairCount"] = expected_pairs
	result["cumulativeWorkWithinLimits"] = totals.publishedPrimitives <= MAX_PUBLISHED_PRIMITIVES and totals.primitiveTests <= MAX_PRIMITIVE_TESTS and totals.recordedContacts <= MAX_RECORDED_CONTACTS and work.nodes <= MAX_COLLECTED_NODES
	result.complete = result.cumulativeWorkWithinLimits and pair_count == expected_pairs and totals.partPairs == expected_pairs and _within_budget()
	result.reason = "raw_contacts_require_external_review" if result.complete else "cumulative_work_or_pair_coverage_failed"
	result["parityExact"] = true
	result["contactAcceptance"] = false
	result["coverage"] = {"jobs": _jobs.size(), "modes": ["standard", "static"], "sourceBefore": _assembly.beforeSnapshot.parts.size(), "sourceAfter": _assembly.afterSnapshot.parts.size(), "furniturePerMode": 152, "newMembersPerMode": 7}
	return result

func _shard_envelope_valid(value: Dictionary) -> bool:
	return value.get("schemaVersion") == COMPARE_SCHEMA and value.get("provenance") == "facade_paving_CPU_comparison_shard" and value.get("publicationAcceptance") == false and value.get("job") is String and _jobs.has(value.job) and value.get("binding") == _binding and value.get("result") is Dictionary and value.get("counts") is Dictionary and value.get("extractionWork") is Dictionary

func _admit_shard(descriptor: Dictionary, shard: Dictionary) -> bool:
	var report: Dictionary = _read_json(descriptor.report, 1024 * 1024)
	var watchdog: Dictionary = _read_json(descriptor.watchdog, MAX_MANIFEST_BYTES)
	if report.get("requestedStageCompleted") != true or report.get("status") != "comparison_shard_complete" or report.get("job") != shard.job or report.get("artifactSha256") != descriptor.sha256 or report.get("bindingDigest") != _raw_digest(_binding) or report.get("inputsUnchanged") != true or not _clean_watchdog(watchdog): return false
	if watchdog.get("sceneArguments") != [get_script().resource_path] or watchdog.get("headless") != true or not report.get("artifactPath") is String or not _same_path(report.artifactPath, descriptor.path): return false
	if not _same_path(descriptor.path.get_base_dir(), descriptor.report.path.get_base_dir()) or not _same_path(descriptor.path.get_base_dir(), descriptor.watchdog.path.get_base_dir()): return false
	for key in ["stdoutPath", "stderrPath"]:
		if not watchdog.get(key) is String or not _same_path(watchdog[key].get_base_dir(), descriptor.path.get_base_dir()): return false
		var log_file: FileAccess = FileAccess.open(watchdog[key], FileAccess.READ)
		if log_file == null: return false
		if log_file.get_length() > 1024 * 1024 or (key == "stderrPath" and log_file.get_length() != 0):
			log_file.close()
			return false
		var log_text: String = log_file.get_as_text()
		log_file.close()
		if log_text.contains("SCRIPT ERROR:") or log_text.contains("ERROR:"): return false
		_inputs_read[watchdog[key]] = FileAccess.get_sha256(watchdog[key])
	var file: FileAccess = FileAccess.open(descriptor.path, FileAccess.READ)
	if file == null: return false
	var size: int = file.get_length()
	file.close()
	return size == int(report.get("artifactBytes", -1))

func _result_coverage_valid(data: Dictionary, spec: Dictionary) -> bool:
	if data.get("complete") != true or data.get("coverage") != spec: return false
	if spec.kind == "audit":
		if spec.stage.begins_with("after_") and data.get("bindingReplayControl", {}).get("passed") != true: return false
		return data.get("sourceParts") == (_assembly.beforeSnapshot.parts.size() if spec.stage.begins_with("before_") else _assembly.afterSnapshot.parts.size()) and data.get("furnitureParts") == 152 and data.get("implementationIdentity") is Dictionary and data.get("finalReportSha256") == _manifest.captures[spec.stage].report.sha256 and data.get("watchdogSha256") == _manifest.captures[spec.stage].watchdog.sha256
	if spec.kind == "controls": return data.get("checks") is Dictionary and data.checks.size() >= 8 and data.checks.values().all(func(value): return value == true)
	if not data.get("rows") is Array: return false
	if spec.kind == "contacts":
		if data.get("pairCount") != spec.pairCount or data.get("expectedPairCount") != spec.pairCount or data.get("contactAcceptance") != false or not data.get("statusCounts") is Dictionary or not data.get("pairOrderDigest") is String or data.pairOrderDigest.length() != 64: return false
		var status_total: int = 0
		for key in data.statusCounts:
			if key not in ["certified_separated", "no_collision", "review_required"] or not data.statusCounts[key] is int or data.statusCounts[key] < 0: return false
			status_total += data.statusCounts[key]
		var seen: Dictionary = {}
		for row in data.rows:
			if not row is Dictionary or row.get("partId") != spec.memberId or row.get("otherId") not in spec.otherIds or row.get("channel") not in spec.channels or row.get("reviewRequired") != true or not row.get("rawMeasurement") is Dictionary: return false
			var key: String = row.otherId + ":" + row.channel
			if seen.has(key): return false
			seen[key] = true
		return status_total == spec.pairCount and data.rows.size() == int(data.statusCounts.get("review_required", 0))
	if data.get("parityExact") != true or data.rows.size() != spec.ids.size(): return false
	for index in range(spec.ids.size()):
		if not data.rows[index] is Dictionary or data.rows[index].get("partId") != spec.ids[index] or data.rows[index].get("exact") != true: return false
	return true

func _coverage_exact(required: Dictionary, actual: Dictionary) -> bool:
	if actual.size() != required.size(): return false
	for job in required:
		if not actual.has(job) or actual[job] != required[job]: return false
	return true

func _add_counters(total: Dictionary, extra: Variant) -> bool:
	if not extra is Dictionary or extra.size() != total.size(): return false
	for key in total:
		if not extra.get(key) is int or extra[key] < 0 or extra[key] > 100000000: return false
		total[key] += extra[key]
	return true

func _comparison_controls() -> Dictionary:
	var checks: Dictionary = {}
	var coverage: Dictionary = {"a": {"ids": ["x"]}, "b": {"ids": ["y"]}}
	checks["exact_coverage"] = _coverage_exact(coverage, coverage)
	checks["missing_shard_rejected"] = not _coverage_exact(coverage, {"a": coverage.a})
	checks["duplicate_range_rejected"] = not _coverage_exact(coverage, {"a": coverage.a, "b": coverage.a})
	checks["extra_shard_rejected"] = not _coverage_exact(coverage, {"a": coverage.a, "b": coverage.b, "c": {}})
	checks["empty_capture_rejected"] = not _capture_header_valid({}, "before_standard")
	checks["orphan_binary_rejected"] = not _final_capture_report_valid({}, "before_standard", {"sha256": "", "path": ""})
	checks["missing_watchdog_rejected"] = not _clean_watchdog({})
	var clean: Dictionary = {"schema": "godot-scene-watchdog/v5", "rootExited": true, "cleanupPassed": true, "authoritativeZeroProven": true, "finalMembershipKnown": true, "timedOut": false, "stopRequested": false, "forcedCleanup": false, "cleanupUnresolved": false, "terminalCleanupExpired": false, "functionalExitCode": 1, "overallExitCode": 1, "finalJobMemberPids": [], "monitoringException": null, "fatalException": null}
	checks["clean_watchdog_accepted"] = _clean_watchdog(clean)
	clean.functionalExitCode = 2
	checks["failed_exit_rejected"] = not _clean_watchdog(clean)
	clean.functionalExitCode = 1
	clean.forcedCleanup = true
	checks["forced_cleanup_rejected"] = not _clean_watchdog(clean)
	var planned: Dictionary = _required_jobs(_assembly)
	checks["bounded_job_inventory"] = planned.size() > 5 and planned.size() <= MAX_SHARDS
	for mode in ["standard", "static"]:
		var ids: Array = []
		for spec in planned.values():
			if spec.kind == "originals" and spec.mode == mode: ids.append_array(spec.ids)
		checks[mode + "_original_partition_exact"] = ids == _source_ids(_assembly.beforeSnapshot.parts).filter(func(id): return not _finish_ids.has(id))
	checks.merge(_generated_label_controls())
	return {"complete": checks.values().all(func(value): return value == true), "checks": checks, "evidenceLevel": "synthetic_protocol_controls_only"}

func _generated_label_fixture(label: String) -> Dictionary:
	var primitive: Dictionary = {"id": "visual:0", "type": "box", "transform": Transform3D.IDENTITY,
		"localMeshBounds": AABB(Vector3.ONE * -0.5, Vector3.ONE), "bounds": [-0.5, -0.5, -0.5, 0.5, 0.5, 0.5],
		"materialDigests": ["a".repeat(64)], "meshDigest": "b".repeat(64), "meshClass": "BoxMesh", "customData": Color(0.2, 0.3, 0.4, 1.0), "castShadow": 1,
		"publisherNodeIdentity": [{"sourcePartId": "synthetic_owner", "emissionOrdinal": 0, "requestedLabel": label}]}
	primitive.bounds = _payload_intervals(primitive.transform, primitive.localMeshBounds)
	return {"payload": {"visual": {"status": "published", "primitives": [primitive], "bounds": primitive.bounds.duplicate()},
		"collision": {"status": "no_collision", "primitives": [], "bounds": [], "shapes": []}},
		"nodes": [{"path": "0/" + label, "name": label, "class": "MeshInstance3D", "matched": true, "instanceCount": 1,
			"owners": [{"partId": "synthetic_owner", "ordinal": 0, "instanceIndex": 0}]}]}

func _fixture_identity_compare(before: Dictionary, after: Dictionary) -> Dictionary:
	return _compare_original_identity(before.payload, after.payload, "synthetic_owner", _single_owner_node_index(before.nodes), _single_owner_node_index(after.nodes))

func _generated_label_controls() -> Dictionary:
	var checks: Dictionary = {}
	var before: Dictionary = _generated_label_fixture("@MeshInstance3D@4130")
	var after: Dictionary = _generated_label_fixture("@MeshInstance3D@4136")
	var original_bytes: PackedByteArray = var_to_bytes([before, after])
	var positive: Dictionary = _fixture_identity_compare(before, after)
	checks["generated_positive_payloads_valid"] = _channels_valid(before.payload) and _channels_valid(after.payload)
	checks["generated_counter_only_exact"] = positive.exact
	checks["generated_raw_names_recorded"] = positive.get("identityNormalization", {}).get("before", []).size() == 1 and positive.get("identityNormalization", {}).get("after", []).size() == 1 and positive.identityNormalization.before[0].rawRequestedLabel == "@MeshInstance3D@4130" and positive.identityNormalization.after[0].rawRequestedLabel == "@MeshInstance3D@4136"
	checks["authored_label_change_rejected"] = not _fixture_identity_compare(_generated_label_fixture("AuthoredA"), _generated_label_fixture("AuthoredB")).exact
	checks["authored_marker_not_generated_label"] = not _fixture_identity_compare(_generated_label_fixture("<engine-generated>"), after).exact
	checks["noninteger_suffix_not_normalized"] = not _fixture_identity_compare(_generated_label_fixture("@MeshInstance3D@left"), _generated_label_fixture("@MeshInstance3D@right")).exact
	var bad: Dictionary = after.duplicate(true)
	bad.nodes[0].owners[0].partId = "wrong_owner"
	checks["generated_wrong_owner_rejected"] = not _fixture_identity_compare(before, bad).exact
	bad = after.duplicate(true)
	bad.nodes[0].owners[0].ordinal = 1
	checks["generated_wrong_ordinal_rejected"] = not _fixture_identity_compare(before, bad).exact
	bad = after.duplicate(true)
	bad.nodes[0]["class"] = "MultiMeshInstance3D"
	checks["generated_wrong_class_rejected"] = not _fixture_identity_compare(before, bad).exact
	bad = after.duplicate(true)
	bad.nodes[0].name = "@MeshInstance3D@9999"
	checks["generated_wrong_raw_name_rejected"] = not _fixture_identity_compare(before, bad).exact
	bad = after.duplicate(true)
	bad.nodes.clear()
	checks["generated_missing_node_rejected"] = not _fixture_identity_compare(before, bad).exact
	bad = after.duplicate(true)
	bad.nodes.append(bad.nodes[0].duplicate(true))
	checks["generated_ambiguous_node_rejected"] = not _fixture_identity_compare(before, bad).exact
	bad.nodes[1]["class"] = "MultiMeshInstance3D"
	bad.nodes[1].owners.append({"partId": "other_owner", "ordinal": 0, "instanceIndex": 1})
	bad.nodes[1].instanceCount = 2
	checks["generated_shared_batch_ambiguity_rejected"] = not _fixture_identity_compare(before, bad).exact
	bad = after.duplicate(true)
	bad.payload.visual.primitives[0].transform = Transform3D(Basis.IDENTITY, Vector3(0.25, 0.0, 0.0))
	bad.payload.visual.primitives[0].bounds = _payload_intervals(bad.payload.visual.primitives[0].transform, bad.payload.visual.primitives[0].localMeshBounds)
	bad.payload.visual.bounds = bad.payload.visual.primitives[0].bounds.duplicate()
	checks["generated_geometry_negative_payload_valid"] = _channels_valid(bad.payload)
	checks["generated_geometry_change_rejected"] = not _fixture_identity_compare(before, bad).exact
	bad = after.duplicate(true)
	bad.payload.visual.primitives[0].materialDigests = ["c".repeat(64)]
	checks["generated_material_change_rejected"] = not _fixture_identity_compare(before, bad).exact
	bad = after.duplicate(true)
	bad.payload.visual.primitives[0].customData = Color(0.9, 0.3, 0.4, 1.0)
	checks["generated_custom_change_rejected"] = not _fixture_identity_compare(before, bad).exact
	bad = after.duplicate(true)
	bad.payload.visual.primitives[0].castShadow = 0
	checks["generated_shadow_change_rejected"] = not _fixture_identity_compare(before, bad).exact
	bad = after.duplicate(true)
	bad.payload.collision["sourceFact"] = "changed"
	checks["generated_collision_change_rejected"] = not _fixture_identity_compare(before, bad).exact
	checks["generated_projection_inputs_byte_exact"] = var_to_bytes([before, after]) == original_bytes
	return checks

func _finish_comparison(job: String, result: Dictionary) -> void:
	var unchanged: bool = _within_budget()
	for path in _inputs_read:
		unchanged = unchanged and FileAccess.get_sha256(path) == _inputs_read[path] and _within_budget()
	if not _binding.is_empty(): unchanged = unchanged and FileAccess.get_sha256(get_script().resource_path) == _binding.comparisonSha256
	for value in _loaded.values(): unchanged = unchanged and _identity_current(value.implementationIdentity)
	if not _assembly.is_empty(): unchanged = unchanged and _check_contract_identity(_assembly.contractIdentity).exact
	var complete: bool = bool(result.get("complete", false)) and bool(result.get("parityExact", true)) and unchanged
	var envelope: Dictionary = {"schemaVersion": COMPARE_SCHEMA, "provenance": "facade_paving_CPU_comparison_shard",
		"job": job, "binding": _binding, "result": result, "counts": _counts, "extractionWork": _work,
		"elapsedMsec": Time.get_ticks_msec() - _started_msec, "publicationAcceptance": false}
	var report: Dictionary = {"job": job, "passed": false, "publicationAcceptance": false, "diagnosticCompleted": false,
		"requestedStageCompleted": false, "inputsUnchanged": unchanged, "bindingDigest": _raw_digest(_binding),
		"counts": _counts, "extractionWork": _work, "stopReason": _stop_reason,
		"reason": result.get("reason", ""), "resultComplete": result.get("complete", false),
		"parityExact": result.get("parityExact"), "rowCount": result.get("rows", []).size(),
		"limits": {"softMsec": SOFT_LIMIT_MSEC, "cpuBytesEach": MAX_CPU_ARTIFACT_BYTES, "loadedCyclesMaximum": 2, "shardBytes": MAX_SHARD_BYTES, "primitiveTestsCumulative": MAX_PRIMITIVE_TESTS, "recordedContactsCumulative": MAX_RECORDED_CONTACTS},
		"doesNotProve": "No live rendering, collision traversal or automatic acceptance. Raw contacts require external review; completion requires the exact full shard set."}
	if job == "inventory":
		report["requiredJobs"] = _jobs.keys()
		report["jobCount"] = _jobs.size()
	if job == "controls":
		report["controlChecks"] = result.get("checks", {})
	if job == "aggregate":
		for key in ["acceptedJobs", "requiredJobCount", "cumulativeCounts", "cumulativeExtractionWork", "pairCount", "expectedPairCount", "cumulativeWorkWithinLimits", "contactArtifacts"]:
			report[key] = result.get(key)
	var failures: Array = []
	for row in result.get("rows", []):
		if failures.size() >= 16: break
		if row.get("exact") == false: failures.append({"partId": row.get("partId"), "reason": row.get("reason", "payload_parity_mismatch")})
	report["firstFailures"] = failures
	_cpu_value_visits = 0
	var encoded: PackedByteArray = var_to_bytes(envelope) if _checkpoint_value_only(envelope, 0) else PackedByteArray()
	var written: bool = false
	if not encoded.is_empty() and encoded.size() <= MAX_SHARD_BYTES and _fresh_path(_compare_export, "bin"):
		var file: FileAccess = FileAccess.open(_compare_export, FileAccess.WRITE)
		if file != null:
			file.store_buffer(encoded)
			file.flush()
			written = file.get_error() == OK and file.get_position() == encoded.size()
			file.close()
			report["artifactPath"] = _compare_export
			report["artifactBytes"] = encoded.size()
			report["artifactSha256"] = _raw_digest(envelope)
			written = written and FileAccess.get_sha256(_compare_export) == report.artifactSha256
	complete = complete and written and _within_budget()
	report.requestedStageCompleted = complete
	report.diagnosticCompleted = complete and job == "aggregate"
	report["status"] = ("comparison_aggregate_complete_review_pending" if job == "aggregate" else "comparison_shard_complete") if complete else "comparison_incomplete_or_failed"
	report["elapsedMsec"] = Time.get_ticks_msec() - _started_msec
	_write_facade_report(_compare_path, report, 1 if complete else 2)

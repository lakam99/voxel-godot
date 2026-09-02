extends "res://scripts/testing/buildings/CitadelFacadePavingComparisonContract.gd"

## Value-only whole09 adapter. Uses inherited classifiers, mesh refinement,
## raw-node identity projection and terminal-bound shard serialization.
## Same VOXEL_FACADE_PAVING_COMPARE_* environment variables as the base.
## Manifest v1: candidate (whole09), legacyCandidate (assembly04), captures:
## after_standard/after_static (fresh), legacy_before_standard/static and
## legacy_after_standard/static (old). Descriptors retain the base
## {path,sha256,report:{path,sha256},watchdog:{path,sha256}} schema.
## dependencyInventory and sourceMapping are SHA-bound JSON descriptors.
## The three reviewed identity pairs below are the only permitted drift.
## shards retain the base format. No raw snapshot/payload is rewritten.
const COMBINED_SHA := "36ed79a46e014afd35c78fdf54cbbbb88730241165bd72c3c9491c8c7eb4d004"
const COMBINED_RUNNER := "res://scripts/testing/buildings/CitadelFacadeCombinedPublishedContract.gd"
const LEGACY_RUNNER := "res://scripts/testing/buildings/CitadelFacadePavingPublishedContract.gd"
const CAPTURE_KEYS := ["after_standard", "after_static", "legacy_before_standard", "legacy_before_static", "legacy_after_standard", "legacy_after_static"]
const CONTACT_MEMBERS_PER_SHARD := 4
# Exact reviewed capture dependency drift, never a filename-only exemption.
const REVIEWED_DRIFT := {
	"res://scripts/buildings/PavingFootingAssemblyRecipe.gd": ["389128666b0f5a68b22b25a8d0d957a4ebce664a794de8a6022b5ac5cb24b45b", "03d75271ab453c750c4b0078c79ad125f65846a346fb50bc9c29baaa54d7abf9"],
	"res://scripts/buildings/FacadeOpeningBearingRecipe.gd": ["e57d8e417e8c5b2c659e646e69d91ecb38d77d0fbc64509a1de991500be2e08d", "2ce0179ced25f462ecec7e8aeb6431fe0a5640568ed76c42eb5e01c7aa4452e2"],
	"res://scripts/buildings/FacadeBearingFrameBuilder.gd": ["ff43278ce3b4545780378dc894df66513539ca24e194c9b545298559996b50da", "60e42747b311603d1bf5e0a1f8d19e38a029e987c4dbed72f61237a3827f2291"],
}
const REVIEWED_ADAPTER_SHA := "4b9f7ae8b43cf8e53c3409253a1d8be4a4e0b8bb0889ba6ccfc2caa6c64a7878"
const REVIEWED_COPY_SHA := "189510934f6667caf193cf02a5710aa218689f40b2f1067354d106f61839109e"
const REVIEWED_MAPPING_SHA := "a31641d4e4bfcc0e2d9bb61eb7e8dd5371311f8ed84e94a6a034911ac0805246"
const GENERATOR_TEST_PATH := "res://scripts/testing/buildings/CitadelFacadePavingAssemblyContract.gd"
const GENERATOR_TEST_OLD := "212d5d7cf161595b589a793bb8c7d040c444e3e5160d9ef4de066b7c1fe23dff"
const GENERATOR_TEST_CURRENT := "db26d2a1232571f33255c1f96cdad65279539a3927d025d11665fabccf8a56bf"
const REVIEWED_COMPARISON_SHA := "403ed481a29567508823322e7a73321b2f2879e3c1bfc88d6bdfa61a3c85c725"
var _dependency_inventory: Dictionary = {}
var _source_mapping: Dictionary = {}
var _combined: Dictionary = {}
var _reuse: Dictionary = {}
var _drift: Dictionary = {}
var _allow_legacy: bool = false
var _identity_failure: String = ""

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	_compare_path = OS.get_environment("VOXEL_FACADE_PAVING_COMPARE_REPORT")
	_compare_export = OS.get_environment("VOXEL_FACADE_PAVING_COMPARE_EXPORT")
	var job: String = OS.get_environment("VOXEL_FACADE_PAVING_COMPARE_JOB")
	if not _fresh_path(_compare_path, "json") or not _fresh_path(_compare_export, "bin"):
		quit(2)
		return
	var descriptor: Dictionary = {"path": OS.get_environment("VOXEL_FACADE_PAVING_COMPARE_MANIFEST"), "sha256": OS.get_environment("VOXEL_FACADE_PAVING_COMPARE_MANIFEST_SHA256")}
	var decoded: Dictionary = _read_json(descriptor, MAX_MANIFEST_BYTES)
	if not _manifest_valid(decoded):
		_finish_comparison(job, {"complete": false, "reason": "combined_manifest_schema"})
		return
	_manifest = decoded
	if not _prepare_drift():
		_finish_comparison(job, {"complete": false, "reason": "unproven_identity_difference:" + _identity_failure})
		return
	var raw: Dictionary = _read_value(_manifest.candidate, MAX_ARTIFACT_BYTES)
	_combined = _adapt_combined(raw)
	_reuse = _read_value(_manifest.legacyCandidate, MAX_ARTIFACT_BYTES)
	if _combined.is_empty() or not _valid_assembly_archive(_reuse):
		_finish_comparison(job, {"complete": false, "reason": "combined_or_reuse_archive"})
		return
	_allow_legacy = false
	var current_exact: bool = _check_contract_identity(_combined.contractIdentity).exact
	_allow_legacy = true
	if not current_exact or not _check_contract_identity(_reuse.contractIdentity).exact:
		_finish_comparison(job, {"complete": false, "reason": "archive_identity:" + _identity_failure})
		return
	_assembly = _combined
	_finish_ids = _combined.pavingFinishPartIds.duplicate()
	var hashes: Array = []
	for stage in CAPTURE_KEYS:
		var capture: Dictionary = _manifest.captures[stage]
		hashes.append([stage, capture.sha256, capture.report.sha256, capture.watchdog.sha256])
	_binding = {"schemaVersion": COMPARE_SCHEMA, "candidateSha256": COMBINED_SHA, "reuseCandidateSha256": APPROVED_CANDIDATE_SHA,
		"captures": hashes, "comparisonSha256": FileAccess.get_sha256(get_script().resource_path),
		"baseComparisonSha256": FileAccess.get_sha256("res://scripts/testing/buildings/CitadelFacadePavingComparisonContract.gd"),
		"historicalGeneratorTest": {"path": GENERATOR_TEST_PATH, "oldSha256": GENERATOR_TEST_OLD, "currentSha256": GENERATOR_TEST_CURRENT, "proof": "exact_full_source_projection_of_changed_negative_expectation_only_not_invoked_by_capture"},
		"identityDifferences": _drift, "dependencyInventorySha256": _manifest.dependencyInventory.sha256, "sourceMappingSha256": _manifest.sourceMapping.sha256, "originalSlice": ORIGINAL_SLICE, "contactMembersPerShard": CONTACT_MEMBERS_PER_SHARD}
	_inputs_read["res://scripts/testing/buildings/CitadelFacadePavingComparisonContract.gd"] = _binding.baseComparisonSha256
	_jobs = _required_jobs(_assembly)
	var result: Dictionary = {"complete": false, "reason": "unknown_job"}
	if job == "inventory":
		result = {"complete": true, "requiredJobs": _jobs}
	elif job == "aggregate":
		result = _aggregate_shards()
	elif _jobs.has(job):
		var spec: Dictionary = _jobs[job]
		if spec.kind == "controls": result = _comparison_controls()
		elif spec.kind == "source_union": result = _source_union()
		elif spec.kind == "audit": result = _audit_capture(_load_capture(spec.stage), spec.stage)
		else:
			var after: Dictionary = _load_capture("after_" + spec.mode)
			var old: Dictionary = {} if spec.kind == "contacts" else _load_capture(("legacy_before_" if spec.kind == "finishes" else "legacy_after_") + spec.mode)
			if after.is_empty() or (spec.kind != "contacts" and old.is_empty()):
				result = {"complete": false, "reason": "capture_admission_or_identity:" + _identity_failure}
			elif spec.kind == "originals": result = _original_slice(old, after, spec.ids)
			elif spec.kind == "furniture": result = _captured_furniture_parity(old, after, spec.ids)
			elif spec.kind == "finishes": result = _finish_parity(old, after, spec.ids)
			else: result = _contact_group(after, spec)
		result["coverage"] = spec
	result["sourceExact"] = false
	result["allDifferencesAccountedFor"] = false
	result["publicationAcceptance"] = false
	result["identityDifferences"] = _drift
	_finish_comparison(job, result)

func _manifest_valid(value: Variant) -> bool:
	if not value is Dictionary or value.get("schemaVersion") != 1 or not _descriptor_valid(value.get("candidate")) or not _descriptor_valid(value.get("legacyCandidate")): return false
	if value.candidate.sha256 != COMBINED_SHA or value.legacyCandidate.sha256 != APPROVED_CANDIDATE_SHA: return false
	if not value.get("captures") is Dictionary or value.captures.size() != CAPTURE_KEYS.size() or not _descriptor_valid(value.get("dependencyInventory")) or not _descriptor_valid(value.get("sourceMapping")): return false
	var paths: Dictionary = {}
	for item in [value.candidate, value.legacyCandidate, value.dependencyInventory, value.sourceMapping]:
		var path: String = item.path.replace("\\", "/").simplify_path()
		if paths.has(path): return false
		paths[path] = true
	var descriptors: Array = []
	for stage in CAPTURE_KEYS:
		if not value.captures.get(stage) is Dictionary: return false
		descriptors.append(value.captures[stage])
	if not value.get("shards", []) is Array or value.get("shards", []).size() > MAX_SHARDS: return false
	descriptors.append_array(value.get("shards", []))
	for capture in descriptors:
		if not capture is Dictionary or capture.size() != 4: return false
		for item in [_binary_descriptor(capture), capture.get("report"), capture.get("watchdog")]:
			if not _descriptor_valid(item): return false
			var path: String = item.path.replace("\\", "/").simplify_path()
			if paths.has(path): return false
			paths[path] = true
	return true

func _adapt_combined(source: Dictionary) -> Dictionary:
	if not _valid_facade_archive(source) or source.get("mainShardPassed") != true or source.get("pairedAcceptancePending") != true or source.get("partIds", []).size() != 16 or source.afterSnapshot.parts.size() != 4298 or source.furnitureSnapshot.parts.size() != 152 or not source.get("pavingFinishPartIds") is Array or source.pavingFinishPartIds.size() != 1 or not source.get("contractIdentity") is Dictionary: return {}
	var policy: Dictionary = {"furnitureParts": source.furnitureSnapshot.parts, "reservedVolumes": source.protectedReservations}
	for pair in [[source.beforeSnapshot, source.get("sourceDigest")], [source.afterSnapshot, source.get("outputDigest")], [source.fixture, source.get("fixtureDigest")], [policy, source.get("policyDigest")]]:
		if var_to_bytes(pair[0]).hex_encode().sha256_text() != pair[1]: return {}
	var adapted: Dictionary = source.duplicate()
	for pair in [["sourceDigest", source.beforeSnapshot], ["afterDigest", source.afterSnapshot], ["fixtureDigest", source.fixture], ["policyDigest", policy], ["furnitureDigest", source.furnitureSnapshot], ["reservationDigest", source.protectedReservations]]:
		adapted[pair[0]] = _raw_digest(pair[1])
	var declared: Array = []
	for part in source.afterSnapshot.parts:
		if not part.get("recipe") is Dictionary: return {}
		if part.recipe.has("pavingFootingJoints"): declared.append(part.id)
	if declared != source.pavingFinishPartIds: return {}
	return adapted

func _prepare_drift() -> bool:
	if FileAccess.get_sha256("res://scripts/testing/buildings/CitadelFacadePavingComparisonContract.gd") != REVIEWED_COMPARISON_SHA: return false
	# Generator-test provenance is distinct from the executed capture closure.
	# This test is not invoked here. Its only change is the expected rejection
	# reason in an invalid prior-foot fixture; reconstruct the entire old file.
	var generator_source: String = FileAccess.get_file_as_string(GENERATOR_TEST_PATH)
	if generator_source.sha256_text() != GENERATOR_TEST_CURRENT: return false
	var generator_projection: String = generator_source.replace("expected = \"invalid_prior_foot\"", "expected = \"missing_or_already_jointed_paving_finish\"")
	if generator_projection.sha256_text() != GENERATOR_TEST_OLD: return false
	_inputs_read[GENERATOR_TEST_PATH] = GENERATOR_TEST_CURRENT
	_dependency_inventory = _read_json(_manifest.dependencyInventory, MAX_SHARD_BYTES)
	_source_mapping = _read_json(_manifest.sourceMapping, MAX_SHARD_BYTES)
	if _dependency_inventory.get("diagnosticCompleted") != true or _dependency_inventory.get("publicationAcceptance") != false or _dependency_inventory.get("sameNewModeIdentity") != true or _dependency_inventory.get("sameOldModeIdentity") != true or not _dependency_inventory.get("identities") is Dictionary: return false
	if not _source_mapping.get("inputBindings") is Dictionary or _source_mapping.inputBindings.get("combined", []).size() != 2 or _source_mapping.inputBindings.get("civic", []).size() != 2: return false
	if _source_mapping.inputBindings.combined[1] != COMBINED_SHA or _source_mapping.inputBindings.civic[1] != APPROVED_CANDIDATE_SHA: return false
	var identities: Dictionary = _dependency_inventory.identities
	var inventory_stages: Dictionary = {"new_standard": "after_standard", "new_static": "after_static", "old_standard": "legacy_after_standard", "old_static": "legacy_after_static"}
	if not _dependency_inventory.get("inputBindings") is Dictionary: return false
	for key in inventory_stages:
		var input: Variant = _dependency_inventory.inputBindings.get(key)
		if not input is Array or input.size() != 2 or input[1] != _manifest.captures[inventory_stages[key]].sha256: return false
	for key in ["new_standard", "new_static", "old_standard", "old_static"]:
		if not identities.get(key) is Dictionary: return false
	if identities.new_standard != identities.new_static or identities.old_standard != identities.old_static: return false
	var old: Dictionary = identities.old_standard
	var current: Dictionary = identities.new_standard
	if current.size() != old.size() + 1 or current.get(COMBINED_RUNNER) != REVIEWED_ADAPTER_SHA or old.has(COMBINED_RUNNER): return false
	for path in old:
		if not current.has(path): return false
		if old[path] == current[path]: continue
		_identity_failure = path
		if not REVIEWED_DRIFT.has(path) or [old[path], current[path]] != REVIEWED_DRIFT[path]: return false
		_drift[path] = {"oldSha256": old[path], "currentSha256": current[path], "scope": "reviewed_exact_callable_closure"}
	if _drift.size() != 3: return false
	for path in current:
		if not path is String or FileAccess.get_sha256(path) != current[path]: return false
		_inputs_read[path] = current[path]
	# Exact reconstruction of the entire historical Assembly source, including
	# every old called body/constant. Only extension functions + inert preload
	# are removed; a change anywhere else fails the historical SHA.
	var assembly_path: String = "res://scripts/buildings/PavingFootingAssemblyRecipe.gd"
	var source: String = FileAccess.get_file_as_string(assembly_path)
	var preload_line: RegEx = RegEx.new()
	if preload_line.compile("(?m)^const Part = preload.*\\r?\\n") != OK: return false
	var projected: String = preload_line.sub(source, "", true)
	var start: int = projected.find("## Extend explicit per-finish membership")
	var end: int = projected.find("static func _failure", start)
	if start < 0 or end <= start: return false
	projected = projected.substr(0, start) + projected.substr(end)
	if projected.sha256_text() != REVIEWED_DRIFT[assembly_path][0]: return false
	_drift[assembly_path]["legacyFullSourceProjectionSha256"] = projected.sha256_text()
	var facade_path: String = "res://scripts/buildings/FacadeOpeningBearingRecipe.gd"
	var facade_source: String = FileAccess.get_file_as_string(facade_path)
	var copy_start: int = facade_source.find("static func copy_blueprint(")
	var copy_end: int = facade_source.find("static func validation_grid_work(", copy_start)
	if copy_start < 0 or copy_end <= copy_start or facade_source.substr(copy_start, copy_end - copy_start).sha256_text() != REVIEWED_COPY_SHA: return false
	_drift[facade_path]["currentCopyBlueprintSha256"] = REVIEWED_COPY_SHA
	# Facade copy_blueprint is actually invoked, not waived. Its captured
	# copyExact/input/post digests are mandatory in every inherited audit.
	# These exact reviewed files have only static functions/constants/preloads;
	# no instance/static initialization or Frame method executes in the cycle.
	for path in ["res://scripts/buildings/FacadeOpeningBearingRecipe.gd", "res://scripts/buildings/FacadeBearingFrameBuilder.gd"]:
		var text_value: String = FileAccess.get_file_as_string(path)
		for line in text_value.split("\n"):
			if line.begins_with("var ") or line.begins_with("static var ") or line.begins_with("func ") or line.begins_with("static func _static_init("): return false
		_drift[path]["sourceHandoffProof"] = "full_lifecycle_copyExact_and_input_digest_required" if path.ends_with("FacadeOpeningBearingRecipe.gd") else "no_frame_call_in_frozen_publication_cycle"
	_identity_failure = ""
	return true

func _identity_current(expected: Variant) -> bool:
	if not expected is Dictionary or expected.is_empty() or expected.size() > 512: return false
	for path in expected:
		if not path is String or not path.begins_with("res://scripts/") or not expected[path] is String or expected[path].length() != 64 or not _within_budget(): return false
		var actual: String = FileAccess.get_sha256(path)
		if actual == expected[path]: continue
		if _allow_legacy and path == GENERATOR_TEST_PATH and expected[path] == GENERATOR_TEST_OLD and actual == GENERATOR_TEST_CURRENT: continue
		var allowed: Dictionary = _drift.get(path, {})
		if not _allow_legacy or allowed.get("oldSha256") != expected[path] or allowed.get("currentSha256") != actual:
			_identity_failure = path
			return false
	return true

func _check_contract_identity(expected: Dictionary) -> Dictionary:
	return {"exact": expected.size() <= 32 and _identity_current(expected), "rows": [], "allowedDifferences": _drift}

func _archive_for(stage: String) -> Dictionary:
	return _combined if stage.begins_with("after_") else _reuse

func _actual_stage(stage: String) -> String:
	return stage.trim_prefix("legacy_")

func _admit_capture(stage: String) -> bool:
	if _admissions.has(stage): return true
	var descriptor: Dictionary = _manifest.captures[stage]
	var report: Dictionary = _read_json(descriptor.report, 1024 * 1024)
	var watchdog: Dictionary = _read_json(descriptor.watchdog, MAX_MANIFEST_BYTES)
	if not _final_capture_report_valid(report, stage, descriptor) or not _clean_watchdog(watchdog): return false
	var runner: String = COMBINED_RUNNER if stage.begins_with("after_") else LEGACY_RUNNER
	if watchdog.get("sceneArguments") != [runner] or watchdog.get("headless") != true: return false
	var directory: String = descriptor.path.get_base_dir()
	if not _same_path(directory, descriptor.report.path.get_base_dir()) or not _same_path(directory, descriptor.watchdog.path.get_base_dir()): return false
	for name in ["stdoutPath", "stderrPath"]:
		if not watchdog.get(name) is String or not _same_path(directory, watchdog[name].get_base_dir()): return false
		var log_file: FileAccess = FileAccess.open(watchdog[name], FileAccess.READ)
		if log_file == null: return false
		var length: int = log_file.get_length()
		if length > 1024 * 1024 or (name == "stderrPath" and length != 0):
			log_file.close()
			return false
		var content: String = log_file.get_as_text()
		log_file.close()
		if content.contains("SCRIPT ERROR:") or content.contains("ERROR:"): return false
		_inputs_read[watchdog[name]] = FileAccess.get_sha256(watchdog[name])
	var binary: FileAccess = FileAccess.open(descriptor.path, FileAccess.READ)
	if binary == null: return false
	var size: int = binary.get_length()
	binary.close()
	if size != int(report.cpuArtifactBytes) or size <= 0 or size > MAX_CPU_ARTIFACT_BYTES: return false
	_admissions[stage] = {"report": report, "watchdog": watchdog}
	return true

func _final_capture_report_valid(report: Dictionary, stage: String, descriptor: Dictionary) -> bool:
	if not CAPTURE_KEYS.has(stage) or not report.get("contractIdentity") is Dictionary or not report.get("collectorControls") is Dictionary or not (report.get("cpuArtifactBytes") is int or report.get("cpuArtifactBytes") is float): return false
	if not report.get("bindingCaptureControls") is Dictionary or report.bindingCaptureControls.get("passed") != true: return false
	var expected_sha: String = COMBINED_SHA if stage.begins_with("after_") else APPROVED_CANDIDATE_SHA
	return report.get("requestedStage") == _actual_stage(stage) and report.get("requestedStageCompleted") == true and report.get("status") == "cycle_export_complete_aggregation_pending" and report.get("stopReason") == "" and report.get("immutableInputUnchanged") == true and report.get("implementationAndSourceIdentityUnchanged") == true and report.get("cpuArtifactSha256") == descriptor.sha256 and report.get("cpuArtifactBytes", 0) > 0 and report.get("cpuArtifactPath") is String and _same_path(report.cpuArtifactPath, descriptor.path) and report.get("inputSha256") == expected_sha and report.contractIdentity.get("exact") == true and report.collectorControls.get("passed") == true

func _capture_header_valid(value: Dictionary, stage: String) -> bool:
	if not CAPTURE_KEYS.has(stage): return false
	var expected_identity: Dictionary = _dependency_inventory.get("identities", {}).get("new_standard" if stage.begins_with("after_") else "old_standard", {})
	if expected_identity.is_empty() or value.get("implementationIdentity") != expected_identity: return false
	var previous: Dictionary = _assembly
	var candidate: Dictionary = _manifest.candidate
	_assembly = _archive_for(stage)
	_manifest.candidate = candidate if stage.begins_with("after_") else _manifest.legacyCandidate
	_allow_legacy = not stage.begins_with("after_")
	var valid: bool = super._capture_header_valid(value, _actual_stage(stage))
	var inventory_key: String = ("new_" if stage.begins_with("after_") else "old_") + ("static" if stage.ends_with("_static") else "standard")
	valid = valid and value.get("implementationIdentity") == _dependency_inventory.identities.get(inventory_key)
	if stage.begins_with("after_"):
		valid = valid and value.get("implementationIdentity", {}).has(COMBINED_RUNNER)
	_assembly = previous
	_manifest.candidate = candidate
	_allow_legacy = true
	return valid

func _audit_capture(value: Dictionary, stage: String) -> Dictionary:
	var previous: Dictionary = _assembly
	_assembly = _archive_for(stage)
	var result: Dictionary = super._audit_capture(value, stage)
	_assembly = previous
	return result

func _required_jobs(assembly: Dictionary) -> Dictionary:
	var jobs: Dictionary = {"controls": {"kind": "controls"}, "source_union": {"kind": "source_union"}}
	for stage in CAPTURE_KEYS: jobs["audit:" + stage] = {"kind": "audit", "stage": stage}
	var originals: Array = _source_ids(assembly.afterSnapshot.parts).filter(func(id): return not assembly.partIds.has(id) and not assembly.pavingFinishPartIds.has(id))
	var members: Array = assembly.partIds.duplicate()
	members.sort()
	var furniture: Array = _source_ids(assembly.furnitureSnapshot.parts)
	var others: Array = _source_ids(assembly.afterSnapshot.parts)
	for id in furniture: others.append("furnishing:" + id)
	others.sort()
	for mode in ["standard", "static"]:
		for start in range(0, originals.size(), ORIGINAL_SLICE):
			jobs[mode + ":originals:" + str(start / ORIGINAL_SLICE)] = {"kind": "originals", "mode": mode, "ids": originals.slice(start, mini(start + ORIGINAL_SLICE, originals.size()))}
		jobs[mode + ":furniture"] = {"kind": "furniture", "mode": mode, "ids": furniture}
		jobs[mode + ":finishes"] = {"kind": "finishes", "mode": mode, "ids": assembly.pavingFinishPartIds.duplicate()}
		for start in range(0, members.size(), CONTACT_MEMBERS_PER_SHARD):
			var pieces: Array = []
			for member in members.slice(start, mini(start + CONTACT_MEMBERS_PER_SHARD, members.size())):
				var peers: Array = others.filter(func(id): return id != member)
				pieces.append({"kind": "contacts", "mode": mode, "memberId": member, "otherIds": peers, "channels": ["visual", "collision"], "pairCount": peers.size() * 2})
			jobs[mode + ":contacts:" + str(start / CONTACT_MEMBERS_PER_SHARD)] = {"kind": "contacts", "mode": mode, "members": pieces, "pairCount": pieces.size() * (others.size() - 1) * 2}
	return jobs

func _contact_group(after: Dictionary, spec: Dictionary) -> Dictionary:
	var pieces: Array = []
	var rows: Array = []
	var pairs: int = 0
	for piece in spec.members:
		if not _within_budget(): break
		var result: Dictionary = _contact_member(after, piece.memberId, piece.otherIds)
		result["coverage"] = piece
		pieces.append(result)
		rows.append_array(result.get("rows", []))
		pairs += int(result.get("pairCount", 0))
		if not result.complete: break
	return {"complete": pieces.size() == spec.members.size() and pieces.all(func(item): return item.complete) and _within_budget(),
		"members": pieces, "rows": rows, "pairCount": pairs, "expectedPairCount": spec.pairCount, "contactAcceptance": false}

func _source_union() -> Dictionary:
	var old: Dictionary = {}
	var current: Dictionary = {}
	for record in _reuse.afterSnapshot.parts: old[record.id] = record
	for record in _combined.afterSnapshot.parts: current[record.id] = record
	var rows: Array = []
	var complete: bool = _mapping_admitted() and var_to_bytes(_reuse.beforeSnapshot) == var_to_bytes(_combined.beforeSnapshot) and var_to_bytes(_reuse.furnitureSnapshot) == var_to_bytes(_combined.furnitureSnapshot)
	var permitted: Array = _source_mapping.get("mapping", {}).get("mismatchedIds", []).duplicate()
	for id in _combined.memberIds:
		if not _reuse.memberIds.has(id) and not permitted.has(id): permitted.append(id)
	for id in old:
		if not _within_budget() or not current.has(id):
			complete = false
			break
		var exact: bool = var_to_bytes(old[id]) == var_to_bytes(current[id])
		if not exact: rows.append({"partId": id, "beforeRecordDigest": _raw_digest(old[id]), "afterRecordDigest": _raw_digest(current[id]), "sourceExact": false})
		if not exact and not permitted.has(id): complete = false
		# Original panel metadata may differ. Their complete emitted payloads
		# remain mandatory originals jobs; no field stripping makes them pass.
	var added: Array = current.keys().filter(func(id): return not old.has(id))
	added.sort()
	var expected: Array = _combined.partIds.filter(func(id): return not _reuse.partIds.has(id))
	expected.sort()
	complete = complete and added == expected and _reuse.partIds.all(func(id): return _combined.partIds.has(id))
	return {"complete": complete and _within_budget(), "sourceExact": false, "rawRecordsUnmodified": true,
		"rows": rows, "newBeyondReuse": added, "sourceMappingPassed": _source_mapping.get("passed"), "sourceMappingAdmitted": _mapping_admitted(), "sourceMappingSha256": _manifest.sourceMapping.sha256,
		"beforeSourceDigest": _reuse.sourceDigest, "combinedBeforeSourceDigest": _combined.sourceDigest,
		"reason": "raw_differences_reported_payload_parity_still_required" if complete else "source_union_or_base_snapshot_mismatch"}

func _mapping_admitted() -> bool:
	# This exact historical evidence remains RED; admission is not acceptance.
	if _manifest.sourceMapping.sha256 != REVIEWED_MAPPING_SHA or _source_mapping.get("passed") != false or not _source_mapping.get("checks") is Array or _source_mapping.checks.size() != 9: return false
	var expected: Array = ["all_bound_inputs", "exact_complete_record_union", "same_baseline", "all_source_shells_exact", "all_furniture_exact", "all_reservations_exact", "history_and_canonical_publication_inputs_exact", "changed_geometry_rejected", "missing_addition_rejected"]
	var seen: Dictionary = {}
	for check in _source_mapping.checks:
		if not check is Dictionary or check.get("label") not in expected or seen.has(check.label): return false
		if check.get("passed") != (check.label != "exact_complete_record_union"): return false
		seen[check.label] = true
	var mapping: Variant = _source_mapping.get("mapping")
	if not mapping is Dictionary or mapping.get("exact") != false or mapping.get("clashes") != [] or mapping.get("expectedPartCount") != 4298 or mapping.get("actualPartCount") != 4298 or not mapping.get("differences") is Dictionary or not mapping.get("mismatchedIds") is Array: return false
	var ids: Array = mapping.differences.keys()
	ids.sort()
	var mismatched: Array = mapping.mismatchedIds.duplicate()
	mismatched.sort()
	return ids.size() == 7 and ids == mismatched

func _comparison_controls() -> Dictionary:
	var result: Dictionary = super._comparison_controls()
	result.checks["six_capture_stages"] = CAPTURE_KEYS.size() == 6
	result.checks["red_mapping_admitted_without_rewriting"] = _mapping_admitted() and _source_mapping.passed == false
	result.checks["unknown_stage_rejected"] = not _capture_header_valid({}, "unknown")
	result.checks["fresh_capture_wrong_input_rejected"] = not _final_capture_report_valid({}, "after_standard", {"path": "", "sha256": ""})
	for mode in ["standard", "static"]:
		var members: Array = []
		var count: int = 0
		for spec in _jobs.values():
			if spec.kind != "contacts" or spec.mode != mode: continue
			for piece in spec.members:
				members.append(piece.memberId)
				count += piece.pairCount
				result.checks[mode + ":no_self:" + piece.memberId] = not piece.otherIds.has(piece.memberId)
		var expected: Array = _combined.partIds.duplicate()
		expected.sort()
		result.checks[mode + ":all_sixteen_once"] = members == expected
		result.checks[mode + ":exact_pairs"] = count == 16 * (4298 + 152 - 1) * 2
	result.complete = result.checks.values().all(func(value): return value == true)
	return result

func _result_coverage_valid(data: Dictionary, spec: Dictionary) -> bool:
	if data.get("complete") != true or data.get("coverage") != spec: return false
	if spec.kind == "source_union": return data.get("sourceExact") == false and data.get("rawRecordsUnmodified") == true and data.get("sourceMappingPassed") == false and data.get("sourceMappingAdmitted") == true and _mapping_admitted() and data.get("sourceMappingSha256") == _manifest.sourceMapping.sha256 and data.get("beforeSourceDigest") == _reuse.sourceDigest and data.get("combinedBeforeSourceDigest") == _combined.sourceDigest
	if spec.kind == "audit":
		var previous: Dictionary = _assembly
		_assembly = _archive_for(spec.stage)
		# Base checks snapshot side from stage prefix, while admission retains
		# the unique manifest key and terminal hashes.
		var valid: bool = data.get("sourceParts") == (_assembly.beforeSnapshot.parts.size() if _actual_stage(spec.stage).begins_with("before_") else _assembly.afterSnapshot.parts.size()) and data.get("furnitureParts") == 152 and data.get("implementationIdentity") is Dictionary and _identity_current(data.implementationIdentity) and data.get("finalReportSha256") == _manifest.captures[spec.stage].report.sha256 and data.get("watchdogSha256") == _manifest.captures[spec.stage].watchdog.sha256
		if not _actual_stage(spec.stage).begins_with("before_"): valid = valid and data.get("bindingReplayControl", {}).get("passed") == true
		_assembly = previous
		return valid
	if spec.kind == "contacts":
		if not data.get("members") is Array or data.members.size() != spec.members.size() or data.get("pairCount") != spec.pairCount or data.get("expectedPairCount") != spec.pairCount or data.get("contactAcceptance") != false: return false
		var rows: Array = []
		for index in range(spec.members.size()):
			if not super._result_coverage_valid(data.members[index], spec.members[index]): return false
			rows.append_array(data.members[index].rows)
		return var_to_bytes(rows) == var_to_bytes(data.get("rows"))
	return super._result_coverage_valid(data, spec)

func _aggregate_shards() -> Dictionary:
	var result: Dictionary = {"complete": false, "reason": "missing_invalid_or_duplicate_shard", "acceptedJobs": [], "requiredJobCount": _jobs.size(), "contactArtifacts": []}
	if _jobs.size() > MAX_SHARDS or _manifest.get("shards", []).size() != _jobs.size(): return result
	var admitted: Dictionary = {}
	var totals: Dictionary = {}
	var work: Dictionary = {}
	for key in _counts: totals[key] = 0
	for key in _work: work[key] = 0
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
		elif spec.kind == "contacts":
			pair_count += data.pairCount
			result.contactArtifacts.append({"job": shard.job, "path": descriptor.path, "sha256": descriptor.sha256, "rawRows": data.rows.size(), "pairCount": data.pairCount})
		result.acceptedJobs.append(shard.job)
	if not _coverage_exact(_jobs, admitted): return result
	for stage in CAPTURE_KEYS:
		if not _admit_capture(stage): return result
		var descriptor: Dictionary = _manifest.captures[stage]
		if FileAccess.get_sha256(descriptor.path) != descriptor.sha256: return result
		_inputs_read[descriptor.path] = descriptor.sha256
	var expected_pairs: int = 2 * 16 * (4298 + 152 - 1) * 2
	result["cumulativeCounts"] = totals
	result["cumulativeExtractionWork"] = work
	result["pairCount"] = pair_count
	result["expectedPairCount"] = expected_pairs
	result["cumulativeWorkWithinLimits"] = totals.publishedPrimitives <= MAX_PUBLISHED_PRIMITIVES and totals.primitiveTests <= MAX_PRIMITIVE_TESTS and totals.recordedContacts <= MAX_RECORDED_CONTACTS and work.nodes <= MAX_COLLECTED_NODES
	result.complete = result.cumulativeWorkWithinLimits and pair_count == expected_pairs and totals.partPairs == expected_pairs and _within_budget()
	result.reason = "raw_contacts_require_external_review" if result.complete else "cumulative_work_or_pair_coverage_failed"
	result["parityExact"] = true
	result["contactAcceptance"] = false
	result["coverage"] = {"jobs": _jobs.size(), "modes": ["standard", "static"], "sourceAfter": 4298, "furniturePerMode": 152, "newMembersPerMode": 16}
	return result

extends "res://scripts/testing/buildings/CitadelFacadePavingContactExport.gd"

## Format conversion only. Same VOXEL_FACADE_PAVING_CONTACT_MANIFEST,
## _MANIFEST_SHA256 and _REPORT variables as the parent; fresh absolute JSON.
## Manifest {schemaVersion:1,aggregate:{path,sha256,report:{path,sha256},
## watchdog:{path,sha256}},candidate:{path,sha256}}. No publication/acceptance.
const COMBINED_COMPARATOR := "res://scripts/testing/buildings/CitadelFacadeCombinedComparisonContract.gd"
const COMBINED_COMPARATOR_SHA := "3729ff24e4cfa24f9f6c0be36c22c7ca1ddcfa3614a321897515ee82779f8d0a"
const CANDIDATE_SHA := "36ed79a46e014afd35c78fdf54cbbbb88730241165bd72c3c9491c8c7eb4d004"

func _run() -> void:
	_started = Time.get_ticks_msec()
	_output = OS.get_environment("VOXEL_FACADE_PAVING_CONTACT_REPORT")
	if not _output.is_absolute_path() or _output.get_extension() != "json" or FileAccess.file_exists(_output) or not DirAccess.dir_exists_absolute(_output.get_base_dir()):
		quit(2)
		return
	var input: Dictionary = {"path": OS.get_environment("VOXEL_FACADE_PAVING_CONTACT_MANIFEST"), "sha256": OS.get_environment("VOXEL_FACADE_PAVING_CONTACT_MANIFEST_SHA256")}
	var manifest: Dictionary = _json_file(input, 65536)
	if manifest.get("schemaVersion") != 1 or not _triple_descriptor(manifest.get("aggregate")) or not _descriptor(manifest.get("candidate")) or manifest.candidate.sha256 != CANDIDATE_SHA or FileAccess.get_sha256(COMBINED_COMPARATOR) != COMBINED_COMPARATOR_SHA:
		_finish({}, "manifest_or_comparator")
		return
	for path in [COMBINED_COMPARATOR, get_script().resource_path, "res://scripts/testing/buildings/CitadelFacadePavingContactExport.gd"]:
		_inputs[path] = FileAccess.get_sha256(path)
	var aggregate: Dictionary = _binary_file(manifest.aggregate)
	if not _envelope(aggregate) or aggregate.get("job") != "aggregate" or not _aggregate_terminal(manifest.aggregate, aggregate):
		_finish({}, "aggregate_binding_or_terminal")
		return
	var result: Dictionary = aggregate.result
	if result.get("complete") != true or result.get("parityExact") != true or result.get("contactAcceptance") != false or result.get("pairCount") != 284736 or result.get("expectedPairCount") != 284736 or result.get("cumulativeWorkWithinLimits") != true or not result.get("contactArtifacts") is Array or result.contactArtifacts.size() != 8:
		_finish({}, "aggregate_incomplete")
		return
	var candidate: Dictionary = _binary_file(manifest.candidate)
	if candidate.get("provenance") != "successful_full_facade_recipe_contract" or not candidate.get("afterSnapshot") is Dictionary or not candidate.afterSnapshot.get("parts") is Array or candidate.afterSnapshot.parts.size() != 4298 or not candidate.get("furnitureSnapshot") is Dictionary or not candidate.furnitureSnapshot.get("parts") is Array or candidate.furnitureSnapshot.parts.size() != 152 or not candidate.get("partIds") is Array or candidate.partIds.size() != 16:
		_finish({}, "candidate_schema")
		return
	var records: Dictionary = {}
	for group in ["afterSnapshot", "furnitureSnapshot"]:
		for record in candidate[group].parts:
			if not _budget() or not record is Dictionary or not record.get("id") is String or record.id.is_empty() or record.id.begins_with("furnishing:"):
				_finish({}, "record_schema")
				return
			var id: String = ("furnishing:" if group == "furnitureSnapshot" else "") + record.id
			if records.has(id):
				_finish({}, "duplicate_record")
				return
			records[id] = {"sourceArray": group + ".parts", "rawRecordDigest": _digest(record), "record": record}
	var members: Array = candidate.partIds.duplicate()
	members.sort()
	var selected: Dictionary = {}
	for id in members:
		if not id is String or not records.has(id) or selected.has(id):
			_finish({}, "member_schema")
			return
		selected[id] = true
	var all_ids: Array = records.keys()
	all_ids.sort()
	var seen: Dictionary = {}
	var exported: Array = []
	var pairs: int = 0
	var rows_count: int = 0
	var member_count: int = 0
	for descriptor in result.contactArtifacts:
		if not _budget() or not _descriptor(descriptor) or not descriptor.get("job") is String or seen.has(descriptor.job): break
		var shard: Dictionary = _binary_file(descriptor)
		if not _envelope(shard) or shard.binding != aggregate.binding or shard.get("job") != descriptor.job or shard.result.get("complete") != true or not shard.result.get("members") is Array or shard.result.members.size() != 4 or not shard.result.get("rows") is Array: break
		var tokens: PackedStringArray = descriptor.job.split(":")
		if tokens.size() != 3 or tokens[0] not in ["standard", "static"] or tokens[1] != "contacts" or tokens[2] not in ["0", "1", "2", "3"]: break
		var flattened: Array = []
		var valid: bool = shard.result.get("contactAcceptance") == false and shard.result.get("pairCount") == 35592 and shard.result.get("expectedPairCount") == 35592 and descriptor.get("pairCount") == 35592 and descriptor.get("rawRows") == shard.result.rows.size()
		for index in range(4):
			var member: String = members[int(tokens[2]) * 4 + index]
			var peers: Array = all_ids.filter(func(id): return id != member)
			var expected: Dictionary = {"kind": "contacts", "mode": tokens[0], "memberId": member, "otherIds": peers, "channels": ["visual", "collision"], "pairCount": 8898}
			if not shard.result.members[index] is Dictionary or not _coverage(shard.result.members[index], expected):
				valid = false
				break
			flattened.append_array(shard.result.members[index].rows)
		if not valid or var_to_bytes(flattened) != var_to_bytes(shard.result.rows): break
		for row in shard.result.rows: selected[row.otherId] = true
		exported.append({"job": shard.job, "source": descriptor, "counts": shard.get("counts"), "extractionWork": shard.get("extractionWork"), "pairCount": 35592, "rows": shard.result.rows})
		seen[shard.job] = true
		pairs += 35592
		member_count += 4
		rows_count += shard.result.rows.size()
	if seen.size() != 8 or pairs != 284736 or member_count != 32 or not _budget():
		_finish({}, "incomplete_or_invalid_eight_contact_shards")
		return
	var source_records: Dictionary = {}
	for id in selected: source_records[id] = records[id]
	var metadata: Dictionary = {"schemaVersion": 1, "conversionPrepared": true, "publicationAcceptance": false, "contactAcceptance": false, "sourceExact": false, "allDifferencesAccountedFor": false,
		"completionStatus": "provisional_until_CONTACT_EXPORT_conversionComplete_true_and_clean_watchdog_exit_0",
		"evidenceLevel": "raw_artifact_format_conversion_only", "manifest": input, "aggregateSource": manifest.aggregate, "candidateSource": manifest.candidate, "binding": aggregate.binding,
		"shardCount": 8, "memberModeCount": member_count, "pairCount": pairs, "rawContactRowCount": rows_count, "memberIds": members, "contactSourceRecords": source_records,
		"classificationUnchanged": true, "shards": exported, "boundInputs": _inputs.duplicate(), "limits": {"outputBytes": MAX_BYTES, "softMsec": MAX_MSEC, "conversionVisits": MAX_VISITS}}
	var encoded: String = JSON.stringify(_json_value(metadata, 0), "\t", true, true)
	_finish(metadata, "", encoded)

func _envelope(value: Dictionary) -> bool:
	return value.get("schemaVersion") == 1 and value.get("provenance") == "facade_paving_CPU_comparison_shard" and value.get("publicationAcceptance") == false and value.get("binding") is Dictionary and value.binding.get("candidateSha256") == CANDIDATE_SHA and value.binding.get("comparisonSha256") == COMBINED_COMPARATOR_SHA and value.get("result") is Dictionary

func _aggregate_terminal(descriptor: Dictionary, aggregate: Dictionary) -> bool:
	var report: Dictionary = _json_file(descriptor.report, 1024 * 1024)
	var watch: Dictionary = _json_file(descriptor.watchdog, 65536)
	if report.get("requestedStageCompleted") != true or report.get("diagnosticCompleted") != true or report.get("status") != "comparison_aggregate_complete_review_pending" or report.get("inputsUnchanged") != true or report.get("job") != "aggregate" or report.get("artifactSha256") != descriptor.sha256 or report.get("bindingDigest") != _digest(aggregate.binding) or not report.get("artifactPath") is String or not _same_path(report.artifactPath, descriptor.path): return false
	if watch.get("schema") != "godot-scene-watchdog/v5" or watch.get("sceneArguments") != [COMBINED_COMPARATOR] or watch.get("headless") != true or watch.get("functionalExitCode") != 1 or watch.get("overallExitCode") != 1 or watch.get("finalJobMemberPids") != []: return false
	for key in ["rootExited", "cleanupPassed", "authoritativeZeroProven", "finalMembershipKnown"]:
		if watch.get(key) != true: return false
	for key in ["timedOut", "stopRequested", "forcedCleanup", "cleanupUnresolved", "terminalCleanupExpired"]:
		if watch.get(key) != false: return false
	if watch.get("monitoringException") != null or watch.get("fatalException") != null: return false
	var directory: String = descriptor.path.get_base_dir()
	if not _same_path(directory, descriptor.report.path.get_base_dir()) or not _same_path(directory, descriptor.watchdog.path.get_base_dir()): return false
	for key in ["stdoutPath", "stderrPath"]:
		if not watch.get(key) is String or not _same_path(directory, watch[key].get_base_dir()): return false
		var log: FileAccess = FileAccess.open(watch[key], FileAccess.READ)
		if log == null: return false
		if log.get_length() > 1024 * 1024 or (key == "stderrPath" and log.get_length() != 0):
			log.close()
			return false
		var content: String = log.get_as_text()
		log.close()
		if content.contains("SCRIPT ERROR:") or content.contains("ERROR:"): return false
		_inputs[watch[key]] = FileAccess.get_sha256(watch[key])
	var file: FileAccess = FileAccess.open(descriptor.path, FileAccess.READ)
	if file == null: return false
	var size: int = file.get_length()
	file.close()
	return size == int(report.get("artifactBytes", -1))

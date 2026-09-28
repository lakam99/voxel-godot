extends SceneTree

## Artifact conversion only; no fixture, publisher, geometry or collision calls.
## Uses comparison manifest v1 with exactly the 14 completed contact descriptors
## in shards; each descriptor includes binary + final JSON + watchdog path/SHA.
## Env VOXEL_FACADE_PAVING_CONTACT_MANIFEST, _MANIFEST_SHA256, _REPORT (fresh JSON).
## Exit 0 = complete conversion, NOT acceptance; exit 2 = explicit failure.
const COMPARATOR := "res://scripts/testing/buildings/CitadelFacadePavingComparisonContract.gd"
const COMPARATOR_SHA := "403ed481a29567508823322e7a73321b2f2879e3c1bfc88d6bdfa61a3c85c725"
const MAX_BYTES := 32 * 1024 * 1024
const MAX_MSEC := 80000
const MAX_VISITS := 4000000
const STAGES := ["before_standard", "after_standard", "before_static", "after_static"]
var _started: int = 0
var _visits: int = 0
var _failure: String = ""
var _inputs: Dictionary = {}
var _output: String = ""

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_started = Time.get_ticks_msec()
	_output = OS.get_environment("VOXEL_FACADE_PAVING_CONTACT_REPORT")
	if not _output.is_absolute_path() or _output.get_extension() != "json" or FileAccess.file_exists(_output) or not DirAccess.dir_exists_absolute(_output.get_base_dir()):
		quit(2)
		return
	var manifest: Dictionary = _json_file({"path": OS.get_environment("VOXEL_FACADE_PAVING_CONTACT_MANIFEST"), "sha256": OS.get_environment("VOXEL_FACADE_PAVING_CONTACT_MANIFEST_SHA256")}, 65536)
	if manifest.get("schemaVersion") != 1 or not manifest.get("candidate") is Dictionary or not manifest.get("captures") is Dictionary or manifest.captures.size() != 4 or not manifest.get("shards") is Array or manifest.shards.size() != 14 or FileAccess.get_sha256(COMPARATOR) != COMPARATOR_SHA:
		_finish({}, "manifest_or_frozen_comparator")
		return
	var candidate: Dictionary = _binary_file(manifest.candidate)
	if candidate.get("provenance") != "successful_complete_facade_paving_assembly_contract" or candidate.get("sourceContractPassed") != true or not candidate.get("partIds") is Array or candidate.partIds.size() != 7 or not candidate.get("afterSnapshot") is Dictionary or not candidate.afterSnapshot.get("parts") is Array or candidate.afterSnapshot.parts.size() > 10000 or not candidate.get("furnitureSnapshot") is Dictionary or not candidate.furnitureSnapshot.get("parts") is Array or candidate.furnitureSnapshot.parts.size() != 152:
		_finish({}, "candidate_schema")
		return
	var members: Array = candidate.partIds.duplicate()
	members.sort()
	var all_ids: Array = []
	var source_records: Dictionary = {}
	for record in candidate.afterSnapshot.parts:
		if not record is Dictionary or not record.get("id") is String or record.id.is_empty() or record.id.begins_with("furnishing:") or all_ids.has(record.id):
			_finish({}, "source_id_schema")
			return
		all_ids.append(record.id)
		source_records[record.id] = {"sourceArray": "afterSnapshot.parts", "record": record}
	for record in candidate.furnitureSnapshot.parts:
		if not record is Dictionary or not record.get("id") is String or all_ids.has("furnishing:" + record.id):
			_finish({}, "furniture_id_schema")
			return
		all_ids.append("furnishing:" + record.id)
		source_records["furnishing:" + record.id] = {"sourceArray": "furnitureSnapshot.parts", "record": record}
	all_ids.sort()
	var expected: Dictionary = {}
	for mode in ["standard", "static"]:
		for index in range(7):
			if not members[index] is String or not all_ids.has(members[index]) or (index > 0 and members[index] == members[index - 1]):
				_finish({}, "member_id_schema")
				return
			var peers: Array = all_ids.filter(func(id): return id != members[index])
			expected[mode + ":contacts:" + str(index)] = {"kind": "contacts", "mode": mode, "memberId": members[index], "otherIds": peers, "channels": ["visual", "collision"], "pairCount": peers.size() * 2}
	var captures: Array = []
	for stage in STAGES:
		var entry: Variant = manifest.captures.get(stage)
		if not _triple_descriptor(entry):
			_finish({}, "capture_binding_descriptor")
			return
		captures.append([stage, entry.sha256, entry.report.sha256, entry.watchdog.sha256])
	var binding: Dictionary = {"schemaVersion": 1, "candidateSha256": manifest.candidate.sha256, "captures": captures, "comparisonSha256": COMPARATOR_SHA, "originalSlice": 512}
	var seen: Dictionary = {}
	var chunks: Array[String] = []
	var encoded_bytes: int = 0
	var pairs: int = 0
	var raw_rows: int = 0
	var selected_records: Dictionary = {}
	for id in members: selected_records[id] = true
	for descriptor in manifest.shards:
		if not _budget() or not _triple_descriptor(descriptor): break
		var shard: Dictionary = _binary_file({"path": descriptor.path, "sha256": descriptor.sha256})
		if shard.get("schemaVersion") != 1 or shard.get("provenance") != "facade_paving_CPU_comparison_shard" or shard.get("publicationAcceptance") != false or shard.get("binding") != binding or not shard.get("job") is String or not expected.has(shard.job) or seen.has(shard.job) or not shard.get("result") is Dictionary:
			_failure = "shard_schema_binding_or_duplicate"
			break
		if not _terminal_proof(descriptor, shard, _digest(binding)) or not _coverage(shard.result, expected[shard.job]):
			_failure = "shard_terminal_proof_or_coverage"
			break
		for row in shard.result.rows: selected_records[row.otherId] = true
		# Preserve the complete recorded result, including every raw measurement
		# and refinement. No filtering, reclassification or contact recomputation.
		var item: Dictionary = {"job": shard.job, "source": descriptor, "counts": shard.get("counts"), "extractionWork": shard.get("extractionWork"), "result": shard.result}
		var text: String = JSON.stringify(_json_value(item, 0), "\t", true, true)
		encoded_bytes += text.to_utf8_buffer().size() + 2
		if not _budget() or encoded_bytes > MAX_BYTES:
			_failure = "json_size_or_conversion_budget"
			break
		chunks.append(text)
		seen[shard.job] = true
		pairs += int(shard.result.pairCount)
		raw_rows += shard.result.rows.size()
	if seen.size() != 14 or not _budget():
		_finish({}, _failure if not _failure.is_empty() else "incomplete_fourteen_contact_shards")
		return
	var record_ids: Array = selected_records.keys()
	record_ids.sort()
	var contact_source_records: Array = []
	for id in record_ids:
		if not source_records.has(id) or not _budget():
			_finish({}, "contact_source_record_missing_or_budget")
			return
		var source: Dictionary = source_records[id]
		contact_source_records.append({"contactPartId": id, "sourceArray": source.sourceArray,
			"rawRecordDigest": _digest(source.record), "record": source.record})
	var metadata: Dictionary = {"schemaVersion": 1, "conversionPrepared": true, "publicationAcceptance": false, "contactAcceptance": false,
		"completionStatus": "provisional_until_CONTACT_EXPORT_conversionComplete_true_and_clean_watchdog_exit_0",
		"evidenceLevel": "artifact_format_conversion_only_not_full_gate_or_live_acceptance", "binding": binding,
		"inputManifest": {"path": OS.get_environment("VOXEL_FACADE_PAVING_CONTACT_MANIFEST"), "sha256": OS.get_environment("VOXEL_FACADE_PAVING_CONTACT_MANIFEST_SHA256")},
		"sourceDigests": {"before": candidate.get("sourceDigest"), "after": candidate.get("afterDigest"), "fixture": candidate.get("fixtureDigest"), "policy": candidate.get("policyDigest")},
		"shardCount": 14, "pairCount": pairs, "rawContactRowCount": raw_rows, "memberIds": members,
		"contactSourceRecords": contact_source_records,
		"sourceRecordScope": "Seven new members and actual contact peers only; complete SHA-bound candidate records, including declared seat/socket facts. No contact approval inferred.",
		"classificationUnchanged": true, "numericEncoding": "Godot JSON full_precision; transforms use origin+basis columns, vectors/colors use component arrays",
		"limits": {"outputBytes": MAX_BYTES, "softMsec": MAX_MSEC, "conversionVisits": MAX_VISITS}}
	var header: String = JSON.stringify(_json_value(metadata, 0), "\t", true, true)
	var output: String = header.left(header.length() - 1) + ",\n\"shards\": [\n" + ",\n".join(chunks) + "\n]}"
	_finish(metadata, "", output)

func _descriptor(value: Variant) -> bool:
	return value is Dictionary and value.get("path") is String and value.path.is_absolute_path() and value.get("sha256") is String and value.sha256.length() == 64 and value.sha256.is_valid_hex_number(false)

func _triple_descriptor(value: Variant) -> bool:
	return _descriptor(value) and _descriptor(value.get("report")) and _descriptor(value.get("watchdog"))

func _read(descriptor: Dictionary, cap: int) -> PackedByteArray:
	if not _descriptor(descriptor) or not _budget(): return PackedByteArray()
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
	_inputs[descriptor.path] = descriptor.sha256
	return bytes

func _binary_file(descriptor: Dictionary) -> Dictionary:
	var bytes: PackedByteArray = _read(descriptor, MAX_BYTES)
	var value: Variant = bytes_to_var(bytes) if not bytes.is_empty() else null
	return value if value is Dictionary else {}

func _json_file(descriptor: Dictionary, cap: int) -> Dictionary:
	var bytes: PackedByteArray = _read(descriptor, cap)
	var value: Variant = JSON.parse_string(bytes.get_string_from_utf8()) if not bytes.is_empty() else null
	return value if value is Dictionary else {}

func _same_path(a: String, b: String) -> bool:
	return a.replace("\\", "/").simplify_path() == b.replace("\\", "/").simplify_path()

func _terminal_proof(descriptor: Dictionary, shard: Dictionary, binding_digest: String) -> bool:
	var report: Dictionary = _json_file(descriptor.report, 1024 * 1024)
	var watch: Dictionary = _json_file(descriptor.watchdog, 65536)
	if report.get("requestedStageCompleted") != true or report.get("status") != "comparison_shard_complete" or report.get("inputsUnchanged") != true or report.get("job") != shard.job or report.get("artifactSha256") != descriptor.sha256 or report.get("bindingDigest") != binding_digest or not report.get("artifactPath") is String or not _same_path(report.artifactPath, descriptor.path): return false
	if watch.get("schema") != "godot-scene-watchdog/v5" or watch.get("sceneArguments") != [COMPARATOR] or watch.get("headless") != true or watch.get("functionalExitCode") != 1 or watch.get("overallExitCode") != 1 or watch.get("finalJobMemberPids") != []: return false
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
		var text: String = log.get_as_text()
		log.close()
		if text.contains("SCRIPT ERROR:") or text.contains("ERROR:"): return false
		_inputs[watch[key]] = FileAccess.get_sha256(watch[key])
	var file: FileAccess = FileAccess.open(descriptor.path, FileAccess.READ)
	if file == null: return false
	var size: int = file.get_length()
	file.close()
	return size == int(report.get("artifactBytes", -1))

func _coverage(data: Dictionary, expected: Dictionary) -> bool:
	if data.get("complete") != true or data.get("coverage") != expected or data.get("pairCount") != expected.pairCount or data.get("expectedPairCount") != expected.pairCount or data.get("contactAcceptance") != false or not data.get("rows") is Array or data.rows.size() > 12000 or not data.get("statusCounts") is Dictionary: return false
	var total: int = 0
	for key in data.statusCounts:
		if key not in ["certified_separated", "no_collision", "review_required"] or not data.statusCounts[key] is int or data.statusCounts[key] < 0: return false
		total += data.statusCounts[key]
	var seen: Dictionary = {}
	for row in data.rows:
		if not _budget() or not row is Dictionary or row.get("partId") != expected.memberId or row.get("otherId") not in expected.otherIds or row.get("channel") not in expected.channels or row.get("reviewRequired") != true or not row.get("rawMeasurement") is Dictionary: return false
		var key: String = row.otherId + ":" + row.channel
		if seen.has(key): return false
		seen[key] = true
	return total == expected.pairCount and data.rows.size() == int(data.statusCounts.get("review_required", 0))

func _json_value(value: Variant, depth: int) -> Variant:
	if not _failure.is_empty() or not _budget(): return null
	if depth > 64 or _visits >= MAX_VISITS:
		_failure = "conversion_work_bound"
		return null
	_visits += 1
	if value is Transform3D: return _json_value({"origin": value.origin, "basis": value.basis}, depth + 1)
	if value is Basis: return _json_value([value.x, value.y, value.z], depth + 1)
	if value is Vector3: return _json_value([value.x, value.y, value.z], depth + 1)
	if value is Color: return _json_value([value.r, value.g, value.b, value.a], depth + 1)
	if value is AABB or value is Rect2: return _json_value({"position": value.position, "size": value.size}, depth + 1)
	if value is Vector2: return _json_value([value.x, value.y], depth + 1)
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			if not _budget(): return null
			if not key is String:
				_failure = "nonstring_json_key"
				return null
			var converted: Variant = _json_value(value[key], depth + 1)
			if not _failure.is_empty(): return null
			result[key] = converted
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			if not _budget(): return null
			var converted: Variant = _json_value(item, depth + 1)
			if not _failure.is_empty(): return null
			result.append(converted)
		return result
	if value is float and not is_finite(value):
		_failure = "nonfinite_json_number"
		return null
	if typeof(value) not in [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING]:
		_failure = "unsupported_value_type:" + type_string(typeof(value))
		return null
	return value

func _digest(value: Variant) -> String:
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(value))
	return hash.finish().hex_encode()

func _budget() -> bool:
	if not _failure.is_empty(): return false
	if Time.get_ticks_msec() - _started > MAX_MSEC: _failure = "soft_time_limit"
	return _failure.is_empty()

func _finish(metadata: Dictionary, failure: String, encoded: String = "") -> void:
	var complete: bool = failure.is_empty() and _budget() and FileAccess.get_sha256(COMPARATOR) == COMPARATOR_SHA
	for path in _inputs: complete = complete and FileAccess.get_sha256(path) == _inputs[path] and _budget()
	var bytes: PackedByteArray = encoded.to_utf8_buffer()
	complete = complete and not bytes.is_empty() and bytes.size() <= MAX_BYTES
	if not complete:
		bytes = JSON.stringify({"conversionComplete": false, "publicationAcceptance": false, "contactAcceptance": false, "reason": failure if not failure.is_empty() else (_failure if not _failure.is_empty() else "output_size_or_input_identity"), "elapsedMsec": Time.get_ticks_msec() - _started}).to_utf8_buffer()
	if FileAccess.file_exists(_output):
		quit(2)
		return
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	var expected_sha: String = hash.finish().hex_encode()
	var file: FileAccess = FileAccess.open(_output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_buffer(bytes)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_position() == bytes.size()
	file.close()
	var actual_sha: String = FileAccess.get_sha256(_output)
	var final_budget_ok: bool = _budget()
	var final_complete: bool = complete and written and actual_sha == expected_sha and final_budget_ok
	print("CONTACT_EXPORT ", JSON.stringify({"conversionComplete": final_complete, "outputBytes": bytes.size(), "outputSha256": actual_sha, "shardCount": metadata.get("shardCount", 0), "rawRows": metadata.get("rawContactRowCount", 0), "elapsedMsec": Time.get_ticks_msec() - _started}))
	quit(0 if final_complete else 2)

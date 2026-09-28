extends SceneTree

## Focused adversarial contract for the two-phase evidence bridge. It never
## builds or reconstructs a production Citadel blueprint.
const Codec := preload("res://scripts/testing/buildings/CitadelStructuralComposerCheckpointCodec.gd")
var checks: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var report_path := OS.get_environment("VOXEL_STRUCTURAL_CODEC_REPORT").simplify_path()
	var artifact_dir := OS.get_environment("VOXEL_STRUCTURAL_CODEC_ARTIFACT_DIR").simplify_path()
	if not report_path.is_absolute_path() or not artifact_dir.is_absolute_path() or FileAccess.file_exists(report_path) \
			or not DirAccess.dir_exists_absolute(artifact_dir):
		quit(2)
		return
	var fingerprint := Codec.source_fingerprint()
	var engine := Codec.engine_identity()
	if not fingerprint.ready or not engine.ready:
		_write_early_failure(report_path, fingerprint, engine)
		return
	_check("complete_source_and_engine_identity", _fingerprint_manifest_complete(fingerprint) \
		and String(engine.runtime.path).replace("\\", "/") == OS.get_executable_path().simplify_path().replace("\\", "/") \
		and String(engine.launcher.path).replace("\\", "/") == OS.get_environment("VOXEL_GODOT_EXE").simplify_path().replace("\\", "/") \
		and not String(engine.runtime.sha256).is_empty() and not String(engine.launcher.sha256).is_empty())
	var nonhex_fingerprint := fingerprint.duplicate(true)
	if nonhex_fingerprint.ready and not (nonhex_fingerprint.entries as Array).is_empty():
		nonhex_fingerprint.entries[0][2] = "z".repeat(64)
	_check("fingerprint_row_nonhex_sha_rejected", not _fingerprint_manifest_complete(nonhex_fingerprint))
	var checkpoint := _fixture_checkpoint(fingerprint, engine)
	var missing_runner_sources_rejected := true
	var changed_runner_sources_rejected := true
	for runner_path in Codec.RUNNER_SOURCE_PATHS:
		var relative := String(runner_path).trim_prefix("res://")
		var omitted := fingerprint.duplicate(true)
		var changed := fingerprint.duplicate(true)
		for index in range((omitted.entries as Array).size()):
			if omitted.entries[index][0] == relative:
				omitted.entries.remove_at(index)
				break
		_rehash_fingerprint(omitted)
		missing_runner_sources_rejected = missing_runner_sources_rejected \
			and not Codec.runner_sources_complete(omitted) and not _fingerprint_manifest_complete(omitted) \
			and not Codec.fingerprints_equal(omitted, omitted) and _rebound_fingerprint_rejected(checkpoint, omitted)
		for row in changed.entries:
			if row[0] == relative:
				row[2] = "0".repeat(64) if row[2] != "0".repeat(64) else "1".repeat(64)
		_rehash_fingerprint(changed)
		changed_runner_sources_rejected = changed_runner_sources_rejected and not Codec.fingerprints_equal(changed, fingerprint)
	_check("every_runner_helper_required_even_after_payload_and_core_rebinding", missing_runner_sources_rejected)
	_check("every_runner_helper_hash_change_invalidates_current_source_identity", changed_runner_sources_rejected)
	var encoded := Codec.encode_payload(checkpoint)
	var decoded := Codec.decode_payload(encoded.get("bytes", PackedByteArray()), String(encoded.get("sha256", "")), 208159) if encoded.ready else {"ready": false}
	var reencoded := Codec.encode_payload(decoded.payload) if decoded.ready else {"ready": false}
	_check("canonical_positive_roundtrip", encoded.ready and decoded.ready and reencoded.ready and reencoded.bytes == encoded.bytes)
	_check("wrong_outer_sha_rejected_before_reconstruction", not Codec.decode_payload(encoded.bytes, "0".repeat(64), 208159).ready)
	_check("wrong_seed_rejected_before_reconstruction", not Codec.decode_payload(encoded.bytes, encoded.sha256, 208160).ready)
	_check("schema_revision_and_run_id_rejected", _mutation_rejected(checkpoint, func(value): value.schema = "wrong") \
		and _mutation_rejected(checkpoint, func(value): value.revision = 2) \
		and _mutation_rejected(checkpoint, func(value): value.runId = "BAD"))
	_check("payload_and_core_hash_tampering_rejected", _mutation_rejected(checkpoint, func(value): value.payloadSha256 = "0".repeat(64)) \
		and _mutation_rejected(checkpoint, func(value): value.phaseACoreSha256 = "0".repeat(64)))
	_check("internal_snapshot_furniture_reservation_hashes_rejected", _section_hash_rejected(checkpoint, "blueprintSnapshot") \
		and _section_hash_rejected(checkpoint, "furnishingSnapshot") and _section_hash_rejected(checkpoint, "reservations"))
	_check("count_tampering_rejected", _mutation_rejected(checkpoint, func(value): value.payload.counts.parts = 99))
	_check("fingerprint_and_engine_tampering_rejected", _mutation_rejected(checkpoint, func(value): value.payload.sourceFingerprint.sha256 = "0".repeat(64)) \
		and _mutation_rejected(checkpoint, func(value): value.payload.engineIdentity.launcher.sha256 = "0".repeat(64)) \
		and _mutation_rejected(checkpoint, func(value): value.payload.engineIdentity.runtime.sha256 = "0".repeat(64)))
	_check("duplicate_part_and_furniture_ids_rejected", _duplicate_id_rejected(checkpoint, "parts") and _duplicate_id_rejected(checkpoint, "furniture"))
	_check("malformed_and_nonstring_dictionary_keys_rejected", _direct_rejected({1: "nonstring"}) and _direct_rejected({"schema": Codec.SCHEMA}))
	_check("nonfinite_scalar_vector_and_aabb_rejected", _direct_rejected({"value": NAN}) and _direct_rejected({"value": Vector3(INF, 0.0, 0.0)}) \
		and _direct_rejected({"value": AABB(Vector3.ZERO, Vector3(1.0, NAN, 1.0))}))
	var egress_nonfinite := checkpoint.duplicate(true)
	egress_nonfinite.payload.furnishingSnapshot.egressDiagnostics = {"routes": [{"distance": INF}]}
	var egress_rejection := Codec.validate_payload(egress_nonfinite, 208159)
	var outside_nonfinite := checkpoint.duplicate(true)
	outside_nonfinite.payload.phaseAAssertions["unrelatedDistance"] = INF
	var outside_rejection := Codec.validate_payload(outside_nonfinite, 208159)
	_check("nonfinite_paths_distinguish_egress_diagnostics_from_outside_payload",
		egress_rejection.reason == "payload_nonfinite_scalar" and egress_rejection.detail.path == "$[\"payload\"][\"furnishingSnapshot\"][\"egressDiagnostics\"][\"routes\"][0][\"distance\"]" \
		and outside_rejection.reason == "payload_nonfinite_scalar" and outside_rejection.detail.path == "$[\"payload\"][\"phaseAAssertions\"][\"unrelatedDistance\"]")
	var repeated_first := Codec.validate_payload(egress_nonfinite, 208159)
	var repeated_second := Codec.validate_payload(egress_nonfinite, 208159)
	_check("rejection_reason_path_and_nodes_are_repeat_deterministic",
		Codec.hash_variant({"reason": repeated_first.reason, "detail": repeated_first.detail}) \
		== Codec.hash_variant({"reason": repeated_second.reason, "detail": repeated_second.detail}))
	var malicious_key := "prefix" + String.chr(1) + "é" + "x".repeat(Codec.MAX_DIAGNOSTIC_SEGMENT_BYTES * 2)
	var malicious_payload := {malicious_key: INF}
	var malicious_first := Codec.validate_payload(malicious_payload, 208159)
	var malicious_second := Codec.validate_payload(malicious_payload, 208159)
	_check("diagnostic_key_escaping_and_segment_truncation_are_bounded_deterministic",
		malicious_first.reason == "payload_nonfinite_scalar" and malicious_first.detail == malicious_second.detail \
		and String(malicious_first.detail.path).contains("prefix\\u{1}\\u{e9}") \
		and String(malicious_first.detail.path).ends_with("...\"]") \
		and String(malicious_first.detail.path).to_utf8_buffer().size() <= Codec.MAX_DIAGNOSTIC_SEGMENT_BYTES + 1)
	var deeply_nested: Variant = INF
	for index in range(8):
		deeply_nested = {"segment_%02d_%s" % [index, "z".repeat(Codec.MAX_DIAGNOSTIC_SEGMENT_BYTES * 2)]: deeply_nested}
	var capped_first := Codec.validate_payload(deeply_nested, 208159)
	var capped_second := Codec.validate_payload(deeply_nested, 208159)
	_check("full_diagnostic_path_cap_is_bounded_deterministic",
		capped_first.reason == "payload_nonfinite_scalar" and capped_first.detail == capped_second.detail \
		and String(capped_first.detail.path).to_utf8_buffer().size() <= Codec.MAX_DIAGNOSTIC_PATH_BYTES \
		and String(capped_first.detail.path).ends_with("..."))
	var packed_vector2_rejection := Codec.validate_payload({"value": PackedVector2Array([Vector2(0.0, INF)])}, 208159)
	var packed_vector3_rejection := Codec.validate_payload({"value": PackedVector3Array([Vector3(NAN, 0.0, 0.0)])}, 208159)
	var packed_color_rejection := Codec.validate_payload({"value": PackedColorArray([Color(0.0, 0.0, INF, 1.0)])}, 208159)
	_check("nonfinite_packed_vector_and_color_components_rejected_at_index",
		packed_vector2_rejection.reason == "payload_nonfinite_packed_vector2" and packed_vector2_rejection.detail.path == "$[\"value\"][0]" \
		and packed_vector3_rejection.reason == "payload_nonfinite_packed_vector3" and packed_vector3_rejection.detail.path == "$[\"value\"][0]" \
		and packed_color_rejection.reason == "payload_nonfinite_packed_color" and packed_color_rejection.detail.path == "$[\"value\"][0]")
	var deep: Variant = "leaf"
	for _index in range(Codec.MAX_DEPTH + 2): deep = [deep]
	_check("excessive_depth_rejected", _direct_rejected({"value": deep}))
	var too_many_nodes: Array = []
	too_many_nodes.resize(Codec.MAX_NODES + 1)
	too_many_nodes.fill(0)
	_check("excessive_node_budget_rejected", _direct_rejected({"value": too_many_nodes}))
	var oversized_string := "x".repeat(Codec.MAX_STRING_BYTES + 1)
	var oversized_packed := PackedByteArray()
	oversized_packed.resize(Codec.MAX_STRING_BYTES + 1)
	_check("oversized_string_and_packed_array_rejected", _direct_rejected({"value": oversized_string}) and _direct_rejected({"value": oversized_packed}))
	var oversized_parts := checkpoint.duplicate(true)
	oversized_parts.payload.blueprintSnapshot.parts = []
	for index in range(Codec.MAX_PARTS + 1): oversized_parts.payload.blueprintSnapshot.parts.append({"id": "p_%d" % index})
	_rebind(oversized_parts)
	_check("oversized_collection_rejected", not Codec.validate_payload(oversized_parts, 208159).ready)
	_check("object_callable_signal_and_rid_rejected", _direct_rejected({"value": RefCounted.new()}) \
		and _direct_rejected({"value": _noop}) and _direct_rejected({"value": process_frame}) and _direct_rejected({"value": RID()}))
	var truncated: PackedByteArray = encoded.bytes.slice(0, maxi(0, encoded.bytes.size() - 3))
	var trailing: PackedByteArray = encoded.bytes.duplicate(); trailing.append(0)
	_check("truncated_trailing_and_malformed_bytes_rejected", not Codec.decode_payload(truncated, Codec.sha256_bytes(truncated), 208159).ready \
		and not Codec.decode_payload(trailing, Codec.sha256_bytes(trailing), 208159).ready \
		and not Codec.decode_payload(PackedByteArray([1, 2, 3]), Codec.sha256_bytes(PackedByteArray([1, 2, 3])), 208159).ready)
	var wrong_magic: PackedByteArray = encoded.bytes.duplicate(); wrong_magic[0] = 0
	var wrong_revision: PackedByteArray = encoded.bytes.duplicate(); wrong_revision.encode_u32(8, Codec.REVISION + 1)
	var malformed_internal_sha: PackedByteArray = encoded.bytes.duplicate(); malformed_internal_sha[20] = 122
	var corrupted_payload: PackedByteArray = encoded.bytes.duplicate(); corrupted_payload[corrupted_payload.size() - 1] = corrupted_payload[corrupted_payload.size() - 1] ^ 1
	_check("frame_magic_revision_sha_and_payload_corruption_rejected_silently", not Codec.decode_payload(wrong_magic, Codec.sha256_bytes(wrong_magic), 208159).ready \
		and not Codec.decode_payload(wrong_revision, Codec.sha256_bytes(wrong_revision), 208159).ready \
		and not Codec.decode_payload(malformed_internal_sha, Codec.sha256_bytes(malformed_internal_sha), 208159).ready \
		and not Codec.decode_payload(corrupted_payload, Codec.sha256_bytes(corrupted_payload), 208159).ready)
	var report := _phase_a_report(checkpoint, encoded, fingerprint, engine)
	var report_bytes := JSON.stringify(report).to_utf8_buffer()
	var report_sha := Codec.sha256_bytes(report_bytes)
	_check("phase_a_report_and_checkpoint_pair_binds", Codec.phase_a_report_matches_checkpoint(report, report_sha, encoded.sha256, encoded.size, 208159, fingerprint, engine).ready)
	var parsed_report: Variant = JSON.parse_string(report_bytes.get_string_from_utf8())
	_check("json_roundtrip_phase_a_identity_pair_binds", parsed_report is Dictionary \
		and Codec.phase_a_report_matches_checkpoint(parsed_report, report_sha, encoded.sha256, encoded.size, 208159, fingerprint, engine).ready)
	_check("json_roundtrip_phase_a_core_binds", parsed_report is Dictionary \
		and Codec.phase_a_cores_equal(parsed_report.phaseACore, checkpoint.phaseACore))
	_check("json_roundtrip_phase_a_core_mutations_rejected",
		_core_mutation_rejected(checkpoint.phaseACore, func(value): value.counts.parts = float(value.counts.parts) + 0.5) \
		and _core_mutation_rejected(checkpoint.phaseACore, func(value): value.revision = float(value.revision) + 0.5) \
		and _core_mutation_rejected(checkpoint.phaseACore, func(value): value.sectionHashes.parts = "0".repeat(64)) \
		and _core_mutation_rejected(checkpoint.phaseACore, func(value): value.sectionHashes.erase("parts")) \
		and _core_mutation_rejected(checkpoint.phaseACore, func(value): value.sectionHashes["unexpected"] = "0".repeat(64)) \
		and _core_mutation_rejected(checkpoint.phaseACore, func(value): value.runId = "f".repeat(32)) \
		and _core_mutation_rejected(checkpoint.phaseACore, func(value): value.payloadSha256 = "0".repeat(64)) \
		and _core_mutation_rejected(checkpoint.phaseACore, func(value): value["unexpected"] = true) \
		and _core_mutation_rejected(checkpoint.phaseACore, func(value): value.counts["unexpected"] = 0))
	_check("json_roundtrip_identity_field_mutations_rejected",
		_report_identity_mutation_rejected(report, encoded, fingerprint, engine, func(value): value.sourceFingerprint.entries[0][0] += ".wrong") \
		and _report_identity_mutation_rejected(report, encoded, fingerprint, engine, func(value): value.sourceFingerprint.entries[0][1] = float(value.sourceFingerprint.entries[0][1]) + 0.5) \
		and _report_identity_mutation_rejected(report, encoded, fingerprint, engine, func(value): value.sourceFingerprint.entries[0][2] = "0".repeat(64)) \
		and _report_identity_mutation_rejected(report, encoded, fingerprint, engine, func(value): value.engineIdentity.version.major = float(value.engineIdentity.version.major) + 0.5) \
		and _report_identity_mutation_rejected(report, encoded, fingerprint, engine, func(value): value.sourceFingerprint["unexpected"] = true) \
		and _report_identity_mutation_rejected(report, encoded, fingerprint, engine, func(value): value.engineIdentity.version["unexpected"] = true))
	var stale := report.duplicate(true); stale.seed = 208160
	var wrong_checkpoint := report.duplicate(true); wrong_checkpoint.checkpointSha256 = "0".repeat(64)
	_check("stale_report_and_swapped_checkpoint_rejected", not Codec.phase_a_report_matches_checkpoint(stale, Codec.sha256_bytes(JSON.stringify(stale).to_utf8_buffer()), encoded.sha256, encoded.size, 208159, fingerprint, engine).ready \
		and not Codec.phase_a_report_matches_checkpoint(wrong_checkpoint, Codec.sha256_bytes(JSON.stringify(wrong_checkpoint).to_utf8_buffer()), encoded.sha256, encoded.size, 208159, fingerprint, engine).ready)
	var wrong_launcher := engine.duplicate(true)
	wrong_launcher.launcher.path = String(engine.launcher.path) + ".wrong"
	wrong_launcher.sha256 = Codec.hash_variant({"version": wrong_launcher.version, "launcher": wrong_launcher.launcher, "runtime": wrong_launcher.runtime})
	var wrong_runtime := engine.duplicate(true)
	wrong_runtime.runtime.path = String(engine.runtime.path) + ".wrong"
	wrong_runtime.sha256 = Codec.hash_variant({"version": wrong_runtime.version, "launcher": wrong_runtime.launcher, "runtime": wrong_runtime.runtime})
	_check("wrong_launcher_and_runtime_paths_rejected", not Codec.phase_a_report_matches_checkpoint(report, report_sha, encoded.sha256, encoded.size, 208159, fingerprint, wrong_launcher).ready \
		and not Codec.phase_a_report_matches_checkpoint(report, report_sha, encoded.sha256, encoded.size, 208159, fingerprint, wrong_runtime).ready)
	var wrong_launcher_sha := engine.duplicate(true)
	wrong_launcher_sha.launcher.sha256 = "0".repeat(64)
	wrong_launcher_sha.sha256 = Codec.hash_variant({"version": wrong_launcher_sha.version, "launcher": wrong_launcher_sha.launcher, "runtime": wrong_launcher_sha.runtime})
	var wrong_runtime_sha := engine.duplicate(true)
	wrong_runtime_sha.runtime.sha256 = "0".repeat(64)
	wrong_runtime_sha.sha256 = Codec.hash_variant({"version": wrong_runtime_sha.version, "launcher": wrong_runtime_sha.launcher, "runtime": wrong_runtime_sha.runtime})
	_check("wrong_launcher_and_runtime_hashes_rejected", not Codec.phase_a_report_matches_checkpoint(report, report_sha, encoded.sha256, encoded.size, 208159, fingerprint, wrong_launcher_sha).ready \
		and not Codec.phase_a_report_matches_checkpoint(report, report_sha, encoded.sha256, encoded.size, 208159, fingerprint, wrong_runtime_sha).ready)
	var final_path := artifact_dir.path_join("atomic-final.bin")
	var temp_path := artifact_dir.path_join("atomic-temp-%s.bin" % String(checkpoint.runId))
	var atomic := Codec.write_atomic_fresh(final_path, temp_path, encoded.bytes)
	_check("atomic_fresh_write_rereads_and_leaves_no_temp", atomic.ready and FileAccess.file_exists(final_path) and not FileAccess.file_exists(temp_path) and FileAccess.get_file_as_bytes(final_path) == encoded.bytes)
	_check("preexisting_final_rejected_without_overwrite", not Codec.write_atomic_fresh(final_path, artifact_dir.path_join("other-temp.bin"), PackedByteArray([9])).ready and FileAccess.get_file_as_bytes(final_path) == encoded.bytes)
	var occupied_temp := artifact_dir.path_join("occupied-temp.bin")
	var occupied := FileAccess.open(occupied_temp, FileAccess.WRITE); occupied.store_8(7); occupied.close()
	_check("preexisting_temp_rejected_without_overwrite", not Codec.write_atomic_fresh(artifact_dir.path_join("other-final.bin"), occupied_temp, PackedByteArray([9])).ready and FileAccess.get_file_as_bytes(occupied_temp) == PackedByteArray([7]))
	var passed := checks.all(func(row): return bool(row.passed))
	var output_report := {"passed": passed, "checks": checks, "checkCount": checks.size(),
		"sourceFingerprint": fingerprint, "engineIdentity": engine,
		"evidenceLevel": "synthetic_checkpoint_codec_adversarial_contract",
		"doesNotProve": "No Citadel composition, physical acceptance, rendering, gameplay, NPC/navigation or headed behavior."}
	var output := FileAccess.open(report_path, FileAccess.WRITE)
	if output == null:
		quit(2)
		return
	output.store_string(JSON.stringify(output_report, "\t"))
	output.flush()
	output.close()
	quit(0 if passed else 1)


func _fixture_checkpoint(fingerprint: Dictionary, engine: Dictionary) -> Dictionary:
	var blueprint := {"id": "codec_fixture", "seed": 208159, "style": "stone", "recipe": {"fixture": true}, "rooms": [],
		"parts": [{"id": "fixture_root", "kind": "foundation", "material": "stone_foundation", "position": Vector3(0.0, 0.5, 0.0), "rotation": Vector3.ZERO, "size": Vector3.ONE, "collision": true, "semantic": "fixture", "physicalIntent": "structural_root", "recipe": {"physicalIntent": "structural_root"}}]}
	var furnishing := {"id": "codec_furnishing", "seed": 1, "sourceBlueprintId": "codec_fixture", "egressDiagnostics": {},
		"parts": [{"id": "fixture_chair", "roomId": "room", "archetype": "chair", "material": "timber_board", "position": Vector3.ZERO, "rotation": Vector3.ZERO, "size": Vector3.ONE, "occupiedSize": Vector3.ONE, "collision": false, "semantic": "fixture", "recipe": {}}]}
	return Codec.make_payload("0123456789abcdef0123456789abcdef", 208159, "1".repeat(64), "2".repeat(64), blueprint, furnishing,
		[AABB(Vector3.ZERO, Vector3.ONE)], {"ready": true}, {"identicalSourceObject": true}, fingerprint, engine)


func _fingerprint_manifest_complete(fingerprint: Dictionary) -> bool:
	if not Codec.runner_sources_complete(fingerprint):
		return false
	if not fingerprint.get("entries") is Array or int(fingerprint.get("fileCount", -1)) != (fingerprint.entries as Array).size():
		return false
	var required := ["project.godot", "tools/run-citadel-structural-composer-two-phase-contract.mjs",
		"scripts/testing/buildings/CitadelStructuralComposerCheckpointCodec.gd",
		"scripts/testing/buildings/CitadelStructuralComposerCheckpointCodecContract.gd",
		"scripts/testing/buildings/CitadelStructuralCompletionComposerPhaseAContract.gd",
		"scripts/testing/buildings/CitadelStructuralCompletionComposerPhaseBContract.gd"]
	var seen: Dictionary = {}
	var previous := ""
	var total := 0
	for entry in fingerprint.entries:
		if not entry is Array or entry.size() != 3 or not entry[0] is String or typeof(entry[1]) != TYPE_INT or not entry[2] is String:
			return false
		var path := String(entry[0])
		var sha := String(entry[2])
		if path.is_empty() or path <= previous or seen.has(path.to_lower()) or int(entry[1]) < 0 or not _is_lower_hex_sha256(sha):
			return false
		previous = path
		seen[path.to_lower()] = true
		total += int(entry[1])
	for path in required:
		if not seen.has(path.to_lower()):
			return false
	return int(fingerprint.get("totalBytes", -1)) == total and not String(fingerprint.get("sha256", "")).is_empty()


func _rehash_fingerprint(fingerprint: Dictionary) -> void:
	var total := 0
	for row in fingerprint.entries:
		total += int(row[1])
	fingerprint.fileCount = fingerprint.entries.size()
	fingerprint.totalBytes = total
	fingerprint.sha256 = Codec.hash_variant(["citadel-source-fingerprint/v1", fingerprint.entries, fingerprint.fileCount, total])


func _rebound_fingerprint_rejected(checkpoint: Dictionary, fingerprint: Dictionary) -> bool:
	var value := checkpoint.duplicate(true)
	value.payload.sourceFingerprint = fingerprint.duplicate(true)
	value.phaseACore.sourceFingerprintSha256 = fingerprint.sha256
	_rebind(value)
	return not Codec.validate_payload(value, 208159).ready


func _is_lower_hex_sha256(value: String) -> bool:
	if value.length() != 64 or value != value.to_lower():
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if not (code >= 48 and code <= 57 or code >= 97 and code <= 102):
			return false
	return true


func _mutation_rejected(source: Dictionary, mutate: Callable) -> bool:
	var value := source.duplicate(true)
	mutate.call(value)
	return not Codec.validate_payload(value, 208159).ready


func _section_hash_rejected(source: Dictionary, key: String) -> bool:
	return _mutation_rejected(source, func(value): value.payload.sectionHashes[key] = "0".repeat(64))


func _duplicate_id_rejected(source: Dictionary, collection: String) -> bool:
	var value := source.duplicate(true)
	if collection == "parts": value.payload.blueprintSnapshot.parts.append(value.payload.blueprintSnapshot.parts[0].duplicate(true))
	else: value.payload.furnishingSnapshot.parts.append(value.payload.furnishingSnapshot.parts[0].duplicate(true))
	_rebind(value)
	return not Codec.validate_payload(value, 208159).ready


func _rebind(value: Dictionary) -> void:
	var body: Dictionary = value.payload
	body.sectionHashes.blueprintSnapshot = Codec.hash_variant(body.blueprintSnapshot)
	body.sectionHashes.parts = Codec.hash_variant(body.blueprintSnapshot.parts)
	body.sectionHashes.furnishingSnapshot = Codec.hash_variant(body.furnishingSnapshot)
	body.sectionHashes.phaseAAssertions = Codec.hash_variant(body.phaseAAssertions)
	body.counts.parts = body.blueprintSnapshot.parts.size()
	body.counts.furniture = body.furnishingSnapshot.parts.size()
	value.payloadSha256 = Codec.hash_variant(body)
	value.phaseACore.payloadSha256 = value.payloadSha256
	value.phaseACore.sectionHashes = body.sectionHashes.duplicate(true)
	value.phaseACore.counts = body.counts.duplicate(true)
	value.phaseACoreSha256 = Codec.hash_variant(value.phaseACore)


func _direct_rejected(value: Variant) -> bool:
	return not Codec.validate_payload(value, 208159).ready


func _phase_a_report(checkpoint: Dictionary, encoded: Dictionary, fingerprint: Dictionary, engine: Dictionary) -> Dictionary:
	return {"schema": Codec.PHASE_A_REPORT_SCHEMA, "revision": Codec.REVISION, "runId": checkpoint.runId, "seed": checkpoint.seed,
		"passed": true, "phaseACore": checkpoint.phaseACore, "phaseACoreSha256": checkpoint.phaseACoreSha256,
		"checkpointSchema": Codec.SCHEMA, "checkpointSha256": encoded.sha256, "checkpointSize": encoded.size,
		"sourceFingerprint": fingerprint, "engineIdentity": engine}


func _report_identity_mutation_rejected(source: Dictionary, encoded: Dictionary, fingerprint: Dictionary,
		engine: Dictionary, mutate: Callable) -> bool:
	var value := source.duplicate(true)
	mutate.call(value)
	var bytes := JSON.stringify(value).to_utf8_buffer()
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	return parsed is Dictionary and not Codec.phase_a_report_matches_checkpoint(parsed, Codec.sha256_bytes(bytes),
		encoded.sha256, encoded.size, 208159, fingerprint, engine).ready


func _core_mutation_rejected(source: Dictionary, mutate: Callable) -> bool:
	var value := source.duplicate(true)
	mutate.call(value)
	var parsed: Variant = JSON.parse_string(JSON.stringify(value))
	return parsed is Dictionary and not Codec.phase_a_cores_equal(parsed, source)


func _check(id: String, passed: bool) -> void:
	checks.append({"id": id, "passed": passed})


func _write_early_failure(report_path: String, fingerprint: Dictionary, engine: Dictionary) -> void:
	var output := FileAccess.open(report_path, FileAccess.WRITE)
	if output == null:
		quit(2)
		return
	output.store_string(JSON.stringify({"passed": false, "reason": "codec_environment_identity_failed",
		"sourceFingerprint": fingerprint, "engineIdentity": engine, "checks": []}, "\t"))
	output.flush()
	output.close()
	quit(1)


func _noop() -> void:
	pass

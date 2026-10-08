extends RefCounted

## Bounded, object-free evidence bridge between the ordinary composer process
## and a separate fresh post-commit validation process. A checkpoint transports
## exact state; it is never acceptance evidence by itself.
const SCHEMA := "citadel_structural_composer_checkpoint/v1"
const PHASE_A_REPORT_SCHEMA := "citadel_structural_composer_phase_a_report/v1"
const REVISION := 1
const MAX_CHECKPOINT_BYTES := 64 * 1024 * 1024
const MAX_SOURCE_FILES := 4096
const MAX_SOURCE_BYTES := 256 * 1024 * 1024
const MAX_PARTS := 10000
const MAX_FURNITURE := 4096
const MAX_ROOMS := 4096
const MAX_RESERVATIONS := 4096
const MAX_DEPTH := 32
const MAX_NODES := 1000000
const MAX_STRING_BYTES := 1024 * 1024
const MAX_DIAGNOSTIC_PATH_BYTES := 1024
const MAX_DIAGNOSTIC_SEGMENT_BYTES := 192
const MAX_EXACT_JSON_INTEGER := 9007199254740991
# The former all-in-one wrapper fingerprint now covers its complete Node/native
# implementation. These bytes are part of the checkpoint payload and core hash.
const RUNNER_SOURCE_PATHS := [
	"res://tools/run-citadel-structural-composer-two-phase-contract.mjs",
	"res://tools/lib/building-runner.mjs",
	"res://tools/lib/headed-test-evidence.mjs",
	"res://tools/lib/building-special.mjs",
	"res://tools/lib/building-special-sources.mjs",
	"res://tools/lib/building-source-bindings.mjs",
	"res://tools/lib/building-help.mjs",
	"res://tools/run-godot-scene-watchdog.mjs",
	"res://tools/lib/owned-process.mjs",
	"res://tools/lib/owned-native-host.mjs",
	"res://tools/lib/owned-live-clock.mjs",
	"res://tools/native/OwnedProcessHost.cs",
	"res://tools/native/OwnedProcessNative.cs",
]
const FRAME_MAGIC := "CSCPCP01"
const FRAME_HEADER_BYTES := 84
const CHECKPOINT_KEYS := ["schema", "revision", "runId", "seed", "phaseACore", "phaseACoreSha256", "payload", "payloadSha256"]
const CORE_KEYS := ["schema", "revision", "runId", "seed", "sourceFingerprintSha256", "engineIdentitySha256", "payloadSha256", "sectionHashes", "counts"]
const CORE_SECTION_HASH_KEYS := ["sourceSnapshot", "sourceRecipe", "blueprintSnapshot", "parts", "rooms", "recipe", "furnishingSnapshot", "reservations", "phaseAAssertions"]
const CORE_COUNT_KEYS := ["parts", "rooms", "furniture", "reservations"]
const PAYLOAD_KEYS := ["blueprintSnapshot", "furnishingSnapshot", "furnishingReservations", "phaseAAssertions", "sourceFingerprint", "engineIdentity", "sectionHashes", "counts"]


static func sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


static func hash_variant(value: Variant) -> String:
	return sha256_bytes(var_to_bytes(value))


static func source_fingerprint() -> Dictionary:
	var first := _source_fingerprint_once()
	if not first.ready:
		return first
	var second := _source_fingerprint_once()
	if not second.ready or not fingerprints_equal(first, second):
		return _fail("source_fingerprint_changed_during_read")
	return first


static func _source_fingerprint_once() -> Dictionary:
	var paths: Array[String] = []
	if not _collect_gdscript_paths("res://scripts", paths):
		return _fail("source_enumeration_failed")
	paths.append("res://project.godot")
	for runner_path in RUNNER_SOURCE_PATHS:
		paths.append(runner_path)
	paths.sort()
	if paths.size() > MAX_SOURCE_FILES:
		return _fail("source_file_limit")
	var entries: Array = []
	var total_bytes := 0
	var previous_path := ""
	var casefold_paths: Dictionary = {}
	for path in paths:
		var relative_path := path.trim_prefix("res://").replace("\\", "/")
		var path_bytes := relative_path.to_utf8_buffer()
		if relative_path.is_empty() or relative_path.is_absolute_path() or relative_path.contains("..") or relative_path.contains("\\") \
				or path_bytes.size() > 512 or relative_path <= previous_path or casefold_paths.has(relative_path.to_lower()):
			return _fail("source_path_invalid", {"path": relative_path})
		for byte in path_bytes:
			if byte < 32 or byte == 127:
				return _fail("source_path_control_character", {"path": relative_path})
		previous_path = relative_path
		casefold_paths[relative_path.to_lower()] = true
		if not FileAccess.file_exists(path):
			return _fail("source_file_missing", {"path": path})
		var bytes := FileAccess.get_file_as_bytes(path)
		var error := FileAccess.get_open_error()
		if error != OK:
			return _fail("source_file_unreadable", {"path": path, "error": error})
		total_bytes += bytes.size()
		if total_bytes > MAX_SOURCE_BYTES:
			return _fail("source_byte_limit")
		if bytes.size() > 16 * 1024 * 1024:
			return _fail("source_single_file_limit", {"path": relative_path})
		entries.append([relative_path, bytes.size(), sha256_bytes(bytes)])
	var aggregate := hash_variant(["citadel-source-fingerprint/v1", entries, entries.size(), total_bytes])
	if aggregate.is_empty():
		return _fail("source_hash_failed")
	return {"ready": true, "entries": entries, "fileCount": entries.size(), "totalBytes": total_bytes, "sha256": aggregate}


static func engine_identity() -> Dictionary:
	var actual_runtime_path := OS.get_executable_path().simplify_path()
	var launcher_path := OS.get_environment("VOXEL_GODOT_EXE").simplify_path()
	var runtime_path := OS.get_environment("VOXEL_GODOT_RUNTIME_EXE").simplify_path()
	if not launcher_path.is_absolute_path() or not runtime_path.is_absolute_path() \
			or runtime_path.replace("\\", "/").to_lower() != actual_runtime_path.replace("\\", "/").to_lower():
		return _fail("godot_executable_path_mismatch")
	var launcher := _executable_file_identity(launcher_path)
	var runtime := _executable_file_identity(runtime_path)
	if not launcher.ready or not runtime.ready:
		return _fail("godot_executable_unreadable", {"launcher": launcher, "runtime": runtime})
	var raw_version := Engine.get_version_info()
	var version := {"major": int(raw_version.get("major", -1)), "minor": int(raw_version.get("minor", -1)),
		"patch": int(raw_version.get("patch", -1)), "status": String(raw_version.get("status", "")),
		"build": String(raw_version.get("build", "")), "hash": String(raw_version.get("hash", ""))}
	if version.major < 0 or version.minor < 0 or version.patch < 0 or version.status.is_empty():
		return _fail("godot_version_missing")
	var identity := {"version": version, "launcher": launcher.duplicate(true), "runtime": runtime.duplicate(true)}
	identity.launcher.erase("ready")
	identity.runtime.erase("ready")
	identity["sha256"] = hash_variant(identity)
	identity["ready"] = true
	return identity


static func runner_sources_complete(fingerprint: Dictionary) -> bool:
	if not fingerprint.get("entries") is Array:
		return false
	var seen: Dictionary = {}
	for row in fingerprint.entries:
		if not row is Array or row.size() != 3 or not row[0] is String or not row[2] is String \
				or not _exact_nonnegative_integer_equal(row[1], row[1], MAX_SOURCE_BYTES) \
				or not _is_lower_hex_sha256(row[2]) or seen.has(row[0]):
			return false
		seen[row[0]] = true
	for runner_path in RUNNER_SOURCE_PATHS:
		if not seen.has(String(runner_path).trim_prefix("res://")):
			return false
	return true


static func fingerprints_equal(first: Dictionary, second: Dictionary) -> bool:
	if not runner_sources_complete(first) or not runner_sources_complete(second):
		return false
	var keys := ["ready", "entries", "fileCount", "totalBytes", "sha256"]
	if not _has_exact_keys(first, keys) or not _has_exact_keys(second, keys) \
			or typeof(first.ready) != TYPE_BOOL or not first.ready or typeof(second.ready) != TYPE_BOOL or not second.ready \
			or not _exact_nonnegative_integer_equal(first.fileCount, second.fileCount, MAX_SOURCE_FILES) \
			or not _exact_nonnegative_integer_equal(first.totalBytes, second.totalBytes, MAX_SOURCE_BYTES) \
			or typeof(first.sha256) != TYPE_STRING or typeof(second.sha256) != TYPE_STRING \
			or not _is_lower_hex_sha256(first.sha256) or first.sha256 != second.sha256 \
			or not first.entries is Array or not second.entries is Array:
		return false
	var first_entries: Array = first.entries
	var second_entries: Array = second.entries
	if first_entries.size() > MAX_SOURCE_FILES or first_entries.size() != second_entries.size() \
			or first_entries.size() != int(first.fileCount) or second_entries.size() != int(second.fileCount):
		return false
	for index in range(first_entries.size()):
		var first_row: Variant = first_entries[index]
		var second_row: Variant = second_entries[index]
		if not first_row is Array or not second_row is Array or first_row.size() != 3 or second_row.size() != 3 \
				or typeof(first_row[0]) != TYPE_STRING or typeof(second_row[0]) != TYPE_STRING or first_row[0] != second_row[0] \
				or not _exact_nonnegative_integer_equal(first_row[1], second_row[1], MAX_SOURCE_BYTES) \
				or typeof(first_row[2]) != TYPE_STRING or typeof(second_row[2]) != TYPE_STRING \
				or not _is_lower_hex_sha256(first_row[2]) or first_row[2] != second_row[2]:
			return false
	return true


static func engines_equal(first: Dictionary, second: Dictionary) -> bool:
	var keys := ["ready", "version", "launcher", "runtime", "sha256"]
	if not _has_exact_keys(first, keys) or not _has_exact_keys(second, keys) \
			or typeof(first.ready) != TYPE_BOOL or not first.ready or typeof(second.ready) != TYPE_BOOL or not second.ready \
			or typeof(first.sha256) != TYPE_STRING or typeof(second.sha256) != TYPE_STRING \
			or not _is_lower_hex_sha256(first.sha256) or first.sha256 != second.sha256 \
			or not first.version is Dictionary or not second.version is Dictionary \
			or not first.launcher is Dictionary or not second.launcher is Dictionary \
			or not first.runtime is Dictionary or not second.runtime is Dictionary:
		return false
	if not _engine_versions_equal(first.version, second.version):
		return false
	return _executable_identities_equal(first.launcher, second.launcher) \
		and _executable_identities_equal(first.runtime, second.runtime)


static func phase_a_cores_equal(first: Dictionary, second: Dictionary) -> bool:
	if not _has_exact_keys(first, CORE_KEYS) or not _has_exact_keys(second, CORE_KEYS) \
			or typeof(first.schema) != TYPE_STRING or typeof(second.schema) != TYPE_STRING \
			or first.schema != "citadel_structural_composer_phase_a_core/v1" or first.schema != second.schema \
			or not _exact_nonnegative_integer_equal(first.revision, second.revision, MAX_EXACT_JSON_INTEGER) \
			or int(first.revision) != REVISION or not _exact_nonnegative_integer_equal(first.seed, second.seed, MAX_EXACT_JSON_INTEGER) \
			or int(first.seed) == 0 or typeof(first.runId) != TYPE_STRING or typeof(second.runId) != TYPE_STRING \
			or not _valid_run_id(first.runId) or first.runId != second.runId:
		return false
	for key in ["sourceFingerprintSha256", "engineIdentitySha256", "payloadSha256"]:
		if typeof(first[key]) != TYPE_STRING or typeof(second[key]) != TYPE_STRING \
				or not _is_lower_hex_sha256(first[key]) or first[key] != second[key]:
			return false
	if not first.sectionHashes is Dictionary or not second.sectionHashes is Dictionary \
			or not _has_exact_keys(first.sectionHashes, CORE_SECTION_HASH_KEYS) \
			or not _has_exact_keys(second.sectionHashes, CORE_SECTION_HASH_KEYS):
		return false
	for key in CORE_SECTION_HASH_KEYS:
		if typeof(first.sectionHashes[key]) != TYPE_STRING or typeof(second.sectionHashes[key]) != TYPE_STRING \
				or not _is_lower_hex_sha256(first.sectionHashes[key]) or first.sectionHashes[key] != second.sectionHashes[key]:
			return false
	if not first.counts is Dictionary or not second.counts is Dictionary \
			or not _has_exact_keys(first.counts, CORE_COUNT_KEYS) or not _has_exact_keys(second.counts, CORE_COUNT_KEYS):
		return false
	for key in CORE_COUNT_KEYS:
		if not _exact_nonnegative_integer_equal(first.counts[key], second.counts[key], MAX_EXACT_JSON_INTEGER):
			return false
	return true


static func _engine_versions_equal(first: Dictionary, second: Dictionary) -> bool:
	var keys := ["major", "minor", "patch", "status", "build", "hash"]
	if not _has_exact_keys(first, keys) or not _has_exact_keys(second, keys):
		return false
	for key in ["major", "minor", "patch"]:
		if not _exact_nonnegative_integer_equal(first[key], second[key], MAX_EXACT_JSON_INTEGER):
			return false
	for key in ["status", "build", "hash"]:
		if typeof(first[key]) != TYPE_STRING or typeof(second[key]) != TYPE_STRING or first[key] != second[key]:
			return false
	return true


static func _executable_identities_equal(first: Dictionary, second: Dictionary) -> bool:
	var keys := ["path", "length", "sha256"]
	return _has_exact_keys(first, keys) and _has_exact_keys(second, keys) \
		and typeof(first.path) == TYPE_STRING and typeof(second.path) == TYPE_STRING and first.path == second.path \
		and _exact_nonnegative_integer_equal(first.length, second.length, MAX_EXACT_JSON_INTEGER) \
		and typeof(first.sha256) == TYPE_STRING and typeof(second.sha256) == TYPE_STRING \
		and _is_lower_hex_sha256(first.sha256) and first.sha256 == second.sha256


static func _exact_nonnegative_integer_equal(first: Variant, second: Variant, maximum: int) -> bool:
	return _is_exact_nonnegative_integer(first, maximum) and _is_exact_nonnegative_integer(second, maximum) \
		and int(first) == int(second)


static func _is_exact_nonnegative_integer(value: Variant, maximum: int) -> bool:
	if typeof(value) == TYPE_INT:
		return value >= 0 and value <= maximum
	if typeof(value) == TYPE_FLOAT:
		return is_finite(value) and value >= 0.0 and value <= float(maximum) and floor(value) == value
	return false


static func _executable_file_identity(path: String) -> Dictionary:
	if not path.is_absolute_path() or not FileAccess.file_exists(path):
		return _fail("executable_missing")
	var bytes := FileAccess.get_file_as_bytes(path)
	if FileAccess.get_open_error() != OK or bytes.is_empty():
		return _fail("executable_unreadable")
	return {"ready": true, "path": path.replace("\\", "/"), "length": bytes.size(), "sha256": sha256_bytes(bytes)}


static func make_payload(run_id: String, seed: int, source_snapshot_sha: String, source_recipe_sha: String,
		blueprint_snapshot: Dictionary, furnishing_snapshot: Dictionary, reservations: Array,
		completion_facts: Dictionary, same_process_facts: Dictionary,
		fingerprint: Dictionary, engine: Dictionary) -> Dictionary:
	var assertions := {"completion": completion_facts.duplicate(true), "sameProcess": same_process_facts.duplicate(true)}
	var section_hashes := {
		"sourceSnapshot": source_snapshot_sha,
		"sourceRecipe": source_recipe_sha,
		"blueprintSnapshot": hash_variant(blueprint_snapshot),
		"parts": hash_variant(blueprint_snapshot.get("parts", [])),
		"rooms": hash_variant(blueprint_snapshot.get("rooms", [])),
		"recipe": hash_variant(blueprint_snapshot.get("recipe", {})),
		"furnishingSnapshot": hash_variant(furnishing_snapshot),
		"reservations": hash_variant(reservations),
		"phaseAAssertions": hash_variant(assertions)}
	var counts := {"parts": (blueprint_snapshot.get("parts", []) as Array).size(),
		"rooms": (blueprint_snapshot.get("rooms", []) as Array).size(),
		"furniture": (furnishing_snapshot.get("parts", []) as Array).size(), "reservations": reservations.size()}
	var payload := {"blueprintSnapshot": blueprint_snapshot.duplicate(true), "furnishingSnapshot": furnishing_snapshot.duplicate(true),
		"furnishingReservations": reservations.duplicate(true), "phaseAAssertions": assertions,
		"sectionHashes": section_hashes, "counts": counts,
		"sourceFingerprint": fingerprint.duplicate(true), "engineIdentity": engine.duplicate(true)}
	var payload_sha := hash_variant(payload)
	var core := {"schema": "citadel_structural_composer_phase_a_core/v1", "revision": REVISION,
		"runId": run_id, "seed": seed, "sourceFingerprintSha256": fingerprint.get("sha256", ""),
		"engineIdentitySha256": engine.get("sha256", ""), "payloadSha256": payload_sha,
		"sectionHashes": section_hashes.duplicate(true), "counts": counts.duplicate(true)}
	return {"schema": SCHEMA, "revision": REVISION, "runId": run_id, "seed": seed,
		"phaseACore": core, "phaseACoreSha256": hash_variant(core), "payload": payload, "payloadSha256": payload_sha}


static func validate_payload(payload: Variant, expected_seed := -1) -> Dictionary:
	var work := {"nodes": 0, "reconstructed": false}
	if not _safe_value(payload, 0, work, "$"):
		return _fail(String(work.get("reason", "unsafe_payload")), {"reconstructed": false,
			"detail": {"path": String(work.get("path", "$")), "nodes": int(work.get("nodes", 0))}})
	if not payload is Dictionary:
		return _fail("payload_not_dictionary", {"reconstructed": false})
	var value: Dictionary = payload
	if not _has_exact_keys(value, CHECKPOINT_KEYS) or String(value.get("schema", "")) != SCHEMA or typeof(value.get("revision")) != TYPE_INT or int(value.revision) != REVISION:
		return _fail("checkpoint_schema_mismatch", {"reconstructed": false})
	if not _valid_run_id(String(value.get("runId", ""))) or typeof(value.get("seed")) != TYPE_INT:
		return _fail("checkpoint_identity_invalid", {"reconstructed": false})
	var seed := int(value.seed)
	if seed == 0 or expected_seed != -1 and seed != expected_seed:
		return _fail("checkpoint_seed_mismatch", {"reconstructed": false})
	if not value.get("phaseACore") is Dictionary or not value.get("payload") is Dictionary or not _has_exact_keys(value.phaseACore, CORE_KEYS) or not _has_exact_keys(value.payload, PAYLOAD_KEYS):
		return _fail("checkpoint_collection_missing", {"reconstructed": false})
	var body: Dictionary = value.payload
	if String(value.get("payloadSha256", "")) != hash_variant(body) or String(value.get("phaseACoreSha256", "")) != hash_variant(value.phaseACore):
		return _fail("checkpoint_outer_binding_mismatch", {"reconstructed": false})
	var core: Dictionary = value.phaseACore
	if core.runId != value.runId or int(core.seed) != seed or core.payloadSha256 != value.payloadSha256 \
			or core.sourceFingerprintSha256 != body.sourceFingerprint.get("sha256", "") or core.engineIdentitySha256 != body.engineIdentity.get("sha256", "") \
			or core.sectionHashes != body.sectionHashes or core.counts != body.counts:
		return _fail("checkpoint_core_mismatch", {"reconstructed": false})
	if not body.get("blueprintSnapshot") is Dictionary or not body.get("furnishingSnapshot") is Dictionary \
			or not body.get("furnishingReservations") is Array or not body.get("phaseAAssertions") is Dictionary \
			or not body.get("sectionHashes") is Dictionary or not body.get("counts") is Dictionary \
			or not body.get("sourceFingerprint") is Dictionary or not body.get("engineIdentity") is Dictionary:
		return _fail("checkpoint_payload_collection_missing", {"reconstructed": false})
	if not runner_sources_complete(body.sourceFingerprint):
		return _fail("checkpoint_runner_source_inventory_missing", {"reconstructed": false})
	var blueprint: Dictionary = body.blueprintSnapshot
	var furnishing: Dictionary = body.furnishingSnapshot
	var reservations: Array = body.furnishingReservations
	if not blueprint.get("parts") is Array or not blueprint.get("rooms") is Array or not blueprint.get("recipe") is Dictionary \
			or not furnishing.get("parts") is Array:
		return _fail("checkpoint_snapshot_malformed", {"reconstructed": false})
	var parts: Array = blueprint.parts
	var furniture: Array = furnishing.parts
	if parts.size() > MAX_PARTS or furniture.size() > MAX_FURNITURE or (blueprint.rooms as Array).size() > MAX_ROOMS or reservations.size() > MAX_RESERVATIONS:
		return _fail("checkpoint_collection_limit", {"reconstructed": false})
	var part_ids := _unique_record_ids(parts)
	if not part_ids.ready:
		return _fail("checkpoint_part_ids_invalid", {"detail": part_ids, "reconstructed": false})
	var furniture_ids := _unique_record_ids(furniture)
	if not furniture_ids.ready:
		return _fail("checkpoint_furniture_ids_invalid", {"detail": furniture_ids, "reconstructed": false})
	var counts: Dictionary = body.counts
	if int(counts.get("parts", -1)) != parts.size() or int(counts.get("rooms", -1)) != (blueprint.rooms as Array).size() \
			or int(counts.get("furniture", -1)) != furniture.size() or int(counts.get("reservations", -1)) != reservations.size():
		return _fail("checkpoint_count_mismatch", {"reconstructed": false})
	var hashes: Dictionary = body.sectionHashes
	var expected_hashes := {"blueprintSnapshot": hash_variant(blueprint), "parts": hash_variant(parts),
		"rooms": hash_variant(blueprint.rooms), "recipe": hash_variant(blueprint.recipe),
		"furnishingSnapshot": hash_variant(furnishing), "reservations": hash_variant(reservations),
		"phaseAAssertions": hash_variant(body.phaseAAssertions)}
	for key in expected_hashes:
		if String(hashes.get(key, "")) != String(expected_hashes[key]):
			return _fail("checkpoint_internal_hash_mismatch", {"field": key, "reconstructed": false})
	if String(hashes.get("sourceSnapshot", "")).is_empty() or String(hashes.get("sourceRecipe", "")).is_empty():
		return _fail("checkpoint_source_hash_missing", {"reconstructed": false})
	return {"ready": true, "reconstructed": false, "payload": value}


static func encode_payload(payload: Dictionary) -> Dictionary:
	var validation := validate_payload(payload, int(payload.get("seed", -1)))
	if not validation.ready:
		return validation
	var payload_bytes := var_to_bytes(payload)
	if payload_bytes.is_empty() or payload_bytes.size() + FRAME_HEADER_BYTES > MAX_CHECKPOINT_BYTES:
		return _fail("checkpoint_byte_limit", {"reconstructed": false})
	var frame := PackedByteArray()
	frame.resize(FRAME_HEADER_BYTES + payload_bytes.size())
	var magic := FRAME_MAGIC.to_ascii_buffer()
	for index in range(magic.size()): frame[index] = magic[index]
	frame.encode_u32(8, REVISION)
	frame.encode_u64(12, payload_bytes.size())
	var payload_sha_bytes := sha256_bytes(payload_bytes).to_ascii_buffer()
	for index in range(payload_sha_bytes.size()): frame[20 + index] = payload_sha_bytes[index]
	for index in range(payload_bytes.size()): frame[FRAME_HEADER_BYTES + index] = payload_bytes[index]
	return {"ready": true, "bytes": frame, "size": frame.size(), "sha256": sha256_bytes(frame)}


static func decode_payload(bytes: PackedByteArray, expected_outer_sha: String, expected_seed: int) -> Dictionary:
	if bytes.size() < FRAME_HEADER_BYTES or bytes.size() > MAX_CHECKPOINT_BYTES:
		return _fail("checkpoint_byte_limit", {"reconstructed": false})
	if expected_outer_sha.is_empty() or sha256_bytes(bytes) != expected_outer_sha:
		return _fail("checkpoint_outer_sha_mismatch", {"reconstructed": false})
	if bytes.slice(0, 8).get_string_from_ascii() != FRAME_MAGIC or bytes.decode_u32(8) != REVISION:
		return _fail("checkpoint_frame_header_mismatch", {"reconstructed": false})
	var payload_length := int(bytes.decode_u64(12))
	if payload_length <= 0 or payload_length + FRAME_HEADER_BYTES != bytes.size():
		return _fail("checkpoint_frame_length_mismatch", {"reconstructed": false})
	var internal_sha := bytes.slice(20, FRAME_HEADER_BYTES).get_string_from_ascii()
	if not _is_lower_hex_sha256(internal_sha):
		return _fail("checkpoint_frame_sha_malformed", {"reconstructed": false})
	var payload_bytes := bytes.slice(FRAME_HEADER_BYTES, bytes.size())
	if sha256_bytes(payload_bytes) != internal_sha:
		return _fail("checkpoint_frame_sha_mismatch", {"reconstructed": false})
	# Godot 4.6's one-argument API keeps object deserialization disabled. Never
	# use bytes_to_var_with_objects for acceptance evidence.
	var decoded: Variant = bytes_to_var(payload_bytes)
	var validation := validate_payload(decoded, expected_seed)
	if not validation.ready:
		return validation
	if var_to_bytes(validation.payload) != payload_bytes:
		return _fail("checkpoint_noncanonical_encoding", {"reconstructed": false})
	return {"ready": true, "reconstructed": false, "payload": validation.payload}


static func write_atomic_fresh(final_path: String, temp_path: String, bytes: PackedByteArray) -> Dictionary:
	# Controlled single-owner artifact protocol: same-volume temp + atomic rename.
	# FileAccess.WRITE is not OS-level CreateNew and this function makes no claim
	# of safety against a hostile concurrent writer outside the wrapper protocol.
	if not final_path.is_absolute_path() or not temp_path.is_absolute_path() or final_path.get_base_dir() != temp_path.get_base_dir() \
			or final_path.to_lower() == temp_path.to_lower() or FileAccess.file_exists(final_path) or FileAccess.file_exists(temp_path):
		return _fail("atomic_path_invalid")
	if not DirAccess.dir_exists_absolute(final_path.get_base_dir()):
		return _fail("atomic_parent_missing")
	var output := FileAccess.open(temp_path, FileAccess.WRITE)
	if output == null:
		return _fail("atomic_temp_open_failed")
	output.store_buffer(bytes)
	output.flush()
	output.close()
	var reread := FileAccess.get_file_as_bytes(temp_path)
	if reread != bytes or FileAccess.file_exists(final_path):
		return _fail("atomic_temp_verification_failed")
	if DirAccess.rename_absolute(temp_path, final_path) != OK:
		return _fail("atomic_rename_failed")
	var final_bytes := FileAccess.get_file_as_bytes(final_path)
	if final_bytes != bytes:
		return _fail("atomic_final_verification_failed")
	return {"ready": true, "size": bytes.size(), "sha256": sha256_bytes(bytes)}


static func phase_a_report_matches_checkpoint(report: Dictionary, report_sha: String, checkpoint_sha: String,
		checkpoint_size: int, expected_seed: int, fingerprint: Dictionary, engine: Dictionary) -> Dictionary:
	if String(report.get("schema", "")) != PHASE_A_REPORT_SCHEMA or int(report.get("revision", -1)) != REVISION \
			or not bool(report.get("passed", false)) or int(report.get("seed", 0)) != expected_seed:
		return _fail("phase_a_report_invalid", {"reconstructed": false})
	if report_sha.is_empty() or checkpoint_sha.is_empty() or String(report.get("reportSha256", report_sha)) != report_sha:
		# reportSha256 is intentionally absent from the file to avoid a self-hash;
		# callers provide it. If present in adversarial input it must match.
		return _fail("phase_a_report_sha_mismatch", {"reconstructed": false})
	if String(report.get("checkpointSha256", "")) != checkpoint_sha or int(report.get("checkpointSize", -1)) != checkpoint_size \
			or String(report.get("checkpointSchema", "")) != SCHEMA:
		return _fail("phase_a_checkpoint_binding_mismatch", {"reconstructed": false})
	if not report.get("sourceFingerprint") is Dictionary or not fingerprints_equal(report.sourceFingerprint, fingerprint):
		return _fail("phase_a_fingerprint_mismatch", {"reconstructed": false})
	if not report.get("engineIdentity") is Dictionary or not engines_equal(report.engineIdentity, engine):
		return _fail("phase_a_engine_mismatch", {"reconstructed": false})
	return {"ready": true, "reconstructed": false}


static func _has_exact_keys(value: Dictionary, expected: Array) -> bool:
	var actual: Array = value.keys().map(func(key): return String(key))
	var wanted := expected.duplicate()
	actual.sort()
	wanted.sort()
	return actual == wanted


static func _valid_run_id(value: String) -> bool:
	if value.length() != 32 or value != value.to_lower():
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if not (code >= 48 and code <= 57 or code >= 97 and code <= 102):
			return false
	return true


static func _is_lower_hex_sha256(value: String) -> bool:
	if value.length() != 64 or value != value.to_lower():
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if not (code >= 48 and code <= 57 or code >= 97 and code <= 102):
			return false
	return true


static func _safe_value(value: Variant, depth: int, work: Dictionary, path: String) -> bool:
	work.nodes = int(work.get("nodes", 0)) + 1
	if work.nodes > MAX_NODES or depth > MAX_DEPTH:
		return _reject_unsafe(work, "payload_node_limit" if work.nodes > MAX_NODES else "payload_depth_limit", path)
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			pass
		TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return _reject_unsafe(work, "payload_unsafe_type_%d" % typeof(value), path)
		TYPE_FLOAT:
			if not is_finite(value): return _reject_unsafe(work, "payload_nonfinite_scalar", path)
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			if String(value).to_utf8_buffer().size() > MAX_STRING_BYTES: return _reject_unsafe(work, "payload_string_limit", path)
		TYPE_VECTOR2:
			if not (value as Vector2).is_finite(): return _reject_unsafe(work, "payload_nonfinite_vector2", path)
		TYPE_VECTOR2I, TYPE_RECT2I, TYPE_VECTOR3I, TYPE_VECTOR4I:
			pass
		TYPE_VECTOR3:
			if not (value as Vector3).is_finite(): return _reject_unsafe(work, "payload_nonfinite_vector3", path)
		TYPE_VECTOR4:
			if not (value as Vector4).is_finite(): return _reject_unsafe(work, "payload_nonfinite_vector4", path)
		TYPE_QUATERNION:
			if not (value as Quaternion).is_finite(): return _reject_unsafe(work, "payload_nonfinite_quaternion", path)
		TYPE_COLOR:
			var color: Color = value
			if not is_finite(color.r) or not is_finite(color.g) or not is_finite(color.b) or not is_finite(color.a): return _reject_unsafe(work, "payload_nonfinite_color", path)
		TYPE_RECT2:
			var rect: Rect2 = value
			if not rect.position.is_finite() or not rect.size.is_finite(): return _reject_unsafe(work, "payload_nonfinite_rect2", path)
		TYPE_AABB:
			var bounds: AABB = value
			if not bounds.position.is_finite() or not bounds.size.is_finite(): return _reject_unsafe(work, "payload_nonfinite_aabb", path)
		TYPE_TRANSFORM3D:
			var transform: Transform3D = value
			if not transform.origin.is_finite() or not transform.basis.x.is_finite() or not transform.basis.y.is_finite() or not transform.basis.z.is_finite(): return _reject_unsafe(work, "payload_nonfinite_transform", path)
		TYPE_TRANSFORM2D:
			var transform_2d: Transform2D = value
			if not transform_2d.x.is_finite() or not transform_2d.y.is_finite() or not transform_2d.origin.is_finite(): return _reject_unsafe(work, "payload_nonfinite_transform2d", path)
		TYPE_BASIS:
			var basis: Basis = value
			if not basis.x.is_finite() or not basis.y.is_finite() or not basis.z.is_finite(): return _reject_unsafe(work, "payload_nonfinite_basis", path)
		TYPE_PLANE:
			var plane: Plane = value
			if not plane.normal.is_finite() or not is_finite(plane.d): return _reject_unsafe(work, "payload_nonfinite_plane", path)
		TYPE_PROJECTION:
			var projection: Projection = value
			if not projection.x.is_finite() or not projection.y.is_finite() or not projection.z.is_finite() or not projection.w.is_finite(): return _reject_unsafe(work, "payload_nonfinite_projection", path)
		TYPE_ARRAY:
			for index in range(value.size()):
				if not _safe_value(value[index], depth + 1, work, _bounded_path(path + "[%d]" % index)): return false
		TYPE_DICTIONARY:
			var keys: Array = value.keys()
			for key in keys:
				if not key is String:
					return _reject_unsafe(work, "payload_nonstring_key", path)
			keys.sort()
			for key in keys:
				var child_path := _bounded_path(path + _diagnostic_key_segment(String(key)))
				if not _safe_value(key, depth + 1, work, child_path) or not _safe_value(value[key], depth + 1, work, child_path): return false
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_STRING_ARRAY:
			if var_to_bytes(value).size() > MAX_STRING_BYTES: return _reject_unsafe(work, "payload_packed_array_limit", path)
		TYPE_PACKED_VECTOR2_ARRAY:
			if var_to_bytes(value).size() > MAX_STRING_BYTES: return _reject_unsafe(work, "payload_packed_array_limit", path)
			for index in range(value.size()):
				if not (value[index] as Vector2).is_finite(): return _reject_unsafe(work, "payload_nonfinite_packed_vector2", _bounded_path(path + "[%d]" % index))
		TYPE_PACKED_VECTOR3_ARRAY:
			if var_to_bytes(value).size() > MAX_STRING_BYTES: return _reject_unsafe(work, "payload_packed_array_limit", path)
			for index in range(value.size()):
				if not (value[index] as Vector3).is_finite(): return _reject_unsafe(work, "payload_nonfinite_packed_vector3", _bounded_path(path + "[%d]" % index))
		TYPE_PACKED_COLOR_ARRAY:
			if var_to_bytes(value).size() > MAX_STRING_BYTES: return _reject_unsafe(work, "payload_packed_array_limit", path)
			for index in range(value.size()):
				var packed_color: Color = value[index]
				if not is_finite(packed_color.r) or not is_finite(packed_color.g) or not is_finite(packed_color.b) or not is_finite(packed_color.a):
					return _reject_unsafe(work, "payload_nonfinite_packed_color", _bounded_path(path + "[%d]" % index))
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			if var_to_bytes(value).size() > MAX_STRING_BYTES: return _reject_unsafe(work, "payload_packed_array_limit", path)
			for index in range(value.size()):
				if not is_finite(value[index]): return _reject_unsafe(work, "payload_nonfinite_packed_float", _bounded_path(path + "[%d]" % index))
		_:
			return _reject_unsafe(work, "payload_unsupported_type_%d" % typeof(value), path)
	return true


static func _reject_unsafe(work: Dictionary, reason: String, path: String) -> bool:
	work["reason"] = reason
	work["path"] = _bounded_path(path)
	return false


static func _diagnostic_key_segment(key: String) -> String:
	var escaped := ""
	var content_budget := MAX_DIAGNOSTIC_SEGMENT_BYTES - 4
	for index in range(key.length()):
		var code := key.unicode_at(index)
		var piece := String.chr(code) if code >= 32 and code <= 126 and code != 34 and code != 92 else "\\u{%x}" % code
		if (escaped + piece).to_utf8_buffer().size() > content_budget - 3:
			escaped += "..."
			break
		escaped += piece
	return "[\"%s\"]" % escaped


static func _bounded_path(path: String) -> String:
	if path.to_utf8_buffer().size() <= MAX_DIAGNOSTIC_PATH_BYTES:
		return path
	var result := ""
	for index in range(path.length()):
		var piece := String.chr(path.unicode_at(index))
		if (result + piece).to_utf8_buffer().size() > MAX_DIAGNOSTIC_PATH_BYTES - 3:
			return result + "..."
		result += piece
	return result


static func _unique_record_ids(records: Array) -> Dictionary:
	var seen: Dictionary = {}
	for record in records:
		if not record is Dictionary:
			return _fail("record_not_dictionary")
		var id := String(record.get("id", ""))
		if id.is_empty() or id != id.strip_edges() or seen.has(id):
			return _fail("record_id_invalid")
		seen[id] = true
	return {"ready": true, "count": seen.size()}


static func _collect_gdscript_paths(directory_path: String, result: Array[String]) -> bool:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		return false
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if name != "." and name != "..":
			var path := directory_path.path_join(name)
			if directory.current_is_dir():
				if not _collect_gdscript_paths(path, result):
					directory.list_dir_end()
					return false
			elif name.ends_with(".gd"):
				result.append(path)
		name = directory.get_next()
	directory.list_dir_end()
	return true


static func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate(true)
	result["ready"] = false
	result["reason"] = reason
	return result

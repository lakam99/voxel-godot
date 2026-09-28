extends SceneTree

## Fixed failing artifact inspection only. No publication or comparison runs.
const SHARD := "res://artifacts/citadel-visual-reset/facade-paving-comparison-v2-static-originals-4/shard.bin"
const EXPECTED_BYTES := 542240
const EXPECTED_SHA := "8f0a36e252a1aa7aab81d1eee429ef5ea65041affc9fd163fe77d1ee6c9bd020"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var file: FileAccess = FileAccess.open(SHARD, FileAccess.READ)
	if file == null:
		_fail("shard_open")
		return
	if file.get_length() != EXPECTED_BYTES:
		file.close()
		_fail("shard_size")
		return
	var bytes: PackedByteArray = file.get_buffer(EXPECTED_BYTES)
	var read_ok: bool = bytes.size() == EXPECTED_BYTES and file.get_error() == OK
	file.close()
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	if not read_ok or hash.finish().hex_encode() != EXPECTED_SHA:
		_fail("shard_sha256")
		return
	var shard: Variant = bytes_to_var(bytes)
	if not shard is Dictionary or shard.get("job") != "static:originals:4" or not shard.get("result") is Dictionary or not shard.result.get("rows") is Array or shard.result.rows.size() != 512:
		_fail("shard_schema")
		return
	var failures: int = 0
	var counter_only_failures: int = 0
	var first: Array = []
	for row in shard.result.rows:
		if not row is Dictionary or not row.get("exact") is bool:
			_fail("row_schema")
			return
		if row.exact: continue
		failures += 1
		if _only_generated_counter_diff(row): counter_only_failures += 1
		if first.size() < 16: first.append(row)
	print(JSON.stringify(_json_value({"readComplete": true, "artifactSha256": EXPECTED_SHA, "artifactBytes": EXPECTED_BYTES,
		"job": shard.job, "totalRowCount": shard.result.rows.size(), "totalFailureCount": failures,
		"counterOnlyFailureCount": counter_only_failures, "allFailuresCounterOnly": failures > 0 and counter_only_failures == failures,
		"returnedFailureCount": first.size(), "truncated": failures > first.size(), "failedRows": first}), "\t", true, true))
	quit(0)

func _only_generated_counter_diff(row: Dictionary) -> bool:
	# Every differing key is recorded for the single primitive in these rows.
	# This diagnoses all saved failures; actual-node admission remains separate.
	if row.get("collisionExact") != true or row.get("originalPrimitiveCount") != 1 or row.get("candidatePrimitiveCount") != 1 or row.get("firstVisualMismatches", []).size() != 1: return false
	var difference: Dictionary = row.firstVisualMismatches[0]
	if difference.get("changedFields") != ["publisherNodeIdentity"]: return false
	var old: Array = difference.originalValues.get("publisherNodeIdentity", [])
	var current: Array = difference.candidateValues.get("publisherNodeIdentity", [])
	if old.size() != 1 or current.size() != 1: return false
	for identity in [old[0], current[0]]:
		if not identity is Dictionary or identity.get("sourcePartId") != row.partId or identity.get("emissionOrdinal") != 0 or not identity.get("requestedLabel") is String: return false
		var label: String = identity.requestedLabel
		if not label.begins_with("@MeshInstance3D@") or not label.trim_prefix("@MeshInstance3D@").is_valid_int(): return false
	var left: Dictionary = old[0].duplicate()
	var right: Dictionary = current[0].duplicate()
	left.erase("requestedLabel")
	right.erase("requestedLabel")
	return var_to_bytes(left) == var_to_bytes(right)

func _json_value(value: Variant) -> Variant:
	if value is Transform3D: return {"origin": _json_value(value.origin), "basis": _json_value(value.basis)}
	if value is Basis: return [_json_value(value.x), _json_value(value.y), _json_value(value.z)]
	if value is Vector3: return [value.x, value.y, value.z]
	if value is Color: return [value.r, value.g, value.b, value.a]
	if value is AABB: return {"position": _json_value(value.position), "size": _json_value(value.size)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[key] = _json_value(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value: result.append(_json_value(item))
		return result
	return value

func _fail(reason: String) -> void:
	print(JSON.stringify({"readComplete": false, "reason": reason}))
	quit(2)

extends "res://scripts/testing/buildings/CitadelFacadePavingComparisonContract.gd"

## Read-only child: normal comparison/admission/output protocol is inherited.
## Override emits at most 16 compact stdout rows and returns super unchanged.
## Main runs JOB=audit:after_standard with fresh ordinary comparison paths.
const BINDING_DIAGNOSTIC_ROWS := 16
const BINDING_DIAGNOSTIC_WORK := 10000
const BINDING_DIAGNOSTIC_BYTES := 32 * 1024 * 1024
var _binding_diag_work: int = 0
var _binding_diag_rows: Array = []

func _bindings_valid(value: Dictionary) -> bool:
	var original_result: bool = super._bindings_valid(value)
	_binding_diag_work = 0
	_binding_diag_rows = []
	if value.side != "after":
		_emit_binding_diagnostic(original_result)
		return original_result
	var cycle: Dictionary = value.cycle
	var post: Dictionary = cycle.postValidationSnapshot
	var wired: Dictionary = cycle.finishValues.artifacts
	var original: Dictionary = {}
	for record in _assembly.afterSnapshot.parts: original[record.id] = record
	var required: Dictionary = {}
	for id in _finish_ids:
		var joint: Dictionary = original[id].recipe.pavingFootingJoints
		required[id] = true
		for foot_id in joint.footPartIds: required[foot_id] = true
	var ids: Array = []
	var records: Array = []
	var joint_records_exact: bool = true
	for record in post.parts:
		ids.append(record.id)
		if record.recipe.has("pavingFootingJoints"):
			joint_records_exact = joint_records_exact and var_to_bytes(record.recipe.pavingFootingJoints) == var_to_bytes(original[record.id].recipe.get("pavingFootingJoints"))
		if required.has(record.id) or record.recipe.has("pavingFootingJoints") or record.kind in ["door", "window"] or record.semantic.contains("eave") or bool(record.recipe.get("weatheringEave", false)): records.append(record)
	var expected: Array = [String(post.recipe.get("sourceBlueprintId", post.id)), post.recipe, ids, records]
	var expected_bytes: PackedByteArray = var_to_bytes(expected)
	for id in _finish_ids:
		if not _within_budget() or _binding_diag_rows.size() >= BINDING_DIAGNOSTIC_ROWS: break
		var joint: Dictionary = original[id].recipe.pavingFootingJoints
		var actual: Variant = cycle.sourceBindings.get(id)
		var artifact: Dictionary = wired.get(id, {})
		var header: Dictionary = {"partId": id, "kind": "binding_guards", "artifactCount": wired.size(), "bindingCount": cycle.sourceBindings.size(), "expectedFinishCount": _finish_ids.size(), "committedJointRecordsExact": joint_records_exact,
			"geometryDigestExact": artifact.get("geometryDigest") == joint.geometryDigest,
			"constructionDigestExact": artifact.get("constructionDigest") == joint.constructionDigest,
			"expectedBindingBytes": expected_bytes.size(), "expectedBindingDigest": _raw_digest(expected_bytes),
			"storedBindingDigest": artifact.get("sourceBindingDigest")}
		if not actual is PackedByteArray or actual.size() > BINDING_DIAGNOSTIC_BYTES or expected_bytes.size() > BINDING_DIAGNOSTIC_BYTES:
			header["reason"] = "invalid_or_excessive_binding"
			_binding_diag_rows.append(header)
			continue
		header["actualBindingBytes"] = actual.size()
		header["actualBindingDigest"] = _raw_digest(actual)
		header["actualMatchesStoredDigest"] = _raw_digest(actual) == artifact.get("sourceBindingDigest")
		header["wholeBytesExact"] = actual == expected_bytes
		header["firstByteDifference"] = _first_byte_difference(actual, expected_bytes)
		if actual.is_empty():
			header["reason"] = "persisted_binding_empty_decode_not_attempted"
			_binding_diag_rows.append(header)
			continue
		var decoded: Variant = bytes_to_var(actual)
		header["decodedFacts"] = _binding_type_facts(decoded)
		header["decodedRoundTripExact"] = var_to_bytes(decoded) == actual
		_binding_diag_rows.append(header)
		if not decoded is Array or decoded.size() != 4: continue
		for index in range(4):
			if _binding_diag_rows.size() >= BINDING_DIAGNOSTIC_ROWS: break
			var actual_bytes: PackedByteArray = var_to_bytes(decoded[index])
			var wanted_bytes: PackedByteArray = var_to_bytes(expected[index])
			var row: Dictionary = {"partId": id, "component": ["canonicalSourceId", "recipe", "orderedIds", "records"][index],
				"actual": _binding_type_facts(decoded[index]), "expected": _binding_type_facts(expected[index]),
				"actualDigest": _raw_digest(decoded[index]), "expectedDigest": _raw_digest(expected[index]),
				"bytesExact": actual_bytes == wanted_bytes, "firstByteDifference": _first_byte_difference(actual_bytes, wanted_bytes)}
			if actual_bytes != wanted_bytes: row["firstDifference"] = _first_binding_difference(decoded[index], expected[index], row.component, 0)
			_binding_diag_rows.append(row)
	_emit_binding_diagnostic(original_result)
	return original_result

func _first_byte_difference(actual: PackedByteArray, expected: PackedByteArray) -> int:
	# Byte scans have their own fixed cap; -2 is explicitly unexamined remainder.
	for index in range(mini(mini(actual.size(), expected.size()), 65536)):
		if actual[index] != expected[index]: return index
	if mini(actual.size(), expected.size()) > 65536: return -2
	return -1 if actual.size() == expected.size() else mini(actual.size(), expected.size())

func _binding_type_facts(value: Variant) -> Dictionary:
	var result: Dictionary = {"variantType": type_string(typeof(value))}
	if value is Array:
		result["size"] = value.size()
		result["typedBuiltin"] = value.get_typed_builtin()
		result["typedClass"] = String(value.get_typed_class_name())
	elif value is Dictionary:
		result["size"] = value.size()
		result["orderedKeysDigest"] = _raw_digest(value.keys())
	return result

func _first_binding_difference(actual: Variant, expected: Variant, path: String, depth: int) -> Dictionary:
	_binding_diag_work += 1
	if depth > 32 or _binding_diag_work > BINDING_DIAGNOSTIC_WORK or not _within_budget(): return {"path": path, "reason": "diagnostic_work_bound"}
	if typeof(actual) != typeof(expected): return {"path": path, "reason": "variant_type", "actual": _binding_type_facts(actual), "expected": _binding_type_facts(expected)}
	if actual is Array:
		if _binding_type_facts(actual) != _binding_type_facts(expected): return {"path": path, "reason": "array_type_or_length", "actual": _binding_type_facts(actual), "expected": _binding_type_facts(expected)}
		for index in range(actual.size()):
			_binding_diag_work += 1
			if _binding_diag_work > BINDING_DIAGNOSTIC_WORK or not _within_budget(): return {"path": path, "reason": "diagnostic_work_bound"}
			if var_to_bytes(actual[index]) != var_to_bytes(expected[index]):
				var result: Dictionary = _first_binding_difference(actual[index], expected[index], path + "[" + str(index) + "]", depth + 1)
				if actual[index] is Dictionary: result["actualRecordId"] = actual[index].get("id")
				if expected[index] is Dictionary: result["expectedRecordId"] = expected[index].get("id")
				return result
	elif actual is Dictionary:
		if var_to_bytes(actual.keys()) != var_to_bytes(expected.keys()): return {"path": path, "reason": "dictionary_key_order_or_types", "actual": _binding_type_facts(actual), "expected": _binding_type_facts(expected)}
		for key in actual:
			_binding_diag_work += 1
			if _binding_diag_work > BINDING_DIAGNOSTIC_WORK or not _within_budget(): return {"path": path, "reason": "diagnostic_work_bound"}
			if var_to_bytes(actual[key]) != var_to_bytes(expected[key]): return _first_binding_difference(actual[key], expected[key], path + "." + str(key), depth + 1)
	return {"path": path, "reason": "encoded_leaf_or_container_metadata", "actual": _binding_type_facts(actual), "expected": _binding_type_facts(expected), "actualDigest": _raw_digest(actual), "expectedDigest": _raw_digest(expected)}

func _emit_binding_diagnostic(original_result: bool) -> void:
	print("PAVING_BINDING_DIAGNOSTIC ", JSON.stringify({"originalBindingsValid": original_result, "rows": _binding_diag_rows, "work": _binding_diag_work, "maxRows": BINDING_DIAGNOSTIC_ROWS, "maxWork": BINDING_DIAGNOSTIC_WORK, "evidenceLevel": "read_only_binding_byte_diagnosis_no_assertion_change"}))

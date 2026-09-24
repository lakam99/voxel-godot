extends RefCounted
class_name NativeCollisionMemoryPolicy

## Pure checked byte accounting for N5 collision source and physics artifacts.
## Production limits are deliberately injected by the owner after measurement;
## this component defines the formula and validates a configured policy only.
const SCHEMA := "n5-collision-memory-policy/v1"
const FORMULA_VERSION := "n5-collision-memory-formula/v1"
const VECTOR3_F32_BYTES := 12
const MAX_I64 := 0x7fffffffffffffff

var _config := {}
var _identity := ""


func configure(config: Dictionary) -> Dictionary:
	if not _config.is_empty():
		return {"status":"failed", "reason":"collision_memory_policy_already_configured"}
	var integer_fields := ["maxVerticesPerRow", "verticesPerShape",
		"rowEntryBytes", "bodyEntryBytes", "shapeEntryBytes",
		"physicsPayloadMultiplier", "maxRowsPerWindow",
		"maxWindowChargedBytes", "maxAggregateChargedBytes",
		"maxReservations"]
	for field in integer_fields:
		if not config.get(field) is int or int(config.get(field, 0)) <= 0:
			return {"status":"failed", "reason":"collision_memory_policy_config_invalid",
				"field":field}
	if int(config.maxAggregateChargedBytes) < int(config.maxWindowChargedBytes) \
			or int(config.rowEntryBytes) > int(config.maxWindowChargedBytes):
		return {"status":"failed", "reason":"collision_memory_policy_cap_invalid"}
	_config = config.duplicate(true)
	_identity = _config_identity(_config)
	return {"status":"ready", "schema":SCHEMA, "formulaVersion":FORMULA_VERSION,
		"policyIdentity":_identity, "config":_config.duplicate(true)}


func is_configured() -> bool:
	return not _config.is_empty() and not _identity.is_empty()


func policy_identity() -> String:
	return _identity


func formula_version() -> String:
	return FORMULA_VERSION


func limits() -> Dictionary:
	return _config.duplicate(true)


func estimate_row(vertex_count: int, expected_hit: bool) -> Dictionary:
	if not is_configured():
		return {"status":"failed", "reason":"collision_memory_policy_unconfigured"}
	if vertex_count < 0 or vertex_count > int(_config.maxVerticesPerRow) \
			or expected_hit != (vertex_count > 0):
		return {"status":"failed", "reason":"collision_memory_row_invalid"}
	var source_result := _checked_mul(vertex_count, VECTOR3_F32_BYTES)
	if source_result.get("status") != "ready": return source_result
	var source_bytes := int(source_result.value)
	var shape_result_count := _shape_count(vertex_count,
		int(_config.verticesPerShape))
	if shape_result_count.get("status") != "ready": return shape_result_count
	var shape_count := int(shape_result_count.value)
	var shape_result := _checked_mul(shape_count, int(_config.shapeEntryBytes))
	if shape_result.get("status") != "ready": return shape_result
	var payload_result := _checked_mul(source_bytes,
		int(_config.physicsPayloadMultiplier))
	if payload_result.get("status") != "ready": return payload_result
	var charged_result := _checked_add(int(_config.rowEntryBytes),
		int(_config.bodyEntryBytes) if expected_hit else 0)
	if charged_result.get("status") != "ready": return charged_result
	charged_result = _checked_add(int(charged_result.value), int(shape_result.value))
	if charged_result.get("status") != "ready": return charged_result
	charged_result = _checked_add(int(charged_result.value), int(payload_result.value))
	if charged_result.get("status") != "ready": return charged_result
	return {"status":"ready", "schema":SCHEMA,
		"formulaVersion":FORMULA_VERSION, "policyIdentity":_identity,
		"vertexCount":vertex_count, "expectedHit":expected_hit,
		"sourceVertexBytes":source_bytes, "shapeCount":shape_count,
		"expectedBodyCount":1 if expected_hit else 0,
		"physicalChargedBytes":int(charged_result.value)}


func _shape_count(vertex_count: int, vertices_per_shape: int) -> Dictionary:
	if vertex_count < 0 or vertices_per_shape <= 0:
		return {"status":"failed", "reason":"collision_memory_shape_count_invalid"}
	@warning_ignore("integer_division")
	var quotient: int = vertex_count / vertices_per_shape
	var remainder: int = vertex_count % vertices_per_shape
	if remainder == 0:
		return {"status":"ready", "value":quotient}
	var rounded := _checked_add(quotient, 1)
	if rounded.get("status") != "ready": return rounded
	return {"status":"ready", "value":int(rounded.value)}


func estimate_window(rows: Array) -> Dictionary:
	if not is_configured():
		return {"status":"failed", "reason":"collision_memory_policy_unconfigured"}
	if rows.is_empty() or rows.size() > int(_config.maxRowsPerWindow):
		return {"status":"failed", "reason":"collision_memory_window_rows_invalid"}
	var source_bytes := 0
	var physical_bytes := 0
	var shape_count := 0
	var body_count := 0
	for row in rows:
		if not row is Dictionary or not row.get("vertexCount") is int \
				or not row.get("expectedHit") is bool:
			return {"status":"failed", "reason":"collision_memory_row_invalid"}
		var estimate: Dictionary = estimate_row(int(row.vertexCount), bool(row.expectedHit))
		if estimate.get("status") != "ready": return estimate
		var source_result := _checked_add(source_bytes, int(estimate.sourceVertexBytes))
		if source_result.get("status") != "ready": return source_result
		source_bytes = int(source_result.value)
		var physical_result := _checked_add(physical_bytes,
			int(estimate.physicalChargedBytes))
		if physical_result.get("status") != "ready": return physical_result
		physical_bytes = int(physical_result.value)
		var shape_result := _checked_add(shape_count, int(estimate.shapeCount))
		if shape_result.get("status") != "ready": return shape_result
		shape_count = int(shape_result.value)
		var body_result := _checked_add(body_count, int(estimate.expectedBodyCount))
		if body_result.get("status") != "ready": return body_result
		body_count = int(body_result.value)
	return {"status":"ready", "schema":SCHEMA,
		"formulaVersion":FORMULA_VERSION, "policyIdentity":_identity,
		"rowCount":rows.size(), "shapeCount":shape_count,
		"expectedBodyCount":body_count,
		"sourceVertexBytes":source_bytes,
		"physicalChargedBytes":physical_bytes,
		"withinWindowCap":physical_bytes <= int(_config.maxWindowChargedBytes)}


func _checked_mul(left: int, right: int) -> Dictionary:
	if left < 0 or right < 0:
		return {"status":"failed", "reason":"collision_memory_byte_overflow"}
	if left == 0:
		return {"status":"ready", "value":0}
	@warning_ignore("integer_division")
	var max_right: int = MAX_I64 / left
	if right > max_right:
		return {"status":"failed", "reason":"collision_memory_byte_overflow"}
	return {"status":"ready", "value":left * right}


func _checked_add(left: int, right: int) -> Dictionary:
	if left < 0 or right < 0 or left > MAX_I64 - right:
		return {"status":"failed", "reason":"collision_memory_byte_overflow"}
	return {"status":"ready", "value":left + right}


func _config_identity(config: Dictionary) -> String:
	return ("%s:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d" % [FORMULA_VERSION,
		int(config.maxVerticesPerRow), int(config.verticesPerShape),
		int(config.rowEntryBytes), int(config.bodyEntryBytes),
		int(config.shapeEntryBytes), int(config.physicsPayloadMultiplier),
		int(config.maxRowsPerWindow), int(config.maxWindowChargedBytes),
		int(config.maxAggregateChargedBytes), int(config.maxReservations)]).sha256_text()

extends RefCounted
class_name EcologyProducerCatalogContext

## Main-thread, no-yield sharing scope for one semantic producer-catalog capture.
## The context carries values only; per-source terrain/admission/removal inputs
## remain outside it and retain their own source-domain revisions.

const DomainScript := preload("res://scripts/world/EcologyProducerDomain.gd")
const SCHEMA := "ecology-producer-catalog-context/v1"
const MAX_VALUE_DEPTH := 48

var _active_context: Dictionary = {}
var _active_scope_id := 0
var _active_scope_depth := 0
var _next_scope_id := 0
var _next_token_id := 0
var _active_token_stack: Array[int] = []


static func create(world_id: String, world_seed: String,
		catalog_inputs: Dictionary) -> Dictionary:
	if world_id.is_empty() or world_seed.is_empty() or catalog_inputs.is_empty():
		return {"status":"failed", "reason":"ecology_catalog_context_identity_or_values_missing"}
	var owned_result := _copy_owned_value(catalog_inputs, 0)
	if not bool(owned_result.get("ok", false)) or not owned_result.get("value", null) is Dictionary:
		return {"status":"failed", "reason":String(owned_result.get("reason",
			"ecology_catalog_context_contains_unsupported_value"))}
	var payload := {"schema":SCHEMA, "worldId":world_id,
		"worldSeed":world_seed, "catalogInputs":owned_result.value}
	var digest := DomainScript.digest_value(payload)
	if digest.length() != 64:
		return {"status":"failed", "reason":"ecology_catalog_context_digest_unavailable"}
	payload["catalogContextDigest"] = digest
	var frozen: Variant = DomainScript.freeze_value(payload)
	if not frozen is Dictionary or not frozen.is_read_only():
		return {"status":"failed", "reason":"ecology_catalog_context_freeze_failed"}
	return {"status":"ready", "context":frozen,
		"catalogContextDigest":digest}


func begin_scope(context: Dictionary) -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_catalog_context_requires_main_thread"}
	if String(context.get("schema", "")) != SCHEMA \
			or String(context.get("worldId", "")).is_empty() \
			or String(context.get("worldSeed", "")).is_empty() \
			or not context.get("catalogInputs", null) is Dictionary:
		return {"status":"failed", "reason":"ecology_catalog_context_invalid"}
	var owned_result := _copy_owned_value(context.catalogInputs, 0)
	if not bool(owned_result.get("ok", false)) or not owned_result.get("value", null) is Dictionary:
		return {"status":"failed", "reason":String(owned_result.get("reason",
			"ecology_catalog_context_contains_unsupported_value"))}
	var payload := {"schema":SCHEMA, "worldId":String(context.worldId),
		"worldSeed":String(context.worldSeed),
		"catalogInputs":owned_result.value}
	var expected_digest := DomainScript.digest_value(payload)
	if expected_digest.length() != 64 \
			or expected_digest != String(context.get("catalogContextDigest", "")):
		return {"status":"failed", "reason":"ecology_catalog_context_content_digest_mismatch"}
	payload["catalogContextDigest"] = expected_digest
	var frozen_payload: Variant = DomainScript.freeze_value(payload)
	if not frozen_payload is Dictionary or not frozen_payload.is_read_only():
		return {"status":"failed", "reason":"ecology_catalog_context_scope_freeze_failed"}
	if _active_scope_depth > 0:
		if _active_context != frozen_payload:
			return {"status":"failed", "reason":"ecology_catalog_context_nested_identity_mismatch"}
	else:
		_next_scope_id += 1
		_active_scope_id = _next_scope_id
		_active_context = frozen_payload
	_next_token_id += 1
	_active_token_stack.append(_next_token_id)
	_active_scope_depth = _active_token_stack.size()
	return {"status":"ready", "scopeId":_active_scope_id,
		"depth":_active_scope_depth, "tokenId":_next_token_id,
		"contextDigest":String(_active_context.catalogContextDigest)}


func context_for(world_id: String, world_seed: String) -> Dictionary:
	if _active_scope_depth <= 0:
		return {"status":"absent", "reason":"ecology_catalog_context_scope_absent"}
	if world_id != String(_active_context.get("worldId", "")) \
			or world_seed != String(_active_context.get("worldSeed", "")):
		return {"status":"failed", "reason":"ecology_catalog_context_scope_identity_mismatch"}
	return {"status":"ready", "context":_active_context,
		"catalogContextDigest":String(_active_context.catalogContextDigest),
		"scopeId":_active_scope_id, "depth":_active_scope_depth}


func end_scope(token: Dictionary) -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_catalog_context_requires_main_thread"}
	if _active_scope_depth <= 0 or int(token.get("scopeId", 0)) != _active_scope_id \
			or int(token.get("depth", 0)) != _active_scope_depth \
			or int(token.get("tokenId", 0)) <= 0 \
			or _active_token_stack.is_empty() \
			or int(_active_token_stack.back()) != int(token.get("tokenId", 0)):
		return {"status":"failed", "reason":"ecology_catalog_context_scope_token_mismatch"}
	var digest := String(_active_context.get("catalogContextDigest", ""))
	_active_token_stack.pop_back()
	_active_scope_depth = _active_token_stack.size()
	if _active_scope_depth == 0:
		_active_scope_id = 0
		_active_context = {}
	return {"status":"ready", "scopeId":int(token.scopeId),
		"contextDigest":digest, "remainingDepth":_active_scope_depth}


func scope_depth() -> int:
	return _active_scope_depth


static func _copy_owned_value(value: Variant, depth: int) -> Dictionary:
	if depth > MAX_VALUE_DEPTH:
		return {"ok":false, "reason":"ecology_catalog_context_value_depth_exceeded"}
	if value is Dictionary:
		var copied: Dictionary = {}
		for key: Variant in value.keys():
			if typeof(key) != TYPE_STRING:
				return {"ok":false, "reason":"ecology_catalog_context_dictionary_key_unsupported"}
			if copied.has(key):
				return {"ok":false, "reason":"ecology_catalog_context_dictionary_key_duplicate"}
			var child := _copy_owned_value(value[key], depth + 1)
			if not bool(child.get("ok", false)):
				return child
			copied[String(key)] = child.value
		return {"ok":true, "value":copied}
	if value is Array:
		var copied: Array = []
		for item: Variant in value:
			var child := _copy_owned_value(item, depth + 1)
			if not bool(child.get("ok", false)):
				return child
			copied.append(child.value)
		return {"ok":true, "value":copied}
	if value is float and not is_finite(value):
		return {"ok":false, "reason":"ecology_catalog_context_nonfinite_scalar"}
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, \
		TYPE_VECTOR2I, TYPE_VECTOR3I:
			return {"ok":true, "value":value}
		TYPE_VECTOR2:
			return {"ok":true, "value":value} if is_finite(value.x) and is_finite(value.y) \
				else {"ok":false, "reason":"ecology_catalog_context_nonfinite_vector"}
		TYPE_VECTOR3:
			return {"ok":true, "value":value} if is_finite(value.x) \
				and is_finite(value.y) and is_finite(value.z) \
				else {"ok":false, "reason":"ecology_catalog_context_nonfinite_vector"}
		TYPE_COLOR:
			return {"ok":true, "value":value} if is_finite(value.r) \
				and is_finite(value.g) and is_finite(value.b) and is_finite(value.a) \
				else {"ok":false, "reason":"ecology_catalog_context_nonfinite_color"}
		TYPE_BASIS:
			var basis_value: Basis = value
			for axis: Vector3 in [basis_value.x, basis_value.y, basis_value.z]:
				if not is_finite(axis.x) or not is_finite(axis.y) or not is_finite(axis.z):
					return {"ok":false, "reason":"ecology_catalog_context_nonfinite_basis"}
			return {"ok":true, "value":basis_value}
		TYPE_TRANSFORM3D:
			var transform_value: Transform3D = value
			var transform_copy := _copy_owned_value(transform_value.basis, depth + 1)
			var origin_copy := _copy_owned_value(transform_value.origin, depth + 1)
			if not bool(transform_copy.get("ok", false)) or not bool(origin_copy.get("ok", false)):
				return {"ok":false, "reason":"ecology_catalog_context_nonfinite_transform"}
			return {"ok":true, "value":transform_value}
		TYPE_AABB:
			var bounds_value: AABB = value
			var position_copy := _copy_owned_value(bounds_value.position, depth + 1)
			var size_copy := _copy_owned_value(bounds_value.size, depth + 1)
			if not bool(position_copy.get("ok", false)) or not bool(size_copy.get("ok", false)):
				return {"ok":false, "reason":"ecology_catalog_context_nonfinite_bounds"}
			return {"ok":true, "value":bounds_value}
		_:
			return {"ok":false, "reason":"ecology_catalog_context_value_type_unsupported:%s" % type_string(typeof(value))}

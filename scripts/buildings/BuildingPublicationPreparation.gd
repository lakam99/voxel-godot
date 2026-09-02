extends RefCounted
class_name BuildingPublicationPreparation

## CPU-only preparation. prepare_source runs on an owned worker with immutable
## source snapshots; no Nodes, rendering resources or scene publication here.
const Source = preload("res://scripts/buildings/BuildingPublicationSource.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const METADATA_MAX_DEPTH := 128

class Continuation extends RefCounted:
	var callback: Callable
	var cancelled := false
	func advance(stage: String) -> bool:
		if cancelled: return false
		cancelled = callback.is_valid() and callback.call(stage) != true
		return not cancelled

class PreparedSource extends RefCounted:
	# Kept private until the publisher consumes this exact holder. Runtime owns
	# its lifetime and must retire stale, unconsumed payloads off the main thread.
	var _binding: Dictionary = {}
	var _payload: Dictionary = {}
	var _consumed := false
	func take(expected_binding: Dictionary) -> Dictionary:
		if _consumed or _payload.is_empty() or _binding != expected_binding: return {}
		_consumed = true
		var result := _payload
		_payload = {}
		return result

class MetadataGraph extends RefCounted:
	# Only isolated Array/Dictionary copies are frozen. Never freeze a caller's
	# recipe, trust packed-array COW, or retain Objects through typed containers.
	var guard: Continuation
	var eligible := true
	var visits := 0
	func walk(value: Variant, ancestors: Array, copy: bool, depth := 0) -> Variant:
		visits += 1
		var kind := typeof(value)
		if visits % 128 == 0 or kind == TYPE_ARRAY or kind == TYPE_DICTIONARY:
			if not guard.advance("publication_metadata_walk"): return null
		if kind <= TYPE_NODE_PATH: return value
		if kind != TYPE_ARRAY and kind != TYPE_DICTIONARY:
			eligible = false
			return null
		if depth >= METADATA_MAX_DEPTH:
			eligible = false
			return null
		for ancestor in ancestors:
			if is_same(value, ancestor):
				eligible = false
				return null
		if kind == TYPE_ARRAY:
			if not container_type_supported(value.get_typed_builtin()):
				eligible = false
				return null
		else:
			if value.get_typed_key_builtin() > TYPE_NODE_PATH or not container_type_supported(value.get_typed_value_builtin()):
				eligible = false
				return null
		ancestors.append(value)
		# A shallow duplicate preserves typed container declarations and key order;
		# every nested value is replaced before this isolated copy is frozen.
		var result: Variant = value.duplicate(false) if copy else null
		if kind == TYPE_DICTIONARY:
			for key in value:
				if typeof(key) > TYPE_NODE_PATH:
					eligible = false
					break
				var item: Variant = walk(value[key], ancestors, copy, depth + 1)
				if not eligible or guard.cancelled: break
				if copy: result[key] = item
		else:
			for index in value.size():
				var item: Variant = walk(value[index], ancestors, copy, depth + 1)
				if not eligible or guard.cancelled: break
				if copy: result[index] = item
		ancestors.pop_back()
		if not eligible or guard.cancelled: return null
		if copy: result.make_read_only()
		return result
	func container_type_supported(kind: int) -> bool:
		return kind <= TYPE_NODE_PATH or kind == TYPE_ARRAY or kind == TYPE_DICTIONARY

static func valid_binding(binding: Dictionary) -> bool:
	return binding.size() == 3 and binding.get("siteId") is String and not binding.siteId.is_empty() \
		and binding.get("sourceKey") is String and not binding.sourceKey.is_empty() \
		and binding.get("generation") is int and binding.generation > 0

static func prepare_source(building: Dictionary, furniture: Dictionary, binding: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	if not valid_binding(binding): return _failed("invalid_publication_binding")
	# Freeze identity before invoking any caller callback or expensive work.
	var source_binding := binding.duplicate()
	source_binding.make_read_only()
	var guard := Continuation.new()
	guard.callback = continuation
	var restored := Source.restore(building, furniture, guard.advance)
	if not restored.ready: return _failed(restored.reason)
	var diagnostics := evaluate(restored.blueprint, {}, guard.advance)
	if not diagnostics.ready: return _failed(diagnostics.reason)
	var metadata := _compile_static_records(restored.blueprint, guard.advance)
	if not metadata.ready: return _failed(metadata.reason)
	if not guard.advance("publication_preparation_ready"): return _failed("cancelled")
	var prepared := PreparedSource.new()
	prepared._binding = source_binding
	prepared._payload = {"blueprint":restored.blueprint, "furnishingPlan":restored.furnishingPlan,
		"raisedRouteCoverage":diagnostics.raisedRouteCoverage, "physicalIntegrity":diagnostics.physicalIntegrity,
		"preparationUsec":diagnostics.preparationUsec, "routeUsec":diagnostics.routeUsec,
		"physicalUsec":diagnostics.physicalUsec, "workerThreadId":OS.get_thread_caller_id(),
		"staticRecords":metadata.staticRecords, "staticRecordBindings":metadata.staticRecordBindings,
		"metadataPreparationUsec":metadata.metadataPreparationUsec}
	return {"ready":true, "reason":"", "prepared":prepared}

## Post-diagnostic snapshots only. Unsupported graphs are absent from BOTH maps
## so the publisher retains its ordinary unfrozen fallback. Exact bindings are
## immutable hexadecimal Strings of the typed encoding, not hashes/packed aliases.
static func _compile_static_records(blueprint, continuation: Callable = Callable()) -> Dictionary:
	var started := Time.get_ticks_usec()
	var guard := Continuation.new()
	guard.callback = continuation
	if not guard.advance("publication_metadata_started"): return _failed("cancelled")
	var records: Dictionary = {}
	var bindings: Dictionary = {}
	var seen: Dictionary = {}
	for part in blueprint.parts:
		if not guard.advance("publication_metadata_part"): return _failed("cancelled")
		if part == null or not part.collision_enabled or String(part.kind) == "door": continue
		var id := String(part.id)
		if seen.has(id): return _failed("duplicate_static_record_id")
		seen[id] = true # Includes unsupported records: never silently overwrite.
		var graph := MetadataGraph.new()
		graph.guard = guard
		# snapshot() itself deep-duplicates recipes. Reject cycles/unsupported
		# graphs BEFORE that legacy operation; do not trigger recursion errors.
		graph.walk(part.recipe, [], false)
		if guard.cancelled: return _failed("cancelled")
		if not graph.eligible: continue
		var snapshot: Dictionary = part.snapshot()
		var frozen: Variant = graph.walk(snapshot, [], true)
		if guard.cancelled: return _failed("cancelled")
		if not graph.eligible: continue
		var encoded := static_record_binding(frozen)
		if encoded.is_empty(): return _failed("static_record_encoding_failed")
		if not guard.advance("publication_metadata_record_encoded"): return _failed("cancelled")
		records[id] = frozen
		bindings[id] = encoded
	if not guard.advance("publication_metadata_completed"): return _failed("cancelled")
	records.make_read_only()
	bindings.make_read_only()
	return {"ready":true, "reason":"", "staticRecords":records, "staticRecordBindings":bindings,
		"metadataPreparationUsec":Time.get_ticks_usec()-started}

## Call only for supported, acyclic metadata. Godot 4.6.1's NodePath encoder
## advances over component alignment padding without writing it (marshalls.cpp).
## Re-encode into zeroed storage: identical Variant types/order/format and every
## represented byte, with deterministic padding instead of allocator contents.
## Consumers comparing these bindings must use this same encoding contract.
static func static_record_binding(record: Dictionary) -> String:
	var encoded := var_to_bytes(record)
	encoded.fill(0)
	if encoded.encode_var(0, record) != encoded.size(): return ""
	return encoded.hex_encode()

## Shared sequence for the legacy synchronous entry and background preparation.
## Preserve BOTH resolutions: the second changes derived classification facts.
## Empty continuation retains existing virtual validation/resolve dispatch.
static func evaluate(blueprint, options: Dictionary = {}, continuation: Callable = Callable()) -> Dictionary:
	if blueprint == null: return _failed("missing_blueprint")
	var guard := Continuation.new()
	guard.callback = continuation
	var callback := guard.advance if continuation.is_valid() else Callable()
	var started := Time.get_ticks_usec()
	if not guard.advance("publication_route_started"): return _failed("cancelled")
	var route: Dictionary = Castle.validate_raised_route_coverage(blueprint, callback)
	if bool(route.get("cancelled", false)) or not guard.advance("publication_route_completed"): return _failed("cancelled")
	var route_finished := Time.get_ticks_usec()
	var authority = options.get("structuralAuthorityBlueprint", blueprint)
	var physical: Dictionary
	if authority != null and authority.has_method("validate_physical_integrity"):
		if continuation.is_valid():
			if not authority.has_method("validate_physical_integrity_cancellable"):
				return _failed("structural_authority_not_cancellable")
			physical = authority.validate_physical_integrity_cancellable(callback)
		else:
			physical = authority.validate_physical_integrity()
	else:
		physical = {"passed":true, "checkedPartCount":0, "checks":[], "violations":[]}
	if bool(physical.get("cancelled", false)) or not guard.advance("publication_physical_completed"): return _failed("cancelled")
	var finished := Time.get_ticks_usec()
	return {"ready":true, "reason":"", "raisedRouteCoverage":route, "physicalIntegrity":physical,
		"preparationUsec":finished-started, "routeUsec":route_finished-started, "physicalUsec":finished-route_finished}

static func _failed(reason: String) -> Dictionary:
	return {"ready":false, "reason":reason}

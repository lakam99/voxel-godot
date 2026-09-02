extends RefCounted
class_name BuildingPublicationPreparation

## CPU-only preparation. prepare_source runs on an owned worker with immutable
## source snapshots; no Nodes, rendering resources or scene publication here.
const Source = preload("res://scripts/buildings/BuildingPublicationSource.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")

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
	if not guard.advance("publication_preparation_ready"): return _failed("cancelled")
	var prepared := PreparedSource.new()
	prepared._binding = source_binding
	prepared._payload = {"blueprint":restored.blueprint, "furnishingPlan":restored.furnishingPlan,
		"raisedRouteCoverage":diagnostics.raisedRouteCoverage, "physicalIntegrity":diagnostics.physicalIntegrity,
		"preparationUsec":diagnostics.preparationUsec, "routeUsec":diagnostics.routeUsec,
		"physicalUsec":diagnostics.physicalUsec, "workerThreadId":OS.get_thread_caller_id()}
	return {"ready":true, "reason":"", "prepared":prepared}

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

extends "res://scripts/buildings/BuildingPublicationWorker.gd"
class_name NavigationPublicationWorker

## Reuse the production worker's ownership, stale-token, cancellation and
## off-thread retirement protocol. Only the pure input/compiler differs.
const Descriptor = preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const Prepared = preload("res://scripts/npc_ai/navigation/PreparedNavigationDescriptor.gd")
const Filter = preload("res://scripts/npc_ai/navigation/NavigationTileFilter.gd")
const Source = preload("res://scripts/npc_ai/navigation/NavigationPublicationSource.gd")

class PreparedTile extends RefCounted:
	var _binding: Dictionary
	var _payload: Dictionary = {}
	func take(expected_binding: Dictionary) -> Dictionary:
		if expected_binding != _binding: return {}
		var result := _payload
		_payload = {}
		return result

func _source_validation_failure(source: Dictionary) -> String:
	if not source.is_read_only() or source.get("status") != "prepared" \
			or not source.get("snapshot") is Dictionary or not source.snapshot.is_read_only() \
			or not source.get("profile") is Dictionary or not source.profile.is_read_only():
		return "invalid_navigation_publication_source"
	var mode := String(source.profile.get("captureMode", "accepted"))
	if mode == "filter_input":
		if not source.get("filterInput") is Dictionary or not source.filterInput.is_read_only():
			return "invalid_navigation_filter_input"
	elif mode != "accepted" or source.has("filterInput"):
		return "invalid_navigation_capture_mode"
	return ""

func _prepare_source(source: Dictionary, binding: Dictionary, continuation: Callable, _description_callback: Callable = Callable()) -> Dictionary:
	# Production always submits filter_input. The existing explicitly captured
	# descriptor-source service API remains available to contract/direct callers.
	# A failed/malformed filter request never falls back to that API.
	var accepted: Dictionary = source
	var diagnostics := {}
	var profile := {}
	if String(source.profile.get("captureMode", "accepted")) == "filter_input":
		var filtered := Filter.new().compile(source.filterInput, source.snapshot, continuation)
		if not filtered.get("ready", false): return filtered
		var factory := Source.new()
		factory.seal_prepared_fact_list(filtered.snapshot.buildingSurfaces)
		factory.seal_prepared_fact_list(filtered.snapshot.crossingLinks)
		accepted = factory.capture(filtered.snapshot)
		diagnostics = filtered.diagnostics
		profile = filtered.profile
	if accepted.get("status") != "prepared":
		return {"ready":false, "reason":accepted.get("reason", "invalid_filtered_navigation_source")}
	if continuation.is_valid() and not continuation.call("navigation_filtered_source_sealed"):
		return {"ready":false, "reason":"navigation_preparation_cancelled_or_invalid"}
	var descriptor = Descriptor.from_tile_snapshot(accepted.snapshot)
	var prepared := Prepared.new()
	if not prepared.prepare_from(descriptor,continuation):
		return {"ready":false,"reason":"navigation_preparation_cancelled_or_invalid"}
	if not Prepared._freeze(diagnostics,continuation) or not Prepared._freeze(profile,continuation):
		return {"ready":false,"reason":"navigation_preparation_cancelled_or_invalid"}
	var holder := PreparedTile.new()
	holder._binding = binding
	# The very same accepted facts produce geometry and later receipt obligations.
	# Keep all aliases in the one-shot payload so cancellation retires them together.
	holder._payload = {"descriptor":prepared, "acceptedSource":accepted,
		"diagnostics":diagnostics, "filterProfile":profile, "captureProfile":source.profile}
	return {"ready":true,"prepared":holder,"binding":binding}

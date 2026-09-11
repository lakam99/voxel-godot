extends "res://scripts/buildings/BuildingPublicationWorker.gd"
class_name NavigationPublicationWorker

## Reuse the production worker's ownership, stale-token, cancellation and
## off-thread retirement protocol. Only the pure input/compiler differs.
const Descriptor = preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const Prepared = preload("res://scripts/npc_ai/navigation/PreparedNavigationDescriptor.gd")

class PreparedTile extends RefCounted:
	var _binding: Dictionary
	var _descriptor
	func take(expected_binding: Dictionary):
		if expected_binding != _binding: return null
		var result = _descriptor
		_descriptor = null
		return result

func _source_validation_failure(source: Dictionary) -> String:
	if not source.is_read_only() or source.get("status") != "prepared" \
			or not source.get("snapshot") is Dictionary or not source.snapshot.is_read_only() \
			or not source.get("profile") is Dictionary or not source.profile.is_read_only():
		return "invalid_navigation_publication_source"
	return ""

func _prepare_source(source: Dictionary, binding: Dictionary, continuation: Callable) -> Dictionary:
	var descriptor = Descriptor.from_tile_snapshot(source.snapshot)
	var prepared := Prepared.new()
	if not prepared.prepare_from(descriptor,continuation):
		return {"ready":false,"reason":"navigation_preparation_cancelled_or_invalid"}
	var holder := PreparedTile.new()
	holder._binding = binding
	holder._descriptor = prepared
	return {"ready":true,"prepared":holder,"binding":binding}

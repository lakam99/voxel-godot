extends RefCounted
class_name BuildingNavigationTilePreparation

## Full/offline callers drain the same demanded producer used by publication.
## There is one sampler, clipping, occupancy and declared-crossing authority.
const Producer = preload("res://scripts/buildings/BuildingNavigationTileProducer.gd")

static func compile(manifest: Dictionary, furniture: Dictionary, continuation: Callable, solids: Array = []) -> Dictionary:
	var producer := Producer.new()
	var initialized := producer.begin(manifest,furniture,continuation,solids)
	if initialized.status != "ready": return {}
	producer.request_all()
	var state := producer.advance(0,continuation)
	if state.status == "cancelled": return {}
	return producer.full_result()

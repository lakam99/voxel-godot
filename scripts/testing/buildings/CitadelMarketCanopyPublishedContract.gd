extends "res://scripts/testing/buildings/CitadelMarketPublishedOverlapContract.gd"

const CanopyRecipe = preload("res://scripts/buildings/MarketCanopyFrameBuilder.gd")
const StorageRecipe = preload("res://scripts/buildings/MarketStoragePlacementRecipe.gd")

func _prepare_households(blueprint, households: Array) -> Dictionary:
	var layouts: Array = []
	var changed: Array = []
	for household in households:
		var layout: Dictionary = StorageRecipe.place(blueprint, household.memberIds, household.front)
		layouts.append(layout)
		if not layout.ready:
			return {"ready": false, "layouts": layouts}
		changed.append_array(layout.changes.map(func(change): return String(change.partId)))
	return {"ready": true, "layouts": layouts, "changedPartIds": changed}

func _augment_candidate(blueprint, plans: Array) -> Dictionary:
	var result := {"ready": false, "partIds": [], "frames": [],
		"doesNotProve": "All new frame/contents pairs are measured, but joint contacts still need adjudication; no triangle/GPU, access or gameplay acceptance."}
	var builder: Script = CanopyRecipe
	if not builder.has_method("add_frame_on_grounded_support"):
		result["reason"] = "missing_shared_grounded_recipe"
		return result
	for plan in plans:
		var frame: Dictionary = builder.call("add_frame_on_grounded_support", blueprint, plan.memberIds, plan.supportId)
		result.frames.append(frame)
		if not frame.get("ready", false):
			result["reason"] = "frame_recipe_failed"
			return result
		result.partIds.append_array(frame.partIds)
	result["ready"] = true
	return result

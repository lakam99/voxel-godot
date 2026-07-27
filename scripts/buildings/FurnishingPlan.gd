extends RefCounted
class_name FurnishingPlan

const FurnishingPartScript := preload("res://scripts/buildings/FurnishingPart.gd")

var id := ""
var seed := 0
var source_blueprint_id := ""
var parts: Array = []


func _init(plan_id := "", plan_seed := 0, blueprint_id := "") -> void:
	id = plan_id
	seed = plan_seed
	source_blueprint_id = blueprint_id


func add_part(values: Dictionary):
	var part = FurnishingPartScript.new(values)
	parts.append(part)
	return part


func snapshot() -> Dictionary:
	var snapshots: Array = []
	for part in parts:
		if part != null and part.has_method("snapshot"):
			snapshots.append(part.snapshot())
	return {
		"id": id,
		"seed": seed,
		"sourceBlueprintId": source_blueprint_id,
		"parts": snapshots
	}


func deterministic_signature() -> String:
	return JSON.stringify(snapshot())

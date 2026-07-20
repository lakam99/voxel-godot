extends RefCounted
class_name MotionInstance

const MotionPrimitiveScript := preload("res://scripts/combat/motion/MotionPrimitive.gd")

## A reusable motion recipe bound to an abstract local anchor. The anchor is
## just data here; a future visual or gameplay adapter may decide what it means.

var instance_id := ""
var recipe
var anchor_id := ""
var anchor_offset := Vector3.ZERO
var direction := 1.0
var start_offset := 0.0
var time_scale := 1.0


func _init(values: Dictionary = {}) -> void:
	instance_id = String(values.get("instanceId", "motion"))
	recipe = values.get("recipe", null)
	anchor_id = String(values.get("anchorId", "anchor"))
	anchor_offset = values.get("anchorOffset", Vector3.ZERO) as Vector3
	direction = -1.0 if float(values.get("direction", 1.0)) < 0.0 else 1.0
	start_offset = clampf(float(values.get("startOffset", 0.0)), 0.0, 0.95)
	time_scale = clampf(float(values.get("timeScale", 1.0)), 0.05, 4.0)


func sample(global_time: float):
	var local_time := (global_time - start_offset) / time_scale
	if local_time < 0.0 or local_time > 1.0:
		return MotionPrimitiveScript.sample(null, local_time, direction, anchor_offset, instance_id, anchor_id)
	var result = MotionPrimitiveScript.sample(recipe, local_time, direction, anchor_offset, instance_id, anchor_id)
	result.normalized_time = global_time
	return result


func trail_until(global_time: float, sample_count: int) -> Array:
	var result: Array = []
	var local_limit := clampf((global_time - start_offset) / time_scale, 0.0, 1.0)
	if global_time < start_offset:
		return result
	var count := maxi(2, sample_count)
	for index in range(count):
		var local_time := local_limit * float(index) / float(count - 1)
		var sample = MotionPrimitiveScript.sample(recipe, local_time, direction, anchor_offset, instance_id, anchor_id)
		sample.normalized_time = start_offset + local_time * time_scale
		result.append(sample)
	return result


func snapshot() -> Dictionary:
	return {
		"instanceId": instance_id,
		"anchorId": anchor_id,
		"anchorOffset": anchor_offset,
		"direction": direction,
		"startOffset": start_offset,
		"timeScale": time_scale,
		"recipe": recipe.snapshot() if recipe != null and recipe.has_method("snapshot") else {}
	}

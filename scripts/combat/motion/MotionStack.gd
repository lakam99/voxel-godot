extends RefCounted
class_name MotionStack

## Composition only. A stack does not merge motions into a named combination;
## it retains every instance as an independently inspectable contribution.

var stack_id := ""
var instances: Array = []


func _init(next_stack_id := "motion_stack", next_instances: Array = []) -> void:
	stack_id = next_stack_id
	instances = next_instances.duplicate()


func samples_at(global_time: float) -> Array:
	var result: Array = []
	for instance in instances:
		if instance == null or not instance.has_method("sample"):
			continue
		var sample = instance.sample(global_time)
		if sample != null and sample.active:
			result.append(sample)
	return result


func trails_until(global_time: float, sample_count: int) -> Array:
	var result: Array = []
	for instance in instances:
		if instance == null or not instance.has_method("trail_until"):
			continue
		result.append({
			"instanceId": instance.instance_id,
			"samples": instance.trail_until(global_time, sample_count)
		})
	return result


func snapshot() -> Dictionary:
	var entries: Array = []
	for instance in instances:
		if instance != null and instance.has_method("snapshot"):
			entries.append(instance.snapshot())
	return {"stackId": stack_id, "instances": entries}

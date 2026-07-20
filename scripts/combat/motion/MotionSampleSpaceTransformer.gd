extends RefCounted
class_name MotionSampleSpaceTransformer

const MotionSampleScript := preload("res://scripts/combat/motion/MotionSample.gd")

## Pure coordinate bridge between an abstract motion anchor and a caller-owned
## world frame. Recipes and primitive sampling remain entirely local; only a
## runtime or presentation adapter decides where that local frame lives.

static func transform_sample(sample, space: Transform3D):
	if sample == null:
		return MotionSampleScript.new()
	return MotionSampleScript.new({
		"instanceId": sample.instance_id,
		"anchorId": sample.anchor_id,
		"normalizedTime": sample.normalized_time,
		"localTime": sample.local_time,
		"phase": sample.phase,
		"active": sample.active,
		"origin": space * sample.origin,
		"tip": space * sample.tip,
		"facing": transform_direction(sample.facing, space.basis)
	})


static func transform_trails(trails: Array, space: Transform3D) -> Array:
	var result: Array = []
	for trail in trails:
		if not (trail is Dictionary):
			continue
		var samples: Array = []
		for sample in trail.get("samples", []):
			samples.append(transform_sample(sample, space))
		result.append({
			"instanceId": String(trail.get("instanceId", "")),
			"samples": samples
		})
	return result


static func transform_direction(direction: Vector3, basis: Basis) -> Vector3:
	var transformed := basis * direction
	return transformed.normalized() if transformed.length_squared() > 0.0000001 else Vector3.FORWARD

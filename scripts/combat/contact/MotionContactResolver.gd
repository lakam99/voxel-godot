extends RefCounted
class_name MotionContactResolver

const MotionContactResolutionScript := preload("res://scripts/combat/contact/MotionContactResolution.gd")
const MotionVolumeSamplerScript := preload("res://scripts/combat/contact/MotionVolumeSampler.gd")

## Pure resolution math over the existing capsule and swept-sheet samples.
## The resolver receives passive geometry and returns facts; it neither queries
## the engine nor applies a consequence to anything in the world.

static func resolve_volume(volume_sample, passive_geometry) -> MotionContactResolution:
	if volume_sample == null or passive_geometry == null or not volume_sample.active:
		return MotionContactResolutionScript.new()
	var closest := closest_point_on_segment(passive_geometry.center, volume_sample.segment_start, volume_sample.segment_end)
	return resolution_from_closest_point(
		passive_geometry,
		volume_sample.instance_id,
		volume_sample.normalized_time,
		volume_sample.phase,
		"capsule_segment",
		closest,
		float(volume_sample.radius),
		volume_sample.facing
	)


static func resolve_sweep(sweep_sample, passive_geometry, phase := "arc") -> MotionContactResolution:
	if sweep_sample == null or passive_geometry == null or not sweep_sample.active:
		return MotionContactResolutionScript.new()
	var first := closest_point_on_triangle(
		passive_geometry.center,
		sweep_sample.from_segment_start,
		sweep_sample.from_segment_end,
		sweep_sample.to_segment_end
	)
	var second := closest_point_on_triangle(
		passive_geometry.center,
		sweep_sample.from_segment_start,
		sweep_sample.to_segment_end,
		sweep_sample.to_segment_start
	)
	var closest := first if first.distance_squared_to(passive_geometry.center) <= second.distance_squared_to(passive_geometry.center) else second
	return resolution_from_closest_point(
		passive_geometry,
		sweep_sample.instance_id,
		sweep_sample.normalized_time,
		phase,
		"sweep_sheet",
		closest,
		float(sweep_sample.radius),
		Vector3.FORWARD
	)


## Emits an entry fact only when a geometry first enters a motion's current
## sample/sweep. A caller can evaluate it every frame without duplicating a
## persistent overlap; a separated later entry remains a new fact.
static func resolve_transition(previous_volume, current_volume, passive_geometry) -> MotionContactResolution:
	if current_volume == null or not current_volume.active:
		return MotionContactResolutionScript.new()
	var previous_resolution := resolve_volume(previous_volume, passive_geometry)
	if previous_resolution.resolved:
		return MotionContactResolutionScript.new()
	var current_resolution := resolve_volume(current_volume, passive_geometry)
	if current_resolution.resolved:
		return current_resolution
	var sweep := MotionVolumeSamplerScript.sweep(previous_volume, current_volume)
	return resolve_sweep(sweep, passive_geometry, String(current_volume.phase))


## Evaluates a bounded normalized-time window and keeps one resolution fact per
## independent motion/geometry pair. This is deterministic idempotence for the
## isolated PoC, without a mutable global combat state.
static func resolve_window(stack, volume_recipe, passive_geometries: Array, start_time: float, end_time: float, sample_count := 16) -> Array:
	var results: Array = []
	if stack == null or volume_recipe == null or end_time < start_time:
		return results
	var seen: Dictionary = {}
	var previous_by_instance: Dictionary = {}
	var count := maxi(2, sample_count)
	for index in range(count):
		var ratio := float(index) / float(count - 1)
		var time := lerpf(start_time, end_time, ratio)
		var current_samples: Array = MotionVolumeSamplerScript.samples_for_stack(stack, volume_recipe, time)
		for current_volume in current_samples:
			var previous_volume = previous_by_instance.get(current_volume.instance_id, null)
			for passive_geometry in passive_geometries:
				var resolution = resolve_transition(previous_volume, current_volume, passive_geometry)
				if resolution.resolved and not seen.has(resolution.event_key()):
					seen[resolution.event_key()] = true
					results.append(resolution)
			previous_by_instance[current_volume.instance_id] = current_volume
	return results


static func resolution_from_closest_point(passive_geometry, instance_id: String, normalized_time: float, phase: String, source_id: String, closest: Vector3, source_radius: float, fallback_facing: Vector3) -> MotionContactResolution:
	var total_radius: float = maxf(0.0, source_radius) + maxf(0.0, float(passive_geometry.radius))
	var delta: Vector3 = closest - (passive_geometry.center as Vector3)
	var distance: float = delta.length()
	if distance > total_radius:
		return MotionContactResolutionScript.new()
	var normal: Vector3 = delta / distance if distance > 0.0001 else safe_normal(-fallback_facing)
	var point: Vector3 = (passive_geometry.center as Vector3) + normal * float(passive_geometry.radius)
	return MotionContactResolutionScript.new({
		"resolved": true,
		"geometryId": passive_geometry.geometry_id,
		"instanceId": instance_id,
		"normalizedTime": normalized_time,
		"phase": phase,
		"sourceId": source_id,
		"contactPoint": point,
		"contactNormal": normal,
		"overlapDepth": total_radius - distance
	})


static func closest_point_on_segment(point: Vector3, start: Vector3, finish: Vector3) -> Vector3:
	var axis := finish - start
	var length_squared := axis.length_squared()
	if length_squared <= 0.0000001:
		return start
	return start + axis * clampf((point - start).dot(axis) / length_squared, 0.0, 1.0)


static func closest_point_on_triangle(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	if ab.cross(ac).length_squared() <= 0.0000001:
		return closest_point_on_degenerate_triangle(point, a, b, c)
	var ap := point - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := point - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := point - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		var edge := c - b
		return b + edge * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denominator := 1.0 / (va + vb + vc)
	return a + ab * (vb * denominator) + ac * (vc * denominator)


static func closest_point_on_degenerate_triangle(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var first := closest_point_on_segment(point, a, b)
	var second := closest_point_on_segment(point, b, c)
	var third := closest_point_on_segment(point, c, a)
	var closest := first
	if second.distance_squared_to(point) < closest.distance_squared_to(point):
		closest = second
	if third.distance_squared_to(point) < closest.distance_squared_to(point):
		closest = third
	return closest


static func safe_normal(candidate: Vector3) -> Vector3:
	return candidate.normalized() if candidate.length_squared() > 0.0000001 else Vector3.UP

extends RefCounted
class_name HostileLocomotionDriver

## Shared CharacterBody3D executor for hostile behavior intents. It performs
## no path search, no direct transform placement, and no combat decisions.

static func step(body: CharacterBody3D, target: Node3D, intent, profile, delta: float, bounds: Dictionary = {}) -> Dictionary:
	var result := {
		"requestedDirection": Vector3.ZERO,
		"appliedVelocity": Vector3.ZERO,
		"displacement": Vector3.ZERO,
		"blocked": false,
		"collisionCount": 0,
		"heading": Vector3.ZERO,
		"distance": INF
	}
	if body == null or target == null or profile == null or intent == null or not is_instance_valid(body) or not is_instance_valid(target) or delta <= 0.0:
		return result
	var previous := body.global_position
	var to_target := target.global_position - previous
	to_target.y = 0.0
	var distance := to_target.length()
	var radial := to_target.normalized() if distance > 0.0001 else Vector3.FORWARD
	var requested := requested_direction(body, target, intent, profile, radial, distance, bounds)
	var speed := maxf(0.0, float(intent.speed))
	if requested.length_squared() > 0.0001 and speed > 0.0:
		requested = requested.normalized()
		body.velocity.x = requested.x * speed
		body.velocity.z = requested.z * speed
	else:
		body.velocity.x = move_toward(body.velocity.x, 0.0, maxf(1.0, profile.orbit_speed * 7.0) * delta)
		body.velocity.z = move_toward(body.velocity.z, 0.0, maxf(1.0, profile.orbit_speed * 7.0) * delta)
	body.velocity.y = -0.25
	body.move_and_slide()
	var displacement := body.global_position - previous
	var applied_planar_velocity := Vector3(displacement.x / delta, 0.0, displacement.z / delta)
	var travel_heading := applied_planar_velocity.normalized() if applied_planar_velocity.length_squared() > 0.0001 else requested
	if travel_heading.length_squared() <= 0.0001:
		travel_heading = radial
	# A profile declares body and gaze independently. This avoids anatomy-family
	# branches: a quadruped can face and look along real travel, while a biped can
	# keep a target-tracking head over movement-facing locomotion. Use measured
	# displacement after slide resolution so a constrained body never presents as
	# travelling sideways relative to its legs.
	var facing := radial if String(profile.facing_mode) == "target" else travel_heading
	if facing.length_squared() > 0.0001:
		body.rotation.y = atan2(-facing.x, -facing.z)
	var rig_driver := body.get_node_or_null("MotionRigPoseDriver")
	if rig_driver != null and rig_driver.has_method("apply_locomotion_velocity"):
		rig_driver.apply_locomotion_velocity(applied_planar_velocity, delta)
	if String(profile.gaze_mode) == "movement" and rig_driver != null and rig_driver.has_method("apply_gaze_direction"):
		rig_driver.apply_gaze_direction(travel_heading, delta)
	elif rig_driver != null and rig_driver.has_method("apply_gaze_target"):
		rig_driver.apply_gaze_target(target.global_position, delta)
	result["requestedDirection"] = requested
	result["appliedVelocity"] = Vector3(applied_planar_velocity.x, displacement.y / delta, applied_planar_velocity.z)
	result["displacement"] = displacement
	result["collisionCount"] = body.get_slide_collision_count()
	result["blocked"] = requested.length_squared() > 0.0001 and Vector2(displacement.x, displacement.z).length() <= 0.001
	result["heading"] = travel_heading
	result["distance"] = distance
	return result


static func requested_direction(body: CharacterBody3D, target: Node3D, intent, profile, radial: Vector3, distance: float, bounds: Dictionary) -> Vector3:
	var kind := String(intent.kind)
	var requested := Vector3.ZERO
	match kind:
		"approach", "lunge":
			requested = radial
		"retreat":
			requested = -radial
		"orbit":
			var tangent := radial.rotated(Vector3.UP, float(intent.orbit_direction) * PI * 0.5)
			var band_half_width := maxf(0.2, (profile.engagement_outer_distance - profile.engagement_inner_distance) * 0.5)
			var radial_error := clampf((distance - profile.preferred_distance) / band_half_width, -1.0, 1.0)
			requested = (tangent + radial * radial_error * 0.78).normalized()
		"evade":
			requested = intent.direction if intent.direction.length_squared() > 0.0001 else radial.rotated(Vector3.UP, float(intent.orbit_direction) * PI * 0.5)
		_:
			requested = Vector3.ZERO
	return steer_inside_bounds(body.global_position, requested, bounds)


static func steer_inside_bounds(position: Vector3, requested: Vector3, bounds: Dictionary) -> Vector3:
	var half_extent := maxf(0.0, float(bounds.get("halfExtent", 0.0)))
	if half_extent <= 0.0 or requested.length_squared() <= 0.0001:
		return requested
	var center: Vector3 = bounds.get("center", Vector3.ZERO) as Vector3
	var local := position - center
	local.y = 0.0
	var inward := -local.normalized() if local.length_squared() > 0.0001 else Vector3.ZERO
	var edge := maxf(absf(local.x), absf(local.z))
	if edge < half_extent - 1.1 or inward.length_squared() <= 0.0001:
		return requested
	if requested.dot(inward) > 0.18:
		return requested
	return (requested + inward * clampf((edge - (half_extent - 1.1)) * 1.8, 0.8, 2.0)).normalized()

extends RefCounted
class_name CollisionProbeService

const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const MAX_ROUTE_PROBE_SAMPLES := 256
const MAX_SAMPLE_SPACING := 0.42
const DEFAULT_GROUND_OFFSET := 0.04
const START_OVERLAP_ESCAPE_EPSILON := 0.02
const START_OVERLAP_ESCAPE_MIN_DOT := 0.25
const DUPLICATE_WAYPOINT_EPSILON := 0.02
const TERRAIN_MOTION_MAX_COLLISIONS := 8
const TERRAIN_MOTION_MARGIN := 0.001

var system = null
var main = null

func setup(system_node, main_node) -> void:
	system = system_node
	main = main_node

func probe_route(entry: Dictionary, route: Dictionary, intent: Dictionary, options := {}) -> Dictionary:
	var body := entry.get("body") as CharacterBody3D
	if body == null:
		return _certificate(true, "skipped", "missing_body", false, 0, {})
	if body.get_world_3d() == null:
		return _certificate(true, "skipped", "missing_world_3d", false, 0, {})
	entry.erase("lastStartOverlapEscapeProbe")
	var waypoints: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
	if waypoints.is_empty():
		return _certificate(true, "skipped", "empty_waypoints", false, 0, {})
	var profile = entry.get("motorProfile")
	if profile == null:
		profile = CharacterMotorProfileScript.npc_default()
	var shape := CapsuleShape3D.new()
	shape.radius = float(profile.get("capsule_radius"))
	shape.height = float(profile.get("capsule_height"))
	var points: Array[Vector3] = [body.global_position]
	for waypoint in waypoints:
		if waypoint is Vector3:
			var point: Vector3 = waypoint
			if _flat_points_close(points[points.size() - 1], point):
				continue
			points.append(point)
	if points.size() < 2:
		return _certificate(true, "passed", "", true, 0, {
			"pointCount": points.size(),
			"singlePointRoute": true,
			"radius": shape.radius,
			"height": shape.height,
			"staticCollisionMask": route_blocking_collision_mask(),
			"terrainMotionMask": terrain_motion_collision_mask(body),
			"completedSamples": 0
		})
	var start_overlap_escape_colliders := _current_overlap_escape_colliders(entry, body, shape, route)
	var cursor: Dictionary = options.get("cursor", {}) if options.get("cursor", {}) is Dictionary else {}
	var terrain_motion_from := _probe_resume_grounded_sample(body.global_position, cursor)
	var sample_count := 0
	var max_samples := int(options.get("maxSamples", MAX_ROUTE_PROBE_SAMPLES))
	var start_segment := maxi(0, int(cursor.get("segmentIndex", 0)))
	var start_sample := maxi(1, int(cursor.get("sampleIndex", 1)))
	var completed_before := maxi(0, int(cursor.get("completedSamples", 0)))
	for index in range(points.size() - 1):
		var from_point: Vector3 = points[index]
		var to_point: Vector3 = points[index + 1]
		var flat_distance := Vector2(to_point.x - from_point.x, to_point.z - from_point.z).length()
		var segment_samples := clampi(ceili(flat_distance / MAX_SAMPLE_SPACING), 1, 64)
		for sample_index in range(1, segment_samples + 1):
			if index < start_segment or (index == start_segment and sample_index < start_sample):
				continue
			if sample_count >= max_samples:
				return _certificate(false, "pending_probe", "collision_probe_budget", true, sample_count, {
					"segmentIndex": index,
					"sampleIndex": sample_index,
					"maxSamples": max_samples,
					"completedSamples": completed_before + sample_count,
					"cursor": {
						"segmentIndex": index,
						"sampleIndex": sample_index,
						"completedSamples": completed_before + sample_count,
						"previousGroundedSample": terrain_motion_from
					}
				})
			sample_count += 1
			var sample: Vector3 = from_point.lerp(to_point, float(sample_index) / float(segment_samples))
			sample = _grounded_sample(sample)
			var blocker := _blocking_overlap(entry, body, shape, sample, route, start_overlap_escape_colliders)
			if not blocker.is_empty():
				blocker["segmentIndex"] = index
				blocker["sampleIndex"] = sample_index
				blocker["sampleCount"] = sample_count
				blocker["completedSamples"] = completed_before + sample_count
				blocker["sample"] = sample
				return _certificate(false, "blocked", "blocked_capsule_probe", true, sample_count, blocker)
			var terrain_blocker := _terrain_motion_blocker(body, terrain_motion_from, sample)
			if not terrain_blocker.is_empty():
				terrain_blocker["segmentIndex"] = index
				terrain_blocker["sampleIndex"] = sample_index
				terrain_blocker["sampleCount"] = sample_count
				terrain_blocker["completedSamples"] = completed_before + sample_count
				terrain_blocker["sample"] = sample
				return _certificate(false, "blocked", "blocked_terrain_motion_probe", true, sample_count, terrain_blocker)
			terrain_motion_from = sample
	return _certificate(true, "passed", "", true, sample_count, {
		"pointCount": points.size(),
		"radius": shape.radius,
		"height": shape.height,
		"staticCollisionMask": route_blocking_collision_mask(),
		"terrainMotionMask": terrain_motion_collision_mask(body),
		"completedSamples": completed_before + sample_count
	})

func _probe_resume_grounded_sample(body_position: Vector3, cursor: Dictionary) -> Vector3:
	var previous = cursor.get("previousGroundedSample", null)
	if previous is Vector3:
		return previous
	return _grounded_sample(body_position)

func _flat_points_close(a: Vector3, b: Vector3) -> bool:
	return Vector2(a.x - b.x, a.z - b.z).length() <= DUPLICATE_WAYPOINT_EPSILON

func route_blocking_collision_mask() -> int:
	return NpcConstantsScript.COLLISION_NPC_STATIC_QUERY_MASK

func terrain_motion_collision_mask(body: CharacterBody3D) -> int:
	if body == null:
		return 0
	return int(body.collision_mask) & NpcConstantsScript.COLLISION_NPC_TERRAIN_MOTION_MASK

func _grounded_sample(sample: Vector3) -> Vector3:
	var result := sample
	if main != null and main.has_method("surface_y_at_position"):
		result.y = float(main.call("surface_y_at_position", sample)) + DEFAULT_GROUND_OFFSET
	return result

func _current_overlap_escape_colliders(entry: Dictionary, body: CharacterBody3D, shape: CapsuleShape3D, route: Dictionary) -> Dictionary:
	var result := {}
	if body == null or body.get_world_3d() == null:
		return result
	var current_sample := _grounded_sample(body.global_position)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), current_sample + Vector3(0.0, shape.height * 0.5, 0.0))
	query.collision_mask = route_blocking_collision_mask()
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [body.get_rid()]
	var hits: Array = body.get_world_3d().direct_space_state.intersect_shape(query, 16)
	for hit in hits:
		var hit_dict: Dictionary = hit
		var collider := hit_dict.get("collider") as Node
		if collider == null or collider == body:
			continue
		if _collider_allowed_for_route(entry, collider, route):
			continue
		if not _collider_type_supports_start_overlap_escape(collider):
			continue
		result[collider.get_instance_id()] = {
			"collider": collider.name,
			"kind": String(collider.get_meta("kind", "")),
			"blockType": String(collider.get_meta("block_type", "")),
			"currentSample": current_sample,
			"currentDistance": _flat_distance_to_collider(collider, current_sample)
		}
	return result

func _blocking_overlap(entry: Dictionary, body: CharacterBody3D, shape: CapsuleShape3D, sample: Vector3, route: Dictionary, start_overlap_escape_colliders := {}) -> Dictionary:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), sample + Vector3(0.0, shape.height * 0.5, 0.0))
	query.collision_mask = route_blocking_collision_mask()
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [body.get_rid()]
	var hits: Array = body.get_world_3d().direct_space_state.intersect_shape(query, 16)
	for hit in hits:
		var hit_dict: Dictionary = hit
		var collider := hit_dict.get("collider") as Node
		if collider == null or collider == body:
			continue
		if _collider_allowed_for_route(entry, collider, route):
			continue
		var escape_context := _start_overlap_escape_context(collider, sample, start_overlap_escape_colliders)
		if bool(escape_context.get("allowed", false)):
			entry["lastStartOverlapEscapeProbe"] = escape_context
			continue
		var collider_body := collider as Node3D
		var collider_position := collider_body.global_position if collider_body != null else Vector3.ZERO
		var blocker := {
			"collider": collider.name,
			"class": collider.get_class(),
			"kind": String(collider.get_meta("kind", "")),
			"blockType": String(collider.get_meta("block_type", "")),
			"position": collider_position,
			"cell": Vector2i(roundi(collider_position.x / NpcConstantsScript.CELL_SIZE), roundi(collider_position.z / NpcConstantsScript.CELL_SIZE))
		}
		if not escape_context.is_empty():
			blocker["startOverlapEscape"] = escape_context
		return blocker
	return {}

func _terrain_motion_blocker(body: CharacterBody3D, from_point: Vector3, to_point: Vector3) -> Dictionary:
	if terrain_motion_collision_mask(body) == 0:
		return {
			"probe": "body_test_motion",
			"reason": "terrain_collision_mask_missing",
			"bodyCollisionMask": int(body.collision_mask),
			"terrainMotionMask": terrain_motion_collision_mask(body)
		}
	var motion := Vector3(to_point.x - from_point.x, 0.0, to_point.z - from_point.z)
	if motion.length_squared() <= 0.000001:
		return {}
	var parameters := PhysicsTestMotionParameters3D.new()
	var from_transform := body.global_transform
	from_transform.origin = from_point
	parameters.from = from_transform
	parameters.motion = motion
	parameters.margin = TERRAIN_MOTION_MARGIN
	parameters.max_collisions = TERRAIN_MOTION_MAX_COLLISIONS
	parameters.recovery_as_collision = false
	parameters.exclude_bodies = [body.get_rid()]
	var result := PhysicsTestMotionResult3D.new()
	var would_collide := PhysicsServer3D.body_test_motion(body.get_rid(), parameters, result)
	if not would_collide:
		return {}
	var collision_count := result.get_collision_count()
	for collision_index in range(collision_count):
		var collider = result.get_collider(collision_index)
		if not (collider is Node):
			continue
		var collider_node := collider as Node
		if not _is_terrain_collider(collider_node):
			continue
		var collision_normal: Vector3 = result.get_collision_normal(collision_index)
		if not _terrain_contact_blocks_motion(body, collision_normal):
			continue
		var collider_body := collider_node as Node3D
		var collider_position := collider_body.global_position if collider_body != null else Vector3.ZERO
		return {
			"probe": "body_test_motion",
			"collider": collider_node.name,
			"class": collider_node.get_class(),
			"kind": String(collider_node.get_meta("kind", "")),
			"position": collider_position,
			"motionFrom": from_point,
			"motion": motion,
			"collisionNormal": collision_normal,
			"collisionPoint": result.get_collision_point(collision_index),
			"safeFraction": result.get_collision_safe_fraction(),
			"unsafeFraction": result.get_collision_unsafe_fraction(),
			"bodyCollisionMask": int(body.collision_mask),
			"terrainMotionMask": terrain_motion_collision_mask(body),
			"collisionCount": collision_count
		}
	return {}

func _terrain_contact_blocks_motion(body: CharacterBody3D, collision_normal: Vector3) -> bool:
	if collision_normal.length_squared() <= 0.000001:
		return true
	var floor_normal_y := cos(body.floor_max_angle)
	return collision_normal.normalized().y < floor_normal_y

func _is_terrain_collider(collider: Node) -> bool:
	if collider == null:
		return false
	if String(collider.get_meta("kind", "")) == "terrain":
		return true
	var collision_object := collider as CollisionObject3D
	return collision_object != null and (int(collision_object.collision_layer) & NpcConstantsScript.COLLISION_NPC_TERRAIN_MOTION_MASK) != 0

func _collider_allowed_for_route(_entry: Dictionary, collider: Node, route: Dictionary) -> bool:
	var kind := String(collider.get_meta("kind", ""))
	var block_type := String(collider.get_meta("block_type", ""))
	if kind == "block" and block_type in ["cobblestonePath", "torch"]:
		return true
	if block_type == "door" and _route_has_matching_door_action(collider, route):
		return true
	return false

func _collider_type_supports_start_overlap_escape(collider: Node) -> bool:
	if collider == null:
		return false
	var kind := String(collider.get_meta("kind", ""))
	if kind == "block":
		var block_type := String(collider.get_meta("block_type", ""))
		return not (block_type in ["door", "cobblestonePath", "torch"])
	return kind == "prop"

func _start_overlap_escape_context(collider: Node, sample: Vector3, start_overlap_escape_colliders: Dictionary) -> Dictionary:
	if collider == null or start_overlap_escape_colliders.is_empty():
		return {}
	var instance_id := collider.get_instance_id()
	if not start_overlap_escape_colliders.has(instance_id):
		return {}
	var context: Dictionary = start_overlap_escape_colliders.get(instance_id, {}).duplicate(true)
	var current_sample: Vector3 = context.get("currentSample", sample)
	var current_distance := float(context.get("currentDistance", _flat_distance_to_collider(collider, current_sample)))
	var sample_distance := _flat_distance_to_collider(collider, sample)
	context["sample"] = sample
	context["sampleDistance"] = sample_distance
	context["allowed"] = _sample_moves_away_from_collider(collider, current_sample, sample, current_distance, sample_distance)
	return context

func _sample_moves_away_from_collider(collider: Node, current_sample: Vector3, sample: Vector3, current_distance := -1.0, sample_distance := -1.0) -> bool:
	if collider == null:
		return false
	var collider_body := collider as Node3D
	if collider_body == null:
		return false
	if current_distance < 0.0:
		current_distance = _flat_distance_to_collider(collider, current_sample)
	if sample_distance < 0.0:
		sample_distance = _flat_distance_to_collider(collider, sample)
	if sample_distance <= current_distance + START_OVERLAP_ESCAPE_EPSILON:
		return false
	var away := Vector2(current_sample.x - collider_body.global_position.x, current_sample.z - collider_body.global_position.z)
	var movement := Vector2(sample.x - current_sample.x, sample.z - current_sample.z)
	if movement.length_squared() <= 0.000001:
		return false
	if away.length_squared() <= 0.000001:
		return true
	return away.normalized().dot(movement.normalized()) >= START_OVERLAP_ESCAPE_MIN_DOT

func _flat_distance_to_collider(collider: Node, position: Vector3) -> float:
	var collider_body := collider as Node3D
	if collider_body == null:
		return INF
	return Vector2(position.x - collider_body.global_position.x, position.z - collider_body.global_position.z).length()

func _route_has_matching_door_action(collider: Node, route: Dictionary) -> bool:
	var actions: Dictionary = route.get("actions", {}) if route.get("actions", {}) is Dictionary else {}
	if actions.is_empty():
		return false
	var collider_portal := String(collider.get_meta("door_portal_id", collider.get_meta("door_group_id", "")))
	for action_value in actions.values():
		if not (action_value is Dictionary):
			continue
		var action: Dictionary = action_value
		var action_portal := String(action.get("portalId", action.get("portal_id", "")))
		if action_portal != "" and collider_portal != "" and action_portal == collider_portal:
			return true
	if collider_portal == "":
		return true
	return false

func _certificate(ok: bool, status: String, reason: String, authoritative: bool, sample_count: int, details: Dictionary) -> Dictionary:
	return {
		"ok": ok,
		"status": status,
		"reason": reason,
		"authoritative": authoritative,
		"sampleCount": sample_count,
		"details": details.duplicate(true)
	}

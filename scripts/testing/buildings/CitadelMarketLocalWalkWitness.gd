extends RefCounted

## Local PoC witness ONLY, not production gameplay or NPC/navigation acceptance.
## Caller owns publication, source-derived waypoints and pre-act placement.
## Keep this instance alive; call cleanup() from the host's _exit_tree().
## Each waypoint is {id: String, position: Vector3, standingY: float} in world
## space. standingY is the feet elevation (CottagePocPlayer's origin).
## Optional capture: bool defaults true; false still requires approach + stop.
## Optional faceDirection: finite nonzero horizontal Vector3, faced by mouse
## input after stopping, before capture/completion. No target deduplication here.
## No route search, jump, sprint, transform/velocity writes or collision changes.
## Optional fifth run argument: frozen source-visible/furnishing {id, bounds}
## boxes. Actual consecutive physics observations are checked, not ideal targets.
## Default [] preserves the old call but explicitly provides NO clearance proof.
const PlayerScript = preload("res://scripts/testing/buildings/CottagePocPlayer.gd")
const MAX_SECONDS := 45.0
const NO_PROGRESS_SECONDS := 3.0
const AIRBORNE_SECONDS := 0.35
const ARRIVAL_RADIUS := 0.35
const BRAKE_RADIUS := 0.30
const STANDING_Y_ERROR := 0.12
const STOP_SPEED := 0.05
const STOP_SECONDS := 0.25
const FACE_YAW_ERROR := 0.03
const MAX_SAMPLES := 8192
const EVIDENCE := "local_poc_keyboard_mouse_real_physics_witness"
const CLEARANCE_RADIUS := 0.32
const CLEARANCE_HEIGHT := 1.72
const CLEARANCE_GROUND_SKIN := 0.02
const MAX_CLEARANCE_OBSTACLES := 4096
const MAX_CLEARANCE_SEGMENTS := 8192
const MAX_CLEARANCE_COORDINATE := 1000000.0

var _host: Node3D
var _actor: CharacterBody3D
var _tree: SceneTree
var _targets: Array = []
var _trace: Array = []
var _inputs: Array = []
var _arrivals: Array = []
var _result: Dictionary = {}
var _file: FileAccess
var _directory := ""
var _report_path := ""
var _active := false
var _used := false
var _forward := false
var _reason := ""
var _index := 0
var _phase := "begin"
var _started_msec := 0
var _progress_msec := 0
var _air_started_msec := 0
var _physics_seconds := 0.0
var _air_seconds := 0.0
var _stop_seconds := 0.0
var _best_distance := INF
var _start_distance := 0.0
var _start_position := Vector3.ZERO
var _approach_index := 0
var _arrival_index := 0
var _stop_draw_frame := 0
var _last_sample_frame := -1
var _clearance_obstacles: Array = []
var _clearance_enabled := false
var _previous_observed_feet := Vector3.ZERO
var _clearance_segments := 0
var _clearance_tests := 0
var _clearance_max_usec := 0
var _clearance_validation_usec := 0
var _clearance_failure: Dictionary = {}


func run(host: Node3D, actor: CharacterBody3D, waypoints: Array, screenshot_dir: String, obstacles: Array = []) -> Dictionary:
	if _active:
		return {"passed": false, "reason": "already_running", "evidenceLevel": EVIDENCE}
	# Single-use instance makes cancellation and artifact ownership unambiguous.
	if _used:
		return {"passed": false, "reason": "witness_already_used", "evidenceLevel": EVIDENCE}
	_used = true
	_host = host
	_actor = actor
	var validation_started := Time.get_ticks_usec()
	var clearance := prepare_observed_clearance(obstacles)
	_clearance_validation_usec = Time.get_ticks_usec() - validation_started
	if not clearance.ready:
		_set_forward(false, true)
		return {"passed": false, "reason": clearance.reason, "evidenceLevel": EVIDENCE,
			"clearanceProof": false, "observedClearance": clearance}
	_clearance_obstacles = clearance.obstacles
	_clearance_enabled = not _clearance_obstacles.is_empty()
	var invalid := _validate(waypoints, screenshot_dir)
	if not invalid.is_empty():
		_set_forward(false, true)
		return {"passed": false, "reason": invalid, "evidenceLevel": EVIDENCE}
	for target in waypoints:
		var copied := {"id": target.id, "position": target.position, "standingY": float(target.standingY), "capture": target.get("capture", true)}
		if target.has("faceDirection"):
			copied["faceDirection"] = target.faceDirection
		_targets.append(copied)
	_directory = screenshot_dir.simplify_path()
	_report_path = _directory.path_join("local-walk-trace.json")
	if DirAccess.make_dir_recursive_absolute(_directory) != OK:
		return {"passed": false, "reason": "capture_directory_failed", "evidenceLevel": EVIDENCE}
	# Preflight all artifact names before injecting any pressed input.
	var paths: Array = [_report_path]
	for index in range(_targets.size()):
		if _targets[index].capture:
			paths.append(_directory.path_join("local-walk-%02d.png" % index))
	for path in paths:
		if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path):
			return {"passed": false, "reason": "artifact_already_exists", "path": path, "evidenceLevel": EVIDENCE}
	_file = FileAccess.open(_report_path, FileAccess.WRITE)
	if _file == null:
		return {"passed": false, "reason": "trace_open_failed", "evidenceLevel": EVIDENCE}
	_file.store_string(JSON.stringify({"passed": false, "reason": "in_progress", "evidenceLevel": EVIDENCE,
		"observedClearanceEnabled": _clearance_enabled, "clearanceProof": false}))
	_file.flush()
	_tree = host.get_tree()
	_started_msec = Time.get_ticks_msec()
	_previous_observed_feet = _actor.global_position
	_active = true
	_tree.physics_frame.connect(_physics_tick)
	# Input decisions and continuous sampling happen at every physics boundary.
	# The coroutine handles screenshots and wall time even when physics is paused.
	while _active:
		await _tree.process_frame
		if not _active:
			break
		if not is_instance_valid(_host) or not is_instance_valid(_actor) or not _host.is_inside_tree() or not _actor.is_inside_tree():
			_fail("host_or_actor_left_tree")
		elif _tree.paused or not _actor.is_physics_processing():
			_fail("physics_not_running")
		elif _elapsed() >= MAX_SECONDS:
			_fail("whole_walk_timeout")
		elif Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			_fail("mouse_capture_lost")
		if _reason.is_empty() and _phase == "capture" and (not _targets[_index].capture or Engine.get_frames_drawn() > _stop_draw_frame):
			_capture_target()
		if not _reason.is_empty() or _index == _targets.size():
			_finish()
	return _result


func cleanup() -> void:
	# Safe on every host exit, including a suspended run() coroutine.
	_set_forward(false, true)
	if _active:
		_fail("cancelled_by_host")
		_finish()


func _validate(waypoints: Array, directory: String) -> String:
	if not is_instance_valid(_host) or not is_instance_valid(_actor) or not _host.is_inside_tree() or not _actor.is_inside_tree():
		return "invalid_host_or_actor"
	if _host.get_tree() != _actor.get_tree() or _actor.get_script() != PlayerScript:
		return "requires_unchanged_cottage_poc_player"
	if _host.get_tree().paused or not _actor.is_physics_processing() or not _actor.is_processing_unhandled_input():
		return "player_input_or_physics_disabled"
	if DisplayServer.get_name() == "headless" or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return "requires_headed_captured_mouse"
	if _actor.collision_mask == 0 or not _actor.global_position.is_finite() or not _actor.velocity.is_finite():
		return "invalid_actor_state"
	if not _actor.global_transform.basis.y.is_equal_approx(Vector3.UP):
		return "requires_upright_actor"
	for key in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_SPACE, KEY_SHIFT]:
		if Input.is_key_pressed(key):
			return "requires_released_movement_keys"
	if not directory.is_absolute_path() or waypoints.is_empty() or waypoints.size() > 64:
		return "invalid_output_or_waypoints"
	var ids: Dictionary = {}
	for target in waypoints:
		if not target is Dictionary or not target.get("id") is String or String(target.id).is_empty() or String(target.id).length() > 128 or ids.has(target.id):
			return "invalid_or_duplicate_waypoint_id"
		if not target.get("position") is Vector3 or not (target.get("standingY") is float or target.get("standingY") is int):
			return "invalid_waypoint_geometry"
		var position: Vector3 = target.position
		var standing_y := float(target.standingY)
		if not position.is_finite() or not is_finite(standing_y):
			return "nonfinite_waypoint"
		if maxf(maxf(absf(position.x), absf(position.y)), absf(position.z)) > 1000000.0 or absf(standing_y) > 1000000.0:
			return "unbounded_waypoint"
		if not target.get("capture", true) is bool:
			return "invalid_waypoint_capture"
		if target.has("faceDirection"):
			if not target.faceDirection is Vector3:
				return "invalid_face_direction"
			var facing: Vector3 = target.faceDirection
			if not facing.is_finite() or facing.y != 0.0 or facing.length_squared() <= 0.000001 or facing.length_squared() > 1000000000000.0:
				return "invalid_face_direction"
		ids[target.id] = true
	return ""


func _physics_tick() -> void:
	if not _active or not _reason.is_empty() or _index >= _targets.size():
		return
	if not is_instance_valid(_actor) or not _actor.is_inside_tree():
		_fail("actor_left_tree")
		return
	var frame := Engine.get_physics_frames()
	if _last_sample_frame >= 0 and frame != _last_sample_frame + 1:
		_fail("discontinuous_physics_trace")
		return
	var delta := 0.0 if _last_sample_frame < 0 else _actor.get_physics_process_delta_time()
	_last_sample_frame = frame
	_physics_seconds += delta
	if _trace.size() >= MAX_SAMPLES or _inputs.size() >= MAX_SAMPLES * 4:
		_fail("trace_budget_exceeded")
		return
	var target: Dictionary = _targets[_index]
	var position := _actor.global_position
	var velocity := _actor.velocity
	var grounded := _actor.is_on_floor()
	# physics_frame precedes this tick's actor update: these are observations
	# of the completed preceding tick, never a claimed post-input outcome.
	_trace.append({"sampleAtPhysicsFrame": frame, "completedPhysicsFrame": frame - 1,
		"elapsedSeconds": _elapsed(), "physicsSeconds": _physics_seconds,
		"targetId": target.id, "phase": _phase, "position": position,
		"velocity": velocity, "grounded": grounded, "floorNormal": _actor.get_floor_normal() if grounded else Vector3.ZERO,
		"colliderOwners": _contacts(), "wPressed": Input.is_key_pressed(KEY_W),
		"forward": -_actor.global_transform.basis.z})
	if not position.is_finite() or not velocity.is_finite():
		_fail("nonfinite_actor_state")
		return
	# Includes approach, braking, stopped turning and capture frames. The first
	# segment starts at the actual pre-act observation saved before connection.
	if not _observe_actual_clearance(position):
		return
	for key in [KEY_A, KEY_S, KEY_D, KEY_SPACE, KEY_SHIFT]:
		if Input.is_key_pressed(key):
			_fail("foreign_movement_or_jump_input")
	if _elapsed() >= MAX_SECONDS or _physics_seconds >= MAX_SECONDS:
		_fail("whole_walk_timeout")
	if grounded:
		_air_seconds = 0.0
		_air_started_msec = 0
	else:
		_air_seconds += delta
		if _air_started_msec == 0:
			_air_started_msec = Time.get_ticks_msec()
		if _air_seconds >= AIRBORNE_SECONDS or float(Time.get_ticks_msec() - _air_started_msec) / 1000.0 >= AIRBORNE_SECONDS:
			_fail("airborne_limit")
	if not _reason.is_empty():
		return
	var offset: Vector3 = target.position - position
	offset.y = 0.0
	var distance := offset.length()
	if _phase == "begin":
		if distance <= ARRIVAL_RADIUS:
			_fail("target_requires_observed_approach")
			return
		_start_position = position
		_start_distance = distance
		_best_distance = distance
		_progress_msec = Time.get_ticks_msec()
		_approach_index = _trace.size() - 1
		_phase = "approach"
	if _phase == "approach":
		if distance < _best_distance - 0.02:
			_best_distance = distance
			_progress_msec = Time.get_ticks_msec()
		if float(Time.get_ticks_msec() - _progress_msec) / 1000.0 >= NO_PROGRESS_SECONDS:
			_fail("no_progress")
		elif distance <= BRAKE_RADIUS:
			_set_forward(false)
			_phase = "stopping"
			_arrival_index = _trace.size() - 1
			_stop_seconds = 0.0
			_progress_msec = Time.get_ticks_msec()
		else:
			var yaw_error := _yaw_error(offset)
			_set_forward(absf(yaw_error) <= 0.12)
			_turn_mouse(yaw_error)
	elif _phase == "stopping" or _phase == "turning" or _phase == "capture":
		_set_forward(false)
		var stopped := grounded and Vector2(velocity.x, velocity.z).length() <= STOP_SPEED and absf(position.y - float(target.standingY)) <= STANDING_Y_ERROR
		if distance > ARRIVAL_RADIUS:
			_fail("arrival_drifted_outside_target")
		elif (_phase == "turning" or _phase == "capture") and not stopped:
			_fail("stop_not_maintained_for_turn_or_capture")
		elif stopped:
			_stop_seconds += delta
			if _phase == "stopping" and _stop_seconds >= STOP_SECONDS:
				_phase = "turning"
			if _phase == "turning":
				var facing_error := _yaw_error(target.faceDirection) if target.has("faceDirection") else 0.0
				if absf(facing_error) > FACE_YAW_ERROR:
					_turn_mouse(facing_error)
				else:
					# Alignment is observed on a subsequent physics sample, not
					# inferred from the mouse event we just submitted.
					_phase = "capture"
					_stop_draw_frame = Engine.get_frames_drawn()
			elif _phase == "capture" and target.has("faceDirection") and absf(_yaw_error(target.faceDirection)) > FACE_YAW_ERROR:
				_fail("facing_not_maintained_for_capture")
		else:
			_stop_seconds = 0.0
		if float(Time.get_ticks_msec() - _progress_msec) / 1000.0 >= NO_PROGRESS_SECONDS:
			_fail("grounded_stop_turn_or_capture_timeout")


func _capture_target() -> void:
	var observed_walk := false
	for sample_index in range(_approach_index, _arrival_index + 1):
		observed_walk = observed_walk or bool(_trace[sample_index].wPressed)
	if not observed_walk:
		_fail("no_observed_keyboard_approach")
		return
	var path := ""
	if _targets[_index].capture:
		var camera: Camera3D = _actor.get("camera")
		if not is_instance_valid(camera) or _host.get_viewport().get_camera_3d() != camera:
			_fail("player_camera_not_current")
			return
		path = _directory.path_join("local-walk-%02d.png" % _index)
		if FileAccess.file_exists(path):
			_fail("capture_path_no_longer_fresh")
			return
		# At least one rendered frame after the maintained grounded stop and
		# observed facing, while physics tracing remains connected.
		var capture := _host.get_viewport().get_texture().get_image()
		if capture == null or capture.is_empty() or capture.save_png(path) != OK:
			_fail("screenshot_failed")
			return
	_arrivals.append({"id": _targets[_index].id, "target": _targets[_index],
		"approachStartTraceIndex": _approach_index, "arrivalTraceIndex": _arrival_index,
		"stoppedTraceIndex": _trace.size() - 1, "startPosition": _start_position,
		"startDistance": _start_distance, "stopSeconds": _stop_seconds,
		"captureRequested": _targets[_index].capture, "screenshot": path,
		"facingYawError": _yaw_error(_targets[_index].faceDirection) if _targets[_index].has("faceDirection") else 0.0,
		"drawFrame": Engine.get_frames_drawn()})
	_index += 1
	_phase = "begin"


func _contacts() -> Array:
	var contacts: Array = []
	for slide_index in range(_actor.get_slide_collision_count()):
		var collision := _actor.get_slide_collision(slide_index)
		for contact_index in range(collision.get_collision_count()):
			if contacts.size() >= 32:
				_fail("contact_trace_budget_exceeded")
				return contacts
			var body := collision.get_collider(contact_index)
			var shape_index := collision.get_collider_shape_index(contact_index)
			var shape_owner: Object = null
			if body is CollisionObject3D and shape_index >= 0:
				shape_owner = body.shape_owner_get_owner(body.shape_find_owner(shape_index))
			var metadata := _contact_metadata(shape_owner, body)
			contacts.append({"bodyPath": str(body.get_path()) if body is Node else "",
				"bodyInstanceId": collision.get_collider_id(contact_index), "shapeIndex": shape_index,
				"shapeOwnerPath": str(shape_owner.get_path()) if shape_owner is Node else "",
				"partId": metadata.partId, "semantic": metadata.semantic,
				"metadataOwners": metadata.owners, "metadataSources": metadata.sources,
				"position": collision.get_position(contact_index), "normal": collision.get_normal(contact_index)})
	return contacts


func _contact_metadata(shape_owner: Object, body: Object) -> Dictionary:
	# Exact shape first, body second, then at most four parents of each.
	# Preserve each observed value/path; never copy a whole publisher record.
	var candidates: Array = [shape_owner, body]
	for origin in [shape_owner, body]:
		var parent: Node = origin.get_parent() if origin is Node else null
		for _depth in range(4):
			if parent == null:
				break
			candidates.append(parent)
			parent = parent.get_parent()
	var result := {"partId": "", "semantic": "", "owners": [], "sources": {}}
	var seen: Dictionary = {}
	for candidate in candidates:
		if not is_instance_valid(candidate) or seen.has(candidate.get_instance_id()):
			continue
		seen[candidate.get_instance_id()] = true
		var path := str(candidate.get_path()) if candidate is Node else ""
		var values: Dictionary = {}
		for field in ["partId", "semantic"]:
			var key: String = "building_part_id" if field == "partId" else "building_semantic"
			var value := str(candidate.get_meta(key, ""))
			values[field] = value
			if result[field] == "" and value != "":
				result[field] = value
				result.sources[field] = path
		result.owners.append({"path": path, "values": values})
	return result


func _yaw_error(direction: Vector3) -> float:
	var forward := -_actor.global_transform.basis.z
	return wrapf(atan2(-direction.x, -direction.z) - atan2(-forward.x, -forward.z), -PI, PI)


func _turn_mouse(yaw_error: float) -> void:
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(-clampf(yaw_error, -0.15, 0.15) / PlayerScript.MOUSE_SENSITIVITY, 0.0)
	Input.parse_input_event(motion)
	_inputs.append({"physicsFrame": Engine.get_physics_frames(), "type": "mouse_yaw", "relativeX": motion.relative.x, "phase": _phase})


func _set_forward(pressed: bool, force := false) -> void:
	if _forward == pressed and not force:
		return
	var event := InputEventKey.new()
	event.keycode = KEY_W
	event.physical_keycode = KEY_W
	event.pressed = pressed
	Input.parse_input_event(event)
	_forward = pressed
	if _active:
		_inputs.append({"physicsFrame": Engine.get_physics_frames(), "type": "key_w", "pressed": pressed})


func _fail(reason: String) -> void:
	if _reason.is_empty():
		_reason = reason
	_set_forward(false, true)


func _finish() -> void:
	if _reason.is_empty() and _elapsed() >= MAX_SECONDS:
		_reason = "whole_walk_timeout"
	_set_forward(false, true)
	_active = false
	if is_instance_valid(_tree) and _tree.physics_frame.is_connected(_physics_tick):
		_tree.physics_frame.disconnect(_physics_tick)
	_result = {"passed": _reason.is_empty() and _arrivals.size() == _targets.size(),
		"reason": _reason, "evidenceLevel": EVIDENCE, "tracePath": _report_path,
		"elapsedSeconds": _elapsed(), "physicsSeconds": _physics_seconds,
		"limits": {"wholeWalkSeconds": MAX_SECONDS, "noProgressSeconds": NO_PROGRESS_SECONDS,
			"airborneSeconds": AIRBORNE_SECONDS, "arrivalRadius": ARRIVAL_RADIUS,
			"standingYError": STANDING_Y_ERROR, "stopSpeed": STOP_SPEED, "stopSeconds": STOP_SECONDS, "faceYawError": FACE_YAW_ERROR},
		"waypoints": _targets, "arrivals": _arrivals, "trace": _trace, "inputs": _inputs,
		"clearanceProof": _clearance_enabled and _clearance_segments > 0 and _clearance_failure.is_empty() and _reason.is_empty() and _arrivals.size() == _targets.size(),
		"observedClearance": {"enabled": _clearance_enabled, "obstacleCount": _clearance_obstacles.size(),
			"segmentsObserved": _clearance_segments, "obstacleTests": _clearance_tests,
			"maxObserverUsec": _clearance_max_usec, "validationUsec": _clearance_validation_usec,
			"radius": CLEARANCE_RADIUS, "height": CLEARANCE_HEIGHT, "groundSkin": CLEARANCE_GROUND_SKIN,
			"maximumObstacles": MAX_CLEARANCE_OBSTACLES, "maximumSegments": MAX_CLEARANCE_SEGMENTS,
			"failure": _clearance_failure,
			"scope": "conservative actual-feet swept box against supplied immutable obstacle snapshot only" if _clearance_enabled else "disabled: no supplied obstacles, no observed-clearance proof"},
		"doesNotProve": "Production gameplay, main-menu flow, NPC/navigation, global accessibility, structural acceptance or unvisited geometry. Caller-owned setup placement is excluded from act evidence. This is only the unchanged local PoC player walking supplied targets through ordinary keyboard/mouse input and real collision."}
	if _file != null:
		_file.seek(0)
		_file.store_string(JSON.stringify(_json(_result), "\t"))
		_file.flush()
		if _file.get_error() != OK:
			_result.passed = false
			_result.reason = "trace_write_failed"
		_file.close()
		_file = null


func _observe_actual_clearance(position: Vector3) -> bool:
	if not _clearance_enabled:
		# Keep legacy behavior when no obstacle snapshot was supplied.
		return true
	var started := Time.get_ticks_usec()
	# This private array was validated and copied at run entry. It is never
	# returned to or shared with the caller and is never subsequently modified.
	var observed := _observe_validated_segment(_previous_observed_feet, position, _clearance_obstacles, _clearance_segments)
	_clearance_max_usec = maxi(_clearance_max_usec, Time.get_ticks_usec() - started)
	_clearance_tests += int(observed.get("obstacleTests", 0))
	_clearance_segments += 1
	_previous_observed_feet = position
	if not _trace.is_empty():
		_trace.back()["observedClearance"] = {"segment": observed.get("segmentIndex", _clearance_segments - 1),
			"clear": observed.ready, "obstacleTests": observed.get("obstacleTests", 0)}
	if not observed.ready:
		_clearance_failure = observed
		_fail(String(observed.reason)) # releases W immediately; no actor writes
		_finish() # persist the actual segment/obstacle and disconnect immediately
		return false
	return true


static func prepare_observed_clearance(obstacles: Variant) -> Dictionary:
	# Pure source validation/copy. Never drop a malformed record or exempt an
	# obstacle by semantic/name (a tall 'wear' box is still an obstruction).
	if not obstacles is Array or obstacles.size() > MAX_CLEARANCE_OBSTACLES:
		return _clearance_reject("invalid_or_excessive_clearance_obstacles")
	var copied: Array = []
	var seen: Dictionary = {}
	for index in range(obstacles.size()):
		var obstacle: Variant = obstacles[index]
		if not obstacle is Dictionary or not obstacle.get("id") is String or obstacle.id.is_empty() or obstacle.id.length() > 256 or seen.has(obstacle.id) or not obstacle.get("bounds") is AABB:
			return _clearance_reject("invalid_clearance_obstacle", {"obstacleIndex": index})
		if not _clearance_bounds_valid(obstacle.bounds):
			return _clearance_reject("invalid_clearance_obstacle_bounds", {"obstacleIndex": index, "partId": obstacle.id})
		seen[obstacle.id] = true
		copied.append({"id": obstacle.id, "bounds": obstacle.bounds})
	return {"ready": true, "reason": "", "obstacles": copied, "obstacleCount": copied.size(),
		"clearanceChecked": false, "clearanceProof": false}


static func observe_clearance_segment(previous_feet: Variant, current_feet: Variant, obstacles: Variant, segment_index := 0) -> Dictionary:
	# Pure public entrypoint for contracts/standalone observations: validates all
	# input before testing any segment, even if an earlier box would intersect.
	var prepared := prepare_observed_clearance(obstacles)
	if not prepared.ready: return prepared
	return _observe_validated_segment(previous_feet, current_feet, prepared.obstacles, segment_index)


static func _observe_validated_segment(previous_feet: Variant, current_feet: Variant, obstacles: Array, segment_index: int) -> Dictionary:
	if segment_index < 0 or segment_index >= MAX_CLEARANCE_SEGMENTS:
		return _clearance_reject("observed_clearance_segment_limit", {"segmentIndex": segment_index})
	if not previous_feet is Vector3 or not current_feet is Vector3 or not _clearance_point_valid(previous_feet) or not _clearance_point_valid(current_feet):
		return _clearance_reject("invalid_observed_feet", {"segmentIndex": segment_index})
	var before: Vector3 = previous_feet
	var after: Vector3 = current_feet
	# Same conservative full-body sweep as the itinerary preflight, now driven
	# exclusively by successive ACTUAL observations (including vertical change).
	var sweep := AABB(before.min(after) + Vector3(-CLEARANCE_RADIUS, CLEARANCE_GROUND_SKIN, -CLEARANCE_RADIUS),
		(after - before).abs() + Vector3(CLEARANCE_RADIUS * 2, CLEARANCE_HEIGHT - CLEARANCE_GROUND_SKIN, CLEARANCE_RADIUS * 2))
	if not sweep.position.is_finite() or not sweep.size.is_finite() or not sweep.end.is_finite():
		return _clearance_reject("invalid_observed_sweep", {"segmentIndex": segment_index})
	var tests := 0
	for obstacle in obstacles:
		tests += 1
		if sweep.intersects(obstacle.bounds):
			return _clearance_reject("observed_clearance_blocked", {"segmentIndex": segment_index,
				"partId": obstacle.id, "previousFeet": before, "currentFeet": after,
				"sweptBounds": sweep, "obstacleBounds": obstacle.bounds, "obstacleTests": tests,
				"clearanceChecked": true})
	return {"ready": true, "reason": "", "segmentIndex": segment_index, "previousFeet": before,
		"currentFeet": after, "sweptBounds": sweep, "obstacleTests": tests,
		"clearanceChecked": not obstacles.is_empty(), "clearanceProof": not obstacles.is_empty(),
		"scope": "provided_obstacle_snapshot_only" if not obstacles.is_empty() else "no_obstacles_no_clearance_proof"}


static func _clearance_point_valid(point: Vector3) -> bool:
	return point.is_finite() and absf(point.x) <= MAX_CLEARANCE_COORDINATE and absf(point.y) <= MAX_CLEARANCE_COORDINATE and absf(point.z) <= MAX_CLEARANCE_COORDINATE


static func _clearance_bounds_valid(bounds: AABB) -> bool:
	return _clearance_point_valid(bounds.position) and _clearance_point_valid(bounds.end) and bounds.size.is_finite() and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0


static func _clearance_reject(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate()
	result["ready"] = false
	result["reason"] = reason
	result["clearanceProof"] = false
	if not result.has("obstacleTests"): result["obstacleTests"] = 0
	return result


func _elapsed() -> float:
	return float(Time.get_ticks_msec() - _started_msec) / 1000.0


static func _json(value: Variant) -> Variant:
	if value is Vector3:
		return [_json(value.x), _json(value.y), _json(value.z)]
	if value is AABB:
		return {"position": _json(value.position), "size": _json(value.size)}
	if value is float and not is_finite(value):
		return str(value)
	if value is Dictionary:
		var output: Dictionary = {}
		for key in value:
			output[key] = _json(value[key])
		return output
	if value is Array:
		return value.map(func(item): return _json(item))
	return value

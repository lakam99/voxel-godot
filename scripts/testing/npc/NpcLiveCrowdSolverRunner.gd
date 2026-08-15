extends Node3D

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const NpcCrowdVelocityServiceScript := preload("res://scripts/npc_ai/movement/NpcCrowdVelocityService.gd")
const ReciprocalAvoidanceAdapterScript := preload("res://scripts/npc_ai/movement/ReciprocalAvoidanceAdapter.gd")
const NpcRouteLeaseExecutorScript := preload("res://scripts/npc_ai/movement/NpcRouteLeaseExecutor.gd")

const ACTOR_COUNT := 10
const TEST_FRAMES := 900
const ARRIVAL_RADIUS := 0.36

var crowd_service
var direct_adapter
var lease_executor
var raw_mode := false
var raw_batch_mode := false
var adapter_mode := false
var line_mode := false
var citadel_replay_mode := false
var executor_mode := false
var raw_agents := {}
var raw_safe_velocities := {}
var entries: Array = []
var targets := {}
var starts := {}
var minimum_separation := INF
var overlap_frames := 0
var frame_count := 0
var stable_arrival_frames := 0
var maximum_server_position_error := 0.0
var server_position_error_at_minimum := 0.0
var server_synchronized_actor_ids := {}
var production_profile = CharacterMotorProfileScript.npc_default()
var required_separation := 0.0


func _ready() -> void:
	var profile_radius := OS.get_environment("VOXEL_NPC_LIVE_CROWD_PROFILE_RADIUS")
	if profile_radius.is_valid_float():
		production_profile.capsule_radius = float(profile_radius)
	required_separation = (float(production_profile.capsule_radius) + NpcConstantsScript.AVOIDANCE_RADIUS_SAFETY_MARGIN) * 2.0
	raw_mode = OS.get_environment("VOXEL_NPC_LIVE_CROWD_RAW") == "1"
	raw_batch_mode = OS.get_environment("VOXEL_NPC_LIVE_CROWD_RAW_BATCH") == "1"
	adapter_mode = OS.get_environment("VOXEL_NPC_LIVE_CROWD_ADAPTER") == "1"
	line_mode = OS.get_environment("VOXEL_NPC_LIVE_CROWD_LINE") == "1"
	citadel_replay_mode = OS.get_environment("VOXEL_NPC_LIVE_CROWD_CITADEL_REPLAY") == "1"
	executor_mode = OS.get_environment("VOXEL_NPC_LIVE_CROWD_EXECUTOR") == "1"
	if adapter_mode:
		direct_adapter = ReciprocalAvoidanceAdapterScript.new()
		direct_adapter.setup(null, null)
	elif not raw_mode:
		crowd_service = NpcCrowdVelocityServiceScript.new()
		crowd_service.setup(null, null)
		if executor_mode:
			lease_executor = NpcRouteLeaseExecutorScript.new()
			lease_executor.setup(null, null, null, crowd_service)
	for actor_index in range(ACTOR_COUNT):
		var scenario := _citadel_replay_scenario(actor_index) if citadel_replay_mode else (_line_scenario(actor_index) if line_mode else _radial_scenario(actor_index))
		var start: Vector3 = scenario.start
		var target: Vector3 = scenario.target
		var body := CharacterBody3D.new()
		body.name = "LiveCrowdActor%02d" % actor_index
		add_child(body)
		body.global_position = start
		body.set_meta("npc_stable_id", body.name)
		body.set_meta("npc_applied_velocity", Vector3.ZERO)
		body.set_meta("npc_requested_velocity", Vector3.ZERO)
		var collision := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = float(production_profile.capsule_radius)
		capsule.height = float(production_profile.capsule_height)
		collision.shape = capsule
		body.add_child(collision)
		if raw_mode:
			var agent := NavigationAgent3D.new()
			body.add_child(agent)
			agent.radius = float(production_profile.capsule_radius) + NpcConstantsScript.AVOIDANCE_RADIUS_SAFETY_MARGIN
			agent.height = float(production_profile.capsule_height)
			agent.neighbor_distance = NpcConstantsScript.AVOIDANCE_NEIGHBOR_DISTANCE
			agent.max_neighbors = NpcConstantsScript.AVOIDANCE_MAX_NEIGHBORS
			agent.time_horizon_agents = NpcConstantsScript.AVOIDANCE_TIME_HORIZON_AGENTS
			agent.time_horizon_obstacles = NpcConstantsScript.AVOIDANCE_TIME_HORIZON_OBSTACLES
			agent.max_speed = NpcConstantsScript.DEFAULT_NPC_WALK_SPEED
			agent.avoidance_priority = 0.72 if OS.get_environment("VOXEL_NPC_LIVE_CROWD_RAW_PRIORITY_72") == "1" else 0.5
			agent.avoidance_enabled = true
			agent.target_position = target
			agent.velocity_computed.connect(_on_raw_velocity_computed.bind(body))
			raw_agents[body.name] = agent
		var entry := {
			"id": body.name,
			"body": body,
			"motorProfile": production_profile,
			"routeStatus": "moving",
			"routeLease": {"state": "ready", "leaseId": "live-crowd:%02d" % actor_index, "requestId": "live-crowd:%02d" % actor_index, "waypoints": [target], "actions": {}, "probeCertificate": {"ok": true, "authoritative": true}}
		}
		if OS.get_environment("VOXEL_NPC_LIVE_CROWD_DISABLE_LANE") == "1":
			(entry.routeLease.probeCertificate as Dictionary).erase("details")
		entries.append(entry)
		targets[body.name] = target
		starts[body.name] = start


func _physics_process(_delta: float) -> void:
	frame_count += 1
	if adapter_mode:
		direct_adapter.begin_frame()
	elif not raw_mode:
		crowd_service.begin_physics_frame(entries)
	for entry_value in entries:
		var entry: Dictionary = entry_value
		var body := entry.get("body") as CharacterBody3D
		var target: Vector3 = targets.get(body.name, body.global_position)
		var offset := target - body.global_position
		offset.y = 0.0
		var actor_index := int(body.name.right(2))
		var stagger_frames := int(OS.get_environment("VOXEL_NPC_LIVE_CROWD_STAGGER_FRAMES")) if OS.get_environment("VOXEL_NPC_LIVE_CROWD_STAGGER_FRAMES").is_valid_int() else 0
		var waiting_for_admission := frame_count < actor_index * stagger_frames
		var desired := Vector3.ZERO if waiting_for_admission or offset.length() <= ARRIVAL_RADIUS else offset.normalized() * NpcConstantsScript.DEFAULT_NPC_WALK_SPEED
		body.set_meta("npc_requested_velocity", desired)
		if raw_mode:
			var agent := raw_agents.get(body.name) as NavigationAgent3D
			if OS.get_environment("VOXEL_NPC_LIVE_CROWD_RAW_REENABLE") == "1":
				agent.avoidance_enabled = true
			if OS.get_environment("VOXEL_NPC_LIVE_CROWD_RAW_REPROFILE") == "1":
				agent.radius = float(production_profile.capsule_radius) + NpcConstantsScript.AVOIDANCE_RADIUS_SAFETY_MARGIN
				agent.height = float(production_profile.capsule_height)
				agent.neighbor_distance = NpcConstantsScript.AVOIDANCE_NEIGHBOR_DISTANCE
				agent.max_neighbors = NpcConstantsScript.AVOIDANCE_MAX_NEIGHBORS
				agent.time_horizon_agents = NpcConstantsScript.AVOIDANCE_TIME_HORIZON_AGENTS
				agent.time_horizon_obstacles = NpcConstantsScript.AVOIDANCE_TIME_HORIZON_OBSTACLES
				agent.max_speed = NpcConstantsScript.DEFAULT_NPC_WALK_SPEED
				agent.avoidance_priority = 0.5
			if OS.get_environment("VOXEL_NPC_LIVE_CROWD_RAW_RETARGET") == "1":
				agent.target_position = body.global_position
				agent.target_position = target
			agent.velocity = desired
		elif adapter_mode:
			direct_adapter.compute_safe_velocity(entry, body, desired, {
				"actors": entries.map(func(other_entry): return (other_entry as Dictionary).get("body")),
				"forceAvoidance": true,
				"maxSpeed": NpcConstantsScript.DEFAULT_NPC_WALK_SPEED,
				"avoidanceTarget": target,
				"avoidanceRequestKey": "live-crowd:%02d" % int(body.name.right(2)),
				"safeVelocityConsumer": Callable(self, "_on_production_velocity_computed").bind(body)
			})
		elif executor_mode:
			if not waiting_for_admission:
				lease_executor.execute(entry, "live-crowd:%02d" % int(body.name.right(2)), entry.routeLease, _delta, {"speed": NpcConstantsScript.DEFAULT_NPC_WALK_SPEED, "waypointRadius": ARRIVAL_RADIUS})
		else:
			crowd_service.resolve_safe_velocity(entry, body, desired, {
				"forceAvoidance": true,
				"maxSpeed": NpcConstantsScript.DEFAULT_NPC_WALK_SPEED,
				"avoidanceTarget": target,
				"avoidanceRequestKey": "live-crowd:%02d" % int(body.name.right(2)),
				"safeVelocityConsumer": Callable(self, "_on_production_velocity_computed").bind(body)
			})
	if not raw_mode and not adapter_mode:
		crowd_service.end_physics_frame()
	_measure_separation()
	var arrived := _arrived_count()
	stable_arrival_frames = stable_arrival_frames + 1 if arrived == ACTOR_COUNT else 0
	if stable_arrival_frames >= 30 or frame_count >= TEST_FRAMES:
		_finish(arrived)


func _on_raw_velocity_computed(safe_velocity: Vector3, body: CharacterBody3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	if raw_batch_mode:
		raw_safe_velocities[body.name] = safe_velocity
		if raw_safe_velocities.size() == ACTOR_COUNT:
			var actor_names: Array = raw_safe_velocities.keys()
			actor_names.sort()
			var velocities := raw_safe_velocities
			raw_safe_velocities = {}
			for actor_name_value in actor_names:
				var actor_name := String(actor_name_value)
				var actor_body := get_node_or_null(actor_name) as CharacterBody3D
				_move_body(actor_body, velocities.get(actor_name, Vector3.ZERO))
		return
	_move_body(body, safe_velocity)


func _move_body(body: CharacterBody3D, safe_velocity: Vector3) -> void:
	if body == null or not is_instance_valid(body):
		return
	body.set_meta("npc_applied_velocity", safe_velocity)
	body.velocity = safe_velocity
	body.move_and_slide()


func _on_production_velocity_computed(safe_velocity: Vector3, _request_key: String, body: CharacterBody3D) -> void:
	_on_raw_velocity_computed(safe_velocity, body)


func _measure_separation() -> void:
	var frame_overlap := false
	for left_index in range(entries.size()):
		var left := (entries[left_index] as Dictionary).get("body") as CharacterBody3D
		var agent := _agent_for_body(left)
		if agent != null and agent.get_rid().is_valid():
			var server_error := left.global_position.distance_to(NavigationServer3D.agent_get_position(agent.get_rid()))
			if server_error <= 0.10:
				server_synchronized_actor_ids[left.name] = true
			if server_synchronized_actor_ids.has(left.name):
				maximum_server_position_error = maxf(maximum_server_position_error, server_error)
		for right_index in range(left_index + 1, entries.size()):
			var right := (entries[right_index] as Dictionary).get("body") as CharacterBody3D
			var distance := Vector2(left.global_position.x - right.global_position.x, left.global_position.z - right.global_position.z).length()
			if distance < minimum_separation:
				minimum_separation = distance
				server_position_error_at_minimum = 0.0
				for measured_body in [left, right]:
					var measured_agent := _agent_for_body(measured_body)
					if measured_agent != null and measured_agent.get_rid().is_valid():
						server_position_error_at_minimum = maxf(server_position_error_at_minimum, measured_body.global_position.distance_to(NavigationServer3D.agent_get_position(measured_agent.get_rid())))
			if distance + 0.001 < float(production_profile.capsule_radius) * 2.0:
				frame_overlap = true
	if frame_overlap:
		overlap_frames += 1


func _arrived_count() -> int:
	var arrived := 0
	for entry_value in entries:
		var body := (entry_value as Dictionary).get("body") as CharacterBody3D
		var target: Vector3 = targets.get(body.name, body.global_position)
		if Vector2(body.global_position.x - target.x, body.global_position.z - target.z).length() <= ARRIVAL_RADIUS:
			arrived += 1
	return arrived


func _finish(arrived: int) -> void:
	set_physics_process(false)
	var distances := {}
	var progress := {}
	for entry_value in entries:
		var body := (entry_value as Dictionary).get("body") as CharacterBody3D
		var target: Vector3 = targets.get(body.name, body.global_position)
		var start: Vector3 = starts.get(body.name, body.global_position)
		distances[body.name] = Vector2(body.global_position.x - target.x, body.global_position.z - target.z).length()
		progress[body.name] = Vector2(body.global_position.x - start.x, body.global_position.z - start.z).length()
	var server_sync_passed := server_synchronized_actor_ids.size() == ACTOR_COUNT and maximum_server_position_error <= 0.10
	var passed := arrived == ACTOR_COUNT and minimum_separation + 0.001 >= required_separation and overlap_frames == 0 and server_sync_passed
	var report := {
		"passed": passed,
		"actorCount": ACTOR_COUNT,
		"arrivedCount": arrived,
		"frames": frame_count,
		"minimumSeparation": minimum_separation,
		"requiredSeparation": required_separation,
		"overlapFrames": overlap_frames,
		"maximumServerPositionError": maximum_server_position_error,
		"serverSynchronizedActorCount": server_synchronized_actor_ids.size(),
		"serverSynchronizationPassed": server_sync_passed,
		"serverPositionErrorAtMinimum": server_position_error_at_minimum,
		"mode": "raw_navigation_agent" if raw_mode else ("direct_adapter" if adapter_mode else "production_crowd_service"),
		"distances": distances,
		"progress": progress,
		"agentConfig": _agent_config(),
		"solver": direct_adapter.stats() if adapter_mode else (crowd_service.stats() if not raw_mode else {
			"agentCount": raw_agents.size(),
			"radius": float(production_profile.capsule_radius) + NpcConstantsScript.AVOIDANCE_RADIUS_SAFETY_MARGIN,
			"neighborDistance": NpcConstantsScript.AVOIDANCE_NEIGHBOR_DISTANCE,
			"timeHorizonAgents": NpcConstantsScript.AVOIDANCE_TIME_HORIZON_AGENTS
		})
	}
	var report_path := OS.get_environment("VOXEL_NPC_LIVE_CROWD_REPORT")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/npc/reports/live-crowd-solver.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
	print(JSON.stringify(report))
	get_tree().quit(0 if passed else 1)


func _agent_config() -> Dictionary:
	var agent: NavigationAgent3D = raw_agents.values()[0] as NavigationAgent3D if raw_mode and not raw_agents.is_empty() else null
	if adapter_mode and direct_adapter != null and not direct_adapter.agents_by_actor_id.is_empty():
		agent = direct_adapter.agents_by_actor_id.values()[0] as NavigationAgent3D
	elif not raw_mode and crowd_service != null and crowd_service.adapter != null and not crowd_service.adapter.agents_by_actor_id.is_empty():
		agent = crowd_service.adapter.agents_by_actor_id.values()[0] as NavigationAgent3D
	if agent == null:
		return {}
	return {
		"radius": agent.radius,
		"height": agent.height,
		"neighborDistance": agent.neighbor_distance,
		"maxNeighbors": agent.max_neighbors,
		"timeHorizonAgents": agent.time_horizon_agents,
		"timeHorizonObstacles": agent.time_horizon_obstacles,
		"maxSpeed": agent.max_speed,
		"priority": agent.avoidance_priority,
		"layers": agent.avoidance_layers,
		"mask": agent.avoidance_mask,
		"enabled": agent.avoidance_enabled
	}


func _agent_for_body(body: CharacterBody3D) -> NavigationAgent3D:
	if body == null:
		return null
	if raw_mode:
		return raw_agents.get(body.name) as NavigationAgent3D
	if adapter_mode and direct_adapter != null:
		return direct_adapter.agents_by_actor_id.get(body.name) as NavigationAgent3D
	if crowd_service != null and crowd_service.adapter != null:
		return crowd_service.adapter.agents_by_actor_id.get(body.name) as NavigationAgent3D
	return null


func _radial_scenario(actor_index: int) -> Dictionary:
	var angle := TAU * float(actor_index) / float(ACTOR_COUNT)
	var start := Vector3(cos(angle) * 7.0, 1.0, sin(angle) * 7.0)
	var target_angle := angle + PI + 0.16
	return {"start": start, "target": Vector3(cos(target_angle) * 7.0, 1.0, sin(target_angle) * 7.0)}


func _line_scenario(actor_index: int) -> Dictionary:
	var starts := [
		Vector3(0.65, 1.0, 7.6691), Vector3(0.65, 1.0, 4.2191),
		Vector3(0.65, 1.0, 8.8191), Vector3(0.65, 1.0, 5.3691),
		Vector3(-0.65, 1.0, -10.8500), Vector3(0.65, 1.0, 6.5191),
		Vector3(-0.65, 1.0, -13.1500), Vector3(-0.65, 1.0, -8.5500),
		Vector3(-0.65, 1.0, -12.0000), Vector3(-0.65, 1.0, -9.7000)
	]
	var targets_list := [
		Vector3(0.65, 1.0, -5.6000), Vector3(0.65, 1.0, -9.0500),
		Vector3(0.65, 1.0, -4.4500), Vector3(0.65, 1.0, -7.9000),
		Vector3(-0.65, 1.0, 0.9191), Vector3(0.65, 1.0, -6.7500),
		Vector3(-0.65, 1.0, -1.3809), Vector3(-0.65, 1.0, 3.2191),
		Vector3(-0.65, 1.0, -0.2309), Vector3(-0.65, 1.0, 2.0691)
	]
	return {"start": starts[actor_index], "target": targets_list[actor_index]}


func _citadel_replay_scenario(actor_index: int) -> Dictionary:
	var starts := [
		Vector3(0.65, 1.0, 13.5491), Vector3(0.65, 1.0, 10.0291),
		Vector3(0.65, 1.0, 15.3091), Vector3(0.65, 1.0, 8.2691),
		Vector3(-0.65, 1.0, -0.4800), Vector3(0.65, 1.0, 11.7891),
		Vector3(-0.65, 1.0, -4.0000), Vector3(-0.65, 1.0, 3.0400),
		Vector3(-0.65, 1.0, -2.2400), Vector3(-0.65, 1.0, 1.2800)
	]
	var targets_list := [
		Vector3(0.65, 1.0, 1.2800), Vector3(0.65, 1.0, -2.2400),
		Vector3(0.65, 1.0, 3.0400), Vector3(0.65, 1.0, -4.0000),
		Vector3(-0.65, 1.0, 11.7891), Vector3(0.65, 1.0, -0.4800),
		Vector3(-0.65, 1.0, 8.2691), Vector3(-0.65, 1.0, 15.3091),
		Vector3(-0.65, 1.0, 10.0291), Vector3(-0.65, 1.0, 13.5491)
	]
	return {"start": starts[actor_index], "target": targets_list[actor_index]}

extends RefCounted
class_name NpcRouteCoordinatorAdapter

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavmeshRoutePlannerScript := preload("res://scripts/npc_ai/routing/NavmeshRoutePlanner.gd")
const NavDataReadinessServiceScript := preload("res://scripts/npc_ai/routing/NavDataReadinessService.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const LIVE_ROUTE_JOBS_PER_FRAME := 6
const LIVE_ROUTE_JOBS_MAX_PER_FRAME := 24
const ROUTE_BUDGET_GRANT_COOLDOWN_FRAMES := 2
const URGENT_ROUTE_EXTRA_JOBS_PER_FRAME := 1
const SCRIPTED_ROUTE_EXTRA_JOBS_PER_FRAME := 1
const ACTIVE_JOB_ROUTE_EXTRA_JOBS_PER_FRAME := 3
const ACTIVE_JOB_ROUTE_STARVED_FRAMES := 4
const ACTIVE_JOB_NAVMESH_TILE_STARVED_FRAMES := 8
const ACTIVE_JOB_NAVMESH_TILE_FORCE_FRAMES := 16
const STARVED_ROUTE_BUDGET_FRAMES := 12
const STARVED_ROUTE_EXTRA_JOBS_PER_FRAME := 2
const STARVED_HOME_NAVMESH_TILE_FRAMES := 12
const STARVED_HOME_GENERATED_BRIDGE_USEC := 2400
const STARVED_HOME_GENERATED_BRIDGE_VISITS := 1024
const EXACT_HOME_COLLISION_LATTICE_MARGIN_CELLS := 16
const EXACT_HOME_COLLISION_LATTICE_MAX_VISITS := 4096
const EXACT_HOME_COLLISION_LATTICE_MAX_USEC := 32000
const EXACT_HOME_COLLISION_LATTICE_CLEARANCE_EPSILON := 0.04
const EXACT_HOME_COLLISION_LATTICE_START_CENTER_MIN_DISTANCE := CELL * 0.36
const EXACT_HOME_COLLISION_LATTICE_RECOVERABLE_REASONS := [
	"no_route",
	"path_endpoint_mismatch",
	"path_crosses_static_collision",
	"blocked_static_collision",
	"blocked_static_transition",
	"forbidden_private_door_link"
]
const ROUTE_CACHE_LIMIT := 128
# Tile publish budgets. The static town is now pre-baked at spawn
# (prebake_area_tiles), so runtime publishing only needs to cover a few tiles
# whose source revision changed after the bake (town-centre tiles with late
# structure edits) plus streaming frontier tiles. That makes it safe to drain
# the queue fast: a single missing tile can no longer starve an active route for
# a whole day window. The per-frame ms guards (_background_navmesh_tile_publish_should_wait)
# still defer publishing on heavy streaming/hostile frames, so raising the tile
# counts does not reintroduce sustained frame spikes.
const NAVMESH_TILE_PUBLISHES_PER_FRAME := 4
const NAVMESH_TILE_PUBLISHES_MAX_PER_FRAME := 32
const BACKGROUND_NAVMESH_TILE_PUBLISHES_PER_FRAME := 2
const PRIORITY_NAVMESH_TILE_PUBLISHES_PER_FRAME := 8
const PRIORITY_NAVMESH_TILE_PUBLISH_USEC_BUDGET := 20000
const ACTIVE_JOB_NAVMESH_TILE_FOREGROUND_PUBLISHES_PER_FRAME := 6
const ACTIVE_JOB_NAVMESH_TILE_FOREGROUND_USEC_BUDGET := 14000
const PRIORITY_NAVMESH_TILE_POST_FOREGROUND_USEC_BUDGET := 3000
const BACKGROUND_NAVMESH_TILE_PUBLISH_USEC_BUDGET := 3000
const BACKGROUND_NAVMESH_TILE_PUBLISH_FRAME_INTERVAL := 2
const BACKGROUND_NAVMESH_TILE_MAX_CHUNK_FRAME_MS := 6.0
const BACKGROUND_NAVMESH_TILE_MAX_HOSTILE_FRAME_MS := 8.0
const ORDERED_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES := 1
const SCRIPTED_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES := 1
const DIRECT_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES := 1
const COST_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES := 0
const ACTIVE_JOB_NAVMESH_TILE_EXTRA_PUBLISHES := 1
const ROUTINE_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES := 0

var system
var main
var world
var backend_config
var navmesh_planner
var navmesh_world
var nav_data_readiness
var route_budget_frame := -1
var route_budget_tick := 0
var route_budget_engine_frame := -1
var route_budget_seen_tick := -1
var route_budget_serial := 0
var route_jobs_this_frame := 0
var urgent_route_jobs_this_frame := 0
var scripted_route_jobs_this_frame := 0
var active_job_route_jobs_this_frame := 0
var starved_route_jobs_this_frame := 0
var navmesh_tile_publish_engine_frame := -1
var navmesh_tile_publish_seen_tick := -1
var navmesh_tile_publishes_this_frame := 0
var active_job_navmesh_tile_foreground_publishes_this_frame := 0
var navmesh_tile_publish_work_this_frame := false
var route_last_granted_actor_id := ""
var route_cache := {}
var route_cache_order: Array[String] = []
# Tile-scoped cache invalidation: cache_key -> Array[String] of tile keys the
# route crosses, and the reverse index tile_key -> { cache_key: true }. A nav
# event for one tile evicts only routes crossing that tile instead of clearing
# the whole town's route cache.
var route_cache_tiles := {}
var route_cache_tile_index := {}
var route_cache_invalidations_this_frame := 0
var route_cache_tile_evictions_this_frame := 0
var published_navmesh_tile_keys := {}
var empty_navmesh_tile_keys := {}
var queued_navmesh_tile_source_keys := {}
var queued_navmesh_tile_priority_keys := {}
var queued_navmesh_tile_contexts := {}
var queued_navmesh_tile_keys: Array[String] = []
var queued_navmesh_tile_sequence := 0
var last_navmesh_tile_queue_debug: Array[Dictionary] = []

func setup(system_node, main_node, navigation_world) -> void:
	system = system_node
	main = main_node
	world = navigation_world
	backend_config = NavigationBackendConfigScript.from_environment()
	navmesh_world = _navmesh_world_from_system()
	navmesh_planner = NavmeshRoutePlannerScript.new()
	navmesh_planner.setup(navmesh_world, system, main, world)
	nav_data_readiness = NavDataReadinessServiceScript.new()
	nav_data_readiness.setup(self)

func performance_monitor():
	return main.get("runtime_perf_monitor") if main != null else null

func begin_frame() -> void:
	route_budget_tick += 1
	route_cache_invalidations_this_frame = 0
	route_cache_tile_evictions_this_frame = 0
	navmesh_tile_publish_work_this_frame = false
	var priority_tiles_waiting := not queued_navmesh_tile_priority_keys.is_empty()
	var background_queue_due := route_budget_tick % BACKGROUND_NAVMESH_TILE_PUBLISH_FRAME_INTERVAL == 0
	if BACKGROUND_NAVMESH_TILE_PUBLISHES_PER_FRAME > 0 and priority_tiles_waiting:
		var foreground_processed := _process_queued_navmesh_tile_publishes(ACTIVE_JOB_NAVMESH_TILE_FOREGROUND_PUBLISHES_PER_FRAME, ACTIVE_JOB_NAVMESH_TILE_FOREGROUND_USEC_BUDGET, true, true)
		var remaining_priority_tiles := maxi(0, PRIORITY_NAVMESH_TILE_PUBLISHES_PER_FRAME - foreground_processed)
		var priority_processed := 0
		if remaining_priority_tiles > 0 and not queued_navmesh_tile_priority_keys.is_empty():
			var remaining_usec := PRIORITY_NAVMESH_TILE_POST_FOREGROUND_USEC_BUDGET if foreground_processed > 0 else PRIORITY_NAVMESH_TILE_PUBLISH_USEC_BUDGET
			priority_processed = _process_queued_navmesh_tile_publishes(remaining_priority_tiles, remaining_usec, false, false)
		if foreground_processed + priority_processed > 0:
			_sync_navmesh_after_queued_tile_publish()
	elif BACKGROUND_NAVMESH_TILE_PUBLISHES_PER_FRAME > 0 and background_queue_due:
		if _background_navmesh_tile_publish_should_wait():
			var monitor = performance_monitor()
			if monitor != null:
				monitor.increment_counter("navmesh_tile_publish_queue_deferred_frame_work")
				monitor.increment_counter("queued_navmesh_tile_depth", queued_navmesh_tile_keys.size())
		else:
			var background_processed := _process_queued_navmesh_tile_publishes(BACKGROUND_NAVMESH_TILE_PUBLISHES_PER_FRAME, BACKGROUND_NAVMESH_TILE_PUBLISH_USEC_BUDGET)
			if background_processed > 0:
				_sync_navmesh_after_queued_tile_publish()

func invalidate() -> void:
	route_cache.clear()
	route_cache_order.clear()
	route_cache_tiles.clear()
	route_cache_tile_index.clear()
	published_navmesh_tile_keys.clear()
	empty_navmesh_tile_keys.clear()
	queued_navmesh_tile_source_keys.clear()
	queued_navmesh_tile_priority_keys.clear()
	queued_navmesh_tile_contexts.clear()
	queued_navmesh_tile_keys.clear()
	queued_navmesh_tile_sequence = 0

func plan_route(entry: Dictionary, intent: Dictionary) -> Dictionary:
	if navmesh_planner == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner = NavmeshRoutePlannerScript.new()
		navmesh_planner.setup(navmesh_world, system, main, world)
	elif navmesh_world == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner.setup(navmesh_world, system, main, world)
	if world == null:
		return route_failure("blocked", "missing_world", intent.get("targetCell", Vector2i(999999, 999999)))
	var monitor = performance_monitor()
	var cache_key_start: int = monitor.begin_section("route_cache_key") if monitor != null else Time.get_ticks_usec()
	var cache_key := _route_cache_key(entry, intent)
	if monitor != null:
		monitor.end_section("route_cache_key", cache_key_start)
	var force_replan := bool(entry.get("routeForceReplan", false))
	if not force_replan and route_cache.has(cache_key):
		if monitor != null:
			monitor.increment_counter("route_cache_hits")
		return _copy_cached_route(route_cache[cache_key])
	if monitor != null:
		monitor.increment_counter("route_cache_misses")
	var generated_section := ""
	if generated_section == "" and _routine_route_should_wait_after_navmesh_tile_publish(entry, intent):
		if monitor != null:
			monitor.increment_counter("route_jobs_pending")
			monitor.increment_counter("navmesh_tile_publish_frame_route_yields")
		var publish_frame_failure := route_failure("pending", "navmesh_tile_publish_frame_budget", intent.get("targetCell", Vector2i(999999, 999999)))
		publish_frame_failure["intentKind"] = String(intent.get("kind", ""))
		publish_frame_failure["intentPriority"] = int(intent.get("priority", 0))
		return publish_frame_failure
	var budget_start: int = monitor.begin_section("route_budget_claim") if monitor != null else Time.get_ticks_usec()
	if not _claim_route_budget(entry, intent):
		if monitor != null:
			monitor.end_section("route_budget_claim", budget_start)
			monitor.increment_counter("route_jobs_pending")
		var failure := route_failure("pending", "route_budget", intent.get("targetCell", Vector2i(999999, 999999)))
		failure["intentKind"] = String(intent.get("kind", ""))
		failure["intentPriority"] = int(intent.get("priority", 0))
		failure["routeBudgetWaitFrames"] = int(entry.get("routeBudgetWaitFrames", 0))
		return failure
	if monitor != null:
		monitor.end_section("route_budget_claim", budget_start)
	var tile_prepare_start: int = monitor.begin_section("navmesh_route_tile_prepare") if monitor != null else Time.get_ticks_usec()
	var readiness: Dictionary = nav_data_readiness.ensure_ready_for_route(entry, intent) if nav_data_readiness != null else { "ready": _ensure_navmesh_route_tiles(entry, intent), "reason": "navmesh_tile_budget" }
	if not bool(readiness.get("ready", false)):
		if monitor != null:
			monitor.end_section("navmesh_route_tile_prepare", tile_prepare_start)
			monitor.increment_counter("route_jobs_pending")
		var failure := route_failure("pending", String(readiness.get("reason", "navmesh_tile_budget")), intent.get("targetCell", Vector2i(999999, 999999)))
		failure["intentKind"] = String(intent.get("kind", ""))
		failure["intentPriority"] = int(intent.get("priority", 0))
		failure["navDataReadiness"] = readiness
		return failure
	if monitor != null:
		monitor.end_section("navmesh_route_tile_prepare", tile_prepare_start)
	if navmesh_world != null and navmesh_world.has_method("sync_navigation_map_if_dirty"):
		var sync_start: int = monitor.begin_section("navmesh_map_sync") if monitor != null else Time.get_ticks_usec()
		navmesh_world.sync_navigation_map_if_dirty()
		if monitor != null:
			monitor.end_section("navmesh_map_sync", sync_start)
	var navmesh_start: int = monitor.begin_section("navmesh_route_query") if monitor != null else Time.get_ticks_usec()
	var result: Dictionary = navmesh_planner.plan_runtime_route(entry, intent, world, 0)
	_annotate_route_intent(result, intent)
	if _should_try_exact_collision_lattice_route(entry, result, intent):
		var lattice_result := _plan_exact_collision_lattice_route(entry, intent, result, "exact_collision_lattice")
		if not lattice_result.is_empty() and bool(lattice_result.get("ok", false)):
			result = lattice_result
			_annotate_route_intent(result, intent)
	if _should_try_static_collision_repair(result, intent):
		var repaired_result := plan_probe_repair_route(entry, intent, result, _static_collision_repair_certificate(result))
		if not repaired_result.is_empty() and bool(repaired_result.get("ok", false)):
			result = repaired_result
			_annotate_route_intent(result, intent)
	if monitor != null:
		var navmesh_duration: float = monitor.end_section("navmesh_route_query", navmesh_start)
		monitor.observe_duration("route_planning", navmesh_duration)
		monitor.increment_counter("navmesh_route_queries")
		if bool(result.get("ok", false)):
			monitor.increment_counter("navmesh_route_successes")
		else:
			monitor.increment_counter("navmesh_route_failures")
		if String(result.get("status", "")) == "pending":
			monitor.increment_counter("route_jobs_pending")
		else:
			monitor.increment_counter("route_jobs_completed")
	if String(result.get("status", "")) != "pending":
		_store_route_cache(cache_key, result)
	return result

func _should_try_static_collision_repair(route: Dictionary, intent: Dictionary) -> bool:
	return false

func _should_try_exact_collision_lattice_route(_entry: Dictionary, route: Dictionary, intent: Dictionary) -> bool:
	if bool(route.get("ok", false)):
		return false
	if String(route.get("status", "")) != "blocked":
		return false
	if not (String(route.get("reason", "")) in EXACT_HOME_COLLISION_LATTICE_RECOVERABLE_REASONS):
		return false
	var route_kind := String(intent.get("kind", "move"))
	if route_kind == "scripted":
		return int(intent.get("priority", 0)) >= 180 and bool(intent.get("strictArrival", false))
	return false

func _static_collision_repair_certificate(route: Dictionary) -> Dictionary:
	var validation: Dictionary = route.get("validation", {}) if route.get("validation", {}) is Dictionary else {}
	if validation.is_empty() and route.get("navmeshRoute", {}) is Dictionary:
		var navmesh_route: Dictionary = route.get("navmeshRoute", {})
		validation = navmesh_route.get("validation", {}) if navmesh_route.get("validation", {}) is Dictionary else {}
	var blocked_cell := _valid_repair_cell(validation.get("blockerCell", Vector2i(999999, 999999)))
	if blocked_cell == Vector2i(999999, 999999):
		blocked_cell = _valid_repair_cell(validation.get("toCell", Vector2i(999999, 999999)))
	if blocked_cell == Vector2i(999999, 999999):
		blocked_cell = _valid_repair_cell(validation.get("fromCell", Vector2i(999999, 999999)))
	return {
		"ok": false,
		"status": "blocked",
		"reason": String(route.get("reason", "path_crosses_static_collision")),
		"authoritative": true,
		"sampleCount": 0,
		"details": {
			"cell": blocked_cell,
			"blockType": String(validation.get("blockType", "")),
			"transitionReason": String(validation.get("transitionReason", "")),
			"segmentIndex": int(validation.get("segmentIndex", -1))
		}
	}

func _valid_repair_cell(value) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Dictionary:
		return Vector2i(int((value as Dictionary).get("x", 999999)), int((value as Dictionary).get("z", (value as Dictionary).get("y", 999999))))
	if value is Array and (value as Array).size() >= 2:
		var array_value: Array = value
		return Vector2i(int(array_value[0]), int(array_value[1]))
	return Vector2i(999999, 999999)

func plan_probe_repair_route(entry: Dictionary, intent: Dictionary, failed_route: Dictionary, probe_certificate: Dictionary) -> Dictionary:
	if navmesh_planner == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner = NavmeshRoutePlannerScript.new()
		navmesh_planner.setup(navmesh_world, system, main, world)
	elif navmesh_world == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner.setup(navmesh_world, system, main, world)
	if navmesh_planner == null or navmesh_world == null or world == null:
		return {}
	if not world.has_method("world_cell") or not world.has_method("cell_position"):
		return {}
	var target: Vector3 = intent.get("target", Vector3.ZERO)
	var target_cell: Vector2i = intent.get("targetCell", world.world_cell(target))
	var body := entry.get("body") as Node3D
	var start: Vector3 = body.global_position if body != null else entry.get("position", entry.get("porchPosition", target))
	var start_cell: Vector2i = world.world_cell(start)
	var repair_intent := intent.duplicate(true)
	repair_intent["allowPartial"] = true
	repair_intent["probeRepair"] = true
	repair_intent["probeBlockedCell"] = _probe_blocked_cell(probe_certificate)
	repair_intent["blockedRepairCells"] = _probe_blocked_repair_cells(probe_certificate)
	repair_intent["fallbackCells"] = _probe_repair_fallback_cells(entry, repair_intent, target, target_cell, probe_certificate)
	if (repair_intent.get("fallbackCells", []) as Array).is_empty():
		_record_probe_repair_failure(failed_route, "no_repair_candidates", repair_intent.get("fallbackCells", []))
		return {}
	var forbidden_private_door_ids: Array[String] = world.forbidden_private_door_portal_ids_for_entry(entry) if world.has_method("forbidden_private_door_portal_ids_for_entry") else []
	var repair_world = _generated_world_for_repair()
	var repair_route := {}
	repair_route = navmesh_planner._plan_fallback_cell_route(entry, repair_intent, repair_world, start, start_cell, target_cell, failed_route, forbidden_private_door_ids)
	if repair_route.is_empty() or not bool(repair_route.get("ok", false)):
		_record_probe_repair_failure(failed_route, "no_repair_route", repair_intent.get("fallbackCells", []))
		return {}
	_annotate_route_intent(repair_route, intent)
	repair_route["probeRepair"] = {
		"reason": String(probe_certificate.get("reason", "route_repair")),
		"blockedCell": _probe_blocked_cell(probe_certificate),
		"blockedType": String(((probe_certificate.get("details", {}) as Dictionary) if probe_certificate.get("details", {}) is Dictionary else {}).get("blockType", "")),
		"candidateCount": (repair_intent.get("fallbackCells", []) as Array).size()
	}
	if String(repair_route.get("reason", "")) == "":
		repair_route["reason"] = "probe_collision_repair"
	return repair_route

func _generated_world_for_repair():
	if world != null and world.has_method("generated_navigation_adapter"):
		var generated_world = world.generated_navigation_adapter()
		if generated_world != null:
			return generated_world
	return world

func _plan_collision_lattice_repair_route(entry: Dictionary, repair_intent: Dictionary, failed_route: Dictionary, start_cell: Vector2i, target_cell: Vector2i) -> Dictionary:
	return {}

func _should_try_exact_home_collision_lattice_route(entry: Dictionary, route: Dictionary, intent: Dictionary) -> bool:
	return false

func _intent_uses_exact_home_collision_lattice(entry: Dictionary, intent: Dictionary) -> bool:
	var route_kind := String(intent.get("kind", "move"))
	if bool(intent.get("movingHome", false)) or route_kind == "home":
		return true
	return _is_physical_home_egress_route(entry, intent)

func _is_physical_home_egress_route(entry: Dictionary, intent: Dictionary, source_override = null) -> bool:
	var route_kind := String(intent.get("kind", "move"))
	if not (route_kind in ["work", "forage", "job", "guard", "move", "idle"]):
		return false
	var source = source_override if source_override != null else _generated_world_for_repair()
	if source == null or not source.has_method("world_cell"):
		return false
	var target: Vector3 = intent.get("target", Vector3.ZERO)
	var target_cell: Vector2i = intent.get("targetCell", source.world_cell(target))
	var start_position := _route_start_position(entry, intent, source)
	var start_cell: Vector2i = source.world_cell(start_position)
	if not _cell_is_private_home_edge(entry, start_cell):
		return false
	var porch_cell := _entry_cell(entry, "porchCell", Vector2i(999999, 999999))
	var door_cell := _entry_cell(entry, "doorCell", Vector2i(999999, 999999))
	return _cell_distance(target_cell, porch_cell) <= 3 or _cell_distance(target_cell, door_cell) <= 3

func _route_start_position(entry: Dictionary, intent: Dictionary, source) -> Vector3:
	var target: Vector3 = intent.get("target", Vector3.ZERO)
	var body := entry.get("body") as Node3D
	if body != null and is_instance_valid(body):
		return body.global_position if body.is_inside_tree() else body.position
	if entry.get("position", null) is Vector3:
		return entry.get("position")
	return entry.get("porchPosition", target)

func _cell_is_private_home_edge(entry: Dictionary, cell: Vector2i) -> bool:
	var home_cell := _entry_cell(entry, "homeCell", cell)
	var porch_cell := _entry_cell(entry, "porchCell", home_cell)
	var door_cell := _entry_cell(entry, "doorCell", Vector2i(999999, 999999))
	var interior_min := _entry_cell(entry, "interiorMinCell", home_cell)
	var interior_max := _entry_cell(entry, "interiorMaxCell", home_cell)
	if cell == porch_cell:
		return true
	if door_cell != Vector2i(999999, 999999) and cell == door_cell:
		return true
	return cell.x >= mini(interior_min.x, interior_max.x) \
		and cell.x <= maxi(interior_min.x, interior_max.x) \
		and cell.y >= mini(interior_min.y, interior_max.y) \
		and cell.y <= maxi(interior_min.y, interior_max.y)

func _entry_cell(entry: Dictionary, key: String, fallback: Vector2i) -> Vector2i:
	var value = entry.get(key, fallback)
	if value is Vector2i:
		return value
	if value is Vector3i:
		var cell3: Vector3i = value
		return Vector2i(cell3.x, cell3.z)
	if value is Dictionary:
		var dictionary: Dictionary = value
		return Vector2i(int(dictionary.get("x", fallback.x)), int(dictionary.get("z", dictionary.get("y", fallback.y))))
	if value is Array and (value as Array).size() >= 2:
		var array_value: Array = value
		return Vector2i(int(array_value[0]), int(array_value[1]))
	return fallback

func _cell_distance(a: Vector2i, b: Vector2i) -> int:
	if a == Vector2i(999999, 999999) or b == Vector2i(999999, 999999):
		return 2147483647
	return absi(a.x - b.x) + absi(a.y - b.y)

func _plan_exact_home_collision_lattice_route(entry: Dictionary, intent: Dictionary, failed_route: Dictionary) -> Dictionary:
	return _plan_exact_collision_lattice_route(entry, intent, failed_route, "exact_collision_lattice_home", true)

func _plan_exact_collision_lattice_route(entry: Dictionary, intent: Dictionary, failed_route: Dictionary, success_reason := "exact_collision_lattice", force_moving_home = null) -> Dictionary:
	var source = _generated_world_for_repair()
	if source == null \
		or not source.has_method("world_cell") \
		or not source.has_method("cell_position") \
		or not source.has_method("cell_transition_pathable"):
		_record_exact_collision_lattice_failure(failed_route, {
			"ok": false,
			"reason": "missing_collision_lattice_world"
		})
		return {}
	var target: Vector3 = intent.get("target", Vector3.ZERO)
	var target_cell: Vector2i = intent.get("targetCell", source.world_cell(target))
	var body := entry.get("body") as Node3D
	var start: Vector3 = entry.get("position", entry.get("porchPosition", target))
	if body != null and is_instance_valid(body):
		start = body.global_position if body.is_inside_tree() else body.position
	var start_cell: Vector2i = source.world_cell(start)
	var allow_outside := bool(intent.get("allowOutside", false))
	var moving_home := bool(intent.get("movingHome", false))
	if force_moving_home != null:
		moving_home = bool(force_moving_home)
	var physical_home_egress := _is_physical_home_egress_route(entry, intent, source)
	var target_lookup := { target_cell: true, "_strictTargetCollision": true }
	var bounds := _exact_collision_lattice_bounds(entry, start_cell, target_cell)
	var snapshot := _exact_collision_lattice_snapshot(source, entry, allow_outside, moving_home, bounds)
	if snapshot.is_empty():
		_record_exact_collision_lattice_failure(failed_route, {
			"ok": false,
			"reason": "missing_collision_snapshot"
		})
		return {}
	if source.has_method("cell_is_static_standable_goal"):
		if not bool(source.cell_is_static_standable_goal(entry, target_cell, allow_outside, moving_home)):
			_record_exact_collision_lattice_failure(failed_route, {
				"ok": false,
				"reason": "target_not_static_standable",
				"targetCell": target_cell
			})
			return {}
	var search: Dictionary = _exact_collision_lattice_search(entry, source, snapshot, start_cell, target_cell, target_lookup, bounds)
	if not bool(search.get("ok", false)):
		_record_exact_collision_lattice_failure(failed_route, search)
		return {}
	var cells: Array[Vector2i] = search.get("cells", [])
	var validation: Dictionary = _exact_collision_lattice_validate(entry, source, snapshot, cells, target_lookup)
	if not bool(validation.get("ok", false)):
		search["validation"] = validation
		search["ok"] = false
		search["reason"] = String(validation.get("reason", "collision_lattice_validation_failed"))
		_record_exact_collision_lattice_failure(failed_route, search)
		return {}
	if cells.size() <= 1:
		return {
			"ok": true,
			"status": "arrived",
			"reason": "",
			"cells": [],
			"waypoints": [],
			"actions": {},
			"targetCell": target_cell,
			"fallbackCell": target_cell,
			"snapshotRevision": String(snapshot.get("revision", "")),
			"source": "collision_lattice",
			"legacyFallbackUsed": false,
			"requiresAuthorityProbe": true,
			"navmeshRoute": failed_route.duplicate(true),
			"exactCollisionLatticeRoute": _exact_collision_lattice_debug_with_egress(search, physical_home_egress)
		}
	var waypoints: Array[Vector3] = []
	var start_center: Vector3 = source.cell_position(start_cell)
	var prepend_start_center := _exact_collision_lattice_should_prepend_start_center(start, start_center, cells)
	if prepend_start_center:
		waypoints.append(start_center)
	for index in range(1, cells.size()):
		waypoints.append(source.cell_position(cells[index]))
	var route_cells: Array = cells.slice(1)
	var actions := _collision_lattice_door_actions(entry, source, snapshot, cells)
	var debug := search.duplicate(true)
	debug["exactTarget"] = true
	debug["validation"] = validation
	debug["startClearanceWaypoint"] = prepend_start_center
	debug["startClearanceCell"] = start_cell
	debug["startPosition"] = start
	debug["startCenter"] = start_center
	debug["startCenterDistance"] = Vector2(start.x - start_center.x, start.z - start_center.z).length()
	debug["physicalHomeEgress"] = physical_home_egress
	return {
		"ok": true,
		"status": "routed",
		"reason": success_reason,
		"cells": route_cells,
		"waypoints": waypoints,
		"actions": actions,
		"targetCell": target_cell,
		"fallbackCell": target_cell,
		"snapshotRevision": String(snapshot.get("revision", "")),
		"source": "collision_lattice",
		"legacyFallbackUsed": false,
		"requiresAuthorityProbe": true,
		"navmeshRoute": failed_route.duplicate(true),
		"exactCollisionLatticeRoute": debug
	}

func _exact_collision_lattice_debug_with_egress(debug: Dictionary, physical_home_egress: bool) -> Dictionary:
	var result := debug.duplicate(true)
	result["physicalHomeEgress"] = physical_home_egress
	return result

func _exact_collision_lattice_snapshot(source, entry: Dictionary, allow_outside := false, moving_home := true, bounds: Dictionary = {}) -> Dictionary:
	if source.has_method("collision_snapshot_for_bounds"):
		var bounded_snapshot = source.collision_snapshot_for_bounds(entry, bounds, allow_outside, moving_home)
		if bounded_snapshot is Dictionary and not (bounded_snapshot as Dictionary).is_empty():
			return bounded_snapshot
	if source.has_method("cached_static_tile_snapshot"):
		return source.cached_static_tile_snapshot(allow_outside, moving_home)
	if source.has_method("cached_validation_snapshot"):
		return source.cached_validation_snapshot(entry, allow_outside, moving_home)
	if source.has_method("build_snapshot"):
		return source.build_snapshot(entry, allow_outside, moving_home)
	return {}

func _exact_collision_lattice_bounds(entry: Dictionary, start_cell: Vector2i, target_cell: Vector2i) -> Dictionary:
	var min_x := mini(start_cell.x, target_cell.x)
	var max_x := maxi(start_cell.x, target_cell.x)
	var min_z := mini(start_cell.y, target_cell.y)
	var max_z := maxi(start_cell.y, target_cell.y)
	for cell_value in [
		entry.get("doorCell", Vector2i(999999, 999999)),
		entry.get("porchCell", Vector2i(999999, 999999)),
		entry.get("homeCell", Vector2i(999999, 999999)),
		entry.get("interiorMinCell", Vector2i(999999, 999999)),
		entry.get("interiorMaxCell", Vector2i(999999, 999999))
	]:
		if not (cell_value is Vector2i):
			continue
		var cell: Vector2i = cell_value
		if cell == Vector2i(999999, 999999):
			continue
		min_x = mini(min_x, cell.x)
		max_x = maxi(max_x, cell.x)
		min_z = mini(min_z, cell.y)
		max_z = maxi(max_z, cell.y)
	return {
		"minX": min_x - EXACT_HOME_COLLISION_LATTICE_MARGIN_CELLS,
		"maxX": max_x + EXACT_HOME_COLLISION_LATTICE_MARGIN_CELLS,
		"minZ": min_z - EXACT_HOME_COLLISION_LATTICE_MARGIN_CELLS,
		"maxZ": max_z + EXACT_HOME_COLLISION_LATTICE_MARGIN_CELLS
	}

func _exact_collision_lattice_search(entry: Dictionary, source, snapshot: Dictionary, start_cell: Vector2i, target_cell: Vector2i, target_lookup: Dictionary, bounds: Dictionary) -> Dictionary:
	var search_start_usec := Time.get_ticks_usec()
	var open: Array[Vector2i] = [start_cell]
	var closed := {}
	var came_from := {}
	var g_score := { start_cell: 0 }
	var blocked_reasons := {}
	var directions: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while not open.is_empty() and closed.size() < EXACT_HOME_COLLISION_LATTICE_MAX_VISITS:
		if closed.size() > 0 and Time.get_ticks_usec() - search_start_usec >= EXACT_HOME_COLLISION_LATTICE_MAX_USEC:
			return {
				"ok": false,
				"reason": "exact_collision_lattice_time_budget",
				"visited": closed.size(),
				"maxVisits": EXACT_HOME_COLLISION_LATTICE_MAX_VISITS,
				"maxUsec": EXACT_HOME_COLLISION_LATTICE_MAX_USEC,
				"blockedReasons": blocked_reasons
			}
		var best_index := _exact_collision_lattice_best_open_index(open, g_score, target_cell)
		var cell := open[best_index]
		open.remove_at(best_index)
		if closed.has(cell):
			continue
		closed[cell] = true
		if cell == target_cell:
			var cells := _exact_collision_lattice_reconstruct_path(came_from, cell)
			return {
				"ok": true,
				"reason": "exact_collision_lattice_home",
				"visited": closed.size(),
				"cells": cells,
				"blockedReasons": blocked_reasons
			}
		for direction in directions:
			var next := cell + direction
			if closed.has(next) or not _exact_collision_lattice_cell_in_bounds(next, bounds):
				continue
			var transition: Dictionary = {}
			if source.has_method("cell_bridge_search_pathable"):
				transition = source.cell_bridge_search_pathable(entry, snapshot, cell, next, target_lookup, true)
			else:
				transition = source.cell_transition_pathable(entry, snapshot, cell, next, target_lookup, true)
			if not bool(transition.get("ok", false)):
				var reason := String(transition.get("reason", "blocked"))
				blocked_reasons[reason] = int(blocked_reasons.get(reason, 0)) + 1
				continue
			var clearance: Dictionary = _exact_collision_lattice_transition_has_clearance(entry, source, snapshot, cell, next)
			if not bool(clearance.get("ok", false)):
				var reason := String(clearance.get("reason", "blocked_static_clearance"))
				blocked_reasons[reason] = int(blocked_reasons.get(reason, 0)) + 1
				continue
			var tentative_g := int(g_score.get(cell, 0)) + 1
			if g_score.has(next) and tentative_g >= int(g_score.get(next, 0)):
				continue
			g_score[next] = tentative_g
			came_from[next] = cell
			if not open.has(next):
				open.append(next)
	return {
		"ok": false,
		"reason": "exact_collision_lattice_visit_budget" if closed.size() >= EXACT_HOME_COLLISION_LATTICE_MAX_VISITS else "no_exact_collision_lattice_route",
		"visited": closed.size(),
		"maxVisits": EXACT_HOME_COLLISION_LATTICE_MAX_VISITS,
		"maxUsec": EXACT_HOME_COLLISION_LATTICE_MAX_USEC,
		"blockedReasons": blocked_reasons
	}

func _exact_collision_lattice_best_open_index(open: Array[Vector2i], g_score: Dictionary, target_cell: Vector2i) -> int:
	var best_index := 0
	var best_f := 2147483647
	var best_h := 2147483647
	var best_g := 2147483647
	for index in range(open.size()):
		var cell := open[index]
		var g := int(g_score.get(cell, 2147483647))
		var h := absi(cell.x - target_cell.x) + absi(cell.y - target_cell.y)
		var f := g + h
		var best_cell := open[best_index]
		if f < best_f \
			or (f == best_f and h < best_h) \
			or (f == best_f and h == best_h and g < best_g) \
			or (f == best_f and h == best_h and g == best_g and (cell.x < best_cell.x or (cell.x == best_cell.x and cell.y < best_cell.y))):
			best_index = index
			best_f = f
			best_h = h
			best_g = g
	return best_index

func _exact_collision_lattice_reconstruct_path(came_from: Dictionary, found_cell: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = [found_cell]
	var cursor := found_cell
	while came_from.has(cursor):
		cursor = came_from[cursor]
		cells.push_front(cursor)
	return cells

func _exact_collision_lattice_validate(entry: Dictionary, source, snapshot: Dictionary, cells: Array[Vector2i], target_lookup: Dictionary) -> Dictionary:
	if cells.size() <= 1:
		return { "ok": true, "reason": "" }
	for index in range(1, cells.size()):
		var from_cell := cells[index - 1]
		var to_cell := cells[index]
		var transition: Dictionary = source.cell_transition_pathable(entry, snapshot, from_cell, to_cell, target_lookup, true)
		if not bool(transition.get("ok", false)):
			transition["ok"] = false
			transition["reason"] = String(transition.get("reason", "exact_collision_lattice_validation_failed"))
			transition["fromCell"] = from_cell
			transition["toCell"] = to_cell
			transition["pathIndex"] = index
			return transition
		var clearance: Dictionary = _exact_collision_lattice_transition_has_clearance(entry, source, snapshot, from_cell, to_cell)
		if not bool(clearance.get("ok", false)):
			clearance["fromCell"] = from_cell
			clearance["toCell"] = to_cell
			clearance["pathIndex"] = index
			return clearance
	return { "ok": true, "reason": "" }

func _exact_collision_lattice_should_prepend_start_center(start_position: Vector3, start_center: Vector3, cells: Array[Vector2i]) -> bool:
	if cells.size() <= 1:
		return false
	return Vector2(start_position.x - start_center.x, start_position.z - start_center.z).length() > EXACT_HOME_COLLISION_LATTICE_START_CENTER_MIN_DISTANCE

func _exact_collision_lattice_transition_has_clearance(entry: Dictionary, source, snapshot: Dictionary, from_cell: Vector2i, to_cell: Vector2i) -> Dictionary:
	var from_position: Vector3 = source.cell_position(from_cell)
	var to_position: Vector3 = source.cell_position(to_cell)
	var records := _exact_collision_lattice_static_records(snapshot, from_cell, to_cell)
	var clearance_radius := _exact_collision_lattice_clearance_radius(entry)
	for record_value in records:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value
		if bool(record.get("isDoor", false)):
			continue
		var node_value = record.get("node", null)
		if node_value != null and not is_instance_valid(node_value):
			continue
		var expansion := maxf(clearance_radius, float(record.get("inflation", 0.0))) + EXACT_HOME_COLLISION_LATTICE_CLEARANCE_EPSILON
		if not _exact_collision_lattice_segment_intersects_record(from_position, to_position, record, expansion):
			continue
		return {
			"ok": false,
			"reason": "blocked_static_clearance",
			"transitionReason": "blocked_static_clearance",
			"blockerCell": record.get("cell", Vector2i(999999, 999999)),
			"blockType": String(record.get("blockType", "")),
			"clearanceRadius": clearance_radius,
			"clearanceExpansion": expansion
		}
	return { "ok": true, "reason": "" }

func _exact_collision_lattice_static_records(snapshot: Dictionary, from_cell: Vector2i, to_cell: Vector2i) -> Array:
	var index: Dictionary = snapshot.get("staticCollisionByCell", {}) if snapshot.get("staticCollisionByCell", {}) is Dictionary else {}
	if index.is_empty():
		return []
	var min_x := mini(from_cell.x, to_cell.x) - 1
	var max_x := maxi(from_cell.x, to_cell.x) + 1
	var min_z := mini(from_cell.y, to_cell.y) - 1
	var max_z := maxi(from_cell.y, to_cell.y) + 1
	var result := []
	var seen := {}
	for z in range(min_z, max_z + 1):
		for x in range(min_x, max_x + 1):
			for record_value in index.get(Vector2i(x, z), []):
				if not (record_value is Dictionary):
					continue
				var record: Dictionary = record_value
				var id := String(record.get("id", ""))
				if id != "":
					if seen.has(id):
						continue
					seen[id] = true
				result.append(record)
	return result

func _exact_collision_lattice_clearance_radius(entry: Dictionary) -> float:
	var radius := NpcConstantsScript.DEFAULT_NPC_RADIUS
	var profile = entry.get("motorProfile", null)
	if profile is Dictionary:
		radius = float((profile as Dictionary).get("capsule_radius", radius))
	elif profile != null:
		var profile_radius = profile.get("capsule_radius")
		if profile_radius != null:
			radius = float(profile_radius)
	return radius + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN

func _exact_collision_lattice_segment_intersects_record(from_position: Vector3, to_position: Vector3, record: Dictionary, expansion: float) -> bool:
	var min_point := Vector2(float(record.get("minX", 0.0)) - expansion, float(record.get("minZ", 0.0)) - expansion)
	var max_point := Vector2(float(record.get("maxX", 0.0)) + expansion, float(record.get("maxZ", 0.0)) + expansion)
	return _exact_collision_lattice_segment_intersects_aabb_2d(Vector2(from_position.x, from_position.z), Vector2(to_position.x, to_position.z), min_point, max_point)

func _exact_collision_lattice_segment_intersects_aabb_2d(from_point: Vector2, to_point: Vector2, min_point: Vector2, max_point: Vector2) -> bool:
	var delta := to_point - from_point
	var t_min := 0.0
	var t_max := 1.0
	if absf(delta.x) < 0.0001:
		if from_point.x < min_point.x or from_point.x > max_point.x:
			return false
	else:
		var tx1 := (min_point.x - from_point.x) / delta.x
		var tx2 := (max_point.x - from_point.x) / delta.x
		t_min = maxf(t_min, minf(tx1, tx2))
		t_max = minf(t_max, maxf(tx1, tx2))
	if absf(delta.y) < 0.0001:
		if from_point.y < min_point.y or from_point.y > max_point.y:
			return false
	else:
		var tz1 := (min_point.y - from_point.y) / delta.y
		var tz2 := (max_point.y - from_point.y) / delta.y
		t_min = maxf(t_min, minf(tz1, tz2))
		t_max = minf(t_max, maxf(tz1, tz2))
	return t_max >= t_min and t_max >= 0.0 and t_min <= 1.0

func _exact_collision_lattice_cell_in_bounds(cell: Vector2i, bounds: Dictionary) -> bool:
	return cell.x >= int(bounds.get("minX", cell.x)) \
		and cell.x <= int(bounds.get("maxX", cell.x)) \
		and cell.y >= int(bounds.get("minZ", cell.y)) \
		and cell.y <= int(bounds.get("maxZ", cell.y))

func _collision_lattice_door_actions(entry: Dictionary, source, snapshot: Dictionary, cells: Array[Vector2i]) -> Dictionary:
	var actions := {}
	if not source.has_method("door_at"):
		return actions
	for index in range(1, cells.size()):
		var from_cell := cells[index - 1]
		var to_cell := cells[index]
		var door = source.door_at(snapshot, to_cell)
		var action_cell := to_cell
		if door == null:
			door = source.door_at(snapshot, from_cell)
			action_cell = from_cell
		if not (door is Node):
			continue
		var portal_id := _collision_lattice_door_portal_id(source, door, action_cell)
		actions["%d,%d" % [action_cell.x, action_cell.y]] = {
			"kind": "door",
			"portalId": portal_id,
			"actionId": "open",
			"cell": action_cell,
			"entryCell": from_cell,
			"entryPosition": source.cell_position(from_cell),
			"exitPosition": source.cell_position(to_cell),
			"direction": _collision_lattice_direction(from_cell, to_cell),
			"navLink": false,
			"requiresSmartObject": true,
			"enabled": true,
			"door": door
		}
	return actions

func _collision_lattice_door_portal_id(source, door: Node, cell: Vector2i) -> String:
	if source != null and source.has_method("_door_portal_id"):
		return String(source.call("_door_portal_id", door, cell))
	if door.has_meta("door_portal_id"):
		return String(door.get_meta("door_portal_id"))
	if door.has_meta("door_group_id"):
		return String(door.get_meta("door_group_id"))
	return "door:%d,0,%d" % [cell.x, cell.y]

func _collision_lattice_direction(from_cell: Vector2i, to_cell: Vector2i) -> String:
	var delta := to_cell - from_cell
	if abs(delta.x) >= abs(delta.y) and delta.x != 0:
		return "x+" if delta.x > 0 else "x-"
	if delta.y != 0:
		return "z+" if delta.y > 0 else "z-"
	return ""

func _record_exact_collision_lattice_failure(route: Dictionary, debug: Dictionary) -> void:
	if route.is_empty():
		return
	route["exactCollisionLatticeRoute"] = debug.duplicate(true)
	if route.get("navmeshRoute", {}) is Dictionary:
		var navmesh_route: Dictionary = route.get("navmeshRoute", {})
		navmesh_route["exactCollisionLatticeRoute"] = debug.duplicate(true)
		route["navmeshRoute"] = navmesh_route

func _probe_repair_prefers_collision_lattice(probe_certificate: Dictionary) -> bool:
	return String(probe_certificate.get("reason", "")) in ["blocked_capsule_probe", "path_endpoint_mismatch"]

func _annotate_route_intent(route: Dictionary, intent: Dictionary) -> void:
	route["intentKind"] = String(intent.get("kind", ""))
	route["intentPriority"] = int(intent.get("priority", 0))
	route["intentMovingHome"] = bool(intent.get("movingHome", false))

func _probe_repair_fallback_cells(entry: Dictionary, intent: Dictionary, target: Vector3, target_cell: Vector2i, probe_certificate: Dictionary) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var blocked_cell := _probe_blocked_cell(probe_certificate)
	var repair_allow_outside := bool(intent.get("allowOutside", false)) or bool(intent.get("movingHome", false))
	_append_porch_side_repair_cells(result, entry, target_cell, blocked_cell, intent)
	for value in intent.get("fallbackCells", []):
		_append_probe_repair_cell(result, value, target_cell, blocked_cell, entry, intent)
	if world != null and world.has_method("approach_cells_for_target"):
		for value in world.approach_cells_for_target(entry, target, repair_allow_outside):
			_append_probe_repair_cell(result, value, target_cell, blocked_cell, entry, intent)
	var porch_cell: Vector2i = entry.get("porchCell", target_cell)
	for offset in [Vector2i(-3, 0), Vector2i(3, 0), Vector2i(-2, -1), Vector2i(2, -1), Vector2i(-2, 1), Vector2i(2, 1), Vector2i(0, 2), Vector2i(0, -2)]:
		_append_probe_repair_cell(result, porch_cell + offset, target_cell, blocked_cell, entry, intent)
	while result.size() > 12:
		result.remove_at(result.size() - 1)
	return result

func _append_porch_side_repair_cells(result: Array[Vector2i], entry: Dictionary, target_cell: Vector2i, blocked_cell: Vector2i, intent: Dictionary) -> void:
	var porch_cell: Vector2i = entry.get("porchCell", target_cell)
	if target_cell != porch_cell:
		return
	var interior_min: Vector2i = entry.get("interiorMinCell", Vector2i(999999, 999999))
	var interior_max: Vector2i = entry.get("interiorMaxCell", Vector2i(999999, 999999))
	if interior_min == Vector2i(999999, 999999) or interior_max == Vector2i(999999, 999999):
		return
	var wall_min := Vector2i(mini(interior_min.x, interior_max.x) - 1, mini(interior_min.y, interior_max.y) - 1)
	var wall_max := Vector2i(maxi(interior_min.x, interior_max.x) + 1, maxi(interior_min.y, interior_max.y) + 1)
	var clearance := 3
	var side_cells: Array[Vector2i] = [
		Vector2i(wall_min.x - clearance, porch_cell.y),
		Vector2i(wall_max.x + clearance, porch_cell.y),
		Vector2i(wall_min.x - clearance, wall_min.y - clearance),
		Vector2i(wall_max.x + clearance, wall_min.y - clearance),
		Vector2i(wall_min.x - 1, porch_cell.y),
		Vector2i(wall_max.x + 1, porch_cell.y),
		Vector2i(wall_min.x - 1, wall_min.y - 1),
		Vector2i(wall_max.x + 1, wall_min.y - 1)
	]
	for cell in side_cells:
		_append_probe_repair_cell(result, cell, target_cell, blocked_cell, entry, intent)

func _append_probe_repair_cell(result: Array[Vector2i], value, target_cell: Vector2i, blocked_cell: Vector2i, entry: Dictionary, intent: Dictionary) -> void:
	if not (value is Vector2i):
		return
	var cell: Vector2i = value
	if cell == target_cell or cell == blocked_cell or result.has(cell):
		return
	if _repair_intent_blocks_cell(intent, cell):
		return
	if _porch_repair_rejects_cell(entry, target_cell, cell):
		return
	if world != null and world.has_method("cell_is_standable_goal"):
		var repair_allow_outside := bool(intent.get("allowOutside", false)) or bool(intent.get("movingHome", false))
		if not bool(world.cell_is_standable_goal(entry, cell, repair_allow_outside, bool(intent.get("movingHome", false)))):
			return
	result.append(cell)

func _repair_intent_blocks_cell(intent: Dictionary, cell: Vector2i) -> bool:
	var blocked_cells = intent.get("blockedRepairCells", [])
	if not (blocked_cells is Array):
		return false
	return (blocked_cells as Array).has(cell)

func _porch_repair_rejects_cell(entry: Dictionary, target_cell: Vector2i, cell: Vector2i) -> bool:
	var porch_cell: Vector2i = entry.get("porchCell", target_cell)
	if target_cell != porch_cell:
		return false
	var door_cell: Vector2i = entry.get("doorCell", Vector2i(999999, 999999))
	if cell == door_cell:
		return true
	var interior_min: Vector2i = entry.get("interiorMinCell", Vector2i(999999, 999999))
	var interior_max: Vector2i = entry.get("interiorMaxCell", Vector2i(999999, 999999))
	if interior_min == Vector2i(999999, 999999) or interior_max == Vector2i(999999, 999999):
		return false
	var wall_min := Vector2i(mini(interior_min.x, interior_max.x) - 1, mini(interior_min.y, interior_max.y) - 1)
	var wall_max := Vector2i(maxi(interior_min.x, interior_max.x) + 1, maxi(interior_min.y, interior_max.y) + 1)
	if cell.x >= wall_min.x and cell.x <= wall_max.x and cell.y >= wall_min.y and cell.y <= wall_max.y:
		return true
	if cell.y == porch_cell.y and cell.x >= wall_min.x and cell.x <= wall_max.x:
		return true
	return cell.x >= mini(interior_min.x, interior_max.x) \
		and cell.x <= maxi(interior_min.x, interior_max.x) \
		and cell.y >= mini(interior_min.y, interior_max.y) \
		and cell.y <= maxi(interior_min.y, interior_max.y)

func _record_probe_repair_failure(route: Dictionary, reason: String, candidates) -> void:
	if route.is_empty():
		return
	var candidate_count := (candidates as Array).size() if candidates is Array else 0
	var repair_debug := {
		"ok": false,
		"reason": reason,
		"candidateCount": candidate_count
	}
	route["probeRepair"] = repair_debug
	if route.get("navmeshRoute", {}) is Dictionary:
		var navmesh_route: Dictionary = route.get("navmeshRoute", {})
		navmesh_route["probeRepair"] = repair_debug
		route["navmeshRoute"] = navmesh_route

func _probe_blocked_cell(probe_certificate: Dictionary) -> Vector2i:
	var details: Dictionary = probe_certificate.get("details", {}) if probe_certificate.get("details", {}) is Dictionary else {}
	var cell_value = details.get("cell", Vector2i(999999, 999999))
	if cell_value is Vector2i:
		return cell_value
	if cell_value is Dictionary:
		return Vector2i(int((cell_value as Dictionary).get("x", 999999)), int((cell_value as Dictionary).get("z", 999999)))
	return Vector2i(999999, 999999)

func _probe_blocked_repair_cells(probe_certificate: Dictionary) -> Array[Vector2i]:
	var blocked_cell := _probe_blocked_cell(probe_certificate)
	var result: Array[Vector2i] = []
	if blocked_cell == Vector2i(999999, 999999):
		return result
	for z in range(-2, 3):
		for x in range(-2, 3):
			result.append(blocked_cell + Vector2i(x, z))
	return result

func _should_try_generated_cell_home_route(entry: Dictionary, intent: Dictionary) -> bool:
	if world == null or navmesh_planner == null:
		return false
	var route_kind := String(intent.get("kind", "move"))
	var moving_home := bool(intent.get("movingHome", false))
	if not moving_home and route_kind not in ["home", "scripted"]:
		return false
	# Returning home is a door/structure route. The generated cell bridge can cut
	# smoothed movement corners through wall blocks even when the discrete cells
	# look pathable, so home routes must wait for prioritized navmesh tiles.
	return false

func _safe_open_terrain_generated_fallback_allowed(entry: Dictionary, intent: Dictionary) -> bool:
	return false

func _should_try_generated_cell_job_route(entry: Dictionary, intent: Dictionary) -> bool:
	return _safe_open_terrain_generated_fallback_allowed(entry, intent)

func _should_try_prebudget_forage_departure_route(entry: Dictionary, intent: Dictionary) -> bool:
	return false

func route_cost(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := CELL * 0.85, approach_cells: Array = [], require_ready := false) -> float:
	if world == null:
		return INF
	if navmesh_planner == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner = NavmeshRoutePlannerScript.new()
		navmesh_planner.setup(navmesh_world, system, main, world)
	elif navmesh_world == null:
		navmesh_world = _navmesh_world_from_system()
		navmesh_planner.setup(navmesh_world, system, main, world)
	var cost_kind := "forage" if require_ready and String(entry.get("job", "")) == "forage" else "job" if require_ready else "cost"
	var cost_priority := maxi(int(entry.get("routePriority", 0)), 90) if require_ready else int(entry.get("routePriority", 0))
	var readiness_intent := {
		"kind": cost_kind,
		"target": target,
		"targetCell": world.world_cell(target),
		"allowOutside": allow_outside,
		"movingHome": moving_home,
		"arrivalRadius": arrival_radius,
		"priority": cost_priority,
		"routeProbe": true
	}
	var readiness: Dictionary = nav_data_readiness.ensure_ready_for_route(entry, readiness_intent) if nav_data_readiness != null else { "ready": _ensure_navmesh_route_tiles(entry, readiness_intent), "reason": "navmesh_tile_budget" }
	if not bool(readiness.get("ready", false)):
		return INF if require_ready else _estimated_route_cost(entry, target)
	return navmesh_planner.route_cost_for_runtime(entry, target, allow_outside, moving_home, arrival_radius, approach_cells, world)

func route_failure(status: String, reason: String, target_cell := Vector2i(999999, 999999)) -> Dictionary:
	return {
		"ok": false,
		"status": status,
		"reason": reason,
		"cells": [],
		"waypoints": [],
		"actions": {},
		"targetCell": target_cell,
		"fallbackCell": Vector2i(999999, 999999),
		"snapshotRevision": ""
	}

func process_navigation_events(events: Array, max_expansions := 128) -> Array[Dictionary]:
	var responses: Array[Dictionary] = []
	if events.is_empty():
		return responses
	var clear_all_cached_routes := false
	for event in events:
		if not (event is Dictionary):
			continue
		var kinds: Array = (event as Dictionary).get("changeKinds", []) if (event as Dictionary).get("changeKinds", []) is Array else []
		var invalidates := _event_invalidates_route_cache(kinds)
		var tile_key := String((event as Dictionary).get("tileKey", ""))
		if tile_key != "" and _event_invalidates_published_navmesh_tile(kinds):
			published_navmesh_tile_keys.erase(tile_key)
			empty_navmesh_tile_keys.erase(tile_key)
		if invalidates:
			if tile_key != "":
				# Tile-scoped: evict only routes that actually cross this tile.
				route_cache_tile_evictions_this_frame += _invalidate_route_cache_for_tile(tile_key)
			else:
				# No tile context (e.g. global semantic change): fall back to a
				# full clear. These events are rare compared to tile publishes.
				clear_all_cached_routes = true
		responses.append({
			"status": "invalidated",
			"reason": "navmesh_revision_changed",
			"event": _navigation_event_summary(event as Dictionary),
			"maxExpansionsIgnored": max_expansions
		})
	if clear_all_cached_routes:
		route_cache_invalidations_this_frame += route_cache.size()
		route_cache.clear()
		route_cache_order.clear()
		route_cache_tiles.clear()
		route_cache_tile_index.clear()
	return responses

func _navigation_event_summary(event: Dictionary) -> Dictionary:
	var kinds: Array = event.get("changeKinds", []) if event.get("changeKinds", []) is Array else []
	return {
		"tileKey": String(event.get("tileKey", "")),
		"revision": int(event.get("revision", 0)),
		"changeKinds": kinds.duplicate(),
		"coalescedCount": int(event.get("coalescedCount", 0))
	}

func _event_invalidates_route_cache(kinds: Array) -> bool:
	return _event_invalidates_published_navmesh_tile(kinds) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_DOOR_STATE) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_SEMANTIC_CHANGED)

func _event_invalidates_published_navmesh_tile(kinds: Array) -> bool:
	return _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_BLOCK_REMOVED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_TERRAIN_EDIT) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_PROP_CREATED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_PROP_REMOVED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_CHUNK_LOADED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_DOOR_REGISTERED) \
		or _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_STRUCTURE_METADATA)

func _event_has_kind(kinds: Array, expected: StringName) -> bool:
	for kind_value in kinds:
		if StringName(kind_value) == expected:
			return true
	return false

func stats() -> Dictionary:
	var result: Dictionary = {}
	result["backend"] = backend_config.to_summary() if backend_config != null else NavigationBackendConfigScript.default_config().to_summary()
	result["activeRoutePressure"] = _active_route_pressure()
	result["liveRouteJobLimit"] = _live_route_job_limit()
	result["navmeshTilePublishLimit"] = _navmesh_tile_publish_limit(0)
	result["queuedNavmeshTiles"] = queued_navmesh_tile_keys.size()
	result["queuedNavmeshTileKeys"] = queued_navmesh_tile_keys.duplicate()
	result["queuedNavmeshPriorityTiles"] = queued_navmesh_tile_priority_keys.size()
	result["queuedNavmeshTileContexts"] = queued_navmesh_tile_contexts.duplicate(true)
	result["lastNavmeshTileQueueDebug"] = last_navmesh_tile_queue_debug.duplicate(true)
	result["routeJobsThisFrame"] = route_jobs_this_frame
	result["navmeshTilePublishesThisFrame"] = navmesh_tile_publishes_this_frame
	result["routeCacheSize"] = route_cache.size()
	result["routeCacheTrackedTiles"] = route_cache_tile_index.size()
	result["routeCacheTileEvictionsThisFrame"] = route_cache_tile_evictions_this_frame
	result["routeCacheFullClearInvalidationsThisFrame"] = route_cache_invalidations_this_frame
	if navmesh_world != null and navmesh_world.has_method("topology_revision_key"):
		result["navmeshTopologyRevision"] = int(String(navmesh_world.topology_revision_key()))
	if nav_data_readiness != null and nav_data_readiness.has_method("stats"):
		result["navDataReadiness"] = nav_data_readiness.stats()
	if navmesh_planner != null and navmesh_planner.has_method("stats"):
		result["navmesh"] = navmesh_planner.stats()
	return result

func _navmesh_world_from_system():
	if system == null:
		return null
	var autonomy = system.get("autonomy_system")
	if autonomy == null:
		return null
	return autonomy.get("navmesh_world")

func _background_navmesh_tile_publish_should_wait() -> bool:
	if queued_navmesh_tile_keys.is_empty():
		return false
	if main == null:
		return false
	var chunk_ms_value = main.get("perf_chunk_ms")
	if (typeof(chunk_ms_value) == TYPE_FLOAT or typeof(chunk_ms_value) == TYPE_INT) and float(chunk_ms_value) >= BACKGROUND_NAVMESH_TILE_MAX_CHUNK_FRAME_MS:
		return true
	var hostile_ms_value = main.get("perf_hostiles_ms")
	if (typeof(hostile_ms_value) == TYPE_FLOAT or typeof(hostile_ms_value) == TYPE_INT) and float(hostile_ms_value) >= BACKGROUND_NAVMESH_TILE_MAX_HOSTILE_FRAME_MS:
		return true
	return false

func _ensure_navmesh_route_tiles(entry: Dictionary, intent: Dictionary) -> bool:
	if world == null or navmesh_world == null:
		return true
	if not world.has_method("route_navmesh_tile_keys") or not world.has_method("build_navmesh_tile_snapshot"):
		return true
	var body := entry.get("body") as Node3D
	var target: Vector3 = intent.get("target", body.global_position if body != null else Vector3.ZERO)
	var start: Vector3 = body.global_position if body != null else entry.get("position", entry.get("porchPosition", target))
	var allow_outside := bool(intent.get("allowOutside", false))
	var moving_home := bool(intent.get("movingHome", false))
	var start_cell: Vector2i = world.world_cell(start) if world.has_method("world_cell") else Vector2i(roundi(start.x / CELL), roundi(start.z / CELL))
	var target_cell: Vector2i = intent.get("targetCell", world.world_cell(target) if world.has_method("world_cell") else Vector2i(roundi(target.x / CELL), roundi(target.z / CELL)))
	var endpoint_tile_keys := _endpoint_navmesh_tile_keys(start_cell, target_cell)
	var route_kind := String(intent.get("kind", "move"))
	var priority := maxi(int(intent.get("priority", 0)), int(entry.get("routePriority", 0)))
	var priority_scripted_route := route_kind == "scripted" and priority >= 180
	var direct_update_move := entry.has("_externalDirectMoveFrame") or entry.has("_standaloneNpcUpdateFrame")
	var cost_route := route_kind == "cost"
	var active_job_route := route_kind in ["forage", "work", "job", "guard"]
	var routine_route := route_kind in ["guard", "work", "forage", "job", "idle", "move"]
	var route_probe := bool(intent.get("routeProbe", false))
	var high_priority_route := priority >= 180
	var home_exit_job_route := active_job_route and bool(entry.get("insideHome", false)) and route_kind in ["work", "forage", "job"]
	# Critical/home/scripted routes must not be held behind every tile in a
	# broad margin-expanded box. Blocking on peripheral tiles turns nav readiness
	# into a guess that a route might need them; the nav query and collision probe
	# are the actual authority for whether the corridor is usable.
	var margin_cells := 0 if moving_home or route_kind in ["home", "scripted"] else 4
	var active_job_route_needs_tiles := active_job_route \
		and (entry.get("pathWaypoints", []) as Array).is_empty() \
		and not _routine_route_is_background(entry, intent)
	var endpoint_scoped_active_route := active_job_route_needs_tiles and not cost_route and not route_probe
	var tile_budget_wait_frames := int(entry.get("navmeshTileBudgetWaitFrames", 0))
	var active_job_route_starved_for_tiles := active_job_route_needs_tiles and tile_budget_wait_frames >= 2
	var active_portal_route := String(entry.get("activeDoorPortalId", "")) != ""
	var critical_route_needs_tiles := moving_home or route_kind in ["home", "scripted"] or high_priority_route or active_portal_route
	var inline_publish_route := not cost_route and direct_update_move
	var burst_publish_route := false
	var monitor = performance_monitor()
	var tile_keys_start: int = monitor.begin_section("navmesh_route_tile_keys") if monitor != null else Time.get_ticks_usec()
	var tile_keys: Array = world.route_navmesh_tile_keys(entry, start, target, allow_outside, moving_home, margin_cells)
	if monitor != null:
		monitor.end_section("navmesh_route_tile_keys", tile_keys_start)
	entry["navmeshRouteTilesStillLoading"] = false
	if endpoint_scoped_active_route:
		tile_keys = []
		for endpoint_tile_key_value in endpoint_tile_keys.keys():
			var endpoint_tile_key := String(endpoint_tile_key_value)
			if endpoint_tile_key != "" and not tile_keys.has(endpoint_tile_key):
				tile_keys.append(endpoint_tile_key)
	elif critical_route_needs_tiles or active_job_route_needs_tiles:
		tile_keys = _route_tiles_with_endpoints_first(tile_keys, endpoint_tile_keys)
	var publish_debug := []
	var published_tile_this_call := false
	var queued_tile_this_call := false
	var queued_endpoint_tile_this_call := false
	var queued_route_tiles_still_loading := false
	var skipped_route_tiles_until_endpoints := false
	var missing_endpoint_tile_keys := {}
	entry["navmeshMissingEndpointTiles"] = []
	entry["navmeshEndpointTilesStillLoading"] = false
	if not inline_publish_route:
		for endpoint_tile_key_value in endpoint_tile_keys.keys():
			var endpoint_tile_key := String(endpoint_tile_key_value)
			var endpoint_source_key := _navmesh_tile_source_key(endpoint_tile_key)
			var endpoint_published_key := "%s|%s" % [endpoint_tile_key, endpoint_source_key]
			if not _navmesh_tile_ready_for_route(endpoint_tile_key, endpoint_published_key):
				missing_endpoint_tile_keys[endpoint_tile_key] = true
	if critical_route_needs_tiles and not inline_publish_route and not missing_endpoint_tile_keys.is_empty():
		var endpoint_publish_count := 0
		for endpoint_tile_key_value in endpoint_tile_keys.keys():
			if endpoint_publish_count >= 2:
				break
			var endpoint_tile_key := String(endpoint_tile_key_value)
			if not missing_endpoint_tile_keys.has(endpoint_tile_key):
				continue
			var endpoint_source_key := _navmesh_tile_source_key(endpoint_tile_key)
			var endpoint_inline_result := _publish_navmesh_tile_inline(endpoint_tile_key, endpoint_source_key, 1)
			publish_debug.append(endpoint_inline_result)
			if not bool(endpoint_inline_result.get("published", false)):
				break
			missing_endpoint_tile_keys.erase(endpoint_tile_key)
			published_tile_this_call = true
			endpoint_publish_count += 1
	for tile_key_value in tile_keys:
		var tile_key := String(tile_key_value)
		if tile_key == "":
			continue
		var source_key := _navmesh_tile_source_key(tile_key)
		var published_key := "%s|%s" % [tile_key, source_key]
		if String(empty_navmesh_tile_keys.get(tile_key, "")) == published_key:
			publish_debug.append({ "tile": tile_key, "status": "cached_empty" })
			continue
		var endpoint_tile := endpoint_tile_keys.has(tile_key)
		var status_start: int = monitor.begin_section("navmesh_tile_status") if monitor != null else Time.get_ticks_usec()
		var tile_status := _navmesh_tile_region_status(tile_key)
		if monitor != null:
			monitor.end_section("navmesh_tile_status", status_start)
		if bool(tile_status.get("installed", false)) and not bool(tile_status.get("dirty", false)) and int(tile_status.get("surfaceCount", 0)) > 0:
			published_navmesh_tile_keys[tile_key] = published_key
			if endpoint_tile:
				missing_endpoint_tile_keys.erase(tile_key)
			publish_debug.append({ "tile": tile_key, "status": "cached", "region": tile_status })
			continue
		if route_probe:
			publish_debug.append({ "tile": tile_key, "status": "probe_missing_ready_tile" })
			entry["lastNavmeshTilePublishDebug"] = publish_debug
			entry["navmeshMissingEndpointTiles"] = _string_keys(missing_endpoint_tile_keys)
			entry["navmeshEndpointTilesStillLoading"] = endpoint_tile or not missing_endpoint_tile_keys.is_empty()
			return false
		if not inline_publish_route:
			if not cost_route:
				if not endpoint_tile and not missing_endpoint_tile_keys.is_empty():
					publish_debug.append({ "tile": tile_key, "status": "skipped_until_endpoint_tiles" })
					skipped_route_tiles_until_endpoints = true
					continue
				var critical_endpoint_force_publish := critical_route_needs_tiles \
					and endpoint_tile \
					and not published_tile_this_call
				var active_job_endpoint_force_publish := active_job_route_needs_tiles \
					and endpoint_tile \
					and not published_tile_this_call \
					and tile_budget_wait_frames >= 1
				if critical_endpoint_force_publish or active_job_endpoint_force_publish:
					var endpoint_inline_budget := 2 if active_job_endpoint_force_publish and tile_budget_wait_frames >= 4 else 1
					var endpoint_inline_result := _publish_navmesh_tile_inline(tile_key, source_key, endpoint_inline_budget)
					publish_debug.append(endpoint_inline_result)
					if bool(endpoint_inline_result.get("published", false)):
						missing_endpoint_tile_keys.erase(tile_key)
						published_tile_this_call = true
						continue
				var critical_route_tile_starved := critical_route_needs_tiles \
					and tile_budget_wait_frames >= 12 \
					and not published_tile_this_call \
					and not navmesh_tile_publish_work_this_frame
				var critical_route_force_publish := critical_route_tile_starved and tile_budget_wait_frames >= 90
				var active_job_route_tile_starved := active_job_route_needs_tiles \
					and tile_budget_wait_frames >= ACTIVE_JOB_NAVMESH_TILE_STARVED_FRAMES \
					and not published_tile_this_call
				var active_job_route_force_publish := active_job_route_tile_starved and tile_budget_wait_frames >= ACTIVE_JOB_NAVMESH_TILE_FORCE_FRAMES
				var can_publish_starved_route_tile := not navmesh_tile_publish_work_this_frame or critical_route_force_publish or active_job_route_force_publish
				if (critical_route_tile_starved or active_job_route_tile_starved) and can_publish_starved_route_tile and (critical_route_force_publish or active_job_route_force_publish or not _background_navmesh_tile_publish_should_wait()):
					var inline_budget := 1 if endpoint_tile or tile_budget_wait_frames >= 24 else 0
					var inline_result := _publish_navmesh_tile_inline(tile_key, source_key, inline_budget)
					publish_debug.append(inline_result)
					if bool(inline_result.get("published", false)):
						if endpoint_tile:
							missing_endpoint_tile_keys.erase(tile_key)
						published_tile_this_call = true
						continue
				var priority_queue := endpoint_tile \
					or active_job_route_needs_tiles \
					or critical_route_needs_tiles \
					or home_exit_job_route \
					or active_job_route_starved_for_tiles
				_enqueue_navmesh_tile_publish(tile_key, source_key, priority_queue, _navmesh_tile_publish_context(entry, intent, start_cell, target_cell, tile_key, "ensure_route_tiles"))
				queued_tile_this_call = true
				queued_route_tiles_still_loading = true
				if endpoint_tile:
					queued_endpoint_tile_this_call = true
				publish_debug.append({ "tile": tile_key, "status": "queued_priority" if priority_queue else "queued_budgeted", "region": tile_status })
			else:
				publish_debug.append({ "tile": tile_key, "status": "cost_skipped_budgeted" })
			continue
		if published_tile_this_call:
			_enqueue_navmesh_tile_publish(tile_key, source_key, true, _navmesh_tile_publish_context(entry, intent, start_cell, target_cell, tile_key, "after_inline_publish"))
			entry["navmeshTileBudgetWaitFrames"] = tile_budget_wait_frames + 1
			publish_debug.append({ "tile": tile_key, "status": "queued_after_inline_publish" })
			entry["lastNavmeshTilePublishDebug"] = publish_debug
			return false
		var extra_publishes := ORDERED_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES if burst_publish_route else COST_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES if cost_route else SCRIPTED_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES if priority_scripted_route else DIRECT_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES if direct_update_move else ACTIVE_JOB_NAVMESH_TILE_EXTRA_PUBLISHES if active_job_route else ROUTINE_ROUTE_NAVMESH_TILE_EXTRA_PUBLISHES if routine_route else 1 if inline_publish_route else 0
		if burst_publish_route and tile_budget_wait_frames >= 2:
			extra_publishes += mini(3, tile_budget_wait_frames / 2)
		if not _claim_navmesh_tile_publish_budget(extra_publishes):
			if monitor != null:
				monitor.increment_counter("navmesh_tile_publish_pending")
			entry["navmeshTileBudgetWaitFrames"] = tile_budget_wait_frames + 1
			publish_debug.append({ "tile": tile_key, "status": "pending_budget" })
			entry["lastNavmeshTilePublishDebug"] = publish_debug
			return false
		var snapshot_start: int = monitor.begin_section("navmesh_tile_snapshot_build") if monitor != null else Time.get_ticks_usec()
		var snapshot: Dictionary = world.build_navmesh_tile_snapshot(tile_key)
		if monitor != null:
			monitor.end_section("navmesh_tile_snapshot_build", snapshot_start)
		if snapshot.is_empty():
			empty_navmesh_tile_keys[tile_key] = published_key
			publish_debug.append({ "tile": tile_key, "status": "empty_snapshot" })
			continue
		var publish_start: int = monitor.begin_section("navmesh_tile_publish") if monitor != null else Time.get_ticks_usec()
		var publish_result: Dictionary = navmesh_world.register_tile_snapshot(snapshot)
		if monitor != null:
			monitor.end_section("navmesh_tile_publish", publish_start)
			monitor.increment_counter("navmesh_route_tiles_published")
		_mark_navmesh_tile_publish_work()
		published_navmesh_tile_keys[tile_key] = published_key
		if endpoint_tile:
			missing_endpoint_tile_keys.erase(tile_key)
		published_tile_this_call = true
		publish_debug.append({
			"tile": tile_key,
			"status": String(publish_result.get("status", "")),
			"surfaces": (snapshot.get("surfaces", []) as Array).size(),
			"doors": (snapshot.get("doorLinks", []) as Array).size(),
			"installed": bool(publish_result.get("installed", false))
		})
	entry["lastNavmeshTilePublishDebug"] = publish_debug
	entry["navmeshMissingEndpointTiles"] = _string_keys(missing_endpoint_tile_keys)
	if skipped_route_tiles_until_endpoints:
		if monitor != null:
			monitor.increment_counter("navmesh_tile_publish_skipped_until_endpoints")
		entry["navmeshTileBudgetWaitFrames"] = tile_budget_wait_frames + 1
		entry["navmeshRouteTilesStillLoading"] = true
		entry["navmeshEndpointTilesStillLoading"] = true
		return false
	if queued_tile_this_call:
		if monitor != null:
			monitor.increment_counter("navmesh_tile_publish_queued_queries")
		if published_tile_this_call:
			_sync_navmesh_after_partial_readiness_publish()
		entry["navmeshTileBudgetWaitFrames"] = tile_budget_wait_frames + 1
		entry["navmeshRouteTilesStillLoading"] = queued_route_tiles_still_loading
		entry["navmeshEndpointTilesStillLoading"] = queued_endpoint_tile_this_call or not missing_endpoint_tile_keys.is_empty()
		if critical_route_needs_tiles and missing_endpoint_tile_keys.is_empty() and not queued_endpoint_tile_this_call:
			entry["navmeshRouteTilesStillLoading"] = false
			entry["navmeshEndpointTilesStillLoading"] = false
			return true
		if home_exit_job_route and missing_endpoint_tile_keys.is_empty() and not queued_endpoint_tile_this_call and not published_tile_this_call:
			entry["navmeshRouteTilesStillLoading"] = false
			entry["navmeshEndpointTilesStillLoading"] = false
			return true
		return false
	if published_tile_this_call and not inline_publish_route:
		if monitor != null:
			monitor.increment_counter("navmesh_tile_publish_deferred_queries")
		# If every required endpoint tile is satisfied and nothing is still
		# queued, the route is ready this frame regardless of whether it is a
		# "critical" (home/scripted/high-priority) route. plan_route calls
		# sync_navigation_map_if_dirty immediately after readiness returns, so a
		# freshly published tile is queryable. Gating this on critical routes
		# meant a guard/worker/forager whose tile is re-published every frame
		# (e.g. a town tile invalidated by chunk streaming near the camera) could
		# stay pending for the entire day window even though its nav data is
		# fully installed.
		if missing_endpoint_tile_keys.is_empty() and not queued_tile_this_call:
			entry["navmeshTileBudgetWaitFrames"] = 0
			entry["navmeshEndpointTilesStillLoading"] = false
			return true
		_sync_navmesh_after_partial_readiness_publish()
		entry["navmeshTileBudgetWaitFrames"] = tile_budget_wait_frames + 1
		return false
	if published_tile_this_call and inline_publish_route and monitor != null:
		monitor.increment_counter("navmesh_tile_publish_inline_ordered_queries")
	entry["navmeshTileBudgetWaitFrames"] = 0
	entry["navmeshMissingEndpointTiles"] = []
	entry["navmeshEndpointTilesStillLoading"] = false
	return true

func _sync_navmesh_after_partial_readiness_publish() -> void:
	if navmesh_world == null or not navmesh_world.has_method("sync_navigation_map_if_dirty"):
		return
	var monitor = performance_monitor()
	var sync_start: int = monitor.begin_section("navmesh_map_partial_readiness_sync") if monitor != null else Time.get_ticks_usec()
	navmesh_world.sync_navigation_map_if_dirty()
	if monitor != null:
		monitor.end_section("navmesh_map_partial_readiness_sync", sync_start)

func _sync_navmesh_after_queued_tile_publish() -> void:
	if navmesh_world == null or not navmesh_world.has_method("sync_navigation_map_if_dirty"):
		return
	var monitor = performance_monitor()
	var sync_start: int = monitor.begin_section("navmesh_map_queued_publish_sync") if monitor != null else Time.get_ticks_usec()
	navmesh_world.sync_navigation_map_if_dirty()
	if monitor != null:
		monitor.end_section("navmesh_map_queued_publish_sync", sync_start)

func _navmesh_tile_region_status(tile_key: String) -> Dictionary:
	if navmesh_world != null and navmesh_world.has_method("tile_region_status"):
		return navmesh_world.tile_region_status(tile_key)
	return {}

func _string_keys(values: Dictionary) -> Array:
	var result := []
	for key in values.keys():
		result.append(String(key))
	return result

func _enqueue_navmesh_tile_publish(tile_key: String, source_key: String, priority := false, context := {}) -> void:
	if tile_key == "" or source_key == "":
		return
	var was_queued := queued_navmesh_tile_source_keys.has(tile_key)
	queued_navmesh_tile_source_keys[tile_key] = source_key
	var previous_context: Dictionary = queued_navmesh_tile_contexts.get(tile_key, {}) if queued_navmesh_tile_contexts.get(tile_key, {}) is Dictionary else {}
	var next_context: Dictionary = (context as Dictionary).duplicate(true) if context is Dictionary and not (context as Dictionary).is_empty() else previous_context.duplicate(true)
	var current_frame := Engine.get_process_frames()
	var sequence := int(previous_context.get("queueSequence", -1))
	if sequence < 0:
		queued_navmesh_tile_sequence += 1
		sequence = queued_navmesh_tile_sequence
	next_context["queueSequence"] = sequence
	next_context["firstQueuedFrame"] = int(previous_context.get("firstQueuedFrame", current_frame))
	next_context["lastQueuedFrame"] = current_frame
	next_context["queueRefreshCount"] = int(previous_context.get("queueRefreshCount", 0)) + (1 if was_queued else 0)
	queued_navmesh_tile_contexts[tile_key] = next_context
	if priority:
		queued_navmesh_tile_priority_keys[tile_key] = true
		if not queued_navmesh_tile_keys.has(tile_key):
			queued_navmesh_tile_keys.append(tile_key)
		_resort_navmesh_tile_queue()
	elif not was_queued:
		queued_navmesh_tile_keys.append(tile_key)

func _resort_navmesh_tile_queue() -> void:
	if queued_navmesh_tile_keys.size() <= 1:
		return
	queued_navmesh_tile_keys.sort_custom(func(a, b) -> bool:
		return _queued_navmesh_tile_precedes(String(a), String(b))
	)

func _queued_navmesh_tile_precedes(a: String, b: String) -> bool:
	var a_priority := queued_navmesh_tile_priority_keys.has(a)
	var b_priority := queued_navmesh_tile_priority_keys.has(b)
	if a_priority != b_priority:
		return a_priority
	var a_rank := _queued_navmesh_tile_rank(a, a_priority)
	var b_rank := _queued_navmesh_tile_rank(b, b_priority)
	if a_rank != b_rank:
		return a_rank > b_rank
	var a_context: Dictionary = queued_navmesh_tile_contexts.get(a, {}) if queued_navmesh_tile_contexts.get(a, {}) is Dictionary else {}
	var b_context: Dictionary = queued_navmesh_tile_contexts.get(b, {}) if queued_navmesh_tile_contexts.get(b, {}) is Dictionary else {}
	return int(a_context.get("queueSequence", 0)) < int(b_context.get("queueSequence", 0))

func _queued_navmesh_tile_rank(tile_key: String, priority_tile := false) -> int:
	var context: Dictionary = queued_navmesh_tile_contexts.get(tile_key, {}) if queued_navmesh_tile_contexts.get(tile_key, {}) is Dictionary else {}
	return _queued_navmesh_tile_rank_for_context(context, priority_tile)

func _queued_navmesh_tile_rank_for_context(context: Dictionary, priority_tile := false) -> int:
	var rank := 0
	if priority_tile:
		rank += 100000
	if bool(context.get("activeJobRoute", false)):
		rank += 50000
	var lod := String(context.get("simulationLod", ""))
	if lod == "active":
		rank += 30000
	elif lod == "nearby":
		rank += 15000
	var actor_id := String(context.get("actorId", ""))
	if actor_id.find(":home:") >= 0:
		rank += 12000
	var intent_kind := String(context.get("intentKind", ""))
	if intent_kind == "forage":
		rank += 5000
	elif intent_kind in ["guard", "work", "job"]:
		rank += 3500
	rank += maxi(0, int(context.get("routePriority", 0))) * 50
	var first_frame := int(context.get("firstQueuedFrame", Engine.get_process_frames()))
	var age := maxi(0, Engine.get_process_frames() - first_frame)
	rank += mini(age, 1200)
	return rank

func _restore_queued_navmesh_tile(tile_key: String, source_key: String, priority_tile: bool, context: Dictionary) -> void:
	if tile_key == "" or source_key == "":
		return
	queued_navmesh_tile_source_keys[tile_key] = source_key
	queued_navmesh_tile_contexts[tile_key] = context.duplicate(true)
	if priority_tile:
		queued_navmesh_tile_priority_keys[tile_key] = true
	else:
		queued_navmesh_tile_priority_keys.erase(tile_key)
	if not queued_navmesh_tile_keys.has(tile_key):
		queued_navmesh_tile_keys.append(tile_key)

func _queued_navmesh_tile_is_active_job_foreground(context: Dictionary, priority_tile := false) -> bool:
	if not priority_tile:
		return false
	if not bool(context.get("activeJobRoute", false)):
		return false
	var actor_id := String(context.get("actorId", ""))
	if actor_id.find(":home:") < 0:
		return false
	var lod := String(context.get("simulationLod", ""))
	return lod == "active" or lod == "nearby"

func _process_queued_navmesh_tile_publishes(max_tiles: int, max_usec := 0, foreground_active_jobs_only := false, reset_debug := true) -> int:
	if max_tiles <= 0 or world == null or navmesh_world == null:
		return 0
	if not world.has_method("build_navmesh_tile_snapshot"):
		return 0
	_resort_navmesh_tile_queue()
	if reset_debug:
		last_navmesh_tile_queue_debug = []
	var processed := 0
	var attempts := queued_navmesh_tile_keys.size()
	var monitor = performance_monitor()
	var started_usec := Time.get_ticks_usec()
	while processed < max_tiles and attempts > 0 and not queued_navmesh_tile_keys.is_empty():
		if max_usec > 0 and Time.get_ticks_usec() - started_usec >= max_usec:
			if monitor != null:
				monitor.increment_counter("navmesh_tile_publish_queue_usec_yields")
			break
		attempts -= 1
		var tile_key := String(queued_navmesh_tile_keys.pop_front())
		var requested_source_key := String(queued_navmesh_tile_source_keys.get(tile_key, ""))
		var priority_tile := queued_navmesh_tile_priority_keys.has(tile_key)
		var context: Dictionary = queued_navmesh_tile_contexts.get(tile_key, {}) if queued_navmesh_tile_contexts.get(tile_key, {}) is Dictionary else {}
		queued_navmesh_tile_source_keys.erase(tile_key)
		queued_navmesh_tile_priority_keys.erase(tile_key)
		queued_navmesh_tile_contexts.erase(tile_key)
		if tile_key == "" or requested_source_key == "":
			continue
		var foreground_candidate := _queued_navmesh_tile_is_active_job_foreground(context, priority_tile)
		var foreground_publish := foreground_active_jobs_only and foreground_candidate
		if foreground_active_jobs_only and not foreground_candidate:
			_restore_queued_navmesh_tile(tile_key, requested_source_key, priority_tile, context)
			if monitor != null:
				monitor.increment_counter("navmesh_tile_publish_foreground_queue_exhausted")
			break
		var source_key := _navmesh_tile_source_key(tile_key)
		if requested_source_key != source_key and monitor != null:
			monitor.increment_counter("navmesh_tile_publish_queue_source_refresh")
		var debug_record := {
			"tile": tile_key,
			"requestedSource": requested_source_key,
			"source": source_key,
			"priority": priority_tile,
			"foreground": foreground_publish,
			"rank": _queued_navmesh_tile_rank_for_context(context, priority_tile),
			"context": context.duplicate(true),
			"status": "started"
		}
		var published_key := "%s|%s" % [tile_key, source_key]
		if String(empty_navmesh_tile_keys.get(tile_key, "")) == published_key:
			debug_record["status"] = "cached_empty"
			_record_navmesh_queue_debug(debug_record)
			continue
		if String(published_navmesh_tile_keys.get(tile_key, "")) == published_key:
			var tile_status := _navmesh_tile_region_status(tile_key)
			if bool(tile_status.get("installed", false)) and not bool(tile_status.get("dirty", false)) and int(tile_status.get("surfaceCount", 0)) > 0:
				debug_record["status"] = "cached"
				debug_record["region"] = tile_status
				_record_navmesh_queue_debug(debug_record)
				continue
		var claimed_publish_budget := _claim_active_job_navmesh_tile_foreground_budget() if foreground_publish else _claim_navmesh_tile_publish_budget(PRIORITY_NAVMESH_TILE_PUBLISHES_PER_FRAME - 1 if priority_tile else 0)
		if not claimed_publish_budget:
			_restore_queued_navmesh_tile(tile_key, requested_source_key, priority_tile, context)
			debug_record["status"] = "budget_denied"
			_record_navmesh_queue_debug(debug_record)
			break
		var snapshot_start: int = monitor.begin_section("navmesh_tile_snapshot_build") if monitor != null else Time.get_ticks_usec()
		var snapshot: Dictionary = world.build_navmesh_tile_snapshot(tile_key)
		if monitor != null:
			monitor.end_section("navmesh_tile_snapshot_build", snapshot_start)
		if snapshot.is_empty():
			empty_navmesh_tile_keys[tile_key] = published_key
			processed += 1
			_mark_navmesh_tile_publish_work()
			debug_record["status"] = "empty_snapshot"
			_record_navmesh_queue_debug(debug_record)
			continue
		var publish_start: int = monitor.begin_section("navmesh_tile_publish") if monitor != null else Time.get_ticks_usec()
		var publish_result: Dictionary = navmesh_world.register_tile_snapshot(snapshot)
		if monitor != null:
			monitor.end_section("navmesh_tile_publish", publish_start)
			monitor.increment_counter("navmesh_route_tiles_published")
			monitor.increment_counter("navmesh_tile_publish_queue_processed")
		published_navmesh_tile_keys[tile_key] = published_key
		processed += 1
		_mark_navmesh_tile_publish_work()
		debug_record["status"] = String(publish_result.get("status", "published"))
		debug_record["surfaces"] = (snapshot.get("surfaces", []) as Array).size()
		debug_record["installed"] = bool(publish_result.get("installed", false))
		_record_navmesh_queue_debug(debug_record)
	return processed

func _record_navmesh_queue_debug(record: Dictionary) -> void:
	last_navmesh_tile_queue_debug.append(record)
	while last_navmesh_tile_queue_debug.size() > 8:
		last_navmesh_tile_queue_debug.pop_front()

func _begin_navmesh_tile_publish_frame() -> void:
	var engine_frame := Engine.get_process_frames()
	if engine_frame == navmesh_tile_publish_engine_frame and navmesh_tile_publish_seen_tick == route_budget_tick:
		return
	navmesh_tile_publish_engine_frame = engine_frame
	navmesh_tile_publish_seen_tick = route_budget_tick
	navmesh_tile_publishes_this_frame = 0
	active_job_navmesh_tile_foreground_publishes_this_frame = 0

func _claim_active_job_navmesh_tile_foreground_budget() -> bool:
	_begin_navmesh_tile_publish_frame()
	if active_job_navmesh_tile_foreground_publishes_this_frame >= ACTIVE_JOB_NAVMESH_TILE_FOREGROUND_PUBLISHES_PER_FRAME:
		var monitor = performance_monitor()
		if monitor != null:
			monitor.increment_counter("navmesh_tile_publish_foreground_budget_yields")
		return false
	active_job_navmesh_tile_foreground_publishes_this_frame += 1
	return true

func _active_route_pressure() -> int:
	if system == null:
		return 0
	var entries_value = system.get("npcs")
	if not (entries_value is Array):
		return 0
	var pressure := 0
	for entry_value in entries_value:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var status := String(entry.get("routeStatus", ""))
		if status in ["moving", "pending", "waiting"]:
			pressure += 1
		elif int(entry.get("routeBudgetWaitFrames", 0)) > 0 or int(entry.get("navmeshTileBudgetWaitFrames", 0)) > 0:
			pressure += 1
	return pressure

func _live_route_job_limit() -> int:
	if not NpcConstantsScript.NPC_NAV_ENABLE_ADAPTIVE_ROUTE_BUDGET:
		return LIVE_ROUTE_JOBS_PER_FRAME
	var pressure := _active_route_pressure()
	var adaptive := ceili(float(pressure) / 4.0)
	return clampi(maxi(LIVE_ROUTE_JOBS_PER_FRAME, adaptive), LIVE_ROUTE_JOBS_PER_FRAME, LIVE_ROUTE_JOBS_MAX_PER_FRAME)

func _navmesh_tile_publish_limit(extra_budget := 0) -> int:
	var base_limit := NAVMESH_TILE_PUBLISHES_PER_FRAME + maxi(0, int(extra_budget))
	if not NpcConstantsScript.NPC_NAV_ENABLE_ADAPTIVE_ROUTE_BUDGET:
		return base_limit
	var queued_pressure := ceili(float(queued_navmesh_tile_keys.size()) / 8.0)
	return clampi(base_limit + queued_pressure, NAVMESH_TILE_PUBLISHES_PER_FRAME, NAVMESH_TILE_PUBLISHES_MAX_PER_FRAME)

func _claim_navmesh_tile_publish_budget(extra_budget := 0) -> bool:
	_begin_navmesh_tile_publish_frame()
	var publish_limit := _navmesh_tile_publish_limit(extra_budget)
	if navmesh_tile_publishes_this_frame >= publish_limit:
		var monitor = performance_monitor()
		if monitor != null:
			monitor.increment_counter("navmesh_tile_publish_budget_yields")
		return false
	navmesh_tile_publishes_this_frame += 1
	return true

func _navmesh_tile_source_key(tile_key: String) -> String:
	if world != null and world.has_method("navmesh_tile_source_key_for_tile"):
		return String(world.navmesh_tile_source_key_for_tile(tile_key))
	if world != null and world.has_method("navmesh_tile_source_key"):
		return String(world.navmesh_tile_source_key())
	return String(world.revision()) if world != null and world.has_method("revision") else ""

func queue_navmesh_tile_publish(tile_key: String, priority := false) -> bool:
	if tile_key == "" or world == null or navmesh_world == null:
		return false
	var source_key := _navmesh_tile_source_key(tile_key)
	if source_key == "":
		return false
	var published_key := "%s|%s" % [tile_key, source_key]
	if String(empty_navmesh_tile_keys.get(tile_key, "")) == published_key:
		return false
	if String(published_navmesh_tile_keys.get(tile_key, "")) == published_key:
		var tile_status := _navmesh_tile_region_status(tile_key)
		if bool(tile_status.get("installed", false)) and not bool(tile_status.get("dirty", false)) and int(tile_status.get("surfaceCount", 0)) > 0:
			return false
	_enqueue_navmesh_tile_publish(tile_key, source_key, priority, { "reason": "external_queue" })
	var monitor = performance_monitor()
	if monitor != null:
		monitor.increment_counter("navmesh_tile_publish_startup_queued")
		monitor.increment_counter("queued_navmesh_tile_depth", queued_navmesh_tile_keys.size())
	return true

const PREBAKE_MAX_TILES := 256

# Publish every navmesh tile covering a square area centred on center_cell with
# the given cell radius, ignoring the per-frame publish budget. Intended to run
# once at load (town spawn) so the static town is fully baked before NPC
# scheduling starts and pending_nav_data stops being the steady state.
func prebake_area_tiles(center_cell: Vector2i, radius_cells: int) -> Dictionary:
	var summary := {
		"published": 0,
		"cachedReady": 0,
		"empty": 0,
		"tiles": 0,
		"ok": false
	}
	if world == null or navmesh_world == null:
		summary["reason"] = "missing_world"
		return summary
	if not world.has_method("build_navmesh_tile_snapshot"):
		summary["reason"] = "missing_snapshot_api"
		return summary
	var radius := maxi(0, radius_cells)
	var min_cell := Vector2i(center_cell.x - radius, center_cell.y - radius)
	var max_cell := Vector2i(center_cell.x + radius, center_cell.y + radius)
	var tile_size: int = maxi(1, NpcConstantsScript.NAV_TILE_CELL_SIZE)
	var min_tile_x := floori(float(min_cell.x) / float(tile_size))
	var max_tile_x := floori(float(max_cell.x) / float(tile_size))
	var min_tile_z := floori(float(min_cell.y) / float(tile_size))
	var max_tile_z := floori(float(max_cell.y) / float(tile_size))
	var processed := 0
	for tile_z in range(min_tile_z, max_tile_z + 1):
		for tile_x in range(min_tile_x, max_tile_x + 1):
			if processed >= PREBAKE_MAX_TILES:
				summary["reason"] = "tile_cap_reached"
				summary["ok"] = true
				return summary
			processed += 1
			summary["tiles"] = processed
			var tile_key := "%d,%d" % [tile_x, tile_z]
			var source_key := _navmesh_tile_source_key(tile_key)
			var published_key := "%s|%s" % [tile_key, source_key]
			if String(empty_navmesh_tile_keys.get(tile_key, "")) == published_key:
				summary["empty"] = int(summary["empty"]) + 1
				continue
			if String(published_navmesh_tile_keys.get(tile_key, "")) == published_key:
				var status := _navmesh_tile_region_status(tile_key)
				if bool(status.get("installed", false)) and not bool(status.get("dirty", false)) and int(status.get("surfaceCount", 0)) > 0:
					summary["cachedReady"] = int(summary["cachedReady"]) + 1
					continue
			var snapshot: Dictionary = world.build_navmesh_tile_snapshot(tile_key)
			if snapshot.is_empty():
				empty_navmesh_tile_keys[tile_key] = published_key
				summary["empty"] = int(summary["empty"]) + 1
				continue
			navmesh_world.register_tile_snapshot(snapshot)
			published_navmesh_tile_keys[tile_key] = published_key
			summary["published"] = int(summary["published"]) + 1
	if navmesh_world.has_method("sync_navigation_map_if_dirty"):
		navmesh_world.sync_navigation_map_if_dirty()
	summary["ok"] = true
	return summary

func _publish_navmesh_tile_inline(tile_key: String, source_key: String, extra_budget: int) -> Dictionary:
	var result := { "tile": tile_key, "status": "pending_budget", "published": false }
	if tile_key == "" or source_key == "" or world == null or navmesh_world == null:
		result["status"] = "missing_context"
		return result
	var monitor = performance_monitor()
	if not _claim_navmesh_tile_publish_budget(extra_budget):
		if monitor != null:
			monitor.increment_counter("navmesh_tile_publish_pending")
		return result
	var snapshot_start: int = monitor.begin_section("navmesh_tile_snapshot_build") if monitor != null else Time.get_ticks_usec()
	var snapshot: Dictionary = world.build_navmesh_tile_snapshot(tile_key)
	if monitor != null:
		monitor.end_section("navmesh_tile_snapshot_build", snapshot_start)
	var published_key := "%s|%s" % [tile_key, source_key]
	if snapshot.is_empty():
		empty_navmesh_tile_keys[tile_key] = published_key
		result["status"] = "empty_snapshot"
		result["published"] = true
		return result
	var publish_start: int = monitor.begin_section("navmesh_tile_publish") if monitor != null else Time.get_ticks_usec()
	var publish_result: Dictionary = navmesh_world.register_tile_snapshot(snapshot)
	if monitor != null:
		monitor.end_section("navmesh_tile_publish", publish_start)
		monitor.increment_counter("navmesh_route_tiles_published")
		monitor.increment_counter("navmesh_tile_publish_inline_endpoint_queries")
	_mark_navmesh_tile_publish_work()
	published_navmesh_tile_keys[tile_key] = published_key
	result["status"] = String(publish_result.get("status", "published"))
	result["published"] = true
	result["surfaces"] = (snapshot.get("surfaces", []) as Array).size()
	result["doors"] = (snapshot.get("doorLinks", []) as Array).size()
	result["installed"] = bool(publish_result.get("installed", false))
	return result

func _mark_navmesh_tile_publish_work() -> void:
	navmesh_tile_publish_work_this_frame = true

func _routine_route_should_wait_after_navmesh_tile_publish(entry: Dictionary, intent: Dictionary) -> bool:
	if not navmesh_tile_publish_work_this_frame:
		return false
	var route_kind := String(intent.get("kind", "move"))
	var priority := maxi(int(intent.get("priority", 0)), int(entry.get("routePriority", 0)))
	if bool(intent.get("movingHome", false)) or route_kind in ["home", "scripted"] or priority >= 180:
		return false
	if String(entry.get("activeDoorPortalId", "")) != "":
		return false
	if entry.has("_externalDirectMoveFrame") or entry.has("_standaloneNpcUpdateFrame"):
		return false
	var active_job_route := route_kind in ["guard", "work", "forage", "job"]
	var current_waypoints: Array = entry.get("pathWaypoints", []) if entry.get("pathWaypoints", []) is Array else []
	if active_job_route and current_waypoints.is_empty():
		return false
	return route_kind in ["guard", "work", "forage", "job", "idle", "move"]

func _navmesh_tile_ready_for_route(tile_key: String, published_key: String) -> bool:
	if tile_key == "" or published_key == "":
		return false
	if String(empty_navmesh_tile_keys.get(tile_key, "")) == published_key:
		return true
	var tile_status := _navmesh_tile_region_status(tile_key)
	if bool(tile_status.get("installed", false)) and not bool(tile_status.get("dirty", false)) and int(tile_status.get("surfaceCount", 0)) > 0:
		published_navmesh_tile_keys[tile_key] = published_key
		return true
	return false

func _endpoint_navmesh_tile_keys(start_cell: Vector2i, target_cell: Vector2i) -> Dictionary:
	var result := {}
	if world != null and world.has_method("tile_key_for_cell"):
		result[String(world.tile_key_for_cell(start_cell))] = true
		result[String(world.tile_key_for_cell(target_cell))] = true
		return result
	var tile_size: int = maxi(1, NpcConstantsScript.NAV_TILE_CELL_SIZE)
	result["%d,%d" % [floori(float(start_cell.x) / float(tile_size)), floori(float(start_cell.y) / float(tile_size))]] = true
	result["%d,%d" % [floori(float(target_cell.x) / float(tile_size)), floori(float(target_cell.y) / float(tile_size))]] = true
	return result

func _route_tiles_with_endpoints_first(tile_keys: Array, endpoint_tile_keys: Dictionary) -> Array:
	if tile_keys.is_empty() or endpoint_tile_keys.is_empty():
		return tile_keys
	var ordered := []
	for tile_key_value in tile_keys:
		var tile_key := String(tile_key_value)
		if tile_key != "" and endpoint_tile_keys.has(tile_key) and not ordered.has(tile_key):
			ordered.append(tile_key)
	for tile_key_value in tile_keys:
		var tile_key := String(tile_key_value)
		if tile_key != "" and not ordered.has(tile_key):
			ordered.append(tile_key)
	return ordered

func _navmesh_tile_publish_context(entry: Dictionary, intent: Dictionary, start_cell: Vector2i, target_cell: Vector2i, tile_key: String, reason: String) -> Dictionary:
	var route_kind := String(intent.get("kind", ""))
	return {
		"actorId": String(entry.get("id", "")),
		"actorName": String(entry.get("name", "")),
		"job": String(entry.get("job", "")),
		"goal": String(entry.get("activeGoalKind", entry.get("goal", ""))),
		"intentKind": route_kind,
		"reason": reason,
		"tile": tile_key,
		"routePriority": maxi(int(intent.get("priority", 0)), int(entry.get("routePriority", 0))),
		"activeJobRoute": route_kind in ["guard", "work", "forage", "job"],
		"movingHome": bool(intent.get("movingHome", false)),
		"allowOutside": bool(intent.get("allowOutside", false)),
		"routeStatus": String(entry.get("routeStatus", "")),
		"routeReason": String(entry.get("routeReason", "")),
		"simulationLod": String(entry.get("simulationLod", "")),
		"insideTown": bool(entry.get("insideTown", false)),
		"insideHome": bool(entry.get("insideHome", false)),
		"townKey": String(entry.get("townKey", "")),
		"routeBudgetWaitFrames": int(entry.get("routeBudgetWaitFrames", 0)),
		"navmeshTileBudgetWaitFrames": int(entry.get("navmeshTileBudgetWaitFrames", 0)),
		"startCell": start_cell,
		"targetCell": target_cell,
		"target": intent.get("target", Vector3.ZERO)
	}

func _estimated_route_cost(entry: Dictionary, target: Vector3) -> float:
	var body := entry.get("body") as Node3D
	var start: Vector3 = body.global_position if body != null else entry.get("position", entry.get("porchPosition", target))
	return Vector2(start.x - target.x, start.z - target.z).length()

func _begin_route_budget_frame() -> void:
	var engine_frame := Engine.get_process_frames()
	if engine_frame == route_budget_engine_frame and route_budget_tick == route_budget_seen_tick:
		return
	route_budget_engine_frame = engine_frame
	route_budget_seen_tick = route_budget_tick
	route_budget_serial += 1
	route_budget_frame = route_budget_serial
	route_jobs_this_frame = 0
	urgent_route_jobs_this_frame = 0
	scripted_route_jobs_this_frame = 0
	active_job_route_jobs_this_frame = 0
	starved_route_jobs_this_frame = 0

func _claim_route_budget(entry: Dictionary, intent: Dictionary) -> bool:
	_begin_route_budget_frame()
	var actor_id := String(entry.get("id", ""))
	if actor_id == "":
		route_jobs_this_frame += 1
		return true
	var route_actions: Dictionary = entry.get("routeActions", {})
	var direct_update_move := entry.has("_externalDirectMoveFrame") or entry.has("_standaloneNpcUpdateFrame")
	var external_direct_move := direct_update_move and String(entry.get("activeDoorPortalId", "")) == "" and route_actions.is_empty()
	var priority := maxi(int(intent.get("priority", 0)), int(entry.get("routePriority", 0)))
	var route_kind := String(intent.get("kind", "move"))
	var critical_ordered_route := route_kind == "home"
	var threat_guard_route := route_kind == "guard" and bool(entry.get("guardRouteCritical", false))
	var priority_scripted_route := route_kind == "scripted" and priority >= 180
	var routine_route := route_kind in ["guard", "work", "forage", "job", "idle", "move", "scripted"]
	var active_job_route := route_kind in ["guard", "forage", "work", "job"]
	var urgent_route := critical_ordered_route or threat_guard_route or priority_scripted_route or (priority >= 180 and not routine_route)
	var waited_frames := int(entry.get("routeBudgetWaitFrames", 0))
	var frames_since_grant := route_budget_frame - int(entry.get("routeBudgetGrantedFrame", -999999))
	if routine_route and not urgent_route and route_kind != "scripted" and _routine_route_is_background(entry, intent):
		entry["routeBudgetWaitFrames"] = waited_frames + 1
		var background_monitor = performance_monitor()
		if background_monitor != null:
			background_monitor.increment_counter("route_budget_background_yields")
		return false
	if not external_direct_move and not urgent_route and not active_job_route and waited_frames < STARVED_ROUTE_BUDGET_FRAMES and frames_since_grant >= 0 and frames_since_grant <= ROUTE_BUDGET_GRANT_COOLDOWN_FRAMES:
		entry["routeBudgetWaitFrames"] = waited_frames + 1
		var cooldown_monitor = performance_monitor()
		if cooldown_monitor != null:
			cooldown_monitor.increment_counter("route_budget_cooldown_yields")
		return false
	var starved_overflow := false
	var urgent_overflow := false
	var scripted_overflow := false
	var active_job_overflow := false
	if route_jobs_this_frame >= _live_route_job_limit():
		waited_frames += 1
		entry["routeBudgetWaitFrames"] = waited_frames
		if priority_scripted_route and scripted_route_jobs_this_frame < SCRIPTED_ROUTE_EXTRA_JOBS_PER_FRAME:
			scripted_route_jobs_this_frame += 1
			scripted_overflow = true
		elif urgent_route and urgent_route_jobs_this_frame < URGENT_ROUTE_EXTRA_JOBS_PER_FRAME:
			urgent_route_jobs_this_frame += 1
			urgent_overflow = true
		elif active_job_route and active_job_route_jobs_this_frame < ACTIVE_JOB_ROUTE_EXTRA_JOBS_PER_FRAME:
			active_job_route_jobs_this_frame += 1
			active_job_overflow = true
		elif route_kind != "scripted" and not external_direct_move and waited_frames >= (ACTIVE_JOB_ROUTE_STARVED_FRAMES if active_job_route else STARVED_ROUTE_BUDGET_FRAMES) and starved_route_jobs_this_frame < STARVED_ROUTE_EXTRA_JOBS_PER_FRAME:
			starved_route_jobs_this_frame += 1
			starved_overflow = true
		else:
			return false
	if not active_job_route and not critical_ordered_route and not priority_scripted_route and not external_direct_move and not starved_overflow and not active_job_overflow and not urgent_overflow and not scripted_overflow and actor_id == route_last_granted_actor_id and int(entry.get("routeBudgetYieldedFrame", -999999)) != route_budget_frame - 1:
		entry["routeBudgetYieldedFrame"] = route_budget_frame
		entry["routeBudgetWaitFrames"] = waited_frames + 1
		var monitor = performance_monitor()
		if monitor != null:
			monitor.increment_counter("route_budget_yields")
		return false
	route_jobs_this_frame += 1
	route_last_granted_actor_id = actor_id
	entry["routeBudgetGrantedFrame"] = route_budget_frame
	entry["routeBudgetWaitFrames"] = 0
	if urgent_overflow:
		var urgent_monitor = performance_monitor()
		if urgent_monitor != null:
			urgent_monitor.increment_counter("route_budget_urgent_grants")
	if scripted_overflow:
		var scripted_monitor = performance_monitor()
		if scripted_monitor != null:
			scripted_monitor.increment_counter("route_budget_scripted_grants")
	if active_job_overflow:
		var active_job_monitor = performance_monitor()
		if active_job_monitor != null:
			active_job_monitor.increment_counter("route_budget_active_job_grants")
	if starved_overflow:
		var monitor = performance_monitor()
		if monitor != null:
			monitor.increment_counter("route_budget_starved_grants")
	return true

func _routine_route_is_background(entry: Dictionary, intent: Dictionary) -> bool:
	if main == null:
		return false
	var player_node := main.get("player") as Node3D
	if player_node == null:
		return false
	var body := entry.get("body") as Node3D
	var actor_position: Vector3 = body.global_position if body != null else entry.get("position", entry.get("porchPosition", player_node.global_position))
	if absf(actor_position.y - player_node.global_position.y) > CELL * 12.0:
		return true
	var route_kind := String(intent.get("kind", "move"))
	if _player_is_sprinting(player_node):
		if route_kind == "guard" and not bool(entry.get("guardRouteCritical", false)):
			return true
		if route_kind in ["forage", "work", "job", "idle", "move"]:
			var flat_delta := Vector2(actor_position.x - player_node.global_position.x, actor_position.z - player_node.global_position.z)
			if flat_delta.length() > CELL * 20.0:
				return true
	return false

func _player_is_sprinting(player_node: Node3D) -> bool:
	if bool(player_node.get("is_sprinting")):
		return true
	if bool(player_node.get("automated_sprint")):
		return true
	var body := player_node as CharacterBody3D
	if body == null:
		return false
	var horizontal_velocity := Vector2(body.velocity.x, body.velocity.z).length()
	return horizontal_velocity >= CELL * 8.0

func _route_cache_key(entry: Dictionary, intent: Dictionary) -> String:
	var body := entry.get("body") as Node3D
	var start_cell: Vector2i = world.world_cell(body.global_position) if body != null and world != null else Vector2i.ZERO
	var target_cell: Vector2i = intent.get("targetCell", world.world_cell(intent.get("target", Vector3.ZERO)) if world != null else Vector2i.ZERO)
	# Cache key intentionally excludes the NavmeshWorldService topology_revision.
	# That counter is bumped on every tile publish, so keying routes on it made the
	# whole town's cache churn every frame under multi-NPC load. The world's
	# navmesh_tile_source_key (static_snapshot_revision:semantic_revision) already
	# changes only on real content edits; tile-scoped event invalidation
	# (process_navigation_events) handles per-tile changes precisely.
	var world_revision := ""
	if world != null and world.has_method("navmesh_tile_source_key"):
		world_revision = String(world.navmesh_tile_source_key())
	elif world != null and world.has_method("revision"):
		world_revision = world.revision()
	var profile_id := "adult_npc"
	var context = entry.get("agentContext")
	if context != null:
		profile_id = String(context.get("traversal_profile_id")) if context.get("traversal_profile_id") != null else profile_id
	var route_kind_for_cache := String(intent.get("kind", "move"))
	var dynamic_avoid_key := "" if route_kind_for_cache == "scripted" else _route_dynamic_avoid_key(entry)
	return "%s|%s|%d,%d|%d,%d|%s|%s|%s|%s|%s|%s|%.3f" % [
		profile_id,
		world_revision,
		start_cell.x,
		start_cell.y,
		target_cell.x,
		target_cell.y,
		String(intent.get("kind", "move")),
		str(bool(intent.get("allowOutside", false))),
		str(bool(intent.get("movingHome", false))),
		String(intent.get("action", "")),
		dynamic_avoid_key,
		str(bool(intent.get("strictArrival", false))),
		float(intent.get("arrivalRadius", CELL * 0.75))
	]

func _route_dynamic_avoid_key(entry: Dictionary) -> String:
	var cells: Array[Vector2i] = []
	for cell_value in entry.get("routeDynamicAvoidCells", []):
		if cell_value is Vector2i:
			cells.append(cell_value)
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y)
	)
	var parts: Array[String] = []
	for cell in cells:
		parts.append("%d,%d" % [cell.x, cell.y])
	return ";".join(parts)

func _store_route_cache(cache_key: String, route: Dictionary) -> void:
	if cache_key == "" or route.is_empty():
		return
	if not bool(route.get("ok", false)) and not _route_failure_cacheable(route):
		return
	route_cache[cache_key] = _compact_route_for_cache(route)
	route_cache_order.erase(cache_key)
	route_cache_order.append(cache_key)
	_index_route_cache_tiles(cache_key, route)
	while route_cache_order.size() > ROUTE_CACHE_LIMIT:
		var evicted: String = route_cache_order.pop_front()
		_forget_route_cache_tiles(evicted)
		route_cache.erase(evicted)

func _index_route_cache_tiles(cache_key: String, route: Dictionary) -> void:
	_forget_route_cache_tiles(cache_key)
	if world == null or not world.has_method("tile_key_for_cell"):
		return
	var tile_keys := {}
	for cell_value in route.get("cells", []):
		if cell_value is Vector2i:
			tile_keys[String(world.tile_key_for_cell(cell_value))] = true
	# Endpoints matter even when a compacted route dropped intermediate cells.
	var target_cell = route.get("targetCell", null)
	if target_cell is Vector2i and target_cell != Vector2i(999999, 999999):
		tile_keys[String(world.tile_key_for_cell(target_cell))] = true
	if tile_keys.is_empty():
		return
	var tile_list: Array[String] = []
	for tile_key in tile_keys.keys():
		tile_list.append(String(tile_key))
		var bucket: Dictionary = route_cache_tile_index.get(tile_key, {})
		bucket[cache_key] = true
		route_cache_tile_index[tile_key] = bucket
	route_cache_tiles[cache_key] = tile_list

func _forget_route_cache_tiles(cache_key: String) -> void:
	var tile_list: Array = route_cache_tiles.get(cache_key, [])
	for tile_key in tile_list:
		var bucket: Dictionary = route_cache_tile_index.get(tile_key, {})
		bucket.erase(cache_key)
		if bucket.is_empty():
			route_cache_tile_index.erase(tile_key)
		else:
			route_cache_tile_index[tile_key] = bucket
	route_cache_tiles.erase(cache_key)

func _evict_route_cache_key(cache_key: String) -> void:
	if not route_cache.has(cache_key):
		return
	route_cache.erase(cache_key)
	route_cache_order.erase(cache_key)
	_forget_route_cache_tiles(cache_key)

func _invalidate_route_cache_for_tile(tile_key: String) -> int:
	if tile_key == "":
		return 0
	var bucket: Dictionary = route_cache_tile_index.get(tile_key, {})
	if bucket.is_empty():
		return 0
	var evicted := 0
	for cache_key in bucket.keys().duplicate():
		if route_cache.has(cache_key):
			route_cache.erase(cache_key)
			route_cache_order.erase(cache_key)
			evicted += 1
		_forget_route_cache_tiles(String(cache_key))
	return evicted

func _route_failure_cacheable(route: Dictionary) -> bool:
	if String(route.get("status", "")) == "pending":
		return false
	var reason := String(route.get("reason", ""))
	return reason in [
		"target_blocked",
		"no_route",
		"path_endpoint_mismatch",
		"path_crosses_static_collision",
		"blocked_static_collision",
		"blocked_static_transition"
	]

func _compact_route_for_cache(route: Dictionary) -> Dictionary:
	return {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"cells": (route.get("cells", []) as Array).duplicate(),
		"waypoints": (route.get("waypoints", []) as Array).duplicate(),
		"actions": (route.get("actions", {}) as Dictionary).duplicate(true),
		"targetCell": route.get("targetCell", Vector2i(999999, 999999)),
		"fallbackCell": route.get("fallbackCell", Vector2i(999999, 999999)),
		"snapshotRevision": String(route.get("snapshotRevision", "")),
		"source": String(route.get("source", "")),
		"legacyFallbackUsed": bool(route.get("legacyFallbackUsed", false)),
		"navmeshRoute": (route.get("navmeshRoute", {}) as Dictionary).duplicate(true)
	}

func _copy_cached_route(route: Dictionary) -> Dictionary:
	return {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"cells": (route.get("cells", []) as Array).duplicate(),
		"waypoints": (route.get("waypoints", []) as Array).duplicate(),
		"actions": (route.get("actions", {}) as Dictionary).duplicate(true),
		"targetCell": route.get("targetCell", Vector2i(999999, 999999)),
		"fallbackCell": route.get("fallbackCell", Vector2i(999999, 999999)),
		"snapshotRevision": String(route.get("snapshotRevision", "")),
		"source": String(route.get("source", "")),
		"legacyFallbackUsed": bool(route.get("legacyFallbackUsed", false)),
		"navmeshRoute": (route.get("navmeshRoute", {}) as Dictionary).duplicate(true)
	}

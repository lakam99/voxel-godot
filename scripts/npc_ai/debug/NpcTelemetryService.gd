extends RefCounted
class_name NpcTelemetryService

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var ring_capacity := NpcConstantsScript.TELEMETRY_RING_CAPACITY
var global_counters := {}
var per_npc_events := {}
var dropped_events := {}
var duration_samples := {}
var gauges := {}
var gauge_high_water := {}
var gauge_limits := {}
var gauge_limit_breaches := {}

const REQUIRED_COUNTERS := [
	"route_requests",
	"route_completions",
	"route_failures",
	"route_cancellations",
	"route_expansions",
	"route_latency",
	"route_cache_hits",
	"route_cache_misses",
	"tile_builds",
	"tile_rebuilds",
	"repair_jobs",
	"full_replans",
	"motor_blocked_ticks",
	"motor_contacts",
	"avoidance_active_agents",
	"avoidance_compute_callbacks",
	"reservation_waits",
	"reservation_denials",
	"deadlock_cycles",
	"deadlock_resolutions",
	"door_opens",
	"door_holds",
	"door_closes",
	"door_obstruction_reversals",
	"action_plan_generations",
	"action_plan_repairs",
	"schedule_compliance",
	"lod_promotions",
	"lod_demotions",
	"memory_cache_size",
	"npc_brain_updates",
	"npc_motion_updates",
	"npc_active_route_motion_ticks",
	"npc_scripted_order_motion_ticks",
	"npc_door_action_motion_ticks",
	"npc_brain_budget_skipped"
]

func _init() -> void:
	for counter in REQUIRED_COUNTERS:
		global_counters[counter] = 0

func increment(counter: StringName, amount := 1) -> void:
	var key := String(counter)
	if not global_counters.has(key) and global_counters.size() >= NpcConstantsScript.TELEMETRY_GLOBAL_COUNTER_LIMIT:
		return
	global_counters[key] = int(global_counters.get(key, 0)) + amount

func record_duration(metric: StringName, duration_usec: int, hard_slice_usec := 0) -> void:
	var key := String(metric)
	var entry: Dictionary = duration_samples.get(key, {
		"count": 0,
		"totalUsec": 0,
		"maxUsec": 0,
		"hardSliceUsec": hard_slice_usec,
		"overruns": 0,
		"samples": []
	})
	entry["count"] = int(entry.get("count", 0)) + 1
	entry["totalUsec"] = int(entry.get("totalUsec", 0)) + maxi(0, duration_usec)
	entry["maxUsec"] = maxi(int(entry.get("maxUsec", 0)), maxi(0, duration_usec))
	if hard_slice_usec > 0:
		entry["hardSliceUsec"] = hard_slice_usec
		if duration_usec > hard_slice_usec:
			entry["overruns"] = int(entry.get("overruns", 0)) + 1
	var samples: Array = entry.get("samples", [])
	samples.append(maxi(0, duration_usec))
	while samples.size() > NpcConstantsScript.TELEMETRY_PERFORMANCE_SAMPLE_CAPACITY:
		samples.pop_front()
	entry["samples"] = samples
	duration_samples[key] = entry

func set_gauge(metric: StringName, value: int, limit := -1) -> void:
	var key := String(metric)
	if not gauges.has(key) and gauges.size() >= NpcConstantsScript.TELEMETRY_GAUGE_LIMIT:
		return
	var normalized := maxi(0, value)
	gauges[key] = normalized
	gauge_high_water[key] = maxi(int(gauge_high_water.get(key, 0)), normalized)
	if limit >= 0:
		gauge_limits[key] = limit
		if normalized > limit:
			gauge_limit_breaches[key] = int(gauge_limit_breaches.get(key, 0)) + 1

func observe_route_result(result) -> void:
	if result == null:
		increment(&"route_failures")
		return
	increment(&"route_requests")
	var status := String(result.get("status"))
	if status == "COMPLETE":
		increment(&"route_completions")
	elif status == "CANCELLED":
		increment(&"route_cancellations")
	elif status in ["UNREACHABLE", "FAILED_INTERNAL", "INVALIDATED"]:
		increment(&"route_failures")
	var metrics: Dictionary = result.get("metrics") if result.get("metrics") is Dictionary else {}
	increment(&"route_expansions", int(metrics.get("lastExpansions", metrics.get("expansions", 0))))
	set_gauge(&"route_cache_entries", int(metrics.get("cacheEntries", metrics.get("localCostCacheEntries", 0))), 4096)

func observe_repair_response(response: Dictionary) -> void:
	increment(&"repair_jobs")
	var metrics: Dictionary = response.get("metrics", {}) if response.get("metrics", {}) is Dictionary else {}
	increment(&"route_expansions", int(metrics.get("expansions", 0)))
	increment(&"full_replans", int(metrics.get("fullReplans", 0)))
	set_gauge(&"repair_queue_count", int(metrics.get("queueCount", 0)), 512)

func observe_navigation_stats(stats_value: Dictionary) -> void:
	set_gauge(&"nav_tile_count", int(stats_value.get("tileCount", 0)), 4096)
	set_gauge(&"nav_dirty_tile_count", int(stats_value.get("dirtyTileCount", 0)), 1024)
	var build_queue: Dictionary = stats_value.get("buildQueue", {}) if stats_value.get("buildQueue", {}) is Dictionary else {}
	set_gauge(&"nav_build_queue_pending", int(build_queue.get("pending", 0)), 512)
	increment(&"tile_builds", int(build_queue.get("completedJobs", 0)))
	record_duration(&"navigation_build_work", int(build_queue.get("lastDurationUsec", 0)), NpcConstantsScript.NAV_BUILD_HARD_SLICE_USEC)

func observe_traffic_stats(stats_value: Dictionary) -> void:
	set_gauge(&"traffic_active_reservations", int(stats_value.get("activeReservations", 0)), 512)
	set_gauge(&"traffic_queue_length", int(stats_value.get("queueLength", 0)), 512)
	increment(&"reservation_waits", int(stats_value.get("waiting", 0)))
	increment(&"reservation_denials", int(stats_value.get("denied", 0)))
	increment(&"deadlock_cycles", int(stats_value.get("cyclesDetected", 0)))
	increment(&"deadlock_resolutions", int(stats_value.get("cyclesResolved", 0)))

func observe_avoidance_stats(stats_value: Dictionary) -> void:
	set_gauge(&"avoidance_registered_agents", int(stats_value.get("registeredAgents", 0)), 256)
	increment(&"avoidance_active_agents", int(stats_value.get("activeAgents", 0)))
	increment(&"avoidance_compute_callbacks", int(stats_value.get("computeCalls", 0)))

func observe_door_event(kind: String) -> void:
	if kind == "open":
		increment(&"door_opens")
	elif kind == "hold":
		increment(&"door_holds")
	elif kind == "close":
		increment(&"door_closes")
	elif kind == "obstruction_reverse":
		increment(&"door_obstruction_reversals")

func observe_schedule_compliance(count := 1) -> void:
	increment(&"schedule_compliance", count)

func observe_lod_transition(kind: String) -> void:
	if kind == "promotion":
		increment(&"lod_promotions")
	elif kind == "demotion":
		increment(&"lod_demotions")

func record_event(npc_id: String, category: StringName, transition: String, reason: StringName = &"none", metrics := {}) -> Dictionary:
	var key := npc_id if npc_id != "" else "_global"
	var events: Array = per_npc_events.get(key, [])
	var event := {
		"tick": Engine.get_process_frames(),
		"timeUnix": Time.get_unix_time_from_system(),
		"actor": key,
		"category": String(category),
		"transition": transition,
		"reason": String(reason),
		"metrics": metrics.duplicate(true)
	}
	events.append(event)
	while events.size() > ring_capacity:
		events.pop_front()
		dropped_events[key] = int(dropped_events.get(key, 0)) + 1
	per_npc_events[key] = events
	increment(StringName("event_%s" % String(category)))
	return event

func events_for(npc_id: String) -> Array:
	return per_npc_events.get(npc_id if npc_id != "" else "_global", []).duplicate(true)

func stats() -> Dictionary:
	var sizes := {}
	for key in per_npc_events.keys():
		sizes[key] = (per_npc_events[key] as Array).size()
	var durations := {}
	for key in duration_samples.keys():
		var entry: Dictionary = duration_samples[key]
		var samples: Array = entry.get("samples", [])
		var sorted_samples := samples.duplicate()
		sorted_samples.sort()
		var p95 := 0
		if not sorted_samples.is_empty():
			var p95_index := clampi(int(ceil(float(sorted_samples.size()) * 0.95)) - 1, 0, sorted_samples.size() - 1)
			p95 = int(sorted_samples[p95_index])
		var count := int(entry.get("count", 0))
		durations[key] = {
			"count": count,
			"totalUsec": int(entry.get("totalUsec", 0)),
			"averageUsec": int(entry.get("totalUsec", 0)) / max(1, count),
			"maxUsec": int(entry.get("maxUsec", 0)),
			"p95Usec": p95,
			"hardSliceUsec": int(entry.get("hardSliceUsec", 0)),
			"overruns": int(entry.get("overruns", 0)),
			"sampleCount": samples.size()
		}
	var missing_required := []
	for counter in REQUIRED_COUNTERS:
		if not global_counters.has(counter):
			missing_required.append(counter)
	return {
		"ringCapacity": ring_capacity,
		"counters": global_counters.duplicate(),
		"eventSizes": sizes,
		"droppedEvents": dropped_events.duplicate(),
		"durations": durations,
		"gauges": gauges.duplicate(),
		"gaugeHighWater": gauge_high_water.duplicate(),
		"gaugeLimits": gauge_limits.duplicate(),
		"gaugeLimitBreaches": gauge_limit_breaches.duplicate(),
		"requiredCounters": {
			"count": REQUIRED_COUNTERS.size(),
			"missing": missing_required
		}
	}


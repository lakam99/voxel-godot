extends RefCounted
class_name NavigationBuildQueue

var queued_by_tile := {}
var sequence := 0
var completed_jobs := 0
var yielded_jobs := 0
var last_duration_usec := 0

func clear() -> void:
	queued_by_tile.clear()
	sequence = 0
	completed_jobs = 0
	yielded_jobs = 0
	last_duration_usec = 0

func schedule_tile(tile_key: String, snapshot: Dictionary, priority := 0, source_revision := 0, profile = null) -> void:
	sequence += 1
	var existing: Dictionary = queued_by_tile.get(tile_key, {})
	if not existing.is_empty() and int(existing.get("priority", 0)) > priority:
		return
	queued_by_tile[tile_key] = {
		"tileKey": tile_key,
		"snapshot": snapshot.duplicate(true),
		"priority": priority,
		"sourceRevision": source_revision,
		"profile": profile,
		"sequence": sequence
	}

func pending_count() -> int:
	return queued_by_tile.size()

func has_pending(tile_key: String) -> bool:
	return queued_by_tile.has(tile_key)

func process_budget(builder, topology_revision: int, max_jobs := 1, max_usec := 4000) -> Array:
	var started := Time.get_ticks_usec()
	var built: Array = []
	var processed := 0
	while not queued_by_tile.is_empty() and processed < max_jobs:
		if processed > 0 and Time.get_ticks_usec() - started >= max_usec:
			break
		var job := _pop_next_job()
		if job.is_empty():
			break
		var tile = builder.build_tile(job.get("snapshot", {}), topology_revision + built.size() + 1, job.get("profile", null), int(job.get("sourceRevision", 0)))
		built.append(tile)
		processed += 1
		completed_jobs += 1
	if not queued_by_tile.is_empty():
		yielded_jobs += 1
	last_duration_usec = Time.get_ticks_usec() - started
	return built

func _pop_next_job() -> Dictionary:
	var best_key := ""
	var best_priority := -2147483648
	var best_sequence := 2147483647
	for tile_key in queued_by_tile.keys():
		var job: Dictionary = queued_by_tile[tile_key]
		var priority := int(job.get("priority", 0))
		var order := int(job.get("sequence", 0))
		if priority > best_priority or (priority == best_priority and order < best_sequence):
			best_key = String(tile_key)
			best_priority = priority
			best_sequence = order
	if best_key == "":
		return {}
	var result: Dictionary = queued_by_tile[best_key]
	queued_by_tile.erase(best_key)
	return result

func stats() -> Dictionary:
	return {
		"pending": queued_by_tile.size(),
		"completedJobs": completed_jobs,
		"yieldedJobs": yielded_jobs,
		"lastDurationUsec": last_duration_usec
	}

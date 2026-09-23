extends RefCounted
class_name StartupWorkProgressTracker

## Loading-only evidence. A timestamped pending message is never a completed
## work unit; only source-owned counters and first ready transitions advance it.
const MAX_RECEIPTS := 8192

var completed_revision := 0
var receipts: Array[Dictionary] = []
var overflow := false
var _last_counts := {}
var _ready_domains := {}
var _last_owner_usec := {}

func reset() -> void:
	completed_revision = 0
	receipts.clear()
	overflow = false
	_last_counts.clear()
	_ready_domains.clear()
	_last_owner_usec.clear()

func observe(domain: String, status: String, metrics: Dictionary, now_usec: int) -> void:
	if overflow or domain.is_empty() or now_usec <= 0:
		return
	var recorded_progress := false
	var source := _completed_source(domain, metrics)
	if not source.is_empty():
		var owner := String(source.owner)
		var count := int(source.completed)
		var previous := int(_last_counts.get(owner, 0))
		if count > previous:
			_last_counts[owner] = count
			_record(owner, "completed_units", count, int(source.pending), now_usec)
			recorded_progress = true
	if status == "ready" and not _ready_domains.has(domain):
		_ready_domains[domain] = true
		if not recorded_progress:
			_record(domain, "readiness_transition", 1, 0, now_usec)

func _completed_source(domain: String, metrics: Dictionary) -> Dictionary:
	if domain == "scene":
		var audio = metrics.get("audio")
		if audio is Dictionary and (audio as Dictionary).has("completedJobs") \
				and (audio as Dictionary).has("totalJobs"):
			return _count("scene.audio", audio.completedJobs, audio.totalJobs)
		if metrics.has("warmedAssetCount") and metrics.has("requiredAssetCount"):
			return _count("scene.assets", metrics.warmedAssetCount, metrics.requiredAssetCount)
	if domain == "terrain_chunks" and metrics.has("loadedChunkCount") and metrics.has("requiredChunkCount"):
		return _count(domain, metrics.loadedChunkCount, metrics.requiredChunkCount)
	if domain == "terrain_collision" and metrics.has("publishedChunkCount") and metrics.has("requiredChunkCount"):
		return _count(domain, metrics.publishedChunkCount, metrics.requiredChunkCount)
	if domain == "town_manifest" and metrics.get("publishedKeys") is Array \
			and metrics.get("requiredKeys") is Array:
		return _count(domain, (metrics.publishedKeys as Array).size(), (metrics.requiredKeys as Array).size())
	if domain == "navigation_changes" and metrics.has("processedEventCount") \
			and metrics.has("remainingEventCount"):
		var processed := int(metrics.processedEventCount)
		return _count(domain, processed, processed + int(metrics.remainingEventCount))
	if domain == "navigation_tiles" and metrics.has("publishedTileCount") and metrics.has("requiredTileCount"):
		return _count(domain, metrics.publishedTileCount, metrics.requiredTileCount)
	if domain in ["initial_region", "initial_region_physical"] and metrics.get("domains") is Dictionary:
		var ready_count := 0
		var domains: Dictionary = metrics.domains
		for value in domains.values():
			if value is Dictionary and String(value.get("status", "")) == "ready":
				ready_count += 1
		return _count(domain, ready_count, domains.size())
	return {}

func _count(owner: String, completed_value, total_value) -> Dictionary:
	if not completed_value is int or not total_value is int:
		return {}
	var completed := int(completed_value)
	var total := int(total_value)
	if completed < 0 or total < 0 or completed > total:
		return {}
	return {"owner":owner, "completed":completed, "pending":total - completed}

func _record(owner: String, kind: String, completed: int, pending: int, now_usec: int) -> void:
	if receipts.size() >= MAX_RECEIPTS:
		overflow = true
		return
	completed_revision += 1
	var previous_usec := int(_last_owner_usec.get(owner, now_usec))
	_last_owner_usec[owner] = now_usec
	receipts.append({"owner":owner, "kind":kind, "completedCount":completed,
		"pendingWorkCount":pending, "activeWorkAgeMs":float(now_usec - previous_usec) / 1000.0,
		"completedRevision":completed_revision, "sourceTicksUsec":now_usec})

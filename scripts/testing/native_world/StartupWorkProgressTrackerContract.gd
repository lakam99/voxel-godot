extends SceneTree

const Tracker = preload("res://scripts/perf/StartupWorkProgressTracker.gd")
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var tracker = Tracker.new()
	tracker.observe("terrain_chunks", "pending", {"loadedChunkCount":0,"requiredChunkCount":9}, 1000)
	tracker.observe("terrain_chunks", "pending", {"loadedChunkCount":0,"requiredChunkCount":9}, 2000)
	check(tracker.completed_revision == 0, "timestamped pending rows do not count as work")
	tracker.observe("terrain_chunks", "pending", {"loadedChunkCount":2,"requiredChunkCount":9}, 3000)
	tracker.observe("terrain_chunks", "pending", {"loadedChunkCount":2,"requiredChunkCount":9}, 4000)
	tracker.observe("terrain_chunks", "pending", {"loadedChunkCount":1,"requiredChunkCount":9}, 5000)
	check(tracker.completed_revision == 1 and tracker.receipts[0].completedCount == 2 \
		and tracker.receipts[0].pendingWorkCount == 7, "only increasing source count advances")
	tracker.observe("terrain_chunks", "ready", {"loadedChunkCount":9,"requiredChunkCount":9}, 6000)
	tracker.observe("terrain_chunks", "ready", {"loadedChunkCount":9,"requiredChunkCount":9}, 7000)
	check(tracker.completed_revision == 2 and tracker.receipts[1].kind == "completed_units",
		"one ready call records its completed count only once")
	tracker.observe("scene", "pending", {"audio":{"completedJobs":1,"totalJobs":3}}, 8000)
	tracker.observe("scene", "pending", {"audio":{"completedJobs":1,"totalJobs":3}}, 9000)
	tracker.observe("town_manifest", "pending", {"publishedKeys":["home"],
		"requiredKeys":["home","door"], "pendingOpCount":1}, 10000)
	check(tracker.completed_revision == 4 and tracker.receipts[2].owner == "scene.audio"
		and tracker.receipts[3].owner == "town_manifest", "independent source owners advance")
	tracker.observe("scene", "pending", {"audio":{"completedJobs":1,"totalJobs":3}}, 15000)
	check(tracker.completed_revision == 4, "five-second cosmetic scene updates cannot create receipts")
	tracker.observe("navigation_map", "ready", {}, 16000)
	tracker.observe("navigation_map", "ready", {}, 17000)
	check(tracker.completed_revision == 5 and tracker.receipts[4].kind == "readiness_transition",
		"first source readiness transition advances exactly once")
	tracker.reset()
	check(tracker.completed_revision == 0 and tracker.receipts.is_empty() and not tracker.overflow,
		"new loading operation resets source receipts")
	print("startup_work_progress_tracker_contract: %s" % ("passed" if failures == 0 else "failed:%d" % failures))
	quit(0 if failures == 0 else 1)

func check(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error(message)

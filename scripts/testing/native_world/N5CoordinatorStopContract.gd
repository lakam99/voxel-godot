extends SceneTree

const COORDINATOR = preload("res://scripts/terrain/NativeWindowedCollisionCoordinator.gd")

class PendingOwner:
	extends Node3D
	var attempts := 0
	func physical_receipt(_identity: Dictionary) -> Dictionary:
		return {"ready":false}
	func stop_and_drain() -> Dictionary:
		attempts += 1
		if attempts == 1:
			return {"status":"pending", "reason":"physics_sync_pending"}
		return {"status":"ready", "drained":true,
			"remainingBodies":0, "windowToken":"fake-window"}

class FakeBroker:
	extends RefCounted
	var layout := {}
	func collision_window_layout() -> Dictionary:
		return layout.duplicate(true)
	func acknowledge_collision_window_retired(_token: String,
			_receipt: Dictionary) -> Dictionary:
		return {"status":"ready"}

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var root_3d := Node3D.new()
	root.add_child(root_3d)
	var coordinator = COORDINATOR.new()
	root_3d.add_child(coordinator)
	var broker := FakeBroker.new()
	var window := {"id":Vector3i.ZERO, "windowToken":"fake-window",
		"blocks":[Vector3i.ZERO]}
	var identity := {"sourceRevision":1}
	broker.layout = {"status":"ready", "windows":[window],
		"identity":identity}
	var setup: Dictionary = coordinator.setup(broker, root_3d)
	var owner := PendingOwner.new()
	coordinator.add_child(owner)
	var registered: Dictionary = coordinator.register_window(window, owner)
	var bounds := AABB(Vector3.ZERO, Vector3.ONE)
	var first_hold: Dictionary = coordinator.begin_window_barrier(window,
		bounds, identity)
	var held: Dictionary = first_hold
	for index in range(64):
		held = coordinator.begin_window_barrier(window, bounds, identity)
	var cap: Dictionary = coordinator.begin_window_barrier(window, bounds,
		identity)
	var first_stop: Dictionary = await coordinator.stop_and_drain()
	var retained_child: bool = is_instance_valid(owner) and owner.get_parent() == coordinator
	var actor := CharacterBody3D.new()
	root_3d.add_child(actor)
	var motion_denied: bool = not coordinator.admit_motion(actor, Vector3.ONE)
	var placement_denied: bool = not coordinator.admit_placement(actor,
		Transform3D(Basis.IDENTITY, Vector3.ONE))
	var terminal_release: bool = held.barrier.release(identity)
	var second_stop: Dictionary = await coordinator.stop_and_drain()
	var distinct_coordinator = COORDINATOR.new()
	root_3d.add_child(distinct_coordinator)
	var distinct_setup: Dictionary = distinct_coordinator.setup(broker, root_3d)
	var distinct_last: Dictionary = {}
	for index in range(distinct_coordinator.MAX_ACTIVE_BARRIERS):
		distinct_last = distinct_coordinator.begin_window_barrier(
			{"id":Vector3i(index, 0, 0), "windowToken":"distinct-%d" % index},
			bounds, identity)
	var distinct_cap: Dictionary = distinct_coordinator.begin_window_barrier(
		{"id":Vector3i(999, 0, 0), "windowToken":"distinct-overflow"},
		bounds, identity)
	var distinct_stop: Dictionary = await distinct_coordinator.stop_and_drain()
	actor.queue_free()
	root_3d.queue_free()
	var passed: bool = setup.get("status") == "ready" \
		and registered.get("status") == "ready" \
		and first_hold.get("status") == "ready" \
		and held.get("status") == "ready" \
		and cap.get("status") == "pending" \
		and cap.get("reason") == "window_barrier_retention_backpressure" \
		and first_stop.get("status") == "pending" \
		and first_stop.get("reason") == "physical_window_drain_pending" \
		and retained_child and motion_denied and placement_denied \
		and not terminal_release \
		and second_stop.get("status") == "ready" \
		and int(second_stop.get("remainingChildren", -1)) == 0 \
		and int(second_stop.get("activeBarriers", -1)) == 0 \
		and distinct_setup.get("status") == "ready" \
		and distinct_last.get("status") == "ready" \
		and distinct_cap.get("status") == "pending" \
		and distinct_cap.get("reason") == "window_barrier_retention_backpressure" \
		and distinct_stop.get("status") == "ready"
	var report := {"schema":"n5-coordinator-stop-contract/v1",
		"passed":passed, "evidenceLevel":"synthetic coordinator lifecycle contract",
		"productionCutover":false, "firstHold":first_hold.get("status"),
		"retainedBarrierCount":coordinator.MAX_RETIRED_BARRIERS,
		"cap":cap, "firstStop":first_stop,
		"retainedChild":retained_child, "motionDenied":motion_denied,
		"placementDenied":placement_denied,
		"terminalRelease":terminal_release, "secondStop":second_stop,
		"distinctBarrierCap":distinct_cap, "distinctStop":distinct_stop}
	var path := OS.get_environment("N5_COORDINATOR_STOP_REPORT")
	if not path.is_empty():
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
			file.close()
	quit(0 if passed else 1)

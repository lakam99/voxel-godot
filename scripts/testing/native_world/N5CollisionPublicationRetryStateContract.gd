extends SceneTree

# Narrow state contract only: proves ticket reset, strong candidate retention,
# and post-await ticket fencing. It does not run N3, N5 physics, MainCore startup,
# or prove production readiness/cutover.
const RUNTIME := preload("res://scripts/terrain/NativeTerrainCollisionPublicationRuntime.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var runtime = RUNTIME.new()
	var first_identity := {"ownerGeneration":7, "sourceRevision":2,
		"sourceEpoch":"retry-contract"}
	var second_identity := {"ownerGeneration":7, "sourceRevision":3,
		"sourceEpoch":"retry-contract"}
	var first_blocks: Array[Vector3i] = [Vector3i.ZERO, Vector3i(1, 0, 0),
		Vector3i(2, 0, 0)]
	var second_blocks: Array[Vector3i] = [Vector3i(8, 0, 0),
		Vector3i(9, 0, 0)]
	var first_ticket := {"status":"ready", "ticket":"ticket-2",
		"identity":first_identity, "layout":{"identity":first_identity,
			"logicalClosureToken":"closure-2"}}
	var adopted_first: Dictionary = runtime.call("_adopt_ticket_demand",
		first_ticket, first_blocks, "closure-2")
	runtime.set("_request_cursor", 2)
	var second_ticket := {"status":"ready", "ticket":"ticket-3",
		"identity":second_identity, "layout":{"identity":second_identity,
			"logicalClosureToken":"closure-3"}}
	var adopted_second: Dictionary = runtime.call("_adopt_ticket_demand",
		second_ticket, second_blocks, "closure-3")
	var queue_reset := adopted_first.get("status") == "ready" \
		and adopted_second.get("status") == "ready" \
		and runtime.get("_ticket") == "ticket-3" \
		and runtime.get("_request_cursor") == 0 \
		and runtime.get("_request_queue") == second_blocks

	var retained_owner := Node3D.new()
	var entry := {"owner":"incumbent", "identity":first_identity}
	var candidate := {"owner":retained_owner, "staged":true,
		"barrierRetryCount":1}
	var retained: Dictionary = runtime.call("_retain_staged_candidate",
		Vector3i.ZERO, entry, candidate)
	var retained_for_retry := retained.get("status") == "ready" \
		and runtime.get("_windows").get(Vector3i.ZERO, {}).get("candidate", {}) \
			.get("owner") == retained_owner

	var matching_ticket := runtime.call("_ticket_is_current", "ticket-3",
		second_identity, second_ticket)
	var drifted_ticket := second_ticket.duplicate(true)
	drifted_ticket.ticket = "ticket-4"
	var await_drift_fenced := not bool(runtime.call("_ticket_is_current",
		"ticket-3", second_identity, drifted_ticket))
	retained_owner.free()
	runtime.free()
	var passed := queue_reset and retained_for_retry \
		and bool(matching_ticket) and await_drift_fenced
	print("N5_COLLISION_PUBLICATION_RETRY_STATE " + ("PASS" if passed else "FAIL")
		+ " queue_reset=%s candidate_retained=%s ticket_drift_fenced=%s" % [
			queue_reset, retained_for_retry, await_drift_fenced])
	quit(0 if passed else 1)

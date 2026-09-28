extends SceneTree

const Driver = preload("res://scripts/buildings/DeterministicRecipeCompletion.gd")
const Lower = preload("res://scripts/buildings/LowerFacadeBearingRecipe.gd")
const Connection = preload("res://scripts/buildings/OpeningHeadConnectionRecipe.gd")

func _initialize() -> void:
	var checks := {}
	var skip_calls: Array = []
	var skip := Driver.run({"unsupported": ["b", "a"], "built": []},
		func(state): return {"ready": true, "candidateIds": state.unsupported},
		func(state, id):
			skip_calls.append(id)
			state.built.append(id)
			state.unsupported.erase(id)
			if id == "a": state.unsupported.erase("b")
			return {"ready": true, "afterState": state}, 8)
	checks["acceptance_rechecks_and_skips_now_passing_next"] = skip.ready and skip_calls == ["a"] and skip.accepted == ["a"] and skip.state.built == ["a"]
	var starvation_calls: Array = []
	var starvation := Driver.run({"unsupported": ["b", "a"], "built": []},
		func(state): return {"ready": true, "candidateIds": state.unsupported},
		func(state, id):
			starvation_calls.append(id)
			if id == "a": return {"ready": false, "monotone": true, "reason": "blocked"}
			state.unsupported.erase(id); state.built.append(id)
			return {"ready": true, "afterState": state}, 8)
	checks["blocked_first_does_not_starve_later"] = starvation.ready and starvation_calls == ["a", "b"] and starvation.accepted == ["b"] and starvation.rejected == [{"panelId": "a", "reason": "blocked"}]
	var hard_source := {"unsupported": ["a"], "built": []}
	var hard_bytes := var_to_bytes(hard_source)
	var hard := Driver.run(hard_source,
		func(state): return {"ready": true, "candidateIds": state.unsupported},
		func(_state, _id): return {"ready": false, "monotone": false, "reason": "work_limit"}, 8)
	checks["hard_failure_aborts_without_candidate_or_mutation"] = not hard.ready and hard.reason == "completion_attempt_failed" and not hard.has("state") and var_to_bytes(hard_source) == hard_bytes
	var malformed := Driver.run(hard_source, func(_state): return {"ready": true, "candidateIds": ["a"]}, func(_state, _id): return {"ready": true}, 8)
	checks["malformed_success_aborts_atomically"] = not malformed.ready and malformed.reason == "completion_attempt_missing_state" and not malformed.has("state")
	var ordered := _order_run(["c", "a", "b"])
	var reversed := _order_run(["b", "c", "a"])
	var repeated := _order_run(["c", "a", "b"])
	checks["reversed_discovery_and_repeat_byte_exact"] = var_to_bytes(ordered) == var_to_bytes(reversed) and var_to_bytes(ordered) == var_to_bytes(repeated) and ordered.accepted == ["a", "b", "c"]
	var capped := Driver.run({"unsupported": ["a", "b"], "built": []},
		func(state): return {"ready": true, "candidateIds": state.unsupported},
		func(state, id): state.unsupported.erase(id); return {"ready": true, "afterState": state}, 1)
	checks["attempt_cap_fails_closed_without_candidate"] = not capped.ready and capped.reason == "completion_attempt_limit" and not capped.has("state")
	var invalid_cap := Driver.run({}, func(_state): return {"ready": true, "candidateIds": []}, func(_state, _id): return {}, 0)
	checks["invalid_cap_fails_closed"] = not invalid_cap.ready and invalid_cap.reason == "invalid_completion_driver"
	var nested_work := {"ready": false, "reason": "no_admitted_rooted_bottom_bearing", "work": {"satPairs": Lower.Connection.MAX_SAT_WORK},
		"attempts": [{"seatId": "seat", "failure": {"ready": false, "reason": "connection_sat_work_limit", "work": {"satPairs": Lower.Connection.MAX_SAT_WORK}}}]}
	var nested_abort := Driver.run({"unsupported": ["a"]},
		func(state): return {"ready": true, "candidateIds": state.unsupported},
		func(_state, _id): return Lower._completion_outcome(nested_work), 4)
	checks["actual_lower_adapter_nested_work_failure_aborts"] = not nested_abort.ready and nested_abort.reason == "completion_attempt_failed" and not nested_abort.has("state") and not Lower._monotone_rejection(nested_work)
	var invalid_measurement := {"ready": false, "reason": "foreign_solid_blocked", "blockingPartId": "solid",
		"measurement": {"valid": false, "clear": false, "reason": "invalid_pose"}}
	var invalid_abort := Driver.run({"unsupported": ["a"]},
		func(state): return {"ready": true, "candidateIds": state.unsupported},
		func(_state, _id): return Lower._completion_outcome(invalid_measurement), 4)
	checks["actual_lower_adapter_invalid_measurement_aborts"] = not invalid_abort.ready and invalid_abort.reason == "completion_attempt_failed" and not invalid_abort.has("state") and not Lower._monotone_rejection(invalid_measurement)
	var valid_measurement := {"ready": false, "reason": "foreign_solid_blocked", "blockingPartId": "solid",
		"measurement": {"valid": true, "clear": false, "reason": "overlap"}}
	checks["actual_lower_adapter_valid_geometry_block_is_monotone"] = Lower._monotone_rejection(valid_measurement) and Lower._completion_outcome(valid_measurement).monotone
	var socket_fixture := _socket_fixture()
	var invalid_socket: Dictionary = Connection._place_connection(socket_fixture.bodyBounds, socket_fixture.core,
		socket_fixture.neutral, socket_fixture.socketHalf, socket_fixture.obstacles, {"satPairs": 0},
		func(_candidate, _obstacle): return {"valid": false, "clear": false, "reason": "invalid_pose"})
	var invalid_nested := {"ready": false, "reason": "no_admitted_rooted_bottom_bearing", "work": invalid_socket.get("work", {"satPairs": 1}),
		"attempts": [{"seatId": "seat", "failure": invalid_socket}]}
	var invalid_nested_abort := Driver.run({"unsupported": ["a"]},
		func(state): return {"ready": true, "candidateIds": state.unsupported},
		func(_state, _id): return Lower._completion_outcome(invalid_nested), 4)
	checks["actual_connection_invalid_nested_measurement_aborts_atomically"] = not invalid_socket.ready \
		and invalid_socket.reason == "invalid_connection_measurement" and not invalid_nested_abort.ready \
		and invalid_nested_abort.reason == "completion_attempt_failed" and not invalid_nested_abort.has("state") \
		and not Lower._monotone_rejection(invalid_nested)
	var blocked_socket: Dictionary = Connection._place_connection(socket_fixture.bodyBounds, socket_fixture.core,
		socket_fixture.neutral, socket_fixture.socketHalf, socket_fixture.obstacles, {"satPairs": 0})
	var blocked_nested := {"ready": false, "reason": "no_admitted_rooted_bottom_bearing", "work": blocked_socket.get("work", {"satPairs": 0}),
		"attempts": [{"seatId": "seat", "failure": blocked_socket}]}
	checks["actual_connection_valid_exhaustive_block_is_monotone"] = not blocked_socket.ready \
		and blocked_socket.reason == "no_clear_connection_in_socket_domain" \
		and blocked_socket.blockedPlacements.size() + blocked_socket.emptyPlacementCount == blocked_socket.attempts \
		and blocked_socket.blockedPlacements.all(func(item): return item.measurement.valid and not item.measurement.clear) \
		and Lower._monotone_rejection(blocked_nested) and Lower._completion_outcome(blocked_nested).monotone
	var passed: bool = checks.values().all(func(value): return value == true)
	var report := {"passed": passed, "checks": checks, "scope": "Pure deterministic completion-driver contract; geometry authority remains covered by lower-bearing contracts."}
	var output := FileAccess.open(OS.get_environment("VOXEL_COMPLETION_DRIVER_REPORT"), FileAccess.WRITE)
	if output != null: output.store_string(JSON.stringify(report, "\t")); output.close()
	quit(0 if passed else 1)

func _order_run(ids: Array) -> Dictionary:
	return Driver.run({"unsupported": ids.duplicate(), "built": []},
		func(state): return {"ready": true, "candidateIds": state.unsupported},
		func(state, id): state.unsupported.erase(id); state.built.append(id); return {"ready": true, "afterState": state}, 8)

func _socket_fixture() -> Dictionary:
	var obstacle_pose := Transform3D(Basis.from_scale(Vector3(4.0, 4.0, 4.0)), Vector3(0.5, 0.1, 0.1))
	return {
		"bodyBounds": [0.0, 0.0, 0.0, 1.0, 0.2, 0.2],
		"core": [-1.0, 0.0, 0.0, 2.0, 0.2, 0.2],
		"neutral": Vector3(0.5, 0.1, 0.1),
		"socketHalf": Vector3(0.07, 0.04, 0.07),
		"obstacles": [{"id": "measured_solid", "pose": obstacle_pose,
			"bounds": [-1.5, -1.9, -1.9, 2.5, 2.1, 2.1]}]
	}

extends RefCounted

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const CLASS_REACHABLE := "reachable"
const CLASS_PENDING_NAV_DATA := "pending_nav_data"
const CLASS_PENDING_BUDGET := "pending_budget"
const CLASS_BLOCKED_DYNAMIC := "blocked_dynamic"
const CLASS_UNREACHABLE_STATIC := "unreachable_static"
const CLASS_INVALID_GOAL := "invalid_goal"
const INVALID_CELL := Vector2i(2147483000, 2147483000)
const DEFAULT_EXPANSIONS_PER_CALL := 128
const DEFAULT_VALIDATION_STEPS_PER_CALL := 512
const DEFAULT_CHEAP_STEPS_PER_CALL := 512
const DEFAULT_CANDIDATE_VALIDATIONS_PER_CALL := 128
const MAX_RECORDED_BLOCKS := 128
const MAX_RECORDED_VISITED := 256

var world_adapter = null
var search_jobs := {}
var active_search_key_by_actor := {}
var candidate_jobs := {}
var active_candidate_key_by_actor := {}
var _active_plan_timing_profile := {}
var _last_plan_timing_profile := {}


func setup(adapter) -> void:
	world_adapter = adapter


func take_last_plan_timing_profile() -> Dictionary:
	var result := _last_plan_timing_profile.duplicate(true)
	_last_plan_timing_profile.clear()
	return result


func _begin_plan_timing_profile() -> void:
	# A profile belongs to exactly one synchronous plan_route call. Clear the last
	# completed value here so a caller can never consume stale attribution after a
	# later call, including a call that returns before snapshot capture.
	_last_plan_timing_profile.clear()
	_active_plan_timing_profile = {
		"snapshotUsec": 0,
		"snapshotCount": 0,
		"validationUsec": 0,
		"validationCount": 0,
		"validationPreflightGoalUsec": 0,
		"validationPreflightGoalCount": 0,
		"validationPreflightStartUsec": 0,
		"validationPreflightStartCount": 0,
		"validationSearchTransitionUsec": 0,
		"validationSearchTransitionCount": 0,
		"validationFinalizeStartUsec": 0,
		"validationFinalizeStartCount": 0,
		"validationFinalizeTransitionUsec": 0,
		"validationFinalizeTransitionCount": 0,
		"doorSignatureUsec": 0,
		"doorSignatureCells": 0,
		"doorSignatureDoors": 0,
		"dynamicSignatureUsec": 0,
		"dynamicSignatureCells": 0,
		"dynamicSignatureOccupied": 0,
		"finalizationAssemblyUsec": 0,
		"cheapStepsThisCall": 0
	}


func _accumulate_plan_timing(key: String, elapsed_usec: int) -> void:
	if _active_plan_timing_profile.is_empty():
		return
	_active_plan_timing_profile[key] = maxi(0, int(_active_plan_timing_profile.get(key, 0))) + maxi(0, elapsed_usec)


func _record_plan_validation_timing(kind: String, start_usec: int) -> void:
	var elapsed_usec := maxi(0, Time.get_ticks_usec() - start_usec)
	_accumulate_plan_timing("validationUsec", elapsed_usec)
	_active_plan_timing_profile["validationCount"] = int(_active_plan_timing_profile.get("validationCount", 0)) + 1
	var usec_key := "validation%sUsec" % kind
	var count_key := "validation%sCount" % kind
	_accumulate_plan_timing(usec_key, elapsed_usec)
	_active_plan_timing_profile[count_key] = int(_active_plan_timing_profile.get(count_key, 0)) + 1


func _finish_plan_timing_profile(result: Dictionary, plan_start_usec: int, loop_start_usec := 0, cheap_steps_this_call := 0) -> Dictionary:
	var finished_usec := Time.get_ticks_usec()
	var total_usec := maxi(0, finished_usec - plan_start_usec)
	var loop_gross_usec := maxi(0, finished_usec - loop_start_usec) if loop_start_usec > 0 else 0
	var snapshot_usec := maxi(0, int(_active_plan_timing_profile.get("snapshotUsec", 0)))
	var validation_usec := maxi(0, int(_active_plan_timing_profile.get("validationUsec", 0)))
	var door_signature_usec := maxi(0, int(_active_plan_timing_profile.get("doorSignatureUsec", 0)))
	var dynamic_signature_usec := maxi(0, int(_active_plan_timing_profile.get("dynamicSignatureUsec", 0)))
	var finalization_assembly_usec := maxi(0, int(_active_plan_timing_profile.get("finalizationAssemblyUsec", 0)))
	var nested_loop_usec := validation_usec + door_signature_usec + dynamic_signature_usec + finalization_assembly_usec
	var cheap_bookkeeping_usec := maxi(0, loop_gross_usec - nested_loop_usec)
	var setup_residual_usec := maxi(0, total_usec - snapshot_usec - loop_gross_usec)
	_active_plan_timing_profile["totalUsec"] = total_usec
	_active_plan_timing_profile["loopGrossUsec"] = loop_gross_usec
	_active_plan_timing_profile["cheapBookkeepingResidualUsec"] = cheap_bookkeeping_usec
	_active_plan_timing_profile["setupResidualUsec"] = setup_residual_usec
	_active_plan_timing_profile["nestedLoopUsec"] = nested_loop_usec
	_active_plan_timing_profile["cheapStepsThisCall"] = maxi(0, cheap_steps_this_call)
	_active_plan_timing_profile["accountedUsec"] = snapshot_usec + loop_gross_usec + setup_residual_usec
	_active_plan_timing_profile["arithmeticBalanced"] = (
		total_usec == snapshot_usec + loop_gross_usec + setup_residual_usec
		and loop_gross_usec == nested_loop_usec + cheap_bookkeeping_usec
	)
	_active_plan_timing_profile["classification"] = String(result.get("classification", result.get("status", "")))
	_active_plan_timing_profile["reason"] = String(result.get("reason", ""))
	_last_plan_timing_profile = _active_plan_timing_profile.duplicate(true)
	_active_plan_timing_profile.clear()
	return result


func plan_route(entry: Dictionary, start_cell: Vector2i, candidate_cells: Array, options := {}) -> Dictionary:
	var plan_timing_start_usec := Time.get_ticks_usec()
	_begin_plan_timing_profile()
	var actor_key := _search_actor_key(entry)
	var request_identity := String(options.get("requestIdentity", ""))
	if world_adapter == null:
		return _finish_plan_timing_profile(_result(false, CLASS_PENDING_NAV_DATA, "missing_world_adapter", [], [], {
			"collisionBacked": true,
			"generatedWorldInformed": true
		}), plan_timing_start_usec)
	var allow_outside := bool(options.get("allowOutside", false))
	var moving_home := bool(options.get("movingHome", false))
	var ignore_dynamic := bool(options.get("ignoreDynamic", false))
	var max_expansions := maxi(1, int(options.get("maxExpansions", 4096)))
	var semantic_kind := String(options.get("semanticKind", ""))
	var avoid_lookup := _avoid_lookup_from_options(options)
	var avoid_cells := _cell_array(avoid_lookup.keys())
	var start_position = _route_start_position(start_cell, options)
	var snapshot_start_usec := Time.get_ticks_usec()
	var snapshot_result := _build_snapshot(entry, allow_outside, moving_home)
	_accumulate_plan_timing("snapshotUsec", Time.get_ticks_usec() - snapshot_start_usec)
	_active_plan_timing_profile["snapshotCount"] = int(_active_plan_timing_profile.get("snapshotCount", 0)) + 1
	if not bool(snapshot_result.get("ok", false)):
		var pending_class := String(snapshot_result.get("classification", CLASS_PENDING_NAV_DATA))
		return _finish_plan_timing_profile(_result(false, pending_class, String(snapshot_result.get("reason", "snapshot_not_ready")), [], [], {
			"collisionBacked": true,
			"generatedWorldInformed": true,
			"snapshot": snapshot_result
		}), plan_timing_start_usec)
	var snapshot: Dictionary = snapshot_result.get("snapshot", {})
	var candidates := _normalize_cells(candidate_cells)
	# Probe-repair avoids are collision findings, not soft route preferences.  A
	# failed interaction pose must not remain an eligible goal, otherwise A* can
	# repeatedly return the same terminal cell that the body probe just rejected.
	# The player and NPC callers both retain every other semantic candidate.
	var avoided_goal_cells: Array = []
	for candidate in candidates.duplicate():
		if avoid_lookup.has(candidate) and candidate != start_cell:
			candidates.erase(candidate)
			avoided_goal_cells.append(candidate)
	if candidates.is_empty():
		_clear_terminal_search_for_actor_request(actor_key, request_identity)
		return _finish_plan_timing_profile(_result(false, CLASS_UNREACHABLE_STATIC, "all_candidate_cells_avoided_by_probe", [], [], {
			"collisionBacked": true,
			"generatedWorldInformed": true,
			"rejectedGoals": [],
			"avoidCells": avoid_cells,
			"avoidedGoalCells": avoided_goal_cells
		}), plan_timing_start_usec)
	var search_key := _search_key(entry, request_identity, start_cell, candidates, snapshot, allow_outside, moving_home, ignore_dynamic, semantic_kind, avoid_cells)
	_clear_replaced_actor_search(actor_key, search_key)
	var job: Dictionary = search_jobs.get(search_key, {}) if search_jobs.get(search_key, {}) is Dictionary else {}
	var observed_cells: Dictionary = job.get("observedCells", {}) if job.get("observedCells", {}) is Dictionary else {}
	var observed_tiles: Dictionary = job.get("observedTiles", {}) if job.get("observedTiles", {}) is Dictionary else {}
	if observed_cells.is_empty() and observed_tiles.is_empty():
		_observe_search_source_cell(observed_cells, observed_tiles, start_cell)
		for candidate in candidates:
			_observe_search_source_cell(observed_cells, observed_tiles, candidate)
	var current_search_revision := _search_snapshot_revision(snapshot, observed_cells.keys(), observed_tiles.keys())
	var expansions_per_call := maxi(1, int(options.get("expansionsPerCall", DEFAULT_EXPANSIONS_PER_CALL)))
	var validation_steps_per_call := maxi(1, int(options.get("validationStepsPerCall", DEFAULT_VALIDATION_STEPS_PER_CALL)))
	var cheap_steps_per_call := maxi(1, int(options.get("cheapStepsPerCall", DEFAULT_CHEAP_STEPS_PER_CALL)))
	if job.is_empty():
		var prevalidated_goal_lookup := {}
		var prevalidated_revision := String(options.get("prevalidatedGoalSnapshotRevision", ""))
		if prevalidated_revision == current_search_revision or prevalidated_revision == _search_snapshot_revision(snapshot):
			for value in options.get("prevalidatedGoalCells", []):
				if value is Vector2i and candidates.has(value):
					prevalidated_goal_lookup[value] = true
		var all_goals_prevalidated := prevalidated_goal_lookup.size() == candidates.size()
		var initial_target_lookup := { "_strictTargetCollision": true }
		for prevalidated_cell in prevalidated_goal_lookup.keys():
			initial_target_lookup[prevalidated_cell] = true
		job = {
			"actorKey": actor_key,
			"requestIdentity": request_identity,
			"phase": "preflight_goals",
			"candidateCells": candidates.duplicate(),
			"observedCells": observed_cells,
			"observedTiles": observed_tiles,
			"preflightIndex": candidates.size() if all_goals_prevalidated else 0,
			"acceptedGoals": prevalidated_goal_lookup,
			"rejectedGoals": [],
			"targetLookup": initial_target_lookup,
			"prevalidatedGoalsReused": all_goals_prevalidated,
			"startValidation": {},
			"open": [],
			"closed": {},
			"gScore": {},
			"parent": {},
			"cellProofs": {},
			"visitedSample": [],
			"blockedRecords": [],
			"doorEdges": [],
			"expansions": 0,
			"sequence": 0,
			"currentRecord": {},
			"currentNeighbors": [],
			"nextNeighborIndex": 0,
			"deferredEdges": [],
			"reconstructCursor": INVALID_CELL,
			"reverseRoute": [],
			"materializeIndex": -1,
			"pendingRoute": [],
			"pendingRouteLookup": {},
			"finalizeIndex": 0,
			"finalCellProofs": [],
			"finalDoorEdges": [],
			"finalActions": {},
			"finalWaypoints": [],
			"finalizationSnapshotRevision": "",
			"lastObservedFinalizationSnapshotRevision": "",
			"finalizationDoorScanRevision": "",
			"finalizationDoorScanIndex": 0,
			"finalizationDoorParts": [],
			"finalizationDoorCells": [],
			"finalizationDoorExpected": [],
			"finalizationDoorVerifyRevision": "",
			"finalizationDoorVerifyIndex": 0,
			"finalizationDynamicPhase": "capture",
			"finalizationDynamicIndex": 0,
			"finalizationDynamicOccupied": [],
			"finalizationDynamicExpected": [],
			"finalizationRestartCount": 0,
			"finalizationRestartedThisCall": false,
			"startedSnapshotRevision": current_search_revision,
			"latestSnapshotRevision": current_search_revision,
			"snapshotChanged": false
		}
		search_jobs[search_key] = job
		active_search_key_by_actor[actor_key] = search_key
	# Call-local telemetry must be reset before every early return, including a
	# source-revision invalidation detected below.
	job["finalizationRestartedThisCall"] = false
	if current_search_revision != String(job.get("startedSnapshotRevision", current_search_revision)):
		job["snapshotChanged"] = true
		job["latestSnapshotRevision"] = current_search_revision
		var changed_proof := _search_progress_proof(job, snapshot, current_search_revision, 0, 0, validation_steps_per_call, 0, cheap_steps_per_call, max_expansions, avoid_cells)
		changed_proof["invalidatedPhase"] = String(job.get("phase", "search"))
		changed_proof["invalidatedNeighborIndex"] = int(job.get("nextNeighborIndex", 0))
		changed_proof["invalidatedFinalizeIndex"] = int(job.get("finalizeIndex", 0))
		_clear_search_job(actor_key, search_key)
		return _finish_plan_timing_profile(_result(false, CLASS_PENDING_BUDGET, "route_snapshot_changed", [], _job_visited_sample(job), changed_proof), plan_timing_start_usec)
	job["latestSnapshotRevision"] = current_search_revision
	# The search key treats goals as a set, so a resumed caller may supply the same
	# goals in a different order. The persisted cursor must always index the job's
	# original normalized array rather than that later call's ordering.
	var job_candidates: Array = job.get("candidateCells", []) if job.get("candidateCells", []) is Array else []
	var accepted_goals: Dictionary = job.get("acceptedGoals", {}) if job.get("acceptedGoals", {}) is Dictionary else {}
	var rejected_goals: Array = job.get("rejectedGoals", []) if job.get("rejectedGoals", []) is Array else []
	var target_lookup: Dictionary = job.get("targetLookup", { "_strictTargetCollision": true }) if job.get("targetLookup", {}) is Dictionary else { "_strictTargetCollision": true }
	var open: Array = job.get("open", []) if job.get("open", []) is Array else []
	var closed: Dictionary = job.get("closed", {}) if job.get("closed", {}) is Dictionary else {}
	var g_score: Dictionary = job.get("gScore", {}) if job.get("gScore", {}) is Dictionary else {}
	var parent: Dictionary = job.get("parent", {}) if job.get("parent", {}) is Dictionary else {}
	var cell_proofs: Dictionary = job.get("cellProofs", {}) if job.get("cellProofs", {}) is Dictionary else {}
	var blocked_records: Array = job.get("blockedRecords", []) if job.get("blockedRecords", []) is Array else []
	var door_edges: Array = job.get("doorEdges", []) if job.get("doorEdges", []) is Array else []
	var visited_sample: Array = job.get("visitedSample", []) if job.get("visitedSample", []) is Array else []
	var expansions := int(job.get("expansions", 0))
	var sequence := int(job.get("sequence", 1))
	var expansions_this_call := 0
	var validation_steps_this_call := 0
	var cheap_steps_this_call := 0
	var pending_reason := "validation_step_budget_deferred"
	var loop_start_usec := Time.get_ticks_usec()
	while cheap_steps_this_call < cheap_steps_per_call:
		var phase := String(job.get("phase", "preflight_goals"))
		if phase == "preflight_goals":
			var preflight_index := int(job.get("preflightIndex", 0))
			if preflight_index < job_candidates.size():
				if validation_steps_this_call >= validation_steps_per_call:
					break
				var candidate: Vector2i = job_candidates[preflight_index]
				var validation_start_usec := Time.get_ticks_usec()
				var validation := validate_goal_cell(entry, snapshot, candidate, allow_outside, moving_home, ignore_dynamic)
				if bool(validation.get("ok", false)):
					validation = validate_semantic_goal_cell(entry, candidate, semantic_kind, snapshot)
				_record_plan_validation_timing("PreflightGoal", validation_start_usec)
				if bool(validation.get("ok", false)):
					accepted_goals[candidate] = true
					target_lookup[candidate] = true
				else:
					rejected_goals.append(validation)
				job["preflightIndex"] = preflight_index + 1
				validation_steps_this_call += 1
				continue
			if accepted_goals.is_empty():
				_clear_search_job(actor_key, search_key)
				return _finish_plan_timing_profile(_result(false, CLASS_INVALID_GOAL, "no_valid_goal_cell", [], [], {
					"collisionBacked": true,
					"generatedWorldInformed": true,
					"rejectedGoals": rejected_goals,
					"validationStepsThisCall": validation_steps_this_call,
					"validationStepLimit": validation_steps_per_call,
					"searchPhase": phase
				}), plan_timing_start_usec, loop_start_usec, cheap_steps_this_call)
			job["phase"] = "preflight_start"
			cheap_steps_this_call += 1
			continue
		if phase == "preflight_start":
			if validation_steps_this_call >= validation_steps_per_call:
				break
			var validation_start_usec := Time.get_ticks_usec()
			var start_validation := validate_route_cell(entry, snapshot, start_cell, target_lookup, allow_outside, moving_home, ignore_dynamic, true)
			_record_plan_validation_timing("PreflightStart", validation_start_usec)
			validation_steps_this_call += 1
			job["startValidation"] = start_validation
			if not bool(start_validation.get("ok", false)):
				_clear_search_job(actor_key, search_key)
				var start_class := _classification_for_block_reason(String(start_validation.get("reason", "")))
				return _finish_plan_timing_profile(_result(false, start_class, String(start_validation.get("reason", "invalid_start")), [], [], {
					"collisionBacked": true,
					"generatedWorldInformed": true,
					"start": start_validation,
					"rejectedGoals": rejected_goals,
					"validationStepsThisCall": validation_steps_this_call,
					"validationStepLimit": validation_steps_per_call,
					"searchPhase": phase
				}), plan_timing_start_usec, loop_start_usec, cheap_steps_this_call)
			if accepted_goals.has(start_cell):
				_clear_search_job(actor_key, search_key)
				var single_route := [start_cell]
				var single_waypoint: Vector3 = start_position if start_position is Vector3 else _cell_position(start_cell)
				return _finish_plan_timing_profile(_result_with_waypoints(true, CLASS_REACHABLE, "already_at_goal", single_route, [], {
					"collisionBacked": true,
					"generatedWorldInformed": true,
					"snapshotRevision": String(snapshot.get("revision", "")),
					"acceptedGoals": _cell_array(accepted_goals.keys()),
					"rejectedGoals": rejected_goals,
					"cellProof": [start_validation],
					"validationStepsThisCall": validation_steps_this_call,
					"validationStepLimit": validation_steps_per_call,
					"searchPhase": "complete"
				}, {}, [single_waypoint]), plan_timing_start_usec, loop_start_usec, cheap_steps_this_call)
			open.append({
				"cell": start_cell,
				"g": 0,
				"f": _goal_heuristic(start_cell, accepted_goals),
				"sequence": 0
			})
			g_score[start_cell] = 0
			cell_proofs[start_cell] = start_validation
			sequence = 1
			job["phase"] = "search"
			cheap_steps_this_call += 1
			continue
		if phase == "reconstruct":
			var reconstruct_cursor: Vector2i = job.get("reconstructCursor", INVALID_CELL)
			if reconstruct_cursor == INVALID_CELL:
				_clear_search_job(actor_key, search_key)
				return _finish_plan_timing_profile(_result(false, CLASS_PENDING_BUDGET, "route_snapshot_changed", [], visited_sample.duplicate(), {
					"collisionBacked": true,
					"generatedWorldInformed": true,
					"completedRouteValidation": { "ok": false, "reason": "missing_reconstruction_cursor" },
					"validationStepsThisCall": validation_steps_this_call,
					"validationStepLimit": validation_steps_per_call,
					"searchPhase": phase
				}), plan_timing_start_usec, loop_start_usec, cheap_steps_this_call)
			var reverse_route: Array = job.get("reverseRoute", []) if job.get("reverseRoute", []) is Array else []
			reverse_route.append(reconstruct_cursor)
			job["reverseRoute"] = reverse_route
			cheap_steps_this_call += 1
			if reconstruct_cursor == start_cell:
				job["phase"] = "materialize_route"
				job["materializeIndex"] = reverse_route.size() - 1
				continue
			if not parent.has(reconstruct_cursor) or not (parent.get(reconstruct_cursor) is Vector2i):
				_clear_search_job(actor_key, search_key)
				return _finish_plan_timing_profile(_result(false, CLASS_PENDING_BUDGET, "route_snapshot_changed", [], visited_sample.duplicate(), {
					"collisionBacked": true,
					"generatedWorldInformed": true,
					"completedRouteValidation": { "ok": false, "reason": "missing_route_parent", "cell": reconstruct_cursor },
					"validationStepsThisCall": validation_steps_this_call,
					"validationStepLimit": validation_steps_per_call,
					"searchPhase": phase
				}), plan_timing_start_usec, loop_start_usec, cheap_steps_this_call)
			job["reconstructCursor"] = parent[reconstruct_cursor]
			continue
		if phase == "materialize_route":
			var reverse_route: Array = job.get("reverseRoute", []) if job.get("reverseRoute", []) is Array else []
			var materialize_index := int(job.get("materializeIndex", -1))
			if materialize_index < 0:
				job["phase"] = "finalize"
				_reset_finalization_identity(job, true)
				cheap_steps_this_call += 1
				continue
			var pending_route: Array = job.get("pendingRoute", []) if job.get("pendingRoute", []) is Array else []
			var materialized_cell: Vector2i = reverse_route[materialize_index]
			pending_route.append(materialized_cell)
			job["pendingRoute"] = pending_route
			var pending_route_lookup: Dictionary = job.get("pendingRouteLookup", {}) if job.get("pendingRouteLookup", {}) is Dictionary else {}
			pending_route_lookup[materialized_cell] = true
			job["pendingRouteLookup"] = pending_route_lookup
			job["materializeIndex"] = materialize_index - 1
			cheap_steps_this_call += 1
			continue
		if phase == "finalize":
			var started_finalization_revision := String(job.get("finalizationSnapshotRevision", ""))
			if started_finalization_revision == "":
				var identity_result := _advance_finalization_identity(snapshot, job, cheap_steps_per_call - cheap_steps_this_call)
				cheap_steps_this_call += int(identity_result.get("steps", 0))
				if not bool(identity_result.get("complete", false)):
					pending_reason = "cheap_step_budget_deferred"
					break
				started_finalization_revision = String(identity_result.get("signature", ""))
				job["finalizationSnapshotRevision"] = started_finalization_revision
				job["lastObservedFinalizationSnapshotRevision"] = started_finalization_revision
			var route: Array = job.get("pendingRoute", []) if job.get("pendingRoute", []) is Array else []
			var finalize_index := int(job.get("finalizeIndex", 0))
			if finalize_index >= route.size():
				job["phase"] = "finalize_verify"
				_reset_finalization_identity_scan(job)
				cheap_steps_this_call += 1
				continue
			var cell_value = route[finalize_index]
			if validation_steps_this_call >= validation_steps_per_call:
				break
			if not (cell_value is Vector2i):
				var invalid_cell_proof := _search_progress_proof(job, snapshot, current_search_revision, expansions_this_call, validation_steps_this_call, validation_steps_per_call, cheap_steps_this_call, cheap_steps_per_call, max_expansions, avoid_cells)
				invalid_cell_proof["completedRouteValidation"] = { "ok": false, "reason": "invalid_route_cell", "index": finalize_index }
				_clear_search_job(actor_key, search_key)
				return _finish_plan_timing_profile(_result(false, CLASS_PENDING_BUDGET, "route_snapshot_changed", [], visited_sample.duplicate(), invalid_cell_proof), plan_timing_start_usec, loop_start_usec, cheap_steps_this_call)
			var route_cell: Vector2i = cell_value
			var completed_cell := { "ok": true, "cell": route_cell, "validatedByTransition": finalize_index > 0 }
			var completed_transition := { "ok": true }
			var validation_start_usec := Time.get_ticks_usec()
			if finalize_index == 0:
				completed_cell = validate_route_cell(entry, snapshot, route_cell, target_lookup, allow_outside, moving_home, ignore_dynamic, true)
				_record_plan_validation_timing("FinalizeStart", validation_start_usec)
			else:
				var previous: Vector2i = route[finalize_index - 1]
				completed_transition = validate_transition(entry, snapshot, previous, route_cell, target_lookup, ignore_dynamic)
				_record_plan_validation_timing("FinalizeTransition", validation_start_usec)
			validation_steps_this_call += 1
			if not bool(completed_cell.get("ok", false)) or not bool(completed_transition.get("ok", false)):
				var failed_validation: Dictionary = completed_cell if not bool(completed_cell.get("ok", false)) else completed_transition
				var failed_finalization_proof := _search_progress_proof(job, snapshot, current_search_revision, expansions_this_call, validation_steps_this_call, validation_steps_per_call, cheap_steps_this_call, cheap_steps_per_call, max_expansions, avoid_cells)
				failed_finalization_proof["completedRouteValidation"] = { "ok": false, "reason": String(failed_validation.get("reason", "route_cell_invalid")), "index": finalize_index, "cell": route_cell, "validation": failed_validation }
				_clear_search_job(actor_key, search_key)
				return _finish_plan_timing_profile(_result(false, CLASS_PENDING_BUDGET, "route_snapshot_changed", [], visited_sample.duplicate(), failed_finalization_proof), plan_timing_start_usec, loop_start_usec, cheap_steps_this_call)
			var assembly_start_usec := Time.get_ticks_usec()
			var final_cell_proofs: Array = job.get("finalCellProofs", []) if job.get("finalCellProofs", []) is Array else []
			final_cell_proofs.append(completed_cell)
			job["finalCellProofs"] = final_cell_proofs
			var final_waypoints: Array = job.get("finalWaypoints", []) if job.get("finalWaypoints", []) is Array else []
			final_waypoints.append(start_position if finalize_index == 0 and start_position is Vector3 else _cell_position(route_cell))
			job["finalWaypoints"] = final_waypoints
			if finalize_index > 0 and bool(completed_transition.get("doorEdge", false)):
				var previous_cell: Vector2i = route[finalize_index - 1]
				var final_edge := _completed_door_edge(snapshot, previous_cell, route_cell, completed_transition)
				var final_door_edges: Array = job.get("finalDoorEdges", []) if job.get("finalDoorEdges", []) is Array else []
				final_door_edges.append(final_edge)
				job["finalDoorEdges"] = final_door_edges
				var final_actions: Dictionary = job.get("finalActions", {}) if job.get("finalActions", {}) is Dictionary else {}
				_append_door_action(final_actions, final_edge)
				job["finalActions"] = final_actions
			job["finalizeIndex"] = finalize_index + 1
			_accumulate_plan_timing("finalizationAssemblyUsec", Time.get_ticks_usec() - assembly_start_usec)
			continue
		if phase == "finalize_verify":
			var verification_result := _advance_finalization_identity(snapshot, job, cheap_steps_per_call - cheap_steps_this_call)
			cheap_steps_this_call += int(verification_result.get("steps", 0))
			if not bool(verification_result.get("complete", false)):
				pending_reason = "cheap_step_budget_deferred"
				break
			var verified_revision := String(verification_result.get("signature", ""))
			job["lastObservedFinalizationSnapshotRevision"] = verified_revision
			if verified_revision != String(job.get("finalizationSnapshotRevision", "")):
				# Topology is still usable, but a door or actor changed while the
				# completion certificate was assembled. Discard only the partial
				# certificate and recapture its bounded route-local identity.
				job["finalizationRestartCount"] = int(job.get("finalizationRestartCount", 0)) + 1
				job["finalizationRestartedThisCall"] = true
				_reset_finalization_identity(job, false)
				job["phase"] = "finalize"
				job["finalizeIndex"] = 0
				job["finalCellProofs"] = []
				job["finalDoorEdges"] = []
				job["finalActions"] = {}
				job["finalWaypoints"] = []
				continue
			var assembly_start_usec := Time.get_ticks_usec()
			var route: Array = job.get("pendingRoute", []) if job.get("pendingRoute", []) is Array else []
			var final_proof := _search_progress_proof(job, snapshot, current_search_revision, expansions_this_call, validation_steps_this_call, validation_steps_per_call, cheap_steps_this_call, cheap_steps_per_call, max_expansions, avoid_cells)
			final_proof["doorEdges"] = job.get("finalDoorEdges", [])
			final_proof["exploredDoorEdges"] = door_edges
			final_proof["cellProof"] = job.get("finalCellProofs", [])
			final_proof["searchPhase"] = "complete"
			var final_actions: Dictionary = job.get("finalActions", {}) if job.get("finalActions", {}) is Dictionary else {}
			var final_waypoints: Array = job.get("finalWaypoints", []) if job.get("finalWaypoints", []) is Array else []
			_clear_search_job(actor_key, search_key)
			var completed_result := _result_with_waypoints(true, CLASS_REACHABLE, "route_found", route, visited_sample.duplicate(), final_proof, final_actions, final_waypoints)
			_accumulate_plan_timing("finalizationAssemblyUsec", Time.get_ticks_usec() - assembly_start_usec)
			return _finish_plan_timing_profile(completed_result, plan_timing_start_usec, loop_start_usec, cheap_steps_this_call)
		# Search phase. Expansion publishes four independently resumable edge
		# records. Their A* lower bound chooses work direction-neutrally, while the
		# reserved virtual sequence retains the legacy eager neighbor/tie order.
		var deferred_edges: Array = job.get("deferredEdges", []) if job.get("deferredEdges", []) is Array else []
		var deferred_index := 0 if not deferred_edges.is_empty() else -1
		var deferred_bound := int((deferred_edges[0] as Dictionary).get("bound", 2147483000)) if not deferred_edges.is_empty() and deferred_edges[0] is Dictionary else 2147483000
		var open_bound := int((open[0] as Dictionary).get("f", 2147483000)) if not open.is_empty() and open[0] is Dictionary else 2147483000
		if deferred_index < 0 or (not open.is_empty() and open_bound < deferred_bound):
			if expansions >= max_expansions:
				pending_reason = "expansion_budget_exhausted"
				break
			if expansions_this_call >= expansions_per_call:
				pending_reason = "search_budget_deferred"
				break
			var current_record: Dictionary = {}
			while not open.is_empty():
				if cheap_steps_this_call >= cheap_steps_per_call:
					pending_reason = "cheap_step_budget_deferred"
					break
				current_record = _open_heap_pop(open)
				cheap_steps_this_call += 1
				var popped_cell: Vector2i = current_record.get("cell", INVALID_CELL)
				if popped_cell != INVALID_CELL and not closed.has(popped_cell):
					break
				current_record = {}
			if current_record.is_empty():
				if pending_reason == "cheap_step_budget_deferred":
					break
				if not deferred_edges.is_empty():
					continue
				_clear_search_job(actor_key, search_key)
				var terminal_class := CLASS_UNREACHABLE_STATIC
				var terminal_reason := "no_static_route"
				for blocked in blocked_records:
					if blocked is Dictionary and String((blocked as Dictionary).get("classification", "")) == CLASS_BLOCKED_DYNAMIC:
						terminal_class = CLASS_BLOCKED_DYNAMIC
						terminal_reason = "dynamic_blocker_prevents_route"
						break
				var terminal_proof := _search_progress_proof(job, snapshot, current_search_revision, expansions_this_call, validation_steps_this_call, validation_steps_per_call, cheap_steps_this_call, cheap_steps_per_call, max_expansions, avoid_cells)
				return _finish_plan_timing_profile(_result(false, terminal_class, terminal_reason, [], visited_sample.duplicate(), terminal_proof), plan_timing_start_usec, loop_start_usec, cheap_steps_this_call)
			var current: Vector2i = current_record.get("cell", INVALID_CELL)
			closed[current] = true
			if visited_sample.size() < MAX_RECORDED_VISITED:
				visited_sample.append(current)
			job["visitedSample"] = visited_sample
			if accepted_goals.has(current):
				job["phase"] = "reconstruct"
				job["reconstructCursor"] = current
				job["reverseRoute"] = []
				job["materializeIndex"] = -1
				job["pendingRoute"] = []
				job["pendingRouteLookup"] = {}
				job["finalizeIndex"] = 0
				job["finalCellProofs"] = []
				job["finalDoorEdges"] = []
				job["finalActions"] = {}
				job["finalWaypoints"] = []
				cheap_steps_this_call += 1
				continue
			expansions += 1
			expansions_this_call += 1
			job["expansions"] = expansions
			var neighbors := _neighbors(current)
			var tentative_g := int(current_record.get("g", 0)) + 1
			for neighbor_index in range(neighbors.size()):
				var neighbor: Vector2i = neighbors[neighbor_index]
				_deferred_heap_push(deferred_edges, {
					"record": current_record,
					"fromCell": current,
					"neighbor": neighbor,
					"neighborIndex": neighbor_index,
					"tentativeG": tentative_g,
					"bound": tentative_g + _goal_heuristic(neighbor, accepted_goals),
					"sequence": sequence + neighbor_index
				})
			sequence += neighbors.size()
			job["sequence"] = sequence
			job["deferredEdges"] = deferred_edges
			cheap_steps_this_call += 1
			continue
		var edge: Dictionary = deferred_edges[deferred_index]
		var current: Vector2i = edge.get("fromCell", INVALID_CELL)
		var neighbor: Vector2i = edge.get("neighbor", INVALID_CELL)
		var neighbor_index := int(edge.get("neighborIndex", 0))
		var tentative_g := int(edge.get("tentativeG", 0))
		if closed.has(neighbor):
			_deferred_heap_pop(deferred_edges)
			job["deferredEdges"] = deferred_edges
			cheap_steps_this_call += 1
			continue
		if _route_avoid_blocks_cell(avoid_lookup, neighbor, start_cell, accepted_goals):
			_deferred_heap_pop(deferred_edges)
			job["deferredEdges"] = deferred_edges
			_append_bounded(blocked_records, _avoid_block_record(current, neighbor), MAX_RECORDED_BLOCKS)
			cheap_steps_this_call += 1
			continue
		if g_score.has(neighbor) and tentative_g >= int(g_score.get(neighbor, 2147483000)):
			_deferred_heap_pop(deferred_edges)
			job["deferredEdges"] = deferred_edges
			cheap_steps_this_call += 1
			continue
		if validation_steps_this_call >= validation_steps_per_call:
			break
		_deferred_heap_pop(deferred_edges)
		job["deferredEdges"] = deferred_edges
		job["currentRecord"] = edge.get("record", {}) if edge.get("record", {}) is Dictionary else {}
		job["currentNeighbors"] = [neighbor]
		job["nextNeighborIndex"] = neighbor_index
		_observe_search_source_cell(observed_cells, observed_tiles, current)
		_observe_search_source_cell(observed_cells, observed_tiles, neighbor)
		validation_steps_this_call += 1
		var validation_start_usec := Time.get_ticks_usec()
		var cell_validation := { "ok": true, "cell": neighbor, "validatedByTransition": _adapter_has("cell_transition_pathable") }
		var transition := { "ok": true }
		if _adapter_has("cell_transition_pathable"):
			transition = validate_transition(entry, snapshot, current, neighbor, target_lookup, ignore_dynamic)
		else:
			cell_validation = validate_route_cell(entry, snapshot, neighbor, target_lookup, allow_outside, moving_home, ignore_dynamic, false)
		_record_plan_validation_timing("SearchTransition", validation_start_usec)
		job["currentRecord"] = {}
		job["currentNeighbors"] = []
		job["nextNeighborIndex"] = 0
		if not bool(cell_validation.get("ok", false)):
			_append_bounded(blocked_records, cell_validation, MAX_RECORDED_BLOCKS)
			continue
		if not bool(transition.get("ok", false)):
			_append_bounded(blocked_records, transition, MAX_RECORDED_BLOCKS)
			continue
		g_score[neighbor] = tentative_g
		parent[neighbor] = current
		cell_proofs[neighbor] = cell_validation
		if bool(transition.get("doorEdge", false)):
			_append_bounded(door_edges, transition, MAX_RECORDED_BLOCKS)
		_open_heap_push(open, {
			"cell": neighbor,
			"g": tentative_g,
			"f": tentative_g + _goal_heuristic(neighbor, accepted_goals),
			"sequence": int(edge.get("sequence", sequence))
		})
	if cheap_steps_this_call >= cheap_steps_per_call and pending_reason == "validation_step_budget_deferred":
		pending_reason = "cheap_step_budget_deferred"
	_update_search_job(job, open, closed, g_score, parent, cell_proofs, blocked_records, door_edges, expansions, sequence)
	job["startedSnapshotRevision"] = _search_snapshot_revision(snapshot, observed_cells.keys(), observed_tiles.keys())
	var pending_proof := _search_progress_proof(job, snapshot, current_search_revision, expansions_this_call, validation_steps_this_call, validation_steps_per_call, cheap_steps_this_call, cheap_steps_per_call, max_expansions, avoid_cells)
	return _finish_plan_timing_profile(_result(false, CLASS_PENDING_BUDGET, pending_reason, [], visited_sample.duplicate(), pending_proof), plan_timing_start_usec, loop_start_usec, cheap_steps_this_call)


func _job_visited_sample(job: Dictionary) -> Array:
	var value = job.get("visitedSample", [])
	return (value as Array).duplicate() if value is Array else []


func _search_progress_proof(job: Dictionary, snapshot: Dictionary, current_search_revision: String, expansions_this_call: int, validation_steps_this_call: int, validation_step_limit: int, cheap_steps_this_call: int, cheap_step_limit: int, max_expansions: int, avoid_cells: Array) -> Dictionary:
	var accepted_goals: Dictionary = job.get("acceptedGoals", {}) if job.get("acceptedGoals", {}) is Dictionary else {}
	var rejected_goals: Array = job.get("rejectedGoals", []) if job.get("rejectedGoals", []) is Array else []
	var blocked_records: Array = job.get("blockedRecords", []) if job.get("blockedRecords", []) is Array else []
	var explored_door_edges: Array = job.get("doorEdges", []) if job.get("doorEdges", []) is Array else []
	var closed: Dictionary = job.get("closed", {}) if job.get("closed", {}) is Dictionary else {}
	return {
		"collisionBacked": true,
		"generatedWorldInformed": true,
		"snapshotRevision": String(snapshot.get("revision", "")),
		"searchStartedRevision": String(job.get("startedSnapshotRevision", "")),
		"searchSnapshotRevision": current_search_revision,
		"searchSnapshotChanged": bool(job.get("snapshotChanged", false)),
		"acceptedGoals": _cell_array(accepted_goals.keys()),
		"rejectedGoals": rejected_goals,
		"preflightIndex": int(job.get("preflightIndex", 0)),
		"candidateCount": (job.get("candidateCells", []) as Array).size() if job.get("candidateCells", []) is Array else 0,
		"prevalidatedGoalsReused": bool(job.get("prevalidatedGoalsReused", false)),
		"blocked": blocked_records,
		"doorEdges": explored_door_edges,
		"maxExpansions": max_expansions,
		"expansions": int(job.get("expansions", 0)),
		"expansionsThisCall": expansions_this_call,
		"validationStepsThisCall": validation_steps_this_call,
		"validationStepLimit": validation_step_limit,
		"cheapStepsThisCall": cheap_steps_this_call,
		"cheapStepLimit": cheap_step_limit,
		"searchPhase": String(job.get("phase", "search")),
		"neighborIndex": int(job.get("nextNeighborIndex", 0)),
		"reconstructCount": (job.get("reverseRoute", []) as Array).size() if job.get("reverseRoute", []) is Array else 0,
		"materializeIndex": int(job.get("materializeIndex", -1)),
		"finalizeIndex": int(job.get("finalizeIndex", 0)),
		"finalizationSnapshotRevision": String(job.get("finalizationSnapshotRevision", "")),
		"currentFinalizationSnapshotRevision": String(job.get("lastObservedFinalizationSnapshotRevision", "")),
		"finalizationRestartCount": int(job.get("finalizationRestartCount", 0)),
		"finalizationRestartedThisCall": bool(job.get("finalizationRestartedThisCall", false)),
		"visitedCount": closed.size(),
		"avoidCells": avoid_cells
	}


func _completed_door_edge(snapshot: Dictionary, from_cell: Vector2i, to_cell: Vector2i, transition: Dictionary) -> Dictionary:
	var result := transition.duplicate(false)
	var from_door = _door_at(snapshot, from_cell)
	var to_door = _door_at(snapshot, to_cell)
	var door = to_door if to_door != null else from_door
	result["doorEdge"] = true
	result["door"] = _door_summary(door)
	result["doorNode"] = door
	result["fromCell"] = from_cell
	result["toCell"] = to_cell
	return result


func _append_door_action(actions: Dictionary, edge: Dictionary) -> void:
	var door = edge.get("doorNode")
	if not (door is Node):
		return
	var from_cell: Vector2i = edge.get("fromCell", INVALID_CELL)
	var to_cell: Vector2i = edge.get("toCell", INVALID_CELL)
	if from_cell == INVALID_CELL or to_cell == INVALID_CELL:
		return
	var portal_id := _door_portal_id(door, to_cell)
	actions["%d,%d" % [to_cell.x, to_cell.y]] = {
		"kind": "door",
		"portalId": portal_id,
		"actionId": "open",
		"cell": to_cell,
		"entryCell": from_cell,
		"entryPosition": _cell_position(from_cell),
		"exitPosition": _cell_position(to_cell),
		"direction": _direction_for_step(from_cell, to_cell),
		"navLink": false,
		"requiresSmartObject": true,
		"enabled": true,
		"door": door
	}


func candidate_poses_for_target(entry: Dictionary, target: Dictionary, semantic_kind := "move", options := {}) -> Dictionary:
	if world_adapter == null:
		return { "ok": false, "classification": CLASS_PENDING_NAV_DATA, "reason": "missing_world_adapter", "candidates": [] }
	var allow_outside := bool(options.get("allowOutside", true))
	var moving_home := semantic_kind == "home_interior" or bool(options.get("movingHome", false))
	var raw_cells := _target_candidate_cells(entry, target, semantic_kind, allow_outside)
	if raw_cells.is_empty():
		return {
			"ok": false,
			"classification": CLASS_INVALID_GOAL,
			"reason": "no_candidate_cells",
			"candidates": []
		}
	var snapshot_result := _build_snapshot(entry, allow_outside, moving_home)
	if not bool(snapshot_result.get("ok", false)):
		return {
			"ok": false,
			"classification": snapshot_result.get("classification", CLASS_PENDING_NAV_DATA),
			"reason": snapshot_result.get("reason", "snapshot_not_ready"),
			"candidates": []
		}
	var snapshot: Dictionary = snapshot_result.get("snapshot", {})
	var actor_key := _search_actor_key(entry)
	var request_identity := String(options.get("requestIdentity", ""))
	var candidate_key := _candidate_search_key(
		actor_key,
		request_identity,
		raw_cells,
		semantic_kind,
		allow_outside,
		moving_home,
		_search_snapshot_revision(snapshot)
	)
	_clear_replaced_actor_candidate_job(actor_key, candidate_key)
	var job: Dictionary = candidate_jobs.get(candidate_key, {}) if candidate_jobs.get(candidate_key, {}) is Dictionary else {}
	if bool(job.get("completed", false)):
		var cached_result: Dictionary = job.get("result", {}) if job.get("result", {}) is Dictionary else {}
		if not cached_result.is_empty():
			var reused := cached_result.duplicate(true)
			reused["candidateResultReused"] = true
			reused["candidateValidationsThisCall"] = 0
			return reused
	if job.is_empty():
		job = {
			"actorKey": actor_key,
			"requestIdentity": request_identity,
			"nextIndex": 0,
			"acceptedCells": [],
			"rejected": []
		}
		candidate_jobs[candidate_key] = job
	var accepted_cells: Array = job.get("acceptedCells", []) if job.get("acceptedCells", []) is Array else []
	var rejected: Array = job.get("rejected", []) if job.get("rejected", []) is Array else []
	var next_index := clampi(int(job.get("nextIndex", 0)), 0, raw_cells.size())
	var validations_per_call := maxi(1, int(options.get("candidateValidationsPerCall", DEFAULT_CANDIDATE_VALIDATIONS_PER_CALL)))
	var validated_this_call := 0
	while next_index < raw_cells.size() and validated_this_call < validations_per_call:
		var cell: Vector2i = raw_cells[next_index]
		# Candidate selection is stable/static work. Live dynamic occupancy is
		# rechecked by the route search and then the collision probe before commit.
		var validation := validate_goal_cell(entry, snapshot, cell, allow_outside, moving_home, true)
		if bool(validation.get("ok", false)):
			validation = validate_semantic_goal_cell(entry, cell, semantic_kind, snapshot)
		if bool(validation.get("ok", false)):
			accepted_cells.append(cell)
		else:
			rejected.append(validation)
		next_index += 1
		validated_this_call += 1
	job["nextIndex"] = next_index
	job["acceptedCells"] = accepted_cells
	job["rejected"] = rejected
	candidate_jobs[candidate_key] = job
	if next_index < raw_cells.size():
		return {
			"ok": false,
			"classification": CLASS_PENDING_BUDGET,
			"reason": "candidate_validation_deferred",
			"candidates": [],
			"rejected": rejected.duplicate(true),
			"collisionBacked": true,
			"generatedWorldInformed": true,
			"candidateProgress": {
				"validated": next_index,
				"total": raw_cells.size(),
				"validatedThisCall": validated_this_call
			},
			"candidateValidationsThisCall": validated_this_call,
			"candidateSnapshotRevision": _search_snapshot_revision(snapshot)
		}
	var accepted: Array = []
	for cell_value in accepted_cells:
		if not (cell_value is Vector2i):
			continue
		var cell: Vector2i = cell_value
		var candidate := {
			"cell": cell,
			"position": _cell_position(cell),
			"semanticKind": semantic_kind,
			"proof": { "ok": true, "classification": CLASS_REACHABLE, "cell": cell, "staticCandidateValidation": true }
		}
		if target.get("interactionClaim", {}) is Dictionary:
			candidate["interactionClaim"] = (target.get("interactionClaim", {}) as Dictionary).duplicate(true)
		accepted.append(candidate)
	var result := {
		"ok": not accepted.is_empty(),
		"classification": CLASS_REACHABLE if not accepted.is_empty() else CLASS_INVALID_GOAL,
		"reason": "candidate_poses_found" if not accepted.is_empty() else "no_routeable_candidate_pose",
		"candidates": accepted,
		"rejected": rejected,
		"collisionBacked": true,
		"generatedWorldInformed": true,
		"candidateValidationsThisCall": validated_this_call,
		"candidateSnapshotRevision": _search_snapshot_revision(snapshot)
	}
	# The same active route request may need many A* slices. Candidate selection is
	# static and source-revision keyed, so retain its completed result rather than
	# revalidating every pose before every search slice.
	if request_identity != "":
		job["completed"] = true
		job["result"] = result.duplicate(true)
		candidate_jobs[candidate_key] = job
	else:
		_clear_candidate_job(actor_key, candidate_key)
	return result


func _candidate_search_key(actor_key: String, request_identity: String, raw_cells: Array, semantic_kind: String, allow_outside: bool, moving_home: bool, snapshot_revision: String) -> String:
	var cells: Array[String] = []
	for value in raw_cells:
		if value is Vector2i:
			var cell: Vector2i = value
			cells.append("%d,%d" % [cell.x, cell.y])
	return "%s|%s|%s|%s|%s|%s|%s" % [actor_key, request_identity, semantic_kind, str(allow_outside), str(moving_home), snapshot_revision, ";".join(cells)]


func _clear_replaced_actor_candidate_job(actor_key: String, candidate_key: String) -> void:
	var previous_key := String(active_candidate_key_by_actor.get(actor_key, ""))
	if previous_key != "" and previous_key != candidate_key:
		candidate_jobs.erase(previous_key)
	active_candidate_key_by_actor[actor_key] = candidate_key


func _clear_candidate_job(actor_key: String, candidate_key: String) -> void:
	candidate_jobs.erase(candidate_key)
	if String(active_candidate_key_by_actor.get(actor_key, "")) == candidate_key:
		active_candidate_key_by_actor.erase(actor_key)

func evict_candidate_cache_for_request(request_identity: String) -> int:
	if request_identity == "":
		return 0
	var removed := 0
	for candidate_key_value in candidate_jobs.keys():
		var candidate_key := String(candidate_key_value)
		var job: Dictionary = candidate_jobs.get(candidate_key, {}) if candidate_jobs.get(candidate_key, {}) is Dictionary else {}
		if String(job.get("requestIdentity", "")) != request_identity:
			continue
		var actor_key := String(job.get("actorKey", ""))
		_clear_candidate_job(actor_key, candidate_key)
		removed += 1
	return removed

func evict_candidate_cache_for_actor(entry_or_actor_key) -> int:
	var actor_key := _search_actor_key(entry_or_actor_key) if entry_or_actor_key is Dictionary else String(entry_or_actor_key)
	if actor_key == "":
		return 0
	# Replacement is actor-unique, so ordinary lifecycle cleanup never needs to
	# scan every other actor's retained job.
	var candidate_key := String(active_candidate_key_by_actor.get(actor_key, ""))
	var removed := 0
	if candidate_key != "" and candidate_jobs.has(candidate_key):
		candidate_jobs.erase(candidate_key)
		removed = 1
	active_candidate_key_by_actor.erase(actor_key)
	return removed

func candidate_cache_census() -> Dictionary:
	var phase_counts := {}
	var partial_neighbor_jobs := 0
	var finalizing_jobs := 0
	var deferred_record_count := 0
	for job_value in search_jobs.values():
		if not (job_value is Dictionary):
			continue
		var job: Dictionary = job_value
		var phase := String(job.get("phase", "search"))
		phase_counts[phase] = int(phase_counts.get(phase, 0)) + 1
		if not (job.get("currentRecord", {}) as Dictionary).is_empty():
			partial_neighbor_jobs += 1
		if phase == "finalize":
			finalizing_jobs += 1
		if job.get("deferredEdges", []) is Array:
			deferred_record_count += (job.get("deferredEdges", []) as Array).size()
	return {
		"jobCount": candidate_jobs.size(),
		"actorCount": active_candidate_key_by_actor.size(),
		"searchJobCount": search_jobs.size(),
		"searchActorCount": active_search_key_by_actor.size(),
		"searchPhaseCounts": phase_counts,
		"partialNeighborJobCount": partial_neighbor_jobs,
		"finalizingJobCount": finalizing_jobs,
		"deferredRecordCount": deferred_record_count
	}

func evict_search_cache_for_request(request_identity: String) -> int:
	if request_identity == "":
		return 0
	var removed := 0
	for search_key_value in search_jobs.keys():
		var search_key := String(search_key_value)
		var job: Dictionary = search_jobs.get(search_key, {}) if search_jobs.get(search_key, {}) is Dictionary else {}
		if String(job.get("requestIdentity", "")) != request_identity:
			continue
		var actor_key := String(job.get("actorKey", ""))
		_clear_search_job(actor_key, search_key)
		removed += 1
	return removed

func evict_search_cache_for_actor(entry_or_actor_key) -> int:
	var actor_key := _search_actor_key(entry_or_actor_key) if entry_or_actor_key is Dictionary else String(entry_or_actor_key)
	if actor_key == "":
		return 0
	var search_key := String(active_search_key_by_actor.get(actor_key, ""))
	var removed := 0
	if search_key != "" and search_jobs.has(search_key):
		search_jobs.erase(search_key)
		removed = 1
	active_search_key_by_actor.erase(actor_key)
	return removed

func _clear_terminal_search_for_actor_request(actor_key: String, request_identity: String) -> void:
	if request_identity != "":
		evict_search_cache_for_request(request_identity)
	else:
		evict_search_cache_for_actor(actor_key)

func repair_route_after_probe(entry: Dictionary, start_cell: Vector2i, candidate_cells: Array, failed_route: Dictionary, probe_certificate: Dictionary, options := {}) -> Dictionary:
	var repair_options: Dictionary = options.duplicate(true) if options is Dictionary else {}
	var avoid_cells := _merge_avoid_cells(repair_options.get("avoidCells", []), _probe_avoid_cells(probe_certificate, repair_options))
	repair_options["avoidCells"] = avoid_cells
	var repaired := plan_route(entry, start_cell, candidate_cells, repair_options)
	repaired["probeRepair"] = {
		"ok": bool(repaired.get("ok", false)),
		"reason": String(probe_certificate.get("reason", "blocked_probe")),
		"sourceRouteReason": String(failed_route.get("reason", "")),
		"attempt": int(repair_options.get("probeRepairAttempt", 1)),
		"avoidCells": avoid_cells.duplicate(),
		"candidateCount": candidate_cells.size()
	}
	if bool(repaired.get("ok", false)):
		repaired["reason"] = "probe_collision_repair"
	else:
		repaired["reason"] = String(repaired.get("reason", "probe_repair_no_route"))
	return repaired


func validate_goal_cell(entry: Dictionary, snapshot: Dictionary, cell: Vector2i, allow_outside := false, moving_home := false, ignore_dynamic := false) -> Dictionary:
	var result := validate_route_cell(entry, snapshot, cell, { cell: true, "_strictTargetCollision": true }, allow_outside, moving_home, ignore_dynamic, false)
	if not bool(result.get("ok", false)):
		result["goal"] = true
		return result
	result["goal"] = true
	return result


func validate_semantic_goal_cell(entry: Dictionary, cell: Vector2i, semantic_kind: String, snapshot := {}) -> Dictionary:
	if _semantic_goal_rejects_door_cell(snapshot, cell, semantic_kind):
		return _semantic_invalid(cell, semantic_kind, "semantic_goal_on_door_cell")
	if semantic_kind in ["home_exterior", "home_departure_clearance", "work_area", "forage_search_anchor", "forage_target", "guard_post"] and _own_home_interior_cell(entry, cell):
		return {
			"ok": false,
			"classification": CLASS_INVALID_GOAL,
			"reason": "semantic_goal_inside_own_home_interior",
			"cell": cell,
			"semanticKind": semantic_kind,
			"goal": true,
			"collisionBacked": true,
			"generatedWorldInformed": true
		}
	if semantic_kind == "forage_search_anchor":
		var area_validation := _validate_forage_search_anchor(entry, cell)
		if not bool(area_validation.get("ok", false)):
			return area_validation
	return {
		"ok": true,
		"classification": CLASS_REACHABLE,
		"reason": "",
		"cell": cell,
		"semanticKind": semantic_kind,
		"goal": true,
		"collisionBacked": true,
		"generatedWorldInformed": true
	}


func _semantic_goal_rejects_door_cell(snapshot, cell: Vector2i, semantic_kind: String) -> bool:
	if semantic_kind == "":
		return false
	if not (snapshot is Dictionary):
		return false
	return _door_at(snapshot, cell) != null


func _validate_forage_search_anchor(entry: Dictionary, cell: Vector2i) -> Dictionary:
	if not _adapter_has("cell_position") or not _adapter_has("point_inside_town") or not _adapter_has("point_inside_work_area"):
		return _semantic_invalid(cell, "forage_search_anchor", "missing_forage_area_validator")
	var position: Vector3 = world_adapter.call("cell_position", cell)
	if bool(world_adapter.call("point_inside_town", entry, position)):
		return _semantic_invalid(cell, "forage_search_anchor", "forage_search_anchor_inside_town")
	if not bool(world_adapter.call("point_inside_work_area", entry, position)):
		return _semantic_invalid(cell, "forage_search_anchor", "forage_search_anchor_outside_work_area")
	return { "ok": true }


func _semantic_invalid(cell: Vector2i, semantic_kind: String, reason: String) -> Dictionary:
	return {
		"ok": false,
		"classification": CLASS_INVALID_GOAL,
		"reason": reason,
		"cell": cell,
		"semanticKind": semantic_kind,
		"goal": true,
		"collisionBacked": true,
		"generatedWorldInformed": true
	}


func validate_route_cell(entry: Dictionary, snapshot: Dictionary, cell: Vector2i, target_lookup: Dictionary, allow_outside := false, moving_home := false, ignore_dynamic := false, allow_start := false) -> Dictionary:
	var base := {
		"ok": true,
		"classification": CLASS_REACHABLE,
		"reason": "",
		"cell": cell,
		"allowStart": allow_start,
		"collisionBacked": true,
		"generatedWorldInformed": true,
		"staticBlockerChecked": _adapter_has("static_blocker"),
		"staticCollisionChecked": _adapter_has("static_collision_blocker"),
		"dynamicBlockerChecked": not ignore_dynamic
	}
	var door = _door_at(snapshot, cell)
	if door != null:
		base["door"] = _door_summary(door)
	if ignore_dynamic and _adapter_has("cell_is_static_standable_goal_in_snapshot"):
		var static_standable = world_adapter.call("cell_is_static_standable_goal_in_snapshot", entry, snapshot, cell, allow_outside, moving_home)
		if not bool(static_standable) and not allow_start and door == null:
			base["ok"] = false
			base["classification"] = CLASS_INVALID_GOAL if target_lookup.has(cell) else CLASS_UNREACHABLE_STATIC
			base["reason"] = "cell_not_standable"
			return base
	elif ignore_dynamic and _adapter_has("cell_is_static_standable_goal"):
		var legacy_static_standable = world_adapter.call("cell_is_static_standable_goal", entry, cell, allow_outside, moving_home)
		if not bool(legacy_static_standable) and not allow_start and door == null:
			base["ok"] = false
			base["classification"] = CLASS_INVALID_GOAL if target_lookup.has(cell) else CLASS_UNREACHABLE_STATIC
			base["reason"] = "cell_not_standable"
			return base
	elif _adapter_has("cell_is_standable_goal_in_snapshot"):
		var standable = world_adapter.call("cell_is_standable_goal_in_snapshot", entry, snapshot, cell, allow_outside, moving_home)
		if not bool(standable) and not allow_start and door == null:
			base["ok"] = false
			base["classification"] = CLASS_INVALID_GOAL if target_lookup.has(cell) else CLASS_UNREACHABLE_STATIC
			base["reason"] = "cell_not_standable"
			return base
	elif _adapter_has("cell_is_standable_goal"):
		var standable = world_adapter.call("cell_is_standable_goal", entry, cell, allow_outside, moving_home)
		if not bool(standable) and not allow_start and door == null:
			base["ok"] = false
			base["classification"] = CLASS_INVALID_GOAL if target_lookup.has(cell) else CLASS_UNREACHABLE_STATIC
			base["reason"] = "cell_not_standable"
			return base
	if _adapter_has("static_blocker"):
		var blocker = world_adapter.call("static_blocker", snapshot, cell)
		if blocker != null:
			base["ok"] = false
			base["classification"] = CLASS_UNREACHABLE_STATIC
			base["reason"] = "blocked_static"
			base["blocker"] = _blocker_summary(blocker)
			return base
	if door == null and _adapter_has("static_collision_blocker"):
		var collision = world_adapter.call("static_collision_blocker", snapshot, cell)
		if collision is Dictionary and not (collision as Dictionary).is_empty():
			base["ok"] = false
			base["classification"] = CLASS_UNREACHABLE_STATIC
			base["reason"] = "blocked_static_collision"
			base["collision"] = collision
			return base
	if not ignore_dynamic:
		var dynamic = _dynamic_blocker(snapshot, cell)
		if dynamic != null and not target_lookup.has(cell):
			if allow_start:
				base["startDynamicBlocker"] = _blocker_summary(dynamic)
				return base
			base["ok"] = false
			base["classification"] = CLASS_BLOCKED_DYNAMIC
			base["reason"] = "blocked_dynamic"
			base["blocker"] = _blocker_summary(dynamic)
			return base
	return base


func _own_home_interior_cell(entry: Dictionary, cell: Vector2i) -> bool:
	var min_value = entry.get("interiorMinCell", entry.get("homeInteriorMinCell", INVALID_CELL))
	var max_value = entry.get("interiorMaxCell", entry.get("homeInteriorMaxCell", INVALID_CELL))
	if not (min_value is Vector2i) or not (max_value is Vector2i):
		var home_cell = entry.get("homeCell", INVALID_CELL)
		if home_cell is Vector2i:
			min_value = home_cell
			max_value = home_cell
	if not (min_value is Vector2i) or not (max_value is Vector2i):
		return false
	var min_cell: Vector2i = min_value
	var max_cell: Vector2i = max_value
	if min_cell == INVALID_CELL or max_cell == INVALID_CELL:
		return false
	if cell.x < mini(min_cell.x, max_cell.x) or cell.x > maxi(min_cell.x, max_cell.x):
		return false
	if cell.y < mini(min_cell.y, max_cell.y) or cell.y > maxi(min_cell.y, max_cell.y):
		return false
	var door_cell = entry.get("doorCell", INVALID_CELL)
	if door_cell is Vector2i and cell == door_cell:
		return false
	var porch_cell = entry.get("porchCell", INVALID_CELL)
	if porch_cell is Vector2i and cell == porch_cell:
		return false
	return true


func validate_transition(entry: Dictionary, snapshot: Dictionary, from_cell: Vector2i, to_cell: Vector2i, target_lookup: Dictionary, ignore_dynamic := false) -> Dictionary:
	var result := {
		"ok": true,
		"classification": CLASS_REACHABLE,
		"reason": "",
		"fromCell": from_cell,
		"toCell": to_cell,
		"collisionBacked": true,
		"generatedWorldInformed": true,
		"transitionCollisionChecked": _adapter_has("cell_transition_pathable")
	}
	var from_door = _door_at(snapshot, from_cell)
	var to_door = _door_at(snapshot, to_cell)
	if from_door != null or to_door != null:
		result["doorEdge"] = true
		var route_door = to_door if to_door != null else from_door
		result["door"] = _door_summary(route_door)
		var door_state_block := _door_route_state_block(route_door)
		if not door_state_block.is_empty():
			result["ok"] = false
			result["classification"] = CLASS_BLOCKED_DYNAMIC
			result["reason"] = String(door_state_block.get("reason", "door_state_blocked"))
			result["doorStateBlock"] = door_state_block
			return result
	var home_wall_block := _home_wall_transition_block(entry, from_cell, to_cell)
	if not home_wall_block.is_empty():
		return home_wall_block
	if _adapter_has("cell_transition_pathable"):
		var transition = world_adapter.call("cell_transition_pathable", entry, snapshot, from_cell, to_cell, target_lookup, ignore_dynamic)
		if transition is Dictionary and not bool((transition as Dictionary).get("ok", false)):
			var transition_reason := String((transition as Dictionary).get("reason", "transition_blocked"))
			if (from_door != null or to_door != null) and _door_transition_can_override_pathable_failure(transition_reason):
				result["doorPathableOverride"] = transition
				return result
			result["ok"] = false
			result["classification"] = _classification_for_block_reason(String((transition as Dictionary).get("reason", "")))
			result["reason"] = transition_reason
			result["transition"] = transition
			return result
	return result


func _door_route_state_block(door) -> Dictionary:
	var locked := false
	var jammed := false
	var destroyed := false
	var unloaded := false
	var door_state := ""
	if door is Object:
		var object := door as Object
		if object.has_method("get_meta"):
			locked = bool(object.call("get_meta", "locked", false))
			jammed = bool(object.call("get_meta", "jammed", false))
			destroyed = bool(object.call("get_meta", "destroyed", false))
			unloaded = bool(object.call("get_meta", "unloaded", false))
			door_state = String(object.call("get_meta", "door_state", ""))
	elif door is Dictionary:
		var value: Dictionary = door
		locked = bool(value.get("locked", false))
		jammed = bool(value.get("jammed", false))
		destroyed = bool(value.get("destroyed", false))
		unloaded = bool(value.get("unloaded", false))
		door_state = String(value.get("doorState", value.get("door_state", value.get("state", ""))))
	var normalized := door_state.to_lower()
	if locked or normalized == "locked":
		return { "reason": "door_locked", "state": door_state }
	if jammed or normalized == "jammed":
		return { "reason": "door_jammed", "state": door_state }
	if destroyed or normalized == "destroyed":
		return { "reason": "door_destroyed", "state": door_state }
	if unloaded or normalized == "unloaded":
		return { "reason": "door_unloaded", "state": door_state }
	return {}


func _door_transition_can_override_pathable_failure(reason: String) -> bool:
	return reason in ["no_walkable_surface", "cell_not_standable", "blocked_static", "blocked_static_collision", "door_transition_blocked"]


func _home_wall_transition_block(entry: Dictionary, from_cell: Vector2i, to_cell: Vector2i) -> Dictionary:
	var door_cell = entry.get("doorCell", INVALID_CELL)
	if not (door_cell is Vector2i) or door_cell == INVALID_CELL:
		return {}
	var from_inside := _own_home_interior_cell(entry, from_cell)
	var to_inside := _own_home_interior_cell(entry, to_cell)
	if from_inside == to_inside:
		return {}
	if from_cell == door_cell or to_cell == door_cell:
		return {}
	return {
		"ok": false,
		"classification": CLASS_UNREACHABLE_STATIC,
		"reason": "home_wall_transition_without_door",
		"fromCell": from_cell,
		"toCell": to_cell,
		"doorCell": door_cell if door_cell is Vector2i else INVALID_CELL,
		"collisionBacked": true,
		"generatedWorldInformed": true,
		"semanticDoorEdgeRequired": true
	}


func _build_snapshot(entry: Dictionary, allow_outside: bool, moving_home: bool) -> Dictionary:
	if _adapter_has("build_snapshot"):
		var snapshot_value = world_adapter.call("build_snapshot", entry, allow_outside, moving_home)
		if snapshot_value is Dictionary:
			var snapshot: Dictionary = snapshot_value
			if bool(snapshot.get("pendingNavData", false)) or String(snapshot.get("status", "")) == CLASS_PENDING_NAV_DATA:
				return { "ok": false, "classification": CLASS_PENDING_NAV_DATA, "reason": String(snapshot.get("reason", "pending_nav_data")), "snapshot": snapshot }
			return { "ok": true, "snapshot": snapshot }
	if _adapter_has("cached_validation_snapshot"):
		var cached_value = world_adapter.call("cached_validation_snapshot", entry, allow_outside, moving_home)
		if cached_value is Dictionary:
			return { "ok": true, "snapshot": cached_value }
	return { "ok": false, "classification": CLASS_PENDING_NAV_DATA, "reason": "no_snapshot_api" }


func _target_candidate_cells(entry: Dictionary, target: Dictionary, semantic_kind: String, allow_outside: bool) -> Array:
	var result: Array = []
	if semantic_kind == "home_interior":
		_append_rect_cells(result, target.get("interiorMinCell", entry.get("homeInteriorMinCell", INVALID_CELL)), target.get("interiorMaxCell", entry.get("homeInteriorMaxCell", INVALID_CELL)))
	elif semantic_kind == "home_departure_clearance":
		_append_cell(result, target.get("cell", INVALID_CELL))
	elif semantic_kind == "home_exterior":
		_append_cell(result, target.get("cell", INVALID_CELL))
		_append_cell(result, target.get("porchCell", entry.get("porchCell", INVALID_CELL)))
		_append_position_approaches(result, entry, target.get("position", entry.get("porchPosition", Vector3.ZERO)), allow_outside)
	elif semantic_kind == "work_area":
		_append_rect_cells(result, target.get("workMinCell", target.get("minCell", INVALID_CELL)), target.get("workMaxCell", target.get("maxCell", INVALID_CELL)))
		_append_cell(result, target.get("cell", INVALID_CELL))
		_append_position_approaches(result, entry, target.get("position", Vector3.ZERO), allow_outside)
	elif semantic_kind == "forage_search_anchor":
		_append_cell(result, target.get("cell", INVALID_CELL))
	elif semantic_kind == "forage_target":
		_append_cell(result, target.get("exactSlotCell", target.get("cell", INVALID_CELL)))
	elif semantic_kind == "interaction_target":
		# A caller may provide a semantic set of physically valid action poses
		# (for example, placement stands). They remain candidates only: this
		# substrate still performs the authoritative snapshot, route, and probe
		# validation before returning a route.
		for candidate_cell in target.get("candidateCells", []):
			_append_cell(result, candidate_cell)
		_append_cell(result, target.get("cell", INVALID_CELL))
		_append_position_approaches(result, entry, target.get("position", Vector3.ZERO), allow_outside)
	elif semantic_kind == "guard_post":
		_append_cell(result, target.get("guardCell", target.get("cell", entry.get("guardCell", INVALID_CELL))))
		_append_position_approaches(result, entry, target.get("guardPosition", entry.get("guardPosition", target.get("position", Vector3.ZERO))), allow_outside)
	else:
		_append_cell(result, target.get("cell", INVALID_CELL))
		_append_position_approaches(result, entry, target.get("position", Vector3.ZERO), allow_outside)
	return _normalize_cells(result)


func _append_position_approaches(result: Array, entry: Dictionary, position, allow_outside: bool) -> void:
	if not (position is Vector3):
		return
	if _adapter_has("world_cell"):
		_append_cell(result, world_adapter.call("world_cell", position))
	if _adapter_has("approach_candidate_cells_for_target"):
		for cell in world_adapter.call("approach_candidate_cells_for_target", entry, position, allow_outside):
			_append_cell(result, cell)
	elif _adapter_has("approach_cells_for_target"):
		for cell in world_adapter.call("approach_cells_for_target", entry, position, allow_outside):
			_append_cell(result, cell)


func _append_rect_cells(result: Array, min_value, max_value) -> void:
	if not (min_value is Vector2i) or not (max_value is Vector2i):
		return
	var min_cell: Vector2i = min_value
	var max_cell: Vector2i = max_value
	if min_cell == INVALID_CELL or max_cell == INVALID_CELL:
		return
	for z in range(mini(min_cell.y, max_cell.y), maxi(min_cell.y, max_cell.y) + 1):
		for x in range(mini(min_cell.x, max_cell.x), maxi(min_cell.x, max_cell.x) + 1):
			_append_cell(result, Vector2i(x, z))


func _append_cell(result: Array, value) -> void:
	if value is Vector2i and value != INVALID_CELL:
		result.append(value)


func _normalize_cells(values: Array) -> Array:
	var seen := {}
	var result: Array = []
	for value in values:
		if not (value is Vector2i):
			continue
		var cell: Vector2i = value
		if seen.has(cell):
			continue
		seen[cell] = true
		result.append(cell)
	return result

func _avoid_lookup_from_options(options: Dictionary) -> Dictionary:
	var result := {}
	for value in options.get("avoidCells", []):
		var cell := _cell_from_value(value)
		if cell != INVALID_CELL:
			result[cell] = true
	return result


func _route_avoid_blocks_cell(avoid_lookup: Dictionary, cell: Vector2i, start_cell: Vector2i, target_lookup: Dictionary) -> bool:
	if cell == start_cell or target_lookup.has(cell):
		return false
	return avoid_lookup.has(cell)


func _avoid_block_record(from_cell: Vector2i, to_cell: Vector2i) -> Dictionary:
	return {
		"ok": false,
		"classification": CLASS_UNREACHABLE_STATIC,
		"reason": "route_avoid_cell",
		"fromCell": from_cell,
		"toCell": to_cell,
		"blockerCell": to_cell,
		"collisionBacked": true,
		"generatedWorldInformed": true,
		"probeRepairAvoidance": true
	}


func _probe_avoid_cells(probe_certificate: Dictionary, options: Dictionary) -> Array:
	var details: Dictionary = probe_certificate.get("details", {}) if probe_certificate.get("details", {}) is Dictionary else {}
	var radius := maxi(0, int(options.get("probeRepairAvoidRadius", 0)))
	var result: Array = []
	var blocked_cell := _cell_from_value(details.get("cell", INVALID_CELL))
	if blocked_cell != INVALID_CELL:
		for z in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				_append_unique_cell(result, blocked_cell + Vector2i(x, z))
	var sample_cell := _cell_from_value(details.get("sample", INVALID_CELL))
	if sample_cell != INVALID_CELL:
		_append_unique_cell(result, sample_cell)
	return result


func _merge_avoid_cells(first, second) -> Array:
	var result: Array = []
	if first is Array:
		for value in first:
			_append_unique_cell(result, _cell_from_value(value))
	if second is Array:
		for value in second:
			_append_unique_cell(result, _cell_from_value(value))
	return result


func _append_unique_cell(result: Array, cell: Vector2i) -> void:
	if cell == INVALID_CELL or result.has(cell):
		return
	result.append(cell)


func _cell_from_value(value) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector3:
		var position: Vector3 = value
		if _adapter_has("world_cell"):
			var cell_value = world_adapter.call("world_cell", position)
			if cell_value is Vector2i:
				return cell_value
		return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))
	if value is Dictionary:
		var dict: Dictionary = value
		return Vector2i(int(dict.get("x", INVALID_CELL.x)), int(dict.get("z", dict.get("y", INVALID_CELL.y))))
	if value is Array and (value as Array).size() >= 2:
		var array_value: Array = value
		return Vector2i(int(array_value[0]), int(array_value[1]))
	return INVALID_CELL


func _neighbors(cell: Vector2i) -> Array[Vector2i]:
	return [
		cell + Vector2i(1, 0),
		cell + Vector2i(-1, 0),
		cell + Vector2i(0, 1),
		cell + Vector2i(0, -1)
	]


func _deferred_heap_push(heap: Array, value: Dictionary) -> void:
	heap.append(value)
	var index := heap.size() - 1
	while index > 0:
		var parent_index := (index - 1) / 2
		if not _deferred_heap_less(value, heap[parent_index]):
			break
		heap[index] = heap[parent_index]
		index = parent_index
	heap[index] = value


func _deferred_heap_pop(heap: Array) -> Dictionary:
	if heap.is_empty():
		return {}
	var result: Dictionary = heap[0]
	var tail = heap.pop_back()
	if heap.is_empty():
		return result
	var index := 0
	while true:
		var left := index * 2 + 1
		if left >= heap.size():
			break
		var right := left + 1
		var child := left
		if right < heap.size() and _deferred_heap_less(heap[right], heap[left]):
			child = right
		if not _deferred_heap_less(heap[child], tail):
			break
		heap[index] = heap[child]
		index = child
	heap[index] = tail
	return result


func _deferred_heap_less(a: Dictionary, b: Dictionary) -> bool:
	var a_bound := int(a.get("bound", 2147483000))
	var b_bound := int(b.get("bound", 2147483000))
	if a_bound != b_bound:
		return a_bound < b_bound
	return int(a.get("sequence", 0)) < int(b.get("sequence", 0))


func _cell_position(cell: Vector2i) -> Vector3:
	if _adapter_has("cell_position"):
		var position = world_adapter.call("cell_position", cell)
		if position is Vector3:
			return position
	return Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)


func _route_start_position(start_cell: Vector2i, options: Dictionary):
	var value = options.get("startPosition", null)
	if not (value is Vector3):
		return null
	var position: Vector3 = value
	if _adapter_has("world_cell"):
		var cell_value = world_adapter.call("world_cell", position)
		if cell_value is Vector2i and cell_value != start_cell:
			return null
	return position


func _cell_array(values: Array) -> Array:
	var result: Array = []
	for value in values:
		if value is Vector2i:
			result.append(value)
	return result


func _limited_cell_array(values: Array, limit: int) -> Array:
	var result: Array = []
	for value in values:
		if value is Vector2i:
			result.append(value)
			if result.size() >= limit:
				break
	return result


func _search_actor_key(entry: Dictionary) -> String:
	var actor_id := String(entry.get("id", entry.get("actorId", "")))
	if actor_id != "":
		return actor_id
	var body = entry.get("body")
	if body is Object and is_instance_valid(body):
		return "instance:%d" % (body as Object).get_instance_id()
	return "entry:%d" % entry.hash()


func _search_key(entry: Dictionary, request_identity: String, start_cell: Vector2i, candidate_cells: Array, _snapshot: Dictionary, allow_outside: bool, moving_home: bool, ignore_dynamic: bool, semantic_kind: String, avoid_cells: Array) -> String:
	var goal_keys: Array[String] = []
	for cell in candidate_cells:
		if cell is Vector2i:
			goal_keys.append("%d,%d" % [cell.x, cell.y])
	goal_keys.sort()
	var avoid_keys: Array[String] = []
	for cell in avoid_cells:
		if cell is Vector2i:
			avoid_keys.append("%d,%d" % [cell.x, cell.y])
	avoid_keys.sort()
	return "%s|%s|%d,%d|%s|%s|%s|%s|%s" % [
		_search_actor_key(entry),
		request_identity,
		start_cell.x,
		start_cell.y,
		semantic_kind,
		"1" if allow_outside else "0",
		"1" if moving_home else "0",
		"1" if ignore_dynamic else "0",
		"%s|%s" % [",".join(goal_keys), ",".join(avoid_keys)]
	]


func _observe_search_source_cell(observed_cells: Dictionary, observed_tiles: Dictionary, cell: Vector2i) -> void:
	if _adapter_has("route_source_revision_for_tiles") and _adapter_has("tile_key_for_cell"):
		for x_offset in range(-1, 2):
			for z_offset in range(-1, 2):
				observed_tiles[String(world_adapter.call("tile_key_for_cell", cell + Vector2i(x_offset, z_offset)))] = true
	else:
		observed_cells[cell] = true


func _search_snapshot_revision(snapshot: Dictionary, observed_cells: Array = [], observed_tiles: Array = []) -> String:
	if not observed_tiles.is_empty() and _adapter_has("route_source_revision_for_tiles"):
		return String(world_adapter.call("route_source_revision_for_tiles", observed_tiles))
	if not observed_cells.is_empty() and _adapter_has("route_source_revision_for_cells"):
		return String(world_adapter.call("route_source_revision_for_cells", observed_cells))
	if snapshot.has("staticSnapshotRevision"):
		# Door open/closed state does not change portal topology. Route execution
		# probes current collision and opens the portal before crossing.
		return "%s:%s:%s" % [
			str(snapshot.get("staticSnapshotRevision", 0)),
			str(snapshot.get("semanticRevision", 0)),
			str(snapshot.get("terrainRevision", 0))
		]
	return String(snapshot.get("revision", ""))


func _advance_finalization_identity(snapshot: Dictionary, job: Dictionary, step_budget: int) -> Dictionary:
	# Door state has a genuine adapter revision, so its route-local fingerprint can
	# be built incrementally and restarted when that revision changes. Live actor
	# occupancy has no source revision. Capture only the route-local occupancy, then
	# verify that capture in a second bounded pass before exposing one identity.
	# A move during either pass restarts this compiler instead of publishing a mixed
	# prefix. Collision probing remains the final live authority before commitment.
	var steps := 0
	var route: Array = job.get("pendingRoute", []) if job.get("pendingRoute", []) is Array else []
	var door_signature_start_usec := Time.get_ticks_usec()
	var door_cells_before := steps
	var doors_observed := 0
	var door_revision := str(snapshot.get("doorStateRevision", snapshot.get("revision", "")))
	if String(job.get("finalizationDoorScanRevision", "")) == "":
		job["finalizationDoorScanRevision"] = door_revision
		job["finalizationDoorScanIndex"] = 0
		job["finalizationDoorParts"] = []
		job["finalizationDoorCells"] = []
		job["finalizationDoorExpected"] = []
		job["finalizationDoorVerifyRevision"] = ""
		job["finalizationDoorVerifyIndex"] = 0
		_reset_finalization_dynamic_scan(job)
	var door_index := clampi(int(job.get("finalizationDoorScanIndex", 0)), 0, route.size())
	var door_parts: Array = job.get("finalizationDoorParts", []) if job.get("finalizationDoorParts", []) is Array else []
	var door_cells: Array = job.get("finalizationDoorCells", []) if job.get("finalizationDoorCells", []) is Array else []
	var door_expected: Array = job.get("finalizationDoorExpected", []) if job.get("finalizationDoorExpected", []) is Array else []
	while door_index < route.size() and steps < step_budget:
		var cell_value = route[door_index]
		if cell_value is Vector2i:
			var cell: Vector2i = cell_value
			var door = _door_at(snapshot, cell)
			if door != null:
				doors_observed += 1
				var captured_door_signature := _route_door_signature(door)
				door_parts.append("%d,%d=%s" % [cell.x, cell.y, captured_door_signature])
				door_cells.append(cell)
				door_expected.append(captured_door_signature)
		door_index += 1
		steps += 1
	job["finalizationDoorScanIndex"] = door_index
	job["finalizationDoorParts"] = door_parts
	job["finalizationDoorCells"] = door_cells
	job["finalizationDoorExpected"] = door_expected
	_accumulate_plan_timing("doorSignatureUsec", Time.get_ticks_usec() - door_signature_start_usec)
	_active_plan_timing_profile["doorSignatureCells"] = int(_active_plan_timing_profile.get("doorSignatureCells", 0)) + maxi(0, steps - door_cells_before)
	_active_plan_timing_profile["doorSignatureDoors"] = int(_active_plan_timing_profile.get("doorSignatureDoors", 0)) + doors_observed
	if door_index < route.size():
		return { "complete": false, "steps": steps }
	# Door-state revisions are global, while this certificate is route-local.
	# Revisions that occurred during a long route scan therefore verify only the
	# captured route doors. A route with no doors accepts an unrelated revision
	# immediately; it never restarts a 30k/long-route scan because some other
	# town door opened.
	if door_revision != String(job.get("finalizationDoorScanRevision", "")):
		if door_cells.is_empty():
			job["finalizationDoorScanRevision"] = door_revision
		else:
			var verify_revision := String(job.get("finalizationDoorVerifyRevision", ""))
			if verify_revision == "":
				verify_revision = door_revision
				job["finalizationDoorVerifyRevision"] = verify_revision
				job["finalizationDoorVerifyIndex"] = 0
			var verify_index := clampi(int(job.get("finalizationDoorVerifyIndex", 0)), 0, door_cells.size())
			while verify_index < door_cells.size() and steps < step_budget:
				var verify_cell: Vector2i = door_cells[verify_index]
				var verify_door = _door_at(snapshot, verify_cell)
				var actual_signature := _route_door_signature(verify_door) if verify_door != null else ""
				if verify_index >= door_expected.size() or actual_signature != String(door_expected[verify_index]):
					_reset_finalization_identity_scan(job)
					return { "complete": false, "steps": steps + 1, "restarted": true }
				verify_index += 1
				steps += 1
			job["finalizationDoorVerifyIndex"] = verify_index
			if verify_index < door_cells.size():
				return { "complete": false, "steps": steps }
			if door_revision != verify_revision:
				job["finalizationDoorVerifyRevision"] = door_revision
				job["finalizationDoorVerifyIndex"] = 0
				return { "complete": false, "steps": steps }
			job["finalizationDoorScanRevision"] = door_revision
			job["finalizationDoorVerifyRevision"] = ""
			job["finalizationDoorVerifyIndex"] = 0
	var dynamic_signature_start_usec := Time.get_ticks_usec()
	var dynamic: Dictionary = snapshot.get("dynamic", {}) if snapshot.get("dynamic", {}) is Dictionary else {}
	var dynamic_phase := String(job.get("finalizationDynamicPhase", "capture"))
	var dynamic_index := clampi(int(job.get("finalizationDynamicIndex", 0)), 0, route.size())
	var occupied_route_cells: Array = job.get("finalizationDynamicOccupied", []) if job.get("finalizationDynamicOccupied", []) is Array else []
	var expected_occupancy: Array = job.get("finalizationDynamicExpected", []) if job.get("finalizationDynamicExpected", []) is Array else []
	var dynamic_steps_before := steps
	while dynamic_index < route.size() and steps < step_budget:
		var cell_value = route[dynamic_index]
		var occupied := cell_value is Vector2i and dynamic.has(cell_value)
		if dynamic_phase == "capture":
			expected_occupancy.append(occupied)
			if occupied:
				var occupied_cell: Vector2i = cell_value
				occupied_route_cells.append("%d,%d" % [occupied_cell.x, occupied_cell.y])
		elif dynamic_index >= expected_occupancy.size() or bool(expected_occupancy[dynamic_index]) != occupied:
			_reset_finalization_dynamic_scan(job)
			_accumulate_plan_timing("dynamicSignatureUsec", Time.get_ticks_usec() - dynamic_signature_start_usec)
			_active_plan_timing_profile["dynamicSignatureCells"] = int(_active_plan_timing_profile.get("dynamicSignatureCells", 0)) + 1
			return { "complete": false, "steps": steps + 1, "restarted": true }
		dynamic_index += 1
		steps += 1
	job["finalizationDynamicIndex"] = dynamic_index
	job["finalizationDynamicOccupied"] = occupied_route_cells
	job["finalizationDynamicExpected"] = expected_occupancy
	if dynamic_index < route.size():
		_accumulate_plan_timing("dynamicSignatureUsec", Time.get_ticks_usec() - dynamic_signature_start_usec)
		_active_plan_timing_profile["dynamicSignatureCells"] = int(_active_plan_timing_profile.get("dynamicSignatureCells", 0)) + maxi(0, steps - dynamic_steps_before)
		return { "complete": false, "steps": steps }
	if dynamic_phase == "capture":
		job["finalizationDynamicPhase"] = "verify"
		job["finalizationDynamicIndex"] = 0
		dynamic_phase = "verify"
		dynamic_index = 0
		# Phase boundaries are not work. If this call still owns cheap-step
		# budget, begin the verification pass immediately so short routes retain
		# the synchronous wrapper behaviour while long routes remain cursorized.
		while dynamic_index < route.size() and steps < step_budget:
			var verify_cell_value = route[dynamic_index]
			var currently_occupied := verify_cell_value is Vector2i and dynamic.has(verify_cell_value)
			if dynamic_index >= expected_occupancy.size() or bool(expected_occupancy[dynamic_index]) != currently_occupied:
				_reset_finalization_dynamic_scan(job)
				_accumulate_plan_timing("dynamicSignatureUsec", Time.get_ticks_usec() - dynamic_signature_start_usec)
				_active_plan_timing_profile["dynamicSignatureCells"] = int(_active_plan_timing_profile.get("dynamicSignatureCells", 0)) + maxi(0, steps - dynamic_steps_before) + 1
				return { "complete": false, "steps": steps + 1, "restarted": true }
			dynamic_index += 1
			steps += 1
		job["finalizationDynamicIndex"] = dynamic_index
		if dynamic_index < route.size():
			_accumulate_plan_timing("dynamicSignatureUsec", Time.get_ticks_usec() - dynamic_signature_start_usec)
			_active_plan_timing_profile["dynamicSignatureCells"] = int(_active_plan_timing_profile.get("dynamicSignatureCells", 0)) + maxi(0, steps - dynamic_steps_before)
			return { "complete": false, "steps": steps }
	var signature := "doors:%s|dynamic:%s" % [";".join(door_parts), ",".join(occupied_route_cells)]
	_accumulate_plan_timing("dynamicSignatureUsec", Time.get_ticks_usec() - dynamic_signature_start_usec)
	_active_plan_timing_profile["dynamicSignatureCells"] = int(_active_plan_timing_profile.get("dynamicSignatureCells", 0)) + route.size()
	_active_plan_timing_profile["dynamicSignatureOccupied"] = int(_active_plan_timing_profile.get("dynamicSignatureOccupied", 0)) + occupied_route_cells.size()
	return {
		"complete": true,
		"steps": steps,
		"signature": signature
	}


func _reset_finalization_dynamic_scan(job: Dictionary) -> void:
	job["finalizationDynamicPhase"] = "capture"
	job["finalizationDynamicIndex"] = 0
	job["finalizationDynamicOccupied"] = []
	job["finalizationDynamicExpected"] = []


func _reset_finalization_identity_scan(job: Dictionary) -> void:
	job["finalizationDoorScanRevision"] = ""
	job["finalizationDoorScanIndex"] = 0
	job["finalizationDoorParts"] = []
	job["finalizationDoorCells"] = []
	job["finalizationDoorExpected"] = []
	job["finalizationDoorVerifyRevision"] = ""
	job["finalizationDoorVerifyIndex"] = 0
	_reset_finalization_dynamic_scan(job)


func _reset_finalization_identity(job: Dictionary, clear_observed: bool) -> void:
	job["finalizationSnapshotRevision"] = ""
	if clear_observed:
		job["lastObservedFinalizationSnapshotRevision"] = ""
	_reset_finalization_identity_scan(job)


func _route_door_signature(door) -> String:
	if door is Object:
		var object := door as Object
		var instance_id := object.get_instance_id()
		var portal_id := ""
		var door_state := ""
		var facts: Array[String] = []
		if object.has_method("get_meta"):
			portal_id = String(object.call("get_meta", "door_portal_id", object.call("get_meta", "portal_id", object.call("get_meta", "door_group_id", ""))))
			door_state = String(object.call("get_meta", "door_state", ""))
			for fact_name in ["open", "locked", "jammed", "destroyed", "unloaded", "door_policy", "door_side", "closed_rotation", "cell", "home_id", "homeId", "owner_actor_id", "ownerActorId"]:
				facts.append("%s=%s" % [fact_name, str(object.call("get_meta", fact_name, ""))])
		if object is Node3D:
			var node := object as Node3D
			facts.append("position=%s" % str(node.position))
			facts.append("rotationY=%s" % str(node.rotation.y))
		return "%d:%s:%s:%s" % [instance_id, portal_id, door_state, ",".join(facts)]
	if door is Dictionary:
		var dictionary: Dictionary = door
		return "%s:%s:%s:%s:%s:%s:%s:%s:%s:%s" % [
			String(dictionary.get("portalId", dictionary.get("portal_id", dictionary.get("doorId", "")))),
			String(dictionary.get("doorState", dictionary.get("door_state", dictionary.get("state", "")))),
			"1" if bool(dictionary.get("open", false)) else "0",
			"1" if bool(dictionary.get("locked", false)) else "0",
			"1" if bool(dictionary.get("jammed", false)) else "0",
			"1" if bool(dictionary.get("destroyed", false)) else "0",
			"1" if bool(dictionary.get("unloaded", false)) else "0",
			String(dictionary.get("doorPolicy", dictionary.get("door_policy", ""))),
			str(dictionary.get("doorSide", dictionary.get("door_side", ""))),
			str(dictionary.get("cell", ""))
		]
	return str(door)


func _clear_replaced_actor_search(actor_key: String, search_key: String) -> void:
	var previous := String(active_search_key_by_actor.get(actor_key, ""))
	if previous != "" and previous != search_key:
		search_jobs.erase(previous)
	active_search_key_by_actor[actor_key] = search_key


func _clear_search_job(actor_key: String, search_key: String) -> void:
	search_jobs.erase(search_key)
	if String(active_search_key_by_actor.get(actor_key, "")) == search_key:
		active_search_key_by_actor.erase(actor_key)


func _update_search_job(job: Dictionary, open: Array, closed: Dictionary, g_score: Dictionary, parent: Dictionary, cell_proofs: Dictionary, blocked_records: Array, door_edges: Array, expansions: int, sequence: int) -> void:
	job["open"] = open
	job["closed"] = closed
	job["gScore"] = g_score
	job["parent"] = parent
	job["cellProofs"] = cell_proofs
	job["blockedRecords"] = blocked_records
	job["doorEdges"] = door_edges
	job["expansions"] = expansions
	job["sequence"] = sequence


func _goal_heuristic(cell: Vector2i, accepted_goals: Dictionary) -> int:
	var best := 2147483000
	for goal in accepted_goals.keys():
		if goal is Vector2i:
			best = mini(best, absi(cell.x - goal.x) + absi(cell.y - goal.y))
	return 0 if best == 2147483000 else best


func _open_heap_push(heap: Array, value: Dictionary) -> void:
	heap.append(value)
	var index := heap.size() - 1
	while index > 0:
		var parent_index := (index - 1) / 2
		if not _open_heap_less(value, heap[parent_index]):
			break
		heap[index] = heap[parent_index]
		index = parent_index
	heap[index] = value


func _open_heap_pop(heap: Array) -> Dictionary:
	if heap.is_empty():
		return {}
	var result: Dictionary = heap[0]
	var tail = heap.pop_back()
	if heap.is_empty():
		return result
	var index := 0
	while true:
		var left := index * 2 + 1
		if left >= heap.size():
			break
		var right := left + 1
		var child := left
		if right < heap.size() and _open_heap_less(heap[right], heap[left]):
			child = right
		if not _open_heap_less(heap[child], tail):
			break
		heap[index] = heap[child]
		index = child
	heap[index] = tail
	return result


func _open_heap_less(a: Dictionary, b: Dictionary) -> bool:
	var a_f := int(a.get("f", 2147483000))
	var b_f := int(b.get("f", 2147483000))
	if a_f != b_f:
		return a_f < b_f
	return int(a.get("sequence", 0)) < int(b.get("sequence", 0))


func _append_bounded(values: Array, value, limit: int) -> void:
	if values.size() < limit:
		values.append(value)


func _door_at(snapshot: Dictionary, cell: Vector2i):
	if _adapter_has("door_at"):
		return world_adapter.call("door_at", snapshot, cell)
	var doors: Dictionary = snapshot.get("doors", {})
	return doors.get(cell, null)


func _dynamic_blocker(snapshot: Dictionary, cell: Vector2i):
	if _adapter_has("dynamic_blocker"):
		return world_adapter.call("dynamic_blocker", snapshot, cell)
	var dynamic: Dictionary = snapshot.get("dynamic", {})
	return dynamic.get(cell, null)


func _classification_for_block_reason(reason: String) -> String:
	if reason == "blocked_dynamic":
		return CLASS_BLOCKED_DYNAMIC
	if reason == "pending_nav_data":
		return CLASS_PENDING_NAV_DATA
	if reason == "pending_budget":
		return CLASS_PENDING_BUDGET
	if reason == "cell_not_standable" or reason == "goal_not_standable" or reason == "outside_area" or reason == "private_interior_not_routeable":
		return CLASS_INVALID_GOAL
	return CLASS_UNREACHABLE_STATIC


func _blocker_summary(blocker) -> Dictionary:
	if blocker == null:
		return {}
	if blocker is Dictionary:
		return blocker
	if blocker is Object:
		var object := blocker as Object
		var summary := { "type": object.get_class() }
		if object.has_method("get_meta"):
			summary["blockType"] = object.call("get_meta", "block_type", "")
			summary["name"] = object.get("name") if object is Node else ""
		return summary
	return { "type": typeof(blocker), "value": str(blocker) }


func _door_summary(door) -> Dictionary:
	if door == null:
		return {}
	if door is Dictionary:
		return door
	if door is Object:
		var object := door as Object
		var summary := { "type": object.get_class() }
		if object.has_method("get_meta"):
			summary["portalId"] = object.call("get_meta", "door_portal_id", object.call("get_meta", "portal_id", object.call("get_meta", "door_group_id", "")))
			summary["portal_id"] = summary["portalId"]
			summary["groupId"] = object.call("get_meta", "door_group_id", "")
			summary["doorId"] = object.call("get_meta", "door_id", "")
		if object is Node:
			summary["name"] = (object as Node).name
		return summary
	return { "type": typeof(door), "value": str(door) }


func _door_portal_id(door, cell: Vector2i) -> String:
	if door is Node:
		var node := door as Node
		if node.has_meta("door_portal_id"):
			return String(node.get_meta("door_portal_id"))
		if node.has_meta("portal_id"):
			return String(node.get_meta("portal_id"))
		if node.has_meta("door_group_id"):
			return String(node.get_meta("door_group_id"))
	return "door:%d,0,%d" % [cell.x, cell.y]


func _direction_for_step(from_cell: Vector2i, to_cell: Vector2i) -> String:
	var delta := to_cell - from_cell
	if abs(delta.x) >= abs(delta.y) and delta.x != 0:
		return "x+" if delta.x > 0 else "x-"
	if delta.y != 0:
		return "z+" if delta.y > 0 else "z-"
	return ""


func _adapter_has(method_name: String) -> bool:
	return world_adapter != null and world_adapter.has_method(method_name)


func _result(ok: bool, classification: String, reason: String, route_cells: Array, visited_cells: Array, proof: Dictionary, actions := {}, start_position = null) -> Dictionary:
	var waypoints: Array = []
	for index in range(route_cells.size()):
		var cell = route_cells[index]
		if cell is Vector2i:
			if index == 0 and start_position is Vector3:
				waypoints.append(start_position)
			else:
				waypoints.append(_cell_position(cell))
	var target_cell := INVALID_CELL
	if not route_cells.is_empty() and route_cells[route_cells.size() - 1] is Vector2i:
		target_cell = route_cells[route_cells.size() - 1]
	return {
		"ok": ok,
		"status": classification,
		"classification": classification,
		"reason": reason,
		"source": "collision_backed_route_substrate",
		"route": route_cells,
		"cells": route_cells,
		"waypoints": waypoints,
		"actions": actions.duplicate(true) if actions is Dictionary else {},
		"targetCell": target_cell,
		"fallbackCell": target_cell,
		"snapshotRevision": String(proof.get("snapshotRevision", "")),
		"visited": visited_cells,
		"proof": proof
	}


func _result_with_waypoints(ok: bool, classification: String, reason: String, route_cells: Array, visited_cells: Array, proof: Dictionary, actions: Dictionary, waypoints: Array) -> Dictionary:
	var target_cell := INVALID_CELL
	if not route_cells.is_empty() and route_cells[route_cells.size() - 1] is Vector2i:
		target_cell = route_cells[route_cells.size() - 1]
	return {
		"ok": ok,
		"status": classification,
		"classification": classification,
		"reason": reason,
		"source": "collision_backed_route_substrate",
		"route": route_cells,
		"cells": route_cells,
		"waypoints": waypoints,
		"actions": actions,
		"targetCell": target_cell,
		"fallbackCell": target_cell,
		"snapshotRevision": String(proof.get("snapshotRevision", "")),
		"visited": visited_cells,
		"proof": proof
	}

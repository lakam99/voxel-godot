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
const DEFAULT_CANDIDATE_VALIDATIONS_PER_CALL := 128
const MAX_RECORDED_BLOCKS := 128
const MAX_RECORDED_VISITED := 256

var world_adapter = null
var search_jobs := {}
var active_search_key_by_actor := {}
var candidate_jobs := {}
var active_candidate_key_by_actor := {}


func setup(adapter) -> void:
	world_adapter = adapter


func plan_route(entry: Dictionary, start_cell: Vector2i, candidate_cells: Array, options := {}) -> Dictionary:
	if world_adapter == null:
		return _result(false, CLASS_PENDING_NAV_DATA, "missing_world_adapter", [], [], {
			"collisionBacked": true,
			"generatedWorldInformed": true
		})
	var allow_outside := bool(options.get("allowOutside", false))
	var moving_home := bool(options.get("movingHome", false))
	var ignore_dynamic := bool(options.get("ignoreDynamic", false))
	var max_expansions := maxi(1, int(options.get("maxExpansions", 4096)))
	var semantic_kind := String(options.get("semanticKind", ""))
	var avoid_lookup := _avoid_lookup_from_options(options)
	var avoid_cells := _cell_array(avoid_lookup.keys())
	var start_position = _route_start_position(start_cell, options)
	var snapshot_result := _build_snapshot(entry, allow_outside, moving_home)
	if not bool(snapshot_result.get("ok", false)):
		var pending_class := String(snapshot_result.get("classification", CLASS_PENDING_NAV_DATA))
		return _result(false, pending_class, String(snapshot_result.get("reason", "snapshot_not_ready")), [], [], {
			"collisionBacked": true,
			"generatedWorldInformed": true,
			"snapshot": snapshot_result
		})
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
		return _result(false, CLASS_UNREACHABLE_STATIC, "all_candidate_cells_avoided_by_probe", [], [], {
			"collisionBacked": true,
			"generatedWorldInformed": true,
			"rejectedGoals": [],
			"avoidCells": avoid_cells,
			"avoidedGoalCells": avoided_goal_cells
		})
	var target_lookup := { "_strictTargetCollision": true }
	var accepted_goals := {}
	var rejected_goals: Array = []
	for cell in candidates:
		var validation := validate_goal_cell(entry, snapshot, cell, allow_outside, moving_home, ignore_dynamic)
		if bool(validation.get("ok", false)):
			validation = validate_semantic_goal_cell(entry, cell, semantic_kind, snapshot)
		if bool(validation.get("ok", false)):
			accepted_goals[cell] = true
		else:
			rejected_goals.append(validation)
	if accepted_goals.is_empty():
		return _result(false, CLASS_INVALID_GOAL, "no_valid_goal_cell", [], [], {
			"collisionBacked": true,
			"generatedWorldInformed": true,
			"rejectedGoals": rejected_goals
		})
	for cell in accepted_goals.keys():
		target_lookup[cell] = true
	var start_validation := validate_route_cell(entry, snapshot, start_cell, target_lookup, allow_outside, moving_home, ignore_dynamic, true)
	if not bool(start_validation.get("ok", false)):
		var start_class := _classification_for_block_reason(String(start_validation.get("reason", "")))
		return _result(false, start_class, String(start_validation.get("reason", "invalid_start")), [], [], {
			"collisionBacked": true,
			"generatedWorldInformed": true,
			"start": start_validation,
			"rejectedGoals": rejected_goals
		})
	if accepted_goals.has(start_cell):
		var single_route := [start_cell]
		return _result(true, CLASS_REACHABLE, "already_at_goal", single_route, [], {
			"collisionBacked": true,
			"generatedWorldInformed": true,
			"snapshotRevision": String(snapshot.get("revision", "")),
			"acceptedGoals": _cell_array(accepted_goals.keys()),
			"rejectedGoals": rejected_goals,
			"cellProof": [start_validation]
		}, {}, start_position)
	var search_key := _search_key(entry, start_cell, accepted_goals, snapshot, allow_outside, moving_home, ignore_dynamic, semantic_kind, avoid_cells)
	var actor_key := _search_actor_key(entry)
	_clear_replaced_actor_search(actor_key, search_key)
	var job: Dictionary = search_jobs.get(search_key, {}) if search_jobs.get(search_key, {}) is Dictionary else {}
	if job.is_empty():
		var initial_open := [{
			"cell": start_cell,
			"g": 0,
			"f": _goal_heuristic(start_cell, accepted_goals),
			"sequence": 0
		}]
		job = {
			"open": initial_open,
			"closed": {},
			"gScore": { start_cell: 0 },
			"parent": {},
			"cellProofs": { start_cell: start_validation },
			"blockedRecords": [],
			"doorEdges": [],
			"expansions": 0,
			"sequence": 1,
			"startedSnapshotRevision": _search_snapshot_revision(snapshot),
			"latestSnapshotRevision": _search_snapshot_revision(snapshot),
			"snapshotChanged": false
		}
		search_jobs[search_key] = job
		active_search_key_by_actor[actor_key] = search_key
	var current_search_revision := _search_snapshot_revision(snapshot)
	if current_search_revision != String(job.get("startedSnapshotRevision", current_search_revision)):
		job["snapshotChanged"] = true
	job["latestSnapshotRevision"] = current_search_revision
	var open: Array = job.get("open", []) if job.get("open", []) is Array else []
	var closed: Dictionary = job.get("closed", {}) if job.get("closed", {}) is Dictionary else {}
	var g_score: Dictionary = job.get("gScore", {}) if job.get("gScore", {}) is Dictionary else {}
	var parent: Dictionary = job.get("parent", {}) if job.get("parent", {}) is Dictionary else {}
	var cell_proofs: Dictionary = job.get("cellProofs", {}) if job.get("cellProofs", {}) is Dictionary else {}
	var blocked_records: Array = job.get("blockedRecords", []) if job.get("blockedRecords", []) is Array else []
	var door_edges: Array = job.get("doorEdges", []) if job.get("doorEdges", []) is Array else []
	var expansions := int(job.get("expansions", 0))
	var sequence := int(job.get("sequence", 1))
	var expansions_this_call := 0
	var expansions_per_call := maxi(1, int(options.get("expansionsPerCall", DEFAULT_EXPANSIONS_PER_CALL)))
	var found := INVALID_CELL
	while not open.is_empty():
		if expansions >= max_expansions:
			_update_search_job(job, open, closed, g_score, parent, cell_proofs, blocked_records, door_edges, expansions, sequence)
			return _result(false, CLASS_PENDING_BUDGET, "expansion_budget_exhausted", [], _limited_cell_array(closed.keys(), MAX_RECORDED_VISITED), {
				"collisionBacked": true,
				"generatedWorldInformed": true,
				"snapshotRevision": String(snapshot.get("revision", "")),
				"searchStartedRevision": String(job.get("startedSnapshotRevision", "")),
				"searchSnapshotRevision": current_search_revision,
				"searchSnapshotChanged": bool(job.get("snapshotChanged", false)),
				"acceptedGoals": _cell_array(accepted_goals.keys()),
				"rejectedGoals": rejected_goals,
				"blocked": blocked_records,
				"doorEdges": door_edges,
				"maxExpansions": max_expansions,
				"expansions": expansions,
				"visitedCount": closed.size(),
				"avoidCells": avoid_cells
			})
		if expansions_this_call >= expansions_per_call:
			_update_search_job(job, open, closed, g_score, parent, cell_proofs, blocked_records, door_edges, expansions, sequence)
			return _result(false, CLASS_PENDING_BUDGET, "search_budget_deferred", [], _limited_cell_array(closed.keys(), MAX_RECORDED_VISITED), {
				"collisionBacked": true,
				"generatedWorldInformed": true,
				"snapshotRevision": String(snapshot.get("revision", "")),
				"searchStartedRevision": String(job.get("startedSnapshotRevision", "")),
				"searchSnapshotRevision": current_search_revision,
				"searchSnapshotChanged": bool(job.get("snapshotChanged", false)),
				"acceptedGoals": _cell_array(accepted_goals.keys()),
				"rejectedGoals": rejected_goals,
				"blocked": blocked_records,
				"doorEdges": door_edges,
				"maxExpansions": max_expansions,
				"expansions": expansions,
				"expansionsThisCall": expansions_this_call,
				"visitedCount": closed.size(),
				"avoidCells": avoid_cells
			})
		var current_record: Dictionary = _open_heap_pop(open)
		var current: Vector2i = current_record.get("cell", INVALID_CELL)
		if current == INVALID_CELL or closed.has(current):
			continue
		closed[current] = true
		if accepted_goals.has(current):
			found = current
			break
		expansions += 1
		expansions_this_call += 1
		for neighbor in _neighbors(current):
			if closed.has(neighbor):
				continue
			if _route_avoid_blocks_cell(avoid_lookup, neighbor, start_cell, accepted_goals):
				_append_bounded(blocked_records, _avoid_block_record(current, neighbor), MAX_RECORDED_BLOCKS)
				continue
			var cell_validation := validate_route_cell(entry, snapshot, neighbor, target_lookup, allow_outside, moving_home, ignore_dynamic, false)
			if not bool(cell_validation.get("ok", false)):
				_append_bounded(blocked_records, cell_validation, MAX_RECORDED_BLOCKS)
				continue
			var transition := validate_transition(entry, snapshot, current, neighbor, target_lookup, ignore_dynamic)
			if not bool(transition.get("ok", false)):
				_append_bounded(blocked_records, transition, MAX_RECORDED_BLOCKS)
				continue
			var tentative_g := int(current_record.get("g", 0)) + 1
			if g_score.has(neighbor) and tentative_g >= int(g_score.get(neighbor, 2147483000)):
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
				"sequence": sequence
			})
			sequence += 1
	if found != INVALID_CELL:
		var route := _reconstruct_route(parent, start_cell, found)
		var completed_validation := _validate_completed_route(entry, snapshot, route, target_lookup, allow_outside, moving_home, ignore_dynamic)
		if not bool(completed_validation.get("ok", false)):
			_clear_search_job(actor_key, search_key)
			return _result(false, CLASS_PENDING_BUDGET, "route_snapshot_changed", [], _limited_cell_array(closed.keys(), MAX_RECORDED_VISITED), {
				"collisionBacked": true,
				"generatedWorldInformed": true,
				"snapshotRevision": String(snapshot.get("revision", "")),
				"searchStartedRevision": String(job.get("startedSnapshotRevision", "")),
				"searchSnapshotRevision": current_search_revision,
				"searchSnapshotChanged": bool(job.get("snapshotChanged", false)),
				"completedRouteValidation": completed_validation,
				"expansions": expansions,
				"visitedCount": closed.size()
			})
		_clear_search_job(actor_key, search_key)
		var route_door_edges := _door_edges_for_route(entry, snapshot, route, target_lookup, ignore_dynamic)
		var route_actions := _door_actions_for_edges(route_door_edges)
		var route_proofs: Array = []
		for cell in route:
			route_proofs.append(cell_proofs.get(cell, { "cell": cell, "ok": true }))
		return _result(true, CLASS_REACHABLE, "route_found", route, _limited_cell_array(closed.keys(), MAX_RECORDED_VISITED), {
			"collisionBacked": true,
			"generatedWorldInformed": true,
			"snapshotRevision": String(snapshot.get("revision", "")),
			"searchStartedRevision": String(job.get("startedSnapshotRevision", "")),
			"searchSnapshotRevision": current_search_revision,
			"searchSnapshotChanged": bool(job.get("snapshotChanged", false)),
			"acceptedGoals": _cell_array(accepted_goals.keys()),
			"rejectedGoals": rejected_goals,
			"blocked": blocked_records,
			"doorEdges": route_door_edges,
			"exploredDoorEdges": door_edges,
			"cellProof": route_proofs,
			"expansions": expansions,
			"visitedCount": closed.size(),
			"avoidCells": avoid_cells
		}, route_actions, start_position)
	if bool(job.get("snapshotChanged", false)):
		_clear_search_job(actor_key, search_key)
		return _result(false, CLASS_PENDING_BUDGET, "search_snapshot_changed", [], _limited_cell_array(closed.keys(), MAX_RECORDED_VISITED), {
			"collisionBacked": true,
			"generatedWorldInformed": true,
			"snapshotRevision": String(snapshot.get("revision", "")),
			"searchStartedRevision": String(job.get("startedSnapshotRevision", "")),
			"searchSnapshotRevision": current_search_revision,
			"searchSnapshotChanged": true,
			"expansions": expansions,
			"visitedCount": closed.size()
		})
	_clear_search_job(actor_key, search_key)
	var terminal_class := CLASS_UNREACHABLE_STATIC
	var terminal_reason := "no_static_route"
	for blocked in blocked_records:
		if String((blocked as Dictionary).get("classification", "")) == CLASS_BLOCKED_DYNAMIC:
			terminal_class = CLASS_BLOCKED_DYNAMIC
			terminal_reason = "dynamic_blocker_prevents_route"
			break
	return _result(false, terminal_class, terminal_reason, [], _limited_cell_array(closed.keys(), MAX_RECORDED_VISITED), {
		"collisionBacked": true,
		"generatedWorldInformed": true,
		"snapshotRevision": String(snapshot.get("revision", "")),
		"acceptedGoals": _cell_array(accepted_goals.keys()),
		"rejectedGoals": rejected_goals,
		"blocked": blocked_records,
		"doorEdges": door_edges,
		"expansions": expansions,
		"visitedCount": closed.size(),
		"avoidCells": avoid_cells
	})


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
	var candidate_key := _candidate_search_key(actor_key, raw_cells, semantic_kind, allow_outside, moving_home)
	_clear_replaced_actor_candidate_job(actor_key, candidate_key)
	var job: Dictionary = candidate_jobs.get(candidate_key, {}) if candidate_jobs.get(candidate_key, {}) is Dictionary else {}
	if job.is_empty():
		job = {
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
			}
		}
	_clear_candidate_job(actor_key, candidate_key)
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
	return {
		"ok": not accepted.is_empty(),
		"classification": CLASS_REACHABLE if not accepted.is_empty() else CLASS_INVALID_GOAL,
		"reason": "candidate_poses_found" if not accepted.is_empty() else "no_routeable_candidate_pose",
		"candidates": accepted,
		"rejected": rejected,
		"collisionBacked": true,
		"generatedWorldInformed": true
	}


func _candidate_search_key(actor_key: String, raw_cells: Array, semantic_kind: String, allow_outside: bool, moving_home: bool) -> String:
	var cells: Array[String] = []
	for value in raw_cells:
		if value is Vector2i:
			var cell: Vector2i = value
			cells.append("%d,%d" % [cell.x, cell.y])
	return "%s|%s|%s|%s|%s" % [actor_key, semantic_kind, str(allow_outside), str(moving_home), ";".join(cells)]


func _clear_replaced_actor_candidate_job(actor_key: String, candidate_key: String) -> void:
	var previous_key := String(active_candidate_key_by_actor.get(actor_key, ""))
	if previous_key != "" and previous_key != candidate_key:
		candidate_jobs.erase(previous_key)
	active_candidate_key_by_actor[actor_key] = candidate_key


func _clear_candidate_job(actor_key: String, candidate_key: String) -> void:
	candidate_jobs.erase(candidate_key)
	if String(active_candidate_key_by_actor.get(actor_key, "")) == candidate_key:
		active_candidate_key_by_actor.erase(actor_key)

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
	if ignore_dynamic and _adapter_has("cell_is_static_standable_goal"):
		var static_standable = world_adapter.call("cell_is_static_standable_goal", entry, cell, allow_outside, moving_home)
		if not bool(static_standable) and not allow_start and door == null:
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
		result["door"] = _door_summary(to_door if to_door != null else from_door)
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


func _reconstruct_route(parent: Dictionary, start_cell: Vector2i, goal_cell: Vector2i) -> Array:
	var result: Array = [goal_cell]
	var cursor := goal_cell
	var guard := 0
	while cursor != start_cell and guard < 10000:
		guard += 1
		cursor = parent.get(cursor, start_cell)
		result.push_front(cursor)
	return result


func _door_edges_for_route(entry: Dictionary, snapshot: Dictionary, route_cells: Array, target_lookup: Dictionary, ignore_dynamic := false) -> Array:
	var result: Array = []
	for index in range(1, route_cells.size()):
		if not (route_cells[index - 1] is Vector2i) or not (route_cells[index] is Vector2i):
			continue
		var from_cell: Vector2i = route_cells[index - 1]
		var to_cell: Vector2i = route_cells[index]
		var from_door = _door_at(snapshot, from_cell)
		var to_door = _door_at(snapshot, to_cell)
		if from_door == null and to_door == null:
			continue
		var transition := validate_transition(entry, snapshot, from_cell, to_cell, target_lookup, ignore_dynamic)
		var door = to_door if to_door != null else from_door
		transition["doorEdge"] = true
		transition["door"] = _door_summary(door)
		transition["doorNode"] = door
		transition["fromCell"] = from_cell
		transition["toCell"] = to_cell
		result.append(transition)
	return result


func _door_actions_for_edges(door_edges: Array) -> Dictionary:
	var actions := {}
	for edge_value in door_edges:
		if not (edge_value is Dictionary):
			continue
		var edge: Dictionary = edge_value
		var door = edge.get("doorNode")
		if not (door is Node):
			continue
		var from_cell: Vector2i = edge.get("fromCell", INVALID_CELL)
		var to_cell: Vector2i = edge.get("toCell", INVALID_CELL)
		if from_cell == INVALID_CELL or to_cell == INVALID_CELL:
			continue
		var action_cell := to_cell
		var portal_id := _door_portal_id(door, action_cell)
		actions["%d,%d" % [action_cell.x, action_cell.y]] = {
			"kind": "door",
			"portalId": portal_id,
			"actionId": "open",
			"cell": action_cell,
			"entryCell": from_cell,
			"entryPosition": _cell_position(from_cell),
			"exitPosition": _cell_position(to_cell),
			"direction": _direction_for_step(from_cell, to_cell),
			"navLink": false,
			"requiresSmartObject": true,
			"enabled": true,
			"door": door
		}
	return actions


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


func _search_key(entry: Dictionary, start_cell: Vector2i, accepted_goals: Dictionary, _snapshot: Dictionary, allow_outside: bool, moving_home: bool, ignore_dynamic: bool, semantic_kind: String, avoid_cells: Array) -> String:
	var goal_keys: Array[String] = []
	for cell in accepted_goals.keys():
		if cell is Vector2i:
			goal_keys.append("%d,%d" % [cell.x, cell.y])
	goal_keys.sort()
	var avoid_keys: Array[String] = []
	for cell in avoid_cells:
		if cell is Vector2i:
			avoid_keys.append("%d,%d" % [cell.x, cell.y])
	avoid_keys.sort()
	return "%s|%d,%d|%s|%s|%s|%s|%s" % [
		_search_actor_key(entry),
		start_cell.x,
		start_cell.y,
		semantic_kind,
		"1" if allow_outside else "0",
		"1" if moving_home else "0",
		"1" if ignore_dynamic else "0",
		"%s|%s" % [",".join(goal_keys), ",".join(avoid_keys)]
	]


func _validate_completed_route(entry: Dictionary, snapshot: Dictionary, route: Array, target_lookup: Dictionary, allow_outside: bool, moving_home: bool, ignore_dynamic: bool) -> Dictionary:
	for index in range(route.size()):
		var cell_value = route[index]
		if not (cell_value is Vector2i):
			return { "ok": false, "reason": "invalid_route_cell", "index": index }
		var cell: Vector2i = cell_value
		var cell_validation := validate_route_cell(entry, snapshot, cell, target_lookup, allow_outside, moving_home, ignore_dynamic, index == 0)
		if not bool(cell_validation.get("ok", false)):
			return { "ok": false, "reason": String(cell_validation.get("reason", "route_cell_invalid")), "index": index, "cell": cell, "validation": cell_validation }
		if index == 0:
			continue
		var previous: Vector2i = route[index - 1]
		var transition := validate_transition(entry, snapshot, previous, cell, target_lookup, ignore_dynamic)
		if not bool(transition.get("ok", false)):
			return { "ok": false, "reason": String(transition.get("reason", "route_transition_invalid")), "index": index, "cell": cell, "validation": transition }
	return { "ok": true, "reason": "route_revalidated", "cellCount": route.size() }


func _search_snapshot_revision(snapshot: Dictionary) -> String:
	if snapshot.has("staticSnapshotRevision"):
		# Door open/closed state does not change portal topology. Route execution
		# probes current collision and opens the portal before crossing.
		return "%s:%s" % [
			str(snapshot.get("staticSnapshotRevision", 0)),
			str(snapshot.get("semanticRevision", 0))
		]
	return String(snapshot.get("revision", ""))


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

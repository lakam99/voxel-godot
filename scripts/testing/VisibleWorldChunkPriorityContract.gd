extends SceneTree

const PRIORITY := preload("res://scripts/world/ChunkPropSpawnPriority.gd")
const REPORT_ENV := "VOXEL_VISIBLE_CHUNK_PRIORITY_REPORT"

var _checks: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var underground_chunk := Node3D.new()
	underground_chunk.set_meta("chunk_surface_candidate_scan_complete", true)
	var surface_chunk := Node3D.new()
	var underground_rng := RandomNumberGenerator.new()
	underground_rng.seed = 1492
	var surface_rng := RandomNumberGenerator.new()
	surface_rng.seed = 2401
	var underground_state := {"chunk": underground_chunk, "phase": "underground_props",
		"propIndex": 28, "undergroundScanColumn": 7, "rng": underground_rng}
	var surface_state := {"chunk": surface_chunk, "phase": "props",
		"propIndex": 5, "rng": surface_rng}
	var underground_key := Vector2i(1, 0)
	var surface_key := Vector2i(2, 0)
	var pending := {underground_key: underground_state, surface_key: surface_state}
	var visible: Array[Vector2i] = [underground_key, surface_key]
	var before_underground_rng: int = underground_rng.state
	var before_surface_rng: int = surface_rng.state
	var chosen: Array[String] = []
	# The previous queue picked the first listed visible key, which is the
	# already-surface-complete underground state in this pinned fixture.
	var previous_first_surface_visits := 1 if visible[0] == surface_key else 0
	for turn in range(1, 5):
		var ordered: Array[Vector2i] = PRIORITY.ordered_keys(pending, visible, turn % 4 == 0)
		chosen.append("underground" if ordered[0] == underground_key else "surface")
		_check("turn_%d_contains_both_keys" % turn,
			ordered.size() == 2 and ordered.has(underground_key) and ordered.has(surface_key))
		_check("turn_%d_preserves_state_identity" % turn,
			is_same(pending[underground_key], underground_state)
			and is_same(pending[surface_key], surface_state))
	_check("surface_first_for_three_turns", chosen.slice(0, 3) == ["surface", "surface", "surface"])
	_check("underground_receives_fourth_turn", chosen[3] == "underground")
	_check("first_turn_visits_new_surface_before_deep_scan",
		previous_first_surface_visits == 0 and chosen[0] == "surface")
	_check("attempt_and_rng_state_unchanged", underground_state.propIndex == 28
		and underground_state.undergroundScanColumn == 7 and surface_state.propIndex == 5
		and underground_rng.state == before_underground_rng and surface_rng.state == before_surface_rng)
	_check("same_rng_objects_retained", is_same(underground_state.rng, underground_rng)
		and is_same(surface_state.rng, surface_rng))
	var near_bounds := Rect2i(Vector2i.ZERO, Vector2i(56, 56))
	var physical := {underground_key: underground_chunk, surface_key: surface_chunk}
	var required_reason := {underground_key: {"reason": "chunk_prop_candidate_scan_incomplete"}}
	_check("pending_near_full_scan_selects_exact_physical_dependency",
		PRIORITY.required_near_full_scan_key(pending, required_reason, physical,
			visible, near_bounds, 28) == underground_key)
	_check("unreported_or_distant_source_does_not_gain_full_scan_boost",
		PRIORITY.required_near_full_scan_key(pending, {}, physical,
			visible, near_bounds, 28) == null
		and PRIORITY.required_near_full_scan_key(pending,
			{surface_key: {"reason": "chunk_prop_candidate_scan_incomplete"}},
			physical, visible, near_bounds, 28) == null)
	underground_chunk.set_meta("chunk_prop_candidate_scan_complete", true)
	_check("completed_near_source_does_not_gain_full_scan_boost",
		PRIORITY.required_near_full_scan_key(pending, required_reason, physical,
			visible, near_bounds, 28) == null)
	underground_chunk.set_meta("chunk_prop_candidate_scan_complete", false)
	underground_chunk.set_meta("horizon_visual_only", true)
	_check("horizon_source_cannot_gain_physical_full_scan_boost",
		PRIORITY.required_near_full_scan_key(pending, required_reason, physical,
			visible, near_bounds, 28) == null)
	underground_chunk.set_meta("horizon_visual_only", false)
	_check("surface_order_and_rng_remain_unchanged_after_dependency_selection",
		PRIORITY.ordered_keys(pending, visible, false)[0] == surface_key
		and underground_rng.state == before_underground_rng
		and surface_rng.state == before_surface_rng)
	_check("ordinary_surface_slice_budget_is_preserved_without_required_full_source",
		PRIORITY.startup_spare_slice_admitted(1.5, false, 1.6, 4.8, 2.8)
		and not PRIORITY.startup_spare_slice_admitted(1.6, false, 1.6, 4.8, 2.8))
	_check("required_full_source_gets_only_bounded_spare_slices",
		PRIORITY.startup_spare_slice_admitted(1.9, true, 1.6, 4.8, 2.8)
		and not PRIORITY.startup_spare_slice_admitted(2.1, true, 1.6, 4.8, 2.8))
	var passed := true
	for row in _checks:
		if not bool(row.passed):
			passed = false
	var report := {"schema": "visible-world-chunk-priority-contract/v1",
		"evidenceLevel": "synthetic_scheduler_contract", "passed": passed,
		"checkCount": _checks.size(), "checks": _checks, "chosen": chosen,
		"previousFirstTurnSurfaceVisits": previous_first_surface_visits,
		"currentFirstTurnSurfaceVisits": 1 if chosen[0] == "surface" else 0}
	var path := OS.get_environment(REPORT_ENV)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("priority contract report write failed")
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	underground_chunk.free()
	surface_chunk.free()
	quit(0 if passed else 1)

func _check(name: String, passed: bool) -> void:
	_checks.append({"name": name, "passed": passed})

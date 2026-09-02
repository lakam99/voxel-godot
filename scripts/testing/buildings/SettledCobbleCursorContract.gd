extends SceneTree
## Frozen pre-edit oracle vs new synchronous and sliced CPU descriptors. Includes
## historical actual source INPUT, never a Source/recipe rebuild or scene render.
const Geometry = preload("res://scripts/buildings/SettledCobbleGeometry.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const History = preload("res://scripts/buildings/SurfaceHistoryField.gd")
const REFERENCE := "res://artifacts/citadel-runtime-integration/paving-cursor-reference-01/SettledCobbleGeometryOriginal.gd"
const REFERENCE_SHA := "f13917cdc63354a7eec6fd4f3068c316751d085d8b43061f7fa4a3a47ee64823"
const HISTORY_SHA := "243802fb7135948ff3b2ec75a3a88aa59909d961bd2e88be158aee29e3532ca4"
const PART_SHA := "4d1a63bf1e4224a39eb6dcb8bec995ba31cf78da9cb766dd6d1295bfcb8a546d"
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const INPUT_SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"

class SnapshotSpy extends Part:
	var snapshots := 0
	func snapshot() -> Dictionary:
		snapshots += 1
		return super.snapshot()

class SyntheticHistory extends RefCounted:
	var queries: Array = []
	var mode := 1
	var cancel_after := -1
	var target: WeakRef
	func record(kind: String, position: Vector3, extent := Vector2.ZERO) -> void:
		queries.append([kind, position, extent])
		if target != null and queries.size() == cancel_after: target.get_ref().cancel()
	func conditions_at(position: Vector3) -> Dictionary:
		record("conditions", position)
		return {"canopyDeposit":fposmod(position.x * 0.19 + position.z * 0.13, 1.0)}
	func wear_contact_at(position: Vector3) -> Dictionary:
		record("wear", position)
		return {"influence":0.0 if mode == 0 else (1.0 if mode == 2 else fposmod(position.x * 0.37, 1.0)),
			"lateral":fposmod(position.z * 0.23, 1.0)}
	func root_buttress_contact(position: Vector3, extent: Vector2) -> Dictionary:
		record("roots", position, extent)
		return {"influence":0.0 if mode == 0 else (1.0 if mode == 2 else fposmod(position.z * 0.29, 1.0)),
			"direction":Vector3.ZERO if mode == 0 else Vector3(0.6, 0.0, 0.8),
			"lateral":sin(position.x * 0.31)}

var checks: Dictionary = {}
var cases: Array = []
var original
var _deadline := 0
var _actual_count := 0

func _initialize() -> void: call_deferred("_run")

func check(label: String, ok: bool) -> void:
	checks[label] = ok
	if not ok: print("COBBLE CURSOR FAILURE ", label)

func bounded() -> bool:
	return Time.get_ticks_msec() < _deadline

func drain(cursor, label: String, budget: int) -> Dictionary:
	check(label + "_partial_hidden", cursor.take_result().is_empty())
	while cursor.status().status == "pending_budget" and bounded(): cursor.advance(budget)
	check(label + "_ready", cursor.status().status == "ready")
	var result: Dictionary = cursor.take_result()
	check(label + "_one_shot", cursor.take_result().is_empty() and cursor.status().status == "consumed")
	return result

func synthetic_case(label: String, values: Dictionary, mode: int) -> void:
	var part = Part.new(values)
	var before := var_to_bytes(part.snapshot())
	var old_history := SyntheticHistory.new()
	old_history.mode = mode
	var expected: Dictionary = original.describe_source(part, old_history, "frozen-source")
	var expected_bytes := var_to_bytes(expected)
	var expected_queries := var_to_bytes(old_history.queries)
	var sync_history := SyntheticHistory.new()
	sync_history.mode = mode
	check(label + "_old_vs_sync_exact", expected_bytes == var_to_bytes(Geometry.describe_source(part, sync_history, "frozen-source")))
	check(label + "_sync_query_order", expected_queries == var_to_bytes(sync_history.queries))
	for budget: int in [1, 2500, 4000]:
		var history := SyntheticHistory.new()
		history.mode = mode
		var cursor = Geometry.begin_source(part, history, "frozen-source")
		check(label + "_setup_no_queries_" + str(budget), history.queries.is_empty())
		var actual := drain(cursor, label + "_" + str(budget), budget)
		check(label + "_old_vs_cursor_exact_" + str(budget), expected_bytes == var_to_bytes(actual))
		check(label + "_cursor_query_order_" + str(budget), expected_queries == var_to_bytes(history.queries))
	check(label + "_input_immutable", before == var_to_bytes(part.snapshot()))
	cases.append({"label":label, "synthetic":true, "regular":expected.regularIds.size(), "worn":expected.wornIds.size()})

func cancellation_controls() -> void:
	var part = SnapshotSpy.new({"id":"cancel", "kind":"foundation", "size":Vector3(8, 0.1, 8)})
	var history := SyntheticHistory.new()
	var cursor = Geometry.begin_source(part, history, "cancel-source")
	check("setup_keeps_input_identity", is_same(cursor.part, part) and is_same(cursor.surface_history, history))
	check("setup_no_snapshot_copy_or_queries", part.snapshots == 0 and history.queries.is_empty())
	check("budget_zero_rejected", cursor.advance(0).status == "rejected")
	check("budget_4001_rejected", cursor.advance(4001).status == "rejected")
	check("bad_budget_no_work", cursor.status().units == 0 and history.queries.is_empty())
	cursor.cancel()
	check("entry_cancel_no_result", cursor.advance().status == "cancelled" and cursor.take_result().is_empty() and history.queries.is_empty())
	for stop: int in [1, 2, 3, 7]:
		history = SyntheticHistory.new()
		history.cancel_after = stop
		cursor = Geometry.begin_source(part, history, "cancel-source")
		history.target = weakref(cursor)
		while cursor.status().status == "pending_budget" and bounded(): cursor.advance(4000)
		check("query_cancel_" + str(stop), cursor.status().status == "cancelled" and history.queries.size() == stop and cursor.take_result().is_empty())
		var old_units: int = cursor.status().units
		cursor.advance(4000)
		cursor.cancel()
		check("no_queries_after_cancel_" + str(stop), history.queries.size() == stop and cursor.status().units == old_units)
		if stop == 7:
			check("partial_allocations_retained", cursor.regular_ids.size() + cursor.worn_ids.size() == 2)
	var part_ref: WeakRef = weakref(part)
	var history_ref: WeakRef = weakref(history)
	part = null
	history = null
	check("cancel_retains_input_ownership", part_ref.get_ref() != null and history_ref.get_ref() != null)
	cursor = null
	check("owner_release_releases_cancelled_inputs", part_ref.get_ref() == null and history_ref.get_ref() == null)
	# Cancellation after completion also hides the result without clearing arrays.
	part = Part.new({"id":"late", "size":Vector3(2, 0.1, 2)})
	history = SyntheticHistory.new()
	cursor = Geometry.begin_source(part, history, "late")
	while cursor.status().status == "pending_budget" and bounded(): cursor.advance()
	var count: int = cursor.regular_ids.size() + cursor.worn_ids.size()
	cursor.cancel()
	check("late_cancel_no_result_and_retains_arrays", count > 0 and cursor.take_result().is_empty() and cursor.regular_ids.size() + cursor.worn_ids.size() == count)
	# Inspect the pure private unit boundary directly, independent of how many
	# cheap units a given wall-clock slice happens to fit on this machine.
	history = SyntheticHistory.new()
	cursor = Geometry.begin(part, history, "civic_setts", false, 0.371)
	var one_stone_per_unit := true
	for index in range(1000):
		if cursor.status().status != "pending_budget": break
		var stones_before: int = cursor.regular_ids.size() + cursor.worn_ids.size()
		var queries_before := history.queries.size()
		cursor._step()
		one_stone_per_unit = one_stone_per_unit and cursor.regular_ids.size() + cursor.worn_ids.size() - stones_before <= 1 and history.queries.size() - queries_before <= 3
	check("one_candidate_stone_per_unit", one_stone_per_unit and cursor.status().status == "ready")
	var expected: Dictionary = original.describe(part, SyntheticHistory.new(), "civic_setts", false, 0.371)
	check("explicit_begin_old_exact", var_to_bytes(expected) == var_to_bytes(cursor.take_result()))
	check("explicit_describe_old_exact", var_to_bytes(expected) == var_to_bytes(Geometry.describe(part, SyntheticHistory.new(), "civic_setts", false, 0.371)))

func actual_cases() -> void:
	check("historical_input_sha", FileAccess.get_sha256(INPUT) == INPUT_SHA)
	if not checks.historical_input_sha: return
	var file := FileAccess.open(INPUT, FileAccess.READ)
	var source: Dictionary = file.get_var(false)
	file.close()
	var source_before := var_to_bytes(source.blueprint)
	var parts: Array = []
	for record: Dictionary in source.blueprint.parts:
		var part = Part.new(record)
		# Snapshot restoration, not constructor minimum-size policy.
		part.size = record.size
		parts.append(part)
	var history := History.new()
	history.configure(source.blueprint.recipe, parts)
	var history_before := var_to_bytes([history.route_corridors, history.tree_placements, history.history_events, history.history_event_cells])
	var source_id := String(source.blueprint.recipe.get("sourceBlueprintId", source.blueprint.id))
	for part in parts:
		if not bounded(): break
		if part.kind != "foundation" or part.material_id not in ["cobblestone", "worn_cobble"] or not part.recipe.get("visual", true): continue
		_actual_count += 1
		var label := "actual_" + String(part.id)
		var expected: Dictionary = original.describe_source(part, history, source_id)
		var expected_bytes := var_to_bytes(expected)
		check(label + "_old_vs_sync_exact", expected_bytes == var_to_bytes(Geometry.describe_source(part, history, source_id)))
		var cursor = Geometry.begin_source(part, history, source_id)
		var actual := drain(cursor, label, 2500)
		check(label + "_old_vs_cursor_exact", expected_bytes == var_to_bytes(actual))
		cases.append({"label":label, "synthetic":false, "regular":expected.regularIds.size(), "worn":expected.wornIds.size(), "metrics":cursor.status()})
	check("actual_paving_present", _actual_count > 0)
	check("actual_source_unchanged", source_before == var_to_bytes(source.blueprint))
	check("actual_history_unchanged", history_before == var_to_bytes([history.route_corridors, history.tree_placements, history.history_events, history.history_event_cells]))

func _run() -> void:
	_deadline = Time.get_ticks_msec() + 75000
	check("frozen_reference_sha", FileAccess.get_sha256(REFERENCE) == REFERENCE_SHA)
	check("bound_history_sha", FileAccess.get_sha256("res://scripts/buildings/SurfaceHistoryField.gd") == HISTORY_SHA)
	check("bound_part_sha", FileAccess.get_sha256("res://scripts/buildings/BuildingPart.gd") == PART_SHA)
	if checks.values().has(false):
		quit(2)
		return
	original = load(REFERENCE)
	for spec: Dictionary in [
		{"id":"negative_civic", "size":Vector3(3.7, 0.08, 4.1), "position":Vector3(-13.2, 0.8, -22.7), "recipe":{"pavingFamily":"civic_setts", "pavingHeading":"x"}},
		{"id":"rotated_lane_z", "size":Vector3(6.5, 0.14, 2.8), "position":Vector3(4.2, 0.9, -3.3), "rotation":Vector3(0.08, 0.63, -0.04), "recipe":{"pavingFamily":"lane_cobbles", "pavingHeading":"z"}},
		{"id":"thin_border", "size":Vector3(0.1, 0.04, 0.099), "position":Vector3(-0.1, 0, -0.1)},
		{"id":"empty_stones", "size":Vector3(0.02, 0.02, 0.02)},
		{"id":"courtyard", "size":Vector3(7.3, 0.18, 5.2), "recipe":{"pavingFamily":"courtyard_setts", "pavingRegion":"shared"}},
		{"id":"tie_axis", "size":Vector3(5, 0.1, 5), "semantic":"ordinary_route"},
		{"id":"expanded_spacing", "size":Vector3(120, 0.08, 140), "position":Vector3(200, 0.8, -180), "recipe":{"pavingFamily":"civic_setts", "pavingHeading":"x"}}
	]:
		if not bounded(): break
		synthetic_case(spec.id, spec, 1)
	for mode: int in [0, 2]: synthetic_case("uniform_" + str(mode), {"id":"uniform", "size":Vector3(4, 0.1, 4)}, mode)
	var packed_exact := true
	for strength: float in [-1.0, 0.0, 0.033, 0.25, 0.5, 0.999, 1.0, 2.0]:
		for lateral: float in [-1.0, 0.0, 0.5, 1.0, 2.0]:
			packed_exact = packed_exact and original.pack_route_history(strength, lateral) == Geometry.pack_route_history(strength, lateral)
	check("old_vs_new_history_packing", packed_exact)
	cancellation_controls()
	actual_cases()
	check("internal_deadline", bounded())
	check("reference_unchanged", FileAccess.get_sha256(REFERENCE) == REFERENCE_SHA)
	var failed: Array = []
	for key: String in checks:
		if not checks[key]: failed.append(key)
	var report := {"evidence":"frozen-original CPU descriptor parity; synthetic plus historical actual input, not live publication",
		"reference":REFERENCE, "referenceSha256":REFERENCE_SHA, "inputSha256":INPUT_SHA,
		"geometrySha256":FileAccess.get_sha256("res://scripts/buildings/SettledCobbleGeometry.gd"),
		"checkCount":checks.size(), "failureCount":failed.size(), "checks":checks, "failures":failed, "actualCount":_actual_count, "cases":cases}
	var output := OS.get_environment("SETTLED_COBBLE_CURSOR_OUTPUT")
	if not output.is_empty():
		DirAccess.make_dir_recursive_absolute(output)
		var file := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "\t"))
	print("COBBLE_CURSOR_CONTRACT checks=", checks.size(), " failures=", failed.size(), " actual=", _actual_count)
	quit(0 if failed.is_empty() else 1)

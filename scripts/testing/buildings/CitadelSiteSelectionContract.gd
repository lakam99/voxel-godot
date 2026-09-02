extends SceneTree

## Independent SOURCE/SERVICE contract, never live gameplay acceptance.
## Successful and town-rejected surveys use actual production WGS/context.
## No recipes, publishers, Main instance, NPCs, terrain edits or mock worlds.
## Predicate cases are explicitly labelled; timing is cold source cost only.
## All rectangles here are caller-supplied SYNTHETIC test envelopes, NOT
## geometry-derived reservations. Passing is not checkpoint-2 completion.
const Field := preload("res://scripts/world/CitadelSiteField.gd")
const Survey := preload("res://scripts/world/CitadelSiteSurvey.gd")
const World := preload("res://scripts/WorldGenerationSystem.gd")
const Context := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const FIXED_SEED := "atlas-1492"
const MAX_ELAPSED_USEC := 80000000
const TIMING_KEYS := ["slices", "maxSliceUsec", "maxColumnUsec", "sliceOverruns", "preparationUsec", "workUsec", "lastBudgetUsec"]

var started_usec := 0
var report_path := ""
var checks: Dictionary = {}
var failures: Array[String] = []
var measurements: Array[Dictionary] = []
var report := {
	"schema": "citadel-site-selection-contract/v1",
	"evidenceLevel": "source_service_contract",
	"complete": false, "passed": false,
	"doesNotProve": "No checkpoint-2 completion, geometry-derived reservation, terrain support, collision, visual, navigation, loading, streaming, save, or live gameplay acceptance. Surveyed is NOT publication-ready; other sites and durable edits remain unresolved.",
	"reservationProvenance": "Caller-supplied synthetic test rectangles, NOT geometry-derived envelopes.",
	"timingScope": "Cold private production WGS per begin; measured sample/slice maxima, not frame-budget acceptance. External watchdog 90 seconds.",
	"comparison": "Exact typed semantic snapshots; only named timing/slice telemetry excluded. Independent every-column production WGS oracle.",
	"mockCoverage": "None. Biome and envelope predicates are labelled predicate checks, not surveyed worlds."
}


func _initialize() -> void:
	call_deferred("_run")


func _check(label: String, condition: bool) -> bool:
	# Repeated checks aggregate; a later pass must never conceal a failure.
	checks[label] = bool(checks.get(label, true)) and condition
	if not condition and not failures.has(label):
		failures.append(label)
	return condition


func _within_deadline() -> bool:
	return _check("internal_elapsed_cap", Time.get_ticks_usec() - started_usec < MAX_ELAPSED_USEC)


func _exact(left: Variant, right: Variant) -> bool:
	return var_to_bytes(left) == var_to_bytes(right)


func _semantic(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	for key in TIMING_KEYS:
		result.erase(key)
	return result


func _run() -> void:
	started_usec = Time.get_ticks_usec()
	report_path = OS.get_environment("VOXEL_CITADEL_SITE_REPORT")
	var fresh_seed := OS.get_environment("VOXEL_CITADEL_SITE_SEED")
	if report_path.is_empty() or not report_path.is_absolute_path() or FileAccess.file_exists(report_path) or fresh_seed.is_empty() or fresh_seed == FIXED_SEED:
		printerr("SITE CONTRACT requires a fresh absolute report path and wrapper-recorded random seed")
		quit(2)
		return
	report["seeds"] = [FIXED_SEED, fresh_seed, fresh_seed + ":density-secondary"]
	report["startedUtc"] = Time.get_datetime_string_from_system(true)
	# Persist seed/provenance BEFORE any contract work; a timeout cannot erase it.
	_write_report()
	print("SITE CONTRACT seeds=", report.seeds)
	_test_predicates()
	_test_field(report.seeds)
	for world_seed: String in [FIXED_SEED, fresh_seed]:
		if not _within_deadline():
			break
		_test_surveys(world_seed)
	report["measurements"] = measurements
	var maxima := {"wholeBeginUsec": 0, "wholeAdvanceUsec": 0, "reportedSampleUsec": 0, "reportedSliceUsec": 0}
	for measurement: Dictionary in measurements:
		maxima.wholeBeginUsec = maxi(maxima.wholeBeginUsec, int(measurement.get("observedWholeBeginUsec", 0)))
		maxima.wholeAdvanceUsec = maxi(maxima.wholeAdvanceUsec, int(measurement.get("observedMaxAdvanceUsec", 0)))
		maxima.reportedSampleUsec = maxi(maxima.reportedSampleUsec, int(measurement.get("reportedMaxColumnUsec", 0)))
		maxima.reportedSliceUsec = maxi(maxima.reportedSliceUsec, int(measurement.get("reportedMaxSliceUsec", 0)))
	report["coldSourceTimingMaxima"] = maxima
	report["checks"] = checks
	report["failures"] = failures
	report["elapsedUsec"] = Time.get_ticks_usec() - started_usec
	report["complete"] = _within_deadline()
	report["passed"] = failures.is_empty() and report.complete
	_write_report()
	print("SITE CONTRACT complete=", report.complete, " passed=", report.passed, " checks=", checks.size(), " failures=", failures)
	quit(0 if report.passed else 1)


func _write_report() -> void:
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		printerr("Cannot write site contract report: ", report_path)
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()


func _test_predicates() -> void:
	_check("predicate.policy_constants", Field.REGION_CELLS == 2048 and Field.JITTER_CELLS == 384 and Field.OCCUPANCY_PER_THOUSAND == 350 and Field.REGION_GUARD_CELLS == 1)
	var coordinates := [-4097, -4096, -4095, -2049, -2048, -2047, -1, 0, 1, 2047, 2048, 2049]
	var regions := [-3, -2, -2, -2, -1, -1, -1, 0, 0, 0, 1, 1]
	for x in range(coordinates.size()):
		for z in range(coordinates.size()):
			_check("predicate.negative_and_positive_region_seams", Field.region_for_cell(Vector2i(coordinates[x], coordinates[z])) == Vector2i(regions[x], regions[z]))
	for region: Vector2i in [Vector2i.ZERO, Vector2i(-1, -2), Vector2i(2, 1)]:
		var start := region * 2048
		_check("predicate.exact_guard_envelope", Field.reservation_fits_region(region, Rect2i(start + Vector2i.ONE, Vector2i(2046, 2046))))
		for rectangle: Rect2i in [Rect2i(start, Vector2i(2, 2)), Rect2i(start + Vector2i(1, 0), Vector2i(2, 2)), Rect2i(start + Vector2i.ONE, Vector2i(2047, 2)), Rect2i(start + Vector2i.ONE, Vector2i(2, 2047)), Rect2i(start + Vector2i.ONE, Vector2i.ZERO), Rect2i(start + Vector2i.ONE, Vector2i(-1, 8))]:
			_check("predicate.border_and_empty_envelope_rejected", not Field.reservation_fits_region(region, rectangle))
	# Include all current production land biomes plus an unknown land identity:
	# this must remain an exclusion policy, not a temperate-biome whitelist.
	for biome: String in ["plains", "forest", "taiga", "tundra", "snow", "swamp", "desert", "savanna", "beach", "mountain", "future_land_biome"]:
		_check("predicate.surface_permitted." + biome, Field.allows_surface_biome(biome))
	for biome: String in ["", "ocean", "cave", "underground", "deep_underground", "underground_air", "town"]:
		_check("predicate.surface_excluded." + biome, not Field.allows_surface_biome(biome))
	_check("predicate.empty_seed_absent", Field.candidate_for_region("", Vector2i.ZERO).is_empty())
	for region: Vector2i in [Vector2i(-1048577, 0), Vector2i(1048576, 0), Vector2i(0, -1048577), Vector2i(0, 1048576), Vector2i(2147483647, -2147483648)]:
		_check("predicate.out_of_int32_region_domain_absent", Field.candidate_for_region(FIXED_SEED, region).is_empty())
		_check("predicate.out_of_domain_envelope_rejected", not Field.reservation_fits_region(region, Rect2i(Vector2i.ZERO, Vector2i.ONE)))
	_check("predicate.int32_min_region", Field.region_for_cell(Vector2i(-2147483648, -2147483648)) == Vector2i(-1048576, -1048576))
	_check("predicate.int32_max_region", Field.region_for_cell(Vector2i(2147483647, 2147483647)) == Vector2i(1048575, 1048575))
	_check("predicate.reservation_end_overflow_rejected", not Field.reservation_fits_region(Vector2i(1048575, 0), Rect2i(Vector2i(2147483600, 1), Vector2i(100, 1))))
	_check("predicate.negative_region_huge_size_rejected", not Field.reservation_fits_region(Vector2i(-1048576, 0), Rect2i(Vector2i(-2147483647, 1), Vector2i(2147483647, 1))))
	for edge: int in [-1048576, 1048575]:
		var found := false
		for index in range(32):
			var region := Vector2i(edge, index - 16)
			var candidate := Field.candidate_for_region(FIXED_SEED, region)
			if not candidate.is_empty():
				found = true
				_check("field.extreme_valid_regions_do_not_alias", Field.region_for_cell(candidate.centerCell) == region)
		_check("field.extreme_valid_candidate_found", found)


func _test_field(seeds: Array) -> void:
	var densities: Array[Dictionary] = []
	var all_ids: Dictionary = {}
	for world_seed: String in seeds:
		var atlas: Dictionary = {}
		var occupied := 0
		for z in range(-50, 50):
			if not _within_deadline():
				return
			for x in range(-50, 50):
				var region := Vector2i(x, z)
				var candidate := Field.candidate_for_region(world_seed, region)
				atlas[region] = candidate.duplicate(true)
				if candidate.is_empty():
					continue
				occupied += 1
				_check("field.complete_candidate_keys", candidate.has_all(["version", "siteId", "worldSeed", "region", "centerCell", "recipeSeed", "surfaceOnly"]))
				var center: Vector2i = candidate.get("centerCell", Vector2i.ZERO)
				var jitter := center - (region * 2048 + Vector2i(1024, 1024))
				_check("field.jitter_envelope", absi(jitter.x) <= 384 and absi(jitter.y) <= 384 and Field.region_for_cell(center) == region)
				_check("field.candidate_identity", candidate.get("worldSeed") == world_seed and candidate.get("region") == region and candidate.get("surfaceOnly") == true and candidate.get("version") == Field.VERSION)
				_check("field.recipe_seed_integer", typeof(candidate.get("recipeSeed")) == TYPE_INT and int(candidate.get("recipeSeed", -1)) >= 0)
				var site_id := String(candidate.get("siteId", ""))
				_check("field.seed_and_region_ids_unique", not site_id.is_empty() and not all_ids.has(site_id))
				all_ids[site_id] = true
		var density := float(occupied) / 10000.0
		# ~6 sigma at n=10000, intentionally no brittle exact occupancy count.
		_check("field.density." + world_seed, density >= 0.32 and density <= 0.38)
		densities.append({"seed": world_seed, "regions": 10000, "occupied": occupied, "density": density, "expected": 0.35, "acceptedRange": [0.32, 0.38]})
		var instance = Field.new()
		var ordered_regions: Array = atlas.keys()
		ordered_regions.reverse()
		for region: Vector2i in ordered_regions:
			_check("field.reverse_order_fresh_instance", _exact(atlas[region], instance.candidate_for_region(world_seed, region)))
		seed(190731)
		var expected_random := [randi(), randi(), randi()]
		seed(190731)
		for index in range(64):
			Field.candidate_for_region(world_seed, Vector2i(index - 32, index * 3 - 96))
		_check("field.does_not_consume_global_rng", expected_random == [randi(), randi(), randi()])
		seed(90713)
		for index in range(64):
			randi()
			var region := Vector2i(index - 32, 0)
			var candidate := Field.candidate_for_region(world_seed, region)
			_check("field.unaffected_by_global_rng", _exact(candidate, atlas[region]))
			candidate.clear()
			_check("field.return_value_isolation", _exact(Field.candidate_for_region(world_seed, region), atlas[region]))
	report["density"] = densities
	print("SITE CONTRACT density complete ", densities)


func _production_world(world_seed: String, overrides: Dictionary = {}):
	var context = Context.new()
	context.seed_text = world_seed
	context.seed_hash = context.hash_string(world_seed)
	context.pinned_town_regions = overrides.duplicate(true)
	context.setup_noise()
	var world = World.new()
	world.setup(context)
	context.set_generator(world)
	return world


func _digest(value: Variant) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(var_to_bytes(value))
	return hashing.finish().hex_encode()


func _begin(survey, world_seed: String, region: Vector2i, rectangle: Rect2i, overrides: Dictionary, surface := true) -> Dictionary:
	var call_start := Time.get_ticks_usec()
	var initial: Dictionary = survey.begin(world_seed, region, rectangle, overrides, surface)
	var elapsed := Time.get_ticks_usec() - call_start
	measurements.append({"label": world_seed + ":begin", "observedWholeBeginUsec": elapsed, "reportedPreparationUsec": initial.get("preparationUsec"), "status": initial.get("status"), "reason": initial.get("reason")})
	_check("survey.begin_timing_scope", int(initial.get("preparationUsec", -1)) >= 0 and int(initial.get("preparationUsec", -1)) <= elapsed and initial.get("workUsec") == 0 and initial.get("lastBudgetUsec") == 0)
	_check("survey.explicit_incomplete_coverage", initial.get("publicationReady") == false and initial.get("surfacePolicyEligible") == false and initial.get("elevationStatisticsComplete") == false and initial.get("reservationProvenance") == "caller_supplied_unverified" and initial.get("otherSiteCoverage") == "unresolved" and initial.get("durableEditCoverage") == "unresolved")
	if initial.get("status") == "pending_budget":
		_check("survey.policy_versions", initial.get("generationPolicyVersion") == 1 and initial.get("surveyPolicyVersion") == 1)
		# Independent construction of the documented canonical source descriptor.
		# It includes engine/policy/seed and sorted explicit overrides (including
		# explicit empty records), never mutable source objects or noise caches.
		var canonical: Array = [1, Engine.get_version_info().string, world_seed]
		var ordered: Array = overrides.keys()
		ordered.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
		for key: Vector2i in ordered:
			var supplied: Dictionary = overrides[key]
			var record := {}
			if not supplied.is_empty():
				record = {"regionX": key.x, "regionZ": key.y, "centerX": int(supplied.centerX), "centerZ": int(supplied.centerZ), "radius": int(supplied.radius), "level": float(supplied.level)}
			canonical.append([key, record])
		var source_identity := _digest(canonical)
		_check("survey.canonical_source_identity", initial.get("sourceIdentity") == source_identity)
		_check("survey.canonical_request_identity", initial.get("requestIdentity") == _digest([1, source_identity, Field.candidate_for_region(world_seed, region), rectangle, surface]))
	else:
		_check("survey.early_rejection_clears_identities", initial.get("sourceIdentity") == "" and initial.get("requestIdentity") == "")
	return initial


func _oracle(world_seed: String, rectangle: Rect2i, overrides: Dictionary = {}) -> Dictionary:
	# Separate, fresh actual WGS. Deliberately does not call Survey or its helpers.
	var world = _production_world(world_seed, overrides)
	var counts: Dictionary = {}
	var low := INF
	var high := -INF
	var columns := 0
	for z in range(rectangle.position.y, rectangle.end.y):
		for x in range(rectangle.position.x, rectangle.end.x):
			var cell := Vector3i(x, 0, z)
			columns += 1
			if not world.town_region_for_surface_cell3(cell).is_empty():
				return {"status": "rejected", "reason": "town_reservation_overlap", "rejectedCell": Vector2i(x, z), "columns": columns, "biomeCounts": counts, "min": low if is_finite(low) else null, "max": high if is_finite(high) else null}
			var biome: String = world.surface_biome_for_cell3(cell)
			if biome in ["", "ocean", "cave", "underground", "deep_underground", "underground_air", "town"]:
				return {"status": "rejected", "reason": "excluded_biome:" + biome, "rejectedCell": Vector2i(x, z), "columns": columns, "biomeCounts": counts, "min": low if is_finite(low) else null, "max": high if is_finite(high) else null}
			var height: float = world.base_surface_y_for_cell(cell)
			_check("oracle.finite_production_height", is_finite(height))
			counts[biome] = int(counts.get(biome, 0)) + 1
			low = minf(low, height)
			high = maxf(high, height)
	return {"status": "surveyed", "reason": "", "rejectedCell": Vector2i.ZERO, "columns": columns, "biomeCounts": counts, "min": low, "max": high}


func _drain(survey, initial: Dictionary, budget: int, label: String) -> Dictionary:
	var current := initial
	var max_observed_usec := 0
	var max_columns := 0
	var steps := 0
	while current.get("status") == "pending_budget" and steps < 4096 and _within_deadline():
		var before := int(current.get("columnsInspected", 0))
		var step_start := Time.get_ticks_usec()
		current = survey.advance(budget)
		max_observed_usec = maxi(max_observed_usec, Time.get_ticks_usec() - step_start)
		var delta := int(current.get("columnsInspected", 0)) - before
		max_columns = maxi(max_columns, delta)
		_check("survey.step_column_cap", delta >= 1 and delta <= 64)
		_check("survey.never_publication_ready", current.get("publicationReady") == false)
		_check("survey.budget_clamped", current.get("lastBudgetUsec") == clampi(budget, 1, 4000))
		_check("survey.timing_excludes_return_explicit", current.get("sliceTimingScope") == "scan_loop_excludes_snapshot_return")
		_check("survey.eligibility_only_when_surveyed", current.get("surfacePolicyEligible") == (current.get("status") == "surveyed") and current.get("elevationStatisticsComplete") == (current.get("status") == "surveyed"))
		steps += 1
	_check("survey.bounded_completion." + label, current.get("status") in ["surveyed", "rejected"])
	measurements.append({"label": label, "budgetUsec": budget, "steps": steps, "maxColumnsPerStep": max_columns, "observedMaxAdvanceUsec": max_observed_usec, "reportedMaxSliceUsec": current.get("maxSliceUsec"), "reportedMaxColumnUsec": current.get("maxColumnUsec"), "sliceOverruns": current.get("sliceOverruns"), "coldPrivateSource": true})
	_check("survey.terminal_advance_idempotent", _exact(current, survey.advance(budget)))
	return current


func _compare_oracle(snapshot: Dictionary, expected: Dictionary, rectangle: Rect2i) -> void:
	_check("survey.oracle_status_reason", snapshot.get("status") == expected.status and snapshot.get("reason") == expected.reason)
	_check("survey.every_column_cardinality", snapshot.get("columnsInspected") == expected.columns and snapshot.get("totalColumns") == rectangle.size.x * rectangle.size.y)
	_check("survey.every_column_biomes", _exact(snapshot.get("biomeCounts"), expected.biomeCounts))
	_check("survey.exact_height_extrema", _exact(snapshot.get("minimumSurfaceY"), expected.min) and _exact(snapshot.get("maximumSurfaceY"), expected.max))
	_check("survey.exact_rejection_cell", snapshot.get("rejectedCell") == expected.rejectedCell)
	_check("survey.reservation_identity", snapshot.get("reservationCells") == rectangle)
	if snapshot.get("status") == "surveyed":
		var counted := 0
		for count: int in snapshot.get("biomeCounts", {}).values():
			counted += count
		_check("survey.full_success_cardinality", counted == rectangle.size.x * rectangle.size.y and counted == snapshot.get("columnsInspected"))


func _test_surveys(world_seed: String) -> void:
	var selected: Dictionary = {}
	var absent_region := Vector2i.ZERO
	var found_absent := false
	# Bounded discovery from actual WGS, not a mocked guaranteed-land sampler.
	for index in range(128):
		if not _within_deadline():
			return
		var region := Vector2i(index % 16 - 8, index / 16 - 4)
		var candidate := Field.candidate_for_region(world_seed, region)
		if candidate.is_empty():
			absent_region = region
			found_absent = true
			continue
		var rectangle := Rect2i(candidate.centerCell - Vector2i(4, 4), Vector2i(8, 8))
		var wide_rectangle := Rect2i(rectangle.position, Vector2i(16, 8))
		var wide_expected := _oracle(world_seed, wide_rectangle)
		if wide_expected.status == "surveyed":
			selected = {"region": region, "candidate": candidate, "rectangle": rectangle, "oracle": _oracle(world_seed, rectangle), "wideRectangle": wide_rectangle, "wideOracle": wide_expected}
			if found_absent:
				break
	if not _check("survey.actual_land_found." + world_seed, not selected.is_empty() and found_absent):
		return
	var region: Vector2i = selected.region
	var rectangle: Rect2i = selected.rectangle
	var baseline: Dictionary = {}
	for budget: int in [1, 2500, 4000, 1000000, 0, -1]:
		var survey = Survey.new()
		var initial := _begin(survey, world_seed, region, rectangle, {})
		_check("survey.begin_is_deferred", initial.get("status") == "pending_budget" and initial.get("columnsInspected") == 0)
		var retained := initial.duplicate(true)
		var result := _drain(survey, initial, budget, world_seed + ":cold:" + str(budget))
		_compare_oracle(result, selected.oracle, rectangle)
		_check("survey.retained_begin_unchanged", _exact(initial, retained))
		_check("survey.candidate_matches_field", _exact(result.get("candidate"), selected.candidate))
		_check("survey.source_identity_present", result.get("sourceIdentity") is String and String(result.get("sourceIdentity", "")).length() == 64)
		if baseline.is_empty():
			baseline = result.duplicate(true)
		else:
			_check("survey.cold_repeat_budget_semantics", _exact(_semantic(baseline), _semantic(result)))
		# Returned nested values must not write back into the survey authority.
		result.get("candidate", {}).clear()
		result.get("biomeCounts", {}).clear()
		result["sourceIdentity"] = "tampered"
		result["requestIdentity"] = "tampered"
		_check("survey.returned_snapshot_isolation", _exact(_semantic(baseline), _semantic(survey.snapshot())))
	var wide_survey = Survey.new()
	var wide_result := _drain(wide_survey, _begin(wide_survey, world_seed, region, selected.wideRectangle, {}), 1000000, world_seed + ":128_columns_cap")
	_compare_oracle(wide_result, selected.wideOracle, selected.wideRectangle)
	_check("survey.more_than_one_slice_for_128_columns", wide_result.get("status") == "surveyed" and int(wide_result.get("slices", 0)) >= 2 and wide_result.get("columnsInspected") == 128)
	_test_invalid_and_reuse(world_seed, selected, absent_region)
	_test_identity_and_bounds(world_seed, selected)
	_test_town_apron(world_seed)
	print("SITE CONTRACT survey complete seed=", world_seed, " region=", region)


func _test_invalid_and_reuse(world_seed: String, selected: Dictionary, absent: Vector2i) -> void:
	var survey = Survey.new()
	var region: Vector2i = selected.region
	var center: Vector2i = selected.candidate.centerCell
	var rectangle: Rect2i = selected.rectangle
	var retained := _drain(survey, _begin(survey, world_seed, region, rectangle, {}), 2500, world_seed + ":reuse_success")
	var retained_copy := retained.duplicate(true)
	var cases := [
		{"region": absent, "rect": rectangle, "overrides": {}, "surface": true, "reason": "no_candidate"},
		{"region": region, "rect": rectangle, "overrides": {}, "surface": false, "reason": "excluded_placement_context"},
		{"region": region, "rect": rectangle, "overrides": {"bad-key": {}}, "surface": true, "reason": "invalid_town_overrides"},
		{"region": region, "rect": rectangle, "overrides": {Vector2i.ZERO: {"radius": 30}}, "surface": true, "reason": "invalid_town_overrides"},
	]
	var valid_town := {"regionX": 0, "regionZ": 0, "centerX": 0, "centerZ": 0, "radius": 30, "level": 20.0}
	for change: Dictionary in [{"radius": 9223372036854775807}, {"radius": 153}, {"radius": 0}, {"radius": -1}, {"radius": 30.5}, {"centerX": 1}, {"centerZ": 1}, {"centerX": 0.5}, {"level": NAN}, {"level": INF}, {"level": "20"}, {"regionX": 1}, {"regionZ": -1}, {"regionX": 0.0}]:
		var invalid_town := valid_town.duplicate(true)
		invalid_town.merge(change, true)
		cases.append({"region": region, "rect": rectangle, "overrides": {Vector2i.ZERO: invalid_town}, "surface": true, "reason": "invalid_town_overrides"})
	for size: Vector2i in [Vector2i.ZERO, Vector2i(0, 8), Vector2i(8, 0), Vector2i(-8, 8), Vector2i(8, -8), Vector2i(513, 512)]:
		cases.append({"region": region, "rect": Rect2i(center, size), "overrides": {}, "surface": true, "reason": "invalid_reservation"})
	for invalid_rect: Rect2i in [Rect2i(region * 2048, Vector2i(2048, 2)), Rect2i(center + Vector2i(20, 20), Vector2i(8, 8))]:
		cases.append({"region": region, "rect": invalid_rect, "overrides": {}, "surface": true, "reason": "invalid_reservation"})
	for item: Dictionary in cases:
		# Seed partial work before EVERY failure, not just the first one.
		_begin(survey, world_seed, region, rectangle, {})
		survey.advance(1)
		var rejected := _begin(survey, world_seed, item.region, item.rect, item.overrides, item.surface)
		_check("survey.reject." + item.reason, rejected.get("status") == "rejected" and rejected.get("reason") == item.reason)
		_check("survey.failure_clears_previous_stats", rejected.get("columnsInspected") == 0 and rejected.get("biomeCounts", {"stale": 1}).is_empty() and rejected.get("minimumSurfaceY") == null and rejected.get("maximumSurfaceY") == null and rejected.get("slices") == 0 and rejected.get("maxSliceUsec") == 0 and rejected.get("maxColumnUsec") == 0 and rejected.get("sliceOverruns") == 0)
		_check("survey.rejected_never_ready", rejected.get("publicationReady") == false)
		_check("survey.failure_terminal", _exact(rejected, survey.advance()))
	_check("survey.completed_snapshot_survives_reuse", _exact(retained, retained_copy))
	# Area boundary is a begin-only validation test, NOT a 262144-column pass.
	var cap_rectangle := Rect2i(center - Vector2i(256, 256), Vector2i(512, 512))
	var cap := _begin(survey, world_seed, region, cap_rectangle, {})
	_check("survey.exact_area_cap_admitted_without_sampling", cap.get("status") == "pending_budget" and cap.get("totalColumns") == 262144 and cap.get("columnsInspected") == 0)
	var resumed := _drain(survey, _begin(survey, world_seed, region, rectangle, {}), 2500, world_seed + ":reuse_after_failure")
	_check("survey.reuse_recovers_exactly", _exact(_semantic(retained), _semantic(resumed)))


func _test_town_apron(world_seed: String) -> void:
	# Pin an aligned production town, radius 30, near a candidate. A thin
	# reservation reaches its apron while remaining wholly outside its core.
	for index in range(1024):
		if not _within_deadline():
			return
		var region := Vector2i(index % 32 - 16, index / 32 - 16)
		var candidate := Field.candidate_for_region(world_seed, region)
		if candidate.is_empty():
			continue
		var center: Vector2i = candidate.centerCell
		var town_region := Vector2i(roundi(float(center.x) / 280.0), roundi(float(center.y) / 280.0))
		var town_center := town_region * 280
		var delta := center - town_center
		if absi(delta.x) < 50 or absi(delta.x) > 90 or absi(delta.y) > 24:
			continue
		var apron_cell := town_center + Vector2i(31 * signi(delta.x), delta.y)
		var low := Vector2i(mini(center.x, apron_cell.x), mini(center.y, apron_cell.y))
		var rectangle := Rect2i(low, Vector2i(absi(center.x - apron_cell.x) + 1, 1))
		if not Field.reservation_fits_region(region, rectangle):
			continue
		var natural_world = _production_world(world_seed)
		var natural: float = natural_world.natural_surface_y_for_cell(Vector3i(town_center.x, 0, town_center.y))
		var level := clampf(roundf(maxf(natural, Context.WATER_LEVEL + 3.0) / Context.CELL) * Context.CELL, Context.WATER_LEVEL + 3.0, 52.0)
		var town := {"regionX": town_region.x, "regionZ": town_region.y, "centerX": town_center.x, "centerZ": town_center.y, "radius": 30, "level": level}
		var overrides := {town_region: town}
		var world = _production_world(world_seed, overrides)
		var sample := Vector3i(apron_cell.x, 0, apron_cell.y)
		if not world.town_region_at_cell3(sample).is_empty() or world.town_region_for_surface_cell3(sample).is_empty():
			continue
		var expected := _oracle(world_seed, rectangle, overrides)
		if expected.reason != "town_reservation_overlap" or Vector2(expected.rejectedCell - town_center).length() <= 30.0:
			continue
		var immutable_overrides := overrides.duplicate(true)
		var survey = Survey.new()
		var initial := _begin(survey, world_seed, region, rectangle, overrides)
		var initial_copy := initial.duplicate(true)
		# Mutation is after begin, before advance. Nested and outer aliases tested.
		town["level"] = NAN
		town["radius"] = 1
		overrides.clear()
		var result := _drain(survey, initial, 1, world_seed + ":mutated_input_town_apron")
		_compare_oracle(result, expected, rectangle)
		_check("survey.town_rejection_is_real_apron_not_core", result.get("reason") == "town_reservation_overlap" and Vector2(result.get("rejectedCell", town_center) - town_center).length() > 30.0)
		_check("survey.retained_source_snapshot_immutable", _exact(initial, initial_copy))
		var fresh = Survey.new()
		var repeated := _drain(fresh, _begin(fresh, world_seed, region, rectangle, immutable_overrides), 4000, world_seed + ":cold_town_apron_repeat")
		_check("survey.input_deep_copy_and_rejected_budget_semantics", _exact(_semantic(result), _semantic(repeated)))
		var no_override = Survey.new()
		var empty_source := _begin(no_override, world_seed, region, rectangle, {})
		_check("survey.explicit_override_changes_source_identity", not _exact(result.get("sourceIdentity"), empty_source.get("sourceIdentity")))
		measurements.append({"label": world_seed + ":town_fixture", "region": region, "candidate": center, "town": immutable_overrides[town_region], "reservation": rectangle, "apronProbe": apron_cell, "rejectedCell": result.get("rejectedCell"), "columns": result.get("columnsInspected")})
		return
	_check("survey.actual_town_apron_found." + world_seed, false)


func _test_identity_and_bounds(world_seed: String, selected: Dictionary) -> void:
	var region: Vector2i = selected.region
	var rectangle: Rect2i = selected.rectangle
	var key_a := Vector2i(200, 200)
	var key_b := Vector2i(201, 200)
	var town_a := {"regionX": 200, "regionZ": 200, "centerX": 56000, "centerZ": 56000, "radius": 30, "level": 20.0}
	# Maximum valid radius accepted without sampling an expensive large region.
	var town_b := {"centerX": 56280, "centerZ": 56000, "radius": 152, "level": 20}
	var forwards := {key_a: town_a, key_b: town_b}
	var backwards := {key_b: town_b.duplicate(true), key_a: town_a.duplicate(true)}
	var first = Survey.new()
	var second = Survey.new()
	var initial := _begin(first, world_seed, region, rectangle, forwards)
	var reordered := _begin(second, world_seed, region, rectangle, backwards)
	_check("survey.override_order_does_not_change_identity", initial.get("status") == "pending_budget" and _exact(_semantic(initial), _semantic(reordered)))
	# Mutating caller-owned nested records and the outer mapping cannot affect
	# subsequent source identity or production sampling of the begun request.
	town_a["centerX"] = -1
	town_b["radius"] = 9223372036854775807
	forwards.clear()
	var first_done := _drain(first, initial, 1, world_seed + ":ordered_overrides_mutated")
	var second_done := _drain(second, reordered, 4000, world_seed + ":reordered_overrides")
	_check("survey.reordered_overrides_exact_continuation", _exact(_semantic(first_done), _semantic(second_done)))
	_compare_oracle(first_done, selected.oracle, rectangle)
	var source = Survey.new()
	var absent := _begin(source, world_seed, region, rectangle, {})
	var explicit_empty := _begin(source, world_seed, region, rectangle, {key_a: {}})
	_check("survey.absent_vs_explicit_empty_override_distinct", absent.get("sourceIdentity") != explicit_empty.get("sourceIdentity") and absent.get("requestIdentity") != explicit_empty.get("requestIdentity"))
	var another_rectangle := Rect2i(rectangle.position, rectangle.size + Vector2i(1, 0))
	var resized := _begin(source, world_seed, region, another_rectangle, {})
	_check("survey.rectangle_changes_request_not_source", resized.get("status") == "pending_budget" and resized.get("sourceIdentity") == absent.get("sourceIdentity") and resized.get("requestIdentity") != absent.get("requestIdentity"))
	# Real field candidates on both sides of the supported +/-1,000,000
	# source-coordinate boundary. No oracle prewarm and no actual far scan.
	for region_x: int in [-489, -488, 487, 488]:
		var found := false
		for z in range(-16, 16):
			var far_region := Vector2i(region_x, z)
			var candidate := Field.candidate_for_region(world_seed, far_region)
			if candidate.is_empty():
				continue
			found = true
			var far_rectangle := Rect2i(candidate.centerCell - Vector2i(4, 4), Vector2i(8, 8))
			var result := _begin(source, world_seed, far_region, far_rectangle, {})
			if region_x in [-489, 488]:
				_check("survey.unsupported_source_coordinates_rejected", result.get("status") == "rejected" and result.get("reason") == "unsupported_survey_coordinates" and result.get("columnsInspected") == 0)
			else:
				_check("survey.supported_boundary_candidates_admitted", result.get("status") == "pending_budget" and result.get("columnsInspected") == 0)
			break
		_check("survey.coordinate_boundary_candidate_found", found)

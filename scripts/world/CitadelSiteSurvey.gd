extends RefCounted
class_name CitadelSiteSurvey

## Source-level reservation survey, NOT terrain support or live readiness.
## Builds a private production generator from seed + copied town overrides.
## It deliberately surveys generated base terrain, not saved edits. Caller
## envelopes are unverified until a later geometry manifest binds them; this
## API alone cannot certify geometry, other sites, fluids or foundation support.
const Field := preload("res://scripts/world/CitadelSiteField.gd")
const Context := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const World := preload("res://scripts/WorldGenerationSystem.gd")
const DEFAULT_BUDGET_USEC := 2500
const MAX_BUDGET_USEC := 4000
const MAX_COLUMNS_PER_SLICE := 64
const MAX_TOTAL_COLUMNS := 262144
const MAX_TOWN_OVERRIDES := 4096
const SURVEY_POLICY_VERSION := 1
# Bump when production context/WGS/biome rules change surveyed base facts.
# Evidence records exact source hashes; runtime must not hash scripts per cell.
const GENERATION_POLICY_VERSION := 1
# Bound this first survey implementation well inside int32 coordinates; WGS
# samples adjacent town regions and their slope aprons beyond the query column.
const MAX_ABS_SURVEY_CELL := 1000000

var _world
var _candidate: Dictionary = {}
var _reservation := Rect2i()
var _cursor := 0
var _status := "not_started"
var _reason := ""
var _rejected_cell := Vector2i.ZERO
var _minimum_y := INF
var _maximum_y := -INF
var _biomes: Dictionary = {}
var _slices := 0
var _max_slice_usec := 0
var _max_column_usec := 0
var _slice_overruns := 0
var _source_identity := ""
var _preparation_usec := 0
var _work_usec := 0
var _last_budget_usec := 0
var _request_identity := ""


func begin(world_seed: String, region: Vector2i, reservation: Rect2i, town_overrides: Dictionary, surface_context: bool = true) -> Dictionary:
	var started := Time.get_ticks_usec()
	# Reuse replaces all prior state; nothing from a completed or partial survey
	# is an authority for the next request. Ownership/thread scheduling is external.
	_world = null
	_candidate = Field.candidate_for_region(world_seed, region)
	_reservation = reservation
	_cursor = 0
	_reason = ""
	_rejected_cell = Vector2i.ZERO
	_minimum_y = INF
	_maximum_y = -INF
	_biomes = {}
	_slices = 0
	_max_slice_usec = 0
	_max_column_usec = 0
	_slice_overruns = 0
	_source_identity = ""
	_preparation_usec = 0
	_work_usec = 0
	_last_budget_usec = 0
	_request_identity = ""
	_status = "pending_budget"
	if not surface_context:
		_reject("excluded_placement_context")
	elif _candidate.is_empty():
		_reject("no_candidate")
	elif not Field.reservation_fits_region(region, reservation) or not reservation.has_point(_candidate.centerCell) or reservation.size.x * reservation.size.y > MAX_TOTAL_COLUMNS:
		_reject("invalid_reservation")
	elif not _supported_coordinates(reservation):
		_reject("unsupported_survey_coordinates")
	elif not _valid_town_overrides(town_overrides):
		_reject("invalid_town_overrides")
	else:
		var context := Context.new()
		context.seed_text = world_seed
		context.seed_hash = context.hash_string(world_seed)
		# Canonical sorted records, not shared mutable Main/cache/scene objects.
		var ordered_keys: Array = town_overrides.keys()
		ordered_keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
		var canonical: Array = [GENERATION_POLICY_VERSION, Engine.get_version_info().string, world_seed]
		for key in ordered_keys:
			var town: Dictionary = town_overrides[key]
			var record := {}
			if not town.is_empty():
				record = {"regionX": key.x, "regionZ": key.y, "centerX": int(town.centerX), "centerZ": int(town.centerZ), "radius": int(town.radius), "level": float(town.level)}
			context.pinned_town_regions[key] = record
			canonical.append([key, record])
		_source_identity = _digest(canonical)
		_request_identity = _digest([SURVEY_POLICY_VERSION, _source_identity, _candidate, _reservation, surface_context])
		context.setup_noise()
		_world = World.new()
		_world.setup(context)
		context.set_generator(_world)
	_preparation_usec = Time.get_ticks_usec() - started
	return snapshot()


func advance(budget_usec: int = DEFAULT_BUDGET_USEC) -> Dictionary:
	if _status != "pending_budget":
		return snapshot()
	var budget := clampi(budget_usec, 1, MAX_BUDGET_USEC)
	_last_budget_usec = budget
	var started := Time.get_ticks_usec()
	var total := _reservation.size.x * _reservation.size.y
	_slices += 1
	var columns_this_slice := 0
	while _cursor < total and _status == "pending_budget" and columns_this_slice < MAX_COLUMNS_PER_SLICE:
		var column_started := Time.get_ticks_usec()
		var cell := _reservation.position + Vector2i(_cursor % _reservation.size.x, _cursor / _reservation.size.x)
		_inspect_column(cell)
		_cursor += 1
		columns_this_slice += 1
		_max_column_usec = maxi(_max_column_usec, Time.get_ticks_usec() - column_started)
		if Time.get_ticks_usec() - started >= budget:
			break
	if _cursor == total and _status == "pending_budget":
		_status = "surveyed"
	var elapsed := Time.get_ticks_usec() - started
	_work_usec += elapsed
	_max_slice_usec = maxi(_max_slice_usec, elapsed)
	if elapsed > budget:
		_slice_overruns += 1
	return snapshot()


func snapshot() -> Dictionary:
	return {
		"status": _status, "reason": _reason,
		"candidate": _candidate.duplicate(true), "reservationCells": _reservation,
		"sourceIdentity": _source_identity,
		"requestIdentity": _request_identity,
		"generationPolicyVersion": GENERATION_POLICY_VERSION,
		"surveyPolicyVersion": SURVEY_POLICY_VERSION,
		"reservationProvenance": "caller_supplied_unverified",
		"otherSiteCoverage": "unresolved", "durableEditCoverage": "unresolved",
		"columnsInspected": _cursor, "totalColumns": _reservation.size.x * _reservation.size.y,
		"rejectedCell": _rejected_cell,
		"minimumSurfaceY": _minimum_y if is_finite(_minimum_y) else null,
		"maximumSurfaceY": _maximum_y if is_finite(_maximum_y) else null,
		"biomeCounts": _biomes.duplicate(),
		"slices": _slices, "maxSliceUsec": _max_slice_usec,
		"maxColumnUsec": _max_column_usec, "sliceOverruns": _slice_overruns,
		"preparationUsec": _preparation_usec, "workUsec": _work_usec,
		"lastBudgetUsec": _last_budget_usec,
		"sliceTimingScope": "scan_loop_excludes_snapshot_return",
		"surfacePolicyEligible": _status == "surveyed",
		"elevationStatisticsComplete": _status == "surveyed",
		"publicationReady": false,
	}


func _valid_town_overrides(overrides: Dictionary) -> bool:
	if overrides.size() > MAX_TOWN_OVERRIDES:
		return false
	for key in overrides:
		if not key is Vector2i or not overrides[key] is Dictionary:
			return false
		var town: Dictionary = overrides[key]
		if town.is_empty():
			continue
		for name in ["centerX", "centerZ", "radius"]:
			if typeof(town.get(name)) != TYPE_INT:
				return false
		if typeof(town.get("level")) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(town.level)):
			return false
		if town.has("regionX") and (typeof(town.regionX) != TYPE_INT or town.regionX != key.x):
			return false
		if town.has("regionZ") and (typeof(town.regionZ) != TYPE_INT or town.regionZ != key.y):
			return false
		# WGS searches +/-1 town region. Bound overrides to that actual contract:
		# radius + maximum production apron (128) must fit one town region.
		if town.centerX != key.x * Context.TOWN_REGION_CELLS or town.centerZ != key.y * Context.TOWN_REGION_CELLS or town.radius <= 0 or town.radius > Context.TOWN_REGION_CELLS - 128:
			return false
	return true


func _supported_coordinates(reservation: Rect2i) -> bool:
	return absi(reservation.position.x) <= MAX_ABS_SURVEY_CELL and absi(reservation.position.y) <= MAX_ABS_SURVEY_CELL and absi(int(reservation.position.x) + int(reservation.size.x)) <= MAX_ABS_SURVEY_CELL and absi(int(reservation.position.y) + int(reservation.size.y)) <= MAX_ABS_SURVEY_CELL


func _digest(value: Variant) -> String:
	var hash_context := HashingContext.new()
	hash_context.start(HashingContext.HASH_SHA256)
	hash_context.update(var_to_bytes(value))
	return hash_context.finish().hex_encode()


func _inspect_column(cell: Vector2i) -> void:
	var source_cell := Vector3i(cell.x, 0, cell.y)
	# Includes existing town terrain aprons, not merely town centers/homes.
	if not _world.town_region_for_surface_cell3(source_cell).is_empty():
		_reject("town_reservation_overlap", cell)
		return
	var biome: String = _world.surface_biome_for_cell3(source_cell)
	if not Field.allows_surface_biome(biome):
		_reject("excluded_biome:" + biome, cell)
		return
	var surface_y: float = _world.base_surface_y_for_cell(source_cell)
	if not is_finite(surface_y):
		_reject("invalid_surface_height", cell)
		return
	_biomes[biome] = int(_biomes.get(biome, 0)) + 1
	_minimum_y = minf(_minimum_y, surface_y)
	_maximum_y = maxf(_maximum_y, surface_y)


func _reject(reason: String, cell := Vector2i.ZERO) -> void:
	_status = "rejected"
	_reason = reason
	_rejected_cell = cell

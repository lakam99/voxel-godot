extends RefCounted
class_name ActiveStructureTreeHaloSnapshot

## Capture-only union of post-draw natural-tree exclusion halos. The native
## definition owner must recheck every ordinal, cell and margin before using
## this value for presence. StructureSystem remains the exclusion authority.
const SCHEMA_VERSION := 1
const MAX_TREES := 28
const MAX_MARGIN_CELLS := 4096

static func capture(structures: Object, requests: Array) -> Dictionary:
	if structures == null or not is_instance_valid(structures) \
			or not structures.has_method("capture_surface_tree_exclusion_halo") \
			or not structures.has_method("surface_tree_exclusion_halo_is_current"):
		return _failed("structure_owner_missing")
	var normalized := _requests(requests)
	if not bool(normalized.get("ok", false)):
		return _failed(String(normalized.get("reason", "requests_invalid")))
	var owner_id := structures.get_instance_id()
	var admission: Variant = structures.get("citadel_terrain_admission")
	if not admission is Object or not is_instance_valid(admission) or not admission.has_method("stats"):
		return _failed("citadel_admission_missing")
	var admission_state: Variant = admission.stats()
	if not admission_state is Dictionary or not admission_state.get("worldSeed") is String \
			or String(admission_state.worldSeed).is_empty() \
			or not admission_state.get("generation") is int or int(admission_state.generation) <= 0:
		return _failed("citadel_admission_identity_invalid")
	var bounds: Rect2i = normalized.bounds
	var center := Vector2i(int(floori(float(bounds.position.x + bounds.end.x - 1) * 0.5)),
		int(floori(float(bounds.position.y + bounds.end.y - 1) * 0.5)))
	var radius := maxi(maxi(center.x - bounds.position.x, bounds.end.x - 1 - center.x),
		maxi(center.y - bounds.position.y, bounds.end.y - 1 - center.y))
	if radius > MAX_MARGIN_CELLS:
		return _failed("union_halo_too_wide")
	var halo: Variant = structures.capture_surface_tree_exclusion_halo(center.x, center.y, radius, radius)
	if not halo is Dictionary or not bool(halo.get("ready", false)) \
			or not structures.surface_tree_exclusion_halo_is_current(halo) \
			or not halo.get("cell") is Vector2i or halo.cell != center \
			or halo.get("naturalMarginCells") != radius \
			or halo.get("structureMarginCells") != radius:
		return _failed("halo_not_ready_or_changed")
	# StructureSystem's canonical coverage is the center cell grown by radius;
	# request_bounds may return a different diagnostic shape.
	var coverage := Rect2i(center, Vector2i.ONE).grow(radius)
	if bounds.position.x < coverage.position.x or bounds.position.y < coverage.position.y \
			or bounds.end.x > coverage.end.x or bounds.end.y > coverage.end.y:
		return _failed("union_coverage_incomplete")
	if not is_instance_valid(structures) or structures.get_instance_id() != owner_id \
			or structures.get("citadel_terrain_admission") != admission \
			or admission.stats().get("worldSeed") != admission_state.worldSeed \
			or admission.stats().get("generation") != admission_state.generation:
		return _failed("source_changed_during_capture")
	var rows: Array = normalized.rows
	var identity := Marshalls.raw_to_base64(var_to_bytes([
		rows, coverage, admission_state.worldSeed, admission_state.generation,
		halo.get("contentDigest", "")])).sha256_text()
	return {"ok":true, "schemaVersion":SCHEMA_VERSION,
		"scope":"admitted_surface_tree_halo_union_only", "ownerInstanceId":owner_id,
		"admissionSeed":admission_state.worldSeed,
		"admissionGeneration":admission_state.generation,
		"requests":rows.duplicate(true), "coverage":coverage,
		"halo":halo.duplicate(true), "contentIdentity":identity}

static func is_current(structures: Object, snapshot: Dictionary) -> bool:
	if not bool(snapshot.get("ok", false)) or snapshot.get("schemaVersion") != SCHEMA_VERSION \
			or snapshot.get("scope") != "admitted_surface_tree_halo_union_only" \
			or not snapshot.get("requests") is Array:
		return false
	var fresh := capture(structures, snapshot.requests)
	return bool(fresh.get("ok", false)) and fresh == snapshot

static func _requests(requests: Array) -> Dictionary:
	if requests.is_empty() or requests.size() > MAX_TREES:
		return _failed("request_count_invalid")
	var rows := []
	var previous_ordinal := -1
	var low_x := 2147483647
	var low_z := 2147483647
	var high_x := -2147483648
	var high_z := -2147483648
	for value in requests:
		if not value is Dictionary:
			return _failed("request_not_dictionary")
		var row: Dictionary = value
		if row.size() != 4 or not row.has_all(["ordinal", "cell", "naturalMarginCells", "structureMarginCells"]) \
				or not row.ordinal is int or not row.cell is Vector2i \
				or not row.naturalMarginCells is int or not row.structureMarginCells is int:
			return _failed("request_fields_invalid")
		var ordinal: int = row.ordinal
		var cell: Vector2i = row.cell
		var natural: int = row.naturalMarginCells
		var structure: int = row.structureMarginCells
		if ordinal <= previous_ordinal or ordinal >= MAX_TREES \
				or cell.x < -1000000 or cell.x > 1000000 or cell.y < -1000000 or cell.y > 1000000 \
				or natural < 0 or natural > MAX_MARGIN_CELLS \
				or structure < 0 or structure > MAX_MARGIN_CELLS:
			return _failed("request_domain_invalid")
		previous_ordinal = ordinal
		var widest := maxi(natural, structure)
		low_x = mini(low_x, cell.x - widest)
		low_z = mini(low_z, cell.y - widest)
		high_x = maxi(high_x, cell.x + widest)
		high_z = maxi(high_z, cell.y + widest)
		rows.append({"ordinal":ordinal, "cell":cell,
			"naturalMarginCells":natural, "structureMarginCells":structure})
	return {"ok":true, "rows":rows,
		"bounds":Rect2i(Vector2i(low_x, low_z), Vector2i(high_x - low_x + 1, high_z - low_z + 1))}

static func _failed(reason: String) -> Dictionary:
	return {"ok":false, "reason":reason}

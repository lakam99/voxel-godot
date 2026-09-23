extends RefCounted
class_name ActiveStructureExclusionChunkSnapshot

## Chunk-scoped, capture-only source value for N4 native prop admission.
## StructureSystem and CitadelTerrainAdmission remain the live authorities.
const CitadelSiteFieldScript := preload("res://scripts/world/CitadelSiteField.gd")
const SCHEMA_VERSION := 1
const CHUNK_CELLS := 28
const MAX_RECORDS := 65536
const MAX_TEXT_BYTES := 1024

static func capture(structures: Object, chunk: Vector2i) -> Dictionary:
	if structures == null or not is_instance_valid(structures):
		return _failed("structure_owner_missing")
	var owner_id := structures.get_instance_id()
	var generation: Variant = structures.get("regional_source_generation")
	var revision: Variant = structures.get("surface_prop_exclusion_revision")
	var admission: Variant = structures.get("citadel_terrain_admission")
	if not generation is int or generation <= 0 or not revision is int or revision < 0 \
			or not admission is Object or not is_instance_valid(admission) \
			or not admission.has_method("request_bounds") or not admission.has_method("source_state") \
			or not admission.has_method("stats"):
		return _failed("source_owner_not_ready")
	var admission_state: Variant = admission.stats()
	if not admission_state is Dictionary or not admission_state.get("worldSeed") is String \
			or String(admission_state.worldSeed).is_empty() \
			or not admission_state.get("generation") is int \
			or int(admission_state.generation) <= 0:
		return _failed("admission_identity_invalid")
	var start_x := int(chunk.x) * CHUNK_CELLS
	var start_z := int(chunk.y) * CHUNK_CELLS
	if start_x < -1000000 or start_z < -1000000 \
			or start_x + CHUNK_CELLS > 1000000 or start_z + CHUNK_CELLS > 1000000:
		return _failed("chunk_out_of_admission_bounds")
	var bounds := Rect2i(Vector2i(start_x, start_z), Vector2i.ONE * CHUNK_CELLS)
	var bounds_admission: Variant = admission.request_bounds(bounds)
	if not bounds_admission is Dictionary or bounds_admission.get("status") != "ready":
		return _failed("bounds_not_ready")
	var natural := _capture_rect_records(structures.get("natural_prop_exclusion_records"), bounds, false)
	var terrain := _capture_rect_records(structures.get("terrain_footprint_records"), bounds, true)
	if not bool(natural.get("ok", false)) or not bool(terrain.get("ok", false)):
		return _failed("exclusion_records_invalid")
	var low_region := CitadelSiteFieldScript.region_for_cell(bounds.position)
	var high_region := CitadelSiteFieldScript.region_for_cell(bounds.end - Vector2i.ONE)
	var citadels := []
	for region_z in range(low_region.y, high_region.y + 1):
		for region_x in range(low_region.x, high_region.x + 1):
			var region := Vector2i(region_x, region_z)
			var source: Variant = admission.source_state(region)
			var row := _capture_citadel(region, source)
			if not bool(row.get("ok", false)):
				return _failed("citadel_source_invalid")
			citadels.append(row.value)
	if not is_instance_valid(structures) or structures.get_instance_id() != owner_id \
			or structures.get("regional_source_generation") != generation \
			or structures.get("surface_prop_exclusion_revision") != revision \
			or structures.get("citadel_terrain_admission") != admission \
			or admission.stats().get("worldSeed") != admission_state.worldSeed \
			or admission.stats().get("generation") != admission_state.generation:
		return _failed("source_changed_during_capture")
	var content := {"natural":natural.rows, "terrain":terrain.rows, "citadel":citadels}
	var identity := Marshalls.raw_to_base64(var_to_bytes([chunk, bounds, content])).sha256_text()
	return {"ok":true, "schemaVersion":SCHEMA_VERSION,
		"scope":"admitted_structure_exclusion_chunk_only", "ownerInstanceId":owner_id,
		"ownerGeneration":generation, "exclusionRevision":revision,
		"admissionSeed":admission_state.worldSeed,
		"admissionGeneration":admission_state.generation,
		"chunk":chunk, "bounds":bounds, "boundsAdmission":bounds_admission.duplicate(true),
		"content":content.duplicate(true), "contentIdentity":identity}

static func is_current(structures: Object, snapshot: Dictionary) -> bool:
	if not bool(snapshot.get("ok", false)) or snapshot.get("schemaVersion") != SCHEMA_VERSION \
			or snapshot.get("scope") != "admitted_structure_exclusion_chunk_only" \
			or not snapshot.get("chunk") is Vector2i or not snapshot.get("content") is Dictionary:
		return false
	var fresh := capture(structures, snapshot.chunk)
	return bool(fresh.get("ok", false)) and snapshot == fresh

static func _capture_rect_records(source: Variant, bounds: Rect2i, terrain: bool) -> Dictionary:
	if not source is Dictionary or source.size() > MAX_RECORDS:
		return _failed("record_store_invalid")
	var rows := []
	for key in source:
		var value: Variant = source[key]
		if not key is String or not value is Dictionary:
			return _failed("record_invalid")
		var row: Dictionary = value
		var id: Variant = row.get("id")
		if not id is String or id.is_empty() or id.to_utf8_buffer().size() > MAX_TEXT_BYTES or key != id:
			return _failed("record_id_invalid")
		var min_x: int
		var min_z: int
		var max_x: int
		var max_z: int
		if terrain:
			if not row.get("minCell") is Vector3i or not row.get("maxCell") is Vector3i:
				return _failed("terrain_record_cells_invalid")
			var low: Vector3i = row.minCell
			var high: Vector3i = row.maxCell
			min_x = low.x; min_z = low.z; max_x = high.x; max_z = high.z
		else:
			if not row.get("minX") is int or not row.get("minZ") is int \
					or not row.get("maxX") is int or not row.get("maxZ") is int:
				return _failed("natural_record_cells_invalid")
			min_x = row.minX; min_z = row.minZ; max_x = row.maxX; max_z = row.maxZ
		if min_x > max_x or min_z > max_z:
			return _failed("record_bounds_reversed")
		if max_x < bounds.position.x or min_x >= bounds.end.x \
				or max_z < bounds.position.y or min_z >= bounds.end.y:
			continue
		rows.append({"id":id, "minX":min_x, "minZ":min_z, "maxX":max_x, "maxZ":max_z})
	rows.sort_custom(func(a, b): return a.id < b.id)
	return {"ok":true, "rows":rows}

static func _capture_citadel(region: Vector2i, source: Variant) -> Dictionary:
	if not source is Dictionary:
		return _failed("source_not_dictionary")
	var status: Variant = source.get("status")
	if not status is String or status not in ["ready", "prepared", "absent", "failed"]:
		return _failed("source_status_not_admitted")
	var reason: Variant = source.get("reason", "")
	if not reason is String or reason.to_utf8_buffer().size() > MAX_TEXT_BYTES:
		return _failed("source_reason_invalid")
	var source_key: Variant = source.get("sourceKey", "")
	var signature: Variant = source.get("sourceSignature", "")
	var generation := 0
	var reservation := Rect2i()
	if status in ["ready", "prepared"]:
		var binding: Variant = source.get("binding")
		if not binding is Dictionary or not binding.get("siteId") is String \
				or String(binding.siteId).is_empty() or not binding.get("sourceKey") is String \
				or String(binding.sourceKey).is_empty() or not binding.get("generation") is int \
				or int(binding.generation) <= 0 or not source.get("reservationCells") is Rect2i \
				or not signature is String or signature.is_empty():
			return _failed("physical_source_invalid")
		source_key = binding.sourceKey
		generation = int(binding.generation)
		reservation = source.reservationCells
		if reservation.size.x <= 0 or reservation.size.y <= 0:
			return _failed("physical_reservation_invalid")
	else:
		if not source_key is String or not signature is String or not signature.is_empty():
			return _failed("nonphysical_source_invalid")
	if not source_key is String or source_key.to_utf8_buffer().size() > MAX_TEXT_BYTES \
			or not signature is String or signature.to_utf8_buffer().size() > MAX_TEXT_BYTES:
		return _failed("source_text_invalid")
	return {"ok":true, "value":{"region":region, "status":status, "reason":reason,
		"sourceKey":source_key, "sourceSignature":signature,
		"admissionGeneration":generation, "reservationCells":reservation}}

static func _failed(reason: String) -> Dictionary:
	return {"ok":false, "reason":reason}

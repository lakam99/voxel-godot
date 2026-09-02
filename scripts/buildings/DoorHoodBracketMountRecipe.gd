extends RefCounted

## Unwired placement candidate. Derive mounting from an actual solid doorway
## pier, never the decorative lintel or a nearby building. Does not mutate input
## or certify rootedness: the ordinary physical validator remains authoritative.
const Part = preload("res://scripts/buildings/BuildingPart.gd")

static func prepare(blueprint, bracket, door, hood, facade_parts: Array) -> Dictionary:
	if blueprint == null or bracket == null or door == null or hood == null or facade_parts.is_empty() or facade_parts.size() > 512:
		return {"ready": false, "reason": "missing_or_unbounded_source"}
	for part in [bracket, door, hood]:
		if not part is Part or not blueprint.has_finite_positive_bounds(part):
			return {"ready": false, "reason": "invalid_source_bounds"}
	if door.semantic != "citadel_urban_door" or not door.id.ends_with("_door"):
		return {"ready": false, "reason": "invalid_door_declaration"}
	var prefix: String = door.id.trim_suffix("_door")
	if prefix.is_empty() or not bracket.id.begins_with(prefix + "_door_bracket_") or hood.id != prefix + "_door_hood" or bracket.kind != "beam" or bracket.semantic != "citadel_urban_door_joinery" or hood.semantic != "citadel_urban_door_hood":
		return {"ready": false, "reason": "foreign_source_membership"}
	if bracket.collision_enabled or bracket.rotation.x != 0.0 or bracket.rotation.y != 0.0 or door.rotation != Vector3.ZERO:
		return {"ready": false, "reason": "unsupported_orientation_or_collision"}
	var basis := Basis.from_euler(bracket.rotation)
	var side := signf(-bracket.rotation.z)
	var along := signf(bracket.position.z - door.position.z)
	if side == 0.0 or along == 0.0:
		return {"ready": false, "reason": "ambiguous_frontage"}
	var facade = null
	for panel in facade_parts:
		if not panel is Part or not blueprint.has_finite_positive_bounds(panel) or panel.rotation != Vector3.ZERO or not panel.collision_enabled or panel.semantic != "citadel_urban_facade" or not panel.id.begins_with(prefix + "_"):
			return {"ready": false, "reason": "invalid_facade_source"}
		if facade != null and (panel.position.x != facade.position.x or panel.size.x != facade.size.x):
			return {"ready": false, "reason": "inconsistent_facade_plane"}
		facade = panel
	# Resolve the final height before selecting its actual mounting pier.
	# This producer's hood slopes in X only, so lateral pier selection cannot
	# change the underside plane evaluated at the bracket's front endpoint.
	var half_x: float = absf(basis.x.x) * bracket.size.x * 0.5 + absf(basis.y.x) * bracket.size.y * 0.5
	var record: Dictionary = bracket.snapshot()
	record.position.x = facade.position.x + side * (facade.size.x * 0.5 + half_x - bracket.size.x)
	var hood_basis := Basis.from_euler(hood.rotation)
	if hood.rotation.x != 0.0 or hood.rotation.y != 0.0 or hood_basis.y.y <= 0.5: return {"ready": false, "reason": "unsupported_hood_slope"}
	var underside: Vector3 = hood.position - hood_basis.y * hood.size.y * 0.5
	var end_point: Vector3 = record.position + basis.y * bracket.size.y * 0.5
	var joint_depth: float = minf(bracket.size.x, hood.size.y) * 0.25
	record.position.y += (joint_depth - (end_point - underside).dot(hood_basis.y)) / hood_basis.y.y
	var rear: Vector3 = record.position - basis.y * bracket.size.y * 0.5
	var selected = null
	var distance := INF
	var nearest_count := 0
	for panel in facade_parts:
		var bounds := AABB(panel.position - panel.size * 0.5, panel.size)
		if rear.y <= bounds.position.y or rear.y >= bounds.end.y: continue
		var inner_edge: float = bounds.position.z if along > 0.0 else bounds.end.z
		var separation: float = along * (inner_edge - door.position.z)
		if separation < door.size.z * 0.5: continue
		if separation < distance:
			distance = separation
			selected = panel
			nearest_count = 1
		elif separation == distance:
			nearest_count += 1
	if selected == null: return {"ready": false, "reason": "no_solid_door_side_pier"}
	if nearest_count != 1: return {"ready": false, "reason": "ambiguous_pier"}
	# Embed one section width at the rear; keep the full brace outside the
	# actual opening's lateral edge. Seat the front end into the real hood
	# underside by a quarter of the thinner joint member, rather than leaving
	# its height tied to an unrelated presentation datum.
	record.position.z = door.position.z + along * (distance + bracket.size.z * 0.5)
	var candidate = Part.new(record)
	if not blueprint.transformed_parts_overlap(candidate, selected, 0.0):
		return {"ready": false, "reason": "missing_exact_pier_contact"}
	if not blueprint.transformed_parts_overlap(candidate, hood, 0.0):
		return {"ready": false, "reason": "missing_exact_hood_contact"}
	return {"ready": true, "part": record, "pierId": selected.id,
		"openingEdgeDistance": distance, "exactPierContact": true, "exactHoodContact": true,
		"scope": "Nominal source volumes only; not published joints, rooted support, doorway clearance or visual acceptance."}

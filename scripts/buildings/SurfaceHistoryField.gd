extends RefCounted
class_name SurfaceHistoryField

## Deterministic construction history. It derives weathering from the same
## recipe parts that create roofs, openings, paths and trees; it never creates
## a decorative overlay authority to conceal a clean generated surface.

var route_corridors: Array = []
var tree_placements: Array = []
var history_events: Array[Dictionary] = []
var history_event_cells: Dictionary = {}

const HISTORY_CELL_SIZE := 8.0


func configure(recipe: Dictionary, parts: Array = []) -> void:
	route_corridors = recipe.get("routeCorridors", recipe.get("pavingTreatments", [])) as Array
	tree_placements.clear()
	history_events.clear()
	history_event_cells.clear()
	var tree_records: Array = recipe.get("landscapeTrees", []) as Array
	if tree_records.is_empty():
		var urban_poc: Dictionary = recipe.get("urbanPoc", {}) as Dictionary
		tree_records = urban_poc.get("treePlacements", []) as Array
	for placement_value in tree_records:
		var placement: Dictionary = {}
		if placement_value is Dictionary:
			placement = (placement_value as Dictionary).duplicate(true)
		elif placement_value is Vector3:
			placement = {"position": placement_value as Vector3, "canopyRadius": 4.40}
		if placement.is_empty():
			continue
		tree_placements.append(placement)
		register_tree_history(placement)
	for part in parts:
		if part == null:
			continue
		var kind := String(part.kind)
		var semantic := String(part.semantic)
		if kind == "window":
			register_opening_runoff(part, "window_runoff")
		elif kind == "door":
			register_threshold_wear(part)
		# Roof courses are finish pieces, not drainage authorities. Only an actual
		# recipe eave/edge may emit a long runoff strip; otherwise a tiled roof
		# would duplicate the same physical footprint hundreds of times.
		if semantic.contains("eave") or bool(part.recipe.get("weatheringEave", false)):
			register_eave_runoff(part)


func history_for(part, world_position: Vector3, normalized_height: float, stable: float) -> float:
	var semantic := String(part.semantic)
	var material := String(part.material_id)
	var conditions := conditions_at(world_position)
	var route_use := float(wear_contact_at(world_position).get("influence", 0.0))
	var near_ground := 1.0 - clampf(normalized_height, 0.0, 1.0)
	var threshold := 1.0 if semantic.contains("threshold") or semantic.contains("entry") or semantic.contains("door") else 0.0
	var roof_shelter := 1.0 if semantic.contains("eave") or semantic.contains("roof") else 0.0
	var repair := 1.0 if semantic.contains("repair") or material.contains("limewash") else 0.0
	if material in ["cobblestone", "worn_cobble"] or semantic.contains("paving") or semantic.contains("lane"):
		return clampf(route_use * 0.76 + float(conditions.get("rootDisturbance", 0.0)) * 0.20 + stable * 0.04, 0.0, 1.0)
	var runoff := float(conditions.get("runoff", 0.0))
	var dampness := near_ground * 0.28 + threshold * 0.10 + runoff * 0.50
	var sheltered_age := roof_shelter * 0.16 + stable * 0.06
	return clampf(dampness + sheltered_age - repair * 0.20, 0.0, 1.0)


func conditions_at(world_position: Vector3) -> Dictionary:
	var result := {"runoff": 0.0, "thresholdWear": 0.0, "rootDisturbance": 0.0, "canopyDeposit": 0.0}
	var events: Array = history_event_cells.get(history_cell_for(world_position), []) as Array
	for event_value in events:
		var event: Dictionary = event_value as Dictionary
		var influence := event_influence(event, world_position)
		if influence <= 0.001:
			continue
		match String(event.get("kind", "")):
			"window_runoff", "eave_runoff": result["runoff"] = maxf(float(result.get("runoff", 0.0)), influence)
			"threshold_wear": result["thresholdWear"] = maxf(float(result.get("thresholdWear", 0.0)), influence)
			"root_buttress": result["rootDisturbance"] = maxf(float(result.get("rootDisturbance", 0.0)), influence)
			"canopy_deposition": result["canopyDeposit"] = maxf(float(result.get("canopyDeposit", 0.0)), influence)
	return result


func root_buttress_contact(world_position: Vector3, half_extent: Vector2) -> Dictionary:
	var strongest := {"influence": 0.0, "direction": Vector3.ZERO, "lateral": 0.0, "progress": 0.0}
	var cell := history_cell_for(world_position)
	var visited := {}
	for offset_x in range(-1, 2):
		for offset_z in range(-1, 2):
			var events: Array = history_event_cells.get(cell + Vector2i(offset_x, offset_z), []) as Array
			for event_value in events:
				if not event_value is Dictionary:
					continue
				var event: Dictionary = event_value as Dictionary
				if String(event.get("kind", "")) != "root_buttress":
					continue
				var source_id := "%s:%s" % [String(event.get("sourceId", "")), str(event.get("position", Vector3.ZERO))]
				if visited.has(source_id):
					continue
				visited[source_id] = true
				var contact := root_buttress_rect_contact(event, world_position, half_extent)
				if float(contact.get("influence", 0.0)) > float(strongest.get("influence", 0.0)):
					strongest = contact
	return strongest


func root_buttress_rect_contact(event: Dictionary, world_position: Vector3, half_extent: Vector2) -> Dictionary:
	var start: Vector3 = event.get("position", Vector3.ZERO) as Vector3
	var end: Vector3 = event.get("end", start) as Vector3
	var segment_start := Vector2(start.x - world_position.x, start.z - world_position.z)
	var segment_end := Vector2(end.x - world_position.x, end.z - world_position.z)
	var segment := segment_end - segment_start
	var segment_length_squared := segment.length_squared()
	if segment_length_squared <= 0.0001:
		return {"influence": 0.0}
	var radius_start := maxf(0.08, float(event.get("radiusStart", 0.16)))
	var radius_end := maxf(0.06, float(event.get("radiusEnd", 0.10)))
	var maximum_radius := maxf(radius_start, radius_end)
	var expanded_half := half_extent + Vector2.ONE * (maximum_radius * 1.28 + 0.05)
	if not segment_intersects_rect(segment_start, segment_end, expanded_half):
		return {"influence": 0.0}
	var progress := clampf((-segment_start).dot(segment) / segment_length_squared, 0.0, 1.0)
	var nearest := segment_start + segment * progress
	var radius := lerpf(radius_start, radius_end, progress)
	var distance := point_rect_distance(nearest, half_extent)
	var influence := 1.0 - smoothstep(radius * 0.50, radius * 1.28 + 0.05, distance)
	if influence <= 0.001:
		return {"influence": 0.0}
	var direction := Vector3(segment.x, 0.0, segment.y).normalized()
	var normal := Vector2(-segment.y, segment.x).normalized()
	var lateral := Vector2(-nearest.x, -nearest.y).dot(normal)
	return {"influence": influence, "direction": direction, "lateral": lateral, "progress": progress}


func segment_intersects_rect(start: Vector2, end: Vector2, half_extent: Vector2) -> bool:
	var delta := end - start
	var lower := Vector2(-half_extent.x, -half_extent.y)
	var upper := half_extent
	var enter := 0.0
	var exit := 1.0
	for axis in range(2):
		var origin := start[axis]
		var direction := delta[axis]
		if absf(direction) <= 0.00001:
			if origin < lower[axis] or origin > upper[axis]:
				return false
			continue
		var inverse := 1.0 / direction
		var first := (lower[axis] - origin) * inverse
		var second := (upper[axis] - origin) * inverse
		if first > second:
			var swap := first
			first = second
			second = swap
		enter = maxf(enter, first)
		exit = minf(exit, second)
		if enter > exit:
			return false
	return true


func point_rect_distance(point: Vector2, half_extent: Vector2) -> float:
	var dx := maxf(absf(point.x) - half_extent.x, 0.0)
	var dz := maxf(absf(point.y) - half_extent.y, 0.0)
	return Vector2(dx, dz).length()


func event_influence(event: Dictionary, world_position: Vector3) -> float:
	var kind := String(event.get("kind", ""))
	var center: Vector3 = event.get("position", Vector3.ZERO) as Vector3
	var horizontal := Vector2(world_position.x - center.x, world_position.z - center.z)
	match kind:
		"window_runoff", "eave_runoff":
			if world_position.y > center.y + 0.10:
				return 0.0
			var axis := horizontal_axis(event.get("axis", Vector3.RIGHT) as Vector3)
			var along := absf(horizontal.dot(axis))
			var across := absf(horizontal.dot(Vector2(-axis.y, axis.x)))
			var half_length := maxf(0.16, float(event.get("halfLength", event.get("span", 0.50) * 0.50)))
			var half_width := maxf(0.12, float(event.get("halfWidth", 0.30)))
			var drop := clampf((center.y - world_position.y) / maxf(0.50, float(event.get("drop", 3.0))), 0.0, 1.0)
			var strip := (1.0 - smoothstep(half_length * 0.82, half_length + 0.16, along)) * (1.0 - smoothstep(half_width * 0.58, half_width + 0.18, across))
			return strip * smoothstep(0.03, 0.38, drop) * (1.0 - drop * 0.30)
		"threshold_wear":
			var direction: Vector3 = event.get("direction", Vector3.FORWARD) as Vector3
			var axis := Vector2(direction.x, direction.z).normalized()
			if axis.length_squared() <= 0.001:
				axis = Vector2.UP
			var along := absf(horizontal.dot(axis))
			var across := absf(horizontal.dot(Vector2(-axis.y, axis.x)))
			var length := maxf(0.80, float(event.get("length", 2.0)))
			var half_width := maxf(0.34, float(event.get("width", 0.80)) * 0.5)
			return (1.0 - smoothstep(length * 0.54, length + 0.42, along)) * (1.0 - smoothstep(half_width * 0.60, half_width + 0.30, across))
		"root_buttress":
			var end: Vector3 = event.get("end", center) as Vector3
			var segment := Vector2(end.x - center.x, end.z - center.z)
			var length_squared := segment.length_squared()
			if length_squared <= 0.0001:
				return 0.0
			var progress := clampf(horizontal.dot(segment) / length_squared, 0.0, 1.0)
			var nearest := segment * progress
			var radius_start := maxf(0.08, float(event.get("radiusStart", 0.16)))
			var radius_end := maxf(0.06, float(event.get("radiusEnd", 0.10)))
			var radius := lerpf(radius_start, radius_end, progress)
			var distance := (horizontal - nearest).length()
			return (1.0 - smoothstep(radius * 0.46, radius * 1.70 + 0.14, distance)) * lerpf(1.0, 0.42, progress)
		"canopy_deposition":
			var radius := maxf(0.60, float(event.get("radius", 2.4)))
			var normalized_distance := horizontal.length() / radius
			return 1.0 - smoothstep(0.26, 1.0, normalized_distance)
	return 0.0


func horizontal_axis(direction: Vector3) -> Vector2:
	var axis := Vector2(direction.x, direction.z).normalized()
	return axis if axis.length_squared() > 0.001 else Vector2.RIGHT


func route_use_at(world_position: Vector3) -> float:
	return float(route_contact_at(world_position).get("influence", 0.0))


func route_contact_at(world_position: Vector3) -> Dictionary:
	var strongest := {"influence": 0.0, "lateral": 1.0}
	for treatment_value in route_corridors:
		if not treatment_value is Dictionary:
			continue
		var treatment: Dictionary = treatment_value as Dictionary
		var center: Vector3 = treatment.get("center", Vector3.ZERO) as Vector3
		var span: Vector2 = treatment.get("span", Vector2.ZERO) as Vector2
		var heading := float(treatment.get("heading", 0.0))
		var axis := Vector2(cos(heading), sin(heading))
		if axis.length_squared() <= 0.0001:
			axis = Vector2(0.0, 1.0)
		var local := Vector2(world_position.x - center.x, world_position.z - center.z)
		var along := absf(local.dot(axis.normalized()))
		var across := absf(local.dot(Vector2(-axis.y, axis.x).normalized()))
		var length := maxf(0.50, span.x * 0.5)
		var half_width := maxf(0.30, span.y * 0.5)
		if along > length + 1.40:
			continue
		var width_falloff := 1.0 - smoothstep(half_width * 0.62, half_width + 0.42, across)
		var end_falloff := 1.0 - smoothstep(length * 0.86, length + 0.58, along)
		var influence := clampf(width_falloff * end_falloff, 0.0, 1.0)
		if influence > float(strongest.get("influence", 0.0)):
			strongest = {
				"influence": influence,
				"lateral": clampf(across / half_width, 0.0, 1.0)
			}
	return strongest


func threshold_wear_contact_at(world_position: Vector3) -> Dictionary:
	var strongest := {"influence": 0.0, "lateral": 1.0}
	var events: Array = history_event_cells.get(history_cell_for(world_position), []) as Array
	for event_value in events:
		if not event_value is Dictionary:
			continue
		var event: Dictionary = event_value as Dictionary
		if String(event.get("kind", "")) != "threshold_wear":
			continue
		var center: Vector3 = event.get("position", Vector3.ZERO) as Vector3
		var direction: Vector3 = event.get("direction", Vector3.FORWARD) as Vector3
		var axis := Vector2(direction.x, direction.z).normalized()
		if axis.length_squared() <= 0.001:
			axis = Vector2.UP
		var local := Vector2(world_position.x - center.x, world_position.z - center.z)
		var along := absf(local.dot(axis))
		var across := absf(local.dot(Vector2(-axis.y, axis.x)))
		var length := maxf(0.80, float(event.get("length", 2.0)))
		var half_width := maxf(0.34, float(event.get("width", 0.80)) * 0.5)
		var influence := (1.0 - smoothstep(length * 0.54, length + 0.42, along)) * (1.0 - smoothstep(half_width * 0.60, half_width + 0.30, across))
		if influence > float(strongest.get("influence", 0.0)):
			strongest = {
				"influence": clampf(influence, 0.0, 1.0),
				"lateral": clampf(across / half_width, 0.0, 1.0)
			}
	return strongest


func wear_contact_at(world_position: Vector3) -> Dictionary:
	var route_contact := route_contact_at(world_position)
	var threshold_contact := threshold_wear_contact_at(world_position)
	return threshold_contact if float(threshold_contact.get("influence", 0.0)) > float(route_contact.get("influence", 0.0)) else route_contact


func register_opening_runoff(part, kind: String) -> void:
	var long_axis := horizontal_long_axis(part)
	var span: float = part.size.x if absf(long_axis.x) > absf(long_axis.z) else part.size.z
	register_history_event({
		"kind": kind,
		"position": part.position + Vector3(0.0, -part.size.y * 0.30, 0.0),
		"axis": long_axis,
		"halfLength": maxf(0.17, span * 0.34),
		"halfWidth": 0.32,
		"drop": maxf(1.20, part.size.y * 2.4),
		"sourceId": String(part.id)
	})


func register_eave_runoff(part) -> void:
	var half_x := maxf(0.30, part.size.x * 0.5)
	var half_z := maxf(0.30, part.size.z * 0.5)
	var axis := horizontal_long_axis(part)
	var perpendicular := Vector3(-axis.z, 0.0, axis.x)
	var half_span := maxf(part.size.x, part.size.z) * 0.5
	var edge_offset := perpendicular * (half_z if absf(axis.x) > absf(axis.z) else half_x)
	for sign in [-1.0, 1.0]:
		register_history_event({
			"kind": "eave_runoff",
			"position": part.position + edge_offset * sign,
			"axis": axis,
			"halfLength": maxf(0.32, half_span),
			"halfWidth": 0.44,
			"drop": maxf(2.0, part.size.y * 4.0),
			"sourceId": String(part.id)
		})


func register_threshold_wear(part) -> void:
	var direction := Basis.from_euler(part.rotation) * Vector3.FORWARD
	direction.y = 0.0
	if direction.length_squared() <= 0.001:
		direction = Vector3.FORWARD
	direction = direction.normalized()
	var width := maxf(0.72, maxf(part.size.x, part.size.z) * 0.88)
	for sign in [-1.0, 1.0]:
		register_history_event({"kind": "threshold_wear", "position": part.position + direction * sign * 0.40, "direction": direction, "length": maxf(1.45, width * 1.42), "width": width, "sourceId": String(part.id)})


func register_tree_history(placement: Dictionary) -> void:
	var canopy_radius := maxf(0.60, float(placement.get("canopyRadius", 2.40)))
	register_history_event({
		"kind": "canopy_deposition",
		"position": placement.get("position", Vector3.ZERO),
		"radius": canopy_radius,
		"sourceId": String(placement.get("id", "tree"))
	})
	for footprint_value in placement.get("rootButtressFootprints", []) as Array:
		if not footprint_value is Dictionary:
			continue
		var footprint: Dictionary = footprint_value as Dictionary
		register_history_event({
			"kind": "root_buttress",
			"position": footprint.get("start", Vector3.ZERO),
			"end": footprint.get("end", Vector3.ZERO),
			"radiusStart": maxf(0.08, float(footprint.get("radiusStart", 0.14))),
			"radiusEnd": maxf(0.06, float(footprint.get("radiusEnd", 0.08))),
			"sourceId": String(placement.get("id", "tree"))
		})


func horizontal_long_axis(part) -> Vector3:
	var local_axis := Vector3.RIGHT if part.size.x >= part.size.z else Vector3.FORWARD
	var world_axis := Basis.from_euler(part.rotation) * local_axis
	world_axis.y = 0.0
	return world_axis.normalized() if world_axis.length_squared() > 0.001 else local_axis


func register_history_event(event: Dictionary) -> void:
	history_events.append(event)
	var position: Vector3 = event.get("position", Vector3.ZERO) as Vector3
	var radius := history_event_radius(event)
	var min_cell := history_cell_for(position - Vector3(radius, 0.0, radius))
	var max_cell := history_cell_for(position + Vector3(radius, 0.0, radius))
	for cell_x in range(min_cell.x, max_cell.x + 1):
		for cell_z in range(min_cell.y, max_cell.y + 1):
			var cell := Vector2i(cell_x, cell_z)
			var events: Array = history_event_cells.get(cell, []) as Array
			events.append(event)
			history_event_cells[cell] = events


func history_event_radius(event: Dictionary) -> float:
	match String(event.get("kind", "")):
		"window_runoff", "eave_runoff": return maxf(0.80, float(event.get("halfLength", event.get("span", 0.50) * 0.50)) + float(event.get("halfWidth", 0.30)) + 0.35)
		"threshold_wear": return maxf(float(event.get("length", 2.0)) + 0.42, float(event.get("width", 0.80)) + 0.42)
		"root_buttress":
			var start: Vector3 = event.get("position", Vector3.ZERO) as Vector3
			var end: Vector3 = event.get("end", start) as Vector3
			return maxf(1.20, Vector2(end.x - start.x, end.z - start.z).length() + maxf(float(event.get("radiusStart", 0.12)), float(event.get("radiusEnd", 0.08))) * 1.8)
		"canopy_deposition": return maxf(0.60, float(event.get("radius", 2.4)))
	return 1.0


func summary() -> Dictionary:
	var event_counts := {}
	for event_value in history_events:
		if not (event_value is Dictionary):
			continue
		var kind := String((event_value as Dictionary).get("kind", "unknown"))
		event_counts[kind] = int(event_counts.get(kind, 0)) + 1
	return {
		"eventCount": history_events.size(),
		"eventCounts": event_counts,
		"routeCorridorCount": route_corridors.size(),
		"treePlacementCount": tree_placements.size()
	}


func history_cell_for(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / HISTORY_CELL_SIZE), floori(position.z / HISTORY_CELL_SIZE))


func stable_unit(value: String) -> float:
	return float(posmod(value.hash(), 4093)) / 4093.0

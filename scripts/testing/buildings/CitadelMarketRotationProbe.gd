extends "res://scripts/testing/buildings/CitadelMarketPlacementProbe.gd"

## Bounded source-only discovery: unchanged whole household, four orientations,
## nearby actual paving records. No producer integration or acceptance claim.
const SEARCH_RADIUS := 25.0

func _extra_checks(report: Dictionary, b, boxes: Dictionary, groups: Array, claimed: Dictionary) -> void:
	var by_id: Dictionary = {}
	for part in b.parts:
		by_id[part.id] = part
	var moving: Dictionary = groups[2]
	var footprint: Rect2 = moving.footprint
	var bottom := INF
	var top := -INF
	for id in moving.occupiedIds:
		var box: AABB = boxes[id]
		bottom = minf(bottom, box.position.y)
		top = maxf(top, box.end.y)
	var pivot := Vector3(footprint.get_center().x, bottom, footprint.get_center().y)
	var surfaces: Array = []
	for part in b.parts:
		if not part.collision_enabled or part.rotation != Vector3.ZERO:
			continue
		if not Urban.is_primary_tree_paving(part) and String(part.recipe.get("topSurfaceMaterial", "")).is_empty():
			continue
		var bounds: AABB = boxes[part.id]
		var rect := _xz(bounds).grow(-0.1)
		# Thin source segments cannot contain this household at any cardinal
		# angle; reject them before clamping or querying rectangle intersections.
		if rect.size.x < minf(footprint.size.x, footprint.size.y) or rect.size.y < minf(footprint.size.x, footprint.size.y):
			continue
		var nearest := footprint.get_center().clamp(rect.position, rect.end)
		if nearest.distance_to(footprint.get_center()) > SEARCH_RADIUS:
			continue
		surfaces.append({"id": part.id, "bounds": bounds, "allowed": rect})
	var trials: Array = []
	var candidates: Array = []
	if surfaces.size() > 64:
		report["rotatedNearbyPavingSearch"] = {"status": "surface_limit_exceeded", "surfaceCount": surfaces.size(), "limit": 64}
		return
	for surface in surfaces:
		var floor_y: float = surface.bounds.end.y
		for quarter in range(4):
			var yaw := float(quarter) * PI * 0.5
			var turn := Basis(Vector3.UP, yaw)
			var rotated := Rect2()
			var first := true
			for id in moving.occupiedIds:
				var part = by_id[id]
				var local_transform: Transform3D = Transform3D(turn, -(turn * pivot)) * b.part_transform(part)
				var bound := _transformed_bounds(local_transform, part.size)
				var rect := _xz(bound)
				rotated = rect if first else rotated.merge(rect)
				first = false
			# Keep the rotation pivot at its old XZ position for distance ranking.
			rotated.position += Vector2(pivot.x, pivot.z)
			var obstacles: Array = []
			var obstacle_ids: Array = []
			# An empty volume inside a house is not outdoor paving. Keep rooms
			# and their use/access space reserved even above buried terraces.
			for room in b.rooms:
				# The compound explicitly models the outdoor courtyard as a room
				# for furnishing ownership; it is not an enclosed building.
				if String(room.get("role", "")) == "courtyard":
					continue
				var room_bounds: AABB = room.get("bounds", AABB())
				var room_rect := _xz(room_bounds)
				if room_rect.has_area() and room_rect.intersects(surface.allowed):
					obstacles.append(room_rect)
					obstacle_ids.append("room:" + String(room.get("id", "")))
			for part in b.parts:
				if claimed.get(part.id, "") == moving.name or part.id == surface.id or _surface_detail(part):
					continue
				var bounds: AABB = boxes[part.id]
				if part.kind == "door" or part.kind == "stair_tread" or part.kind == "ramp":
					var access := _xz(bounds).grow(1.25 if part.kind == "door" else 0.8)
					if access.intersects(surface.allowed):
						obstacles.append(access)
						obstacle_ids.append("access:" + String(part.id))
				if bounds.end.y <= floor_y or bounds.position.y >= floor_y + top - bottom:
					continue
				var rect := _xz(bounds)
				if not rect.grow(0.1).intersects(surface.allowed):
					continue
				# Dominance pruning changes no occupied area: discard only bounds
				# fully contained by another actual obstacle at the same Y band.
				var contained := false
				for existing in obstacles:
					if (existing as Rect2).encloses(rect):
						contained = true
						break
				if contained:
					continue
				for index in range(obstacles.size() - 1, -1, -1):
					if rect.encloses(obstacles[index]):
						obstacles.remove_at(index)
						obstacle_ids.remove_at(index)
				obstacles.append(rect)
				obstacle_ids.append(part.id)
			var outcome: Dictionary = Placement.find_translation(rotated, surface.allowed, obstacles, 0.1)
			if outcome.get("reason", "") == "placement_obstacle_limit":
				outcome = _grid_translation(rotated, surface.allowed, obstacles, pivot)
			var row := {"surfaceId": surface.id, "floorY": floor_y, "yawDegrees": quarter * 90,
				"obstacleCount": obstacles.size(), "solver": outcome}
			trials.append(row)
			if not outcome.get("ready", false):
				continue
			var delta: Vector3 = outcome.translation
			var target := Vector3(pivot.x + delta.x, floor_y, pivot.z + delta.z)
			if Vector2(delta.x, delta.z).length() > SEARCH_RADIUS:
				row["rejectedBeyondSearchRadius"] = true
				continue
			var transform := Transform3D(turn, target - turn * pivot)
			row["pivotBefore"] = pivot
			row["pivotAfter"] = target
			row["distanceSquared"] = pivot.distance_squared_to(target)
			row["transformOrigin"] = transform.origin
			row["memberCount"] = moving.allIds.size()
			row["treeEnvelopeConflicts"] = _tree_overlap_rows(report.treeRecords, outcome.placedFootprint, 0.1)
			row["obstacleIds"] = obstacle_ids
			row["sourceCandidateOnly"] = true
			row["frontApproach"] = _front_approach(b, boxes, outcome.placedFootprint, floor_y,
				turn * Vector3(0.0, 0.0, -float(moving.layoutSpec.depth)), claimed, moving.name)
			row["nearbyContext"] = []
			row["circulationEnvelopeConflicts"] = []
			var area: Rect2 = outcome.placedFootprint
			for part in b.parts:
				if claimed.get(part.id, "") == moving.name:
					continue
				var bounds: AABB = boxes[part.id]
				if not area.grow(3.0).intersects(_xz(bounds)) or bounds.end.y < floor_y - 0.1 or bounds.position.y > floor_y + 3.0:
					continue
				row.nearbyContext.append({"id": part.id, "kind": part.kind, "semantic": part.semantic,
					"bounds": bounds, "collision": part.collision_enabled})
				if bounds.end.y > floor_y + 0.1 and bounds.position.y < floor_y + 2.0 and area.grow(0.8).intersects(_xz(bounds)):
					row.circulationEnvelopeConflicts.append(part.id)
			row["nearbyStairs"] = []
			for part in b.parts:
				if part.kind != "stair_tread" and part.kind != "ramp":
					continue
				var bounds: AABB = boxes[part.id]
				if area.grow(8.0).intersects(_xz(bounds)):
					row.nearbyStairs.append({"id": part.id, "bounds": bounds})
			candidates.append(row)
	candidates.sort_custom(func(a: Dictionary, c: Dictionary):
		if a.distanceSquared != c.distanceSquared:
			return a.distanceSquared < c.distanceSquared
		if a.surfaceId != c.surfaceId:
			return a.surfaceId < c.surfaceId
		return a.yawDegrees < c.yawDegrees)
	report["rotatedNearbyPavingSearch"] = {"searchRadius": SEARCH_RADIUS, "surfaces": surfaces,
		"orientations": [0, 90, 180, 270], "trials": trials, "candidates": candidates,
		"placementAccepted": false, "sourcePivot": pivot,
		"limits": "Source AABB discovery only. Each complete household is aligned rigidly to an existing collision top, never suspended or reshaped. Exact publisher primitives, tree envelopes, approach/door access and preservation require further review. No source mutation. A bounded no-fit is not universal impossibility."}
	report["extraChecksCompleted"] = true

func _front_approach(b, boxes: Dictionary, area: Rect2, floor_y: float, direction: Vector3, claimed: Dictionary, label: String) -> Dictionary:
	var forward := Vector2(direction.x, direction.z).normalized()
	var lateral := Vector2(-forward.y, forward.x)
	var edge := area.get_center() + forward * (area.size.x * 0.5 if absf(forward.x) > 0.5 else area.size.y * 0.5)
	var rows: Array = []
	for step in range(7):
		for side in [-0.6, 0.0, 0.6]:
			var sample: Vector2 = edge + forward * (0.8 + float(step) * 0.5) + lateral * side
			var supporting: Array = []
			var blocked: Array = []
			var foot := Rect2(sample - Vector2.ONE * 0.3, Vector2.ONE * 0.6)
			for part in b.parts:
				if claimed.get(part.id, "") == label or not part.collision_enabled:
					continue
				var bounds: AABB = boxes[part.id]
				var footprint := _xz(bounds)
				if not foot.intersects(footprint):
					continue
				# Arithmetic-only equality for an existing source top. No height
				# interpolation, fabricated floor, step or route is accepted here.
				if absf(bounds.end.y - floor_y) <= 0.00001 and footprint.encloses(foot):
					supporting.append(part.id)
				elif bounds.end.y > floor_y + 0.00001 and bounds.position.y < floor_y + 2.0:
					blocked.append(part.id)
			rows.append({"position": Vector3(sample.x, floor_y, sample.y), "supportIds": supporting, "blockerIds": blocked,
				"passed": not supporting.is_empty() and blocked.is_empty()})
	return {"passed": rows.all(func(row): return row.passed), "samples": rows,
		"direction": direction, "evidenceLevel": "source_collision_box_supported_front_samples_not_live_traversal",
		"footprintWidth": 0.6, "headroom": 2.0, "distanceBeyondAssembly": [0.8, 3.8]}

func _grid_translation(moving: Rect2, allowed: Rect2, obstacles: Array, pivot: Vector3) -> Dictionary:
	# Diagnostic-only alternative for crowded surfaces; never drop obstacles
	# or widen the production solver cap. Finite 0.25m samples, not exact search.
	if obstacles.size() > 256:
		return {"ready": false, "reason": "diagnostic_obstacle_limit", "count": obstacles.size()}
	var half := moving.size * 0.5
	var old_center := Vector2(pivot.x, pivot.z)
	var minimum := (allowed.position + half).max(old_center - Vector2.ONE * SEARCH_RADIUS)
	var maximum := (allowed.end - half).min(old_center + Vector2.ONE * SEARCH_RADIUS)
	var best := Vector2.INF
	var distance := INF
	var tested := 0
	var grown: Array = obstacles.map(func(rect: Rect2): return rect.grow(0.1))
	for ix in range(maxi(0, floori((maximum.x - minimum.x) / 0.25) + 1)):
		for iz in range(maxi(0, floori((maximum.y - minimum.y) / 0.25) + 1)):
			var center := minimum + Vector2(ix, iz) * 0.25
			var delta := center - moving.get_center()
			var score := center.distance_squared_to(old_center)
			if score > SEARCH_RADIUS * SEARCH_RADIUS or score >= distance:
				continue
			tested += 1
			var placed := Rect2(center - half, moving.size)
			if not allowed.encloses(placed) or grown.any(func(rect: Rect2): return rect.intersects(placed)):
				continue
			best = delta
			distance = score
	if best == Vector2.INF:
		return {"ready": false, "reason": "no_sampled_grid_fit", "testedCandidates": tested, "gridStep": 0.25}
	return {"ready": true, "reason": "", "translation": Vector3(best.x, 0.0, best.y),
		"placedFootprint": Rect2(moving.position + best, moving.size), "testedCandidates": tested,
		"gridStep": 0.25, "clearance": 0.1, "method": "bounded_diagnostic_grid_not_exact_nearest"}

func _transformed_bounds(transform: Transform3D, size: Vector3) -> AABB:
	var half := size * 0.5
	var bounds := AABB(transform * -half, Vector3.ZERO)
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				bounds = bounds.expand(transform * Vector3(x * half.x, y * half.y, z * half.z))
	return bounds

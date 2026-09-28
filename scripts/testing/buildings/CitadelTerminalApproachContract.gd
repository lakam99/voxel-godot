extends SceneTree

## Source-only sidecar. Exit 0 means inventory completed, NEVER public access PASS.
## No scene instance, renderer, navigation query, teleport, or source mutation.
const Visual = preload("res://scripts/testing/buildings/CitadelMarketRecipeVisual.gd")
# Diagnostic envelope matches PlayerController._ready, not a new actor authority.
const RADIUS := 0.42
const HEIGHT := 1.72
const FRONT_GAP := 0.10
const CONTACT_EPS := 0.00001
const INVENTORY_RADIUS := 8.0
const MAX_PARTS := 10000
const MAX_NEARBY := 4096
const MAX_SURFACES := 512
const MAX_PAIRS := 500000
const MAX_FACTS := 8192
var _pairs := 0
var _facts := 0
var _failure := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var output := OS.get_environment("VOXEL_TERMINAL_APPROACH_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output):
		quit(2)
		return
	var started := Time.get_ticks_usec()
	var baseline := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE")
	var prepared: Dictionary = Visual._prepare_frozen_recipe(baseline, true)
	var report: Dictionary = {
		"evidenceLevel": "prepared_source_geometry_diagnostic", "diagnosticComplete": false,
		"localStandability": {"status": "not_inspected", "liveStandabilityProven": false},
		"continuousPublicApproach": {"passed": false, "status": "unproven",
			"reason": "No continuous exposed support/clearance or live crossing evidence. Boundary proximity and local standing space are not routes."},
		"policy": {"radius": RADIUS, "height": HEIGHT, "frontGap": FRONT_GAP,
			"dimensionsOwner": "PlayerController._ready capsule (copied diagnostic dimensions)",
			"inventoryRadius": INVENTORY_RADIUS, "maxParts": MAX_PARTS,
			"maxNearby": MAX_NEARBY, "maxSurfaces": MAX_SURFACES,
			"maxPairs": MAX_PAIRS, "maxFacts": MAX_FACTS},
		"limitations": "Transformed source envelopes only, not publisher mesh intersections or collision-server proof. Rotated/nonbox obstacle bounds are conservative. Room/access rows are reservations, not asserted physical solids. Tree/light publication after preparation is absent. No NPC, door-state, dynamic actor, slope, stair-rise or world-connectivity acceptance. Baseline physical failures are reported without a new physical validation or waiver."}
	if not prepared.get("ready", false):
		report["reason"] = "preparation_not_ready"
		report["preparation"] = prepared
	else:
		report["baselineSha256"] = prepared.baselineSha256
		report["baselinePhysical"] = prepared.baselinePhysical
		report["preparationUsec"] = prepared.preparationUsec
		var b = prepared.blueprint
		if b.parts.size() > MAX_PARTS:
			_failure = "source_collection_limit"
		else:
			var before: PackedByteArray = var_to_bytes(b.snapshot())
			# Reuse the fixture's actual frozen furnishing/reservation conversion.
			# Only read after successful SHA-checked preparation; recheck for replacement.
			if FileAccess.get_sha256(baseline) != prepared.baselineSha256:
				_failure = "frozen_changed_after_preparation"
			else:
				var file := FileAccess.open(baseline, FileAccess.READ)
				if file == null:
					_failure = "frozen_reopen_failed"
				else:
					var envelope: Variant = file.get_var(false)
					var valid := file.get_error() == OK and file.get_position() == file.get_length()
					file.close()
					if not valid or not envelope is Dictionary or not envelope.get("output") is Dictionary:
						_failure = "frozen_reread_failed"
					else:
						_inspect(b, prepared.terminals, envelope.output, report)
			report["preparedSourceUnchanged"] = before == var_to_bytes(b.snapshot())
			if not report.preparedSourceUnchanged:
				_failure = "diagnostic_mutated_source"
		report["diagnosticComplete"] = _failure.is_empty()
		report["reason"] = "inventory_complete_public_approach_unproven" if _failure.is_empty() else _failure
	report["pairChecks"] = _pairs
	report["factCount"] = _facts
	report["elapsedUsec"] = Time.get_ticks_usec() - started
	var writer := FileAccess.open(output, FileAccess.WRITE)
	if writer == null:
		quit(2)
		return
	writer.store_string(JSON.stringify(_json(report), "\t"))
	writer.close()
	quit(0 if report.diagnosticComplete else 1)


func _inspect(b, terminals: Dictionary, frozen: Dictionary, report: Dictionary) -> void:
	var setups: Array = terminals.get("setups", [])
	if not terminals.get("ready", false) or setups.is_empty() or setups.size() > 16:
		_failure = "terminal_preparation_schema"
		return
	var index: Dictionary = {}
	var records: Array = []
	for part in b.parts:
		if index.has(part.id) or not b.has_finite_positive_bounds(part):
			_failure = "duplicate_or_invalid_source_part"
			return
		index[part.id] = part
		var bounds: AABB = b.transformed_part_bounds(part)
		if not _valid(bounds):
			return
		records.append({"id": part.id, "bounds": bounds, "collision": part.collision_enabled,
			"kind": part.kind, "semantic": part.semantic, "origin": "prepared_part",
			"axisAligned": _axis_aligned(b.part_transform(part).basis),
			"navigationRole": part.recipe.get("navigationRole", "")})
	var support_id := String(terminals.get("elevation", {}).get("supportId", ""))
	if not index.has(support_id):
		_failure = "selected_support_missing"
		return
	var support = index[support_id]
	var support_bounds: AABB = b.transformed_part_bounds(support)
	if not support.collision_enabled or not _axis_aligned(b.part_transform(support).basis):
		_failure = "unsupported_selected_surface_geometry"
		return
	var support_rect := _xz(support_bounds)
	var region := support_rect.grow(INVENTORY_RADIUS)
	var standing_y := support_bounds.end.y
	report["selectedSupport"] = {"id": support_id, "bounds": support_bounds,
		"standingY": standing_y, "kind": support.kind, "semantic": support.semantic,
		"sourceClosureIds": terminals.elevation.get("supportClosure", {}).get("partIds", [])}
	if frozen.get("furnitureSnapshot", {}).get("parts", []).size() > MAX_PARTS or frozen.get("protectedReservations", []).size() > MAX_PARTS or b.rooms.size() > 256:
		_failure = "reservation_collection_limit"
		return
	for obstacle in Visual._frozen_furnishing_obstacles(frozen):
		if not _valid(obstacle.bounds):
			return
		records.append({"id": obstacle.id, "bounds": obstacle.bounds, "collision": null,
			"origin": "frozen_furnishing_or_access_reservation", "kind": "reservation", "semantic": "reservation"})
	for room in b.rooms:
		if not room is Dictionary or not room.get("bounds") is AABB or not room.get("accesses", []) is Array or room.get("accesses", []).size() > 32:
			_failure = "room_schema_or_collection_limit"
			return
		if not _valid(room.bounds):
			return
		if room.get("role", "") != "courtyard":
			records.append({"id": String(room.get("id", "")), "bounds": room.bounds,
				"collision": null, "origin": "interior_reservation", "kind": "reservation", "semantic": "interior"})
		for i in range(room.get("accesses", []).size()):
			var access: Variant = room.accesses[i]
			if not access is Dictionary or not access.get("position") is Vector3 or not access.get("size") is Vector3:
				_failure = "access_schema"
				return
			var bounds := AABB(access.position - access.size * 0.5, access.size)
			if not _valid(bounds):
				return
			records.append({"id": "%s/access/%d" % [room.get("id", ""), i], "bounds": bounds,
				"collision": null, "origin": "access_reservation", "kind": "reservation", "semantic": "access"})
	var nearby: Array = []
	var surfaces: Array = []
	for row in records:
		if not region.intersects(_xz(row.bounds), true):
			continue
		nearby.append(row)
		if row.origin == "prepared_part" and row.collision and (row.kind in ["foundation", "floor", "stair_tread"] or row.navigationRole == "walkable_support" or "paving" in String(row.semantic) or "plaza" in String(row.semantic)):
			surfaces.append(row)
	if nearby.size() > MAX_NEARBY or surfaces.size() > MAX_SURFACES:
		_failure = "nearby_collection_limit"
		return
	report["nearbyCount"] = nearby.size()
	report["inventoryRegionXZ"] = region
	var bays: Array = []
	report["bays"] = bays
	for setup in setups:
		# Same public producer-prefix convention consumed by the visual fixture.
		var counter_id := String(setup.prefix) + "_counter"
		var lintel_id := String(setup.prefix) + "_lintel"
		if not index.has(counter_id) or not index.has(lintel_id):
			_failure = "counter_or_lintel_missing"
			return
		var counter = index[counter_id]
		if counter.size.x < RADIUS * 2.0:
			_failure = "counter_narrower_than_diagnostic_capsule"
			return
		var transform: Transform3D = b.part_transform(counter)
		var front: Vector3 = (b.part_transform(index[lintel_id]).basis * Vector3.FORWARD).normalized()
		if not _axis_aligned(transform.basis) or absf(front.y) > CONTACT_EPS or front.dot(transform.basis * Vector3.FORWARD) < 0.99999:
			_failure = "unsupported_counter_orientation"
			return
		var front_center: Vector3 = counter.position + front * (counter.size.z * 0.5)
		front_center.y = standing_y
		var band_local := AABB(Vector3(-counter.size.x * 0.5, 0.0, -counter.size.z * 0.5 - FRONT_GAP - RADIUS * 2.0), Vector3(counter.size.x, HEIGHT, RADIUS * 2.0))
		var band_transform := Transform3D(transform.basis, Vector3(counter.position.x, standing_y, counter.position.z))
		var band: AABB = band_transform * band_local
		if not region.encloses(_xz(band)):
			_failure = "customer_band_outside_inventory"
			return
		var obstacles := _overlaps(band, nearby, support_id)
		var samples: Array = []
		for i in range(5):
			var usable_half := maxf(0.0, counter.size.x * 0.5 - RADIUS)
			var feet := front_center + transform.basis.x * lerpf(-usable_half, usable_half, float(i) / 4.0) + front * (FRONT_GAP + RADIUS)
			var disk_bounds := Rect2(Vector2(feet.x - RADIUS, feet.z - RADIUS), Vector2.ONE * RADIUS * 2.0)
			samples.append({"feet": feet, "wholeDiskSupported": support_rect.encloses(disk_bounds),
				"capsuleEnvelopePotentialConflicts": _capsule_conflicts(feet, nearby, support_id)})
		bays.append({"prefix": setup.prefix, "counterId": counter_id,
			"counterBounds": b.transformed_part_bounds(counter), "front": front, "frontEdgeCenter": front_center,
			"customerBand": band, "wholeBandOnSelectedSupport": support_rect.encloses(_xz(band)),
			"bandPotentialConflicts": obstacles, "samples": samples,
			"localSourceEnvelopeClear": _failure.is_empty() and support_rect.encloses(_xz(band)) and obstacles.is_empty(),
			"scope": "Full band containment and conservative source-envelope clearance; samples are local capsule checks, not a route or live standability proof."})
		if not _failure.is_empty():
			return
	report["localStandability"] = {"status": "source_envelope_diagnostic_only",
		"allBaySourceBandsClear": bays.all(func(bay): return bay.localSourceEnvelopeClear),
		"liveStandabilityProven": false}
	var inventory: Array = []
	report["surfaceInventory"] = inventory
	for surface in surfaces:
		var bounds: AABB = surface.bounds
		var rect := _xz(bounds)
		# Large paving may extend beyond the bounded inventory. Never certify
		# its unscanned remainder from a local obstacle collection.
		var inspected := rect.intersection(region)
		var overhead := AABB(Vector3(inspected.position.x, bounds.end.y + CONTACT_EPS, inspected.position.y), Vector3(inspected.size.x, HEIGHT, inspected.size.y))
		var facts := _overlaps(overhead, nearby, surface.id)
		inventory.append({"id": surface.id, "kind": surface.kind, "semantic": surface.semantic,
			"navigationRole": surface.navigationRole, "bounds": bounds, "axisAligned": surface.axisAligned,
			"topY": bounds.end.y, "topMinusSelectedTop": bounds.end.y - standing_y,
			"xzGapToSelected": _rect_gap(rect, support_rect), "overlapsSelectedXZ": rect.intersects(support_rect),
			"selectedBoundaryRelations": _boundaries(support_rect, rect),
			"topHeadroomPotentialConflicts": facts,
			"inspectedFootprint": inspected, "entireFootprintInspected": region.encloses(rect),
			"inspectedTopEnvelopeClear": surface.axisAligned and facts.is_empty() and _failure.is_empty(),
			"interpretation": "Partial overlap is not complete burial. No exposure claim for rotated surfaces; no walkability or public designation inferred from kind/semantic."})
		if not _failure.is_empty():
			return


func _overlaps(volume: AABB, rows: Array, exclude: String) -> Array:
	var result: Array = []
	for row in rows:
		if not _budget():
			break
		var bounds: AABB = row.bounds
		if row.id == exclude or bounds.end.y <= volume.position.y + CONTACT_EPS or not volume.intersects(bounds):
			continue
		if not _fact():
			break
		result.append({"id": row.id, "origin": row.origin, "collision": row.collision,
			"bounds": bounds, "intersectionBounds": volume.intersection(bounds),
			"coversWholeXZ": _xz(bounds).encloses(_xz(volume)),
			"classification": "source_aabb_potential_overlap_not_mesh_intersection"})
	return result


func _capsule_conflicts(feet: Vector3, rows: Array, exclude: String) -> Array:
	var result: Array = []
	for row in rows:
		if not _budget():
			break
		var bounds: AABB = row.bounds
		if row.id == exclude or bounds.end.y <= feet.y + CONTACT_EPS:
			continue
		# Exact distance of vertical capsule axis segment to source AABB. Still
		# conservative relative to actual nonbox/rotated publication geometry.
		var dx := maxf(maxf(bounds.position.x - feet.x, feet.x - bounds.end.x), 0.0)
		var dz := maxf(maxf(bounds.position.z - feet.z, feet.z - bounds.end.z), 0.0)
		var dy := maxf(maxf(bounds.position.y - (feet.y + HEIGHT - RADIUS), feet.y + RADIUS - bounds.end.y), 0.0)
		if dx * dx + dy * dy + dz * dz < RADIUS * RADIUS:
			if not _fact():
				break
			result.append({"id": row.id, "origin": row.origin, "collision": row.collision,
				"bounds": bounds, "classification": "capsule_vs_source_aabb_potential_conflict"})
	return result


func _boundaries(selected: Rect2, other: Rect2) -> Array:
	var result: Array = []
	for axis in range(2):
		var tangent := 1 - axis
		var lo := maxf(selected.position[tangent], other.position[tangent])
		var hi := minf(selected.end[tangent], other.end[tangent])
		if hi <= lo:
			continue
		for side in range(2):
			var coordinate: float = selected.position[axis] if side == 0 else selected.end[axis]
			var gap := maxf(maxf(other.position[axis] - coordinate, coordinate - other.end[axis]), 0.0)
			result.append({"axis": "x" if axis == 0 else "z", "side": "min" if side == 0 else "max",
				"coordinate": coordinate, "tangentInterval": [lo, hi], "horizontalGap": gap})
	return result


func _rect_gap(a: Rect2, b: Rect2) -> float:
	return Vector2(maxf(maxf(a.position.x - b.end.x, b.position.x - a.end.x), 0.0), maxf(maxf(a.position.y - b.end.y, b.position.y - a.end.y), 0.0)).length()


func _axis_aligned(basis: Basis) -> bool:
	for axis in [basis.x, basis.y, basis.z]:
		if absf(axis.length_squared() - 1.0) > CONTACT_EPS or maxf(absf(axis.x), maxf(absf(axis.y), absf(axis.z))) < 1.0 - CONTACT_EPS:
			return false
	return absf(basis.y.dot(Vector3.UP) - 1.0) <= CONTACT_EPS


func _valid(bounds: AABB) -> bool:
	if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		_failure = "invalid_bounds"
		return false
	if bounds.position.length() > 1000000.0 or bounds.size.length() > 1000000.0:
		_failure = "coordinate_limit"
		return false
	return true


func _budget() -> bool:
	if not _failure.is_empty():
		return false
	_pairs += 1
	if _pairs > MAX_PAIRS:
		_failure = "pair_work_limit"
	return _failure.is_empty()


func _fact() -> bool:
	_facts += 1
	if _facts > MAX_FACTS:
		_failure = "report_fact_limit"
	return _failure.is_empty()


func _xz(bounds: AABB) -> Rect2:
	return Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))


func _json(value: Variant) -> Variant:
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Vector2:
		return [value.x, value.y]
	if value is AABB or value is Rect2:
		return {"position": _json(value.position), "size": _json(value.size)}
	if value is Transform3D:
		return {"origin": _json(value.origin), "basis": [_json(value.basis.x), _json(value.basis.y), _json(value.basis.z)]}
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[key] = _json(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _json(item))
	return value

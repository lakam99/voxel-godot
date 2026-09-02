extends RefCounted

## Unwired three-piece recipe prototype. One shallow visible band is carried
## by two transverse end blocks, each genuinely housed in its masonry gable.
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Core = preload("res://scripts/buildings/MasonryWallGeometry.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const ReplacementOccupancy = preload("res://scripts/buildings/ReplacementBoxOccupancy.gd")
const ConstructionMath = preload("res://scripts/buildings/ConstructionSeamMath.gd")
const Admission = preload("res://scripts/buildings/ConstructionBoxAdmission.gd")
const Materials = preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const PAD := 0.02
const HALF := Vector3(0.04, 0.04, 0.07)
const MAX_AXIS_CANDIDATES := 128
const MAX_PLACEMENTS := 4096
const MAX_SAT_WORK := 250000

static func prepare(original_header: Dictionary, facade, gables: Array, foreign_parts: Array = [], retained_panels: Array = [], source_blueprint = null) -> Dictionary:
	if not _valid_part(facade) or facade.kind != "wall" or gables.size() != 2: return _fail("invalid_membership")
	var fitted := fit_body(original_header, facade, retained_panels)
	if not fitted.ready: return fitted
	var body := Part.new(fitted.body)
	var body_bounds := _bounds(body)
	var obstacles := _obstacles(foreign_parts)
	if not obstacles.ready: return obstacles
	var ends: Array = []
	var body_facts: Array = []
	var placements: Array = []
	var direct_seats: Array = []
	var work := {"satPairs": 0}
	var seen: Dictionary = {}
	for gable in gables:
		if not _valid_part(gable) or gable.kind != "wall" or not Materials.is_masonry_material(gable.material_id) or not gable.collision_enabled or gable.rotation != Vector3.ZERO or seen.has(gable.id): return _fail("invalid_gable")
		seen[gable.id] = true
		var core_size := Core.bed_size(gable.size)
		var core_bounds := _bounds_values(gable.position, core_size)
		var side := signf(body.position.x - gable.position.x)
		if side == 0.0: return _fail("ambiguous_frontage")
		# The connection spans X, so its genuine longitudinal socket is >=0.12m
		# along X. The band spans Z and retains its separate longitudinal joint.
		var socket_half := Vector3(HALF.z, HALF.y, HALF.z)
		var outer: float = core_bounds[3] if side > 0.0 else core_bounds[0]
		var placement := _place_connection(body_bounds, core_bounds, Vector3(outer - side * (socket_half.x + PAD), body.position.y, gable.position.z), socket_half, obstacles.boxes, work)
		if not placement.ready:
			if placement.reason == "no_clear_connection_in_socket_domain" and source_blueprint != null:
				var direct := _rooted_direct_seat(body, gable, foreign_parts, source_blueprint)
				if direct.ready:
					if body_facts.any(func(fact): return fact.seatId == direct.fact.seatId): return _fail("duplicate_end_support")
					body_facts.append(direct.fact)
					direct_seats.append(direct)
					placements.append({"kind": "direct_existing_masonry", "declaredGableId": gable.id, "selectedSeatId": direct.fact.seatId, "socket": direct.socket})
					continue
				placement["directSeatFailure"] = direct
			placement["gableId"] = gable.id
			return placement
		var socket: Vector3 = placement.socket
		var end: Dictionary = placement.end
		placements.append(placement.evidence)
		var end_id: String = body.id + "_connection_" + str(body_facts.size())
		var gable_fact := {"seatId": gable.id, "contactMode": "housed_overlap", "localSpanAxis": "x",
			"localOverlapCenter": socket - end.position, "localOverlapHalfExtents": socket_half,
			"minimumLongitudinalEmbedment": 0.12, "minimumVerticalOverlap": 0.04}
		var end_record := {"id": end_id, "kind": "beam", "material": body.material_id, "position": end.position, "size": end.size,
			"collision": true, "semantic": "citadel_opening_head_connection", "physicalIntent": "structural_mass",
			"recipe": {"physicalIntent": "structural_mass", "preserveBearingFaces": true,
			"variation": body.recipe.get("variation", 0.0), "physicalRequiredSeatPartIds": [gable.id], "physicalRequiredSeatFacts": [gable_fact]}}
		var interface_center := Vector3(body.position.x, socket.y, socket.z)
		body_facts.append({"seatId": end_id, "contactMode": "housed_overlap", "localSpanAxis": "z",
			"localOverlapCenter": interface_center - body.position, "localOverlapHalfExtents": HALF,
			"minimumLongitudinalEmbedment": 0.12, "minimumVerticalOverlap": 0.04})
		# Complete finite socket plus construction pad must stay inside the real
		# core on Y/Z. X crosses from the band into the core by design.
		var actual: Array = _bounds_values(end.position, end.size)
		for axis in [1, 2]:
			if actual[axis] < core_bounds[axis] or actual[axis + 3] > core_bounds[axis + 3]: return _fail("connection_outside_core")
		ends.append(end_record)
	if body_facts.size() != 2 or not body_facts.any(func(fact): return fact.localOverlapCenter.z < 0.0) or not body_facts.any(func(fact): return fact.localOverlapCenter.z > 0.0): return _fail("end_supports_do_not_bracket_span")
	body.recipe.physicalRequiredSeatPartIds = body_facts.map(func(fact): return fact.seatId)
	body.recipe.physicalRequiredSeatFacts = body_facts
	return {"ready": true, "body": body.snapshot(), "bodyFit": fitted.boundsEvidence, "connections": ends, "directSeats": direct_seats, "placements": placements, "work": work,
		"scope": "Source framing construction only. Existing masonry adoption requires an independent owner-house root proof; assembly joints, occupancy and publication still require independent acceptance."}

## A finite housed joint into actual existing masonry, near the declared end.
## Geometry alone is never a root certificate; _rooted_direct_seat supplies it.
static func direct_socket(body, declared_gable, masonry) -> Dictionary:
	for part in [body, declared_gable, masonry]:
		if not _valid_part(part) or part.rotation != Vector3.ZERO: return _fail("invalid_direct_joint_part")
	if body.kind != "beam" or not body.collision_enabled or declared_gable.kind != "wall" or not declared_gable.collision_enabled or masonry.kind != "wall" or not masonry.collision_enabled or not Materials.is_masonry_material(masonry.material_id): return _fail("invalid_direct_masonry")
	var bounds := _bounds(body)
	var core := _bounds_values(masonry.position, Core.bed_size(masonry.size))
	var gable_bounds := _bounds(declared_gable)
	if not ReplacementOccupancy.valid(bounds) or not ReplacementOccupancy.valid(core) or not ReplacementOccupancy.valid(gable_bounds): return _fail("invalid_direct_joint_bounds")
	var end_side := signf(declared_gable.position.z - body.position.z)
	if end_side == 0.0: return _fail("ambiguous_direct_end")
	var socket := Vector3.ZERO
	var domain: Array = []
	for axis in range(3):
		var low := maxf(bounds[axis], core[axis]) + HALF[axis] + PAD
		var high := minf(bounds[axis + 3], core[axis + 3]) - HALF[axis] - PAD
		var preferred: float = body.position[axis]
		if axis == 2:
			# No nearest-wall repair at an arbitrary point along the span. The
			# joint center must stay in the original gable's physical end zone,
			# and the complete joint remains on its corresponding beam half.
			low = maxf(low, gable_bounds[2])
			high = minf(high, gable_bounds[5])
			if end_side < 0.0: high = minf(high, float(body.position.z) - HALF.z - PAD)
			else: low = maxf(low, float(body.position.z) + HALF.z + PAD)
			preferred = declared_gable.position.z
			domain = [low, high]
		low = _represented_inward(low, true)
		high = _represented_inward(high, false)
		if low > high: return _fail("no_finite_direct_socket")
		socket[axis] = clampf(preferred, low, high)
	var local: Vector3 = socket - body.position
	var fact := {"seatId": masonry.id, "contactMode": "housed_overlap", "localSpanAxis": "z",
		"localOverlapCenter": local, "localOverlapHalfExtents": HALF,
		"minimumLongitudinalEmbedment": 0.12, "minimumVerticalOverlap": 0.04}
	return {"ready": true, "fact": fact, "socket": socket, "coreBounds": core, "bodyBounds": bounds, "endDomain": domain,
		"declaredGableId": declared_gable.id, "endSide": end_side, "scope": "Finite source geometry only; not a root or publication proof."}

static func _rooted_direct_seat(body, gable, foreign_parts: Array, source) -> Dictionary:
	if source.parts.size() > 10000: return _fail("direct_source_limit")
	for proposed_id: String in [body.id, body.id + "_connection_0", body.id + "_connection_1"]:
		if source.find_part(proposed_id) != null: return _fail("proposed_framing_in_support_source")
	var candidates: Array = []
	for part in foreign_parts:
		if not _valid_part(part) or part.kind != "wall" or not part.collision_enabled or not Materials.is_masonry_material(part.material_id): continue
		var direct := direct_socket(body, gable, part)
		if direct.ready: candidates.append(direct)
	if candidates.is_empty(): return _fail("no_direct_masonry_geometry")
	if candidates.size() > 32: return _fail("direct_candidate_limit")
	candidates.sort_custom(func(a, b):
		var da := absf(a.socket.z - gable.position.z)
		var db := absf(b.socket.z - gable.position.z)
		return da < db if da != db else a.fact.seatId < b.fact.seatId)
	var membership := Copy.street_house_memberships(source)
	if not membership.ready: return _fail("direct_source_membership_unavailable")
	var owner_proofs: Dictionary = {}
	for direct: Dictionary in candidates:
		var id: String = direct.fact.seatId
		var owners: Array = membership.houses.filter(func(house): return house.memberIds.has(id))
		if owners.size() != 1: continue
		var owner: Dictionary = owners[0]
		if not owner_proofs.has(owner.prefix):
			var independent = Blueprint.new("direct_seat_independent_owner", source.seed, source.style)
			var included: Array = []
			var excluded: Array = []
			for member_id: String in owner.memberIds:
				var member = source.find_part(member_id)
				if member.semantic in ["citadel_urban_facade", "citadel_opening_head_band", "citadel_opening_head_connection"] or member.id == body.id:
					excluded.append(member.id)
					continue
				independent.add_part(member.snapshot())
				included.append(member.id)
			Copy.clear_caches(independent)
			var grid_work := Copy.validation_grid_work(independent)
			if not grid_work.ready: return _fail("direct_root_grid_limit")
			var root_report: Dictionary = independent.validate_physical_integrity()
			owner_proofs[owner.prefix] = {"report": root_report, "memberIds": included, "excludedIds": excluded}
		var proof: Dictionary = owner_proofs[owner.prefix]
		var seat_check: Array = proof.report.checks.filter(func(check): return check.partId == id)
		if seat_check.size() != 1 or not seat_check[0].passed or not seat_check[0].get("reachesGroundRoot", false) or seat_check[0].get("intent", "") not in ["structural_root", "structural_mass"]: continue
		var source_part = source.find_part(id)
		var foreign: Array = foreign_parts.filter(func(part): return part.id == id)
		if source_part == null or foreign.size() != 1 or source_part.position != foreign[0].position or source_part.rotation != foreign[0].rotation or source_part.size != foreign[0].size or source_part.collision_enabled != foreign[0].collision_enabled or source_part.kind != foreign[0].kind or source_part.material_id != foreign[0].material_id: return _fail("direct_seat_source_mismatch")
		direct["rootProof"] = {"seatCheck": seat_check[0], "ownerPrefix": owner.prefix, "independentMemberIds": proof.memberIds, "excludedFacadeIds": proof.excludedIds}
		return direct
	return _fail("no_independently_rooted_direct_masonry")

static func fit_body(original_header: Dictionary, facade, retained_panels: Array) -> Dictionary:
	if not _valid_part(facade) or facade.kind != "wall" or facade.rotation != Vector3.ZERO: return _fail("invalid_facade")
	if not original_header.get("position") is Vector3 or not original_header.get("size") is Vector3 or not original_header.get("recipe") is Dictionary: return _fail("invalid_header_input")
	var body := Part.new(original_header)
	if not _valid_part(body) or body.kind != "beam" or body.size != original_header.size or body.rotation != Vector3.ZERO: return _fail("invalid_body")
	body.position.x = facade.position.x
	body.size.x = facade.size.x
	var original: Array = _bounds(body)
	var desired: Array = original.duplicate()
	if retained_panels.size() > 512: return _fail("retained_panel_limit")
	var seen: Dictionary = {}
	for panel in retained_panels:
		if not _valid_part(panel) or panel.rotation != Vector3.ZERO or panel.kind != "wall" or panel.position.x != facade.position.x or panel.size.x != facade.size.x or seen.has(panel.id): return _fail("invalid_retained_panel")
		seen[panel.id] = true
		# The represented lower face of retained material is authoritative. Do
		# not reproduce the rounded AABB end that originally trimmed it.
		desired[4] = minf(desired[4], float(panel.position.y) - float(panel.size.y) * 0.5)
	if desired[4] < original[4]:
		var fitted := _inside_box(desired)
		if fitted.is_empty(): return _fail("unrepresentable_body_fit")
		body.position = fitted.position
		body.size = fitted.size
	if body.size.y < 2.0 * (HALF.y + PAD): return _fail("insufficient_body_for_sockets")
	return {"ready": true, "body": body.snapshot(), "boundsEvidence": {"original": original, "desired": desired, "represented": _bounds(body), "retainedPanelCount": retained_panels.size()}}

## Search actual available socket domains, not a seed/name-specific offset. The
## finite candidate set is formed by the domains and nearby obstacle faces.
## Bounds are only a conservative search aid; every proposed end is SAT tested.
static func _place_connection(body_bounds: Array, core: Array, neutral: Vector3, socket_half: Vector3, obstacles: Array, work: Dictionary, measure_override: Callable = Callable()) -> Dictionary:
	var low_x := minf(body_bounds[0], float(neutral.x) - socket_half.x - PAD)
	var high_x := maxf(body_bounds[3], float(neutral.x) + socket_half.x + PAD)
	var domains: Array = []
	for axis in [1, 2]:
		# The entire end, not only its finite socket, must stay in the band's
		# Y/Z strip so it cannot enter retained masonry or the opening below.
		var low := maxf(core[axis], body_bounds[axis]) + socket_half[axis] + PAD
		var high := minf(core[axis + 3], body_bounds[axis + 3]) - socket_half[axis] - PAD
		if low > high: return _fail("empty_connection_socket_domain")
		domains.append([low, high])
	var envelope := [low_x, domains[0][0] - socket_half.y - PAD, domains[1][0] - socket_half.z - PAD,
		high_x, domains[0][1] + socket_half.y + PAD, domains[1][1] + socket_half.z + PAD]
	var nearby: Array = []
	for obstacle: Dictionary in obstacles:
		if _overlaps(envelope, obstacle.bounds): nearby.append(obstacle)
	var axes: Array = []
	for axis in [1, 2]:
		var candidates: Array = []
		var domain: Array = domains[axis - 1]
		_add_candidate(candidates, neutral[axis], domain)
		_add_candidate(candidates, _represented_inward(domain[0], true), domain)
		_add_candidate(candidates, _represented_inward(domain[1], false), domain)
		for obstacle: Dictionary in nearby:
			# Round away from the obstacle, never shrink its occupied volume.
			_add_candidate(candidates, _represented_inward(obstacle.bounds[axis] - socket_half[axis] - PAD, false), domain)
			_add_candidate(candidates, _represented_inward(obstacle.bounds[axis + 3] + socket_half[axis] + PAD, true), domain)
		if candidates.size() > MAX_AXIS_CANDIDATES: return _fail("connection_candidate_limit")
		candidates.sort_custom(func(a, b):
			var da := absf(a - neutral[axis])
			var db := absf(b - neutral[axis])
			return da < db if da != db else a < b)
		axes.append(candidates)
	if axes[0].size() * axes[1].size() > MAX_PLACEMENTS: return _fail("connection_placement_limit")
	var attempts := 0
	var empty_placements := 0
	var blocked_placements: Array = []
	for y: float in axes[0]:
		for z: float in axes[1]:
			attempts += 1
			var socket := Vector3(neutral.x, y, z)
			var end := _inside_box([low_x, y - socket_half.y - PAD, z - socket_half.z - PAD,
				high_x, y + socket_half.y + PAD, z + socket_half.z + PAD])
			if end.is_empty():
				empty_placements += 1
				continue
			var pose := Transform3D(Basis.from_scale(end.size), end.position)
			var clear := true
			for obstacle: Dictionary in obstacles:
				if work.satPairs >= MAX_SAT_WORK: return {"ready": false, "reason": "connection_sat_work_limit", "work": work.duplicate()}
				work.satPairs += 1
				var measured: Dictionary = measure_override.call(pose, obstacle.pose) if measure_override.is_valid() else Admission.measure(pose, obstacle.pose)
				if not measured.get("valid", false):
					return {"ready": false, "reason": "invalid_connection_measurement", "measurement": measured,
						"attempts": attempts, "blockingPartId": obstacle.id, "work": work.duplicate()}
				if not measured.get("clear", false):
					clear = false
					blocked_placements.append({"blockingPartId": obstacle.id, "measurement": measured})
					break
			if clear: return {"ready": true, "end": end, "socket": socket,
				"evidence": {"neutralSocket": neutral, "selectedSocket": socket, "socketDomains": domains,
				"attempts": attempts, "nearbyCount": nearby.size(), "foreignCount": obstacles.size(), "axisCandidateCounts": [axes[0].size(), axes[1].size()]}}
	return {"ready": false, "reason": "no_clear_connection_in_socket_domain", "attempts": attempts,
		"emptyPlacementCount": empty_placements, "blockedPlacements": blocked_placements,
		"socketDomains": domains, "nearbyCount": nearby.size(), "work": work.duplicate()}

static func _obstacles(parts: Array) -> Dictionary:
	if parts.size() > 10000: return _fail("foreign_source_limit")
	var boxes: Array = []
	var ids: Dictionary = {}
	for part in parts:
		if not _valid_part(part) or ids.has(part.id): return _fail("invalid_foreign_source")
		ids[part.id] = true
		if not part.collision_enabled: continue
		var pose := Transform3D(Basis.from_euler(part.rotation) * Basis.from_scale(part.size), part.position)
		if not Admission._valid(pose): return _fail("invalid_foreign_pose")
		var bounds: Array = []
		var radii: Array = []
		for axis in range(3):
			var radius := 0.0
			for column in range(3): radius += absf(float(pose.basis[column][axis])) * 0.5
			radii.append(radius)
			bounds.append(float(pose.origin[axis]) - radius)
		for axis in range(3): bounds.append(float(pose.origin[axis]) + radii[axis])
		boxes.append({"id": part.id, "pose": pose, "bounds": bounds})
	boxes.sort_custom(func(a, b): return a.id < b.id)
	return {"ready": true, "boxes": boxes}

static func _overlaps(a: Array, b: Array) -> bool:
	for axis in range(3):
		if a[axis + 3] <= b[axis] or b[axis + 3] <= a[axis]: return false
	return true

static func _represented_inward(value: float, increasing: bool) -> float:
	var represented := float(Vector3(value, 0, 0).x)
	if increasing and represented < value: return ConstructionMath.next_float32_up(represented)
	if not increasing and represented > value: return -ConstructionMath.next_float32_up(-represented)
	return represented

static func _add_candidate(values: Array, value: float, domain: Array) -> void:
	if value >= domain[0] and value <= domain[1] and not values.has(value): values.append(value)

static func _inside_box(bounds: Array) -> Dictionary:
	var center := Vector3.ZERO
	var size := Vector3.ZERO
	for axis in range(3):
		if not is_finite(bounds[axis]) or not is_finite(bounds[axis + 3]) or bounds[axis + 3] <= bounds[axis]: return {}
		center[axis] = (bounds[axis] + bounds[axis + 3]) * 0.5
		size[axis] = 2.0 * minf(float(center[axis]) - bounds[axis], bounds[axis + 3] - float(center[axis]))
		for attempt in range(4):
			if float(center[axis]) - float(size[axis]) * 0.5 >= bounds[axis] and float(center[axis]) + float(size[axis]) * 0.5 <= bounds[axis + 3]: break
			size[axis] = -ConstructionMath.next_float32_up(-float(size[axis]))
		if size[axis] < 0.02 or float(center[axis]) - float(size[axis]) * 0.5 < bounds[axis] or float(center[axis]) + float(size[axis]) * 0.5 > bounds[axis + 3]: return {}
	return {"position": center, "size": size}

static func _bounds(part) -> Array:
	return _bounds_values(part.position, part.size)

static func _valid_part(part) -> bool:
	return part is Part and not part.id.is_empty() and part.position.is_finite() and part.rotation.is_finite() and part.size.is_finite() and part.size.x > 0.0 and part.size.y > 0.0 and part.size.z > 0.0

static func _bounds_values(center: Vector3, size: Vector3) -> Array:
	return [float(center.x) - float(size.x) * 0.5, float(center.y) - float(size.y) * 0.5, float(center.z) - float(size.z) * 0.5,
		float(center.x) + float(size.x) * 0.5, float(center.y) + float(size.y) * 0.5, float(center.z) + float(size.z) * 0.5]

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}

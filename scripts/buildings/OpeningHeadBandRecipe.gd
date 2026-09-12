extends RefCounted

## Unwired single-house prototype. A new timber band replaces an existing full
## masonry strip above an actual opening row. No source mutation or publication.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Layout = preload("res://scripts/buildings/InteriorFurnishingLayout.gd")
const Aperture = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const MasonryCore = preload("res://scripts/buildings/MasonryWallGeometry.gd")
const Materials = preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const BoxAdmission = preload("res://scripts/buildings/ConstructionBoxAdmission.gd")
const ReplacementOccupancy = preload("res://scripts/buildings/ReplacementBoxOccupancy.gd")
const Connections = preload("res://scripts/buildings/OpeningHeadConnectionRecipe.gd")
const ReplacementAdmission = preload("res://scripts/buildings/OpeningHeadReplacementAdmission.gd")
const ConstructionMath = preload("res://scripts/buildings/ConstructionSeamMath.gd")
const HEADER_HEIGHT := 0.24
const EDGE_EPS := ConstructionMath.EDGE_EPS # grouping represented panel edges only, not joint forgiveness.
const SOCKET_HALF := Vector3(0.04, 0.04, 0.07)
const SOCKET_INSET := 0.02

static func prepare_all_first_rows(b, policy: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	if continuation.is_valid() and continuation.call("opening_heads_started") != true: return _fail("cancelled")
	var membership := Copy.street_house_memberships(b)
	if not membership.ready: return membership
	if membership.houses.is_empty(): return _fail("no_declared_houses")
	var callback: Variant = policy.get("progressCallback", Callable())
	if not callback is Callable: return _fail("invalid_progress_callback")
	var staged = Copy.copy_blueprint(b.snapshot())
	var proposals: Array = []
	var trimmed: Array = []
	for house in membership.houses:
		if continuation.is_valid() and continuation.call("opening_head_house:" + String(house.prefix)) != true: return _fail("cancelled")
		if callback.is_valid(): callback.call(house.prefix)
		var proposal := _prepare_first(staged, house.memberIds, policy, continuation, true)
		if proposal.get("reason", "") == "cancelled": return proposal
		if continuation.is_valid() and continuation.call("opening_head_house_completed:" + String(house.prefix)) != true: return _fail("cancelled")
		if not proposal.ready:
			return {"ready": false, "reason": proposal.reason, "failedHouse": house.prefix, "completedHouseCount": proposals.size(), "failureEvidence": proposal}
		# This candidate is owned by the batch. A failed house or cancellation
		# discards it; only the final ordered snapshot crosses the public boundary.
		staged = proposal.candidateSnapshot
		trimmed.append_array(proposal.trimmedPanelIds)
		proposal.erase("candidateSnapshot")
		proposal["house"] = house.prefix
		proposals.append(proposal)
	if continuation.is_valid() and continuation.call("opening_heads_completed") != true: return _fail("cancelled")
	return {"ready": true, "candidateSnapshot": staged.snapshot(), "houseProposals": proposals, "trimmedPanelIds": trimmed}

static func prepare_first(b, producer_ids: Array, policy: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	return _prepare_first(b, producer_ids, policy, continuation, false)

static func _prepare_first(b, producer_ids: Array, policy: Dictionary, continuation: Callable, retain_candidate: bool) -> Dictionary:
	if b == null or b.parts.size() > 10000 or producer_ids.is_empty() or producer_ids.size() > 512:
		return _fail("source_limit")
	if not policy.get("furnitureParts") is Array or not policy.get("reservedVolumes") is Array or not policy.get("requiredHeadroom") is float or not is_finite(policy.requiredHeadroom) or policy.requiredHeadroom <= 0.0:
		return _fail("invalid_clearance_policy")
	var source: Dictionary = {} if retain_candidate else b.snapshot()
	var by_id: Dictionary = {}
	for part in b.parts:
		if part == null or by_id.has(part.id) or not b.has_finite_positive_bounds(part): return _fail("invalid_source")
		by_id[part.id] = part
	var owned: Dictionary = {}
	var doors: Array = []
	var panels: Array = []
	for id in producer_ids:
		if not id is String or not by_id.has(id) or owned.has(id): return _fail("invalid_producer_membership")
		owned[id] = true
		if by_id[id].semantic == "citadel_urban_door": doors.append(by_id[id])
		if by_id[id].semantic == "citadel_urban_facade": panels.append(by_id[id])
	if doors.size() != 1 or panels.is_empty() or not doors[0].id.ends_with("_door"): return _fail("missing_house_declaration")
	var prefix: String = doors[0].id.trim_suffix("_door")
	if producer_ids.any(func(id): return not id.begins_with(prefix + "_")): return _fail("foreign_producer_member")
	var gables: Array = []
	for suffix in ["_upper_shell_side_-1", "_upper_shell_side_1"]:
		if not owned.has(prefix + suffix): return _fail("missing_gable")
		var gable = by_id[prefix + suffix]
		if gable.kind != "wall" or not gable.collision_enabled or gable.rotation != Vector3.ZERO or not Materials.is_masonry_material(gable.material_id): return _fail("invalid_gable")
		gables.append(gable)
	var plane = panels[0]
	for panel in panels:
		if panel.kind != "wall" or not panel.collision_enabled or panel.rotation != Vector3.ZERO or panel.position.x != plane.position.x or panel.size.x != plane.size.x: return _fail("inconsistent_facade_plane")
	var declarations := _declarations(b, by_id, panels, prefix)
	if not declarations.ready: return declarations
	var discovery := _first_full_head_row(panels)
	if not discovery.ready: return discovery
	var aperture_sources := _trim_aperture_sources(b, by_id, discovery.panelIds, declarations.declarationKeys)
	if not aperture_sources.ready: return aperture_sources
	var header_id := prefix + "_opening_head_band_000"
	if by_id.has(header_id): return _fail("header_already_exists")
	var side := signf(doors[0].position.x - gables[0].position.x)
	if side == 0.0: return _fail("ambiguous_frontage")
	var outer: float = plane.position.x + side * plane.size.x * 0.5
	var socket_x: Array[float] = []
	var inner := outer
	for gable in gables:
		var core_size := MasonryCore.bed_size(gable.size)
		if core_size.x <= 2.0 * (SOCKET_HALF.x + SOCKET_INSET) or core_size.z <= 2.0 * (SOCKET_HALF.z + SOCKET_INSET): return _fail("masonry_core_too_small_for_socket")
		var socket: float = gable.position.x + side * (core_size.x * 0.5 - SOCKET_HALF.x - SOCKET_INSET)
		socket_x.append(socket)
		var edge: float = socket - side * (SOCKET_HALF.x + SOCKET_INSET)
		inner = minf(inner, edge) if side > 0.0 else maxf(inner, edge)
	var centre := Vector3((inner + outer) * 0.5, discovery.bottom + HEADER_HEIGHT * 0.5, (discovery.near + discovery.far) * 0.5)
	var size := Vector3(absf(outer - inner), HEADER_HEIGHT, discovery.far - discovery.near)
	var required_bottom: float = discovery.bottom
	for volume in declarations.volumes:
		# Discovery may group represented edges; actual construction must remain
		# above the authoritative aperture, with no overlap tolerance.
		if volume.end.y <= discovery.bottom + EDGE_EPS and volume.end.z > discovery.near and volume.position.z < discovery.far:
			required_bottom = maxf(required_bottom, volume.end.y)
	centre.y = required_bottom + float(size.y) * 0.5
	for attempt in range(4):
		if float(centre.y) - float(size.y) * 0.5 >= required_bottom and (centre - size * 0.5).y >= required_bottom: break
		centre.y = _next_float32_up(centre.y)
	if float(centre.y) - float(size.y) * 0.5 < required_bottom or (centre - size * 0.5).y < required_bottom: return _fail("unrepresentable_aperture_head")
	var facts: Array = []
	for index in range(gables.size()):
		facts.append({"seatId": gables[index].id, "contactMode": "housed_overlap", "localSpanAxis": "z",
			"localOverlapCenter": Vector3(socket_x[index], centre.y, gables[index].position.z) - centre,
			"localOverlapHalfExtents": SOCKET_HALF, "minimumLongitudinalEmbedment": 0.12, "minimumVerticalOverlap": 0.04})
	var header := {"id": header_id, "kind": "beam", "material": "timber_beam", "position": centre, "size": size,
		"collision": true, "semantic": "citadel_opening_head_band", "physicalIntent": "structural_mass",
		"recipe": {"physicalIntent": "structural_mass", "preserveBearingFaces": true,
			"variation": doors[0].recipe.get("variation", 0.0), "physicalRequiredSeatPartIds": gables.map(func(g): return g.id), "physicalRequiredSeatFacts": facts}}
	var header_bounds := AABB(centre - size * 0.5, size)
	for volume in declarations.volumes:
		if _penetrates(header_bounds, volume): return {"ready": false, "reason": "declared_aperture_blocked", "geometryConflict": {"proposedBounds": header_bounds, "protectedVolume": volume, "positiveOverlap": header_bounds.end.min(volume.end) - header_bounds.position.max(volume.position), "overlapY": float(minf(header_bounds.end.y, volume.end.y) - maxf(header_bounds.position.y, volume.position.y))}}
	var staged = _house_candidate(b, by_id, discovery.panelIds) if retain_candidate else Copy.copy_blueprint(source)
	var trimmed: Array = []
	var trim_geometry: Array = []
	for id in discovery.panelIds:
		var panel = staged.find_part(id)
		var original_panel: Dictionary = panel.snapshot()
		var original_bounds := AABB(panel.position - panel.size * 0.5, panel.size)
		for key in panel.recipe:
			if String(key).begins_with("physicalRequired") and not (panel.recipe[key] is Array and panel.recipe[key].is_empty()): return _fail("existing_explicit_panel_contract")
		var top: float = original_bounds.end.y
		var bottom: float = header_bounds.end.y
		if top - bottom < 0.04: return _fail("insufficient_remaining_panel")
		panel.position.y = (top + bottom) * 0.5
		# Limit height from the stored centre and the represented original top,
		# not an ideal double-precision centre that the Vector3 cannot retain.
		panel.size.y = 2.0 * minf(float(panel.position.y) - bottom, float(original_bounds.end.y) - float(panel.position.y))
		# Round the replacement panel inward, never beyond either requested face.
		# This is actual geometry construction, not tolerance in the validator.
		for attempt in range(4):
			var represented := AABB(panel.position - panel.size * 0.5, panel.size)
			if represented.position.y >= bottom and represented.end.y <= original_bounds.end.y: break
			panel.size.y = -_next_float32_up(-float(panel.size.y))
		var fitted_panel := fit_retained_panel(Blueprint.BuildingPartScript.new(original_panel), panel)
		if not fitted_panel.ready: return fitted_panel
		panel.position = fitted_panel.position
		panel.size = fitted_panel.size
		var actual_bounds := AABB(panel.position - panel.size * 0.5, panel.size)
		if actual_bounds.position.x != original_bounds.position.x or actual_bounds.position.z != original_bounds.position.z or actual_bounds.size.x != original_bounds.size.x or actual_bounds.size.z != original_bounds.size.z or actual_bounds.position.y < bottom or actual_bounds.end.y > original_bounds.end.y: return {"ready": false, "reason": "trim_expands_represented_geometry", "trimConflict": {"id": id, "requestedBottom": bottom, "originalTop": float(original_bounds.end.y), "actualBottom": float(actual_bounds.position.y), "actualTop": float(actual_bounds.end.y)}}
		for volume in declarations.volumes:
			if _penetrates(actual_bounds, volume):
				return {"ready": false, "reason": "trimmed_panel_blocks_aperture", "geometryConflict": {
					"partId": id, "originalPanel": original_panel, "trimmedPanel": panel.snapshot(),
					"actualBounds": actual_bounds, "protectedVolume": volume,
					"positiveOverlap": actual_bounds.end.min(volume.end) - actual_bounds.position.max(volume.position)}}
		trim_geometry.append({"id": id, "before": original_bounds, "after": actual_bounds})
		Copy.Frame._clean_derived(panel)
		# Reference the bound declaration; never copy aperture geometry into parts.
		panel.recipe["masonryApertureSource"] = aperture_sources.sources[id]
		var half_patch := Vector2(minf(0.06, panel.size.x * 0.5 - 0.06), minf(0.06, panel.size.z * 0.5 - 0.06))
		if half_patch.x <= 0.0 or half_patch.y <= 0.0: return _fail("panel_too_narrow_for_bearing_patch")
		panel.recipe["physicalRequiredSeatPartIds"] = [header_id]
		panel.recipe["physicalRequiredSeatFacts"] = [{"seatId": header_id, "loadDirection": "world_down", "seatFace": "max_y",
			"localPatchCenter": Vector3(0.0, -panel.size.y * 0.5, 0.0), "localPatchHalfExtents": half_patch}]
		trimmed.append(id)
	# Trim geometry establishes the actual available strip; the shared recipe
	# then fits a shallow body and bounded transverse/direct masonry joints.
	var gable_ids: Array = gables.map(func(g): return g.id)
	var obstacles: Array = b.parts.filter(func(p): return p.collision_enabled and not trimmed.has(p.id) and not gable_ids.has(p.id))
	var arrangement := Connections.prepare(header, plane, gables, obstacles, trimmed.map(func(id): return staged.find_part(id)), b)
	if not arrangement.ready: return arrangement
	header = arrangement.body
	header_bounds = AABB(header.position - header.size * 0.5, header.size)
	var pieces: Array = [header] + arrangement.connections
	var clearance: Dictionary = {}
	for record: Dictionary in pieces:
		var bounds := AABB(record.position - record.size * 0.5, record.size)
		for volume in declarations.volumes:
			if _penetrates(bounds, volume): return _fail("declared_aperture_blocked")
		var piece_clearance := _clearance(b, bounds, prefix, policy)
		if not piece_clearance.ready: return piece_clearance
		clearance[record.id] = piece_clearance
	# Do not exempt whole adopted walls: body contacts are accounted against
	# removed source masonry and explicit construction seams. Own new joints
	# are installed only after their independent finite-contact validation.
	var solid_admission := ReplacementAdmission.evaluate(b, staged, header, trimmed, [], declarations.volumes)
	if not solid_admission.ready: return solid_admission
	var end_admissions: Array = []
	for record: Dictionary in arrangement.connections:
		var admitted := _foreign_solid_admission(b, record, trimmed, gable_ids)
		if not admitted.ready: return admitted
		end_admissions.append(admitted)
	var support_ids: Array = producer_ids.duplicate()
	var root_ids: Array = gable_ids.duplicate()
	for direct: Dictionary in arrangement.directSeats:
		if not root_ids.has(direct.fact.seatId): root_ids.append(direct.fact.seatId)
		for id: String in direct.rootProof.independentMemberIds:
			if not support_ids.has(id): support_ids.append(id)
	support_ids.sort()
	var support = Blueprint.new(prefix + "_independent_support", b.seed, b.style)
	for id: String in support_ids:
		if by_id[id].semantic not in ["citadel_urban_facade", "citadel_opening_head_band", "citadel_opening_head_connection"]: support.add_part(by_id[id].snapshot())
	Copy.clear_caches(support)
	if not Copy.validation_grid_work(support).ready: return _fail("support_grid_limit")
	var independent: Dictionary = support.validate_physical_integrity_cancellable(continuation)
	if independent.get("cancelled", false): return _fail("cancelled")
	var roots: Array = independent.checks.filter(func(c): return root_ids.has(c.partId))
	if roots.size() != root_ids.size() or not roots.all(func(c): return c.passed and c.reachesGroundRoot): return _fail("terminal_not_independently_rooted")
	for record: Dictionary in pieces: support.add_part(record)
	Copy.clear_caches(support)
	var joint_report: Dictionary = support.validate_physical_integrity_cancellable(continuation)
	if joint_report.get("cancelled", false): return _fail("cancelled")
	var piece_ids: Array = pieces.map(func(p): return p.id)
	var joint_checks: Array = joint_report.checks.filter(func(c): return piece_ids.has(c.partId))
	if joint_checks.size() != piece_ids.size() or not joint_checks.all(func(c): return c.passed): return _fail("finite_housed_end_joint_failed")
	var header_check: Array = joint_checks.filter(func(c): return c.partId == header_id)
	for record: Dictionary in pieces:
		var part = staged.add_part(record)
		if retain_candidate: staged.physical_parts_by_id[part.id] = part
	for id in trimmed: support.add_part(staged.find_part(id).snapshot())
	Copy.clear_caches(support)
	var seated_report: Dictionary = support.validate_physical_integrity_cancellable(continuation)
	if seated_report.get("cancelled", false): return _fail("cancelled")
	var seated: Array = seated_report.checks.filter(func(check): return trimmed.has(check.partId))
	if seated.size() != trimmed.size() or not seated.all(func(check): return check.passed): return _fail("trimmed_panel_gravity_seat_failed")
	for key in declarations.declarationKeys:
		var declaration: Dictionary = staged.recipe.facadeApertures[key].duplicate(true)
		declaration.erase("sourceBinding")
		staged.recipe.facadeApertures[key] = Aperture.seal(declaration, declaration.partIds.map(func(id): return staged.find_part(id)))
	return {"ready": true, "candidateSnapshot": staged if retain_candidate else staged.snapshot(), "headerId": header_id,
		"apertureProof": {"declarationKeys": declarations.declarationKeys, "fullVolumeCount": declarations.volumes.size(), "positiveHeaderIntersections": 0},
		"constructionSeamChanges": solid_admission.get("seamCells", []),
		"headConstruction": {"requiredBottom": required_bottom, "actualBottom": float(header_bounds.position.y), "actualTop": float(header_bounds.end.y)},
		"trimGeometry": trim_geometry, "trimmedPanelSeatChecks": seated,
		"trimmedPanelIds": trimmed, "discovery": discovery, "header": header, "clearance": clearance, "foreignSolidAdmission": solid_admission,
		"connectionArrangement": arrangement, "connectionIds": arrangement.connections.map(func(p): return p.id), "endAdmissions": end_admissions, "jointChecks": joint_checks,
		"independentGableChecks": independent.checks.filter(func(check): return gables.any(func(g): return g.id == check.partId)),
		"headerCheck": header_check[0], "scope": "Unwired source prototype. No full regression, published material-transition, swept-door, visual or integration acceptance."}

static func _house_candidate(source, by_id: Dictionary, panel_ids: Array):
	# The batch admitted a complete private copy at entry. Unchanged objects
	# remain read-only throughout this house; only panels and aperture metadata
	# are edited. All physical classification runs on separate proof blueprints.
	var candidate = Blueprint.new(source.id, source.seed, source.style)
	candidate.recipe = source.recipe.duplicate(true)
	candidate.rooms = source.rooms
	candidate.parts = source.parts.duplicate()
	candidate.physical_parts_by_id = by_id.duplicate()
	var records: Array = panel_ids.map(func(id): return by_id[id].snapshot())
	var replacements = Copy.copy_blueprint({"id": source.id, "seed": source.seed, "style": source.style,
		"recipe": {}, "rooms": [], "parts": records})
	for index in range(candidate.parts.size()):
		var id: String = candidate.parts[index].id
		if replacements.physical_parts_by_id.has(id):
			candidate.parts[index] = replacements.find_part(id)
			candidate.physical_parts_by_id[id] = candidate.parts[index]
	return candidate

static func _trim_aperture_sources(b, by_id: Dictionary, ids: Array, allowed_keys: Array) -> Dictionary:
	var records: Variant = b.recipe.get("facadeApertures")
	if not records is Dictionary: return _fail("missing_or_invalid_apertures")
	var sources: Dictionary = {}
	for id: Variant in ids:
		if not id is String or not by_id.has(id) or sources.has(id): return _fail("invalid_trim_membership")
		var panel = by_id[id]
		if panel.recipe.has("masonryApertureSource"): return _fail("existing_masonry_aperture_source")
		if panel.kind != "wall" or not Materials.is_masonry_material(panel.material_id): return _fail("trim_not_masonry")
		var owners: Array = []
		for key: Variant in records:
			var record: Variant = records[key]
			if record is Dictionary and record.get("partIds") is Array:
				for member: Variant in record.partIds:
					if member == id: owners.append(key)
		if owners.size() != 1: return _fail("ambiguous_trim_aperture_source")
		var owner: Variant = owners[0]
		if not owner is String or not allowed_keys.has(owner): return _fail("foreign_trim_aperture_source")
		var declaration: Dictionary = records[owner]
		if declaration.get("producerPrefix") != owner or declaration.get("semantic") != panel.semantic or not id.begins_with(owner + "_") or not Aperture.validate(declaration, by_id): return _fail("invalid_trim_aperture_source")
		sources[id] = owner
	return {"ready": true, "sources": sources}

## Retain the represented original solid exactly; float32 AABB endpoint
## reconstruction is not permission to grow the upper face of a trimmed panel.
static func fit_retained_panel(original, retained) -> Dictionary:
	if original == null or retained == null or original.kind != "wall" or retained.kind != "wall" or original.rotation != Vector3.ZERO or retained.rotation != Vector3.ZERO or not original.position.is_finite() or not original.size.is_finite() or not retained.position.is_finite() or not retained.size.is_finite(): return _fail("invalid_retained_fit_input")
	if original.position.x != retained.position.x or original.position.z != retained.position.z or original.size.x != retained.size.x or original.size.z != retained.size.z: return _fail("retained_fit_changes_horizontal_geometry")
	var low := maxf(float(original.position.y) - float(original.size.y) * 0.5, float(retained.position.y) - float(retained.size.y) * 0.5)
	var high := minf(float(original.position.y) + float(original.size.y) * 0.5, float(retained.position.y) + float(retained.size.y) * 0.5)
	if high - low < 0.04: return _fail("insufficient_retained_panel")
	var center: Vector3 = retained.position
	var size: Vector3 = retained.size
	if float(center.y) - float(size.y) * 0.5 < low or float(center.y) + float(size.y) * 0.5 > high:
		# Preserve the lower bearing face exactly. Rounding the centre upward
		# then shortening from the upper face can lift the panel off its beam.
		# Bias the centre inward/down and shorten only the non-bearing top.
		var midpoint: float = (low + high) * 0.5
		center.y = midpoint
		if float(center.y) > midpoint: center.y = -_next_float32_up(-float(center.y))
		size.y = 2.0 * (float(center.y) - low)
	if size.y < 0.04 or float(center.y) - float(size.y) * 0.5 != low or float(center.y) + float(size.y) * 0.5 > high: return _fail("unrepresentable_retained_panel")
	return {"ready": true, "position": center, "size": size, "desiredLow": low, "desiredHigh": high,
		"actualLow": float(center.y) - float(size.y) * 0.5, "actualHigh": float(center.y) + float(size.y) * 0.5}

static func _declarations(b, by_id: Dictionary, panels: Array, prefix: String) -> Dictionary:
	var records: Variant = b.recipe.get("facadeApertures")
	if not records is Dictionary or records.size() > 256: return _fail("missing_or_invalid_apertures")
	var keys: Array = []
	var covered: Dictionary = {}
	var volumes: Array = []
	for key in records:
		if not key is String: return _fail("invalid_aperture_key")
		if not key.begins_with(prefix + "_"): continue
		var record: Variant = records[key]
		if not Aperture.validate(record, by_id): return _fail("stale_aperture_declaration")
		if record.get("producerPrefix") != key or not record.get("semantic") is String or not record.get("wallDomain") is AABB or not Copy.Frame._valid_bounds(record.wallDomain) or not record.get("openings") is Array or record.openings.size() > 128: return _fail("invalid_aperture_declaration")
		for id in record.partIds:
			if not id.begins_with(key + "_") or by_id[id].semantic != record.semantic: return _fail("conflicting_aperture_membership")
			if panels.has(by_id[id]):
				if covered.has(id): return _fail("conflicting_aperture_membership")
				covered[id] = true
		var opening_ids: Dictionary = {}
		for opening in record.openings:
			if not opening is Dictionary or not opening.get("id") is String or opening_ids.has(opening.id) or not opening.get("input") is Dictionary or not opening.get("fullVolume") is AABB or not Copy.Frame._valid_bounds(opening.fullVolume): return _fail("invalid_aperture_volume")
			opening_ids[opening.id] = true
			var input: Dictionary = opening.input
			for field in ["centerY", "centerZ", "height", "width"]:
				if not (input.get(field) is float or input.get(field) is int) or not is_finite(float(input[field])): return _fail("invalid_aperture_input")
			if input.height <= 0.0 or input.width <= 0.0: return _fail("invalid_aperture_input")
			var domain: AABB = record.wallDomain
			var expected := AABB(Vector3(domain.position.x, input.centerY - input.height * 0.5, input.centerZ - input.width * 0.5), Vector3(domain.size.x, input.height, input.width))
			if opening.fullVolume != expected: return _fail("conflicting_aperture_volume")
			volumes.append(opening.fullVolume)
		keys.append(key)
	if covered.size() != panels.size() or keys.is_empty() or volumes.is_empty(): return _fail("incomplete_aperture_membership")
	keys.sort()
	return {"ready": true, "declarationKeys": keys, "volumes": volumes}

## Exact represented solid difference inside the old facade slab. No tolerance
## removes cells from this ledger. Only construction-width seams may be filled;
## declared aperture protection above uses strict positive intersection.
static func _construction_seams(header: AABB, panels: Array) -> Dictionary:
	var slab := header
	slab.position.x = panels[0].position.x - panels[0].size.x * 0.5
	slab.size.x = panels[0].size.x
	var cells: Array = [slab]
	for panel in panels:
		var old := AABB(panel.position - panel.size * 0.5, panel.size)
		var next: Array = []
		for cell in cells:
			next.append_array(_subtract_box(cell, old))
			if next.size() > 4096: return _fail("seam_partition_limit")
		cells = next
	for cell in cells:
		if not Copy.Frame._valid_bounds(cell): return _fail("invalid_seam_cell")
		if minf(cell.size.y, cell.size.z) > EDGE_EPS: return _fail("undeclared_facade_void_would_be_filled")
	return {"ready": true, "addedSolidCells": cells}

## The same construction-seam policy, measured without narrowing the represented
## Part faces into float32 AABB endpoints. These are real added cells, not a
## tolerance waiver: the replacement admission must account for each of them.
static func construction_seam_cells(bounds: Array, panels: Array) -> Dictionary:
	return ConstructionMath.construction_seam_cells(bounds, panels)

static func _subtract_box(source: AABB, cutter: AABB) -> Array:
	if not _penetrates(source, cutter): return [source]
	var low := source.position.max(cutter.position)
	var high := source.end.min(cutter.end)
	var result: Array = []
	var remaining := source
	for axis in range(3):
		if low[axis] > remaining.position[axis]:
			var left := remaining
			left.size[axis] = low[axis] - remaining.position[axis]
			result.append(left)
			var end := remaining.end
			remaining.position[axis] = low[axis]
			remaining.size = end - remaining.position
		if high[axis] < remaining.end[axis]:
			var right := remaining
			right.position[axis] = high[axis]
			right.size[axis] = remaining.end[axis] - high[axis]
			result.append(right)
			remaining.size[axis] = high[axis] - remaining.position[axis]
	return result

static func _next_float32_up(value: float) -> float:
	return ConstructionMath.next_float32_up(value)

static func _first_full_head_row(panels: Array) -> Dictionary:
	var raw_edges: Array[float] = []
	var near := INF
	var far := -INF
	for panel in panels:
		raw_edges.append(panel.position.y - panel.size.y * 0.5)
		raw_edges.append(panel.position.y + panel.size.y * 0.5)
		near = minf(near, panel.position.z - panel.size.z * 0.5)
		far = maxf(far, panel.position.z + panel.size.z * 0.5)
	raw_edges.sort()
	var edges: Array[float] = []
	for edge in raw_edges:
		if edges.is_empty() or edge - edges.back() > EDGE_EPS: edges.append(edge)
	for index in range(1, edges.size() - 1):
		if edges[index + 1] - edges[index] < HEADER_HEIGHT + 0.04: continue
		var row := _row_at(panels, (edges[index] + edges[index + 1]) * 0.5)
		var below := _row_at(panels, (edges[index - 1] + edges[index]) * 0.5)
		var voids := _gaps(below, near, far)
		if row.is_empty() or not _gaps(row, near, far).is_empty() or voids.is_empty(): continue
		if row.any(func(panel): return absf(panel.position.y - panel.size.y * 0.5 - edges[index]) > EDGE_EPS): continue
		return {"ready": true, "bottom": edges[index], "near": near, "far": far, "panelIds": row.map(func(p): return p.id),
			"openingRowBottom": edges[index - 1], "openingSpans": voids, "edgeGroupingArithmetic": EDGE_EPS}
	return _fail("no_full_solid_opening_head_row")

static func _row_at(panels: Array, y: float) -> Array:
	var row := panels.filter(func(p): return y > p.position.y - p.size.y * 0.5 and y < p.position.y + p.size.y * 0.5)
	row.sort_custom(func(a, c): return a.position.z < c.position.z)
	return row

static func _gaps(row: Array, near: float, far: float) -> Array:
	var cursor := near
	var gaps: Array = []
	for panel in row:
		var start: float = panel.position.z - panel.size.z * 0.5
		if start > cursor + EDGE_EPS: gaps.append(Vector2(cursor, start))
		cursor = maxf(cursor, panel.position.z + panel.size.z * 0.5)
	if far > cursor + EDGE_EPS: gaps.append(Vector2(cursor, far))
	return gaps

static func _clearance(b, bounds: AABB, prefix: String, policy: Dictionary) -> Dictionary:
	if policy.furnitureParts.size() + policy.reservedVolumes.size() > 2048: return _fail("reservation_limit")
	for record in policy.furnitureParts:
		var occupied: Dictionary = Copy.Frame.furnishing_bounds(record)
		if not occupied.ready: return occupied
		if _penetrates(bounds.grow(0.01), occupied.bounds): return _fail("furniture_blocked:" + String(record.get("id", "")))
	for volume in policy.reservedVolumes:
		if not volume is AABB or not Copy.Frame._valid_bounds(volume): return _fail("invalid_reservation")
		if _penetrates(bounds.grow(0.01), volume): return _fail("protected_reservation_blocked")
	var room_found := false
	for room in b.rooms:
		if not room is Dictionary: return _fail("invalid_room")
		if room.get("id", "") != prefix + "_interior": continue
		if not room.get("bounds") is AABB or not Copy.Frame._valid_bounds(room.bounds) or not room.get("accesses") is Array: return _fail("invalid_room_geometry")
		room_found = true
		for access in room.get("accesses", []):
			if not access is Dictionary or not access.get("position") is Vector3 or not access.position.is_finite(): return _fail("invalid_access_position")
			var access_size: Variant = access.get("furnishingSize", access.get("size"))
			if not access_size is Vector3 or not Copy.Frame._valid_bounds(AABB(Vector3.ZERO, access_size)): return _fail("invalid_access_size")
			if _penetrates(bounds.grow(0.01), Layout.access_reservation(access)): return _fail("declared_access_blocked")
		var floor = null
		for part in b.parts:
			if part.id == prefix + "_interior_floor": floor = part
		if floor == null or floor.kind != "floor" or not floor.collision_enabled or floor.rotation != Vector3.ZERO: return _fail("invalid_floor_headroom_datum")
		if bounds.position.y < floor.position.y + floor.size.y * 0.5 + policy.requiredHeadroom: return _fail("ground_floor_headroom_blocked")
	if not room_found: return _fail("missing_room")
	for part in b.parts:
		if part.kind not in ["door", "window", "crate", "barrel", "tool_rack", "basket", "sack", "sign"]: continue
		if _penetrates(bounds.grow(0.01), b.transformed_part_bounds(part)): return _fail("source_opening_or_contents_blocked:" + part.id)
	return {"ready": true, "preservedFurnitureCount": policy.furnitureParts.size(), "protectedReservationCount": policy.reservedVolumes.size(),
		"requiredGroundFloorHeadroom": policy.requiredHeadroom, "limitation": "Source bounds and declared access, not actual published/swept geometry or upper-floor circulation proof."}

static func _foreign_solid_admission(b, header: Dictionary, replaced_ids: Array, seat_ids: Array) -> Dictionary:
	# Only the explicitly replaced panels and geometrically proved end seats
	# may share this new material. Same-house identity is not an exclusion.
	var candidate := Blueprint.BuildingPartScript.new(header)
	var transform: Transform3D = b.part_transform(candidate) * Transform3D(Basis.from_scale(candidate.size), Vector3.ZERO)
	var tested := 0
	for part in b.parts:
		if not part.collision_enabled or replaced_ids.has(part.id) or seat_ids.has(part.id): continue
		tested += 1
		var other: Transform3D = b.part_transform(part) * Transform3D(Basis.from_scale(part.size), Vector3.ZERO)
		var result := BoxAdmission.measure(transform, other)
		if not result.valid or not result.clear:
			return {"ready": false, "reason": "foreign_solid_header_no_fit", "blockingPartId": part.id,
				"candidate": header, "sourceBoxMeasurement": result, "testedSolidCount": tested,
				"scope": "Source collision boxes only; all kinds included, no surrounding source changed."}
	return {"ready": true, "testedSolidCount": tested, "scope": "Source collision boxes only; render, changed-panel and swept-door checks remain separate."}

static func _penetrates(a: AABB, c: AABB) -> bool:
	var overlap := a.end.min(c.end) - a.position.max(c.position)
	return overlap.x > 0.0 and overlap.y > 0.0 and overlap.z > 0.0

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}

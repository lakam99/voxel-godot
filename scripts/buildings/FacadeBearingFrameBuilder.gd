extends RefCounted

## Unwired, bounded exterior bearing-bay recipe. This is NOT a whole-facade
## opening/header solver: members must form one continuous coplanar bottom row.
## add_frame(b, member_ids, policy) stages privately, then commits atomically.
## policy: outward (cardinal horizontal Vector3), foundationPartIds (Array),
## reservedVolumes (Array[AABB]), furnitureParts (Array of actual snapshots),
## clearance (positive metres, default .01). Both reservation arrays REQUIRED.
## Direct APIs require collision-backed grounded masonry. add_frame_on_support
## additionally accepts an actual paving/floor stack with a complete, freshly
## verified ground-root closure. The selected finite seat must resolve to
## structural_mass/root; walkable-only upstream layers still require 25-point
## coverage. No supplied root flag creates a ground root.
## Success appends parts without rebuilding the caller's derived indices/caches;
## the caller must rebuild its lookup before find_part, then validate integration.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Seats = preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
const Materials = preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const DoorGeometry = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const PavingAssembly = preload("res://scripts/buildings/PavingFootingAssemblyRecipe.gd")
# Reuse the existing bounded mandatory-seat schema and spatial-work guard;
# no terminal geometry is constructed through this dependency.
const SupportContracts = preload("res://scripts/buildings/TerminalShopFrameBuilder.gd")
const MAX_PARTS := 10000
const MAX_MEMBERS := 24
const MAX_RESERVATIONS := 2048
const POST_WIDTH := 0.24
const FOOT_WIDTH := 0.36
const FOOT_HEIGHT := 0.20
const SILL_HEIGHT := 0.24
const PATCH_HALF := 0.06
const EPS := 0.00001 # represented arithmetic only, not clearance forgiveness
const PIER_CAP_SPAN := POST_WIDTH * 2.0
const MAX_SUPPORT_CLOSURE := 32


static func add_frame(b, member_ids: Array, policy: Dictionary) -> Dictionary:
	return _add_frame(b, member_ids, policy, false)


static func add_narrow_pier(b, member_id: String, policy: Dictionary) -> Dictionary:
	return _add_frame(b, [member_id], policy, true)


static func add_frame_on_support(b, member_ids: Array, policy: Dictionary, support_id: String, upstream_ids: Array, narrow := false) -> Dictionary:
	var closure := validate_support_closure(b, support_id, upstream_ids)
	if not closure.ready: return closure
	for id in member_ids:
		if closure.partIds.has(id): return _failure("support_closure_contains_frame_member")
	var bound_policy := policy.duplicate(true)
	bound_policy["foundationPartIds"] = [support_id]
	return _add_frame(b, member_ids, bound_policy, narrow, closure)


static func validate_support_closure(b, support_id: String, upstream_ids: Array) -> Dictionary:
	if b == null or b.parts.size() > MAX_PARTS or support_id.is_empty() or upstream_ids.size() >= MAX_SUPPORT_CLOSURE: return _failure("support_closure_limit")
	var ids: Array = [support_id]
	for id in upstream_ids:
		if not id is String or id.is_empty() or ids.has(id): return _failure("invalid_support_closure_ids")
		ids.append(id)
	var originals: Dictionary = {}
	for part in b.parts:
		if part == null or originals.has(part.id): return _failure("invalid_support_source")
		originals[part.id] = part
	var staged = Blueprint.new(b.id, b.seed, b.style)
	var roots: Array = []
	for id in ids:
		if not originals.has(id): return _failure("missing_support_closure_part")
		var part = originals[id]
		if not b.has_finite_positive_bounds(part) or not part.collision_enabled or part.rotation != Vector3.ZERO or part.kind not in ["foundation", "floor"]: return _failure("invalid_support_closure_geometry")
		var intent_proof := support_source_intent(b, part)
		if not intent_proof.ready: return intent_proof
		var resolved_intent: String = intent_proof.intent
		# Finite-seat authority accepts structural mass/root, not a walkable-only
		# surface. Navigation role does not determine this physical intent.
		if id == support_id and resolved_intent not in ["structural_mass", "structural_root"]: return _failure("unsupported_bearing_intent")
		if not Materials.is_masonry_material(part.material_id) and not Materials.is_cobble_material(part.material_id): return _failure("support_requires_masonry_or_paving")
		var grounded: bool = b.is_grounded_structural_root(part) and absf(_bounds(part).position.y) <= EPS
		var root_flag: Variant = part.recipe.get("physicalRoot", false)
		if not root_flag is bool or (not grounded and (root_flag or resolved_intent == "structural_root")): return _failure("forged_support_root")
		if grounded:
			if Materials.is_cobble_material(part.material_id): return _failure("ground_root_requires_structural_masonry")
			roots.append(id)
		if not SupportContracts._support_schema_valid(part.recipe, ids): return _failure("invalid_support_closure_schema")
		var copy = staged.add_part(part.snapshot())
		copy.physical_intent = resolved_intent
		_clean_derived(copy)
	if roots.is_empty(): return _failure("support_closure_has_no_actual_ground_root")
	var guard: Dictionary = SupportContracts._validation_work(staged)
	if not guard.ready: return guard
	var physical: Dictionary = staged.validate_physical_integrity()
	if physical.checks.size() != ids.size() or not physical.violations.is_empty(): return {"ready": false, "reason": "source_support_closure_invalid", "physical": physical}
	var proof := _closure_contacts(staged, ids, roots, support_id)
	if not proof.ready: return proof
	return {"ready": true, "partIds": ids, "rootIds": roots, "supportId": support_id, "supportTop": _bounds(originals[support_id]).end.y, "physical": physical, "coverage": proof.coverage, "edges": proof.edges}


static func support_source_intent(b, part) -> Dictionary:
	var recipe_intent: Variant = part.recipe.get("physicalIntent", "")
	var allowed := ["", "structural_mass", "structural_root", "walkable_surface"]
	if not recipe_intent is String or recipe_intent not in allowed or part.physical_intent not in allowed or (not recipe_intent.is_empty() and not part.physical_intent.is_empty() and recipe_intent != part.physical_intent): return _failure("incompatible_support_source_intent")
	# Explicit recipe intent is authority even if the separate property is
	# empty. Materialize it ONLY on validation copies so inference cannot erase
	# it. The original property, recipe, geometry and aliases remain untouched.
	var intent: String = recipe_intent if not recipe_intent.is_empty() else part.physical_intent
	if intent.is_empty(): intent = b.inferred_physical_intent(part)
	return {"ready": true, "intent": intent}


static func _closure_contacts(staged, ids: Array, roots: Array, support_id: String) -> Dictionary:
	var edges: Dictionary = {}
	var coverage: Array = []
	for id in ids:
		var part = staged.find_part(id)
		var dependencies: Array = []
		if not roots.has(id):
			# Always 5x5, including walkable_surface whose normal gate uses 3x3.
			# Re-query real geometry; never relabel the source to obtain 25 samples.
			var samples: Array = staged.footprint_bottom_samples(part, 5)
			var supported := 0
			for sample in samples:
				var contact: Dictionary = staged.structural_support_at(part, sample.position)
				var lower = staged.find_part(String(contact.get("id", "")))
				if lower == null or not ids.has(lower.id): return _failure("incomplete_25_point_support_coverage")
				var bounds: AABB = _bounds(lower)
				var point: Vector3 = sample.position
				# Actual contact/embedding, not the physical query's allowed gap.
				if lower.position.y >= part.position.y or point.x < bounds.position.x - EPS or point.x > bounds.end.x + EPS or point.z < bounds.position.z - EPS or point.z > bounds.end.z + EPS or point.y < bounds.position.y - EPS or point.y > bounds.end.y + EPS or not staged.has_rooted_support_chain(lower, {}): return _failure("support_sample_has_no_real_rooted_contact")
				supported += 1
				if not dependencies.has(lower.id): dependencies.append(lower.id)
			coverage.append({"partId": id, "sampleCount": samples.size(), "supportedCount": supported})
		for required in part.recipe.get("physicalRequiredSupportPartIds", []):
			if not part.recipe.get("physicalSupportPartIds", []).has(required): return _failure("required_support_contact_missing")
		for fact in part.recipe.get("physicalRequiredSeatFacts", []):
			if not staged.has_rooted_bearer_seat(part, fact): return _failure("source_required_seat_invalid")
		for key in ["physicalSupportPartIds", "physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds"]:
			for dependency in part.recipe.get(key, []):
				if not ids.has(dependency): return _failure("support_dependency_outside_closure")
				if not dependencies.has(dependency): dependencies.append(dependency)
		edges[id] = dependencies
	var reachable: Array = [support_id]
	var cursor := 0
	while cursor < reachable.size():
		for id in edges[reachable[cursor]]:
			if not reachable.has(id): reachable.append(id)
		cursor += 1
	if reachable.size() != ids.size(): return _failure("unrelated_support_ancestor")
	var ordered: Array = []
	for pass_index in range(ids.size()):
		for id in ids:
			if not ordered.has(id) and edges[id].all(func(dependency): return ordered.has(dependency)): ordered.append(id)
	if ordered.size() != ids.size(): return _failure("cyclic_support_closure")
	return {"ready": true, "edges": edges, "coverage": coverage}


static func _add_frame(b, member_ids: Array, policy: Dictionary, narrow: bool, closure: Dictionary = {}) -> Dictionary:
	if b == null or b.parts.size() > MAX_PARTS or b.rooms.size() > MAX_RESERVATIONS or member_ids.is_empty() or member_ids.size() > MAX_MEMBERS:
		return _failure("invalid_or_oversized_source")
	var outward: Variant = policy.get("outward")
	if not outward is Vector3 or not outward.is_finite() or outward.y != 0.0 or outward.length_squared() != 1.0 or absf(outward.x) + absf(outward.z) != 1.0:
		return _failure("outward_must_be_horizontal_cardinal")
	for key in ["foundationPartIds", "reservedVolumes", "furnitureParts"]:
		if not policy.get(key) is Array or policy[key].size() > MAX_RESERVATIONS:
			return _failure("missing_or_oversized_" + key)
	var clearance: Variant = policy.get("clearance", 0.01)
	if not (clearance is float or clearance is int) or not is_finite(clearance) or clearance <= 0.0:
		return _failure("invalid_clearance")
	var originals: Dictionary = {}
	var source_bounds: Dictionary = {}
	for part in b.parts:
		if part == null or String(part.id).is_empty() or originals.has(part.id) or not b.has_finite_positive_bounds(part):
			return _failure("invalid_or_duplicate_source_part")
		originals[part.id] = part
		source_bounds[part.id] = _bounds(part)
	var ids: Array = member_ids.duplicate()
	if not ids.all(func(value): return value is String):
		return _failure("invalid_member_id")
	ids.sort()
	var panels: Array = []
	for id in ids:
		if not id is String or not originals.has(id) or panels.has(originals[id]):
			return _failure("missing_or_duplicate_member")
		var panel = originals[id]
		if panel.kind != "wall" or not panel.collision_enabled or panel.rotation != Vector3.ZERO:
			return _failure("requires_axis_aligned_collision_wall")
		for key in panel.recipe:
			if String(key).begins_with("physicalRequired"):
				return _failure("member_already_has_joint_contract")
		panels.append(panel)
	var normal_axis := 0 if outward.x != 0.0 else 2
	var span_axis := 2 if normal_axis == 0 else 0
	var first = panels[0]
	var datum: float = first.position.y - first.size.y * 0.5
	var thickness: float = first.size[normal_axis]
	if thickness < POST_WIDTH or thickness > 0.50:
		return _failure("unsupported_facade_thickness")
	# Optional geometry-derived section supplied by the real-facade adapter.
	# Finite panel/sill bearing and all obstruction checks remain mandatory.
	for key in ["bearingWidth", "bearingNormalCenter"]:
		if policy.has(key) and not (policy[key] is float or policy[key] is int):
			return _failure("invalid_bearing_section")
	var bearing_width: float = policy.get("bearingWidth", thickness)
	var bearing_center: float = policy.get("bearingNormalCenter", first.position[normal_axis])
	# Narrow mode can be reconstructed from the actual emitted Vector3 size.
	# Its component is real_t, while POST_WIDTH is a 64-bit scalar. Accept
	# exactly that canonical representation, not a tolerance band below policy.
	# The legacy two-post input contract and all emitted dimensions are unchanged.
	var canonical_post_width: float = Vector3(POST_WIDTH, POST_WIDTH, POST_WIDTH).x
	var canonical_narrow_width: bool = narrow and bearing_width == canonical_post_width
	if not is_finite(bearing_width) or not is_finite(bearing_center) or (bearing_width < POST_WIDTH and not canonical_narrow_width) or bearing_width > thickness:
		return _failure("invalid_bearing_section")
	panels.sort_custom(func(a, c): return a.position[span_axis] < c.position[span_axis])
	var start: float = panels[0].position[span_axis] - panels[0].size[span_axis] * 0.5
	var end := start
	for panel in panels:
		var edge: float = panel.position[span_axis] - panel.size[span_axis] * 0.5
		if panel.size[span_axis] <= 0.12:
			return _failure("member_too_narrow_for_finite_seat")
		if absf(panel.position[normal_axis] - first.position[normal_axis]) > EPS or absf(panel.size[normal_axis] - thickness) > EPS or absf(panel.position.y - panel.size.y * 0.5 - datum) > EPS or absf(edge - end) > EPS:
			return _failure("members_not_one_continuous_coplanar_bottom_row")
		end = panel.position[span_axis] + panel.size[span_axis] * 0.5
	var span := end - start
	if (not narrow and (span < 1.20 or span > 5.0)) or (narrow and (panels.size() != 1 or span < PIER_CAP_SPAN or span >= 1.20)):
		return _failure("unsupported_bay_span")
	var cap_center: float = (start + end) * 0.5
	# Optional inset endpoints describe a NEW sill, never cropped facade panels.
	# Post coordinates remain relative to the original panel-group centre, so
	# shortening a sill cannot silently relax the original end-support limit.
	var inset_sill: bool = policy.has("sillSpanBounds")
	var sill_interval := Vector2(start, end)
	if inset_sill:
		var requested_interval: Variant = policy.sillSpanBounds
		if narrow or not requested_interval is Vector2 or not requested_interval.is_finite(): return _failure("invalid_inset_sill_interval")
		sill_interval = requested_interval
		if sill_interval.x < start or sill_interval.y > end or sill_interval.y - sill_interval.x < 1.20: return _failure("inset_sill_outside_bearing_envelope")
		if not policy.has("postSpanOffsets"): return _failure("inset_sill_requires_explicit_post_offsets")
	if narrow:
		var requested: Variant = policy.get("capSpanCenter")
		if not (requested is float or requested is int) or not is_finite(requested): return _failure("invalid_cap_center")
		cap_center = requested
		if bearing_center - bearing_width * 0.5 < first.position[normal_axis] - thickness * 0.5 or bearing_center + bearing_width * 0.5 > first.position[normal_axis] + thickness * 0.5:
			return _failure("cap_outside_panel_bearing_envelope")
		# Fixed section; no thinning to fit an access. Keep the panel's centre
		# over its cap and limit the remaining end overhang to two cap depths.
		if cap_center - PIER_CAP_SPAN * 0.5 < start or cap_center + PIER_CAP_SPAN * 0.5 > end or absf(cap_center - (start + end) * 0.5) > PIER_CAP_SPAN * 0.5 or maxf(cap_center - PIER_CAP_SPAN * 0.5 - start, end - cap_center - PIER_CAP_SPAN * 0.5) > SILL_HEIGHT * 2.0:
			return _failure("cap_outside_panel_bearing_envelope")
	var offsets: Variant = policy.get("postSpanOffsets", Vector2(-span * 0.5 + FOOT_WIDTH * 0.5, span * 0.5 - FOOT_WIDTH * 0.5))
	if not offsets is Vector2 or not offsets.is_finite(): return _failure("invalid_post_span_offsets")
	var inset_limit := maximum_post_inset(span)
	if policy.has("postSpanOffsets") and (offsets.x < -span * 0.5 + FOOT_WIDTH * 0.5 or offsets.x > -span * 0.5 + inset_limit or offsets.y > span * 0.5 - FOOT_WIDTH * 0.5 or offsets.y < span * 0.5 - inset_limit):
		return _failure("post_span_offsets_exceed_bearing_envelope")
	if inset_sill:
		for offset in [offsets.x, offsets.y]:
			var post_center: float = cap_center + offset
			if post_center - POST_WIDTH * 0.5 < sill_interval.x or post_center + POST_WIDTH * 0.5 > sill_interval.y: return _failure("post_not_fully_seated_under_inset_sill")
	var reservations: Array = policy.reservedVolumes.duplicate()
	for room in b.rooms:
		if not room is Dictionary or not room.get("bounds") is AABB or not _valid_bounds(room.bounds) or not room.get("accesses", []) is Array:
			return _failure("invalid_room_record")
		if room.get("role", "") != "courtyard":
			reservations.append(room.bounds)
		if room.get("accesses", []).size() + reservations.size() > MAX_RESERVATIONS:
			return _failure("reservation_limit_exceeded")
		for access in room.get("accesses", []):
			if not access is Dictionary or not access.get("position") is Vector3 or not access.get("size") is Vector3:
				return _failure("invalid_access_record")
			reservations.append(AABB(access.position - access.size * 0.5, access.size))
	for record in policy.furnitureParts:
		var occupied := furnishing_bounds(record)
		if not occupied.ready: return occupied
		reservations.append(occupied.bounds)
	if reservations.size() > MAX_RESERVATIONS:
		return _failure("reservation_limit_exceeded")
	for volume in reservations:
		if not volume is AABB or not _valid_bounds(volume):
			return _failure("invalid_reserved_volume")
	# Independently derive final construction reservations from actual doors;
	# caller-supplied planning reservations are not trusted as final evidence.
	var door_visuals := closed_door_reservations(b)
	if not door_visuals.ready: return door_visuals
	if reservations.size() + door_visuals.records.size() > MAX_RESERVATIONS: return _failure("reservation_limit_exceeded")
	var foundations: Array = []
	for id in policy.foundationPartIds:
		if not id is String or not originals.has(id) or foundations.has(originals[id]):
			return _failure("invalid_foundation_declaration")
		var foundation = originals[id]
		if not closure.is_empty():
			foundations.append(foundation)
			continue
		# Geometry cannot override either authoritative intent field. A staging
		# copy must not turn a decorative source into a structural foundation.
		var recipe_intent: Variant = foundation.recipe.get("physicalIntent", "")
		if foundation.physical_intent not in ["", "structural_mass", "structural_root"] or not recipe_intent is String or recipe_intent not in ["", "structural_mass", "structural_root"]:
			return _failure("incompatible_foundation_intent")
		if not foundation.physical_intent.is_empty() and not recipe_intent.is_empty() and foundation.physical_intent != recipe_intent:
			return _failure("conflicting_foundation_intents")
		if foundation.rotation != Vector3.ZERO or not b.is_grounded_structural_root(foundation) or Materials.is_cobble_material(foundation.material_id):
			return _failure("foundation_is_not_grounded_structural_masonry")
		# Paving alone is not a declared footing authority; require masonry.
		if not Materials.is_masonry_material(foundation.material_id):
			return _failure("foundation_requires_masonry")
		for key in foundation.recipe:
			if String(key).begins_with("physicalRequired"):
				return _failure("foundation_has_external_joint_contract")
		foundations.append(foundation)
	var staged = Blueprint.new(b.id, b.seed, b.style)
	var prefix: String = "facade_bearing_" + String(ids[0])
	var new_parts: Array = []
	var selected_roots: Dictionary = {}
	var posts: Array = []
	var feet: Array = []
	var bearing_span: float = PIER_CAP_SPAN if narrow else span
	if inset_sill: bearing_span = sill_interval.y - sill_interval.x
	var sill_size := Vector3(bearing_width, SILL_HEIGHT, bearing_span)
	if span_axis == 0:
		sill_size = Vector3(bearing_span, SILL_HEIGHT, bearing_width)
	var sill_center: Vector3 = first.position
	sill_center[normal_axis] = bearing_center
	sill_center.y = datum - SILL_HEIGHT * 0.5
	sill_center[span_axis] = cap_center
	if inset_sill: sill_center[span_axis] = (sill_interval.x + sill_interval.y) * 0.5
	var sill = _new(staged, prefix + "_sill", "beam", "timber_beam", sill_center, sill_size)
	new_parts.append(sill)
	var placement_center := sill_center
	if inset_sill: placement_center[span_axis] = cap_center
	var placements: Array = footing_layout(placement_center, span_axis, span, outward, offsets if policy.has("postSpanOffsets") else null)
	if narrow:
		placements = [{"side": 0.0, "postCenter": sill_center, "footCenter": sill_center + outward * ((FOOT_WIDTH - POST_WIDTH) * 0.5)}]
	for placement in placements:
		var side: float = placement.side
		var location: Vector3 = placement.postCenter
		var foot_center: Vector3 = placement.footCenter
		var candidates: Array = []
		for foundation in foundations:
			var root_bounds := _bounds(foundation)
			var top := root_bounds.end.y
			if top + FOOT_HEIGHT + 0.80 >= datum - SILL_HEIGHT:
				continue
			var footprint := Rect2(Vector2(foot_center.x - FOOT_WIDTH * 0.5, foot_center.z - FOOT_WIDTH * 0.5), Vector2.ONE * FOOT_WIDTH)
			if Rect2(Vector2(root_bounds.position.x, root_bounds.position.z), Vector2(root_bounds.size.x, root_bounds.size.z)).encloses(footprint):
				candidates.append(foundation)
		if candidates.size() != 1:
			return _failure("missing_or_ambiguous_grounded_footing_seat")
		var root = candidates[0]
		selected_roots[root.id] = root
		foot_center.y = root.position.y + root.size.y * 0.5 + FOOT_HEIGHT * 0.5
		# A visible masonry block on an existing root, NOT a new root label.
		var foot = _new(staged, prefix + "_foot_%d" % int(side), "beam", "stone_foundation", foot_center, Vector3(FOOT_WIDTH, FOOT_HEIGHT, FOOT_WIDTH))
		feet.append(foot)
		_seats(foot, [Seats.world_down_seat_fact(root.id, Vector3(0, -FOOT_HEIGHT * 0.5, 0), Vector2.ONE * PATCH_HALF)])
		var foot_top: float = foot.position.y + FOOT_HEIGHT * 0.5
		var post_height := datum - SILL_HEIGHT - foot_top
		location.y = foot_top + post_height * 0.5
		var post = _new(staged, prefix + "_post_%d" % int(side), "beam", "timber_beam", location, Vector3.ONE * POST_WIDTH)
		post.size.y = post_height
		_seats(post, [Seats.world_down_seat_fact(foot.id, Vector3(0, -post_height * 0.5, 0), Vector2.ONE * PATCH_HALF)])
		posts.append(post)
		new_parts.append_array([foot, post])
	var sill_facts: Array = []
	for post in posts:
		var patch: Vector3 = post.position - sill.position
		patch.y = -SILL_HEIGHT * 0.5
		sill_facts.append(Seats.world_down_seat_fact(post.id, patch, Vector2.ONE * PATCH_HALF))
	_seats(sill, sill_facts)
	var retained_supports: Array = selected_roots.values()
	if not closure.is_empty(): retained_supports = closure.partIds.map(func(id): return originals[id])
	for root in retained_supports:
		var copy = staged.add_part(root.snapshot())
		# Carry the consistent authoritative intent into the validation copy,
		# including recipe-only declarations. Never commit this normalization
		# back to retained support records.
		var source_intent := support_source_intent(b, root)
		if not source_intent.ready: return source_intent
		copy.physical_intent = source_intent.intent
		_clean_derived(copy)
	for panel in panels:
		var copy = staged.add_part(panel.snapshot())
		_clean_derived(copy)
		var panel_bounds := _bounds(copy)
		var sill_bounds := _bounds(sill)
		var low := panel_bounds.position.max(sill_bounds.position)
		var high := panel_bounds.end.min(sill_bounds.end)
		var patch: Vector3 = (low + high) * 0.5 - copy.position
		patch.y = -copy.size.y * 0.5
		var half := Vector2((high.x - low.x) * 0.5 - 0.06, (high.z - low.z) * 0.5 - 0.06)
		if half.x <= 0.0 or half.y <= 0.0:
			return _failure("panel_has_no_finite_sill_seat")
		_seats(copy, [Seats.world_down_seat_fact(sill.id, patch, half)])
	# A short cap bears directly on one post; diagonal knees belong to the
	# unchanged spanning two-post frame, not to a fictitious second support.
	for index in range(0 if narrow else posts.size()):
		var post = posts[index]
		var start_point: Vector3 = post.position
		start_point.y = datum - SILL_HEIGHT - 0.50
		var end_point: Vector3 = sill.position
		end_point[span_axis] = post.position[span_axis] + (0.36 if index == 0 else -0.36)
		var direction := (end_point - start_point).normalized()
		var transverse: Vector3 = outward.cross(direction).normalized()
		var basis := Basis(direction.cross(transverse).normalized(), direction, transverse)
		var brace = _new(staged, prefix + "_knee_%d" % index, "beam", "timber_beam", (start_point + end_point) * 0.5, Vector3(0.12, start_point.distance_to(end_point), 0.12))
		brace.rotation = basis.get_euler()
		brace.collision_enabled = false
		brace.physical_intent = "facade_attachment"
		brace.recipe.physicalIntent = "facade_attachment"
		brace.recipe["physicalRequiredAnchorPartIds"] = [post.id, sill.id]
		brace.recipe["physicalRequiredAnchorFacts"] = [_socket(post.id, Vector3(0, -brace.size.y * 0.5 + 0.05, 0)), _socket(sill.id, Vector3(0, brace.size.y * 0.5 - 0.05, 0))]
		new_parts.append(brace)
	# Prepare actual dressing geometry privately. No finish is ignored: every
	# complete frame member must clear the exact represented cut artifact.
	var paving: Dictionary = {"ready": true, "artifacts": {}, "joints": {}}
	if policy.has("pavingFinishPartIds"):
		if not policy.pavingFinishPartIds is Array: return _failure("invalid_paving_finish_policy")
		var membership := _paving_foot_membership(b, originals, policy.pavingFinishPartIds, feet, clearance)
		if not membership.ready: return membership
		paving = PavingAssembly.prepare_extension(b, membership.finishFeet, clearance)
		if not paving.ready: return paving
	for part in new_parts:
		if originals.has(part.id):
			return _failure("frame_already_present")
		var bounds := _bounds(part)
		for primitive in door_visuals.records:
			if _penetrates(bounds.grow(clearance), primitive.bounds):
				return {"ready": false, "reason": "ordinary_door_visual_geometry_blocked", "partId": part.id, "otherId": primitive.partId, "primitive": primitive.name, "reservation": primitive.bounds}
		for volume in reservations:
			if _penetrates(bounds.grow(clearance), volume):
				return {"ready": false, "reason": "reserved_interior_access_or_furniture_blocked", "partId": part.id, "reservation": volume}
		for other in b.parts:
			if paving.artifacts.has(other.id):
				var member_boxes: Array[AABB] = [bounds]
				var proof: Dictionary = PavingAssembly.Artifact.clear_of_boxes(paving.artifacts[other.id], member_boxes)
				if not proof.completed: return _failure("cut_paving_clearance_incomplete:" + String(proof.get("reason", "")))
				if not proof.get("clear", false):
					return {"ready": false, "reason": "frame_member_not_clear_of_cut_paving", "partId": part.id, "otherId": other.id, "proof": proof}
				continue
			# Permit declared bearing faces only. No generic foundation/trim or
			# decorative-geometry exclusions; unrelated visible parts still block.
			if not _penetrates(bounds, source_bounds[other.id]):
				continue
			return {"ready": false, "reason": "existing_source_geometry_blocked", "partId": part.id, "otherId": other.id}
	# Snapshot before validation; never publish derived root/support caches.
	var grid_cells := 0
	for part in staged.parts:
		var bounds := _bounds(part)
		var cells_x := floorf(bounds.end.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL) - floorf(bounds.position.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL) + 1.0
		var cells_z := floorf(bounds.end.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL) - floorf(bounds.position.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL) + 1.0
		if not is_finite(cells_x) or not is_finite(cells_z) or cells_x > 4096 or cells_z > 4096:
			return _failure("staged_validation_work_limit_exceeded")
		grid_cells += int(cells_x * cells_z)
		if grid_cells > 4096:
			return _failure("staged_validation_work_limit_exceeded")
	var records: Array = staged.part_snapshots()
	var validation: Dictionary = staged.validate_physical_integrity()
	if not validation.violations.is_empty():
		return {"ready": false, "reason": "staged_load_path_failed", "violations": validation.violations}
	if not closure.is_empty():
		var complete := _closure_contacts(staged, closure.partIds, closure.rootIds, closure.supportId)
		if not complete.ready: return complete
	for part in staged.parts:
		for fact in part.recipe.get("physicalRequiredSeatFacts", []):
			if not staged.has_rooted_bearer_seat(part, fact):
				return _failure("finite_seat_failed")
		for fact in part.recipe.get("physicalRequiredAnchorFacts", []):
			if not _socket_inside(part, fact) or not staged.has_rooted_attachment_socket(part, fact):
				return _failure("finite_socket_failed")
	var additions: Array = []
	for record in records:
		if selected_roots.has(record.id) or closure.get("partIds", []).has(record.id):
			continue
		if originals.has(record.id):
			var target = originals[record.id]
			target.physical_intent = record.physicalIntent
			target.recipe = record.recipe.duplicate(true)
		else:
			b.add_part(record)
			additions.append(record.id)
	# This is the first mutation of finish records, after ALL frame checks and
	# physical validation succeed. No transient mesh/artifact is serialized.
	for finish_id in paving.joints:
		originals[finish_id].recipe["pavingFootingJoints"] = paving.joints[finish_id].duplicate(true)
	return {"ready": true, "reason": "", "partIds": additions, "memberIds": ids, "pavingFinishPartIds": paving.joints.keys(),
		"foundationIds": selected_roots.keys(), "sillId": sill.id, "postIds": posts.map(func(post): return post.id),
		"mode": "narrow_pier" if narrow else ("inset_end_two_post" if inset_sill else "two_post"), "sillSpanBounds": Vector2(_bounds(sill).position[span_axis], _bounds(sill).end[span_axis]),
		"supportClosureIds": closure.get("partIds", selected_roots.keys()), "supportCoverage": closure.get("coverage", []),
		"stagedPhysical": validation, "scope": "One bottom-row bearing construction. Original full-span/narrow modes retained; optional inset sill keeps original panel/end-post limits and full sections. No opening-header, engineering load rating, whole-facade, publisher or gameplay acceptance."}


static func footing_layout(sill_center: Vector3, span_axis: int, span: float, outward: Vector3, offsets: Variant = null) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for side in [-1.0, 1.0]:
		var location := sill_center
		location[span_axis] += side * (span * 0.5 - FOOT_WIDTH * 0.5) if offsets == null else (offsets.x if side < 0 else offsets.y)
		result.append({"side": side, "postCenter": location, "footCenter": location + outward * ((FOOT_WIDTH - POST_WIDTH) * 0.5)})
	return result


static func maximum_post_inset(span: float) -> float:
	# Recipe envelope: end cantilever at most two sill depths and 20% of span.
	# This is construction policy, not a stress-analysis/load-rating claim.
	return minf(SILL_HEIGHT * 2.0, span * 0.20)


static func plan_footing_offsets(b, center: Vector3, span_axis: int, span: float, outward: Vector3, ground_top: float, reservations: Array, clearance: float, support_bounds: Variant = null, work_budget: Dictionary = {}, sill_interval: Variant = null) -> Dictionary:
	if b.parts.size() > MAX_PARTS or reservations.size() > MAX_RESERVATIONS: return _failure("footing_projection_work_limit")
	if support_bounds != null and (not support_bounds is AABB or not _valid_bounds(support_bounds) or absf(support_bounds.end.y - ground_top) > EPS): return _failure("invalid_shared_support_bounds")
	if not work_budget.is_empty() and (not work_budget.get("remaining") is int or work_budget.remaining < 0 or work_budget.remaining > 131072): return _failure("invalid_footing_work_budget")
	if sill_interval != null and (not sill_interval is Vector2 or not sill_interval.is_finite() or sill_interval.x >= sill_interval.y): return _failure("invalid_inset_sill_interval")
	var obstacles: Array[AABB] = []
	for part in b.parts: obstacles.append(_bounds(part))
	for volume in reservations: obstacles.append(volume.grow(clearance))
	return _plan_footing_offsets_from_bounds(center, span_axis, span, outward, ground_top, obstacles, clearance, support_bounds, work_budget, sill_interval)


static func _plan_footing_offsets_from_bounds(center: Vector3, span_axis: int, span: float, outward: Vector3, ground_top: float, obstacles: Array[AABB], clearance: float, support_bounds: Variant = null, work_budget: Dictionary = {}, sill_interval: Variant = null) -> Dictionary:
	# Single projection implementation. The broad recipe supplies once-built,
	# conservatively filtered bounds; public callers still build from source.
	# This is planning only: _add_frame always checks ALL actual source parts.
	if obstacles.size() > MAX_PARTS + MAX_RESERVATIONS: return _failure("footing_projection_work_limit")
	if support_bounds != null and (not support_bounds is AABB or not _valid_bounds(support_bounds) or absf(support_bounds.end.y - ground_top) > EPS): return _failure("invalid_shared_support_bounds")
	if not work_budget.is_empty() and (not work_budget.get("remaining") is int or work_budget.remaining < 0 or work_budget.remaining > 131072): return _failure("invalid_footing_work_budget")
	if sill_interval != null and (not sill_interval is Vector2 or not sill_interval.is_finite() or sill_interval.x >= sill_interval.y): return _failure("invalid_inset_sill_interval")
	var normal_axis := 0 if span_axis == 2 else 2
	var offsets := Vector2.ZERO
	var evidence: Array = []
	var projection_work := 0
	for placement in footing_layout(center, span_axis, span, outward):
		var side: float = placement.side
		var default_coordinate: float = placement.postCenter[span_axis]
		var travel := maximum_post_inset(span) - FOOT_WIDTH * 0.5
		if travel <= 2.0 * clearance: return _failure("insufficient_footing_search_envelope")
		# Construct inside the policy boundary, not on a float-equality edge.
		var free: Array[Vector2] = [Vector2(default_coordinate + clearance, default_coordinate + travel - clearance) if side < 0 else Vector2(default_coordinate - travel + clearance, default_coordinate - clearance)]
		if sill_interval != null:
			# Full post section bears inside the new sill; the wider foot can
			# project beyond it only where the actual support/obstacles permit.
			free[0] = Vector2(maxf(free[0].x, sill_interval.x + POST_WIDTH * 0.5 + clearance), minf(free[0].y, sill_interval.y - POST_WIDTH * 0.5 - clearance))
			if free[0].y <= free[0].x: return _failure("inset_sill_exceeds_end_support_limit")
		var foot_center: Vector3 = placement.footCenter
		foot_center.y = ground_top + FOOT_HEIGHT * 0.5
		var foot_bounds := AABB(foot_center - Vector3(FOOT_WIDTH, FOOT_HEIGHT, FOOT_WIDTH) * 0.5, Vector3(FOOT_WIDTH, FOOT_HEIGHT, FOOT_WIDTH))
		if support_bounds != null:
			# Both independent end-post ranges must fit this SAME real surface.
			# Keep a construction margin; no expanded or union support footprint.
			if foot_bounds.position[normal_axis] < support_bounds.position[normal_axis] + clearance or foot_bounds.end[normal_axis] > support_bounds.end[normal_axis] - clearance: return _failure("shared_support_does_not_cover_both_feet")
			var low: float = support_bounds.position[span_axis] + FOOT_WIDTH * 0.5 + clearance
			var high: float = support_bounds.end[span_axis] - FOOT_WIDTH * 0.5 - clearance
			free[0] = Vector2(maxf(free[0].x, low), minf(free[0].y, high))
			if free[0].y <= free[0].x: return _failure("shared_support_does_not_cover_both_feet")
		var post_bottom := ground_top + FOOT_HEIGHT
		var post_top := center.y - SILL_HEIGHT * 0.5
		if post_top <= post_bottom: return _failure("insufficient_post_height")
		var post_center: Vector3 = placement.postCenter
		post_center.y = (post_bottom + post_top) * 0.5
		var post_size := Vector3(POST_WIDTH, post_top - post_bottom, POST_WIDTH)
		var post_bounds := AABB(post_center - post_size * 0.5, post_size)
		for envelope in [foot_bounds, post_bounds]:
			for obstacle in obstacles:
				projection_work += 1
				if not work_budget.is_empty():
					work_budget.remaining -= 1
					if work_budget.remaining < 0: return _failure("footing_projection_work_limit")
				if projection_work > 131072: return _failure("footing_projection_work_limit")
				# Exact X/Y projection; only Z/X span coordinates are variable.
				if minf(envelope.end.y, obstacle.end.y) - maxf(envelope.position.y, obstacle.position.y) <= EPS or minf(envelope.end[normal_axis], obstacle.end[normal_axis]) - maxf(envelope.position[normal_axis], obstacle.position[normal_axis]) <= EPS: continue
				var low: float = obstacle.position[span_axis] - envelope.size[span_axis] * 0.5 - clearance
				var high: float = obstacle.end[span_axis] + envelope.size[span_axis] * 0.5 + clearance
				var next: Array[Vector2] = []
				for interval in free:
					projection_work += 1
					if not work_budget.is_empty():
						work_budget.remaining -= 1
						if work_budget.remaining < 0: return _failure("footing_projection_work_limit")
					if projection_work > 131072: return _failure("footing_projection_work_limit")
					if high <= interval.x or low >= interval.y: next.append(interval)
					else:
						if low > interval.x: next.append(Vector2(interval.x, low))
						if high < interval.y: next.append(Vector2(high, interval.y))
				free = next
		if free.is_empty(): return _failure("no_clear_footing_within_sill_envelope")
		# Subtraction preserves coordinate order; choose nearest original end.
		var chosen: float = free[0].x if side < 0 else free.back().y
		if side < 0: offsets.x = chosen - center[span_axis]
		else: offsets.y = chosen - center[span_axis]
		evidence.append({"side": side, "originalCoordinate": default_coordinate, "selectedCoordinate": chosen})
	return {"ready": true, "offsets": offsets, "projections": evidence, "projectionWork": projection_work}


static func _paving_foot_membership(b, originals: Dictionary, finish_ids: Array, feet: Array, joint: float) -> Dictionary:
	if finish_ids.is_empty() or finish_ids.size() > PavingAssembly.MAX_FINISHES or feet.is_empty() or feet.size() > PavingAssembly.FootCuts.MAX_FEET:
		return _failure("paving_membership_collection_limit")
	var history := PavingAssembly.History.new()
	history.configure(b.recipe, b.parts)
	var source_id: String = String(b.recipe.get("sourceBlueprintId", b.id))
	var seen: Dictionary = {}
	var finish_feet: Dictionary = {}
	for id in finish_ids:
		if not id is String or seen.has(id) or not originals.has(id) or not PavingAssembly._valid_finish(b, originals[id]): return _failure("invalid_paving_finish_policy")
		seen[id] = true
		var finish = originals[id]
		var described: Dictionary = PavingAssembly.Geometry.describe_source(finish, history, source_id)
		var members: Array = []
		for foot in feet:
			var boxes: Array[AABB] = [AABB(foot.position - foot.size * 0.5, foot.size)]
			# Existing native-solid/cutter authority proves positive overlap.
			# An AABB hit alone must not associate the other foot with a finish.
			var probe: Dictionary = PavingAssembly.FootCuts.derive(described, b.part_transform(finish), boxes, joint)
			if probe.completed: members.append(foot)
			elif probe.get("reason") != "foot_has_no_actual_finish_overlap": return _failure("paving_membership:" + String(probe.get("reason", "")))
		if not members.is_empty(): finish_feet[id] = members
	if finish_feet.is_empty(): return _failure("no_actual_paving_foot_overlap")
	return {"ready": true, "finishFeet": finish_feet}


static func _new(b, id: String, kind: String, material: String, position: Vector3, size: Vector3):
	return b.add_part({"id": id, "kind": kind, "material": material, "position": position, "size": size,
		"collision": true, "semantic": "facade_bearing_frame", "physicalIntent": "structural_mass",
		"recipe": {"physicalIntent": "structural_mass", "preserveBearingFaces": true}})


static func _seats(part, facts: Array) -> void:
	part.physical_intent = "structural_mass"
	part.recipe["physicalIntent"] = "structural_mass"
	part.recipe["physicalRequiredSeatFacts"] = facts
	part.recipe["physicalRequiredSeatPartIds"] = facts.map(func(fact): return fact.seatId)


static func _socket(id: String, center: Vector3) -> Dictionary:
	return {"anchorId": id, "contactMode": "attachment_socket", "localMountCenter": center, "localMountHalfExtents": Vector3(0.015, 0.02, 0.015)}


static func _socket_inside(part, fact: Dictionary) -> bool:
	for axis in range(3):
		if absf(fact.localMountCenter[axis]) + fact.localMountHalfExtents[axis] > part.size[axis] * 0.5:
			return false
	return true


static func _clean_derived(part) -> void:
	# Only caches: classification belongs to the source, or to _seats for the
	# panels whose new structural contract is also committed to the caller.
	for key in ["physicalRoot", "physicalSupportPartIds", "physicalSupportCoverage", "physicalAnchorPartIds", "physicalIntentResolution"]:
		part.recipe.erase(key)


static func closed_door_reservations(b) -> Dictionary:
	# Same ordinary-door selection and pure geometry as the publisher, in the
	# actual world pose. Bounds are conservative for non-axis-aligned boxes.
	# Portcullises retain existing source/access checks; no ordinary-door proxy.
	if b == null or b.parts.size() > MAX_PARTS: return _failure("door_reservation_source_limit")
	var records: Array = []
	var volumes: Array = []
	var unsupported: Array = []
	for part in b.parts:
		if part.kind != "door": continue
		if String(part.recipe.get("doorPresentation", "")) == "portcullis":
			unsupported.append(part.id)
			continue
		if not b.has_finite_positive_bounds(part): return _failure("invalid_door_reservation_source")
		for primitive in DoorGeometry.closed_primitives(part.size, b.part_transform(part)):
			if records.size() >= MAX_RESERVATIONS: return _failure("door_reservation_collection_limit")
			if not primitive.get("bounds") is AABB or not _valid_bounds(primitive.bounds): return _failure("invalid_door_primitive_bounds")
			records.append({"partId": part.id, "name": primitive.name, "bounds": primitive.bounds, "transform": primitive.transform, "size": primitive.size})
			volumes.append(primitive.bounds)
	return {"ready": true, "records": records, "volumes": volumes, "unsupportedPortcullisIds": unsupported, "scope": "closed ordinary-door visual construction envelopes, not swing clearance or portcullis visual proof"}


static func furnishing_bounds(record: Variant) -> Dictionary:
	# FurnishingPart.position is the FLOOR centre, unlike BuildingPart.position.
	# Transform all occupied corners about that origin, including tilted inputs.
	if not record is Dictionary: return _failure("invalid_furniture_record")
	var size: Variant = record.get("occupiedSize", record.get("size"))
	var position: Variant = record.get("position")
	var rotation: Variant = record.get("rotation", Vector3.ZERO)
	if not size is Vector3 or not position is Vector3 or not rotation is Vector3 or not record.get("recipe", {}) is Dictionary:
		return _failure("invalid_furniture_record")
	if not _valid_bounds(AABB(Vector3.ZERO, size)) or not position.is_finite() or not rotation.is_finite(): return _failure("invalid_furniture_record")
	var transform := Transform3D(Basis.from_euler(rotation), position)
	var bounds := AABB(transform * Vector3(-size.x * 0.5, 0, -size.z * 0.5), Vector3.ZERO)
	for x in [-0.5, 0.5]:
		for y in [0.0, 1.0]:
			for z in [-0.5, 0.5]:
				bounds = bounds.expand(transform * (size * Vector3(x, y, z)))
	if not _valid_bounds(bounds): return _failure("invalid_furniture_record")
	return {"ready": true, "bounds": bounds}


static func _bounds(part) -> AABB:
	var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
	var bounds := AABB(transform * (-part.size * 0.5), Vector3.ZERO)
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				bounds = bounds.expand(transform * (part.size * Vector3(x, y, z)))
	return bounds


static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.end.is_finite() and bounds.size.x > 0 and bounds.size.y > 0 and bounds.size.z > 0


static func _penetrates(a: AABB, c: AABB) -> bool:
	var overlap := a.end.min(c.end) - a.position.max(c.position)
	return overlap.x > EPS and overlap.y > EPS and overlap.z > EPS


static func _failure(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}

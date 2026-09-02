extends RefCounted

## Unwired prototype: retain terminal cloth, furniture and principal frame shapes.
const Seats = preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const MAX_SOURCE_PARTS := 10000
const MAX_SUPPORT_CLOSURE := 32 # includes support_id
const INPUT_SUFFIXES := ["_lintel", "_sign_arm", "_jamb_-1", "_jamb_1", "_bracket_-1", "_bracket_1"]
const ADDED_SUFFIXES := ["_awning_rail_-1", "_awning_rail_1", "_sign_mount_base", "_sign_mount", "_sign_mount_top"]

static func add_frame(blueprint, prefix: String, support_id: String) -> Dictionary:
	return _add_legacy_frame(blueprint, prefix, support_id)

## Caller supplies the complete actual support path; no discovery or elevation.
## The frame members must ALREADY seat at the supplied support's real top.
## Caller rigidly transforms the COMPLETE row first. This bay API validates its
## six input frame orientations; it does not discover or move row contents.
## Explicit mode consumes the bay's actual cloth planes for underside bearing.
## Direct add_frame retains legacy rail geometry; cross-API geometry parity is
## no longer promised (input preservation / world support authority still are).
static func add_frame_on_support(blueprint, prefix: String, support_id: String, upstream_ids: Array) -> Dictionary:
	var description := describe_frame(blueprint, prefix)
	if not description.described:
		var failure := description.duplicate(true)
		failure["ready"] = false
		return failure
	# Private transaction; unaffected source references are only read. Every
	# described member is a private copy before the binder can change its recipe.
	var trial = Blueprint.new(blueprint.id, blueprint.seed, blueprint.style)
	var records: Dictionary = {}
	for record in description.records: records[record.id] = record
	for part in blueprint.parts:
		if records.has(part.id):
			var copy = trial.add_part(records[part.id])
			copy.physical_intent = records[part.id].physicalIntent
		else:
			trial.parts.append(part)
	for id in description.partIds:
		var added = trial.add_part(records[id])
		added.physical_intent = records[id].physicalIntent
	var result := bind_described_frame_on_support(trial, description, support_id, upstream_ids)
	if not result.ready: return result
	var originals: Dictionary = {}
	for part in blueprint.parts: originals[part.id] = part
	for id in description.memberIds:
		var record: Dictionary = _find(trial, id).snapshot()
		if not originals.has(id):
			blueprint.add_part(record)
			continue
		var part = originals[id]
		part.position = record.position
		part.rotation = record.rotation
		part.size = record.size
		part.collision_enabled = record.collision
		part.physical_intent = record.physicalIntent
		part.recipe = record.recipe.duplicate(true)
	return result

## Pure source geometry description: no support input, fake foundation, physical
## validation, source mutation, or readiness/root claim. Joint coordinates local.
static func describe_frame(source, prefix: String) -> Dictionary:
	if source == null or prefix.is_empty() or prefix != prefix.strip_edges() or source.parts.size() > MAX_SOURCE_PARTS:
		return {"described": false, "reason": "invalid_frame_declaration"}
	var originals: Dictionary = {}
	for part in source.parts:
		if part == null or String(part.id).is_empty() or originals.has(part.id):
			return {"described": false, "reason": "missing_or_duplicate_part_id"}
		originals[part.id] = part
	for suffix in ADDED_SUFFIXES:
		if originals.has(prefix + suffix): return {"described": false, "reason": "frame_already_present"}
	var staged = Blueprint.new(source.id, source.seed, source.style)
	for suffix in INPUT_SUFFIXES:
		var part = originals.get(prefix + suffix)
		if part == null: return {"described": false, "reason": "missing_frame_member"}
		if not source.has_finite_positive_bounds(part): return {"described": false, "reason": "invalid_member_bounds"}
		if part.kind != "beam" or part.material_id != "timber_beam": return {"described": false, "reason": "incompatible_frame_member"}
		for key in part.recipe:
			if String(key).begins_with("physicalRequired"): return {"described": false, "reason": "member_already_has_joint_contract"}
		var intent: Variant = part.recipe.get("physicalIntent", "")
		if not intent is String or part.physical_intent not in ["", "structural_mass", "facade_attachment"] or intent not in ["", "structural_mass", "facade_attachment"] or (not part.physical_intent.is_empty() and not intent.is_empty() and part.physical_intent != intent):
			return {"described": false, "reason": "incompatible_frame_source_intent"}
		if part.recipe.get("physicalRoot", false) != false: return {"described": false, "reason": "frame_member_cannot_be_root"}
		if suffix in ["_sign_arm", "_bracket_-1", "_bracket_1"] and (part.collision_enabled or part.physical_intent not in ["", "facade_attachment"] or intent not in ["", "facade_attachment"]):
			return {"described": false, "reason": "incompatible_attachment_intent"}
		var copy = staged.add_part(part.snapshot())
		copy.physical_intent = part.physical_intent
		_clean_caches(copy)
	var collected := _collect_cloth(source, prefix)
	if not collected.ready: return _description_failure(collected)
	var work := _validation_work(staged)
	if not work.ready: return _description_failure(work)
	# Exactly the constructor used by explicit add_frame; no geometry rebuilding
	# after layout. The absent external post seats are bound only to real source.
	var result := _assemble(staged, prefix, "", true, collected.parts, true)
	if not result.ready: return _description_failure(result)
	work = _validation_work(staged)
	if not work.ready: return _description_failure(work)
	result.erase("ready")
	result["described"] = true
	result["descriptionVersion"] = 1
	result["prefix"] = prefix
	result["records"] = staged.part_snapshots()
	result["memberIds"] = staged.parts.map(func(part): return part.id)
	result["postIds"] = [prefix + "_jamb_-1", prefix + "_jamb_1"]
	result["clothRecords"] = collected.parts.map(func(part): return part.snapshot())
	result["scope"] = "Unbound source geometry and local internal joints only; no structural readiness or public-access claim."
	return result

static func _description_failure(result: Dictionary) -> Dictionary:
	var failure := result.duplicate(true)
	failure.erase("ready")
	failure["described"] = false
	return failure

## Consume already-staged/transformed described records. Never constructs or
## adjusts geometry. Only two external post-seat declarations are committed.
static func bind_described_frame_on_support(source, description: Dictionary, support_id: String, upstream_ids: Array) -> Dictionary:
	if source == null or source.parts.size() > MAX_SOURCE_PARTS or support_id.is_empty() or support_id != support_id.strip_edges() or upstream_ids.size() >= MAX_SUPPORT_CLOSURE:
		return {"ready": false, "reason": "invalid_frame_declaration"}
	var schema := _description_schema(description)
	if not schema.ready: return schema
	var originals: Dictionary = {}
	for part in source.parts:
		if part == null or String(part.id).is_empty() or originals.has(part.id): return {"ready": false, "reason": "missing_or_duplicate_part_id"}
		originals[part.id] = part
	var closure_ids: Array = [support_id]
	for id in upstream_ids:
		if not id is String or id.is_empty() or id != id.strip_edges() or closure_ids.has(id): return {"ready": false, "reason": "invalid_or_duplicate_upstream_id"}
		closure_ids.append(id)
	for id in closure_ids:
		if description.memberIds.has(id) or description.clothIds.has(id): return {"ready": false, "reason": "support_closure_contains_frame_member"}
	var header_id: String = description.prefix + "_lintel"
	if not originals.has(header_id): return {"ready": false, "reason": "missing_staged_description_member"}
	var reference_header: Dictionary = schema.records[header_id]
	var delta: Transform3D = source.part_transform(originals[header_id]) * Transform3D(Basis.from_euler(reference_header.rotation), reference_header.position).affine_inverse()
	if not delta.is_finite(): return {"ready": false, "reason": "invalid_description_transform"}
	for record in description.records + description.clothRecords:
		var part = originals.get(record.id)
		if part == null or not source.has_finite_positive_bounds(part): return {"ready": false, "reason": "missing_or_invalid_staged_description_member", "partId": record.id}
		if not _rigid_record_matches(source, part, record, delta): return {"ready": false, "reason": "staged_member_changed_since_description", "partId": record.id}
	var prefix: String = description.prefix
	var posts: Array = description.postIds.map(func(id): return originals[id])
	var orientation := _frame_orientation(source, originals[header_id], originals[prefix + "_sign_arm"], posts, [originals[prefix + "_bracket_-1"], originals[prefix + "_bracket_1"]])
	if not orientation.ready: return orientation
	var actual_cloth := _collect_cloth(source, prefix)
	if not actual_cloth.ready: return actual_cloth
	if actual_cloth.parts.size() != description.clothIds.size() or not actual_cloth.parts.all(func(part): return description.clothIds.has(part.id)):
		return {"ready": false, "reason": "staged_cloth_membership_changed"}
	var consistent := _consistent_cloth(source, actual_cloth.parts, orientation.basis)
	if not consistent.ready: return consistent
	var closure := _validate_support_closure(source, originals, closure_ids)
	if not closure.ready: return closure
	var support = originals[support_id]
	if support.rotation != Vector3.ZERO: return {"ready": false, "reason": "unsupported_support_orientation"}
	var seated := _post_seat_check(source, posts, support, orientation.basis)
	if not seated.ready: return seated
	var proofs: Array = []
	for bearing in description.clothBearing:
		var bound_bearing: Dictionary = bearing.duplicate(true)
		bound_bearing["cloth"] = originals[bearing.clothId]
		var proof := _cloth_corner_proof(source, originals[bearing.railId], bound_bearing)
		if not proof.ready: return proof
		proofs.append(proof)
	var staged = Blueprint.new(source.id, source.seed, source.style)
	for id in closure_ids + description.memberIds:
		var original = originals[id]
		var copy = staged.add_part(original.snapshot())
		copy.physical_intent = original.physical_intent
		_clean_caches(copy)
		if description.postIds.has(id): _bind_post(copy, support_id)
	var work := _validation_work(staged)
	if not work.ready: return work
	var physical: Dictionary = staged.validate_physical_integrity()
	var expected_count: int = closure_ids.size() + 11
	if physical.checks.size() != expected_count or not physical.violations.is_empty() or not physical.checks.all(func(check): return check.passed):
		return {"ready": false, "reason": "staged_frame_has_invalid_load_path", "violations": physical.violations}
	for part in staged.parts:
		for fact in part.recipe.get("physicalRequiredSeatFacts", []):
			if not staged.has_rooted_bearer_seat(part, fact): return {"ready": false, "reason": "staged_seat_invalid"}
		for fact in part.recipe.get("physicalRequiredAnchorFacts", []):
			if not _socket_inside_member(part, fact): return {"ready": false, "reason": "staged_socket_outside_attachment"}
			if not staged.has_rooted_attachment_socket(part, fact): return {"ready": false, "reason": "staged_anchor_invalid"}
	# Prepare both commits first, with no derived cache copies or geometry writes.
	var recipes: Dictionary = {}
	for id in description.postIds:
		var recipe: Dictionary = originals[id].recipe.duplicate(true)
		var bound = staged.find_part(id)
		recipe["physicalRequiredSeatPartIds"] = bound.recipe.physicalRequiredSeatPartIds.duplicate(true)
		recipe["physicalRequiredSeatFacts"] = bound.recipe.physicalRequiredSeatFacts.duplicate(true)
		recipes[id] = recipe
	for id in description.postIds: originals[id].recipe = recipes[id]
	return {"ready": true, "reason": "", "partIds": description.partIds.duplicate(), "memberIds": description.memberIds.duplicate(),
		"clothIds": description.clothIds.duplicate(), "clothBearing": proofs,
		"sourceClosureIds": closure_ids, "sourceClosurePhysicalBefore": closure.physical,
		"sourceRootIds": closure.rootIds, "sourceSupportEdges": closure.edges,
		"stagedPhysical": physical, "expectedPartCount": expected_count,
		"geometryPolicy": description.get("geometryPolicy", ""), "bindingChanges": "Only two post-seat declarations; planned world geometry untouched."}

static func _post_seat_check(blueprint, posts: Array, support, frame_basis: Basis) -> Dictionary:
	var support_top: float = support.position.y + support.size.y * 0.5
	var patch_world: Vector3 = frame_basis.x.abs() * 0.04 + frame_basis.z.abs() * 0.05
	for post in posts:
		var bottom: float = post.position.y - post.size.y * 0.5
		if absf(bottom - support_top) > blueprint.PHYSICAL_CONTACT_MARGIN or absf(post.position.x - support.position.x) + patch_world.x > support.size.x * 0.5 - blueprint.PHYSICAL_CONTACT_MARGIN or absf(post.position.z - support.position.z) + patch_world.z > support.size.z * 0.5 - blueprint.PHYSICAL_CONTACT_MARGIN:
			return {"ready": false, "reason": "post_does_not_seat_on_supplied_support"}
	return {"ready": true}

static func _bind_post(post, support_id: String) -> void:
	post.recipe["physicalRequiredSeatPartIds"] = [support_id]
	post.recipe["physicalRequiredSeatFacts"] = [Seats.world_down_seat_fact(support_id,
		Vector3(0.0, -post.size.y * 0.5, 0.0), Vector2(0.04, 0.05))]

static func _rigid_record_matches(source, part, record: Dictionary, delta: Transform3D) -> bool:
	if part.recipe.get("physicalRoot", false) != false: return false
	var actual: Dictionary = part.snapshot()
	var reference: Dictionary = record.duplicate(true)
	for candidate in [actual, reference]:
		candidate.erase("position")
		candidate.erase("rotation")
		for key in ["physicalRoot", "physicalSupportPartIds", "physicalSupportCoverage", "physicalAnchorPartIds", "physicalIntentResolution"]:
			candidate.recipe.erase(key)
	if actual != reference: return false
	var expected := delta * Transform3D(Basis.from_euler(record.rotation), record.position)
	var transformed: Transform3D = source.part_transform(part)
	return transformed.origin.distance_to(expected.origin) <= 0.00003 and _basis_close(transformed.basis, expected.basis)

static func _description_schema(description: Dictionary) -> Dictionary:
	if description.get("described") != true or description.get("descriptionVersion") != 1 or not description.get("prefix") is String:
		return {"ready": false, "reason": "invalid_frame_description"}
	var prefix: String = description.prefix
	if prefix.is_empty() or prefix != prefix.strip_edges(): return {"ready": false, "reason": "invalid_frame_description"}
	var added: Array = ADDED_SUFFIXES.map(func(suffix): return prefix + suffix)
	var members: Array = INPUT_SUFFIXES.map(func(suffix): return prefix + suffix) + added
	var posts: Array = [prefix + "_jamb_-1", prefix + "_jamb_1"]
	if description.get("partIds") != added or description.get("memberIds") != members or description.get("postIds") != posts or not description.get("records") is Array or description.records.size() != 11:
		return {"ready": false, "reason": "invalid_description_membership"}
	if not description.get("clothIds") is Array or not description.get("clothRecords") is Array or description.clothIds.size() < 2 or description.clothIds.size() > 32 or description.clothIds.size() != description.clothRecords.size() or not description.get("clothBearing") is Array or description.clothBearing.size() != 2:
		return {"ready": false, "reason": "invalid_description_cloth"}
	var records: Dictionary = {}
	for record in description.records + description.clothRecords:
		if not record is Dictionary or not record.get("id") is String or records.has(record.id) or not _description_record_shape(record):
			return {"ready": false, "reason": "invalid_description_record"}
		records[record.id] = record
	for id in members:
		if not records.has(id): return {"ready": false, "reason": "invalid_description_membership"}
		var record: Dictionary = records[id]
		var attachment: bool = id in [prefix + "_sign_arm", prefix + "_bracket_-1", prefix + "_bracket_1"]
		var permitted: Array = ["", "facade_attachment"] if attachment else ["structural_mass"]
		var intent: Variant = record.recipe.get("physicalIntent", "")
		if record.kind != "beam" or record.material != "timber_beam" or record.collision != (not attachment) or record.physicalIntent not in permitted or intent not in permitted or (not record.physicalIntent.is_empty() and not String(intent).is_empty() and record.physicalIntent != intent):
			return {"ready": false, "reason": "invalid_description_member_role", "partId": id}
		var seat_ids: Array = []
		var anchor_ids: Array = []
		if id == prefix + "_lintel": seat_ids = posts
		elif id in [added[0], added[1], added[2]]: seat_ids = [prefix + "_lintel"]
		elif id == added[3]: seat_ids = [added[2]]
		elif id == added[4]: seat_ids = [added[3]]
		elif id == prefix + "_sign_arm": anchor_ids = [added[4]]
		elif id == prefix + "_bracket_-1": anchor_ids = [posts[0], added[0]]
		elif id == prefix + "_bracket_1": anchor_ids = [posts[1], added[1]]
		if not _description_joints(record.recipe, seat_ids, anchor_ids): return {"ready": false, "reason": "invalid_description_joint_declarations", "partId": id}
	var seen_cloth: Array = []
	for id in description.clothIds:
		if not id is String or members.has(id) or seen_cloth.has(id) or not records.has(id) or records[id].semantic != "citadel_terminal_shop_awning": return {"ready": false, "reason": "invalid_description_cloth"}
		seen_cloth.append(id)
	for i in range(2):
		var bearing: Variant = description.clothBearing[i]
		if not bearing is Dictionary or bearing.get("railId") != added[i] or not seen_cloth.has(bearing.get("clothId")) or not bearing.get("spanLocalZ") is Vector2 or not bearing.spanLocalZ.is_finite() or bearing.spanLocalZ.x >= bearing.spanLocalZ.y or not (bearing.get("undersideLocalY") is float or bearing.get("undersideLocalY") is int) or not is_finite(bearing.undersideLocalY):
			return {"ready": false, "reason": "invalid_description_cloth_bearing"}
		if absf(bearing.undersideLocalY + records[bearing.clothId].size.y * 0.5) > 0.00001: return {"ready": false, "reason": "invalid_description_cloth_bearing"}
	return {"ready": true, "records": records}

static func _description_record_shape(record: Dictionary) -> bool:
	for key in ["id", "kind", "material", "semantic", "physicalIntent"]:
		if not record.get(key) is String: return false
	for key in ["position", "rotation", "size"]:
		if not record.get(key) is Vector3 or not record[key].is_finite(): return false
	if not _positive_vector3(record.size) or record.size.length() > 10000.0 or record.position.length() > 1000000.0 or not record.get("collision") is bool or not record.get("recipe") is Dictionary: return false
	return record.recipe.get("physicalRoot", false) == false and record.physicalIntent != "structural_root" and record.recipe.get("physicalIntent", "") != "structural_root"

static func _description_joints(recipe: Dictionary, seats: Array, anchors: Array) -> bool:
	var allowed: Array = []
	if not seats.is_empty(): allowed.append_array(["physicalRequiredSeatPartIds", "physicalRequiredSeatFacts"])
	if not anchors.is_empty(): allowed.append_array(["physicalRequiredAnchorPartIds", "physicalRequiredAnchorFacts"])
	for key in recipe:
		if String(key).begins_with("physicalRequired") and not allowed.has(key): return false
	for spec in [["physicalRequiredSeatPartIds", "physicalRequiredSeatFacts", "seatId", seats], ["physicalRequiredAnchorPartIds", "physicalRequiredAnchorFacts", "anchorId", anchors]]:
		if spec[3].is_empty(): continue
		if recipe.get(spec[0]) != spec[3] or not recipe.get(spec[1]) is Array or recipe[spec[1]].size() != spec[3].size(): return false
		var seen: Array = []
		for fact in recipe[spec[1]]:
			if not fact is Dictionary or not fact.get(spec[2]) is String or not spec[3].has(fact[spec[2]]) or seen.has(fact[spec[2]]): return false
			seen.append(fact[spec[2]])
			var center_key := "localOverlapCenter" if spec[2] == "seatId" else "localMountCenter"
			var half_key := "localOverlapHalfExtents" if spec[2] == "seatId" else "localMountHalfExtents"
			if not fact.get(center_key) is Vector3 or not fact[center_key].is_finite() or not _positive_vector3(fact.get(half_key)): return false
			if spec[2] == "seatId":
				if fact.get("contactMode") != "housed_overlap" or fact.get("localSpanAxis") not in ["x", "y", "z"]: return false
				for key in ["minimumLongitudinalEmbedment", "minimumVerticalOverlap"]:
					var value: Variant = fact.get(key)
					if not (value is float or value is int) or not is_finite(value) or value < 0.0: return false
			elif fact.get("contactMode") != "attachment_socket": return false
	return true

static func _add_legacy_frame(blueprint, prefix: String, support_id: String) -> Dictionary:
	# Original direct API only. Explicit construction has one description path.
	if blueprint == null or prefix.is_empty() or support_id.is_empty() or blueprint.parts.size() > MAX_SOURCE_PARTS:
		return {"ready": false, "reason": "invalid_frame_declaration"}
	var originals: Dictionary = {}
	for part in blueprint.parts:
		if part == null or String(part.id).is_empty() or originals.has(part.id):
			return {"ready": false, "reason": "missing_or_duplicate_part_id"}
		originals[part.id] = part
	var closure_ids: Array = [support_id]
	var input_ids: Array = closure_ids.duplicate()
	for suffix in INPUT_SUFFIXES:
		if closure_ids.has(prefix + suffix): return {"ready": false, "reason": "support_closure_contains_frame_member"}
		input_ids.append(prefix + suffix)
	var staged = Blueprint.new(blueprint.id, blueprint.seed, blueprint.style)
	for id in input_ids:
		var part = originals.get(id)
		if part == null:
			return {"ready": false, "reason": "missing_frame_member"}
		if not blueprint.has_finite_positive_bounds(part):
			return {"ready": false, "reason": "invalid_member_bounds"}
		for key in part.recipe:
			if String(key).begins_with("physicalRequired"):
				return {"ready": false, "reason": "member_already_has_joint_contract"}
		if closure_ids.has(id):
			if not blueprint.is_grounded_structural_root(part):
				return {"ready": false, "reason": "support_is_not_grounded_foundation"}
		else:
			if part.kind != "beam" or part.material_id != "timber_beam":
				return {"ready": false, "reason": "incompatible_frame_member"}
			if bool(part.recipe.get("physicalRoot", false)) or part.physical_intent == "structural_root":
				return {"ready": false, "reason": "frame_member_cannot_be_root"}
			if id in [prefix + "_sign_arm", prefix + "_bracket_-1", prefix + "_bracket_1"]:
				if part.collision_enabled or part.physical_intent not in ["", "facade_attachment"] or String(part.recipe.get("physicalIntent", "")) not in ["", "facade_attachment"]:
					return {"ready": false, "reason": "incompatible_attachment_intent"}
		var copy = staged.add_part(part.snapshot())
		copy.physical_intent = part.physical_intent
		_clean_caches(copy)
	var result := _assemble(staged, prefix, support_id)
	if not bool(result.ready):
		return result
	for id in result.partIds:
		if originals.has(id):
			return {"ready": false, "reason": "frame_already_present"}
	# Keep authored records separate from derived validation caches. Verification
	# is bounded to the explicit closure + six old members + five additions.
	var records: Array = staged.part_snapshots()
	for part in staged.parts:
		_clean_caches(part)
	var work := _validation_work(staged)
	if not work.ready: return work
	var validation: Dictionary = staged.validate_physical_integrity()
	var expected_count := closure_ids.size() + 6 + 5
	if records.size() != expected_count or validation.checks.size() != expected_count or not validation.violations.is_empty() or not validation.checks.all(func(check): return bool(check.passed)):
		return {"ready": false, "reason": "staged_frame_has_invalid_load_path", "violations": validation.violations}
	for part in staged.parts:
		for fact in part.recipe.get("physicalRequiredSeatFacts", []):
			if not staged.has_rooted_bearer_seat(part, fact):
				return {"ready": false, "reason": "staged_seat_invalid"}
		for fact in part.recipe.get("physicalRequiredAnchorFacts", []):
			if not _socket_inside_member(part, fact):
				return {"ready": false, "reason": "staged_socket_outside_attachment"}
			if not staged.has_rooted_attachment_socket(part, fact):
				return {"ready": false, "reason": "staged_anchor_invalid"}
	# No source mutation occurs before every member and mandatory joint passes.
	# Preserve original object identity/order and never write derived caches back.
	for record in records:
		if closure_ids.has(record.id):
			continue
		if not originals.has(record.id):
			blueprint.add_part(record)
			continue
		var part = originals[record.id]
		part.position = record.position
		part.rotation = record.rotation
		part.size = record.size
		part.collision_enabled = record.collision
		part.physical_intent = record.physicalIntent
		part.recipe = record.recipe.duplicate(true)
	return result

static func _validate_support_closure(source, originals: Dictionary, ids: Array) -> Dictionary:
	var staged = Blueprint.new(source.id, source.seed, source.style)
	var root_ids: Array = []
	for id in ids:
		var part = originals.get(id)
		if part == null: return {"ready": false, "reason": "missing_support_closure_part", "partId": id}
		if not source.has_finite_positive_bounds(part) or not part.collision_enabled:
			return {"ready": false, "reason": "invalid_support_closure_geometry", "partId": id}
		var recipe_intent: Variant = part.recipe.get("physicalIntent", "")
		if not recipe_intent is String or part.physical_intent not in ["", "structural_mass", "structural_root"] or recipe_intent not in ["", "structural_mass", "structural_root"] or (not part.physical_intent.is_empty() and not recipe_intent.is_empty() and part.physical_intent != recipe_intent):
			return {"ready": false, "reason": "incompatible_support_source_intent", "partId": id}
		var grounded: bool = source.is_grounded_structural_root(part)
		if grounded:
			# Stricter new API: actual y=0 bottom, not the owner's contact band.
			var bounds: AABB = source.transformed_part_bounds(part)
			if absf(bounds.position.y) > 0.00001 or part.rotation != Vector3.ZERO:
				return {"ready": false, "reason": "support_root_bottom_is_not_zero", "partId": id}
			root_ids.append(id)
		var root_flag: Variant = part.recipe.get("physicalRoot", false)
		if not root_flag is bool or (not grounded and (root_flag or part.physical_intent == "structural_root" or recipe_intent == "structural_root")):
			return {"ready": false, "reason": "forged_support_root", "partId": id}
		if not _support_schema_valid(part.recipe, ids):
			return {"ready": false, "reason": "invalid_support_closure_schema", "partId": id}
		var copy = staged.add_part(part.snapshot())
		copy.physical_intent = part.physical_intent
		_clean_caches(copy)
	if root_ids.is_empty(): return {"ready": false, "reason": "support_closure_has_no_actual_ground_root"}
	var work := _validation_work(staged)
	if not work.ready: return work
	var physical: Dictionary = staged.validate_physical_integrity()
	if physical.checks.size() != ids.size() or not physical.violations.is_empty() or not physical.checks.all(func(check): return check.passed and check.intent in ["structural_mass", "structural_root"]):
		return {"ready": false, "reason": "source_support_closure_invalid", "physical": physical}
	# Inspect the geometry-resolved graph, never input physicalSupport caches.
	# Required seats were geometrically validated above, so their links belong
	# here too. Do not discover/add an omitted source part on the caller's behalf.
	var edges: Dictionary = {}
	for part in staged.parts:
		for id in part.recipe.get("physicalRequiredSupportPartIds", []):
			if not part.recipe.get("physicalSupportPartIds", []).has(id): return {"ready": false, "reason": "required_support_contact_missing", "partId": part.id}
		var facts: Array = part.recipe.get("physicalRequiredSeatFacts", [])
		for fact in facts:
			if not staged.has_rooted_bearer_seat(part, fact): return {"ready": false, "reason": "source_required_seat_invalid", "partId": part.id}
		if facts.is_empty():
			for id in part.recipe.get("physicalRequiredSeatPartIds", []):
				var seat = staged.find_part(id)
				if seat == null or not staged.transformed_parts_overlap(part, seat, Blueprint.PHYSICAL_CONTACT_MARGIN) or not staged.has_rooted_support_chain(seat, {}): return {"ready": false, "reason": "source_required_seat_invalid", "partId": part.id}
		var dependencies: Array = []
		for key in ["physicalSupportPartIds", "physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds"]:
			for id in part.recipe.get(key, []):
				if not ids.has(id): return {"ready": false, "reason": "support_dependency_outside_closure"}
				if not dependencies.has(id): dependencies.append(id)
		edges[part.id] = dependencies
	var reachable: Array = [ids[0]]
	var cursor := 0
	while cursor < reachable.size():
		for id in edges[reachable[cursor]]:
			if not reachable.has(id): reachable.append(id)
		cursor += 1
	if reachable.size() != ids.size(): return {"ready": false, "reason": "unrelated_support_ancestor", "edges": edges}
	var ordered: Array = []
	for pass_index in range(ids.size()):
		var progressed := false
		for id in ids:
			if not ordered.has(id) and edges[id].all(func(dependency): return ordered.has(dependency)):
				ordered.append(id)
				progressed = true
		if not progressed: break
	if ordered.size() != ids.size(): return {"ready": false, "reason": "cyclic_support_closure", "edges": edges}
	return {"ready": true, "physical": physical, "rootIds": root_ids, "edges": edges}

static func _support_schema_valid(recipe: Dictionary, ids: Array) -> bool:
	# Bounded structural closure contract, not a new parser for every assembly.
	# Explicitly reject unsupported mandatory fields rather than silently drop.
	for key in recipe:
		if String(key).begins_with("physicalRequired") and key not in ["physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds", "physicalRequiredSeatFacts"]: return false
	for key in ["physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds"]:
		var values: Variant = recipe.get(key, [])
		if not values is Array or values.size() > MAX_SUPPORT_CLOSURE: return false
		var seen: Array = []
		for value in values:
			if not value is String or not ids.has(value) or seen.has(value): return false
			seen.append(value)
	var facts: Variant = recipe.get("physicalRequiredSeatFacts", [])
	if not facts is Array or facts.size() > MAX_SUPPORT_CLOSURE: return false
	var seen_facts: Array = []
	for fact in facts:
		if not fact is Dictionary or not fact.get("seatId") is String or not recipe.get("physicalRequiredSeatPartIds", []).has(fact.seatId) or seen_facts.has(fact.seatId): return false
		seen_facts.append(fact.seatId)
		if fact.get("contactMode") == "housed_overlap":
			if not fact.get("localOverlapCenter") is Vector3 or not fact.localOverlapCenter.is_finite() or not _positive_vector3(fact.get("localOverlapHalfExtents")) or fact.get("localSpanAxis") not in ["x", "y", "z"]: return false
			for key in ["minimumLongitudinalEmbedment", "minimumVerticalOverlap"]:
				var value: Variant = fact.get(key, 0.0)
				if not (value is float or value is int) or not is_finite(value) or value < 0.0: return false
		elif fact.get("loadDirection") == "world_down":
			if fact.get("seatFace") != "max_y" or not fact.get("localPatchCenter") is Vector3 or not fact.localPatchCenter.is_finite(): return false
			var half: Variant = fact.get("localPatchHalfExtents")
			if not half is Vector2 or not half.is_finite() or half.x <= 0.0 or half.y <= 0.0: return false
		else: return false
	if not facts.is_empty() and facts.size() != recipe.get("physicalRequiredSeatPartIds", []).size(): return false
	if recipe.has("physicalAssemblyRole") and not recipe.physicalAssemblyRole is String: return false
	return true

static func _positive_vector3(value: Variant) -> bool:
	return value is Vector3 and value.is_finite() and value.x > 0.0 and value.y > 0.0 and value.z > 0.0

static func _clean_caches(part) -> void:
	for key in ["physicalRoot", "physicalSupportPartIds", "physicalSupportCoverage", "physicalAnchorPartIds", "physicalIntentResolution"]:
		part.recipe.erase(key)

static func _validation_work(b) -> Dictionary:
	# Bound actual transformed grid insertion AND contact-query extents before
	# invoking the production validator, including huge finite rotated parts.
	var total := 0.0
	for part in b.parts:
		if not b.has_finite_positive_bounds(part): return {"ready": false, "reason": "invalid_validation_bounds"}
		var bounds: AABB = b.transformed_part_bounds(part).grow(Blueprint.PHYSICAL_CONTACT_MARGIN * sqrt(3.0))
		if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite(): return {"ready": false, "reason": "invalid_validation_bounds"}
		var cells: Array = [floorf(bounds.position.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL), floorf(bounds.end.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL), floorf(bounds.position.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL), floorf(bounds.end.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL)]
		if cells.any(func(value): return not is_finite(value) or absf(value) > 10000000.0): return {"ready": false, "reason": "validation_grid_work_limit"}
		var nx: float = cells[1] - cells[0] + 1.0
		var nz: float = cells[3] - cells[2] + 1.0
		if nx < 1.0 or nz < 1.0 or nx > 4096.0 or nz > 4096.0: return {"ready": false, "reason": "validation_grid_work_limit"}
		total += nx * nz
		if nx * nz > 4096.0 or total > 65536.0: return {"ready": false, "reason": "validation_grid_work_limit"}
	return {"ready": true, "expandedCells": total}

static func _socket_inside_member(part, fact: Dictionary) -> bool:
	var center: Vector3 = fact.get("localMountCenter", Vector3.INF)
	var half: Vector3 = fact.get("localMountHalfExtents", Vector3.INF)
	if not center.is_finite() or not half.is_finite():
		return false
	for axis in range(3):
		if half[axis] <= 0.0 or absf(center[axis]) + half[axis] > part.size[axis] * 0.5:
			return false
	return true

static func _assemble(blueprint, prefix: String, support_id: String, allow_quarter_turn := false, cloth: Array = [], unbound := false) -> Dictionary:
	var header = _find(blueprint, prefix + "_lintel")
	var sign = _find(blueprint, prefix + "_sign_arm")
	var support = _find(blueprint, support_id)
	var posts: Array = [_find(blueprint, prefix + "_jamb_-1"), _find(blueprint, prefix + "_jamb_1")]
	var brackets: Array = [_find(blueprint, prefix + "_bracket_-1"), _find(blueprint, prefix + "_bracket_1")]
	if header == null or sign == null or (not unbound and support == null) or posts.has(null) or brackets.has(null):
		return {"ready": false, "reason": "missing_frame_member"}
	for part in [header, sign] + posts + brackets + ([] if unbound else [support]):
		if not blueprint.has_finite_positive_bounds(part):
			return {"ready": false, "reason": "invalid_member_bounds"}
	var frame_basis := Basis.IDENTITY
	if allow_quarter_turn:
		var orientation := _frame_orientation(blueprint, header, sign, posts, brackets)
		if not orientation.ready: return orientation
		frame_basis = orientation.basis
		# Selected support and ancestors remain actual world-space records. The
		# existing rectangular support-seat precheck requires an unrotated slab.
		if not unbound and support.rotation != Vector3.ZERO:
			return {"ready": false, "reason": "unsupported_support_orientation"}
	else:
		for part in [header, sign, support] + posts:
			if part.rotation != Vector3.ZERO:
				return {"ready": false, "reason": "unsupported_frame_orientation"}
	var oriented := frame_basis != Basis.IDENTITY
	var frame := Transform3D(frame_basis, header.position)
	var frame_inverse := frame.affine_inverse()
	var new_ids: Array = ADDED_SUFFIXES.map(func(suffix): return prefix + suffix)
	for id in new_ids:
		if _find(blueprint, id) != null:
			return {"ready": false, "reason": "frame_already_present"}
	# Validate source seats before altering any records. These are real supplied
	# retaining bounds, not a new root inferred from a convenient visual floor.
	if not unbound:
		var seat_check := _post_seat_check(blueprint, posts, support, frame_basis)
		if not seat_check.ready: return seat_check
	var header_facts: Array = []
	var post_ids: Array = []
	var cloth_bearings: Array = []
	if allow_quarter_turn:
		var cloth_validation := _consistent_cloth(blueprint, cloth, frame_basis)
		if not cloth_validation.ready: return cloth_validation
	for index in range(2):
		var post = posts[index]
		var bracket = brackets[index]
		post_ids.append(String(post.id))
		_mass(post)
		if not unbound: _bind_post(post, support_id)
		var joint_world := Vector3(post.position.x, header.position.y - 0.03, post.position.z)
		header_facts.append(_housed(post.id, frame_basis.transposed() * (joint_world - header.position), Vector3(0.075, 0.065, 0.06), "x"))
		# Both bays project forward in the same direction. Derive each brace
		# from its post socket and its rail socket rather than mirroring Euler angles.
		var rail_start := Vector3(post.position.x, header.position.y, header.position.z + 0.055)
		var rail_end := Vector3(post.position.x, header.position.y - 0.24, header.position.z - 1.53)
		var post_local: Vector3 = frame_inverse * post.position
		if oriented:
			rail_start = frame * Vector3(post_local.x, 0.0, 0.055)
			rail_end = frame * Vector3(post_local.x, -0.24, -1.53)
		var bearing: Dictionary = {}
		if allow_quarter_turn:
			bearing = _cloth_rail(blueprint, cloth, rail_start, rail_end, Vector2(0.16, 0.16))
			if not bearing.ready: return bearing
			rail_start = bearing.start
			rail_end = bearing.end
		var rail_record := _beam_between(new_ids[index], rail_start, rail_end, Vector2(0.16, 0.16), frame_basis.x)
		var rail = blueprint.add_part(rail_record)
		if allow_quarter_turn:
			var proof := _cloth_corner_proof(blueprint, rail, bearing)
			if not proof.ready: return proof
			cloth_bearings.append(proof)
		_mass(rail)
		rail.recipe["physicalRequiredSeatPartIds"] = [header.id]
		rail.recipe["physicalRequiredSeatFacts"] = [_housed(header.id, Vector3(0, -rail.size.y * 0.5 + 0.085, 0), Vector3(0.045, 0.065, 0.025), "y")]
		var brace_start := Vector3(post.position.x, header.position.y - 0.62, post.position.z + 0.05)
		if oriented:
			brace_start = frame * Vector3(post_local.x, -0.62, post_local.z + 0.05)
		var brace_end := rail_start.lerp(rail_end, 0.95)
		var brace_record := _beam_between(bracket.id, brace_start, brace_end, Vector2(0.15, 0.15), frame_basis.x)
		bracket.position = brace_record.position
		bracket.rotation = brace_record.rotation
		bracket.size = brace_record.size
		# This explicit profile change is part of the reviewed joinery proposal:
		# it retains material/custom-data but not the previous bent silhouette.
		bracket.recipe["preserveBearingFaces"] = true
		bracket.recipe["physicalRequiredAnchorPartIds"] = [post.id, rail.id]
		bracket.recipe["physicalRequiredAnchorFacts"] = [
			_socket(post.id, Vector3(0, -bracket.size.y * 0.5 + 0.08, 0), Vector3(0.035, 0.065, 0.025)),
			_socket(rail.id, Vector3(0, bracket.size.y * 0.5 - 0.075, 0), Vector3(0.035, 0.06, 0.02))]
	_mass(header)
	header.recipe["physicalRequiredSeatPartIds"] = post_ids
	header.recipe["physicalRequiredSeatFacts"] = header_facts
	# Route the sign support behind the unchanged cloth's rear edge, not through
	# its surface. The lower standoff stays beneath the cloth; the upper one is
	# above it. Existing sign and awning positions are untouched.
	var sign_local: Vector3 = frame_inverse * sign.position
	var base_position := Vector3(sign.position.x, header.position.y - 0.10, header.position.z + 0.30)
	var mount_position := Vector3(sign.position.x, header.position.y + 0.25, header.position.z + 0.52)
	var top_position := Vector3(sign.position.x, sign.position.y, header.position.z + 0.23)
	if oriented:
		base_position = frame * Vector3(sign_local.x, -0.10, 0.30)
		mount_position = frame * Vector3(sign_local.x, 0.25, 0.52)
		top_position = frame * Vector3(sign_local.x, sign_local.y, 0.23)
	var base = _new_mount(blueprint, new_ids[2], base_position, Vector3(0.16, 0.16, 0.68), header, frame_basis)
	base.recipe["physicalRequiredSeatPartIds"] = [header.id]
	base.recipe["physicalRequiredSeatFacts"] = [_housed(header.id, Vector3(0, 0.02, -0.265), Vector3(0.045, 0.03, 0.065), "z")]
	var mount = _new_mount(blueprint, new_ids[3], mount_position, Vector3(0.16, 0.74, 0.16), header, frame_basis)
	_mass(mount)
	mount.recipe["physicalRequiredSeatPartIds"] = [base.id]
	mount.recipe["physicalRequiredSeatFacts"] = [_housed(base.id, Vector3(0, -0.32, 0), Vector3(0.045, 0.035, 0.065), "z")]
	var top = _new_mount(blueprint, new_ids[4], top_position, Vector3(0.16, 0.12, 0.80), header, frame_basis)
	top.recipe["physicalRequiredSeatPartIds"] = [mount.id]
	top.recipe["physicalRequiredSeatFacts"] = [_housed(mount.id, Vector3(0, 0, 0.29), Vector3(0.04, 0.035, 0.065), "z")]
	sign.recipe["physicalRequiredAnchorPartIds"] = [top.id]
	sign.recipe["physicalRequiredAnchorFacts"] = [_socket(top.id, Vector3.ZERO, Vector3(0.05, 0.025, 0.025))]
	var result := {"ready": true, "reason": "", "partIds": new_ids}
	if allow_quarter_turn:
		result["clothBearing"] = cloth_bearings
		result["clothIds"] = cloth.map(func(part): return part.id)
		result["geometryPolicy"] = "Actual cloth underside, parallel upper rail face, original full longitudinal endpoint projections retained; no cloth/source-support edits. Direct API remains legacy geometry."
	return result

static func _new_mount(blueprint, id: String, position: Vector3, size: Vector3, header, frame_basis := Basis.IDENTITY):
	var part = blueprint.add_part({"id": id, "kind": "beam", "material": "timber_beam", "position": position,
		"size": size, "collision": true, "semantic": "terminal_sign_mount", "recipe": {"variation": header.recipe.get("variation", 0.0)}})
	if frame_basis != Basis.IDENTITY:
		part.rotation = frame_basis.get_euler()
	_mass(part)
	return part

static func _mass(part) -> void:
	part.collision_enabled = true
	part.physical_intent = "structural_mass"
	part.recipe["physicalIntent"] = "structural_mass"
	part.recipe["preserveBearingFaces"] = true

static func _beam_between(id: String, start: Vector3, end: Vector3, section: Vector2, row_right := Vector3.RIGHT) -> Dictionary:
	var direction := (end - start).normalized()
	var transverse := row_right.cross(direction).normalized()
	var basis := Basis(direction.cross(transverse).normalized(), direction, transverse)
	return {"id": id, "kind": "beam", "material": "timber_beam", "position": (start + end) * 0.5,
		"rotation": basis.get_euler(), "size": Vector3(section.x, start.distance_to(end), section.y),
		"collision": true, "semantic": "terminal_awning_frame", "recipe": {"preserveBearingFaces": true}}

static func _housed(id: String, center: Vector3, half: Vector3, axis: String) -> Dictionary:
	return {"seatId": id, "contactMode": "housed_overlap", "localOverlapCenter": center,
		"localOverlapHalfExtents": half, "localSpanAxis": axis,
		"minimumLongitudinalEmbedment": 0.12, "minimumVerticalOverlap": 0.04}

static func _socket(id: String, center: Vector3, half: Vector3) -> Dictionary:
	return {"anchorId": id, "contactMode": "attachment_socket", "localMountCenter": center, "localMountHalfExtents": half}

static func _find(blueprint, id: String):
	for part in blueprint.parts:
		if part.id == id:
			return part
	return null

static func _frame_orientation(blueprint, header, sign, posts: Array, brackets: Array) -> Dictionary:
	# Compare bases, not Euler encodings (Godot re-encodes yaw 180/270).
	# Snap only the inferred construction basis; do not rewrite input members.
	var actual: Basis = blueprint.part_transform(header).basis
	var quarters: Array[Basis] = [Basis.IDENTITY,
		Basis(Vector3(0, 0, -1), Vector3.UP, Vector3.RIGHT),
		Basis(Vector3.LEFT, Vector3.UP, Vector3.FORWARD),
		Basis(Vector3.BACK, Vector3.UP, Vector3.LEFT)]
	var selected := -1
	for i in range(quarters.size()):
		if _basis_close(actual, quarters[i]): selected = i
	if selected < 0:
		return {"ready": false, "reason": "unsupported_frame_orientation"}
	var basis: Basis = quarters[selected]
	for part in [sign] + posts:
		if not _basis_close(blueprint.part_transform(part).basis, basis):
			return {"ready": false, "reason": "mixed_frame_orientation", "partId": part.id}
	for bracket in brackets:
		# Existing braces legitimately pitch about row-local X. They must not
		# carry a different yaw/roll before their reviewed socket reconstruction.
		var local: Basis = basis.transposed() * blueprint.part_transform(bracket).basis
		if not local.is_finite() or local.x.distance_to(Vector3.RIGHT) > 0.00001 or absf(local.determinant() - 1.0) > 0.00001:
			return {"ready": false, "reason": "mixed_frame_orientation", "partId": bracket.id}
	return {"ready": true, "basis": basis, "quarterTurn": selected}

static func _basis_close(a: Basis, b: Basis) -> bool:
	return a.is_finite() and a.x.distance_to(b.x) <= 0.00001 and a.y.distance_to(b.y) <= 0.00001 and a.z.distance_to(b.z) <= 0.00001

static func _collect_cloth(blueprint, prefix: String) -> Dictionary:
	# Existing public producer prefix convention, with actual role/geometry.
	# No seven-strip ID list, seed exception, copied producer or scene lookup.
	var parts: Array = []
	for part in blueprint.parts:
		if not String(part.id).begins_with(prefix + "_awning_") or part.semantic != "citadel_terminal_shop_awning": continue
		if parts.size() >= 32: return {"ready": false, "reason": "cloth_collection_limit"}
		if not blueprint.has_finite_positive_bounds(part) or part.size.length() > 10000.0 or part.position.length() > 1000000.0:
			return {"ready": false, "reason": "invalid_cloth_geometry", "partId": part.id}
		if part.kind != "decor" or part.collision_enabled or not bool(part.recipe.get("visual", true)) or part.size.y >= minf(part.size.x, part.size.z):
			return {"ready": false, "reason": "incompatible_cloth_source", "partId": part.id}
		parts.append(part) # Read-only geometry input, never staged/committed as mass.
	if parts.size() < 2: return {"ready": false, "reason": "missing_cloth"}
	return {"ready": true, "parts": parts}

static func _consistent_cloth(blueprint, parts: Array, row_basis: Basis) -> Dictionary:
	if parts.size() < 2: return {"ready": false, "reason": "missing_cloth"}
	var reference: Basis = blueprint.part_transform(parts[0]).basis
	if reference.x.distance_to(row_basis.x) > 0.00001 or reference.y.dot(Vector3.UP) < 0.5 or reference.z.dot(row_basis.z) < 0.5:
		return {"ready": false, "reason": "inconsistent_cloth_orientation"}
	var rows: Array = []
	for part in parts:
		if not _basis_close(reference, blueprint.part_transform(part).basis):
			return {"ready": false, "reason": "inconsistent_cloth_orientation", "partId": part.id}
		var center: Vector3 = row_basis.transposed() * part.position
		rows.append({"id": part.id, "center": center, "size": part.size})
	rows.sort_custom(func(a, b): return a.center.x < b.center.x)
	for i in range(1, rows.size()):
		var a: Dictionary = rows[i - 1]
		var b: Dictionary = rows[i]
		var gap: float = b.center.x - b.size.x * 0.5 - (a.center.x + a.size.x * 0.5)
		# Permit ordinary narrow cloth seams, not a missing strip or overlap.
		if gap < -0.00001 or gap > minf(a.size.x, b.size.x) * 0.10 or absf(a.center.z - b.center.z) > 0.00001 or absf(a.size.z - b.size.z) > 0.00001 or absf(a.size.y - b.size.y) > 0.00001 or absf(a.center.y - b.center.y) > maxf(a.size.y, b.size.y):
			return {"ready": false, "reason": "inconsistent_or_missing_cloth_strip", "partIds": [a.id, b.id]}
	return {"ready": true}

static func _cloth_rail(blueprint, parts: Array, original_start: Vector3, original_end: Vector3, section: Vector2) -> Dictionary:
	var candidates: Array = []
	for cloth in parts:
		var transform: Transform3D = blueprint.part_transform(cloth)
		var inverse := transform.affine_inverse()
		var start: Vector3 = inverse * original_start
		var end: Vector3 = inverse * original_end
		if absf(start.x) + section.x * 0.5 > cloth.size.x * 0.5 or absf(end.x) + section.x * 0.5 > cloth.size.x * 0.5: continue
		if absf(start.x - end.x) > 0.00001 or start.z <= end.z or absf(start.z) > cloth.size.z * 0.5 or absf(end.z) > cloth.size.z * 0.5:
			return {"ready": false, "reason": "cloth_does_not_cover_full_rail_span", "clothId": cloth.id}
		# Preserve BOTH longitudinal projections, including the header end.
		# Only the normal coordinate is solved: top face == actual underside.
		# No measured defect offset, yaw-specific pose, or shortened stub.
		var underside: float = -cloth.size.y * 0.5
		start.y = underside - section.y * 0.5
		end.y = start.y
		candidates.append({"ready": true, "cloth": cloth, "start": transform * start, "end": transform * end,
			"spanLocalZ": Vector2(end.z, start.z), "undersideLocalY": underside})
	if candidates.size() != 1:
		return {"ready": false, "reason": "missing_or_ambiguous_rail_cloth", "candidates": candidates.size()}
	return candidates[0]

static func _cloth_corner_proof(blueprint, rail, bearing: Dictionary) -> Dictionary:
	# Test the rounded stored Euler/position/size, not just ideal solved points.
	# 30 micrometres is a float-transform comparison tolerance, not embed policy.
	var cloth = bearing.cloth
	var relative: Transform3D = blueprint.part_transform(cloth).affine_inverse() * blueprint.part_transform(rail)
	var corners: Array = []
	var min_z := INF
	var max_z := -INF
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				var point: Vector3 = relative * (rail.size * Vector3(x, y, z) * 0.5)
				var delta: float = point.y - bearing.undersideLocalY
				if absf(point.x) > cloth.size.x * 0.5 + 0.00003 or absf(point.z) > cloth.size.z * 0.5 + 0.00003 or delta > 0.00003 or (z > 0.0 and absf(delta) > 0.00003):
					return {"ready": false, "reason": "rail_outside_cloth_underside_envelope", "railId": rail.id, "clothId": cloth.id, "corner": point}
				min_z = minf(min_z, point.z)
				max_z = maxf(max_z, point.z)
				corners.append({"clothLocal": point, "upperFace": z > 0.0, "normalGap": delta})
	if absf(min_z - bearing.spanLocalZ.x) > 0.00003 or absf(max_z - bearing.spanLocalZ.y) > 0.00003:
		return {"ready": false, "reason": "rail_longitudinal_span_changed"}
	return {"ready": true, "railId": rail.id, "clothId": cloth.id, "corners": corners,
		"spanLocalZ": bearing.spanLocalZ, "undersideLocalY": bearing.undersideLocalY,
		"fullSpanRetained": true, "upperFaceBearing": true}

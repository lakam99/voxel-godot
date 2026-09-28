extends RefCounted

## Complete mandatory load paths for the gable-supported purlin grammar.
## The general support graph's ANY reachable edge is insufficient here.
static func is_frame_part(member) -> bool:
	return member.recipe.has("physicalGableFrameId") or String(member.recipe.get("physicalAssemblyRole", "")).begins_with("gable_roof_")

static func context_for(blueprint, checks: Array) -> Dictionary:
	var context := {"checks": {}, "duplicates": false, "frames": {}}
	for check in checks:
		context.checks[String(check.partId)] = bool(check.passed)
	var ids: Dictionary = {}
	for part in blueprint.parts:
		if part == null:
			continue
		context.duplicates = context.duplicates or ids.has(String(part.id))
		ids[String(part.id)] = true
		if is_frame_part(part):
			context.frames[String(part.id)] = true
	return context

static func validates(blueprint, member, context: Dictionary) -> bool:
	if not schema_valid(member) or bool(context.duplicates):
		return false
	var frame := String(member.recipe.get("physicalGableFrameId", ""))
	if frame.is_empty():
		return false
	var excluded: Dictionary = context.frames
	match String(member.recipe.get("physicalAssemblyRole", "")):
		"gable_roof_post":
			return _post(blueprint, member, frame, excluded, context)
		"gable_roof_purlin":
			return _purlin(blueprint, member, frame, excluded, context)
		"gable_roof_panel":
			var ids: Array = member.recipe.get("physicalRequiredPurlinPartIds", [])
			if not _facts_match(member, ids, 2, "housed_overlap"):
				return false
			var positions: Array = []
			var common_bearers: Array = []
			for index in range(2):
				var purlin = blueprint.find_part(String(ids[index]))
				if not _is_member(purlin, frame, "gable_roof_purlin") or not _purlin(blueprint, purlin, frame, excluded, context):
					return false
				positions.append(purlin.position.x)
				var bearer_ids: Array = []
				for post_id in purlin.recipe.physicalRequiredPostPartIds:
					bearer_ids.append(String(blueprint.find_part(String(post_id)).recipe.physicalRequiredGableBearerId))
				bearer_ids.sort()
				if index == 0:
					common_bearers = bearer_ids
				elif common_bearers != bearer_ids:
					return false
			if not _brackets(positions, member.position.x):
				return false
			for fact in member.recipe.physicalRequiredSeatFacts:
				if String(fact.get("localSpanAxis", "")) != "x" or not blueprint.has_rooted_bearer_seat(member, fact, {String(member.id): true}):
					return false
			return member.collision_enabled and member.physical_intent == "structural_mass"
	return false

static func _post(blueprint, post, frame: String, excluded: Dictionary, context: Dictionary) -> bool:
	if not _is_member(post, frame, "gable_roof_post") or post.rotation != Vector3.ZERO:
		return false
	var bearer_id := String(post.recipe.get("physicalRequiredGableBearerId", ""))
	var bearer = blueprint.find_part(bearer_id)
	if bearer == null or bearer.kind != "wall" or excluded.has(bearer_id) or not bearer.collision_enabled:
		return false
	if not _facts_match(post, [bearer_id], 1, "world_down"):
		return false
	# The gable must reach existing masonry without using this roof/frame.
	return blueprint.has_rooted_bearer_seat(post, post.recipe.physicalRequiredSeatFacts[0], excluded) and _complete_existing_path(blueprint, bearer, context, excluded)

static func _purlin(blueprint, purlin, frame: String, excluded: Dictionary, context: Dictionary) -> bool:
	if not _is_member(purlin, frame, "gable_roof_purlin") or purlin.rotation != Vector3.ZERO:
		return false
	var ids: Array = purlin.recipe.get("physicalRequiredPostPartIds", [])
	if not _facts_match(purlin, ids, 2, "world_down"):
		return false
	var positions: Array = []
	var bearer_ids: Array = []
	for post_id in ids:
		var post = blueprint.find_part(String(post_id))
		if not _post(blueprint, post, frame, excluded, context):
			return false
		positions.append(post.position.z)
		bearer_ids.append(String(post.recipe.physicalRequiredGableBearerId))
	if bearer_ids[0] == bearer_ids[1] or not _brackets(positions, purlin.position.z):
		return false
	for fact in purlin.recipe.physicalRequiredSeatFacts:
		if not blueprint.has_rooted_bearer_seat(purlin, fact, {String(purlin.id): true}):
			return false
	return true

static func _is_member(member, frame: String, role: String) -> bool:
	return schema_valid(member) and String(member.recipe.get("physicalGableFrameId", "")) == frame and String(member.recipe.get("physicalAssemblyRole", "")) == role

static func schema_valid(member) -> bool:
	if member == null or not member.collision_enabled or member.physical_intent != "structural_mass":
		return false
	if String(member.id).strip_edges().is_empty():
		return false
	var role := String(member.recipe.get("physicalAssemblyRole", ""))
	if role not in ["gable_roof_panel", "gable_roof_purlin", "gable_roof_post"] or member.kind != ("roof" if role == "gable_roof_panel" else "beam"):
		return false
	if not member.position.is_finite() or not member.rotation.is_finite() or not member.size.is_finite() or member.size.x <= 0 or member.size.y <= 0 or member.size.z <= 0:
		return false
	if not member.recipe.get("physicalGableFrameId") is String or String(member.recipe.get("physicalGableFrameId", "")).is_empty():
		return false
	if member.recipe.has("physicalRequiredGableBearerId") and (not member.recipe.physicalRequiredGableBearerId is String or member.recipe.physicalRequiredGableBearerId.is_empty()):
		return false
	for key in ["physicalRequiredSeatPartIds", "physicalRequiredPurlinPartIds", "physicalRequiredPostPartIds", "physicalRequiredSupportPartIds"]:
		var values = member.recipe.get(key, [])
		if not values is Array or not values.all(func(value): return value is String and not value.is_empty()):
			return false
	# This closed grammar expresses every mandatory dependency through seats.
	# Do not silently ignore a second set of obligations beside that contract.
	if not (member.recipe.get("physicalRequiredSupportPartIds", []) as Array).is_empty():
		return false
	var facts = member.recipe.get("physicalRequiredSeatFacts", [])
	if not facts is Array:
		return false
	for fact in facts:
		if not fact is Dictionary or not fact.get("seatId") is String:
			return false
		if fact.get("contactMode", "") == "housed_overlap":
			if not fact.get("localOverlapCenter") is Vector3 or not fact.get("localOverlapHalfExtents") is Vector3:
				return false
			var half: Vector3 = fact.localOverlapHalfExtents
			if not fact.localOverlapCenter.is_finite() or not half.is_finite() or half.x <= 0 or half.y <= 0 or half.z <= 0:
				return false
			for key in ["minimumLongitudinalEmbedment", "minimumVerticalOverlap"]:
				var value = fact.get(key, 0.0)
				if not (value is float or value is int) or not is_finite(float(value)) or float(value) < 0:
					return false
		elif fact.get("loadDirection", "") == "world_down":
			if not fact.get("localPatchCenter") is Vector3 or not fact.get("localPatchHalfExtents") is Vector2:
				return false
			var half: Vector2 = fact.localPatchHalfExtents
			if not fact.localPatchCenter.is_finite() or not half.is_finite() or half.x <= 0 or half.y <= 0:
				return false
		else:
			return false
	return true

static func _complete_existing_path(blueprint, member, context: Dictionary, visited: Dictionary) -> bool:
	if member == null or visited.has(String(member.id)) or not bool(context.checks.get(String(member.id), false)):
		return false
	if bool(member.recipe.get("physicalRoot", false)):
		return blueprint.is_grounded_structural_root(member)
	var next := visited.duplicate()
	next[String(member.id)] = true
	for key in ["physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds"]:
		for part_id in member.recipe.get(key, []):
			if not _complete_existing_path(blueprint, blueprint.find_part(String(part_id)), context, next):
				return false
	for key in ["physicalSupportPartIds", "physicalRequiredSeatPartIds"]:
		for part_id in member.recipe.get(key, []):
			if _complete_existing_path(blueprint, blueprint.find_part(String(part_id)), context, next):
				return true
	return false

static func _brackets(values: Array, center: float) -> bool:
	return values.size() == 2 and minf(values[0], values[1]) < center - 0.05 and maxf(values[0], values[1]) > center + 0.05

static func _facts_match(member, ids: Array, count: int, mode: String) -> bool:
	var declared: Array = member.recipe.get("physicalRequiredSeatPartIds", [])
	var facts: Array = member.recipe.get("physicalRequiredSeatFacts", [])
	if ids.size() != count or declared.size() != count or facts.size() != count:
		return false
	var seen: Dictionary = {}
	for value in ids:
		var part_id := String(value)
		if part_id.is_empty() or seen.has(part_id) or declared.count(part_id) != 1:
			return false
		seen[part_id] = true
	var fact_ids: Dictionary = {}
	for value in facts:
		if not value is Dictionary:
			return false
		var fact: Dictionary = value
		var part_id := String(fact.get("seatId", ""))
		if not seen.has(part_id) or fact_ids.has(part_id):
			return false
		if mode == "world_down":
			if String(fact.get("loadDirection", "")) != mode or String(fact.get("contactMode", "")) == "housed_overlap":
				return false
		elif String(fact.get("contactMode", "")) != mode:
			return false
		fact_ids[part_id] = true
	return true

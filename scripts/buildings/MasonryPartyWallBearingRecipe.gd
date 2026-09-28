extends RefCounted

## Source recipe. A procedural facade that physically enters a distinct
## rooted masonry volume may use that existing party wall as a finite housed
## bearing. No geometry is added or moved and no collision is removed.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Aperture = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Materials = preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const SupportMemo = preload("res://scripts/buildings/BuildingSupportResolutionMemo.gd")
const MAX_PARTS := 8192
const MAX_DECLARATION_PARTS := 512
const JOINT_INSET := 0.006
const LOWER_BAND_HEIGHT := 0.24
const BOTTOM_COHORT_TOLERANCE := 0.01
const END_TOUCH_TOLERANCE := 0.012
const MIN_TRANSVERSE := 0.08
const MIN_LONGITUDINAL := 0.12
const MIN_VERTICAL := 0.04

## Owned by one completion operation, never stored in a blueprint or save.
## Bind derived artifacts too: a matching source cannot authorize a modified proof.
class ProofContext extends RefCounted:
	var source_bytes := PackedByteArray()
	var proof: Variant = null
	var report: Dictionary = {}
	var proof_bytes := PackedByteArray()
	var report_bytes := PackedByteArray()
	var invalid_gable_bytes := PackedByteArray()
	var independent_validations := 0
	var geometric_rejections := 0

static func prepare_context(source, continuation: Callable = Callable()) -> Dictionary:
	return _prepare_context(source,continuation,null)

## Composer-private optimization; public contexts never retain the shared store.
static func _prepare_context_with_support_memo(source, continuation: Callable, identities: Dictionary) -> Dictionary:
	var result := _prepare_context(source,continuation,identities)
	if not result.ready: identities.clear()
	return result

static func _prepare_context(source, continuation: Callable, identities: Variant) -> Dictionary:
	if not source is Blueprint or source.parts.size()>MAX_PARTS: return _fail("invalid_or_unbounded_source")
	var seen: Dictionary={}
	for part in source.parts:
		if not part is Part or part.id.is_empty() or seen.has(part.id) or not source.has_finite_positive_bounds(part):
			return _fail("invalid_or_duplicate_source_part")
		seen[part.id]=true
	var context := ProofContext.new()
	context.source_bytes=var_to_bytes(source.snapshot())
	if not _continue(continuation,"party_wall_proof_started"): return _fail("cancelled")
	if context.source_bytes!=var_to_bytes(source.snapshot()): return _fail("stale_party_wall_source_proof")
	context.proof=Copy.copy_blueprint(source.snapshot())
	if identities != null:
		var memo := SupportMemo.new(context.proof.id,context.proof.seed,context.proof.style)
		memo.recipe=context.proof.recipe; memo.rooms=context.proof.rooms; memo.parts=context.proof.parts
		memo.identities=identities
		context.proof=memo
	Copy.clear_caches(context.proof)
	var grid := Copy.validation_grid_work(context.proof)
	if not grid.ready: return grid
	context.report=context.proof.validate_physical_integrity_cancellable(continuation)
	if identities != null: context.proof.identities={}
	if context.report.get("cancelled",false): return _fail("cancelled")
	if not _continue(continuation,"party_wall_proof_completed"): return _fail("cancelled")
	if context.source_bytes!=var_to_bytes(source.snapshot()): return _fail("stale_party_wall_source_proof")
	context.proof_bytes=var_to_bytes(context.proof.snapshot())
	context.report_bytes=var_to_bytes(context.report)
	context.invalid_gable_bytes=var_to_bytes(context.proof.invalid_gable_part_ids)
	return {"ready":true,"context":context}

static func _context_valid(source, context: Variant) -> Dictionary:
	if not context is ProofContext or not context.proof is Blueprint or context.source_bytes.is_empty() or context.proof_bytes.is_empty() or context.report_bytes.is_empty():
		return _fail("invalid_party_wall_proof_context")
	if context.source_bytes!=var_to_bytes(source.snapshot()): return _fail("stale_party_wall_source_proof")
	if context.proof_bytes!=var_to_bytes(context.proof.snapshot()) or context.report_bytes!=var_to_bytes(context.report):
		return _fail("modified_party_wall_proof_context")
	# These lookup/validation facts are not part of Blueprint.snapshot(), but
	# rooted seat queries consume them. They must still describe this proof.
	if context.invalid_gable_bytes!=var_to_bytes(context.proof.invalid_gable_part_ids) or context.proof._validation_cache_active or context.proof.physical_parts_by_id.size()!=context.proof.parts.size():
		return _fail("modified_party_wall_proof_context")
	for part in context.proof.parts:
		if context.proof.find_part(part.id)!=part: return _fail("modified_party_wall_proof_context")
	return {"ready":true}

static func declare_party_wall_seat(part, allow_embedded_panel := false) -> bool:
	if not part is Part or not part.collision_enabled or part.kind not in ["wall", "foundation"] or part.rotation != Vector3.ZERO or not Materials.is_masonry_material(part.material_id): return false
	part.recipe["physicalPartyWallBearingModes"] = ["terminal_joint", "embedded_panel"] if allow_embedded_panel else ["terminal_joint"]
	return true

static func plan(source, declaration_key: String, supplied_context: Variant = null, continuation: Callable = Callable()) -> Dictionary:
	if not source is Blueprint or source.parts.size() > MAX_PARTS or declaration_key.is_empty():
		return _fail("invalid_or_unbounded_source")
	var by_id: Dictionary = {}
	for part in source.parts:
		if not part is Part or part.id.is_empty() or by_id.has(part.id) or not source.has_finite_positive_bounds(part):
			return _fail("invalid_or_duplicate_source_part")
		by_id[part.id] = part
	var declarations: Variant = source.recipe.get("facadeApertures")
	if not declarations is Dictionary or not declarations.has(declaration_key):
		return _fail("missing_facade_declaration")
	var declaration: Variant = declarations[declaration_key]
	if not Aperture.validate(declaration, by_id) or declaration.get("producerPrefix") != declaration_key or not declaration.get("partIds") is Array or declaration.partIds.is_empty() or declaration.partIds.size() > MAX_DECLARATION_PARTS:
		return _fail("invalid_facade_declaration")
	var source_bytes := var_to_bytes(source.snapshot())
	if not _continue(continuation,"party_wall_plan_started"): return _fail("cancelled")
	if source_bytes!=var_to_bytes(source.snapshot()): return _fail("stale_party_wall_source_proof")
	var context: Variant=supplied_context
	if context==null:
		var built := prepare_context(source,continuation)
		if not built.ready: return built
		context=built.context
	var binding := _context_valid(source,context)
	if not binding.ready: return binding
	var proof = context.proof
	var before: Dictionary = context.report
	var failed: Array = Copy.failed_ids(before)
	var bottom := INF
	for id: String in declaration.partIds:
		if not _continue(continuation,"party_wall_panel"): return _fail("cancelled")
		var part = by_id.get(id)
		var proof_part = proof.find_part(id)
		if not _panel_valid(proof, proof_part): return _fail("invalid_declared_panel", {"partId": id})
		bottom = minf(bottom, source.transformed_part_bounds(part).position.y)
	var targets: Array = []
	for id: String in declaration.partIds:
		var part = by_id[id]
		if absf(source.transformed_part_bounds(part).position.y - bottom) <= BOTTOM_COHORT_TOLERANCE and failed.has(id):
			# Obligation admission is evaluated on the immutable authored source,
			# before resolve_physical_contracts adds derived coverage caches.
			if not _target_valid(part): return _fail("target_has_existing_or_inconsistent_load_contract", {"partId": id})
			targets.append(part)
	targets.sort_custom(func(a, b): return a.id < b.id)
	if targets.is_empty(): return _pending(source,context,"no_failed_bottom_cohort")
	# Rejection only: independent proof cannot invent a finite geometric contact.
	# Use a superset of admissible seats (including unresolved physical intent),
	# and only the first target so legacy failure ordering remains identical.
	var first_target = targets[0]
	var possible_contact := false
	for seat in source.parts:
		if not _continue(continuation,"party_wall_contact_prefilter"): return _fail("cancelled")
		if declaration.partIds.has(seat.id) or seat.id.begins_with(declaration_key+"_"): continue
		if not seat.collision_enabled or seat.kind not in ["wall","foundation"] or seat.rotation!=Vector3.ZERO or not Materials.is_masonry_material(seat.material_id): continue
		var modes: Variant=seat.recipe.get("physicalPartyWallBearingModes")
		if not modes is Array: continue
		if not _fact(source,first_target,seat).is_empty():
			possible_contact=true
			break
	if not possible_contact:
		context.geometric_rejections+=1
		return _pending(source,context,"no_finite_rooted_party_wall",{"partId":first_target.id})
	# Remove the entire facade declaration before proving candidate seats. A
	# target or dependent panel can never make its proposed party wall look rooted.
	var independent = Blueprint.new(source.id, source.seed, source.style)
	independent.recipe = source.recipe.duplicate(true)
	independent.rooms = source.rooms.duplicate(true)
	for part in source.parts:
		if not _continue(continuation,"party_wall_independent_copy"): return _fail("cancelled")
		if declaration.partIds.has(part.id): continue
		var copy = independent.add_part(part.snapshot())
		copy.physical_intent = part.physical_intent
	Copy.clear_caches(independent)
	var grid := Copy.validation_grid_work(independent)
	if not grid.ready: return grid
	if not _continue(continuation,"party_wall_independent_proof_started"): return _fail("cancelled")
	context.independent_validations+=1
	var independent_report: Dictionary = independent.validate_physical_integrity_cancellable(continuation)
	if independent_report.get("cancelled",false): return _fail("cancelled")
	if not _continue(continuation,"party_wall_independent_proof_completed"): return _fail("cancelled")
	var rooted: Dictionary = {}
	var passed_checks: Dictionary = {}
	for check: Dictionary in independent_report.checks:
		if check.passed: passed_checks[check.partId] = check
		if check.passed and (check.get("reachesGroundRoot", false) or check.get("physicalRoot", false)):
			rooted[check.partId] = true
	var seats: Array = []
	for part in independent.parts:
		if rooted.has(part.id) and not part.id.begins_with(declaration_key + "_") and _seat_valid(independent, part): seats.append(part)
	seats.sort_custom(func(a, b): return a.id < b.id)
	var changes: Array = []
	for target in targets:
		if not _continue(continuation,"party_wall_target"): return _fail("cancelled")
		var candidates: Array = []
		for seat in seats:
			if not _continue(continuation,"party_wall_seat"): return _fail("cancelled")
			var fact: Dictionary = _fact(source, target, seat)
			if fact.is_empty(): continue
			var changed = Part.new(target.snapshot())
			changed.recipe["physicalRequiredSeatPartIds"] = [seat.id]
			changed.recipe["physicalRequiredSeatFacts"] = [fact]
			var seat_in_proof = proof.find_part(seat.id)
			if seat_in_proof == null or not proof.has_rooted_housed_overlap(changed, seat_in_proof, fact): continue
			candidates.append({"seatId": seat.id, "fact": fact, "overlapVolume": fact.localOverlapHalfExtents.x * fact.localOverlapHalfExtents.y * fact.localOverlapHalfExtents.z * 8.0})
		if candidates.is_empty(): return _pending(source,context,"no_finite_rooted_party_wall", {"partId": target.id})
		candidates.sort_custom(func(a, b): return a.overlapVolume > b.overlapVolume if a.overlapVolume != b.overlapVolume else a.seatId < b.seatId)
		var selected: Dictionary = candidates[0]
		var root_ids: Array = _reachable_roots(independent, selected.seatId)
		if root_ids.is_empty() or not root_ids.all(func(root_id):
			var root = independent.find_part(root_id)
			return passed_checks.has(root_id) and root != null and root.collision_enabled and root.physical_intent == "structural_root" and bool(root.recipe.get("physicalRoot", false))):
			return _pending(source,context,"party_wall_without_independently_passing_root", {"partId": target.id})
		var recipe: Dictionary = target.recipe.duplicate(true)
		recipe["physicalRequiredSeatPartIds"] = [selected.seatId]
		recipe["physicalRequiredSeatFacts"] = [selected.fact]
		changes.append({"partId": target.id, "recipe": recipe, "seatId": selected.seatId,
			"fact": selected.fact, "overlapVolume": selected.overlapVolume, "candidateCount": candidates.size(),
			"seatRootIds": root_ids})
	if not _continue(continuation,"party_wall_plan_completed"): return _fail("cancelled")
	binding=_context_valid(source,context)
	if not binding.ready: return binding
	return {"ready": true, "reason": "", "declarationKey": declaration_key,
		"targetIds": changes.map(func(row): return row.partId), "changes": changes,
		"scope": "Source-only existing masonry housed-overlap declarations; no added/moved geometry, publication, rendering, gameplay or engineering-capacity acceptance."}

static func apply(source, declaration_key: String, context: Variant = null, continuation: Callable = Callable()) -> Dictionary:
	var result := plan(source, declaration_key,context,continuation)
	if not result.ready: return result
	return apply_plan(source, result)

static func apply_plan(source, result: Dictionary) -> Dictionary:
	if source == null or not result.get("ready", false) or not result.get("changes") is Array or result.changes.is_empty() or result.changes.size() > MAX_DECLARATION_PARTS:
		return _fail("invalid_party_wall_plan")
	var targets: Array = []
	var seen: Dictionary = {}
	for row: Dictionary in result.changes:
		if not row.get("partId") is String or row.partId.is_empty() or seen.has(row.partId) or not row.get("recipe") is Dictionary:
			return _fail("invalid_party_wall_plan_change")
		seen[row.partId] = true
		var target = source.find_part(row.partId)
		if target == null:
			for part in source.parts:
				if part.id == row.partId: target = part; break
		if target == null: return _fail("party_wall_plan_target_missing", {"partId": row.partId})
		targets.append({"target": target, "recipe": row.recipe})
	for staged: Dictionary in targets:
		var target = staged.target
		var recipe: Dictionary = staged.recipe
		target.recipe = recipe.duplicate(true)
	return result

static func _fact(source, panel, seat) -> Dictionary:
	var a: AABB = source.transformed_part_bounds(panel)
	var b: AABB = source.transformed_part_bounds(seat)
	var modes: Array = seat.recipe.get("physicalPartyWallBearingModes", [])
	if not modes.has("terminal_joint"): return {}
	var raw_low := a.position.max(b.position)
	var raw_high := a.end.min(b.end)
	var touches_end := absf(raw_low.z - a.position.z) <= END_TOUCH_TOLERANCE or absf(raw_high.z - a.end.z) <= END_TOUCH_TOLERANCE
	var fully_housed := raw_low.z <= a.position.z + END_TOUCH_TOLERANCE and raw_high.z >= a.end.z - END_TOUCH_TOLERANCE
	if not touches_end or fully_housed and not modes.has("embedded_panel"): return {}
	var low := a.position.max(b.position)
	var high := a.end.min(b.end)
	var band_high := minf(a.position.y + LOWER_BAND_HEIGHT, a.end.y)
	high.y = minf(high.y, band_high)
	low += Vector3.ONE * JOINT_INSET
	high -= Vector3.ONE * JOINT_INSET
	var size := high - low
	if not size.is_finite() or size.x < MIN_TRANSVERSE or size.y < MIN_VERTICAL or size.z < MIN_LONGITUDINAL:
		return {}
	var center := (low + high) * 0.5
	var half := size * 0.5
	return {"seatId": seat.id, "contactMode": "housed_overlap", "localSpanAxis": "z",
		"localOverlapCenter": center - panel.position, "localOverlapHalfExtents": half,
		"minimumLongitudinalEmbedment": MIN_LONGITUDINAL, "minimumVerticalOverlap": MIN_VERTICAL}

static func _panel_valid(source, part) -> bool:
	return part is Part and part.kind == "wall" and part.semantic == "citadel_urban_facade" and part.physical_intent == "structural_mass" and part.rotation == Vector3.ZERO and part.collision_enabled and Materials.is_masonry_material(part.material_id) and source.has_finite_positive_bounds(part)

static func _target_valid(part) -> bool:
	if not part is Part: return false
	# Fail closed for every authored obligation family, including future
	# physicalRequired* fields. Derived ordinary support IDs are intentionally not
	# obligations; source admission occurs before resolver caches are generated.
	for key_value in part.recipe:
		var key := String(key_value)
		if (key.begins_with("physicalRequired") or key == "physicalSupportCoverage") and _value_nonempty(part.recipe[key_value]): return false
	return String(part.recipe.get("physicalAssemblyRole", "")).is_empty()

static func _value_nonempty(value: Variant) -> bool:
	if value == null: return false
	if value is String or value is StringName: return not String(value).is_empty()
	if value is Array or value is Dictionary or value is PackedStringArray: return not value.is_empty()
	return true

static func _seat_valid(source, part) -> bool:
	var modes: Variant = part.recipe.get("physicalPartyWallBearingModes")
	return part is Part and part.kind in ["wall", "foundation"] and modes is Array and not modes.is_empty() and modes.all(func(mode): return mode in ["terminal_joint", "embedded_panel"]) and part.rotation == Vector3.ZERO and part.collision_enabled and part.physical_intent in ["structural_mass", "structural_root"] and Materials.is_masonry_material(part.material_id) and source.has_finite_positive_bounds(part)

static func _reachable_roots(source, start_id: String) -> Array:
	var queue: Array = [start_id]
	var seen: Dictionary = {}
	var roots: Array = []
	while not queue.is_empty():
		var id: String = queue.pop_front()
		if seen.has(id): continue
		seen[id] = true
		var part = source.find_part(id)
		if part == null: continue
		if bool(part.recipe.get("physicalRoot", false)):
			roots.append(id)
			continue
		var next: Array = part.recipe.get("physicalSupportPartIds", []).duplicate()
		for fact: Dictionary in part.recipe.get("physicalRequiredSeatFacts", []): next.append(String(fact.get("seatId", "")))
		for seat_id in part.recipe.get("physicalRequiredSeatPartIds", []): next.append(String(seat_id))
		next.sort()
		for next_id: String in next:
			if not next_id.is_empty() and not seen.has(next_id): queue.append(next_id)
	roots.sort()
	return roots

static func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate(true)
	result["ready"] = false
	result["reason"] = reason
	return result

static func _continue(callback: Callable, stage: String) -> bool:
	return not callback.is_valid() or callback.call(stage)==true

static func _pending(source, context, reason: String, detail: Dictionary = {}) -> Dictionary:
	var binding := _context_valid(source,context)
	return _fail(reason,detail) if binding.ready else binding

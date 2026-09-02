extends SceneTree

# Source/service contract, not gameplay or visual placement acceptance.
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Furniture = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")

func _initialize() -> void:
	call_deferred("_run")

func _is_fuel(part) -> bool:
	return String(part.semantic) in ["citadel_household_firewood", "citadel_civic_firewood"]

func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()

func _clone(source, omit_fuel := false):
	var result = Blueprint.new(source.id, source.seed, source.style)
	result.recipe = source.recipe.duplicate(true)
	result.rooms = source.rooms.duplicate(true)
	for part in source.parts:
		if not omit_fuel or not _is_fuel(part):
			result.add_part(part.snapshot())
	return result

func _run() -> void:
	var started := Time.get_ticks_msec()
	print("stored firewood: actual seed208159 scale1.25")
	var after = Castle.build(208159, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25})
	if after == null:
		quit(2)
		return
	after = Urban.compose(after, 208159)
	if after == null:
		push_error("Citadel composition failed")
		quit(2)
		return
	var before = _clone(after)
	var without = _clone(after, true)
	var fuel_ids: Array = []
	var shapes: Array = []
	var old_shapes: Array = []
	var only_intent_changed := true
	var all_noncolliding := true
	var primitives_identical := true
	var publisher = Publisher.new()
	for index in range(after.parts.size()):
		var part = after.parts[index]
		var old = before.parts[index]
		if _is_fuel(part):
			fuel_ids.append(String(part.id))
			all_noncolliding = all_noncolliding and not part.collision_enabled and part.physical_intent == "visual_detail"
			# Reconstruct the former default inference only; no generator substitute.
			old.physical_intent = ""
			old.recipe.erase("physicalIntent")
			var normalized: Dictionary = part.snapshot()
			normalized["physicalIntent"] = ""
			normalized.recipe.erase("physicalIntent")
			only_intent_changed = only_intent_changed and _digest(normalized) == _digest(old.snapshot())
			primitives_identical = primitives_identical and _same_primitives(publisher, before, old, part)
		else:
			only_intent_changed = only_intent_changed and _digest(part.snapshot()) == _digest(old.snapshot())
		shapes.append([part.id, part.kind, part.position, part.rotation, part.size, part.material_id, part.collision_enabled, part.semantic])
		old_shapes.append([old.id, old.kind, old.position, old.rotation, old.size, old.material_id, old.collision_enabled, old.semantic])
	print("stored firewood: validate original inference, explicit intent, and removal control")
	var previous: Dictionary = before.validate_physical_integrity()
	var current: Dictionary = after.validate_physical_integrity()
	var removed_fuel: Dictionary = without.validate_physical_integrity()
	var other_before: Array = previous.checks.filter(func(check): return not fuel_ids.has(String(check.partId)))
	var other_after: Array = current.checks.filter(func(check): return not fuel_ids.has(String(check.partId)))
	var removed: Array = previous.violations.filter(func(value): return not current.violations.has(value))
	var added: Array = current.violations.filter(func(value): return not previous.violations.has(value))
	var only_fuel_violations := removed.all(func(value): return fuel_ids.has(String(value).trim_suffix(" facade_attachment has no rooted declared anchor")))
	print("stored firewood: furniture and independent placement observations")
	var old_furniture = Furniture.build(before, 208159 * 7919 + 37)
	var new_furniture = Furniture.build(after, 208159 * 7919 + 37)
	var controls := _negative_controls()
	var checks := {
		"all_112_authored_logs_classified": fuel_ids.size() == 112 and all_noncolliding,
		"only_fuel_intent_changed": only_intent_changed,
		"all_shape_collision_fields_identical": _digest(shapes) == _digest(old_shapes),
		"actual_published_primitives_identical": primitives_identical,
		"nonfuel_physical_checks_identical": _digest(other_before) == _digest(other_after),
		"removing_fuel_does_not_change_structure": _digest(other_after) == _digest(removed_fuel.checks),
		"only_fuel_classification_failures_removed": only_fuel_violations and not removed.is_empty() and added.is_empty(),
		"rooms_identical": _digest(before.rooms) == _digest(after.rooms),
		"furniture_identical": old_furniture != null and new_furniture != null and _digest(old_furniture.snapshot()) == _digest(new_furniture.snapshot()),
		"reservations_identical": old_furniture != null and new_furniture != null and _digest(old_furniture.protected_access_reservations) == _digest(new_furniture.protected_access_reservations),
		"structural_negatives_still_reject": controls.values().all(func(value): return bool(value))
	}
	var report := {"evidenceLevel": "source_and_visual_primitive_service_contract", "seed": 208159, "scale": 1.25,
		"passed": checks.values().all(func(value): return bool(value)), "checks": checks,
		"beforeViolations": previous.violations, "afterViolations": current.violations,
		"removedViolations": removed, "addedViolations": added, "fuelIds": fuel_ids,
		"negativeControls": controls, "shapeDigest": _digest(shapes),
		"placementObservationsNotAcceptance": _placement_observations(after),
		"elapsedMsec": Time.get_ticks_msec() - started,
		"doesNotProve": "Classification correction is not support repair. No live movement, rendered-image acceptance, complete grounding of props, full physical gate, or gameplay acceptance. Before reconstructs former recipe inference, not a historical executable."}
	var file := FileAccess.open(OS.get_environment("VOXEL_STORED_FIREWOOD_REPORT"), FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var write_error := file.get_error()
	file.close()
	print("stored firewood: contract=", report.passed, " classifications=", previous.violations.size(), " -> ", current.violations.size())
	quit(2 if write_error != OK else (0 if report.passed else 1))

func _same_primitives(publisher, blueprint, old, part) -> bool:
	var first := Node3D.new()
	var second := Node3D.new()
	first.transform = blueprint.part_transform(old)
	second.transform = blueprint.part_transform(part)
	publisher.publish_visual(old, first)
	publisher.publish_visual(part, second)
	var same := first.transform == second.transform and first.get_child_count() == 1 and second.get_child_count() == 1
	if same:
		var a := first.get_child(0) as MeshInstance3D
		var b := second.get_child(0) as MeshInstance3D
		same = a != null and b != null and a.mesh == b.mesh and a.material_override == b.material_override and a.transform == b.transform and a.cast_shadow == b.cast_shadow
	first.free()
	second.free()
	return same

func _negative_controls() -> Dictionary:
	var checks: Dictionary = {}
	for kind in ["beam", "wall"]:
		var b = Blueprint.new()
		b.add_part({"id": "unsupported", "kind": kind, "position": Vector3(0, 5, 0)})
		checks[kind + "_mass_rejected"] = not b.validate_physical_integrity().passed
	var brace = Blueprint.new()
	brace.add_part({"id": "brace", "kind": "beam", "collision": false, "position": Vector3(0, 5, 0)})
	checks["unsupported_attachment_rejected"] = not brace.validate_physical_integrity().passed
	var fuel = Blueprint.new()
	fuel.add_part({"id": "fuel", "kind": "beam", "collision": true, "recipe": {"physicalIntent": "visual_detail"}})
	checks["colliding_visual_detail_rejected"] = not fuel.validate_physical_integrity().passed
	return checks

func _placement_observations(blueprint) -> Array:
	# Center-only vertical observations, not full-footprint/stack stability proof.
	# Keep gaps visible even though loose props do not require facade anchoring.
	var fuel: Array = blueprint.parts.filter(_is_fuel)
	var records: Array = []
	for part in fuel:
		var bottom: Vector3 = part.position - Vector3(0, part.size.y * 0.5, 0)
		var candidates: Array = blueprint.structural_candidates_near(bottom)
		candidates.append_array(fuel)
		var best_top := -INF
		var record := {"id": part.id, "bottom": bottom, "supportId": "", "gap": null, "supportIsFuel": false, "centerOverlappingVolumes": [], "observationLimit": "Gap to the nearest eligible lower axis-aligned top at one center sample; overlapping volumes can instead embed or cover the log. Not a floating/grounding verdict."}
		for candidate in candidates:
			if candidate == part or absf(candidate.rotation.x) > 0.0001 or absf(candidate.rotation.z) > 0.0001:
				continue
			var local: Vector3 = blueprint.part_transform(candidate).affine_inverse() * bottom
			var top: float = candidate.position.y + candidate.size.y * 0.5
			if absf(local.x) > candidate.size.x * 0.5 or absf(local.z) > candidate.size.z * 0.5:
				continue
			var candidate_bottom: float = candidate.position.y - candidate.size.y * 0.5
			if top > bottom.y + 0.05 and candidate_bottom < bottom.y + part.size.y:
				record.centerOverlappingVolumes.append({"id": candidate.id, "bottomY": candidate_bottom, "topY": top, "collision": candidate.collision_enabled, "kind": candidate.kind})
			if top > bottom.y + 0.05 or top <= best_top:
				continue
			best_top = top
			record["supportId"] = candidate.id
			record["gap"] = bottom.y - top
			record["supportIsFuel"] = _is_fuel(candidate)
		records.append(record)
	return records

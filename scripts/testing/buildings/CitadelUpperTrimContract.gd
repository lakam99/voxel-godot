extends SceneTree

# Source/geometry contract only; never live movement or visual acceptance.
const CastleBuilder = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const UrbanComposer = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const FurniturePlanner = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")

func _initialize() -> void:
	call_deferred("_run")

func _digest(value: Variant) -> String:
	var hash_context := HashingContext.new()
	hash_context.start(HashingContext.HASH_SHA256)
	hash_context.update(var_to_bytes(value))
	return hash_context.finish().hex_encode()

func _run() -> void:
	var started := Time.get_ticks_msec()
	print("upper trim: build actual seed208159 scale1.25")
	var after = CastleBuilder.build(208159, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25})
	after = UrbanComposer.compose(after, 208159)
	if after == null:
		push_error("Citadel composition failed")
		quit(2)
		return
	# Reconstruct the previous two placement expressions for an explicit A/B
	# source experiment. No alternative builder is used in production.
	var before = Blueprint.new(after.id, after.seed, after.style)
	before.recipe = after.recipe.duplicate(true)
	before.rooms = after.rooms.duplicate(true)
	var changed: Array = []
	var invariant_records: Array = []
	var all_other_fields_equal := true
	for part in after.parts:
		var old = before.add_part(part.snapshot())
		var part_id := String(part.id)
		if "_upper_stud_" in part_id or "_floor_beam_" in part_id:
			var prefix := part_id.split("_upper_stud_")[0] if "_upper_stud_" in part_id else part_id.split("_floor_beam_")[0]
			var back = _find(after, prefix + "_upper_shell_back")
			if back != null:
				var side := signf(part.position.x - back.position.x)
				old.position.x += side * 0.14
				changed.append({"id": part_id, "prefix": prefix, "before": old.position, "after": part.position, "collision": part.collision_enabled})
		var old_snapshot: Dictionary = old.snapshot()
		old_snapshot["position"] = part.position
		all_other_fields_equal = all_other_fields_equal and _digest(old_snapshot) == _digest(part.snapshot())
		if old.position == part.position:
			invariant_records.append(part.snapshot())
	print("upper trim: validate previous and repaired source")
	var previous: Dictionary = before.validate_physical_integrity()
	var current: Dictionary = after.validate_physical_integrity()
	var contact_before := 0
	var contact_after := 0
	var rooted_before := 0
	var rooted_after := 0
	for record in changed:
		var old = before.find_part(record.id)
		var part = after.find_part(record.id)
		var old_contacts := _facade_contacts(before, old, record.prefix)
		var new_contacts := _facade_contacts(after, part, record.prefix)
		record["oldFacadeContacts"] = old_contacts
		record["newFacadeContacts"] = new_contacts
		record["oldRooted"] = before.has_rooted_anchor_chain(old, {})
		record["newRooted"] = after.has_rooted_anchor_chain(part, {})
		contact_before += int(not old_contacts.is_empty())
		contact_after += int(not new_contacts.is_empty())
		rooted_before += int(record.oldRooted)
		rooted_after += int(record.newRooted)
	var before_furniture = FurniturePlanner.build(before, 208159 * 7919 + 37)
	var after_furniture = FurniturePlanner.build(after, 208159 * 7919 + 37)
	var checks := {
		"only_noncolliding_trim_moved": not changed.is_empty() and changed.all(func(record): return not record.collision and absf(record.before.distance_to(record.after) - 0.14) < 0.00001),
		"all_other_part_fields_unchanged": all_other_fields_equal,
		"rooms_unchanged": _digest(before.rooms) == _digest(after.rooms),
		"furniture_unchanged": _digest(before_furniture.snapshot()) == _digest(after_furniture.snapshot()),
		"furniture_reservations_unchanged": _digest(before_furniture.protected_access_reservations) == _digest(after_furniture.protected_access_reservations),
		"all_reseated_trim_contacts_own_facade": contact_after == changed.size(),
		"no_added_physical_violations": (current.violations as Array).all(func(value): return previous.violations.has(value)),
		"anchor_negative_controls": _negative_controls()
	}
	var report := {"evidenceLevel": "source_geometry_contract", "seed": 208159, "scale": 1.25,
		"passed": checks.values().all(func(value): return bool(value)), "checks": checks,
		"beforePhysicalPassed": previous.passed, "afterPhysicalPassed": current.passed,
		"beforeViolations": previous.violations, "afterViolations": current.violations,
		"changed": changed, "unchangedPartCount": invariant_records.size(),
		"contactsBefore": contact_before, "contactsAfter": contact_after,
		"rootedBefore": rooted_before, "rootedAfter": rooted_after,
		"elapsedMsec": Time.get_ticks_msec() - started,
		"doesNotProve": "Rendered appearance, load-bearing safety, physical gate completion, normal-world or NPC behavior. Previous trim placements are reconstructed source-level controls, not a second production generator."}
	var output := FileAccess.open(OS.get_environment("VOXEL_UPPER_TRIM_REPORT"), FileAccess.WRITE)
	if output == null:
		quit(2)
		return
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	print("upper trim: contract=", report.passed, " violations=", previous.violations.size(), " -> ", current.violations.size(), " contacts=", contact_before, " -> ", contact_after)
	quit(0 if report.passed else 1)

func _find(blueprint, part_id: String):
	for part in blueprint.parts:
		if String(part.id) == part_id:
			return part
	return null

func _facade_contacts(blueprint, target, prefix: String) -> Array:
	var ids: Array = []
	for candidate in blueprint.structural_candidates_overlapping_part(target, 0.0):
		if String(candidate.id).begins_with(prefix + "_upper_facade_") and blueprint.transformed_parts_overlap(target, candidate, 0.0):
			ids.append(candidate.id)
	return ids

func _negative_controls() -> bool:
	var b = Blueprint.new()
	var anchor = b.add_part({"id": "anchor", "kind": "foundation", "position": Vector3(0, 1.5, 0), "size": Vector3(0.3, 3, 4)})
	var trim = b.add_part({"id": "trim", "kind": "beam", "collision": false, "position": Vector3(0.21, 1.5, 0), "size": Vector3(0.22, 1, 0.22)})
	b.resolve_physical_contracts()
	var valid: bool = b.has_rooted_anchor_chain(trim, {})
	anchor.position.x = -2.0
	b.resolve_physical_contracts()
	valid = valid and not b.has_rooted_anchor_chain(trim, {})
	anchor.position.x = 0.0
	anchor.kind = "wall"
	anchor.physical_intent = "structural_mass"
	anchor.recipe.erase("physicalRoot")
	b.resolve_physical_contracts()
	valid = valid and not b.has_rooted_anchor_chain(trim, {})
	b.parts.erase(anchor)
	b.resolve_physical_contracts()
	valid = valid and not b.has_rooted_anchor_chain(trim, {})
	return valid

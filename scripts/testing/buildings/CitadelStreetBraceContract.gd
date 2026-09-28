extends SceneTree

# Source/geometry contract only. No live/visual acceptance or headed permission.
# Reconstruct ONLY old street-brace X positions; keep all earlier trim repairs.
# Set VOXEL_STREET_BRACE_REPORT to a file in an existing report directory.
const CastleBuilder = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const UrbanComposer = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const FurniturePlanner = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")

func _initialize() -> void:
	call_deferred("_run")

func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()

func _run() -> void:
	var started := Time.get_ticks_msec()
	print("street brace: actual seed208159 scale1.25")
	var after = CastleBuilder.build(208159, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25})
	after = UrbanComposer.compose(after, 208159)
	if after == null:
		push_error("Citadel composition failed")
		quit(2)
		return
	if after.parts.is_empty() or after.parts.size() > 20000:
		push_error("Street brace source part count outside bound")
		quit(2)
		return
	var before = Blueprint.new(after.id, after.seed, after.style)
	before.recipe = after.recipe.duplicate(true)
	before.rooms = after.rooms.duplicate(true)
	var changed: Array = []
	var houses: Dictionary = {}
	var unrelated_before: Array = []
	var unrelated_after: Array = []
	var all_other_fields_equal := true
	for part in after.parts:
		var old = before.add_part(part.snapshot())
		var part_id := String(part.id)
		if String(part.semantic) == "citadel_urban_brace" and "_street_brace_" in part_id:
			var prefix := part_id.split("_street_brace_")[0]
			var back = _find(after, prefix + "_upper_shell_back")
			if back != null:
				var side := signf(part.position.x - back.position.x)
				old.position.x += side * 0.14
				houses[prefix] = int(houses.get(prefix, 0)) + 1
				changed.append({"id": part_id, "prefix": prefix, "before": old.position, "after": part.position, "side": side, "collision": part.collision_enabled})
		var normalized: Dictionary = old.snapshot()
		normalized["position"] = part.position
		all_other_fields_equal = all_other_fields_equal and _digest(normalized) == _digest(part.snapshot())
		if old.position == part.position:
			unrelated_before.append(old.snapshot())
			unrelated_after.append(part.snapshot())
	# Full source/recipe parity is measured before derived physical caches mutate.
	var checks := {
		"exactly_32_braces_16_houses": changed.size() == 32 and houses.size() == 16 and houses.values().all(func(count): return count == 2),
		"only_noncolliding_014_x_moves": changed.all(func(record): return not record.collision and absf(record.before.x - record.after.x - record.side * 0.14) < 0.00001 and absf(record.side) == 1.0 and record.before.y == record.after.y and record.before.z == record.after.z),
		"all_other_part_fields_unchanged": all_other_fields_equal,
		"all_unrelated_parts_identical": _digest(unrelated_before) == _digest(unrelated_after),
		"recipe_unchanged": _digest(before.recipe) == _digest(after.recipe),
		"rooms_unchanged": _digest(before.rooms) == _digest(after.rooms)
	}
	print("street brace: validate reconstructed previous and current geometry")
	var previous: Dictionary = before.validate_physical_integrity()
	var current: Dictionary = after.validate_physical_integrity()
	var contact_before := 0
	var contact_after := 0
	var rooted_before := 0
	var rooted_after := 0
	for record in changed:
		var old = before.find_part(record.id)
		var part = after.find_part(record.id)
		record["oldFacadeContacts"] = _facade_contacts(before, old, record.prefix)
		record["newFacadeContacts"] = _facade_contacts(after, part, record.prefix)
		record["oldRooted"] = before.has_rooted_anchor_chain(old, {})
		record["newRooted"] = after.has_rooted_anchor_chain(part, {})
		contact_before += int(not record.oldFacadeContacts.is_empty())
		contact_after += int(not record.newFacadeContacts.is_empty())
		rooted_before += int(record.oldRooted)
		rooted_after += int(record.newRooted)
	var removed: Array = previous.violations.filter(func(value): return not current.violations.has(value))
	var added: Array = current.violations.filter(func(value): return not previous.violations.has(value))
	checks["no_added_physical_violations"] = added.is_empty()
	checks["actual_mounting_contacts_improved"] = contact_after > contact_before
	checks["rooted_anchor_count_improved"] = rooted_after > rooted_before
	checks["no_brace_loses_rooted_support"] = changed.all(func(record): return not record.oldRooted or record.newRooted)
	print("street brace: compare actual furniture and reservations")
	var before_furniture = FurniturePlanner.build(before, 208159 * 7919 + 37)
	var after_furniture = FurniturePlanner.build(after, 208159 * 7919 + 37)
	checks["furniture_unchanged"] = before_furniture != null and after_furniture != null and _digest(before_furniture.snapshot()) == _digest(after_furniture.snapshot())
	checks["furniture_reservations_unchanged"] = before_furniture != null and after_furniture != null and _digest(before_furniture.protected_access_reservations) == _digest(after_furniture.protected_access_reservations)
	var controls := _negative_controls()
	checks["synthetic_anchor_controls"] = controls.values().all(func(control): return bool(control.passed))
	var report := {"evidenceLevel": "source_geometry_contract", "seed": 208159, "scale": 1.25,
		"passed": checks.values().all(func(value): return bool(value)), "checks": checks,
		"beforePhysicalPassed": previous.passed, "afterPhysicalPassed": current.passed,
		"beforeViolations": previous.violations, "afterViolations": current.violations,
		"removedViolations": removed, "addedViolations": added, "changed": changed,
		"houseCount": houses.size(), "changedPartCount": changed.size(), "unchangedPartCount": unrelated_after.size(),
		"contactsBefore": contact_before, "contactsAfter": contact_after, "rootedBefore": rooted_before, "rootedAfter": rooted_after,
		"syntheticAnchorControls": controls, "elapsedMsec": Time.get_ticks_msec() - started,
		"contactScope": "Exact zero-margin own upper-facade overlaps are observations, not an all-contact requirement: openings may leave a brace without contact. Contact alone is not rooted support.",
		"doesNotProve": "Rendered appearance, full physical gate completion, load-bearing safety, live collision or NPC/gameplay acceptance. Before is a reconstruction of only brace X + side*0.14, not an independent historical generator."}
	var output := FileAccess.open(OS.get_environment("VOXEL_STREET_BRACE_REPORT"), FileAccess.WRITE)
	if output == null:
		push_error("Cannot open VOXEL_STREET_BRACE_REPORT")
		quit(2)
		return
	output.store_string(JSON.stringify(report, "\t"))
	output.flush()
	var write_error := output.get_error()
	output.close()
	print("street brace: contract=", report.passed, " violations=", previous.violations.size(), " -> ", current.violations.size())
	quit(2 if write_error != OK else (0 if report.passed else 1))

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
	ids.sort()
	return ids

func _negative_controls() -> Dictionary:
	# Independent synthetic mutations; each starts with a positively rooted trim.
	var controls: Dictionary = {}
	for mode in ["moved", "removed", "ungrounded", "cyclic"]:
		var b = Blueprint.new()
		var anchor = b.add_part({"id": "anchor", "kind": "foundation", "position": Vector3(0, 1.5, 0), "size": Vector3(0.3, 3, 4)})
		var trim = b.add_part({"id": "trim", "kind": "beam", "collision": false, "position": Vector3(0.21, 1.5, 0), "size": Vector3(0.22, 1, 0.22)})
		b.resolve_physical_contracts()
		var initially_rooted: bool = b.has_rooted_anchor_chain(trim, {})
		if mode == "moved":
			anchor.position.x = -2.0
		elif mode == "removed":
			b.parts.erase(anchor)
		else:
			anchor.kind = "wall"
			anchor.physical_intent = "structural_mass"
			anchor.recipe["physicalIntent"] = "structural_mass"
			anchor.recipe.erase("physicalRoot")
			if mode == "cyclic":
				# Touching seats form a real declared cycle, but neither is grounded.
				anchor.recipe["physicalRequiredSeatPartIds"] = ["peer"]
				b.add_part({"id": "peer", "kind": "wall", "position": anchor.position, "size": anchor.size, "recipe": {"physicalRequiredSeatPartIds": ["anchor"]}})
		var physical: Dictionary = b.validate_physical_integrity()
		var rooted: bool = b.has_rooted_anchor_chain(trim, {})
		var rejected: bool = not rooted and physical.violations.has("trim facade_attachment has no rooted declared anchor")
		controls[mode] = {"passed": initially_rooted and rejected, "initiallyRooted": initially_rooted, "rootedAfter": rooted, "violations": physical.violations}
	return controls

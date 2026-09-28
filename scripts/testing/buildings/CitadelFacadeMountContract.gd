extends SceneTree

# Bounded source/geometry A/B contract, NOT live or headed acceptance.
# Uses the actual producer, then reconstructs ONLY the old corner-frame and
# door-lintel X expressions. Previously repaired studs/floor beams stay intact.
# Run later through the owned-process watchdog with --headless --script.
# Required: VOXEL_FACADE_MOUNT_REPORT (existing parent directory).
# Optional: VOXEL_FACADE_MOUNT_SEED (integer; default 208159, e.g. 208158).
# No publisher, meshes, physics scene, actors or navigation are instantiated.
const CastleBuilder = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const UrbanComposer = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const FurniturePlanner = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const DEFAULT_SEED: int = 208159
const SCALE: float = 1.25
const OUTWARD_OFFSET: float = 0.14
const MAX_PARTS: int = 20000
const MAX_TARGETS: int = 1024
const MAX_REPORT_BYTES: int = 8388608


func _initialize() -> void:
	call_deferred("_run")


func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()


func _run() -> void:
	var started := Time.get_ticks_msec()
	var seed_text := OS.get_environment("VOXEL_FACADE_MOUNT_SEED").strip_edges()
	var selected_seed := DEFAULT_SEED
	if not seed_text.is_empty():
		if not seed_text.is_valid_int():
			_fail("VOXEL_FACADE_MOUNT_SEED must be an integer")
			return
		selected_seed = seed_text.to_int()
	if OS.get_environment("VOXEL_FACADE_MOUNT_REPORT").strip_edges().is_empty():
		_fail("VOXEL_FACADE_MOUNT_REPORT is required")
		return
	print("facade mount: actual builder seed=", selected_seed, " scale=", SCALE)
	var after = CastleBuilder.build(selected_seed, {
		"biome": "forest", "siteKey": "river-citadel", "citadelScale": SCALE
	})
	if after == null:
		_fail("Castle builder returned null")
		return
	after = UrbanComposer.compose(after, selected_seed)
	if after == null:
		push_error("Citadel composition failed")
		quit(2)
		return
	if after.parts.is_empty() or after.parts.size() > MAX_PARTS:
		_fail("Source part count outside contract bounds")
		return
	# Local index avoids relying on physical caches before their resolution.
	var source_by_id: Dictionary = {}
	var houses: Dictionary = {}
	for part in after.parts:
		if part == null or String(part.id).is_empty() or source_by_id.has(String(part.id)):
			_fail("Null part or empty/duplicate source ID")
			return
		var part_id := String(part.id)
		source_by_id[part_id] = part
		if part_id.ends_with("_upper_shell_back"):
			houses[part_id.trim_suffix("_upper_shell_back")] = {"frame": 0, "door_lintel": 0}
	var before = Blueprint.new(after.id, after.seed, after.style)
	before.recipe = after.recipe.duplicate(true)
	before.rooms = after.rooms.duplicate(true)
	var changed: Array = []
	var changed_ids: Dictionary = {}
	var previous_trim_count := 0
	var all_other_fields_equal := true
	var unrelated_before: Array = []
	var unrelated_after: Array = []
	var prior_trim_before: Array = []
	var prior_trim_after: Array = []
	for part in after.parts:
		var old = before.add_part(part.snapshot())
		var part_id := String(part.id)
		var selection := _selection(part, source_by_id)
		if not selection.is_empty():
			var prefix := String(selection.prefix)
			var back = source_by_id[prefix + "_upper_shell_back"]
			var side := signf(part.position.x - back.position.x)
			if not part.position.is_finite() or side == 0.0 or part.collision_enabled:
				_fail("Invalid/nondecorative facade mount: " + part_id)
				return
			old.position.x += side * OUTWARD_OFFSET
			changed_ids[part_id] = true
			houses[prefix][selection.family] += 1
			changed.append({
				"id": part_id, "prefix": prefix, "family": selection.family,
				"semantic": part.semantic, "collision": part.collision_enabled,
				"streetSide": side, "before": old.position, "after": part.position
			})
		else:
			unrelated_before.append(old.snapshot())
			unrelated_after.append(part.snapshot())
		if "_upper_stud_" in part_id or "_floor_beam_" in part_id:
			previous_trim_count += 1
			prior_trim_before.append(old.snapshot())
			prior_trim_after.append(part.snapshot())
		# Compare EVERY non-position field, including full recipe/material data,
		# before validation mutates inferred physical bookkeeping on either side.
		var normalized: Dictionary = old.snapshot()
		normalized["position"] = part.position
		all_other_fields_equal = all_other_fields_equal and _digest(normalized) == _digest(part.snapshot())
	if changed.is_empty() or changed.size() > MAX_TARGETS:
		_fail("Facade target count outside contract bounds")
		return
	var checks := {
		"seed208159_expected_48_mounts": selected_seed != DEFAULT_SEED or (houses.size() == 16 and changed.size() == 48),
		"every_house_has_two_frames_and_one_lintel": not houses.is_empty() and houses.values().all(func(counts): return counts.frame == 2 and counts.door_lintel == 1),
		"only_noncolliding_mounts_moved_014_inward": changed.all(_is_expected_shift),
		"all_other_part_fields_unchanged": all_other_fields_equal,
		"all_unrelated_parts_identical": _digest(unrelated_before) == _digest(unrelated_after),
		"previous_stud_floorbeam_repairs_intact": previous_trim_count > 0 and _digest(prior_trim_before) == _digest(prior_trim_after),
		"identity_and_part_order_preserved": before.id == after.id and before.seed == after.seed and before.style == after.style and before.parts.size() == after.parts.size(),
		"recipe_unchanged": _digest(before.recipe) == _digest(after.recipe),
		"rooms_unchanged": _digest(before.rooms) == _digest(after.rooms)
	}
	var source_digests := {
		"before": _digest(before.snapshot()), "after": _digest(after.snapshot()),
		"unrelatedBefore": _digest(unrelated_before), "unrelatedAfter": _digest(unrelated_after),
		"priorTrimBefore": _digest(prior_trim_before), "priorTrimAfter": _digest(prior_trim_after)
	}
	print("facade mount: validate reconstructed-before and current source")
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
		record["oldAnchorPartIds"] = old.recipe.get("physicalAnchorPartIds", []).duplicate()
		record["newAnchorPartIds"] = part.recipe.get("physicalAnchorPartIds", []).duplicate()
		contact_before += int(not old_contacts.is_empty())
		contact_after += int(not new_contacts.is_empty())
		rooted_before += int(record.oldRooted)
		rooted_after += int(record.newRooted)
	var removed := _difference(previous.violations, current.violations)
	var added := _difference(current.violations, previous.violations)
	checks["all_mounts_contact_own_facade_at_zero_margin"] = contact_after == changed.size()
	checks["no_added_physical_violations"] = added.is_empty()
	checks["removed_at_least_one_violation"] = not removed.is_empty()
	checks["removed_violations_only_target_attachments"] = removed.all(func(value):
		return changed_ids.has(String(value).trim_suffix(" facade_attachment has no rooted declared anchor")) and String(value).ends_with(" facade_attachment has no rooted declared anchor")
	)
	checks["no_target_loses_rooted_chain"] = changed.all(func(record): return not record.oldRooted or record.newRooted)
	print("facade mount: compare actual furniture and reservations")
	var furnishing_seed := selected_seed * 7919 + 37
	var before_furniture = FurniturePlanner.build(before, furnishing_seed)
	var after_furniture = FurniturePlanner.build(after, furnishing_seed)
	var furniture_digests: Dictionary = {}
	checks["furniture_plans_exist"] = before_furniture != null and after_furniture != null
	checks["furniture_unchanged"] = false
	checks["furniture_reservations_unchanged"] = false
	if checks.furniture_plans_exist:
		furniture_digests = {
			"before": _digest(before_furniture.snapshot()), "after": _digest(after_furniture.snapshot()),
			"reservationsBefore": _digest(before_furniture.protected_access_reservations),
			"reservationsAfter": _digest(after_furniture.protected_access_reservations)
		}
		checks["furniture_unchanged"] = furniture_digests.before == furniture_digests.after
		checks["furniture_reservations_unchanged"] = furniture_digests.reservationsBefore == furniture_digests.reservationsAfter
	var controls := _negative_controls()
	checks["synthetic_anchor_controls"] = controls.values().all(func(control): return bool(control.passed))
	var report := {
		"schema": "citadel-facade-mount/v1", "evidenceLevel": "source_geometry_contract",
		"seed": selected_seed, "scale": SCALE, "furnishingSeed": furnishing_seed,
		"passed": checks.values().all(func(value): return bool(value)), "checks": checks,
		"beforePhysicalPassed": previous.passed, "afterPhysicalPassed": current.passed,
		"beforeViolations": previous.violations, "afterViolations": current.violations,
		"removedViolations": removed, "addedViolations": added,
		"beforeViolationCount": previous.violations.size(), "afterViolationCount": current.violations.size(),
		"changed": changed, "changedPartCount": changed.size(), "houses": houses,
		"unchangedPartCount": unrelated_after.size(), "preservedPriorTrimCount": previous_trim_count,
		"contactsBefore": contact_before, "contactsAfter": contact_after,
		"rootedBefore": rooted_before, "rootedAfter": rooted_after,
		"sourceDigests": source_digests, "furnitureDigests": furniture_digests,
		"syntheticAnchorControls": controls, "elapsedMsec": Time.get_ticks_msec() - started,
		"comparisonScope": "Current actual build versus an isolated source reconstruction of only frame/lintel X + streetSide*0.14. Full source parity is checked before physical inference; inferred anchor/support bookkeeping is allowed to change during validation. Not an independent historical build.",
		"doesNotProve": "Rendered visual/furniture preservation, full physical gate completion, load-bearing safety, live collision, NPC/navigation behavior or gameplay acceptance. Contact is not rooted support. A passing bounded contract does not authorize a headed launch."
	}
	_write_report(report)


func _is_expected_shift(record: Dictionary) -> bool:
	var delta: Vector3 = record.before - record.after
	return not record.collision and delta.y == 0.0 and delta.z == 0.0 and absf(delta.x - float(record.streetSide) * OUTWARD_OFFSET) < 0.00001


func _selection(part, source_by_id: Dictionary) -> Dictionary:
	var part_id := String(part.id)
	var prefix := ""
	var family := ""
	if String(part.semantic) == "citadel_urban_frame" and "_frame_" in part_id and not "_floor_beam_" in part_id:
		prefix = part_id.rsplit("_frame_", true, 1)[0]
		family = "frame"
	elif String(part.semantic) == "citadel_urban_door_joinery" and part_id.ends_with("_door_lintel"):
		prefix = part_id.trim_suffix("_door_lintel")
		family = "door_lintel"
	if family.is_empty() or not source_by_id.has(prefix + "_upper_shell_back"):
		return {}
	return {"prefix": prefix, "family": family}


func _facade_contacts(blueprint, target, prefix: String) -> Array:
	var ids: Array = []
	for candidate in blueprint.structural_candidates_overlapping_part(target, 0.0):
		if String(candidate.id).begins_with(prefix + "_upper_facade_") and blueprint.transformed_parts_overlap(target, candidate, 0.0):
			ids.append(String(candidate.id))
	ids.sort()
	return ids


func _difference(left: Array, right: Array) -> Array:
	var result: Array = []
	for value in left:
		if not right.has(value):
			result.append(value)
	result.sort()
	return result


func _negative_controls() -> Dictionary:
	# Explicitly SYNTHETIC fixtures, independent per mutation. Both the anchor
	# query and the actual integrity validator must reject the invalid fixture.
	var controls: Dictionary = {}
	for mode in ["valid", "moved", "removed", "ungrounded", "cyclic"]:
		var b = Blueprint.new()
		var anchor = b.add_part({"id": "anchor", "kind": "foundation", "position": Vector3(0, 1.5, 0), "size": Vector3(0.3, 3, 4)})
		var trim = b.add_part({"id": "trim", "kind": "beam", "collision": false, "position": Vector3(0.21, 1.5, 0), "size": Vector3(0.22, 1, 0.22)})
		b.resolve_physical_contracts()
		var initially_rooted: bool = b.has_rooted_anchor_chain(trim, {})
		if mode == "moved":
			anchor.position.x = -2.0
		elif mode == "removed":
			b.parts.erase(anchor)
		elif mode in ["ungrounded", "cyclic"]:
			anchor.kind = "wall"
			anchor.physical_intent = "structural_mass"
			anchor.recipe["physicalIntent"] = "structural_mass"
			anchor.recipe.erase("physicalRoot")
			if mode == "cyclic":
				# Deliberately circular declared seats, no grounded root. Geometry
				# touches, but neither member may certify the other as grounded.
				anchor.recipe["physicalRequiredSeatPartIds"] = ["cycle_peer"]
				b.add_part({"id": "cycle_peer", "kind": "wall", "position": anchor.position, "size": anchor.size, "recipe": {"physicalRequiredSeatPartIds": ["anchor"]}})
		var physical: Dictionary = b.validate_physical_integrity()
		var rooted: bool = b.has_rooted_anchor_chain(trim, {})
		var trim_violation := "trim facade_attachment has no rooted declared anchor"
		var topology_present := true
		if mode == "cyclic":
			var peer = b.find_part("cycle_peer")
			topology_present = peer != null and b.transformed_parts_overlap(anchor, peer, 0.0) and anchor.recipe.physicalRequiredSeatPartIds.has("cycle_peer") and peer.recipe.physicalRequiredSeatPartIds.has("anchor") and not bool(anchor.recipe.get("physicalRoot", false)) and not bool(peer.recipe.get("physicalRoot", false))
		var expected: bool = rooted and bool(physical.passed) if mode == "valid" else not rooted and not bool(physical.passed) and physical.violations.has(trim_violation)
		controls[mode] = {
			"passed": initially_rooted and expected and topology_present,
			"initiallyRooted": initially_rooted, "rootedAfter": rooted,
			"physicalPassed": physical.passed, "violations": physical.violations,
			"anchorPartIds": trim.recipe.get("physicalAnchorPartIds", []),
			"cyclePresent": topology_present if mode == "cyclic" else false
		}
	return controls


func _fail(message: String) -> void:
	push_error("facade mount: " + message)
	_write_report({"evidenceLevel": "source_geometry_contract", "passed": false, "error": message})


func _write_report(report: Dictionary) -> void:
	var path := OS.get_environment("VOXEL_FACADE_MOUNT_REPORT").strip_edges()
	var encoded := JSON.stringify(report, "\t")
	if path.is_empty() or encoded.to_utf8_buffer().size() > MAX_REPORT_BYTES:
		push_error("facade mount: missing report path or report exceeds bound")
		quit(2)
		return
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		push_error("facade mount: cannot open report: " + path)
		quit(2)
		return
	output.store_string(encoded)
	output.flush()
	var write_error := output.get_error()
	output.close()
	if write_error != OK:
		push_error("facade mount: report write failed")
		quit(2)
		return
	print("facade mount: contract=", report.passed, " violations=", report.get("beforeViolationCount", -1), " -> ", report.get("afterViolationCount", -1), " report=", path)
	quit(0 if report.passed else 1)

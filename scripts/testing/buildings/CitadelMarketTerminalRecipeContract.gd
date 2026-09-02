extends "res://scripts/testing/buildings/CitadelMarketPlacementProbe.gd"

const TerminalFrame = preload("res://scripts/buildings/TerminalShopFrameBuilder.gd")

func _extra_checks(report: Dictionary, b, _boxes: Dictionary, groups: Array, _claimed: Dictionary) -> void:
	var group: Dictionary = groups[2]
	var layout: Dictionary = Urban.plan_household_on_paving(b, group.allIds,
		Vector3(0, 0, -float(group.layoutSpec.depth)))
	if not layout.get("ready", false):
		report["combinedRecipe"] = {"layout": layout, "ready": false}
		return
	var baseline = _clone(b)
	var candidate = _clone(b)
	var relocation_only = _clone(b)
	var frames_only = _clone(b)
	var pose: Transform3D = layout.transform
	var member_ids: Array = group.allIds
	for part in candidate.parts:
		if member_ids.has(part.id):
			var transformed := pose * Transform3D(Basis.from_euler(part.rotation), part.position)
			part.position = transformed.origin
			part.rotation = transformed.basis.get_euler()
	for part in relocation_only.parts:
		if member_ids.has(part.id):
			var transformed := pose * Transform3D(Basis.from_euler(part.rotation), part.position)
			part.position = transformed.origin
			part.rotation = transformed.basis.get_euler()
	print("combined recipe: layout planned; constructing terminal frames")
	var frames: Array = []
	for index in range(3):
		frames.append(TerminalFrame.add_frame(candidate, "urban_terminal_%02d" % index, "urban_market_plaza_retaining"))
		frames.append(TerminalFrame.add_frame(frames_only, "urban_terminal_%02d" % index, "urban_market_plaza_retaining"))
	if not frames.all(func(frame): return frame.get("ready", false)):
		report["combinedRecipe"] = {"frames": frames, "ready": false}
		return
	print("combined recipe: validate baseline")
	var before: Dictionary = baseline.validate_physical_integrity()
	print("combined recipe: validate candidate")
	var after: Dictionary = candidate.validate_physical_integrity()
	print("combined recipe: validate relocation-only and frames-only counterfactuals")
	var relocated: Dictionary = relocation_only.validate_physical_integrity()
	var framed: Dictionary = frames_only.validate_physical_integrity()
	report["fourWayComparison"] = {"baseline": _comparison(before, before),
		"relocationOnly": _comparison(before, relocated), "framesOnly": _comparison(before, framed),
		"combined": _comparison(before, after)}
	var old_failures: Dictionary = {}
	var new_failures: Dictionary = {}
	for check in before.checks:
		if not check.passed:
			old_failures[check.partId] = true
	for check in after.checks:
		if not check.passed:
			new_failures[check.partId] = true
	var removed: Array = old_failures.keys().filter(func(id): return not new_failures.has(id))
	var added: Array = new_failures.keys().filter(func(id): return not old_failures.has(id))
	var original: Dictionary = {}
	for part in b.parts:
		original[part.id] = part.snapshot()
	# Validation derives caches. Compare authoritative geometry/material fields,
	# not derived support labels; all permitted changed IDs remain explicit.
	var unexpected: Array = []
	for part in candidate.parts:
		if not original.has(part.id) or member_ids.has(part.id) or String(part.id).begins_with("urban_terminal_"):
			continue
		var old: Dictionary = original[part.id]
		if old.position != part.position or old.rotation != part.rotation or old.size != part.size or old.material != part.material_id or old.collision != part.collision_enabled:
			unexpected.append(part.id)
	report["combinedRecipe"] = {"ready": true, "frames": frames, "baselineViolations": before.violations.size(),
		"candidateViolations": after.violations.size(), "removedFailureIds": removed, "addedFailureIds": added,
		"unexpectedGeometryChanges": unexpected, "memberIds": member_ids,
		"quarterTurn": layout.quarterTurn, "supportId": layout.supportId, "approach": layout.approach,
		"transformOrigin": pose.origin, "transformBasis": [pose.basis.x, pose.basis.y, pose.basis.z],
		"candidatePhysicalReport": after, "baselinePhysicalReport": before,
		"doesNotProve": "Source-only combined recipe prototype; no headed appearance, exact published contact or runtime integration acceptance."}
	report["extraChecksCompleted"] = before.violations.size() == 253 and added.is_empty() and unexpected.is_empty() and after.violations.size() < 253

func _clone(source):
	var copy = Blueprint.new(source.id, source.seed, source.style)
	copy.recipe = source.recipe.duplicate(true)
	copy.rooms = source.rooms.duplicate(true)
	for part in source.parts:
		copy.add_part(part.snapshot())
	return copy

func _comparison(before: Dictionary, after: Dictionary) -> Dictionary:
	var old: Dictionary = {}
	var current: Dictionary = {}
	for row in before.checks:
		old[row.partId] = row
	for row in after.checks:
		current[row.partId] = row
	var removed: Array = []
	var added: Array = []
	var support_changes: Array = []
	for id in current:
		var row: Dictionary = current[id]
		if not row.passed and (not old.has(id) or old[id].passed):
			added.append(id)
		if not old.has(id):
			continue
		if not old[id].passed and row.passed:
			removed.append(id)
		var changes: Dictionary = {}
		for key in ["supportPartIds", "anchorPartIds", "seatPartIds", "supportCoverage", "anchorCoverage"]:
			if var_to_bytes(old[id].get(key)) != var_to_bytes(row.get(key)):
				changes[key] = {"before": old[id].get(key), "after": row.get(key)}
		if not changes.is_empty():
			support_changes.append({"partId": id, "changes": changes})
	removed.sort()
	added.sort()
	return {"violations": after.violations.size(), "removedFailureIds": removed,
		"addedFailureIds": added, "inferredSupportChanges": support_changes}

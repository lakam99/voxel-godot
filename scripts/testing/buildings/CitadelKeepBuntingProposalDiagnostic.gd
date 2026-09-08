extends "res://scripts/testing/buildings/CitadelBuntingStageDiagnostic.gd"
## Known captured structure IDs are exploratory fixture setup only. No owner
## association or proposed placement is written to production generation.
func _work() -> Dictionary:
	state.begin_phase("keep_bunting_proposal", 90000)
	var checks := {"pinned": FileAccess.get_sha256(_input_path()) == _input_sha()}
	var report := {"passed": false, "checks": checks, "scope": "Frozen-source exploratory tower/pavilion assembly proposal with real anchor proof and all captured obstacles. No production ownership/domain, full recipe, visuals or gameplay acceptance."}
	if not checks.pinned: return report
	var file := FileAccess.open(_input_path(), FileAccess.READ)
	if file == null: return report
	var input: Dictionary = file.get_var(false); file.close()
	var source = Heads.Copy.copy_blueprint(input.blueprint)
	var frozen := var_to_bytes(source.snapshot()); var inputs := var_to_bytes([input.assemblies, input.protected])
	var left = source.find_part("urban_civic_tower")
	var right = source.find_part("castle_keep_forecourt_pavilion_1")
	checks.fixture_owners = left != null and right != null and left.semantic == "citadel_civic_landmark" and right.semantic == "castle_keep_forecourt_pavilion"
	if not checks.fixture_owners: return report
	var a: AABB = source.transformed_part_bounds(left); var b: AABB = source.transformed_part_bounds(right)
	var lower := Vector3(a.end.x, maxf(a.position.y, b.position.y), maxf(a.position.z, b.position.z))
	var upper := Vector3(b.position.x, minf(a.end.y, b.end.y), minf(a.end.z, b.end.z))
	var bounds := AABB(lower, upper-lower)
	checks.opposing_common_faces = bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0
	if not checks.opposing_common_faces: return report
	var protected: Array = input.protected.duplicate(true)
	var courtyard_verified := false
	for room: Dictionary in source.rooms:
		if not room.get("bounds") is AABB: continue
		if room.get("role") == "courtyard":
			var outer: AABB = room.bounds
			courtyard_verified = courtyard_verified or (bounds.position.x >= outer.position.x and bounds.end.x <= outer.end.x and bounds.position.z >= outer.position.z and bounds.end.z <= outer.end.z)
		else:
			if not protected.has(room.bounds): protected.append(room.bounds)
	checks.shared_courtyard_xz = courtyard_verified
	if not courtyard_verified: return report
	var assemblies: Array = input.assemblies.duplicate(true)
	for assembly: Dictionary in assemblies:
		if assembly.ropeId == "urban_bunting_rope_02": assembly["placementDomain"] = {"leftAnchorIds": [left.id], "rightAnchorIds": [right.id], "bounds": bounds}
	var result := Anchor.prepare(source, assemblies, protected, state.checkpoint)
	checks.proposal_ready = result.get("ready", false)
	if checks.proposal_ready:
		var replacements := {}; var allowed := {}; var original := {}
		for assembly: Dictionary in assemblies:
			allowed[assembly.ropeId] = true
			for id: String in assembly.pennantIds: allowed[id] = true
		for record: Dictionary in input.blueprint.parts: original[record.id] = record
		var preserved := true
		for record: Dictionary in result.changes:
			preserved = preserved and allowed.has(record.id) and not replacements.has(record.id)
			replacements[record.id] = record
			for key: String in ["kind", "material", "rotation", "collision", "semantic"]: preserved = preserved and record[key] == original[record.id][key]
			if record.kind == "pennant": preserved = preserved and record.size == original[record.id].size
		checks.member_identity_and_style = preserved
		var snapshot: Dictionary = input.blueprint.duplicate(true)
		for i in range(snapshot.parts.size()): snapshot.parts[i] = replacements.get(snapshot.parts[i].id, snapshot.parts[i])
		var proof = Heads.Copy.copy_blueprint(snapshot)
		var physical: Dictionary = proof.validate_physical_integrity_cancellable(state.checkpoint)
		checks.all_selected_members_physically_pass = not physical.get("cancelled", false)
		var seen := {}
		for row: Dictionary in physical.get("checks", []):
			if allowed.has(row.partId):
				seen[row.partId] = true
				checks.all_selected_members_physically_pass = checks.all_selected_members_physically_pass and row.get("passed", false)
		checks.all_selected_members_physically_pass = checks.all_selected_members_physically_pass and seen.size() == allowed.size()
		var terminal := Anchor.verify_stored(proof, assemblies, protected, state.checkpoint)
		checks.stored_socket_and_clearance = terminal.get("ready", false)
		report["terminal"] = terminal
		file = FileAccess.open(OS.get_environment("CITADEL_ORDERED_OPENING_REPORT").get_base_dir().path_join("proposal.bin"), FileAccess.WRITE)
		if file == null: return report
		file.store_var({"inputSha256": _input_sha(), "proposal": result, "assemblies": assemblies, "protected": protected}, false)
		file.flush(); checks.proposal_written = file.get_error() == OK; file.close()
	result.erase("sourceBytes"); result.erase("changes")
	report["proposal"] = result; report["domain"] = bounds
	checks.source_immutable = frozen == var_to_bytes(source.snapshot()) and inputs == var_to_bytes([input.assemblies, input.protected]) and FileAccess.get_sha256(_input_path()) == _input_sha()
	checks.deadline = state.checkpoint("keep_bunting_proposal_completed")
	report.passed = checks.values().all(func(value): return value == true)
	return report

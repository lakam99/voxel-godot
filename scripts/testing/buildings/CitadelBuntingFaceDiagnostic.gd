extends "res://scripts/testing/buildings/CitadelOpeningHeadPolicyReplay.gd"
## Pinned pre-structural geometry audit only. Does not prove rootedness or
## reproduce the later-stage candidate failure.
const Anchor = preload("res://scripts/buildings/CitadelBuntingAnchorRecipe.gd")
func _work() -> Dictionary:
	var checks := {"pinned": FileAccess.get_sha256(_input_path()) == _input_sha()}
	var report := {"passed": false, "checks": checks, "scope": "Pinned pre-structural raw endpoint geometry audit; no rootedness, later-stage reproduction, placement or gameplay acceptance."}
	if not checks.pinned: return report
	var file := FileAccess.open(_input_path(), FileAccess.READ)
	if file == null: return report
	var input: Dictionary = file.get_var(false); file.close()
	var source = Heads.Copy.copy_blueprint(input.blueprint)
	var frozen := var_to_bytes(source.snapshot())
	var lines: Array = []
	for rope in source.parts:
		if rope.semantic != "citadel_bunting_rope": continue
		var half := Vector3(minf(rope.size.y, rope.size.z), rope.size.y, rope.size.z) * 0.25
		var low: float = rope.position.x - rope.size.x * 0.5
		var high: float = rope.position.x + rope.size.x * 0.5
		var rows: Array = []
		var left := 0; var right := 0
		for part in source.parts:
			if not state.checkpoint("bunting_raw_faces"): return report
			if not part.collision_enabled or part.kind not in ["wall", "foundation"] or part.rotation != Vector3.ZERO: continue
			var bounds: AABB = source.transformed_part_bounds(part)
			var side := ""
			if bounds.end.x < rope.position.x and bounds.end.x >= low: side = "left"
			if bounds.position.x > rope.position.x and bounds.position.x <= high: side = "right"
			if side.is_empty(): continue
			var fits_y: bool = rope.position.y-half.y > bounds.position.y+Anchor.SOCKET_INSET and rope.position.y+half.y < bounds.end.y-Anchor.SOCKET_INSET
			var fits_z: bool = rope.position.z-half.z > bounds.position.z+Anchor.SOCKET_INSET and rope.position.z+half.z < bounds.end.z-Anchor.SOCKET_INSET
			if fits_y and fits_z:
				if side == "left": left += 1
				else: right += 1
			# Keep relevant transverse spans, including exact failed Y limits.
			if fits_z: rows.append({"id": part.id, "side": side, "bounds": bounds, "fitsY": fits_y, "intent": part.physical_intent})
		lines.append({"rope": rope.snapshot(), "rawLeftFaces": left, "rawRightFaces": right, "zAlignedFaces": rows})
	checks.three_assemblies = lines.size() == 3
	checks.source_immutable = frozen == var_to_bytes(source.snapshot()) and FileAccess.get_sha256(_input_path()) == _input_sha()
	checks.deadline = state.checkpoint("bunting_raw_faces_completed")
	report["lines"] = lines
	report.passed = checks.values().all(func(value): return value == true)
	return report

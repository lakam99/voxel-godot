extends SceneTree
## Read-only attribution of observed renderer blockers to frozen recipe records.
## Does not certify global invisibility, physical bearing or exterior appearance.
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const OBSERVED := "res://artifacts/citadel-visual-reset/facade-assembly-renderer-01/report.json"
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("VOXEL_FACADE_OCCLUDER_SOURCE_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()):
		quit(2)
		return
	var identity := FileAccess.get_sha256(OBSERVED)
	var observed: Variant = JSON.parse_string(FileAccess.get_file_as_string(OBSERVED))
	var candidate := Plan.read_input("candidate")
	if not observed is Dictionary or candidate.is_empty() or observed.get("requestedStage") != "assembly_review" or observed.get("views", []).size() != 1:
		quit(2)
		return
	var before: Dictionary = {}
	var after: Dictionary = {}
	for record in candidate.beforeSnapshot.parts: before[record.id] = record
	for record in candidate.afterSnapshot.parts: after[record.id] = record
	var blockers: Dictionary = {}
	for example in observed.views[0].camera.get("targetRejectionExamples", []):
		var failure: Dictionary = example.get("failure", {})
		for hit in failure.get("firstBlockers", []):
			var id: String = hit.get("partId", "")
			if not id.is_empty(): blockers[id] = int(blockers.get(id, 0)) + 1
		for sample in failure.get("failedSamples", []):
			var id: String = sample.get("firstBlocker", {}).get("partId", "")
			if not id.is_empty(): blockers[id] = int(blockers.get(id, 0)) + 1
	var ids: Array = blockers.keys()
	ids.sort()
	var rows: Array = []
	var unchanged := not ids.is_empty()
	for id in ids:
		var original: Dictionary = before.get(id, {})
		var current: Dictionary = after.get(id, {})
		var exact: bool = not original.is_empty() and not current.is_empty() and var_to_bytes(original) == var_to_bytes(current)
		unchanged = unchanged and exact and not candidate.partIds.has(id)
		rows.append({"partId": id, "observedBlockerCount": blockers[id], "recordUnchanged": exact,
			"addedByCandidate": candidate.partIds.has(id), "sourceRecord": current})
	var report := {"passed": unchanged and identity == FileAccess.get_sha256(OBSERVED),
		"evidence": "observed_occluder_exact_frozen_source_attribution_only", "observedReport": OBSERVED,
		"observedReportSha256": identity, "candidateSha256": Plan.INPUTS.candidate[1], "rows": rows,
		"doesNotProve": "No global occlusion, new renderer capture, physical bearing, exterior appearance or integration acceptance. Attribution does not waive missing evidence."}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	print("Observed blocker source audit count=", rows.size(), " passed=", report.passed)
	quit(0 if written and report.passed else 2)
func _json(value: Variant) -> Variant:
	if value is Vector3: return [value.x, value.y, value.z]
	if value is Vector2: return [value.x, value.y]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Array:
		var result: Array = []
		for item in value: result.append(_json(item))
		return result
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[key] = _json(value[key])
		return result
	return value

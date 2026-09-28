extends SceneTree

const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Opening = preload("res://scripts/buildings/OpeningHeadBandRecipe.gd")
const Lower = preload("res://scripts/buildings/LowerFacadeBearingRecipe.gd")

func _initialize() -> void:
	var source: Variant = _read(OS.get_environment("VOXEL_OPENING_STAGE_SOURCE"))
	var expected: Variant = _read(OS.get_environment("VOXEL_OPENING_STAGE_EXPECTED"))
	var expected_first: Variant = _read(OS.get_environment("VOXEL_OPENING_STAGE_EXPECTED_FIRST"))
	var report := {"ready": false}
	if source is Dictionary and expected is Dictionary:
		var result := Opening.prepare_all_first_rows(Copy.copy_blueprint(source.afterSnapshot), {
			"furnitureParts": source.furnitureSnapshot.parts,
			"reservedVolumes": source.protectedReservations,
			"requiredHeadroom": 1.72})
		report.ready = result.get("ready", false)
		if result.get("ready", false):
			report["exactExpectedSnapshot"] = var_to_bytes(result.candidateSnapshot) == var_to_bytes(expected.afterSnapshot)
			var selection := Lower._current_unsupported_bottom_panels(result.candidateSnapshot)
			report["firstEligible"] = selection.get("eligible", []).slice(0, 8)
			report["failureCount"] = selection.get("failureCount", -1)
			if expected_first is Dictionary and not selection.get("eligible", []).is_empty():
				var policy := {"furnitureParts": source.furnitureSnapshot.parts, "reservedVolumes": source.protectedReservations}
				var first := Lower.prepare_batch(result.candidateSnapshot, [selection.eligible[0]], policy)
				report["firstReady"] = first.get("ready", false)
				report["firstExactExpected"] = first.get("ready", false) and var_to_bytes(first.afterSnapshot) == var_to_bytes(expected_first.afterSnapshot)
				if first.get("ready", false):
					var next := Lower._current_unsupported_bottom_panels(first.afterSnapshot)
					var requested: Array = next.get("eligible", []).slice(0, 4)
					var live_batch := Lower.prepare_batch(first.afterSnapshot, requested, policy)
					var archived_batch := Lower.prepare_batch(expected_first.afterSnapshot, requested, policy)
					report["secondRequested"] = requested
					report["liveSecond"] = _batch_summary(live_batch)
					report["archivedSecond"] = _batch_summary(archived_batch)
	var output := FileAccess.open(OS.get_environment("VOXEL_OPENING_STAGE_REPORT"), FileAccess.WRITE)
	if output != null: output.store_string(JSON.stringify(report, "\t")); output.close()
	quit(0 if report.get("ready", false) else 1)

func _batch_summary(value: Dictionary) -> Dictionary:
	return {"ready": value.get("ready", false),
		"accepted": value.get("accepted", []).map(func(record): return record.get("panelId", "")),
		"rejected": value.get("rejected", []).map(func(record): return {"panelId": record.get("panelId", ""), "reason": record.get("reason", "")})}

func _read(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return null
	var value: Variant = bytes_to_var(file.get_buffer(file.get_length()))
	file.close()
	return value

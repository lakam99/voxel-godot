extends "res://scripts/testing/buildings/CitadelUrbanPocRunner.gd"

## Compatibility diagnostic: shared composition now supplies all framing.
## This fixture inspects records only; it must not inject a second frame.

func build_castle_blueprint():
	var result = super.build_castle_blueprint()
	if result == null:
		return null
	var prefixes: Array[String] = []
	for part in result.parts:
		if part.semantic == "citadel_urban_roof" and String(part.id).ends_with("_roof_left"):
			prefixes.append(String(part.id).trim_suffix("_roof_left"))
	var setups: Array = []
	for prefix in prefixes:
		var frame_id: String = prefix + "_purlin_frame"
		var members: Array = result.parts.filter(func(part): return String(part.recipe.get("physicalGableFrameId", "")) == frame_id)
		setups.append({"ready": members.size() == 14, "frameId": frame_id, "source": "integrated_composer_only"})
	var setup_ready: bool = setups.size() == 16 and setups.all(func(value): return bool(value.get("ready", false)))
	var evidence := {"evidenceLevel": "integrated_roof_frame_appearance_diagnostic", "setupReady": setup_ready,
		"setups": setups, "seed": selected_seed, "scale": selected_citadel_scale,
		"strictContactStatus": "FAIL: represented submicrometre positive gaps remain; see gable-purlin-probe-08",
		"doesNotProve": "No exact joint contact, structural safety, full physical gate, NPC behavior or gameplay acceptance. Parent diagnostic opens its review door by service call, not player input."}
	var setup_path := report_path.get_base_dir().path_join("prototype-setup.json")
	var file := FileAccess.open(setup_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(evidence, "\t"))
	if not setup_ready or file == null:
		push_error("Roof-frame diagnostic setup incomplete; no acceptance")
		get_tree().quit(2)
		return null
	return result

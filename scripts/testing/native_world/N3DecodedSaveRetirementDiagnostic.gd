extends SceneTree

const RETIREMENT := preload("res://scripts/terrain/NativeDecodedSaveRetirement.gd")
const SECTION_CELLS := 4096
const SECTION_COUNT := 16

func _init() -> void:
	call_deferred("run")

func _save() -> Dictionary:
	var sections: Array = []
	for section_x in range(SECTION_COUNT):
		var section_key := [section_x, 0, 0]
		var origin := [section_x * 16, 0, 0]
		var cells: Array = []
		for index in range(SECTION_CELLS):
			var local := [index % 16, int(index / 16) % 16, int(index / 256)]
			var cell := [origin[0] + local[0], local[1], local[2]]
			cells.append({"cell":cell, "local":local, "state":{
				"cell":cell, "sectionKey":section_key, "localCell":local,
				"blockId":"terrain.import.test", "material":"stone", "biome":"underground",
				"solid":true, "density":1.25, "fluid":"",
				"light":{"sky":3, "block":7}, "metadata":{"saveDelta":true},
				"editReason":"n3_retirement_diagnostic", "generated":false, "edited":true}})
		sections.append({"schemaVersion":1, "sectionKey":section_key,
			"originCell":origin, "revision":7, "cells":cells})
	return {"version":2, "seed":"n3-decoded-save-retirement",
		"terrainVolume":{"schemaVersion":1, "sectionSize":16,
			"revision":9, "sections":sections}, "terrain":[]}

func run() -> void:
	var raw: Dictionary = _save()
	var raw_sections: Array = raw.terrainVolume.sections
	var raw_release_started := Time.get_ticks_usec()
	raw = {}
	raw_sections = []
	var raw_release_usec := Time.get_ticks_usec() - raw_release_started

	var owned: Dictionary = _save()
	var owned_sections: Array = owned.terrainVolume.sections
	var expected_cells := 0
	for section: Dictionary in owned_sections:
		expected_cells += section.cells.size()
	var retirement = RETIREMENT.new()
	var started: Dictionary = retirement.start_owned_file_save(owned)
	var steps := 0
	var last: Dictionary = started
	while last.get("status") == "pending" and steps < 1400:
		last = retirement.advance()
		steps += 1
		await process_frame
	var prior_to_outer_release: Dictionary = retirement.snapshot()
	var owned_release_started := Time.get_ticks_usec()
	owned = {}
	owned_sections = []
	retirement = null
	var owned_release_usec := Time.get_ticks_usec() - owned_release_started
	var empty_sections: Array = []
	for index in range(257):
		empty_sections.append({"sectionKey":[index, 0, 0], "cells":[]})
	var empty_save := {"version":2, "seed":"n3-decoded-save-retirement",
		"terrainVolume":{"schemaVersion":1, "sectionSize":16,
			"revision":1, "sections":empty_sections}, "terrain":[{"x":0, "z":0}]}
	var empty_retirement = RETIREMENT.new()
	var empty_started: Dictionary = empty_retirement.start_owned_file_save(empty_save)
	var empty_first: Dictionary = empty_retirement.advance()
	var empty_after_first: Dictionary = empty_retirement.snapshot()
	var empty_steps := 1
	var empty_last: Dictionary = empty_first
	while empty_last.get("status") == "pending" and empty_steps < 8:
		empty_last = empty_retirement.advance()
		empty_steps += 1
	var empty_bounded: bool = empty_started.get("status") == "pending" \
		and empty_first.get("status") == "pending" \
		and int(empty_after_first.get("sectionsRemaining", -1)) == 193 \
		and int(empty_after_first.get("legacyRemaining", -1)) == 1 \
		and empty_last.get("status") == "ready" \
		and int(empty_last.get("removedRecords", -1)) == 1 \
		and empty_steps == 5
	var passed: bool = started.get("status") == "pending" \
		and last.get("status") == "ready" \
		and int(last.get("removedRecords", -1)) == expected_cells \
		and expected_cells == SECTION_CELLS * SECTION_COUNT \
		and prior_to_outer_release.get("state") == "ready" \
		and empty_bounded
	var report := {"schema":"n3-decoded-save-retirement-diagnostic/v1",
		"passed":passed, "records":expected_cells, "steps":steps,
		"rawReleaseUsec":raw_release_usec, "ownedReleaseUsec":owned_release_usec,
		"retirement":last, "emptySections":{"passed":empty_bounded,
			"initialSections":257, "remainingAfterFirst":empty_after_first.get("sectionsRemaining", -1),
			"legacyAfterFirst":empty_after_first.get("legacyRemaining", -1),
			"steps":empty_steps, "final":empty_last},
		"evidenceLevel":"synthetic service diagnostic",
		"doesNotProve":["exclusive ownership in Main", "real file-backed save parity",
			"whole-game frame cadence", "external snapshot override disposal"]}
	var path := OS.get_environment("VWB_DECODED_SAVE_RETIREMENT_REPORT")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	await process_frame
	quit(0 if passed else 1)

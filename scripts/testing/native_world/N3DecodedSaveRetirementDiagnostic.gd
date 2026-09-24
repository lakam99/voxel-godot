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

func _invalid_start_case(save: Dictionary, expected_reason: String) -> Dictionary:
	var retirement = RETIREMENT.new()
	var started: Dictionary = retirement.start_owned_file_save(save)
	var retained: Dictionary = retirement.snapshot()
	var first: Dictionary = retirement.advance_failed_drain()
	var result: Dictionary = first
	var steps := 1
	while result.get("status") == "pending" and steps < 200:
		result = retirement.advance_failed_drain()
		steps += 1
	return {"passed":started.get("status") == "failed"
		and started.get("reason") == expected_reason
		and started.get("ownerMustBeRetained") == true
		and retained.get("state") == "failed" and retained.get("ownerRetained") == true
		and first.get("status") == "pending" and steps > 1
		and result.get("drained") == true
		and retirement.snapshot().get("ownerRetained") == false,
		"reason":started.get("reason", ""), "steps":steps,
		"retained":retained, "first":first, "final":result}

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
	var malformed_sections: Array = []
	for index in range(128):
		malformed_sections.append({"sectionKey":[index, 0, 0], "cells":[]})
	malformed_sections.append({"sectionKey":[128, 0, 0], "cells":"invalid"})
	var malformed_save := {"version":2, "seed":"n3-decoded-save-retirement",
		"terrainVolume":{"schemaVersion":1, "sectionSize":16,
			"revision":1, "sections":malformed_sections}, "terrain":[]}
	var malformed_retirement = RETIREMENT.new()
	var malformed_started: Dictionary = malformed_retirement.start_owned_file_save(malformed_save)
	var malformed_failed: Dictionary = malformed_retirement.advance()
	var malformed_retained: Dictionary = malformed_retirement.snapshot()
	var malformed_first_drain: Dictionary = malformed_retirement.advance_failed_drain()
	var malformed_after_first: Dictionary = malformed_retirement.snapshot()
	var malformed_drain_steps := 1
	var malformed_last: Dictionary = malformed_first_drain
	while malformed_last.get("status") == "pending" and malformed_drain_steps < 5:
		malformed_last = malformed_retirement.advance_failed_drain()
		malformed_drain_steps += 1
	var malformed_bounded: bool = malformed_started.get("status") == "pending" \
		and malformed_failed.get("reason") == "terrain_cells_invalid" \
		and malformed_failed.get("ownerMustBeRetained") == true \
		and malformed_retained.get("ownerRetained") == true \
		and malformed_retained.get("state") == "failed" \
		and malformed_first_drain.get("status") == "pending" \
		and int(malformed_after_first.get("sectionsRemaining", -1)) == 65 \
		and malformed_last.get("drained") == true \
		and malformed_drain_steps == 3 \
		and malformed_retirement.snapshot().get("ownerRetained") == false
	var invalid_volume: Array = []
	var invalid_sections: Dictionary = {}
	var invalid_legacy: Dictionary = {}
	for index in range(129):
		invalid_volume.append({"payload":[index]})
		invalid_sections[str(index)] = [index]
		invalid_legacy[str(index)] = [index]
	var invalid_start := {
		"volume":_invalid_start_case({"version":2, "seed":"invalid",
			"terrainVolume":invalid_volume, "terrain":[]}, "terrain_volume_invalid"),
		"sections":_invalid_start_case({"version":2, "seed":"invalid",
			"terrainVolume":{"sections":invalid_sections}, "terrain":[]},
			"terrain_sections_invalid"),
		"legacy":_invalid_start_case({"version":2, "seed":"invalid",
			"terrainVolume":{"sections":[]}, "terrain":invalid_legacy},
			"legacy_terrain_invalid")}
	var invalid_start_passed: bool = invalid_start.volume.passed \
		and invalid_start.sections.passed and invalid_start.legacy.passed
	var passed: bool = started.get("status") == "pending" \
		and last.get("status") == "ready" \
		and int(last.get("removedRecords", -1)) == expected_cells \
		and expected_cells == SECTION_CELLS * SECTION_COUNT \
		and prior_to_outer_release.get("state") == "ready" \
		and empty_bounded and malformed_bounded and invalid_start_passed
	var report := {"schema":"n3-decoded-save-retirement-diagnostic/v1",
		"passed":passed, "records":expected_cells, "steps":steps,
		"rawReleaseUsec":raw_release_usec, "ownedReleaseUsec":owned_release_usec,
		"retirement":last, "emptySections":{"passed":empty_bounded,
			"initialSections":257, "remainingAfterFirst":empty_after_first.get("sectionsRemaining", -1),
			"legacyAfterFirst":empty_after_first.get("legacyRemaining", -1),
			"steps":empty_steps, "final":empty_last},
		"malformedOwnerDrain":{"passed":malformed_bounded,
			"failed":malformed_failed, "retained":malformed_retained,
			"remainingAfterFirst":malformed_after_first.get("sectionsRemaining", -1),
			"steps":malformed_drain_steps, "final":malformed_last},
		"invalidStart":{"passed":invalid_start_passed, "cases":invalid_start},
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

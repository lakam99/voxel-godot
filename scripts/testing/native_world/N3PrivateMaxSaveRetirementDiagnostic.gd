extends SceneTree

const MAIN := preload("res://scripts/MainCore.gd")
const STRUCTURES := preload("res://scripts/StructureSystem.gd")
const WORLD := preload("res://scripts/WorldGenerationSystem.gd")
const STAGE := preload("res://scripts/terrain/NativePrivateMainLoadStage.gd")

const SECTION_CELLS := 4096
const SECTION_COUNT := 16

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var main = MAIN.new()
	main.seed_text = "n3-private-max-save-retirement"
	main.seed_hash = main.hash_string(main.seed_text)
	main.setup_noise()
	main.structure_system = STRUCTURES.new()
	main.structure_system.citadel_terrain_admission.configure(main.seed_text, {}, {
		"regionCells":main.STRUCTURE_REGION_CELLS,
		"spawnChance":float(main.STRUCTURE_SPAWN_CHANCE)})
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	var build_started := Time.get_ticks_usec()
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
	var built_usec := Time.get_ticks_usec() - build_started
	var save := {"version":2, "seed":main.seed_text, "terrain":[],
		"terrainVolume":{"schemaVersion":1, "sectionSize":16,
			"revision":9, "sections":sections}}
	var stage = STAGE.new()
	var started: Dictionary = stage.start(main, save)
	var result: Dictionary = started
	var frames := 0
	while result.get("status") == "pending" and frames < 1800:
		result = stage.advance()
		frames += 1
		await process_frame
	var before_stop: Dictionary = stage.snapshot()
	var wrong_generation: Dictionary = stage._backend.start_private_staged_save_retirement(
		int(result.get("receipt", {}).get("generation", -1)) + 1) \
		if result.get("status") == "ready" else {}
	var stopped: Dictionary = stage.stop()
	var stop_frames := 0
	while not stopped.get("drained", false) and stop_frames < 300:
		await process_frame
		stopped = stage.advance_stop()
		stop_frames += 1
	var passed: bool = started.get("status") == "pending" and result.get("status") == "ready" \
		and before_stop.get("backendRetained") == true \
		and wrong_generation.get("reason") == "private_committed_owner_not_idle" \
		and int(before_stop.get("transaction", {}).get("recordsAdmitted", -1)) == 65536 \
		and stopped.get("drained") == true
	var report := {"schema":"n3-private-max-save-retirement/v1", "passed":passed,
		"recordCount":SECTION_COUNT * SECTION_CELLS, "buildUsec":built_usec,
		"advanceFrames":frames, "maxAdvanceUsec":before_stop.get("transaction", {}).get("maxAdvanceUsec", -1),
		"releaseUsec":stopped.get("releaseUsec", -1), "stopFrames":stop_frames,
		"start":started, "lastAdvance":result, "beforeStop":before_stop,
		"wrongGeneration":wrong_generation, "stop":stopped,
		"evidenceLevel":"service-diagnostic",
		"doesNotProve":["headed Main frame cadence", "native terrain authority cutover",
			"bounded whole-save disposal", "bounded worker completion latency"]}
	var stage_release_started := Time.get_ticks_usec()
	stage = null
	var stage_release_usec := Time.get_ticks_usec() - stage_release_started
	var save_release_started := Time.get_ticks_usec()
	save = {}
	var save_release_usec := Time.get_ticks_usec() - save_release_started
	var sections_release_started := Time.get_ticks_usec()
	sections = []
	var sections_release_usec := Time.get_ticks_usec() - sections_release_started
	var main_free_started := Time.get_ticks_usec()
	main.free()
	var main_free_usec := Time.get_ticks_usec() - main_free_started
	report["stageReleaseUsec"] = stage_release_usec
	report["saveReleaseUsec"] = save_release_usec
	report["sectionsReleaseUsec"] = sections_release_usec
	report["mainFreeUsec"] = main_free_usec
	var report_path := OS.get_environment("VWB_MAX_SAVE_RETIREMENT_REPORT")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	await process_frame
	quit(0 if passed else 1)

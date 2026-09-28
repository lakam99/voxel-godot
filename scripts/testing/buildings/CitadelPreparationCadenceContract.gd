extends SceneTree

## Synthetic accounting controls for the same helper used before live terminal
## branches. No rendering, publication, time-budget or visual acceptance claim.
const Preparation = preload("res://scripts/testing/buildings/CitadelOpeningHeadVisualPreparation.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_CADENCE_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var checks: Dictionary = {}
	var cadence := {"lastAdvanceEndUsec": -1, "betweenAdvanceUsec": 0, "maxBetweenAdvanceUsec": 0, "firstDrawnFrame": 5, "actualDrawnFrames": 0}
	checks.initial_sample = Preparation.record_cadence(cadence, 100, 5) and cadence.betweenAdvanceUsec == 0 and cadence.actualDrawnFrames == 0
	cadence.lastAdvanceEndUsec = 100
	checks.timeout_sample_includes_final_wait = Preparation.record_cadence(cadence, 150, 8) and cadence.betweenAdvanceUsec == 50 and cadence.maxBetweenAdvanceUsec == 50 and cadence.actualDrawnFrames == 3
	checks.terminal_resample_never_double_counts = Preparation.record_cadence(cadence, 170, 9) and cadence.betweenAdvanceUsec == 50 and cadence.actualDrawnFrames == 4
	cadence.lastAdvanceEndUsec = 200
	checks.completion_sample_includes_final_wait = Preparation.record_cadence(cadence, 230, 11) and cadence.betweenAdvanceUsec == 80 and cadence.maxBetweenAdvanceUsec == 50 and cadence.actualDrawnFrames == 6
	checks.completion_resample_never_double_counts = Preparation.record_cadence(cadence, 230, 11) and cadence.betweenAdvanceUsec == 80 and cadence.actualDrawnFrames == 6
	cadence.lastAdvanceEndUsec = 300
	var before := cadence.duplicate()
	checks.reversed_clock_rejects_without_consuming = not Preparation.record_cadence(cadence, 299, 12) and cadence == before
	checks.reversed_frames_reject_without_consuming = not Preparation.record_cadence(cadence, 310, 4) and cadence == before
	var passed: bool = checks.values().all(func(value): return value == true)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify({"passed": passed, "checks": checks, "evidenceLevel": "synthetic_terminal_cadence_accounting", "visualAcceptance": false}, "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)

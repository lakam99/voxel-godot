extends SceneTree

# Direct-service byte parity plus real audio-owner lifecycle contracts. No world,
# player interaction, audible-quality, or whole-game frame-time acceptance.
const AudioScript := preload("res://scripts/AudioEffectsSystem.gd")
const BASELINE_PATH := "res://artifacts/citadel-runtime-integration/audio-pcm-baseline-01/report.json"
const BASELINE_SHA := "f34707e40288c670734c35b4015c8acb5d0123d73798ae71dff2c94facdb6353"
const TEST_SEED := 17012026

class SyntheticMissingAssets extends AudioScript:
	var load_calls := 0
	func load_pcm_wav(_path: String, _loop := false) -> AudioStreamWAV:
		load_calls += 1
		return null
	func load_imported_stream(_name: String) -> AudioStream:
		load_calls += 1
		return null

var checks: Array[Dictionary] = []
var measurements := {}

func _initialize() -> void:
	call_deferred("run_contract")

func check(name: String, passed: bool, details: Dictionary = {}) -> void:
	checks.append({"name": name, "passed": passed, "details": details})

func digest(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

func describe_stream(stream: AudioStream) -> Dictionary:
	if stream is AudioStreamWAV:
		return {"class": "AudioStreamWAV", "bytes": stream.data.size(),
			"dataSha256": digest(stream.data), "format": stream.format,
			"mixRate": stream.mix_rate, "stereo": stream.stereo,
			"loopMode": stream.loop_mode, "loopBegin": stream.loop_begin,
			"loopEnd": stream.loop_end}
	if stream is AudioStreamMP3:
		return {"class": "AudioStreamMP3", "bytes": stream.data.size(),
			"dataSha256": digest(stream.data), "loop": stream.loop,
			"loopOffset": stream.loop_offset}
	return {"class": stream.get_class() if stream != null else "null"}

func stream_records(audio: AudioEffectsSystem) -> Dictionary:
	var records := {}
	for key in audio.streams:
		records[key] = describe_stream(audio.streams[key])
	return records

func stream_record_matches(actual: Dictionary, expected: Dictionary) -> bool:
	if actual.size() != expected.size():
		return false
	for field in actual:
		if not expected.has(field):
			return false
		if field in ["bytes", "format", "mixRate", "loopMode", "loopBegin", "loopEnd"]:
			# Historical JSON decodes numbers as floats. Validate the integer schema
			# exactly before conversion; never round fractional or nonfinite values.
			var value = expected[field]
			if not actual[field] is int or not (value is int or value is float):
				return false
			if not is_finite(float(value)) or float(value) != floorf(float(value)) or absf(float(value)) > 9007199254740991.0:
				return false
			if actual[field] != int(value):
				return false
		elif field == "loopOffset":
			if not (expected[field] is int or expected[field] is float) or not is_finite(float(expected[field])) or actual[field] != float(expected[field]):
				return false
		elif typeof(actual[field]) != typeof(expected[field]) or actual[field] != expected[field]:
			return false
	return true

func compare_records(label: String, records: Dictionary, baseline: Dictionary) -> void:
	check(label + "_stream_inventory", records.size() == 22 and records.size() == baseline.size(),
		{"actual": records.size(), "expected": baseline.size()})
	for key in baseline:
		check(label + "_" + String(key) + "_bytes_and_properties", stream_record_matches(records.get(key, {}), baseline[key]),
			{"actual": records.get(key, {}), "expected": baseline[key]})

func owned_players(audio: AudioEffectsSystem) -> Array:
	var players: Array = audio.sfx_players.duplicate()
	players.append_array([audio.rain_player, audio.knock_player, audio.music_player, audio.nature_player, audio.night_player])
	return players

func players_are_stopped(audio: AudioEffectsSystem, require_released := false) -> bool:
	for item in owned_players(audio):
		var audio_player := item as AudioStreamPlayer
		if audio_player == null or audio_player.playing or (require_released and audio_player.stream != null):
			return false
	return true

func run_contract() -> void:
	var baseline_sha := FileAccess.get_sha256(BASELINE_PATH)
	check("historical_baseline_is_pinned", baseline_sha == BASELINE_SHA, {"actual": baseline_sha, "expected": BASELINE_SHA})
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(BASELINE_PATH))
	if not parsed is Dictionary or baseline_sha != BASELINE_SHA:
		finish()
		return
	var baseline: Dictionary = parsed
	check("baseline_is_successful_direct_service", bool(baseline.get("passed", false)) and String(baseline.get("evidenceLevel", "")) == "direct-service")
	var source_assets: Dictionary = baseline.get("sourceAssets", {})
	check("baseline_has_all_eight_wav_sources", source_assets.size() == 8)
	for key in source_assets:
		var source: Dictionary = source_assets[key]
		check("source_" + String(key) + "_unchanged", FileAccess.get_sha256(String(source.path)) == String(source.sha256))
	seed(TEST_SEED)
	var synchronous := AudioScript.new()
	var started := Time.get_ticks_usec()
	synchronous.build_streams()
	measurements.synchronousBuildUsec = Time.get_ticks_usec() - started
	var next_random := randi()
	var following_random := randi()
	var expected_streams: Dictionary = baseline.get("streams", {})
	var sync_records := stream_records(synchronous)
	var sync_keys := synchronous.streams.keys()
	var fractional: Dictionary = expected_streams.strike.duplicate()
	fractional.bytes = float(fractional.bytes) + 0.5
	check("comparison_rejects_fractional_integer_schema", not stream_record_matches(sync_records.strike, fractional))
	var wrong_hash: Dictionary = expected_streams.strike.duplicate()
	wrong_hash.dataSha256 = "different"
	check("comparison_rejects_changed_byte_digest", not stream_record_matches(sync_records.strike, wrong_hash))
	var wrong_bytes: Dictionary = expected_streams.strike.duplicate()
	wrong_bytes.bytes = float(wrong_bytes.bytes) + 1.0
	check("comparison_rejects_changed_integral_value", not stream_record_matches(sync_records.strike, wrong_bytes))
	var wrong_bool: Dictionary = expected_streams.strike.duplicate()
	wrong_bool.stereo = 0
	check("comparison_rejects_changed_boolean_type", not stream_record_matches(sync_records.strike, wrong_bool))
	compare_records("synchronous", sync_records, expected_streams)
	check("synchronous_preserves_original_rng", next_random == int(baseline.nextRandom))
	check("synchronous_daytime_order", synchronous.daytime_music_tracks == baseline.daytimeTracks)
	check("synchronous_shared_jobs_complete", not synchronous.stream_build_active and synchronous.stream_build_jobs.is_empty() and synchronous.stream_build_cursor == 22)
	synchronous.free()
	await test_staged_owner(expected_streams, sync_keys, next_random, following_random)
	await test_missing_assets(next_random)
	for cancel_phase in ["before_first_asset", "after_first_asset", "prime_audio", "prime_visuals", "prime_materials", "ready"]:
		await test_cancellation(String(cancel_phase))
	await test_exit_during_preparation()
	finish()

func test_staged_owner(expected_streams: Dictionary, expected_keys: Array, expected_random: int, following_random: int) -> void:
	seed(TEST_SEED)
	var staged := AudioScript.new()
	staged.staged_startup = true
	var started := Time.get_ticks_usec()
	root.add_child(staged)
	measurements.reserveAndCreatePlayersUsec = Time.get_ticks_usec() - started
	check("staged_reserves_original_rng_before_first_yield", randi() == expected_random)
	check("staged_begin_owns_thirteen_players", owned_players(staged).size() == 13 and staged.get_child_count() == 13)
	check("staged_begin_publishes_no_stream_or_playback", staged.streams.is_empty() and players_are_stopped(staged) and not staged.is_processing())
	var colors := [Color(0.3, 0.4, 0.5), Color(0.8, 0.6, 0.2)]
	staged.prime_materials(colors)
	check("staged_retains_material_request_before_pool", staged.startup_material_colors == colors and staged.material_cache.is_empty() and staged.visual_effect_pool.is_empty())
	var steps: Array[Dictionary] = []
	var one_asset_per_step := true
	var no_early_process := true
	var no_early_playback := true
	for _index in range(32):
		if staged.startup_preparation_ready():
			break
		await process_frame
		var previous_phase := staged.startup_phase
		var previous_assets := staged.stream_build_timings.size()
		started = Time.get_ticks_usec()
		var state: Dictionary = staged.advance_startup_preparation()
		steps.append({"fromPhase": previous_phase, "toPhase": state.phase,
			"elapsedUsec": Time.get_ticks_usec() - started, "frame": Engine.get_process_frames(),
			"completedJobs": state.completedJobs})
		one_asset_per_step = one_asset_per_step and staged.stream_build_timings.size() - previous_assets <= 1
		no_early_process = no_early_process and (staged.startup_preparation_ready() or not staged.is_processing())
		if previous_phase == "streams":
			no_early_playback = no_early_playback and players_are_stopped(staged)
	measurements.stagedSteps = steps
	measurements.stagedAssets = staged.stream_build_timings.duplicate(true)
	check("staged_completes_in_fourteen_frame_steps", staged.startup_preparation_ready() and steps.size() == 14, {"actualSteps": steps.size()})
	check("staged_at_most_one_asset_per_advance", one_asset_per_step)
	check("staged_process_only_enabled_when_ready", no_early_process and staged.is_processing())
	check("staged_no_playback_during_stream_build", no_early_playback)
	check("staged_later_phases_do_not_consume_rng", randi() == following_random)
	compare_records("staged", stream_records(staged), expected_streams)
	check("staged_preserves_dictionary_insertion_order", staged.streams.keys() == expected_keys)
	check("staged_daytime_order_and_alias", staged.daytime_music_tracks == AudioScript.DAYTIME_MUSIC_TRACKS and staged.streams.get("daytime") == staged.streams.get("tutorialTownDay"))
	check("staged_primes_owned_players_after_streams", staged.rain_player.playing and staged.music_player.playing and staged.nature_player.playing and staged.night_player.playing and staged.knock_player.stream == staged.streams.get("knock"))
	check("staged_primes_original_visual_pool_and_materials", staged.effect_nodes_created == 64 and staged.visual_effect_pool.size() + staged.feedback_prime_nodes.size() == 64 and staged.material_cache.size() == colors.size() and staged.startup_material_colors.is_empty())
	var ready_state := staged.startup_preparation_state()
	staged.advance_startup_preparation()
	check("staged_ready_advance_is_idempotent", ready_state == staged.startup_preparation_state() and staged.effect_nodes_created == 64)
	staged.free()

func test_missing_assets(expected_random: int) -> void:
	seed(TEST_SEED)
	var missing := SyntheticMissingAssets.new()
	missing.staged_startup = true
	root.add_child(missing)
	var reserved := {}
	for job in missing.stream_build_jobs:
		if job.has("fallback"):
			reserved[job.name] = job.fallback
	check("missing_assets_reserve_identical_rng", randi() == expected_random)
	for _index in range(32):
		if missing.startup_preparation_ready():
			break
		await process_frame
		missing.advance_startup_preparation()
	var exact_fallbacks := reserved.size() == 7
	for key in reserved:
		exact_fallbacks = exact_fallbacks and missing.streams.get(key) == reserved[key]
	check("missing_assets_use_exact_reserved_fallback_objects", exact_fallbacks)
	check("missing_second_music_uses_resolved_first_music", missing.streams.get("gameDay2") == missing.streams.get("tutorialTownDay") and missing.streams.get("daytime") == missing.streams.get("tutorialTownDay"))
	check("missing_imported_streams_remain_absent", not missing.streams.has("natureDay") and not missing.streams.has("nightWind"))
	check("missing_assets_complete_original_ten_load_attempts", missing.startup_preparation_ready() and missing.load_calls == 10)
	reserved.clear()
	missing.free()

func test_cancellation(cancel_phase: String) -> void:
	var subject := SyntheticMissingAssets.new()
	subject.staged_startup = true
	root.add_child(subject)
	subject.prime_materials([Color(0.2, 0.3, 0.4)])
	if cancel_phase == "after_first_asset":
		subject.advance_startup_preparation()
	elif cancel_phase != "before_first_asset":
		for _index in range(32):
			if subject.startup_phase == cancel_phase:
				break
			subject.advance_startup_preparation()
	var reached := (cancel_phase == "before_first_asset" and subject.load_calls == 0) or (cancel_phase == "after_first_asset" and subject.load_calls == 1) or subject.startup_phase == cancel_phase
	var previous_calls := subject.load_calls
	subject.shutdown_audio()
	subject.shutdown_audio()
	subject.advance_startup_preparation()
	subject.build_streams()
	subject.prime_materials([Color.RED])
	await process_frame
	check("cancel_" + cancel_phase + "_does_not_resume", reached and subject.load_calls == previous_calls and subject.startup_phase == "cancelled" and not subject.startup_preparation_ready() and not subject.is_processing() and not subject.stream_build_active)
	check("cancel_" + cancel_phase + "_releases_pending_and_playback", subject.stream_build_jobs.is_empty() and subject.streams.is_empty() and subject.startup_material_colors.is_empty() and subject.material_cache.is_empty() and players_are_stopped(subject, true))
	subject.free()

func test_exit_during_preparation() -> void:
	var subject := SyntheticMissingAssets.new()
	subject.staged_startup = true
	root.add_child(subject)
	subject.advance_startup_preparation()
	root.remove_child(subject)
	await process_frame
	check("exit_tree_cancels_pending_audio", subject.startup_phase == "cancelled" and subject.stream_build_jobs.is_empty() and subject.streams.is_empty() and players_are_stopped(subject, true))
	subject.free()

func finish() -> void:
	var failures := 0
	for result in checks:
		if not bool(result.passed):
			failures += 1
	var output := OS.get_environment("VOXEL_AUDIO_STARTUP_CONTRACT_REPORT")
	var report := {"schema": "audio-startup-preparation-contract/v1", "passed": failures == 0,
		"evidenceLevel": "direct-service-and-owner-lifecycle-contract", "engine": Engine.get_version_info(),
		"scope": "Pinned historical 22-stream bytes/properties and RNG parity; real audio owner staged priming and synthetic missing-asset cancellation; no Main scene, audible-quality, or whole-game performance acceptance",
		"baselinePath": BASELINE_PATH, "baselineSha256": BASELINE_SHA,
		"productionSourceSha256": FileAccess.get_sha256("res://scripts/AudioEffectsSystem.gd"),
		"total": checks.size(), "failed": failures, "checks": checks, "measurements": measurements}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write VOXEL_AUDIO_STARTUP_CONTRACT_REPORT")
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("Audio startup contract: ", checks.size() - failures, "/", checks.size())
	quit(0 if failures == 0 else 1)

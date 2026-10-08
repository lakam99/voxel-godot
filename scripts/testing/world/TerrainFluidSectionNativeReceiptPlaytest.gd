extends SceneTree

const AdmissionDiagnostics := preload("res://scripts/testing/world/StaticSectionAdmissionDiagnostics.gd")

const MainScene := preload("res://scenes/Main.tscn")
const Vox43Selector := preload("res://scripts/testing/terrain/Vox43UndergroundFluidVisualRunner.gd")
const SectionGrid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const InstallSession := preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const TerrainSectionSnapshot := preload("res://scripts/terrain/AuthoritativeTerrainSectionSnapshot.gd")
const REPORT_SCHEMA := "terrain-fluid-section-native-receipt/v1"
const CELL := 1.35
const OBSERVATION_LIMIT_SECONDS := 360.0
const MAIN_STARTUP_WAIT_SECONDS := 240.0

var main: Node3D
var player: CharacterBody3D
var player_camera: Camera3D
var diagnostic_camera: Camera3D
var observer_light: OmniLight3D
var coordinator: Object
var terrain_runtime: Object
var sample: Dictionary = {}
var section_key := Vector3i.ZERO
var fluid_source_id := ""
var selected_fluid_signature := ""
var legacy_visual_instance_id := 0
var legacy_chunk_key := Vector2i.ZERO
var seed_text := ""
var initial_player_position := Vector3.ZERO
var report_path := ""
var progress_path := ""
var screenshot_path := ""
var started_msec := 0
var checks: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var finished := false
var startup_failure: Dictionary = {}
var startup_failure_signal_message := ""
var replacement_lifecycle_evidence: Dictionary = {}


func _initialize() -> void:
	started_msec = Time.get_ticks_msec()
	seed_text = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	report_path = OS.get_environment("VOXEL_TERRAIN_FLUID_SECTION_RECEIPT_REPORT")
	progress_path = OS.get_environment("VOXEL_TERRAIN_FLUID_SECTION_RECEIPT_PROGRESS")
	screenshot_path = OS.get_environment("VOXEL_TERRAIN_FLUID_SECTION_RECEIPT_SCREENSHOT")
	call_deferred("_run")


func _run() -> void:
	OS.set_environment("VOXEL_PLAYTEST", "1")
	OS.set_environment("VOXEL_TEST_SEED", seed_text)
	_check("fixed_seed_and_skip_tutorial_arguments", not seed_text.is_empty() \
		and "-SkipTutorial" in OS.get_cmdline_user_args(), {
		"seed":seed_text, "userArguments":OS.get_cmdline_user_args()})
	main = MainScene.instantiate() as Node3D
	if not is_instance_valid(main):
		_check("production_main_scene_instantiated", false, "Main.tscn failed to instantiate")
		await _finish()
		return
	main.set("render_distance", 1)
	main.set("visual_quality", {"decorativeDensity":0.0,
		"decorativeDetailCap":0, "particleDensity":0.0})
	if main.has_signal("startup_loading_failed"):
		main.connect("startup_loading_failed", _on_startup_failed)
	root.add_child(main)
	current_scene = main
	var launch_options: Dictionary = main.get("launch_options")
	_check("real_main_skips_tutorial", bool(launch_options.get("skipTutorial", false)),
		launch_options)
	if not checks.back().passed:
		await _finish()
		return
	_write_progress("waiting_for_main_startup", {"scene":"res://scenes/Main.tscn",
		"waitSeconds":MAIN_STARTUP_WAIT_SECONDS})
	var startup_wait_started_msec := Time.get_ticks_msec()
	var startup_ok: bool = bool(await main.call("wait_for_startup_loading_complete",
		MAIN_STARTUP_WAIT_SECONDS, true))
	if not startup_ok:
		var startup_result: Variant = main.get("startup_loading_failure_result")
		if startup_result is Dictionary:
			startup_failure = startup_result.duplicate(true)
		else:
			startup_failure = {"startupLoadingFailureResult":str(startup_result)}
		if not startup_failure_signal_message.is_empty():
			startup_failure["signalMessage"] = startup_failure_signal_message
		var startup_wait_elapsed_msec := Time.get_ticks_msec() - startup_wait_started_msec
		var wait_outcome := "main_startup_failed" if not startup_failure.is_empty() \
			or not startup_failure_signal_message.is_empty() else "readiness_wait_timed_out"
		if wait_outcome == "readiness_wait_timed_out":
			startup_failure["reason"] = "startup_readiness_wait_timeout"
		startup_failure["startupReadinessDiagnosticSchema"] = "main-startup-readiness-timeout/v1"
		startup_failure["startupWait"] = {"outcome":wait_outcome,
			"limitSeconds":MAIN_STARTUP_WAIT_SECONDS,
			"elapsedMsec":startup_wait_elapsed_msec,
			"readinessAccepted":false}
		startup_failure["readinessDomainsAtWaitEnd"] = _startup_readiness_domains()
		startup_failure["loadingStateAtWaitEnd"] = _startup_loading_state()
		startup_failure["sourceCaptureSchedulerAtWaitEnd"] = _startup_source_capture_progress()
		startup_failure["sectionCompiler"] = _startup_section_compiler_progress()
		startup_failure["staticSectionAdmission"] = AdmissionDiagnostics.snapshot(main)
		startup_failure["terrainFluidPublication"] = _startup_terrain_fluid_progress()
		_write_progress("main_startup_readiness_failed", startup_failure)
		_check("real_main_startup_ready_for_diagnostic", false, startup_failure)
		await _finish()
		return
	coordinator = main.get("world_static_section_coordinator") as Object
	terrain_runtime = main.get("voxel_terrain_runtime") as Object
	player = main.get("player") as CharacterBody3D
	player_camera = player.get("camera") as Camera3D if is_instance_valid(player) else null
	initial_player_position = player.global_position if is_instance_valid(player) else Vector3.ZERO
	_check("production_terrain_provider_and_coordinator_live",
		is_instance_valid(coordinator) and is_instance_valid(terrain_runtime) \
		and bool(terrain_runtime.get("authority_ready")) \
		and terrain_runtime.generation_context_current(), {
		"coordinator":is_instance_valid(coordinator),
		"terrainRuntime":is_instance_valid(terrain_runtime),
		"authorityReady":bool(terrain_runtime.get("authority_ready")) \
			if is_instance_valid(terrain_runtime) else false})
	if not checks.back().passed:
		await _finish()
		return
	var selector: Node = Vox43Selector.new()
	selector.set("main", main)
	selector.set("world_generation", main.get("world_generation_system"))
	var selected: Dictionary = selector.call("find_stage_records")
	sample = selected.get("generated_water_exposed", {})
	_check("vox43_generated_exposed_water_sample_selected", not sample.is_empty(), {
		"selectedStages":selected.keys(), "seed":seed_text})
	if sample.is_empty():
		await _finish()
		return
	var fluid_cell: Vector3i = sample.get("fluidCell", Vector3i.ZERO)
	section_key = SectionGrid.key_for_cell(fluid_cell)
	fluid_source_id = terrain_runtime.call("_terrain_section_source_part_id", section_key)
	await _stage_legacy_visual_and_move_to_sample()
	if finished:
		return
	var readiness := await _wait_for_resident_section_and_fluid_proof()
	_check("real_voxelterrain_section_resident_and_exact_fluid_proof_current",
		readiness.get("status") == "ready", readiness)
	if readiness.get("status") != "ready":
		await _finish()
		return
	var proof: Dictionary = terrain_runtime.get("terrain_section_fluid_proofs").get(section_key, {})
	var exact_revision := String(terrain_runtime.call("_terrain_section_source_revision",
		section_key, proof))
	selected_fluid_signature = String(proof.get("signature", ""))
	_check("fluid_proof_has_exact_current_source_revision",
		bool(proof.get("hasFluid", false)) and not exact_revision.is_empty(), {
		"sectionKey":_vec3i(section_key), "fluidSourceId":fluid_source_id,
		"proof":_proof_summary(proof), "expectedSourceRevision":exact_revision})
	if not checks.back().passed:
		await _finish()
		return
	var source_parity := await _compare_authoritative_source_with_resident(section_key, proof)
	_check("authoritative_section_source_matches_resident_voxeltools_channels",
		source_parity.get("status") == "ready", source_parity)
	if not checks.back().passed:
		await _finish()
		return
	var demand_state: Dictionary = coordinator.get("_visible_section_demands").get(section_key, {})
	if demand_state.is_empty():
		var terrain_revision := int(terrain_runtime.call("visible_mesh_source_revision", section_key))
		coordinator.call("request_visible_section_demand", section_key, terrain_revision, 0.0)
		_trace("resident_section_demand_requested_after_signal_check", {
			"sectionKey":_vec3i(section_key), "terrainRevision":terrain_revision})
	var candidate_wait := await _wait_for_current_native_receipt(exact_revision)
	_check("real_coordinator_candidate_native_receipt_and_exact_translucent_fluid_layer",
		candidate_wait.get("status") == "ready", candidate_wait)
	var final_candidate_wait: Dictionary = candidate_wait
	if candidate_wait.get("status") == "ready":
		final_candidate_wait = await _run_stale_replacement_lifecycle(candidate_wait)
		replacement_lifecycle_evidence = final_candidate_wait.get("lifecycleEvidence", {})
	if final_candidate_wait.get("status") == "ready":
		await _capture_and_check_live_comparison(final_candidate_wait)
	_write_progress("finished")
	await _finish()


func _stage_legacy_visual_and_move_to_sample() -> void:
	var fluid_cell: Vector3i = sample.get("fluidCell", Vector3i.ZERO)
	var camera_cell: Vector3i = sample.get("cameraCell", fluid_cell + Vector3i(0, 0, 2))
	var chunk_key: Vector2i = main.call("cell_to_chunk", fluid_cell.x, fluid_cell.z)
	if main.has_method("create_chunk"):
		main.call("create_chunk", chunk_key.x, chunk_key.y, true)
	if main.has_method("request_chunk_terrain_mesh_assets"):
		main.call("request_chunk_terrain_mesh_assets", chunk_key, true, 100)
	var chunk: Node = main.get("chunks").get(chunk_key)
	var legacy: MeshInstance3D = chunk.get_node_or_null("TerrainFluidMesh") as MeshInstance3D \
		if is_instance_valid(chunk) else null
	var requested_position := _cell_center(camera_cell)
	if is_instance_valid(player):
		player.global_position = requested_position
		player.velocity = Vector3.ZERO
	if is_instance_valid(player_camera):
		player_camera.current = false
	diagnostic_camera = Camera3D.new()
	diagnostic_camera.name = "TerrainFluidSectionDiagnosticCamera"
	diagnostic_camera.fov = 42.0
	root.add_child(diagnostic_camera)
	diagnostic_camera.current = true
	observer_light = OmniLight3D.new()
	observer_light.light_energy = 12.0
	observer_light.omni_range = CELL * 12.0
	observer_light.shadow_enabled = false
	root.add_child(observer_light)
	observer_light.global_position = requested_position
	diagnostic_camera.global_position = requested_position
	_look_at_sample(requested_position, _cell_center(fluid_cell))
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline:
		if is_instance_valid(legacy) and legacy.mesh != null \
				and legacy.mesh.get_surface_count() > 0 and legacy.is_visible_in_tree():
			break
		await process_frame
	var mesh := legacy.mesh if is_instance_valid(legacy) else null
	_check("legacy_voxeltools_fluid_visual_live_as_comparison_authority",
		mesh != null and mesh.get_surface_count() > 0 and legacy.is_visible_in_tree(), {
		"chunkKey":_vec2i(chunk_key), "nodePresent":is_instance_valid(legacy),
		"visible":is_instance_valid(legacy) and legacy.is_visible_in_tree(),
		"surfaceCount":mesh.get_surface_count() if mesh != null else 0,
		"fluidFaces":int(mesh.get_meta("chunk_fluid_faces", 0)) if mesh != null else 0,
		"waterFaces":int(mesh.get_meta("chunk_water_faces", 0)) if mesh != null else 0,
		"legacyVisualInstanceId":legacy.get_instance_id() if is_instance_valid(legacy) else 0})
	if not checks.back().passed:
		await _finish()
		return
	legacy_visual_instance_id = legacy.get_instance_id()
	legacy_chunk_key = chunk_key
	_trace("legacy_fluid_visual_ready_and_player_teleported", {
		"sample":_sample_summary(sample), "sectionKey":_vec3i(section_key),
		"playerPosition":_vec3(requested_position), "teleportDiagnostic":true})
	_write_progress("legacy_fluid_visual_ready_player_at_sample")


func _wait_for_resident_section_and_fluid_proof() -> Dictionary:
	var deadline := Time.get_ticks_msec() + 180000
	var last: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		var resident: Variant = terrain_runtime.get("published_mesh_blocks")
		var proof: Dictionary = terrain_runtime.get("terrain_section_fluid_proofs").get(section_key, {})
		var proof_ready: bool = bool(terrain_runtime.call(
			"_terrain_section_fluid_proof_is_current", section_key, proof))
		if resident is Dictionary and resident.has(section_key) and proof_ready \
				and String(proof.get("signature", "")) != "":
			var capture_state: Dictionary = terrain_runtime.call("_resident_terrain_capture_state", section_key)
			last = {"resident":true, "proof":_proof_summary(proof),
				"captureState":capture_state,
				"runtimeMetrics":terrain_runtime.call("status") \
					if terrain_runtime.has_method("status") else {}}
			if capture_state.get("status") == "ready":
				return {"status":"ready", "sectionKey":_vec3i(section_key),
					"proof":_proof_summary(proof), "captureState":capture_state,
					"elapsedMsec":Time.get_ticks_msec() - started_msec}
		last = {"resident":resident is Dictionary and resident.has(section_key),
			"proofCurrent":proof_ready, "proof":_proof_summary(proof),
			"captureState":terrain_runtime.call("_resident_terrain_capture_state", section_key),
			"demand":coordinator.get("_visible_section_demands").get(section_key, {})}
		if Engine.get_process_frames() % 120 == 0:
			_write_progress("waiting_for_section_residency_fluid_proof", last)
		await process_frame
	return {"status":"pending", "reason":"section_residency_or_current_fluid_proof_timeout",
		"sectionKey":_vec3i(section_key), "last":last,
		"elapsedMsec":Time.get_ticks_msec() - started_msec}


func _compare_authoritative_source_with_resident(section: Vector3i,
		fluid_proof: Dictionary) -> Dictionary:
	var resident: Dictionary = terrain_runtime.call("capture_resident_terrain_mesh_block", section)
	if resident.get("status") != "ready":
		return {"status":"pending", "reason":"resident_voxeltools_capture_unavailable",
			"capture":resident}
	var volume: Object = terrain_runtime.call("volume_service")
	var generator: Object = terrain_runtime.get("generator")
	var world_id := "seed:%s:%d" % [String(main.get("seed_text")), int(main.get("seed_hash"))]
	var material_revision := String(terrain_runtime.call("_terrain_capture_mesher_material_revision"))
	var prepared_result: Dictionary = TerrainSectionSnapshot.prepare(generator, volume,
		section, world_id, material_revision, fluid_proof)
	if prepared_result.get("status") != "ready":
		return {"status":"pending", "reason":"authoritative_source_prepare_failed",
			"prepare":prepared_result, "residentDigest":resident.get("payloadDigest", "")}
	var prepared: Dictionary = prepared_result.get("prepared", {})
	var cancellation := TerrainSectionSnapshot.CancellationToken.new()
	var worker := Thread.new()
	var start_error := worker.start(Callable(TerrainSectionSnapshot,
		"generate_prepared").bind(prepared, cancellation))
	if start_error != OK:
		return {"status":"failed", "reason":"authoritative_source_worker_start_failed",
			"error":error_string(start_error)}
	var deadline := Time.get_ticks_msec() + 30000
	var generated_result: Variant
	while worker.is_alive() and Time.get_ticks_msec() < deadline:
		await process_frame
	if worker.is_alive():
		cancellation.cancel()
		var timed_out_result: Variant = worker.wait_to_finish()
		return {"status":"pending", "reason":"authoritative_source_worker_timeout",
			"workerResult":timed_out_result}
	generated_result = worker.wait_to_finish()
	if not generated_result is Dictionary:
		return {"status":"failed", "reason":"authoritative_source_worker_result_invalid",
			"workerResultType":type_string(typeof(generated_result))}
	var sealed_result: Dictionary = TerrainSectionSnapshot.seal(prepared,
		generated_result, generator, volume, world_id, material_revision, fluid_proof)
	if sealed_result.get("status") != "ready":
		return {"status":"pending", "reason":"authoritative_source_seal_failed",
			"seal":sealed_result, "workerResult":generated_result}
	var capture: Dictionary = sealed_result.get("capture", {})
	var current := TerrainSectionSnapshot.is_current(capture, generator, volume,
		world_id, material_revision, fluid_proof)
	var sdf_match := String(capture.get("sdf16LeBase64", "")) \
		== Marshalls.raw_to_base64(resident.get("sdf16Le", PackedByteArray()))
	var indices_match := String(capture.get("indices8Base64", "")) \
		== Marshalls.raw_to_base64(resident.get("indices8", PackedByteArray()))
	var data5_match := String(capture.get("data5_8Base64", "")) \
		== Marshalls.raw_to_base64(resident.get("data5_8", PackedByteArray()))
	return {"status":"ready" if current and sdf_match and indices_match and data5_match else "failed",
		"sectionKey":_vec3i(section), "sourceRevision":String(capture.get("sourceRevision", "")),
		"currentAtComparison":current, "sdfBytesMatch":sdf_match,
		"indicesBytesMatch":indices_match, "data5BytesMatch":data5_match,
		"authoritativeDigest":String(capture.get("payloadDigest", "")),
		"residentDigest":String(resident.get("payloadDigest", "")),
		"generationUsec":int(capture.get("generationUsec", 0)),
		"sampleCount":int(capture.get("sampleCount", 0))}


func _wait_for_current_native_receipt(exact_revision: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(OBSERVATION_LIMIT_SECONDS * 1000.0)
	var last: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		var candidate: Dictionary = coordinator.get("_production_candidates_by_section").get(section_key, {})
		var receipt: Dictionary = coordinator.get("_production_candidate_receipts").get(section_key, {})
		if not candidate.is_empty() and not receipt.is_empty():
			var inspection := _inspect_installed_candidate(candidate, receipt, exact_revision)
			last = inspection
			if inspection.get("status") == "ready":
				return inspection
		var job: Dictionary = coordinator.get("_production_candidate_jobs").get(section_key, {})
		last = {"candidateGeneration":int(candidate.get("generation", 0)),
			"receiptStatus":String(receipt.get("status", "missing")),
			"demand":coordinator.get("_visible_section_demands").get(section_key, {}),
			"jobStage":String(job.get("stage", "")),
			"lastAdmission":coordinator.get("_visible_section_demands").get(section_key, {}).get("lastAdmissionDetails", {}),
			"fluidProof":_proof_summary(terrain_runtime.get("terrain_section_fluid_proofs").get(section_key, {}))}
		if Engine.get_process_frames() % 120 == 0:
			_write_progress("waiting_for_candidate_install_receipt", last)
		await process_frame
	return {"status":"pending", "reason":"current_fluid_section_native_receipt_timeout",
		"sectionKey":_vec3i(section_key), "last":last,
		"elapsedMsec":Time.get_ticks_msec() - started_msec}


func _run_stale_replacement_lifecycle(initial_receipt: Dictionary) -> Dictionary:
	var old_candidate: Dictionary = coordinator.get("_production_candidates_by_section").get(section_key, {})
	var old_receipt: Dictionary = coordinator.get("_production_candidate_receipts").get(section_key, {})
	var old_native: Dictionary = _native_installed_snapshot(old_candidate, old_receipt)
	var old_identity := _candidate_render_identity(old_candidate, old_receipt)
	var old_generation := int(old_candidate.get("generation", 0))
	var old_fluid_proof: Dictionary = terrain_runtime.get("terrain_section_fluid_proofs").get(section_key, {})
	var old_fluid_signature := String(old_fluid_proof.get("signature", ""))
	var old_fluid_proof_current: bool = bool(terrain_runtime.call(
		"_terrain_section_fluid_proof_is_current", section_key, old_fluid_proof))
	var world_generation: Object = main.get("world_generation_system") as Object
	var volume: Object = world_generation.get("terrain_volume_service") as Object \
		if is_instance_valid(world_generation) else null
	var terrain: Object = terrain_runtime.get("terrain") as Object
	var fluid_cell: Vector3i = sample.get("fluidCell", Vector3i.ZERO)
	if not is_instance_valid(volume) or not volume.has_method("get_cell_state") \
			or not volume.has_method("set_cell_state") or not volume.has_method("clear_cell_state") \
			or not is_instance_valid(terrain) or not terrain.has_method("get_mesh_block_viewer_state"):
		_check("terrain_stale_replacement_fixture_authorities_available", false, {
			"volume":is_instance_valid(volume), "terrain":is_instance_valid(terrain)})
		return {"status":"failed", "reason":"terrain_lifecycle_fixture_authority_unavailable"}
	var original_state: Dictionary = volume.call("get_cell_state", fluid_cell)
	var expected_fluid := String(sample.get("fluid", ""))
	var original_edit_bucket: Dictionary = volume.get("edited_cells")
	var had_prior_cell_edit := original_edit_bucket.has(fluid_cell)
	var old_voxeltools_state: Dictionary = terrain.call("get_mesh_block_viewer_state", section_key)
	var setup_valid: bool = old_generation > 0 and old_receipt.get("status") == "installed" \
		and old_native.get("status") == "ready" \
		and int(old_native.get("generation", 0)) == old_generation \
		and old_fluid_proof_current and old_fluid_signature == selected_fluid_signature \
		and bool(old_voxeltools_state.get("present", false)) \
		and int(old_voxeltools_state.get("terrain_instance_id", 0)) == terrain.get_instance_id() \
		and not had_prior_cell_edit and not original_state.is_empty() \
		and not bool(original_state.get("solid", true)) \
		and String(original_state.get("fluid", "")) == expected_fluid \
		and expected_fluid == "water"
	_check("replacement_starts_from_current_receipt_and_unedited_generated_fluid_cell",
		setup_valid, {"initialReceipt":initial_receipt.get("receipt", {}),
			"oldSlot":old_identity, "nativeSnapshot":old_native,
			"voxelToolsOwner":_voxeltools_state_summary(old_voxeltools_state),
			"fluidCell":_vec3i(fluid_cell), "originalState":_cell_state_summary(original_state),
			"hadPriorCellEdit":had_prior_cell_edit})
	if not setup_valid:
		return {"status":"failed", "reason":"terrain_lifecycle_initial_state_invalid"}
	var original_durable_sections: Dictionary = volume.get("durable_delta_cells_by_section")
	var original_durable_bucket: Dictionary = original_durable_sections.get(
		volume.call("section_key_for_cell", fluid_cell), {})
	var had_prior_durable_cell := original_durable_bucket.has(fluid_cell)
	_check("fixture_cell_has_no_preexisting_durable_delta", not had_prior_durable_cell,
		{"fluidCell":_vec3i(fluid_cell), "durableBucketCount":original_durable_bucket.size()})
	if had_prior_durable_cell:
		return {"status":"failed", "reason":"terrain_lifecycle_cell_has_prior_durable_delta"}

	var altered_state: Dictionary = original_state.duplicate(true)
	altered_state["fluid"] = "lava"
	var altered_metadata: Dictionary = altered_state.get("metadata", {}).duplicate(true) \
		if altered_state.get("metadata", {}) is Dictionary else {}
	altered_metadata.erase("terrainMeshAffects")
	altered_state["metadata"] = altered_metadata
	var pre_mutation_volume_revision := int(volume.get("revision"))
	var pre_mutation_fluid_revision := int(volume.get("fluid_revision"))
	var first_mutation: Dictionary = volume.call("set_cell_state", fluid_cell,
		altered_state, "section_stage3_stale_candidate_fixture", false)
	var first_revision: Dictionary = await _wait_for_current_fluid_revision(
		old_fluid_signature, "lava")
	if first_revision.get("status") != "ready":
		var restored_after_first_failure := _restore_generated_fluid_cell(volume, fluid_cell,
			original_state)
		_check("first_fluid_revision_admits_real_replacement", false,
			{"mutation":_cell_state_summary(first_mutation), "revision":first_revision,
				"restore":restored_after_first_failure})
		return {"status":"failed", "reason":"first_fluid_revision_not_current",
			"details":first_revision}
	var staged := await _wait_for_staged_replacement(old_generation,
		String(old_native.get("packetDigest", "")))
	var staged_session: Variant = staged.get("sessionRef", null)
	var stale_candidate: Dictionary = staged.get("candidate", {})
	var stale_candidate_identity := _candidate_render_identity(stale_candidate, {})
	_check("real_replacement_candidate_reaches_native_staging_before_restore_mutation",
		staged.get("status") == "ready", _staged_replacement_summary(staged))
	if staged.get("status") != "ready":
		var restore_without_stage := _restore_generated_fluid_cell(volume, fluid_cell, original_state)
		return {"status":"failed", "reason":"replacement_never_reached_native_staging",
			"details":staged, "restore":restore_without_stage}

	var stale_generation := int(stale_candidate.get("generation", 0))
	var stale_fluid_revision := String(stale_candidate.get("sourceRevisions", {}).get(
		fluid_source_id, ""))
	var old_fluid_revision := String(old_candidate.get("sourceRevisions", {}).get(
		fluid_source_id, ""))
	var state_before_stale_mutation: Dictionary = terrain.call(
		"get_mesh_block_viewer_state", section_key)
	var slot_before_stale_mutation: Dictionary = staged.get("nativeSlot", {}).duplicate(true)
	var exact_old_coverage_still_active := _voxeltools_coverage_contains_receipt(
		state_before_stale_mutation, old_receipt)
	var restore_result := _restore_generated_fluid_cell(volume, fluid_cell, original_state)
	var current_job_after_restore: Dictionary = coordinator.get(
		"_production_candidate_jobs").get(section_key, {})
	var slot_after_stale_mutation: Dictionary = _installed_slot_snapshot(old_candidate, old_receipt)
	var state_after_stale_mutation: Dictionary = terrain.call(
		"get_mesh_block_viewer_state", section_key)
	var restored_state: Dictionary = volume.call("get_cell_state", fluid_cell)
	var durable_after_restore: Dictionary = volume.get("durable_delta_cells_by_section")
	var durable_section_after_restore: Dictionary = durable_after_restore.get(
		volume.call("section_key_for_cell", fluid_cell), {})
	var restored_without_delta: bool = not (volume.get("edited_cells") as Dictionary).has(fluid_cell) \
		and not durable_section_after_restore.has(fluid_cell) \
		and _cell_states_match_render_authority(restored_state, original_state)
	var staged_session_state := String(staged_session.get("state")) \
		if staged_session is RefCounted else "unavailable"
	var stale_session_cancelled := staged_session is RefCounted \
		and staged_session_state == "cancelled"
	var stale_cancelled: bool = current_job_after_restore.is_empty() \
		or int(current_job_after_restore.get("candidate", {}).get("generation", 0)) != stale_generation
	var old_slot_retained: bool = slot_after_stale_mutation.get("status") == "ready" \
		and int(slot_after_stale_mutation.get("generation", 0)) == old_generation \
		and String(slot_after_stale_mutation.get("packetDigest", "")) \
			== String(slot_before_stale_mutation.get("packetDigest", ""))
	var voxeltools_owner_retained: bool = bool(state_after_stale_mutation.get("present", false)) \
		and bool(state_after_stale_mutation.get("has_mesh", false)) \
		and int(state_before_stale_mutation.get("terrain_instance_id", 0)) \
			== int(old_voxeltools_state.get("terrain_instance_id", -1)) \
		and int(state_before_stale_mutation.get("owner_generation", 0)) \
			== int(old_voxeltools_state.get("owner_generation", -1)) \
		and int(state_after_stale_mutation.get("terrain_instance_id", 0)) \
			== int(state_before_stale_mutation.get("terrain_instance_id", -1)) \
		and int(state_after_stale_mutation.get("owner_generation", 0)) \
			== int(state_before_stale_mutation.get("owner_generation", -1)) \
		and int(state_after_stale_mutation.get("collision_viewers", 0)) > 0 \
		and _voxeltools_coverage_contains_receipt(state_after_stale_mutation, old_receipt)
	_check("source_revision_change_cancels_staged_candidate_and_retains_old_native_and_voxeltools_owners",
		first_mutation.get("fluid") == "lava" and restore_result.get("status") in ["ready", "restored"] \
		and stale_generation > old_generation and not stale_fluid_revision.is_empty() \
		and stale_fluid_revision != old_fluid_revision \
		and stale_cancelled and stale_session_cancelled \
		and old_slot_retained and exact_old_coverage_still_active \
		and voxeltools_owner_retained and restored_without_delta,
		{"beforeVolumeRevision":pre_mutation_volume_revision,
			"beforeFluidRevision":pre_mutation_fluid_revision,
			"afterVolumeRevision":int(volume.get("revision")),
			"afterFluidRevision":int(volume.get("fluid_revision")),
			"firstMutation":_cell_state_summary(first_mutation),
			"intermediateCurrentProof":first_revision,
			"staleCandidate":stale_candidate_identity,
			"staleCandidateFluidSourceRevision":stale_fluid_revision,
			"staleStage":staged.get("stage", ""),
			"staleSessionState":staged.get("sessionState", ""),
			"staleCancelled":stale_cancelled,
			"stagedSessionStateAfterRestore":staged_session_state,
			"stagedSessionCancelled":stale_session_cancelled,
			"oldSlotBeforeMutation":old_identity,
			"oldSlotAtStagedCandidate":_native_identity_summary(slot_before_stale_mutation),
			"oldSlotAfterMutation":_native_identity_summary(slot_after_stale_mutation),
			"voxelToolsBeforeMutation":_voxeltools_state_summary(state_before_stale_mutation),
			"voxelToolsAfterMutation":_voxeltools_state_summary(state_after_stale_mutation),
			"oldCoverageBeforeMutation":exact_old_coverage_still_active,
			"oldCoverageAfterMutation":_voxeltools_coverage_contains_receipt(
				state_after_stale_mutation, old_receipt),
			"restoredCell":_cell_state_summary(restored_state),
			"restoredWithoutDurableEdit":restored_without_delta,
			"restoreResult":restore_result})
	if not stale_cancelled or not stale_session_cancelled \
			or not old_slot_retained or not voxeltools_owner_retained \
			or not restored_without_delta:
		return {"status":"failed", "reason":"stale_candidate_retention_gate_failed"}

	var final_proof := await _wait_for_current_fluid_revision(
		String(first_revision.get("signature", "")), expected_fluid)
	if final_proof.get("status") != "ready":
		return {"status":"failed", "reason":"restored_fluid_proof_not_current",
			"details":final_proof}
	selected_fluid_signature = String(final_proof.get("signature", ""))
	var final_revision := String(terrain_runtime.call("_terrain_section_source_revision",
		section_key, final_proof))
	var final_receipt := await _wait_for_current_native_receipt(final_revision)
	var final_candidate: Dictionary = coordinator.get("_production_candidates_by_section").get(section_key, {})
	var final_receipt_value: Dictionary = coordinator.get("_production_candidate_receipts").get(section_key, {})
	var final_native: Dictionary = _native_installed_snapshot(final_candidate, final_receipt_value)
	var final_identity := _candidate_render_identity(final_candidate, final_receipt_value)
	var final_coverage_ack := await _wait_for_terrain_render_claim(terrain, final_receipt_value)
	var collision_live := _terrain_collision_is_live(terrain)
	var newer_receipt: bool = final_receipt.get("status") == "ready" \
		and int(final_candidate.get("generation", 0)) > old_generation \
		and int(final_candidate.get("generation", 0)) > stale_generation \
		and final_native.get("status") == "ready" \
		and int(final_native.get("generation", 0)) == int(final_candidate.get("generation", 0)) \
		and String(final_native.get("packetDigest", "")) \
			== String(final_receipt_value.get("contentManifestDigest", "")) \
		and String(final_candidate.get("sourceRevisions", {}).get(fluid_source_id, "")) \
			== final_revision and final_coverage_ack.get("status") == "acknowledged"
	_check("restored_source_retries_to_new_current_native_receipt_with_collision_authority_live",
		newer_receipt and collision_live, {
			"staleGeneration":stale_generation, "oldGeneration":old_generation,
			"finalReceipt":final_receipt.get("receipt", {}),
			"finalCandidate":final_identity,
			"finalNativeSnapshot":_native_identity_summary(final_native),
			"finalFluidRevision":final_revision,
			"finalVoxelToolsCoverage":final_coverage_ack,
			"collisionAuthority":_terrain_collision_summary(terrain),
			"collisionLive":collision_live,
			"positivePhysicsHit":_positive_terrain_physics_hit(terrain)})
	if newer_receipt:
		final_receipt["lifecycleEvidence"] = {
			"oldSlot":old_identity, "staleCandidate":stale_candidate_identity,
			"finalSlot":final_identity,
			"sourceMutationAndRestore": {"beforeVolumeRevision":pre_mutation_volume_revision,
				"beforeFluidRevision":pre_mutation_fluid_revision,
				"afterVolumeRevision":int(volume.get("revision")),
				"afterFluidRevision":int(volume.get("fluid_revision")),
				"restoredWithoutDurableEdit":restored_without_delta},
			"staleCandidateCancelled":stale_cancelled,
			"oldNativeSlotRetained":old_slot_retained,
			"oldVoxelToolsClaimRetained":voxeltools_owner_retained,
			"newVoxelToolsClaimAcknowledged":final_coverage_ack.get("status") == "acknowledged",
			"collisionAuthorityLive":collision_live,
			"positivePhysicsHit":_positive_terrain_physics_hit(terrain)}
		return final_receipt
	return {"status":"failed",
		"reason":"fresh_receipt_or_collision_authority_missing",
		"finalReceipt":final_receipt, "collisionLive":collision_live,
		"lifecycleEvidence":{"oldSlot":old_identity,
			"staleCandidate":stale_candidate_identity, "finalSlot":final_identity}}


func _wait_for_current_fluid_revision(previous_signature: String,
		expected_fluid: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 90000
	var last: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		var proof: Dictionary = terrain_runtime.get("terrain_section_fluid_proofs").get(section_key, {})
		if bool(terrain_runtime.call("_terrain_section_fluid_proof_is_current", section_key, proof)) \
				and String(proof.get("signature", "")) != previous_signature \
				and bool(proof.get("hasFluid", false)):
			var state: Dictionary = main.get("world_generation_system").call(
				"sample_cell", sample.get("fluidCell", Vector3i.ZERO))
			if String(state.get("fluid", "")) == expected_fluid:
				return {"status":"ready", "signature":String(proof.get("signature", "")),
					"fluidRevision":int(proof.get("fluidRevision", -1)),
					"volumeRevision":int(proof.get("volumeRevision", -1)),
					"proof":_proof_summary(proof)}
		last = {"proof":_proof_summary(proof),
			"proofCurrent":bool(terrain_runtime.call(
				"_terrain_section_fluid_proof_is_current", section_key, proof)),
			"expectedFluid":expected_fluid,
			"sample":main.get("world_generation_system").call(
				"sample_cell", sample.get("fluidCell", Vector3i.ZERO))}
		if Engine.get_process_frames() % 120 == 0:
			_write_progress("waiting_for_fluid_revision_transition", last)
		await process_frame
	return {"status":"pending", "reason":"current_fluid_revision_transition_timeout",
		"expectedFluid":expected_fluid, "last":last}


func _wait_for_staged_replacement(after_generation: int,
		expected_old_digest: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 120000
	var last: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		var job: Dictionary = coordinator.get("_production_candidate_jobs").get(section_key, {})
		var candidate: Dictionary = job.get("candidate", {})
		var session: Variant = job.get("session", null)
		var session_state := String(session.get("state")) if session is RefCounted else ""
		var generation := int(candidate.get("generation", 0))
		var native_still_old := _installed_slot_snapshot(
			coordinator.get("_production_candidates_by_section").get(section_key, {}),
			coordinator.get("_production_candidate_receipts").get(section_key, {}))
		last = {"candidateGeneration":generation, "stage":String(job.get("stage", "")),
			"sessionState":session_state, "candidateDigest":String(candidate.get("contentManifestDigest", "")),
			"candidateFluidRevision":String(candidate.get("sourceRevisions", {}).get(fluid_source_id, "")),
			"nativeSlot":_native_identity_summary(native_still_old)}
		if generation > after_generation and session_state in ["append", "upload", "commit"] \
				and int(native_still_old.get("generation", 0)) == after_generation \
				and String(native_still_old.get("packetDigest", "")) == expected_old_digest:
			return {"status":"ready", "candidate":candidate, "stage":String(job.get("stage", "")),
				"sessionState":session_state, "nativeSlot":native_still_old,
				"sessionRef":session}
		if Engine.get_process_frames() % 120 == 0:
			_write_progress("waiting_for_native_replacement_stage", last)
		await process_frame
	return {"status":"pending", "reason":"replacement_candidate_not_staged_before_timeout",
		"last":last}


func _staged_replacement_summary(staged: Dictionary) -> Dictionary:
	return {"status":String(staged.get("status", "")),
		"reason":String(staged.get("reason", "")),
		"stage":String(staged.get("stage", "")),
		"sessionState":String(staged.get("sessionState", "")),
		"nativeSlot":_native_identity_summary(staged.get("nativeSlot", {})),
		"candidate":_candidate_render_identity(staged.get("candidate", {}), {})}


func _restore_generated_fluid_cell(volume: Object, fluid_cell: Vector3i,
		original_state: Dictionary) -> Dictionary:
	if not is_instance_valid(volume) or not volume.has_method("clear_cell_state"):
		return {"status":"failed", "reason":"terrain_volume_clear_api_unavailable"}
	volume.call("clear_cell_state", fluid_cell, "section_stage3_fixture_restore")
	var restored: Dictionary = volume.call("get_cell_state", fluid_cell)
	var edited: Dictionary = volume.get("edited_cells")
	var durable: Dictionary = volume.get("durable_delta_cells_by_section")
	var durable_bucket: Dictionary = durable.get(volume.call(
		"section_key_for_cell", fluid_cell), {})
	var no_fixture_delta: bool = not edited.has(fluid_cell) and not durable_bucket.has(fluid_cell) \
		and _cell_states_match_render_authority(restored, original_state)
	return {"status":"restored" if no_fixture_delta else "failed",
		"state":_cell_state_summary(restored), "original":_cell_state_summary(original_state),
		"fixtureDeltaPresent":edited.has(fluid_cell) or durable_bucket.has(fluid_cell)}


func _cell_states_match_render_authority(a: Dictionary, b: Dictionary) -> bool:
	return a == b


func _candidate_render_identity(candidate: Dictionary, receipt: Dictionary) -> Dictionary:
	var envelope: Dictionary = candidate.get("candidate", {})
	var snapshot: Dictionary = envelope.get("snapshot", {})
	var batch_rows: Array[Dictionary] = []
	for batch_value: Variant in snapshot.get("batches", {}).values():
		if not batch_value is Dictionary:
			continue
		var batch: Dictionary = batch_value
		var segment_rows: Array[Dictionary] = []
		for segment_value: Variant in batch.get("segments", []):
			if not segment_value is Dictionary:
				continue
			var bounds_value: Variant = segment_value.get("bounds", AABB())
			var bounds: AABB = bounds_value if bounds_value is AABB else AABB()
			segment_rows.append({"segmentId":String(segment_value.get("segmentId", "")),
				"sourcePartId":String(segment_value.get("sourcePartId", "")),
				"sourceRevision":String(segment_value.get("sourceRevision", "")),
				"localBounds":_aabb_summary(bounds)})
		batch_rows.append({"layer":String(batch.get("renderLayer", "")),
			"batchId":String(batch.get("batchId", "")),
			"meshContentDigest":String(batch.get("meshContentDigest", "")),
			"segments":segment_rows})
	return {"sectionKey":_vec3i(candidate.get("sectionKey", section_key)),
		"generation":int(candidate.get("generation", 0)),
		"sourceRevision":String(receipt.get("sourceRevision", candidate.get("sourceRevision", ""))),
		"contentManifestDigest":String(candidate.get("contentManifestDigest", "")),
		"receiptDigest":String(receipt.get("contentManifestDigest", "")),
		"sectionWorldTransform":{"basis":"identity", "origin":_vec3(SectionGrid.origin_for_key(section_key))},
		"batches":batch_rows}


func _installed_slot_snapshot(candidate: Dictionary, receipt: Dictionary) -> Dictionary:
	var owner_cell: Variant = receipt.get("ownerCell", Vector2i.ZERO)
	var resolved: Dictionary = main.call("get_static_section_render_owner", owner_cell, false)
	if resolved.get("status") != "ready":
		return {"status":"pending", "reason":String(resolved.get("reason", "native_section_owner_pending"))}
	var backend: Object = resolved.get("backend") as Object
	if not is_instance_valid(backend) or not backend.has_method("installed_snapshot"):
		return {"status":"pending", "reason":"native_section_backend_snapshot_unavailable"}
	var source_id := String(InstallSession.slot_id(String(candidate.get("worldId", "")), section_key))
	return backend.call("installed_snapshot", source_id)


func _wait_for_terrain_render_claim(terrain: Object, receipt: Dictionary) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 15000
	var last: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		var state: Dictionary = terrain.call("get_mesh_block_viewer_state", section_key)
		last = _voxeltools_state_summary(state)
		if _voxeltools_coverage_contains_receipt(state, receipt):
			return {"status":"acknowledged", "state":last,
				"receipt":_receipt_summary(receipt)}
		await process_frame
	return {"status":"pending", "reason":"voxeltools_render_coverage_receipt_not_acknowledged",
		"state":last, "receipt":_receipt_summary(receipt)}


func _voxeltools_coverage_contains_receipt(state: Dictionary, receipt: Dictionary) -> bool:
	var claims: Variant = state.get("render_coverage_claims", null)
	if not claims is Array:
		return false
	var world_id := String(receipt.get("worldId", ""))
	var generation := int(receipt.get("generation", 0))
	var digest := String(receipt.get("contentManifestDigest", ""))
	for claim_value: Variant in claims:
		if not claim_value is Dictionary:
			continue
		var claim: Dictionary = claim_value
		if String(claim.get("worldId", "")) == world_id \
				and int(claim.get("sectionGeneration", 0)) == generation \
				and String(claim.get("receiptDigest", "")) == digest \
				and claim.get("sectionKey") == section_key:
			return true
	return false


func _voxeltools_state_summary(state: Dictionary) -> Dictionary:
	return {"present":bool(state.get("present", false)),
		"hasMesh":bool(state.get("has_mesh", false)),
		"isVisible":bool(state.get("is_visible", false)),
		"terrainInstanceId":int(state.get("terrain_instance_id", 0)),
		"ownerGeneration":int(state.get("owner_generation", 0)),
		"renderCoverageRevision":int(state.get("render_coverage_revision", -1)),
		"renderCoverageComplete":bool(state.get("render_coverage_complete", false)),
		"renderViewerCount":int(state.get("render_viewers", 0)),
		"collisionViewerCount":int(state.get("collision_viewers", 0)),
		"claimCount":(state.get("render_coverage_claims", []) as Array).size() \
			if state.get("render_coverage_claims", []) is Array else -1}


func _native_identity_summary(snapshot: Dictionary) -> Dictionary:
	return {"status":String(snapshot.get("status", "")),
		"generation":int(snapshot.get("generation", 0)),
		"sourceRevision":String(snapshot.get("sourceRevision", "")),
		"packetDigest":String(snapshot.get("packetDigest", "")),
		"layers":snapshot.get("layers", [])}


func _terrain_collision_is_live(terrain: Object) -> bool:
	var collision_state: Dictionary = terrain.call("get_mesh_block_viewer_state", section_key) \
		if is_instance_valid(terrain) and terrain.has_method("get_mesh_block_viewer_state") else {}
	var local_current: bool = bool(terrain_runtime.call("_local_collision_identity_current"))
	var local_mesh: Dictionary = terrain_runtime.call(
		"collision_mesh_ready_for_body_position", initial_player_position, 0.42) \
		if is_instance_valid(terrain_runtime) else {}
	return local_current and bool(local_mesh.get("passed", false)) \
		and int(collision_state.get("collision_viewers", 0)) > 0 \
		and int(collision_state.get("terrain_instance_id", 0)) == terrain.get_instance_id()


func _terrain_collision_summary(terrain: Object) -> Dictionary:
	var state: Dictionary = terrain.call("get_mesh_block_viewer_state", section_key) \
		if is_instance_valid(terrain) and terrain.has_method("get_mesh_block_viewer_state") else {}
	return {"localIdentityCurrent":bool(terrain_runtime.call("_local_collision_identity_current")),
		"collisionMeshReadyAtInitialSpawn":terrain_runtime.call(
			"collision_mesh_ready_for_body_position", initial_player_position, 0.42),
		"voxelToolsOwner":_voxeltools_state_summary(state)}


func _positive_terrain_physics_hit(terrain: Object) -> Dictionary:
	if not is_instance_valid(terrain):
		return {"hit":false, "reason":"terrain_owner_missing"}
	var space := root.get_world_3d().direct_space_state
	for offset in [Vector3.ZERO, Vector3.RIGHT * 2.0, Vector3.LEFT * 2.0,
		Vector3.FORWARD * 2.0, Vector3.BACK * 2.0]:
		var origin: Vector3 = initial_player_position + offset + Vector3.UP * 5.0
		var target: Vector3 = origin - Vector3.UP * 32.0
		var query := PhysicsRayQueryParameters3D.create(origin, target, 0xFFFFFFFF)
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if not hit.is_empty() and hit.get("collider") == terrain:
			return {"hit":true, "position":_vec3(hit.get("position", Vector3.ZERO)),
				"offset":_vec3(offset), "terrainInstanceId":terrain.get_instance_id()}
	return {"hit":false, "reason":"no_positive_voxelterrain_ray_hit_at_initial_spawn"}


func _cell_state_summary(state: Dictionary) -> Dictionary:
	return {"cell":_vec3i(state.get("cell", Vector3i.ZERO)),
		"sectionKey":_vec3i(state.get("sectionKey", Vector3i.ZERO)),
		"localCell":_vec3i(state.get("localCell", Vector3i.ZERO)),
		"blockId":String(state.get("blockId", "")),
		"biome":String(state.get("biome", "")),
		"solid":bool(state.get("solid", false)),
		"fluid":String(state.get("fluid", "")),
		"material":String(state.get("material", "")),
		"density":float(state.get("density", 0.0)),
		"light":state.get("light", {}).duplicate(true) \
			if state.get("light", {}) is Dictionary else {},
		"metadata":state.get("metadata", {}).duplicate(true) \
			if state.get("metadata", {}) is Dictionary else {},
		"generated":bool(state.get("generated", false)),
		"edited":bool(state.get("edited", false))}


func _aabb_summary(bounds: AABB) -> Dictionary:
	return {"position":_vec3(bounds.position), "size":_vec3(bounds.size)}


func _inspect_installed_candidate(candidate: Dictionary, receipt: Dictionary,
		exact_revision: String) -> Dictionary:
	var envelope: Dictionary = candidate.get("candidate", {})
	var snapshot: Dictionary = envelope.get("snapshot", {})
	var batches: Dictionary = snapshot.get("batches", {})
	var source_revisions: Dictionary = candidate.get("sourceRevisions", {})
	var current_pov: Dictionary = coordinator.call("current_translucent_pov_snapshot", section_key)
	var matching_translucent: Array[Dictionary] = []
	for batch_value: Variant in batches.values():
		if batch_value is Dictionary and String(batch_value.get("renderLayer", "")) == "translucent":
			matching_translucent.append(batch_value)
	var descriptors: Array[Dictionary] = []
	var exact_fluid_segment_count := 0
	var exact_fluid_descriptor_batch_count := 0
	var batches_match_mesh := false
	var all_translucent_descriptors_valid := true
	var pov_revision := -1
	for batch: Dictionary in matching_translucent:
		var descriptor: Dictionary = batch.get("translucentSortDescriptor", {})
		var mesh_digest := String(batch.get("meshContentDigest", ""))
		var descriptor_pov := int(descriptor.get("povRevision", -1))
		var descriptor_camera: Variant = descriptor.get("cameraPosition", null)
		var descriptor_camera_world := SectionGrid.origin_for_key(section_key) \
			+ (descriptor_camera as Vector3) * CELL if descriptor_camera is Vector3 else Vector3.ZERO
		var descriptor_camera_section := SectionGrid.key_for_world_position(descriptor_camera_world)
		var descriptor_pov_class := _relative_pov_class(descriptor_camera_section, section_key)
		var current_pov_class: Variant = current_pov.get("povClass", null)
		var descriptor_matches_current_pov: bool = String(current_pov.get("status", "")) == "ready" \
			and current_pov_class is Vector3i \
			and descriptor_pov_class == Vector3i(current_pov_class)
		var descriptor_valid: bool = String(descriptor.get("schema", "")) == "section-translucent-face-groups/v1" \
			and descriptor.get("sectionKey") == section_key and descriptor_pov > 0 \
			and descriptor.get("cameraPosition") is Vector3 \
			and descriptor_matches_current_pov \
			and String(descriptor.get("meshContentDigest", "")) == mesh_digest \
			and String(batch.get("transparencySortPolicy", "")) == "camera_depth"
		all_translucent_descriptors_valid = all_translucent_descriptors_valid and descriptor_valid
		var batch_fluid_segment_count := 0
		for segment_value: Variant in batch.get("segments", []):
			if segment_value is Dictionary \
					and String(segment_value.get("sourcePartId", "")) == fluid_source_id \
					and String(segment_value.get("sourceRevision", "")) == exact_revision:
				exact_fluid_segment_count += 1
				batch_fluid_segment_count += 1
		if not descriptor.is_empty():
			descriptors.append({"schema":descriptor.get("schema", ""),
				"sectionKey":_vec3i(descriptor.get("sectionKey", Vector3i.ZERO)),
				"povRevision":descriptor_pov,
				"meshContentDigest":String(descriptor.get("meshContentDigest", "")),
				"meshDigestMatches":String(descriptor.get("meshContentDigest", "")) == mesh_digest,
				"exactFluidSourceSegmentCount":batch_fluid_segment_count,
				"cameraPositionMatchesCurrentPovClass":descriptor_matches_current_pov,
				"descriptorPovClass":_vec3i(descriptor_pov_class),
				"sortPolicy":String(batch.get("transparencySortPolicy", ""))})
			batches_match_mesh = batches_match_mesh or String(descriptor.get("meshContentDigest", "")) == mesh_digest
			if String(descriptor.get("meshContentDigest", "")) == mesh_digest \
					and batch_fluid_segment_count > 0:
				exact_fluid_descriptor_batch_count += 1
			if pov_revision <= 0:
				pov_revision = descriptor_pov
			elif pov_revision != descriptor_pov:
				all_translucent_descriptors_valid = false
	var receipt_current: bool = bool(coordinator.call(
		"installed_section_receipt_is_current", section_key, receipt))
	var current_census: Dictionary = coordinator.call("capture_authoritative_source_census", [section_key])
	var native := _native_installed_snapshot(candidate, receipt)
	var native_layers: Array = native.get("layers", [])
	var native_translucent: Dictionary = {}
	for layer_value: Variant in native_layers:
		if layer_value is Dictionary and String(layer_value.get("layer", "")) == "translucent":
			native_translucent = layer_value
	var exact_fluid_revision := String(source_revisions.get(fluid_source_id, "")) == exact_revision
	var receipt_fluid_revision := String(receipt.get("sourceRevisions", {}).get(fluid_source_id, ""))
	var receipt_binds_exact_fluid := receipt_fluid_revision == exact_revision
	var census_source_revisions: Dictionary = current_census.get("sourceRevisions", {})
	var census_source_providers: Dictionary = current_census.get("sourceProviderIds", {})
	var census_is_current: bool = current_census.get("status") == "complete" \
		and String(current_census.get("censusDigest", "")) == String(candidate.get("censusDigest", "")) \
		and String(census_source_revisions.get(fluid_source_id, "")) == exact_revision \
		and String(census_source_providers.get(fluid_source_id, "")) == "terrain"
	var current_proof: Dictionary = terrain_runtime.get("terrain_section_fluid_proofs").get(section_key, {})
	var proof_still_current: bool = bool(terrain_runtime.call(
		"_terrain_section_fluid_proof_is_current", section_key, current_proof)) \
		and bool(current_proof.get("hasFluid", false)) \
			and String(current_proof.get("signature", "")) == selected_fluid_signature
	var descriptor_current: bool = current_pov.get("status") == "ready" \
		and int(current_pov.get("revision", -1)) == pov_revision \
		and int(receipt.get("translucentPovRevision", -1)) == pov_revision \
		and batches_match_mesh and all_translucent_descriptors_valid \
		and descriptors.size() == matching_translucent.size()
	var success: bool = receipt_current and census_is_current and exact_fluid_revision and proof_still_current \
		and receipt_binds_exact_fluid \
		and not matching_translucent.is_empty() and exact_fluid_segment_count > 0 \
		and exact_fluid_descriptor_batch_count > 0 and descriptor_current \
		and native.get("status") == "ready" \
		and String(native_translucent.get("status", "")) == "ready" \
		and int(native_translucent.get("expectedBatchCount", 0)) > 0 \
		and int(native_translucent.get("installedBatchCount", -1)) \
			== int(native_translucent.get("expectedBatchCount", 0)) \
		and int(native_translucent.get("installedInstanceCount", 0)) > 0 \
		and String(native.get("sourceRevision", "")) == String(receipt.get("sourceRevision", "")) \
		and String(native.get("packetDigest", "")) == String(receipt.get("contentManifestDigest", ""))
	return {"status":"ready" if success else "pending",
		"sectionKey":_vec3i(section_key), "worldId":String(candidate.get("worldId", "")),
		"generation":int(candidate.get("generation", 0)),
		"candidateSchema":String(candidate.get("schema", "")),
		"receiptCurrent":receipt_current, "receipt":_receipt_summary(receipt),
		"currentCensusStatus":String(current_census.get("status", "")),
		"currentCensusDigestMatches":String(current_census.get("censusDigest", "")) \
			== String(candidate.get("censusDigest", "")),
		"currentCensusFluidSourceRevision":String(census_source_revisions.get(fluid_source_id, "")),
		"currentCensusFluidProvider":String(census_source_providers.get(fluid_source_id, "")),
		"currentCensusMatchesCandidate":census_is_current,
		"exactFluidSourceId":fluid_source_id, "exactFluidRevision":exact_revision,
		"candidateFluidSourceRevision":String(source_revisions.get(fluid_source_id, "")),
		"exactFluidSourceRevisionMatches":exact_fluid_revision,
		"receiptFluidSourceRevision":receipt_fluid_revision,
		"receiptBindsExactFluidSourceRevision":receipt_binds_exact_fluid,
		"fluidProofStillCurrent":proof_still_current,
		"translucentBatchCount":matching_translucent.size(),
		"exactFluidRevisionTranslucentSegmentCount":exact_fluid_segment_count,
		"translucentBatchesWithExactFluidSegmentAndPovDescriptor":exact_fluid_descriptor_batch_count,
		"translucentDescriptors":descriptors, "currentPov":_pov_summary(current_pov),
		"allTranslucentDescriptorsValid":all_translucent_descriptors_valid,
		"nativeSnapshot":native, "nativeTranslucentLayer":native_translucent,
		"success":success,
		"reason":"waiting_for_exact_revision_receipt_layer_or_pov" if not success else ""}


func _native_installed_snapshot(candidate: Dictionary, receipt: Dictionary) -> Dictionary:
	var owner_cell: Variant = receipt.get("ownerCell", Vector2i.ZERO)
	var resolved: Dictionary = main.call("get_static_section_render_owner", owner_cell, false)
	if resolved.get("status") != "ready":
		return {"status":"pending", "reason":String(resolved.get("reason", "native_section_owner_pending"))}
	var backend: Object = resolved.get("backend") as Object
	if not is_instance_valid(backend) or not backend.has_method("installed_snapshot"):
		return {"status":"pending", "reason":"native_section_backend_snapshot_unavailable"}
	var source_id := String(InstallSession.slot_id(String(candidate.get("worldId", "")), section_key))
	var snapshot: Dictionary = backend.call("installed_snapshot", source_id)
	if snapshot.get("status") != "ready" \
			or int(snapshot.get("generation", -1)) != int(candidate.get("generation", 0)):
		return {"status":"pending", "reason":"native_section_slot_generation_not_current",
			"snapshot":snapshot}
	return snapshot


func _capture_and_check_live_comparison(candidate_report: Dictionary) -> void:
	await process_frame
	var fluid_cell: Vector3i = sample.get("fluidCell", Vector3i.ZERO)
	var camera_cell: Vector3i = sample.get("cameraCell", fluid_cell + Vector3i.FORWARD * 2)
	var eye := _cell_center(camera_cell)
	diagnostic_camera.global_position = eye
	_look_at_sample(eye, _cell_center(fluid_cell))
	observer_light.global_position = eye
	if is_instance_valid(player):
		player.global_position = eye
		player.velocity = Vector3.ZERO
	for _frame in range(5):
		await process_frame
	var legacy_key: Vector2i = main.call("cell_to_chunk", fluid_cell.x, fluid_cell.z)
	var chunk: Node = main.get("chunks").get(legacy_key)
	var legacy: MeshInstance3D = chunk.get_node_or_null("TerrainFluidMesh") as MeshInstance3D \
		if is_instance_valid(chunk) else null
	var legacy_same := is_instance_valid(legacy) \
		and legacy.get_instance_id() == legacy_visual_instance_id \
		and legacy.is_visible_in_tree() and legacy.mesh != null
	var legacy_live := is_instance_valid(legacy) and legacy.is_visible_in_tree() \
		and legacy.mesh != null and legacy.mesh.get_surface_count() > 0
	var camera_origin := diagnostic_camera.global_position
	var ray_target := _cell_center(fluid_cell)
	var query := PhysicsRayQueryParameters3D.create(camera_origin, ray_target, 0xFFFFFFFF)
	query.collide_with_areas = false
	var hit := diagnostic_camera.get_world_3d().direct_space_state.intersect_ray(query)
	var ray := {"hit":not hit.is_empty(),
		"position":_vec3(hit.get("position", Vector3.ZERO)) if not hit.is_empty() else {},
		"collider":str(hit.get("collider", "")) if not hit.is_empty() else ""}
	var terrain_instance_id := int(terrain_runtime.get("terrain").get_instance_id()) \
		if is_instance_valid(terrain_runtime.get("terrain")) else 0
	var image := root.get_viewport().get_texture().get_image()
	var image_error := image.save_png(screenshot_path) if not screenshot_path.is_empty() else ERR_INVALID_PARAMETER
	_check("voxeltools_fluid_comparison_and_collision_authorities_remain_live",
		legacy_live and terrain_instance_id > 0 and not bool(ray.get("hit", false)) \
		and int(candidate_report.get("nativeTranslucentLayer", {}).get("installedInstanceCount", 0)) > 0, {
		"legacyVisualLive":legacy_live,
		"legacyVisualSameInstanceAsBeforeRevisionMutation":legacy_same,
		"legacyVisualInstanceId":legacy.get_instance_id() if is_instance_valid(legacy) else 0,
		"expectedLegacyVisualInstanceId":legacy_visual_instance_id,
		"terrainInstanceId":terrain_instance_id, "collisionRay":ray,
		"candidateNativeTranslucentLayer":candidate_report.get("nativeTranslucentLayer", {})})
	_check("fluid_section_native_receipt_screenshot_saved",
		image_error == OK and FileAccess.file_exists(screenshot_path), {
		"path":screenshot_path, "error":image_error,
		"cameraPosition":_vec3(eye), "sample":_sample_summary(sample)})


func _cell_center(cell: Vector3i) -> Vector3:
	return (Vector3(cell) + Vector3.ONE * 0.5) * CELL


func _look_at_sample(from: Vector3, to: Vector3) -> void:
	var direction := (to - from).normalized()
	var up := Vector3.FORWARD if absf(direction.dot(Vector3.UP)) > 0.92 else Vector3.UP
	diagnostic_camera.look_at(to, up)


func _relative_pov_class(camera_section: Vector3i, target_section: Vector3i) -> Vector3i:
	return Vector3i(clampi(camera_section.x - target_section.x, -1, 1),
		clampi(camera_section.y - target_section.y, -1, 1),
		clampi(camera_section.z - target_section.z, -1, 1))


func _check(name: String, passed: bool, details: Variant) -> void:
	var row := {"name":name, "passed":passed, "details":details}
	checks.append(row)
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, JSON.stringify(details)])


func _trace(event: String, data: Dictionary = {}) -> void:
	timeline.append({"event":event, "elapsedMsec":Time.get_ticks_msec() - started_msec,
		"data":data})


func _write_progress(stage: String, data: Dictionary = {}) -> void:
	if progress_path.is_empty():
		return
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"stage":stage,
			"elapsedMsec":Time.get_ticks_msec() - started_msec,
			"sectionKey":_vec3i(section_key), "details":data}, "  "))
		file.close()


func _finish() -> void:
	if finished:
		return
	finished = true
	var passed := true
	for row: Dictionary in checks:
		passed = passed and bool(row.get("passed", false))
	var report := {"schema":REPORT_SCHEMA, "passed":passed,
		"checkCount":checks.size(), "checks":checks, "seed":seed_text,
		"worldId":"seed:%s:%d" % [String(main.get("seed_text")) if is_instance_valid(main) else "",
			int(main.get("seed_hash")) if is_instance_valid(main) else 0],
		"sample":_sample_summary(sample), "sectionKey":_vec3i(section_key),
		"fluidSourceId":fluid_source_id,
		"evidenceLevel":"headed_real_main_terrain_census_contribution_coordinator_native_receipt",
		"mode":"single generated exposed-water sample; diagnostic teleport; legacy visuals and VoxelTools collision remain active",
		"replacementLifecycle":replacement_lifecycle_evidence,
		"startupScope":"real Main startup awaited; sample location reached by teleport after startup",
		"gameplayAcceptance":false,
		"doesNotProve":["ordinary spawn flow or traversal", "terrain collision parity or retirement",
			"fluid visual parity or old-path retirement", "terrain edit/save/reload behavior",
			"player-facing gameplay readiness", "streaming performance"],
		"startupFailure":startup_failure,
		"startupReadinessDomainsAtFailure":startup_failure.get(
			"readinessDomainsAtWaitEnd", {}),
		"startupLoadingStateAtFailure":startup_failure.get(
			"loadingStateAtWaitEnd", {}),
		"sourceCaptureSchedulerAtFailure":startup_failure.get(
			"sourceCaptureSchedulerAtWaitEnd", {}),
		"startupReadinessMetrics":startup_failure.get("metrics", {}),
		"sectionCompilerAtStartupFailure":startup_failure.get("sectionCompiler", {}),
		"timeline":timeline,
		"screenshot":screenshot_path}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	_write_progress("finished", {"passed":passed, "reason":report.get("reason", ""),
		"startupFailure":startup_failure,
		"captureHandshake":"waiting_for_run_bound_screenshot_ack",
		"screenshotPath":screenshot_path})
	await _wait_for_final_screenshot_ack(passed)
	if is_instance_valid(main) and main.has_method("request_graceful_quit"):
		main.request_graceful_quit(0 if passed else 1)
	else:
		quit(0 if passed else 1)


func _wait_for_final_screenshot_ack(passed: bool) -> void:
	var ack_path := OS.get_environment("VOXEL_AUTOMATED_TEST_FINAL_CAPTURE_ACK").strip_edges()
	if ack_path.is_empty() or OS.get_environment("VOXEL_AUTOMATED_TEST") != "1":
		return
	var expected_run_id := OS.get_environment("VOXEL_AUTOMATED_TEST_RUN_ID").strip_edges()
	while true:
		if FileAccess.file_exists(ack_path):
			var file := FileAccess.open(ack_path, FileAccess.READ)
			if file != null:
				var ack: Variant = JSON.parse_string(file.get_as_text())
				file.close()
				var expected_checkpoint := "test-success" if passed else "test-failure"
				if ack is Dictionary and ack.get("schema") == "headed-test-capture-ack/v1" \
						and ack.get("runId") == expected_run_id \
						and ack.get("checkpoint") == expected_checkpoint \
						and ack.get("accepted") == passed:
					return
		await process_frame


func _on_startup_failed(message: String) -> void:
	startup_failure_signal_message = message
	startup_failure = {"signalMessage":message}


func _startup_readiness_domains() -> Dictionary:
	if not is_instance_valid(main):
		return {"status":"unavailable", "reason":"main_unavailable"}
	var domains_value: Variant = main.get("startup_readiness_domains")
	if not domains_value is Dictionary:
		return {"status":"unavailable", "reason":"startup_readiness_domains_missing"}
	return {"status":"ready", "domains":(domains_value as Dictionary).duplicate(true)}


func _startup_loading_state() -> Dictionary:
	if not is_instance_valid(main):
		return {"status":"unavailable", "reason":"main_unavailable"}
	var failure_value: Variant = main.get("startup_loading_failure_result")
	return {"status":"ready",
		"startupLoadingActive":bool(main.get("startup_loading_active")),
		"runtimeLoadingActive":bool(main.get("runtime_loading_active")),
		"startupOperationActive":bool(main.get("startup_operation_active")),
		"startupFailureReason":String((failure_value as Dictionary).get("reason", "")) \
			if failure_value is Dictionary else ""}


func _startup_source_capture_progress() -> Dictionary:
	if not is_instance_valid(main):
		return {"status":"unavailable", "reason":"main_unavailable"}
	var provider_value: Variant = main.get("ecology_static_section_provider")
	if not provider_value is Object or not is_instance_valid(provider_value) \
			or not (provider_value as Object).has_method("source_capture_scheduler_snapshot"):
		return {"status":"unavailable", "reason":"ecology_source_capture_scheduler_missing"}
	var snapshot_value: Variant = (provider_value as Object).call(
		"source_capture_scheduler_snapshot")
	if not snapshot_value is Dictionary:
		return {"status":"unavailable", "reason":"ecology_source_capture_scheduler_invalid"}
	var snapshot: Dictionary = snapshot_value
	return {"status":"ready",
		"schema":String(snapshot.get("schema", "")),
		"activeCohortCount":int(snapshot.get("activeCohortCount", 0)),
		"deferredCohortCount":int(snapshot.get("deferredCohortCount", 0)),
		"blockedCohortCount":int(snapshot.get("blockedCohortCount", 0)),
		"pendingSourceJobCount":int(snapshot.get("pendingSourceJobCount", 0)),
		"queuedSourceJobCount":int(snapshot.get("queuedSourceJobCount", 0)),
		"activeSourceJobCount":int(snapshot.get("activeSourceJobCount", 0)),
		"deferredSourceJobCount":int(snapshot.get("deferredSourceJobCount", 0)),
		"blockedSamples":_source_capture_rows_summary(snapshot.get("blocked", [])),
		"activeSamples":_source_capture_rows_summary(snapshot.get("active", [])),
		"preparingSamples":_source_capture_rows_summary(snapshot.get("preparing", [])),
		"deferredSamples":_source_capture_rows_summary(snapshot.get("deferred", []))}


func _source_capture_rows_summary(value: Variant) -> Array[Dictionary]:
	var summaries: Array[Dictionary] = []
	if not value is Array:
		return summaries
	for row_value: Variant in value:
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		summaries.append({"sectionKey":str(row.get("sectionKey", "")),
			"cohortId":String(row.get("cohortId", "")),
			"status":String(row.get("status", "")),
			"blockedReason":String(row.get("blockedReason", "")),
			"preparationStage":String(row.get("preparationStage", "")),
			"preparationPendingReason":String(row.get("preparationPendingReason", "")),
			"waitOpportunities":int(row.get("waitOpportunities", 0)),
			"sourceJobCount":int(row.get("sourceJobCount", 0))})
		if summaries.size() >= 8:
			break
	return summaries


func _startup_section_compiler_progress() -> Dictionary:
	if is_instance_valid(main):
		var failure_value: Variant = main.get("startup_loading_failure_result")
		if failure_value is Dictionary:
			var metrics: Variant = (failure_value as Dictionary).get("metrics", {})
			if metrics is Dictionary:
				var pending_tree_candidates: Variant = (metrics as Dictionary).get("pendingVisualTreeCandidates", {})
				if pending_tree_candidates is Dictionary:
					var compiler: Variant = (pending_tree_candidates as Dictionary).get("sectionCompiler", {})
					if compiler is Dictionary and not (compiler as Dictionary).is_empty():
						return (compiler as Dictionary).duplicate(true)
				var structure_visual: Variant = (metrics as Dictionary).get("structureVisual", {})
				if structure_visual is Dictionary:
					var structure_compiler: Variant = (structure_visual as Dictionary).get("sectionCompiler", {})
					if structure_compiler is Dictionary and not (structure_compiler as Dictionary).is_empty():
						return (structure_compiler as Dictionary).duplicate(true)
		var queue_value: Variant = main.get("tree_publication_queue")
		if queue_value is Object and is_instance_valid(queue_value) \
				and (queue_value as Object).has_method("startup_tree_section_compile_diagnostics"):
			var diagnostics: Variant = (queue_value as Object).call(
				"startup_tree_section_compile_diagnostics")
			if diagnostics is Dictionary:
				return (diagnostics as Dictionary).duplicate(true)
	return {"status":"unavailable", "reason":"tree_section_compiler_progress_unavailable"}


func _startup_terrain_fluid_progress() -> Dictionary:
	if not is_instance_valid(main):
		return {"status":"unavailable", "reason":"main_unavailable"}
	var runtime_value: Variant = main.get("voxel_terrain_runtime")
	if not runtime_value is Object or not is_instance_valid(runtime_value):
		return {"status":"unavailable", "reason":"terrain_runtime_unavailable"}
	var runtime: Object = runtime_value
	var probe_queue: Array = runtime.get("terrain_section_fluid_probe_queue")
	var probe_states: Dictionary = runtime.get("terrain_section_fluid_probe_states")
	var probe_samples: Array[Dictionary] = []
	for index in range(mini(6, probe_queue.size())):
		var key: Variant = probe_queue[index]
		var state: Dictionary = probe_states.get(key, {})
		probe_samples.append({"sectionKey":str(key),
			"stage":String(state.get("stage", "")),
			"lastReason":String(state.get("lastReason", ""))})
	var result := {"status":"ready", "fluidProbeQueueDepth":probe_queue.size(),
		"fluidProbeStateCount":probe_states.size(), "fluidProbeSamples":probe_samples,
		"fluidProofCount":(runtime.get("terrain_section_fluid_proofs") as Dictionary).size()}
	var shadow_value: Variant = runtime.get("terrain_section_shadow_publisher")
	if not shadow_value is Object or not is_instance_valid(shadow_value):
		result["shadow"] = {"status":"unavailable"}
		return result
	var shadow: Object = shadow_value
	var active: Dictionary = shadow.get("_active")
	var active_contribution: Dictionary = shadow.get("_active_contribution")
	var blocked: Dictionary = shadow.get("_blocked_contributions_by_section")
	var blocked_samples: Array[Dictionary] = []
	for key: Variant in blocked:
		if blocked_samples.size() >= 6: break
		var state: Dictionary = blocked.get(key, {})
		blocked_samples.append({"sectionKey":str(key),
			"stage":String(state.get("stage", "")),
			"reason":String(state.get("reason", state.get("lastReason", "")))})
	result["shadow"] = {"status":"ready",
		"requestQueueDepth":(shadow.get("_requests") as Array).size(),
		"activeStage":String(active.get("stage", "")),
		"activeLastReason":String(active.get("lastReason", "")),
		"contributionQueueDepth":(shadow.get("_contribution_requests") as Array).size(),
		"activeContributionStage":String(active_contribution.get("stage", "")),
		"activeContributionLastReason":String(active_contribution.get("lastReason", "")),
		"blockedContributionCount":blocked.size(),
		"blockedSamples":blocked_samples,
		"retainedContributionCount":(shadow.get("_contributions_by_section") as Dictionary).size()}
	return result


func _proof_summary(proof: Dictionary) -> Dictionary:
	return {"schema":String(proof.get("schema", "")),
		"sectionKey":_vec3i(proof.get("sectionKey", Vector3i.ZERO)),
		"hasFluid":bool(proof.get("hasFluid", false)),
		"volumeRevision":int(proof.get("volumeRevision", -1)),
		"fluidRevision":int(proof.get("fluidRevision", -1)),
		"signature":String(proof.get("signature", "")),
		"sectionRevisionCount":(proof.get("sectionRevisions", []) as Array).size()}


func _receipt_summary(receipt: Dictionary) -> Dictionary:
	return {"status":String(receipt.get("status", "")),
		"generation":int(receipt.get("generation", 0)),
		"sourceRevision":String(receipt.get("sourceRevision", "")),
		"translucentPovRevision":int(receipt.get("translucentPovRevision", -1)),
		"censusDigest":String(receipt.get("censusDigest", "")),
		"contentManifestDigest":String(receipt.get("contentManifestDigest", "")),
		"backendInstanceId":int(receipt.get("backendInstanceId", 0)),
		"chunkInstanceId":int(receipt.get("chunkInstanceId", 0)),
		"ownerCell":_vec2i(receipt.get("ownerCell", Vector2i.ZERO))}


func _pov_summary(pov: Dictionary) -> Dictionary:
	return {"status":String(pov.get("status", "")),
		"revision":int(pov.get("revision", -1)),
		"sectionKey":_vec3i(pov.get("sectionKey", Vector3i.ZERO)),
		"cameraPosition":_vec3(pov.get("cameraPosition", Vector3.ZERO))}


func _sample_summary(record: Dictionary) -> Dictionary:
	return {"fluid":String(record.get("fluid", "")),
		"fluidCell":_vec3i(record.get("fluidCell", Vector3i.ZERO)),
		"cameraCell":_vec3i(record.get("cameraCell", Vector3i.ZERO)),
		"targetCell":_vec3i(record.get("targetCell", Vector3i.ZERO)),
		"proof":String(record.get("proof", ""))}


func _vec3i(value: Variant) -> Array:
	return [value.x, value.y, value.z] if value is Vector3i else []


func _vec2i(value: Variant) -> Array:
	return [value.x, value.y] if value is Vector2i else []


func _vec3(value: Variant) -> Array:
	return [value.x, value.y, value.z] if value is Vector3 else []

extends SceneTree

const CONTEXT := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const GENERATION := preload("res://scripts/WorldGenerationSystem.gd")
const WORKER := preload("res://scripts/terrain/VoxelTerrainGenerator.gd")
const PROFILE_STORE := preload("res://scripts/world/GeneratedSiteProfileStore.gd")
const TERRAIN_VOLUME := preload("res://scripts/TerrainVolumeService.gd")
const SECTION_SNAPSHOT := preload("res://scripts/terrain/AuthoritativeTerrainSectionSnapshot.gd")
const CELL := 1.35
const BLOCK_SIZE := Vector3i(16, 16, 16)
const MAX_MISMATCHES := 8


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var rows: Array[Dictionary] = []
	for seed_text in ["atlas-1492", "atlas-75216765", "terrain-parity-4081"]:
		for block in [
			{"name": "surface", "origin": Vector3i(0, 4, 0), "lod": 0},
			{"name": "underground", "origin": Vector3i(32, -24, -16), "lod": 0},
			{"name": "deep_lod", "origin": Vector3i(-32, -60, 24), "lod": 1},
		]:
			rows.append(compare_block(seed_text, block))
	var revision_isolation := check_cave_cache_revision_isolation()
	var authority_snapshot := check_authoritative_section_snapshot()
	var passed := revision_isolation and bool(authority_snapshot.get("passed", false)) \
		and rows.all(func(row: Dictionary) -> bool:
		return row.passed and row.voxels == 4096 and row.savedEditVoxels == 2)
	var report := {"schema": "voxel-generator-exact-output-contract/v1",
		"evidenceLevel": "synthetic_service_contract", "liveGameplayAcceptance": false,
		"passed": passed, "complete": true, "revisionIsolation": revision_isolation,
		"authoritativeSectionSnapshot":authority_snapshot,
		"blocks": rows}
	var report_path := OS.get_environment("VOXEL_GENERATOR_EXACT_OUTPUT_REPORT")
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path(
			"res://artifacts/terrain/voxel-generator-exact-output-report.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write voxel generator parity report: " + report_path)
		quit(1)
		return
	file.store_string(JSON.stringify(report, "  "))
	quit(0 if passed else 1)


func check_authoritative_section_snapshot() -> Dictionary:
	var seed_text := "authoritative-section-snapshot-20261006"
	var context = CONTEXT.new()
	context.seed_text = seed_text
	context.seed_hash = context.hash_string(seed_text)
	context.setup_noise()
	var profile_store = PROFILE_STORE.new(seed_text)
	context.generated_site_profile_store = profile_store
	# Deliberately retain a setup-time edit in the generator template. The
	# snapshot must use the current volume delta map instead of that stale copy.
	context.initial_terrain_edits[Vector3i(2, 2, 2)] = {
		"density":CELL * 2.0, "material":"ironOre"}
	var generator = WORKER.new()
	generator.setup(context)
	var volume = TERRAIN_VOLUME.new()
	var section_key := Vector3i.ZERO
	var world_id := "seed:%s:%d" % [seed_text, context.seed_hash]
	var proof := make_empty_fluid_proof(section_key, volume)
	var baseline_result: Dictionary = capture_authoritative_snapshot(generator, volume,
		section_key, world_id, "transvoxel-material-fixture-v1", proof)
	if baseline_result.get("status") != "ready":
		return {"passed":false, "reason":"baseline_capture_failed", "result":baseline_result}
	var baseline: Dictionary = baseline_result.capture
	var prepared_probe: Dictionary = SECTION_SNAPSHOT.prepare(generator, volume,
		section_key, world_id, "transvoxel-material-fixture-v1", proof)
	var prepared_input: Dictionary = prepared_probe.get("prepared", {})
	var detached_input_read_only := false
	var private_worker_resources := false
	var exact_profile_snapshot := false
	var worker_generation_parity := false
	var worker_result_sealed := false
	var pre_cancelled_worker_rejected := false
	var cancellation_during_active_generation := false
	var active_cancelled_worker_joined := false
	var active_cancelled_result_not_sealed_or_admitted := false
	var census_revision_parity := false
	var prepared_stale_after_edit_rejected := false
	if prepared_probe.get("status") == "ready":
		var prepared_context: Object = prepared_input.context
		var pinned_towns: Dictionary = prepared_context.get("pinned_town_regions")
		var initial_edits: Dictionary = prepared_context.get("initial_terrain_edits")
		var profiles: Array = prepared_context.get("generated_site_profiles")
		var edit_overlay: Dictionary = prepared_input.editOverlay
		var overlay_rows: Array = edit_overlay.values
		var resource_graph_is_private := true
		for property_name in ["height_noise", "ridge_noise", "flat_noise",
				"moisture_noise", "temp_noise", "cave_field"]:
			if prepared_context.get(property_name) == generator.context_template.get(property_name):
				resource_graph_is_private = false
		var profile_snapshot: Array = prepared_input.profileSnapshot.get("profiles", [])
		private_worker_resources = resource_graph_is_private
		exact_profile_snapshot = Marshalls.raw_to_base64(var_to_bytes(profiles)) \
			== Marshalls.raw_to_base64(var_to_bytes(profile_snapshot))
		detached_input_read_only = prepared_input.is_read_only() \
			and prepared_context != generator.context_template \
			and prepared_context.get("generator_ref") == null \
			and prepared_context.get("generated_site_profile_store") == null \
			and pinned_towns.is_read_only() and initial_edits.is_read_only() \
			and profiles.is_read_only() and edit_overlay.is_read_only() \
			and overlay_rows.is_read_only()
		var source_revision := SECTION_SNAPSHOT.current_source_revision(generator,
			volume, section_key, world_id, "transvoxel-material-fixture-v1", proof)
		census_revision_parity = source_revision.get("status") == "ready" \
			and String(source_revision.get("sourceRevision", "")) \
				== String(baseline.get("sourceRevision", ""))
		var cancellation := SECTION_SNAPSHOT.CancellationToken.new()
		cancellation.cancel()
		var cancelled := SECTION_SNAPSHOT.generate_prepared(prepared_input, cancellation)
		pre_cancelled_worker_rejected = cancelled.get("status") == "cancelled"
	var origin: Vector3i = baseline.origin
	var reference_context = context.clone_for_worker()
	reference_context.initial_terrain_edits = {}
	var reference_generator = WORKER.new()
	reference_generator.setup(reference_context)
	var reference := make_capture_buffer(Vector3i(19, 19, 19))
	reference_generator._generate_block(reference, origin, 0)
	var parity: bool = buffer_matches_capture(reference, baseline)
	if prepared_probe.get("status") == "ready":
		var worker_thread := Thread.new()
		var thread_started := worker_thread.start(Callable(SECTION_SNAPSHOT,
			"generate_prepared").bind(prepared_input))
		if thread_started == OK:
			var worker_output: Variant = worker_thread.wait_to_finish()
			if worker_output is Dictionary and worker_output.get("status") == "ready":
				worker_generation_parity = buffer_matches_generated(reference, worker_output.generated)
				var worker_sealed := SECTION_SNAPSHOT.seal(prepared_input, worker_output,
					generator, volume, world_id, "transvoxel-material-fixture-v1", proof)
				worker_result_sealed = worker_sealed.get("status") == "ready" \
					and SECTION_SNAPSHOT.is_current(worker_sealed.capture, generator,
						volume, world_id, "transvoxel-material-fixture-v1", proof)
	var active_prepared_probe: Dictionary = SECTION_SNAPSHOT.prepare(generator, volume,
		section_key, world_id, "transvoxel-material-fixture-v1", proof)
	if active_prepared_probe.get("status") == "ready":
		var active_prepared: Dictionary = active_prepared_probe.prepared
		var active_cancellation := SECTION_SNAPSHOT.CancellationToken.new()
		var active_thread := Thread.new()
		var active_thread_started := active_thread.start(Callable(SECTION_SNAPSHOT,
			"generate_prepared").bind(active_prepared, active_cancellation))
		if active_thread_started == OK:
			var active_deadline := Time.get_ticks_msec() + 5000
			while active_thread.is_alive() \
					and not active_cancellation.is_generation_active() \
					and Time.get_ticks_msec() < active_deadline:
				OS.delay_usec(100)
			cancellation_during_active_generation = active_cancellation.is_generation_active()
			active_cancellation.cancel()
			var active_result: Variant = active_thread.wait_to_finish()
			active_cancelled_worker_joined = not active_thread.is_started()
			if cancellation_during_active_generation and active_result is Dictionary:
				var rejected_seal: Dictionary = SECTION_SNAPSHOT.seal(active_prepared,
					active_result, generator, volume, world_id,
					"transvoxel-material-fixture-v1", proof)
				active_cancelled_result_not_sealed_or_admitted = \
					active_result.get("status") == "cancelled" \
					and not active_result.has("generated") \
					and rejected_seal.get("status") != "ready" \
					and not rejected_seal.has("capture")
	var baseline_current: bool = SECTION_SNAPSHOT.is_current(baseline, generator, volume,
		world_id, "transvoxel-material-fixture-v1", proof)
	var stale_edit_cell := Vector3i(5, 5, 5)
	var overlay_state := {
		"material":"copperOre", "solid":true, "density":CELL * 2.0,
		"fluid":"", "light":{"sky":0,"block":0},
		"metadata":{"source":"scene_block", "renderedBySceneBlock":true,
			"terrainMeshAffects":false}}
	volume.set_scene_block_overlay(stale_edit_cell, overlay_state, "snapshot-test")
	proof = make_empty_fluid_proof(section_key, volume)
	var overlay_result: Dictionary = capture_authoritative_snapshot(generator, volume,
		section_key, world_id, "transvoxel-material-fixture-v1", proof)
	if prepared_probe.get("status") == "ready":
		prepared_stale_after_edit_rejected = not SECTION_SNAPSHOT.prepared_is_current(
			prepared_probe.prepared, generator, volume, world_id,
			"transvoxel-material-fixture-v1", proof)
	var nonterrain_overlay: bool = overlay_result.get("status") == "ready" \
		and String(overlay_result.capture.editOverlayDigest) != String(baseline.editOverlayDigest) \
		and buffer_matches_capture(reference, overlay_result.capture) \
		and not SECTION_SNAPSHOT.is_current(baseline, generator, volume, world_id,
			"transvoxel-material-fixture-v1", proof)
	var overlay_mesh_state := overlay_state.duplicate(true)
	overlay_mesh_state["material"] = "ironOre"
	overlay_mesh_state["metadata"]["terrainMeshAffects"] = true
	volume.set_scene_block_overlay(stale_edit_cell, overlay_mesh_state, "snapshot-terrain-overlay")
	proof = make_empty_fluid_proof(section_key, volume)
	var mesh_overlay_result: Dictionary = capture_authoritative_snapshot(generator, volume,
		section_key, world_id, "transvoxel-material-fixture-v1", proof)
	var mesh_overlay_applied := false
	if mesh_overlay_result.get("status") == "ready":
		var overlay_buffer := buffer_from_capture(mesh_overlay_result.capture)
		var local: Vector3i = stale_edit_cell - mesh_overlay_result.capture.origin
		mesh_overlay_applied = overlay_buffer.get_voxel(local.x, local.y, local.z,
			VoxelBuffer.CHANNEL_INDICES) == int(WORKER.MATERIAL_IDS.ironOre)
	var overlap_cell := Vector3i(7, 7, 7)
	volume.edited_cells[overlap_cell] = {"material":"copperOre", "solid":true,
		"density":CELL * 2.0, "fluid":"", "light":{"sky":0,"block":0},
		"metadata":{"source":"durable_edit", "terrainMeshAffects":true}}
	var overlap_overlay := {"material":"ironOre", "solid":true,
		"density":CELL * 3.0, "fluid":"", "light":{"sky":0,"block":0},
		"metadata":{"source":"scene_block", "terrainMeshAffects":true,
			"renderedBySceneBlock":true}}
	volume.set_scene_block_overlay(overlap_cell, overlap_overlay, "overlapping-source-test")
	proof = make_empty_fluid_proof(section_key, volume)
	var authoritative_overlap: Dictionary = volume.get_cell_state(overlap_cell)
	var expected_overlap_sdf_buffer := make_capture_buffer(Vector3i.ONE)
	expected_overlap_sdf_buffer.set_voxel_f(
		-float(authoritative_overlap.get("density", NAN)) / CELL,
		0, 0, 0, VoxelBuffer.CHANNEL_SDF)
	var expected_overlap_sdf := expected_overlap_sdf_buffer.get_voxel_f(
		0, 0, 0, VoxelBuffer.CHANNEL_SDF)
	var overlap_capture := capture_authoritative_snapshot(generator, volume,
		section_key, world_id, "transvoxel-material-fixture-v1", proof)
	var scene_overlay_wins := false
	var overlap_evidence := {
		"captureStatus":String(overlap_capture.get("status", "missing")),
		"captureReason":String(overlap_capture.get("reason", "")),
		"proofVolumeRevision":int(proof.get("volumeRevision", -1)),
		"liveVolumeRevision":int(volume.get("revision")),
		"proofFluidRevision":int(proof.get("fluidRevision", -1)),
		"liveFluidRevision":int(volume.get("fluid_revision")),
		"expectedState":{"material":String(authoritative_overlap.get("material", "")),
			"density":float(authoritative_overlap.get("density", NAN)),
			"source":String(authoritative_overlap.get("metadata", {}).get("source", ""))},
		"expectedChannelId":int(WORKER.MATERIAL_IDS.ironOre),
		"expectedRawSdf":-float(authoritative_overlap.get("density", NAN)) / CELL,
		"expectedSdf":expected_overlap_sdf,
		"actualChannelId":-1, "actualSdf":NAN,
		"sameCellOverrideRows":[]}
	if overlap_capture.get("status") == "ready":
		var overlap_buffer := buffer_from_capture(overlap_capture.capture)
		var overlap_local: Vector3i = overlap_cell - overlap_capture.capture.origin
		var actual_channel_id := int(overlap_buffer.get_voxel(overlap_local.x,
			overlap_local.y, overlap_local.z, VoxelBuffer.CHANNEL_INDICES))
		var actual_sdf := overlap_buffer.get_voxel_f(overlap_local.x,
			overlap_local.y, overlap_local.z, VoxelBuffer.CHANNEL_SDF)
		overlap_evidence["actualChannelId"] = actual_channel_id
		overlap_evidence["actualSdf"] = actual_sdf
		var overlap_prepare: Dictionary = SECTION_SNAPSHOT.prepare(generator, volume,
			section_key, world_id, "transvoxel-material-fixture-v1", proof)
		if overlap_prepare.get("status") == "ready":
			var edit_rows: Array = overlap_prepare.prepared.editOverlay.values
			var same_cell_rows: Array[Dictionary] = []
			for row_value: Variant in edit_rows:
				if row_value is Dictionary and row_value.get("cell") == overlap_cell:
					same_cell_rows.append({"kind":String(row_value.get("kind", "")),
						"material":String(row_value.get("material", "")),
						"density":float(row_value.get("density", NAN)),
						"affectsTerrainMesh":bool(row_value.get("affectsTerrainMesh", false))})
			overlap_evidence["sameCellOverrideRows"] = same_cell_rows
			overlap_evidence["prepareStatus"] = "ready"
		else:
			overlap_evidence["prepareStatus"] = String(overlap_prepare.get("status", "missing"))
			overlap_evidence["prepareReason"] = String(overlap_prepare.get("reason", ""))
		var rows_precedence_matches := false
		var captured_rows: Array = overlap_evidence.get("sameCellOverrideRows", [])
		if captured_rows.size() == 2:
			rows_precedence_matches = captured_rows[0].get("kind") == "edit" \
				and captured_rows[1].get("kind") == "scene_overlay"
		scene_overlay_wins = String(authoritative_overlap.get("material", "")) == "ironOre" \
			and actual_channel_id == int(WORKER.MATERIAL_IDS.ironOre) \
			and actual_sdf == expected_overlap_sdf \
			and rows_precedence_matches
	else:
		overlap_evidence["captureDetail"] = overlap_capture.get("detail", {})
	var scene_overlay_cleared := volume.clear_scene_block_overlay(overlap_cell)
	proof = make_empty_fluid_proof(section_key, volume)
	var restored_edit_capture := capture_authoritative_snapshot(generator, volume,
		section_key, world_id, "transvoxel-material-fixture-v1", proof)
	var durable_edit_revealed := false
	if restored_edit_capture.get("status") == "ready":
		var restored_buffer := buffer_from_capture(restored_edit_capture.capture)
		var restored_local: Vector3i = overlap_cell - restored_edit_capture.capture.origin
		durable_edit_revealed = scene_overlay_cleared \
			and String(volume.get_cell_state(overlap_cell).get("material", "")) == "copperOre" \
			and int(restored_buffer.get_voxel(restored_local.x, restored_local.y,
				restored_local.z, VoxelBuffer.CHANNEL_INDICES)) \
				== int(WORKER.MATERIAL_IDS.copperOre)
	var edit_cell := Vector3i(6, 6, 6)
	volume.edited_cells[edit_cell] = {"material":"copperOre", "solid":true,
		"density":CELL * 3.0, "fluid":"", "light":{"sky":0,"block":0},
		"metadata":{"terrainMeshAffects":true}}
	volume.section_revisions[Vector3i.ZERO] = 7
	var edit_result: Dictionary = capture_authoritative_snapshot(generator, volume,
		section_key, world_id, "transvoxel-material-fixture-v1", proof)
	var durable_edit_applied := false
	if edit_result.get("status") == "ready":
		var edit_buffer := buffer_from_capture(edit_result.capture)
		var edit_local: Vector3i = edit_cell - edit_result.capture.origin
		durable_edit_applied = edit_buffer.get_voxel(edit_local.x, edit_local.y,
			edit_local.z, VoxelBuffer.CHANNEL_INDICES) == int(WORKER.MATERIAL_IDS.copperOre)
	var edit_current: bool = edit_result.get("status") == "ready" \
		and SECTION_SNAPSHOT.is_current(edit_result.capture, generator, volume,
			world_id, "transvoxel-material-fixture-v1", proof)
	volume.section_revisions[Vector3i.ZERO] = 8
	var stale_revision_rejected := not SECTION_SNAPSHOT.is_current(edit_result.capture,
		generator, volume, world_id, "transvoxel-material-fixture-v1", proof)
	var changed_fluid_proof: Dictionary = make_empty_fluid_proof(section_key, volume).duplicate(false)
	changed_fluid_proof["signature"] = "changed-proof"
	changed_fluid_proof.make_read_only()
	var stale_fluid_rejected := not SECTION_SNAPSHOT.is_current(edit_result.capture,
		generator, volume, world_id, "transvoxel-material-fixture-v1", changed_fluid_proof)
	var high_air_key := Vector3i(0, 8, 0)
	var high_air_result: Dictionary = capture_authoritative_snapshot(generator, volume,
		high_air_key, world_id, "transvoxel-material-fixture-v1",
		make_empty_fluid_proof(high_air_key, volume))
	var explicit_empty_source := false
	if high_air_result.get("status") == "ready":
		var air_buffer := buffer_from_capture(high_air_result.capture)
		explicit_empty_source = true
		for z in 19:
			for y in 19:
				for x in 19:
					if air_buffer.get_voxel_f(x, y, z, VoxelBuffer.CHANNEL_SDF) <= 0.0:
						explicit_empty_source = false
						break
	var profile := {"worldSeed":seed_text, "siteId":"snapshot-profile",
		"envelopeCells":Rect2i(64, 64, 4, 4), "supportMask":[],
		"distanceCells":[], "groundRootPoints":[]}
	(profile.supportMask as Array).make_read_only()
	(profile.distanceCells as Array).make_read_only()
	(profile.groundRootPoints as Array).make_read_only()
	profile.make_read_only()
	var profile_accepted := profile_store.append_prepared_profile(profile)
	var profile_stale_rejected := not SECTION_SNAPSHOT.is_current(edit_result.capture,
		generator, volume, world_id, "transvoxel-material-fixture-v1", proof)
	var channel_payloads_immutable: bool = \
		baseline.get("sdf16LeBase64") is String \
		and baseline.get("indices8Base64") is String \
		and baseline.get("data5_8Base64") is String
	var snapshot_passed: bool = parity and baseline_current and detached_input_read_only \
		and worker_generation_parity and worker_result_sealed \
		and pre_cancelled_worker_rejected and census_revision_parity \
		and cancellation_during_active_generation and active_cancelled_worker_joined \
		and active_cancelled_result_not_sealed_or_admitted \
		and prepared_stale_after_edit_rejected \
		and private_worker_resources and exact_profile_snapshot \
		and channel_payloads_immutable \
		and nonterrain_overlay and mesh_overlay_applied \
		and scene_overlay_wins and durable_edit_revealed \
		and durable_edit_applied and edit_current and stale_revision_rejected \
		and stale_fluid_rejected and explicit_empty_source and profile_accepted \
		and profile_stale_rejected
	return {"passed":snapshot_passed, "parity":parity, "baselineCurrent":baseline_current,
		"workerGenerationParity":worker_generation_parity,
		"workerResultSealed":worker_result_sealed,
		"preCancelledWorkerRejected":pre_cancelled_worker_rejected,
		"cancellationDuringActiveGeneration":cancellation_during_active_generation,
		"activeCancelledWorkerJoined":active_cancelled_worker_joined,
		"activeCancelledResultNotSealedOrAdmitted":active_cancelled_result_not_sealed_or_admitted,
		"censusRevisionParity":census_revision_parity,
		"preparedStaleAfterEditRejected":prepared_stale_after_edit_rejected,
		"detachedInputReadOnly":detached_input_read_only,
		"workerResourcesPrivate":private_worker_resources,
		"workerUsesExactProfileSnapshot":exact_profile_snapshot,
		"nonterrainOverlayBoundAndOmitted":nonterrain_overlay,
		"channelPayloadsImmutable":channel_payloads_immutable,
		"terrainOverlayApplied":mesh_overlay_applied,
		"sceneBlockOverlayWinsSameCell":scene_overlay_wins,
		"sceneBlockOverlayEvidence":overlap_evidence,
		"durableEditRevealedWhenSceneOverlayClears":durable_edit_revealed,
		"durableEditApplied":durable_edit_applied, "editedCaptureCurrent":edit_current,
		"staleNeighborRevisionRejected":stale_revision_rejected,
		"staleFluidProofRejected":stale_fluid_rejected,
		"highAirSourceIsEmpty":explicit_empty_source,
		"profileRevisionBound":profile_stale_rejected,
		"payloadBytes":int(Marshalls.base64_to_raw(baseline.sdf16LeBase64).size() \
			+ Marshalls.base64_to_raw(baseline.indices8Base64).size() \
			+ Marshalls.base64_to_raw(baseline.data5_8Base64).size()),
		"origin":origin, "size":baseline.size}


func capture_authoritative_snapshot(generator: Object, volume: Object,
		section_key: Vector3i, world_id: String, material_revision: String,
		fluid_proof: Dictionary) -> Dictionary:
	var prepared_result: Dictionary = SECTION_SNAPSHOT.prepare(generator, volume,
		section_key, world_id, material_revision, fluid_proof)
	if prepared_result.get("status") != "ready":
		return prepared_result
	var prepared: Dictionary = prepared_result.prepared
	var generated: Dictionary = SECTION_SNAPSHOT.generate_prepared(prepared)
	return SECTION_SNAPSHOT.seal(prepared, generated, generator, volume,
		world_id, material_revision, fluid_proof)


func make_capture_buffer(size: Vector3i) -> VoxelBuffer:
	var buffer := VoxelBuffer.new()
	buffer.create(size.x, size.y, size.z)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	return buffer


func buffer_from_capture(capture: Dictionary) -> VoxelBuffer:
	var size: Vector3i = capture.size
	var buffer := make_capture_buffer(size)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_SDF,
		Marshalls.base64_to_raw(capture.sdf16LeBase64))
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_INDICES,
		Marshalls.base64_to_raw(capture.indices8Base64))
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_DATA5,
		Marshalls.base64_to_raw(capture.data5_8Base64))
	return buffer


func buffer_matches_capture(buffer: VoxelBuffer, capture: Dictionary) -> bool:
	var expected := buffer_from_capture(capture)
	return buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF) \
		== expected.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF) \
		and buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_INDICES) \
		== expected.get_channel_as_byte_array(VoxelBuffer.CHANNEL_INDICES) \
		and buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_DATA5) \
		== expected.get_channel_as_byte_array(VoxelBuffer.CHANNEL_DATA5)


func buffer_matches_generated(buffer: VoxelBuffer, generated: Dictionary) -> bool:
	return buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF) \
		== Marshalls.base64_to_raw(String(generated.get("sdf16LeBase64", ""))) \
		and buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_INDICES) \
		== Marshalls.base64_to_raw(String(generated.get("indices8Base64", ""))) \
		and buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_DATA5) \
		== Marshalls.base64_to_raw(String(generated.get("data5_8Base64", "")))


func make_empty_fluid_proof(section_key: Vector3i, volume: Object = null) -> Dictionary:
	var volume_revision := int(volume.get("revision")) if volume != null else 0
	var fluid_revision := int(volume.get("fluid_revision")) if volume != null else 0
	var proof := {"schema":"terrain-fluid-section-proof/v2", "sectionKey":section_key,
		"hasFluid":false, "volumeRevision":volume_revision,
		"fluidRevision":fluid_revision,
		"boundsInclusive":true, "minCell":section_key * 16,
		"maxCell":section_key * 16 + Vector3i.ONE * 15,
		"sectionRevisions":[], "signature":"snapshot-fluid-proof:%s:%d:%d" % [
			str(section_key), volume_revision, fluid_revision]}
	proof.make_read_only()
	return proof


func check_cave_cache_revision_isolation() -> bool:
	var template = CONTEXT.new()
	template.seed_text = "revision-isolation-407"
	template.seed_hash = template.hash_string(template.seed_text)
	template.setup_noise()
	var store = PROFILE_STORE.new(template.seed_text)
	template.generated_site_profile_store = store
	var before = template.clone_for_worker()
	var same = template.clone_for_worker()
	var empty: Array = []
	empty.make_read_only()
	var profile := {"worldSeed": template.seed_text, "siteId": "test-site",
		"envelopeCells": Rect2i(0, 0, 4, 4), "supportMask": empty,
		"distanceCells": empty, "groundRootPoints": empty}
	profile.make_read_only()
	if not store.append_prepared_profile(profile):
		return false
	var after = template.clone_for_worker()
	var after_same = template.clone_for_worker()
	return is_same(before.cave_field, same.cave_field) \
		and not is_same(before.cave_field, after.cave_field) \
		and is_same(after.cave_field, after_same.cave_field) \
		and before.generated_site_profiles.is_empty() \
		and after.generated_site_profiles.size() == 1


func compare_block(seed_text: String, block: Dictionary) -> Dictionary:
	var origin: Vector3i = block.origin
	var lod: int = block.lod
	var voxel_scale := 1 << lod
	var context = CONTEXT.new()
	context.seed_text = seed_text
	context.seed_hash = context.hash_string(seed_text)
	context.setup_noise()
	# This is the durable edit snapshot consumed by the native worker context.
	# Exercise both a removed cell and a replacement solid at each block origin.
	context.initial_terrain_edits[origin + Vector3i(1, 1, 1) * voxel_scale] = {
		"density": -CELL, "material": "air"}
	context.initial_terrain_edits[origin + Vector3i(6, 5, 3) * voxel_scale] = {
		"density": CELL * 2.0, "material": "copperOre"}
	var worker = WORKER.new()
	worker.setup(context)
	var shared_field = context.clone_for_worker().cave_field
	var actual := make_buffer()
	var worker_started := Time.get_ticks_usec()
	worker._generate_block(actual, origin, lod)
	var worker_usec := Time.get_ticks_usec() - worker_started
	var first_builds := int(shared_field.cache_stats().get("recipe_build_count", 0))
	var repeat := make_buffer()
	var repeat_started := Time.get_ticks_usec()
	worker._generate_block(repeat, origin, lod)
	var repeat_usec := Time.get_ticks_usec() - repeat_started
	var repeat_builds := int(shared_field.cache_stats().get("recipe_build_count", 0))
	var reference := make_buffer()
	var direct_context = context.clone_for_worker()
	direct_context.cave_field = null
	var world = GENERATION.new()
	var setup_started := Time.get_ticks_usec()
	world.setup(direct_context)
	direct_context.set_generator(world)
	var setup_usec := Time.get_ticks_usec() - setup_started
	var material_worker = WORKER.new()
	var reference_started := Time.get_ticks_usec()
	var saved_edit_voxels := fill_direct_reference(reference, direct_context, world,
		material_worker, origin, lod)
	var reference_usec := Time.get_ticks_usec() - reference_started
	var cave_stats: Dictionary = world.cave_field.cache_stats()
	var mismatch_count := 0
	var mismatches: Array[Dictionary] = []
	var material_ids: Dictionary = {}
	for z in BLOCK_SIZE.z:
		for y in BLOCK_SIZE.y:
			for x in BLOCK_SIZE.x:
				var at := Vector3i(x, y, z)
				var actual_sdf := actual.get_voxel_f(x, y, z, VoxelBuffer.CHANNEL_SDF)
				var reference_sdf := reference.get_voxel_f(x, y, z, VoxelBuffer.CHANNEL_SDF)
				var actual_indices := actual.get_voxel(x, y, z, VoxelBuffer.CHANNEL_INDICES)
				var reference_indices := reference.get_voxel(x, y, z, VoxelBuffer.CHANNEL_INDICES)
				var actual_data5 := actual.get_voxel(x, y, z, VoxelBuffer.CHANNEL_DATA5)
				var reference_data5 := reference.get_voxel(x, y, z, VoxelBuffer.CHANNEL_DATA5)
				material_ids[actual_indices] = true
				if actual_sdf != reference_sdf or actual_indices != reference_indices \
						or actual_data5 != reference_data5 \
						or repeat.get_voxel_f(x, y, z, VoxelBuffer.CHANNEL_SDF) != actual_sdf \
						or repeat.get_voxel(x, y, z, VoxelBuffer.CHANNEL_INDICES) != actual_indices \
						or repeat.get_voxel(x, y, z, VoxelBuffer.CHANNEL_DATA5) != actual_data5:
					mismatch_count += 1
					if mismatches.size() < MAX_MISMATCHES:
						mismatches.append({"cell": origin + at * voxel_scale,
							"actualSdf": actual_sdf, "referenceSdf": reference_sdf,
							"actualIndices": actual_indices, "referenceIndices": reference_indices,
							"actualData5": actual_data5, "referenceData5": reference_data5})
	return {"seed": seed_text, "block": block.name, "origin": origin, "lod": lod,
		"voxels": BLOCK_SIZE.x * BLOCK_SIZE.y * BLOCK_SIZE.z,
		"savedEditVoxels": saved_edit_voxels, "materialCount": material_ids.size(),
		"workerUsec": worker_usec, "repeatWorkerUsec": repeat_usec,
		"firstRecipeBuilds": first_builds, "repeatRecipeBuilds": repeat_builds,
		"referenceUsec": reference_usec,
		"worldSetupUsec": setup_usec, "caveRecipeBuilds": cave_stats.get("recipe_build_count", 0),
		"caveRecipeBuildUsec": cave_stats.get("recipe_build_total_usec", 0),
		"caveRecipeBuildMaxUsec": cave_stats.get("recipe_build_max_usec", 0),
		"mismatchCount": mismatch_count, "mismatches": mismatches,
		"passed": mismatch_count == 0 and first_builds >= 1 and repeat_builds == first_builds}


func make_buffer() -> VoxelBuffer:
	var buffer := VoxelBuffer.new()
	buffer.create(BLOCK_SIZE.x, BLOCK_SIZE.y, BLOCK_SIZE.z)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	return buffer


func fill_direct_reference(buffer: VoxelBuffer, context, world, material_worker,
		origin: Vector3i, lod: int) -> int:
	var voxel_scale := 1 << lod
	var saved_edit_voxels := 0
	for z in BLOCK_SIZE.z:
		for y in BLOCK_SIZE.y:
			for x in BLOCK_SIZE.x:
				var cell := origin + Vector3i(x, y, z) * voxel_scale
				var saved_edit: Dictionary = context.initial_terrain_edits.get(cell, {})
				var density: float
				var material_name: String
				if not saved_edit.is_empty():
					saved_edit_voxels += 1
					density = float(saved_edit.get("density", -CELL)) / float(voxel_scale)
					material_name = String(saved_edit.get("material", "air"))
				else:
					var position := Vector3(cell) * CELL
					# This is the prior direct per-voxel loop, without the worker's
					# local x/z height and biome caches.
					var base_surface_y: float = world.terrain_reference_surface_y_at(position)
					var surface_y: float = world.terrain_deformed_surface_y_at(position)
					density = world.density_from_components(position, surface_y,
						base_surface_y) / float(voxel_scale)
					material_name = material_worker.material_for_generated_density(
						world, cell, position, base_surface_y, density)
				var material_id := int(WORKER.MATERIAL_IDS.get(material_name,
					WORKER.MATERIAL_IDS["stone"]))
				buffer.set_voxel_f(-density / CELL, x, y, z, VoxelBuffer.CHANNEL_SDF)
				buffer.set_voxel(material_id, x, y, z, VoxelBuffer.CHANNEL_INDICES)
				buffer.set_voxel(material_id, x, y, z, VoxelBuffer.CHANNEL_DATA5)
	buffer.compress_uniform_channels()
	return saved_edit_voxels

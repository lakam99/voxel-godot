extends "res://scripts/testing/world/WorldStaticSectionCandidateAssemblerContract.gd"
## Synthetic inputs through the actual native worker. No gameplay acceptance.

const Snapshot := preload("res://scripts/world/ChunkStaticRenderSectionSnapshot.gd")
var dispatcher: Object


func _run() -> void:
	_check("native_class_registered", ClassDB.class_exists("NativeSectionCompileDispatcher"), {})
	if not ClassDB.class_exists("NativeSectionCompileDispatcher"):
		_finish()
		return
	dispatcher = ClassDB.instantiate("NativeSectionCompileDispatcher")
	_build_shared_batch()
	var census := _census(["terrain:0,0,0", "ordinary:town-a:cell-0"],
		{"terrain:0,0,0":"terrain-r1", "ordinary:town-a:cell-0":"ordinary-r1"})
	var digest_census: Dictionary = census.duplicate(false)
	digest_census["censusDigest"] = String(census.get("censusDigest", "")).sha256_text()
	digest_census.make_read_only()
	census = digest_census
	var contributions := _contributions(census)
	var identity_fixture := _identity_fixture(census, contributions)
	census = identity_fixture.census
	contributions = identity_fixture.contributions
	var old_result := Assembler.assemble(census, SECTION, contributions, 1)
	var prepared := Assembler.prepare_compile(census, SECTION, contributions, 1)
	_check("production_prepare_ready", prepared.get("status") == "ready", prepared.get("reason", ""))
	if prepared.get("status") != "ready":
		dispatcher.call("drain_section_compiles")
		_finish()
		return
	var identity := _identity(1, String(prepared.inputDigest), String(census.censusDigest))
	var admitted: Dictionary = dispatcher.call("submit_section_compile", prepared.nativePreparation, identity)
	var ticket := int(admitted.get("ticket", -1))
	var result := await _wait_take(ticket)
	var finalized := Assembler.finalize_compile(prepared.preparation, result)
	_check("production_candidate_parity", finalized.get("status") == "ready" \
		and finalized.get("contentManifestDigest") == old_result.get("contentManifestDigest") \
		and finalized.get("candidate", {}).get("sourceRevisions") == old_result.get("candidate", {}).get("sourceRevisions") \
		and finalized.get("candidate", {}).get("materialBindings") == old_result.get("candidate", {}).get("materialBindings") \
		and finalized.get("candidate", {}).get("meshBindings") == old_result.get("candidate", {}).get("meshBindings"),
		{"nativeStatus":result.get("status"), "finalStatus":finalized.get("status"), "reason":finalized.get("reason", "")})
	var twice: Dictionary = dispatcher.call("take_section_compile_result", ticket)
	_check("result_consumed_once", twice.get("status") != "ready", twice)
	dispatcher.call("release_section_compile", ticket)
	var forged := result.duplicate(false)
	var forged_identity: Dictionary = result.get("identity", {}).duplicate(false)
	forged_identity["preparedPayloadDigest"] = "forged"
	forged["identity"] = forged_identity
	_check("wrong_capture_rejected", Assembler.finalize_compile(prepared.preparation, forged).get("status") == "failed", {})

	var mixed := _mixed_contributors()
	var expected := Snapshot.assemble(SECTION, mixed)
	var snapshot_prepare := Snapshot.prepare_compile(SECTION, mixed)
	var mutable_copy: Dictionary = snapshot_prepare.preparation.duplicate(true)
	var copied_identity := _identity(2, "mixed-payload", "mixed-coverage")
	var copied_admission: Dictionary = dispatcher.call("submit_section_compile", mutable_copy, copied_identity)
	_check("mutable_input_admitted_as_owned_copy", int(copied_admission.get("ticket", -1)) > 0, copied_admission)
	for group: Dictionary in mutable_copy.batches.values():
		for input: Dictionary in group.inputContributions:
			input.buffer[0] = 999.0
	var copied_result := await _wait_take(int(copied_admission.get("ticket", -1)))
	var merged := Snapshot.finalize_compile(snapshot_prepare.preparation, copied_result.get("groups", {}))
	_check("mixed_layers_split_and_copied_payload_parity", merged == expected,
		{"nativeStatus":copied_result.get("status"), "reason":merged.get("reason", ""),
		"expectedBatchCount":expected.get("snapshot", {}).get("batchCount", -1)})
	dispatcher.call("release_section_compile", int(copied_admission.get("ticket", -1)))

	var old_admission: Dictionary = dispatcher.call("submit_section_compile", snapshot_prepare.preparation,
		_identity(3, "old", "coverage"))
	var newer_admission: Dictionary = dispatcher.call("submit_section_compile", snapshot_prepare.preparation,
		_identity(4, "new", "coverage"))
	_check("replacement_jobs_admitted", int(old_admission.get("ticket", -1)) > 0 \
		and int(newer_admission.get("ticket", -1)) > 0, {"old":old_admission, "new":newer_admission})
	var old_terminal := await _wait_take(int(old_admission.get("ticket", -1)))
	_check("superseded_cannot_be_consumed", old_terminal.get("status") != "ready", old_terminal.get("status"))
	var newer_ticket := int(newer_admission.get("ticket", -1))
	var newer_ready: Dictionary = await _wait_ready_state(newer_ticket)
	_check("ready_before_cancel", newer_ready.get("status") == "ready", newer_ready)
	var foreign_world_identity := _identity(4, "foreign-world", "coverage")
	foreign_world_identity["worldId"] = WORLD + ":other"
	var foreign_world: Dictionary = dispatcher.call("submit_section_compile",
		snapshot_prepare.preparation, foreign_world_identity)
	var foreign_epoch_identity := _identity(4, "foreign-epoch", "coverage")
	foreign_epoch_identity["worldEpoch"] = WORLD + ":next-epoch"
	var foreign_epoch: Dictionary = dispatcher.call("submit_section_compile",
		snapshot_prepare.preparation, foreign_epoch_identity)
	var cancel_identity := _identity(4, "cancel-target", "coverage")
	dispatcher.call("cancel_section_compile", String(cancel_identity.worldId),
		String(cancel_identity.worldEpoch), SECTION, 4)
	var cancelled := await _wait_take(int(newer_admission.get("ticket", -1)))
	_check("ready_cancelled_cannot_be_consumed", cancelled.get("status") == "cancelled", cancelled.get("status"))
	var foreign_world_result := await _wait_take(int(foreign_world.get("ticket", -1)))
	var foreign_epoch_result := await _wait_take(int(foreign_epoch.get("ticket", -1)))
	_check("cancel_is_world_and_epoch_scoped", foreign_world_result.get("status") == "ready" \
		and foreign_epoch_result.get("status") == "ready", {
		"foreignWorld":foreign_world_result.get("status"),
		"foreignEpoch":foreign_epoch_result.get("status")})
	dispatcher.call("release_section_compile", int(old_admission.get("ticket", -1)))
	dispatcher.call("release_section_compile", int(newer_admission.get("ticket", -1)))

	var empty_array: Array = []
	empty_array.make_read_only()
	var empty := Snapshot.prepare_compile(SECTION, empty_array)
	var empty_admission: Dictionary = dispatcher.call("submit_section_compile", empty.preparation, _identity(5, "empty", "coverage"))
	var empty_result := await _wait_take(int(empty_admission.get("ticket", -1)))
	_check("explicit_empty_native_result", empty_result.get("status") == "ready" \
		and Snapshot.finalize_compile(empty.preparation, empty_result.get("groups", {})) == Snapshot.assemble(SECTION, empty_array), {})
	dispatcher.call("release_section_compile", int(empty_admission.get("ticket", -1)))
	var tickets: Array[int] = []
	var refused: Dictionary = {}
	for index in range(40):
		var capacity_identity := _identity(1, "capacity", "coverage")
		capacity_identity["sectionKey"] = Vector3i(index + 1, 0, 0)
		var capacity_preparation: Dictionary = empty.preparation.duplicate(false)
		capacity_preparation["sectionKey"] = capacity_identity.sectionKey
		var admission: Dictionary = dispatcher.call("submit_section_compile", capacity_preparation, capacity_identity)
		if int(admission.get("ticket", -1)) < 0:
			refused = admission
			break
		tickets.append(int(admission.ticket))
	_check("unconsumed_jobs_apply_backpressure", tickets.size() == 32 and not refused.is_empty(), refused)
	for retained_ticket: int in tickets:
		await _wait_take(retained_ticket)
		dispatcher.call("release_section_compile", retained_ticket)
	var retried: Dictionary = dispatcher.call("submit_section_compile", empty.preparation, _identity(6, "retry", "coverage"))
	_check("capacity_recovers_after_consumption", int(retried.get("ticket", -1)) > 0, retried)
	await _wait_take(int(retried.get("ticket", -1)))
	dispatcher.call("release_section_compile", int(retried.get("ticket", -1)))
	var drained: Dictionary = dispatcher.call("drain_section_compiles")
	_check("drained", drained.get("status") == "drained" \
		and int(drained.get("pendingJobCount", -1)) == 0 \
		and int(drained.get("workerCount", -1)) == 0 \
		and int(drained.get("retainedBufferBytes", -1)) == 0, drained)
	_finish()


func _wait_take(ticket: int) -> Dictionary:
	if ticket < 0: return {"status":"failed", "reason":"admission_missing_ticket"}
	for frame in range(600):
		var state: Dictionary = dispatcher.call("poll_section_compile", ticket)
		if state.get("status") not in ["queued", "running"]:
			return dispatcher.call("take_section_compile_result", ticket)
		await process_frame
	return {"status":"failed", "reason":"contract_worker_wait_exhausted"}


func _identity(generation: int, digest: String, coverage: String) -> Dictionary:
	var prepared_digest := digest if digest.length() == 64 else digest.sha256_text()
	var coverage_digest := coverage if coverage.length() == 64 else coverage.sha256_text()
	return {"worldId":WORLD, "worldEpoch":WORLD, "sectionKey":SECTION,
		"generation":generation, "providerRevisionDigest":coverage_digest,
		"sourceIndexRevision":"0", "coverageDigest":coverage_digest,
		"preparedPayloadDigest":prepared_digest}


func _wait_ready_state(ticket: int) -> Dictionary:
	if ticket < 0: return {"status":"failed", "reason":"admission_missing_ticket"}
	for _frame in range(600):
		var state: Dictionary = dispatcher.call("poll_section_compile", ticket)
		if state.get("status") == "ready": return state
		if state.get("status") not in ["queued", "running"]: return state
		await process_frame
	return {"status":"failed", "reason":"contract_worker_wait_exhausted"}


func _build_shared_batch() -> void:
	mesh = ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, 0, -0.5), Vector3(0.5, 0, -0.5), Vector3(0, 1, 0.5)])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	material = StandardMaterial3D.new()
	var fingerprint: Dictionary = MeshFingerprint.inspect(mesh)
	var mesh_resource_key := "contract-shared-triangle"
	var pipeline := "native-compile-contract-v1"
	var raw := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":"contract:foliage", "renderTier":"detail",
		"meshResourceKey":mesh_resource_key,
		"meshKey":"%s|pipeline=%s|layer=opaque|sort=none" % [mesh_resource_key, pipeline],
		"meshContentDigest":String(fingerprint.get("contentDigest", "")),
		"meshLocalBounds":mesh.get_aabb(), "pipelineRevision":pipeline,
		"renderLayer":"opaque", "translucentSortPolicy":"none", "castShadows":true,
		"visibilityRangeEnd":240.0, "fadeMargin":12.0}
	batch_key = SnapshotBuilder.batch_compatibility_key(raw)
	raw["batchKey"] = batch_key
	raw["compatibilityKey"] = batch_key
	raw.make_read_only()
	compatibility = raw


## The shared geometry fixture predates composite source identities. Admit its
## same sources through the current exact (sourceId, sourcePartId) census.
func _identity_fixture(census: Dictionary, contributions: Array) -> Dictionary:
	var upgraded: Dictionary = census.duplicate(false)
	var revisions: Dictionary = {}
	var providers: Dictionary = {}
	var identities: Dictionary = {}
	var expected: Array[String] = []
	for part: String in census.sourceRevisions:
		var key := Assembler._source_part_identity_key(part, part)
		expected.append(key)
		revisions[key] = census.sourceRevisions[part]
		providers[key] = census.sourceProviderIds[part]
		identities[key] = {"sourceId":part, "sourcePartId":part}
	expected.sort()
	upgraded["sourceRevisions"] = revisions
	upgraded["sourceProviderIds"] = providers
	upgraded["sourceIdentities"] = identities
	upgraded["expectedContributorsBySection"] = {SECTION:expected}
	var rows: Array = []
	for original: Dictionary in contributions:
		var row := original.duplicate(false)
		var authority: Dictionary = {}
		for part: String in original.authoritySourceRevisions:
			authority[Assembler._source_part_identity_key(part, part)] = original.authoritySourceRevisions[part]
		authority.make_read_only()
		row["authoritySourceRevisions"] = authority
		row.make_read_only()
		rows.append(row)
	rows.make_read_only()
	return {"census":Assembler._capture_value(upgraded), "contributions":rows}


func _mixed_contributors() -> Array:
	var contributors: Array = []
	for source_index in range(2):
		var batches: Array = []
		for layer: String in ["opaque", "cutout", "translucent"]:
			var buffer: Array[float] = []
			for index in range(150):
				buffer.append_array(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3(2, 2, 2)),
					Color(0.25, 0.5, 0.75, 1), Color(0, 0, 0, 1)))
			buffer.make_read_only()
			var mesh_bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
			var segment := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
				"segmentId":"segment", "buffer":buffer, "instanceCount":150,
				"bounds":AABB(Vector3(1.5, 1.5, 1.5), Vector3.ONE), "meshLocalBounds":mesh_bounds}
			segment.make_read_only()
			var segments: Array = [segment]
			segments.make_read_only()
			var batch := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
				"materialKey":"material", "renderTier":"detail", "meshKey":"box",
				"meshContentDigest":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
				"pipelineRevision":"contract/v1", "renderLayer":layer,
				"transparencySortPolicy":"camera_depth" if layer == "translucent" else "none",
				"meshLocalBounds":mesh_bounds, "castShadows":true,
				"visibilityRangeEnd":128.0, "fadeMargin":8.0, "segments":segments}
			batch.make_read_only()
			batches.append(batch)
		batches.make_read_only()
		var contributor := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
			"sourceId":"source-%d" % source_index, "sourcePartId":"part", "sourceRevision":"r1",
			"ownerCell":Vector2i.ZERO, "sectionKey":SECTION, "bufferSpace":"section_local", "batches":batches}
		contributor.make_read_only()
		contributors.append(contributor)
	contributors.make_read_only()
	return contributors


func _finish() -> void:
	var failed: Array[String] = []
	for name: String in checks:
		if not checks[name].passed: failed.append(name)
	var report := {"schema":"native-section-compile-dispatcher-contract/v1", "passed":failed.is_empty(),
		"checks":checks, "checkCount":checks.size(), "failedChecks":failed,
		"evidenceLevel":"synthetic_inputs_actual_native_worker_contract",
		"doesNotProve":"Live renderer installation, source discovery, gameplay or traversal performance."}
	var file := FileAccess.open(OS.get_environment("VOXEL_NATIVE_SECTION_COMPILE_REPORT"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	quit(0 if failed.is_empty() else 1)

extends SceneTree

const Assembler := preload("res://scripts/world/WorldStaticSectionCandidateAssembler.gd")
const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const PacketOwner := preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstallSession := preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const RuntimeToolsScript := preload("res://scripts/MainRuntimeTools.gd")
const REPORT_ENV := "VOXEL_WHOLE_SECTION_NATIVE_INSTALL_REPORT"
const WORLD := "seed:whole-section-native-install"
const SECTION := Vector3i.ZERO
const SOURCE_REVISIONS := {"terrain:0,0,0":"terrain-r1", "ordinary:fixture:0":"ordinary-r1"}

var report_path := ""
var checks: Dictionary = {}
var shared_mesh: ArrayMesh
var shared_material: StandardMaterial3D
var shared_compatibility: Dictionary
var shared_batch_key := ""
var coordinator


class CensusProvider extends RefCounted:
	var world_id := ""
	var provider_id := ""
	var source_part_id := ""
	var source_revision := ""

	func capture_static_section_sources(request_world_id: String,
			section_keys: Array) -> Dictionary:
		if request_world_id != world_id or section_keys != [SECTION]:
			return {"status":"failed", "reason":"unexpected_fixture_census_query"}
		var ids: Array[String] = [source_part_id]
		ids.make_read_only()
		var row := {"status":"complete", "coverageRevision":provider_id + "-coverage-r1",
			"sourcePartIds":ids}
		row.make_read_only()
		var revisions := {source_part_id:source_revision}
		revisions.make_read_only()
		var sections := {SECTION:row}
		sections.make_read_only()
		var result := {"status":"complete", "worldId":world_id,
			"authorityRevision":provider_id + "-authority-r1",
			"sourceRevisions":revisions, "sections":sections}
		result.make_read_only()
		return result


class WorldRoot extends Node3D:
	var chunk_owner: Node3D
	var backend: Node3D

	func get_static_section_render_owner(owner_cell: Vector2i,
			create_if_missing: bool) -> Dictionary:
		if owner_cell != Vector2i.ZERO or not is_instance_valid(chunk_owner) \
				or not is_instance_valid(backend):
			return {"status":"pending", "reason":"fixture_owner_unavailable"}
		return {"status":"ready", "owner":chunk_owner, "backend":backend}


func _initialize() -> void:
	report_path = OS.get_environment(REPORT_ENV)
	call_deferred("_run")


func _run() -> void:
	_build_shared_batch()
	var world := WorldRoot.new()
	world.name = "WholeSectionNativeInstallWorld"
	root.add_child(world)
	current_scene = world
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	world.add_child(chunk)
	var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
	var backend: Node3D = attached.get("backend") as Node3D
	world.chunk_owner = chunk
	world.backend = backend
	coordinator = Coordinator.new()
	coordinator.configure(WORLD)
	var required_providers: Array[String] = ["terrain", "ordinary"]
	coordinator.configure_source_roster(required_providers)
	var terrain_provider := CensusProvider.new()
	terrain_provider.world_id = WORLD
	terrain_provider.provider_id = "terrain"
	terrain_provider.source_part_id = "terrain:0,0,0"
	terrain_provider.source_revision = "terrain-r1"
	var ordinary_provider := CensusProvider.new()
	ordinary_provider.world_id = WORLD
	ordinary_provider.provider_id = "ordinary"
	ordinary_provider.source_part_id = "ordinary:fixture:0"
	ordinary_provider.source_revision = "ordinary-r1"
	coordinator.register_source_provider("terrain", terrain_provider,
		"capture_static_section_sources")
	coordinator.register_source_provider("ordinary", ordinary_provider,
		"capture_static_section_sources")
	_check("real_native_section_backend_attached", attached.get("status") == "ready"
		and is_instance_valid(backend), attached)
	if not checks["real_native_section_backend_attached"].passed:
		_finish()
		return
	var first_census: Dictionary = coordinator.capture_authoritative_source_census([SECTION])
	var first_result: Dictionary = _assemble(1, first_census)
	var first_candidate: Dictionary = first_result.get("candidate", {})
	var first_admission: Dictionary = coordinator.submit_complete_section_candidate(first_candidate)
	_check("production_candidate_enters_native_install_session",
		first_admission.get("status") == "queued", first_admission)
	if first_admission.get("status") != "queued":
		_finish()
		return
	var first_outcome: Dictionary = await _advance_coordinator_to_install()
	var slot := InstallSession.slot_id(WORLD, SECTION)
	var first_live: Dictionary = backend.call("installed_snapshot", slot)
	_check("first_whole_section_candidate_has_native_receipt",
		first_outcome.get("status") == "installed" and first_live.get("status") == "ready"
		and int(first_live.get("generation", 0)) == 1
		and bool(backend.call("receipt_installed", slot, 1,
			"%s:%d" % [WORLD, 1], String(first_candidate.get("contentManifestDigest", "")))),
		{"outcome":first_outcome, "installed":first_live})
	if first_outcome.get("status") != "installed":
		_finish()
		return
	var second_census: Dictionary = coordinator.capture_authoritative_source_census([SECTION])
	var second_result: Dictionary = _assemble(2, second_census)
	var second_candidate: Dictionary = second_result.get("candidate", {})
	var second_admission: Dictionary = coordinator.submit_complete_section_candidate(second_candidate)
	_check("replacement_candidate_begins_without_retiring_old_slot",
		second_admission.get("status") == "queued"
		and int(backend.call("installed_snapshot", slot).get("generation", 0)) == 1,
		{"admission":second_admission, "oldSlot":backend.call("installed_snapshot", slot)})
	if second_admission.get("status") != "queued":
		_finish()
		return
	var waiting_for_commit := false
	for frame_index in range(1200):
		var scheduled: Dictionary = coordinator.advance_queued_complete_section_candidates(1, 8)
		var step: Dictionary = scheduled.get("results", [{}])[0] if not scheduled.get("results", []).is_empty() else {"status":"idle"}
		var active: Dictionary = coordinator._production_candidate_jobs.get(SECTION, {})
		var session = active.get("session")
		if session is RefCounted and String(session.get("state")) == "commit":
			waiting_for_commit = true
			break
		if step.get("status") in ["failed", "cancelled"]:
			break
		await process_frame
	var before_commit: Dictionary = backend.call("installed_snapshot", slot)
	_check("old_native_generation_remains_installed_through_staging",
		waiting_for_commit and int(before_commit.get("generation", 0)) == 1,
		{"waitingForCommit":waiting_for_commit, "installed":before_commit})
	var replacement_outcome: Dictionary = {"status":"not_started"}
	if waiting_for_commit:
		replacement_outcome = coordinator.advance_complete_section_candidate(SECTION, 8)
	var after_commit: Dictionary = backend.call("installed_snapshot", slot)
	_check("replacement_promotes_only_after_native_commit_ack",
		replacement_outcome.get("status") == "installed"
		and after_commit.get("status") == "ready"
		and int(after_commit.get("generation", 0)) == 2
		and bool(backend.call("receipt_installed", slot, 2,
			"%s:%d" % [WORLD, 2], String(second_candidate.get("contentManifestDigest", "")))),
		{"outcome":replacement_outcome, "installed":after_commit})
	var third_census: Dictionary = coordinator.capture_authoritative_source_census([SECTION])
	var third_result: Dictionary = _assemble(3, third_census)
	var third_candidate: Dictionary = third_result.get("candidate", {})
	var third_admission: Dictionary = coordinator.submit_complete_section_candidate(third_candidate)
	ordinary_provider.source_revision = "ordinary-r2"
	var stale_advance: Dictionary = coordinator.advance_complete_section_candidate(SECTION, 8)
	var retained_after_stale: Dictionary = backend.call("installed_snapshot", slot)
	_check("stale_authority_rejects_candidate_and_retains_last_live_slot",
		third_admission.get("status") == "queued"
		and stale_advance.get("status") == "pending"
		and bool(stale_advance.get("requiresReassembly", false))
		and int(retained_after_stale.get("generation", 0)) == 2,
		{"admission":third_admission, "advance":stale_advance,
		"retainedGeneration":retained_after_stale.get("generation", 0)})
	ordinary_provider.source_revision = "ordinary-r1"
	var old_chunk_instance_id := chunk.get_instance_id()
	var unloaded_sections: int = coordinator.notify_stream_chunk_unloaded(Vector2i.ZERO,
		old_chunk_instance_id)
	world.remove_child(chunk)
	chunk.free()
	var recreated_chunk := Node3D.new()
	recreated_chunk.name = "Chunk_0_0"
	world.add_child(recreated_chunk)
	var recreated_backend_result: Dictionary = PacketOwner.attach_to_chunk(recreated_chunk)
	backend = recreated_backend_result.get("backend") as Node3D
	world.chunk_owner = recreated_chunk
	world.backend = backend
	var replay_queue_count: int = coordinator.notify_stream_chunk_loaded(Vector2i.ZERO)
	var replay_outcome: Dictionary = await _advance_coordinator_to_install()
	var replay_live: Dictionary = backend.call("installed_snapshot", slot)
	_check("complete_candidate_survives_owner_unload_and_replays_in_new_chunk_backend",
		unloaded_sections == 1 and recreated_backend_result.get("status") == "ready"
		and replay_queue_count == 1 and replay_outcome.get("status") == "installed"
		and int(replay_live.get("generation", 0)) == 2,
		{"unloadedSections":unloaded_sections, "recreatedBackend":recreated_backend_result.get("status"),
		"replayQueued":replay_queue_count, "replayOutcome":replay_outcome,
		"generation":replay_live.get("generation", 0)})
	_finish()


func _advance_coordinator_to_install() -> Dictionary:
	for frame_index in range(1200):
		var scheduled: Dictionary = coordinator.advance_queued_complete_section_candidates(1, 8)
		var results: Array = scheduled.get("results", [])
		var step: Dictionary = results[0] if not results.is_empty() else {"status":"idle"}
		if step.get("status") in ["installed", "failed", "cancelled"]:
			return step
		await process_frame
	return {"status":"failed", "reason":"headed_native_install_frame_budget_exceeded"}


func _assemble(generation: int, census: Dictionary) -> Dictionary:
	var contributions: Array = []
	for provider_id: String in ["terrain", "ordinary"]:
		var parts: Array = census.expectedContributorsBySection.get(SECTION, [])
		var part_id := ""
		for part_value: Variant in parts:
			if String(census.sourceProviderIds.get(String(part_value), "")) == provider_id:
				part_id = String(part_value)
		var inputs: Array = []
		var source_revision := {}
		if not part_id.is_empty():
			var revision := String(census.sourceRevisions.get(part_id, ""))
			inputs.append(_input(part_id, revision,
				Vector3(2.0 if provider_id == "terrain" else 4.0, 0.0, 2.0)))
			source_revision[part_id] = revision
		inputs.make_read_only()
		source_revision.make_read_only()
		var compat := {}
		var materials := {}
		var meshes := {}
		var resources := {}
		if not inputs.is_empty():
			compat[shared_batch_key] = shared_compatibility
			materials["contract:shared"] = shared_material
			meshes["contract:shared-mesh"] = shared_mesh
			resources[shared_batch_key] = {"material":shared_material,"mesh":shared_mesh}
		compat.make_read_only()
		materials.make_read_only()
		meshes.make_read_only()
		resources.make_read_only()
		var contribution := {"providerId":provider_id, "sectionKey":SECTION,
			"coverageRevision":String(census.providerCoverageRevisions[provider_id][SECTION]),
			"authorityRevision":String(census.providerSnapshotRevisions[provider_id]),
			"authoritySourceRevisions":source_revision, "inputs":inputs,
			"compatibilityByKey":compat, "materialBindings":materials,
			"meshBindings":meshes, "resourceBindings":resources}
		contribution.make_read_only()
		contributions.append(contribution)
	contributions.make_read_only()
	return Assembler.assemble(census, SECTION, contributions, generation)


func _input(part_id: String, revision: String, origin: Vector3) -> Dictionary:
	var values: Array[float] = []
	for value: float in Attributes.encode(Transform3D.IDENTITY, Color.WHITE):
		values.append(value)
	values.make_read_only()
	var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"sourceId":part_id, "sourcePartId":part_id, "sourceRevision":revision,
		"ownerCell":Grid.logical_owner_cell_for_world_position(origin),
		"sourceToWorld":Transform3D(Basis.IDENTITY, origin),
		"meshLocalBounds":shared_mesh.get_aabb(), "batchKey":shared_batch_key,
		"segmentId":part_id + ":mesh", "buffer":values, "instanceCount":1}
	input.make_read_only()
	return input


func _build_shared_batch() -> void:
	shared_mesh = ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, 0.0, -0.5), Vector3(0.5, 0.0, -0.5), Vector3(0.0, 0.0, 0.5)])
	shared_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	shared_material = StandardMaterial3D.new()
	shared_material.albedo_color = Color(0.25, 0.55, 0.35)
	var fingerprint: Dictionary = MeshFingerprint.inspect(shared_mesh)
	var resource := "contract:shared-mesh"
	var pipeline := "whole-section-native-install-v1"
	var mesh_key := "%s|pipeline=%s|layer=opaque|sort=none" % [resource, pipeline]
	var raw := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":"contract:shared", "renderTier":"detail",
		"meshResourceKey":resource, "meshKey":mesh_key,
		"meshContentDigest":String(fingerprint.get("contentDigest", "")),
		"meshLocalBounds":shared_mesh.get_aabb(), "pipelineRevision":pipeline,
		"renderLayer":"opaque", "translucentSortPolicy":"none",
		"castShadows":true, "visibilityRangeEnd":100.0, "fadeMargin":0.0}
	shared_batch_key = SnapshotBuilder.batch_compatibility_key(raw)
	raw["batchKey"] = shared_batch_key
	raw["compatibilityKey"] = shared_batch_key
	raw.make_read_only()
	shared_compatibility = raw


func _check(name: String, passed: bool, evidence: Variant) -> void:
	checks[name] = {"passed":passed, "evidence":evidence}


func _finish() -> void:
	var failed: Array[String] = []
	for name: String in checks:
		if not bool(checks[name].get("passed", false)):
			failed.append(name)
	var report := {"schema":"whole-section-candidate-native-install/v1",
		"complete":true, "passed":failed.is_empty(), "checks":checks,
		"checkCount":checks.size(), "failedChecks":failed,
		"evidenceLevel":"headed_synthetic_production_candidate_installed_by_native_chunk_renderer",
		"doesNotProve":"real terrain/building/ecology producer parity, gameplay collision/interactions, save/replay or world streaming performance."}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	quit(0 if failed.is_empty() else 1)

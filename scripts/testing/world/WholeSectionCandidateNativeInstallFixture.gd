extends SceneTree

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
	const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
	const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
	const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
	var world_id := ""
	var provider_id := ""
	var source_part_id := ""
	var source_revision := ""
	var mesh: Mesh
	var material: Material
	var batch_key := ""
	var compatibility: Dictionary

	func _current_source_revision() -> String:
		var mesh_report: Dictionary = MeshFingerprint.inspect(mesh)
		if mesh_report.get("status") != "ready" or not material is StandardMaterial3D:
			return ""
		return Marshalls.raw_to_base64(var_to_bytes([source_revision,
			String(mesh_report.get("contentDigest", "")),
			(material as StandardMaterial3D).albedo_color])).sha256_text()

	func capture_static_section_sources(request_world_id: String,
			section_keys: Array) -> Dictionary:
		if request_world_id != world_id or section_keys != [SECTION]:
			return {"status":"failed", "reason":"unexpected_fixture_census_query"}
		var ids: Array[String] = [source_part_id]
		ids.make_read_only()
		var row := {"status":"complete", "coverageRevision":provider_id + "-coverage-r1",
			"sourcePartIds":ids}
		row.make_read_only()
		var current_revision := _current_source_revision()
		if current_revision.is_empty():
			return {"status":"pending", "reason":"fixture_source_resource_unavailable", "retryable":true}
		var revisions := {source_part_id:current_revision}
		revisions.make_read_only()
		var sections := {SECTION:row}
		sections.make_read_only()
		var result := {"status":"complete", "worldId":world_id,
			"authorityRevision":provider_id + "-authority-r1",
			"sourceRevisions":revisions, "sections":sections}
		result.make_read_only()
		return result

	func capture_static_section_contribution(census: Dictionary,
			section_key: Vector3i) -> Dictionary:
		if census.get("status") != "complete" or census.get("worldId") != world_id \
				or section_key != SECTION or source_part_id not in \
				census.get("expectedContributorsBySection", {}).get(section_key, []):
			return {"status":"pending", "reason":"fixture_contribution_census_stale",
				"retryable":true}
		var current_revision := _current_source_revision()
		if current_revision.is_empty() or String(census.get("sourceRevisions", {}).get(
			source_part_id, "")) != current_revision:
			return {"status":"pending", "reason":"fixture_contribution_resource_stale",
				"retryable":true}
		var values: Array[float] = []
		for value: float in Attributes.encode(Transform3D.IDENTITY, Color.WHITE):
			values.append(value)
		values.make_read_only()
		var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
			"sourceId":source_part_id, "sourcePartId":source_part_id,
			"sourceRevision":current_revision,
			"ownerCell":Grid.logical_owner_cell_for_world_position(Vector3(2, 0, 2)),
			"sourceToWorld":Transform3D(Basis.IDENTITY, Vector3(2, 0, 2)),
			"meshLocalBounds":mesh.get_aabb(), "batchKey":batch_key,
			"segmentId":source_part_id + ":mesh", "buffer":values, "instanceCount":1}
		input.make_read_only()
		var inputs: Array[Dictionary] = [input]
		inputs.make_read_only()
		var revisions := {source_part_id:current_revision}
		revisions.make_read_only()
		var compatibility_map := {batch_key:compatibility}
		compatibility_map.make_read_only()
		var materials := {"contract:shared":material}
		materials.make_read_only()
		var meshes := {"contract:shared-mesh":mesh}
		meshes.make_read_only()
		var binding := {"material":material, "mesh":mesh}
		binding.make_read_only()
		var resources := {batch_key:binding}
		resources.make_read_only()
		var contribution := {"providerId":provider_id, "sectionKey":section_key,
			"coverageRevision":String(census.providerCoverageRevisions[provider_id][section_key]),
			"authorityRevision":String(census.providerSnapshotRevisions[provider_id]),
			"authoritySourceRevisions":revisions, "inputs":inputs,
			"compatibilityByKey":compatibility_map, "materialBindings":materials,
			"meshBindings":meshes, "resourceBindings":resources}
		contribution.make_read_only()
		return {"status":"ready", "contribution":contribution}


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
	terrain_provider.mesh = shared_mesh
	terrain_provider.material = shared_material
	terrain_provider.batch_key = shared_batch_key
	terrain_provider.compatibility = shared_compatibility
	var ordinary_provider := CensusProvider.new()
	ordinary_provider.world_id = WORLD
	ordinary_provider.provider_id = "ordinary"
	ordinary_provider.source_part_id = "ordinary:fixture:0"
	ordinary_provider.source_revision = "ordinary-r1"
	ordinary_provider.mesh = shared_mesh
	ordinary_provider.material = shared_material
	ordinary_provider.batch_key = shared_batch_key
	ordinary_provider.compatibility = shared_compatibility
	coordinator.register_source_provider("terrain", terrain_provider,
		"capture_static_section_sources")
	coordinator.register_source_provider("ordinary", ordinary_provider,
		"capture_static_section_sources")
	_check("real_native_section_backend_attached", attached.get("status") == "ready"
		and is_instance_valid(backend), attached)
	if not checks["real_native_section_backend_attached"].passed:
		_finish()
		return
	var first_admission: Dictionary = coordinator.assemble_and_submit_complete_section_candidate(
		SECTION, 1)
	var first_candidate: Dictionary = coordinator._production_candidate_jobs.get(SECTION, {}).get("candidate", {})
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
	var second_admission: Dictionary = coordinator.assemble_and_submit_complete_section_candidate(
		SECTION, 2)
	var second_candidate: Dictionary = coordinator._production_candidate_jobs.get(SECTION, {}).get("candidate", {})
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
	var third_admission: Dictionary = coordinator.assemble_and_submit_complete_section_candidate(
		SECTION, 3)
	var staged_advance: Dictionary = coordinator.advance_complete_section_candidate(SECTION, 1)
	var staged_job: Dictionary = coordinator._production_candidate_jobs.get(SECTION, {})
	var staged_session = staged_job.get("session")
	var staged_snapshot: Dictionary = backend.call("installed_snapshot", slot)
	var retained_root_id := int(staged_snapshot.get("rootInstanceId", 0))
	var began_stale_replacement: bool = third_admission.get("status") == "queued" \
		and staged_advance.get("status") == "pending" \
		and staged_session is RefCounted \
		and String(staged_session.get("state")) in ["append", "upload", "commit"] \
		and int(staged_snapshot.get("generation", 0)) == 2
	var original_mesh_digest := String(MeshFingerprint.inspect(shared_mesh).get("contentDigest", ""))
	_replace_shared_mesh_geometry(0.75)
	var stale_advance: Dictionary = coordinator.advance_complete_section_candidate(SECTION, 8)
	var retained_after_stale: Dictionary = backend.call("installed_snapshot", slot)
	_check("stale_authority_cancels_staged_replacement_and_retains_last_live_slot",
		began_stale_replacement
		and original_mesh_digest != String(MeshFingerprint.inspect(shared_mesh).get("contentDigest", ""))
		and stale_advance.get("status") == "pending"
		and bool(stale_advance.get("requiresReassembly", false))
		and int(retained_after_stale.get("generation", 0)) == 2
		and int(retained_after_stale.get("rootInstanceId", 0)) == retained_root_id,
		{"admission":third_admission, "stagedAdvance":staged_advance,
		"stagedState":staged_session.get("state") if staged_session is RefCounted else "missing",
		"resourceRevisionChanged":original_mesh_digest != String(MeshFingerprint.inspect(shared_mesh).get("contentDigest", "")),
		"advance":stale_advance, "retainedGeneration":retained_after_stale.get("generation", 0),
		"retainedRootId":retained_after_stale.get("rootInstanceId", 0),
		"previousRootId":retained_root_id})
	_replace_shared_mesh_geometry(0.5)
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


func _replace_shared_mesh_geometry(edge: float) -> void:
	shared_mesh.clear_surfaces()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-edge, 0.0, -0.5), Vector3(edge, 0.0, -0.5), Vector3(0.0, 0.0, 0.5)])
	shared_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


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

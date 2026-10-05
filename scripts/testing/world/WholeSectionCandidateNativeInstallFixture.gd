extends SceneTree

const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const PacketOwner := preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstallSession := preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const MainCoreScript := preload("res://scripts/MainCore.gd")
const RuntimeToolsScript := preload("res://scripts/MainRuntimeTools.gd")
const EcologyAdapterScript := preload("res://scripts/world/EcologySectionValueAdapter.gd")
const EcologyLedgerScript := preload("res://scripts/world/EcologySourceValueLedger.gd")
const TreeQueueScript := preload("res://scripts/environment/TreePublicationQueue.gd")
const REPORT_ENV := "VOXEL_WHOLE_SECTION_NATIVE_INSTALL_REPORT"
const LIFECYCLE_REPORT_ENV := "VOXEL_NATIVE_SECTION_LIFECYCLE_REPORT"
const WORLD := "seed:whole-section-tree-install:909"
const SECTION := Vector3i.ZERO

var report_path := ""
var checks: Dictionary = {}
var shared_mesh: ArrayMesh
var shared_material: StandardMaterial3D
var shared_compatibility: Dictionary
var shared_batch_key := ""
var coordinator
var lifecycle_exit_code := 1


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
	var install_acknowledgement_count := 0
	var release_call_count := 0
	var release_attempts_by_digest: Dictionary = {}

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

	func acknowledge_section_install(section_key: Vector3i,
			coverage_revision: String, receipt: Dictionary) -> Dictionary:
		if section_key != SECTION or coverage_revision != provider_id + "-coverage-r1" \
				or not receipt.is_read_only() or receipt.get("status") != "installed":
			return {"status":"failed", "reason":"fixture_install_ack_identity_mismatch"}
		install_acknowledgement_count += 1
		return {"status":"acknowledged", "providerId":provider_id,
			"generation":int(receipt.get("generation", 0))}

	func release_section_install(section_key: Vector3i,
			coverage_revision: String, receipt: Dictionary) -> Dictionary:
		if section_key != SECTION or coverage_revision != provider_id + "-coverage-r1" \
				or not receipt.is_read_only() or receipt.get("status") != "installed":
			return {"status":"failed", "reason":"fixture_release_identity_mismatch"}
		release_call_count += 1
		var digest := String(receipt.get("contentManifestDigest", ""))
		var attempt := int(release_attempts_by_digest.get(digest, 0)) + 1
		release_attempts_by_digest[digest] = attempt
		if attempt == 1:
			return {"status":"pending", "retryable":true,
				"reason":"fixture_release_pending_once", "attempt":attempt}
		return {"status":"acknowledged", "released":true,
			"providerId":provider_id, "attempt":attempt}


class FrameCallbackProbe extends RefCounted:
	var state := "awaiting_frame"
	var _presentation_token := ""
	var accepted_tokens: Array[String] = []

	func accept_frame_drawn_callback(token: String) -> bool:
		if state != "awaiting_frame" or token != _presentation_token:
			return false
		accepted_tokens.append(token)
		return true


class ExplicitEmptyProvider extends RefCounted:
	const SECTION_KEY := Vector3i.ZERO
	var world_id := ""
	var provider_id := "explicit-empty"
	var census_pending := false
	var install_acknowledgement_count := 0
	var release_count := 0

	func capture_static_section_sources(request_world_id: String,
			section_keys: Array) -> Dictionary:
		if request_world_id != world_id or section_keys != [SECTION_KEY]:
			return {"status":"failed", "reason":"unexpected_empty_fixture_census"}
		if census_pending:
			return {"status":"pending", "reason":"fixture_census_pending",
				"retryable":true}
		var members: Array[String] = []
		members.make_read_only()
		var row := {"status":"empty", "coverageRevision":"explicit-empty-r1",
			"sourcePartIds":members}
		row.make_read_only()
		var sections := {SECTION_KEY:row}
		sections.make_read_only()
		var revisions := {}
		revisions.make_read_only()
		var result := {"status":"complete", "worldId":world_id,
			"authorityRevision":"explicit-empty-authority-r1",
			"sourceRevisions":revisions, "sections":sections}
		result.make_read_only()
		return result

	func capture_static_section_contribution(census: Dictionary,
			section_key: Vector3i) -> Dictionary:
		if census.get("status") != "complete" or census.get("worldId") != world_id \
				or section_key != SECTION_KEY \
				or census.get("expectedContributorsBySection", {}).get(section_key, []) != []:
			return {"status":"pending", "reason":"empty_fixture_census_stale",
				"retryable":true}
		var empty_revisions := {}
		empty_revisions.make_read_only()
		var inputs: Array[Dictionary] = []
		inputs.make_read_only()
		var compatibility := {}
		compatibility.make_read_only()
		var materials := {}
		materials.make_read_only()
		var meshes := {}
		meshes.make_read_only()
		var empty_contributors: Array[Dictionary] = []
		empty_contributors.make_read_only()
		var contribution := {"providerId":provider_id,
			"sectionKey":section_key,
			"coverageRevision":String(census.providerCoverageRevisions[provider_id][section_key]),
			"authorityRevision":String(census.providerSnapshotRevisions[provider_id]),
			"authoritySourceRevisions":empty_revisions, "inputs":inputs,
			"compatibilityByKey":compatibility, "materialBindings":materials,
			"meshBindings":meshes, "explicitEmptyContributors":empty_contributors}
		contribution.make_read_only()
		return {"status":"ready", "contribution":contribution}

	func acknowledge_section_install(section_key: Vector3i,
			coverage_revision: String, receipt: Dictionary) -> Dictionary:
		if section_key != SECTION_KEY or coverage_revision != "explicit-empty-r1" \
				or not receipt.is_read_only() or receipt.get("status") != "installed":
			return {"status":"failed", "reason":"empty_fixture_ack_identity_mismatch"}
		install_acknowledgement_count += 1
		return {"status":"acknowledged", "providerId":provider_id,
			"generation":int(receipt.get("generation", 0))}

	func release_section_install(section_key: Vector3i,
			coverage_revision: String, receipt: Dictionary) -> Dictionary:
		if section_key != SECTION_KEY or coverage_revision != "explicit-empty-r1" \
				or not receipt.is_read_only() or receipt.get("status") != "installed":
			return {"status":"failed", "reason":"empty_fixture_release_identity_mismatch"}
		release_count += 1
		return {"status":"acknowledged", "released":true}


class WorldRoot extends Node3D:
	var chunk_owner: Node3D
	var backend: Node3D
	var seed_text := "whole-section-tree-install"
	var seed_hash := 909
	var removed_props: Dictionary = {}
	var removed_props_revision := 0
	var terrain_revision := 0
	var chunks: Dictionary = {}
	var tree_publication_queue: Node
	var world_static_section_coordinator: Variant

	func detail_mesh(_detail_type: String) -> Mesh: return BoxMesh.new()
	func detail_material(_detail_type: String) -> Material: return StandardMaterial3D.new()
	func _ecology_chunk_source_revision(key: Vector2i) -> String:
		return "ecology-r1:%d,%d" % [key.x, key.y]
	func terrain_volume_chunk_revision(_key: Vector2i, _chunk_size: int) -> int:
		return terrain_revision
	func visible_world_underground_visuals_required() -> bool: return false

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
	world.chunks[Vector2i.ZERO] = chunk
	chunk.set_meta("static_ecology_render_resource_bindings", {})
	var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
	var backend: Node3D = attached.get("backend") as Node3D
	world.chunk_owner = chunk
	world.backend = backend
	if OS.get_environment("VOXEL_WHOLE_SECTION_NATIVE_LIFECYCLE_ONLY") == "1":
		await _run_synthetic_presentation_lifecycle(world, chunk, backend, attached)
		# The lifecycle report already owns a serialized snapshot. Drop the
		# evidence graph and every producer/backend alias before asking Godot to
		# exit, so the native renderer's Nodes, RIDs and Resources can be released.
		checks.clear()
		coordinator = null
		shared_mesh = null
		shared_material = null
		shared_compatibility = {}
		shared_batch_key = ""
		world.world_static_section_coordinator = null
		world.chunks.clear()
		world.chunk_owner = null
		world.backend = null
		current_scene = null
		attached.clear()
		backend = null
		chunk = null
		var teardown_world := world
		world = null
		teardown_world.free()
		teardown_world = null
		await process_frame
		await RenderingServer.frame_post_draw
		quit(lifecycle_exit_code)
		return
	var production_tree := _prepare_production_tree(world, chunk)
	if production_tree.get("status") != "ready":
		_check("production_tree_recipe_source_prepared", false, production_tree)
		_finish()
		return
	var production_tree_queue: Variant = production_tree.get("queue")
	var production_tree_body: StaticBody3D = production_tree.get("body")
	var compiled_tree_record: Dictionary = {}
	for frame_index in range(600):
		compiled_tree_record = production_tree_queue.compiled_tree_section_record_for_body(
			production_tree_body)
		if not compiled_tree_record.is_empty():
			break
		await process_frame
	_check("production_tree_queue_compiles_through_its_bounded_frame_lane",
		not compiled_tree_record.is_empty()
		and int(compiled_tree_record.get("bodyInstanceId", 0)) == production_tree_body.get_instance_id()
		and int(production_tree_queue.get("tree_section_compile_completed_count")) == 1,
		{"compiledRecordPresent":not compiled_tree_record.is_empty(),
			"queueMetrics":production_tree_queue.metrics()})
	if compiled_tree_record.is_empty():
		_finish()
		return
	coordinator = Coordinator.new()
	coordinator.configure(WORLD)
	world.world_static_section_coordinator = coordinator
	var required_providers: Array[String] = ["terrain", "ordinary", EcologyAdapterScript.PROVIDER_ID]
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
	var ecology_provider := EcologyAdapterScript.new()
	ecology_provider.configure(WORLD)
	ecology_provider.bind_main_authority(world)
	coordinator.register_source_provider(EcologyAdapterScript.PROVIDER_ID, ecology_provider,
		"capture_static_section_sources")
	_check("real_native_section_backend_attached", attached.get("status") == "ready"
		and is_instance_valid(backend), attached)
	if not checks["real_native_section_backend_attached"].passed:
		_finish()
		return
	var current_tree_census: Dictionary = ecology_provider.capture_static_section_sources(WORLD,
		[SECTION])
	var tree_source_id := String(production_tree.get("sourceId", ""))
	_check("production_ecology_census_sees_current_compiled_tree_owner",
		current_tree_census.get("status") == "complete" \
		and tree_source_id in current_tree_census.get("sections", {}).get(SECTION, {}).get("sourcePartIds", [])
		and current_tree_census.get("sections", {}).get(SECTION, {}).get("status") == "complete",
		{"censusStatus":current_tree_census.get("status", ""),
			"reason":current_tree_census.get("reason", ""),
			"section":current_tree_census.get("sections", {}).get(SECTION, {}),
			"treeSourceId":tree_source_id})
	var first_admission: Dictionary = coordinator.assemble_and_submit_complete_section_candidate(
		SECTION, 1)
	var first_candidate: Dictionary = coordinator._production_candidate_jobs.get(SECTION, {}).get("candidate", {})
	_check("candidate_admission_exposes_phase_timings",
		_candidate_phase_timings_are_complete(first_admission),
		first_admission.get("phaseUsec", {}))
	_check("production_candidate_enters_native_install_session",
		first_admission.get("status") == "queued", first_admission)
	var first_snapshot: Dictionary = first_candidate.get("candidate", {}).get("snapshot", {})
	var first_manifest_ids: Array[String] = []
	for row_value: Variant in first_snapshot.get("manifest", []):
		if row_value is Dictionary:
			first_manifest_ids.append(String(row_value.get("sourcePartId", "")))
	_check("production_tree_candidate_is_in_exact_assembled_manifest",
		first_admission.get("status") == "queued" and not tree_source_id.is_empty() \
		and first_manifest_ids.has(tree_source_id)
		and String(first_candidate.get("evidenceLevel", "")) == "complete_authoritative_section_candidate",
		{"sourceId":tree_source_id, "manifestSourceIds":first_manifest_ids,
			"candidateSourceRevisions":first_candidate.get("sourceRevisions", {})})
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
	var reset_with_live_receipt: Dictionary = coordinator.reset_for_world("next-world")
	_check("world_reset_preserves_current_live_install",
		reset_with_live_receipt.get("status") == "failed"
		and String(coordinator.get("_world_id")) == WORLD
		and coordinator.installed_section_receipt_is_current(SECTION,
			coordinator._production_candidate_receipts.get(SECTION, {})),
		{"reset":reset_with_live_receipt, "worldId":coordinator.get("_world_id"),
		"receiptRetained":coordinator._production_candidate_receipts.has(SECTION)})
	var exact_tree_sections_query: Array[Vector3i] = [SECTION]
	var no_compiled_tree_sections: Array[Vector3i] = []
	var expected_tree_source_revision := String(
		Coordinator._section_candidate_source_revisions(first_candidate).get(tree_source_id, ""))
	var exact_tree_install: Dictionary = coordinator.startup_source_install_diagnostics(
		tree_source_id, exact_tree_sections_query, expected_tree_source_revision)
	var exact_tree_sections: Array = exact_tree_install.get("sections", [])
	var exact_tree_section: Dictionary = exact_tree_sections[0] if not exact_tree_sections.is_empty() else {}
	var missing_tree_install: Dictionary = coordinator.startup_source_install_diagnostics(
		"seed:missing-tree:tree:absent", exact_tree_sections_query,
		expected_tree_source_revision)
	var stale_tree_revision: Dictionary = coordinator.startup_source_install_diagnostics(
		tree_source_id, exact_tree_sections_query, "stale-tree-source-revision")
	var empty_tree_install: Dictionary = coordinator.startup_source_install_diagnostics(
		tree_source_id, no_compiled_tree_sections)
	_check("exact_source_id_query_joins_installed_candidate_and_current_native_receipt",
		exact_tree_install.get("status") == "queried" \
		and exact_tree_install.get("exactSectionQuery", false) \
		and exact_tree_section.get("sourcePresentInCandidate", false) \
		and exact_tree_section.get("admitted", false) \
		and exact_tree_section.get("sourceRevisionMatch", false) \
		and exact_tree_section.get("receiptCurrent", false) \
		and int(exact_tree_section.get("receiptGeneration", 0)) == 1,
		{"query":exact_tree_install, "sourceId":tree_source_id})
	_check("exact_install_query_fails_closed_for_missing_source_or_section_keys",
		missing_tree_install.get("sections", []).size() == 1 \
		and not missing_tree_install.sections[0].get("sourcePresentInCandidate", true) \
		and not missing_tree_install.sections[0].get("receiptCurrent", true) \
		and stale_tree_revision.get("sections", []).size() == 1 \
		and not stale_tree_revision.sections[0].get("sourceRevisionMatch", true) \
		and stale_tree_revision.sections[0].get("sourceRevisionMismatchReason", "") \
			== "candidate_source_revision_mismatch" \
		and not stale_tree_revision.sections[0].get("receiptCurrent", true) \
		and empty_tree_install.get("status") == "unresolved_no_compiled_sections" \
		and empty_tree_install.get("sections", []).is_empty(),
		{"missingSource":missing_tree_install, "emptySections":empty_tree_install})
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
	var pending_swap: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var old_provider_ack_count := terrain_provider.install_acknowledgement_count
	_check("replacement_waits_for_frame_with_prior_root_retained_and_provider_ack_deferred",
		replacement_outcome.get("status") == "pending" \
		and replacement_outcome.get("stage") == "awaiting_frame" \
		and pending_swap.get("status") == "pending_presentation" \
		and int(pending_swap.get("generation", 0)) == 2 \
		and int(pending_swap.get("previousGeneration", 0)) == 1 \
		and int(pending_swap.get("previousRootInstanceId", 0)) \
			== int(before_commit.get("rootInstanceId", 0)) \
		and not bool(backend.call("receipt_installed", slot, 2,
			"%s:%d" % [WORLD, 2], String(second_candidate.get("contentManifestDigest", "")))) \
		and terrain_provider.install_acknowledgement_count == old_provider_ack_count \
		and ordinary_provider.install_acknowledgement_count == old_provider_ack_count,
		{"outcome":replacement_outcome, "pendingPresentation":pending_swap,
			"priorReceiptGeneration":before_commit.get("generation", 0),
			"terrainAckCount":terrain_provider.install_acknowledgement_count,
			"ordinaryAckCount":ordinary_provider.install_acknowledgement_count})
	await process_frame
	replacement_outcome = coordinator.advance_complete_section_candidate(SECTION, 8)
	var after_commit: Dictionary = backend.call("installed_snapshot", slot)
	_check("replacement_finalizes_after_global_frame_ack_and_then_acks_providers",
		replacement_outcome.get("status") == "installed" \
		and after_commit.get("status") == "ready" \
		and int(after_commit.get("generation", 0)) == 2 \
		and int(after_commit.get("instanceCount", 0)) > 0 \
		and bool(backend.call("receipt_installed", slot, 2,
			"%s:%d" % [WORLD, 2], String(second_candidate.get("contentManifestDigest", "")))) \
		and terrain_provider.install_acknowledgement_count == old_provider_ack_count + 1 \
		and ordinary_provider.install_acknowledgement_count == old_provider_ack_count + 1,
		{"outcome":replacement_outcome, "installed":after_commit,
			"terrainAckCount":terrain_provider.install_acknowledgement_count,
			"ordinaryAckCount":ordinary_provider.install_acknowledgement_count})
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
	var pending_release: Dictionary = coordinator._pending_source_releases.get(SECTION, {})
	var retained_receipt_during_release: Dictionary = coordinator._production_candidate_receipts.get(SECTION, {})
	var retained_snapshot_during_release: Dictionary = backend.call("installed_snapshot", slot)
	_check("pending_provider_release_keeps_receipt_and_last_native_slot",
		unloaded_sections == 1 and not pending_release.is_empty()
		and not retained_receipt_during_release.is_empty()
		and int(retained_receipt_during_release.get("generation", 0)) == 2
		and int(retained_snapshot_during_release.get("generation", 0)) == 2,
		{"unloadedSections":unloaded_sections,
		"pendingRelease":pending_release,
		"retainedReceiptGeneration":retained_receipt_during_release.get("generation", 0),
		"retainedNativeGeneration":retained_snapshot_during_release.get("generation", 0)})
	var loaded_while_release_pending: int = coordinator.notify_stream_chunk_loaded(Vector2i.ZERO)
	var pending_after_load: Dictionary = coordinator._pending_source_releases.get(SECTION, {})
	var unloaded_again: int = coordinator.notify_stream_chunk_unloaded(Vector2i.ZERO,
		old_chunk_instance_id)
	var pending_after_second_unload: Dictionary = coordinator._pending_source_releases.get(SECTION, {})
	_check("unload_cancels_replay_requested_during_pending_release",
		loaded_while_release_pending == 0 and unloaded_again == 1
		and bool(pending_after_load.get("reloadPending", false))
		and not bool(pending_after_second_unload.get("reloadPending", true)),
		{"loadedWhilePending":loaded_while_release_pending,
		"unloadedAgain":unloaded_again,
		"reloadPendingAfterLoad":pending_after_load.get("reloadPending", false),
		"reloadPendingAfterUnload":pending_after_second_unload.get("reloadPending", true)})
	await process_frame
	await process_frame
	var release_drain: Dictionary = coordinator.advance_queued_complete_section_candidates(1, 8)
	var release_results: Array = release_drain.get("releases", [])
	var release_row: Dictionary = release_results[0] if not release_results.is_empty() else {}
	_check("exact_provider_release_retries_then_clears_receipt_before_owner_replay",
		release_row.get("status", "") == "released"
		and terrain_provider.release_call_count >= 2
		and ordinary_provider.release_call_count >= 2
		and not coordinator._production_candidate_receipts.has(SECTION)
		and not coordinator._production_candidate_jobs.has(SECTION)
		and int(backend.call("installed_snapshot", slot).get("generation", 0)) == 2,
		{"releaseDrain":release_drain,
		"terrainReleaseCalls":terrain_provider.release_call_count,
		"ordinaryReleaseCalls":ordinary_provider.release_call_count,
		"receiptStillPresent":coordinator._production_candidate_receipts.has(SECTION),
		"nativeGeneration":backend.call("installed_snapshot", slot).get("generation", 0)})
	world.chunks.erase(Vector2i.ZERO)
	world.remove_child(chunk)
	chunk.free()
	var recreated_chunk := Node3D.new()
	recreated_chunk.name = "Chunk_0_0"
	world.add_child(recreated_chunk)
	world.chunks[Vector2i.ZERO] = recreated_chunk
	recreated_chunk.set_meta("static_ecology_render_resource_bindings", {})
	var replay_snapshot: Dictionary = production_tree.get("snapshot", {}).duplicate(true)
	replay_snapshot["producerOwnerInstanceId"] = recreated_chunk.get_instance_id()
	recreated_chunk.set_meta("static_ecology_source_value_snapshot", replay_snapshot)
	var recreated_backend_result: Dictionary = PacketOwner.attach_to_chunk(recreated_chunk)
	backend = recreated_backend_result.get("backend") as Node3D
	world.chunk_owner = recreated_chunk
	world.backend = backend
	var replay_queue_count: int = coordinator.notify_stream_chunk_loaded(Vector2i.ZERO)
	var replay_status_after_queue: Dictionary = coordinator.status()
	var replay_job_after_queue: Dictionary = coordinator._production_candidate_jobs.get(SECTION, {})
	var replay_outcome: Dictionary = await _advance_coordinator_to_install()
	var replay_live: Dictionary = backend.call("installed_snapshot", slot)
	_check("complete_candidate_survives_owner_unload_and_replays_in_new_chunk_backend",
		unloaded_sections == 1 and recreated_backend_result.get("status") == "ready"
		and replay_queue_count == 1 and replay_outcome.get("status") == "installed"
		and int(replay_live.get("generation", 0)) == 3
		and bool(replay_outcome.get("staleReplayAttempt", {}).get("requiresReassembly", false))
		and replay_outcome.get("reassemblyAdmission", {}).get("status") == "queued"
		and terrain_provider.install_acknowledgement_count >= 3
		and ordinary_provider.install_acknowledgement_count >= 3,
		{"unloadedSections":unloaded_sections, "recreatedBackend":recreated_backend_result.get("status"),
		"replayQueued":replay_queue_count, "replayStatusAfterQueue":replay_status_after_queue,
		"replayJobAfterQueue":replay_job_after_queue,
		"replayOutcome":replay_outcome,
		"generation":replay_live.get("generation", 0),
		"terrainInstallAcknowledgements":terrain_provider.install_acknowledgement_count,
		"ordinaryInstallAcknowledgements":ordinary_provider.install_acknowledgement_count})
	var empty_coordinator = Coordinator.new()
	empty_coordinator.configure(WORLD)
	empty_coordinator.configure_source_roster(["explicit-empty"])
	var empty_provider := ExplicitEmptyProvider.new()
	empty_provider.world_id = WORLD
	empty_coordinator.register_source_provider("explicit-empty", empty_provider,
		"capture_static_section_sources")
	var generation_three_snapshot: Dictionary = backend.call("installed_snapshot", slot)
	var empty_admission: Dictionary = empty_coordinator.assemble_and_submit_complete_section_candidate(
		SECTION, 10)
	var empty_pending_outcome: Dictionary = {"status":"not_started"}
	for frame_index in range(1200):
		empty_pending_outcome = empty_coordinator.advance_complete_section_candidate(SECTION, 8)
		if empty_pending_outcome.get("stage") == "awaiting_frame":
			break
		if empty_pending_outcome.get("status") in ["failed", "cancelled"]:
			break
		await process_frame
	var empty_pending: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var empty_layers: Array = empty_pending.get("layers", [])
	_check("explicit_empty_candidate_retains_previous_nonempty_root_until_frame_ack",
		empty_admission.get("status") == "queued" \
		and empty_pending_outcome.get("status") == "pending" \
		and empty_pending_outcome.get("stage") == "awaiting_frame" \
		and empty_pending.get("status") == "pending_presentation" \
		and int(empty_pending.get("generation", 0)) == 10 \
		and int(empty_pending.get("instanceCount", -1)) == 0 \
		and int(empty_pending.get("previousGeneration", 0)) == 3 \
		and int(empty_pending.get("previousRootInstanceId", 0)) \
			== int(generation_three_snapshot.get("rootInstanceId", 0)) \
		and empty_layers.size() == 3 \
		and empty_layers.all(func(layer: Dictionary) -> bool:
			return layer.get("status", "") == "empty" \
				and int(layer.get("expectedBatchCount", -1)) == 0 \
				and int(layer.get("expectedInstanceCount", -1)) == 0) \
		and empty_provider.install_acknowledgement_count == 0,
		{"admission":empty_admission, "pendingOutcome":empty_pending_outcome,
		"pendingPresentation":empty_pending,
		"previousNonemptyRoot":generation_three_snapshot.get("rootInstanceId", 0),
		"providerAckCount":empty_provider.install_acknowledgement_count})
	await process_frame
	var empty_install_outcome: Dictionary = empty_coordinator.advance_complete_section_candidate(
		SECTION, 8)
	var installed_empty: Dictionary = backend.call("installed_snapshot", slot)
	_check("explicit_empty_manifest_finalizes_and_acknowledges_after_frame",
		empty_install_outcome.get("status") == "installed" \
		and installed_empty.get("status") == "ready" \
		and int(installed_empty.get("generation", 0)) == 10 \
		and int(installed_empty.get("instanceCount", -1)) == 0 \
		and installed_empty.get("layers", []).size() == 3 \
		and installed_empty.get("layers", []).all(func(layer: Dictionary) -> bool:
			return layer.get("status", "") == "empty") \
		and empty_provider.install_acknowledgement_count == 1 \
		and backend.call("pending_presentation_snapshot", slot).get("status") == "missing",
		{"outcome":empty_install_outcome, "installedEmpty":installed_empty,
		"providerAckCount":empty_provider.install_acknowledgement_count})
	var empty_root_id := int(installed_empty.get("rootInstanceId", 0))
	var cancelled_empty_admission: Dictionary = empty_coordinator.assemble_and_submit_complete_section_candidate(
		SECTION, 11)
	var cancelled_pending_outcome: Dictionary = {"status":"not_started"}
	for frame_index in range(1200):
		cancelled_pending_outcome = empty_coordinator.advance_complete_section_candidate(SECTION, 8)
		if cancelled_pending_outcome.get("stage") == "awaiting_frame":
			break
		if cancelled_pending_outcome.get("status") in ["failed", "cancelled"]:
			break
		await process_frame
	empty_provider.census_pending = true
	var pending_census_outcome: Dictionary = empty_coordinator.advance_complete_section_candidate(
		SECTION, 8)
	var census_rollback_snapshot: Dictionary = backend.call("installed_snapshot", slot)
	_check("unavailable_provider_census_rolls_back_promoted_candidate_before_pending_return",
		cancelled_pending_outcome.get("stage") == "awaiting_frame" \
		and pending_census_outcome.get("status") == "pending" \
		and pending_census_outcome.get("stage") == "source_census" \
		and pending_census_outcome.get("reason") == "static_source_provider_pending" \
		and pending_census_outcome.get("providerReason") == "fixture_census_pending" \
		and pending_census_outcome.get("requiresReassembly", false) \
		and backend.call("pending_presentation_snapshot", slot).get("status") == "missing" \
		and census_rollback_snapshot.get("status") == "ready" \
		and int(census_rollback_snapshot.get("generation", 0)) == 10 \
		and int(census_rollback_snapshot.get("rootInstanceId", 0)) == empty_root_id,
		{"pendingPresentationOutcome":cancelled_pending_outcome,
		"censusOutcome":pending_census_outcome,
		"censusPendingProvider":pending_census_outcome.get("providerId", ""),
		"restoredSlot":census_rollback_snapshot,
		"expectedRootId":empty_root_id})
	empty_provider.census_pending = false
	var unload_admission: Dictionary = empty_coordinator.assemble_and_submit_complete_section_candidate(
		SECTION, 12)
	var unload_pending_outcome: Dictionary = {"status":"not_started"}
	for frame_index in range(1200):
		unload_pending_outcome = empty_coordinator.advance_complete_section_candidate(SECTION, 8)
		if unload_pending_outcome.get("stage") == "awaiting_frame":
			break
		if unload_pending_outcome.get("status") in ["failed", "cancelled"]:
			break
		await process_frame
	# The coordinator is the stable callback target and remains alive through
	# callback delivery even after unload releases the install-session job.
	var callback_metrics_before: Dictionary = \
		empty_coordinator.frame_presentation_callback_diagnostics()
	var pending_unload_job: Dictionary = empty_coordinator._production_candidate_jobs.get(SECTION, {})
	var pending_unload_session: Variant = pending_unload_job.get("session")
	var pending_unload_token := String(pending_unload_session.get("_presentation_token")) \
		if pending_unload_session is RefCounted else ""
	var pending_unload_session_ref: WeakRef = weakref(self)
	if pending_unload_session is RefCounted:
		pending_unload_session_ref = weakref(pending_unload_session)
	var unloaded_pending_section_count: int = empty_coordinator.notify_stream_chunk_unloaded(
		Vector2i.ZERO, recreated_chunk.get_instance_id())
	var job_after_pending_unload: Dictionary = empty_coordinator._production_candidate_jobs.get(
		SECTION, {})
	var tombstoned_callback: Dictionary = empty_coordinator._pending_frame_presentations.get(
		pending_unload_token, {})
	var callback_retained_released_session: bool = pending_unload_session is RefCounted \
		and tombstoned_callback.get("session") == pending_unload_session \
		and bool(tombstoned_callback.get("cancelled", false))
	pending_unload_session = null
	pending_unload_job.clear()
	tombstoned_callback.clear()
	var callback_metrics_after := callback_metrics_before.duplicate(false)
	for frame_index in range(4):
		await process_frame
		callback_metrics_after = empty_coordinator.frame_presentation_callback_diagnostics()
		if int(callback_metrics_after.get("cancelledCallbackCount", 0)) \
				> int(callback_metrics_before.get("cancelledCallbackCount", 0)):
			break
	var released_session_after_callback := pending_unload_session_ref != null \
		and pending_unload_session_ref.get_ref() == null
	var empty_after_cancel: Dictionary = backend.call("installed_snapshot", slot)
	_check("unload_cancels_pending_empty_swap_and_stale_callback_is_ignored",
		unload_admission.get("status") == "queued" \
		and unload_pending_outcome.get("status") == "pending" \
		and unload_pending_outcome.get("stage") == "awaiting_frame" \
		and unloaded_pending_section_count == 1 \
		and job_after_pending_unload.is_empty() \
		and callback_retained_released_session \
		and int(callback_metrics_after.get("cancelledCallbackCount", 0)) \
			> int(callback_metrics_before.get("cancelledCallbackCount", 0)) \
		and int(callback_metrics_after.get("pendingCallbackCount", -1)) \
			== int(callback_metrics_before.get("pendingCallbackCount", -1)) - 1 \
		and released_session_after_callback \
		and backend.call("pending_presentation_snapshot", slot).get("status") == "missing" \
		and empty_after_cancel.get("status") == "ready" \
		and int(empty_after_cancel.get("generation", 0)) == 10 \
		and int(empty_after_cancel.get("rootInstanceId", 0)) == empty_root_id \
		and empty_provider.install_acknowledgement_count == 1 \
		and empty_provider.release_count == 1,
		{"admission":cancelled_empty_admission,
		"admissionAfterCensusRollback":unload_admission,
		"pendingOutcome":unload_pending_outcome,
		"unloadedPendingSectionCount":unloaded_pending_section_count,
		"callbackRetainedReleasedSession":callback_retained_released_session,
		"callbackMetricsBefore":callback_metrics_before,
		"callbackMetricsAfter":callback_metrics_after,
		"pendingCallbackToken":pending_unload_token,
		"releasedSessionAfterCallback":released_session_after_callback,
		"restoredSlot":empty_after_cancel,
		"expectedRootId":empty_root_id,
		"providerAckCount":empty_provider.install_acknowledgement_count,
		"providerReleaseCount":empty_provider.release_count})
	_finish()
func _candidate_phase_timings_are_complete(admission: Dictionary) -> bool:
	var phases: Variant = admission.get("phaseUsec", null)
	if not phases is Dictionary:
		return false
	for name in ["census", "contributions", "assembly", "submit_and_revalidate"]:
		var elapsed: Variant = phases.get(name, null)
		if not elapsed is int or elapsed < 0:
			return false
	return true


func _prepare_production_tree(world: WorldRoot, chunk: Node3D) -> Dictionary:
	var queue: Node = TreeQueueScript.new()
	queue.name = "TreePublicationQueue"
	world.add_child(queue)
	world.tree_publication_queue = queue
	queue.call("set_section_owned_publication_enabled", true)
	var prop_id := "native-install-tree-0"
	var body := StaticBody3D.new()
	body.name = "Tree_%s" % prop_id
	body.set_meta("prop_id", prop_id)
	body.set_meta("static_ecology_source_id", "%s:tree:%s" % [world.seed_text, prop_id])
	body.position = Vector3(8.0, 8.0, 8.0)
	body.add_to_group("generated_tree_trunks")
	world.add_child(body)
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 8.0
	collision.shape = capsule
	collision.position.y = 4.0
	body.add_child(collision)
	var request := {"treeId":prop_id, "worldSeed":world.seed_text,
		"biome":"forest", "architecture":"broadleaf", "speciesGrammar":"bushy_oak",
		"renderLodTier":"near", "treeWorldPosition":body.global_position,
		"visualHeight":8.0, "trunkRadius":0.4, "canopyRadius":4.0,
		"canopyDensity":0.6, "geneticSeed":7281}
	var recipe: Dictionary = queue.get("publication_service").build_recipe(request)
	if recipe.is_empty():
		return {"status":"failed", "reason":"canonical_tree_recipe_unavailable"}
	var record_result: Dictionary = queue.call("build_tree_section_recipe_input_record",
		{"request":request, "enqueueSequence":1}, body, recipe)
	if record_result.get("status") != "ready":
		return {"status":"failed", "reason":"tree_recipe_artifact_capture_failed",
			"detail":record_result}
	var retained: Dictionary = queue.call("retain_tree_section_recipe_input_record",
		record_result.record)
	if retained.get("status") != "retained":
		return {"status":"failed", "reason":"tree_recipe_artifact_retention_failed",
			"detail":retained}
	var revision := world._ecology_chunk_source_revision(Vector2i.ZERO)
	var ledger = EcologyLedgerScript.new()
	ledger.configure(world.seed_text, Vector2i.ZERO, revision,
		world.removed_props_revision, world.terrain_revision)
	var tree_candidate := {"sourceId":"%s:tree:%s" % [world.seed_text, prop_id],
		"propId":prop_id, "kind":"trees_foliage", "renderLayers":["opaque"],
		"materials":["tree_recipe"], "transform":Transform3D(Basis.IDENTITY, body.global_position),
		"localBounds":AABB(Vector3(-8.0, 0.0, -8.0), Vector3(16.0, 24.0, 16.0)),
		"shadowCasting":"on", "visibilityRangeEnd":0.0}
	if not ledger.record_candidate(tree_candidate):
		return {"status":"failed", "reason":"tree_candidate_ledger_rejected"}
	var complete_provenance := {"sourceRevision":revision, "chunk":Vector2i.ZERO,
		"terrainRevision":world.terrain_revision, "producerComplete":true,
		"scanRevision":"underground-static-scan-r1"}
	for category: String in ["surface_rocks", "ore", "forage", "underground_props"]:
		if not ledger.mark_category_complete(category, complete_provenance):
			return {"status":"failed", "reason":"ecology_category_completion_rejected",
				"category":category}
	var snapshot: Dictionary = ledger.snapshot()
	snapshot["producerOwnerInstanceId"] = chunk.get_instance_id()
	snapshot["status"] = "finalized"
	chunk.set_meta("static_ecology_source_value_snapshot", snapshot)
	return {"status":"ready", "sourceId":String(tree_candidate.sourceId),
		"propId":prop_id, "queue":queue, "body":body,
		"recipeRecord":record_result.record,
		"snapshot":snapshot,
		"snapshotContentRevision":String(snapshot.get("contentRevision", ""))}


func _advance_coordinator_to_install() -> Dictionary:
	var last_step: Dictionary = {"status":"idle"}
	var stale_replay_attempt: Dictionary = {}
	var reassembly_admission: Dictionary = {}
	for frame_index in range(1200):
		var scheduled: Dictionary = coordinator.advance_queued_complete_section_candidates(1, 8)
		var results: Array = scheduled.get("results", [])
		last_step = results[0] if not results.is_empty() else {"status":"idle"}
		if last_step.get("status") in ["installed", "failed", "cancelled"]:
			if not stale_replay_attempt.is_empty():
				last_step["staleReplayAttempt"] = stale_replay_attempt
				last_step["reassemblyAdmission"] = reassembly_admission
			return last_step
		if bool(last_step.get("requiresReassembly", false)):
			# A recreated chunk has a new provider owner identity. The old candidate
			# must fail its census digest check; capture and submit fresh contributions
			# against that owner's current roster before attempting native replay.
			stale_replay_attempt = last_step.duplicate(true)
			var previous_candidate: Dictionary = coordinator._production_candidates_by_section.get(
				SECTION, {})
			var next_generation := int(previous_candidate.get("generation", 0)) + 1
			reassembly_admission = coordinator.assemble_and_submit_complete_section_candidate(
				SECTION, next_generation)
			if reassembly_admission.get("status") != "queued":
				return {"status":"failed", "reason":"owner_replay_reassembly_not_queued",
					"staleAttempt":stale_replay_attempt,
					"reassemblyAdmission":reassembly_admission}
			last_step = {"status":"pending", "stage":"owner_replay_reassembled",
				"generation":next_generation}
			await process_frame
			continue
		var replay_state: Dictionary = coordinator.status()
		if int(replay_state.get("queuedReplaySections", 0)) > 0 \
				or replay_state.get("activeReplaySection", null) != null:
			var census: Dictionary = coordinator.capture_authoritative_source_census([SECTION])
			if census.get("status") != "complete":
				return {"status":"failed", "reason":"replay_source_census_pending",
					"census":census, "coordinatorStatus":replay_state}
			var current_revisions: Dictionary = census.sourceRevisions.duplicate(false)
			for part_id_value: Variant in census.get("removalRevisions", {}):
				current_revisions[String(part_id_value)] = String(census.removalRevisions[part_id_value])
			current_revisions.make_read_only()
			var production_candidate: Dictionary = coordinator._production_candidates_by_section.get(
				SECTION, {})
			var replay: Dictionary = coordinator.advance_replay(current_revisions,
				census.expectedContributorsBySection,
				production_candidate.get("materialBindings", {}),
				production_candidate.get("meshBindings", {}), 8)
			last_step = replay
			if replay.get("status") in ["replayed", "failed", "cancelled"]:
				if replay.get("status") == "replayed":
					return {"status":"installed", "stage":"stream_replay", "replay":replay}
				return replay
		await process_frame
	return {"status":"failed", "reason":"headed_native_install_frame_budget_exceeded",
		"lastStep":last_step,
		"staleReplayAttempt":stale_replay_attempt,
		"reassemblyAdmission":reassembly_admission,
		"coordinatorMetrics":coordinator.metrics() if coordinator.has_method("metrics") else {}}


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
		"evidenceLevel":"production TreePublicationQueue canonical recipe artifact and EcologySectionValueAdapter census/contribution assembled into a complete section candidate and acknowledged by the native chunk renderer; terrain and ordinary providers remain fixture producers",
		"frameAcknowledgementSemantics":"one-shot global RenderingServer frame-drawn callback after the candidate root is promoted; this is not candidate-specific rasterization or unobscured-pixel proof",
		"headedObjectVisibilityProven":false,
		"doesNotProve":"Normal-world startup and streaming, candidate-specific pixel visibility, live visual parity, gameplay collision/interactions, save/replay or runtime performance."}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	quit(0 if failed.is_empty() else 1)


func _run_synthetic_presentation_lifecycle(world: WorldRoot, chunk: Node3D,
		backend: Node3D, attached: Dictionary) -> void:
	var lifecycle_report_path := OS.get_environment(LIFECYCLE_REPORT_ENV)
	checks.clear()
	_check("actual_native_backend_attached", attached.get("status") == "ready"
		and is_instance_valid(backend), attached)
	if not checks["actual_native_backend_attached"].passed:
		_finish_lifecycle(lifecycle_report_path)
		return
	coordinator = Coordinator.new()
	coordinator.configure(WORLD)
	world.world_static_section_coordinator = coordinator
	var providers: Array[String] = ["terrain", "ordinary"]
	coordinator.configure_source_roster(providers)
	var terrain_provider := _make_lifecycle_provider("terrain", "terrain:fixture:0", "terrain-r1")
	var ordinary_provider := _make_lifecycle_provider("ordinary", "ordinary:fixture:0", "ordinary-r1")
	coordinator.register_source_provider("terrain", terrain_provider, "capture_static_section_sources")
	coordinator.register_source_provider("ordinary", ordinary_provider, "capture_static_section_sources")
	var complete_census: Dictionary = coordinator.capture_authoritative_source_census([SECTION])
	var census_sections: Array = complete_census.get("sections", [])
	var expected_rows: Array = complete_census.get("expectedContributorsBySection", {}).get(SECTION, [])
	_check("fixture_provider_census_complete_before_candidate",
		complete_census.get("status") == "complete" and census_sections.has(SECTION)
		and expected_rows.size() == 2 and "terrain:fixture:0" in expected_rows
		and "ordinary:fixture:0" in expected_rows,
		{"status":complete_census.get("status"), "sectionKeys":census_sections,
			"expectedContributors":expected_rows,
			"providerCount":complete_census.get("providerCount", -1)})
	if complete_census.get("status") != "complete" or not census_sections.has(SECTION) \
			or expected_rows.size() != 2:
		_finish_lifecycle(lifecycle_report_path)
		return
	var slot := InstallSession.slot_id(WORLD, SECTION)
	var first_admission: Dictionary = coordinator.assemble_and_submit_complete_section_candidate(SECTION, 1)
	var first_outcome: Dictionary = await _drive_lifecycle_candidate(1, "installed")
	var first_live: Dictionary = backend.call("installed_snapshot", slot)
	var first_receipt: Dictionary = coordinator._production_candidate_receipts.get(SECTION, {})
	_check("generation_one_installed_and_both_providers_acknowledged",
		first_admission.get("status") == "queued" and first_outcome.get("status") == "installed"
		and first_live.get("status") == "ready" and int(first_live.get("generation", 0)) == 1
		and terrain_provider.install_acknowledgement_count == 1
		and ordinary_provider.install_acknowledgement_count == 1,
		{"admission":first_admission, "outcome":first_outcome,
			"nativeReceipt":first_live, "retainedReceipt":first_receipt,
			"terrainAcks":terrain_provider.install_acknowledgement_count,
			"ordinaryAcks":ordinary_provider.install_acknowledgement_count})
	if first_outcome.get("status") != "installed":
		_finish_lifecycle(lifecycle_report_path)
		return
	terrain_provider.source_revision = "terrain-r2"
	ordinary_provider.source_revision = "ordinary-r2"
	var second_admission: Dictionary = coordinator.assemble_and_submit_complete_section_candidate(SECTION, 2)
	var second_pending_outcome: Dictionary = await _drive_lifecycle_candidate(2, "awaiting_frame")
	var pending_snapshot: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var previous_receipt: Dictionary = pending_snapshot.get("previousReceipt", {})
	var old_receipt_live := bool(backend.call("receipt_installed", slot, 1,
		String(first_receipt.get("sourceRevision", "")),
		String(first_receipt.get("contentManifestDigest", ""))))
	var candidate_receipt_visible := bool(backend.call("receipt_installed", slot, 2,
		String(pending_snapshot.get("sourceRevision", "")),
		String(pending_snapshot.get("packetDigest", ""))))
	var frame_callback_absent_step: Dictionary = coordinator.advance_complete_section_candidate(
		SECTION, 8)
	var wrong_token_finalize: Dictionary = backend.call("finalize_presentation", slot, 2,
		String(pending_snapshot.get("token", "")) + ":wrong")
	_check("pending_swap_retains_hidden_previous_receipt_without_acknowledging_candidate",
		second_admission.get("status") == "queued"
		and second_pending_outcome.get("stage") == "awaiting_frame"
		and pending_snapshot.get("status") == "pending_presentation"
		and int(pending_snapshot.get("generation", 0)) == 2
		and int(pending_snapshot.get("previousGeneration", 0)) == 1
		and previous_receipt.get("status") == "retained_previous"
		and int(previous_receipt.get("generation", 0)) == 1
		and old_receipt_live and not candidate_receipt_visible
		and frame_callback_absent_step.get("status") == "pending"
		and frame_callback_absent_step.get("stage") == "awaiting_frame"
		and terrain_provider.install_acknowledgement_count == 1
		and wrong_token_finalize.get("status") == "failed"
		and terrain_provider.install_acknowledgement_count == 1
		and ordinary_provider.install_acknowledgement_count == 1,
		{"admission":second_admission, "pending":pending_snapshot,
		"previousReceipt":previous_receipt, "oldReceiptStillValid":old_receipt_live,
			"candidateReceiptAcceptedEarly":candidate_receipt_visible,
			"callbackAbsentStep":frame_callback_absent_step,
			"wrongTokenFinalize":wrong_token_finalize,
			"providerAcks":[terrain_provider.install_acknowledgement_count,
				ordinary_provider.install_acknowledgement_count]})
	await process_frame
	var second_finalized: Dictionary = await _advance_until_lifecycle_terminal(2)
	var second_live: Dictionary = backend.call("installed_snapshot", slot)
	_check("global_frame_callback_finalizes_candidate_before_provider_ack",
		second_finalized.get("status") == "installed"
		and second_live.get("status") == "ready" and int(second_live.get("generation", 0)) == 2
		and terrain_provider.install_acknowledgement_count == 2
		and ordinary_provider.install_acknowledgement_count == 2,
		{"outcome":second_finalized, "nativeReceipt":second_live,
			"providerAcks":[terrain_provider.install_acknowledgement_count,
				ordinary_provider.install_acknowledgement_count]})
	if second_finalized.get("status") != "installed":
		_finish_lifecycle(lifecycle_report_path)
		return
	terrain_provider.source_revision = "terrain-r3"
	ordinary_provider.source_revision = "ordinary-r3"
	var third_admission: Dictionary = coordinator.assemble_and_submit_complete_section_candidate(SECTION, 3)
	var third_pending_outcome: Dictionary = await _drive_lifecycle_candidate(3, "awaiting_frame")
	var third_pending: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var third_token := String(third_pending.get("token", ""))
	var third_session = coordinator._production_candidate_jobs.get(SECTION, {}).get("session")
	if third_session is RefCounted:
		third_session.set("_translucent_pov_revision", 77)
	var stale_pov_rollback: Dictionary = third_session.advance(8, 76) \
		if third_session is RefCounted else {"status":"failed", "reason":"session_missing"}
	var after_pov_pending: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var after_pov_live: Dictionary = backend.call("installed_snapshot", slot)
	_check("stale_translucent_pov_rolls_back_before_discarding_session",
		third_admission.get("status") == "queued"
		and third_pending_outcome.get("stage") == "awaiting_frame"
		and third_pending.get("status") == "pending_presentation"
		and stale_pov_rollback.get("status") == "failed"
		and stale_pov_rollback.get("reason") == "section_translucent_pov_revision_stale"
		and stale_pov_rollback.get("rollback", {}).get("status") == "cancelled"
		and after_pov_pending.get("status") == "missing"
		and after_pov_live.get("status") == "ready"
		and int(after_pov_live.get("generation", 0)) == 2,
		{"admission":third_admission, "awaitingFrame":third_pending_outcome,
			"pendingBeforePovChange":third_pending, "rollback":stale_pov_rollback,
			"pendingAfterRollback":after_pov_pending, "installedAfterRollback":after_pov_live})
	await process_frame
	var after_pov_late_callback: Dictionary = backend.call("installed_snapshot", slot)
	_check("stale_pov_callback_cannot_replace_retained_old_slot",
		after_pov_late_callback.get("status") == "ready"
		and int(after_pov_late_callback.get("generation", 0)) == 2,
		after_pov_late_callback)
	terrain_provider.source_revision = "terrain-r4"
	ordinary_provider.source_revision = "ordinary-r4"
	var fourth_admission: Dictionary = coordinator.assemble_and_submit_complete_section_candidate(SECTION, 4)
	var fourth_pending_outcome: Dictionary = await _drive_lifecycle_candidate(4, "awaiting_frame")
	var fourth_pending: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var fourth_job_before_unload: Dictionary = coordinator._production_candidate_jobs.get(SECTION, {})
	var fourth_session: Variant = fourth_job_before_unload.get("session", null)
	var fourth_token := String(fourth_pending.get("token", ""))
	coordinator._on_section_frame_drawn(third_token)
	var fourth_frame_drawn_after_old_token := bool(fourth_session.get("_frame_drawn")) \
		if fourth_session is RefCounted else true
	var fourth_callback_retained_before_unload: bool = coordinator._pending_frame_presentations.has(fourth_token) \
		and coordinator._pending_frame_presentations[fourth_token].get("session") == fourth_session
	fourth_job_before_unload = {}
	var direct_release: Dictionary = backend.call("release_packet", slot, 2)
	var unload_count: int = coordinator.notify_stream_chunk_unloaded(Vector2i.ZERO,
		chunk.get_instance_id())
	var after_unload_pending: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var after_unload_live: Dictionary = backend.call("installed_snapshot", slot)
	var production_job_after_unload: Dictionary = coordinator._production_candidate_jobs.get(SECTION, {})
	var source_release_after_unload: Dictionary = coordinator._pending_source_releases.get(SECTION, {})
	var fourth_session_weak: WeakRef = weakref(fourth_session) if fourth_session is RefCounted else null
	fourth_session = null
	await process_frame
	var after_late_callback: Dictionary = backend.call("installed_snapshot", slot)
	var callbacks_after_unload: Dictionary = coordinator.frame_presentation_callback_diagnostics()
	_check("owner_unload_rolls_back_pending_candidate_and_late_callback_is_noop",
		fourth_admission.get("status") == "queued"
		and fourth_pending_outcome.get("stage") == "awaiting_frame"
		and fourth_pending.get("status") == "pending_presentation"
		and not fourth_frame_drawn_after_old_token
		and direct_release.get("status") == "backpressure"
		and direct_release.get("reason") == "source_has_pending_presentation"
		and unload_count > 0 and after_unload_pending.get("status") == "missing"
		and after_unload_live.get("status") == "ready"
		and int(after_unload_live.get("generation", 0)) == 2
		and production_job_after_unload.is_empty()
		and not source_release_after_unload.is_empty()
		and after_late_callback.get("status") == "ready"
		and int(after_late_callback.get("generation", 0)) == 2
		and fourth_callback_retained_before_unload
		and not coordinator._pending_frame_presentations.has(fourth_token)
		and int(callbacks_after_unload.get("cancelledCallbackCount", 0)) >= 1,
		{"admission":fourth_admission, "awaitingFrame":fourth_pending_outcome,
			"pendingBeforeUnload":fourth_pending, "directBackendRelease":direct_release,
			"previousGenerationToken":third_token,
			"currentFrameDrawnAfterPreviousToken":fourth_frame_drawn_after_old_token,
			"unloadNotifications":unload_count,
			"pendingAfterUnload":after_unload_pending,
			"installedAfterUnload":after_unload_live,
			"productionJobAfterUnload":production_job_after_unload,
			"sourceReleaseAfterUnload":source_release_after_unload,
			"callbackWasCoordinatorOwned":fourth_callback_retained_before_unload,
			"callbackAfterUnload":callbacks_after_unload,
			"sessionAfterCallback":fourth_session_weak.get_ref() if fourth_session_weak != null else null,
			"installedAfterLateGlobalCallback":after_late_callback})
	terrain_provider.source_revision = "terrain-r2"
	ordinary_provider.source_revision = "ordinary-r2"
	var loaded_count: int = coordinator.notify_stream_chunk_loaded(Vector2i.ZERO)
	var replay_job: Dictionary = {}
	for frame_index in range(24):
		await process_frame
		coordinator._advance_pending_source_releases(1)
		replay_job = coordinator._production_candidate_jobs.get(SECTION, {})
		if String(replay_job.get("stage", "")) == "unload_replay":
			break
	_check("successful_unload_release_and_reload_admit_retained_candidate_replay",
		# The unload path may already have admitted this replay job before the
		# loaded notification arrives. The contract is that retained demand is
		# present and retryable, not that this call must enqueue it again.
		replay_job.get("stage") == "unload_replay"
		and replay_job.get("session", null) == null
		and int(replay_job.get("candidate", {}).get("generation", 0)) == 2
		and coordinator._production_candidate_receipts.get(SECTION, {}).is_empty()
		and terrain_provider.release_call_count >= 2
		and ordinary_provider.release_call_count >= 2,
		{"loadedNotifications":loaded_count,
			"replayJobAlreadyAdmittedOrRetained":replay_job.get("stage") == "unload_replay",
			"replayJob":replay_job,
			"pendingReleases":coordinator._pending_source_releases.size(),
			"installedReceipts":coordinator._production_candidate_receipts})
	var empty_coordinator = Coordinator.new()
	empty_coordinator.configure(WORLD)
	world.world_static_section_coordinator = empty_coordinator
	var empty_provider := ExplicitEmptyProvider.new()
	empty_provider.world_id = WORLD
	var empty_provider_ids: Array[String] = ["explicit-empty"]
	empty_coordinator.configure_source_roster(empty_provider_ids)
	empty_coordinator.register_source_provider("explicit-empty", empty_provider,
		"capture_static_section_sources")
	var empty_census: Dictionary = empty_coordinator.capture_authoritative_source_census([SECTION])
	var empty_sections: Array = empty_census.get("sections", [])
	var empty_expected_rows: Array = empty_census.get("expectedContributorsBySection", {}).get(SECTION, [])
	var empty_admission: Dictionary = empty_coordinator.assemble_and_submit_complete_section_candidate(SECTION, 10)
	var empty_pending_outcome: Dictionary = await _drive_lifecycle_candidate(10,
		"awaiting_frame", empty_coordinator)
	var empty_pending: Dictionary = backend.call("pending_presentation_snapshot", slot)
	await process_frame
	var empty_finalized: Dictionary = await _advance_until_lifecycle_terminal(10,
		empty_coordinator)
	var empty_live: Dictionary = backend.call("installed_snapshot", slot)
	var empty_layers: Array = empty_live.get("layers", [])
	_check("authoritative_explicit_empty_replacement_finalizes_all_empty_layers",
		empty_census.get("status") == "complete" and empty_sections.has(SECTION)
		and empty_expected_rows.is_empty()
		and empty_admission.get("status") == "queued"
		and empty_pending_outcome.get("stage") == "awaiting_frame"
		and empty_pending.get("status") == "pending_presentation"
		and int(empty_pending.get("previousGeneration", 0)) == 2
		and int(empty_pending.get("instanceCount", -1)) == 0
		and empty_finalized.get("status") == "installed"
		and empty_live.get("status") == "ready"
		and int(empty_live.get("generation", 0)) == 10
		and int(empty_live.get("instanceCount", -1)) == 0
		and empty_layers.size() == 3 and _all_layers_empty(empty_layers)
		and empty_provider.install_acknowledgement_count == 1,
		{"census":empty_census, "sectionKeys":empty_sections,
			"expectedContributors":empty_expected_rows, "admission":empty_admission,
			"awaitingFrame":empty_pending_outcome, "pending":empty_pending,
			"finalized":empty_finalized, "installed":empty_live,
			"providerAcks":empty_provider.install_acknowledgement_count})
	if empty_finalized.get("status") != "installed":
		_finish_lifecycle(lifecycle_report_path)
		return
	empty_provider.census_pending = false
	var pending_admission: Dictionary = empty_coordinator.assemble_and_submit_complete_section_candidate(SECTION, 11)
	var census_pending_candidate: Dictionary = await _drive_lifecycle_candidate(11,
		"awaiting_frame", empty_coordinator)
	var pending_before_cancel: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var pending_job: Dictionary = empty_coordinator._production_candidate_jobs.get(SECTION, {})
	var pending_session = pending_job.get("session")
	var session_generation := int(pending_session.get("_generation")) \
		if pending_session is RefCounted else 0
	empty_coordinator._active_replay = {"candidate":empty_coordinator._production_candidates_by_section.get(SECTION, {}),
		"sectionKey":SECTION, "installSession":pending_session}
	if pending_session is RefCounted:
		pending_session.set("_generation", session_generation + 1000)
	var injected_rollback_failure: Dictionary = empty_coordinator.cancel_section_replay(SECTION)
	var active_replay_after_failure: Dictionary = empty_coordinator.get("_active_replay")
	var job_after_failed_replay_cancel: Dictionary = empty_coordinator._production_candidate_jobs.get(SECTION, {})
	var native_after_failed_rollback: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var retained_after_failed_rollback: Dictionary = native_after_failed_rollback.get("previousReceipt", {})
	empty_coordinator._active_boundary = {"boundaryId":"fixture-pending-boundary",
		"installSession":pending_session}
	var failed_boundary_cancel: Dictionary = empty_coordinator.cancel_boundary(
		"fixture-pending-boundary")
	var boundary_after_failed_cancel: Dictionary = empty_coordinator.get("_active_boundary")
	var owner_retirement_main = MainCoreScript.new()
	owner_retirement_main.set("world_static_section_coordinator", empty_coordinator)
	owner_retirement_main.set("static_section_render_owners", {Vector2i.ZERO:chunk})
	var owner_retirement_after_rollback_failure: bool = bool(
		owner_retirement_main.call("retire_static_section_render_owner", Vector2i.ZERO))
	var owner_registry_after_rollback_failure: Dictionary = owner_retirement_main.get(
		"static_section_render_owners")
	_check("native_rollback_identity_failure_retains_live_session_and_old_slot",
		injected_rollback_failure.get("status") == "rollback_failed"
		and injected_rollback_failure.get("rollback", {}).get("nativeRollback", {}).get("status") == "failed"
		and pending_session is RefCounted
		and String(pending_session.get("state")) == "awaiting_frame"
		and not active_replay_after_failure.is_empty()
		and active_replay_after_failure.get("installSession") == pending_session
		and failed_boundary_cancel.get("status") == "rollback_failed"
		and boundary_after_failed_cancel.get("installSession") == pending_session
		and not job_after_failed_replay_cancel.is_empty()
		and job_after_failed_replay_cancel.get("session") == pending_session
		and native_after_failed_rollback.get("status") == "pending_presentation"
		and int(native_after_failed_rollback.get("generation", 0)) == 11
		and retained_after_failed_rollback.get("status") == "retained_previous"
		and int(retained_after_failed_rollback.get("generation", 0)) == 10
		and not owner_retirement_after_rollback_failure
		and owner_registry_after_rollback_failure.get(Vector2i.ZERO) == chunk
		and not chunk.is_queued_for_deletion()
		and empty_provider.install_acknowledgement_count == 1,
		{"rollbackFailure":injected_rollback_failure,
			"boundaryRollbackFailure":failed_boundary_cancel,
			"sessionState":pending_session.get("state") if pending_session is RefCounted else "missing",
			"activeReplayAfterFailure":active_replay_after_failure,
			"activeBoundaryAfterFailure":boundary_after_failed_cancel,
			"productionJobAfterFailure":job_after_failed_replay_cancel,
			"nativePending":native_after_failed_rollback,
			"retainedPreviousReceipt":retained_after_failed_rollback,
			"ownerRetirementAccepted":owner_retirement_after_rollback_failure,
			"ownerStillRegistered":owner_registry_after_rollback_failure.get(Vector2i.ZERO) == chunk,
			"ownerQueuedForDeletion":chunk.is_queued_for_deletion(),
			"providerAckCount":empty_provider.install_acknowledgement_count})
	empty_provider.census_pending = true
	var census_rollback_failure: Dictionary = empty_coordinator.advance_complete_section_candidate(SECTION, 8)
	var job_after_census_rollback_failure: Dictionary = empty_coordinator._production_candidate_jobs.get(SECTION, {})
	var pending_after_census_rollback_failure: Dictionary = backend.call("pending_presentation_snapshot", slot)
	if pending_session is RefCounted:
		pending_session.set("_generation", session_generation)
	var census_loss: Dictionary = empty_coordinator.advance_complete_section_candidate(SECTION, 8)
	var boundary_cleanup: Dictionary = empty_coordinator.cancel_boundary("fixture-pending-boundary")
	var after_census_loss_pending: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var after_census_loss_installed: Dictionary = backend.call("installed_snapshot", slot)
	var replay_cleanup: Dictionary = empty_coordinator.cancel_section_replay(SECTION)
	_check("unavailable_complete_provider_census_rolls_back_before_pending_return",
		pending_admission.get("status") == "queued"
		and census_pending_candidate.get("stage") == "awaiting_frame"
		and pending_before_cancel.get("status") == "pending_presentation"
		and census_rollback_failure.get("status") == "rollback_failed"
		and not job_after_census_rollback_failure.is_empty()
		and job_after_census_rollback_failure.get("session") == pending_session
		and pending_after_census_rollback_failure.get("status") == "pending_presentation"
		and census_loss.get("status") == "pending"
		and census_loss.get("stage") == "source_census"
		and census_loss.get("reason") == "static_source_provider_pending"
		and census_loss.get("providerReason") == "fixture_census_pending"
		and census_loss.get("requiresReassembly", false)
		and boundary_cleanup.get("status") == "cancelled"
		and after_census_loss_pending.get("status") == "missing"
		and after_census_loss_installed.get("status") == "ready"
		and int(after_census_loss_installed.get("generation", 0)) == 10
		and replay_cleanup.get("status") == "cancelled"
		and empty_provider.install_acknowledgement_count == 1,
		{"admission":pending_admission, "awaitingFrame":census_pending_candidate,
			"pendingBeforeCensusLoss":pending_before_cancel,
			"rollbackFailure":census_rollback_failure,
			"jobAfterRollbackFailure":job_after_census_rollback_failure,
			"pendingAfterRollbackFailure":pending_after_census_rollback_failure,
			"censusLoss":census_loss, "pendingAfterRollback":after_census_loss_pending,
			"installedAfterRollback":after_census_loss_installed,
			"replayCleanup":replay_cleanup,
			"providerAckCount":empty_provider.install_acknowledgement_count})
	empty_provider.census_pending = false
	var teardown_admission: Dictionary = empty_coordinator.assemble_and_submit_complete_section_candidate(
		SECTION, 12)
	var teardown_pending: Dictionary = await _drive_lifecycle_candidate(12,
		"awaiting_frame", empty_coordinator)
	var teardown_pending_snapshot: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var teardown_job: Dictionary = empty_coordinator._production_candidate_jobs.get(SECTION, {})
	var teardown_session: Variant = teardown_job.get("session", null)
	var teardown_generation := int(teardown_session.get("_generation")) \
		if teardown_session is RefCounted else 0
	var teardown_token := String(teardown_pending_snapshot.get("token", ""))
	if teardown_session is RefCounted:
		teardown_session.set("_generation", teardown_generation + 1000)
	var failed_teardown_drain: Dictionary = await empty_coordinator.drain_pending_frame_presentations()
	var job_after_failed_teardown_drain: Dictionary = empty_coordinator._production_candidate_jobs.get(SECTION, {})
	var pending_after_failed_teardown_drain: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var installed_after_failed_teardown_drain: Dictionary = backend.call("installed_snapshot", slot)
	var retained_teardown_receipt: Dictionary = pending_after_failed_teardown_drain.get(
		"previousReceipt", {})
	var teardown_previous_root_preserved: bool = \
		pending_after_failed_teardown_drain.get("status") == "pending_presentation" \
		and retained_teardown_receipt.get("status") == "retained_previous" \
		and int(retained_teardown_receipt.get("generation", 0)) == 10 \
		and int(pending_after_failed_teardown_drain.get("previousRootInstanceId", 0)) \
			== int(retained_teardown_receipt.get("rootInstanceId", 0))
	if teardown_session is RefCounted:
		teardown_session.set("_generation", teardown_generation)
	_check("teardown_rollback_failure_preserves_dispatch_session_and_native_identity",
		failed_teardown_drain.get("status") == "rollback_failed"
		and not failed_teardown_drain.get("drained", false)
		and failed_teardown_drain.get("ownerMustBeRetained", false)
		and not job_after_failed_teardown_drain.is_empty()
		and job_after_failed_teardown_drain.get("session") == teardown_session
		and teardown_session is RefCounted
		and String(teardown_session.get("state")) == "awaiting_frame"
		and empty_coordinator._pending_frame_presentations.has(teardown_token)
		and int(pending_after_failed_teardown_drain.get("generation", 0)) == 12
		and teardown_previous_root_preserved
		and empty_provider.install_acknowledgement_count == 1,
		{"failedDrain":failed_teardown_drain,
			"jobRetained":not job_after_failed_teardown_drain.is_empty(),
			"sessionState":teardown_session.get("state") if teardown_session is RefCounted else "missing",
			"pendingPresentation":pending_after_failed_teardown_drain,
			"previousRootPreserved":teardown_previous_root_preserved,
			"retainedReceipt":retained_teardown_receipt,
			"visibleOnlyInstalledSnapshot":installed_after_failed_teardown_drain,
			"providerAckCount":empty_provider.install_acknowledgement_count})
	var teardown_drain: Dictionary = await empty_coordinator.drain_pending_frame_presentations()
	var teardown_live: Dictionary = backend.call("installed_snapshot", slot)
	var teardown_pending_after: Dictionary = backend.call("pending_presentation_snapshot", slot)
	_check("world_teardown_drains_callback_before_releasing_native_backend_owner",
		teardown_admission.get("status") == "queued"
		and teardown_pending.get("stage") == "awaiting_frame"
		and teardown_pending_snapshot.get("status") == "pending_presentation"
		and failed_teardown_drain.get("status") == "rollback_failed"
		and teardown_drain.get("status") == "drained"
		and teardown_drain.get("drained", false)
		and int(teardown_drain.get("pendingCallbackCount", -1)) == 0
		and teardown_pending_after.get("status") == "missing"
		and teardown_live.get("status") == "ready"
		and int(teardown_live.get("generation", 0)) == 10
		and empty_provider.install_acknowledgement_count == 1
		and empty_coordinator._pending_frame_presentations.is_empty(),
		{"admission":teardown_admission, "awaitingFrame":teardown_pending,
			"pendingBeforeDrain":teardown_pending_snapshot, "drain":teardown_drain,
			"pendingAfterDrain":teardown_pending_after,
			"retainedOldReceiptAfterDrain":teardown_live,
			"providerAckCount":empty_provider.install_acknowledgement_count,
			"pendingPresentationRecords":empty_coordinator._pending_frame_presentations.size()})
	var owner_retry_admission: Dictionary = empty_coordinator.assemble_and_submit_complete_section_candidate(
		SECTION, 13)
	var owner_retry_pending: Dictionary = await _drive_lifecycle_candidate(13,
		"awaiting_frame", empty_coordinator)
	var owner_retry_snapshot: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var owner_retry_token := String(owner_retry_snapshot.get("token", ""))
	var owner_retry_release_count_before := empty_provider.release_count
	var owner_retirement_pending: bool = bool(owner_retirement_main.call(
		"retire_static_section_render_owner", Vector2i.ZERO))
	var owner_pending_snapshot_after_rollback: Dictionary = backend.call(
		"pending_presentation_snapshot", slot)
	var owner_old_slot_after_rollback: Dictionary = backend.call("installed_snapshot", slot)
	var owner_registry_while_callback_pending: Dictionary = owner_retirement_main.get(
		"static_section_render_owners").duplicate()
	var owner_registered_before_callback: bool = owner_registry_while_callback_pending.get(
		Vector2i.ZERO) == chunk
	var owner_node_queued_before_callback: bool = chunk.is_queued_for_deletion()
	var owner_retirement_record: Dictionary = chunk.get_meta(
		"static_section_owner_retirement", {})
	var owner_callback_record: Dictionary = empty_coordinator._pending_frame_presentations.get(
		owner_retry_token, {})
	var owner_callback_is_tombstone := bool(owner_callback_record.get("cancelled", false))
	var owner_rollback_release_count := empty_provider.release_count
	await process_frame
	await RenderingServer.frame_post_draw
	var owner_callback_after_draw: Dictionary = empty_coordinator.frame_presentation_callback_diagnostics()
	var owner_retirement_retry: bool = bool(owner_retirement_main.call(
		"retire_static_section_render_owner", Vector2i.ZERO))
	var owner_registry_after_retry: Dictionary = owner_retirement_main.get(
		"static_section_render_owners")
	var owner_release_count_after_retry := empty_provider.release_count
	_check("owner_retirement_waits_for_tombstoned_callback_then_retries_idempotently",
		owner_retry_admission.get("status") == "queued"
		and owner_retry_pending.get("stage") == "awaiting_frame"
		and owner_retry_snapshot.get("status") == "pending_presentation"
		and not owner_retirement_pending
		and owner_retirement_record.get("status") == "pending"
		and owner_callback_is_tombstone
		and owner_pending_snapshot_after_rollback.get("status") == "missing"
		and owner_old_slot_after_rollback.get("status") == "ready"
		and int(owner_old_slot_after_rollback.get("generation", 0)) == 10
		and owner_registered_before_callback
		and not owner_node_queued_before_callback
		and owner_rollback_release_count == owner_retry_release_count_before + 1
		and not empty_coordinator._pending_frame_presentations.has(owner_retry_token)
		and int(owner_callback_after_draw.get("cancelledCallbackCount", 0)) >= 1
		and owner_retirement_retry
		and not owner_registry_after_retry.has(Vector2i.ZERO)
		and chunk.is_queued_for_deletion()
		and owner_release_count_after_retry == owner_rollback_release_count,
		{"admission":owner_retry_admission, "awaitingFrame":owner_retry_pending,
			"pendingBeforeOwnerRetirement":owner_retry_snapshot,
			"firstRetirementAccepted":owner_retirement_pending,
			"retirementStatus":owner_retirement_record,
			"callbackTombstone":owner_callback_is_tombstone,
			"nativePendingAfterRollback":owner_pending_snapshot_after_rollback,
			"oldSlotAfterRollback":owner_old_slot_after_rollback,
			"ownerRegistryBeforeCallback":owner_registry_while_callback_pending,
			"ownerRegisteredBeforeCallback":owner_registered_before_callback,
			"ownerNodeQueuedBeforeCallback":owner_node_queued_before_callback,
			"providerReleaseCountBefore":owner_retry_release_count_before,
			"providerReleaseCountAfterRollback":owner_rollback_release_count,
			"callbackAfterDraw":owner_callback_after_draw,
			"retirementRetryAccepted":owner_retirement_retry,
			"ownerRegistryAfterRetry":owner_registry_after_retry,
			"providerReleaseCountAfterRetry":owner_release_count_after_retry})
	owner_retirement_main.free()
	owner_retirement_main = null
	var callback_probe_coordinator := Coordinator.new()
	callback_probe_coordinator.configure(WORLD + ":callback-probe")
	var probe_a := FrameCallbackProbe.new()
	probe_a._presentation_token = "callback-probe-a"
	var probe_b := FrameCallbackProbe.new()
	probe_b._presentation_token = "callback-probe-b"
	var probe_a_registration: Dictionary = callback_probe_coordinator.register_pending_frame_presentation(
		probe_a, probe_a._presentation_token)
	var probe_b_registration: Dictionary = callback_probe_coordinator.register_pending_frame_presentation(
		probe_b, probe_b._presentation_token)
	var probe_a_cancel: Dictionary = callback_probe_coordinator.cancel_pending_frame_presentation(
		probe_a, probe_a._presentation_token)
	# Dispatch in reverse registration order to prove token routing is independent
	# of callback order. The queued RenderingServer callbacks then arrive late and
	# must be harmless stale no-ops.
	callback_probe_coordinator._on_section_frame_drawn(probe_b._presentation_token)
	callback_probe_coordinator._on_section_frame_drawn(probe_a._presentation_token)
	var probe_before_server_callbacks: Dictionary = callback_probe_coordinator.frame_presentation_callback_diagnostics()
	var probe_b_completion: Dictionary = callback_probe_coordinator.complete_pending_frame_presentation(
		probe_b, probe_b._presentation_token)
	await process_frame
	await RenderingServer.frame_post_draw
	var probe_after_server_callbacks: Dictionary = callback_probe_coordinator.frame_presentation_callback_diagnostics()
	_check("multiple_token_dispatch_is_order_independent_and_late_callbacks_noop",
		probe_a_registration.get("status") == "queued"
		and probe_b_registration.get("status") == "queued"
		and probe_a_cancel.get("status") == "tombstoned"
		and probe_b_completion.get("status") == "completed"
		and probe_b.accepted_tokens == [probe_b._presentation_token]
		and probe_a.accepted_tokens.is_empty()
		and int(probe_before_server_callbacks.get("pendingCallbackCount", -1)) == 0
		and int(probe_before_server_callbacks.get("acceptedCallbackCount", -1)) == 1
		and int(probe_before_server_callbacks.get("cancelledCallbackCount", -1)) == 1
		and int(probe_after_server_callbacks.get("pendingCallbackCount", -1)) == 0
		and int(probe_after_server_callbacks.get("staleCallbackCount", 0)) >= 2,
		{"registrationA":probe_a_registration, "registrationB":probe_b_registration,
			"cancelA":probe_a_cancel, "completionB":probe_b_completion,
			"acceptedA":probe_a.accepted_tokens,
			"acceptedB":probe_b.accepted_tokens,
			"beforeServerCallbacks":probe_before_server_callbacks,
			"afterServerCallbacks":probe_after_server_callbacks})
	var reset_probe_coordinator := Coordinator.new()
	reset_probe_coordinator.configure(WORLD + ":reset-callback-probe")
	var reset_probe := FrameCallbackProbe.new()
	reset_probe._presentation_token = "reset-pending-callback"
	var reset_probe_registration: Dictionary = reset_probe_coordinator.register_pending_frame_presentation(
		reset_probe, reset_probe._presentation_token)
	var reset_probe_cancel: Dictionary = reset_probe_coordinator.cancel_pending_frame_presentation(
		reset_probe, reset_probe._presentation_token)
	var reset_with_only_pending_callback: Dictionary = reset_probe_coordinator.reset_for_world(
		WORLD + ":reset-before-callback")
	await process_frame
	await RenderingServer.frame_post_draw
	var reset_probe_callbacks_drained := reset_probe_coordinator._pending_frame_presentations.is_empty()
	var reset_after_callback_drained: Dictionary = reset_probe_coordinator.reset_for_world(
		WORLD + ":reset-after-callback")
	_check("reset_refuses_only_pending_callback_token_until_callback_delivery",
		reset_probe_registration.get("status") == "queued"
		and reset_probe_cancel.get("status") == "tombstoned"
		and reset_with_only_pending_callback.get("status") == "failed"
		and reset_with_only_pending_callback.get("reason") == "world_reset_has_pending_section_work"
		and int(reset_probe_coordinator.frame_presentation_callback_diagnostics().get(
			"pendingCallbackCount", -1)) == 0
		and reset_probe_callbacks_drained
		and reset_after_callback_drained.get("status") == "ready",
		{"registration":reset_probe_registration, "cancellation":reset_probe_cancel,
			"resetWithPendingCallback":reset_with_only_pending_callback,
			"callbacksDrained":reset_probe_callbacks_drained,
			"resetAfterCallback":reset_after_callback_drained})
	_finish_lifecycle(lifecycle_report_path)


func _make_lifecycle_provider(provider_id: String, source_part_id: String,
		source_revision: String) -> CensusProvider:
	var provider := CensusProvider.new()
	provider.world_id = WORLD
	provider.provider_id = provider_id
	provider.source_part_id = source_part_id
	provider.source_revision = source_revision
	provider.mesh = shared_mesh
	provider.material = shared_material
	provider.batch_key = shared_batch_key
	provider.compatibility = shared_compatibility
	return provider


func _drive_lifecycle_candidate(generation: int, target_state: String,
		target_coordinator = null) -> Dictionary:
	var active_coordinator = coordinator if target_coordinator == null else target_coordinator
	var last_step: Dictionary = {"status":"idle"}
	for frame_index in range(1200):
		last_step = active_coordinator.advance_complete_section_candidate(SECTION, 8)
		var job: Dictionary = active_coordinator._production_candidate_jobs.get(SECTION, {})
		var session = job.get("session")
		if target_state == "awaiting_frame" and session is RefCounted \
				and String(session.get("state")) == target_state:
			return last_step
		if target_state == "installed" and last_step.get("status") == "installed":
			return last_step
		if last_step.get("status") in ["failed", "cancelled"]:
			return last_step
		await process_frame
	return {"status":"failed", "reason":"lifecycle_candidate_frame_budget_exceeded",
		"generation":generation, "lastStep":last_step}


func _advance_until_lifecycle_terminal(generation: int, target_coordinator = null) -> Dictionary:
	return await _drive_lifecycle_candidate(generation, "installed", target_coordinator)


func _all_layers_empty(layers: Array) -> bool:
	for layer_value: Variant in layers:
		if not layer_value is Dictionary \
				or String(layer_value.get("status", "")) != "empty" \
				or int(layer_value.get("expectedBatchCount", -1)) != 0 \
				or int(layer_value.get("installedBatchCount", -1)) != 0 \
				or int(layer_value.get("expectedInstanceCount", -1)) != 0 \
				or int(layer_value.get("installedInstanceCount", -1)) != 0 \
				or not layer_value.get("batchIds", []).is_empty():
			return false
	return true


func _finish_lifecycle(path: String) -> void:
	var failed: Array[String] = []
	for name: String in checks:
		if not bool(checks[name].get("passed", false)):
			failed.append(name)
	var report := {"schema":"native-section-pending-presentation-lifecycle/v1",
		"complete":true, "passed":failed.is_empty(), "checks":checks,
		"checkCount":checks.size(), "failedChecks":failed,
		"evidenceLevel":"headed synthetic-producer whole-section candidate lifecycle through the actual native section packet renderer",
		"frameAcknowledgementSemantics":"one-shot global RenderingServer frame-drawn callback after atomic candidate promotion; the callback is a global frame boundary, not a candidate-specific or object-specific rasterization acknowledgement",
		"headedObjectVisibilityProven":false,
		"doesNotProve":"Live Main/provider census, normal-world startup or streaming, candidate-specific pixel visibility, unobscured raster output, collision/interactions, save/replay, or runtime performance."}
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	lifecycle_exit_code = 0 if failed.is_empty() else 1

extends SceneTree

const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const PacketOwner := preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstallSession := preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const EcologyDomain := preload("res://scripts/world/EcologyProducerDomain.gd")
const MainCoreScript := preload("res://scripts/MainCore.gd")
const MainScene := preload("res://scenes/Main.tscn")
const RuntimeToolsScript := preload("res://scripts/MainRuntimeTools.gd")
const EcologyAdapterScript := preload("res://scripts/world/EcologySectionValueAdapter.gd")
const StructureSystemScript := preload("res://scripts/StructureSystem.gd")
const REPORT_ENV := "VOXEL_WHOLE_SECTION_NATIVE_INSTALL_REPORT"
const PROGRESS_ENV := "VOXEL_WHOLE_SECTION_NATIVE_INSTALL_PROGRESS"
const LIFECYCLE_REPORT_ENV := "VOXEL_NATIVE_SECTION_LIFECYCLE_REPORT"
const SOURCE_COMPILE_RECENSUS_INTERVAL_FRAMES := 30
const WORLD := "seed:whole-section-tree-install:909"
const SECTION := Vector3i.ZERO

var report_path := ""
var progress_path := ""
var checks: Dictionary = {}
var shared_mesh: ArrayMesh
var shared_material: StandardMaterial3D
var shared_compatibility: Dictionary
var shared_batch_key := ""
var coordinator
var production_main_authority: Node
var lifecycle_exit_code := 1


class CensusProvider extends RefCounted:
	const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
	const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
	const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
	var world_id := ""
	var provider_id := ""
	var source_id := ""
	var source_part_id := ""
	var source_revision := ""
	var support_only_section := Vector3i(-2147483647, -2147483647, -2147483647)
	var owner_generation := 1
	var census_pending := false
	var acknowledgement_pending := false
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

	func _coverage_revision(section_key: Vector3i) -> String:
		return provider_id + ("-coverage-r1" if section_key == SECTION \
			else "-support-coverage-r1")

	func capture_static_section_sources(request_world_id: String,
			section_keys: Array) -> Dictionary:
		if census_pending:
			return {"status":"pending", "reason":"fixture_owner_capture_pending", "retryable":true}
		if request_world_id != world_id or section_keys.size() != 1 \
				or section_keys[0] not in [SECTION, support_only_section]:
			return {"status":"failed", "reason":"unexpected_fixture_census_query"}
		var section_key: Vector3i = Vector3i(section_keys[0])
		var is_support_only: bool = section_key == support_only_section \
			and section_key != SECTION
		if is_support_only:
			var empty_parts: Array[Dictionary] = []
			empty_parts.make_read_only()
			var empty_row := {"status":"complete",
				"coverageRevision":_coverage_revision(section_key),
				"sourceParts":empty_parts}
			empty_row.make_read_only()
			var empty_sections := {section_key:empty_row}
			empty_sections.make_read_only()
			var empty_revisions := {}
			empty_revisions.make_read_only()
			var empty_identities := {}
			empty_identities.make_read_only()
			var empty_result := {"status":"complete", "worldId":world_id,
				"authorityRevision":provider_id + "-authority-r%d" % owner_generation,
				"sourceRevisions":empty_revisions,
				"sourceIdentities":empty_identities, "sections":empty_sections}
			empty_result.make_read_only()
			return empty_result
		var identity := {"sourceId":source_id, "sourcePartId":source_part_id}
		identity.make_read_only()
		var parts: Array[Dictionary] = [identity]
		parts.make_read_only()
		var row := {"status":"complete", "coverageRevision":_coverage_revision(section_key),
			"sourceParts":parts}
		row.make_read_only()
		var current_revision := _current_source_revision()
		if current_revision.is_empty():
			return {"status":"pending", "reason":"fixture_source_resource_unavailable", "retryable":true}
		var revisions := {source_part_id:current_revision}
		revisions.make_read_only()
		var identities := {source_part_id:identity}
		identities.make_read_only()
		var sections := {section_key:row}
		sections.make_read_only()
		var result := {"status":"complete", "worldId":world_id,
			"authorityRevision":provider_id + "-authority-r%d" % owner_generation,
			"sourceRevisions":revisions, "sourceIdentities":identities,
			"sections":sections}
		result.make_read_only()
		return result

	func capture_static_section_contribution(census: Dictionary,
			section_key: Vector3i) -> Dictionary:
		if section_key == support_only_section and section_key != SECTION:
			if census.get("status") != "complete" or census.get("worldId") != world_id \
					or not census.get("expectedContributorsBySection", {}).get(
						section_key, []).is_empty():
				return {"status":"pending", "reason":"fixture_empty_support_census_stale",
					"retryable":true}
			var empty_inputs: Array[Dictionary] = []
			empty_inputs.make_read_only()
			var empty_revisions := {}
			empty_revisions.make_read_only()
			var empty_compatibility := {}
			empty_compatibility.make_read_only()
			var empty_materials := {}
			empty_materials.make_read_only()
			var empty_meshes := {}
			empty_meshes.make_read_only()
			var empty_resources := {}
			empty_resources.make_read_only()
			var empty_contribution := {"providerId":provider_id,
				"sectionKey":section_key,
				"coverageRevision":String(census.get("providerCoverageRevisions", {}).get(
					provider_id, {}).get(section_key, "")),
				"authorityRevision":String(census.get("providerSnapshotRevisions", {}).get(
					provider_id, "")),
				"authoritySourceRevisions":empty_revisions,
				"inputs":empty_inputs, "compatibilityByKey":empty_compatibility,
				"materialBindings":empty_materials, "meshBindings":empty_meshes,
				"resourceBindings":empty_resources}
			empty_contribution.make_read_only()
			return {"status":"ready", "contribution":empty_contribution}
		if census.get("status") != "complete" or census.get("worldId") != world_id \
				or section_key != SECTION or _identity_key(source_id, source_part_id) not in \
			census.get("expectedContributorsBySection", {}).get(section_key, []):
			return {"status":"pending", "reason":"fixture_contribution_census_stale",
				"retryable":true}
		var current_revision := _current_source_revision()
		var source_identity_key := _identity_key(source_id, source_part_id)
		if current_revision.is_empty() or String(census.get("sourceRevisions", {}).get(
			source_identity_key, "")) != current_revision:
			return {"status":"pending", "reason":"fixture_contribution_resource_stale",
				"retryable":true}
		var values: Array[float] = []
		for value: float in Attributes.encode(Transform3D.IDENTITY, Color.WHITE):
			values.append(value)
		values.make_read_only()
		var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
			"sourceId":source_id, "sourcePartId":source_part_id,
			"sourceRevision":current_revision,
			"ownerCell":Grid.logical_owner_cell_for_world_position(Vector3(2, 0, 2)),
			"sourceToWorld":Transform3D(Basis.IDENTITY, Vector3(2, 0, 2)),
			"meshLocalBounds":mesh.get_aabb(), "batchKey":batch_key,
			"segmentId":source_part_id + ":mesh", "buffer":values, "instanceCount":1}
		input.make_read_only()
		var inputs: Array[Dictionary] = [input]
		inputs.make_read_only()
		var revisions := {source_identity_key:current_revision}
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

	static func _identity_key(source_id_value: String, source_part_id_value: String) -> String:
		if source_id_value.is_empty() or source_part_id_value.is_empty():
			return ""
		return "section-part:" + var_to_bytes([
			source_id_value, source_part_id_value]).hex_encode()

	func acknowledge_section_install(section_key: Vector3i,
			coverage_revision: String, receipt: Dictionary) -> Dictionary:
		if section_key not in [SECTION, support_only_section] \
				or coverage_revision != _coverage_revision(section_key) \
			or not receipt.is_read_only() or receipt.get("status") != "installed":
			return {"status":"failed", "reason":"fixture_install_ack_identity_mismatch"}
		if acknowledgement_pending:
			return {"status":"pending", "reason":"fixture_acknowledgement_pending", "retryable":true}
		install_acknowledgement_count += 1
		return {"status":"acknowledged", "providerId":provider_id,
			"generation":int(receipt.get("generation", 0))}

	func release_section_install(section_key: Vector3i,
			coverage_revision: String, receipt: Dictionary) -> Dictionary:
		if section_key not in [SECTION, support_only_section] \
				or coverage_revision != _coverage_revision(section_key) \
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
	var owner_generation := 1
	var acknowledgement_pending := false
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
			"authorityRevision":"explicit-empty-authority-r%d" % owner_generation,
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
		if acknowledgement_pending:
			return {"status":"pending", "reason":"fixture_acknowledgement_pending", "retryable":true}
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
	var production_main_authority: Object

	func detail_mesh(_detail_type: String) -> Mesh: return BoxMesh.new()
	func detail_material(_detail_type: String) -> Material: return StandardMaterial3D.new()
	func _ecology_chunk_source_revision(key: Vector2i) -> String:
		return "ecology-r1:%d,%d" % [key.x, key.y]
	func terrain_volume_chunk_revision(_key: Vector2i, _chunk_size: int) -> int:
		return terrain_revision
	func visible_world_underground_visuals_required() -> bool: return false
	func begin_ecology_source_catalog_context_scope() -> Dictionary:
		if not is_instance_valid(production_main_authority):
			return {"status":"pending", "reason":"production_main_catalog_authority_unavailable",
				"retryable":true}
		return production_main_authority.call("begin_ecology_source_catalog_context_scope")
	func end_ecology_source_catalog_context_scope(scope: Dictionary) -> Dictionary:
		if not is_instance_valid(production_main_authority):
			return {"status":"pending", "reason":"production_main_catalog_authority_unavailable",
				"retryable":true}
		return production_main_authority.call("end_ecology_source_catalog_context_scope", scope)
	func ecology_source_publication_local_is_current(view: Dictionary,
			lease_token: String) -> Dictionary:
		if not is_instance_valid(production_main_authority) or not production_main_authority.has_method(
				"ecology_source_publication_local_is_current"):
			return {"status":"pending", "reason":"production_main_publication_currentness_unavailable",
				"retryable":true}
		return production_main_authority.call(
			"ecology_source_publication_local_is_current", view, lease_token)
	func ecology_source_publication_record_is_current(view: Dictionary,
			lease_token: String, record: Dictionary) -> Dictionary:
		if not is_instance_valid(production_main_authority) or not production_main_authority.has_method(
				"ecology_source_publication_record_is_current"):
			return {"status":"pending", "reason":"production_main_publication_record_currentness_unavailable",
				"retryable":true}
		return production_main_authority.call(
			"ecology_source_publication_record_is_current", view, lease_token, record)
	func get_static_section_render_owner(owner_cell: Vector2i,
			create_if_missing: bool) -> Dictionary:
		if owner_cell != Vector2i.ZERO or not is_instance_valid(chunk_owner) \
				or not is_instance_valid(backend):
			return {"status":"pending", "reason":"fixture_owner_unavailable"}
		return {"status":"ready", "owner":chunk_owner, "backend":backend}


func _initialize() -> void:
	report_path = OS.get_environment(REPORT_ENV)
	progress_path = OS.get_environment(PROGRESS_ENV)
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
	coordinator = Coordinator.new()
	coordinator.configure(WORLD)
	world.world_static_section_coordinator = coordinator
	var required_providers: Array[String] = ["terrain", "ordinary", EcologyAdapterScript.PROVIDER_ID]
	coordinator.configure_source_roster(required_providers)
	var terrain_provider := CensusProvider.new()
	terrain_provider.world_id = WORLD
	terrain_provider.provider_id = "terrain"
	terrain_provider.source_id = "terrain-authority:fixture"
	terrain_provider.source_part_id = "terrain:0,0,0"
	terrain_provider.source_revision = "terrain-r1"
	terrain_provider.mesh = shared_mesh
	terrain_provider.material = shared_material
	terrain_provider.batch_key = shared_batch_key
	terrain_provider.compatibility = shared_compatibility
	var ordinary_provider := CensusProvider.new()
	ordinary_provider.world_id = WORLD
	ordinary_provider.provider_id = "ordinary"
	ordinary_provider.source_id = "ordinary-authority:fixture"
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
	var production_main_result := _prepare_production_main_authority(world,
		coordinator)
	if production_main_result.get("status") != "ready":
		_check("production_main_source_authority_initialized", false,
			production_main_result)
		_finish()
		return
	var production_main: Node = production_main_result.get("main") as Node
	var production_tree_queue: Node = production_main_result.get("treeQueue") as Node
	var ecology_provider: Object = production_main_result.get("ecologyProvider") as Object
	coordinator.register_source_provider(EcologyAdapterScript.PROVIDER_ID, ecology_provider,
		"capture_static_section_sources")
	_check("real_native_section_backend_attached", attached.get("status") == "ready"
		and is_instance_valid(backend), attached)
	if not checks["real_native_section_backend_attached"].passed:
		_finish()
		return
	var census_progress: Dictionary = await _capture_authoritative_ecology_census(
		ecology_provider, production_main, production_tree_queue, SECTION)
	var current_tree_census: Dictionary = census_progress.get("census", {})
	var support_pair: Dictionary = _select_tree_support_pair_from_census(current_tree_census,
		production_tree_queue, SECTION, Grid.chunk_key_for_section(SECTION))
	var tree_identity: Dictionary = support_pair.get("identity", {})
	var tree_source_id: String = String(tree_identity.get("sourceId", ""))
	var tree_source_part_id: String = String(tree_identity.get("sourcePartId", ""))
	var source_band_artifact: Dictionary = support_pair.get("artifact", {})
	var support_selection: Dictionary = support_pair.get("supportSelection", {})
	var support_only_section: Vector3i = support_selection.get("sectionKey", SECTION)
	if String(support_selection.get("status", "")) == "ready":
		terrain_provider.support_only_section = support_only_section
		ordinary_provider.support_only_section = support_only_section
	_check("real_sealed_tree_manifest_selects_ownerless_support_in_loaded_backend_cell",
		String(support_pair.get("status", "")) == "ready"
		and String(support_selection.get("status", "")) == "ready"
		and support_only_section != SECTION
		and Grid.chunk_key_for_section(support_only_section) == Vector2i.ZERO,
		{"treeSourceId":tree_source_id, "artifactSchema":source_band_artifact.get("schema", ""),
			"artifactDisposition":source_band_artifact.get("disposition", ""),
			"selection":support_selection,
			"pairSelection":support_pair.get("candidateDiagnostics", [])})
	_check("production_ecology_census_sees_current_compiled_tree_owner",
		current_tree_census.get("status") == "complete" \
		and not tree_source_id.is_empty() \
		and not tree_source_part_id.is_empty() \
		and _census_has_source_identity(current_tree_census, SECTION, tree_identity)
		and current_tree_census.get("sections", {}).get(SECTION, {}).get("status") == "complete",
		{"censusStatus":current_tree_census.get("status", ""),
			"reason":current_tree_census.get("reason", ""),
			"section":current_tree_census.get("sections", {}).get(SECTION, {}),
			"treeSourceId":tree_source_id,
			"sourceCaptureProgress":census_progress.get("progress", {}),
			"treeSourcePartId":tree_source_part_id,
			"mainSetup":production_main_result.get("evidence", {}),
			"treeQueueMetrics":production_tree_queue.call("metrics")})
	if current_tree_census.get("status") != "complete" or tree_source_id.is_empty():
		_finish()
		return
	var first_admission: Dictionary = await _admit_compiled_candidate(coordinator,
		SECTION, 1)
	var first_candidate: Dictionary = coordinator._production_candidate_jobs.get(SECTION, {}).get("candidate", {})
	var owner_alias_census: Dictionary = coordinator.capture_authoritative_source_census([SECTION])
	var owner_alias_capture: Dictionary = {}
	var ecology_owner_contribution: Dictionary = {}
	if owner_alias_census.get("status") == "complete":
		owner_alias_capture = coordinator._source_roster.capture_section_contributions(
			owner_alias_census, SECTION)
		for contribution_value: Variant in owner_alias_capture.get("contributions", []):
			if contribution_value is Dictionary and String(contribution_value.get("providerId", "")) \
					== EcologyAdapterScript.PROVIDER_ID:
				ecology_owner_contribution = contribution_value
				break
	var tree_buffer_alias_evidence: Dictionary = _tree_owner_buffer_alias_evidence(
		source_band_artifact, ecology_owner_contribution, tree_source_id,
		tree_source_part_id, String(first_candidate.get("sourceRevisions", {}).get(
			_identity_key(tree_source_id, tree_source_part_id), "")))
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
		and first_manifest_ids.has(tree_source_part_id)
		and String(first_candidate.get("evidenceLevel", "")) == "complete_authoritative_section_candidate",
		{"sourceId":tree_source_id, "sourcePartId":tree_source_part_id,
			"manifestSourceIds":first_manifest_ids,
			"candidateSourceRevisions":first_candidate.get("sourceRevisions", {})})
	_check("installed_main_tree_candidate_uses_current_typed_readonly_alias_from_sealed_band_artifact",
		String(tree_buffer_alias_evidence.get("status", "")) == "ready"
		and String(owner_alias_census.get("status", "")) == "complete"
		and String(owner_alias_capture.get("status", "")) == "complete"
		and String(owner_alias_census.get("censusDigest", "")) \
			== String(first_candidate.get("censusDigest", ""))
		and String(tree_buffer_alias_evidence.get("candidateSourceRevision", "")) \
			== String(tree_buffer_alias_evidence.get("artifactSourceRevision", ""))
		and String(tree_buffer_alias_evidence.get("candidateSourceRevision", "")) \
			== String(tree_buffer_alias_evidence.get("adapterSourceRevision", ""))
		and bool(tree_buffer_alias_evidence.get("sameTypedReadonlyBuffer", false)),
		{"ownerAliasCensusStatus":owner_alias_census.get("status", ""),
			"ownerAliasCensusDigest":owner_alias_census.get("censusDigest", ""),
			"candidateCensusDigest":first_candidate.get("censusDigest", ""),
			"contributionStatus":owner_alias_capture.get("status", ""),
			"bufferEvidence":tree_buffer_alias_evidence})
	if first_admission.get("status") != "queued":
		_finish()
		return
	var detail_material_before_install := _detail_material_diagnostic(production_main)
	var first_outcome: Dictionary = await _advance_coordinator_to_install(
		production_main, detail_material_before_install)
	var slot := InstallSession.slot_id(WORLD, SECTION)
	var first_live: Dictionary = backend.call("installed_snapshot", slot)
	_check("first_whole_section_candidate_has_native_receipt",
		first_outcome.get("status") == "installed" and first_live.get("status") == "ready"
		and int(first_live.get("generation", 0)) == 1
		and bool(backend.call("receipt_installed", slot, 1,
			"%s:%d" % [WORLD, 1], String(first_candidate.get("contentManifestDigest", ""))))
		and first_live.get("packetDigest", "") == first_candidate.get("contentManifestDigest", "")
		and coordinator.installed_section_receipt_is_current(SECTION,
			coordinator._production_candidate_receipts.get(SECTION, {})),
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
	var second_admission: Dictionary = await _admit_compiled_candidate(coordinator,
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
	var third_admission: Dictionary = await _admit_compiled_candidate(coordinator,
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
	var pending_after_load: Dictionary = coordinator._pending_source_releases.get(
		SECTION, {}).duplicate(true)
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
	var recreated_backend_result: Dictionary = PacketOwner.attach_to_chunk(recreated_chunk)
	backend = recreated_backend_result.get("backend") as Node3D
	world.chunk_owner = recreated_chunk
	world.backend = backend
	# A replacement chunk is a new provider authority instance. Its changed
	# capture revisions must invalidate and rebuild the retained section census.
	terrain_provider.owner_generation += 1
	ordinary_provider.owner_generation += 1
	var replay_queue_count: int = coordinator.notify_stream_chunk_loaded(Vector2i.ZERO)
	var replay_status_after_queue: Dictionary = coordinator.status()
	var replay_job_after_queue: Dictionary = coordinator._production_candidate_jobs.get(SECTION, {})
	var replay_outcome: Dictionary = await _advance_coordinator_to_install()
	var replay_live: Dictionary = backend.call("installed_snapshot", slot)
	var replay_generation := int(replay_outcome.get("reassemblyAdmission", {}).get(
		"generation", 0))
	_check("complete_candidate_survives_owner_unload_and_replays_in_new_chunk_backend",
		unloaded_sections == 1 and recreated_backend_result.get("status") == "ready"
		and replay_queue_count == 1 and replay_outcome.get("status") == "installed"
		and replay_generation > 3
		and int(replay_live.get("generation", 0)) == replay_generation
		and bool(replay_outcome.get("staleReplayAttempt", {}).get("requiresReassembly", false))
		and replay_outcome.get("reassemblyAdmission", {}).get("status") == "queued"
		and terrain_provider.install_acknowledgement_count >= 3
		and ordinary_provider.install_acknowledgement_count >= 3,
		{"unloadedSections":unloaded_sections, "recreatedBackend":recreated_backend_result.get("status"),
		"replayQueued":replay_queue_count, "replayStatusAfterQueue":replay_status_after_queue,
		"replayJobAfterQueue":replay_job_after_queue,
		"replayOutcome":replay_outcome,
		"generation":replay_live.get("generation", 0),
		"reassemblyGeneration":replay_generation,
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
	var empty_admission: Dictionary = await _admit_compiled_candidate(empty_coordinator,
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
		and int(empty_pending.get("previousGeneration", 0)) \
			== int(generation_three_snapshot.get("generation", 0)) \
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
	var cancelled_empty_admission: Dictionary = await _admit_compiled_candidate(empty_coordinator,
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
	var unload_admission: Dictionary = await _admit_compiled_candidate(empty_coordinator,
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
		pending_unload_token, {}).duplicate(false)
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
	var support_native_result: Dictionary = {"status":"not_run",
		"reason":"real_ownerless_support_section_unavailable"}
	if String(support_selection.get("status", "")) == "ready":
		support_native_result = await _install_ownerless_support_candidate(
			coordinator, backend, support_only_section, tree_source_id,
			tree_source_part_id)
	_check("real_ownerless_tree_support_candidate_installs_empty_native_layers_and_current_receipt",
		String(support_native_result.get("status", "")) == "installed"
		and bool(support_native_result.get("sourceIdentityCurrent", false))
		and bool(support_native_result.get("nativeReceiptCurrent", false))
		and bool(support_native_result.get("providerAcknowledgementCurrent", false)),
		support_native_result)
	_finish()
func _candidate_phase_timings_are_complete(admission: Dictionary) -> bool:
	var phases: Variant = admission.get("phaseUsec", null)
	if not phases is Dictionary:
		return false
	for name in ["census", "contributions", "prepare_compile", "native_compile_admission"]:
		var elapsed: Variant = phases.get(name, null)
		if not elapsed is int or elapsed < 0:
			return false
	return true


func _prepare_production_main_authority(world: WorldRoot,
		candidate_coordinator: Object) -> Dictionary:
	var main := MainScene.instantiate() as Node3D
	if not is_instance_valid(main):
		return {"status":"failed", "reason":"production_main_scene_instantiation_failed"}
	main.set("seed_text", "ecology-source-pass-slicing-parity-v1")
	main.set("seed_hash", int(main.call("hash_string", String(main.get("seed_text")))))
	main.call("apply_world_seed", String(main.get("seed_text")), false)
	main.call("setup_materials")
	main.call("setup_biome_environment_catalog")
	main.call("setup_visual_asset_registry")
	main.call("setup_animated_asset_registry")
	var structures := StructureSystemScript.new()
	main.set("structure_system", structures)
	structures.call("setup", main)
	main.set("world_static_section_coordinator", candidate_coordinator)
	var ecology_provider := EcologyAdapterScript.new()
	var configured: Dictionary = ecology_provider.call("configure", WORLD)
	if configured.get("status") != "ready":
		main.free()
		return {"status":"failed", "reason":"production_ecology_adapter_configure_failed",
			"detail":configured}
	var bound: Dictionary = ecology_provider.call("bind_main_authority", main)
	if bound.get("status") != "ready":
		main.free()
		return {"status":"failed", "reason":"production_ecology_main_bind_failed",
			"detail":bound}
	main.set("ecology_static_section_provider", ecology_provider)
	var queue: Node = main.call("ensure_tree_publication_queue") as Node
	if not is_instance_valid(queue):
		main.free()
		return {"status":"failed", "reason":"production_tree_publication_queue_unavailable"}
	queue.call("set_section_owned_publication_enabled", true)
	# Keep production Main detached so normal game startup cannot run. Its real
	# queue is parented to the headed fixture world, whose scope methods delegate
	# directly to Main's actual catalog authority; the ordinary queue frame loop
	# and tree-owned compiler lane then run without a synchronous test bypass.
	main.remove_child(queue)
	world.add_child(queue)
	world.tree_publication_queue = queue
	world.production_main_authority = main
	production_main_authority = main
	var scope: Dictionary = main.call("begin_ecology_source_catalog_context_scope")
	if String(scope.get("status", "")) != "ready":
		main.free()
		return {"status":"pending", "reason":"production_catalog_scope_pending",
			"detail":scope}
	var artifact: Dictionary = main.call("_active_ecology_catalog_artifact", WORLD,
		String(main.get("seed_text"))).get("artifact", {})
	var end_scope: Dictionary = main.call("end_ecology_source_catalog_context_scope", scope)
	var town_authority := _finalize_production_town_inputs_for_section(main, artifact,
		SECTION)
	if String(town_authority.get("status", "")) != "ready":
		main.free()
		return {"status":"failed", "reason":"production_town_dependency_closure_not_finalized",
			"detail":town_authority}
	var setup_ready: bool = not artifact.is_empty() and end_scope.get("status") == "ready" \
		and is_instance_valid(main.get("world_generation_system")) \
		and is_instance_valid(main.get("structure_system")) \
		and is_instance_valid(main.get("visual_asset_registry")) \
		and is_instance_valid(main.get("animated_asset_registry"))
	if not setup_ready:
		main.free()
		return {"status":"pending", "reason":"production_main_authorities_not_ready",
			"catalogArtifactPresent":not artifact.is_empty(), "catalogScopeClose":end_scope}
	return {"status":"ready", "main":main, "treeQueue":queue,
		"ecologyProvider":ecology_provider,
		"evidence":{"worldId":WORLD, "seed":main.get("seed_text"),
			"catalogArtifactId":String(artifact.get("artifactId", "")),
			"catalogContentDigest":String(artifact.get("catalogContentDigest", "")),
			"townDependencyClosure":town_authority,
			"structureAuthorityInstanceId":structures.get_instance_id(),
			"generationAuthorityInstanceId":main.get("world_generation_system").get_instance_id(),
			"treeQueueIsRegisteredByProductionMain":main.get("tree_publication_queue") == queue,
			"queueCatalogScopeDelegatesToProductionMain":world.production_main_authority == main}}


func _finalize_production_town_inputs_for_section(main: Object,
		catalog_artifact: Dictionary, section: Vector3i) -> Dictionary:
	if not is_instance_valid(main) or catalog_artifact.is_empty() \
			or not main.has_method("town_region") \
			or not main.has_method("finalize_production_town_inputs_for_loading"):
		return {"status":"failed", "reason":"production_town_authority_unavailable"}
	var catalog_inputs: Variant = catalog_artifact.get("catalogInputs", null)
	var tree_envelope: Variant = catalog_inputs.get("treeProducerEnvelope", {}) \
		if catalog_inputs is Dictionary else {}
	var profiles: Variant = catalog_inputs.get("biomeProfileSnapshot", {}).get("profiles", []) \
		if catalog_inputs is Dictionary else []
	var artifact_policy: Variant = catalog_artifact.get("supportPolicy", null)
	if not catalog_inputs is Dictionary or not tree_envelope is Dictionary \
			or String(tree_envelope.get("status", "")) != "ready" \
			or not profiles is Array or profiles.is_empty() \
			or not artifact_policy is Dictionary:
		return {"status":"failed", "reason":"production_town_dependency_catalog_incomplete"}
	var source_policy_inputs := {
		"schema":"ecology-source-domain-inputs/v2",
		"worldId":String(catalog_artifact.get("worldId", "")),
		"worldSeed":String(catalog_artifact.get("worldSeed", "")),
		"catalogArtifactId":String(catalog_artifact.get("artifactId", "")),
		"catalogContentDigest":String(catalog_artifact.get("catalogContentDigest", "")),
		"worldEpoch":int(catalog_artifact.get("worldEpoch", 0)),
		"influencePolicyRevision":String(artifact_policy.get("revision", "")),
		"influencePolicyDigest":String(artifact_policy.get("digest", ""))}
	source_policy_inputs.make_read_only()
	var census: Dictionary = EcologyDomain.source_domain_census_certificate(section,
		source_policy_inputs, catalog_artifact)
	if String(census.get("status", "")) != "ready" \
			or not EcologyDomain.validate_source_domain_census_certificate(census,
				section, source_policy_inputs, catalog_artifact):
		return {"status":"failed", "reason":"production_town_source_census_unavailable",
			"census":census}
	var source_chunk_keys: Variant = census.get("sourceChunkKeys", null)
	if not source_chunk_keys is Array or source_chunk_keys.is_empty():
		return {"status":"failed", "reason":"production_town_source_chunk_closure_empty"}
	var tree_trunk := float(tree_envelope.get("maxTrunkRadiusMeters", NAN))
	var tree_canopy := float(tree_envelope.get("maxCanopyRadiusMeters", NAN))
	var max_exclusion := 0.0
	for profile_value: Variant in profiles:
		if not profile_value is Dictionary:
			return {"status":"failed", "reason":"production_town_profile_row_invalid"}
		var encoded: Variant = profile_value.get("natural_prop_exclusion_margin", null)
		if not encoded is Dictionary:
			return {"status":"failed", "reason":"production_town_exclusion_margin_missing"}
		var margin_value: Variant = encoded.get("value", null)
		if not margin_value is float and not margin_value is int:
			return {"status":"failed", "reason":"production_town_exclusion_margin_invalid"}
		var margin := float(margin_value)
		if not is_finite(margin) or margin < 0.0:
			return {"status":"failed", "reason":"production_town_exclusion_margin_invalid"}
		max_exclusion = maxf(max_exclusion, margin)
	var cell_size := float(main.get("CELL"))
	var chunk_cells := int(main.get("CHUNK_SIZE"))
	var town_region_cells := int(main.get("TOWN_REGION_CELLS"))
	if not is_finite(tree_trunk) or not is_finite(tree_canopy) \
			or tree_trunk <= 0.0 or tree_canopy <= 0.0 \
			or not is_finite(cell_size) or cell_size <= 0.0 \
			or chunk_cells <= 0 or town_region_cells <= 0:
		return {"status":"failed", "reason":"production_town_dependency_dimensions_invalid"}
	var natural_margin_cells := ceili((tree_trunk + max_exclusion) / cell_size)
	var structure_margin_cells := ceili((tree_canopy + max_exclusion) / cell_size)
	var coverage_margin_cells := maxi(natural_margin_cells, structure_margin_cells)
	var required_region_set: Dictionary = {}
	for source_key_value: Variant in source_chunk_keys:
		if not source_key_value is Vector2i:
			return {"status":"failed", "reason":"production_town_source_chunk_key_invalid"}
		var source_key: Vector2i = source_key_value
		var source_bounds := Rect2i(source_key * chunk_cells, Vector2i.ONE * chunk_cells)
		var coverage_bounds := source_bounds.grow(coverage_margin_cells)
		# StructureSystem._ecology_local_town_sources expands this same coverage
		# by one adjacent town region on every side; include the exact full range
		# before CitadelTerrainAdmission freezes its production town input map.
		var low := Vector2i(
			floori(float(coverage_bounds.position.x) / town_region_cells),
			floori(float(coverage_bounds.position.y) / town_region_cells)) - Vector2i.ONE
		var high := Vector2i(
			floori(float(coverage_bounds.end.x - 1) / town_region_cells),
			floori(float(coverage_bounds.end.y - 1) / town_region_cells)) + Vector2i.ONE
		for region_z in range(low.y, high.y + 1):
			for region_x in range(low.x, high.x + 1):
				required_region_set[Vector2i(region_x, region_z)] = true
	var required_regions: Array[Vector2i] = []
	for region_value: Variant in required_region_set.keys():
		if region_value is Vector2i:
			required_regions.append(region_value)
	required_regions.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x if a.x != b.x else a.y < b.y)
	var town_region_cache: Variant = main.get("town_region_cache")
	if not town_region_cache is Dictionary:
		return {"status":"failed", "reason":"production_town_region_cache_unavailable"}
	var generated_regions: Array[Vector2i] = []
	for region: Vector2i in required_regions:
		var town_value: Variant = main.call("town_region", region.x, region.y)
		if not town_value is Dictionary or not town_region_cache.has(region):
			return {"status":"failed", "reason":"production_town_region_generation_failed",
				"region":region}
		generated_regions.append(region)
	var finalized: Dictionary = main.call("finalize_production_town_inputs_for_loading")
	if String(finalized.get("status", "")) != "ready":
		return {"status":"failed", "reason":"production_town_inputs_not_finalized",
			"detail":finalized}
	var structures: Object = main.get("structure_system")
	var admission: Variant = structures.get("citadel_terrain_admission") \
		if is_instance_valid(structures) else null
	if admission == null or not admission.has_method("finalized_town_inputs_snapshot"):
		return {"status":"failed", "reason":"production_town_admission_snapshot_unavailable"}
	var admission_snapshot: Dictionary = admission.call("finalized_town_inputs_snapshot")
	var finalized_towns: Variant = admission_snapshot.get("towns", null)
	if String(admission_snapshot.get("status", "")) != "ready" \
			or not finalized_towns is Dictionary:
		return {"status":"failed", "reason":"production_town_admission_snapshot_incomplete",
			"snapshot":admission_snapshot}
	var missing_regions: Array[Vector2i] = []
	for region: Vector2i in required_regions:
		if not town_region_cache.has(region) or not finalized_towns.has(region) \
				or finalized_towns.get(region) != town_region_cache.get(region):
			missing_regions.append(region)
	if not missing_regions.is_empty():
		return {"status":"failed", "reason":"production_town_finalized_closure_incomplete",
			"missingRegions":missing_regions}
	return {"status":"ready", "sectionKey":section,
		"sourceChunkKeys":source_chunk_keys.duplicate(),
		"sourceChunkCount":source_chunk_keys.size(),
		"townRegionKeys":generated_regions,
		"townRegionCount":generated_regions.size(),
		"townRegionCells":town_region_cells,
		"naturalMarginCells":natural_margin_cells,
		"structureMarginCells":structure_margin_cells,
		"adjacentRegionExpansion":1,
		"finalizedTownRegionCount":finalized_towns.size(),
		"finalizedTownCount":(finalized.get("towns", {}) as Dictionary).size(),
		"admissionGeneration":admission_snapshot.get("generation", -1)}


func _capture_authoritative_ecology_census(provider: Object, main: Object,
		queue: Node, section: Vector3i) -> Dictionary:
	var census: Dictionary = {}
	var last_advance: Dictionary = {}
	var first_pending_census: Dictionary = {}
	var previous_idle_pending_signature := ""
	var repeated_idle_pending_count := 0
	var structure_work_processed := 0
	var last_structure_queue_depth := 0
	var citadel_admission_advance_count := 0
	var last_citadel_admission_advance: Dictionary = {}
	var source_compile_recensus_count := 0
	var recapture_census_after_change := false
	var previous_source_job_count := -1
	var started_msec := Time.get_ticks_msec()
	# A full support census can keep many source domains deferred while structure
	# admissions settle and cohorts honor their retry cooldowns. The previous
	# 1200-frame stop left all 64 source jobs pending, so continue servicing the
	# bounded queues long enough to observe the declared retry behavior.
	for frame_index in range(3600):
		var structures: Variant = main.get("structure_system")
		var pending_structure_ops := 0
		if is_instance_valid(structures) and structures.has_method("pending_structure_op_count"):
			pending_structure_ops = int(structures.call("pending_structure_op_count"))
		# Tree recipe workers finish outside the source-domain capture queue. Their
		# immutable result is consumed only when the section provider polls the
		# retained demand again, matching Minecraft's compile-result handoff through
		# the section dispatcher. Once the source snapshots are all admitted, poll
		# that same census at a bounded cadence; existing demands are reused rather
		# than cancelled or rebuilt.
		var census_reason := String(census.get("reason", ""))
		var tree_compile_pending := census_reason.begins_with(
			"ecology_tree_recipe_") or census_reason.begins_with(
			"tree_section_compile_") or census_reason.begins_with(
			"ecology_tree_source_compile_")
		if tree_compile_pending \
				and frame_index > 0 \
				and frame_index % SOURCE_COMPILE_RECENSUS_INTERVAL_FRAMES == 0:
			var compile_poll_scheduler: Dictionary = provider.call(
				"source_capture_scheduler_snapshot")
			if int(compile_poll_scheduler.get("pendingSourceJobCount", -1)) == 0 \
					and int(compile_poll_scheduler.get("activeSourceJobCount", -1)) == 0:
				recapture_census_after_change = true
				source_compile_recensus_count += 1
		# Keep one source snapshot bound to its continuation while capture work is
		# advancing. Re-census once after the queued structure work drains, or when
		# a source explicitly reports stale inputs; polling the same census every
		# frame cancels and recreates each producer session.
		if census.is_empty() or (recapture_census_after_change \
				and pending_structure_ops == 0):
			census = provider.call("capture_static_section_sources", WORLD, [section])
			recapture_census_after_change = false
			if String(census.get("status", "")) == "complete" \
					or String(census.get("status", "")) == "failed":
				if String(census.get("status", "")) == "complete":
					_write_ecology_census_progress(frame_index, census, provider, main,
						structures, queue, last_advance, structure_work_processed,
						last_structure_queue_depth,
						Time.get_ticks_msec() - started_msec,
						source_compile_recensus_count)
				return {"census":census, "progress":{"frameCount":frame_index,
					"phase":"ecology_census_complete",
					"firstPendingCensus":first_pending_census,
					"lastCaptureAdvance":last_advance,
					"structureWorkProcessed":structure_work_processed,
					"citadelAdmissionAdvanceCount":citadel_admission_advance_count,
					"lastCitadelAdmissionAdvance":last_citadel_admission_advance,
					"sourceCompileRecensusCount":source_compile_recensus_count,
					"elapsedMsec":Time.get_ticks_msec() - started_msec}}
			if first_pending_census.is_empty():
				first_pending_census = {
					"reason":String(census.get("reason", "")),
					"diagnostic":_census_diagnostic(census),
					"supportPolicyDiagnostic":census.get("supportPolicyDiagnostic", {}),
					"firstPendingCapture":census.get("firstPendingCapture", {})}
			var capture_scheduler: Dictionary = provider.call(
				"source_capture_scheduler_snapshot")
			var queue_metrics: Dictionary = queue.call("metrics") \
				if is_instance_valid(queue) and queue.has_method("metrics") else {}
			var tree_source_compiler_progress := _tree_source_compiler_progress(queue)
			var source_compile_counts: Dictionary = tree_source_compiler_progress.get(
				"sourceCompileStatusCounts", {})
			var recipe_job_counts: Dictionary = tree_source_compiler_progress.get(
				"recipeJobStatusCounts", {})
			var source_compiler_needs_repoll := int(source_compile_counts.get("queued", 0)) \
				+ int(source_compile_counts.get("active", 0)) \
				+ int(source_compile_counts.get("failed", 0))
			var recipe_jobs_need_repoll := int(recipe_job_counts.get("queued", 0)) \
				+ int(recipe_job_counts.get("active", 0)) \
				+ int(recipe_job_counts.get("awaiting_validation", 0)) \
				+ int(recipe_job_counts.get("failed", 0))
			var source_jobs_pending := int(capture_scheduler.get(
				"pendingSourceJobCount", 0))
			if previous_source_job_count > 0 and source_jobs_pending == 0:
				recapture_census_after_change = true
			# A queued census becomes consumable only after every source-domain
			# continuation has produced its terminal receipt. Re-query exactly once
			# at that drained boundary so the adapter can admit those completed values.
			if String(census.get("reason", "")) == "ecology_source_capture_queued" \
					and source_jobs_pending == 0 \
					and int(capture_scheduler.get("activeSourceJobCount", 0)) == 0 \
					and int(capture_scheduler.get("completedSourceJobCount", 0)) > 0:
				recapture_census_after_change = true
			previous_source_job_count = source_jobs_pending
			var tree_work_pending := int(queue_metrics.get("pending", 0)) \
				+ int(queue_metrics.get("activeWorkers", 0))
			var diagnostic := _census_diagnostic(census)
			var pending_signature := JSON.stringify(diagnostic)
			var producer_work_idle := pending_structure_ops == 0 \
				and source_jobs_pending == 0 and tree_work_pending == 0 \
				and source_compiler_needs_repoll == 0 \
				and recipe_jobs_need_repoll == 0
			if producer_work_idle and pending_signature == previous_idle_pending_signature:
				repeated_idle_pending_count += 1
			elif producer_work_idle:
				repeated_idle_pending_count = 1
			else:
				repeated_idle_pending_count = 0
			previous_idle_pending_signature = pending_signature if producer_work_idle else ""
			if repeated_idle_pending_count >= 3:
				return {"census":census, "progress":{"frameCount":frame_index + 1,
					"terminalNoProgress":true, "terminalNoProgressCount":repeated_idle_pending_count,
					"terminalDiagnostic":diagnostic,
					"sourceCaptureScheduler":capture_scheduler,
					"treeQueueMetrics":queue_metrics,
					"treeSourceCompilerProgress":tree_source_compiler_progress,
					"firstPendingCensus":first_pending_census,
					"lastCaptureAdvance":last_advance,
					"structureWorkProcessed":structure_work_processed,
					"citadelAdmissionAdvanceCount":citadel_admission_advance_count,
					"lastCitadelAdmissionAdvance":last_citadel_admission_advance,
					"sourceCompileRecensusCount":source_compile_recensus_count,
					"lastStructureQueueDepth":last_structure_queue_depth,
					"elapsedMsec":Time.get_ticks_msec() - started_msec}}
		last_advance = provider.call("advance_source_domain_captures", 8, Vector3.ZERO)
		for advance_value: Variant in last_advance.get("results", []):
			if advance_value is Dictionary \
					and bool(advance_value.get("requiresRecapture", false)):
				recapture_census_after_change = true
		# The census result above is a snapshot from before this scheduler turn.
		# If the last queued source job completed during the advance, that snapshot
		# is now stale and nobody will wake the fixture to consume the ready value.
		# Re-census once at the drained boundary so the next frame observes the
		# admitted publication receipt and continues toward section compilation.
		if String(census.get("reason", "")) == "ecology_source_capture_queued" \
				and int(last_advance.get("pendingJobCount", -1)) == 0:
			var post_advance_scheduler: Dictionary = provider.call(
				"source_capture_scheduler_snapshot")
			if int(post_advance_scheduler.get("pendingSourceJobCount", -1)) == 0 \
					and int(post_advance_scheduler.get("activeSourceJobCount", -1)) == 0:
				recapture_census_after_change = true
		# Main is deliberately detached so the fixture cannot start normal gameplay.
		# Advance the same bounded StructureSystem operation queue that
		# process_streaming_structure_work services during ordinary runtime.
		if is_instance_valid(structures) and structures.has_method("process_pending_structure_ops"):
			var processed_structure_ops := int(structures.call(
				"process_pending_structure_ops"))
			structure_work_processed += processed_structure_ops
			if processed_structure_ops > 0:
				recapture_census_after_change = true
		# Main is detached, so VoxelTerrainRuntime cannot run its VoxelTerrainSiteGate.
		# Advance the same Citadel admission owner and refresh generated site profiles
		# that the gate services each runtime frame; otherwise natural prop capture
		# remains correctly blocked on an admission request no owner is advancing.
		if is_instance_valid(structures):
			var admission: Variant = structures.get("citadel_terrain_admission")
			if is_instance_valid(admission) and admission.has_method("advance"):
				last_citadel_admission_advance = admission.call("advance")
				citadel_admission_advance_count += 1
			var generation: Variant = main.get("world_generation_system")
			if is_instance_valid(generation) \
					and generation.has_method("refresh_generated_site_profiles"):
				generation.call("refresh_generated_site_profiles")
		if is_instance_valid(structures) and structures.has_method("pending_structure_op_count"):
			last_structure_queue_depth = int(structures.call("pending_structure_op_count"))
		if frame_index % 30 == 0:
			_write_ecology_census_progress(frame_index, census, provider, main, structures, queue,
				last_advance, structure_work_processed, last_structure_queue_depth,
				Time.get_ticks_msec() - started_msec, source_compile_recensus_count)
		await process_frame
	return {"census":census, "progress":{"frameCount":3600,
		"firstPendingCensus":first_pending_census,
		"lastCaptureAdvance":last_advance,
		"structureWorkProcessed":structure_work_processed,
		"citadelAdmissionAdvanceCount":citadel_admission_advance_count,
		"lastCitadelAdmissionAdvance":last_citadel_admission_advance,
		"sourceCompileRecensusCount":source_compile_recensus_count,
		"treeSourceCompilerProgress":_tree_source_compiler_progress(queue),
		"lastStructureQueueDepth":last_structure_queue_depth,
		"elapsedMsec":Time.get_ticks_msec() - started_msec,
		"sourceCaptureCohorts":provider.get("_source_capture_cohorts"),
		"sourceCaptureServiceOpportunities":provider.get("_source_capture_service_opportunities"),
		"sourceCaptureActiveCohortCount":provider.get("_source_capture_active_cohort_count"),
		"sourceCaptureJobs":_source_capture_job_summary(provider),
		"citadelAdmission":main.get("structure_system").get("citadel_terrain_admission").stats(),
		"captureDiagnostics":main.call("ecology_source_capture_diagnostics_snapshot"),
		"queueMetrics":queue.call("metrics")}}


func _source_capture_job_summary(provider: Object) -> Dictionary:
	const MAX_SAMPLE_ROWS := 8
	var jobs_value: Variant = provider.get("_source_capture_jobs") \
		if is_instance_valid(provider) else null
	if not jobs_value is Dictionary:
		return {"schema":"whole-section-source-capture-job-summary/v1",
			"status":"unavailable", "jobCount":0, "statusCounts":{}, "sample":[]}
	var job_keys: Array[String] = []
	var status_counts: Dictionary = {}
	for key_value: Variant in jobs_value.keys():
		var key := String(key_value)
		var job_value: Variant = jobs_value.get(key_value, null)
		if not job_value is Dictionary:
			continue
		var status := String(job_value.get("status", "unknown"))
		status_counts[status] = int(status_counts.get(status, 0)) + 1
		job_keys.append(key)
	job_keys.sort()
	var sample: Array[Dictionary] = []
	for key: String in job_keys:
		if sample.size() >= MAX_SAMPLE_ROWS:
			break
		var job: Dictionary = jobs_value.get(key, {})
		var source_chunk: Variant = job.get("sourceChunkKey", null)
		sample.append({"identityPrefix":String(job.get("identity", key)).substr(0, 12),
			"sourceChunkKey":source_chunk if source_chunk is Vector2i else null,
			"requestedFamilies":job.get("requestedFamilies", []),
			"status":String(job.get("status", "unknown")),
			"attempts":int(job.get("attempts", 0)),
			"lastReason":String(job.get("lastReason", "")),
			"sourcePublicationId":String(job.get("sourcePublicationId", "")),
			"stalledAttempts":int(job.get("stalledAttempts", 0))})
	return {"schema":"whole-section-source-capture-job-summary/v1",
		"status":"ready", "jobCount":job_keys.size(),
		"statusCounts":status_counts, "sample":sample,
		"sampleLimit":MAX_SAMPLE_ROWS}


func _write_ecology_census_progress(frame_index: int, census: Dictionary,
		provider: Object, main: Object, structures: Variant, queue: Node,
		last_advance: Dictionary, structure_work_processed: int,
		structure_queue_depth: int, elapsed_msec: int,
		source_compile_recensus_count: int) -> void:
	if progress_path.is_empty():
		return
	var standalone_requests: Variant = structures.get("regional_standalone_requests") \
		if is_instance_valid(structures) else null
	var citadel_admission: Variant = structures.get("citadel_terrain_admission") \
		if is_instance_valid(structures) else null
	var generated_standalone: Variant = structures.get("generated_structures") \
		if is_instance_valid(structures) else null
	var generated_towns: Variant = structures.get("generated_towns") \
		if is_instance_valid(structures) else null
	var source_capture_jobs: Array[Dictionary] = []
	var source_capture_jobs_value: Variant = provider.get("_source_capture_jobs")
	if source_capture_jobs_value is Dictionary:
		for job_value: Variant in source_capture_jobs_value.values():
			if not job_value is Dictionary:
				continue
			var job: Dictionary = job_value
			source_capture_jobs.append({
				"identityPrefix":String(job.get("identity", "")).substr(0, 12),
				"sourceChunkKey":job.get("sourceChunkKey", Vector2i.ZERO),
				"requestedFamilies":job.get("requestedFamilies", []),
				"status":String(job.get("status", "")),
				"attempts":int(job.get("attempts", 0)),
				"lastReason":String(job.get("lastReason", "")),
				"sourcePublicationId":String(job.get("sourcePublicationId", "")),
				"stalledAttempts":int(job.get("stalledAttempts", 0)),
				"captureProgress":job.get("captureProgress", {})})
	var payload := {"schema":"whole-section-ecology-census-progress/v1",
		"frameIndex":frame_index, "elapsedMsec":elapsed_msec,
		"censusStatus":String(census.get("status", "")),
		"censusReason":String(census.get("reason", "")),
		"censusDiagnostic":_census_diagnostic(census),
		"structureWorkProcessed":structure_work_processed,
		"structureQueueDepth":structure_queue_depth,
		"sourceCompileRecensusCount":source_compile_recensus_count,
		"treeSourceCompilerProgress":_tree_source_compiler_progress(queue),
		"regionalStandaloneRequests":standalone_requests.size() \
			if standalone_requests is Dictionary else 0,
		"generatedStandaloneRegions":generated_standalone.size() \
			if generated_standalone is Dictionary else 0,
		"generatedTownRegions":generated_towns.size() \
			if generated_towns is Dictionary else 0,
		"citadelAdmissionStats":citadel_admission.call("stats") \
			if is_instance_valid(citadel_admission) and citadel_admission.has_method("stats") else {},
		"captureDiagnostics":main.call("ecology_source_capture_diagnostics_snapshot") \
			if main.has_method("ecology_source_capture_diagnostics_snapshot") else {},
		"sourceCaptureJobs":source_capture_jobs,
		"captureScheduler":provider.call("source_capture_scheduler_snapshot") \
			if provider.has_method("source_capture_scheduler_snapshot") else {},
		"treeQueueMetrics":queue.call("metrics") \
			if is_instance_valid(queue) and queue.has_method("metrics") else {},
		"lastCaptureAdvance":last_advance}
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.flush()
	file.close()


func _tree_source_compiler_progress(queue: Node) -> Dictionary:
	var result := {"schema":"whole-section-tree-source-compiler-progress/v1",
		"sourceCompileStatusCounts":{}, "sourceCompileSample":[],
		"recipeJobStatusCounts":{}, "recipeJobSample":[]}
	if not is_instance_valid(queue):
		result["status"] = "queue_unavailable"
		return result
	var compile_jobs_value: Variant = queue.get("ecology_source_compile_jobs")
	var compile_jobs: Dictionary = compile_jobs_value \
		if compile_jobs_value is Dictionary else {}
	var compile_status_counts: Dictionary = {}
	var compile_sample: Array[Dictionary] = []
	for key_value: Variant in compile_jobs.keys():
		var key := String(key_value)
		var job_value: Variant = compile_jobs.get(key_value, {})
		if not job_value is Dictionary:
			continue
		var job: Dictionary = job_value
		var status := String(job.get("status", "unknown"))
		compile_status_counts[status] = int(compile_status_counts.get(status, 0)) + 1
		if status not in ["queued", "active", "failed"] or compile_sample.size() >= 8:
			continue
		var compiler: Variant = job.get("compiler", null)
		var progress: Dictionary = compiler.call("progress_snapshot") \
			if is_instance_valid(compiler) and compiler.has_method("progress_snapshot") else {}
		compile_sample.append({"keyPrefix":key.substr(0, 28),
			"sourceChunkKey":job.get("sourceChunkKey", Vector2i.ZERO),
			"status":status,
			"reason":String(job.get("reason", "")),
			"workUnits":int(job.get("workUnits", 0)),
			"compilerProgress":progress})
	var recipe_jobs_value: Variant = queue.get("source_recipe_jobs")
	var recipe_jobs: Dictionary = recipe_jobs_value \
		if recipe_jobs_value is Dictionary else {}
	var recipe_status_counts: Dictionary = {}
	var recipe_sample: Array[Dictionary] = []
	for key_value: Variant in recipe_jobs.keys():
		var key := String(key_value)
		var task_value: Variant = recipe_jobs.get(key_value, {})
		if not task_value is Dictionary:
			continue
		var task: Dictionary = task_value
		var status := String(task.get("status", "unknown"))
		recipe_status_counts[status] = int(recipe_status_counts.get(status, 0)) + 1
		if status not in ["queued", "active", "awaiting_validation", "failed"] \
				or recipe_sample.size() >= 8:
			continue
		var thread := task.get("thread") as Thread
		recipe_sample.append({"keyPrefix":key.substr(0, 28),
			"sourceId":String(task.get("sourceId", "")), "status":status,
			"stage":String(task.get("stage", "")),
			"reason":String(task.get("reason", "")),
			"threadAlive":thread != null and thread.is_alive()})
	result["sourceCompileStatusCounts"] = compile_status_counts
	result["sourceCompileSample"] = compile_sample
	result["recipeJobStatusCounts"] = recipe_status_counts
	result["recipeJobSample"] = recipe_sample
	result["status"] = "ready"
	return result


func _census_diagnostic(census: Dictionary) -> Dictionary:
	var diagnostic := {}
	for key in ["reason", "sourceChunkKey", "sourceId", "sourcePartId", "family",
			"stage", "sectionKey", "retryable", "disposition",
			"sourceJobIdentity", "pendingSourceJobCount", "captureProgress",
			"meshFingerprintStatus", "meshDigestLength", "declaredMeshDigestLength",
			"meshDigestMatches", "materialDigestLength",
			"declaredMaterialDigestLength", "materialDigestMatches",
			"resourceDescriptorRevisionLength"]:
		if census.has(key):
			diagnostic[key] = census[key]
	return diagnostic


func _select_tree_support_pair_from_census(census: Dictionary, queue: Object,
		section: Vector3i, required_owner_cell: Vector2i) -> Dictionary:
	var section_row: Dictionary = census.get("sections", {}).get(section, {})
	var source_parts: Array[Dictionary] = []
	for identity_value: Variant in section_row.get("sourceParts", []):
		if not identity_value is Dictionary:
			continue
		var identity: Dictionary = identity_value
		var source_id: String = String(identity.get("sourceId", ""))
		var source_part_id: String = String(identity.get("sourcePartId", ""))
		if source_id.contains(":tree:") and not source_part_id.is_empty():
			source_parts.append(identity)
	source_parts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_source: String = String(a.get("sourceId", ""))
		var b_source: String = String(b.get("sourceId", ""))
		if a_source != b_source:
			return a_source < b_source
		return String(a.get("sourcePartId", "")) < String(b.get("sourcePartId", "")))
	var diagnostics: Array[Dictionary] = []
	for identity: Dictionary in source_parts:
		var source_id: String = String(identity.get("sourceId", ""))
		var source_part_id: String = String(identity.get("sourcePartId", ""))
		var artifact: Dictionary = _tree_band_artifact_for_source(queue, section, source_id)
		var selection: Dictionary = _select_ownerless_support_section(artifact,
			source_id, source_part_id, section, required_owner_cell)
		if String(selection.get("status", "")) == "ready":
			return {"status":"ready", "identity":identity, "artifact":artifact,
				"supportSelection":selection, "candidateDiagnostics":diagnostics}
		if diagnostics.size() < 8:
			diagnostics.append({"sourceId":source_id,
				"sourcePartId":source_part_id,
				"artifactStatus":"ready" if not artifact.is_empty() else "missing",
				"selectionReason":String(selection.get("reason", "")),
				"matchingSourceRows":int(selection.get("matchingSourceRows", 0)),
				"matchingMemberRows":int(selection.get("matchingMemberRows", 0)),
				"candidateCount":int(selection.get("candidateCount", 0))})
	return {"status":"failed", "reason":"no_census_tree_member_has_ownerless_support_in_backend_cell",
		"identity":{}, "artifact":{}, "supportSelection":{"status":"failed",
			"reason":"no_eligible_tree_member"}, "candidateDiagnostics":diagnostics,
		"censusStatus":String(census.get("status", "")),
		"censusReason":String(census.get("reason", ""))}


func _tree_band_artifact_for_source(queue: Object, section: Vector3i,
		source_id: String) -> Dictionary:
	if not is_instance_valid(queue) or source_id.is_empty():
		return {}
	var jobs_value: Variant = queue.get("ecology_tree_band_compile_jobs")
	if not jobs_value is Dictionary:
		return {}
	for job_value: Variant in jobs_value.values():
		if not job_value is Dictionary:
			continue
		var job: Dictionary = job_value
		if job.get("sectionKey", null) != section or String(job.get("status", "")) != "complete":
			continue
		var source_chunk_value: Variant = job.get("sourceChunkKey", null)
		var snapshot_value: Variant = job.get("snapshot", null)
		var authority_value: Variant = job.get("authority", null)
		var expected_ids_value: Variant = job.get("expectedSourceIds", null)
		if not source_chunk_value is Vector2i or not snapshot_value is Dictionary \
				or not authority_value is Dictionary or not expected_ids_value is Array \
				or authority_value.get("sectionKey", null) != section \
				or authority_value.get("sourceChunkKey", null) != source_chunk_value \
				or String(authority_value.get("sourceRevision", "")) \
					!= String(snapshot_value.get("sourceRevision", "")):
			continue
		var artifact_value: Variant = job.get("artifact", null)
		if not artifact_value is Dictionary or not artifact_value.is_read_only() \
				or String(artifact_value.get("schema", "")) \
				!= "compiled-tree-section-source/v2" \
				or artifact_value.get("sectionKey", null) != section \
				or artifact_value.get("sourceChunkKey", null) != source_chunk_value \
				or String(artifact_value.get("sourceRevision", "")) \
					!= String(snapshot_value.get("sourceRevision", "")) \
				or String(artifact_value.get("authorityDigest", "")) \
					!= String(job.get("authorityDigest", "")) \
				or String(job.get("authorityDigest", "")) \
					!= String(authority_value.get("authorityDigest", "")) \
				or artifact_value.get("expectedSourceIds", []) != expected_ids_value:
			continue
		if source_id in expected_ids_value:
			return artifact_value
	return {}


func _tree_owner_buffer_alias_evidence(artifact: Dictionary,
		contribution: Dictionary, source_id: String, source_part_id: String,
		candidate_source_revision: String) -> Dictionary:
	if String(artifact.get("schema", "")) != "compiled-tree-section-source/v2" \
			or not artifact.is_read_only() or not contribution.is_read_only():
		return {"status":"failed", "reason":"sealed_artifact_or_contribution_unavailable"}
	var owner_buffer: Variant = null
	var artifact_revision: String = ""
	var artifact_instance_count: int = -1
	var owner_rows: int = 0
	for batch_value: Variant in artifact.get("batches", []):
		if not batch_value is Dictionary:
			continue
		var batch: Dictionary = batch_value
		var members_value: Variant = batch.get("contributors", null)
		if not members_value is Dictionary:
			continue
		for member_value: Variant in members_value.values():
			if not member_value is Dictionary:
				continue
			var member: Dictionary = member_value
			if String(member.get("sourceId", "")) != source_id \
					or String(member.get("sourcePartId", "")) != source_part_id:
				continue
			owner_rows += 1
			owner_buffer = member.get("instanceAttributes", null)
			artifact_revision = String(member.get("sourceRevision", ""))
			artifact_instance_count = int(member.get("instanceCount", -1))
	var adapter_buffer: Variant = null
	var adapter_revision: String = ""
	var adapter_instance_count: int = -1
	var input_rows: int = 0
	for input_value: Variant in contribution.get("inputs", []):
		if not input_value is Dictionary:
			continue
		var input: Dictionary = input_value
		if String(input.get("sourceId", "")) != source_id \
				or String(input.get("sourcePartId", "")) != source_part_id:
			continue
		input_rows += 1
		adapter_buffer = input.get("buffer", null)
		adapter_revision = String(input.get("sourceRevision", ""))
		adapter_instance_count = int(input.get("instanceCount", -1))
	var same_buffer: bool = owner_buffer is Array and adapter_buffer is Array \
		and is_same(owner_buffer, adapter_buffer)
	var valid_buffer: bool = same_buffer and owner_buffer.get_typed_builtin() == TYPE_FLOAT \
		and owner_buffer.is_read_only() and artifact_instance_count > 0 \
		and artifact_instance_count == adapter_instance_count \
		and owner_buffer.size() == artifact_instance_count * Attributes.FLOATS_PER_INSTANCE
	var identity_valid: bool = not candidate_source_revision.is_empty() \
		and candidate_source_revision == artifact_revision \
		and candidate_source_revision == adapter_revision
	return {"status":"ready" if owner_rows == 1 and input_rows == 1 \
		and valid_buffer and identity_valid else "failed",
		"reason":"" if owner_rows == 1 and input_rows == 1 \
			and valid_buffer and identity_valid else "typed_owner_buffer_alias_or_revision_mismatch",
		"sourceId":source_id, "sourcePartId":source_part_id,
		"ownerRows":owner_rows, "adapterInputRows":input_rows,
		"candidateSourceRevision":candidate_source_revision,
		"artifactSourceRevision":artifact_revision,
		"adapterSourceRevision":adapter_revision,
		"artifactInstanceCount":artifact_instance_count,
		"adapterInstanceCount":adapter_instance_count,
		"typedBuiltin":owner_buffer.get_typed_builtin() if owner_buffer is Array else -1,
		"readonly":owner_buffer.is_read_only() if owner_buffer is Array else false,
		"sameTypedReadonlyBuffer":valid_buffer}


func _select_ownerless_support_section(artifact: Dictionary,
		source_id: String, source_part_id: String, excluded_section: Vector3i,
		required_owner_cell: Vector2i) -> Dictionary:
	var sources_value: Variant = artifact.get("sources", null)
	if source_id.is_empty() or source_part_id.is_empty() \
			or not sources_value is Array or not artifact.is_read_only():
		return {"status":"failed", "reason":"sealed_tree_source_manifest_unavailable"}
	var by_section: Dictionary = {}
	var all_geometry_owner_sections: Dictionary = {}
	var matching_source_rows: int = 0
	var matching_member_rows: int = 0
	var primary_owner_member_rows: int = 0
	for source_value: Variant in sources_value:
		if not source_value is Dictionary:
			continue
		var source: Dictionary = source_value
		var source_matches: bool = String(source.get("sourceId", "")) == source_id
		if source_matches:
			matching_source_rows += 1
		for member_value: Variant in source.get("geometryOwnership", []):
			if not member_value is Dictionary:
				continue
			var member: Dictionary = member_value
			var owner_value: Variant = member.get("ownedSectionKey",
				member.get("geometryOwnerSectionKey", null))
			var supports_value: Variant = member.get("supportSectionKeys", null)
			if not owner_value is Vector3i:
				continue
			all_geometry_owner_sections[owner_value] = true
			var member_id: String = String(member.get("memberId", ""))
			if not source_matches or member_id != source_part_id:
				continue
			matching_member_rows += 1
			if owner_value != excluded_section:
				continue
			primary_owner_member_rows += 1
			if member_id.is_empty() or not supports_value is Array:
				continue
			var identity: String = source_id + "|" + member_id
			for support_value: Variant in supports_value:
				if not support_value is Vector3i:
					continue
				var support_section: Vector3i = support_value
				if not by_section.has(support_section):
					by_section[support_section] = {"owners":{}, "supports":{}}
				var row: Dictionary = by_section[support_section]
				row.supports[identity] = true
				if owner_value == support_section:
					row.owners[identity] = true
	if matching_source_rows != 1 or matching_member_rows != 1 \
				or primary_owner_member_rows != 1:
		return {"status":"failed", "reason":"tree_owner_identity_not_unique_for_primary_section",
			"sourceId":source_id, "sourcePartId":source_part_id,
			"matchingSourceRows":matching_source_rows,
			"matchingMemberRows":matching_member_rows,
			"primaryOwnerMemberRows":primary_owner_member_rows,
			"artifactGeometryOwnerSectionCount":all_geometry_owner_sections.size(),
			"candidateCount":0, "candidates":[]}
	var candidates: Array[Vector3i] = []
	for section_value: Variant in by_section:
		if not section_value is Vector3i:
			continue
		var section_key: Vector3i = section_value
		var row: Dictionary = by_section[section_key]
		if section_key != excluded_section \
				and not all_geometry_owner_sections.has(section_key) \
				and row.owners.is_empty() \
				and not row.supports.is_empty() \
				and Grid.chunk_key_for_section(section_key) == required_owner_cell:
			candidates.append(section_key)
	candidates.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var da: int = absi(a.x - excluded_section.x) + absi(a.y - excluded_section.y) \
			+ absi(a.z - excluded_section.z)
		var db: int = absi(b.x - excluded_section.x) + absi(b.y - excluded_section.y) \
			+ absi(b.z - excluded_section.z)
		if da != db: return da < db
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var rows: Array[Dictionary] = []
	for section_key: Vector3i in candidates.slice(0, 8):
		var row: Dictionary = by_section[section_key]
		rows.append({"sectionKey":section_key,
			"ownerMemberCount":row.owners.size(),
			"supportMemberCount":row.supports.size(),
			"ownerCell":Grid.chunk_key_for_section(section_key)})
	return {"status":"ready" if not candidates.is_empty() else "failed",
		"reason":"" if not candidates.is_empty() \
			else "sealed_manifest_has_no_ownerless_support_in_loaded_backend_cell",
		"sectionKey":candidates[0] if not candidates.is_empty() else Vector3i.ZERO,
		"sourceId":source_id, "sourcePartId":source_part_id,
		"matchingSourceRows":matching_source_rows,
		"matchingMemberRows":matching_member_rows,
		"primaryOwnerMemberRows":primary_owner_member_rows,
		"artifactGeometryOwnerSectionCount":all_geometry_owner_sections.size(),
		"candidateCount":candidates.size(), "candidates":rows}


func _install_ownerless_support_candidate(owner_coordinator: Object,
		backend: Node, section_key: Vector3i, source_id: String,
		source_part_id: String) -> Dictionary:
	if not is_instance_valid(owner_coordinator) or not is_instance_valid(backend) \
			or source_id.is_empty() or source_part_id.is_empty():
		return {"status":"failed", "reason":"ownerless_support_install_input_missing"}
	var admission: Dictionary = await _admit_compiled_candidate(owner_coordinator,
		section_key, 1)
	if admission.get("status") != "queued":
		return {"status":"failed", "reason":"ownerless_support_candidate_not_queued",
			"admission":admission, "sectionKey":section_key}
	var candidate_value: Variant = owner_coordinator._production_candidate_jobs.get(
		section_key, {}).get("candidate", {})
	if not candidate_value is Dictionary or not candidate_value.is_read_only():
		return {"status":"failed", "reason":"ownerless_support_candidate_missing",
			"admission":admission}
	var candidate: Dictionary = candidate_value
	var replacement: Dictionary = candidate.get("candidate", {})
	var snapshot: Dictionary = replacement.get("snapshot", {})
	var manifest: Variant = snapshot.get("manifest", null)
	var batches: Variant = snapshot.get("batches", null)
	var support_identities: Variant = candidate.get("supportCoverageIdentities", null)
	var provider_has_tree_support: bool = false
	var support_coverage_digest: String = ""
	if support_identities is Array:
		for identity_value: Variant in support_identities:
			if identity_value is Dictionary and String(identity_value.get("providerId", "")) \
					== EcologyAdapterScript.PROVIDER_ID \
					and identity_value.get("sectionKey", null) == section_key:
				provider_has_tree_support = true
				support_coverage_digest = String(identity_value.get("coverageDigest", ""))
	var candidate_source_revision: String = String(candidate.get("sourceRevisions", {}).get(
		_identity_key(source_id, source_part_id), ""))
	var exact_support_member_present: bool = false
	var all_manifest_members_support_only: bool = manifest is Array and not manifest.is_empty()
	if manifest is Array:
		for manifest_value: Variant in manifest:
			if not manifest_value is Dictionary:
				all_manifest_members_support_only = false
				continue
			var manifest_row: Dictionary = manifest_value
			if String(manifest_row.get("contributorKind", "")) != "support_only" \
					or manifest_row.get("supportRanges", []).is_empty() \
					or not manifest_row.get("batchKeys", []).is_empty():
				all_manifest_members_support_only = false
			if String(manifest_row.get("sourceId", "")) == source_id \
					and String(manifest_row.get("sourcePartId", "")) == source_part_id \
					and String(manifest_row.get("sourceRevision", "")) == candidate_source_revision \
					and String(manifest_row.get("contributorKind", "")) == "support_only":
				exact_support_member_present = true
	var native_compile_receipt: Dictionary = owner_coordinator._production_candidate_jobs.get(
		section_key, {}).get("candidate", {}).get("nativeCompileReceipt", {})
	var empty_candidate: bool = all_manifest_members_support_only \
		and exact_support_member_present \
		and batches is Dictionary and batches.is_empty() \
		and int(snapshot.get("instanceCount", -1)) == 0
	if not empty_candidate or not provider_has_tree_support \
			or support_coverage_digest.is_empty() \
			or candidate_source_revision.is_empty() \
			or native_compile_receipt.get("status") != "compiled":
		return {"status":"failed", "reason":"ownerless_support_candidate_not_explicit_empty",
			"sectionKey":section_key, "manifestCount":manifest.size() if manifest is Array else -1,
			"allManifestMembersSupportOnly":all_manifest_members_support_only,
			"exactSupportMemberPresent":exact_support_member_present,
			"batchCount":batches.size() if batches is Dictionary else -1,
			"instanceCount":snapshot.get("instanceCount", -1),
			"providerHasTreeSupport":provider_has_tree_support,
			"supportCoverageDigest":support_coverage_digest,
			"candidateSourceRevision":candidate_source_revision,
			"nativeCompileReceipt":native_compile_receipt}
	var slot: String = InstallSession.slot_id(WORLD, section_key)
	var previous: Dictionary = backend.call("installed_snapshot", slot)
	var outcome: Dictionary = {"status":"not_started"}
	for frame_index in range(1200):
		outcome = owner_coordinator.advance_complete_section_candidate(section_key, 8)
		if outcome.get("stage") == "awaiting_frame" \
				or outcome.get("status") in ["installed", "failed", "cancelled"]:
			break
		await process_frame
	var pending: Dictionary = backend.call("pending_presentation_snapshot", slot)
	var pending_matches: bool = outcome.get("stage") == "awaiting_frame" \
		and pending.get("status") == "pending_presentation" \
		and pending.get("sourceId") == slot \
		and int(pending.get("generation", 0)) == 1 \
		and String(pending.get("packetDigest", "")) \
			== String(candidate.get("contentManifestDigest", "")) \
		and int(pending.get("instanceCount", -1)) == 0 \
		and pending.get("layers", []).size() == 3 \
		and pending.get("layers", []).all(func(layer: Dictionary) -> bool:
			return String(layer.get("status", "")) == "empty" \
				and int(layer.get("expectedBatchCount", -1)) == 0 \
				and int(layer.get("expectedInstanceCount", -1)) == 0)
	if pending_matches:
		await process_frame
		outcome = owner_coordinator.advance_complete_section_candidate(section_key, 8)
	var installed: Dictionary = backend.call("installed_snapshot", slot)
	var receipt: Dictionary = owner_coordinator._production_candidate_receipts.get(
		section_key, {})
	var native_receipt_current: bool = outcome.get("status") == "installed" \
		and installed.get("status") == "ready" \
		and installed.get("sourceId") == slot \
		and int(installed.get("generation", 0)) == 1 \
		and int(installed.get("instanceCount", -1)) == 0 \
		and String(installed.get("packetDigest", "")) \
			== String(candidate.get("contentManifestDigest", "")) \
		and bool(backend.call("receipt_installed", slot, 1,
			"%s:%d" % [WORLD, 1], String(candidate.get("contentManifestDigest", "")))) \
		and owner_coordinator.installed_section_receipt_is_current(section_key, receipt)
	var ack_proof: Dictionary = owner_coordinator.source_install_acknowledgement_proof(
		section_key, receipt)
	for _ack_frame in range(120):
		if ack_proof.get("status") in ["ready", "failed", "stale"]:
			break
		owner_coordinator.advance_queued_complete_section_candidates(1, 1)
		await process_frame
		ack_proof = owner_coordinator.source_install_acknowledgement_proof(
			section_key, receipt)
	var source_identity_current: Dictionary = owner_coordinator.capture_authoritative_source_census(
		[section_key])
	var identity_key: String = _identity_key(source_id, source_part_id)
	var census_identity_current: bool = String(source_identity_current.get("status", "")) \
		== "complete" and String(source_identity_current.get("censusDigest", "")) \
			== String(candidate.get("censusDigest", "")) \
		and String(source_identity_current.get("sourceRevisions", {}).get(identity_key, "")) \
			== candidate_source_revision
	return {"status":"installed" if native_receipt_current and pending_matches \
		and census_identity_current else "failed",
		"reason":"" if native_receipt_current and pending_matches and census_identity_current \
			else "ownerless_support_native_receipt_or_identity_not_current",
		"sectionKey":section_key, "sourceId":source_id,
		"sourcePartId":source_part_id, "sourceRevision":candidate_source_revision,
		"sourceIdentityCurrent":census_identity_current,
		"censusStatus":source_identity_current.get("status", ""),
		"censusReason":source_identity_current.get("reason", ""),
		"censusDigestMatches":String(source_identity_current.get("censusDigest", "")) \
			== String(candidate.get("censusDigest", "")),
		"providerAcknowledgementCurrent":ack_proof.get("status") == "ready",
		"providerAcknowledgement":ack_proof,
		"nativeReceiptCurrent":native_receipt_current,
		"pendingPresentationMatchesExactCandidate":pending_matches,
		"candidateContentManifestDigest":candidate.get("contentManifestDigest", ""),
		"candidateSupportCoverageDigest":support_coverage_digest,
		"nativeCompileReceipt":native_compile_receipt,
		"previousSlot":previous, "pendingPresentation":pending,
		"installedSnapshot":installed, "installOutcome":outcome,
		"coordinatorReceipt":receipt}


func _identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty():
		return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()


func _census_has_source_identity(census: Dictionary, section: Vector3i,
		identity: Dictionary) -> bool:
	var source_id := String(identity.get("sourceId", ""))
	var source_part_id := String(identity.get("sourcePartId", ""))
	for identity_value: Variant in census.get("sections", {}).get(section, {}).get(
			"sourceParts", []):
		if identity_value is Dictionary \
				and String(identity_value.get("sourceId", "")) == source_id \
				and String(identity_value.get("sourcePartId", "")) == source_part_id:
			return true
	return false


func _advance_coordinator_to_install(main: Object = null,
		detail_material_before_install: Dictionary = {}) -> Dictionary:
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
			var detail_material_at_reassembly := _detail_material_diagnostic(main)
			var previous_candidate: Dictionary = coordinator._production_candidates_by_section.get(
				SECTION, {})
			var generation_floor := int(previous_candidate.get("generation", 0))
			var compile_jobs: Dictionary = coordinator.get("_section_compile_jobs")
			var pending_compile: Dictionary = compile_jobs.get(SECTION, {})
			generation_floor = maxi(generation_floor,
				int(pending_compile.get("generation", 0)))
			generation_floor = maxi(generation_floor,
				int(coordinator.get("_production_candidate_generation")))
			var next_generation := generation_floor + 1
			reassembly_admission = await _admit_compiled_candidate(coordinator,
				SECTION, next_generation)
			if reassembly_admission.get("status") != "queued":
				return {"status":"failed", "reason":"owner_replay_reassembly_not_queued",
					"staleAttempt":stale_replay_attempt,
					"detailMaterialBeforeInstall":detail_material_before_install,
					"detailMaterialAtReassembly":detail_material_at_reassembly,
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


func _detail_material_diagnostic(main: Object) -> Dictionary:
	if not is_instance_valid(main) or not main.has_method("detail_material"):
		return {"status":"unavailable"}
	var material: Material = main.call("detail_material", "pebble")
	if not is_instance_valid(material):
		return {"status":"unavailable"}
	var result := {"status":"ready", "materialClass":material.get_class(),
		"contentDigest":EcologyAdapterScript._material_digest(material)}
	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		var parameters := {}
		if shader != null:
			for uniform_value: Variant in shader.get_shader_uniform_list():
				if uniform_value is Dictionary:
					var name := String(uniform_value.get("name", ""))
					if not name.begins_with("global_"):
						parameters[name] = (material as ShaderMaterial).get_shader_parameter(name)
		result["parameters"] = parameters
	return result


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
	if is_instance_valid(production_main_authority):
		var queue_value: Variant = production_main_authority.get("tree_publication_queue")
		production_main_authority.call("reset_ecology_source_capture_sessions")
		if is_instance_valid(queue_value) and queue_value is Node:
			(queue_value as Node).set_process(false)
			(queue_value as Node).free()
		production_main_authority.set("tree_publication_queue", null)
		production_main_authority.free()
		production_main_authority = null
	var report := {"schema":"whole-section-candidate-native-install/v1",
		"complete":true, "passed":failed.is_empty(), "checks":checks,
		"checkCount":checks.size(), "failedChecks":failed,
		"evidenceLevel":"headed real Main.tscn ecology source authority, complete certified source-domain census, production tree source compiler, and assembled section candidate installed by the native chunk renderer; terrain and ordinary providers remain fixture producers",
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
	var terrain_provider := _make_lifecycle_provider("terrain", "terrain-authority:fixture",
		"terrain:fixture:0", "terrain-r1")
	var ordinary_provider := _make_lifecycle_provider("ordinary", "ordinary-authority:fixture",
		"ordinary:fixture:0", "ordinary-r1")
	coordinator.register_source_provider("terrain", terrain_provider, "capture_static_section_sources")
	coordinator.register_source_provider("ordinary", ordinary_provider, "capture_static_section_sources")
	var complete_census: Dictionary = coordinator.capture_authoritative_source_census([SECTION])
	var census_sections: Array = complete_census.get("sections", [])
	var expected_rows: Array = complete_census.get("expectedContributorsBySection", {}).get(SECTION, [])
	var terrain_identity_key := CensusProvider._identity_key(terrain_provider.source_id,
		terrain_provider.source_part_id)
	var ordinary_identity_key := CensusProvider._identity_key(ordinary_provider.source_id,
		ordinary_provider.source_part_id)
	var captured_identities: Dictionary = complete_census.get("sourceIdentities", {})
	_check("fixture_provider_census_complete_before_candidate",
		complete_census.get("status") == "complete" and census_sections.has(SECTION)
		and expected_rows.size() == 2 and terrain_identity_key in expected_rows
		and ordinary_identity_key in expected_rows
		and captured_identities.get(terrain_identity_key, {}).get("sourceId", "") == terrain_provider.source_id
		and captured_identities.get(terrain_identity_key, {}).get("sourcePartId", "") == terrain_provider.source_part_id
		and captured_identities.get(ordinary_identity_key, {}).get("sourceId", "") == ordinary_provider.source_id
		and captured_identities.get(ordinary_identity_key, {}).get("sourcePartId", "") == ordinary_provider.source_part_id,
		{"status":complete_census.get("status"), "sectionKeys":census_sections,
			"expectedContributors":expected_rows,
			"sourceIdentities":captured_identities})
	if complete_census.get("status") != "complete" or not census_sections.has(SECTION) \
			or expected_rows.size() != 2:
		_finish_lifecycle(lifecycle_report_path)
		return
	var slot := InstallSession.slot_id(WORLD, SECTION)
	var first_admission: Dictionary = await _admit_compiled_candidate(coordinator, SECTION, 1)
	var first_outcome: Dictionary = await _drive_lifecycle_candidate(1, "installed")
	var first_live: Dictionary = backend.call("installed_snapshot", slot)
	var first_receipt: Dictionary = coordinator._production_candidate_receipts.get(SECTION, {})
	_check("generation_one_installed_and_both_providers_acknowledged",
		first_admission.get("status") == "queued" and first_outcome.get("status") == "installed"
		and int(first_admission.get("providerCount", -1)) == 2
		and int(first_admission.get("sourceCount", -1)) == 2
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
	var second_admission: Dictionary = await _admit_compiled_candidate(coordinator, SECTION, 2)
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
	var third_admission: Dictionary = await _admit_compiled_candidate(coordinator, SECTION, 3)
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
	var fourth_admission: Dictionary = await _admit_compiled_candidate(coordinator, SECTION, 4)
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
	var empty_admission: Dictionary = await _admit_compiled_candidate(empty_coordinator, SECTION, 10)
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
	var pending_admission: Dictionary = await _admit_compiled_candidate(empty_coordinator, SECTION, 11)
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
	var teardown_admission: Dictionary = await _admit_compiled_candidate(empty_coordinator,
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
	var owner_retry_admission: Dictionary = await _admit_compiled_candidate(empty_coordinator,
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
	await _exercise_runtime_authority_replacement(world)
	_finish_lifecycle(lifecycle_report_path)


## Synthetic producers, real native renderer and frame callbacks. Only runtime
## authority changes; geometry, source revisions and coverage remain identical.
func _exercise_runtime_authority_replacement(world: WorldRoot) -> void:
	var owner_chunk := Node3D.new()
	# PacketOwner and InstallSession require the exact canonical cell name,
	# tree membership and registry/backend identity throughout installation.
	owner_chunk.name = "Chunk_0_0"
	owner_chunk.set_meta("static_ecology_render_resource_bindings", {})
	world.add_child(owner_chunk)
	world.chunks[Vector2i.ZERO] = owner_chunk
	world.chunk_owner = owner_chunk
	var attached: Dictionary = PacketOwner.attach_to_chunk(owner_chunk)
	var native: Node3D = attached.get("backend") as Node3D
	world.backend = native
	var resolved := PacketOwner.resolve_existing_static_section_backend(Vector2i.ZERO)
	var owner_ready: bool = attached.get("status") == "ready" \
		and resolved.get("status") == "ready" \
		and current_scene == world and owner_chunk.is_inside_tree() \
		and world.chunks.get(Vector2i.ZERO) == owner_chunk \
		and resolved.get("chunk") == owner_chunk and resolved.get("backend") == native
	_check("runtime_authority_native_owner_attached", owner_ready,
		{"attachmentStatus":attached.get("status"), "resolutionStatus":resolved.get("status"),
			"resolutionReason":resolved.get("reason", ""), "ownerName":str(owner_chunk.name)})
	if not owner_ready:
		return
	for empty in [false, true]:
		var owner := Coordinator.new()
		owner.configure(WORLD)
		world.world_static_section_coordinator = owner
		var provider = ExplicitEmptyProvider.new() if empty else _make_lifecycle_provider(
			"runtime-owner", "runtime-source", "runtime-part", "fixed-source-r1")
		provider.world_id = WORLD
		owner.configure_source_roster([provider.provider_id])
		owner.register_source_provider(provider.provider_id, provider, "capture_static_section_sources")
		var prefix := "empty_runtime_owner_" if empty else "runtime_owner_"
		var base_generation := 200 if empty else 100
		var slot := InstallSession.slot_id(WORLD, SECTION)
		var original_sources: Dictionary = provider.capture_static_section_sources(WORLD,
			[SECTION]).get("sourceRevisions", {})
		var admitted: Dictionary = await _admit_compiled_candidate(owner, SECTION, base_generation)
		var initial: Dictionary = await _advance_until_lifecycle_terminal(base_generation, owner)
		_check(prefix + "initial_installed", admitted.get("status") == "queued"
			and initial.get("status") == "installed", {"admission":admitted, "result":initial})
		if initial.get("status") != "installed": return
		var prior: Dictionary = native.call("installed_snapshot", slot)
		for stage in ["upload", "awaiting_frame"]:
			var generation := base_generation + (1 if stage == "upload" else 2)
			var admission: Dictionary = await _admit_compiled_candidate(owner, SECTION, generation)
			# An authoritative empty candidate has no buffers to upload. Exercise
			# its ready-to-commit boundary instead of inventing an upload payload.
			var target_stage: String = "commit" if empty and stage == "upload" else stage
			var staged: Dictionary = await _drive_lifecycle_candidate(generation, target_stage, owner)
			var old_acks: int = provider.install_acknowledgement_count
			provider.owner_generation += 1
			var changed: Dictionary = owner.advance_complete_section_candidate(SECTION, 8)
			var retained: Dictionary = native.call("installed_snapshot", slot)
			_check(prefix + stage + "_rejects_same_content_owner_replacement",
				admission.get("status") == "queued" and staged.get("status") == "pending"
				and bool(changed.get("requiresReassembly", false))
				and int(retained.get("generation", 0)) == base_generation
				and retained.get("rootInstanceId") == prior.get("rootInstanceId")
				and provider.install_acknowledgement_count == old_acks
				and original_sources == provider.capture_static_section_sources(WORLD,
					[SECTION]).get("sourceRevisions", {}),
				{"admission":admission, "targetStage":target_stage, "staged":staged,
					"changed":changed, "retained":retained})
			await process_frame
		provider.acknowledgement_pending = true
		var pending_generation := base_generation + 3
		var pending_admission: Dictionary = await _admit_compiled_candidate(owner, SECTION, pending_generation)
		var pending_install: Dictionary = await _advance_until_lifecycle_terminal(pending_generation, owner)
		var ack_count: int = provider.install_acknowledgement_count
		var installed_before_retry: Dictionary = native.call("installed_snapshot", slot)
		provider.census_pending = true
		# Advance real frames until the retained retry becomes eligible.
		var capture_pending: Array = []
		for frame in range(120):
			capture_pending = owner._advance_pending_source_acknowledgements(1)
			if not capture_pending.is_empty(): break
			await process_frame
		_check(prefix + "pending_census_preserves_ack_and_slot",
			pending_admission.get("status") == "queued" and pending_install.get("status") == "installed"
			and capture_pending.size() == 1 and capture_pending[0].get("status") == "pending"
			and owner._pending_source_acknowledgements.has(SECTION)
			and provider.install_acknowledgement_count == ack_count
			and native.call("installed_snapshot", slot).get("rootInstanceId") == installed_before_retry.get("rootInstanceId"),
			{"install":pending_install, "retry":capture_pending})
		provider.census_pending = false
		provider.acknowledgement_pending = false
		provider.owner_generation += 1
		# Register real visible demand so stale acknowledgement schedules its replacement.
		owner.request_visible_section_demand(SECTION, 1, 0.0)
		var stale_ack: Array = []
		for frame in range(120):
			stale_ack = owner._advance_pending_source_acknowledgements(1)
			if not stale_ack.is_empty(): break
			await process_frame
		_check(prefix + "pending_ack_rejects_owner_replacement_and_queues_reassembly",
			stale_ack.size() == 1 and stale_ack[0].get("status") == "stale_dropped"
			and not owner._pending_source_acknowledgements.has(SECTION)
			and owner._replay_reassembly_required_by_section.has(SECTION)
			and bool(owner._visible_section_demands.get(SECTION, {}).get("queued", false))
			and provider.install_acknowledgement_count == ack_count
			and native.call("installed_snapshot", slot).get("rootInstanceId") == installed_before_retry.get("rootInstanceId"),
			{"retry":stale_ack, "installed":native.call("installed_snapshot", slot)})
		var replacement: Dictionary = await _admit_compiled_candidate(owner, SECTION, base_generation + 4)
		var settled: Dictionary = await _advance_until_lifecycle_terminal(base_generation + 4, owner)
		_check(prefix + "current_replacement_installs_and_acknowledges_once",
			replacement.get("status") == "queued" and settled.get("status") == "installed"
			and provider.install_acknowledgement_count == ack_count + 1
			and not owner._pending_source_acknowledgements.has(SECTION)
			and not owner._replay_reassembly_required_by_section.has(SECTION)
			and int(native.call("installed_snapshot", slot).get("generation", 0)) == base_generation + 4,
			{"admission":replacement, "settled":settled})
		await owner.drain_pending_frame_presentations()


func _make_lifecycle_provider(provider_id: String, source_id: String, source_part_id: String,
		source_revision: String) -> CensusProvider:
	var provider := CensusProvider.new()
	provider.world_id = WORLD
	provider.provider_id = provider_id
	provider.source_id = source_id
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
		if target_state != "installed" and session is RefCounted \
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

## Admission now queues a native worker. Wait for its current identity receipt
## before the fixture inspects candidate data or controls upload/frame stages.
func _admit_compiled_candidate(owner_coordinator, section_key: Vector3i,
		generation: int) -> Dictionary:
	_write_native_candidate_progress(owner_coordinator, "candidate_assembly_started",
		section_key, generation, 0, {})
	var admission: Dictionary = owner_coordinator.call(
		"assemble_and_submit_complete_section_candidate", section_key, generation)
	_write_native_candidate_progress(owner_coordinator,
		"candidate_assembly_returned", section_key, generation, 0, admission)
	if admission.get("status") != "queued": return admission
	for wait_frame in range(1200):
		var outcomes: Array = owner_coordinator.call("_advance_section_compiles", 1)
		for outcome: Dictionary in outcomes:
			if outcome.get("sectionKey") == section_key and int(outcome.get("generation", -1)) == generation:
				if outcome.get("status") != "queued": return outcome
		var jobs: Dictionary = owner_coordinator.get("_production_candidate_jobs")
		var candidate: Dictionary = jobs.get(section_key, {}).get("candidate", {})
		if int(candidate.get("generation", -1)) == generation:
			var receipt: Dictionary = candidate.get("nativeCompileReceipt", {})
			if receipt.get("status") != "compiled":
				return {"status":"failed", "reason":"fixture_native_compile_receipt_missing"}
			var accepted := admission.duplicate(false)
			accepted["acceptedStage"] = "native_compile_accepted"
			accepted["compileWaitFrames"] = wait_frame
			accepted["nativeCompileReceipt"] = receipt
			accepted["providerCount"] = candidate.get("providerCoverage", []).size()
			accepted["sourceCount"] = candidate.get("candidate", {}).get("snapshot", {}).get("manifest", []).size()
			_write_native_candidate_progress(owner_coordinator,
				"native_compile_accepted", section_key, generation,
				wait_frame, accepted)
			return accepted
		if wait_frame % SOURCE_COMPILE_RECENSUS_INTERVAL_FRAMES == 0:
			_write_native_candidate_progress(owner_coordinator,
				"native_compile_waiting", section_key, generation,
				wait_frame, {"outcomes":outcomes})
		await process_frame
	_write_native_candidate_progress(owner_coordinator, "native_compile_wait_exhausted",
		section_key, generation, 1200, {"status":"failed"})
	return {"status":"failed", "reason":"fixture_native_compile_wait_exhausted",
		"stage":"native_compile", "sectionKey":section_key, "generation":generation}


func _write_native_candidate_progress(owner_coordinator, phase: String,
		section_key: Vector3i, generation: int, wait_frame: int,
		outcome: Dictionary) -> void:
	if progress_path.is_empty() or not is_same(owner_coordinator, coordinator):
		return
	var compile_jobs_value: Variant = owner_coordinator.get("_section_compile_jobs")
	var compile_jobs: Dictionary = compile_jobs_value \
		if compile_jobs_value is Dictionary else {}
	var job: Dictionary = compile_jobs.get(section_key, {})
	var candidate_jobs_value: Variant = owner_coordinator.get("_production_candidate_jobs")
	var candidate_jobs: Dictionary = candidate_jobs_value \
		if candidate_jobs_value is Dictionary else {}
	var candidate_job: Dictionary = candidate_jobs.get(section_key, {})
	var candidate: Dictionary = candidate_job.get("candidate", {})
	var dispatcher: Variant = owner_coordinator.get("_section_compile_dispatcher")
	var dispatch_metrics: Dictionary = dispatcher.call("metrics") \
		if is_instance_valid(dispatcher) and dispatcher.has_method("metrics") else {}
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file == null:
		return
	var payload := {"schema":"whole-section-native-candidate-admission-progress/v1",
		"phase":phase, "sectionKey":section_key, "generation":generation,
		"waitFrame":wait_frame, "outcome":outcome,
		"compileJobCount":compile_jobs.size(),
		"compileTicket":int(job.get("ticket", 0)),
		"candidateStage":String(candidate_job.get("stage", "")),
		"candidateGeneration":int(candidate.get("generation", 0)),
		"nativeReceiptStatus":String(candidate.get("nativeCompileReceipt", {}).get(
			"status", "")), "nativeDispatcherMetrics":dispatch_metrics,
		"elapsedMsec":Time.get_ticks_msec()}
	file.store_string(JSON.stringify(payload, "\t"))
	file.flush()
	file.close()

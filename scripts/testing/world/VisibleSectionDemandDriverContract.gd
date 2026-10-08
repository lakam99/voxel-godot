extends SceneTree
## Synthetic coordinator demand-scheduler contract. It verifies native-section
## demand admission, provider-complete gating, bounded retries and fair priority.
## Its POV replay case installs through the real native packet backend/session,
## but uses synthetic provider inputs and does not prove Main-world visuals.

const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const MainRuntime := preload("res://scripts/MainRuntimeTools.gd")
const SectionGrid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const InstallSession := preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const TerrainRuntime := preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
const TerrainVolume := preload("res://scripts/TerrainVolumeService.gd")
const WorldGeneration := preload("res://scripts/WorldGenerationSystem.gd")
const SourceRoster := preload("res://scripts/world/StaticSectionSourceRoster.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const PacketOwner := preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const ACK_SETTLEMENT_CHECK_NAME := \
	"failed_and_malformed_provider_acknowledgements_remain_unsettled_until_retry_succeeds"


class FixtureCoordinator extends "res://scripts/world/WorldStaticSectionCoordinator.gd":
	func _receipt_is_live(candidate: Dictionary, receipt: Dictionary) -> bool:
		return receipt.get("status") == "installed" \
			and receipt.get("worldId") == candidate.get("worldId") \
			and receipt.get("sectionKey") == candidate.get("sectionKey") \
			and int(receipt.get("generation", 0)) == int(candidate.get("generation", 0)) \
			and receipt.get("contentManifestDigest") == candidate.get("contentManifestDigest") \
			and _section_receipt_source_revision_is_current(candidate, receipt)


class AckRotationCoordinator extends FixtureCoordinator:
	func _installed_section_receipt_is_current_uncached(section_key: Vector3i,
			receipt: Dictionary) -> bool:
		var candidate: Dictionary = _production_candidates_by_section.get(section_key, {})
		return not candidate.is_empty() \
			and is_same(_production_candidate_receipts.get(section_key, {}), receipt) \
			and int(candidate.get("generation", -1)) == int(receipt.get("generation", -2))


class AckRotationRoster extends RefCounted:
	var coordinator: Object
	var calls: Array[Vector3i] = []

	func capture_sections(section_keys: Array) -> Dictionary:
		var section_key: Vector3i = section_keys[0]
		var candidate: Dictionary = coordinator._production_candidates_by_section.get(
			section_key, {})
		return {"status":"complete",
			"censusDigest":String(candidate.get("censusDigest", "")),
			"providerPhaseUsec":{}}

	func acknowledge_section_install(section_key: Vector3i, _provider_coverage: Array,
			_receipt: Dictionary, _census: Dictionary) -> Dictionary:
		calls.append(section_key)
		return {"status":"pending", "reason":"fixture_owner_proof_pending",
			"retryable":true}


class PendingInstallScheduler extends "res://scripts/world/WorldStaticSectionCoordinator.gd":
	var visits: Array[Vector3i] = []

	func advance_complete_section_candidate(section_key: Vector3i,
			_max_upload_units := 1) -> Dictionary:
		visits.append(section_key)
		return {"status":"pending", "sectionKey":section_key}


class RetirementInstallSession extends RefCounted:
	var _owner_cell := Vector2i.ZERO
	var _chunk_id := 101
	var state := "appending"
	var cancel_calls := 0
	var fail_cancel := false

	func cancel() -> Dictionary:
		cancel_calls += 1
		if fail_cancel:
			return {"status":"rollback_failed", "reason":"synthetic_abort_pending"}
		state = "cancelled"
		return {"status":"cancelled"}


class FakeReceiptBackend extends Node:
	var expected_source_id := ""
	var expected_generation := 0
	var expected_source_revision := ""
	var expected_digest := ""
	var owner_cell := Vector2i.ZERO
	var receipt_check_calls := 0
	var last_source_revision := ""

	func receipt_installed(source_id: String, generation: int,
			source_revision: String, digest: String) -> bool:
		receipt_check_calls += 1
		last_source_revision = source_revision
		return source_id == expected_source_id and generation == expected_generation \
			and source_revision == expected_source_revision and digest == expected_digest

	func installed_snapshot(_source_id: String) -> Dictionary:
		return {"status":"ready", "ownerCell":owner_cell,
			"generation":expected_generation, "sourceRevision":expected_source_revision,
			"packetDigest":expected_digest}


class TranslucentReceiptCoordinator extends "res://scripts/world/WorldStaticSectionCoordinator.gd":
	var fixture_chunk: Node3D
	var fixture_backend: Node
	var fixture_owner_cell := Vector2i.ZERO

	func _resolve_existing_static_section_backend(owner_cell: Vector2i) -> Dictionary:
		if owner_cell != fixture_owner_cell or not is_instance_valid(fixture_chunk) \
				or not is_instance_valid(fixture_backend):
			return {"status":"pending", "reason":"fixture_section_owner_missing"}
		return {"status":"ready", "chunk":fixture_chunk, "backend":fixture_backend}


class NativeSectionOwnerScene extends Node3D:
	var static_section_render_root: Node3D
	var static_section_render_owners: Dictionary = {}

	func _init() -> void:
		static_section_render_root = Node3D.new()
		static_section_render_root.name = "StaticSectionRenderRoot"
		add_child(static_section_render_root)

	func get_static_section_render_owner(owner_cell: Vector2i,
			create_if_missing := true) -> Dictionary:
		var owner: Node3D = static_section_render_owners.get(owner_cell) as Node3D
		if is_instance_valid(owner):
			return {"status":"ready", "owner":owner,
				"backend":owner.get_node_or_null("ChunkRenderPacketBackend")}
		if not create_if_missing:
			return {"status":"pending", "reason":"fixture_section_owner_missing"}
		owner = Node3D.new()
		owner.name = "Chunk_%d_%d" % [owner_cell.x, owner_cell.y]
		owner.position = Vector3(owner_cell.x * SectionGrid.STREAM_CHUNK_SIZE_METERS,
			0.0, owner_cell.y * SectionGrid.STREAM_CHUNK_SIZE_METERS)
		static_section_render_root.add_child(owner)
		var attached: Dictionary = PacketOwner.attach_to_chunk(owner)
		if attached.get("status") != "ready":
			owner.queue_free()
			return attached
		static_section_render_owners[owner_cell] = owner
		return {"status":"ready", "owner":owner, "backend":attached.backend}


class PovBoundSectionProvider extends RefCounted:
	var provider_id := "fixture-fluid"
	var source_id := "fixture-fluid:water"
	var source_part_id := "fixture-fluid:water-surface"
	var world_id := ""
	var coordinator: Object
	var mesh := ArrayMesh.new()
	var material := StandardMaterial3D.new()
	var mesh_digest := ""
	var mesh_resource_key := "fixture-water-mesh"
	var material_key := "fixture-water-material"

	func configure(next_world_id: String, next_coordinator: Object) -> void:
		world_id = next_world_id
		coordinator = next_coordinator
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
			Vector3(0, 0, 0), Vector3(1, 0, 0),
			Vector3(1, 1, 0), Vector3(0, 1, 0)])
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = Color(0.2, 0.5, 0.8, 0.45)
		mesh_digest = String(MeshFingerprint.inspect(mesh).get("contentDigest", ""))

	func capture_static_section_sources(capture_world_id: String,
			section_keys: Array) -> Dictionary:
		if capture_world_id != world_id or coordinator == null:
			return {"status":"pending", "retryable":true,
				"reason":"fixture_world_or_coordinator_unavailable"}
		var sections: Dictionary = {}
		var revisions: Dictionary = {}
		var identity_key := SourceRoster._source_part_identity_key(source_id, source_part_id)
		var source_identity := {"sourceId":source_id, "sourcePartId":source_part_id}
		source_identity.make_read_only()
		var identities := {identity_key:source_identity}
		identities.make_read_only()
		for section_value: Variant in section_keys:
			if not section_value is Vector3i:
				return {"status":"failed", "reason":"fixture_section_key_invalid"}
			var section_key: Vector3i = section_value
			var pov: Dictionary = coordinator.current_translucent_pov_snapshot(section_key)
			if pov.get("status") != "ready":
				return {"status":"pending", "retryable":true,
					"reason":"fixture_current_pov_unavailable"}
			var revision := "fluid-source-pov-%d" % int(pov.revision)
			revisions[identity_key] = revision
			var parts: Array[Dictionary] = [source_identity]
			parts.make_read_only()
			var coverage := {"status":"complete",
				"coverageRevision":"fluid-coverage-pov-%d" % int(pov.revision),
				"sourceParts":parts}
			coverage.make_read_only()
			sections[section_key] = coverage
		revisions.make_read_only()
		sections.make_read_only()
		return {"status":"complete", "worldId":world_id,
			"authorityRevision":"fluid-authority-pov-%d" % int(
				coordinator.current_translucent_pov_snapshot(section_keys[0]).revision),
			"sourceRevisions":revisions, "sourceIdentities":identities, "sections":sections}

	func capture_static_section_contribution(census: Dictionary,
			section_key: Vector3i) -> Dictionary:
		var pov: Dictionary = coordinator.current_translucent_pov_snapshot(section_key)
		if pov.get("status") != "ready":
			return {"status":"pending", "retryable":true,
				"reason":"fixture_current_pov_unavailable"}
		var pov_revision := int(pov.revision)
		var revision := "fluid-source-pov-%d" % pov_revision
		var face_group := {"groupId":"fixture-fluid-face-0", "firstIndex":0,
			"indexCount":6, "centroid":Vector3(0.5, 0.5, 0.0)}
		face_group.make_read_only()
		var groups: Array[Dictionary] = [face_group]
		groups.make_read_only()
		var surface := {"surfaceIndex":0, "faceGroups":groups}
		surface.make_read_only()
		var surfaces: Array[Dictionary] = [surface]
		surfaces.make_read_only()
		var descriptor := {"schema":"section-translucent-face-groups/v1",
			"sectionKey":section_key, "sectionGeneration":int(census.get(
				"candidateGeneration", 0)), "povRevision":pov_revision,
			"cameraPosition":pov.cameraPosition, "meshContentDigest":mesh_digest,
			"surfaces":surfaces}
		descriptor.make_read_only()
		var pipeline := "fixture-fluid-section-v1"
		var mesh_key := "%s|pipeline=%s|layer=translucent|sort=camera_depth" % [
			mesh_resource_key, pipeline]
		var compatibility := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
			"materialKey":material_key, "renderTier":"structural",
			"meshResourceKey":mesh_resource_key, "meshContentDigest":mesh_digest,
			"meshKey":mesh_key, "pipelineRevision":pipeline,
			"renderLayer":"translucent", "translucentSortPolicy":"camera_depth",
			"translucentSortDescriptor":descriptor,
			"meshLocalBounds":AABB(Vector3.ZERO, Vector3.ONE),
			"castShadows":false, "visibilityRangeEnd":100000.0, "fadeMargin":0.0}
		var batch_key := SnapshotBuilder.batch_compatibility_key(compatibility)
		compatibility["batchKey"] = batch_key
		compatibility["compatibilityKey"] = batch_key
		compatibility.make_read_only()
		var compatibility_by_key := {batch_key:compatibility}
		compatibility_by_key.make_read_only()
		var buffer: Array[float] = []
		for component: float in Attributes.encode(Transform3D.IDENTITY,
				Color.WHITE, Color.WHITE):
			buffer.append(component)
		buffer.make_read_only()
		var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
			"sourceId":source_id, "sourcePartId":source_part_id,
			"sourceRevision":revision,
			"ownerCell":SectionGrid.logical_owner_cell_for_world_position(Vector3(0.5, 0.5, 0.0)),
			"sourceToWorld":Transform3D.IDENTITY,
			"meshLocalBounds":AABB(Vector3.ZERO, Vector3.ONE),
			"batchKey":batch_key, "segmentId":source_part_id + ":segment",
			"buffer":buffer, "instanceCount":1}
		input.make_read_only()
		var inputs: Array[Dictionary] = [input]
		inputs.make_read_only()
		var authority_revisions := {SourceRoster._source_part_identity_key(source_id, source_part_id):revision}
		authority_revisions.make_read_only()
		var material_bindings := {material_key:material}
		material_bindings.make_read_only()
		var mesh_bindings := {mesh_resource_key:mesh}
		mesh_bindings.make_read_only()
		var contribution := {"providerId":provider_id, "sectionKey":section_key,
			"coverageRevision":String(census.providerCoverageRevisions[
				provider_id][section_key]),
			"authorityRevision":String(census.providerSnapshotRevisions[provider_id]),
			"authoritySourceRevisions":authority_revisions,
			"inputs":inputs, "compatibilityByKey":compatibility_by_key,
			"materialBindings":material_bindings, "meshBindings":mesh_bindings,
			"resourceBindings":{}}
		contribution.resourceBindings.make_read_only()
		contribution.make_read_only()
		return {"status":"ready", "contribution":contribution}


class FakeTerrainRuntime extends Node3D:
	signal visible_mesh_block_revision_changed(section_key: Vector3i, revision: int)
	var published_mesh_blocks: Dictionary = {}

	func enter_section(section_key: Vector3i, revision: int) -> void:
		published_mesh_blocks[section_key] = true
		visible_mesh_block_revision_changed.emit(section_key, revision)

	func exit_section(section_key: Vector3i, revision: int) -> void:
		published_mesh_blocks.erase(section_key)
		visible_mesh_block_revision_changed.emit(section_key, revision)


class MutableCensusProvider extends PovBoundSectionProvider:
	var mutation := 0
	var census_calls := 0

	func capture_static_section_sources(capture_world_id: String, section_keys: Array) -> Dictionary:
		census_calls += 1
		var captured := super.capture_static_section_sources(capture_world_id, section_keys)
		if mutation == 0 or captured.get("status") != "complete": return captured
		var changed := captured.duplicate(false)
		var revisions: Dictionary = captured.sourceRevisions.duplicate()
		for key: String in revisions: revisions[key] = String(revisions[key]) + ":mutation:" + str(mutation)
		revisions.make_read_only()
		changed["sourceRevisions"] = revisions
		changed["authorityRevision"] = String(captured.authorityRevision) + ":mutation:" + str(mutation)
		return changed


class FakeInstalledSession extends RefCounted:
	var state := "installing"
	var receipt: Dictionary = {}
	var cancelled := false
	var advance_calls := 0
	var last_pov_revision := -1
	var return_pending := false
	var fail_reason := ""

	func configure(candidate: Dictionary, pov_revision := -1) -> void:
		var source_revision := "%s:%d" % [String(candidate.get("worldId", "")),
			int(candidate.get("generation", 0))]
		if pov_revision > 0:
			source_revision += ":pov:%d" % pov_revision
		receipt = {"status":"installed",
			"worldId":String(candidate.get("worldId", "")),
			"sectionKey":candidate.get("sectionKey", Vector3i.ZERO),
			"generation":int(candidate.get("generation", 0)),
			"censusDigest":String(candidate.get("censusDigest", "")),
			"contentManifestDigest":String(candidate.get("contentManifestDigest", "")),
			"sourceRevision":source_revision,
			"backendInstanceId":101, "chunkInstanceId":202, "ownerCell":Vector2i(2, 0)}
		if pov_revision > 0:
			receipt["translucentPovRevision"] = pov_revision
		receipt.make_read_only()

	func advance(_max_upload_units: int, current_translucent_pov_revision := -1) -> Dictionary:
		advance_calls += 1
		last_pov_revision = current_translucent_pov_revision
		if not fail_reason.is_empty():
			state = "failed"
			return {"status":"failed", "reason":fail_reason}
		if return_pending:
			state = "installing"
			return {"status":"pending", "stage":"fixture_install"}
		state = "installed"
		return {"status":"installed", "receipt":receipt}

	func cancel() -> Dictionary:
		cancelled = true
		state = "cancelled"
		return {"status":"cancelled"}

class EmptySectionProvider extends RefCounted:
	var provider_id := ""
	var configured_world_id := ""
	var authority_revision := 1
	var pending_capture_calls := 0
	var pending_continuation := false
	var capture_calls := 0

	func configure(next_provider_id: String, world_id: String) -> void:
		provider_id = next_provider_id
		configured_world_id = world_id

	func capture_static_section_sources(world_id: String, section_keys: Array) -> Dictionary:
		capture_calls += 1
		if pending_capture_calls > 0:
			pending_capture_calls -= 1
			var pending := {"status":"pending",
				"reason":"fixture_incremental_capture_pending", "retryable":true}
			if pending_continuation:
				var hint := {"schema":"static-section-provider-continuation/v1",
					"stage":"fixture_capture", "cursor":capture_calls}
				hint.make_read_only()
				pending["continuationHint"] = hint
			return pending
		if world_id != configured_world_id:
			return {"status":"pending", "reason":"fixture_world_mismatch", "retryable":true}
		var sections: Dictionary = {}
		for section_key_value: Variant in section_keys:
			var coverage := {"status":"empty",
				"coverageRevision":"%s:%s" % [provider_id, str(section_key_value)],
				"sourcePartIds":[]}
			coverage["sourcePartIds"].make_read_only()
			coverage.make_read_only()
			sections[section_key_value] = coverage
		sections.make_read_only()
		var revisions: Dictionary = {}
		revisions.make_read_only()
		return {"status":"complete", "worldId":world_id,
			"authorityRevision":provider_id + ":authority:" + str(authority_revision),
			"sourceRevisions":revisions, "sections":sections}

	func capture_static_section_contribution(census: Dictionary,
			section_key: Vector3i) -> Dictionary:
		var coverage: Dictionary = census.providerCoverageRevisions.get(provider_id, {})
		var authority: Dictionary = census.providerSnapshotRevisions
		if not coverage.has(section_key) or not authority.has(provider_id):
			return {"status":"pending", "reason":"fixture_provider_coverage_missing",
				"retryable":true}
		var revisions: Dictionary = {}
		revisions.make_read_only()
		var inputs: Array[Dictionary] = []
		inputs.make_read_only()
		var compatibility: Dictionary = {}
		compatibility.make_read_only()
		var contribution := {"providerId":provider_id, "sectionKey":section_key,
			"coverageRevision":String(coverage[section_key]),
			"authorityRevision":String(authority[provider_id]),
			"authoritySourceRevisions":revisions,
			"inputs":inputs, "compatibilityByKey":compatibility}
		contribution.make_read_only()
		return {"status":"ready", "contribution":contribution}


class PendingInstallAckProvider extends EmptySectionProvider:
	var acknowledge_calls := 0
	var pending_acknowledgements := 1
	var pending_generations: Array[int] = []
	var acknowledged_generations: Array[int] = []

	func acknowledge_section_install(_section_key: Vector3i,
			_coverage_revision: String, receipt: Dictionary) -> Dictionary:
		acknowledge_calls += 1
		if not receipt.is_read_only() or receipt.get("status") != "installed":
			return {"status":"failed", "reason":"fixture_receipt_invalid"}
		var generation := int(receipt.get("generation", 0))
		if generation in pending_generations:
			return {"status":"pending", "retryable":true,
				"reason":"fixture_generation_ack_pending"}
		if pending_acknowledgements > 0:
			pending_acknowledgements -= 1
			return {"status":"pending", "retryable":true,
				"reason":"fixture_ack_dependency_pending"}
		acknowledged_generations.append(generation)
		return {"status":"acknowledged", "sectionKey":_section_key}


class SequencedInstallAckProvider extends EmptySectionProvider:
	var acknowledge_calls := 0
	var responses: Array = []
	var acknowledged_generations: Array[int] = []

	func acknowledge_section_install(_section_key: Vector3i,
			_coverage_revision: String, receipt: Dictionary) -> Variant:
		acknowledge_calls += 1
		if not receipt.is_read_only() or receipt.get("status") != "installed":
			return {"status":"failed", "reason":"fixture_receipt_invalid"}
		var response_index := acknowledge_calls - 1
		if response_index >= responses.size():
			return {"status":"acknowledged"}
		var response: Variant = responses[response_index]
		if response is Dictionary and response.get("status") == "acknowledged":
			acknowledged_generations.append(int(receipt.get("generation", 0)))
		return response


class StaleSnapshotProvider extends RefCounted:
	func capture_static_section_sources(_world_id: String, _sections: Array) -> Dictionary:
		return {"status":"pending", "retryable":true,
			"reason":"ecology_chunk_source_snapshot_revision_stale",
			"sourceId":"fixture:tree:oak-3", "sourcePartId":"fixture:tree:oak-3:foliage",
			"cell":Vector3i(17, 8, -4), "blockType":"canopyMesh",
			"chunk":Vector2i(2, -1), "snapshotRemovedPropsRevision":3,
			"currentRemovedPropsRevision":3, "snapshotSourceRevision":"terrain-5",
			"currentSourceRevision":"terrain-6",
			"snapshotValidation":{"status":"ready", "reason":""}}


class FakeFluidRevisionAuthority extends "res://scripts/TerrainVolumeService.gd":
	func _init() -> void:
		revision = 1
		fluid_revision = 1

	func exact_fluid_section_revision(_section_key: Vector3i) -> int:
		return 0


class FakeFluidWorldGeneration extends RefCounted:
	var terrain_volume_service: FakeFluidRevisionAuthority
	var has_fluid := false
	var stale_payload := false
	var probe_sequence := 0
	var probe_section_key := Vector3i.ZERO

	func begin_exact_fluid_payload_for_meshing_chunk(_x: int, _z: int, _size: int,
			_min_y: int, _max_y: int, _step: int) -> Dictionary:
		probe_sequence += 1
		probe_section_key = Vector3i(floori(float(_x) / 16.0),
			floori(float(_min_y) / 16.0), floori(float(_z) / 16.0))
		return terrain_volume_service.begin_exact_fluid_payload_for_meshing_chunk(
			_x, _z, _size, _min_y, _max_y, _step)

	func advance_exact_fluid_payload_state(state: Dictionary, _budget_ms: float,
			_max_cells: int) -> Dictionary:
		var min_section: Vector3i = terrain_volume_service.section_key_for_cell(state.minCell)
		var max_section: Vector3i = terrain_volume_service.section_key_for_cell(state.maxCell)
		var section_keys: Array = []
		for x in range(min_section.x, max_section.x + 1):
			for y in range(min_section.y, max_section.y + 1):
				for z in range(min_section.z, max_section.z + 1):
					section_keys.append(Vector3i(x, y, z))
		state["sectionKeys"] = section_keys
		state["hasFluid"] = has_fluid
		state["volumeRevision"] = int(terrain_volume_service.revision) - int(stale_payload)
		var payload := terrain_volume_service.finalized_exact_fluid_payload_from_state(state)
		return {"complete":true, "state":state, "payload":payload}


class FakeFluidSiteGate extends RefCounted:
	func current() -> bool:
		return true


class FakeFluidAdmission extends RefCounted:
	var world_seed := "fluid-wakeup-seed"


class FakeFluidStructureSystem extends RefCounted:
	var citadel_terrain_admission := FakeFluidAdmission.new()


class FakeFluidRuntimeMain extends Node:
	var seed_text := "fluid-wakeup-seed"
	var seed_hash := 71
	var structure_system := FakeFluidStructureSystem.new()
	var world_generation_system: FakeFluidWorldGeneration
	var world_static_section_coordinator: FixtureCoordinator


var checks: Array[Dictionary] = []
var ack_settlement_only := false


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	ack_settlement_only = OS.get_environment(
		"VOXEL_VISIBLE_SECTION_DEMAND_ACK_SETTLEMENT_ONLY") == "1"
	var ack_rotation_input: Array[Vector3i] = [
		Vector3i(2, 0, 0), Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	var ack_rotation_first := Coordinator._ordered_pending_source_acknowledgement_keys(
		ack_rotation_input, Vector3i.ZERO, false)
	var ack_rotation_second := Coordinator._ordered_pending_source_acknowledgement_keys(
		ack_rotation_input, Vector3i.ZERO, true)
	var ack_rotation_third := Coordinator._ordered_pending_source_acknowledgement_keys(
		ack_rotation_input, Vector3i(2, 0, 0), true)
	check("pending_source_ack_sections_rotate_after_each_serviced_section",
		ack_rotation_first == [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(2, 0, 0)]
		and ack_rotation_second == [Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i.ZERO]
		and ack_rotation_third == [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(2, 0, 0)],
		{"first":ack_rotation_first, "afterZero":ack_rotation_second,
			"afterMax":ack_rotation_third})
	var ack_fair := AckRotationCoordinator.new()
	ack_fair.configure("seed:ack-rotation-fairness-contract:1")
	var ack_fair_roster := AckRotationRoster.new()
	ack_fair_roster.coordinator = ack_fair
	ack_fair._source_roster = ack_fair_roster
	var ack_fair_keys: Array[Vector3i] = [
		Vector3i(21, 0, 0), Vector3i(19, 0, 0), Vector3i(20, 0, 0)]
	for index in range(ack_fair_keys.size()):
		var section_key: Vector3i = ack_fair_keys[index]
		var candidate := {"worldId":ack_fair.world_identity(), "sectionKey":section_key,
			"generation":index + 1, "censusDigest":"census-%d" % index,
			"contentManifestDigest":"manifest-%d" % index}
		var receipt := {"status":"installed", "worldId":ack_fair.world_identity(),
			"sectionKey":section_key, "generation":index + 1,
			"censusDigest":candidate.censusDigest,
			"contentManifestDigest":candidate.contentManifestDigest}
		receipt.make_read_only()
		ack_fair._production_candidates_by_section[section_key] = candidate
		ack_fair._production_candidate_receipts[section_key] = receipt
		ack_fair._pending_source_acknowledgements[section_key] = {
			"candidate":candidate, "receipt":receipt, "providerCoverage":[],
			"attempts":0, "nextAttemptFrame":0}
	for _turn in range(ack_fair_keys.size()):
		ack_fair.advance_queued_complete_section_candidates(1, 1)
		for section_key: Vector3i in ack_fair._pending_source_acknowledgements:
			var pending: Dictionary = ack_fair._pending_source_acknowledgements[section_key]
			pending["nextAttemptFrame"] = 0
			ack_fair._pending_source_acknowledgements[section_key] = pending
	check("pending_source_ack_scheduler_services_sections_round_robin",
		ack_fair_roster.calls == [Vector3i(19, 0, 0), Vector3i(20, 0, 0),
			Vector3i(21, 0, 0)],
		{"calls":ack_fair_roster.calls,
			"deferrals":ack_fair._last_source_acknowledgement_deferrals})
	ack_fair_roster.coordinator = null
	ack_fair._source_roster = null
	ack_fair = null
	ack_fair_roster = null
	var pending_installs := PendingInstallScheduler.new()
	var install_keys: Array[Vector3i] = [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(2, 0, 0)]
	for install_key: Vector3i in install_keys:
		pending_installs._production_candidate_jobs[install_key] = {"status":"pending"}
	for _frame in range(6):
		pending_installs.advance_queued_complete_section_candidates(1, 1)
	check("pending_install_does_not_starve_other_complete_sections",
		pending_installs.visits == install_keys + install_keys,
		{"visits":pending_installs.visits})
	var world_id := "seed:visible-section-demand-contract:1"
	var pov_coordinator = Coordinator.new()
	var pov_without_camera := pov_coordinator.current_translucent_pov_snapshot(Vector3i.ZERO)
	pov_coordinator.configure(world_id + ":pov")
	pov_coordinator.refresh_visible_section_demand_priorities(Vector3(1.0, 1.0, 1.0), 1)
	var pov_first := pov_coordinator.current_translucent_pov_snapshot(Vector3i.ZERO)
	pov_coordinator.refresh_visible_section_demand_priorities(Vector3(2.0, 2.0, 2.0), 1)
	var pov_same_class := pov_coordinator.current_translucent_pov_snapshot(Vector3i.ZERO)
	pov_coordinator.refresh_visible_section_demand_priorities(
		Vector3(SectionGrid.SECTION_SIZE_METERS + 1.0, 2.0, 2.0), 1)
	var pov_crossed_boundary := pov_coordinator.current_translucent_pov_snapshot(Vector3i.ZERO)
	check("translucent_pov_uses_current_camera_and_stable_section_relative_class",
		pov_without_camera.get("status") == "pending"
		and pov_first.get("status") == "ready"
		and pov_first.get("cameraPosition") == Vector3(1.0, 1.0, 1.0)
		and pov_first.get("povClass") == Vector3i.ZERO
		and pov_first.get("revision") == 14
		and pov_same_class.get("revision") == pov_first.get("revision")
		and pov_crossed_boundary.get("povClass") == Vector3i(1, 0, 0)
		and pov_crossed_boundary.get("revision") != pov_first.get("revision"),
		{"withoutCamera":pov_without_camera, "first":pov_first,
			"sameClass":pov_same_class, "crossedBoundary":pov_crossed_boundary})
	var pov_world_b := world_id + ":pov-world-b"
	var pov_reset := pov_coordinator.reset_for_world(pov_world_b)
	var stale_world_b_pov := pov_coordinator.current_translucent_pov_snapshot(Vector3i.ZERO)
	var reset_camera_position: Vector3 = pov_coordinator._translucent_camera_position
	var reset_has_camera_snapshot: bool = pov_coordinator._has_translucent_camera_snapshot
	var pov_required_providers: Array[String] = ["fixture-fluid"]
	pov_coordinator.configure_source_roster(pov_required_providers)
	var reset_provider := PovBoundSectionProvider.new()
	reset_provider.configure(pov_world_b, pov_coordinator)
	var reset_provider_registration := pov_coordinator.register_source_provider(
		"fixture-fluid", reset_provider, "capture_static_section_sources")
	var reset_section := Vector3i.ZERO
	var world_b_without_pov := pov_coordinator.assemble_and_submit_complete_section_candidate(
		reset_section, 1)
	pov_coordinator.refresh_visible_section_demand_priorities(Vector3(48.0, 2.0, -16.0), 1)
	var world_b_with_pov := pov_coordinator.assemble_and_submit_complete_section_candidate(
		reset_section, 2)
	check("world_reset_clears_cached_pov_until_new_world_camera_and_then_admits_translucency",
		pov_reset.get("status") == "ready"
		and pov_reset.get("worldId") == pov_world_b
		and reset_camera_position == Vector3.ZERO
		and not reset_has_camera_snapshot
		and stale_world_b_pov.get("status") == "pending"
		and reset_provider_registration.get("status") == "ready"
		and world_b_without_pov.get("status") == "pending"
		and world_b_without_pov.get("reason") == "static_source_provider_pending"
		and world_b_with_pov.get("status") == "queued",
		{"reset":pov_reset, "worldBPovBeforeRefresh":stale_world_b_pov,
			"resetCameraPosition":reset_camera_position,
			"resetHasSnapshot":reset_has_camera_snapshot,
			"providerRegistration":reset_provider_registration,
			"admissionWithoutPov":world_b_without_pov,
			"admissionWithPov":world_b_with_pov,
			"cachedPosition":pov_coordinator._translucent_camera_position,
			"hasSnapshot":pov_coordinator._has_translucent_camera_snapshot})
	var pov_receipt_coordinator := TranslucentReceiptCoordinator.new()
	var pov_receipt_world := world_id + ":translucent-receipt-pov"
	pov_receipt_coordinator.configure(pov_receipt_world)
	pov_receipt_coordinator.refresh_visible_section_demand_priorities(
		Vector3(1.0, 1.0, 1.0), 1)
	var pov_receipt_key := Vector3i.ZERO
	var translucent_descriptor := {"schema":"section-translucent-face-groups/v1",
		"povRevision":14}
	var translucent_batch := {"renderLayer":"translucent",
		"translucentSortDescriptor":translucent_descriptor}
	var translucent_batches := {"fixture:glass":translucent_batch}
	var translucent_snapshot := {"batches":translucent_batches}
	translucent_batches.make_read_only()
	translucent_snapshot.make_read_only()
	var translucent_candidate := {"worldId":pov_receipt_world,
		"sectionKey":pov_receipt_key, "generation":9,
		"contentManifestDigest":"fixture-translucent-manifest",
		"snapshot":translucent_snapshot}
	var receipt_chunk := Node3D.new()
	root.add_child(receipt_chunk)
	var receipt_backend := FakeReceiptBackend.new()
	receipt_chunk.add_child(receipt_backend)
	var receipt_owner_cell := SectionGrid.chunk_key_for_section(pov_receipt_key)
	pov_receipt_coordinator.fixture_chunk = receipt_chunk
	pov_receipt_coordinator.fixture_backend = receipt_backend
	pov_receipt_coordinator.fixture_owner_cell = receipt_owner_cell
	var source_id := InstallSession.slot_id(pov_receipt_world, pov_receipt_key)
	var source_revision := "%s:9:pov:14" % pov_receipt_world
	receipt_backend.expected_source_id = source_id
	receipt_backend.expected_generation = 9
	receipt_backend.expected_source_revision = source_revision
	receipt_backend.expected_digest = "fixture-translucent-manifest"
	receipt_backend.owner_cell = receipt_owner_cell
	var translucent_receipt := {"status":"installed", "worldId":pov_receipt_world,
		"sectionKey":pov_receipt_key, "generation":9,
		"censusDigest":"fixture-census",
		"contentManifestDigest":"fixture-translucent-manifest",
		"sourceRevision":source_revision,
		"translucentPovRevision":14,
		"backendInstanceId":receipt_backend.get_instance_id(),
		"chunkInstanceId":receipt_chunk.get_instance_id(),
		"ownerCell":receipt_owner_cell}
	translucent_receipt.make_read_only()
	pov_receipt_coordinator._production_candidates_by_section[pov_receipt_key] = translucent_candidate
	pov_receipt_coordinator._production_candidate_receipts[pov_receipt_key] = translucent_receipt
	pov_receipt_coordinator.request_visible_section_demand(pov_receipt_key, 1, 0.0)
	var drained_translucent_demand := pov_receipt_coordinator._pop_visible_section_demand()
	var translucent_demand: Dictionary = pov_receipt_coordinator._visible_section_demands[
		pov_receipt_key]
	translucent_demand["stage"] = "installed"
	translucent_demand["queued"] = false
	pov_receipt_coordinator._visible_section_demands[pov_receipt_key] = translucent_demand
	var current_pov_receipt_live := pov_receipt_coordinator.installed_section_receipt_is_current(
		pov_receipt_key, translucent_receipt)
	var pov_resort_refresh := pov_receipt_coordinator.refresh_visible_section_demand_priorities(
		Vector3(22.6, 2.0, 2.0), 1)
	var crossed_pov_receipt_live := pov_receipt_coordinator.installed_section_receipt_is_current(
		pov_receipt_key, translucent_receipt)
	var queued_translucent_demand: Dictionary = pov_receipt_coordinator._visible_section_demands[
		pov_receipt_key]
	var same_pov_resort_refresh := pov_receipt_coordinator.refresh_visible_section_demand_priorities(
		Vector3(23.0, 2.0, 2.0), 1)
	check("translucent_receipt_source_revision_is_live_only_for_its_current_pov",
		current_pov_receipt_live and not crossed_pov_receipt_live
		and receipt_backend.receipt_check_calls == 2
		and receipt_backend.last_source_revision == source_revision,
		{"sourceRevision":translucent_receipt.get("sourceRevision"),
			"initialPovRevision":14,
			"initialReceiptLive":current_pov_receipt_live,
			"backendCheckCalls":receipt_backend.receipt_check_calls,
			"backendSourceRevision":receipt_backend.last_source_revision,
			"crossedPovRevision":pov_receipt_coordinator.current_translucent_pov_snapshot(
				pov_receipt_key).get("revision"),
			"crossedReceiptLive":crossed_pov_receipt_live})
	check("translucent_pov_change_queues_bounded_replacement_and_retains_old_receipt",
		drained_translucent_demand.get("status") == "ready"
		and drained_translucent_demand.get("sectionKey") == pov_receipt_key
		and pov_resort_refresh.get("povResortsQueued") == 1
		and queued_translucent_demand.get("stage") == "waiting"
		and queued_translucent_demand.get("urgentRecompile", false)
		and queued_translucent_demand.get("lastWakeReason") == "translucent_camera_pov_changed"
		and pov_receipt_coordinator._production_candidate_receipts[pov_receipt_key] \
			== translucent_receipt
		and pov_receipt_coordinator._production_candidates_by_section[pov_receipt_key] \
			== translucent_candidate
		and same_pov_resort_refresh.get("povResortsQueued") == 0
		and pov_receipt_coordinator._visible_section_demand_count == 1,
		{"refresh":pov_resort_refresh, "sameClassRefresh":same_pov_resort_refresh,
			"demand":queued_translucent_demand,
			"oldReceiptRetained":pov_receipt_coordinator._production_candidate_receipts[
				pov_receipt_key] == translucent_receipt,
			"queuedDemandCount":pov_receipt_coordinator._visible_section_demand_count})
	var empty_manifest: Array[Dictionary] = []
	empty_manifest.make_read_only()
	var path_descriptor := {"schema":"section-translucent-face-groups/v1",
		"povRevision":14}
	var path_batch := {"renderLayer":"translucent",
		"translucentSortDescriptor":path_descriptor}
	var path_batches := {"fixture:glass":path_batch}
	path_batches.make_read_only()
	var path_snapshot := {"manifest":empty_manifest, "batches":path_batches}
	path_snapshot.make_read_only()
	var path_candidate := {"worldId":pov_receipt_world,
		"sectionKey":pov_receipt_key, "generation":10,
		"contentManifestDigest":"fixture-pov-session-manifest",
		"snapshot":path_snapshot}
	var empty_revisions: Dictionary = {}
	empty_revisions.make_read_only()
	var empty_contributors: Array[String] = []
	empty_contributors.make_read_only()
	var section_census := {pov_receipt_key:empty_contributors}
	section_census.make_read_only()
	var empty_bindings: Dictionary = {}
	empty_bindings.make_read_only()
	var boundary_session := FakeInstalledSession.new()
	boundary_session.configure(path_candidate, 14)
	boundary_session.return_pending = true
	var boundary_coordinator := FixtureCoordinator.new()
	boundary_coordinator.configure(pov_receipt_world + ":boundary-pov-advance")
	boundary_coordinator.refresh_visible_section_demand_priorities(
		Vector3(1.0, 1.0, 1.0), 1)
	boundary_coordinator._active_boundary = {"boundaryId":"fixture:pov-boundary",
		"phase":"installing", "candidate":{"replacements":[path_candidate]},
		"replacementIndex":0, "receipts":{}, "installSession":boundary_session,
		"declarations":[], "removals":[]}
	var boundary_pov_advance := boundary_coordinator.advance_boundary(
		empty_revisions, section_census, empty_bindings, empty_bindings, 1)
	var pov_replay_session := FakeInstalledSession.new()
	pov_replay_session.configure(path_candidate, 14)
	pov_replay_session.return_pending = true
	var replay_coordinator := FixtureCoordinator.new()
	replay_coordinator.configure(pov_receipt_world + ":replay-pov-advance")
	replay_coordinator.refresh_visible_section_demand_priorities(
		Vector3(1.0, 1.0, 1.0), 1)
	replay_coordinator._active_replay = {"candidate":path_candidate,
		"sectionKey":pov_receipt_key, "installSession":pov_replay_session}
	var replay_pov_advance := replay_coordinator.advance_replay(
		empty_revisions, section_census, empty_bindings, empty_bindings, 1)
	check("boundary_and_replay_sessions_receive_current_translucent_pov_revision",
		boundary_pov_advance.get("status") == "pending"
		and boundary_session.last_pov_revision == 14
		and replay_pov_advance.get("status") == "pending"
		and pov_replay_session.last_pov_revision == 14,
		{"boundary":boundary_pov_advance,
			"boundaryPovArgument":boundary_session.last_pov_revision,
			"replay":replay_pov_advance,
			"replayPovArgument":pov_replay_session.last_pov_revision})
	var native_replay_report := await _run_native_stale_pov_replay_contract()
	check("stale_translucent_replay_recaptures_and_installs_current_pov_candidate",
		bool(native_replay_report.get("passed", false)), native_replay_report)
	var retry_world := world_id + ":next-frame-retry"
	var retry_coordinator = FixtureCoordinator.new()
	retry_coordinator.configure(retry_world)
	var retry_required: Array[String] = ["terrain", "ecology"]
	retry_required.make_read_only()
	retry_coordinator.configure_source_roster(retry_required)
	var retry_terrain := EmptySectionProvider.new()
	retry_terrain.configure("terrain", retry_world)
	retry_terrain.pending_capture_calls = 1
	var retry_ecology := EmptySectionProvider.new()
	retry_ecology.configure("ecology", retry_world)
	retry_coordinator.register_source_provider("terrain", retry_terrain,
		"capture_static_section_sources")
	retry_coordinator.register_source_provider("ecology", retry_ecology,
		"capture_static_section_sources")
	var retry_section := Vector3i(40, 0, 0)
	retry_coordinator.request_visible_section_demand(retry_section, 1, 1.0)
	var first_retry_frame := Engine.get_process_frames()
	var first_retry_advance: Dictionary = retry_coordinator.advance_visible_section_candidate_demands(1)
	var retry_state: Dictionary = retry_coordinator._visible_section_demands[retry_section]
	var scheduled_retry_frame := int(retry_state.get("nextAttemptFrame", -1))
	var delayed_retry_status: Dictionary = retry_coordinator.status()
	var second_retry_advance: Dictionary = retry_coordinator.advance_visible_section_candidate_demands(1)
	check("retryable_source_census_is_parked_for_thirty_publication_frames",
		first_retry_advance.get("status") == "advanced"
		and first_retry_advance.results[0].admission.get("providerReason", "")
			== "fixture_incremental_capture_pending"
		and scheduled_retry_frame - first_retry_frame == 30
		and delayed_retry_status.get("status") == "busy"
		and delayed_retry_status.get("pendingVisibleSectionDemandCount") == 1
		and delayed_retry_status.get("visibleSectionDemandStages", {}).get("waiting", 0) == 1
		and second_retry_advance.get("status") == "idle"
		and retry_terrain.capture_calls == 1,
		{"firstAdvance":first_retry_advance, "secondAdvance":second_retry_advance,
			"delayedRetryStatus":delayed_retry_status,
			"firstRetryFrame":first_retry_frame,
			"scheduledRetryFrame":scheduled_retry_frame,
			"currentFrame":Engine.get_process_frames(),
		"captureCalls":retry_terrain.capture_calls})
	var continuation_world := world_id + ":resumable-capture"
	var continuation_coordinator = FixtureCoordinator.new()
	continuation_coordinator.configure(continuation_world)
	var continuation_required: Array[String] = ["terrain", "ecology"]
	continuation_required.make_read_only()
	continuation_coordinator.configure_source_roster(continuation_required)
	var continuation_terrain := EmptySectionProvider.new()
	continuation_terrain.configure("terrain", continuation_world)
	continuation_terrain.pending_capture_calls = 1
	continuation_terrain.pending_continuation = true
	var continuation_ecology := EmptySectionProvider.new()
	continuation_ecology.configure("ecology", continuation_world)
	continuation_coordinator.register_source_provider("terrain", continuation_terrain,
		"capture_static_section_sources")
	continuation_coordinator.register_source_provider("ecology", continuation_ecology,
		"capture_static_section_sources")
	var continuation_section := Vector3i(2, 0, 0)
	var farther_initial_section := Vector3i(8, 0, 0)
	continuation_coordinator.request_visible_section_demand(continuation_section, 1, 1.0)
	var continuation_first_frame := Engine.get_process_frames()
	var continuation_first: Dictionary = continuation_coordinator.advance_visible_section_candidate_demands(1)
	var continuation_state: Dictionary = continuation_coordinator._visible_section_demands[
		continuation_section]
	continuation_coordinator.request_visible_section_demand(farther_initial_section, 1, 100.0)
	var fresh_turn: Dictionary = continuation_coordinator._take_next_visible_section_demand()
	var fresh_turn_is_fair: bool = fresh_turn.get("sectionKey") == farther_initial_section
	while Engine.get_process_frames() <= continuation_first_frame:
		await process_frame
	var continuation_turn: Dictionary = continuation_coordinator._take_next_visible_section_demand()
	check("resumable_provider_cursor_gets_next_frame_retry_with_initial_compile_fairness",
		continuation_first.get("status") == "advanced"
			and String(continuation_state.get("continuationHint", {}).get("stage", "")) \
				== "fixture_capture"
			and int(continuation_state.get("nextAttemptFrame", -1)) \
				- continuation_first_frame == 1
			and fresh_turn_is_fair
			and continuation_turn.get("sectionKey") == continuation_section,
		{"firstAdvance":continuation_first,
			"continuationHint":continuation_state.get("continuationHint", {}),
			"nextAttemptFrame":continuation_state.get("nextAttemptFrame", -1),
			"firstFrame":continuation_first_frame,
			"currentFrame":Engine.get_process_frames(),
			"freshTurn":fresh_turn, "continuationTurn":continuation_turn})
	var admitted_generation := int(continuation_state.get("admissionGeneration", 0))
	continuation_coordinator._enqueue_visible_section_demand(continuation_section,
		continuation_state)
	var continuation_retry := continuation_coordinator.advance_visible_section_candidate_demands(1)
	var continuation_after: Dictionary = continuation_coordinator._visible_section_demands[
		continuation_section]
	check("continuation_reuses_candidate_generation_until_admission_completes",
		admitted_generation > 0
			and continuation_retry.get("status") == "advanced"
			and continuation_after.get("stage") == "candidate_queued"
			and int(continuation_after.get("candidateGeneration", 0)) == admitted_generation
			and not continuation_after.has("admissionGeneration"),
		{"initialGeneration":admitted_generation, "retry":continuation_retry,
			"state":continuation_after})
	var fluid_coordinator := FixtureCoordinator.new()
	fluid_coordinator.configure(world_id + ":fluid-proof-wakeup")
	var fluid_section := Vector3i(6, 2, -3)
	var stale_fluid_section := Vector3i(7, 2, -3)
	var fluid_demand := fluid_coordinator.request_visible_section_demand(
		fluid_section, 1, 40.0)
	var stale_fluid_demand := fluid_coordinator.request_visible_section_demand(
		stale_fluid_section, 1, 41.0)
	var fluid_main := FakeFluidRuntimeMain.new()
	fluid_main.world_static_section_coordinator = fluid_coordinator
	var fluid_generation := FakeFluidWorldGeneration.new()
	fluid_generation.terrain_volume_service = FakeFluidRevisionAuthority.new()
	fluid_main.world_generation_system = fluid_generation
	var fluid_runtime := TerrainRuntime.new()
	fluid_runtime.main = fluid_main
	fluid_runtime.configured_seed = fluid_main.seed_text
	fluid_runtime.site_gate = FakeFluidSiteGate.new()
	fluid_runtime.authority_ready = true
	# Source-revision capture follows the production generator -> immutable
	# context path. The fluid authority stays synthetic, but the section revision
	# must not silently pass without a generator/profile identity.
	var fluid_context = TerrainRuntime.CONTEXT_SCRIPT.new()
	fluid_context.seed_text = fluid_main.seed_text
	fluid_context.seed_hash = fluid_main.seed_hash
	fluid_context.setup_noise()
	var fluid_generator = TerrainRuntime.GENERATOR_SCRIPT.new()
	fluid_generator.setup(fluid_context)
	fluid_runtime.generator = fluid_generator
	# Source-revision capture includes the actual mesher/material identity. Keep
	# this synthetic probe's renderer authority minimal but complete.
	var fluid_terrain := VoxelTerrain.new()
	fluid_terrain.mesher = VoxelMesherTransvoxel.new()
	fluid_terrain.material_override = StandardMaterial3D.new()
	fluid_runtime.terrain = fluid_terrain
	var delayed_fluid_demand: Dictionary = fluid_coordinator._visible_section_demands[fluid_section]
	delayed_fluid_demand["nextAttemptFrame"] = Engine.get_process_frames() + 30
	fluid_coordinator._visible_section_demands[fluid_section] = delayed_fluid_demand
	var delayed_other_demand: Dictionary = fluid_coordinator._visible_section_demands[stale_fluid_section]
	delayed_other_demand["nextAttemptFrame"] = Engine.get_process_frames() + 30
	fluid_coordinator._visible_section_demands[stale_fluid_section] = delayed_other_demand
	fluid_runtime.request_terrain_section_fluid_probe(fluid_section)
	var current_fluid_proof: Dictionary = fluid_runtime.advance_terrain_section_fluid_probes()
	var current_fluid_demand: Dictionary = fluid_coordinator._visible_section_demands[fluid_section]
	var duplicate_fluid_request: Dictionary = fluid_runtime.request_terrain_section_fluid_probe(fluid_section)
	var duplicate_fluid_wake: Dictionary = fluid_coordinator.wake_visible_section_demand(
		fluid_section, "exact_terrain_fluid_proof_current",
		String(current_fluid_proof.get("signature", "")))
	check("accepted_current_fluid_proof_wakes_only_its_delayed_demand_once",
		fluid_demand.get("status") == "queued"
			and stale_fluid_demand.get("status") == "queued"
			and current_fluid_proof.get("status") == "ready"
			and current_fluid_proof.get("demandWake", {}).get("status") == "woken"
			and current_fluid_demand.get("eventWake", false)
			and int(current_fluid_demand.get("nextAttemptFrame", -1)) == Engine.get_process_frames()
			and int(fluid_coordinator._visible_section_demands[stale_fluid_section].nextAttemptFrame)
				> Engine.get_process_frames()
			and duplicate_fluid_request.get("status") == "ready"
			and duplicate_fluid_wake.get("status") == "duplicate"
			and fluid_coordinator._visible_section_demand_count == 2,
		{"proof":current_fluid_proof, "duplicateProbeRequest":duplicate_fluid_request,
			"duplicateWake":duplicate_fluid_wake, "demand":current_fluid_demand,
			"otherDemand":fluid_coordinator._visible_section_demands[stale_fluid_section],
			"queueCount":fluid_coordinator._visible_section_demand_count})
	var selected_fluid_demand: Dictionary = fluid_coordinator._take_next_visible_section_demand()
	var selected_after_wake: Dictionary = fluid_coordinator._visible_section_demands.get(
		selected_fluid_demand.get("sectionKey", Vector3i.ZERO), {})
	var duplicate_after_dequeue: Dictionary = fluid_coordinator.wake_visible_section_demand(
		fluid_section, "exact_terrain_fluid_proof_current",
		String(current_fluid_proof.get("signature", "")))
	check("event_wake_bypasses_only_its_section_retry_delay_once",
		selected_fluid_demand.get("status") == "ready"
			and selected_fluid_demand.get("sectionKey") == fluid_section
			and not selected_after_wake.has("eventWake")
			and duplicate_after_dequeue.get("status") == "duplicate"
			and fluid_coordinator._visible_section_demand_count == 1
			and not fluid_coordinator._visible_section_demands[stale_fluid_section].has("eventWake"),
		{"selected":selected_fluid_demand, "selectedState":selected_after_wake,
			"duplicateAfterDequeue":duplicate_after_dequeue,
			"otherState":fluid_coordinator._visible_section_demands[stale_fluid_section]})
	var missing_demand_wake: Dictionary = fluid_coordinator.wake_visible_section_demand(
		Vector3i(90, 0, 0), "exact_terrain_fluid_proof_current", "fixture-no-demand-proof")
	check("fluid_proof_for_non_demanded_section_is_ignored",
		missing_demand_wake.get("status") == "ignored"
			and missing_demand_wake.get("reason") == "section_not_demanded"
			and fluid_coordinator._visible_section_demand_count == 1,
		{"wake":missing_demand_wake,
			"queueCount":fluid_coordinator._visible_section_demand_count})
	fluid_generation.stale_payload = true
	fluid_runtime.request_terrain_section_fluid_probe(stale_fluid_section)
	var stale_fluid_proof: Dictionary = fluid_runtime.advance_terrain_section_fluid_probes()
	check("stale_exact_fluid_proof_does_not_wake_demand",
		stale_fluid_proof.get("status") == "pending"
			and stale_fluid_proof.get("reason") == "exact_fluid_section_probe_revision_changed"
			and not fluid_coordinator._visible_section_demands[stale_fluid_section].has("eventWake")
			and fluid_coordinator._visible_section_demand_count == 1,
		{"proof":stale_fluid_proof,
			"demand":fluid_coordinator._visible_section_demands[stale_fluid_section],
			"queueCount":fluid_coordinator._visible_section_demand_count})
	fluid_generation.stale_payload = false
	fluid_generation.has_fluid = true
	var fluid_bearing_section := Vector3i(8, 2, -3)
	fluid_coordinator.request_visible_section_demand(fluid_bearing_section, 1, 42.0)
	fluid_runtime.request_terrain_section_fluid_probe(fluid_bearing_section)
	var fluid_bearing_proof: Dictionary = fluid_runtime.advance_terrain_section_fluid_probes()
	var fluid_revision_authority: FakeFluidRevisionAuthority = \
		fluid_generation.terrain_volume_service
	fluid_revision_authority.section_revisions[fluid_bearing_section] = \
		fluid_revision_authority.exact_fluid_section_revision(fluid_bearing_section)
	var fluid_bearing_census: Dictionary = fluid_runtime.capture_static_section_sources(
		"seed:%s:%d" % [fluid_main.seed_text, fluid_main.seed_hash], [fluid_bearing_section])
	var fluid_bearing_source_proof: Dictionary = fluid_runtime.terrain_section_fluid_proofs.get(
		fluid_bearing_section, {})
	var fluid_bearing_source_part_id := fluid_runtime._terrain_section_source_part_id(
		fluid_bearing_section)
	var expected_fluid_source_revision := fluid_runtime._terrain_section_source_revision(
		fluid_bearing_section, fluid_bearing_source_proof)
	var fluid_bearing_section_row: Dictionary = fluid_bearing_census.get(
		"sections", {}).get(fluid_bearing_section, {})
	check("fluid_bearing_proof_wakes_demand_and_census_admits_current_exact_source",
		fluid_bearing_proof.get("status") == "ready"
			and fluid_bearing_proof.get("hasFluid", false)
			and fluid_bearing_proof.get("demandWake", {}).get("status") == "woken"
			and fluid_bearing_census.get("status") == "complete"
			and fluid_bearing_section_row.get("status") == "complete"
			and fluid_bearing_section_row.get("sourcePartIds", []) \
				.has(fluid_bearing_source_part_id)
			and String(fluid_bearing_census.get("sourceRevisions", {}).get(
				fluid_bearing_source_part_id, "")) == expected_fluid_source_revision
			and not expected_fluid_source_revision.is_empty(),
		{"proof":fluid_bearing_proof, "census":fluid_bearing_census,
			"expectedSourcePartId":fluid_bearing_source_part_id,
			"expectedSourceRevision":expected_fluid_source_revision})
	fluid_runtime.free()
	fluid_terrain.free()
	fluid_main.free()
	var stale_roster := SourceRoster.new()
	var stale_provider := StaleSnapshotProvider.new()
	stale_roster.bind_world(world_id + ":stale-snapshot", ["ecology_and_static_props"])
	stale_roster.register_provider("ecology_and_static_props", stale_provider,
		"capture_static_section_sources")
	var stale_census: Dictionary = stale_roster.capture_sections([Vector3i.ZERO])
	var stale_details: Dictionary = stale_census.get("providerDetails", {})
	check("pending_provider_wrapper_preserves_nested_reason_and_bounded_revision_details",
		stale_census.get("status") == "pending"
			and stale_census.get("reason") == "static_source_provider_pending"
			and stale_census.get("providerReason") == "ecology_chunk_source_snapshot_revision_stale"
			and stale_details.get("snapshotSourceRevision") == "terrain-5"
			and stale_details.get("currentSourceRevision") == "terrain-6"
			and stale_details.get("sourcePartId") == "fixture:tree:oak-3:foliage"
			and stale_details.get("cell") == Vector3i(17, 8, -4)
			and stale_details.get("blockType") == "canopyMesh"
			and stale_details.get("snapshotValidationStatus") == "ready",
		stale_census)
	var adjacent_admission_details := Coordinator._visible_section_admission_details({
		"reason":"whole_section_candidate_owns_adjacent_section",
		"requestedSection":Vector3i(-1, 1, 0),
		"ownedSection":Vector3i(-1, 1, 1),
		"sourcePartId":"fixture:crossing-source"})
	check("pending_adjacent_section_admission_keeps_exact_source_identity",
		adjacent_admission_details.get("requestedSection") == Vector3i(-1, 1, 0)
		and adjacent_admission_details.get("ownedSection") == Vector3i(-1, 1, 1)
		and adjacent_admission_details.get("sourcePartId") == "fixture:crossing-source",
		adjacent_admission_details)
	var required: Array[String] = ["terrain", "ecology"]
	required.make_read_only()
	var coordinator = FixtureCoordinator.new()
	var configured: Dictionary = coordinator.configure(world_id)
	var roster_configured: Dictionary = coordinator.configure_source_roster(required)
	var section_near := Vector3i(0, 0, 0)
	var section_far := Vector3i(3, 0, 0)
	var signal_coordinator = FixtureCoordinator.new()
	signal_coordinator.configure(world_id + ":signal")
	var main_runtime = MainRuntime.new()
	main_runtime.world_static_section_coordinator = signal_coordinator
	var fake_terrain := FakeTerrainRuntime.new()
	main_runtime.voxel_terrain_runtime = fake_terrain
	main_runtime.connect_voxel_terrain_section_demand_signal()
	fake_terrain.enter_section(section_near, 10)
	check("terrain_section_events_seed_demand_through_runtime_signal",
		main_runtime.voxel_terrain_section_demand_signal_connected
		and signal_coordinator._visible_section_demands.has(section_near)
		and int(signal_coordinator._visible_section_demands[section_near].terrainRevision) == 10,
		{"connected":main_runtime.voxel_terrain_section_demand_signal_connected,
			"demand":signal_coordinator._visible_section_demands.get(section_near, {})})
	fake_terrain.exit_section(section_near, 11)
	check("terrain_exit_event_withdraws_visible_demand",
		not signal_coordinator._visible_section_demands.has(section_near),
		{"remaining":signal_coordinator._visible_section_demands.keys()})
	fake_terrain.free()
	main_runtime.free()
	var edited_coordinator = FixtureCoordinator.new()
	edited_coordinator.configure(world_id + ":terrain-edit")
	var volume := TerrainVolume.new()
	var world := WorldGeneration.new()
	world.terrain_volume_service = volume
	var edit_runtime := MainRuntime.new()
	edit_runtime.world_generation_system = world
	edit_runtime.world_static_section_coordinator = edited_coordinator
	var voxel_runtime := TerrainRuntime.new()
	voxel_runtime.main = edit_runtime
	edit_runtime.voxel_terrain_runtime = voxel_runtime
	var resident_sections: Array[Vector3i] = []
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var resident_key := Vector3i(x, y, z)
				resident_sections.append(resident_key)
				voxel_runtime.published_mesh_blocks[resident_key] = true
				voxel_runtime.mesh_block_revisions[resident_key] = 1
	voxel_runtime.connect_terrain_volume_revision_signal()
	edit_runtime.connect_voxel_terrain_section_demand_signal()
	volume.set_cell_state(Vector3i.ZERO,
		{"solid":true, "density":1.0, "material":"stone"}, "section_render_invalidation_contract")
	var exact_halo_sections_redemanded := true
	var exact_halo_revision_count := 0
	for z in range(-1, 1):
		for y in range(-1, 1):
			for x in range(-1, 1):
				var affected_key := Vector3i(x, y, z)
				exact_halo_sections_redemanded = exact_halo_sections_redemanded \
					and edited_coordinator._visible_section_demands.has(affected_key)
				exact_halo_revision_count += int(
					int(voxel_runtime.mesh_block_revisions.get(affected_key, 0)) > 1)
	check("authoritative_terrain_revision_invalidates_resident_core_and_transvoxel_halo",
		exact_halo_sections_redemanded and exact_halo_revision_count == 8
		and edited_coordinator._visible_section_demands.size() == 8,
		{"residentSections":resident_sections.size(),
			"redemandedSections":edited_coordinator._visible_section_demands.size(),
			"exactExpectedHaloSections":8,
			"revisions":voxel_runtime.mesh_block_revisions})
	voxel_runtime.free()
	edit_runtime.free()
	var priority_coordinator = FixtureCoordinator.new()
	priority_coordinator.configure(world_id + ":urgent-recompile")
	var edited_section := Vector3i(8, 0, 0)
	var installed_candidate := {"sectionKey":edited_section, "generation":4}
	priority_coordinator._production_candidates_by_section[edited_section] = installed_candidate
	priority_coordinator.request_visible_section_demand(edited_section, 10, 900.0)
	var installed_demand: Dictionary = priority_coordinator._visible_section_demands[edited_section]
	installed_demand["stage"] = "installed"
	installed_demand["installedGeneration"] = 4
	installed_demand["queued"] = false
	priority_coordinator._visible_section_demands[edited_section] = installed_demand
	priority_coordinator._visible_section_demand_queue.clear()
	priority_coordinator._visible_section_demand_head = 0
	priority_coordinator._visible_section_demand_tail = 0
	priority_coordinator._visible_section_demand_count = 0
	for index in range(3):
		priority_coordinator.request_visible_section_demand(
			Vector3i(index, 0, 0), 1, 0.01 + float(index))
	var revision_request: Dictionary = priority_coordinator.request_visible_section_demand(
		edited_section, 11, 900.0)
	var selected_recompile: Dictionary = priority_coordinator._take_next_visible_section_demand()
	var refreshed_demand: Dictionary = priority_coordinator._visible_section_demands[edited_section]
	check("installed_section_revision_change_preempts_first_time_nearby_sections",
		revision_request.get("status") == "queued"
		and bool(refreshed_demand.get("urgentRecompile", false))
		and float(refreshed_demand.get("priority", INF)) == 0.0
		and selected_recompile.get("status") == "ready"
		and selected_recompile.get("sectionKey") == edited_section
		and priority_coordinator._production_candidates_by_section.get(edited_section) == installed_candidate,
		{"request":revision_request, "selected":selected_recompile,
			"demand":refreshed_demand,
			"previousCandidateRetained":priority_coordinator._production_candidates_by_section.get(edited_section) == installed_candidate})
	var saturated_coordinator = FixtureCoordinator.new()
	saturated_coordinator.configure(world_id + ":urgent-saturated-queue")
	for index in range(1000):
		saturated_coordinator.request_visible_section_demand(
			Vector3i(index, 1, 0), 1, float(index + 1))
	var saturated_key := Vector3i(2000, 1, 0)
	var saturated_candidate := {"sectionKey":saturated_key, "generation":12}
	saturated_coordinator._production_candidates_by_section[saturated_key] = saturated_candidate
	saturated_coordinator.request_visible_section_demand(saturated_key, 1, 999999.0)
	var saturated_state: Dictionary = saturated_coordinator._visible_section_demands[saturated_key]
	saturated_state["stage"] = "installed"
	saturated_state["installedGeneration"] = 12
	saturated_state["queued"] = false
	saturated_coordinator._visible_section_demands[saturated_key] = saturated_state
	saturated_coordinator.invalidate_visible_section_source(saturated_key,
		"terrain", "terrain:installed:fixture", "revision-2")
	var urgent_head := saturated_coordinator.has_urgent_visible_section_recompile()
	var saturated_selection := saturated_coordinator._take_next_visible_section_demand(true)
	check("urgent_installed_replacement_preempts_saturated_fifo_with_bounded_scan",
		urgent_head and saturated_selection.get("status") == "ready"
			and saturated_selection.get("sectionKey") == saturated_key
			and saturated_coordinator._production_candidates_by_section.get(saturated_key)
				== saturated_candidate
			and saturated_coordinator._visible_section_demand_count > 0,
		{"urgentHead":urgent_head, "selection":saturated_selection,
			"remainingQueueCount":saturated_coordinator._visible_section_demand_count,
			"pendingDemandCount":saturated_coordinator._visible_section_demands.size()})
	var bounded_admission_details: Dictionary = Coordinator._visible_section_admission_details({
		"status":"pending", "providerId":"ecology_and_static_props",
		"reason":"static_source_provider_pending",
		"providerReason":"ecology_chunk_source_snapshot_revision_stale",
		"providerDetails":{"chunk":Vector2i(2, -1), "sourcePartId":"fixture:tree:oak-3:foliage",
			"cell":Vector3i(17, 8, -4), "blockType":"canopyMesh",
			"snapshotRemovedPropsRevision":3,
			"currentRemovedPropsRevision":3, "snapshotSourceRevision":"old",
			"currentSourceRevision":"new", "snapshotValidationStatus":"ready"},
		"unboundedPayload":PackedByteArray([1, 2, 3])})
	check("provider_stale_revision_details_are_retained_as_bounded_scalar_telemetry",
		bounded_admission_details.get("providerReason") == "ecology_chunk_source_snapshot_revision_stale"
			and bounded_admission_details.get("snapshotSourceRevision") == "old"
			and bounded_admission_details.get("currentSourceRevision") == "new"
			and bounded_admission_details.get("sourcePartId") == "fixture:tree:oak-3:foliage"
			and bounded_admission_details.get("cell") == Vector3i(17, 8, -4)
			and bounded_admission_details.get("blockType") == "canopyMesh"
			and bounded_admission_details.get("snapshotValidationStatus") == "ready"
			and not bounded_admission_details.has("unboundedPayload"), bounded_admission_details)
	var demand: Dictionary = coordinator.request_visible_section_demand(section_far, 11, 900.0)
	check("native_mesh_section_demand_enters_retryable_coordinator_queue",
		configured.get("status") == "ready" and roster_configured.get("status") == "ready"
		and demand.get("status") == "queued"
		and coordinator._visible_section_demand_count == 1, demand)
	var missing_both: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	check("missing_terrain_and_ecology_providers_stay_pending_without_install",
		missing_both.get("status") == "advanced"
		and missing_both.results[0].admission.get("status") == "pending"
		and missing_both.results[0].admission.get("reason") == "static_source_provider_missing"
		and coordinator._production_candidate_jobs.is_empty()
		and String(coordinator._visible_section_demands[section_far].stage) == "waiting",
		missing_both)
	var terrain := EmptySectionProvider.new()
	terrain.configure("terrain", world_id)
	var terrain_registered: Dictionary = coordinator.register_source_provider(
		"terrain", terrain, "capture_static_section_sources")
	var missing_ecology: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	check("terrain_only_census_cannot_admit_partial_section",
		terrain_registered.get("status") == "ready"
		and missing_ecology.get("status") == "advanced"
		and missing_ecology.results[0].admission.get("status") == "pending"
		and missing_ecology.results[0].admission.get("reason") == "static_source_provider_missing"
		and coordinator._production_candidate_jobs.is_empty(), missing_ecology)
	var ecology := EmptySectionProvider.new()
	ecology.configure("ecology", world_id)
	var ecology_registered: Dictionary = coordinator.register_source_provider(
		"ecology", ecology, "capture_static_section_sources")
	var admitted: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	await _await_native_compiles(coordinator)
	check("explicit_complete_empty_providers_admit_candidate_without_installing_it",
		ecology_registered.get("status") == "ready"
		and admitted.get("status") == "advanced"
		and admitted.results[0].admission.get("status") == "queued"
		and coordinator._production_candidate_jobs.has(section_far)
		and coordinator._production_candidates_by_section.is_empty(), admitted)
	coordinator.request_visible_section_demand(section_far, 11, 900.0)
	check("duplicate_native_revision_does_not_duplicate_or_requeue_admitted_work",
		String(coordinator._visible_section_demands[section_far].stage) == "candidate_queued"
		and coordinator._visible_section_demand_count == 0,
		{"state":coordinator._visible_section_demands.get(section_far, {}),
			"queueCount":coordinator._visible_section_demand_count})
	var revised: Dictionary = coordinator.request_visible_section_demand(section_far, 12, 900.0)
	check("new_native_revision_supersedes_pending_candidate_with_retryable_demand",
		revised.get("status") == "queued"
		and not coordinator._production_candidate_jobs.has(section_far)
		and coordinator._visible_section_demand_count == 1,
		{"request":revised, "jobs":coordinator._production_candidate_jobs.keys()})
	coordinator.withdraw_visible_section_demand(section_far)
	coordinator.request_visible_section_demand(section_far, 13, 900.0)
	coordinator.request_visible_section_demand(section_near, 21, 900.0)
	var near_center := SectionGrid.origin_for_key(section_near) \
		+ Vector3.ONE * (SectionGrid.SECTION_SIZE_METERS * 0.5)
	var refreshed: Dictionary = coordinator.refresh_visible_section_demand_priorities(
		near_center, 16)
	var nearest: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	check("bounded_camera_refresh_prioritizes_nearest_current_demand",
		refreshed.get("status") == "advanced" and refreshed.get("updatedCount") == 2
		and nearest.get("status") == "advanced"
		and nearest.results[0].get("sectionKey") == section_near
		and coordinator._visible_section_demands.has(section_far), nearest)
	var fair_followup: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	check("unselected_demand_remains_queued_for_fair_followup",
		fair_followup.get("status") == "advanced"
		and fair_followup.results[0].get("sectionKey") == section_far,
		fair_followup)
	var withdrawn: Dictionary = coordinator.withdraw_visible_section_demand(section_near)
	check("withdrawal_cancels_only_staged_work_and_keeps_accepted_visual_state",
		withdrawn.get("status") == "withdrawn"
		and not withdrawn.get("installedRepresentationRetained", true), withdrawn)
	var lifecycle := FixtureCoordinator.new()
	var lifecycle_world := world_id + ":candidate-lifecycle"
	lifecycle.configure(lifecycle_world)
	lifecycle.configure_source_roster(required)
	var lifecycle_terrain := EmptySectionProvider.new()
	lifecycle_terrain.configure("terrain", lifecycle_world)
	var lifecycle_ecology := EmptySectionProvider.new()
	lifecycle_ecology.configure("ecology", lifecycle_world)
	lifecycle.register_source_provider("terrain", lifecycle_terrain,
		"capture_static_section_sources")
	lifecycle.register_source_provider("ecology", lifecycle_ecology,
		"capture_static_section_sources")
	var installed_key := Vector3i(10, 0, 0)
	lifecycle.request_visible_section_demand(installed_key, 31, 1.0)
	var lifecycle_admission: Dictionary = lifecycle.advance_visible_section_candidate_demands(1)
	await _await_native_compiles(lifecycle)
	var candidate_job: Dictionary = lifecycle._production_candidate_jobs.get(installed_key, {})
	var actual_candidate: Dictionary = candidate_job.get("candidate", {})
	var staged_work_status: Dictionary = lifecycle.status()
	var fake_session := FakeInstalledSession.new()
	fake_session.configure(actual_candidate)
	candidate_job["session"] = fake_session
	lifecycle._production_candidate_jobs[installed_key] = candidate_job
	var install_outcome: Dictionary = lifecycle.advance_complete_section_candidate(installed_key, 1)
	var installed_state: Dictionary = lifecycle._visible_section_demands[installed_key]
	check("candidate_install_completion_receipt_marks_matching_visible_demand_installed",
		lifecycle_admission.get("attemptCount") == 1
		and lifecycle_admission.results[0].admission.get("status") == "queued"
		and staged_work_status.get("status") == "busy"
		and staged_work_status.get("productionCandidateJobCount") == 1
		and staged_work_status.get("visibleSectionDemandStages", {}).get(
			"candidate_queued", 0) == 1
		and install_outcome.get("status") == "installed"
		and installed_state.get("stage") == "installed"
		and int(installed_state.get("installedGeneration", 0)) \
			== int(actual_candidate.get("generation", 0))
		and installed_state.get("installedReceipt", {}).get("contentManifestDigest") \
			== String(actual_candidate.get("contentManifestDigest", ""))
		and lifecycle._production_candidate_receipts.has(installed_key),
		{"admission":lifecycle_admission, "outcome":install_outcome,
			"stagedStatus":staged_work_status, "demand":installed_state})
	var installed_idle := Coordinator.new()
	installed_idle.configure(world_id + ":installed-idle-status")
	var installed_idle_key := Vector3i(99, 0, 0)
	installed_idle.request_visible_section_demand(installed_idle_key, 1, 1.0)
	var installed_idle_state: Dictionary = installed_idle._visible_section_demands[
		installed_idle_key]
	installed_idle_state["stage"] = "installed"
	installed_idle_state["queued"] = false
	installed_idle._visible_section_demands[installed_idle_key] = installed_idle_state
	var installed_idle_status: Dictionary = installed_idle.status()
	check("installed_demand_with_stale_physical_queue_row_reports_idle",
		installed_idle_status.get("status") == "idle"
		and not installed_idle.has_pending_work()
		and installed_idle_status.get("pendingVisibleSectionDemandCount") == 0
		and installed_idle_status.get("physicalVisibleDemandQueueRows") == 1,
		installed_idle_status)
	_run_attachment_reassembly_contract(world_id)
	await _run_install_owner_retirement_contract(world_id)
	var deferred_replay := Coordinator.new()
	deferred_replay.configure(world_id + ":deferred-replay-status")
	var deferred_replay_key := Vector3i(98, 0, 0)
	deferred_replay._replay_reassembly_required_by_section[deferred_replay_key] = {
		"requiredAfterPovRevision":15, "requestedFrame":Engine.get_process_frames()}
	var deferred_marker_status: Dictionary = deferred_replay.status()
	var deferred_marker_has_pending_work := deferred_replay.has_pending_work()
	var deferred_replay_demand := deferred_replay.request_visible_section_demand(
		deferred_replay_key, 1, 1.0)
	var active_marker_status: Dictionary = deferred_replay.status()
	var active_marker_has_pending_work := deferred_replay.has_pending_work()
	var withdrawn_replay_demand: Dictionary = deferred_replay.withdraw_visible_section_demand(
		deferred_replay_key)
	var withdrawn_marker_status: Dictionary = deferred_replay.status()
	var withdrawn_marker_has_pending_work := deferred_replay.has_pending_work()
	var resumed_replay_demand := deferred_replay.request_visible_section_demand(
		deferred_replay_key, 1, 1.0)
	var resumed_marker_status: Dictionary = deferred_replay.status()
	var resumed_marker_has_pending_work := deferred_replay.has_pending_work()
	check("deferred_replay_marker_is_idle_until_visible_demand_can_run",
		deferred_marker_status.get("status") == "idle"
		and not deferred_marker_has_pending_work
		and deferred_marker_status.get("replayAwaitingAuthoritativeReassemblyCount") == 1
		and deferred_marker_status.get("activeReplayReassemblyDemandCount") == 0
		and deferred_replay_demand.get("status") == "queued"
		and active_marker_status.get("status") == "busy"
		and active_marker_has_pending_work
		and active_marker_status.get("activeReplayReassemblyDemandCount") == 1
		and withdrawn_replay_demand.get("status") == "withdrawn"
		and withdrawn_marker_status.get("status") == "idle"
		and not withdrawn_marker_has_pending_work
		and withdrawn_marker_status.get("replayAwaitingAuthoritativeReassemblyCount") == 1
		and resumed_replay_demand.get("status") == "queued"
		and resumed_marker_status.get("status") == "busy"
		and resumed_marker_has_pending_work
		and resumed_marker_status.get("activeReplayReassemblyDemandCount") == 1,
		{"deferred":deferred_marker_status, "firstDemand":deferred_replay_demand,
			"hasPendingWork":{"deferred":deferred_marker_has_pending_work,
				"active":active_marker_has_pending_work,
				"withdrawn":withdrawn_marker_has_pending_work,
				"resumed":resumed_marker_has_pending_work},
			"active":active_marker_status, "withdrawal":withdrawn_replay_demand,
			"withdrawn":withdrawn_marker_status, "resumedDemand":resumed_replay_demand,
			"resumed":resumed_marker_status})
	var ack_retry := FixtureCoordinator.new()
	var ack_retry_world := world_id + ":provider-ack-retry"
	ack_retry.configure(ack_retry_world)
	ack_retry.configure_source_roster(required)
	var ack_retry_terrain := EmptySectionProvider.new()
	ack_retry_terrain.configure("terrain", ack_retry_world)
	var ack_retry_ecology := PendingInstallAckProvider.new()
	ack_retry_ecology.configure("ecology", ack_retry_world)
	ack_retry.register_source_provider("terrain", ack_retry_terrain,
		"capture_static_section_sources")
	ack_retry.register_source_provider("ecology", ack_retry_ecology,
		"capture_static_section_sources")
	var ack_retry_key := Vector3i(12, 0, 0)
	ack_retry.request_visible_section_demand(ack_retry_key, 1, 1.0)
	ack_retry.advance_visible_section_candidate_demands(1)
	await _await_native_compiles(ack_retry)
	var ack_retry_job: Dictionary = ack_retry._production_candidate_jobs.get(ack_retry_key, {})
	var ack_retry_candidate: Dictionary = ack_retry_job.get("candidate", {})
	var ack_retry_session := FakeInstalledSession.new()
	ack_retry_session.configure(ack_retry_candidate)
	ack_retry_job["session"] = ack_retry_session
	ack_retry._production_candidate_jobs[ack_retry_key] = ack_retry_job
	var ack_first_install: Dictionary = ack_retry.advance_complete_section_candidate(
		ack_retry_key, 1)
	var ack_retry_state: Dictionary = ack_retry._pending_source_acknowledgements.get(
		ack_retry_key, {})
	var ack_retry_receipt: Dictionary = ack_retry._production_candidate_receipts.get(
		ack_retry_key, {})
	var ack_unsettled_proof: Dictionary = ack_retry.source_install_acknowledgement_proof(
		ack_retry_key, ack_retry_receipt)
	var pending_ack_status: Dictionary = ack_retry.status()
	var pending_ack_has_work: bool = ack_retry.has_pending_work()
	ack_retry_state["nextAttemptFrame"] = 0
	ack_retry._pending_source_acknowledgements[ack_retry_key] = ack_retry_state
	var ack_retry_advance: Dictionary = ack_retry.advance_queued_complete_section_candidates(1, 1)
	var ack_retry_rows: Array = ack_retry_advance.get("acknowledgements", [])
	var ack_settled_proof: Dictionary = ack_retry.source_install_acknowledgement_proof(
		ack_retry_key, ack_retry_receipt)
	var mutable_ack_proof: Dictionary = ack_retry.source_install_acknowledgement_proof(
		ack_retry_key, ack_retry_receipt)
	mutable_ack_proof["status"] = "failed"
	var ack_settled_proof_after_caller_mutation: Dictionary = \
		ack_retry.source_install_acknowledgement_proof(ack_retry_key, ack_retry_receipt)
	check("pending_provider_ack_retries_current_receipt_without_native_reinstall",
		ack_first_install.get("status") == "installed"
		and ack_first_install.get("sourceAcknowledgements", {}).get("status") == "pending"
		and pending_ack_status.get("status") == "busy"
		and pending_ack_status.get("pendingSourceAcknowledgementCount") == 1
		and pending_ack_has_work
		and ack_retry_ecology.acknowledge_calls == 2
		and ack_retry_rows.size() == 1
		and ack_retry_rows[0].get("status") == "acknowledged"
		and ack_retry_rows[0].get("generation") == ack_retry_candidate.get("generation")
		and ack_unsettled_proof.get("status") == "pending"
		and ack_settled_proof.get("status") == "ready"
		and not ack_settled_proof.has("providerAcknowledgements")
		and not ack_settled_proof.has("providerCoverage")
		and ack_settled_proof_after_caller_mutation.get("status") == "ready"
		and ack_retry._pending_source_acknowledgements.is_empty()
		and ack_retry._production_candidate_receipts[ack_retry_key] == ack_retry_receipt
		and ack_retry_session.advance_calls == 1,
		{"initialInstall":ack_first_install, "retry":ack_retry_advance,
			"pendingStatus":pending_ack_status,
			"unsettledProof":ack_unsettled_proof, "settledProof":ack_settled_proof,
			"proofAfterCallerMutation":ack_settled_proof_after_caller_mutation,
			"acknowledgeCalls":ack_retry_ecology.acknowledge_calls,
			"nativeInstallAdvanceCalls":ack_retry_session.advance_calls,
			"generation":ack_retry_candidate.get("generation")})
	var failed_ack_retry := FixtureCoordinator.new()
	var failed_ack_world := world_id + ":failed-provider-ack-retry"
	failed_ack_retry.configure(failed_ack_world)
	failed_ack_retry.configure_source_roster(required)
	var failed_ack_terrain := EmptySectionProvider.new()
	failed_ack_terrain.configure("terrain", failed_ack_world)
	var failed_ack_ecology := SequencedInstallAckProvider.new()
	failed_ack_ecology.configure("ecology", failed_ack_world)
	failed_ack_ecology.responses = [
		{"status":"failed", "reason":"fixture_ack_rejected_once"},
		17,
		{"status":"acknowledged"}]
	failed_ack_retry.register_source_provider("terrain", failed_ack_terrain,
		"capture_static_section_sources")
	failed_ack_retry.register_source_provider("ecology", failed_ack_ecology,
		"capture_static_section_sources")
	var failed_ack_key := Vector3i(15, 0, 0)
	failed_ack_retry.request_visible_section_demand(failed_ack_key, 1, 1.0)
	failed_ack_retry.advance_visible_section_candidate_demands(1)
	await _await_native_compiles(failed_ack_retry)
	var failed_ack_job: Dictionary = failed_ack_retry._production_candidate_jobs.get(
		failed_ack_key, {})
	var failed_ack_candidate: Dictionary = failed_ack_job.get("candidate", {})
	var failed_ack_session := FakeInstalledSession.new()
	failed_ack_session.configure(failed_ack_candidate)
	failed_ack_job["session"] = failed_ack_session
	failed_ack_retry._production_candidate_jobs[failed_ack_key] = failed_ack_job
	var failed_ack_install: Dictionary = failed_ack_retry.advance_complete_section_candidate(
		failed_ack_key, 1)
	var failed_ack_first_state: Dictionary = failed_ack_retry._pending_source_acknowledgements.get(
		failed_ack_key, {})
	var failed_ack_receipt: Dictionary = failed_ack_retry._production_candidate_receipts.get(
		failed_ack_key, {})
	var failed_ack_first_proof: Dictionary = failed_ack_retry.source_install_acknowledgement_proof(
		failed_ack_key, failed_ack_receipt)
	failed_ack_ecology.responses[0]["reason"] = "fixture_mutated_after_provider_return"
	var retained_first_failure: Dictionary = failed_ack_first_state.get("lastResult", {})
	var failed_ack_status_after_install: Dictionary = failed_ack_retry.status()
	var failed_ack_status_summary: Dictionary = failed_ack_status_after_install.get(
		"sourceInstallAcknowledgementSummary", {})
	if not failed_ack_first_state.is_empty():
		failed_ack_first_state["nextAttemptFrame"] = 0
		failed_ack_retry._pending_source_acknowledgements[failed_ack_key] = failed_ack_first_state
	var failed_ack_second_advance: Dictionary = failed_ack_retry.advance_queued_complete_section_candidates(1, 1)
	var failed_ack_second_rows: Array = failed_ack_second_advance.get("acknowledgements", [])
	var failed_ack_second_state: Dictionary = failed_ack_retry._pending_source_acknowledgements.get(
		failed_ack_key, {})
	var failed_ack_second_proof: Dictionary = failed_ack_retry.source_install_acknowledgement_proof(
		failed_ack_key, failed_ack_receipt)
	if not failed_ack_second_state.is_empty():
		failed_ack_second_state["nextAttemptFrame"] = 0
		failed_ack_retry._pending_source_acknowledgements[failed_ack_key] = failed_ack_second_state
	var failed_ack_third_advance: Dictionary = failed_ack_retry.advance_queued_complete_section_candidates(1, 1)
	var failed_ack_third_rows: Array = failed_ack_third_advance.get("acknowledgements", [])
	var failed_ack_settled_proof: Dictionary = failed_ack_retry.source_install_acknowledgement_proof(
		failed_ack_key, failed_ack_receipt)
	check(ACK_SETTLEMENT_CHECK_NAME,
		failed_ack_install.get("status") == "installed"
		and failed_ack_install.get("sourceAcknowledgements", {}).get("status") == "failed"
		and failed_ack_status_after_install.get("status") == "busy"
		and failed_ack_status_after_install.get("pendingSourceAcknowledgementCount") == 1
		and failed_ack_status_summary.get("total") == 1
		and failed_ack_status_summary.get("counts", {}).get("failed") == 1
		and failed_ack_status_summary.get("sample", []).size() <= 8
		and failed_ack_first_state.get("lastResult", {}).get("status") == "failed"
		and retained_first_failure.get("result", {}).get("reason") \
			== "fixture_ack_rejected_once"
		and failed_ack_first_proof.get("status") == "failed"
		and failed_ack_second_rows.size() == 1
		and failed_ack_second_rows[0].get("status") == "failed"
		and failed_ack_second_state.get("lastResult", {}).get("status") == "failed"
		and failed_ack_second_proof.get("status") == "failed"
		and failed_ack_third_rows.size() == 1
		and failed_ack_third_rows[0].get("status") == "acknowledged"
		and failed_ack_settled_proof.get("status") == "ready"
		and failed_ack_retry._pending_source_acknowledgements.is_empty()
		and failed_ack_retry._production_candidate_receipts.get(failed_ack_key, {}) == failed_ack_receipt
		and failed_ack_ecology.acknowledge_calls == 3
		and failed_ack_ecology.acknowledged_generations == [failed_ack_candidate.get("generation")]
		and failed_ack_session.advance_calls == 1,
		{"initialInstall":failed_ack_install,
			"pendingStatus":failed_ack_status_after_install,
			"statusSummary":failed_ack_status_summary,
			"initialProof":failed_ack_first_proof,
			"firstSettlement":failed_ack_first_state,
			"failedRetry":failed_ack_second_advance,
			"proofAfterMalformed":failed_ack_second_proof,
			"retainedAfterMalformed":failed_ack_second_state,
			"successfulRetry":failed_ack_third_advance,
			"settledProof":failed_ack_settled_proof,
			"acknowledgeCalls":failed_ack_ecology.acknowledge_calls,
			"nativeInstallAdvanceCalls":failed_ack_session.advance_calls})
	var stale_ack_retry := FixtureCoordinator.new()
	var stale_ack_world := world_id + ":stale-provider-ack-retry"
	stale_ack_retry.configure(stale_ack_world)
	stale_ack_retry.configure_source_roster(required)
	var stale_ack_terrain := EmptySectionProvider.new()
	stale_ack_terrain.configure("terrain", stale_ack_world)
	var stale_ack_ecology := PendingInstallAckProvider.new()
	stale_ack_ecology.configure("ecology", stale_ack_world)
	stale_ack_retry.register_source_provider("terrain", stale_ack_terrain,
		"capture_static_section_sources")
	stale_ack_retry.register_source_provider("ecology", stale_ack_ecology,
		"capture_static_section_sources")
	var stale_ack_key := Vector3i(13, 0, 0)
	stale_ack_retry.request_visible_section_demand(stale_ack_key, 1, 1.0)
	stale_ack_retry.advance_visible_section_candidate_demands(1)
	await _await_native_compiles(stale_ack_retry)
	var stale_ack_job: Dictionary = stale_ack_retry._production_candidate_jobs.get(
		stale_ack_key, {})
	var stale_ack_candidate: Dictionary = stale_ack_job.get("candidate", {})
	var stale_ack_session := FakeInstalledSession.new()
	stale_ack_session.configure(stale_ack_candidate)
	stale_ack_job["session"] = stale_ack_session
	stale_ack_retry._production_candidate_jobs[stale_ack_key] = stale_ack_job
	var stale_ack_install: Dictionary = stale_ack_retry.advance_complete_section_candidate(
		stale_ack_key, 1)
	var old_pending_receipt: Dictionary = stale_ack_retry._production_candidate_receipts[
		stale_ack_key]
	var old_ack_generation := int(stale_ack_install.get("generation", 0))
	stale_ack_ecology.pending_generations.append(old_ack_generation)
	var old_receipt_live_before_replacement: bool = \
		stale_ack_retry.installed_section_receipt_is_current(stale_ack_key,
			old_pending_receipt)
	var replacement_generation := old_ack_generation + 1
	var newer_generation_admission: Dictionary = \
		stale_ack_retry.assemble_and_submit_complete_section_candidate(
			stale_ack_key, replacement_generation)
	await _await_native_compiles(stale_ack_retry)
	var newer_generation_job: Dictionary = stale_ack_retry._production_candidate_jobs.get(
		stale_ack_key, {})
	var newer_generation_candidate: Dictionary = newer_generation_job.get("candidate", {})
	var newer_generation_session := FakeInstalledSession.new()
	newer_generation_session.configure(newer_generation_candidate)
	newer_generation_job["session"] = newer_generation_session
	stale_ack_retry._production_candidate_jobs[stale_ack_key] = newer_generation_job
	var old_ack_still_pending_before_replacement: bool = \
		stale_ack_retry._pending_source_acknowledgements.has(stale_ack_key)
	var newer_generation_install: Dictionary = stale_ack_retry.advance_complete_section_candidate(
		stale_ack_key, 1)
	var newer_generation_receipt: Dictionary = stale_ack_retry._production_candidate_receipts.get(
		stale_ack_key, {})
	var old_receipt_settlement_after_replacement: Dictionary = \
		stale_ack_retry.source_install_acknowledgement_proof(stale_ack_key, old_pending_receipt)
	var replacement_settlement: Dictionary = stale_ack_retry.source_install_acknowledgement_proof(
		stale_ack_key, newer_generation_receipt)
	var stale_ack_advance: Dictionary = stale_ack_retry.advance_queued_complete_section_candidates(1, 1)
	var stale_ack_rows: Array = stale_ack_advance.get("acknowledgements", [])
	check("same_revision_replacement_drops_old_ack_only_after_current_install",
		stale_ack_install.get("status") == "installed"
		and old_receipt_live_before_replacement
		and old_ack_still_pending_before_replacement
		and newer_generation_admission.get("status") == "queued"
		and newer_generation_install.get("status") == "installed"
		and int(newer_generation_install.get("generation", 0)) == replacement_generation
		and newer_generation_candidate.get("sourceRevisions") \
			== stale_ack_candidate.get("sourceRevisions")
		and newer_generation_receipt != old_pending_receipt
		and stale_ack_ecology.acknowledge_calls == 2
		and stale_ack_ecology.acknowledged_generations == [replacement_generation]
		and old_receipt_settlement_after_replacement.get("status") == "pending"
		and replacement_settlement.get("status") == "ready"
		and stale_ack_rows.is_empty()
		and stale_ack_retry._pending_source_acknowledgements.is_empty()
		and stale_ack_session.advance_calls == 1
		and newer_generation_session.advance_calls == 1,
		{"initialInstall":stale_ack_install,
			"oldReceiptLiveBeforeReplacement":old_receipt_live_before_replacement,
			"oldAckStillPendingBeforeReplacement":old_ack_still_pending_before_replacement,
			"replacementAdmission":newer_generation_admission,
			"replacementInstall":newer_generation_install,
			"replacementReceiptGeneration":newer_generation_receipt.get("generation"),
			"oldSettlementAfterReplacement":old_receipt_settlement_after_replacement,
			"replacementSettlement":replacement_settlement,
			"retryAfterReplacement":stale_ack_advance,
			"acknowledgeCalls":stale_ack_ecology.acknowledge_calls,
			"acknowledgedGenerations":stale_ack_ecology.acknowledged_generations,
			"oldNativeInstallAdvanceCalls":stale_ack_session.advance_calls,
			"newNativeInstallAdvanceCalls":newer_generation_session.advance_calls})
	var unload_ack_retry := FixtureCoordinator.new()
	var unload_ack_world := world_id + ":unloaded-provider-ack-retry"
	unload_ack_retry.configure(unload_ack_world)
	unload_ack_retry.configure_source_roster(required)
	var unload_ack_terrain := EmptySectionProvider.new()
	unload_ack_terrain.configure("terrain", unload_ack_world)
	var unload_ack_ecology := PendingInstallAckProvider.new()
	unload_ack_ecology.configure("ecology", unload_ack_world)
	unload_ack_retry.register_source_provider("terrain", unload_ack_terrain,
		"capture_static_section_sources")
	unload_ack_retry.register_source_provider("ecology", unload_ack_ecology,
		"capture_static_section_sources")
	var unload_ack_key := Vector3i(14, 0, 0)
	unload_ack_retry.request_visible_section_demand(unload_ack_key, 1, 1.0)
	unload_ack_retry.advance_visible_section_candidate_demands(1)
	await _await_native_compiles(unload_ack_retry)
	var unload_ack_job: Dictionary = unload_ack_retry._production_candidate_jobs.get(
		unload_ack_key, {})
	var unload_ack_candidate: Dictionary = unload_ack_job.get("candidate", {})
	var unload_ack_session := FakeInstalledSession.new()
	unload_ack_session.configure(unload_ack_candidate)
	unload_ack_job["session"] = unload_ack_session
	unload_ack_retry._production_candidate_jobs[unload_ack_key] = unload_ack_job
	var unload_ack_install: Dictionary = unload_ack_retry.advance_complete_section_candidate(
		unload_ack_key, 1)
	var unload_ack_receipt: Dictionary = unload_ack_retry._production_candidate_receipts.get(
		unload_ack_key, {})
	var unloaded_ack_owner := SectionGrid.chunk_key_for_section(unload_ack_key)
	var unloaded_ack_count: int = unload_ack_retry.notify_stream_chunk_unloaded(
		unloaded_ack_owner, int(unload_ack_receipt.get("chunkInstanceId", 0)))
	var unload_settlement_after_owner_unload: Dictionary = \
		unload_ack_retry.source_install_acknowledgement_proof(unload_ack_key,
			unload_ack_receipt)
	check("unload_drops_pending_provider_ack_before_any_retry",
		unload_ack_install.get("status") == "installed"
		and unload_ack_retry._pending_source_acknowledgements.is_empty()
		and unloaded_ack_count > 0
		and unload_ack_ecology.acknowledge_calls == 1
		and not unload_ack_retry._production_candidate_receipts.has(unload_ack_key)
		and unload_settlement_after_owner_unload.get("status") == "pending"
		and unload_ack_session.advance_calls == 1,
		{"initialInstall":unload_ack_install, "unloadedSections":unloaded_ack_count,
			"settlementAfterUnload":unload_settlement_after_owner_unload,
			"acknowledgeCalls":unload_ack_ecology.acknowledge_calls,
			"nativeInstallAdvanceCalls":unload_ack_session.advance_calls})
	var prior_candidate: Dictionary = lifecycle._production_candidates_by_section[installed_key]
	var indexed_candidate: Dictionary = prior_candidate.duplicate(false)
	var prior_source_revisions := {"ecology:part:fixture":"prop-revision-1"}
	prior_source_revisions.make_read_only()
	indexed_candidate["sourceRevisions"] = prior_source_revisions
	var indexed_prepared: Dictionary = prior_candidate.candidate.duplicate(true)
	var indexed_snapshot: Dictionary = indexed_prepared.snapshot.duplicate(true)
	indexed_snapshot["manifest"] = [{"sourceId":"ecology:prop:fixture",
		"sourcePartId":"ecology:part:fixture", "sourceRevision":"prop-revision-1"}]
	indexed_prepared["snapshot"] = indexed_snapshot
	indexed_candidate["candidate"] = indexed_prepared
	lifecycle._replace_section_source_index(installed_key, prior_candidate, indexed_candidate)
	lifecycle._production_candidates_by_section[installed_key] = indexed_candidate
	prior_candidate = indexed_candidate
	var prior_generation := int(installed_state.get("installedGeneration", 0))
	lifecycle_ecology.authority_revision = 2
	var invalidation: Dictionary = lifecycle.invalidate_visible_static_source(
		"ecology", "ecology:prop:fixture", "prop-revision-2")
	var invalidated_state: Dictionary = lifecycle._visible_section_demands[installed_key].duplicate(true)
	var invalidation_results: Array = invalidation.get("results", [])
	var first_invalidation: Dictionary = invalidation_results[0] if not invalidation_results.is_empty() else {}
	var invalidation_checks := {"queued":invalidation.get("status") == "queued",
		"previous_generation":first_invalidation.get("previousInstalledGeneration") == prior_generation,
		"representation_retained":bool(first_invalidation.get("previousRepresentationRetained", false)),
		"waiting":invalidated_state.get("stage") == "waiting",
		"still_queued":bool(invalidated_state.get("queued", false)),
		"urgent_recompile":bool(invalidated_state.get("urgentRecompile", false)),
		"urgent_priority":float(invalidated_state.get("priority", INF)) == 0.0,
		"old_generation_retained":int(invalidated_state.get("installedGeneration", 0)) == prior_generation,
		"old_candidate_retained":is_same(lifecycle._production_candidates_by_section[installed_key], prior_candidate),
		"index_uses_source_id_not_source_part_id":lifecycle._visible_sections_by_source_id.has("ecology:prop:fixture")
			and not lifecycle._visible_sections_by_source_id.has("ecology:part:fixture")}
	check("source_revision_invalidation_queues_complete_rebuild_and_keeps_old_receipt",
		not invalidation_checks.values().has(false),
		{"invalidation":invalidation, "state":invalidated_state,
		"checks":invalidation_checks,
		"sourceIndexedByManifestIdentity":lifecycle._visible_sections_by_source_id.has("ecology:prop:fixture")
			and not lifecycle._visible_sections_by_source_id.has("ecology:part:fixture"),
		"candidateSame":is_same(lifecycle._production_candidates_by_section[installed_key], prior_candidate)})
	var replacement_admission: Dictionary = lifecycle.advance_visible_section_candidate_demands(1)
	await _await_native_compiles(lifecycle)
	var replacement_job: Dictionary = lifecycle._production_candidate_jobs.get(installed_key, {})
	var replacement_candidate: Dictionary = replacement_job.get("candidate", {})
	var replacement_session := FakeInstalledSession.new()
	replacement_session.configure(replacement_candidate)
	replacement_job["session"] = replacement_session
	lifecycle._production_candidate_jobs[installed_key] = replacement_job
	var replacement_outcome: Dictionary = lifecycle.advance_complete_section_candidate(installed_key, 1)
	var replaced_state: Dictionary = lifecycle._visible_section_demands[installed_key]
	check("changed_source_replaces_candidate_only_after_current_install_receipt",
		replacement_admission.get("attemptCount") == 1
		and replacement_job.get("candidate", {}).get("censusDigest") != prior_candidate.get("censusDigest")
		and replacement_outcome.get("status") == "installed"
		and replaced_state.get("stage") == "installed"
		and int(replaced_state.get("installedGeneration", 0)) > prior_generation
		and not replaced_state.has("sourceInvalidation")
		and int(lifecycle._production_candidates_by_section[installed_key].get("generation", 0)) \
			== int(replacement_candidate.get("generation", 0))
		and not lifecycle._visible_sections_by_source_id.has("ecology:prop:fixture"),
		{"admission":replacement_admission, "outcome":replacement_outcome,
			"installedGeneration":replaced_state.get("installedGeneration", 0)})
	var added_source_bounds := AABB(SectionGrid.origin_for_key(installed_key),
		Vector3.ONE * SectionGrid.SECTION_SIZE_METERS)
	var added_source_invalidation: Dictionary = lifecycle.invalidate_visible_static_source(
		"ecology", "ecology:new:fixture", "new-source-revision", added_source_bounds)
	var added_source_state: Dictionary = lifecycle._visible_section_demands[installed_key]
	check("new_static_source_bounds_invalidate_intersecting_demanded_section",
		added_source_invalidation.get("status") == "queued"
		and added_source_invalidation.get("affectedSectionKeys") == [installed_key]
		and int(added_source_invalidation.get("queuedCount", 0)) == 1
		and added_source_state.get("stage") == "waiting"
		and added_source_state.get("queued"),
		{"invalidation":added_source_invalidation, "state":added_source_state})
	var replay_lifecycle := FixtureCoordinator.new()
	var replay_world := world_id + ":withdrawn-source-replay"
	replay_lifecycle.configure(replay_world)
	replay_lifecycle.configure_source_roster(required)
	var replay_terrain := EmptySectionProvider.new()
	replay_terrain.configure("terrain", replay_world)
	var replay_ecology := EmptySectionProvider.new()
	replay_ecology.configure("ecology", replay_world)
	replay_lifecycle.register_source_provider("terrain", replay_terrain,
		"capture_static_section_sources")
	replay_lifecycle.register_source_provider("ecology", replay_ecology,
		"capture_static_section_sources")
	var replay_key := Vector3i(4, 0, 0)
	replay_lifecycle.request_visible_section_demand(replay_key, 41, 1.0)
	replay_lifecycle.advance_visible_section_candidate_demands(1)
	await _await_native_compiles(replay_lifecycle)
	var replay_job: Dictionary = replay_lifecycle._production_candidate_jobs.get(replay_key, {})
	var replay_original: Dictionary = replay_job.get("candidate", {})
	var replay_session := FakeInstalledSession.new()
	replay_session.configure(replay_original)
	replay_job["session"] = replay_session
	replay_lifecycle._production_candidate_jobs[replay_key] = replay_job
	var replay_install: Dictionary = replay_lifecycle.advance_complete_section_candidate(replay_key, 1)
	var replay_indexed: Dictionary = replay_lifecycle._production_candidates_by_section[replay_key].duplicate(false)
	var replay_prepared: Dictionary = replay_indexed.candidate.duplicate(true)
	var replay_snapshot: Dictionary = replay_prepared.snapshot.duplicate(true)
	replay_snapshot["manifest"] = [{"sourceId":"ecology:prop:replay",
		"sourcePartId":"ecology:part:replay", "sourceRevision":"prop-revision-1"}]
	replay_prepared["snapshot"] = replay_snapshot
	replay_indexed["candidate"] = replay_prepared
	replay_lifecycle._replace_section_source_index(replay_key,
		replay_lifecycle._production_candidates_by_section[replay_key], replay_indexed)
	replay_lifecycle._production_candidates_by_section[replay_key] = replay_indexed
	replay_lifecycle._committed_candidates[replay_key] = replay_indexed
	replay_lifecycle._replay_set[replay_key] = true
	replay_lifecycle._replay_queue.append(replay_key)
	var legacy_active_session := FakeInstalledSession.new()
	legacy_active_session.configure(replay_indexed)
	replay_lifecycle._active_replay = {"candidate":replay_indexed,
		"sectionKey":replay_key, "installSession":legacy_active_session}
	var replay_withdrawal: Dictionary = replay_lifecycle.withdraw_visible_section_demand(replay_key)
	replay_ecology.authority_revision = 2
	var replay_invalidation: Dictionary = replay_lifecycle.invalidate_visible_static_source(
		"ecology", "ecology:prop:replay", "prop-revision-2")
	var replay_dirty: Dictionary = replay_lifecycle._dirty_source_sections.get(replay_key, {})
	var replay_invalidation_rows: Array = replay_invalidation.get("results", [])
	var replay_invalidation_row: Dictionary = replay_invalidation_rows[0] \
		if not replay_invalidation_rows.is_empty() else {}
	var owner_cell := SectionGrid.chunk_key_for_section(replay_key)
	var unload_count: int = replay_lifecycle.notify_stream_chunk_unloaded(owner_cell, 202)
	var load_count: int = replay_lifecycle.notify_stream_chunk_loaded(owner_cell)
	var replay_request_blocked: bool = not replay_lifecycle.request_section_replay(replay_key)
	var no_stale_replay_job := not replay_lifecycle._production_candidate_jobs.has(replay_key)
	var no_legacy_replay_work := replay_lifecycle._replay_queue.is_empty() \
		and not replay_lifecycle._replay_set.has(replay_key) \
		and replay_lifecycle._active_replay.is_empty() and legacy_active_session.cancelled
	var late_legacy_session := FakeInstalledSession.new()
	late_legacy_session.configure(replay_indexed)
	replay_lifecycle._active_replay = {"candidate":replay_indexed,
		"sectionKey":replay_key, "installSession":late_legacy_session}
	var empty_revision_map: Dictionary = {}
	empty_revision_map.make_read_only()
	var empty_census_map: Dictionary = {}
	empty_census_map.make_read_only()
	var dirty_replay_advance: Dictionary = replay_lifecycle.advance_replay(
		empty_revision_map, empty_census_map, {}, {})
	var dirty_advance_blocked: bool = dirty_replay_advance.get("status") == "deferred_dirty" \
		and late_legacy_session.cancelled and replay_lifecycle._active_replay.is_empty()
	replay_lifecycle.request_visible_section_demand(replay_key, 41, 1.0)
	var fresh_admission: Dictionary = replay_lifecycle.advance_visible_section_candidate_demands(1)
	await _await_native_compiles(replay_lifecycle)
	var fresh_candidate_job: Dictionary = replay_lifecycle._production_candidate_jobs.get(replay_key, {})
	var fresh_candidate: Dictionary = fresh_candidate_job.get("candidate", {})
	var replay_checks := {"initial_candidate_installed":replay_install.get("status") == "installed",
		"demand_withdrawn":replay_withdrawal.get("status") == "withdrawn",
		"invalidation_deferred_but_retained":replay_invalidation.get("status") == "deferred"
			and bool(replay_invalidation_row.get("dirtyRetained", false)),
		"dirty_source_identity_retained":replay_dirty.has("ecology:prop:replay"),
		"owner_unloaded":unload_count == 1,
		"stale_replay_not_queued":load_count == 0 and replay_request_blocked
			and no_stale_replay_job,
		"queued_and_active_legacy_replay_cancelled":no_legacy_replay_work,
		"late_active_legacy_replay_blocked_at_advance":dirty_advance_blocked,
		"fresh_demand_reassembles":fresh_admission.get("attemptCount") == 1
			and int(fresh_candidate.get("generation", 0)) > int(replay_indexed.get("generation", 0)),
		"dirty_marker_survives_until_receipt":replay_lifecycle._dirty_source_sections.has(replay_key)}
	check("withdrawn_source_invalidation_survives_unload_and_blocks_stale_replay",
		not replay_checks.values().has(false),
		{"checks":replay_checks, "withdrawal":replay_withdrawal,
			"invalidation":replay_invalidation, "dirtySources":replay_dirty,
			"unloadCount":unload_count, "loadReplayCount":load_count,
			"legacyReplayQueue":replay_lifecycle._replay_queue,
			"legacyReplaySetContainsSection":replay_lifecycle._replay_set.has(replay_key),
			"legacyActiveReplayEmpty":replay_lifecycle._active_replay.is_empty(),
			"legacyReplaySessionCancelled":legacy_active_session.cancelled,
			"dirtyReplayAdvance":dirty_replay_advance,
			"lateLegacyReplaySessionCancelled":late_legacy_session.cancelled,
			"freshAdmission":fresh_admission,
			"freshCandidateGeneration":fresh_candidate.get("generation"),
			"staleGeneration":replay_indexed.get("generation")})
	var unresolved_key := Vector3i(10, 1, 0)
	lifecycle.request_visible_section_demand(unresolved_key, 33, 9.0)
	lifecycle._pop_visible_section_demand()
	var unresolved_state: Dictionary = lifecycle._visible_section_demands[unresolved_key]
	unresolved_state["queued"] = false
	unresolved_state["stage"] = "candidate_queued"
	unresolved_state["candidateGeneration"] = 93
	lifecycle._visible_section_demands[unresolved_key] = unresolved_state
	lifecycle._reconcile_visible_section_candidate_outcome(unresolved_key, 93,
		{"status":"pending", "stage":"section_upload", "reason":"fixture_upload_pending",
			"retryable":true})
	var pending_install_state: Dictionary = lifecycle._visible_section_demands[unresolved_key].duplicate(true)
	lifecycle._reconcile_visible_section_candidate_outcome(unresolved_key, 93,
		{"status":"pending", "stage":"source_census", "reason":"fixture_census_stale",
			"retryable":true, "requiresReassembly":true})
	var stale_install_state: Dictionary = lifecycle._visible_section_demands[unresolved_key].duplicate(true)
	check("pending_install_session_is_retained_and_stale_census_requeues_reassembly",
		pending_install_state.get("stage") == "candidate_pending"
		and int(pending_install_state.get("candidateGeneration", 0)) == 93
		and stale_install_state.get("stage") == "waiting"
		and not stale_install_state.has("candidateGeneration")
		and stale_install_state.get("queued")
		and stale_install_state.get("lastInstallReason") == "fixture_census_stale",
		{"pending":pending_install_state, "stale":stale_install_state})
	var stale_queue_entry: Dictionary = lifecycle._pop_visible_section_demand()
	unresolved_state = lifecycle._visible_section_demands[unresolved_key]
	unresolved_state["queued"] = false
	unresolved_state["stage"] = "candidate_queued"
	unresolved_state["candidateGeneration"] = 94
	lifecycle._visible_section_demands[unresolved_key] = unresolved_state
	lifecycle._reconcile_visible_section_candidate_outcome(unresolved_key, 94,
		{"status":"failed", "reason":"fixture_nonretryable_install_failure"})
	var blocked_state: Dictionary = lifecycle._visible_section_demands[unresolved_key]
	check("nonretryable_install_failure_records_blocked_reason",
		stale_queue_entry.get("status") == "ready"
		and blocked_state.get("stage") == "blocked"
		and blocked_state.get("blockedReason") == "fixture_nonretryable_install_failure"
		and not blocked_state.has("candidateGeneration"), blocked_state)
	var retry_key := Vector3i(11, 0, 0)
	lifecycle.request_visible_section_demand(retry_key, 32, 4.0)
	var retry_demand: Dictionary = lifecycle._visible_section_demands[retry_key]
	lifecycle._pop_visible_section_demand()
	retry_demand["queued"] = false
	retry_demand["stage"] = "candidate_queued"
	retry_demand["candidateGeneration"] = 92
	lifecycle._visible_section_demands[retry_key] = retry_demand
	lifecycle._reconcile_visible_section_candidate_outcome(retry_key, 92,
		{"status":"failed", "reason":"fixture_transient_install_failure",
			"retryable":true})
	var retry_after_failure: Dictionary = lifecycle._visible_section_demands[retry_key].duplicate(true)
	var removed_for_wake: Dictionary = lifecycle.unregister_source_provider(
		"ecology", lifecycle_ecology)
	var restored_for_wake: Dictionary = lifecycle.register_source_provider(
		"ecology", lifecycle_ecology, "capture_static_section_sources")
	var recovered_admission: Dictionary = lifecycle.advance_visible_section_candidate_demands(1)
	await _await_native_compiles(lifecycle)
	check("retryable_failure_is_requeued_and_provider_wakeup_recovers_candidate",
		retry_after_failure.get("stage") == "waiting"
		and not retry_after_failure.has("candidateGeneration")
		and retry_after_failure.get("queued")
		and removed_for_wake.get("status") == "ready"
		and restored_for_wake.get("status") == "ready"
		and recovered_admission.get("attemptCount") == 1
		and recovered_admission.results[0].admission.get("status") == "queued"
		and lifecycle._visible_section_demands[retry_key].get("stage") == "candidate_queued",
		{"afterFailure":retry_after_failure, "removed":removed_for_wake,
			"restored":restored_for_wake, "recovered":recovered_admission})
	var output := {"schema":"visible-section-demand-driver-contract/v1",
		"passed":not checks.is_empty() \
			and checks.all(func(row: Dictionary) -> bool: return bool(row.passed)),
		"complete":not checks.is_empty() \
			and checks.all(func(row: Dictionary) -> bool: return bool(row.passed)),
		"checkCount":checks.size(),
		"focus":"ack_settlement" if ack_settlement_only else "full_contract",
		"evidenceLevel":"synthetic_provider_and_coordinator_contract_with_real_native_translucent_section_install_receipt",
		"checks":checks,
		"doesNotProve":"Main startup integration, production terrain/ecology geometry parity, live pixel ordering, gameplay traversal, or performance"}
	var report_path := OS.get_environment("VOXEL_VISIBLE_SECTION_DEMAND_REPORT")
	if report_path.is_empty():
		push_error("VOXEL_VISIBLE_SECTION_DEMAND_REPORT is required")
		quit(2)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write visible-section demand report: " + report_path)
		quit(2)
	file.store_string(JSON.stringify(output, "\t"))
	file.close()
	quit(0 if output.passed else 1)


func _run_install_owner_retirement_contract(world_id: String) -> void:
	# Synthetic lifecycle coverage: sessions record cancellation calls. Native
	# root retirement and rendered behavior require the separate renderer gates.
	var coordinator := Coordinator.new()
	coordinator.configure(world_id + ":install-retirement")
	var section_key := Vector3i.ZERO
	var first := RetirementInstallSession.new()
	coordinator._production_candidate_jobs[section_key] = {
		"session":first, "candidate":{"generation":1}}
	var first_result: Dictionary = coordinator.request_stream_chunk_owner_retirement(Vector2i.ZERO, 101)
	check("synthetic_first_install_is_cancelled_before_receipt_or_callback_exists",
		first_result.get("status") == "ready" and first.cancel_calls == 1
		and coordinator._production_candidate_jobs.is_empty()
		and coordinator._production_candidates_by_section.is_empty(), first_result)
	var retry := RetirementInstallSession.new()
	retry.fail_cancel = true
	coordinator._production_candidate_jobs[section_key] = {
		"session":retry, "candidate":{"generation":2}}
	var refused: Dictionary = coordinator.request_stream_chunk_owner_retirement(Vector2i.ZERO, 101)
	var wrong_owner: Dictionary = coordinator.request_stream_chunk_owner_retirement(Vector2i.ZERO, 202)
	check("synthetic_failed_install_cancellation_retains_exact_owner_and_ignores_other_incarnation",
		refused.get("status") == "rollback_failed" and bool(refused.get("ownerMustBeRetained", false))
		and wrong_owner.get("status") == "ready" and retry.cancel_calls == 1
		and coordinator._production_candidate_jobs[section_key].session == retry, refused)
	retry.fail_cancel = false
	var retried: Dictionary = coordinator.request_stream_chunk_owner_retirement(Vector2i.ZERO, 101)
	check("synthetic_failed_install_cancellation_can_retry_before_backend_destruction",
		retried.get("status") == "ready" and retry.cancel_calls == 2
		and coordinator._production_candidate_jobs.is_empty(), retried)
	var replay := RetirementInstallSession.new()
	var boundary := RetirementInstallSession.new()
	coordinator._committed_candidates[section_key] = {"sectionKey":section_key}
	coordinator._active_replay = {"sectionKey":section_key, "installSession":replay}
	coordinator._active_boundary = {"boundaryId":"synthetic-retirement",
		"phase":"installing", "installSession":boundary}
	var all_lanes: Dictionary = coordinator.request_stream_chunk_owner_retirement(Vector2i.ZERO, 101)
	check("synthetic_owner_retirement_cancels_staged_replay_and_boundary_without_losing_retry",
		all_lanes.get("status") == "ready" and replay.cancel_calls == 1
		and boundary.cancel_calls == 1 and coordinator._active_replay.is_empty()
		and coordinator._replay_queue.has(section_key)
		and coordinator._active_boundary.get("installSession") == null
		and coordinator._active_boundary.get("phase") == "installing", all_lanes)
	var failed_replay := RetirementInstallSession.new()
	var failed_boundary := RetirementInstallSession.new()
	failed_replay.fail_cancel = true
	failed_boundary.fail_cancel = true
	coordinator._active_replay = {"sectionKey":section_key, "installSession":failed_replay}
	coordinator._active_boundary["installSession"] = failed_boundary
	var other_refused: Dictionary = coordinator.request_stream_chunk_owner_retirement(Vector2i.ZERO, 101)
	var both_retained: bool = other_refused.get("status") == "rollback_failed" \
		and bool(other_refused.get("ownerMustBeRetained", false)) \
		and coordinator._active_replay.get("installSession") == failed_replay \
		and coordinator._active_boundary.get("installSession") == failed_boundary
	failed_replay.fail_cancel = false
	failed_boundary.fail_cancel = false
	var other_retried: Dictionary = coordinator.request_stream_chunk_owner_retirement(Vector2i.ZERO, 101)
	check("synthetic_replay_and_boundary_cancellation_failures_retain_owners_until_retry",
		both_retained and other_retried.get("status") == "ready"
		and failed_replay.cancel_calls == 2 and failed_boundary.cancel_calls == 2
		and coordinator._active_replay.is_empty()
		and coordinator._active_boundary.get("installSession") == null, other_retried)
	var global_production := RetirementInstallSession.new()
	var global_replay := RetirementInstallSession.new()
	var global_boundary := RetirementInstallSession.new()
	coordinator._production_candidate_jobs[section_key] = {
		"session":global_production, "candidate":{"generation":3}}
	coordinator._active_replay = {"sectionKey":section_key, "installSession":global_replay}
	coordinator._active_boundary["installSession"] = global_boundary
	var drained: Dictionary = await coordinator.drain_pending_frame_presentations()
	check("synthetic_global_drain_cancels_all_pre_presentation_install_lanes",
		bool(drained.get("drained", false)) and global_production.cancel_calls == 1
		and global_replay.cancel_calls == 1 and global_boundary.cancel_calls == 1
		and coordinator._production_candidate_jobs.is_empty()
		and coordinator._active_replay.is_empty() and coordinator._active_boundary.is_empty(), drained)


func _run_attachment_reassembly_contract(world_id: String) -> void:
	# Synthetic scheduler evidence only. A deliberately stale census separates
	# reassembly admission from native installation and player interaction.
	var section_key := Vector3i(97, 0, 0)
	var batch := {"attachmentKey":"synthetic-door-pivot"}
	batch.make_read_only()
	var batches := {"door":batch}
	batches.make_read_only()
	var snapshot := {"batches":batches}
	snapshot.make_read_only()
	var candidate := {"sectionKey":section_key, "snapshot":snapshot}
	candidate.make_read_only()
	var coordinator := Coordinator.new()
	coordinator.configure(world_id + ":attachment-replay")
	var empty_map := {}
	empty_map.make_read_only()
	coordinator.request_visible_section_demand(section_key, 1, 1.0)
	coordinator._committed_candidates[section_key] = candidate
	coordinator._queue_replay(section_key)
	var queued_result: Dictionary = coordinator.advance_replay(empty_map, empty_map, empty_map, empty_map, 1)
	check("synthetic_stale_attached_replay_retains_snapshot_and_requests_authoritative_reassembly",
		queued_result.get("status") == "pending"
		and bool(queued_result.get("requiresAuthoritativeReassembly", false))
		and bool(queued_result.get("reassemblyDemandQueued", false))
		and not String(queued_result.get("dependencyReason", "")).is_empty()
		and is_same(coordinator._committed_candidates.get(section_key), candidate)
		and coordinator._replay_queue.is_empty()
		and coordinator._visible_section_demands[section_key].get("stage") == "waiting",
		queued_result)
	coordinator._replay_reassembly_required_by_section.erase(section_key)
	coordinator._active_replay = {"candidate":candidate, "sectionKey":section_key,
		"installSession":null}
	var active_result: Dictionary = coordinator.advance_replay(empty_map, empty_map, empty_map, empty_map, 1)
	check("synthetic_stale_active_attachment_replay_cancels_before_reassembly",
		active_result.get("status") == "pending"
		and bool(active_result.get("requiresAuthoritativeReassembly", false))
		and coordinator._active_replay.is_empty()
		and coordinator._replay_reassembly_required_by_section.has(section_key), active_result)
	coordinator.withdraw_visible_section_demand(section_key)
	coordinator._replay_reassembly_required_by_section.erase(section_key)
	coordinator._queue_replay(section_key)
	var withdrawn_result: Dictionary = coordinator.advance_replay(empty_map, empty_map, empty_map, empty_map, 1)
	check("synthetic_undemanded_attachment_reassembly_retains_marker_without_inventing_demand",
		bool(withdrawn_result.get("requiresAuthoritativeReassembly", false))
		and not bool(withdrawn_result.get("reassemblyDemandQueued", true))
		and not coordinator._visible_section_demands.has(section_key)
		and coordinator._replay_reassembly_required_by_section.has(section_key), withdrawn_result)
	coordinator.reset_for_world(world_id + ":attachment-replay-finished")
	var empty_array: Array = []
	empty_array.make_read_only()
	var declaration := {"sourceId":"synthetic-door", "sourcePartId":"door",
		"sourceRevision":"r1", "ownerCell":Vector2i.ZERO,
		"sourceToWorld":Transform3D.IDENTITY, "segments":empty_array}
	declaration.make_read_only()
	var declarations: Array = [declaration]
	declarations.make_read_only()
	var opened: Dictionary = coordinator._ledger.begin_boundary(
		"synthetic-geometry-only", declarations, empty_array)
	coordinator.request_visible_section_demand(section_key, 1, 1.0)
	# Inject the geometry-only ledger output to isolate the pre-install guard.
	coordinator._active_boundary = {"boundaryId":"synthetic-geometry-only",
		"phase":"installing", "candidate":{"replacements":[candidate]},
		"installSession":null}
	var boundary_result: Dictionary = coordinator.advance_boundary(
		empty_map, empty_map, empty_map, empty_map, 1)
	check("synthetic_geometry_only_attachment_boundary_aborts_before_install_and_requests_recapture",
		opened.get("status") == "ready"
		and boundary_result.get("status") == "pending"
		and bool(boundary_result.get("requiresAuthoritativeReassembly", false))
		and coordinator._active_boundary.is_empty()
		and coordinator._ledger._pending.is_empty()
		and coordinator._production_candidate_jobs.is_empty()
		and coordinator._replay_reassembly_required_by_section.has(section_key), boundary_result)
	coordinator.withdraw_visible_section_demand(section_key)
	coordinator.reset_for_world(world_id + ":attachment-boundary-finished")


func check(name: String, passed: bool, evidence: Variant = {}) -> void:
	if ack_settlement_only and name != ACK_SETTLEMENT_CHECK_NAME:
		return
	checks.append({"name":name, "passed":passed, "evidence":evidence})
	if not passed:
		push_error("Visible section demand contract failed: " + name + " " + str(evidence))


func _run_native_stale_pov_replay_contract() -> Dictionary:
	if not ClassDB.class_exists("ChunkRenderPacketBackend"):
		return {"passed":false, "reason":"native_chunk_render_packet_backend_missing"}
	var prior_scene: Node = current_scene
	var fixture_scene := NativeSectionOwnerScene.new()
	fixture_scene.name = "VisibleSectionDemandNativeFixture"
	root.add_child(fixture_scene)
	current_scene = fixture_scene
	var section_key := Vector3i.ZERO
	var world_id := "seed:visible-section-native-stale-replay:1"
	var coordinator := Coordinator.new()
	coordinator.configure(world_id)
	coordinator.refresh_visible_section_demand_priorities(Vector3(1.0, 1.0, 1.0), 1)
	var provider := MutableCensusProvider.new()
	provider.configure(world_id, coordinator)
	var required: Array[String] = [provider.provider_id]
	required.make_read_only()
	coordinator.configure_source_roster(required)
	coordinator.register_source_provider(provider.provider_id, provider,
		"capture_static_section_sources")
	coordinator.request_visible_section_demand(section_key, 1, 0.0)
	var initial_admission: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	await _await_native_compiles(coordinator)
	var initial_candidate: Dictionary = coordinator._production_candidate_jobs.get(
		section_key, {}).get("candidate", {})
	var initial_generation := int(initial_candidate.get("generation", 0))
	var initial_install := await _drive_candidate_install(coordinator, section_key, 12)
	var initial_receipt: Dictionary = coordinator._production_candidate_receipts.get(
		section_key, {})
	var native_owner: Dictionary = PacketOwner.resolve_existing_static_section_backend(
		SectionGrid.chunk_key_for_section(section_key))
	var native_backend: Node = native_owner.get("backend") as Node
	var slot_id := InstallSession.slot_id(world_id, section_key)
	var installed_slot_before: Dictionary = native_backend.call("installed_snapshot", slot_id) \
		if is_instance_valid(native_backend) else {}
	var pre_replay_census: Dictionary = coordinator.capture_authoritative_source_census(
		[section_key])
	var queued_stale_candidate: Dictionary = coordinator.assemble_and_submit_complete_section_candidate(
		section_key, initial_generation + 1)
	await _await_native_compiles(coordinator)
	var stale_candidate_job: Dictionary = coordinator._production_candidate_jobs.get(
		section_key, {})
	var stale_production_candidate: Dictionary = stale_candidate_job.get("candidate", {})
	var stale_envelope: Dictionary = stale_production_candidate.get("candidate", {})
	coordinator._production_candidate_jobs.erase(section_key)
	coordinator._production_candidate_generation = initial_generation + 1
	coordinator._committed_candidates[section_key] = stale_envelope
	coordinator._installed_receipts[section_key] = initial_receipt
	coordinator._queue_replay(section_key)
	coordinator.refresh_visible_section_demand_priorities(Vector3(22.6, 2.0, 2.0), 1)
	var stale_replay_result: Dictionary = coordinator.advance_replay(
		pre_replay_census.get("sourceRevisions", {}),
		pre_replay_census.get("expectedContributorsBySection", {}),
		stale_production_candidate.get("materialBindings", {}),
		stale_production_candidate.get("meshBindings", {}), 8)
	var slot_after_stale_replay: Dictionary = native_backend.call("installed_snapshot", slot_id) \
		if is_instance_valid(native_backend) else {}
	var old_slot_backend_receipt_still_installed: bool = \
		is_instance_valid(native_backend) \
		and bool(native_backend.call("receipt_installed", slot_id,
			int(initial_receipt.get("generation", 0)),
			String(initial_receipt.get("sourceRevision", "")),
			String(initial_receipt.get("contentManifestDigest", ""))))
	var marked_for_reassembly: bool = coordinator._replay_reassembly_required_by_section.has(
		section_key)
	var fresh_admission: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	await _await_native_compiles(coordinator)
	var fresh_candidate: Dictionary = coordinator._production_candidate_jobs.get(
		section_key, {}).get("candidate", {})
	var fresh_pov_revision := coordinator._candidate_translucent_pov_revision(fresh_candidate)
	var slot_before_fresh_commit: Dictionary = native_backend.call("installed_snapshot", slot_id) \
		if is_instance_valid(native_backend) else {}
	var fresh_install := await _drive_candidate_install(coordinator, section_key, 12)
	var fresh_receipt: Dictionary = coordinator._production_candidate_receipts.get(
		section_key, {})
	var fresh_candidate_envelope: Dictionary = fresh_candidate.get("candidate", {})
	var fresh_committed_envelope: Dictionary = coordinator._committed_candidates.get(
		section_key, {})
	var fresh_legacy_receipt: Dictionary = coordinator._installed_receipts.get(
		section_key, {})
	var fresh_install_trace: Array = fresh_install.get("stepTrace", [])
	var staging_row_count := 0
	var staging_rows_keep_old_slot := true
	var installed_after_staging := false
	for trace_value: Variant in fresh_install_trace:
		if not trace_value is Dictionary:
			staging_rows_keep_old_slot = false
			continue
		var trace_row: Dictionary = trace_value
		var trace_status := String(trace_row.get("status", ""))
		if trace_status in ["pending", "pending_owner"]:
			staging_row_count += 1
			if installed_after_staging \
					or int(trace_row.get("installedSlotGeneration", -1)) != initial_generation:
				staging_rows_keep_old_slot = false
		elif trace_status == "installed":
			installed_after_staging = staging_row_count > 0 \
				and int(trace_row.get("installedSlotGeneration", -1)) \
					== int(fresh_candidate.get("generation", -2))
	var old_slot_retained_during_staging := staging_row_count > 0 \
		and staging_rows_keep_old_slot and installed_after_staging
	var final_slot: Dictionary = native_backend.call("installed_snapshot", slot_id) \
		if is_instance_valid(native_backend) else {}
	var passed: bool = initial_admission.get("attemptCount") == 1 \
		and initial_candidate.get("schema") == "world-static-section-production-candidate/v1" \
		and initial_admission.get("results", []).size() == 1 \
		and initial_admission.results[0].get("admission", {}).get("status") == "queued" \
		and initial_install.get("status") == "installed" \
		and int(initial_receipt.get("generation", 0)) == initial_generation \
		and installed_slot_before.get("status") == "ready" \
		and int(installed_slot_before.get("generation", 0)) == initial_generation \
		and queued_stale_candidate.get("status") == "queued" \
		and stale_replay_result.get("status") == "pending" \
		and stale_replay_result.get("stage") == "authoritative_reassembly" \
		and marked_for_reassembly \
		and int(slot_after_stale_replay.get("generation", 0)) == initial_generation \
		and old_slot_backend_receipt_still_installed \
		and fresh_admission.get("attemptCount") == 1 \
		and int(fresh_candidate.get("generation", 0)) > int(stale_envelope.get("generation", 0)) \
		and fresh_pov_revision == 15 \
		and int(slot_before_fresh_commit.get("generation", 0)) == initial_generation \
		and fresh_install.get("status") == "installed" \
		and old_slot_retained_during_staging \
		and int(fresh_receipt.get("generation", 0)) == int(fresh_candidate.get("generation", -1)) \
		and int(fresh_receipt.get("translucentPovRevision", -1)) == 15 \
		and fresh_committed_envelope == fresh_candidate_envelope \
		and int(fresh_committed_envelope.get("generation", -1)) \
			== int(fresh_receipt.get("generation", -2)) \
		and fresh_legacy_receipt == fresh_receipt \
		and int(final_slot.get("generation", 0)) == int(fresh_receipt.get("generation", -1)) \
		and not coordinator._replay_reassembly_required_by_section.has(section_key) \
		and coordinator.installed_section_receipt_is_current(section_key, fresh_receipt)
	var evidence := {"nativeBackend":ClassDB.class_exists("ChunkRenderPacketBackend"),
		"initialAdmission":initial_admission, "initialInstall":initial_install,
		"initialGeneration":initial_generation, "initialReceipt":initial_receipt,
		"initialInstalledSlot":installed_slot_before,
		"staleCandidateAdmission":queued_stale_candidate,
		"staleReplay":stale_replay_result,
		"slotAfterStaleReplay":slot_after_stale_replay,
		"oldSlotBackendReceiptStillInstalled":old_slot_backend_receipt_still_installed,
		"reassemblyMarkerRetained":marked_for_reassembly,
		"freshAdmission":fresh_admission,
		"freshGeneration":fresh_candidate.get("generation"),
		"freshPovRevision":fresh_pov_revision,
		"slotBeforeFreshCommit":slot_before_fresh_commit,
		"freshInstall":fresh_install, "freshInstallTrace":fresh_install_trace,
		"stagingRowCount":staging_row_count,
		"oldSlotRetainedDuringStaging":old_slot_retained_during_staging,
		"freshReceipt":fresh_receipt,
		"freshCandidateEnvelopeGeneration":fresh_candidate_envelope.get("generation", -1),
		"freshCommittedEnvelopeGeneration":fresh_committed_envelope.get("generation", -1),
		"freshLegacyReceipt":fresh_legacy_receipt,
		"finalSlot":final_slot, "freshReceiptCurrent":coordinator.installed_section_receipt_is_current(
			section_key, fresh_receipt)}
	# Admitted immutable output enters the real Session/backend. Mutations here
	# deliberately omit coordinator invalidation to prove final census catches
	# changes even when no cheap producer cancellation notification was delivered.
	var mutation_rows: Array[Dictionary] = []
	for target_state: String in ["append", "upload", "commit", "awaiting_frame"]:
		provider.mutation = 0
		var next_generation := int(fresh_receipt.get("generation", 0)) + mutation_rows.size() + 1
		var admitted: Dictionary = coordinator.assemble_and_submit_complete_section_candidate(section_key, next_generation)
		await _await_native_compiles(coordinator)
		var target_reached := false
		for turn in range(16):
			var mutation_job: Dictionary = coordinator._production_candidate_jobs.get(section_key, {})
			var active: Variant = mutation_job.get("session")
			if is_instance_valid(active) and String(active.get("state")) == target_state:
				target_reached = true
				break
			coordinator.advance_complete_section_candidate(section_key, 1)
			await process_frame
		provider.mutation = 1
		var mutation_result: Dictionary = {}
		var hidden_checks_skipped := true
		for turn in range(16):
			var mutation_job: Dictionary = coordinator._production_candidate_jobs.get(section_key, {})
			if mutation_job.is_empty(): break
			var active: Variant = mutation_job.get("session")
			var before_state := String(active.get("state")) if is_instance_valid(active) else ""
			var before_calls := provider.census_calls
			mutation_result = coordinator.advance_complete_section_candidate(section_key, 1)
			if before_state in ["append", "upload"]:
				hidden_checks_skipped = hidden_checks_skipped and provider.census_calls == before_calls
			await process_frame
		var old_retained: bool = native_backend.call("receipt_installed", slot_id,
			int(fresh_receipt.generation), String(fresh_receipt.sourceRevision), String(fresh_receipt.contentManifestDigest))
		var stale_rejected: bool = target_reached and admitted.get("status") == "queued" \
			and mutation_result.get("requiresReassembly", false) and old_retained \
			and hidden_checks_skipped and not coordinator._production_candidate_jobs.has(section_key)
		var row := {"stage":target_state, "passed":stale_rejected, "result":mutation_result,
			"targetReached":target_reached, "oldPacketRetained":old_retained,
			"hiddenCensusSkipped":hidden_checks_skipped}
		mutation_rows.append(row)
		check("native_census_boundary_rejects_mutation_" + target_state, stale_rejected, row)
		passed = passed and stale_rejected
	provider.mutation = 0
	evidence["sourceMutationBoundaryMatrix"] = mutation_rows
	root.remove_child(fixture_scene)
	fixture_scene.free()
	current_scene = prior_scene
	evidence["passed"] = passed
	evidence["scope"] = "synthetic provider and coordinator; real native section install session/backend receipt"
	evidence["doesNotProve"] = "Main startup readiness, live camera pixels, visual ordering, or gameplay traversal"
	return evidence


## Synthetic fixture boundary: wait for actual native compilation, without
## advancing installation before the existing staged-session assertions.
func _await_native_compiles(coordinator: Object) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while not coordinator._section_compile_jobs.is_empty() and Time.get_ticks_msec() < deadline:
		coordinator._advance_section_compiles(8)
		await process_frame
	check("native_compile_jobs_reach_terminal_acceptance",
		coordinator._section_compile_jobs.is_empty(),
		{"pendingSections":coordinator._section_compile_jobs.keys()})


func _drive_candidate_install(coordinator: Object, section_key: Vector3i,
		max_steps: int) -> Dictionary:
	var trace: Array[Dictionary] = []
	var last: Dictionary = {"status":"pending", "reason":"fixture_install_not_started"}
	for step_index in range(max_steps):
		await process_frame
		var candidate: Dictionary = coordinator._production_candidate_jobs.get(
			section_key, {}).get("candidate", {})
		last = coordinator.advance_complete_section_candidate(section_key, 8)
		var installed_slot_generation := -1
		var owner_cell := SectionGrid.chunk_key_for_section(section_key)
		var scene := Engine.get_main_loop() as SceneTree
		if scene != null and scene.current_scene != null \
				and scene.current_scene.has_method("get_static_section_render_owner"):
			var owner_result: Dictionary = scene.current_scene.call(
				"get_static_section_render_owner", owner_cell, false)
			var backend: Node = owner_result.get("backend") as Node
			if is_instance_valid(backend) and not candidate.is_empty():
				var source_id := InstallSession.slot_id(
					String(candidate.get("worldId", "")), section_key)
				var slot: Dictionary = backend.call("installed_snapshot", source_id)
				installed_slot_generation = int(slot.get("generation", -1)) \
					if slot.get("status") == "ready" else 0
				if last.get("stage") == "awaiting_frame":
					var pending: Dictionary = backend.call("pending_presentation_snapshot", source_id)
					var previous: Dictionary = pending.get("previousReceipt", {})
					# During the candidate's first frame the old slot is retained for
					# rollback; it is intentionally no longer the active snapshot.
					if previous.get("status") == "retained_previous" \
							and bool(backend.call("receipt_installed", source_id,
								int(previous.get("generation", 0)),
								String(previous.get("sourceRevision", "")),
								String(previous.get("packetDigest", "")))):
						installed_slot_generation = int(previous.get("generation", 0))
		trace.append({"step":step_index, "status":String(last.get("status", "")),
			"stage":String(last.get("stage", "")),
			"installedSlotGeneration":installed_slot_generation,
			"reason":String(last.get("reason", ""))})
		if last.get("status") == "installed":
			last["stepTrace"] = trace
			return last
		if last.get("status") not in ["pending", "pending_owner"]:
			last["stepTrace"] = trace
			return last
	last["stepTrace"] = trace
	last["reason"] = "fixture_install_step_budget_exhausted:" + str(last.get("reason", ""))
	return last

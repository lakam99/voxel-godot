extends SceneTree

const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const PacketOwner := preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstallSession := preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const CitadelService := preload("res://scripts/world/CitadelPublicationService.gd")
const REPORT_ENV := "VOXEL_CITADEL_SECTION_RECEIPT_RETIREMENT_REPORT"
const SEED := "citadel-section-receipt"
const SECTION := Vector3i.ZERO
const SITE_ID := "fixture-site"
const MEMBER_ID := "building:fixture-part"
const PROVIDER_ID := "blueprint_buildings"
const EMPTY_SERVICE_SEED := "citadel-empty-service-receipt"
const TOMBSTONE_SERVICE_SEED := "citadel-omission-tombstone-receipt"
const TOMBSTONE_PART_ID := "omitted-static-part"
const TOMBSTONE_INSTALL_FRAME_BUDGET := 1200
const TOMBSTONE_INSTALL_TRANSITION_SAMPLE_LIMIT := 32
const TOMBSTONE_INSTALL_TAIL_SAMPLE_LIMIT := 32

var report_path := ""
var checks: Dictionary = {}
var coordinator
var world_id := ""
var mesh: ArrayMesh
var material: StandardMaterial3D
var compatibility: Dictionary
var batch_key := ""


class CensusProvider extends RefCounted:
	var world_id := ""
	var mesh: Mesh
	var material: Material
	var compatibility: Dictionary
	var batch_key := ""

	func capture_static_section_sources(request_world_id: String,
			sections: Array) -> Dictionary:
		if request_world_id != world_id or sections != [SECTION]:
			return {"status":"failed", "reason":"unexpected_native_fixture_query"}
		var source_ids: Array[String] = ["fixture-blueprint-contributor"]
		source_ids.make_read_only()
		var row := {"status":"complete", "coverageRevision":"citadel-coverage-r1",
			"sourcePartIds":source_ids}
		row.make_read_only()
		var revisions := {"fixture-blueprint-contributor":"fixture-blueprint-source-r1"}
		revisions.make_read_only()
		var section_map := {SECTION:row}
		section_map.make_read_only()
		var result := {"status":"complete", "worldId":world_id,
			"authorityRevision":"citadel-authority-r1", "sourceRevisions":revisions,
			"sections":section_map}
		result.make_read_only()
		return result

	func capture_static_section_contribution(census: Dictionary,
			section_key: Vector3i) -> Dictionary:
		var source_id := "fixture-blueprint-contributor"
		var source_identity_key := "section-part:" + var_to_bytes(
			[source_id, source_id]).hex_encode()
		if census.get("status") != "complete" or section_key != SECTION \
				or not census.get("sourceRevisions", {}).has(source_identity_key):
			return {"status":"pending", "reason":"fixture_contribution_census_stale",
				"retryable":true}
		var values: Array[float] = []
		for value: float in Attributes.encode(Transform3D.IDENTITY, Color.WHITE):
			values.append(value)
		values.make_read_only()
		var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
			"sourceId":source_id, "sourcePartId":source_id,
			"sourceRevision":"fixture-blueprint-source-r1",
			"ownerCell":Grid.logical_owner_cell_for_world_position(Vector3(5, 5, 5)),
			"sourceToWorld":Transform3D(Basis.IDENTITY, Vector3(5, 5, 5)),
			"meshLocalBounds":mesh.get_aabb(), "batchKey":batch_key,
			"segmentId":"fixture-blueprint-segment", "buffer":values,
			"instanceCount":1}
		input.make_read_only()
		var inputs: Array[Dictionary] = [input]
		inputs.make_read_only()
		var revisions := {source_identity_key:"fixture-blueprint-source-r1"}
		revisions.make_read_only()
		var compatibility_map := {batch_key:compatibility}
		compatibility_map.make_read_only()
		var materials := {"fixture-material":material}
		materials.make_read_only()
		var meshes := {"fixture-mesh":mesh}
		meshes.make_read_only()
		var resource_binding := {"material":material, "mesh":mesh}
		resource_binding.make_read_only()
		var resources := {batch_key:resource_binding}
		resources.make_read_only()
		var contribution := {"providerId":PROVIDER_ID,
			"sectionKey":section_key, "coverageRevision":"citadel-coverage-r1",
			"authorityRevision":"citadel-authority-r1",
			"authoritySourceRevisions":revisions, "inputs":inputs,
			"compatibilityByKey":compatibility_map,
			"materialBindings":materials, "meshBindings":meshes,
			"resourceBindings":resources}
		contribution.make_read_only()
		return {"status":"ready", "contribution":contribution}


class WorldRoot extends Node3D:
	var chunk_owner: Node3D
	var backend: Node3D
	var additional_owners: Dictionary = {}
	func get_static_section_render_owner(owner_cell: Vector2i,
			_create_if_missing: bool) -> Dictionary:
		if owner_cell == Vector2i.ZERO:
			if not is_instance_valid(chunk_owner) or not is_instance_valid(backend):
				return {"status":"pending", "reason":"fixture_section_owner_unavailable"}
			return {"status":"ready", "owner":chunk_owner, "backend":backend}
		var existing: Dictionary = additional_owners.get(owner_cell, {})
		if not existing.is_empty() and is_instance_valid(existing.get("owner")) \
				and is_instance_valid(existing.get("backend")):
			return {"status":"ready", "owner":existing.owner, "backend":existing.backend}
		if not _create_if_missing:
			return {"status":"pending", "reason":"fixture_section_owner_unavailable"}
		var chunk := Node3D.new()
		chunk.name = "Chunk_%d_%d" % [owner_cell.x, owner_cell.y]
		add_child(chunk)
		var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
		var packet_backend := attached.get("backend") as Node3D
		if attached.get("status") != "ready" or not is_instance_valid(packet_backend):
			chunk.queue_free()
			return {"status":"pending", "reason":"fixture_section_owner_attach_failed",
				"detail":attached}
		additional_owners[owner_cell] = {"owner":chunk, "backend":packet_backend}
		return {"status":"ready", "owner":chunk, "backend":packet_backend}


class EmptyCitadelAdmission extends RefCounted:
	var world_seed := EMPTY_SERVICE_SEED
	var generation := 1
	func stats() -> Dictionary:
		return {"worldSeed":world_seed, "generation":generation}
	func request_bounds(_bounds: Rect2i) -> Dictionary:
		return {"status":"ready"}
	func source_state(_region: Vector2i) -> Dictionary:
		return {"status":"absent"}


class TombstoneAdmission extends RefCounted:
	var world_seed := TOMBSTONE_SERVICE_SEED
	var generation := 1
	var source_binding: Dictionary = {"siteId":SITE_ID,
		"sourceKey":"fixture-current-plan", "generation":1}
	var reservation_cells := Rect2i(-64, -64, 128, 128)
	func stats() -> Dictionary:
		return {"worldSeed":world_seed, "generation":generation}
	func request_bounds(_bounds: Rect2i) -> Dictionary:
		return {"status":"ready"}
	func source_state(region: Vector2i) -> Dictionary:
		if region != Vector2i.ZERO:
			return {"status":"absent"}
		return {"status":"ready", "binding":source_binding,
			"reservationCells":reservation_cells}


class TombstonePlan extends RefCounted:
	var source_binding: Dictionary
	var groups: Array = []
	var member_records: Array[Dictionary] = []
	var output_signature := "fixture-current-empty-plan-r1"
	func matches(binding: Dictionary, candidate_groups: Array) -> bool:
		return binding == source_binding and candidate_groups == groups
	func visual_members_intersecting_bounds(_bounds: AABB) -> Dictionary:
		var members: Array[Dictionary] = []
		members.make_read_only()
		var result := {"status":"described", "members":members}
		result.make_read_only()
		return result


class BuildingVisualOwner extends Node3D:
	var published_nodes: Array = []
	var publication_site_id := SITE_ID
	var _physical_packet_bindings_by_part_id: Dictionary = {}
	func has_pending_chunk_static_packet_retirement() -> bool:
		return false
	func committed_static_visual_source_identity(part_id: String) -> Dictionary:
		for visual_value: Variant in published_nodes:
			var visual := visual_value as GeometryInstance3D
			if is_instance_valid(visual) and String(visual.get_meta(
					"building_source_part_id", "")) == part_id:
				return {"status":"ready", "sourceRevision":"fixture-source:" + part_id}
		return {"status":"absent", "reason":"fixture_source_visual_missing"}


class RetiringSceneJob extends RefCounted:
	var _building: BuildingVisualOwner
	var _furniture = null
	var _binding: Dictionary = {}
	var _root: Node3D
	var _door_claims: Dictionary = {}
	var _tree_retirement_claims: Dictionary = {}
	var _registered_tree_ids: Dictionary = {}
	func own_node_root() -> Node3D:
		return _root if is_instance_valid(_root) else null
	func cancel() -> void:
		pass
	func status_count() -> Dictionary:
		return {"phase":"teardown"}


class ReceiptService extends CitadelService:
	var fixture_world_id := ""
	var fixture_census: Dictionary = {}
	var fixture_publisher: BuildingVisualOwner
	func capture_static_section_sources(request_world_id: String,
			section_keys: Array) -> Dictionary:
		if request_world_id != fixture_world_id or section_keys != [SECTION]:
			return {"status":"pending", "reason":"fixture_census_not_current", "retryable":true}
		return fixture_census
	func _current_packet_publisher_for_site(_site_id: String) -> Dictionary:
		return {"status":"ready", "publisher":fixture_publisher}


class AckTraceService extends CitadelService:
	var fixture_scene_inventory_call_count := 0
	var fixture_retiree_inventory_call_count := 0
	var fixture_last_scene_inventory: Dictionary = {}
	var fixture_last_retiree_inventory: Dictionary = {}
	var fixture_last_ack_path_trace: Dictionary = {}

	func _validate_visible_citadel_scene_visual_inventory(section_key: Vector3i,
			section_source_ids: Dictionary, removal_revisions: Dictionary = {},
			removal_records_by_id: Dictionary = {}) -> Dictionary:
		fixture_scene_inventory_call_count += 1
		var result: Dictionary = super._validate_visible_citadel_scene_visual_inventory(
			section_key, section_source_ids, removal_revisions, removal_records_by_id)
		fixture_last_scene_inventory = {"sectionKey":section_key,
			"status":String(result.get("status", "")),
			"reason":String(result.get("reason", "")),
			"waitingVisualCount":int(result.get("waitingVisualCount", 0)),
			"retiringSceneCount":_retiring_scenes.size()}
		fixture_last_scene_inventory.make_read_only()
		return result

	func _retiring_citadel_inventory_disjoint_from_section(retiring_entry: Dictionary,
			retiring_source: Dictionary, retiring_binding: Dictionary,
			section_key: Vector3i) -> Dictionary:
		fixture_retiree_inventory_call_count += 1
		var result: Dictionary = super._retiring_citadel_inventory_disjoint_from_section(
			retiring_entry, retiring_source, retiring_binding, section_key)
		fixture_last_retiree_inventory = {"sectionKey":section_key,
			"status":String(result.get("status", "")),
			"reason":String(result.get("reason", "")),
			"disjoint":bool(result.get("disjoint", false)),
			"visualCount":int(result.get("visualCount", 0)),
			"retiringSceneCount":_retiring_scenes.size()}
		fixture_last_retiree_inventory.make_read_only()
		return result

	func acknowledge_section_install(section_key: Vector3i,
			coverage_revision: String, receipt: Dictionary = {}) -> Dictionary:
		fixture_scene_inventory_call_count = 0
		fixture_retiree_inventory_call_count = 0
		fixture_last_scene_inventory = {}
		fixture_last_retiree_inventory = {}
		var count_before := _retiring_scenes.size()
		var result: Dictionary = super.acknowledge_section_install(
			section_key, coverage_revision, receipt)
		fixture_last_ack_path_trace = {"sectionKey":section_key,
			"status":String(result.get("status", "")),
			"reason":String(result.get("reason", "")),
			"sceneInventoryCallCount":fixture_scene_inventory_call_count,
			"sceneInventory":fixture_last_scene_inventory,
			"retireeInventoryCallCount":fixture_retiree_inventory_call_count,
			"retireeInventory":fixture_last_retiree_inventory,
			"retiringSceneCountBeforeAck":count_before,
			"retiringSceneCountAfterAck":_retiring_scenes.size()}
		fixture_last_ack_path_trace.make_read_only()
		return result


class TombstoneService extends AckTraceService:
	var fixture_plan: TombstonePlan
	func _publication_plan_for_binding(binding: Dictionary):
		if fixture_plan == null or not fixture_plan.matches(binding, fixture_plan.groups):
			return null
		return fixture_plan


func _initialize() -> void:
	report_path = OS.get_environment(REPORT_ENV)
	call_deferred("_run")


func _run() -> void:
	_build_batch()
	var world := WorldRoot.new()
	world.name = "CitadelSectionReceiptWorld"
	root.add_child(world)
	current_scene = world
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	world.add_child(chunk)
	var backend_result: Dictionary = PacketOwner.attach_to_chunk(chunk)
	world.chunk_owner = chunk
	world.backend = backend_result.get("backend") as Node3D
	_check("native_chunk_backend_attached", backend_result.get("status") == "ready"
		and is_instance_valid(world.backend), backend_result)
	if not checks["native_chunk_backend_attached"].passed:
		_finish()
		return

	coordinator = Coordinator.new()
	world_id = "seed:%s:%d" % [SEED, CitadelService._seed_hash(SEED)]
	coordinator.configure(world_id)
	var domains: Array[String] = [PROVIDER_ID]
	coordinator.configure_source_roster(domains)
	var provider := CensusProvider.new()
	provider.world_id = world_id
	provider.mesh = mesh
	provider.material = material
	provider.compatibility = compatibility
	provider.batch_key = batch_key
	coordinator.register_source_provider(PROVIDER_ID, provider,
		"capture_static_section_sources")
	var admitted: Dictionary = await _admit_compiled_candidate(coordinator,
		SECTION, 1)
	var installed: Dictionary = {"status":"not_started"}
	for frame_index in range(1200):
		var step: Dictionary = coordinator.advance_queued_complete_section_candidates(1, 8)
		var results: Array = step.get("results", [])
		installed = results[0] if not results.is_empty() else {"status":"idle"}
		if installed.get("status") in ["installed", "failed", "cancelled"]:
			break
		await process_frame
	var receipt: Dictionary = coordinator._production_candidate_receipts.get(SECTION, {})
	_check("whole_section_candidate_installed_by_native_renderer",
		admitted.get("status") == "queued" and installed.get("status") == "installed"
		and receipt.get("status") == "installed"
		and bool(world.backend.call("receipt_installed",
			InstallSession.slot_id(world_id, SECTION),
			1, "%s:%d" % [world_id, 1], String(receipt.get("contentManifestDigest", "")))),
		{"admission":admitted, "install":installed, "receipt":receipt})
	if not checks["whole_section_candidate_installed_by_native_renderer"].passed:
		_finish()
		return

	var service := ReceiptService.new()
	service.set("_seed", SEED)
	service.set("_admission", RefCounted.new())
	service.fixture_world_id = world_id
	service.fixture_publisher = BuildingVisualOwner.new()
	world.add_child(service.fixture_publisher)
	var legacy_visual := MeshInstance3D.new()
	legacy_visual.mesh = BoxMesh.new()
	legacy_visual.position = Vector3(5, 5, 5)
	legacy_visual.set_meta("building_source_part_id", "fixture-part")
	legacy_visual.set_meta("building_source_blueprint", "fixture-blueprint")
	service.fixture_publisher.add_child(legacy_visual)
	service.fixture_publisher.published_nodes.append(legacy_visual)
	var unrelated_visual := MeshInstance3D.new()
	unrelated_visual.mesh = BoxMesh.new()
	unrelated_visual.position = Vector3(32, 5, 5)
	unrelated_visual.set_meta("building_source_part_id", "other-part")
	service.fixture_publisher.add_child(unrelated_visual)
	service.fixture_publisher.published_nodes.append(unrelated_visual)
	var unidentified_visual := MeshInstance3D.new()
	unidentified_visual.mesh = BoxMesh.new()
	unidentified_visual.position = Vector3(7, 5, 5)
	service.fixture_publisher.add_child(unidentified_visual)
	service.fixture_publisher.published_nodes.append(unidentified_visual)
	var unrostered_visual := MeshInstance3D.new()
	unrostered_visual.mesh = BoxMesh.new()
	unrostered_visual.position = Vector3(8, 5, 5)
	unrostered_visual.set_meta("building_source_part_id", "not-in-census")
	service.fixture_publisher.add_child(unrostered_visual)
	service.fixture_publisher.published_nodes.append(unrostered_visual)
	service.fixture_census = _citadel_fixture_census()

	var stale_ack: Dictionary = _ack_after_inventory_progress(service, SECTION,
		"wrong-coverage", receipt)
	_check("stale_coverage_keeps_legacy_visual_visible",
		stale_ack.get("status") == "pending" and legacy_visual.visible,
		{"ack":stale_ack, "visible":legacy_visual.visible})
	service.fixture_census = _citadel_fixture_census("citadel-member-r2",
		"citadel-coverage-r2")
	var stale_source_ack: Dictionary = _ack_after_inventory_progress(service, SECTION,
		"citadel-coverage-r1", receipt)
	_check("changed_source_and_coverage_keep_legacy_visual_visible",
		stale_source_ack.get("status") == "pending" and legacy_visual.visible,
		{"ack":stale_source_ack, "visible":legacy_visual.visible,
			"oldSourceRevision":"citadel-member-r1",
			"currentSourceRevision":"citadel-member-r2"})
	service.fixture_census = _citadel_fixture_census()
	var pending_inventory_ack: Dictionary = _ack_after_inventory_progress(service, SECTION,
		"citadel-coverage-r1", receipt)
	var unknown_identity_reported: bool = false
	for result_value: Variant in pending_inventory_ack.get("visualResults", []):
		if result_value is Dictionary and String(result_value.get("reason", "")) \
				== "citadel_visible_visual_source_identity_unavailable":
			unknown_identity_reported = true
	_check("unidentified_intersecting_visual_keeps_section_ack_pending_atomically",
		pending_inventory_ack.get("status") == "pending"
		and String(pending_inventory_ack.get("reason", "")) == "citadel_visual_inventory_unresolved"
		and legacy_visual.visible and unidentified_visual.visible
		and unrostered_visual.visible and unknown_identity_reported,
		{"ack":pending_inventory_ack, "knownVisible":legacy_visual.visible,
			"unknownVisible":unidentified_visual.visible,
			"unrosteredVisible":unrostered_visual.visible,
			"unknownIdentityReported":unknown_identity_reported})
	service.fixture_publisher.published_nodes.erase(unidentified_visual)
	unidentified_visual.queue_free()
	var unrostered_ack: Dictionary = _ack_after_inventory_progress(service, SECTION,
		"citadel-coverage-r1", receipt)
	var unrostered_identity_reported: bool = false
	for result_value: Variant in unrostered_ack.get("visualResults", []):
		if result_value is Dictionary and String(result_value.get("reason", "")) \
				== "citadel_visible_visual_source_not_in_current_census":
			unrostered_identity_reported = true
	_check("same_section_visual_identity_missing_from_census_keeps_all_old_visuals_visible",
		unrostered_ack.get("status") == "pending" and legacy_visual.visible
		and unrostered_visual.visible and unidentified_visual.visible
		and unrostered_identity_reported,
		{"ack":unrostered_ack, "knownVisible":legacy_visual.visible,
			"unrosteredVisible":unrostered_visual.visible,
			"unidentifiedVisible":unidentified_visual.visible,
			"unrosteredIdentityReported":unrostered_identity_reported})
	service.fixture_publisher.published_nodes.erase(unrostered_visual)
	unrostered_visual.queue_free()
	await process_frame
	var valid_ack: Dictionary = _ack_after_inventory_progress(service, SECTION,
		"citadel-coverage-r1", receipt)
	_check("current_native_receipt_retires_only_matching_visual_after_inventory_is_known",
		valid_ack.get("status") == "acknowledged" and not legacy_visual.visible
		and unrelated_visual.visible
		and bool(legacy_visual.get_meta("citadel_section_owned", false)),
		{"ack":valid_ack, "legacyVisible":legacy_visual.visible,
			"unrelatedVisible":unrelated_visual.visible,
			"visualLocalAabb":legacy_visual.get_aabb(),
			"visualWorldBounds":legacy_visual.global_transform * legacy_visual.get_aabb(),
			"visualSections":Grid.keys_intersecting_bounds(
				legacy_visual.global_transform * legacy_visual.get_aabb())})
	_check("visual_only_retirement_keeps_source_node_owned_by_publisher",
		is_instance_valid(service.fixture_publisher)
		and service.fixture_publisher.published_nodes.has(legacy_visual)
		and legacy_visual.get_parent() == service.fixture_publisher,
		{"publisherInstanceId":service.fixture_publisher.get_instance_id(),
			"legacyParentMatches":legacy_visual.get_parent() == service.fixture_publisher})
	await _verify_actual_service_empty_receipt_path(world, service, legacy_visual)
	await _verify_live_plan_omission_tombstone(world)
	await _verify_retiring_scene_reservation_liveness(world)
	_finish()


func _verify_actual_service_empty_receipt_path(world: WorldRoot,
		fixture_service: ReceiptService, legacy_visual: GeometryInstance3D) -> void:
	var actual_service := AckTraceService.new()
	var admission := EmptyCitadelAdmission.new()
	actual_service.configure(admission)
	var actual_world_id := "seed:%s:%d" % [EMPTY_SERVICE_SEED,
		CitadelService._seed_hash(EMPTY_SERVICE_SEED)]
	var actual_coordinator = Coordinator.new()
	var coordinator_binding: Dictionary = actual_coordinator.configure(actual_world_id)
	var source_ids: Array[String] = [PROVIDER_ID]
	source_ids.make_read_only()
	var roster_binding: Dictionary = actual_coordinator.configure_source_roster(source_ids)
	var provider_registration: Dictionary = actual_coordinator.register_source_provider(
		PROVIDER_ID, actual_service, "capture_static_section_sources")
	_check("actual_citadel_service_registered_in_live_coordinator_roster",
		coordinator_binding.get("status") == "ready"
		and roster_binding.get("status") == "ready"
		and provider_registration.get("status") == "ready",
		{"coordinator":coordinator_binding, "roster":roster_binding,
			"provider":provider_registration})
	var admitted: Dictionary = await _admit_compiled_candidate(actual_coordinator,
		SECTION, 1)
	var installed: Dictionary = {"status":"not_started"}
	for frame_index in range(1200):
		var step: Dictionary = actual_coordinator.advance_queued_complete_section_candidates(1, 8)
		var results: Array = step.get("results", [])
		installed = results[0] if not results.is_empty() else {"status":"idle"}
		if installed.get("status") in ["installed", "failed", "cancelled"]:
			break
		await process_frame
	var receipt: Dictionary = actual_coordinator._production_candidate_receipts.get(SECTION, {})
	var candidate: Dictionary = actual_coordinator._production_candidates_by_section.get(SECTION, {})
	_check("actual_citadel_empty_source_passes_roster_assembler_and_native_install",
		admitted.get("status") == "queued" and installed.get("status") == "installed"
		and candidate.get("providerCoverage", []).size() == 1
		and bool(world.backend.call("receipt_installed",
			InstallSession.slot_id(actual_world_id, SECTION),
			1, "%s:%d" % [actual_world_id, 1],
			String(receipt.get("contentManifestDigest", "")))),
		{"admission":admitted, "install":installed, "receipt":receipt,
			"evidenceScope":"actual CitadelPublicationService empty-section census/contribution, live roster and assembler, actual native section receipt"})
	if installed.get("status") != "installed":
		return
	var stale_coverage: Dictionary = _ack_after_inventory_progress(actual_service,
		SECTION, "stale-coverage", receipt)
	var current_coverage := String(candidate.get("providerCoverage", [])[0][1])
	var retiring_owner := BuildingVisualOwner.new()
	world.add_child(retiring_owner)
	var retiring_visual := MeshInstance3D.new()
	retiring_visual.mesh = BoxMesh.new()
	retiring_visual.position = Vector3(5, 5, 5)
	retiring_visual.set_meta("building_source_part_id", "removed-from-current-plan")
	retiring_owner.add_child(retiring_visual)
	retiring_owner.published_nodes.append(retiring_visual)
	var retiring_job := RetiringSceneJob.new()
	retiring_job._building = retiring_owner
	var retiring_entry := {"region":Vector2i.ZERO,
		"binding":{"siteId":SITE_ID}, "job":retiring_job}
	actual_service._scenes[Vector2i.ZERO] = retiring_entry
	var empty_with_retained_visual: Dictionary = _ack_after_inventory_progress(actual_service,
		SECTION, current_coverage, receipt)
	var removal_reason_reported: bool = false
	for result_value: Variant in empty_with_retained_visual.get("visualResults", []):
		if result_value is Dictionary and String(result_value.get("reason", "")) \
				== "citadel_visible_visual_source_not_in_current_census":
			removal_reason_reported = true
	_check("empty_current_receipt_waits_for_retained_scene_removal_proof",
		empty_with_retained_visual.get("status") == "pending"
		and String(empty_with_retained_visual.get("reason", "")) \
			== "citadel_scene_visual_inventory_unresolved"
		and retiring_visual.visible and removal_reason_reported,
		{"ack":empty_with_retained_visual,
			"retiringVisualVisible":retiring_visual.visible,
			"removalReasonReported":removal_reason_reported})
	actual_service._scenes.erase(Vector2i.ZERO)
	actual_service._retiring_scenes.append(retiring_entry)
	var queued_retirement: Dictionary = _ack_after_inventory_progress(actual_service,
		SECTION, current_coverage, receipt)
	var retirement_reason_reported: bool = false
	for result_value: Variant in queued_retirement.get("visualResults", []):
		if result_value is Dictionary and String(result_value.get("reason", "")) \
				== "citadel_retiring_scene_visual_owner_not_drained":
			retirement_reason_reported = true
	_check("empty_current_receipt_waits_for_scene_after_it_enters_retirement_queue",
		queued_retirement.get("status") == "pending"
		and retiring_visual.visible and retirement_reason_reported,
		{"ack":queued_retirement,
			"ackPath":actual_service.fixture_last_ack_path_trace,
			"retiringVisualVisible":retiring_visual.visible,
			"retirementReasonReported":retirement_reason_reported})
	retiring_visual.queue_free()
	await process_frame
	var draining_retirement: Dictionary = _ack_after_inventory_progress(actual_service,
		SECTION, current_coverage, receipt)
	_check("empty_current_receipt_waits_until_retiring_owner_entry_drains",
		draining_retirement.get("status") == "pending" and retirement_reason_reported,
		{"ack":draining_retirement,
			"ackPath":actual_service.fixture_last_ack_path_trace,
			"retiringSceneCount":actual_service._retiring_scenes.size()})
	actual_service._retiring_scenes.erase(retiring_entry)
	retiring_owner.queue_free()
	await process_frame
	var accepted: Dictionary = _ack_after_inventory_progress(actual_service,
		SECTION, current_coverage, receipt)
	_check("actual_citadel_service_ack_rejects_stale_then_accepts_current_receipt",
		stale_coverage.get("status") == "pending"
		and accepted.get("status") == "acknowledged",
		{"staleCoverage":stale_coverage, "current":accepted,
			"coverageRevision":current_coverage})
	admission.generation += 1
	var stale_generation: Dictionary = _ack_after_inventory_progress(actual_service,
		SECTION, current_coverage, receipt)
	_check("actual_citadel_service_rejects_receipt_after_admission_revision_changes",
		stale_generation.get("status") == "pending",
		{"ack":stale_generation, "previousGeneration":1,
			"currentGeneration":admission.generation})
	admission.generation -= 1
	var old_chunk := world.chunk_owner
	old_chunk.get_parent().remove_child(old_chunk)
	old_chunk.free()
	var replacement_chunk := Node3D.new()
	replacement_chunk.name = "Chunk_0_0"
	world.add_child(replacement_chunk)
	var replacement_result: Dictionary = PacketOwner.attach_to_chunk(replacement_chunk)
	world.chunk_owner = replacement_chunk
	world.backend = replacement_result.get("backend") as Node3D
	fixture_service._restore_stale_citadel_visuals(fixture_service.fixture_publisher,
		SITE_ID, MEMBER_ID)
	_check("section_owner_recreation_restores_old_visual_until_replacement_receipt",
		legacy_visual.visible,
		{"visible":legacy_visual.visible, "newBackendInstanceId":world.backend.get_instance_id(),
			"oldReceiptBackendInstanceId":receipt.get("backendInstanceId")})
	var stale_owner: Dictionary = _ack_after_inventory_progress(actual_service,
		SECTION, current_coverage, receipt)
	_check("actual_citadel_service_ack_rejects_receipt_after_section_owner_recreation",
		replacement_result.get("status") == "ready"
		and stale_owner.get("status") == "pending",
		{"replacementOwner":replacement_result, "ack":stale_owner,
			"oldBackendInstanceId":receipt.get("backendInstanceId"),
			"newBackendInstanceId":world.backend.get_instance_id()})


func _verify_live_plan_omission_tombstone(world: WorldRoot) -> void:
	var admission := TombstoneAdmission.new()
	var service := TombstoneService.new()
	service.configure(admission)
	var plan := TombstonePlan.new()
	var source_id := CitadelService._citadel_census_source_id(SITE_ID,
		"building:" + TOMBSTONE_PART_ID, SECTION)
	plan.source_binding = admission.source_binding
	service.fixture_plan = plan
	var publisher := BuildingVisualOwner.new()
	world.add_child(publisher)
	var old_visual := MeshInstance3D.new()
	var old_visual_mesh := BoxMesh.new()
	old_visual_mesh.size = Vector3(2.0, 1.0, 1.0)
	old_visual.mesh = old_visual_mesh
	old_visual.position = Vector3(Grid.SECTION_SIZE_METERS, 5.0, 5.0)
	old_visual.set_meta("building_source_part_id", TOMBSTONE_PART_ID)
	publisher.add_child(old_visual)
	publisher.published_nodes.append(old_visual)
	var old_bindings := {TOMBSTONE_PART_ID:"fixture-old-member-binding-r1"}
	old_bindings.make_read_only()
	publisher._physical_packet_bindings_by_part_id = old_bindings
	var job := RetiringSceneJob.new()
	job._building = publisher
	var entry := {"region":Vector2i.ZERO, "binding":admission.source_binding,
		"packetMode":true, "phase":"scene_ready", "job":job}
	service._scenes[Vector2i.ZERO] = entry
	var tombstone_world_id := "seed:%s:%d" % [TOMBSTONE_SERVICE_SEED,
		CitadelService._seed_hash(TOMBSTONE_SERVICE_SEED)]
	var coordinator = Coordinator.new()
	coordinator.configure(tombstone_world_id)
	var domains: Array[String] = [PROVIDER_ID]
	var roster_result: Dictionary = coordinator.configure_source_roster(domains)
	var provider_result: Dictionary = coordinator.register_source_provider(PROVIDER_ID,
		service, "capture_static_section_sources")
	var initial_census: Dictionary = service.capture_static_section_sources(
		tombstone_world_id, [SECTION])
	var initial_removals: Array = initial_census.get("removalsBySection", {}).get(
		SECTION, [])
	var initial_removal: Dictionary = initial_removals[0] if not initial_removals.is_empty() else {}
	var expected_visual_bounds := old_visual.global_transform * old_visual.get_aabb()
	var tombstone_is_exact: bool = initial_census.get("status") == "complete" \
		and initial_removals.size() == 1 \
		and String(initial_removal.get("sourcePartId", "")) == \
			CitadelService._citadel_census_source_id(SITE_ID,
				"building:" + TOMBSTONE_PART_ID, SECTION) \
		and String(initial_removal.get("memberBinding", "")) \
			== "fixture-old-member-binding-r1" \
		and String(initial_removal.get("ownerBindingDigest", "")).length() == 64 \
		and String(initial_removal.get("sourceRevision", "")).length() == 64 \
		and initial_removal.get("bounds", []) == [expected_visual_bounds]
	var first_admission: Dictionary = await _admit_compiled_candidate(coordinator,
		SECTION, 1)
	var first_install: Dictionary = await _advance_tombstone_install(coordinator, SECTION)
	var first_receipt: Dictionary = coordinator._production_candidate_receipts.get(SECTION, {})
	var first_coverage_rows: Array = first_receipt.get("providerCoverage", [])
	var first_coverage := String(first_coverage_rows[0][1]) \
		if not first_coverage_rows.is_empty() else ""
	plan.output_signature = "fixture-current-empty-plan-r2"
	var stale_plan_ack: Dictionary = _ack_after_inventory_progress(service, SECTION,
		first_coverage, first_receipt)
	plan.output_signature = "fixture-current-empty-plan-r1"
	var changed_bindings := {TOMBSTONE_PART_ID:"fixture-old-member-binding-r2"}
	changed_bindings.make_read_only()
	publisher._physical_packet_bindings_by_part_id = changed_bindings
	var stale_member_ack: Dictionary = _ack_after_inventory_progress(service, SECTION,
		first_coverage, first_receipt)
	publisher._physical_packet_bindings_by_part_id = old_bindings
	var first_ack: Dictionary = _ack_after_inventory_progress(service, SECTION,
		first_coverage, first_receipt)
	var intersected_sections: Array[Vector3i] = Grid.keys_intersecting_bounds(
		old_visual.global_transform * old_visual.get_aabb())
	_check("current_empty_plan_acknowledges_section_and_queues_cross_section_retirement",
		roster_result.get("status") == "ready"
		and provider_result.get("status") == "ready"
		and first_admission.get("status") == "queued"
		and tombstone_is_exact
		and first_install.get("status") == "installed"
		and first_receipt.get("status") == "installed"
		and stale_plan_ack.get("status") == "pending"
		and String(stale_plan_ack.get("reason", "")) \
			== "citadel_section_acknowledgement_coverage_stale"
		and stale_member_ack.get("status") == "pending"
		and String(stale_member_ack.get("reason", "")) \
			== "citadel_section_acknowledgement_coverage_stale"
		and old_visual.visible
		and first_ack.get("status") == "acknowledged"
		and service._pending_section_source_retirements.has(source_id)
		and old_visual.visible
		and intersected_sections == [SECTION, Vector3i(1, 0, 0)],
		{"roster":roster_result, "provider":provider_result,
			"census":initial_census, "tombstone":initial_removal,
			"admission":first_admission, "install":first_install,
			"receipt":first_receipt, "stalePlanAck":stale_plan_ack,
			"staleMemberBindingAck":stale_member_ack,
			"ack":first_ack,
			"pendingRetirement":service._pending_section_source_retirements.get(source_id, {}),
			"oldVisualVisible":old_visual.visible,
			"intersectedSections":intersected_sections})
	var neighbor_section := Vector3i(1, 0, 0)
	var neighbor_admission: Dictionary = await _admit_compiled_candidate(coordinator,
		neighbor_section, 1)
	var neighbor_install: Dictionary = await _advance_tombstone_install(coordinator,
		neighbor_section)
	var neighbor_receipt: Dictionary = coordinator._production_candidate_receipts.get(
		neighbor_section, {})
	var neighbor_coverage_rows: Array = neighbor_receipt.get("providerCoverage", [])
	var neighbor_coverage := String(neighbor_coverage_rows[0][1]) \
		if not neighbor_coverage_rows.is_empty() else ""
	var neighbor_ack: Dictionary = _ack_after_inventory_progress(service,
		neighbor_section, neighbor_coverage, neighbor_receipt)
	var retirement_tick: Dictionary = service.advance(Rect2i(), false, 4000)
	_check("legacy_source_retires_after_empty_neighbor_receipt_arrives",
		neighbor_admission.get("status") == "queued"
		and neighbor_install.get("status") == "installed"
		and neighbor_receipt.get("status") == "installed"
		and neighbor_ack.get("status") == "acknowledged"
		and retirement_tick.get("status") != "rejected"
		and not service._pending_section_source_retirements.has(source_id)
		and not old_visual.visible,
		{"admission":neighbor_admission, "install":neighbor_install,
			"receipt":neighbor_receipt, "ack":neighbor_ack,
			"retirementTick":retirement_tick,
			"oldVisualVisible":old_visual.visible})


func _advance_tombstone_install(owner_coordinator, section: Vector3i) -> Dictionary:
	var install_result: Dictionary = {"status":"not_started"}
	var transition_diagnostics: Array[Dictionary] = []
	var tail_diagnostics: Array[Dictionary] = []
	var last_transition_signature := ""
	var section_owner_cell: Vector2i = Grid.chunk_key_for_section(section)
	for frame_index in range(TOMBSTONE_INSTALL_FRAME_BUDGET):
		var candidate_keys_before: Array[String] = _candidate_job_key_strings(
			owner_coordinator)
		var requested_candidate_exists_before: bool = \
			owner_coordinator._production_candidate_jobs.has(section)
		var step: Dictionary = owner_coordinator.advance_queued_complete_section_candidates(1, 8)
		var results: Array = step.get("results", [])
		var step_envelope := {"sectionKeyPresent":false, "sectionKey":"",
			"status":String(step.get("status", "")),
			"stage":String(step.get("stage", "")),
			"reason":String(step.get("reason", ""))}
		step_envelope.make_read_only()
		var frame_result: Dictionary = {}
		var raw_results: Array[Dictionary] = []
		for result_value: Variant in results:
			if not result_value is Dictionary:
				continue
			var result_section: Variant = result_value.get("sectionKey", null)
			var normalized_result := {"sectionKeyPresent":result_section is Vector3i,
				"sectionKey":str(result_section) if result_section != null else "",
				"status":String(result_value.get("status", "")),
				"stage":String(result_value.get("stage", "")),
				"reason":String(result_value.get("reason", ""))}
			normalized_result.make_read_only()
			raw_results.append(normalized_result)
			if result_section == section:
				frame_result = result_value
				install_result = frame_result
				break
		raw_results.make_read_only()
		var candidate_job: Dictionary = owner_coordinator._production_candidate_jobs.get(
			section, {})
		var candidate_keys_after: Array[String] = _candidate_job_key_strings(
			owner_coordinator)
		var requested_candidate_exists_after: bool = \
			owner_coordinator._production_candidate_jobs.has(section)
		var candidate: Dictionary = candidate_job.get("candidate", {})
		var session = candidate_job.get("session")
		var session_present: bool = session != null
		var session_valid: bool = session_present and is_instance_valid(session)
		var diagnostic := {"frame":frame_index,
			"sectionOwnerCell":[section_owner_cell.x, section_owner_cell.y],
			"stepStatus":String(step.get("status", "")),
			"stepReason":String(step.get("reason", "")),
			"stepEnvelope":step_envelope,
			"stepSectionCount":int(step.get("sectionCount", 0)),
			"rawResults":raw_results,
			"requestedCandidateExistsBefore":requested_candidate_exists_before,
			"requestedCandidateExistsAfter":requested_candidate_exists_after,
			"candidateKeysBefore":candidate_keys_before,
			"candidateKeysAfter":candidate_keys_after,
			"sessionAdvanceStatus":String(frame_result.get("status", "no_section_result")),
			"sessionAdvanceStage":String(frame_result.get("stage", "")),
			"sessionAdvanceReason":String(frame_result.get("reason", "")),
			"resultStatus":String(frame_result.get("status", "")),
			"resultStage":String(frame_result.get("stage", "")),
			"resultReason":String(frame_result.get("reason", "")),
			"candidateJobStage":String(candidate_job.get("stage", "")),
			"candidateGeneration":int(candidate.get("generation", 0)),
			"candidateCensusDigest":String(candidate.get("censusDigest", "")),
			"sessionPresent":session_present,
			"sessionValid":session_valid,
			"sessionState":String(session.state) if session_valid else "unavailable",
			"sessionReason":String(session.reason) if session_valid else "",
			"sessionUnits":int(session.units) if session_valid else 0,
			"sessionBackendInstanceId":int(session._backend_id) if session_valid else 0,
			"sessionChunkInstanceId":int(session._chunk_id) if session_valid else 0,
			"productionCandidateJobCount":owner_coordinator._production_candidate_jobs.size(),
			"pendingAcknowledgementCount":owner_coordinator._pending_source_acknowledgements.size()}
		diagnostic.make_read_only()
		var transition_signature := "%s|%s|%s|%s|%s|%s|%s" % [
			String(step.get("status", "")), String(frame_result.get("status", "")),
			String(frame_result.get("stage", "")), String(frame_result.get("reason", "")),
			str(requested_candidate_exists_before), str(requested_candidate_exists_after),
			JSON.stringify(raw_results)]
		if transition_signature != last_transition_signature \
				and transition_diagnostics.size() < TOMBSTONE_INSTALL_TRANSITION_SAMPLE_LIMIT:
			transition_diagnostics.append(diagnostic)
			last_transition_signature = transition_signature
		tail_diagnostics.append(diagnostic)
		if tail_diagnostics.size() > TOMBSTONE_INSTALL_TAIL_SAMPLE_LIMIT:
			tail_diagnostics.pop_front()
		if frame_result.is_empty() and not raw_results.is_empty() \
				and requested_candidate_exists_before and not requested_candidate_exists_after:
			var missing_target := {"status":"failed",
				"reason":"fixture_requested_candidate_disappeared_without_matching_section_result",
				"sectionKey":section, "frame":frame_index,
				"rawResults":raw_results,
				"candidateKeysBefore":candidate_keys_before,
				"candidateKeysAfter":candidate_keys_after,
				"requestedCandidateExistsBefore":requested_candidate_exists_before,
				"requestedCandidateExistsAfter":requested_candidate_exists_after}
			missing_target["progressDiagnostics"] = _bounded_install_trace(
				transition_diagnostics, tail_diagnostics)
			missing_target["progressFrameCount"] = frame_index + 1
			missing_target["frameBudget"] = TOMBSTONE_INSTALL_FRAME_BUDGET
			missing_target.make_read_only()
			return missing_target
		if install_result.get("status") in ["installed", "failed", "cancelled"]:
			var completed := install_result.duplicate(false)
			completed["progressDiagnostics"] = _bounded_install_trace(
				transition_diagnostics, tail_diagnostics)
			completed["progressFrameCount"] = frame_index + 1
			completed["frameBudget"] = TOMBSTONE_INSTALL_FRAME_BUDGET
			completed.make_read_only()
			return completed
		await process_frame
	var pending := {"status":"pending", "reason":"fixture_native_install_runner_budget_exhausted",
		"sectionKey":section, "progressDiagnostics":_bounded_install_trace(
			transition_diagnostics, tail_diagnostics),
		"progressFrameCount":TOMBSTONE_INSTALL_FRAME_BUDGET,
		"frameBudget":TOMBSTONE_INSTALL_FRAME_BUDGET}
	pending.make_read_only()
	return pending


func _candidate_job_key_strings(owner_coordinator) -> Array[String]:
	var keys: Array[String] = []
	for key_value: Variant in owner_coordinator._production_candidate_jobs.keys():
		keys.append(str(key_value))
	keys.sort()
	keys.make_read_only()
	return keys


func _retiring_inventory_probe(service, entry: Dictionary,
		section: Vector3i) -> Dictionary:
	var region_value: Variant = entry.get("region", null)
	if not region_value is Vector2i or service._admission == null:
		return {"status":"pending", "reason":"retiring_inventory_probe_owner_unavailable",
			"disjoint":false, "visualCount":0}
	var region: Vector2i = region_value
	var source: Dictionary = service._admission.source_state(region)
	var binding: Dictionary = entry.get("binding", {})
	var inventory: Dictionary = service._retiring_citadel_inventory_disjoint_from_section(
		entry, source, binding, section)
	return {"status":String(inventory.get("status", "pending")),
		"reason":String(inventory.get("reason", "")),
		"disjoint":bool(inventory.get("disjoint", false)),
		"visualCount":int(inventory.get("visualCount", 0)),
		"sourceStatus":String(source.get("status", "pending")),
		"sourceBindingMatches":source.get("binding", {}) == binding,
		"region":region, "sectionKey":section}


func _bounded_install_trace(transitions: Array[Dictionary], tail: Array[Dictionary]) \
		-> Array[Dictionary]:
	var by_frame: Dictionary = {}
	for row: Dictionary in transitions:
		by_frame[int(row.get("frame", -1))] = row
	for row: Dictionary in tail:
		by_frame[int(row.get("frame", -1))] = row
	var frames: Array[int] = []
	for frame_value: Variant in by_frame.keys():
		frames.append(int(frame_value))
	frames.sort()
	var result: Array[Dictionary] = []
	for frame_index: int in frames:
		result.append(by_frame[frame_index])
	result.make_read_only()
	return result


func _verify_retiring_scene_reservation_liveness(world: WorldRoot) -> void:
	var admission := TombstoneAdmission.new()
	var service := TombstoneService.new()
	service.configure(admission)
	var plan := TombstonePlan.new()
	plan.source_binding = admission.source_binding
	service.fixture_plan = plan
	var retiring_job := RetiringSceneJob.new()
	var retiring_root := Node3D.new()
	world.add_child(retiring_root)
	var retiring_owner := BuildingVisualOwner.new()
	retiring_root.add_child(retiring_owner)
	var local_visual := MeshInstance3D.new()
	var local_mesh := BoxMesh.new()
	local_mesh.size = Vector3.ONE
	local_visual.mesh = local_mesh
	local_visual.position = Vector3(10.0, 5.0, 10.0)
	local_visual.set_meta("building_source_part_id", "fixture-retiring-member")
	retiring_owner.add_child(local_visual)
	retiring_owner.published_nodes.append(local_visual)
	retiring_job._root = retiring_root
	retiring_job._binding = admission.source_binding
	retiring_job._building = retiring_owner
	var retiring_entry := {"region":Vector2i.ZERO,
		"binding":admission.source_binding, "job":retiring_job}
	service._retiring_scenes.append(retiring_entry)
	var owner_id := "seed:%s:%d" % [TOMBSTONE_SERVICE_SEED,
		CitadelService._seed_hash(TOMBSTONE_SERVICE_SEED)]
	var coordinator = Coordinator.new()
	coordinator.configure(owner_id)
	var domains: Array[String] = [PROVIDER_ID]
	var roster_result: Dictionary = coordinator.configure_source_roster(domains)
	var provider_result: Dictionary = coordinator.register_source_provider(PROVIDER_ID,
		service, "capture_static_section_sources")
	var distant_section := Vector3i(20, 0, 0)
	var distant_admission: Dictionary = await _admit_compiled_candidate(coordinator,
		distant_section, 1)
	var distant_install: Dictionary = await _advance_tombstone_install(coordinator,
		distant_section)
	var distant_receipt: Dictionary = coordinator._production_candidate_receipts.get(
		distant_section, {})
	var distant_coverage_rows: Array = distant_receipt.get("providerCoverage", [])
	var distant_coverage := String(distant_coverage_rows[0][1]) \
		if not distant_coverage_rows.is_empty() else ""
	var nonintersecting_ack: Dictionary = _ack_after_inventory_progress(service,
		distant_section, distant_coverage, distant_receipt)
	var distant_owner_cell: Vector2i = Grid.chunk_key_for_section(distant_section)
	_check("same_region_exact_retained_inventory_bounds_allow_unrelated_section_while_retiree_stays_undrained",
		roster_result.get("status") == "ready"
		and provider_result.get("status") == "ready"
		and distant_admission.get("status") == "queued"
		and distant_install.get("status") == "installed"
		and distant_receipt.get("status") == "installed"
		and distant_owner_cell != Vector2i.ZERO
		and nonintersecting_ack.get("status") == "acknowledged"
		and not _ack_contains_reason(nonintersecting_ack,
			"citadel_retiring_scene_visual_owner_not_drained")
		and service._retiring_scenes.size() == 1,
		{"roster":roster_result, "provider":provider_result,
			"admission":distant_admission, "install":distant_install,
			"receipt":distant_receipt, "ack":nonintersecting_ack,
			"distantOwnerCell":distant_owner_cell,
			"retiringSceneCount":service._retiring_scenes.size(),
			"retiringJobStatus":"fixture intentionally does not advance job",
			"inventoryBounds":local_visual.global_transform * local_visual.get_aabb()})
	var unlisted_visual := MeshInstance3D.new()
	var unlisted_mesh := BoxMesh.new()
	unlisted_mesh.size = Vector3.ONE
	unlisted_visual.mesh = unlisted_mesh
	unlisted_visual.position = Grid.origin_for_key(distant_section) \
		+ Vector3(5.0, 0.5, 5.0)
	unlisted_visual.set_meta("building_source_part_id", "fixture-unlisted-retiring-member")
	retiring_owner.add_child(unlisted_visual)
	# Deliberately omit this visible child from published_nodes and the job root.
	# The still-current publisher owner is the complete scan root.
	retiring_job._root = null
	var rootless_retirees_before_ack: int = service._retiring_scenes.size()
	var rootless_inventory: Dictionary = _retiring_inventory_probe(service,
		retiring_entry, distant_section)
	var unlisted_child_ack: Dictionary = _ack_after_inventory_progress(service,
		distant_section, distant_coverage, distant_receipt)
	var rootless_retirees_after_ack: int = service._retiring_scenes.size()
	var unlisted_child_result: Dictionary = {}
	var unlisted_visual_results: Array = unlisted_child_ack.get("visualResults", [])
	if not unlisted_visual_results.is_empty() and unlisted_visual_results[0] is Dictionary:
		unlisted_child_result = unlisted_visual_results[0]
	_check("rootless_current_retiring_owner_inventory_finds_unlisted_visible_child",
		unlisted_child_ack.get("status") == "pending"
		and rootless_inventory.get("status") == "pending"
		and String(rootless_inventory.get("reason", "")) \
			== "retiring_visual_intersects_section"
		and _ack_contains_reason(unlisted_child_ack,
			"citadel_retiring_scene_visual_owner_not_drained")
		and String(unlisted_child_result.get("inventoryReason", "")) \
			== "retiring_visual_intersects_section"
		and unlisted_visual.visible
		and is_instance_valid(retiring_job._building)
		and retiring_job._binding == admission.source_binding,
		{"ack":unlisted_child_ack, "unlistedVisualVisible":unlisted_visual.visible,
			"ackPath":service.fixture_last_ack_path_trace,
			"inventory":rootless_inventory,
			"retiringSceneCountBeforeAck":rootless_retirees_before_ack,
			"retiringSceneCountAfterAck":rootless_retirees_after_ack,
			"listedPublishedNodeCount":retiring_owner.published_nodes.size(),
			"jobRootAvailable":retiring_job.own_node_root() != null,
			"bindingCurrent":retiring_job._binding == admission.source_binding})
	retiring_owner.remove_child(unlisted_visual)
	unlisted_visual.free()
	retiring_job._root = retiring_root
	var oversize_visual := MeshInstance3D.new()
	var oversize_mesh := BoxMesh.new()
	oversize_mesh.size = Vector3(2.0, 1.0, 2.0)
	oversize_visual.mesh = oversize_mesh
	oversize_visual.position = Grid.origin_for_key(distant_section) \
		+ Vector3(Grid.SECTION_SIZE_METERS - 0.5, 0.5, 10.0)
	oversize_visual.set_meta("building_source_part_id", "fixture-oversize-retiring-member")
	retiring_owner.add_child(oversize_visual)
	retiring_owner.published_nodes.append(oversize_visual)
	var distant_section_admission_bounds: Rect2i = service._citadel_section_admission_bounds(
		distant_section)
	var oversize_world_bounds: AABB = oversize_visual.global_transform * oversize_visual.get_aabb()
	var oversize_section_keys: Array[Vector3i] = Grid.keys_intersecting_bounds(
		oversize_world_bounds)
	var oversize_retirees_before_ack: int = service._retiring_scenes.size()
	var oversize_inventory: Dictionary = _retiring_inventory_probe(service,
		retiring_entry, distant_section)
	var oversize_ack: Dictionary = _ack_after_inventory_progress(service,
		distant_section, distant_coverage, distant_receipt)
	var oversize_retirees_after_ack: int = service._retiring_scenes.size()
	_check("visual_outside_matching_reservation_intersection_stays_pending",
		oversize_ack.get("status") == "pending"
		and oversize_inventory.get("status") == "pending"
		and String(oversize_inventory.get("reason", "")) \
			== "retiring_visual_intersects_section"
		and not admission.reservation_cells.intersects(distant_section_admission_bounds)
		and distant_section in oversize_section_keys
		and Vector3i(distant_section.x + 1, distant_section.y, distant_section.z) \
			in oversize_section_keys
		and _ack_contains_reason(oversize_ack,
			"citadel_retiring_scene_visual_owner_not_drained")
		and service._retiring_scenes.size() == 1,
		{"ack":oversize_ack,
			"ackPath":service.fixture_last_ack_path_trace,
			"inventory":oversize_inventory,
			"retiringSceneCountBeforeAck":oversize_retirees_before_ack,
			"retiringSceneCountAfterAck":oversize_retirees_after_ack,
			"oversizeVisualBounds":oversize_world_bounds,
			"oversizeSectionKeys":oversize_section_keys,
			"distantSectionAdmissionBounds":distant_section_admission_bounds,
			"reservationCells":admission.reservation_cells,
			"retiringSceneCount":service._retiring_scenes.size()})
	retiring_owner.published_nodes.erase(oversize_visual)
	retiring_owner.remove_child(oversize_visual)
	oversize_visual.free()
	var cross_region_section := Vector3i(130, 0, 0)
	var cross_region_admission: Dictionary = await _admit_compiled_candidate(coordinator,
		cross_region_section, 1)
	var cross_region_install: Dictionary = await _advance_tombstone_install(coordinator,
		cross_region_section)
	var cross_region_receipt: Dictionary = coordinator._production_candidate_receipts.get(
		cross_region_section, {})
	var cross_region_coverage_rows: Array = cross_region_receipt.get("providerCoverage", [])
	var cross_region_coverage := String(cross_region_coverage_rows[0][1]) \
		if not cross_region_coverage_rows.is_empty() else ""
	var cross_region_visual := MeshInstance3D.new()
	var cross_region_mesh := BoxMesh.new()
	cross_region_mesh.size = Vector3.ONE
	cross_region_visual.mesh = cross_region_mesh
	cross_region_visual.position = Grid.origin_for_key(cross_region_section) \
		+ Vector3(0.5, 0.5, 0.5)
	retiring_owner.add_child(cross_region_visual)
	retiring_owner.published_nodes.append(cross_region_visual)
	var cross_region_world_bounds: AABB = cross_region_visual.global_transform \
		* cross_region_visual.get_aabb()
	var cross_region_keys: Array[Vector3i] = Grid.keys_intersecting_bounds(
		cross_region_world_bounds)
	var admission_binding_before: Dictionary = admission.source_binding
	var stale_admission_binding := admission_binding_before.duplicate(false)
	stale_admission_binding["sourceKey"] = "superseded-cross-region-admission"
	admission.source_binding = stale_admission_binding
	var stale_admission_retirees_before_ack: int = service._retiring_scenes.size()
	var stale_admission_inventory: Dictionary = _retiring_inventory_probe(service,
		retiring_entry, cross_region_section)
	var cross_region_stale_ack: Dictionary = _ack_after_inventory_progress(service,
		cross_region_section, cross_region_coverage, cross_region_receipt)
	var stale_admission_retirees_after_ack: int = service._retiring_scenes.size()
	var cross_region_bounds: Rect2i = service._citadel_section_admission_bounds(
		cross_region_section)
	var cross_region_low: Vector2i = CitadelService.Field.region_for_cell(
		cross_region_bounds.position)
	var cross_region_high: Vector2i = CitadelService.Field.region_for_cell(
		cross_region_bounds.end - Vector2i.ONE)
	var retiring_region := Vector2i.ZERO
	var old_region_outside_coarse_query: bool = \
		retiring_region.x < cross_region_low.x or retiring_region.x > cross_region_high.x \
		or retiring_region.y < cross_region_low.y or retiring_region.y > cross_region_high.y
	_check("stale_admission_cannot_skip_cross_region_retiring_visual",
		cross_region_admission.get("status") == "queued"
		and cross_region_install.get("status") == "installed"
		and cross_region_receipt.get("status") == "installed"
		and not admission.reservation_cells.intersects(cross_region_bounds)
		and cross_region_section in cross_region_keys
		and old_region_outside_coarse_query
		and stale_admission_inventory.get("status") == "pending"
		and String(stale_admission_inventory.get("reason", "")) \
			== "retiring_admission_binding_stale"
		and cross_region_stale_ack.get("status") == "pending"
		and _ack_contains_reason(cross_region_stale_ack,
			"citadel_retiring_scene_visual_owner_not_drained"),
		{"admission":cross_region_admission, "install":cross_region_install,
			"receipt":cross_region_receipt, "ack":cross_region_stale_ack,
			"ackPath":service.fixture_last_ack_path_trace,
			"inventory":stale_admission_inventory,
			"retiringSceneCountBeforeAck":stale_admission_retirees_before_ack,
			"retiringSceneCountAfterAck":stale_admission_retirees_after_ack,
			"crossRegionWorldBounds":cross_region_world_bounds,
			"crossRegionSectionKeys":cross_region_keys,
			"sectionAdmissionBounds":cross_region_bounds,
			"reservationCells":admission.reservation_cells,
			"coarseRegionRange":[cross_region_low, cross_region_high],
			"retiringRegion":retiring_region,
			"retiringAdmissionBinding":admission_binding_before,
			"currentAdmissionBinding":stale_admission_binding})
	admission.source_binding = admission_binding_before
	retiring_owner.published_nodes.erase(cross_region_visual)
	retiring_owner.remove_child(cross_region_visual)
	cross_region_visual.free()
	var stale_binding := admission.source_binding.duplicate(false)
	stale_binding["sourceKey"] = "superseded-fixture-binding"
	retiring_entry["binding"] = stale_binding
	var stale_binding_retirees_before_ack: int = service._retiring_scenes.size()
	var stale_binding_inventory: Dictionary = _retiring_inventory_probe(service,
		retiring_entry, distant_section)
	var stale_binding_ack: Dictionary = _ack_after_inventory_progress(service,
		distant_section, distant_coverage, distant_receipt)
	var stale_binding_retirees_after_ack: int = service._retiring_scenes.size()
	_check("same_region_retiree_with_stale_binding_keeps_conservative_pending_gate",
		stale_binding_ack.get("status") == "pending"
		and stale_binding_inventory.get("status") == "pending"
		and String(stale_binding_inventory.get("reason", "")) \
			== "retiring_admission_binding_stale"
		and _ack_contains_reason(stale_binding_ack,
			"citadel_retiring_scene_visual_owner_not_drained")
		and service._retiring_scenes.size() == 1,
		{"ack":stale_binding_ack,
			"ackPath":service.fixture_last_ack_path_trace,
			"inventory":stale_binding_inventory,
			"retiringSceneCountBeforeAck":stale_binding_retirees_before_ack,
			"retiringSceneCountAfterAck":stale_binding_retirees_after_ack,
			"retiringBinding":stale_binding,
			"currentAdmissionBinding":admission.source_binding})
	retiring_entry["binding"] = admission.source_binding
	var local_section := Vector3i.ZERO
	var local_admission: Dictionary = await _admit_compiled_candidate(coordinator,
		local_section, 2)
	var local_install: Dictionary = await _advance_tombstone_install(coordinator,
		local_section)
	var local_receipt: Dictionary = coordinator._production_candidate_receipts.get(
		local_section, {})
	var local_coverage_rows: Array = local_receipt.get("providerCoverage", [])
	var local_coverage := String(local_coverage_rows[0][1]) \
		if not local_coverage_rows.is_empty() else ""
	var intersecting_ack: Dictionary = _ack_after_inventory_progress(service,
		local_section, local_coverage, local_receipt)
	_check("intersecting_current_reservation_stays_pending_while_retiree_is_not_drained",
		local_admission.get("status") == "queued"
		and local_install.get("status") == "installed"
		and intersecting_ack.get("status") == "pending"
		and _ack_contains_reason(intersecting_ack,
			"citadel_retiring_scene_visual_owner_not_drained")
		and service._retiring_scenes.size() == 1,
		{"admission":local_admission, "install":local_install,
			"receipt":local_receipt, "ack":intersecting_ack,
			"retiringSceneCount":service._retiring_scenes.size()})
	service._retiring_scenes.erase(retiring_entry)
	retiring_root.free()
	var after_drain_ack: Dictionary = _ack_after_inventory_progress(service,
		local_section, local_coverage, local_receipt)
	_check("intersecting_section_ack_retries_after_retiree_drains",
		after_drain_ack.get("status") == "acknowledged"
		and service._retiring_scenes.is_empty(),
		{"ack":after_drain_ack,
			"retiringSceneCount":service._retiring_scenes.size()})


func _ack_after_inventory_progress(service: CitadelService,
		section_key: Vector3i, coverage_revision: String,
		receipt: Dictionary) -> Dictionary:
	var result: Dictionary = {"status":"pending",
		"reason":"fixture_ack_inventory_progress_not_started"}
	for _attempt in range(32):
		result = service.acknowledge_section_install(section_key,
			coverage_revision, receipt)
		if String(result.get("reason", "")) not in [
				"legacy_visual_section_scope_preparing",
				"legacy_visual_index_preparing",
				"citadel_visual_inventory_index_pending"]:
			return result
		service.advance_legacy_visual_inventory(96, 350)
	return result


func _ack_contains_reason(ack: Dictionary, expected_reason: String) -> bool:
	for result_value: Variant in ack.get("visualResults", []):
		if result_value is Dictionary and String(result_value.get("reason", "")) == expected_reason:
			return true
	return false


func _citadel_fixture_census(source_revision := "citadel-member-r1",
		coverage_revision := "citadel-coverage-r1") -> Dictionary:
	var source_id := CitadelService._citadel_census_source_id(SITE_ID,
		MEMBER_ID, SECTION)
	var source_ids: Array[String] = [source_id]
	source_ids.make_read_only()
	var row := {"status":"complete", "coverageRevision":coverage_revision,
		"sourcePartIds":source_ids}
	row.make_read_only()
	var section_map := {SECTION:row}
	section_map.make_read_only()
	var revisions := {source_id:source_revision}
	revisions.make_read_only()
	var result := {"status":"complete", "worldId":world_id,
		"authorityRevision":"citadel-authority-r1",
		"sourceRevisions":revisions, "sections":section_map}
	result.make_read_only()
	return result


func _build_batch() -> void:
	mesh = ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, -0.5, -0.5), Vector3(0.5, -0.5, -0.5),
		Vector3(0.0, 0.5, 0.5)])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	material = StandardMaterial3D.new()
	material.albedo_color = Color(0.6, 0.45, 0.3)
	var digest: Dictionary = MeshFingerprint.inspect(mesh)
	var mesh_resource := "citadel-fixture-mesh"
	var pipeline := "citadel-receipt-retirement-fixture-v1"
	var mesh_key := "%s|pipeline=%s|layer=opaque|sort=none" % [mesh_resource, pipeline]
	var raw := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":"citadel-fixture-material", "renderTier":"structural",
		"meshResourceKey":mesh_resource, "meshKey":mesh_key,
		"meshContentDigest":String(digest.get("contentDigest", "")),
		"meshLocalBounds":mesh.get_aabb(), "pipelineRevision":pipeline,
		"renderLayer":"opaque", "translucentSortPolicy":"none",
		"castShadows":true, "visibilityRangeEnd":0.0, "fadeMargin":0.0}
	batch_key = SnapshotBuilder.batch_compatibility_key(raw)
	raw["batchKey"] = batch_key
	raw["compatibilityKey"] = batch_key
	raw.make_read_only()
	compatibility = raw


func _check(label: String, passed: bool, evidence: Variant) -> void:
	checks[label] = {"passed":passed, "evidence":evidence}
	if not passed:
		print("CITADEL SECTION RECEIPT RETIREMENT FAILURE ", label)


func _finish() -> void:
	var failed: Array[String] = []
	for name: String in checks:
		if not bool(checks[name].get("passed", false)):
			failed.append(name)
	var result := {"schema":"citadel-section-receipt-retirement-fixture/v1",
		"complete":true, "passed":failed.is_empty(), "checks":checks,
		"checkCount":checks.size(), "failedChecks":failed,
		"evidenceLevel":"headed native receipt fixture: actual CitadelPublicationService source census and active-owner omission tombstones flow through the live roster, complete assembler candidate, native section receipts and multi-section visual retirement; fixtures supply admission/plan inputs",
		"doesNotProve":"Normal-world Citadel plan generation and packet capture, collision physics/door/nav gameplay, save/reload parity, startup readiness, or performance."}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(result, "\t"))
			file.close()
	quit(0 if failed.is_empty() else 1)

## Admission now queues a native worker. Wait for its current identity receipt
## before the fixture inspects candidate data or controls upload/frame stages.
func _admit_compiled_candidate(owner_coordinator, section_key: Vector3i,
		generation: int) -> Dictionary:
	var admission: Dictionary = owner_coordinator.call(
		"assemble_and_submit_complete_section_candidate", section_key, generation)
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
			return accepted
		await process_frame
	return {"status":"failed", "reason":"fixture_native_compile_wait_exhausted",
		"stage":"native_compile", "sectionKey":section_key, "generation":generation}

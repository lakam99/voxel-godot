extends SceneTree

const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const Provider := preload("res://scripts/world/OrdinaryStructureStaticSectionProvider.gd")
const PacketOwner := preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstallSession := preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const StructureSystemScript := preload("res://scripts/StructureSystem.gd")
const OwnerCompletion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const SECTION := Vector3i.ZERO
const MOVED_SECTION := Vector3i(0, -1, 0)
const WORLD_ID := "seed:ordinary-native-section-receipt:wood-corner-r1"
var _fixture_block_options: Dictionary = {}
const CELL := Vector3i(4, 0, 4)
const REPORT_ENV := "VOXEL_ORDINARY_STRUCTURE_NATIVE_RECEIPT_REPORT"
const COMPILE_ONLY_ENV := "VOXEL_ORDINARY_STRUCTURE_NATIVE_RECEIPT_COMPILE_ONLY"
const MAX_CAPTURE_AND_INSTALL_FRAMES := 900


class FixtureWorld extends Node3D:
	var chunks: Dictionary = {}
	var section_chunk: Node3D
	var section_backend: Node3D

	func get_static_section_render_owner(owner_cell: Vector2i,
			create_if_missing: bool) -> Dictionary:
		if owner_cell != Vector2i.ZERO:
			return {"status":"pending", "reason":"fixture_owner_cell_out_of_scope",
				"ownerCell":owner_cell}
		if not is_instance_valid(section_chunk) or not is_instance_valid(section_backend):
			return {"status":"pending", "reason":"fixture_native_section_owner_missing"}
		return {"status":"ready", "owner":section_chunk, "backend":section_backend}


class ProductionBlockConstructor extends "res://scripts/MainChunkTerrain.gd":
	var fixture_mesh: Mesh

	func block_visual_mesh(_material_key: String) -> Mesh:
		return fixture_mesh

	func block_visual_material(material_key: String) -> Material:
		return materials.get(material_key, materials.get("woodBlock")) as Material

	func sync_block_state_to_terrain(_cell: Vector3i, _block_type: String,
			_options: Dictionary = {}) -> void:
		pass

	func sync_block_light_to_terrain(_cell: Vector3i, _block_type: String) -> void:
		pass

	func register_navigation_marker_block(_cell: Vector3i, _body: Node3D,
			_block_type: String) -> void:
		pass

	func invalidate_navigation_marker_cache() -> void:
		pass


var report_path := ""
var checks: Dictionary = {}
var trace: Array[Dictionary] = []
var world: FixtureWorld
var constructor: ProductionBlockConstructor
var structure_system
var source_id := ""
var provider
var coordinator
var body: StaticBody3D
var collision: CollisionShape3D
var recipe_visuals: Array[MeshInstance3D] = []
var last_census: Dictionary = {}
var last_admission: Dictionary = {}
var last_install: Dictionary = {}
var pending_retention_samples: Array[Dictionary] = []
var pending_retention_all_visible := true
var pending_retention_frame_count := 0
var pre_receipt_pending_frame_count := 0
var pre_receipt_visuals_all_visible := true
var finish_started := false


func _initialize() -> void:
	report_path = OS.get_environment(REPORT_ENV)
	if OS.get_environment(COMPILE_ONLY_ENV) == "1":
		print("ORDINARY_STRUCTURE_NATIVE_RECEIPT_COMPILE_SMOKE loaded")
		quit(0)
		return
	call_deferred("_run")


func _run() -> void:
	world = FixtureWorld.new()
	world.name = "OrdinaryStructureNativeReceiptWorld"
	root.add_child(world)
	current_scene = world
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	world.add_child(chunk)
	world.section_chunk = chunk
	world.chunks[Vector2i.ZERO] = chunk
	var packet_result: Dictionary = PacketOwner.attach_to_chunk(chunk)
	world.section_backend = packet_result.get("backend") as Node3D
	_check("real_native_section_backend_attached",
		packet_result.get("status") == "ready"
		and is_instance_valid(world.section_backend)
		and world.section_backend.get_parent() == chunk,
		{"status":packet_result.get("status", ""),
			"backendInstanceId":world.section_backend.get_instance_id() \
				if is_instance_valid(world.section_backend) else 0,
			"backendParentName":world.section_backend.get_parent().name \
				if is_instance_valid(world.section_backend) \
				and world.section_backend.get_parent() != null else ""})
	if not checks.real_native_section_backend_attached.passed:
		_finish()
		return

	var camera := Camera3D.new()
	camera.position = Vector3(11.0, 8.0, 15.0)
	world.add_child(camera)
	camera.look_at(Vector3(5.4, 0.6, 5.4), Vector3.UP)
	camera.current = true
	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	world.add_child(key_light)

	constructor = ProductionBlockConstructor.new()
	constructor.name = "UnenteredProductionBlockConstructor"
	constructor.block_root = world
	constructor.blocks = {}
	constructor.fixture_mesh = BoxMesh.new()
	constructor.materials = {
		"woodBlock":StandardMaterial3D.new(),
		"trimWood":StandardMaterial3D.new()}
	_constructor_world_authority_setup()
	structure_system = StructureSystemScript.new()
	structure_system.main = constructor
	constructor.structure_system = structure_system
	_seed_known_empty_structure_regions()
	var fixture_town := {"key":"%d,%d" % [CELL.x, CELL.z],
		"centerX":CELL.x, "centerZ":CELL.z, "radius":3}
	constructor.town_region_cache[Vector2i.ZERO] = fixture_town
	source_id = "town:" + String(structure_system.call("town_key_for", fixture_town))

	var options := {"generated":true, "generatedTier":"ordinary_native_receipt_fixture",
		"generatedVisualSourceId":source_id, "world_x":float(CELL.x) * constructor.CELL,
		"world_y":float(CELL.y) * constructor.CELL,
		"world_z":float(CELL.z) * constructor.CELL,
		"accentRole":"cornerTimber", "cornerX":-1, "cornerZ":1,
		"cornerTrimMaterial":"trimWood"}
	_fixture_block_options = options.duplicate(true)
	structure_system.call("_begin_ordinary_visual_source", source_id)
	structure_system.set("active_structure_visual_source_id", source_id)
	body = constructor.create_block(CELL, "woodBlock", options)
	structure_system.call("_record_ordinary_visual_block", CELL, "woodBlock", body, options)
	structure_system.set("active_structure_visual_source_id", "")
	structure_system.call("_complete_ordinary_visual_source", source_id)
	if not is_instance_valid(body):
		_check("production_create_block_created_static_owner", false,
			{"reason":"production_create_block_returned_null"})
		_finish()
		return
	collision = _find_collision_shape_recursive(body)
	recipe_visuals = _recipe_visual_children(body)
	var recipe_segments := _recipe_segment_ids(recipe_visuals)
	var legacy_corner_count := _legacy_corner_visual_count(body)
	_check("unchanged_production_create_block_makes_exact_recipe_and_real_collision_owner",
		body is StaticBody3D and body.is_inside_tree()
		and body.get_meta("kind", "") == "block"
		and body.get_meta("cell", Vector3i(-1, -1, -1)) == CELL
		and body.get_meta("block_type", "") == "woodBlock"
		and constructor.blocks.get(CELL) == body
		and is_instance_valid(collision) and collision.shape is BoxShape3D
		and not collision.disabled
		and recipe_segments == ["base", "corner_timber_x", "corner_timber_z"]
		and _all_recipe_visuals_visible(recipe_visuals)
		and legacy_corner_count == 0,
		{"bodyInstanceId":body.get_instance_id(), "bodyClass":body.get_class(),
			"bodyChildren":_describe_children_recursive(body),
			"bodyMetadata":{"kind":body.get_meta("kind", ""),
				"cell":body.get_meta("cell", Vector3i.ZERO),
				"blockType":body.get_meta("block_type", "")},
			"blockMapOwnsBody":constructor.blocks.get(CELL) == body,
			"collisionExists":is_instance_valid(collision),
			"collisionDisabled":collision.disabled if is_instance_valid(collision) else true,
			"recipeSegments":recipe_segments, "legacyCornerVisualCount":legacy_corner_count})
	if not checks.unchanged_production_create_block_makes_exact_recipe_and_real_collision_owner.passed:
		_finish()
		return

	var town_cache: Dictionary = constructor.town_region_cache
	var source_row: Dictionary = structure_system.ordinary_visual_sources.get(source_id, {})
	var town_anchor: Dictionary = town_cache.get(Vector2i.ZERO, {})
	_check("single_fixture_source_is_complete_and_revisioned",
		source_row.get("completed", false)
		and source_row.get("expected", {}) == {CELL:"woodBlock"}
		and not town_anchor.is_empty()
		and source_id == "town:" + String(structure_system.call("town_key_for", town_anchor))
		and town_cache.size() >= 16,
		{"sourceId":source_id, "source":source_row,
			"discoverableTownAnchor":town_anchor,
			"knownTownRegions":town_cache.size(),
			"knownStandaloneRegions":structure_system.generated_structures.size()})
	if not checks.single_fixture_source_is_complete_and_revisioned.passed:
		_finish()
		return

	provider = Provider.new()
	var provider_setup: Dictionary = provider.configure(WORLD_ID, structure_system, constructor)
	coordinator = Coordinator.new()
	var coordinator_setup: Dictionary = coordinator.configure(WORLD_ID)
	var required_ids: Array[String] = [Provider.PROVIDER_ID]
	required_ids.make_read_only()
	var roster_setup: Dictionary = coordinator.configure_source_roster(required_ids)
	var provider_registration: Dictionary = coordinator.register_source_provider(
		Provider.PROVIDER_ID, provider, "capture_static_section_sources")
	_check("production_provider_and_coordinator_registered_in_explicit_isolation_roster",
		provider_setup.get("status") == "ready"
		and coordinator_setup.get("status") == "ready"
		and roster_setup.get("status") == "ready"
		and provider_registration.get("status") == "ready",
		{"provider":provider_setup, "coordinator":coordinator_setup,
			"roster":roster_setup, "registration":provider_registration,
			"requiredDomains":[Provider.PROVIDER_ID],
			"excludedDomains":["terrain", "blueprint_buildings", "ecology_and_static_props"]})
	if not checks.production_provider_and_coordinator_registered_in_explicit_isolation_roster.passed:
		_finish()
		return

	var target_member_id := "ordinary:%s:cell:%d,%d,%d" % [source_id, CELL.x, CELL.y, CELL.z]
	var target_identity_key := "section-part:" + var_to_bytes([target_member_id, target_member_id]).hex_encode()
	var capture_frame_count := 0
	var candidate_generation := 1
	var candidate_envelope: Dictionary = {}
	var census_gate_recorded := false
	for frame_index in range(MAX_CAPTURE_AND_INSTALL_FRAMES):
		capture_frame_count = frame_index + 1
		last_census = coordinator.capture_authoritative_source_census([SECTION])
		if last_census.get("status") != "complete":
			trace.append({"frame":Engine.get_process_frames(), "event":"provider_census_pending",
				"reason":String(last_census.get("reason", "")),
				"providerReason":String(last_census.get("providerReason", "")),
				"providerDetails":last_census.get("providerDetails", {})})
			await process_frame
			continue
		var census_sections: Array = last_census.get("sections", [])
		var expected_by_section: Dictionary = last_census.get(
			"expectedContributorsBySection", {})
		var census_member_ids: Array = expected_by_section.get(SECTION, [])
		var census_has_exact_member: bool = census_sections.has(SECTION) \
			and census_member_ids == [target_identity_key] \
			and last_census.get("sourceIdentities", {}).get(target_identity_key, {}) \
				== {"sourceId":target_member_id, "sourcePartId":target_member_id}
		_check("provider_only_census_is_complete_and_contains_exact_fixture_membership",
			census_has_exact_member,
			{"censusStatus":last_census.get("status", ""),
				"sectionIncluded":census_sections.has(SECTION),
				"sourcePartIds":census_member_ids,
				"expectedContributorIds":census_member_ids,
				"sourceRevisions":last_census.get("sourceRevisions", {})})
		census_gate_recorded = true
		if not census_has_exact_member:
			break
		last_admission = await _admit_compiled_candidate(coordinator,
			SECTION, candidate_generation)
		_record_pending_visual_retention("admission",
			String(last_admission.get("status", "")), candidate_generation)
		trace.append({"frame":Engine.get_process_frames(),
			"event":"ordinary_candidate_admission",
			"status":String(last_admission.get("status", "")),
			"reason":String(last_admission.get("reason", "")),
			"stage":String(last_admission.get("stage", ""))})
		if last_admission.get("status") == "queued":
			candidate_envelope = coordinator._production_candidate_jobs.get(SECTION, {}).get(
				"candidate", {})
			break
		if last_admission.get("status") == "failed":
			break
		await process_frame

	if not census_gate_recorded:
		if last_census.get("status") != "complete":
			last_census = coordinator.capture_authoritative_source_census([SECTION])
		if last_census.get("status") != "complete":
			_check("provider_only_census_is_complete_and_contains_exact_fixture_membership",
				false, {"census":last_census,
					"providerProgress":provider.membership_census_stats()})
		else:
			var final_sections: Array = last_census.get("sections", [])
			var final_expected_by_section: Dictionary = last_census.get(
				"expectedContributorsBySection", {})
			var final_ids: Array = final_expected_by_section.get(SECTION, [])
			_check("provider_only_census_is_complete_and_contains_exact_fixture_membership",
				final_sections.has(SECTION) and final_ids == [target_identity_key] \
					and last_census.get("sourceIdentities", {}).get(target_identity_key, {}) \
						== {"sourceId":target_member_id, "sourcePartId":target_member_id},
				{"censusStatus":last_census.get("status", ""),
					"sectionIncluded":final_sections.has(SECTION),
					"sourcePartIds":final_ids,
					"expectedContributorIds":final_ids,
					"sourceRevisions":last_census.get("sourceRevisions", {})})
			census_gate_recorded = true

	if candidate_envelope.is_empty():
		_check("complete_candidate_admitted_from_actual_ordinary_provider",
			last_admission.get("status") == "queued", {
				"admission":last_admission, "lastCensus":last_census,
				"providerProgress":provider.membership_census_stats(),
				"traceTail":trace.slice(maxi(0, trace.size() - 8))})
		_finish()
		return
	_check("complete_candidate_admitted_from_actual_ordinary_provider",
		last_admission.get("status") == "queued"
		and candidate_envelope.get("sectionKey") == SECTION
		and candidate_envelope.get("generation") == candidate_generation,
		{"admission":last_admission,
			"candidateCensusDigest":candidate_envelope.get("censusDigest", ""),
			"candidateManifestDigest":candidate_envelope.get("contentManifestDigest", "")})

	var installed_outcome: Dictionary = {}
	var installed_frame_count := 0
	for frame_index in range(MAX_CAPTURE_AND_INSTALL_FRAMES):
		installed_frame_count = frame_index + 1
		last_install = coordinator.advance_complete_section_candidate(SECTION, 8)
		_record_pending_visual_retention("install",
			String(last_install.get("status", "")), candidate_generation)
		trace.append({"frame":Engine.get_process_frames(), "event":"native_candidate_install",
			"status":String(last_install.get("status", "")),
			"reason":String(last_install.get("reason", "")),
			"stage":String(last_install.get("stage", ""))})
		if last_install.get("status") in ["installed", "failed", "cancelled"]:
			installed_outcome = last_install
			break
		await process_frame
	_check("old_recipe_visuals_remain_visible_until_native_receipt_current",
		pending_retention_frame_count > 0 and pre_receipt_pending_frame_count > 0
		and pending_retention_all_visible and pre_receipt_visuals_all_visible,
		{"pendingFrameCount":pending_retention_frame_count,
			"preReceiptPendingFrameCount":pre_receipt_pending_frame_count,
			"allPendingFramesRetainedOldVisuals":pending_retention_all_visible,
			"allPreReceiptPendingFramesVisible":pre_receipt_visuals_all_visible,
			"sampledFrames":pending_retention_samples.size(),
			"samples":pending_retention_samples,
			"limit":MAX_CAPTURE_AND_INSTALL_FRAMES})

	var production_candidate: Dictionary = coordinator._production_candidates_by_section.get(
		SECTION, {})
	var snapshot: Dictionary = production_candidate.get("candidate", {}).get("snapshot", {})
	var manifest_part_ids: Array[String] = []
	for manifest_value: Variant in snapshot.get("manifest", []):
		if manifest_value is Dictionary:
			manifest_part_ids.append(String(manifest_value.get("sourcePartId", "")))
	var receipt: Dictionary = coordinator._production_candidate_receipts.get(SECTION, {})
	var slot_id := InstallSession.slot_id(WORLD_ID, SECTION)
	var native_snapshot: Dictionary = world.section_backend.call("installed_snapshot", slot_id)
	var native_receipt_valid: bool = native_snapshot.get("status") == "ready" \
		and int(native_snapshot.get("generation", 0)) == candidate_generation \
		and world.section_backend.call("receipt_installed", slot_id, candidate_generation,
			String(receipt.get("sourceRevision", "")),
			String(production_candidate.get("contentManifestDigest", "")))
	_check("ordinary_member_is_in_manifest_and_has_current_native_renderer_receipt",
		installed_outcome.get("status") == "installed"
		and manifest_part_ids.has(target_member_id)
		and receipt.get("status") == "installed"
		and receipt.get("sectionKey") == SECTION
		and receipt.is_read_only()
		and native_receipt_valid,
		{"outcome":installed_outcome, "candidateManifestSourcePartIds":manifest_part_ids,
			"receipt":receipt, "nativeSnapshot":native_snapshot,
			"nativeReceiptValid":native_receipt_valid,
			"contentManifestDigest":production_candidate.get("contentManifestDigest", ""),
			"captureFrameCount":capture_frame_count,
			"installFrameCount":installed_frame_count})

	var final_recipe_segments := _recipe_segment_ids(_recipe_visual_children(body))
	var retired_all_recipe_visuals := true
	for visual: MeshInstance3D in _recipe_visual_children(body):
		retired_all_recipe_visuals = retired_all_recipe_visuals and not visual.visible \
			and bool(visual.get_meta("ordinary_structure_section_owned", false))
	_check("native_receipt_retires_recipe_visuals_and_retains_same_body_with_enabled_collider",
		installed_outcome.get("status") == "installed"
		and constructor.blocks.get(CELL) == body and is_instance_valid(body)
		and body.get_meta("kind", "") == "block"
		and body.get_meta("cell", Vector3i(-1, -1, -1)) == CELL
		and body.get_meta("block_type", "") == "woodBlock"
		and is_instance_valid(collision) and not collision.disabled
		and final_recipe_segments == ["base", "corner_timber_x", "corner_timber_z"]
		and retired_all_recipe_visuals
		and _legacy_corner_visual_count(body) == 0,
		{"bodyInstanceId":body.get_instance_id(),
			"sameBodyStillMapped":constructor.blocks.get(CELL) == body,
			"bodyMetadata":{"kind":body.get_meta("kind", ""),
				"cell":body.get_meta("cell", Vector3i.ZERO),
				"blockType":body.get_meta("block_type", "")},
			"collisionEnabled":is_instance_valid(collision) and not collision.disabled,
			"recipeSegments":final_recipe_segments,
			"allRecipeVisualsRetired":retired_all_recipe_visuals,
			"legacyCornerVisualCount":_legacy_corner_visual_count(body),
			"providerAcknowledgement":installed_outcome.get("sourceAcknowledgements", {})})
	if native_receipt_valid and retired_all_recipe_visuals:
		await _exercise_coordinator_release_and_replay(receipt)
	_finish()


func _exercise_coordinator_release_and_replay(prior_receipt: Dictionary) -> void:
	var prior_coverage: Array = coordinator._production_candidates_by_section.get(SECTION, {}).get(
		"providerCoverage", [])
	var old_owner_id := world.section_chunk.get_instance_id()
	var old_backend_id := world.section_backend.get_instance_id()
	var owner_retirement: Dictionary = coordinator.request_stream_chunk_owner_retirement(Vector2i.ZERO, old_owner_id)
	var owner_unload_count := int(owner_retirement.get("queuedWorkCount", 0))
	var restored := true
	for visual: MeshInstance3D in _recipe_visual_children(body):
		restored = restored and visual.visible
	_check("coordinator_owner_unload_restores_real_recipe_before_renderer_destruction",
		owner_retirement.get("status") == "ready" and owner_unload_count > 0 and restored \
			and not coordinator.installed_section_receipt_is_current(SECTION, prior_receipt),
		{"retirement":owner_retirement, "unloadCount":owner_unload_count, "visualsRestored":restored,
			"oldOwnerId":old_owner_id, "oldBackendId":old_backend_id})
	if owner_retirement.get("status") != "ready": return
	var slot := InstallSession.slot_id(WORLD_ID, SECTION)
	var cleanup: Dictionary = world.section_backend.call("release_packet", slot,
		int(prior_receipt.get("generation", 0)))
	await process_frame
	await RenderingServer.frame_post_draw
	var old_owner := world.section_chunk
	world.section_chunk = null
	world.section_backend = null
	world.chunks.erase(Vector2i.ZERO)
	old_owner.free()
	var replacement_owner := Node3D.new()
	replacement_owner.name = "Chunk_0_0"
	world.add_child(replacement_owner)
	world.section_chunk = replacement_owner
	world.chunks[Vector2i.ZERO] = replacement_owner
	var attachment: Dictionary = PacketOwner.attach_to_chunk(replacement_owner)
	world.section_backend = attachment.get("backend") as Node3D
	coordinator.notify_stream_chunk_loaded(Vector2i.ZERO)
	var replay_result: Dictionary = {}
	for frame in range(MAX_CAPTURE_AND_INSTALL_FRAMES):
		replay_result = coordinator.advance_complete_section_candidate(SECTION, 8)
		if replay_result.get("status") in ["installed", "failed", "cancelled"]: break
		await process_frame
	var current_receipt: Dictionary = coordinator._production_candidate_receipts.get(SECTION, {})
	var replay_hidden := true
	for visual: MeshInstance3D in _recipe_visual_children(body):
		replay_hidden = replay_hidden and not visual.visible
	_check("real_ordinary_provider_replay_installs_fresh_renderer_owner_then_retires_recipe",
		cleanup.get("status") == "released" and attachment.get("status") == "ready" \
			and replay_result.get("status") == "installed" and replay_hidden \
			and int(current_receipt.get("chunkInstanceId", 0)) != old_owner_id \
			and int(current_receipt.get("backendInstanceId", 0)) != old_backend_id \
			and coordinator.installed_section_receipt_is_current(SECTION, current_receipt) \
			and constructor.blocks.get(CELL) == body and is_instance_valid(collision) \
			and not collision.disabled,
		{"cleanup":cleanup, "replay":replay_result, "receipt":current_receipt,
			"sameCollisionOwner":constructor.blocks.get(CELL) == body})
	var stale_release: Dictionary = {}
	# Use the original provider coverage claim, not an invented release token.
	for coverage: Array in prior_coverage:
		if coverage.size() >= 3 and coverage[0] == Provider.PROVIDER_ID:
			stale_release = provider.release_section_install(SECTION,
				String(coverage[1]), prior_receipt)
	var hidden_after_stale_release := true
	for visual: MeshInstance3D in _recipe_visual_children(body):
		hidden_after_stale_release = hidden_after_stale_release and not visual.visible
	_check("delayed_prior_owner_release_cannot_restore_current_native_replacement",
		stale_release.get("status") == "acknowledged" \
			and stale_release.get("reason") == "ordinary_section_release_claim_replaced" \
			and hidden_after_stale_release \
			and coordinator.installed_section_receipt_is_current(SECTION, current_receipt),
		{"release":stale_release, "currentReceipt":current_receipt})
	if replay_result.get("status") == "installed" and replay_hidden:
		await _exercise_identical_body_replacement(current_receipt)


func _exercise_identical_body_replacement(old_receipt: Dictionary) -> void:
	# Renderer contract fixture: recreate the real production recipe owner with
	# identical durable source inputs, without pretending this is a gameplay edit.
	var part_id := "ordinary:" + source_id + ":cell:%d,%d,%d" % [CELL.x, CELL.y, CELL.z]
	var old_roster: Dictionary = provider._geometry_owner_rosters.get(part_id, {})
	var old_body_id := body.get_instance_id()
	var old_recipe_digest := String(body.get_meta("ordinary_structure_recipe_content_digest", ""))
	constructor.blocks.erase(CELL)
	body.queue_free()
	await process_frame
	body = constructor.create_block(CELL, "woodBlock", _fixture_block_options)
	collision = _find_collision_shape_recursive(body)
	var capture: Dictionary = {}
	for frame: int in range(MAX_CAPTURE_AND_INSTALL_FRAMES):
		capture = coordinator.capture_authoritative_source_census([SECTION])
		if capture.get("status") in ["complete", "failed"]: break
		await process_frame
	var new_roster: Dictionary = provider._geometry_owner_rosters.get(part_id, {})
	var old_proof: Dictionary = coordinator.validate_geometry_owner_completion(new_roster, [old_roster])
	var retained_native: Dictionary = world.section_backend.call("installed_snapshot", InstallSession.slot_id(WORLD_ID, SECTION))
	_check("identical_body_replacement_changes_admitted_revision_and_rejects_old_native_receipt",
		capture.get("status") == "complete" and not new_roster.is_empty() \
			and body.get_instance_id() != old_body_id \
			and String(body.get_meta("ordinary_structure_recipe_content_digest", "")) == old_recipe_digest \
			and new_roster.get("sourceRevision") != old_roster.get("sourceRevision") \
			and old_proof.get("status") == "pending" \
			and retained_native.get("status") == "ready" \
			and retained_native.get("generation") == old_receipt.get("generation") \
			and _all_recipe_visuals_visible(_recipe_visual_children(body)),
		{"oldBodyId":old_body_id, "newBodyId":body.get_instance_id(),
			"oldRevision":old_roster.get("sourceRevision"), "newRevision":new_roster.get("sourceRevision"),
			"completion":old_proof, "oldReceipt":old_receipt, "retainedNative":retained_native})
	if capture.get("status") != "complete" or old_proof.get("status") != "pending": return
	var replacement_admission: Dictionary = await _admit_compiled_candidate(coordinator,
		SECTION, int(old_receipt.get("generation", 0)) + 1)
	_check("replacement_body_candidate_is_admitted_from_current_coordinator_census",
		replacement_admission.get("status") == "queued", replacement_admission)
	if replacement_admission.get("status") != "queued": return
	var submitted_candidate: Dictionary = coordinator._production_candidate_jobs.get(SECTION, {}).get("candidate", {})
	var expected_native_revision := "%s:%d" % [String(submitted_candidate.get("worldId", "")),
		int(submitted_candidate.get("generation", 0))]
	if int(submitted_candidate.get("translucentPovRevision", 0)) > 0:
		expected_native_revision += ":pov:%d" % int(submitted_candidate.translucentPovRevision)
	var replacement: Dictionary = {}
	var pending_samples: Array[Dictionary] = []
	var old_slot_retained_with_fallback := true
	for frame: int in range(MAX_CAPTURE_AND_INSTALL_FRAMES):
		replacement = coordinator.advance_complete_section_candidate(SECTION, 12)
		if replacement.get("status") in ["installed", "failed", "cancelled"]: break
		var physical: Dictionary = world.section_backend.call("installed_snapshot", InstallSession.slot_id(WORLD_ID, SECTION))
		var presentation: Dictionary = world.section_backend.call("pending_presentation_snapshot", InstallSession.slot_id(WORLD_ID, SECTION))
		var previous: Dictionary = presentation.get("previousReceipt", {})
		var fallback_visible := _all_recipe_visuals_visible(_recipe_visual_children(body))
		var before_commit: bool = physical.get("status") == "ready" \
			and physical.get("generation") == old_receipt.get("generation") \
			and physical.get("sourceRevision") == old_receipt.get("sourceRevision") \
			and physical.get("rootInstanceId") == retained_native.get("rootInstanceId") \
			and physical.get("packetDigest") == old_receipt.get("contentManifestDigest")
		var retained_for_rollback: bool = presentation.get("status") == "pending_presentation" \
			and bool(presentation.get("hasPrevious", false)) \
			and presentation.get("generation") == int(old_receipt.get("generation", 0)) + 1 \
			and presentation.get("sourceRevision") == expected_native_revision \
			and presentation.get("packetDigest") == submitted_candidate.get("contentManifestDigest") \
			and int(presentation.get("rootInstanceId", 0)) > 0 \
			and presentation.get("rootInstanceId") != retained_native.get("rootInstanceId") \
			and presentation.get("previousGeneration") == old_receipt.get("generation") \
			and int(presentation.get("previousRootInstanceId", 0)) == int(retained_native.get("rootInstanceId", -1)) \
			and previous.get("status") == "retained_previous" \
			and previous.get("generation") == old_receipt.get("generation") \
			and previous.get("sourceRevision") == old_receipt.get("sourceRevision") \
			and previous.get("rootInstanceId") == retained_native.get("rootInstanceId") \
			and previous.get("packetDigest") == old_receipt.get("contentManifestDigest")
		old_slot_retained_with_fallback = old_slot_retained_with_fallback \
			and fallback_visible and (before_commit or retained_for_rollback)
		if pending_samples.size() < 64:
			pending_samples.append({"frame":frame, "status":replacement.get("status"),
				"beforeCommit":before_commit, "retainedForRollback":retained_for_rollback,
				"newRecipeVisible":fallback_visible, "presentation":presentation})
		await process_frame
	var all_hidden := true
	for visual: MeshInstance3D in _recipe_visual_children(body): all_hidden = all_hidden and not visual.visible
	var new_receipt: Dictionary = coordinator._production_candidate_receipts.get(SECTION, {})
	var exact_native: bool = world.section_backend.call("receipt_installed",
		InstallSession.slot_id(WORLD_ID, SECTION), int(new_receipt.get("generation", 0)),
		String(new_receipt.get("sourceRevision", "")), String(new_receipt.get("contentManifestDigest", "")))
	var settled: Dictionary = coordinator.source_install_acknowledgement_proof(SECTION, new_receipt)
	_check("replacement_body_retires_only_after_new_native_geometry_owner_receipt",
		replacement.get("status") == "installed" and all_hidden \
			and exact_native and old_slot_retained_with_fallback and not pending_samples.is_empty() \
			and settled.get("status") == "ready" \
			and new_receipt.get("generation") != old_receipt.get("generation") \
			and new_receipt.get("contentManifestDigest") != old_receipt.get("contentManifestDigest") \
			and constructor.blocks.get(CELL) == body and is_instance_valid(collision) and not collision.disabled,
		{"replacement":replacement, "allRecipeVisualsRetired":all_hidden,
			"bodyInstanceId":body.get_instance_id(), "newReceipt":new_receipt,
			"exactNativeReceipt":exact_native, "pendingRetentionSamples":pending_samples, "settlement":settled})
	if checks.replacement_body_retires_only_after_new_native_geometry_owner_receipt.passed:
		await _exercise_moved_and_deleted_member()


## Direct production-source mutation in an isolated renderer fixture. This is
## not evidence of player movement, building interactions, or save/reload.
func _exercise_moved_and_deleted_member() -> void:
	var part_id := "ordinary:" + source_id + ":cell:%d,%d,%d" % [CELL.x, CELL.y, CELL.z]
	var prior_roster: Dictionary = provider._geometry_owner_rosters.get(part_id, {})
	var moved_options := _fixture_block_options.duplicate(true)
	moved_options["world_y"] = -4.0
	constructor.blocks.erase(CELL)
	body.queue_free()
	await process_frame
	body = constructor.create_block(CELL, "woodBlock", moved_options)
	collision = body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	structure_system.active_structure_visual_source_id = source_id
	structure_system._record_ordinary_visual_block(CELL, "woodBlock", body, moved_options)
	structure_system.active_structure_visual_source_id = ""
	var moved_census: Dictionary = await _capture_lifecycle_sections([SECTION, MOVED_SECTION])
	var moved_roster: Dictionary = provider._geometry_owner_rosters.get(part_id, {})
	var identity := "section-part:" + var_to_bytes([part_id, part_id]).hex_encode()
	var moved_revision := String(moved_roster.get("sourceRevision", ""))
	_check("moved_member_has_same_identity_and_current_revision_in_new_and_departed_sections",
		moved_census.get("status") == "complete" and OwnerCompletion.validate(moved_roster) \
		and OwnerCompletion.owner_sections(moved_roster) == [MOVED_SECTION] \
		and moved_revision != String(prior_roster.get("sourceRevision", "")) \
		and moved_census.get("sourceRevisions", {}).get(identity) == moved_revision \
		and moved_census.get("removalRevisions", {}).get(identity) == moved_revision,
		{"census":moved_census, "priorRoster":prior_roster, "movedRoster":moved_roster})
	if not checks.moved_member_has_same_identity_and_current_revision_in_new_and_departed_sections.passed: return
	var moved_install: Dictionary = await _install_lifecycle_sections([MOVED_SECTION, SECTION])
	var departed_native: Dictionary = world.section_backend.call("installed_snapshot", InstallSession.slot_id(WORLD_ID, SECTION))
	var moved_native: Dictionary = world.section_backend.call("installed_snapshot", InstallSession.slot_id(WORLD_ID, MOVED_SECTION))
	var moved_completion: Dictionary = coordinator.validate_geometry_owner_completion(moved_roster, [prior_roster])
	_check("moved_member_installs_new_owner_and_explicitly_empties_departed_native_owner",
		moved_install.get("status") == "installed" and moved_completion.get("status") == "ready" \
		and bool(moved_install.get("legacyRetentionValid", false)) \
		and departed_native.get("status") == "ready" and int(departed_native.get("instanceCount", -1)) == 0 \
		and moved_native.get("status") == "ready" and int(moved_native.get("instanceCount", 0)) == 3,
		{"install":moved_install, "completion":moved_completion,
			"departedNative":departed_native, "movedNative":moved_native})
	if not checks.moved_member_installs_new_owner_and_explicitly_empties_departed_native_owner.passed: return
	# This is the ordinary durable removal authority; a missing body alone must
	# never be admitted as an empty world member.
	structure_system.generated_visual_block_removed(body)
	constructor.blocks.erase(CELL)
	body.queue_free()
	await process_frame
	var deletion_census: Dictionary = await _capture_lifecycle_sections([SECTION, MOVED_SECTION])
	var empty_roster: Dictionary = provider._geometry_owner_rosters.get(part_id, {})
	var deletion_revision := String(empty_roster.get("sourceRevision", ""))
	_check("durable_member_deletion_admits_explicit_empty_roster_and_retains_previous_owner_proof",
		deletion_census.get("status") == "complete" and OwnerCompletion.validate(empty_roster) \
		and bool(empty_roster.get("explicitRemoval", false)) and empty_roster.get("members", []).is_empty() \
		and deletion_revision != moved_revision \
		and deletion_census.get("removalRevisions", {}).get(identity) == deletion_revision \
		and moved_roster in provider._geometry_owner_prior_rosters.get(part_id, []),
		{"census":deletion_census, "emptyRoster":empty_roster,
			"priorRosters":provider._geometry_owner_prior_rosters.get(part_id, [])})
	if not checks.durable_member_deletion_admits_explicit_empty_roster_and_retains_previous_owner_proof.passed: return
	var deleted_install: Dictionary = await _install_lifecycle_sections([MOVED_SECTION, SECTION])
	var empty_native: Dictionary = world.section_backend.call("installed_snapshot", InstallSession.slot_id(WORLD_ID, MOVED_SECTION))
	var deleted_completion: Dictionary = coordinator.validate_geometry_owner_completion(empty_roster, [moved_roster, prior_roster])
	var revision_before_unrelated := int(structure_system.ordinary_visual_revision)
	structure_system._begin_ordinary_visual_source("fixture:unrelated-deletion-stability")
	structure_system._complete_ordinary_visual_source("fixture:unrelated-deletion-stability")
	var repeated_census: Dictionary = await _capture_lifecycle_sections([SECTION, MOVED_SECTION])
	_check("durable_deletion_clears_native_geometry_and_preserves_stable_tombstones_after_ack",
		deleted_install.get("status") == "installed" and deleted_completion.get("status") == "ready" \
		and empty_native.get("status") == "ready" and int(empty_native.get("instanceCount", -1)) == 0 \
		and repeated_census.get("status") == "complete" \
		and int(structure_system.ordinary_visual_revision) > revision_before_unrelated \
		and repeated_census.get("removalRevisions", {}).get(identity) == deletion_revision,
		{"install":deleted_install, "completion":deleted_completion,
			"nativeEmpty":empty_native, "repeatedCensus":repeated_census,
			"unrelatedRevisionBefore":revision_before_unrelated,
			"unrelatedRevisionAfter":structure_system.ordinary_visual_revision})


func _capture_lifecycle_sections(sections: Array) -> Dictionary:
	var census: Dictionary = {}
	for frame in MAX_CAPTURE_AND_INSTALL_FRAMES:
		census = coordinator.capture_authoritative_source_census(sections)
		if census.get("status") in ["complete", "failed"]: return census
		await process_frame
	return census


func _install_lifecycle_sections(sections: Array) -> Dictionary:
	var admissions: Dictionary = {}
	for section: Vector3i in sections:
		var prior_receipt: Dictionary = coordinator._production_candidate_receipts.get(section, {})
		var generation := int(prior_receipt.get("generation", 0)) + 1
		var admitted: Dictionary = await _admit_compiled_candidate(coordinator, section, generation, false)
		admissions[section] = admitted
		if admitted.get("status") != "queued": return {"status":"failed", "admissions":admissions}
	var results: Dictionary = {}
	var legacy_retention_valid := true
	var retention_samples: Array[Dictionary] = []
	for frame in MAX_CAPTURE_AND_INSTALL_FRAMES:
		var complete := true
		for section: Vector3i in sections:
			if results.get(section, {}).get("status") == "installed": continue
			var result: Dictionary = coordinator.advance_complete_section_candidate(section, 12)
			results[section] = result
			if result.get("status") in ["failed", "cancelled"]:
				return {"status":"failed", "admissions":admissions, "results":results}
			if result.get("status") != "installed": complete = false
		if is_instance_valid(body) and not body.is_queued_for_deletion():
			var visible := true
			for visual: MeshInstance3D in _recipe_visual_children(body): visible = visible and visual.visible
			var part_id := "ordinary:" + source_id + ":cell:%d,%d,%d" % [CELL.x, CELL.y, CELL.z]
			var roster: Dictionary = provider._geometry_owner_rosters.get(part_id, {})
			var owner_proof: Dictionary = coordinator.validate_geometry_owner_completion(roster,
				provider._geometry_owner_prior_rosters.get(part_id, []))
			legacy_retention_valid = legacy_retention_valid and (visible or owner_proof.get("status") == "ready")
			if retention_samples.size() < 32:
				retention_samples.append({"frame":frame, "legacyVisible":visible, "completion":owner_proof.get("status")})
		if complete: return {"status":"installed", "admissions":admissions, "results":results,
			"legacyRetentionValid":legacy_retention_valid, "retentionSamples":retention_samples}
		await process_frame
	return {"status":"pending", "admissions":admissions, "results":results}


func _constructor_world_authority_setup() -> void:
	constructor.seed_text = "ordinary-native-section-receipt-fixture"
	constructor.town_region_cache = {}
	constructor.generated_block_cells_by_column = {}
	constructor.light_safety_sources = {}
	constructor.light_safety_sources_initialized = false
	constructor.world_generation_system = null
	constructor.npc_system = null
	constructor.world_edit_followup_queue = null


func _seed_known_empty_structure_regions() -> void:
	for z in range(-3, 3):
		for x in range(-3, 3):
			var key := Vector2i(x, z)
			constructor.town_region_cache[key] = {}
			structure_system.generated_structures[key] = false


func _recipe_visual_children(owner_body: StaticBody3D) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if not is_instance_valid(owner_body):
		return result
	for child_value: Variant in owner_body.get_children():
		var mesh := child_value as MeshInstance3D
		if is_instance_valid(mesh) and mesh.mesh != null \
				and not String(mesh.get_meta("ordinary_structure_recipe_segment_id", "")).is_empty():
			result.append(mesh)
	return result


func _find_collision_shape_recursive(parent: Node) -> CollisionShape3D:
	if not is_instance_valid(parent):
		return null
	for child: Node in parent.get_children():
		var collision_shape := child as CollisionShape3D
		if is_instance_valid(collision_shape):
			return collision_shape
		var nested := _find_collision_shape_recursive(child)
		if is_instance_valid(nested):
			return nested
	return null


func _describe_children_recursive(parent: Node) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not is_instance_valid(parent):
		return result
	for child: Node in parent.get_children():
		result.append({"name":String(child.name), "class":child.get_class(),
			"path":String(parent.get_path_to(child))})
		result.append_array(_describe_children_recursive(child))
	return result


func _recipe_segment_ids(visuals: Array[MeshInstance3D]) -> Array[String]:
	var result: Array[String] = []
	for visual: MeshInstance3D in visuals:
		result.append(String(visual.get_meta("ordinary_structure_recipe_segment_id", "")))
	result.sort()
	return result


func _all_recipe_visuals_visible(visuals: Array[MeshInstance3D]) -> bool:
	if visuals.is_empty():
		return false
	for visual: MeshInstance3D in visuals:
		if not visual.visible:
			return false
	return true


func _record_pending_visual_retention(phase: String, status: String,
		candidate_generation: int) -> void:
	if status not in ["pending", "queued", "waiting", "pending_owner"]:
		return
	var visible := _all_recipe_visuals_visible(_recipe_visual_children(body))
	var candidate_receipt_current := _candidate_native_receipt_is_current(candidate_generation)
	var retained := is_instance_valid(body) and (candidate_receipt_current or visible)
	pending_retention_all_visible = pending_retention_all_visible and retained
	pending_retention_frame_count += 1
	if not candidate_receipt_current:
		pre_receipt_pending_frame_count += 1
		pre_receipt_visuals_all_visible = pre_receipt_visuals_all_visible \
			and visible and is_instance_valid(body)
	if pending_retention_samples.size() < 64:
		pending_retention_samples.append({"phase":phase, "status":status,
			"frame":Engine.get_process_frames(), "visible":visible,
			"bodyInstanceId":body.get_instance_id() if is_instance_valid(body) else 0,
			"candidateReceiptCurrent":candidate_receipt_current,
			"retained":retained})


func _candidate_native_receipt_is_current(candidate_generation: int) -> bool:
	if not is_instance_valid(world) or not is_instance_valid(world.section_backend) \
			or not is_instance_valid(coordinator):
		return false
	var receipt: Dictionary = coordinator._production_candidate_receipts.get(SECTION, {})
	var candidate: Dictionary = coordinator._production_candidates_by_section.get(SECTION, {})
	var manifest_digest := String(candidate.get("contentManifestDigest", ""))
	if receipt.get("status") != "installed" or manifest_digest.is_empty():
		return false
	return world.section_backend.call("receipt_installed",
		InstallSession.slot_id(WORLD_ID, SECTION), candidate_generation,
		String(receipt.get("sourceRevision", "")), manifest_digest)


func _legacy_corner_visual_count(owner_body: StaticBody3D) -> int:
	var count := 0
	if not is_instance_valid(owner_body):
		return count
	for child_value: Variant in owner_body.get_children():
		var mesh := child_value as MeshInstance3D
		if is_instance_valid(mesh) and mesh.mesh != null \
				and String(mesh.get_meta("visual_role", "")) == "cornerTimber" \
				and String(mesh.get_meta("ordinary_structure_recipe_segment_id", "")).is_empty():
			count += 1
	return count


func _check(name: String, passed: bool, evidence: Variant) -> void:
	checks[name] = {"passed":passed, "evidence":evidence}


func _finish() -> void:
	if not checks.has("durable_deletion_clears_native_geometry_and_preserves_stable_tombstones_after_ack"):
		_check("complete_release_replay_and_body_replacement_act_reached", false,
			{"reason":"required_lifecycle_act_did_not_reach_final_assertion"})
	if finish_started:
		return
	finish_started = true
	var failed: Array[String] = []
	for name: String in checks:
		if not bool(checks[name].get("passed", false)):
			failed.append(name)
	var report := {"schema":"ordinary-structure-native-section-receipt-fixture/v1",
		"passed":failed.is_empty(), "checkCount":checks.size(), "checks":checks,
		"failedChecks":failed,
		"evidenceLevel":"headed isolated production MainChunkTerrain.create_block and actual ordinary provider/coordinator/native renderer receipt for one synthetic one-cell town source anchored to a discoverable town-cache record; only ordinary-structures is in the fixture roster",
		"doesNotProve":"Full-world provider roster, terrain/ecology/Citadel co-coverage, generated-town production layout, player interaction action, save/reload, edit/tombstone replay, chunk unload/replay, normal startup/loading, traversal, visual parity beyond the fixture member, or runtime performance.",
		"lastAdmission":last_admission.duplicate(true),
		"lastInstall":last_install.duplicate(true),
		"pendingVisualRetention":{"pendingFrameCount":pending_retention_frame_count,
			"preReceiptPendingFrameCount":pre_receipt_pending_frame_count,
			"allVisibleUntilNativeReceiptCurrent":pending_retention_all_visible,
			"allPreReceiptPendingFramesVisible":pre_receipt_visuals_all_visible,
			"samples":pending_retention_samples.duplicate(true)},
		"providerProgress":provider.membership_census_stats() if is_instance_valid(provider) else {},
		"traceCount":trace.size(),
		"traceTail":trace.slice(maxi(0, trace.size() - 32))}
	call_deferred("_teardown_and_quit", report, 0 if failed.is_empty() else 1)


func _teardown_and_quit(report: Dictionary, exit_code: int) -> void:
	var slot_id := InstallSession.slot_id(WORLD_ID, SECTION)
	var release_result := {"status":"missing", "reason":"backend_not_created"}
	var cancellation_result: Dictionary = {}
	var backend_metrics: Dictionary = {}
	var post_release_snapshot: Dictionary = {}
	var moved_release_result: Dictionary = {"status":"missing"}
	var backend_retirement_drained := true
	var backend: Node3D
	if is_instance_valid(world) and is_instance_valid(world.section_backend):
		backend = world.section_backend
		if is_instance_valid(coordinator):
			for owned_section: Vector3i in [SECTION, MOVED_SECTION]:
				var job: Dictionary = coordinator._production_candidate_jobs.get(owned_section, {})
				var session: Variant = job.get("session", null)
				if session is RefCounted and session.has_method("cancel"):
					var cancelled: Dictionary = session.call("cancel")
					if cancellation_result.is_empty() or cancelled.get("status") != "cancelled":
						cancellation_result = cancelled
		var installed_snapshot: Dictionary = backend.call("installed_snapshot", slot_id)
		var installed_generation := int(installed_snapshot.get("generation", 0))
		var installed_status := String(installed_snapshot.get("status", ""))
		if installed_status == "ready" and installed_generation > 0:
			release_result = backend.call("release_packet", slot_id, installed_generation)
		elif installed_status == "missing":
			release_result = {"status":"missing", "snapshotStatus":installed_status}
		else:
			release_result = {"status":"failed",
				"reason":"unexpected_installed_snapshot_state",
				"snapshot":installed_snapshot}
		var moved_slot := InstallSession.slot_id(WORLD_ID, MOVED_SECTION)
		var moved_snapshot: Dictionary = backend.call("installed_snapshot", moved_slot)
		if moved_snapshot.get("status") == "ready":
			moved_release_result = backend.call("release_packet", moved_slot, int(moved_snapshot.get("generation", 0)))
		elif moved_snapshot.get("status") != "missing":
			moved_release_result = {"status":"failed", "snapshot":moved_snapshot}
		await process_frame
		await RenderingServer.frame_post_draw
		post_release_snapshot = backend.call("installed_snapshot", slot_id)
		backend_metrics = backend.call("metrics")
		backend_retirement_drained = post_release_snapshot.get("status") == "missing" \
			and int(backend_metrics.get("installedPackets", -1)) == 0 \
			and int(backend_metrics.get("stagedPackets", -1)) == 0 \
			and int(backend_metrics.get("retiringRoots", -1)) == 0

	# The coordinator owns the roster/provider, and the provider retains the
	# geometry capture's mesh/material resources. Drop those owners before freeing
	# the fixture's separately allocated, never-parented production constructor.
	coordinator = null
	provider = null
	last_census = {}
	last_admission = {}
	last_install = {}
	trace = []
	pending_retention_samples = []
	if is_instance_valid(structure_system):
		structure_system.main = null
	if is_instance_valid(constructor):
		constructor.structure_system = null
		constructor.block_root = null
		constructor.blocks = {}
		constructor.materials = {}
		constructor.fixture_mesh = null
		constructor.free()
	constructor = null
	structure_system = null
	recipe_visuals = []
	body = null
	collision = null
	var world_weak: WeakRef
	if is_instance_valid(world):
		world_weak = weakref(world)
		current_scene = null
		world.queue_free()
	world = null
	await process_frame
	await RenderingServer.frame_post_draw

	var world_freed := world_weak == null or world_weak.get_ref() == null
	var cleanup_passed: bool = release_result.get("status") in ["released", "missing"] \
		and moved_release_result.get("status") in ["released", "missing"] \
		and backend_retirement_drained and world_freed \
		and (cancellation_result.is_empty() or cancellation_result.get("status") == "cancelled")
	var checks_report: Dictionary = report.get("checks", {})
	checks_report["native_section_slot_released_before_fixture_shutdown"] = {
		"passed":cleanup_passed,
		"evidence":{"slotId":slot_id, "release":release_result,
			"movedSlotRelease":moved_release_result,
			"pendingInstallCancellation":cancellation_result,
			"postRetirementSnapshot":post_release_snapshot if is_instance_valid(backend) else {},
			"backendMetricsAfterRetirement":backend_metrics,
			"backendRetirementDrained":backend_retirement_drained,
			"worldFreed":world_freed}}
	report["checks"] = checks_report
	var failed_report: Array = report.get("failedChecks", [])
	if not cleanup_passed:
		failed_report.append("native_section_slot_released_before_fixture_shutdown")
	report["failedChecks"] = failed_report
	report["checkCount"] = checks_report.size()
	report["passed"] = bool(report.get("passed", false)) and cleanup_passed
	report["shutdownCleanup"] = {"nativePacketRelease":release_result,
		"pendingInstallCancellation":cancellation_result,
		"backendMetricsAfterRetirement":backend_metrics,
		"backendRetirementDrained":backend_retirement_drained,
		"worldQueuedForFree":world_weak != null, "worldFreed":world_freed}
	var report_json := JSON.stringify(report, "\t")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(report_json)
			file.close()
	print("ORDINARY STRUCTURE NATIVE SECTION RECEIPT ", report_json)
	quit(exit_code if bool(report.get("passed", false)) else 1)

## Admission now queues a native worker. Wait for its current identity receipt
## before the fixture inspects candidate data or controls upload/frame stages.
func _admit_compiled_candidate(owner_coordinator, section_key: Vector3i,
		generation: int, record_initial_visual_retention: bool = true) -> Dictionary:
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
		if record_initial_visual_retention:
			_record_pending_visual_retention("native_compile", "pending", generation)
		await process_frame
	return {"status":"failed", "reason":"fixture_native_compile_wait_exhausted",
		"stage":"native_compile", "sectionKey":section_key, "generation":generation}

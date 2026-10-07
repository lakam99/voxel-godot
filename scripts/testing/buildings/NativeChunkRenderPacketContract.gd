extends SceneTree
## Native chunk packet lifecycle contract; no game scene or mock backend.
const PacketOwner = preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstanceBuffer = preload("res://scripts/buildings/BuildingInstanceBuffer.gd")
const BuildingPublisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const VoxelTerrainRuntime = preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
const StaticRenderSectionGrid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const StaticSectionSnapshotBuilder = preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const StaticSectionSnapshot = preload("res://scripts/world/ChunkStaticRenderSectionSnapshot.gd")
const StaticSectionInstallSession = preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const StaticContributorLedger = preload("res://scripts/world/PreparedStaticContributorLedger.gd")
const InstanceAttributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const StaticMeshFingerprint = preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const WorldStaticSectionCoordinator = preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const CitadelPublicationPlan = preload("res://scripts/world/CitadelPublicationPlan.gd")
const CitadelPublicationService = preload("res://scripts/world/CitadelPublicationService.gd")
const OWNER_CELL := Vector2i(0,0)
const SOURCE_ID := "native-contract:wall"
const SOURCE_REVISION := "revision-1"
const PACKET_DIGEST := "digest-contract-v1"
var checks: Dictionary = {}
var diagnostics: Dictionary = {}

class SceneRegistry extends Node3D:
	var chunks: Dictionary={}
	var static_section_render_root: Node3D
	var static_section_render_owners: Dictionary={}
	var world_static_section_coordinator: Object

	func get_static_section_render_owner(owner_cell: Vector2i,
			create_if_missing := true) -> Dictionary:
		var owner: Node3D=static_section_render_owners.get(owner_cell) as Node3D
		if is_instance_valid(owner):
			return {"status":"ready","owner":owner,
				"backend":owner.get_node_or_null("ChunkRenderPacketBackend")}
		if not create_if_missing:
			return {"status":"pending","reason":"static_section_owner_not_loaded"}
		owner=Node3D.new()
		owner.name="Chunk_%d_%d" % [owner_cell.x,owner_cell.y]
		owner.position=Vector3(owner_cell.x*StaticRenderSectionGrid.STREAM_CHUNK_SIZE_METERS,
			0.0,owner_cell.y*StaticRenderSectionGrid.STREAM_CHUNK_SIZE_METERS)
		static_section_render_root.add_child(owner)
		var attached: Dictionary=PacketOwner.attach_to_chunk(owner)
		if attached.get("status")!="ready": return attached
		static_section_render_owners[owner_cell]=owner
		return {"status":"ready","owner":owner,"backend":attached.backend}

class MainRuntimeHarness extends "res://scripts/Main.gd":
	func _ready() -> void: pass
	func _process(_delta: float) -> void: pass
	func _physics_process(_delta: float) -> void: pass

class AdmissionGateStub extends RefCounted:
	func request_cells(_bounds: Rect2i) -> Dictionary:
		return {"status":"ready"}
	func stop() -> void: pass

class PacketBuildingPublisher extends BuildingPublisher:
	func validate_static_flush_source() -> bool: return true

const FixturePart = preload("res://scripts/buildings/BuildingPart.gd")

class SourceCensusProvider extends RefCounted:
	var provider_id := ""
	var source_id := ""
	var source_part_id := ""
	var source_revision := ""
	var authority_revision := "authority-1"
	var coverage_state := "normal"
	var include_invalid_revision_key := false

	func capture_static_section_sources(world_id: String, section_keys: Array) -> Dictionary:
		if coverage_state == "pending":
			return {"status":"pending", "worldId":world_id,
				"reason":"fixture_provider_pending", "retryable":true}
		var sections: Dictionary = {}
		var source_revisions: Dictionary = {}
		var source_identities: Dictionary = {}
		for section_key in section_keys:
			if coverage_state == "omit_section": continue
			var source_ids: Array[String] = []
			var source_parts: Array[Dictionary] = []
			if section_key == Vector3i.ZERO and not source_part_id.is_empty():
				source_ids.append(source_part_id)
				source_revisions[source_part_id] = source_revision
				var identity := {"sourceId":source_id,"sourcePartId":source_part_id}
				source_identities[source_part_id] = identity
				source_parts.append(identity)
			sections[section_key] = {"status":"empty" if source_ids.is_empty() else "complete",
				"coverageRevision":authority_revision+":"+str(section_key),
				"sourceParts":source_parts}
		if include_invalid_revision_key:
			source_revisions[Vector3i.ZERO] = "invalid-key-revision"
		return {"status":"complete", "worldId":world_id,
			"authorityRevision":authority_revision,
			"sourceRevisions":source_revisions,"sourceIdentities":source_identities, "sections":sections}

class EmptyCitadelAdmission extends RefCounted:
	func stats() -> Dictionary:
		return {"generation":7,"worldSeed":"section-census-contract"}
	func request_bounds(_bounds: Rect2i) -> Dictionary:
		return {"status":"ready"}
	func source_state(_region: Vector2i) -> Dictionary:
		return {"status":"absent","reason":"source_not_requested"}

func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, value: bool) -> void:
	checks[name]=value


func _run() -> void:
	_test_citadel_section_membership_query()
	if not ClassDB.class_exists("ChunkRenderPacketBackend"):
		_finish(false,"native_chunk_render_packet_backend_missing")
		return
	var scene := SceneRegistry.new()
	scene.name="NativeChunkPacketContractScene"
	scene.world_static_section_coordinator=WorldStaticSectionCoordinator.new()
	scene.world_static_section_coordinator.configure("native-section-contract-world")
	root.add_child(scene)
	scene.static_section_render_root=Node3D.new()
	scene.static_section_render_root.name="StaticSectionOwners"
	scene.add_child(scene.static_section_render_root)
	current_scene=scene
	await _test_attachment_root_set(scene)
	await _test_borrowed_presentation_cutover(scene)
	await _test_visible_borrowed_source_mount(scene)
	await _test_manifest_admission_seals_owned_motion(scene)
	await _test_borrowed_section_install_session(scene)
	await _test_mixed_section_install_session(scene)
	# The session fixtures use the real static-section owner registry. Retire
	# those owners before the original direct chunk-owner contract creates its
	# own Chunk_0_0 node, so this fixture never relies on duplicate-name repair.
	for owner_value: Variant in scene.static_section_render_owners.values():
		var section_owner := owner_value as Node3D
		if is_instance_valid(section_owner): section_owner.queue_free()
	scene.static_section_render_owners.clear()
	await process_frame
	await process_frame
	var first_chunk := _make_chunk(scene,OWNER_CELL)
	var first_owner := PacketOwner.attach_to_chunk(first_chunk)
	_check("native_backend_attached_to_actual_chunk",first_owner.get("status")=="ready" \
		and first_owner.backend.get_parent()==first_chunk)
	var backend: Node=first_owner.get("backend") as Node
	if not is_instance_valid(backend):
		_finish(false,"native_chunk_packet_owner_attach_failed")
		return
	var wrong_owner: Dictionary=backend.call("begin_packet",SOURCE_ID,Vector2i(1,0),1,SOURCE_REVISION,
		PACKET_DIGEST,Transform3D.IDENTITY,1,1)
	_check("native_backend_rejects_wrong_owner_cell",wrong_owner.get("status")=="failed" \
		and wrong_owner.get("reason")=="invalid_packet_header_or_owner_cell")
	_check("native_packet_generation_one_installs",_install(backend,1))
	_check("native_packet_receipt_matches_generation_one",backend.call("receipt_installed",SOURCE_ID,1,
		SOURCE_REVISION,PACKET_DIGEST))
	_check("native_packet_rejects_mesh_mutated_after_candidate_binding",
		_reject_mutated_mesh_after_begin(backend))
	_check("native_packet_generation_two_replaces_generation_one",_install(backend,2) \
		and backend.call("receipt_installed",SOURCE_ID,2,SOURCE_REVISION,PACKET_DIGEST) \
		and not backend.call("receipt_installed",SOURCE_ID,1,SOURCE_REVISION,PACKET_DIGEST))
	var stale_release: Dictionary=backend.call("release_packet",SOURCE_ID,1)
	_check("native_packet_stale_release_preserves_current_generation",stale_release.get("status")=="failed" \
		and backend.call("receipt_installed",SOURCE_ID,2,SOURCE_REVISION,PACKET_DIGEST))
	var parent := Node3D.new()
	parent.name="NativePacketBuildingSite"
	scene.add_child(parent)
	var publisher := PacketBuildingPublisher.new()
	publisher.source_blueprint_id="native-contract-blueprint"
	publisher.publication_site_id="native-contract-site"
	var material := StandardMaterial3D.new()
	publisher.material_cache["native-contract-material"]=material
	var section_material := StandardMaterial3D.new()
	section_material.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	# Smooth terrain compiles to arbitrary triangle geometry. Exercise that exact
	# renderer resource shape through the section slot instead of another box.
	var section_mesh := ArrayMesh.new()
	var terrain_surface_arrays: Array=[]
	terrain_surface_arrays.resize(Mesh.ARRAY_MAX)
	terrain_surface_arrays[Mesh.ARRAY_VERTEX]=PackedVector3Array([
		Vector3(0.0,0.0,0.0),Vector3(1.0,0.0,0.0),Vector3(0.0,1.0,0.0)])
	terrain_surface_arrays[Mesh.ARRAY_NORMAL]=PackedVector3Array([
		Vector3.BACK,Vector3.BACK,Vector3.BACK])
	section_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,terrain_surface_arrays)
	var section_mesh_identity: Dictionary=StaticMeshFingerprint.inspect(section_mesh)
	var section_buffer: Array[float]=[]
	var expected_instance_color:=Color(0.15,0.45,0.8,0.9)
	var expected_custom_data:=Color(0.3,0.7,0.4,1.0)
	for value: float in InstanceBuffer.encode(
			Transform3D(Basis.IDENTITY,Vector3(0.5,0.5,0.5)),expected_custom_data,expected_instance_color):
		section_buffer.append(value)
	section_buffer.make_read_only()
	var section_bounds:=AABB(Vector3.ZERO,Vector3.ONE)
	var section_material_key:="native-section-material"
	var section_tier:="structural"
	var section_resource_mesh_key:="unit-box-v1"
	var section_pipeline:="native-section-v1"
	var section_segment_declaration: Dictionary={"segmentId":"native-section-source-segment",
		"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"materialKey":section_material_key,"renderTier":section_tier,
		"meshKey":section_resource_mesh_key,"meshContentDigest":section_mesh_identity.contentDigest,
		"meshLocalBounds":section_bounds,
		"pipelineRevision":section_pipeline,"renderLayer":"cutout",
		"translucentSortPolicy":"none","castShadows":true,
		"visibilityRangeEnd":240.0,"fadeMargin":18.0}
	section_segment_declaration.make_read_only()
	var section_segment_declarations: Array[Dictionary]=[section_segment_declaration]
	section_segment_declarations.make_read_only()
	var section_declaration: Dictionary={"sourcePartId":"native-section-part",
		"sourceId":"native-section-source","sourceRevision":"native-section-rev-1",
		"sourceToWorld":Transform3D.IDENTITY,"ownerCell":OWNER_CELL,
		"segments":section_segment_declarations}
	section_declaration.make_read_only()
	var section_declarations: Array[Dictionary]=[section_declaration]
	section_declarations.make_read_only()
	var section_removals: Array=[]
	section_removals.make_read_only()
	var section_ledger=StaticContributorLedger.new()
	var section_begin: Dictionary=section_ledger.begin_boundary("native-section-boundary",
		section_declarations,section_removals)
	var section_input: Dictionary={"sourcePartId":"native-section-part",
		"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"sourceId":"native-section-source","sourceRevision":"native-section-rev-1",
		"segmentId":"native-section-source-segment","buffer":section_buffer,
		"instanceCount":1,"materialKey":section_material_key,"renderTier":section_tier,
		"meshKey":section_resource_mesh_key,"meshContentDigest":section_mesh_identity.contentDigest,
		"meshLocalBounds":section_bounds,
		"pipelineRevision":section_pipeline,"renderLayer":"cutout",
		"translucentSortPolicy":"none","castShadows":true,
		"visibilityRangeEnd":240.0,"fadeMargin":18.0}
	section_input.make_read_only()
	var section_admission: Dictionary=section_ledger.accept_prepared_segment(
		"native-section-boundary",section_input)
	var section_revisions: Dictionary={StaticContributorLedger._source_part_identity_key("native-section-source","native-section-part"):"native-section-rev-1"}
	section_revisions.make_read_only()
	var section_prepared: Dictionary=section_ledger.prepare_boundary(
		"native-section-boundary",section_revisions,"native-section-contract-world",1)
	diagnostics["sectionPreparation"]={"begin":section_begin,"admission":section_admission,"prepared":section_prepared}
	if section_prepared.get("status") != "prepared" or section_prepared.get("replacements",[]).is_empty():
		_finish(false,"section_candidate_preparation_failed")
		return
	var section_candidate: Dictionary=section_prepared.replacements[0]
	var section_snapshot: Dictionary=section_candidate.snapshot
	var section_bindings_started: Dictionary=PacketOwner.begin_static_section_install(section_candidate,
		{"native-section-material":section_material},{"unit-box-v1":section_mesh})
	var section_backend: Node=section_bindings_started.get("backend") as Node
	if section_bindings_started.get("status") != "ready" or not is_instance_valid(section_backend):
		diagnostics["sectionInstallStart"]=section_bindings_started
		_finish(false,"section_install_admission_failed")
		return
	var mismatch_arrays: Array=section_mesh.surface_get_arrays(0)
	var mismatch_vertices: PackedVector3Array=mismatch_arrays[Mesh.ARRAY_VERTEX]
	mismatch_vertices[0]+=Vector3(0.125,0.0,0.0)
	mismatch_arrays[Mesh.ARRAY_VERTEX]=mismatch_vertices
	var mismatch_mesh:=ArrayMesh.new()
	mismatch_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,mismatch_arrays)
	var rejected_mesh_session:=StaticSectionInstallSession.new()
	var rejected_mesh_binding: Dictionary=rejected_mesh_session.begin(section_backend,
		section_bindings_started.chunk,section_candidate,{"native-section-material":section_material},
		{"unit-box-v1":mismatch_mesh})
	_check("section_candidate_rejects_mesh_binding_with_different_content",
		rejected_mesh_binding.get("status")=="failed" \
		and rejected_mesh_binding.get("reason")=="section_mesh_binding_content_digest_mismatch")
	var section_session: Variant=section_bindings_started.get("session")
	var section_mesh_expected: Mesh=section_mesh.duplicate(true) as Mesh
	var section_append_result: Dictionary={"status":"not_started"}
	if section_session is RefCounted:
		section_append_result=section_session.advance(1)
	if section_append_result.get("status")=="pending" and section_append_result.get("stage")=="append":
		section_mesh.clear_surfaces()
	var section_result: Dictionary={"status":section_bindings_started.get("status","failed")}
	var section_turns:=0
	while section_session is RefCounted and section_session.state not in ["installed","failed","cancelled"] \
			and section_turns<64:
		section_result=await _advance_presented_session(section_session,4)
		section_turns+=1
	var section_slot_id:=StaticSectionInstallSession.slot_id("native-section-contract-world",Vector3i.ZERO)
	var section_backend_snapshot: Dictionary=section_backend.call("installed_snapshot",section_slot_id) \
		if is_instance_valid(section_backend) else {"status":"missing"}
	var installed_batch_receipts: Array=section_backend_snapshot.get("batches",[])
	var installed_multimesh: MultiMesh = null
	if not installed_batch_receipts.is_empty():
		var installed_batch_node := instance_from_id(int(installed_batch_receipts[0].get("instanceId",0))) as MultiMeshInstance3D
		if is_instance_valid(installed_batch_node):
			installed_multimesh = installed_batch_node.multimesh
	var installed_section_layers: Array=section_backend_snapshot.get("layers",[])
	var session_layer_receipts_match:=installed_section_layers.size()==3 \
		and String(installed_section_layers[0].get("layer",""))=="cutout" \
		and String(installed_section_layers[0].get("status",""))=="ready" \
		and int(installed_section_layers[0].get("installedBatchCount",-1))==1 \
		and String(installed_section_layers[1].get("layer",""))=="opaque" \
		and String(installed_section_layers[1].get("status",""))=="empty" \
		and String(installed_section_layers[2].get("layer",""))=="translucent" \
		and String(installed_section_layers[2].get("status",""))=="empty"
	var section_receipts: Array[Dictionary]=[]
	if section_result.get("status")=="installed" and section_result.get("receipt") is Dictionary:
		section_receipts.append(section_result.receipt)
	section_receipts.make_read_only()
	var section_promoted: Dictionary=section_ledger.accept_installed_candidate(
		"native-section-boundary",section_receipts,section_revisions)
	diagnostics["sectionCandidateInstall"]={"start":section_bindings_started,
		"result":section_result,"turns":section_turns,"backend":section_backend_snapshot}
	_check("bound_section_candidate_installs_through_native_chunk_renderer",
		section_begin.get("status")=="ready" and section_admission.get("status")=="accepted" \
		and section_prepared.get("status")=="prepared" \
		and section_session is RefCounted and section_session.state=="installed" \
		and not String(section_result.get("frameAckToken","")).is_empty() \
		and section_result.get("callbackCompletion",{}).get("status")=="completed" \
		and section_backend.call("receipt_installed",section_slot_id,1,
			"native-section-contract-world:1",String(section_candidate.contentManifestDigest)) \
		and section_backend_snapshot.get("status")=="ready" \
		and int(section_backend_snapshot.get("expectedBatchCount",0))==1 \
		and session_layer_receipts_match \
		and section_promoted.get("status")=="committed")
	_check("native_section_receipt_and_multimesh_keep_independent_color_and_custom_lanes",
		installed_batch_receipts.size()==1 \
		and bool(installed_batch_receipts[0].get("usesColors",false)) \
		and bool(installed_batch_receipts[0].get("usesCustomData",false)) \
		and installed_multimesh is MultiMesh and installed_multimesh.use_colors \
		and installed_multimesh.use_custom_data \
		and installed_multimesh.get_buffer().size()==InstanceAttributes.FLOATS_PER_INSTANCE \
		and Color(installed_multimesh.get_buffer()[InstanceAttributes.COLOR_OFFSET],
			installed_multimesh.get_buffer()[InstanceAttributes.COLOR_OFFSET+1],
			installed_multimesh.get_buffer()[InstanceAttributes.COLOR_OFFSET+2],
			installed_multimesh.get_buffer()[InstanceAttributes.COLOR_OFFSET+3]).is_equal_approx(expected_instance_color) \
		and Color(installed_multimesh.get_buffer()[InstanceAttributes.CUSTOM_DATA_OFFSET],
			installed_multimesh.get_buffer()[InstanceAttributes.CUSTOM_DATA_OFFSET+1],
			installed_multimesh.get_buffer()[InstanceAttributes.CUSTOM_DATA_OFFSET+2],
			installed_multimesh.get_buffer()[InstanceAttributes.CUSTOM_DATA_OFFSET+3]).is_equal_approx(expected_custom_data))
	diagnostics["instanceAttributeLanes"]={"receiptCount":installed_batch_receipts.size(),
		"receiptUsesColors":bool(installed_batch_receipts[0].get("usesColors",false)) if not installed_batch_receipts.is_empty() else false,
		"receiptUsesCustomData":bool(installed_batch_receipts[0].get("usesCustomData",false)) if not installed_batch_receipts.is_empty() else false,
		"multimeshValid":installed_multimesh is MultiMesh,
		"usesColors":installed_multimesh.use_colors if installed_multimesh is MultiMesh else false,
		"usesCustomData":installed_multimesh.use_custom_data if installed_multimesh is MultiMesh else false,
		"expectedColor":expected_instance_color,
		"actualColor":installed_multimesh.get_instance_color(0) if installed_multimesh is MultiMesh else Color.TRANSPARENT,
		"expectedCustom":expected_custom_data,
		"actualCustom":installed_multimesh.get_instance_custom_data(0) if installed_multimesh is MultiMesh else Color.TRANSPARENT,
		"readbackBuffer":installed_multimesh.get_buffer() if installed_multimesh is MultiMesh else PackedFloat32Array()}
	var replacement_color:=Color(0.9,0.2,0.1,1.0)
	var replacement_custom:=Color(0.8,0.1,0.6,1.0)
	var replacement_buffer: Array[float]=[]
	for value: float in InstanceBuffer.encode(
			Transform3D(Basis.IDENTITY,Vector3(0.5,0.5,0.5)),replacement_custom,replacement_color):
		replacement_buffer.append(value)
	replacement_buffer.make_read_only()
	var replacement_segment_declaration:=section_segment_declaration.duplicate(false)
	replacement_segment_declaration.make_read_only()
	var replacement_segment_declarations: Array[Dictionary]=[replacement_segment_declaration]
	replacement_segment_declarations.make_read_only()
	var replacement_declaration:=section_declaration.duplicate(false)
	replacement_declaration["sourceRevision"]="native-section-rev-2"
	replacement_declaration["segments"]=replacement_segment_declarations
	replacement_declaration.make_read_only()
	var replacement_declarations: Array[Dictionary]=[replacement_declaration]
	replacement_declarations.make_read_only()
	var replacement_no_removals: Array=[]
	replacement_no_removals.make_read_only()
	var replacement_begin: Dictionary=section_ledger.begin_boundary("native-section-boundary-2",
		replacement_declarations,replacement_no_removals)
	var replacement_input:=section_input.duplicate(false)
	replacement_input["sourceRevision"]="native-section-rev-2"
	replacement_input["buffer"]=replacement_buffer
	replacement_input.make_read_only()
	var replacement_admission: Dictionary=section_ledger.accept_prepared_segment(
		"native-section-boundary-2",replacement_input)
	var replacement_revisions: Dictionary={StaticContributorLedger._source_part_identity_key("native-section-source","native-section-part"):"native-section-rev-2"}
	replacement_revisions.make_read_only()
	var replacement_prepared: Dictionary=section_ledger.prepare_boundary(
		"native-section-boundary-2",replacement_revisions,"native-section-contract-world",2)
	diagnostics["replacementPreparation"]={"begin":replacement_begin,"admission":replacement_admission,"prepared":replacement_prepared}
	if replacement_prepared.get("status") != "prepared" or replacement_prepared.get("replacements",[]).is_empty():
		_finish(false,"replacement_candidate_preparation_failed")
		return
	var replacement_candidate: Dictionary=replacement_prepared.replacements[0]
	var replacement_started: Dictionary=PacketOwner.begin_static_section_install(replacement_candidate,
		{"native-section-material":section_material},{"unit-box-v1":section_mesh_expected})
	if replacement_started.get("status") != "ready":
		diagnostics["replacementInstallStart"]=replacement_started
		_finish(false,"replacement_install_admission_failed")
		return
	var replacement_session: Variant=replacement_started.get("session")
	var replacement_first_turn: Dictionary={"status":"not_started"}
	if replacement_session is RefCounted:
		replacement_first_turn=replacement_session.advance(1)
	var still_installed_before_swap: Dictionary=section_backend.call("installed_snapshot",section_slot_id)
	var old_batch_receipts: Array=still_installed_before_swap.get("batches",[])
	var old_batch_node:=instance_from_id(int(old_batch_receipts[0].get("instanceId",0))) as MultiMeshInstance3D \
		if not old_batch_receipts.is_empty() else null
	var old_multimesh: MultiMesh=old_batch_node.multimesh if is_instance_valid(old_batch_node) else null
	var replacement_turns:=0
	var replacement_result: Dictionary={"status":replacement_started.get("status","failed")}
	while replacement_session is RefCounted \
			and replacement_session.state not in ["installed","failed","cancelled"] \
			and replacement_turns<64:
		replacement_result=await _advance_presented_session(replacement_session,4)
		replacement_turns+=1
	var replacement_snapshot: Dictionary=section_backend.call("installed_snapshot",section_slot_id)
	var replacement_batch_receipts: Array=replacement_snapshot.get("batches",[])
	var replacement_batch_node:=instance_from_id(int(replacement_batch_receipts[0].get("instanceId",0))) as MultiMeshInstance3D \
		if not replacement_batch_receipts.is_empty() else null
	var replacement_multimesh: MultiMesh=replacement_batch_node.multimesh \
		if is_instance_valid(replacement_batch_node) else null
	var replacement_section_receipts: Array[Dictionary]=[]
	if replacement_result.get("status")=="installed" and replacement_result.get("receipt") is Dictionary:
		replacement_section_receipts.append(replacement_result.receipt)
	replacement_section_receipts.make_read_only()
	var replacement_promoted: Dictionary=section_ledger.accept_installed_candidate(
		"native-section-boundary-2",replacement_section_receipts,replacement_revisions)
	_check("native_section_replacement_keeps_old_color_and_custom_until_new_receipt_then_swaps",
		replacement_begin.get("status")=="ready" and replacement_admission.get("status")=="accepted" \
		and replacement_prepared.get("status")=="prepared" \
		and replacement_first_turn.get("status")=="pending" \
		and still_installed_before_swap.get("status")=="ready" \
		and int(still_installed_before_swap.get("generation",0))==1 \
		and is_instance_valid(old_multimesh) \
		and _multimesh_color(old_multimesh).is_equal_approx(expected_instance_color) \
		and _multimesh_custom(old_multimesh).is_equal_approx(expected_custom_data) \
		and replacement_result.get("status")=="installed" \
		and replacement_snapshot.get("status")=="ready" \
		and int(replacement_snapshot.get("generation",0))==2 \
		and replacement_batch_receipts.size()==1 \
		and bool(replacement_batch_receipts[0].get("usesColors",false)) \
		and bool(replacement_batch_receipts[0].get("usesCustomData",false)) \
		and is_instance_valid(replacement_multimesh) \
		and _multimesh_color(replacement_multimesh).is_equal_approx(replacement_color) \
		and _multimesh_custom(replacement_multimesh).is_equal_approx(replacement_custom) \
		and replacement_promoted.get("status")=="committed")
	_check("native_section_slot_installs_transvoxel_shaped_array_mesh",
		section_mesh_expected.get_surface_count()==1 \
		and section_mesh_expected.surface_get_primitive_type(0)==Mesh.PRIMITIVE_TRIANGLES \
		and section_mesh.get_surface_count()==0 \
		and _has_installed_mesh(section_backend,section_mesh_expected))
	var layered_chunk:=_make_chunk(scene,Vector2i(5,0))
	var layered_owner: Dictionary=PacketOwner.attach_to_chunk(layered_chunk)
	var layered_backend: Node=layered_owner.get("backend") as Node
	var layered_source_id:="native-contract:layered-section-slot"
	var layered_revision:="layered-section-revision-1"
	var layered_digest:="layered-section-manifest-1"
	var layered_layers: Array=[
		{"layer":"opaque","expectedBatchCount":1,"expectedInstanceCount":1},
		{"layer":"cutout","expectedBatchCount":0,"expectedInstanceCount":0},
		{"layer":"translucent","expectedBatchCount":1,"expectedInstanceCount":1}]
	var layered_material:=StandardMaterial3D.new()
	var cutout_material:=StandardMaterial3D.new()
	cutout_material.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	var translucent_material:=StandardMaterial3D.new()
	translucent_material.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
	var layered_opaque_mesh:=BoxMesh.new()
	var layered_translucent_mesh:=BoxMesh.new()
	var layered_opaque_identity: Dictionary=StaticMeshFingerprint.inspect(layered_opaque_mesh)
	var layered_translucent_identity: Dictionary=StaticMeshFingerprint.inspect(layered_translucent_mesh)
	var layered_begin: Dictionary=layered_backend.call("begin_packet_with_layers",layered_source_id,Vector2i(5,0),1,
		layered_revision,layered_digest,Transform3D.IDENTITY,2,2,layered_layers)
	var layered_opaque_append:=_append_native_layer_batch(layered_backend,layered_source_id,1,
		"opaque-batch",layered_opaque_mesh,String(layered_opaque_identity.get("contentDigest","")),
		layered_material,"opaque",Vector3.ZERO)
	var layered_translucent_append:=_append_native_layer_batch(layered_backend,layered_source_id,1,
		"translucent-batch",layered_translucent_mesh,
		String(layered_translucent_identity.get("contentDigest","")),translucent_material,
		"translucent",Vector3(2.0,0.0,0.0))
	var layered_upload_first: Dictionary=layered_backend.call("advance_packet",layered_source_id,1,1)
	var layered_upload_second: Dictionary=layered_backend.call("advance_packet",layered_source_id,1,1)
	var layered_commit: Dictionary=layered_backend.call("commit_packet",layered_source_id,1)
	var layered_snapshot: Dictionary=layered_backend.call("installed_snapshot",layered_source_id)
	var layered_receipts: Array=layered_snapshot.get("layers",[])
	var layered_layer_receipts_match:=layered_receipts.size()==3 \
		and String(layered_receipts[0].get("layer",""))=="opaque" \
		and String(layered_receipts[0].get("status",""))=="ready" \
		and String(layered_receipts[1].get("layer",""))=="cutout" \
		and String(layered_receipts[1].get("status",""))=="empty" \
		and int(layered_receipts[1].get("expectedBatchCount",-1))==0 \
		and int(layered_receipts[1].get("installedBatchCount",-1))==0 \
		and String(layered_receipts[2].get("layer",""))=="translucent" \
		and String(layered_receipts[2].get("status",""))=="ready"
	var layered_root_id:=int(layered_snapshot.get("rootInstanceId",0))
	_check("native_section_slot_acknowledges_every_render_layer_and_explicit_empty_layer",
		layered_begin.get("status")=="ready_to_append" \
		and layered_opaque_append.get("status")=="accepted" \
		and layered_translucent_append.get("status")=="accepted" \
		and layered_upload_first.get("status")=="pending" \
		and layered_upload_second.get("status")=="ready_to_commit" \
		and layered_commit.get("status")=="ready" \
		and layered_snapshot.get("status")=="ready" \
		and layered_snapshot.get("sourceRevision")==layered_revision \
		and layered_snapshot.get("packetDigest")==layered_digest \
		and layered_layer_receipts_match)
	var translucent_sort_probe := await _probe_translucent_index_replacement(
		layered_backend, layered_chunk, translucent_material)
	checks.merge(translucent_sort_probe.get("checks", {}), true)
	diagnostics["translucentSortReplacementProbe"] = translucent_sort_probe.get("diagnostics", {})
	var translucent_session_probe := await _probe_translucent_install_session_gate(
		layered_backend, layered_chunk, translucent_material)
	checks.merge(translucent_session_probe.get("checks", {}), true)
	diagnostics["translucentInstallSessionProbe"] = translucent_session_probe.get("diagnostics", {})
	var incomplete_layers: Array=[
		{"layer":"opaque","expectedBatchCount":1,"expectedInstanceCount":1},
		{"layer":"cutout","expectedBatchCount":0,"expectedInstanceCount":0},
		{"layer":"translucent","expectedBatchCount":1,"expectedInstanceCount":1}]
	var incomplete_begin: Dictionary=layered_backend.call("begin_packet_with_layers",layered_source_id,Vector2i(5,0),2,
		"layered-section-revision-2","layered-section-manifest-2",Transform3D.IDENTITY,2,2,incomplete_layers)
	var incomplete_append:=_append_native_layer_batch(layered_backend,layered_source_id,2,
		"replacement-opaque",layered_opaque_mesh,String(layered_opaque_identity.get("contentDigest","")),
		layered_material,"opaque",Vector3(0.0,1.0,0.0))
	var incomplete_advance: Dictionary=layered_backend.call("advance_packet",layered_source_id,2,2)
	var old_layered_snapshot: Dictionary=layered_backend.call("installed_snapshot",layered_source_id)
	var incomplete_abort: Dictionary=layered_backend.call("abort_packet",layered_source_id,2)
	var retained_layered_snapshot: Dictionary=layered_backend.call("installed_snapshot",layered_source_id)
	_check("native_section_slot_keeps_old_layers_visible_until_replacement_manifest_is_complete",
		incomplete_begin.get("status")=="ready_to_append" \
		and incomplete_append.get("status")=="accepted" \
		and incomplete_advance.get("status")=="pending" \
		and incomplete_advance.get("reason")=="packet_batches_incomplete" \
		and old_layered_snapshot.get("status")=="ready" \
		and int(old_layered_snapshot.get("generation",0))==1 \
		and int(old_layered_snapshot.get("rootInstanceId",0))==layered_root_id \
		and old_layered_snapshot.get("layers")==layered_receipts \
		and incomplete_abort.get("status")=="aborted" \
		and retained_layered_snapshot.get("status")=="ready" \
		and int(retained_layered_snapshot.get("rootInstanceId",0))==layered_root_id)
	var empty_layers: Array=[
		{"layer":"opaque","expectedBatchCount":0,"expectedInstanceCount":0},
		{"layer":"cutout","expectedBatchCount":0,"expectedInstanceCount":0},
		{"layer":"translucent","expectedBatchCount":0,"expectedInstanceCount":0}]
	var empty_begin: Dictionary=layered_backend.call("begin_packet_with_layers",layered_source_id,Vector2i(5,0),3,
		"layered-section-revision-3","layered-section-manifest-empty",Transform3D.IDENTITY,0,0,empty_layers)
	var empty_advance: Dictionary=layered_backend.call("advance_packet",layered_source_id,3,1)
	var empty_commit: Dictionary=layered_backend.call("commit_packet",layered_source_id,3)
	var empty_snapshot: Dictionary=layered_backend.call("installed_snapshot",layered_source_id)
	var empty_receipts: Array=empty_snapshot.get("layers",[])
	_check("native_section_slot_replaces_with_explicitly_empty_layers",
		empty_begin.get("status")=="ready_to_append" \
		and empty_advance.get("status")=="ready_to_commit" \
		and empty_commit.get("status")=="ready" \
		and empty_snapshot.get("status")=="ready" \
		and int(empty_snapshot.get("generation",0))==3 \
		and empty_receipts.size()==3 \
		and empty_receipts.all(func(layer: Dictionary) -> bool:
			return layer.get("status")=="empty" \
				and int(layer.get("expectedBatchCount",-1))==0 \
				and int(layer.get("installedBatchCount",-1))==0 \
				and int(layer.get("expectedInstanceCount",-1))==0 \
				and int(layer.get("installedInstanceCount",-1))==0))
	diagnostics["layeredSectionSlot"]={"begin":layered_begin,"firstAppend":layered_opaque_append,
		"secondAppend":layered_translucent_append,"uploadFirst":layered_upload_first,
		"uploadSecond":layered_upload_second,"commit":layered_commit,"snapshot":layered_snapshot,
		"incompleteBegin":incomplete_begin,"incompleteAdvance":incomplete_advance,
		"retainedAfterCancel":retained_layered_snapshot,"emptyBegin":empty_begin,
		"emptyAdvance":empty_advance,"emptyCommit":empty_commit,"emptySnapshot":empty_snapshot}
	var expected_mesh_payload_bytes: int=_mesh_payload_bytes(section_mesh_expected)
	var backend_metrics: Dictionary=section_backend.call("metrics")
	_check("native_mesh_surface_payload_bytes_are_reserved_and_reported",
		int(section_backend_snapshot.get("meshPayloadBytes",-1))==expected_mesh_payload_bytes \
		and int(section_backend_snapshot.get("payloadBytes",-1))==expected_mesh_payload_bytes+InstanceAttributes.FLOATS_PER_INSTANCE*4 \
		and int(backend_metrics.get("installedMeshPayloadBytes",-1))==expected_mesh_payload_bytes \
		and int(backend_metrics.get("residentPayloadBytes",-1))>=int(section_backend_snapshot.payloadBytes))
	var coordinator := WorldStaticSectionCoordinator.new()
	var coordinator_world := "native-section-coordinator-contract-world"
	var coordinator_source_id := "coordinator-building-source"
	var coordinator_part_id := "coordinator-building-part"
	var coordinator_identity := StaticContributorLedger._source_part_identity_key(coordinator_source_id,coordinator_part_id)
	var coordinator_revision := "coordinator-rev-1"
	var coordinator_boundary_id := "coordinator-boundary-1"
	var coordinator_configured: Dictionary=coordinator.configure(coordinator_world)
	var required_source_providers: Array[String]=["terrain", "ordinary_structures",
		"blueprint_buildings", "ecology_and_static_props"]
	required_source_providers.make_read_only()
	var roster_configured: Dictionary=coordinator.configure_source_roster(required_source_providers)
	var missing_roster_census: Dictionary=coordinator.capture_authoritative_source_census([Vector3i.ZERO])
	var source_providers: Array=[]
	for provider_id in required_source_providers:
		var provider := SourceCensusProvider.new()
		provider.provider_id = provider_id
		if provider_id == "ordinary_structures":
			provider.source_id = coordinator_source_id
			provider.source_part_id = coordinator_part_id
			provider.source_revision = coordinator_revision
		source_providers.append(provider)
		coordinator.register_source_provider(provider_id,provider,"capture_static_section_sources")
	var roster_snapshot: Dictionary=coordinator.capture_authoritative_source_census([Vector3i.ZERO])
	var invalid_revision_provider: SourceCensusProvider=source_providers[1]
	invalid_revision_provider.include_invalid_revision_key=true
	var invalid_revision_census: Dictionary=coordinator.capture_authoritative_source_census([Vector3i.ZERO])
	invalid_revision_provider.include_invalid_revision_key=false
	var multi_section_admission: Dictionary=coordinator.advance_boundary_from_roster(
		[Vector3i.ZERO,Vector3i(1,0,0)],{}, {},1)
	var empty_provider: SourceCensusProvider=source_providers[0]
	empty_provider.coverage_state="omit_section"
	var omitted_section_census: Dictionary=coordinator.capture_authoritative_source_census([Vector3i.ZERO])
	empty_provider.coverage_state="normal"
	diagnostics["worldCoordinatorSourceRoster"]={"configured":roster_configured,
		"missingProvider":missing_roster_census,"complete":roster_snapshot,
		"omittedSection":omitted_section_census,
		"invalidRevisionKey":invalid_revision_census,
		"multiSectionAdmission":multi_section_admission}
	var coordinator_declaration_segment: Dictionary=section_segment_declaration.duplicate(false)
	coordinator_declaration_segment["segmentId"]="coordinator-segment-1"
	coordinator_declaration_segment.make_read_only()
	var coordinator_segment_declarations: Array[Dictionary]=[coordinator_declaration_segment]
	coordinator_segment_declarations.make_read_only()
	var coordinator_declaration: Dictionary={"sourcePartId":coordinator_part_id,
		"sourceId":coordinator_source_id,"sourceRevision":coordinator_revision,
		"sourceToWorld":Transform3D.IDENTITY,"ownerCell":OWNER_CELL,
		"segments":coordinator_segment_declarations}
	coordinator_declaration.make_read_only()
	var coordinator_declarations: Array[Dictionary]=[coordinator_declaration]
	coordinator_declarations.make_read_only()
	var coordinator_removals: Array=[]
	coordinator_removals.make_read_only()
	var coordinator_enqueued: Dictionary=coordinator.enqueue_boundary(coordinator_boundary_id,
		coordinator_declarations,coordinator_removals)
	var coordinator_input: Dictionary=section_input.duplicate(false)
	coordinator_input["sourcePartId"]=coordinator_part_id
	coordinator_input["sourceId"]=coordinator_source_id
	coordinator_input["sourceRevision"]=coordinator_revision
	coordinator_input["segmentId"]="coordinator-segment-1"
	coordinator_input.make_read_only()
	var coordinator_segment_admitted: Dictionary=coordinator.submit_prepared_segment(
		coordinator_boundary_id,coordinator_input)
	var coordinator_materials: Dictionary={section_material_key:section_material}
	coordinator_materials.make_read_only()
	var coordinator_meshes: Dictionary={section_resource_mesh_key:section_mesh_expected}
	coordinator_meshes.make_read_only()
	var coordinator_install: Dictionary={"status":"pending"}
	var coordinator_turns:=0
	while coordinator_turns<64 and coordinator_install.get("status") not in ["committed","failed","unsupported"]:
		coordinator_install=coordinator.advance_boundary_from_roster([Vector3i.ZERO],
			coordinator_materials,coordinator_meshes,4)
		coordinator_turns+=1
		await process_frame
	var coordinator_slot_id:=StaticSectionInstallSession.slot_id(coordinator_world,Vector3i.ZERO)
	var coordinator_backend_snapshot: Dictionary=section_backend.call("installed_snapshot",coordinator_slot_id)
	diagnostics["worldCoordinatorInstall"]={"configured":coordinator_configured,
		"enqueued":coordinator_enqueued,"segmentAdmitted":coordinator_segment_admitted,
		"lastAdvance":coordinator_install,"turns":coordinator_turns,
		"status":coordinator.status(),"backend":coordinator_backend_snapshot}
	_check("world_coordinator_candidate_installs_and_promotes_through_native_renderer",
		coordinator_configured.get("status")=="ready" \
		and roster_configured.get("status")=="ready" \
		and missing_roster_census.get("status")=="pending" \
		and missing_roster_census.get("reason")=="static_source_provider_missing" \
		and roster_snapshot.get("status")=="complete" \
		and roster_snapshot.expectedContributorsBySection.get(Vector3i.ZERO,[]).size()==1 \
		and invalid_revision_census.get("status")=="failed" \
		and invalid_revision_census.get("reason")=="invalid_static_source_revision_entry" \
		and multi_section_admission.get("status")=="failed" \
		and multi_section_admission.get("reason")=="roster_boundary_requires_single_section_until_atomic_promotion" \
		and omitted_section_census.get("status")=="failed" \
		and omitted_section_census.get("reason")=="incomplete_static_source_provider_snapshot" \
		and coordinator_enqueued.get("status")=="queued" \
		and coordinator_segment_admitted.get("status")=="queued" \
		and coordinator_install.get("status")=="committed" \
		and coordinator_backend_snapshot.get("status")=="ready" \
		and int(coordinator_backend_snapshot.get("generation",0))==1 \
		and coordinator.status().get("committedSourcePartIds",[]).has(coordinator_part_id) \
		and section_backend.call("receipt_installed",coordinator_slot_id,1,
			"%s:1" % coordinator_world,String(coordinator_backend_snapshot.get("packetDigest",""))))
	var roster_replace_segment: Dictionary=coordinator_declaration_segment.duplicate(false)
	roster_replace_segment["segmentId"]="coordinator-segment-census-stale"
	roster_replace_segment.make_read_only()
	var roster_replace_segments: Array[Dictionary]=[roster_replace_segment]
	roster_replace_segments.make_read_only()
	var roster_replace_declaration: Dictionary=coordinator_declaration.duplicate(false)
	roster_replace_declaration["sourceRevision"]="coordinator-rev-2"
	roster_replace_declaration["segments"]=roster_replace_segments
	roster_replace_declaration.make_read_only()
	var roster_replace_declarations: Array[Dictionary]=[roster_replace_declaration]
	roster_replace_declarations.make_read_only()
	var roster_stale_boundary:="coordinator-boundary-stale-roster"
	var roster_stale_enqueue: Dictionary=coordinator.enqueue_boundary(roster_stale_boundary,
		roster_replace_declarations,coordinator_removals)
	var roster_replace_input: Dictionary=coordinator_input.duplicate(false)
	roster_replace_input["sourceRevision"]="coordinator-rev-2"
	roster_replace_input["segmentId"]="coordinator-segment-census-stale"
	roster_replace_input.make_read_only()
	var roster_stale_segment_admitted: Dictionary=coordinator.submit_prepared_segment(
		roster_stale_boundary,roster_replace_input)
	for provider in source_providers:
		if provider.provider_id=="ordinary_structures":
			provider.source_revision="coordinator-rev-2"
	var roster_stale_first_advance: Dictionary=coordinator.advance_boundary_from_roster(
		[Vector3i.ZERO],coordinator_materials,coordinator_meshes,1)
	for provider in source_providers:
		if provider.provider_id=="ordinary_structures":
			provider.source_revision="coordinator-rev-3"
	var roster_stale_second_advance: Dictionary=coordinator.advance_boundary_from_roster(
		[Vector3i.ZERO],coordinator_materials,coordinator_meshes,1)
	var retained_roster_slot: Dictionary=section_backend.call("installed_snapshot",coordinator_slot_id)
	for provider in source_providers:
		if provider.provider_id=="ordinary_structures":
			provider.source_revision=coordinator_revision
	diagnostics["worldCoordinatorStaleRoster"]={"enqueued":roster_stale_enqueue,
		"segmentAdmitted":roster_stale_segment_admitted,"firstAdvance":roster_stale_first_advance,
		"staleAdvance":roster_stale_second_advance,"retainedSlot":retained_roster_slot}
	_check("world_coordinator_aborts_stale_roster_boundary_and_retains_current_slot",
		roster_stale_enqueue.get("status")=="queued" \
		and roster_stale_segment_admitted.get("status")=="queued" \
		and roster_stale_first_advance.get("status")=="pending" \
		and roster_stale_second_advance.get("status")=="failed" \
		and roster_stale_second_advance.get("reason")=="authoritative_source_census_changed_during_boundary" \
		and bool(roster_stale_second_advance.get("requiresResubmit",false)) \
		and int(retained_roster_slot.get("generation",0))==1)
	var pending_boundary_id:="coordinator-boundary-provider-pending"
	var pending_enqueue: Dictionary=coordinator.enqueue_boundary(pending_boundary_id,
		roster_replace_declarations,coordinator_removals)
	var pending_segment_admitted: Dictionary=coordinator.submit_prepared_segment(
		pending_boundary_id,roster_replace_input)
	for provider in source_providers:
		if provider.provider_id=="ordinary_structures":
			provider.source_revision="coordinator-rev-2"
	var pending_boundary_first: Dictionary=coordinator.advance_boundary_from_roster(
		[Vector3i.ZERO],coordinator_materials,coordinator_meshes,1)
	var pending_boundary_second: Dictionary=coordinator.advance_boundary_from_roster(
		[Vector3i.ZERO],coordinator_materials,coordinator_meshes,1)
	for provider in source_providers:
		if provider.provider_id=="ecology_and_static_props":
			provider.coverage_state="pending"
	var provider_pending_advance: Dictionary=coordinator.advance_boundary_from_roster(
		[Vector3i.ZERO],coordinator_materials,coordinator_meshes,1)
	var retained_pending_slot: Dictionary=section_backend.call("installed_snapshot",coordinator_slot_id)
	for provider in source_providers:
		if provider.provider_id=="ecology_and_static_props":
			provider.coverage_state="normal"
		if provider.provider_id=="ordinary_structures":
			provider.source_revision=coordinator_revision
	diagnostics["worldCoordinatorPendingProvider"]={"enqueued":pending_enqueue,
		"segmentAdmitted":pending_segment_admitted,"firstAdvance":pending_boundary_first,
		"secondAdvance":pending_boundary_second,"pendingAdvance":provider_pending_advance,
		"retainedSlot":retained_pending_slot}
	_check("world_coordinator_cancels_active_single_section_when_provider_becomes_pending",
		pending_enqueue.get("status")=="queued" \
		and pending_segment_admitted.get("status")=="queued" \
		and pending_boundary_first.get("status")=="pending" \
		and pending_boundary_second.get("status") in ["pending", "pending_owner"] \
		and provider_pending_advance.get("status")=="failed" \
		and provider_pending_advance.get("requiresResubmit",false) \
		and provider_pending_advance.get("cancelled",false) \
		and int(retained_pending_slot.get("generation",0))==1)
	var stale_declaration_segment: Dictionary=coordinator_declaration_segment.duplicate(false)
	stale_declaration_segment["segmentId"]="coordinator-segment-2"
	stale_declaration_segment.make_read_only()
	var stale_declaration_segments: Array[Dictionary]=[stale_declaration_segment]
	stale_declaration_segments.make_read_only()
	var stale_declaration: Dictionary=coordinator_declaration.duplicate(false)
	stale_declaration["sourceRevision"]="coordinator-rev-2"
	stale_declaration["segments"]=stale_declaration_segments
	stale_declaration.make_read_only()
	var stale_declarations: Array[Dictionary]=[stale_declaration]
	stale_declarations.make_read_only()
	var stale_boundary_id:="coordinator-boundary-incomplete-census"
	coordinator.enqueue_boundary(stale_boundary_id,stale_declarations,coordinator_removals)
	var stale_input: Dictionary=coordinator_input.duplicate(false)
	stale_input["sourceRevision"]="coordinator-rev-2"
	stale_input["segmentId"]="coordinator-segment-2"
	stale_input.make_read_only()
	coordinator.submit_prepared_segment(stale_boundary_id,stale_input)
	var stale_revisions: Dictionary={coordinator_identity:"coordinator-rev-2"}
	stale_revisions.make_read_only()
	var incomplete_contributors: Array[String]=[coordinator_identity,StaticContributorLedger._source_part_identity_key("undiscovered-source","undiscovered-part")]
	incomplete_contributors.make_read_only()
	var incomplete_census: Dictionary={Vector3i.ZERO:incomplete_contributors}
	incomplete_census.make_read_only()
	var incomplete_result: Dictionary=coordinator.advance_boundary(stale_revisions,
		incomplete_census,coordinator_materials,coordinator_meshes,4)
	var retained_coordinator_slot: Dictionary=section_backend.call("installed_snapshot",coordinator_slot_id)
	diagnostics["worldCoordinatorIncompleteCensus"]={"result":incomplete_result,
		"status":coordinator.status(),"backend":retained_coordinator_slot}
	_check("world_coordinator_rejects_incomplete_source_census_without_replacing_slot",
		incomplete_result.get("status")=="failed" \
		and String(incomplete_result.get("reason","" )).begins_with("section_candidate_contributor_census_mismatch:") \
		and int(retained_coordinator_slot.get("generation",0))==1 \
		and coordinator.status().get("committedSourcePartIds",[]).has(coordinator_part_id))
	var spanning_boundary_id:="coordinator-boundary-spanning-sections"
	var spanning_first_segment: Dictionary=coordinator_declaration_segment.duplicate(false)
	spanning_first_segment["segmentId"]="coordinator-segment-spanning-a"
	spanning_first_segment.make_read_only()
	var spanning_second_segment: Dictionary=coordinator_declaration_segment.duplicate(false)
	spanning_second_segment["segmentId"]="coordinator-segment-spanning-b"
	spanning_second_segment.make_read_only()
	var spanning_segments: Array[Dictionary]=[spanning_first_segment,spanning_second_segment]
	spanning_segments.make_read_only()
	var coordinator_contributors: Array[String]=[coordinator_identity]
	coordinator_contributors.make_read_only()
	var spanning_declaration: Dictionary=coordinator_declaration.duplicate(false)
	spanning_declaration["sourceRevision"]="coordinator-rev-spanning"
	spanning_declaration["segments"]=spanning_segments
	spanning_declaration.make_read_only()
	var spanning_declarations: Array[Dictionary]=[spanning_declaration]
	spanning_declarations.make_read_only()
	var spanning_enqueued: Dictionary=coordinator.enqueue_boundary(spanning_boundary_id,
		spanning_declarations,coordinator_removals)
	var spanning_first_input: Dictionary=coordinator_input.duplicate(false)
	spanning_first_input["sourceRevision"]="coordinator-rev-spanning"
	spanning_first_input["segmentId"]="coordinator-segment-spanning-a"
	spanning_first_input.make_read_only()
	var spanning_first_admitted: Dictionary=coordinator.submit_prepared_segment(
		spanning_boundary_id,spanning_first_input)
	var spanning_buffer: Array[float]=[]
	for value: float in InstanceBuffer.encode(Transform3D(Basis.IDENTITY,Vector3(50.5,0.5,0.5)),Color(0.3,0.7,0.4,1.0)):
		spanning_buffer.append(value)
	spanning_buffer.make_read_only()
	var spanning_second_input: Dictionary=coordinator_input.duplicate(false)
	spanning_second_input["sourceRevision"]="coordinator-rev-spanning"
	spanning_second_input["segmentId"]="coordinator-segment-spanning-b"
	spanning_second_input["buffer"]=spanning_buffer
	spanning_second_input.make_read_only()
	var spanning_second_admitted: Dictionary=coordinator.submit_prepared_segment(
		spanning_boundary_id,spanning_second_input)
	var spanning_revisions: Dictionary={coordinator_identity:"coordinator-rev-spanning"}
	spanning_revisions.make_read_only()
	var spanning_census: Dictionary={
		Vector3i.ZERO:coordinator_contributors,
		Vector3i(2,0,0):coordinator_contributors}
	spanning_census.make_read_only()
	var spanning_install: Dictionary={"status":"pending"}
	var spanning_turns:=0
	while spanning_turns<128 and spanning_install.get("status") not in ["committed","failed","unsupported"]:
		spanning_install=coordinator.advance_boundary(spanning_revisions,
			spanning_census,coordinator_materials,coordinator_meshes,4)
		spanning_turns+=1
		await process_frame
	var spanning_slot_a:=StaticSectionInstallSession.slot_id(coordinator_world,Vector3i.ZERO)
	var spanning_slot_b:=StaticSectionInstallSession.slot_id(coordinator_world,Vector3i(2,0,0))
	var spanning_installed_a: Dictionary=section_backend.call("installed_snapshot",spanning_slot_a)
	var spanning_owner_b: Dictionary=PacketOwner.resolve_existing_static_section_backend(Vector2i(1,0))
	var spanning_backend_b: Node=spanning_owner_b.get("backend") as Node
	var spanning_installed_b: Dictionary=spanning_backend_b.call("installed_snapshot",spanning_slot_b) \
		if is_instance_valid(spanning_backend_b) else {"status":"missing_backend"}
	diagnostics["worldCoordinatorSpanningSectionInstall"]={"enqueued":spanning_enqueued,
		"firstSegment":spanning_first_admitted,"secondSegment":spanning_second_admitted,
		"lastAdvance":spanning_install,"turns":spanning_turns,
		"sectionA":spanning_installed_a,"ownerB":spanning_owner_b,
		"sectionB":spanning_installed_b}
	_check("world_coordinator_installs_and_promotes_all_sections_for_spanning_source",
		spanning_enqueued.get("status")=="queued" \
		and spanning_first_admitted.get("status")=="queued" \
		and spanning_second_admitted.get("status")=="queued" \
		and spanning_install.get("status")=="committed" \
		and spanning_install.get("sectionKeys",[]).size()==2 \
		and spanning_installed_a.get("status")=="ready" \
		and spanning_installed_b.get("status")=="ready" \
		and spanning_owner_b.get("status")=="ready" \
		and spanning_backend_b.get_parent()!=section_backend.get_parent() \
		and int(spanning_installed_a.get("generation",0))>1 \
		and int(spanning_installed_a.get("generation",0))==int(spanning_installed_b.get("generation",0)) \
		and coordinator.status().get("committedSourcePartIds",[]).has(coordinator_part_id))
	var retained_generation:=int(replacement_snapshot.get("generation",0))
	var retained_payload_bytes:=int(replacement_snapshot.get("payloadBytes",0))
	var section_root_id:=int(replacement_snapshot.get("rootInstanceId",0))
	var cancelled_candidate: Dictionary=section_candidate.duplicate(false)
	cancelled_candidate["generation"]=retained_generation+1
	cancelled_candidate["contentManifestDigest"]=StaticSectionSnapshotBuilder._snapshot_digest(
		section_snapshot,String(cancelled_candidate.worldId),int(cancelled_candidate.generation),cancelled_candidate.sectionKey)
	cancelled_candidate.make_read_only()
	var cancelled_started: Dictionary=PacketOwner.begin_static_section_install(cancelled_candidate,
		{"native-section-material":section_material},{"unit-box-v1":section_mesh_expected})
	var cancelled_session: Variant=cancelled_started.get("session")
	var cancelled_append: Dictionary=cancelled_session.advance(1) \
		if cancelled_session is RefCounted else {"status":"missing"}
	var cancel_receipt: Dictionary=cancelled_session.cancel() if cancelled_session is RefCounted else {"status":"missing"}
	var retained_after_cancel: Dictionary=section_backend.call("installed_snapshot",section_slot_id)
	var overlap_metrics: Dictionary=section_backend.call("metrics")
	_check("cancelled_section_replacement_keeps_previous_native_root_visible",
		cancelled_append.get("stage")=="append" and cancel_receipt.get("status")=="cancelled" \
		and retained_after_cancel.get("status")=="ready" \
		and int(retained_after_cancel.get("generation",0))==retained_generation \
		and int(retained_after_cancel.get("rootInstanceId",0))==section_root_id \
		and int(overlap_metrics.get("installedMeshPayloadBytes",0))>0 \
		and int(overlap_metrics.get("retiringPayloadBytes",0))>=retained_payload_bytes \
		and int(overlap_metrics.get("residentPayloadBytes",0))>=retained_payload_bytes*2)
	var stale_section_start: Dictionary=PacketOwner.begin_static_section_install(section_candidate,
		{"native-section-material":section_material},{"unit-box-v1":section_mesh_expected})
	_check("native_section_slot_rejects_reused_generation",
		stale_section_start.get("status")=="failed" \
		and stale_section_start.get("reason")=="stale_section_slot_generation")
	var owner_swap_started: Dictionary=PacketOwner.begin_static_section_install(cancelled_candidate,
		{"native-section-material":section_material},{"unit-box-v1":section_mesh_expected})
	var owner_swap_session: Variant=owner_swap_started.get("session")
	var previous_section_owner: Variant=scene.static_section_render_owners[OWNER_CELL]
	var replacement_registry_chunk:=Node3D.new()
	replacement_registry_chunk.name="Chunk_0_0"
	scene.static_section_render_owners[OWNER_CELL]=replacement_registry_chunk
	var owner_swap_result: Dictionary=owner_swap_session.advance(4) if owner_swap_session is RefCounted \
		else {"status":"missing"}
	scene.static_section_render_owners[OWNER_CELL]=previous_section_owner
	replacement_registry_chunk.free()
	_check("section_install_revalidates_registry_owner_before_upload",
		owner_swap_started.get("status")=="ready" \
		and owner_swap_result.get("status")=="failed" \
		and owner_swap_result.get("reason")=="section_install_owner_replaced" \
		and int(section_backend.call("installed_snapshot",section_slot_id).get("generation",0))==retained_generation)
	var cross_chunk_snapshot: Dictionary=section_snapshot.duplicate(false)
	var cross_chunk_dependencies: Array[Vector2i]=[OWNER_CELL,Vector2i(1,0)]
	cross_chunk_dependencies.make_read_only()
	cross_chunk_snapshot["streamChunkDependencies"]=cross_chunk_dependencies
	cross_chunk_snapshot.make_read_only()
	var cross_chunk_candidate: Dictionary=section_candidate.duplicate(false)
	cross_chunk_candidate["generation"]=retained_generation+1
	cross_chunk_candidate["snapshot"]=cross_chunk_snapshot
	cross_chunk_candidate["contentManifestDigest"]=StaticSectionSnapshotBuilder._snapshot_digest(
		cross_chunk_snapshot,String(cross_chunk_candidate.worldId),int(cross_chunk_candidate.generation),cross_chunk_candidate.sectionKey)
	cross_chunk_candidate.make_read_only()
	var cross_chunk_start: Dictionary=PacketOwner.begin_static_section_install(cross_chunk_candidate,
		{"native-section-material":section_material},{"unit-box-v1":section_mesh_expected})
	var cross_chunk_session: Variant=cross_chunk_start.get("session")
	var cross_chunk_cancel: Dictionary=cross_chunk_session.cancel() \
		if cross_chunk_session is RefCounted else {"status":"missing"}
	_check("section_owner_accepts_cross_chunk_manifest_and_retains_old_slot_on_cancel",
		cross_chunk_start.get("status")=="ready" \
		and cross_chunk_cancel.get("status")=="cancelled" \
		and cross_chunk_start.get("chunk")!=first_chunk \
		and int(section_backend.call("installed_snapshot",section_slot_id).get("generation",0))==retained_generation)
	var instance_transform:=Transform3D(Basis.IDENTITY,Vector3(0.5,0.5,0.5))
	var buffer: Array[float]=[]
	for value: float in InstanceBuffer.encode(instance_transform,Color.WHITE): buffer.append(value)
	buffer.make_read_only()
	var segment: Dictionary={"buffer":buffer,"bounds":AABB(Vector3.ZERO,Vector3.ONE),"instanceCount":1}
	segment.make_read_only()
	var segments: Dictionary={0:segment}
	var group: Dictionary={"material":material,"transforms":[instance_transform],"customData":[Color.WHITE],
		"renderTier":"structural","ownerCell":OWNER_CELL,"renderChunkKey":OWNER_CELL,
		"sourcePartId":"native-wall",
		"sourceRevision":"native-wall-revision-1","materialKey":"native-contract-material",
		"preparedSegments":segments}
	publisher.static_visual_batches={"native-wall-group":group}
	publisher._record_completed_source_part(FixturePart.new({"id":"native-wall","kind":"wall"}))
	publisher._begin_static_flush(parent,false,true)
	var flush: Dictionary={"status":"pending_budget"}
	var flush_turns:=0
	while publisher.has_pending_static_flush() and flush_turns<128:
		flush=publisher.advance_static_flush(parent,4000)
		flush_turns+=1
	var production_ids: Array[String]=publisher.chunk_static_packet_source_ids("native-wall")
	var production_id:=production_ids[0] if not production_ids.is_empty() else ""
	diagnostics["productionFlush"]={"flush":flush,"turns":flush_turns,"failure":publisher._paving_failure,
		"groupsRemaining":publisher.static_visual_batches.size(),"pendingExpected":publisher._chunk_static_packet_pending_expected,
		"expected":publisher._chunk_static_packet_expected,"receiptParts":publisher._chunk_static_packet_receipts.keys(),
		"productionId":production_id,"registryHasChunk":scene.chunks.has(OWNER_CELL)}
	_check("production_static_flush_installs_through_native_backend",production_id!="" \
		and publisher.chunk_static_packet_receipt_live("native-wall",production_id) \
		and publisher._chunk_static_packet_recipes.has(production_id))
	var logical_cell:=Vector2i.ZERO
	var actual_render_chunk:=StaticRenderSectionGrid.chunk_key_for_world_position(Vector3(40.0,0.5,0.5))
	var source_owner_size_meters:=StaticRenderSectionGrid.CELL_SIZE_METERS \
		* float(StaticRenderSectionGrid.LOGICAL_OWNER_SIZE_CELLS)
	var logical_cell_at_40m:=Vector2i(floori(40.0/source_owner_size_meters),floori(0.5/source_owner_size_meters))
	_check("32_cell_source_owner_differs_from_28_cell_stream_chunk",logical_cell==Vector2i.ZERO \
		and logical_cell_at_40m==Vector2i.ZERO and actual_render_chunk==Vector2i(1,0) \
		and StaticRenderSectionGrid.LOGICAL_OWNER_SIZE_CELLS==32 \
		and StaticRenderSectionGrid.STREAM_CHUNK_SIZE_CELLS==VoxelTerrainRuntime.GAME_CHUNK_SIZE)
	# Exercise the production flush at a nonzero coordinate where the logical
	# 32-cell source owner and 28-cell Main chunk indices differ. Cell-zero-only
	# checks previously let the wrong owner grid pass.
	var mismatch_chunk:=_make_chunk(scene,actual_render_chunk)
	var mismatch_backend_result:=PacketOwner.attach_to_chunk(mismatch_chunk)
	var mismatch_backend: Node=mismatch_backend_result.get("backend") as Node
	var mismatch_parent:=Node3D.new()
	mismatch_parent.name="NonzeroChunkBuildingSite"
	mismatch_parent.position=Vector3(40.0,0.5,0.5)
	scene.add_child(mismatch_parent)
	var mismatch_publisher:=PacketBuildingPublisher.new()
	mismatch_publisher.source_blueprint_id="native-nonzero-blueprint"
	mismatch_publisher.publication_site_id="native-nonzero-site"
	var mismatch_material:=StandardMaterial3D.new()
	mismatch_publisher.material_cache["native-nonzero-material"]=mismatch_material
	var mismatch_transform:=Transform3D(Basis.IDENTITY,Vector3(0.5,0.5,0.5))
	var mismatch_buffer: Array[float]=[]
	for value: float in InstanceBuffer.encode(mismatch_transform,Color.WHITE): mismatch_buffer.append(value)
	mismatch_buffer.make_read_only()
	var mismatch_segment: Dictionary={"buffer":mismatch_buffer,"bounds":AABB(Vector3.ZERO,Vector3.ONE),"instanceCount":1}
	mismatch_segment.make_read_only()
	var mismatch_segments: Dictionary={0:mismatch_segment}
	var mismatch_group: Dictionary={"material":mismatch_material,"transforms":[mismatch_transform],"customData":[Color.WHITE],
		"renderTier":"structural","ownerCell":logical_cell,"renderChunkKey":actual_render_chunk,
		"sourcePartId":"nonzero-wall","sourceRevision":"nonzero-wall-revision-1",
		"materialKey":"native-nonzero-material","preparedSegments":mismatch_segments}
	mismatch_publisher.static_visual_batches={"nonzero-wall-group":mismatch_group}
	var mismatch_part:=FixturePart.new({"id":"native-wall","kind":"wall"})
	mismatch_part.id="nonzero-wall"
	mismatch_publisher._record_completed_source_part(mismatch_part)
	mismatch_publisher._begin_static_flush(mismatch_parent,false,true)
	var mismatch_flush: Dictionary={"status":"pending_budget"}
	var mismatch_turns:=0
	while mismatch_publisher.has_pending_static_flush() and mismatch_turns<128:
		mismatch_flush=mismatch_publisher.advance_static_flush(mismatch_parent,4000)
		mismatch_turns+=1
	var mismatch_ids: Array[String]=mismatch_publisher.chunk_static_packet_source_ids("nonzero-wall")
	var mismatch_id:=mismatch_ids[0] if not mismatch_ids.is_empty() else ""
	var mismatch_receipt: Dictionary=mismatch_publisher._chunk_static_packet_receipts.get("nonzero-wall",{}).get(mismatch_id,{})
	_check("production_packet_attaches_to_actual_28_cell_stream_chunk",mismatch_flush.get("status")=="ready" \
		and mismatch_id!="" and mismatch_receipt.get("ownerCell")==Vector2i(1,0) \
		and mismatch_receipt.get("chunk") is WeakRef and mismatch_receipt.chunk.get_ref()==mismatch_chunk \
		and mismatch_backend.call("receipt_installed",mismatch_id,int(mismatch_receipt.get("generation",0)),
			String(mismatch_receipt.get("sourceRevision","")),String(mismatch_receipt.get("packetDigest",""))))
	mismatch_publisher._chunk_static_packet_expected.erase("nonzero-wall")
	_check("nonzero_packet_retires_from_actual_chunk_owner",mismatch_id!="" \
		and mismatch_publisher.retire_chunk_static_packet_if_unexpected("nonzero-wall",mismatch_id) \
		and mismatch_backend.call("installed_snapshot",mismatch_id).get("status")=="missing")
	mismatch_parent.free()
	mismatch_chunk.free()
	var first_chunk_id:=first_chunk.get_instance_id()
	scene.chunks.erase(OWNER_CELL)
	first_chunk.free()
	var replacement_chunk := _make_chunk(scene,OWNER_CELL)
	var replacement_owner := PacketOwner.attach_to_chunk(replacement_chunk)
	_check("native_backend_recreated_for_replacement_chunk",replacement_chunk.get_instance_id()!=first_chunk_id \
		and replacement_owner.get("status")=="ready" and replacement_owner.backend.get_parent()==replacement_chunk)
	var replacement_backend: Node=replacement_owner.get("backend") as Node
	var production_replay: Dictionary={"status":"pending_budget"}
	var replay_turns:=0
	while production_replay.status=="pending_budget" and replay_turns<128:
		production_replay=publisher.advance_chunk_static_packet_replay(parent,4000)
		replay_turns+=1
	_check("production_static_packet_replays_after_chunk_recreation",production_replay.get("status")=="completed" \
		and publisher.chunk_static_packet_receipt_live("native-wall",production_id) \
		and replacement_backend.call("receipt_installed",production_id,
			int(publisher._chunk_static_packet_expected["native-wall"][production_id].generation),
			String(publisher._chunk_static_packet_expected["native-wall"][production_id].sourceRevision),
			String(publisher._chunk_static_packet_expected["native-wall"][production_id].packetDigest)))
	_check("native_packet_republishes_after_chunk_replacement",_install(replacement_backend,3) \
		and replacement_backend.call("receipt_installed",SOURCE_ID,3,SOURCE_REVISION,PACKET_DIGEST))
	publisher._chunk_static_packet_expected.erase("native-wall")
	_check("production_static_packet_release_acknowledged",production_id!="" \
		and publisher.retire_chunk_static_packet_if_unexpected("native-wall",production_id) \
		and not publisher._chunk_static_packet_recipes.has(production_id) \
		and replacement_backend.call("installed_snapshot",production_id).get("status")=="missing")
	var released: Dictionary=replacement_backend.call("release_packet",SOURCE_ID,3)
	_check("native_packet_release_acknowledged",released.get("status")=="released" \
		and replacement_backend.call("installed_snapshot",SOURCE_ID).get("status")=="missing")
	var capacity_cell:=Vector2i(2,2)
	var capacity_chunk:=_make_chunk(scene,capacity_cell)
	var capacity_owner:=PacketOwner.attach_to_chunk(capacity_chunk)
	var capacity_backend: Node=capacity_owner.get("backend") as Node
	var capacity_installs_ok: bool=capacity_owner.get("status")=="ready"
	for index in range(128):
		var source_id: String="capacity:%03d" % index
		var begun: Dictionary=capacity_backend.call("begin_packet",source_id,capacity_cell,1,
			"capacity-revision","capacity-digest",Transform3D.IDENTITY,0,0)
		if begun.get("status")!="ready_to_append": capacity_installs_ok=false; break
		var committed: Dictionary=capacity_backend.call("commit_packet",source_id,1)
		if committed.get("status")!="ready": capacity_installs_ok=false; break
	_check("native_packet_capacity_fixture_fills_installed_limit",capacity_installs_ok \
		and int(capacity_backend.call("metrics").installedPackets)==128)
	diagnostics["capacityFixture"]={"ownerStatus":capacity_owner.get("status"),
		"installed":capacity_backend.call("metrics").get("installedPackets"),
		"cell":capacity_cell,"parentPosition":capacity_chunk.position}
	var capacity_parent:=Node3D.new()
	capacity_parent.name="NativePacketCapacityBuildingSite"
	capacity_parent.position=Vector3(capacity_cell.x*43.2+0.5,0.5,capacity_cell.y*43.2+0.5)
	scene.add_child(capacity_parent)
	var capacity_publisher:=PacketBuildingPublisher.new()
	capacity_publisher.source_blueprint_id="native-capacity-blueprint"
	capacity_publisher.publication_site_id="native-capacity-site"
	var capacity_material:=StandardMaterial3D.new()
	capacity_publisher.material_cache["native-capacity-material"]=capacity_material
	var capacity_transform:=Transform3D(Basis.IDENTITY,Vector3(0.5,0.5,0.5))
	var capacity_buffer: Array[float]=[]
	for value: float in InstanceBuffer.encode(capacity_transform,Color.WHITE): capacity_buffer.append(value)
	capacity_buffer.make_read_only()
	var capacity_segment: Dictionary={"buffer":capacity_buffer,"bounds":AABB(Vector3.ZERO,Vector3.ONE),"instanceCount":1}
	capacity_segment.make_read_only()
	var capacity_segments: Dictionary={0:capacity_segment}
	var capacity_group: Dictionary={"material":capacity_material,"transforms":[capacity_transform],"customData":[Color.WHITE],
		"renderTier":"structural","ownerCell":capacity_cell,"renderChunkKey":capacity_cell,
		"sourcePartId":"capacity-wall",
		"sourceRevision":"capacity-wall-revision-1","materialKey":"native-capacity-material",
		"preparedSegments":capacity_segments}
	capacity_publisher.static_visual_batches={"capacity-wall-group":capacity_group}
	capacity_publisher._record_completed_source_part(FixturePart.new({"id":"native-wall","kind":"wall"}))
	capacity_publisher._begin_static_flush(capacity_parent,false,true)
	var capacity_flush: Dictionary={"status":"pending_budget"}
	var capacity_turns:=0
	while capacity_publisher.has_pending_static_flush() and capacity_turns<128:
		capacity_flush=capacity_publisher.advance_static_flush(capacity_parent,4000)
		capacity_turns+=1
	var capacity_metrics: Dictionary=capacity_backend.call("metrics")
	diagnostics["capacityFlush"]={"flush":capacity_flush,"turns":capacity_turns,"metrics":capacity_metrics,
		"failure":capacity_publisher._paving_failure}
	_check("production_flush_fails_closed_at_installed_packet_capacity",capacity_flush.get("status")=="failed" \
		and String(capacity_flush.get("reason",""))=="chunk_packet_installed_capacity" \
		and int(capacity_metrics.get("installedPackets",0))==128 and int(capacity_metrics.get("stagedPackets",-1))==0)
	var main := MainRuntimeHarness.new()
	main.name="MainRuntimeChunkOwnerHarness"
	scene.add_child(main)
	var chunk_root := Node3D.new()
	chunk_root.name="ChunkRoot"
	main.add_child(chunk_root)
	main.chunk_root=chunk_root
	var static_section_root:=Node3D.new()
	static_section_root.name="StaticSectionOwners"
	main.add_child(static_section_root)
	main.static_section_render_root=static_section_root
	var terrain_runtime := VoxelTerrainRuntime.new()
	terrain_runtime.main=main
	terrain_runtime.site_gate=AdmissionGateStub.new()
	main.add_child(terrain_runtime)
	main.voxel_terrain_runtime=terrain_runtime
	main.create_voxel_authority_chunk_container(OWNER_CELL.x,OWNER_CELL.y,true)
	var streamed_chunk: Node3D=main.chunks.get(OWNER_CELL) as Node3D
	var prop_state: Variant=main.pending_chunk_prop_spawns.get(OWNER_CELL)
	var state_chunk: Node3D=prop_state.get("chunk") as Node3D if prop_state is Dictionary else null
	diagnostics["mainRuntimeCreation"]={"terrainPending":terrain_runtime.pending_gameplay_chunks.has(OWNER_CELL),
		"chunks":main.chunks.keys(),"pendingPropKeys":main.pending_chunk_prop_spawns.keys(),
		"propStateType":type_string(typeof(prop_state)),
		"propChunkValid":is_instance_valid(state_chunk),
		"streamedChunkId":streamed_chunk.get_instance_id() if is_instance_valid(streamed_chunk) else 0,
		"propChunkId":state_chunk.get_instance_id() if is_instance_valid(state_chunk) else 0}
	_check("main_runtime_creates_chunk_owned_native_backend",is_instance_valid(streamed_chunk) \
		and streamed_chunk.get_parent()==chunk_root \
		and streamed_chunk.has_node("ChunkRenderPacketBackend"))
	var section_owner_result: Dictionary=main.get_static_section_render_owner(Vector2i(1,0),true)
	var static_section_owner: Node3D=section_owner_result.get("owner") as Node3D
	diagnostics["mainRuntimeSectionOwner"]={"result":section_owner_result,
		"rootValid":is_instance_valid(main.static_section_render_root),
		"rootInsideTree":main.static_section_render_root.is_inside_tree() if is_instance_valid(main.static_section_render_root) else false,
		"ownerInsideTree":static_section_owner.is_inside_tree() if is_instance_valid(static_section_owner) else false,
		"ownerPosition":static_section_owner.position if is_instance_valid(static_section_owner) else Vector3.ZERO,
		"ownerParentMatches":static_section_owner.get_parent()==static_section_root if is_instance_valid(static_section_owner) else false,
		"ownerHasBackend":static_section_owner.has_node("ChunkRenderPacketBackend") if is_instance_valid(static_section_owner) else false,
		"ownerDistinctFromGameplay":static_section_owner!=main.chunks.get(Vector2i(1,0)) if is_instance_valid(static_section_owner) else false,
		"ownerPositionMatches":static_section_owner.position.x==Vector2i(1,0).x*StaticRenderSectionGrid.STREAM_CHUNK_SIZE_METERS if is_instance_valid(static_section_owner) else false,
		"expectedPositionX":StaticRenderSectionGrid.STREAM_CHUNK_SIZE_METERS}
	_check("main_runtime_creates_independent_static_section_owner",
		section_owner_result.get("status")=="ready" \
		and is_instance_valid(static_section_owner) \
		and static_section_owner.get_parent()==static_section_root \
		and static_section_owner!=main.chunks.get(Vector2i(1,0)) \
		and static_section_owner.has_node("ChunkRenderPacketBackend") \
		and is_equal_approx(static_section_owner.position.x,
			Vector2i(1,0).x*StaticRenderSectionGrid.STREAM_CHUNK_SIZE_METERS))
	main.prune_static_section_render_owners({Vector2i(1,0):true})
	var retained_static_owner: bool=main.static_section_render_owners.has(Vector2i(1,0))
	main.prune_static_section_render_owners({})
	_check("main_runtime_retires_static_section_owner_after_render_demand",
		retained_static_owner and not main.static_section_render_owners.has(Vector2i(1,0)) \
		and static_section_owner.is_queued_for_deletion())
	_check("main_runtime_admits_and_requests_production_chunk",terrain_runtime.site_gate!=null \
		and terrain_runtime.desired_gameplay_chunks.has(OWNER_CELL) \
		and terrain_runtime.pending_gameplay_chunks.has(OWNER_CELL) \
		and is_instance_valid(state_chunk) and state_chunk.get_instance_id()==streamed_chunk.get_instance_id())
	var retired:=main.retire_streamed_chunk_container(OWNER_CELL)
	_check("main_runtime_releases_backend_before_unregistering_chunk",retired \
		and not terrain_runtime.desired_gameplay_chunks.has(OWNER_CELL) \
		and not terrain_runtime.pending_gameplay_chunks.has(OWNER_CELL) \
		and not main.chunks.has(OWNER_CELL) and streamed_chunk.is_queued_for_deletion())
	await process_frame
	_check("main_runtime_chunk_retirement_frees_native_owner",not is_instance_valid(streamed_chunk))
	main.create_voxel_authority_chunk_container(OWNER_CELL.x,OWNER_CELL.y,true)
	var retained_chunk: Node3D=main.chunks.get(OWNER_CELL) as Node3D
	terrain_runtime.retained_gameplay_chunks[OWNER_CELL]=true
	var retained_retire:=main.retire_streamed_chunk_container(OWNER_CELL)
	_check("main_runtime_preserves_retained_terrain_owner",not retained_retire \
		and main.chunks.get(OWNER_CELL)==retained_chunk and is_instance_valid(retained_chunk) \
		and not retained_chunk.is_queued_for_deletion())
	terrain_runtime.retained_gameplay_chunks.erase(OWNER_CELL)
	terrain_runtime.startup_auxiliary_publication_chunks[OWNER_CELL]=true
	var auxiliary_retire:=main.retire_streamed_chunk_container(OWNER_CELL)
	_check("main_runtime_preserves_startup_auxiliary_terrain_owner",not auxiliary_retire \
		and main.chunks.get(OWNER_CELL)==retained_chunk and is_instance_valid(retained_chunk) \
		and not retained_chunk.is_queued_for_deletion())
	terrain_runtime.startup_auxiliary_publication_chunks.erase(OWNER_CELL)
	_check("main_runtime_retires_owner_after_dependencies_release",main.retire_streamed_chunk_container(OWNER_CELL))
	_finish(not checks.values().has(false),"")
	parent.free()


func _test_citadel_section_membership_query() -> void:
	var plan = CitadelPublicationPlan.new()
	var low := {"memberId":"negative-low","groupId":"group-low",
		"bounds":AABB(Vector3(-22.0,1.0,-2.0),Vector3(2.0,2.0,4.0)),"visual":true}
	var high := {"memberId":"negative-high","groupId":"group-high",
		"bounds":AABB(Vector3(-22.0,50.0,-2.0),Vector3(2.0,2.0,4.0)),"visual":true}
	var flat := {"memberId":"flat-origin","groupId":"group-flat",
		"bounds":AABB(Vector3(-2.0,0.0,-2.0),Vector3(4.0,0.0,4.0)),"visual":true}
	for record: Dictionary in [low,high,flat]: record.make_read_only()
	plan.member_records.append_array([low,high,flat])
	plan.member_records.make_read_only()
	plan.member_buckets={"-1,-1":[0,1,2],"-1,0":[0,1,2],"0,-1":[2],"0,0":[2]}
	for indices: Array in plan.member_buckets.values(): indices.make_read_only()
	plan.member_buckets.make_read_only()
	var negative_section := AABB(Vector3(-21.6,0.0,-21.6),Vector3.ONE*21.6)
	var low_query: Dictionary=plan.visual_members_intersecting_bounds(negative_section)
	var found_low := false
	var wrongly_found_high := false
	var found_flat := false
	for record: Dictionary in low_query.get("members",[]):
		found_low = found_low or String(record.memberId)=="negative-low"
		wrongly_found_high = wrongly_found_high or String(record.memberId)=="negative-high"
		found_flat = found_flat or String(record.memberId)=="flat-origin"
	_check("citadel_plan_section_query_filters_full_3d_bounds",low_query.get("status")=="described" \
		and low_query.get("descriptionComplete",false) and found_low and not wrongly_found_high)
	var below_section := AABB(Vector3(-21.6,-21.6,-21.6),Vector3.ONE*21.6)
	var flat_below: Dictionary=plan.visual_members_intersecting_bounds(below_section)
	_check("citadel_plan_flat_visual_belongs_to_one_vertical_section",
		found_flat and not flat_below.get("members",[]).any(
			func(record: Dictionary): return String(record.memberId)=="flat-origin"))
	var touching := AABB(Vector3(-25.6,4.0,-4.0),Vector3(4.0,2.0,4.0))
	var crossing := AABB(Vector3(-25.6,4.0,-4.0),Vector3(4.01,2.0,4.0))
	_check("citadel_plan_negative_section_edges_are_half_open",
		not CitadelPublicationPlan._aabb_intersects_section(touching,negative_section) \
		and CitadelPublicationPlan._aabb_intersects_section(crossing,negative_section))
	var provider := CitadelPublicationService.new()
	provider.configure(EmptyCitadelAdmission.new())
	var world_id := "seed:section-census-contract:%d" % CitadelPublicationService._seed_hash("section-census-contract")
	var empty_snapshot: Dictionary=provider.capture_static_section_sources(world_id,[Vector3i.ZERO])
	var empty_row: Dictionary=empty_snapshot.get("sections",{}).get(Vector3i.ZERO,{})
	_check("citadel_section_provider_returns_revisioned_explicit_empty",
		empty_snapshot.get("status")=="complete" and empty_snapshot.get("worldId")==world_id \
		and String(empty_snapshot.get("authorityRevision","" )).length()==64 \
		and empty_row.get("status")=="empty" and String(empty_row.get("coverageRevision","")).length()==64 \
		and empty_row.get("sourcePartIds",[]).is_empty() and empty_snapshot.get("sourceRevisions",{}).is_empty())
	provider.request_shutdown()


func _append_native_layer_batch(backend: Node, source_id: String, generation: int,
		batch_id: String, mesh: Mesh, mesh_digest: String, material: Material,
		render_layer: String, origin: Vector3, intended_visible := true) -> Dictionary:
	var buffer: PackedFloat32Array=InstanceBuffer.encode(
		Transform3D(Basis.IDENTITY,origin+Vector3(0.5,0.5,0.5)),Color.WHITE)
	return backend.call("append_batch_in_layer",source_id,generation,batch_id,mesh,mesh_digest,material,
		buffer,AABB(origin,Vector3.ONE),"structural",true,240.0,18.0,render_layer,
		intended_visible)


func _probe_translucent_index_replacement(backend: Node, chunk: Node3D,
		material: Material) -> Dictionary:
	var result := {"checks":{}, "diagnostics":{}}
	var vertices := PackedVector3Array([
		Vector3(-1.0, -1.0, 0.0), Vector3(1.0, -1.0, 0.0),
		Vector3(1.0, 1.0, 0.0), Vector3(-1.0, 1.0, 0.0),
		Vector3(-1.0, -1.0, -2.0), Vector3(1.0, -1.0, -2.0),
		Vector3(1.0, 1.0, -2.0), Vector3(-1.0, 1.0, -2.0)])
	var camera_first := Vector3(0.0, 0.0, 5.0)
	var camera_next := Vector3(0.0, 0.0, -5.0)
	var base_face_groups: Array[PackedInt32Array] = [
		PackedInt32Array([0, 1, 2, 0, 2, 3]), PackedInt32Array([4, 5, 6, 4, 6, 7])]
	var far_face_first := _sort_face_groups_for_camera(vertices, base_face_groups, camera_first)
	var far_face_next := _sort_face_groups_for_camera(vertices, base_face_groups, camera_next)
	var baked := _make_translucent_face_group_mesh(vertices, far_face_first, material)
	var baked_identity: Dictionary = StaticMeshFingerprint.inspect(baked)
	var source_id := "native-contract:translucent-camera-replacement"
	var first_revision := "section-generation:1;camera-revision:4"
	var first_digest := (first_revision + String(baked_identity.get("contentDigest", ""))).sha256_text()
	var layers: Array = [
		{"layer":"opaque","expectedBatchCount":0,"expectedInstanceCount":0},
		{"layer":"cutout","expectedBatchCount":0,"expectedInstanceCount":0},
		{"layer":"translucent","expectedBatchCount":1,"expectedInstanceCount":1}]
	var begin_first: Dictionary = backend.call("begin_packet_with_layers", source_id,
		Vector2i(5, 0), 1, first_revision, first_digest, Transform3D.IDENTITY, 1, 1, layers)
	var append_first: Dictionary = _append_translucent_probe_batch(backend, source_id, 1,
		"camera-sorted-face-groups", baked, String(baked_identity.get("contentDigest", "")),
		material)
	var upload_first: Dictionary = backend.call("advance_packet", source_id, 1, 1)
	var commit_first: Dictionary = backend.call("commit_packet", source_id, 1)
	var first_snapshot: Dictionary = backend.call("installed_snapshot", source_id)
	var first_root_id := int(first_snapshot.get("rootInstanceId", 0))
	var replacement := _make_translucent_face_group_mesh(vertices, far_face_next, material)
	var camera_revision := 5
	var next_revision := "section-generation:2;camera-revision:%d" % camera_revision
	var replacement_identity: Dictionary = StaticMeshFingerprint.inspect(replacement)
	var next_digest := (next_revision + String(replacement_identity.get("contentDigest", ""))).sha256_text()
	var begin_next: Dictionary = backend.call("begin_packet_with_layers", source_id,
		Vector2i(5, 0), 2, next_revision, next_digest, Transform3D.IDENTITY, 1, 1, layers)
	var append_next: Dictionary = _append_translucent_probe_batch(backend, source_id, 2,
		"camera-sorted-face-groups-replacement", replacement,
		String(replacement_identity.get("contentDigest", "")), material)
	var upload_next: Dictionary = backend.call("advance_packet", source_id, 2, 1)
	var retained_before_commit: Dictionary = backend.call("installed_snapshot", source_id)
	var commit_next: Dictionary = backend.call("commit_packet", source_id, 2)
	var next_snapshot: Dictionary = backend.call("installed_snapshot", source_id)
	var receipt_current: bool = backend.call("receipt_installed", source_id, 2,
		next_revision, next_digest)
	var stale_camera_receipt_rejected: bool = not backend.call("receipt_installed", source_id,
		2, first_revision, next_digest)
	result.checks["translucent_sorted_mesh_installs_through_real_native_renderer"] = \
		backend.get_parent() == chunk and begin_first.get("status") == "ready_to_append" \
		and append_first.get("status") == "accepted" \
		and upload_first.get("status") == "ready_to_commit" and commit_first.get("status") == "ready"
	result.checks["translucent_camera_revision_replacement_retains_old_root_until_commit"] = \
		begin_next.get("status") == "ready_to_append" and append_next.get("status") == "accepted" \
		and upload_next.get("status") == "ready_to_commit" \
		and int(retained_before_commit.get("generation", 0)) == 1 \
		and int(retained_before_commit.get("rootInstanceId", 0)) == first_root_id
	result.checks["translucent_camera_revision_replacement_receipt_matches_current_generation"] = \
		commit_next.get("status") == "ready" and receipt_current \
		and int(next_snapshot.get("generation", 0)) == 2 \
		and next_snapshot.get("sourceRevision") == next_revision \
		and next_snapshot.get("packetDigest") == next_digest \
		and int(next_snapshot.get("rootInstanceId", 0)) != first_root_id
	result.checks["translucent_camera_revision_receipt_rejects_stale_pov_identity"] = \
		stale_camera_receipt_rejected
	result.checks["translucent_face_groups_change_order_for_camera_revision"] = \
		far_face_first == PackedInt32Array([4, 5, 6, 4, 6, 7, 0, 1, 2, 0, 2, 3]) \
		and far_face_next == PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
	result.diagnostics["nativeReplacement"] = {"beginFirst":begin_first,
		"appendFirst":append_first, "commitFirst":commit_first,
		"beginNext":begin_next, "appendNext":append_next, "uploadNext":upload_next,
		"retainedBeforeCommit":retained_before_commit, "commitNext":commit_next,
		"currentSnapshot":next_snapshot, "cameraRevision":camera_revision,
		"staleCameraReceiptRejected":stale_camera_receipt_rejected,
		"firstCameraPosition":camera_first, "replacementCameraPosition":camera_next,
		"firstFaceGroupOrder":far_face_first, "replacementFaceGroupOrder":far_face_next,
		"usesSectionBakedSingleInstance":true}
	return result


func _make_translucent_face_group_mesh(vertices: PackedVector3Array,
		indices: PackedInt32Array, material: Material) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


func _sort_face_groups_for_camera(vertices: PackedVector3Array,
		face_groups: Array[PackedInt32Array], camera: Vector3) -> PackedInt32Array:
	var sortable: Array[Dictionary] = []
	for group_index: int in range(face_groups.size()):
		var indices: PackedInt32Array = face_groups[group_index]
		var center := Vector3.ZERO
		for index_value: int in indices:
			center += vertices[index_value]
		center /= float(indices.size())
		sortable.append({"group":group_index, "distanceSquared":center.distance_squared_to(camera)})
	sortable.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a.distanceSquared), float(b.distanceSquared)):
			return int(a.group) < int(b.group)
		return float(a.distanceSquared) > float(b.distanceSquared))
	var sorted_indices := PackedInt32Array()
	for entry: Dictionary in sortable:
		sorted_indices.append_array(face_groups[int(entry.group)])
	return sorted_indices


func _append_translucent_probe_batch(backend: Node, source_id: String, generation: int,
		batch_id: String, mesh: Mesh, mesh_digest: String, material: Material) -> Dictionary:
	var buffer := InstanceBuffer.encode(Transform3D.IDENTITY, Color.WHITE)
	return backend.call("append_batch_in_layer", source_id, generation, batch_id, mesh,
		mesh_digest, material, buffer, AABB(Vector3(-1.0, -1.0, -2.0), Vector3(2.0, 2.0, 2.0)),
		"structural", false, 0.0, 0.0, "translucent")


func _probe_translucent_install_session_gate(backend: Node, chunk: Node3D,
		material: Material) -> Dictionary:
	var result := {"checks":{}, "diagnostics":{}}
	var scene := Engine.get_main_loop() as SceneTree
	var requested_owner_cell := StaticRenderSectionGrid.chunk_key_for_world_position(chunk.global_position)
	var owner_result: Dictionary = scene.current_scene.call("get_static_section_render_owner",
		requested_owner_cell, true) if scene != null and scene.current_scene != null else {}
	if owner_result.get("status") != "ready":
		return result
	var session_chunk := owner_result.get("owner") as Node3D
	var session_backend := owner_result.get("backend") as Node
	if not is_instance_valid(session_chunk) or not is_instance_valid(session_backend):
		return result
	var owner_cell := StaticRenderSectionGrid.chunk_key_for_world_position(session_chunk.global_position)
	var section_key := Vector3i.ZERO
	var found_section := false
	for x in range(0, 128):
		var candidate_key := Vector3i(x, 0, 0)
		if StaticRenderSectionGrid.chunk_key_for_section(candidate_key) == owner_cell:
			section_key = candidate_key
			found_section = true
			break
	if not found_section:
		return result
	var vertices := PackedVector3Array([
		Vector3(-1.0, -1.0, 0.0), Vector3(1.0, -1.0, 0.0),
		Vector3(1.0, 1.0, 0.0), Vector3(-1.0, 1.0, 0.0),
		Vector3(-1.0, -1.0, -2.0), Vector3(1.0, -1.0, -2.0),
		Vector3(1.0, 1.0, -2.0), Vector3(-1.0, 1.0, -2.0)])
	var first_indices := PackedInt32Array([4, 5, 6, 4, 6, 7, 0, 1, 2, 0, 2, 3])
	var next_indices := PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
	var first_mesh := _make_translucent_face_group_mesh(vertices, first_indices, material)
	var first_candidate := _translucent_install_candidate(first_mesh, section_key, 1, 4,
		Vector3(0.0, 0.0, 5.0), false)
	var first_session := StaticSectionInstallSession.new()
	var first_started: Dictionary = first_session.begin(session_backend, session_chunk,
		first_candidate.candidate, first_candidate.materials, first_candidate.meshes)
	var first_backend_now: Variant = first_session._current_backend()
	var first_chunk_now: Variant = first_session._current_chunk()
	var first_step: Dictionary = {}
	for _attempt in range(8):
		if first_started.get("status") != "begun" or first_step.get("status") == "installed" \
				or first_step.get("status") == "failed":
			break
		first_step = await _advance_presented_session(first_session,1,4)
	var installed_first: Dictionary = session_backend.call("installed_snapshot",
		StaticSectionInstallSession.slot_id(String(first_candidate.candidate.worldId), section_key))
	var first_root := int(installed_first.get("rootInstanceId", 0))
	var second_mesh := _make_translucent_face_group_mesh(vertices, next_indices, material)
	var second_candidate := _translucent_install_candidate(second_mesh, section_key, 2, 5,
		Vector3(0.0, 0.0, -5.0), false)
	var stale_session := StaticSectionInstallSession.new()
	var stale_started: Dictionary = stale_session.begin(session_backend, session_chunk,
		second_candidate.candidate, second_candidate.materials, second_candidate.meshes)
	var stale_step: Dictionary = stale_session.advance(1, 4)
	var retained_after_stale: Dictionary = session_backend.call("installed_snapshot",
		StaticSectionInstallSession.slot_id(String(second_candidate.candidate.worldId), section_key))
	var tampered_candidate := _translucent_install_candidate(second_mesh, section_key, 2, 5,
		Vector3(0.0, 0.0, -5.0), true)
	var tampered_session := StaticSectionInstallSession.new()
	var tampered_started: Dictionary = tampered_session.begin(session_backend, session_chunk,
		tampered_candidate.candidate, tampered_candidate.materials, tampered_candidate.meshes)
	var missing_descriptor_candidate := _translucent_install_candidate(first_mesh, section_key,
		3, 6, Vector3(0.0, 0.0, 5.0), false, false)
	var missing_descriptor_session := StaticSectionInstallSession.new()
	var missing_descriptor_started: Dictionary = missing_descriptor_session.begin(
		session_backend, session_chunk, missing_descriptor_candidate.candidate,
		missing_descriptor_candidate.materials, missing_descriptor_candidate.meshes)
	var retained_after_missing_descriptor: Dictionary = session_backend.call("installed_snapshot",
		StaticSectionInstallSession.slot_id(String(first_candidate.candidate.worldId), section_key))
	result.checks["translucent_session_installs_candidate_bound_to_generation_and_pov"] = \
		first_started.get("status") == "begun" and first_step.get("status") == "installed" \
		and int(first_step.get("receipt", {}).get("translucentPovRevision", -1)) == 4 \
		and String(first_step.get("receipt", {}).get("sourceRevision", "")).ends_with(":pov:4")
	result.checks["translucent_session_rejects_stale_pov_and_retains_previous_root"] = \
		stale_started.get("status") == "begun" and stale_step.get("status") == "failed" \
		and stale_step.get("reason") == "section_translucent_pov_revision_stale" \
		and int(retained_after_stale.get("generation", 0)) == 1 \
		and int(retained_after_stale.get("rootInstanceId", 0)) == first_root
	result.checks["translucent_session_rejects_tampered_actual_mesh_group_centroid"] = \
		tampered_started.get("status") == "failed" \
		and tampered_started.get("reason") == "section_translucent_face_group_centroid_mismatch"
	result.checks["translucent_session_rejects_missing_descriptor_and_retains_previous_root"] = \
		missing_descriptor_started.get("status") == "failed" \
		and missing_descriptor_started.get("reason") == \
			"section_translucent_sort_descriptor_missing_or_mutable" \
		and int(retained_after_missing_descriptor.get("generation", 0)) == 1 \
		and int(retained_after_missing_descriptor.get("rootInstanceId", 0)) == first_root
	result.diagnostics["firstStarted"] = first_started
	result.diagnostics["firstInstall"] = first_step
	result.diagnostics["chunkIdentity"] = {"name":session_chunk.name,
		"position":session_chunk.global_position,
		"backendValid":is_instance_valid(session_backend),
		"backendInsideTree":session_backend.is_inside_tree() if is_instance_valid(session_backend) else false,
		"backendParentMatches":session_backend.get_parent()==session_chunk if is_instance_valid(session_backend) else false,
		"ownerCell":owner_cell,
		"sectionKey":section_key,
		"sectionOwner":StaticRenderSectionGrid.chunk_key_for_section(section_key),
		"streamChunkKeys":StaticRenderSectionGrid.stream_chunk_keys_intersecting_section(section_key)}
	result.diagnostics["sessionOwnerAfterBegin"] = {"backendValid":first_backend_now!=null,
		"chunkValid":first_chunk_now!=null,
		"backendId":first_backend_now.get_instance_id() if first_backend_now!=null else 0,
		"chunkId":first_chunk_now.get_instance_id() if first_chunk_now!=null else 0}
	result.diagnostics["staleStarted"] = stale_started
	result.diagnostics["staleStep"] = stale_step
	result.diagnostics["retainedAfterStale"] = retained_after_stale
	result.diagnostics["tamperedStarted"] = tampered_started
	result.diagnostics["missingDescriptorStarted"] = missing_descriptor_started
	result.diagnostics["retainedAfterMissingDescriptor"] = retained_after_missing_descriptor
	return result


func _translucent_install_candidate(mesh: Mesh, section_key: Vector3i,
		generation: int, pov_revision: int, camera_position: Vector3,
		tamper_centroid: bool, include_descriptor: bool = true) -> Dictionary:
	var mesh_identity: Dictionary = StaticMeshFingerprint.inspect(mesh)
	var mesh_digest := String(mesh_identity.get("contentDigest", ""))
	var groups: Array[Dictionary] = []
	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var rows: Array[Dictionary] = []
	for first_index in range(0, indices.size(), 6):
		var unique_vertices: Dictionary = {}
		for index_offset in range(first_index, first_index + 6):
			unique_vertices[int(indices[index_offset])] = true
		var centroid := Vector3.ZERO
		for vertex_index: Variant in unique_vertices:
			centroid += vertices[int(vertex_index)]
		centroid /= float(unique_vertices.size())
		var row := {"groupId":"face-z:%0.3f" % centroid.z,
			"firstIndex":first_index, "indexCount":6, "centroid":centroid}
		if tamper_centroid and first_index == 0:
			row["centroid"] = centroid + Vector3(0.0, 0.0, 1.0)
		row.make_read_only()
		groups.append(row)
	groups.make_read_only()
	var surface_row := {"surfaceIndex":0, "faceGroups":groups}
	surface_row.make_read_only()
	var surfaces: Array[Dictionary] = [surface_row]
	surfaces.make_read_only()
	var descriptor := {"schema":"section-translucent-face-groups/v1",
		"sectionKey":section_key, "sectionGeneration":generation,
		"povRevision":pov_revision, "cameraPosition":camera_position,
		"meshContentDigest":mesh_digest, "surfaces":surfaces}
	descriptor.make_read_only()
	var buffer: Array[float] = [1.0,0.0,0.0,0.0, 0.0,1.0,0.0,0.0,
		0.0,0.0,1.0,0.0, 1.0,1.0,1.0,1.0, 0.0,0.0,0.0,0.0]
	buffer.make_read_only()
	var segment := {"segmentId":"baked-fluid-section", "buffer":buffer,
		"bounds":AABB(Vector3(-1.0,-1.0,-2.0),Vector3(2.0,2.0,2.0)), "instanceCount":1}
	segment.make_read_only()
	var segments: Array[Dictionary] = [segment]
	segments.make_read_only()
	var batch := {"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"renderLayer":"translucent", "transparencySortPolicy":"camera_depth",
		"intendedVisible":true,
		"materialKey":"probe-material",
		"meshKey":"probe-mesh", "meshContentDigest":mesh_digest,
		"segments":segments}
	if include_descriptor:
		batch["translucentSortDescriptor"] = descriptor
	batch.make_read_only()
	var batches := {"probe-batch":batch}
	batches.make_read_only()
	var dependencies := StaticRenderSectionGrid.stream_chunk_keys_intersecting_section(section_key)
	dependencies.make_read_only()
	var render_layers: Array[Dictionary] = []
	for layer_name: String in ["opaque", "cutout", "translucent"]:
		var layer := {"layer":layer_name,
			"expectedBatchCount":1 if layer_name == "translucent" else 0,
			"expectedInstanceCount":1 if layer_name == "translucent" else 0}
		layer.make_read_only()
		render_layers.append(layer)
	render_layers.make_read_only()
	var manifest: Array = []
	manifest.make_read_only()
	var snapshot := {"schema":"chunk-static-render-section-snapshot/v3",
		"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"sectionKey":section_key,
		"streamChunkKey":StaticRenderSectionGrid.chunk_key_for_section(section_key),
		"streamChunkDependencies":dependencies, "batches":batches,
		"renderLayers":render_layers, "manifest":manifest, "presentationMembers":manifest,
		"instanceCount":1, "segmentCount":1}
	snapshot.make_read_only()
	var world_id := "translucent-install-session-contract"
	var digest := StaticSectionSnapshotBuilder._snapshot_digest(snapshot, world_id,
		generation, section_key)
	var candidate := {"schema":"prepared-static-section-snapshot-envelope/v1",
		"worldId":world_id, "sectionKey":section_key, "generation":generation,
		"contentManifestDigest":digest, "snapshot":snapshot}
	candidate.make_read_only()
	return {"candidate":candidate, "materials":{"probe-material":StandardMaterial3D.new()},
		"meshes":{"probe-mesh":mesh}}


## Synthetic renderer lifecycle contract: real native backend and scene nodes,
## direct packet APIs and direct pivot motion. This is not door gameplay proof.
func _test_attachment_root_set(scene: Node3D) -> void:
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	scene.add_child(chunk)
	var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
	var backend: Node = attached.get("backend")
	if backend == null or not backend.has_method("register_packet_attachment"):
		_check("attachment_native_api_available", false)
		chunk.queue_free()
		return
	var bodies: Array[Node3D] = []
	var pivots: Array[Node3D] = []
	var neutral: Array[Transform3D] = []
	for index in range(2):
		var body := StaticBody3D.new()
		body.name = "AttachmentContractBody%d" % index
		scene.add_child(body)
		body.position = Vector3(3.0 + 4.0 * index, 0.0, 2.0)
		body.set_meta("section_attachment_source_revision", "door-source-%d" % index)
		body.set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
		body.set_meta("section_attachment_publication_epoch", 17)
		var pivot := Node3D.new()
		pivot.name = "DoorPivot"
		body.add_child(pivot)
		pivot.position = Vector3(-0.5, 0.0, 0.0)
		var frame_visual := MeshInstance3D.new()
		frame_visual.mesh = BoxMesh.new()
		body.add_child(frame_visual)
		var leaf_visual := MeshInstance3D.new()
		leaf_visual.mesh = BoxMesh.new()
		pivot.add_child(leaf_visual)
		bodies.append(body)
		pivots.append(pivot)
		neutral.append(pivot.global_transform)
	var source := "native-contract:attachment-root-set"
	var first := _prepare_attachment_packet(backend, source, 1, bodies, pivots, neutral)
	_check("attachment_three_batches_stage_hidden", first.get("status") == "ready_to_commit" \
		and _attachment_children(pivots).size() == 2 \
		and _attachment_children(pivots).all(func(node: Node3D) -> bool: return not node.visible))
	var pending: Dictionary = backend.call("commit_packet", source, 1, true)
	var roots: Array = pending.get("attachmentRoots", [])
	var legacy := _attachment_legacy_visuals(bodies, pivots)
	_check("attachment_first_commit_has_zero_legacy_native_overlap", pending.get("status") == "pending_presentation" \
		and legacy.size() == 4 and legacy.all(func(node: GeometryInstance3D) -> bool: return not node.visible) \
		and _attachment_children(pivots).all(func(node: Node3D) -> bool: return node.visible))
	var legacy_pending: Dictionary = backend.call("legacy_visual_state", legacy[0].get_instance_id())
	_check("attachment_legacy_claim_is_pending_until_ack", legacy_pending.get("status") == "pending_presentation")
	var exact_roots := roots.size() == 2
	for row: Dictionary in roots:
		var index := 0 if String(row.get("attachmentKey")) == "swing" else 1
		exact_roots = exact_roots and int(row.get("parentInstanceId", 0)) == pivots[index].get_instance_id() \
			and int(row.get("bodyInstanceId", 0)) == bodies[index].get_instance_id() \
			and String(row.get("sourceRevision", "")) == "door-source-%d" % index \
			and int(row.get("publisherInstanceId", 0)) == scene.get_instance_id() \
			and int(row.get("publicationEpoch", -1)) == 17 \
			and row.get("neutralParentToWorld") == neutral[index]
	_check("attachment_pending_receipt_binds_exact_source_and_root_set", \
		pending.get("status") == "pending_presentation" and exact_roots)
	# This direct acknowledgement checks the backend protocol, not frame rendering.
	var accepted: Dictionary = backend.call("finalize_presentation", source, 1, String(pending.get("token", "")))
	_check("attachment_root_set_accepts_matching_presentation_token", accepted.get("status") == "ready")
	var legacy_installed: Dictionary = backend.call("legacy_visual_state", legacy[0].get_instance_id())
	_check("attachment_legacy_claim_is_installed_after_ack", legacy_installed.get("status") == "installed")
	var installed_first: Dictionary = backend.call("installed_snapshot", source)
	var per_batch_visibility := true
	var visible_batches := 0
	var hidden_batches := 0
	for batch_receipt_value: Variant in installed_first.get("batches", []):
		if not batch_receipt_value is Dictionary:
			per_batch_visibility = false
			continue
		var batch_receipt: Dictionary = batch_receipt_value
		if String(batch_receipt.get("attachmentKey", "")) != "swing": continue
		var batch_node := instance_from_id(int(batch_receipt.get("instanceId", 0))) as MultiMeshInstance3D
		var should_be_visible := String(batch_receipt.get("batchId", "")) == "attachment-batch-1"
		per_batch_visibility = per_batch_visibility \
			and bool(batch_receipt.get("intendedVisible", !should_be_visible)) == should_be_visible \
			and batch_node != null and batch_node.is_visible() == should_be_visible
		if should_be_visible: visible_batches += 1
		else: hidden_batches += 1
	_check("attachment_shared_anchor_preserves_each_batch_visibility",
		installed_first.get("status") == "ready" and per_batch_visibility \
		and visible_batches == 1 and hidden_batches == 1)
	pivots[0].rotation.y = 0.7
	pivots[1].position.y = 2.0
	var same_frame := true
	for row: Dictionary in roots:
		var index := 0 if String(row.get("attachmentKey")) == "swing" else 1
		var installed_root := instance_from_id(int(row.get("rootInstanceId", 0))) as Node3D
		same_frame = same_frame and installed_root != null \
			and installed_root.global_transform.is_equal_approx(pivots[index].global_transform * neutral[index].affine_inverse())
	var moved: Dictionary = backend.call("installed_snapshot", source)
	_check("attachment_swing_and_raise_follow_parent_same_call_without_recompile", same_frame and moved.get("status") == "ready")
	pivots[0].rotation = Vector3.ZERO
	pivots[1].position.y = 0.0
	pivots[0].rotation.y = 2.0
	var swing_outside: Dictionary = backend.call("legacy_visual_state", legacy[0].get_instance_id())
	_check("attachment_out_of_range_swing_invalidates_whole_packet", swing_outside.get("status") == "stale")
	pivots[0].rotation = Vector3.ZERO
	pivots[1].position.y = 4.0
	var raise_outside: Dictionary = backend.call("installed_snapshot", source)
	_check("attachment_out_of_range_raise_invalidates_whole_packet", raise_outside.get("status") == "stale")
	pivots[1].position.y = 0.0
	var second := _prepare_attachment_packet(backend, source, 2, bodies, pivots, neutral, 1)
	var partial: Dictionary = backend.call("commit_packet", source, 2, true)
	var old_root := instance_from_id(int(accepted.get("rootInstanceId", 0))) as Node3D
	_check("attachment_partial_upload_preserves_previous_visible_packet", second.get("status") == "pending" \
		and partial.get("status") == "pending" and old_root != null and old_root.visible)
	backend.call("advance_packet", source, 2, 3)
	var replacement: Dictionary = backend.call("commit_packet", source, 2, true)
	var rolled_back: Dictionary = backend.call("rollback_presentation", source, 2, String(replacement.get("token", "")))
	var restored: Dictionary = backend.call("installed_snapshot", source)
	_check("attachment_rollback_restores_entire_previous_root_set", rolled_back.get("status") == "rolled_back" \
		and restored.get("attachmentRoots", []) == roots and old_root != null and old_root.visible)
	await process_frame
	await process_frame
	_prepare_attachment_packet(backend, source, 3, bodies, pivots, neutral)
	var stale_pending: Dictionary = backend.call("commit_packet", source, 3, true)
	bodies[0].set_meta("section_attachment_publication_epoch", 18)
	var stale_ack: Dictionary = backend.call("finalize_presentation", source, 3, String(stale_pending.get("token", "")))
	_check("attachment_ack_rejects_changed_source_boundary", stale_ack.get("status") == "failed")
	var stale_rollback: Dictionary = backend.call("rollback_presentation", source, 3, String(stale_pending.get("token", "")))
	_check("attachment_stale_source_can_restore_retained_previous_geometry", stale_rollback.get("status") == "rolled_back")
	bodies[0].set_meta("section_attachment_publication_epoch", 17)
	await process_frame
	await process_frame
	_prepare_attachment_packet(backend, source, 4, bodies, pivots, neutral)
	bodies[0].set_meta("section_attachment_source_revision", "replacement-source-revision")
	var changed_revision: Dictionary = backend.call("commit_packet", source, 4, true)
	_check("attachment_commit_rejects_changed_source_revision", changed_revision.get("status") == "failed")
	bodies[0].set_meta("section_attachment_source_revision", "door-source-0")
	bodies[0].set_meta("section_attachment_publisher_instance_id", scene.get_instance_id() + 1)
	var changed_publisher: Dictionary = backend.call("commit_packet", source, 4, true)
	_check("attachment_commit_rejects_changed_publisher_incarnation", changed_publisher.get("status") == "failed")
	bodies[0].set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
	var original_body_transform := bodies[0].transform
	bodies[0].position.x += 0.25
	var changed_body: Dictionary = backend.call("commit_packet", source, 4, true)
	_check("attachment_commit_rejects_changed_neutral_body_placement", changed_body.get("status") == "failed")
	bodies[0].transform = original_body_transform
	backend.call("abort_packet", source, 4)
	await process_frame
	await process_frame
	var before_release: Dictionary = backend.call("installed_snapshot", source)
	var payload := int(before_release.get("payloadBytes", 0))
	backend.call("release_packet", source, 1)
	_check("attachment_release_restores_exact_legacy_before_free", legacy.all(func(node: GeometryInstance3D) -> bool: return node.visible))
	var retiring: Dictionary = backend.call("metrics")
	_check("attachment_release_accounts_all_three_retiring_roots", int(retiring.get("retiringRoots", -1)) == 3 \
		and int(retiring.get("retiringPayloadBytes", -1)) == payload and payload > 0)
	if not roots.is_empty():
		var freed_root_id := int(roots[0].get("rootInstanceId", 0))
		for root_row: Dictionary in roots:
			if int(root_row.get("payloadBytes", 0)) > 0:
				freed_root_id = int(root_row.get("rootInstanceId", 0))
				break
		var root_payload := 0
		for batch: Dictionary in before_release.get("batches", []):
			if int(batch.get("parentRootId", 0)) == freed_root_id:
				root_payload += int(batch.get("payloadBytes", 0))
		var retiring_root := instance_from_id(freed_root_id) as Node3D
		if retiring_root != null: retiring_root.free()
		var after_one_root: Dictionary = backend.call("metrics")
		_check("attachment_retirement_releases_only_actual_root_payload", root_payload > 0 \
			and int(after_one_root.get("retiringRoots", -1)) == 2 \
			and int(after_one_root.get("retiringPayloadBytes", -1)) == payload - root_payload)
	await process_frame
	await process_frame
	var drained: Dictionary = backend.call("metrics")
	_check("attachment_release_drains_all_payload_and_roots", int(drained.get("retiringRoots", -1)) == 0 \
		and int(drained.get("retiringPayloadBytes", -1)) == 0)
	# Missing retained old root must hide the entire unaccepted replacement and
	# restore legacy, rather than fail rollback with the replacement still visible.
	_prepare_attachment_packet(backend, source, 5, bodies, pivots, neutral)
	var rollback_base: Dictionary = backend.call("commit_packet", source, 5, false)
	_check("attachment_reclaim_clears_restoration_receipts", rollback_base.get("status") == "ready" \
		and legacy.all(func(visual: GeometryInstance3D) -> bool:
			return not visual.has_meta("section_attachment_legacy_restoration_receipt")))
	_prepare_attachment_packet(backend, source, 6, bodies, pivots, neutral)
	var missing_previous_pending: Dictionary = backend.call("commit_packet", source, 6, true)
	var previous_anchor := instance_from_id(int(rollback_base.get("rootInstanceId", 0))) as Node3D
	if previous_anchor != null: previous_anchor.free()
	var missing_previous_rollback: Dictionary = backend.call("rollback_presentation", source, 6,
		String(missing_previous_pending.get("token", "")))
	_check("attachment_missing_previous_rollback_hides_replacement_and_restores_legacy", \
		bool(missing_previous_rollback.get("replacementHidden", false)) \
		and legacy.all(func(node: GeometryInstance3D) -> bool: return node.visible) \
		and _attachment_children(pivots).all(func(node: Node3D) -> bool: return not node.visible))
	var rollback_retry: Dictionary = backend.call("rollback_presentation", source, 6,
		String(missing_previous_pending.get("token", "")))
	_check("attachment_missing_previous_is_partial_failure_with_retained_owner", \
		missing_previous_rollback.get("status") == "rollback_failed" \
		and missing_previous_rollback.get("reason") == "previous_representation_incomplete" \
		and bool(missing_previous_rollback.get("partialLegacyRestoration", false)) \
		and bool(missing_previous_rollback.get("ownerRetained", false)) \
		and rollback_retry.get("status") == "rollback_failed" \
		and rollback_retry.get("token") == missing_previous_pending.get("token"))
	# Explicit provider cleanup ends the retained failed transaction; it is not
	# counted as successful restoration of the missing terrain/static root.
	var partial_cleanup: Dictionary = backend.call("restore_legacy_for_visual", legacy[0].get_instance_id())
	_check("attachment_partial_rollback_requires_explicit_cleanup", partial_cleanup.get("status") == "restored")
	var partial_settled: Dictionary = backend.call("settle_presentation_cancellation", source, 6,
		String(missing_previous_pending.get("token", "")))
	_check("attachment_partial_cleanup_requires_exact_token_acknowledgement", partial_settled.get("status") == "cancelled" \
		and bool(partial_settled.get("ownershipReleased", false)) and bool(partial_settled.get("candidateQuiesced", false)))
	await process_frame
	await process_frame
	# Provider-directed fallback is a full packet withdrawal, not a boolean flag.
	_prepare_attachment_packet(backend, source, 7, bodies, pivots, neutral)
	backend.call("commit_packet", source, 7, false)
	var restored_legacy: Dictionary = backend.call("restore_legacy_for_visual", legacy[0].get_instance_id())
	var after_fallback: Dictionary = backend.call("legacy_visual_state", legacy[0].get_instance_id())
	_check("attachment_provider_fallback_withdraws_whole_packet", restored_legacy.get("status") == "restored" \
		and after_fallback.get("status") == "unowned" \
		and legacy.all(func(node: GeometryInstance3D) -> bool: return node.visible) \
		and _attachment_children(pivots).all(func(node: Node3D) -> bool: return not node.visible))
	await process_frame
	await process_frame
	_prepare_attachment_packet(backend, source, 8, bodies, pivots, neutral)
	backend.call("commit_packet", source, 8, false)
	_prepare_attachment_packet(backend, source, 9, bodies, pivots, neutral, 1)
	var external_ids: Array[int] = []
	for external: Node3D in _attachment_children(pivots): external_ids.append(external.get_instance_id())
	backend.queue_free()
	await process_frame
	await process_frame
	var external_drained := external_ids.size() == 4
	for id: int in external_ids: external_drained = external_drained and not is_instance_id_valid(id)
	_check("attachment_backend_exit_releases_installed_and_staged_external_roots", external_drained \
		and bodies.all(func(body: Node3D) -> bool: return is_instance_valid(body) and body.is_inside_tree()) \
		and legacy.all(func(node: GeometryInstance3D) -> bool: return node.visible))
	diagnostics["attachmentRootSet"] = {"evidence":"synthetic renderer contract; direct native API and pivot changes; no gameplay or rendered frame proof",
		"firstPending":pending, "firstAccepted":accepted, "moved":moved,
		"replacement":replacement, "staleAck":stale_ack, "missingPreviousRollback":missing_previous_rollback,
		"changedRevision":changed_revision, "changedPublisher":changed_publisher, "changedBody":changed_body,
		"beforeRelease":before_release, "retiring":retiring, "drained":drained,
		"externalRootIdsAtBackendExit":external_ids}
	for body: Node3D in bodies: body.queue_free()
	chunk.queue_free()
	await process_frame
	await _test_attachment_owner_loss(scene, false)
	await _test_attachment_owner_loss(scene, true)
	await _test_attachment_awaiting_owner_replacement(scene)
	await _test_attachment_suppression_transfer(scene)
	await _test_attachment_provider_first_cancellation(scene)
	await _test_attachment_claim_capacity(scene)
	await _test_attachment_previous_unavailable_matrix(scene)
	await _test_attachment_refcounted_publisher(scene)


func _test_visible_borrowed_source_mount(scene: Node3D) -> void:
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	scene.add_child(chunk)
	var backend: Node = PacketOwner.attach_to_chunk(chunk).get("backend") as Node
	var body := StaticBody3D.new()
	body.set_meta("section_attachment_source_revision", "visible-source-revision")
	body.set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
	body.set_meta("section_attachment_publication_epoch", 1)
	scene.add_child(body)
	var mount := Node3D.new()
	mount.set_meta("section_attachment_presentation_member_id", "visible-source-light")
	body.add_child(mount)
	var light := OmniLight3D.new()
	mount.add_child(light)
	var source := "native-contract:visible-borrowed-source"
	var first := _prepare_borrowed_packet(backend, source, 1, body, body, mount, "visible-source-light")
	var first_pending: Dictionary = backend.call("commit_packet", source, 1, true)
	var first_rollback: Dictionary = backend.call("rollback_presentation", source, 1,
		String(first_pending.get("token", "")))
	_check("borrowed_visible_source_survives_stage_and_first_rollback",
		first.get("status") == "ready_to_commit" and first_pending.get("status") == "pending_presentation" \
		and first_rollback.get("status") == "rolled_back" and mount.visible and light.is_visible_in_tree())
	var second := _prepare_borrowed_packet(backend, source, 2, body, body, mount, "visible-source-light")
	var second_pending: Dictionary = backend.call("commit_packet", source, 2, true)
	var second_ack: Dictionary = backend.call("finalize_presentation", source, 2,
		String(second_pending.get("token", "")))
	var released: Dictionary = backend.call("release_packet", source, 2)
	_check("borrowed_visible_source_survives_install_and_release",
		second.get("status") == "ready_to_commit" and second_pending.get("status") == "pending_presentation" \
		and second_ack.get("status") == "ready" and released.get("status") == "released" \
		and mount.visible and light.is_visible_in_tree())
	var third := _prepare_borrowed_packet(backend, source, 3, body, body, mount, "visible-source-light")
	var third_pending: Dictionary = backend.call("commit_packet", source, 3, true)
	var third_ack: Dictionary = backend.call("finalize_presentation", source, 3,
		String(third_pending.get("token", "")))
	scene.remove_child(body)
	var detached_local_visibility := mount.visible and light.visible
	scene.add_child(body)
	_check("borrowed_visible_source_detach_restores_local_visibility_for_reentry",
		third.get("status") == "ready_to_commit" and third_pending.get("status") == "pending_presentation" \
		and third_ack.get("status") == "ready" and detached_local_visibility \
		and mount.visible and light.is_visible_in_tree())
	body.queue_free()
	chunk.queue_free()
	await process_frame
	await process_frame


 ## Synthetic transaction contract: real native backend and source-owned mount
## with a real OmniLight3D child. It proves root ownership/ACK semantics only,
## not a rendered-light gameplay or screenshot result.
func _test_borrowed_presentation_cutover(scene: Node3D) -> void:
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	scene.add_child(chunk)
	var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
	var backend: Node = attached.get("backend") as Node
	if backend == null or not backend.has_method("register_borrowed_presentation"):
		_check("borrowed_presentation_native_api_available", false)
		chunk.queue_free()
		return
	var body := StaticBody3D.new()
	body.name = "BorrowedTorchBody"
	body.set_meta("section_attachment_source_revision", "torch-revision-1")
	body.set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
	body.set_meta("section_attachment_publication_epoch", 31)
	scene.add_child(body)
	var pivot := Node3D.new()
	pivot.name = "TorchPivot"
	body.add_child(pivot)
	pivot.position = Vector3(0.25, 0.5, 0.0)
	var mount := Node3D.new()
	mount.name = "SectionPresentationMount"
	mount.set_meta("section_attachment_presentation_member_id", "torch-light:owner-0")
	mount.visible = false
	pivot.add_child(mount)
	var light := OmniLight3D.new()
	light.name = "LiveTorchLight"
	light.light_energy = 0.7
	mount.add_child(light)
	var mount_id := mount.get_instance_id()
	var original_parent_id := pivot.get_instance_id()
	var original_transform := mount.transform
	var original_meta := mount.get_meta_list()
	var source := "native-contract:borrowed-torch"
	var first := _prepare_borrowed_packet(backend, source, 1, body, pivot, mount, "torch-light:owner-0")
	var stage_unchanged := mount.get_instance_id() == mount_id and mount.get_parent() == pivot \
		and mount.transform == original_transform and not mount.visible \
		and mount.get_meta_list() == original_meta and light.get_parent() == mount
	var first_pending: Dictionary = backend.call("commit_packet", source, 1, true)
	var first_rows: Array = first_pending.get("attachmentRoots", [])
	var first_row: Dictionary = first_rows[0] if first_rows.size() == 1 else {}
	_check("borrowed_mount_is_manifest_member_without_fake_geometry", first.get("status") == "ready_to_commit" \
		and stage_unchanged and first_pending.get("status") == "pending_presentation" \
		and first_pending.get("attachmentManifestDigest", "") == first.get("testManifestDigest", "") \
		and first_pending.get("packetDigest", "") == first.get("testPacketDigest", "") \
		and first_pending.get("batchCount", -1) == 0 and first_pending.get("instanceCount", -1) == 0 \
		and first_pending.get("attachmentManifestCount", -1) == 1 \
		and first_row.get("ownershipKind", "") == "borrowed_presentation" \
		and first_row.get("memberSourceId", "") == "torch-source:fireplace-0" \
		and first_row.get("sourcePartId", "") == "torch-part:owner-0" \
		and first_row.get("presentationMemberId", "") == "torch-light:owner-0" \
		and first_row.get("rootInstanceId", 0) == mount_id and first_row.get("parentInstanceId", 0) == original_parent_id \
		and first_row.get("payloadBytes", -1) == 0 and mount.visible and light.is_visible_in_tree())
	var first_ack: Dictionary = backend.call("finalize_presentation", source, 1, String(first_pending.get("token", "")))
	var installed_first: Dictionary = backend.call("installed_snapshot", source)
	var child_local_visibility_survives: bool = installed_first.get("status") == "ready"
	light.visible = false
	child_local_visibility_survives = child_local_visibility_survives and mount.visible \
		and not light.is_visible_in_tree() and backend.call("installed_snapshot", source).get("status") == "ready"
	light.visible = true
	_check("borrowed_mount_installs_after_exact_frame_ack_and_preserves_light_script_visibility", \
		first_ack.get("status") == "ready" and installed_first.get("status") == "ready" \
		and child_local_visibility_survives and mount.visible and light.is_visible_in_tree())

	var shared_mount_visibility_changes: Array[int] = [0]
	var shared_mount_visibility_witness := func() -> void: shared_mount_visibility_changes[0] += 1
	mount.visibility_changed.connect(shared_mount_visibility_witness)
	var second := _prepare_borrowed_packet(backend, source, 2, body, pivot, mount,
		"torch-light:owner-0", "", true)
	var after_register: Dictionary = backend.call("installed_snapshot", source)
	var second_pending: Dictionary = backend.call("commit_packet", source, 2, true)
	var second_rows: Array = second_pending.get("attachmentRoots", [])
	var second_previous: Dictionary = second_pending.get("previousReceipt", {})
	var second_previous_rows: Array = second_previous.get("attachmentRoots", [])
	var same_mount_transfer: bool = second_rows.size() == 1 and second_previous_rows.size() == 1 \
		and second_pending.get("batchCount", -1) == 1 and second_pending.get("instanceCount", -1) == 1 \
		and not bool(second_pending.get("previousUnavailable", true)) \
		and second_previous.get("expectedBatchCount", -1) == 0 \
		and second_rows[0].get("rootInstanceId", 0) == mount_id \
		and second_rows[0].get("activeClaim", false) \
		and second_previous_rows[0].get("rootInstanceId", 0) == mount_id \
		and not second_previous_rows[0].get("activeClaim", true) \
		and second_previous_rows[0].get("rootVisible", false) \
		and mount.visible and after_register.get("status") == "ready"
	var second_ack: Dictionary = backend.call("finalize_presentation", source, 2, String(second_pending.get("token", "")))
	var second_installed: Dictionary = backend.call("installed_snapshot", source)
	_check("borrowed_same_mount_transfer_keeps_previous_receipt_and_candidate_visible", second.get("status") == "ready_to_commit" \
		and second_pending.get("status") == "pending_presentation" and same_mount_transfer \
		and second_ack.get("status") == "ready" and mount.visible and is_instance_id_valid(mount_id) \
		and shared_mount_visibility_changes[0] == 0)
	mount.visibility_changed.disconnect(shared_mount_visibility_witness)
	_check("borrowed_mount_and_geometry_share_one_atomic_section_candidate", \
		second_pending.get("status") == "pending_presentation" and second_ack.get("status") == "ready" \
		and second_installed.get("expectedBatchCount", -1) == 1 and second_installed.get("instanceCount", -1) == 1 \
		and second_installed.get("attachmentManifestCount", -1) == 1 \
		and mount.visible and is_instance_id_valid(mount_id))

	var third := _prepare_borrowed_packet(backend, source, 3, body, pivot, mount, "torch-light:owner-0")
	var third_pending: Dictionary = backend.call("commit_packet", source, 3, true)
	var third_rollback: Dictionary = backend.call("rollback_presentation", source, 3, String(third_pending.get("token", "")))
	var after_rollback: Dictionary = backend.call("installed_snapshot", source)
	_check("borrowed_candidate_rollback_restores_exact_previous_mount_without_free", \
		third.get("status") == "ready_to_commit" and third_pending.get("status") == "pending_presentation" \
		and not bool(third_pending.get("previousUnavailable", true)) \
		and third_pending.get("previousReceipt", {}).get("status", "") == "retained_previous" \
		and third_rollback.get("status") == "rolled_back" and after_rollback.get("generation") == 2 \
		and after_rollback.get("status") == "ready" and mount.visible and is_instance_id_valid(mount_id))
	body.set_meta("section_attachment_source_revision", "torch-revision-replaced")
	var changed_revision := _prepare_borrowed_packet(backend, source, 4, body, pivot, mount,
		"torch-light:owner-0")
	body.set_meta("section_attachment_source_revision", "torch-revision-1")
	var unchanged_after_revision_change: Dictionary = backend.call("installed_snapshot", source)
	_check("borrowed_mount_reuse_rejects_changed_source_revision", \
		changed_revision.get("status") == "failed" \
		and changed_revision.get("reason", "") == "borrowed_mount_transfer_identity_mismatch" \
		and unchanged_after_revision_change.get("status", "") == "ready" \
		and int(unchanged_after_revision_change.get("generation", -1)) == 2 and mount.visible)

	var other_mount := Node3D.new()
	other_mount.name = "ReplacementSectionPresentationMount"
	other_mount.set_meta("section_attachment_presentation_member_id", "torch-light:owner-0")
	other_mount.visible = false
	pivot.add_child(other_mount)
	var other_light := OmniLight3D.new()
	other_light.name = "ReplacementLiveTorchLight"
	other_mount.add_child(other_light)
	var other_mount_id := other_mount.get_instance_id()
	var fourth := _prepare_borrowed_packet(backend, source, 4, body, pivot, other_mount, "torch-light:owner-0")
	var fourth_pending: Dictionary = backend.call("commit_packet", source, 4, true)
	var old_hidden_new_visible := not mount.visible and other_mount.visible \
		and is_instance_id_valid(mount_id) and is_instance_id_valid(other_mount_id)
	var fourth_rollback: Dictionary = backend.call("rollback_presentation", source, 4, String(fourth_pending.get("token", "")))
	_check("borrowed_different_mount_rollback_hides_only_candidate_and_retains_old", \
		fourth.get("status") == "ready_to_commit" and fourth_pending.get("status") == "pending_presentation" \
		and old_hidden_new_visible and fourth_rollback.get("status") == "rolled_back" \
		and mount.visible and not other_mount.visible and is_instance_id_valid(other_mount_id))

	var fifth := _prepare_borrowed_packet(backend, source, 5, body, pivot, other_mount, "torch-light:owner-0")
	var fifth_pending: Dictionary = backend.call("commit_packet", source, 5, true)
	var fifth_ack: Dictionary = backend.call("finalize_presentation", source, 5, String(fifth_pending.get("token", "")))
	var replacement_installed: Dictionary = backend.call("installed_snapshot", source)
	var released: Dictionary = backend.call("release_packet", source, 5)
	await process_frame
	await process_frame
	await _test_borrowed_presentation_tail(scene, backend, source, body, pivot,
		mount, mount_id, other_mount, other_mount_id, other_light, fifth,
		fifth_pending, fifth_ack, replacement_installed, released, chunk)


func _test_manifest_admission_seals_owned_motion(scene: Node3D) -> void:
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	scene.add_child(chunk)
	var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
	var backend: Node = attached.get("backend") as Node
	if not is_instance_valid(backend):
		_check("attachment_manifest_admission_owns_nested_motion", false)
		return
	var body := StaticBody3D.new()
	body.set_meta("section_attachment_source_revision", "seal-revision-1")
	body.set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
	body.set_meta("section_attachment_publication_epoch", 91)
	scene.add_child(body)
	var pivot := Node3D.new()
	body.add_child(pivot)
	var mount := Node3D.new()
	var member_id := "seal-light:owner-0"
	mount.set_meta("section_attachment_presentation_member_id", member_id)
	mount.visible = false
	pivot.add_child(mount)
	var light := OmniLight3D.new()
	mount.add_child(light)
	var prepared := _prepare_borrowed_packet(backend,
		"native-contract:manifest-seal", 1, body, pivot, mount, member_id,
		"mutate_motion_after_declaration")
	var pending: Dictionary = backend.call("commit_packet",
		"native-contract:manifest-seal", 1, true)
	var rows: Array = pending.get("attachmentRoots", [])
	var row: Dictionary = rows[0] if rows.size() == 1 else {}
	var ack: Dictionary = backend.call("finalize_presentation",
		"native-contract:manifest-seal", 1, String(pending.get("token", "")))
	_check("attachment_manifest_admission_owns_nested_motion",
		prepared.get("status") == "ready_to_commit" \
		and bool(prepared.get("testCallerMotionMutated", false)) \
		and pending.get("status") == "pending_presentation" \
		and pending.get("attachmentManifestDigest", "") == prepared.get("testManifestDigest", "") \
		and row.get("swing", INF) == 0.35 and row.get("motionKind", "") == "swing" \
		and ack.get("status") == "ready" and mount.visible and light.is_visible_in_tree())
	var released: Dictionary = backend.call("release_packet",
		"native-contract:manifest-seal", 1)
	var extra_field := _prepare_borrowed_packet(backend,
		"native-contract:manifest-seal-negative", 2, body, pivot, mount,
		member_id, "extra_manifest_field")
	backend.call("abort_packet", "native-contract:manifest-seal-negative", 2)
	var wrong_type := _prepare_borrowed_packet(backend,
		"native-contract:manifest-seal-negative", 3, body, pivot, mount,
		member_id, "identity_variant_type")
	backend.call("abort_packet", "native-contract:manifest-seal-negative", 3)
	var zero_bounds := _prepare_borrowed_packet(backend,
		"native-contract:manifest-seal-negative", 4, body, pivot, mount,
		member_id, "zero_swept_bounds")
	backend.call("abort_packet", "native-contract:manifest-seal-negative", 4)
	_check("attachment_manifest_exact_shape_and_variant_types_fail_closed",
		extra_field.get("reason", "") == "attachment_manifest_member_fields_invalid" \
		and wrong_type.get("reason", "") == "attachment_manifest_member_types_invalid" \
		and zero_bounds.get("reason", "") == "attachment_manifest_spatial_contract_invalid" \
		and released.get("status") == "released")
	body.queue_free()
	chunk.queue_free()
	await process_frame
	await process_frame


func _test_borrowed_section_install_session(scene: Node3D) -> void:
	var owner_result: Dictionary = scene.call("get_static_section_render_owner", Vector2i.ZERO, true)
	var chunk := owner_result.get("owner") as Node3D
	var backend := owner_result.get("backend") as Node
	if not is_instance_valid(chunk) or not is_instance_valid(backend):
		_check("presentation_session_installs_borrowed_only_candidate_through_frame_ack", false)
		return
	var body := StaticBody3D.new()
	body.set_meta("section_attachment_source_revision", "session-source-revision-1")
	body.set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
	body.set_meta("section_attachment_publication_epoch", 104)
	scene.add_child(body)
	var pivot := Node3D.new()
	body.add_child(pivot)
	var legacy := MeshInstance3D.new()
	legacy.mesh = BoxMesh.new()
	body.add_child(legacy)
	var first_mount := _make_session_presentation_mount(pivot, "session-member-1")
	var world_id := "native-presentation-session-contract"
	var first_inputs := _session_presentation_candidate(world_id, 1, body, pivot,
		first_mount, legacy, "session-attachment-1", "session-member-1")
	var first_session := StaticSectionInstallSession.new()
	var first_begin: Dictionary = first_session.begin(backend, chunk,
		first_inputs.candidate, {}, {}, scene.world_static_section_coordinator,
		first_inputs.bindings)
	var first_result: Dictionary = {}
	if first_begin.get("status") == "begun":
		first_result = await _advance_presented_session(first_session, 1)
	var slot := StaticSectionInstallSession.slot_id(world_id, Vector3i.ZERO)
	var first_installed: Dictionary = backend.call("installed_snapshot", slot)
	diagnostics["borrowedSession"] = {"inputs":first_inputs.get("status"),
		"begin":first_begin, "advance":first_result, "installed":first_installed}
	var first_attachment_rows: Array = first_installed.get("attachmentRoots", [])
	var first_attachment: Dictionary = first_attachment_rows[0] if first_attachment_rows.size() == 1 else {}
	_check("presentation_session_installs_borrowed_only_candidate_through_frame_ack",
		first_begin.get("status") == "begun" and first_result.get("status") == "installed" \
		and int(first_installed.get("instanceCount", -1)) == 0 \
		and first_installed.get("batches", [null]).is_empty() \
		and int(first_installed.get("attachmentManifestCount", -1)) == 1 \
		and first_attachment.get("ownershipKind", "") == "borrowed_presentation" \
		and int(first_attachment.get("rootInstanceId", 0)) == first_mount.get_instance_id() \
		and first_mount.visible and not legacy.visible)
	_check("presentation_receipt_preserves_distinct_census_and_producer_revisions",
		first_attachment.get("sourceRevision") == first_inputs.member.sourceRevision \
		and first_attachment.get("producerSourceRevision") == first_inputs.member.producerSourceRevision \
		and first_attachment.get("sourceRevision") != first_attachment.get("producerSourceRevision") \
		and body.get_meta("section_attachment_source_revision") == first_inputs.member.producerSourceRevision)

	var second_mount := _make_session_presentation_mount(pivot, "session-member-2")
	var second_inputs := _session_presentation_candidate(world_id, 2, body, pivot,
		second_mount, legacy, "session-attachment-2", "session-member-2")
	var missing_binding := StaticSectionInstallSession.new()
	# An unchanged producer cannot authorize a binding from an older census.
	var stale_census_binding: Dictionary = second_inputs.bindings["session-attachment-2"].duplicate(false)
	stale_census_binding["sourceRevision"] = first_inputs.member.sourceRevision
	stale_census_binding.make_read_only()
	var stale_census_session := StaticSectionInstallSession.new()
	var stale_census_begin := stale_census_session.begin(backend, chunk,
		second_inputs.candidate, {}, {}, scene.world_static_section_coordinator,
		{"session-attachment-2":stale_census_binding})
	_check("presentation_rejects_stale_census_binding_with_unchanged_producer",
		stale_census_begin.get("status") == "failed" \
		and stale_census_begin.get("reason") == "borrowed_presentation_binding_identity_mismatch" \
		and backend.call("installed_snapshot", slot).get("generation", -1) == 1 \
		and first_mount.visible)
	var missing_begin: Dictionary = missing_binding.begin(backend, chunk,
		second_inputs.candidate, {}, {}, scene.world_static_section_coordinator, {})
	var unchanged_after_missing_binding: Dictionary = backend.call("installed_snapshot", slot)
	var tampered_candidate := _tamper_presentation_candidate_visibility(second_inputs.candidate)
	var tampered_session := StaticSectionInstallSession.new()
	var tampered_begin: Dictionary = tampered_session.begin(backend, chunk,
		tampered_candidate, {}, {}, scene.world_static_section_coordinator,
		second_inputs.bindings)
	_check("presentation_session_rejects_missing_binding_and_member_visibility_digest_change",
		missing_begin.get("status") == "failed" \
		and missing_begin.get("reason", "") == "borrowed_presentation_binding_missing" \
		and unchanged_after_missing_binding.get("generation", -1) == 1 \
		and tampered_begin.get("status") == "failed" \
		and tampered_begin.get("reason", "") == "section_candidate_manifest_digest_mismatch" \
		and backend.call("installed_snapshot", slot).get("generation", -1) == 1)

	# Reuse the exact mount identity for a same-mount rollback through the real
	# install session, including frame-pending cancellation semantics.
	var same_mount_inputs := _session_presentation_candidate(world_id, 2, body, pivot,
		first_mount, legacy, "session-attachment-1", "session-member-1")
	var second_session := StaticSectionInstallSession.new()
	var second_begin: Dictionary = second_session.begin(backend, chunk,
		same_mount_inputs.candidate, {}, {}, scene.world_static_section_coordinator,
		same_mount_inputs.bindings)
	var pending: Dictionary = {}
	for _attempt in range(6):
		pending = second_session.advance(1)
		if pending.get("status") in ["pending_presentation", "failed", "rollback_failed"]:
			break
	var shared_mount_visible_before_rollback := first_mount.visible
	var rollback := second_session.rollback_presentation(
		String(pending.get("presentationToken", ""))) \
		if pending.get("status") == "pending_presentation" else {"status":"not_pending"}
	var restored: Dictionary = backend.call("installed_snapshot", slot)
	_check("presentation_session_cancellation_restores_previous_native_and_borrowed_mount",
		second_begin.get("status") == "begun" and pending.get("status") == "pending_presentation" \
		and shared_mount_visible_before_rollback \
		and rollback.get("status") == "cancelled" and restored.get("status") == "ready" \
		and int(restored.get("generation", 0)) == 1 and first_mount.visible \
		and not second_mount.visible and not legacy.visible)

	var stale_mount := _make_session_presentation_mount(pivot, "session-member-stale")
	var stale_inputs := _session_presentation_candidate(world_id, 3, body, pivot,
		stale_mount, legacy, "session-attachment-stale", "session-member-stale")
	var stale_session := StaticSectionInstallSession.new()
	var stale_begin: Dictionary = stale_session.begin(backend, chunk,
		stale_inputs.candidate, {}, {}, scene.world_static_section_coordinator,
		stale_inputs.bindings)
	body.set_meta("section_attachment_source_revision", "mutated-after-session-admission")
	var stale_advance: Dictionary = stale_session.advance(1)
	body.set_meta("section_attachment_source_revision", "session-source-revision-1")
	var retained_after_stale: Dictionary = backend.call("installed_snapshot", slot)
	_check("presentation_session_rejects_stale_owner_before_candidate_promotion",
		stale_begin.get("status") == "begun" and stale_advance.get("status") == "failed" \
		and stale_advance.get("reason", "") == "section_attachment_binding_stale" \
		and retained_after_stale.get("status") == "ready" \
		and int(retained_after_stale.get("generation", 0)) == 1 and first_mount.visible)
	var released: Dictionary = backend.call("release_packet", slot, 1)
	_check("presentation_session_release_restores_legacy_without_freeing_borrowed_mount",
		released.get("status") == "released" and legacy.visible \
		and is_instance_valid(first_mount) and not first_mount.visible)
	var light_only_mount := _make_session_presentation_mount(pivot, "light-only-member")
	var light_only_inputs := _session_presentation_candidate(world_id, 4, body, pivot,
		light_only_mount, legacy, "light-only-anchor", "light-only-member", false)
	var light_only_session := StaticSectionInstallSession.new()
	var light_only_begin: Dictionary = light_only_session.begin(backend, chunk,
		light_only_inputs.candidate, {}, {}, scene.world_static_section_coordinator,
		light_only_inputs.bindings)
	var light_only_result: Dictionary = {}
	if light_only_begin.get("status") == "begun":
		light_only_result = await _advance_presented_session(light_only_session, 1)
	var light_only_native: Dictionary = backend.call("installed_snapshot", slot)
	var light_only_roots: Array = light_only_native.get("attachmentRoots", [])
	_check("presentation_light_only_source_accepts_exact_empty_legacy_geometry_roster",
		light_only_result.get("status") == "installed" and light_only_roots.size() == 1 \
		and light_only_roots[0].get("legacyVisuals", [null]).is_empty() \
		and light_only_mount.get_parent() == pivot and light_only_mount.visible \
		and (light_only_mount.get_child(0) as OmniLight3D).is_visible_in_tree() and legacy.visible)
	var light_only_release: Dictionary = backend.call("release_packet", slot, 4)
	_check("presentation_light_only_release_preserves_source_ownership",
		light_only_release.get("status") == "released" and is_instance_valid(light_only_mount) \
		and light_only_mount.get_parent() == pivot and not light_only_mount.visible and legacy.visible)
	for mount: Node3D in [first_mount, second_mount, stale_mount]:
		if is_instance_valid(mount): mount.queue_free()
	body.queue_free()
	await process_frame
	await process_frame


func _make_session_presentation_mount(parent: Node3D, member_id: String) -> Node3D:
	var mount := Node3D.new()
	mount.name = "SessionMount_" + member_id.validate_node_name()
	mount.set_meta("section_attachment_presentation_member_id", member_id)
	mount.visible = false
	parent.add_child(mount)
	var light := OmniLight3D.new()
	light.name = "SessionLiveLight"
	mount.add_child(light)
	return mount


func _session_presentation_candidate(world_id: String, generation: int,
		body: StaticBody3D, parent: Node3D, mount: Node3D,
		legacy: GeometryInstance3D, attachment_key: String, member_id: String,
		include_legacy := true) -> Dictionary:
	var source_id := "session-source:lantern"
	var source_part_id := "session-part:lantern-0"
	var producer_revision := String(body.get_meta("section_attachment_source_revision", ""))
	var source_revision := "census:%d:%s" % [generation, producer_revision]
	var neutral := parent.global_transform
	var motion := {"kind":"static",
		"closedParentToBody":body.global_transform.affine_inverse() * neutral,
		"raiseOffset":Vector3.ZERO, "swing":0.0}
	motion.make_read_only()
	var bounds := AABB(body.global_position - Vector3(1.0, 0.0, 1.0), Vector3(2.0, 3.0, 2.0))
	var member := {"schema":"static-section-presentation-member/v2",
		"sourceId":source_id, "sourcePartId":source_part_id,
		"sourceRevision":source_revision, "presentationMemberId":member_id,
		"producerSourceRevision":producer_revision,
		"attachmentKey":attachment_key, "ownershipKind":"borrowed_presentation",
		"intendedVisible":true, "neutralParentToWorld":neutral,
		"sweptWorldBounds":bounds, "motion":motion}
	member.make_read_only()
	var members: Array[Dictionary] = [member]
	members.make_read_only()
	var batches: Array[Dictionary] = []
	batches.make_read_only()
	var support_ranges: Array = []
	support_ranges.make_read_only()
	var contributor := {"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"sourceId":source_id, "sourcePartId":source_part_id,
		"sourceRevision":source_revision, "ownerCell":Vector2i.ZERO,
		"sectionKey":Vector3i.ZERO, "bufferSpace":"section_local",
		"contributorKind":"presentation", "supportRanges":support_ranges,
		"batches":batches, "presentationMembers":members}
	contributor.make_read_only()
	var contributors: Array[Dictionary] = [contributor]
	contributors.make_read_only()
	var prepared: Dictionary = StaticSectionSnapshot.prepare_compile(Vector3i.ZERO, contributors)
	if prepared.get("status") != "ready": return {"status":"failed", "reason":prepared.get("reason", "prepare_failed")}
	var finalized: Dictionary = StaticSectionSnapshot.finalize_compile(prepared.preparation)
	if finalized.get("status") != "ready": return {"status":"failed", "reason":finalized.get("reason", "finalize_failed")}
	var snapshot: Dictionary = finalized.snapshot
	var digest := StaticSectionSnapshotBuilder._snapshot_digest(snapshot, world_id,
		generation, Vector3i.ZERO)
	var candidate := {"schema":"prepared-static-section-snapshot-envelope/v1",
		"worldId":world_id, "sectionKey":Vector3i.ZERO, "generation":generation,
		"contentManifestDigest":digest, "snapshot":snapshot}
	candidate.make_read_only()
	var legacy_refs: Array[WeakRef] = []
	if include_legacy: legacy_refs.append(weakref(legacy))
	legacy_refs.make_read_only()
	var binding := {"sourceId":source_id, "sourcePartId":source_part_id,
		"sourceRevision":source_revision, "presentationMemberId":member_id,
		"producerSourceRevision":producer_revision,
		"attachmentKey":attachment_key, "ownershipKind":"borrowed_presentation",
		"intendedVisible":true, "publisherInstanceId":int(body.get_meta("section_attachment_publisher_instance_id", 0)),
		"publicationEpoch":int(body.get_meta("section_attachment_publication_epoch", -1)),
		"neutralParentToWorld":neutral, "sweptWorldBounds":bounds,
		"motion":motion, "parent":weakref(parent), "body":weakref(body),
		"mount":weakref(mount), "bodyToWorld":body.global_transform,
		"mountLocalTransform":mount.transform, "legacyVisuals":legacy_refs}
	binding.make_read_only()
	return {"status":"ready", "candidate":candidate,
		"bindings":{attachment_key:binding}, "member":member}


func _tamper_presentation_candidate_visibility(candidate: Dictionary) -> Dictionary:
	var snapshot: Dictionary = candidate.snapshot.duplicate(false)
	var source_members: Array = candidate.snapshot.presentationMembers
	var tampered_members: Array[Dictionary] = []
	for source_member: Dictionary in source_members:
		var member := source_member.duplicate(false)
		member["intendedVisible"] = not bool(member.get("intendedVisible", false))
		member.make_read_only()
		tampered_members.append(member)
	tampered_members.make_read_only()
	snapshot["presentationMembers"] = tampered_members
	snapshot.make_read_only()
	var tampered := candidate.duplicate(false)
	tampered["snapshot"] = snapshot
	tampered.make_read_only()
	return tampered


func _test_mixed_section_install_session(scene: Node3D) -> void:
	var owner_result: Dictionary = scene.call("get_static_section_render_owner", Vector2i.ZERO, true)
	var chunk := owner_result.get("owner") as Node3D
	var backend := owner_result.get("backend") as Node
	if not is_instance_valid(chunk) or not is_instance_valid(backend):
		_check("presentation_session_installs_geometry_and_borrowed_member_atomically", false)
		return
	var body := StaticBody3D.new()
	body.set_meta("section_attachment_source_revision", "mixed-session-revision-1")
	body.set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
	body.set_meta("section_attachment_publication_epoch", 105)
	scene.add_child(body)
	var pivot := Node3D.new()
	body.add_child(pivot)
	var geometry_legacy := MeshInstance3D.new()
	geometry_legacy.mesh = BoxMesh.new()
	body.add_child(geometry_legacy)
	var presentation_legacy := MeshInstance3D.new()
	presentation_legacy.mesh = BoxMesh.new()
	body.add_child(presentation_legacy)
	var mount := _make_session_presentation_mount(pivot, "mixed-presentation-member")
	var producer_revision := String(body.get_meta("section_attachment_source_revision", ""))
	var source_revision := "mixed-census:" + producer_revision
	var neutral := pivot.global_transform
	var motion := {"kind":"static",
		"closedParentToBody":body.global_transform.affine_inverse() * neutral,
		"raiseOffset":Vector3.ZERO, "swing":0.0}
	motion.make_read_only()
	var swept := AABB(body.global_position - Vector3.ONE, Vector3.ONE * 2.0)
	var geometry_key := "mixed-geometry-anchor"
	var presentation_key := "mixed-borrowed-mount"
	var geometry_source := "mixed-geometry-source"
	var geometry_part := "mixed-geometry-part"
	var presentation_source := "mixed-presentation-source"
	var presentation_part := "mixed-presentation-part"
	var member_id := "mixed-presentation-member"
	var member := {"schema":"static-section-presentation-member/v2",
		"sourceId":presentation_source, "sourcePartId":presentation_part,
		"sourceRevision":source_revision, "presentationMemberId":member_id,
		"producerSourceRevision":producer_revision,
		"attachmentKey":presentation_key, "ownershipKind":"borrowed_presentation",
		"intendedVisible":true, "neutralParentToWorld":neutral,
		"sweptWorldBounds":swept, "motion":motion}
	member.make_read_only()
	var presentation_members: Array[Dictionary] = [member]
	presentation_members.make_read_only()
	var float_buffer: Array[float] = [1.0,0.0,0.0,0.0, 0.0,1.0,0.0,0.0,
		0.0,0.0,1.0,0.0, 1.0,1.0,1.0,1.0, 0.0,0.0,0.0,0.0]
	float_buffer.make_read_only()
	var segment := {"segmentId":"mixed-session-segment", "buffer":float_buffer,
		"bounds":AABB(Vector3(-0.5,-0.5,-0.5), Vector3.ONE), "instanceCount":1}
	segment.make_read_only()
	var segments: Array[Dictionary] = [segment]
	segments.make_read_only()
	var mesh := BoxMesh.new()
	var mesh_fingerprint: Dictionary = StaticMeshFingerprint.inspect(mesh)
	var mesh_digest := String(mesh_fingerprint.get("contentDigest", ""))
	var mesh_key := "mixed-session-mesh"
	var material_key := "mixed-session-material"
	var batch_key := "mixed-session-compatible-batch"
	var batch := {"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"batchKey":batch_key, "materialKey":material_key, "meshKey":mesh_key,
		"meshContentDigest":mesh_digest, "renderTier":"structural",
		"renderLayer":"opaque", "transparencySortPolicy":"none",
		"castShadows":true, "intendedVisible":false,
		"visibilityRangeEnd":0.0, "fadeMargin":0.0,
		"attachmentKey":geometry_key, "neutralParentToWorld":neutral,
		"producerSourceRevision":producer_revision,
		"sweptWorldBounds":swept, "motion":motion, "segments":segments}
	batch.make_read_only()
	var batches := {batch_key:batch}
	batches.make_read_only()
	var geometry_batch_keys: Array[String] = [batch_key]
	geometry_batch_keys.make_read_only()
	var empty_batch_keys: Array[String] = []
	empty_batch_keys.make_read_only()
	var empty_ranges: Array = []
	empty_ranges.make_read_only()
	var geometry_manifest := {"sourceId":geometry_source,
		"sourcePartId":geometry_part, "sourceRevision":source_revision,
		"batchKeys":geometry_batch_keys, "ranges":empty_ranges}
	geometry_manifest.make_read_only()
	var presentation_manifest := {"sourceId":presentation_source,
		"sourcePartId":presentation_part, "sourceRevision":source_revision,
		"batchKeys":empty_batch_keys, "ranges":empty_ranges}
	presentation_manifest.make_read_only()
	var manifest: Array[Dictionary] = [geometry_manifest, presentation_manifest]
	manifest.make_read_only()
	var dependencies := StaticRenderSectionGrid.stream_chunk_keys_intersecting_section(Vector3i.ZERO)
	dependencies.make_read_only()
	var snapshot_batch_keys: Array[String] = [batch_key]
	snapshot_batch_keys.make_read_only()
	var layers: Array[Dictionary] = []
	for layer_name: String in ["opaque", "cutout", "translucent"]:
		var layer := {"layer":layer_name,
			"expectedBatchCount":1 if layer_name == "opaque" else 0,
			"expectedInstanceCount":1 if layer_name == "opaque" else 0}
		layer.make_read_only()
		layers.append(layer)
	layers.make_read_only()
	var snapshot := {"schema":"chunk-static-render-section-snapshot/v3",
		"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"sectionKey":Vector3i.ZERO, "streamChunkKey":Vector2i.ZERO,
		"streamChunkDependencies":dependencies, "manifest":manifest,
		"batchKeys":snapshot_batch_keys, "presentationMembers":presentation_members,
		"renderLayers":layers, "batches":batches, "contributorCount":2,
		"batchGroupCount":1, "batchCount":1, "inputSegmentCount":1,
		"segmentCount":1, "instanceCount":1}
	snapshot.make_read_only()
	var world_id := "native-mixed-presentation-session-contract"
	var digest := StaticSectionSnapshotBuilder._snapshot_digest(snapshot,
		world_id, 1, Vector3i.ZERO)
	var candidate := {"schema":"prepared-static-section-snapshot-envelope/v1",
		"worldId":world_id, "sectionKey":Vector3i.ZERO, "generation":1,
		"contentManifestDigest":digest, "snapshot":snapshot}
	candidate.make_read_only()
	var geometry_legacy_refs: Array[WeakRef] = [weakref(geometry_legacy)]
	geometry_legacy_refs.make_read_only()
	var presentation_legacy_refs: Array[WeakRef] = [weakref(presentation_legacy)]
	presentation_legacy_refs.make_read_only()
	var common_binding := {"sourceRevision":source_revision,
		"producerSourceRevision":producer_revision,
		"parentInstanceId":pivot.get_instance_id(), "bodyInstanceId":body.get_instance_id(),
		"publisherInstanceId":int(body.get_meta("section_attachment_publisher_instance_id", 0)),
		"publicationEpoch":int(body.get_meta("section_attachment_publication_epoch", -1)),
		"bodyToWorld":body.global_transform,
		"neutralParentToWorld":neutral, "motion":motion,
		"parent":weakref(pivot), "body":weakref(body)}
	var geometry_binding := common_binding.duplicate(false)
	geometry_binding["sourceId"] = geometry_source
	geometry_binding["sourcePartId"] = geometry_part
	geometry_binding["ownershipKind"] = "backend_owned_geometry"
	geometry_binding["legacyVisuals"] = geometry_legacy_refs
	geometry_binding.make_read_only()
	var presentation_binding := common_binding.duplicate(false)
	presentation_binding["sourceId"] = presentation_source
	presentation_binding["sourcePartId"] = presentation_part
	presentation_binding["sourceRevision"] = source_revision
	presentation_binding["presentationMemberId"] = member_id
	presentation_binding["attachmentKey"] = presentation_key
	presentation_binding["ownershipKind"] = "borrowed_presentation"
	presentation_binding["intendedVisible"] = true
	presentation_binding["sweptWorldBounds"] = swept
	presentation_binding["mount"] = weakref(mount)
	presentation_binding["mountLocalTransform"] = mount.transform
	presentation_binding["legacyVisuals"] = presentation_legacy_refs
	presentation_binding.make_read_only()
	var bindings := {geometry_key:geometry_binding,
		presentation_key:presentation_binding}
	var session := StaticSectionInstallSession.new()
	var begun: Dictionary = session.begin(backend, chunk, candidate,
		{material_key:StandardMaterial3D.new()}, {mesh_key:mesh},
		scene.world_static_section_coordinator, bindings)
	var installed: Dictionary = {}
	if begun.get("status") == "begun":
		installed = await _advance_presented_session(session, 1)
	var native: Dictionary = backend.call("installed_snapshot",
		StaticSectionInstallSession.slot_id(world_id, Vector3i.ZERO))
	var native_batches: Array = native.get("batches", [])
	diagnostics["mixedPresentationSession"] = {"begin":begun,
		"advance":installed, "installed":native}
	var batch_receipt: Dictionary = native_batches[0] if native_batches.size() == 1 else {}
	var attachment_receipts: Array = native.get("attachmentRoots", [])
	var has_both_kinds := attachment_receipts.size() == 2
	var borrowed_root_claim := false
	var geometry_anchor_active := false
	for receipt_value: Variant in attachment_receipts:
		if not receipt_value is Dictionary: continue
		var receipt: Dictionary = receipt_value
		if receipt.get("ownershipKind", "") == "borrowed_presentation":
			borrowed_root_claim = int(receipt.get("rootInstanceId", 0)) == mount.get_instance_id() \
				and bool(receipt.get("activeClaim", false)) and mount.visible
		elif receipt.get("ownershipKind", "") == "backend_owned_geometry":
			geometry_anchor_active = bool(receipt.get("activeClaim", false)) \
				and int(receipt.get("rootInstanceId", 0)) > 0
	_check("presentation_session_installs_geometry_and_borrowed_member_atomically",
		begun.get("status") == "begun" and installed.get("status") == "installed" \
		and native.get("status") == "ready" and int(native.get("instanceCount", -1)) == 1 \
		and has_both_kinds and borrowed_root_claim and geometry_anchor_active \
		and batch_receipt.get("intendedVisible", true) == false \
		and not geometry_legacy.visible and not presentation_legacy.visible \
		and mount.visible and not geometry_legacy.is_queued_for_deletion())
	backend.call("release_packet", StaticSectionInstallSession.slot_id(world_id, Vector3i.ZERO), 1)
	body.queue_free()
	await process_frame
	await process_frame


func _test_borrowed_presentation_tail(scene: Node3D, backend: Node, source: String,
		body: StaticBody3D, pivot: Node3D, mount: Node3D, mount_id: int,
		other_mount: Node3D, other_mount_id: int, other_light: OmniLight3D,
		fifth: Dictionary, fifth_pending: Dictionary, fifth_ack: Dictionary,
		replacement_installed: Dictionary, released: Dictionary, chunk: Node3D) -> void:
	_check("borrowed_acknowledged_replacement_retires_no_source_owned_mount", \
		fifth.get("status") == "ready_to_commit" and fifth_pending.get("status") == "pending_presentation" \
		and fifth_ack.get("status") == "ready" and replacement_installed.get("status") == "ready" \
		and released.get("status") == "released" and not other_mount.visible \
		and is_instance_id_valid(other_mount_id) and is_instance_valid(other_light))

	var incomplete := _prepare_borrowed_packet(backend, source, 6, body, pivot, mount,
		"torch-light:owner-0", "extra")
	var incomplete_commit: Dictionary = backend.call("commit_packet", source, 6, false)
	var incomplete_abort: Dictionary = backend.call("abort_packet", source, 6)
	_check("borrowed_manifest_rejects_unregistered_extra_member_without_hiding_mount", \
		incomplete.get("status") == "ready_to_commit" and incomplete_commit.get("status") == "failed" \
		and incomplete_commit.get("reason", "") == "attachment_manifest_membership_mismatch" \
		and incomplete_abort.get("status") == "aborted" and is_instance_id_valid(mount_id) and not mount.visible)

	var duplicate_member := _prepare_borrowed_packet(backend, source, 7, body, pivot, mount,
		"torch-light:owner-0", "duplicate_member")
	var duplicate_abort: Dictionary = backend.call("abort_packet", source, 7)
	_check("borrowed_manifest_rejects_duplicate_member_identity", \
		duplicate_member.get("status") == "failed" \
		and duplicate_member.get("reason", "") == "attachment_manifest_duplicate_identity" \
		and duplicate_abort.get("status") == "aborted")

	var unknown_kind := _prepare_borrowed_packet(backend, source, 8, body, pivot, mount,
		"torch-light:owner-0", "unknown_kind")
	var unknown_abort: Dictionary = backend.call("abort_packet", source, 8)
	_check("borrowed_manifest_rejects_unknown_ownership_kind", \
		unknown_kind.get("status") == "failed" \
		and unknown_kind.get("reason", "") == "attachment_manifest_member_invalid" \
		and unknown_abort.get("status") == "aborted")

	var over_cap := _prepare_borrowed_packet(backend, source, 9, body, pivot, mount,
		"torch-light:owner-0", "over_cap")
	var cap_abort: Dictionary = backend.call("abort_packet", source, 9)
	_check("borrowed_manifest_enforces_member_cap", \
		over_cap.get("status") == "failed" \
		and over_cap.get("reason", "") == "attachment_manifest_header_invalid" \
		and cap_abort.get("status") == "aborted")

	var stale_binding := _prepare_borrowed_packet(backend, source, 10, body, pivot, mount, "torch-light:owner-0")
	body.set_meta("section_attachment_source_revision", "torch-revision-mutated-after-admission")
	var stale_commit: Dictionary = backend.call("commit_packet", source, 10, false)
	var stale_abort: Dictionary = backend.call("abort_packet", source, 10)
	body.set_meta("section_attachment_source_revision", "torch-revision-1")
	_check("borrowed_manifest_rejects_source_revision_changed_after_binding", \
		stale_binding.get("status") == "ready_to_commit" and stale_commit.get("status") == "failed" \
		and stale_commit.get("reason", "") == "attachment_binding_stale" \
		and stale_abort.get("status") == "aborted" and is_instance_id_valid(mount_id) and not mount.visible)

	var reentry: Dictionary = _prepare_borrowed_packet(backend, source, 11, body, pivot, mount, "torch-light:owner-0")
	var reentry_install: Dictionary = backend.call("commit_packet", source, 11, false)
	pivot.remove_child(mount)
	var detached_snapshot: Dictionary = backend.call("installed_snapshot", source)
	pivot.add_child(mount)
	var reentered_snapshot: Dictionary = backend.call("installed_snapshot", source)
	var reentry_release: Dictionary = backend.call("release_packet", source, 11)
	_check("borrowed_mount_detach_is_stale_then_exact_reentry_recovers", \
		reentry.get("status") == "ready_to_commit" and reentry_install.get("status") == "ready" \
		and detached_snapshot.get("status") == "stale" and reentered_snapshot.get("status") == "ready" \
		and reentry_release.get("status") == "released" and is_instance_id_valid(mount_id))

	var lost_admission: Dictionary = _prepare_borrowed_packet(backend, source, 12, body, pivot, mount, "torch-light:owner-0")
	var lost_pending: Dictionary = backend.call("commit_packet", source, 12, true)
	var lost_token := String(lost_pending.get("token", ""))
	mount.queue_free()
	await process_frame
	var lost_snapshot: Dictionary = backend.call("pending_presentation_snapshot", source)
	var lost_settlement: Dictionary = backend.call("settle_presentation_cancellation", source, 12, lost_token)
	_check("borrowed_mount_destruction_preserves_exact_cancellation_receipt", \
		lost_admission.get("status") == "ready_to_commit" and lost_pending.get("status") == "pending_presentation" \
		and lost_snapshot.get("status") == "owner_lost" and lost_snapshot.get("token", "") == lost_token \
		and lost_settlement.get("status") == "cancelled" \
		and lost_settlement.get("token", "") == lost_token and lost_settlement.get("candidateQuiesced", false))

	var exit_chunk := Node3D.new()
	exit_chunk.name = "Chunk_0_0"
	# A second owner for the same cell needs its own parent namespace.
	var exit_scope := Node3D.new()
	scene.add_child(exit_scope)
	exit_scope.add_child(exit_chunk)
	var exit_attached: Dictionary = PacketOwner.attach_to_chunk(exit_chunk)
	var exit_backend: Node = exit_attached.get("backend") as Node
	var exit_body := StaticBody3D.new()
	exit_body.set_meta("section_attachment_source_revision", "exit-revision")
	exit_body.set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
	exit_body.set_meta("section_attachment_publication_epoch", 32)
	scene.add_child(exit_body)
	var exit_pivot := Node3D.new()
	exit_body.add_child(exit_pivot)
	var exit_mount := Node3D.new()
	exit_mount.set_meta("section_attachment_presentation_member_id", "exit-light:owner-0")
	exit_mount.visible = false
	exit_pivot.add_child(exit_mount)
	var exit_light := OmniLight3D.new()
	exit_mount.add_child(exit_light)
	var exit_mount_id := exit_mount.get_instance_id()
	var exit_light_id := exit_light.get_instance_id()
	var exit_packet := _prepare_borrowed_packet(exit_backend, "native-contract:borrowed-backend-exit",
		1, exit_body, exit_pivot, exit_mount, "exit-light:owner-0")
	var exit_install: Dictionary = exit_backend.call("commit_packet", "native-contract:borrowed-backend-exit", 1, false)
	exit_backend.queue_free()
	await process_frame
	await process_frame
	_check("borrowed_backend_exit_hides_but_never_frees_source_mount", \
		exit_packet.get("status") == "ready_to_commit" and exit_install.get("status") == "ready" \
		and is_instance_id_valid(exit_mount_id) and is_instance_id_valid(exit_light_id) \
		and exit_mount.get_parent() == exit_pivot and not exit_mount.visible and exit_light.get_parent() == exit_mount)
	exit_body.queue_free()
	exit_scope.queue_free()

	# Previous owner loss during candidate frame wait must not erase the live
	# replacement token or root; the candidate remains acknowledgeable.
	var old_body := StaticBody3D.new()
	old_body.name = "BorrowedPreviousOwner"
	old_body.set_meta("section_attachment_source_revision", "torch-old-revision")
	old_body.set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
	old_body.set_meta("section_attachment_publication_epoch", 45)
	scene.add_child(old_body)
	var old_parent := Node3D.new()
	old_body.add_child(old_parent)
	var old_mount := Node3D.new()
	old_mount.set_meta("section_attachment_presentation_member_id", "torch-light:transition")
	old_mount.visible = false
	old_parent.add_child(old_mount)
	var transition_source := "native-contract:borrowed-owner-exit"
	var old_install := _prepare_borrowed_packet(backend, transition_source, 1,
		old_body, old_parent, old_mount, "torch-light:transition")
	var old_pending: Dictionary = backend.call("commit_packet", transition_source, 1, true)
	var old_ack: Dictionary = backend.call("finalize_presentation", transition_source, 1, String(old_pending.get("token", "")))
	var new_body := StaticBody3D.new()
	new_body.name = "BorrowedReplacementOwner"
	new_body.set_meta("section_attachment_source_revision", "torch-new-revision")
	new_body.set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
	new_body.set_meta("section_attachment_publication_epoch", 46)
	scene.add_child(new_body)
	var new_parent := Node3D.new()
	new_body.add_child(new_parent)
	var new_mount := Node3D.new()
	new_mount.set_meta("section_attachment_presentation_member_id", "torch-light:transition")
	new_mount.visible = false
	new_parent.add_child(new_mount)
	var new_mount_id := new_mount.get_instance_id()
	var new_candidate := _prepare_borrowed_packet(backend, transition_source, 2,
		new_body, new_parent, new_mount, "torch-light:transition")
	var new_pending: Dictionary = backend.call("commit_packet", transition_source, 2, true)
	old_body.free()
	var after_previous_loss: Dictionary = backend.call("pending_presentation_snapshot", transition_source)
	var replacement_survived_previous_exit: bool = after_previous_loss.get("status") == "pending_presentation" \
		and after_previous_loss.get("token", "") == new_pending.get("token", "") \
		and after_previous_loss.get("generation", 0) == 2 and new_mount.visible \
		and is_instance_id_valid(new_mount_id)
	var new_ack: Dictionary = backend.call("finalize_presentation", transition_source, 2, String(new_pending.get("token", "")))
	_check("borrowed_previous_owner_loss_preserves_candidate_ack_transaction", \
		old_install.get("status") == "ready_to_commit" and old_pending.get("status") == "pending_presentation" \
		and old_ack.get("status") == "ready" and new_candidate.get("status") == "ready_to_commit" \
		and new_pending.get("status") == "pending_presentation" and replacement_survived_previous_exit \
		and new_ack.get("status") == "ready" and backend.call("installed_snapshot", transition_source).get("status") == "ready")
	backend.call("release_packet", transition_source, 2)
	new_body.queue_free()
	body.queue_free()
	chunk.queue_free()
	await process_frame
	await process_frame


func _borrowed_manifest_digest(members: Array[Dictionary]) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	var canonical: Array = []
	for member: Dictionary in members:
		canonical.push_back(member.duplicate(false))
	var payload: PackedByteArray = var_to_bytes(canonical)
	if context.update(payload) != OK:
		return ""
	return context.finish().hex_encode()


func _prepare_borrowed_packet(backend: Node, source: String, generation: int,
		body: Node3D, parent: Node3D, mount: Node3D, member_id: String,
		manifest_case: String = "", with_geometry: bool = false) -> Dictionary:
	var key := member_id
	var member_source_id := "torch-source:fireplace-0"
	var producer_revision := String(body.get_meta("section_attachment_source_revision", ""))
	var source_revision := "census:%d:%s" % [generation, producer_revision]
	var source_part_id := "torch-part:owner-0"
	var neutral := parent.global_transform
	var motion := {"kind":"swing", "closedParentToBody":body.global_transform.affine_inverse() * neutral,
		"raiseOffset":Vector3.ZERO, "swing":0.35}
	var row := {"schema":"static-section-presentation-member/v2",
		"sourceId":member_source_id, "sourcePartId":source_part_id,
		"sourceRevision":source_revision, "producerSourceRevision":producer_revision, "attachmentKey":key,
		"presentationMemberId":member_id, "ownershipKind":"borrowed_presentation",
		"intendedVisible":true, "neutralParentToWorld":neutral,
		"sweptWorldBounds":AABB(body.global_position - Vector3.ONE, Vector3.ONE * 2.0),
		"motion":motion}
	var registration_motion: Dictionary = motion.duplicate(true)
	if manifest_case == "extra_manifest_field":
		row["unexpected"] = true
	elif manifest_case == "identity_variant_type":
		row["sourceId"] = StringName(member_source_id)
	elif manifest_case == "zero_swept_bounds":
		row["sweptWorldBounds"] = AABB(body.global_position, Vector3.ZERO)
	var members: Array[Dictionary] = [row]
	if manifest_case == "extra":
		var omitted: Dictionary = row.duplicate(true)
		omitted["attachmentKey"] = member_id + ":extra"
		omitted["presentationMemberId"] = member_id + ":extra"
		omitted["sourcePartId"] = source_part_id + ":extra"
		members.push_back(omitted)
	elif manifest_case == "duplicate_member":
		var duplicate: Dictionary = row.duplicate(true)
		duplicate["attachmentKey"] = member_id + ":duplicate"
		members.push_back(duplicate)
	elif manifest_case == "unknown_kind":
		row["ownershipKind"] = "unknown_visual_owner"
	elif manifest_case == "over_cap":
		for index: int in range(256):
			var extra: Dictionary = row.duplicate(true)
			extra["attachmentKey"] = "zz-extra-%03d" % index
			extra["presentationMemberId"] = "zz-extra-member-%03d" % index
			extra["sourcePartId"] = "zz-extra-part-%03d" % index
			members.push_back(extra)
	members.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return String(left["attachmentKey"]) < String(right["attachmentKey"]))
	var manifest_digest := _borrowed_manifest_digest(members)
	if manifest_digest.is_empty():
		return {"status":"failed", "reason":"fixture_manifest_digest_failed"}
	var packet_digest := "borrowed-presentation:" + manifest_digest
	var layers: Array[Dictionary] = [
		{"layer":"opaque", "expectedBatchCount":1 if with_geometry else 0,
			"expectedInstanceCount":1 if with_geometry else 0},
		{"layer":"cutout", "expectedBatchCount":0, "expectedInstanceCount":0},
		{"layer":"translucent", "expectedBatchCount":0, "expectedInstanceCount":0}]
	var begun: Dictionary = backend.call("begin_packet_with_layers", source, OWNER_CELL, generation,
		"section-revision-%d" % generation, packet_digest, Transform3D.IDENTITY,
		1 if with_geometry else 0,
		1 if with_geometry else 0, layers)
	if begun.get("status") not in ["ready_to_append", "ready_to_commit"]: return begun
	var declared: Dictionary = backend.call("declare_attachment_manifest", source,
		generation, members, manifest_digest)
	if declared.get("status") != "manifest_declared": return declared
	if manifest_case == "mutate_motion_after_declaration":
		motion["swing"] = 0.75
	var registered: Dictionary = backend.call("register_borrowed_presentation", source,
		generation, key, member_source_id, source_part_id, member_id, mount, parent, body, neutral, mount.transform,
		registration_motion, true, [])
	if registered.get("status") != "registered_borrowed":
		backend.call("abort_packet", source, generation)
		return registered
	if with_geometry:
		var mesh := ArrayMesh.new()
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var identity: Dictionary = StaticMeshFingerprint.inspect(mesh)
		var appended: Dictionary = _append_native_layer_batch(backend, source, generation,
			"borrowed-mixed-geometry", mesh, String(identity.get("contentDigest", "")),
			StandardMaterial3D.new(), "opaque", Vector3.ZERO)
		if appended.get("status") != "accepted":
			backend.call("abort_packet", source, generation)
			return appended
	var progressed: Dictionary = backend.call("advance_packet", source, generation, 1)
	progressed["testManifestDigest"] = manifest_digest
	progressed["testPacketDigest"] = packet_digest
	progressed["testCallerMotionMutated"] = manifest_case == "mutate_motion_after_declaration" \
		and float(motion.get("swing", 0.0)) == 0.75
	return progressed


func _test_attachment_refcounted_publisher(scene: Node3D) -> void:
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	scene.add_child(chunk)
	var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
	var backend: Node = attached.get("backend")
	var publisher := RefCounted.new()
	var owners := _make_attachment_test_owners(scene)
	for body: Node3D in owners.bodies:
		body.set_meta("section_attachment_publisher_instance_id",publisher.get_instance_id())
	var source := "native-contract:refcounted-publisher"
	var prepared := _prepare_attachment_packet(backend,source,1,owners.bodies,owners.pivots,owners.neutral)
	var installed: Dictionary = backend.call("commit_packet",source,1,false)
	var exact_identity: bool = publisher.get_instance_id()<0 and installed.get("status")=="ready"
	for receipt: Dictionary in installed.get("attachmentRoots",[]):
		exact_identity = exact_identity and receipt.get("publisherInstanceId")==publisher.get_instance_id()
	_check("attachment_real_refcounted_publisher_identity_is_valid",exact_identity \
		and prepared.get("status")=="ready_to_commit" and installed.get("attachmentRoots",[]).size()==2)
	backend.call("release_packet",source,1)
	for body: Node3D in owners.bodies: body.queue_free()
	chunk.queue_free()
	await process_frame
	await process_frame


func _test_attachment_previous_unavailable_matrix(scene: Node3D) -> void:
	# Synthetic native lifetime matrix; real gameplay input is covered separately.
	for phase: String in ["staged", "pending"]:
		for loss: String in ["body", "pivot", "revision", "detach"]:
			for action: String in ["ack", "cancel"]:
				var chunk := Node3D.new()
				chunk.name = "Chunk_0_0"
				scene.add_child(chunk)
				var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
				var backend: Node = attached.get("backend")
				var old := _make_attachment_test_owners(scene)
				var next := _make_attachment_test_owners(scene)
				var source := "native-contract:previous-%s-%s-%s" % [phase, loss, action]
				_prepare_attachment_packet(backend, source, 1, old.bodies, old.pivots, old.neutral)
				backend.call("commit_packet", source, 1, false)
				_prepare_attachment_packet(backend, source, 2, next.bodies, next.pivots, next.neutral, 1 if phase == "staged" else 3)
				var pending: Dictionary = {}
				if phase == "pending": pending = backend.call("commit_packet", source, 2, true)
				if loss == "body": old.bodies[0].free()
				elif loss == "pivot": old.pivots[0].free()
				elif loss == "detach": scene.remove_child(old.bodies[0])
				else: old.bodies[0].set_meta("section_attachment_source_revision", "changed")
				var old_visual := _attachment_legacy_visuals([old.bodies[1]], [old.pivots[1]])[0]
				var old_restore: Dictionary = backend.call("restore_legacy_for_visual", old_visual.get_instance_id())
				var retained: bool = old_restore.get("status") in ["retained_previous", "retained_suppressed"]
				var passed := false
				if phase == "staged" and action == "cancel":
					var aborted: Dictionary = backend.call("abort_packet", source, 2)
					passed = aborted.get("status") == "aborted"
				else:
					if phase == "staged":
						backend.call("advance_packet", source, 2, 8)
						pending = backend.call("commit_packet", source, 2, true)
					var token := String(pending.get("token", ""))
					var polled: Dictionary = backend.call("settle_presentation_cancellation", source, 2, token)
					passed = pending.get("status") == "pending_presentation" and polled.get("status") == "not_applicable"
					if action == "ack":
						var accepted: Dictionary = backend.call("finalize_presentation", source, 2, token)
						passed = passed and accepted.get("status") == "ready"
					else:
						var settled: Dictionary = backend.call("settle_presentation_cancellation", source, 2, token, true)
						if loss == "revision":
							# Follow Session's complete explicit cancellation sequence:
							# stale source identity does not invalidate retained geometry.
							var rolled_back: Dictionary = backend.call("rollback_presentation", source, 2, token)
							passed = passed and settled.get("status") == "not_applicable" \
								and rolled_back.get("status") == "rolled_back"
						else:
							passed = passed and settled.get("status") == "cancelled" \
								and settled.get("presentationToken") == token and bool(settled.get("ownershipReleased", false)) \
								and bool(settled.get("candidateQuiesced", false)) and not bool(settled.get("previousRestored", true)) \
								and bool(settled.get("previousUnavailable", false))
				_check("attachment_previous_%s_%s_%s" % [phase, loss, action], passed and retained)
				backend.call("release_packet", source, 2)
				backend.call("release_packet", source, 1)
				for owners: Dictionary in [old, next]:
					for body: Variant in owners.bodies:
						if is_instance_valid(body): body.queue_free()
				chunk.queue_free()
				await process_frame
				await process_frame


func _test_attachment_owner_loss(scene: Node3D, destroy_body: bool) -> void:
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	scene.add_child(chunk)
	var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
	var backend: Node = attached.get("backend")
	var bodies: Array[Node3D] = []
	var pivots: Array[Node3D] = []
	var neutral: Array[Transform3D] = []
	for index in range(2):
		var body := StaticBody3D.new()
		scene.add_child(body)
		body.set_meta("section_attachment_source_revision", "door-source-%d" % index)
		body.set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
		body.set_meta("section_attachment_publication_epoch", 17)
		var pivot := Node3D.new()
		body.add_child(pivot)
		var frame := MeshInstance3D.new()
		frame.mesh = BoxMesh.new()
		body.add_child(frame)
		var leaf := MeshInstance3D.new()
		leaf.mesh = BoxMesh.new()
		pivot.add_child(leaf)
		bodies.append(body)
		pivots.append(pivot)
		neutral.append(pivot.global_transform)
	var source := "native-contract:owner-loss"
	_prepare_attachment_packet(backend, source, 1, bodies, pivots, neutral)
	backend.call("commit_packet", source, 1, false)
	if not destroy_body:
		var original := _attachment_legacy_visuals([bodies[0]], [pivots[0]])[0]
		original.reparent(bodies[1], true)
		var unrelated := MeshInstance3D.new()
		unrelated.mesh = BoxMesh.new()
		unrelated.visible = false
		bodies[0].add_child(unrelated)
		var fallback: Dictionary = backend.call("restore_legacy_for_visual", original.get_instance_id())
		_check("attachment_stale_owner_never_restores_moved_or_replacement_visual", \
			fallback.get("status") == "restored" and not original.visible and not unrelated.visible)
		unrelated.free()
		original.reparent(bodies[0], true)
		original.visible = true
		await process_frame
		await process_frame
		_prepare_attachment_packet(backend, source, 2, bodies, pivots, neutral)
		backend.call("commit_packet", source, 2, false)
	var root_ids: Array[int] = []
	var installed: Dictionary = backend.call("installed_snapshot", source)
	root_ids.append(int(installed.get("rootInstanceId", 0)))
	for external: Node3D in _attachment_children(pivots): root_ids.append(external.get_instance_id())
	if destroy_body: bodies[0].free()
	else: pivots[0].free()
	var after_owner_exit: Dictionary = backend.call("installed_snapshot", source)
	var surviving_legacy := _attachment_legacy_visuals([bodies[1]], [pivots[1]])
	var remaining_hidden := _attachment_children([pivots[1]]).all(func(node: Node3D) -> bool: return not node.visible)
	await process_frame
	await process_frame
	var all_roots_gone := root_ids.size() == 3
	for id: int in root_ids: all_roots_gone = all_roots_gone and not is_instance_id_valid(id)
	_check("attachment_%s_destroy_withdraws_complete_packet" % ("body" if destroy_body else "pivot"), \
		after_owner_exit.get("status") == "missing" and remaining_hidden and all_roots_gone \
		and surviving_legacy.all(func(node: GeometryInstance3D) -> bool: return node.visible))
	for body: Variant in bodies:
		if is_instance_valid(body): body.queue_free()
	chunk.queue_free()
	await process_frame


func _make_attachment_test_owners(scene: Node3D) -> Dictionary:
	var bodies: Array[Node3D] = []
	var pivots: Array[Node3D] = []
	var neutral: Array[Transform3D] = []
	for index in range(2):
		var body := StaticBody3D.new()
		scene.add_child(body)
		body.set_meta("section_attachment_source_revision", "door-source-%d" % index)
		body.set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
		body.set_meta("section_attachment_publication_epoch", 17)
		var pivot := Node3D.new()
		body.add_child(pivot)
		for parent: Node3D in [body, pivot]:
			var visual := MeshInstance3D.new()
			visual.mesh = BoxMesh.new()
			parent.add_child(visual)
		bodies.append(body)
		pivots.append(pivot)
		neutral.append(pivot.global_transform)
	return {"bodies":bodies, "pivots":pivots, "neutral":neutral}


func _test_attachment_awaiting_owner_replacement(scene: Node3D) -> void:
	for mode: String in ["previous_body", "previous_pivot", "candidate_body", "candidate_pivot"]:
		var chunk := Node3D.new()
		chunk.name = "Chunk_0_0"
		scene.add_child(chunk)
		var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
		var backend: Node = attached.get("backend")
		var old := _make_attachment_test_owners(scene)
		var next := _make_attachment_test_owners(scene)
		var source := "native-contract:awaiting-owner-" + mode
		_prepare_attachment_packet(backend, source, 1, old.bodies, old.pivots, old.neutral)
		backend.call("commit_packet", source, 1, false)
		_prepare_attachment_packet(backend, source, 2, next.bodies, next.pivots, next.neutral)
		var pending: Dictionary = backend.call("commit_packet", source, 2, true)
		var token := String(pending.get("token", ""))
		var old_visual := _attachment_legacy_visuals([old.bodies[1]], [old.pivots[1]])[0]
		var retained: Dictionary = backend.call("legacy_visual_state", old_visual.get_instance_id())
		var attempted_old_restore: Dictionary = backend.call("restore_legacy_for_visual", old_visual.get_instance_id())
		var unchanged: Dictionary = backend.call("pending_presentation_snapshot", source)
		_check("attachment_%s_previous_claim_cannot_withdraw_candidate" % mode, \
			retained.get("status") == "retained_previous" and retained.get("role") == "previous" \
			and attempted_old_restore.get("status") == "retained_previous" \
			and unchanged.get("status") == "pending_presentation" and unchanged.get("token") == token)
		var lost: Dictionary = old if mode.begins_with("previous") else next
		if mode.ends_with("body"): lost.bodies[0].free()
		else: lost.pivots[0].free()
		var after_loss: Dictionary = backend.call("pending_presentation_snapshot", source)
		if mode.begins_with("previous"):
			var still_retained: Dictionary = backend.call("legacy_visual_state", old_visual.get_instance_id())
			var unrelated_settle: Dictionary = backend.call("settle_attachment_owner_loss", source, 2, token)
			var accepted: Dictionary = backend.call("finalize_presentation", source, 2, token)
			_check("attachment_%s_loss_preserves_candidate_and_ack" % mode, \
				after_loss.get("status") == "pending_presentation" and after_loss.get("token") == token \
				and bool(after_loss.get("previousUnavailable", false)) \
				and still_retained.get("status") == "retained_previous" \
				and unrelated_settle.get("status") == "not_applicable" and accepted.get("status") == "ready")
			backend.call("release_packet", source, 2)
		else:
			var anchor := instance_from_id(int(pending.get("rootInstanceId", 0))) as Node3D
			var wrong_token: Dictionary = backend.call("settle_attachment_owner_loss", source, 2, token + "wrong")
			var unsettled: Dictionary = backend.call("pending_presentation_snapshot", source)
			_check("attachment_%s_loss_quiesces_but_retains_token" % mode, \
				after_loss.get("status") == "owner_lost" and after_loss.get("token") == token \
				and not bool(after_loss.get("ownershipReleased", true)) \
				and anchor != null and not anchor.visible \
				and _attachment_children([next.pivots[1]]).all(func(node: Node3D) -> bool: return not node.visible) \
				and wrong_token.get("status") == "failed" and unsettled.get("token") == token)
			var settled: Dictionary = backend.call("settle_attachment_owner_loss", source, 2, token)
			var restored: Dictionary = backend.call("installed_snapshot", source)
			diagnostics["attachmentOwnerLoss:"+mode] = {"afterLoss":after_loss,"settled":settled,"restored":restored}
			_check("attachment_%s_loss_settles_with_exact_cleanup_proof" % mode, \
				settled.get("status") == "cancelled" and settled.get("sourceId") == source \
				and int(settled.get("generation", -1)) == 2 and settled.get("token") == token \
				and bool(settled.get("ownershipReleased", false)) and bool(settled.get("candidateQuiesced", false)) \
				and bool(settled.get("previousRestored", false)) and restored.get("status") == "ready" \
				and int(restored.get("generation", -1)) == 1)
			if mode == "candidate_pivot":
				var surviving_frame := _attachment_legacy_visuals([next.bodies[0]], [])[0]
				var surviving_suppression: Dictionary = backend.call("legacy_visual_state", surviving_frame.get_instance_id())
				diagnostics["attachmentSurvivingFixedLegacy"] = {"claim":surviving_suppression,"visible":surviving_frame.visible}
				_check("attachment_lost_replacement_pivot_retains_surviving_fixed_legacy", \
					surviving_suppression.get("status") == "retained_suppressed" \
					and surviving_suppression.get("role") == "suppressed" and not surviving_frame.visible)
			backend.call("release_packet", source, 1)
		for owners: Dictionary in [old, next]:
			for body: Variant in owners.bodies:
				if is_instance_valid(body): body.queue_free()
		chunk.queue_free()
		await process_frame
		await process_frame
	# Losing a staged owner leaves an explicit abort proof until the caller reads it.
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	scene.add_child(chunk)
	var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
	var backend: Node = attached.get("backend")
	var owners := _make_attachment_test_owners(scene)
	var source := "native-contract:staged-owner-loss"
	_prepare_attachment_packet(backend, source, 1, owners.bodies, owners.pivots, owners.neutral, 1)
	owners.pivots[0].free()
	var aborted: Dictionary = backend.call("abort_packet", source, 1)
	_check("attachment_staged_owner_loss_retains_explicit_abort_proof", aborted.get("status") == "aborted" \
		and aborted.get("sourceId") == source and int(aborted.get("generation", -1)) == 1 \
		and bool(aborted.get("ownershipReleased", false)) and bool(aborted.get("candidateQuiesced", false)))
	for body: Node3D in owners.bodies: body.queue_free()
	chunk.queue_free()
	await process_frame


func _test_attachment_suppression_transfer(scene: Node3D) -> void:
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	scene.add_child(chunk)
	var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
	var backend: Node = attached.get("backend")
	var old := _make_attachment_test_owners(scene)
	var next := _make_attachment_test_owners(scene)
	var third := _make_attachment_test_owners(scene)
	var next_visuals := _attachment_legacy_visuals(next.bodies, next.pivots)
	next_visuals[0].visible = false
	var originals: Dictionary = {}
	for owners: Dictionary in [old, next, third]:
		for visual: GeometryInstance3D in _attachment_legacy_visuals(owners.bodies, owners.pivots):
			originals[visual.get_instance_id()] = visual.visible
	var source := "native-contract:suppression-transfer"
	_prepare_attachment_packet(backend, source, 1, old.bodies, old.pivots, old.neutral)
	backend.call("commit_packet", source, 1, false)
	_prepare_attachment_packet(backend, source, 2, next.bodies, next.pivots, next.neutral)
	var pending: Dictionary = backend.call("commit_packet", source, 2, true)
	var rollback: Dictionary = backend.call("rollback_presentation", source, 2, String(pending.get("token", "")))
	var suppressed: Dictionary = backend.call("legacy_visual_state", next_visuals[1].get_instance_id())
	var suppressed_restore: Dictionary = backend.call("restore_legacy_for_visual", next_visuals[1].get_instance_id())
	var old_installed: Dictionary = backend.call("installed_snapshot", source)
	_check("attachment_different_incarnation_rollback_retains_hidden_suppression", \
		rollback.get("status") == "rolled_back" and old_installed.get("status") == "ready" \
		and int(old_installed.get("generation", -1)) == 1 \
		and suppressed.get("status") == "retained_suppressed" and suppressed.get("role") == "suppressed" \
		and suppressed_restore.get("status") == "retained_suppressed" \
		and next_visuals.all(func(visual: GeometryInstance3D) -> bool: return not visual.visible))
	await process_frame
	await process_frame
	var detached_id: int = next.bodies[0].get_instance_id()
	scene.remove_child(next.bodies[0])
	_prepare_attachment_packet(backend, source, 3, third.bodies, third.pivots, third.neutral)
	var third_pending: Dictionary = backend.call("commit_packet", source, 3, true)
	var retained_during_next: Dictionary = backend.call("legacy_visual_state", next_visuals[1].get_instance_id())
	var third_accepted: Dictionary = backend.call("finalize_presentation", source, 3, String(third_pending.get("token", "")))
	var retained_after_next: Dictionary = backend.call("legacy_visual_state", next_visuals[1].get_instance_id())
	scene.add_child(next.bodies[0])
	var detached_false_claim: Dictionary = backend.call("legacy_visual_state", next_visuals[0].get_instance_id())
	var detached_true_claim: Dictionary = backend.call("legacy_visual_state", next_visuals[2].get_instance_id())
	_check("attachment_same_id_detach_readd_preserves_suppression_claims", \
		next.bodies[0].get_instance_id() == detached_id \
		and detached_false_claim.get("status") == "retained_suppressed" \
		and detached_true_claim.get("status") == "retained_suppressed" \
		and not next_visuals[0].visible and not next_visuals[2].visible)
	_check("attachment_suppression_transfers_through_next_candidate_ack", \
		third_accepted.get("status") == "ready" \
		and retained_during_next.get("status") == "retained_suppressed" \
		and retained_after_next.get("status") == "retained_suppressed" \
		and next_visuals.all(func(visual: GeometryInstance3D) -> bool: return not visual.visible))
	var surviving_old_frame := _attachment_legacy_visuals([old.bodies[1]], [old.pivots[1]])[0]
	old.bodies[0].free()
	old.pivots[1].free()
	var after_suppressed_exit: Dictionary = backend.call("installed_snapshot", source)
	var surviving_claim: Dictionary = backend.call("legacy_visual_state", surviving_old_frame.get_instance_id())
	_check("attachment_suppressed_owner_exit_preserves_current_packet_and_surviving_claim", \
		after_suppressed_exit.get("status") == "ready" and int(after_suppressed_exit.get("generation", -1)) == 3 \
		and surviving_claim.get("status") == "retained_suppressed" and not surviving_old_frame.visible)
	await process_frame
	await process_frame
	_prepare_attachment_packet(backend, source, 4, next.bodies, next.pivots, next.neutral)
	var reentry: Dictionary = backend.call("commit_packet", source, 4, false)
	var reentered_claim: Dictionary = backend.call("legacy_visual_state", next_visuals[1].get_instance_id())
	_check("attachment_suppressed_incarnation_reentry_becomes_geometry_owner", reentry.get("status") == "ready" \
		and reentered_claim.get("status") == "installed" and reentered_claim.get("role") == "installed")
	backend.call("release_packet", source, 4)
	var originals_restored := true
	for id: int in originals:
		var visual := instance_from_id(id) as GeometryInstance3D
		if visual != null: originals_restored = originals_restored and visual.visible == bool(originals[id])
	var native_hidden := true
	for owners: Dictionary in [old, next, third]:
		var live_pivots: Array[Node3D] = []
		for pivot: Variant in owners.pivots:
			if is_instance_valid(pivot): live_pivots.append(pivot)
		native_hidden = native_hidden and _attachment_children(live_pivots).all(func(node: Node3D) -> bool: return not node.visible)
	_check("attachment_final_withdraw_restores_all_claims_with_original_visibility", originals_restored and native_hidden)
	_check("attachment_same_id_detach_reentry_restores_original_true_and_false", \
		next.bodies[0].get_instance_id() == detached_id and not next_visuals[0].visible and next_visuals[2].visible)
	var false_receipt: Dictionary = next_visuals[0].get_meta("section_attachment_legacy_restoration_receipt", {})
	var true_receipt: Dictionary = next_visuals[2].get_meta("section_attachment_legacy_restoration_receipt", {})
	_check("attachment_final_restore_receipts_bind_exact_true_and_false_operations", \
		false_receipt.is_read_only() and true_receipt.is_read_only() \
		and int(false_receipt.get("visualInstanceId", 0)) == next_visuals[0].get_instance_id() \
		and int(true_receipt.get("visualInstanceId", 0)) == next_visuals[2].get_instance_id() \
		and int(false_receipt.get("bodyInstanceId", 0)) == next.bodies[0].get_instance_id() \
		and int(false_receipt.get("parentInstanceId", 0)) == next_visuals[0].get_parent().get_instance_id() \
		and int(true_receipt.get("parentInstanceId", 0)) == next_visuals[2].get_parent().get_instance_id() \
		and int(false_receipt.get("publisherInstanceId", 0)) == scene.get_instance_id() \
		and int(false_receipt.get("publicationEpoch", -1)) == 17 \
		and false_receipt.get("sourceRevision") == "door-source-0" \
		and not bool(false_receipt.get("originalVisible", true)) and bool(true_receipt.get("originalVisible", false)))
	for owners: Dictionary in [old, next, third]:
		for body: Variant in owners.bodies:
			if is_instance_valid(body): body.queue_free()
	chunk.queue_free()
	await process_frame
	await process_frame


func _test_attachment_provider_first_cancellation(scene: Node3D) -> void:
	for mode: String in ["revision", "pivot"]:
		var chunk := Node3D.new()
		chunk.name = "Chunk_0_0"
		scene.add_child(chunk)
		var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
		var backend: Node = attached.get("backend")
		var old := _make_attachment_test_owners(scene)
		var next := _make_attachment_test_owners(scene)
		var source := "native-contract:provider-first-" + mode
		_prepare_attachment_packet(backend, source, 1, old.bodies, old.pivots, old.neutral)
		backend.call("commit_packet", source, 1, false)
		_prepare_attachment_packet(backend, source, 2, next.bodies, next.pivots, next.neutral)
		var pending: Dictionary = backend.call("commit_packet", source, 2, true)
		var token := String(pending.get("token", ""))
		var frame := _attachment_legacy_visuals([next.bodies[0]], [next.pivots[0]])[0]
		if mode == "revision": next.bodies[0].set_meta("section_attachment_publication_epoch", 18)
		else: next.pivots[0].free()
		var provider_restore: Dictionary = backend.call("restore_legacy_for_visual", frame.get_instance_id())
		var wrong: Dictionary = backend.call("settle_presentation_cancellation", source, 2, token + ":wrong")
		var blocked: Dictionary = backend.call("begin_packet", source, OWNER_CELL, 3, "revision-next", "digest-next",
			Transform3D.IDENTITY, 0, 0)
		var settled: Dictionary = backend.call("settle_presentation_cancellation", source, 2, token)
		_check("attachment_provider_first_%s_withdrawal_has_exact_cancellation_proof" % mode, \
			provider_restore.get("status") == "restored" and wrong.get("status") == "failed" \
			and blocked.get("status") == "backpressure" \
			and settled.get("status") == "cancelled" and settled.get("sourceId") == source \
			and int(settled.get("generation", -1)) == 2 and settled.get("presentationToken") == token \
			and bool(settled.get("ownershipReleased", false)) and bool(settled.get("candidateQuiesced", false)) \
			and bool(settled.get("previousUnavailable", false)) and not bool(settled.get("previousRestored", true)))
		var admitted: Dictionary = backend.call("begin_packet", source, OWNER_CELL, 3, "revision-next", "digest-next",
			Transform3D.IDENTITY, 0, 0)
		_check("attachment_provider_first_%s_admission_waits_for_ack" % mode, admitted.get("status") == "ready_to_append")
		backend.call("abort_packet", source, 3)
		for owners: Dictionary in [old, next]:
			for body: Variant in owners.bodies:
				if is_instance_valid(body): body.queue_free()
		chunk.queue_free()
		await process_frame
		await process_frame
	# Native object remains callable after EXIT_TREE and preserves its exact proof.
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	scene.add_child(chunk)
	var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
	var backend: Node = attached.get("backend")
	var owners := _make_attachment_test_owners(scene)
	var source := "native-contract:backend-detach-cancellation"
	_prepare_attachment_packet(backend, source, 1, owners.bodies, owners.pivots, owners.neutral)
	var pending: Dictionary = backend.call("commit_packet", source, 1, true)
	chunk.remove_child(backend)
	var settled: Dictionary = backend.call("settle_presentation_cancellation", source, 1, String(pending.get("token", "")))
	_check("attachment_backend_detach_retains_cancellation_until_session_ack", \
		settled.get("status") == "cancelled" and settled.get("presentationToken") == pending.get("token") \
		and bool(settled.get("candidateQuiesced", false)) and bool(settled.get("ownershipReleased", false)))
	backend.free()
	for body: Node3D in owners.bodies: body.queue_free()
	chunk.queue_free()
	await process_frame


func _test_attachment_claim_capacity(scene: Node3D) -> void:
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	scene.add_child(chunk)
	var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
	var backend: Node = attached.get("backend")
	var limits: Dictionary = backend.call("metrics")
	var capacity := int(limits.get("maxLegacyVisualClaimsPerPacket", 0))
	if capacity <= 1 or capacity > 16384:
		_check("attachment_claim_capacity_is_explicit_and_bounded", false)
		chunk.queue_free()
		return
	_check("attachment_claim_capacity_is_explicit_and_bounded", true)
	var body := StaticBody3D.new()
	scene.add_child(body)
	body.set_meta("section_attachment_source_revision", "capacity-revision")
	body.set_meta("section_attachment_publisher_instance_id", scene.get_instance_id())
	body.set_meta("section_attachment_publication_epoch", 1)
	var pivot := Node3D.new()
	body.add_child(pivot)
	var mesh := BoxMesh.new()
	var legacy: Array[GeometryInstance3D] = []
	for index in range(capacity + 1):
		var visual := MeshInstance3D.new()
		visual.mesh = mesh
		pivot.add_child(visual)
		legacy.append(visual)
	legacy[1].visible = false
	var source := "native-contract:suppression-capacity"
	var first_claims: Array[GeometryInstance3D] = []
	for index in range(capacity): first_claims.append(legacy[index])
	_prepare_attachment_capacity_packet(backend, source, 1, body, pivot, first_claims)
	var first: Dictionary = backend.call("commit_packet", source, 1, false)
	var replacement_claims: Array[GeometryInstance3D] = [legacy[0], legacy[capacity]]
	_prepare_attachment_capacity_packet(backend, source, 2, body, pivot, replacement_claims)
	var rejected: Dictionary = backend.call("commit_packet", source, 2, true)
	var retained: Dictionary = backend.call("installed_snapshot", source)
	_check("attachment_suppression_capacity_backpressure_preserves_live_claims_and_visibility", \
		first.get("status") == "ready" and rejected.get("status") == "backpressure" \
		and rejected.get("reason") == "legacy_visual_retention_capacity" \
		and retained.get("status") == "ready" and int(retained.get("generation", -1)) == 1 \
		and first_claims.all(func(visual: GeometryInstance3D) -> bool: return not visual.visible) \
		and legacy[capacity].visible)
	backend.call("abort_packet", source, 2)
	legacy[capacity - 1].free()
	_prepare_attachment_capacity_packet(backend, source, 3, body, pivot, replacement_claims)
	var reentry: Dictionary = backend.call("commit_packet", source, 3, false)
	backend.call("release_packet", source, 3)
	var restored := true
	for index in range(legacy.size()):
		if is_instance_valid(legacy[index]): restored = restored and legacy[index].visible == (index != 1)
	_check("attachment_capacity_reentry_prunes_only_dead_claim_and_restores_original_visibility", \
		reentry.get("status") == "ready" and restored)
	body.queue_free()
	chunk.queue_free()
	await process_frame
	await process_frame


func _prepare_attachment_capacity_packet(backend: Node, source: String, generation: int,
		body: Node3D, pivot: Node3D, legacy: Array[GeometryInstance3D]) -> Dictionary:
	var begun: Dictionary = backend.call("begin_packet", source, OWNER_CELL, generation,
		"capacity-section", "capacity-digest-%d" % generation, Transform3D.IDENTITY, 1, 1)
	if begun.get("status") != "ready_to_append": return begun
	var motion := {"kind":"swing", "closedParentToBody":pivot.transform,
		"swing":1.2, "raiseOffset":Vector3.ZERO}
	var registered: Dictionary = backend.call("register_packet_attachment", source, generation,
		"capacity", pivot, body, pivot.global_transform, motion, legacy)
	if registered.get("status") != "registered": return registered
	var mesh := BoxMesh.new()
	var identity: Dictionary = StaticMeshFingerprint.inspect(mesh)
	var buffer: PackedFloat32Array = InstanceBuffer.encode(Transform3D.IDENTITY, Color.WHITE)
	var appended: Dictionary = backend.call("append_batch_in_attachment", source, generation,
		"capacity", mesh, String(identity.get("contentDigest", "")), StandardMaterial3D.new(), buffer,
		mesh.get_aabb(), "structural", true, 0.0, 0.0, "opaque", "capacity")
	if appended.get("status") != "accepted": return appended
	return backend.call("advance_packet", source, generation, 1)


func _attachment_children(pivots: Array[Node3D]) -> Array[Node3D]:
	var result: Array[Node3D] = []
	for pivot: Variant in pivots:
		if not is_instance_valid(pivot): continue
		for child: Node in pivot.get_children():
			if child is Node3D and bool(child.get_meta("section_attachment_native_root", false)):
				result.append(child)
	return result


func _attachment_legacy_visuals(bodies: Array[Node3D], pivots: Array[Node3D]) -> Array[GeometryInstance3D]:
	var result: Array[GeometryInstance3D] = []
	for parent: Variant in bodies + pivots:
		if not is_instance_valid(parent): continue
		for child: Node in parent.get_children():
			if child is GeometryInstance3D: result.append(child)
	return result


func _prepare_attachment_packet(backend: Node, source: String, generation: int,
		bodies: Array[Node3D], pivots: Array[Node3D], neutral: Array[Transform3D], upload_units := 3) -> Dictionary:
	var begun: Dictionary = backend.call("begin_packet", source, OWNER_CELL, generation,
		"aggregate-section-revision", "attachment-digest-%d" % generation, Transform3D.IDENTITY, 3, 3)
	if begun.get("status") != "ready_to_append": return begun
	for index in range(2):
		var motion := {"kind":"swing" if index == 0 else "raise",
			"closedParentToBody":bodies[index].global_transform.affine_inverse() * neutral[index],
			"swing":1.2 if index == 0 else 0.0,
			"raiseOffset":Vector3.ZERO if index == 0 else Vector3(0.0, 3.0, 0.0)}
		var legacy: Array[GeometryInstance3D] = _attachment_legacy_visuals([bodies[index]], [pivots[index]])
		var registered: Dictionary = backend.call("register_packet_attachment", source, generation,
			"swing" if index == 0 else "raise", pivots[index], bodies[index], neutral[index], motion, legacy)
		if registered.get("status") != "registered": return registered
	var mesh := BoxMesh.new()
	var fingerprint: Dictionary = StaticMeshFingerprint.inspect(mesh)
	var material := StandardMaterial3D.new()
	var buffer: PackedFloat32Array = InstanceBuffer.encode(Transform3D.IDENTITY, Color.WHITE)
	for index in range(3):
		var appended: Dictionary = backend.call("append_batch_in_attachment", source, generation,
			"attachment-batch-%d" % index, mesh, String(fingerprint.get("contentDigest", "")), material,
			buffer, mesh.get_aabb(), "structural", true, 0.0, 0.0, "opaque",
			"" if index == 0 else "swing",
			index != 2)
		if appended.get("status") != "accepted": return appended
	return backend.call("advance_packet", source, generation, upload_units)


func _install(backend: Node, generation: int) -> bool:
	var begun: Dictionary=backend.call("begin_packet",SOURCE_ID,OWNER_CELL,generation,SOURCE_REVISION,
		PACKET_DIGEST,Transform3D.IDENTITY,1,1)
	if begun.get("status")!="ready_to_append": return false
	var material := StandardMaterial3D.new()
	var mesh := BoxMesh.new()
	var mesh_identity: Dictionary=StaticMeshFingerprint.inspect(mesh)
	if mesh_identity.get("status")!="ready": return false
	var buffer: PackedFloat32Array=InstanceBuffer.encode(Transform3D.IDENTITY,Color.WHITE)
	var appended: Dictionary=backend.call("append_batch",SOURCE_ID,generation,"batch-0",mesh,
		String(mesh_identity.contentDigest),material,
		buffer,AABB(Vector3(-0.5,-0.5,-0.5),Vector3.ONE),"structural",true,240.0,18.0)
	if appended.get("status")!="accepted": return false
	var upload: Dictionary=backend.call("advance_packet",SOURCE_ID,generation,1)
	if upload.get("status")!="ready_to_commit": return false
	var committed: Dictionary=backend.call("commit_packet",SOURCE_ID,generation)
	return committed.get("status")=="ready" and backend.call("receipt_installed",SOURCE_ID,generation,
		SOURCE_REVISION,PACKET_DIGEST)


func _reject_mutated_mesh_after_begin(backend: Node) -> bool:
	const source_id := "native-contract:mesh-mutation"
	var mesh := BoxMesh.new()
	var identity: Dictionary=StaticMeshFingerprint.inspect(mesh)
	if identity.get("status")!="ready": return false
	var generation:=1
	var begun: Dictionary=backend.call("begin_packet",source_id,OWNER_CELL,generation,
		"mesh-revision",PACKET_DIGEST,Transform3D.IDENTITY,1,1)
	if begun.get("status")!="ready_to_append": return false
	mesh.size=Vector3(2.0,1.0,1.0)
	var buffer: PackedFloat32Array=InstanceBuffer.encode(Transform3D.IDENTITY,Color.WHITE)
	var appended: Dictionary=backend.call("append_batch",source_id,generation,"batch-mutated",mesh,
		String(identity.contentDigest),StandardMaterial3D.new(),buffer,
		AABB(Vector3(-1.0,-0.5,-0.5),Vector3(2.0,1.0,1.0)),"structural",true,240.0,18.0)
	backend.call("abort_packet",source_id,generation)
	return appended.get("status")=="failed" \
		and String(appended.get("reason",""))=="mesh_content_identity_mismatch"


func _has_installed_mesh(root_node: Node, expected: Mesh) -> bool:
	if root_node is MultiMeshInstance3D:
		var instance := root_node as MultiMeshInstance3D
		if instance.multimesh != null and instance.multimesh.mesh != expected \
				and instance.multimesh.mesh.get_surface_count()==expected.get_surface_count() \
				and instance.multimesh.mesh.surface_get_primitive_type(0)==expected.surface_get_primitive_type(0) \
				and instance.multimesh.mesh.surface_get_arrays(0)==expected.surface_get_arrays(0) \
				and instance.is_visible_in_tree(): return true
	for child: Node in root_node.get_children():
		if _has_installed_mesh(child,expected): return true
	return false


func _mesh_payload_bytes(mesh: Mesh) -> int:
	var total:=0
	for surface_index in range(mesh.get_surface_count()):
		for array_value: Variant in mesh.surface_get_arrays(surface_index):
			if array_value is PackedByteArray or array_value is PackedInt32Array \
					or array_value is PackedInt64Array or array_value is PackedFloat32Array \
					or array_value is PackedFloat64Array or array_value is PackedVector2Array \
					or array_value is PackedVector3Array or array_value is PackedVector4Array \
					or array_value is PackedColorArray:
				total+=array_value.to_byte_array().size()
			elif array_value != null:
				return -1
	return total


func _multimesh_color(multimesh: MultiMesh) -> Color:
	var buffer: PackedFloat32Array=multimesh.get_buffer()
	if buffer.size()<InstanceAttributes.FLOATS_PER_INSTANCE:
		return Color.TRANSPARENT
	return Color(buffer[InstanceAttributes.COLOR_OFFSET],buffer[InstanceAttributes.COLOR_OFFSET+1],
		buffer[InstanceAttributes.COLOR_OFFSET+2],buffer[InstanceAttributes.COLOR_OFFSET+3])


func _multimesh_custom(multimesh: MultiMesh) -> Color:
	var buffer: PackedFloat32Array=multimesh.get_buffer()
	if buffer.size()<InstanceAttributes.FLOATS_PER_INSTANCE:
		return Color.TRANSPARENT
	return Color(buffer[InstanceAttributes.CUSTOM_DATA_OFFSET],buffer[InstanceAttributes.CUSTOM_DATA_OFFSET+1],
		buffer[InstanceAttributes.CUSTOM_DATA_OFFSET+2],buffer[InstanceAttributes.CUSTOM_DATA_OFFSET+3])


func _make_chunk(scene: SceneRegistry, cell: Vector2i) -> Node3D:
	var chunk := Node3D.new()
	chunk.name="Chunk_%d_%d" % [cell.x,cell.y]
	chunk.position=Vector3(cell.x*VoxelTerrainRuntime.GAME_CHUNK_SIZE*1.35,0.0,
		cell.y*VoxelTerrainRuntime.GAME_CHUNK_SIZE*1.35)
	scene.add_child(chunk)
	scene.chunks[cell]=chunk
	return chunk


## Real RenderingServer callback; never inject a synthetic frame acknowledgement.
## A headed service contract still does not prove gameplay or visible pixels.
func _advance_presented_session(session: RefCounted, units: int, pov := -1) -> Dictionary:
	var result: Dictionary = session.advance(units,pov)
	# Drive the bounded append/upload/commit stages before waiting for a real frame.
	for _attempt in range(16):
		if result.get("status") != "pending": break
		result = session.advance(units,pov)
	if result.get("status") == "pending_presentation":
		await process_frame
		result = session.advance(units,pov)
		if result.get("status") == "pending_presentation" and bool(result.get("frameDrawn",false)):
			result = session.finalize_presentation(String(result.get("presentationToken","")))
	return result


func _finish(passed: bool, reason: String) -> void:
	var report := {"schema":"native_chunk_render_packet_contract/v1",
		"evidence":"native_building_packet_flush_and_replay; world-owned coordinator installs a census-checked candidate through the native backend and rejects incomplete replacement census; section manifest binds actual ArrayMesh content digest and rejects mismatched resource binding; native upload owns a content-preserving mesh snapshot with CPU mesh-array accounting; canceled replacement retains old root through replacement; no generated-world/live-gameplay acceptance",
		"checks":checks,"diagnostics":diagnostics,"passed":passed,"reason":reason}
	var path := OS.get_environment("NATIVE_CHUNK_PACKET_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path,FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report,"\t"))
			file.close()
	print("NATIVE CHUNK PACKET ",JSON.stringify(report))
	quit(0 if passed else 1)

extends SceneTree
## Native chunk packet lifecycle contract; no game scene or mock backend.
const PacketOwner = preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstanceBuffer = preload("res://scripts/buildings/BuildingInstanceBuffer.gd")
const BuildingPublisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const VoxelTerrainRuntime = preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
const StaticRenderSectionGrid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const StaticSectionSnapshotBuilder = preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const StaticSectionInstallSession = preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const StaticContributorLedger = preload("res://scripts/world/PreparedStaticContributorLedger.gd")
const WorldStaticSectionCoordinator = preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const OWNER_CELL := Vector2i(0,0)
const SOURCE_ID := "native-contract:wall"
const SOURCE_REVISION := "revision-1"
const PACKET_DIGEST := "digest-contract-v1"
var checks: Dictionary = {}
var diagnostics: Dictionary = {}

class SceneRegistry extends Node3D:
	var chunks: Dictionary={}

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

class FixturePart extends RefCounted:
	var id := "native-wall"

func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, value: bool) -> void:
	checks[name]=value


func _run() -> void:
	if not ClassDB.class_exists("ChunkRenderPacketBackend"):
		_finish(false,"native_chunk_render_packet_backend_missing")
		return
	var scene := SceneRegistry.new()
	scene.name="NativeChunkPacketContractScene"
	root.add_child(scene)
	current_scene=scene
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
	var section_mesh := BoxMesh.new()
	section_mesh.size=Vector3.ONE
	var section_buffer: Array[float]=[]
	for value: float in InstanceBuffer.encode(Transform3D(Basis.IDENTITY,Vector3(0.5,0.5,0.5)),Color(0.3,0.7,0.4,1.0)):
		section_buffer.append(value)
	section_buffer.make_read_only()
	var section_bounds:=AABB(Vector3.ZERO,Vector3.ONE)
	var section_material_key:="native-section-material"
	var section_tier:="structural"
	var section_resource_mesh_key:="unit-box-v1"
	var section_pipeline:="native-section-v1"
	var section_segment_declaration: Dictionary={"segmentId":"native-section-source-segment",
		"materialKey":section_material_key,"renderTier":section_tier,
		"meshKey":section_resource_mesh_key,"meshLocalBounds":section_bounds,
		"pipelineRevision":section_pipeline,"renderLayer":"opaque",
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
		"sourceId":"native-section-source","sourceRevision":"native-section-rev-1",
		"segmentId":"native-section-source-segment","buffer":section_buffer,
		"instanceCount":1,"materialKey":section_material_key,"renderTier":section_tier,
		"meshKey":section_resource_mesh_key,"meshLocalBounds":section_bounds,
		"pipelineRevision":section_pipeline,"renderLayer":"opaque",
		"translucentSortPolicy":"none","castShadows":true,
		"visibilityRangeEnd":240.0,"fadeMargin":18.0}
	section_input.make_read_only()
	var section_admission: Dictionary=section_ledger.accept_prepared_segment(
		"native-section-boundary",section_input)
	var section_revisions: Dictionary={"native-section-part":"native-section-rev-1"}
	section_revisions.make_read_only()
	var section_prepared: Dictionary=section_ledger.prepare_boundary(
		"native-section-boundary",section_revisions,"native-section-contract-world",1)
	var section_candidate: Dictionary=section_prepared.replacements[0]
	var section_snapshot: Dictionary=section_candidate.snapshot
	var section_bindings_started: Dictionary=PacketOwner.begin_static_section_install(section_candidate,
		{"native-section-material":section_material},{"unit-box-v1":section_mesh})
	var section_session: Variant=section_bindings_started.get("session")
	var section_result: Dictionary={"status":section_bindings_started.get("status","failed")}
	var section_turns:=0
	while section_session is RefCounted and section_session.state not in ["installed","failed","cancelled"] \
			and section_turns<64:
		section_result=section_session.advance(4)
		section_turns+=1
	var section_slot_id:=StaticSectionInstallSession.slot_id("native-section-contract-world",Vector3i.ZERO)
	var section_backend_snapshot: Dictionary=backend.call("installed_snapshot",section_slot_id)
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
		and backend.call("receipt_installed",section_slot_id,1,
			"native-section-contract-world:1",String(section_candidate.contentManifestDigest)) \
		and section_backend_snapshot.get("status")=="ready" \
		and int(section_backend_snapshot.get("expectedBatchCount",0))==1 \
		and section_promoted.get("status")=="committed")
	var coordinator := WorldStaticSectionCoordinator.new()
	var coordinator_world := "native-section-coordinator-contract-world"
	var coordinator_source_id := "coordinator-building-source"
	var coordinator_part_id := "coordinator-building-part"
	var coordinator_revision := "coordinator-rev-1"
	var coordinator_boundary_id := "coordinator-boundary-1"
	var coordinator_configured: Dictionary=coordinator.configure(coordinator_world)
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
	var coordinator_revisions: Dictionary={coordinator_part_id:coordinator_revision}
	coordinator_revisions.make_read_only()
	var coordinator_contributors: Array[String]=[coordinator_part_id]
	coordinator_contributors.make_read_only()
	var coordinator_census: Dictionary={Vector3i.ZERO:coordinator_contributors}
	coordinator_census.make_read_only()
	var coordinator_materials: Dictionary={section_material_key:section_material}
	coordinator_materials.make_read_only()
	var coordinator_meshes: Dictionary={section_resource_mesh_key:section_mesh}
	coordinator_meshes.make_read_only()
	var coordinator_install: Dictionary={"status":"pending"}
	var coordinator_turns:=0
	while coordinator_turns<64 and coordinator_install.get("status") not in ["committed","failed","unsupported"]:
		coordinator_install=coordinator.advance_boundary(coordinator_revisions,
			coordinator_census,coordinator_materials,coordinator_meshes,4)
		coordinator_turns+=1
	var coordinator_slot_id:=StaticSectionInstallSession.slot_id(coordinator_world,Vector3i.ZERO)
	var coordinator_backend_snapshot: Dictionary=backend.call("installed_snapshot",coordinator_slot_id)
	diagnostics["worldCoordinatorInstall"]={"configured":coordinator_configured,
		"enqueued":coordinator_enqueued,"segmentAdmitted":coordinator_segment_admitted,
		"lastAdvance":coordinator_install,"turns":coordinator_turns,
		"status":coordinator.status(),"backend":coordinator_backend_snapshot}
	_check("world_coordinator_candidate_installs_and_promotes_through_native_renderer",
		coordinator_configured.get("status")=="ready" \
		and coordinator_enqueued.get("status")=="queued" \
		and coordinator_segment_admitted.get("status")=="queued" \
		and coordinator_install.get("status")=="committed" \
		and coordinator_backend_snapshot.get("status")=="ready" \
		and int(coordinator_backend_snapshot.get("generation",0))==1 \
		and coordinator.status().get("committedSourcePartIds",[]).has(coordinator_part_id) \
		and backend.call("receipt_installed",coordinator_slot_id,1,
			"%s:1" % coordinator_world,String(coordinator_backend_snapshot.get("packetDigest",""))))
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
	var stale_revisions: Dictionary={coordinator_part_id:"coordinator-rev-2"}
	stale_revisions.make_read_only()
	var incomplete_contributors: Array[String]=[coordinator_part_id,"undiscovered-part"]
	incomplete_contributors.make_read_only()
	var incomplete_census: Dictionary={Vector3i.ZERO:incomplete_contributors}
	incomplete_census.make_read_only()
	var incomplete_result: Dictionary=coordinator.advance_boundary(stale_revisions,
		incomplete_census,coordinator_materials,coordinator_meshes,4)
	var retained_coordinator_slot: Dictionary=backend.call("installed_snapshot",coordinator_slot_id)
	diagnostics["worldCoordinatorIncompleteCensus"]={"result":incomplete_result,
		"status":coordinator.status(),"backend":retained_coordinator_slot}
	_check("world_coordinator_rejects_incomplete_source_census_without_replacing_slot",
		incomplete_result.get("status")=="failed" \
		and String(incomplete_result.get("reason","" )).begins_with("section_candidate_contributor_census_mismatch:") \
		and int(retained_coordinator_slot.get("generation",0))==1 \
		and coordinator.status().get("committedSourcePartIds",[]).has(coordinator_part_id))
	var section_root_id:=int(section_backend_snapshot.get("rootInstanceId",0))
	var cancelled_candidate: Dictionary=section_candidate.duplicate(false)
	cancelled_candidate["generation"]=2
	cancelled_candidate["contentManifestDigest"]=StaticSectionSnapshotBuilder._snapshot_digest(
		section_snapshot,String(cancelled_candidate.worldId),int(cancelled_candidate.generation),cancelled_candidate.sectionKey)
	cancelled_candidate.make_read_only()
	var cancelled_started: Dictionary=PacketOwner.begin_static_section_install(cancelled_candidate,
		{"native-section-material":section_material},{"unit-box-v1":section_mesh})
	var cancelled_session: Variant=cancelled_started.get("session")
	var cancel_receipt: Dictionary=cancelled_session.cancel() if cancelled_session is RefCounted else {"status":"missing"}
	var retained_after_cancel: Dictionary=backend.call("installed_snapshot",section_slot_id)
	_check("cancelled_section_replacement_keeps_previous_native_root_visible",
		cancel_receipt.get("status")=="cancelled" \
		and retained_after_cancel.get("status")=="ready" \
		and int(retained_after_cancel.get("generation",0))==1 \
		and int(retained_after_cancel.get("rootInstanceId",0))==section_root_id)
	var stale_section_start: Dictionary=PacketOwner.begin_static_section_install(section_candidate,
		{"native-section-material":section_material},{"unit-box-v1":section_mesh})
	_check("native_section_slot_rejects_reused_generation",
		stale_section_start.get("status")=="failed" \
		and stale_section_start.get("reason")=="stale_section_slot_generation")
	var owner_swap_started: Dictionary=PacketOwner.begin_static_section_install(cancelled_candidate,
		{"native-section-material":section_material},{"unit-box-v1":section_mesh})
	var owner_swap_session: Variant=owner_swap_started.get("session")
	var previous_registry_chunk: Variant=scene.chunks[OWNER_CELL]
	var replacement_registry_chunk:=Node3D.new()
	replacement_registry_chunk.name="Chunk_0_0"
	scene.chunks[OWNER_CELL]=replacement_registry_chunk
	var owner_swap_result: Dictionary=owner_swap_session.advance(4) if owner_swap_session is RefCounted \
		else {"status":"missing"}
	scene.chunks[OWNER_CELL]=previous_registry_chunk
	replacement_registry_chunk.free()
	_check("section_install_revalidates_registry_owner_before_upload",
		owner_swap_started.get("status")=="ready" \
		and owner_swap_result.get("status")=="failed" \
		and owner_swap_result.get("reason")=="section_install_owner_replaced" \
		and int(backend.call("installed_snapshot",section_slot_id).get("generation",0))==1)
	var cross_chunk_snapshot: Dictionary=section_snapshot.duplicate(false)
	var cross_chunk_dependencies: Array[Vector2i]=[OWNER_CELL,Vector2i(1,0)]
	cross_chunk_dependencies.make_read_only()
	cross_chunk_snapshot["streamChunkDependencies"]=cross_chunk_dependencies
	cross_chunk_snapshot.make_read_only()
	var cross_chunk_candidate: Dictionary=section_candidate.duplicate(false)
	cross_chunk_candidate["generation"]=2
	cross_chunk_candidate["snapshot"]=cross_chunk_snapshot
	cross_chunk_candidate["contentManifestDigest"]=StaticSectionSnapshotBuilder._snapshot_digest(
		cross_chunk_snapshot,String(cross_chunk_candidate.worldId),int(cross_chunk_candidate.generation),cross_chunk_candidate.sectionKey)
	cross_chunk_candidate.make_read_only()
	var cross_chunk_start: Dictionary=PacketOwner.begin_static_section_install(cross_chunk_candidate,
		{"native-section-material":section_material},{"unit-box-v1":section_mesh})
	_check("section_candidate_waits_for_cross_chunk_dependency_pin",
		cross_chunk_start.get("status")=="failed" \
		and cross_chunk_start.get("reason")=="section_residency_dependency_not_pinned" \
		and int(backend.call("installed_snapshot",section_slot_id).get("generation",0))==1)
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
	publisher._record_completed_source_part(FixturePart.new())
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
	var mismatch_part:=FixturePart.new()
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
	capacity_publisher._record_completed_source_part(FixturePart.new())
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


func _install(backend: Node, generation: int) -> bool:
	var begun: Dictionary=backend.call("begin_packet",SOURCE_ID,OWNER_CELL,generation,SOURCE_REVISION,
		PACKET_DIGEST,Transform3D.IDENTITY,1,1)
	if begun.get("status")!="ready_to_append": return false
	var material := StandardMaterial3D.new()
	var mesh := BoxMesh.new()
	var buffer: PackedFloat32Array=InstanceBuffer.encode(Transform3D.IDENTITY,Color.WHITE)
	var appended: Dictionary=backend.call("append_batch",SOURCE_ID,generation,"batch-0",mesh,material,
		buffer,AABB(Vector3(-0.5,-0.5,-0.5),Vector3.ONE),"structural",true,240.0,18.0)
	if appended.get("status")!="accepted": return false
	var upload: Dictionary=backend.call("advance_packet",SOURCE_ID,generation,1)
	if upload.get("status")!="ready_to_commit": return false
	var committed: Dictionary=backend.call("commit_packet",SOURCE_ID,generation)
	return committed.get("status")=="ready" and backend.call("receipt_installed",SOURCE_ID,generation,
		SOURCE_REVISION,PACKET_DIGEST)


func _make_chunk(scene: SceneRegistry, cell: Vector2i) -> Node3D:
	var chunk := Node3D.new()
	chunk.name="Chunk_%d_%d" % [cell.x,cell.y]
	chunk.position=Vector3(cell.x*VoxelTerrainRuntime.GAME_CHUNK_SIZE*1.35,0.0,
		cell.y*VoxelTerrainRuntime.GAME_CHUNK_SIZE*1.35)
	scene.add_child(chunk)
	scene.chunks[cell]=chunk
	return chunk


func _finish(passed: bool, reason: String) -> void:
	var report := {"schema":"native_chunk_render_packet_contract/v1",
		"evidence":"native_building_packet_flush_and_replay; world-owned coordinator installs a census-checked candidate through the native backend and rejects incomplete replacement census; section cancellation retains the old root; no generated-world/live-gameplay acceptance",
		"checks":checks,"diagnostics":diagnostics,"passed":passed,"reason":reason}
	var path := OS.get_environment("NATIVE_CHUNK_PACKET_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path,FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report,"\t"))
			file.close()
	print("NATIVE CHUNK PACKET ",JSON.stringify(report))
	quit(0 if passed else 1)

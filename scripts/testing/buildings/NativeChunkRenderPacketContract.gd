extends SceneTree
## Native chunk packet lifecycle contract; no game scene or mock backend.
const PacketOwner = preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstanceBuffer = preload("res://scripts/buildings/BuildingInstanceBuffer.gd")
const BuildingPublisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const VoxelTerrainRuntime = preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
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
	var instance_transform:=Transform3D(Basis.IDENTITY,Vector3(0.5,0.5,0.5))
	var buffer: Array[float]=[]
	for value: float in InstanceBuffer.encode(instance_transform,Color.WHITE): buffer.append(value)
	buffer.make_read_only()
	var segment: Dictionary={"buffer":buffer,"bounds":AABB(Vector3.ZERO,Vector3.ONE),"instanceCount":1}
	segment.make_read_only()
	var segments: Dictionary={0:segment}
	var group: Dictionary={"material":material,"transforms":[instance_transform],"customData":[Color.WHITE],
		"renderTier":"structural","ownerCell":OWNER_CELL,"sourcePartId":"native-wall",
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
	scene.add_child(chunk)
	scene.chunks[cell]=chunk
	return chunk


func _finish(passed: bool, reason: String) -> void:
	var report := {"schema":"native_chunk_render_packet_contract/v1","evidence":"native_building_packet_flush_main_runtime_integration",
		"checks":checks,"diagnostics":diagnostics,"passed":passed,"reason":reason}
	var path := OS.get_environment("NATIVE_CHUNK_PACKET_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path,FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report,"\t"))
			file.close()
	print("NATIVE CHUNK PACKET ",JSON.stringify(report))
	quit(0 if passed else 1)

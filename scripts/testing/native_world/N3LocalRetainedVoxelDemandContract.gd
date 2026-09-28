extends SceneTree

# Service-level adapter contract only; it does not insert a VoxelTerrain block.
var failures: Array[String] = []
var observations: Array[Dictionary] = []

func check(value: bool, label: String) -> void:
	if not value:
		failures.append(label)

func source_request() -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":"atlas-1492",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
			"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,
			"worldBottomCellY":-64,"waterLevelMeters":11.1,
			"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
			"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func edit_state() -> Dictionary:
	return {"materialId":13,"biomeId":0,"solid":true,"density":1.35,
		"fluidId":0,"light":Vector2i.ZERO,
		"metadata":{"source":"terrain_edit","terrainMeshAffects":true},
		"blockId":"local-demand-edit","editReason":"local-demand-contract"}

func commit_edit(backend, cell: Vector3i, expected_revision: int, tag: String) -> Dictionary:
	return backend.commit_typed_cells({"schema":"n3-native-typed-cell-transaction/v1",
		"transactionId":"local-demand:" + tag,"expectedRevision":expected_revision,
		"operations":[{"namespace":"durable_terrain","kind":"set",
			"cell":cell,"state":edit_state()}]})

func finish() -> void:
	var path := OS.get_environment("VWB_LOCAL_DEMAND_REPORT")
	var report := {"schema":"n3-local-retained-voxel-demand-contract/v1",
		"passed":failures.is_empty(),"evidenceLevel":"real-godot-binding-service-contract",
		"productionCutover":false,"failures":failures,"observations":observations}
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report,"\t"))
	quit(0 if report.passed else 1)

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null,"native backend registered")
	if backend == null:
		finish()
		return
	check(backend.initialize(source_request()).get("status") == "ready","backend initialized")
	var initial_capacity: Dictionary = backend.status()
	check(int(initial_capacity.get("voxelDemandMaxRetainedEntries", -1)) == 16384,
		"production-scale retained capacity exposed")
	check(backend.configure_voxel_block_shadow_capacity(256).get("status") == "ready"
		and int(backend.status().get("voxelDemandMaxRetainedEntries", -1)) == 256,
		"bounded retained capacity configurable")
	check(backend.configure_voxel_block_shadow_capacity(32769).get("reason") == "capacity_out_of_bounds",
		"hard retained capacity bound enforced")
	check(backend.configure_voxel_block_shadow_capacity(16384).get("status") == "ready",
		"retained capacity restored before block demand")
	var request := {"schema":"n3-effective-voxel-block-request/v1",
		"origin":Vector3i.ZERO,"size":Vector3i.ONE * 16,"lod":0}
	check(backend.request_voxel_block_shadow(request,1,10).has("key"),"retained request admitted")
	var prepared: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		var event: Dictionary = backend.pump_voxel_block_shadow()
		if event.get("status") == "ready" and event.get("state") == "prepared":
			prepared = event
			break
		await process_frame
	check(not prepared.is_empty(),"retained block prepared")
	if prepared.is_empty():
		finish()
		return
	var distant_shaping: Dictionary = backend.shaping_requests(Vector2i(2,2))
	var shaping_requests: Array = distant_shaping.get("requests",[])
	check(not shaping_requests.is_empty(),"distant unresolved shaping candidate found")
	if not shaping_requests.is_empty():
		var candidate: Dictionary = shaping_requests[0]
		var resolution := {"region":candidate.region,
			"requestIdentity":candidate.requestIdentity,
			"workerSourceKey":candidate.workerSourceKey,
			"kind":"absent","reasonCode":"local_demand_contract_absent"}
		var shaping_receipt: Dictionary = backend.apply_shaping_resolutions([resolution])
		check(shaping_receipt.get("commitStatus") == "committed",
			"distant shaping region resolved")
		var shaping_replay: Dictionary = backend.apply_shaping_resolutions([resolution])
		check(shaping_replay.get("commitStatus") == "no_change",
			"terminal shaping replay is no change")
		var shaped_insertion: Dictionary = backend.voxel_block_shadow_insertion_receipt(
			prepared.key,int(prepared.generation),true)
		check(shaped_insertion.get("status") == "ready",
			"distant terminal resolution and replay preserve bound ready block")
		observations.append({"shapingResolution":shaping_receipt.get("commitStatus"),
			"shapingReplay":shaping_replay.get("commitStatus"),
			"insertionAfterShaping":shaped_insertion.get("status")})
	var remote: Dictionary = commit_edit(backend,Vector3i(560,0,560),0,"remote")
	check(remote.get("commitStatus") == "committed","remote durable edit committed")
	var after_remote: Dictionary = backend.encode_voxel_block_shadow(request)
	check(after_remote.get("status") == "ready"
		and after_remote.get("blockContentIdentity") == prepared.get("blockContentIdentity")
		and after_remote.get("sdf16Le") == prepared.get("sdf16Le")
		and after_remote.get("indices8") == prepared.get("indices8")
		and after_remote.get("data5_8") == prepared.get("data5_8"),
		"remote edit preserves block identity and bytes")
	var remote_receipt: Dictionary = backend.voxel_block_shadow_mesh_receipt(
		prepared.key,int(prepared.generation),true,true,true)
	check(remote_receipt.get("status") == "ready","unrelated edit preserves retained block mesh receipt")
	var local: Dictionary = commit_edit(backend,Vector3i.ZERO,1,"local")
	check(local.get("commitStatus") == "committed","local durable edit committed")
	var after_local: Dictionary = backend.encode_voxel_block_shadow(request)
	check(after_local.get("status") == "ready"
		and after_local.get("blockContentIdentity") != prepared.get("blockContentIdentity"),
		"local edit changes conservative block source identity")
	var stale_receipt: Dictionary = backend.voxel_block_shadow_mesh_receipt(
		prepared.key,int(prepared.generation),true,true,true)
	check(stale_receipt.get("status") == "rejected","local edit rejects old mesh receipt")
	var retried: Dictionary = {}
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		var retry_event: Dictionary = backend.pump_voxel_block_shadow()
		if retry_event.get("status") == "ready" and retry_event.get("state") == "prepared":
			retried = retry_event
			break
		await process_frame
	check(not retried.is_empty() and int(retried.get("generation",0)) > int(prepared.generation)
		and retried.get("sdf16Le") == after_local.get("sdf16Le")
		and retried.get("indices8") == after_local.get("indices8")
		and retried.get("data5_8") == after_local.get("data5_8"),
		"retained local demand retries with edited native bytes and new generation")
	if not retried.is_empty():
		check(backend.voxel_block_shadow_insertion_receipt(
			retried.key,int(retried.generation),true).get("status") == "ready",
			"retried local insertion accepted")
		check(backend.voxel_block_shadow_mesh_receipt(
			retried.key,int(retried.generation),true,true,true).get("status") == "ready",
			"retried local mesh receipt accepted")
	var halo_requests := {}
	for z in range(-1,2):
		for y in range(-1,2):
			for x in range(-1,2):
				var origin := Vector3i(x,y,z) * 16
				var halo_request := request.duplicate()
				halo_request.origin = origin
				var admission: Dictionary = backend.request_voxel_block_shadow(halo_request,2,5)
				check(admission.has("key"),"halo request admitted: %s" % origin)
				halo_requests[origin] = true
	var published := {Vector3i.ZERO:true} if not retried.is_empty() else {}
	deadline = Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline and published.size() < halo_requests.size():
		var event: Dictionary = backend.pump_voxel_block_shadow()
		if event.get("status") == "ready" and event.get("state") == "prepared":
			var origin: Vector3i = event.key.origin
			var insertion: Dictionary = backend.voxel_block_shadow_insertion_receipt(
				event.key,int(event.generation),true)
			var mesh: Dictionary = backend.voxel_block_shadow_mesh_receipt(
				event.key,int(event.generation),true,true,true)
			check(insertion.get("status") == "ready" and mesh.get("status") == "ready",
				"halo service receipts accepted: %s" % origin)
			published[origin] = true
		await process_frame
	check(published.size() == halo_requests.size(),"27 retained halo keys reach service publication")
	var invalidation_started := Time.get_ticks_usec()
	var second_remote: Dictionary = commit_edit(backend,Vector3i(840,0,840),2,"second-remote")
	var invalidation_usec := Time.get_ticks_usec() - invalidation_started
	check(second_remote.get("commitStatus") == "committed","second remote edit committed")
	observations.append({"remoteEdit":remote.get("commitStatus"),
		"remoteReceipt":remote_receipt.get("status"),
		"localEdit":local.get("commitStatus"),
		"localReceipt":stale_receipt.get("status"),
		"localReason":stale_receipt.get("reason", ""),
		"localRetryGeneration":retried.get("generation",0),
		"haloPublished":published.size(),
		"secondRemoteEdit":second_remote.get("commitStatus"),
		"remoteEditCommitAndInvalidationUsec":invalidation_usec})
	backend = null
	finish()

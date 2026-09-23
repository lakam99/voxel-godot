extends SceneTree

# Real Godot binding/lifetime contract; no VoxelTerrain insertion or gameplay claim.
const REQUEST_SCHEMA := "n3-effective-voxel-block-request/v1"
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

func block_request(origin: Vector3i, size: Vector3i = Vector3i.ONE * 16) -> Dictionary:
	return {"schema":REQUEST_SCHEMA,"origin":origin,"size":size,"lod":0}

func edit_state() -> Dictionary:
	return {"materialId":13,"biomeId":0,"solid":true,"density":1.35,
		"fluidId":0,"light":Vector2i.ZERO,
		"metadata":{"source":"terrain_edit","terrainMeshAffects":true},
		"blockId":"async_shadow_edit","editReason":"async-shadow-contract"}

func wait_for_ticket(backend, ticket: int, label: String) -> Dictionary:
	var result: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		result = backend.poll_voxel_block_shadow_async(ticket)
		if result.get("status") != "pending" or result.get("reason") != "worker_running":
			break
		await process_frame
	check(result.get("status") != "pending" or result.get("reason") != "worker_running",
		label + " completed within 30 seconds")
	observations.append({"case":label,"status":result.get("status"),
		"reason":result.get("reason",""),"ticket":ticket,
		"captureUsec":result.get("captureUsec",-1),
		"workerEncodeUsec":result.get("workerEncodeUsec",-1)})
	return result

func finish() -> void:
	var path := OS.get_environment("VWB_ASYNC_VOXEL_SHADOW_REPORT")
	var report := {"schema":"n3-async-voxel-block-shadow-contract/v1",
		"passed":failures.is_empty(),"evidenceLevel":"real-godot-binding-service-contract",
		"productionCutover":false,"failures":failures,"observations":observations}
	if path != "":
		var file := FileAccess.open(path,FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report,"\t"))
	quit(0 if report.passed else 1)

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null,"NativeWorldBackend registered")
	if backend == null:
		finish()
		return
	check(backend.initialize(source_request()).get("status") == "ready","backend initialized")
	var broad := block_request(Vector3i.ZERO,Vector3i(32,1,32))
	broad.lod = 24
	var capped: Dictionary = backend.begin_voxel_block_shadow_async(broad)
	check(capped.get("status") == "failed" and not capped.has("ticket"),
		"high-LOD capture is bounded before large page pinning")
	var request := block_request(Vector3i(-8, 0, -8))
	var first: Dictionary = backend.begin_voxel_block_shadow_async(request)
	check(first.get("status") == "pending" and int(first.get("ticket",0)) > 0,
		"ready source starts owned worker ticket")
	if not first.has("ticket"):
		finish()
		return
	var busy: Dictionary = backend.begin_voxel_block_shadow_async(request)
	check(busy.get("reason") == "worker_busy" and not busy.has("ticket"),
		"bounded worker rejects second request without replacing first")
	var ticket := int(first.ticket)
	var result: Dictionary = await wait_for_ticket(backend,ticket,"initial encode")
	var direct: Dictionary = backend.encode_voxel_block_shadow(request)
	check(result.get("status") == "ready" and direct.get("status") == "ready",
		"async and direct blocks ready")
	check(int(result.get("captureUsec",0)) > 0 and int(result.get("workerEncodeUsec",0)) > 0,
		"ready worker reports capture and encode durations")
	if result.get("status") == "ready" and direct.get("status") == "ready":
		check(result.get("shadowOnly") == true and result.get("productionCutover") == false,
			"async service result cannot be mistaken for production publication")
		check(result.get("sdf16Le") == direct.get("sdf16Le")
			and result.get("indices8") == direct.get("indices8")
			and result.get("data5_8") == direct.get("data5_8"),
			"worker bytes exactly match synchronous native bytes")
		check(result.get("pinIdentity") == direct.get("pinIdentity")
			and result.get("blockContentIdentity") == direct.get("blockContentIdentity"),
			"worker identities match current source")
	check(backend.poll_voxel_block_shadow_async(ticket).get("status") == "failed",
		"completion consumed exactly once")
	var pending: Dictionary = backend.begin_voxel_block_shadow_async(
		block_request(Vector3i(560,0,560)))
	check(pending.get("status") == "pending" and pending.get("reason") == "shaping_dependency_unresolved"
		and not pending.has("ticket"),"unresolved source retains no fake worker bytes")
	var stale_begin: Dictionary = backend.begin_voxel_block_shadow_async(request)
	check(stale_begin.has("ticket"),"stale test worker started")
	if stale_begin.has("ticket"):
		var tx := {"schema":"n3-native-typed-cell-transaction/v1",
			"transactionId":"async-shadow:edit","expectedRevision":0,
			"operations":[{"namespace":"durable_terrain","kind":"set",
				"cell":Vector3i(-8,0,-8),"state":edit_state()}]}
		check(backend.commit_typed_cells(tx).get("commitStatus") == "committed",
			"edit committed while old encode in flight")
		var stale: Dictionary = await wait_for_ticket(backend,int(stale_begin.ticket),"stale encode")
		check(stale.get("status") == "pending" and stale.get("reason") == "source_changed_retry"
			and not stale.has("sdf16Le"),"old captured worker rejected after edit")
	var current_begin: Dictionary = backend.begin_voxel_block_shadow_async(request)
	check(current_begin.has("ticket"),"edited block retry admitted")
	if current_begin.has("ticket"):
		var current: Dictionary = await wait_for_ticket(backend,int(current_begin.ticket),"edited retry")
		check(current.get("status") == "ready" and current.get("terrainDeltaRevision") == 1,
			"retry encodes current edit revision")
	var cancel_begin: Dictionary = backend.begin_voxel_block_shadow_async(
		block_request(Vector3i(-8,0,-8),Vector3i.ONE * 32))
	check(cancel_begin.has("ticket"),"cancellable worker started")
	if cancel_begin.has("ticket"):
		var cancelled: Dictionary = backend.cancel_voxel_block_shadow_async(int(cancel_begin.ticket))
		var first_cancel_status: String = str(cancelled.get("status",""))
		var first_cancel_reason: String = str(cancelled.get("reason",""))
		if cancelled.get("status") == "pending":
			check(cancelled.get("reason") == "worker_draining",
				"cancellation does not join a running worker on Main")
			var deadline := Time.get_ticks_msec() + 30000
			while Time.get_ticks_msec() < deadline:
				cancelled = backend.poll_voxel_block_shadow_async(int(cancel_begin.ticket))
				if cancelled.get("status") != "pending":
					break
				await process_frame
		check(cancelled.get("status") == "ready" and cancelled.get("cancelled") == true,
			"cancel drains owned worker")
		check(not cancelled.has("sdf16Le"),"cancelled worker never returns bytes")
		check(backend.poll_voxel_block_shadow_async(int(cancel_begin.ticket)).get("status") == "failed",
			"cancelled ticket cannot publish")
		observations.append({"case":"cancel","initialStatus":first_cancel_status,
			"initialReason":first_cancel_reason,"finalStatus":cancelled.get("status")})
	var teardown_begin: Dictionary = backend.begin_voxel_block_shadow_async(
		block_request(Vector3i(-8,0,-8),Vector3i.ONE * 32))
	check(teardown_begin.has("ticket"),"teardown worker started")
	var teardown_started := Time.get_ticks_msec()
	backend = null
	var teardown_ms := Time.get_ticks_msec() - teardown_started
	observations.append({"case":"backend_teardown","elapsedMs":teardown_ms,
		"ticket":teardown_begin.get("ticket",0)})
	check(teardown_ms < 1000,"backend teardown cooperatively drains within one second")
	finish()

extends SceneTree

const QueueScript := preload("res://scripts/world/CitadelSiteBuildQueue.gd")
const CELL := 1.35
const SEED := "atlas-1492"
const TOWNS := [
	{"region": Vector2i(2, -1), "hasTown": true, "centerX": 560, "centerZ": -280, "radiusCells": 24, "levelMeters": 10.0},
	{"region": Vector2i(-3, 4), "hasTown": false},
]
const TOWN_MAP := {
	Vector2i(2, -1): {"centerX": 560, "centerZ": -280, "radius": 24, "level": 10.0},
	Vector2i(-3, 4): {},
}

var failures: Array[String] = []

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func failed(value: Dictionary, reason: String, label: String) -> void:
	check(value.get("status") == "failed", label + " status")
	check(reason.is_empty() or String(value.get("reason", "")).contains(reason), label + " reason: " + String(value.get("reason", "")))

func initialization(towns := TOWNS) -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":SEED,
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":CELL,"cellCenterOffsetCells":0.5,"worldBottomCellY":-64,"waterLevelMeters":11.1,"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":towns}}

func owner(towns := TOWNS):
	var value = ClassDB.instantiate("NativeWorldBackend")
	check(value != null, "adapter registration")
	if value != null: check(value.initialize(initialization(towns)).get("status") == "ready", "adapter initialization")
	return value

func empty_batch() -> Dictionary:
	return {"schema":"n3-effective-terrain-batch-request/v1","surfaceColumns":[],"cellCenters":[],"latticeNumeric":[],"worldNumeric":[],"surfaceProjectionNumeric":[]}

func full_batch(cell: Vector3i, other: Vector3i) -> Dictionary:
	var request := empty_batch()
	for c in [cell, other, cell]:
		request.surfaceColumns.append({"coordinate":Vector2i(c.x,c.z),"intent":"gameplay"})
		request.cellCenters.append({"coordinate":c,"intent":"gameplay"})
		request.latticeNumeric.append({"coordinate":c,"intent":"terrain_mesh"})
		request.worldNumeric.append({"position":Vector3((float(c.x)+0.5)*CELL,(float(c.y)+0.5)*CELL,(float(c.z)+0.5)*CELL),"intent":"terrain_mesh","semanticRevision":1})
		request.surfaceProjectionNumeric.append({"coordinate":c,"intent":"terrain_collision","semanticRevision":1})
	return request

func cell_state(density: float, source: String, affects: bool) -> Dictionary:
	return {"materialId":0,"biomeId":0,"solid":false,"density":density,"fluidId":0,"light":Vector2i(5,13),
		"metadata":{"source":source,"terrainMeshAffects":affects},"blockId":"contract_air","editReason":"page-contract"}

func solid_state() -> Dictionary:
	return {"materialId":3,"biomeId":0,"solid":true,"density":1.0,"fluidId":0,"light":Vector2i.ZERO,
		"metadata":{"source":"terrain_edit","terrainMeshAffects":true},"blockId":"contract_stone","editReason":"volume-surface-contract"}

func transaction(id: String, revision: int, cell: Vector3i) -> Dictionary:
	return {"schema":"n3-native-typed-cell-transaction/v1","transactionId":id,"expectedRevision":revision,"operations":[
		{"namespace":"durable_terrain","kind":"set","cell":cell,"state":cell_state(-1.35,"terrain_edit",true)},
		{"namespace":"scene_overlay","kind":"set","cell":cell,"state":cell_state(-0.75,"scene_block",false)}]}

func find_page(value, desired: String) -> Dictionary:
	for z in range(-12,13):
		for x in range(-12,13):
			var p := Vector2i(x,z)
			var readiness: Dictionary = value.shaping_requests(p)
			if readiness.get("status") == desired: return {"page":p,"readiness":readiness}
	return {}

func valid_identity(value, label: String) -> void:
	check(value is Dictionary, label + " dictionary")
	if value is Dictionary:
		var digest := String(value.get("hex",""))
		check(value.get("algorithm") == "sha256" and digest.length() == 64 and digest == digest.to_lower(), label + " sha256")

func prepared_profile(request: Dictionary, side := 5, apron := 1, root_count := 4, signature := "a".repeat(64)) -> Dictionary:
	var center: Vector2i=request.centerCell
	var envelope:=Rect2i(center-Vector2i(side/2,side/2),Vector2i(side,side))
	var core:=envelope.grow(-apron)
	var count:=side*side
	var support:=[]; support.resize(count); support.fill(0)
	var distances:=[]; distances.resize(count); distances.fill(1.0)
	var center_index:=(center.y-envelope.position.y)*side+center.x-envelope.position.x
	if center_index>=0 and center_index<count:
		support[center_index]=1; distances[center_index]=0.0
	var origin:=Vector3(float(center.x)*CELL,12.0,float(center.y)*CELL)
	var roots:=[]; roots.resize(root_count); roots.fill(origin)
	return {"version":1,"worldSeed":SEED,"siteId":request.siteId,"sourceSignature":signature,
		"cellSize":CELL,"coreCells":core,"envelopeCells":envelope,
		"reservationCells":Rect2i(center-Vector2i.ONE,Vector2i.ONE*3),
		"origin":origin,"level":12.0,"apronCells":apron,
		"supportMask":support,"distanceCells":distances,"groundRootPoints":roots}

func prepared_resolution(request: Dictionary, profile := {}) -> Dictionary:
	if profile.is_empty(): profile=prepared_profile(request)
	var candidate={"version":1,"siteId":request.siteId,"worldSeed":SEED,"region":request.region,
		"centerCell":request.centerCell,"recipeSeed":request.recipeSeed,"surfaceOnly":true}
	return {"region":request.region,"requestIdentity":request.requestIdentity,
		"workerSourceKey":request.workerSourceKey,"kind":"prepared","reasonCode":"",
		"candidate":candidate,"manifest":{"ready":true,"sourceSignature":profile.sourceSignature},
		"reservationCells":profile.envelopeCells.grow(1).merge(profile.reservationCells),"profile":profile}

func first_pending_request(value) -> Dictionary:
	var found:=find_page(value,"pending")
	return {} if found.is_empty() else {"page":found.page,"request":found.readiness.requests[0]}

func check_prepared_rejection(mutator: Callable, reason: String, label: String) -> void:
	var backend=owner(); var pending:=first_pending_request(backend)
	check(not pending.is_empty(),label+" pending")
	if pending.is_empty(): return
	var receipt:=prepared_resolution(pending.request)
	mutator.call(receipt)
	failed(backend.apply_shaping_resolutions([receipt]),reason,label)
	check(backend.shaping_requests(pending.page).get("status") == "pending",label+" atomic pending")

func test_page() -> Dictionary:
	var report := {}
	var backend = owner([])
	var status: Dictionary = backend.status()
	check(status.get("typedCellTransactionsSupported") == true and status.get("durableCellTransactionsSupported") == true, "typed/durable status")
	check(status.get("sceneOverlayTransactionsSupported") == true and status.get("sceneOverlaySavePersistence") == false, "overlay status and persistence")
	check(status.get("preparedShapingResolutionsSupported") == true, "prepared status")
	var ready := find_page(backend,"ready")
	check(not ready.is_empty(), "ready page")
	if ready.is_empty(): return report
	var page_key: Vector2i = ready.page
	var cell := Vector3i(page_key.x*280+5,0,page_key.y*280+7)
	var other := cell+Vector3i(1,0,0)
	var old_pin: Dictionary = backend.pin_effective_page(page_key)
	var old_page = old_pin.get("page")
	check(old_pin.get("status") == "ready" and old_page != null, "old pin")
	var surface_probe:=empty_batch(); surface_probe.surfaceColumns=[{"coordinate":Vector2i(cell.x,cell.z),"intent":"gameplay"}]
	var old_surface_probe: Dictionary=old_page.sample_batch(surface_probe)
	check(old_surface_probe.get("status") == "ready" and old_surface_probe.surfaceColumns.size() == 1,"old surface probe")
	var volume_cell:=Vector3i(cell.x,floori(float(old_surface_probe.surfaceColumns[0].referenceSurfaceY)/CELL)+5,cell.z)
	var expected_volume_surface_y:=float(volume_cell.y+1)*CELL
	var tx := transaction("page-contract:layered",0,cell)
	tx.operations.append({"namespace":"durable_terrain","kind":"set","cell":volume_cell,"state":solid_state()})
	var commit: Dictionary = backend.commit_typed_cells(tx)
	check(commit.get("status") == "ready" and commit.get("commitStatus") == "committed" and commit.get("revision") == 1, "mixed commit")
	check(backend.commit_typed_cells(tx).get("commitStatus") == "idempotent_replay", "idempotent replay")
	var changed := tx.duplicate(true); changed.operations[0].state.density = -1.0
	failed(backend.commit_typed_cells(changed),"transaction","changed replay")
	failed(backend.commit_typed_cells(transaction("page-contract:stale",0,other)),"revision","stale revision")
	var new_pin: Dictionary = backend.pin_effective_page(page_key)
	var new_page = new_pin.get("page")
	check(new_pin.get("status") == "ready" and new_page != null, "new pin")
	backend = null
	await process_frame
	var request := full_batch(cell,other)
	var old_result: Dictionary = old_page.sample_batch(request)
	var result: Dictionary = new_page.sample_batch(request)
	check(old_result.get("status") == "ready" and result.get("status") == "ready", "old/new samples after owner release")
	for key in ["sourceIdentity","pinIdentity","shapingRegistryIdentity"]: valid_identity(result.get(key),key)
	check(old_result.sourceIdentity == result.sourceIdentity and old_result.pinIdentity != result.pinIdentity, "source/pin identities")
	check(old_result.terrainDeltaRevision == 0 and result.terrainDeltaRevision == 1, "terrain revisions")
	check(old_result.shapingRegistryIdentity == result.shapingRegistryIdentity, "shaping identity stable")
	for channel in ["surfaceColumns","cellCenters","latticeNumeric","worldNumeric","surfaceProjectionNumeric"]:
		check(result[channel].size() == 3 and result[channel][0] == result[channel][2], channel+" order/duplicate")
	check(result.surfaceColumns[0].requested.coordinate == Vector2i(cell.x,cell.z) and result.surfaceColumns[0].sourceCell == Vector2i(cell.x,cell.z), "surface requested/source")
	check(result.surfaceColumns[0].referenceSurfaceY == old_result.surfaceColumns[0].referenceSurfaceY and result.surfaceColumns[0].deformedSurfaceY == old_result.surfaceColumns[0].deformedSurfaceY and result.surfaceColumns[0].biomeId == old_result.surfaceColumns[0].biomeId,"surface shaping/biome unchanged by durable cell")
	check(is_equal_approx(float(result.surfaceColumns[0].volumeSurfaceY),expected_volume_surface_y) and not is_equal_approx(float(old_result.surfaceColumns[0].volumeSurfaceY),expected_volume_surface_y),"volumeSurfaceY owns highest exposed durable solid")
	var center: Dictionary = result.cellCenters[0]
	check(center.requested.coordinate == cell and center.sourceCell == cell and center.requested.intent == "gameplay", "center ownership")
	check(center.edited and not center.generated and center.density == -0.75 and center.materialId == 0, "center overlay precedence")
	check(center.editedSparseState is Dictionary and center.editedSparseState.cell == cell and center.editedSparseState.metadata.source == "scene_block", "center sparse overlay")
	var lattice: Dictionary = result.latticeNumeric[0]
	var lattice_position := Vector3(cell) * CELL
	var lattice_source := Vector3i(floori(lattice_position.x / CELL), floori(lattice_position.y / CELL), floori(lattice_position.z / CELL))
	check(lattice.requestedCell == cell and lattice.sourceCell == lattice_source and lattice.requested.intent == "terrain_mesh", "lattice ownership")
	check(lattice.edited and not lattice.generated and lattice.density == -1.35 and lattice.materialId == 0, "lattice durable precedence")
	check(lattice.editedSparseState is Dictionary and lattice.editedSparseState.metadata.source == "terrain_edit", "lattice sparse durable")
	var world: Dictionary = result.worldNumeric[0]
	check(world.sourceCell == cell and world.intent == "terrain_mesh" and world.semanticRevision == 1, "world ownership")
	check(world.edited and not world.generated and world.density == -CELL and world.materialId == 0, "world mesh payload")
	check(world.editedSparseState is Dictionary and world.editedSparseState.metadata.source == "scene_block", "world sparse overlay")
	var projection: Dictionary = result.surfaceProjectionNumeric[0]
	check(projection.requestedCell == cell and projection.sourceCell == cell and projection.requested.intent == "terrain_collision" and projection.semanticRevision == 1, "projection ownership")
	check(projection.generated and not projection.edited and projection.editedSparseState == null and projection.materialId == old_result.surfaceProjectionNumeric[0].materialId and projection.density == old_result.surfaceProjectionNumeric[0].density, "projection ignores overlay")
	for channel in ["cellCenters","latticeNumeric","worldNumeric","surfaceProjectionNumeric"]:
		check(result[channel][1].generated and not result[channel][1].edited and result[channel][1].editedSparseState == null, channel+" generated neighbor")
	check(old_result.cellCenters[0].generated and not old_result.cellCenters[0].edited, "old pin immutable")
	var invalid := empty_batch(); invalid.cellCenters=[{"coordinate":cell,"intent":"bad"}]
	failed(new_page.sample_batch(invalid),"not a supported intent","unsupported intent")
	invalid=empty_batch(); invalid.worldNumeric=[{"position":Vector3.ZERO,"intent":"terrain_mesh","semanticRevision":2}]
	failed(new_page.sample_batch(invalid),"world-numeric batch query is invalid","world revision")
	invalid=empty_batch(); invalid.surfaceProjectionNumeric=[{"coordinate":cell,"intent":"gameplay","semanticRevision":1}]
	failed(new_page.sample_batch(invalid),"surface-projection batch query is invalid","projection intent")
	check(new_page.sample_batch(empty_batch()).get("status") == "ready", "valid sample after rejection")
	report={"ownerReleasedBeforeSample":true,"oldRevision":old_result.terrainDeltaRevision,"newRevision":result.terrainDeltaRevision,
		"volumeSurfaceYWitness":{"column":Vector2i(cell.x,cell.z),"durableSolidCell":volume_cell,
			"old":old_result.surfaceColumns[0].volumeSurfaceY,"actual":result.surfaceColumns[0].volumeSurfaceY,
			"expected":expected_volume_surface_y,"relationship":"highest_exposed_durable_solid_top"}}
	return report

func test_shaping() -> Dictionary:
	var report := {"workerSourceKeysChecked":0,"preparedSampling":{}}
	var backend = owner()
	check(backend.status().get("preparedShapingResolutionsSupported") == true, "prepared status")
	var found := find_page(backend,"pending")
	check(not found.is_empty(),"pending page")
	if found.is_empty(): return report
	var page: Vector2i=found.page
	var requests: Array=found.readiness.requests
	check(not requests.is_empty() and backend.pin_effective_page(page).get("status") == "pending","pending requests/pin")
	for request in requests:
		var canonical: Dictionary=QueueScript._canonical_request(SEED,request.region,TOWN_MAP,{"regionCells":140,"spawnChance":0.08})
		check(not canonical.is_empty() and canonical.sourceKey == request.workerSourceKey,"workerSourceKey parity")
		report.workerSourceKeysChecked+=1
	var first: Dictionary=requests[0]
	var prepared:=prepared_resolution(first)
	var wrong:=prepared.duplicate(true); wrong.kind="absent"; wrong.reasonCode="absent"; wrong.workerSourceKey="0".repeat(64)
	failed(backend.apply_shaping_resolutions([wrong]),"canonical request","worker key rejection")
	wrong=prepared.duplicate(true); wrong.requestIdentity="0".repeat(64)
	failed(backend.apply_shaping_resolutions([wrong]),"request identity","request identity rejection")
	var resolutions:=[]
	resolutions.append(prepared)
	for request in requests.slice(1): resolutions.append({"region":request.region,"requestIdentity":request.requestIdentity,"workerSourceKey":request.workerSourceKey,"kind":"absent","reasonCode":"contract_absent"})
	var before: Dictionary=backend.status()
	var admitted: Dictionary=backend.apply_shaping_resolutions(resolutions)
	check(admitted.get("commitStatus") == "committed" and admitted.shapingRegistryRevision == before.shapingRegistryRevision+1,"prepared commit/revision")
	check(admitted.shapingRegistryIdentity != before.shapingRegistryIdentity,"shaping identity change")
	var replay: Dictionary=backend.apply_shaping_resolutions([prepared])
	check(replay.get("commitStatus") == "no_change" and replay.shapingRegistryRevision == admitted.shapingRegistryRevision,"prepared replay/revision")
	var candidate_page:=Vector2i(floori(float(first.centerCell.x)/280.0),floori(float(first.centerCell.y)/280.0))
	var candidate_readiness: Dictionary=backend.shaping_requests(candidate_page)
	if candidate_readiness.get("status") == "pending":
		var remaining:=[]
		for request in candidate_readiness.requests:
			remaining.append({"region":request.region,"requestIdentity":request.requestIdentity,"workerSourceKey":request.workerSourceKey,"kind":"absent","reasonCode":"contract_absent"})
		check(backend.apply_shaping_resolutions(remaining).get("status") == "ready","prepared neighbor dependencies")
	var shaped_pin: Dictionary=backend.pin_effective_page(candidate_page)
	var shaped_page=shaped_pin.get("page")
	check(shaped_pin.get("status") == "ready" and shaped_page != null,"prepared pin ready")
	backend=null
	if shaped_page != null:
		var shaped_request:=empty_batch(); shaped_request.surfaceColumns=[{"coordinate":first.centerCell,"intent":"gameplay"}]
		var shaped: Dictionary=shaped_page.sample_batch(shaped_request)
		check(shaped.get("status") == "ready" and shaped.surfaceColumns.size() == 1,"prepared pin sample")
		if shaped.get("status") == "ready" and shaped.surfaceColumns.size() == 1:
			check(is_equal_approx(float(shaped.surfaceColumns[0].deformedSurfaceY),12.0),"prepared center level")
			report.preparedSampling={"candidateRegion":first.region,"centerCell":first.centerCell,
				"registryRevision":admitted.shapingRegistryRevision,"deformedSurfaceY":shaped.surfaceColumns[0].deformedSurfaceY,
				"ownerReleasedBeforeSample":true}

	check_prepared_rejection(func(value): value.candidate.siteId+="-altered","candidate does not match","altered candidate")
	check_prepared_rejection(func(value): value.candidate.worldSeed+="-altered","candidate does not match","altered candidate seed")
	check_prepared_rejection(func(value): value.manifest.ready=false,"manifest is not ready","manifest not ready")
	check_prepared_rejection(func(value): value.manifest.sourceSignature="b".repeat(64),"manifest signature","signature mismatch")
	check_prepared_rejection(func(value): value.reservationCells=Rect2i(value.reservationCells.position+Vector2i(385,0),value.reservationCells.size),"source reservation","reservation outside declaration")
	check_prepared_rejection(func(value): value.profile.siteId+="-altered","profile site ID","profile candidate binding")
	check_prepared_rejection(func(value): value.profile.origin+=Vector3(CELL,0,0),"native terrain shaping registry rejected","profile origin binding")
	check_prepared_rejection(func(value): value.profile.origin=Vector3(INF,0,0),"finite","profile finite origin")
	check_prepared_rejection(func(value): value.profile.coreCells=Rect2i(Vector2i(1000001,0),Vector2i.ONE),"bounded profile rectangle","profile rectangle bound")
	check_prepared_rejection(func(value): value.profile.distanceCells[0]=INF,"finite","profile finite distance")
	check_prepared_rejection(func(value): value.profile.distanceCells[12]=-1.0,"terrain profile semantics","profile negative distance")
	var failure_backend=owner(); var failure_found:=find_page(failure_backend,"pending")
	check(not failure_found.is_empty(),"failure pending page")
	if not failure_found.is_empty():
		var request: Dictionary=failure_found.readiness.requests[0]
		check(failure_backend.apply_shaping_resolutions([{"region":request.region,"requestIdentity":request.requestIdentity,"workerSourceKey":request.workerSourceKey,"kind":"failed","reasonCode":"contract_failed"}]).get("status") == "ready","failed admission")
		check(failure_backend.shaping_requests(failure_found.page).get("status") == "failed" and failure_backend.pin_effective_page(failure_found.page).get("status") == "failed","failed terminal state")
	return report

func record_cap_pair(completed: Array, name: String, limit: int, exact_ok: bool, over_ok: bool) -> void:
	completed.append({"name":name,"limit":limit,"exactAtLimit":exact_ok,"plusOneRejected":over_ok})
	check(exact_ok, name+" exact-at-limit")
	check(over_ok, name+" plus-one")

func metadata_for_node_count(target: int, container_limit: int) -> Dictionary:
	# The metadata object and its top array are two nodes. Child arrays consume
	# one node each; their null leaves fill the remainder without exceeding any
	# container or depth limit.
	var remaining:=target-2
	var child_count:=mini(container_limit,remaining)
	var leaf_count:=remaining-child_count
	var children:=[]
	for index in range(child_count):
		var slots_left:=child_count-index
		var leaves:=ceili(float(leaf_count)/float(slots_left)) if slots_left>0 else 0
		var child:=[]; child.resize(leaves); children.append(child); leaf_count-=leaves
	return {"nodes":children}

func typed_state_commit(value: Dictionary, transaction_id: String) -> Dictionary:
	var backend=owner([])
	return backend.commit_typed_cells({"schema":"n3-native-typed-cell-transaction/v1","transactionId":transaction_id,"expectedRevision":0,"operations":[{"namespace":"durable_terrain","kind":"set","cell":Vector3i.ZERO,"state":value}]})

func metadata_commit(metadata: Dictionary, transaction_id: String) -> Dictionary:
	var value:=cell_state(-1.0,"terrain_edit",true); value.metadata=metadata
	return typed_state_commit(value,transaction_id)

func test_caps() -> Dictionary:
	var completed:=[]
	var backend=owner([]); var limits: Dictionary=backend.status().adapterLimits
	var ready:=find_page(backend,"ready"); check(not ready.is_empty(),"caps ready page")
	if ready.is_empty(): return {"completed":completed}
	var page=backend.pin_effective_page(ready.page).get("page")
	var channel_limit:=int(limits.batchChannelQueries)
	for channel in ["surfaceColumns","cellCenters","latticeNumeric","worldNumeric","surfaceProjectionNumeric"]:
		var exact:=empty_batch(); exact[channel].resize(channel_limit)
		var exact_result: Dictionary=page.sample_batch(exact)
		var over:=empty_batch(); over[channel].resize(channel_limit+1)
		var over_result: Dictionary=page.sample_batch(over)
		record_cap_pair(completed,"batch."+channel,channel_limit,String(exact_result.get("reason","")).contains("must be a Dictionary"),String(over_result.get("reason","")).contains("channel exceeds adapter query limit"))
	var total_limit:=int(limits.batchTotalQueries)
	var exact_total:=empty_batch(); exact_total.surfaceColumns.resize(channel_limit); exact_total.cellCenters.resize(channel_limit); exact_total.latticeNumeric.resize(channel_limit); exact_total.worldNumeric.resize(total_limit-channel_limit*3)
	var exact_total_result: Dictionary=page.sample_batch(exact_total)
	var over_total:=exact_total.duplicate(true); over_total.surfaceProjectionNumeric.resize(1)
	var over_total_result: Dictionary=page.sample_batch(over_total)
	record_cap_pair(completed,"batch.total",total_limit,String(exact_total_result.get("reason","")).contains("must be a Dictionary"),String(over_total_result.get("reason","")).contains("total query limit"))
	var operation_limit:=int(limits.typedCellOperations)
	var exact_operations:=[]; exact_operations.resize(operation_limit)
	var exact_operation_result: Dictionary=backend.commit_typed_cells({"schema":"n3-native-typed-cell-transaction/v1","transactionId":"exact-operations","expectedRevision":0,"operations":exact_operations})
	var over_operations:=[]; over_operations.resize(operation_limit+1)
	var over_operation_result: Dictionary=backend.commit_typed_cells({"schema":"n3-native-typed-cell-transaction/v1","transactionId":"over-operations","expectedRevision":0,"operations":over_operations})
	record_cap_pair(completed,"typedCellOperations",operation_limit,String(exact_operation_result.get("reason","")).contains("must be a Dictionary"),String(over_operation_result.get("reason","")).contains("operation limit"))
	var shaping_limit:=int(limits.shapingResolutions)
	var exact_shaping:=[]; exact_shaping.resize(shaping_limit)
	var exact_shaping_result: Dictionary=backend.apply_shaping_resolutions(exact_shaping)
	var over_shaping:=[]; over_shaping.resize(shaping_limit+1)
	var over_shaping_result: Dictionary=backend.apply_shaping_resolutions(over_shaping)
	record_cap_pair(completed,"shapingResolutions",shaping_limit,String(exact_shaping_result.get("reason","")).contains("must be a Dictionary"),String(over_shaping_result.get("reason","")).contains("adapter batch limit"))

	var seed_limit:=int(limits.seedCodePoints); var seed_scalar:="😀"
	var exact_seed_owner=ClassDB.instantiate("NativeWorldBackend"); var exact_seed_request:=initialization([]); exact_seed_request.seedText=seed_scalar.repeat(seed_limit)
	var exact_seed: Dictionary=exact_seed_owner.initialize(exact_seed_request)
	var over_seed_owner=ClassDB.instantiate("NativeWorldBackend"); var over_seed_request:=initialization([]); over_seed_request.seedText=seed_scalar.repeat(seed_limit+1)
	var over_seed: Dictionary=over_seed_owner.initialize(over_seed_request)
	record_cap_pair(completed,"seedCodePoints",seed_limit,exact_seed.get("status") == "ready" and exact_seed_request.seedText.to_utf8_buffer().size() == int(limits.seedUtf8Bytes),String(over_seed.get("reason","")).contains("code point limit"))

	var town_limit:=int(limits.townOverrides); var exact_towns:=[]
	for index in range(town_limit): exact_towns.append({"region":Vector2i(index,0),"hasTown":false})
	var exact_town_owner=ClassDB.instantiate("NativeWorldBackend"); var exact_town: Dictionary=exact_town_owner.initialize(initialization(exact_towns))
	var over_towns:=exact_towns.duplicate(true); over_towns.append({"region":Vector2i(town_limit,0),"hasTown":false})
	var over_town_owner=ClassDB.instantiate("NativeWorldBackend"); var over_town: Dictionary=over_town_owner.initialize(initialization(over_towns))
	record_cap_pair(completed,"townOverrides",town_limit,exact_town.get("status") == "ready",String(over_town.get("reason","")).contains("record limit"))

	var depth_limit:=int(limits.metadataDepth); var exact_nested: Variant="leaf"
	for _index in range(depth_limit-1): exact_nested=[exact_nested]
	var exact_depth: Dictionary=metadata_commit({"nested":exact_nested},"metadata-depth-exact")
	var over_nested: Variant=[exact_nested]
	var over_depth: Dictionary=metadata_commit({"nested":over_nested},"metadata-depth-over")
	record_cap_pair(completed,"metadataDepth",depth_limit,exact_depth.get("status") == "ready",String(over_depth.get("reason","")).contains("metadata depth limit"))

	var container_limit:=int(limits.metadataContainerEntries); var exact_entries:=[]; exact_entries.resize(container_limit)
	var exact_container: Dictionary=metadata_commit({"entries":exact_entries},"metadata-container-exact")
	var over_entries:=[]; over_entries.resize(container_limit+1)
	var over_container: Dictionary=metadata_commit({"entries":over_entries},"metadata-container-over")
	record_cap_pair(completed,"metadataContainerEntries",container_limit,exact_container.get("status") == "ready",String(over_container.get("reason","")).contains("metadata container limit"))

	var key_limit:=int(limits.metadataKeyBytes)
	var exact_key: Dictionary=metadata_commit({"k".repeat(key_limit):true},"metadata-key-exact")
	var over_key: Dictionary=metadata_commit({"k".repeat(key_limit+1):true},"metadata-key-over")
	record_cap_pair(completed,"metadataKeyBytes",key_limit,exact_key.get("status") == "ready",String(over_key.get("reason","")).contains("text limit"))

	var node_limit:=int(limits.metadataNodes)
	var exact_nodes: Dictionary=metadata_commit(metadata_for_node_count(node_limit,container_limit),"metadata-nodes-exact")
	var over_nodes: Dictionary=metadata_commit(metadata_for_node_count(node_limit+1,container_limit),"metadata-nodes-over")
	record_cap_pair(completed,"metadataNodes",node_limit,exact_nodes.get("status") == "ready",String(over_nodes.get("reason","")).contains("metadata node limit"))

	var metadata_string_limit:=int(limits.metadataStringBytes)
	var exact_metadata_string: Dictionary=metadata_commit({"text":"m".repeat(metadata_string_limit)},"metadata-string-exact")
	var over_metadata_string: Dictionary=metadata_commit({"text":"m".repeat(metadata_string_limit+1)},"metadata-string-over")
	record_cap_pair(completed,"metadataStringBytes",metadata_string_limit,exact_metadata_string.get("status") == "ready",String(over_metadata_string.get("reason","")).contains("text limit"))

	var transaction_limit:=int(limits.transactionIdBytes)
	var transaction_value:=cell_state(-1.0,"terrain_edit",true)
	var exact_transaction: Dictionary=typed_state_commit(transaction_value,"t".repeat(transaction_limit))
	var over_transaction: Dictionary=typed_state_commit(transaction_value,"t".repeat(transaction_limit+1))
	record_cap_pair(completed,"transactionIdBytes",transaction_limit,exact_transaction.get("status") == "ready",String(over_transaction.get("reason","")).contains("text limit"))

	var block_limit:=int(limits.blockIdBytes)
	var exact_block_value:=cell_state(-1.0,"terrain_edit",true); exact_block_value.blockId="b".repeat(block_limit)
	var over_block_value:=cell_state(-1.0,"terrain_edit",true); over_block_value.blockId="b".repeat(block_limit+1)
	var exact_block: Dictionary=typed_state_commit(exact_block_value,"block-exact")
	var over_block: Dictionary=typed_state_commit(over_block_value,"block-over")
	record_cap_pair(completed,"blockIdBytes",block_limit,exact_block.get("status") == "ready",String(over_block.get("reason","")).contains("text limit"))

	var edit_reason_limit:=int(limits.editReasonBytes)
	var exact_reason_value:=cell_state(-1.0,"terrain_edit",true); exact_reason_value.editReason="e".repeat(edit_reason_limit)
	var over_reason_value:=cell_state(-1.0,"terrain_edit",true); over_reason_value.editReason="e".repeat(edit_reason_limit+1)
	var exact_edit_reason: Dictionary=typed_state_commit(exact_reason_value,"edit-reason-exact")
	var over_edit_reason: Dictionary=typed_state_commit(over_reason_value,"edit-reason-over")
	record_cap_pair(completed,"editReasonBytes",edit_reason_limit,exact_edit_reason.get("status") == "ready",String(over_edit_reason.get("reason","")).contains("text limit"))

	var reason_limit:=int(limits.shapingReasonBytes)
	var reason_exact_owner=owner(); var reason_exact_found:=find_page(reason_exact_owner,"pending"); var exact_reason_ok:=false
	if not reason_exact_found.is_empty():
		var request: Dictionary=reason_exact_found.readiness.requests[0]
		var receipt: Dictionary=reason_exact_owner.apply_shaping_resolutions([{"region":request.region,"requestIdentity":request.requestIdentity,"workerSourceKey":request.workerSourceKey,"kind":"absent","reasonCode":"r".repeat(reason_limit)}])
		exact_reason_ok=receipt.get("status") == "ready" and receipt.get("commitStatus") == "committed"
	var reason_over_owner=owner(); var reason_over_found:=find_page(reason_over_owner,"pending"); var over_reason_ok:=false
	if not reason_over_found.is_empty():
		var request: Dictionary=reason_over_found.readiness.requests[0]
		var receipt: Dictionary=reason_over_owner.apply_shaping_resolutions([{"region":request.region,"requestIdentity":request.requestIdentity,"workerSourceKey":request.workerSourceKey,"kind":"absent","reasonCode":"r".repeat(reason_limit+1)}])
		over_reason_ok=String(receipt.get("reason","")).contains("text limit") and reason_over_owner.shaping_requests(reason_over_found.page).get("status") == "pending"
	record_cap_pair(completed,"shapingReasonBytes",reason_limit,exact_reason_ok,over_reason_ok)

	var sample_limit:=int(limits.siteProfileSamples)
	var sample_exact_owner=owner(); var sample_exact_pending:=first_pending_request(sample_exact_owner); var sample_exact_ok:=false
	if not sample_exact_pending.is_empty():
		var sample_profile:=prepared_profile(sample_exact_pending.request,512)
		var receipt: Dictionary=sample_exact_owner.apply_shaping_resolutions([prepared_resolution(sample_exact_pending.request,sample_profile)])
		sample_exact_ok=receipt.get("status") == "ready" and receipt.get("commitStatus") == "committed" and sample_profile.supportMask.size() == sample_limit
	var support_over_owner=owner(); var support_over_pending:=first_pending_request(support_over_owner); var support_over_ok:=false
	if not support_over_pending.is_empty():
		var support_over_profile:=prepared_profile(support_over_pending.request,512); support_over_profile.supportMask.append(0)
		var receipt: Dictionary=support_over_owner.apply_shaping_resolutions([prepared_resolution(support_over_pending.request,support_over_profile)])
		support_over_ok=String(receipt.get("reason","")).contains("supportMask exceeds sample limit")
	record_cap_pair(completed,"siteProfile.supportMask",sample_limit,sample_exact_ok,support_over_ok)
	var distance_over_owner=owner(); var distance_over_pending:=first_pending_request(distance_over_owner); var distance_over_ok:=false
	if not distance_over_pending.is_empty():
		var distance_over_profile:=prepared_profile(distance_over_pending.request,512); distance_over_profile.distanceCells.append(1.0)
		var receipt: Dictionary=distance_over_owner.apply_shaping_resolutions([prepared_resolution(distance_over_pending.request,distance_over_profile)])
		distance_over_ok=String(receipt.get("reason","")).contains("distanceCells exceeds sample limit")
	record_cap_pair(completed,"siteProfile.distanceCells",sample_limit,sample_exact_ok,distance_over_ok)

	var root_limit:=int(limits.siteProfileRootPoints)
	var root_exact_owner=owner(); var root_exact_pending:=first_pending_request(root_exact_owner); var root_exact_ok:=false
	if not root_exact_pending.is_empty():
		var root_profile:=prepared_profile(root_exact_pending.request,5,1,root_limit)
		var receipt: Dictionary=root_exact_owner.apply_shaping_resolutions([prepared_resolution(root_exact_pending.request,root_profile)])
		root_exact_ok=receipt.get("status") == "ready" and receipt.get("commitStatus") == "committed"
	var root_over_owner=owner(); var root_over_pending:=first_pending_request(root_over_owner); var root_over_ok:=false
	if not root_over_pending.is_empty():
		var root_over_profile:=prepared_profile(root_over_pending.request,5,1,root_limit); root_over_profile.groundRootPoints.append(root_over_profile.origin)
		var receipt: Dictionary=root_over_owner.apply_shaping_resolutions([prepared_resolution(root_over_pending.request,root_over_profile)])
		root_over_ok=String(receipt.get("reason","")).contains("root point limit")
	record_cap_pair(completed,"siteProfile.groundRootPoints",root_limit,root_exact_ok,root_over_ok)

	var signature_limit:=int(limits.siteProfileSourceSignatureBytes)
	var signature_exact_owner=owner(); var signature_exact_pending:=first_pending_request(signature_exact_owner); var signature_exact_ok:=false
	if not signature_exact_pending.is_empty():
		var signature_profile:=prepared_profile(signature_exact_pending.request,5,1,4,"s".repeat(signature_limit))
		var receipt: Dictionary=signature_exact_owner.apply_shaping_resolutions([prepared_resolution(signature_exact_pending.request,signature_profile)])
		signature_exact_ok=receipt.get("status") == "ready" and receipt.get("commitStatus") == "committed"
	var signature_over_owner=owner(); var signature_over_pending:=first_pending_request(signature_over_owner); var signature_over_ok:=false
	if not signature_over_pending.is_empty():
		var signature_over_profile:=prepared_profile(signature_over_pending.request,5,1,4,"s".repeat(signature_limit+1))
		var receipt: Dictionary=signature_over_owner.apply_shaping_resolutions([prepared_resolution(signature_over_pending.request,signature_over_profile)])
		signature_over_ok=String(receipt.get("reason","")).contains("text limit")
	record_cap_pair(completed,"siteProfile.sourceSignatureBytes",signature_limit,signature_exact_ok,signature_over_ok)

	var apron_limit:=int(limits.siteProfileApronCells)
	var apron_exact_owner=owner(); var apron_exact_pending:=first_pending_request(apron_exact_owner); var apron_exact_ok:=false
	if not apron_exact_pending.is_empty():
		var apron_profile:=prepared_profile(apron_exact_pending.request,apron_limit*2+3,apron_limit)
		var receipt: Dictionary=apron_exact_owner.apply_shaping_resolutions([prepared_resolution(apron_exact_pending.request,apron_profile)])
		apron_exact_ok=receipt.get("status") == "ready" and receipt.get("commitStatus") == "committed"
	var apron_over_owner=owner(); var apron_over_pending:=first_pending_request(apron_over_owner); var apron_over_ok:=false
	if not apron_over_pending.is_empty():
		var apron_over_profile:=prepared_profile(apron_over_pending.request,(apron_limit+1)*2+3,apron_limit+1)
		var receipt: Dictionary=apron_over_owner.apply_shaping_resolutions([prepared_resolution(apron_over_pending.request,apron_over_profile)])
		apron_over_ok=String(receipt.get("reason","")).contains("native terrain shaping page admission failed")
	record_cap_pair(completed,"siteProfile.apronCells",apron_limit,apron_exact_ok,apron_over_ok)

	check(backend.status().terrainDeltaRevision == 0 and page.sample_batch(empty_batch()).get("status") == "ready","caps atomic/usable")
	return {"completed":completed,"completedPairCount":completed.size(),"allCompleted":completed.all(func(value): return value.exactAtLimit and value.plusOneRejected)}

func _init() -> void: call_deferred("run")

func run() -> void:
	var report_path:=OS.get_environment("VWB_N3_PAGE_CONTRACT_REPORT")
	var page: Dictionary=await test_page()
	var shaping:=test_shaping()
	var caps:=test_caps()
	var report={"schema":"native-world-backend-page-contract/v2","passed":failures.is_empty(),"evidenceLevel":"shadow-service-contract-only","productionCutover":false,"page":page,"shaping":shaping,"caps":caps,"failures":failures}
	if report_path != "":
		var file:=FileAccess.open(report_path,FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report,"\t"))
	quit(0 if report.passed else 1)

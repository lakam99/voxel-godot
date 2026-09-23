extends SceneTree

# Shadow-service byte transport only; this does not publish a VoxelBuffer.
const REQUEST_SCHEMA := "n3-effective-voxel-block-request/v1"
var failures: Array[String] = []

func check(value: bool, label: String) -> void:
	if not value:
		failures.append(label)

func request(origin: Vector3i, size: Vector3i, lod := 0) -> Dictionary:
	return {"schema": REQUEST_SCHEMA, "origin": origin, "size": size, "lod": lod}

func initialize() -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":"atlas-1492",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,"worldBottomCellY":-64,"waterLevelMeters":11.1,"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "class registered")
	if backend == null:
		quit(1)
		return
	check(backend.initialize(initialize()).get("status") == "ready", "initialize")
	var key := Vector2i.ZERO
	var pin: Dictionary = backend.pin_effective_page(key)
	check(pin.get("status") == "ready", "ready page")
	if pin.get("status") != "ready":
		quit(1)
		return
	var old_page = pin.page
	var cell := Vector3i(5, 0, 7)
	var one := request(cell, Vector3i.ONE)
	var old_result: Dictionary = old_page.encode_voxel_block(one)
	check(old_result.get("status") == "ready" and old_result.get("shadowOnly") == true and old_result.get("productionCutover") == false, "old shadow result")
	check(old_result.get("sdf16Le") is PackedByteArray and old_result.sdf16Le.size() == 2, "sdf bytes")
	check(old_result.get("indices8") is PackedByteArray and old_result.indices8.size() == 1, "indices bytes")
	check(old_result.get("data5_8") is PackedByteArray and old_result.data5_8.size() == 1, "data bytes")
	check(old_result.get("pinIdentity") == old_page.status().get("pinIdentity") and old_result.get("terrainDeltaRevision") == 0, "pin receipt")
	var state := {"materialId":0,"biomeId":0,"solid":false,"density":-1.35,"fluidId":0,"light":Vector2i.ZERO,
		"metadata":{"source":"terrain_edit","terrainMeshAffects":true},"blockId":"adapter_air","editReason":"voxel-adapter-contract"}
	var tx := {"schema":"n3-native-typed-cell-transaction/v1","transactionId":"voxel-adapter-contract:1","expectedRevision":0,
		"operations":[{"namespace":"durable_terrain","kind":"set","cell":cell,"state":state}]}
	var commit: Dictionary = backend.commit_typed_cells(tx)
	check(commit.get("status") == "ready" and commit.get("commitStatus") == "committed", "commit")
	var new_pin: Dictionary = backend.pin_effective_page(key)
	check(new_pin.get("status") == "ready", "new pin")
	var new_page = new_pin.get("page")
	var edited: Dictionary = new_page.encode_voxel_block(one)
	check(edited.get("status") == "ready", "edited result")
	check(edited.get("sdf16Le") == PackedByteArray([65, 0]), "edited SDF16 little-endian bytes")
	check(edited.get("indices8") == PackedByteArray([0]) and edited.get("data5_8") == PackedByteArray([0]), "edited material bytes")
	check(edited.get("pinIdentity") != old_result.get("pinIdentity") and edited.get("terrainDeltaRevision") == 1, "new pin receipt")
	check(old_page.encode_voxel_block(one).get("sdf16Le") == old_result.get("sdf16Le"), "old pin remains immutable")
	for invalid in [request(cell, Vector3i.ZERO), request(cell, Vector3i(33,1,1)), request(cell, Vector3i.ONE, -1),
		request(Vector3i(279,0,0), Vector3i(2,1,1)), {"schema":"wrong","origin":cell,"size":Vector3i.ONE,"lod":0}]:
		var failure: Dictionary = new_page.encode_voxel_block(invalid)
		check(failure.get("status") == "failed" and failure.get("operation") == "encode_voxel_block", "invalid request rejected: " + str(invalid))
	var report := {"schema":"native-effective-voxel-adapter-contract/v1","passed":failures.is_empty(),
		"evidenceLevel":"shadow-service-byte-contract-only","productionCutover":false,"failures":failures}
	var path := OS.get_environment("VWB_VOXEL_ADAPTER_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)

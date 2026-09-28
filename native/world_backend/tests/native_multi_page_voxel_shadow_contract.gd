extends SceneTree

# Serialized shadow-service contract. No VoxelBuffer or production publication.
const Oracle := preload("res://scripts/testing/native_world/N3EffectiveTerrainOracle.gd")
const Generator := preload("res://scripts/terrain/VoxelTerrainGenerator.gd")
const SCHEMA := "n3-effective-voxel-block-request/v1"
var failures: Array[String] = []
var cases: Array[Dictionary] = []

func check(value: bool, label: String) -> void:
	if not value:
		failures.append(label)

func source_request() -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":"atlas-1492",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,"worldBottomCellY":-64,"waterLevelMeters":11.1,"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func block_request(origin: Vector3i, size: Vector3i, lod := 0) -> Dictionary:
	return {"schema":SCHEMA,"origin":origin,"size":size,"lod":lod}

func edit_state(block_id: String, material_id: int) -> Dictionary:
	return {"materialId":material_id,"biomeId":0,"solid":true,"density":1.35,
		"fluidId":0,"light":Vector2i.ZERO,
		"metadata":{"source":"terrain_edit","terrainMeshAffects":true},
		"blockId":block_id,"editReason":"multi-page-shadow-contract"}

func floor_page(value: int) -> int:
	return floori(float(value) / 280.0)

func verify_direct_generator(backend, generator, origin: Vector3i, size: Vector3i, lod: int, label: String) -> void:
	var buffer := VoxelBuffer.new()
	buffer.create(size.x, size.y, size.z)
	generator._generate_block(buffer, origin, lod)
	var native: Dictionary = backend.encode_voxel_block_shadow(block_request(origin, size, lod))
	if native.get("status") == "pending":
		check(native.get("reason") == "shaping_dependency_unresolved" \
			and not native.has("sdf16Le") and not native.has("indices8") and not native.has("data5_8"),
			"pending classification without invented bytes: %s" % label)
		cases.append({"label":label,"origin":origin,"size":size,"lod":lod,
			"status":"pending","reason":native.get("reason"),"directGodotByteParity":"not_tested_pending"})
		return
	var equal: bool = native.get("status") == "ready" \
		and native.get("sdf16Le") == buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF) \
		and native.get("indices8") == buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_INDICES) \
		and native.get("data5_8") == buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_DATA5)
	check(equal, "direct VoxelTerrainGenerator all-channel byte parity: %s" % label)
	cases.append({"label":label,"origin":origin,"size":size,"lod":lod,
		"status":native.get("status"),"reason":native.get("reason"),"directGodotByteParity":equal})

func verify_case(backend, origin: Vector3i, size: Vector3i, lod: int) -> void:
	var result: Dictionary = backend.encode_voxel_block_shadow(block_request(origin, size, lod))
	var ok: bool = result.get("status") == "ready" and result.get("shadowOnly") == true \
		and result.get("productionCutover") == false and result.get("sdf16Le") is PackedByteArray \
		and result.sdf16Le.size() == size.x * size.y * size.z * 2 \
		and result.indices8.size() == size.x * size.y * size.z \
		and result.data5_8.size() == size.x * size.y * size.z
	check(ok, "ready composite bytes: %s: %s" % [origin, result])
	if not ok:
		cases.append({"origin":origin,"size":size,"lod":lod,"passed":false,"status":result.get("status"),"reason":result.get("reason")})
		return
	var scale := 1 << lod
	for z in range(size.z):
		for x in range(size.x):
			var cell := origin + Vector3i(x * scale, 0, z * scale)
			var key := Vector2i(floor_page(cell.x), floor_page(cell.z))
			var page_result: Dictionary = backend.pin_effective_page(key)
			check(page_result.get("status") == "ready", "single page pin: %s" % key)
			if page_result.get("status") != "ready":
				continue
			var single: Dictionary = page_result.page.encode_voxel_block(block_request(cell, Vector3i(1, size.y, 1), lod))
			check(single.get("status") == "ready", "single page bytes: %s" % cell)
			if single.get("status") != "ready":
				continue
			for y in range(size.y):
				var index := y + size.y * (x + size.x * z)
				check(result.sdf16Le[2 * index] == single.sdf16Le[2 * y] \
					and result.sdf16Le[2 * index + 1] == single.sdf16Le[2 * y + 1] \
					and result.indices8[index] == single.indices8[y] \
					and result.data5_8[index] == single.data5_8[y], "stitch bytes: %s/%d" % [cell,y])
	cases.append({"origin":origin,"size":size,"lod":lod,"passed":ok,
		"primaryPageCount":result.get("primaryPageCount"),"shapingPageCount":result.get("shapingPageCount")})

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "native backend class")
	if backend == null:
		quit(1)
		return
	check(backend.initialize(source_request()).get("status") == "ready", "initialize")
	verify_case(backend, Vector3i(-1, -1, -1), Vector3i(2, 2, 2), 0)
	verify_case(backend, Vector3i(279, 0, 279), Vector3i(2, 1, 2), 0)
	var pending_lod: Dictionary = backend.encode_voxel_block_shadow(
		block_request(Vector3i(-281, 0, -281), Vector3i(3, 1, 3), 10))
	check(pending_lod.get("status") == "pending" \
		and pending_lod.get("reason") == "shaping_dependency_unresolved" \
		and not pending_lod.has("sdf16Le") and not pending_lod.has("indices8"),
		"unresolved X/Z LOD pages remain retryable without fake air")
	cases.append({"origin":Vector3i(-281, 0, -281),"size":Vector3i(3, 1, 3),"lod":10,
		"status":pending_lod.get("status"),"reason":pending_lod.get("reason"),
		"proves":"pending admission only; pure-core tests cover ready skipped-page stitching"})
	var oracle_world: Dictionary = Oracle.build_world("atlas-1492")
	check(bool(oracle_world.get("ok", false)), "direct generator oracle setup")
	if bool(oracle_world.get("ok", false)):
		var generator = Generator.new()
		generator.setup(oracle_world.context)
		var buffer := VoxelBuffer.new()
		buffer.create(2, 2, 2)
		generator._generate_block(buffer, Vector3i(-1, -1, -1), 0)
		var direct: Dictionary = backend.encode_voxel_block_shadow(
			block_request(Vector3i(-1, -1, -1), Vector3i(2, 2, 2)))
		check(direct.get("status") == "ready" \
			and direct.get("sdf16Le") == buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF) \
			and direct.get("indices8") == buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_INDICES) \
			and direct.get("data5_8") == buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_DATA5),
			"direct VoxelTerrainGenerator X/Z seam byte parity")
		var full_origin := Vector3i(-16, 0, -16)
		var full_size := Vector3i.ONE * 16
		var full_buffer := VoxelBuffer.new()
		full_buffer.create(16, 16, 16)
		generator._generate_block(full_buffer, full_origin, 0)
		var full_native: Dictionary = backend.encode_voxel_block_shadow(
			block_request(full_origin, full_size))
		var full_equal: bool = full_native.get("status") == "ready" \
			and full_native.get("sdf16Le") == full_buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF) \
			and full_native.get("indices8") == full_buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_INDICES) \
			and full_native.get("data5_8") == full_buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_DATA5)
		check(full_equal, "direct VoxelTerrainGenerator full 16-cubed byte parity")
		cases.append({"origin":full_origin,"size":full_size,"lod":0,
			"directGodotByteParity":full_equal})
		# 1960 is the first cell of page 7; nearby lattice products expose
		# Godot Vector3 float32 rounding and source-cell remapping.
		for specification in [
			["negative-page-seam-full16-lod1", Vector3i(-288, 0, -288), Vector3i.ONE * 16, 1],
			["negative-page-seam-lod1", Vector3i(-281, -1, -281), Vector3i(2, 2, 2), 1],
			["positive-page-seam-lod1", Vector3i(279, 0, 279), Vector3i(2, 1, 2), 1],
			["float32-remap-positive-lod0", Vector3i(1959, -1, 1959), Vector3i(2, 2, 2), 0],
			["float32-remap-negative-lod0", Vector3i(-1961, -1, -1961), Vector3i(2, 2, 2), 0],
			["float32-remap-positive-lod1", Vector3i(1959, -1, 1959), Vector3i(2, 2, 2), 1],
			["float32-remap-negative-lod1", Vector3i(-1961, -1, -1961), Vector3i(2, 2, 2), 1],
		]:
			verify_direct_generator(backend, generator, specification[1], specification[2],
				specification[3], specification[0])
	var seam_request := block_request(Vector3i(-1, 0, -1), Vector3i(2, 1, 2))
	var before: Dictionary = backend.encode_voxel_block_shadow(seam_request)
	var tx := {"schema":"n3-native-typed-cell-transaction/v1",
		"transactionId":"multi-page-shadow-contract:two-seam-edits","expectedRevision":0,
		"operations":[
			{"namespace":"durable_terrain","kind":"set","cell":Vector3i(-1,0,-1),
				"state":edit_state("multi_page_seam_left",13)},
			{"namespace":"durable_terrain","kind":"set","cell":Vector3i(0,0,0),
				"state":edit_state("multi_page_seam_right",11)}]}
	var commit: Dictionary = backend.commit_typed_cells(tx)
	check(commit.get("status") == "ready" and commit.get("commitStatus") == "committed", "two seam edits commit")
	var after: Dictionary = backend.encode_voxel_block_shadow(seam_request)
	check(before.get("status") == "ready" and after.get("status") == "ready", "before/after seam block")
	if before.get("status") == "ready" and after.get("status") == "ready":
		check(before.get("terrainDeltaRevision") == 0 and after.get("terrainDeltaRevision") == 1,
			"one whole-block delta revision")
		check(before.get("pinIdentity") != after.get("pinIdentity"), "whole-block identity invalidated")
		check(before.get("blockContentIdentity") != after.get("blockContentIdentity"),
			"local block content invalidated by two seam edits")
		check(after.indices8[0] == 13 and after.indices8[3] == 11,
			"both sides of seam use committed materials")
	verify_case(backend, Vector3i(-1, 0, -1), Vector3i(2, 1, 2), 0)
	for invalid in [block_request(Vector3i.ZERO, Vector3i.ZERO),
		block_request(Vector3i.ZERO, Vector3i(33,1,1)), block_request(Vector3i.ZERO, Vector3i.ONE, -1),
		{"schema":"wrong","origin":Vector3i.ZERO,"size":Vector3i.ONE,"lod":0}]:
		var result: Dictionary = backend.encode_voxel_block_shadow(invalid)
		check(result.get("status") == "failed", "invalid request rejected: %s" % invalid)
	var report := {"schema":"native-multi-page-voxel-shadow-contract/v1","passed":failures.is_empty(),
		"evidenceLevel":"shadow-service-byte-contract-only","productionCutover":false,
		"cases":cases,"failures":failures}
	var path := OS.get_environment("VWB_MULTI_PAGE_SHADOW_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)

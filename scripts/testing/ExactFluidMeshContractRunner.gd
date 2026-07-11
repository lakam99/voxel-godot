extends SceneTree

const TerrainMeshingServiceScript := preload("res://scripts/TerrainMeshingService.gd")
const CELL_SIZE := 1.35
const SECTION_SIZE := 16
const EPSILON := 0.001

var report_path := ""
var results: Array[Dictionary] = []
var backend

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_EXACT_FLUID_MESH_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vox43/exact-fluid-mesh-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())

	var service = TerrainMeshingServiceScript.new()
	service.setup(null)
	backend = service.backend
	if backend == null or not backend.has_method("build_chunk_fluid_mesh_from_sections"):
		results.append({
			"name": "native_backend_ready",
			"passed": false,
			"failures": ["TerrainMeshingBackend.build_chunk_fluid_mesh_from_sections is unavailable"]
		})
		finish()
		return

	run_case(
		"single_water_cell",
		payload_for_cells([
			cell_state(Vector3i(0, 2, 0), "water")
		], {"chunkSize": 2, "stepCells": 1}),
		{
			"stepCells": 1,
			"fluidFaces": 6,
			"waterFaces": 6,
			"lavaFaces": 0,
			"surfaceOrder": ["water"],
			"owningCell": Vector3i(0, 2, 0)
		}
	)
	run_case(
		"adjacent_same_fluid_cells",
		payload_for_cells([
			cell_state(Vector3i(0, 2, 0), "water"),
			cell_state(Vector3i(1, 2, 0), "water")
		], {"chunkSize": 2, "stepCells": 1}),
		{
			"stepCells": 1,
			"fluidFaces": 10,
			"waterFaces": 10,
			"lavaFaces": 0,
			"surfaceOrder": ["water"]
		}
	)
	run_case(
		"solid_adjacent_fluid_cell",
		payload_for_cells([
			cell_state(Vector3i(0, 2, 0), "water"),
			cell_state(Vector3i(1, 2, 0), "", true)
		], {"chunkSize": 2, "stepCells": 1}),
		{
			"stepCells": 1,
			"fluidFaces": 5,
			"waterFaces": 5,
			"lavaFaces": 0,
			"surfaceOrder": ["water"]
		}
	)
	run_case(
		"cross_chunk_same_fluid_halo",
		payload_for_cells([
			cell_state(Vector3i(1, 2, 0), "water"),
			cell_state(Vector3i(2, 2, 0), "water")
		], {"chunkSize": 2, "stepCells": 1}),
		{
			"stepCells": 1,
			"fluidFaces": 5,
			"waterFaces": 5,
			"lavaFaces": 0,
			"surfaceOrder": ["water"]
		}
	)
	run_case(
		"water_and_lava_surface_identity",
		payload_for_cells([
			cell_state(Vector3i(0, 2, 0), "water"),
			cell_state(Vector3i(1, 2, 0), "lava")
		], {"chunkSize": 2, "stepCells": 1}),
		{
			"stepCells": 1,
			"waterFacesMinimum": 1,
			"lavaFacesMinimum": 1,
			"surfaceOrder": ["water", "lava"]
		}
	)
	run_case(
		"atlas_71906947_chunk_11_1_coarse_aquifer",
		payload_for_cells([
			cell_state(Vector3i(322, 2, 28), "water")
		], {
			"chunkSize": 28,
			"startX": 308,
			"startZ": 28,
			"stepCells": 14,
			"revision": 0
		}),
		{
			"stepCells": 1,
			"fluidFaces": 6,
			"waterFaces": 6,
			"lavaFaces": 0,
			"surfaceOrder": ["water"],
			"owningCell": Vector3i(322, 2, 28),
			"sourceSeed": "atlas-71906947",
			"sourceChunk": Vector2i(11, 1),
			"observedBrokenStepCells": 14,
			"observedBrokenCubeSizeMeters": 18.9
		}
	)
	finish()

func cell_state(cell: Vector3i, fluid := "", solid := false) -> Dictionary:
	return {
		"cell": cell,
		"fluid": String(fluid),
		"solid": bool(solid)
	}

func payload_for_cells(cells: Array, options: Dictionary) -> Dictionary:
	var sections_by_key := {}
	for value in cells:
		if not (value is Dictionary):
			continue
		append_sparse_cell(sections_by_key, value)
	var sections := []
	for section in sections_by_key.values():
		sections.append(section)
	var start_x := int(options.get("startX", 0))
	var start_z := int(options.get("startZ", 0))
	var chunk_size := int(options.get("chunkSize", 2))
	var step_cells := int(options.get("stepCells", 1))
	return {
		"schemaVersion": 1,
		"sectionSize": SECTION_SIZE,
		"cellSize": CELL_SIZE,
		"chunkSize": chunk_size,
		"chunkX": floori(float(start_x) / float(chunk_size)),
		"chunkZ": floori(float(start_z) / float(chunk_size)),
		"startX": start_x,
		"startZ": start_z,
		"minY": 3,
		"maxY": 3,
		"minCell": Vector3i(start_x - step_cells, 2, start_z - step_cells),
		"maxCell": Vector3i(start_x + chunk_size + step_cells, 4, start_z + chunk_size + step_cells),
		"stepCells": step_cells,
		"revision": int(options.get("revision", 1)),
		"sparse": true,
		"hasFluid": true,
		"sections": sections
	}

func append_sparse_cell(sections_by_key: Dictionary, value: Dictionary) -> void:
	var cell: Vector3i = value.get("cell", Vector3i.ZERO)
	var section_key := Vector3i(
		floori(float(cell.x) / float(SECTION_SIZE)),
		floori(float(cell.y) / float(SECTION_SIZE)),
		floori(float(cell.z) / float(SECTION_SIZE))
	)
	var key_text := "%d,%d,%d" % [section_key.x, section_key.y, section_key.z]
	var section: Dictionary = sections_by_key.get(key_text, {
		"sectionKey": section_key,
		"sectionSize": SECTION_SIZE,
		"channelSchema": 1,
		"revision": 1,
		"sparse": true,
		"channels": empty_sparse_channels()
	})
	var local := Vector3i(
		posmod(cell.x, SECTION_SIZE),
		posmod(cell.y, SECTION_SIZE),
		posmod(cell.z, SECTION_SIZE)
	)
	var cell_index := local.x + SECTION_SIZE * (local.y + SECTION_SIZE * local.z)
	var channels: Dictionary = section.get("channels", {})
	var sparse_indices: PackedInt32Array = channels.get("sparseCellIndices", PackedInt32Array())
	var sparse_lookup: Dictionary = channels.get("sparseIndexByCellIndex", {})
	var packed_index := sparse_indices.size()
	sparse_indices.append(cell_index)
	sparse_lookup[cell_index] = packed_index
	var solid := bool(value.get("solid", false))
	var fluid := String(value.get("fluid", ""))
	var material := "stone" if solid else (fluid if fluid != "" else "air")
	append_string_channel(channels, "blockIds", material)
	append_string_channel(channels, "materialIds", material)
	append_string_channel(channels, "biomeIds", "underground_air")
	append_string_channel(channels, "fluidIds", fluid)
	append_byte_channel(channels, "solid", 1 if solid else 0)
	append_byte_channel(channels, "skyLight", 0)
	append_byte_channel(channels, "blockLight", 0)
	append_float_channel(channels, "density", CELL_SIZE if solid else -CELL_SIZE)
	append_float_channel(channels, "surfaceY", float(cell.y) * CELL_SIZE)
	channels["sparseCellIndices"] = sparse_indices
	channels["sparseIndexByCellIndex"] = sparse_lookup
	section["channels"] = channels
	sections_by_key[key_text] = section

func empty_sparse_channels() -> Dictionary:
	return {
		"sparseCellIndices": PackedInt32Array(),
		"sparseIndexByCellIndex": {},
		"blockIds": PackedStringArray(),
		"materialIds": PackedStringArray(),
		"biomeIds": PackedStringArray(),
		"fluidIds": PackedStringArray(),
		"solid": PackedByteArray(),
		"skyLight": PackedByteArray(),
		"blockLight": PackedByteArray(),
		"density": PackedFloat32Array(),
		"surfaceY": PackedFloat32Array()
	}

func append_string_channel(channels: Dictionary, name: String, value: String) -> void:
	var values: PackedStringArray = channels.get(name, PackedStringArray())
	values.append(value)
	channels[name] = values

func append_byte_channel(channels: Dictionary, name: String, value: int) -> void:
	var values: PackedByteArray = channels.get(name, PackedByteArray())
	values.append(value)
	channels[name] = values

func append_float_channel(channels: Dictionary, name: String, value: float) -> void:
	var values: PackedFloat32Array = channels.get(name, PackedFloat32Array())
	values.append(value)
	channels[name] = values

func run_case(name: String, payload: Dictionary, expected: Dictionary) -> void:
	var mesh_value = backend.call("build_chunk_fluid_mesh_from_sections", payload)
	if not (mesh_value is Mesh):
		results.append({
			"name": name,
			"passed": false,
			"failures": ["native backend did not return a Mesh"],
			"expected": json_safe(expected)
		})
		return
	var mesh := mesh_value as Mesh
	var summary := mesh_summary(mesh)
	var failures: Array[String] = []
	check_equal(failures, "nativeFluidStepCells", int(summary.get("nativeFluidStepCells", -1)), int(expected.get("stepCells", 1)))
	if expected.has("fluidFaces"):
		check_equal(failures, "chunk_fluid_faces", int(summary.get("fluidFaces", -1)), int(expected.get("fluidFaces", -1)))
	if expected.has("waterFaces"):
		check_equal(failures, "chunk_water_faces", int(summary.get("waterFaces", -1)), int(expected.get("waterFaces", -1)))
	if expected.has("lavaFaces"):
		check_equal(failures, "chunk_lava_faces", int(summary.get("lavaFaces", -1)), int(expected.get("lavaFaces", -1)))
	if expected.has("waterFacesMinimum") and int(summary.get("waterFaces", 0)) < int(expected.get("waterFacesMinimum", 0)):
		failures.append("chunk_water_faces expected at least %d, got %d" % [int(expected.get("waterFacesMinimum", 0)), int(summary.get("waterFaces", 0))])
	if expected.has("lavaFacesMinimum") and int(summary.get("lavaFaces", 0)) < int(expected.get("lavaFacesMinimum", 0)):
		failures.append("chunk_lava_faces expected at least %d, got %d" % [int(expected.get("lavaFacesMinimum", 0)), int(summary.get("lavaFaces", 0))])
	var expected_order := PackedStringArray(expected.get("surfaceOrder", []))
	var actual_order: PackedStringArray = summary.get("surfaceOrder", PackedStringArray())
	if actual_order != expected_order:
		failures.append("terrainFluidSurfaceOrder expected %s, got %s" % [str(expected_order), str(actual_order)])
	if not bool(summary.get("verticesOnExactCellBoundaries", false)):
		failures.append("fluid geometry contains vertices away from exact cell boundaries")
	if expected.has("owningCell"):
		var owning_cell: Vector3i = expected.get("owningCell", Vector3i.ZERO)
		var start_x := int(payload.get("startX", 0))
		var start_z := int(payload.get("startZ", 0))
		var expected_min := Vector3(
			float(owning_cell.x - start_x) * CELL_SIZE,
			float(owning_cell.y) * CELL_SIZE,
			float(owning_cell.z - start_z) * CELL_SIZE
		)
		var expected_max := expected_min + Vector3.ONE * CELL_SIZE
		var actual_min: Vector3 = summary.get("boundsMin", Vector3.ZERO)
		var actual_max: Vector3 = summary.get("boundsMax", Vector3.ZERO)
		if not vector_approx_equal(actual_min, expected_min) or not vector_approx_equal(actual_max, expected_max):
			failures.append("geometry bounds expected %s..%s, got %s..%s" % [str(expected_min), str(expected_max), str(actual_min), str(actual_max)])
	results.append({
		"name": name,
		"passed": failures.is_empty(),
		"failures": failures,
		"payload": {
			"stepCells": int(payload.get("stepCells", -1)),
			"startX": int(payload.get("startX", 0)),
			"startZ": int(payload.get("startZ", 0)),
			"chunkSize": int(payload.get("chunkSize", 0)),
			"sectionCount": (payload.get("sections", []) as Array).size()
		},
		"expected": json_safe(expected),
		"actual": json_safe(summary)
	})

func mesh_summary(mesh: Mesh) -> Dictionary:
	var vertex_count := 0
	var has_vertices := false
	var bounds_min := Vector3(INF, INF, INF)
	var bounds_max := Vector3(-INF, -INF, -INF)
	var exact_boundaries := true
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		vertex_count += vertices.size()
		for vertex in vertices:
			has_vertices = true
			bounds_min = bounds_min.min(vertex)
			bounds_max = bounds_max.max(vertex)
			if not coordinate_on_cell_boundary(vertex.x) or not coordinate_on_cell_boundary(vertex.y) or not coordinate_on_cell_boundary(vertex.z):
				exact_boundaries = false
	if not has_vertices:
		bounds_min = Vector3.ZERO
		bounds_max = Vector3.ZERO
	var order_value = mesh.get_meta("terrainFluidSurfaceOrder", PackedStringArray())
	var surface_order: PackedStringArray = order_value if order_value is PackedStringArray else PackedStringArray()
	return {
		"terrainMeshingBackend": String(mesh.get_meta("terrainMeshingBackend", "")),
		"terrainFluidSectionPayload": bool(mesh.get_meta("terrainFluidSectionPayload", false)),
		"nativeFluidStepCells": int(mesh.get_meta("nativeFluidStepCells", -1)),
		"fluidFaces": int(mesh.get_meta("chunk_fluid_faces", -1)),
		"waterFaces": int(mesh.get_meta("chunk_water_faces", -1)),
		"lavaFaces": int(mesh.get_meta("chunk_lava_faces", -1)),
		"surfaceCount": mesh.get_surface_count(),
		"surfaceOrder": surface_order,
		"vertexCount": vertex_count,
		"boundsMin": bounds_min,
		"boundsMax": bounds_max,
		"boundsSize": bounds_max - bounds_min,
		"verticesOnExactCellBoundaries": exact_boundaries
	}

func coordinate_on_cell_boundary(value: float) -> bool:
	var cell_coordinate := value / CELL_SIZE
	return absf(cell_coordinate - roundf(cell_coordinate)) <= EPSILON

func vector_approx_equal(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) <= EPSILON

func check_equal(failures: Array[String], label: String, actual: int, expected: int) -> void:
	if actual != expected:
		failures.append("%s expected %d, got %d" % [label, expected, actual])

func all_passed() -> bool:
	for result in results:
		if not bool(result.get("passed", false)):
			return false
	return true

func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func json_safe(value):
	if value is Vector3i:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Vector2i:
		return {"x": value.x, "z": value.y}
	if value is Vector3:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is PackedStringArray:
		return Array(value)
	if value is Array:
		var array_result := []
		for item in value:
			array_result.append(json_safe(item))
		return array_result
	if value is Dictionary:
		var dictionary_result := {}
		for key in value.keys():
			dictionary_result[key] = json_safe(value[key])
		return dictionary_result
	return value

func finish() -> void:
	var report := {
		"schemaVersion": 1,
		"runnerId": "exact_fluid_mesh_contract",
		"testId": "vox_43_exact_fluid_mesh_contract",
		"finished": true,
		"passed": all_passed(),
		"evidenceLevel": "contract",
		"scope": "Native production sparse-section fluid mesh contract. This is not headed visual acceptance.",
		"resultCount": results.size(),
		"failureCount": failure_count(),
		"results": json_safe(results)
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify(report, "  "))
	quit(0 if bool(report.get("passed", false)) else 1)

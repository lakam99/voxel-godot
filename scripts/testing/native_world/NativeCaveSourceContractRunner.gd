extends SceneTree

const CONTEXT := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const GENERATION := preload("res://scripts/WorldGenerationSystem.gd")
const CELL := 1.35
const PAGE_CELLS := 280
const SEED := "cave-contract-417"

var failures: Array[String] = []
var evidence := {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var world = _make_world(SEED)
	var recipe: Dictionary = {}
	for z in range(-2, 3):
		for x in range(-2, 3):
			recipe = world.cave_recipe_for_region(Vector2i(x, z))
			if not recipe.is_empty():
				break
		if not recipe.is_empty():
			break
	_require(not recipe.is_empty(), "reference_recipe_missing")
	if recipe.is_empty():
		_finish()
		return

	_require(ClassDB.class_exists("NativeWorldBackend"), "native_world_backend_class_missing")
	if not ClassDB.class_exists("NativeWorldBackend"):
		_finish()
		return
	var backend = ClassDB.instantiate("NativeWorldBackend")
	var initialized: Dictionary = backend.initialize(_initialization_request())
	_require(initialized.get("status") == "ready", "native_backend_initialize_failed")
	if initialized.get("status") != "ready":
		evidence["initialization"] = initialized
		_finish()
		return

	var route_indices := [0, 2, 4, 6]
	var queries_by_page := {}
	var route_surfaces: Array = []
	for route_index in route_indices:
		var floor_point: Vector3 = recipe.route[route_index]
		var route_surface := float(world.terrain_reference_surface_y_at(floor_point))
		route_surfaces.append({"routeIndex": route_index, "floorY": floor_point.y,
			"referenceSurfaceY": route_surface, "overburdenMeters": route_surface - floor_point.y})
		var floor_cell := _cell_at(floor_point)
		var page_key := _page_for(floor_cell)
		var page_name := _page_name(page_key)
		if not queries_by_page.has(page_name):
			queries_by_page[page_name] = {"key": page_key, "queries": [], "labels": [], "projections": []}
		var group: Dictionary = queries_by_page[page_name]
		for query in [
			{"label": "floor_%d" % route_index, "cell": floor_cell + Vector3i(0, -1, 0), "kind": "floor"},
			{"label": "body_low_%d" % route_index, "cell": floor_cell + Vector3i(0, 1, 0), "kind": "body"},
			{"label": "body_high_%d" % route_index, "cell": floor_cell + Vector3i(0, 2, 0), "kind": "body"},
		]:
			query["expectedDensity"] = _script_density_at_cell(world, query.cell)
			group.queries.append(query)
		var projection := {"startCell": floor_cell, "maxUpCells": 4, "maxDownCells": 8,
			"intent": "gameplay", "semanticRevision": 1}
		group.projections.append({"label": "route_%d" % route_index, "floorPoint": floor_point,
			"query": projection})
	var roof_probe := Vector3.INF
	var roof_surface_y := NAN
	for chamber in recipe.chambers:
		var center: Vector3 = chamber.center
		var radii: Vector3 = chamber.radii
		var candidate_probe := center + Vector3.UP * (radii.y + 3.0)
		var surface_y := float(world.terrain_reference_surface_y_at(candidate_probe))
		if surface_y - candidate_probe.y >= CELL:
			roof_probe = candidate_probe
			roof_surface_y = surface_y
			break
	_require(roof_probe != Vector3.INF, "recipe_has_no_chamber_roof_probe_with_overburden")
	if roof_probe != Vector3.INF:
		var roof_cell := _cell_at(roof_probe)
		var roof_page := _page_for(roof_cell)
		var roof_page_name := _page_name(roof_page)
		if not queries_by_page.has(roof_page_name):
			queries_by_page[roof_page_name] = {"key": roof_page, "queries": [], "labels": [], "projections": []}
		queries_by_page[roof_page_name].queries.append({"label": "interior_roof",
			"cell": roof_cell, "kind": "roof", "worldPosition": roof_probe,
			"referenceSurfaceY": roof_surface_y,
			"expectedDensity": _script_density_at_cell(world, roof_cell)})
	var deep_noise_samples: Array[Dictionary] = []
	var deep_noise_air_samples := 0
	var deep_noise_solid_samples := 0
	# The authored recipe itself is shallower than the deep-noise threshold for
	# this region. Probe a bounded grid elsewhere in the same 192 m region so
	# this contract covers the target field's deep 3D density component too.
	for z_step in range(-7, 8):
		for x_step in range(-7, 8):
			if deep_noise_air_samples >= 8 and deep_noise_solid_samples >= 8:
				break
			var x := float(recipe.region.x) * 192.0 + float(x_step) * 12.0
			var z := float(recipe.region.y) * 192.0 + float(z_step) * 12.0
			var surface_y := float(world.terrain_reference_surface_y_at(Vector3(x, 0.0, z)))
			var cell := _cell_at(Vector3(x, surface_y - 34.0, z))
			var lattice_position := Vector3(cell) * CELL
			var lattice_base_surface_y := float(world.terrain_reference_surface_y_at(lattice_position))
			var depth := lattice_base_surface_y - lattice_position.y
			if depth <= 28.0 or recipe.bounds.has_point(lattice_position):
				continue
			var density := _script_density_at_cell(world, cell)
			if density < 0.0 and deep_noise_air_samples >= 8:
				continue
			if density > 0.0 and deep_noise_solid_samples >= 8:
				continue
			if is_zero_approx(density):
				continue
			var sample_key := "%d,%d,%d" % [cell.x, cell.y, cell.z]
			if deep_noise_samples.any(func(row): return String(row.key) == sample_key):
				continue
			if density < 0.0:
				deep_noise_air_samples += 1
			else:
				deep_noise_solid_samples += 1
			deep_noise_samples.append({"key": sample_key, "cell": cell,
				"position": lattice_position, "depthMeters": depth,
				"expectedDensity": density})
			var page_key := _page_for(cell)
			var page_name := _page_name(page_key)
			if not queries_by_page.has(page_name):
				queries_by_page[page_name] = {"key": page_key, "queries": [], "labels": [], "projections": []}
			queries_by_page[page_name].queries.append({"label": "deep_noise_%s" % sample_key,
				"cell": cell, "kind": "deep_noise", "expectedDensity": density,
				"depthMeters": depth})
	_require(deep_noise_air_samples > 0, "deep_noise_air_probe_not_found")
	_require(deep_noise_solid_samples > 0, "deep_noise_solid_probe_not_found")

	var page_evidence := {}
	for page_name in queries_by_page:
		var group: Dictionary = queries_by_page[page_name]
		var readiness: Dictionary = backend.shaping_requests(group.key)
		var pin_result: Dictionary = backend.pin_effective_page(group.key)
		var page = pin_result.get("page")
		_require(readiness.get("status") == "ready", "native_shaping_not_ready:%s" % page_name)
		_require(pin_result.get("status") == "ready" and page != null, "native_page_pin_failed:%s" % page_name)
		if page == null:
			page_evidence[page_name] = {"readiness": readiness, "pin": pin_result}
			continue
		var lattice_queries: Array = []
		for query in group.queries:
			lattice_queries.append({"coordinate": query.cell, "intent": "terrain_mesh"})
		var batch: Dictionary = page.sample_batch({
			"schema": "n3-effective-terrain-batch-request/v1",
			"surfaceColumns": [], "cellCenters": [], "latticeNumeric": lattice_queries,
			"worldNumeric": [], "surfaceProjectionNumeric": [],
		})
		_require(batch.get("status") == "ready", "native_cave_sample_batch_failed:%s" % page_name)
		var samples: Array = batch.get("latticeNumeric", [])
		for index in range(mini(samples.size(), group.queries.size())):
			var expected: Dictionary = group.queries[index]
			var sample: Dictionary = samples[index]
			var density := float(sample.get("density", NAN))
			if expected.has("expectedDensity"):
				_require(absf(density - float(expected.expectedDensity)) <= 0.01,
					"%s_density_mismatch:native=%.6f:script=%.6f" % [expected.label, density, float(expected.expectedDensity)])
			if expected.kind == "floor":
				_require(density > 0.0, "%s_not_solid:%.5f" % [expected.label, density])
			elif expected.kind == "body":
				_require(density < 0.0, "%s_not_clear:%.5f" % [expected.label, density])
			elif expected.kind == "roof":
				_require(density > 0.0, "interior_roof_not_solid:%.5f" % density)
			group.labels.append({"label": expected.label, "coordinate": expected.cell,
				"density": density, "expectedDensity": expected.get("expectedDensity", NAN),
				"depthMeters": expected.get("depthMeters", NAN),
				"undergroundAirVoid": sample.get("undergroundAirVoid", false)})
		if not group.projections.is_empty():
			var projection_request := {"schema": "n3-effective-terrain-projection-batch-request/v1",
				"surfaceProjections": [], "walkableProjections": [], "knownHeightProjections": []}
			for row in group.projections:
				projection_request.walkableProjections.append(row.query)
			var projections: Dictionary = page.project_surfaces(projection_request)
			_require(projections.get("status") == "ready", "native_cave_projection_failed:%s" % page_name)
			var walkable_rows: Array = projections.get("walkableProjections", [])
			for index in range(mini(walkable_rows.size(), group.projections.size())):
				var result: Dictionary = walkable_rows[index]
				var floor_point: Vector3 = group.projections[index].floorPoint
				var position: Vector3 = result.get("position", Vector3.INF)
				var walkable := bool(result.get("walkable", false))
				_require(bool(result.get("found", false)) and walkable,
					"native_route_not_walkable:%s" % group.projections[index].label)
				if position != Vector3.INF:
					_require(absf(position.y - floor_point.y) <= CELL * 2.0,
						"native_route_floor_displaced:%s" % group.projections[index].label)
				group.projections[index]["result"] = result
		var encoded_route_cell := _cell_at(recipe.route[2]) + Vector3i(0, -1, 0)
		if group.key == _page_for(encoded_route_cell):
			var block_origin := _block_origin(encoded_route_cell)
			var encoded: Dictionary = page.encode_voxel_block({
				"schema": "n3-effective-voxel-block-request/v1",
				"origin": block_origin, "size": Vector3i.ONE * 16, "lod": 0,
			})
			_require(encoded.get("status") == "ready", "native_cave_voxel_block_encode_failed:%s" % page_name)
			if encoded.get("status") != "ready":
				group["voxelBlock"] = encoded
			if encoded.get("status") == "ready":
				_require(encoded.sdf16Le.size() == 16 * 16 * 16 * 2,
					"native_cave_voxel_sdf_size_invalid")
				for query in group.queries:
					if query.kind not in ["floor", "body"] or not _inside_block(block_origin, query.cell):
						continue
					var encoded_sdf := _encoded_sdf_at(encoded.sdf16Le, block_origin, query.cell)
					if query.kind == "floor":
						_require(encoded_sdf < 0, "%s_encoded_as_air:%d" % [query.label, encoded_sdf])
					else:
						_require(encoded_sdf > 0, "%s_encoded_as_solid:%d" % [query.label, encoded_sdf])
				group["voxelBlock"] = {"status": encoded.status,
					"origin": encoded.origin, "size": encoded.size,
					"sdfBytes": encoded.sdf16Le.size(), "materialBytes": encoded.indices8.size(),
					"pinIdentity": encoded.pinIdentity,
					"blockContentIdentity": encoded.blockContentIdentity,
					"routeSdfSamples": group.queries.filter(func(query):
						return query.kind in ["floor", "body"] and _inside_block(block_origin, query.cell)).map(
						func(query): return {"label": query.label,
							"rawSdf16": _encoded_sdf_at(encoded.sdf16Le, block_origin, query.cell)})}
		page_evidence[page_name] = {"readiness": readiness, "pin": pin_result,
			"sampleBatch": batch, "samples": group.labels, "projections": group.projections,
			"voxelBlock": group.get("voxelBlock", {})}

	evidence = {"seed": SEED, "recipeRegion": recipe.region, "entry": recipe.entry,
		"route": recipe.route, "routeSurfaces": route_surfaces,
		"roofProbe": roof_probe, "roofSurfaceY": roof_surface_y,
		"deepNoiseParitySamples": deep_noise_samples,
		"deepNoiseAirSampleCount": deep_noise_air_samples,
		"deepNoiseSolidSampleCount": deep_noise_solid_samples,
		"regionBounds": recipe.bounds, "nativePages": page_evidence}
	_finish()


func _make_world(seed_value: String):
	var context = CONTEXT.new()
	context.seed_text = seed_value
	context.seed_hash = context.hash_string(seed_value)
	context.setup_noise()
	var generation = GENERATION.new()
	generation.setup(context)
	context.set_generator(generation)
	return generation


func _initialization_request() -> Dictionary:
	return {"schema": "n3-native-world-backend-initialize/v1", "seedText": SEED,
		"revisions": {"sourceSchema": 2, "terrainGenerator": 1, "biomeRegionField": 2,
			"latticeQuery": 1, "cellCenterQuery": 1, "surfaceColumnQuery": 1},
		"constants": {"cellSizeMeters": CELL, "cellCenterOffsetCells": 0.5,
			"worldBottomCellY": -64, "waterLevelMeters": 11.1,
			"minimumSurfaceMeters": 4.0, "maximumSurfaceMeters": 120.0},
		"sitePolicy": {"sourcePolicyRevision": 1, "surveyGenerationPolicyRevision": 1,
			"ordinaryRegionCells": 140, "ordinarySpawnChance": 0.08, "townOverrides": []}}


func _cell_at(point: Vector3) -> Vector3i:
	return Vector3i(floori(point.x / CELL), floori(point.y / CELL), floori(point.z / CELL))


func _script_density_at_cell(world, cell: Vector3i) -> float:
	var position := Vector3(cell) * CELL
	var surface_y := float(world.terrain_deformed_surface_y_at(position))
	var base_surface_y := float(world.terrain_reference_surface_y_at(position))
	return float(world.density_from_components(position, surface_y, base_surface_y))


func _page_for(cell: Vector3i) -> Vector2i:
	return Vector2i(floori(float(cell.x) / PAGE_CELLS), floori(float(cell.z) / PAGE_CELLS))


func _page_name(page: Vector2i) -> String:
	return "%d,%d" % [page.x, page.y]


func _block_origin(cell: Vector3i) -> Vector3i:
	return Vector3i(floori(float(cell.x) / 16.0) * 16,
		floori(float(cell.y) / 16.0) * 16, floori(float(cell.z) / 16.0) * 16)


func _inside_block(origin: Vector3i, cell: Vector3i) -> bool:
	return cell.x >= origin.x and cell.y >= origin.y and cell.z >= origin.z \
		and cell.x < origin.x + 16 and cell.y < origin.y + 16 and cell.z < origin.z + 16


func _encoded_sdf_at(bytes: PackedByteArray, origin: Vector3i, cell: Vector3i) -> int:
	var local := cell - origin
	var index := local.y + 16 * (local.x + 16 * local.z)
	var bits := int(bytes.decode_u16(index * 2))
	return bits if bits < 32768 else bits - 65536


func _require(value: bool, reason: String) -> void:
	if not value:
		failures.append(reason)


func _finish() -> void:
	var report := {"schema": "native-cave-source-contract/v1", "passed": failures.is_empty(),
		"failures": failures, "evidence": evidence,
		"evidenceLevel": "native effective-terrain adapter contract; not headed gameplay acceptance",
		"proves": ["native recipe-derived floor/body/roof samples", "deep-noise density parity", "walkable projections along recipe route"],
		"doesNotProve": ["live collision publication", "player traversal", "visual mesh continuity or screenshot acceptance"]}
	var report_path := OS.get_environment("NATIVE_CAVE_SOURCE_REPORT").strip_edges()
	if not report_path.is_empty():
		DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))	
	print("NATIVE_CAVE_SOURCE_CONTRACT passed=", report.passed,
		" failures=", JSON.stringify(failures), " report=", report_path)
	quit(0 if failures.is_empty() else 1)

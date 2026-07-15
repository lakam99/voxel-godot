extends SceneTree

const MANIFEST_PATH := "res://assets/visual/generated/visual-manifest.json"
const CANOPY_FAMILIES := {
	"mature_broadleaf_tree": true,
	"old_growth_broadleaf_tree": true,
	"mature_conifer_tree": true,
	"mature_savanna_tree": true,
}
const VisualAssetRegistryScript := preload("res://scripts/visual/VisualAssetRegistry.gd")

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_CANOPY_IMPORT_CONTRACT_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/canopy-asset-import-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var manifest := read_json(MANIFEST_PATH)
	var canopy_assets := select_canopy_assets(manifest)
	add_result("manifest_exposes_dormant_canopy_asset_set", int(manifest.get("schemaVersion", 0)) == 2 and canopy_assets.size() == 13 and all_runtime_disabled(canopy_assets), {
		"schemaVersion": manifest.get("schemaVersion", 0),
		"assetIds": asset_ids(canopy_assets),
		"runtimeEnabled": runtime_states(canopy_assets),
	})
	var imported_rows: Array[Dictionary] = []
	var import_errors: Array[String] = []
	for asset in canopy_assets:
		var row := import_asset(asset, import_errors)
		if not row.is_empty():
			imported_rows.append(row)
	add_result("godot_imports_all_canopy_glbs", import_errors.is_empty() and imported_rows.size() == 13, {
		"importedCount": imported_rows.size(),
		"errors": import_errors,
	})
	add_result("import_preserves_geometry_material_and_grounding_contract", rows_all_true(imported_rows, ["triangleCountMatches", "materialsMatch", "heightMatches", "grounded"]), compact_rows(imported_rows, ["id", "triangleCount", "height", "materials", "triangleCountMatches", "materialsMatch", "heightMatches", "grounded"]))
	add_result("import_preserves_wind_vertex_color_contract", rows_all_true(imported_rows, ["allSurfacesHaveColor", "hasRootWeight", "hasCrownWeight", "hasFlutterWeight", "alphaReserved"]), compact_rows(imported_rows, ["id", "coloredVertexCount", "bendRange", "flutterRange", "alphaRange", "allSurfacesHaveColor", "hasRootWeight", "hasCrownWeight", "hasFlutterWeight", "alphaReserved"]))
	add_result("canopy_assets_remain_static_meshes", rows_all_true(imported_rows, ["staticOnly"]), compact_rows(imported_rows, ["id", "skeletonCount", "animationPlayerCount", "staticOnly"]))
	var registry = VisualAssetRegistryScript.new()
	var registry_ready: bool = registry.setup()
	var dormant_ids_present: Array[String] = []
	for asset in canopy_assets:
		var asset_id := String(asset.get("id", ""))
		if registry.assets_by_id.has(asset_id) or registry.scene_cache.has(asset_id):
			dormant_ids_present.append(asset_id)
	add_result("runtime_registry_excludes_vox120_canopy_assets", registry_ready and registry.asset_count() == 26 and registry.cached_scene_count() == 26 and dormant_ids_present.is_empty(), {
		"registryReady": registry_ready,
		"assetCount": registry.asset_count(),
		"cachedSceneCount": registry.cached_scene_count(),
		"dormantIdsPresent": dormant_ids_present,
		"errors": registry.last_errors,
	})
	finish(imported_rows)

func select_canopy_assets(manifest: Dictionary) -> Array[Dictionary]:
	var selected: Array[Dictionary] = []
	for asset_variant in manifest.get("assets", []):
		if asset_variant is Dictionary:
			var asset: Dictionary = asset_variant
			if CANOPY_FAMILIES.has(String(asset.get("family", ""))):
				selected.append(asset)
	selected.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	return selected

func import_asset(asset: Dictionary, errors: Array[String]) -> Dictionary:
	var asset_id := String(asset.get("id", ""))
	var resource_path := "res://%s" % String(asset.get("path", ""))
	var absolute_path := ProjectSettings.globalize_path(resource_path)
	if not FileAccess.file_exists(absolute_path):
		errors.append("%s missing %s" % [asset_id, absolute_path])
		return {}
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var import_error := document.append_from_file(absolute_path, state)
	if import_error != OK:
		errors.append("%s GLTFDocument import failed: %s" % [asset_id, error_string(import_error)])
		return {}
	var instance := document.generate_scene(state)
	if instance == null:
		errors.append("%s generated no scene" % asset_id)
		return {}
	root.add_child(instance)
	var meshes: Array[MeshInstance3D] = []
	collect_meshes(instance, meshes)
	if meshes.size() != 1 or meshes[0].mesh == null:
		errors.append("%s expected one imported mesh, got %d" % [asset_id, meshes.size()])
		instance.queue_free()
		return {}
	var mesh_instance := meshes[0]
	var mesh := mesh_instance.mesh
	var bounds := transformed_aabb(mesh_instance.global_transform, mesh.get_aabb())
	var colors := inspect_colors(mesh)
	var materials := imported_material_names(mesh)
	var expected_materials := string_array(asset.get("materialSlots", []))
	var imported_triangles := triangle_count(mesh)
	var expected_height := float(asset.get("treeMetrics", {}).get("height", 0.0))
	var row := {
		"id": asset_id,
		"triangleCount": imported_triangles,
		"triangleCountMatches": imported_triangles == int(asset.get("triangleCount", -1)),
		"height": snappedf(bounds.size.y, 0.0001),
		"heightMatches": absf(bounds.size.y - expected_height) <= 0.02,
		"grounded": absf(bounds.position.y) <= 0.08,
		"materials": materials,
		"materialsMatch": materials == expected_materials,
		"coloredVertexCount": colors.coloredVertexCount,
		"allSurfacesHaveColor": bool(colors.allSurfacesHaveColor),
		"bendRange": colors.bendRange,
		"flutterRange": colors.flutterRange,
		"alphaRange": colors.alphaRange,
		"hasRootWeight": float(colors.bendRange[0]) <= 0.01,
		"hasCrownWeight": float(colors.bendRange[1]) >= 0.95,
		"hasFlutterWeight": float(colors.flutterRange[1]) >= 0.75,
		"alphaReserved": float(colors.alphaRange[0]) >= 0.99 and float(colors.alphaRange[1]) <= 1.001,
		"skeletonCount": count_nodes_of_type(instance, "Skeleton3D"),
		"animationPlayerCount": count_nodes_of_type(instance, "AnimationPlayer"),
	}
	row["staticOnly"] = int(row.skeletonCount) == 0 and int(row.animationPlayerCount) == 0
	instance.queue_free()
	return row

func inspect_colors(mesh: Mesh) -> Dictionary:
	var colored_vertex_count := 0
	var surface_count := mesh.get_surface_count()
	var colored_surface_count := 0
	var bend_min := 1.0
	var bend_max := 0.0
	var flutter_min := 1.0
	var flutter_max := 0.0
	var alpha_min := 1.0
	var alpha_max := 0.0
	for surface_index in range(surface_count):
		var arrays := mesh.surface_get_arrays(surface_index)
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		if colors.is_empty():
			continue
		colored_surface_count += 1
		colored_vertex_count += colors.size()
		for color in colors:
			bend_min = minf(bend_min, color.r)
			bend_max = maxf(bend_max, color.r)
			flutter_min = minf(flutter_min, color.b)
			flutter_max = maxf(flutter_max, color.b)
			alpha_min = minf(alpha_min, color.a)
			alpha_max = maxf(alpha_max, color.a)
	return {
		"coloredVertexCount": colored_vertex_count,
		"allSurfacesHaveColor": surface_count > 0 and colored_surface_count == surface_count,
		"bendRange": [snappedf(bend_min, 0.0001), snappedf(bend_max, 0.0001)],
		"flutterRange": [snappedf(flutter_min, 0.0001), snappedf(flutter_max, 0.0001)],
		"alphaRange": [snappedf(alpha_min, 0.0001), snappedf(alpha_max, 0.0001)],
	}

func collect_meshes(node: Node, output: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		output.append(node)
	for child in node.get_children():
		collect_meshes(child, output)

func count_nodes_of_type(node: Node, type_name: String) -> int:
	var count := 1 if node.is_class(type_name) else 0
	for child in node.get_children():
		count += count_nodes_of_type(child, type_name)
	return count

func imported_material_names(mesh: Mesh) -> Array[String]:
	var names: Array[String] = []
	for surface_index in range(mesh.get_surface_count()):
		var material := mesh.surface_get_material(surface_index)
		if material == null:
			continue
		var material_name := material.resource_name
		if material_name == "":
			material_name = material.get_name()
		if material_name != "" and not names.has(material_name):
			names.append(material_name)
	names.sort()
	return names

func triangle_count(mesh: Mesh) -> int:
	var total := 0
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		total += indices.size() / 3 if not indices.is_empty() else vertices.size() / 3
	return total

func transformed_aabb(transform: Transform3D, bounds: AABB) -> AABB:
	var result := AABB()
	var first := true
	for x in [0.0, 1.0]:
		for y in [0.0, 1.0]:
			for z in [0.0, 1.0]:
				var point := bounds.position + Vector3(bounds.size.x * x, bounds.size.y * y, bounds.size.z * z)
				var transformed := transform * point
				if first:
					result = AABB(transformed, Vector3.ZERO)
					first = false
				else:
					result = result.expand(transformed)
	return result

func all_runtime_disabled(assets: Array[Dictionary]) -> bool:
	for asset in assets:
		if bool(asset.get("runtimeEnabled", true)):
			return false
	return true

func rows_all_true(rows: Array[Dictionary], fields: Array[String]) -> bool:
	if rows.size() != 13:
		return false
	for row in rows:
		for field in fields:
			if not bool(row.get(field, false)):
				return false
	return true

func compact_rows(rows: Array[Dictionary], fields: Array[String]) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for row in rows:
		var compact := {}
		for field in fields:
			compact[field] = row.get(field)
		output.append(compact)
	return output

func asset_ids(assets: Array[Dictionary]) -> Array[String]:
	var ids: Array[String] = []
	for asset in assets:
		ids.append(String(asset.get("id", "")))
	return ids

func runtime_states(assets: Array[Dictionary]) -> Dictionary:
	var states := {}
	for asset in assets:
		states[String(asset.get("id", ""))] = bool(asset.get("runtimeEnabled", true))
	return states

func string_array(values: Array) -> Array[String]:
	var output: Array[String] = []
	for value in values:
		output.append(String(value))
	output.sort()
	return output

func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}

func add_result(name: String, passed: bool, details) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func finish(imported_rows: Array[Dictionary]) -> void:
	var failure_count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failure_count += 1
	var report := {
		"schemaVersion": 1,
		"runnerId": "canopy_asset_import_contract",
		"testId": "vox_120_canopy_asset_import_contract",
		"finished": true,
		"passed": failure_count == 0,
		"evidenceLevel": "contract",
		"scope": "Godot GLTF import, static mesh/material/geometry/wind-channel integrity, and runtime-registry dormancy for VOX-120 canopy assets. This is import contract evidence, not live visual or gameplay acceptance.",
		"resultCount": results.size(),
		"failureCount": failure_count,
		"importedAssetCount": imported_rows.size(),
		"results": results,
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify({"runnerId": report.runnerId, "passed": report.passed, "resultCount": report.resultCount, "failureCount": report.failureCount}, "  "))
	quit(0 if failure_count == 0 else 1)

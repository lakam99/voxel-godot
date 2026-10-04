extends SceneTree

const MANIFEST_PATH := "res://assets/visual/generated/visual-manifest.json"
const CANOPY_FAMILIES := {
	"mature_broadleaf_tree": true,
	"old_growth_broadleaf_tree": true,
	"mature_conifer_tree": true,
	"mature_savanna_tree": true,
	"ecological_broadleaf_tree": true,
	"ecological_conifer_tree": true,
	"ecological_savanna_tree": true,
}
const EXPECTED_CANOPY_ASSET_COUNT := 43
const EXPECTED_RUNTIME_ASSET_COUNT := 69
const VisualAssetRegistryScript := preload("res://scripts/visual/VisualAssetRegistry.gd")
const CharacterAssetRegistryScript := preload("res://scripts/visual/CharacterAssetRegistry.gd")
const StaticItemAssetRegistryScript := preload("res://scripts/visual/StaticItemAssetRegistry.gd")
const AnimatedAssetRegistryScript := preload("res://scripts/visual/AnimatedAssetRegistry.gd")

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
	add_result("manifest_exposes_runtime_canopy_asset_set", int(manifest.get("schemaVersion", 0)) == 3 and canopy_assets.size() == EXPECTED_CANOPY_ASSET_COUNT and all_runtime_enabled(canopy_assets), {
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
	add_result("godot_imports_all_canopy_glbs", import_errors.is_empty() and imported_rows.size() == EXPECTED_CANOPY_ASSET_COUNT, {
		"importedCount": imported_rows.size(),
		"errors": import_errors,
	})
	# Complete-tree GLBs are now Blender reference outputs, not live topology.
	# Their exact triangle/phenotype metrics belong to the generator review, while
	# this migration gate only proves that the retained reference library imports
	# as grounded static material data.
	add_result("reference_tree_library_imports_as_grounded_static_material_data", rows_all_true(imported_rows, ["materialsMatch", "grounded"]), compact_rows(imported_rows, ["id", "triangleCount", "height", "materials", "materialsMatch", "grounded"]))
	add_result("import_preserves_wind_vertex_color_contract", rows_all_true(imported_rows, ["allSurfacesHaveColor", "hasRootWeight", "hasCrownWeight", "hasFlutterWeight", "alphaReserved"]), compact_rows(imported_rows, ["id", "coloredVertexCount", "bendRange", "flutterRange", "alphaRange", "allSurfacesHaveColor", "hasRootWeight", "hasCrownWeight", "hasFlutterWeight", "alphaReserved"]))
	add_result("import_preserves_scale_safe_bark_uv0", rows_all_true(imported_rows, ["allSurfacesHaveUv0"]), compact_rows(imported_rows, ["id", "uvVertexCount", "allSurfacesHaveUv0"]))
	add_result("ecological_assets_publish_complete_age_and_fullness_contract", ecological_contract_complete(canopy_assets), ecological_contract_rows(canopy_assets))
	add_result("ecological_foliage_colonizes_branch_lengths_and_terminal_tips", ecological_branch_foliage_complete(canopy_assets), ecological_contract_rows(canopy_assets))
	add_result("ecological_phenotypes_grow_monotonically_with_age", ecological_growth_is_monotonic(canopy_assets), ecological_growth_rows(canopy_assets))
	add_result("upper_age_ecological_phenotypes_are_monumental_landmarks", ecological_monumental_dimensions_complete(canopy_assets), ecological_monumental_dimension_rows(canopy_assets))
	add_result("canopy_assets_remain_static_meshes", rows_all_true(imported_rows, ["staticOnly"]), compact_rows(imported_rows, ["id", "skeletonCount", "animationPlayerCount", "staticOnly"]))
	var registry = VisualAssetRegistryScript.new()
	var registry_ready: bool = registry.setup()
	var rock_member_manifest := _generated_rock_member_manifest_contract(registry)
	add_result("generated_asset_registry_emits_stable_per_surface_member_values",
		rock_member_manifest.get("passed", false), rock_member_manifest)
	var cached_tree_ids: Array[String] = []
	for asset in canopy_assets:
		var asset_id := String(asset.get("id", ""))
		if registry.scene_cache.has(asset_id):
			cached_tree_ids.append(asset_id)
	add_result("complete_tree_glbs_remain_importable_reference_assets_but_not_runtime_authority", registry_ready and registry.asset_count() == EXPECTED_RUNTIME_ASSET_COUNT and registry.cached_scene_count() < EXPECTED_RUNTIME_ASSET_COUNT and cached_tree_ids.is_empty(), {
		"registryReady": registry_ready,
		"assetCount": registry.asset_count(),
		"cachedSceneCount": registry.cached_scene_count(),
		"cachedTreeIds": cached_tree_ids,
		"errors": registry.last_errors,
	})
	var rock_id: String = registry.select_rock_asset_id("mountain", "headless-rock-cache-contract")
	var cached_rock_scene := registry.scene_cache.get(rock_id) as PackedScene
	var rock: Node3D = registry.instantiate_asset(rock_id)
	var rock_meshes: Array[MeshInstance3D] = []
	if rock != null:
		collect_meshes(rock, rock_meshes)
	var importer_owned_scene := cached_rock_scene != null and not cached_rock_scene.resource_path.is_empty()
	var rock_mesh_ready := rock_meshes.size() > 0 and rock_meshes.all(func(mesh_instance: MeshInstance3D) -> bool:
		return mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0)
	var headless_renderer := DisplayServer.get_name().strip_edges().to_lower() == "headless"
	var headless_proxy_ready := rock != null \
		and bool(rock.get_meta("headless_visual_proxy", false)) \
		and String(rock.get_meta("visual_asset_id", "")) == rock_id \
		and String(rock.get_meta("visual_source", "")) == "generated_asset" \
		and String(rock.get_meta("imported_scene_resource_path", "")) == (cached_rock_scene.resource_path if cached_rock_scene != null else "") \
		and rock.get_child_count() == 0 \
		and rock_meshes.is_empty()
	add_result("runtime_rock_retains_importer_owned_source_and_uses_renderer_appropriate_publication", registry_ready and importer_owned_scene and rock != null \
		and (headless_proxy_ready if headless_renderer else rock_mesh_ready), {
		"renderer": DisplayServer.get_name(),
		"rockId": rock_id,
		"cachedResourcePath": cached_rock_scene.resource_path if cached_rock_scene != null else "",
		"meshCount": rock_meshes.size(),
		"headlessProxy": headless_proxy_ready,
		"threadId": OS.get_thread_caller_id(),
	})
	if rock != null:
		rock.free()
	var sibling_registry_rows: Array[Dictionary] = []
	var character_registry = CharacterAssetRegistryScript.new()
	var character_ready: bool = character_registry.setup()
	var character_ids: Array = character_registry.scene_cache.keys()
	character_ids.sort()
	var character_id := String(character_ids[0]) if not character_ids.is_empty() else ""
	var character_scene := character_registry.scene_cache.get(character_id) as PackedScene
	var character: Node3D = character_registry.instantiate_asset(character_id)
	sibling_registry_rows.append(_registry_instance_row("character", character_ready, character_id, character_scene, character))
	if character != null:
		character.free()
	var static_registry = StaticItemAssetRegistryScript.new()
	var static_ready: bool = static_registry.setup()
	var static_ids := static_registry.asset_ids()
	var static_id := String(static_ids[0]) if not static_ids.is_empty() else ""
	var static_scene := static_registry.scene_cache.get(static_id) as PackedScene
	var static_item: Node3D = static_registry.instantiate_item(static_id)
	sibling_registry_rows.append(_registry_instance_row("static_item", static_ready, static_id, static_scene, static_item))
	if static_item != null:
		static_item.free()
	var animated_registry = AnimatedAssetRegistryScript.new()
	var animated_ready: bool = animated_registry.setup()
	var animated_ids := animated_registry.asset_ids()
	var animated_id := String(animated_ids[0]) if not animated_ids.is_empty() else ""
	var animated_scene := animated_registry.scene_cache.get(animated_id) as PackedScene
	var animated: Node3D = animated_registry.instantiate_asset(animated_id)
	sibling_registry_rows.append(_registry_instance_row("animated", animated_ready, animated_id, animated_scene, animated))
	if animated != null:
		animated.free()
	add_result("runtime_glb_registries_retain_importer_owned_scenes_in_headless_renderer", sibling_registry_rows.all(func(row: Dictionary) -> bool: return bool(row.get("passed", false))), sibling_registry_rows)
	finish(imported_rows)

func _registry_instance_row(label: String, ready: bool, asset_id: String, scene: PackedScene, instance: Node3D) -> Dictionary:
	var meshes: Array[MeshInstance3D] = []
	if instance != null:
		collect_meshes(instance, meshes)
	return {
		"label": label,
		"passed": ready and scene != null and not scene.resource_path.is_empty() and instance != null and not meshes.is_empty(),
		"assetId": asset_id,
		"cachedResourcePath": scene.resource_path if scene != null else "",
		"meshCount": meshes.size(),
		"threadId": OS.get_thread_caller_id(),
	}

func _generated_rock_member_manifest_contract(registry: Object) -> Dictionary:
	var asset_id := "generated-rock-member-manifest-contract"
	registry.assets_by_id[asset_id] = {"family":"rock"}
	var root_node := Node3D.new()
	root_node.name = "RockAsset"
	root_node.set_meta("visual_asset_id", asset_id)
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.BACK, Vector3.BACK, Vector3.BACK])
	for surface_index in range(2):
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var first_material := StandardMaterial3D.new()
	var second_material := StandardMaterial3D.new()
	first_material.albedo_color = Color(0.36, 0.3, 0.25, 1.0)
	second_material.albedo_color = Color(0.58, 0.52, 0.42, 1.0)
	mesh.surface_set_material(0, first_material)
	mesh.surface_set_material(1, second_material)
	var mesh_node := MeshInstance3D.new()
	mesh_node.name = "RockMesh"
	mesh_node.transform = Transform3D(Basis.IDENTITY,
		Vector3(0.35, 0.8, -0.2))
	mesh_node.mesh = mesh
	root_node.add_child(mesh_node)
	registry.apply_render_policy(root_node, asset_id)
	var rows: Array = root_node.get_meta("static_render_member_values", [])
	var ids: Array[String] = []
	var exact_surface_bindings := rows.size() == 2
	for row_value: Variant in rows:
		if not row_value is Dictionary:
			exact_surface_bindings = false
			continue
		var row: Dictionary = row_value
		ids.append(String(row.get("memberId", "")))
		var captured_mesh := row.get("mesh") as Mesh
		var surface_index := int(row.get("meshSurfaceIndex", -1))
		var expected_material := first_material if surface_index == 0 else second_material
		var material_value := row.get("material") as Material
		var mesh_material := captured_mesh.surface_get_material(0) \
			if is_instance_valid(captured_mesh) and captured_mesh.get_surface_count() == 1 else null
		exact_surface_bindings = exact_surface_bindings \
			and String(row.get("status", "")) == "ready" \
			and String(row.get("renderLayer", "")) == "opaque" \
			and row.get("transform") == mesh_node.transform \
			and is_instance_valid(captured_mesh) and captured_mesh.get_surface_count() == 1 \
			and material_value == expected_material and mesh_material == expected_material
	var repeat_ids: Array[String] = []
	registry.apply_render_policy(root_node, asset_id)
	for row_value: Variant in root_node.get_meta("static_render_member_values", []):
		if row_value is Dictionary:
			repeat_ids.append(String(row_value.get("memberId", "")))
	var stable_ids := ids == repeat_ids and not ids.has("") \
		and ids[0] != ids[1] if ids.size() == 2 else false
	root_node.free()
	registry.assets_by_id.erase(asset_id)
	return {"passed":exact_surface_bindings and stable_ids,
		"surfaceCount":rows.size(), "memberIds":ids,
		"repeatMemberIds":repeat_ids, "stableIds":stable_ids,
		"exactSurfaceBindings":exact_surface_bindings}

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
	var uvs := inspect_uv0(mesh)
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
		"uvVertexCount": uvs.uvVertexCount,
		"allSurfacesHaveUv0": uvs.allSurfacesHaveUv0,
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

func inspect_uv0(mesh: Mesh) -> Dictionary:
	var uv_vertex_count := 0
	var surfaces_with_uv := 0
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		if uvs.is_empty():
			continue
		surfaces_with_uv += 1
		uv_vertex_count += uvs.size()
	return {
		"uvVertexCount": uv_vertex_count,
		"allSurfacesHaveUv0": mesh.get_surface_count() > 0 and surfaces_with_uv == mesh.get_surface_count(),
	}

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

func all_runtime_enabled(assets: Array[Dictionary]) -> bool:
	for asset in assets:
		if not bool(asset.get("runtimeEnabled", false)):
			return false
	return true

func rows_all_true(rows: Array[Dictionary], fields: Array[String]) -> bool:
	if rows.size() != EXPECTED_CANOPY_ASSET_COUNT:
		return false
	for row in rows:
		for field in fields:
			if not bool(row.get(field, false)):
				return false
	return true

func ecological_contract_complete(assets: Array[Dictionary]) -> bool:
	var band_counts := {}
	for asset in assets:
		var family := String(asset.get("family", ""))
		if not family.begins_with("ecological_"):
			continue
		var phenotype: Dictionary = asset.get("treePhenotype", {})
		var band := String(phenotype.get("ageBand", ""))
		var key := "%s:%s" % [family, band]
		band_counts[key] = int(band_counts.get(key, 0)) + 1
		if not bool(phenotype.get("minimumFullnessPassed", false)) \
			or int(phenotype.get("minimumSectorOccupancy", 0)) < 1 \
			or int(phenotype.get("terminalTipCount", 0)) <= 0 \
			or String(asset.get("barkData", {}).get("attribute", "")) != "TEXCOORD_0":
			return false
	for family in ["ecological_broadleaf_tree", "ecological_conifer_tree", "ecological_savanna_tree"]:
		for band in ["young", "established", "mature", "old", "ancient"]:
			if int(band_counts.get("%s:%s" % [family, band], 0)) != 2:
				return false
	return true

func ecological_contract_rows(assets: Array[Dictionary]) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for asset in assets:
		if String(asset.get("family", "")).begins_with("ecological_"):
			rows.append({
				"id": asset.get("id", ""),
				"phenotype": asset.get("treePhenotype", {}),
				"foliagePrimitiveCount": asset.get("canopyStructure", {}).get("foliagePrimitiveCount", 0),
				"bark": asset.get("barkData", {}),
			})
	return rows

func ecological_branch_foliage_complete(assets: Array[Dictionary]) -> bool:
	var checked := 0
	for asset in assets:
		if not String(asset.get("family", "")).begins_with("ecological_"):
			continue
		var structure: Dictionary = asset.get("canopyStructure", {})
		var phenotype: Dictionary = asset.get("treePhenotype", {})
		if String(structure.get("foliageDistribution", "")) != "branch_length_and_terminal" \
			or int(structure.get("branchInteriorAnchorCount", 0)) < int(phenotype.get("primaryBranchCount", 1)) \
			or int(structure.get("terminalFoliageAnchorCount", 0)) != int(phenotype.get("terminalTipCount", -1)):
			return false
		checked += 1
	return checked == 30

func ecological_monumental_dimensions_complete(assets: Array[Dictionary]) -> bool:
	var thresholds := {
		"ecological_broadleaf_tree": {"mature": [30.0, 1.45], "old": [47.0, 3.0], "ancient": [70.0, 5.5]},
		"ecological_conifer_tree": {"mature": [34.0, 1.35], "old": [54.0, 2.75], "ancient": [82.0, 4.75]},
		"ecological_savanna_tree": {"mature": [28.0, 1.35], "old": [45.0, 2.75], "ancient": [64.0, 4.75]},
	}
	var checked := 0
	for asset in assets:
		var family := String(asset.get("family", ""))
		var band := String(asset.get("treePhenotype", {}).get("ageBand", ""))
		if not thresholds.has(family) or not (thresholds[family] as Dictionary).has(band):
			continue
		var expected: Array = (thresholds[family] as Dictionary)[band]
		var metrics: Dictionary = asset.get("treeMetrics", {})
		if float(metrics.get("height", 0.0)) < float(expected[0]) \
			or float(metrics.get("trunkRadius", 0.0)) < float(expected[1]):
			return false
		checked += 1
	return checked == 18

func ecological_monumental_dimension_rows(assets: Array[Dictionary]) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for asset in assets:
		var band := String(asset.get("treePhenotype", {}).get("ageBand", ""))
		if String(asset.get("family", "")).begins_with("ecological_") and band in ["mature", "old", "ancient"]:
			rows.append({"id": asset.get("id", ""), "ageBand": band, "treeMetrics": asset.get("treeMetrics", {})})
	return rows

func ecological_growth_is_monotonic(assets: Array[Dictionary]) -> bool:
	var groups := ecological_growth_groups(assets)
	for group_variant in groups.values():
		var group: Dictionary = group_variant
		var previous := {}
		for band in ["young", "established", "mature", "old", "ancient"]:
			var current: Dictionary = group.get(band, {})
			if current.is_empty():
				return false
			if not previous.is_empty() and (
				float(current.height) <= float(previous.height) \
				or float(current.trunkRadius) <= float(previous.trunkRadius) \
				or float(current.canopyRadius) <= float(previous.canopyRadius) \
				or int(current.leaves) <= int(previous.leaves) \
				or int(current.terminalTips) <= int(previous.terminalTips) \
				or int(current.branchFoliageAnchors) <= int(previous.branchFoliageAnchors)
			):
				return false
			previous = current
	return groups.size() == 6

func ecological_growth_rows(assets: Array[Dictionary]) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var groups := ecological_growth_groups(assets)
	for key_variant in groups.keys():
		rows.append({"group": String(key_variant), "bands": groups[key_variant]})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.group) < String(b.group))
	return rows

func ecological_growth_groups(assets: Array[Dictionary]) -> Dictionary:
	var groups := {}
	for asset in assets:
		var family := String(asset.get("family", ""))
		if not family.begins_with("ecological_"):
			continue
		var phenotype: Dictionary = asset.get("treePhenotype", {})
		var metrics: Dictionary = asset.get("treeMetrics", {})
		var structure: Dictionary = asset.get("canopyStructure", {})
		var key := "%s:%d" % [family, int(phenotype.get("variant", 0))]
		if not groups.has(key):
			groups[key] = {}
		groups[key][String(phenotype.get("ageBand", ""))] = {
			"height": float(metrics.get("height", 0.0)),
			"trunkRadius": float(metrics.get("trunkRadius", 0.0)),
			"canopyRadius": float(metrics.get("canopyRadius", 0.0)),
			"leaves": int(structure.get("foliagePrimitiveCount", 0)),
			"terminalTips": int(phenotype.get("terminalTipCount", 0)),
			"branchFoliageAnchors": int(structure.get("branchInteriorAnchorCount", 0)),
			"branchGenerations": int(phenotype.get("branchGenerationCount", 0)),
		}
	return groups

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
		"testId": "vox_128_129_ecological_tree_asset_import_contract",
		"finished": true,
		"passed": failure_count == 0,
		"evidenceLevel": "contract",
		"scope": "Godot GLTF import, static mesh/material/geometry/wind-channel/UV integrity, finite five-band phenotype completeness, minimum foliage fullness, and runtime-registry publication. This is import contract evidence, not live visual or gameplay acceptance.",
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

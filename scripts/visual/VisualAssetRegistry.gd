extends RefCounted
class_name VisualAssetRegistry

const MANIFEST_PATH := "res://assets/visual/generated/visual-manifest.json"
const BiomeEnvironmentCatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const TreeRuntimeRequestBuilderScript := preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const TREE_WIND_SHADER := preload("res://resources/visual/tree_wind_material.gdshader")
const TREE_WIND_CULL_MARGIN := 1.25
const INVALID_TREE_CELL := Vector2i(2147483647, 2147483647)
const WIND_TREE_FAMILIES := {
    "broadleaf_tree": true,
    "conifer_tree": true,
    "savanna_tree": true,
    "mature_broadleaf_tree": true,
    "old_growth_broadleaf_tree": true,
    "mature_conifer_tree": true,
    "mature_savanna_tree": true,
    "ecological_broadleaf_tree": true,
    "ecological_conifer_tree": true,
    "ecological_savanna_tree": true
}

var assets_by_id := {}
var assets_by_family := {}
var environment_catalog: BiomeEnvironmentCatalog
var tree_runtime_request_builder
var tree_spawn_service
var scene_cache := {}
var tree_wind_material_cache := {}
var disabled_asset_ids := {}
var last_errors: Array[String] = []
var loaded := false

func setup(catalog: BiomeEnvironmentCatalog = null) -> bool:
    assets_by_id.clear()
    assets_by_family.clear()
    scene_cache.clear()
    tree_wind_material_cache.clear()
    disabled_asset_ids.clear()
    last_errors.clear()
    environment_catalog = catalog
    if environment_catalog == null:
        environment_catalog = BiomeEnvironmentCatalogScript.new()
        environment_catalog.setup()
    tree_runtime_request_builder = TreeRuntimeRequestBuilderScript.new()
    tree_spawn_service = TreeSpawnServiceScript.new()
    # Prewarm shared procedural geometry while the game is still in its loading
    # path. The first streamed tree then cannot pay mesh construction in a
    # player movement frame.
    tree_spawn_service.prewarm_visuals()
    loaded = load_manifest() and cache_asset_scenes()
    return loaded

func load_manifest() -> bool:
    var manifest_text := read_text(MANIFEST_PATH)
    if manifest_text == "":
        last_errors.append("Missing visual manifest %s" % MANIFEST_PATH)
        return false
    var manifest_variant = JSON.parse_string(manifest_text)
    if not (manifest_variant is Dictionary):
        last_errors.append("Invalid visual manifest JSON")
        return false
    var manifest: Dictionary = manifest_variant
    var assets: Array = manifest.get("assets", [])
    for asset_variant in assets:
        if not (asset_variant is Dictionary):
            last_errors.append("Skipping non-dictionary asset row")
            continue
        var asset: Dictionary = asset_variant
        if not bool(asset.get("runtimeEnabled", true)):
            continue
        var asset_id := String(asset.get("id", ""))
        var family := String(asset.get("family", ""))
        if asset_id == "" or family == "":
            last_errors.append("Skipping asset with missing id/family")
            continue
        assets_by_id[asset_id] = asset
        if not assets_by_family.has(family):
            assets_by_family[family] = []
        assets_by_family[family].append(asset_id)
    for family in assets_by_family.keys():
        assets_by_family[family].sort()
    return not assets_by_id.is_empty()

func cache_asset_scenes() -> bool:
    var ok := true
    for asset_id in assets_by_id.keys():
        var asset: Dictionary = assets_by_id[asset_id]
        # Complete tree GLBs are retained as Blender-reference/import assets
        # during migration, but they no longer participate in runtime loading.
        # Natural trees are now recipe-driven from profile + ecology inputs.
        if is_complete_tree_asset(asset):
            continue
        var resource_path := "res://%s" % String(asset.get("path", ""))
        var absolute_path := ProjectSettings.globalize_path(resource_path)
        if not FileAccess.file_exists(absolute_path):
            last_errors.append("%s missing file %s" % [asset_id, absolute_path])
            ok = false
            continue
        # Runtime GLBs are project assets. Keep the importer-owned PackedScene
        # and hydrate nodes from it on the main thread; repacking a generated
        # GLTF tree retains transient render resources after its source tree is
        # freed, which produces invalid RIDs in the headless dummy renderer.
        var packed := ResourceLoader.load(resource_path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE) as PackedScene
        if packed == null:
            last_errors.append("%s imported PackedScene load failed: %s" % [asset_id, resource_path])
            ok = false
            continue
        scene_cache[asset_id] = packed
    return ok

func read_text(path: String) -> String:
    if not FileAccess.file_exists(path):
        return ""
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return ""
    var text := file.get_as_text()
    file.close()
    return text

func is_ready() -> bool:
    return loaded

func asset_count() -> int:
    return assets_by_id.size()

func cached_scene_count() -> int:
    return scene_cache.size()

func cached_asset_ids() -> Array[String]:
    var result: Array[String] = []
    for asset_id_value in scene_cache.keys():
        result.append(String(asset_id_value))
    result.sort()
    return result

func profile_count() -> int:
    return environment_catalog.profile_count() if environment_catalog != null else 0

func select_tree_asset_id(
    biome: String,
    prop_id: String,
    world_cell := INVALID_TREE_CELL,
    world_seed := ""
) -> String:
    var profile := profile_for_biome(biome)
    var families := PackedStringArray(["broadleaf_tree"])
    var ecology := {}
    if profile != null:
        families = profile.get("tree_families")
        ecology = tree_ecology_spec(biome, prop_id, world_cell, world_seed)
        if not ecology.is_empty() and families_contain_ecological_tree(families):
            return select_tree_asset_for_age_band(
                families,
                biome,
                prop_id,
                String(ecology.get("ageBand", "mature"))
            )
        var old_growth_chance := clampf(float(profile.get("old_growth_chance")), 0.0, 1.0)
        if families.has("mature_broadleaf_tree") \
            and old_growth_chance > 0.0 \
            and stable_unit("tree-old-growth:%s:%s" % [biome, prop_id]) < old_growth_chance:
            families = PackedStringArray(["old_growth_broadleaf_tree"])
    return select_asset_id(families, biome, prop_id, "tree")

func tree_ecology_spec(
    biome: String,
    prop_id: String,
    world_cell := INVALID_TREE_CELL,
    world_seed := ""
) -> Dictionary:
    var profile := profile_for_biome(biome) as BiomeEnvironmentProfile
    if profile == null or tree_runtime_request_builder == null:
        return {}
    return tree_runtime_request_builder.sample_ecology(profile, biome, prop_id, world_cell, world_seed)

func families_contain_ecological_tree(families: PackedStringArray) -> bool:
    for family in families:
        if String(family).begins_with("ecological_"):
            return true
    return false

func select_tree_asset_for_age_band(
    families: PackedStringArray,
    biome: String,
    prop_id: String,
    age_band: String
) -> String:
    var candidates: Array[String] = []
    for family in families:
        for id_variant in assets_by_family.get(String(family), []):
            var asset_id := String(id_variant)
            var asset: Dictionary = assets_by_id.get(asset_id, {})
            var tags: Array = asset.get("biomeTags", [])
            var phenotype: Dictionary = asset.get("treePhenotype", {})
            if String(phenotype.get("ageBand", "")) == age_band \
                and (tags.is_empty() or tags.has(biome)):
                candidates.append(asset_id)
    if candidates.is_empty():
        return select_asset_id(families, biome, prop_id, "tree")
    candidates.sort()
    return candidates[stable_index("tree-phenotype:%s:%s:%s" % [biome, age_band, prop_id], candidates.size())]

func select_rock_asset_id(biome: String, prop_id: String) -> String:
    var profile := profile_for_biome(biome)
    var families := PackedStringArray(["rock"])
    if profile != null:
        families = profile.get("rock_families")
    return select_asset_id(families, biome, prop_id, "rock")

func profile_for_biome(biome: String) -> Resource:
    return environment_catalog.profile_for_biome(biome) if environment_catalog != null else null

func select_asset_id(families: PackedStringArray, biome: String, prop_id: String, role: String) -> String:
    var candidates: Array[String] = []
    for family in families:
        var family_ids: Array = assets_by_family.get(String(family), [])
        for id_variant in family_ids:
            var asset_id := String(id_variant)
            var asset: Dictionary = assets_by_id.get(asset_id, {})
            var tags: Array = asset.get("biomeTags", [])
            if tags.is_empty() or tags.has(biome):
                candidates.append(asset_id)
    if candidates.is_empty():
        for family in families:
            var family_ids: Array = assets_by_family.get(String(family), [])
            for id_variant in family_ids:
                candidates.append(String(id_variant))
    if candidates.is_empty():
        return ""
    candidates.sort()
    var index := stable_index("%s:%s:%s" % [role, biome, prop_id], candidates.size())
    return candidates[index]

func instantiate_tree_visual(biome: String, prop_id: String) -> Node3D:
    var node := instantiate_asset(select_tree_asset_id(biome, prop_id))
    configure_tree_wind_instance(node, biome, prop_id)
    return node

func instantiate_procedural_tree_visual(
    biome: String,
    prop_id: String,
    runtime_spec: Dictionary,
    world_seed := ""
) -> Node3D:
    if tree_spawn_service == null:
        return null
    if not is_procedural_tree_family(String(runtime_spec.get("family", ""))):
        return null
    var request := runtime_spec.duplicate(true)
    request["treeId"] = prop_id
    request["biome"] = biome
    request["worldSeed"] = world_seed
    request["presentation"] = "runtime"
    return tree_spawn_service.spawn_tree(request)

func instantiate_rock_visual(biome: String, prop_id: String) -> Node3D:
    return instantiate_asset(select_rock_asset_id(biome, prop_id))

func instantiate_family(family: String, stable_key: String) -> Node3D:
    return instantiate_asset(select_asset_id(PackedStringArray([family]), "", stable_key, family))

func instantiate_asset(asset_id: String) -> Node3D:
    if asset_id == "" or disabled_asset_ids.has(asset_id):
        return null
    var scene := scene_cache.get(asset_id) as PackedScene
    if scene == null:
        return null
    # Imported GLB meshes are renderer presentation, not world or collision
    # authority. Godot's dummy renderer can load and retain the importer-owned
    # PackedScene, but hydrating that scene may hand an imported ArrayMesh RID to
    # an incompatible dummy mesh owner. Preserve deterministic asset selection
    # and source identity headlessly without asking the renderer to publish it.
    if not imported_scene_visual_publication_supported(DisplayServer.get_name()):
        return headless_imported_scene_proxy(asset_id, scene)
    var instance := scene.instantiate()
    var node := instance as Node3D
    if node == null:
        if instance:
            instance.queue_free()
        return null
    node.set_meta("visual_source", "generated_asset")
    node.set_meta("visual_asset_id", asset_id)
    if not bool(node.get_meta("render_policy_preapplied", false)):
        apply_render_policy(node, asset_id)
    return node

static func imported_scene_visual_publication_supported(display_server_name: String) -> bool:
    return display_server_name.strip_edges().to_lower() != "headless"

func headless_imported_scene_proxy(asset_id: String, scene: PackedScene) -> Node3D:
    var proxy := Node3D.new()
    proxy.name = "HeadlessImportedVisualProxy"
    proxy.set_meta("visual_source", "generated_asset")
    proxy.set_meta("visual_asset_id", asset_id)
    proxy.set_meta("headless_visual_proxy", true)
    proxy.set_meta("visual_publication", "headless_imported_scene_proxy")
    proxy.set_meta("imported_scene_resource_path", scene.resource_path if scene != null else "")
    apply_render_policy(proxy, asset_id)
    return proxy

func apply_render_policy(node: Node3D, asset_id: String) -> void:
    var asset: Dictionary = assets_by_id.get(asset_id, {})
    var family := String(asset.get("family", ""))
    var shadow_policy := shadow_policy_for_family(family)
    var visibility_end := visibility_range_for_family(family)
    apply_render_policy_recursive(node, family, shadow_policy, visibility_end)
    node.set_meta("shadow_policy", shadow_policy)
    node.set_meta("visibility_range_end", visibility_end)
    node.set_meta("shared_tree_wind_material", WIND_TREE_FAMILIES.has(family))

func shadow_policy_for_family(family: String) -> int:
    if family == "bush":
        return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func visibility_range_for_family(family: String) -> float:
    match family:
        "broadleaf_tree", "conifer_tree", "savanna_tree":
            return 260.0
        "mature_broadleaf_tree", "mature_conifer_tree", "mature_savanna_tree":
            return 340.0
        "old_growth_broadleaf_tree":
            return 380.0
        "ecological_broadleaf_tree", "ecological_conifer_tree", "ecological_savanna_tree":
            return 440.0
        "rock":
            return 220.0
        "stump_log":
            return 160.0
        "bush":
            return 120.0
    return 180.0

func apply_render_policy_recursive(node: Node, family: String, shadow_policy: int, visibility_end: float) -> void:
    if node is MeshInstance3D:
        var mesh_instance := node as MeshInstance3D
        mesh_instance.cast_shadow = shadow_policy
        mesh_instance.visibility_range_end = visibility_end
        mesh_instance.visibility_range_end_margin = minf(24.0, visibility_end * 0.12)
        mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
        if WIND_TREE_FAMILIES.has(family):
            apply_tree_wind_materials(mesh_instance)
            mesh_instance.extra_cull_margin = TREE_WIND_CULL_MARGIN
        if family == "bush":
            apply_bush_materials(mesh_instance)
    for child in node.get_children():
        apply_render_policy_recursive(child, family, shadow_policy, visibility_end)

func apply_tree_wind_materials(mesh_instance: MeshInstance3D) -> void:
    if mesh_instance.mesh == null:
        return
    for surface_index in range(mesh_instance.mesh.get_surface_count()):
        var source_material := mesh_instance.get_surface_override_material(surface_index)
        if source_material == null:
            source_material = mesh_instance.mesh.surface_get_material(surface_index)
        mesh_instance.set_surface_override_material(surface_index, shared_tree_wind_material(source_material))


func apply_bush_materials(mesh_instance: MeshInstance3D) -> void:
    if mesh_instance.mesh == null:
        return
    for surface_index in range(mesh_instance.mesh.get_surface_count()):
        var source_material := mesh_instance.get_surface_override_material(surface_index)
        if source_material == null:
            source_material = mesh_instance.mesh.surface_get_material(surface_index)
        var role := "leaf_primary"
        if source_material != null:
            role = String(source_material.resource_name).to_lower()
        var material := StandardMaterial3D.new()
        material.resource_name = role
        material.roughness = 0.92
        if "trunk" in role or "stem" in role:
            material.albedo_color = Color(0.18, 0.075, 0.025)
        elif "secondary" in role:
            material.albedo_color = Color(0.13, 0.255, 0.085)
        else:
            material.albedo_color = Color(0.19, 0.34, 0.115)
        mesh_instance.set_surface_override_material(surface_index, material)

func shared_tree_wind_material(source_material: Material) -> ShaderMaterial:
    var role := "tree_default"
    var base_color := Color(0.26, 0.48, 0.22, 1.0)
    var roughness := 0.82
    if source_material != null:
        role = source_material.resource_name.strip_edges()
        if role == "":
            role = "tree_default"
        if source_material is BaseMaterial3D:
            var base_material := source_material as BaseMaterial3D
            base_color = base_material.albedo_color
            roughness = base_material.roughness
    if tree_wind_material_cache.has(role):
        return tree_wind_material_cache[role] as ShaderMaterial
    var material := ShaderMaterial.new()
    material.resource_name = "shared_tree_wind_%s" % role
    material.shader = TREE_WIND_SHADER
    material.set_shader_parameter("base_color", base_color)
    material.set_shader_parameter("roughness", roughness)
    material.set_shader_parameter("main_bend_meters", 0.48)
    material.set_shader_parameter("detail_flutter_meters", 0.075 if foliage_material_role(role) else 0.018)
    var bark_role := role == "trunk" or role == "bark_dark"
    material.set_shader_parameter("bark_enabled", 1.0 if bark_role else 0.0)
    material.set_shader_parameter("bark_accent_color", base_color.darkened(0.30) if bark_role else base_color)
    material.set_shader_parameter("bark_grain_contrast", 0.34 if role == "trunk" else 0.46)
    tree_wind_material_cache[role] = material
    return material

func foliage_material_role(role: String) -> bool:
    return role.begins_with("leaf_") or role.begins_with("needle_") or role == "savanna_leaf"

func configure_tree_wind_instance(node: Node3D, biome: String, prop_id: String, visual_scale := 1.0) -> void:
    if node == null:
        return
    var profile := profile_for_biome(biome)
    var response := clampf(float(profile.get("wind_response")) if profile != null else 1.0, 0.0, 2.0)
    var phase := stable_unit("tree-wind-phase:%s:%s" % [biome, prop_id]) * TAU
    var variation := stable_unit("tree-wind-stiffness:%s:%s" % [biome, prop_id])
    var stiffness := clampf(1.18 - response * 0.18 + variation * 0.22, 0.68, 1.32)
    var bark_scale := maxf(0.1, float(visual_scale))
    configure_tree_wind_instance_recursive(node, phase, stiffness, response, bark_scale)
    node.set_meta("tree_wind_phase", phase)
    node.set_meta("tree_wind_stiffness", stiffness)
    node.set_meta("tree_wind_response", response)
    node.set_meta("tree_bark_scale", bark_scale)

func configure_tree_wind_instance_recursive(node: Node, phase: float, stiffness: float, response: float, bark_scale: float) -> void:
    if node is MeshInstance3D:
        var mesh_instance := node as MeshInstance3D
        mesh_instance.set_instance_shader_parameter("tree_phase", phase)
        mesh_instance.set_instance_shader_parameter("tree_stiffness", stiffness)
        mesh_instance.set_instance_shader_parameter("tree_response", response)
        mesh_instance.set_instance_shader_parameter("bark_scale", Vector2(bark_scale, bark_scale))
    for child in node.get_children():
        configure_tree_wind_instance_recursive(child, phase, stiffness, response, bark_scale)

func tree_wind_material_count() -> int:
    return tree_wind_material_cache.size()

func tree_wind_material_roles() -> Array[String]:
    var roles: Array[String] = []
    for role_variant in tree_wind_material_cache.keys():
        roles.append(String(role_variant))
    roles.sort()
    return roles

func asset_size(asset_id: String) -> Vector3:
    var asset: Dictionary = assets_by_id.get(asset_id, {})
    var bounds: Dictionary = asset.get("boundingBox", {})
    var size: Array = bounds.get("size", [])
    if size.size() < 3:
        return Vector3.ONE
    return Vector3(float(size[0]), float(size[1]), float(size[2]))

func asset_record(asset_id: String) -> Dictionary:
    var asset: Dictionary = assets_by_id.get(asset_id, {})
    return asset.duplicate(true)

func tree_runtime_spec(
    biome: String,
    prop_id: String,
    fallback_height := 4.0,
    world_cell := INVALID_TREE_CELL,
    world_seed := ""
) -> Dictionary:
    var profile := profile_for_biome(biome)
    if profile == null or tree_runtime_request_builder == null:
        return {}
    return tree_runtime_request_builder.build(profile, biome, prop_id, fallback_height, world_cell, world_seed)

func tree_biome_parameters(profile: BiomeEnvironmentProfile) -> Dictionary:
    return TreeRuntimeRequestBuilderScript.biome_parameters_for_profile(profile)

func select_tree_family(profile: BiomeEnvironmentProfile, biome: String, prop_id: String, world_seed: String) -> String:
    return TreeRuntimeRequestBuilderScript.select_tree_family(profile, biome, prop_id, world_seed)

func architecture_for_tree_family(family: String) -> String:
    return TreeRuntimeRequestBuilderScript.architecture_for_tree_family(family)

func species_grammar_for_tree(family: String, biome: String, prop_id: String, world_seed: String) -> String:
    # The registry turns ecology into a request; canonical grammar authority lives
    # in TreeSpawnService so the PoC and the live world cannot silently diverge.
    return TreeSpawnServiceScript.grammar_for_architecture(architecture_for_tree_family(family))

func is_procedural_tree_family(family: String) -> bool:
    return architecture_for_tree_family(family) != ""

func is_complete_tree_asset(asset: Dictionary) -> bool:
    return is_procedural_tree_family(String(asset.get("family", "")))

func tree_scale_for_biome(biome: String) -> float:
    var profile := profile_for_biome(biome)
    return float(profile.get("tree_scale")) if profile else 1.0

func rock_scale_for_biome(biome: String) -> float:
    var profile := profile_for_biome(biome)
    return float(profile.get("rock_scale")) if profile else 1.0

func disable_asset_for_test(asset_id: String) -> void:
    if asset_id != "":
        disabled_asset_ids[asset_id] = true

func clear_test_disabled_assets() -> void:
    disabled_asset_ids.clear()

func stable_index(text: String, modulo: int) -> int:
    if modulo <= 0:
        return 0
    return abs(stable_hash(text)) % modulo

func stable_unit(text: String) -> float:
    return float(abs(stable_hash(text)) % 100000) / 100000.0

func stable_hash(text: String) -> int:
    var h := 2166136261
    for i in range(text.length()):
        h = int((h ^ text.unicode_at(i)) * 16777619) & 0xffffffff
    return h

extends SceneTree

const MANIFEST_PATH := "res://assets/visual/generated/visual-manifest.json"
const REPORT_PATH := "res://assets/visual/generated/godot-import-check.json"

func _init() -> void:
    var report := run_checks()
    write_json(ProjectSettings.globalize_path(REPORT_PATH), report)
    if not bool(report.get("passed", false)):
        for error in report.get("errors", []):
            printerr("[FAIL] %s" % String(error))
        quit(1)
        return
    print("Godot imported %d generated assets" % int(report.get("checked", 0)))
    quit(0)

func run_checks() -> Dictionary:
    var errors: Array[String] = []
    var rows: Array[Dictionary] = []
    var manifest := read_json(ProjectSettings.globalize_path(MANIFEST_PATH))
    if manifest.is_empty():
        return { "passed": false, "checked": 0, "errors": ["missing or invalid manifest"], "assets": [] }
    var assets: Array = manifest.get("assets", [])
    for asset_value in assets:
        if not (asset_value is Dictionary):
            errors.append("asset row is not a Dictionary")
            continue
        var asset: Dictionary = asset_value
        var result := validate_asset(asset, errors)
        if not result.is_empty():
            rows.append(result)
    return {
        "passed": errors.is_empty(),
        "checked": rows.size(),
        "errors": errors,
        "assets": rows
    }

func validate_asset(asset: Dictionary, errors: Array[String]) -> Dictionary:
    var asset_id := String(asset.get("id", ""))
    var resource_path := "res://%s" % String(asset.get("path", ""))
    var absolute_path := ProjectSettings.globalize_path(resource_path)
    if not FileAccess.file_exists(absolute_path):
        errors.append("%s: missing GLB file %s" % [asset_id, absolute_path])
        return {}
    var document := GLTFDocument.new()
    var state := GLTFState.new()
    var import_error := document.append_from_file(absolute_path, state)
    if import_error != OK:
        errors.append("%s: GLTFDocument import failed with %s" % [asset_id, str(import_error)])
        return {}
    var instance := document.generate_scene(state)
    if instance == null:
        errors.append("%s: GLTFDocument did not generate a scene" % asset_id)
        return {}
    var meshes: Array[MeshInstance3D] = []
    collect_meshes(instance, meshes)
    if meshes.size() != 1:
        errors.append("%s: expected one MeshInstance3D, got %d" % [asset_id, meshes.size()])
        instance.queue_free()
        return {}
    var mesh_instance := meshes[0]
    var mesh := mesh_instance.mesh
    if mesh == null:
        errors.append("%s: imported MeshInstance3D has no mesh" % asset_id)
        instance.queue_free()
        return {}

    var bounds := transformed_aabb(mesh_instance.transform, mesh.get_aabb())
    var material_names := imported_material_names(mesh)
    var expected_materials: Array = asset.get("materialSlots", [])
    for expected in expected_materials:
        if not material_names.has(String(expected)):
            errors.append("%s: missing imported material %s in %s" % [asset_id, String(expected), str(material_names)])

    var family := String(asset.get("family", ""))
    var height := bounds.size.y
    var horizontal := maxf(bounds.size.x, bounds.size.z)
    if absf(bounds.position.y) > 0.08:
        errors.append("%s: imported pivot is not ground-centered, min y %.3f" % [asset_id, bounds.position.y])
    if height <= 0.08 or horizontal <= 0.04:
        errors.append("%s: imported bounds are degenerate %s" % [asset_id, str(bounds.size)])
    if family.ends_with("_tree") and (height < 2.2 or height > 7.8):
        errors.append("%s: tree imported at unexpected height %.3f" % [asset_id, height])
    if family == "rock" and (height < 0.18 or height > 1.8):
        errors.append("%s: rock imported at unexpected height %.3f" % [asset_id, height])
    if family == "bush" and (height < 0.18 or height > 1.8):
        errors.append("%s: bush imported at unexpected height %.3f" % [asset_id, height])
    if family == "stump_log" and (height < 0.18 or height > 1.8):
        errors.append("%s: stump/log imported at unexpected height %.3f" % [asset_id, height])

    var imported_triangles := triangle_count(mesh)
    var manifest_triangles := int(asset.get("triangleCount", -1))
    if imported_triangles != manifest_triangles:
        errors.append("%s: triangle count changed on import %d vs manifest %d" % [asset_id, imported_triangles, manifest_triangles])

    var result := {
        "id": asset_id,
        "path": resource_path,
        "family": family,
        "meshInstances": meshes.size(),
        "triangleCount": imported_triangles,
        "materials": material_names,
        "bounds": {
            "position": vec3(bounds.position),
            "size": vec3(bounds.size)
        },
        "grounded": absf(bounds.position.y) <= 0.08
    }
    instance.queue_free()
    return result

func collect_meshes(node: Node, result: Array[MeshInstance3D]) -> void:
    if node is MeshInstance3D:
        result.append(node)
    for child in node.get_children():
        collect_meshes(child, result)

func imported_material_names(mesh: Mesh) -> Array[String]:
    var result: Array[String] = []
    for surface in range(mesh.get_surface_count()):
        var material := mesh.surface_get_material(surface)
        if material == null:
            continue
        var material_name := material.resource_name
        if material_name == "":
            material_name = material.get_name()
        if material_name != "" and not result.has(material_name):
            result.append(material_name)
    return result

func triangle_count(mesh: Mesh) -> int:
    var total := 0
    for surface in range(mesh.get_surface_count()):
        var arrays := mesh.surface_get_arrays(surface)
        var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
        var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
        if indices.size() > 0:
            total += indices.size() / 3
        else:
            total += vertices.size() / 3
    return total

func transformed_aabb(transform: Transform3D, aabb: AABB) -> AABB:
    var first := true
    var result := AABB()
    for x in [0.0, 1.0]:
        for y in [0.0, 1.0]:
            for z in [0.0, 1.0]:
                var point := aabb.position + Vector3(aabb.size.x * x, aabb.size.y * y, aabb.size.z * z)
                var transformed := transform * point
                if first:
                    result = AABB(transformed, Vector3.ZERO)
                    first = false
                else:
                    result = result.expand(transformed)
    return result

func read_json(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {}
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {}
    var text := file.get_as_text()
    file.close()
    var parsed = JSON.parse_string(text)
    return parsed if parsed is Dictionary else {}

func write_json(path: String, value: Dictionary) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        printerr("Could not write %s" % path)
        return
    file.store_string(JSON.stringify(value, "  "))
    file.store_string("\n")
    file.close()

func vec3(value: Vector3) -> Dictionary:
    return {
        "x": snappedf(value.x, 0.001),
        "y": snappedf(value.y, 0.001),
        "z": snappedf(value.z, 0.001)
    }

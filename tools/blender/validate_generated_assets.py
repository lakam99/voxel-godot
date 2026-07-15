import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


TREE_FAMILIES = {
    "broadleaf_tree",
    "conifer_tree",
    "savanna_tree",
    "mature_broadleaf_tree",
    "old_growth_broadleaf_tree",
    "mature_conifer_tree",
    "mature_savanna_tree",
    "ecological_broadleaf_tree",
    "ecological_conifer_tree",
    "ecological_savanna_tree",
}
CANOPY_FAMILIES = {
    "mature_broadleaf_tree",
    "old_growth_broadleaf_tree",
    "mature_conifer_tree",
    "mature_savanna_tree",
    "ecological_broadleaf_tree",
    "ecological_conifer_tree",
    "ecological_savanna_tree",
}
CANOPY_MAX_HEIGHT = {
    "ecological_broadleaf_tree": 46.0,
    "ecological_conifer_tree": 48.0,
    "ecological_savanna_tree": 38.0,
}
CANOPY_MAX_WIDTH = {
    "old_growth_broadleaf_tree": 18.0,
    "ecological_broadleaf_tree": 40.0,
    "ecological_conifer_tree": 22.0,
    "ecological_savanna_tree": 42.0,
}


def parse_args():
    parser = argparse.ArgumentParser(description="Validate generated GLB assets through Blender import.")
    parser.add_argument("--manifest", required=True, help="Path to assets/visual/generated/visual-manifest.json")
    parser.add_argument("--project-root", required=True, help="Godot project root.")
    parser.add_argument("--output", default="", help="Optional validation report JSON path.")
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(args)


def reset_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for mesh in list(bpy.data.meshes):
        if mesh.users == 0:
            bpy.data.meshes.remove(mesh)
    for material in list(bpy.data.materials):
        if material.users == 0:
            bpy.data.materials.remove(material)
    for image in list(bpy.data.images):
        if image.users == 0:
            bpy.data.images.remove(image)


def fail(errors, asset_id, message):
    errors.append(f"{asset_id}: {message}")


def mesh_objects():
    return [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]


def imported_bounds(meshes):
    vertices = []
    for obj in meshes:
        vertices.extend([obj.matrix_world @ vertex.co for vertex in obj.data.vertices])
    if not vertices:
        return Vector((0, 0, 0)), Vector((0, 0, 0))
    min_v = Vector((min(v.x for v in vertices), min(v.y for v in vertices), min(v.z for v in vertices)))
    max_v = Vector((max(v.x for v in vertices), max(v.y for v in vertices), max(v.z for v in vertices)))
    return min_v, max_v


def snap(value):
    return round(float(value), 4)


def close(a, b, tolerance):
    return abs(float(a) - float(b)) <= tolerance


def material_names(meshes):
    names = []
    for obj in meshes:
        for slot in obj.material_slots:
            if slot.material and slot.material.name not in names:
                names.append(slot.material.name)
    return names


def triangle_count(meshes):
    return sum(len(obj.data.polygons) for obj in meshes)


def validate_asset(asset, manifest, project_root, allowed_materials, errors):
    asset_id = str(asset.get("id", ""))
    rel_path = str(asset.get("path", ""))
    glb_path = project_root / rel_path
    if not glb_path.exists():
        fail(errors, asset_id, f"missing GLB {glb_path}")
        return None
    if glb_path.stat().st_size <= 1024:
        fail(errors, asset_id, f"GLB too small: {glb_path.stat().st_size} bytes")
        return None

    reset_scene()
    bpy.ops.import_scene.gltf(filepath=str(glb_path))
    meshes = mesh_objects()
    if len(meshes) != 1:
        fail(errors, asset_id, f"expected one imported mesh, got {len(meshes)}")
        return None

    obj = meshes[0]
    if obj.data is None or len(obj.data.vertices) == 0:
        fail(errors, asset_id, "zero-size mesh")
    if not close(obj.location.x, 0.0, 0.005) or not close(obj.location.y, 0.0, 0.005) or not close(obj.location.z, 0.0, 0.005):
        fail(errors, asset_id, f"pivot not at origin: {tuple(obj.location)}")
    if not close(obj.scale.x, 1.0, 0.005) or not close(obj.scale.y, 1.0, 0.005) or not close(obj.scale.z, 1.0, 0.005):
        fail(errors, asset_id, f"unapplied scale: {tuple(obj.scale)}")
    if abs(obj.rotation_euler.x) > 0.005 or abs(obj.rotation_euler.y) > 0.005 or abs(obj.rotation_euler.z) > 0.005:
        fail(errors, asset_id, f"unapplied rotation: {tuple(obj.rotation_euler)}")

    min_v, max_v = imported_bounds(meshes)
    size = max_v - min_v
    if min_v.z < -0.055 or min_v.z > 0.055:
        fail(errors, asset_id, f"not ground-centered, min z {min_v.z:.4f}")
    if size.z <= 0.08 or size.x <= 0.04 or size.y <= 0.04:
        fail(errors, asset_id, f"degenerate bounds size {tuple(size)}")
    family = str(asset.get("family", ""))
    max_height = CANOPY_MAX_HEIGHT.get(family, 22.5 if family in CANOPY_FAMILIES else 7.5)
    max_width = CANOPY_MAX_WIDTH.get(family, 16.0 if family in CANOPY_FAMILIES else 4.5)
    if size.z > max_height or size.x > max_width or size.y > max_width:
        fail(errors, asset_id, f"unexpectedly large bounds size {tuple(size)}")

    triangles = triangle_count(meshes)
    expected_triangles = int(asset.get("triangleCount", -1))
    limit = int(asset.get("triangleLimit", manifest.get("triangleLimit", 2200)))
    if triangles <= 0:
        fail(errors, asset_id, "zero triangles")
    if triangles > limit:
        fail(errors, asset_id, f"triangle count {triangles} exceeds limit {limit}")
    if expected_triangles != triangles:
        fail(errors, asset_id, f"triangle count drift {expected_triangles} manifest vs {triangles} import")

    names = material_names(meshes)
    unexpected = [name for name in names if name not in allowed_materials]
    if unexpected:
        fail(errors, asset_id, f"unexpected materials {unexpected}")
    expected_slots = [str(name) for name in asset.get("materialSlots", [])]
    missing_slots = [name for name in expected_slots if name not in names]
    if missing_slots:
        fail(errors, asset_id, f"missing material slots after import {missing_slots}")

    if family in TREE_FAMILIES:
        bark_data = asset.get("barkData", {})
        if bark_data.get("attribute") != "TEXCOORD_0" or bark_data.get("mapping") != "branch_local_circumference_u_physical_length_v":
            fail(errors, asset_id, "missing scale-safe branch-local bark UV contract")
        if not obj.data.uv_layers:
            fail(errors, asset_id, "missing imported TEXCOORD_0 bark UV data")
        if family.startswith("ecological_"):
            phenotype = asset.get("treePhenotype", {})
            if phenotype.get("ageBand") not in {"young", "established", "mature", "old", "ancient"}:
                fail(errors, asset_id, "missing ecological age-band phenotype")
            if not phenotype.get("minimumFullnessPassed", False):
                fail(errors, asset_id, "ecological phenotype failed minimum fullness")
            if int(phenotype.get("terminalTipCount", 0)) <= 0:
                fail(errors, asset_id, "ecological phenotype has no terminal tips")

    family = str(asset.get("family", ""))
    color_attributes = list(obj.data.color_attributes)
    if family in TREE_FAMILIES:
        if not color_attributes:
            fail(errors, asset_id, "missing imported vertex color wind data")
        else:
            color_attribute = color_attributes[0]
            colors = [tuple(value.color) for value in color_attribute.data]
            if colors:
                bend_max = max(color[0] for color in colors)
                phase_range = max(color[1] for color in colors) - min(color[1] for color in colors)
                flutter_max = max(color[2] for color in colors)
                if color_attribute.domain == "POINT":
                    root_colors = [colors[vertex.index][0] for vertex in obj.data.vertices if (vertex.co.z - min_v.z) / max(0.001, size.z) <= 0.08]
                elif color_attribute.domain == "CORNER":
                    root_colors = [colors[loop.index][0] for loop in obj.data.loops if (obj.data.vertices[loop.vertex_index].co.z - min_v.z) / max(0.001, size.z) <= 0.08]
                else:
                    root_colors = []
                    fail(errors, asset_id, f"unsupported imported wind color domain {color_attribute.domain}")
                if root_colors and max(root_colors) > 0.035:
                    fail(errors, asset_id, f"imported root bend exceeds immobility budget: {max(root_colors):.4f}")
                if bend_max < 0.45 or phase_range < 0.20 or flutter_max < 0.50:
                    fail(errors, asset_id, f"imported wind channel range is not useful: bend={bend_max:.3f} phase={phase_range:.3f} flutter={flutter_max:.3f}")
    if any(obj.type == "ARMATURE" for obj in bpy.context.scene.objects):
        fail(errors, asset_id, "imported GLB contains an armature")
    if obj.data.shape_keys is not None:
        fail(errors, asset_id, "imported GLB contains shape keys")
    if bpy.data.actions:
        fail(errors, asset_id, f"imported GLB contains {len(bpy.data.actions)} animation actions")

    manifest_box = asset.get("boundingBox", {})
    manifest_size = manifest_box.get("size", [0, 0, 0])
    actual_size = [snap(size.x), snap(size.y), snap(size.z)]
    for index, axis in enumerate(["x", "y", "z"]):
        if not close(actual_size[index], float(manifest_size[index]), 0.02):
            fail(errors, asset_id, f"bounding size {axis} drift {manifest_size[index]} manifest vs {actual_size[index]} import")

    return {
        "id": asset_id,
        "path": rel_path,
        "triangles": triangles,
        "materials": names,
        "bounds": {
            "min": [snap(min_v.x), snap(min_v.y), snap(min_v.z)],
            "max": [snap(max_v.x), snap(max_v.y), snap(max_v.z)],
            "size": actual_size,
        },
        "pivotAtOrigin": close(obj.location.length, 0.0, 0.005),
        "grounded": abs(float(min_v.z)) <= 0.055,
        "vertexColorAttributes": [{"name": attribute.name, "domain": attribute.domain, "count": len(attribute.data)} for attribute in color_attributes],
        "armatures": sum(1 for scene_obj in bpy.context.scene.objects if scene_obj.type == "ARMATURE"),
        "shapeKeys": 1 if obj.data.shape_keys is not None else 0,
        "animationActions": len(bpy.data.actions),
    }


def main():
    args = parse_args()
    manifest_path = Path(args.manifest).resolve()
    project_root = Path(args.project_root).resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assets = manifest.get("assets", [])
    allowed_materials = set(str(name) for name in manifest.get("materialVocabulary", []))
    errors = []
    checked = []

    if not assets:
        errors.append("manifest has no assets")

    for asset in assets:
        result = validate_asset(asset, manifest, project_root, allowed_materials, errors)
        if result:
            checked.append(result)

    family_counts = {}
    for asset in assets:
        family = str(asset.get("family", ""))
        family_counts[family] = family_counts.get(family, 0) + 1
    for family, expected_count in manifest.get("families", {}).items():
        if int(family_counts.get(family, 0)) != int(expected_count):
            errors.append(f"family {family} count mismatch {family_counts.get(family, 0)} vs {expected_count}")

    report = {
        "passed": len(errors) == 0,
        "checked": len(checked),
        "errors": errors,
        "assets": checked,
    }
    if args.output:
        output_path = Path(args.output).resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    if errors:
        for error in errors:
            print(f"[FAIL] {error}")
        raise SystemExit(1)
    print(f"Validated {len(checked)} generated assets through Blender import")


if __name__ == "__main__":
    main()

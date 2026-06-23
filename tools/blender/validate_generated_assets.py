import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


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
    if size.z > 7.5 or size.x > 4.5 or size.y > 4.5:
        fail(errors, asset_id, f"unexpectedly large bounds size {tuple(size)}")

    triangles = triangle_count(meshes)
    expected_triangles = int(asset.get("triangleCount", -1))
    limit = int(manifest.get("triangleLimit", 2200))
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

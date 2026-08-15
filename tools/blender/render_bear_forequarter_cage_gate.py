import argparse
import json
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--review-root", required=True)
    parser.add_argument("--object-name", default="BrownBear_ForequarterSubdivisionCage")
    return parser.parse_args(sys.argv[sys.argv.index("--") + 1 :])


def look_at(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def configure_material(material, base_color, metallic=0.0, roughness=0.55):
    material.use_nodes = True
    principled = material.node_tree.nodes.get("Principled BSDF")
    principled.inputs["Base Color"].default_value = (*base_color, 1.0)
    principled.inputs["Metallic"].default_value = metallic
    principled.inputs["Roughness"].default_value = roughness


def main():
    args = parse_args()
    root = Path(args.review_root)
    root.mkdir(parents=True, exist_ok=True)
    cage = bpy.data.objects[args.object_name]

    for obj in bpy.context.scene.objects:
        if obj.type in {"MESH", "CURVE"}:
            obj.hide_render = obj != cage and not obj.name.startswith("ToeGuide_")

    configure_material(bpy.data.materials["CageSkin"], (0.035, 0.09, 0.14), metallic=0.05, roughness=0.72)
    configure_material(bpy.data.materials["CageWireMaterial"], (1.0, 0.19, 0.025), metallic=0.0, roughness=0.38)
    if "AnatomyGuide" in bpy.data.materials:
        configure_material(bpy.data.materials["AnatomyGuide"], (1.0, 0.72, 0.03), metallic=0.0, roughness=0.32)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1024
    scene.render.resolution_y = 1024
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.006, 0.009, 0.014)

    bpy.ops.object.light_add(type="AREA", location=(3.8, -4.8, 5.6))
    key = bpy.context.object
    key.name = "CageGate_Key"
    key.data.energy = 1050.0
    key.data.shape = "DISK"
    key.data.size = 4.0
    look_at(key, (0.0, -0.2, 0.85))

    bpy.ops.object.light_add(type="AREA", location=(-4.4, 1.8, 3.2))
    fill = bpy.context.object
    fill.name = "CageGate_Fill"
    fill.data.energy = 650.0
    fill.data.size = 3.0
    look_at(fill, (0.0, -0.1, 0.8))

    bpy.ops.object.light_add(type="AREA", location=(0.0, 2.7, 0.5))
    rim = bpy.context.object
    rim.name = "CageGate_Rim"
    rim.data.energy = 800.0
    rim.data.size = 2.5
    look_at(rim, (0.0, 0.0, 0.9))

    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.name = "CageGate_Camera"
    camera.data.type = "ORTHO"
    scene.camera = camera

    views = (
        ("cage-side.png", (4.8, -0.05, 1.05), (0.0, -0.08, 0.92), 2.35),
        ("cage-front-three-quarter.png", (3.6, -4.5, 2.45), (0.0, -0.27, 0.90), 2.45),
        ("cage-ventral-three-quarter.png", (3.2, -4.1, -2.35), (0.0, -0.28, 0.72), 2.35),
        ("cage-top.png", (0.0, -0.10, 5.6), (0.0, -0.10, 0.82), 2.35),
        ("cage-paw-top.png", (0.49, -0.74, 4.7), (0.49, -0.72, 0.10), 0.90),
    )
    paths = []
    for filename, location, target, scale in views:
        camera.location = location
        camera.data.ortho_scale = scale
        look_at(camera, target)
        path = root / filename
        scene.render.filepath = str(path)
        bpy.ops.render.render(write_still=True)
        paths.append(str(path))

    report = {
        "status": "subdivision_cage_wire_gate_rendered",
        "presentation": "unsubdivided cage skin and orange topology wire; no proxy/reference geometry",
        "reviewRenders": paths,
    }
    report_path = root.parent / "cage-render-report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_SUBDIVISION_CAGE_RENDER", json.dumps(report))


if __name__ == "__main__":
    main()

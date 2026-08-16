import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def parse_args():
    parser = argparse.ArgumentParser(description="Render brown-bear hindquarter gate evidence.")
    parser.add_argument("--review-root", required=True)
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(args)


def material():
    value = bpy.data.materials.new("Clay")
    value.diffuse_color = (0.45, 0.38, 0.32, 1.0)
    value.roughness = 0.82
    return value


def look_at(camera, target):
    camera.rotation_euler = (Vector(target) - camera.location).to_track_quat("-Z", "Y").to_euler()


def main():
    args = parse_args()
    root = Path(args.review_root)
    root.mkdir(parents=True, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 900
    scene.render.resolution_y = 900
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.world.color = (0.025, 0.025, 0.025)
    obj = bpy.data.objects["BrownBear_HindquarterGate"]
    obj.data.materials.clear()
    obj.data.materials.append(material())
    bpy.ops.object.light_add(type="AREA", location=(-3.5, -4.0, 5.0))
    bpy.context.object.data.energy = 1100
    bpy.context.object.data.shape = "DISK"
    bpy.context.object.data.size = 4.0
    bpy.ops.object.light_add(type="AREA", location=(3.5, 1.0, 3.0))
    bpy.context.object.data.energy = 650
    bpy.context.object.data.size = 3.0
    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = 2.8
    scene.camera = camera
    views = {
        "clay-side": ((3.7, -0.05, 1.15), (0.0, 0.55, 0.85)),
        "clay-rear": ((0.0, 4.0, 1.20), (0.0, 0.65, 0.85)),
        "clay-three-quarter": ((3.2, 3.2, 2.1), (0.0, 0.55, 0.80)),
        "clay-low-raking": ((3.0, -1.8, 0.65), (0.0, 0.40, 0.42)),
    }
    rendered = []
    for name, (location, target) in views.items():
        camera.location = location
        look_at(camera, target)
        scene.render.filepath = str(root / f"{name}.png")
        bpy.ops.render.render(write_still=True)
        rendered.append(scene.render.filepath)
    report = {"status": "hindquarter_gate_rendered", "renders": rendered}
    (root.parent / "render-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_HINDQUARTER_RENDER", json.dumps(report))


if __name__ == "__main__":
    main()

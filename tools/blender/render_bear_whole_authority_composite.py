import argparse
import json
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def parse_args():
    parser = argparse.ArgumentParser(description="Render whole brown-bear authority composite evidence.")
    parser.add_argument("--review-root", required=True)
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(args)


def look_at(camera, target):
    camera.rotation_euler = (Vector(target) - camera.location).to_track_quat("-Z", "Y").to_euler()


def main():
    args = parse_args()
    root = Path(args.review_root)
    root.mkdir(parents=True, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1024
    scene.render.resolution_y = 1024
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.world.color = (0.018, 0.018, 0.018)
    clay = bpy.data.materials.new("WholeBearClay")
    clay.diffuse_color = (0.42, 0.34, 0.28, 1.0)
    clay.roughness = 0.85
    for obj in (value for value in scene.objects if value.type == "MESH"):
        obj.data.materials.clear()
        obj.data.materials.append(clay)
    bpy.ops.object.light_add(type="AREA", location=(-4.0, -5.0, 6.0))
    bpy.context.object.data.energy = 1400
    bpy.context.object.data.size = 5.0
    bpy.ops.object.light_add(type="AREA", location=(4.0, 2.0, 3.5))
    bpy.context.object.data.energy = 800
    bpy.context.object.data.size = 4.0
    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = 4.4
    scene.camera = camera
    views = {
        "clay-side": ((4.8, -0.15, 1.35), (0.0, -0.20, 1.08)),
        "clay-front": ((0.0, -5.5, 1.35), (0.0, -0.30, 1.05)),
        "clay-three-quarter": ((4.4, -4.4, 2.55), (0.0, -0.20, 1.05)),
        "clay-rear": ((0.0, 5.0, 1.25), (0.0, 0.45, 1.00)),
        "clay-head-close": ((3.3, -4.2, 2.2), (0.0, -1.25, 1.55)),
    }
    rendered = []
    for name, (location, target) in views.items():
        camera.location = location
        camera.data.ortho_scale = 2.2 if name == "clay-head-close" else 4.4
        look_at(camera, target)
        scene.render.filepath = str(root / f"{name}.png")
        bpy.ops.render.render(write_still=True)
        rendered.append(scene.render.filepath)
    report = {"status": "whole_authority_composite_rendered", "renders": rendered}
    (root.parent / "render-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_WHOLE_AUTHORITY_RENDER", json.dumps(report))


if __name__ == "__main__":
    main()

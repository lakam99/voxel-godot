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
    scene.world.use_nodes = True
    background = scene.world.node_tree.nodes.get("Background")
    background.inputs["Color"].default_value = (0.075, 0.080, 0.090, 1.0)
    background.inputs["Strength"].default_value = 0.48
    scene.view_settings.look = "AgX - Medium Low Contrast"
    clay = bpy.data.materials.new("WholeBearClay")
    clay.use_nodes = True
    principled = clay.node_tree.nodes.get("Principled BSDF")
    principled.inputs["Base Color"].default_value = (0.36, 0.25, 0.18, 1.0)
    principled.inputs["Roughness"].default_value = 0.88
    claw_clay = bpy.data.materials.new("WholeBearClawClay")
    claw_clay.use_nodes = True
    claw_principled = claw_clay.node_tree.nodes.get("Principled BSDF")
    claw_principled.inputs["Base Color"].default_value = (0.075, 0.052, 0.036, 1.0)
    claw_principled.inputs["Roughness"].default_value = 0.72
    for obj in (value for value in scene.objects if value.type == "MESH"):
        obj.data.materials.clear()
        obj.data.materials.append(claw_clay if "Claw" in obj.name else clay)
    bpy.ops.object.light_add(type="AREA", location=(-4.0, -5.0, 6.0))
    bpy.context.object.data.energy = 1150
    bpy.context.object.data.size = 5.0
    bpy.ops.object.light_add(type="AREA", location=(4.0, 2.0, 3.5))
    bpy.context.object.data.energy = 620
    bpy.context.object.data.size = 4.0
    bpy.ops.object.light_add(type="AREA", location=(0.0, -4.5, 1.15))
    bpy.context.object.data.energy = 760
    bpy.context.object.data.size = 3.5
    bpy.ops.object.light_add(type="AREA", location=(0.0, -4.2, 2.8))
    bpy.context.object.data.energy = 920
    bpy.context.object.data.size = 3.0
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
        "clay-paw-side": ((3.2, -0.20, 0.34), (0.68, -0.48, 0.16)),
        "clay-paw-three-quarter": ((2.8, -3.4, 0.82), (0.55, -0.48, 0.16)),
    }
    rendered = []
    for name, (location, target) in views.items():
        camera.location = location
        if name == "clay-head-close":
            camera.data.ortho_scale = 2.2
        elif name == "clay-paw-side":
            camera.data.ortho_scale = 0.92
        elif name == "clay-paw-three-quarter":
            camera.data.ortho_scale = 1.12
        else:
            camera.data.ortho_scale = 4.4
        look_at(camera, target)
        scene.render.filepath = str(root / f"{name}.png")
        bpy.ops.render.render(write_still=True)
        rendered.append(scene.render.filepath)
    report = {"status": "whole_authority_composite_rendered", "renders": rendered}
    (root.parent / "render-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_WHOLE_AUTHORITY_RENDER", json.dumps(report))


if __name__ == "__main__":
    main()

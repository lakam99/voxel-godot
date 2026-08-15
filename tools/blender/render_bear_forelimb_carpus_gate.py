import argparse
import json
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--review-root", required=True)
    return parser.parse_args(sys.argv[sys.argv.index("--") + 1 :])


def look_at(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def material(name, color, roughness):
    value = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    value.use_nodes = True
    principled = value.node_tree.nodes.get("Principled BSDF")
    principled.inputs["Base Color"].default_value = (*color, 1.0)
    principled.inputs["Roughness"].default_value = roughness
    return value


def main():
    args = parse_args()
    root = Path(args.review_root)
    root.mkdir(parents=True, exist_ok=True)
    cage = bpy.data.objects["BrownBear_ShoulderSaddlePatch"]
    clay = cage.copy()
    clay.data = cage.data.copy()
    clay.name = "BrownBear_ForelimbCarpusClay"
    bpy.context.collection.objects.link(clay)
    clay.modifiers.clear()
    clay.data.materials.clear()
    clay.data.materials.append(material("ForelimbCarpusClay", (0.32, 0.255, 0.205), 0.84))
    subdivision = clay.modifiers.new("ForelimbCarpusCatmullClark", "SUBSURF")
    subdivision.subdivision_type = "CATMULL_CLARK"
    subdivision.levels = 2
    subdivision.render_levels = 2
    for polygon in clay.data.polygons:
        polygon.use_smooth = True
    scene = bpy.context.scene
    try:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    except TypeError:
        scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1024
    scene.render.resolution_y = 1024
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.world.color = (0.006, 0.008, 0.012)
    bpy.ops.object.light_add(type="AREA", location=(3.8, -3.5, 4.2))
    key = bpy.context.object
    key.data.energy = 1050.0
    key.data.size = 2.8
    look_at(key, (0.84, -0.20, 0.70))
    bpy.ops.object.light_add(type="AREA", location=(-1.5, 1.8, 1.8))
    fill = bpy.context.object
    fill.data.energy = 500.0
    fill.data.size = 2.4
    look_at(fill, (0.84, -0.10, 0.65))
    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.data.type = "ORTHO"
    scene.camera = camera
    views = (
        ("lateral", (3.6, -0.22, 0.78), (0.83, -0.20, 0.76), 1.55),
        ("cranial-three-quarter", (3.0, -3.0, 1.65), (0.83, -0.18, 0.72), 1.60),
        ("caudal-three-quarter", (3.0, 2.5, 1.55), (0.83, -0.10, 0.72), 1.60),
        ("front", (0.86, -3.8, 0.72), (0.83, -0.15, 0.70), 1.40),
        ("ventral-raking", (2.8, -2.4, 0.05), (0.82, -0.15, 0.58), 1.35),
        ("elbow-carpus", (3.0, -1.8, 0.52), (0.88, -0.12, 0.48), 0.85),
    )
    paths = {"wire": [], "clay": []}
    for presentation, active, hidden in (("wire", cage, clay), ("clay", clay, cage)):
        active.hide_render = False
        hidden.hide_render = True
        for view_name, location, target, scale in views:
            camera.location = location
            camera.data.ortho_scale = scale
            look_at(camera, target)
            path = root / f"{presentation}-{view_name}.png"
            scene.render.filepath = str(path)
            bpy.ops.render.render(write_still=True)
            paths[presentation].append(str(path))
    report = {"status": "forelimb_carpus_rendered", "reviewRenders": paths}
    (root.parent / "render-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_FORELIMB_CARPUS_RENDER", json.dumps(report))


if __name__ == "__main__":
    main()

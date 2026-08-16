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
    clay.name = "BrownBear_ForepawClay"
    bpy.context.collection.objects.link(clay)
    clay.modifiers.clear()
    clay.data.materials.clear()
    clay.data.materials.append(material("ForepawClay", (0.32, 0.255, 0.205), 0.84))
    subdivision = clay.modifiers.new("ForepawCatmullClark", "SUBSURF")
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
    bpy.ops.object.light_add(type="AREA", location=(3.6, -3.8, 4.2))
    key = bpy.context.object
    key.data.energy = 1100.0
    key.data.size = 2.8
    look_at(key, (1.1, -0.8, 0.35))
    bpy.ops.object.light_add(type="AREA", location=(-1.6, 1.5, 1.3))
    fill = bpy.context.object
    fill.data.energy = 450.0
    fill.data.size = 2.4
    look_at(fill, (1.1, -0.8, 0.35))
    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.data.type = "ORTHO"
    scene.camera = camera
    views = (
        ("top", (1.1, -0.85, 3.2), (1.1, -0.85, 0.35), 1.55),
        ("front", (1.1, -3.5, 0.42), (1.1, -0.9, 0.34), 1.30),
        ("lateral", (3.5, -0.85, 0.55), (1.1, -0.85, 0.36), 1.55),
        ("plantar", (1.1, -0.85, -2.2), (1.1, -0.85, 0.28), 1.55),
        ("dorsal-three-quarter", (3.0, -3.0, 2.2), (1.1, -0.85, 0.35), 1.65),
        ("toe-raking", (2.6, -3.2, 0.42), (1.1, -1.25, 0.34), 1.05),
        ("paw-close-top", (1.17, -0.76, 2.0), (1.17, -0.76, 0.13), 0.52),
        ("paw-close-plantar", (1.17, -0.76, -1.5), (1.17, -0.76, 0.10), 0.52),
        ("paw-close-front", (1.17, -2.0, 0.15), (1.17, -0.76, 0.13), 0.48),
        ("paw-close-raking", (1.82, -1.55, 0.72), (1.17, -0.80, 0.13), 0.54),
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
    report = {"status": "forepaw_rendered", "reviewRenders": paths}
    (root.parent / "render-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_FOREPAW_RENDER", json.dumps(report))


if __name__ == "__main__":
    main()

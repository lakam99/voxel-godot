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


def configure_material(material, color, roughness):
    material.use_nodes = True
    principled = material.node_tree.nodes.get("Principled BSDF")
    principled.inputs["Base Color"].default_value = (*color, 1.0)
    principled.inputs["Roughness"].default_value = roughness


def main():
    args = parse_args()
    root = Path(args.review_root)
    root.mkdir(parents=True, exist_ok=True)
    cage = bpy.data.objects["BrownBear_ShoulderSaddlePatch"]
    proxy = bpy.data.objects.get("BrownBear_TorsoProxy_NotAsset")
    configure_material(bpy.data.materials["ShoulderSaddleSkin"], (0.025, 0.075, 0.11), 0.76)
    configure_material(bpy.data.materials["ShoulderSaddleWire"], (1.0, 0.16, 0.02), 0.40)
    clay_material = bpy.data.materials.get("ShoulderSaddleClay") or bpy.data.materials.new("ShoulderSaddleClay")
    configure_material(clay_material, (0.32, 0.255, 0.205), 0.84)
    if proxy is not None:
        configure_material(bpy.data.materials["TorsoProxySkin"], (0.10, 0.12, 0.13), 0.90)
    clay = cage.copy()
    clay.data = cage.data.copy()
    clay.name = "BrownBear_ShoulderSaddleClay"
    bpy.context.collection.objects.link(clay)
    clay.modifiers.clear()
    clay.data.materials.clear()
    clay.data.materials.append(clay_material)
    subdivision = clay.modifiers.new("ShoulderSaddleCatmullClark", "SUBSURF")
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
    bpy.ops.object.light_add(type="AREA", location=(3.4, -3.3, 4.0))
    key = bpy.context.object
    key.data.energy = 950.0
    key.data.size = 2.6
    look_at(key, (0.68, -0.28, 1.0))
    bpy.ops.object.light_add(type="AREA", location=(-1.5, 1.8, 2.0))
    fill = bpy.context.object
    fill.data.energy = 520.0
    fill.data.size = 2.2
    look_at(fill, (0.68, -0.28, 1.0))
    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.data.type = "ORTHO"
    scene.camera = camera
    views = (
        ("lateral", (3.2, -0.28, 1.04), (0.68, -0.28, 1.02), 0.95),
        ("cranial-three-quarter", (2.65, -2.55, 1.85), (0.68, -0.30, 1.00), 1.00),
        ("caudal-three-quarter", (2.65, 2.05, 1.70), (0.68, -0.22, 1.02), 1.00),
        ("ventral-raking", (2.45, -2.15, 0.15), (0.64, -0.28, 0.92), 0.88),
        ("dorsal", (1.55, -0.25, 4.0), (0.69, -0.26, 1.04), 0.90),
        ("axilla", (2.15, -1.65, 0.48), (0.61, -0.30, 0.86), 0.58),
    )
    render_paths = {"wire": [], "clay": []}
    for presentation, active, hidden in (("wire", cage, clay), ("clay", clay, cage)):
        active.hide_render = False
        hidden.hide_render = True
        if proxy is not None:
            proxy.data.materials.clear()
            proxy.data.materials.append(
                bpy.data.materials["TorsoProxySkin"] if presentation == "wire" else clay_material
            )
        for view_name, location, target, scale in views:
            camera.location = location
            camera.data.ortho_scale = scale
            look_at(camera, target)
            path = root / f"{presentation}-{view_name}.png"
            scene.render.filepath = str(path)
            bpy.ops.render.render(write_still=True)
            render_paths[presentation].append(str(path))
    report = {
        "status": "shoulder_saddle_rendered",
        "subdivision": {"algorithm": "Catmull-Clark", "levels": 2},
        "reviewRenders": render_paths,
    }
    report_path = root.parent / "render-report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_SHOULDER_SADDLE_RENDER", json.dumps(report))


if __name__ == "__main__":
    main()

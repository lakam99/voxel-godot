import argparse
import json
import math
import sys
from pathlib import Path

import bpy


GENERATOR_VERSION = "animated-poc-v1"

MATERIAL_SPECS = {
    "wood": (0.56, 0.32, 0.14, 1.0),
    "wood_dark": (0.24, 0.12, 0.05, 1.0),
    "wood_line": (0.14, 0.07, 0.03, 1.0),
    "stone": (0.48, 0.52, 0.50, 1.0),
    "iron": (0.28, 0.30, 0.29, 1.0),
    "gold": (0.94, 0.72, 0.28, 1.0),
    "glass": (0.54, 0.82, 0.92, 0.42),
    "boar": (0.45, 0.33, 0.24, 1.0),
    "boar_dark": (0.24, 0.17, 0.12, 1.0),
    "boar_snout": (0.58, 0.38, 0.34, 1.0),
    "deer": (0.58, 0.40, 0.23, 1.0),
    "deer_dark": (0.30, 0.19, 0.10, 1.0),
    "deer_belly": (0.82, 0.70, 0.55, 1.0),
    "hare": (0.68, 0.58, 0.42, 1.0),
    "hare_dark": (0.42, 0.34, 0.24, 1.0),
    "hare_snow": (0.86, 0.88, 0.82, 1.0),
}


def parse_args():
    parser = argparse.ArgumentParser(description="Generate deterministic animated low-poly GLB POC assets.")
    parser.add_argument("--output-root", required=True, help="Project-relative or absolute assets/generated/animated directory.")
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(args)


def reset_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.render.fps = 24
    bpy.context.scene.view_settings.view_transform = "Standard"
    bpy.context.scene.view_settings.look = "Medium High Contrast"
    bpy.context.scene.view_settings.exposure = 0.0
    bpy.context.scene.view_settings.gamma = 1.0


def make_materials():
    materials = {}
    for name, color in MATERIAL_SPECS.items():
        material = bpy.data.materials.new(name)
        material.diffuse_color = color
        material.use_nodes = True
        bsdf = material.node_tree.nodes.get("Principled BSDF")
        if bsdf:
            bsdf.inputs["Base Color"].default_value = color
            bsdf.inputs["Roughness"].default_value = 0.82
            bsdf.inputs["Metallic"].default_value = 0.0
            if color[3] < 1.0:
                bsdf.inputs["Alpha"].default_value = color[3]
                material.blend_method = "BLEND"
        materials[name] = material
    return materials


def assign_material(obj, material):
    obj.data.materials.append(material)
    for polygon in obj.data.polygons:
        polygon.material_index = 0


def create_empty(name, location=(0.0, 0.0, 0.0), parent=None):
    obj = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(obj)
    obj.empty_display_type = "ARROWS"
    obj.empty_display_size = 0.18
    obj.parent = parent
    obj.location = location
    return obj


def add_cube(name, size, location, material, parent=None, rotation=(0.0, 0.0, 0.0)):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0.0, 0.0, 0.0))
    obj = bpy.context.object
    obj.name = name
    obj.parent = parent
    obj.location = location
    obj.rotation_euler = rotation
    obj.scale = size
    assign_material(obj, material)
    return obj


def add_cylinder(name, radius, depth, location, material, parent=None, vertices=8, rotation=(0.0, 0.0, 0.0)):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=vertices,
        radius=radius,
        depth=depth,
        end_fill_type="TRIFAN",
        location=(0.0, 0.0, 0.0),
    )
    obj = bpy.context.object
    obj.name = name
    obj.parent = parent
    obj.location = location
    obj.rotation_euler = rotation
    assign_material(obj, material)
    return obj


def add_cone(name, vertices, radius1, radius2, depth, location, material, parent=None, rotation=(0.0, 0.0, 0.0)):
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices,
        radius1=radius1,
        radius2=radius2,
        depth=depth,
        end_fill_type="TRIFAN",
        location=(0.0, 0.0, 0.0),
    )
    obj = bpy.context.object
    obj.name = name
    obj.parent = parent
    obj.location = location
    obj.rotation_euler = rotation
    assign_material(obj, material)
    return obj


def add_ico(name, radius, location, scale, material, parent=None, subdivisions=1):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions, radius=radius, location=(0.0, 0.0, 0.0))
    obj = bpy.context.object
    obj.name = name
    obj.parent = parent
    obj.location = location
    obj.scale = scale
    assign_material(obj, material)
    return obj


def key_transform(obj, frame, location=None, rotation=None):
    bpy.context.scene.frame_set(frame)
    if location is not None:
        obj.location = location
        obj.keyframe_insert(data_path="location", frame=frame)
    if rotation is not None:
        obj.rotation_euler = rotation
        obj.keyframe_insert(data_path="rotation_euler", frame=frame)


def push_active_action_to_nla(obj, clip_name):
    if not obj.animation_data or not obj.animation_data.action:
        return
    action = obj.animation_data.action
    action.name = "%s_%s" % (clip_name, obj.name)
    track = obj.animation_data.nla_tracks.new()
    track.name = clip_name
    strip = track.strips.new(clip_name, int(action.frame_range[0]), action)
    strip.name = clip_name
    obj.animation_data.action = None


def set_interpolation(objects):
    for obj in objects:
        if not obj.animation_data:
            continue
        actions = []
        if obj.animation_data.action:
            actions.append(obj.animation_data.action)
        for track in obj.animation_data.nla_tracks:
            for strip in track.strips:
                actions.append(strip.action)
        for action in actions:
            for curve in action.fcurves:
                for point in curve.keyframe_points:
                    point.interpolation = "SINE" if point.interpolation == "BEZIER" else point.interpolation


def export_glb(filepath):
    filepath.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    kwargs = {
        "filepath": str(filepath),
        "export_format": "GLB",
        "export_animations": True,
    }
    properties = bpy.ops.export_scene.gltf.get_rna_type().properties.keys()
    if "export_selected" in properties:
        kwargs["export_selected"] = True
    if "export_animation_mode" in properties:
        kwargs["export_animation_mode"] = "NLA_TRACKS"
    if "export_merge_animation" in properties:
        kwargs["export_merge_animation"] = "NLA_TRACK"
    if "export_anim_scene_split_object" in properties:
        kwargs["export_anim_scene_split_object"] = False
    if "export_nla_strips" in properties:
        kwargs["export_nla_strips"] = True
    if "export_anim_slide_to_zero" in properties:
        kwargs["export_anim_slide_to_zero"] = False
    bpy.ops.export_scene.gltf(**kwargs)


def animate_quadruped(root, legs, clip_name, stride_degrees=18.0, bob_height=0.045, end_frame=80):
    bpy.context.scene.frame_start = 1
    bpy.context.scene.frame_end = end_frame
    for frame, z in [(1, 0.0), (12, bob_height), (24, 0.0), (36, bob_height * 0.75), (48, 0.0)]:
        key_transform(root, frame, location=(0.0, 0.0, z))
    for frame, z in [(49, 0.0), (57, bob_height * 1.25), (65, 0.0), (73, bob_height * 1.25), (end_frame, 0.0)]:
        key_transform(root, frame, location=(0.0, 0.0, z))
    for pivot, phase in legs:
        for frame in [1, 24, 48]:
            key_transform(pivot, frame, rotation=(0.0, 0.0, 0.0))
        for frame, amount in [(49, phase), (57, -phase), (65, phase), (73, -phase), (end_frame, phase)]:
            key_transform(pivot, frame, rotation=(math.radians(stride_degrees * amount), 0.0, 0.0))

    push_active_action_to_nla(root, clip_name)
    for pivot, _phase in legs:
        push_active_action_to_nla(pivot, clip_name)


def build_door(output_root):
    reset_scene()
    materials = make_materials()
    root = create_empty("DoorAssetRoot")
    hinge = create_empty("DoorHinge", (0.0, 0.0, 0.0), root)
    width = 0.96
    thickness = 0.12
    height = 1.88
    panel_center = (-width * 0.5, 0.0, height * 0.5)
    add_cube("DoorPanel", (width, thickness, height), panel_center, materials["wood"], hinge)
    add_cube("DoorTopRail", (width * 0.96, thickness * 1.22, 0.08), (-width * 0.5, -0.01, height * 0.80), materials["wood_dark"], hinge)
    add_cube("DoorBottomRail", (width * 0.96, thickness * 1.22, 0.08), (-width * 0.5, -0.01, height * 0.24), materials["wood_dark"], hinge)
    for x in [-0.76, -0.48, -0.20]:
        add_cube("DoorGrainLine", (0.025, thickness * 1.24, height * 0.90), (x, -0.016, height * 0.50), materials["wood_line"], hinge)
    add_ico("DoorKnob", 0.055, (-0.84, -0.088, height * 0.50), (1.0, 1.0, 1.0), materials["gold"], hinge, 1)

    bpy.context.scene.frame_start = 1
    bpy.context.scene.frame_end = 60
    key_transform(hinge, 1, rotation=(0.0, 0.0, 0.0))
    key_transform(hinge, 30, rotation=(0.0, 0.0, -math.radians(92.0)))
    key_transform(hinge, 60, rotation=(0.0, 0.0, 0.0))
    push_active_action_to_nla(hinge, "door_open_close")
    export_glb(output_root / "door_open_close.glb")


def build_chest(output_root):
    reset_scene()
    materials = make_materials()
    root = create_empty("ChestAssetRoot")
    add_cube("ChestBase", (1.12, 0.70, 0.46), (0.0, 0.0, 0.23), materials["wood"], root)
    add_cube("ChestFrontBand", (1.18, 0.045, 0.38), (0.0, -0.372, 0.30), materials["wood_dark"], root)
    add_cube("ChestSideBandLeft", (0.045, 0.74, 0.48), (-0.58, 0.0, 0.28), materials["iron"], root)
    add_cube("ChestSideBandRight", (0.045, 0.74, 0.48), (0.58, 0.0, 0.28), materials["iron"], root)
    add_cube("ChestLatch", (0.18, 0.055, 0.16), (0.0, -0.392, 0.32), materials["gold"], root)

    hinge = create_empty("ChestLidHinge", (0.0, 0.35, 0.52), root)
    add_cube("ChestLid", (1.18, 0.74, 0.16), (0.0, -0.35, 0.08), materials["wood_dark"], hinge)
    add_cube("ChestLidHighlight", (1.05, 0.06, 0.10), (0.0, -0.67, 0.14), materials["wood"], hinge)

    bpy.context.scene.frame_start = 1
    bpy.context.scene.frame_end = 60
    key_transform(hinge, 1, rotation=(0.0, 0.0, 0.0))
    key_transform(hinge, 30, rotation=(math.radians(72.0), 0.0, 0.0))
    key_transform(hinge, 60, rotation=(0.0, 0.0, 0.0))
    push_active_action_to_nla(hinge, "chest_open_close")
    export_glb(output_root / "chest_open_close.glb")


def build_boar(output_root):
    reset_scene()
    materials = make_materials()
    root = create_empty("BoarAssetRoot")
    body = add_ico("BoarBody", 1.0, (0.0, 0.0, 0.76), (0.92, 0.48, 0.40), materials["boar"], root, 1)
    add_ico("BoarHead", 1.0, (0.0, -0.62, 0.84), (0.42, 0.32, 0.30), materials["boar"], root, 1)
    add_ico("BoarSnout", 1.0, (0.0, -0.90, 0.76), (0.24, 0.18, 0.16), materials["boar_snout"], root, 1)
    add_cone("BoarLeftEar", 4, 0.12, 0.02, 0.26, (-0.20, -0.58, 1.13), materials["boar_dark"], root, (math.radians(22.0), 0.0, math.radians(18.0)))
    add_cone("BoarRightEar", 4, 0.12, 0.02, 0.26, (0.20, -0.58, 1.13), materials["boar_dark"], root, (math.radians(22.0), 0.0, math.radians(-18.0)))
    add_cone("BoarLeftTusk", 6, 0.035, 0.006, 0.28, (-0.16, -1.02, 0.76), materials["glass"], root, (math.radians(90.0), math.radians(12.0), 0.0))
    add_cone("BoarRightTusk", 6, 0.035, 0.006, 0.28, (0.16, -1.02, 0.76), materials["glass"], root, (math.radians(90.0), math.radians(-12.0), 0.0))

    legs = []
    for name, x, y, phase in [
        ("FrontLeftLeg", -0.30, -0.28, 1.0),
        ("FrontRightLeg", 0.30, -0.28, -1.0),
        ("BackLeftLeg", -0.30, 0.28, -1.0),
        ("BackRightLeg", 0.30, 0.28, 1.0),
    ]:
        pivot = create_empty("%sPivot" % name, (x, y, 0.48), root)
        add_cube(name, (0.15, 0.13, 0.42), (0.0, 0.0, -0.22), materials["boar_dark"], pivot)
        legs.append((pivot, phase))

    animate_quadruped(root, legs, "boar_idle_walk", 18.0, 0.045)
    export_glb(output_root / "boar_idle_walk.glb")


def build_deer(output_root):
    reset_scene()
    materials = make_materials()
    root = create_empty("DeerAssetRoot")
    add_ico("DeerBody", 1.0, (0.0, 0.0, 0.92), (0.82, 0.36, 0.32), materials["deer"], root, 1)
    add_ico("DeerChest", 1.0, (0.0, -0.42, 0.95), (0.48, 0.34, 0.36), materials["deer_belly"], root, 1)
    add_cylinder("DeerNeck", 0.14, 0.48, (0.0, -0.66, 1.16), materials["deer"], root, 7, (math.radians(26.0), 0.0, 0.0))
    add_ico("DeerHead", 1.0, (0.0, -0.88, 1.32), (0.30, 0.24, 0.22), materials["deer"], root, 1)
    add_ico("DeerMuzzle", 1.0, (0.0, -1.08, 1.24), (0.15, 0.12, 0.10), materials["deer_dark"], root, 1)
    for x in [-0.17, 0.17]:
        add_cone("DeerEar", 4, 0.075, 0.012, 0.26, (x, -0.83, 1.55), materials["deer_dark"], root, (math.radians(18.0), 0.0, math.radians(-24.0 if x < 0 else 24.0)))
        add_cylinder("DeerAntlerStem", 0.018, 0.30, (x, -0.78, 1.65), materials["wood_line"], root, 5, (math.radians(12.0), math.radians(16.0 if x < 0 else -16.0), 0.0))
        add_cylinder("DeerAntlerFork", 0.012, 0.18, (x + (-0.045 if x < 0 else 0.045), -0.78, 1.76), materials["wood_line"], root, 5, (math.radians(38.0), math.radians(-26.0 if x < 0 else 26.0), 0.0))
    legs = []
    for name, x, y, phase in [
        ("DeerFrontLeftLeg", -0.24, -0.35, 1.0),
        ("DeerFrontRightLeg", 0.24, -0.35, -1.0),
        ("DeerBackLeftLeg", -0.24, 0.34, -1.0),
        ("DeerBackRightLeg", 0.24, 0.34, 1.0),
    ]:
        pivot = create_empty("%sPivot" % name, (x, y, 0.70), root)
        add_cube(name, (0.085, 0.075, 0.68), (0.0, 0.0, -0.35), materials["deer_dark"], pivot)
        legs.append((pivot, phase))
    animate_quadruped(root, legs, "deer_idle_walk", 24.0, 0.055)
    export_glb(output_root / "deer_idle_walk.glb")


def build_hare(output_root):
    reset_scene()
    materials = make_materials()
    root = create_empty("HareAssetRoot")
    add_ico("HareBody", 1.0, (0.0, 0.0, 0.44), (0.44, 0.30, 0.28), materials["hare"], root, 1)
    add_ico("HareChest", 1.0, (0.0, -0.22, 0.48), (0.26, 0.22, 0.24), materials["hare_snow"], root, 1)
    add_ico("HareHead", 1.0, (0.0, -0.42, 0.66), (0.24, 0.20, 0.20), materials["hare"], root, 1)
    add_ico("HareTail", 0.11, (0.0, 0.38, 0.47), (1.0, 0.85, 0.85), materials["hare_snow"], root, 1)
    for x in [-0.08, 0.08]:
        add_cone("HareEar", 5, 0.055, 0.010, 0.44, (x, -0.42, 0.98), materials["hare_dark"], root, (math.radians(10.0), 0.0, math.radians(-10.0 if x < 0 else 10.0)))
    legs = []
    for name, x, y, phase, size in [
        ("HareFrontLeftLeg", -0.15, -0.20, 1.0, (0.055, 0.045, 0.22)),
        ("HareFrontRightLeg", 0.15, -0.20, -1.0, (0.055, 0.045, 0.22)),
        ("HareBackLeftLeg", -0.18, 0.18, -1.0, (0.075, 0.060, 0.28)),
        ("HareBackRightLeg", 0.18, 0.18, 1.0, (0.075, 0.060, 0.28)),
    ]:
        pivot = create_empty("%sPivot" % name, (x, y, 0.28), root)
        add_cube(name, size, (0.0, 0.0, -0.14), materials["hare_dark"], pivot)
        legs.append((pivot, phase))
    animate_quadruped(root, legs, "hare_idle_walk", 32.0, 0.10)
    export_glb(output_root / "hare_idle_walk.glb")


def main():
    args = parse_args()
    output_root = Path(args.output_root).resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    build_door(output_root)
    build_chest(output_root)
    build_boar(output_root)
    build_deer(output_root)
    build_hare(output_root)
    manifest = {
        "generator": GENERATOR_VERSION,
        "assets": [
            {"id": "door_open_close", "path": "assets/generated/animated/door_open_close.glb", "expectedAnimations": ["door_open_close"]},
            {"id": "chest_open_close", "path": "assets/generated/animated/chest_open_close.glb", "expectedAnimations": ["chest_open_close"]},
            {"id": "boar_idle_walk", "path": "assets/generated/animated/boar_idle_walk.glb", "expectedAnimations": ["boar_idle_walk"]},
            {"id": "deer_idle_walk", "path": "assets/generated/animated/deer_idle_walk.glb", "expectedAnimations": ["deer_idle_walk"]},
            {"id": "hare_idle_walk", "path": "assets/generated/animated/hare_idle_walk.glb", "expectedAnimations": ["hare_idle_walk"]},
        ],
    }
    (output_root / "animated-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("Generated animated assets in %s" % output_root)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Animated asset generation failed: %s" % error, file=sys.stderr)
        raise SystemExit(1)

import argparse
import json
import math
import random
import struct
import sys
import zlib
from pathlib import Path

import bpy
from mathutils import Vector


GENERATOR_VERSION = "cave-assets-preview-v1"
SEED = 1492
TRIANGLE_LIMIT = 1800
GALLERY_COLUMNS = 5
GALLERY_SPACING_X = 3.8
GALLERY_SPACING_Y = 3.25

MATERIAL_SPECS = {
    "cave_stone": (0.38, 0.42, 0.39, 1.0, 0.90, 0.0, 0.0),
    "cave_stone_dark": (0.20, 0.23, 0.22, 1.0, 0.94, 0.0, 0.0),
    "cave_stone_warm": (0.48, 0.45, 0.36, 1.0, 0.88, 0.0, 0.0),
    "cave_soil": (0.28, 0.22, 0.15, 1.0, 0.96, 0.0, 0.0),
    "cave_moss": (0.20, 0.34, 0.22, 1.0, 0.88, 0.0, 0.0),
    "cave_wood": (0.42, 0.24, 0.12, 1.0, 0.86, 0.0, 0.0),
    "cave_wood_dark": (0.22, 0.12, 0.06, 1.0, 0.90, 0.0, 0.0),
    "iron_dark": (0.22, 0.24, 0.24, 1.0, 0.55, 0.18, 0.0),
    "ore_copper": (0.80, 0.42, 0.20, 1.0, 0.54, 0.10, 0.0),
    "ore_iron": (0.76, 0.78, 0.72, 1.0, 0.50, 0.14, 0.0),
    "ore_coal": (0.06, 0.07, 0.07, 1.0, 0.96, 0.0, 0.0),
    "torch_flame": (1.00, 0.58, 0.18, 1.0, 0.32, 0.0, 1.5),
    "torch_ember": (1.00, 0.24, 0.08, 1.0, 0.34, 0.0, 1.0),
    "glow_blue": (0.32, 0.74, 0.92, 1.0, 0.38, 0.0, 1.15),
    "glow_green": (0.38, 0.90, 0.58, 1.0, 0.42, 0.0, 1.0),
    "glow_violet": (0.70, 0.44, 0.94, 1.0, 0.42, 0.0, 1.05),
    "book_cover": (0.32, 0.18, 0.10, 1.0, 0.82, 0.0, 0.0),
    "book_rare": (0.28, 0.22, 0.58, 1.0, 0.72, 0.0, 0.2),
    "book_pages": (0.86, 0.75, 0.52, 1.0, 0.78, 0.0, 0.0),
    "gold_trim": (0.88, 0.66, 0.28, 1.0, 0.48, 0.14, 0.0),
    "root": (0.32, 0.16, 0.08, 1.0, 0.86, 0.0, 0.0),
}

ASSET_SPECS = [
    {"id": "cave_support_01", "family": "cave_support", "anchor": "ground", "builder": "support", "variant": 1, "notes": "single tunnel support"},
    {"id": "cave_support_02", "family": "cave_support", "anchor": "ground", "builder": "support", "variant": 2, "notes": "reinforced tunnel support"},
    {"id": "wall_torch_01", "family": "cave_wall_torch", "anchor": "wall", "builder": "wall_torch", "variant": 1, "notes": "wall mounted torch and bracket"},
    {"id": "wall_torch_02", "family": "cave_wall_torch", "anchor": "wall", "builder": "wall_torch", "variant": 2, "notes": "angled wall mounted torch"},
    {"id": "cave_rubble_01", "family": "cave_rubble", "anchor": "ground", "builder": "rubble", "variant": 1, "notes": "small passable rock scatter"},
    {"id": "cave_rubble_02", "family": "cave_rubble", "anchor": "ground", "builder": "rubble", "variant": 2, "notes": "medium passable rock scatter"},
    {"id": "cave_rubble_03", "family": "cave_rubble", "anchor": "ground", "builder": "rubble", "variant": 3, "notes": "larger edge dressing rock scatter"},
    {"id": "mineral_vein_copper_01", "family": "cave_mineral_vein", "anchor": "wall", "builder": "mineral_vein", "variant": 1, "ore": "copper", "notes": "wall copper seam"},
    {"id": "mineral_vein_iron_01", "family": "cave_mineral_vein", "anchor": "wall", "builder": "mineral_vein", "variant": 2, "ore": "iron", "notes": "wall iron seam"},
    {"id": "mineral_vein_coal_01", "family": "cave_mineral_vein", "anchor": "wall", "builder": "mineral_vein", "variant": 3, "ore": "coal", "notes": "wall coal seam"},
    {"id": "glow_mushroom_01", "family": "cave_glow_flora", "anchor": "ground", "builder": "glow_mushroom", "variant": 1, "notes": "singular blue cave mushroom"},
    {"id": "glow_mushroom_02", "family": "cave_glow_flora", "anchor": "ground", "builder": "glow_mushroom", "variant": 2, "notes": "singular green cave mushroom"},
    {"id": "glow_crystal_01", "family": "cave_glow_crystal", "anchor": "ground", "builder": "glow_crystal", "variant": 1, "notes": "blue floor crystal cluster"},
    {"id": "glow_crystal_02", "family": "cave_glow_crystal", "anchor": "wall", "builder": "glow_crystal", "variant": 2, "notes": "violet wall crystal cluster"},
    {"id": "cave_roots_01", "family": "cave_roots", "anchor": "ceiling", "builder": "roots", "variant": 1, "notes": "hanging roots near entrances"},
    {"id": "crafting_book_progression", "family": "cave_crafting_book", "anchor": "ground", "builder": "book", "variant": 1, "notes": "standard crafting book pickup"},
    {"id": "crafting_book_rare", "family": "cave_crafting_book", "anchor": "ground", "builder": "book", "variant": 2, "notes": "rare crafting book pickup"},
]


def parse_args():
    parser = argparse.ArgumentParser(description="Generate cave asset approval previews.")
    parser.add_argument("--output-root", required=True, help="Output directory for cave GLBs and preview images.")
    parser.add_argument("--manifest", required=True, help="Cave manifest output path.")
    parser.add_argument("--contact-sheet", required=True, help="Cave asset contact sheet PNG path.")
    parser.add_argument("--preview-render", required=True, help="Dark cave interior preview PNG path.")
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(args)


def reset_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for collection in [bpy.data.meshes, bpy.data.materials, bpy.data.images, bpy.data.lights, bpy.data.cameras]:
        for item in list(collection):
            if item.users == 0:
                collection.remove(item)
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.render.resolution_x = 2200
    bpy.context.scene.render.resolution_y = 1500
    bpy.context.scene.view_settings.view_transform = "Standard"
    bpy.context.scene.view_settings.look = "Medium High Contrast"
    bpy.context.scene.view_settings.exposure = 0.0
    bpy.context.scene.view_settings.gamma = 1.0


def make_materials():
    materials = {}
    for name, (r, g, b, a, roughness, metallic, emission_strength) in MATERIAL_SPECS.items():
        material = bpy.data.materials.new(name)
        material.diffuse_color = (r, g, b, a)
        material.use_nodes = True
        bsdf = material.node_tree.nodes.get("Principled BSDF")
        if bsdf:
            bsdf.inputs["Base Color"].default_value = (r, g, b, a)
            bsdf.inputs["Roughness"].default_value = roughness
            bsdf.inputs["Metallic"].default_value = metallic
            if emission_strength > 0.0:
                if "Emission Color" in bsdf.inputs:
                    bsdf.inputs["Emission Color"].default_value = (r, g, b, 1.0)
                if "Emission Strength" in bsdf.inputs:
                    bsdf.inputs["Emission Strength"].default_value = emission_strength
        materials[name] = material
    return materials


def stable_rng(asset_id):
    return random.Random(f"{SEED}:{asset_id}")


def assign_material(obj, material):
    obj.data.materials.append(material)
    for polygon in obj.data.polygons:
        polygon.material_index = 0


def add_cube(name, size, location, material, rotation=(0.0, 0.0, 0.0)):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = size
    assign_material(obj, material)
    return obj


def add_cone(name, vertices, radius1, radius2, depth, location, material, rotation=(0.0, 0.0, 0.0)):
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices,
        radius1=radius1,
        radius2=radius2,
        depth=depth,
        end_fill_type="TRIFAN",
        location=location,
        rotation=rotation,
    )
    obj = bpy.context.object
    obj.name = name
    assign_material(obj, material)
    return obj


def add_cylinder(name, radius, depth, location, material, vertices=8, rotation=(0.0, 0.0, 0.0), top_radius=None):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=vertices,
        radius=radius,
        depth=depth,
        end_fill_type="TRIFAN",
        location=location,
        rotation=rotation,
    )
    obj = bpy.context.object
    obj.name = name
    obj.rotation_euler = rotation
    if top_radius is not None and radius > 0.0:
        ratio = top_radius / radius
        for vertex in obj.data.vertices:
            if vertex.co.z > 0.0:
                vertex.co.x *= ratio
                vertex.co.y *= ratio
        obj.data.update()
    assign_material(obj, material)
    return obj


def add_ico(name, radius, location, scale, material, rng=None, roughness=0.0, subdivisions=1):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions, radius=radius, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    assign_material(obj, material)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if rng and roughness > 0.0:
        for vertex in obj.data.vertices:
            direction = vertex.co.normalized()
            vertex.co += direction * rng.uniform(-roughness, roughness)
        obj.data.update()
    return obj


def add_branch(name, start, end, radius, material, vertices=6):
    start_v = Vector(start)
    end_v = Vector(end)
    direction = end_v - start_v
    length = direction.length
    if length <= 0.001:
        return add_cylinder(name, radius, 0.01, start, material, vertices)
    midpoint = (start_v + end_v) * 0.5
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=vertices,
        radius=radius,
        depth=length,
        end_fill_type="TRIFAN",
        location=midpoint,
    )
    obj = bpy.context.object
    obj.name = name
    obj.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()
    assign_material(obj, material)
    return obj


def add_prism(name, outline, thickness, location, material, rotation=(0.0, 0.0, 0.0)):
    half = thickness * 0.5
    vertices = [(x, -half, z) for x, z in outline] + [(x, half, z) for x, z in outline]
    count = len(outline)
    faces = [tuple(range(count - 1, -1, -1)), tuple(range(count, count * 2))]
    for index in range(count):
        next_index = (index + 1) % count
        faces.append((index, next_index, next_index + count, index + count))
    mesh = bpy.data.meshes.new(f"{name}Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.location = location
    obj.rotation_euler = rotation
    assign_material(obj, material)
    return obj


def rough_rock(name, location, scale, material, rng):
    rock = add_ico(name, 1.0, location, scale, material, rng, 0.10, 1)
    return rock


def combine_asset(asset_id, objects):
    if not objects:
        raise RuntimeError(f"{asset_id} has no objects")
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    if len(objects) > 1:
        bpy.ops.object.join()
        combined = bpy.context.object
    else:
        combined = objects[0]
    combined.name = asset_id
    bpy.context.scene.cursor.location = (0.0, 0.0, 0.0)
    bpy.ops.object.origin_set(type="ORIGIN_CURSOR", center="MEDIAN")
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    triangulate = combined.modifiers.new("triangulate_export", "TRIANGULATE")
    bpy.context.view_layer.objects.active = combined
    combined.select_set(True)
    bpy.ops.object.modifier_apply(modifier=triangulate.name)
    for polygon in combined.data.polygons:
        polygon.use_smooth = False
    combined.data.update()
    return combined


def build_support(spec, materials, rng):
    variant = spec["variant"]
    width = 2.45 + variant * 0.20
    height = 2.35 + variant * 0.12
    objects = []
    for side in [-1, 1]:
        x = side * width * 0.5
        objects.append(add_cylinder(f"post_{side}", 0.075, height, (x, 0.0, height * 0.5), materials["cave_wood"], 7, (0.0, 0.0, rng.uniform(-0.04, 0.04)), 0.065))
        objects.append(add_cylinder(f"post_shadow_{side}", 0.032, height * 0.92, (x + side * 0.055, -0.045, height * 0.48), materials["cave_wood_dark"], 6))
    objects.append(add_cube("top_beam", (width * 0.62, 0.13, 0.12), (0.0, 0.0, height + 0.02), materials["cave_wood"]))
    objects.append(add_cube("top_beam_dark", (width * 0.60, 0.035, 0.13), (0.0, -0.09, height + 0.025), materials["cave_wood_dark"]))
    if variant == 2:
        objects.append(add_branch("brace_a", (-width * 0.44, -0.02, height * 0.30), (-width * 0.10, -0.02, height * 0.86), 0.040, materials["cave_wood_dark"], 6))
        objects.append(add_branch("brace_b", (width * 0.44, -0.02, height * 0.30), (width * 0.10, -0.02, height * 0.86), 0.040, materials["cave_wood_dark"], 6))
    return combine_asset(spec["id"], objects)


def build_wall_torch(spec, materials, rng):
    variant = spec["variant"]
    objects = []
    objects.append(add_cube("wall_plate", (0.18, 0.05, 0.32), (0.0, 0.03, 0.62), materials["iron_dark"]))
    angle = math.radians(72 if variant == 1 else 62)
    start = (0.0, -0.02, 0.58)
    end = (0.0, -0.48, 0.58 + math.sin(angle) * 0.42)
    objects.append(add_branch("torch_handle", start, end, 0.045, materials["cave_wood_dark"], 7))
    tip = Vector(end)
    objects.append(add_cone("flame_outer", 7, 0.13, 0.025, 0.36, (tip.x, tip.y, tip.z + 0.21), materials["torch_flame"]))
    objects.append(add_cone("flame_inner", 6, 0.07, 0.015, 0.22, (tip.x, tip.y - 0.005, tip.z + 0.20), materials["torch_ember"]))
    objects.append(add_cube("iron_band", (0.13, 0.055, 0.05), (tip.x, tip.y, tip.z + 0.03), materials["iron_dark"]))
    return combine_asset(spec["id"], objects)


def build_rubble(spec, materials, rng):
    variant = spec["variant"]
    objects = []
    count = 3 + variant * 2
    for index in range(count):
        angle = (index / count) * math.tau + rng.uniform(-0.32, 0.32)
        distance = rng.uniform(0.02, 0.38 + variant * 0.08)
        scale = (rng.uniform(0.14, 0.34), rng.uniform(0.12, 0.30), rng.uniform(0.08, 0.22))
        loc = (math.cos(angle) * distance, math.sin(angle) * distance, scale[2])
        material = materials["cave_stone"] if index % 3 != 0 else materials["cave_stone_dark"]
        objects.append(rough_rock(f"rubble_{index}", loc, scale, material, rng))
    return combine_asset(spec["id"], objects)


def build_mineral_vein(spec, materials, rng):
    ore = spec.get("ore", "copper")
    ore_material = materials["ore_copper"]
    if ore == "iron":
        ore_material = materials["ore_iron"]
    elif ore == "coal":
        ore_material = materials["ore_coal"]
    objects = []
    objects.append(add_cube("wall_patch", (0.82, 0.08, 0.55), (0.0, 0.04, 0.42), materials["cave_stone_dark"]))
    for index in range(5):
        x = rng.uniform(-0.34, 0.34)
        z = rng.uniform(0.22, 0.66)
        if ore == "coal":
            objects.append(rough_rock(f"coal_{index}", (x, -0.03, z), (0.10, 0.045, 0.08), ore_material, rng))
        else:
            objects.append(add_cone(f"ore_{index}", 5, rng.uniform(0.035, 0.06), rng.uniform(0.010, 0.022), rng.uniform(0.18, 0.28), (x, -0.065, z), ore_material, (math.radians(90), 0.0, rng.uniform(0.0, math.tau))))
    return combine_asset(spec["id"], objects)


def build_glow_mushroom(spec, materials, rng):
    variant = spec["variant"]
    objects = []
    cap_material = materials["glow_blue"] if variant == 1 else materials["glow_green"]
    height = 0.30 if variant == 1 else 0.38
    stem_radius = 0.038 if variant == 1 else 0.046
    cap_scale = (0.19, 0.15, 0.058) if variant == 1 else (0.24, 0.18, 0.065)
    objects.append(add_cylinder("stem", stem_radius, height, (0.0, 0.0, height * 0.5), materials["book_pages"], 6, top_radius=stem_radius * 0.70))
    objects.append(add_ico("cap", 1.0, (0.0, 0.0, height + 0.035), cap_scale, cap_material, rng, 0.02, 1))
    objects.append(add_ico("moss_base", 1.0, (0.0, 0.0, 0.035), (0.26, 0.20, 0.045), materials["cave_moss"], rng, 0.02, 1))
    return combine_asset(spec["id"], objects)


def build_glow_crystal(spec, materials, rng):
    variant = spec["variant"]
    objects = []
    material = materials["glow_blue"] if variant == 1 else materials["glow_violet"]
    count = 4 if variant == 1 else 3
    for index in range(count):
        angle = (index / count) * math.tau + rng.uniform(-0.30, 0.30)
        distance = rng.uniform(0.04, 0.28)
        height = rng.uniform(0.48, 0.82)
        x = math.cos(angle) * distance
        y = math.sin(angle) * distance if variant == 1 else -0.04
        if variant == 2:
            objects.append(add_cone(f"wall_crystal_{index}", 5, 0.06, 0.015, height, (x, -0.08, 0.38 + index * 0.09), material, (math.radians(90), 0.0, angle)))
        else:
            objects.append(add_cone(f"floor_crystal_{index}", 5, 0.08, 0.018, height, (x, y, height * 0.5), material, (0.0, 0.0, angle)))
    objects.append(add_ico("crystal_base", 1.0, (0.0, 0.0, 0.07), (0.36, 0.28, 0.08), materials["cave_stone_dark"], rng, 0.04, 1))
    return combine_asset(spec["id"], objects)


def build_roots(spec, materials, rng):
    objects = []
    for index in range(6):
        x = (index - 2.5) * 0.13 + rng.uniform(-0.04, 0.04)
        start = (x, rng.uniform(-0.08, 0.08), 0.0)
        end = (x + rng.uniform(-0.12, 0.12), rng.uniform(-0.06, 0.14), -rng.uniform(0.52, 1.05))
        objects.append(add_branch(f"root_{index}", start, end, rng.uniform(0.014, 0.030), materials["root"], 5))
    objects.append(add_cube("ceiling_clump", (0.92, 0.22, 0.06), (0.0, 0.0, 0.02), materials["cave_soil"]))
    return combine_asset(spec["id"], objects)


def build_book(spec, materials, rng):
    variant = spec["variant"]
    cover_material = materials["book_cover"] if variant == 1 else materials["book_rare"]
    accent_material = materials["gold_trim"] if variant == 2 else materials["cave_wood"]
    objects = []
    objects.append(add_cube("pages", (0.34, 0.25, 0.055), (0.0, 0.0, 0.08), materials["book_pages"], (0.0, 0.0, math.radians(-6))))
    objects.append(add_cube("cover", (0.39, 0.29, 0.035), (0.0, 0.0, 0.125), cover_material, (0.0, 0.0, math.radians(-6))))
    objects.append(add_cube("spine", (0.045, 0.31, 0.07), (-0.20, 0.0, 0.115), accent_material, (0.0, 0.0, math.radians(-6))))
    objects.append(add_cube("strap", (0.035, 0.32, 0.045), (0.08, 0.0, 0.155), accent_material, (0.0, 0.0, math.radians(-6))))
    if variant == 2:
        objects.append(add_ico("rare_gem", 1.0, (0.08, 0.0, 0.19), (0.045, 0.035, 0.018), materials["glow_violet"], rng, 0.004, 1))
    return combine_asset(spec["id"], objects)


BUILDERS = {
    "support": build_support,
    "wall_torch": build_wall_torch,
    "rubble": build_rubble,
    "mineral_vein": build_mineral_vein,
    "glow_mushroom": build_glow_mushroom,
    "glow_crystal": build_glow_crystal,
    "roots": build_roots,
    "book": build_book,
}


def bounding_box(obj):
    vertices = [obj.matrix_world @ vertex.co for vertex in obj.data.vertices]
    min_v = Vector((min(v.x for v in vertices), min(v.y for v in vertices), min(v.z for v in vertices)))
    max_v = Vector((max(v.x for v in vertices), max(v.y for v in vertices), max(v.z for v in vertices)))
    return min_v, max_v


def snap(value):
    return round(float(value), 4)


def material_slot_names(obj):
    return [slot.material.name for slot in obj.material_slots if slot.material]


def asset_metadata(spec, obj, relative_path):
    min_v, max_v = bounding_box(obj)
    triangle_count = len(obj.data.polygons)
    return {
        "id": spec["id"],
        "path": relative_path.replace("\\", "/"),
        "family": spec["family"],
        "anchor": spec["anchor"],
        "tags": ["cave", "generated", spec["family"]],
        "triangleCount": triangle_count,
        "boundingBox": {
            "min": [snap(min_v.x), snap(min_v.y), snap(min_v.z)],
            "max": [snap(max_v.x), snap(max_v.y), snap(max_v.z)],
            "size": [snap(max_v.x - min_v.x), snap(max_v.y - min_v.y), snap(max_v.z - min_v.z)],
        },
        "pivotCheck": {
            "origin": [snap(obj.location.x), snap(obj.location.y), snap(obj.location.z)],
            "anchorAligned": anchor_aligned(spec["anchor"], min_v, max_v),
            "minZ": snap(min_v.z),
            "maxZ": snap(max_v.z),
            "originXYCentered": abs(float(obj.location.x)) <= 0.001 and abs(float(obj.location.y)) <= 0.001,
        },
        "materialSlots": material_slot_names(obj),
        "previewNotes": spec["notes"],
    }


def anchor_aligned(anchor, min_v, max_v):
    if anchor == "ground":
        return abs(float(min_v.z)) <= 0.055
    if anchor == "ceiling":
        return abs(float(max_v.z)) <= 0.12 or abs(float(min_v.z)) <= 0.055
    if anchor == "wall":
        return abs(float(max_v.y)) <= 0.18 or abs(float(min_v.y)) <= 0.18
    return True


def export_glb(obj, filepath):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(
        filepath=str(filepath),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_materials="EXPORT",
    )


def place_for_gallery(obj, spec, index):
    row = index // GALLERY_COLUMNS
    column = index % GALLERY_COLUMNS
    obj.location.x = (column - (GALLERY_COLUMNS - 1) * 0.5) * GALLERY_SPACING_X
    obj.location.y = -row * GALLERY_SPACING_Y
    if spec["anchor"] == "ceiling":
        obj.location.z = 1.45
    elif spec["anchor"] == "wall":
        obj.location.z = 0.35
    else:
        obj.location.z = 0.0


def add_gallery_label(text, obj, materials):
    bpy.ops.object.text_add(location=(obj.location.x - 1.04, obj.location.y - 1.05, 0.03), rotation=(math.radians(90), 0, 0))
    label = bpy.context.object
    label.name = f"label_{text}"
    label.data.body = text
    label.data.align_x = "LEFT"
    label.data.size = 0.17
    label.data.align_y = "CENTER"
    label.data.materials.append(materials["book_pages"])
    return label


def setup_gallery_camera(asset_count):
    rows = math.ceil(asset_count / GALLERY_COLUMNS)
    center_x = 0.0
    center_y = -((rows - 1) * GALLERY_SPACING_Y) * 0.5
    camera_data = bpy.data.cameras.new("CaveAssetGalleryCamera")
    camera = bpy.data.objects.new("CaveAssetGalleryCamera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (center_x, center_y - 18.0, 7.4)
    target = Vector((center_x, center_y, 1.1))
    direction = target - Vector(camera.location)
    camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = max(20.5, rows * 3.85)
    bpy.context.scene.camera = camera

    bpy.ops.object.light_add(type="AREA", location=(center_x - 4.0, center_y - 6.2, 7.2))
    key = bpy.context.object
    key.name = "CaveGalleryKeyLight"
    key.data.energy = 520.0
    key.data.size = 7.0

    bpy.ops.object.light_add(type="POINT", location=(center_x + 4.0, center_y + 1.5, 4.0))
    fill = bpy.context.object
    fill.name = "CaveGalleryFillLight"
    fill.data.energy = 80.0


def render_contact_sheet(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        bpy.context.scene.render.engine = "BLENDER_WORKBENCH"
        bpy.context.scene.display.shading.light = "STUDIO"
        bpy.context.scene.display.shading.color_type = "MATERIAL"
    except Exception:
        pass
    bpy.context.scene.world.color = (0.08, 0.08, 0.08)
    bpy.context.scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    normalize_png(path)


def render_preview(path, materials):
    reset_scene()
    materials = make_materials()
    rng = random.Random(f"{SEED}:preview")

    add_cube("floor", (3.8, 4.2, 0.08), (0.0, 0.0, -0.04), materials["cave_soil"])
    add_cube("left_wall", (0.20, 4.2, 2.45), (-2.05, 0.0, 1.18), materials["cave_stone_dark"])
    add_cube("right_wall", (0.20, 4.2, 2.45), (2.05, 0.0, 1.18), materials["cave_stone_dark"])
    add_cube("ceiling", (3.95, 4.2, 0.16), (0.0, 0.0, 2.58), materials["cave_stone_dark"])
    for index in range(18):
        side = -1 if index % 2 == 0 else 1
        x = side * rng.uniform(1.65, 2.03)
        y = rng.uniform(-1.95, 1.95)
        z = rng.uniform(0.18, 2.22)
        rough_rock(f"wall_rock_{index}", (x, y, z), (rng.uniform(0.16, 0.32), 0.08, rng.uniform(0.12, 0.28)), materials["cave_stone"], rng)

    preview_specs = [
        ("cave_support_02", (0.0, 0.55, 0.0), 0.0),
        ("wall_torch_01", (-1.82, -0.55, 0.82), 0.0),
        ("wall_torch_02", (1.82, 0.72, 0.82), math.pi),
        ("cave_roots_01", (-0.72, -1.20, 2.58), 0.0),
        ("cave_rubble_02", (-0.82, 0.82, 0.0), 0.0),
        ("mineral_vein_copper_01", (-1.92, 0.92, 0.20), 0.0),
        ("glow_mushroom_02", (-1.15, -1.62, 0.0), 0.0),
        ("glow_crystal_01", (1.16, 1.28, 0.0), 0.0),
        ("crafting_book_progression", (0.0, 1.52, 0.05), 0.0),
    ]
    for asset_id, location, rotation_z in preview_specs:
        spec = next(item for item in ASSET_SPECS if item["id"] == asset_id)
        obj = BUILDERS[spec["builder"]](spec, materials, stable_rng(asset_id))
        obj.location = location
        obj.rotation_euler.z = rotation_z

    bpy.ops.object.light_add(type="POINT", location=(-1.75, -0.55, 1.62))
    torch_a = bpy.context.object
    torch_a.name = "TorchWarmLightA"
    torch_a.data.color = (1.0, 0.55, 0.20)
    torch_a.data.energy = 260.0
    torch_a.data.shadow_soft_size = 3.0

    bpy.ops.object.light_add(type="POINT", location=(1.75, 0.72, 1.62))
    torch_b = bpy.context.object
    torch_b.name = "TorchWarmLightB"
    torch_b.data.color = (1.0, 0.62, 0.28)
    torch_b.data.energy = 155.0
    torch_b.data.shadow_soft_size = 2.4

    bpy.ops.object.light_add(type="POINT", location=(1.14, 1.25, 0.45))
    crystal_light = bpy.context.object
    crystal_light.name = "CrystalCoolLight"
    crystal_light.data.color = (0.35, 0.78, 1.0)
    crystal_light.data.energy = 45.0
    crystal_light.data.shadow_soft_size = 2.0

    camera_data = bpy.data.cameras.new("CaveInteriorPreviewCamera")
    camera = bpy.data.objects.new("CaveInteriorPreviewCamera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (0.0, -4.35, 1.20)
    target = Vector((0.0, 0.15, 1.05))
    direction = target - Vector(camera.location)
    camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    camera.data.lens = 25
    bpy.context.scene.camera = camera

    bpy.context.scene.render.resolution_x = 1280
    bpy.context.scene.render.resolution_y = 720
    try:
        bpy.context.scene.render.engine = "BLENDER_EEVEE_NEXT"
    except Exception:
        bpy.context.scene.render.engine = "BLENDER_EEVEE"
    bpy.context.scene.world.color = (0.012, 0.014, 0.014)
    bpy.context.scene.view_settings.exposure = -0.35
    bpy.context.scene.view_settings.gamma = 1.0
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.context.scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    normalize_png(path)


def normalize_png(path):
    data = path.read_bytes()
    signature = b"\x89PNG\r\n\x1a\n"
    if not data.startswith(signature):
        return
    offset = len(signature)
    chunks = []
    while offset + 8 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + length]
        offset += 12 + length
        if chunk_type in {b"IHDR", b"PLTE", b"IDAT", b"IEND"}:
            chunks.append((chunk_type, chunk_data))
        if chunk_type == b"IEND":
            break
    output = bytearray(signature)
    for chunk_type, chunk_data in chunks:
        output.extend(struct.pack(">I", len(chunk_data)))
        output.extend(chunk_type)
        output.extend(chunk_data)
        output.extend(struct.pack(">I", zlib.crc32(chunk_type + chunk_data) & 0xFFFFFFFF))
    path.write_bytes(bytes(output))


def family_counts():
    counts = {}
    for spec in ASSET_SPECS:
        counts[spec["family"]] = counts.get(spec["family"], 0) + 1
    return counts


def main():
    args = parse_args()
    output_root = Path(args.output_root).resolve()
    manifest_path = Path(args.manifest).resolve()
    contact_sheet_path = Path(args.contact_sheet).resolve()
    preview_path = Path(args.preview_render).resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)

    reset_scene()
    materials = make_materials()
    assets = []
    for index, spec in enumerate(ASSET_SPECS):
        rng = stable_rng(spec["id"])
        obj = BUILDERS[spec["builder"]](spec, materials, rng)
        glb_path = output_root / f"{spec['id']}.glb"
        export_glb(obj, glb_path)
        relative_path = Path("assets/visual/generated/caves") / glb_path.name
        metadata = asset_metadata(spec, obj, str(relative_path))
        if metadata["triangleCount"] <= 0 or metadata["triangleCount"] > TRIANGLE_LIMIT:
            raise RuntimeError(f"{spec['id']} triangle count outside allowed range: {metadata['triangleCount']}")
        assets.append(metadata)
        place_for_gallery(obj, spec, index)
        add_gallery_label(spec["id"], obj, materials)

    setup_gallery_camera(len(ASSET_SPECS))
    render_contact_sheet(contact_sheet_path)
    render_preview(preview_path, materials)

    manifest = {
        "schemaVersion": 1,
        "generator": GENERATOR_VERSION,
        "seed": SEED,
        "coordinateSystem": "Blender Z-up source; GLB import pending Godot integration after approval",
        "triangleLimit": TRIANGLE_LIMIT,
        "assetDirectory": "assets/visual/generated/caves",
        "contactSheet": "assets/visual/generated/caves/contact-sheet.png",
        "interiorPreview": "assets/visual/generated/caves/cave-interior-preview.png",
        "assets": assets,
        "families": family_counts(),
        "placementGuidance": {
            "cave_support": "Use sparingly in mined or reinforced sections, not throughout every natural cave.",
            "cave_glow_flora": "Singular mushroom assets; place individually or let gameplay systems decide clustering.",
            "stalactitesAndStalagmites": "Generate procedurally from terrain/cave shaping, not from fixed GLB assets.",
            "caveMouth": "Entrance should be a procedural terrain opening into the cavern, not a fixed GLB mouth."
        },
        "materialVocabulary": sorted(MATERIAL_SPECS.keys()),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {len(assets)} cave assets")
    print(f"Manifest: {manifest_path}")
    print(f"Contact sheet: {contact_sheet_path}")
    print(f"Interior preview: {preview_path}")


if __name__ == "__main__":
    main()

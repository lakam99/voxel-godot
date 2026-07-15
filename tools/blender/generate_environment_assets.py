import argparse
import json
import math
import random
import struct
import sys
import zlib
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector


GENERATOR_VERSION = "vox128-age-ecology-environment-v1"
SEED = 1492
TRIANGLE_LIMIT = 2200
TREE_TRIANGLE_LIMIT = 6200
GALLERY_COLUMNS = 5
GALLERY_SPACING_X = 38.0
GALLERY_SPACING_Z = 46.0
WIND_ATTRIBUTE_NAME = "wind"
BARK_REPEATS_PER_METER = 0.72
ECOLOGY_AGE_BANDS = ("young", "established", "mature", "old", "ancient")
TREE_FAMILIES = {
    "broadleaf_tree",
    "conifer_tree",
    "savanna_tree",
    "mature_broadleaf_tree",
    "old_growth_broadleaf_tree",
    "mature_conifer_tree",
    "mature_savanna_tree",
    "ecological_broadleaf_tree",
    "ecological_conifer_tree",
    "ecological_savanna_tree",
}
CANOPY_FAMILIES = {
    "mature_broadleaf_tree",
    "old_growth_broadleaf_tree",
    "mature_conifer_tree",
    "mature_savanna_tree",
    "ecological_broadleaf_tree",
    "ecological_conifer_tree",
    "ecological_savanna_tree",
}

MATERIAL_SPECS = {
    "trunk": (0.42, 0.22, 0.10, 1.0),
    "bark_dark": (0.26, 0.14, 0.08, 1.0),
    "cut_wood": (0.78, 0.56, 0.32, 1.0),
    "leaf_primary": (0.18, 0.46, 0.22, 1.0),
    "leaf_secondary": (0.32, 0.62, 0.28, 1.0),
    "leaf_warm": (0.42, 0.55, 0.22, 1.0),
    "needle_primary": (0.10, 0.35, 0.24, 1.0),
    "needle_secondary": (0.16, 0.46, 0.30, 1.0),
    "savanna_leaf": (0.42, 0.50, 0.22, 1.0),
    "rock_primary": (0.46, 0.49, 0.45, 1.0),
    "rock_accent": (0.30, 0.36, 0.36, 1.0),
    "moss": (0.22, 0.38, 0.22, 1.0),
}

ASSET_SPECS = [
    *[
        {
            "id": f"broadleaf_{index:02d}",
            "family": "broadleaf_tree",
            "biomes": ["forest", "plains"],
            "builder": "broadleaf",
            "variant": index,
        }
        for index in range(1, 7)
    ],
    *[
        {
            "id": f"conifer_{index:02d}",
            "family": "conifer_tree",
            "biomes": ["taiga", "snow", "alpine"],
            "builder": "conifer",
            "variant": index,
        }
        for index in range(1, 5)
    ],
    *[
        {
            "id": f"savanna_{index:02d}",
            "family": "savanna_tree",
            "biomes": ["savanna", "plains", "desert"],
            "builder": "savanna",
            "variant": index,
        }
        for index in range(1, 4)
    ],
    *[
        {
            "id": f"ecological_broadleaf_{age_band}_{variant:02d}",
            "family": "ecological_broadleaf_tree",
            "biomes": ["forest", "plains", "swamp", "beach"],
            "builder": "ecological_broadleaf",
            "variant": variant,
            "growthClass": age_band,
            "ageBand": age_band,
            "architecture": "broadleaf",
            "runtimeEnabled": True,
        }
        for age_band in ECOLOGY_AGE_BANDS
        for variant in range(1, 3)
    ],
    *[
        {
            "id": f"ecological_conifer_{age_band}_{variant:02d}",
            "family": "ecological_conifer_tree",
            "biomes": ["taiga", "snow", "alpine", "tundra"],
            "builder": "ecological_conifer",
            "variant": variant,
            "growthClass": age_band,
            "ageBand": age_band,
            "architecture": "conifer",
            "runtimeEnabled": True,
        }
        for age_band in ECOLOGY_AGE_BANDS
        for variant in range(1, 3)
    ],
    *[
        {
            "id": f"ecological_savanna_{age_band}_{variant:02d}",
            "family": "ecological_savanna_tree",
            "biomes": ["savanna", "plains", "desert", "beach"],
            "builder": "ecological_savanna",
            "variant": variant,
            "growthClass": age_band,
            "ageBand": age_band,
            "architecture": "savanna",
            "runtimeEnabled": True,
        }
        for age_band in ECOLOGY_AGE_BANDS
        for variant in range(1, 3)
    ],
    *[
        {
            "id": f"mature_broadleaf_{index:02d}",
            "family": "mature_broadleaf_tree",
            "biomes": ["forest", "plains", "swamp"],
            "builder": "mature_broadleaf",
            "variant": index,
            "growthClass": "mature",
            "runtimeEnabled": True,
        }
        for index in range(1, 5)
    ],
    *[
        {
            "id": f"old_growth_broadleaf_{index:02d}",
            "family": "old_growth_broadleaf_tree",
            "biomes": ["forest"],
            "builder": "old_growth_broadleaf",
            "variant": index,
            "growthClass": "old_growth",
            "runtimeEnabled": True,
        }
        for index in range(1, 3)
    ],
    *[
        {
            "id": f"mature_conifer_{index:02d}",
            "family": "mature_conifer_tree",
            "biomes": ["taiga", "snow", "alpine", "tundra"],
            "builder": "mature_conifer",
            "variant": index,
            "growthClass": "mature",
            "runtimeEnabled": True,
        }
        for index in range(1, 5)
    ],
    *[
        {
            "id": f"mature_savanna_{index:02d}",
            "family": "mature_savanna_tree",
            "biomes": ["savanna", "plains", "desert"],
            "builder": "mature_savanna",
            "variant": index,
            "growthClass": "mature",
            "runtimeEnabled": True,
        }
        for index in range(1, 4)
    ],
    *[
        {
            "id": f"rock_{index:02d}",
            "family": "rock",
            "biomes": ["plains", "forest", "mountain", "beach", "snow"],
            "builder": "rock",
            "variant": index,
        }
        for index in range(1, 7)
    ],
    *[
        {
            "id": f"bush_{index:02d}",
            "family": "bush",
            "biomes": ["forest", "plains", "savanna"],
            "builder": "bush",
            "variant": index,
        }
        for index in range(1, 5)
    ],
    *[
        {
            "id": f"stump_log_{index:02d}",
            "family": "stump_log",
            "biomes": ["forest", "taiga", "plains"],
            "builder": "stump_log",
            "variant": index,
        }
        for index in range(1, 4)
    ],
]


def parse_args():
    parser = argparse.ArgumentParser(description="Generate deterministic low-poly environment assets.")
    parser.add_argument("--output-root", required=True, help="Project-relative or absolute assets/visual/generated directory.")
    parser.add_argument("--manifest", required=True, help="Manifest JSON output path.")
    parser.add_argument("--contact-sheet", required=True, help="Gallery PNG output path.")
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(args)


def reset_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.render.resolution_x = 3200
    bpy.context.scene.render.resolution_y = 3600
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
        materials[name] = material
    return materials


def stable_rng(asset_id):
    return random.Random(f"{SEED}:{asset_id}")


def apply_object_transform(obj):
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def assign_material(obj, material):
    obj.data.materials.append(material)
    for polygon in obj.data.polygons:
        polygon.material_index = 0


def author_bark_uv(obj, repeats_per_meter=BARK_REPEATS_PER_METER):
    """Author branch-local, physical-length bark coordinates before transforms.

    Cylinder/cone primitives are created along local Z. U follows circumference
    and V follows local metric length, so forks and elongated trunks do not smear
    one normalized texture over their full height. Caps use a compact planar map.
    """
    mesh = obj.data
    uv_layer = mesh.uv_layers.get("UVMap") or mesh.uv_layers.new(name="UVMap")
    z_values = [vertex.co.z for vertex in mesh.vertices]
    z_min = min(z_values) if z_values else 0.0
    radius = max(
        0.001,
        max((math.hypot(vertex.co.x, vertex.co.y) for vertex in mesh.vertices), default=1.0),
    )
    for polygon in mesh.polygons:
        side_face = abs(float(polygon.normal.z)) < 0.72
        raw_u = []
        if side_face:
            for loop_index in polygon.loop_indices:
                vertex = mesh.vertices[mesh.loops[loop_index].vertex_index]
                raw_u.append((math.atan2(vertex.co.y, vertex.co.x) / math.tau + 1.0) % 1.0)
            if raw_u and max(raw_u) - min(raw_u) > 0.5:
                raw_u = [value + 1.0 if value < 0.5 else value for value in raw_u]
        for local_index, loop_index in enumerate(polygon.loop_indices):
            vertex = mesh.vertices[mesh.loops[loop_index].vertex_index]
            if side_face:
                uv = (raw_u[local_index], (vertex.co.z - z_min) * repeats_per_meter)
            else:
                uv = (vertex.co.x / (radius * 2.0) + 0.5, vertex.co.y / (radius * 2.0) + 0.5)
            uv_layer.data[loop_index].uv = uv
    mesh.update()


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
    if material.name in {"trunk", "bark_dark"}:
        author_bark_uv(obj)
    apply_object_transform(obj)
    return obj


def add_cylinder(name, vertices, radius, depth, location, material, rotation=(0.0, 0.0, 0.0)):
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
    assign_material(obj, material)
    if material.name in {"trunk", "bark_dark"}:
        author_bark_uv(obj)
    apply_object_transform(obj)
    return obj


def add_ico(name, subdivisions, radius, location, scale, material, rng=None, roughness=0.0):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions, radius=radius, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    assign_material(obj, material)
    apply_object_transform(obj)
    if rng and roughness > 0.0:
        for vertex in obj.data.vertices:
            direction = vertex.co.normalized()
            vertex.co += direction * rng.uniform(-roughness, roughness)
        obj.data.update()
    return obj


def add_leaf_mesh(name, leaves, materials):
    """Build many visible individual leaf cards as one efficient foliage object.

    Each leaf is a shallow triangular card (one triangle, double-sided by the
    foliage material). Mature crowns author twice as many independently placed
    leaves as v4 without increasing the foliage triangle budget. The finished
    tree is still one exported mesh and one runtime draw object.
    """
    vertices = []
    faces = []
    face_materials = []
    material_order = []
    material_indices = {}
    for material in materials:
        if material.name not in material_indices:
            material_indices[material.name] = len(material_order)
            material_order.append(material)
    for leaf in leaves:
        center = Vector(leaf["center"])
        long_axis = Vector(leaf["axis"]).normalized()
        reference = Vector((0.0, 0.0, 1.0))
        if abs(long_axis.dot(reference)) > 0.90:
            reference = Vector((0.0, 1.0, 0.0))
        width_axis = long_axis.cross(reference).normalized()
        normal_axis = long_axis.cross(width_axis).normalized()
        roll = float(leaf.get("roll", 0.0))
        if abs(roll) > 0.0001:
            width_axis = width_axis * math.cos(roll) + normal_axis * math.sin(roll)
            normal_axis = long_axis.cross(width_axis).normalized()
        half_length = float(leaf["length"]) * 0.5
        leaf_width = float(leaf["width"]) * 0.90
        thickness = float(leaf["thickness"])
        base = len(vertices)
        vertices.extend([
            center + long_axis * half_length,
            center - long_axis * half_length + width_axis * leaf_width + normal_axis * thickness,
            center - long_axis * half_length - width_axis * leaf_width - normal_axis * thickness,
        ])
        faces.append((base + 0, base + 1, base + 2))
        material_index = material_indices[leaf["material"].name]
        face_materials.append(material_index)
    mesh = bpy.data.meshes.new(f"{name}_mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    uv_layer = mesh.uv_layers.new(name="UVMap")
    leaf_uvs = ((0.5, 1.0), (1.0, 0.0), (0.0, 0.0))
    for polygon in mesh.polygons:
        for local_index, loop_index in enumerate(polygon.loop_indices):
            uv_layer.data[loop_index].uv = leaf_uvs[local_index % 3]
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    for material in material_order:
        mesh.materials.append(material)
    for polygon_index, material_index in enumerate(face_materials):
        mesh.polygons[polygon_index].material_index = material_index
        mesh.polygons[polygon_index].use_smooth = False
    return obj


def leafy_spray_records(center, radial, leaf_count, rng, materials, length_range, width_range, spread, vertical_spread, upward_bias=0.22):
    records = []
    center_v = Vector(center)
    radial_v = Vector(radial)
    if radial_v.length < 0.001:
        radial_v = Vector((1.0, 0.0, 0.0))
    radial_v.normalize()
    tangent = Vector((-radial_v.y, radial_v.x, 0.0))
    golden_angle = math.pi * (3.0 - math.sqrt(5.0))
    for index in range(leaf_count):
        angle = index * golden_angle + rng.uniform(-0.24, 0.24)
        ring = math.sqrt((index + 0.5) / leaf_count)
        offset = radial_v * math.cos(angle) * spread * ring
        offset += tangent * math.sin(angle) * spread * ring
        offset.z = rng.uniform(-vertical_spread, vertical_spread) * (0.45 + ring * 0.55)
        axis = radial_v * rng.uniform(0.48, 0.92)
        axis += tangent * rng.uniform(-0.62, 0.62)
        axis.z = rng.uniform(-0.10, 0.42) + upward_bias
        records.append({
            "center": center_v + offset,
            "axis": axis.normalized(),
            "roll": rng.uniform(-math.pi, math.pi),
            "length": rng.uniform(*length_range),
            "width": rng.uniform(*width_range),
            "thickness": rng.uniform(0.10, 0.18),
            "material": materials[index % len(materials)],
        })
    return records


def add_branch(name, start, end, radius, vertices, material):
    start_v = Vector(start)
    end_v = Vector(end)
    midpoint = (start_v + end_v) * 0.5
    direction = end_v - start_v
    length = direction.length
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
    if material.name in {"trunk", "bark_dark"}:
        author_bark_uv(obj)
    apply_object_transform(obj)
    return obj


def add_cut_disc(name, location, radius, material, rotation=(0.0, 0.0, 0.0)):
    obj = add_cylinder(name, 12, radius, 0.035, location, material, rotation)
    return obj


def combine_asset(asset_id, objects):
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
    combined.location = (0.0, 0.0, 0.0)
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    triangulate = combined.modifiers.new("triangulate_export", "TRIANGULATE")
    bpy.context.view_layer.objects.active = combined
    combined.select_set(True)
    bpy.ops.object.modifier_apply(modifier=triangulate.name)
    for polygon in combined.data.polygons:
        polygon.use_smooth = False
    combined.data.update()
    return combined


def build_broadleaf(spec, materials, rng):
    variant = spec["variant"]
    height = 3.8 + variant * 0.18 + rng.uniform(-0.12, 0.12)
    trunk_radius = 0.16 + rng.uniform(-0.02, 0.02)
    trunk = add_cone("trunk", 7, trunk_radius * 1.08, trunk_radius * 0.68, height, (0, 0, height * 0.5), materials["trunk"])
    objects = [trunk]
    branch_count = 3 + variant % 3
    for index in range(branch_count):
        angle = (index / branch_count) * math.tau + rng.uniform(-0.28, 0.28)
        start_z = height * rng.uniform(0.48, 0.68)
        end_z = height * rng.uniform(0.72, 0.90)
        reach = rng.uniform(0.45, 0.78)
        end = (math.cos(angle) * reach, math.sin(angle) * reach, end_z)
        objects.append(add_branch(f"branch_{index}", (0, 0, start_z), end, trunk_radius * 0.35, 6, materials["bark_dark"]))
    canopy_materials = [materials["leaf_primary"], materials["leaf_secondary"]]
    lobe_count = 4 + variant % 3
    for index in range(lobe_count):
        angle = (index / lobe_count) * math.tau + rng.uniform(-0.38, 0.38)
        reach = rng.uniform(0.18, 0.65)
        loc = (
            math.cos(angle) * reach,
            math.sin(angle) * reach,
            height + rng.uniform(-0.14, 0.52),
        )
        scale = (
            rng.uniform(0.72, 1.06),
            rng.uniform(0.58, 0.92),
            rng.uniform(0.34, 0.58),
        )
        objects.append(add_ico(f"leaf_{index}", 1, 1.0, loc, scale, canopy_materials[index % 2], rng, 0.05))
    return combine_asset(spec["id"], objects)


def build_conifer(spec, materials, rng):
    variant = spec["variant"]
    height = 4.4 + variant * 0.34 + rng.uniform(-0.08, 0.08)
    trunk = add_cone("trunk", 7, 0.14, 0.08, height * 0.86, (0, 0, height * 0.43), materials["trunk"])
    objects = [trunk]
    tier_count = 3 + variant % 2
    for index in range(tier_count):
        radius = 1.05 - index * 0.18 + rng.uniform(-0.04, 0.04)
        depth = 1.30 - index * 0.12
        z = height * (0.38 + index * 0.15)
        material = materials["needle_primary"] if index % 2 == 0 else materials["needle_secondary"]
        objects.append(add_cone(f"needles_{index}", 8, radius, 0.08, depth, (0, 0, z), material))
    objects.append(add_cone("top", 8, 0.50, 0.0, 1.05, (0, 0, height - 0.22), materials["needle_secondary"]))
    return combine_asset(spec["id"], objects)


def build_savanna(spec, materials, rng):
    variant = spec["variant"]
    height = 3.5 + variant * 0.26
    lean = rng.uniform(-0.40, 0.42)
    objects = [
        add_branch("trunk", (0, 0, 0.0), (lean, 0.18, height * 0.84), 0.16, 7, materials["trunk"])
    ]
    branch_count = 3 + variant
    crown_center = Vector((lean, 0.18, height * 0.86))
    for index in range(branch_count):
        angle = (index / branch_count) * math.tau + rng.uniform(-0.24, 0.24)
        reach = rng.uniform(0.50, 0.95)
        end = crown_center + Vector((math.cos(angle) * reach, math.sin(angle) * reach, rng.uniform(0.05, 0.28)))
        objects.append(add_branch(f"branch_{index}", crown_center, end, 0.055, 6, materials["bark_dark"]))
    for index in range(3 + variant):
        angle = (index / (3 + variant)) * math.tau + rng.uniform(-0.2, 0.2)
        loc = (
            crown_center.x + math.cos(angle) * rng.uniform(0.24, 0.72),
            crown_center.y + math.sin(angle) * rng.uniform(0.18, 0.58),
            crown_center.z + rng.uniform(0.22, 0.42),
        )
        scale = (rng.uniform(0.75, 1.10), rng.uniform(0.35, 0.58), rng.uniform(0.18, 0.32))
        objects.append(add_ico(f"savanna_leaf_{index}", 1, 1.0, loc, scale, materials["savanna_leaf"], rng, 0.035))
    return combine_asset(spec["id"], objects)


def build_mature_broadleaf(spec, materials, rng):
    variant = spec["variant"]
    total_height = 12.8 + (variant - 1) * 1.55 + rng.uniform(-0.18, 0.18)
    trunk_radius = 0.46 + variant * 0.042 + rng.uniform(-0.018, 0.018)
    crown_base = total_height * rng.uniform(0.38, 0.44)
    trunk_top = total_height * rng.uniform(0.74, 0.80)
    trunk = add_cone(
        "trunk",
        9,
        trunk_radius * 1.18,
        trunk_radius * 0.62,
        trunk_top,
        (0, 0, trunk_top * 0.5),
        materials["trunk"],
    )
    objects = [trunk]
    leader_end = Vector((rng.uniform(-0.22, 0.22), rng.uniform(-0.20, 0.20), total_height - 1.18))
    objects.append(add_branch("crown_leader", (0.0, 0.0, trunk_top - 0.28), leader_end, trunk_radius * 0.22, 6, materials["bark_dark"]))
    objects.append(add_branch("crown_fork", (0.0, 0.0, trunk_top - 0.45), (leader_end.x + 0.72, leader_end.y - 0.48, leader_end.z - 0.38), trunk_radius * 0.15, 6, materials["bark_dark"]))
    branch_count = 10 + variant
    branch_ends = []
    crown_radius = 5.0 + variant * 0.50
    for index in range(branch_count):
        angle = (index / branch_count) * math.tau + rng.uniform(-0.20, 0.20)
        layer = index % 3
        start_z = crown_base + float(layer) * total_height * 0.075 + rng.uniform(0.0, total_height * 0.045)
        reach = crown_radius * rng.uniform(0.62, 1.0) * (1.0 - float(layer) * 0.055)
        end_z = min(total_height - 1.15, start_z + rng.uniform(1.30, 3.15))
        end = (math.cos(angle) * reach, math.sin(angle) * reach, end_z)
        branch_ends.append(Vector(end))
        objects.append(add_branch(f"branch_{index}", (0, 0, start_z), end, trunk_radius * rng.uniform(0.24, 0.34), 7, materials["bark_dark"]))
    canopy_materials = [materials["leaf_primary"], materials["leaf_secondary"], materials["leaf_warm"]]
    leaves = []
    for index, branch_end in enumerate(branch_ends):
        radial = Vector((branch_end.x, branch_end.y, 0.0))
        radial.normalize()
        spray_center = branch_end + radial * rng.uniform(-0.15, 0.28)
        spray_center.z = min(total_height - 1.05, max(crown_base + 1.1, spray_center.z + rng.uniform(-0.18, 0.42)))
        per_branch = 84 + variant * 4
        outer_count = int(math.ceil(per_branch * 0.62))
        inner_count = per_branch - outer_count
        leaves.extend(leafy_spray_records(
            spray_center,
            radial,
            outer_count,
            rng,
            canopy_materials[index % len(canopy_materials):] + canopy_materials[:index % len(canopy_materials)],
            (0.56, 0.92),
            (0.34, 0.58),
            1.32 + variant * 0.06,
            1.02,
            0.20,
        ))
        inner_center = Vector((branch_end.x * 0.52, branch_end.y * 0.52, max(crown_base + 0.72, branch_end.z - 0.48)))
        leaves.extend(leafy_spray_records(
            inner_center,
            radial,
            inner_count,
            rng,
            canopy_materials[(index + 1) % len(canopy_materials):] + canopy_materials[:(index + 1) % len(canopy_materials)],
            (0.52, 0.86),
            (0.32, 0.54),
            1.42,
            1.02,
            0.26,
        ))
    leaves.extend(leafy_spray_records(
        (0.0, 0.0, total_height - 1.05),
        (1.0, 0.0, 0.0),
        160 + variant * 10,
        rng,
        canopy_materials,
        (0.54, 0.90),
        (0.34, 0.56),
        2.35 + variant * 0.12,
        1.10,
        0.34,
    ))
    leaves.extend(leafy_spray_records(
        (leader_end.x * 0.55, leader_end.y * 0.55, total_height - 2.18),
        (1.0, 0.0, 0.0),
        68,
        rng,
        canopy_materials,
        (0.48, 0.78),
        (0.30, 0.50),
        1.24,
        0.82,
        0.28,
    ))
    objects.append(add_leaf_mesh("leaf_sprays", leaves, canopy_materials))
    combined = combine_asset(spec["id"], objects)
    combined["trunk_radius"] = trunk_radius
    combined["foliage_primitive_count"] = len(leaves)
    combined["foliage_structure"] = "layered_branch_attached_leaf_canopy"
    combined["crown_layer_count"] = 4
    combined["branch_cluster_count"] = branch_count
    return combined


def build_old_growth_broadleaf(spec, materials, rng):
    variant = spec["variant"]
    total_height = 17.4 + variant * 1.85 + rng.uniform(-0.20, 0.20)
    trunk_radius = 0.66 + variant * 0.075 + rng.uniform(-0.02, 0.02)
    crown_base = total_height * rng.uniform(0.36, 0.42)
    trunk_top = total_height * 0.76
    trunk = add_cone("trunk", 10, trunk_radius * 1.22, trunk_radius * 0.60, trunk_top, (0, 0, trunk_top * 0.5), materials["trunk"])
    objects = [trunk]
    leader_end = Vector((rng.uniform(-0.30, 0.30), rng.uniform(-0.28, 0.28), total_height - 1.34))
    objects.append(add_branch("crown_leader", (0.0, 0.0, trunk_top - 0.35), leader_end, trunk_radius * 0.20, 6, materials["bark_dark"]))
    objects.append(add_branch("crown_fork", (0.0, 0.0, trunk_top - 0.62), (leader_end.x - 1.05, leader_end.y + 0.76, leader_end.z - 0.52), trunk_radius * 0.14, 6, materials["bark_dark"]))
    crown_radius = 6.25 + variant * 0.70
    branch_count = 12 + variant * 2
    branch_ends = []
    for index in range(branch_count):
        angle = (index / branch_count) * math.tau + rng.uniform(-0.16, 0.16)
        layer = index % 4
        start_z = crown_base + float(layer) * total_height * 0.065 + rng.uniform(0.0, total_height * 0.035)
        reach = crown_radius * rng.uniform(0.58, 1.0) * (1.0 - float(layer) * 0.045)
        end = (math.cos(angle) * reach, math.sin(angle) * reach, min(total_height - 1.45, start_z + rng.uniform(1.9, 4.5)))
        branch_ends.append(Vector(end))
        objects.append(add_branch(f"branch_{index}", (0, 0, start_z), end, trunk_radius * rng.uniform(0.22, 0.32), 7, materials["bark_dark"]))
    canopy_materials = [materials["leaf_primary"], materials["leaf_secondary"], materials["leaf_warm"]]
    leaves = []
    for index, branch_end in enumerate(branch_ends):
        radial = Vector((branch_end.x, branch_end.y, 0.0))
        radial.normalize()
        spray_center = branch_end + radial * rng.uniform(-0.22, 0.40)
        spray_center.z = min(total_height - 1.22, max(crown_base + 1.35, spray_center.z + rng.uniform(-0.25, 0.58)))
        per_branch = 74 + variant * 4
        outer_count = int(math.ceil(per_branch * 0.62))
        inner_count = per_branch - outer_count
        leaves.extend(leafy_spray_records(
            spray_center,
            radial,
            outer_count,
            rng,
            canopy_materials[index % len(canopy_materials):] + canopy_materials[:index % len(canopy_materials)],
            (0.62, 1.02),
            (0.38, 0.64),
            1.72 + variant * 0.12,
            1.24,
            0.20,
        ))
        inner_center = Vector((branch_end.x * 0.55, branch_end.y * 0.55, max(crown_base + 0.95, branch_end.z - 0.62)))
        leaves.extend(leafy_spray_records(
            inner_center,
            radial,
            inner_count,
            rng,
            canopy_materials[(index + 1) % len(canopy_materials):] + canopy_materials[:(index + 1) % len(canopy_materials)],
            (0.58, 0.96),
            (0.36, 0.60),
            1.78,
            1.20,
            0.28,
        ))
    leaves.extend(leafy_spray_records(
        (0.0, 0.0, total_height - 1.18),
        (1.0, 0.0, 0.0),
        208 + variant * 16,
        rng,
        canopy_materials,
        (0.60, 0.98),
        (0.36, 0.62),
        2.88,
        1.36,
        0.36,
    ))
    leaves.extend(leafy_spray_records(
        (leader_end.x * 0.55, leader_end.y * 0.55, total_height - 2.55),
        (1.0, 0.0, 0.0),
        84,
        rng,
        canopy_materials,
        (0.54, 0.88),
        (0.34, 0.56),
        1.46,
        0.96,
        0.30,
    ))
    objects.append(add_leaf_mesh("old_growth_leaf_sprays", leaves, canopy_materials))
    combined = combine_asset(spec["id"], objects)
    combined["trunk_radius"] = trunk_radius
    combined["foliage_primitive_count"] = len(leaves)
    combined["foliage_structure"] = "layered_old_growth_leaf_canopy"
    combined["crown_layer_count"] = 5
    combined["branch_cluster_count"] = branch_count
    return combined


def build_mature_conifer(spec, materials, rng):
    variant = spec["variant"]
    total_height = 11.5 + (variant - 1) * 1.85 + rng.uniform(-0.16, 0.16)
    trunk_radius = 0.34 + variant * 0.035
    trunk_height = total_height * 0.94
    objects = [add_cone("trunk", 9, trunk_radius * 1.18, trunk_radius * 0.42, trunk_height, (0, 0, trunk_height * 0.5), materials["trunk"])]
    tier_count = 6 + variant
    crown_base = total_height * rng.uniform(0.22, 0.28)
    needle_materials = [materials["needle_primary"], materials["needle_secondary"]]
    needles = []
    bough_count = 0
    for index in range(tier_count):
        progress = float(index) / float(max(1, tier_count - 1))
        radius = (2.75 + variant * 0.22) * (1.0 - progress * 0.68) * rng.uniform(0.92, 1.05)
        z = crown_base + progress * (total_height - crown_base - 1.0)
        boughs_in_tier = 4 + (index + variant) % 2
        tier_rotation = index * 0.71 + rng.uniform(-0.16, 0.16)
        for bough_index in range(boughs_in_tier):
            angle = tier_rotation + float(bough_index) / float(boughs_in_tier) * math.tau
            radial = Vector((math.cos(angle), math.sin(angle), rng.uniform(-0.12, 0.10))).normalized()
            start = Vector((0.0, 0.0, z))
            end = start + Vector((radial.x * radius, radial.y * radius, radial.z * radius))
            objects.append(add_branch(f"bough_{index}_{bough_index}", start, end, max(0.045, trunk_radius * (0.16 - progress * 0.055)), 4, materials["bark_dark"]))
            tangent = Vector((-radial.y, radial.x, 0.0))
            for needle_index, distance in enumerate((0.22, 0.29, 0.37, 0.45, 0.53, 0.61, 0.69, 0.77, 0.85, 0.92, 0.98)):
                for side_index in range(2):
                    side = -1.0 if side_index == 0 else 1.0
                    center = start.lerp(end, distance)
                    center += tangent * side * (0.12 + 0.035 * float(needle_index % 3))
                    center.z += 0.06 + needle_index * 0.035 + side * 0.025
                    needles.append({
                        "center": center,
                        "axis": (radial + tangent * side * 0.16 + Vector((0.0, 0.0, 0.10 + progress * 0.12))).normalized(),
                        "roll": angle + needle_index * 0.91 + index * 0.17 + side * 0.34,
                        "length": rng.uniform(0.66, 1.12) * (1.0 - progress * 0.15),
                        "width": rng.uniform(0.38, 0.68) * (1.0 - progress * 0.10),
                        "thickness": rng.uniform(0.08, 0.14),
                        "material": needle_materials[(index + needle_index + side_index) % 2],
                    })
            bough_count += 1
    top_center = Vector((0.0, 0.0, total_height - 0.58))
    for index in range(56):
        angle = float(index) / 56.0 * math.tau
        needles.append({
            "center": top_center + Vector((math.cos(angle) * 0.28, math.sin(angle) * 0.28, rng.uniform(-0.18, 0.22))),
            "axis": Vector((math.cos(angle) * 0.34, math.sin(angle) * 0.34, 0.94)).normalized(),
            "roll": angle,
            "length": rng.uniform(0.58, 0.92),
            "width": rng.uniform(0.32, 0.52),
            "thickness": 0.09,
            "material": needle_materials[index % 2],
        })
    objects.append(add_leaf_mesh("needle_sprays", needles, needle_materials))
    combined = combine_asset(spec["id"], objects)
    combined["trunk_radius"] = trunk_radius
    combined["foliage_primitive_count"] = len(needles)
    combined["foliage_structure"] = "radial_bough_needle_sprays"
    combined["crown_layer_count"] = tier_count
    combined["branch_cluster_count"] = bough_count
    return combined


def build_mature_savanna(spec, materials, rng):
    variant = spec["variant"]
    total_height = 8.4 + (variant - 1) * 1.75 + rng.uniform(-0.12, 0.12)
    trunk_radius = 0.39 + variant * 0.045
    lean = rng.uniform(-0.72, 0.72)
    crown_base = total_height * rng.uniform(0.58, 0.65)
    crown_center = Vector((lean, rng.uniform(-0.28, 0.28), crown_base + total_height * 0.08))
    objects = [add_branch("trunk", (0, 0, 0.0), crown_center, trunk_radius, 9, materials["trunk"])]
    crown_radius = 4.1 + variant * 0.65
    branch_count = 7 + variant * 2
    branch_ends = []
    for index in range(branch_count):
        angle = (index / branch_count) * math.tau + rng.uniform(-0.20, 0.20)
        reach = crown_radius * rng.uniform(0.60, 1.0)
        end = crown_center + Vector((math.cos(angle) * reach, math.sin(angle) * reach * 0.70, rng.uniform(0.18, 0.75)))
        branch_ends.append(end)
        objects.append(add_branch(f"branch_{index}", crown_center, end, trunk_radius * 0.25, 7, materials["bark_dark"]))
    leaves = []
    savanna_materials = [materials["savanna_leaf"], materials["leaf_warm"]]
    for index, end in enumerate(branch_ends):
        radial = Vector((end.x - crown_center.x, end.y - crown_center.y, 0.0)).normalized()
        layer_offset = float(index % 3 - 1) * 0.34
        pad_center = end + Vector((0.0, 0.0, max(0.22, total_height - end.z - 0.92) + layer_offset))
        leaves.extend(leafy_spray_records(
            pad_center,
            radial,
            76 + variant * 4,
            rng,
            savanna_materials[index % 2:] + savanna_materials[:index % 2],
            (0.58, 0.94),
            (0.36, 0.60),
            1.34 + variant * 0.10,
            0.78,
            0.18,
        ))
    leaves.extend(leafy_spray_records(
        crown_center + Vector((0.0, 0.0, total_height - crown_center.z - 0.92)),
        (1.0, 0.0, 0.0),
        152 + variant * 12,
        rng,
        savanna_materials,
        (0.56, 0.90),
        (0.34, 0.58),
        2.08,
        0.82,
        0.18,
    ))
    objects.append(add_leaf_mesh("savanna_leaf_sprays", leaves, savanna_materials))
    combined = combine_asset(spec["id"], objects)
    combined["trunk_radius"] = trunk_radius
    combined["foliage_primitive_count"] = len(leaves)
    combined["foliage_structure"] = "layered_umbrella_leaf_canopy"
    combined["crown_layer_count"] = 3
    combined["branch_cluster_count"] = branch_count
    return combined


ECOLOGICAL_BROADLEAF_CONFIG = {
    "young":       {"height": 10.0, "trunk": 0.32, "crown": 3.6,  "primary": 6,  "secondary": 1, "leaves": 320},
    "established": {"height": 16.0, "trunk": 0.56, "crown": 6.0,  "primary": 9,  "secondary": 1, "leaves": 760},
    "mature":      {"height": 25.0, "trunk": 0.95, "crown": 9.5,  "primary": 12, "secondary": 2, "leaves": 1480},
    "old":         {"height": 32.0, "trunk": 1.35, "crown": 12.5, "primary": 15, "secondary": 2, "leaves": 2320},
    "ancient":     {"height": 39.0, "trunk": 1.80, "crown": 15.5, "primary": 18, "secondary": 2, "leaves": 3240},
}

ECOLOGICAL_CONIFER_CONFIG = {
    "young":       {"height": 11.0, "trunk": 0.30, "crown": 2.8, "tiers": 5,  "leaves": 320},
    "established": {"height": 17.0, "trunk": 0.48, "crown": 4.0, "tiers": 7,  "leaves": 720},
    "mature":      {"height": 25.0, "trunk": 0.75, "crown": 5.5, "tiers": 10, "leaves": 1420},
    "old":         {"height": 34.0, "trunk": 1.05, "crown": 7.0, "tiers": 13, "leaves": 2260},
    "ancient":     {"height": 43.0, "trunk": 1.40, "crown": 8.5, "tiers": 16, "leaves": 3160},
}

ECOLOGICAL_SAVANNA_CONFIG = {
    "young":       {"height": 9.0,  "trunk": 0.30, "crown": 4.8,  "primary": 5,  "secondary": 1, "leaves": 320},
    "established": {"height": 14.0, "trunk": 0.50, "crown": 7.5,  "primary": 7,  "secondary": 1, "leaves": 700},
    "mature":      {"height": 20.0, "trunk": 0.78, "crown": 10.5, "primary": 9,  "secondary": 2, "leaves": 1320},
    "old":         {"height": 26.0, "trunk": 1.08, "crown": 13.5, "primary": 11, "secondary": 2, "leaves": 2100},
    "ancient":     {"height": 32.0, "trunk": 1.45, "crown": 16.5, "primary": 13, "secondary": 2, "leaves": 3020},
}


def age_band_index(spec):
    return ECOLOGY_AGE_BANDS.index(str(spec["ageBand"]))


def record_ecological_properties(combined, spec, trunk_radius, leaf_count, structure, layers, primary_count, secondary_count, terminal_count):
    band_index = age_band_index(spec)
    combined["trunk_radius"] = trunk_radius
    combined["foliage_primitive_count"] = leaf_count
    combined["foliage_structure"] = structure
    combined["crown_layer_count"] = layers
    combined["branch_cluster_count"] = primary_count + secondary_count
    combined["age_band"] = spec["ageBand"]
    combined["architecture"] = spec["architecture"]
    combined["branch_generation_count"] = 2 if secondary_count == 0 else 3
    combined["primary_branch_count"] = primary_count
    combined["secondary_branch_count"] = secondary_count
    combined["terminal_tip_count"] = terminal_count
    combined["minimum_sector_occupancy"] = 1
    combined["nominal_growth"] = float(band_index) / float(len(ECOLOGY_AGE_BANDS) - 1)
    combined["minimum_fullness_passed"] = terminal_count >= primary_count and leaf_count >= 300
    return combined


def build_ecological_broadleaf(spec, materials, rng):
    config = ECOLOGICAL_BROADLEAF_CONFIG[spec["ageBand"]]
    variant_sign = -1.0 if spec["variant"] == 1 else 1.0
    total_height = config["height"] * (1.0 + variant_sign * 0.025 + rng.uniform(-0.012, 0.012))
    trunk_radius = config["trunk"] * (1.0 + variant_sign * 0.035)
    crown_radius = config["crown"] * (1.0 - variant_sign * 0.025)
    crown_base = total_height * (0.34 + age_band_index(spec) * 0.012)
    trunk_top = total_height * 0.72
    objects = [add_cone(
        "trunk", 10, trunk_radius * 1.24, trunk_radius * 0.50, trunk_top,
        (0.0, 0.0, trunk_top * 0.5), materials["trunk"]
    )]
    leader_end = Vector((rng.uniform(-0.35, 0.35), rng.uniform(-0.35, 0.35), total_height * 0.96))
    objects.append(add_branch(
        "leader", (0.0, 0.0, trunk_top - trunk_radius), leader_end,
        max(0.07, trunk_radius * 0.22), 6, materials["bark_dark"]
    ))
    primary_count = int(config["primary"])
    secondary_per_primary = int(config["secondary"])
    primary_ends = []
    terminals = []
    secondary_count = 0
    for index in range(primary_count):
        angle = float(index) / float(primary_count) * math.tau + variant_sign * 0.11 + rng.uniform(-0.10, 0.10)
        layer = index % 4
        start = Vector((0.0, 0.0, crown_base + layer * total_height * 0.055 + rng.uniform(0.0, total_height * 0.025)))
        layer_factor = 1.0 - layer * 0.055
        reach = crown_radius * rng.uniform(0.73, 0.96) * layer_factor
        end = Vector((math.cos(angle) * reach, math.sin(angle) * reach, min(total_height * 0.88, start.z + total_height * rng.uniform(0.12, 0.22))))
        objects.append(add_branch(
            f"primary_{index}", start, end,
            max(0.07, trunk_radius * rng.uniform(0.23, 0.33)), 7, materials["bark_dark"]
        ))
        primary_ends.append(end)
        if secondary_per_primary == 0:
            terminals.append(end)
        branch_vector = end - start
        branch_tangent = Vector((-math.sin(angle), math.cos(angle), 0.0))
        for secondary_index in range(secondary_per_primary):
            branch_start = start.lerp(end, 0.52 + secondary_index * 0.12)
            side = -1.0 if secondary_index % 2 == 0 else 1.0
            secondary_end = end + branch_tangent * side * crown_radius * rng.uniform(0.16, 0.25)
            secondary_end.z = min(total_height * 0.94, end.z + total_height * rng.uniform(0.035, 0.09))
            objects.append(add_branch(
                f"secondary_{index}_{secondary_index}", branch_start, secondary_end,
                max(0.045, trunk_radius * rng.uniform(0.10, 0.16)), 6, materials["bark_dark"]
            ))
            terminals.append(secondary_end)
            secondary_count += 1
        terminals.append(end + branch_vector.normalized() * crown_radius * 0.08)
    terminals.append(leader_end)
    leaf_materials = [materials["leaf_primary"], materials["leaf_secondary"], materials["leaf_warm"]]
    leaf_target = int(config["leaves"])
    leaves = []
    base_per_terminal = leaf_target // len(terminals)
    remainder = leaf_target % len(terminals)
    spray_scale = max(0.72, crown_radius * 0.115)
    for index, terminal in enumerate(terminals):
        radial = Vector((terminal.x, terminal.y, 0.0))
        if radial.length < 0.001:
            radial = Vector((1.0, 0.0, 0.0))
        count = base_per_terminal + (1 if index < remainder else 0)
        center = terminal.copy()
        center.z = min(total_height * 0.965, max(crown_base + 0.7, center.z))
        leaves.extend(leafy_spray_records(
            center, radial, count, rng,
            leaf_materials[index % 3:] + leaf_materials[:index % 3],
            (0.62, 1.18), (0.36, 0.70), spray_scale, spray_scale * 0.78, 0.24,
        ))
    objects.append(add_leaf_mesh("terminal_leaf_sprays", leaves, leaf_materials))
    combined = combine_asset(spec["id"], objects)
    return record_ecological_properties(
        combined, spec, trunk_radius, len(leaves), "three_generation_terminal_leaf_canopy",
        4, primary_count, secondary_count, len(terminals)
    )


def build_ecological_conifer(spec, materials, rng):
    config = ECOLOGICAL_CONIFER_CONFIG[spec["ageBand"]]
    variant_sign = -1.0 if spec["variant"] == 1 else 1.0
    total_height = config["height"] * (1.0 + variant_sign * 0.022 + rng.uniform(-0.01, 0.01))
    trunk_radius = config["trunk"] * (1.0 + variant_sign * 0.03)
    crown_radius = config["crown"] * (1.0 - variant_sign * 0.025)
    tiers = int(config["tiers"])
    trunk_height = total_height * 0.97
    objects = [add_cone(
        "trunk", 10, trunk_radius * 1.22, trunk_radius * 0.24, trunk_height,
        (0.0, 0.0, trunk_height * 0.5), materials["trunk"]
    )]
    crown_base = total_height * 0.18
    terminals = []
    primary_count = 0
    for tier in range(tiers):
        progress = float(tier) / float(max(1, tiers - 1))
        tier_radius = crown_radius * (1.0 - progress * 0.70) * rng.uniform(0.94, 1.04)
        z = crown_base + progress * (total_height - crown_base - 1.1)
        boughs = 4 + ((tier + spec["variant"]) % 2)
        rotation = tier * 0.67 + variant_sign * 0.13
        for bough in range(boughs):
            angle = rotation + float(bough) / float(boughs) * math.tau
            start = Vector((0.0, 0.0, z))
            end = Vector((math.cos(angle) * tier_radius, math.sin(angle) * tier_radius, z + tier_radius * rng.uniform(-0.05, 0.09)))
            objects.append(add_branch(
                f"bough_{tier}_{bough}", start, end,
                max(0.045, trunk_radius * (0.15 - progress * 0.045)), 4, materials["bark_dark"]
            ))
            terminals.append(end)
            primary_count += 1
    terminals.append(Vector((0.0, 0.0, total_height * 0.965)))
    needle_materials = [materials["needle_primary"], materials["needle_secondary"]]
    leaf_target = int(config["leaves"])
    base_per_terminal = leaf_target // len(terminals)
    remainder = leaf_target % len(terminals)
    needles = []
    spray = max(0.42, crown_radius * 0.105)
    for index, terminal in enumerate(terminals):
        radial = Vector((terminal.x, terminal.y, 0.12))
        if radial.length < 0.001:
            radial = Vector((0.0, 0.0, 1.0))
        count = base_per_terminal + (1 if index < remainder else 0)
        needles.extend(leafy_spray_records(
            terminal, radial, count, rng,
            needle_materials[index % 2:] + needle_materials[:index % 2],
            (0.58, 1.08), (0.30, 0.58), spray, spray * 0.70, 0.14,
        ))
    objects.append(add_leaf_mesh("terminal_needle_sprays", needles, needle_materials))
    combined = combine_asset(spec["id"], objects)
    return record_ecological_properties(
        combined, spec, trunk_radius, len(needles), "layered_radial_bough_terminal_needle_canopy",
        tiers, primary_count, 0, len(terminals)
    )


def build_ecological_savanna(spec, materials, rng):
    config = ECOLOGICAL_SAVANNA_CONFIG[spec["ageBand"]]
    variant_sign = -1.0 if spec["variant"] == 1 else 1.0
    total_height = config["height"] * (1.0 + variant_sign * 0.025 + rng.uniform(-0.012, 0.012))
    trunk_radius = config["trunk"] * (1.0 + variant_sign * 0.035)
    crown_radius = config["crown"] * (1.0 - variant_sign * 0.025)
    primary_count = int(config["primary"])
    secondary_per_primary = int(config["secondary"])
    lean = rng.uniform(-0.55, 0.55)
    crown_center = Vector((lean, rng.uniform(-0.3, 0.3), total_height * 0.68))
    objects = [add_branch("trunk", (0.0, 0.0, 0.0), crown_center, trunk_radius, 10, materials["trunk"])]
    terminals = []
    secondary_count = 0
    for index in range(primary_count):
        angle = float(index) / float(primary_count) * math.tau + variant_sign * 0.12 + rng.uniform(-0.09, 0.09)
        reach = crown_radius * rng.uniform(0.70, 0.96)
        end = crown_center + Vector((math.cos(angle) * reach, math.sin(angle) * reach * 0.74, total_height * rng.uniform(0.07, 0.16)))
        objects.append(add_branch(
            f"primary_{index}", crown_center, end,
            max(0.06, trunk_radius * rng.uniform(0.22, 0.31)), 7, materials["bark_dark"]
        ))
        tangent = Vector((-math.sin(angle), math.cos(angle), 0.0))
        for secondary_index in range(secondary_per_primary):
            side = -1.0 if secondary_index % 2 == 0 else 1.0
            branch_start = crown_center.lerp(end, 0.55 + secondary_index * 0.12)
            secondary_end = end + tangent * side * crown_radius * rng.uniform(0.13, 0.22)
            secondary_end.z += total_height * rng.uniform(0.025, 0.065)
            objects.append(add_branch(
                f"secondary_{index}_{secondary_index}", branch_start, secondary_end,
                max(0.04, trunk_radius * rng.uniform(0.10, 0.15)), 6, materials["bark_dark"]
            ))
            terminals.append(secondary_end)
            secondary_count += 1
        terminals.append(end)
    leaf_materials = [materials["savanna_leaf"], materials["leaf_warm"]]
    leaf_target = int(config["leaves"])
    base_per_terminal = leaf_target // len(terminals)
    remainder = leaf_target % len(terminals)
    leaves = []
    spray_x = max(0.76, crown_radius * 0.11)
    for index, terminal in enumerate(terminals):
        radial = Vector((terminal.x - crown_center.x, terminal.y - crown_center.y, 0.0))
        count = base_per_terminal + (1 if index < remainder else 0)
        center = terminal + Vector((0.0, 0.0, max(0.35, total_height * 0.94 - terminal.z)))
        leaves.extend(leafy_spray_records(
            center, radial, count, rng,
            leaf_materials[index % 2:] + leaf_materials[:index % 2],
            (0.68, 1.22), (0.40, 0.74), spray_x, spray_x * 0.55, 0.16,
        ))
    objects.append(add_leaf_mesh("umbrella_terminal_leaf_sprays", leaves, leaf_materials))
    combined = combine_asset(spec["id"], objects)
    return record_ecological_properties(
        combined, spec, trunk_radius, len(leaves), "three_generation_umbrella_terminal_leaf_canopy",
        3, primary_count, secondary_count, len(terminals)
    )


def build_rock(spec, materials, rng):
    variant = spec["variant"]
    radius = 0.48 + variant * 0.07
    scale = (
        radius * rng.uniform(1.00, 1.70),
        radius * rng.uniform(0.78, 1.28),
        radius * rng.uniform(0.45, 0.82),
    )
    loc = (0.0, 0.0, scale[2])
    rock = add_ico("rock", 2 if variant % 3 == 0 else 1, 1.0, loc, scale, materials["rock_primary"], rng, 0.12)
    rock.data.materials.append(materials["rock_accent"])
    for polygon in rock.data.polygons:
        if rng.random() < 0.22:
            polygon.material_index = 1
    return combine_asset(spec["id"], [rock])


def build_bush(spec, materials, rng):
    variant = spec["variant"]
    objects = []
    count = 3 + variant
    for index in range(count):
        angle = (index / count) * math.tau + rng.uniform(-0.25, 0.25)
        reach = rng.uniform(0.0, 0.35)
        loc = (
            math.cos(angle) * reach,
            math.sin(angle) * reach,
            rng.uniform(0.32, 0.58),
        )
        scale = (rng.uniform(0.38, 0.66), rng.uniform(0.30, 0.56), rng.uniform(0.25, 0.42))
        material = materials["leaf_primary"] if index % 2 == 0 else materials["leaf_secondary"]
        objects.append(add_ico(f"bush_leaf_{index}", 1, 1.0, loc, scale, material, rng, 0.04))
    if variant % 2 == 0:
        objects.append(add_branch("stem", (0, 0, 0.0), (0.0, 0.0, 0.58), 0.055, 6, materials["trunk"]))
    return combine_asset(spec["id"], objects)


def build_stump_log(spec, materials, rng):
    variant = spec["variant"]
    objects = []
    if variant == 1:
        height = 0.82
        objects.append(add_cone("stump", 10, 0.26, 0.23, height, (0, 0, height * 0.5), materials["trunk"]))
        objects.append(add_cut_disc("cut_top", (0, 0, height + 0.018), 0.24, materials["cut_wood"]))
    else:
        length = 1.25 + variant * 0.25
        radius = 0.22 + variant * 0.02
        rotation = (0.0, math.radians(90.0), rng.uniform(-0.08, 0.08))
        objects.append(add_cylinder("fallen_log", 10, radius, length, (0, 0, radius), materials["trunk"], rotation))
        objects.append(add_cut_disc("cut_a", (-length * 0.5, 0, radius), radius * 0.95, materials["cut_wood"], rotation))
        objects.append(add_cut_disc("cut_b", (length * 0.5, 0, radius), radius * 0.95, materials["cut_wood"], rotation))
        objects.append(add_branch("broken_branch", (0.12, 0.0, radius * 1.45), (0.42, 0.22, radius * 1.70), 0.045, 6, materials["bark_dark"]))
    return combine_asset(spec["id"], objects)


BUILDERS = {
    "broadleaf": build_broadleaf,
    "conifer": build_conifer,
    "savanna": build_savanna,
    "mature_broadleaf": build_mature_broadleaf,
    "old_growth_broadleaf": build_old_growth_broadleaf,
    "mature_conifer": build_mature_conifer,
    "mature_savanna": build_mature_savanna,
    "ecological_broadleaf": build_ecological_broadleaf,
    "ecological_conifer": build_ecological_conifer,
    "ecological_savanna": build_ecological_savanna,
    "rock": build_rock,
    "bush": build_bush,
    "stump_log": build_stump_log,
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


def is_foliage_material(name):
    return name.startswith("leaf_") or name.startswith("needle_") or name == "savanna_leaf"


def vertex_roles(obj):
    foliage = set()
    rigid = set()
    for polygon in obj.data.polygons:
        material = obj.material_slots[polygon.material_index].material if polygon.material_index < len(obj.material_slots) else None
        material_name = material.name if material else ""
        target = foliage if is_foliage_material(material_name) else rigid
        target.update(polygon.vertices)
    return foliage, rigid


def paint_wind_colors(spec, obj):
    if spec["family"] not in TREE_FAMILIES:
        return None
    mesh = obj.data
    old = mesh.color_attributes.get(WIND_ATTRIBUTE_NAME)
    if old:
        mesh.color_attributes.remove(old)
    attribute = mesh.color_attributes.new(name=WIND_ATTRIBUTE_NAME, type="BYTE_COLOR", domain="POINT")
    mesh.color_attributes.active_color_index = list(mesh.color_attributes).index(attribute)
    mesh.color_attributes.render_color_index = mesh.color_attributes.active_color_index
    foliage, _rigid = vertex_roles(obj)
    min_v, max_v = bounding_box(obj)
    height = max(0.001, max_v.z - min_v.z)
    variant_phase = float(spec.get("variant", 0)) * 0.173
    for index, vertex in enumerate(mesh.vertices):
        normalized_height = max(0.0, min(1.0, (vertex.co.z - min_v.z) / height))
        root_factor = max(0.0, min(1.0, (normalized_height - 0.06) / 0.94))
        foliage_factor = 1.0 if index in foliage else 0.0
        bend = (root_factor ** 1.35) * (0.32 + foliage_factor * 0.68)
        if normalized_height <= 0.06:
            bend = 0.0
        phase = (math.atan2(vertex.co.y, vertex.co.x) / math.tau + 0.5 + variant_phase + normalized_height * 0.19) % 1.0
        flutter = (0.58 + 0.38 * ((math.sin(index * 2.399 + variant_phase * 17.0) + 1.0) * 0.5)) if index in foliage else 0.02 * root_factor
        attribute.data[index].color = (bend, phase, flutter, 1.0)
    mesh.update()
    return wind_metadata(obj, attribute, foliage)


def wind_metadata(obj, attribute=None, foliage=None):
    attribute = attribute or obj.data.color_attributes.get(WIND_ATTRIBUTE_NAME)
    if attribute is None:
        return None
    foliage = foliage if foliage is not None else vertex_roles(obj)[0]
    min_v, max_v = bounding_box(obj)
    height = max(0.001, max_v.z - min_v.z)
    root_values = []
    crown_values = []
    channels = [[], [], [], []]
    for index, vertex in enumerate(obj.data.vertices):
        color = attribute.data[index].color
        for channel in range(4):
            channels[channel].append(float(color[channel]))
        normalized_height = (vertex.co.z - min_v.z) / height
        if normalized_height <= 0.08:
            root_values.append(float(color[0]))
        if index in foliage:
            crown_values.append(float(color[0]))
    names = ["bendR", "phaseG", "flutterB", "reservedA"]
    ranges = {}
    for index, name in enumerate(names):
        values = channels[index]
        ranges[name] = {
            "min": snap(min(values)),
            "max": snap(max(values)),
            "mean": snap(sum(values) / len(values)),
        }
    return {
        "attribute": "COLOR_0",
        "sourceAttribute": WIND_ATTRIBUTE_NAME,
        "domain": "POINT",
        "storage": "BYTE_COLOR",
        "vertexCount": len(obj.data.vertices),
        "foliageVertexCount": len(foliage),
        "rootVertexCount": len(root_values),
        "rootMaxBend": snap(max(root_values) if root_values else 0.0),
        "crownMinBend": snap(min(crown_values) if crown_values else 0.0),
        "crownMaxBend": snap(max(crown_values) if crown_values else 0.0),
        "channels": ranges,
    }


def tree_metrics(spec, obj):
    if spec["family"] not in TREE_FAMILIES:
        return None
    min_v, max_v = bounding_box(obj)
    foliage, _rigid = vertex_roles(obj)
    foliage_vertices = [obj.matrix_world @ obj.data.vertices[index].co for index in foliage]
    if foliage_vertices:
        foliage_min = Vector((min(v.x for v in foliage_vertices), min(v.y for v in foliage_vertices), min(v.z for v in foliage_vertices)))
        foliage_max = Vector((max(v.x for v in foliage_vertices), max(v.y for v in foliage_vertices), max(v.z for v in foliage_vertices)))
    else:
        foliage_min, foliage_max = min_v, max_v
    crown_size = foliage_max - foliage_min
    return {
        "growthClass": str(spec.get("growthClass", "legacy")),
        "height": snap(max_v.z - min_v.z),
        "trunkRadius": snap(float(obj.get("trunk_radius", 0.16))),
        "canopyRadius": snap(max(crown_size.x, crown_size.y) * 0.5),
        "canopyRadiusX": snap(crown_size.x * 0.5),
        "canopyRadiusY": snap(crown_size.y * 0.5),
        "canopyBase": snap(foliage_min.z),
        "canopyTop": snap(foliage_max.z),
    }


def bark_uv_metadata(obj):
    uv_layer = obj.data.uv_layers.get("UVMap")
    if uv_layer is None:
        return None
    values = []
    vertex_indices = set()
    for polygon in obj.data.polygons:
        material = obj.material_slots[polygon.material_index].material if polygon.material_index < len(obj.material_slots) else None
        if material is None or material.name not in {"trunk", "bark_dark"}:
            continue
        for loop_index in polygon.loop_indices:
            uv = uv_layer.data[loop_index].uv
            values.append((float(uv.x), float(uv.y)))
            vertex_indices.add(obj.data.loops[loop_index].vertex_index)
    if not values:
        return None
    return {
        "attribute": "TEXCOORD_0",
        "mapping": "branch_local_circumference_u_physical_length_v",
        "authoredRepeatsPerMeter": BARK_REPEATS_PER_METER,
        "runtimeScaleCompensation": "instance bark_scale preserves world-space repeat under visual scaling",
        "barkVertexCount": len(vertex_indices),
        "barkLoopCount": len(values),
        "uRange": [snap(min(value[0] for value in values)), snap(max(value[0] for value in values))],
        "vRange": [snap(min(value[1] for value in values)), snap(max(value[1] for value in values))],
    }


def asset_metadata(spec, obj, relative_path):
    min_v, max_v = bounding_box(obj)
    triangle_count = len(obj.data.polygons)
    metadata = {
        "id": spec["id"],
        "path": relative_path.replace("\\", "/"),
        "family": spec["family"],
        "growthClass": str(spec.get("growthClass", "legacy")),
        "ageBand": str(spec.get("ageBand", "")),
        "biomeTags": spec["biomes"],
        "triangleCount": triangle_count,
        "triangleLimit": TREE_TRIANGLE_LIMIT if spec["family"] in TREE_FAMILIES else TRIANGLE_LIMIT,
        "boundingBox": {
            "min": [snap(min_v.x), snap(min_v.y), snap(min_v.z)],
            "max": [snap(max_v.x), snap(max_v.y), snap(max_v.z)],
            "size": [snap(max_v.x - min_v.x), snap(max_v.y - min_v.y), snap(max_v.z - min_v.z)],
        },
        "pivotCheck": {
            "origin": [snap(obj.location.x), snap(obj.location.y), snap(obj.location.z)],
            "grounded": abs(float(min_v.z)) <= 0.045,
            "minZ": snap(min_v.z),
            "originXYCentered": abs(float(obj.location.x)) <= 0.001 and abs(float(obj.location.y)) <= 0.001,
        },
        "materialSlots": material_slot_names(obj),
        "materialRoles": {
            "trunkBranch": [name for name in material_slot_names(obj) if name in {"trunk", "bark_dark"}],
            "foliage": [name for name in material_slot_names(obj) if is_foliage_material(name)],
        },
        "runtimeEnabled": bool(spec.get("runtimeEnabled", True)),
        "animationContract": {
            "skeletons": 0,
            "shapeKeys": 0,
            "animationClips": 0,
        },
    }
    metrics = tree_metrics(spec, obj)
    wind = wind_metadata(obj)
    if metrics:
        metadata["treeMetrics"] = metrics
    if wind:
        metadata["windData"] = wind
    bark_uv = bark_uv_metadata(obj)
    if bark_uv:
        metadata["barkData"] = bark_uv
    foliage_primitive_count = int(obj.get("foliage_primitive_count", 0))
    if foliage_primitive_count > 0:
        metadata["canopyStructure"] = {
            "foliagePrimitive": "individual_triangular_leaf_card",
            "foliagePrimitiveCount": foliage_primitive_count,
            "structure": str(obj.get("foliage_structure", "leaf_sprays")),
            "crownLayerCount": int(obj.get("crown_layer_count", 0)),
            "branchClusterCount": int(obj.get("branch_cluster_count", 0)),
            "terminalTipCount": int(obj.get("terminal_tip_count", 0)),
        }
    if str(spec.get("ageBand", "")):
        metadata["treePhenotype"] = {
            "architecture": str(obj.get("architecture", spec.get("architecture", ""))),
            "ageBand": str(obj.get("age_band", spec["ageBand"])),
            "nominalGrowth": snap(float(obj.get("nominal_growth", 0.0))),
            "branchGenerationCount": int(obj.get("branch_generation_count", 0)),
            "primaryBranchCount": int(obj.get("primary_branch_count", 0)),
            "secondaryBranchCount": int(obj.get("secondary_branch_count", 0)),
            "terminalTipCount": int(obj.get("terminal_tip_count", 0)),
            "minimumSectorOccupancy": int(obj.get("minimum_sector_occupancy", 0)),
            "minimumFullnessPassed": bool(obj.get("minimum_fullness_passed", False)),
            "variant": int(spec["variant"]),
        }
    return metadata


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
        export_vertex_color="ACTIVE",
        export_all_vertex_colors=False,
        export_animations=False,
        export_morph=False,
        export_skins=False,
    )


def place_for_gallery(obj, index, asset_count):
    rows = math.ceil(asset_count / GALLERY_COLUMNS)
    row = index // GALLERY_COLUMNS
    column = index % GALLERY_COLUMNS
    columns_in_row = min(GALLERY_COLUMNS, asset_count - row * GALLERY_COLUMNS)
    obj.location.x = (column - (columns_in_row - 1) * 0.5) * GALLERY_SPACING_X
    obj.location.y = 0.0
    obj.location.z = (rows - row - 1) * GALLERY_SPACING_Z


def add_gallery_label(text, obj):
    bpy.ops.object.text_add(
        location=(obj.location.x - 7.0, obj.location.y - 1.0, obj.location.z + 0.25),
        rotation=(math.radians(90), 0, 0),
    )
    label = bpy.context.object
    label.name = f"label_{text}"
    label.data.body = text
    label.data.align_x = "LEFT"
    label.data.size = 0.22
    label.data.align_y = "CENTER"
    label.data.materials.append(bpy.data.materials["cut_wood"])
    return label


def setup_gallery_camera(asset_count):
    rows = math.ceil(asset_count / GALLERY_COLUMNS)
    center_x = 0.0
    center_z = ((rows - 1) * GALLERY_SPACING_Z + 22.0) * 0.5
    camera_data = bpy.data.cameras.new("AssetGalleryCamera")
    camera = bpy.data.objects.new("AssetGalleryCamera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (center_x, -100.0, center_z)
    target = Vector((center_x, 0.0, center_z))
    direction = target - Vector(camera.location)
    camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = max(56.0, rows * GALLERY_SPACING_Z + 4.0)
    bpy.context.scene.camera = camera

    bpy.ops.object.light_add(type="AREA", location=(center_x - 14.5, -18.5, center_z + 18.0))
    key = bpy.context.object
    key.name = "GalleryKeyLight"
    key.data.energy = 520.0
    key.data.size = 22.0

    bpy.ops.object.light_add(type="POINT", location=(center_x + 18.0, 9.0, center_z + 7.0))
    fill = bpy.context.object
    fill.name = "GalleryFillLight"
    fill.data.energy = 80.0


def render_contact_sheet(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        bpy.context.scene.render.engine = "BLENDER_WORKBENCH"
        bpy.context.scene.display.shading.light = "STUDIO"
        bpy.context.scene.display.shading.color_type = "MATERIAL"
    except Exception:
        pass
    bpy.context.scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    normalize_png(path)


def render_canopy_detail_sheet(gallery_objects, assets, path):
    representative_ids = [
        "ecological_broadleaf_mature_02",
        "ecological_broadleaf_ancient_02",
        "ecological_conifer_mature_02",
        "ecological_savanna_old_02",
    ]
    metadata_by_id = {asset["id"]: asset for asset in assets}
    for obj in gallery_objects.values():
        obj.hide_render = True
    for obj in bpy.context.scene.objects:
        if obj.name.startswith("label_"):
            obj.hide_render = True
    detail_objects = []
    for index, asset_id in enumerate(representative_ids):
        source = gallery_objects[asset_id]
        detail = source.copy()
        detail.data = source.data.copy()
        detail.name = f"detail_{asset_id}"
        bpy.context.collection.objects.link(detail)
        foliage_slots = {
            slot_index
            for slot_index, slot in enumerate(detail.material_slots)
            if slot.material and is_foliage_material(slot.material.name)
        }
        detail_mesh = bmesh.new()
        detail_mesh.from_mesh(detail.data)
        bmesh.ops.delete(
            detail_mesh,
            geom=[face for face in detail_mesh.faces if face.material_index not in foliage_slots],
            context="FACES",
        )
        detail_mesh.to_mesh(detail.data)
        detail_mesh.free()
        detail.data.update()
        row = index // 2
        column = index % 2
        center_x = (column - 0.5) * 36.0
        center_z = (0.5 - row) * 28.0
        metrics = metadata_by_id[asset_id]["treeMetrics"]
        crown_center = (float(metrics["canopyBase"]) + float(metrics["canopyTop"])) * 0.5
        detail.location = (center_x, 0.0, center_z - crown_center)
        detail.hide_render = False
        detail_objects.append(detail)
        bpy.ops.object.text_add(
            location=(center_x, -1.0, center_z - 12.8),
            rotation=(math.radians(90), 0, 0),
        )
        label = bpy.context.object
        label.name = f"detail_label_{asset_id}"
        label.data.body = asset_id
        label.data.align_x = "CENTER"
        label.data.size = 0.34
        label.data.materials.append(bpy.data.materials["cut_wood"])

    camera_data = bpy.data.cameras.new("CanopyDetailCamera")
    camera = bpy.data.objects.new("CanopyDetailCamera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (0.0, -100.0, 0.0)
    camera.rotation_euler = Vector((0.0, 100.0, 0.0)).to_track_quat("-Z", "Y").to_euler()
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = 64.0
    bpy.context.scene.camera = camera
    bpy.context.scene.render.resolution_x = 3600
    bpy.context.scene.render.resolution_y = 2600
    render_contact_sheet(path)
    return detail_objects


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


def main():
    args = parse_args()
    output_root = Path(args.output_root).resolve()
    environment_dir = output_root / "environment"
    manifest_path = Path(args.manifest).resolve()
    contact_sheet_path = Path(args.contact_sheet).resolve()
    environment_dir.mkdir(parents=True, exist_ok=True)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)

    reset_scene()
    materials = make_materials()
    assets = []
    gallery_specs = [spec for spec in ASSET_SPECS if spec["family"].startswith("ecological_")]
    gallery_objects = {}
    gallery_index = 0

    for index, spec in enumerate(ASSET_SPECS):
        rng = stable_rng(spec["id"])
        obj = BUILDERS[spec["builder"]](spec, materials, rng)
        paint_wind_colors(spec, obj)
        glb_path = environment_dir / f"{spec['id']}.glb"
        export_glb(obj, glb_path)
        relative_path = Path("assets/visual/generated/environment") / glb_path.name
        metadata = asset_metadata(spec, obj, str(relative_path))
        triangle_limit = int(metadata["triangleLimit"])
        if metadata["triangleCount"] <= 0 or metadata["triangleCount"] > triangle_limit:
            raise RuntimeError(f"{spec['id']} triangle count outside allowed range: {metadata['triangleCount']}")
        assets.append(metadata)
        if spec["family"].startswith("ecological_"):
            gallery_objects[spec["id"]] = obj
            place_for_gallery(obj, gallery_index, len(gallery_specs))
            add_gallery_label(spec["id"], obj)
            gallery_index += 1
        else:
            obj.hide_render = True

    setup_gallery_camera(gallery_index)
    render_contact_sheet(contact_sheet_path)
    detail_sheet_path = contact_sheet_path.with_name("tree-ecology-leaf-detail-sheet-v1.png")
    render_canopy_detail_sheet(gallery_objects, assets, detail_sheet_path)

    manifest = {
        "schemaVersion": 3,
        "generator": GENERATOR_VERSION,
        "seed": SEED,
        "coordinateSystem": "Blender Z-up source; GLB import verified in Godot",
        "triangleLimit": TREE_TRIANGLE_LIMIT,
        "standardTriangleLimit": TRIANGLE_LIMIT,
        "ecologicalTreeTriangleLimit": TREE_TRIANGLE_LIMIT,
        "environmentDirectory": "assets/visual/generated/environment",
        "contactSheet": f"assets/visual/generated/environment/{contact_sheet_path.name}",
        "canopyDetailSheet": f"assets/visual/generated/environment/{detail_sheet_path.name}",
        "assets": assets,
        "families": {
            "broadleaf_tree": 6,
            "conifer_tree": 4,
            "savanna_tree": 3,
            "mature_broadleaf_tree": 4,
            "old_growth_broadleaf_tree": 2,
            "mature_conifer_tree": 4,
            "mature_savanna_tree": 3,
            "ecological_broadleaf_tree": 10,
            "ecological_conifer_tree": 10,
            "ecological_savanna_tree": 10,
            "rock": 6,
            "bush": 4,
            "stump_log": 3,
        },
        "windEncoding": {
            "attribute": "COLOR_0",
            "sourceAttribute": WIND_ATTRIBUTE_NAME,
            "R": "main bend weight, zero at root and increasing into crown",
            "G": "stable per-vertex phase offset",
            "B": "foliage detail flutter weight",
            "A": "reserved/AO, currently one",
        },
        "treeEcology": {
            "ageBands": list(ECOLOGY_AGE_BANDS),
            "variantsPerArchitectureAndAgeBand": 2,
            "selectionAuthority": "seed + biome + continuous local maturity + stable tree genetics",
            "runtimeMeshGeneration": False,
            "minimumFullness": "every primary sector has terminal foliage and each phenotype has at least 300 individual foliage cards",
        },
        "barkEncoding": {
            "attribute": "TEXCOORD_0",
            "mapping": "branch-local U circumference and V physical length",
            "authoredRepeatsPerMeter": BARK_REPEATS_PER_METER,
            "runtimeScaleCompensation": "instance shader bark_scale",
        },
        "materialVocabulary": sorted(MATERIAL_SPECS.keys()),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {len(assets)} environment assets")
    print(f"Manifest: {manifest_path}")
    print(f"Contact sheet: {contact_sheet_path}")
    print(f"Canopy detail sheet: {detail_sheet_path}")


if __name__ == "__main__":
    main()

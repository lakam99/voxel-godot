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


GENERATOR_VERSION = "phase5-environment-v1"
SEED = 1492
TRIANGLE_LIMIT = 2200
GALLERY_COLUMNS = 7
GALLERY_SPACING_X = 3.1
GALLERY_SPACING_Y = 3.45

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
    bpy.context.scene.render.resolution_x = 2600
    bpy.context.scene.render.resolution_y = 1600
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


def asset_metadata(spec, obj, relative_path):
    min_v, max_v = bounding_box(obj)
    triangle_count = len(obj.data.polygons)
    return {
        "id": spec["id"],
        "path": relative_path.replace("\\", "/"),
        "family": spec["family"],
        "biomeTags": spec["biomes"],
        "triangleCount": triangle_count,
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
    }


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


def place_for_gallery(obj, index):
    row = index // GALLERY_COLUMNS
    column = index % GALLERY_COLUMNS
    obj.location.x = (column - (GALLERY_COLUMNS - 1) * 0.5) * GALLERY_SPACING_X
    obj.location.y = -row * GALLERY_SPACING_Y


def add_gallery_label(text, obj):
    bpy.ops.object.text_add(location=(obj.location.x - 0.95, obj.location.y - 1.18, 0.02), rotation=(math.radians(90), 0, 0))
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
    center_y = -((rows - 1) * GALLERY_SPACING_Y) * 0.5
    camera_data = bpy.data.cameras.new("AssetGalleryCamera")
    camera = bpy.data.objects.new("AssetGalleryCamera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (center_x, center_y - 16.5, 7.7)
    target = Vector((center_x, center_y, 2.0))
    direction = target - Vector(camera.location)
    camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = max(25.5, rows * 4.1)
    bpy.context.scene.camera = camera

    bpy.ops.object.light_add(type="AREA", location=(center_x - 4.5, center_y - 6.5, 8.0))
    key = bpy.context.object
    key.name = "GalleryKeyLight"
    key.data.energy = 520.0
    key.data.size = 8.0

    bpy.ops.object.light_add(type="POINT", location=(center_x + 5.0, center_y + 2.0, 5.0))
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

    for index, spec in enumerate(ASSET_SPECS):
        rng = stable_rng(spec["id"])
        obj = BUILDERS[spec["builder"]](spec, materials, rng)
        glb_path = environment_dir / f"{spec['id']}.glb"
        export_glb(obj, glb_path)
        relative_path = Path("assets/visual/generated/environment") / glb_path.name
        metadata = asset_metadata(spec, obj, str(relative_path))
        if metadata["triangleCount"] <= 0 or metadata["triangleCount"] > TRIANGLE_LIMIT:
            raise RuntimeError(f"{spec['id']} triangle count outside allowed range: {metadata['triangleCount']}")
        assets.append(metadata)
        place_for_gallery(obj, index)
        add_gallery_label(spec["id"], obj)

    setup_gallery_camera(len(ASSET_SPECS))
    render_contact_sheet(contact_sheet_path)

    manifest = {
        "schemaVersion": 1,
        "generator": GENERATOR_VERSION,
        "seed": SEED,
        "coordinateSystem": "Blender Z-up source; GLB import verified in Godot",
        "triangleLimit": TRIANGLE_LIMIT,
        "environmentDirectory": "assets/visual/generated/environment",
        "contactSheet": "assets/visual/generated/environment/contact-sheet.png",
        "assets": assets,
        "families": {
            "broadleaf_tree": 6,
            "conifer_tree": 4,
            "savanna_tree": 3,
            "rock": 6,
            "bush": 4,
            "stump_log": 3,
        },
        "materialVocabulary": sorted(MATERIAL_SPECS.keys()),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {len(assets)} environment assets")
    print(f"Manifest: {manifest_path}")
    print(f"Contact sheet: {contact_sheet_path}")


if __name__ == "__main__":
    main()

import argparse
import json
import math
import random
import sys
from pathlib import Path

import bpy
from mathutils import Vector


GENERATOR_VERSION = "phase10-characters-v1"
SEED = 1492
TRIANGLE_LIMIT = 900
GALLERY_COLUMNS = 6
GALLERY_SPACING_X = 2.15
GALLERY_SPACING_Y = 2.25

MATERIAL_SPECS = {
    "cloth": (0.36, 0.42, 0.34, 1.0),
    "accent": (0.82, 0.62, 0.34, 1.0),
    "skin": (0.76, 0.55, 0.39, 1.0),
    "hair": (0.24, 0.14, 0.08, 1.0),
    "hostile": (0.12, 0.12, 0.22, 1.0),
    "hostile_accent": (0.22, 0.10, 0.32, 1.0),
    "hostile_eye": (0.62, 0.90, 1.0, 1.0),
    "rift_core": (0.94, 0.36, 0.88, 1.0),
    "frost": (0.20, 0.34, 0.42, 1.0),
}

ASSET_SPECS = [
    *[
        {"id": f"npc_torso_{index:02d}", "family": "npc_torso", "builder": "npc_torso", "variant": index}
        for index in range(1, 4)
    ],
    *[
        {"id": f"npc_head_{index:02d}", "family": "npc_head", "builder": "npc_head", "variant": index}
        for index in range(1, 4)
    ],
    *[
        {"id": f"npc_headwear_{index:02d}", "family": "npc_headwear", "builder": "npc_headwear", "variant": index}
        for index in range(1, 5)
    ],
    *[
        {"id": f"npc_arm_{index:02d}", "family": "npc_arm", "builder": "npc_arm", "variant": index}
        for index in range(1, 3)
    ],
    *[
        {
            "id": f"hostile_torso_{variant}",
            "family": "hostile_torso",
            "builder": "hostile_torso",
            "variant": variant,
        }
        for variant in ["shadow", "frost", "seer", "rift", "skitter"]
    ],
    *[
        {
            "id": f"hostile_head_{variant}",
            "family": "hostile_head",
            "builder": "hostile_head",
            "variant": variant,
        }
        for variant in ["shadow", "frost", "seer", "rift", "skitter"]
    ],
    *[
        {"id": f"hostile_eye_{index:02d}", "family": "hostile_eye", "builder": "hostile_eye", "variant": index}
        for index in range(1, 4)
    ],
    *[
        {"id": f"hostile_core_{index:02d}", "family": "hostile_core", "builder": "hostile_core", "variant": index}
        for index in range(1, 3)
    ],
    *[
        {"id": f"hostile_shard_{index:02d}", "family": "hostile_shard", "builder": "hostile_shard", "variant": index}
        for index in range(1, 4)
    ],
]


def parse_args():
    parser = argparse.ArgumentParser(description="Generate deterministic low-poly character assets.")
    parser.add_argument("--output-root", required=True, help="Project-relative or absolute assets/visual/generated directory.")
    parser.add_argument("--manifest", required=True, help="Manifest JSON output path.")
    parser.add_argument("--contact-sheet", required=True, help="Gallery PNG output path.")
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(args)


def reset_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.render.resolution_x = 2200
    bpy.context.scene.render.resolution_y = 1500
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
            bsdf.inputs["Roughness"].default_value = 0.78
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


def add_cone(name, vertices, radius1, radius2, depth, location, material, rotation=(0.0, 0.0, 0.0), scale=(1.0, 1.0, 1.0)):
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
    obj.scale = scale
    assign_material(obj, material)
    apply_object_transform(obj)
    return obj


def add_cylinder(name, vertices, radius, depth, location, material, rotation=(0.0, 0.0, 0.0), scale=(1.0, 1.0, 1.0)):
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
    obj.scale = scale
    assign_material(obj, material)
    apply_object_transform(obj)
    return obj


def add_sphere(name, radius, location, material, segments=8, rings=4, scale=(1.0, 1.0, 1.0)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=rings, radius=radius, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    assign_material(obj, material)
    apply_object_transform(obj)
    return obj


def add_cube(name, size, location, material, rotation=(0.0, 0.0, 0.0)):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = size
    assign_material(obj, material)
    apply_object_transform(obj)
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
    min_z = min(vertex.co.z for vertex in combined.data.vertices)
    for vertex in combined.data.vertices:
        vertex.co.z -= min_z
    combined.data.update()
    return combined


def build_npc_torso(spec, materials, rng):
    variant = int(spec["variant"])
    height = 0.86 + variant * 0.035
    bottom = 0.34 + rng.uniform(-0.015, 0.02)
    top = 0.24 + rng.uniform(-0.015, 0.018)
    torso = add_cone("cloth_tunic", 8, bottom, top, height, (0.0, 0.0, height * 0.5), materials["cloth"], scale=(0.92, 0.78, 1.0))
    belt = add_cylinder("accent_belt", 8, bottom * 1.03, 0.075, (0.0, 0.0, height * 0.42), materials["accent"], scale=(0.98, 0.78, 1.0))
    collar = add_cylinder("accent_collar", 8, top * 1.04, 0.06, (0.0, 0.0, height * 0.96), materials["accent"], scale=(0.86, 0.70, 1.0))
    hem = add_cylinder("accent_hem", 8, bottom * 1.06, 0.055, (0.0, 0.0, 0.035), materials["accent"], scale=(1.0, 0.78, 1.0))
    if variant == 3:
        cloak = add_cube("accent_back_cloak", (0.46, 0.08, 0.62), (0.0, 0.31, height * 0.50), materials["accent"])
        return combine_asset(spec["id"], [torso, belt, collar, hem, cloak])
    return combine_asset(spec["id"], [torso, belt, collar, hem])


def build_npc_head(spec, materials, rng):
    variant = int(spec["variant"])
    head = add_sphere("skin_head", 0.24 + variant * 0.008, (0.0, 0.0, 0.20), materials["skin"], segments=10, rings=5, scale=(0.88, 0.82, 1.02))
    nose = add_cube("skin_nose", (0.075, 0.105, 0.055), (0.0, -0.205, 0.205), materials["skin"], rotation=(0.0, 0.0, math.radians(4.0 * variant)))
    ear_left = add_sphere("skin_ear_l", 0.045, (-0.205, 0.0, 0.205), materials["skin"], segments=6, rings=3, scale=(0.60, 0.36, 0.82))
    ear_right = add_sphere("skin_ear_r", 0.045, (0.205, 0.0, 0.205), materials["skin"], segments=6, rings=3, scale=(0.60, 0.36, 0.82))
    return combine_asset(spec["id"], [head, nose, ear_left, ear_right])


def build_npc_headwear(spec, materials, rng):
    variant = int(spec["variant"])
    objects = []
    if variant == 1:
        objects.append(add_sphere("accent_hood", 0.28, (0.0, 0.012, 0.16), materials["accent"], segments=9, rings=4, scale=(0.98, 0.82, 0.66)))
        objects.append(add_cube("accent_hood_back", (0.34, 0.10, 0.16), (0.0, 0.20, 0.08), materials["accent"]))
    elif variant == 2:
        for i in range(7):
            angle = -math.pi * 0.78 + i * (math.pi * 1.56 / 6.0)
            objects.append(add_sphere("hair_clump", 0.085, (math.cos(angle) * 0.19, math.sin(angle) * 0.12 - 0.02, 0.18 + rng.uniform(-0.015, 0.04)), materials["hair"], segments=6, rings=3, scale=(1.2, 0.78, 0.74)))
    elif variant == 3:
        objects.append(add_cylinder("accent_hat_brim", 14, 0.34, 0.045, (0.0, 0.0, 0.06), materials["accent"], scale=(1.0, 0.76, 1.0)))
        objects.append(add_cone("accent_hat_crown", 8, 0.20, 0.11, 0.22, (0.0, 0.0, 0.18), materials["accent"], scale=(0.92, 0.78, 1.0)))
    else:
        objects.append(add_sphere("accent_cap", 0.25, (0.0, 0.0, 0.13), materials["accent"], segments=9, rings=4, scale=(1.04, 0.82, 0.42)))
        objects.append(add_cube("accent_cap_bill", (0.22, 0.18, 0.045), (0.0, -0.22, 0.08), materials["accent"]))
    return combine_asset(spec["id"], objects)


def build_npc_arm(spec, materials, rng):
    variant = int(spec["variant"])
    height = 0.58 + 0.04 * variant
    sleeve = add_cone("cloth_sleeve", 6, 0.062, 0.080, height * 0.74, (0.0, 0.0, height * 0.39), materials["cloth"], scale=(0.82, 0.82, 1.0))
    hand = add_sphere("skin_hand", 0.078, (0.0, 0.0, height * 0.08), materials["skin"], segments=6, rings=3, scale=(0.76, 0.76, 0.68))
    cuff = add_cylinder("accent_cuff", 6, 0.075, 0.035, (0.0, 0.0, height * 0.28), materials["accent"], scale=(0.84, 0.84, 1.0))
    return combine_asset(spec["id"], [sleeve, hand, cuff])


def hostile_material(variant, materials):
    if variant == "frost":
        return materials["frost"]
    return materials["hostile"]


def build_hostile_torso(spec, materials, rng):
    variant = str(spec["variant"])
    scale = 1.26 if variant == "rift" else (0.72 if variant == "skitter" else 1.0)
    mat = hostile_material(variant, materials)
    torso = add_cone("hostile_torso", 8, 0.42 * scale, 0.30 * scale, 1.04 * scale, (0.0, 0.0, 0.52 * scale), mat, scale=(0.92, 0.76, 1.0))
    chest = add_cube("hostile_accent_chest", (0.26 * scale, 0.08 * scale, 0.30 * scale), (0.0, -0.30 * scale, 0.66 * scale), materials["hostile_accent"])
    objects = [torso, chest]
    spike_count = 4 if variant != "skitter" else 6
    for i in range(spike_count):
        angle = (i / spike_count) * math.tau
        radius = 0.24 * scale
        objects.append(add_cone("hostile_accent_spike", 5, 0.035 * scale, 0.0, 0.20 * scale, (math.cos(angle) * radius, math.sin(angle) * radius, 0.96 * scale), materials["hostile_accent"], rotation=(math.radians(18), 0.0, angle)))
    return combine_asset(spec["id"], objects)


def build_hostile_head(spec, materials, rng):
    variant = str(spec["variant"])
    scale = 1.18 if variant == "rift" else (0.74 if variant == "skitter" else 1.0)
    mat = hostile_material(variant, materials)
    head = add_sphere("hostile_head", 0.30 * scale, (0.0, 0.0, 0.26 * scale), mat, segments=8, rings=4, scale=(0.92, 0.82, 0.82))
    jaw = add_cube("hostile_accent_jaw", (0.32 * scale, 0.12 * scale, 0.10 * scale), (0.0, -0.22 * scale, 0.08 * scale), materials["hostile_accent"])
    objects = [head, jaw]
    if variant in ["seer", "rift"]:
        objects.append(add_cone("hostile_accent_horn_l", 5, 0.055 * scale, 0.0, 0.28 * scale, (-0.16 * scale, -0.02 * scale, 0.52 * scale), materials["hostile_accent"], rotation=(math.radians(-18), math.radians(18), 0.0)))
        objects.append(add_cone("hostile_accent_horn_r", 5, 0.055 * scale, 0.0, 0.28 * scale, (0.16 * scale, -0.02 * scale, 0.52 * scale), materials["hostile_accent"], rotation=(math.radians(-18), math.radians(-18), 0.0)))
    return combine_asset(spec["id"], objects)


def build_hostile_eye(spec, materials, rng):
    variant = int(spec["variant"])
    radius = 0.048 + 0.008 * variant
    left = add_sphere("hostile_eye_l", radius, (-0.13, -0.02, radius), materials["hostile_eye"], segments=6, rings=3, scale=(1.0, 0.55, 0.72))
    right = add_sphere("hostile_eye_r", radius, (0.13, -0.02, radius), materials["hostile_eye"], segments=6, rings=3, scale=(1.0, 0.55, 0.72))
    brow = add_cube("hostile_accent_brow", (0.36, 0.04, 0.035), (0.0, 0.005, radius * 1.75), materials["hostile_accent"], rotation=(0.0, 0.0, math.radians(-4.0 * variant)))
    return combine_asset(spec["id"], [left, right, brow])


def build_hostile_core(spec, materials, rng):
    variant = int(spec["variant"])
    core = add_sphere("rift_core", 0.20 + 0.035 * variant, (0.0, 0.0, 0.22), materials["rift_core"], segments=8, rings=4, scale=(0.86, 0.72, 1.0))
    ring = add_cylinder("hostile_accent_core_ring", 9, 0.23 + 0.02 * variant, 0.028, (0.0, 0.0, 0.22), materials["hostile_accent"], rotation=(math.radians(90), 0.0, 0.0), scale=(1.0, 0.70, 1.0))
    return combine_asset(spec["id"], [core, ring])


def build_hostile_shard(spec, materials, rng):
    variant = int(spec["variant"])
    shard = add_cone("rift_core_shard", 5, 0.075 + variant * 0.010, 0.0, 0.42 + variant * 0.06, (0.0, 0.0, 0.22 + variant * 0.03), materials["rift_core"], scale=(0.75, 1.0, 1.0))
    socket = add_cylinder("hostile_accent_shard_socket", 5, 0.070, 0.055, (0.0, 0.0, 0.035), materials["hostile_accent"], scale=(0.90, 0.90, 1.0))
    return combine_asset(spec["id"], [shard, socket])


BUILDERS = {
    "npc_torso": build_npc_torso,
    "npc_head": build_npc_head,
    "npc_headwear": build_npc_headwear,
    "npc_arm": build_npc_arm,
    "hostile_torso": build_hostile_torso,
    "hostile_head": build_hostile_head,
    "hostile_eye": build_hostile_eye,
    "hostile_core": build_hostile_core,
    "hostile_shard": build_hostile_shard,
}


def mesh_bounds(obj):
    coords = [obj.matrix_world @ vertex.co for vertex in obj.data.vertices]
    min_v = Vector((min(v.x for v in coords), min(v.y for v in coords), min(v.z for v in coords)))
    max_v = Vector((max(v.x for v in coords), max(v.y for v in coords), max(v.z for v in coords)))
    return min_v, max_v


def snap(value):
    return round(float(value), 4)


def triangle_count(obj):
    return len(obj.data.polygons)


def material_slot_names(obj):
    return [slot.material.name for slot in obj.material_slots if slot.material]


def asset_metadata(spec, obj, relative_path):
    min_v, max_v = mesh_bounds(obj)
    size = max_v - min_v
    return {
        "id": spec["id"],
        "path": str(relative_path).replace("\\", "/"),
        "family": spec["family"],
        "variant": spec["variant"],
        "triangleCount": triangle_count(obj),
        "boundingBox": {
            "min": [snap(min_v.x), snap(min_v.y), snap(min_v.z)],
            "max": [snap(max_v.x), snap(max_v.y), snap(max_v.z)],
            "size": [snap(size.x), snap(size.y), snap(size.z)],
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
    bpy.ops.object.text_add(location=(obj.location.x - 0.78, obj.location.y - 0.78, 0.02), rotation=(math.radians(90), 0, 0))
    label = bpy.context.object
    label.name = f"label_{text}"
    label.data.body = text
    label.data.align_x = "LEFT"
    label.data.size = 0.17
    label.data.align_y = "CENTER"
    label.data.materials.append(bpy.data.materials["accent"])
    return label


def setup_gallery_camera(asset_count):
    rows = math.ceil(asset_count / GALLERY_COLUMNS)
    center_x = 0.0
    center_y = -((rows - 1) * GALLERY_SPACING_Y) * 0.5
    camera_data = bpy.data.cameras.new("CharacterGalleryCamera")
    camera = bpy.data.objects.new("CharacterGalleryCamera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (0.0, center_y - 6.8, 5.1)
    camera.rotation_euler = (math.radians(60.0), 0.0, 0.0)
    camera.data.lens = 34
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = max(5.5, rows * 2.12)
    bpy.context.scene.camera = camera
    light_data = bpy.data.lights.new("CharacterGallerySun", "SUN")
    light = bpy.data.objects.new("CharacterGallerySun", light_data)
    bpy.context.collection.objects.link(light)
    light.rotation_euler = (math.radians(48.0), math.radians(0.0), math.radians(-30.0))
    light.data.energy = 2.2


def render_contact_sheet(path):
    setup_gallery_camera(len(ASSET_SPECS))
    bpy.context.scene.render.filepath = str(path)
    bpy.context.scene.render.image_settings.file_format = "PNG"
    bpy.ops.render.render(write_still=True)


def family_counts():
    counts = {}
    for spec in ASSET_SPECS:
        counts[spec["family"]] = counts.get(spec["family"], 0) + 1
    return counts


def main():
    args = parse_args()
    output_root = Path(args.output_root).resolve()
    character_dir = output_root / "characters"
    manifest_path = Path(args.manifest).resolve()
    contact_sheet_path = Path(args.contact_sheet).resolve()
    character_dir.mkdir(parents=True, exist_ok=True)
    contact_sheet_path.parent.mkdir(parents=True, exist_ok=True)

    reset_scene()
    materials = make_materials()
    assets = []
    gallery_objects = []

    for index, spec in enumerate(ASSET_SPECS):
        rng = stable_rng(spec["id"])
        obj = BUILDERS[spec["builder"]](spec, materials, rng)
        glb_path = character_dir / f"{spec['id']}.glb"
        export_glb(obj, glb_path)
        relative_path = Path("assets/visual/generated/characters") / glb_path.name
        assets.append(asset_metadata(spec, obj, relative_path))
        duplicate = obj.copy()
        duplicate.data = obj.data.copy()
        bpy.context.collection.objects.link(duplicate)
        place_for_gallery(duplicate, index)
        gallery_objects.append(duplicate)
        add_gallery_label(spec["id"], duplicate)
        obj.hide_set(True)
        obj.hide_render = True

    render_contact_sheet(contact_sheet_path)

    manifest = {
        "schemaVersion": 1,
        "generator": GENERATOR_VERSION,
        "seed": SEED,
        "coordinateSystem": "Blender Z-up source; GLB import verified in Godot",
        "triangleLimit": TRIANGLE_LIMIT,
        "characterDirectory": "assets/visual/generated/characters",
        "contactSheet": "assets/visual/generated/characters/contact-sheet.png",
        "families": family_counts(),
        "materialVocabulary": sorted(MATERIAL_SPECS.keys()),
        "assets": assets,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {len(assets)} character assets")
    print(f"Manifest: {manifest_path}")
    print(f"Contact sheet: {contact_sheet_path}")


if __name__ == "__main__":
    main()

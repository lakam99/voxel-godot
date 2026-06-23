import argparse
import json
import math
import sys
from pathlib import Path

import bpy


GENERATOR_VERSION = "static-items-v2"

MATERIAL_SPECS = {
    "wood": (0.56, 0.32, 0.14, 1.0, 0.82, 0.0),
    "wood_dark": (0.24, 0.12, 0.05, 1.0, 0.88, 0.0),
    "stone": (0.50, 0.54, 0.51, 1.0, 0.90, 0.0),
    "stone_dark": (0.28, 0.31, 0.30, 1.0, 0.94, 0.0),
    "copper": (0.78, 0.42, 0.20, 1.0, 0.46, 0.18),
    "iron": (0.78, 0.84, 0.80, 1.0, 0.36, 0.24),
    "night": (0.22, 0.25, 0.72, 1.0, 0.36, 0.10),
    "ward": (0.36, 0.78, 0.92, 1.0, 0.34, 0.06),
    "rift": (0.78, 0.34, 0.96, 1.0, 0.28, 0.08),
    "gold": (0.92, 0.70, 0.32, 1.0, 0.48, 0.18),
    "glass": (0.54, 0.82, 0.92, 0.42, 0.14, 0.0),
    "flame": (1.00, 0.73, 0.42, 0.92, 0.30, 0.0),
    "ember": (1.00, 0.36, 0.12, 1.0, 0.34, 0.0),
    "string": (0.92, 0.82, 0.62, 1.0, 0.62, 0.0),
    "leather": (0.50, 0.30, 0.16, 1.0, 0.88, 0.0),
    "cloth_red": (0.68, 0.20, 0.18, 1.0, 0.82, 0.0),
    "cloth_teal": (0.26, 0.46, 0.42, 1.0, 0.78, 0.0),
    "cloth_light": (0.86, 0.77, 0.55, 1.0, 0.80, 0.0),
    "snow": (0.88, 0.92, 0.90, 1.0, 0.72, 0.0),
}

TOOL_SPECS = [
    ("woodenAxe", "axe", "wood"),
    ("woodenPickaxe", "pickaxe", "wood"),
    ("woodenShovel", "shovel", "wood"),
    ("woodenSword", "sword", "wood"),
    ("stoneAxe", "axe", "stone"),
    ("stonePickaxe", "pickaxe", "stone"),
    ("stoneShovel", "shovel", "stone"),
    ("stoneSword", "sword", "stone"),
    ("copperAxe", "axe", "copper"),
    ("copperPickaxe", "pickaxe", "copper"),
    ("copperShovel", "shovel", "copper"),
    ("copperSword", "sword", "copper"),
    ("ironAxe", "axe", "iron"),
    ("ironPickaxe", "pickaxe", "iron"),
    ("ironShovel", "shovel", "iron"),
    ("ironSword", "sword", "iron"),
    ("nightBlade", "sword", "night"),
]

RANGED_SPECS = [
    ("hunterBow", "bow", "wood"),
    ("ironCrossbow", "crossbow", "iron"),
    ("fishingRod", "rod", "wood"),
    ("arrows", "arrows", "stone"),
]

UTILITY_SPECS = [
    ("workbench", "workbench"),
    ("anvil", "anvil"),
    ("door", "door"),
    ("bed", "bed"),
    ("chest", "chest"),
    ("furnace", "furnace"),
    ("campfire", "campfire"),
    ("torch", "torch"),
    ("spikeTrap", "spikeTrap"),
    ("wardLantern", "wardLantern"),
    ("sanctuaryBeacon", "sanctuaryBeacon"),
    ("riftAnchor", "riftAnchor"),
    ("traderStall", "traderStall"),
]

EQUIPMENT_SPECS = [
    ("hideVest", "armor", "leather"),
    ("stoneArmor", "armor", "stone"),
    ("copperArmor", "armor", "copper"),
    ("ironArmor", "armor", "iron"),
    ("wardArmor", "armor", "ward"),
    ("trailPack", "pack", "leather"),
    ("expeditionPack", "pack", "cloth_teal"),
    ("trailCharm", "charm", "leather"),
    ("wardAmulet", "charm", "ward"),
    ("compass", "compass", "gold"),
    ("surveyLens", "lens", "copper"),
]


def parse_args():
    parser = argparse.ArgumentParser(description="Generate deterministic static item/utility GLBs.")
    parser.add_argument("--output-root", required=True, help="Project-relative or absolute assets/generated/static directory.")
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(args)


def reset_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.view_settings.view_transform = "Standard"
    bpy.context.scene.view_settings.look = "Medium High Contrast"
    bpy.context.scene.view_settings.exposure = 0.0
    bpy.context.scene.view_settings.gamma = 1.0


def make_materials():
    materials = {}
    for name, (r, g, b, a, roughness, metallic) in MATERIAL_SPECS.items():
        material = bpy.data.materials.new(name)
        material.diffuse_color = (r, g, b, a)
        material.use_nodes = True
        bsdf = material.node_tree.nodes.get("Principled BSDF")
        if bsdf:
            bsdf.inputs["Base Color"].default_value = (r, g, b, a)
            bsdf.inputs["Roughness"].default_value = roughness
            bsdf.inputs["Metallic"].default_value = metallic
            if a < 1.0:
                bsdf.inputs["Alpha"].default_value = a
                material.blend_method = "BLEND"
            if name in ["flame", "ember", "ward", "rift", "night"]:
                for input_name in ["Emission Color", "Emission"]:
                    if input_name in bsdf.inputs:
                        bsdf.inputs[input_name].default_value = (r, g, b, 1.0)
                if "Emission Strength" in bsdf.inputs:
                    bsdf.inputs["Emission Strength"].default_value = 0.65 if name != "flame" else 1.25
        materials[name] = material
    return materials


def assign_material(obj, material):
    obj.data.materials.append(material)
    for polygon in obj.data.polygons:
        polygon.material_index = 0


def create_empty(name, parent=None, location=(0.0, 0.0, 0.0)):
    obj = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(obj)
    obj.empty_display_type = "PLAIN_AXES"
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


def add_cylinder(name, radius, depth, location, material, parent=None, vertices=8, rotation=(0.0, 0.0, 0.0), top_radius=None):
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
    if top_radius is not None:
        for vertex in obj.data.vertices:
            if vertex.co.z > 0.0:
                vertex.co.x *= top_radius / radius
                vertex.co.y *= top_radius / radius
        obj.data.update()
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


def add_prism(name, outline, thickness, location, material, parent=None, rotation=(0.0, 0.0, 0.0)):
    half = thickness * 0.5
    vertices = [(x, -half, z) for x, z in outline] + [(x, half, z) for x, z in outline]
    count = len(outline)
    faces = [tuple(range(count - 1, -1, -1)), tuple(range(count, count * 2))]
    for index in range(count):
        next_index = (index + 1) % count
        faces.append((index, next_index, next_index + count, index + count))
    mesh = bpy.data.meshes.new("%sMesh" % name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.parent = parent
    obj.location = location
    obj.rotation_euler = rotation
    assign_material(obj, material)
    return obj


def material_for_tier(materials, tier):
    if tier == "wood":
        return materials["wood"]
    if tier == "stone":
        return materials["stone"]
    if tier == "copper":
        return materials["copper"]
    if tier == "iron":
        return materials["iron"]
    if tier == "night":
        return materials["night"]
    if tier == "ward":
        return materials["ward"]
    if tier == "rift":
        return materials["rift"]
    if tier == "leather":
        return materials["leather"]
    if tier == "cloth_teal":
        return materials["cloth_teal"]
    return materials["wood"]


def build_tool(root, materials, kind, tier):
    head = material_for_tier(materials, tier)
    shaft = materials["wood_dark"] if tier != "wood" else materials["wood"]
    if kind == "sword":
        add_cylinder("Grip", 0.040, 0.42, (0.0, 0.0, -0.42), shaft, root, 8)
        add_ico("Pommel", 0.055, (0.0, 0.0, -0.62), (1.0, 1.0, 0.75), head, root, 1)
        add_cube("Guard", (0.46, 0.060, 0.060), (0.0, 0.0, -0.22), head, root)
        add_cube("BladeTang", (0.070, 0.055, 0.26), (0.0, 0.0, -0.12), head, root)
        add_prism(
            "Blade",
            [(-0.070, -0.22), (0.070, -0.22), (0.076, 0.42), (0.0, 0.80), (-0.076, 0.42)],
            0.052,
            (0.0, 0.0, 0.0),
            head,
            root,
        )
        add_prism(
            "BladeRidge",
            [(-0.012, -0.12), (0.012, -0.12), (0.016, 0.40), (0.0, 0.68), (-0.016, 0.40)],
            0.060,
            (0.0, -0.004, 0.0),
            materials["ward"] if tier == "night" else materials["stone_dark"],
            root,
        )
        if tier == "night":
            add_cube("NightGlow", (0.030, 0.030, 0.58), (0.0, 0.028, 0.22), materials["ward"], root)
        return
    add_cylinder("Handle", 0.040, 1.02, (0.0, 0.0, -0.08), shaft, root, 9)
    add_cube("GripWrapLow", (0.090, 0.065, 0.070), (0.0, 0.0, -0.52), materials["leather"], root)
    add_cube("GripWrapHigh", (0.090, 0.065, 0.070), (0.0, 0.0, 0.04), materials["leather"], root)
    add_cube("ToolHeadSocket", (0.12, 0.12, 0.24), (0.0, 0.0, 0.30), shaft, root)
    if kind == "pickaxe":
        add_prism(
            "PickaxeHead",
            [(-0.56, 0.02), (-0.34, 0.12), (-0.08, 0.09), (0.0, 0.03), (0.08, 0.09), (0.34, 0.12), (0.56, 0.02), (0.34, -0.06), (0.08, -0.05), (0.0, -0.12), (-0.08, -0.05), (-0.34, -0.06)],
            0.095,
            (0.0, 0.0, 0.39),
            head,
            root,
        )
        add_cube("PickaxeCollar", (0.22, 0.14, 0.24), (0.0, 0.0, 0.35), head, root)
        add_cube("PickaxeHeadBridge", (0.50, 0.080, 0.10), (0.0, 0.0, 0.39), head, root)
    elif kind == "shovel":
        add_cube("ShovelSocket", (0.14, 0.10, 0.28), (0.0, 0.0, 0.27), head, root)
        add_prism(
            "ShovelBlade",
            [(-0.17, -0.05), (-0.24, 0.16), (-0.17, 0.34), (0.0, 0.53), (0.17, 0.34), (0.24, 0.16), (0.17, -0.05)],
            0.072,
            (0.0, 0.0, 0.28),
            head,
            root,
        )
        add_prism(
            "ShovelRidge",
            [(-0.018, 0.04), (0.018, 0.04), (0.016, 0.32), (0.0, 0.44), (-0.016, 0.32)],
            0.082,
            (0.0, -0.002, 0.30),
            materials["stone_dark"],
            root,
        )
    else:
        add_cube("AxeEye", (0.20, 0.13, 0.26), (-0.02, 0.0, 0.34), head, root)
        add_cube("AxeHeadBridge", (0.48, 0.090, 0.16), (0.05, 0.0, 0.35), head, root)
        add_prism(
            "AxeBlade",
            [(-0.11, -0.21), (0.24, -0.22), (0.44, -0.06), (0.41, 0.18), (0.18, 0.36), (-0.13, 0.28), (-0.02, 0.04)],
            0.090,
            (0.08, 0.0, 0.33),
            head,
            root,
        )
        add_prism(
            "AxePoll",
            [(-0.26, -0.09), (-0.08, -0.10), (-0.04, 0.12), (-0.24, 0.14)],
            0.082,
            (-0.08, 0.0, 0.34),
            head,
            root,
        )


def build_ranged(root, materials, kind, tier):
    mat = material_for_tier(materials, tier)
    if kind == "crossbow":
        add_cube("CrossbowStock", (0.14, 0.10, 0.80), (0.0, 0.0, -0.04), materials["wood_dark"], root)
        add_cube("CrossbowBow", (0.82, 0.070, 0.065), (0.0, 0.0, 0.28), mat, root)
        add_cylinder("CrossbowString", 0.010, 0.78, (0.0, -0.075, 0.28), materials["string"], root, 5, (0.0, math.radians(90.0), 0.0))
        add_cube("CrossbowTrigger", (0.10, 0.08, 0.06), (0.0, -0.02, -0.35), materials["gold"], root)
    elif kind == "bow":
        add_cylinder("UpperBowLimb", 0.028, 0.54, (0.0, 0.0, 0.24), mat, root, 8, (math.radians(20.0), 0.0, 0.0))
        add_cylinder("LowerBowLimb", 0.028, 0.54, (0.0, 0.0, -0.24), mat, root, 8, (math.radians(-20.0), 0.0, 0.0))
        add_cylinder("BowString", 0.008, 1.04, (0.0, -0.12, 0.0), materials["string"], root, 5)
        add_cube("BowGrip", (0.075, 0.075, 0.20), (0.0, 0.0, 0.0), materials["wood_dark"], root)
    elif kind == "rod":
        add_cylinder("Rod", 0.022, 1.06, (0.0, 0.0, 0.0), mat, root, 8, (math.radians(-24.0), 0.0, 0.0))
        add_cylinder("RodLine", 0.005, 0.68, (-0.15, -0.04, 0.31), materials["string"], root, 4)
        add_ico("Float", 0.05, (-0.15, -0.04, -0.08), (1.0, 0.75, 1.0), materials["ward"], root, 1)
    else:
        for index, x in enumerate([-0.08, 0.0, 0.08]):
            add_cylinder("ArrowShaft%d" % index, 0.010, 0.66, (x, 0.0, 0.0), materials["string"], root, 5, (0.0, math.radians(90.0), 0.0))
            add_cone("ArrowTip%d" % index, 4, 0.050, 0.006, 0.11, (x + 0.38, 0.0, 0.0), materials["stone"], root, (0.0, math.radians(90.0), 0.0))
            add_cube("ArrowFletch%d" % index, (0.05, 0.012, 0.09), (x - 0.34, 0.0, 0.0), materials["cloth_red"], root)


def build_utility(root, materials, kind):
    if kind == "workbench":
        add_cube("BenchTop", (1.04, 0.74, 0.14), (0.0, 0.0, 0.22), materials["wood"], root)
        add_cube("BenchTopGrainA", (0.94, 0.028, 0.018), (0.0, -0.19, 0.30), materials["wood_dark"], root)
        add_cube("BenchTopGrainB", (0.94, 0.028, 0.018), (0.0, 0.18, 0.30), materials["wood_dark"], root)
        for x in [-0.42, 0.42]:
            for y in [-0.28, 0.28]:
                add_cube("BenchLeg", (0.10, 0.10, 0.58), (x, y, -0.12), materials["wood_dark"], root)
        add_cube("BenchToolA", (0.35, 0.045, 0.045), (-0.25, -0.12, 0.36), materials["iron"], root, (0.0, 0.0, math.radians(8.0)))
        add_cube("BenchToolB", (0.06, 0.25, 0.04), (0.30, 0.12, 0.36), materials["wood_dark"], root, (0.0, 0.0, math.radians(-16.0)))
    elif kind == "anvil":
        add_cube("AnvilBase", (0.54, 0.38, 0.14), (0.0, 0.0, -0.40), materials["stone_dark"], root)
        add_cube("AnvilWaist", (0.30, 0.28, 0.30), (0.0, 0.0, -0.18), materials["iron"], root)
        add_cube("AnvilTop", (0.82, 0.34, 0.22), (0.0, 0.0, 0.08), materials["iron"], root)
        add_cone("AnvilHorn", 8, 0.15, 0.035, 0.36, (0.58, 0.0, 0.08), materials["iron"], root, (0.0, math.radians(90.0), 0.0))
        add_cube("AnvilHeel", (0.22, 0.30, 0.18), (-0.52, 0.0, 0.05), materials["iron"], root)
    elif kind == "door":
        add_cube("DoorPanel", (0.86, 0.11, 1.18), (0.0, 0.0, 0.05), materials["wood"], root)
        for x in [-0.22, 0.22]:
            add_cube("DoorPlankLine", (0.028, 0.12, 1.08), (x, -0.01, 0.05), materials["wood_dark"], root)
        add_cube("DoorTopRail", (0.78, 0.13, 0.08), (0.0, -0.02, 0.42), materials["wood_dark"], root)
        add_cube("DoorBottomRail", (0.78, 0.13, 0.08), (0.0, -0.02, -0.30), materials["wood_dark"], root)
        add_ico("DoorKnob", 0.055, (-0.28, -0.075, 0.03), (1.0, 1.0, 1.0), materials["gold"], root, 1)
    elif kind == "bed":
        add_cube("BedFrame", (1.12, 0.76, 0.16), (0.0, 0.0, -0.34), materials["wood_dark"], root)
        add_cube("Mattress", (1.04, 0.68, 0.16), (0.04, 0.0, -0.20), materials["snow"], root)
        add_cube("Blanket", (0.72, 0.70, 0.18), (0.20, 0.0, -0.08), materials["cloth_red"], root)
        add_cube("Pillow", (0.26, 0.58, 0.14), (-0.42, 0.0, -0.04), materials["cloth_light"], root)
    elif kind == "chest":
        add_cube("ChestBase", (1.02, 0.72, 0.45), (0.0, 0.0, -0.20), materials["wood"], root)
        add_cube("ChestLid", (1.08, 0.78, 0.18), (0.0, 0.0, 0.16), materials["wood_dark"], root)
        add_cube("ChestBandLeft", (0.07, 0.80, 0.66), (-0.38, 0.0, -0.02), materials["iron"], root)
        add_cube("ChestBandRight", (0.07, 0.80, 0.66), (0.38, 0.0, -0.02), materials["iron"], root)
        add_cube("ChestLatch", (0.18, 0.055, 0.15), (0.0, -0.42, -0.04), materials["gold"], root)
    elif kind == "furnace":
        add_cube("FurnaceBody", (0.84, 0.78, 0.84), (0.0, 0.0, -0.04), materials["stone"], root)
        add_cube("FurnaceTop", (0.90, 0.84, 0.13), (0.0, 0.0, 0.44), materials["stone_dark"], root)
        add_cube("FurnaceMouth", (0.48, 0.055, 0.32), (0.0, -0.43, -0.05), materials["stone_dark"], root)
        add_cube("FurnaceGlow", (0.32, 0.060, 0.08), (0.0, -0.47, -0.12), materials["ember"], root)
    elif kind == "campfire":
        for angle in [math.radians(35.0), math.radians(-35.0)]:
            add_cylinder("CampfireLog", 0.060, 0.78, (0.0, 0.0, -0.38), materials["wood"], root, 8, (0.0, math.radians(90.0), angle))
        for x in [-0.30, 0.30]:
            for y in [-0.24, 0.24]:
                add_ico("CampfireStone", 0.11, (x, y, -0.44), (1.0, 0.72, 0.85), materials["stone"], root, 1)
        add_cone("CampfireFlameA", 6, 0.16, 0.035, 0.55, (0.0, 0.0, -0.09), materials["flame"], root)
        add_cone("CampfireFlameB", 5, 0.11, 0.018, 0.38, (0.0, 0.0, 0.00), materials["ember"], root, (0.0, 0.0, math.radians(30.0)))
    elif kind == "torch":
        add_cylinder("TorchHandle", 0.035, 0.92, (0.0, 0.0, -0.10), materials["wood_dark"], root, 8, (math.radians(6.0), 0.0, 0.0))
        add_cube("TorchWrap", (0.16, 0.16, 0.14), (0.0, 0.0, 0.36), materials["wood"], root)
        add_cone("TorchFlame", 6, 0.12, 0.018, 0.30, (0.0, 0.0, 0.58), materials["flame"], root)
    elif kind == "spikeTrap":
        add_cube("TrapBase", (0.82, 0.82, 0.08), (0.0, 0.0, -0.45), materials["wood_dark"], root)
        for x in [-0.24, 0.0, 0.24]:
            for y in [-0.24, 0.0, 0.24]:
                add_cone("TrapSpike", 4, 0.065, 0.018, 0.38, (x, y, -0.22), materials["iron"], root)
    elif kind in ["wardLantern", "sanctuaryBeacon", "riftAnchor"]:
        core = materials["rift"] if kind == "riftAnchor" else materials["ward"]
        base = materials["stone_dark"] if kind != "wardLantern" else materials["gold"]
        add_cube("LightBase", (0.44, 0.44, 0.10), (0.0, 0.0, -0.48), base, root)
        add_cylinder("LightPost", 0.045, 0.68, (0.0, 0.0, -0.14), materials["iron"], root, 8)
        if kind == "wardLantern":
            add_cube("LanternGlass", (0.34, 0.34, 0.34), (0.0, 0.0, 0.26), materials["glass"], root)
            add_ico("LanternCore", 0.18, (0.0, 0.0, 0.26), (0.78, 1.0, 0.78), core, root, 1)
            add_cube("LanternCap", (0.48, 0.48, 0.06), (0.0, 0.0, 0.50), materials["gold"], root)
        else:
            add_ico("BeaconCrystal", 0.26, (0.0, 0.0, 0.28), (0.82, 1.35, 0.82), core, root, 1)
            add_cube("BeaconRing", (0.58, 0.08, 0.08), (0.0, 0.0, 0.02), base, root, (0.0, 0.0, math.radians(45.0)))
    elif kind == "traderStall":
        add_cube("StallCounter", (1.12, 0.62, 0.28), (0.0, 0.0, -0.32), materials["wood"], root)
        for x in [-0.46, 0.46]:
            for y in [-0.28, 0.28]:
                add_cube("StallPost", (0.07, 0.07, 0.92), (x, y, 0.05), materials["wood_dark"], root)
        add_cube("StallCanopy", (1.26, 0.90, 0.12), (0.0, 0.0, 0.58), materials["cloth_red"], root)
        for i in range(-2, 3):
            mat = materials["cloth_light"] if i % 2 == 0 else materials["cloth_red"]
            add_cube("StallValance", (0.18, 0.08, 0.15), (float(i) * 0.20, -0.48, 0.45), mat, root)


def build_equipment(root, materials, kind, tier):
    mat = material_for_tier(materials, tier)
    if kind == "armor":
        add_cube("ArmorChest", (0.48, 0.22, 0.58), (0.0, 0.0, 0.0), mat, root)
        add_cube("ArmorLeftShoulder", (0.18, 0.24, 0.16), (-0.32, 0.0, 0.14), mat, root)
        add_cube("ArmorRightShoulder", (0.18, 0.24, 0.16), (0.32, 0.0, 0.14), mat, root)
        add_cube("ArmorStrap", (0.36, 0.035, 0.06), (0.0, -0.13, 0.0), materials["wood_dark"], root)
    elif kind == "pack":
        add_cube("PackBody", (0.42, 0.28, 0.54), (0.0, 0.0, 0.0), mat, root)
        add_cube("PackFlap", (0.36, 0.30, 0.14), (0.0, -0.02, 0.24), materials["wood_dark"], root)
        add_cube("PackRoll", (0.50, 0.18, 0.14), (0.0, 0.0, -0.36), materials["cloth_light"], root)
        for x in [-0.16, 0.16]:
            add_cube("PackStrap", (0.045, 0.035, 0.58), (x, -0.16, 0.0), materials["leather"], root)
    elif kind == "compass":
        add_cylinder("CompassCase", 0.26, 0.055, (0.0, 0.0, 0.0), materials["gold"], root, 18, (math.radians(90.0), 0.0, 0.0))
        add_cube("CompassNeedle", (0.035, 0.22, 0.018), (0.0, -0.035, 0.0), materials["ward"], root, (0.0, 0.0, math.radians(28.0)))
        add_cylinder("CompassGlass", 0.22, 0.018, (0.0, -0.040, 0.0), materials["glass"], root, 18, (math.radians(90.0), 0.0, 0.0))
    elif kind == "lens":
        add_cylinder("LensGlass", 0.24, 0.035, (0.0, 0.0, 0.0), materials["glass"], root, 18, (math.radians(90.0), 0.0, 0.0))
        add_cylinder("LensRim", 0.27, 0.035, (0.0, 0.0, 0.0), mat, root, 18, (math.radians(90.0), 0.0, 0.0))
        add_cylinder("LensHandle", 0.035, 0.42, (0.18, 0.0, -0.28), mat, root, 8, (0.0, math.radians(28.0), 0.0))
    else:
        add_ico("CharmCore", 0.20, (0.0, 0.0, 0.0), (0.80, 1.0, 0.42), mat, root, 1)
        add_cylinder("CharmCord", 0.010, 0.68, (0.0, 0.0, 0.18), materials["string"], root, 5, (0.0, math.radians(90.0), 0.0))
        add_cube("CharmBand", (0.24, 0.035, 0.035), (0.0, -0.02, 0.0), materials["gold"], root)


def export_glb(filepath):
    filepath.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    kwargs = {
        "filepath": str(filepath),
        "export_format": "GLB",
        "export_animations": False,
    }
    properties = bpy.ops.export_scene.gltf.get_rna_type().properties.keys()
    if "export_selected" in properties:
        kwargs["export_selected"] = True
    bpy.ops.export_scene.gltf(**kwargs)


def mesh_count():
    return len([obj for obj in bpy.context.scene.objects if obj.type == "MESH"])


def generate_asset(output_root, asset_id, family, builder):
    reset_scene()
    materials = make_materials()
    root = create_empty("%sRoot" % asset_id)
    builder(root, materials)
    count = mesh_count()
    export_glb(output_root / ("%s.glb" % asset_id))
    return {
        "id": asset_id,
        "family": family,
        "path": "assets/generated/static/%s.glb" % asset_id,
        "minMeshes": max(1, min(count, 4)),
    }


def main():
    args = parse_args()
    output_root = Path(args.output_root).resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    assets = []
    for asset_id, kind, tier in TOOL_SPECS:
        assets.append(generate_asset(output_root, asset_id, "tool", lambda root, materials, k=kind, t=tier: build_tool(root, materials, k, t)))
    for asset_id, kind, tier in RANGED_SPECS:
        assets.append(generate_asset(output_root, asset_id, "tool", lambda root, materials, k=kind, t=tier: build_ranged(root, materials, k, t)))
    for asset_id, kind in UTILITY_SPECS:
        assets.append(generate_asset(output_root, asset_id, "utility", lambda root, materials, k=kind: build_utility(root, materials, k)))
    for asset_id, kind, tier in EQUIPMENT_SPECS:
        assets.append(generate_asset(output_root, asset_id, "equipment", lambda root, materials, k=kind, t=tier: build_equipment(root, materials, k, t)))
    manifest = {
        "generator": GENERATOR_VERSION,
        "assets": assets,
    }
    (output_root / "static-item-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("Generated %d static item assets in %s" % (len(assets), output_root))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Static item asset generation failed: %s" % error, file=sys.stderr)
        raise SystemExit(1)

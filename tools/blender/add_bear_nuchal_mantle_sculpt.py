import argparse
import json
import math
import sys
from pathlib import Path

import bpy


SECTIONS = (
    (-1.220, 0.42, 1.52, 0.30),
    (-1.120, 0.58, 1.53, 0.36),
    (-1.030, 0.82, 1.55, 0.45),
    (-0.950, 0.90, 1.57, 0.46),
    (-0.865, 0.95, 1.58, 0.47),
    (-0.775, 0.98, 1.60, 0.47),
    (-0.655, 1.02, 1.61, 0.49),
    (-0.525, 1.04, 1.62, 0.50),
    (-0.395, 1.04, 1.62, 0.50),
    (-0.265, 1.02, 1.61, 0.49),
    (-0.145, 0.98, 1.59, 0.47),
)
RADIAL_COUNT = 64


def parse_args():
    parser = argparse.ArgumentParser(description="Add a buried sculpted nuchal mantle over the frozen brown-bear body.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def main():
    args = parse_args()
    old = bpy.data.objects.get("BrownBear_NuchalMantleSculpt")
    if old is not None:
        bpy.data.objects.remove(old, do_unlink=True)
    vertices = []
    faces = []
    for section_index, (center_y, radius_x, center_z, radius_z) in enumerate(SECTIONS):
        section_parameter = section_index / (len(SECTIONS) - 1)
        for radial in range(RADIAL_COUNT):
            angle = math.tau * radial / RADIAL_COUNT
            cosine = math.cos(angle)
            sine = math.sin(angle)
            dorsal = max(0.0, sine)
            ventral = max(0.0, -sine)
            lateral_mane = 1.0 + 0.08 * (1.0 - abs(sine)) * math.sin(math.pi * section_parameter)
            x = radius_x * cosine * lateral_mane
            z_scale = 1.0 + 0.10 * dorsal - 0.22 * ventral
            z = center_z + radius_z * sine * z_scale
            y = center_y + 0.025 * dorsal * math.sin(math.pi * section_parameter)
            vertices.append((x, y, z))
    for section_index in range(len(SECTIONS) - 1):
        for radial in range(RADIAL_COUNT):
            following = (radial + 1) % RADIAL_COUNT
            first = section_index * RADIAL_COUNT + radial
            second = section_index * RADIAL_COUNT + following
            third = (section_index + 1) * RADIAL_COUNT + following
            fourth = (section_index + 1) * RADIAL_COUNT + radial
            faces.append((first, second, third, fourth))
    mesh = bpy.data.meshes.new("BrownBearNuchalMantleSculptMesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    mantle = bpy.data.objects.new("BrownBear_NuchalMantleSculpt", mesh)
    bpy.context.scene.collection.objects.link(mantle)
    for polygon in mesh.polygons:
        polygon.use_smooth = True
    material = bpy.data.materials.get("BearClay") or bpy.data.materials.get("WholeBearClay")
    if material is not None:
        mesh.materials.append(material)
    subdivision = mantle.modifiers.new("NuchalSurfaceRefinement", "SUBSURF")
    subdivision.levels = 2
    subdivision.render_levels = 2
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_nuchal_mantle_critic_gate",
        "source": "iteration-733-balanced-dorsal-sacral-profile",
        "method": "nine-section asymmetric nuchal mantle with buried cranial and caudal ends",
        "sections": [list(section) for section in SECTIONS],
        "radialCount": RADIAL_COUNT,
        "clawsRetained": len([obj for obj in bpy.context.scene.objects if "Claw" in obj.name]),
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_NUCHAL_MANTLE", json.dumps(report))


if __name__ == "__main__":
    main()

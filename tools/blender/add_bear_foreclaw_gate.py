import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


TIP_CENTERS = (
    (1.0900, -0.7230, 0.0835),
    (1.1345, -0.7346, 0.0843),
    (1.1906, -0.7491, 0.0855),
    (1.2467, -0.7346, 0.0848),
    (1.2955, -0.7230, 0.0837),
)
FAN_DEGREES = (-7.0, -3.0, -0.5, 3.5, 7.0)
LENGTHS = (0.126, 0.142, 0.150, 0.140, 0.118)


def parse_args():
    parser = argparse.ArgumentParser(description="Add anatomically swept claws to the frozen brown-bear forepaw authority.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def centerline(root, fan_degrees, length, parameter):
    angle = math.radians(fan_degrees)
    forward = Vector((math.sin(angle), -math.cos(angle), 0.0))
    buried_root = Vector(root) - forward * (length * 0.28)
    advance = length * parameter
    delayed = max(0.0, min(1.0, (parameter - 0.62) / 0.38))
    delayed = delayed * delayed * (3.0 - 2.0 * delayed)
    drop = length * (0.07 * parameter + 0.13 * delayed)
    return buried_root + forward * advance + Vector((0.0, 0.0, -drop))


def section_scale(parameter):
    if parameter <= 0.25:
        return 1.20 - 0.80 * parameter
    if parameter <= 0.75:
        return 1.00 - 0.10 * ((parameter - 0.25) / 0.50)
    return 0.90 - 0.35 * ((parameter - 0.75) / 0.25) ** 1.20


def create_claw(index, root, fan_degrees, length):
    ring_count = 9
    radial_count = 10
    vertices = []
    faces = []
    centers = [centerline(root, fan_degrees, length, ring / (ring_count - 1)) for ring in range(ring_count)]
    for ring, center in enumerate(centers):
        parameter = ring / (ring_count - 1)
        if ring == 0:
            tangent = centers[1] - centers[0]
        elif ring == ring_count - 1:
            tangent = centers[-1] - centers[-2]
        else:
            tangent = centers[ring + 1] - centers[ring - 1]
        tangent.normalize()
        width_axis = Vector((math.cos(math.radians(fan_degrees)), math.sin(math.radians(fan_degrees)), 0.0)).normalized()
        depth_axis = tangent.cross(width_axis).normalized()
        taper = section_scale(parameter)
        half_depth = 0.0185 * taper
        compression = 0.68 - 0.10 * parameter
        half_width = half_depth * compression
        for radial in range(radial_count):
            angle = math.tau * radial / radial_count
            sine = math.sin(angle)
            ventral_scale = 1.0 if sine >= 0.0 else 0.64
            dorsal_ridge = 0.08 * half_depth * max(0.0, sine) * math.cos(angle)
            profile = width_axis * (half_width * math.cos(angle) + dorsal_ridge) + depth_axis * (half_depth * sine * ventral_scale)
            vertices.append(tuple(center + profile))
    for ring in range(ring_count - 1):
        for radial in range(radial_count):
            following = (radial + 1) % radial_count
            first = ring * radial_count + radial
            second = ring * radial_count + following
            third = (ring + 1) * radial_count + following
            fourth = (ring + 1) * radial_count + radial
            faces.append((first, second, third, fourth))
    faces.append(tuple(reversed(range(radial_count))))
    last = (ring_count - 1) * radial_count
    faces.append(tuple(last + radial for radial in range(radial_count)))
    mesh = bpy.data.meshes.new(f"BrownBear_ForeClaw_{index + 1:02d}_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    claw = bpy.data.objects.new(f"BrownBear_ForeClaw_{index + 1:02d}", mesh)
    bpy.context.scene.collection.objects.link(claw)
    for polygon in mesh.polygons:
        polygon.use_smooth = True
    bevel = claw.modifiers.new("ClawSurfaceRefinement", "SUBSURF")
    bevel.levels = 1
    bevel.render_levels = 2
    return claw, centers[-1]


def main():
    args = parse_args()
    claws = []
    tips = []
    for index, (root, fan, length) in enumerate(zip(TIP_CENTERS, FAN_DEGREES, LENGTHS)):
        claw, tip = create_claw(index, root, fan, length)
        claws.append(claw)
        tips.append(list(tip))
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_foreclaw_critic_gate",
        "clawCount": len(claws),
        "construction": "nine-ring asymmetric ungual sweeps with 28-percent buried roots, delayed curvature, laterally compressed sections, and broad finite worn caps",
        "lengths": list(LENGTHS),
        "fanDegrees": list(FAN_DEGREES),
        "rootBurialFraction": 0.28,
        "totalVentralDropFraction": 0.20,
        "rootWidthToDepth": 0.68,
        "distalWidthToDepth": 0.58,
        "tipClosure": "finite ten-vertex worn profile",
        "tipCoordinates": tips,
        "softTissueAuthority": "iteration-663 unchanged",
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_FORECLAW_GATE", json.dumps(report))


if __name__ == "__main__":
    main()

import argparse
import json
import math
import sys
from pathlib import Path

import bpy
import bmesh
from mathutils import Vector


RING_COUNT = 10
RADIAL_COUNT = 10
REBUILT_RADIAL_COUNT = 16


def parse_args():
    parser = argparse.ArgumentParser(description="Restore readable brown-bear claw silhouettes without unseating their roots.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def smoothstep(edge0, edge1, value):
    parameter = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return parameter * parameter * (3.0 - 2.0 * parameter)


def ring_center(vertices, ring):
    start = ring * RADIAL_COUNT
    return sum((vertices[index].co for index in range(start, start + RADIAL_COUNT)), Vector()) / RADIAL_COUNT


def refine_claw(obj, family, digit_index):
    source_vertices = obj.data.vertices
    if len(source_vertices) != RING_COUNT * RADIAL_COUNT:
        raise RuntimeError(f"Unexpected claw topology for {obj.name}: {len(source_vertices)} vertices")
    centers = [ring_center(source_vertices, ring) for ring in range(RING_COUNT)]
    axis = centers[-1] - centers[0]
    horizontal = Vector((axis.x, axis.y, 0.0))
    horizontal_length = horizontal.length
    horizontal.normalize()
    width_axis = Vector((-horizontal.y, horizontal.x, 0.0)).normalized()
    depth_axis = horizontal.cross(width_axis).normalized()
    hierarchy = (0.84, 0.96, 1.0, 0.94, 0.80)[digit_index]
    extension = (0.026 if family == "fore" else 0.012) * hierarchy
    additional_burial = (0.026 if family == "fore" else 0.010) * hierarchy
    root = centers[0] - horizontal * additional_burial
    total_drop = abs(axis.z) + (0.006 if family == "fore" else 0.003)
    ring_count = 18
    vertices = []
    faces = []
    rebuilt_centers = []
    for ring in range(ring_count):
        parameter = ring / (ring_count - 1)
        emergence = smoothstep(0.20, 1.0, parameter)
        delayed = smoothstep(0.60, 1.0, parameter)
        drop = total_drop * (0.22 * parameter + 0.78 * delayed)
        center = root + horizontal * (horizontal_length * parameter + extension * emergence)
        center.z -= drop
        rebuilt_centers.append(center)
        root_weight = 1.0 - smoothstep(0.0, 0.38, parameter)
        if parameter < 0.28:
            taper = 1.38 - 1.10 * parameter
        else:
            taper = 1.07 - 0.67 * ((parameter - 0.28) / 0.72) ** 1.35
        half_depth = horizontal_length * 0.25 * taper * (1.0 + 0.40 * root_weight)
        half_width = half_depth * (0.68 - 0.10 * parameter) * (1.0 + 0.22 * root_weight)
        for radial in range(REBUILT_RADIAL_COUNT):
            angle = math.tau * radial / REBUILT_RADIAL_COUNT
            sine = math.sin(angle)
            ventral_scale = 0.52 if sine < 0.0 else 1.0
            profile = width_axis * (half_width * math.cos(angle))
            profile += depth_axis * (half_depth * sine * ventral_scale)
            if ring == ring_count - 1:
                profile *= 0.78
                profile += horizontal * (half_width * 0.18 * math.cos(angle))
            vertices.append(tuple(center + profile))
    for ring in range(ring_count - 1):
        for radial in range(REBUILT_RADIAL_COUNT):
            following = (radial + 1) % REBUILT_RADIAL_COUNT
            first = ring * REBUILT_RADIAL_COUNT + radial
            second = ring * REBUILT_RADIAL_COUNT + following
            third = (ring + 1) * REBUILT_RADIAL_COUNT + following
            fourth = (ring + 1) * REBUILT_RADIAL_COUNT + radial
            faces.append((first, second, third, fourth))
    faces.append(tuple(reversed(range(REBUILT_RADIAL_COUNT))))
    last = (ring_count - 1) * REBUILT_RADIAL_COUNT
    faces.append(tuple(last + radial for radial in range(REBUILT_RADIAL_COUNT)))
    rebuilt = bpy.data.meshes.new(f"{obj.name}RebuiltMesh")
    rebuilt.from_pydata(vertices, [], faces)
    rebuilt.update()
    old_mesh = obj.data
    obj.data = rebuilt
    bpy.data.meshes.remove(old_mesh)
    for polygon in rebuilt.polygons:
        polygon.use_smooth = True
    rebuilt.polygons[-1].use_smooth = False
    obj.modifiers.clear()
    bevel = obj.modifiers.new("WornTipPerimeter", "BEVEL")
    bevel.width = horizontal_length * 0.012
    bevel.segments = 2
    bevel.limit_method = "ANGLE"
    bevel.angle_limit = math.radians(28.0)
    return (rebuilt_centers[-1] - centers[-1]).length


def gaussian(value, center, scale):
    return pow(2.718281828459045, -0.5 * ((value - center) / scale) ** 2)


def sculpt_forepaw_digits(bear):
    bm = bmesh.new()
    bm.from_mesh(bear.data)
    moved = 0
    maximum_move = 0.0
    affected_vertices = []
    for vertex in bm.verts:
        point = vertex.co.copy()
        if point.y > -0.40 or point.y < -0.76 or point.z < 0.07 or point.z > 0.28:
            continue
        side = -1.0 if point.x < 0.0 else 1.0
        local_x = point.x - side * 0.68
        if abs(local_x) > 0.31:
            continue
        distal = gaussian(point.y, -0.575, 0.145)
        dorsal = smoothstep(0.105, 0.19, point.z) * (1.0 - smoothstep(0.21, 0.27, point.z))
        valley = 0.0
        for boundary in (-0.15, -0.05, 0.05, 0.15):
            valley += gaussian(local_x, boundary, 0.020)
        toe = 0.0
        for center in (-0.20, -0.10, 0.0, 0.10, 0.20):
            toe += gaussian(local_x, center, 0.034)
        target = point.copy()
        valley_weight = min(1.0, valley) * distal * dorsal
        target.z -= 0.028 * valley_weight
        nearest_boundary = min((-0.15, -0.05, 0.05, 0.15), key=lambda value: abs(local_x - value))
        boundary_delta = local_x - nearest_boundary
        if abs(boundary_delta) < 0.045:
            target.x += 0.011 * (1.0 if boundary_delta > 0.0 else -1.0) * valley_weight
        toe_weight = min(1.0, toe) * distal * dorsal
        target.z += 0.016 * toe_weight
        target.y -= 0.026 * toe_weight
        nearest_toe = min((-0.20, -0.10, 0.0, 0.10, 0.20), key=lambda value: abs(local_x - value))
        target.x += (local_x - nearest_toe) * 0.09 * toe_weight
        nail_fold = gaussian(local_x, nearest_toe, 0.040) * gaussian(point.y, -0.635, 0.050)
        nail_fold *= smoothstep(0.105, 0.145, point.z) * (1.0 - smoothstep(0.215, 0.27, point.z))
        target.y -= 0.011 * nail_fold
        target.z += 0.010 * nail_fold
        plantar = gaussian(local_x, nearest_toe, 0.042) * gaussian(point.y, -0.60, 0.085)
        plantar *= 1.0 - smoothstep(0.10, 0.17, point.z)
        target.y -= 0.015 * plantar
        target.z -= 0.008 * plantar
        move = target - point
        if move.length > 1.0e-7:
            vertex.co = target
            affected_vertices.append(vertex)
            moved += 1
            maximum_move = max(maximum_move, move.length)
    for _ in range(5):
        bmesh.ops.smooth_vert(
            bm,
            verts=affected_vertices,
            factor=0.18,
            use_axis_x=True,
            use_axis_y=True,
            use_axis_z=True,
        )
    bm.to_mesh(bear.data)
    bm.free()
    bear.data.update()
    return moved, maximum_move


def main():
    args = parse_args()
    claws = sorted((obj for obj in bpy.context.scene.objects if "Claw" in obj.name), key=lambda obj: obj.name)
    if len(claws) != 20:
        raise RuntimeError(f"Claw visibility gate requires 20 claws, found {len(claws)}")
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Claw visibility gate requires the unified bear mesh")
    digit_vertices_moved, digit_maximum_move = sculpt_forepaw_digits(bear)
    report_items = []
    for obj in claws:
        family = "fore" if "ForeClaw" in obj.name else "hind"
        digit_index = int(obj.name.rsplit("_", 1)[-1]) - 1
        maximum_move = refine_claw(obj, family, digit_index)
        report_items.append({"name": obj.name, "family": family, "maximumVertexMove": maximum_move})
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_visible_claw_critic_gate",
        "source": "iteration-734-seam-rump-paw-refinement",
        "method": "retain buried roots, extend exposed digit-owned arcs, preserve broad proximal sections, and add restrained terminal curvature",
        "clawsRetained": len(claws),
        "foreclawMaximumAddedProjection": 0.026,
        "hindclawMaximumAddedProjection": 0.012,
        "rootWidthIncrease": 0.22,
        "rootDepthIncrease": 0.40,
        "additionalForeclawBurial": 0.026,
        "distalTipSectionIncrease": 0.30,
        "forepawDigitVerticesMoved": digit_vertices_moved,
        "forepawDigitMaximumMove": digit_maximum_move,
        "items": report_items,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_CLAW_VISIBILITY", json.dumps(report))


if __name__ == "__main__":
    main()

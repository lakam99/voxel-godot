import argparse
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector


def parse_args():
    parser = argparse.ArgumentParser(description="Pose and sculpt the frozen manifold bear using joint-space deformations.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def smoothstep(edge0, edge1, value):
    parameter = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return parameter * parameter * (3.0 - 2.0 * parameter)


def gaussian(point, center, scale):
    distance = sum(((point[index] - center[index]) / scale[index]) ** 2 for index in range(3))
    return math.exp(-0.5 * distance)


def rotate_yz(point, pivot_y, pivot_z, angle):
    delta_y = point.y - pivot_y
    delta_z = point.z - pivot_z
    cosine = math.cos(angle)
    sine = math.sin(angle)
    return Vector((point.x, pivot_y + delta_y * cosine - delta_z * sine, pivot_z + delta_y * sine + delta_z * cosine))


def topology(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    remaining = set(bm.verts)
    components = 0
    while remaining:
        components += 1
        frontier = [remaining.pop()]
        while frontier:
            vertex = frontier.pop()
            for edge in vertex.link_edges:
                neighbor = edge.other_vert(vertex)
                if neighbor in remaining:
                    remaining.remove(neighbor)
                    frontier.append(neighbor)
    result = {
        "vertices": len(bm.verts),
        "faces": len(bm.faces),
        "boundaryEdges": sum(1 for edge in bm.edges if len(edge.link_faces) == 1),
        "nonmanifoldEdges": sum(1 for edge in bm.edges if len(edge.link_faces) != 2),
        "components": components,
    }
    bm.free()
    return result


def transform_foreclaws():
    transformed = 0
    for obj in bpy.context.scene.objects:
        if "ForeClaw" not in obj.name:
            continue
        for vertex in obj.data.vertices:
            vertex.co = rotate_yz(vertex.co, 0.16, 0.82, 0.20)
            vertex.co.z += 0.14
        obj.data.update()
        transformed += 1
    return transformed


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Run from iteration 716")
    locked_before = sorted(
        (vertex.co.copy() for vertex in bear.data.vertices if vertex.co.y < -1.05 and vertex.co.z > 0.95),
        key=lambda value: (value.x, value.y, value.z),
    )
    maximum_move = 0.0
    moved_vertices = 0
    for vertex in bear.data.vertices:
        original = vertex.co.copy()
        if original.y < -1.05:
            continue
        point = original.copy()
        absolute_x = abs(point.x)
        side = -1.0 if point.x < 0.0 else 1.0

        extension_y = smoothstep(-0.52, 0.02, point.y)
        extension_z = smoothstep(0.20, 0.72, point.z)
        extension = 0.075 * extension_y * extension_z
        point.z = 0.12 + (point.z - 0.12) * (1.0 + extension)

        shoulder = gaussian((absolute_x, point.y, point.z), (0.68, -0.22, 1.52), (0.36, 0.30, 0.42))
        point.x += side * 0.070 * shoulder

        nuchal = gaussian((absolute_x, point.y, point.z), (0.58, -0.26, 1.74), (0.48, 0.42, 0.36))
        point.x += side * 0.105 * nuchal
        point.y += 0.035 * nuchal
        seam_fill = gaussian((absolute_x, point.y, point.z), (0.64, -0.82, 1.58), (0.42, 0.22, 0.48))
        point.x += side * 0.055 * seam_fill
        collar_ridge = gaussian((absolute_x, point.y, point.z), (0.34, -0.46, 2.02), (0.52, 0.34, 0.22))
        point.z -= 0.105 * collar_ridge
        collar_brisket = gaussian((absolute_x, point.y, point.z), (0.30, -0.26, 1.02), (0.46, 0.38, 0.26))
        point.z -= 0.070 * collar_brisket

        elbow = gaussian((absolute_x, point.y, point.z), (0.70, 0.10, 0.86), (0.28, 0.36, 0.32))
        point.y -= 0.230 * elbow

        hock = gaussian((absolute_x, point.y, point.z), (0.57, 0.88, 0.62), (0.28, 0.30, 0.29))
        point.y -= 0.100 * hock
        point.z += 0.035 * hock
        stifle = gaussian((absolute_x, point.y, point.z), (0.59, 0.66, 0.91), (0.28, 0.28, 0.27))
        point.y -= 0.080 * stifle

        pelvis = gaussian((absolute_x, point.y, point.z), (0.46, 0.80, 1.55), (0.54, 0.34, 0.48))
        point.z += 0.030 * pelvis
        point.x += side * 0.045 * pelvis
        sacral_flatten = gaussian((absolute_x, point.y, point.z), (0.30, 0.84, 1.82), (0.48, 0.26, 0.20))
        point.z -= 0.140 * sacral_flatten
        gluteal_round = gaussian((absolute_x, point.y, point.z), (0.58, 0.86, 1.43), (0.38, 0.30, 0.40))
        point.x += side * 0.075 * gluteal_round
        point.y += 0.045 * gluteal_round

        brisket = gaussian((absolute_x, point.y, point.z), (0.28, 0.02, 0.94), (0.42, 0.32, 0.25))
        point.z -= 0.105 * brisket
        abdomen = gaussian((absolute_x, point.y, point.z), (0.54, 0.42, 1.24), (0.44, 0.30, 0.38))
        point.x -= side * 0.100 * abdomen
        belly_tuck = gaussian((absolute_x, point.y, point.z), (0.30, 0.55, 0.98), (0.46, 0.26, 0.25))
        point.z += 0.095 * belly_tuck

        distal_forearm = gaussian((absolute_x, point.y, point.z), (0.68, -0.10, 0.43), (0.22, 0.24, 0.22))
        point.x += side * 0.036 * distal_forearm
        distal_hind = gaussian((absolute_x, point.y, point.z), (0.57, 0.72, 0.44), (0.22, 0.26, 0.22))
        point.x += side * 0.034 * distal_hind
        fore_paw_root = gaussian((absolute_x, point.y, point.z), (0.68, -0.22, 0.21), (0.25, 0.22, 0.15))
        point.x += side * 0.040 * fore_paw_root
        point.z += 0.012 * fore_paw_root
        hind_paw_root = gaussian((absolute_x, point.y, point.z), (0.57, 0.62, 0.21), (0.25, 0.24, 0.15))
        point.x += side * 0.038 * hind_paw_root
        point.z += 0.012 * hind_paw_root

        dorsal_height = smoothstep(1.20, 1.55, point.z)
        dorsal_entry = smoothstep(-0.34, -0.12, point.y)
        dorsal_exit = 1.0 - smoothstep(0.62, 0.90, point.y)
        dorsal_slope = smoothstep(-0.24, 0.76, point.y)
        point.z -= 0.075 * dorsal_height * dorsal_entry * dorsal_exit * dorsal_slope
        thigh_reduction = gaussian((absolute_x, point.y, point.z), (0.56, 0.64, 1.03), (0.34, 0.28, 0.34))
        point.x -= side * 0.080 * thigh_reduction
        upper_arm_reduction = gaussian((absolute_x, point.y, point.z), (0.70, -0.02, 1.02), (0.32, 0.30, 0.34))
        point.x -= side * 0.060 * upper_arm_reduction
        lower_hind = gaussian((absolute_x, point.y, point.z), (0.57, 0.74, 0.56), (0.26, 0.30, 0.34))
        point.z += 0.10 * max(0.0, point.z - 0.14) * lower_hind
        wrist_thickness = gaussian((absolute_x, point.y, point.z), (0.68, -0.16, 0.28), (0.22, 0.24, 0.18))
        point.x += side * 0.038 * wrist_thickness
        ankle_thickness = gaussian((absolute_x, point.y, point.z), (0.57, 0.70, 0.36), (0.22, 0.26, 0.20))
        point.x += side * 0.036 * ankle_thickness
        fore_paw_depth = gaussian((absolute_x, point.y, point.z), (0.68, -0.38, 0.15), (0.34, 0.34, 0.14))
        point.z += 0.20 * max(0.0, point.z - 0.08) * fore_paw_depth
        hind_paw_depth = gaussian((absolute_x, point.y, point.z), (0.57, 0.46, 0.15), (0.34, 0.38, 0.14))
        point.z += 0.19 * max(0.0, point.z - 0.08) * hind_paw_depth

        move = point - original
        if move.length > 1.0e-7:
            vertex.co = point
            moved_vertices += 1
            maximum_move = max(maximum_move, move.length)
    bear.data.update()

    bm = bmesh.new()
    bm.from_mesh(bear.data)
    seam_neck_vertices = [vertex for vertex in bm.verts if -1.045 < vertex.co.y < -0.16 and vertex.co.z > 0.95]
    for _ in range(3):
        bmesh.ops.smooth_vert(
            bm,
            verts=seam_neck_vertices,
            factor=0.06,
            use_axis_x=True,
            use_axis_y=True,
            use_axis_z=True,
        )
    bm.normal_update()
    for vertex in seam_neck_vertices:
        entry = smoothstep(-1.045, -0.90, vertex.co.y)
        exit_weight = 1.0 - smoothstep(-0.72, -0.50, vertex.co.y)
        height_weight = smoothstep(0.95, 1.20, vertex.co.z)
        vertex.co += vertex.normal * (0.082 * entry * exit_weight * height_weight)
    neck_vertices = [vertex for vertex in bm.verts if -0.94 < vertex.co.y < -0.16 and vertex.co.z > 0.98]
    for _ in range(6):
        bmesh.ops.smooth_vert(
            bm,
            verts=neck_vertices,
            factor=0.18,
            use_axis_x=True,
            use_axis_y=True,
            use_axis_z=True,
        )
    limb_vertices = [
        vertex
        for vertex in bm.verts
        if abs(vertex.co.x) > 0.44
        and 0.32 < vertex.co.z < 1.30
        and (-0.42 < vertex.co.y < 0.36 or 0.24 < vertex.co.y < 1.10)
    ]
    for _ in range(2):
        bmesh.ops.smooth_vert(
            bm,
            verts=limb_vertices,
            factor=0.08,
            use_axis_x=True,
            use_axis_y=True,
            use_axis_z=True,
        )
    bm.to_mesh(bear.data)
    bm.free()
    bear.data.update()
    transformed_claws = 0

    locked_after = sorted(
        (vertex.co.copy() for vertex in bear.data.vertices if vertex.co.y < -1.05 and vertex.co.z > 0.95),
        key=lambda value: (value.x, value.y, value.z),
    )
    if len(locked_before) != len(locked_after):
        raise RuntimeError("Joint-space pass changed locked face count")
    locked_displacement = max(((after - before).length for before, after in zip(locked_before, locked_after)), default=0.0)
    if locked_displacement > 1.0e-9:
        raise RuntimeError(f"Joint-space pass changed locked face by {locked_displacement}")
    mesh_topology = topology(bear)
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Joint-space topology gate failed: {mesh_topology}")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_joint_space_critic_gate",
        "source": "iteration-716-raised-neck-floor-hind-support",
        "method": "joint-space rotations, weighted vertical extension, regional volume sculpt, and restricted neck relaxation",
        "movedVertices": moved_vertices,
        "maximumVertexMove": maximum_move,
        "lockedFaceMaximumDisplacement": locked_displacement,
        "foreClawsTransformedWithPaws": transformed_claws,
        "clawsRetained": len([obj for obj in bpy.context.scene.objects if "Claw" in obj.name]),
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_JOINT_SPACE_SCULPT", json.dumps(report))


if __name__ == "__main__":
    main()

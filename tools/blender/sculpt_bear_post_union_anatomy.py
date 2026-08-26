import argparse
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector


def parse_args():
    parser = argparse.ArgumentParser(description="Apply continuous anatomical sculpt fields to the frozen manifold bear authority.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def field(point, center, scale):
    distance = sum(((point[index] - center[index]) / scale[index]) ** 2 for index in range(3))
    return math.exp(-0.5 * distance)


def topology(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    components = 0
    remaining = set(bm.verts)
    while remaining:
        components += 1
        seed = remaining.pop()
        frontier = [seed]
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


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Run from the frozen iteration-716 manifold authority")
    locked_before = sorted(
        (vertex.co.copy() for vertex in bear.data.vertices if vertex.co.y < -1.05 and vertex.co.z > 0.95),
        key=lambda value: (value.x, value.y, value.z),
    )
    maximum_move = 0.0
    moved_vertices = 0
    for vertex in bear.data.vertices:
        point = vertex.co.copy()
        if point.y < -1.05:
            continue
        side = -1.0 if point.x < 0.0 else 1.0
        absolute_x = abs(point.x)
        displacement = Vector((0.0, 0.0, 0.0))
        shoulder = field((absolute_x, point.y, point.z), (0.66, -0.24, 1.52), (0.34, 0.24, 0.38))
        displacement.x += side * 0.110 * shoulder
        displacement.z += 0.018 * shoulder
        triceps = field((absolute_x, point.y, point.z), (0.72, -0.08, 1.10), (0.24, 0.24, 0.30))
        displacement.x += side * 0.090 * triceps
        displacement.y += 0.040 * triceps
        elbow = field((absolute_x, point.y, point.z), (0.70, 0.00, 0.78), (0.20, 0.22, 0.20))
        displacement.y += 0.110 * elbow
        wrist = field((absolute_x, point.y, point.z), (0.68, -0.17, 0.31), (0.19, 0.20, 0.18))
        displacement.y -= 0.045 * wrist
        sternum = field((absolute_x, point.y, point.z), (0.30, 0.08, 0.92), (0.42, 0.30, 0.24))
        displacement.z -= 0.045 * sternum
        abdominal_tuck = field((absolute_x, point.y, point.z), (0.34, 0.48, 0.98), (0.48, 0.25, 0.28))
        displacement.z += 0.050 * abdominal_tuck
        gluteal = field((absolute_x, point.y, point.z), (0.56, 0.72, 1.34), (0.34, 0.28, 0.38))
        displacement.x += side * 0.065 * gluteal
        displacement.y += 0.025 * gluteal
        thigh = field((absolute_x, point.y, point.z), (0.58, 0.66, 1.02), (0.26, 0.22, 0.30))
        displacement.x += side * 0.045 * thigh
        hock = field((absolute_x, point.y, point.z), (0.57, 0.82, 0.56), (0.20, 0.20, 0.20))
        displacement.y += 0.130 * hock
        displacement.z += 0.070 * hock
        tibia = field((absolute_x, point.y, point.z), (0.57, 0.72, 0.72), (0.21, 0.20, 0.24))
        displacement.y += 0.035 * tibia
        hind_heel = field((absolute_x, point.y, point.z), (0.57, 0.64, 0.16), (0.22, 0.16, 0.10))
        displacement.z += 0.026 * hind_heel
        stifle = field((absolute_x, point.y, point.z), (0.59, 0.45, 0.91), (0.26, 0.25, 0.28))
        displacement.y -= 0.065 * stifle
        pelvis_lift = field((absolute_x, point.y, point.z), (0.48, 0.80, 1.55), (0.52, 0.34, 0.45))
        displacement.z += 0.105 * pelvis_lift
        sacral_top = field((absolute_x, point.y, point.z), (0.26, 0.84, 1.84), (0.46, 0.22, 0.16))
        displacement.z -= 0.025 * sacral_top
        collar_top = field((absolute_x, point.y, point.z), (0.38, -0.48, 2.02), (0.48, 0.24, 0.22))
        displacement.z -= 0.080 * collar_top
        collar_side = field((absolute_x, point.y, point.z), (0.76, -0.38, 1.68), (0.36, 0.38, 0.44))
        displacement.x += side * 0.120 * collar_side
        displacement.y += 0.018 * collar_side
        caudal_neck = field((absolute_x, point.y, point.z), (0.72, -0.16, 1.66), (0.38, 0.36, 0.46))
        displacement.x += side * 0.080 * caudal_neck
        displacement.z -= 0.015 * caudal_neck
        collar_floor = field((absolute_x, point.y, point.z), (0.34, -0.43, 1.18), (0.44, 0.25, 0.20))
        displacement.z += 0.035 * collar_floor
        displaced_y = point.y + displacement.y
        fore_column = field((absolute_x, point.y, point.z), (0.68, -0.08, 0.76), (0.24, 0.42, 0.56))
        if point.z > 0.24 and point.y < 0.34:
            displacement.y += 0.72 * fore_column * (-0.20 - displaced_y)
        displaced_y = point.y + displacement.y
        hind_column = field((absolute_x, point.y, point.z), (0.57, 0.72, 0.82), (0.27, 0.46, 0.55))
        if point.z > 0.24 and point.y > 0.22:
            displacement.y += 0.72 * hind_column * (0.68 - displaced_y)
        if displacement.length > 1.0e-7:
            vertex.co += displacement
            maximum_move = max(maximum_move, displacement.length)
            moved_vertices += 1
    bear.data.update()
    bm = bmesh.new()
    bm.from_mesh(bear.data)
    neck_vertices = [vertex for vertex in bm.verts if -0.88 < vertex.co.y < -0.12 and vertex.co.z > 0.98]
    for _ in range(4):
        bmesh.ops.smooth_vert(
            bm,
            verts=neck_vertices,
            factor=0.16,
            use_axis_x=True,
            use_axis_y=True,
            use_axis_z=True,
        )
    bm.to_mesh(bear.data)
    bm.free()
    bear.data.update()
    locked_after = sorted(
        (vertex.co.copy() for vertex in bear.data.vertices if vertex.co.y < -1.05 and vertex.co.z > 0.95),
        key=lambda value: (value.x, value.y, value.z),
    )
    if len(locked_before) != len(locked_after):
        raise RuntimeError("Continuous sculpt changed locked face count")
    locked_displacement = max(((after - before).length for before, after in zip(locked_before, locked_after)), default=0.0)
    if locked_displacement > 1.0e-9:
        raise RuntimeError(f"Continuous sculpt changed locked face by {locked_displacement}")
    mesh_topology = topology(bear)
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Continuous sculpt topology gate failed: {mesh_topology}")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_continuous_sculpt_critic_gate",
        "source": "iteration-716-raised-neck-floor-hind-support",
        "method": "continuous Gaussian anatomical deformation fields on the frozen unified manifold surface",
        "neckSmoothing": {"iterations": 4, "factor": 0.16, "rangeY": [-0.88, -0.12], "minimumZ": 0.98},
        "movedVertices": moved_vertices,
        "maximumVertexMove": maximum_move,
        "lockedFaceMaximumDisplacement": locked_displacement,
        "clawsRetained": len([obj for obj in bpy.context.scene.objects if "Claw" in obj.name]),
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_CONTINUOUS_SCULPT", json.dumps(report))


if __name__ == "__main__":
    main()

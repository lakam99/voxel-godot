import argparse
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy


def parse_args():
    parser = argparse.ArgumentParser(description="Refine load-bearing bear limbs while preserving passed anatomy.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def gaussian(point, center, scale):
    distance = sum(((point[index] - center[index]) / scale[index]) ** 2 for index in range(3))
    return math.exp(-0.5 * distance)


def smoothstep(edge0, edge1, value):
    factor = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return factor * factor * (3.0 - 2.0 * factor)


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


def is_protected(point):
    return point.z < 0.38 or point.y < -0.58


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Run from the passed torso/pelvis authority")
    claws_before = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if len(claws_before) != 20:
        raise RuntimeError(f"Limb pass requires 20 claws, found {len(claws_before)}")
    protected_before = {
        vertex.index: vertex.co.copy()
        for vertex in bear.data.vertices
        if is_protected(vertex.co)
    }
    moved_vertices = 0
    maximum_move = 0.0
    for vertex in bear.data.vertices:
        point = vertex.co
        if is_protected(point):
            continue
        original = point.copy()
        absolute_x = abs(point.x)
        side = -1.0 if point.x < 0.0 else 1.0
        lateral_ramp = smoothstep(0.38, 0.62, absolute_x)

        upper_arm = gaussian((absolute_x, point.y, point.z), (0.72, -0.02, 1.00), (0.31, 0.30, 0.34))
        point.x -= side * 0.095 * upper_arm * lateral_ramp

        triceps_taper = gaussian((absolute_x, point.y, point.z), (0.72, 0.04, 0.82), (0.28, 0.28, 0.28))
        point.x -= side * 0.045 * triceps_taper * lateral_ramp

        proximal_hind = gaussian((absolute_x, point.y, point.z), (0.66, 0.58, 0.96), (0.34, 0.34, 0.38))
        point.x += side * 0.090 * proximal_hind * lateral_ramp

        stifle = gaussian((absolute_x, point.y, point.z), (0.65, 0.58, 0.78), (0.28, 0.28, 0.25))
        point.y += 0.035 * stifle
        point.z -= 0.045 * stifle

        hock = gaussian((absolute_x, point.y, point.z), (0.63, 0.72, 0.53), (0.25, 0.28, 0.22))
        point.y -= 0.085 * hock
        point.z -= 0.120 * hock

        hind_column = gaussian((absolute_x, point.y, point.z), (0.63, 0.67, 0.65), (0.28, 0.32, 0.31))
        point.x += side * 0.075 * hind_column * lateral_ramp
        point.y -= 0.070 * hind_column

        displacement = (point - original).length
        if displacement > 1.0e-7:
            moved_vertices += 1
            maximum_move = max(maximum_move, displacement)
    bear.data.update()
    protected_displacement = max(
        ((bear.data.vertices[index].co - before).length for index, before in protected_before.items()),
        default=0.0,
    )
    if protected_displacement > 1.0e-9:
        raise RuntimeError(f"Limb pass changed protected anatomy by {protected_displacement}")
    mesh_topology = topology(bear)
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Limb pass topology gate failed: {mesh_topology}")
    claws_after = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if claws_after != claws_before:
        raise RuntimeError("Limb pass changed the passed claw set")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_load_bearing_limb_critic_gate",
        "source": "iteration-789-inverted-u-posterior-remap",
        "method": "bounded upper-arm reduction and joint-space hindlimb support fields",
        "movedVertices": moved_vertices,
        "maximumVertexMove": maximum_move,
        "protectedMaximumDisplacement": protected_displacement,
        "clawsRetained": len(claws_after),
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_LOAD_BEARING_LIMBS", json.dumps(report))


if __name__ == "__main__":
    main()

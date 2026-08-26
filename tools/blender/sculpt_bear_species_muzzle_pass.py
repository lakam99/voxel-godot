import argparse
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils.bvhtree import BVHTree


def parse_args():
    parser = argparse.ArgumentParser(description="Recover adult brown-bear muzzle length, taper, and nasal slope.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def smoothstep(edge0, edge1, value):
    factor = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return factor * factor * (3.0 - 2.0 * factor)


def gaussian(point, center, scale):
    distance = sum(((point[index] - center[index]) / scale[index]) ** 2 for index in range(3))
    return math.exp(-0.5 * distance)


def topology(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    result = {
        "vertices": len(bm.verts),
        "faces": len(bm.faces),
        "boundaryEdges": sum(1 for edge in bm.edges if len(edge.link_faces) == 1),
        "nonmanifoldEdges": sum(1 for edge in bm.edges if len(edge.link_faces) != 2),
    }
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
    result["components"] = components
    bm.free()
    return result


def nonadjacent_intersections(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    bvh = BVHTree.FromBMesh(bm)
    count = 0
    for first, second in bvh.overlap(bvh):
        if first >= second:
            continue
        first_vertices = {vertex.index for vertex in bm.faces[first].verts}
        second_vertices = {vertex.index for vertex in bm.faces[second].verts}
        if not first_vertices.intersection(second_vertices):
            count += 1
    bm.free()
    return count


def fair_maxillary_transition(bear):
    bm = bmesh.new()
    bm.from_mesh(bear.data)
    selected = [
        vertex
        for vertex in bm.verts
        if -1.50 < vertex.co.y < -0.92
        and 1.04 < vertex.co.z < 1.54
        and abs(vertex.co.x) < 0.62
    ]
    for _ in range(12):
        bmesh.ops.smooth_vert(
            bm,
            verts=selected,
            factor=0.16,
            use_axis_x=True,
            use_axis_y=True,
            use_axis_z=True,
        )
    bm.to_mesh(bear.data)
    bm.free()
    bear.data.update()
    return len(selected)


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Species muzzle pass requires the unified bear mesh")
    claws_before = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if len(claws_before) != 20:
        raise RuntimeError(f"Species muzzle pass requires 20 claws, found {len(claws_before)}")
    protected_before = {
        vertex.index: vertex.co.copy()
        for vertex in bear.data.vertices
        if vertex.co.y >= -0.92 or vertex.co.z >= 1.88
    }
    moved = 0
    maximum_move = 0.0
    anchor_y = -0.92
    for vertex in bear.data.vertices:
        point = vertex.co
        if point.y >= anchor_y or point.z < 1.02 or point.z >= 1.88:
            continue
        original = point.copy()
        longitudinal = smoothstep(anchor_y, -1.68, point.y)
        facial = smoothstep(1.02, 1.18, point.z) * (1.0 - smoothstep(1.78, 1.88, point.z))
        eye_guard = gaussian((abs(point.x), point.y, point.z), (0.38, -1.35, 1.70), (0.18, 0.20, 0.17))
        weight = longitudinal * facial * (1.0 - 0.96 * eye_guard)
        point.y = anchor_y + (point.y - anchor_y) * (1.0 + 0.12 * weight)

        root_mass = gaussian((abs(original.x), original.y, original.z), (0.38, -1.31, 1.48), (0.30, 0.22, 0.26))
        point.x *= 1.0 + 0.050 * root_mass * (1.0 - eye_guard)
        terminal = smoothstep(-1.50, -1.76, original.y) * facial
        point.x *= 1.0 - 0.100 * terminal

        upper_lip = gaussian((abs(original.x), original.y, original.z), (0.33, -1.52, 1.35), (0.28, 0.24, 0.18))
        point.x *= 1.0 - 0.100 * upper_lip
        point.z = 1.34 + (point.z - 1.34) * (1.0 - 0.090 * upper_lip)

        nasal = gaussian((abs(original.x), original.y, original.z), (0.17, -1.72, 1.48), (0.24, 0.20, 0.17))
        point.z -= 0.035 * nasal
        bridge = gaussian((abs(original.x), original.y, original.z), (0.18, -1.47, 1.63), (0.30, 0.27, 0.20))
        point.z -= 0.014 * bridge * longitudinal

        mouth_corner = gaussian((abs(original.x), original.y, original.z), (0.37, -1.53, 1.27), (0.18, 0.16, 0.12))
        point.y += 0.012 * mouth_corner
        point.x *= 1.0 - 0.060 * mouth_corner
        lower_jaw = gaussian((abs(original.x), original.y, original.z), (0.25, -1.43, 1.16), (0.30, 0.26, 0.14))
        point.z -= 0.038 * lower_jaw
        point.y -= 0.012 * lower_jaw

        displacement = point - original
        if displacement.length > 0.17:
            displacement.normalize()
            displacement *= 0.17
        if displacement.length > 1.0e-7:
            vertex.co = original + displacement
            moved += 1
            maximum_move = max(maximum_move, displacement.length)
    bear.data.update()
    transition_vertices = fair_maxillary_transition(bear)
    protected_displacement = max(
        ((bear.data.vertices[index].co - before).length for index, before in protected_before.items()),
        default=0.0,
    )
    if protected_displacement > 1.0e-9:
        raise RuntimeError(f"Species muzzle pass moved protected eye, ear, or body vertices by {protected_displacement}")
    mesh_topology = topology(bear)
    intersections = nonadjacent_intersections(bear)
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Species muzzle topology gate failed: {mesh_topology}")
    if intersections:
        raise RuntimeError(f"Species muzzle pass created {intersections} nonadjacent intersections")
    claws_after = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if claws_after != claws_before:
        raise RuntimeError("Species muzzle pass changed the passed claw set")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_whole_bear_critic_gate",
        "source": "iteration-805-weight-bearing-paws",
        "method": "muzzle-only occipital-anchored species warp preserving eyes, ears, body, paws, and claws",
        "muzzleLengthIncrease": 0.12,
        "terminalWidthReduction": 0.10,
        "muzzleRootWidthIncrease": 0.05,
        "upperLipCheekReduction": 0.10,
        "nasalTipDrop": 0.035,
        "maxillaryTransitionVerticesSmoothed": transition_vertices,
        "movedVertices": moved,
        "maximumVertexMove": maximum_move,
        "protectedMaximumDisplacement": protected_displacement,
        "clawsRetained": len(claws_after),
        "nonadjacentIntersections": intersections,
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_SPECIES_MUZZLE", json.dumps(report))


if __name__ == "__main__":
    main()

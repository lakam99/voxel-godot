import argparse
import json
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils.bvhtree import BVHTree


def parse_args():
    parser = argparse.ArgumentParser(description="Restore the critic-passed iteration 742 paw and claw authority.")
    parser.add_argument("--source-blend", required=True)
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def smoothstep(edge0, edge1, value):
    factor = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return factor * factor * (3.0 - 2.0 * factor)


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


def intersection_vertex_indices(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    bvh = BVHTree.FromBMesh(bm)
    vertices = set()
    pairs = 0
    for first, second in bvh.overlap(bvh):
        if first >= second:
            continue
        first_vertices = {vertex.index for vertex in bm.faces[first].verts}
        second_vertices = {vertex.index for vertex in bm.faces[second].verts}
        if first_vertices.intersection(second_vertices):
            continue
        vertices.update(first_vertices)
        vertices.update(second_vertices)
        pairs += 1
    bm.free()
    return pairs, vertices


def paw_weight(point):
    if point.z < 0.035 or point.z > 0.43:
        return 0.0
    absolute_x = abs(point.x)
    if point.y < -0.02:
        lateral = 1.0 - smoothstep(0.32, 0.48, abs(absolute_x - 0.68))
        proximal = 1.0 - smoothstep(-0.28, -0.08, point.y)
        vertical = 1.0 - smoothstep(0.30, 0.43, point.z)
        return lateral * proximal * vertical
    lateral = 1.0 - smoothstep(0.32, 0.48, abs(absolute_x - 0.57))
    proximal = 1.0 - smoothstep(0.58, 0.88, point.y)
    vertical = 1.0 - smoothstep(0.30, 0.43, point.z)
    return lateral * proximal * vertical


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Passed paw restoration requires the unified current bear mesh")
    original_positions = [vertex.co.copy() for vertex in bear.data.vertices]
    current_claws = [obj for obj in bpy.context.scene.objects if "Claw" in obj.name]
    if len(current_claws) != 20:
        raise RuntimeError(f"Expected 20 current claws, found {len(current_claws)}")
    for claw in current_claws:
        bpy.data.objects.remove(claw, do_unlink=True)
    with bpy.data.libraries.load(args.source_blend, link=False) as (available, requested):
        claw_names = sorted(name for name in available.objects if "Claw" in name)
        if "BrownBear_LandmarkSubdivisionCage" not in available.objects or len(claw_names) != 20:
            raise RuntimeError("Iteration 742 source does not contain the complete passed paw authority")
        requested.objects = ["BrownBear_LandmarkSubdivisionCage", *claw_names]
    source = requested.objects[0]
    source.name = "BrownBear_Iteration742PassedPawSource"
    bpy.context.scene.collection.objects.link(source)
    source.hide_render = True
    source.hide_set(True)
    restored_claws = requested.objects[1:]
    for claw in restored_claws:
        bpy.context.scene.collection.objects.link(claw)
    source_bmesh = bmesh.new()
    source_bmesh.from_mesh(source.data)
    source_bvh = BVHTree.FromBMesh(source_bmesh)
    moved = 0
    maximum_move = 0.0
    for vertex in bear.data.vertices:
        weight = paw_weight(vertex.co)
        if weight <= 0.0:
            continue
        nearest = source_bvh.find_nearest(vertex.co, 0.30)
        if nearest[0] is None:
            continue
        target = nearest[0]
        displacement = target - vertex.co
        if displacement.length > 0.25:
            continue
        vertex.co = vertex.co.lerp(target, weight)
        moved += 1
        maximum_move = max(maximum_move, displacement.length * weight)
    bear.data.update()
    rollback_iterations = 0
    for rollback_iterations in range(1, 13):
        pairs, bad_vertices = intersection_vertex_indices(bear)
        if not pairs:
            rollback_iterations -= 1
            break
        for index in bad_vertices:
            bear.data.vertices[index].co = bear.data.vertices[index].co.lerp(original_positions[index], 0.55)
        bear.data.update()
    source_bmesh.free()
    bpy.data.objects.remove(source, do_unlink=True)
    mesh_topology = topology(bear)
    intersections, _ = intersection_vertex_indices(bear)
    claws_after = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if len(claws_after) != 20:
        raise RuntimeError(f"Passed paw restoration retained {len(claws_after)} claws")
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Passed paw topology gate failed: {mesh_topology}")
    if intersections:
        raise RuntimeError(f"Passed paw restoration left {intersections} body intersections")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_whole_bear_critic_gate",
        "sourceBody": "iteration-804-intersection-safe-facial-authority",
        "sourcePawsAndClaws": str(Path(args.source_blend)),
        "method": "nearest-surface restoration of the critic-passed iteration 742 paw envelope with exact passed claw objects",
        "bodyVerticesMoved": moved,
        "maximumBodyVertexMove": maximum_move,
        "intersectionRollbackIterations": rollback_iterations,
        "clawsRetained": len(claws_after),
        "nonadjacentIntersections": intersections,
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_PASSED_PAW_AUTHORITY_RESTORED", json.dumps(report))


if __name__ == "__main__":
    main()

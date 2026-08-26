import argparse
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils.bvhtree import BVHTree


def parse_args():
    parser = argparse.ArgumentParser(description="Restore craniofacial relief by bounded nearest-surface reprojection.")
    parser.add_argument("--source-blend", required=True)
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
    intersections = 0
    for first, second in bvh.overlap(bvh):
        if first >= second:
            continue
        first_vertices = {vertex.index for vertex in bm.faces[first].verts}
        second_vertices = {vertex.index for vertex in bm.faces[second].verts}
        if not first_vertices.intersection(second_vertices):
            intersections += 1
    bm.free()
    return intersections


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


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Run from iteration 796")
    claws_before = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    with bpy.data.libraries.load(args.source_blend, link=False) as (available, requested):
        if "BrownBear_LandmarkSubdivisionCage" not in available.objects:
            raise RuntimeError("Source blend lacks BrownBear_LandmarkSubdivisionCage")
        requested.objects = ["BrownBear_LandmarkSubdivisionCage"]
    source = requested.objects[0]
    source.name = "BrownBear_Iteration793RayProjectionSource"
    bpy.context.scene.collection.objects.link(source)
    source.hide_render = True
    source.hide_set(True)
    source_bmesh = bmesh.new()
    source_bmesh.from_mesh(source.data)
    source_bvh = BVHTree.FromBMesh(source_bmesh)
    bear.data.update()
    original_positions = [vertex.co.copy() for vertex in bear.data.vertices]
    reprojected = 0
    maximum_move = 0.0
    for vertex in bear.data.vertices:
        point = vertex.co
        if point.y >= -0.72 or point.z < 1.05:
            continue
        weight = 1.0 - smoothstep(-0.90, -0.72, point.y)
        if weight <= 0.0:
            continue
        hit, _, _, distance = source_bvh.find_nearest(point, 0.30)
        if hit is None:
            continue
        displacement = hit - point
        if displacement.length > 0.28:
            continue
        applied_weight = 0.92 * weight
        vertex.co = point.lerp(hit, applied_weight)
        reprojected += 1
        maximum_move = max(maximum_move, displacement.length * applied_weight)
    landmark_vertices = 0
    landmark_strength = 0.0
    for vertex in bear.data.vertices:
        point = vertex.co
        if point.y >= -0.82 or point.z < 1.02:
            continue
        original = point.copy()
        absolute_x = abs(point.x)
        side = -1.0 if point.x < 0.0 else 1.0
        eye_recess = gaussian((absolute_x, point.y, point.z), (0.38, -1.36, 1.70), (0.18, 0.20, 0.18))
        point.x -= side * 0.032 * landmark_strength * eye_recess
        point.y += 0.030 * landmark_strength * eye_recess
        cheek_break = gaussian((absolute_x, point.y, point.z), (0.46, -1.43, 1.48), (0.25, 0.24, 0.25))
        point.x -= side * 0.050 * landmark_strength * cheek_break
        nose_plane = gaussian((absolute_x, point.y, point.z), (0.20, -1.72, 1.47), (0.24, 0.17, 0.18))
        lateral_ramp = smoothstep(0.03, 0.22, absolute_x)
        point.x -= side * 0.030 * landmark_strength * nose_plane * lateral_ramp
        mouth_corner = gaussian((absolute_x, point.y, point.z), (0.42, -1.55, 1.28), (0.18, 0.16, 0.13))
        point.y += 0.018 * landmark_strength * mouth_corner
        if (point - original).length > 1.0e-7:
            landmark_vertices += 1
    bear.data.update()
    rollback_iterations = 0
    for rollback_iterations in range(1, 13):
        intersection_pairs, bad_vertices = intersection_vertex_indices(bear)
        if not intersection_pairs:
            rollback_iterations -= 1
            break
        for index in bad_vertices:
            bear.data.vertices[index].co = bear.data.vertices[index].co.lerp(original_positions[index], 0.55)
        bear.data.update()
    source_bmesh.free()
    bpy.data.objects.remove(source, do_unlink=True)
    mesh_topology = topology(bear)
    intersections = nonadjacent_intersections(bear)
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Craniofacial ray projection topology gate failed: {mesh_topology}")
    if intersections:
        raise RuntimeError(f"Craniofacial ray projection created {intersections} nonadjacent intersections")
    claws_after = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if claws_after != claws_before:
        raise RuntimeError("Craniofacial ray projection changed the passed claw set")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_whole_bear_critic_gate",
        "sourceBody": "iteration-796-reprojected-distal-junction-remesh",
        "sourceFace": str(Path(args.source_blend)),
        "method": "bounded nearest-surface reprojection with occipital feather and intersection rollback",
        "reprojectedVertices": reprojected,
        "maximumVertexMove": maximum_move,
        "landmarkSculptVertices": landmark_vertices,
        "intersectionRollbackIterations": rollback_iterations,
        "clawsRetained": len(claws_after),
        "nonadjacentIntersections": intersections,
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_CRANIOFACIAL_RAY_REPROJECT", json.dumps(report))


if __name__ == "__main__":
    main()

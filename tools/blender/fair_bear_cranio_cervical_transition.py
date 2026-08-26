import argparse
import json
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils.bvhtree import BVHTree


def parse_args():
    parser = argparse.ArgumentParser(description="Remove the residual cranio-cervical authority ring without changing the face or paws.")
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


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Cranio-cervical fairing requires the unified bear mesh")
    claws_before = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if len(claws_before) != 20:
        raise RuntimeError(f"Cranio-cervical fairing requires 20 claws, found {len(claws_before)}")
    vertices = bear.data.vertices
    original_positions = [vertex.co.copy() for vertex in vertices]
    adjacency = [[] for _ in vertices]
    for edge in bear.data.edges:
        first, second = edge.vertices
        adjacency[first].append(second)
        adjacency[second].append(first)
    weights = {}
    for vertex in vertices:
        point = vertex.co
        if point.y <= -1.10 or point.y >= -0.74 or point.z <= 1.14 or point.z >= 2.04:
            continue
        longitudinal = smoothstep(-1.10, -0.99, point.y) * (1.0 - smoothstep(-0.87, -0.74, point.y))
        vertical = smoothstep(1.14, 1.31, point.z) * (1.0 - smoothstep(1.94, 2.04, point.z))
        weight = longitudinal * vertical
        if weight > 0.0:
            weights[vertex.index] = weight
    maximum_allowed_move = 0.028
    for _ in range(180):
        updates = {}
        for index, weight in weights.items():
            neighbors = adjacency[index]
            if not neighbors:
                continue
            average = sum((vertices[neighbor].co for neighbor in neighbors), vertices[index].co.copy() * 0.0) / len(neighbors)
            target = vertices[index].co.lerp(average, 0.30 * weight)
            offset = target - original_positions[index]
            if offset.length > maximum_allowed_move:
                offset.normalize()
                offset *= maximum_allowed_move
                target = original_positions[index] + offset
            updates[index] = target
        for index, target in updates.items():
            vertices[index].co = target
    bear.data.update()
    rollback_iterations = 0
    for rollback_iterations in range(1, 9):
        pairs, bad_vertices = intersection_vertex_indices(bear)
        if not pairs:
            rollback_iterations -= 1
            break
        for index in bad_vertices:
            vertices[index].co = vertices[index].co.lerp(original_positions[index], 0.55)
        bear.data.update()
    mesh_topology = topology(bear)
    intersections, _ = intersection_vertex_indices(bear)
    displacements = [(vertex.co - original_positions[vertex.index]).length for vertex in vertices]
    face_displacement = max(
        (displacements[vertex.index] for vertex in vertices if vertex.co.y < -1.18),
        default=0.0,
    )
    paw_displacement = max(
        (displacements[vertex.index] for vertex in vertices if vertex.co.z < 0.45),
        default=0.0,
    )
    if face_displacement > 1.0e-9 or paw_displacement > 1.0e-9:
        raise RuntimeError(f"Cranio-cervical fairing escaped its mask: face={face_displacement}, paws={paw_displacement}")
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Cranio-cervical topology gate failed: {mesh_topology}")
    if intersections:
        raise RuntimeError(f"Cranio-cervical fairing left {intersections} intersections")
    claws_after = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if claws_after != claws_before:
        raise RuntimeError("Cranio-cervical fairing changed the passed claw set")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_final_whole_bear_critic_gate",
        "source": "iteration-815-restored-paws-continuous-maxilla",
        "method": "bounded adjacency fairing across a 26 percent head-length cranio-cervical band with jaw, face, and paw locks",
        "verticesSmoothed": len(weights),
        "maximumVertexMove": max(displacements),
        "maximumAllowedMove": maximum_allowed_move,
        "protectedFaceMaximumMove": face_displacement,
        "protectedPawMaximumMove": paw_displacement,
        "intersectionRollbackIterations": rollback_iterations,
        "clawsRetained": len(claws_after),
        "nonadjacentIntersections": intersections,
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_CRANIO_CERVICAL_FAIRING", json.dumps(report))


if __name__ == "__main__":
    main()

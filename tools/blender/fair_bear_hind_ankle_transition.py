import argparse
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils.bvhtree import BVHTree


def parse_args():
    parser = argparse.ArgumentParser(description="Integrate each hind crus into the passed plantigrade heel without changing the foot authority.")
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
        raise RuntimeError("Hind-ankle fairing requires the unified bear mesh")
    claws_before = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if len(claws_before) != 20:
        raise RuntimeError(f"Hind-ankle fairing requires 20 claws, found {len(claws_before)}")
    vertices = bear.data.vertices
    original_positions = [vertex.co.copy() for vertex in vertices]
    remodeled_vertices = 0
    remodel_maximum_move = 0.0
    bear.data.update()
    for vertex in vertices:
        point = vertex.co
        side = -1.0 if point.x < 0.0 else 1.0
        center_x = side * 0.57
        local_x = point.x - center_x
        if abs(local_x) >= 0.34 or point.y <= 0.40 or point.y >= 0.95 or point.z <= 0.08 or point.z >= 0.40:
            continue
        original = point.copy()
        upper_surface = max(0.0, min(1.0, vertex.normal.z))
        longitudinal = smoothstep(0.40, 0.53, point.y) * (1.0 - smoothstep(0.82, 0.95, point.y))
        vertical = smoothstep(0.08, 0.16, point.z) * (1.0 - smoothstep(0.32, 0.40, point.z))
        bridge = upper_surface * longitudinal * vertical
        point.z += 0.180 * bridge
        point.y += 0.025 * bridge
        point.x = center_x + local_x * (1.0 - 0.06 * bridge)
        move = point - original
        if move.length > 1.0e-7:
            remodeled_vertices += 1
            remodel_maximum_move = max(remodel_maximum_move, move.length)
    bear.data.update()
    adjacency = [[] for _ in vertices]
    for edge in bear.data.edges:
        first, second = edge.vertices
        adjacency[first].append(second)
        adjacency[second].append(first)
    bm = bmesh.new()
    bm.from_mesh(bear.data)
    bm.verts.ensure_lookup_table()
    crease_seeds = set()
    for edge in bm.edges:
        if len(edge.link_faces) != 2 or edge.calc_face_angle(0.0) < math.radians(42.0):
            continue
        midpoint = (edge.verts[0].co + edge.verts[1].co) * 0.5
        if 0.52 < midpoint.y < 0.98 and 0.24 < midpoint.z < 0.43 and 0.32 < abs(midpoint.x) < 0.94:
            crease_seeds.update(vertex.index for vertex in edge.verts)
    bm.free()
    if not crease_seeds:
        raise RuntimeError("No hind-ankle cuff crease edges were detected")
    depths = {index: 0 for index in crease_seeds}
    frontier = list(crease_seeds)
    for depth in range(1, 14):
        following = []
        for index in frontier:
            for neighbor in adjacency[index]:
                point = vertices[neighbor].co
                if neighbor in depths or point.y < 0.40 or point.z < 0.08 or point.z > 0.58:
                    continue
                depths[neighbor] = depth
                following.append(neighbor)
        frontier = following
    weights = {index: (1.0 - depth / 14.0) ** 2 for index, depth in depths.items()}
    maximum_allowed_move = 0.160
    for _ in range(220):
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
    for rollback_iterations in range(1, 21):
        pairs, bad_vertices = intersection_vertex_indices(bear)
        if not pairs:
            rollback_iterations -= 1
            break
        for index in bad_vertices:
            vertices[index].co = vertices[index].co.lerp(original_positions[index], 0.65)
        bear.data.update()
    mesh_topology = topology(bear)
    intersections, _ = intersection_vertex_indices(bear)
    displacements = [(vertex.co - original_positions[vertex.index]).length for vertex in vertices]
    protected_foot_move = max(
        (
            displacements[vertex.index]
            for vertex in vertices
            if vertex.co.z < 0.055 or vertex.co.y < 0.34
        ),
        default=0.0,
    )
    face_move = max(
        (displacements[vertex.index] for vertex in vertices if vertex.co.y < -0.40),
        default=0.0,
    )
    if protected_foot_move > 1.0e-9 or face_move > 1.0e-9:
        raise RuntimeError(f"Hind-ankle fairing escaped its mask: feet={protected_foot_move}, face={face_move}")
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Hind-ankle topology gate failed: {mesh_topology}")
    if intersections:
        raise RuntimeError(f"Hind-ankle fairing left {intersections} intersections")
    claws_after = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if claws_after != claws_before:
        raise RuntimeError("Hind-ankle fairing changed the passed claw set")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_final_whole_bear_critic_gate",
        "source": "iteration-818-corrected-ring-center-fairing",
        "method": "bounded bilateral hind-crus-to-heel adjacency fairing with foot, digit, sole, claw, and face locks",
        "verticesSmoothed": len(weights),
        "detectedCreaseVertices": len(crease_seeds),
        "crusVerticesRemodeled": remodeled_vertices,
        "crusRemodelMaximumMove": remodel_maximum_move,
        "maximumVertexMove": max(displacements),
        "maximumAllowedMove": maximum_allowed_move,
        "protectedFootMaximumMove": protected_foot_move,
        "protectedFaceMaximumMove": face_move,
        "intersectionRollbackIterations": rollback_iterations,
        "clawsRetained": len(claws_after),
        "nonadjacentIntersections": intersections,
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_HIND_ANKLE_FAIRING", json.dumps(report))


if __name__ == "__main__":
    main()

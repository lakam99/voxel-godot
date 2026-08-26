import argparse
import json
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree


def parse_args():
    parser = argparse.ArgumentParser(description="Repair localized bear self-intersections without remeshing protected anatomy.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def intersection_vertices(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    bvh = BVHTree.FromBMesh(bm)
    bad_vertices = set()
    pairs = 0
    for first, second in bvh.overlap(bvh):
        if first >= second:
            continue
        first_vertices = {vertex.index for vertex in bm.faces[first].verts}
        second_vertices = {vertex.index for vertex in bm.faces[second].verts}
        if first_vertices.intersection(second_vertices):
            continue
        bad_vertices.update(first_vertices)
        bad_vertices.update(second_vertices)
        pairs += 1
    bm.free()
    return pairs, bad_vertices


def intersection_face_pairs(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    bvh = BVHTree.FromBMesh(bm)
    collisions = []
    for first, second in bvh.overlap(bvh):
        if first >= second:
            continue
        first_vertices = {vertex.index for vertex in bm.faces[first].verts}
        second_vertices = {vertex.index for vertex in bm.faces[second].verts}
        if first_vertices.intersection(second_vertices):
            continue
        first_face = bm.faces[first]
        second_face = bm.faces[second]
        collisions.append(
            (
                first_vertices,
                second_vertices,
                first_face.calc_center_median().copy(),
                second_face.calc_center_median().copy(),
                first_face.normal.copy(),
                second_face.normal.copy(),
            )
        )
    bm.free()
    return collisions


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
    return point.y < -0.92 and point.z > 1.18


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Missing unified bear mesh")
    claws_before = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    original_positions = [vertex.co.copy() for vertex in bear.data.vertices]
    neighbors = [[] for _ in bear.data.vertices]
    for edge in bear.data.edges:
        first, second = edge.vertices
        neighbors[first].append(second)
        neighbors[second].append(first)

    initial_pairs, _ = intersection_vertices(bear)
    history = [initial_pairs]
    best_pairs = initial_pairs
    best_positions = [vertex.co.copy() for vertex in bear.data.vertices]
    touched = set()
    maximum_move = 0.0
    for _ in range(70):
        pairs, core = intersection_vertices(bear)
        if not pairs:
            break
        ring_by_vertex = {index: 0 for index in core if not is_protected(bear.data.vertices[index].co)}
        frontier = set(ring_by_vertex)
        for ring in range(1, 4):
            next_frontier = set()
            for index in frontier:
                for neighbor in neighbors[index]:
                    if neighbor in ring_by_vertex or is_protected(bear.data.vertices[neighbor].co):
                        continue
                    ring_by_vertex[neighbor] = ring
                    next_frontier.add(neighbor)
            frontier = next_frontier
        touched.update(ring_by_vertex)
        strengths = (0.46, 0.31, 0.19, 0.10)
        substeps = 5
        for _ in range(substeps):
            positions = [vertex.co.copy() for vertex in bear.data.vertices]
            updates = {}
            for index, ring in ring_by_vertex.items():
                if not neighbors[index]:
                    continue
                average = sum((positions[neighbor] for neighbor in neighbors[index]), Vector()) / len(neighbors[index])
                candidate = positions[index].lerp(average, strengths[ring])
                displacement = candidate - original_positions[index]
                if displacement.length > 0.16:
                    displacement.normalize()
                    displacement *= 0.16
                    candidate = original_positions[index] + displacement
                updates[index] = candidate
            for index, candidate in updates.items():
                bear.data.vertices[index].co = candidate
                maximum_move = max(maximum_move, (candidate - original_positions[index]).length)
        bear.data.update()
        next_pairs, _ = intersection_vertices(bear)
        history.append(next_pairs)
        if next_pairs < best_pairs:
            best_pairs = next_pairs
            best_positions = [vertex.co.copy() for vertex in bear.data.vertices]
        if best_pairs == 1:
            break

    if best_pairs < history[-1]:
        for vertex, position in zip(bear.data.vertices, best_positions):
            vertex.co = position
        bear.data.update()

    separation_iterations = 0
    collisions = intersection_face_pairs(bear)
    if collisions:
        baseline = [vertex.co.copy() for vertex in bear.data.vertices]
        solved = False
        direction_modes = ("centers", "first_normal", "second_normal", "normal_difference")
        for epsilon in (0.0005, 0.001, 0.002, 0.004, 0.008, 0.012, 0.018):
            if solved:
                break
            for direction_mode in direction_modes:
                separation_iterations += 1
                for vertex, position in zip(bear.data.vertices, baseline):
                    vertex.co = position
                for first_vertices, second_vertices, first_center, second_center, first_normal, second_normal in collisions:
                    if direction_mode == "centers":
                        direction = first_center - second_center
                    elif direction_mode == "first_normal":
                        direction = first_normal
                    elif direction_mode == "second_normal":
                        direction = second_normal
                    else:
                        direction = first_normal - second_normal
                    if direction.length <= 1.0e-6:
                        continue
                    direction.normalize()
                    for index in first_vertices:
                        if not is_protected(baseline[index]):
                            bear.data.vertices[index].co += direction * epsilon
                    for index in second_vertices:
                        if not is_protected(baseline[index]):
                            bear.data.vertices[index].co -= direction * epsilon
                bear.data.update()
                candidate_pairs, _ = intersection_vertices(bear)
                if candidate_pairs == 0:
                    solved = True
                    for first_vertices, second_vertices, *_ in collisions:
                        for index in first_vertices.union(second_vertices):
                            maximum_move = max(
                                maximum_move,
                                (bear.data.vertices[index].co - original_positions[index]).length,
                            )
                    break
        if not solved:
            for vertex, position in zip(bear.data.vertices, baseline):
                vertex.co = position
            bear.data.update()

    final_pairs, _ = intersection_vertices(bear)
    protected_move = max(
        (
            (vertex.co - original_positions[vertex.index]).length
            for vertex in bear.data.vertices
            if is_protected(original_positions[vertex.index])
        ),
        default=0.0,
    )
    mesh_topology = topology(bear)
    if final_pairs:
        raise RuntimeError(f"Local intersection repair stalled with {final_pairs} pairs; history={history}")
    if protected_move > 1.0e-9:
        raise RuntimeError(f"Local intersection repair moved protected face vertices by {protected_move}")
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Local intersection topology gate failed: {mesh_topology}")
    claws_after = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if claws_after != claws_before:
        raise RuntimeError("Local intersection repair changed claw objects")

    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_photo_backed_critic_gate",
        "method": "intersection-face core smoothing with three feather rings and hard facial protection",
        "initialIntersectionPairs": initial_pairs,
        "finalIntersectionPairs": final_pairs,
        "intersectionHistory": history,
        "bestSmoothedIntersectionPairs": best_pairs,
        "directionalSeparationIterations": separation_iterations,
        "verticesTouched": len(touched),
        "maximumVertexMove": maximum_move,
        "protectedFaceMaximumMove": protected_move,
        "clawsRetained": len(claws_after),
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_LOCAL_INTERSECTION_REPAIR", json.dumps(report))


if __name__ == "__main__":
    main()

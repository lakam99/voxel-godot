import argparse
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy


HEAD_CUT_Y = -1.025
BODY_CUT_Y = -0.55


def parse_args():
    parser = argparse.ArgumentParser(description="Replace the bear's nonlocked Boolean neck band with an explicit manifold bridge.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def boundary_components(edges):
    adjacency = {}
    for edge in edges:
        first, second = edge.verts
        adjacency.setdefault(first, []).append(second)
        adjacency.setdefault(second, []).append(first)
    if any(len(neighbors) != 2 for neighbors in adjacency.values()):
        degrees = sorted({len(neighbors) for neighbors in adjacency.values()})
        branches = [
            {"co": list(vertex.co), "degree": len(neighbors)}
            for vertex, neighbors in adjacency.items()
            if len(neighbors) != 2
        ]
        raise RuntimeError(f"Neck boundary is not loop-like; degrees={degrees}; branches={branches[:24]}")
    components = []
    remaining = set(adjacency)
    while remaining:
        start = min(remaining, key=lambda vertex: (vertex.co.y, vertex.co.x, vertex.co.z))
        loop = [start]
        previous = None
        current = start
        while True:
            neighbors = adjacency[current]
            following = neighbors[0] if neighbors[0] != previous else neighbors[1]
            if following == start:
                break
            if following in loop:
                raise RuntimeError("Neck boundary self-reentered before closure")
            loop.append(following)
            previous, current = current, following
        remaining.difference_update(loop)
        components.append(loop)
    return components


def loop_area(vertices):
    return 0.5 * sum(
        vertices[index].co.x * vertices[(index + 1) % len(vertices)].co.z
        - vertices[(index + 1) % len(vertices)].co.x * vertices[index].co.z
        for index in range(len(vertices))
    )


def align_loop_start(vertices):
    center_x = sum(vertex.co.x for vertex in vertices) / len(vertices)
    center_z = sum(vertex.co.z for vertex in vertices) / len(vertices)
    start = min(
        range(len(vertices)),
        key=lambda index: math.atan2(vertices[index].co.z - center_z, vertices[index].co.x - center_x),
    )
    return vertices[start:] + vertices[:start]


def zipper_bridge(bm, head_loop, body_loop):
    head = align_loop_start(list(head_loop))
    body = list(body_loop)
    if loop_area(head) * loop_area(body) < 0.0:
        body.reverse()
    body = align_loop_start(body)
    head_count = len(head)
    body_count = len(body)
    head_lengths = [(head[(index + 1) % head_count].co - head[index].co).length for index in range(head_count)]
    body_lengths = [(body[(index + 1) % body_count].co - body[index].co).length for index in range(body_count)]
    head_total = sum(head_lengths)
    body_total = sum(body_lengths)
    head_cumulative = [0.0]
    body_cumulative = [0.0]
    for length in head_lengths:
        head_cumulative.append(head_cumulative[-1] + length / head_total)
    for length in body_lengths:
        body_cumulative.append(body_cumulative[-1] + length / body_total)
    head_index = 0
    body_index = 0
    faces = []
    while head_index < head_count or body_index < body_count:
        head_current = head[head_index % head_count]
        body_current = body[body_index % body_count]
        head_progress = head_cumulative[head_index + 1]
        body_progress = body_cumulative[body_index + 1]
        if abs(head_progress - body_progress) < 1.0e-10:
            face = bm.faces.new(
                (
                    head_current,
                    head[(head_index + 1) % head_count],
                    body[(body_index + 1) % body_count],
                    body_current,
                )
            )
            head_index += 1
            body_index += 1
        elif head_progress < body_progress:
            face = bm.faces.new((head_current, head[(head_index + 1) % head_count], body_current))
            head_index += 1
        else:
            face = bm.faces.new((head_current, body[(body_index + 1) % body_count], body_current))
            body_index += 1
        faces.append(face)
    return faces


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
        "nonmanifoldFaceCounts": {
            str(count): sum(1 for edge in bm.edges if len(edge.link_faces) == count)
            for count in sorted({len(edge.link_faces) for edge in bm.edges if len(edge.link_faces) != 2})
        },
        "nonmanifoldSamples": [
            {
                "midpoint": list((edge.verts[0].co + edge.verts[1].co) * 0.5),
                "faceCount": len(edge.link_faces),
            }
            for edge in bm.edges
            if len(edge.link_faces) != 2
        ][:40],
    }
    bm.free()
    return result


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Run from iteration 733")
    locked_before = sorted(
        (vertex.co.copy() for vertex in bear.data.vertices if vertex.co.y < -1.05 and vertex.co.z > 0.95),
        key=lambda value: (value.x, value.y, value.z),
    )
    bm = bmesh.new()
    bm.from_mesh(bear.data)
    candidates = {
        face
        for face in bm.faces
        if HEAD_CUT_Y < face.calc_center_median().y < BODY_CUT_Y
        and face.calc_center_median().z > 1.35
    }
    components = []
    remaining_faces = set(candidates)
    while remaining_faces:
        component = set()
        frontier = [remaining_faces.pop()]
        while frontier:
            face = frontier.pop()
            component.add(face)
            for edge in face.edges:
                for neighbor in edge.link_faces:
                    if neighbor in remaining_faces:
                        remaining_faces.remove(neighbor)
                        frontier.append(neighbor)
        components.append(component)
    removed = list(max(components, key=len))
    bmesh.ops.delete(bm, geom=removed, context="FACES_ONLY")
    bm.verts.ensure_lookup_table()
    bm.edges.ensure_lookup_table()
    bm.faces.ensure_lookup_table()
    boundary_edges = [edge for edge in bm.edges if len(edge.link_faces) == 1]
    patch_fill = bmesh.ops.triangle_fill(bm, edges=boundary_edges, use_beauty=True)
    bridge_faces = [element for element in patch_fill["geom"] if isinstance(element, bmesh.types.BMFace)]
    if not bridge_faces:
        raise RuntimeError("Visible neck patch fill created no faces")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    original_vertices = set(bm.verts)
    patch_faces = set(bridge_faces)
    interior_edges = [
        edge
        for edge in {edge for face in bridge_faces for edge in face.edges}
        if edge.link_faces and all(face in patch_faces for face in edge.link_faces)
    ]
    subdivision = bmesh.ops.subdivide_edges(bm, edges=interior_edges, cuts=2, use_grid_fill=True)
    transition_vertices = [
        element
        for element in subdivision["geom_inner"]
        if isinstance(element, bmesh.types.BMVert) and element not in original_vertices
    ]
    for _ in range(8):
        bmesh.ops.smooth_vert(
            bm,
            verts=transition_vertices,
            factor=0.20,
            use_axis_x=True,
            use_axis_y=True,
            use_axis_z=True,
        )
    loose_edges = [edge for edge in bm.edges if len(edge.link_faces) == 0]
    if loose_edges:
        bmesh.ops.delete(bm, geom=loose_edges, context="EDGES")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(bear.data)
    bm.free()
    for polygon in bear.data.polygons:
        polygon.use_smooth = True
    bear.data.update()
    locked_after = sorted(
        (vertex.co.copy() for vertex in bear.data.vertices if vertex.co.y < -1.05 and vertex.co.z > 0.95),
        key=lambda value: (value.x, value.y, value.z),
    )
    if len(locked_before) != len(locked_after):
        raise RuntimeError(f"Neck retopology changed locked face count: {len(locked_before)} -> {len(locked_after)}")
    locked_displacement = max(((after - before).length for before, after in zip(locked_before, locked_after)), default=0.0)
    if locked_displacement > 1.0e-9:
        raise RuntimeError(f"Neck retopology changed locked face by {locked_displacement}")
    mesh_topology = topology(bear)
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Neck retopology gate failed: {mesh_topology}")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_explicit_neck_retopology_critic_gate",
        "source": "iteration-733-balanced-dorsal-sacral-profile",
        "method": "delete only the visible defective neck surface, beauty-fill its single boundary, densify interior edges, and relax only new patch vertices",
        "cutRangeY": [HEAD_CUT_Y, BODY_CUT_Y],
        "removedVertices": len(removed),
        "boundaryEdgeCount": len(boundary_edges),
        "bridgeFacesBeforeSubdivision": len(bridge_faces),
        "relaxedTransitionVertices": len(transition_vertices),
        "lockedFaceMaximumDisplacement": locked_displacement,
        "clawsRetained": len([obj for obj in bpy.context.scene.objects if "Claw" in obj.name]),
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_EXPLICIT_NECK_RETOPOLOGY", json.dumps(report))


if __name__ == "__main__":
    main()

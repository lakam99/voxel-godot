import argparse
import json
import sys
from pathlib import Path

import bmesh
import bpy


def parse_args():
    parser = argparse.ArgumentParser(description="Correct whole-bear cranial proportion with an occipital-anchored cage warp.")
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


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Run from the passed load-bearing limb authority")
    claws_before = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if len(claws_before) != 20:
        raise RuntimeError(f"Cranial pass requires 20 claws, found {len(claws_before)}")
    protected_before = {
        vertex.index: vertex.co.copy()
        for vertex in bear.data.vertices
        if vertex.co.y >= -0.58
    }
    occipital_y = -0.58
    cranial_center_z = 1.54
    moved_vertices = 0
    maximum_move = 0.0
    for vertex in bear.data.vertices:
        point = vertex.co
        if point.y >= occipital_y:
            continue
        original = point.copy()
        weight = 1.0 - smoothstep(-1.08, occipital_y, point.y)
        point.x *= 1.0 - 0.200 * weight
        point.z = cranial_center_z + (point.z - cranial_center_z) * (1.0 - 0.110 * weight)
        point.y = occipital_y + (point.y - occipital_y) * (1.0 - 0.090 * weight)
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
        raise RuntimeError(f"Cranial pass changed protected anatomy by {protected_displacement}")
    mesh_topology = topology(bear)
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Cranial pass topology gate failed: {mesh_topology}")
    claws_after = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if claws_after != claws_before:
        raise RuntimeError("Cranial pass changed the passed claw set")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_whole_bear_critic_gate",
        "source": "iteration-792-heavy-distal-hind-column",
        "method": "occipital-anchored landmark-coherent cranial cage warp",
        "headWidthReduction": 0.20,
        "cranialDepthReduction": 0.11,
        "muzzleLengthReduction": 0.09,
        "movedVertices": moved_vertices,
        "maximumVertexMove": maximum_move,
        "protectedMaximumDisplacement": protected_displacement,
        "clawsRetained": len(claws_after),
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_CRANIAL_PROPORTION", json.dumps(report))


if __name__ == "__main__":
    main()

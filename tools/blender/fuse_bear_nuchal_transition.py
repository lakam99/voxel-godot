import argparse
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy


SECTIONS = (
    (-1.00, 1.60, 1.54, 0.54, 0.46),
    (-0.86, 1.61, 1.72, 0.61, 0.50),
    (-0.68, 1.62, 1.88, 0.66, 0.55),
    (-0.48, 1.62, 2.02, 0.67, 0.61),
    (-0.25, 1.60, 2.04, 0.62, 0.65),
    (-0.05, 1.57, 1.94, 0.57, 0.64),
)


def parse_args():
    parser = argparse.ArgumentParser(description="Fuse a closed nuchal transition sculpt into the accepted bear surface.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def create_transition():
    radial_count = 64
    vertices = []
    faces = []
    for y_value, center_z, width, top, bottom in SECTIONS:
        for radial in range(radial_count):
            angle = math.tau * radial / radial_count
            sine = math.sin(angle)
            vertical = top if sine >= 0.0 else bottom
            vertices.append((0.5 * width * math.cos(angle), y_value, center_z + vertical * sine))
    for section in range(len(SECTIONS) - 1):
        first = section * radial_count
        following = (section + 1) * radial_count
        for radial in range(radial_count):
            next_radial = (radial + 1) % radial_count
            faces.append((first + radial, following + radial, following + next_radial, first + next_radial))
    faces.append(tuple(range(radial_count)))
    last = (len(SECTIONS) - 1) * radial_count
    faces.append(tuple(reversed(tuple(last + radial for radial in range(radial_count)))))
    mesh = bpy.data.meshes.new("BrownBear_NuchalTransitionMesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    transition = bpy.data.objects.new("BrownBear_NuchalTransition", mesh)
    bpy.context.collection.objects.link(transition)
    for polygon in mesh.polygons:
        polygon.use_smooth = True
    return transition


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
        raise RuntimeError("Run from iteration 733")
    locked_before = sorted(
        (vertex.co.copy() for vertex in bear.data.vertices if vertex.co.y < -1.05 and vertex.co.z > 0.95),
        key=lambda value: (value.x, value.y, value.z),
    )
    transition = create_transition()
    bpy.ops.object.select_all(action="DESELECT")
    transition.select_set(True)
    bpy.context.view_layer.objects.active = transition
    modifier = transition.modifiers.new("NuchalTransitionUnion", "BOOLEAN")
    modifier.operation = "UNION"
    modifier.solver = "EXACT"
    modifier.object = bear
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    bpy.data.objects.remove(bear, do_unlink=True)
    transition.name = "BrownBear_LandmarkSubdivisionCage"
    bear = transition
    for polygon in bear.data.polygons:
        polygon.use_smooth = True
    bear.data.update()
    locked_after = sorted(
        (vertex.co.copy() for vertex in bear.data.vertices if vertex.co.y < -1.05 and vertex.co.z > 0.95),
        key=lambda value: (value.x, value.y, value.z),
    )
    if len(locked_before) != len(locked_after):
        y_values = [vertex.co.y for vertex in bear.data.vertices]
        raise RuntimeError(
            f"Nuchal union changed locked face count: {len(locked_before)} -> {len(locked_after)}; "
            f"vertices={len(bear.data.vertices)} yRange={[min(y_values), max(y_values)]}"
        )
    locked_displacement = max(((after - before).length for before, after in zip(locked_before, locked_after)), default=0.0)
    if locked_displacement > 1.0e-9:
        raise RuntimeError(f"Nuchal union changed locked face by {locked_displacement}")
    mesh_topology = topology(bear)
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Nuchal union topology gate failed: {mesh_topology}")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_nuchal_transition_critic_gate",
        "source": "iteration-733-balanced-dorsal-sacral-profile",
        "method": "closed six-station nuchal sculpt exact-unioned into the unified manifold bear",
        "sections": SECTIONS,
        "lockedFaceMaximumDisplacement": locked_displacement,
        "clawsRetained": len([obj for obj in bpy.context.scene.objects if "Claw" in obj.name]),
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_NUCHAL_TRANSITION", json.dumps(report))


if __name__ == "__main__":
    main()

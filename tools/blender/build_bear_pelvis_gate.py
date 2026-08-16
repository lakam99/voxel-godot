import argparse
import json
import math
import sys
from collections import Counter
from pathlib import Path

import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree


def parse_args():
    parser = argparse.ArgumentParser(description="Build a brown-bear rump and pelvis primary-form gate.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(args)


def sections():
    return (
        ("lumbar_seam", 0.24, 1.35, 0.72, 0.54),
        ("iliac_front", 0.43, 1.39, 0.75, 0.59),
        ("sacral_apex", 0.64, 1.42, 0.70, 0.60),
        ("gluteal_fullness", 0.84, 1.35, 0.71, 0.57),
        ("ischial_falloff", 1.03, 1.34, 0.58, 0.47),
        ("tail_base", 1.17, 1.45, 0.30, 0.26),
        ("tail_seam", 1.27, 1.49, 0.17, 0.14),
    )


def point_for(section, radial, count):
    label, y, center_z, half_width, half_depth = section
    angle = math.tau * radial / count
    lateral = math.cos(angle)
    vertical = math.sin(angle)
    width = half_width
    depth = half_depth
    if label in ("iliac_front", "sacral_apex"):
        width *= 1.0 + 0.10 * max(vertical, 0.0)
        depth *= 1.0 + 0.08 * max(abs(lateral) - 0.35, 0.0)
    elif label == "gluteal_fullness":
        width *= 1.0 + 0.12 * max(-vertical, 0.0)
        depth *= 1.0 + 0.10 * max(abs(lateral), 0.0)
    elif label in ("ischial_falloff", "tail_base"):
        width *= 1.0 - 0.12 * max(vertical, 0.0)
        depth *= 1.0 - 0.16 * max(-vertical, 0.0)
    z = center_z + vertical * depth
    y_offset = 0.045 * max(-vertical, 0.0) * (1.0 - abs(lateral))
    return (lateral * width, y + y_offset, z)


def main():
    args = parse_args()
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    cross_sections = sections()
    count = 16
    vertices = []
    faces = []
    rings = []
    for section in cross_sections:
        ring = []
        for radial in range(count):
            ring.append(len(vertices))
            vertices.append(point_for(section, radial, count))
        if rings:
            previous = rings[-1]
            for radial in range(count):
                following = (radial + 1) % count
                faces.append((previous[radial], previous[following], ring[following], ring[radial]))
        rings.append(ring)
    mesh = bpy.data.meshes.new("BrownBear_PelvisGate_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new("BrownBear_HindquarterGate", mesh)
    bpy.context.scene.collection.objects.link(obj)
    for polygon in mesh.polygons:
        polygon.use_smooth = True
    modifier = obj.modifiers.new(name="ReviewSubdivision", type="SUBSURF")
    modifier.levels = 2
    modifier.render_levels = 2
    edge_counts = Counter(tuple(sorted(edge)) for face in faces for edge in zip(face, face[1:] + face[:1]))
    tree = BVHTree.FromPolygons([Vector(value) for value in vertices], faces, all_triangles=False)
    overlaps = [(a, b) for a, b in tree.overlap(tree) if a < b and not (set(faces[a]) & set(faces[b]))]
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    apex = max(vertex[2] for vertex in vertices)
    widest = max(vertex[0] for vertex in vertices) - min(vertex[0] for vertex in vertices)
    report = {"status": "pending_pelvis_primary_critic_gate", "topology": {"vertices": len(vertices), "faces": len(faces), "quads": sum(len(face) == 4 for face in faces), "boundaryEdges": sum(value == 1 for value in edge_counts.values()), "nonmanifoldEdges": sum(value not in (1, 2) for value in edge_counts.values()), "nonadjacentSelfIntersectionPairs": len(overlaps)}, "anatomy": {"sections": [{"label": label, "y": y, "centerZ": z, "halfWidth": width, "halfDepth": depth} for label, y, z, width, depth in cross_sections], "rumpApexZ": apex, "maximumWidth": widest, "withersAuthorityZ": 2.075, "rumpApexBelowWithers": apex < 2.075}}
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_PELVIS_GATE", json.dumps(report))


if __name__ == "__main__":
    main()

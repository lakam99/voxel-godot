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
    parser = argparse.ArgumentParser(description="Build an isolated brown-bear hindlimb primary-form gate.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(args)


def stations():
    return (
        ("hip", Vector((0.0, 0.78, 1.28)), 0.34, 0.42),
        ("gluteal", Vector((0.0, 0.70, 1.15)), 0.36, 0.39),
        ("femur", Vector((0.0, 0.60, 1.00)), 0.29, 0.32),
        ("stifle", Vector((0.0, 0.383, 0.79)), 0.259, 0.281),
        ("tibia", Vector((0.0, 0.53, 0.59)), 0.209, 0.231),
        ("hock", Vector((0.0, 0.68, 0.35)), 0.140, 0.171),
        ("heel", Vector((0.0, 0.447, 0.1015)), 0.108, 0.105),
        ("paw_root", Vector((0.0, 0.35, 0.067)), 0.112, 0.088),
        ("metatarsal", Vector((0.0, 0.18, 0.057)), 0.116, 0.078),
        ("toe_shelf", Vector((0.0, 0.04, 0.054)), 0.106, 0.068),
        ("toe_tip", Vector((0.0, -0.016, 0.057)), 0.096, 0.050),
    )


def section_frame(path, index):
    if index == 0:
        tangent = path[1][1] - path[0][1]
    elif index == len(path) - 1:
        tangent = path[-1][1] - path[-2][1]
    else:
        tangent = path[index + 1][1] - path[index - 1][1]
    tangent.normalize()
    width_axis = Vector((1.0, 0.0, 0.0))
    depth_axis = tangent.cross(width_axis).normalized()
    return width_axis, depth_axis


def section_point(label, center, width_axis, depth_axis, half_width, half_depth, angle):
    lateral = math.cos(angle)
    depth = math.sin(angle)
    width = half_width
    thickness = half_depth
    offset = Vector()
    if label in ("hip", "gluteal"):
        width *= 1.0 + 0.15 * max(depth, 0.0)
        thickness *= 1.0 + 0.12 * max(lateral, 0.0)
        offset += depth_axis * (0.035 * max(depth, 0.0))
    elif label == "femur":
        width *= 1.0 + 0.08 * max(lateral, 0.0)
        thickness *= 1.0 + 0.10 * max(depth, 0.0)
    elif label == "stifle":
        thickness *= 1.0 + 0.16 * max(-depth, 0.0)
        offset -= depth_axis * (0.020 * max(-depth, 0.0))
    elif label in ("tibia", "hock"):
        thickness *= 1.0 + 0.18 * max(depth, 0.0)
    point = center + width_axis * (lateral * width) + depth_axis * (depth * thickness) + offset
    if label in ("paw_root", "metatarsal", "toe_shelf", "toe_tip"):
        point.z = max(0.035, point.z)
    return point


def cap_fourteen(vertices, faces, ring):
    first = len(vertices)
    vertices.append(tuple(sum((Vector(vertices[ring[index]]) for index in range(7)), start=Vector()) / 7.0))
    second = len(vertices)
    vertices.append(tuple(sum((Vector(vertices[ring[index]]) for index in range(7, 14)), start=Vector()) / 7.0))
    faces.extend(((ring[0], ring[1], ring[2], first), (ring[2], ring[3], ring[4], first), (ring[4], ring[5], ring[6], first), (ring[6], ring[7], second, first), (ring[7], ring[8], ring[9], second), (ring[9], ring[10], ring[11], second), (ring[11], ring[12], ring[13], second), (ring[13], ring[0], first, second)))


def main():
    args = parse_args()
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    path = stations()
    vertices = []
    faces = []
    rings = []
    count = 14
    for station_index, (label, center, half_width, half_depth) in enumerate(path):
        width_axis, depth_axis = section_frame(path, station_index)
        ring = []
        for radial in range(count):
            angle = 2.0 * math.pi * radial / count
            ring.append(len(vertices))
            vertices.append(tuple(section_point(label, center, width_axis, depth_axis, half_width, half_depth, angle)))
        if rings:
            previous = rings[-1]
            for radial in range(count):
                following = (radial + 1) % count
                faces.append((previous[radial], previous[following], ring[following], ring[radial]))
        rings.append(ring)
    cap_fourteen(vertices, faces, rings[-1])
    mesh = bpy.data.meshes.new("BrownBear_HindlimbGate_Mesh")
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
    hock_to_heel = (path[6][1] - path[5][1]).length
    heel_to_tip = (path[-1][1] - path[6][1]).length
    report = {"status": "pending_hindlimb_primary_critic_gate", "topology": {"vertices": len(vertices), "faces": len(faces), "quads": sum(len(face) == 4 for face in faces), "boundaryEdges": sum(value == 1 for value in edge_counts.values()), "nonmanifoldEdges": sum(value not in (1, 2) for value in edge_counts.values()), "nonadjacentSelfIntersectionPairs": len(overlaps), "firstSelfIntersectionPairs": overlaps[:20]}, "anatomy": {"stations": [{"label": label, "center": list(center), "halfWidth": width, "halfDepth": depth} for label, center, width, depth in path], "hockToHeelOverHeelToToe": hock_to_heel / heel_to_tip, "hindPawLength": heel_to_tip, "hindPawWidth": path[8][2] * 2.0}}
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_HINDLIMB_GATE", json.dumps(report))


if __name__ == "__main__":
    main()

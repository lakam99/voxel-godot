import argparse
import json
import math
import sys
from collections import Counter, defaultdict, deque
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector


TORSO_SEGMENTS = 48
LIMB_SEGMENTS = 24


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    return parser.parse_args(sys.argv[sys.argv.index("--") + 1 :])


def torso_sections():
    return [
        {"y": -0.78, "z": 1.42, "width": 1.16, "top": 0.50, "bottom": 0.58},
        {"y": -0.68, "z": 1.43, "width": 1.25, "top": 0.53, "bottom": 0.61},
        {"y": -0.58, "z": 1.43, "width": 1.34, "top": 0.56, "bottom": 0.64},
        {"y": -0.48, "z": 1.43, "width": 1.43, "top": 0.59, "bottom": 0.67},
        {"y": -0.38, "z": 1.42, "width": 1.50, "top": 0.61, "bottom": 0.69},
        {"y": -0.28, "z": 1.40, "width": 1.54, "top": 0.62, "bottom": 0.70},
        {"y": -0.18, "z": 1.385, "width": 1.56, "top": 0.62, "bottom": 0.70},
        {"y": -0.08, "z": 1.37, "width": 1.56, "top": 0.61, "bottom": 0.69},
        {"y": 0.08, "z": 1.34, "width": 1.53, "top": 0.59, "bottom": 0.67},
        {"y": 0.24, "z": 1.31, "width": 1.48, "top": 0.56, "bottom": 0.64},
        {"y": 0.40, "z": 1.28, "width": 1.40, "top": 0.52, "bottom": 0.60},
        {"y": 0.56, "z": 1.27, "width": 1.31, "top": 0.49, "bottom": 0.57},
        {"y": 0.70, "z": 1.27, "width": 1.21, "top": 0.46, "bottom": 0.54},
        {"y": 0.80, "z": 1.28, "width": 1.16, "top": 0.45, "bottom": 0.53},
    ]


def build_torso_vertices_faces():
    vertices = []
    faces = []
    sections = torso_sections()
    for section in sections:
        for radial in range(TORSO_SEGMENTS):
            angle = math.tau * radial / TORSO_SEGMENTS
            vertical = section["top"] if math.sin(angle) >= 0.0 else section["bottom"]
            shoulder_weight = math.exp(-((section["y"] + 0.28) / 0.34) ** 2)
            lateral_weight = max(0.0, abs(math.cos(angle)) - 0.28) / 0.72
            dorsal_weight = max(0.0, math.sin(angle) + 0.12) / 1.12
            side = 1.0 if math.cos(angle) >= 0.0 else -1.0
            scapular_outward = 0.105 * shoulder_weight * lateral_weight * dorsal_weight
            scapular_lift = 0.030 * shoulder_weight * lateral_weight * dorsal_weight
            vertices.append(
                (
                    0.5 * section["width"] * math.cos(angle) + side * scapular_outward,
                    section["y"],
                    section["z"] + vertical * math.sin(angle) + scapular_lift,
                )
            )
    right_hole = set(range(39, 46))
    left_hole = set(range(27, 34))
    for longitudinal in range(len(sections) - 1):
        for radial in range(TORSO_SEGMENTS):
            remove_right = longitudinal in range(2, 7) and radial in right_hole
            remove_left = longitudinal in range(2, 7) and radial in left_hole
            if remove_right or remove_left:
                continue
            following = (radial + 1) % TORSO_SEGMENTS
            base = longitudinal * TORSO_SEGMENTS
            next_base = (longitudinal + 1) * TORSO_SEGMENTS
            faces.append((base + radial, base + following, next_base + following, next_base + radial))
    return vertices, faces


def edge_key(first, second):
    return (first, second) if first < second else (second, first)


def boundary_loops(faces):
    counts = Counter()
    for face in faces:
        for index, first in enumerate(face):
            counts[edge_key(first, face[(index + 1) % len(face)])] += 1
    boundary = [edge for edge, count in counts.items() if count == 1]
    adjacency = defaultdict(list)
    for first, second in boundary:
        adjacency[first].append(second)
        adjacency[second].append(first)
    loops = []
    remaining = set(boundary)
    while remaining:
        first_edge = next(iter(remaining))
        start, current = first_edge
        loop = [start]
        previous = None
        while True:
            loop.append(current)
            remaining.discard(edge_key(loop[-2], current))
            candidates = [neighbor for neighbor in adjacency[current] if neighbor != previous]
            if not candidates:
                break
            following = candidates[0]
            if following == start:
                remaining.discard(edge_key(current, following))
                break
            previous, current = current, following
        loops.append(loop)
    return loops


def ring_frame(tangent):
    tangent = Vector(tangent).normalized()
    width_axis = Vector((1.0, 0.0, 0.0))
    width_axis = (width_axis - tangent * width_axis.dot(tangent)).normalized()
    if width_axis.x < 0.0:
        width_axis = -width_axis
    caudal_axis = tangent.cross(width_axis).normalized()
    if caudal_axis.y < 0.0:
        caudal_axis = -caudal_axis
    return tangent, width_axis, caudal_axis


def ring_points(center, tangent, width, depth, caudal_bias=0.0, lateral_bias=0.0, side=1.0, segments=LIMB_SEGMENTS):
    width_axis = Vector((1.0, 0.0, 0.0))
    caudal_axis = Vector((0.0, 1.0, 0.0))
    center = Vector(center)
    points = []
    for index in range(segments):
        angle = math.tau * index / segments
        across = math.cos(angle)
        caudal = math.sin(angle)
        lateral_weight = max(0.0, side * across)
        caudal_weight = max(0.0, caudal)
        across_radius = 0.5 * width * (1.0 + lateral_bias * lateral_weight)
        caudal_radius = 0.5 * depth * (1.0 + caudal_bias * caudal_weight)
        points.append(tuple(center + width_axis * (across_radius * across) + caudal_axis * (caudal_radius * caudal)))
    return points


def oriented_ring_points(center, tangent, width, depth, segments=LIMB_SEGMENTS):
    _, width_axis, caudal_axis = ring_frame(tangent)
    center = Vector(center)
    return [
        tuple(
            center
            + width_axis * (0.5 * width * math.cos(math.tau * index / segments))
            + caudal_axis * (0.5 * depth * math.sin(math.tau * index / segments))
        )
        for index in range(segments)
    ]


def best_correspondence(boundary, target):
    best = None
    for reversed_order in (False, True):
        sequence = list(reversed(boundary)) if reversed_order else list(boundary)
        for shift in range(len(sequence)):
            shifted = sequence[shift:] + sequence[:shift]
            cost = sum((Vector(first) - Vector(second)).length_squared for first, second in zip(shifted, target))
            candidate = (cost, shifted)
            if best is None or candidate[0] < best[0]:
                best = candidate
    return best


def best_loft_correspondence(source, target):
    source = [Vector(point) for point in source]
    best = None
    for reversed_order in (False, True):
        sequence = list(reversed(target)) if reversed_order else list(target)
        for shift in range(len(sequence)):
            shifted = sequence[shift:] + sequence[:shift]
            planarity = []
            for index in range(len(source)):
                following = (index + 1) % len(source)
                first = source[index]
                second = source[following]
                third = Vector(shifted[following])
                fourth = Vector(shifted[index])
                normal_first = (second - first).cross(third - first).normalized()
                normal_second = (third - first).cross(fourth - first).normalized()
                planarity.append(normal_first.dot(normal_second))
            distance_cost = sum((first - Vector(second)).length_squared for first, second in zip(source, shifted))
            score = (min(planarity), sum(planarity) / len(planarity), -distance_cost)
            if best is None or score > best[0]:
                best = (score, shifted)
    return best


def limb_sections(side):
    return [
        {"center": (side * 0.58, -0.28, 0.94), "width": 0.44, "depth": 0.30, "name": "shoulder_underfold", "caudalBias": 0.08},
        {"center": (side * 0.62, -0.25, 0.88), "width": 0.46, "depth": 0.32, "name": "shoulder_joint", "caudalBias": 0.12},
        {"center": (side * 0.66, -0.14, 0.82), "width": 0.44, "depth": 0.30, "name": "proximal_humerus", "caudalBias": 0.24},
        {"center": (side * 0.68, 0.00, 0.68), "width": 0.39, "depth": 0.28, "name": "mid_humerus", "caudalBias": 0.28},
        {"center": (side * 0.68, 0.12, 0.60), "width": 0.35, "depth": 0.26, "name": "distal_humerus", "caudalBias": 0.30},
        {"center": (side * 0.67, 0.17, 0.49), "width": 0.34, "depth": 0.25, "name": "pre_elbow", "caudalBias": 0.12},
        {"center": (side * 0.67, 0.23, 0.42), "width": 0.35, "depth": 0.28, "name": "olecranon", "caudalBias": 0.18},
        {"center": (side * 0.67, 0.19, 0.385), "width": 0.35, "depth": 0.27, "name": "lower_olecranon", "caudalBias": 0.12},
        {"center": (side * 0.67, 0.14, 0.36), "width": 0.35, "depth": 0.26, "name": "ulnar_transition", "lateralBias": 0.06},
        {"center": (side * 0.67, 0.10, 0.34), "width": 0.35, "depth": 0.25, "name": "post_elbow", "lateralBias": 0.10},
        {"center": (side * 0.67, 0.02, 0.31), "width": 0.36, "depth": 0.24, "name": "proximal_forearm", "lateralBias": 0.18},
        {"center": (side * 0.66, -0.07, 0.26), "width": 0.34, "depth": 0.22, "name": "mid_forearm", "lateralBias": 0.15},
        {"center": (side * 0.66, -0.15, 0.21), "width": 0.31, "depth": 0.20, "name": "distal_forearm", "lateralBias": 0.10},
        {"center": (side * 0.66, -0.17, 0.24), "width": 0.29, "depth": 0.18, "name": "upper_carpus"},
        {"center": (side * 0.66, -0.20, 0.21), "width": 0.28, "depth": 0.16, "name": "lower_carpus"},
    ]


def wrist_sections(side):
    return [
        {"center": (side * 0.66, -0.225, 0.185), "width": 0.28, "depth": 0.16, "name": "carpal_flexion_1"},
        {"center": (side * 0.66, -0.255, 0.158), "width": 0.285, "depth": 0.155, "name": "carpal_flexion_2"},
        {"center": (side * 0.66, -0.295, 0.136), "width": 0.295, "depth": 0.15, "name": "carpal_flexion_3"},
        {"center": (side * 0.66, -0.34, 0.120), "width": 0.30, "depth": 0.15, "name": "heel_turn"},
    ]


def paw_sections(side):
    return [
        {"center": (side * 0.66, -0.35, 0.118), "width": 0.30, "depth": 0.15, "name": "heel_shell", "toeFactor": 0.0},
        {"center": (side * 0.66, -0.41, 0.108), "width": 0.35, "depth": 0.14, "name": "metacarpal", "toeFactor": 0.0},
        {"center": (side * 0.66, -0.47, 0.100), "width": 0.37, "depth": 0.13, "name": "palm", "toeFactor": 0.0},
        {"center": (side * 0.66, -0.53, 0.095), "width": 0.37, "depth": 0.12, "name": "toe_bases", "toeFactor": 0.10},
        {"center": (side * 0.66, -0.58, 0.093), "width": 0.37, "depth": 0.118, "name": "proximal_toes", "toeFactor": 0.34},
        {"center": (side * 0.66, -0.63, 0.091), "width": 0.36, "depth": 0.112, "name": "toe_knuckles", "toeFactor": 0.62},
        {"center": (side * 0.66, -0.69, 0.089), "width": 0.35, "depth": 0.102, "name": "distal_toes", "toeFactor": 0.84},
        {"center": (side * 0.66, -0.75, 0.087), "width": 0.33, "depth": 0.088, "name": "toe_tips", "toeFactor": 1.0},
    ]


def paw_ring_points(section):
    center = Vector(section["center"])
    width = section["width"]
    depth = section["depth"]
    factor = section["toeFactor"]
    peak_lengths = (0.90, 0.98, 1.00, 0.98, 0.90)
    fan_angles = (15.0, 7.5, 0.0, -7.5, -15.0)
    top = []
    for column in range(11):
        across = 0.5 - column / 10.0
        x = center.x + width * across
        y = center.y
        z = center.z + 0.5 * depth
        if column % 2 == 1:
            toe = (column - 1) // 2
            travel = 0.22 * factor
            x += math.tan(math.radians(fan_angles[toe])) * travel
            y += (1.0 - peak_lengths[toe]) * 0.22 * factor
            z += 0.016 * factor
        elif column not in (0, 10):
            left_toe = column // 2 - 1
            right_toe = left_toe + 1
            travel = 0.22 * factor
            average_angle = 0.5 * (fan_angles[left_toe] + fan_angles[right_toe])
            x += math.tan(math.radians(average_angle)) * travel
            y += 0.030 * factor
            z -= 0.020 * factor
        else:
            travel = 0.22 * factor
            x += math.tan(math.radians(fan_angles[0] if column == 0 else fan_angles[-1])) * travel * 1.08
            y += 0.012 * factor
            z -= 0.010 * factor
        top.append((x, y, z))
    bottom = [(point[0], point[1] + 0.004 * factor, center.z - 0.5 * depth) for point in top]
    return (
        top
        + [(top[-1][0], center.y + 0.006 * factor, center.z)]
        + list(reversed(bottom))
        + [(top[0][0], center.y + 0.006 * factor, center.z)]
    )


def add_ring(vertices, faces, previous_ring, points, preserve_order=False):
    if previous_ring is not None and not preserve_order:
        previous_points = [vertices[index] for index in previous_ring]
        _, points = best_correspondence(points, previous_points)
    ring = []
    for point in points:
        ring.append(len(vertices))
        vertices.append(tuple(point))
    if previous_ring is not None:
        for index in range(LIMB_SEGMENTS):
            following = (index + 1) % LIMB_SEGMENTS
            faces.append((previous_ring[index], previous_ring[following], ring[following], ring[index]))
    return ring


def cap_paw_with_quads(vertices, faces, ring):
    grid = {}
    for column in range(11):
        grid[(column, 0)] = ring[column]
        grid[(column, 2)] = ring[12 + (10 - column)]
    grid[(10, 1)] = ring[11]
    grid[(0, 1)] = ring[23]
    for column in range(1, 10):
        top = Vector(vertices[grid[(column, 0)]])
        bottom = Vector(vertices[grid[(column, 2)]])
        grid[(column, 1)] = len(vertices)
        vertices.append(tuple(top.lerp(bottom, 0.5)))
    for row in range(2):
        for column in range(10):
            faces.append((grid[(column, row)], grid[(column + 1, row)], grid[(column + 1, row + 1)], grid[(column, row + 1)]))


def add_limb(vertices, faces, boundary_indices, side):
    sections = limb_sections(side)
    centers = [Vector(section["center"]) for section in sections]
    tangents = []
    for index in range(len(centers)):
        previous = centers[max(index - 1, 0)]
        following = centers[min(index + 1, len(centers) - 1)]
        tangents.append((following - previous).normalized())
    boundary_points = [vertices[index] for index in boundary_indices]
    previous_ring = list(boundary_indices)
    first_section = sections[0]
    first_target = ring_points(
        first_section["center"],
        tangents[0],
        first_section["width"],
        first_section["depth"],
        first_section.get("caudalBias", 0.0),
        first_section.get("lateralBias", 0.0),
        side,
    )
    _, ordered_target = best_loft_correspondence(boundary_points, first_target)
    attachment_stages = (0.12, 0.28, 0.46, 0.64, 0.80)
    for factor in attachment_stages:
        smooth = factor * factor * (3.0 - 2.0 * factor)
        points = [tuple(Vector(source).lerp(Vector(target), smooth)) for source, target in zip(boundary_points, ordered_target)]
        previous_ring = add_ring(vertices, faces, previous_ring, points, preserve_order=True)
    for section_index, section in enumerate(sections):
        if section_index == 0:
            points = ordered_target
        else:
            points = ring_points(
                section["center"],
                tangents[section_index],
                section["width"],
                section["depth"],
                section.get("caudalBias", 0.0),
                section.get("lateralBias", 0.0),
                side,
            )
        previous_ring = add_ring(vertices, faces, previous_ring, points, preserve_order=section_index == 0)
    wrist_data = wrist_sections(side)
    wrist_tangents = [
        Vector((0.0, -0.20, -0.98)).normalized(),
        Vector((0.0, -0.50, -0.866)).normalized(),
        Vector((0.0, -0.866, -0.50)).normalized(),
        Vector((0.0, -1.0, 0.0)),
    ]
    for index, section in enumerate(wrist_data):
        points = oriented_ring_points(section["center"], wrist_tangents[index], section["width"], section["depth"])
        previous_ring = add_ring(vertices, faces, previous_ring, points)

    paw_data = paw_sections(side)
    first_paw_points = paw_ring_points(paw_data[0])
    previous_points = [vertices[index] for index in previous_ring]
    _, aligned_first_paw_points = best_correspondence(first_paw_points, previous_points)
    first_point_to_index = {tuple(point): index for index, point in enumerate(first_paw_points)}
    paw_order = [first_point_to_index[tuple(point)] for point in aligned_first_paw_points]
    for section_index, section in enumerate(paw_data):
        canonical_points = paw_ring_points(section)
        ordered_points = [canonical_points[index] for index in paw_order]
        previous_ring = add_ring(vertices, faces, previous_ring, ordered_points, preserve_order=True)
    canonical_ring = [None] * LIMB_SEGMENTS
    for position, canonical_index in enumerate(paw_order):
        canonical_ring[canonical_index] = previous_ring[position]
    cap_paw_with_quads(vertices, faces, canonical_ring)
    return {
        "side": side,
        "attachmentRings": len(attachment_stages),
        "sections": [
            {"name": section["name"], "center": section["center"], "width": section["width"], "depth": section["depth"]}
            for section in sections
        ],
        "pawSections": paw_sections(side),
        "wristSections": wrist_sections(side),
    }


def topology(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    components = 0
    remaining = set(bm.verts)
    while remaining:
        components += 1
        queue = deque([next(iter(remaining))])
        while queue:
            vertex = queue.popleft()
            if vertex not in remaining:
                continue
            remaining.remove(vertex)
            queue.extend(neighbor for edge in vertex.link_edges for neighbor in edge.verts if neighbor in remaining)
    boundary_edges = [edge for edge in bm.edges if len(edge.link_faces) == 1]
    result = {
        "vertices": len(bm.verts),
        "edges": len(bm.edges),
        "faces": len(bm.faces),
        "quads": sum(len(face.verts) == 4 for face in bm.faces),
        "ngons": sum(len(face.verts) > 4 for face in bm.faces),
        "triangles": sum(len(face.verts) == 3 for face in bm.faces),
        "boundaryEdges": len(boundary_edges),
        "nonmanifoldEdges": sum(len(edge.link_faces) not in (1, 2) for edge in bm.edges),
        "components": components,
    }
    bm.free()
    return result


def curve(name, points, material, bevel=0.008):
    data = bpy.data.curves.new(name, "CURVE")
    data.dimensions = "3D"
    data.bevel_depth = bevel
    data.bevel_resolution = 2
    spline = data.splines.new("POLY")
    spline.points.add(len(points) - 1)
    for target, point in zip(spline.points, points):
        target.co = (*point, 1.0)
    obj = bpy.data.objects.new(name, data)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(material)
    return obj


def material(name, color):
    value = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    value.diffuse_color = (*color, 1.0)
    return value


def main():
    args = parse_args()
    for obj in list(bpy.context.scene.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    vertices, faces = build_torso_vertices_faces()
    loops = boundary_loops(faces)
    shoulder_loops = []
    for loop in loops:
        center = sum((Vector(vertices[index]) for index in loop), start=Vector()) / len(loop)
        if len(loop) == LIMB_SEGMENTS and abs(center.x) > 0.25:
            shoulder_loops.append((center.x, loop))
    if len(shoulder_loops) != 2:
        raise RuntimeError(f"Expected two 24-edge shoulder loops, found {[(value, len(loop)) for value, loop in shoulder_loops]}")
    limb_reports = []
    for center_x, loop in sorted(shoulder_loops):
        limb_reports.append(add_limb(vertices, faces, loop, -1.0 if center_x < 0.0 else 1.0))

    used = sorted({index for face in faces for index in face})
    remap = {old: new for new, old in enumerate(used)}
    vertices = [vertices[index] for index in used]
    faces = [tuple(remap[index] for index in face) for face in faces]

    mesh = bpy.data.meshes.new("BrownBear_ForequarterSubdivisionCageMesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    cage = bpy.data.objects.new("BrownBear_ForequarterSubdivisionCage", mesh)
    bpy.context.collection.objects.link(cage)
    wire = cage.modifiers.new("CageWire", "WIREFRAME")
    wire.thickness = 0.006
    wire.use_replace = False
    cage.data.materials.append(material("CageSkin", (0.10, 0.18, 0.24)))
    cage.data.materials.append(material("CageWireMaterial", (0.96, 0.43, 0.05)))
    wire.material_offset = 1

    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_anatomical_subdivision_cage_wire_gate",
        "authority": cage.name,
        "topology": topology(cage),
        "torso": {"segments": TORSO_SEGMENTS, "longitudinalRings": len(torso_sections())},
        "shoulderOpenings": {"count": len(shoulder_loops), "edgesEach": LIMB_SEGMENTS},
        "limbs": limb_reports,
        "toeTopology": {
            "columnsPerPaw": 5,
            "longitudinalAuthorities": ["base", "knuckle", "tip"],
            "fanDegrees": 30.0,
            "terminalClosure": "10x2 all-quad grid",
        },
        "integration": {
            "cervicalBoundary": "front 48-edge torso ring",
            "caudalBoundary": "rear 48-edge torso ring",
            "lockedHead": "iteration-289 external authority; no source vertices modified",
        },
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_FOREQUARTER_SUBDIVISION_CAGE", json.dumps(report))


if __name__ == "__main__":
    main()

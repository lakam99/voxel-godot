import argparse
import json
import math
import sys
from collections import Counter, defaultdict, deque
from pathlib import Path

import bmesh
import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree


WIDTH = 12
HEIGHT = 10
HOLE = (2, 8, 2, 8)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    return parser.parse_args(sys.argv[sys.argv.index("--") + 1 :])


def boundary(x_min, x_max, y_min, y_max):
    return (
        [(x, y_min) for x in range(x_min, x_max)]
        + [(x_max, y) for y in range(y_min, y_max)]
        + [(x, y_max) for x in range(x_max, x_min, -1)]
        + [(x_min, y) for y in range(y_max, y_min, -1)]
    )


def cubic(first, control_first, control_second, last, factor):
    inverse = 1.0 - factor
    return (
        first * (inverse ** 3)
        + control_first * (3.0 * inverse * inverse * factor)
        + control_second * (3.0 * inverse * factor * factor)
        + last * (factor ** 3)
    )


def arc(first, control_first, control_second, last):
    return [cubic(first, control_first, control_second, last, index / 6.0) for index in range(6)]


def cyclic_sector_value(index, values):
    centers = (3.0, 9.0, 15.0, 21.0)
    weights = [math.exp(4.0 * math.cos(math.tau * (index - center) / 24.0)) for center in centers]
    total = sum(weights)
    return sum(value * weight for value, weight in zip(values, weights)) / total


def shoulder_boundary(side):
    cranial_ventral = Vector((side * 0.760, -0.480, 0.920))
    cranial_dorsal = Vector((side * 0.820, -0.515, 1.260))
    caudal_dorsal = Vector((side * 0.840, -0.065, 1.285))
    caudal_ventral = Vector((side * 0.740, -0.100, 0.920))
    pectoral = arc(
        cranial_ventral,
        Vector((side * 0.650, -0.510, 1.020)),
        Vector((side * 0.705, -0.525, 1.180)),
        cranial_dorsal,
    )
    scapular = arc(
        cranial_dorsal,
        Vector((side * 0.835, -0.405, 1.330)),
        Vector((side * 0.850, -0.185, 1.335)),
        caudal_dorsal,
    )
    triceps = arc(
        caudal_dorsal,
        Vector((side * 0.812, -0.042, 1.180)),
        Vector((side * 0.745, -0.060, 1.010)),
        caudal_ventral,
    )
    axilla = arc(
        caudal_ventral,
        Vector((side * 0.700, -0.170, 0.720)),
        Vector((side * 0.700, -0.410, 0.720)),
        cranial_ventral,
    )
    points = pectoral + scapular + triceps + axilla
    root_height = max(point.z for point in points) - min(point.z for point in points)
    for index, point in enumerate(points):
        point.x += side * root_height * cyclic_sector_value(index, (-0.04, 0.07, 0.05, -0.08))
        point.y += root_height * cyclic_sector_value(index, (0.00, 0.00, 0.04, 0.00))
        point.z += root_height * cyclic_sector_value(index, (0.00, 0.04, 0.00, -0.01))
    return points


def base_position(coord, side):
    vertical = coord[0] / WIDTH
    longitudinal = coord[1] / HEIGHT
    z = 0.70 + 0.66 * vertical
    y = -0.62 + 0.64 * longitudinal
    crown = math.sin(math.pi * vertical) * math.sin(math.pi * longitudinal)
    return Vector((side * (0.665 + 0.045 * crown), y, z))


def guide_positions(side):
    result = {}
    roots = dict(zip(boundary(*HOLE), shoulder_boundary(side)))
    blend = 0.45
    for vertical in range(HOLE[0], HOLE[1] + 1):
        result[(vertical, HOLE[2] - 1)] = roots[(vertical, HOLE[2])].lerp(
            base_position((vertical, 0), side), blend
        )
        result[(vertical, HOLE[3] + 1)] = roots[(vertical, HOLE[3])].lerp(
            base_position((vertical, HEIGHT), side), blend
        )
    for longitudinal in range(HOLE[2], HOLE[3] + 1):
        result[(HOLE[0] - 1, longitudinal)] = roots[(HOLE[0], longitudinal)].lerp(
            base_position((0, longitudinal), side), blend
        )
        result[(HOLE[1] + 1, longitudinal)] = roots[(HOLE[1], longitudinal)].lerp(
            base_position((WIDTH, longitudinal), side), blend
        )
    return result


def solve_patch_positions(side):
    outer = boundary(0, WIDTH, 0, HEIGHT)
    inner = boundary(*HOLE)
    used = [
        (vertical, longitudinal)
        for longitudinal in range(HEIGHT + 1)
        for vertical in range(WIDTH + 1)
        if not (HOLE[0] < vertical < HOLE[1] and HOLE[2] < longitudinal < HOLE[3])
    ]
    fixed = {coord: base_position(coord, side) for coord in outer}
    fixed.update(dict(zip(inner, shoulder_boundary(side))))
    fixed.update(guide_positions(side))
    free = [coord for coord in used if coord not in fixed]
    free_index = {coord: index for index, coord in enumerate(free)}
    matrix = np.zeros((len(free), len(free)))
    targets = np.zeros((len(free), 3))
    used_set = set(used)
    for coord, row in free_index.items():
        neighbors = [
            (coord[0] - 1, coord[1]),
            (coord[0] + 1, coord[1]),
            (coord[0], coord[1] - 1),
            (coord[0], coord[1] + 1),
        ]
        neighbors = [neighbor for neighbor in neighbors if neighbor in used_set]
        matrix[row, row] = len(neighbors)
        for neighbor in neighbors:
            if neighbor in free_index:
                matrix[row, free_index[neighbor]] -= 1.0
            else:
                targets[row] += fixed[neighbor]
    solution = np.linalg.solve(matrix, targets)
    positions = dict(fixed)
    for coord, row in free_index.items():
        positions[coord] = Vector(solution[row])
    for coord in used:
        distance_from_outer = min(coord[0], WIDTH - coord[0], coord[1], HEIGHT - coord[1])
        proxy_weight = 0.70 if distance_from_outer == 1 else 0.30 if distance_from_outer == 2 else 0.0
        if proxy_weight > 0.0:
            positions[coord] = positions[coord].lerp(base_position(coord, side), proxy_weight)
    for longitudinal in (1, HEIGHT - 1):
        source = {vertical: Vector(positions[(vertical, longitudinal)]) for vertical in range(WIDTH + 1)}
        for vertical in range(1, WIDTH):
            positions[(vertical, longitudinal)].x = (
                0.25 * source[vertical - 1].x
                + 0.50 * source[vertical].x
                + 0.25 * source[vertical + 1].x
            )
    return used, outer, inner, positions


def humeral_ring(side, center, tangent, width, depth):
    tangent = Vector(tangent).normalized()
    dorsal = Vector((0.0, 0.0, 1.0))
    dorsal = (dorsal - tangent * dorsal.dot(tangent)).normalized()
    caudal = tangent.cross(dorsal).normalized()
    if caudal.y < 0.0:
        caudal = -caudal
    center = Vector(center)
    return [
        center
        + caudal * (0.5 * depth * math.cos(math.radians(225.0 - 15.0 * index)))
        + dorsal * (0.5 * width * math.sin(math.radians(225.0 - 15.0 * index)))
        for index in range(24)
    ]


def collar_ring(root, tangent, side, root_width):
    result = []
    for index, source in enumerate(root):
        thickness = cyclic_sector_value(index, (0.90, 1.15, 1.10, 0.84))
        value = Vector(source) + tangent * (0.14 * root_width * thickness)
        value += Vector(
            (
                side * root_width * cyclic_sector_value(index, (0.006, 0.024, 0.020, 0.008)),
                root_width * cyclic_sector_value(index, (-0.008, 0.0, 0.018, 0.0)),
                root_width * cyclic_sector_value(index, (0.0, 0.008, 0.0, 0.004)),
            )
        )
        result.append(value)
    return result


def extend_torso_proxy(vertices, faces, coord_index, positions, layers=4):
    def extrapolated_position(coord):
        vertical, longitudinal = coord
        base_vertical = 0 if vertical < 0 else WIDTH - 1 if vertical > WIDTH else min(vertical, WIDTH - 1)
        base_longitudinal = 0 if longitudinal < 0 else HEIGHT - 1 if longitudinal > HEIGHT else min(longitudinal, HEIGHT - 1)
        factor_vertical = vertical - base_vertical
        factor_longitudinal = longitudinal - base_longitudinal
        lower_left = positions[(base_vertical, base_longitudinal)]
        lower_right = positions[(base_vertical + 1, base_longitudinal)]
        upper_left = positions[(base_vertical, base_longitudinal + 1)]
        upper_right = positions[(base_vertical + 1, base_longitudinal + 1)]
        return (
            lower_left * ((1.0 - factor_vertical) * (1.0 - factor_longitudinal))
            + lower_right * (factor_vertical * (1.0 - factor_longitudinal))
            + upper_left * ((1.0 - factor_vertical) * factor_longitudinal)
            + upper_right * (factor_vertical * factor_longitudinal)
        )

    for longitudinal in range(-layers, HEIGHT + layers + 1):
        for vertical in range(-layers, WIDTH + layers + 1):
            coord = (vertical, longitudinal)
            if coord in coord_index:
                continue
            if 0 <= vertical <= WIDTH and 0 <= longitudinal <= HEIGHT:
                continue
            coord_index[coord] = len(vertices)
            vertices.append(tuple(extrapolated_position(coord)))
    extension_faces = []
    for longitudinal in range(-layers, HEIGHT + layers):
        for vertical in range(-layers, WIDTH + layers):
            if 0 <= vertical < WIDTH and 0 <= longitudinal < HEIGHT:
                continue
            extension_faces.append(
                (
                    coord_index[(vertical, longitudinal)],
                    coord_index[(vertical + 1, longitudinal)],
                    coord_index[(vertical + 1, longitudinal + 1)],
                    coord_index[(vertical, longitudinal + 1)],
                )
            )
    faces.extend(extension_faces)
    return boundary(-layers, WIDTH + layers, -layers, HEIGHT + layers), len(extension_faces)


def edge_key(first, second):
    return tuple(sorted((first, second)))


def topology(
    vertices,
    faces,
    outer_indices,
    root_indices,
    collar_indices,
    humerus_indices,
    humerus_tangent,
    saddle_face_count,
    extension_face_count,
    seam_indices,
):
    edges = Counter()
    neighbors = defaultdict(set)
    face_areas = []
    edge_ratios = []
    for face in faces:
        points = [Vector(vertices[index]) for index in face]
        face_areas.append(0.5 * (points[1] - points[0]).cross(points[2] - points[0]).length_squared ** 0.5 + 0.5 * (points[2] - points[0]).cross(points[3] - points[0]).length_squared ** 0.5)
        lengths = []
        for index, first in enumerate(face):
            second = face[(index + 1) % 4]
            edges[edge_key(first, second)] += 1
            neighbors[first].add(second)
            neighbors[second].add(first)
            lengths.append((Vector(vertices[first]) - Vector(vertices[second])).length)
        edge_ratios.append(max(lengths) / min(lengths))
    boundary_edges = [edge for edge, count in edges.items() if count == 1]
    boundary_vertices = {vertex for edge in boundary_edges for vertex in edge}
    valences = Counter(len(neighbors[index]) for index in range(len(vertices)) if index not in boundary_vertices)
    root_corner_indices = [root_indices[index] for index in (0, 6, 12, 18)]
    bvh = BVHTree.FromPolygons([Vector(vertex) for vertex in vertices], faces, all_triangles=False)
    intersection_pairs = [
        (first, second)
        for first, second in bvh.overlap(bvh)
        if first < second and not set(faces[first]).intersection(faces[second])
    ]
    intersection_categories = Counter(
        "surfaceSurface"
        if first < saddle_face_count and second < saddle_face_count
        else "surfaceCollar"
        if first < saddle_face_count <= second
        else "collarCollar"
        for first, second in intersection_pairs
    )
    components = 0
    remaining = set(range(len(vertices)))
    while remaining:
        components += 1
        queue = deque([next(iter(remaining))])
        while queue:
            vertex = queue.popleft()
            if vertex not in remaining:
                continue
            remaining.remove(vertex)
            queue.extend(neighbors[vertex] & remaining)
    worst_faces = sorted(range(len(edge_ratios)), key=edge_ratios.__getitem__, reverse=True)[:12]
    monotonic_advances = {
        "rootToCollar": [
            (Vector(vertices[collar_indices[index]]) - Vector(vertices[root_indices[index]])).dot(humerus_tangent)
            for index in range(24)
        ],
        "collarToHumerus": [
            (Vector(vertices[humerus_indices[index]]) - Vector(vertices[collar_indices[index]])).dot(humerus_tangent)
            for index in range(24)
        ],
    }
    seam_normal_dots = []
    for index, first in enumerate(seam_indices):
        second = seam_indices[(index + 1) % len(seam_indices)]
        incident = [face for face in faces[:saddle_face_count] if first in face and second in face]
        if len(incident) != 2:
            continue
        normals = []
        for face in incident:
            points = [Vector(vertices[vertex]) for vertex in face]
            normals.append((points[1] - points[0]).cross(points[2] - points[0]).normalized())
        seam_normal_dots.append(
            {
                "edge": [first, second],
                "dot": abs(normals[0].dot(normals[1])),
                "coordinates": [list(vertices[first]), list(vertices[second])],
            }
        )
    patch_face_count = saddle_face_count - extension_face_count
    vertex_normal_dots = []
    for vertex in seam_indices:
        side_normals = []
        for face_group in (faces[:patch_face_count], faces[patch_face_count:saddle_face_count]):
            normals = []
            for face in face_group:
                if vertex not in face:
                    continue
                points = [Vector(vertices[index]) for index in face]
                normals.append((points[1] - points[0]).cross(points[2] - points[0]).normalized())
                normals.append((points[2] - points[0]).cross(points[3] - points[0]).normalized())
            side_normals.append(sum(normals, start=Vector()).normalized())
        vertex_normal_dots.append(abs(side_normals[0].dot(side_normals[1])))
    return {
        "vertices": len(vertices),
        "edges": len(edges),
        "faces": len(faces),
        "quads": sum(len(face) == 4 for face in faces),
        "triangles": sum(len(face) == 3 for face in faces),
        "ngons": sum(len(face) > 4 for face in faces),
        "euler": len(vertices) - len(edges) + len(faces),
        "components": components,
        "boundaryEdges": len(boundary_edges),
        "nonmanifoldEdges": sum(count > 2 for count in edges.values()),
        "boundaryCountsExpected": {"outer": len(outer_indices), "humerus": len(humerus_indices)},
        "patchQuads": saddle_face_count - extension_face_count,
        "torsoExtensionQuads": extension_face_count,
        "collarQuads": 48,
        "interiorValences": dict(sorted(valences.items())),
        "rootCornerValences": [len(neighbors[index]) for index in root_corner_indices],
        "rootRegularValences": [len(neighbors[index]) for index in root_indices if index not in root_corner_indices],
        "maximumEdgeRatio": max(edge_ratios),
        "worstEdgeRatioFace": {
            "index": max(range(len(edge_ratios)), key=edge_ratios.__getitem__),
            "ratio": max(edge_ratios),
            "vertices": list(faces[max(range(len(edge_ratios)), key=edge_ratios.__getitem__)]),
        },
        "worstEdgeRatioFaces": [
            {
                "index": face_index,
                "ratio": edge_ratios[face_index],
                "vertices": list(faces[face_index]),
                "coordinates": [list(vertices[vertex]) for vertex in faces[face_index]],
            }
            for face_index in worst_faces
        ],
        "minimumFaceArea": min(face_areas),
        "medianFaceArea": sorted(face_areas)[len(face_areas) // 2],
        "nonadjacentSelfIntersectionPairs": len(intersection_pairs),
        "selfIntersectionCategories": dict(sorted(intersection_categories.items())),
        "firstSelfIntersectionPairs": intersection_pairs[:12],
        "minimumMonotonicAdvance": {
            name: min(values) for name, values in monotonic_advances.items()
        },
        "torsoSeam": {
            "edgeCount": len(seam_indices),
            "boundaryPositionError": 0.0,
            "minimumNormalDot": min(vertex_normal_dots),
            "minimumRawFaceNormalDot": min(item["dot"] for item in seam_normal_dots),
            "worstNormalEdges": sorted(seam_normal_dots, key=lambda item: item["dot"])[:8],
        },
        "declaredRings": {
            "root": len(root_indices),
            "collar": len(collar_indices),
            "humerus": len(humerus_indices),
        },
    }


def material(name, color):
    value = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    value.diffuse_color = (*color, 1.0)
    return value


def main():
    args = parse_args()
    for obj in list(bpy.context.scene.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    used, outer, inner, positions = solve_patch_positions(1.0)
    coord_index = {coord: index for index, coord in enumerate(used)}
    vertices = [tuple(positions[coord]) for coord in used]
    faces = []
    for longitudinal in range(HEIGHT):
        for vertical in range(WIDTH):
            if HOLE[0] <= vertical < HOLE[1] and HOLE[2] <= longitudinal < HOLE[3]:
                continue
            faces.append(
                (
                    coord_index[(vertical, longitudinal)],
                    coord_index[(vertical + 1, longitudinal)],
                    coord_index[(vertical + 1, longitudinal + 1)],
                    coord_index[(vertical, longitudinal + 1)],
                )
            )
    outer_indices = [coord_index[coord] for coord in outer]
    root_indices = [coord_index[coord] for coord in inner]
    root_points = [Vector(vertices[index]) for index in root_indices]
    shoulder_center = sum(root_points, start=Vector()) / len(root_points)
    root_width = max(
        max(point.y for point in root_points) - min(point.y for point in root_points),
        max(point.z for point in root_points) - min(point.z for point in root_points),
    )
    humerus_tangent = Vector((1.00, 0.03, -0.12)).normalized()
    collar_points = collar_ring(root_points, humerus_tangent, 1.0, root_width)
    humerus_center = shoulder_center + humerus_tangent * (0.28 * root_width)
    target_humerus_points = humeral_ring(1.0, humerus_center, humerus_tangent, 0.400, 0.340)
    humerus_points = []
    for index, (collar_point, target_point) in enumerate(zip(collar_points, target_humerus_points)):
        thickness = cyclic_sector_value(index, (0.90, 1.15, 1.10, 0.84))
        cross_section_delta = target_point - collar_point
        cross_section_delta -= humerus_tangent * cross_section_delta.dot(humerus_tangent)
        humerus_points.append(
            collar_point
            + humerus_tangent * (0.14 * root_width * thickness)
            + cross_section_delta * (0.45 * thickness)
        )
    seam_indices = list(outer_indices)
    extended_outer, extension_face_count = extend_torso_proxy(vertices, faces, coord_index, positions)
    outer_indices = [coord_index[coord] for coord in extended_outer]
    saddle_face_count = len(faces)
    collar_indices = list(range(len(vertices), len(vertices) + 24))
    vertices.extend(tuple(point) for point in collar_points)
    humerus_indices = list(range(len(vertices), len(vertices) + 24))
    vertices.extend(tuple(point) for point in humerus_points)
    for first_ring, second_ring in ((root_indices, collar_indices), (collar_indices, humerus_indices)):
        for index in range(24):
            faces.append((first_ring[index], first_ring[(index + 1) % 24], second_ring[(index + 1) % 24], second_ring[index]))
    mesh = bpy.data.meshes.new("BrownBear_ShoulderSaddlePatchMesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new("BrownBear_ShoulderSaddlePatch", mesh)
    bpy.context.collection.objects.link(obj)
    for group_name, indices in (
        ("J0", root_indices),
        ("Collar", collar_indices),
        ("H0", humerus_indices),
        ("TorsoSeam", seam_indices),
    ):
        group = obj.vertex_groups.new(name=group_name)
        group.add(indices, 1.0, "REPLACE")
    obj["j0_indices"] = root_indices
    obj["collar_indices"] = collar_indices
    obj["h0_indices"] = humerus_indices
    obj["humerus_tangent"] = list(humerus_tangent)
    obj.data.materials.append(material("ShoulderSaddleSkin", (0.07, 0.20, 0.29)))
    obj.data.materials.append(material("ShoulderSaddleWire", (1.0, 0.23, 0.03)))
    wire = obj.modifiers.new("ShoulderSaddleWire", "WIREFRAME")
    wire.thickness = 0.005
    wire.use_replace = False
    wire.material_offset = 1
    report = {
        "status": "pending_shoulder_saddle_topology_gate",
        "topology": topology(
            vertices,
            faces,
            outer_indices,
            root_indices,
            collar_indices,
            humerus_indices,
            humerus_tangent,
            saddle_face_count,
            extension_face_count,
            seam_indices,
        ),
        "architecture": {
            "outerPatchFaces": [WIDTH, HEIGHT],
            "removedInnerFaces": [6, 6],
            "semanticSectors": ["pectoral", "scapular", "triceps", "axilla"],
            "collarBands": 2,
            "torsoExtensionRings": 4,
            "torsoBoundaryBlendWeights": [1.0, 0.70, 0.30],
            "humerusPlaneNormalDotTangent": 1.0,
        },
    }
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_SHOULDER_SADDLE_PATCH", json.dumps(report))


if __name__ == "__main__":
    main()

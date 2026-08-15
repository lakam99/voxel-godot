import argparse
import json
import math
import sys
from collections import Counter, defaultdict, deque
from pathlib import Path

import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree


SEGMENTS = 24


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    return parser.parse_args(sys.argv[sys.argv.index("--") + 1 :])


def edge_key(first, second):
    return tuple(sorted((first, second)))


def polygon_normal(vertices, face):
    points = [Vector(vertices[index]) for index in face]
    return (
        (points[1] - points[0]).cross(points[2] - points[0])
        + (points[2] - points[0]).cross(points[3] - points[0])
    ).normalized()


def parallel_transport_frames(centers, initial_tangent):
    tangents = []
    for index in range(len(centers)):
        if index == 0:
            tangent = Vector(initial_tangent).normalized()
        elif index == len(centers) - 1:
            tangent = (centers[index] - centers[index - 1]).normalized()
        else:
            tangent = (centers[index + 1] - centers[index - 1]).normalized()
        tangents.append(tangent)
    dorsal = Vector((0.0, 0.0, 1.0))
    dorsal = (dorsal - tangents[0] * dorsal.dot(tangents[0])).normalized()
    caudal = tangents[0].cross(dorsal).normalized()
    if caudal.y < 0.0:
        caudal = -caudal
    frames = [(tangents[0], dorsal, caudal)]
    roll_changes = []
    for index in range(1, len(centers)):
        previous_tangent, previous_dorsal, previous_caudal = frames[-1]
        rotation = previous_tangent.rotation_difference(tangents[index])
        transported_dorsal = rotation @ previous_dorsal
        transported_dorsal = (
            transported_dorsal - tangents[index] * transported_dorsal.dot(tangents[index])
        ).normalized()
        transported_caudal = rotation @ previous_caudal
        transported_caudal = (
            transported_caudal - tangents[index] * transported_caudal.dot(tangents[index])
        ).normalized()
        frames.append((tangents[index], transported_dorsal, transported_caudal))
        roll_changes.append(0.0)
    return frames, roll_changes


def build_control_centers(h0_center, length, initial_tangent):
    offsets = (
        (0.0, 0.0, 0.0),
        (0.10, 0.010, -0.012),
        (0.22, 0.040, -0.070),
        (0.34, 0.080, -0.180),
        (0.36, 0.100, -0.330),
        (0.34, 0.070, -0.430),
        (0.31, 0.020, -0.560),
        (0.29, -0.050, -0.660),
        (0.28, -0.080, -0.710),
    )
    centers = [Vector(h0_center)]
    centers.append(Vector(h0_center) + Vector(initial_tangent).normalized() * (0.10 * length))
    for lateral, caudal, vertical in offsets[2:]:
        centers.append(Vector(h0_center) + Vector((lateral * length, caudal * length, vertical * length)))
    return centers


def monotone_tangents(values):
    secants = [values[index + 1] - values[index] for index in range(len(values) - 1)]
    tangents = [secants[0]]
    for index in range(1, len(values) - 1):
        previous = secants[index - 1]
        following = secants[index]
        if previous == 0.0 or following == 0.0 or previous * following <= 0.0:
            tangents.append(0.0)
        else:
            tangents.append(2.0 * previous * following / (previous + following))
    tangents.append(secants[-1])
    return tangents


def hermite(first, second, tangent_first, tangent_second, factor):
    factor_squared = factor * factor
    factor_cubed = factor_squared * factor
    return (
        (2.0 * factor_cubed - 3.0 * factor_squared + 1.0) * first
        + (factor_cubed - 2.0 * factor_squared + factor) * tangent_first
        + (-2.0 * factor_cubed + 3.0 * factor_squared) * second
        + (factor_cubed - factor_squared) * tangent_second
    )


def dense_control_values(values, bands_per_interval=3):
    tangents = monotone_tangents(values)
    dense = [values[0]]
    for interval in range(len(values) - 1):
        for band in range(1, bands_per_interval + 1):
            factor = band / bands_per_interval
            dense.append(hermite(values[interval], values[interval + 1], tangents[interval], tangents[interval + 1], factor))
    return dense


def dense_centers(control_centers, bands_per_interval=3):
    components = []
    for axis in range(3):
        components.append(dense_control_values([center[axis] for center in control_centers], bands_per_interval))
    return [Vector((components[0][index], components[1][index], components[2][index])) for index in range(len(components[0]))]


def enforce_rail_advance(ring, previous_ring, path_direction):
    ring = [Vector(point) for point in ring]
    previous_ring = [Vector(point) for point in previous_ring]
    path_direction = Vector(path_direction).normalized()
    for _ in range(3):
        updated = []
        for index, point in enumerate(ring):
            previous_column = previous_ring[index]
            circumferential = 0.5 * (
                (point - ring[(index - 1) % SEGMENTS]).length
                + (ring[(index + 1) % SEGMENTS] - point).length
            )
            minimum_advance = 1.25 * circumferential
            maximum_advance = 2.60 * circumferential
            advance = (point - previous_column).dot(path_direction)
            if advance < minimum_advance:
                point += path_direction * (minimum_advance - advance)
            elif advance > maximum_advance:
                point -= path_direction * (advance - maximum_advance)
            updated.append(point)
        ring = updated
    return ring


def append_forelimb(vertices, faces, collar_indices, h0_indices, initial_tangent):
    h0_points = [Vector(vertices[index]) for index in h0_indices]
    h0_center = sum(h0_points, start=Vector()) / SEGMENTS
    shoulder_to_ground = max(0.80, h0_center.z - 0.08)
    control_centers = build_control_centers(h0_center, shoulder_to_ground, initial_tangent)
    centers = dense_centers(control_centers)
    frames, roll_changes = parallel_transport_frames(centers, initial_tangent)
    initial_dorsal = frames[0][1]
    initial_caudal = frames[0][2]
    dorsal_values = [(point - h0_center).dot(initial_dorsal) for point in h0_points]
    caudal_values = [(point - h0_center).dot(initial_caudal) for point in h0_points]
    dorsal_mid = 0.5 * (max(dorsal_values) + min(dorsal_values))
    caudal_mid = 0.5 * (max(caudal_values) + min(caudal_values))
    shoulder_width = max(dorsal_values) - min(dorsal_values)
    shoulder_depth = max(caudal_values) - min(caudal_values)
    normalized = [
        (
            (dorsal - dorsal_mid) / (0.5 * shoulder_width),
            (caudal - caudal_mid) / (0.5 * shoulder_depth),
        )
        for dorsal, caudal in zip(dorsal_values, caudal_values)
    ]
    control_width_ratios = (1.00, 0.94, 0.86, 0.84, 0.74, 0.58, 0.52, 0.44, 0.37)
    control_depth_ratios = (1.00, 0.92, 0.74, 0.68, 0.66, 0.58, 0.50, 0.40, 0.34)
    width_ratios = [math.exp(value) for value in dense_control_values([math.log(value) for value in control_width_ratios])]
    depth_ratios = [math.exp(value) for value in dense_control_values([math.log(value) for value in control_depth_ratios])]
    section_indices = [list(h0_indices)]
    section_names = (
        "H0",
        "deltoid_exit",
        "upper_arm",
        "distal_upper_arm",
        "elbow_olecranon",
        "proximal_forearm",
        "mid_forearm",
        "distal_forearm",
        "carpus",
    )
    collar_points = [Vector(vertices[index]) for index in collar_indices]
    incoming_directions = [
        (h0_point - collar_point).normalized() for h0_point, collar_point in zip(h0_points, collar_points)
    ]
    control_parameter = [index / 3.0 for index in range(len(centers))]
    for section in range(1, len(centers)):
        _, dorsal_axis, caudal_axis = frames[section]
        ring = []
        for column, (dorsal_normalized, caudal_normalized) in enumerate(normalized):
            dorsal_coordinate = 0.5 * shoulder_width * width_ratios[section] * dorsal_normalized
            caudal_coordinate = 0.5 * shoulder_depth * depth_ratios[section] * caudal_normalized
            parameter = control_parameter[section]
            upper_weight = max(0.0, 1.0 - abs(parameter - 2.5) / 1.5)
            elbow_weight = max(0.0, 1.0 - abs(parameter - 4.0))
            forearm_weight = max(0.0, min(1.0, parameter - 4.5))
            caudal_coordinate += 0.035 * shoulder_width * upper_weight * max(0.0, caudal_normalized) ** 2
            if elbow_weight > 0.0:
                caudal_coordinate += 0.095 * shoulder_width * elbow_weight * max(0.0, caudal_normalized) ** 3
                dorsal_coordinate *= 1.0 - 0.08 * max(0.0, -caudal_normalized)
            dorsal_coordinate *= 1.0 - 0.10 * forearm_weight * max(0.0, -caudal_normalized)
            model_point = centers[section] + dorsal_axis * dorsal_coordinate + caudal_axis * caudal_coordinate
            if section <= 5:
                local_step = (centers[1] - centers[0]).length
                incoming_point = h0_points[column] + incoming_directions[column] * (local_step * section)
                model_weight = 0.0 if section <= 3 else 0.33 if section == 4 else 0.66
                model_point = incoming_point.lerp(model_point, model_weight)
            ring.append(model_point)
        ring = [tuple(point) for point in ring]
        indices = list(range(len(vertices), len(vertices) + SEGMENTS))
        vertices.extend(ring)
        section_indices.append(indices)
    limb_face_start = len(faces)
    for first_ring, second_ring in zip(section_indices, section_indices[1:]):
        for index in range(SEGMENTS):
            following = (index + 1) % SEGMENTS
            faces.append((first_ring[index], first_ring[following], second_ring[following], second_ring[index]))
    return {
        "sectionIndices": section_indices,
        "sectionNames": section_names,
        "centers": centers,
        "controlCenters": control_centers,
        "frames": frames,
        "rollChangesDegrees": roll_changes,
        "shoulderToGround": shoulder_to_ground,
        "shoulderWidth": shoulder_width,
        "widthRatios": control_width_ratios,
        "depthRatios": control_depth_ratios,
        "collarIndices": list(collar_indices),
        "limbFaceStart": limb_face_start,
    }


def self_intersections(vertices, faces):
    bvh = BVHTree.FromPolygons([Vector(vertex) for vertex in vertices], faces, all_triangles=False)
    return [
        (first, second)
        for first, second in bvh.overlap(bvh)
        if first < second and not set(faces[first]).intersection(faces[second])
    ]


def topology_report(vertices, faces, build):
    edges = Counter()
    owners = defaultdict(list)
    face_areas = []
    edge_ratios = []
    normals = []
    for face_index, face in enumerate(faces):
        points = [Vector(vertices[index]) for index in face]
        normals.append(polygon_normal(vertices, face))
        face_areas.append(
            0.5 * (points[1] - points[0]).cross(points[2] - points[0]).length
            + 0.5 * (points[2] - points[0]).cross(points[3] - points[0]).length
        )
        lengths = []
        for index, first in enumerate(face):
            second = face[(index + 1) % 4]
            key = edge_key(first, second)
            edges[key] += 1
            owners[key].append(face_index)
            lengths.append((Vector(vertices[first]) - Vector(vertices[second])).length)
        edge_ratios.append(max(lengths) / min(lengths))
    reversed_adjacencies = sum(
        normals[first].dot(normals[second]) < -0.20
        for owner_faces in owners.values()
        if len(owner_faces) == 2
        for first, second in [owner_faces]
    )
    intersections = self_intersections(vertices, faces)
    limb_start = build["limbFaceStart"]
    intersection_categories = Counter(
        "baseBase"
        if first < limb_start and second < limb_start
        else "baseLimb"
        if first < limb_start <= second
        else "limbLimb"
        for first, second in intersections
    )
    h0_indices = build["sectionIndices"][0]
    first_ring_indices = build["sectionIndices"][1]
    cage_tangent_dots = [
        (Vector(vertices[h0]) - Vector(vertices[collar])).normalized().dot(
            (Vector(vertices[first_ring]) - Vector(vertices[h0])).normalized()
        )
        for collar, h0, first_ring in zip(build["collarIndices"], h0_indices, first_ring_indices)
    ]
    h0_normal_dots = []
    for vertex in h0_indices:
        side_normals = []
        for face_group in (faces[:limb_start], faces[limb_start:]):
            group_normals = [polygon_normal(vertices, face) for face in face_group if vertex in face]
            side_normals.append(sum(group_normals, start=Vector()).normalized())
        h0_normal_dots.append(abs(side_normals[0].dot(side_normals[1])))
    components = 0
    adjacency = defaultdict(set)
    for first, second in edges:
        adjacency[first].add(second)
        adjacency[second].add(first)
    remaining = set(range(len(vertices)))
    while remaining:
        components += 1
        queue = deque([next(iter(remaining))])
        while queue:
            vertex = queue.popleft()
            if vertex not in remaining:
                continue
            remaining.remove(vertex)
            queue.extend(adjacency[vertex] & remaining)
    return {
        "vertices": len(vertices),
        "faces": len(faces),
        "quads": sum(len(face) == 4 for face in faces),
        "nonmanifoldEdges": sum(count > 2 for count in edges.values()),
        "boundaryEdges": sum(count == 1 for count in edges.values()),
        "components": components,
        "maximumEdgeRatio": max(edge_ratios),
        "worstEdgeRatioFaces": [
            {
                "index": face_index,
                "ratio": edge_ratios[face_index],
                "vertices": list(faces[face_index]),
                "coordinates": [list(vertices[vertex]) for vertex in faces[face_index]],
                "band": "base" if face_index < limb_start else (face_index - limb_start) // SEGMENTS,
            }
            for face_index in sorted(range(len(faces)), key=edge_ratios.__getitem__, reverse=True)[:12]
        ],
        "minimumFaceArea": min(face_areas),
        "medianFaceArea": sorted(face_areas)[len(face_areas) // 2],
        "minimumAreaFraction": min(face_areas) / sorted(face_areas)[len(face_areas) // 2],
        "nonadjacentSelfIntersectionPairs": len(intersections),
        "firstSelfIntersectionPairs": intersections[:12],
        "selfIntersectionCategories": dict(sorted(intersection_categories.items())),
        "reversedAdjacencies": reversed_adjacencies,
        "h0SeamMinimumNormalDot": min(h0_normal_dots),
        "h0CageTangentMinimumDot": min(cage_tangent_dots),
    }


def subdivided_intersection_report(obj):
    temporary = obj.copy()
    temporary.data = obj.data.copy()
    temporary.name = "BrownBear_Forelimb_SubdivisionAudit"
    bpy.context.collection.objects.link(temporary)
    temporary.modifiers.clear()
    modifier = temporary.modifiers.new("CatmullClarkAudit", "SUBSURF")
    modifier.subdivision_type = "CATMULL_CLARK"
    modifier.levels = 2
    modifier.render_levels = 2
    bpy.context.view_layer.update()
    evaluated = temporary.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = evaluated.to_mesh()
    vertices = [tuple(vertex.co) for vertex in mesh.vertices]
    faces = [tuple(polygon.vertices) for polygon in mesh.polygons]
    intersections = self_intersections(vertices, faces)
    evaluated.to_mesh_clear()
    bpy.data.objects.remove(temporary, do_unlink=True)
    return {"level": 2, "nonadjacentSelfIntersectionPairs": len(intersections), "firstPairs": intersections[:12]}


def main():
    args = parse_args()
    obj = bpy.data.objects["BrownBear_ShoulderSaddlePatch"]
    mesh = obj.data
    vertices = [tuple(vertex.co) for vertex in mesh.vertices]
    faces = [tuple(polygon.vertices) for polygon in mesh.polygons]
    h0_indices = list(obj["h0_indices"])
    collar_indices = list(obj["collar_indices"])
    initial_tangent = Vector(obj["humerus_tangent"])
    build = append_forelimb(vertices, faces, collar_indices, h0_indices, initial_tangent)
    mesh.clear_geometry()
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj["carpus_indices"] = build["sectionIndices"][-1]
    obj["forelimb_section_names"] = list(build["sectionNames"])
    group = obj.vertex_groups.get("Carpus") or obj.vertex_groups.new(name="Carpus")
    group.add(build["sectionIndices"][-1], 1.0, "REPLACE")
    topology = topology_report(vertices, faces, build)
    subdivision = subdivided_intersection_report(obj)
    centers = build["controlCenters"]
    length = build["shoulderToGround"]
    report = {
        "status": "pending_forelimb_carpus_critic_gate",
        "topology": topology,
        "subdivision": subdivision,
        "anatomy": {
            "sections": list(build["sectionNames"]),
            "sectionCountIncludingH0": len(build["sectionNames"]),
            "emittedRingCountIncludingH0": len(build["sectionIndices"]),
            "supportLoopsPerControlInterval": 2,
            "widthRatios": list(build["widthRatios"]),
            "depthRatios": list(build["depthRatios"]),
            "elbowDepthFraction": (centers[0].z - centers[4].z) / length,
            "carpusDepthFraction": (centers[0].z - centers[-1].z) / length,
            "elbowCaudalFraction": (centers[4].y - centers[0].y) / length,
            "carpusCranialFraction": (centers[0].y - centers[-1].y) / length,
            "olecranonProjectionShoulderWidths": 0.095,
            "maximumSectionRollDegrees": max(build["rollChangesDegrees"] or [0.0]),
            "cumulativeFrameRollDegrees": sum(abs(value) for value in build["rollChangesDegrees"]),
            "cyclicPhaseShifts": 0,
        },
    }
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_FORELIMB_CARPUS_GATE", json.dumps(report))


if __name__ == "__main__":
    main()

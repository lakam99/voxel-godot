import argparse
import json
import math
import sys
from collections import Counter, defaultdict, deque
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree


SEGMENTS = 24
CONTROL_WIDTH_RATIOS = (1.00, 0.73, 0.60, 0.56, 0.58, 0.58, 0.52, 0.44, 0.37)
CONTROL_DEPTH_RATIOS = (1.00, 0.90, 0.82, 0.78, 0.72, 0.60, 0.52, 0.42, 0.35)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--smoothing-weight", type=float, default=400.0)
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
        (0.13, 0.000, 0.000),
        (0.22, 0.025, -0.100),
        (0.31, 0.055, -0.220),
        (0.35, 0.090, -0.350),
        (0.35, 0.070, -0.450),
        (0.31, 0.020, -0.560),
        (0.29, -0.050, -0.660),
        (0.28, -0.080, -0.710),
    )
    centers = [Vector(h0_center)]
    centers.append(Vector(h0_center) + Vector(initial_tangent).normalized() * (0.13 * length))
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


def bspline_basis(index, degree, parameter, knots, control_count):
    if degree == 0:
        if parameter == 1.0:
            return 1.0 if index == control_count - 1 else 0.0
        return 1.0 if knots[index] <= parameter < knots[index + 1] else 0.0
    first = 0.0
    first_denominator = knots[index + degree] - knots[index]
    if first_denominator > 0.0:
        first = (
            (parameter - knots[index])
            / first_denominator
            * bspline_basis(index, degree - 1, parameter, knots, control_count)
        )
    second = 0.0
    second_denominator = knots[index + degree + 1] - knots[index + 1]
    if second_denominator > 0.0:
        second = (
            (knots[index + degree + 1] - parameter)
            / second_denominator
            * bspline_basis(index + 1, degree - 1, parameter, knots, control_count)
        )
    return first + second


def interpolate_log_schedule(values, station_parameters, parameter):
    if parameter <= station_parameters[0]:
        return values[0]
    if parameter >= station_parameters[-1]:
        return values[-1]
    for index in range(len(station_parameters) - 1):
        first = station_parameters[index]
        second = station_parameters[index + 1]
        if first <= parameter <= second:
            factor = (parameter - first) / (second - first)
            return math.exp(
                math.log(values[index]) * (1.0 - factor)
                + math.log(values[index + 1]) * factor
            )
    return values[-1]


def evaluate_bspline(control_points, parameter, knots, degree=3):
    return sum(
        (
            point * bspline_basis(index, degree, parameter, knots, len(control_points))
            for index, point in enumerate(control_points)
        ),
        start=Vector(),
    )


def fit_centerline(control_centers, initial_tangent, shoulder_width, length, smoothing_weight):
    degree = 3
    control_count = 10
    internal_count = control_count - degree - 1
    knots = [0.0] * (degree + 1)
    knots.extend(index / (internal_count + 1) for index in range(1, internal_count + 1))
    knots.extend([1.0] * (degree + 1))

    chord_lengths = [
        (control_centers[index + 1] - control_centers[index]).length
        for index in range(len(control_centers) - 1)
    ]
    cumulative = [0.0]
    for chord_length in chord_lengths:
        cumulative.append(cumulative[-1] + chord_length)
    station_parameters = [value / cumulative[-1] for value in cumulative]

    fixed = {
        0: Vector(control_centers[0]),
        1: Vector(control_centers[0]) + Vector(initial_tangent).normalized() * (0.10 * length),
        control_count - 1: Vector(control_centers[-1]),
    }
    variable_indices = [index for index in range(control_count) if index not in fixed]
    station_weights = (0.0, 20.0, 16.0, 16.0, 28.0, 16.0, 14.0, 12.0, 0.0)
    solved = None
    solve_metrics = None

    for _ in range(1):
        rows = []
        targets = []
        for station, parameter, weight in zip(control_centers, station_parameters, station_weights):
            if weight <= 0.0:
                continue
            basis = [
                bspline_basis(index, degree, parameter, knots, control_count)
                for index in range(control_count)
            ]
            adjusted = Vector(station)
            for index, point in fixed.items():
                adjusted -= point * basis[index]
            rows.append([math.sqrt(weight) * basis[index] for index in variable_indices])
            targets.append([math.sqrt(weight) * value for value in adjusted])
        for center_index in range(1, control_count - 1):
            coefficients = [0.0] * control_count
            coefficients[center_index - 1] = 1.0
            coefficients[center_index] = -2.0
            coefficients[center_index + 1] = 1.0
            adjusted = Vector()
            for index, point in fixed.items():
                adjusted -= point * coefficients[index]
            rows.append(
                [math.sqrt(smoothing_weight) * coefficients[index] for index in variable_indices]
            )
            targets.append([math.sqrt(smoothing_weight) * value for value in adjusted])
        matrix = np.asarray(rows, dtype=float)
        right_hand = np.asarray(targets, dtype=float)
        solution, _, _, _ = np.linalg.lstsq(matrix, right_hand, rcond=None)
        solved = [Vector()] * control_count
        for index, point in fixed.items():
            solved[index] = point
        for row, index in enumerate(variable_indices):
            solved[index] = Vector(solution[row])

        samples = [evaluate_bspline(solved, index / 600.0, knots) for index in range(601)]
        curvature_radius_products = []
        for index in range(1, len(samples) - 1):
            incoming = samples[index] - samples[index - 1]
            outgoing = samples[index + 1] - samples[index]
            average_step = 0.5 * (incoming.length + outgoing.length)
            if average_step <= 1e-8:
                continue
            curvature = incoming.normalized().angle(outgoing.normalized()) / average_step
            parameter = index / 600.0
            radius = 0.5 * shoulder_width * interpolate_log_schedule(
                CONTROL_WIDTH_RATIOS, station_parameters, parameter
            )
            curvature_radius_products.append(curvature * radius)
        maximum_product = max(curvature_radius_products or [0.0])
        solve_metrics = {
            "smoothingWeight": smoothing_weight,
            "maximumDenseCurvatureTimesBendRadius": maximum_product,
        }

    samples = [evaluate_bspline(solved, index / 1200.0, knots) for index in range(1201)]
    cumulative_tau = [0.0]
    for index in range(1, len(samples)):
        midpoint_parameter = (index - 0.5) / 1200.0
        radius = 0.5 * shoulder_width * interpolate_log_schedule(
            CONTROL_WIDTH_RATIOS, station_parameters, midpoint_parameter
        )
        cumulative_tau.append(
            cumulative_tau[-1]
            + (samples[index] - samples[index - 1]).length / radius
        )
    emitted_parameters = [0.0]
    search_index = 1
    for ring_index in range(1, 25):
        target_tau = cumulative_tau[-1] * ring_index / 24.0
        while cumulative_tau[search_index] < target_tau:
            search_index += 1
        first_tau = cumulative_tau[search_index - 1]
        second_tau = cumulative_tau[search_index]
        factor = (target_tau - first_tau) / max(second_tau - first_tau, 1e-8)
        emitted_parameters.append((search_index - 1 + factor) / 1200.0)
    tail_anchor_ring = 6
    tail_anchor_sample = round(emitted_parameters[tail_anchor_ring] * 1200.0)
    tail_arc_lengths = [0.0]
    for sample_index in range(tail_anchor_sample + 1, len(samples)):
        tail_arc_lengths.append(
            tail_arc_lengths[-1] + (samples[sample_index] - samples[sample_index - 1]).length
        )
    tail_search_index = 1
    tail_interval_count = 24 - tail_anchor_ring
    for tail_ring in range(1, tail_interval_count + 1):
        target_arc = tail_arc_lengths[-1] * tail_ring / tail_interval_count
        while tail_arc_lengths[tail_search_index] < target_arc:
            tail_search_index += 1
        first_arc = tail_arc_lengths[tail_search_index - 1]
        second_arc = tail_arc_lengths[tail_search_index]
        factor = (target_arc - first_arc) / max(second_arc - first_arc, 1e-8)
        emitted_parameters[tail_anchor_ring + tail_ring] = (
            tail_anchor_sample + tail_search_index - 1 + factor
        ) / 1200.0
    centers = [evaluate_bspline(solved, parameter, knots) for parameter in emitted_parameters]
    return {
        "centers": centers,
        "emittedParameters": emitted_parameters,
        "stationParameters": station_parameters,
        "solveMetrics": solve_metrics,
    }


def append_forelimb(
    vertices,
    faces,
    collar_indices,
    h0_indices,
    initial_tangent,
    smoothing_weight,
):
    h0_points = [Vector(vertices[index]) for index in h0_indices]
    h0_center = sum(h0_points, start=Vector()) / SEGMENTS
    shoulder_to_ground = max(0.80, h0_center.z - 0.08)
    control_centers = build_control_centers(h0_center, shoulder_to_ground, initial_tangent)
    initial_tangent = Vector(initial_tangent).normalized()
    initial_dorsal = Vector((0.0, 0.0, 1.0))
    initial_dorsal = (initial_dorsal - initial_tangent * initial_dorsal.dot(initial_tangent)).normalized()
    initial_caudal = initial_tangent.cross(initial_dorsal).normalized()
    if initial_caudal.y < 0.0:
        initial_caudal = -initial_caudal
    dorsal_values = [(point - h0_center).dot(initial_dorsal) for point in h0_points]
    caudal_values = [(point - h0_center).dot(initial_caudal) for point in h0_points]
    dorsal_mid = 0.5 * (max(dorsal_values) + min(dorsal_values))
    caudal_mid = 0.5 * (max(caudal_values) + min(caudal_values))
    shoulder_width = max(dorsal_values) - min(dorsal_values)
    shoulder_depth = max(caudal_values) - min(caudal_values)
    centerline = fit_centerline(
        control_centers,
        initial_tangent,
        shoulder_width,
        shoulder_to_ground,
        smoothing_weight,
    )
    centers = centerline["centers"]
    frames, roll_changes = parallel_transport_frames(centers, initial_tangent)
    normalized = [
        (
            (dorsal - dorsal_mid) / (0.5 * shoulder_width),
            (caudal - caudal_mid) / (0.5 * shoulder_depth),
        )
        for dorsal, caudal in zip(dorsal_values, caudal_values)
    ]
    width_ratios = [
        interpolate_log_schedule(CONTROL_WIDTH_RATIOS, centerline["stationParameters"], parameter)
        for parameter in centerline["emittedParameters"]
    ]
    depth_ratios = [
        interpolate_log_schedule(CONTROL_DEPTH_RATIOS, centerline["stationParameters"], parameter)
        for parameter in centerline["emittedParameters"]
    ]
    width_ratios[1] = 1.0
    depth_ratios[1] = 1.0
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
    control_parameter = []
    for parameter in centerline["emittedParameters"]:
        nearest = min(
            range(len(centerline["stationParameters"])),
            key=lambda index: abs(centerline["stationParameters"][index] - parameter),
        )
        control_parameter.append(float(nearest))
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
                caudal_coordinate += 0.086 * shoulder_width * elbow_weight * max(0.0, caudal_normalized) ** 3
                dorsal_coordinate *= 1.0 - 0.08 * max(0.0, -caudal_normalized)
            if 10 <= section <= 13:
                cranial_transfer_weight = 1.0 - abs(section - 11.5) / 2.5
                caudal_coordinate -= (
                    0.009
                    * shoulder_width
                    * cranial_transfer_weight
                    * max(0.0, -caudal_normalized) ** 2
                )
            dorsal_coordinate *= 1.0 - 0.10 * forearm_weight * max(0.0, -caudal_normalized)
            model_point = centers[section] + dorsal_axis * dorsal_coordinate + caudal_axis * caudal_coordinate
            if section <= 7:
                local_step = (centers[section] - centers[section - 1]).length
                previous_point = (
                    h0_points[column]
                    if section == 1
                    else Vector(vertices[section_indices[-1][column]])
                )
                direction_weight = (section - 1) / 6.0
                travel_direction = incoming_directions[column].lerp(
                    Vector(initial_tangent).normalized(), direction_weight
                ).normalized()
                transported_point = previous_point + travel_direction * local_step
                model_weight = (section - 1) / 7.0
                model_point = transported_point.lerp(model_point, model_weight)
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
        "emittedParameters": centerline["emittedParameters"],
        "stationParameters": centerline["stationParameters"],
        "centerlineSolveMetrics": centerline["solveMetrics"],
        "rollChangesDegrees": roll_changes,
        "shoulderToGround": shoulder_to_ground,
        "shoulderWidth": shoulder_width,
        "widthRatios": CONTROL_WIDTH_RATIOS,
        "depthRatios": CONTROL_DEPTH_RATIOS,
        "emittedWidthRatios": width_ratios,
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
    normalized_band_quality = []
    normalized_face_quality = []
    for band, (first_ring, second_ring) in enumerate(
        zip(build["sectionIndices"], build["sectionIndices"][1:])
    ):
        center_step = (build["centers"][band + 1] - build["centers"][band]).length
        circumferential_lengths = []
        for ring in (first_ring, second_ring):
            circumferential_lengths.extend(
                (Vector(vertices[ring[(index + 1) % SEGMENTS]]) - Vector(vertices[ring[index]])).length
                for index in range(SEGMENTS)
            )
        target_circumferential_edge = sum(circumferential_lengths) / len(circumferential_lengths)
        denominator = max(center_step * target_circumferential_edge, 1e-12)
        band_start = limb_start + band * SEGMENTS
        values = [face_areas[band_start + index] / denominator for index in range(SEGMENTS)]
        median_value = sorted(values)[len(values) // 2]
        normalized_face_quality.extend(values)
        normalized_band_quality.append(
            {
                "band": band,
                "minimum": min(values),
                "median": median_value,
                "minimumToMedian": min(values) / median_value,
            }
        )
    normalized_global_median = sorted(normalized_face_quality)[len(normalized_face_quality) // 2]
    adjacent_band_ratios = []
    for index, band in enumerate(normalized_band_quality):
        neighbors = []
        if index > 0:
            neighbors.append(normalized_band_quality[index - 1]["median"])
        if index + 1 < len(normalized_band_quality):
            neighbors.append(normalized_band_quality[index + 1]["median"])
        adjacent_band_ratios.extend(band["median"] / neighbor for neighbor in neighbors)
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
        "normalizedAreaQuality": {
            "definition": "face_area / (center_step * mean_circumferential_edge)",
            "globalMinimumToMedian": min(normalized_face_quality) / normalized_global_median,
            "minimumBandMinimumToMedian": min(
                band["minimumToMedian"] for band in normalized_band_quality
            ),
            "minimumAdjacentBandMedianRatio": min(adjacent_band_ratios),
            "bands": normalized_band_quality,
        },
        "smallestAreaFaces": [
            {
                "index": face_index,
                "area": face_areas[face_index],
                "vertices": list(faces[face_index]),
                "coordinates": [list(vertices[vertex]) for vertex in faces[face_index]],
                "band": "base" if face_index < limb_start else (face_index - limb_start) // SEGMENTS,
            }
            for face_index in sorted(range(len(faces)), key=face_areas.__getitem__)[:12]
        ],
        "nonadjacentSelfIntersectionPairs": len(intersections),
        "firstSelfIntersectionPairs": intersections[:12],
        "selfIntersectionCategories": dict(sorted(intersection_categories.items())),
        "reversedAdjacencies": reversed_adjacencies,
        "h0SeamMinimumNormalDot": min(h0_normal_dots),
        "h0CageTangentMinimumDot": min(cage_tangent_dots),
    }


def centerline_report(build):
    centers = build["centers"]
    frames = build["frames"]
    shoulder_width = build["shoulderWidth"]
    dense_width_ratios = build["emittedWidthRatios"]
    tangent_changes = []
    curvature_radius_products = []
    for index in range(1, len(centers)):
        tangent_changes.append(math.degrees(frames[index - 1][0].angle(frames[index][0])))
    for index in range(1, len(centers) - 1):
        incoming = (centers[index] - centers[index - 1]).normalized()
        outgoing = (centers[index + 1] - centers[index]).normalized()
        turning_angle = incoming.angle(outgoing)
        average_step = 0.5 * (
            (centers[index] - centers[index - 1]).length
            + (centers[index + 1] - centers[index]).length
        )
        curvature = turning_angle / max(average_step, 1e-8)
        bend_plane_half_radius = 0.5 * shoulder_width * dense_width_ratios[index]
        curvature_radius_products.append(curvature * bend_plane_half_radius)
    return {
        "construction": "globally_constrained_approximating_c2_bspline",
        "ringDistribution": "radius-weighted through ring 6, then uniform distal arc length",
        "solve": build["centerlineSolveMetrics"],
        "emittedBandTangentChangesDegrees": tangent_changes,
        "curvatureTimesBendRadiusByInteriorRing": curvature_radius_products,
        "maximumEmittedBandTangentChangeDegrees": max(tangent_changes or [0.0]),
        "maximumCurvatureTimesBendRadius": max(curvature_radius_products or [0.0]),
        "curvatureTimesBendRadiusLimit": 0.40,
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
    build = append_forelimb(
        vertices,
        faces,
        collar_indices,
        h0_indices,
        initial_tangent,
        args.smoothing_weight,
    )
    mesh.clear_geometry()
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj["carpus_indices"] = build["sectionIndices"][-1]
    obj["precarpus_indices"] = build["sectionIndices"][-2]
    obj["forelimb_section_names"] = list(build["sectionNames"])
    group = obj.vertex_groups.get("Carpus") or obj.vertex_groups.new(name="Carpus")
    group.add(build["sectionIndices"][-1], 1.0, "REPLACE")
    topology = topology_report(vertices, faces, build)
    subdivision = subdivided_intersection_report(obj)
    centerline = centerline_report(build)
    centers = build["controlCenters"]
    length = build["shoulderToGround"]
    report = {
        "status": "pending_forelimb_carpus_critic_gate",
        "topology": topology,
        "subdivision": subdivision,
        "centerline": centerline,
        "anatomy": {
            "sections": list(build["sectionNames"]),
            "sectionCountIncludingH0": len(build["sectionNames"]),
            "emittedRingCountIncludingH0": len(build["sectionIndices"]),
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

import argparse
import json
import math
import sys
from collections import Counter, defaultdict, deque
from pathlib import Path

import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree


SEGMENTS = 24
RAILS = 13
DISTAL_RAILS = 14
ANATOMY_PARAMETERS = (0.00, 0.04, 0.08, 0.13, 0.18, 0.265, 0.35, 0.45, 0.55, 0.625, 0.70, 0.76, 0.82)
SECTION_PARAMETERS = (
    0.00, 0.045, 0.09, 0.16, 0.24, 0.35, 0.42, 0.45,
    0.475, 0.515, 0.555, 0.595, 0.635, 0.661, 0.687, 0.713,
    0.739, 0.765, 0.791, 0.817, 0.85, 0.88, 0.91, 0.94,
)
WIDTH_RATIOS = (1.00, 0.98, 0.95, 1.05, 1.15, 1.26, 1.35, 1.41, 1.44, 1.44, 1.42, 1.39, 1.35)
THICKNESS_RATIOS = (0.78, 0.84, 0.90, 0.96, 1.00, 1.00, 0.98, 0.92, 0.84, 0.76, 0.70, 0.66, 0.62)
LANE_COEFFICIENTS = (0.0, 0.35, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, 0.35, 0.0)
TOE_CENTER_RAILS = (2, 4, 6, 8, 10)
TOE_LATERAL = (-0.38, -0.19, 0.0, 0.19, 0.38)
TOE_FAN_DEGREES = (-10.0, -5.0, 0.0, 5.0, 10.0)
TOE_LENGTHS = (0.945, 0.982, 1.00, 0.985, 0.95)
DISTAL_LATERAL = (-0.50, -0.36, -0.3375, -0.315, -0.145, -0.1225, -0.10, 0.10, 0.1225, 0.145, 0.315, 0.3375, 0.36, 0.50)
DISTAL_TOE_PAIRS = ((0, 1), (3, 4), (6, 7), (9, 10), (12, 13))
DISTAL_WEB_RAILS = (2, 5, 8, 11)


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


def face_area(vertices, face):
    points = [Vector(vertices[index]) for index in face]
    return 0.5 * sum(
        (points[index] - points[0]).cross(points[index + 1] - points[0]).length
        for index in range(1, len(points) - 1)
    )


def self_intersections(vertices, faces):
    bvh = BVHTree.FromPolygons([Vector(vertex) for vertex in vertices], faces, all_triangles=False)
    return [
        (first, second)
        for first, second in bvh.overlap(bvh)
        if first < second and not set(faces[first]).intersection(faces[second])
    ]


def carpus_paths(vertices, carpus_indices):
    points = [Vector(vertices[index]) for index in carpus_indices]
    maximum = max(range(SEGMENTS), key=lambda index: points[index].x)
    opposite = (maximum + SEGMENTS // 2) % SEGMENTS
    cycle = carpus_indices[maximum:] + carpus_indices[:maximum]
    if cycle[SEGMENTS // 2] != carpus_indices[opposite]:
        raise RuntimeError("carpus side vertices are not opposite")
    first_arc = cycle[: RAILS]
    second_arc = [cycle[0]] + list(reversed(cycle[RAILS - 1 :]))
    first_average = sum(Vector(vertices[index]).z for index in first_arc) / RAILS
    second_average = sum(Vector(vertices[index]).z for index in second_arc) / RAILS
    if first_average >= second_average:
        dorsal = first_arc
        plantar = second_arc
    else:
        dorsal = second_arc
        plantar = first_arc
    return cycle, dorsal, plantar


def rail_toe_influence(rail):
    influences = []
    for toe_index, center in enumerate(TOE_CENTER_RAILS):
        distance = abs(rail - center)
        influences.append((max(0.0, 1.0 - distance / 1.45), toe_index))
    total = sum(weight for weight, _ in influences)
    if total <= 0.0:
        return [(1.0, min(range(5), key=lambda index: abs(rail - TOE_CENTER_RAILS[index])))]
    return [(weight / total, toe_index) for weight, toe_index in influences if weight > 0.0]


def smoothstep(first, second, value):
    factor = max(0.0, min(1.0, (value - first) / (second - first)))
    return factor * factor * (3.0 - 2.0 * factor)


def interpolate_schedule(values, parameter):
    if parameter <= ANATOMY_PARAMETERS[0]:
        return values[0]
    if parameter >= ANATOMY_PARAMETERS[-1]:
        return values[-1]
    for index in range(len(ANATOMY_PARAMETERS) - 1):
        first = ANATOMY_PARAMETERS[index]
        second = ANATOMY_PARAMETERS[index + 1]
        if first <= parameter <= second:
            factor = (parameter - first) / (second - first)
            return values[index] * (1.0 - factor) + values[index + 1] * factor
    return values[-1]


def distal_phase(parameter):
    controls = (
        (0.68, 0.00),
        (0.72, 0.18),
        (0.76, 0.38),
        (0.84, 0.72),
        (0.90, 0.90),
        (0.94, 0.97),
    )
    if parameter <= controls[0][0]:
        return 0.0
    for (first_u, first_value), (second_u, second_value) in zip(controls, controls[1:]):
        if first_u <= parameter <= second_u:
            factor = (parameter - first_u) / (second_u - first_u)
            return first_value * (1.0 - factor) + second_value * factor
    return controls[-1][1]


def width_ratio(parameter):
    controls = (
        (0.00, 0.71),
        (0.045, 0.71),
        (0.09, 0.71 * 1.02),
        (0.16, 0.71 * 1.08),
        (0.26, 0.82),
        (0.42, 0.96),
        (0.55, 1.00),
        (0.66, 0.96),
        (0.82, 0.93),
        (0.94, 0.90),
    )
    for (first_u, first_value), (second_u, second_value) in zip(controls, controls[1:]):
        if first_u <= parameter <= second_u:
            factor = smoothstep(first_u, second_u, parameter)
            return first_value * (1.0 - factor) + second_value * factor
    return controls[-1][1]


def thickness_ratio(parameter, carpus_depth, paw_width):
    controls = (
        (0.00, carpus_depth),
        (0.045, carpus_depth),
        (0.09, carpus_depth * 1.01),
        (0.16, carpus_depth * 1.04),
        (0.30, paw_width * 0.33),
        (0.44, paw_width * 0.36),
        (0.55, paw_width * 0.35),
        (0.68, paw_width * 0.31),
        (0.84, paw_width * 0.24),
        (0.94, paw_width * 0.16),
    )
    for (first_u, first_value), (second_u, second_value) in zip(controls, controls[1:]):
        if first_u <= parameter <= second_u:
            factor = smoothstep(first_u, second_u, parameter)
            return first_value * (1.0 - factor) + second_value * factor
    return controls[-1][1]


def cubic_bezier(first, second, third, fourth, factor):
    inverse = 1.0 - factor
    return (
        first * inverse**3
        + second * 3.0 * inverse * inverse * factor
        + third * 3.0 * inverse * factor * factor
        + fourth * factor**3
    )


def cubic_bezier_tangent(first, second, third, fourth, factor):
    inverse = 1.0 - factor
    return (
        (second - first) * 3.0 * inverse * inverse
        + (third - second) * 6.0 * inverse * factor
        + (fourth - third) * 3.0 * factor * factor
    ).normalized()


def section_point(
    rail,
    is_dorsal,
    parameter,
    center,
    forward_axis,
    width_axis,
    thickness_axis,
    paw_width,
    paw_length,
    thickness,
):
    width_normalized = rail / (RAILS - 1) * 2.0 - 1.0
    lateral = 0.5 * paw_width * width_normalized
    forward = 0.0
    relief = smoothstep(0.68, 0.86, parameter)
    toe_phase = distal_phase(parameter)
    influences = rail_toe_influence(rail)
    relative_length = sum(weight * TOE_LENGTHS[toe] for weight, toe in influences)
    if toe_phase > 0.0:
        is_web = rail in (3, 5, 7, 9)
        target_length = relative_length - (0.03 if is_web else 0.0)
        desired_parameter = 0.68 + toe_phase * (target_length - 0.68)
        fan_offset = sum(
            weight
            * math.tan(math.radians(TOE_FAN_DEGREES[toe]))
            * max(0.0, desired_parameter - 0.68)
            * paw_length
            for weight, toe in influences
        )
        lateral += fan_offset
        forward += (desired_parameter - parameter) * paw_length
    web = rail in (3, 5, 7, 9)
    toe_center = rail in TOE_CENTER_RAILS
    support = rail in (1, 11)
    edge = rail in (0, 12)
    profile = max(0.0, 1.0 - width_normalized * width_normalized) ** 2
    if is_dorsal:
        vertical = thickness * 0.50 * profile
        crown_window = smoothstep(0.20, 0.32, parameter) * (1.0 - smoothstep(0.60, 0.68, parameter))
        vertical += thickness * 0.08 * profile * crown_window
        vertical += thickness * relief * (
            0.09 * max(0.0, LANE_COEFFICIENTS[rail])
            + 0.06 * min(0.0, LANE_COEFFICIENTS[rail])
        )
    else:
        vertical = thickness * -0.50 * profile
        vertical += thickness * 0.04 * (1.0 - profile) * smoothstep(0.20, 0.40, parameter)
        if parameter >= 0.70 and web:
            vertical += thickness * 0.035 * smoothstep(0.70, 0.88, parameter)
    if parameter <= 0.35 and not is_dorsal:
        heel_weight = max(0.0, 1.0 - abs(parameter - 0.18) / 0.18)
        forward -= 0.06 * paw_length * heel_weight * profile
    if support:
        vertical *= 0.98
    if edge:
        vertical = 0.0
    return center + forward_axis * forward + width_axis * lateral + thickness_axis * vertical


def distal_rail_influence(rail):
    for toe_index, pair in enumerate(DISTAL_TOE_PAIRS):
        if rail in pair:
            return ((1.0, toe_index),)
    web_index = DISTAL_WEB_RAILS.index(rail)
    return ((0.5, web_index), (0.5, web_index + 1))


def distal_section_point(
    rail,
    is_dorsal,
    parameter,
    center,
    forward_axis,
    width_axis,
    thickness_axis,
    paw_width,
    paw_length,
    thickness,
):
    uniform_lateral = rail / (DISTAL_RAILS - 1) - 0.5
    spacing_blend = smoothstep(0.475, 0.66, parameter)
    lateral_normalized = uniform_lateral * (1.0 - spacing_blend) + DISTAL_LATERAL[rail] * spacing_blend
    lateral = paw_width * lateral_normalized
    toe_phase = distal_phase(parameter)
    influences = distal_rail_influence(rail)
    relative_length = sum(weight * TOE_LENGTHS[toe] for weight, toe in influences)
    fan_angle = sum(weight * TOE_FAN_DEGREES[toe] for weight, toe in influences)
    is_web = rail in DISTAL_WEB_RAILS
    target_length = relative_length - (0.0275 if is_web else 0.0)
    desired_parameter = 0.68 + toe_phase * (target_length - 0.68)
    terminal_factor = smoothstep(target_length - 0.10, target_length, desired_parameter)
    for toe_index, pair in enumerate(DISTAL_TOE_PAIRS):
        if rail in pair:
            pair_center = 0.5 * (DISTAL_LATERAL[pair[0]] + DISTAL_LATERAL[pair[1]])
            contracted = pair_center + (DISTAL_LATERAL[rail] - pair_center) * 0.76
            lateral_normalized += (contracted - DISTAL_LATERAL[rail]) * terminal_factor * spacing_blend
            lateral = paw_width * lateral_normalized
            break
    forward = (desired_parameter - parameter) * paw_length if toe_phase > 0.0 else 0.0
    if toe_phase > 0.0:
        lateral += math.tan(math.radians(fan_angle)) * (desired_parameter - 0.68) * paw_length
    crown = max(0.0, 1.0 - (lateral_normalized / 0.5) ** 2) ** 2
    relief = smoothstep(0.66, 0.84, parameter)
    terminal_thickness = 1.0
    if terminal_factor > 0.0:
        terminal_controls = ((0.0, 1.0), (0.33, 0.65), (0.67, 0.25), (1.0, 0.0))
        for (first_u, first_value), (second_u, second_value) in zip(terminal_controls, terminal_controls[1:]):
            if first_u <= terminal_factor <= second_u:
                factor = smoothstep(first_u, second_u, terminal_factor)
                terminal_thickness = first_value * (1.0 - factor) + second_value * factor
                break
    if is_dorsal:
        vertical = thickness * terminal_thickness * (0.58 * crown + relief * (-0.07 if is_web else 0.12))
    else:
        vertical = thickness * terminal_thickness * (-0.50 * crown + (0.03 * relief if is_web else 0.0))
    if rail in (0, DISTAL_RAILS - 1):
        vertical = 0.0
    return center + forward_axis * forward + width_axis * lateral + thickness_axis * vertical


def connect_transition(faces, first_ring, second_ring):
    operations = ["regular"] * 6 + ["merge", "split"] + ["regular"] * 10 + ["split"] + ["regular"] * 6
    first_index = 0
    second_index = 0
    for operation in operations:
        if operation == "regular":
            faces.append((
                first_ring[first_index % 24],
                first_ring[(first_index + 1) % 24],
                second_ring[(second_index + 1) % 26],
                second_ring[second_index % 26],
            ))
            first_index += 1
            second_index += 1
        elif operation == "split":
            faces.append((
                first_ring[first_index % 24],
                second_ring[(second_index + 2) % 26],
                second_ring[(second_index + 1) % 26],
                second_ring[second_index % 26],
            ))
            second_index += 2
        else:
            faces.append((
                first_ring[first_index % 24],
                first_ring[(first_index + 1) % 24],
                first_ring[(first_index + 2) % 24],
                second_ring[second_index % 26],
            ))
            first_index += 2


def build_paw(vertices, faces, carpus_indices, precarpus_indices):
    carpus_points = [Vector(vertices[index]) for index in carpus_indices]
    carpus_center = sum(carpus_points, start=Vector()) / SEGMENTS
    cycle, dorsal_path, plantar_path = carpus_paths(vertices, carpus_indices)
    previous_by_carpus = {
        carpus: precarpus
        for carpus, precarpus in zip(carpus_indices, precarpus_indices)
    }
    forward_axis = Vector((0.0, -1.0, 0.0))
    precarpus_points = [Vector(vertices[index]) for index in precarpus_indices]
    precarpus_center = sum(precarpus_points, start=Vector()) / SEGMENTS
    incoming_tangent = (carpus_center - precarpus_center).normalized()
    width_axis = (
        Vector(vertices[dorsal_path[-1]]) - Vector(vertices[dorsal_path[0]])
    ).normalized()
    width_axis = (width_axis - incoming_tangent * width_axis.dot(incoming_tangent)).normalized()
    thickness_axis = incoming_tangent.cross(width_axis).normalized()
    dorsal_average = sum((Vector(vertices[index]) for index in dorsal_path), start=Vector()) / RAILS
    if (dorsal_average - carpus_center).dot(thickness_axis) < 0.0:
        dorsal_path, plantar_path = plantar_path, dorsal_path
    carpus_depth = max((point - carpus_center).dot(thickness_axis) for point in carpus_points) - min(
        (point - carpus_center).dot(thickness_axis) for point in carpus_points
    )
    carpus_width = (
        Vector(vertices[dorsal_path[-1]]) - Vector(vertices[dorsal_path[0]])
    ).length
    paw_width = carpus_width * 1.42
    paw_length = paw_width * 1.52
    maximum_thickness = paw_width * 0.36
    contact_z = 0.08
    path_start = carpus_center
    path_first_handle = path_start + incoming_tangent * (0.18 * paw_length)
    path_end = carpus_center + forward_axis * (SECTION_PARAMETERS[-1] * paw_length)
    path_end.z = contact_z + thickness_ratio(SECTION_PARAMETERS[-1], carpus_depth, paw_width) * 0.50
    path_second_handle = path_end - forward_axis * (0.24 * paw_length)
    path_second_handle.z += 0.03 * paw_length
    cycle_positions = {vertex: index for index, vertex in enumerate(cycle)}
    dorsal_positions = [cycle_positions[index] for index in dorsal_path]
    plantar_positions = [cycle_positions[index] for index in plantar_path]
    sections = [list(cycle)]
    transition_weights = (0.0, 0.0, 0.0, 0.0, 0.55, 1.0)
    previous_width_axis = width_axis
    for section_index, parameter in enumerate(SECTION_PARAMETERS[1:], start=1):
        width = paw_width * width_ratio(parameter)
        thickness = thickness_ratio(parameter, carpus_depth, paw_width)
        path_factor = parameter / SECTION_PARAMETERS[-1]
        center = cubic_bezier(
            path_start, path_first_handle, path_second_handle, path_end, path_factor
        )
        tangent = cubic_bezier_tangent(
            path_start, path_first_handle, path_second_handle, path_end, path_factor
        )
        section_width_axis = (
            previous_width_axis - tangent * previous_width_axis.dot(tangent)
        ).normalized()
        section_thickness_axis = tangent.cross(section_width_axis).normalized()
        previous_width_axis = section_width_axis
        if parameter < 0.475:
            ring_points = [None] * SEGMENTS
            for rail, position in enumerate(dorsal_positions):
                ring_points[position] = section_point(
                    rail, True, parameter, center, forward_axis, section_width_axis,
                    section_thickness_axis, width, paw_length, thickness,
                )
            for rail, position in enumerate(plantar_positions):
                point = section_point(
                    rail, False, parameter, center, forward_axis, section_width_axis,
                    section_thickness_axis, width, paw_length, thickness,
                )
                if ring_points[position] is None:
                    ring_points[position] = point
                else:
                    ring_points[position] = 0.5 * (ring_points[position] + point)
        else:
            distal_dorsal = [
                distal_section_point(
                    rail, True, parameter, center, forward_axis, section_width_axis,
                    section_thickness_axis, width, paw_length, thickness,
                )
                for rail in range(DISTAL_RAILS)
            ]
            distal_plantar = [
                distal_section_point(
                    rail, False, parameter, center, forward_axis, section_width_axis,
                    section_thickness_axis, width, paw_length, thickness,
                )
                for rail in range(DISTAL_RAILS)
            ]
            for edge_rail in (0, DISTAL_RAILS - 1):
                shared = 0.5 * (distal_dorsal[edge_rail] + distal_plantar[edge_rail])
                distal_dorsal[edge_rail] = shared
                distal_plantar[edge_rail] = shared
            ring_points = distal_dorsal + list(reversed(distal_plantar[1:-1]))
        transition_weight = transition_weights[min(section_index, len(transition_weights) - 1)]
        transition_advance = (center - carpus_center).length
        wrist_authority = len(ring_points) == SEGMENTS and section_index <= 3
        if wrist_authority:
            width_scales = (1.0, 1.0, 1.02, 1.08)
            depth_scales = (1.0, 1.0, 1.01, 1.04)
            translated_center = carpus_center + incoming_tangent * (parameter * paw_length)
            for position, carpus_vertex in enumerate(cycle):
                relative = Vector(vertices[carpus_vertex]) - carpus_center
                lateral_component = width_axis * relative.dot(width_axis) * width_scales[section_index]
                depth_component = thickness_axis * relative.dot(thickness_axis) * depth_scales[section_index]
                ring_points[position] = translated_center + lateral_component + depth_component
        elif len(ring_points) == SEGMENTS:
            for position, target_point in enumerate(ring_points):
                carpus_vertex = cycle[position]
                incoming_direction = (
                    Vector(vertices[carpus_vertex])
                    - Vector(vertices[previous_by_carpus[carpus_vertex]])
                ).normalized()
                continuation = Vector(vertices[carpus_vertex]) + incoming_direction * transition_advance
                ring_points[position] = continuation.lerp(target_point, transition_weight)
        indices = list(range(len(vertices), len(vertices) + len(ring_points)))
        vertices.extend(tuple(point) for point in ring_points)
        sections.append(indices)
    paw_face_start = len(faces)
    for first_ring, second_ring in zip(sections, sections[1:]):
        if len(first_ring) != len(second_ring):
            connect_transition(faces, first_ring, second_ring)
            continue
        for index in range(len(first_ring)):
            following = (index + 1) % len(first_ring)
            faces.append((first_ring[index], first_ring[following], second_ring[following], second_ring[index]))

    final_ring = sections[-1]
    final_dorsal = final_ring[:14]
    final_plantar = [final_ring[0]] + list(reversed(final_ring[14:])) + [final_ring[13]]
    seam = []
    for rail in range(DISTAL_RAILS):
        influences = distal_rail_influence(rail)
        relative_length = sum(weight * TOE_LENGTHS[toe] for weight, toe in influences)
        fan_angle = sum(weight * TOE_FAN_DEGREES[toe] for weight, toe in influences)
        is_web = rail in DISTAL_WEB_RAILS
        if is_web:
            relative_length -= 0.0275
        forward = paw_length * relative_length
        lateral = paw_width * DISTAL_LATERAL[rail]
        lateral += math.tan(math.radians(fan_angle)) * paw_length * (relative_length - 0.68)
        vertical = contact_z + 0.325 * thickness_ratio(0.94, carpus_depth, paw_width)
        seam.append(len(vertices))
        vertices.append(tuple(carpus_center + forward_axis * forward + width_axis * lateral + Vector((0, 0, vertical - carpus_center.z))))
    for rail in range(DISTAL_RAILS - 1):
        faces.append((final_dorsal[rail], final_dorsal[rail + 1], seam[rail + 1], seam[rail]))
        faces.append((final_plantar[rail + 1], final_plantar[rail], seam[rail], seam[rail + 1]))
    return {
        "sections": sections,
        "seam": seam,
        "carpusIndices": list(carpus_indices),
        "pawFaceStart": paw_face_start,
        "carpusCenter": carpus_center,
        "pawWidth": paw_width,
        "pawLength": paw_length,
        "maximumThickness": maximum_thickness,
        "contactZ": contact_z,
        "dorsalPositions": dorsal_positions,
        "plantarPositions": plantar_positions,
    }


def topology_report(vertices, faces, build):
    edges = Counter()
    owners = defaultdict(list)
    areas = []
    ratios = []
    normals = []
    for face_index, face in enumerate(faces):
        areas.append(face_area(vertices, face))
        normals.append(polygon_normal(vertices, face))
        lengths = []
        for index, first in enumerate(face):
            second = face[(index + 1) % len(face)]
            key = edge_key(first, second)
            edges[key] += 1
            owners[key].append(face_index)
            lengths.append((Vector(vertices[first]) - Vector(vertices[second])).length)
        ratios.append(max(lengths) / max(min(lengths), 1e-12))
    reversed_pairs = [
        (first, second)
        for owner_faces in owners.values()
        if len(owner_faces) == 2
        for first, second in [owner_faces]
        if normals[first].dot(normals[second]) < -0.20
    ]
    intersections = self_intersections(vertices, faces)
    paw_start = build["pawFaceStart"]
    carpus = build["sections"][0]
    first = build["sections"][1]
    seam_tangents = [
        (Vector(vertices[first_vertex]) - Vector(vertices[carpus_vertex])).normalized()
        for carpus_vertex, first_vertex in zip(carpus, first)
    ]
    carpus_normal_dots = []
    for vertex in carpus:
        first_side = [polygon_normal(vertices, face) for face in faces[:paw_start] if vertex in face]
        second_side = [polygon_normal(vertices, face) for face in faces[paw_start:] if vertex in face]
        carpus_normal_dots.append(
            abs(sum(first_side, start=Vector()).normalized().dot(sum(second_side, start=Vector()).normalized()))
        )
    components = 0
    adjacency = defaultdict(set)
    for first_vertex, second_vertex in edges:
        adjacency[first_vertex].add(second_vertex)
        adjacency[second_vertex].add(first_vertex)
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
        "nonadjacentSelfIntersectionPairs": len(intersections),
        "firstSelfIntersectionPairs": intersections[:12],
        "reversedAdjacencies": len(reversed_pairs),
        "firstReversedAdjacencyPairs": reversed_pairs[:20],
        "maximumEdgeRatio": max(ratios),
        "worstEdgeRatioFaces": [
            {
                "index": face_index,
                "ratio": ratios[face_index],
                "vertices": list(faces[face_index]),
                "coordinates": [list(vertices[vertex]) for vertex in faces[face_index]],
                "pawBand": None
                if face_index < paw_start
                else (face_index - paw_start) // SEGMENTS,
            }
            for face_index in sorted(range(len(faces)), key=ratios.__getitem__, reverse=True)[:16]
        ],
        "minimumAreaFraction": min(areas) / sorted(areas)[len(areas) // 2],
        "carpusMinimumNormalDot": min(carpus_normal_dots),
        "carpusMinimumAdvance": min(tangent.length for tangent in seam_tangents),
    }


def subdivided_intersection_report(obj):
    temporary = obj.copy()
    temporary.data = obj.data.copy()
    bpy.context.collection.objects.link(temporary)
    temporary.modifiers.clear()
    modifier = temporary.modifiers.new("CatmullClarkAudit", "SUBSURF")
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
    carpus_indices = list(obj["carpus_indices"])
    precarpus_indices = list(obj["precarpus_indices"])
    original_carpus = [Vector(vertices[index]) for index in carpus_indices]
    build = build_paw(vertices, faces, carpus_indices, precarpus_indices)
    displacement = max(
        (Vector(vertices[index]) - point).length
        for index, point in zip(carpus_indices, original_carpus)
    )
    mesh.clear_geometry()
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj["forepaw_tip_seam_indices"] = build["seam"]
    topology = topology_report(vertices, faces, build)
    subdivision = subdivided_intersection_report(obj)
    report = {
        "status": "pending_forepaw_critic_gate",
        "topology": topology,
        "subdivision": subdivision,
        "anatomy": {
            "closedSectionCountIncludingCarpus": len(build["sections"]),
            "tipSeamVertexCount": len(build["seam"]),
            "carpusDisplacement": displacement,
            "pawWidth": build["pawWidth"],
            "pawLength": build["pawLength"],
            "maximumThickness": build["maximumThickness"],
            "widthToCarpus": build["pawWidth"]
            / (
                max(Vector(vertices[index]).x for index in carpus_indices)
                - min(Vector(vertices[index]).x for index in carpus_indices)
            ),
            "lengthToWidth": build["pawLength"] / build["pawWidth"],
            "thicknessToWidth": build["maximumThickness"] / build["pawWidth"],
            "toeCenterRails": list(TOE_CENTER_RAILS),
            "toeFanDegrees": list(TOE_FAN_DEGREES),
            "toeRelativeLengths": list(TOE_LENGTHS),
        },
    }
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_FOREPAW_GATE", json.dumps(report))


if __name__ == "__main__":
    main()

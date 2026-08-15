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
DISTAL_RAILS = 19
ANATOMY_PARAMETERS = (0.00, 0.04, 0.08, 0.13, 0.18, 0.265, 0.35, 0.45, 0.55, 0.625, 0.70, 0.76, 0.82)
SECTION_PARAMETERS = (
    0.00, 0.04, 0.08, 0.12, 0.16, 0.22, 0.28, 0.34, 0.42, 0.45,
    0.475, 0.515, 0.555, 0.595, 0.635, 0.675, 0.72, 0.765,
    0.81,
)
WIDTH_RATIOS = (1.00, 0.98, 0.95, 1.05, 1.15, 1.26, 1.35, 1.41, 1.44, 1.44, 1.42, 1.39, 1.35)
THICKNESS_RATIOS = (0.78, 0.84, 0.90, 0.96, 1.00, 1.00, 0.98, 0.92, 0.84, 0.76, 0.70, 0.66, 0.62)
LANE_COEFFICIENTS = (0.0, 0.35, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, 0.35, 0.0)
TOE_CENTER_RAILS = (2, 4, 6, 8, 10)
TOE_LATERAL = (-0.38, -0.19, 0.0, 0.19, 0.38)
TOE_FAN_DEGREES = (-8.0, -4.0, 0.0, 4.0, 8.0)
TOE_LENGTHS = (0.89, 0.96, 1.00, 0.96, 0.89)
DISTAL_LATERAL = (-0.485, -0.415, -0.345, -0.3225, -0.30, -0.2225, -0.145, -0.1225, -0.10, 0.0, 0.10, 0.1225, 0.145, 0.2225, 0.30, 0.3225, 0.345, 0.415, 0.485)
DISTAL_TOE_TRIPLETS = ((0, 1, 2), (4, 5, 6), (8, 9, 10), (12, 13, 14), (16, 17, 18))
DISTAL_TOE_CENTERS = (1, 5, 9, 13, 17)
DISTAL_WEB_RAILS = (3, 7, 11, 15)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    return parser.parse_args(sys.argv[sys.argv.index("--") + 1 :])


def edge_key(first, second):
    return tuple(sorted((first, second)))


def polygon_normal(vertices, face):
    points = [Vector(vertices[index]) for index in face]
    normal = sum(
        ((points[index] - points[0]).cross(points[index + 1] - points[0])
         for index in range(1, len(points) - 1)),
        start=Vector(),
    )
    return normal.normalized()


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


def smootherstep(first, second, value):
    factor = max(0.0, min(1.0, (value - first) / (second - first)))
    return factor**3 * (factor * (factor * 6.0 - 15.0) + 10.0)


def palm_outer_compression(parameter, normalized_lateral):
    if parameter <= 0.52:
        longitudinal = smootherstep(0.28, 0.52, parameter)
    else:
        longitudinal = 1.0 - smootherstep(0.52, 0.76, parameter)
    lateral = smootherstep(0.55, 1.0, abs(normalized_lateral))
    return 1.0 - 0.08 * longitudinal * lateral


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


def interpolate_controls(controls, factor):
    if factor <= controls[0][0]:
        return controls[0][1]
    for (first_u, first_value), (second_u, second_value) in zip(controls, controls[1:]):
        if first_u <= factor <= second_u:
            local = smootherstep(first_u, second_u, factor)
            return first_value * (1.0 - local) + second_value * local
    return controls[-1][1]


def distal_phase(parameter):
    controls = (
        (0.68, 0.00),
        (0.72, 0.18),
        (0.76, 0.38),
        (0.84, 0.72),
        (0.88, 0.88),
        (0.90, 0.90),
        (0.94, 0.94),
        (1.00, 1.00),
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
        (0.00, 0.68),
        (0.18, 0.72),
        (0.35, 0.88),
        (0.58, 1.00),
        (0.78, 0.94),
        (0.81, 0.84),
    )
    for (first_u, first_value), (second_u, second_value) in zip(controls, controls[1:]):
        if first_u <= parameter <= second_u:
            factor = smoothstep(first_u, second_u, parameter)
            return first_value * (1.0 - factor) + second_value * factor
    return controls[-1][1]


def thickness_ratio(parameter, carpus_depth, paw_width):
    maximum_thickness = paw_width * 1.52 * 0.26
    controls = (
        (0.00, carpus_depth),
        (0.10, carpus_depth),
        (0.18, carpus_depth * 1.02),
        (0.28, carpus_depth * 1.08),
        (0.35, maximum_thickness * 0.88),
        (0.55, maximum_thickness),
        (0.70, maximum_thickness * 0.96),
        (0.81, maximum_thickness * 0.84),
    )
    for (first_u, first_value), (second_u, second_value) in zip(controls, controls[1:]):
        if first_u <= parameter <= second_u:
            factor = smoothstep(first_u, second_u, parameter)
            return first_value * (1.0 - factor) + second_value * factor
    return controls[-1][1]


def plantar_height_ratio(parameter):
    return interpolate_controls(
        ((0.48, 0.18), (0.58, 0.05), (0.68, 0.00), (0.88, 0.00), (0.94, 0.02), (1.00, 0.07)),
        parameter,
    )


def dorsal_span_ratio(parameter):
    return interpolate_controls(
        ((0.48, 0.90), (0.58, 1.00), (0.70, 0.96), (0.81, 0.84), (0.88, 0.68), (0.94, 0.44), (1.00, 0.21)),
        parameter,
    )


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


def quadratic_extrapolation(first, second, third, first_distance, second_distance, distance):
    first_x = -(first_distance + second_distance)
    second_x = -second_distance
    third_x = 0.0
    first_weight = (distance - second_x) * (distance - third_x) / ((first_x - second_x) * (first_x - third_x))
    second_weight = (distance - first_x) * (distance - third_x) / ((second_x - first_x) * (second_x - third_x))
    third_weight = (distance - first_x) * (distance - second_x) / ((third_x - first_x) * (third_x - second_x))
    return first * first_weight + second * second_weight + third * third_weight


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
    lateral = 0.5 * paw_width * width_normalized * palm_outer_compression(parameter, width_normalized)
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
    for toe_index, triplet in enumerate(DISTAL_TOE_TRIPLETS):
        if rail in triplet:
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
    contact_z,
):
    uniform_lateral = rail / (DISTAL_RAILS - 1) - 0.5
    spacing_blend = smoothstep(0.475, 0.66, parameter)
    lateral_normalized = uniform_lateral * (1.0 - spacing_blend) + DISTAL_LATERAL[rail] * spacing_blend
    lateral = paw_width * lateral_normalized * palm_outer_compression(parameter, lateral_normalized / 0.5)
    toe_phase = distal_phase(parameter)
    influences = distal_rail_influence(rail)
    relative_length = sum(weight * TOE_LENGTHS[toe] for weight, toe in influences)
    fan_angle = sum(weight * TOE_FAN_DEGREES[toe] for weight, toe in influences)
    is_web = rail in DISTAL_WEB_RAILS
    if is_web:
        web_index = DISTAL_WEB_RAILS.index(rail)
        target_length = min(TOE_LENGTHS[web_index], TOE_LENGTHS[web_index + 1]) - 0.03
    else:
        target_length = relative_length
    desired_parameter = 0.68 + toe_phase * (target_length - 0.68)
    toe_progress = (desired_parameter - 0.68) / max(target_length - 0.68, 1e-8)
    terminal_width = interpolate_controls(
        ((0.00, 1.00), (0.60, 1.00), (0.72, 1.04), (0.84, 1.00), (0.88, 1.00), (0.94, 0.72), (1.00, 0.58)),
        toe_progress,
    )
    matched_toe_index = None
    for toe_index, triplet in enumerate(DISTAL_TOE_TRIPLETS):
        if rail in triplet:
            matched_toe_index = toe_index
            triplet_center = DISTAL_LATERAL[triplet[1]]
            contracted = triplet_center + (DISTAL_LATERAL[rail] - triplet_center) * terminal_width
            lateral_normalized += (contracted - DISTAL_LATERAL[rail]) * spacing_blend
            lateral = paw_width * lateral_normalized * palm_outer_compression(parameter, lateral_normalized / 0.5)
            break
    forward = (desired_parameter - parameter) * paw_length if toe_phase > 0.0 else 0.0
    if toe_phase > 0.0:
        lateral += math.tan(math.radians(fan_angle)) * (desired_parameter - 0.68) * paw_length
    crown = max(0.0, 1.0 - (lateral_normalized / 0.5) ** 2) ** 2
    toe_relief = interpolate_controls(
        ((0.00, 0.00), (0.62, 0.00), (0.68, 0.03), (0.75, 0.07), (0.81, 0.09)),
        parameter,
    )
    terminal_thickness = interpolate_controls(
        ((0.00, 1.00), (0.72, 1.00), (0.75, 0.85), (0.88, 0.60), (0.91, 0.55), (0.94, 0.40), (0.97, 0.28), (1.00, 0.19)),
        toe_progress,
    )
    is_toe_center = rail in DISTAL_TOE_CENTERS
    pad_window = smoothstep(0.60, 0.68, toe_progress) * (1.0 - smoothstep(0.94, 1.00, toe_progress))
    web_relief = interpolate_controls(
        ((0.00, 0.00), (0.62, 0.00), (0.68, -0.02), (0.75, -0.04), (0.81, -0.05)),
        parameter,
    )
    if is_dorsal:
        vertical = thickness * terminal_thickness * 0.50 * crown
        if is_web:
            vertical += thickness * web_relief
        elif is_toe_center:
            vertical += thickness * toe_relief
    else:
        vertical = thickness * terminal_thickness * -0.50 * crown
        if is_toe_center:
            vertical -= thickness * 0.10 * pad_window
        elif is_web:
            vertical += thickness * 0.08 * pad_window
        elif matched_toe_index is not None:
            vertical += thickness * 0.04 * pad_window
    if rail in (0, DISTAL_RAILS - 1):
        vertical = 0.0
    point = center + forward_axis * forward + width_axis * lateral + thickness_axis * vertical
    envelope_blend = smootherstep(0.48, 0.58, parameter)
    if envelope_blend > 0.0:
        maximum_thickness = paw_length * 0.26
        plantar_height = plantar_height_ratio(parameter) * maximum_thickness
        dorsal_span = dorsal_span_ratio(parameter) * maximum_thickness
        midpoint_height = contact_z + plantar_height + 0.5 * dorsal_span
        is_world_dorsal = (1.0 if is_dorsal else -1.0) * thickness_axis.z > 0.0
        target_z = midpoint_height + (0.5 if is_world_dorsal else -0.5) * dorsal_span * crown
        if is_world_dorsal:
            if is_toe_center:
                target_z += toe_relief * maximum_thickness
            elif is_web:
                target_z += web_relief * maximum_thickness
        else:
            if is_toe_center:
                target_z -= 0.10 * pad_window * maximum_thickness
            elif is_web:
                target_z += 0.08 * pad_window * maximum_thickness
        point.z = point.z * (1.0 - envelope_blend) + target_z * envelope_blend
    return point


def connect_transition(faces, first_ring, second_ring):
    split_columns = {4, 6, 8, 16, 18, 20}
    second_index = 0
    for first_index in range(24):
        if first_index in split_columns:
            faces.append((
                first_ring[first_index],
                second_ring[(second_index + 2) % 36],
                second_ring[(second_index + 1) % 36],
                second_ring[second_index % 36],
            ))
            second_index += 2
        faces.append((
            first_ring[first_index],
            first_ring[(first_index + 1) % 24],
            second_ring[(second_index + 1) % 36],
            second_ring[second_index % 36],
        ))
        second_index += 1


def build_paw(vertices, faces, carpus_indices, precarpus_indices):
    carpus_points = [Vector(vertices[index]) for index in carpus_indices]
    carpus_center = sum(carpus_points, start=Vector()) / SEGMENTS
    cycle, dorsal_path, plantar_path = carpus_paths(vertices, carpus_indices)
    previous_by_carpus = {
        carpus: precarpus
        for carpus, precarpus in zip(carpus_indices, precarpus_indices)
    }
    preprecarpus_indices = [index - SEGMENTS for index in precarpus_indices]
    preprecarpus_by_carpus = {
        carpus: preprecarpus
        for carpus, preprecarpus in zip(carpus_indices, preprecarpus_indices)
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
    maximum_thickness = paw_length * 0.26
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
    preprecarpus_points = [Vector(vertices[index]) for index in preprecarpus_indices]
    preprecarpus_center = sum(preprecarpus_points, start=Vector()) / SEGMENTS
    prior_tangent = (precarpus_center - preprecarpus_center).normalized()
    incoming_turn = prior_tangent.angle(incoming_tangent)
    incoming_spacing = 0.5 * (
        (precarpus_center - preprecarpus_center).length
        + (carpus_center - precarpus_center).length
    )
    wrist_curvature = incoming_turn / max(incoming_spacing, 1e-8)
    bend_direction = incoming_tangent - prior_tangent
    bend_direction -= incoming_tangent * bend_direction.dot(incoming_tangent)
    if bend_direction.length < 1e-8:
        bend_direction = thickness_axis.copy()
    else:
        bend_direction.normalize()
    bend_radius = max(abs((point - carpus_center).dot(bend_direction)) for point in carpus_points)
    wrist_curvature = min(wrist_curvature, 0.55 / max(bend_radius, 1e-8))
    sections = [list(cycle)]
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
        frame_blend = smootherstep(0.55, 0.72, parameter)
        contact_thickness_axis = Vector((0.0, 0.0, 1.0))
        contact_thickness_axis -= tangent * contact_thickness_axis.dot(tangent)
        contact_thickness_axis.normalize()
        if contact_thickness_axis.dot(section_thickness_axis) < 0.0:
            contact_thickness_axis.negate()
        section_thickness_axis = section_thickness_axis.lerp(contact_thickness_axis, frame_blend).normalized()
        section_width_axis = section_thickness_axis.cross(tangent).normalized()
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
                    section_thickness_axis, width, paw_length, thickness, contact_z,
                )
                for rail in range(DISTAL_RAILS)
            ]
            distal_plantar = [
                distal_section_point(
                    rail, False, parameter, center, forward_axis, section_width_axis,
                    section_thickness_axis, width, paw_length, thickness, contact_z,
                )
                for rail in range(DISTAL_RAILS)
            ]
            for edge_rail in (0, DISTAL_RAILS - 1):
                shared = 0.5 * (distal_dorsal[edge_rail] + distal_plantar[edge_rail])
                distal_dorsal[edge_rail] = shared
                distal_plantar[edge_rail] = shared
            ring_points = distal_dorsal + list(reversed(distal_plantar[1:-1]))
        if len(ring_points) == SEGMENTS and parameter <= 0.34:
            correction = 0.0 if parameter <= 0.12 else smootherstep(0.12, 0.32, parameter)
            wrist_distance = parameter * paw_length
            integration_steps = max(8, math.ceil(wrist_distance / max(0.01 * paw_length, 1e-8)))
            step_length = wrist_distance / integration_steps
            wrist_center = carpus_center.copy()
            wrist_angle = 0.0
            for _ in range(integration_steps):
                midpoint_angle = wrist_angle + 0.5 * wrist_curvature * step_length
                midpoint_tangent = (
                    incoming_tangent * math.cos(midpoint_angle)
                    + bend_direction * math.sin(midpoint_angle)
                ).normalized()
                wrist_center += midpoint_tangent * step_length
                wrist_angle += wrist_curvature * step_length
            wrist_tangent = (
                incoming_tangent * math.cos(wrist_angle)
                + bend_direction * math.sin(wrist_angle)
            ).normalized()
            wrist_width_axis = (width_axis - wrist_tangent * width_axis.dot(wrist_tangent)).normalized()
            wrist_thickness_axis = wrist_tangent.cross(wrist_width_axis).normalized()
            for position, target_point in enumerate(ring_points):
                relative = Vector(vertices[cycle[position]]) - carpus_center
                continuation = (
                    wrist_center
                    + wrist_width_axis * relative.dot(width_axis)
                    + wrist_thickness_axis * relative.dot(thickness_axis)
                )
                ring_points[position] = continuation.lerp(target_point, correction)
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
    final_dorsal = final_ring[:DISTAL_RAILS]
    final_plantar = [final_ring[0]] + list(reversed(final_ring[DISTAL_RAILS:])) + [final_ring[DISTAL_RAILS - 1]]
    final_midpoints = [
        0.5 * (Vector(vertices[dorsal]) + Vector(vertices[plantar]))
        for dorsal, plantar in zip(final_dorsal, final_plantar)
    ]
    terminal_parameter = SECTION_PARAMETERS[-1]
    tip_base_thickness = paw_length * 0.26
    seam = []
    toe_roots = {}
    profile_cache = {}

    def vertical_profile(dorsal_index, plantar_index):
        key = (dorsal_index, plantar_index)
        if key in profile_cache:
            return profile_cache[key]
        if dorsal_index == plantar_index:
            profile_cache[key] = [dorsal_index]
            return profile_cache[key]
        dorsal_point = Vector(vertices[dorsal_index])
        plantar_point = Vector(vertices[plantar_index])
        profile = [dorsal_index]
        for factor in (1.0 / 3.0, 2.0 / 3.0):
            profile.append(len(vertices))
            vertices.append(tuple(dorsal_point.lerp(plantar_point, factor)))
        profile.append(plantar_index)
        profile_cache[key] = profile
        return profile

    def connect_profiles(first_profile, second_profile):
        if len(first_profile) == 1:
            for index in range(len(second_profile) - 1):
                faces.append((first_profile[0], second_profile[index], second_profile[index + 1]))
            return
        if len(second_profile) == 1:
            for index in range(len(first_profile) - 1):
                faces.append((first_profile[index], second_profile[0], first_profile[index + 1]))
            return
        for index in range(len(first_profile) - 1):
            faces.append((first_profile[index], second_profile[index], second_profile[index + 1], first_profile[index + 1]))

    for toe_index, triplet in enumerate(DISTAL_TOE_TRIPLETS):
        final_target = TOE_LENGTHS[toe_index]
        final_desired = max(0.68, final_target - 0.04)
        common_desired = 0.68 + distal_phase(terminal_parameter) * (final_target - 0.68)
        center_midpoint = final_midpoints[triplet[1]]
        fan_angle = math.radians(TOE_FAN_DEGREES[toe_index])

        def cap_row(stage, width_scale, thickness_scale, nose_bulge=0.0):
            desired = final_desired + stage * (final_target - final_desired)
            stage_center = center_midpoint + forward_axis * ((desired - common_desired) * paw_length)
            stage_center += width_axis * (math.tan(fan_angle) * (desired - common_desired) * paw_length)
            dorsal_row = []
            plantar_row = []
            for local_rail, rail in enumerate(triplet):
                lateral_delta = (final_midpoints[rail] - center_midpoint).dot(width_axis)
                base = stage_center + width_axis * lateral_delta * width_scale
                is_center = local_rail == 1
                if is_center:
                    base += forward_axis * nose_bulge
                is_outer_edge = rail in (0, DISTAL_RAILS - 1)
                if is_outer_edge:
                    outer_shift = interpolate_controls(
                        ((0.00, 0.00), (1.00, 0.00)),
                        stage,
                    ) * paw_length
                    base += width_axis * (-1.0 if lateral_delta > 0.0 else 1.0) * outer_shift
                stage_parameter = 0.88 + 0.12 * stage
                plantar_z = contact_z + plantar_height_ratio(stage_parameter) * tip_base_thickness
                if not is_center:
                    plantar_z += 0.04 * tip_base_thickness
                dorsal_z = plantar_z + thickness_scale * tip_base_thickness * (1.0 if is_center else 0.84)
                if is_center:
                    dorsal_z += 0.04 * (1.0 - stage) * tip_base_thickness
                source_dorsal_is_upper = (
                    Vector(vertices[final_dorsal[rail]]).z
                    >= Vector(vertices[final_plantar[rail]]).z
                )
                if is_outer_edge:
                    shared_index = len(vertices)
                    base.z = 0.5 * (dorsal_z + plantar_z)
                    vertices.append(tuple(base))
                    dorsal_row.append(shared_index)
                    plantar_row.append(shared_index)
                else:
                    dorsal_point = base.copy()
                    plantar_point = base.copy()
                    dorsal_point.z = dorsal_z if source_dorsal_is_upper else plantar_z
                    plantar_point.z = plantar_z if source_dorsal_is_upper else dorsal_z
                    dorsal_row.append(len(vertices))
                    vertices.append(tuple(dorsal_point))
                    plantar_row.append(len(vertices))
                    vertices.append(tuple(plantar_point))
            return dorsal_row, plantar_row

        cap_rows = [
            cap_row(0.00, 1.00, 0.60),
            cap_row(0.25, 0.86, 0.58),
            cap_row(0.50, 0.72, 0.43),
            cap_row(0.75, 0.63, 0.30, 0.004 * paw_width),
            cap_row(1.00, 0.56, 0.21, 0.012 * paw_width),
        ]
        toe_roots[toe_index] = cap_rows[0]
        toe_dorsal, toe_plantar = cap_rows[-1]
        row_pairs = [
            (source_dorsal, source_plantar, target_dorsal, target_plantar)
            for (source_dorsal, source_plantar), (target_dorsal, target_plantar)
            in zip(cap_rows, cap_rows[1:])
        ]
        source_common = ([final_dorsal[rail] for rail in triplet], [final_plantar[rail] for rail in triplet])
        row_pairs.insert(0, (*source_common, *cap_rows[0]))
        for pair_index, (source_dorsal, source_plantar, target_dorsal, target_plantar) in enumerate(row_pairs):
            for local_rail in range(2):
                faces.append((source_dorsal[local_rail], source_dorsal[local_rail + 1], target_dorsal[local_rail + 1], target_dorsal[local_rail]))
                faces.append((source_plantar[local_rail + 1], source_plantar[local_rail], target_plantar[local_rail], target_plantar[local_rail + 1]))
            if pair_index > 0:
                for local_rail in (0, 2):
                    rail = triplet[local_rail]
                    if rail not in (0, DISTAL_RAILS - 1):
                        connect_profiles(
                            vertical_profile(source_dorsal[local_rail], source_plantar[local_rail]),
                            vertical_profile(target_dorsal[local_rail], target_plantar[local_rail]),
                        )
        tip_profiles = [
            vertical_profile(toe_dorsal[local_rail], toe_plantar[local_rail])
            for local_rail in range(3)
        ]
        connect_profiles(tip_profiles[0], tip_profiles[1])
        connect_profiles(tip_profiles[1], tip_profiles[2])
        seam.extend(toe_dorsal)
        seam.extend(toe_plantar)
    for web_index, web_rail in enumerate(DISTAL_WEB_RAILS):
        left_root_dorsal, left_root_plantar = toe_roots[web_index]
        right_root_dorsal, right_root_plantar = toe_roots[web_index + 1]
        web_target = min(TOE_LENGTHS[web_index], TOE_LENGTHS[web_index + 1]) - 0.03
        common_web_desired = 0.68 + distal_phase(terminal_parameter) * (web_target - 0.68)
        web_fan = math.radians(0.5 * (TOE_FAN_DEGREES[web_index] + TOE_FAN_DEGREES[web_index + 1]))
        web_midpoint = final_midpoints[web_rail]
        web_midpoint += forward_axis * ((web_target - common_web_desired) * paw_length)
        web_midpoint += width_axis * (math.tan(web_fan) * (web_target - common_web_desired) * paw_length)
        adjacent_upper = min(
            max(Vector(vertices[left_root_dorsal[2]]).z, Vector(vertices[left_root_plantar[2]]).z),
            max(Vector(vertices[right_root_dorsal[0]]).z, Vector(vertices[right_root_plantar[0]]).z),
        )
        adjacent_lower = max(
            min(Vector(vertices[left_root_dorsal[2]]).z, Vector(vertices[left_root_plantar[2]]).z),
            min(Vector(vertices[right_root_dorsal[0]]).z, Vector(vertices[right_root_plantar[0]]).z),
        )
        web_upper = adjacent_upper - 0.10 * tip_base_thickness
        web_lower = adjacent_lower + 0.04 * tip_base_thickness
        if web_upper <= web_lower:
            midpoint_z = 0.5 * (web_upper + web_lower)
            web_upper = midpoint_z + 0.01 * tip_base_thickness
            web_lower = midpoint_z - 0.01 * tip_base_thickness
        source_dorsal_is_upper = (
            Vector(vertices[final_dorsal[web_rail]]).z
            >= Vector(vertices[final_plantar[web_rail]]).z
        )
        target_dorsal = web_midpoint.copy()
        target_plantar = web_midpoint.copy()
        target_dorsal.z = web_upper if source_dorsal_is_upper else web_lower
        target_plantar.z = web_lower if source_dorsal_is_upper else web_upper
        web_axis = (
            Vector(vertices[final_dorsal[web_rail]])
            - Vector(vertices[final_plantar[web_rail]])
        ).normalized()
        old_midpoint = web_midpoint + web_axis * (0.06 * tip_base_thickness)
        old_dorsal = old_midpoint + web_axis * (0.16 * tip_base_thickness)
        old_plantar = old_midpoint - web_axis * (0.16 * tip_base_thickness)
        burial_factor = 0.0
        dorsal_point = old_dorsal.lerp(target_dorsal, burial_factor)
        plantar_point = old_plantar.lerp(target_plantar, burial_factor)
        web_dorsal = len(vertices)
        vertices.append(tuple(dorsal_point))
        web_plantar = len(vertices)
        vertices.append(tuple(plantar_point))
        left_rail = web_rail - 1
        right_rail = web_rail + 1
        faces.append((final_dorsal[left_rail], final_dorsal[web_rail], web_dorsal, left_root_dorsal[2]))
        faces.append((final_dorsal[web_rail], final_dorsal[right_rail], right_root_dorsal[0], web_dorsal))
        faces.append((final_plantar[web_rail], final_plantar[left_rail], left_root_plantar[2], web_plantar))
        faces.append((final_plantar[right_rail], final_plantar[web_rail], web_plantar, right_root_plantar[0]))
        web_profile = vertical_profile(web_dorsal, web_plantar)
        connect_profiles(vertical_profile(left_root_dorsal[2], left_root_plantar[2]), web_profile)
        connect_profiles(web_profile, vertical_profile(right_root_dorsal[0], right_root_plantar[0]))
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
            "toeCenterRails": list(DISTAL_TOE_CENTERS),
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

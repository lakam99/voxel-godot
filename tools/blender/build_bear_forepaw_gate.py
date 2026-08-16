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
    prior_dorsal_start = previous_by_carpus[dorsal_path[0]]
    prior_dorsal_end = previous_by_carpus[dorsal_path[-1]]
    prior_width_axis = (
        Vector(vertices[prior_dorsal_end]) - Vector(vertices[prior_dorsal_start])
    )
    prior_width_axis = (
        prior_width_axis - prior_tangent * prior_width_axis.dot(prior_tangent)
    ).normalized()
    prior_thickness_axis = prior_tangent.cross(prior_width_axis).normalized()

    def ring_extent(indices, center_point, axis):
        coordinates = [(Vector(vertices[index]) - center_point).dot(axis) for index in indices]
        return max(coordinates) - min(coordinates)

    carpus_width_extent = ring_extent(cycle, carpus_center, width_axis)
    carpus_depth_extent = ring_extent(cycle, carpus_center, thickness_axis)
    prior_cycle = [previous_by_carpus[index] for index in cycle]
    prior_width_extent = ring_extent(prior_cycle, precarpus_center, prior_width_axis)
    prior_depth_extent = ring_extent(prior_cycle, precarpus_center, prior_thickness_axis)
    width_scale_derivative = (carpus_width_extent - prior_width_extent) / max(carpus_width_extent, 1e-8)
    depth_scale_derivative = (carpus_depth_extent - prior_depth_extent) / max(carpus_depth_extent, 1e-8)
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
            if parameter < SECTION_PARAMETERS[-1]:
                for edge_rail in (0, DISTAL_RAILS - 1):
                    shared = 0.5 * (distal_dorsal[edge_rail] + distal_plantar[edge_rail])
                    distal_dorsal[edge_rail] = shared
                    distal_plantar[edge_rail] = shared
                ring_points = distal_dorsal + list(reversed(distal_plantar[1:-1]))
            else:
                topology_vertical_sign = (
                    1.0 if distal_dorsal[1].z >= distal_plantar[1].z else -1.0
                )
                outer_profile_half_span = 0.20 * maximum_thickness
                for edge_rail in (0, DISTAL_RAILS - 1):
                    midpoint = 0.5 * (
                        distal_dorsal[edge_rail] + distal_plantar[edge_rail]
                    )
                    distal_dorsal[edge_rail].z = (
                        midpoint.z + topology_vertical_sign * outer_profile_half_span
                    )
                    distal_plantar[edge_rail].z = (
                        midpoint.z - topology_vertical_sign * outer_profile_half_span
                    )
                left_midpoint = 0.5 * (distal_dorsal[0] + distal_plantar[0])
                right_midpoint = 0.5 * (distal_dorsal[-1] + distal_plantar[-1])
                ring_points = (
                    distal_dorsal
                    + [right_midpoint]
                    + list(reversed(distal_plantar))
                    + [left_midpoint]
                )
        if len(ring_points) == SEGMENTS and parameter <= 0.34:
            correction = 0.0 if parameter <= 0.13 else smootherstep(0.13, 0.32, parameter)
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
            incoming_spacing_ratio = wrist_distance / max(
                (carpus_center - precarpus_center).length, 1e-8
            )
            width_scale = 1.0 + width_scale_derivative * incoming_spacing_ratio
            depth_scale = 1.0 + depth_scale_derivative * incoming_spacing_ratio
            for position, target_point in enumerate(ring_points):
                relative = Vector(vertices[cycle[position]]) - carpus_center
                continuation = (
                    wrist_center
                    + wrist_width_axis * relative.dot(width_axis) * width_scale
                    + wrist_thickness_axis * relative.dot(thickness_axis) * depth_scale
                )
                ring_points[position] = continuation.lerp(target_point, correction)
        indices = list(range(len(vertices), len(vertices) + len(ring_points)))
        vertices.extend(tuple(point) for point in ring_points)
        sections.append(indices)
    paw_face_start = len(faces)
    for first_ring, second_ring in zip(sections, sections[1:]):
        if len(first_ring) == 36 and len(second_ring) == 40:
            first_dorsal = first_ring[:DISTAL_RAILS]
            first_plantar = [first_ring[0]] + list(reversed(first_ring[DISTAL_RAILS:])) + [first_ring[DISTAL_RAILS - 1]]
            second_dorsal = second_ring[:DISTAL_RAILS]
            second_plantar = list(reversed(second_ring[20:39]))
            for rail in range(DISTAL_RAILS - 1):
                faces.append((first_dorsal[rail], first_dorsal[rail + 1], second_dorsal[rail + 1], second_dorsal[rail]))
                faces.append((first_plantar[rail + 1], first_plantar[rail], second_plantar[rail], second_plantar[rail + 1]))
            faces.append((first_dorsal[0], second_dorsal[0], second_ring[39], second_plantar[0]))
            faces.append((first_dorsal[-1], second_plantar[-1], second_ring[19], second_dorsal[-1]))
            continue
        if len(first_ring) != len(second_ring):
            connect_transition(faces, first_ring, second_ring)
            continue
        for index in range(len(first_ring)):
            following = (index + 1) % len(first_ring)
            faces.append((first_ring[index], first_ring[following], second_ring[following], second_ring[index]))

    final_ring = sections[-1]
    final_dorsal = final_ring[:DISTAL_RAILS]
    final_plantar = list(reversed(final_ring[20:39]))
    final_outer_midpoints = (final_ring[39], final_ring[19])
    final_midpoints = [
        0.5 * (Vector(vertices[dorsal]) + Vector(vertices[plantar]))
        for dorsal, plantar in zip(final_dorsal, final_plantar)
    ]
    terminal_parameter = SECTION_PARAMETERS[-1]
    tip_base_thickness = paw_length * 0.26

    def build_closed_toe_tubes():
        seam = []
        toe_sources = {}
        toe_rings = {}
        row_specs = (
            (0.86, 1.05, 1.04, 0.060),
            (0.90, 1.00, 1.00, 0.003),
            (0.94, 0.86, 0.86, 0.010),
            (0.97, 0.62, 0.58, 0.025),
            (1.00, 0.45, 0.40, 0.040),
        )
        ring_profile = (
            (-math.sqrt(0.5), math.sqrt(0.5)),
            (0.0, 1.0),
            (math.sqrt(0.5), math.sqrt(0.5)),
            (1.0, 0.0),
            (math.sqrt(0.5), -math.sqrt(0.5)),
            (0.0, -1.0),
            (-math.sqrt(0.5), -math.sqrt(0.5)),
            (-1.0, 0.0),
        )
        for toe_index, triplet in enumerate(DISTAL_TOE_TRIPLETS):
            center_dorsal = Vector(vertices[final_dorsal[triplet[1]]])
            center_plantar = Vector(vertices[final_plantar[triplet[1]]])
            if center_dorsal.z >= center_plantar.z:
                source_upper = [final_dorsal[rail] for rail in triplet]
                source_lower = [final_plantar[rail] for rail in triplet]
            else:
                source_upper = [final_plantar[rail] for rail in triplet]
                source_lower = [final_dorsal[rail] for rail in triplet]
            toe_sources[toe_index] = (source_upper, source_lower)
            source_center = final_midpoints[triplet[1]]
            source_thickness = abs(center_dorsal.z - center_plantar.z)
            left_half_width = abs((final_midpoints[triplet[0]] - source_center).dot(width_axis))
            right_half_width = abs((final_midpoints[triplet[2]] - source_center).dot(width_axis))
            source_half_width = 0.5 * (left_half_width + right_half_width)
            final_target = TOE_LENGTHS[toe_index]
            common_progress = distal_phase(terminal_parameter)
            common_desired = 0.68 + common_progress * (final_target - 0.68)
            fan_angle = math.radians(TOE_FAN_DEGREES[toe_index])
            width_multiplier = 0.91 if toe_index in (0, 4) else 1.0
            rings = []
            for parameter, width_scale, thickness_scale, plantar_lift in row_specs:
                stage = (parameter - terminal_parameter) / max(1.0 - terminal_parameter, 1e-8)
                progress = common_progress + stage * (1.0 - common_progress)
                desired = 0.68 + progress * (final_target - 0.68)
                center = source_center + forward_axis * ((desired - common_desired) * paw_length)
                center += width_axis * (
                    math.tan(fan_angle) * (desired - common_desired) * paw_length
                )
                half_width = source_half_width * width_scale * width_multiplier
                thickness = source_thickness * thickness_scale
                plantar_z = contact_z + plantar_lift * paw_length
                midpoint_z = plantar_z + 0.5 * thickness
                ring = []
                for lateral_factor, vertical_factor in ring_profile:
                    point = center + width_axis * (lateral_factor * half_width)
                    point.z = midpoint_z + vertical_factor * 0.5 * thickness
                    ring.append(len(vertices))
                    vertices.append(tuple(point))
                rings.append(ring)
            toe_rings[toe_index] = rings
            first_ring = rings[0]
            faces.append((source_upper[0], source_upper[1], first_ring[1], first_ring[0]))
            faces.append((source_upper[1], source_upper[2], first_ring[2], first_ring[1]))
            faces.append((source_lower[2], source_lower[1], first_ring[5], first_ring[4]))
            faces.append((source_lower[1], source_lower[0], first_ring[6], first_ring[5]))
            if toe_index == 0:
                faces.append((source_upper[0], first_ring[0], first_ring[7], first_ring[6]))
            if toe_index == len(DISTAL_TOE_TRIPLETS) - 1:
                faces.append((source_upper[2], first_ring[4], first_ring[3], first_ring[2]))
            for first_ring, second_ring in zip(rings, rings[1:]):
                for ring_index in range(8):
                    following = (ring_index + 1) % 8
                    faces.append((
                        first_ring[ring_index],
                        first_ring[following],
                        second_ring[following],
                        second_ring[ring_index],
                    ))
            tip = rings[-1]
            faces.append((tip[0], tip[1], tip[2], tip[3]))
            faces.append((tip[3], tip[4], tip[5], tip[6]))
            faces.append((tip[6], tip[7], tip[0], tip[3]))
            seam.extend(tip)
        for web_index, web_rail in enumerate(DISTAL_WEB_RAILS):
            left_upper, left_lower = toe_sources[web_index]
            right_upper, right_lower = toe_sources[web_index + 1]
            left_ring = toe_rings[web_index][0]
            right_ring = toe_rings[web_index + 1][0]
            common_dorsal = final_dorsal[web_rail]
            common_plantar = final_plantar[web_rail]
            if Vector(vertices[common_dorsal]).z >= Vector(vertices[common_plantar]).z:
                common_upper, common_lower = common_dorsal, common_plantar
            else:
                common_upper, common_lower = common_plantar, common_dorsal
            adjacent_points = [
                Vector(vertices[index])
                for index in (
                    left_ring[2], left_ring[3], left_ring[4],
                    right_ring[0], right_ring[7], right_ring[6],
                )
            ]
            web_center = sum(adjacent_points, start=Vector()) / len(adjacent_points)
            web_center -= forward_axis * (0.03 * paw_length)
            reference_thickness = 0.5 * (
                (Vector(vertices[left_ring[1]]) - Vector(vertices[left_ring[5]])).length
                + (Vector(vertices[right_ring[1]]) - Vector(vertices[right_ring[5]])).length
            )
            web_upper_z = min(
                Vector(vertices[left_ring[2]]).z,
                Vector(vertices[right_ring[0]]).z,
            ) - 0.08 * reference_thickness
            web_lower_z = max(
                Vector(vertices[left_ring[4]]).z,
                Vector(vertices[right_ring[6]]).z,
            ) + 0.03 * reference_thickness
            if web_upper_z - web_lower_z < 0.12 * reference_thickness:
                midpoint_z = 0.5 * (web_upper_z + web_lower_z)
                web_upper_z = midpoint_z + 0.06 * reference_thickness
                web_lower_z = midpoint_z - 0.06 * reference_thickness
            web_profile = []
            for factor in (1.0, 0.0, -1.0):
                point = web_center.copy()
                point.z = (
                    0.5 * (web_upper_z + web_lower_z)
                    + factor * 0.5 * (web_upper_z - web_lower_z)
                )
                web_profile.append(len(vertices))
                vertices.append(tuple(point))
            faces.append((left_upper[2], common_upper, web_profile[0], left_ring[2]))
            faces.append((common_upper, right_upper[0], right_ring[0], web_profile[0]))
            faces.append((common_lower, left_lower[2], left_ring[4], web_profile[2]))
            faces.append((right_lower[0], common_lower, web_profile[2], right_ring[6]))
            left_profile = (left_ring[2], left_ring[3], left_ring[4])
            right_profile = (right_ring[0], right_ring[7], right_ring[6])
            for profile_index in range(2):
                faces.append((
                    left_profile[profile_index],
                    web_profile[profile_index],
                    web_profile[profile_index + 1],
                    left_profile[profile_index + 1],
                ))
                faces.append((
                    web_profile[profile_index],
                    right_profile[profile_index],
                    right_profile[profile_index + 1],
                    web_profile[profile_index + 1],
                ))
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

    def build_constant_ring_toes():
        seam = []
        toe_face_start = len(faces)
        web_midpoints = {}
        for web_rail in DISTAL_WEB_RAILS:
            web_midpoints[web_rail] = len(vertices)
            midpoint = 0.5 * (
                Vector(vertices[final_dorsal[web_rail]])
                + Vector(vertices[final_plantar[web_rail]])
            )
            vertices.append(tuple(midpoint))
        outer_midpoints = {
            0: final_outer_midpoints[0],
            DISTAL_RAILS - 1: final_outer_midpoints[1],
        }
        all_midpoints = {**web_midpoints, **outer_midpoints}
        source_cycles = {}
        toe_rings = {}
        terminal_lengths = (0.92, 0.96, 1.00, 0.96, 0.92)
        root_depth_ratios = (0.30, 0.40, 0.45, 0.35, 0.28)
        row_specs = (
            (0.86, 1.12, 1.00, 0.060),
            (0.90, 1.15, 0.90, 0.000),
            (0.92, 1.12, 0.80, 0.000),
            (0.94, 1.02, 0.65, 0.000),
            (0.97, 0.76, 0.48, 0.000),
            (1.00, 0.48, 0.30, 0.000),
        )

        def ellipse_profile(count):
            top_count = 4 if count == 10 else 5
            profile = []
            for index in range(top_count):
                factor = index / (top_count - 1)
                angle = math.radians(135.0 - 90.0 * factor)
                profile.append((math.cos(angle), math.sin(angle)))
            profile.append((1.0, 0.0))
            for index in range(top_count):
                factor = index / (top_count - 1)
                angle = math.radians(-45.0 - 90.0 * factor)
                profile.append((math.cos(angle), math.sin(angle)))
            profile.append((-1.0, 0.0))
            return profile

        for toe_index, triplet in enumerate(DISTAL_TOE_TRIPLETS):
            start_rail = 0 if toe_index == 0 else DISTAL_WEB_RAILS[toe_index - 1]
            end_rail = DISTAL_RAILS - 1 if toe_index == 4 else DISTAL_WEB_RAILS[toe_index]
            source_cycle = (
                final_dorsal[start_rail : end_rail + 1]
                + [all_midpoints[end_rail]]
                + list(reversed(final_plantar[start_rail : end_rail + 1]))
                + [all_midpoints[start_rail]]
            )
            source_cycles[toe_index] = source_cycle
            count = len(source_cycle)
            profile = ellipse_profile(count)
            source_center = final_midpoints[triplet[1]]
            source_thickness = abs(
                Vector(vertices[final_dorsal[triplet[1]]]).z
                - Vector(vertices[final_plantar[triplet[1]]]).z
            )
            topology_vertical_sign = (
                1.0
                if Vector(vertices[final_dorsal[triplet[1]]]).z
                >= Vector(vertices[final_plantar[triplet[1]]]).z
                else -1.0
            )
            left_center = 0.5 * (
                Vector(vertices[final_dorsal[start_rail]])
                + Vector(vertices[final_plantar[start_rail]])
            )
            right_center = 0.5 * (
                Vector(vertices[final_dorsal[end_rail]])
                + Vector(vertices[final_plantar[end_rail]])
            )
            source_half_width = 0.5 * abs((right_center - left_center).dot(width_axis))
            final_target = terminal_lengths[toe_index]
            common_progress = distal_phase(terminal_parameter)
            common_desired = 0.68 + common_progress * (final_target - 0.68)
            fan_angle = math.radians(TOE_FAN_DEGREES[toe_index])
            width_multiplier = 0.98 if toe_index in (0, 4) else 1.0
            rings = []
            for row_index, (parameter, width_scale, thickness_scale, plantar_lift) in enumerate(row_specs):
                stage = (parameter - terminal_parameter) / max(1.0 - terminal_parameter, 1e-8)
                if abs(parameter - 0.97) < 1e-8:
                    longitudinal_stage = 0.90
                else:
                    longitudinal_stage = stage
                longitudinal_stage *= 0.78
                progress = common_progress + longitudinal_stage * (1.0 - common_progress)
                desired = 0.68 + progress * (final_target - 0.68)
                center = source_center + forward_axis * ((desired - common_desired) * paw_length)
                center += width_axis * (
                    math.tan(fan_angle) * (desired - common_desired) * paw_length
                )
                half_width = source_half_width * width_scale * width_multiplier
                thickness = (
                    maximum_thickness
                    * root_depth_ratios[toe_index]
                    * thickness_scale
                )
                plantar_z = contact_z + plantar_lift * paw_length
                midpoint_z = plantar_z + 0.5 * thickness
                ring = []
                for profile_index, (lateral_factor, vertical_factor) in enumerate(profile):
                    point = center + width_axis * (lateral_factor * half_width)
                    point.z = midpoint_z + topology_vertical_sign * vertical_factor * 0.5 * thickness
                    ring.append(len(vertices))
                    vertices.append(tuple(point))
                rings.append(ring)
            toe_rings[toe_index] = rings

        for web_index in range(4):
            left_count = len(source_cycles[web_index])
            right_count = len(source_cycles[web_index + 1])
            left_profile_indices = (3, 4, 5) if left_count == 10 else (4, 5, 6)
            right_profile_indices = (0, right_count - 1, right_count - 2)
            final_left = toe_rings[web_index][3]
            final_right = toe_rings[web_index + 1][3]
            final_left_center = sum(
                (Vector(vertices[final_left[index]]) for index in left_profile_indices),
                start=Vector(),
            ) / 3.0
            final_right_center = sum(
                (Vector(vertices[final_right[index]]) for index in right_profile_indices),
                start=Vector(),
            ) / 3.0
            separation = final_right_center - final_left_center
            for row_index, (gap_factor, recess_factor) in enumerate(zip(
                (0.00, 0.15, 0.60, 1.00),
                (-0.50, -0.30, 0.00, 0.00),
            )):
                left_ring = toe_rings[web_index][row_index]
                right_ring = toe_rings[web_index + 1][row_index]
                left_indices = [left_ring[index] for index in left_profile_indices]
                right_indices = [right_ring[index] for index in right_profile_indices]
                left_center = sum((Vector(vertices[index]) for index in left_indices), start=Vector()) / 3.0
                right_center = sum((Vector(vertices[index]) for index in right_indices), start=Vector()) / 3.0
                web_center = 0.5 * (left_center + right_center)
                target_left_center = web_center - 0.5 * gap_factor * separation
                target_right_center = web_center + 0.5 * gap_factor * separation
                for indices, current_center, target_center in (
                    (left_indices, left_center, target_left_center),
                    (right_indices, right_center, target_right_center),
                ):
                    displacement = target_center - current_center
                    for index in indices:
                        vertices[index] = tuple(Vector(vertices[index]) + displacement)
                    upper = max(indices, key=lambda index: Vector(vertices[index]).z)
                    lower = min(indices, key=lambda index: Vector(vertices[index]).z)
                    middle = next(index for index in indices if index not in (upper, lower))
                    reference_thickness = (
                        Vector(vertices[upper]) - Vector(vertices[lower])
                    ).length
                    upper_point = Vector(vertices[upper])
                    lower_point = Vector(vertices[lower])
                    upper_point.z -= 0.10 * reference_thickness * recess_factor
                    lower_point.z += 0.04 * reference_thickness * recess_factor
                    vertices[upper] = tuple(upper_point)
                    vertices[lower] = tuple(lower_point)
                    vertices[middle] = tuple(0.5 * (upper_point + lower_point))

        for toe_index in range(5):
            bands = [source_cycles[toe_index]] + toe_rings[toe_index]
            for first_ring, second_ring in zip(bands, bands[1:]):
                for index in range(len(first_ring)):
                    following = (index + 1) % len(first_ring)
                    faces.append((
                        first_ring[index],
                        first_ring[following],
                        second_ring[following],
                        second_ring[index],
                    ))
            tip = toe_rings[toe_index][-1]
            tip_width = max(
                (Vector(vertices[index]).dot(width_axis) for index in tip),
            ) - min(Vector(vertices[index]).dot(width_axis) for index in tip)
            forward_bulge = forward_axis * (0.12 * tip_width)
            if len(tip) == 10:
                interior = []
                for source_indices in ((0, 1, 2, 3, 4), (5, 6, 7, 8, 9)):
                    point = sum((Vector(vertices[tip[index]]) for index in source_indices), start=Vector()) / 5.0
                    interior.append(len(vertices))
                    vertices.append(tuple(point + forward_bulge))
                first, second = interior
                faces.extend((
                    (tip[0], tip[1], tip[2], first),
                    (tip[2], tip[3], tip[4], first),
                    (tip[4], tip[5], second, first),
                    (tip[5], tip[6], tip[7], second),
                    (tip[7], tip[8], tip[9], second),
                    (tip[9], tip[0], first, second),
                ))
            else:
                interior = []
                for source_indices in ((0, 1, 2), (3, 4, 5), (6, 7, 8), (9, 10, 11)):
                    point = sum((Vector(vertices[tip[index]]) for index in source_indices), start=Vector()) / 3.0
                    interior.append(len(vertices))
                    vertices.append(tuple(point + forward_bulge))
                first, second, third, fourth = interior
                faces.extend((
                    (tip[0], tip[1], tip[2], first),
                    (tip[2], tip[3], second, first),
                    (tip[3], tip[4], tip[5], second),
                    (tip[5], tip[6], third, second),
                    (tip[6], tip[7], tip[8], third),
                    (tip[8], tip[9], fourth, third),
                    (tip[9], tip[10], tip[11], fourth),
                    (tip[11], tip[0], first, fourth),
                    (first, second, third, fourth),
                ))
            seam.extend(tip)
        toe_measurements = []
        for toe_index in range(5):
            source = source_cycles[toe_index]
            root = toe_rings[toe_index][0]
            tip = toe_rings[toe_index][-1]
            source_center = sum(
                (Vector(vertices[index]) for index in source), start=Vector()
            ) / len(source)
            root_center = sum(
                (Vector(vertices[index]) for index in root), start=Vector()
            ) / len(root)
            tip_center = sum(
                (Vector(vertices[index]) for index in tip), start=Vector()
            ) / len(tip)
            root_width = (
                max(Vector(vertices[index]).dot(width_axis) for index in root)
                - min(Vector(vertices[index]).dot(width_axis) for index in root)
            )
            root_depth = (
                max(Vector(vertices[index]).z for index in root)
                - min(Vector(vertices[index]).z for index in root)
            )
            tip_width = (
                max(Vector(vertices[index]).dot(width_axis) for index in tip)
                - min(Vector(vertices[index]).dot(width_axis) for index in tip)
            )
            tip_depth = (
                max(Vector(vertices[index]).z for index in tip)
                - min(Vector(vertices[index]).z for index in tip)
            )
            cap_advance = 0.12 * tip_width
            toe_measurements.append({
                "toe": toe_index,
                "rootWidthToPalmWidth": root_width / paw_width,
                "rootDepthToMaximumThickness": root_depth / maximum_thickness,
                "rootWidthToDepth": root_width / max(root_depth, 1e-8),
                "tipWidthToRootWidth": tip_width / max(root_width, 1e-8),
                "tipDepthToRootDepth": tip_depth / max(root_depth, 1e-8),
                "exposedLengthToPawLength": (
                    (tip_center - source_center).dot(forward_axis) + cap_advance
                ) / paw_length,
                "rootAdvanceToPawLength": (
                    root_center - source_center
                ).dot(forward_axis) / paw_length,
                "plantarOffsetToPawLength": (
                    min(Vector(vertices[index]).z for index in tip) - contact_z
                ) / paw_length,
                "capAdvanceToTipWidth": cap_advance / max(tip_width, 1e-8),
            })
        return {
            "sections": sections,
            "seam": seam,
            "carpusIndices": list(carpus_indices),
            "pawFaceStart": paw_face_start,
            "toeFaceStart": toe_face_start,
            "carpusCenter": carpus_center,
            "pawWidth": paw_width,
            "pawLength": paw_length,
            "maximumThickness": maximum_thickness,
            "contactZ": contact_z,
            "dorsalPositions": dorsal_positions,
            "plantarPositions": plantar_positions,
            "toeMeasurements": toe_measurements,
        }

    def build_knuckle_shelf_toes():
        seam = []
        toe_face_start = len(faces)
        terminal_lengths = (0.92, 0.96, 1.00, 0.96, 0.92)
        root_depth_ratios = (0.30, 0.40, 0.45, 0.35, 0.28)
        toe_depth_boosts = (1.091, 1.001, 1.102, 1.103, 1.163)
        row_specs = (
            (0.86, 1.12, 1.00, 0.060),
            (0.90, 1.15, 0.90, 0.000),
            (0.92, 1.12, 0.80, 0.000),
            (0.94, 1.02, 0.82, 0.000),
            (0.97, 0.76, 0.46, 0.000),
            (1.00, 0.48, 0.23, 0.000),
        )

        def ellipse_profile(count):
            top_count = 4 if count == 10 else 5
            profile = []
            for index in range(top_count):
                factor = index / (top_count - 1)
                angle = math.radians(135.0 - 90.0 * factor)
                profile.append((math.cos(angle), math.sin(angle)))
            profile.append((1.0, 0.0))
            for index in range(top_count):
                factor = index / (top_count - 1)
                angle = math.radians(-45.0 - 90.0 * factor)
                profile.append((math.cos(angle), math.sin(angle)))
            profile.append((-1.0, 0.0))
            return profile

        toe_positions = {}
        toe_ring_counts = {}
        toe_source_centers = {}
        for toe_index, triplet in enumerate(DISTAL_TOE_TRIPLETS):
            start_rail = 0 if toe_index == 0 else DISTAL_WEB_RAILS[toe_index - 1]
            end_rail = DISTAL_RAILS - 1 if toe_index == 4 else DISTAL_WEB_RAILS[toe_index]
            count = 10 if toe_index in (0, 4) else 12
            toe_ring_counts[toe_index] = count
            profile = ellipse_profile(count)
            source_center = final_midpoints[triplet[1]]
            toe_source_centers[toe_index] = source_center
            topology_vertical_sign = (
                1.0
                if Vector(vertices[final_dorsal[triplet[1]]]).z
                >= Vector(vertices[final_plantar[triplet[1]]]).z
                else -1.0
            )
            left_center = 0.5 * (
                Vector(vertices[final_dorsal[start_rail]])
                + Vector(vertices[final_plantar[start_rail]])
            )
            right_center = 0.5 * (
                Vector(vertices[final_dorsal[end_rail]])
                + Vector(vertices[final_plantar[end_rail]])
            )
            source_half_width = 0.5 * abs((right_center - left_center).dot(width_axis))
            final_target = terminal_lengths[toe_index]
            common_progress = distal_phase(terminal_parameter)
            common_desired = 0.68 + common_progress * (final_target - 0.68)
            fan_angle = math.radians(TOE_FAN_DEGREES[toe_index])
            width_multiplier = 0.98 if toe_index in (0, 4) else 1.0
            rows = []
            for parameter, width_scale, thickness_scale, plantar_lift in row_specs:
                stage = (parameter - terminal_parameter) / max(1.0 - terminal_parameter, 1e-8)
                longitudinal_stage = 0.90 if abs(parameter - 0.97) < 1e-8 else stage
                longitudinal_stage *= 0.78
                progress = common_progress + longitudinal_stage * (1.0 - common_progress)
                desired = 0.68 + progress * (final_target - 0.68)
                center = source_center + forward_axis * ((desired - common_desired) * paw_length)
                fan_stage = 1.0
                if toe_index in (0, 4):
                    if parameter <= 0.94:
                        fan_stage = 0.0
                    elif parameter < 1.0:
                        fan_stage = (parameter - 0.94) / 0.06
                center += width_axis * (
                    math.tan(fan_angle) * (desired - common_desired) * paw_length * fan_stage
                )
                if toe_index in (0, 4) and parameter >= 0.90:
                    proximal_shift = {
                        0.90: 0.010,
                        0.92: 0.010,
                        0.94: 0.008,
                    }.get(round(parameter, 2), 0.0)
                    inward_shift = {
                        0.90: 0.015,
                        0.92: 0.012,
                        0.94: 0.008,
                        0.97: 0.005,
                    }.get(round(parameter, 2), 0.0)
                    center += forward_axis * ((0.025 - proximal_shift) * paw_length)
                    center -= width_axis * math.copysign(inward_shift * paw_length, fan_angle)
                half_width = source_half_width * width_scale * width_multiplier
                depth_blend = {
                    0.86: 0.0,
                    0.90: 0.55,
                    0.92: 1.0,
                    0.94: 1.08,
                    0.97: 0.65,
                    1.00: 0.25,
                }[round(parameter, 2)]
                depth_boost = 1.0 + (toe_depth_boosts[toe_index] - 1.0) * depth_blend
                thickness = (
                    maximum_thickness
                    * root_depth_ratios[toe_index]
                    * thickness_scale
                    * depth_boost
                )
                plantar_z = contact_z + plantar_lift * paw_length
                midpoint_z = plantar_z + 0.5 * thickness
                row = []
                for lateral_factor, vertical_factor in profile:
                    point = center + width_axis * (lateral_factor * half_width)
                    point.z = midpoint_z + topology_vertical_sign * vertical_factor * 0.5 * thickness
                    row.append(point)
                rows.append(row)
            toe_positions[toe_index] = rows

        for row_index, bridge_gap in ((0, 0.015), (1, 0.021), (2, 0.018)):
            for web_index in range(4):
                left_count = toe_ring_counts[web_index]
                right_count = toe_ring_counts[web_index + 1]
                left_dorsal = 3 if left_count == 10 else 4
                left_plantar = left_dorsal + 2
                right_dorsal = 0
                right_plantar = right_count - 2
                for left_index, right_index in (
                    (left_dorsal, right_dorsal),
                    (left_plantar, right_plantar),
                ):
                    left_point = toe_positions[web_index][row_index][left_index]
                    right_point = toe_positions[web_index + 1][row_index][right_index]
                    midpoint = 0.5 * (left_point + right_point)
                    half_gap = 0.5 * bridge_gap * paw_length
                    toe_positions[web_index][row_index][left_index] = (
                        midpoint - width_axis * half_gap
                    )
                    toe_positions[web_index + 1][row_index][right_index] = (
                        midpoint + width_axis * half_gap
                    )

        for web_index in range(4):
            left_count = toe_ring_counts[web_index]
            right_count = toe_ring_counts[web_index + 1]
            left_dorsal = 3 if left_count == 10 else 4
            left_middle = left_dorsal + 1
            left_plantar = left_dorsal + 2
            right_dorsal = 0
            right_middle = right_count - 1
            right_plantar = right_count - 2
            left_midpoint = 0.5 * (
                toe_positions[web_index][2][left_dorsal]
                + toe_positions[web_index][2][left_plantar]
            )
            right_midpoint = 0.5 * (
                toe_positions[web_index + 1][2][right_dorsal]
                + toe_positions[web_index + 1][2][right_plantar]
            )
            toe_positions[web_index][2][left_middle] = toe_positions[web_index][2][left_middle].lerp(
                left_midpoint, 0.25
            )
            toe_positions[web_index + 1][2][right_middle] = toe_positions[web_index + 1][2][right_middle].lerp(
                right_midpoint, 0.25
            )

        def source_point_for_profile(toe_index, profile_index):
            start_rail = 0 if toe_index == 0 else DISTAL_WEB_RAILS[toe_index - 1]
            end_rail = DISTAL_RAILS - 1 if toe_index == 4 else DISTAL_WEB_RAILS[toe_index]
            count = toe_ring_counts[toe_index]
            top_count = 4 if count == 10 else 5
            if profile_index < top_count:
                return Vector(vertices[final_dorsal[start_rail + profile_index]])
            if profile_index == top_count:
                return 0.5 * (
                    Vector(vertices[final_dorsal[end_rail]])
                    + Vector(vertices[final_plantar[end_rail]])
                )
            if profile_index < count - 1:
                plantar_offset = profile_index - (top_count + 1)
                return Vector(vertices[final_plantar[end_rail - plantar_offset]])
            return 0.5 * (
                Vector(vertices[final_dorsal[start_rail]])
                + Vector(vertices[final_plantar[start_rail]])
            )

        for toe_index in range(5):
            for profile_index, target in enumerate(toe_positions[toe_index][0]):
                source = source_point_for_profile(toe_index, profile_index)
                toe_positions[toe_index][0][profile_index] = source.lerp(target, 0.65)

        pre_rows = []
        pre_maps = []
        for row_index in (0, 1):
            row_maps = {}
            for toe_index in range(5):
                count = toe_ring_counts[toe_index]
                omitted = set()
                if toe_index > 0:
                    omitted.add(count - 1)
                if toe_index < 4:
                    omitted.add(4 if count == 10 else 5)
                mapping = {}
                for profile_index, point in enumerate(toe_positions[toe_index][row_index]):
                    if profile_index in omitted:
                        continue
                    mapping[profile_index] = len(vertices)
                    vertices.append(tuple(point))
                row_maps[toe_index] = mapping
            composite = []
            for toe_index in range(5):
                right_dorsal = 3 if toe_index in (0, 4) else 4
                composite.extend(row_maps[toe_index][index] for index in range(right_dorsal + 1))
            composite.append(row_maps[4][4])
            composite.extend(row_maps[4][index] for index in range(5, 9))
            for toe_index in (3, 2, 1):
                composite.extend(row_maps[toe_index][index] for index in range(6, 11))
            composite.extend(row_maps[0][index] for index in range(5, 9))
            composite.append(row_maps[0][9])
            if len(composite) != 48:
                raise RuntimeError(f"Expected 48 shelf vertices, got {len(composite)}")
            pre_rows.append(composite)
            pre_maps.append(row_maps)

        source_loop = list(final_ring)
        shelf_loop = pre_rows[0]
        shelf_transition_face_start = len(faces)
        expansion_indices = {5, 13, 25, 33}
        source_index = 0
        shelf_index = 0
        while source_index < 40:
            if source_index in expansion_indices:
                faces.append((
                    source_loop[source_index],
                    shelf_loop[(shelf_index + 2) % 48],
                    shelf_loop[(shelf_index + 1) % 48],
                    shelf_loop[shelf_index % 48],
                ))
                shelf_index += 2
            faces.append((
                source_loop[source_index],
                source_loop[(source_index + 1) % 40],
                shelf_loop[(shelf_index + 1) % 48],
                shelf_loop[shelf_index % 48],
            ))
            source_index += 1
            shelf_index += 1
        if shelf_index != 48:
            raise RuntimeError(f"Expected complete 40-to-48 transition, got {shelf_index}")
        shelf_transition_face_end = len(faces)
        shelf_band_face_start = len(faces)
        for index in range(48):
            following = (index + 1) % 48
            faces.append((pre_rows[0][index], pre_rows[0][following], pre_rows[1][following], pre_rows[1][index]))
        shelf_band_face_end = len(faces)

        toe_rings = {}
        for toe_index in range(5):
            rings = []
            for row_index in range(2, len(row_specs)):
                ring = []
                for point in toe_positions[toe_index][row_index]:
                    ring.append(len(vertices))
                    vertices.append(tuple(point))
                rings.append(ring)
            toe_rings[toe_index] = rings

        branch_ring_index = 0
        branch_face_start = len(faces)
        for toe_index in range(5):
            count = toe_ring_counts[toe_index]
            previous = pre_maps[1][toe_index]
            branch = toe_rings[toe_index][branch_ring_index]
            omitted_edges = set()
            if toe_index > 0:
                omitted_edges.update((count - 2, count - 1))
            if toe_index < 4:
                right_dorsal = 3 if count == 10 else 4
                omitted_edges.update((right_dorsal, right_dorsal + 1))
            for index in range(count):
                following = (index + 1) % count
                if index in omitted_edges:
                    continue
                if index not in previous or following not in previous:
                    continue
                faces.append((previous[index], previous[following], branch[following], branch[index]))
        branch_face_end = len(faces)

        saddle_face_start = len(faces)
        for web_index in range(4):
            left_count = toe_ring_counts[web_index]
            right_count = toe_ring_counts[web_index + 1]
            left_dorsal = 3 if left_count == 10 else 4
            left_middle = left_dorsal + 1
            left_plantar = left_dorsal + 2
            right_dorsal = 0
            right_middle = right_count - 1
            right_plantar = right_count - 2
            left_pre = pre_maps[1][web_index]
            right_pre = pre_maps[1][web_index + 1]
            left_branch = toe_rings[web_index][0]
            right_branch = toe_rings[web_index + 1][0]
            saddle = (
                (
                    right_pre[right_dorsal], left_pre[left_dorsal],
                    left_branch[left_dorsal], right_branch[right_dorsal],
                ),
                (
                    right_branch[right_dorsal], left_branch[left_dorsal],
                    left_branch[left_middle], right_branch[right_middle],
                ),
                (
                    right_branch[right_middle], left_branch[left_middle],
                    left_branch[left_plantar], right_branch[right_plantar],
                ),
                (
                    right_branch[right_plantar], left_branch[left_plantar],
                    left_pre[left_plantar], right_pre[right_plantar],
                ),
            )
            faces.extend(tuple(reversed(face)) for face in saddle)
        saddle_face_end = len(faces)

        distal_face_start = len(faces)
        for toe_index in range(5):
            rings = toe_rings[toe_index]
            for first_ring, second_ring in zip(rings, rings[1:]):
                for index in range(len(first_ring)):
                    following = (index + 1) % len(first_ring)
                    faces.append((first_ring[index], first_ring[following], second_ring[following], second_ring[index]))
            tip = rings[-1]
            tip_width = (
                max(Vector(vertices[index]).dot(width_axis) for index in tip)
                - min(Vector(vertices[index]).dot(width_axis) for index in tip)
            )
            forward_bulge = forward_axis * (0.12 * tip_width)
            if len(tip) == 10:
                interior = []
                for source_indices in ((0, 1, 2, 3, 4), (5, 6, 7, 8, 9)):
                    point = sum((Vector(vertices[tip[index]]) for index in source_indices), start=Vector()) / 5.0
                    interior.append(len(vertices))
                    vertices.append(tuple(point + forward_bulge))
                first, second = interior
                faces.extend((
                    (tip[0], tip[1], tip[2], first),
                    (tip[2], tip[3], tip[4], first),
                    (tip[4], tip[5], second, first),
                    (tip[5], tip[6], tip[7], second),
                    (tip[7], tip[8], tip[9], second),
                    (tip[9], tip[0], first, second),
                ))
            else:
                interior = []
                for source_indices in ((0, 1, 2), (3, 4, 5), (6, 7, 8), (9, 10, 11)):
                    point = sum((Vector(vertices[tip[index]]) for index in source_indices), start=Vector()) / 3.0
                    interior.append(len(vertices))
                    vertices.append(tuple(point + forward_bulge))
                first, second, third, fourth = interior
                faces.extend((
                    (tip[0], tip[1], tip[2], first),
                    (tip[2], tip[3], second, first),
                    (tip[3], tip[4], tip[5], second),
                    (tip[5], tip[6], third, second),
                    (tip[6], tip[7], tip[8], third),
                    (tip[8], tip[9], fourth, third),
                    (tip[9], tip[10], tip[11], fourth),
                    (tip[11], tip[0], first, fourth),
                    (first, second, third, fourth),
                ))
            seam.extend(tip)
        distal_face_end = len(faces)

        toe_measurements = []
        for toe_index in range(5):
            root = toe_rings[toe_index][0]
            tip = toe_rings[toe_index][-1]
            source_center = toe_source_centers[toe_index]
            root_center = sum((Vector(vertices[index]) for index in root), start=Vector()) / len(root)
            tip_center = sum((Vector(vertices[index]) for index in tip), start=Vector()) / len(tip)
            root_width = max(Vector(vertices[index]).dot(width_axis) for index in root) - min(Vector(vertices[index]).dot(width_axis) for index in root)
            root_depth = max(Vector(vertices[index]).z for index in root) - min(Vector(vertices[index]).z for index in root)
            tip_width = max(Vector(vertices[index]).dot(width_axis) for index in tip) - min(Vector(vertices[index]).dot(width_axis) for index in tip)
            tip_depth = max(Vector(vertices[index]).z for index in tip) - min(Vector(vertices[index]).z for index in tip)
            cap_advance = 0.12 * tip_width
            toe_measurements.append({
                "toe": toe_index,
                "rootWidthToPalmWidth": root_width / paw_width,
                "rootDepthToMaximumThickness": root_depth / maximum_thickness,
                "rootWidthToDepth": root_width / max(root_depth, 1e-8),
                "tipWidthToRootWidth": tip_width / max(root_width, 1e-8),
                "tipDepthToRootDepth": tip_depth / max(root_depth, 1e-8),
                "exposedLengthToPawLength": ((tip_center - source_center).dot(forward_axis) + cap_advance) / paw_length,
                "rootAdvanceToPawLength": (root_center - source_center).dot(forward_axis) / paw_length,
                "plantarOffsetToPawLength": (min(Vector(vertices[index]).z for index in tip) - contact_z) / paw_length,
                "capAdvanceToTipWidth": cap_advance / max(tip_width, 1e-8),
            })
        return {
            "sections": sections,
            "seam": seam,
            "carpusIndices": list(carpus_indices),
            "pawFaceStart": paw_face_start,
            "toeFaceStart": toe_face_start,
            "carpusCenter": carpus_center,
            "pawWidth": paw_width,
            "pawLength": paw_length,
            "maximumThickness": maximum_thickness,
            "contactZ": contact_z,
            "dorsalPositions": dorsal_positions,
            "plantarPositions": plantar_positions,
            "toeMeasurements": toe_measurements,
            "faceRanges": {
                "shelfTransition": [shelf_transition_face_start, shelf_transition_face_end],
                "shelfBand": [shelf_band_face_start, shelf_band_face_end],
                "branch": [branch_face_start, branch_face_end],
                "saddle": [saddle_face_start, saddle_face_end],
                "distalAndCaps": [distal_face_start, distal_face_end],
            },
        }

    return build_knuckle_shelf_toes()

    seam = []
    toe_rows = {}
    toe_root_thicknesses = {}
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
        common_desired = 0.68 + distal_phase(terminal_parameter) * (final_target - 0.68)
        common_progress = distal_phase(terminal_parameter)
        center_midpoint = final_midpoints[triplet[1]]
        source_center_thickness = abs(
            Vector(vertices[final_dorsal[triplet[1]]]).z
            - Vector(vertices[final_plantar[triplet[1]]]).z
        )
        toe_root_thicknesses[toe_index] = source_center_thickness
        fan_angle = math.radians(TOE_FAN_DEGREES[toe_index])

        def cap_row(
            parameter,
            lateral_positions,
            width_scale,
            thickness_scale,
            plantar_lift,
            nose_bulge=0.0,
        ):
            stage = (parameter - terminal_parameter) / max(1.0 - terminal_parameter, 1e-8)
            progress = common_progress + stage * (1.0 - common_progress)
            desired = 0.68 + progress * (final_target - 0.68)
            stage_center = center_midpoint + forward_axis * ((desired - common_desired) * paw_length)
            stage_center += width_axis * (math.tan(fan_angle) * (desired - common_desired) * paw_length)
            dorsal_row = []
            plantar_row = []
            left_half_width = abs((final_midpoints[triplet[0]] - center_midpoint).dot(width_axis))
            right_half_width = abs((final_midpoints[triplet[2]] - center_midpoint).dot(width_axis))
            source_dorsal_is_upper = (
                Vector(vertices[final_dorsal[triplet[1]]]).z
                >= Vector(vertices[final_plantar[triplet[1]]]).z
            )
            for local_rail, normalized_lateral in enumerate(lateral_positions):
                half_width = left_half_width if normalized_lateral < 0.0 else right_half_width
                lateral_delta = normalized_lateral * half_width
                base = stage_center + width_axis * lateral_delta * width_scale
                is_center = local_rail == 3
                if is_center:
                    base += forward_axis * nose_bulge
                is_outer_edge = (
                    (toe_index == 0 and local_rail == 0)
                    or (
                        toe_index == len(DISTAL_TOE_TRIPLETS) - 1
                        and local_rail == len(lateral_positions) - 1
                    )
                )
                if is_outer_edge:
                    outer_shift = interpolate_controls(
                        ((0.00, 0.00), (1.00, 0.00)),
                        stage,
                    ) * paw_length
                    base += width_axis * (-1.0 if lateral_delta > 0.0 else 1.0) * outer_shift
                stage_parameter = parameter
                plantar_z = contact_z + plantar_lift * paw_length
                contact_roll = smoothstep(0.60, 1.00, abs(normalized_lateral))
                plantar_z += 0.04 * contact_roll * tip_base_thickness
                crown_scale = 0.55 + 0.45 * max(
                    0.0, 1.0 - normalized_lateral * normalized_lateral
                )
                dorsal_z = plantar_z + thickness_scale * source_center_thickness * crown_scale
                if is_center:
                    dorsal_z += 0.04 * (1.0 - stage) * source_center_thickness
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

        def connect_cap_surfaces(source_dorsal, source_plantar, target_dorsal, target_plantar):
            if len(source_dorsal) == 3 and len(target_dorsal) == 5:
                dorsal_faces = (
                    (source_dorsal[0], source_dorsal[1], target_dorsal[1], target_dorsal[0]),
                    (source_dorsal[1], source_dorsal[2], target_dorsal[4], target_dorsal[3]),
                    (source_dorsal[1], target_dorsal[3], target_dorsal[2], target_dorsal[1]),
                )
            elif len(source_dorsal) == 5 and len(target_dorsal) == 7:
                dorsal_faces = (
                    (source_dorsal[0], source_dorsal[1], target_dorsal[1], target_dorsal[0]),
                    (source_dorsal[1], source_dorsal[2], target_dorsal[2], target_dorsal[1]),
                    (source_dorsal[2], target_dorsal[4], target_dorsal[3], target_dorsal[2]),
                    (source_dorsal[2], source_dorsal[3], target_dorsal[5], target_dorsal[4]),
                    (source_dorsal[3], source_dorsal[4], target_dorsal[6], target_dorsal[5]),
                )
            else:
                dorsal_faces = tuple(
                    (
                        source_dorsal[local_rail],
                        source_dorsal[local_rail + 1],
                        target_dorsal[local_rail + 1],
                        target_dorsal[local_rail],
                    )
                    for local_rail in range(len(source_dorsal) - 1)
                )
            faces.extend(dorsal_faces)
            for face in dorsal_faces:
                mapping = {
                    dorsal: plantar
                    for dorsal, plantar in zip(source_dorsal + target_dorsal, source_plantar + target_plantar)
                }
                faces.append(tuple(mapping[index] for index in reversed(face)))

        five_relaxed = (-1.0, -0.58, 0.0, 0.58, 1.0)
        five_even = (-1.0, -2.0 / 3.0, 0.0, 2.0 / 3.0, 1.0)
        seven_even = (-1.0, -2.0 / 3.0, -1.0 / 3.0, 0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0)
        cap_rows = [
            cap_row(0.86, five_relaxed, 1.05, 1.04, 0.003),
            cap_row(0.90, five_even, 1.00, 1.00, 0.003),
            cap_row(0.92, seven_even, 0.93, 0.93, 0.006),
            cap_row(0.94, seven_even, 0.86, 0.86, 0.010),
            cap_row(0.97, seven_even, 0.62, 0.58, 0.025, 0.004 * paw_width),
            cap_row(1.00, seven_even, 0.35, 0.25, 0.040, 0.012 * paw_width),
        ]
        toe_rows[toe_index] = cap_rows
        toe_dorsal, toe_plantar = cap_rows[-1]
        source_common = ([final_dorsal[rail] for rail in triplet], [final_plantar[rail] for rail in triplet])
        all_rows = [source_common] + cap_rows
        for pair_index, ((source_dorsal, source_plantar), (target_dorsal, target_plantar)) in enumerate(
            zip(all_rows, all_rows[1:])
        ):
            connect_cap_surfaces(source_dorsal, source_plantar, target_dorsal, target_plantar)
            if pair_index >= 3:
                for local_rail in (0, len(source_dorsal) - 1):
                    is_global_outer = (
                        (toe_index == 0 and local_rail == 0)
                        or (toe_index == len(DISTAL_TOE_TRIPLETS) - 1 and local_rail == len(source_dorsal) - 1)
                    )
                    if not is_global_outer:
                        connect_profiles(
                            vertical_profile(source_dorsal[local_rail], source_plantar[local_rail]),
                            vertical_profile(target_dorsal[local_rail], target_plantar[local_rail]),
                        )
        tip_profiles = [
            vertical_profile(toe_dorsal[local_rail], toe_plantar[local_rail])
            for local_rail in range(len(toe_dorsal))
        ]
        for local_rail in range(len(tip_profiles) - 1):
            connect_profiles(tip_profiles[local_rail], tip_profiles[local_rail + 1])
        seam.extend(toe_dorsal)
        seam.extend(toe_plantar)
    for web_index, web_rail in enumerate(DISTAL_WEB_RAILS):
        web_reference_thickness = 0.5 * (
            toe_root_thicknesses[web_index] + toe_root_thicknesses[web_index + 1]
        )
        left_triplet = DISTAL_TOE_TRIPLETS[web_index]
        right_triplet = DISTAL_TOE_TRIPLETS[web_index + 1]
        left_rows = [
            (final_dorsal[left_triplet[-1]], final_plantar[left_triplet[-1]])
        ] + [(dorsal[-1], plantar[-1]) for dorsal, plantar in toe_rows[web_index][:3]]
        right_rows = [
            (final_dorsal[right_triplet[0]], final_plantar[right_triplet[0]])
        ] + [(dorsal[0], plantar[0]) for dorsal, plantar in toe_rows[web_index + 1][:3]]
        web_rows = [(final_dorsal[web_rail], final_plantar[web_rail])]
        source_dorsal_is_upper = (
            Vector(vertices[web_rows[0][0]]).z >= Vector(vertices[web_rows[0][1]]).z
        )
        saddle_schedule = ((0.80, 0.00), (1.20, 0.00), (0.80, 0.00))
        for saddle_index, (recession_factor, proximal_shift) in enumerate(saddle_schedule, start=1):
            left_dorsal, left_plantar = left_rows[saddle_index]
            right_dorsal, right_plantar = right_rows[saddle_index]
            boundary_points = [
                Vector(vertices[index])
                for index in (left_dorsal, left_plantar, right_dorsal, right_plantar)
            ]
            web_midpoint = sum(boundary_points, start=Vector()) / len(boundary_points)
            if saddle_index == 1:
                root_boundary_points = [
                    Vector(vertices[index])
                    for pair in (left_rows[0], right_rows[0])
                    for index in pair
                ]
                root_web_points = [Vector(vertices[index]) for index in web_rows[0]]
                boundary_displacement = (
                    sum(boundary_points, start=Vector()) / len(boundary_points)
                    - sum(root_boundary_points, start=Vector()) / len(root_boundary_points)
                )
                boundary_displacement -= width_axis * boundary_displacement.dot(width_axis)
                web_midpoint = (
                    sum(root_web_points, start=Vector()) / len(root_web_points)
                    + boundary_displacement
                )
            web_midpoint -= forward_axis * (proximal_shift * paw_length)
            adjacent_upper = min(
                max(Vector(vertices[left_dorsal]).z, Vector(vertices[left_plantar]).z),
                max(Vector(vertices[right_dorsal]).z, Vector(vertices[right_plantar]).z),
            )
            adjacent_lower = max(
                min(Vector(vertices[left_dorsal]).z, Vector(vertices[left_plantar]).z),
                min(Vector(vertices[right_dorsal]).z, Vector(vertices[right_plantar]).z),
            )
            web_upper = adjacent_upper - 0.10 * recession_factor * web_reference_thickness
            web_lower = adjacent_lower + 0.04 * recession_factor * web_reference_thickness
            if web_upper - web_lower < 0.02 * web_reference_thickness:
                midpoint_z = 0.5 * (web_upper + web_lower)
                web_upper = midpoint_z + 0.01 * web_reference_thickness
                web_lower = midpoint_z - 0.01 * web_reference_thickness
            dorsal_point = web_midpoint.copy()
            plantar_point = web_midpoint.copy()
            dorsal_point.z = web_upper if source_dorsal_is_upper else web_lower
            plantar_point.z = web_lower if source_dorsal_is_upper else web_upper
            web_dorsal = len(vertices)
            vertices.append(tuple(dorsal_point))
            web_plantar = len(vertices)
            vertices.append(tuple(plantar_point))
            web_rows.append((web_dorsal, web_plantar))
        for band_index in range(3):
            left_dorsal, left_plantar = left_rows[band_index]
            next_left_dorsal, next_left_plantar = left_rows[band_index + 1]
            right_dorsal, right_plantar = right_rows[band_index]
            next_right_dorsal, next_right_plantar = right_rows[band_index + 1]
            web_dorsal, web_plantar = web_rows[band_index]
            next_web_dorsal, next_web_plantar = web_rows[band_index + 1]
            faces.append((left_dorsal, web_dorsal, next_web_dorsal, next_left_dorsal))
            faces.append((web_dorsal, right_dorsal, next_right_dorsal, next_web_dorsal))
            faces.append((web_plantar, left_plantar, next_left_plantar, next_web_plantar))
            faces.append((right_plantar, web_plantar, next_web_plantar, next_right_plantar))
        left_profile = vertical_profile(*left_rows[3])
        web_profile = vertical_profile(*web_rows[3])
        right_profile = vertical_profile(*right_rows[3])
        connect_profiles(left_profile, web_profile)
        connect_profiles(web_profile, right_profile)
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
        "firstSelfIntersectionDetails": [
            {
                "pair": [first, second],
                "firstFace": list(faces[first]),
                "firstCoordinates": [list(vertices[index]) for index in faces[first]],
                "secondFace": list(faces[second]),
                "secondCoordinates": [list(vertices[index]) for index in faces[second]],
            }
            for first, second in intersections[:12]
        ],
        "reversedAdjacencies": len(reversed_pairs),
        "firstReversedAdjacencyPairs": reversed_pairs[:20],
        "reversedAdjacencyPairs": reversed_pairs,
        "maximumEdgeRatio": max(ratios),
        "toeMaximumEdgeRatio": max(ratios[build["toeFaceStart"] :]),
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
            "toeMeasurements": build["toeMeasurements"],
            "faceRanges": build.get("faceRanges", {}),
        },
    }
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_FOREPAW_GATE", json.dumps(report))


if __name__ == "__main__":
    main()

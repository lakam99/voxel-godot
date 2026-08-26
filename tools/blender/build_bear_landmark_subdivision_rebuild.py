import argparse
import json
import math
import sys
from collections import Counter
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_bear_forequarter_subdivision_cage as cage_tools


def parse_args():
    parser = argparse.ArgumentParser(description="Build the whole-bear landmark subdivision rebuild without modifying the preferred face.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    return parser.parse_args(sys.argv[sys.argv.index("--") + 1 :])


def body_sections():
    return [
        {"y": -0.72, "z": 1.61, "width": 1.72, "top": 0.66, "bottom": 0.66, "name": "buried_mane_handoff"},
        {"y": -0.60, "z": 1.62, "width": 1.84, "top": 0.72, "bottom": 0.40, "name": "neck_base"},
        {"y": -0.52, "z": 1.61, "width": 1.92, "top": 0.70, "bottom": 0.50, "name": "cranial_scapula"},
        {"y": -0.36, "z": 1.62, "width": 1.92, "top": 0.64, "bottom": 0.60, "name": "withers"},
        {"y": -0.26, "z": 1.60, "width": 1.88, "top": 0.62, "bottom": 0.65, "name": "caudal_scapula"},
        {"y": -0.10, "z": 1.57, "width": 1.86, "top": 0.58, "bottom": 0.68, "name": "cranial_thorax"},
        {"y": 0.08, "z": 1.55, "width": 1.88, "top": 0.54, "bottom": 0.66, "name": "ribcage"},
        {"y": 0.26, "z": 1.54, "width": 1.80, "top": 0.51, "bottom": 0.60, "name": "caudal_ribcage"},
        {"y": 0.42, "z": 1.49, "width": 1.45, "top": 0.49, "bottom": 0.58, "name": "last_rib"},
        {"y": 0.56, "z": 1.55, "width": 1.29, "top": 0.43, "bottom": 0.48, "name": "abdomen"},
        {"y": 0.68, "z": 1.59, "width": 1.27, "top": 0.37, "bottom": 0.42, "name": "lumbar_bridge"},
        {"y": 0.78, "z": 1.70, "width": 1.58, "top": 0.28, "bottom": 0.39, "name": "iliac_crest"},
        {"y": 0.88, "z": 1.71, "width": 1.56, "top": 0.25, "bottom": 0.37, "name": "sacral_crown"},
        {"y": 0.98, "z": 1.66, "width": 1.42, "top": 0.24, "bottom": 0.31, "name": "gluteal_falloff"},
        {"y": 1.08, "z": 1.50, "width": 1.06, "top": 0.24, "bottom": 0.23, "name": "ischial_tuck"},
        {"y": 1.14, "z": 1.58, "width": 0.36, "top": 0.13, "bottom": 0.14, "name": "tail_support"},
        {"y": 1.18, "z": 1.63, "width": 0.18, "top": 0.075, "bottom": 0.075, "name": "tail_root"},
        {"y": 1.21, "z": 1.64, "width": 0.10, "top": 0.045, "bottom": 0.045, "name": "tail_mass"},
        {"y": 1.23, "z": 1.63, "width": 0.04, "top": 0.020, "bottom": 0.020, "name": "tail_tip_support"},
        {"y": 1.245, "z": 1.62, "width": 0.018, "top": 0.009, "bottom": 0.009, "name": "tail_tip"},
    ]


def build_body_with_limb_openings(with_openings=True):
    vertices = []
    faces = []
    sections = body_sections()
    for section in sections:
        for radial in range(cage_tools.TORSO_SEGMENTS):
            angle = cage_tools.math.tau * radial / cage_tools.TORSO_SEGMENTS
            sine = cage_tools.math.sin(angle)
            cosine = cage_tools.math.cos(angle)
            vertical = section["top"] if sine >= 0.0 else section["bottom"]
            shoulder_weight = cage_tools.math.exp(-((section["y"] + 0.36) / 0.31) ** 2)
            iliac_weight = cage_tools.math.exp(-((section["y"] - 0.78) / 0.24) ** 2)
            side_weight = max(0.0, abs(cosine) - 0.24) / 0.76
            dorsal_weight = max(0.0, sine + 0.10) / 1.10
            lateral = 0.060 * shoulder_weight * side_weight * dorsal_weight + 0.045 * iliac_weight * side_weight
            lift = 0.035 * shoulder_weight * side_weight * dorsal_weight
            side = 1.0 if cosine >= 0.0 else -1.0
            vertices.append((0.5 * section["width"] * cosine + side * lateral, section["y"], section["z"] + vertical * sine + lift))

    right_side = set(range(39, 46))
    left_side = set(range(27, 34))
    fore_spans = set(range(1, 6))
    hind_spans = set(range(9, 14))
    for longitudinal in range(len(sections) - 1):
        for radial in range(cage_tools.TORSO_SEGMENTS):
            remove_right = radial in right_side and longitudinal in fore_spans.union(hind_spans)
            remove_left = radial in left_side and longitudinal in fore_spans.union(hind_spans)
            if with_openings and (remove_right or remove_left):
                continue
            following = (radial + 1) % cage_tools.TORSO_SEGMENTS
            base = longitudinal * cage_tools.TORSO_SEGMENTS
            next_base = (longitudinal + 1) * cage_tools.TORSO_SEGMENTS
            faces.append((base + radial, base + following, next_base + following, next_base + radial))
    rear_start = (len(sections) - 1) * cage_tools.TORSO_SEGMENTS
    faces.append(tuple(reversed(range(cage_tools.TORSO_SEGMENTS))))
    faces.append(tuple(reversed(range(rear_start, rear_start + cage_tools.TORSO_SEGMENTS))))
    return vertices, faces


def append_closed_loft(vertices, faces, sections):
    radial_count = cage_tools.LIMB_SEGMENTS
    centers = [Vector(section["center"]) for section in sections]
    rings = []
    for index, section in enumerate(sections):
        if index == 0:
            tangent = centers[1] - centers[0]
        elif index == len(sections) - 1:
            tangent = centers[-1] - centers[-2]
        else:
            tangent = centers[index + 1] - centers[index - 1]
        ring = []
        for point in cage_tools.oriented_ring_points(section["center"], tangent, section["width"], section["depth"]):
            ring.append(len(vertices))
            vertices.append(tuple(point))
        rings.append(ring)
    for first, second in zip(rings, rings[1:]):
        for radial in range(radial_count):
            following = (radial + 1) % radial_count
            faces.append((first[radial], first[following], second[following], second[radial]))
    faces.append(tuple(reversed(rings[0])))
    faces.append(tuple(rings[-1]))
    return rings


def fit_front_ring_to_head(vertices, head, target_y=-0.55, ring_y=None):
    candidates = [
        vertex.co.copy()
        for vertex in head.data.vertices
        if target_y - 0.025 < vertex.co.y < target_y + 0.025 and vertex.co.z > 0.95
    ]
    if len(candidates) < cage_tools.TORSO_SEGMENTS:
        raise RuntimeError(f"Insufficient preferred-head boundary samples: {len(candidates)}")
    center_z = 0.5 * (min(point.z for point in candidates) + max(point.z for point in candidates))
    x_radius = max(abs(point.x) for point in candidates)
    z_radius = max(abs(point.z - center_z) for point in candidates)
    chosen = []
    for radial in range(cage_tools.TORSO_SEGMENTS):
        target = math.tau * radial / cage_tools.TORSO_SEGMENTS
        ranked = []
        for point in candidates:
            angle = math.atan2((point.z - center_z) / z_radius, point.x / x_radius) % math.tau
            angular_delta = abs((angle - target + math.pi) % math.tau - math.pi)
            normalized_radius = math.sqrt((point.x / x_radius) ** 2 + ((point.z - center_z) / z_radius) ** 2)
            ranked.append((angular_delta, -normalized_radius, point))
        point = min(ranked, key=lambda value: (value[0], value[1]))[2]
        vertices[radial] = (point.x, target_y if ring_y is None else ring_y, point.z)
        chosen.append(point)
    return {
        "samples": len(candidates),
        "fittedVertices": len(chosen),
        "xExtent": [min(point.x for point in chosen), max(point.x for point in chosen)],
        "zExtent": [min(point.z for point in chosen), max(point.z for point in chosen)],
        "maximumYDeviationFromHandoffPlane": max(abs(point.y - target_y) for point in chosen),
    }


def fore_limb_sections(side):
    return [
        {"center": (side * 0.46, -0.30, 1.58), "width": 0.86, "depth": 0.76, "name": "scapular_underfold"},
        {"center": (side * 0.59, -0.34, 1.44), "width": 0.72, "depth": 0.66, "name": "shoulder_joint"},
        {"center": (side * 0.72, -0.22, 1.24), "width": 0.66, "depth": 0.62, "name": "triceps_root"},
        {"center": (side * 0.73, -0.12, 1.05), "width": 0.58, "depth": 0.54, "name": "humerus"},
        {"center": (side * 0.72, -0.06, 0.90), "width": 0.54, "depth": 0.50, "name": "distal_humerus"},
        {"center": (side * 0.71, 0.00, 0.82), "width": 0.53, "depth": 0.50, "name": "olecranon"},
        {"center": (side * 0.70, -0.05, 0.66), "width": 0.43, "depth": 0.35, "name": "proximal_forearm"},
        {"center": (side * 0.69, -0.10, 0.54), "width": 0.39, "depth": 0.30, "name": "upper_forearm"},
        {"center": (side * 0.69, -0.14, 0.43), "width": 0.35, "depth": 0.26, "name": "mid_forearm"},
        {"center": (side * 0.68, -0.18, 0.31), "width": 0.31, "depth": 0.22, "name": "distal_forearm"},
        {"center": (side * 0.68, -0.20, 0.25), "width": 0.29, "depth": 0.20, "name": "carpus"},
    ]


def fore_wrist_sections(side):
    return [
        {"center": (side * 0.68, -0.21, 0.19), "width": 0.29, "depth": 0.17, "name": "carpal_turn"},
        {"center": (side * 0.68, -0.22, 0.14), "width": 0.36, "depth": 0.17, "name": "heel"},
    ]


def fore_paw_sections(side):
    return [
        {"center": (side * 0.68, -0.22, 0.155), "width": 0.51, "depth": 0.29, "name": "heel_shell", "toeFactor": 0.0},
        {"center": (side * 0.68, -0.31, 0.148), "width": 0.62, "depth": 0.28, "name": "palm", "toeFactor": 0.0},
        {"center": (side * 0.68, -0.41, 0.140), "width": 0.68, "depth": 0.25, "name": "digit_shelf", "toeFactor": 0.22},
        {"center": (side * 0.68, -0.50, 0.130), "width": 0.67, "depth": 0.22, "name": "toe_knuckles", "toeFactor": 0.64},
        {"center": (side * 0.68, -0.60, 0.116), "width": 0.63, "depth": 0.18, "name": "toe_line", "toeFactor": 1.0},
    ]


def hind_limb_sections(side):
    return [
        {"center": (side * 0.40, 0.76, 1.55), "width": 0.86, "depth": 0.73, "name": "gluteal_underfold"},
        {"center": (side * 0.52, 0.72, 1.41), "width": 0.74, "depth": 0.65, "name": "hip_joint"},
        {"center": (side * 0.59, 0.68, 1.28), "width": 0.64, "depth": 0.56, "name": "proximal_femur"},
        {"center": (side * 0.61, 0.66, 1.12), "width": 0.60, "depth": 0.52, "name": "hamstring"},
        {"center": (side * 0.61, 0.66, 0.98), "width": 0.64, "depth": 0.55, "name": "distal_hamstring"},
        {"center": (side * 0.60, 0.64, 0.90), "width": 0.60, "depth": 0.52, "name": "stifle"},
        {"center": (side * 0.59, 0.68, 0.82), "width": 0.55, "depth": 0.46, "name": "proximal_crus"},
        {"center": (side * 0.58, 0.72, 0.72), "width": 0.51, "depth": 0.42, "name": "mid_crus"},
        {"center": (side * 0.57, 0.76, 0.63), "width": 0.48, "depth": 0.40, "name": "gastrocnemius"},
        {"center": (side * 0.57, 0.78, 0.57), "width": 0.39, "depth": 0.31, "name": "achilles"},
        {"center": (side * 0.57, 0.79, 0.53), "width": 0.36, "depth": 0.28, "name": "hock"},
    ]


def hind_wrist_sections(side):
    return [
        {"center": (side * 0.57, 0.78, 0.41), "width": 0.37, "depth": 0.26, "name": "metatarsal_turn"},
        {"center": (side * 0.57, 0.74, 0.27), "width": 0.43, "depth": 0.24, "name": "hind_heel_turn"},
        {"center": (side * 0.57, 0.68, 0.16), "width": 0.49, "depth": 0.22, "name": "hind_heel"},
    ]


def hind_paw_sections(side):
    return [
        {"center": (side * 0.57, 0.68, 0.160), "width": 0.55, "depth": 0.30, "name": "heel_shell", "toeFactor": 0.0},
        {"center": (side * 0.57, 0.60, 0.150), "width": 0.65, "depth": 0.28, "name": "plantar_shelf", "toeFactor": 0.0},
        {"center": (side * 0.57, 0.46, 0.140), "width": 0.70, "depth": 0.26, "name": "digit_shelf", "toeFactor": 0.24},
        {"center": (side * 0.57, 0.33, 0.130), "width": 0.69, "depth": 0.23, "name": "toe_knuckles", "toeFactor": 0.66},
        {"center": (side * 0.57, 0.21, 0.116), "width": 0.64, "depth": 0.19, "name": "toe_line", "toeFactor": 1.0},
    ]


def toe_sections(side, family, toe_index):
    hierarchy = (0.84, 0.96, 1.0, 0.94, 0.80)
    lateral = (-0.20, -0.10, 0.0, 0.10, 0.20)[toe_index]
    fan = math.radians((-7.0, -3.0, -0.5, 3.5, 7.0)[toe_index])
    if family == "fore":
        center_x = side * 0.68 + lateral
        root_y = -0.48
        length = 0.16 * hierarchy[toe_index]
    else:
        center_x = side * 0.57 + lateral
        root_y = 0.35
        length = 0.17 * hierarchy[toe_index]
    tip_x = center_x + math.sin(fan) * length
    tip_y = root_y - math.cos(fan) * length
    width = 0.122 if toe_index == 2 else 0.108
    return [
        {"center": (center_x, root_y, 0.148), "width": width * 1.52, "depth": 0.205, "name": "buried_digit_root"},
        {"center": ((2.0 * center_x + tip_x) / 3.0, (2.0 * root_y + tip_y) / 3.0, 0.132), "width": width * 1.30, "depth": 0.172, "name": "digit_body"},
        {"center": ((center_x + 2.0 * tip_x) / 3.0, (root_y + 2.0 * tip_y) / 3.0, 0.112), "width": width * 1.04, "depth": 0.132, "name": "distal_digit"},
        {"center": (tip_x, tip_y, 0.096), "width": width * 0.74, "depth": 0.092, "name": "soft_toe_cap"},
    ]


def claw_centerline(root, fan_degrees, length, parameter):
    angle = math.radians(fan_degrees)
    forward = Vector((math.sin(angle), -math.cos(angle), 0.0))
    buried_root = Vector(root) - forward * (length * 0.26) + Vector((0.0, 0.0, 0.012))
    delayed_curve = max(0.0, min(1.0, (parameter - 0.58) / 0.42))
    delayed_curve = delayed_curve * delayed_curve * (3.0 - 2.0 * delayed_curve)
    ventral_drop = length * (0.055 * parameter + 0.165 * delayed_curve)
    return buried_root + forward * (length * parameter) + Vector((0.0, 0.0, -ventral_drop))


def create_claw(name, root, fan_degrees, length, material):
    ring_count = 10
    radial_count = 10
    centers = [claw_centerline(root, fan_degrees, length, ring / (ring_count - 1)) for ring in range(ring_count)]
    vertices = []
    faces = []
    for ring, center in enumerate(centers):
        parameter = ring / (ring_count - 1)
        tangent = centers[min(ring + 1, ring_count - 1)] - centers[max(ring - 1, 0)]
        tangent.normalize()
        width_axis = Vector((math.cos(math.radians(fan_degrees)), math.sin(math.radians(fan_degrees)), 0.0)).normalized()
        depth_axis = tangent.cross(width_axis).normalized()
        if parameter < 0.28:
            taper = 1.38 - 1.10 * parameter
        else:
            taper = 1.07 - 0.77 * ((parameter - 0.28) / 0.72) ** 1.35
        half_depth = length * 0.25 * taper
        half_width = half_depth * (0.72 - 0.10 * parameter)
        for radial in range(radial_count):
            angle = math.tau * radial / radial_count
            sine = math.sin(angle)
            ventral_scale = 0.68 if sine < 0.0 else 1.0
            dorsal_keel = half_depth * 0.10 * max(0.0, sine) * math.cos(angle)
            profile = width_axis * (half_width * math.cos(angle) + dorsal_keel)
            profile += depth_axis * (half_depth * sine * ventral_scale)
            vertices.append(tuple(center + profile))
    for ring in range(ring_count - 1):
        for radial in range(radial_count):
            following = (radial + 1) % radial_count
            first = ring * radial_count + radial
            second = ring * radial_count + following
            third = (ring + 1) * radial_count + following
            fourth = (ring + 1) * radial_count + radial
            faces.append((first, second, third, fourth))
    faces.append(tuple(reversed(range(radial_count))))
    last = (ring_count - 1) * radial_count
    faces.append(tuple(last + radial for radial in range(radial_count)))
    mesh = bpy.data.meshes.new(f"{name}Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    claw = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(claw)
    claw.data.materials.append(material)
    for polygon in claw.data.polygons:
        polygon.use_smooth = True
    subdivision = claw.modifiers.new("UngualSurfaceRefinement", "SUBSURF")
    subdivision.levels = 1
    subdivision.render_levels = 2
    return claw, centers[-1]


def add_claws(material):
    hierarchy = (0.84, 0.96, 1.0, 0.94, 0.80)
    fan_degrees = (-7.0, -3.0, 0.0, 4.0, 8.0)
    report = []
    for side in (-1.0, 1.0):
        for family in ("fore", "hind"):
            for toe_index in range(5):
                toe = toe_sections(side, family, toe_index)[-1]["center"]
                side_variation = 1.0 + (0.025 if side > 0.0 and toe_index in (1, 3) else -0.015 if side < 0.0 and toe_index in (0, 4) else 0.0)
                base_length = 0.176 if family == "fore" else 0.119
                length = base_length * hierarchy[toe_index] * side_variation
                claw, tip = create_claw(
                    f"BrownBear_{family.title()}Claw_{'L' if side < 0.0 else 'R'}_{toe_index + 1:02d}",
                    toe,
                    fan_degrees[toe_index],
                    length,
                    material,
                )
                report.append({"name": claw.name, "length": length, "root": list(toe), "tip": list(tip)})
    return report


def nuchal_mantle_sections():
    return [
        {"center": (0.0, -0.74, 1.62), "width": 1.30, "depth": 0.88, "name": "buried_nuchal_root"},
        {"center": (0.0, -0.64, 1.62), "width": 1.52, "depth": 1.00, "name": "cranial_mane"},
        {"center": (0.0, -0.55, 1.61), "width": 1.66, "depth": 1.08, "name": "mane_handoff"},
        {"center": (0.0, -0.46, 1.61), "width": 1.70, "depth": 1.14, "name": "withers_blend"},
        {"center": (0.0, -0.36, 1.62), "width": 1.70, "depth": 1.18, "name": "scapular_blend"},
    ]


def scapular_shield_sections(side):
    return [
        {"center": (side * 0.34, -0.38, 1.82), "width": 0.62, "depth": 0.46, "name": "scapular_spine"},
        {"center": (side * 0.45, -0.31, 1.65), "width": 0.61, "depth": 0.50, "name": "scapular_sheet"},
        {"center": (side * 0.57, -0.22, 1.43), "width": 0.57, "depth": 0.49, "name": "scapular_humeral_bridge"},
        {"center": (side * 0.67, -0.12, 1.20), "width": 0.49, "depth": 0.43, "name": "triceps_bridge"},
    ]


def gluteal_bridge_sections(side):
    return [
        {"center": (side * 0.32, 0.80, 1.76), "width": 0.68, "depth": 0.48, "name": "iliac_root"},
        {"center": (side * 0.43, 0.72, 1.58), "width": 0.70, "depth": 0.55, "name": "gluteal_plane"},
        {"center": (side * 0.54, 0.58, 1.38), "width": 0.66, "depth": 0.56, "name": "hip_bridge"},
        {"center": (side * 0.61, 0.43, 1.16), "width": 0.58, "depth": 0.50, "name": "hamstring_bridge"},
    ]


def add_limb_family(vertices, faces, loops, family):
    def oriented_ring(center, tangent, width, depth, *unused):
        return cage_tools.oriented_ring_points(center, tangent, width, depth)

    cage_tools.ring_points = oriented_ring
    if family == "fore":
        cage_tools.limb_sections = fore_limb_sections
        cage_tools.wrist_sections = fore_wrist_sections
        cage_tools.paw_sections = fore_paw_sections
    else:
        cage_tools.limb_sections = hind_limb_sections
        cage_tools.wrist_sections = hind_wrist_sections
        cage_tools.paw_sections = hind_paw_sections
    return [cage_tools.add_limb(vertices, faces, loop, -1.0 if center_x < 0.0 else 1.0) for center_x, loop in sorted(loops)]


def extract_locked_head(source):
    head = source.copy()
    head.data = source.data.copy()
    head.name = "BrownBear_PreservedFace289"
    bpy.context.collection.objects.link(head)
    def locked_face(point):
        return point.y < -1.05 and point.z > 0.95

    def retained_head_and_neck(point):
        legacy_forelimb = point.y > -1.0 and point.z < 1.35
        return point.y < -0.55 and point.z > 0.95 and not legacy_forelimb

    locked_before = sorted((vertex.co.copy() for vertex in head.data.vertices if locked_face(vertex.co)), key=lambda value: (value.x, value.y, value.z))
    bm = bmesh.new()
    bm.from_mesh(head.data)
    bmesh.ops.delete(bm, geom=[vertex for vertex in bm.verts if not retained_head_and_neck(vertex.co)], context="VERTS")
    bm.verts.ensure_lookup_table()
    nose = min(bm.verts, key=lambda vertex: vertex.co.y)
    retained_component = {nose}
    frontier = [nose]
    while frontier:
        vertex = frontier.pop()
        for edge in vertex.link_edges:
            neighbor = edge.other_vert(vertex)
            if neighbor not in retained_component:
                retained_component.add(neighbor)
                frontier.append(neighbor)
    bmesh.ops.delete(bm, geom=[vertex for vertex in bm.verts if vertex not in retained_component], context="VERTS")
    boundary = [edge for edge in bm.edges if len(edge.link_faces) == 1]
    if boundary:
        bmesh.ops.holes_fill(bm, edges=boundary, sides=0)
    bm.to_mesh(head.data)
    bm.free()
    head.data.update()
    locked_after = sorted((vertex.co.copy() for vertex in head.data.vertices if locked_face(vertex.co)), key=lambda value: (value.x, value.y, value.z))
    if len(locked_before) != len(locked_after):
        raise RuntimeError("Locked face vertex count changed during extraction")
    maximum_displacement = max(((after - before).length for before, after in zip(locked_before, locked_after)), default=0.0)
    if maximum_displacement > 1.0e-9:
        raise RuntimeError(f"Locked face changed by {maximum_displacement}")
    return head, len(locked_after), maximum_displacement


def finalize_body_sculpt_substrate(cage):
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = cage
    cage.select_set(True)
    subdivision = cage.modifiers.get("AnatomicalSubdivision")
    bpy.ops.object.modifier_apply(modifier=subdivision.name)
    pre_remesh_vertices = len(cage.data.vertices)
    cage.data.remesh_voxel_size = 0.016
    bpy.ops.object.voxel_remesh()
    smoothing = cage.modifiers.new("BodyOnlySurfaceRelax", "SMOOTH")
    smoothing.factor = 0.18
    smoothing.iterations = 3
    bpy.ops.object.modifier_apply(modifier=smoothing.name)
    for polygon in cage.data.polygons:
        polygon.use_smooth = True
    cage.data.update()
    cage.select_set(False)
    return {
        "preRemeshVertices": pre_remesh_vertices,
        "postRemeshVertices": len(cage.data.vertices),
        "voxelSize": 0.016,
        "smoothingFactor": 0.18,
        "smoothingIterations": 3,
        "faceIncluded": False,
    }


def fuse_locked_head(cage, head, locked_reference):
    bpy.ops.object.select_all(action="DESELECT")
    cage.select_set(True)
    bpy.context.view_layer.objects.active = cage
    boolean = cage.modifiers.new("ExactHeadNeckUnion", "BOOLEAN")
    boolean.operation = "UNION"
    boolean.solver = "MANIFOLD"
    boolean.object = head
    bpy.ops.object.modifier_apply(modifier=boolean.name)
    bpy.data.objects.remove(head, do_unlink=True)
    bm = bmesh.new()
    bm.from_mesh(cage.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1.0e-7)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(cage.data)
    bm.free()
    for polygon in cage.data.polygons:
        polygon.use_smooth = True
    cage.data.update()
    locked_after = sorted(
        (vertex.co.copy() for vertex in cage.data.vertices if vertex.co.y < -1.05 and vertex.co.z > 0.95),
        key=lambda value: (value.x, value.y, value.z),
    )
    if len(locked_reference) != len(locked_after):
        reference_counts = Counter(tuple(round(value, 9) for value in point) for point in locked_reference)
        after_counts = Counter(tuple(round(value, 9) for value in point) for point in locked_after)
        missing = list((reference_counts - after_counts).elements())
        raise RuntimeError(f"Exact union changed locked face count: {len(locked_reference)} -> {len(locked_after)}; missing={missing[:12]}")
    maximum_displacement = max(((after - before).length for before, after in zip(locked_reference, locked_after)), default=0.0)
    if maximum_displacement > 1.0e-9:
        raise RuntimeError(f"Exact union changed locked face by {maximum_displacement}")
    return {"method": "exact_boolean_union", "lockedVertices": len(locked_after), "maximumDisplacement": maximum_displacement}


def nonmanifold_bounds(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    points = [vertex.co.copy() for edge in bm.edges if len(edge.link_faces) != 2 for vertex in edge.verts]
    bm.free()
    if not points:
        return None
    return {
        "minimum": [min(point[axis] for point in points) for axis in range(3)],
        "maximum": [max(point[axis] for point in points) for axis in range(3)],
        "pointCount": len(points),
    }


def main():
    args = parse_args()
    source = bpy.data.objects.get("BrownBear_FusedSculptBase")
    if source is None:
        raise RuntimeError("Run this script from the iteration-289 preferred source blend")
    locked_reference = sorted(
        (vertex.co.copy() for vertex in source.data.vertices if vertex.co.y < -1.05 and vertex.co.z > 0.95),
        key=lambda value: (value.x, value.y, value.z),
    )
    head, locked_count, locked_maximum = extract_locked_head(source)
    for obj in list(bpy.context.scene.objects):
        if obj != head:
            bpy.data.objects.remove(obj, do_unlink=True)

    vertices, faces = build_body_with_limb_openings(with_openings=False)
    collar_fit = fit_front_ring_to_head(vertices, head, target_y=-0.55, ring_y=-0.72)
    fore_reports = []
    hind_reports = []
    for side in (-1.0, 1.0):
        fore_sections = fore_limb_sections(side) + fore_wrist_sections(side) + fore_paw_sections(side)
        hind_sections = hind_limb_sections(side) + hind_wrist_sections(side) + hind_paw_sections(side)
        append_closed_loft(vertices, faces, fore_sections)
        append_closed_loft(vertices, faces, hind_sections)
        for toe_index in range(5):
            append_closed_loft(vertices, faces, toe_sections(side, "fore", toe_index))
            append_closed_loft(vertices, faces, toe_sections(side, "hind", toe_index))
        fore_reports.append({"side": side, "sections": fore_sections})
        hind_reports.append({"side": side, "sections": hind_sections})

    used = sorted({index for face in faces for index in face})
    remap = {old: new for new, old in enumerate(used)}
    vertices = [vertices[index] for index in used]
    faces = [tuple(remap[index] for index in face) for face in faces]
    mesh = bpy.data.meshes.new("BrownBear_LandmarkSubdivisionCageMesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    cage = bpy.data.objects.new("BrownBear_LandmarkSubdivisionCage", mesh)
    bpy.context.collection.objects.link(cage)
    cage.data.materials.append(cage_tools.material("RebuildClay", (0.28, 0.20, 0.14)))
    head.data.materials.append(cage_tools.material("PreservedFaceClay", (0.31, 0.22, 0.15)))
    subdivision = cage.modifiers.new("AnatomicalSubdivision", "SUBSURF")
    subdivision.subdivision_type = "CATMULL_CLARK"
    subdivision.levels = 2
    subdivision.render_levels = 2

    sculpt_substrate = finalize_body_sculpt_substrate(cage)
    head_union = fuse_locked_head(cage, head, locked_reference)
    claw_material = cage_tools.material("UngualClay", (0.085, 0.060, 0.042))
    claw_report = add_claws(claw_material)
    topology = cage_tools.topology(cage)
    if topology["boundaryEdges"] != 0 or topology["nonmanifoldEdges"] != 0 or topology["components"] != 1:
        raise RuntimeError(f"Whole-bear manifold gate failed: {topology}; bounds={nonmanifold_bounds(cage)}")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_whole_landmark_cage_critic_gate",
        "sourceFace": "iteration-289",
        "faceLock": {"boundaryY": -1.05, "minimumZ": 0.95, "lockedVertices": locked_count, "maximumDisplacement": locked_maximum},
        "transitionCollar": {"headExtractionEndY": -0.55, "bodyStartY": -0.72, "policy": "exact union buries the measured neck-cut cross-section by 0.17 while preserving the locked face"},
        "collarFit": collar_fit,
        "nuchalMantle": nuchal_mantle_sections(),
        "separateRegionalOverlayMasses": False,
        "bodySculptSubstrate": sculpt_substrate,
        "headUnion": head_union,
        "topology": topology,
        "bodySections": body_sections(),
        "limbIntegration": {"method": "closed articulated loft overlap followed by one body-only voxel union", "fore": 2, "hind": 2, "hiddenDuplicateShellsAfterRemesh": False},
        "forelimbs": fore_reports,
        "hindlimbs": hind_reports,
        "claws": {"count": len(claw_report), "rootBurialFraction": 0.26, "construction": "toe-axis asymmetric unguals with delayed curvature and finite worn tips", "items": claw_report},
        "rejectedGeometryRetained": False,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_LANDMARK_SUBDIVISION_REBUILD", json.dumps(report))


if __name__ == "__main__":
    main()

import argparse
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree


BEAR_NAME = "BrownBear_LandmarkSubdivisionCage"
GROUND_Z = 0.019


def parse_args():
    parser = argparse.ArgumentParser(description="Rebuild structural brown-bear anatomy from the accepted unified surface.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--preserve-native-head", action="store_true")
    parser.add_argument("--preserve-paws-and-claws", action="store_true")
    parser.add_argument("--defer-intersection-repair", action="store_true")
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def clamp(value, minimum=0.0, maximum=1.0):
    return max(minimum, min(maximum, value))


def smoothstep(edge0, edge1, value):
    if edge0 == edge1:
        return float(value >= edge1)
    factor = clamp((value - edge0) / (edge1 - edge0))
    return factor * factor * (3.0 - 2.0 * factor)


def gaussian(point, center, scale):
    distance = sum(((point[index] - center[index]) / scale[index]) ** 2 for index in range(len(point)))
    return math.exp(-0.5 * distance)


def topology(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    remaining = set(bm.verts)
    components = 0
    while remaining:
        components += 1
        frontier = [remaining.pop()]
        while frontier:
            vertex = frontier.pop()
            for edge in vertex.link_edges:
                neighbor = edge.other_vert(vertex)
                if neighbor in remaining:
                    remaining.remove(neighbor)
                    frontier.append(neighbor)
    result = {
        "vertices": len(bm.verts),
        "faces": len(bm.faces),
        "boundaryEdges": sum(1 for edge in bm.edges if len(edge.link_faces) == 1),
        "nonmanifoldEdges": sum(1 for edge in bm.edges if len(edge.link_faces) != 2),
        "components": components,
    }
    bm.free()
    return result


def nonadjacent_intersections(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    bvh = BVHTree.FromBMesh(bm)
    count = 0
    centers = []
    for first, second in bvh.overlap(bvh):
        if first >= second:
            continue
        first_vertices = {vertex.index for vertex in bm.faces[first].verts}
        second_vertices = {vertex.index for vertex in bm.faces[second].verts}
        if not first_vertices.intersection(second_vertices):
            count += 1
            if len(centers) < 20:
                centers.append(tuple(round(value, 4) for value in ((bm.faces[first].calc_center_median() + bm.faces[second].calc_center_median()) * 0.5)))
    bm.free()
    return count, centers


def fair_neck_head_seam(bear):
    bm = bmesh.new()
    bm.from_mesh(bear.data)
    selected = [
        vertex
        for vertex in bm.verts
        if -1.04 < vertex.co.y < -0.72
        and 1.30 < vertex.co.z < 2.08
        and 0.18 < abs(vertex.co.x) < 0.78
    ]
    for _ in range(5):
        bmesh.ops.smooth_vert(
            bm,
            verts=selected,
            factor=0.12,
            use_axis_x=True,
            use_axis_y=True,
            use_axis_z=True,
        )
    bm.to_mesh(bear.data)
    bm.free()
    bear.data.update()
    return len(selected)


def fair_posterior_shelf(bear):
    bm = bmesh.new()
    bm.from_mesh(bear.data)
    selected = [
        vertex
        for vertex in bm.verts
        if 0.02 < vertex.co.y < 0.58
        and 1.02 < vertex.co.z < 1.68
        and abs(vertex.co.x) < 0.86
    ]
    for _ in range(48):
        bmesh.ops.smooth_vert(
            bm,
            verts=selected,
            factor=0.18,
            use_axis_x=True,
            use_axis_y=True,
            use_axis_z=True,
        )
    bm.to_mesh(bear.data)
    bm.free()
    bear.data.update()
    return len(selected)


def fair_crease_ring(bear, bounds, minimum_angle_degrees, rings, iterations, factor):
    bm = bmesh.new()
    bm.from_mesh(bear.data)
    bm.normal_update()
    minimum_x, maximum_x, minimum_y, maximum_y, minimum_z, maximum_z = bounds
    seeds = set()
    for edge in bm.edges:
        if len(edge.link_faces) != 2 or math.degrees(edge.calc_face_angle(0.0)) < minimum_angle_degrees:
            continue
        midpoint = (edge.verts[0].co + edge.verts[1].co) * 0.5
        if (
            minimum_x < midpoint.x < maximum_x
            and minimum_y < midpoint.y < maximum_y
            and minimum_z < midpoint.z < maximum_z
        ):
            seeds.update(edge.verts)
    selected = set(seeds)
    frontier = set(seeds)
    for _ in range(rings):
        next_frontier = set()
        for vertex in frontier:
            for edge in vertex.link_edges:
                neighbor = edge.other_vert(vertex)
                if neighbor not in selected:
                    selected.add(neighbor)
                    next_frontier.add(neighbor)
        frontier = next_frontier
    for _ in range(iterations):
        bmesh.ops.smooth_vert(
            bm,
            verts=list(selected),
            factor=factor,
            use_axis_x=True,
            use_axis_y=True,
            use_axis_z=True,
        )
    bm.normal_update()
    maximum_angle = 0.0
    for edge in bm.edges:
        if len(edge.link_faces) != 2:
            continue
        midpoint = (edge.verts[0].co + edge.verts[1].co) * 0.5
        if (
            minimum_x < midpoint.x < maximum_x
            and minimum_y < midpoint.y < maximum_y
            and minimum_z < midpoint.z < maximum_z
        ):
            maximum_angle = max(maximum_angle, math.degrees(edge.calc_face_angle(0.0)))
    bm.to_mesh(bear.data)
    bm.free()
    bear.data.update()
    return len(seeds), len(selected), maximum_angle


def claw_centers(prefix):
    objects = sorted((obj for obj in bpy.context.scene.objects if obj.name.startswith(prefix)), key=lambda obj: obj.name)
    centers = [sum((obj.matrix_world @ vertex.co for vertex in obj.data.vertices), Vector()) / len(obj.data.vertices) for obj in objects]
    return sorted(centers, key=lambda center: center.x)


def nearest_digit_profile(x, centers, width):
    distances = [abs(x - center.x) for center in centers]
    nearest = min(range(len(distances)), key=distances.__getitem__)
    crest = math.exp(-0.5 * (distances[nearest] / width) ** 2)
    return nearest, crest


def articulate_claws(prefix, length_scales, rear_offsets, bury_z):
    claws = sorted((obj for obj in bpy.context.scene.objects if obj.name.startswith(prefix)), key=lambda obj: obj.name)
    maximum_move = 0.0
    groups = [
        sorted((obj for obj in claws if sum((obj.matrix_world @ vertex.co).x for vertex in obj.data.vertices) < 0.0), key=lambda obj: obj.location.x),
        sorted((obj for obj in claws if sum((obj.matrix_world @ vertex.co).x for vertex in obj.data.vertices) >= 0.0), key=lambda obj: obj.location.x),
    ]
    for group in groups:
        if len(group) != 5:
            raise RuntimeError(f"Expected five claws per paw side for {prefix}, found {len(group)}")
        for index, obj in enumerate(group):
            world_points = [obj.matrix_world @ vertex.co for vertex in obj.data.vertices]
            root_y = max(point.y for point in world_points)
            root_vertices = [point for point in world_points if point.y > root_y - 0.035]
            root_x = sum(point.x for point in root_vertices) / len(root_vertices)
            root_z = max(point.z for point in world_points)
            inverse = obj.matrix_world.inverted()
            for vertex, world in zip(obj.data.vertices, world_points):
                new_world = world.copy()
                new_world.y = root_y + (world.y - root_y) * length_scales[index] + rear_offsets[index]
                root_weight = smoothstep(root_y - 0.12, root_y, world.y)
                new_world.x = root_x + (world.x - root_x) * (0.92 - 0.14 * root_weight)
                new_world.z = root_z + (world.z - root_z) * (0.94 + 0.04 * length_scales[index] - 0.08 * root_weight) - bury_z
                maximum_move = max(maximum_move, (new_world - world).length)
                vertex.co = inverse @ new_world
            obj.data.update()
    return len(claws), maximum_move


def main():
    args = parse_args()
    bear = bpy.data.objects.get(BEAR_NAME)
    if bear is None:
        raise RuntimeError(f"Missing {BEAR_NAME}")
    claws_before = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if len(claws_before) != 20:
        raise RuntimeError(f"Structural pass requires 20 claws, found {len(claws_before)}")

    fore_centers = claw_centers("BrownBear_ForeClaw")
    hind_centers = claw_centers("BrownBear_HindClaw")
    moved_vertices = 0
    maximum_move = 0.0
    region_counts = {name: 0 for name in ("torso", "head", "forelimbs", "hindlimbs", "paws")}

    for vertex in bear.data.vertices:
        original = vertex.co.copy()
        point = vertex.co
        absolute_x = abs(original.x)
        side = -1.0 if original.x < 0.0 else 1.0

        torso_mask = smoothstep(0.78, 1.08, original.z) * smoothstep(-0.78, -0.58, original.y) * (1.0 - smoothstep(1.02, 1.12, original.y))
        if torso_mask > 0.0:
            lumbar = gaussian((original.y, original.z), (0.42, 1.42), (0.25, 0.58)) * torso_mask
            point.x *= 1.0 - 0.145 * lumbar

            pelvis = gaussian((original.y, original.z), (0.78, 1.38), (0.25, 0.52)) * torso_mask
            point.x *= 1.0 - 0.110 * pelvis

            flank_tuck = gaussian((absolute_x, original.y, original.z), (0.38, 0.42, 1.02), (0.48, 0.24, 0.24)) * torso_mask
            point.z += 0.220 * flank_tuck

            rear_skirt = gaussian((absolute_x, original.y, original.z), (0.30, 0.72, 1.07), (0.52, 0.22, 0.22)) * torso_mask
            posterior_target = 0.70 + 0.24 * smoothstep(1.25, 1.52, original.z)
            if point.y > posterior_target:
                point.y += 0.78 * rear_skirt * (posterior_target - point.y)

            thoracic_keel = gaussian((absolute_x, original.y, original.z), (0.28, -0.14, 1.06), (0.55, 0.34, 0.28)) * torso_mask
            point.z -= 0.055 * thoracic_keel

            hump = gaussian((absolute_x, original.y, original.z), (0.26, -0.27, 1.94), (0.60, 0.28, 0.22)) * torso_mask
            point.z += 0.125 * hump

            lumbar_top = gaussian((absolute_x, original.y, original.z), (0.25, 0.40, 1.91), (0.62, 0.30, 0.20)) * torso_mask
            point.z -= 0.055 * lumbar_top

            pelvic_top = gaussian((absolute_x, original.y, original.z), (0.28, 0.76, 1.82), (0.60, 0.24, 0.22)) * torso_mask
            point.z -= 0.055 * pelvic_top
            region_counts["torso"] += 1

        head_mask = smoothstep(-0.78, -0.94, original.y) * smoothstep(1.08, 1.24, original.z)
        if head_mask > 0.0 and not args.preserve_native_head:
            muzzle = smoothstep(-1.38, -1.52, original.y) * (1.0 - smoothstep(1.82, 1.94, original.z))
            point.y = -1.38 + (point.y + 1.38) * (1.0 - 0.155 * muzzle)

            forehead = gaussian((absolute_x, original.y, original.z), (0.18, -1.16, 1.91), (0.30, 0.29, 0.27))
            frontal_plane = 2.00 + 0.48 * (original.y + 1.02)
            point.z += 0.42 * forehead * (frontal_plane - point.z)

            nasal = gaussian((absolute_x, original.y, original.z), (0.14, -1.49, 1.66), (0.25, 0.25, 0.22))
            nasal_plane = 1.79 + 0.35 * (original.y + 1.35)
            point.z += 0.50 * nasal * (nasal_plane - point.z)

            brow = gaussian((absolute_x, original.y, original.z), (0.36, -1.27, 1.73), (0.13, 0.15, 0.11))
            point.y -= 0.060 * brow
            point.z += 0.025 * brow

            orbit = gaussian((absolute_x, original.y, original.z), (0.38, -1.32, 1.65), (0.12, 0.12, 0.09))
            point.y += 0.040 * orbit

            maxillary = gaussian((absolute_x, original.y, original.z), (0.38, -1.48, 1.45), (0.17, 0.22, 0.18))
            point.x -= side * 0.045 * maxillary

            jaw_angle = gaussian((absolute_x, original.y, original.z), (0.42, -1.25, 1.28), (0.16, 0.18, 0.13))
            point.x += side * 0.048 * jaw_angle
            point.y += 0.025 * jaw_angle
            point.z -= 0.025 * jaw_angle

            lower_jaw = gaussian((absolute_x, original.y, original.z), (0.28, -1.34, 1.22), (0.34, 0.28, 0.15))
            point.z += 0.130 * lower_jaw
            point.y -= 0.050 * lower_jaw
            point.x *= 1.0 - 0.065 * lower_jaw
            region_counts["head"] += 1

        forelimb = smoothstep(0.42, 0.58, absolute_x) * smoothstep(1.45, 1.26, original.z) * smoothstep(0.28, 0.08, original.y)
        if forelimb > 0.0:
            elbow = gaussian((absolute_x, original.y, original.z), (0.69, -0.02, 0.79), (0.24, 0.20, 0.19)) * forelimb
            point.y += 0.110 * elbow
            point.x += side * 0.028 * elbow

            ulna = gaussian((absolute_x, original.y, original.z), (0.68, -0.13, 0.59), (0.20, 0.22, 0.22)) * forelimb
            point.y -= 0.040 * ulna

            carpus = gaussian((absolute_x, original.y, original.z), (0.68, -0.25, 0.36), (0.18, 0.22, 0.15)) * forelimb
            point.x = side * (0.68 + (abs(point.x) - 0.68) * (1.0 - 0.24 * carpus))
            point.y -= 0.040 * carpus
            region_counts["forelimbs"] += 1

        hindlimb = smoothstep(0.43, 0.58, absolute_x) * smoothstep(1.48, 1.28, original.z) * smoothstep(0.24, 0.40, original.y)
        if hindlimb > 0.0:
            stifle = gaussian((absolute_x, original.y, original.z), (0.66, 0.52, 0.88), (0.27, 0.22, 0.22)) * hindlimb
            point.y -= 0.120 * stifle
            point.x += side * 0.035 * stifle

            hock = gaussian((absolute_x, original.y, original.z), (0.64, 0.72, 0.51), (0.22, 0.20, 0.18)) * hindlimb
            point.y += 0.145 * hock
            point.x = side * (0.64 + (abs(point.x) - 0.64) * (1.0 - 0.12 * hock))

            heel = gaussian((absolute_x, original.y, original.z), (0.61, 0.52, 0.29), (0.23, 0.23, 0.15)) * hindlimb
            point.y -= 0.075 * heel
            region_counts["hindlimbs"] += 1

        forepaw = smoothstep(0.30, 0.42, absolute_x) * smoothstep(0.35, 0.26, original.z) * smoothstep(-0.18, -0.30, original.y)
        hindpaw = smoothstep(0.28, 0.40, absolute_x) * smoothstep(0.34, 0.27, original.z) * smoothstep(0.38, 0.25, original.y)
        if (forepaw > 0.0 or hindpaw > 0.0) and not args.preserve_paws_and_claws:
            paw = max(forepaw, hindpaw)
            flatten = smoothstep(GROUND_Z + 0.015, GROUND_Z + 0.27, original.z)
            point.z = GROUND_Z + (point.z - GROUND_Z) * (1.0 - (0.28 if forepaw >= hindpaw else 0.20) * paw * flatten)

            centers = [center for center in (fore_centers if forepaw >= hindpaw else hind_centers) if (center.x < 0.0) == (original.x < 0.0)]
            front_limit = -0.38 if forepaw >= hindpaw else 0.31
            front = smoothstep(front_limit + 0.12, front_limit - 0.08, original.y)
            if centers and front > 0.0:
                nearest_digit_profile(original.x, centers, 0.040 if forepaw >= hindpaw else 0.035)
            region_counts["paws"] += 1

        displacement = point - original
        if displacement.length > 0.24:
            displacement.normalize()
            displacement *= 0.24
            vertex.co = original + displacement
        if displacement.length > 1.0e-7:
            moved_vertices += 1
            maximum_move = max(maximum_move, displacement.length)

    bear.data.update()
    seam_vertices_faired = fair_neck_head_seam(bear)
    posterior_shelf_vertices_faired = fair_posterior_shelf(bear)
    throat_crease = fair_crease_ring(
        bear,
        (-0.72, 0.72, -0.90, -0.66, 1.08, 1.42),
        18.0,
        12,
        42,
        0.18,
    )
    posterior_crease = fair_crease_ring(
        bear,
        (-0.68, 0.68, 0.16, 0.38, 1.14, 1.42),
        18.0,
        10,
        38,
        0.17,
    )
    if args.preserve_paws_and_claws:
        fore_count = sum(obj.name.startswith("BrownBear_ForeClaw") for obj in bpy.context.scene.objects)
        hind_count = sum(obj.name.startswith("BrownBear_HindClaw") for obj in bpy.context.scene.objects)
        fore_claw_move = 0.0
        hind_claw_move = 0.0
    else:
        fore_count, fore_claw_move = articulate_claws(
            "BrownBear_ForeClaw", [0.98, 1.03, 1.08, 1.03, 0.98], [0.018, 0.004, -0.008, 0.004, 0.018], 0.004
        )
        hind_count, hind_claw_move = articulate_claws(
            "BrownBear_HindClaw", [0.90, 1.00, 1.05, 1.00, 0.90], [0.014, 0.003, -0.006, 0.003, 0.014], 0.005
        )

    mesh_topology = topology(bear)
    intersections, intersection_centers = nonadjacent_intersections(bear)
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Structural anatomy topology gate failed: {mesh_topology}")
    if intersections and not args.defer_intersection_repair:
        raise RuntimeError(f"Structural anatomy pass created {intersections} nonadjacent intersections near {intersection_centers}")
    claws_after = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if claws_after != claws_before or fore_count + hind_count != 20:
        raise RuntimeError("Structural anatomy pass changed the claw authority")

    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_photo_backed_critic_gate",
        "source": "iteration-827-deep-upper-heel-overlap",
        "method": "bounded structural deformation fields with explicit torso ratios, cranial planes, limb articulations, digit relief, and staggered claws",
        "nativeHeadPreserved": args.preserve_native_head,
        "pawAndClawAuthorityPreserved": args.preserve_paws_and_claws,
        "intersectionRepairDeferred": args.defer_intersection_repair,
        "movedVertices": moved_vertices,
        "maximumVertexMove": maximum_move,
        "regionVertexVisits": region_counts,
        "neckHeadSeamVerticesFaired": seam_vertices_faired,
        "posteriorShelfVerticesFaired": posterior_shelf_vertices_faired,
        "throatCreaseSeedExpandedAndMaximumDegrees": throat_crease,
        "posteriorCreaseSeedExpandedAndMaximumDegrees": posterior_crease,
        "clawsRetained": len(claws_after),
        "maximumClawMove": max(fore_claw_move, hind_claw_move),
        "nonadjacentIntersections": intersections,
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_STRUCTURAL_ANATOMY", json.dumps(report))


if __name__ == "__main__":
    main()

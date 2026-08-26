import argparse
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy


NUCHAL_SECTIONS = (
    (-1.82, 0.20, 1.58, 0.14),
    (-1.68, 0.34, 1.55, 0.20),
    (-1.52, 0.47, 1.51, 0.27),
    (-1.36, 0.57, 1.49, 0.33),
    (-1.22, 0.66, 1.48, 0.39),
    (-1.08, 0.72, 1.50, 0.43),
    (-0.94, 0.80, 1.52, 0.47),
    (-0.80, 0.88, 1.54, 0.50),
    (-0.66, 0.95, 1.56, 0.53),
    (-0.50, 1.00, 1.57, 0.54),
    (-0.32, 1.02, 1.56, 0.53),
    (-0.15, 1.00, 1.53, 0.50),
)
NUCHAL_RADIAL_COUNT = 48
THROAT_SECTIONS = (
    (-1.44, 0.48, 1.36, 0.15),
    (-1.28, 0.58, 1.32, 0.18),
    (-1.10, 0.68, 1.27, 0.20),
    (-0.90, 0.76, 1.21, 0.22),
    (-0.70, 0.81, 1.15, 0.23),
    (-0.50, 0.78, 1.08, 0.21),
    (-0.30, 0.70, 1.02, 0.18),
)


def parse_args():
    parser = argparse.ArgumentParser(description="Rebuild the bear as one continuous remeshed surface and reproject protected anatomy.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--voxel-size", type=float, default=0.018)
    parser.add_argument("--skip-face-projection", action="store_true")
    parser.add_argument("--skip-lower-head-fairing", action="store_true")
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def smoothstep(edge0, edge1, value):
    parameter = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return parameter * parameter * (3.0 - 2.0 * parameter)


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


def create_closed_nuchal_volume():
    vertices = []
    faces = []
    for section_index, (center_y, radius_x, center_z, radius_z) in enumerate(NUCHAL_SECTIONS):
        section_parameter = section_index / (len(NUCHAL_SECTIONS) - 1)
        for radial_index in range(NUCHAL_RADIAL_COUNT):
            angle = math.tau * radial_index / NUCHAL_RADIAL_COUNT
            cosine = math.cos(angle)
            sine = math.sin(angle)
            dorsal = max(0.0, sine)
            ventral = max(0.0, -sine)
            lateral_blend = 1.0 + 0.035 * (1.0 - abs(sine)) * math.sin(math.pi * section_parameter)
            ventral_tuck = 0.62 * (1.0 - section_parameter) + 0.12 * section_parameter
            dorsal_rise = 1.0 + 0.35 * dorsal * math.sin(math.pi * section_parameter)
            ventral_blend = 1.0 - ventral_tuck * ventral
            vertices.append(
                (
                    radius_x * cosine * lateral_blend,
                    center_y + 0.018 * dorsal * math.sin(math.pi * section_parameter),
                    center_z + radius_z * sine * ventral_blend * dorsal_rise,
                )
            )
    for section_index in range(len(NUCHAL_SECTIONS) - 1):
        for radial_index in range(NUCHAL_RADIAL_COUNT):
            following = (radial_index + 1) % NUCHAL_RADIAL_COUNT
            first = section_index * NUCHAL_RADIAL_COUNT + radial_index
            second = section_index * NUCHAL_RADIAL_COUNT + following
            third = (section_index + 1) * NUCHAL_RADIAL_COUNT + following
            fourth = (section_index + 1) * NUCHAL_RADIAL_COUNT + radial_index
            faces.append((first, second, third, fourth))
    cranial_center = len(vertices)
    vertices.append((0.0, NUCHAL_SECTIONS[0][0], NUCHAL_SECTIONS[0][2]))
    caudal_center = len(vertices)
    vertices.append((0.0, NUCHAL_SECTIONS[-1][0], NUCHAL_SECTIONS[-1][2]))
    last_start = (len(NUCHAL_SECTIONS) - 1) * NUCHAL_RADIAL_COUNT
    for radial_index in range(NUCHAL_RADIAL_COUNT):
        following = (radial_index + 1) % NUCHAL_RADIAL_COUNT
        faces.append((cranial_center, following, radial_index))
        faces.append((caudal_center, last_start + radial_index, last_start + following))
    mesh = bpy.data.meshes.new("BrownBearBuriedNuchalVolumeMesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    volume = bpy.data.objects.new("BrownBear_BuriedNuchalVolume", mesh)
    bpy.context.scene.collection.objects.link(volume)
    return volume


def create_closed_throat_volume():
    vertices = []
    faces = []
    for center_y, radius_x, center_z, radius_z in THROAT_SECTIONS:
        for radial_index in range(NUCHAL_RADIAL_COUNT):
            angle = math.tau * radial_index / NUCHAL_RADIAL_COUNT
            vertices.append(
                (
                    radius_x * math.cos(angle),
                    center_y,
                    center_z + radius_z * math.sin(angle),
                )
            )
    for section_index in range(len(THROAT_SECTIONS) - 1):
        for radial_index in range(NUCHAL_RADIAL_COUNT):
            following = (radial_index + 1) % NUCHAL_RADIAL_COUNT
            first = section_index * NUCHAL_RADIAL_COUNT + radial_index
            second = section_index * NUCHAL_RADIAL_COUNT + following
            third = (section_index + 1) * NUCHAL_RADIAL_COUNT + following
            fourth = (section_index + 1) * NUCHAL_RADIAL_COUNT + radial_index
            faces.append((first, second, third, fourth))
    cranial_center = len(vertices)
    vertices.append((0.0, THROAT_SECTIONS[0][0], THROAT_SECTIONS[0][2]))
    caudal_center = len(vertices)
    vertices.append((0.0, THROAT_SECTIONS[-1][0], THROAT_SECTIONS[-1][2]))
    last_start = (len(THROAT_SECTIONS) - 1) * NUCHAL_RADIAL_COUNT
    for radial_index in range(NUCHAL_RADIAL_COUNT):
        following = (radial_index + 1) % NUCHAL_RADIAL_COUNT
        faces.append((cranial_center, following, radial_index))
        faces.append((caudal_center, last_start + radial_index, last_start + following))
    mesh = bpy.data.meshes.new("BrownBearBuriedThroatFairingMesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    volume = bpy.data.objects.new("BrownBear_BuriedThroatFairing", mesh)
    bpy.context.scene.collection.objects.link(volume)
    return volume


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Run from iteration 742")
    claws_before = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if len(claws_before) != 20:
        raise RuntimeError(f"Continuous remesh requires 20 claws, found {len(claws_before)}")
    source = bear.copy()
    source.data = bear.data.copy()
    source.name = "BrownBear_ProtectedProjectionSource"
    bpy.context.scene.collection.objects.link(source)
    source.hide_render = True
    source.hide_set(True)
    nuchal_volume = create_closed_nuchal_volume()
    bpy.ops.object.select_all(action="DESELECT")
    bear.select_set(True)
    nuchal_volume.select_set(True)
    bpy.context.view_layer.objects.active = bear
    bpy.ops.object.join()
    before = topology(bear)
    bear.data.remesh_voxel_size = args.voxel_size
    bear.data.remesh_voxel_adaptivity = 0.0
    bear.data.use_remesh_fix_poles = True
    bear.data.use_remesh_preserve_volume = True
    bpy.ops.object.voxel_remesh()
    protected = bear.vertex_groups.new(name="ProtectedFaceAndPaws")
    protected_vertices = 0
    for vertex in bear.data.vertices:
        point = vertex.co
        muzzle_weight = 1.0 - smoothstep(-1.66, -1.52, point.y)
        eye_longitudinal = smoothstep(-1.66, -1.54, point.y) * (1.0 - smoothstep(-1.25, -1.12, point.y))
        eye_vertical = smoothstep(1.54, 1.66, point.z) * (1.0 - smoothstep(1.94, 2.04, point.z))
        eye_lateral = smoothstep(0.20, 0.30, abs(point.x)) * (1.0 - smoothstep(0.62, 0.72, abs(point.x)))
        eye_weight = eye_longitudinal * eye_vertical * eye_lateral
        ear_weight = smoothstep(1.86, 1.98, point.z) * (1.0 - smoothstep(-1.10, -0.96, point.y))
        face_weight = 0.0 if args.skip_face_projection else max(muzzle_weight, eye_weight, ear_weight)
        paw_height = 1.0 - smoothstep(0.22, 0.38, point.z)
        paw_longitudinal = max(1.0 - smoothstep(-0.12, 0.02, point.y), smoothstep(0.10, 0.28, point.y))
        paw_lateral = smoothstep(0.26, 0.46, abs(point.x))
        paw_weight = paw_height * paw_longitudinal * paw_lateral
        weight = max(face_weight, paw_weight)
        if weight > 1.0e-5:
            protected.add([vertex.index], weight, "REPLACE")
            protected_vertices += 1
    shrinkwrap = bear.modifiers.new("ReprojectProtectedAnatomy", "SHRINKWRAP")
    shrinkwrap.target = source
    shrinkwrap.wrap_method = "NEAREST_SURFACEPOINT"
    shrinkwrap.wrap_mode = "ON_SURFACE"
    shrinkwrap.vertex_group = protected.name
    bpy.context.view_layer.objects.active = bear
    bpy.ops.object.modifier_apply(modifier=shrinkwrap.name)
    bpy.data.objects.remove(source, do_unlink=True)
    harmonic = bear.vertex_groups.new(name="HarmonicHeadNeckTransition")
    transition_vertices = 0
    throat_vertices = 0
    for vertex in bear.data.vertices:
        point = vertex.co
        ventral_blend = 1.0 - smoothstep(1.05, 1.35, point.z)
        cranial_edge = -1.40 - 0.30 * ventral_blend
        cranial_full = -0.84 - 0.40 * ventral_blend
        cranial_ramp = smoothstep(cranial_edge, cranial_full, point.y)
        caudal_ramp = 1.0 - smoothstep(-0.42, -0.12, point.y)
        vertical_weight = smoothstep(0.66, 0.84, point.z)
        harmonic_weight = cranial_ramp * caudal_ramp * vertical_weight
        if harmonic_weight > 1.0e-5:
            harmonic.add([vertex.index], harmonic_weight, "REPLACE")
            transition_vertices += 1
    bear.data.update()
    laplacian = bear.modifiers.new("VolumePreservingHeadNeckHarmonic", "LAPLACIANSMOOTH")
    laplacian.vertex_group = harmonic.name
    laplacian.iterations = 20
    laplacian.lambda_factor = 0.12
    laplacian.lambda_border = 0.08
    laplacian.use_volume_preserve = True
    bpy.context.view_layer.objects.active = bear
    bpy.ops.object.modifier_apply(modifier=laplacian.name)
    crease_fairing = bear.vertex_groups.new(name="LowerHeadRidgeRemoval")
    crease_vertices = 0
    for vertex in bear.data.vertices:
        point = vertex.co
        longitudinal = smoothstep(-1.68, -1.50, point.y) * (1.0 - smoothstep(-0.86, -0.64, point.y))
        vertical = smoothstep(0.94, 1.06, point.z) * (1.0 - smoothstep(1.54, 1.70, point.z))
        weight = longitudinal * vertical
        if weight > 1.0e-5:
            crease_fairing.add([vertex.index], weight, "REPLACE")
            crease_vertices += 1
    if not args.skip_lower_head_fairing:
        localized = bear.modifiers.new("DestructiveLowerHeadRidgeFairing", "SMOOTH")
        localized.vertex_group = crease_fairing.name
        localized.iterations = 35
        localized.factor = 0.55
        bpy.context.view_layer.objects.active = bear
        bpy.ops.object.modifier_apply(modifier=localized.name)
    bear.data.update()
    for polygon in bear.data.polygons:
        polygon.use_smooth = True
    after = topology(bear)
    if after["boundaryEdges"] or after["nonmanifoldEdges"] or after["components"] != 1:
        raise RuntimeError(f"Continuous remesh topology gate failed: {after}")
    claws_after = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if claws_after != claws_before:
        raise RuntimeError("Continuous remesh changed the passed claw set")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_continuous_surface_critic_gate",
        "source": "iteration-742-relaxed-toe-ownership",
        "method": "buried closed nuchal volume fused by full soft-tissue voxel remesh, followed by weighted nearest-surface reprojection of the preferred face and passed paws",
        "nuchalSections": [list(section) for section in NUCHAL_SECTIONS],
        "throatSections": [list(section) for section in THROAT_SECTIONS],
        "voxelSize": args.voxel_size,
        "faceProjectionSkipped": args.skip_face_projection,
        "lowerHeadFairingSkipped": args.skip_lower_head_fairing,
        "protectedVertices": protected_vertices,
        "harmonicTransitionVertices": transition_vertices,
        "liftedRetractedThroatVertices": throat_vertices,
        "destructiveLowerHeadFairingVertices": crease_vertices,
        "localizedCreaseFairingVertices": crease_vertices,
        "clawsRetained": len(claws_after),
        "topologyBefore": before,
        "topologyAfter": after,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_CONTINUOUS_SURFACE", json.dumps(report))


if __name__ == "__main__":
    main()

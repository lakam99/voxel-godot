import argparse
import json
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils.bvhtree import BVHTree


def parse_args():
    parser = argparse.ArgumentParser(description="Remesh four distal limb junctions while reprojecting accepted bear anatomy.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--voxel-size", type=float, default=0.014)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def smoothstep(edge0, edge1, value):
    factor = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return factor * factor * (3.0 - 2.0 * factor)


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


def junction_weight(point):
    lateral = smoothstep(0.38, 0.52, abs(point.x))
    vertical = smoothstep(0.24, 0.37, point.z) * (1.0 - smoothstep(0.58, 0.70, point.z))
    fore = smoothstep(-0.62, -0.50, point.y) * (1.0 - smoothstep(0.18, 0.30, point.y))
    hind = smoothstep(0.22, 0.34, point.y) * (1.0 - smoothstep(0.98, 1.10, point.y))
    return lateral * vertical * max(fore, hind)


def nonadjacent_intersections(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    bvh = BVHTree.FromBMesh(bm)
    intersections = 0
    for first, second in bvh.overlap(bvh):
        if first >= second:
            continue
        first_vertices = {vertex.index for vertex in bm.faces[first].verts}
        second_vertices = {vertex.index for vertex in bm.faces[second].verts}
        if not first_vertices.intersection(second_vertices):
            intersections += 1
    bm.free()
    return intersections


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Run from iteration 793")
    claws_before = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if len(claws_before) != 20:
        raise RuntimeError(f"Distal remesh requires 20 claws, found {len(claws_before)}")
    source = bear.copy()
    source.data = bear.data.copy()
    source.name = "BrownBear_AcceptedSurfaceProjectionSource"
    bpy.context.scene.collection.objects.link(source)
    source.hide_render = True
    source.hide_set(True)
    before = topology(bear)
    intersections_before = nonadjacent_intersections(bear)
    bpy.ops.object.select_all(action="DESELECT")
    bear.select_set(True)
    bpy.context.view_layer.objects.active = bear
    bear.data.remesh_voxel_size = args.voxel_size
    bear.data.remesh_voxel_adaptivity = 0.0
    bear.data.use_remesh_fix_poles = True
    bear.data.use_remesh_preserve_volume = True
    bpy.ops.object.voxel_remesh()

    accepted = bear.vertex_groups.new(name="AcceptedAnatomyReprojection")
    junction = bear.vertex_groups.new(name="DistalJunctionFairing")
    junction_vertices = 0
    for vertex in bear.data.vertices:
        local_junction_weight = junction_weight(vertex.co)
        accepted_weight = 1.0 - local_junction_weight
        if accepted_weight > 1.0e-5:
            accepted.add([vertex.index], accepted_weight, "REPLACE")
        if local_junction_weight > 1.0e-5:
            junction.add([vertex.index], local_junction_weight, "REPLACE")
            junction_vertices += 1
    shrinkwrap = bear.modifiers.new("ReprojectAcceptedBearAnatomy", "SHRINKWRAP")
    shrinkwrap.target = source
    shrinkwrap.wrap_method = "NEAREST_SURFACEPOINT"
    shrinkwrap.wrap_mode = "ON_SURFACE"
    shrinkwrap.vertex_group = accepted.name
    bpy.ops.object.modifier_apply(modifier=shrinkwrap.name)
    fairing = bear.modifiers.new("FairContinuousDistalJunctions", "SMOOTH")
    fairing.vertex_group = junction.name
    fairing.iterations = 24
    fairing.factor = 0.42
    bpy.ops.object.modifier_apply(modifier=fairing.name)
    bpy.data.objects.remove(source, do_unlink=True)
    for polygon in bear.data.polygons:
        polygon.use_smooth = True
    bear.data.update()
    after = topology(bear)
    intersections_after = nonadjacent_intersections(bear)
    if after["boundaryEdges"] or after["nonmanifoldEdges"] or after["components"] != 1:
        raise RuntimeError(f"Distal remesh topology gate failed: {after}")
    claws_after = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if claws_after != claws_before:
        raise RuntimeError("Distal remesh changed the passed claw set")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_whole_bear_critic_gate",
        "source": "iteration-793-occipital-anchored-cranial-warp",
        "method": "full soft-tissue voxel remesh with accepted-surface reprojection outside four distal junction bands",
        "voxelSize": args.voxel_size,
        "junctionVertices": junction_vertices,
        "clawsRetained": len(claws_after),
        "topologyBefore": before,
        "topologyAfter": after,
        "nonadjacentIntersectionsBefore": intersections_before,
        "nonadjacentIntersectionsAfter": intersections_after,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_DISTAL_REMESH", json.dumps(report))


if __name__ == "__main__":
    main()

import argparse
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector


def parse_args():
    parser = argparse.ArgumentParser(description="Refine the passed-neck bear torso and pelvis without touching face, neck, paws, or claws.")
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(values)


def gaussian(point, center, scale):
    distance = sum(((point[index] - center[index]) / scale[index]) ** 2 for index in range(3))
    return math.exp(-0.5 * distance)


def smoothstep(edge0, edge1, value):
    factor = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return factor * factor * (3.0 - 2.0 * factor)


def fair_posterior(mesh, iterations=100):
    neighbors = [[] for _ in mesh.vertices]
    for edge in mesh.edges:
        first, second = edge.vertices
        neighbors[first].append(second)
        neighbors[second].append(first)
    weights = []
    for vertex in mesh.vertices:
        point = vertex.co
        if point.y < 0.28 or point.z < 0.52:
            weights.append(0.0)
            continue
        posterior = smoothstep(0.28, 0.76, point.y)
        upper_thigh = smoothstep(0.52, 0.88, point.z)
        weights.append(posterior * upper_thigh)
    maximum_move = 0.0
    for _ in range(iterations):
        iteration_start = [vertex.co.copy() for vertex in mesh.vertices]
        for coefficient in (0.38,):
            positions = [vertex.co.copy() for vertex in mesh.vertices]
            updates = {}
            for index, vertex_neighbors in enumerate(neighbors):
                weight = weights[index]
                if weight <= 0.0 or not vertex_neighbors:
                    continue
                average = sum((positions[neighbor] for neighbor in vertex_neighbors), Vector()) / len(vertex_neighbors)
                updates[index] = positions[index] + coefficient * weight * (average - positions[index])
            for index, position in updates.items():
                mesh.vertices[index].co = position
        maximum_move = max(
            maximum_move,
            max(
                ((mesh.vertices[index].co - position).length for index, position in enumerate(iteration_start)),
                default=0.0,
            ),
        )
    return maximum_move


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


def main():
    args = parse_args()
    bear = bpy.data.objects.get("BrownBear_LandmarkSubdivisionCage")
    if bear is None:
        raise RuntimeError("Run from iteration 776")
    claws_before = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if len(claws_before) != 20:
        raise RuntimeError(f"Torso pass requires 20 claws, found {len(claws_before)}")
    protected_before = {
        vertex.index: vertex.co.copy()
        for vertex in bear.data.vertices
        if vertex.co.y < -0.08 or vertex.co.z < 0.38
    }
    moved_vertices = 0
    maximum_move = 0.0
    for vertex in bear.data.vertices:
        point = vertex.co
        if point.y < -0.08 or point.z < 0.38:
            continue
        original = point.copy()
        absolute_x = abs(point.x)
        side = -1.0 if point.x < 0.0 else 1.0
        lateral_ramp = smoothstep(0.02, 0.30, absolute_x)

        abdomen = gaussian((absolute_x, point.y, point.z), (0.68, 0.36, 1.22), (0.48, 0.34, 0.46))
        point.x -= side * 0.115 * abdomen * lateral_ramp

        caudal_belly = gaussian((absolute_x, point.y, point.z), (0.34, 0.56, 0.94), (0.52, 0.30, 0.25))
        point.z += 0.205 * caudal_belly

        posterior_shelf = gaussian((absolute_x, point.y, point.z), (0.46, 0.94, 1.42), (0.54, 0.32, 0.28))
        point.y -= 0.310 * posterior_shelf
        posterior_descent = gaussian((0.0, point.y, point.z), (0.0, 0.94, 1.42), (1.0, 0.32, 0.45))
        point.z -= 0.045 * posterior_descent

        underside_retract = gaussian((absolute_x, point.y, point.z), (0.36, 0.92, 1.27), (0.70, 0.28, 0.20))
        point.y -= 0.140 * underside_retract

        sacral_flatten = gaussian((absolute_x, point.y, point.z), (0.30, 0.82, 1.82), (0.50, 0.28, 0.20))
        point.z -= 0.180 * sacral_flatten

        gluteal_descent = gaussian((absolute_x, point.y, point.z), (0.59, 0.75, 1.05), (0.37, 0.33, 0.48))
        point.x += side * 0.190 * gluteal_descent * lateral_ramp
        lateral_gluteal = gaussian((absolute_x, point.y, point.z), (0.48, 0.76, 1.04), (0.34, 0.36, 0.48))
        point.z -= 0.205 * lateral_gluteal

        intergluteal_cleft = gaussian((absolute_x, point.y, point.z), (0.0, 0.82, 1.02), (0.25, 0.34, 0.38))
        point.z += 0.085 * intergluteal_cleft

        inferior_medial_belt = gaussian((absolute_x, point.y, point.z), (0.0, 0.78, 1.10), (0.38, 0.34, 0.30))
        point.y -= 0.165 * inferior_medial_belt
        point.z += 0.145 * inferior_medial_belt

        lateral_gluteal_shoulder = gaussian((absolute_x, point.y, point.z), (0.62, 0.74, 1.17), (0.32, 0.34, 0.32))
        point.z -= 0.095 * lateral_gluteal_shoulder

        upper_thigh_fill = gaussian((absolute_x, point.y, point.z), (0.58, 0.68, 0.88), (0.34, 0.32, 0.50))
        point.x += side * 0.205 * upper_thigh_fill * lateral_ramp
        point.y += 0.145 * upper_thigh_fill

        proximal_support = gaussian((absolute_x, point.y, point.z), (0.62, 0.58, 0.91), (0.34, 0.40, 0.38))
        point.x += side * 0.125 * proximal_support * lateral_ramp

        low_rump_trim = gaussian((absolute_x, point.y, point.z), (0.86, 0.72, 1.20), (0.28, 0.34, 0.28))
        point.x -= side * 0.080 * low_rump_trim * lateral_ramp

        displacement = (point - original).length
        if displacement > 1.0e-7:
            moved_vertices += 1
            maximum_move = max(maximum_move, displacement)
    fairing_maximum_move = fair_posterior(bear.data)
    bear.data.update()
    protected_displacement = max(
        ((bear.data.vertices[index].co - before).length for index, before in protected_before.items()),
        default=0.0,
    )
    if protected_displacement > 1.0e-9:
        raise RuntimeError(f"Torso pass changed protected anatomy by {protected_displacement}")
    mesh_topology = topology(bear)
    if mesh_topology["boundaryEdges"] or mesh_topology["nonmanifoldEdges"] or mesh_topology["components"] != 1:
        raise RuntimeError(f"Torso pass topology gate failed: {mesh_topology}")
    claws_after = sorted(obj.name for obj in bpy.context.scene.objects if "Claw" in obj.name)
    if claws_after != claws_before:
        raise RuntimeError("Torso pass changed the passed claw set")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_torso_pelvis_critic_gate",
        "source": "iteration-776-lower-head-ridge-removal",
        "method": "bounded continuous torso and pelvis deformation fields",
        "movedVertices": moved_vertices,
        "maximumVertexMove": maximum_move,
        "fairingMaximumMovePerIteration": fairing_maximum_move,
        "protectedMaximumDisplacement": protected_displacement,
        "clawsRetained": len(claws_after),
        "topology": mesh_topology,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_TORSO_PELVIS", json.dumps(report))


if __name__ == "__main__":
    main()

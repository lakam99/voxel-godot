import argparse
import json
import sys
from pathlib import Path

import bpy


def parse_args():
    parser = argparse.ArgumentParser(description="Deform the continuous brown-bear sculpt source toward passed regional authorities.")
    parser.add_argument("--forequarter-blend", required=True)
    parser.add_argument("--hindquarter-blend", required=True)
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(args)


def append_objects(path, names):
    before = set(bpy.data.objects)
    with bpy.data.libraries.load(str(Path(path).resolve()), link=False) as (source, target):
        target.objects = [name for name in source.objects if name in names]
    appended = [obj for obj in bpy.data.objects if obj not in before]
    for obj in appended:
        if obj.name not in bpy.context.scene.collection.objects:
            bpy.context.scene.collection.objects.link(obj)
    return appended


def mirror_target(source):
    mirrored = source.copy()
    mirrored.data = source.data.copy()
    mirrored.name = f"{source.name}_Mirrored"
    for vertex in mirrored.data.vertices:
        vertex.co.x *= -1.0
    for polygon in mirrored.data.polygons:
        polygon.flip()
    bpy.context.scene.collection.objects.link(mirrored)
    return mirrored


def join_targets(objects, name):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    target = bpy.context.object
    target.name = name
    return target


def smoothstep(value):
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)


def add_group(body, name, weight_function):
    group = body.vertex_groups.new(name=name)
    weighted = []
    for vertex in body.data.vertices:
        weight = weight_function(vertex.co)
        if weight <= 0.0:
            continue
        group.add([vertex.index], weight, "REPLACE")
        weighted.append(vertex.index)
    return group.name, weighted


def shrinkwrap(body, target, group_name):
    modifier = body.modifiers.new(name=f"AuthorityProjection_{group_name}", type="SHRINKWRAP")
    modifier.wrap_method = "NEAREST_SURFACEPOINT"
    modifier.wrap_mode = "ON_SURFACE"
    modifier.target = target
    modifier.vertex_group = group_name
    bpy.context.view_layer.objects.active = body
    body.select_set(True)
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    body.select_set(False)


def main():
    args = parse_args()
    body = bpy.data.objects["BrownBear_FusedSculptBase"]
    body.name = "BrownBear_ContinuousAuthorityDeform"
    before = [vertex.co.copy() for vertex in body.data.vertices]
    locked_indices = [vertex.index for vertex in body.data.vertices if vertex.co.y < -1.05]
    old_hind = [bpy.data.objects.get(name) for name in ("BrownBear_LeftHindLimb", "BrownBear_RightHindLimb")]
    for obj in old_hind:
        if obj is not None:
            bpy.data.objects.remove(obj, do_unlink=True)

    right_fore = append_objects(args.forequarter_blend, {"BrownBear_ShoulderSaddlePatch"})[0]
    right_fore.name = "Authority_Forequarter_Right"
    left_fore = mirror_target(right_fore)
    left_fore.name = "Authority_Forequarter_Left"
    rear_parts = append_objects(args.hindquarter_blend, {"BrownBear_FrozenPelvis", "BrownBear_FrozenHindlimb_Left", "BrownBear_FrozenHindlimb_Right"})
    rear_target = join_targets(rear_parts, "Authority_Hindquarter")

    def right_weight(point):
        if point.y < -1.02 or point.y > 0.36 or point.z > 1.78:
            return 0.0
        lateral = smoothstep((point.x - 0.22) / 0.28)
        head_lock = smoothstep((point.y + 1.02) / 0.20)
        return lateral * head_lock

    def left_weight(point):
        mirrored = point.copy()
        mirrored.x *= -1.0
        return right_weight(mirrored)

    def rear_weight(point):
        if point.y < 0.12:
            return 0.0
        return smoothstep((point.y - 0.12) / 0.30)

    right_group, right_indices = add_group(body, "AuthorityForeRight", right_weight)
    left_group, left_indices = add_group(body, "AuthorityForeLeft", left_weight)
    rear_group, rear_indices = add_group(body, "AuthorityRear", rear_weight)
    shrinkwrap(body, right_fore, right_group)
    shrinkwrap(body, left_fore, left_group)
    shrinkwrap(body, rear_target, rear_group)

    for index in locked_indices:
        body.data.vertices[index].co = before[index]
    body.data.update()

    for target in (right_fore, left_fore, rear_target):
        bpy.data.objects.remove(target, do_unlink=True)
    displacements = [(vertex.co - original).length for vertex, original in zip(body.data.vertices, before)]
    locked_max = max((displacements[index] for index in locked_indices), default=0.0)
    if locked_max > 1.0e-8:
        raise RuntimeError(f"Preserved face lock moved by {locked_max}")
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_continuous_authority_deformation_critic_gate",
        "object": body.name,
        "vertices": len(body.data.vertices),
        "faces": len(body.data.polygons),
        "groups": {"foreRight": len(right_indices), "foreLeft": len(left_indices), "rear": len(rear_indices)},
        "changedVertices": sum(value > 1.0e-6 for value in displacements),
        "maximumDisplacement": max(displacements),
        "preservedFaceMaximumDisplacement": locked_max,
        "preservedFaceBoundaryY": -1.05,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_CONTINUOUS_AUTHORITY_DEFORM", json.dumps(report))


if __name__ == "__main__":
    main()

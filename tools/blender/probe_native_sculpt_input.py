import json
import sys
from pathlib import Path

import bpy


def parse_args():
    output = Path("/tmp/native-sculpt-input-probe.json")
    if "--" in sys.argv:
        args = sys.argv[sys.argv.index("--") + 1 :]
        if args:
            output = Path(args[0])
    return output


def view3d_override(obj):
    area = next(area for area in bpy.context.screen.areas if area.type == "VIEW_3D")
    region = next(region for region in area.regions if region.type == "WINDOW")
    return {
        "window": bpy.context.window,
        "screen": bpy.context.screen,
        "area": area,
        "region": region,
        "scene": bpy.context.scene,
        "view_layer": bpy.context.view_layer,
        "active_object": obj,
        "object": obj,
    }, region


def build_probe(output_path):
    active_object = bpy.context.active_object
    override, _region = view3d_override(active_object)
    with bpy.context.temp_override(**override):
        if active_object.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        bpy.ops.object.select_all(action="SELECT")
        bpy.ops.object.delete(use_global=False)
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=5, radius=1.0)
    probe = bpy.context.object
    probe.name = "NativeSculptInputProbe"
    override, region = view3d_override(probe)
    with bpy.context.temp_override(**override):
        bpy.ops.object.mode_set(mode="SCULPT")
        bpy.ops.view3d.view_axis(type="FRONT", align_active=False, relative=False)
        bpy.ops.view3d.view_selected(use_all_regions=False)
    before = [vertex.co.copy() for vertex in probe.data.vertices]

    ready = {
        "status": "ready_for_stroke",
        "region": {"x": region.x, "y": region.y, "width": region.width, "height": region.height},
        "objectMode": probe.mode,
    }
    output_path.write_text(json.dumps(ready, indent=2) + "\n", encoding="utf-8")
    print("NATIVE_SCULPT_INPUT_READY", json.dumps(ready))

    def verify():
        bpy.context.view_layer.update()
        changed = sum(1 for original, vertex in zip(before, probe.data.vertices) if (original - vertex.co).length > 0.000001)
        result = {
            "changedVertices": changed,
            "region": {"x": region.x, "y": region.y, "width": region.width, "height": region.height},
            "objectMode": probe.mode,
        }
        output_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print("NATIVE_SCULPT_INPUT_PROBE", json.dumps(result))
        bpy.ops.wm.quit_blender()
        return None

    bpy.app.timers.register(verify, first_interval=90.0)


build_probe(parse_args())

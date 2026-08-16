import argparse
import json
import sys
from pathlib import Path

import bpy


def parse_args():
    parser = argparse.ArgumentParser(description="Compose frozen bear pelvis and hindlimb authorities for placement review.")
    parser.add_argument("--hindlimb-blend", required=True)
    parser.add_argument("--output-blend", required=True)
    parser.add_argument("--report", required=True)
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(args)


def append_hindlimb(path):
    before = set(bpy.data.objects)
    with bpy.data.libraries.load(str(Path(path).resolve()), link=False) as (source, target):
        target.objects = [name for name in source.objects if name == "BrownBear_HindquarterGate"]
    appended = [obj for obj in bpy.data.objects if obj not in before]
    if len(appended) != 1:
        raise RuntimeError(f"Expected one appended hindlimb, got {[obj.name for obj in appended]}")
    obj = appended[0]
    if obj.name not in bpy.context.scene.collection.objects:
        bpy.context.scene.collection.objects.link(obj)
    return obj


def main():
    args = parse_args()
    pelvis = bpy.data.objects["BrownBear_HindquarterGate"]
    pelvis.name = "BrownBear_FrozenPelvis"
    left = append_hindlimb(args.hindlimb_blend)
    left.name = "BrownBear_FrozenHindlimb_Left"
    left.location.x = -0.36
    right = left.copy()
    right.data = left.data.copy()
    right.name = "BrownBear_FrozenHindlimb_Right"
    right.location.x = 0.36
    bpy.context.scene.collection.objects.link(right)
    output = Path(args.output_blend)
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    report = {
        "status": "pending_hindquarter_placement_critic_gate",
        "authorities": {
            "pelvis": "iteration-672-elevated-pelvis-tail-seam",
            "hindlimb": "iteration-670-measured-hind-paw-length",
        },
        "placement": {
            "leftX": left.location.x,
            "rightX": right.location.x,
            "hipSpacing": right.location.x - left.location.x,
        },
        "geometryPolicy": "Placement-only composite; frozen source vertices are unchanged and overlap is intentional pending accepted extraction topology.",
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_HINDQUARTER_COMPOSITE", json.dumps(report))


if __name__ == "__main__":
    main()

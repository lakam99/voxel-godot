import argparse
import json
from pathlib import Path


PINNED_ITERATIONS = {
    "iteration-058-curve-limb-sculpt-base",
    "iteration-182-continuous-forepaw-planes",
    "iteration-246-distal-rim-notches",
    "iteration-253-c2-forelimb-root",
    "iteration-274-pinna-reorientation",
    "iteration-284-ventral-lip-projection",
    "iteration-289-visible-thorax-envelope-fit",
    "iteration-448-broad-transition-sculpt",
    "iteration-513-rebuilt-shoulder-authority",
    "iteration-531-frozen-forelimb-authority",
    "iteration-589-frozen-load-envelope-safe",
}
HEAVY_SUFFIXES = {".blend", ".blend1", ".png", ".exr", ".tif", ".tiff"}
EVIDENCE_PREFIXES = ("rejected-",)


def parse_args():
    parser = argparse.ArgumentParser(description="Prune reproducible brown-bear study payloads while retaining reports.")
    parser.add_argument("--root", type=Path, default=Path("assets/art-source/brown_bear_poc/studies"))
    parser.add_argument("--keep-latest", type=int, default=1)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--manifest", type=Path)
    return parser.parse_args()


def iteration_number(path):
    try:
        return int(path.name.split("-", 2)[1])
    except (IndexError, ValueError):
        return -1


def main():
    args = parse_args()
    root = args.root.resolve()
    iterations = sorted((path for path in root.glob("iteration-*") if path.is_dir()), key=iteration_number)
    latest = {path.name for path in iterations[-args.keep_latest :]} if args.keep_latest else set()
    retained = PINNED_ITERATIONS | latest
    candidates = []
    retained_payloads = []
    for directory in iterations:
        for path in directory.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in HEAVY_SUFFIXES:
                continue
            record = {"path": str(path.relative_to(root.parent.parent.parent)), "bytes": path.stat().st_size}
            if directory.name in retained or path.name.startswith(EVIDENCE_PREFIXES):
                retained_payloads.append(record)
            else:
                candidates.append(record)
    manifest = {
        "policy": "Retain reports/JSON for every iteration; retain heavy payloads only for pinned authorities, the requested latest open iterations, and explicitly named rejection evidence.",
        "pinnedIterations": sorted(PINNED_ITERATIONS),
        "latestRetained": sorted(latest),
        "candidateFiles": len(candidates),
        "candidateBytes": sum(item["bytes"] for item in candidates),
        "retainedHeavyFiles": len(retained_payloads),
        "retainedHeavyBytes": sum(item["bytes"] for item in retained_payloads),
        "applied": args.apply,
    }
    if args.apply:
        for item in candidates:
            path = root.parent.parent.parent / item["path"]
            path.unlink()
        for directory in sorted(root.rglob("*"), reverse=True):
            if directory.is_dir() and not any(directory.iterdir()):
                directory.rmdir()
    manifest_path = args.manifest or root.parent / "STUDY_RETENTION_MANIFEST.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()

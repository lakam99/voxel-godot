# Brown Bear Sculpt PoC

This package is the authored-creature pilot. It is separate from
`assets/visual/generated/` and does not alter procedural trees or the existing
generated-mob pipeline.

## Current authority

The active PoC is anatomy-first. It builds and reviews a continuous subdivision
cage before any high-frequency sculpting, texture, rig, or runtime export.
Construction volumes and superseded fused studies are evidence only; they are
not production mesh authority.

Generate the current forequarter cage and Blender-independent preflight with:

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/build_bear_forequarter_subdivision_cage.py -- \
  --output-blend /tmp/brown_bear_forequarter_cage.blend \
  --report /tmp/brown_bear_forequarter_cage-report.json

/Users/lakam99/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  tools/blender/preview_bear_forequarter_cage_standalone.py \
  --builder tools/blender/build_bear_forequarter_subdivision_cage.py \
  --output-root /tmp/brown-bear-cage-review
```

The standalone preflight executes the same deterministic vertex/face functions,
writes an OBJ, verifies topology, and renders unsubdivided wire plus two-level
Catmull-Clark clay evidence. It is a diagnostic fallback, not permission to skip
the Blender wire, subdivided-clay, and raking-light gates.

## Reference evidence

Build the compact regional anatomy library with:

```bash
/Users/lakam99/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  tools/blender/build_bear_anatomy_reference_library.py
```

Downloaded normalized images, contact sheets, manifests, studies, review
renders, textures, and Blender backups are reproducible working cache and remain
ignored. Their durable anatomical conclusions belong in
`LEARNING_JOURNAL.md`.

## Native sculpt gate

After the critic accepts primary and secondary anatomy, native Sculpt Mode work
requires Accessibility-authorized desktop input. `agent_desktop_input.swift`
provides the pointer/keyboard bridge; Blender Python remains responsible for
scene setup, masks, checkpoints, rendering, reports, and export. A reported
brush operation with zero measured vertex displacement is always rejected.

Every build must pass all of these gates before an asset is admitted to source
or export directories:

1. Cage contract: one continuous, deformation-ready anatomical mesh; no visible primitive fallback or folded/nonmanifold topology.
2. Visual contract: identical wire, clay, silhouette, and raking-light views independently read as a realistic brown bear.
3. Critic contract: an independent veteran critic gives an explicit anatomy pass; clean topology counters alone cannot pass.
4. Native-sculpt contract: a real foreground Brush Asset drag changes source vertices without moving frozen landmarks.
5. Runtime contract: the accepted source is retopologized as needed, UV-unwrapped, rigged, exported to GLB, and kept separate from the generated tree pipeline.

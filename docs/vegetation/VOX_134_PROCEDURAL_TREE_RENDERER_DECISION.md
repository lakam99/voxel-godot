# VOX-134 Procedural Tree Renderer Decision

## Decision

Production uses the staged hybrid renderer:

```text
deterministic TreeSpawnService recipe (worker)
  -> one continuous structural bole MeshInstance3D
  -> one MultiMeshInstance3D for distal branches
  -> one MultiMeshInstance3D for foliage clusters
  -> TreePublicationQueue commits one bounded renderer stage per frame
```

`ProceduralTreeVisualFactory` owns the shared meshes, materials, shader
parameters, continuous bole, and per-tree visual roles. `TreePublicationQueue`
owns worker scheduling, caching, LOD transitions, and bounded main-thread
publication. The tree's existing `StaticBody3D` owns only its bounded gameplay
trunk collision and stable mutable identity.

This is deliberately not a shader-only topology generator. A spatial shader
deforms vertices supplied to it; it cannot create a connected, independently
branching tree graph. The mathematical recipe therefore supplies bounded branch
and foliage transforms, while shared GPU meshes and shaders provide taper, bark
scale, curvature, stable variation, and wind.

## Candidate comparison

Command:

```powershell
.\tools\run-tree-chunk-batch-prototype.ps1 `
  -Visible `
  -ReportPath artifacts\vegetation\vox134-renderer-comparison-current.json
```

This is intentionally headed: Godot's dummy headless renderer cannot allocate
the MultiMesh resources being compared. The prototype used identical canonical
recipes for twelve trees. Candidate A (chunk/material/LOD MultiMeshes)
preserved all 4,496 distal branch and 7,080 foliage instances and reduced the
submission-role estimate from 36 to 27. It
did not create collision nodes. However, removing one tree took 3.868 ms and
required 972 slot swaps; it also reserved 2.25 MiB of fixed-capacity instance
storage for this small fixture. That is above the production publication target
and would require a second queued batch-compaction system before it could become
the authoritative live renderer.

Candidate B (the selected staged hybrid renderer) keeps the visual ownership
local to one stable tree body, so removal is atomic from gameplay's perspective
and visual construction can be published in small queue stages. It has one
continuous close-range bole rather than a stack of cylinders; all distal wood
and foliage remains GPU-instanced. There are no branch or leaf SceneTree nodes,
physics bodies, or per-tree animation loops.

Candidate A remains an isolated benchmark/prototype, not a parallel production
pipeline. It may be reconsidered only if profiling shows draw submissions are a
measured gameplay bottleneck and its slot compaction can be made just as bounded
as production publication.

## Parameter and material contract

Each instanced branch and foliage cluster uses a shared primitive plus a
transform and MultiMesh custom data. The data carries tapered-end ratio, wind
weight, deterministic phase, and bark/leaf variation. The shared shaders use
those values for wind, curvature, and bark scale; no unique per-tree material,
GPU readback, or RenderingDevice synchronization is used. Near/mid/far/impostor
LOD selects a bounded recipe reduction before publication, with a distinct
shadow range in the render policy.

## Current measurements

Command:

```powershell
.\tools\run-procedural-tree-performance-benchmark.ps1 `
  -ReportPath artifacts\vegetation\vox133-137-current-recipe-publication.json
```

On the Windows Godot 4.6.1 Forward+ build, staged publication reported p99
0.289 ms, max 0.311 ms, and worst queue frame 0.346 ms. This meets the
publication self-time target (p99 <= 1 ms; max <= 2 ms). Warm same-request
recipe cache p99 was 2.729 ms and near-to-mid recipe reduction reuse p99 was
2.072 ms; both occur in worker/cache paths, never as an unbounded renderer
commit. The dense bushy-oak near recipe was the slowest cold worker recipe at
258.980 ms p99, so it remains a throughput/queue-depth metric rather than a
main-thread frame-time cost.

The benchmark does not prove GPU frame time, foliage overdraw, or complete live
traversal behavior. Those remain VOX-135/136/137 headed visual and normal-runtime
release gates.

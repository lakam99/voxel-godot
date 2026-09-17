# N1 Standalone Core, Build, Coverage, And API Reflection

Date: 2026-09-17

Migration authority: `CODEX_NATIVE_WORLD_BACKEND_MIGRATION_HANDOFF_2026-09-17.md`

Status: N1 complete; no production generator or collision-authority cutover

## 1. Outcome and source identity

N1 established the Godot-free C++17 core, deterministic identity primitives,
standalone test executable, reproducible debug/release build, machine-readable
coverage gate, thin Godot adapter smoke, and a source-bound read-only inventory
of the installed Voxel Tools ClassDB surface.

| Change | Commit | Meaning |
|---|---|---|
| Pure core, SCons integration, tests, coverage automation, and adapter smoke | `f6b40c8964e4b5f7912cda079e4740b365abe62b` | Establishes the N1 core and build/test boundary |
| Voxel Tools API reflection probe, validator, and runner | `d44ab0fb71603f82dc5c7dc23f6128c78499d1fb` | Records the installed API surface without invoking candidate APIs |

The authoritative core receipt is
`artifacts/native-world-backend/n1-final-19/report.json`, SHA-256
`2e88878247ed37b953f1960a46c6c8dc23df2a7bd713b3ab2956077a0db25f35`.
It records `status: passed`. The receipt was produced before the core files
were committed, so its Git field names the N0 commit `3472da0` and its exact
dirty inventory. The immutable source, project-input, dependency, compiler,
build-manifest, binary, installed-copy, and adapter digests in that receipt are
the provenance link to `f6b40c8`; the recorded inventories were unchanged
before and after the run.

The authoritative reflection receipt is
`artifacts/native-world-backend/n1-api-reflection/2026-09-17T195812-689Z-d616e052/report.json`,
SHA-256 `d773eeb49b97d945115b46a85094f198fff4792c41aa9d3f0cc0db2282e09c53`.
It records the committed core at `f6b40c8` plus the exact four reflection files
later committed as `d44ab0f`.

`n1-final-18` and all earlier N1 reflection reports are superseded and are not
acceptance evidence.

An accidental later invocation passed `--help` to the N1 runner, which has no
help mode. It produced the ignored failed diagnostic
`artifacts/native-world-backend/n1-2026-09-17T20-07-50-255Z-12b37752/report.json`
after the debug DLL install was denied while a baseline Godot run held the
file. It changed no source, its owned processes drained naturally, and it is
not N1 evidence.

## 2. Delivered boundary

The pure core under `native/world_backend/core` contains:

- signed cell coordinates with checked range conversion and defined negative
  floor-division/modulo behavior;
- the preserved Unicode-code-point seed hash;
- local SHA-256 and canonical `SourceKey`, `SnapshotKey`, and `ArtifactKey`
  serialization/digests;
- the complete frozen N0 revision map and world constants; and
- owner-generation, cancellation, source-revision, and stale-result decisions.

The core contains no Godot `Object`, `Node`, `RID`, `Variant`, `Dictionary`,
singleton, scene-tree, or callback dependency. The canonical source vector is
also reproduced by an independent Node implementation. The adapter exposes a
minimal smoke method on the existing `TerrainMeshingBackend`; it does not move
generation, terrain volume, collision, saves, navigation, or gameplay policy
into native authority.

The SCons stack now builds an explicit core library and standalone test target
alongside the existing extension. It inventories the complete core denominator,
extension sources and headers, build inputs, N1 runner inputs, dependency, and
installed outputs. Debug and release builds produce PDBs and use strict floating
point for the new pure core. The receipt pins the actual MSVC Build Tools
installation (`19.44.35228`, toolset `14.44.35207`), compiler/linker/vcvars
hashes, clean `godot-cpp` revision
`ba0edfed90512ec64aba51d4295a3e7e30112f86`, and Godot
`4.6.1.stable.official.14d19694e`.

## 3. Standalone tests and coverage

| Configuration / metric | Result |
|---|---|
| Debug standalone tests | 11/11 passed |
| Release standalone tests | 11/11 passed |
| Pure-core lines | 482/482, 100% |
| Pure-core functions | 46/46, 100% |
| Pure-core branches | 198/198, 100% |
| Coverage canary lines | 8/12 |
| Coverage canary functions | 2/3 |
| Coverage canary branches | 2/4 |

The coverage denominator is exactly these five pure-core translation units:

- `authority.cpp`
- `coordinates.cpp`
- `legacy_seed_hash.cpp`
- `sha256.cpp`
- `world_identity.cpp`

The 100% claim does **not** cover the Godot adapter, the pre-existing terrain
meshing extension, Voxel Tools, the GDScript smoke/probe, or Node automation.
The deliberately incomplete canary proves that the LLVM 23.1.1 parser reports
uncovered lines, functions, and both branch edges rather than silently
normalizing incomplete coverage to success.

## 4. Adapter and installed API evidence

The Godot adapter evidence is a load, explicit method invocation, and unload
smoke only. It proved that the installed debug extension linked the new core
and returned the independent canonical source digest
`abbd66bd21010fe6f0a4b9406264fdefefa05bc793ed8a27ce2c7c59424736bf`
under the exact Godot commit above. It is not standalone coverage, production
generation parity, a collision installation test, or gameplay acceptance.

The Voxel Tools probe inventoried 28 classes, found all 8 required classes,
and validated 18 required structural anchors, including declared and inherited
methods, properties, signals, constants, and enums. It bound the complete probe
input closure, project/native sources, native-world manifest, Godot binaries,
custom extension binaries, and installed Voxel Tools editor/release binaries.

Read-only ClassDB reflection observed generator/stream assignment members. It
did not observe the nominated direct per-block collision-injection, exact
collision-install/physics-acknowledgement, or viewer hard-task-cap names in the
reflected surface. Absence means only that those exact candidates were not
visible in this installed ClassDB surface. It is not proof that a capability is
universally impossible, and it says nothing about non-ClassDB C++ entry points,
other names/compositions, or other builds. The probe invoked no candidate API,
installed no collision, mutated no gameplay, and proved no physics or rendering
behavior. N2 must make the integration decision with an actual vertical-slice
fixture.

## 5. Lifecycle, review, and deletion audit

All 15 owned-process watchdogs in `n1-final-19` completed with functional exit
code zero and authoritative natural zero membership. No PID/name kill or forced
cleanup was used. The reflection run independently reached authoritative natural
zero membership with functional exit code zero and clean cleanup.

Independent review passed after the implementation corrected three provenance
and contract blockers: canonical `SourceKey` field order, complete installed
extension/build-input binding with before/after immutability, and proof that
SCons selected the pinned Build Tools installation and toolset. No unresolved
high-severity N1 review finding remains.

N1 deleted no live generator, sampler, terrain-volume, save, collision,
streaming, navigation, route, structure, ecology, or gameplay authority. It made
no production generator cutover and installed no second collision owner. The
legacy seed hash and identity utilities now have a native implementation, but
production callers remain on their existing authorities until their N3/N4
parity and caller-deletion gates pass. The migration ledger therefore keeps all
runtime deletion candidates pending for N3 and later.

## 6. Evidence boundary and next gate

N1 proves a reproducible standalone native foundation and a loadable thin
adapter. It does not prove terrain-source parity, delta resolution, collision
geometry, collision installation acknowledgement, seams, edits, reload,
cancellation through a real vertical slice, live movement, or Gate-5
acceptance. Those are N2 and later gates. Original Gate 5 remains open.

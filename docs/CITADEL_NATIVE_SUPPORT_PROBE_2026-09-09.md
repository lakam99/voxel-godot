# Native support-query feasibility

Production remains at 1f8814e, with first headed scene-ready at 157.130s.
This investigation does not change production or establish a new arrival time.
It identifies a larger candidate optimization toward the unmet 90-second target.

## Isolated implementation

artifacts/citadel-runtime-integration/native-support-probe contains a standalone
CitadelSupportKernelProbe extension and a BuildingBlueprint subclass used only
by diagnostic scripts. The extension is loaded explicitly in those processes;
it is not installed in the production terrain backend.

GDScript supplies the actual ordered neighborhood candidate membership, object
indices for self-exclusion, classified eligibility, target recipe inputs and
Godot-computed transforms. The C++ query performs the existing XZ rejection,
preferred/fallback passes, embedded early return and nearest-gap selection.
Vector3 operations retain float storage, while scalar calculations use double.
The compiler uses /O2 /fp:strict /EHsc /MT and C++17; no fast-math reassociation
is requested. The current whole-proof benchmark includes input preparation and
native call overhead, not merely the inner C++ loop.

The first prototype still marshaled every exact-XZ shortlist. The second passes
the existing ordered neighborhood once per grid origin, with the same XZ
predicate executed inside the native loop. This removes repeated GDScript
column filtering without changing membership order or query results.

## Evidence

All evidence directories below are under artifacts/citadel-runtime-integration.
The full replay uses final source38, pinned through its receipt to SHA
190e1f310f61eadc2d372a76a743dc6ddf4bcf0defda6120c4e91c943e2df8ea.

- native-support-cost-01: baseline 2.061s, first prototype 1.587s.
- native-support-cost-02: baseline 2.091s, neighborhood prototype 1.040s.
- native-support-cost-release-01: baseline 2.052s, release prototype 1.006s.

All three compare complete physical reports and resolved snapshots byte-for-byte,
and all four checks passed. This approximately halves the complete proof in the
replay. It does not mean total source generation or game arrival is halved.

native-support-controls-01 and native-support-controls-release-01 each passed
55 checks across 10,692 contact queries. They compare complete contact dictionaries,
including surface/gap/contact mode, plus complete physical reports and snapshots.
Controls cover preferred/fallback order, equal gaps, embedded competition,
rotated candidates, contact thresholds, coordinates at +/-100000, movement,
removal, reordering, repeated validation and owner-exit cleanup. An invalid
target index was also checked. These are synthetic contracts, not gameplay.
Every Godot diagnostic exited cleanly with owned-process zero.

Commands use the existing watchdog runner:

```text
node artifacts/citadel-runtime-integration/native-support-probe/build.mjs
node artifacts/citadel-runtime-integration/native-support-probe/build.mjs --release
node tools/run-building-contract.mjs -Contract res://artifacts/citadel-runtime-integration/native-support-probe/Cost.gd -OutputDirectory artifacts/citadel-runtime-integration/native-support-cost-02 -ReportEnvironment PHYSICAL_COST_REPORT -TimeoutSeconds 120
node tools/run-building-contract.mjs -Contract res://artifacts/citadel-runtime-integration/native-support-probe/Controls.gd -OutputDirectory artifacts/citadel-runtime-integration/native-support-controls-01 -ReportEnvironment NATIVE_SUPPORT_CONTROLS_REPORT -TimeoutSeconds 120
```

The release runs used a Node spawn wrapper to supply NATIVE_SUPPORT_EXTENSION as
res://artifacts/citadel-runtime-integration/native-support-probe/probe-release.gdextension,
with the separate release output directories listed above.

The prototype links pre-existing libraries in the sibling original project's
godot-cpp directory without modifying that dependency. Its clean Git revision is
ba0edfed90512ec64aba51d4295a3e7e30112f86; generated headers identify Godot 4.6.0.
Both debug and release libraries loaded and passed parity in the installed
Godot 4.6.1 process. The same revision has now been cloned into this worktree's
ignored native/terrain_meshing/godot-cpp directory for an isolated production
build. No game files or installed binaries were copied or replaced.

Prototype SHA256s:

```text
kernel.cpp        986055d938066a2df6cec1c755b572cce0876c926415728985dbd0403221ae99
probe.dll         45df68d70557a3cb961e1a795e6cc1d31978ccf5346b4bb2a5a513c5e11e475c
probe.release.dll add7e2fa6e23445e9acdac581c1b0f07fb61e435422433d9e39c7b0611c4c2bd
```

## Required production guards

The read-only critic judged the gain material enough for a candidate, not a
promotion. The prototype wrapper is deliberately not production-ready:

- Enable native records only during the explicitly owned support-resolution
  pass; _validation_cache_active alone is too broad for fresh direct queries.
- Restrict acceleration to exact supported base/Memo implementations. Preserve
  existing virtual behavior for custom subclasses and unknown target objects.
- Mirror resolution-entry, reindex, cancellation and owner-exit invalidations,
  including nested cancellation. Keep the native object and maps private.
- Do not silently skip invalid native indices as the probe does. Wrapper/kernel
  inconsistency needs an explicit failure, not plausible unsupported geometry.
- Pin reproducible binding/API/precision/compiler inputs, verify both binary
  variants, and explicitly define the unavailable-native-class behavior.
- Keep registration separate from terrain methods and preserve all higher-level
  physical, root, dependency, cancellation and navigation contracts.

After integration, use existing cache/cancellation/differential contracts, then
full source, exact parity, continuation and headed checks. Only those production
measurements can establish the realized arrival benefit. No further source or
headed run was warranted for the unchanged production implementation here.

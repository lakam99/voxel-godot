# N3 to N5 real-source physics handoff — 2026-09-23

The focused `N3N5PhysicalHandoffFixture` uses `NativeWorldBackend` padded voxel bytes, `NativeTerrainTriangleArtifactProducer`, and `NativeResidentCollisionOwner` in real Godot Forward+ physics. Its two-block pinned demand contains one nonempty surface block and one empty upper block. The source snapshot remains pending before and after the first row; it becomes ready only after both source-owned rows exist with the exact planner closure token and source identity. The physical owner then installs the real Transvoxel triangles, acknowledges both blocks, and a `CharacterBody3D` contacts the nonempty collider before actor admission releases.

A durable native edit increments source revision. The old physical receipt becomes stale, a new producer's incomplete source stays pending, the old identity is rejected, and the complete new source republishes both blocks with a new physical receipt. `stop_and_drain` leaves no owner bodies. The owner now preserves a source's honest `pending` state and reason instead of treating it as a terminal revision mismatch; exact identity checks still run for ready snapshots.

Command from the isolated N5 project root:

```powershell
node tools/run-n3-n5-physical-handoff.mjs
```

The headed report is `artifacts/native-world-backend/n3-n5-physical-handoff-1790178747658-242cd010/report.json`: `passed: true`, exit 0, one solid and one empty block, actor contact, exact first and second physical receipts, and one-frame physics acknowledgement per block. Shape preparation reached 2.581 ms per block; the first producer `advance()` peaked at 36.401 ms. This is **not** proof of a 6 ms frame budget or stall-free loading; full native meshing/copy and physics publication need measured queue budgets at larger closures.

This fixture is a source and physics service test that connects the producer directly to the owner. It does not exercise the composed `NativeTerrainRuntimeOwner` artifact broker or live gameplay. `productionCutover` remains false. The production runtime still uses Voxel Tools collision. The 4,096-block resident cap cannot cover a valid 4,913-block planner closure; deterministic physical partitions, safe retirement, and one logical complete readiness are required before startup or live edit binding. Main menu, Continue, NPC passage, and Gate 5 remain unaccepted.

# N5 windowed physical receipt contract — 2026-09-23

`NativeWindowedCollisionReadiness.evaluate()` is a pure, fail-closed gate over N3's current `n3-mesh-window-layout/v1` and N5 physical receipts. It checks the exact 16×16×16 spatial partition, unique window IDs/tokens and block membership, and that the union contains every current required block exactly once. Each window receipt must carry the current source/request identity, local window token, exact resident blocks and a physics frame. A missing or stale receipt leaves readiness pending; a duplicate, gap, or malformed layout fails. The logical closure token appears only in the aggregate result, allowing an unchanged local window receipt to survive a distant demand change.

Focused synthetic contract command from the isolated N5 project root:

```powershell
$env:N5_WINDOW_AGGREGATE_REPORT = 'C:\Users\arkam\Documents\Codex\2026-06-18\goal-develop-a-3d-voxel-seed\outputs\voxel-biome-world-godot-native-n5\artifacts\native-world-backend\n5-window-aggregate-contract-2.json'
& 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe' --headless --path . --script res://scripts/testing/native_world/N5WindowAggregateContract.gd
```

The report passed for a 4,913-block logical closure across eight windows (largest 4,096), missing window, stale local token, overlapping membership, and a distant new block that reuses eight old local receipts while the aggregate remains pending until the ninth window is present. The headed `N5ResidentCollisionOwnerFixture.tscn` also passed after adding exact resident membership and local provenance to its physical receipt (`artifacts/native-world-backend/n5-resident-aggregate-receipt.json`).

This is a synthetic aggregate contract and local physics mechanism fixture. It does not yet bind N3's real window facade objects, retire obsolete physical owners, or claim Main/Continue readiness. The runtime still uses Voxel Tools collision. Production binding must track all old owners until explicitly drained behind actor admission and must never infer physical retirement from a stale receipt alone.

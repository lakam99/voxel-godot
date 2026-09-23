# N5 windowed physical receipt contract — 2026-09-23

`NativeWindowedCollisionReadiness.evaluate()` is a pure, fail-closed gate over N3's current `n3-mesh-window-layout/v1` and N5 physical receipts. It checks the exact 16×16×16 spatial partition, unique window IDs/tokens and block membership, and that the union contains every current required block exactly once. Each window receipt must carry the current source/request identity, local window token, exact resident blocks and a physics frame. A missing or stale receipt leaves readiness pending; a duplicate, gap, or malformed layout fails. The logical closure token appears only in the aggregate result, allowing an unchanged local window receipt to survive a distant demand change.

Focused synthetic contract command from the isolated N5 project root:

```powershell
$env:N5_WINDOW_AGGREGATE_REPORT = 'C:\Users\arkam\Documents\Codex\2026-06-18\goal-develop-a-3d-voxel-seed\outputs\voxel-biome-world-godot-native-n5\artifacts\native-world-backend\n5-window-aggregate-contract-2.json'
& 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe' --headless --path . --script res://scripts/testing/native_world/N5WindowAggregateContract.gd
```

The report passed for a 4,913-block logical closure across eight windows (largest 4,096), missing window, stale local token, overlapping membership, and a distant new block that reuses eight old local receipts while the aggregate remains pending until the ninth window is present. The headed `N5ResidentCollisionOwnerFixture.tscn` also passed after adding exact resident membership and local provenance to its physical receipt (`artifacts/native-world-backend/n5-resident-aggregate-receipt.json`).

The 4,913-block aggregate contract is synthetic, and the local owner fixture uses fixture-owned rows. The runtime still uses Voxel Tools collision. Production binding must track all old owners until explicitly drained behind actor admission and must never infer physical retirement from a stale receipt alone.

## Real N3 window facade handoff

The focused headed `N3N5WindowedPhysicalFixture` now uses N3's retained artifact broker and parameterless `collision_window_source` facade. It requests every block in a two-block planner closure, waits for the facade's complete native triangle rows, installs them through the N5 physical owner, and evaluates the actual N3 layout against the owner's physics receipt. The aggregate is pending without the receipt and ready with it; a `CharacterBody3D` contacts the nonempty block while the adjacent upper block is physically empty.

After demand shifts to a distant window, the old facade reports pending with retained rows and the new aggregate is pending for the missing physical window. A premature retirement request is rejected. The physical owner's own `stop_and_drain()` returns its pinned window token and zero remaining bodies; that exact receipt is accepted by `acknowledge_collision_window_retired`, after which the old facade reports retired. The fixture ends without admitting gameplay for the new distant window.

Run `node tools/run-n3-n5-windowed-physical.mjs` from the isolated N5 project root. The headed report `artifacts/native-world-backend/n3-n5-windowed-physical-1790180053672-6f5e6c09/report.json` passed with exit 0, one-frame physical acknowledgement per block, actor contact, source retirement handshake, and no Godot errors. This is a source/physics service fixture. It does not exercise `NativeTerrainRuntimeOwner`, Main/Continue startup, multi-window live publication, or the full 4,913-block physical set. Production cutover remains false.

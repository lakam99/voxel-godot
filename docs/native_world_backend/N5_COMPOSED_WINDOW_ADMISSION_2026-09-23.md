# N5 composed window admission — 2026-09-23

`NativeWindowedCollisionCoordinator` is a composed Node3D that owns actor admission barriers and collects actual N5 physical receipts for the current N3 window layout. Each barrier is bound to the coordinator's aggregate `physical_receipt`, so a single ready window cannot release movement while another required window is missing. The coordinator also checks for old physical owners outside the current layout before claiming readiness. Motion and placement ingress consult every active barrier.

When an owner must be replaced, the old barrier stays active while a new source-identity barrier is opened over the same region. The coordinator requires actor clearance, drains the old owner, passes its own token-bearing zero-body drain receipt to the N3 retirement API, then permits the new owner to publish. `release_barriers` checks the current aggregate receipt, that the new barrier still covers the old region and has completed clearance, and only then transfers/releases the old hold followed by the new hold. Stopping the coordinator terminal-holds active barriers, drains child owners, and denies subsequent motion or placement.

Focused headed commands from the isolated N5 project root:

```powershell
node tools/run-n3-n5-windowed-physical.mjs
node tools/run-n3-n5-two-window-startup.mjs
```

The first report, `artifacts/native-world-backend/n3-n5-windowed-physical-1790180715667-343bf876/report.json`, passed with native source revision 0→1 and cancellation epoch 1→2 after a durable edit. It recorded two simultaneous actor holds, denied crossing motion and placement before and after old-owner drain, a pending aggregate before new installation, new native-row physics acknowledgement, a ready aggregate, both holds released, and motion/placement admitted afterward. The old owner drained to zero bodies; final coordinator drain left zero children and active barriers.

The second report, `artifacts/native-world-backend/n3-n5-two-window-startup-1790180804497-e72f7fe5/report.json`, passed with four source-owned native blocks across two spatial windows. After the first physical window, aggregate readiness and barrier release remained pending. After the second, the aggregate and release were ready; a real `CharacterBody3D` contacted native terrain. Stopping with a fresh active barrier prevented release and subsequent motion, and drained all child owners. Maximum broker `advance()` in that focused run was about 2 ms.

These are headed source/physics fixtures, not normal gameplay. They do not exercise `NativeTerrainRuntimeOwner`, Main/Continue, NPC passage, the 4,913-block physical set, or production collision cutover. `productionCutover` remains false. The N3 distant-edit local proof protocol is still being implemented; until that lands, a global durable edit reissues each window's physical identity.

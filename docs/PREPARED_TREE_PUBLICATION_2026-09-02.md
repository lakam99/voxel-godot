# Shared prepared-tree publication entry

The generic `make_tree_from_runtime_request` entry accepts an existing production
tree request. It calls the same extracted body/harvest/collider/navigation-hook
and visual-queue path as ordinary `make_tree`. Ordinary ecology sampling, RNG
consumption and natural-prop exclusions remain on the ordinary entry only.

Prepared placement is parent-local with explicit yaw; the parent must be rigid
and upright. The copied request's world position/yaw are bound once. Genetics,
recipe identity and dimensions are not resampled. Unsupported dimensions reject
rather than being silently clamped. A player overlap defers before creating the
body or queue request; it does not use the existing relocation helper. Removed
props skip without creating or changing a durable removal delta.

The lifecycle caller must supply stable durable IDs, prevent duplicate bodies,
retry deferred publication, and unload its own bodies. `published` means the
body exists and its visual is queued, not that the visual is complete. There is
no citadel runtime caller yet.

Verification from the feature worktree, with a fresh output directory:

```powershell
./tools/run-prepared-tree-publication-contract.ps1 -OutputDirectory artifacts/visual/prepared-tree-contract-20260902-d
```

43/43 headless source/service checks passed against pinned baseline `11cf54b`:
ordinary RNG/spec/body/queue identity in five biomes with and without exclusion;
shared-path extraction; an actual composer-produced tree request; exact genetics,
dimensions, yaw and transformed queue placement; unchanged input; existing
navigation notification (spy); retryable overlap; removed-prop skip; malformed
dimensions/request, unready parent and scaled-parent rejection.

Reports are `report.json`, `stdout.log`, `stderr.log` and `watchdog.json` in that
directory. The source-extraction harness uses real request construction and queue
intake, with explicit navigation/overlap spies and queue processing disabled.
It is NOT live gameplay or rendered-tree evidence. Stderr is empty; natural
exit 0, clean watchdog and zero owned processes.

Main also preloaded the entire `Main.gd` inheritance chain, Source and Site in
`artifacts/citadel-runtime-integration/shared-tree-parse-01/run.gd`: clean compile,
natural exit 0, empty stderr and owned-process zero. That run instantiated no game.

No headed launch, renderer completion, harvesting interaction, save round-trip,
normal-game citadel hookup, crowd behavior or runtime frame-budget acceptance
is claimed. Earlier failed helper attempts remain in the artifact directory.
Run `c` also passed, but used moving HEAD as its old implementation. The critic
required immutable baseline binding; run `d` pins the full pre-extraction commit
so future commits cannot turn this into a self-comparison.

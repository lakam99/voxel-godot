# Citadel publication preparation: source decoding and stall inventory

Parent `67f1507`, branch `codex/citadel-visuals-clean`. The native admission
checkpoint is committed. This next chunk supplies a worker-side source decoder
and measures the existing publisher; it does not yet activate buildings in Main.
Independent critic review approved this focused decoder/diagnostic commit after
checking source bindings, complete reports, logs and owned-process cleanup.
No headed launch is authorized or claimed.

## Reusable source decoder

`scripts/buildings/BuildingPublicationSource.gd` restores the accepted building
and furniture snapshots for existing publishers. It uses the existing blueprint
copy path, preserves represented thin dimensions, restores furnishings directly
without rerunning placement filters, and requires the captured access-reservation
array (explicitly empty is valid). Full ordered snapshots must round-trip exactly.
Duplicate IDs, invalid poses and constructor normalization that changes accepted
data fail. Cancellation returns no partial objects. This belongs on an owned
worker: copying/validating whole source snapshots is not frame-budgeted work.

Command from the project root, using a fresh output directory on repeats:

```powershell
./tools/run-building-publication-source-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/publication-source-02
```

Result: **19/19 checks plus a separate different-worker-thread check pass**;
the complete actual source restores in 164.566 ms on that worker. Input is
`actual-site-source-05/result.bin`, SHA256
`7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf`:
seed `atlas-1492`, site region `(1,-3)`, recipe `1298433643`, scale `1.25`,
4,703 building parts and 210 furnishings. The actual reservation array is empty;
nonempty-reservation preservation and no-refilter behavior are synthetic controls.
The earlier source-01 passed 18 checks before mandatory-field coverage was added.

The wrapper records source hashes in `launch.json` and verifies them after exit.
`report.json`, `stdout.log`, `stderr.log` and `watchdog.json` are in the output
directory. Final source-02 has empty stderr, natural exit 0 and zero owned
processes. There is no scene publication, recipe rebuild, collision test or
visual-fidelity acceptance in this decoder contract.

## Existing publisher stall: diagnostic evidence

```powershell
./tools/run-citadel-publication-preflight.ps1 -OutputDirectory artifacts/citadel-runtime-integration/publication-preflight-01
```

This test restores that same frozen source on a worker, then calls the real
`BuildingPartPublisher.begin_publication` on the main thread with a synthetic
empty parent. Instrumentation delegates to unchanged production methods and
uses the public structural-authority option for timing the same blueprint's
physical validation. It does not substitute a successful validation result.

Observed main-thread begin: **18,871.290 ms**. Stage observations:

| Stage | Time | Interpretation |
| --- | --- | --- |
| Raised-route diagnostic interval | approximately 9,218 ms | Inferred upper bound between clear completion and physical-validation entry; includes print overhead |
| Physical validation | approximately 9,615 ms | Actual validation of the same restored blueprint |
| Surface-history setup | approximately 8.2 ms | Main-thread preparation |
| Paving preparation | approximately 2.4 ms | Main-thread preparation |
| Masonry initialization | approximately 18.6 ms | Returns with masonry still pending |

The publisher's existing `publication_usec` remains zero at this point; it
excludes begin. Calling the existing “incremental” publication API therefore
does not remove this stall. These measurements identify work to move/slice;
they are not acceptable frame times or a performance pass.

Preflight-01 is **failed diagnostic evidence (11/12)**: begin returned ready
without publishing parts, but its physical-contract resolution changed the
blueprint snapshot. Furniture stayed exact. This failure is retained, not
relabeled green because the useful timing ran. Logs contain no
engine errors; the watchdog records natural functional exit 1 and zero owned
processes. Masonry remains pending, and no trees, doors or parts were published.

The follow-up `publication-preflight-02` uses the same command with that fresh
output directory. It retains the preservation failure (**12/13 checks**), and
captures typed snapshots and the complete mutation inventory. Raised-route
diagnostics resolve physical contracts, changing 3,410 part intents and adding
physical facts across all 4,703 parts. Physical validation resolves them again,
changing 3,389 classifications from `building_part_taxonomy` to `recipe`. No
geometry or non-physical recipe fields change, and no mutations occur after
physical validation. Begin takes 19.678 seconds including intermediate snapshot
captures; this instrumented duration is not a clean isolated timing. Source
hashes remain unchanged, logs have no engine errors, and owned processes are
empty after natural functional exit 1. The typed mutation artifact is diagnostic
evidence only, not a runtime cache or replacement source authority.

## Authority boundary and remaining work

The critic approved reusing the existing building/furnishing publishers and
shared tree-request API, with one site owner rooted at `profile.origin` exactly
once. `CitadelBlueprintBuildJob` is not a publication service and must not rerun
the recipe after an accepted Site snapshot. Runtime access must wait for real
geometry/physics and door readiness, not only part counts.

Before production activation, extract owned preparation for the expensive
checks, preserve the old/new complete results (including derived physical
facts), and measure begin, bounded part batches and finish separately. Source
restoration is implemented here; the worker publication job and ordinary-world
activation remain unfinished.

The existing shared DoorPortalService has no per-door unregister. Freeing
leaves does not remove its retained portal/controller mappings and scheduled
state. Global clear, direct external dictionary edits and a citadel-only door
service are not valid substitutes. Explicit user authorization for a narrow
protected shared-door cleanup API has been requested and is pending; no
protected door, traffic, navigation or NPC code has been edited.

No new NPC baseline run is claimed for this chunk: the new decoder has no
production caller and the preflight only measures unchanged publisher code.
The existing NPC exception remains recorded in the integration control. Full
Main/New Game spawning, continuous approach/gate use, visual preservation,
unload/re-entry, durable-edit save/Continue and runtime performance are still
required. No screenshots or live acceptance booleans are supplied by this chunk.

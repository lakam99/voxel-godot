# Citadel roadbed bearing contract

Branch: `codex/citadel-visuals-clean`; base HEAD
`fcda6762c1923015e27cf622a63e87f6209118c0`. Accumulated work preserved.
Scope: recipe/source contracts, not headed gameplay or final Citadel acceptance.
Independent critic verdict: **PASS for the scoped roadbed recipe milestone**.
This is not approval of the overall Citadel gate.

## Recipe correction

`CastleCompoundBlueprintBuilder.add_elevated_street_roadbed` preserves every
existing part, transform, material, collision flag and ordered
`physicalRequiredSupportPartIds` list. It adds:

- `physicalRequiredSeatPartIds`: a copy of that same ordered support list;
- `physicalAssemblyRole = "walkable_subfloor"`.

The ordinary validator now proves each named foundation's rooted contact and
independently requires all 25 support samples to be rooted. Previously a narrow
foundation could contact the roadbed but miss every sample column, incorrectly
failing the requirement that its ID appear among sample winners. No validator,
route consumer, tolerance, seed exception, furniture or geometry was changed.

## Completed focused evidence

All directories below are under `artifacts/citadel-visual-reset/`.

| Seed | Directory | Checks | Actual roadbeds | Runtime |
| --- | --- | --- | --- | --- |
| 208159 | `roadbed-bearing-known-01` | 100/100 | 8/8 pass | 86.1 s |
| 237207443 | `roadbed-bearing-fresh-01` | 97/97 | 9/9 pass | 113.6 s |

Both runs used `tools/run-godot-scene-watchdog.ps1`, `-Headless`,
`-Scene '--script'`,
`-SceneArguments 'res://scripts/testing/buildings/CitadelRoadbedBearingContract.gd'`,
and `-TimeoutSeconds 180`. `VOXEL_ROADBED_BEARING_SEED` selected the listed seed;
`VOXEL_ROADBED_BEARING_REPORT` selected its fresh absolute `report.json`.
Each directory's `watchdog.json` records the full executable command, ownership,
timing and cleanup evidence; `stdout.txt` contains stage timings.

Both have empty stderr, natural functional/overall exit 0, no forced cleanup,
and authoritative zero remaining owned processes. The runs were sequential,
without intervening code changes.

The 65 shared physical controls exercise the real producer on explicit synthetic
geometry: narrow unsampled bearings, gap filling, protected-volume partitioning,
missing/disabled/displaced/ungrounded bearings, independent uncovered samples,
real mandatory-dependency propagation, repeat and cleared-cache decisions.
Only expected first-inference versus subsequent-recipe `classification`
provenance is excluded from the physical decision comparison.

Each actual seed is built once and receives one full-source physical validation.
All roadbed rows must pass. The uncomposed Castle's other failures remain
reported separately: 36 for the known seed and 52 for the fresh seed. Those are
NOT completed-Citadel failure counts or accepted gameplay failures.

The initial old/new route results are byte-identical and passing. Both mandatory
new-schema repeat and cache-cleared replays execute and match the initial new
result. Old-schema repeat/cache stability is not claimed. The old schema is a
lossless current-source copy with only the two added fields removed, not a
historical executable. For the known seed, that copy also recovers the independent
historical source hash `6caefa897a3cdd38492c899684535c8e1ed02153a8974d4e2c715102ffa307c0`.

Report SHA-256:

- known: `49b2ed0091d11630db02aa86d5ab200e1b114b088ce6fdfb6c12d5872d718f2e`;
- fresh: `083ecb34d4e04f649d1dbd1149f551b6cbe0b24a615014d62c451e1681275618`.

## Rejected evidence and corrected isolation premise

`roadbed-bearing-contract-01` had a test-helper compile error. It was stopped
through its watchdog as soon as the broken execution was identified. Forced
cleanup is a failed run even though zero ownership was confirmed. The runner
now checks preloaded helpers and exits explicitly on compilation failure.

`roadbed-bearing-contract-02` remains red. Its direct-declared-foundation pool
omitted legitimate paving support, and its optional route-replay budget skipped
required evidence. Neither failure was relabeled as passing.

`roadbed-support-context-fresh-01` performed one fresh Castle build and one full
physical validation in 39.3 s. All nine roadbeds passed. Both pool-missing samples
selected rooted, collision-enabled `castle_compound_paving_segment_39` in the
full source. This justified replacing the incomplete isolated acceptance context
with full-source validation, NOT adding new footing geometry or weakening the
physical rule. Its completed diagnostic is distinct from its global physical
result. Both immutable diagnostic hashes are checked by the final contract.

## Remaining full-fixture work

The last complete fresh-seed composer replay is
`fresh-seed-evidence-01/phase-a-diagnostic-01`, before the roadbed correction.
It reports two roadbeds and two unrooted decorative door thresholds. The roadbed
source correction is now verified separately; no post-correction full composer,
Phase B or headed run is claimed here. Threshold bearing, final integration and
visual review remain pending. No new screenshot or live NPC acceptance follows
from these source contracts.

The critic approved the next bounded chunk: generic threshold/door/foundation
ownership metadata, bearing candidate preparation, and focused contracts.
Already-valid thresholds and all door/room/furniture/reservation geometry must
remain unchanged. Candidates must reject unresolved source, door-sweep or
reservation conflicts. Completion-stage integration requires further review;
no new Phase A, Phase B or headed run is authorized by this milestone acceptance.

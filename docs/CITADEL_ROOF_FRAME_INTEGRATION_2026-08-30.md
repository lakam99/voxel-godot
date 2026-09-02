# Shared roof-frame integration

Goal: continue to zero physical-gate failures while preserving the citadel's
visual grammar and furniture. This is one integration step, not goal completion.

**Critic verdict: bounded integration PASS. Current known-seed integrated gate:
253 failures (298 -> 253). Full physical gate REJECT.** The 45 removed failures
are 28 roof halves, 14 eaves, one facade frame and two bunting ropes. This count
does not convert strict rendered-contact failures or incomplete visual coverage
into acceptance.

Branch `codex/citadel-visuals-clean`, HEAD
`fcda6762c1923015e27cf622a63e87f6209118c0`. Existing dirty work is preserved;
no commits, resets, branch rewrites or edits to the original/donor worktrees.
The protected NPC/navigation baseline remains unchanged.

## Frozen comparison authority

Before connecting the composer, `CitadelRoofIntegrationContract.gd` ran in
`--capture-prototype` mode using actual Castle seed 208159, forest,
`river-citadel`, scale 1.25, actual urban composition, then the reviewed frame
builder in original part order. It stores complete unframed source, candidate
source, physically resolved source/checks, actual furniture and reservations.
Furniture planning runs on an independent complete copy.

`artifacts/citadel-visual-reset/roof-prototype-freeze-01/prototype.bin` SHA256:
`7d218cb03d293304bb06f2f4dce492db503ff54a8091b525de93563b42549ec5`.
The capture passed all seven checks, including binary round-trip; 44.153 s,
exit 0, empty stderr and authoritative owned-job zero. Its report records the
pre-cutover source hashes. The dormant collection helper existed at capture,
but `compose` did not call it. Capture refuses to overwrite existing evidence.

Default comparison mode only calls integrated `compose`; it never injects
frames or rewrites the baseline. Equality covers every recorded value and array
order, with dictionary-key insertion order canonicalized. The visual probe
loads the SHA-pinned frozen unframed source, not a newly regenerated control.

## Owning-path change

The composer calls `add_roof_frames` once, after its existing deterministic tree
placement selection, matching the reviewed prototype order. All urban roof
pairs must be complete and uniquely identified. Each uses the existing shared
frame builder. Missing partners, malformed pairs and failed frame construction
return explicit failure; `compose` returns null rather than publish partial work.
All callers honor failure. Diagnostic fixtures no longer add duplicate frames.

The parent castle review fixture now stops before publication/player setup if
blueprint construction fails. A synthetic null-blueprint fixture verifies this
actual caller path. It is failure-injection evidence, not gameplay acceptance.

Existing `add_street_house` focused tests remain unchanged: integration is at
the full composition boundary, not a second low-level house generator.
No physical thresholds, furniture logic, roof skins, material pipeline, NPC
code or façade-post decisions changed. Strict submicrometre contact failures
remain explicit; this integration does not claim exact contact or engineering
safety. The temporary physical-publication bypass remains enabled.

## Evidence ledger

All run folders are under `artifacts/citadel-visual-reset/`, with exact commands
and cleanup in `watchdog.json`, reports in `report.json`, logs in `stdout.log`
and `stderr.log`. Every engine launch uses the existing ownership watchdog,
isolated APPDATA/LOCALAPPDATA, fresh outputs and a run-owned stop-marker path.

| Run | Expected evidence | Actual |
| --- | --- | --- |
| `roof-prototype-freeze-01` | Immutable complete prototype output | PASS, seven checks |
| `roof-composition-contract-01` | Synthetic complete/missing/duplicate collection contracts | All eight PASS; exit 0 |
| `blueprint-failure-contract-01` | Null blueprint aborts before publication/player | Expected exit 2 and construction-failed report; no publisher/player/root; owned zero |
| `roof-integration-parity-01` | Integrated output equals frozen prototype | All 26 checks PASS, no changed IDs, 253 physical failures, 59.993 s, exit 0 |
| `gable-integrated-probe-01` | Integrated payload/contact and original preservation | All preservation/envelope checks PASS; same two strict-contact failures retained; 41.715 s, exit 1 |
| `gable-integrated-contract-01` | Frame positives and structural negatives | All 12 positive / 40 negative checks PASS |
| `standard-roof-integrated-contract-01` | Existing standard roof regression | All 18 PASS |
| `roof-composition-integrated-contract-01` | Collection completeness/duplicate regression | All eight PASS |
| `timber-bearing-integrated-contract-01` | Direct/static renderer profile regression | All 60 cases PASS |
| `late-roof-failure-contract-01` | Later frame failure cannot publish earlier partial output | Five abort checks PASS; 180 earlier frame members exist but no publisher/player/root; expected exit 2 |

The failure-injection run intentionally emits the single construction-failed
error; it does not count as an engine success. No unexpected continuation or
publication occurred. These tests do not prove normal-world or NPC behavior.
All completed integration jobs have authoritative owned-job zero and no cleanup
errors. The 152 furniture records are identical. Reservation arrays also match,
but are empty in this fixture: this is not occupied-reservation coverage.
The late-failure fixture calls the actual Castle builder and urban composer,
introducing one deliberate final-house member-ID collision before composition.
The expected two errors identify that collision and the caller's cancelled
publication. Its `report.json.contract.json` sidecar proves 15 earlier frames
were actually assembled; it is not merely another null-return mock. Exit 2,
authoritative owned-job zero and global Godot zero were verified.

The prior critic-approved images remain in `gable-diagnostic-capture-01`.
Their bounded reuse was accepted after output/payload parity and independent
critic review. No additional headed launch was requested or performed.

## Next shared failures (read-only inventory)

The prototype's remaining failures include 15 market canopy members and 12
terminal-shop attachments. The market producer has no supporting canopy posts;
terminal header/bracket/sign parts lack a complete rooted frame. Existing
images show disjoint timbers. These need actual geometry/joints, not decorative
reclassification or weaker anchor rules. The worker's dimensional calculations
are source evidence only; no next-family patch or acceptance is claimed here.
The separate 163-panel upper-façade support proposal still awaits the user's
decision about visible exterior posts and footings.

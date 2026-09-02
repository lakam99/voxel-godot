# Citadel visuals on the pre-integration production baseline

**Current checkpoint: critic-approved source structural gate at zero for seed
`237207443`, scale `1.25`.** All 146 furnishings are preserved. The final two-phase
source checks pass; visual, publication, gameplay/navigation and performance
acceptance remain separate. See `CITADEL_THRESHOLD_BEARING_2026-09-01.md` for the
final commands, evidence and limits. The user has approved committing this work.

### Earlier integration checkpoint (historical)

**Historical checkpoint: critic-approved normal recipe integration; 170 failures remain.**
Fresh normal generation exactly matches the reviewed 4298-part candidate.
Publication retains the user-authorized
temporary gate bypass; neither rendering nor a completed diagnostic passes the
physical gate. The candidate removes56 failures, introduces no new failed IDs,
and preserves152 furnishings and their protected access reservations.

The critic has accepted combined CPU publication/contact evidence:38 comparison
jobs,284736 pairs and92 inspected contacts. Seven real civic differences from
the old component union are accounted for through fresh geometry/binding evidence;
the historical exact-union result remains RED, not tolerance-waived.

The critic has now also accepted **real Forward+ publication/index readiness**:
4298 building parts,152 furnishings,15457 nodes and224035 instances; five cut
meshes/180 triangles with exact source/furniture/instance bindings. The45.434s
run exited cleanly with no Godot processes left and all626 source files unchanged.
Its956ms maximum frame gap is a hitch observation, not a smoothness pass.

**Do not use headless scene camera results:** the dummy renderer returns identity
MultiMesh transforms and empty buffers. Those earlier visibility results are
invalidated; the inspector now rejects unavailable readback. Pure source/math
and intercepted CPU-publication evidence retain only their documented scope.

The first critic-approved full camera run now completed in51.807s and saved all13
images with exact bindings and clean owned-process zero. Main image inspection
rejects `frame_02_foot_00`: foreground furniture/timber obscure the intended
interface despite the current single-visible-sample camera check passing.
The critic independently rejects that detail and frame02's oblique day view;
other image credits remain useful. A generic observer-coverage repair now passes
45pure-policy and9synthetic wiring checks; it requires distributed per-part
visibility, the lower foot face and adjacent support/finish, using the same
predicate at selection and final capture. No visual acceptance or integration
follows from synthetic tests. The critic-approved renderer02 run subsequently
produced all five readable foot details, including the previously obscured02.
Main inspected all five. The stricter whole-part overview predicate found no
acceptable day pose; nights were therefore skipped. The run correctly exits2,
with exact preservation and clean process zero. Critic independently accepts
all five replacement foot details. A subsequent single assembly-view run found
the joint obscured by unchanged original window/household/masonry details.
Exact source attribution is critic-approved. **Stop pursuing direct exterior
visibility of that concealed seat.** Keep mandatory CPU joint/contact proof;
the remaining image obligation is the preserved facade details plus exposed
new framing. No geometry/furnishing change is justified by the camera no-fit.
The critic re-inspected existing day02/night02/accepted foot02 under that corrected
scope and accepted the image combination with prior CPU preservation/contact
proof. Candidate visual acceptance is bounded; it is not gate-zero, access or
performance acceptance. Generic integration was cleared and has been wired
after ordinary shop composition using the existing furnished-source reservations.
Fresh production-worker verification passes20 checks: exact source,152 furnishings,
reservations, lookup identities, single prepared-plan consumption and identical170
failed IDs from independent validation. Real-composer failure admission passes6
checks and returns no partial blueprint/furniture. Critic accepted this bounded
integration milestone. The physical gate remains false; this is not live access,
whole-caller rollback or performance acceptance. Both runs exited0 with verified
owned-process cleanup and zero remaining Godot processes.
All one-shot grants are consumed; no further headed launch is
currently authorized. No commit/reset/clean occurred.
See `CITADEL_MARKET_RELOCATION_CHECK_2026-08-30.md` for current evidence and limits.

## Product boundary

This branch preserves the current Golden Alley / Solitude-inspired citadel
appearance and the blueprint and furniture-placement rules that generate it.
Citadel residents, their life-playtest fixture, and the later normal-world
citadel/NPC/navigation integration are deliberately absent. This is not a claim
that citadel NPC integration has been completed.

The ordinary production NPC, pathfinding, terrain, streaming and save systems
start from commit `90e89cf433edacbeed26c40916719e7a7d4b55e3`.
No current `scripts/npc_ai`, `NpcSystem.gd`, or `NpcPathing.gd` changes are
ported. The existing player-door system remains, including raising gates.

## Preservation source

Visual source: the working tree of `codex/unified-nav-gate0-baseline` at
`f010830ac75b45982dc2f4657d3cad17c7fef596`, including its current uncommitted
furniture/residence-planning changes. Both that working tree and the original
`codex/citadel-texture-poc` working tree are left untouched.

The retained source includes architecture, courtyard/residence placement,
interiors, furnishings and protected access reservations, masonry/weathering
materials, procedural trees, urban composition and its review scene.

Some source-level clearance/connectivity calculations influence furniture
selection. Those calculations are retained under `scripts/buildings/layout/`
with the donor's dimensions, separate from restored runtime NPC policy.
They analyze immutable building/furniture records; they do not register
navigation, schedule actors or provide a runtime route service.

Building and furnishing publishers no longer publish navigation manifests.
Their visual, collision and player-door construction methods are retained.
Layout-only manifest builders remain dependencies of furniture generation.
The later Citadel route-admission check is diagnostic-only on this branch;
its failures remain visible in publication summaries. The separate physical
integrity admission check is temporarily bypassed at the user's request, with
actual failures retained in reports. It must not be described as a passed gate.

## Verification and reproduction

Use `tools/run-citadel-visual-preservation.ps1` with a fresh absolute
`-OutputDirectory`. It requires no preexisting Godot processes and launches
through a bounded, process-tree-owning watchdog with isolated user-data paths.

- `-Mode Import`: headless project import/parse preparation.
- `-Mode Contract`: seed 208159, scale 1.25 source-artifact capture. Pass
  `-ProjectPath` to run the identical external script against the donor.
  Run both `-Variant urban` and `-Variant compound`; the former alone does
  not exercise courtyard residence furnishings.
- `-Mode Capture`: headed empty-environment citadel appearance captures.
  Obtain the requested independent readiness review before launching.

Contract reports must be compared across projects. A complete report alone
does not prove parity. Compare all five stage records, full snapshot and part
hashes, including furnishing access reservations. This is not live NPC,
normal-world, door-input or performance acceptance.

Visual reports require inspection of the actual images. The review fixture
stages a door through its service for photography; it does not prove real
player-operated door traversal. Do not cite that action as gameplay evidence.

Run evidence and the original 84-file donor hash inventory are under
`artifacts/citadel-visual-reset/` (locally generated, ignored by Git).
Final verification results are recorded below after review.

### Verified so far

- Import/parse: `import-01`, exit 0, empty stderr, no detected errors/warnings,
  empty owned process job and no remaining Godot processes.
- Urban source parity: `donor-contract-02` versus `clean-contract-02`,
  seed 208159 / scale 1.25. All five stage objects match, including 18 hashes
  and all counts/histograms. This covers 4,045 urban shell parts and 152
  urban furnishing parts. Independent critic accepted source parity.
- Earlier `donor-contract-01` and `donor-compound-01` are deliberately
  retained as incomplete captures: cumulative serializer safety ceilings were
  too low. Neither is acceptance evidence. Their production calls returned,
  and process cleanup succeeded; execution timeouts were not increased.
- Source-only checks confirm ordinary NPC/navigation files match the chosen
  baseline, and the copied publishers' mesh/material/collision/door methods
  match the visual donor. These are not runtime gameplay claims.

### Accepted source checkpoint and unresolved visual gate

- Compound source parity: `donor-compound-02` versus `clean-compound-02`,
  seed 208159 / scale 1.25. All five stage objects match exactly: 4,951
  building parts, 386 furnishings, including 10 beds, 23 other interior
  furniture pieces, and 51 protected access reservations. Independent critic
  accepted this and the urban source-parity result.
- `donor-capture-01` stopped at the later route-admission gate (overlapping
  roadbed collision records and an unresolved declared handoff). The donor
  was not edited. Its failure remains in stderr and watchdog evidence.
- After retiring only that route-admission prerequisite, `clean-capture-01`
  stopped at the independent physical-integrity gate: 208 structural
  support-chain failures and 151 attachment-anchor failures, 359 total.
  Details: `artifacts/citadel-visual-reset/physical-publication-blocker.json`.
- Both headed failures were stopped through their run-local stop markers.
  Both watchdog reports prove zero remaining owned processes, with no
  unresolved cleanup or cleanup errors. Final global Godot process count: 0.
- **No screenshots were obtained.** There is no rendered, player-collision,
  traversal, normal-world or NPC acceptance claim. The aggregate physical
  errors do not distinguish bad declarations from restrictive inference or
  unsupported geometry; live colliders had not been published.
- The critic accepted a source-preservation checkpoint, not visual acceptance.
  Further work needs a product decision: reconcile physical support/anchor
  contracts without changing the approved appearance, or explicitly retire
  that later admission policy. Do not bypass it silently or mark failures PASS.

### Temporary physical-gate bypass (user authorized, 2026-08-30)

After the bounded repair, the user explicitly requested disabling the gate and
proceeding to visual verification. `BuildingPartPublisher.gd` now sets
`PHYSICAL_INTEGRITY_REQUIRED_FOR_PUBLICATION = false`. The validator still runs
and reports its actual failures; the publication summary explicitly records
`physicalIntegrityRequiredForPublication: false`. Re-enable the constant to
restore blocking. This does not certify physical integrity or NPC gameplay.

#### Visual verification after bypass

Independent critic approved one headed visual-only run after headless import
passed. No capture retry or geometry/furniture changes were made.

Command (from this clean visuals worktree):

```powershell
./tools/run-citadel-visual-preservation.ps1 -Mode Capture -OutputDirectory "$PWD/artifacts/citadel-visual-reset/physical-bypass-capture-01"
```

Seed 208159, scale 1.25; Godot 4.6.1 Forward+, 1280x720 captures. The run
completed in about 53 seconds, published all 4,045 building parts and 152
furnishing parts, registered 20 doors, hid loading, and saved nine of ten
requested images. This is an empty-environment fixture, not normal gameplay.

Evidence: `artifacts/citadel-visual-reset/physical-bypass-capture-01/report.json`,
`stdout.log`, `stderr.log`, `watchdog.json`, and `screenshots/*.png`. The fixture
does not emit a separate progress file; stdout and final readiness fields are
the available evidence. Stderr is empty. Exit 1 correctly retains overall
failure. The watchdog proves zero owned processes; global Godot count was zero.

The publication report explicitly retains `physicalIntegrity.passed=false`,
348 violations, and `physicalIntegrityRequiredForPublication=false`.

Main agent inspected all nine saved images:

- `outer_approach`, `gate_threshold`: gatehouse masonry and open passage render.
- `inner_lane`: dense painted/timber facades, lanterns, paving and pots render.
- `market_ground`, `market_release`: market canopy, table goods, barrels and
  crates render; some bracket/awning members look disjoint. No historical
  image-parity or structural-integrity conclusion is justified.
- `civic_overview`, `civic_commons`: roofscape, buildings and paved courts render.
- `tree_contact_paving`: tree trunk/canopy and paving render.
- `perimeter_lane`: fully obstructed by a plain surface, **not usable visual
  evidence**, notwithstanding its synthetic camera check returning true.

Remaining verification failures (not silently bypassed):

1. `green_market_square` was not captured: all 64 candidate observer positions
   failed the fixture's support check.
2. Window/interior audit rejects `urban_row_03_left_window_02_-1`: one of 76
   windows lacks a recognized interior.
3. Actual perimeter-lane image invalidates that camera's green result.

Result: **rendering unblocked; visual verification partial, not full PASS**.
Independent critic agrees: partial visual evidence accepted; full verification
rejected for the missing/obstructed views, window-interior failure, and unresolved
disjoint-looking awning/bracket appearance. No further launch was made.
No night capture, historical pixel comparison, interior-furniture walkthrough,
player-operated door traversal, NPC, normal-world or runtime-performance
acceptance is claimed. Existing full source parity for urban/compound furniture
remains the prior evidence; these exterior images do not replace it.

### Shared upper-trim follow-up

The subsequent user-approved representative-house repair corrected the shared
mounting plane for upper studs and floor beams only: 56 noncolliding trim parts
across 16 houses shifted inward by 0.14. Exact own-facade contact rose from 0 to
56; rooted trim count rose from 30 to 50; violations fell from 348 to 328, with
no added failures. Massing, collision, rooms and furniture are unchanged.
One critic-approved headed comparison completed with the same known visual
coverage/window failures and clean process exit. See
`CITADEL_UPPER_TRIM_REPAIR_2026-08-30.md` for scope and evidence. The physical
publication gate remains bypassed, not satisfied.

### Further mounting repair toward the zero-failure goal

Corner frames and door lintels now share the actual upper-wall mounting plane.
The known-seed physical count decreased from 328 to 317 with no new violations;
48 noncolliding pieces were reseated. Furniture and all unrelated source fields
match the source-level control. A critic-authorized headed comparison completed
publication with no leftover Godot processes; existing full visual failures
remain. Fresh seed 783601 and historical seed 208158 both fail castle layout
before reaching the modified composer, so neither supplies trim acceptance.
See `CITADEL_FACADE_MOUNT_REPAIR_2026-08-30.md` for evidence and limitations,
and `CITADEL_REMAINING_PHYSICAL_GATE_2026-08-30.md` for the remaining families.
The zero-failure goal remains active; the publication bypass is not acceptance.

The subsequent street-brace mounting correction reduces the known-seed count
from 317 to 315, with no additions. See `CITADEL_STREET_BRACE_REPAIR_2026-08-30.md`
for source checks and visual-review status. The 163-panel upper-façade family
needs a real structural repair: the representative low interior beam leaves
only 1.224 m of headroom. A visible exterior-post candidate is pending explicit
user agreement; no posts or collision changes were implemented. The dimensioned
study is `CITADEL_UPPER_FACADE_BEARING_STUDY_2026-08-30.md`.

The stored-firewood intent correction subsequently reduces 315 to 298 by
removing 17 erroneous facade-anchor requirements, not by repairing support.
All 112 logs retain identical geometry/rendering inputs; nonfuel structural
checks, furniture and access reservations remain identical. The critic accepted
this bounded source/service correction without another headed run. Prop
grounding remains unresolved. See `CITADEL_STORED_FIREWOOD_INTENT_2026-08-30.md`.
The full physical gate still fails and the zero-failure goal remains active.

The shared roof-frame repair is now integrated and critic-accepted within its
bounded scope: the current known-seed physical count is **253**, down from 298.
Exact source, physical-check and furniture parity against an immutable reviewed
prototype passed, as did payload-preservation and structural regressions. A
late-frame failure test proves partial output cannot publish. Exact rendered
contact still has submicrometre separation failures; the full gate remains
rejected and the temporary bypass remains enabled. See
`CITADEL_ROOF_FRAME_INTEGRATION_2026-08-30.md` for the current ledger and
`CITADEL_GABLE_PURLIN_PROTOTYPE_2026-08-30.md` for historical discovery. Production
NPC/navigation files remain unchanged from the protected baseline. The next
shared groups are market-canopy and terminal-shop attachments; the larger
upper-façade exterior-post proposal still awaits user agreement.

### Stop control and prior timebox (historical)

### Current recipe gate work (supersedes earlier permission notes)

The user explicitly authorized all necessary citadel-recipe edits to pass the
physical gate while preserving the visual direction and furniture-placement
logic. Earlier notes saying exterior facade supports await permission are
historical, not an active blocker. NPC/navigation remain outside this scope.

The market/terminal prototype received scoped critic visual/local-access approval
after headed05: all nine review views and six-front continuous walking evidence
pass. Shared recipe extraction is now wired into `CitadelUrbanPocComposer`.
`market-production-integration-01` proves complete source/order, resolved source,
physical results, furniture and reservations exactly match the immutable reviewed
prototype: **226 historical failures, 152 exact furnishing records**. Late failure
and double-application controls pass. Loading-worker02 and actual-publication02
checks pass their scoped equivalence requirements; critic acceptance supersedes
the two-gap integration rejection after furniture reservations and worker-owned
furnishing handoff were fixed. Fresh cleared-cache validation exposed **233**
failures, including seven elevated processional stairs incorrectly authored as
ground roots. The stair recipe now declares its actual foundation seats without
changing tread geometry. Fresh, repeated and cleared-cache validation agree on
**226 current integrated failures**; the critic accepted that scoped repair.
The same two pre-existing generated-route coverage failures remain explicitly
red, with before/after comparison proving only the seven support-owner IDs
changed. See `CITADEL_PROCESSIONAL_SUPPORT_2026-08-31.md`; this is not navigation
or live movement acceptance.
This is not a zero gate or whole-game acceptance claim; the goal remains active.

The reviewed pre-extraction artifact is
`artifacts/citadel-visual-reset/market-reviewed-freeze-01/reviewed.bin`, SHA256
`e43b972eface80bbcbc015ef55ac0c21a5cb99083dcfa9aabbb5a407f9832038`.
It must never be regenerated or overwritten to manufacture parity. The facade
worker is extending narrow-pier/cap construction to bear on actual rooted paving;
the first full-source attempt produced no reduction and remains rejected. The
narrow-paving candidate03 subsequently passed source checks at **226 to 176**
(41 facade failures and nine dependent failures resolved) with twelve added
parts and exact furniture preservation. Subsequent CPU publication rejected a
4.1mm door-brace intersection. Shared actual-door reservations repair that unsafe
placement by rejecting the fourth pier: candidate06 and its mandatory rollback
companion pass **226 to 180**. Publication02 and scoped critic review confirm
exact original/furnishing payloads and no foreign contacts; footing visual
separations/embeddings still need closeups. This is the current accepted source
candidate, not integration or visual approval. Broad inset-end sill controls pass,
but whole candidate07 exhausts its bounded search and rolls back without export.
Reusing spatial analysis is the next bounded repair. Eleven
chimney bearings pass bounded source checks (233 to 222 on that separate candidate,
not an integrated count); complete CPU publication06 now passes scoped critic
parity/contact-readiness review, but headed appearance evidence remains required.
Neither facade nor chimney candidates are integrated or visually accepted yet.
Chimney headed01 failed a fixture prediction check, reproduced and repaired with
strict full source equality. Headed02 passes preservation but cannot find any of
its 24 camera views. After critic-reviewed surface-probe repairs, headed03
produces 16/24 images, all individually inspected by main. Several ordinary
views are obstructed; missing brick closeups and later ray-budget exhaustion
prevent acceptance. All three grants are consumed; no automatic retry.
Search-reuse candidate08 and rollback03 now pass with exactly the candidate06
source/output and unchanged count180; critic permits reuse of publication02.
The next actual broad-frame obstruction is an80mm noncolliding paving finish
across the foot seats. Recipe-owned apertures have conditional architecture
approval only; no paving geometry has been changed. All owned processes are
closed. Exact evidence and limitations
are in `CITADEL_MARKET_RELOCATION_CHECK_2026-08-30.md`.

### Earlier timebox and stop-control history

The user subsequently authorized a 15-minute attempt to satisfy the physical
gate without weakening it. The uncommitted contact-detection repair reduced
359 violations to 348; geometry/collision-field and furnishing-source digests
remained identical. The full gate is still rejected and no new headed run was
launched. See `CITADEL_PHYSICAL_GATE_TIMEBOX_2026-08-30.md` for exact scope,
commands, evidence, remaining assembly-contract gaps, and limitations.

The wrapper supplies a fresh `stop-request.txt` path inside each run directory.
Creating that marker requests termination of that watchdog's own Job Object;
it never selects processes by executable name or guessed PID ownership.
Checks occur during the bounded wait, after root exit, and after cleanup grace.
Normal completion, requested stop of a waiting root, and stop-during-exit were
tested in `stop-normal-01`, `stop-wait-01`, and `stop-exit-race-01`.
Both cancellation tests observed the marker before root exit; post-exit-check
coverage is static review only. Intentional cancellation returns nonzero.

Fresh import also changed line endings in 213 existing asset/icon import
descriptors. Those line-ending-only changes were restored; the five newly
generated script UID files were retained. No asset content was replaced.

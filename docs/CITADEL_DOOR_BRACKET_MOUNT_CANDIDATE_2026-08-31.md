# Door hood brackets: recipe placement candidate

Integrated checkpoint remains170 failures. The new unwired placement candidate
measures159, not gate zero and not visual or production acceptance.

## Owning defect

The street-house producer positions the decorative diagonal brackets from a
presentation offset, outside its actual facade and within the opening's lateral
span. Historical `physical-timebox-contact-fix-03/report.json` has empty anchor
lists for all16 failing brackets. The other16 attach incidentally to castle
terrace/keep/buttress geometry. The fresh integrated report retains those16 failed
IDs, but does not itself include per-bracket anchor lists.

The existing noncolliding door lintel is an attachment, not a structural anchor.
Changing the validator or promoting that lintel without a load path is not a fix.

## Unwired recipe experiment

`DoorHoodBracketMountRecipe.prepare` finds the actual solid door-side facade pier
at the bracket's rear-end height. It places the unchanged angled member against
that wall, embeds one section width and places its lateral edge at the actual
opening edge. Shape, size, rotation, material, collision and all other records
remain unchanged. It rejects missing/ambiguous piers and missing exact nominal
wall/hood intersections. It only returns a candidate record; it does not mutate
the caller or assert rootedness.

Initial scope is the existing axis-aligned street-house producer, mirrored in X.
It is not yet a generic rotated-frontage API. No seed or named-house branches.

## Fresh source evidence

Command: `artifacts/citadel-visual-reset/door-bracket-candidate-01/command.ps1`.
Seed208159, scale1.25. Report, stdout, stderr and watchdog summary are in the same
directory. Input is the frozen whole09 source already proven byte-identical to
normal generation by `facade-integration-01`; this is a source-only experiment,
not a new normal-generator run or live gameplay evidence.

- 19.626s;32/32 plans prepared and32 positions changed.
- Six checks pass, including exact unrelated-record preservation and unchanged
 frozen input. Independent validation170->159,11 removed failed IDs, none added.
- The five remaining bracket failures have actual own-facade anchors but fail
 rooted-support validation. No success override conceals those dependencies.
- Functional exit0, empty stderr, cleanupPassed and authoritativeZeroProven true;
 no remaining Godot process. No headed run or commit.

## Required before integration

Independent critic review; invalid-input, mirrored and missing/moved/unrooted
anchor controls; finite contact in the actual published timber/hood geometry;
door and furnishing clearance/preservation; scoped visual inspection under a
fresh critic launch grant; normal generation verification after any integration.
Nominal zero-margin intersection is not finite published joint proof. Neither
the candidateReady field nor the reduced count passes these later obligations.

## Critic and guarded replay

Critic accepted candidate01 only as a source experiment. It required finite-input
and producer-membership guards, deterministic nearest-pier tie handling, and
verification that improvements use their own rooted facade rather than incidental
castle contacts. The helper now rejects malformed/foreign inputs and evaluates
ties at the final minimum, not prematurely before a later closer pier.

`door-bracket-candidate-02/command.ps1` replayed the guarded recipe in22.024s:
170->159, the same11 removals and no additions; all6 checks pass, clean0/zero.
Additional root observations matter: six improved brackets have a rooted selected
lower pier, while five touch another rooted panel of their own facade but their
selected lower pier is unrooted. This does not prove those five lower mounting
joints. All11 have own-facade rooted anchors; none needs an unrelated castle wall
to explain the observed source-validator improvement. Production remains170.

A separate delegated guard contract covers32 source plans, panel-order permutations,
malformed/missing/foreign inputs, nearest/farther ties and input immutability.
`door-bracket-guards-01/command.ps1` passes100 checks across159 preparation calls,
including all32 source plans. The main agent read the delegated file before
execution. Functional exit0, empty stderr, verified cleanup/zero; no engine left.
Critic accepts the100 controls and source experiment only. The guard verifies
supplied records and producer naming/semantics, not authoritative membership of a
same-ID altered copy. No mounting, visual or integration grant.

## Published contact checks and next owning repair

The focused CPU publication runner uses the existing publisher/collector, never
headless MultiMesh readback. A delegated pure contact helper has35 independent
synthetic plane-proof controls passing in `door-bracket-witness-controls-02`.
Controls01 is preserved as a parsing failure; two explicit test variable types
fixed it. Both exits cleaned up their owned processes.

`door-bracket-published-01/command.ps1` completed in10.254s:32 selected-pier
contacts,21 rooted rear contacts, zero sampled hood-front witnesses. The640-file
source freeze was unchanged at
`f594bf1ecf743f461d1bf02ac98f75770ac5f73ceccba3f65102e62dcfdac3f9`.
Absence of a sampled witness was not proof of geometric separation.

The recipe now derives bracket height from the real hood underside, embedding
its front centre by one-quarter of the thinner joint member. It preserves angle,
size, collision and material. It validates the common facade plane, derives final
X/Y first, and only then chooses the actual pier at the final rear-end height.
Cross-sloped hoods and inconsistent facade planes reject; no snapping/averaging.
`door-bracket-guards-03` passes104 checks/163 calls, including an old-height decoy
and final-height pier selection. Guards02 is the prior100-check passing run.

`door-bracket-published-02` completed in11.429s and03 in11.165s. Both measure32
finite hood-front witnesses and21 rooted rear witnesses. All32 selected piers
have finite published contact, but11 are not rooted at the rear mount. All runs
retain source failure count159. The witness criterion is a two-millimetre-radius
ball inside actual represented box primitives, not an engineering adequacy claim.

Published door contacts bind uniquely to the unchanged production descriptor's
frameLeft/frameRight/frameTop, not leaf boards, leaf brace or handle. This is
closed-pose attribution only; it does not automatically permit fixed-frame
intersection or prove the swept leaf, room approach, furniture or neighbour
clearance.

Pub01/02 reported31/32 exact combined profile/appearance comparisons. The sole
difference was a material digest, not shape: the diagnostic published only old
brackets but candidate context parts too. The production material cache rounds
variation keys to three decimals, so those request sequences were incomparable.
Pub03 mirrors all inspected context requests and cache initialization;32/32
profiles/materials/custom data/shadow fields match. Historical mismatches remain
recorded. No material/cache policy was changed.

All successful runs exited0 with empty stderr and verified cleanup/authoritative
zero. No headed test was launched. Commands, reports, stdout/stderr and watchdog
summaries are in the named `artifacts/citadel-visual-reset` directories.

**Do not integrate the32 moves on the159 source count alone.** One originally
passing bracket (`urban_row_03_right_door_bracket_66`) has no own rooted facade
anchor after the candidate move. Five apparent source improvements also rely on
upper-panel contact, not a rooted lower mounting pier. Next repair belongs to
the shared upstream facade support, not further camera or sampling tuning.
Integrated checkpoint remains170; bracket candidate stays unwired. Critic accepts
the bounded measurement milestone:104 guards,35 witness controls and pub03's
32hood/21rooted-rear/32profile results with clean process ownership. Mounting,
visuals and integration remain rejected/unproved. No gate-zero claim.

## Next shared facade prototype (not implemented)

Critic considers a geometry-derived opening-head timber band plausible: infer
actual voids and full solid bands from the panel tiling, replace a thin masonry
strip atomically, and connect the new header to independently rooted gables with
finite housed joints. Start with one representative house and a failed-end-support
negative. Do not assume85 panels will pass. Existing gable fronts stop inward of
the facade, so any necessary inward header extension must explicitly preserve
opening volumes, door sweeps, furniture, access reservations and headroom.
No circular support through repaired panels, gaps/doubled published solids,
tolerance changes or forced common height. A timber band changes appearance even
if the exterior envelope is unchanged; later visual review is mandatory.
No engine/visual/integration permission follows from this design review.

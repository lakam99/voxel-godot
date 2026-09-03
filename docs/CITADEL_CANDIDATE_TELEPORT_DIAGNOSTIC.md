# Citadel candidate teleport diagnostic

This headed diagnostic avoids walking kilometres from the tutorial spawn. It
does **not** establish continuous traversal, NPC routing, or complete gameplay
acceptance. The user explicitly authorized teleporting to inspect the candidate.

## Run

After read-only critic approval of the current runner and its owned-process
wrapper, use a fresh output directory:

```powershell
.\tools\run-citadel-candidate-teleport-playtest.ps1 `
  -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-01 `
  -Seed atlas-30895044 -TimeoutSeconds 600
```

The seed repeats the last ordinary Main-menu/New-Game diagnostic. The candidate
is selected by the production deterministic field; selection does not imply
that terrain admission will accept it. The bounded search reports its extent.

## Evidence boundary

- Instantiate the real Main scene and complete its New Game startup. A narrowly
  scoped fixture subclass overrides random seed selection only; this is not
  evidence of clicking through the real main menu. The earlier ordinary menu
  diagnostic is separate evidence.
- Place the player outside the candidate's conservative discovery bounds. Allow
  the ordinary observer and terrain admission to prepare the actual source.
- After admission, place the player outside its actual manifest reservation.
  This second setup placement avoids walking from the much larger conservative
  discovery boundary. Neither placement injects a source, publishes a scene, or
  disables the construction guard.
- Temporarily hold only player physics during setup. Require current native
  terrain collision and fresh capsule clearance before resuming it. No terrain,
  publication, NPC, or main-loop processing is paused to manufacture readiness.
- Observe ordinary scene publication, current source identity, runtime owners,
  registered doors/trees, and sampled physical geometry. Capture the ordinary
  viewport; inspect the images before claiming a visible citadel.
- Use isolated save data and an owned Windows process job. Engine errors request
  immediate owned cleanup. The outer deadline remains at most 600 seconds,
  including time reserved for ordinary graceful shutdown. No process-name-wide
  termination is allowed.

The output includes launch/source hashes, progress, report, viewport captures,
engine logs, and watchdog/cleanup verification. Missing evidence, rejected
sites, timeouts, errors, source changes, or unresolved cleanup are failures,
not successful visual verification. Fixture work and captures add overhead;
these timings are diagnostic, not performance acceptance.

## Results

The independent critic approved one 600-second headed run on 2026-09-03 after
the final-source check-only run (`candidate-teleport-parse-04`) exited naturally
with code 0, empty stderr and authoritative owned-process zero. The earlier
parse directories are retained; they are not headed runs.

Approved source SHA256:

- Runner: `1d5e07b1e555e32a9c0dee317969ce8e0bdb5c525eefe844f6038570c59b0555`
- Wrapper: `a68f3b9d4e034d1c3df71cc3839ef68603df7ee48374852af6b59939e1f94fad`

### First headed run: failed source, owned shutdown verified

Command: the command above, unchanged. Branch `codex/citadel-visuals-clean`,
HEAD `52b0cbc`; the two new test files were uncommitted but frozen at the hashes
above. The wrapper verified no measured source changed during execution.

Evidence directory: `artifacts/citadel-runtime-integration/candidate-teleport-01/`.
Read `report.json`, `progress.json`, `stderr.log`, `stdout.log`, `launch.json`,
`watchdog.json`, `verification.json`, and the three PNG captures together.

- Ordinary New Game reached startup readiness at about 37 seconds.
- The field selected region `(0,-1)`, center cell `(1216,-679)`, recipe seed
  `1747969299`, site `citadel-site-v1:14:atlas-30895044:0,-1`.
- Exactly one setup teleport occurred at 37.199 seconds, from
  `(360.45,20.25,-13.5)` to `(1117.8,18.006,-398.25)`, outside the declared
  discovery bounds. No accepted-reservation teleport or physics resume occurred.
- The ordinary source worker failed structural completion. The report records
  `citadel_structural_completion_failed`; the engine trace narrows this to
  `facade_completion_failed` in `CitadelUrbanPocComposer._compose`, called by
  ordinary recipe/site preparation. The report was written at 111.638 seconds.
- The error watcher requested immediate owned-job shutdown. The watchdog proves
  **zero owned processes**, with forced cleanup and no timeout. Its
  `cleanupPassed=false`/nonzero overall result correctly rejects forced shutdown
  as a clean natural-exit pass; it does not mean a process was left alive.
- `preteleport.png`, `pending.png`, and `failed.png` were inspected. They show
  the ordinary starter house followed by a dark nighttime exterior. There is no
  visible citadel and no visual acceptance claim. No clock or lighting override
  was used.

This run proves that the first teleport triggers ordinary source discovery and
that an observed engine failure closes the owned test. It does **not** prove
the second placement, accepted terrain reservation, ready scene, door/tree
bindings, or visible citadel. Those branches were not reached. Do not bypass
the recipe failure, substitute a prebuilt source, or repeat a headed run before
the owning source failure is understood and the critic approves readiness.

Evidence limitation found during this run: repetitive startup messages filled
the bounded timeline before later phase transitions. The report and latest
progress preserve the terminal failure, but this timeline is not a complete
phase history. A subsequent harness-only change deduplicates startup messages
and records stage transitions separately; it cannot retroactively repair this
run's evidence.

The final timeline-only revision passed `candidate-teleport-parse-05` with
natural exit 0, empty stderr and owned zero. Its runner SHA256 is
`320b1a148832d3bfd8230b514e69508f339e96a5fab7e11d53046298bf3a1cfa`;
the wrapper hash is unchanged. This revision has not had a headed rerun.

Next diagnostic: replay the failing production recipe headlessly with its
production-derived center biome, exact site key, scale `1.25` and recipe seed
`1747969299`, retaining the nested `structuralCompletionFailure.detail`.
This isolates facade completion without walking, changing navigation, or
spending another headed run on a known source failure.

### Second headed run: complete recipe, legitimate ocean exclusion

After the complete public recipe and independent physical proof passed
(`candidate-recipe-05`), the critic approved one retry on unchanged fixture
hashes. Branch `codex/citadel-visuals-clean`, clean HEAD `8b2c877`.

```powershell
.\tools\run-citadel-candidate-teleport-playtest.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-02 -Seed atlas-30895044 -TimeoutSeconds 600
```

Ordinary startup completed and one exterior setup placement occurred at about
37 seconds. Source composition progressed past both repaired failures. The
subsequent full-envelope production survey returned `absent` with reason
`excluded_biome:ocean` at 295.114 seconds. The candidate center was plains, but
that did not certify the complete geometry/apron footprint. No site was admitted,
no second placement occurred, and no scene was constructed.

The test stopped on that result: natural exit 1, no timeout, no forced cleanup,
empty engine-error/warning inventory, clean owned cleanup and zero remaining
Godot processes. All 814 launch hashes remained unchanged. Read `report.json`,
`progress.json`, `verification.json`, engine logs, watchdog and capture records
under the run directory. The three inspected images show the starter-house
view and dark rainy exterior, not a citadel. The critic accepted this as a
legitimate exclusion checkpoint, explicitly not spawning success.

### Explicit diagnostic candidate selection

An optional `-CandidateRegion 'x,z'` selects one of the same bounded production
field candidates instead of the nearest. Canonical coordinates are validated;
missing/out-of-ring candidates stop without fallback. Both requested region
and selection mode are recorded. There is still one selected candidate, at most
two exterior setup placements, no source injection and no automatic headed
candidate-search loop. Ocean, town and full-site admission rules are unchanged.

`candidate-selection-02` passes 23 pure fixture-selection checks with natural
exit 0, clean logs and owned zero. The preceding `candidate-selection-01` records
a fixed test-report parse error; its owned process also reached zero. These
checks do not instantiate Main or establish site eligibility.

A separate sparse production-biome/town scout may inform the region choice.
Its sampled conservative envelope is a heuristic, not a complete survey or a
promise that the actual source, furniture, terrain or collision will pass.

`candidate-scout-01` inspected 81 lattice points for each of eight production
candidates in 25 regions, with exact forward/reverse query-order replay in fresh
contexts. It missed the known ocean exclusion at `(0,-1)`, empirically confirming
that sparse screening cannot prove eligibility. This report predates the optional
dense-square code and is not evidence for that later code.

`candidate-scout-02` repeats those controls and uses the ordinary public
`CitadelSiteSurvey` to scan every column of a caller-defined 257x257 square at
region `(-1,0)`, center `(-796,659)`, recipe seed `541151883`. All 66,049 columns
were surveyed: 65,968 forest and 81 beach, no town/excluded-biome refusal. Dense
elapsed7.786606s; maximum whole advance3.381ms. It uses existing survey budgets
and remains below the262,144-column limit. Both runs have clean logs, natural
exit0 and owned zero. Neither screen binds the actual recipe footprint, tests
other structure conflicts or certifies rendering, collision or performance.

Reproduce with a fresh output directory and restore the process-scoped variable:

```powershell
$previousDenseRegion = $env:CITADEL_CANDIDATE_SCOUT_DENSE_REGION
try {
  $env:CITADEL_CANDIDATE_SCOUT_DENSE_REGION = '-1,0'
  ./tools/run-building-contract.ps1 -Contract CitadelCandidateScoutDiagnostic.gd -OutputDirectory artifacts/citadel-runtime-integration/candidate-scout-repeat -ReportEnvironment CITADEL_CANDIDATE_SCOUT_OUTPUT -TimeoutSeconds 45
} finally {
  $env:CITADEL_CANDIDATE_SCOUT_DENSE_REGION = $previousDenseRegion
}
```

The next selected diagnostic region is `(-1,0)`, not a production placement
override. Its recipe and full Site preparation still need ordinary execution.
No new headed launch follows solely from this source-screen result.

After reviewing the final six-file harness/scout/evidence scope, the critic
approved its focused commit and one 600-second `candidate-teleport-03` discovery
run with `-CandidateRegion '-1,0'`. Production code is unchanged from `8b2c877`.
Spawn/NPC acceptance and performance budgets are not waived.

### Third headed run: fresh candidate facade failure, immediate owned stop

Clean HEAD `20dffac`, same world seed, explicit region `(-1,0)` and recipe seed
`541151883`; critic-approved command:

```powershell
.\tools\run-citadel-candidate-teleport-playtest.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-03 -Seed atlas-30895044 -CandidateRegion '-1,0' -TimeoutSeconds 600
```

Ordinary New Game completed, and one counted exterior setup teleport reached
the selected candidate. The last progress snapshot at225.547s records ordinary
source discovery and worker stage `opening_head_house_completed:urban_civic_house_east`,
713,713 checkpoints and188.594s worker elapsed. The subsequent engine error was
`Citadel structural completion failed: facade_completion_failed`, with the
ordinary Composer -> Recipe -> Site -> source-queue call stack.

The error watcher immediately stopped its owned Windows job. Watchdog126,
forced cleanup true, timeout false, authoritative owned-zero true. There are no
remaining Godot processes. Source hashes stayed unchanged. `cleanupPassed=false`
correctly means forced termination is not a clean natural-exit pass, not that a
process remains alive.

`report.json` and a terminal failure capture were not written before that stop.
This absence is an evidence limitation, not a success. Retained evidence is
`launch.json`, `progress.json`, stdout/stderr, stop request, watchdog and
`verification.json`. The two inspected images (`preteleport.png`, `pending.png`)
show the starter-house view and dark staging exterior; no citadel is visible.
No source admission, second teleport, scene publication or gameplay pass occurred.

This candidate's underlying facade defect is not yet classified. The shared
outer failure name does not establish that it is the earlier row-overlap defect.
Next work is an exact headless public-recipe replay for this seed/region, retaining
the nested structural failure before any further headed request. Do not weaken
site/structural gates, inject a previously accepted source or raise deadlines.

The independent critic approved this two-document failure-evidence checkpoint,
including the missing terminal artifacts and unclassified underlying cause.
No gameplay acceptance or further headed retry approval was granted.

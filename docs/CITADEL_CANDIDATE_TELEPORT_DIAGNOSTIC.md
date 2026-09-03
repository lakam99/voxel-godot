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

# Citadel whole-path review — 2026-09-13

Status: working-tree changes, not accepted or merged. The verification sequence
stopped on a new synthetic scheduling-test failure, per the user's stop instruction.
No headed game was launched in this pass. Loading-time non-regression is unproven.

Worktree: voxel-biome-world-godot-citadel-visuals.
Branch: codex/world-streaming-architecture. Preserve the existing dirty tree.

## Evidence and causal boundaries

The previous headed diagnostic used seed atlas-3376622889, candidate region -2,-2:
artifacts/citadel-runtime-integration/candidate-teleport-gate-axis-11/report.json.
It failed approach_time_limit at 26.46m from visual bounds after moving about111m.
It exited naturally with no engine errors, clean owned-process cleanup and no
watchdog timeout. It was a teleport/setup diagnostic, not ordinary menu acceptance.

Late motion samples name two distinct states:

- structure_dependency_revision_changed rejects the previously admitted broad
  request before checking the current local physical receipts.
- regional_navigation_pending names navigation_accepted_source_absent for
  tile -209,-180 while terrain and structure receipts are ready.

Final navigation service observation already contains an accepted source for that
tile, serial305, matching descriptor/binding and installation receipt390. The
regional consumer still reports its old absent state. The report lacks an exact
installation timestamp, so it does not establish the duration of that lag.

The regional adapter rotates over78 tiles. Expensive discovery/proof work can
consume its cooperative4ms slice before a completed tile gets acknowledged.
Priority sorting alone does not prioritize completion when the numeric cursor
continues across the whole list. Reordering demand also changes that list.

There is a separate performance problem: the final Main process sample window
has median142ms, p95274ms and maximum311ms. These are Main process measurements,
not total rendering/physics frame times. Capture and repeated physical proofs
remain expensive; eventual acknowledgement would not by itself meet performance
acceptance.

## Changes in this pass

1. Restored the previous complete StructureSystem dependency invalidation.
   The immediately preceding untested regional fingerprint covered only the raw
   query, although town/standalone dependencies can extend beyond it. It also
   rebuilt candidates and scanned queues/portals during polling, and retained
   global revision fields in bindings while omitting them from cache identity.
   Only those latest hunks were removed; prior construction-guard and per-domain
   closure work remains.
2. Restored job dependency invalidation on phase, door registration and physical
   group receipts. The cached description still contains those live facts.
   An immutable-only revision would be premature without separating their owners.
3. WorldStreamingCoordinator now proves fresh query requirements against active
   retained source bindings/groups and current domain/provider handles. Broad
   scheduling revision changes or a pending refresh do not alone revoke a locally
   current proof. Replacement generations, newly required groups/tiles, historical
   ownership, failed live receipts and mutation during proof remain pending.
   Request sequence is checked at acceptance exit, including in-place replacement.
4. RegionalNavigationPublication gives accepted-source completion a separate
   bounded rotating visit before unrelated discovery. Initial source-ID collection
   can borrow the service's immutable installed source before live physical proof.
   Borrowing never grants readiness; final validation/receipt checks remain.
   This change has one unresolved synthetic fairness assertion below.
5. Removed the recent speculative startup relocation search. It moved the real
   player through13 candidates during a shared New Game/Continue readiness method,
   potentially replacing a valid saved position and adding loading work.
   Existing spawn/restore ownership and collision checks remain. The user's
   stationary rock observation does not explain the recorded regional hold.
6. Diagnostic navigation samples retain the first128 and latest128 entries, so
   long runs preserve startup context and the decisive terminal interval.
   Bounded regional completion diagnostics separate collection time, remaining
   proof/receipt cost, and first-observed-installation-to-acknowledgement latency.
   That observation timestamp is not the engine's installation timestamp.

## Executed coverage

Commands run from the worktree above; artifact paths are relative to it.

| Command | Evidence | Result and scope |
| --- | --- | --- |
| node tools/run-world-streaming-consumer-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/world-streaming-consumer-whole-path-02 | same directory/report.json |85 checks pass; synthetic retained ownership, revision churn, live receipt rejection, replacement/cancellation, capacity and history |
| node tools/run-building-scene-publication-job-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/scene-job-packet-order-whole-path-01 | same directory/report.json |537 checks pass; synthetic scene orchestration including resumed packet receipt invalidation |
| node tools/run-project-compile-smoke.mjs --report-path artifacts/citadel-runtime-integration/whole-path-compile-01.json --timeout-seconds 90 | named JSON |Main and MainMenu load; compilation only |
| node tools/run-regional-navigation-sparse-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/regional-navigation-sparse-whole-path-01 | same directory/report.json and watchdog.json |55/56 pass; failed accepted_completion_rotation_services_second_retained_tile |

The failed sparse contract still passed eventual acknowledgement, source-ID cursor
retention, physical mutation rejection, changed-source rejection and cancellation.
It exited1 naturally, cleanup passed, owned-process zero, no timeout or engine error.
Do not treat partial checks as a passed suite. No test or gameplay timeout was raised.
Read-only engine-source inspection supports a specific fixture explanation:
deferred initialization can run during the physics message flush, then await
process_frame within the same engine iteration. The process-frame counter advances
at iteration end, so the production same-frame guard can correctly skip that call.
The report lacks counters, so this remains an explanation to verify, not a proven
diagnosis. Wait for an actual counter transition, assert it, and record selected
tile/cursors; retain fairness on the second eligible tick and the12-frame bound.
See Godot4.6 main/main.cpp and scene/main/scene_tree.cpp in the upstream source.
No code changes
or additional runs were made after this failure.

## Remaining acceptance sequence

Resolve the sparse fairness failure with frame-ID/selected-key evidence; keep its
bounded eventual-progress requirement. Then run the publication lifecycle,
startup readiness and Citadel publication contracts with current sources.

Next use the preserved failing Citadel seed for one headed replay, inspect ready,
approach and terminal screenshots and correlate accepted serials, visits, physical
validation cost and regional acknowledgement. Stop on failure; do not replay
successive speculative patches.

If that passes, run ordinary MainMenu New Game, Continue with preserved input save,
the functional playtest, relevant NPC/navigation regression coverage and normal
runtime traversal/performance observation. The diagnostic's setup teleports,
daytime/weather flags and skip-tutorial mode cannot substitute for those gates.
Compare loading stages and saved position with appropriate prior evidence.

Other unresolved risks to measure rather than hide:

- Global revision checks and repeated physical validation remain in capture.
- A smaller admitted request that cannot cover fresh local requirements can still
  delay selection of a larger valid enclosing owner.
- Whole-town closure expansion remains a separate recorded issue.
- No new proof yet establishes smooth traversal, acceptable loading time, ordinary
  save/restore behavior or complete NPC/door gameplay on the current tree.

Merge remains explicitly on hold.

## Engine reference

Godot4.6 documents process_frame as a signal immediately before node processing:
https://docs.godotengine.org/en/4.6/classes/class_scenetree.html
An awaited signal alone should not be used as evidence that a frame-counter
guard admitted a second service call. Record the actual counter and call order.
Navigation synchronization is also a distinct cost/phase:
https://docs.godotengine.org/en/4.6/tutorials/navigation/navigation_optimizing_performance.html

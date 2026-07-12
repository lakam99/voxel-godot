# Phase 2 Structure Manifest Authority

## Objective

Make `StructureSystem` the sole publisher and validator of deterministic generated-town manifests, using its existing home records, door generation, structure queue, and town RNG order.

This phase follows Phase 2 of `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`. It does not migrate tutorial startup or NPC registration; those remain Phase 3 and Phase 4 work.

## Branch And Commit

- Branch: `codex/vox-72-structure-manifest-authority`
- Implementation commit: `3a9c71f` (`Publish deterministic town manifests from structures`)
- Linear: `VOX-72`
- New production authority: `StructureSystem.town_manifest_status()`
- New loading operation: `StructureSystem.request_town_manifest_publication()`

## Files Changed

- `scripts/StructureSystem.gd`
- `scripts/testing/StructureTownManifestContractRunner.gd`
- `tools/run-structure-town-manifest-contract-tests.ps1`
- `tools/test-runner-registry.json`

## Ownership Decisions

### One Record Authority

`town_home_records` remains the only authoritative generated home registry. `town_manifest_publish_states` contains bounded generation lifecycle and metrics only; it does not duplicate home, door, or structure records.

The manifest is assembled on demand from published `town_home_records`. It is a serializable validated view, not a second mutable registry.

### Read Versus Mutation

`town_manifest_status(town, requirements)` is a read-only validation query. It:

- validates semantic requirements before examining generation state;
- reads only published home records;
- derives stable home and door portal identities;
- counts only pending structure operations owned by the requested town;
- returns structured `ready`, `pending`, or `failed` readiness;
- reports required keys, published keys, pending operation count, generation attempts, elapsed loading time, publication state, and all validation failures.

It does not enqueue work, build structures, consume RNG, promote deferred records, or mutate publication state.

`request_town_manifest_publication()` is the bounded loading mutation. It enqueues the existing deferred town build once, then processes the existing FIFO structure queue under caller-supplied operation and time budgets. Repeated polling never starts a second generation attempt.

### Deferred Publication

Town-owned deferred structure operations carry a stable `townKey`. Generated home records remain in `deferred_town_home_records` until the FIFO publication marker executes after the associated paths, perimeter, home blocks, doors, market, and utility operations.

A manifest cannot become ready while town-owned structure operations remain pending. Publication with missing required semantic home keys becomes the terminal structured failure `required_town_manifest_generation_failed`.

### Existing Generation Preserved

The implementation reuses:

- the existing `town-build` seed;
- `town_home_count()` and `town_home_sites()`;
- the existing synchronous and deferred building functions;
- the existing structure queue and FIFO ordering;
- generated door placement and portal ID format;
- `town_home_records` and `deferred_town_home_records`.

No dialogue, tutorial, NPC, route, or test code generates production homes. The removed late `build_town_homes_now()` path is not replaced with another synchronous fallback.

## Contract Tests

Command:

```powershell
.\tools\run-structure-town-manifest-contract-tests.ps1 `
  -ReportPath '.\artifacts\tutorial-town\vox72-structure-town-manifest-contract.json'
```

Result: 10 passed, 0 failed.

Coverage:

1. Known and freshly randomized seeds reproduce identical manifests and structure call counts.
2. Required semantic home keys include complete stable identity, door portal, and strict interior records.
3. A town-owned pending operation prevents readiness.
4. Deferred records remain non-authoritative until the FIFO publication marker.
5. Status polling is read-only.
6. Invalid semantic requirements fail before generation.
7. Repeated ready polling does not duplicate records, buildings, doors, blocks, or generation.
8. Bounded loading polling enqueues exactly one generation attempt.
9. Full bounded deferred generation reaches the exact synchronous manifest.
10. Actual excluded home sites produce a structured deterministic generation failure.

The fresh seed labels in the final verification run were:

```text
phase2-fresh-935956792
phase2-fresh-3270512651
```

The deferred parity case completed in 68 bounded polls, observed a 283-operation queue peak, and produced the same manifest and 1,595 structure block calls as synchronous generation.

The runner is registered as required contract evidence in `tools/test-runner-registry.json`. Its scope explicitly excludes tutorial runtime and live gameplay acceptance.

## Verification

| Check | Result |
| --- | --- |
| `run-structure-town-manifest-contract-tests.ps1` in active and clean committed trees | Passed, 10/10 in both |
| `run-town-runtime-manifest-contract-tests.ps1` | Passed, 11/11 |
| `run-project-compile-smoke.ps1` in active and clean committed trees | Passed in both |
| `test-evidence-registry-self-test.ps1` | Passed, 3/3 |
| Deferred versus synchronous manifest | Exact match |
| Repeated readiness polling | One generation attempt, no duplicate output |
| Invalid/excluded requirements | Structured terminal failure |
| `git diff --check` | Passed |

## World Signature

The world signature was generated in one clean detached worktree at clean `master` commit `b11acbd`, then at Phase 2 implementation commit `3a9c71f`, using seed `atlas-1492` and the same local GDExtension binaries.

The complete generated JSON files are byte-identical:

```text
master bytes: 263801
phase 2 bytes: 263801
master SHA-256: CB567F741495CD62748CF1EC6B0B75A7795537CC22EE48B495593D7E7B7B8D5F
phase 2 SHA-256: CB567F741495CD62748CF1EC6B0B75A7795537CC22EE48B495593D7E7B7B8D5F
```

Evidence: `artifacts/tutorial-town/vox72-world-signature-comparison.json`.

The standard baseline comparison remains red on both commits because its tracked baseline was already stale on clean `master`. The baseline was not weakened or updated. `VOX-79` tracks the required root-cause investigation and deliberate baseline repair.

## Residual Scope

- Tutorial startup still uses the legacy count-oriented escape hatch until Phase 3 replaces it with structured manifest polling.
- Gameplay is not yet gated on manifest, terrain collision, door, NPC, or initial navigation readiness.
- Tutorial actors are not yet registered from manifest assignments; Phase 4 owns that migration.
- Tutorial-specific movement holds and Mira release code remain until Phase 5.
- This phase makes no live gameplay, NPC movement, or pathfinding acceptance claim.
- The Phase 0 `pending_budget` route delay remains a separate shared route-authority risk and is not hidden by this phase.

## Exit Decision

- Phase 2 manifest authority gate: passed
- Deterministic world delta: unchanged
- Standard tracked baseline health: pre-existing failure tracked by `VOX-79`
- Tutorial/runtime migration performed: no, by design
- Next phase allowed: yes
- Next phase: Phase 3 startup loading readiness only

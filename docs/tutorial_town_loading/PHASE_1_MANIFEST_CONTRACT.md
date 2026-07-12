# Phase 1 Manifest Contract

## Objective

Define deterministic, serializable contracts for generated-town readiness, startup status, and generic NPC command acceptance before any production migration.

## Branch And Commit

- Branch: `codex/vox-71-town-manifest-contracts`
- Implementation commit: `31a7b5c` (`Define generated town readiness contracts`)
- Linear: `VOX-71`
- Production callers added: none
- Runtime behavior moved: none

## Files Changed

- `scripts/world/TownRuntimeManifest.gd`
- `scripts/world/StartupReadinessResult.gd`
- `scripts/npc_ai/contracts/NpcOrderAcceptance.gd`
- `scripts/testing/TownRuntimeManifestContractRunner.gd`
- `tools/run-town-runtime-manifest-contract-tests.ps1`
- `tools/test-runner-registry.json`

## Contract Decisions

### Town Manifest

`TownRuntimeManifest` schema version 1 owns data normalization, semantic requirement derivation, validation, and canonical serialization only.

The manifest contains:

- seed, town key, center, and generation revision;
- required semantic home keys derived from actor specifications;
- homes indexed by canonical string keys;
- published door portal IDs;
- pending required structure operation count;
- source identity counts for duplicate detection;
- structured failure and pending reasons;
- a derived `ready` value.

Every supplied home is validated, not only the required subset. Validation reports all discovered problems and checks:

- missing required semantic keys;
- duplicate home keys, stable IDs, and door portal IDs;
- cross-town records;
- stable identity;
- home, porch, door, landing, and strict interior cells;
- strict interior bound orientation and containment;
- coherent porch -> door -> landing -> home route semantics;
- portal publication;
- live `Object` references;
- deterministic serialization independent of input ordering.

The manifest contains no node references and does not generate structures.

### Startup Readiness

`StartupReadinessResult` defines one result shape:

```gdscript
{
    "ok": bool,
    "status": "ready|pending|failed",
    "reason": String,
    "manifest": Dictionary,
    "pending": Array,
    "metrics": Dictionary
}
```

`ready` is successful and has no pending items. `pending` is retryable, requires an explicit reason and pending requirements, and is not success. `failed` is terminal and requires a reason.

### NPC Order Acceptance

`NpcOrderAcceptance` separates retained gameplay intent from route readiness:

- `accepted`: the generic order has a stable ID/kind and was retained;
- `rejected`: the order was not retained and includes a failure reason;
- `cancelled`: a previously retained order was cancelled.

An accepted `order_go_home` does not claim a route is ready, moving, or arrived. Route status keys are prohibited from the acceptance result. The contract intentionally accepts a retained order whose independent route authority may still be `pending_budget`.

## Contract Tests

Command:

```powershell
.\tools\run-town-runtime-manifest-contract-tests.ps1 `
  -ReportPath '.\artifacts\tutorial-town\vox71-town-runtime-manifest-contract.json'
```

Result: 11 passed, 0 failed.

Coverage:

1. Actor specifications derive semantic home keys.
2. A complete manifest becomes ready.
3. A missing required key is reported by key.
4. A duplicate home key is not silently overwritten.
5. Duplicate stable home and portal identities are rejected.
6. A record from the wrong town is rejected.
7. Missing door and strict interior data reports all defects.
8. Reordered inputs serialize identically.
9. Ready, pending, and failed startup summaries validate distinctly.
10. Order acceptance retains intent without claiming route readiness.
11. Live node references are rejected.

The runner is registered as required contract evidence in `tools/test-runner-registry.json`.

## Verification

| Check | Result |
| --- | --- |
| `run-project-compile-smoke.ps1` in active worktree | Passed |
| Compile smoke on clean committed tree | Passed |
| Focused contract runner in active worktree | 11/11 passed |
| Focused contract runner on clean committed tree | 11/11 passed |
| `test-evidence-registry-self-test.ps1` | Passed, 3/3 |
| Production caller source audit | Passed; references exist only in the three contract files and the contract runner |
| `git diff --check` | Passed |

## World Signature

The standard `run-world-signature.ps1` command reports a mismatch on both clean `master` (`6409149`) and Phase 1 (`31a7b5c`). The tracked baseline predates existing generated-world changes:

- generated blocks: current 1,300, baseline 1,216;
- loaded chunk keys: current 37, baseline 49;
- props: current 32, baseline 1,124;
- structure counts and town-home records also differ.

The baseline was not updated in this phase.

To isolate the Phase 1 delta, the signature was generated from a clean detached `master` worktree, preserved, then generated again from clean commit `31a7b5c` with the same local GDExtension binaries. The two complete signature files are byte-identical:

```text
SHA-256 CB567F741495CD62748CF1EC6B0B75A7795537CC22EE48B495593D7E7B7B8D5F
```

This proves Phase 1 did not change deterministic world output while preserving the pre-existing stale-baseline failure for separate correction.

## Residual Risks

- The checked-in world-signature baseline remains stale and the standard wrapper remains red before and after this phase.
- These contracts are intentionally dormant. Structure generation does not publish manifests until Phase 2.
- Startup loading does not consume the readiness result until Phase 3.
- Generic NPC order methods do not expose this acceptance result until the later migration phase.
- This phase makes no live gameplay or pathfinding acceptance claim.

## Exit Decision

- Phase 1 contract gate: passed
- Deterministic Phase 1 delta: unchanged
- Standard baseline health: pre-existing failure, not weakened or rewritten
- Linear status after report update: Done
- Next phase allowed: yes
- Next phase: Phase 2 StructureSystem manifest authority only

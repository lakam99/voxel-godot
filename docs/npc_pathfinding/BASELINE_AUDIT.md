# NPC Pathfinding Baseline Audit

Phase branch: `npc-pathfinding/phase-00-baseline-harness`
Base branch: `master`
Audit date: 2026-06-25
Controlling specification: `CODEX_NPC_PATHFINDING_FINAL_IMPLEMENTATION_PLAN.md`

## Scope

This audit freezes the pre-replacement NPC movement and autonomy state before Phase 01 changes runtime ownership. It records current architecture, known defects, current runner evidence, and static-search findings. The findings below are baseline debt for later phases, not Phase 00 behavior changes.

## Pre-Phase Worktree State

- `git branch --show-current`: `master` before branch creation, then `npc-pathfinding/phase-00-baseline-harness`.
- `git status --short` before Phase 00 edits showed one pre-existing modified file: `artifacts/baselines/world-signature/atlas-1492.json`.
- The baseline artifact diff is not part of Phase 00 and remains unstaged. Its SHA-256 at audit time was `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`.

## Current Architecture

- `scripts/NpcSystem.gd` is the public NPC integration point and still owns registration, spawn, schedule/job updates, home return state, pending door close ownership, and movement delegation.
- `scripts/NpcPathing.gd` is a `RefCounted` facade used by `NpcSystem.move_npc(...)`.
- `scripts/npc_nav/NpcNavigationWorld.gd` builds one legacy navigation snapshot from blocks, props, roots, height edits, and NPC count.
- `scripts/npc_nav/NpcRoutePlanner.gd` owns the bounded flat-grid route search.
- `scripts/npc_nav/NpcLocomotionController.gd` validates candidate movement, reserves cells/doors, and commits movement by writing `body.global_position`.
- `scripts/npc_nav/NpcGoalPlanner.gd` chooses legacy day, guard, job, forage, and fallback targets.
- `scripts/NpcNavigationTestRunner.gd`, `scenes/NpcNavigationTest.tscn`, and `tools/run-npc-navigation-tests.ps1` provide the current focused NPC regression loop.

## Latest Pre-Phase Evidence

- `npc-navigation-report.json`: 11 results, 0 failures, SHA-256 `B40567FD4ED81A41097E803490C2C4B073A717D6229CF25195D48D05BF563CC4`.
- `playtest-report.json`: 180 results, 0 failures, SHA-256 `9F9E7792B7FB88F9BC4BFF336B0B696F92142A96BC59602708EDB1718DC280B9`.
- `artifacts/world-signature/latest/atlas-1492.json`: SHA-256 `05290360F4ACA4965AC3EB6EA6B4D5E886A01F52CE02E073D1B845DCA87A63D5`, matching the current baseline artifact hash at audit time.
- `artifacts/visual/latest/visual-captures.json`: SHA-256 `2BACCA2E6D95ED8B2BD223DD167DFBD2F1859FD03659791743DCE1074BD6A7FE`, 10 visual capture cases present.
- No `artifacts/story/story-playtest-report.json` file was present during the pre-phase audit.

## Static Search Findings

Commands were run with `rg` against current NPC/pathing/runtime files.

### NPC `StaticBody3D` Construction

- `scripts/NpcSystem.gd:118`: `register_npc(body: StaticBody3D, profile: Dictionary)`.
- `scripts/NpcSystem.gd:269`: `spawn_town_npc(record: Dictionary, index: int) -> StaticBody3D`.
- `scripts/NpcSystem.gd:276`: generated town NPCs use `StaticBody3D.new()`.
- `scripts/NpcNavigationTestRunner.gd:277`, `386`, `393`, `546`, `685`, `769`: focused tests construct `StaticBody3D` NPC/hostile bodies.
- `scripts/NpcPathing.gd:48` and multiple `scripts/npc_nav/*.gd` call sites cast entries to `StaticBody3D`.

### Normal NPC Transform Movement

- `scripts/npc_nav/NpcLocomotionController.gd:134`: normal route movement assigns `body.global_position = move_candidate`.
- `scripts/NpcSystem.gd:286`: spawn placement assigns `body.position = cell_to_position(...)`.
- `scripts/NpcNavigationTestRunner.gd` has several setup/test placement assignments, including direct `body.global_position` changes for test state setup.

### Door Toggles and Pending Closes

- `scripts/MainRuntimeTools.gd:290`: `toggle_door(door: Node) -> bool` is a blind toggle API.
- `scripts/NpcSystem.gd:868` and `874`: `open_door_for_npc` uses `main.toggle_door`.
- `scripts/NpcSystem.gd:889`: `update_pending_door_closes(delta)` owns delayed close attempts.
- `scripts/NpcSystem.gd:910`: close safety currently allows `(player_clear or timed_out)`, so a timeout can override player clearance.
- `scripts/NpcNavigationTestRunner.gd:321`: focused test calls `main.toggle_door(door)` directly.

### Scene Scan / Hash Navigation Revision

- `scripts/npc_nav/NpcNavigationWorld.gd:52-67`: revision scans block keys, root child counts, height edit count, and NPC count into a cached hash-style revision string.
- `scripts/NpcSystem.gd:243-250`: generic town NPC spawn scans home records once per frame via `town_home_records_snapshot()`.

### Route Search Cap and Partial Semantics

- `scripts/npc_nav/NpcRoutePlanner.gd:5`: `MAX_ITERATIONS := 384`.
- `scripts/npc_nav/NpcRoutePlanner.gd:56`: route search iterates `range(MAX_ITERATIONS)`.
- `scripts/NpcSystem.gd:841-842`: porch/home-edge fallback can mark an NPC inside home with `home_porch_fallback`.

### Reservations and Local Avoidance

- `scripts/npc_nav/NpcLocomotionController.gd:5-6`: cell and door reservation TTL constants are frame-count TTLs.
- `scripts/npc_nav/NpcLocomotionController.gd:347-363`: reservations expire by `reservation_frame`.
- `scripts/npc_nav/NpcLocomotionController.gd:309-324`: local avoidance uses fixed side/back vectors.

### Guard Duty / `canFight`

- `scripts/NpcSystem.gd:341`: update logic reads `canFight`.
- `scripts/NpcSystem.gd:276-301`: generic spawn derives guard role and `nightGuard` from `can_fight`.
- `scripts/NpcNavigationTestRunner.gd:793-794`: focused test profiles set `canFight` and `nightGuard` together.

## Baseline Defect Summary

The current code has the exact legacy conditions the controlling specification names: NPCs are `StaticBody3D` bodies, route movement writes transforms, topology is single-surface XZ/grid driven, route search has a small hard cap, doors use blind toggles and delayed close ownership, reservations are frame TTL claims, and porch fallback can satisfy home state. Phase 00 does not change those behaviors; later phases replace them under focused tests.

## Phase 00 Harness Additions

The Phase 00 harness adds:

- `scripts/testing/npc/NpcAutonomyTestRunner.gd`
- `scripts/testing/npc/NpcTestClock.gd`
- `scripts/testing/npc/NpcTestAssertions.gd`
- `scenes/testing/npc/NpcAutonomyTest.tscn`
- `tools/npc/run-npc-suite.ps1`
- `tools/npc/run-npc-contract-tests.ps1`
- `tools/npc/run-all-npc-tests.ps1`
- `tools/npc/npc-suite-registry.json`
- `tools/test-runner-registry.json`
- `tools/run-all-test-runners.ps1`

These files add test/report infrastructure only. No NPC runtime movement, door, route, save, story, visual, or world-generation behavior is changed in Phase 00.

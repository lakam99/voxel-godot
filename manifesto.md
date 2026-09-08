# NPC Pathfinding Stability Manifesto

## The Current Situation

NPC pathfinding is stable. The replacement work that this manifesto originally demanded has been completed, and the production route stack is now established infrastructure.

Pathfinding is no longer a general project priority, an invitation to continue iterating, or a subsystem to improve opportunistically. Future agents must not read the historical pathfinding plans as an active mandate. Those documents remain useful context only when a task is specifically and expressly about pathfinding.

The priority now is preservation.

## The Prime Directive

Leave pathfinding alone unless the assigned work is specifically and expressly pathfinding work.

Use a ten-thousand-foot pole. Do not refactor, simplify, modernize, optimize, clean up, reorganize, rename, consolidate, or otherwise alter stable pathfinding code while working on another feature or bug.

In particular:

- Do not make opportunistic pathfinding changes while touching NPC gameplay, world generation, loading, performance, doors, structures, or the tutorial.
- Do not replace a working pathfinding contract with an approach that appears cleaner in isolation.
- Do not change route behavior merely because a synthetic test, static inspection, or local code preference suggests an improvement.
- Do not widen a task into pathfinding work because pathfinding is adjacent to the requested system.
- Do not silently fix a suspected pathfinding regression encountered during unrelated work.
- Do not weaken, bypass, or rewrite pathfinding tests to accommodate a change elsewhere.

Passing pathfinding code is protected code. Stability is more valuable than speculative improvement.

## What Is Protected

The protected pathfinding surface includes, but is not limited to:

- navigation topology and publication;
- route planning, proof, commitment, leasing, repair, and cancellation;
- route readiness and failure classifications;
- collision-backed route validation;
- NPC route-following and movement-controller contracts;
- door portal and threshold traversal;
- traffic reservations and crossing ownership;
- pathfinding recovery and fallback behavior;
- pathfinding-specific save, streaming, observation, and test contracts;
- `scripts/NpcPathing.gd` and the navigation, routing, movement, interaction, and traffic systems under `scripts/npc_ai/`.

NPC profiles, schedules, dialogue, quests, jobs, combat, and presentation may still be changed when they are in scope, but those changes must consume the established route authority through its existing public contracts. They must not alter pathfinding internals as an incidental implementation detail.

If a requested feature appears to require a protected change, stop and explain why. Obtain explicit agreement that pathfinding work is now in scope before editing it.

## What Counts As Express Authorization

A broad request to work on NPCs, terrain, a town, doors, loading, performance, or world generation is not authorization to change pathfinding.

Authorization must specifically identify pathfinding, navigation, routing, route execution, or a confirmed regression in that layer as work to be performed. When intent is ambiguous, preserve the subsystem and ask before changing it.

Read-only diagnosis is allowed when necessary to determine whether pathfinding is involved. Diagnosis does not authorize a fix.

## The World-Generation Firewall

World generation and pathfinding are tightly coupled through terrain occupancy, collision, structures, towns, doors, chunk streaming, and navigation publication. Any work that can affect generated geometry or those contracts must treat pathfinding verification as a hard gate.

Before world-generation implementation begins:

1. Record the current branch, working-tree state, seed, and relevant baseline behavior.
2. Run the applicable pathfinding regression suites against the unchanged baseline.
3. Include a real headed gameplay run when generated terrain, towns, homes, doors, collision, streaming, or navigation publication may be affected.
4. Inspect the reports, traces, progress files, and screenshots rather than trusting a result boolean alone.

At minimum, use the established NPC regression commands relevant to the change, including:

```powershell
node tools/npc/run-npc-contract-tests.mjs -TimeMode Both
node tools/npc/run-all-npc-tests.mjs -TimeMode Both
```

Use the applicable live runner as well, such as the real tutorial playthrough or town job/home visual playtests, when the affected generated-world behavior is exercised there.

If the baseline exposes any pathfinding regression, no implementation work begins. Stop, report the regression, and discuss it with the user first.

After each meaningful world-generation change, and again before acceptance, rerun the applicable pathfinding regression coverage using the same baseline conditions. Add fresh random generated-town seeds where practical, while retaining any known failing seed for reproduction.

If a pathfinding regression appears after work has begun:

- Stop further implementation immediately.
- Do not patch pathfinding.
- Do not add a fallback, special case, teleport, doctored vector, named-NPC exception, or test-only bypass.
- Do not reinterpret the regression as acceptable collateral damage.
- Preserve the failing seed and evidence.
- Report and discuss the regression before any work resumes.

Resuming with a pathfinding fix requires explicit direction that expands the task to include pathfinding. Until then, the correct action is to leave the protected subsystem untouched.

## Regression Reporting Is Mandatory

Any suspected pathfinding regression must be reported with:

- the exact command used;
- the seed and relevant setup;
- the report and artifact paths;
- screenshots, trace, or timeline evidence when behavior is visual;
- the expected behavior and actual behavior;
- whether the failure exists on the unchanged baseline;
- the earliest known change after which it appears;
- a clear statement of what each test does and does not prove.

Mocked, synthetic, direct-service, metadata-only, source-scan, helper-call, and teleport-driven tests may support diagnosis, but they are not live gameplay acceptance evidence.

Do not conceal a regression by continuing unrelated work. Do not start remedial work until the regression and the proposed scope have been discussed.

## If Pathfinding Work Is Explicitly Authorized

The established production contracts remain mandatory:

- One route authority decides whether intent can become movement.
- Committed routes are backed by real collision and actor-footprint proof.
- Route readiness distinguishes ready, pending navigation data, pending budget, dynamic blockage, static unreachability, and invalid goals.
- Doors open before crossing, provide real clearance, retain crossing ownership, and close after clearance.
- An NPC is indoors only at a strict interior location, not on a porch, threshold, wall edge, or roof.
- Named NPCs do not receive routing privileges, special movement logic, or actor-specific fallbacks.
- Production movement does not use teleports, doctored vectors, hand-authored offsets, partial endpoint success, or direct loops that bypass route authority.
- Live gameplay is the source of truth, and headed acceptance must agree with automated coverage.

Read the controlling pathfinding plans, invariants, prohibited shortcuts, and test protocols before making any authorized change. Keep the change narrowly scoped and prove that the rest of the stable system remains intact.

## The Mandate

Pathfinding is stable. Protect it.

Do not continue the old replacement campaign. Do not touch pathfinding as collateral work. Test it whenever world generation could affect it, and treat any regression as a stop-work event requiring evidence, disclosure, and discussion.

When in doubt, keep the ten-thousand-foot pole between the task and the pathfinding code.

# NPC Pathfinding Manifesto

## The Situation

This game was progressing well until NPC pathfinding became the dominant blocker. For roughly two weeks, the project has been stuck in a loop: one NPC gets moving, another stops; one route passes, another stalls; one screenshot looks correct, then live gameplay contradicts it.

That pattern is the signal. This is not a Mira bug, a Niko bug, a Rowan bug, or a single bad seed. The current NPC pathfinding approach is not working as a production system.

The game needs reliable NPC autonomy more than it needs another patch around today's stuck actor.

## What Is Not Working

The existing system has too many authorities. Schedule logic, behavior planning, route planning, navmesh readiness, generated-cell fallbacks, traffic reservations, door traversal, home settlement, scripted tutorial orders, and movement recovery can all influence whether an NPC moves.

When an NPC stands still, the system cannot give one clear answer:

- Is the NPC waiting by schedule?
- Did behavior fail to choose a goal?
- Did route planning fail?
- Is nav data still pending?
- Is a door blocking the route?
- Is traffic reservation holding it?
- Is the route considered arrived too early?
- Is the NPC inside, outside, or stuck on a threshold?

If the system cannot answer that question clearly, it cannot be trusted.

## The Principle

Live gameplay is the source of truth.

A test scene, synthetic setup, metadata flag, direct helper call, or isolated happy-path screenshot cannot overrule what happens when the player boots the game, clicks New Game, and watches NPCs fail to live their lives.

The pathfinding system must serve the game, not the test harness.

## The Line In The Sand

No more named-NPC patches.

No more fixes that make Mira move but leave Niko idle.

No more fixes that make Niko forage but leave Rowan trapped indoors.

No more "arrived" states that mean an NPC is on a porch, in a doorway, or near a wall.

No more route success based primarily on metadata.

No more broad claims from narrow acceptance tests.

No more expanding a stack that cannot explain its own failures.

## The Replacement Standard

The project needs one NPC route authority.

Behavior may choose intent:

- `go_home`
- `go_work`
- `forage`
- `guard`
- `idle`

But one route authority must decide whether that intent can become movement.

That authority must own:

- route planning;
- collision validation;
- dynamic blocker response;
- door portal traversal;
- threshold clearance;
- route commitment;
- route cancellation;
- route failure reasons.

The movement motor should only follow committed route segments. It should not invent route semantics. Behavior should not guess around route failures. Tests should not certify success by bypassing the route authority.

## Collision Is The Contract

A route is not real until the game can prove it physically.

NPC pathfinding must be collision-based. It should not guess whether a route is blocked. Before committing an NPC to a route, the route authority must be able to probe the path with the actor's real movement footprint and answer:

- Can the NPC stand here?
- Can the NPC move from this point to the next point?
- Does this segment collide with terrain, walls, fences, props, doors, or other blocking bodies?
- If a door is involved, can it open, provide clearance, allow crossing, and close after the NPC clears it?
- If the route is blocked dynamically, can the NPC wait, replan, or choose a valid fallback without poisoning the goal forever?

If the answer is not known, the route is not ready.

## Door And Home Rules

Homes and doors are not metadata achievements.

An NPC is home only when the body reaches a strict interior location, clears the threshold, and is no longer occupying the door sweep or porch edge.

A door route must prove the visible sequence:

1. Approach the door.
2. Open the door before crossing.
3. Cross through valid clearance.
4. Reach a strict interior or exterior target.
5. Clear the threshold.
6. Close the door when safe.

Porches, thresholds, exterior wall edges, roofs, and "close enough" cells do not count as inside.

## Acceptance Must Match The Game

The next acceptance target should be a real-boot town autonomy matrix, not a single NPC screenshot.

The gate should boot the actual game, click New Game, avoid gameplay-affecting test flags, complete the relevant tutorial flow through player input, sleep, and observe the following morning.

For each major NPC, the report must show:

- schedule state;
- behavior intent;
- target;
- route status;
- route reason;
- route authority proof;
- distance moved;
- door state if applicable;
- final gameplay-visible state.

At minimum, the matrix should cover:

- Mira returning home after the knock and behaving correctly the next morning.
- Niko leaving or starting outside and actively foraging when that is their role.
- Rowan leaving home or moving to the expected work behavior.
- Guards remaining on guard when appropriate.
- Non-guards returning indoors at night.

Standing still is acceptable only if the report gives a truthful gameplay reason.

## What To Keep

Do not throw away useful game data just because the route stack is suspect.

Likely reusable pieces include:

- NPC profiles;
- roles and schedules;
- home records;
- town structure metadata;
- door metadata;
- semantic intent selection;
- character motor movement;
- visual NPC bodies and animation hooks;
- existing live playtest lessons.

The problem is not that NPCs have homes, jobs, doors, or goals. The problem is that too many systems compete to interpret and execute those facts.

## What To Retire

The current route decision stack should be treated as legacy until proven otherwise.

Any pathfinding component that cannot clearly answer "why is this NPC not moving?" should either be replaced or demoted behind the new authority.

Fallbacks must not become normal behavior. Recovery code must not define the main route contract.

## Definition Of Done

NPC pathfinding is not done when one NPC reaches one destination.

It is done when, in real gameplay:

- NPCs consistently choose appropriate goals;
- NPCs move with purpose;
- NPCs enter and exit homes through real doors;
- foragers forage;
- workers work;
- guards guard;
- night behavior and morning behavior both function;
- blocked routes produce clear, actionable reasons;
- live playtests and manual gameplay tell the same story.

Until then, the project should prioritize replacing the NPC pathfinding authority over adding more gameplay features that depend on it.

## The Mandate

Stop patching symptoms.

Build one collision-backed route authority.

Make live gameplay and automated playtests agree.

Then the game can move forward again.

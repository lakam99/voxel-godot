# NPC Nav Collision Plan

## Summary
Fix this at the navigation layer: NPC routes must be generated from collision-aware traversability, not from “destination cell looks open” guesses. The goal is that nav refuses any route segment whose swept NPC body would cross a wall, high block, closed non-route door, prop, or too-steep terrain. Door traversal remains the explicit valid exception through a wall boundary.

## Key Changes
- Add a shared collision-aware transition check in the generated-world nav adapter:
  - New API shape: `cell_transition_pathable(entry, snapshot, from_cell, to_cell, target_cells, ignore_dynamic := false)`.
  - It replaces edge-level use of `cell_pathable` in route graph construction.
  - It checks the swept corridor between cell centers, not only the destination cell.
  - It uses the same block collider geometry created by `create_block`: blocking box size, offset, rotation, block type, door metadata, and nonblocking exceptions like paths/torches.

- Build deterministic static collision records during nav snapshot rebuild:
  - Cache blocking block/prop footprints as XZ obstacle records derived from their `CollisionShape3D`/`BoxShape3D`.
  - Doors stay separate records with portal id, door side/axis, policy, and open/closed state.
  - A transition crossing a blocking record fails unless it is crossing the matching door portal in the correct direction.
  - Terrain height still rejects water and too-high/too-steep transitions.

- Validate both route sources:
  - Generated corridor graph edges use `cell_transition_pathable`.
  - Navmesh route results get post-query validation before acceptance: each waypoint segment is sampled into cell transitions and rejected if any transition crosses static collision.
  - If navmesh returns a bad path, return a clear reason such as `path_crosses_static_collision` and allow the existing generated-corridor fallback to try a valid route.

- Keep motor collision as the final safety net:
  - Do not remove capsule sweeps in `NpcRouteMovementController`.
  - If motor collision still catches a wall, mark the route stale and force replanning with the offending transition recorded.
  - The intended end state is that motor wall hits become rare diagnostics, not normal routing behavior.

## Test Plan
- Add focused synthetic route tests:
  - Wall boundary between two cells blocks the transition even when the destination cell itself is otherwise open.
  - A closed wall with a door only permits crossing through the door portal/action cell.
  - Diagonal corner-cutting across two blocked wall edges is rejected.
  - Navmesh route post-validation rejects a path that crosses a static wall boundary.

- Add tutorial regression coverage:
  - `tutorial_start` fails if Mira enters the player-house interior after the knock dialogue or attempts to route through the starter-house back/corner wall.
  - Real headed Mira return-home acceptance still proves: leave starter area, route through actual town, open her home door, enter strict home interior, door closes.
  - Screenshots must include Mira’s departure path from the player house and the successful arrival at her own home.

- Run verification:
  - `.\tools\npc\run-npc-route-tests.ps1 -TimeMode Day`
  - `.\tools\npc\run-real-tutorial-playthrough.ps1 -Visible -MiraHomeOnly`
  - `.\tools\run-playtest.ps1` with tutorial start coverage
  - If final rescue routing changed, rerun `.\tools\npc\run-real-tutorial-playthrough.ps1 -Visible -FinalRescue`

## Assumptions
- Do not add NPC-specific rules like “Mira cannot enter the player house.”
- Door permissions remain policy-based, but wall avoidance comes from collision-aware transition validation.
- Tests must not fake acceptance; headed tutorial evidence is required for the Mira regression.
- This pass fixes route/collision disagreement, not unrelated tutorial gate destruction noted in `AGENTS.md`.

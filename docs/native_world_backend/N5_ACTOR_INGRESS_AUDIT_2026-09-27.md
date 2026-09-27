# N5 actor ingress audit — 2026-09-27

Evidence level: read-only static source audit. Production source is pinned to
`b9e69bd36173ba067494a6f56d3de36e7c5f1eea`. This report does not establish
runtime correctness, N5 cutover, physical acceptance or gameplay acceptance.
No parser, build, test, engine or runner was executed for this audit.

## Finding and authority boundary

N5 actor-safe ingress is incomplete and not bound in normal production at the
pinned revision. `scripts/MainCore.gd:322–344` allows motion, registration and
placement when the admission owner ID is zero. The production source search
found `NativeTerrainCollisionPublicationRuntime.bind_main_core` only as a
definition (`scripts/terrain/NativeTerrainCollisionPublicationRuntime.gd:647–655`),
not a production invocation. `MainCore.gd:347` also rejects owner IDs `<=0`;
the binding contract needs nonzero and exact identity rather than positivity
for signed ObjectIDs.

Bind the source-linked router before playable startup and actor admission.
Keep the binding throughout edit replacement and stop; unbind only after the
exact body, actor and lease drains. Canonical volume/native source remains
terrain authority. Source capture, insertion, current physical body or
canonical-empty proof, physics ACK and gameplay contact are separate facts.

The pinned review already leaves production binding and source-revision-complete
residents open: `docs/native_world_backend/N3_N5_PHYSICAL_HANDOFF_REVIEW_2026-09-23.md:15,26`.
Its cutover requirement is one terrain collision authority: disable production
VoxelTerrain/viewer-generated terrain collisions only when the native resident
set and callers are proven; preserve legitimate render/source and feature uses.

## Production family and ingress map

All anchors below refer to the pinned production commit, not this report's
checkout. Ranges identify the inspected contract, not measured coverage.

| Family / ingress | Existing source path | Required admission/publication seam |
| --- | --- | --- |
| Player motion | `PlayerController.gd:192` calls shared `npc_ai/motor/CharacterMotor3D.gd`; motion guard at `46–55`, correction guards at `177–190` | Preserve motor behavior; provide an active source-linked router before motion. |
| Player startup and Continue | `MainSetupScene.gd:278–283`; `MainSaveState.gd:418` directly assigns position | Retain/retry placement until destination physical receipt and actor registration are current; suspend physics until admitted. |
| Relocation and teleport | `MainDiscoveryFlow.gd:355–367` waits for existing streaming readiness then places; convenience `teleport_to_cell:402–408` assigns directly | Extend existing destination readiness with exact N5 proof; guard final placement and rollback. Teleport setup is not locomotion acceptance. |
| NPC motion | Shared motor guards above; `npc_ai/NpcMotionController.gd:139,147` directly applies vertical collision motion | Resolve correction-path reachability and guard applied sweeps through established admission without replacing route authority. |
| NPC spawn/restoration placement | `NpcSystem.gd:916–930` reaches `npc_ai/NpcSafePlacementService.gd:14–32`, which validates a capsule then places directly | Retryable registration/placement admission at the existing boundary, retaining capsule validation, spawn and save behavior. |
| Moving static hostiles | `HostileSystem.gd:780–828` constructs/registers/admits placement; motion at `860–863`, vertical guards at `1147–1149,1243–1245` | Preserve pooling/respawn; required admission flag currently depends on router binding. Audit every transform update. |
| Character hostiles | `combat/hostile/HostileBehaviorController.gd:142` calls `HostileLocomotionDriver.gd:34` (`move_and_slide`) | Inspected executor has no admission call; supply an admission-aware motion boundary without a second movement authority. |
| Hostile projectiles | `HostileProjectileSystem.gd:45,69–104`: visual mesh moved after swept physics ray and block query | Require current coverage for the entire ray segment. Pending coverage must retain the step rather than treat no hit as clear. |
| Player projectiles | `PlayerProjectileSystem.gd:44,140,248`: firing/ray and visual tracer | Guard query coverage through the same physical authority; tracers are not PhysicsBody actors. |
| Pickups | `MainCharacterState.gd:17–35`: Node3D spin/bob and proximity collection | Preserve existing visual/proximity behavior. No production rigid pickup physics was found in the searched scripts/scenes. |
| Building/static placement | `MainInteractionFlow.gd:28,97,177,338` creates static bodies/places blocks; chunk construction also creates static bodies | Separate durable terrain edit publication from feature/structure collision. Preserve actor clearance, edit barriers and publication leases. |

`NativeCollisionAdmissionBarrier.gd:89–99` supports CharacterBody and explicitly
grouped moving StaticBody actors. The searched production scripts/scenes had no
RigidBody3D or AnimatableBody3D family. This is a bounded inventory finding,
not a guarantee about future dynamic extensions or external scenes.

## Critical dependencies and protected boundaries

Read the pinned `manifesto.md` before the NPC inspection. It protects routing,
navigation, route execution, motors, doors, traffic and recovery. This audit
authorizes no edits to those systems. Any necessary protected implementation
change needs explicit scope authorization; preserve ordinary NPC commands and
routes, not named-actor exceptions or direct movement repairs.

Ingress must compose with actor census and swept-shape checks, source/current-R
and exact generation binding, resident install/health ACK, old-owner retirement,
leases, destination streaming requests and save restoration. Spawn and motion
requests must remain retryable while dependencies are pending. New actors,
pool reuse and destination changes must not bypass an existing hold. Shutdown
must seal new admission before physical owners and native source are released.

Unresolved caller scope includes dynamic/aliased placement, scene replacement,
spawn cancellation, reachable NPC correction branches, character-hostile
admission, projectile coverage semantics and old terrain-authority deletion.
The inventory is not an exhaustive proof of every inherited or dynamic call.

## Minimal real headed acceptance package

Proposed new headed N5 ingress fixture: ordinary player input crosses a native
window seam, edits terrain under/near an actor, waits through replacement and
crosses again. Include a late NPC/hostile spawn, pool reuse, destination placement
during a hold, projectile sweep, stop/reset and Continue. Use real bodies,
physics frames and production public paths; do not synthesize insertion/body
ACKs, teleport the act phase or call scenario progression directly.

Existing commands to reuse where relevant, not executed for this audit:

- `node tools/npc/run-real-tutorial-playthrough.mjs` and existing town home/job
  visual runners for ordinary NPC/door behavior after production binding lands.
- Existing digging and underground visual runners for edit geometry, ray hits
  and terrain coherence.
- `node tools/run-n3-n5-physical-handoff.mjs` and
  `node tools/run-n3-n5-windowed-physical.mjs` for focused fixture mechanisms.
  These do not prove normal production ingress by themselves.

Each acceptance artifact must identify exact source commit/tree and source
hashes, build manifest, installed DLL/PDB, Godot executable, dependency/cache
identities, command and seed. Keep reports, screenshots before/after edit and
crossing, actor-motion timeline, per-block source/generation/body receipts,
ray/contact observations and collision layer/body census proving one terrain
authority. Report frame budgets and independent owned-process cleanup receipts
with authoritative zero-member drain. Natural/forced cleanup and functional
result are separate facts.

Unit, contract, synthetic source, direct service and static audit results can
prove local rules. They cannot establish real engine installation, current
physics contact, headed traversal, normal startup/Continue or live gameplay.
No acceptance result is claimed here.

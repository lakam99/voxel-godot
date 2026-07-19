# VOX-150 Forward Tree Readiness Audit

## Delivered behavior

`TreePublicationQueue` now uses the player body's planar velocity and active
camera forward direction as an ephemeral presentation-only signal. Confident
movement prioritizes the predicted forward corridor before equally near
lateral or behind work; stationary or uncertain motion keeps the existing
distance-first order. The signal does not alter tree recipes, biome/age input,
world RNG, collision, saves, navigation, or NPC behavior.

Every collision-bearing tree is also protected by a bounded visibility
invariant. Once it is within 28 m of the player, it has either its final
`GeneratedTreeVisual` or a lightweight shared `TreeVisibilityProxy`. The
proxy uses existing shared trunk/crown meshes and materials, has no collision,
does not create a recipe, and is atomically replaced by the final recipe
visual. At most two newly relevant proxies are attached per frame.

## Evidence

| Check | Result |
| --- | --- |
| `tools/run-tree-publication-queue-contract.ps1` | Passed. Proves forward selection, stationary fallback, immediate collision proxy, approach-after-queue proxy, and atomic final replacement. |
| `tools/run-canopy-runtime-contract-tests.ps1` | Passed (17 runtime-tree contract cases). |
| `tools/run-procedural-tree-performance-benchmark.ps1 -ReportPath artifacts/vegetation/vox150-procedural-tree-performance.json` | Passed. Publication p99 221 us; collision-before-visual breaches 0. |
| `tools/run-world-signature.ps1` | Matched the tracked `atlas-1492` baseline. |
| `tools/run-visual-captures.ps1 -Canopy -OutputDir artifacts/visual/vox150-forward-readiness -Seed atlas-1492` | Completed. Inspected forest traversal and midday captures. |
| Focused canopy release, forest/broadleaf/mature | Passed live menu -> render -> break/fall/drop -> save -> Continue persistence. Seed `atlas-71001120`, removed prop `atlas-71001120:304,-44:2`; report directory `artifacts/vegetation/vox150-canopy-release-forest-mature`. |
| `tools/npc/run-npc-contract-tests.ps1 -TimeMode Both` | Passed, 84 results, 0 failures. |
| Final-rescue headed playtest | Passed, including generic NPC route/door/combat behavior under existing godmode policy. Report `artifacts/npc/reports/real_tutorial_final_rescue-both.json`. |

## Performance observation

Two fixed-seed SprintTraversal observations traversed 697 m and 930 m,
respectively, with no dropped tree publications. The tree queue stayed below
0.84 ms worst frame and 0.36 ms p99 for staged publication. The suite's global
frame-p99 gate was narrowly red (22.52 ms and 22.39 ms vs. 22 ms tolerated),
with the dominant reported work in `sky`/`sky_weather` (24-25 ms), not tree
publication. No sky or weather code was changed under this tree-readiness
issue.

## Separate regressions / pre-existing runner caveats

- The natural generated-town day/night runner reproduced non-guard NPCs
  remaining outside at night on `town-cycle-20260719002731-fb434647`. This is
  tracked separately as VOX-151; no NPC code was changed here.
- Headed visual/release runners continue to print the known generic shutdown
  warning: `ObjectDB instances leaked` and `6 resources still in use at exit`.
  It occurred before this work and remains outside VOX-150's scope.
- The legacy broad canopy-density runner and broad smoke runner have existing
  completion/acceptance failures unrelated to visibility publication. The
  focused live canopy release above is the relevant accepted coverage for this
  issue.

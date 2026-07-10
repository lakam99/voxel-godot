# Phase 8 - Migrate Work, Forage, Guard, And Roam

Phase: 8
Branch: `codex/npc-pathfinding-replacement`
Linear issue: `VOX-38`

## Commands run

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\npc\run-npc-contract-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase8-contract-tests-after-forage-search-anchor-semantic.json
.\tools\npc\run-npc-route-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase8-route-tests-after-forage-search-anchor-semantic.json
.\tools\npc\run-npc-behavior-tests.ps1 -TimeMode Both -ReportPath artifacts\npc\reports\phase8-behavior-tests-after-forage-search-anchor-semantic-2.json
.\tools\npc\assert-npc-acceptance-runner-clean.ps1 -RunnerPath scripts\testing\npc\NpcRealTutorialPlaythroughRunner.gd -ReportPath artifacts\npc\reports\phase8-acceptance-runner-clean-after-forage-search-anchor-semantic.json
.\tools\npc\run-real-tutorial-playthrough.ps1 -Visible -Seed tutorial-20260710080948-4394fd3e -ReportPath artifacts\npc\reports\phase8-full-visible-known-seed-after-forage-search-anchor-semantic.json -ProgressPath artifacts\npc\progress\phase8-full-visible-known-seed-after-forage-search-anchor-semantic.txt -ScreenshotDir artifacts\npc\screenshots\phase8-full-visible-known-seed-after-forage-search-anchor-semantic -TimeoutSeconds 470 -StaleProgressSeconds 60
.\tools\npc\run-real-tutorial-playthrough.ps1 -Visible -MorningOutsideOnly -Seed phase8-morning-fresh-20260710-a -ReportPath artifacts\npc\reports\phase8-morning-outside-fresh-a-after-forage-search-anchor-semantic.json -ProgressPath artifacts\npc\progress\phase8-morning-outside-fresh-a-after-forage-search-anchor-semantic.txt -ScreenshotDir artifacts\npc\screenshots\phase8-morning-outside-fresh-a-after-forage-search-anchor-semantic -TimeoutSeconds 160 -StaleProgressSeconds 45
.\tools\npc\run-real-tutorial-playthrough.ps1 -Visible -MorningOutsideOnly -Seed phase8-morning-fresh-20260710-b -ReportPath artifacts\npc\reports\phase8-morning-outside-fresh-b-after-forage-search-anchor-semantic.json -ProgressPath artifacts\npc\progress\phase8-morning-outside-fresh-b-after-forage-search-anchor-semantic.txt -ScreenshotDir artifacts\npc\screenshots\phase8-morning-outside-fresh-b-after-forage-search-anchor-semantic -TimeoutSeconds 160 -StaleProgressSeconds 45
```

## Reports

- `artifacts/npc/reports/phase8-contract-tests-after-forage-search-anchor-semantic.json`: 72 results, 0 failures.
- `artifacts/npc/reports/phase8-route-tests-after-forage-search-anchor-semantic.json`: 92 results, 0 failures.
- `artifacts/npc/reports/phase8-behavior-tests-after-forage-search-anchor-semantic-2.json`: 49 results, 0 failures.
- `artifacts/npc/reports/phase8-acceptance-runner-clean-after-forage-search-anchor-semantic.json`: acceptance runner guard passed.
- `artifacts/npc/reports/phase8-full-visible-known-seed-after-forage-search-anchor-semantic.json`: known failing seed passed, `failureCount=0`, `playtestGodMode=false`, `fullPlayerPov=true`.
- `artifacts/npc/reports/phase8-morning-outside-fresh-a-after-forage-search-anchor-semantic.json`: fresh morning outside run passed, `failureCount=0`.
- `artifacts/npc/reports/phase8-morning-outside-fresh-b-after-forage-search-anchor-semantic.json`: fresh morning outside run passed, `failureCount=0`.

## Screenshots/traces

- `artifacts/npc/screenshots/phase8-full-visible-known-seed-after-forage-search-anchor-semantic/player_pov_after_morning_forager_observation.png`
- `artifacts/npc/screenshots/phase8-morning-outside-fresh-a-after-forage-search-anchor-semantic/morning_outside_group.png`
- `artifacts/npc/screenshots/phase8-morning-outside-fresh-a-after-forage-search-anchor-semantic/morning_outside_niko.png`
- `artifacts/npc/screenshots/phase8-morning-outside-fresh-b-after-forage-search-anchor-semantic/morning_outside_group.png`
- `artifacts/npc/screenshots/phase8-morning-outside-fresh-b-after-forage-search-anchor-semantic/morning_outside_niko.png`

## Code changed

- Routine V2 route execution now carries the actual semantic intent instead of treating every collision-backed lease as `movingHome`.
- Home departure uses `home_departure_clearance`, with exact-cell collision-backed validation so porch/interior proximity is not accepted as departure success.
- Foragers without a live target use `forage_search_anchor`, which requires an exact outside-work-area anchor instead of broad `work_area` arrival.
- Contract, route, and behavior cases were added or updated to cover moving-home semantics, home departure clearance, and forage search anchors.

## Acceptance result

Pass for Phase 8. The known failing full tutorial seed and two fresh generated morning seeds showed town NPCs selecting and progressing through daytime work/forage/guard style intents through the V2 route authority.

## Known failures

- The older legacy route decision stack still exists and can re-enter through fallback paths. That is Phase 9 scope.
- This phase does not claim final release acceptance. It proves the migrated daytime autonomy matrix needed before legacy production pathfinding removal.

## Next phase allowed

yes

Reason: Phase 8 focused tests, acceptance runner guard, known failing seed, and two fresh headed generated-town morning runs passed with evidence. Phase 9 may proceed to remove legacy production pathfinding.

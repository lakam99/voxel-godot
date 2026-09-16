# World streaming maturity G4 — scale, retirement, and Citadel ground course

Date: 2026-09-16. Status: complete on `codex/world-streaming-maturity-migration`; commit is recorded in the migration ledger after this report is committed.

## Product result

The Citadel keeps its broad shared base. It is now a thin, continuous ground-level course rather than an artificially elevated terrace: a 107.6 × 116.6 m foundation bed and 30 edge-sharing paving tiles, all 0.04 m thick with a common top at Y=0.08. Buildings retain their own foundations. Natural terrain grades are preserved; no Citadel terrace, platform wall, or decorative stair geometry was reintroduced.

The packet publication path now retains a bounded view-ranked resident working set, restores any navigation owner whose unpinned packet selection was discarded, and admits an exact collision dependency closure as one whole unit from hard foreground headroom. This prevents an incomplete collision packet from being mislabeled as retained and becoming a fall-through gap after retirement/revisit.

## Frozen evidence

- Seed: `atlas-3376622889`; candidate region `-2,-2`; initial spawn cell `-3334,-2666`.
- Accepted source SHA-256: `665DE2B3433B921DFD246276976200F5F1751D100B65BBDEA8610E4AE728B884`.
- Focused contracts:
  - `node tools/run-citadel-publication-service-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/publication-service-g4-exact-nav-09` — 169 checks passed.
  - `node tools/run-building-scene-publication-job-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/scene-job-packet-order-g4-stale-owner-08` — 606 checks passed.
- Headed shakedown:
  - `node tools/run-citadel-candidate-teleport-playtest.mjs ... -ScaleSoakSeconds 180 ...` — `artifacts/citadel-runtime-integration/candidate-teleport-g4-view-retention-shakedown-10/report.json`; three retirement/revisit cycles, autosave, settled resource comparison, and ordinary player-scale inspection passed.
- Headed long soak:
  - `node tools/run-citadel-candidate-teleport-playtest.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-g4-continuous-platform-soak-05 -Seed atlas-3376622889 '--CandidateRegion=-2,-2' '--SpawnCell=-3334,-2666' -SkipTutorial -ForceDaytime -ForceClearWeather -ScaleSoakSeconds 1800 -TimeoutSeconds 1200 -StartupTimeoutSeconds 120`
  - 34.68 minutes wall time; three retirement/revisit cycles; autosave passed; no modal loading frames; settled resource comparison passed; clean exit code 0 and owned-process zero proof.

Comparable post-warmup checkpoint signatures matched exactly for the resident gameplay world. Stable background exposure-scan backlog is recorded separately, rather than being misreported as resident resource growth. The final player itinerary used production W/Shift/mouse input and production right-click doors through the curtain, gate, market/natural ground, civic home interior, and gate stair. It reported `ordinary_player_scale_inspection_complete` with no player transform, motor, or door-authority helper call.

Inspected captures from the long soak include `courtyard_overview.png`, `player_day_market_natural_ground.png`, day/night gate and stair captures, and both furnished civic home interior views under `artifacts/citadel-runtime-integration/candidate-teleport-g4-continuous-platform-soak-05/`. The overhead view shows the wide continuous courtyard course; the street view shows uninterrupted paving at player scale.

## Limits and next action

This is a headed initial-location Citadel diagnostic with tutorial skipped, forced clear/day weather, and test-only survival god mode during the soak. It proves no artificial Citadel terrace/hole on the exercised platform and retirement paths, bounded resource behavior, ordinary player collision/input on the inspected route, autosave, and shutdown. It does not prove menu-to-tutorial-to-Citadel continuous journey, broad save/reload, NPC behavior/routing, or the complete maturity matrix. Those are G5.

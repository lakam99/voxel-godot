# Citadel arithmetic performance pass, 2026-09-09

Baseline 1298e34, codex/citadel-visuals-clean. No navigation changes.
BuildingBlueprint uses direct translation for exact-zero-rotation support boxes. ConstructionBoxAdmission evaluates the three cardinal SAT directions directly when both boxes are cardinal. Original validity, summation order, contact acceptance and near-contact reason guard remain.

Evidence under artifacts/citadel-runtime-integration:
- support-query-01: pinned candidate26 physical report and resulting snapshot byte-exact against baseline; 4.461276s baseline / 3.711220s candidate. Three checks pass.
- support-query-cache-01: 75 mutation/cache checks pass.
- support-query-cancellation-01: 465 cancellation checks pass.
- box-admission-02: 2001 synthetic baseline/candidate results byte-exact, including near-contact reason classification. The critic caught and corrected that classification before commit.
- box-lower-facade-01: 159 producer checks pass.
- candidate-recipe-27: production generation and independent physical gates pass. Total 162.696s versus candidate26 217.758s; source preparation 158.304s versus 212.550s. Full27 predates the reason-only correction; no acceptance boolean or geometry change in that correction.
- box-admission-contract-01 and box-admission-contract-baseline-01 both fail only actual_intrusion_rejected_atomically. Exact1298e34 production arithmetic files reproduce it. This establishes a pre-existing fixture failure, not that the assertion is necessarily obsolete. No test weakened.

Completed runs proved owned process zero. These are source/contract measurements, not 90-second arrival or headed gameplay acceptance. No full headed rerun yet.

Reproduce baseline artifacts for differential scripts by exporting git1298e34 scripts/buildings/BuildingBlueprint.gd and ConstructionBoxAdmission.gd into artifacts/citadel-runtime-integration/support-query-baseline/. Remove only the BuildingBlueprint class_name declaration from that private copy to avoid a global class conflict. The support differential also requires the pinned candidate26/source.bin. Invoke each using node tools/run-building-contract.mjs, -Contract BuildingSupportQueryDifferential.gd / ConstructionBoxAdmissionDifferential.gd, -ReportEnvironment SUPPORT_QUERY_REPORT / BOX_ADMISSION_REPORT, -TimeoutSeconds 60 and a fresh -OutputDirectory.

The dominant remaining source interval is physical_resolve_support (~60.137s). Next: remove repeated immutable façade-input work without changing later-candidate obstacle visibility or validation semantics. The goal remains <=90 seconds to usable arrival, not merely source completion.


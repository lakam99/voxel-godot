import path from 'node:path';
import fs from 'node:fs';
import { cli, options, context, prepare, launchRecord, phaseRun, read, write, sha, demand, stable, integer } from './lib/building-runner.mjs';

function losslessReport(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''), (key, value, source) => {
    if (typeof value === 'number' && Number.isInteger(value) && !Number.isSafeInteger(value)) {
      demand(typeof source?.source === 'string', 'Lossless 64-bit RNG comparison requires JSON source access.');
      return source.source;
    }
    return value;
  });
}

function deterministicEvidence(report) {
  const details = name => {
    const row = report.checks?.find(value => value.name === name);
    demand(row?.passed === true && row.details, `Missing passing baseline evidence: ${name}`);
    return row.details;
  };
  const publicResult = details('public_widening_matches_full_pass_sources_and_actors');
  const result = {
    seed: report.seed,
    sourceChunkKey: details('naturally_generated_chunk_has_static_and_actor_outputs').sourceChunkKey,
    sourceManifest: details('canonical_static_source_manifest_matches_across_budgets'),
    actorManifest: details('wildlife_actor_intent_manifest_matches_across_budgets'),
    finalRngStates: details('all_producer_rng_streams_match_after_complete_pass'),
    publicRowsDigest: publicResult.actualRowsDigest,
    publicSourceRevision: publicResult.differential?.actualSourceRevision,
    publicFamilyDigest: publicResult.differential?.actualFamilyCoverageDigest,
    publicSnapshotRevision: publicResult.differential?.actualProducerSnapshotRevision,
    publicActorDigest: publicResult.differential?.actualActorIntentDigest,
    publicRowCount: publicResult.differential?.actualRowCount
  };
  demand(Object.values(result).every(value => value !== undefined), 'Baseline comparison evidence is incomplete.');
  return result;
}

cli(async () => {
  const o = options(process.argv.slice(2), {
    outputdirectory: '', godotexe: '', projectpath: '',
    seed: 'ecology-source-pass-slicing-parity-v1', timeoutseconds: '600', baselinereport: ''
  });
  const timeoutSeconds = integer(o.timeoutseconds, 60, 900, 'TimeoutSeconds');
  const c = context(o, 'ecology-source-pass-slicing-parity-');
  const baselinePath = o.baselinereport ? path.resolve(c.project, o.baselinereport) : '';
  const baseline = baselinePath ? losslessReport(baselinePath) : null;
  const baselineSha256 = baselinePath ? sha(baselinePath) : '';
  if (baseline) demand(baseline.passed === true && baseline.seed === o.seed,
    'Baseline must be a passing source-parity report for this exact seed.');
  prepare(c, 'userdata', true);
  const reportPath = path.join(c.run, 'report.json');
  const progressPath = path.join(c.run, 'progress.json');
  const sourceSha256 = launchRecord(c, [
    'scenes/Main.tscn',
    'scripts/Main.gd', 'scripts/MainPropFactory.gd', 'scripts/MainChunkTerrain.gd',
    'scripts/MainInteractionFlow.gd', 'scripts/MainPlaytestTools.gd',
    'scripts/MainRuntimeTools.gd', 'scripts/MainDiscoveryFlow.gd',
    'scripts/MainHudFlow.gd', 'scripts/MainWorldEntities.gd',
    'scripts/MainCharacterState.gd', 'scripts/MainGameLoop.gd',
    'scripts/MainSetupScene.gd', 'scripts/MainSaveState.gd',
    'scripts/MainCore.gd', 'scripts/MainInterface.gd',
    'scripts/WorldGenerationSystem.gd', 'scripts/StructureSystem.gd',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/EcologyProducerCatalogContext.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologyWorldSupportIndex.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'scripts/world/ActiveRemovedPropsSnapshot.gd',
    'scripts/world/EcologyDetailSourceValueBuilder.gd',
    'scripts/environment/TreeEcologySampler.gd',
    'scripts/environment/TreeRuntimeRequestBuilder.gd',
    'scripts/environment/TreeRequestAdmission.gd',
    'scripts/environment/RockRecipeBuilder.gd',
    'scripts/environment/BiomeEnvironmentCatalog.gd',
    'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd',
    'scripts/environment/TreePublicationQueue.gd',
    'scripts/visual/VisualAssetRegistry.gd',
    'scripts/visual/AnimatedAssetRegistry.gd',
    'scripts/testing/world/EcologySourcePassSlicingParity.gd',
    'scripts/testing/world/EcologySourcePassSlicingParity.gd.uid',
    'tools/run-ecology-source-pass-slicing-parity.mjs',
    'tools/lib/building-runner.mjs', 'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'ecology-source-pass-slicing-parity-launch/v1',
    evidenceLevel: 'real_main_production_source_pass_service_parity',
    seed: o.seed, gameplayStartup: false,
    headed: true, renderingMethod: 'gl_compatibility',
    baselineReport: baselinePath || null, baselineReportSha256: baselineSha256 || null,
    comparedBudgets: [{ surfaceAttempts: 1, detailAttempts: 1 },
      { surfaceAttempts: 8, detailAttempts: 8 }],
    timeBudgetMs: -1,
    timeoutSeconds,
    acceptance: 'Require naturally generated static render members and wildlife actor intents; compare sealed manifests and all producer RNG streams. Widen a real public tree-only capture to all families with distinct leases and prove the shared surface pass is retained.'
  });
  await phaseRun(c, {
    args: ['--audio-driver', 'Dummy', '--rendering-method', 'gl_compatibility',
      '--script', 'res://scripts/testing/world/EcologySourcePassSlicingParity.gd'],
    env: {
      ECOLOGY_SOURCE_PASS_PARITY_SEED: o.seed,
      ECOLOGY_SOURCE_PASS_PARITY_REPORT: reportPath,
      ECOLOGY_SOURCE_PASS_PARITY_PROGRESS: progressPath
    },
    timeout: timeoutSeconds,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  const report = read(reportPath);
  demand(report.schema === 'ecology-source-pass-slicing-parity/v1',
    'Ecology source-pass parity fixture did not produce the expected report.');
  demand(report.passed === true,
    `Ecology source-pass parity fixture failed: ${report.reason || 'see report'}`);
  const check = name => report.checks.find(row => row.name === name);
  for (const name of [
    'real_main_generation_catalog_and_structure_authorities_initialized',
    'real_catalog_publications_admitted',
    'production_town_region_inputs_finalized_before_admission',
    'naturally_generated_chunk_has_static_and_actor_outputs',
    'one_attempt_budget_pass_completed',
    'eight_attempt_budget_pass_completed',
    'canonical_static_source_manifest_matches_across_budgets',
    'wildlife_actor_intent_manifest_matches_across_budgets',
    'all_producer_rng_streams_match_after_complete_pass',
    'family_requests_have_independent_live_leases',
    'tree_only_public_capture_completes',
    'retained_surface_session_proves_nonempty_tree_currentness',
    'synthetic_invalid_tree_record_is_not_accepted_as_queued_work',
    'generated_tree_publication_admitted_by_actual_queue',
    'generated_tree_publication_compiles_through_actual_queue',
    'authoritative_empty_queue_output_is_sealed_and_current',
    'generated_nonzero_chunk_tree_support_validates_against_index',
    'actual_queue_admission_release_preserves_capture_publication',
    'tree_only_capture_defers_details_without_empty_success',
    'widened_public_capture_completes',
    'widening_preserves_original_sealed_tree_bundle',
    'widening_reuses_surface_rng_without_resampling',
    'public_widening_matches_full_pass_sources_and_actors',
    'public_family_bundle_has_unique_source_member_pairs',
    'public_duplicate_admission_retains_exact_view_after_caller_lease_release',
    'catalog_capture_scope_closed'
  ]) demand(check(name)?.passed === true, `Required source-pass parity assertion failed: ${name}`);
  let baselineComparisonPath = null;
  if (baseline) {
    demand(sha(baselinePath) === baselineSha256, 'Baseline report changed during verification.');
    const expected = deterministicEvidence(baseline);
    const actual = deterministicEvidence(losslessReport(reportPath));
    const differences = Object.keys(expected).filter(key => JSON.stringify(expected[key]) !== JSON.stringify(actual[key]));
    baselineComparisonPath = path.join(c.run, 'baseline-comparison.json');
    write(baselineComparisonPath, { schema: 'ecology-source-parity-baseline-comparison/v1',
      passed: differences.length === 0, baselinePath, baselineSha256,
      currentReportPath: reportPath, differences, expected, actual });
    demand(differences.length === 0, `Deterministic source output changed from baseline: ${differences.join(', ')}`);
  }
  return { reportPath, progressPath, seed: report.seed, reason: report.reason,
    baselineComparisonPath,
    checkCount: report.checkCount, elapsedUsec: report.elapsedUsec,
    evidenceLevel: report.evidenceLevel, gameplayAcceptance: false,
    doesNotProve: report.doesNotProve };
});

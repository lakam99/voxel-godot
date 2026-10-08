import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '', compileonly: false, handoffonly: false, uncommittedtreeonly: false });
  const compileOnly = o.compileonly === true || String(o.compileonly).toLowerCase() === 'true';
  const handoffOnly = o.handoffonly === true || String(o.handoffonly).toLowerCase() === 'true';
  const uncommittedTreeOnly = o.uncommittedtreeonly === true || String(o.uncommittedtreeonly).toLowerCase() === 'true';
  const headedRun = !compileOnly && !uncommittedTreeOnly;
  const c = context(o, compileOnly
    ? 'ecology-section-value-adapter-compile-'
    : uncommittedTreeOnly ? 'ecology-uncommitted-tree-diagnostic-'
    : handoffOnly ? 'ecology-tree-handoff-diagnostic-'
    : 'ecology-section-value-adapter-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/EcologyProducerCatalogContext.gd',
    'scripts/world/EcologyWorldSupportIndex.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd.uid',
    'scripts/world/CompiledTreeSectionArtifact.gd',
    'scripts/world/CompiledTreeSectionArtifact.gd.uid',
    'scripts/world/EcologySectionValueAdapter.gd.uid',
    'scripts/world/EcologySourceValueLedger.gd',
    'scripts/world/TreeSectionValueAdapter.gd',
    'scripts/world/TreeSectionValueAdapter.gd.uid',
    'scripts/environment/TreePublicationQueue.gd',
    'scripts/environment/TreePublicationQueue.gd.uid',
    'scripts/world/OwnedValueArtifactRetirement.gd',
    'scripts/world/OwnedValueArtifactRetirement.gd.uid',
    'scripts/environment/TreeSpawnService.gd',
    'scripts/environment/TreeSpawnService.gd.uid',
    'scripts/testing/CertifiedTreeRequestFixture.gd',
    'scripts/testing/CertifiedTreeRequestFixture.gd.uid',
    'native/terrain_meshing/src/native_tree_geometry_dispatcher.cpp',
    'native/terrain_meshing/src/native_tree_geometry_dispatcher.h',
    'native/terrain_meshing/src/register_types.cpp',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/StaticSectionSourceRoster.gd.uid',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd.uid',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd.uid',
    'scripts/world/StaticGeometryOwnerCompletion.gd',
    'scripts/world/StaticGeometryOwnerCompletion.gd.uid',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd.uid',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd.uid',
    'scripts/buildings/BuildingSpatialDependencies.gd',
    'scripts/testing/world/EcologySectionValueAdapterContract.gd',
    'scripts/testing/world/EcologySectionValueAdapterContract.gd.uid',
    'tools/run-ecology-section-value-adapter-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  const sourceSha256 = launchRecord(c, files, {
    schema: 'ecology-section-value-adapter-launch/v1',
    evidenceLevel: uncommittedTreeOnly ? 'diagnostic_isolated_uncommitted_tree_queue_boundary'
      : handoffOnly ? 'diagnostic_renderer_backed_tree_compiler_to_candidate_contract'
      : 'renderer_backed_ecology_source_value_and_tree_compiler_to_candidate_contract',
    headed: headedRun,
    timeoutSeconds: compileOnly ? 240 : handoffOnly ? 90 : 150,
    doesNotProve: 'The focused synthetic contract proves a real tree queue/native compiler/index-overlay/adapter contribution/candidate handoff only; it does not prove installed renderer receipts, save/replay, headed gameplay, collision parity, or performance acceptance.'
  });
  await phaseRun(c, {
    args: compileOnly
      ? ['--headless', '--check-only', '--script', 'res://scripts/testing/world/EcologySectionValueAdapterContract.gd']
      : headedRun
        ? ['--script', 'res://scripts/testing/world/EcologySectionValueAdapterContract.gd']
        : ['--headless', '--script', 'res://scripts/testing/world/EcologySectionValueAdapterContract.gd'],
    env: {
      ECOLOGY_SECTION_VALUE_ADAPTER_REPORT: path.join(c.run, 'report.json'),
      ECOLOGY_SECTION_VALUE_ADAPTER_HANDOFF_ONLY: handoffOnly ? '1' : '',
      ECOLOGY_SECTION_VALUE_ADAPTER_UNCOMMITTED_TREE_ONLY: uncommittedTreeOnly ? '1' : ''
    },
    timeout: compileOnly ? 240 : handoffOnly ? 90 : 150,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  if (compileOnly) return { evidenceLevel: 'headless_check_only_target_script_parse_smoke', runPath: c.run };
  const report = read(path.join(c.run, 'report.json'));
  if (handoffOnly) return {
    reportPath: path.join(c.run, 'report.json'),
    diagnosticOnly: report.diagnosticOnly === true,
    diagnosticPassed: report.passed === true,
    realTreeBandHandoff: report.realTreeBandHandoff
  };
  if (uncommittedTreeOnly) return {
    reportPath: path.join(c.run, 'report.json'),
    diagnosticOnly: report.diagnosticOnly === true,
    diagnosticPassed: report.passed === true,
    uncommittedTree: report.uncommittedTree
  };
  demand(report.schema === 'ecology-section-value-adapter-contract/v1' && report.passed === true,
    'Ecology section value adapter contract failed.');
  const requiredContractChecks = [
    'missing_tree_and_static_prop_categories_keep_common_contribution_retryable',
    'certified_empty_source_closure_releases_its_active_cohort_slot',
    'source_preparation_scheduler_telemetry_is_bounded_and_identity_scoped',
    'blocked_retained_preparation_rotates_to_empty_sibling_without_polling_first',
    'terminal_retained_preparation_failure_is_surfaced_and_removed_from_scheduler',
    'terminal_tree_registration_failure_is_persisted_not_wrapped_as_pending',
    'retained_preparation_classifies_nested_terminal_and_stale_producer_outcomes',
    'first_tree_band_poll_terminal_failure_is_not_requeued_as_pending',
    'record_backpressure_tree_band_consumer_is_retained_and_queue_full_is_not',
    'terminal_tree_band_admission_detaches_attached_consumer_before_failure',
    'pending_terminal_tree_band_admission_is_classified_before_poll',
    'pending_terminal_family_projection_is_terminal_and_stale_family_result_is_classified',
    'same_authority_terminal_tree_band_failure_retains_reason_and_consumer',
    'stale_tree_band_poll_detaches_and_retries_with_original_reason',
    'detached_tree_band_consumer_is_readmitted_after_exact_detach',
    'malformed_existing_tree_band_poll_fails_closed',
    'partial_tree_band_source_admission_retains_and_cancels_each_exact_consumer',
    'cached_source_rows_are_scanned_in_bounded_batches_without_conversion_units',
    'retained_section_preparation_advances_real_family_units_within_budget',
    'retained_section_preparation_returns_accepted_census_after_service',
    'retained_prep_uses_admitted_source_views_and_rejects_stale_cached_census',
    'stale_shared_source_preparation_releases_and_readmits_current_capture',
    'real_tree_handoff_completed_with_nonempty_checks',
    'real_tree_handoff_gate_rejects_empty_checks'
  ];
  demand(report.checks && requiredContractChecks.every((name) => report.checks[name] === true),
    'A required retained source-preparation or handoff contract check is missing or failed.');
  const handoff = report.realTreeBandHandoff;
  const requiredHandoffChecks = [
    'real_source_capture_ready',
    'real_native_nonempty_band_artifact',
    'real_adapter_registered_index_overlay',
    'index_accepts_source_with_support_but_no_owned_geometry',
    'real_adapter_contribution_assembles_owner_candidate',
    'real_owner_buffers_are_typed_readonly_aliases_with_exact_membership',
    'source_band_revision_input_introspection_preflight',
    'legacy_body_unload_transfers_partial_compiler_values',
    'band_projection_resumes_source_admission_above_cache_capacity'
  ];
  demand(handoff && handoff.status === 'ready'
      && handoff.checks && Object.keys(handoff.checks).length > 0
      && requiredHandoffChecks.every((name) => handoff.checks[name] === true)
      && Object.values(handoff.checks).every((value) => value === true),
    'Real tree source-to-candidate handoff is missing, incomplete, or failed.');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checks: report.checks,
    surfaceDetailPartitionOutputs: report.surfaceDetailPartitionOutputs,
    evidence: report.evidence
  };
});

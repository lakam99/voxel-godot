import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'citadel-section-geometry-service-');
  prepare(c, 'userdata', false);
  const sourceHashes = launchRecord(c, [
    'scripts/buildings/BuildingPartPublisher.gd',
    'scripts/buildings/FurnishingPublisher.gd',
    'scripts/buildings/FurnishingVisualRecipe.gd',
    'scripts/buildings/FurnishingVisualRecipe.gd.uid',
    'scripts/buildings/FurnishingPart.gd',
    'scripts/buildings/FurnishingPlan.gd',
    'scripts/buildings/BuildingScenePublicationJob.gd',
    'scripts/buildings/BuildingSpatialDependencies.gd',
    'scripts/buildings/BuildingDoorSectionCapture.gd',
    'scripts/buildings/BuildingDoorSectionCapture.gd.uid',
    'scripts/buildings/BuildingDoorGeometry.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'native/terrain_meshing/build/world_backend/debug/build-manifest.json',
    'scripts/buildings/BuildingStaticBatchFlush.gd',
    'scripts/buildings/BuildingMeshBatchUpload.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingSourceRecordBinding.gd',
    'scripts/buildings/BuildingSourceRecordBinding.gd.uid',
    'scripts/world/CitadelPublicationPlan.gd',
    'scripts/world/StaticGeometryOwnerCompletion.gd',
    'scripts/world/StaticGeometryOwnerSectionSlice.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/testing/world/CitadelSectionGeometryServiceContract.gd',
    'scripts/world/CitadelPublicationService.gd',
    'scripts/world/CitadelLegacySectionVisualIndex.gd',
    'scripts/world/CitadelSectionGeometryAdapter.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'tools/visible-world/run-citadel-section-geometry-service-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'citadel-section-geometry-service-launch/v1',
    evidenceLevel: 'synthetic_admission_real_furnishing_producer_service_native_renderer_and_frame_callback',
    headed: true,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--script', 'res://scripts/testing/world/CitadelSectionGeometryServiceContract.gd'],
    env: { VOXEL_CITADEL_SECTION_SERVICE_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceHashes);
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, {
    schema: 'citadel-section-geometry-service-contract/v1',
    complete: true,
    passed: true
  });
  demand(report.checkCount >= 14, 'Citadel geometry service bridge coverage unexpectedly shrank');
  for (const name of ['legacy_visual_scoped_inventory_visits_only_sealed_source_roots',
    'legacy_visual_scoped_inventory_reopens_on_child_publication',
    'legacy_visual_scoped_inventory_fails_closed_on_untracked_root',
    'geometry_owner_completion_advances_with_bounded_partial_progress',
    'geometry_owner_completion_discards_progress_after_receipt_replacement']) {
    demand(report.checks?.some(row => row.name === name && row.passed === true),
      'Missing scoped legacy inventory proof: ' + name);
  }
  for (const kind of ['candle', 'hearth']) {
    for (const suffix of ['actual_furnishing_service_contribution', 'actual_scene_job_furnishing_owner',
      'legacy_retained_before_native_ack', 'service_rejects_stale_body_epoch_resource',
      'real_frame_callback_native_install', 'completion_authorizes_only_visual_retirement',
      'unloaded_scene_owner_rejects_old_receipt', 'replay_requires_new_body_capture',
      'replayed_source_installs_new_native_receipt',
      'capture_lease_preserves_owner_against_rebegin_clear', 'owned_compile_install_callbacks_drained']) {
      demand(report.checks?.some(row => row.name === kind + '_' + suffix && row.passed === true),
        'Missing real furnishing renderer proof: ' + kind + '/' + suffix);
    }
  }
  for (const name of ['attachment_transform_digest_repeat_is_deterministic',
    'attachment_transform_digest_binds_all_twelve_scalars',
    'attachment_transform_digest_rejects_all_nonfinite_scalars', 'compound_policy_rejects_anchor_under_legacy_policy',
    'compound_policy_rejects_missing_anchor', 'compound_policy_accepts_exact_anchor_contract',
    'compound_support_policy_rejects_anchor_under_legacy_policy',
    'compound_support_policy_rejects_missing_anchor', 'compound_support_policy_accepts_exact_anchor_contract']) {
    demand(report.checks?.some(row => row.name === name && row.passed === true), `Missing strict ownership proof: ${name}`);
  }
  for (const motion of ['swing', 'raise']) {
    for (const name of ['actual_batch_rejects_anchor_policy_mismatch', 'actual_segment_rejects_anchor_policy_mismatch',
      'refcounted_publisher_identity_preserved', 'provider_wrapper_initial_install', 'new_owner_replacement_awaits_frame',
      'previous_claim_provider_cannot_restore_overlap', 'previous_owner_exit_preserves_replacement_ack',
      'replacement_owner_loss_settles_before_recapture', 'replacement_loss_recaptures_through_provider',
      'binding_invalidation_provider_first_settles_exact_token', 'provider_first_cancellation_reentry_installs',
      'final_withdraw_provider_preserves_true_false_originals', 'restoration_receipt_is_not_new_source_authority',
      'previous_loss_direct_rollback_settles', 'previous_loss_coordinator_drain_settles']) {
      demand(report.checks?.some(row => row.name === `${motion}_${name}` && row.passed === true),
        `Missing real provider/wrapper lifetime proof: ${motion}/${name}`);
    }
  }
  return {
    reportPath: path.join(c.run, 'report.json'),
    checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel
  };
});

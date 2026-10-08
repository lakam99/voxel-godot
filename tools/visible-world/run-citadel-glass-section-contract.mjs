import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'citadel-glass-section-');
  prepare(c, 'userdata', false);
  const sourceHashes = launchRecord(c, [
    'scripts/world/StaticTranslucentMeshPreparation.gd',
    'scripts/world/StaticTranslucentMeshPreparation.gd.uid',
    'scripts/testing/world/CitadelSectionGeometryServiceContract.gd',
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
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingSourceRecordBinding.gd',
    'scripts/buildings/BuildingSourceRecordBinding.gd.uid',
    'scripts/world/CitadelPublicationPlan.gd',
    'scripts/world/StaticGeometryOwnerCompletion.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/testing/world/CitadelGlassSectionContract.gd',
    'scripts/world/CitadelPublicationService.gd',
    'scripts/world/CitadelSectionGeometryAdapter.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'tools/visible-world/run-citadel-glass-section-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'citadel-glass-section-launch/v1',
    evidenceLevel: 'synthetic_admission_real_furnishing_producer_service_native_renderer_and_frame_callback',
    headed: true,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--script', 'res://scripts/testing/world/CitadelGlassSectionContract.gd'],
    env: { VOXEL_CITADEL_SECTION_SERVICE_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceHashes);
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, {
    schema: 'citadel-glass-section-contract/v1',
    complete: true,
    passed: true
  });
  demand(report.checkCount >= 10, 'Citadel geometry service bridge coverage unexpectedly shrank');
  for (const name of ['actual_window_capture', 'glass_service_contribution', 'glass_candidate_assembled',
    'glass_descriptor_real_quad_coverage', 'glass_keeps_translucent_layer', 'glass_real_native_frame_install',
    'partial_owner_keeps_legacy_visible', 'neighbor_owner_contribution', 'neighbor_real_native_install',
    'stale_pov_rejected_before_upload', 'source_revision_independent_of_pov', 'owned_sessions_drained',
    'glass_complete_owner_ack_retires_legacy', 'malformed_glass_sort_rejected',
    'glass_cache_reuses_completed_same_pov_mesh', 'glass_resort_reuses_canonical_arrays',
    'glass_cache_clear_preserves_candidate_resources']) {
    demand(report.checks?.some(row => row.name === name && row.passed === true), `Missing glass proof: ${name}`);
  }
  return {
    reportPath: path.join(c.run, 'report.json'),
    checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel
  };
});

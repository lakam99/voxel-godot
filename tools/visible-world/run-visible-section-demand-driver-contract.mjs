import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' }, ['acksettlementonly']);
  const c = context(o, 'visible-section-demand-driver-');
  prepare(c, 'userdata', false);
  const sourceHashes = launchRecord(c, [
    'scripts/testing/world/VisibleSectionDemandDriverContract.gd',
    'scripts/MainRuntimeTools.gd',
    'scripts/MainDiscoveryFlow.gd',
    'scripts/MainHudFlow.gd',
    'scripts/MainWorldEntities.gd',
    'scripts/MainCharacterState.gd',
    'scripts/MainGameLoop.gd',
    'scripts/MainSetupScene.gd',
    'scripts/MainSaveState.gd',
    'scripts/MainCore.gd',
    'scripts/MainInterface.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/CitadelPublicationService.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/WorldGenerationSystem.gd',
    'scripts/TerrainVolumeService.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'native/terrain_meshing/src/native_section_compile_dispatcher.cpp',
    'native/terrain_meshing/src/native_section_compile_dispatcher.h',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'native/terrain_meshing/build/world_backend/debug/build-manifest.json',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'tools/visible-world/run-visible-section-demand-driver-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'visible-section-demand-driver-launch/v1',
    evidenceLevel: 'synthetic_native_section_demand_to_complete_candidate_admission',
    headed: true,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/VisibleSectionDemandDriverContract.gd', '--check-only'],
    timeout: 90,
    prefix: 'parse-',
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceHashes);
  await phaseRun(c, {
    // The embedded native presentation proof needs a real rendered frame.
    args: ['--script', 'res://scripts/testing/world/VisibleSectionDemandDriverContract.gd'],
    env: {
      VOXEL_VISIBLE_SECTION_DEMAND_REPORT: path.join(c.run, 'report.json'),
      ...(o.acksettlementonly ? { VOXEL_VISIBLE_SECTION_DEMAND_ACK_SETTLEMENT_ONLY: '1' } : {})
    },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceHashes);
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, {
    schema: 'visible-section-demand-driver-contract/v1',
    complete: true,
    passed: true
  });
  if (o.acksettlementonly) {
    demand(report.focus === 'ack_settlement' && report.checkCount === 1 &&
      report.checks?.[0]?.name === 'failed_and_malformed_provider_acknowledgements_remain_unsettled_until_retry_succeeds',
      'Focused provider acknowledgement settlement contract was not isolated');
  } else {
    demand(report.focus === 'full_contract' && report.checkCount >= 7,
      'Visible-section demand coverage unexpectedly shrank');
    for (const name of [
      'synthetic_stale_attached_replay_retains_snapshot_and_requests_authoritative_reassembly',
      'synthetic_stale_active_attachment_replay_cancels_before_reassembly',
      'synthetic_undemanded_attachment_reassembly_retains_marker_without_inventing_demand',
      'synthetic_geometry_only_attachment_boundary_aborts_before_install_and_requests_recapture',
      'synthetic_first_install_is_cancelled_before_receipt_or_callback_exists',
      'synthetic_failed_install_cancellation_retains_exact_owner_and_ignores_other_incarnation',
      'synthetic_failed_install_cancellation_can_retry_before_backend_destruction',
      'synthetic_owner_retirement_cancels_staged_replay_and_boundary_without_losing_retry',
      'synthetic_replay_and_boundary_cancellation_failures_retain_owners_until_retry',
      'synthetic_global_drain_cancels_all_pre_presentation_install_lanes'
    ]) {
      demand(report.checks.some(check => check.name === name && check.passed === true),
        `Missing or failing attachment replay scheduler contract: ${name}`);
    }
  }
  return {
    reportPath: path.join(c.run, 'report.json'),
    checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel
  };
});

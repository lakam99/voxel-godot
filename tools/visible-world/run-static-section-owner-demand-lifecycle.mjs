import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'static-section-owner-demand-lifecycle-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/world/StaticSectionOwnerDemandLifecycleFixture.gd',
    'scripts/Main.gd',
    'scripts/MainPropFactory.gd',
    'scripts/MainChunkTerrain.gd',
    'scripts/MainInteractionFlow.gd',
    'scripts/MainPlaytestTools.gd',
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
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'native/terrain_meshing/src/register_types.cpp',
    'native/terrain_meshing/src/register_types.h',
    'native/terrain_meshing/terrain_meshing_backend.gdextension.in',
    'project.godot',
    'tools/visible-world/run-static-section-owner-demand-lifecycle.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, {
    schema: 'static-section-owner-demand-lifecycle-launch/v1',
    evidenceLevel: 'isolated_main_owner_lifecycle_contract',
    headed: false,
    timeoutSeconds: 120,
    doesNotProve: 'Normal Main startup or world streaming, production provider/source parity, live visual/gameplay behavior, Stage 1 completion, or full Stage 2 exit.'
  });
  const reportPath = path.join(c.run, 'report.json');
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/StaticSectionOwnerDemandLifecycleFixture.gd'],
    env: { VOXEL_STATIC_SECTION_OWNER_DEMAND_REPORT: reportPath },
    timeout: 120,
    logPolicy: { emptyStderr: false }
  });
  const report = read(reportPath);
  demand(report.schema === 'static-section-owner-demand-lifecycle/v1' && report.passed === true,
    'Static section owner demand lifecycle contract failed.');
  demand(report.checks?.production_candidate_installs_with_current_native_receipt === true
    && report.checks?.main_demand_exit_invalidates_receipt_and_retains_candidate === true
    && report.checks?.ownerless_demand_exit_cancels_pending_owner_job_only === true
    && report.checks?.reentry_replays_candidate_to_fresh_native_owner_receipt === true
    && report.checks?.fixture_teardown_frees_Main_and_native_owner_nodes === true,
  'Owner lifecycle contract did not prove every required receipt and cancellation edge.');
  return { reportPath, checkCount: Object.keys(report.checks ?? {}).length,
    evidenceLevel: report.evidenceLevel, stageStatus: report.stageStatus,
    doesNotProve: report.doesNotProve };
});

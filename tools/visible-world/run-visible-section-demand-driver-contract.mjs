import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'visible-section-demand-driver-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
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
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'tools/visible-world/run-visible-section-demand-driver-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'visible-section-demand-driver-launch/v1',
    evidenceLevel: 'synthetic_native_section_demand_to_complete_candidate_admission',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/VisibleSectionDemandDriverContract.gd', '--check-only'],
    timeout: 90,
    prefix: 'parse-',
    logPolicy: { emptyStderr: false }
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/VisibleSectionDemandDriverContract.gd'],
    env: { VOXEL_VISIBLE_SECTION_DEMAND_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, {
    schema: 'visible-section-demand-driver-contract/v1',
    complete: true,
    passed: true
  });
  demand(report.checkCount >= 7, 'Visible-section demand coverage unexpectedly shrank');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel
  };
});

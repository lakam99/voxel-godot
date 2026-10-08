import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ecology-main-retirement-');
  prepare(c, 'userdata', true);
  const seed = 'ecology-main-retirement-stage5';
  const reportPath = path.join(c.run, 'report.json');
  const progressPath = path.join(c.run, 'progress.json');
  const beforePath = path.join(c.run, 'before.png');
  const afterPath = path.join(c.run, 'after.png');
  launchRecord(c, [
    'scenes/Main.tscn',
    'scripts/MainCore.gd',
    'scripts/MainPlaytestTools.gd',
    'scripts/MainPropFactory.gd',
    'scripts/world/GameLaunchOptions.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologySourceValueLedger.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scenes/testing/world/EcologyMainRetirementPlaytest.tscn',
    'scripts/testing/world/EcologyMainRetirementPlaytest.gd',
    'tools/visible-world/run-ecology-main-retirement.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h'
  ], {
    schema: 'ecology-main-visual-retirement-launch/v1',
    evidenceLevel: 'headed_Main_production_ecology_retirement_with_native_receipts',
    seed,
    tutorialLaunchOption: '-SkipTutorial',
    timeoutSeconds: 900,
    doesNotProve: 'Broad visual parity, gameplay harvest/save replay, collision response, unload/replay parity, traversal, performance, or full ecology cutover.'
  });
  await phaseRun(c, {
    args: ['--resolution', '1280x720',
      'res://scenes/testing/world/EcologyMainRetirementPlaytest.tscn', '--', '-SkipTutorial'],
    env: {
      VOXEL_PLAYTEST: '1',
      VOXEL_TEST_SEED: seed,
      VOXEL_ECOLOGY_MAIN_RETIREMENT_REPORT: reportPath,
      VOXEL_ECOLOGY_MAIN_RETIREMENT_PROGRESS: progressPath,
      VOXEL_ECOLOGY_MAIN_RETIREMENT_BEFORE: beforePath,
      VOXEL_ECOLOGY_MAIN_RETIREMENT_AFTER: afterPath
    },
    timeout: 900,
    logPolicy: { emptyStderr: false }
  });
  const report = read(reportPath);
  demand(report.schema === 'ecology-main-visual-retirement/v1'
    && report.passed === true && report.tutorialSkipped === true,
  'Headed Main ecology visual retirement proof failed.');
  demand(report.beforeScreenshot === beforePath && report.afterScreenshot === afterPath,
    'Main ecology retirement screenshots were not recorded in the run directory.');
  return {
    reportPath,
    beforePath,
    afterPath,
    checkCount: report.checkCount,
    seed: report.seed,
    worldId: report.worldId,
    evidenceLevel: report.evidenceLevel,
    doesNotProve: report.doesNotProve
  };
});

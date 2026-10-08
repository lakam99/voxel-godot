import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '', compileonly: false });
  const compileOnly = o.compileonly === true || String(o.compileonly).toLowerCase() === 'true';
  const c = context(o, compileOnly
    ? 'ordinary-structure-main-section-compile-'
    : 'ordinary-structure-main-section-replay-');
  prepare(c, 'userdata', true);
  const seed = 'ecology-main-retirement-stage5';
  const reportPath = path.join(c.run, 'report.json');
  const progressPath = path.join(c.run, 'progress.json');
  const beforePath = path.join(c.run, 'before.png');
  const savePath = path.join(c.run, 'test-save.bin');
  const files = [
    'scenes/Main.tscn',
    'scenes/testing/world/OrdinaryStructureMainSectionReplayPlaytest.tscn',
    'scripts/testing/world/OrdinaryStructureMainSectionReplayPlaytest.gd',
    'scripts/testing/world/OrdinaryStructureMainSectionReplayPlaytest.gd.uid',
    'scripts/testing/world/EcologyMainHarvestReplayPlaytest.gd',
    'scripts/testing/world/EcologyMainRetirementPlaytest.gd',
    'scripts/testing/player/LivePlaytestPlayerNavigator.gd',
    'scripts/testing/player/LivePlaytestPlayerRouteAuthorityV2.gd',
    'scripts/MainCore.gd', 'scripts/MainRuntimeTools.gd', 'scripts/MainSaveState.gd',
    'scripts/MainPropFactory.gd', 'scripts/MainInteractionFlow.gd',
    'scripts/MainPlaytestTools.gd', 'scripts/StructureSystem.gd', 'scripts/SaveSystem.gd',
    'scripts/world/OrdinaryStructureStaticSectionProvider.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologySourceValueLedger.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'tools/visible-world/run-ordinary-structure-main-section-replay.mjs',
    'tools/lib/building-runner.mjs', 'tools/run-godot-scene-watchdog.mjs'
  ];
  const sourceSha256 = launchRecord(c, files, {
    schema: 'ordinary-structure-main-section-replay-launch/v1',
    evidenceLevel: 'headed_main_initial_spawn_production_ordinary_candidate_owner_replay_save_reload',
    seed, tutorialLaunchOption: '-SkipTutorial', headed: true,
    timeoutSeconds: compileOnly ? 240 : 900, startupTimeoutSeconds: 180,
    startupNoProgressTimeoutSeconds: 90,
    sourceWaitSeconds: 120, receiptAndReplayWaitSeconds: 300,
    plannedStopConditions: [
      'stop on startup signal failure, startup no-progress or startup deadline',
      'stop if no live ordinary block source with recipe visuals and collision appears within 120 seconds from initial spawn',
      'stop if current receipt, unload/replay, gameplay tombstone, save, or staged reload fails its bounded gate',
      'runner watchdog owns the Godot process job; require authoritative zero-member cleanup'
    ],
    doesNotProve: 'Only a short seeded route is exercised; broad natural exploration is not. Owner unload/replay is controlled through Main retire/demand-sync hooks rather than natural streaming unload. No broad source census, other structure kinds/seeds, visual parity, runtime performance, or full migration acceptance.'
  });
  await phaseRun(c, {
    args: compileOnly ? ['--headless', '--check-only', '--script',
      'res://scripts/testing/world/OrdinaryStructureMainSectionReplayPlaytest.gd']
      : ['--resolution', '1280x720', 'res://scenes/testing/world/OrdinaryStructureMainSectionReplayPlaytest.tscn', '--', '-SkipTutorial'],
    env: {
      VOXEL_PLAYTEST: '1', VOXEL_TEST_SEED: seed,
      VOXEL_ORDINARY_MAIN_SECTION_REPLAY_REPORT: reportPath,
      VOXEL_ECOLOGY_MAIN_RETIREMENT_PROGRESS: progressPath,
      VOXEL_ECOLOGY_MAIN_RETIREMENT_BEFORE: beforePath,
      VOXEL_SAVE_PATH_OVERRIDE: savePath
    },
    timeout: compileOnly ? 240 : 900, logPolicy: { emptyStderr: false }
  });
  if (compileOnly) return { evidenceLevel: 'headless_check_only_target_script_parse_smoke', runPath: c.run };
  const report = read(reportPath);
  demand(report.schema === 'ordinary-structure-main-section-replay/v1'
    && report.passed === true && report.tutorialSkipped === true,
  'Headed ordinary structure Main section replay failed.');
  return { reportPath, progressPath, beforePath, savePath, checkCount: report.checkCount,
    seed: report.seed, worldId: report.worldId, source: report.source,
    evidenceLevel: report.evidenceLevel, doesNotProve: report.doesNotProve };
});

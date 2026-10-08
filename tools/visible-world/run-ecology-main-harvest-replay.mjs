import fs from 'node:fs';
import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ecology-main-harvest-replay-');
  prepare(c, 'userdata', true);
  const seed = 'ecology-main-retirement-stage5';
  const reportPath = path.join(c.run, 'report.json');
  const progressPath = path.join(c.run, 'progress.json');
  const beforePath = path.join(c.run, 'before-harvest.png');
  const harvestedPath = path.join(c.run, 'after-harvest.png');
  const afterPath = path.join(c.run, 'after-save-reload.png');
  const savePath = path.join(c.run, 'test-save.bin');
  const sourceSha256 = launchRecord(c, [
    'scenes/Main.tscn',
    'scenes/testing/world/EcologyMainHarvestReplayPlaytest.tscn',
    'scripts/testing/world/EcologyMainHarvestReplayPlaytest.gd',
    'scripts/testing/world/EcologyMainHarvestReplayPlaytest.gd.uid',
    'scripts/testing/world/EcologyMainRetirementPlaytest.gd',
    'scripts/MainCore.gd',
    'scripts/MainPlaytestTools.gd',
    'scripts/MainPropFactory.gd',
    'scripts/MainInteractionFlow.gd',
    'scripts/MainWorldEntities.gd',
    'scripts/MainSaveState.gd',
    'scripts/SaveSystem.gd',
    'scripts/world/GameLaunchOptions.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologySourceValueLedger.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'tools/visible-world/run-ecology-main-harvest-replay.mjs',
    'tools/visible-world/run-ecology-main-retirement.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'ecology-main-harvest-save-replay-launch/v1',
    evidenceLevel: 'headed_Main_public_gameplay_harvest_isolated_save_staged_reload_and_native_receipt',
    seed,
    tutorialLaunchOption: '-SkipTutorial',
    headed: true,
    timeoutSeconds: 1200,
    startupNoProgressTimeoutSeconds: 90,
    startupTimeoutSeconds: 180,
    plannedMilestones: [
      'main_scene_instantiated', 'waiting_for_main_startup',
      'main_startup_no_progress_timeout', 'main_startup_timeout', 'main_gameplay_ready',
      'waiting_for_visible_legacy_pair', 'preharvest_receipts_current',
      'real_gameplay_harvest_recorded', 'harvested_source_absence_receipts',
      'save_written_and_reopened', 'staged_reload_begin', 'staged_reload_completed',
      'replay_checks_complete', 'finished'
    ],
    doesNotProve: 'Broad visual parity or traversal, complete ecology-family census, all prop families/seeds, publisher retirement beyond the tested prop, or runtime performance.'
  });
  await phaseRun(c, {
    args: ['--resolution', '1280x720',
      'res://scenes/testing/world/EcologyMainHarvestReplayPlaytest.tscn', '--', '-SkipTutorial'],
    env: {
      VOXEL_PLAYTEST: '1',
      VOXEL_TEST_SEED: seed,
      VOXEL_ECOLOGY_HARVEST_REPLAY_REPORT: reportPath,
      VOXEL_ECOLOGY_HARVEST_REPLAY_PROGRESS: progressPath,
      VOXEL_ECOLOGY_HARVEST_REPLAY_BEFORE: beforePath,
      VOXEL_ECOLOGY_HARVEST_REPLAY_HARVESTED: harvestedPath,
      VOXEL_ECOLOGY_HARVEST_REPLAY_AFTER: afterPath,
      VOXEL_SAVE_PATH_OVERRIDE: savePath
    },
    timeout: 1200,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  const report = read(reportPath);
  demand(report.schema === 'ecology-main-harvest-save-replay/v1'
    && report.passed === true && report.tutorialSkipped === true,
  'Headed Main ecology harvest/save/replay draft failed.');
  for (const file of [beforePath, harvestedPath, afterPath]) {
    demand(fs.existsSync(file) && fs.statSync(file).size > 0,
      `Viewport frame missing or empty: ${file}`);
  }
  const runRoot = path.resolve(c.run);
  const persistedSavePath = path.resolve(report.savePath || '');
  demand(report.saveBasePath === savePath
    && path.dirname(persistedSavePath) === runRoot
    && path.basename(persistedSavePath).startsWith('test-save_slot_')
    && persistedSavePath.endsWith('.bin')
    && fs.existsSync(persistedSavePath),
  `Main save slot did not stay in the isolated run directory: ${report.savePath}`);
  return {
    reportPath, progressPath, beforePath, harvestedPath, afterPath,
    saveBasePath: savePath, persistedSavePath,
    checkCount: report.checkCount, seed: report.seed, worldId: report.worldId,
    sourceId: report.sourceId, propId: report.propId,
    controlSourceId: report.controlSourceId, controlPropId: report.controlPropId,
    evidenceLevel: report.evidenceLevel, doesNotProve: report.doesNotProve
  };
});

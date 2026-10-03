import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' }, ['headed']);
  const c = context(o, 'visible-world-readiness-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/VisibleWorldReadinessContractRunner.gd',
    'scripts/world/VisibleWorldReadiness.gd',
    'scripts/world/VoxelTerrainVisualManifest.gd',
    'scripts/world/ChunkPropVisualManifest.gd',
    'native/terrain_meshing/src/chunk_static_render_backend.h',
    'native/terrain_meshing/src/chunk_static_render_backend.cpp',
    'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
    'scripts/world/HorizonEcologySource.gd',
    'scripts/world/HorizonEcologyPropReceiptPublisher.gd',
    'scripts/world/GeneratedStructureVisualManifest.gd',
    'scripts/world/CitadelPublicationPlan.gd',
    'scripts/world/CitadelPublicationService.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/TerrainVolumeService.gd',
    'scripts/MainPlaytestTools.gd',
    'scripts/MainChunkTerrain.gd',
    'scripts/MainCore.gd',
    'scripts/MainSaveState.gd',
    'scripts/MainRuntimeTools.gd',
    'tools/run-visible-world-readiness-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, {
    schema: 'visible-world-readiness-launch/v1',
    evidenceLevel: 'synthetic_owner_receipt_contract',
    headed: o.headed,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--editor', '--import', '--quit'],
    prefix: 'import-',
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  await phaseRun(c, {
    args: [...(o.headed ? [] : ['--headless']), '--script', 'res://scripts/testing/VisibleWorldReadinessContractRunner.gd'],
    prefix: 'contract-',
    env: { VOXEL_VISIBLE_WORLD_READINESS_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'visible-world-readiness-contract/v1', complete: true, passed: true });
  demand(report.checkCount >= 20, 'visual readiness contract coverage unexpectedly shrank');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel, scope: report.scope };
});

import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' }, ['visible', 'setuponly']);
  const c = context(o, 'visible-world-surface-source-replay-');
  prepare(c, 'userdata', true);
  launchRecord(c, [
    'scripts/testing/VisibleWorldSurfaceSourceReplay.gd',
    'scripts/MainCore.gd',
    'scripts/MainRuntimeTools.gd',
    'scripts/MainPlaytestTools.gd',
    'scripts/world/ChunkPropVisualManifest.gd',
    'tools/visible-world/run-surface-source-replay.mjs',
    'tools/lib/building-runner.mjs'
  ], { schema: 'visible-world-surface-source-replay-launch/v1', seed: 'atlas-1492',
    evidenceLevel: o.visible ? 'live_visible_source_observation' : 'live_headless_failure_observation',
    headed: Boolean(o.visible),
    stopConditions: 'startup and source manifests complete, startup failure, 35-second no-completion window after the view source set appears, or 270 seconds',
    timeoutSeconds: 350 });
  await phaseRun(c, {
    args: [...(o.visible ? [] : ['--headless']), '--script', 'res://scripts/testing/VisibleWorldSurfaceSourceReplay.gd'],
    env: { VOXEL_VISIBLE_SURFACE_REPLAY_REPORT: path.join(c.run, 'report.json'),
      VOXEL_VISIBLE_SOURCE_REPLAY_HEADED: o.visible ? '1' : '0',
      VOXEL_VISIBLE_SOURCE_REPLAY_SETUP_ONLY: o.setuponly ? '1' : '0' },
    timeout: 350, membership: true, logPolicy: { emptyStderr: false }
  });
  const reportPath = path.join(c.run, 'report.json');
  const report = read(reportPath);
  if (o.setuponly) {
    demand(report.schema === 'visible-world-surface-source-replay-setup/v1' &&
      report.reason === 'ready' && report.nativeCaveClass === true &&
      report.voxelTerrainClass === true, 'Surface source replay setup failed');
    return { reportPath, setup: report.reason };
  }
  demand(report.schema === 'visible-world-surface-source-replay/v1' &&
    report.seed === 'atlas-1492' && Array.isArray(report.samples) &&
    report.samples.length > 0, 'Surface source replay report missing');
  return { reportPath, stopReason: report.stopReason,
    viewSourcesComplete: report.viewSourcesComplete,
    viewChunkCount: report.viewChunkCount };
});

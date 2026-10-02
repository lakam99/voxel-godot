import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'visible-world-terrain-cadence-');
  prepare(c, 'userdata', true);
  launchRecord(c, [
    'scripts/testing/VisibleWorldTerrainCadenceProbe.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/MainCore.gd',
    'tools/visible-world/run-terrain-cadence.mjs',
    'tools/lib/building-runner.mjs'
  ], { schema: 'visible-world-terrain-cadence-launch/v1', seed: 'atlas-1492',
    evidenceLevel: 'live_headed_diagnostic',
    question: 'At cold startup, is final-view delay caused by native worker backlog, secondary-viewer admission, mesh upload or main-frame cadence?',
    stopConditions: 'startup complete, 25 seconds after final distance and two retained viewers, startup failure, or 235 seconds',
    timeoutSeconds: 260 });
  await phaseRun(c, {
    args: ['--script', 'res://scripts/testing/VisibleWorldTerrainCadenceProbe.gd'],
    env: { VOXEL_TERRAIN_CADENCE_REPORT: path.join(c.run, 'report.json') },
    timeout: 260, membership: true, logPolicy: { emptyStderr: false }
  });
  const reportPath = path.join(c.run, 'report.json');
  const report = read(reportPath);
  demand(report.schema === 'visible-world-terrain-cadence/v1' &&
    report.seed === 'atlas-1492' && Array.isArray(report.samples) &&
    report.samples.length > 0, 'Terrain cadence report missing');
  return { reportPath, stopReason: report.stopReason,
    elapsedSeconds: report.elapsedSeconds, samples: report.samples.length };
});

import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'visible-world-chunk-priority-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/VisibleWorldChunkPriorityContract.gd',
    'scripts/testing/VisibleWorldPropSourceSnapshotContract.gd',
    'scripts/testing/VisibleWorldPropSourceSnapshot.gd',
    'scripts/world/ChunkPropSpawnPriority.gd',
    'scripts/MainCore.gd',
    'scripts/MainRuntimeTools.gd',
    'scripts/MainPlaytestTools.gd',
    'tools/visible-world/run-chunk-priority-contract.mjs',
    'tools/lib/building-runner.mjs'
  ], { schema: 'visible-world-chunk-priority-launch/v1',
    evidenceLevel: 'synthetic_scheduler_contract', headed: false, timeoutSeconds: 90 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/VisibleWorldChunkPriorityContract.gd'],
    env: { VOXEL_VISIBLE_CHUNK_PRIORITY_REPORT: path.join(c.run, 'report.json') },
    timeout: 90, membership: true, logPolicy: { emptyStderr: false }
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/VisibleWorldPropSourceSnapshotContract.gd'],
    env: {},
    timeout: 90, membership: true, prefix: 'snapshot-', summaryName: 'snapshot-watchdog.json',
    logPolicy: { emptyStderr: false }
  });
  const reportPath = path.join(c.run, 'report.json');
  const report = read(reportPath);
  assertReport(report, { schema: 'visible-world-chunk-priority-contract/v1', passed: true });
  demand(report.checkCount >= 14, 'Priority contract coverage unexpectedly shrank');
  return { reportPath, checkCount: report.checkCount, chosen: report.chosen,
    undergroundProgressSnapshotContract: 'passed' };
});

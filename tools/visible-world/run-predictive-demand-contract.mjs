import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'visible-world-predictive-demand-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/VisibleWorldPredictiveDemandContract.gd',
    'scripts/world/VisibleWorldDemandController.gd',
    'scripts/world/VisibleWorldReadiness.gd',
    'scripts/world/VoxelTerrainVisualManifest.gd',
    'scripts/world/GeneratedStructureVisualManifest.gd',
    'scripts/world/GeneratedContentViewPriority.gd',
    'tools/visible-world/run-predictive-demand-contract.mjs',
    'tools/lib/building-runner.mjs'
  ], { schema: 'visible-world-predictive-demand-launch/v1',
    evidenceLevel: 'synthetic_controller_contract', headed: false, timeoutSeconds: 90 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/VisibleWorldPredictiveDemandContract.gd'],
    env: { VOXEL_VISIBLE_PREDICTIVE_DEMAND_REPORT: path.join(c.run, 'report.json') },
    timeout: 90, membership: true, logPolicy: { emptyStderr: false }
  });
  const reportPath = path.join(c.run, 'report.json');
  const report = read(reportPath);
  assertReport(report, { schema: 'visible-world-predictive-demand-contract/v1', passed: true });
  demand(report.checkCount >= 9, 'Predictive demand coverage unexpectedly shrank');
  return { reportPath, checkCount: report.checkCount, evidenceLevel: report.evidenceLevel };
});

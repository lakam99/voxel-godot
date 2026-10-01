import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'visible-world-readiness-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/VisibleWorldReadinessContractRunner.gd',
    'scripts/world/VisibleWorldReadiness.gd',
    'tools/run-visible-world-readiness-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, {
    schema: 'visible-world-readiness-launch/v1',
    evidenceLevel: 'synthetic_owner_receipt_contract',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/VisibleWorldReadinessContractRunner.gd'],
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

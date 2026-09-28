import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'regional-navigation-sparse-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/buildings/RegionalNavigationSparseContract.gd',
    'scripts/world/RegionalNavigationPublication.gd',
    'tools/run-regional-navigation-sparse-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'regional-navigation-sparse-launch/v1',
    evidenceLevel: 'synthetic_retention_and_receipt_policy_contract',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/RegionalNavigationSparseContract.gd'],
    env: { REGIONAL_NAVIGATION_SPARSE_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'regional-navigation-sparse-contract/v1', complete: true, passed: true });
  demand(report.checks?.accepted_foreground_eventually_acknowledged_with_competing_expensive_sources === true,
    'retained accepted foreground debt did not reach acknowledgement');
  demand(report.checks?.borrowed_completion_cannot_acknowledge_physical_mutation === true,
    'borrowed completion bypassed final physical validation');
  return { reportPath: path.join(c.run, 'report.json'), checks: report.checks, doesNotProve: report.doesNotProve };
});

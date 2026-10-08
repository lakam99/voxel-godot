import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'geometry-owner-completion-scheduler-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/world/GeometryOwnerCompletionSchedulerContract.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/StaticGeometryOwnerCompletion.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'tools/visible-world/run-geometry-owner-completion-scheduler-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'geometry-owner-completion-scheduler-launch/v1',
    evidenceLevel: 'synthetic_coordinator_scheduler_and_native_receipt_identity',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/GeometryOwnerCompletionSchedulerContract.gd'],
    env: { GEOMETRY_OWNER_COMPLETION_SCHEDULER_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, {
    schema: 'geometry-owner-completion-scheduler-contract/v1',
    complete: true,
    passed: true
  });
  demand(report.checkCount >= 4, 'Geometry owner completion scheduler coverage unexpectedly shrank');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel
  };
});

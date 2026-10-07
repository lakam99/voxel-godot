import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'static-geometry-owner-completion-');
  prepare(c, 'userdata', false);
  const hashes = launchRecord(c, [
    'scripts/testing/world/StaticGeometryOwnerCompletionContract.gd',
    'scripts/world/StaticGeometryOwnerCompletion.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'tools/visible-world/run-static-geometry-owner-completion-contract.mjs',
    'tools/lib/building-runner.mjs', 'tools/run-godot-scene-watchdog.mjs'
  ], { schema: 'static-geometry-owner-completion-launch/v1',
    evidenceLevel: 'synthetic_value_contract', headed: false, timeoutSeconds: 45 });
  const reportPath = path.join(c.run, 'report.json');
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/StaticGeometryOwnerCompletionContract.gd'],
    env: { STATIC_GEOMETRY_OWNER_COMPLETION_REPORT: reportPath },
    timeout: 45, logPolicy: { emptyStderr: false }
  });
  stable(c.project, hashes);
  const report = read(reportPath);
  demand(report.schema === 'static-geometry-owner-completion-contract/v1'
    && report.evidence === 'synthetic_value_contract' && report.passed === true
    && Object.keys(report.checks ?? {}).length >= 40
    && Object.values(report.checks).every(value => value === true),
  'Complete geometry-owner member contract failed.');
  return { reportPath, checkCount: Object.keys(report.checks).length, doesNotProve: report.doesNotProve };
});

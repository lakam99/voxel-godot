import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'static-geometry-owner-section-slice-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/world/StaticGeometryOwnerCompletion.gd',
    'scripts/world/StaticGeometryOwnerSectionSlice.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/testing/world/StaticGeometryOwnerSectionSliceContract.gd',
    'tools/visible-world/run-static-geometry-owner-section-slice-contract.mjs',
    'tools/lib/building-runner.mjs',
    ...['tools/run-godot-scene-watchdog.mjs', 'tools/lib/owned-process.mjs',
      'tools/lib/owned-native-host.mjs', 'tools/lib/owned-live-clock.mjs',
      'tools/native/OwnedProcessHost.cs', 'tools/native/OwnedProcessNative.cs']
  ];
  const sourceHashes = launchRecord(c, files, {
    schema: 'static-geometry-owner-section-slice-contract-launch/v1',
    evidenceLevel: 'synthetic_value_contract', headed: false, timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/StaticGeometryOwnerSectionSliceContract.gd'],
    env: { STATIC_GEOMETRY_OWNER_SECTION_SLICE_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceHashes);
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, {
    schema: 'static-geometry-owner-section-slice-contract/v1',
    evidence: 'synthetic_value_contract', passed: true
  });
  demand(report.checkCount >= 12 && Object.values(report.checks ?? {}).every(value => value === true),
    'Section slice contract did not pass every value assertion');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    checks: report.checks, doesNotProve: report.doesNotProve };
});

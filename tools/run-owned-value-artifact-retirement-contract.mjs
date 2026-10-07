import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'owned-value-artifact-retirement-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/world/OwnedValueArtifactRetirement.gd',
    'scripts/world/OwnedValueArtifactRetirement.gd.uid',
    'scripts/testing/world/OwnedValueArtifactRetirementContract.gd',
    'scripts/testing/world/OwnedValueArtifactRetirementContract.gd.uid',
    'tools/run-owned-value-artifact-retirement-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, {
    schema: 'owned-value-artifact-retirement-contract-launch/v1',
    evidenceLevel: 'synthetic_owned_value_retirement_thread_and_ack_contract',
    headed: false,
    timeoutSeconds: 45,
    doesNotProve: 'No production queue integration, live renderer install, gameplay, or performance acceptance.'
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/OwnedValueArtifactRetirementContract.gd'],
    env: { OWNED_VALUE_ARTIFACT_RETIREMENT_REPORT: path.join(c.run, 'report.json') },
    timeout: 45,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'owned-value-artifact-retirement-contract/v1' && report.passed === true,
    'Owned value artifact retirement contract failed.');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checkCount: report.checkCount,
    checks: report.checks,
    evidenceLevel: report.evidenceLevel
  };
});

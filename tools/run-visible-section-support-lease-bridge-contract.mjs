import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'visible-section-support-lease-bridge-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/world/VisibleSectionSupportLeaseBridge.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/testing/world/VisibleSectionSupportLeaseBridgeContract.gd',
    'tools/run-visible-section-support-lease-bridge-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, { schema: 'visible-section-support-lease-bridge-launch/v1',
    evidenceLevel: 'pure_per_section_support_lease_contract', headed: false, timeoutSeconds: 45,
    doesNotProve: 'No source-index producer completeness, native section installation, renderer visibility, or live gameplay acceptance.' });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/VisibleSectionSupportLeaseBridgeContract.gd'],
    env: { VISIBLE_SECTION_SUPPORT_LEASE_BRIDGE_REPORT: path.join(c.run, 'report.json') },
    timeout: 45,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'visible-section-support-lease-bridge-contract/v1' && report.passed === true,
    'Visible section support lease bridge contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checks: report.checks, evidence: report.evidence };
});

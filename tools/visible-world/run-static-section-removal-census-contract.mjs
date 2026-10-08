import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'static-section-removal-census-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/world/StaticSectionRemovalCensusContract.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'tools/visible-world/run-static-section-removal-census-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'static-section-removal-census-launch/v1',
    evidenceLevel: 'synthetic_source_roster_tombstone_contract',
    headed: false,
    timeoutSeconds: 90,
    doesNotProve: 'provider acknowledgement, coordinator/native installation, gameplay, persistence or performance.'
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/StaticSectionRemovalCensusContract.gd'],
    env: { VOXEL_STATIC_SECTION_REMOVAL_CENSUS_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, {
    schema: 'static-section-removal-census-contract/v1',
    complete: true,
    passed: true
  });
  demand(report.checkCount === 9, 'static removal census assertions did not all run');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel,
    doesNotProve: report.doesNotProve
  };
});

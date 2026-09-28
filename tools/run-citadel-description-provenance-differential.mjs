import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'description-provenance-differential-');
  prepare(c, 'userdata', false);
  launchRecord(c, ['scripts/testing/buildings/CitadelDescriptionProvenanceDifferential.gd',
    'scripts/buildings/BuildingSpatialDependencies.gd', 'scripts/buildings/BuildingPublicationSource.gd',
    'artifacts/citadel-runtime-integration/actual-site-source-05/result.bin'],
    { schema: 'citadel-description-provenance-differential-launch/v1', evidenceLevel: 'frozen_actual_source_differential', headed: false, timeoutSeconds: 120 });
  await phaseRun(c, { args: ['--headless', '--script', 'res://scripts/testing/buildings/CitadelDescriptionProvenanceDifferential.gd'],
    env: { CITADEL_DESCRIPTION_PROVENANCE_REPORT: path.join(c.run, 'report.json') }, timeout: 120, logPolicy: { emptyStderr: false } });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'citadel-description-provenance-differential/v1', complete: true, passed: true });
  return { reportPath: path.join(c.run, 'report.json'), aggregate: report.aggregate };
});

import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'generated-structure-bounded-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/GeneratedStructureVisualManifestBoundedContract.gd',
    'scripts/world/GeneratedStructureVisualManifest.gd',
    'scripts/world/OrdinaryStructureVisualSourceCapture.gd',
    'scripts/StructureSystem.gd',
    'tools/visible-world/run-generated-structure-bounded-contract.mjs',
    'tools/lib/building-runner.mjs'
  ], { schema: 'generated-structure-bounded-launch/v1',
    evidenceLevel: 'synthetic_producer_receipt_contract', headed: false, timeoutSeconds: 90 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/GeneratedStructureVisualManifestBoundedContract.gd'],
    env: { VOXEL_GENERATED_STRUCTURE_BOUNDED_REPORT: path.join(c.run, 'report.json') },
    timeout: 90, membership: true, logPolicy: { emptyStderr: false }
  });
  const reportPath = path.join(c.run, 'report.json');
  const report = read(reportPath);
  assertReport(report, { schema: 'generated-structure-bounded-contract/v1', passed: true });
  demand(report.checkCount >= 8, 'Bounded structure receipt coverage unexpectedly shrank');
  return { reportPath, checkCount: report.checkCount, evidenceLevel: 'synthetic_producer_receipt_contract' };
});

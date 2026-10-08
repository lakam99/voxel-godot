import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ecology-world-support-index-');
  prepare(c, 'userdata', false);
  const sourceSha256 = launchRecord(c, [
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/EcologyProducerCatalogContext.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologyWorldSupportIndex.gd',
    'scripts/testing/world/EcologySectionValueAdapterContract.gd',
    'scripts/testing/world/EcologyWorldSupportIndexContract.gd',
    'tools/visible-world/run-ecology-world-support-index-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'ecology-world-support-index-contract-launch/v1',
    evidenceLevel: 'synthetic_source_index_contract',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/EcologyWorldSupportIndexContract.gd'],
    env: { ECOLOGY_WORLD_SUPPORT_INDEX_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'ecology_world_support_index_contract/v1' && report.passed === true,
    'Ecology world support index contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});

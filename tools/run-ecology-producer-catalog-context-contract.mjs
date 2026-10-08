import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ecology-producer-catalog-context-');
  prepare(c, 'userdata', false);
  const sourceSha256 = launchRecord(c, [
    'scripts/world/EcologyProducerCatalogContext.gd',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'scripts/environment/BiomeEnvironmentCatalog.gd',
    'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd',
    'scripts/testing/world/EcologyProducerCatalogContextContract.gd',
    'tools/run-ecology-producer-catalog-context-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'ecology-producer-catalog-context-contract-launch/v1',
    evidenceLevel: 'synthetic_catalog_value_and_scope_lifecycle_contract',
    headed: false,
    timeoutSeconds: 45
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/EcologyProducerCatalogContextContract.gd'],
    env: { ECOLOGY_PRODUCER_CATALOG_CONTEXT_REPORT: path.join(c.run, 'report.json') },
    timeout: 45,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'ecology-producer-catalog-context-contract/v1' && report.passed === true,
    'Ecology producer catalog context contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});

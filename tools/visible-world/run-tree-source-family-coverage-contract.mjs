import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'tree-source-family-coverage-');
  prepare(c, 'userdata', false);
  const hashes = launchRecord(c, [
    'scripts/testing/world/TreeSourceFamilyCoverageContract.gd',
    'scripts/testing/world/TreeSourceFamilyCoverageContract.gd.uid',
    'scripts/testing/world/EcologySectionValueAdapterContract.gd',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/EcologyProducerCatalogContext.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'scripts/environment/TreePublicationQueue.gd',
    'scripts/environment/TreeSpawnService.gd',
    'scripts/MainPlaytestTools.gd',
    'tools/visible-world/run-tree-source-family-coverage-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], { schema: 'tree-source-family-coverage-launch/v1',
    evidenceLevel: 'synthetic_tree_family_admission_and_empty_currentness_contract',
    headed: false, timeoutSeconds: 90 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/TreeSourceFamilyCoverageContract.gd'],
    env: { VOXEL_TREE_SOURCE_FAMILY_REPORT: path.join(c.run, 'report.json') },
    timeout: 90, logPolicy: { emptyStderr: false }
  });
  stable(c.project, hashes);
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'tree-source-family-coverage-contract/v1' && report.passed === true,
    'Tree source family coverage contract failed.');
  demand(report.checks && Object.keys(report.checks).length >= 8, 'Tree family coverage unexpectedly shrank.');
  return { reportPath: path.join(c.run, 'report.json'), evidenceLevel: report.evidenceLevel,
    checkCount: Object.keys(report.checks).length };
});

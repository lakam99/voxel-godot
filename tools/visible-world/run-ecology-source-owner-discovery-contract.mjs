import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ecology-source-owner-discovery-contract-');
  prepare(c, 'userdata', false);
  const reportPath = path.join(c.run, 'report.json');
  const sourceHashes = launchRecord(c, [
    'scripts/testing/world/EcologySourceOwnerDiscoveryContract.gd',
    'scripts/testing/world/EcologySourceOwnerDiscoveryContract.gd.uid',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/testing/world/EcologySectionValueAdapterContract.gd',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/EcologyProducerCatalogContext.gd',
    'scripts/world/EcologyWorldSupportIndex.gd',
    'scripts/world/EcologySourceValueLedger.gd',
	'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
	'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd.uid',
    'scripts/world/StaticRenderSectionGrid.gd',
    'tools/visible-world/run-ecology-source-owner-discovery-contract.mjs',
    'tools/lib/building-runner.mjs'
  ], {
    schema: 'ecology-source-owner-discovery-contract-launch/v1',
    evidenceLevel: 'headless_production_provider_missing_and_complete_empty_discovery_contract',
    timeoutSeconds: 90,
    doesNotProve: 'Main startup, actual streaming, native install, gameplay, save/reload, or performance.'
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/EcologySourceOwnerDiscoveryContract.gd'],
    env: { ECOLOGY_SOURCE_OWNER_DISCOVERY_CONTRACT_REPORT: reportPath },
    timeout: 90, logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceHashes);
  const report = read(reportPath);
  demand(report.schema === 'ecology-source-owner-discovery-contract/v2'
    && report.passed === true && report.checkCount === 14,
  'Ecology source-owner discovery contract failed.');
  return { reportPath, checkCount: report.checkCount, evidenceLevel: report.evidenceLevel };
});

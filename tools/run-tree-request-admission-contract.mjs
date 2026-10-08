#!/usr/bin/env node
import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'tree-request-admission-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/buildings/CitadelUrbanPocComposer.gd',
    'scripts/environment/TreeRuntimeRequestBuilder.gd',
    'scripts/environment/BiomeEnvironmentCatalog.gd',
    'scripts/environment/BiomeEnvironmentProfile.gd',
    'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd',
    'resources/visual/biomes/town.tres',
    'scripts/environment/TreeRequestAdmission.gd',
    'scripts/environment/TreeRequestAdmission.gd.uid',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/EcologyProducerDomain.gd.uid',
    'scripts/testing/CertifiedTreeRequestFixture.gd',
    'scripts/testing/CertifiedTreeRequestFixture.gd.uid',
    'scripts/testing/TreeRequestAdmissionContract.gd',
    'scripts/testing/TreeRequestAdmissionContract.gd.uid',
    'tools/run-tree-request-admission-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, {
    schema: 'tree-request-admission-launch/v1',
    evidenceLevel: 'tree_request_certificate_tamper_and_stale_catalog_contract',
    headed: false,
    timeoutSeconds: 60,
    doesNotProve: 'No tree recipe geometry, publication latency, live world, visual acceptance, or performance result.'
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/TreeRequestAdmissionContract.gd'],
    env: { TREE_REQUEST_ADMISSION_REPORT: path.join(c.run, 'report.json') },
    timeout: 60,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'tree-request-admission-contract/v1' && report.passed === true,
    'Tree request admission contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checks: report.checks };
});

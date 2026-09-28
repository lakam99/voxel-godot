import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'actual-packet-tile-receipt-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/buildings/CitadelActualPacketTileReceiptContract.gd',
    'scripts/testing/buildings/CitadelPublicationServiceContract.gd',
    'scripts/world/CitadelPublicationService.gd',
    'scripts/buildings/BuildingScenePublicationJob.gd',
    'scripts/buildings/BuildingPublicationWorker.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingNavigationTileProducer.gd',
    'tools/run-citadel-actual-packet-tile-receipt-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs',
    'artifacts/citadel-runtime-integration/actual-site-source-05/result.bin'
  ];
  launchRecord(c, files, { schema: 'citadel-actual-packet-tile-receipt-launch/v1', evidenceLevel: 'actual_frozen_source_packet_physical_then_navigation_receipt', headed: false, timeoutSeconds: 150 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/CitadelActualPacketTileReceiptContract.gd'],
    env: { CITADEL_PACKET_TILE_RECEIPT_REPORT: path.join(c.run, 'report.json') }, timeout: 150,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'citadel-actual-packet-tile-receipt-contract/v1', complete: true, passed: true });
  demand(report.result?.ready === true && report.result?.navigation?.status === 'ready', 'actual tile packet receipt did not reach navigation source readiness');
  return { reportPath: path.join(c.run, 'report.json'), result: report.result, doesNotProve: report.doesNotProve };
});

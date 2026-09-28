import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'actual-packet-nonempty-navigation-ack-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/buildings/CitadelActualPacketNonemptyNavigationAcknowledgementContract.gd',
    'scripts/testing/buildings/CitadelActualPacketTileNavigationAcknowledgementContract.gd',
    'scripts/testing/buildings/CitadelPublicationServiceContract.gd',
    'scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd',
    'scripts/npc_ai/navigation/NavmeshWorldService.gd',
    'scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd',
    'scripts/world/CitadelPublicationService.gd',
    'scripts/buildings/BuildingScenePublicationJob.gd',
    'scripts/buildings/BuildingPublicationWorker.gd',
    'scripts/buildings/BuildingNavigationTileProducer.gd',
    'tools/run-citadel-actual-packet-nonempty-navigation-acknowledgement-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs',
    'artifacts/citadel-runtime-integration/actual-site-source-05/result.bin'
  ];
  launchRecord(c, files, { schema: 'citadel-actual-packet-nonempty-navigation-ack-launch/v1', evidenceLevel: 'actual_frozen_source_nonempty_packet_to_navigation_service_acknowledgement', headed: false, timeoutSeconds: 180 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/CitadelActualPacketNonemptyNavigationAcknowledgementContract.gd'],
    env: { CITADEL_PACKET_TILE_NAVIGATION_ACK_REPORT: path.join(c.run, 'report.json') }, timeout: 180,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'citadel-actual-packet-tile-navigation-acknowledgement-contract/v1', complete: true, passed: true });
  demand(report.result?.sourceReceipt?.tileKey === '199,-337' && report.result?.sourceReceipt?.groupIds?.length === 18, 'wrong nonempty packet closure');
  demand(report.result?.acknowledged === true && report.result?.queueDrained === true, 'nonempty packet tile did not acknowledge through coordinator queue');
  demand(Number(report.result?.iterations?.map) > 0 && Number(report.result?.iterations?.region) > 0, 'nonempty navigation map or region did not synchronize');
  return { reportPath: path.join(c.run, 'report.json'), result: report.result, doesNotProve: report.doesNotProve };
});

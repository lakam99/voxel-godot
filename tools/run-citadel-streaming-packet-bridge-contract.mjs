import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'streaming-packet-bridge-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/buildings/CitadelStreamingPacketBridgeContract.gd',
    'scripts/testing/buildings/CitadelPublicationServiceContract.gd',
    'scripts/MainCore.gd', 'scripts/world/WorldStreamingCoordinator.gd', 'scripts/StructureSystem.gd',
    'scripts/world/CitadelPublicationService.gd', 'scripts/buildings/BuildingScenePublicationJob.gd',
    'scripts/buildings/BuildingPublicationWorker.gd', 'scripts/buildings/BuildingNavigationTileProducer.gd',
    'tools/run-citadel-streaming-packet-bridge-contract.mjs', 'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs', 'artifacts/citadel-runtime-integration/actual-site-source-05/result.bin'
  ];
  launchRecord(c, files, { schema: 'citadel-streaming-packet-bridge-launch/v1', evidenceLevel: 'actual_frozen_source_world_streaming_to_maincore_packet_demand', headed: false, timeoutSeconds: 150 });
  await phaseRun(c, { args: ['--headless', '--script', 'res://scripts/testing/buildings/CitadelStreamingPacketBridgeContract.gd'],
    env: { CITADEL_STREAMING_PACKET_BRIDGE_REPORT: path.join(c.run, 'report.json') }, timeout: 150, logPolicy: { emptyStderr: false } });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'citadel-streaming-packet-bridge-contract/v1', complete: true, passed: true });
  demand(report.result?.expectedGroups?.length === 18 && report.result?.retainedRequest?.navigationTileKeys?.includes('199,-337'), 'streaming bridge omitted the target closure or tile');
  return { reportPath: path.join(c.run, 'report.json'), result: report.result, doesNotProve: report.doesNotProve };
});

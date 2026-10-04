import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'static-flush-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/buildings/BuildingStaticBatchFlushContract.gd',
    'scripts/buildings/BuildingStaticBatchFlush.gd',
    'scripts/buildings/BuildingPartPublisher.gd',
    'scripts/buildings/BuildingInstanceBuffer.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'tools/run-building-static-packet-replay-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, { schema: 'building-static-packet-replay-launch/v1', evidenceLevel: 'synthetic_chunk_unload_recreate_replay', headed: false, timeoutSeconds: 60 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/BuildingStaticBatchFlushContract.gd'],
    env: { BUILDING_STATIC_FLUSH_REPORT: path.join(c.run, 'report.json'), BUILDING_STATIC_FLUSH_REPLAY_ONLY: '1' },
    timeout: 60,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.evidence === 'synthetic_chunk_packet_replay_contract' && report.passed === true
    && report.checks?.static_packet_initial_receipt_installed === true
    && report.checks?.static_packet_replay_recipe_owns_frozen_segments === true
    && report.checks?.static_packet_replayed_after_chunk_recreation === true
    && report.checks?.static_packet_failed_release_retains_retry_receipt === true
    && report.checks?.static_packet_release_ack_clears_receipt_and_recipe === true,
  'Chunk packet replay contract did not establish unload/recreate installation.');
  return { reportPath: path.join(c.run, 'report.json'), checks: report.checks,
    doesNotProve: 'This synthetic fake-backend contract does not prove native renderer integration or live gameplay.' };
});

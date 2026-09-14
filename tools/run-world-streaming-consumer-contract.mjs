import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'world-streaming-consumer-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/buildings/WorldStreamingConsumerContract.gd',
    'scripts/world/WorldStreamingCoordinator.gd',
    'scripts/world/GeneratedContentViewPriority.gd',
    'scripts/world/RegionDemandSet.gd',
    'tools/run-world-streaming-consumer-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, {
    schema: 'world-streaming-consumer-launch/v1',
    evidenceLevel: 'synthetic_retained_consumer_contract',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/WorldStreamingConsumerContract.gd'],
    env: { WORLD_STREAMING_CONSUMER_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'world-streaming-consumer-contract/v1', complete: true, passed: true });
  demand(report.checks?.foreground_tiles_are_canonical_subset_of_retained_navigation === true,
    'foreground tiles were not retained as an exact subset');
  demand(report.checks?.foreground_only_replacement_reissues_exact_structure_tile_intent === true,
    'foreground tile replacement did not reach the structure manifest');
  return { reportPath: path.join(c.run, 'report.json'), checks: report.checks, doesNotProve: report.doesNotProve };
});

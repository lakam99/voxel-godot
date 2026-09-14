import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'initial-spawn-closure-audit-');
  prepare(c, 'userdata', false);
  const files = ['scripts/testing/buildings/CitadelInitialSpawnClosureAudit.gd', 'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingSpatialDependencies.gd', 'scripts/world/WorldStreamingCoordinator.gd', 'tools/run-citadel-initial-spawn-closure-audit.mjs',
    'tools/lib/building-runner.mjs', 'tools/run-godot-scene-watchdog.mjs', 'artifacts/citadel-runtime-integration/candidate-recipe-source-profile-32/source.bin'];
  launchRecord(c, files, { schema: 'citadel-initial-spawn-closure-audit-launch/v1', evidenceLevel: 'actual_frozen_source_compact_spawn_safety_tile_closure_audit', headed: false, timeoutSeconds: 150 });
  await phaseRun(c, { args: ['--headless', '--script', 'res://scripts/testing/buildings/CitadelInitialSpawnClosureAudit.gd'],
    env: { CITADEL_INITIAL_SPAWN_CLOSURE_AUDIT_REPORT: path.join(c.run, 'report.json') }, timeout: 150, logPolicy: { emptyStderr: false } });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'citadel-initial-spawn-closure-audit/v1', complete: true, passed: true });
  demand(Array.isArray(report.tiles) && report.tiles.length > 0 && report.summary?.uniqueClosureGroupCount > 0, 'Initial safety closure audit is empty.');
  return { reportPath: path.join(c.run, 'report.json'), summary: report.summary, spawnTileKey: report.spawnTileKey, doesNotProve: report.doesNotProve };
});

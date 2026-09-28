import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'actual-nonempty-tile-locator-');
  prepare(c, 'userdata', false);
  const files = ['scripts/testing/buildings/CitadelActualNonemptyTileLocator.gd', 'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingSpatialDependencies.gd', 'tools/run-citadel-actual-nonempty-tile-locator.mjs',
    'tools/lib/building-runner.mjs', 'tools/run-godot-scene-watchdog.mjs',
    'artifacts/citadel-runtime-integration/candidate-recipe-source-profile-32/source.bin'];
  launchRecord(c, files, { schema: 'citadel-actual-nonempty-tile-locator-launch/v1', evidenceLevel: 'offline_pinned_actual_source_closure_locator', headed: false, timeoutSeconds: 150 });
  await phaseRun(c, { args: ['--headless', '--script', 'res://scripts/testing/buildings/CitadelActualNonemptyTileLocator.gd'],
    env: { CITADEL_ACTUAL_NONEMPTY_TILE_LOCATOR_REPORT: path.join(c.run, 'report.json') }, timeout: 150, logPolicy: { emptyStderr: false } });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'citadel-actual-nonempty-tile-locator/v1', complete: true, passed: true });
  demand(report.selected?.sourceExterior === true && Array.isArray(report.selected?.groupIds) && report.selected.groupIds.length > 0, 'Locator did not select an exterior nonempty physical tile.');
  return { reportPath: path.join(c.run, 'report.json'), selected: report.selected, doesNotProve: 'No terrain admission at the selected exterior cell, scene publication, NavigationServer, runtime collision, startup, or headed gameplay.' };
});

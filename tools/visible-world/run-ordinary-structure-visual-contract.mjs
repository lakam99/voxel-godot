import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ordinary-structure-visual-source-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/OrdinaryStructureVisualSourceContract.gd',
    'scripts/StructureSystem.gd',
    'scripts/MainChunkTerrain.gd',
    'scripts/MainPropFactory.gd',
    'scripts/MainSaveState.gd',
    'tools/visible-world/run-ordinary-structure-visual-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'ordinary-structure-visual-source-launch/v1',
    evidenceLevel: 'synthetic_producer_receipt_contract',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/OrdinaryStructureVisualSourceContract.gd'],
    env: { VOXEL_ORDINARY_VISUAL_SOURCE_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'ordinary-structure-visual-source-contract/v1', complete: true, passed: true });
  demand(report.checkCount >= 10, 'ordinary structure visual source coverage unexpectedly shrank');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});

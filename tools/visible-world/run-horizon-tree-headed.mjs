import path from 'node:path';
import fs from 'node:fs';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'visible-world-horizon-tree-headed-');
  prepare(c, 'userdata', false);
  const reportPath = path.join(c.run, 'report.json');
  const captureDir = path.join(c.run, 'captures');
  fs.mkdirSync(captureDir);
  launchRecord(c, [
    'scripts/testing/VisibleWorldHorizonTreeHeaded.gd',
    'scripts/environment/TreePublicationQueue.gd',
    'scripts/environment/TreeSpawnService.gd',
    'scripts/world/HorizonEcologyTreeBatch.gd',
    'scripts/visual/ProceduralTreeVisualFactory.gd',
    'tools/visible-world/run-horizon-tree-headed.mjs',
    'tools/lib/building-runner.mjs'
  ], {
    schema: 'visible-world-horizon-tree-headed-launch/v1',
    evidenceLevel: 'headed_production_queue_fixture', headed: true,
    stopConditions: 'queued slot proof, cancellation, far recipe publication, near promotion, 90 seconds per recipe phase, engine diagnostic, or 205 seconds total',
    timeoutSeconds: 205
  });
  await phaseRun(c, {
    args: ['--resolution', '1280x720', '--script', 'res://scripts/testing/VisibleWorldHorizonTreeHeaded.gd'],
    env: { VOXEL_HORIZON_TREE_REPORT: reportPath, VOXEL_HORIZON_TREE_CAPTURES: captureDir },
    timeout: 205, membership: true, logPolicy: { emptyStderr: false }
  });
  const report = read(reportPath);
  demand(report.schema === 'visible-world-horizon-tree-headed/v1' && report.finished === true && report.passed === true,
    'Horizon tree headed fixture did not pass');
  demand(Array.isArray(report.captures) && report.captures.length >= 3 &&
    report.captures.every(capture => capture.saved === true && fs.existsSync(capture.path)),
    'Horizon tree screenshots are incomplete');
  return { reportPath, captureDir, checkCount: report.checks.length, captures: report.captures.length };
});

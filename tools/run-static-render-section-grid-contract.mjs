import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'static-render-section-grid-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd.uid',
    'scripts/buildings/BuildingSpatialDependencies.gd',
    'scripts/testing/buildings/StaticRenderSectionGridContract.gd',
    'tools/run-static-render-section-grid-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, { schema: 'static-render-section-grid-launch/v1',
    evidenceLevel: 'pure_spatial_contract', headed: false, timeoutSeconds: 45 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/StaticRenderSectionGridContract.gd'],
    env: { STATIC_RENDER_SECTION_GRID_REPORT: path.join(c.run, 'report.json') },
    timeout: 45,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'static-render-section-grid-contract/v1' && report.passed === true,
    'Static render section grid contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checks: report.checks, evidence: report.evidence };
});

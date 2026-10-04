import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'chunk-static-render-section-snapshot-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/testing/buildings/ChunkStaticRenderSectionSnapshotContract.gd',
    'tools/run-chunk-static-render-section-snapshot-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, { schema: 'chunk-static-render-section-snapshot-launch/v1',
    evidenceLevel: 'pure_immutable_section_snapshot_contract', headed: false, timeoutSeconds: 45,
    doesNotProve: 'No renderer/native integration, queue scheduling, or live gameplay acceptance.' });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/ChunkStaticRenderSectionSnapshotContract.gd'],
    env: { CHUNK_STATIC_RENDER_SECTION_SNAPSHOT_REPORT: path.join(c.run, 'report.json') },
    timeout: 45,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'chunk-static-render-section-snapshot-contract/v1' && report.passed === true,
    'Chunk static render section snapshot contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checks: report.checks, evidence: report.evidence };
});

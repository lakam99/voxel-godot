import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'prepared-static-section-snapshot-builder-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd.uid',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticRenderSectionGrid.gd.uid',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd.uid',
    'scripts/buildings/BuildingSpatialDependencies.gd',
    'scripts/testing/buildings/PreparedStaticSectionSnapshotBuilderContract.gd',
    'scripts/testing/buildings/PreparedStaticSectionSnapshotBuilderContract.gd.uid',
    'tools/run-prepared-static-section-snapshot-builder-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, {
    schema: 'prepared-static-section-snapshot-builder-launch/v1',
    evidenceLevel: 'pure_committed_section_snapshot_adapter_contract',
    headed: false,
    timeoutSeconds: 45,
    doesNotProve: 'No section renderer integration, upload/owner acknowledgement, native layer-specific publication, collision, queue scheduling, or live gameplay acceptance.'
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/PreparedStaticSectionSnapshotBuilderContract.gd'],
    env: { PREPARED_STATIC_SECTION_SNAPSHOT_BUILDER_REPORT: path.join(c.run, 'report.json') },
    timeout: 45,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'prepared-static-section-snapshot-builder-contract/v1' && report.passed === true,
    'Prepared static section snapshot builder contract failed.');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checks: report.checks,
    evidence: report.evidence
  };
});

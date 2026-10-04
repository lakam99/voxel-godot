import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'chunk-static-render-section-instance-partitioner-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd.uid',
    'scripts/buildings/BuildingSpatialDependencies.gd',
    'scripts/testing/buildings/ChunkStaticRenderSectionInstancePartitionerContract.gd',
    'tools/run-chunk-static-render-section-instance-partitioner-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, {
    schema: 'chunk-static-render-section-instance-partitioner-launch/v1',
    evidenceLevel: 'pure_building_instance_section_partition_contract',
    headed: false,
    timeoutSeconds: 45,
    doesNotProve: 'No snapshot integration, native renderer publication, collision, queue scheduling, performance, or live gameplay acceptance.'
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/ChunkStaticRenderSectionInstancePartitionerContract.gd'],
    env: { CHUNK_STATIC_RENDER_SECTION_INSTANCE_PARTITIONER_REPORT: path.join(c.run, 'report.json') },
    timeout: 45,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'chunk-static-render-section-instance-partitioner-contract/v1' && report.passed === true,
    'Chunk static render section instance partitioner contract failed.');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checks: report.checks,
    inputInstances: report.inputInstances,
    crossBoundaryCanonicalOutputInstances: report.crossBoundaryCanonicalOutputInstances,
    sourceRootsKeptSeparate: report.sourceRootsKeptSeparate,
    crossBoundaryStreamChunkDependencies: report.crossBoundaryStreamChunkDependencies,
    evidence: report.evidence
  };
});

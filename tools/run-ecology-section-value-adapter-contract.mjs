import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ecology-section-value-adapter-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologySourceValueLedger.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd.uid',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd.uid',
    'scripts/buildings/BuildingSpatialDependencies.gd',
    'scripts/testing/world/EcologySectionValueAdapterContract.gd',
    'tools/run-ecology-section-value-adapter-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, {
    schema: 'ecology-section-value-adapter-launch/v1',
    evidenceLevel: 'synthetic_ecology_source_value_partition_contract',
    headed: false,
    timeoutSeconds: 60,
    doesNotProve: 'No production provider registration, native section installation, complete ecology census, save/replay, headed gameplay, collision parity, or performance acceptance.'
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/EcologySectionValueAdapterContract.gd'],
    env: { ECOLOGY_SECTION_VALUE_ADAPTER_REPORT: path.join(c.run, 'report.json') },
    timeout: 60,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'ecology-section-value-adapter-contract/v1' && report.passed === true,
    'Ecology section value adapter contract failed.');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checks: report.checks,
    surfaceDetailPartitionOutputs: report.surfaceDetailPartitionOutputs,
    evidence: report.evidence
  };
});

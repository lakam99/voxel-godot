import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'citadel-section-geometry-adapter-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/world/CitadelSectionGeometryAdapterContract.gd',
    'scripts/world/CitadelSectionGeometryAdapter.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'tools/visible-world/run-citadel-section-geometry-adapter-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'citadel-section-geometry-adapter-launch/v1',
    evidenceLevel: 'synthetic_prepared_packet_to_shared_partition_contract',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/CitadelSectionGeometryAdapterContract.gd'],
    env: { VOXEL_CITADEL_SECTION_ADAPTER_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, {
    schema: 'citadel-section-geometry-adapter-contract/v1',
    complete: true,
    passed: true
  });
  demand(report.checkCount >= 8, 'Citadel section adapter coverage unexpectedly shrank');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel
  };
});

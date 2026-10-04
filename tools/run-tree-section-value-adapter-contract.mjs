import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'tree-section-value-adapter-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/world/TreeSectionValueAdapter.gd',
    'scripts/world/TreeSectionValueAdapter.gd.uid',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/ActiveRemovedPropsSnapshot.gd',
    'scripts/environment/TreePublicationQueue.gd',
    'scripts/environment/TreeSpawnService.gd',
    'scripts/visual/ProceduralTreeVisualFactory.gd',
    'scripts/testing/world/TreeSectionValueAdapterContract.gd',
    'tools/run-tree-section-value-adapter-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, {
    schema: 'tree-section-value-adapter-launch/v1',
    evidenceLevel: 'headed_synthetic_tree_queue_receipt_and_visual_resource_contract',
    headed: true,
    timeoutSeconds: 90,
    doesNotProve: 'No live TreePublicationQueue production run, registration, native section installation, full tree or ecology census, collision/render parity, save/replay, headed gameplay, or performance acceptance.'
  });
  await phaseRun(c, {
    args: ['--script', 'res://scripts/testing/world/TreeSectionValueAdapterContract.gd'],
    env: { TREE_SECTION_VALUE_ADAPTER_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'tree-section-value-adapter-contract/v1' && report.passed === true,
    'Tree section value adapter contract failed.');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checks: report.checks,
    partitionInstanceCount: report.partitionInstanceCount,
    sectionKeys: report.sectionKeys,
    batchCount: report.batchCount,
    evidence: report.evidence
  };
});

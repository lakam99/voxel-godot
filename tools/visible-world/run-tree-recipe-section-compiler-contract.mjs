import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'tree-recipe-section-compiler-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/world/TreeRecipeSectionCompilerContract.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'scripts/world/TreeSectionValueAdapter.gd',
    'scripts/environment/TreePublicationQueue.gd',
    'scripts/environment/TreeSpawnService.gd',
    'scripts/visual/ProceduralTreeVisualFactory.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/ActiveRemovedPropsSnapshot.gd',
    'tools/visible-world/run-tree-recipe-section-compiler-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'tree-recipe-section-compiler-launch/v1',
    evidenceLevel: 'headed_canonical_recipe_artifact_and_node_free_compiler_contract',
    headed: true,
    timeoutSeconds: 120
  });
  await phaseRun(c, {
    args: ['--audio-driver', 'Dummy', '--rendering-method', 'gl_compatibility', '--script', 'res://scripts/testing/world/TreeRecipeSectionCompilerContract.gd'],
    env: { TREE_RECIPE_SECTION_COMPILER_REPORT: path.join(c.run, 'report.json') },
    timeout: 120,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'tree-recipe-section-compiler-contract/v1', passed: true });
  demand(report.checks && Object.keys(report.checks).length >= 6, 'tree compiler contract coverage unexpectedly shrank');
  demand(report.status === 'ready' && report.batchCount >= 3, 'tree compiler emitted no complete render batches');
  return {
    reportPath: path.join(c.run, 'report.json'),
    sectionKeys: report.sectionKeys,
    batchCount: report.batchCount,
    workUnits: report.workUnits,
    singleUnitSteps: report.singleUnitSteps,
    largeUnitSteps: report.largeUnitSteps,
    evidenceLevel: report.evidenceLevel
  };
});

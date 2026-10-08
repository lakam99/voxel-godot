import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'tree-recipe-section-compiler-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/world/TreeRecipeSectionCompilerContract.gd',
    'scripts/testing/world/TreeRecipeSectionCompilerContract.gd.uid',
    'scripts/testing/CertifiedTreeRequestFixture.gd',
    'scripts/testing/CertifiedTreeRequestFixture.gd.uid',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'native/terrain_meshing/src/native_tree_geometry_dispatcher.h',
    'native/terrain_meshing/src/native_tree_geometry_dispatcher.cpp',
    'native/terrain_meshing/src/register_types.cpp',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/EcologyProducerDomain.gd.uid',
    'scripts/world/EcologyProducerCatalogContext.gd',
    'scripts/world/EcologyProducerCatalogContext.gd.uid',
    'scripts/world/TreeSectionValueAdapter.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologySectionValueAdapter.gd.uid',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/ActiveRemovedPropsSnapshot.gd',
    'scripts/world/EcologySourceValueLedger.gd',
    'scripts/environment/TreeRuntimeRequestBuilder.gd',
    'scripts/environment/BiomeEnvironmentCatalog.gd',
    'scripts/environment/BiomeEnvironmentCatalog.gd.uid',
    'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd',
    'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd.uid',
    'scripts/environment/TreeEcologySampler.gd',
    'scripts/environment/BiomeEnvironmentProfile.gd',
    'scripts/environment/BiomeEnvironmentProfile.gd.uid',
    'resources/visual/biomes/default.tres',
    'resources/visual/biomes/beach.tres',
    'resources/visual/biomes/desert.tres',
    'resources/visual/biomes/forest.tres',
    'resources/visual/biomes/alpine.tres',
    'resources/visual/biomes/plains.tres',
    'resources/visual/biomes/savanna.tres',
    'resources/visual/biomes/snow.tres',
    'resources/visual/biomes/swamp.tres',
    'resources/visual/biomes/taiga.tres',
    'resources/visual/biomes/town.tres',
    'resources/visual/biomes/tundra.tres',
    'resources/visual/biomes/ocean.tres',
    'resources/visual/biomes/forest.tres',
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
    evidenceLevel: 'headed_canonical_recipe_compiler_and_native_foliage_value_parity_and_lifecycle_contract',
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
  demand(report.checks.native_foliage_packed_values_match_factory_all_families_lods === true,
    'native foliage packed-value parity failed for one or more families/LODs');
  demand(report.checks.native_whole_record_branch_values_match_factory_and_echo_epochs === true,
    'native whole-record branch parity or source-epoch echo failed for one or more families/LODs');
  demand(report.checks.native_tree_worker_cancel_and_queue_capacity_are_bounded === true,
    'native tree worker cancellation or bounded admission failed');
  demand(report.checks.native_tree_section_pack_matches_transform_bounds_owner_and_support_reference === true,
    'native tree section pack differed from the independent transform/bounds/ownership reference');
  demand(report.checks.native_tree_section_pack_cancel_and_capacity_are_bounded === true,
    'native tree section pack cancellation or bounded admission failed');
  demand(report.checks.empty_tree_roles_remain_explicit_complete_empty_without_native_packet === true,
    'empty tree roles no longer produce explicit complete-empty output');
  demand(Array.isArray(report.nativeFoliageParityCases) && report.nativeFoliageParityCases.length === 3,
    'native foliage parity evidence omitted family/LOD rows');
  demand(Array.isArray(report.nativeBranchParityCases) && report.nativeBranchParityCases.length === 3,
    'native branch parity evidence omitted family/LOD rows');
  demand(report.nativeBranchParityCases.every((row) =>
    row.replacedSourceEpochRejected === true && row.replacedRecipeEpochRejected === true),
  'native branch result was not independently rejected for replaced source and recipe epochs');
  demand(report.status === 'ready' && report.batchCount >= 3, 'tree compiler emitted no complete render batches');
  return {
    reportPath: path.join(c.run, 'report.json'),
    sectionKeys: report.sectionKeys,
    batchCount: report.batchCount,
    workUnits: report.workUnits,
    singleUnitSteps: report.singleUnitSteps,
    largeUnitSteps: report.largeUnitSteps,
    treeClosureFalsifier: report.treeClosureFalsifier,
    nativeFoliageParityCases: report.nativeFoliageParityCases,
    nativeBranchParityCases: report.nativeBranchParityCases,
    nativeDispatcherLifecycle: report.nativeDispatcherLifecycle,
    nativeSectionPackDifferential: report.nativeSectionPackDifferential,
    nativeSectionPackLifecycle: report.nativeSectionPackLifecycle,
    evidenceLevel: report.evidenceLevel
  };
});

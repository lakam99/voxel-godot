import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), {
    outputdirectory: '', godotexe: '', projectpath: '', compileonly: false
  });
  const compileOnly = o.compileonly === true || String(o.compileonly).toLowerCase() === 'true';
  const c = context(o, compileOnly
    ? 'whole-section-candidate-native-install-compile-'
    : 'whole-section-candidate-native-install-');
  prepare(c, 'userdata', false);
  const visualManifest = read(path.join(c.project, 'assets/visual/generated/visual-manifest.json'));
  const visualAssetSources = Array.isArray(visualManifest.assets)
    ? visualManifest.assets.map(asset => String(asset?.path ?? '')).filter(assetPath => assetPath.length > 0)
      .flatMap(assetPath => [assetPath, `${assetPath}.import`])
    : [];
  demand(visualAssetSources.length > 0, 'Production visual manifest has no source assets to pin.');
  launchRecord(c, [
    'scripts/testing/world/WholeSectionCandidateNativeInstallFixture.gd',
    'scenes/Main.tscn',
    'scripts/Main.gd',
    'scripts/MainPropFactory.gd',
    'scripts/MainChunkTerrain.gd',
    'scripts/MainInteractionFlow.gd',
    'scripts/MainPlaytestTools.gd',
    'scripts/MainRuntimeTools.gd',
    'scripts/MainDiscoveryFlow.gd',
    'scripts/MainHudFlow.gd',
    'scripts/MainWorldEntities.gd',
    'scripts/MainCharacterState.gd',
    'scripts/MainGameLoop.gd',
    'scripts/MainSetupScene.gd',
    'scripts/MainSaveState.gd',
    'scripts/MainCore.gd',
    'scripts/MainInterface.gd',
    'scripts/StructureSystem.gd',
    'scripts/WorldGenerationSystem.gd',
    'scripts/world/BiomeRegionField.gd',
    'scripts/environment/BiomeEnvironmentCatalog.gd',
    'scripts/environment/BiomeEnvironmentProfile.gd',
    'scripts/visual/VisualAssetRegistry.gd',
    'scripts/visual/AnimatedAssetRegistry.gd',
    'scripts/world/EcologyProducerCatalogContext.gd',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/visual/ActiveVisualAssetSnapshot.gd',
    'scripts/visual/ActiveVisualAssetSnapshot.gd.uid',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologySectionValueAdapter.gd.uid',
    'scripts/world/EcologySourceValueLedger.gd',
    'scripts/world/EcologyWorldSupportIndex.gd',
    'scripts/world/EcologyDetailSourceValueBuilder.gd',
    'scripts/world/TreeSectionValueAdapter.gd',
    'scripts/world/ActiveRemovedPropsSnapshot.gd',
    'scripts/world/HorizonEcologyTreeBatch.gd',
    'scripts/world/CitadelSectionGeometryAdapter.gd',
    'scripts/environment/TreeRecipeCache.gd',
    'scripts/environment/RockRecipeBuilder.gd',
    'scripts/world/ChunkPropVisualManifest.gd',
    'scripts/world/HorizonChunkPropManifestCache.gd',
    'scripts/world/PhysicalChunkPropManifestCache.gd',
    'scripts/world/DetailBatchVisualReceiptPublisher.gd',
    'scripts/environment/TreeRuntimeRequestBuilder.gd',
    'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd',
    'scripts/environment/TreeRequestAdmission.gd',
    'scripts/environment/tree_grammars/MathematicalTreePocRecipeBuilder.gd',
    'scripts/environment/tree_grammars/MathematicalTreePocBushyOakRecipeBuilder.gd',
    'scripts/environment/tree_grammars/MathematicalTreePocConiferRecipeBuilder.gd',
    'scripts/environment/tree_grammars/MathematicalTreePocSavannaRecipeBuilder.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd.uid',
    'scripts/world/TreeSectionValueAdapter.gd',
    'scripts/environment/TreePublicationQueue.gd',
    'scripts/environment/TreeSpawnService.gd',
    'scripts/environment/EnvironmentWindSystem.gd',
    'scripts/visual/ProceduralTreeVisualFactory.gd',
    'resources/visual/procedural_tree_branch.gdshader',
    'resources/visual/procedural_tree_foliage.gdshader',
    'resources/visual/tree_wind_material.gdshader',
    'resources/visual/biomes/default.tres',
    'resources/visual/biomes/ocean.tres',
    'resources/visual/biomes/beach.tres',
    'resources/visual/biomes/plains.tres',
    'resources/visual/biomes/forest.tres',
    'resources/visual/biomes/taiga.tres',
    'resources/visual/biomes/snow.tres',
    'resources/visual/biomes/tundra.tres',
    'resources/visual/biomes/alpine.tres',
    'resources/visual/biomes/savanna.tres',
    'resources/visual/biomes/desert.tres',
    'resources/visual/biomes/swamp.tres',
    'resources/visual/biomes/town.tres',
    'assets/visual/generated/visual-manifest.json',
    ...visualAssetSources,
    'assets/generated/animated/door_open_close.glb',
    'assets/generated/animated/door_open_close.glb.import',
    'assets/generated/animated/chest_open_close.glb',
    'assets/generated/animated/chest_open_close.glb.import',
    'assets/generated/animated/boar_idle_walk.glb',
    'assets/generated/animated/boar_idle_walk.glb.import',
    'assets/generated/animated/deer_idle_walk.glb',
    'assets/generated/animated/deer_idle_walk.glb.import',
    'assets/generated/animated/hare_idle_walk.glb',
    'assets/generated/animated/hare_idle_walk.glb.import',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/StaticRenderMaterialFingerprint.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd.uid',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'native/terrain_meshing/src/register_types.cpp',
    'native/terrain_meshing/src/terrain_meshing_backend.cpp',
    'native/terrain_meshing/src/terrain_meshing_backend.h',
    'native/terrain_meshing/src/native_tree_geometry_dispatcher.cpp',
    'native/terrain_meshing/src/native_tree_geometry_dispatcher.h',
    'native/terrain_meshing/build/world_backend/debug/build-manifest.json',
    'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'tools/visible-world/run-whole-section-candidate-native-install.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: compileOnly
      ? 'whole-section-candidate-native-install-compile-launch/v1'
      : 'whole-section-candidate-native-install-launch/v1',
    evidenceLevel: compileOnly
      ? 'headless_fixture_script_compile_load_only'
      : 'headed_real_main_ecology_candidate_installed_by_native_chunk_renderer',
    headed: !compileOnly,
    timeoutSeconds: compileOnly ? 90 : 600,
    doesNotProve: 'Normal-world startup and streaming, live visual parity, collision/interactions, save/replay, or runtime performance; terrain and ordinary providers remain fixture producers.'
  });
  await phaseRun(c, {
    args: [...(compileOnly ? ['--headless', '--check-only'] : []),
      '--script', 'res://scripts/testing/world/WholeSectionCandidateNativeInstallFixture.gd'],
    env: {
      VOXEL_WHOLE_SECTION_NATIVE_INSTALL_REPORT: path.join(c.run, 'report.json'),
      VOXEL_WHOLE_SECTION_NATIVE_INSTALL_PROGRESS: path.join(c.run, 'progress.json')
    },
    timeout: compileOnly ? 90 : 600,
    logPolicy: { emptyStderr: false }
  });
  if (compileOnly) return { evidenceLevel: 'headless_fixture_script_compile_load_only' };
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'whole-section-candidate-native-install/v1' && report.passed === true,
    'Headed native whole-section install fixture failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});

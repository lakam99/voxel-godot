export const N4_UNDERGROUND_PROP_SOURCE_PATHS = Object.freeze([
  'tools/run-n4-underground-prop-source-differential.mjs',
  'tools/lib/n4-underground-prop-source-evidence.mjs',
  'tools/lib/voxel-tool-runtime.mjs',
  'tools/lib/godot-process.mjs',
  'tools/run-godot-scene-watchdog.mjs',
  'tools/lib/owned-process.mjs',
  'tools/lib/owned-native-host.mjs',
  'tools/lib/owned-live-clock.mjs',
  'tools/native/OwnedProcessHost.cs',
  'tools/native/OwnedProcessNative.cs',
  'scripts/testing/native_world/N4UndergroundPropSourceProbe.gd',
  'scripts/Main.gd',
  'scripts/MainPropFactory.gd',
  'scripts/MainPlaytestTools.gd',
  'scripts/MainInteractionFlow.gd',
  'scripts/MainRuntimeTools.gd',
  'scripts/MainSetupScene.gd',
  'scripts/MainSaveState.gd',
  'scripts/MainCore.gd',
  'scripts/MainInterface.gd',
  'scripts/WorldGenerationSystem.gd',
  'scripts/TerrainVolumeService.gd',
  'scripts/world/BiomeRegionField.gd',
  'scripts/world/BuildingTerrainProfile.gd',
  'scripts/world/BuildingGroundMask.gd',
  'scripts/StructureSystem.gd',
  'scripts/world/CitadelTerrainAdmission.gd',
  'scripts/world/CitadelSiteField.gd',
  'scripts/world/CitadelSiteBuildQueue.gd',
  'scripts/world/CitadelSitePreparation.gd',
  'scripts/world/CitadelSiteSurvey.gd',
  'scripts/world/GeneratedSiteProfileStore.gd',
  'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd',
  'scripts/visual/ActiveVisualAssetSnapshot.gd',
  'scripts/world/ActiveRemovedPropsSnapshot.gd',
  'scripts/world/ActiveStructureExclusionChunkSnapshot.gd',
  'scripts/world/ActiveEffectiveTerrainChunkPin.gd',
  'scripts/world/ActiveSurfacePropOwnerBundle.gd',
  'scripts/environment/RockRecipeBuilder.gd',
  'scripts/environment/BiomeEnvironmentCatalog.gd',
  'scripts/environment/BiomeEnvironmentProfile.gd',
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
  'scripts/visual/VisualAssetRegistry.gd',
  'assets/visual/generated/visual-manifest.json',
  ...Array.from({ length: 6 }, (_, index) => {
    const suffix = String(index + 1).padStart(2, '0');
    return [`assets/visual/generated/environment/rock_${suffix}.glb`,
      `assets/visual/generated/environment/rock_${suffix}.glb.import`];
  }).flat(),
  'scripts/visual/AnimatedAssetRegistry.gd',
  ...['door_open_close', 'chest_open_close', 'boar_idle_walk', 'deer_idle_walk',
    'hare_idle_walk'].flatMap(name => [`assets/generated/animated/${name}.glb`,
    `assets/generated/animated/${name}.glb.import`]),
  'native/world_backend/core/native_underground_prop_stream.cpp',
  'native/world_backend/core/native_underground_prop_stream.hpp',
  'native/world_backend/core/native_ore_cluster_stream.cpp',
  'native/world_backend/core/native_ore_cluster_stream.hpp',
  'native/terrain_meshing/src/native_world_backend_adapter.cpp',
  'native/terrain_meshing/src/native_world_backend_adapter.h',
  'native/world_backend/source-manifest.json',
  'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
]);

const demand = (condition, message) => {
  if (!condition) throw new Error(message);
};

const timestamp = (value, field) => {
  demand(typeof value === 'string' && value.length > 0, `Missing watchdog ${field}`);
  const milliseconds = Date.parse(value);
  demand(Number.isFinite(milliseconds), `Invalid watchdog ${field}`);
  return milliseconds;
};

export function n4UndergroundPropWatchdogIdentity(processResult) {
  demand(processResult && typeof processResult === 'object', 'Missing owned-process result');
  const summary = processResult.summary;
  demand(summary && typeof summary === 'object', 'Missing owned-process watchdog summary');
  demand(summary.schema === 'godot-scene-watchdog/v5', 'Unexpected watchdog schema');
  demand(typeof summary.runId === 'string' && /^[0-9a-f]{32}$/.test(summary.runId),
    'Invalid watchdog runId');
  demand(Number.isSafeInteger(summary.rootPid) && summary.rootPid > 0,
    'Invalid watchdog rootPid');
  const launched = timestamp(summary.launchTimeUtc, 'launchTimeUtc');
  const completed = timestamp(summary.completedTimeUtc, 'completedTimeUtc');
  demand(completed >= launched, 'Watchdog completion predates launch');
  demand(typeof summary.zeroProofSource === 'string' && summary.zeroProofSource.length > 0,
    'Missing watchdog zeroProofSource');
  demand(typeof processResult.summaryPath === 'string' && processResult.summaryPath.length > 0,
    'Missing owned-process summaryPath');
  demand(summary.summaryPath === processResult.summaryPath,
    'Owned-process summaryPath does not match watchdog receipt');
  return Object.freeze({
    schema: summary.schema,
    runId: summary.runId,
    rootPid: summary.rootPid,
    launchTimeUtc: summary.launchTimeUtc,
    completedTimeUtc: summary.completedTimeUtc,
    zeroProofSource: summary.zeroProofSource,
    ownershipAuthority: summary.ownershipAuthority,
    summaryPath: processResult.summaryPath,
  });
}

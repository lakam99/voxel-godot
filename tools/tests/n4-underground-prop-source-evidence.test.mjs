import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { N4_UNDERGROUND_PROP_SOURCE_PATHS,
  n4UndergroundPropWatchdogIdentity } from '../lib/n4-underground-prop-source-evidence.mjs';

const project = fileURLToPath(new URL('../../', import.meta.url));

test('N4 source freeze covers every direct underground oracle owner and capture input', () => {
  const required = [
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
    'scripts/StructureSystem.gd',
    'scripts/world/CitadelTerrainAdmission.gd',
    'scripts/world/CitadelSiteField.gd',
    'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd',
    'scripts/visual/ActiveVisualAssetSnapshot.gd',
    'scripts/world/ActiveRemovedPropsSnapshot.gd',
    'scripts/world/ActiveStructureExclusionChunkSnapshot.gd',
    'scripts/world/ActiveEffectiveTerrainChunkPin.gd',
    'scripts/world/ActiveSurfacePropOwnerBundle.gd',
    'scripts/environment/RockRecipeBuilder.gd',
    'scripts/environment/BiomeEnvironmentCatalog.gd',
    'scripts/environment/BiomeEnvironmentProfile.gd',
    'scripts/visual/VisualAssetRegistry.gd',
    'scripts/visual/AnimatedAssetRegistry.gd',
    'assets/visual/generated/visual-manifest.json',
    'native/world_backend/core/native_underground_prop_stream.cpp',
    'native/terrain_meshing/src/native_world_backend_adapter.cpp',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
  ];
  assert.equal(new Set(N4_UNDERGROUND_PROP_SOURCE_PATHS).size,
    N4_UNDERGROUND_PROP_SOURCE_PATHS.length, 'source freeze paths must be unique');
  for (const path of required) assert.ok(N4_UNDERGROUND_PROP_SOURCE_PATHS.includes(path), path);
  for (const path of N4_UNDERGROUND_PROP_SOURCE_PATHS) {
    assert.equal(path.includes('\\'), false, `source path must be canonical: ${path}`);
    assert.ok(existsSync(resolve(project, path)), `source input must exist: ${path}`);
  }
});

test('N4 source freeze pairs every consumed generated scene with its import descriptor', () => {
  const scenes = N4_UNDERGROUND_PROP_SOURCE_PATHS.filter(path => path.endsWith('.glb'));
  assert.equal(scenes.length, 11);
  for (const scene of scenes)
    assert.ok(N4_UNDERGROUND_PROP_SOURCE_PATHS.includes(`${scene}.import`), scene);
});

const cleanResult = () => ({
  summaryPath: 'P:\\run\\watchdog.json',
  summary: {
    schema: 'godot-scene-watchdog/v5',
    runId: '0123456789abcdef0123456789abcdef',
    rootPid: 1234,
    launchTimeUtc: '2026-09-24T09:42:48.982Z',
    completedTimeUtc: '2026-09-24T09:46:07.985Z',
    zeroProofSource: 'job_membership_zero',
    ownershipAuthority: 'Windows Job Object membership only',
    summaryPath: 'P:\\run\\watchdog.json',
  },
});

test('N4 report identity binds to the exact watchdog run and root process', () => {
  const identity = n4UndergroundPropWatchdogIdentity(cleanResult());
  assert.deepEqual(identity, {
    schema: 'godot-scene-watchdog/v5',
    runId: '0123456789abcdef0123456789abcdef',
    rootPid: 1234,
    launchTimeUtc: '2026-09-24T09:42:48.982Z',
    completedTimeUtc: '2026-09-24T09:46:07.985Z',
    zeroProofSource: 'job_membership_zero',
    ownershipAuthority: 'Windows Job Object membership only',
    summaryPath: 'P:\\run\\watchdog.json',
  });
  assert.equal(Object.isFrozen(identity), true);
  const later = cleanResult();
  later.summary.runId = 'fedcba9876543210fedcba9876543210';
  later.summary.rootPid = 5678;
  assert.notDeepEqual(n4UndergroundPropWatchdogIdentity(later), identity);
});

test('N4 watchdog identity rejects missing, malformed, or cross-receipt fields', () => {
  const mutations = [
    result => { result.summary = null; },
    result => { result.summary.schema = 'godot-scene-watchdog/v4'; },
    result => { result.summary.runId = 'not-a-run-id'; },
    result => { result.summary.rootPid = 0; },
    result => { result.summary.launchTimeUtc = 'invalid'; },
    result => { result.summary.completedTimeUtc = '2026-09-24T09:40:00.000Z'; },
    result => { result.summary.zeroProofSource = null; },
    result => { result.summaryPath = 'P:\\other\\watchdog.json'; },
  ];
  for (const mutate of mutations) {
    const result = cleanResult();
    mutate(result);
    assert.throws(() => n4UndergroundPropWatchdogIdentity(result));
  }
});

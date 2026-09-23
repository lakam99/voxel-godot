import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import { expectedNativeMethod, inputPaths, validateFixtureReport, validateNativeBuildReport } from '../lib/n2-native-world-vertical-slice.mjs';

const godotVersion = { major: 4, minor: 6, patch: 1, hash: '14d19694e0c88a3f9e82d899a0400f27a24c176e' };

function oracle() {
  const coordinates = [[-33, 12, -5], [-32, 12, -5], [-33, 12, -4], [-32, 12, -4]];
  return {
    sampleCount: 33915,
    ordering: 'x_fastest_then_z_then_y',
    forbiddenOraclePathsUsed: false,
    noiseFloatBits: [...new Map([['height', 1769607420], ['ridge', 1769813314], ['flat', 1770035046], ['moisture', 1770320130], ['temperature', 1770510186]])]
      .flatMap(([configuration, seed]) => Array.from({ length: 4 }, (_, index) => ({ configuration, seed, coordinate: [index, index, index], twoDBits: index, threeDBits: index + 1 }))),
    typedDeltas: { sha256: 'a'.repeat(64), byteLength: 100, records: coordinates.map((coordinate, index) => ({
      coordinate, density: -1.35, solid: false, materialId: 0, materialName: 'air', surfaceBiomeId: 2,
      surfaceBiomeName: 'swamp', resolvedBiomeId: 13, resolvedBiomeName: 'underground_air', fluidId: 0,
      fluid: '', deltaId: `n2:seam-air:${index}`, deltaRevision: 1,
    })) },
  };
}

function expectedApi() {
  return { method: expectedNativeMethod, requestSchema: 'n2-native-vertical-slice-request/v1', resultSchema: 'n2-native-vertical-slice-result/v1', preparedPayloadCapBytes: 4194304 };
}

function resourceUsage(bytes) {
  return { admittedRequests: 1, peakInFlightBuilds: 1, preparedResults: 1, preparedBytes: bytes,
    installedBodiesExpected: 1, installedShapesExpected: 3, collisionTriangles: 100,
    retiredShapeSetsAwaitingRelease: 0 };
}

function payloadAccounting(bytes) {
  return { sourcePackedColumnsBytes: bytes, renderPackedBytes: 0, collisionPackedBytes: 0, stringBytes: 0,
    sparseMetadataBytes: 0, blockerGeometryBytes: 0, noiseFixtureBytes: 0,
    scope: 'native variable payload; excludes Variant container overhead and fixed object headers', total: bytes };
}

function timing() {
  return { requestValidationMilliseconds: 1, deltaResolutionMilliseconds: 1, sourceMilliseconds: 1,
    collisionMilliseconds: 1, renderPackMilliseconds: 1, hydrationMilliseconds: 1,
    renderConsumptionWaitMilliseconds: 1, installMilliseconds: 1, acknowledgementMilliseconds: 1,
    totalMilliseconds: 9 };
}

function installed(frame, identity, digest, artifact, retiredShapeCount) {
  return { ok: true, acknowledgedPhysicsFrame: frame, currentShapeCount: 3, retiredShapeCount,
    acknowledgement: { physicsFrame: frame, provenance: {
      requestIdentity: identity, snapshotDigest: digest, artifactKey: artifact,
    } } };
}

test('blocked fixture is valid only for the explicit unavailable N2 native seam', () => {
  const report = { schema: 'n2-native-world-vertical-slice-fixture/v1', finished: true, passed: false,
    reason: `missing_native_method:${expectedNativeMethod}`, godotVersion, evidence: { oracle: oracle(), expectedNativeApi: expectedApi() } };
  assert.deepEqual(validateFixtureReport(report), { valid: true, errors: [], nativeApiAvailable: false });
  report.reason = 'ordered_sample_mismatch';
  assert.equal(validateFixtureReport(report).valid, false);
});

test('passing fixture requires exact one-authority, parity, render, acknowledgement and physics evidence', () => {
  const report = { schema: 'n2-native-world-vertical-slice-fixture/v1', finished: true, passed: true, reason: 'passed', godotVersion, evidence: {
    oracle: oracle(), expectedNativeApi: expectedApi(),
    authority: { staticBodyCount: 1, projectOwnedTerrainBodies: 1, voxelTerrainCollisionEnabled: false, installedShapeCount: 3 },
    render: { consumer: 'VoxelTerrain/VoxelBuffer/VoxelMesherTransvoxel', collisionDisabled: true, requiredSnapshotGap: '' },
    nativeBaseline: { sampleCount: 33915, snapshotDigest: '1'.repeat(64), collisionArtifactKey: '2'.repeat(64), preparedPayloadBytes: 1000, resourceUsage: resourceUsage(1000), preparedPayloadAccounting: payloadAccounting(1000),
      tileGeometrySha256: { '-3,-1': 'a'.repeat(64), '-2,-1': 'b'.repeat(64) } },
    sameShapeCheck: { snapshotDigest: '3'.repeat(64), collisionArtifactKey: '4'.repeat(64) },
    nativeEdited: { sampleCount: 33915, snapshotDigest: '5'.repeat(64), collisionArtifactKey: '6'.repeat(64), preparedPayloadBytes: 1001, resourceUsage: resourceUsage(1001), preparedPayloadAccounting: payloadAccounting(1001),
      tileGeometrySha256: { '-3,-1': 'c'.repeat(64), '-2,-1': 'd'.repeat(64) } },
    baselineInstall: installed(4, { ownerGeneration: 1, sourceRevision: 1, cancellationEpoch: 1 }, '1'.repeat(64), '2'.repeat(64), 0),
    sameShapeInstall: installed(7, { ownerGeneration: 1, sourceRevision: 1, cancellationEpoch: 2 }, '3'.repeat(64), '4'.repeat(64), 3),
    editedInstall: installed(10, { ownerGeneration: 1, sourceRevision: 2, cancellationEpoch: 2 }, '5'.repeat(64), '6'.repeat(64), 3),
    blockedReplacement: { reason: 'replacement_occupied_before_install' }, sameShapeSameHits: true,
    blockedAbort: { accepted: true, wrongIdentitySafe: false, replaySafe: false },
    acknowledgedPhysicsFrame: 10, physics: { ok: true }, actorGuard: { ok: true,
      occupied: { reason: 'actor_occupies_replacement' }, swept: { reason: 'actor_occupies_replacement' },
      clear: { clear: true }, lateActor: { clearance: { reason: 'actor_occupies_replacement' },
        motionAdmitted: false, prematureRelease: false, prematureAbort: false,
        cancelledEmptyStartup: true },
      nodeCap: { reason: 'actor_census_node_cap' } }, staleBeforeAck: { reason: 'stale_before_acknowledgement' },
      staleBeforeInstall: { reason: 'stale_before_install' },
      crossSeamPhysics: { changed: true, allHitsOwnedBySoleBody: true }, timing: timing(),
      resourceLifecycle: { admittedRequests: 3, currentInFlightBuilds: 0, peakInFlightBuilds: 1,
        currentPreparedResults: 0, peakPreparedResults: 1, currentPreparedBytes: 0, peakPreparedBytes: 1001,
        currentRetiredShapeSetsAwaitingRelease: 0, peakRetiredShapeSetsAwaitingRelease: 1 },
  } };
  assert.equal(validateFixtureReport(report).valid, true);
  report.evidence.authority.staticBodyCount = 2;
  assert(validateFixtureReport(report).errors.includes('one_authority_evidence_invalid'));
  report.evidence.authority.staticBodyCount = 1;
  report.evidence.sameShapeInstall.acknowledgement.provenance.requestIdentity.cancellationEpoch = 1;
  assert(validateFixtureReport(report).errors.includes('sameShapeInstall_physical_revision_invalid'));
  report.evidence.sameShapeInstall.acknowledgement.provenance.requestIdentity.cancellationEpoch = 2;
  report.evidence.resourceLifecycle.admittedRequests = 2;
  assert(validateFixtureReport(report).errors.includes('fixture_resource_lifecycle_invalid'));
});

test('N2 native build join requires passing coverage, immutable inputs, smoke, tests, and installed hashes', () => {
  const binaries = ['debug.dll', 'debug.dll.pdb', 'release.dll', 'release.dll.pdb'].map((name, index) => ({
    path: `addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.${name}`,
    sha256: String(index).repeat(64), bytes: index + 1,
  }));
  const installed = binaries.map(binary => ({ name: binary.path.split('/').at(-1), sha256: binary.sha256, bytes: binary.bytes,
    buildManifestSha256: 'a'.repeat(64), inputsDigestSha256: 'b'.repeat(64), pureCoreInputsDigestSha256: 'c'.repeat(64) }));
  const report = { schema: 'native-world-backend-n1-receipt/v1', status: 'passed', projectInputs: { unchanged: true },
    source: { unchanged: true }, adapterSmoke: { report: { value: { passed: true } } },
    coverage: { status: 'passed', denominatorValidated: true }, installed,
    configurations: [{ tests: { total: 1, passed: 1, failed: 0 } }, { tests: { total: 1, passed: 1, failed: 0 } }] };
  const joined = { path: 'native/world_backend/core/example.cpp', sha256: 'd'.repeat(64), bytes: 10 };
  report.source = { unchanged: true, sources: [joined] };
  report.projectInputs.before = { extensionSources: [], extensionHeaders: [], extensionBuildInputs: [], n1Inputs: [] };
  assert.deepEqual(validateNativeBuildReport(report, binaries, [joined]), { valid: true, errors: [] });
  report.coverage.status = 'failed_threshold';
  assert(validateNativeBuildReport(report, binaries, [joined]).errors.includes('native_coverage_not_passed'));
  report.coverage.status = 'passed';
  assert(validateNativeBuildReport(report, binaries, []).errors.includes('native_build_input_join_invalid'));
});

test('N2 inventory names every oracle, fixture, scene, runner and controlling input', () => {
  for (const required of [
    'docs/native_world_backend/N2_VERTICAL_SLICE_CONTRACT_2026-09-17.md',
    'native/terrain_meshing/src/n2_vertical_slice_adapter.cpp',
    'native/terrain_meshing/src/n2_vertical_slice_adapter.h',
    'native/world_backend/source-manifest.json',
    'native/world_backend/toolchain-lock.json',
    'native/world_backend/core/fast_noise_compat.cpp',
    'native/world_backend/core/terrain_source.cpp',
    'native/world_backend/core/terrain_snapshot.cpp',
    'native/world_backend/core/terrain_meshing.cpp',
    'native/world_backend/core/thirdparty/fast_noise_lite/FastNoiseLite.h',
    'scripts/testing/native_world/N2LatticeSourceOracle.gd',
    'scripts/testing/native_world/N2PreparedRenderGenerator.gd',
    'scripts/testing/native_world/N2VerticalSliceFixture.gd',
    'scripts/terrain/NativeTerrainCollisionOwner.gd',
    'scripts/terrain/NativeCollisionActorGuard.gd',
    'scripts/terrain/NativeCollisionAdmissionBarrier.gd',
    'scenes/testing/native_world/N2VerticalSliceFixture.tscn',
    'tools/run-n2-native-world-vertical-slice.mjs',
    'tools/lib/n2-native-world-vertical-slice.mjs',
    'tools/lib/owned-native-host.mjs',
    'tools/lib/owned-live-clock.mjs',
    'tools/lib/godot-process.mjs',
    'tools/native/OwnedProcessNative.cs',
    'tools/native/OwnedProcessHost.cs',
  ]) assert(inputPaths.includes(required), required);
  assert.equal(new Set(inputPaths).size, inputPaths.length);
});

test('oracle never calls a composite terrain sampler or generated-fluid authority', async () => {
  const source = await readFile(new URL('../../scripts/testing/native_world/N2LatticeSourceOracle.gd', import.meta.url), 'utf8');
  for (const prohibited of ['sample_cell(', 'generate_cell_state(', 'generate_section_payload(', 'underground_fluid_for_cell(']) {
    assert.equal(source.includes(prohibited), false, prohibited);
  }
  for (const required of ['terrain_reference_surface_y_at(', 'terrain_deformed_surface_y_at(', 'density_from_components(', 'generated_solid_material_for_cell(']) {
    assert.equal(source.includes(required), true, required);
  }
});

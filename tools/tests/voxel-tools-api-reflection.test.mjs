import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import {
  absenceInterpretation,
  discoverProjectLocalModuleClosure,
  prepareEvidencePaths,
  projectIdentityFiles,
  receiptSchema,
  validateNativeWorldBackendManifest,
  validateProbeReport
} from '../lib/voxel-tools-api-reflection.mjs';

function members() {
  return { methods: [], properties: [], signals: [], integerConstants: [], enums: [] };
}

function validProbe(token = 'token', digest = 'a'.repeat(64)) {
  const required = [
    'VoxelTerrain', 'VoxelViewer', 'VoxelBuffer', 'VoxelGenerator',
    'VoxelGeneratorScript', 'VoxelStream', 'VoxelStreamScript', 'VoxelTool'
  ];
  return {
    schema: 'voxel-tools-classdb-reflection/v1',
    runnerId: 'voxel_tools_api_reflection_probe',
    finished: true,
    passed: true,
    runToken: token,
    absenceInterpretation,
    providedIdentity: { observedInputAggregateSha256: digest },
    classes: required.map(name => ({
      name, exists: true, declared: members(), includingInherited: members()
    })),
    capabilityCandidateObservations: Array.from({ length: 4 }, (_, index) => ({
      id: `query-${index}`,
      exactCandidateObservation: 'not_observed_in_reflected_classdb_surface',
      interpretation: absenceInterpretation
    }))
  };
}

test('receipt schema is versioned', () => {
  assert.equal(receiptSchema, 'voxel-tools-api-reflection-receipt/v1');
});

test('input identity binds the recursive local module closure and native owned-process sources', async () => {
  const moduleClosure = await discoverProjectLocalModuleClosure();
  for (const requiredPath of [
    'tools/run-voxel-tools-api-reflection.mjs',
    'tools/tests/voxel-tools-api-reflection.test.mjs',
    'tools/lib/voxel-tool-runtime.mjs',
    'tools/lib/godot-process.mjs',
    'tools/run-godot-scene-watchdog.mjs',
    'tools/lib/owned-process.mjs',
    'tools/lib/owned-native-host.mjs',
    'tools/lib/owned-live-clock.mjs'
  ]) {
    assert.ok(moduleClosure.includes(requiredPath), `missing module identity input: ${requiredPath}`);
  }
  for (const requiredPath of [
    'tools/native/OwnedProcessNative.cs',
    'tools/native/OwnedProcessHost.cs'
  ]) {
    assert.ok(projectIdentityFiles.includes(requiredPath), `missing native identity input: ${requiredPath}`);
  }
});

test('valid ClassDB probe is accepted without converting absence into impossibility', () => {
  const report = validProbe();
  assert.deepEqual(validateProbeReport(report, 'token', 'a'.repeat(64)), []);
  assert.match(report.absenceInterpretation, /not proof of universal impossibility/);
});

test('validator rejects stale, incomplete, broadened, and identity-mismatched reports', () => {
  const cases = [
    [{ ...validProbe(), runToken: 'stale' }, /run_token_mismatch/],
    [{ ...validProbe(), classes: [] }, /required_class_missing:VoxelTerrain/],
    [{ ...validProbe(), classes: {} }, /class_inventory_missing/],
    [{ ...validProbe(), absenceInterpretation: 'API is impossible.' }, /absence_interpretation_missing_or_broadened/],
    [{ ...validProbe(), providedIdentity: { observedInputAggregateSha256: 'b'.repeat(64) } }, /input_identity_mismatch/],
    [{ ...validProbe(), capabilityCandidateObservations: [] }, /capability_observations_missing/]
  ];
  for (const [report, expected] of cases) {
    assert.match(validateProbeReport(report, 'token', 'a'.repeat(64)).join('\n'), expected);
  }
});

test('explicit evidence paths refuse to overwrite either composite or raw probe evidence', async () => {
  const root = await mkdtemp(join(tmpdir(), 'voxel-api-reflection-'));
  const reportPath = join(root, 'report.json');
  const probePath = join(root, 'report.probe.json');
  const first = await prepareEvidencePaths(reportPath);
  assert.equal(first.reportPath, reportPath);
  assert.equal(first.probePath, probePath);

  await writeFile(reportPath, '{"preserved":true}\n');
  await assert.rejects(prepareEvidencePaths(reportPath), /Refusing to overwrite/);
  assert.equal(await readFile(reportPath, 'utf8'), '{"preserved":true}\n');

  const secondRoot = join(root, 'second');
  await mkdir(secondRoot);
  const secondReport = join(secondRoot, 'receipt.json');
  await writeFile(join(secondRoot, 'receipt.probe.json'), '{"preserved":true}\n');
  await assert.rejects(prepareEvidencePaths(secondReport), /Refusing to overwrite/);
});

test('native world backend manifest must exactly cover categorized core and test sources', () => {
  const manifest = {
    schema: 'native-world-backend-source-manifest/v1',
    coreSources: ['core/identity.cpp'],
    coreHeaders: ['core/identity.hpp'],
    testSources: ['tests/identity_tests.cpp'],
    testHeaders: ['tests/test_harness.hpp']
  };
  const discovered = [
    'core/identity.cpp', 'core/identity.hpp',
    'tests/identity_tests.cpp', 'tests/test_harness.hpp'
  ];
  assert.deepEqual(validateNativeWorldBackendManifest(manifest, discovered), [...discovered].sort());
  assert.throws(
    () => validateNativeWorldBackendManifest(manifest, [...discovered, 'core/unlisted.cpp']),
    /unmanifested=.*core\/unlisted\.cpp/
  );
  assert.throws(
    () => validateNativeWorldBackendManifest({ ...manifest, coreSources: ['core/missing.cpp'] }, discovered),
    /manifest mismatch/
  );
  assert.throws(
    () => validateNativeWorldBackendManifest({ ...manifest, coreSources: ['..\/escape.cpp'] }, discovered),
    /Invalid native world backend manifest path/
  );
  assert.throws(
    () => validateNativeWorldBackendManifest({ ...manifest, coreSources: [42] }, discovered),
    /manifest path in coreSources is not a string/
  );
  assert.throws(
    () => validateNativeWorldBackendManifest({ ...manifest, coreSources: ['C:/core/identity.cpp'] }, discovered),
    /Invalid native world backend manifest path/
  );
  assert.throws(
    () => validateNativeWorldBackendManifest({ ...manifest, coreHeaders: ['core/identity.cpp'] }, discovered),
    /Unexpected extension/
  );
});

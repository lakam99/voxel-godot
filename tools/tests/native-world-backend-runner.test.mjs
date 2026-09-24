import assert from 'node:assert/strict';
import { dirname, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  coverageTotals,
  coverageExecutionTimeoutMilliseconds,
  parseLcovLineCoverage,
  assertNormalizedUpstreamTextIdentity,
  expectedToolchainLockValue,
  inventoryProjectBuildInputs,
  nativeTestTimeoutSeconds,
  normalizedUpstreamTextSha256,
  releaseSaveV2ProbeChecks,
  validateInstalledProvenance,
  validateReleaseSaveV2ProbeReport,
  validateToolchainLockValue,
} from '../lib/native-world-backend-runner.mjs';

const project = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

test('native test timeout has current-suite headroom and validates bounded per-run overrides', () => {
  assert.equal(nativeTestTimeoutSeconds(), 300);
  assert.equal(nativeTestTimeoutSeconds({ nativeTestTimeoutSeconds: 360 }), 360);
  assert.equal(nativeTestTimeoutSeconds({ nativeTestTimeoutSeconds: '360' }), 360);
  for (const value of ['', '300.5', 0, 901, null]) {
    assert.throws(() => nativeTestTimeoutSeconds({ nativeTestTimeoutSeconds: value }),
      /nativeTestTimeoutSeconds/);
  }
});

test('coverage execution inherits the native test timeout and validates bounded overrides', () => {
  assert.equal(coverageExecutionTimeoutMilliseconds(), 300000);
  assert.equal(coverageExecutionTimeoutMilliseconds({ nativeTestTimeoutSeconds: 360 }), 360000);
  assert.equal(coverageExecutionTimeoutMilliseconds({ coverageExecuteTimeoutMs: 300000 }), 300000);
  assert.equal(coverageExecutionTimeoutMilliseconds({ coverageExecuteTimeoutMs: '300000' }), 300000);
  for (const value of ['', '300000.5', 999, 900001, 1500, null]) {
    assert.throws(() => coverageExecutionTimeoutMilliseconds({ coverageExecuteTimeoutMs: value }),
      /coverageExecuteTimeoutMs/);
  }
});

test('pinned upstream text identity normalizes CRLF only and rejects changed content', () => {
  const lf = Buffer.from('first line\nsecond line\n', 'utf8');
  const crlf = Buffer.from('first line\r\nsecond line\r\n', 'utf8');
  const expected = normalizedUpstreamTextSha256(lf);
  assert.equal(normalizedUpstreamTextSha256(crlf), expected);
  assert.equal(assertNormalizedUpstreamTextIdentity(crlf, expected), expected);
  assert.notEqual(normalizedUpstreamTextSha256(lf), normalizedUpstreamTextSha256('first line\nchanged line\n'));
  assert.throws(() => assertNormalizedUpstreamTextIdentity('first line\nchanged line\n', expected), /identity mismatch/);
});

function coverageExport(filename, branches) {
  return {
    type: 'llvm.coverage.json.export',
    data: [{
      files: [{
        filename,
        branches,
        segments: [[6, 9, 1, true, true, false]],
        summary: {
          lines: { count: 1, covered: 1 },
          functions: { count: 1, covered: 1 },
          branches: {
            count: branches.length * 2,
            covered: branches.reduce((sum, branch) => sum + Number(branch[4] > 0) + Number(branch[5] > 0), 0),
          },
        },
      }],
      functions: [],
    }],
  };
}

function lineCoverage(filename, records = ['DA:6,1']) {
  return parseLcovLineCoverage([`SF:${filename}`, ...records, 'end_of_record', ''].join('\n'), [filename]);
}

test('LLVM lcov parser normalizes paths and fails closed on missing, duplicate, or invalid line records', () => {
  const filename = resolve('C:/n1/coverage_canary.cpp');
  const normalized = parseLcovLineCoverage(
    [`SF:${filename.toUpperCase()}`, 'DA:6,0', 'end_of_record', ''].join('\n'), [filename]);
  assert.equal(normalized.get(filename.toLowerCase()).get(6), 0);
  assert.throws(() => parseLcovLineCoverage('', [filename]), /lcov line export is empty/);
  assert.throws(() => parseLcovLineCoverage('SF:C:/n1/other.cpp\nDA:6,1\nend_of_record\n', [filename]), /omitted expected/);
  assert.throws(() => parseLcovLineCoverage(
    [`SF:${filename}`, 'DA:6,0', 'DA:6,1', 'end_of_record', ''].join('\n'), [filename]), /duplicated line/);
  assert.throws(() => parseLcovLineCoverage(
    [`SF:${filename}`, 'DA:0,-1', 'end_of_record', ''].join('\n'), [filename]), /invalid DA record/);
});

test('LLVM 23 branch tuple reads independent true and false edge counts', () => {
  const filename = resolve('C:/n1/coverage_canary.cpp');
  const value = coverageTotals(coverageExport(filename, [
    [6, 9, 6, 18, 1, 0, 0, 0, 4],
    [13, 12, 13, 41, 0, 1, 0, 0, 4],
    [8, 9, 8, 52, 1, 4, 0, 0, 4],
    [8, 41, 8, 62, 9, 348, 0, 0, 4],
  ]), [filename], [filename], lineCoverage(filename));
  assert.deepEqual(value.uncovered.branches, [
    { file: filename, line: 6, column: 9, trueCount: 1, falseCount: 0 },
    { file: filename, line: 13, column: 12, trueCount: 0, falseCount: 1 },
  ]);
});

test('LLVM uncovered line serialization ignores branch-only misses and follows the line export', () => {
  const filename = resolve('C:/n1/coverage_canary.cpp');
  const value = coverageExport(filename, [[11, 9, 11, 18, 1, 0, 0, 0, 4]]);
  value.data[0].files[0].summary.lines = { count: 2, covered: 1 };
  value.data[0].files[0].segments = [
    [10, 3, 0, true, true, false], // source-region segment: uncovered executable line
    [11, 3, 4, true, true, false], // source-region segment: covered executable line
    [11, 8, 0, true, true, true], // gap artifact, not line coverage
    [11, 9, 0, true, false, false], // branch boundary artifact, despite its zero counter
  ];
  assert.deepEqual(coverageTotals(value, [filename], [filename],
    lineCoverage(filename, ['DA:10,0', 'DA:11,4'])).uncovered.lines, [
    { file: filename, line: 10 },
  ]);
  assert.equal(coverageTotals(value, [filename], [filename],
    lineCoverage(filename, ['DA:10,0', 'DA:11,4'])).uncovered.branches.length, 1);
});

test('LLVM uncovered line serialization rejects disagreement with the authoritative line summary', () => {
  const filename = resolve('C:/n1/coverage_canary.cpp');
  const value = coverageExport(filename, []);
  value.data[0].files[0].summary.lines = { count: 2, covered: 1 };
  assert.throws(() => coverageTotals(value, [filename], [filename], lineCoverage(filename)), /lcov line\/summary mismatch/);
});

test('LLVM lcov line serialization rejects omitted covered line records', () => {
  const filename = resolve('C:/n1/coverage_canary.cpp');
  const value = coverageExport(filename, []);
  value.data[0].files[0].summary.lines = { count: 2, covered: 1 };
  // The one uncovered record still agrees with LLVM's uncovered count, but a
  // covered DA record is missing, so the per-file total must fail closed.
  assert.throws(() => coverageTotals(value, [filename], [filename],
    lineCoverage(filename, ['DA:10,0'])), /lcov line\/summary mismatch.*executable lines/);
});

test('LLVM branch tuple rejects invalid edge counts', () => {
  const filename = resolve('C:/n1/coverage_canary.cpp');
  assert.throws(() => coverageTotals(coverageExport(filename, [
    [6, 9, 6, 18, -1, 2, 0, 0, 4],
  ]), [filename], [filename], lineCoverage(filename)), /Invalid LLVM branch true\/false-edge counts/);
});

test('LLVM branch tuple rejects summary and detail disagreement', () => {
  const filename = resolve('C:/n1/coverage_canary.cpp');
  const value = coverageExport(filename, [[6, 9, 6, 18, 1, 0, 0, 0, 4]]);
  value.data[0].files[0].summary.branches.covered = 2;
  assert.throws(() => coverageTotals(value, [filename], [filename], lineCoverage(filename)), /branch summary\/detail mismatch/);
});

test('LLVM duplicate expansion tuples aggregate by source identity before summary validation', () => {
  const filename = resolve('C:/n1/coverage_canary.cpp');
  const value = coverageExport(filename, [
    [6, 9, 6, 18, 1, 0, 0, 0, 4],
    [6, 9, 6, 18, 0, 2, 0, 0, 4],
  ]);
  value.data[0].files[0].summary.branches = { count: 2, covered: 2 };
  assert.deepEqual(coverageTotals(value, [filename], [filename], lineCoverage(filename)).uncovered.branches, []);
  value.data[0].files[0].summary.branches.covered = 1;
  assert.throws(() => coverageTotals(value, [filename], [filename], lineCoverage(filename)), /branch summary\/detail mismatch/);
});

test('LLVM coverage permits only explicitly manifested core headers outside the source denominator', () => {
  const source = resolve('C:/repo/native/world_backend/core/source.cpp');
  const header = resolve('C:/repo/native/world_backend/core/thirdparty/dependency.hpp');
  const value = coverageExport(source, []);
  value.data[0].files.push({ ...structuredClone(value.data[0].files[0]), filename: header });
  assert.doesNotThrow(() => coverageTotals(value, [source], [source, header], lineCoverage(source)));
  assert.throws(() => coverageTotals(value, [source], [source], lineCoverage(source)), /unmanifested core sources/);
});

test('toolchain lock validation fails closed on pin or license-path drift', () => {
  assert.equal(validateToolchainLockValue(structuredClone(expectedToolchainLockValue)).schema,
    'native-world-backend-toolchain-lock/v1');
  const resourceDrift = structuredClone(expectedToolchainLockValue);
  resourceDrift.llvmCoverage.resourceDirVersion = '23.1.1';
  assert.throws(() => validateToolchainLockValue(resourceDrift), /does not exactly match/);
  const licenseDrift = structuredClone(expectedToolchainLockValue);
  licenseDrift.godotCpp.licenseFile = '../wrong/LICENSE.md';
  assert.throws(() => validateToolchainLockValue(licenseDrift), /does not exactly match/);
  const compilerDrift = structuredClone(expectedToolchainLockValue);
  compilerDrift.msvc.toolsetVersion = '14.43.0';
  assert.throws(() => validateToolchainLockValue(compilerDrift), /does not exactly match/);
  const godotDrift = structuredClone(expectedToolchainLockValue);
  godotDrift.godot.patch = 0;
  assert.throws(() => validateToolchainLockValue(godotDrift), /does not exactly match/);
  const templateDrift = structuredClone(expectedToolchainLockValue);
  templateDrift.godot.windowsReleaseX8664TemplateSha256 = '0'.repeat(64);
  assert.throws(() => validateToolchainLockValue(templateDrift), /does not exactly match/);
  const noiseDrift = structuredClone(expectedToolchainLockValue);
  noiseDrift.fastNoiseLite.patchedHeaderSha256 = '0'.repeat(64);
  assert.throws(() => validateToolchainLockValue(noiseDrift), /does not exactly match/);
});

test('project input inventory includes the owned launcher and adapter/build surfaces', async () => {
  const inventory = await inventoryProjectBuildInputs(project);
  const paths = inventory.n1Inputs.map(item => item.path);
  assert(paths.includes('tools/lib/owned-process.mjs'));
  assert(paths.includes('scripts/testing/native_world/NativeWorldBackendAdapterSmoke.gd'));
  assert(paths.includes('scripts/testing/native_world/NativeWorldBackendReleaseSaveV2Probe.gd'));
  assert(paths.includes('native/world_backend/core/thirdparty/fast_noise_lite/LICENSE'));
  assert(inventory.extensionSources.some(item => item.path.endsWith('/terrain_meshing_backend.cpp')));
  assert.match(inventory.digestSha256, /^[0-9a-f]{64}$/);
});

function validReleaseProbeReport() {
  return {
    schema: 'native-world-backend-release-save-v2-probe/v1',
    passed: true,
    evidenceLevel: 'isolated-release-export-shadow-adapter',
    productionCutover: false,
    shadowOnly: true,
    engineVersion: {
      major: 4, minor: 6, patch: 1, status: 'stable',
      hash: '14d19694e0c88a3f9e82d899a0400f27a24c176e',
    },
    features: { release: true, template: true, debug: false, editor: false, editorHint: false },
    checks: Object.fromEntries(releaseSaveV2ProbeChecks.map(name => [name, true])),
    failures: [],
  };
}

test('release save-v2 probe validator requires the exact release/shadow evidence', () => {
  const valid = validReleaseProbeReport();
  assert.equal(validateReleaseSaveV2ProbeReport(valid), valid);
  const debug = structuredClone(valid);
  debug.features.debug = true;
  assert.throws(() => validateReleaseSaveV2ProbeReport(debug), /release export template/);
  const missing = structuredClone(valid);
  delete missing.checks.overlay_excluded_from_save;
  assert.throws(() => validateReleaseSaveV2ProbeReport(missing), /exact required check set/);
  const cutover = structuredClone(valid);
  cutover.productionCutover = true;
  assert.throws(() => validateReleaseSaveV2ProbeReport(cutover), /envelope is invalid/);
});

test('installed artifact provenance rejects a missing pure-core digest', () => {
  const valid = Array.from({ length: 4 }, (_, index) => ({
    name: `artifact-${index}`, buildManifestSha256: 'a', inputsDigestSha256: 'b', pureCoreInputsDigestSha256: 'c',
  }));
  assert.equal(validateInstalledProvenance(valid), valid);
  const invalid = structuredClone(valid);
  delete invalid[0].pureCoreInputsDigestSha256;
  assert.throws(() => validateInstalledProvenance(invalid), /missing a required build\/source provenance digest/);
});

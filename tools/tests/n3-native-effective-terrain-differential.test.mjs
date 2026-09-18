import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';

import {
  authoritativeStaticPaths,
  evidenceLevel,
  expectedQueryCounts,
  fixtureSchema,
  fixtureScript,
  pinnedGodot,
  receiptSchema,
  inventoryAuthoritativeInputs,
  runN3NativeEffectiveTerrainDifferential,
  validateFixtureReport,
  validateNativeBuildReceipt,
} from '../lib/n3-native-effective-terrain-differential.mjs';

const joinedInput = { path: 'native/world_backend/core/example.cpp', sha256: 'd'.repeat(64), bytes: 10 };
const binaryInput = {
  path: 'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
  sha256: 'e'.repeat(64), bytes: 20,
};
const goldensInput = {
  path: 'scripts/testing/native_world/N3EffectiveTerrainGoldens.json',
  sha256: 'f'.repeat(64), bytes: 30,
};

function inputInventory(digest = 'a'.repeat(64)) {
  return {
    schema: 'n3-effective-terrain-authoritative-input-inventory/v1',
    files: [joinedInput, binaryInput, goldensInput],
    nativeBuildRequiredPaths: [joinedInput.path],
    aggregateSha256: digest,
  };
}

function toolchainLock() {
  return { schema: 'native-world-backend-toolchain-lock/v1', godot: { ...pinnedGodot } };
}

function nativeBuildReceipt() {
  const engineVersion = { major: 4, minor: 6, patch: 1, status: 'stable', hash: pinnedGodot.engineCommitSha };
  const tests = configuration => ({ configuration, tests: { total: 2, passed: 2, failed: 0 } });
  return {
    schema: 'native-world-backend-n1-receipt/v1', status: 'passed',
    source: { unchanged: true, sources: [joinedInput] },
    projectInputs: { unchanged: true, before: { extensionSources: [], extensionHeaders: [], extensionBuildInputs: [], n1Inputs: [] } },
    adapterSmoke: {
      report: { value: { schema: 'native-world-backend-adapter-smoke-report/v1', passed: true, engineVersion } },
      godot: { sha256: pinnedGodot.consoleSha256, pinnedVersion: pinnedGodot.version },
    },
    coverage: { status: 'passed', denominatorValidated: true },
    configurations: [tests('debug'), tests('release')],
    installed: [{
      name: binaryInput.path.split('/').at(-1), sha256: binaryInput.sha256, bytes: binaryInput.bytes,
      buildManifestSha256: 'a'.repeat(64), inputsDigestSha256: 'b'.repeat(64),
      pureCoreInputsDigestSha256: 'c'.repeat(64),
    }],
  };
}

function fixtureReport(overrides = {}) {
  return {
    schema: fixtureSchema, finished: true, status: 'passed', passed: true, evidenceLevel,
    godotVersion: { major: 4, minor: 6, patch: 1, status: 'stable', hash: pinnedGodot.engineCommitSha },
    mismatchCount: 0,
    queryCounts: { ...expectedQueryCounts },
    checks: {
      sourceParity: true,
      independentGoldens: true,
      mutationChecks: true,
      pinLifetime: true,
      noProductionMutation: true,
    },
    nativeAdapterIdentity: binaryInput.sha256,
    querySetIdentity: goldensInput.sha256,
    productionCutover: false,
    ...overrides,
  };
}

async function setup(overrides = {}) {
  const project = await mkdtemp(join(tmpdir(), 'n3-effective-differential-'));
  const output = join(project, 'out');
  const godot = join(project, 'godot-console.exe');
  const nativeReceiptPath = join(project, 'native-receipt.json');
  await mkdir(join(project, 'native', 'world_backend'), { recursive: true });
  await writeFile(join(project, 'native', 'world_backend', 'toolchain-lock.json'), JSON.stringify(toolchainLock()));
  await writeFile(godot, 'fake pinned Godot');
  await writeFile(nativeReceiptPath, JSON.stringify(nativeBuildReceipt()));
  let inventoryCall = 0;
  let godotHashCall = 0;
  let launched = false;
  const dependencies = {
    defaultProjectRoot: project,
    findGodot: async () => godot,
    hashFile: async path => {
      if (path === godot) {
        godotHashCall += 1;
        return godotHashCall > 1 && overrides.godotSha256After
          ? overrides.godotSha256After
          : (overrides.godotSha256 ?? pinnedGodot.consoleSha256);
      }
      return createHash('sha256').update(await readFile(path)).digest('hex');
    },
    inventoryAuthoritativeInputs: async () => {
      inventoryCall += 1;
      return overrides.inventory?.(inventoryCall) ?? inputInventory();
    },
    runOwnedProcess: async options => {
      launched = true;
      await writeFile(options.stdoutPath, overrides.stdout ?? 'fixture output\n');
      await writeFile(options.stderrPath, overrides.stderr ?? '');
      if (!overrides.omitFixture) {
        await writeFile(options.env.N3_EFFECTIVE_TERRAIN_DIFFERENTIAL_REPORT,
          JSON.stringify(overrides.fixture ?? fixtureReport()));
      }
      const summary = overrides.process ?? {
        overallExitCode: 0, functionalExitCode: 0, cleanupPassed: true,
        authoritativeZeroProven: true, forcedCleanup: false, cleanupUnresolved: false,
        finalJobMemberPids: [],
      };
      if (overrides.mutateLock) {
        await writeFile(join(project, 'native', 'world_backend', 'toolchain-lock.json'), '{"changed":true}');
      }
      if (overrides.mutateNativeReceipt) await writeFile(nativeReceiptPath, '{"changed":true}');
      await writeFile(options.summaryPath, JSON.stringify(summary));
      assert.deepEqual(options.args, ['--headless', '--audio-driver', 'Dummy', '--path', project, '--script', fixtureScript]);
      assert.equal(options.env.VOXEL_DISABLE_AUDIO_PLAYBACK, '1');
      return summary;
    },
  };
  const argv = [
    '--project-path', project,
    '--output-dir', output,
    '--native-build-report', nativeReceiptPath,
    '--godot-exe', godot,
  ];
  return {
    project, output, godot, nativeReceiptPath, dependencies, argv,
    launched: () => launched,
    cleanup: () => rm(project, { recursive: true, force: true }),
  };
}

test('passing orchestration emits a shadow-only receipt with hashed evidence and clean shutdown', async () => {
  const context = await setup();
  try {
    const result = await runN3NativeEffectiveTerrainDifferential(context.argv, context.dependencies);
    assert.equal(result.receipt.schema, receiptSchema);
    assert.equal(result.receipt.status, 'passed');
    assert.equal(result.receipt.evidenceLevel, evidenceLevel);
    assert.equal(result.receipt.productionCutover, false);
    assert.equal(result.receipt.godot.before.sha256, pinnedGodot.consoleSha256);
    assert.equal(result.receipt.godot.unchanged, true);
    assert.equal(result.receipt.fixture.before.sha256.length, 64);
    assert.equal(result.receipt.fixture.unchanged, true);
    assert.equal(result.receipt.nativeBuild.before.sha256.length, 64);
    assert.equal(result.receipt.nativeBuild.unchanged, true);
    assert.equal(result.receipt.toolchainLock.unchanged, true);
    assert.equal(result.receipt.ownedProcess.cleanShutdown, true);
    assert.equal(result.receipt.authoritativeInputs.unchanged, true);
    assert(result.receipt.checks.every(check => check.passed));
    assert.equal(JSON.parse(await readFile(result.receiptPath, 'utf8')).status, 'passed');
  } finally { await context.cleanup(); }
});

test('fixture and native-build validators reject invalid evidence independently', () => {
  const fixture = fixtureReport();
  const fixtureExpected = {
    nativeAdapterIdentity: binaryInput.sha256,
    querySetIdentity: goldensInput.sha256,
    queryCounts: expectedQueryCounts,
  };
  assert.deepEqual(validateFixtureReport(fixture, fixtureExpected), { valid: true, errors: [] });
  fixture.evidenceLevel = 'production';
  assert(validateFixtureReport(fixture, fixtureExpected).errors.includes('fixture_evidence_level_invalid'));
  fixture.evidenceLevel = evidenceLevel;
  fixture.godotVersion.patch = 5;
  assert(validateFixtureReport(fixture, fixtureExpected).errors.includes('fixture_godot_version_invalid'));
  Object.assign(fixture, fixtureReport({ status: 'passed', passed: false }));
  assert(validateFixtureReport(fixture, fixtureExpected).errors.includes('fixture_status_or_completion_invalid'));

  const native = nativeBuildReceipt();
  assert.deepEqual(validateNativeBuildReceipt(native, [joinedInput, binaryInput]), { valid: true, errors: [] });
  native.adapterSmoke.report.value.passed = false;
  assert(validateNativeBuildReceipt(native, [joinedInput, binaryInput]).errors.includes('native_adapter_smoke_not_passed'));
  native.adapterSmoke.report.value.passed = true;
  assert(validateNativeBuildReceipt(native, []).errors.includes('native_build_receipt_stale_for_current_inputs'));
});

test('fixture validator rejects semantic evidence gaps behind a nominal passed status', () => {
  const fixtureExpected = {
    nativeAdapterIdentity: binaryInput.sha256,
    querySetIdentity: goldensInput.sha256,
    queryCounts: expectedQueryCounts,
  };
  const cases = [
    [report => { report.finished = false; }, 'fixture_status_or_completion_invalid'],
    [report => { report.mismatchCount = 1; }, 'fixture_mismatch_count_invalid'],
    [report => { report.queryCounts.surfaceProjectionNumeric = 0; },
      'fixture_channel_query_counts_invalid'],
    [report => { report.checks.pinLifetime = false; }, 'fixture_explicit_checks_invalid'],
    [report => { report.nativeAdapterIdentity = 'not-a-digest'; }, 'fixture_native_adapter_identity_invalid'],
    [report => { report.nativeAdapterIdentity = '1'.repeat(64); }, 'fixture_native_adapter_identity_mismatch'],
    [report => { report.querySetIdentity = '1'.repeat(64); }, 'fixture_query_set_identity_mismatch'],
    [report => { report.productionCutover = true; }, 'fixture_production_cutover_invalid'],
  ];
  for (const [mutate, expectedError] of cases) {
    const report = fixtureReport();
    mutate(report);
    assert(validateFixtureReport(report, fixtureExpected).errors.includes(expectedError), expectedError);
  }
});

test('native receipt input join rejects omitted, duplicate, and unexpected paths', () => {
  const current = [joinedInput, binaryInput];
  const expected = [joinedInput.path];
  const omitted = nativeBuildReceipt();
  omitted.source.sources = [];
  assert(validateNativeBuildReceipt(omitted, current, expected).errors.includes('native_build_receipt_input_set_invalid'));

  const duplicate = nativeBuildReceipt();
  duplicate.source.sources.push({ ...joinedInput });
  assert(validateNativeBuildReceipt(duplicate, current, expected).errors.includes('native_build_receipt_input_paths_duplicate_or_invalid'));

  const unexpected = nativeBuildReceipt();
  unexpected.source.sources.push({ path: 'native/world_backend/core/unexpected.cpp', sha256: '1'.repeat(64), bytes: 1 });
  assert(validateNativeBuildReceipt(unexpected, current, expected).errors.includes('native_build_receipt_input_set_invalid'));
});

test('missing or invalid native receipt blocks launch', async t => {
  for (const mode of ['missing', 'invalid']) await t.test(mode, async () => {
    const context = await setup();
    try {
      if (mode === 'missing') context.argv.splice(4, 2);
      else await writeFile(context.nativeReceiptPath, '{invalid');
      const result = await runN3NativeEffectiveTerrainDifferential(context.argv, context.dependencies);
      assert.equal(result.receipt.status, 'failed');
      assert.equal(context.launched(), false);
      const errors = result.receipt.checks.find(check => check.name === 'nativeBuildReceipt').errors;
      assert(errors.includes(mode === 'missing' ? 'native_build_receipt_missing' : 'native_build_receipt_json_invalid'));
    } finally { await context.cleanup(); }
  });
});

test('mismatched Godot executable blocks launch', async () => {
  const context = await setup({ godotSha256: '0'.repeat(64) });
  try {
    const result = await runN3NativeEffectiveTerrainDifferential(context.argv, context.dependencies);
    assert.equal(result.receipt.status, 'failed');
    assert.equal(context.launched(), false);
    assert(result.receipt.checks.find(check => check.name === 'godotExecutablePin').errors.includes('godot_console_sha256_mismatch'));
  } finally { await context.cleanup(); }
});

test('Godot executable identity changing during the run fails the receipt', async () => {
  const context = await setup({ godotSha256After: '0'.repeat(64) });
  try {
    const result = await runN3NativeEffectiveTerrainDifferential(context.argv, context.dependencies);
    assert.equal(result.receipt.status, 'failed');
    assert(result.receipt.checks.find(check => check.name === 'godotExecutableUnchanged')
      .errors.includes('godot_console_changed_during_run'));
  } finally { await context.cleanup(); }
});

test('an existing output directory is rejected before evidence can be overwritten', async () => {
  const context = await setup();
  try {
    await mkdir(context.output);
    await assert.rejects(
      runN3NativeEffectiveTerrainDifferential(context.argv, context.dependencies),
      /output directory already exists/,
    );
    assert.equal(context.launched(), false);
  } finally { await context.cleanup(); }
});

test('fixture failure is recorded after a clean owned-process run', async () => {
  const context = await setup({ fixture: fixtureReport({ status: 'failed', passed: false }) });
  try {
    const result = await runN3NativeEffectiveTerrainDifferential(context.argv, context.dependencies);
    assert.equal(context.launched(), true);
    assert.equal(result.receipt.status, 'failed');
    assert(result.receipt.checks.find(check => check.name === 'fixtureReport').errors.includes('fixture_status_or_completion_invalid'));
  } finally { await context.cleanup(); }
});

test('authoritative input changes invalidate otherwise passing evidence', async () => {
  const context = await setup({ inventory: call => inputInventory((call === 1 ? 'a' : 'b').repeat(64)) });
  try {
    const result = await runN3NativeEffectiveTerrainDifferential(context.argv, context.dependencies);
    assert.equal(context.launched(), true);
    assert.equal(result.receipt.status, 'failed');
    assert(result.receipt.checks.find(check => check.name === 'authoritativeInputsUnchanged').errors.includes('authoritative_inputs_changed'));
  } finally { await context.cleanup(); }
});

test('owned process failure and non-clean shutdown invalidate the receipt', async () => {
  const context = await setup({
    process: {
      overallExitCode: 1, functionalExitCode: 1, cleanupPassed: false,
      authoritativeZeroProven: false, forcedCleanup: true, cleanupUnresolved: true,
      finalJobMemberPids: [123],
    },
  });
  try {
    const result = await runN3NativeEffectiveTerrainDifferential(context.argv, context.dependencies);
    assert.equal(context.launched(), true);
    assert.equal(result.receipt.status, 'failed');
    const errors = result.receipt.checks.find(check => check.name === 'ownedProcess').errors;
    assert(errors.includes('owned_process_exit_failed'));
    assert(errors.includes('owned_process_shutdown_not_clean'));
  } finally { await context.cleanup(); }
});

test('toolchain lock and native receipt changes during Godot execution are rejected', async t => {
  for (const [name, overrides, check, error] of [
    ['lock', { mutateLock: true }, 'toolchainLockUnchanged', 'toolchain_lock_changed_during_run'],
    ['native receipt', { mutateNativeReceipt: true }, 'nativeBuildReceiptUnchanged', 'native_build_receipt_changed_during_run'],
  ]) await t.test(name, async () => {
    const context = await setup(overrides);
    try {
      const result = await runN3NativeEffectiveTerrainDifferential(context.argv, context.dependencies);
      assert.equal(context.launched(), true);
      assert.equal(result.receipt.status, 'failed');
      assert(result.receipt.checks.find(candidate => candidate.name === check).errors.includes(error));
    } finally { await context.cleanup(); }
  });
});

test('real authoritative inventory refuses missing N3 fixture, oracle, or goldens', async t => {
  const required = [
    'scripts/testing/native_world/N3EffectiveTerrainAdapterFixture.gd',
    'scripts/testing/native_world/N3EffectiveTerrainOracleContract.gd',
    'scripts/testing/native_world/N3EffectiveTerrainOracle.gd',
    'scripts/testing/native_world/N3EffectiveTerrainGoldens.json',
  ];
  for (const missing of required) await t.test(missing.split('/').at(-1), async () => {
    const project = await mkdtemp(join(tmpdir(), 'n3-real-inventory-'));
    try {
      for (const path of authoritativeStaticPaths) {
        if (path === missing) continue;
        const absolute = join(project, ...path.split('/'));
        await mkdir(dirname(absolute), { recursive: true });
        await writeFile(absolute, 'fixture');
      }
      await mkdir(join(project, 'native', 'terrain_meshing', 'src'), { recursive: true });
      await mkdir(join(project, 'scripts', 'terrain'), { recursive: true });
      await writeFile(join(project, 'native', 'world_backend', 'source-manifest.json'), JSON.stringify({
        schema: 'native-world-backend-source-manifest/v1',
        coreSources: [], coreHeaders: [], testSources: [], testHeaders: [],
      }));
      await assert.rejects(inventoryAuthoritativeInputs(project), new RegExp(missing.replaceAll('/', '[\\\\/]')));
    } finally { await rm(project, { recursive: true, force: true }); }
  });
});

test('authoritative inventory includes transitive production oracle dependencies', () => {
  for (const path of [
    'scripts/world/BiomeRegionField.gd',
    'scripts/world/BuildingTerrainProfile.gd',
    'scripts/world/BuildingGroundMask.gd',
    'scripts/world/CitadelSiteField.gd',
    'scripts/world/CitadelSitePreparation.gd',
    'scripts/world/CitadelSiteSurvey.gd',
    'scripts/world/StandaloneStructureCandidate.gd',
    'scripts/buildings/BuildingSiteManifestBuilder.gd',
    'scripts/buildings/BuildingBlueprint.gd',
    'scripts/buildings/BuildingPart.gd',
    'scripts/buildings/FurnishingPlan.gd',
    'scripts/buildings/FurnishingPart.gd',
    'scripts/buildings/layout/BuildingLayoutConstants.gd',
  ]) assert(authoritativeStaticPaths.includes(path), path);
});

test('stderr must be byte-empty and evidence schemas remain stable', async () => {
  const context = await setup({ stderr: 'engine warning\n' });
  try {
    const result = await runN3NativeEffectiveTerrainDifferential(context.argv, context.dependencies);
    assert.equal(result.receipt.status, 'failed');
    assert(result.receipt.checks.find(check => check.name === 'emptyStderr').errors.includes('stderr_not_empty'));
    assert.equal(receiptSchema, 'n3-native-effective-terrain-differential-receipt/v1');
    assert.equal(fixtureSchema, 'n3-effective-terrain-differential-report/v1');
    assert.equal(evidenceLevel, 'shadow-only/no-production-cutover');
  } finally { await context.cleanup(); }
});

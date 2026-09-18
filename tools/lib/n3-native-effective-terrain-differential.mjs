import { createHash, randomUUID } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { access, mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { dirname, extname, isAbsolute, join, relative, resolve } from 'node:path';

import { runOwnedProcess } from './owned-process.mjs';
import { findGodot, parseArguments, projectRoot as defaultProjectRoot } from './voxel-tool-runtime.mjs';

export const receiptSchema = 'n3-native-effective-terrain-differential-receipt/v1';
export const fixtureSchema = 'n3-effective-terrain-differential-report/v1';
export const evidenceLevel = 'shadow-only/no-production-cutover';
export const fixtureScript = 'res://scripts/testing/native_world/N3EffectiveTerrainAdapterFixture.gd';
export const expectedQueryCounts = Object.freeze({
  surfaceColumns: 10,
  cellCenters: 11,
  latticeNumeric: 11,
  worldNumeric: 6,
  surfaceProjectionNumeric: 8,
});
const debugAdapterBinary = 'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll';

export const pinnedGodot = Object.freeze({
  version: '4.6.1.stable.official.14d19694e',
  major: 4,
  minor: 6,
  patch: 1,
  status: 'stable',
  hash: '14d19694e',
  engineCommitSha: '14d19694e0c88a3f9e82d899a0400f27a24c176e',
  consoleSha256: 'bd9e27c6994a128aaab45cdda4d372de87b91900618ba2de55c6aa29248d5b56',
});

export const nativeBuildStaticPaths = Object.freeze([
  'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
  'native/terrain_meshing/SConstruct',
  'native/terrain_meshing/godot-cpp-revision.txt',
  'native/terrain_meshing/scons_tools/windows.py',
  'native/world_backend/README.md',
  'native/world_backend/coverage_canary/coverage_canary.cpp',
  'native/world_backend/core/thirdparty/fast_noise_lite/LICENSE',
  'native/world_backend/source-manifest.json',
  'native/world_backend/toolchain-lock.json',
  'scripts/testing/native_world/NativeWorldBackendAdapterSmoke.gd',
  'tools/run-native-world-backend-tests.mjs',
  'tools/lib/native-compiler-owned-wrapper.mjs',
  'tools/lib/native-world-backend-runner.mjs',
  'tools/lib/native-world-identity-reference.mjs',
  'tools/lib/owned-process.mjs',
  'tools/tests/native-world-backend-runner.test.mjs',
  'tools/tests/native-world-identity-reference.test.mjs',
]);

export const authoritativeStaticPaths = Object.freeze([
  ...nativeBuildStaticPaths,
  'project.godot',
  debugAdapterBinary,
  'scripts/WorldGenerationSystem.gd',
  'scripts/TerrainVolumeService.gd',
  'scripts/world/BiomeRegionField.gd',
  'scripts/world/BuildingTerrainProfile.gd',
  'scripts/world/BuildingGroundMask.gd',
  'scripts/testing/native_world/N3CoverageOracle.gd',
  'scripts/testing/native_world/N3EffectiveTerrainAdapterFixture.gd',
  'scripts/testing/native_world/N3EffectiveTerrainOracle.gd',
  'scripts/testing/native_world/N3EffectiveTerrainGoldens.json',
  'tools/run-n3-native-effective-terrain-differential.mjs',
  'tools/lib/n3-native-effective-terrain-differential.mjs',
  'tools/tests/n3-native-effective-terrain-differential.test.mjs',
]);

const defaultDependencies = {
  access,
  mkdir,
  readFile,
  readdir,
  stat,
  writeFile,
  findGodot,
  parseArguments,
  runOwnedProcess,
  defaultProjectRoot,
};

function normalizedProjectPath(project, path) {
  const value = relative(project, path).replaceAll('\\', '/');
  return value === '' || value === '..' || value.startsWith('../') ? path.replaceAll('\\', '/') : value;
}

async function existsWith(deps, path) {
  try {
    await deps.access(path, fsConstants.F_OK);
    return true;
  } catch {
    return false;
  }
}

async function sha256With(deps, path) {
  if (deps.hashFile) return deps.hashFile(path);
  return createHash('sha256').update(await deps.readFile(path)).digest('hex');
}

async function fileRecord(deps, project, configuredPath) {
  const absolutePath = resolve(project, configuredPath);
  const value = await deps.stat(absolutePath);
  if (!value.isFile()) throw new Error(`N3 authoritative input is not a file: ${configuredPath}`);
  return {
    path: normalizedProjectPath(project, absolutePath),
    absolutePath: absolutePath.replaceAll('\\', '/'),
    bytes: value.size,
    sha256: await sha256With(deps, absolutePath),
  };
}

async function filesBelow(deps, directory, extensions) {
  const result = [];
  for (const entry of await deps.readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) result.push(...await filesBelow(deps, path, extensions));
    else if (entry.isFile() && extensions.has(extname(entry.name).toLowerCase())) result.push(path);
  }
  return result;
}

function safeManifestPaths(manifest) {
  if (manifest?.schema !== 'native-world-backend-source-manifest/v1') {
    throw new Error('Unsupported native world source manifest schema.');
  }
  const paths = [];
  for (const group of ['coreSources', 'coreHeaders', 'testSources', 'testHeaders']) {
    if (!Array.isArray(manifest[group])) throw new Error(`Missing native source manifest group: ${group}`);
    for (const path of manifest[group]) {
      if (typeof path !== 'string' || !path || path.includes('\\') || isAbsolute(path)
          || path.split('/').some(segment => !segment || segment === '.' || segment === '..')) {
        throw new Error(`Unsafe native source manifest path: ${path}`);
      }
      paths.push(`native/world_backend/${path}`);
    }
  }
  return paths;
}

export async function inventoryAuthoritativeInputs(project, dependencies = {}) {
  const deps = { ...defaultDependencies, ...dependencies };
  const manifest = JSON.parse(await deps.readFile(resolve(project, 'native/world_backend/source-manifest.json'), 'utf8'));
  const extensionPaths = (await filesBelow(deps, resolve(project, 'native/terrain_meshing/src'), new Set(['.cpp', '.h', '.hpp'])))
    .map(path => normalizedProjectPath(project, path));
  const terrainScriptPaths = (await filesBelow(deps, resolve(project, 'scripts/terrain'), new Set(['.gd'])))
    .map(path => normalizedProjectPath(project, path));
  const manifestPaths = safeManifestPaths(manifest);
  const nativeBuildRequiredPaths = [...new Set([
    ...nativeBuildStaticPaths,
    ...manifestPaths,
    ...extensionPaths,
  ])].sort();
  const paths = [...new Set([
    ...authoritativeStaticPaths,
    ...manifestPaths,
    ...extensionPaths,
    ...terrainScriptPaths,
  ])].sort();
  const files = [];
  for (const path of paths) files.push(await fileRecord(deps, project, path));
  const aggregateSha256 = createHash('sha256')
    .update(files.map(row => `${row.path}\0${row.bytes}\0${row.sha256}\n`).join(''))
    .digest('hex');
  return {
    schema: 'n3-effective-terrain-authoritative-input-inventory/v1',
    files,
    nativeBuildRequiredPaths,
    aggregateSha256,
  };
}

function exactGodotVersion(version) {
  return version?.major === pinnedGodot.major
    && version?.minor === pinnedGodot.minor
    && version?.patch === pinnedGodot.patch
    && version?.status === pinnedGodot.status
    && (version?.hash === pinnedGodot.engineCommitSha || version?.hash === pinnedGodot.hash)
    && (version?.version === undefined || version.version === pinnedGodot.version);
}

export function validateToolchainLock(lock) {
  const errors = [];
  if (lock?.schema !== 'native-world-backend-toolchain-lock/v1') errors.push('toolchain_lock_schema_invalid');
  const godot = lock?.godot;
  for (const [field, expected] of Object.entries(pinnedGodot)) {
    if (godot?.[field] !== expected) errors.push(`toolchain_godot_${field}_invalid`);
  }
  return { valid: errors.length === 0, errors };
}

export function validateFixtureReport(report, expected = {}) {
  const errors = [];
  if (report?.schema !== fixtureSchema) errors.push('fixture_schema_invalid');
  if (report?.status !== 'passed' || report?.passed !== true || report?.finished !== true) {
    errors.push('fixture_status_or_completion_invalid');
  }
  if (report?.evidenceLevel !== evidenceLevel) errors.push('fixture_evidence_level_invalid');
  if (!exactGodotVersion(report?.godotVersion)) errors.push('fixture_godot_version_invalid');
  if (report?.mismatchCount !== 0) errors.push('fixture_mismatch_count_invalid');
  const queryCounts = report?.queryCounts;
  if (!queryCounts || Object.entries(expected.queryCounts ?? {}).length === 0
      || Object.entries(expected.queryCounts ?? {}).some(([channel, count]) =>
        !Number.isInteger(queryCounts[channel]) || queryCounts[channel] !== count)) {
    errors.push('fixture_channel_query_counts_invalid');
  }
  const fixtureChecks = report?.checks;
  if (!fixtureChecks || ['sourceParity', 'independentGoldens', 'mutationChecks', 'pinLifetime', 'noProductionMutation']
    .some(check => fixtureChecks[check] !== true)) {
    errors.push('fixture_explicit_checks_invalid');
  }
  if (!/^[0-9a-f]{64}$/.test(report?.nativeAdapterIdentity ?? '')) {
    errors.push('fixture_native_adapter_identity_invalid');
  } else if (!/^[0-9a-f]{64}$/.test(expected.nativeAdapterIdentity ?? '')
      || report.nativeAdapterIdentity !== expected.nativeAdapterIdentity) {
    errors.push('fixture_native_adapter_identity_mismatch');
  }
  if (!/^[0-9a-f]{64}$/.test(report?.querySetIdentity ?? '')) {
    errors.push('fixture_query_set_identity_invalid');
  } else if (!/^[0-9a-f]{64}$/.test(expected.querySetIdentity ?? '')
      || report.querySetIdentity !== expected.querySetIdentity) {
    errors.push('fixture_query_set_identity_mismatch');
  }
  if (report?.productionCutover !== false) errors.push('fixture_production_cutover_invalid');
  return { valid: errors.length === 0, errors };
}

function receiptInputRows(report) {
  const before = report?.projectInputs?.before ?? {};
  return [
    ...(report?.source?.sources ?? []),
    ...(before.extensionSources ?? []),
    ...(before.extensionHeaders ?? []),
    ...(before.extensionBuildInputs ?? []),
    ...(before.n1Inputs ?? []),
  ];
}

function inferredNativeBuildPaths(currentInputFiles) {
  const staticPaths = new Set(nativeBuildStaticPaths);
  return currentInputFiles.map(row => row.path).filter(path => staticPaths.has(path)
    || path.startsWith('native/world_backend/core/')
    || path.startsWith('native/world_backend/tests/')
    || path.startsWith('native/terrain_meshing/src/'));
}

export function validateNativeBuildReceipt(report, currentInputFiles = [], requiredInputPaths = null) {
  const errors = [];
  if (report?.schema !== 'native-world-backend-n1-receipt/v1' || report?.status !== 'passed') {
    errors.push('native_build_receipt_not_passed');
  }
  if (report?.source?.unchanged !== true || report?.projectInputs?.unchanged !== true) {
    errors.push('native_build_inputs_not_immutable');
  }
  if (report?.adapterSmoke?.report?.value?.passed !== true
      || report?.adapterSmoke?.report?.value?.schema !== 'native-world-backend-adapter-smoke-report/v1') {
    errors.push('native_adapter_smoke_not_passed');
  }
  const smokeVersion = report?.adapterSmoke?.report?.value?.engineVersion;
  if (!exactGodotVersion(smokeVersion)
      || report?.adapterSmoke?.godot?.sha256 !== pinnedGodot.consoleSha256
      || report?.adapterSmoke?.godot?.pinnedVersion !== pinnedGodot.version) {
    errors.push('native_adapter_smoke_godot_pin_invalid');
  }
  if (report?.coverage?.status !== 'passed' || report?.coverage?.denominatorValidated !== true) {
    errors.push('native_build_coverage_not_passed');
  }
  const configurations = report?.configurations;
  if (!Array.isArray(configurations) || configurations.length !== 2
      || !['debug', 'release'].every(name => configurations.some(configuration =>
        configuration?.configuration === name && configuration?.tests?.failed === 0
        && Number.isInteger(configuration?.tests?.total) && configuration.tests.total > 0
        && configuration.tests.passed === configuration.tests.total))) {
    errors.push('native_debug_release_tests_not_passed');
  }
  const current = new Map(currentInputFiles.map(row => [row.path, row]));
  const joined = receiptInputRows(report);
  const joinedPaths = joined.map(row => row?.path);
  const expectedPaths = [...new Set(requiredInputPaths ?? inferredNativeBuildPaths(currentInputFiles))].sort();
  if (joinedPaths.some(path => typeof path !== 'string') || new Set(joinedPaths).size !== joinedPaths.length) {
    errors.push('native_build_receipt_input_paths_duplicate_or_invalid');
  }
  if (joinedPaths.length === 0 || JSON.stringify([...new Set(joinedPaths)].sort()) !== JSON.stringify(expectedPaths)) {
    errors.push('native_build_receipt_input_set_invalid');
  }
  if (joined.some(row => {
    const candidate = current.get(row?.path);
    return !candidate || candidate.sha256 !== row.sha256 || candidate.bytes !== row.bytes;
  })) {
    errors.push('native_build_receipt_stale_for_current_inputs');
  }
  const currentBinary = current.get(debugAdapterBinary);
  const installedBinary = (report?.installed ?? []).find(row => row?.name === debugAdapterBinary.split('/').at(-1));
  if (!currentBinary || !installedBinary || installedBinary.sha256 !== currentBinary.sha256
      || installedBinary.bytes !== currentBinary.bytes
      || !/^[0-9a-f]{64}$/.test(installedBinary.buildManifestSha256 ?? '')
      || !/^[0-9a-f]{64}$/.test(installedBinary.inputsDigestSha256 ?? '')
      || !/^[0-9a-f]{64}$/.test(installedBinary.pureCoreInputsDigestSha256 ?? '')) {
    errors.push('installed_debug_adapter_not_bound_to_receipt');
  }
  return { valid: errors.length === 0, errors };
}

export function validateOwnedProcess(summary) {
  const errors = [];
  if (summary?.overallExitCode !== 0 || summary?.functionalExitCode !== 0) errors.push('owned_process_exit_failed');
  if (summary?.cleanupPassed !== true || summary?.authoritativeZeroProven !== true
      || summary?.forcedCleanup !== false || summary?.cleanupUnresolved === true
      || !Array.isArray(summary?.finalJobMemberPids) || summary.finalJobMemberPids.length !== 0) {
    errors.push('owned_process_shutdown_not_clean');
  }
  return { valid: errors.length === 0, errors };
}

async function optionalEvidenceFile(deps, project, path) {
  if (!path || !await existsWith(deps, path)) return { path: path ? normalizedProjectPath(project, path) : null, present: false };
  const value = await deps.stat(path);
  return {
    path: normalizedProjectPath(project, path),
    absolutePath: resolve(path).replaceAll('\\', '/'),
    present: true,
    bytes: value.size,
    sha256: await sha256With(deps, path),
  };
}

async function parseJsonEvidence(deps, path, missingError, invalidError) {
  if (!path || !await existsWith(deps, path)) return { value: null, error: missingError };
  try {
    return { value: JSON.parse(await deps.readFile(path, 'utf8')), error: null };
  } catch {
    return { value: null, error: invalidError };
  }
}

async function snapshotJsonEvidence(deps, project, path, missingError, invalidError) {
  if (!path || !await existsWith(deps, path)) {
    return { value: null, error: missingError, record: { path: path ? normalizedProjectPath(project, path) : null, present: false } };
  }
  try {
    const bytes = await deps.readFile(path);
    const record = {
      path: normalizedProjectPath(project, path),
      absolutePath: resolve(path).replaceAll('\\', '/'),
      present: true,
      bytes: bytes.length,
      sha256: createHash('sha256').update(bytes).digest('hex'),
    };
    try {
      return { value: JSON.parse(bytes.toString('utf8')), error: null, record };
    } catch {
      return { value: null, error: invalidError, record };
    }
  } catch {
    return { value: null, error: missingError, record: { path: normalizedProjectPath(project, path), present: false } };
  }
}

function evidenceSnapshotUnchanged(before, after) {
  return before?.record?.present === true && after?.record?.present === true
    && before.record.bytes === after.record.bytes && before.record.sha256 === after.record.sha256;
}

export async function runN3NativeEffectiveTerrainDifferential(argv = process.argv.slice(2), dependencies = {}) {
  const deps = { ...defaultDependencies, ...dependencies };
  const { options } = deps.parseArguments(argv);
  const project = resolve(String(options.projectPath ?? deps.defaultProjectRoot));
  const runName = String(options.runName ?? `n3-effective-terrain-differential-${new Date().toISOString().replace(/[:.]/g, '-')}-${randomUUID().slice(0, 8)}`);
  const output = resolve(project, String(options.outputDir ?? join('artifacts', 'native-world-backend', runName)));
  if (await existsWith(deps, output)) throw new Error(`N3 differential output directory already exists: ${output}`);
  await deps.mkdir(dirname(output), { recursive: true });
  await deps.mkdir(output, { recursive: false });

  const receiptPath = join(output, 'receipt.json');
  const reportPath = join(output, 'fixture-report.json');
  const stdoutPath = join(output, 'godot.stdout.log');
  const stderrPath = join(output, 'godot.stderr.log');
  const summaryPath = join(output, 'godot.watchdog.json');
  const checks = [];
  const addCheck = (name, valid, errors = []) => checks.push({ name, passed: valid === true, errors: [...errors] });

  const inventory = dependencies.inventoryAuthoritativeInputs ?? ((root) => inventoryAuthoritativeInputs(root, deps));
  const inputsBefore = await inventory(project);
  const inputRecord = path => inputsBefore.files.find(row => row.path === path) ?? null;
  const fixtureExpectations = {
    nativeAdapterIdentity: inputRecord(debugAdapterBinary)?.sha256 ?? null,
    querySetIdentity: inputRecord('scripts/testing/native_world/N3EffectiveTerrainGoldens.json')?.sha256 ?? null,
    queryCounts: expectedQueryCounts,
  };
  const lockPath = resolve(project, 'native/world_backend/toolchain-lock.json');
  const lockBefore = await snapshotJsonEvidence(deps, project, lockPath, 'toolchain_lock_missing', 'toolchain_lock_json_invalid');
  const lockValidation = lockBefore.value ? validateToolchainLock(lockBefore.value) : { valid: false, errors: [lockBefore.error] };
  addCheck('toolchainLock', lockValidation.valid, lockValidation.errors);

  const nativeBuildPath = options.nativeBuildReport ? resolve(project, String(options.nativeBuildReport)) : null;
  const nativeBefore = await snapshotJsonEvidence(deps, project, nativeBuildPath,
    'native_build_receipt_missing', 'native_build_receipt_json_invalid');
  const nativeValidation = nativeBefore.value
    ? validateNativeBuildReceipt(nativeBefore.value, inputsBefore.files, inputsBefore.nativeBuildRequiredPaths)
    : { valid: false, errors: [nativeBefore.error] };
  addCheck('nativeBuildReceipt', nativeValidation.valid, nativeValidation.errors);

  let godotPath = null;
  let godotBefore = null;
  let godotError = null;
  try {
    godotPath = await deps.findGodot(options.godotExe);
    godotBefore = await fileRecord(deps, project, godotPath);
    if (godotBefore.sha256 !== pinnedGodot.consoleSha256) godotError = 'godot_console_sha256_mismatch';
  } catch {
    godotError = 'godot_console_unavailable';
  }
  addCheck('godotExecutablePin', godotError === null, godotError ? [godotError] : []);

  let summary = null;
  let fixture = null;
  let fixtureBefore = null;
  let fixtureValidation = { valid: false, errors: ['fixture_not_run'] };
  const preflightPassed = checks.every(check => check.passed);
  if (preflightPassed) {
    summary = await deps.runOwnedProcess({
      projectPath: project,
      executable: godotPath,
      args: ['--headless', '--audio-driver', 'Dummy', '--path', project, '--script', fixtureScript],
      env: {
        ...process.env,
        N3_EFFECTIVE_TERRAIN_DIFFERENTIAL_REPORT: reportPath,
        VOXEL_DISABLE_AUDIO_PLAYBACK: '1',
      },
      timeoutSeconds: Number(options.timeoutSeconds ?? 30),
      cleanupGraceMilliseconds: 3000,
      stdoutPath,
      stderrPath,
      summaryPath,
    });
    const processValidation = validateOwnedProcess(summary);
    addCheck('ownedProcess', processValidation.valid, processValidation.errors);
    fixtureBefore = await snapshotJsonEvidence(deps, project, reportPath,
      'fixture_report_missing', 'fixture_report_json_invalid');
    fixture = fixtureBefore.value;
    fixtureValidation = fixture
      ? validateFixtureReport(fixture, fixtureExpectations)
      : { valid: false, errors: [fixtureBefore.error] };
    addCheck('fixtureReport', fixtureValidation.valid, fixtureValidation.errors);
    const stderr = await existsWith(deps, stderrPath) ? await deps.readFile(stderrPath, 'utf8') : null;
    addCheck('emptyStderr', stderr === '', stderr === '' ? [] : [stderr === null ? 'stderr_log_missing' : 'stderr_not_empty']);
  } else {
    addCheck('ownedProcess', false, ['preflight_failed']);
    addCheck('fixtureReport', false, ['preflight_failed']);
    addCheck('emptyStderr', false, ['preflight_failed']);
  }

  const lockAfter = await snapshotJsonEvidence(deps, project, lockPath, 'toolchain_lock_missing', 'toolchain_lock_json_invalid');
  const lockUnchanged = evidenceSnapshotUnchanged(lockBefore, lockAfter);
  addCheck('toolchainLockUnchanged', lockUnchanged, lockUnchanged ? [] : ['toolchain_lock_changed_during_run']);
  const nativeAfter = await snapshotJsonEvidence(deps, project, nativeBuildPath,
    'native_build_receipt_missing', 'native_build_receipt_json_invalid');
  const nativeUnchanged = evidenceSnapshotUnchanged(nativeBefore, nativeAfter);
  addCheck('nativeBuildReceiptUnchanged', nativeUnchanged, nativeUnchanged ? [] : ['native_build_receipt_changed_during_run']);
  let godotAfter = null;
  try {
    godotAfter = godotPath ? await fileRecord(deps, project, godotPath) : null;
  } catch {
    godotAfter = null;
  }
  const godotUnchanged = godotBefore !== null && godotAfter !== null
    && godotBefore.bytes === godotAfter.bytes && godotBefore.sha256 === godotAfter.sha256;
  addCheck('godotExecutableUnchanged', godotUnchanged,
    godotUnchanged ? [] : ['godot_console_changed_during_run']);
  const fixtureAfter = fixtureBefore
    ? await snapshotJsonEvidence(deps, project, reportPath, 'fixture_report_missing', 'fixture_report_json_invalid')
    : null;
  const fixtureUnchanged = fixtureBefore !== null && fixtureAfter !== null
    && evidenceSnapshotUnchanged(fixtureBefore, fixtureAfter);
  addCheck('fixtureReportUnchanged', fixtureUnchanged,
    fixtureUnchanged ? [] : ['fixture_report_changed_after_validation']);
  const inputsAfter = await inventory(project);
  const inputsUnchanged = inputsBefore.aggregateSha256 === inputsAfter.aggregateSha256;
  addCheck('authoritativeInputsUnchanged', inputsUnchanged, inputsUnchanged ? [] : ['authoritative_inputs_changed']);
  const passed = checks.every(check => check.passed);
  const receipt = {
    schema: receiptSchema,
    status: passed ? 'passed' : 'failed',
    runName,
    evidenceLevel,
    productionCutover: false,
    adapterLoadEvidence: {
      configuration: 'debug',
      debugGodotAdapterLoadingProven: passed,
      releaseEngineLoadingProven: false,
      scope: 'This shadow fixture loads only the editor/debug Godot adapter; release engine loading is a later gate.',
    },
    fixtureScript,
    project: project.replaceAll('\\', '/'),
    output: output.replaceAll('\\', '/'),
    checks,
    toolchainLock: { before: lockBefore.record, after: lockAfter.record, unchanged: lockUnchanged, validation: lockValidation },
    godot: {
      before: godotBefore,
      after: godotAfter,
      unchanged: godotUnchanged,
      pinned: pinnedGodot,
      exactPinMatched: godotError === null,
    },
    nativeBuild: { before: nativeBefore.record, after: nativeAfter.record, unchanged: nativeUnchanged, validation: nativeValidation },
    fixture: {
      before: fixtureBefore?.record ?? null,
      after: fixtureAfter?.record ?? null,
      unchanged: fixtureUnchanged,
      validation: fixtureValidation,
      value: fixture,
    },
    ownedProcess: { ...await optionalEvidenceFile(deps, project, summaryPath), cleanShutdown: summary ? validateOwnedProcess(summary).valid : false, summary },
    logs: {
      stdout: await optionalEvidenceFile(deps, project, stdoutPath),
      stderr: await optionalEvidenceFile(deps, project, stderrPath),
    },
    authoritativeInputs: { before: inputsBefore, after: inputsAfter, unchanged: inputsUnchanged },
  };
  await deps.writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, { flag: 'wx' });
  return { receipt, receiptPath };
}

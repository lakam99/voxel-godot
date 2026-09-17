import { createHash, randomUUID } from 'node:crypto';
import { execFile as execFileCallback } from 'node:child_process';
import { constants as fsConstants } from 'node:fs';
import { access, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { runOwnedProcess } from './owned-process.mjs';
import { findGodot, parseArguments, projectRoot as defaultProjectRoot } from './voxel-tool-runtime.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const execFile = promisify(execFileCallback);
export const receiptSchema = 'n2-native-world-vertical-slice-receipt/v1';
export const fixtureSchema = 'n2-native-world-vertical-slice-fixture/v1';
export const expectedNativeMethod = 'n2_prepare_vertical_slice';

export const inputPaths = [
  'docs/native_world_backend/N2_VERTICAL_SLICE_CONTRACT_2026-09-17.md',
  'native/terrain_meshing/SConstruct',
  'native/terrain_meshing/godot-cpp-revision.txt',
  'native/terrain_meshing/scons_tools/windows.py',
  'native/terrain_meshing/src/building_support_kernel.cpp',
  'native/terrain_meshing/src/building_support_kernel.h',
  'native/terrain_meshing/src/n2_vertical_slice_adapter.cpp',
  'native/terrain_meshing/src/n2_vertical_slice_adapter.h',
  'native/terrain_meshing/src/register_types.cpp',
  'native/terrain_meshing/src/register_types.h',
  'native/terrain_meshing/src/terrain_meshing_backend.cpp',
  'native/terrain_meshing/src/terrain_meshing_backend.h',
  'native/world_backend/source-manifest.json',
  'native/world_backend/toolchain-lock.json',
  'native/world_backend/README.md',
  'native/world_backend/coverage_canary/coverage_canary.cpp',
  'native/world_backend/core/authority.cpp',
  'native/world_backend/core/authority.hpp',
  'native/world_backend/core/coordinates.cpp',
  'native/world_backend/core/coordinates.hpp',
  'native/world_backend/core/fast_noise_compat.cpp',
  'native/world_backend/core/fast_noise_compat.hpp',
  'native/world_backend/core/legacy_seed_hash.cpp',
  'native/world_backend/core/legacy_seed_hash.hpp',
  'native/world_backend/core/sha256.cpp',
  'native/world_backend/core/sha256.hpp',
  'native/world_backend/core/terrain_meshing.cpp',
  'native/world_backend/core/terrain_meshing.hpp',
  'native/world_backend/core/terrain_snapshot.cpp',
  'native/world_backend/core/terrain_snapshot.hpp',
  'native/world_backend/core/terrain_source.cpp',
  'native/world_backend/core/terrain_source.hpp',
  'native/world_backend/core/thirdparty/fast_noise_lite/FastNoiseLite.h',
  'native/world_backend/core/thirdparty/fast_noise_lite/LICENSE',
  'native/world_backend/core/world_identity.cpp',
  'native/world_backend/core/world_identity.hpp',
  'native/world_backend/tests/terrain_meshing_tests.cpp',
  'native/world_backend/tests/terrain_source_tests.cpp',
  'native/world_backend/tests/test_harness.hpp',
  'native/world_backend/tests/test_main.cpp',
  'native/world_backend/tests/world_backend_core_tests.cpp',
  'scripts/testing/native_world/NativeWorldBackendAdapterSmoke.gd',
  'scripts/testing/native_world/N2LatticeSourceOracle.gd',
  'scripts/testing/native_world/N2PreparedRenderGenerator.gd',
  'scripts/testing/native_world/N2VerticalSliceFixture.gd',
  'scenes/testing/native_world/N2VerticalSliceFixture.tscn',
  'scripts/terrain/VoxelTerrainGenerator.gd',
  'scripts/terrain/VoxelTerrainRuntime.gd',
  'scripts/terrain/VoxelWorldGenerationContext.gd',
  'scripts/WorldGenerationSystem.gd',
  'addons/zylann.voxel/voxel.gdextension',
  'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
  'tools/run-n2-native-world-vertical-slice.mjs',
  'tools/run-native-world-backend-tests.mjs',
  'tools/lib/n2-native-world-vertical-slice.mjs',
  'tools/lib/native-compiler-owned-wrapper.mjs',
  'tools/lib/native-world-backend-runner.mjs',
  'tools/lib/native-world-identity-reference.mjs',
  'tools/lib/owned-process.mjs',
  'tools/lib/owned-native-host.mjs',
  'tools/lib/owned-live-clock.mjs',
  'tools/lib/voxel-tool-runtime.mjs',
  'tools/lib/godot-process.mjs',
  'tools/native/OwnedProcessNative.cs',
  'tools/native/OwnedProcessHost.cs',
  'tools/tests/n2-native-world-vertical-slice.test.mjs',
  'tools/tests/native-world-backend-runner.test.mjs',
  'tools/tests/native-world-identity-reference.test.mjs',
];

const binaryPaths = [
  'addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll',
  'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
  'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll.pdb',
  'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_release.x86_64.dll',
  'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_release.x86_64.dll.pdb',
  'native/terrain_meshing/build/world_backend/debug/build-manifest.json',
  'native/terrain_meshing/build/world_backend/release/build-manifest.json',
];

async function exists(path) {
  try { await access(path, fsConstants.F_OK); return true; } catch { return false; }
}

async function sha256(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

async function gitText(project, args) {
  const result = await execFile('git', args, { cwd: project, windowsHide: true, encoding: 'utf8' });
  return result.stdout.trim();
}

async function fileReceipt(project, configured) {
  const path = resolve(project, configured);
  const info = await stat(path);
  if (!info.isFile()) throw new Error(`N2 identity input is not a file: ${configured}`);
  return { path: relative(project, path).replaceAll('\\', '/'), bytes: info.size, sha256: await sha256(path) };
}

async function inventory(project, paths) {
  const files = [];
  for (const path of paths) files.push(await fileReceipt(project, path));
  const aggregateSha256 = createHash('sha256').update(files.map(row => `${row.path}\0${row.bytes}\0${row.sha256}\n`).join('')).digest('hex');
  return { files, aggregateSha256 };
}

export function validateFixtureReport(report) {
  const errors = [];
  if (!report || report.schema !== fixtureSchema || report.finished !== true) errors.push('fixture_schema_or_completion_invalid');
  const version = report?.godotVersion;
  if (version?.major !== 4 || version?.minor !== 6 || version?.patch !== 1
      || version?.hash !== '14d19694e0c88a3f9e82d899a0400f27a24c176e') errors.push('pinned_godot_version_invalid');
  const evidence = report?.evidence;
  const oracle = evidence?.oracle;
  if (!oracle || oracle.sampleCount !== 33915 || oracle.ordering !== 'x_fastest_then_z_then_y') errors.push('oracle_denominator_invalid');
  if (!oracle || oracle.forbiddenOraclePathsUsed !== false) errors.push('oracle_forbidden_path_evidence_invalid');
  const noises = oracle?.noiseFloatBits;
  const noiseConfigurations = new Map([['height', 1769607420], ['ridge', 1769813314], ['flat', 1770035046], ['moisture', 1770320130], ['temperature', 1770510186]]);
  if (!Array.isArray(noises) || noises.length !== 20 || [...noiseConfigurations].some(([name, seed]) =>
    noises.filter(row => row?.configuration === name && row?.seed === seed
      && Number.isInteger(row?.twoDBits) && row.twoDBits >= 0 && row.twoDBits <= 0xffffffff
      && Number.isInteger(row?.threeDBits) && row.threeDBits >= 0 && row.threeDBits <= 0xffffffff
      && Array.isArray(row?.coordinate) && row.coordinate.length === 3).length !== 4)) errors.push('raw_noise_bit_fixture_invalid');
  const deltas = oracle?.typedDeltas;
  const expectedDeltaCoordinates = ['-33,12,-5', '-32,12,-5', '-33,12,-4', '-32,12,-4'];
  if (!Array.isArray(deltas?.records) || deltas.records.length !== 4 || !/^[0-9a-f]{64}$/.test(deltas?.sha256 ?? '')
      || !Number.isInteger(deltas?.byteLength) || deltas.byteLength <= 0
      || deltas.records.some((row, index) => row?.coordinate?.join(',') !== expectedDeltaCoordinates[index]
        || row?.density !== -1.35 || row?.solid !== false || row?.materialId !== 0 || row?.materialName !== 'air'
        || row?.surfaceBiomeId !== 2 || row?.surfaceBiomeName !== 'swamp'
        || row?.resolvedBiomeId !== 13 || row?.resolvedBiomeName !== 'underground_air'
        || row?.fluidId !== 0 || row?.fluid !== '' || row?.deltaId !== `n2:seam-air:${index}` || row?.deltaRevision !== 1)) {
    errors.push('typed_delta_reload_evidence_invalid');
  }
  const expected = evidence?.expectedNativeApi;
  if (expected?.method !== expectedNativeMethod || expected?.requestSchema !== 'n2-native-vertical-slice-request/v1'
      || expected?.resultSchema !== 'n2-native-vertical-slice-result/v1' || expected?.preparedPayloadCapBytes !== 4194304) errors.push('expected_native_api_schema_invalid');
  if (report?.passed === true) {
    const authority = evidence?.authority;
    if (authority?.staticBodyCount !== 1 || authority?.projectOwnedTerrainBodies !== 1
        || authority?.voxelTerrainCollisionEnabled !== false || authority?.installedShapeCount !== 3) errors.push('one_authority_evidence_invalid');
    if (evidence?.render?.consumer !== 'VoxelTerrain/VoxelBuffer/VoxelMesherTransvoxel'
        || evidence?.render?.collisionDisabled !== true) errors.push('voxel_render_consumer_evidence_invalid');
    if (evidence?.nativeBaseline?.sampleCount !== 33915 || evidence?.nativeEdited?.sampleCount !== 33915) errors.push('ordered_native_parity_invalid');
    for (const native of [evidence?.nativeBaseline, evidence?.nativeEdited]) {
      const usage = native?.resourceUsage;
      const usageFields = ['admittedRequests', 'peakInFlightBuilds', 'preparedResults', 'preparedBytes',
        'installedBodiesExpected', 'installedShapesExpected', 'collisionTriangles', 'retiredShapeSetsAwaitingRelease'];
      if (!usage || usageFields.some(field => !Number.isInteger(usage[field]) || usage[field] < 0)
          || usage.admittedRequests !== 1 || usage.peakInFlightBuilds !== 1 || usage.preparedResults !== 1
          || usage.preparedBytes !== native.preparedPayloadBytes || usage.installedBodiesExpected !== 1
          || usage.installedShapesExpected !== 3 || usage.collisionTriangles > 200000
          || usage.retiredShapeSetsAwaitingRelease !== 0) errors.push('native_resource_caps_invalid');
      const accounting = native?.preparedPayloadAccounting;
      const accountingFields = ['sourcePackedColumnsBytes', 'renderPackedBytes', 'collisionPackedBytes', 'stringBytes',
        'sparseMetadataBytes', 'blockerGeometryBytes', 'noiseFixtureBytes'];
      if (!accounting || accounting.scope !== 'native variable payload; excludes Variant container overhead and fixed object headers'
          || accounting.total !== native.preparedPayloadBytes
          || accountingFields.some(field => !Number.isInteger(accounting[field]) || accounting[field] < 0)
          || accountingFields.reduce((sum, field) => sum + (accounting?.[field] ?? 0), 0) !== accounting?.total) {
        errors.push('prepared_payload_accounting_invalid');
      }
    }
    if (!['-3,-1', '-2,-1'].every(key => /^[0-9a-f]{64}$/.test(evidence?.nativeBaseline?.tileGeometrySha256?.[key] ?? '')
        && /^[0-9a-f]{64}$/.test(evidence?.nativeEdited?.tileGeometrySha256?.[key] ?? '')
        && evidence.nativeBaseline.tileGeometrySha256[key] !== evidence.nativeEdited.tileGeometrySha256[key])) errors.push('both_tile_artifact_changes_invalid');
    if (!Number.isInteger(evidence?.acknowledgedPhysicsFrame) || evidence.acknowledgedPhysicsFrame < 0) errors.push('physics_acknowledgement_invalid');
    if (evidence?.physics?.ok !== true) errors.push('direct_physics_evidence_invalid');
    if (evidence?.staleBeforeAck?.reason !== 'stale_before_acknowledgement') errors.push('stale_before_ack_rejection_invalid');
    if (evidence?.staleBeforeInstall?.reason !== 'stale_before_install') errors.push('stale_before_install_rejection_invalid');
    if (evidence?.crossSeamPhysics?.changed !== true
        || evidence?.crossSeamPhysics?.allHitsOwnedBySoleBody !== true) errors.push('cross_seam_pre_post_physics_invalid');
    if (evidence?.render?.requiredSnapshotGap !== '') errors.push('render_required_snapshot_gap');
    const timing = evidence?.timing;
    const timingFields = ['requestValidationMilliseconds', 'deltaResolutionMilliseconds', 'sourceMilliseconds',
      'collisionMilliseconds', 'renderPackMilliseconds', 'hydrationMilliseconds', 'renderConsumptionWaitMilliseconds',
      'installMilliseconds', 'acknowledgementMilliseconds', 'totalMilliseconds'];
    if (!timing || timingFields.some(field => !Number.isFinite(timing[field]) || timing[field] < 0)
        || timing.totalMilliseconds > 10000) errors.push('stage_timing_evidence_invalid');
    const lifecycle = evidence?.resourceLifecycle;
    if (!lifecycle || lifecycle.admittedRequests !== 2 || lifecycle.currentInFlightBuilds !== 0
        || lifecycle.peakInFlightBuilds !== 1 || lifecycle.currentPreparedResults !== 0
        || lifecycle.peakPreparedResults !== 1 || lifecycle.currentPreparedBytes !== 0
        || !Number.isInteger(lifecycle.peakPreparedBytes) || lifecycle.peakPreparedBytes <= 0
        || lifecycle.peakPreparedBytes > 4194304 || lifecycle.currentRetiredShapeSetsAwaitingRelease !== 0
        || lifecycle.peakRetiredShapeSetsAwaitingRelease > 1) errors.push('fixture_resource_lifecycle_invalid');
    for (const prepared of [evidence?.nativeBaseline?.preparedPayloadBytes, evidence?.nativeEdited?.preparedPayloadBytes]) {
      if (!Number.isInteger(prepared) || prepared <= 0 || prepared > 4194304) errors.push('prepared_payload_cap_invalid');
    }
  } else if (!String(report?.reason ?? '').startsWith(`missing_native_method:${expectedNativeMethod}`)
      && !String(report?.reason ?? '').startsWith('missing_native_class:')) {
    errors.push('fixture_failed_for_unexpected_reason');
  }
  return { valid: errors.length === 0, errors, nativeApiAvailable: report?.passed === true || !String(report?.reason ?? '').startsWith('missing_native_') };
}

export function validateNativeBuildReport(report, binaries, currentInputs = []) {
  const errors = [];
  if (report?.schema !== 'native-world-backend-n1-receipt/v1' || report?.status !== 'passed') errors.push('native_build_not_passed');
  if (report?.projectInputs?.unchanged !== true || report?.source?.unchanged !== true) errors.push('native_build_inputs_not_immutable');
  if (report?.adapterSmoke?.report?.value?.passed !== true) errors.push('native_adapter_smoke_not_passed');
  if (report?.coverage?.status !== 'passed' || report?.coverage?.denominatorValidated !== true) errors.push('native_coverage_not_passed');
  if (!Array.isArray(report?.configurations) || report.configurations.length !== 2
      || report.configurations.some(configuration => configuration?.tests?.failed !== 0
        || configuration?.tests?.passed !== configuration?.tests?.total)) errors.push('native_debug_release_tests_not_passed');
  const currentInputMap = new Map(currentInputs.map(row => [row.path, row]));
  const projectBuildInputs = report?.projectInputs?.before;
  const joinedInputs = [
    ...(report?.source?.sources ?? []),
    ...(projectBuildInputs?.extensionSources ?? []),
    ...(projectBuildInputs?.extensionHeaders ?? []),
    ...(projectBuildInputs?.extensionBuildInputs ?? []),
    ...(projectBuildInputs?.n1Inputs ?? []),
  ];
  if (joinedInputs.length === 0 || joinedInputs.some(row => {
    const current = currentInputMap.get(row?.path);
    return !current || current.sha256 !== row.sha256 || current.bytes !== row.bytes;
  })) errors.push('native_build_input_join_invalid');
  const installed = new Map((report?.installed ?? []).map(row => [row.name, row]));
  for (const binary of binaries.filter(row => row.path.includes('terrain_meshing_backend.windows.'))) {
    const row = installed.get(binary.path.split('/').at(-1));
    if (!row || row.sha256 !== binary.sha256 || row.bytes !== binary.bytes
        || !/^[0-9a-f]{64}$/.test(row.buildManifestSha256 ?? '')
        || !/^[0-9a-f]{64}$/.test(row.inputsDigestSha256 ?? '')
        || !/^[0-9a-f]{64}$/.test(row.pureCoreInputsDigestSha256 ?? '')) errors.push(`installed_native_binary_unbound:${binary.path}`);
  }
  return { valid: errors.length === 0, errors };
}

export async function runN2NativeWorldVerticalSlice(argv = process.argv.slice(2)) {
  const { options } = parseArguments(argv);
  const project = resolve(String(options.projectPath ?? defaultProjectRoot));
  const runName = String(options.runName ?? `n2-vertical-slice-${new Date().toISOString().replace(/[:.]/g, '-')}-${randomUUID().slice(0, 8)}`);
  const output = resolve(project, String(options.outputDir ?? join('artifacts', 'native-world-backend', runName)));
  if (await exists(output)) throw new Error(`N2 output directory already exists: ${output}`);
  await mkdir(output, { recursive: false });
  const reportPath = join(output, 'fixture-report.json');
  const screenshotPath = join(output, 'fixture.png');
  const receiptPath = join(output, 'receipt.json');
  const stdoutPath = join(output, 'godot.stdout.log');
  const stderrPath = join(output, 'godot.stderr.log');
  const summaryPath = join(output, 'godot.watchdog.json');
  const gitBefore = { commit: await gitText(project, ['rev-parse', 'HEAD']), branch: await gitText(project, ['branch', '--show-current']),
    status: await gitText(project, ['status', '--short']) };
  const inputsBefore = await inventory(project, inputPaths);
  const binaries = await inventory(project, binaryPaths);
  const nativeBuildReportPath = options.nativeBuildReport ? resolve(project, String(options.nativeBuildReport)) : null;
  const nativeBuildReport = nativeBuildReportPath && await exists(nativeBuildReportPath)
    ? JSON.parse(await readFile(nativeBuildReportPath, 'utf8')) : null;
  const nativeBuildValidation = validateNativeBuildReport(nativeBuildReport, binaries.files, inputsBefore.files);
  const godot = await findGodot(options.godotExe);
  const godotReceipt = { path: godot, bytes: (await stat(godot)).size, sha256: await sha256(godot) };
  const toolchainLock = JSON.parse(await readFile(resolve(project, 'native/world_backend/toolchain-lock.json'), 'utf8'));
  if (godotReceipt.sha256 !== toolchainLock?.godot?.consoleSha256) throw new Error('N2 requires the exact Godot executable pinned by the native toolchain lock.');
  const summary = await runOwnedProcess({
    projectPath: project,
    executable: godot,
    args: ['--audio-driver', 'Dummy', '--path', project, 'res://scenes/testing/native_world/N2VerticalSliceFixture.tscn'],
    env: { ...process.env, N2_NATIVE_WORLD_REPORT: reportPath, N2_NATIVE_WORLD_SCREENSHOT: screenshotPath },
    timeoutSeconds: 15,
    cleanupGraceMilliseconds: 3000,
    stdoutPath, stderrPath, summaryPath,
  });
  const fixture = await exists(reportPath) ? JSON.parse(await readFile(reportPath, 'utf8')) : null;
  const validation = validateFixtureReport(fixture);
  const inputsAfter = await inventory(project, inputPaths);
  const inputsUnchanged = inputsBefore.aggregateSha256 === inputsAfter.aggregateSha256;
  const gitAfter = { commit: await gitText(project, ['rev-parse', 'HEAD']), branch: await gitText(project, ['branch', '--show-current']),
    status: await gitText(project, ['status', '--short']) };
  const gitCleanAndStable = gitBefore.commit === gitAfter.commit && gitBefore.branch === gitAfter.branch
    && gitBefore.status === '' && gitAfter.status === '';
  const ownedClean = summary.cleanupPassed && summary.authoritativeZeroProven && !summary.forcedCleanup;
  const stderrText = await readFile(stderrPath, 'utf8');
  const screenshotPresent = await exists(screenshotPath) && (await stat(screenshotPath)).size > 0;
  const passed = fixture?.passed === true && validation.valid && nativeBuildValidation.valid && inputsUnchanged && gitCleanAndStable && ownedClean
    && summary.functionalExitCode === 0 && stderrText.length === 0 && screenshotPresent;
  const blockedOnNativeApi = validation.valid && fixture?.passed === false && String(fixture?.reason ?? '').startsWith('missing_native_')
    && inputsUnchanged && ownedClean && stderrText.length === 0;
  const receipt = {
    schema: receiptSchema,
    status: passed ? 'passed' : blockedOnNativeApi ? 'blocked_native_api' : 'failed',
    runName,
    evidenceLevel: 'N2-only headed lattice parity and one-authority fixture; no production, NPC, navigation, or gameplay acceptance claim.',
    git: { before: gitBefore, after: gitAfter, cleanAndStable: gitCleanAndStable },
    expectedNativeApi: fixture?.evidence?.expectedNativeApi ?? { class: 'TerrainMeshingBackend', method: expectedNativeMethod },
    fixture: fixture ? { path: relative(project, reportPath).replaceAll('\\', '/'), sha256: await sha256(reportPath), value: fixture } : null,
    screenshot: screenshotPresent ? { path: relative(project, screenshotPath).replaceAll('\\', '/'), sha256: await sha256(screenshotPath) } : null,
    validation,
    nativeBuild: nativeBuildReportPath ? { path: relative(project, nativeBuildReportPath).replaceAll('\\', '/'),
      sha256: await sha256(nativeBuildReportPath), validation: nativeBuildValidation } : { path: null, validation: nativeBuildValidation },
    inputs: { before: inputsBefore, after: inputsAfter, unchanged: inputsUnchanged },
    binaries,
    godot: godotReceipt,
    ownedProcess: { path: relative(project, summaryPath).replaceAll('\\', '/'), summary, naturalZero: ownedClean },
    logs: {
      stdout: { path: relative(project, stdoutPath).replaceAll('\\', '/'), sha256: await sha256(stdoutPath) },
      stderr: { path: relative(project, stderrPath).replaceAll('\\', '/'), sha256: await sha256(stderrPath) },
    },
  };
  await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, { flag: 'wx' });
  return { receipt, receiptPath };
}

import { cp, lstat, mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { basename, dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { findGodot } from './voxel-tool-runtime.mjs';
import { runOwnedProcess as ownedProcess } from './owned-process.mjs';
import { assertNoReparseComponents, godotEngineSiblingPath, projectFingerprintBounds, projectInputManifest, sha256 as sha256BoundedFile } from './citadel-candidate-runner.mjs';

export const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const scene = 'res://scenes/testing/WorldStreamingMaturityLoading.tscn';
export const appDataSuffix = ['Godot', 'app_userdata', 'Voxel Biome World Godot'];
export const comparatorPolicy = Object.freeze({
  policyId: 'gate5-responsive-loading-2026-09-23',
  status: 'fixed_responsiveness_policy',
  passAffecting: {
    functionalReadiness: true,
    cleanLifecycle: true,
    emptyIsolatedColdProfile: true,
    immutableSavePairing: true,
    firstVisibleLoadingFrameMaxMs: 1000,
    loadingFrameP99MaxMs: 33,
    loadingFrameMaxMs: 100,
    progressHeartbeatMaxGapMs: 5000,
    loadingMainCallbackMaxMs: 33,
    noModalReentryAfterGameplayReady: true,
    duration: false,
  },
  provisionalReferencesOnly: {
    source: 'Historical G2 references only. User decision: loading total seconds are diagnostic, while visible responsiveness and complete readiness determine acceptance.',
    coldInputToGameplayReadyMs: 90000,
    warmInputToGameplayReadyMs: 45000,
    warmToPairedColdRatio: 1.10,
  },
  decisionRule: 'Every cold and warm sample must complete with visible responsive loading, honest source progress, full gameplay readiness and clean lifecycle. Total time and warm/cold ratio are diagnostic; watchdog timeout means noncompletion.',
});
export const loadingSaveBounds = Object.freeze({ activeSeedBytes: 4096, slotBytes: 64 * 1024 * 1024 });

function demand(condition, message) { if (!condition) throw new Error(message); }
function normalized(value) { return process.platform === 'win32' ? value.toLowerCase() : value; }
export function sha256Buffer(value) { return createHash('sha256').update(value).digest('hex'); }
export async function sha256File(file, maximumBytes = projectFingerprintBounds.maximumFileBytes) {
  return sha256BoundedFile(file, maximumBytes);
}
async function readUtf8Bounded(file, maximumBytes) {
  return new Promise((resolveText, reject) => {
    const stream = createReadStream(file);
    const chunks = [];
    let bytes = 0;
    stream.on('error', reject);
    stream.on('data', chunk => {
      bytes += chunk.length;
      if (bytes > maximumBytes) stream.destroy(new Error(`Text input exceeded ${maximumBytes} bytes: ${file}`));
      else chunks.push(chunk);
    });
    stream.on('end', () => resolveText(Buffer.concat(chunks).toString('utf8')));
  });
}
async function exists(file) { try { await stat(file); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; } }
async function writeJson(file, value) { await mkdir(dirname(file), { recursive: true }); await writeFile(file, JSON.stringify(value, null, 2) + '\n', 'utf8'); }
async function readJson(file) { return JSON.parse((await readFile(file, 'utf8')).replace(/^\uFEFF/, '')); }

export function parseLoadingMatrixOptions(argv) {
  const aliases = new Map([
    ['outputdirectory', 'outputDirectory'], ['knownseed', 'knownSeed'], ['resolution', 'resolution'],
    ['timeoutseconds', 'timeoutSeconds'], ['godotexe', 'godotExe'], ['dryrun', 'dryRun'],
    ['evaluationmode', 'evaluationMode'],
  ]);
  const result = {};
  for (let index = 0; index < argv.length; index++) {
    const match = /^--?([^=:]+)(?:[=:](.*))?$/.exec(argv[index]);
    demand(match, `Unknown positional argument: ${argv[index]}`);
    const key = aliases.get(match[1].replaceAll('-', '').toLowerCase());
    demand(key, `Unknown option: ${argv[index]}`);
    demand(!Object.hasOwn(result, key), `Duplicate option: ${match[1]}`);
    if (key === 'dryRun') {
      const value = match[2];
      demand(value === undefined || /^(1|0|true|false|\$true|\$false)$/i.test(value), 'DryRun must be a boolean switch.');
      result[key] = value === undefined || /^(1|true|\$true)$/i.test(value);
    } else {
      const value = match[2] ?? argv[++index];
      demand(value !== undefined && !/^--?[A-Za-z]/.test(value), `Missing value for ${match[1]}`);
      result[key] = value;
    }
  }
  demand(typeof result.outputDirectory === 'string' && result.outputDirectory.trim(), 'OutputDirectory is required.');
  result.knownSeed ??= 'gate5-loading-known-seed-v1';
  demand(result.knownSeed.length <= 128 && result.knownSeed.trim(), 'KnownSeed must be 1..128 characters.');
  result.resolution ??= '1920x1080';
  demand(['1280x720', '1920x1080'].includes(result.resolution), 'Resolution must be 1280x720 or 1920x1080.');
  result.timeoutSeconds = result.timeoutSeconds === undefined ? 330 : Number(result.timeoutSeconds);
  demand(Number.isInteger(result.timeoutSeconds) && result.timeoutSeconds >= 180 && result.timeoutSeconds <= 600, 'TimeoutSeconds must be an integer from 180 through 600.');
  result.evaluationMode ??= 'gate5';
  demand(['gate5', 'functional-diagnostic'].includes(result.evaluationMode), 'EvaluationMode must be gate5 or functional-diagnostic.');
  result.dryRun ??= false;
  return result;
}

export function buildSamplePlan(knownSeed, freshIds = [randomUUID(), randomUUID()]) {
  demand(Array.isArray(freshIds) && freshIds.length === 2 && freshIds.every(value => typeof value === 'string' && value), 'Two fresh seed IDs are required.');
  demand(new Set(freshIds).size === 2, 'Fresh seed IDs must be distinct.');
  const cold = [
    ...[1, 2, 3].map(index => ({ pairId: `known-${index}`, cohort: 'controlled_known_seed', requestedSeed: knownSeed })),
    ...freshIds.map((id, index) => ({ pairId: `fresh-${index + 1}`, cohort: 'fresh_seed', requestedSeed: `gate5-loading-fresh-${id}` })),
  ];
  return cold.flatMap(row => [
    { ...row, sampleId: `${row.pairId}-cold-new-game`, launchMode: 'new_game', cacheClassification: 'cold' },
    { ...row, sampleId: `${row.pairId}-warm-continue`, launchMode: 'continue', cacheClassification: 'warm_continue' },
  ]);
}

function git(project, args) { return execFileSync('git', ['-C', project, ...args], { encoding: 'utf8', windowsHide: true, maxBuffer: 64 * 1024 * 1024 }); }
export async function sourceManifest(project) {
  // This inventory is shared with the headed journey so Gate 5 cannot freeze
  // only GDScript/scenes while resources, shaders, assets, native inputs or the
  // runner change. Known runtime output/cache roots are excluded explicitly;
  // hard bounds fail closed rather than silently truncating the fingerprint.
  return projectInputManifest(project);
}

export function activeBinaryCandidates(project, godotExe) {
  return [
    ['godot', godotExe],
    ...(godotEngineSiblingPath(godotExe) ? [['godotEngine', godotEngineSiblingPath(godotExe)]] : []),
    ['voxelGdextensionDebug', join(project, 'addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll')],
    ['voxelGdextensionRelease', join(project, 'addons/zylann.voxel/bin/libvoxel.windows.template_release.x86_64.dll')],
    ['terrainMeshingGdextensionDebug', join(project, 'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll')],
    ['terrainMeshingGdextensionRelease', join(project, 'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_release.x86_64.dll')],
  ];
}

export async function binaryManifest(project, godotExe) {
  const candidates = activeBinaryCandidates(project, godotExe);
  const binaries = {};
  for (const [id, file] of candidates) {
    demand(await exists(file), `Required binary is missing: ${file}`);
    await assertNoReparseComponents(file, `Required binary ${id}`);
    const info = await lstat(file);
    demand(info.isFile() && !info.isSymbolicLink() && info.size <= projectFingerprintBounds.maximumFileBytes, `Required binary is invalid, symlinked, or exceeds the fingerprint bound: ${file}`);
    binaries[id] = { path: file, bytes: info.size, sha256: await sha256BoundedFile(file, projectFingerprintBounds.maximumFileBytes) };
  }
  return binaries;
}

export async function directoryInventory(root) {
  const files = [];
  let totalBytes = 0;
  async function visit(directory) {
    if (!(await exists(directory))) return;
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const absolute = join(directory, entry.name);
      if (entry.isSymbolicLink()) throw new Error(`Symlinked/reparse userdata entry is forbidden: ${absolute}`);
      if (entry.isDirectory()) await visit(absolute);
      else if (entry.isFile()) {
        demand(files.length < projectFingerprintBounds.maximumFileCount, 'Userdata inventory exceeds its file-count bound.');
        const info = await lstat(absolute);
        demand(info.size <= projectFingerprintBounds.maximumFileBytes, `Userdata file exceeds its per-file bound: ${absolute}`);
        totalBytes += info.size;
        demand(totalBytes <= projectFingerprintBounds.maximumTotalBytes, 'Userdata inventory exceeds its total-byte bound.');
        files.push({ path: relative(root, absolute).replaceAll('\\', '/'), bytes: info.size,
          sha256: await sha256BoundedFile(absolute, projectFingerprintBounds.maximumFileBytes) });
      }
      else throw new Error(`Unsupported userdata entry: ${absolute}`);
    }
  }
  await visit(root);
  files.sort((left, right) => left.path.localeCompare(right.path));
  return { root, empty: files.length === 0, fileCount: files.length, totalBytes, bounds: projectFingerprintBounds,
    files, aggregateSha256: sha256Buffer(files.map(row => `${row.path}\0${row.bytes}\0${row.sha256}\n`).join('')) };
}

export function directoryInventoriesEqual(left, right) {
  return Number(left?.fileCount ?? -1) === Number(right?.fileCount ?? -2)
    && left?.aggregateSha256 === right?.aggregateSha256
    && JSON.stringify(left?.files ?? null) === JSON.stringify(right?.files ?? null);
}

export function assertFrozenManifest(actual, expected, label) {
  demand(actual?.aggregateSha256 === expected?.aggregateSha256,
    `Source changed ${label}: expected ${expected?.aggregateSha256 ?? 'missing'}, got ${actual?.aggregateSha256 ?? 'missing'}.`);
}

export function assertFrozenBinaries(actual, expected, label) {
  demand(JSON.stringify(actual) === JSON.stringify(expected), `Binary changed ${label}.`);
}

export function processSeedForSample(sample, expectedActualSeed = '') {
  if (sample?.launchMode === 'continue') {
    demand(typeof expectedActualSeed === 'string' && expectedActualSeed !== '', 'Warm Continue requires its cold source actual seed.');
    return expectedActualSeed;
  }
  demand(typeof sample?.requestedSeed === 'string' && sample.requestedSeed !== '', 'Cold New Game requires its requested seed.');
  return sample.requestedSeed;
}

function savePaths(userdata, seed) {
  demand(/^[A-Za-z0-9_-]+$/.test(seed), `Actual seed is not safe for immutable save pairing: ${seed}`);
  const root = join(userdata, ...appDataSuffix);
  return {
    active: join(root, 'voxel_biome_world_saves_active_seed.txt'),
    slot: join(root, `voxel_biome_world_saves_slot_${seed}.json`),
  };
}

export async function saveReceipt(userdata, seed) {
  const paths = savePaths(userdata, seed);
  demand(await exists(paths.active) && await exists(paths.slot), `Pairing save is missing for ${seed}`);
  await assertNoReparseComponents(paths.active, 'Pairing active-seed save');
  await assertNoReparseComponents(paths.slot, 'Pairing slot save');
  const activeInfo = await lstat(paths.active), slotInfo = await lstat(paths.slot);
  demand(activeInfo.isFile() && !activeInfo.isSymbolicLink() && activeInfo.size <= loadingSaveBounds.activeSeedBytes,
    'Pairing active-seed save is invalid, symlinked, or exceeds its byte bound.');
  demand(slotInfo.isFile() && !slotInfo.isSymbolicLink() && slotInfo.size <= loadingSaveBounds.slotBytes,
    'Pairing slot save is invalid, symlinked, or exceeds its byte bound.');
  const activeText = (await readUtf8Bounded(paths.active, loadingSaveBounds.activeSeedBytes)).replace(/^\uFEFF/, '').trim();
  const slot = JSON.parse((await readUtf8Bounded(paths.slot, loadingSaveBounds.slotBytes)).replace(/^\uFEFF/, ''));
  demand(activeText === seed && slot.seed === seed && slot.version === 2, 'Pairing save seed/version mismatch.');
  return {
    seed,
    activeRelativePath: relative(userdata, paths.active).replaceAll('\\', '/'),
    slotRelativePath: relative(userdata, paths.slot).replaceAll('\\', '/'),
    activeBytes: activeInfo.size,
    slotBytes: slotInfo.size,
    activeSha256: await sha256File(paths.active, loadingSaveBounds.activeSeedBytes),
    slotSha256: await sha256File(paths.slot, loadingSaveBounds.slotBytes),
  };
}

function cleanEnvironment(parent) {
  const env = {};
  for (const [key, value] of Object.entries(parent)) if (!/^VOXEL_/i.test(key) && !/^CITADEL_/i.test(key)) env[key] = value;
  return env;
}

export function evaluateSampleReport(report, expected, evaluationMode = 'gate5') {
  const errors = [];
  const finitePositive = value => typeof value === 'number' && Number.isFinite(value) && value > 0;
  const finiteNonnegative = value => typeof value === 'number' && Number.isFinite(value) && value >= 0;
  if (report?.schema !== 'world-streaming-loading-sample/v1' || report?.finished !== true || report?.passed !== true) errors.push('Godot loading sample did not pass.');
  if (report?.sampleId !== expected.sampleId || report?.launchMode !== expected.launchMode || report?.cacheClassification !== expected.cacheClassification) errors.push('Sample identity/classification mismatch.');
  if (report?.requestedTestSeed !== expected.requestedSeed || report?.processTestSeed !== expected.processTestSeed || !report?.actualSeed) errors.push('Requested/process/actual seed evidence is incomplete.');
  if (expected.actualSeed && report?.actualSeed !== expected.actualSeed) errors.push('Continue restored a different seed than its paired New Game.');
  if (report?.voxelPlaytest !== '' || report?.runTokenPresent !== true || report?.savePathOverride !== '') errors.push('Dedicated-token/save-path/VOXEL_PLAYTEST policy was not preserved.');
  const firstFrameMs = report?.timing?.inputToFirstLoadingFrameMs;
  const readyMs = report?.timing?.inputToGameplayReadyMs;
  if (!finitePositive(firstFrameMs) || !finitePositive(readyMs) || readyMs < firstFrameMs) errors.push('Menu-input loading timings are incomplete.');
  else if (firstFrameMs > comparatorPolicy.passAffecting.firstVisibleLoadingFrameMaxMs) errors.push(`First visible loading frame ${firstFrameMs.toFixed(3)}ms exceeded ${comparatorPolicy.passAffecting.firstVisibleLoadingFrameMaxMs}ms.`);
  const cadence = report?.timing?.loadingFrameCadence;
  if (!Number.isInteger(cadence?.sampleCount) || cadence.sampleCount <= 0 || !finitePositive(cadence?.p99Ms)
      || !finitePositive(cadence?.maxMs) || cadence.p99Ms > cadence.maxMs
      || !Array.isArray(report?.timing?.startupTimeline) || report.timing.startupTimeline.length === 0
      || !report?.timing?.stageDistributions || Object.keys(report.timing.stageDistributions).length === 0
      || report?.timing?.timelineObservation?.complete !== true || report?.timing?.timelineObservation?.truncated !== false) errors.push('Loading cadence/stage-distribution evidence is incomplete or truncated.');
  else {
    if (cadence.p99Ms > comparatorPolicy.passAffecting.loadingFrameP99MaxMs) errors.push(`Loading frame-gap p99 ${cadence.p99Ms.toFixed(3)}ms exceeded ${comparatorPolicy.passAffecting.loadingFrameP99MaxMs}ms.`);
    if (cadence.maxMs > comparatorPolicy.passAffecting.loadingFrameMaxMs) errors.push(`Loading frame-gap max ${cadence.maxMs.toFixed(3)}ms exceeded ${comparatorPolicy.passAffecting.loadingFrameMaxMs}ms.`);
  }
  const heartbeat = report?.timing?.progressHeartbeat;
  const workRows = heartbeat?.workProofRows;
  let workGapMaxMs = NaN;
  const heartbeatAvailable = heartbeat?.source === 'MainCore.startup_work_progress_revision'
    && heartbeat?.verified === true && Array.isArray(workRows) && workRows.length > 0;
  if (!heartbeatAvailable
      || !Array.isArray(workRows) || workRows.length === 0 || !finitePositive(readyMs)) {
    if (evaluationMode === 'gate5') errors.push('Authoritative completed-work heartbeat evidence is unavailable.');
  } else {
    let previousAtMs = 0, previousRevision = -1;
    workGapMaxMs = 0;
    for (const row of workRows) {
      if (typeof row?.owner !== 'string' || !row.owner || !finiteNonnegative(row?.observedAtInputMs)
          || row.observedAtInputMs <= previousAtMs || row.observedAtInputMs > readyMs
          || !Number.isSafeInteger(row?.completedRevision) || row.completedRevision <= previousRevision
          || !Number.isSafeInteger(row?.pendingWorkCount) || row.pendingWorkCount < 0
          || !finiteNonnegative(row?.activeWorkAgeMs)) {
        errors.push('Authoritative completed-work heartbeat row is invalid or nonprogressing.');
        break;
      }
      workGapMaxMs = Math.max(workGapMaxMs, row.observedAtInputMs - previousAtMs);
      previousAtMs = row.observedAtInputMs;
      previousRevision = row.completedRevision;
    }
    workGapMaxMs = Math.max(workGapMaxMs, readyMs - previousAtMs);
    if (workGapMaxMs > comparatorPolicy.passAffecting.progressHeartbeatMaxGapMs) errors.push(`Completed-work heartbeat gap ${workGapMaxMs.toFixed(3)}ms exceeded ${comparatorPolicy.passAffecting.progressHeartbeatMaxGapMs}ms.`);
  }
  if (Number(report?.modal?.overlayMissingFramesDuringLoading) !== 0 || report?.modal?.reenteredAfterGameplayReady !== false || Number(report?.modal?.postReadyModalVisibleFrames) !== 0 || !(Number(report?.modal?.postReadyObservationFramesRequested) >= 60) || Number(report?.modal?.postReadyObservationFramesObserved) !== Number(report?.modal?.postReadyObservationFramesRequested)) errors.push('Loading modal continuity/re-entry observation failed.');
  if (!(Number(report?.modal?.overlayVisibleFrames) > 0)) errors.push('Loading overlay was never observed.');
  if (report?.startupReadinessDomains?.gameplay?.status !== 'ready') errors.push('Gameplay readiness domain was not ready.');
  if (!report?.runtime?.engine || !report?.runtime?.displayServer || String(report.runtime.displayServer).toLowerCase() === 'headless' || !report?.runtime?.renderingMethod || !report?.runtime?.renderingDriver || !report?.runtime?.videoAdapter) errors.push('Engine/active-renderer evidence is incomplete.');
  const requestedResolution = expected.resolution?.split('x').map(Number);
  if (expected.resolution && JSON.stringify(report?.runtime?.requestedResolution) !== JSON.stringify(requestedResolution)) errors.push('Reported requested resolution did not match the matrix request.');
  if (expected.resolution && JSON.stringify(report?.runtime?.nativeWindowResolution) !== JSON.stringify(requestedResolution)) errors.push('Native window resolution did not match the requested matrix resolution.');
  if (expected.resolution && JSON.stringify(report?.runtime?.renderTargetResolution) !== JSON.stringify(requestedResolution)) errors.push('Render target resolution did not match the requested matrix resolution.');
  const callback = report?.loadingMainCallbackObservation;
  const mainCallbackMaxMs = callback?.maxObservedFrameMs;
  if (callback?.complete !== true || !Number.isInteger(callback?.pollCount) || callback.pollCount <= 0
      || !Number.isInteger(callback?.maxObservedMonitorSampleCount) || callback.maxObservedMonitorSampleCount <= 0
      || !finiteNonnegative(mainCallbackMaxMs)) errors.push('Full-loading Main callback evidence is missing.');
  else if (mainCallbackMaxMs > comparatorPolicy.passAffecting.loadingMainCallbackMaxMs) errors.push(`Loading Main callback ${mainCallbackMaxMs.toFixed(3)}ms exceeded 33ms.`);
  return {
    passed: errors.length === 0,
    policyId: comparatorPolicy.policyId,
    errors,
    mainCallbackMaxMs,
    firstFrameMs,
    loadingFrameP99Ms: cadence?.p99Ms,
    loadingFrameMaxMs: cadence?.maxMs,
    progressHeartbeatMaxGapMs: workGapMaxMs,
    authoritativeWorkProgressProven: heartbeatAvailable,
    loadingCallbackIntervalMaxMs: Number(report?.timing?.loadingCallbackIntervalMax?.stepMs ?? 0),
    scope: 'Main callback maximum is accumulated by polling RuntimePerformanceMonitor throughout the full loading interval; runner frame gaps and loading callback intervals remain separate presentation/cadence evidence.',
  };
}

export function aggregateMatrix(sampleRows, evaluationMode = 'gate5') {
  const pairs = [];
  for (const cold of sampleRows.filter(row => row.launchMode === 'new_game')) {
    const warm = sampleRows.find(row => row.pairId === cold.pairId && row.launchMode === 'continue');
    const coldMs = Number(cold.report?.timing?.inputToGameplayReadyMs ?? 0);
    const warmMs = Number(warm?.report?.timing?.inputToGameplayReadyMs ?? 0);
    pairs.push({
      pairId: cold.pairId,
      cohort: cold.cohort,
      requestedSeed: cold.requestedSeed,
      actualSeed: cold.report?.actualSeed ?? '',
      coldMs,
      warmMs,
      warmToColdRatio: coldMs > 0 ? warmMs / coldMs : null,
      provisionalColdReferenceMet: coldMs <= comparatorPolicy.provisionalReferencesOnly.coldInputToGameplayReadyMs,
      provisionalWarmReferenceMet: warmMs <= comparatorPolicy.provisionalReferencesOnly.warmInputToGameplayReadyMs,
      provisionalWarmRatioMet: coldMs > 0 && warmMs <= coldMs * comparatorPolicy.provisionalReferencesOnly.warmToPairedColdRatio,
      durationComparisonPassAffecting: false,
    });
  }
  const knownActualSeeds = new Set(pairs.filter(row => row.cohort === 'controlled_known_seed').map(row => row.actualSeed));
  const freshActualSeeds = new Set(pairs.filter(row => row.cohort === 'fresh_seed').map(row => row.actualSeed));
  const controlledKnownSeedStable = knownActualSeeds.size === 1 && !knownActualSeeds.has('');
  const freshSeedsDistinct = freshActualSeeds.size === 2 && !freshActualSeeds.has('');
  const allActualSeeds = new Set([...knownActualSeeds, ...freshActualSeeds]);
  const seedCohortsDistinct = controlledKnownSeedStable && freshSeedsDistinct && allActualSeeds.size === 3;
  const functionalPassed = sampleRows.length === 10 && sampleRows.every(row => row.verification?.passed === true) && seedCohortsDistinct;
  const authoritativeWorkProgressProven = sampleRows.length === 10 && sampleRows.every(row =>
    row.verification?.evaluation?.authoritativeWorkProgressProven === true);
  const responsivePolicyPassed = functionalPassed && sampleRows.every(row =>
    row.verification?.evaluation?.passed === true
      && row.verification.evaluation.policyId === comparatorPolicy.policyId);
  const gate5LoadingAccepted = evaluationMode === 'gate5' && authoritativeWorkProgressProven
    ? responsivePolicyPassed : null;
  return {
    schema: 'world-streaming-loading-matrix/v1',
    finished: true,
    status: evaluationMode === 'functional-diagnostic'
      ? (functionalPassed ? 'functional_diagnostic_passed' : 'failed')
      : (!authoritativeWorkProgressProven ? 'gate5_blocked_authoritative_work_progress_unavailable'
        : (responsivePolicyPassed ? 'gate5_responsive_loading_passed' : 'failed')),
    evaluationMode,
    gate5LoadingAccepted,
    responsivePolicyReady: authoritativeWorkProgressProven,
    comparatorPolicy,
    sampleCount: sampleRows.length,
    processCount: sampleRows.length,
    functionalPassed,
    authoritativeWorkProgressProven,
    responsivePolicyPassed,
    controlledKnownSeedStable,
    freshSeedsDistinct,
    seedCohortsDistinct,
    pairs,
    samples: sampleRows,
  };
}

async function runOneSample({ project, output, sample, userdata, godotExe, options, expectedActualSeed = '', runOwnedProcess = ownedProcess }) {
  const sampleDir = join(output, 'samples', sample.sampleId);
  await mkdir(sampleDir, { recursive: false });
  const precondition = await directoryInventory(userdata);
  if (sample.cacheClassification === 'cold') demand(precondition.empty, 'Cold sample userdata/cache root was not empty before launch.');
  await writeJson(join(sampleDir, 'cache-precondition.json'), {
    ...precondition,
    definition: 'Cold means a fresh process whose isolated APPDATA/LOCALAPPDATA root has no files. This is stronger than checking one named generated-artifact subdirectory and does not touch user or unrelated caches.',
    classification: sample.cacheClassification,
  });
  const reportPath = join(sampleDir, 'report.json');
  const progressPath = join(sampleDir, 'progress.txt');
  const token = randomUUID();
  const processTestSeed = processSeedForSample(sample, expectedActualSeed);
  const env = {
    ...cleanEnvironment(process.env),
    APPDATA: userdata,
    LOCALAPPDATA: userdata,
    VOXEL_DISABLE_AUDIO_PLAYBACK: '1',
    VOXEL_WORLD_STREAMING_LOADING_MATRIX_TOKEN: token,
    VOXEL_WORLD_STREAMING_LOADING_SAMPLE_ID: sample.sampleId,
    VOXEL_WORLD_STREAMING_LOADING_SAMPLE_MODE: sample.launchMode,
    VOXEL_WORLD_STREAMING_LOADING_CACHE_CLASSIFICATION: sample.cacheClassification,
    VOXEL_WORLD_STREAMING_LOADING_REQUESTED_SEED: sample.requestedSeed,
    VOXEL_WORLD_STREAMING_LOADING_SAMPLE_REPORT: reportPath,
    VOXEL_WORLD_STREAMING_LOADING_SAMPLE_PROGRESS: progressPath,
    VOXEL_WORLD_STREAMING_LOADING_RESOLUTION: options.resolution,
    VOXEL_TEST_SEED: processTestSeed,
  };
  const paths = {
    stdoutPath: join(sampleDir, 'stdout.log'), stderrPath: join(sampleDir, 'stderr.log'),
    summaryPath: join(sampleDir, 'watchdog.json'), stopRequestPath: join(sampleDir, 'stop-request.txt'),
    liveOwnershipPath: join(sampleDir, 'live-ownership.json'),
  };
  const watch = await runOwnedProcess({ projectPath: project, executable: godotExe,
    args: ['--path', project, scene, '--resolution', options.resolution, '--windowed'], env,
    timeoutSeconds: options.timeoutSeconds, ...paths });
  const report = await exists(reportPath) ? await readJson(reportPath) : null;
  const evaluation = evaluateSampleReport(report, { ...sample, processTestSeed, actualSeed: expectedActualSeed, resolution: options.resolution }, options.evaluationMode);
  const logText = (await readFile(paths.stdoutPath, 'utf8')) + '\n' + (await readFile(paths.stderrPath, 'utf8'));
  const engineIssues = logText.split(/\r?\n/).filter(line => /SCRIPT ERROR:|Parse Error:|ERROR:|WARNING:|leaked|resources still in use/i.test(line));
  const lifecyclePassed = watch.rootExited === true && watch.functionalExitCode === 0 && watch.timedOut === false && watch.forcedCleanup === false && watch.cleanupPassed === true && watch.authoritativeZeroProven === true;
  const verification = {
    passed: evaluation.passed && lifecyclePassed && engineIssues.length === 0,
    evaluation,
    naturalExit: watch.rootExited === true && !watch.forcedCleanup && !watch.timedOut,
    functionalExitCode: watch.functionalExitCode,
    cleanupPassed: watch.cleanupPassed,
    ownedZero: watch.authoritativeZeroProven,
    engineIssueCount: engineIssues.length,
    engineIssues,
    cachePrecondition: precondition,
  };
  await writeJson(join(sampleDir, 'verification.json'), verification);
  demand(verification.passed, `Loading sample failed: ${sample.sampleId}; retain ${relative(project, sampleDir)}.`);
  return { ...sample, processTestSeed, report, verification, sampleDirectory: relative(project, sampleDir).replaceAll('\\', '/') };
}

export async function runLoadingMatrix(input, dependencies = {}) {
  const options = { ...input };
  const project = dependencies.projectPath ?? projectRoot;
  const output = resolve(project, options.outputDirectory.replaceAll('\\', '/'));
  const allowedRoot = resolve(project, 'artifacts/world-streaming-maturity/g5');
  demand(normalized(dirname(output)) === normalized(allowedRoot) && basename(output).toLowerCase().startsWith('loading-matrix-'), 'OutputDirectory must be a fresh loading-matrix-* directory directly under artifacts/world-streaming-maturity/g5.');
  demand(!(await exists(output)), 'OutputDirectory must be fresh; evidence is never overwritten.');
  await mkdir(output, { recursive: true });
  const godotExe = await (dependencies.findGodot ?? findGodot)(options.godotExe);
  const samples = buildSamplePlan(options.knownSeed, dependencies.freshIds);
  const initialSource = await (dependencies.sourceManifest ?? sourceManifest)(project);
  const initialBinaries = await (dependencies.binaryManifest ?? binaryManifest)(project, godotExe);
  const launch = {
    schema: 'world-streaming-loading-matrix-launch/v1',
    recordedUtc: new Date().toISOString(),
    projectPath: project,
    head: git(project, ['rev-parse', 'HEAD']).trim(),
    branch: git(project, ['branch', '--show-current']).trim(),
    resolution: options.resolution,
    timeoutSecondsPerProcess: options.timeoutSeconds,
    expectedProcessCount: 10,
    seedMechanism: 'Cold New Game uses the cohort VOXEL_TEST_SEED through MainCore.random_world_seed deterministic sequence index zero, admitted only by VOXEL_WORLD_STREAMING_LOADING_MATRIX_TOKEN. Warm Continue uses the paired cold actual seed as its process VOXEL_TEST_SEED while retaining the cohort request separately. VOXEL_PLAYTEST is unset.',
    plans: samples,
    comparatorPolicy,
    source: initialSource,
    binaries: initialBinaries,
  };
  await writeJson(join(output, 'launch.json'), launch);
  if (options.dryRun) return { planValid: true, dryRun: true, evaluationMode: options.evaluationMode,
    gate5LoadingAccepted: null, outputDirectory: relative(project, output).replaceAll('\\', '/'), processCount: 0, plannedProcessCount: 10 };
  const rows = [];
  const frozenCheckpoint = async label => {
    const source = await (dependencies.sourceManifest ?? sourceManifest)(project);
    const binaries = await (dependencies.binaryManifest ?? binaryManifest)(project, godotExe);
    assertFrozenManifest(source, initialSource, label);
    assertFrozenBinaries(binaries, initialBinaries, label);
    return { label, sourceAggregateSha256: source.aggregateSha256,
      binarySha256: Object.fromEntries(Object.entries(binaries).map(([id, value]) => [id, value.sha256])) };
  };
  for (const coldSample of samples.filter(row => row.launchMode === 'new_game')) {
    const coldUserdata = join(output, 'profiles', coldSample.pairId, 'cold-userdata');
    await mkdir(coldUserdata, { recursive: true });
    const coldBefore = await frozenCheckpoint(`before ${coldSample.sampleId}`);
    const cold = await runOneSample({ project, output, sample: coldSample, userdata: coldUserdata, godotExe, options, runOwnedProcess: dependencies.runOwnedProcess });
    const coldAfter = await frozenCheckpoint(`after ${coldSample.sampleId}`);
    cold.frozenManifests = { before: coldBefore, after: coldAfter };
    const coldSave = await saveReceipt(coldUserdata, cold.report.actualSeed);
    cold.saveOutput = coldSave;
    const sourceInventoryBeforeWarm = await directoryInventory(coldUserdata);
    cold.profileOutput = sourceInventoryBeforeWarm;
    const warmSample = samples.find(row => row.pairId === coldSample.pairId && row.launchMode === 'continue');
    const warmUserdata = join(output, 'profiles', coldSample.pairId, 'warm-userdata');
    await mkdir(dirname(warmUserdata), { recursive: true });
    await cp(coldUserdata, warmUserdata, { recursive: true, errorOnExist: true, force: false });
    const warmProfileInput = await directoryInventory(warmUserdata);
    demand(directoryInventoriesEqual(sourceInventoryBeforeWarm, warmProfileInput), 'Warm Continue profile is not byte-identical to its cold source.');
    const warmInputSave = await saveReceipt(warmUserdata, cold.report.actualSeed);
    demand(warmInputSave.activeSha256 === coldSave.activeSha256 && warmInputSave.slotSha256 === coldSave.slotSha256, 'Warm Continue input save is not byte-identical to its cold source.');
    const warmBefore = await frozenCheckpoint(`before ${warmSample.sampleId}`);
    const warm = await runOneSample({ project, output, sample: warmSample, userdata: warmUserdata, godotExe, options, expectedActualSeed: cold.report.actualSeed, runOwnedProcess: dependencies.runOwnedProcess });
    const warmAfter = await frozenCheckpoint(`after ${warmSample.sampleId}`);
    warm.frozenManifests = { before: warmBefore, after: warmAfter };
    demand(directoryInventoriesEqual(warm.verification.cachePrecondition, warmProfileInput), 'Warm prelaunch profile observation changed before process creation.');
    const sourceInventoryAfterWarm = await directoryInventory(coldUserdata);
    demand(sourceInventoryBeforeWarm.aggregateSha256 === sourceInventoryAfterWarm.aggregateSha256, 'Cold source profile changed during paired Continue.');
    const warmSaveOutput = await saveReceipt(warmUserdata, cold.report.actualSeed);
    const warmProfileOutput = await directoryInventory(warmUserdata);
    warm.saveInput = { ...warmInputSave, sourceProfileAggregateSha256: sourceInventoryBeforeWarm.aggregateSha256,
      warmProfileAggregateSha256: warmProfileInput.aggregateSha256, fullProfileByteIdentical: true,
      sourceProfileUnchangedAfterContinue: true };
    warm.saveOutput = warmSaveOutput;
    warm.profileInput = warmProfileInput;
    warm.profileOutput = warmProfileOutput;
    rows.push(cold, warm);
  }
  const summary = aggregateMatrix(rows, options.evaluationMode);
  summary.sourceFrozen = true;
  summary.binariesFrozen = true;
  summary.outputDirectory = relative(project, output).replaceAll('\\', '/');
  await writeJson(join(output, 'report.json'), summary);
  return { functionalPassed: summary.functionalPassed, gate5LoadingAccepted: summary.gate5LoadingAccepted, evaluationMode: options.evaluationMode,
    status: summary.status, outputDirectory: summary.outputDirectory,
    processCount: summary.processCount, responsivePolicyReady: summary.responsivePolicyReady };
}

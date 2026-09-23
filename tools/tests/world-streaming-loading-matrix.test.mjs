import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, open, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { activeBinaryCandidates, aggregateMatrix, assertFrozenBinaries, assertFrozenManifest,
  binaryManifest, buildSamplePlan, comparatorPolicy, directoryInventoriesEqual, directoryInventory, evaluateSampleReport,
  loadingSaveBounds, parseLoadingMatrixOptions, processSeedForSample, saveReceipt, sha256File, sourceManifest } from '../lib/world-streaming-loading-matrix.mjs';
import { projectFingerprintBounds } from '../lib/citadel-candidate-runner.mjs';
import { loadingMatrixExitCode } from '../run-world-streaming-maturity-loading-matrix.mjs';

function report(sample, actualSeed = 'atlas-12345678', elapsed = 75000, maxStep = 30) {
  const workProofRows = [];
  for (let at = 4000, revision = 1; at < elapsed; at += 4000, revision++)
    workProofRows.push({ owner: 'startup-work', observedAtInputMs: at,
      completedRevision: revision, pendingWorkCount: 1, activeWorkAgeMs: 100,
      kind: 'completed_units', completedCount: revision });
  return {
    schema: 'world-streaming-loading-sample/v1', finished: true, passed: true,
    sampleId: sample.sampleId, launchMode: sample.launchMode, cacheClassification: sample.cacheClassification,
    requestedTestSeed: sample.requestedSeed, processTestSeed: sample.processTestSeed ?? sample.requestedSeed,
    actualSeed, voxelPlaytest: '', runTokenPresent: true, savePathOverride: '',
    timing: { inputToFirstLoadingFrameMs: 1, inputToGameplayReadyMs: elapsed,
      loadingCallbackIntervalMax: { stepMs: 5000 }, loadingFrameCadence: { sampleCount: 10, p99Ms: 16.7, maxMs: 16.7 },
      progressHeartbeat: { source: 'MainCore.startup_work_progress_revision', verified: true, workProofRows },
      startupTimeline: [{ domain: 'gameplay', stepMs: 1 }], stageDistributions: { gameplay: { count: 1 } },
      timelineObservation: { complete: true, truncated: false, observedRowCount: 1 } },
    mainCallbackWindowAtReady: { frameMaxMs: maxStep },
    loadingMainCallbackObservation: { complete: true, pollCount: 2, maxObservedMonitorSampleCount: 10, maxObservedFrameMs: maxStep },
    modal: { overlayMissingFramesDuringLoading: 0, overlayVisibleFrames: 10,
      postReadyModalVisibleFrames: 0, postReadyObservationFramesRequested: 60,
      postReadyObservationFramesObserved: 60, reenteredAfterGameplayReady: false },
    startupReadinessDomains: { gameplay: { status: 'ready' } },
    runtime: { engine: { string: '4.6.1' }, displayServer: 'windows', renderingMethod: 'gl_compatibility',
      renderingDriver: 'd3d12', videoAdapter: 'test', requestedResolution: [1920, 1080],
      nativeWindowResolution: [1920, 1080], renderTargetResolution: [1920, 1080], logicalViewportResolution: [1280, 720] },
  };
}

function expected(sample, values = {}) {
  return { ...sample, processTestSeed: sample.processTestSeed ?? sample.requestedSeed, resolution: '1920x1080', ...values };
}

test('matrix plan is five ordered cold/warm pairs and exactly ten fresh processes', () => {
  const plan = buildSamplePlan('known', ['fresh-a', 'fresh-b']);
  assert.equal(plan.length, 10);
  assert.deepEqual(plan.map(row => row.launchMode), ['new_game', 'continue', 'new_game', 'continue', 'new_game', 'continue', 'new_game', 'continue', 'new_game', 'continue']);
  assert.equal(plan.filter(row => row.cohort === 'controlled_known_seed' && row.launchMode === 'new_game').length, 3);
  assert.equal(plan.filter(row => row.cohort === 'fresh_seed' && row.launchMode === 'new_game').length, 2);
  assert.equal(new Set(plan.filter(row => row.cohort === 'fresh_seed').map(row => row.requestedSeed)).size, 2);
  assert.throws(() => buildSamplePlan('known', ['same', 'same']), /must be distinct/);
});

test('sample validation enforces identity lifecycle-facing evidence and callback envelope', () => {
  const sample = buildSamplePlan('known', ['a', 'b'])[0];
  assert.equal(evaluateSampleReport(report(sample), expected(sample)).passed, true);
  const atLimits = report(sample, 'atlas-12345678', 75000, 33);
  atLimits.timing.inputToFirstLoadingFrameMs = 1000;
  atLimits.timing.loadingFrameCadence.p99Ms = 33;
  atLimits.timing.loadingFrameCadence.maxMs = 100;
  atLimits.timing.progressHeartbeat.workProofRows[1].observedAtInputMs = 9000;
  assert.equal(evaluateSampleReport(atLimits, expected(sample)).passed, true);
  const slowCallback = report(sample, 'atlas-12345678', 75000, 33.001);
  assert.equal(evaluateSampleReport(slowCallback, expected(sample)).passed, false);
  for (const mutate of [
    value => { value.timing.inputToFirstLoadingFrameMs = 1000.001; },
    value => { value.timing.loadingFrameCadence.p99Ms = 33.001; },
    value => { value.timing.loadingFrameCadence.maxMs = 100.001; },
    value => { value.timing.progressHeartbeat.workProofRows[1].observedAtInputMs = 9000.001; },
    value => { value.timing.progressHeartbeat.workProofRows[1].completedRevision = 1; },
  ]) {
    const value = structuredClone(report(sample)); mutate(value);
    assert.equal(evaluateSampleReport(value, expected(sample)).passed, false);
  }
  assert.equal(evaluateSampleReport(report(sample), expected(sample, { actualSeed: 'atlas-other' })).passed, false);
});

test('sample validation fails closed for every provenance and evidence bypass', () => {
  const sample = buildSamplePlan('known', ['a', 'b'])[0];
  const mutations = [
    value => { delete value.loadingMainCallbackObservation; },
    value => { value.loadingMainCallbackObservation.pollCount = 0; },
    value => { value.loadingMainCallbackObservation.maxObservedMonitorSampleCount = 0; },
    value => { value.loadingMainCallbackObservation.maxObservedFrameMs = -1; },
    value => { value.loadingMainCallbackObservation.maxObservedFrameMs = '1'; },
    value => { value.timing.inputToFirstLoadingFrameMs = '1'; },
    value => { value.timing.loadingFrameCadence.p99Ms = Infinity; },
    value => { value.timing.loadingFrameCadence.maxMs = NaN; },
    value => { value.timing.progressHeartbeat.verified = false; },
    value => { value.timing.progressHeartbeat.source = 'MainCore.startup_loading_timeline'; },
    value => { value.timing.progressHeartbeat.workProofRows = []; },
    value => { value.timing.timelineObservation = { complete: false, truncated: true }; },
    value => { value.runtime.renderingDriver = ''; },
    value => { value.runtime.displayServer = 'headless'; },
    value => { value.runtime.nativeWindowResolution = [1280, 720]; },
    value => { value.runtime.renderTargetResolution = [1280, 720]; },
    value => { delete value.runtime.requestedResolution; },
    value => { value.savePathOverride = 'user://bypass.json'; },
    value => { value.modal.postReadyObservationFramesRequested = 8; value.modal.postReadyObservationFramesObserved = 8; },
    value => { value.modal.postReadyObservationFramesObserved = 59; },
    value => { value.processTestSeed = 'wrong-process-seed'; },
  ];
  for (const mutate of mutations) {
    const value = structuredClone(report(sample));
    mutate(value);
    assert.equal(evaluateSampleReport(value, expected(sample)).passed, false);
  }
});

test('loading fixture records native window and renderer target separately from the logical viewport', async () => {
  const source = await readFile(new URL('../../scripts/testing/WorldStreamingMaturityLoadingRunner.gd', import.meta.url), 'utf8');
  assert.match(source, /DisplayServer\.window_set_size\(requested_resolution\)/);
  assert.match(source, /"nativeWindowResolution"/);
  assert.match(source, /"renderTargetResolution"/);
  assert.match(source, /"logicalViewportResolution"/);
  assert.match(source, /frame_gap_ms\.append\(float\(gameplay_ready_usec - last_frame_usec\)/);
  assert.match(source, /startup_work_progress/);
});

test('warm Continue uses the cold actual seed without losing cohort identity', () => {
  const plan = buildSamplePlan('cohort-seed', ['a', 'b']);
  const cold = plan[0];
  const warm = plan[1];
  assert.equal(processSeedForSample(cold), 'cohort-seed');
  assert.equal(processSeedForSample(warm, 'atlas-87654321'), 'atlas-87654321');
  assert.equal(warm.requestedSeed, 'cohort-seed');
  assert.throws(() => processSeedForSample(warm), /requires its cold source actual seed/);
});

test('complete profile and frozen-manifest comparisons reject partial provenance', () => {
  const files = [{ path: 'a', bytes: 1, sha256: 'a' }];
  const inventory = { fileCount: 1, aggregateSha256: 'all', files };
  assert.equal(directoryInventoriesEqual(inventory, structuredClone(inventory)), true);
  assert.equal(directoryInventoriesEqual(inventory, { ...inventory, files: [{ ...files[0], sha256: 'b' }] }), false);
  assert.equal(directoryInventoriesEqual(inventory, { ...inventory, fileCount: 2 }), false);
  assert.doesNotThrow(() => assertFrozenManifest({ aggregateSha256: 's' }, { aggregateSha256: 's' }, 'fixture'));
  assert.throws(() => assertFrozenManifest({ aggregateSha256: 'changed' }, { aggregateSha256: 's' }, 'fixture'), /Source changed/);
  const binary = { godot: { sha256: 'g' }, godotEngine: { sha256: 'engine-a' } };
  assert.doesNotThrow(() => assertFrozenBinaries(binary, structuredClone(binary), 'fixture'));
  assert.throws(() => assertFrozenBinaries({ ...binary, godotEngine: { sha256: 'engine-b' } }, binary, 'fixture'), /Binary changed/);
});

test('source manifest includes tracked resources and nonignored untracked assets', async () => {
  const root = await mkdtemp(join(tmpdir(), 'loading-matrix-source-'));
  try {
    execFileSync('git', ['init', '--quiet'], { cwd: root, windowsHide: true });
    await writeFile(join(root, 'script.gd'), 'extends Node\n');
    await writeFile(join(root, 'material.tres'), '[gd_resource]\n');
    await writeFile(join(root, 'model.glb'), Buffer.from([1, 2, 3]));
    await writeFile(join(root, 'playtest-report.json'), 'runtime output');
    await writeFile(join(root, 'artifacts.bin'), 'project input');
    await writeFile(join(root, 'ignored.tmp'), 'ignored cache');
    await writeFile(join(root, '.gitignore'), 'ignored.tmp\n');
    await (await import('node:fs/promises')).mkdir(join(root, 'artifacts'), { recursive: true });
    await writeFile(join(root, 'artifacts', 'run.json'), 'runtime artifact');
    execFileSync('git', ['add', 'script.gd', 'material.tres'], { cwd: root, windowsHide: true });
    const manifest = await sourceManifest(root);
    assert.deepEqual(Object.keys(manifest.files).sort(), ['.gitignore', 'artifacts.bin', 'material.tres', 'model.glb', 'script.gd']);
    assert.equal(manifest.schema, 'project-input-fingerprint/v1');
    assert.ok(manifest.totalBytes > 0);
    assert.ok(manifest.bounds.maximumFileCount >= manifest.fileCount);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('profile inventory rejects junctions and oversized files before hashing them', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'loading-matrix-profile-'));
  try {
    const root = join(parent, 'profile'), target = join(parent, 'target');
    await mkdir(root);
    await mkdir(target);
    await writeFile(join(target, 'save.json'), '{}');
    await symlink(target, join(root, 'linked'), 'junction');
    await assert.rejects(directoryInventory(root), /symlink|junction|reparse/i);
    await rm(join(root, 'linked'), { recursive: true, force: true });
    const handle = await open(join(root, 'oversized.bin'), 'w');
    try { await handle.truncate(projectFingerprintBounds.maximumFileBytes + 1); } finally { await handle.close(); }
    await assert.rejects(directoryInventory(root), /per-file bound/i);
  } finally {
    await rm(parent, { recursive: true, force: true });
  }
});

test('loading binary provenance rejects a Godot path containing a junction', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'loading-matrix-binary-'));
  try {
    const project = join(parent, 'project'), real = join(parent, 'real-bin'), linked = join(parent, 'linked-bin');
    await mkdir(project);
    await mkdir(real);
    await writeFile(join(real, 'godot.exe'), 'binary');
    await symlink(real, linked, 'junction');
    await assert.rejects(binaryManifest(project, join(linked, 'godot.exe')), /symlink, junction, or reparse/i);
  } finally {
    await rm(parent, { recursive: true, force: true });
  }
});

test('loading binary manifest detects an engine-only mutation behind an unchanged console launcher', async () => {
  const parent = await mkdtemp(join(tmpdir(), 'loading-matrix-engine-'));
  try {
    const project = join(parent, 'project'), bin = join(parent, 'godot-bin');
    const consolePath = join(bin, 'Godot_v4.6.1-stable_win64_console.exe');
    const enginePath = join(bin, 'Godot_v4.6.1-stable_win64.exe');
    const addonPaths = [
      'addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll',
      'addons/zylann.voxel/bin/libvoxel.windows.template_release.x86_64.dll',
      'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
      'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_release.x86_64.dll',
    ];
    await mkdir(bin, { recursive: true });
    await writeFile(consolePath, 'launcher');
    await assert.rejects(binaryManifest(project, consolePath), /Required binary is missing/);
    await writeFile(enginePath, 'engine one');
    for (const relativePath of addonPaths) {
      await mkdir(join(project, relativePath, '..'), { recursive: true });
      await writeFile(join(project, relativePath), relativePath);
    }
    const before = await binaryManifest(project, consolePath);
    await writeFile(enginePath, 'engine two');
    const after = await binaryManifest(project, consolePath);
    assert.equal(after.godot.sha256, before.godot.sha256);
    assert.notEqual(after.godotEngine.sha256, before.godotEngine.sha256);
    assert.throws(() => assertFrozenBinaries(after, before, 'engine-only mutation'), /Binary changed/);
  } finally {
    await rm(parent, { recursive: true, force: true });
  }
});

test('loading save receipts reject oversized saves and hash through a bounded stream', async () => {
  const root = await mkdtemp(join(tmpdir(), 'loading-matrix-save-'));
  try {
    const saveRoot = join(root, 'Godot/app_userdata/Voxel Biome World Godot');
    const active = join(saveRoot, 'voxel_biome_world_saves_active_seed.txt');
    const slot = join(saveRoot, 'voxel_biome_world_saves_slot_atlas-123.json');
    await mkdir(saveRoot, { recursive: true });
    await writeFile(active, 'atlas-123\n');
    const handle = await open(slot, 'w');
    try { await handle.truncate(loadingSaveBounds.slotBytes + 1); } finally { await handle.close(); }
    await assert.rejects(saveReceipt(root, 'atlas-123'), /exceeds its byte bound/);
    await writeFile(slot, '{"version":2,"seed":"atlas-123"}');
    const receipt = await saveReceipt(root, 'atlas-123');
    assert.equal(receipt.slotBytes, 32);
    await writeFile(join(root, 'small.bin'), '12345');
    await assert.rejects(sha256File(join(root, 'small.bin'), 4), /exceeded 4 bytes/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('binary inventory names both active GDExtensions and debug/release variants', () => {
  const candidates = activeBinaryCandidates('P:/project', 'P:/Godot_v4.6.1-stable_win64_console.exe');
  const ids = candidates.map(([id]) => id);
  assert.deepEqual(ids, ['godot', 'godotEngine', 'voxelGdextensionDebug', 'voxelGdextensionRelease',
    'terrainMeshingGdextensionDebug', 'terrainMeshingGdextensionRelease']);
  assert.match(candidates.find(([id]) => id === 'godotEngine')[1], /Godot_v4\.6\.1-stable_win64\.exe$/);
});

test('responsive loading can pass beyond historical total-time references; diagnostics cannot claim Gate 5', () => {
  const plan = buildSamplePlan('known', ['a', 'b']);
  const rows = plan.map(sample => {
    const value = report(sample, sample.cohort === 'controlled_known_seed' ? 'atlas-known' : `atlas-${sample.pairId}`,
      sample.launchMode === 'new_game' ? 95000 : 50000);
    const evaluation = evaluateSampleReport(value, expected(sample));
    return { ...sample, report: value, verification: { passed: evaluation.passed, evaluation } };
  });
  const summary = aggregateMatrix(rows);
  assert.equal(summary.functionalPassed, true);
  assert.equal(Object.hasOwn(summary, 'passed'), false);
  assert.equal(summary.gate5LoadingAccepted, true);
  assert.equal(summary.responsivePolicyReady, true);
  assert.equal(summary.pairs.every(pair => pair.provisionalColdReferenceMet === false && pair.durationComparisonPassAffecting === false), true);
  assert.equal(comparatorPolicy.passAffecting.duration, false);
  assert.equal(summary.status, 'gate5_responsive_loading_passed');
  assert.equal(loadingMatrixExitCode({ ...summary, evaluationMode: 'gate5' }), 0);
  const diagnostic = aggregateMatrix(rows, 'functional-diagnostic');
  assert.equal(diagnostic.status, 'functional_diagnostic_passed');
  assert.equal(diagnostic.gate5LoadingAccepted, null);
  assert.equal(loadingMatrixExitCode(diagnostic), 0);
  assert.equal(loadingMatrixExitCode({ dryRun: true, gate5LoadingAccepted: null }), 0);
  const noWorkProof = structuredClone(rows);
  noWorkProof[0].report.timing.progressHeartbeat.verified = false;
  noWorkProof[0].verification.evaluation = evaluateSampleReport(noWorkProof[0].report, expected(noWorkProof[0]));
  noWorkProof[0].verification.passed = noWorkProof[0].verification.evaluation.passed;
  assert.equal(aggregateMatrix(noWorkProof).gate5LoadingAccepted, null);
  assert.equal(aggregateMatrix(noWorkProof).status, 'gate5_blocked_authoritative_work_progress_unavailable');
  assert.equal(loadingMatrixExitCode(aggregateMatrix(noWorkProof)), 1);
  const diagnosticEvaluation = evaluateSampleReport(noWorkProof[0].report, expected(noWorkProof[0]), 'functional-diagnostic');
  assert.equal(diagnosticEvaluation.passed, true);
  assert.equal(diagnosticEvaluation.authoritativeWorkProgressProven, false);
});

test('frequent timeline messages cannot substitute for an authoritative completed-work receipt', () => {
  const sample = buildSamplePlan('known', ['a', 'b'])[0];
  const value = report(sample);
  value.timing.startupTimeline = Array.from({ length: 100 }, (_, index) =>
    ({ domain: 'terrain_chunks', status: 'pending', message: 'Loading terrain 0/9',
      metrics: { loadedChunkCount: 0, requiredChunkCount: 9 }, elapsedMs: index * 10 }));
  value.timing.timelineObservation.observedRowCount = 100;
  value.timing.progressHeartbeat = { source: 'unavailable', verified: false,
    reason: 'no_common_authoritative_completed_work_revision', workProofRows: [] };
  assert.equal(evaluateSampleReport(value, expected(sample)).passed, false);
  assert.equal(evaluateSampleReport(value, expected(sample), 'functional-diagnostic').passed, true);
});

test('distinct completed units may share a source clock tick', () => {
  const sample = buildSamplePlan('known', ['a', 'b'])[0];
  const value = report(sample);
  const rows = value.timing.progressHeartbeat.workProofRows;
  rows.splice(1, 0, { ...rows[0], completedRevision: 2, completedCount: 2 });
  for (let index = 2; index < rows.length; index++) {
    rows[index].completedRevision += 1;
    rows[index].completedCount += 1;
  }
  assert.equal(evaluateSampleReport(value, expected(sample)).passed, true);
});

test('known and fresh actual seed cohorts must be mutually distinct', () => {
  const plan = buildSamplePlan('known', ['a', 'b']);
  const rows = plan.map(sample => ({ ...sample,
    report: report(sample, sample.pairId.startsWith('fresh-2') ? 'atlas-other' : 'atlas-known'),
    verification: { passed: true } }));
  const summary = aggregateMatrix(rows);
  assert.equal(summary.controlledKnownSeedStable, true);
  assert.equal(summary.freshSeedsDistinct, true);
  assert.equal(summary.seedCohortsDistinct, false);
  assert.equal(summary.functionalPassed, false);
});

test('CLI parser requires an explicit fresh output and validates bounded settings', () => {
  const options = parseLoadingMatrixOptions(['-OutputDirectory', 'artifacts/world-streaming-maturity/g5/loading-matrix-unit', '-DryRun']);
  assert.equal(options.dryRun, true);
  assert.equal(options.resolution, '1920x1080');
  assert.equal(options.timeoutSeconds, 330);
  assert.equal(options.evaluationMode, 'gate5');
  assert.equal(parseLoadingMatrixOptions(['-OutputDirectory', 'x', '-EvaluationMode', 'functional-diagnostic']).evaluationMode, 'functional-diagnostic');
  assert.throws(() => parseLoadingMatrixOptions(['-Resolution', '640x480']), /OutputDirectory/);
  assert.throws(() => parseLoadingMatrixOptions(['-OutputDirectory', 'x', '-TimeoutSeconds', '90']), /180 through 600/);
  assert.throws(() => parseLoadingMatrixOptions(['-OutputDirectory', 'x', '-EvaluationMode', 'accepted']), /EvaluationMode/);
});

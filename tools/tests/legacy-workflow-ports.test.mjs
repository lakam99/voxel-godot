import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createLegacyWorkflowPorts, evaluateUndergroundAudit, treeMatrixCases, canopyCaptures } from '../lib/legacy-workflow-ports.mjs';
import { undergroundAuditChecks } from '../lib/legacy-underground-audit-checks.mjs';

// Synthetic orchestration only. No production process runner or Godot is called.
async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'voxel-legacy-workflow-test-'));
  t.after(async () => {
    assert.equal(path.dirname(path.resolve(root)), path.resolve(os.tmpdir()));
    assert.ok(path.basename(root).startsWith('voxel-legacy-workflow-test-'));
    await fs.rm(root, { recursive: true, force: true });
  });
  return root;
}
const json = async (file, value) => { await fs.mkdir(path.dirname(file), { recursive: true }); await fs.writeFile(file, JSON.stringify(value)); };
const absent = async file => fs.stat(file).then(() => false, error => { if (error.code === 'ENOENT') return true; throw error; });

function canopyFake(root, calls, mode = '') {
  return async (exe, args, options) => {
    calls.push({ exe, args, options });
    const e = options.env, stage = e.VOXEL_CANOPY_RELEASE_STAGE;
    const report = { runnerId: 'canopy_release_playtest', evidenceLevel: 'acceptance_visual', passed: true,
      runToken: e.VOXEL_CANOPY_RELEASE_RUN_TOKEN, seed: 'natural-seed', resultCount: 4,
      harvest: { propId: 'tree-123', destroyMetrics: { totalMs: 12.5 } },
      treeBefore: { recipeSignature: 'recipe-456', branchCount: 7, foliageClusterCount: 9 } };
    if (mode === 'failed-continue' && stage === 'continue_verify') report.passed = false;
    if (mode === 'wrong-identity') report.runnerId = 'different';
    if (mode === 'stale-token') report.runToken = 'stale';
    if (mode !== 'missing-report') await json(e.VOXEL_CANOPY_RELEASE_REPORT, report);
    if (mode !== 'missing-save') await fs.writeFile(path.join(path.dirname(e.VOXEL_SAVE_PATH_OVERRIDE), 'canopy-release-save_active_seed.txt'), 'natural-seed');
    if (stage === 'continue_verify') for (const capture of canopyCaptures.slice(0, mode === 'missing-capture' ? -1 : undefined))
      await fs.writeFile(path.join(e.VOXEL_CANOPY_RELEASE_SCREENSHOT_DIR, capture), 'synthetic capture placeholder');
    return { code: mode === 'failed-process' ? 1 : 0 };
  };
}

test('all 37 audit rules preserve frozen baseline patterns and requirements; only wrapper source location changes', async () => {
  const baseline = JSON.parse(await fs.readFile(new URL('./fixtures/underground-audit-baseline.json', import.meta.url), 'utf8'));
  assert.equal(baseline.schema, 'underground-audit-baseline/v1');
  assert.deepEqual(baseline.provenance, {
    commit: 'e09cc95b6211ecfb7de1fcf9902406b0cb176a5d',
    source: 'tools/run-underground-volume-audit.ps1',
    sha256: '3a006f95c151cf5096a338f160748d92d6c3d75c910e10722c87e6120fb2d833',
  });
  const { checks } = baseline;
  assert.equal(checks.length, 37);
  for (let i = 0; i < checks.length; i++) {
    const current = { ...undergroundAuditChecks[i] };
    if (current.id === 'terrain-native-meshing-build-wrapper') {
      assert.deepEqual(current.composedSources, ['tools/lib/voxel-tool-runtime.mjs']);
      assert.deepEqual(current.files, ['tools/build-native-terrain-meshing.mjs']);
      delete current.composedSources; delete current.entrypointPattern; current.files = checks[i].files;
    }
    assert.deepEqual(current, checks[i]);
  }
});

test('audit checks each required alternative, forbidden multiline expressions, and missing files', () => {
  const checks = [{ id: 'sample', files: ['one', 'missing'], requiredPattern: 'alpha|beta', forbiddenPattern: 'bad[\\s\\S]*thing', requirement: 'Both tokens, no bad thing.' }];
  const report = evaluateUndergroundAudit(new Map([['one', 'ALPHA\nbad\nthing']]), checks);
  assert.equal(report.runnerId, 'underground_volume_static_audit');
  assert.equal(report.evidenceLevel, 'static_audit');
  assert.equal(report.status, 'failed');
  assert.deepEqual(report.findings.map(f => f.type), ['forbidden_pattern', 'missing_required_pattern', 'missing_file']);
  assert.equal(report.findings[1].pattern, 'beta');
  assert.equal(evaluateUndergroundAudit(new Map([['one', 'ALPHA BETA'], ['missing', 'alpha beta']]), checks).status, 'passed');
});

test('audit fails closed and writes the full baseline report schema without any game process', async t => {
  const root = await fixture(t), emitted = [];
  const api = createLegacyWorkflowPorts({ projectRoot: root, emit: r => emitted.push(r), findGodot: () => assert.fail('No Godot discovery') });
  await assert.rejects(api.runLegacyWorkflow('run-underground-volume-audit', ['-ReportPath', 'audit.json']), /static audit failed/);
  const report = JSON.parse(await fs.readFile(path.join(root, 'audit.json'), 'utf8'));
  assert.equal(report.schemaVersion, 1);
  assert.equal(report.findingCount, undergroundAuditChecks.reduce((n, check) => n + check.files.length, 0));
  assert.deepEqual(emitted, [report]);
});

test('matrix runs twelve stages across six exact cases and retains measured result metadata', async t => {
  const root = await fixture(t), calls = [], emitted = [];
  const parent = { voxel_playtest: 'bad', VOXEL_TEST_SEED: 'bad', VOXEL_CANOPY_EXPECTED_REMOVED_PROP_ID: 'stale', KEEP: 'yes' };
  const api = createLegacyWorkflowPorts({ projectRoot: root, env: parent, findGodot: async p => p,
    runGodot: canopyFake(root, calls), emit: r => emitted.push(r) });
  const report = await api.runLegacyWorkflow('run-procedural-tree-interaction-matrix', ['-GodotExe', 'fake.exe', '-ArtifactDir', 'matrix', '-WatchdogSeconds', '23']);
  assert.equal(calls.length, 12);
  assert.equal(report.caseCount, 6);
  assert.equal(report.passed, true);
  assert.deepEqual(report.cases.map(c => [c.case, c.biome, c.architecture, c.ageBand]), treeMatrixCases);
  assert.equal(report.cases[0].propId, 'tree-123'); assert.equal(report.cases[0].recipeSignature, 'recipe-456');
  assert.equal(report.cases[0].branchCount, 7); assert.equal(report.cases[0].foliageClusterCount, 9); assert.equal(report.cases[0].breakTotalMs, 12.5);
  for (let i = 0; i < calls.length; i++) {
    const { exe, args, options } = calls[i], e = options.env;
    assert.equal(exe, 'fake.exe'); assert.equal(options.timeoutSeconds, 23);
    assert.ok(!args.includes('--headless') && !args.includes('--fixed-fps'));
    assert.deepEqual(args, ['--path', root, '--resolution', '1280x720', '--scene', 'res://scenes/testing/CanopyReleasePlaytest.tscn']);
    assert.equal(e.VOXEL_CANOPY_RELEASE_STAGE, i % 2 ? 'continue_verify' : 'save_and_harvest');
    assert.equal(e.VOXEL_CANOPY_EXPECTED_REMOVED_PROP_ID, i % 2 ? 'tree-123' : undefined);
    assert.equal(e.VOXEL_TEST_SEED, undefined); assert.equal(e.voxel_playtest, undefined);
    assert.equal(e.KEEP, 'yes');
    if (i % 2) {
      assert.equal(e.VOXEL_SAVE_PATH_OVERRIDE, calls[i - 1].options.env.VOXEL_SAVE_PATH_OVERRIDE);
      assert.notEqual(e.VOXEL_CANOPY_RELEASE_RUN_TOKEN, calls[i - 1].options.env.VOXEL_CANOPY_RELEASE_RUN_TOKEN);
    }
  }
  assert.equal(parent.voxel_playtest, 'bad'); assert.equal(parent.VOXEL_CANOPY_EXPECTED_REMOVED_PROP_ID, 'stale');
  assert.equal(emitted.length, 1);
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(root, 'matrix/interaction-matrix.json'), 'utf8')), report);
});

for (const mode of ['failed-continue', 'failed-process', 'missing-report', 'missing-save', 'missing-capture', 'wrong-identity', 'stale-token']) {
  test(`matrix rejects ${mode}, stops remaining cases, and removes stale green aggregate`, async t => {
    const root = await fixture(t), calls = [], emitted = [];
    const output = path.join(root, 'matrix/interaction-matrix.json');
    await json(output, { passed: true });
    const api = createLegacyWorkflowPorts({ projectRoot: root, findGodot: async () => 'fake', runGodot: canopyFake(root, calls, mode), emit: r => emitted.push(r) });
    await assert.rejects(api.runLegacyWorkflow('run-procedural-tree-interaction-matrix', ['--artifact-dir', 'matrix']));
    assert.ok(calls.length <= 2); assert.equal(emitted.length, 0); assert.ok(await absent(output));
  });
}

test('canopy clears only its stale save/report/capture files and rejects partial selection before launching', async t => {
  const root = await fixture(t), calls = [];
  await json(path.join(root, 'canopy/keep.json'), { keep: true });
  await fs.writeFile(path.join(root, 'canopy/canopy-release-save_slot_stale.json'), 'stale');
  await fs.mkdir(path.join(root, 'canopy/screenshots'), { recursive: true });
  await fs.writeFile(path.join(root, 'canopy/screenshots/old.PNG'), 'stale');
  const api = createLegacyWorkflowPorts({ projectRoot: root, findGodot: async () => 'fake', runGodot: canopyFake(root, calls), emit: () => {} });
  await assert.rejects(api.runLegacyWorkflow('run-canopy-release-playtest', ['-TargetBiome', 'forest']), /provided together/);
  assert.equal(calls.length, 0);
  await api.runLegacyWorkflow('run-canopy-release-playtest', ['-ArtifactDir', 'canopy']);
  assert.ok(await absent(path.join(root, 'canopy/canopy-release-save_slot_stale.json')));
  assert.ok(await absent(path.join(root, 'canopy/screenshots/old.PNG')));
  assert.ok(!(await absent(path.join(root, 'canopy/keep.json'))));
});

const clean = { rootPid: 123, overallExitCode: 0, functionalExitCode: 0, cleanupPassed: true, authoritativeZeroProven: true };
async function interactive(t, args, noInfo = false, badCleanup = false) {
  const root = await fixture(t), emitted = [];
  let captured, tick = 0, finish;
  const completion = new Promise(resolve => { finish = resolve; });
  const parent = { voxel_playtest: 'bad', voxel_underground_interactive_min_depth: '999', KEEP: 'yes' };
  const api = createLegacyWorkflowPorts({ projectRoot: root, env: parent, uuid: () => 'abcdef12-rest', findGodot: async p => p || 'fake',
    now: () => tick, sleep: async ms => { tick += ms; },
    runOwned: async options => {
      captured = options;
      await json(options.liveOwnershipPath, { rootPid: 123 });
      if (!noInfo) await json(options.env.VOXEL_UNDERGROUND_INTERACTIVE_LAUNCH_INFO, { ready: true });
      return completion;
    }, emit: receipt => {
      assert.ok(captured); emitted.push(receipt);
      finish(badCleanup ? { ...clean, cleanupPassed: false } : clean);
    } });
  const execution = api.runUndergroundInteractive(args);
  if (badCleanup) await assert.rejects(execution, /cleanup failed/);
  else await execution;
  assert.equal(parent.voxel_playtest, 'bad');
  return { root, captured, emitted, tick };
}

test('interactive restores baseline defaults, flags, scene and launch receipt while retaining ownership', async t => {
  const { root, captured: c, emitted } = await interactive(t, []);
  assert.equal(c.timeoutSeconds, 0);
  assert.deepEqual(c.args, ['--resolution', '1280x720', '--path', root, '--scene', 'res://scenes/Main.tscn']);
  assert.equal(c.env.VOXEL_PLAYTEST, '1'); assert.equal(c.env.voxel_playtest, undefined);
  assert.equal(c.env.VOXEL_UNDERGROUND_INTERACTIVE, '1');
  assert.equal(c.env.VOXEL_TEST_SEED, 'interactive-underground-abcdef12');
  assert.equal(c.env.VOXEL_UNDERGROUND_INTERACTIVE_SEARCH_RADIUS, '32');
  assert.equal(c.env.VOXEL_UNDERGROUND_INTERACTIVE_MIN_DEPTH, '4');
  assert.equal(c.env.VOXEL_UNDERGROUND_INTERACTIVE_MAX_DEPTH, '30');
  assert.equal(c.env.VOXEL_UNDERGROUND_INTERACTIVE_GOD_MODE, '1');
  assert.equal(c.env.voxel_underground_interactive_min_depth, undefined);
  assert.deepEqual(emitted, [{ processId: 123, seed: 'interactive-underground-abcdef12', searchRadius: 32,
    minDepthCells: 4, maxDepthCells: 30, godMode: true,
    launchInfoPath: path.join(root, 'artifacts/underground/interactive-underground-launch.json'), launchInfo: { ready: true } }]);
});

test('interactive preserves requested receipt values while clamping environment and honoring false GodMode', async t => {
  const { captured: c, emitted } = await interactive(t, ['-Seed', 'chosen', '-SearchRadius', '-3', '-MinDepthCells', '12', '-MaxDepthCells', '2', '-GodMode', 'false', '-LaunchInfoPath', 'launch.json']);
  assert.equal(c.env.VOXEL_UNDERGROUND_INTERACTIVE_SEARCH_RADIUS, '1');
  assert.equal(c.env.VOXEL_UNDERGROUND_INTERACTIVE_MAX_DEPTH, '12');
  assert.equal(c.env.VOXEL_UNDERGROUND_INTERACTIVE_GOD_MODE, '0');
  assert.equal(emitted[0].searchRadius, -3); assert.equal(emitted[0].maxDepthCells, 2); assert.equal(emitted[0].seed, 'chosen');
});

test('interactive emits null launch info after baseline 60-second observation limit, without ending game ownership', async t => {
  const { emitted, tick } = await interactive(t, [], true);
  assert.ok(tick >= 60000); assert.equal(emitted[0].launchInfo, null);
});

test('interactive cleanup failure cannot become successful completion', async t => { await interactive(t, [], false, true); });

test('interactive rejects early exit before launch info', async t => {
  const root = await fixture(t);
  const api = createLegacyWorkflowPorts({ projectRoot: root, findGodot: async () => 'fake', runOwned: async () => clean, emit: () => assert.fail('No launch receipt') });
  await assert.rejects(api.runUndergroundInteractive([]), /exited before writing/);
});

for (const mode of ['writable-stop', 'unwritable-stop', 'unwritable-stop-cleanup-rejects']) {
  test(`interactive observer cancellation awaits owned cleanup and preserves cause: ${mode}`, { timeout: 10000 }, async t => {
    const root = await fixture(t);
    const original = new Error('injected launch receipt observer failure');
    const cleanupError = new Error('injected owned cleanup failure');
    let finishCleanup, rejectCleanup, signal, abortObserved, callerSettled = false, cleanupSettled = false;
    const aborted = new Promise(resolve => { abortObserved = resolve; });
    const cleanup = new Promise((resolve, reject) => { finishCleanup = resolve; rejectCleanup = reject; });
    const api = createLegacyWorkflowPorts({ projectRoot: root, findGodot: async () => 'fake',
      runOwned: async options => {
        signal = options.signal;
        assert.ok(signal instanceof AbortSignal);
        signal.addEventListener('abort', () => abortObserved(), { once: true });
        // A directory at the exact stop-file path reliably injects a write
        // failure without permissions assumptions or a production test hook.
        if (mode.startsWith('unwritable')) await fs.mkdir(options.stopRequestPath);
        await json(options.liveOwnershipPath, { rootPid: 123 });
        await json(options.env.VOXEL_UNDERGROUND_INTERACTIVE_LAUNCH_INFO, { ready: true });
        try { return await cleanup; }
        finally { cleanupSettled = true; }
      }, emit: () => { throw original; } });
    const result = api.runUndergroundInteractive([]).then(
      () => { callerSettled = true; assert.fail('Observer failure must reject'); },
      error => { callerSettled = true; return error; });
    await aborted;
    assert.equal(signal.aborted, true);
    assert.equal(signal.reason, original);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(callerSettled, false, 'Caller escaped before watchdog cleanup');
    assert.equal(cleanupSettled, false);
    if (mode.endsWith('cleanup-rejects')) rejectCleanup(cleanupError);
    else finishCleanup({ ...clean, overallExitCode: 125 });
    const error = await result;
    assert.equal(cleanupSettled, true);
    assert.equal(error, original, 'Cleanup or stop-file error masked the original observer cause');
    assert.equal(error.message, 'injected launch receipt observer failure');
    if (mode.startsWith('unwritable')) assert.ok(error.stopRequestWriteError instanceof Error);
    else assert.equal(error.stopRequestWriteError, undefined);
    if (mode.endsWith('cleanup-rejects')) assert.equal(error.ownedProcessError, cleanupError);
  });
}

test('all workflow help paths are discoverable without side effects or process discovery', async () => {
  const lines = [];
  const api = createLegacyWorkflowPorts({ emit: value => lines.push(value), findGodot: () => assert.fail('No process discovery') });
  for (const id of ['run-procedural-tree-interaction-matrix', 'run-underground-volume-audit', 'run-canopy-release-playtest']) await api.runLegacyWorkflow(id, ['--help']);
  await api.runUndergroundInteractive(['-Help']);
  assert.equal(lines.length, 4); assert.ok(lines.every(line => line.startsWith('Usage:')));
});

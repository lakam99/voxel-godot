// Pure/synthetic Node helper checks only. The injected launcher never starts Godot.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { deflateSync } from 'node:zlib';
import { options, choice, integer, ownedPath, inside, fresh, hashes, stable, assertReport, assertWatchdog, assertNoGodot, checkLogs, phaseRun, classifyHeadedTestProgress, readProgressSnapshot, captureWithBoundedRetries, projectDefault, uid, watchdogSources, write, read, context, resolveExecutablePair } from './building-runner.mjs';
import { createHeadedTestEvidence, headedCapturePath, inspectFocusCaptureOwnedWindow,
	persistVisualInspection, validateVisualInspection } from './headed-test-evidence.mjs';
import { removeClass, replaceOnce, archiveGraph, landscapeCapture, errorInventory, expectedCompoundError, eligibleBaseline, normalized } from './building-frozen.mjs';
import { runSpecial as runSpecialImplementation } from './building-special.mjs';
import { specs } from './building-contract-specs.mjs';
import { sourceFiles } from './building-special-sources.mjs';
import { structuralRunnerSources, validatePhaseASourceBindings } from './building-source-bindings.mjs';
import { runFocused } from './building-focused.mjs';

const clean = { overallExitCode: 0, functionalExitCode: 0, cleanupPassed: true, authoritativeZeroProven: true, finalMembershipKnown: true, finalJobMemberPids: [], timedOut: false, forcedCleanup: false, cleanupUnresolved: false };
const runSpecial = (name, args, launcher) => runSpecialImplementation(name, [...args, '-GodotExe', process.execPath], launcher);
function temporary(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'building-node-unit-'));
  t.after(() => { assert.ok(inside(os.tmpdir(), dir)); fs.rmSync(dir, { recursive: true, force: true }); });
  return dir;
}
function ownedTemporary(t) {
  const dir = path.join(projectDefault, 'artifacts/citadel-runtime-integration/building-node-unit-' + uid());
  t.after(() => { assert.equal(path.dirname(dir), path.join(projectDefault, 'artifacts/citadel-runtime-integration')); if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true }); });
  return dir;
}

test('CLI preserves single/double-dash spelling and rejects unknown/missing values', () => {
  assert.deepEqual(options(['-OutputDirectory', 'a b', '--timeout-seconds', '17', '-Capture'], { outputdirectory: '', timeoutseconds: 30 }, ['capture']), { outputdirectory: 'a b', timeoutseconds: '17', capture: true });
  assert.throws(() => options(['-Unknown'], {}));
  assert.throws(() => options(['-Phase'], { phase: '' }));
  assert.throws(() => options(['-Phase', '--Bad'], { phase: '' }));
  assert.equal(choice('phasea', ['Codec', 'PhaseA', 'PhaseB'], 'Mode'), 'PhaseA');
  for (const n of [0, 241, 1.5, 'NaN']) assert.throws(() => integer(n, 1, 240, 'timeout'));
});
test('owned output confinement rejects siblings, nested paths and wrong prefixes', () => {
  const project = path.resolve('fixture-project');
  assert.equal(ownedPath(project, 'artifacts/citadel-runtime-integration/publication-source-01', 'publication-source-'), path.join(project, 'artifacts/citadel-runtime-integration/publication-source-01'));
  for (const p of ['../escape', 'artifacts/citadel-runtime-integration/publication-source-01/nested', 'artifacts/citadel-runtime-integration/other-01']) assert.throws(() => ownedPath(project, p, 'publication-source-'));
  assert.equal(inside(project, project + '-sibling'), false);
});
test('fresh creation refuses existing evidence', t => {
  const p = path.join(temporary(t), 'new'); fresh(p); fs.writeFileSync(path.join(p, 'keep'), 'evidence');
  assert.throws(() => fresh(p)); assert.equal(fs.readFileSync(path.join(p, 'keep'), 'utf8'), 'evidence');
});
test('source hashes bind exact bytes, including line endings', t => {
  const dir = temporary(t); fs.writeFileSync(path.join(dir, 'a'), 'x\r\n'); const before = hashes(dir, ['a']); stable(dir, before);
  fs.writeFileSync(path.join(dir, 'a'), 'x\n'); assert.throws(() => stable(dir, before));
});
test('watchdog cannot pass without authoritative zero or with failed cleanup', () => {
  assertWatchdog(clean, true);
  for (const change of [{ overallExitCode: 1 }, { functionalExitCode: 1 }, { authoritativeZeroProven: false }, { cleanupPassed: false }, { forcedCleanup: true }, { timedOut: true }, { cleanupUnresolved: true }, { finalMembershipKnown: false }, { finalJobMemberPids: [42] }, { finalJobMemberPids: undefined }]) assert.throws(() => assertWatchdog({ ...clean, ...change }, true));
  assert.throws(() => assertWatchdog({}));
});
test('every required watchdog field rejects absence and wrong JSON type', () => {
  for (const membership of [false, true]) {
    const keys = ['overallExitCode', 'functionalExitCode', 'cleanupPassed', 'authoritativeZeroProven', 'timedOut', 'forcedCleanup', 'cleanupUnresolved', ...(membership ? ['finalMembershipKnown', 'finalJobMemberPids'] : [])];
    for (const key of keys) {
      const missing = { ...clean }; delete missing[key];
      assert.throws(() => assertWatchdog(missing, membership), key + ' missing');
      for (const value of [null, undefined, String(clean[key]), {}, ...(Array.isArray(clean[key]) ? [false] : [[]])]) {
        assert.throws(() => assertWatchdog({ ...clean, [key]: value }, membership), key + ' mistyped');
      }
    }
  }
});
test('relative launcher and console runtime become exact absolute file paths', t => {
  const project = temporary(t), launcher = path.join(project, 'Engine_console.exe'), runtime = path.join(project, 'Engine.exe');
  fs.writeFileSync(launcher, 'fake launcher: never executed'); fs.writeFileSync(runtime, 'fake runtime: never executed');
  const relative = path.relative(process.cwd(), launcher);
  const c = context({ projectpath: project, outputdirectory: 'fresh-output', godotexe: relative });
  assert.equal(c.executable, fs.realpathSync(launcher)); assert.ok(path.isAbsolute(c.executable));
  assert.deepEqual(resolveExecutablePair(relative), { executable: fs.realpathSync(launcher), runtime: fs.realpathSync(runtime) });
  assert.throws(() => context({ projectpath: project, outputdirectory: 'fresh-output', godotexe: path.join(project, 'missing.exe') }));
  fs.unlinkSync(runtime); assert.throws(() => resolveExecutablePair(relative));
});
test('Phase A requires every helper/native source in both launch and checkpoint fingerprint', t => {
  const project = temporary(t);
  for (const source of structuralRunnerSources) { const file = path.join(project, source); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, source); }
  const map = hashes(project, structuralRunnerSources);
  const launch = { mode: 'PhaseA', sourceSha256: map };
  const report = { sourceFingerprint: { ready: true, entries: structuralRunnerSources.map(source => [source, fs.statSync(path.join(project, source)).size, map[source]]) } };
  validatePhaseASourceBindings(project, launch, report);
  for (const source of structuralRunnerSources) {
    const omitted = { ...map }; delete omitted[source];
    assert.throws(() => validatePhaseASourceBindings(project, { ...launch, sourceSha256: omitted }, report), source + ' absent from launch');
    const missingFingerprint = structuredClone(report); missingFingerprint.sourceFingerprint.entries = missingFingerprint.sourceFingerprint.entries.filter(row => row[0] !== source);
    assert.throws(() => validatePhaseASourceBindings(project, launch, missingFingerprint), source + ' absent from checkpoint fingerprint');
    const malformed = { ...map, [source]: null };
    assert.throws(() => validatePhaseASourceBindings(project, { ...launch, sourceSha256: malformed }, report));
  }
  const changed = structuralRunnerSources.find(source => source.endsWith('building-special.mjs'));
  fs.appendFileSync(path.join(project, changed), '\nchanged');
  assert.throws(() => validatePhaseASourceBindings(project, launch, report));
  const rewrittenMap = { ...map, ...hashes(project, [changed]) };
  assert.throws(() => validatePhaseASourceBindings(project, { ...launch, sourceSha256: rewrittenMap }, report), 'rewriting launch alone cannot bypass checkpoint binding');
});
test('static audit: Codec and Node inventory agree and cover local runtime imports', () => {
  const codec = fs.readFileSync(path.join(projectDefault, 'scripts/testing/buildings/CitadelStructuralComposerCheckpointCodec.gd'), 'utf8');
  const block = codec.match(/const RUNNER_SOURCE_PATHS := \[([\s\S]*?)\n\]/)[1];
  const gdInventory = [...block.matchAll(/"res:\/\/([^"\n]+)"/g)].map(match => match[1]);
  assert.deepEqual(gdInventory.toSorted(), structuralRunnerSources.toSorted());
  for (const source of structuralRunnerSources.filter(file => file.endsWith('.mjs'))) {
    const code = fs.readFileSync(path.join(projectDefault, source), 'utf8');
    for (const match of code.matchAll(/(?:from\s*|import\s*\()'([^']+)'/g)) {
      if (!match[1].startsWith('.')) continue;
      const imported = path.relative(projectDefault, path.resolve(projectDefault, path.dirname(source), match[1])).replaceAll('\\', '/');
      assert.ok(structuralRunnerSources.includes(imported), source + ' imports unbound source ' + imported);
    }
  }
  assert.ok(codec.includes('checkpoint_runner_source_inventory_missing'));
});
test('synthetic StrictMode fixture ports reject missing or mistyped timing evidence', async t => {
  for (const name of ['citadel-site-selection-contract', 'citadel-site-build-queue-contract']) {
    const field = name === 'citadel-site-selection-contract' ? 'elapsedUsec' : 'maxPollUsec';
    for (const value of [undefined, null, '1', -1]) {
      const dir = path.join(temporary(t), 'output');
      await assert.rejects(runFocused(name, ['-OutputDirectory', dir, '-GodotExe', process.execPath], async o => {
        fs.writeFileSync(o.stdoutPath, ''); fs.writeFileSync(o.stderrPath, '');
        write(path.join(dir, 'report.json'), { schema: specs[name].reportSchema, evidenceLevel: specs[name].evidenceLevel, complete: true, passed: true, failures: [], [field]: value });
        return clean;
      }), /Missing or invalid report field/);
    }
  }
});
test('report gates fail closed on missing, false or wrong-type fields', () => {
  assertReport({ passed: true, complete: true, schema: 'fixture/v1' }, { passed: true, complete: true, schema: 'fixture/v1' });
  for (const report of [{}, { passed: 'true' }, { passed: false }]) assert.throws(() => assertReport(report, { passed: true }));
});
test('global exclusive-engine gate reads image names, never controls unrelated processes', () => {
  assertNoGodot('"node.exe","42","Console","1","2 K"\n');
  assert.throws(() => assertNoGodot('"Godot_v4.6_console.exe","99","Console","1","2 K"'));
});
test('Windows process gate requires complete names and rejects console or runtime Godot', () => {
  const inventory = names => ({ schema: 'process-name-inventory/v1', complete: true, count: names.length,
    processes: names.map((name, pid) => ({ name, pid })) });
  const response = names => ({ status: 0, signal: null, stdout: JSON.stringify(inventory(names)), stderr: '' });
  let calls = 0;
  const run = (executable, args, options) => {
    calls++;
    assert.equal(executable, 'powershell.exe');
    assert.deepEqual(args.slice(0, 4), ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command']);
    assert.ok(args[4].includes('Get-Process -ErrorAction Stop'));
    assert.equal(options.windowsHide, true); assert.equal(options.timeout, 10000);
    assert.equal(options.encoding, 'utf8'); assert.equal(options.maxBuffer, 1024 * 1024);
    return { ...response(['Idle', 'node', 'powershell']), stdout: '\uFEFF' + JSON.stringify(inventory(['Idle', 'node', 'powershell'])) };
  };
  assertNoGodot(undefined, { platform: 'win32', run }); assert.equal(calls, 1);
  for (const name of ['Godot_v4.6.1-stable_win64_console', 'godot_v4.6.1-stable_win64', 'GODOT']) {
    assert.throws(() => assertNoGodot(undefined, { platform: 'win32', run: () => response(['node', name]) }), /Another Godot instance/);
  }
  assertNoGodot('"node.exe","42"', { platform: 'win32', run: () => { throw new Error('Injected inventory must not spawn a command'); } });
});
test('Windows process gate rejects missing, malformed, mistyped and empty inventories', () => {
  const valid = { schema: 'process-name-inventory/v1', complete: true, count: 1, processes: [{ name: 'node', pid: 42 }] };
  const response = stdout => ({ status: 0, signal: null, stdout, stderr: '' });
  const invalid = [null, {}, { ...valid, schema: 'other' }, { ...valid, complete: false }, { ...valid, complete: 'true' },
    { ...valid, count: 0, processes: [] }, { ...valid, processes: {} }, { ...valid, count: '1' }, { ...valid, count: 2 },
    ...[null, { name: '', pid: 1 }, { name: '  ', pid: 1 }, { name: 42, pid: 1 }, { name: 'node' },
      { name: 'node', pid: -1 }, { name: 'node', pid: 1.5 }, { name: 'node', pid: '42' }].map(item => ({ ...valid, processes: [item] })),
    { ...valid, count: 2, processes: [{ name: 'node', pid: 42 }, { name: 'other', pid: 42 }] }];
  for (const value of invalid) assert.throws(() => assertNoGodot(undefined, { platform: 'win32', run: () => response(JSON.stringify(value)) }));
  for (const output of ['', 'Access denied', JSON.stringify(valid) + '\ntruncated', Buffer.from(JSON.stringify(valid))]) {
    assert.throws(() => assertNoGodot(undefined, { platform: 'win32', run: () => response(output) }));
  }
  for (const change of [{ status: 1 }, { status: '0' }, { signal: 'SIGTERM' }, { stderr: 'Access denied' }, { stderr: undefined }, { error: new Error('spawn failed') }]) {
    assert.throws(() => assertNoGodot(undefined, { platform: 'win32', run: () => ({ ...response(JSON.stringify(valid)), ...change }) }));
  }
});
test('Windows process gate never treats enumeration failure or timeout as no Godot', () => {
  for (const code of ['EACCES', 'ETIMEDOUT', 'ENOBUFS']) {
    const failure = Object.assign(new Error(code), { code }); let calls = 0;
    assert.throws(() => assertNoGodot(undefined, { platform: 'win32', run: () => { calls++; throw failure; } }), error => error === failure);
    assert.equal(calls, 1, 'No permissive fallback after inventory failure');
    assert.throws(() => assertNoGodot(undefined, { platform: 'win32', run: () => ({ status: null, signal: null, error: failure, stdout: '', stderr: '' }) }));
  }
});
test('non-Windows process gate preserves plain ps names and rejects Godot', () => {
  const run = (executable, args, options) => {
    assert.equal(executable, 'ps'); assert.deepEqual(args, ['-A', '-o', 'comm=']);
    assert.deepEqual(options, { encoding: 'utf8' }); return 'node\nps\n';
  };
  assertNoGodot(undefined, { platform: 'linux', run });
  assert.throws(() => assertNoGodot(undefined, { platform: 'linux', run: () => 'node\nGodot_v4.6\n' }), /Another Godot instance/);
});
test('late warnings, leaks and nonempty stderr invalidate clean booleans', () => {
  checkLogs('Godot Engine\n', '');
  for (const line of ['SCRIPT ERROR: bad', 'Parse Error: bad', 'Compile Error', 'WARNING: bad', 'ObjectDB instances leaked', 'resources still in use']) assert.throws(() => checkLogs(line, ''));
  assert.throws(() => checkLogs('', 'note', { emptyStderr: true }));
});
test('compound failure permits exactly two exact diagnostic lines', () => {
  const lines = expectedCompoundError + '\n' + expectedCompoundError;
  assert.equal(errorInventory(lines, '', true).passed, true);
  for (const bad of ['', expectedCompoundError, lines + '\n' + expectedCompoundError, lines + '\nERROR: other', expectedCompoundError.toLowerCase() + '\n' + expectedCompoundError]) assert.equal(errorInventory(bad, '', true).passed, false);
  assert.equal(errorInventory(lines, '', false).passed, false);
});
test('archive class stripping and capture substitutions require exact markers', () => {
  assert.equal(removeClass('class_name Example\r\nextends RefCounted\r\n', 'Example'), 'extends RefCounted\r\n');
  assert.throws(() => removeClass('extends RefCounted\n'));
  assert.throws(() => removeClass('class_name A\nclass_name B\n'));
  assert.equal(replaceOnce('before MARK after', 'MARK', 'new'), 'before new after');
  assert.throws(() => replaceOnce('MARK MARK', 'MARK', 'new'));
  assert.equal(normalized('a\r\nb'), 'a\nb');
});
test('transitive dependency walk handles cycles and rejects mutable root edges', () => {
  const files = { 'scripts/A.gd': 'preload("res://scripts/B.gd")', 'scripts/B.gd': 'preload("res://scripts/A.gd")' };
  const graph = archiveGraph(['scripts/A.gd'], p => Buffer.from(files[p]), () => {});
  assert.deepEqual([...graph.keys()], ['scripts/A.gd', 'scripts/B.gd']);
  assert.throws(() => archiveGraph(['scripts/A.gd'], p => Buffer.from(files[p]), p => { assert.notEqual(p, 'scripts/B.gd'); }));
});
test('landscape capture preserves house call and stops before tree selection', () => {
  const source = 'static func compose():\n\tadd_perimeter_neighborhoods(blueprint, grammar, keep_front_z, foundation_height, variation)\n\tvar selected_tree_sites := select_open_paving_tree_sites(blueprint, seed)\n\tunsafe_later_stage()\nstatic func next():\n\tpass\n';
  const capture = landscapeCapture(source);
  assert.ok(capture.includes('handoff["houseInput"]')); assert.ok(capture.includes('handoff["houseOutput"]')); assert.ok(capture.includes('handoff["treeInput"]'));
  assert.ok(capture.includes('add_perimeter_neighborhoods')); assert.ok(capture.includes('static func next')); assert.ok(!capture.includes('unsafe_later_stage')); assert.ok(!capture.includes('select_open_paving_tree_sites'));
  assert.throws(() => landscapeCapture(source.replace('select_open_paving_tree_sites', 'changed')));
});
test('baseline admission requires completed report, bound artifact and clean watchdog', t => {
  const project = temporary(t), dir = path.join(project, 'artifacts/citadel-runtime-integration/compound-cancellation-baseline-test'); fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'baseline.bin'), 'baseline'); const hash = hashes(dir, ['baseline.bin'])['baseline.bin'];
  write(path.join(dir, 'report.json'), { complete: true, passed: true, phase: 'baseline', baselineSha256: hash }); write(path.join(dir, 'watchdog.json'), clean);
  assert.equal(eligibleBaseline({ project }, dir, 'compound-cancellation-').hash, hash);
  fs.writeFileSync(path.join(dir, 'baseline.bin'), 'corrupt'); assert.throws(() => eligibleBaseline({ project }, dir, 'compound-cancellation-'));
});
test('synthetic watchdog adapter passes complete child environment without mutating parent', async t => {
  const dir = temporary(t), original = process.env.BUILDING_UNIT_PARENT;
  const c = { project: dir, run: dir, executable: 'never-launched', env: { ONLY_CHILD: 'yes' } };
  let captured;
  await phaseRun(c, { args: ['--headless', '--script', 'res://fixture.gd'], env: { OUTPUT: dir }, timeout: 3 }, async o => { captured = o; fs.writeFileSync(o.stdoutPath, ''); fs.writeFileSync(o.stderrPath, ''); return clean; });
  assert.deepEqual(captured.env, { ONLY_CHILD: 'yes', OUTPUT: dir }); assert.equal(captured.timeoutSeconds, 3); assert.equal(process.env.BUILDING_UNIT_PARENT, original);
  assert.deepEqual(captured.args, ['--path', dir, '--headless', '--script', 'res://fixture.gd']);
});
test('headed phaseRun binds supplied runId to live ownership and test environment', async t => {
  const dir = temporary(t), runId = 'abcdef0123456789abcdef0123456789';
  let captured;
  await phaseRun({ project: dir, run: dir, executable: 'never-launched', env: {} }, {
    args: ['--script', 'res://fixture.gd'], live: true, headedTest: { runnerId: 'fixture-headed-gate' },
  }, async o => {
    captured = o;
    fs.writeFileSync(o.stdoutPath, ''); fs.writeFileSync(o.stderrPath, '');
    return { ...clean, runId: o.runId };
  });
  assert.match(captured.runId, /^[a-f0-9]{32}$/);
  assert.equal(captured.env.VOXEL_AUTOMATED_TEST, '1');
  assert.equal(captured.env.VOXEL_AUTOMATED_TEST_RUN_ID, captured.runId);
  assert.equal(captured.liveOwnershipPath, path.join(dir, 'he', 'l.json'));
  const evidence = read(path.join(dir, 'he', 'e.json'));
  assert.equal(evidence.watchdogRunId, captured.runId);
  assert.equal(evidence.accepted, false);
});
test('default owned-window completion writes failure acknowledgement even when capture is unavailable', async t => {
  const dir = temporary(t), progressPath = path.join(dir, 'progress.json');
  let acknowledgement;
  await phaseRun({ project: dir, run: dir, executable: 'never-launched', env: {} }, {
    args: [], live: true,
    headedTest: { runnerId: 'default-window-ack-fixture', completionHandshake: true, progressPath },
  }, async o => {
    fs.writeFileSync(o.stdoutPath, ''); fs.writeFileSync(o.stderrPath, '');
    write(progressPath, { stage: 'finished', details: { passed: false } });
    const ackPath = o.env.VOXEL_AUTOMATED_TEST_FINAL_CAPTURE_ACK;
    const deadline = Date.now() + 3000;
    while (!fs.existsSync(ackPath) && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 25));
    }
    assert.ok(fs.existsSync(ackPath), 'terminal capture must acknowledge through the configured path');
    acknowledgement = read(ackPath);
    assert.equal(acknowledgement.runId, o.runId);
    return { ...clean, runId: o.runId };
  });
  assert.equal(acknowledgement.schema, 'headed-test-capture-ack/v1');
  assert.equal(acknowledgement.checkpoint, 'test-failure');
  assert.equal(acknowledgement.accepted, false);
  assert.equal(read(path.join(dir, 'he', 'e.json')).accepted, false);
});
test('headed screenshot inspects first, retries transient ambiguity/focus refusal, and reuses that exact HWND', async t => {
  const dir = temporary(t), runId = '22155664000000000000000000000001';
  const liveOwnershipPath = path.join(dir, 'live-ownership.json');
  fs.writeFileSync(liveOwnershipPath, JSON.stringify({ schema: 'godot-live-ownership/v1', runId,
    state: 'running', projectPath: dir, authority: 'Windows Job Object membership',
    members: [{ pid: 38852 }] }));
  const calls = [], waits = [];
  let inspectCount = 0, focusCount = 0;
  const window = { Hwnd: 22155664, Pid: 38852, Width: 1280, Height: 720, Foreground: true };
  const result = await inspectFocusCaptureOwnedWindow({ liveOwnershipPath, projectPath: dir, runId,
    capturePath: path.join(dir, 'capture.png'), wait: async milliseconds => waits.push(milliseconds),
    invoke: async (args, action) => {
      calls.push({ args, action });
      assert.equal(args[args.indexOf('--run-id') + 1], runId);
      if (action === 'Inspect') {
        inspectCount++;
        assert.equal(args.includes('--window-handle'), false);
        if (inspectCount === 1) throw new Error('Inspect failed: Expected exactly one visible owned Godot game client; provide an inspected HWND if ambiguous.');
        return { schema: 'owned-game-window-action/v1', runId, action, status: 'completed',
          window: { ...window, Foreground: false } };
      }
      assert.equal(args[args.indexOf('--window-handle') + 1], String(window.Hwnd));
      if (action === 'Focus') {
        focusCount++;
        if (focusCount === 1) throw new Error('Focus failed: Windows refused foreground focus.');
        return { schema: 'owned-game-window-action/v1', runId, action, status: 'completed', window };
      }
      assert.equal(action, 'Capture');
      assert.equal(args[args.indexOf('--expected-client-width') + 1], '1280');
      assert.equal(args[args.indexOf('--expected-client-height') + 1], '720');
      return { schema: 'owned-game-window-action/v1', runId, action, status: 'completed', window };
    } });
  assert.equal(result.window.Hwnd, window.Hwnd);
  assert.deepEqual(calls.map(call => call.action), ['Inspect', 'Inspect', 'Focus', 'Inspect', 'Focus', 'Capture']);
  assert.deepEqual(waits, [150, 150]);
});
test('headed capture filenames stay compact and sequence-unique under deep run paths', t => {
  const dir = temporary(t), deepRun = path.join(dir, 'artifacts', 'citadel-runtime-integration',
    'terrain-fluid-section-native-receipt-r4');
  const evidence = createHeadedTestEvidence({ projectPath: dir, runnerId: 'compact-path-test',
    runId: '22155664000000000000000000000002', outputDirectory: path.join(deepRun, 'he') });
  const first = headedCapturePath(evidence.metadata.captureDirectory, 0);
  const second = headedCapturePath(evidence.metadata.captureDirectory, 1);
  assert.equal(evidence.metadata.captureDirectory, path.join(deepRun, 'he', 's'));
  assert.equal(path.basename(first), '00.png');
  assert.equal(path.basename(second), '01.png');
  assert.notEqual(first, second);
  assert.ok(first.length < path.join(deepRun, 'headed-test-evidence', 'screenshots',
    '000001-test-success.png').length - 30, 'compact path materially reduces Windows path length');
});
test('Main gate progress distinguishes real startup readiness from harness and search phases', () => {
  assert.deepEqual(classifyHeadedTestProgress({ stage: 'waiting_for_main_startup' }), {
    phase: 'waiting_for_main_startup', phaseKind: 'initialized_main_readiness_wait', checkpoint: 'main-readiness'
  });
  assert.deepEqual(classifyHeadedTestProgress({ stage: 'waiting_for_real_main_startup' }), {
    phase: 'waiting_for_main_startup', phaseKind: 'initialized_main_readiness_wait', checkpoint: 'main-readiness'
  });
  assert.deepEqual(classifyHeadedTestProgress({ stage: 'searching_installed_production_candidates', details: { scanCount: 10 } }), {
    phase: 'candidate_search', phaseKind: 'harness', checkpoint: 'candidate-search'
  });
  assert.equal(classifyHeadedTestProgress({ stage: 'finished', details: { passed: false } }).phaseKind, 'failure');
});
test('transient truncated progress snapshots are retried and retained as diagnostics', t => {
  const file = path.join(temporary(t), 'progress.json'), diagnostics = [];
  fs.writeFileSync(file, '{"stage":"waiting_for_main_startup"');
  assert.equal(readProgressSnapshot(file, diagnostics), null);
  assert.equal(diagnostics.length, 1);
  assert.match(diagnostics[0].error, /JSON/);
  fs.writeFileSync(file, JSON.stringify({ stage: 'searching_installed_production_candidates' }));
  assert.equal(readProgressSnapshot(file, diagnostics).stage, 'searching_installed_production_candidates');
  assert.equal(diagnostics.length, 1, 'successful retry preserves the earlier parse race for final evidence');
});
test('screenshot retries are bounded and yield to a terminal phase', async () => {
  let terminal = false, calls = 0;
  const result = await captureWithBoundedRetries({
    capture: async () => { calls++; throw new Error('native helper transient failure'); },
    shouldRetry: () => !terminal,
    maxAttempts: 5,
    wait: async () => { terminal = true; },
  });
  assert.equal(calls, 2);
  assert.equal(result.attempts, 2);
  assert.match(result.error.message, /native helper/);
});
test('terminal phase polling can advance while an async screenshot action is pending', async () => {
  let terminal = false, calls = 0, phasePolls = 0;
  const pollTimer = setInterval(() => { phasePolls++; terminal = true; }, 2);
  try {
    const result = await captureWithBoundedRetries({
      capture: async () => { calls++; await new Promise(resolve => setTimeout(resolve, 25)); throw new Error('capture failed'); },
      shouldRetry: () => !terminal,
      maxAttempts: 4,
      wait: async () => {},
    });
    assert.equal(result.attempts, 1);
    assert.equal(calls, 1);
    assert.ok(phasePolls > 0, 'progress polling ran while screenshot work was pending');
  } finally { clearInterval(pollTimer); }
});
test('screenshot review rejects mismatched run and screenshot hashes', () => {
  const evidence = { runnerId: 'headed-fixture', runId: 'a'.repeat(32), captures: [
    { captureId: 'capture-1', sha256: '1'.repeat(64) }
  ] };
  assert.throws(() => validateVisualInspection(evidence, { schema: 'voxel-automated-test-visual-review/v1',
    runnerId: evidence.runnerId, runId: 'b'.repeat(32), reviewer: 'human', captures: [] }), /identity/);
  assert.throws(() => validateVisualInspection(evidence, { schema: 'voxel-automated-test-visual-review/v1',
    runnerId: evidence.runnerId, runId: evidence.runId, reviewer: 'human', captures: [
      { captureId: 'capture-1', screenshotSha256: '2'.repeat(64), inspected: true, result: 'pass', notes: 'Reviewed image' }
    ] }), /hash-matched/);
});
test('unclean watchdog failure remains durable evidence and cannot be accepted', t => {
  const dir = temporary(t), runId = '0123456789abcdef0123456789abcdef';
  const evidenceRun = createHeadedTestEvidence({ projectPath: dir, runnerId: 'headed-failure-fixture', runId,
    outputDirectory: path.join(dir, 'headed-test-evidence'), sourceIdentity: { head: 'fixture' } });
  evidenceRun.publishPhase('watchdog_or_test_failure', 'failure', 'owned process cleanup failed');
  evidenceRun.recordCaptureFailure({ phase: 'watchdog_or_test_failure', phaseKind: 'failure', reason: 'owned window closed before capture' });
  const evidence = evidenceRun.finalize({ watchdogSummary: { runId, overallExitCode: 125,
    functionalExitCode: 1, cleanupPassed: false, authoritativeZeroProven: false } });
  assert.equal(evidence.accepted, false);
  assert.equal(evidence.watchdog.cleanupPassed, false);
  assert.equal(evidence.captureFailures.length, 1);
  assert.equal(evidence.visualInspection.status, 'unavailable');
});
test('headed phaseRun finalizes failure evidence when watchdog invocation rejects', async t => {
  const dir = temporary(t);
  let runId = '';
  await assert.rejects(phaseRun({ project: dir, run: dir, executable: 'never-launched', env: {} }, {
    args: ['--script', 'res://fixture.gd'], live: true, headedTest: { runnerId: 'rejected-watchdog-fixture' },
  }, async options => { runId = options.runId; throw new Error('injected watchdog rejection'); }),
  /injected watchdog rejection.*headed-test failure evidence/);
  const evidence = read(path.join(dir, 'he', 'e.json'));
  assert.equal(evidence.runId, runId);
  assert.equal(evidence.watchdog.schema, 'watchdog-invocation-failure/v1');
  assert.equal(evidence.watchdog.cleanupPassed, false);
  assert.equal(evidence.accepted, false);
  assert.ok(evidence.captureFailures.some(row => row.phase === 'watchdog_or_test_failure'));
});
function syntheticPngForEvidenceTest() {
  const crc32 = bytes => {
    let crc = 0xffffffff;
    for (const byte of bytes) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc & 1) ? (0xedb88320 ^ (crc >>> 1)) : (crc >>> 1);
    }
    return (crc ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const typeBytes = Buffer.from(type, 'ascii'), length = Buffer.alloc(4), checksum = Buffer.alloc(4);
    length.writeUInt32BE(data.length);
    checksum.writeUInt32BE(crc32(Buffer.concat([typeBytes, data])));
    return Buffer.concat([length, typeBytes, data, checksum]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(1, 0);
  header.writeUInt32BE(1, 4);
  header[8] = 8;
  header[9] = 6;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', header), chunk('IDAT', deflateSync(Buffer.from([0, 64, 128, 192, 255]))),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}
test('pending visual review keeps otherwise passing headed evidence unaccepted until persisted review', t => {
  const dir = temporary(t), runId = 'aabbccddeeff0011aabbccddeeff0011';
  const evidenceRun = createHeadedTestEvidence({ projectPath: dir, runnerId: 'headed-review-fixture', runId,
    outputDirectory: path.join(dir, 'headed-test-evidence'), sourceIdentity: { head: 'fixture' } });
  const status = evidenceRun.publishPhase('test_success', 'harness');
  const imagePath = path.join(evidenceRun.metadata.captureDirectory, 'checkpoint.png');
  const png = syntheticPngForEvidenceTest();
  fs.writeFileSync(imagePath, png);
  const screenshotSha256 = createHash('sha256').update(png).digest('hex');
  const sourceIdentity = evidenceRun.metadata.sourceIdentity;
  fs.appendFileSync(evidenceRun.metadata.captureManifestPath, `${JSON.stringify({
    schema: 'voxel-automated-test-capture/v1', captureId: `${runId}:000001`, runnerId: 'headed-review-fixture',
    runId, watchdogRunId: runId, phase: 'test_success', phaseKind: 'harness', elapsedMilliseconds: 40,
    statusSequence: status.sequence, captureType: 'owned-window', sourceIdentity,
    sourceSha256: sourceIdentity.sourceSha256 ?? {},
    sourceIdentitySha256: evidenceRun.metadata.sourceIdentitySha256,
    capturedAtUnixMilliseconds: Date.now(), path: imagePath, screenshotBytes: png.length, screenshotSha256,
    windowHandle: '4', pid: 3, ownershipSequence: 2,
    nativeCaptureReceipt: { runId, window: { Hwnd: 4, Pid: 3 } },
  })}\n`);
  const evidence = evidenceRun.finalize({ watchdogSummary: { ...clean, runId }, acceptancePassed: true });
  assert.equal(evidence.processAcceptancePassed, true);
  assert.equal(evidence.visualInspection.status, 'pending');
  assert.equal(evidence.accepted, false);
  const review = { schema: 'voxel-automated-test-visual-review/v1', runnerId: evidence.runnerId, runId,
    reviewer: 'test reviewer', inspectedAtUtc: new Date().toISOString(), captures: [
      { captureId: `${runId}:000001`, screenshotSha256, inspected: true, result: 'pass', notes: 'Badge and loading UI are legible.' }
    ] };
  const persisted = persistVisualInspection({ evidencePath: evidenceRun.metadata.evidencePath, review });
  const reviewedEvidence = read(persisted.outputPath);
  assert.equal(persisted.accepted, true);
  assert.equal(reviewedEvidence.visualInspection.status, 'passed');
  assert.equal(reviewedEvidence.accepted, true);
  assert.throws(() => validateVisualInspection(evidence, { ...review, captures: [review.captures[0], review.captures[0]] }), /exactly once/);
});
test('synthetic watcher signals owned stop promptly on script error', async t => {
  const dir = temporary(t);
  await assert.rejects(phaseRun({ project: dir, run: dir, executable: 'never-launched', env: {} }, { args: [] }, async o => {
    fs.writeFileSync(o.stdoutPath, 'SCRIPT ERROR: fixture\n'); fs.writeFileSync(o.stderrPath, '');
    await new Promise(resolve => setTimeout(resolve, 160)); assert.ok(fs.existsSync(o.stopRequestPath)); return clean;
  }));
});
test('synthetic building-contract runs parse then execution with separate artifacts', async t => {
  const dir = ownedTemporary(t), calls = [];
  const result = await runSpecial('building-contract', ['-Contract', 'BuildingPublicationSourceContract.gd', '-OutputDirectory', dir, '-ReportEnvironment', 'BUILDING_SOURCE_REPORT', '-TimeoutSeconds', '7'], async o => {
    calls.push(o); fs.writeFileSync(o.stdoutPath, ''); fs.writeFileSync(o.stderrPath, ''); write(o.summaryPath, clean);
    if (!o.args.includes('--check-only')) write(o.env.BUILDING_SOURCE_REPORT, { passed: true }); return clean;
  });
  assert.equal(calls.length, 2); assert.ok(calls[0].args.includes('--check-only')); assert.ok(!calls[1].args.includes('--check-only'));
  assert.notEqual(calls[0].stdoutPath, calls[1].stdoutPath); assert.notEqual(calls[0].summaryPath, calls[1].summaryPath); assert.equal(result.ownedZero, true);
  const launch = read(path.join(dir, 'launch.json')); for (const source of watchdogSources) assert.match(launch.sourceSha256[source], /^[0-9a-f]{64}$/);
});
test('synthetic failed parse never starts execution', async t => {
  const dir = ownedTemporary(t); let calls = 0;
  await assert.rejects(runSpecial('building-contract', ['-Contract', 'BuildingPublicationSourceContract.gd', '-OutputDirectory', dir, '-ReportEnvironment', 'BUILDING_SOURCE_REPORT'], async o => {
    calls++; fs.writeFileSync(o.stdoutPath, ''); fs.writeFileSync(o.stderrPath, ''); return { ...clean, overallExitCode: 1 };
  })); assert.equal(calls, 1);
});
test('synthetic directory-report binding, missing reports and path traversal fail closed', async t => {
  const dir = ownedTemporary(t); let calls = 0;
  await assert.rejects(runSpecial('building-contract', ['-Contract', 'BuildingPublicationSourceContract.gd', '-OutputDirectory', dir, '-ReportEnvironment', 'BUILDING_SOURCE_REPORT', '-OutputIsDirectory'], async o => {
    calls++; assert.equal(o.env.BUILDING_SOURCE_REPORT, dir); fs.writeFileSync(o.stdoutPath, ''); fs.writeFileSync(o.stderrPath, ''); return clean;
  })); assert.equal(calls, 2);
  await assert.rejects(runSpecial('building-contract', ['-Contract', 'res://artifacts/citadel-runtime-integration/../../../outside.gd', '-OutputDirectory', ownedTemporary(t), '-ReportEnvironment', 'BUILDING_REPORT'], async () => { throw new Error('must not launch'); }), /Invalid artifact contract path/);
});
test('explicit focused fixture specifications retain non-generic acceptance gates', () => {
  assert.equal(specs['citadel-site-selection-contract'].reportSchema, 'citadel-site-selection-contract/v1');
  assert.equal(specs['citadel-site-selection-contract'].membership, true);
  assert.equal(specs['building-publication-worker-contract'].complete, true);
  assert.equal(specs['citadel-publication-preflight'].timeout, 450);
  assert.ok(specs['citadel-native-admission-contract'].files.includes('addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll'));
  for (const spec of Object.values(specs)) { assert.ok(spec.script.startsWith('res://scripts/testing/')); assert.ok(spec.reportEnvironment); assert.ok(!spec.files.some(f => f.endsWith('.ps1'))); }
});
test('all 35 owned wrappers support help without artifacts or engine launch', t => {
  const dir = temporary(t);
  const names = [...Object.keys(specs), ...Object.keys(sourceFiles), 'citadel-compound-cancellation-contract', 'citadel-landscape-cancellation-contract', 'citadel-retained-paving-cancellation-contract'];
  assert.equal(names.length, 35);
  for (const name of names) {
    const output = execFileSync(process.execPath, [path.join(projectDefault, 'tools/run-' + name + '.mjs'), '--help'], { encoding: 'utf8', cwd: dir, windowsHide: true, timeout: 5000 });
    assert.ok(output.includes('Usage: node tools/run-' + name + '.mjs'));
    assert.ok(output.includes('without launching'));
  }
  assert.deepEqual(fs.readdirSync(dir), []);
});
test('synthetic main menu clears fixture variables case-insensitively only in child', async t => {
  const dir = ownedTemporary(t), key = 'voxel_BUILDING_NODE_TEST', previous = process.env[key];
  process.env[key] = 'must-not-reach-menu';
  try {
    const result = await runSpecial('citadel-main-menu-diagnostic', ['-OutputDirectory', dir], async o => {
      assert.equal(o.env[key], undefined); assert.equal(o.env.APPDATA, path.join(dir, 'userdata')); assert.ok(o.liveOwnershipPath);
      fs.writeFileSync(o.stdoutPath, ''); fs.writeFileSync(o.stderrPath, ''); write(o.summaryPath, clean); return { ...clean, runId: o.runId };
    });
    assert.equal(result.launcherClean, true); assert.equal(process.env[key], 'must-not-reach-menu');
  } finally { if (previous === undefined) delete process.env[key]; else process.env[key] = previous; }
});

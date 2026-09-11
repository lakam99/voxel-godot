import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, appendFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { expectedError, parseOptions, recipeOptions, teleportOptions, regionCoordinates, freshDirectory, recipeStopReason, validateRecipeErrors, ownedPassed, startCandidateWatcher, runCandidatePhase, auditSources, sha256, sourceHashes, helperSource, watchdogSource, watchdogDependencies, engineErrors, readJson, writeJson } from '../lib/citadel-candidate-runner.mjs';
import { recipeVerification, runRecipeDiagnostic } from '../run-citadel-candidate-recipe-diagnostic.mjs';
import { validateTeleportReport, runTeleportPlaytest } from '../run-citadel-candidate-teleport-playtest.mjs';
import { runWatcherCases } from '../test-candidate-recipe-error-watcher.mjs';

async function temporary(t) {
  const dir = await mkdtemp(join(tmpdir(), 'citadel-candidate-unit-'));
  t.after(async () => {
    assert.equal(resolve(dir).startsWith(resolve(tmpdir()) + (process.platform === 'win32' ? '\\' : '/')), true);
    await rm(dir, { recursive: true, force: true });
  });
  return dir;
}
const goodOwned = { overallExitCode: 0, cleanupPassed: true, authoritativeZeroProven: true };

test('CLI preserves PowerShell-style names and negative regions, accepts kebab-case, rejects unknown/missing/duplicate options', () => {
  assert.deepEqual(parseOptions(['-OutputDirectory', 'out', '-CandidateRegion', '-1,0', '-CaptureBlueprint'], 'recipe'), { outputDirectory: 'out', candidateRegion: '-1,0', captureBlueprint: true });
  assert.deepEqual(parseOptions(['--output-directory=out', '-ExpectReady:$false', '--capture-failure=true'], 'recipe'), { outputDirectory: 'out', expectReady: false, captureFailure: true });
  for (const args of [[], ['-OutputDirectory'], ['-Unknown'], ['-OutputDirectory', 'out', '-OutputDirectory', 'again'], ['-OutputDirectory', 'out', '-CaptureFailure=nope']]) assert.throws(() => parseOptions(args, 'recipe'));
});
test('recipe modes retain ceilings, expected error policy, and exclusivity', () => {
  for (const [mode, run, source, proof, error] of [['default', 180, 150, 0, expectedError], ['captureFailure', 540, 450, 0, expectedError], ['captureBlueprint', 540, 450, 0, ''], ['expectReady', 540, 450, 60, '']]) {
    const o = recipeOptions(mode === 'default' ? {} : { [mode]: true });
    assert.deepEqual([o.runSeconds, o.sourceSeconds, o.proofSeconds, o.expectedError], [run, source, proof, error]);
    assert.equal(o.expectedRecipeSeed, 1747969299);
  }
  for (const input of [{ captureBlueprint: true, expectReady: true }, { captureFailure: true, expectReady: true }, { captureFailure: true, captureBlueprint: true }, { expectedRecipeSeed: -1 }, { expectedRecipeSeed: 2147483648 }, { expectedRecipeSeed: '1.5' }, { seed: ' ' }, { seed: 'x'.repeat(129) }]) assert.throws(() => recipeOptions(input));
  assert.equal(recipeOptions({ expectedRecipeSeed: '0' }).expectedRecipeSeed, 0);
});
test('canonical region field bounds and teleport environment/deadline validation', () => {
  const spawn = teleportOptions(parseOptions(['-OutputDirectory','out','-SpawnCell','-3334,-2666','-CandidateRegion','-2,-2','-SkipTutorial'], 'teleport'), {});
  assert.equal(spawn.spawnCell, '-3334,-2666');
  assert.deepEqual(spawn.gameArguments, ['-SkipTutorial']);
  for (const input of [{ spawnCell: '1,2' }, { spawnCell: '1,2', skipTutorial: true }, { spawnCell: '1,2', candidateRegion: '0,0' }, { spawnCell: '1.5,2', skipTutorial: true, candidateRegion: '0,0' }]) assert.throws(() => teleportOptions(input, {}));
  assert.equal(teleportOptions({}, {}).resolution, '1280x720');
  assert.equal(teleportOptions(parseOptions(['-OutputDirectory','out','-Resolution','1920x1080'], 'teleport'), {}).resolution, '1920x1080');
  for (const resolution of ['0x0', '1920x0', '1280x720 --headless', null]) assert.throws(() => teleportOptions({ resolution }, {}));
  const flags = parseOptions(['-OutputDirectory','out','-SkipTutorial','-ForceDaytime','-ForceClearWeather','-StartupTimeoutSeconds','45'], 'teleport');
  const launch = teleportOptions(flags, {});
  assert.deepEqual(launch.gameArguments, ['-SkipTutorial','-ForceDaytime','-ForceClearWeather']);
  assert.equal(launch.overallTimeoutSeconds,645);
  const manual = teleportOptions(parseOptions(['-OutputDirectory','out','-ManualInspection'], 'teleport'), {});
  assert.equal(manual.manualInspectionSeconds,1800);
  assert.equal(manual.overallTimeoutSeconds,2520);
  assert.equal(manual.timeoutSeconds,600);
  assert.throws(()=>teleportOptions({manualInspection:'true'},{}));
  assert.deepEqual(teleportOptions({},{}).gameArguments,[]);
  assert.throws(()=>teleportOptions({skipTutorial:'false'},{}));
  for(const startupTimeoutSeconds of [14,181,'no']) assert.throws(()=>teleportOptions({startupTimeoutSeconds},{}));
  assert.deepEqual(regionCoordinates('-1048576,1048575'), [-1048576, 1048575]);
  for (const region of ['-0,0', '00,1', '+1,0', '1, 0', '0,0\n', '1048576,0', '-1048577,0', '', '1.0,0']) assert.throws(() => regionCoordinates(region));
  assert.equal(teleportOptions({}, {}).timeoutSeconds, 600);
  assert.equal(teleportOptions({ timeoutSeconds: '90' }, { VOXEL_EMPTY: '' }).timeoutSeconds, 90);
  for (const timeoutSeconds of [89, 601, 90.5, 'x']) assert.throws(() => teleportOptions({ timeoutSeconds }, {}));
  assert.throws(() => teleportOptions({}, { VOXEL_FAST_BOOT: '0' }), /Unset inherited/);
  assert.throws(() => teleportOptions({}, { voxel_test: '1' }), /Unset inherited/);
  const diagnostic = teleportOptions(parseOptions(['-OutputDirectory','out','-CaptureNavigationRejections'], 'teleport'), {});
  assert.equal(diagnostic.captureNavigationRejections, true);
  assert.deepEqual(diagnostic.gameArguments, []);
  assert.throws(() => teleportOptions({captureNavigationRejections:true}, {VOXEL_NAVIGATION_REJECTION_DIAGNOSTICS:'1'}), /Unset inherited/);
  assert.throws(() => teleportOptions({captureNavigationRejections:'true'}, {}), /Invalid boolean/);
});
test('fresh direct artifact directories never overwrite evidence or allow traversal', async t => {
  const project = await temporary(t);
  const relative = 'artifacts/citadel-runtime-integration/candidate-recipe-one';
  const dir = await freshDirectory(project, relative, 'candidate-recipe-');
  await writeFile(join(dir, 'evidence'), 'keep');
  await assert.rejects(freshDirectory(project, relative, 'candidate-recipe-'), /Fresh output/);
  assert.equal(await readFile(join(dir, 'evidence'), 'utf8'), 'keep');
  for (const path of ['../candidate-recipe-escape', 'artifacts/citadel-runtime-integration/nested/candidate-recipe-two', 'artifacts/citadel-runtime-integration/candidate-teleport-two']) await assert.rejects(freshDirectory(project, path, 'candidate-recipe-'));
});
test('actual watcher synthetic five-case regression with repeated unchanged polls', async t => {
  const rows = await runWatcherCases(await temporary(t));
  assert.equal(rows.length, 5); assert.ok(rows.every(row => row.passed));
});
test('recipe allowance is exact, once across logs, and final scan rejects warnings/leaks', async t => {
  const logs = [`  ${expectedError}  \ntrace`, ''];
  for (let i = 0; i < 8; i++) assert.equal(recipeStopReason(logs, expectedError), '');
  assert.match(recipeStopReason([expectedError, expectedError], expectedError), /^Repeated/);
  for (const line of [expectedError.toLowerCase(), expectedError + ' detail', 'WARNING: x', 'Parse Error: x']) assert.equal(recipeStopReason([line], expectedError), line);
  assert.throws(() => validateRecipeErrors([], expectedError, true), /exactly one/);
  assert.throws(() => validateRecipeErrors([expectedError, expectedError], expectedError, true), /exactly one/);
  validateRecipeErrors([expectedError], expectedError, true);
  const dir = await temporary(t), path = join(dir, 'log');
  await writeFile(path, '\uFEFFWARNING: x\nObject leaked\nresources still in use\nbenign\n');
  const errors = await engineErrors([path]);
  assert.equal(errors.length, 3);
  assert.throws(() => validateRecipeErrors(errors, '', false), /Unexpected/);
});
test('teleport watcher detects split error tokens, rejects log shrink, defers warnings to final scan', async t => {
  const dir = await temporary(t);
  for (const scenario of ['split', 'shrink', 'warning']) {
    const stdoutPath = join(dir, scenario + '-out'), stderrPath = join(dir, scenario + '-err'), stopRequestPath = join(dir, scenario + '-stop');
    await writeFile(stdoutPath, scenario === 'split' ? 'SCRIPT ER' : 'a'.repeat(100)); await writeFile(stderrPath, '');
    const watcher = startCandidateWatcher({ stdoutPath, stderrPath, stopRequestPath, kind: 'teleport', intervalMs: 10000 });
    try {
      await watcher.poll();
      if (scenario === 'split') await appendFile(stdoutPath, 'ROR: failure');
      if (scenario === 'shrink') await writeFile(stdoutPath, '');
      if (scenario === 'warning') await appendFile(stdoutPath, 'WARNING: final-only');
      await watcher.poll();
      if (scenario === 'split') assert.match(await readFile(stopRequestPath, 'utf8'), /Immediate owned stop: SCRIPT ERROR:/);
      if (scenario === 'shrink') { assert.equal(watcher.failed, true); assert.match(await readFile(stopRequestPath + '.watcher-error.txt', 'utf8'), /shrank/); }
      if (scenario === 'warning') { assert.equal(watcher.reason, ''); assert.equal((await engineErrors([stdoutPath])).length, 1); }
    } finally { await watcher.stop(); }
  }
});
test('watcher read failure writes independent error and requests owned stop', async t => {
  const dir = await temporary(t), out = join(dir, 'out'); await mkdir(out);
  const stop = join(dir, 'stop');
  const watcher = startCandidateWatcher({ stdoutPath: out, stderrPath: join(dir, 'missing'), stopRequestPath: stop });
  await watcher.stop();
  assert.equal(watcher.failed, true);
  assert.equal(await readFile(stop, 'utf8'), 'watcher failure');
  assert.ok(await readFile(stop + '.watcher-error.txt', 'utf8'));
});
test('owned phase delegates exact args/env and budgets; final scan catches fast exits without process launches', async t => {
  const run = await temporary(t), project = join(run, 'project');
  const env = { SENTINEL: 'unchanged' }, args = ['--headless', '--path', project, '--script', 'fixture', '--check-only'];
  const result = await runCandidatePhase({ project, run, args, env, timeoutSeconds: 15, prefix: 'parse-', kind: 'recipe', runOwnedProcess: async options => {
    assert.equal(options.projectPath, project); assert.deepEqual(options.args, args); assert.equal(options.env, env);
    assert.equal(options.timeoutSeconds, 15); assert.equal(options.finalCleanupTimeoutMilliseconds, 15000);
    await writeFile(options.stdoutPath, 'WARNING: fast exit'); await writeFile(options.stderrPath, '');
    return goodOwned;
  } });
  assert.equal(result.stopRequested, true); assert.equal(result.watcherFailed, false);
  assert.equal(ownedPassed(goodOwned), true);
  for (const field of ['overallExitCode', 'cleanupPassed', 'authoritativeZeroProven']) assert.equal(ownedPassed({ ...goodOwned, [field]: null }), false);
  const teleport = await runCandidatePhase({ project, run, args: ['--path', project], env, timeoutSeconds: 600, kind: 'teleport', runOwnedProcess: async options => {
    assert.equal(options.liveOwnershipPath, join(run, 'live-ownership.json'));
    assert.equal(options.finalCleanupTimeoutMilliseconds, undefined);
    await writeFile(options.stdoutPath, ''); await writeFile(options.stderrPath, ''); return goodOwned;
  } });
  assert.equal(teleport.stopRequested, false);
  await assert.rejects(runCandidatePhase({ project, run, args, env, timeoutSeconds: 15, prefix: 'throw-', kind: 'recipe', runOwnedProcess: async () => { throw new Error('owned launch failed'); } }), /owned launch failed/);
});
test('source SHA256 audit records changed and missing sources without losing remaining hashes', async t => {
  const dir = await temporary(t);
  await writeFile(join(dir, 'same'), 'abc'); await writeFile(join(dir, 'changed'), 'after');
  const hash = await sha256(join(dir, 'same'));
  assert.equal(hash, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  const audit = await auditSources(dir, { same: hash, changed: hash, missing: hash });
  assert.equal(audit.unchanged, false); assert.equal(audit.sourceCount, 3);
  assert.deepEqual(audit.changedSources.map(row => row.path), ['changed']); assert.deepEqual(audit.readErrors.map(row => row.path), ['missing']);
  assert.equal(audit.finalSourceHashes.same, hash);
});
test('hash inventories include untracked scripts and teleport scenes plus explicit native/runner sources', async t => {
  const dir = await temporary(t);
  execFileSync('git', ['init', dir], { windowsHide: true, stdio: 'ignore' });
  const recipe = 'tools/run-citadel-candidate-recipe-diagnostic.mjs', teleport = 'tools/run-citadel-candidate-teleport-playtest.mjs';
  const files = [recipe, teleport, helperSource, watchdogSource,
    'scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd', 'scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd', 'scripts/perf/RuntimeRenderObservation.gd', 'addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll', 'scripts/tracked.gd', 'scenes/tracked.tscn', 'project.godot', ...watchdogDependencies];
  for (const path of files) { await mkdir(join(dir, path, '..'), { recursive: true }); await writeFile(join(dir, path), path); }
  execFileSync('git', ['-C', dir, 'add', '.'], { windowsHide: true });
  await writeFile(join(dir, 'scripts/untracked.gd'), 'untracked');
  const a = await sourceHashes(dir, 'recipe', recipe), b = await sourceHashes(dir, 'teleport', teleport);
  assert.ok(a['scripts/untracked.gd']); assert.ok(b['scripts/untracked.gd']);
  assert.ok(b['scenes/tracked.tscn']); assert.ok(b['project.godot']); assert.ok(b['addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll']);
  assert.ok(a[recipe]); assert.ok(b[teleport]);
  for (const hashes of [a, b]) {
    assert.ok(hashes[helperSource]); assert.ok(hashes[watchdogSource]);
    for (const file of watchdogDependencies) assert.ok(hashes[file]);
    assert.equal(Object.keys(hashes).some(file => file.endsWith('.ps1')), false);
  }
});
test('all recipe receipts preserve failure vs capture vs independent proof requirements', () => {
  const failure = { diagnosticCompleted: true, expectedFailureReproduced: true, passed: false };
  for (const o of [recipeOptions({}), recipeOptions({ captureFailure: true })]) {
    assert.equal(recipeVerification(o, failure, [], false, '/run').diagnosticVerified, true);
    assert.equal(recipeVerification(o, { ...failure, passed: true }, [], true, '/run').diagnosticVerified, false);
    assert.equal(recipeVerification(o, failure, ['changed'], true, '/run').diagnosticVerified, false);
  }
  const blueprint = { diagnosticCompleted: true, captureCompleted: true, recipePassed: false, passed: false, receipt: { contextUnchanged: true, sourceWithinDeadline: true } };
  const ready = { diagnosticCompleted: true, recipePassed: true, passed: true, receipt: { physicalPassed: true, physicalViolationCount: 0, contextUnchanged: true } };
  for (const [o, report] of [[recipeOptions({ captureBlueprint: true }), blueprint], [recipeOptions({ expectReady: true }), ready]]) {
    assert.equal(recipeVerification(o, report, [], true, '/run').diagnosticVerified, true);
    assert.equal(recipeVerification(o, report, [], false, '/run').diagnosticVerified, false);
    for (const key of Object.keys(report.receipt)) assert.equal(recipeVerification(o, { ...report, receipt: { ...report.receipt, [key]: null } }, [], true, '/run').diagnosticVerified, false);
  }
});
test('teleport validates exact seed, actual seed, successful report and each saved file', async () => {
  const report = { passed: true, seed: 'Atlas', actualSeed: 'Atlas', captures: [{ saved: true, path: '/capture.png' }] };
  await validateTeleportReport(report, 'Atlas', async path => path === '/capture.png');
  for (const override of [{ passed: false }, { seed: 'atlas' }, { actualSeed: 'other' }, { captures: null }, { captures: [{ saved: false, path: '/capture.png' }] }]) await assert.rejects(validateTeleportReport({ ...report, ...override }, 'Atlas', async () => true));
  await assert.rejects(validateTeleportReport(report, 'Atlas', async () => false), /Missing/);
});

test('mocked recipe orchestration preserves all modes, isolated env, phase order, and final audit on failure', async t => {
  const project = await temporary(t);
  await writeFile(join(project, 'source.gd'), 'frozen');
  const hash = await sha256(join(project, 'source.gd'));
  const environment = { APPDATA: 'original', LOCALAPPDATA: 'original-local', EXTRA: 'preserve' };
  for (const mode of ['default', 'captureFailure', 'captureBlueprint', 'expectReady', 'parseFailure', 'throwFailure', 'missingReport', 'sourceChanged']) {
    const outputDirectory = `artifacts/citadel-runtime-integration/candidate-recipe-${mode}`;
    const run = join(project, outputDirectory);
    const phases = [];
    const input = { outputDirectory, ...(['captureFailure', 'captureBlueprint', 'expectReady'].includes(mode) ? { [mode]: true } : {}) };
    const action = runRecipeDiagnostic(input, {
      projectPath: project, env: environment, sourceHashes: async () => ({ 'source.gd': hash }), git: () => 'synthetic-head\n',
      runOwnedProcess: async options => {
        const parse = options.args.includes('--check-only'); phases.push(parse ? 'parse' : 'run');
        assert.equal(options.env.APPDATA, join(run, 'userdata')); assert.equal(options.env.EXTRA, 'preserve');
        assert.equal(environment.APPDATA, 'original');
        assert.equal(options.env.CITADEL_CANDIDATE_RECIPE_REGION, '0,-1');
        assert.equal(options.env.CITADEL_CANDIDATE_RECIPE_EXPECTED, '1747969299');
        assert.equal(options.env.CITADEL_CANDIDATE_EXPECT_READY, mode === 'expectReady' ? '1' : '0');
        assert.equal(options.env.CITADEL_CANDIDATE_CAPTURE_BLUEPRINT, mode === 'captureBlueprint' ? '1' : '0');
        assert.equal(options.env.CITADEL_CANDIDATE_CAPTURE_FAILURE, mode === 'captureFailure' ? '1' : '0');
        assert.equal(options.finalCleanupTimeoutMilliseconds, 15000);
        if (mode === 'throwFailure') throw new Error('mock watchdog failure');
        await writeFile(options.stdoutPath, !parse && !['expectReady', 'captureBlueprint'].includes(mode) ? expectedError + '\n' : '');
        await writeFile(options.stderrPath, '');
        if (mode === 'parseFailure') return { ...goodOwned, overallExitCode: 1 };
        if (!parse) {
          assert.equal(options.timeoutSeconds, ['captureFailure', 'captureBlueprint', 'expectReady'].includes(mode) ? 540 : 180);
          const report = mode === 'expectReady' ? { diagnosticCompleted: true, recipePassed: true, passed: true, receipt: { physicalPassed: true, physicalViolationCount: 0, contextUnchanged: true } }
            : mode === 'captureBlueprint' ? { diagnosticCompleted: true, captureCompleted: true, recipePassed: false, passed: false, receipt: { contextUnchanged: true, sourceWithinDeadline: true } }
              : { diagnosticCompleted: true, expectedFailureReproduced: true, passed: false };
          if (mode !== 'missingReport') await writeJson(join(run, 'report.json'), report);
          await writeFile(join(run, mode === 'expectReady' ? 'source.bin' : mode === 'captureBlueprint' ? 'caller-blueprint.bin' : 'failure.json'), 'synthetic');
          if (mode === 'sourceChanged') await writeFile(join(project, 'source.gd'), 'changed');
        } else assert.equal(options.timeoutSeconds, 15);
        return goodOwned;
      },
    });
    if (['parseFailure', 'throwFailure', 'missingReport', 'sourceChanged'].includes(mode)) await assert.rejects(action);
    else { const result = await action; assert.equal(result.diagnosticVerified, true); assert.equal(result.recipePassed, mode === 'expectReady'); }
    assert.deepEqual(phases, ['parseFailure', 'throwFailure'].includes(mode) ? ['parse'] : ['parse', 'run']);
    const audit = await readJson(join(run, 'source-hash-audit.json'));
    assert.equal(audit.unchanged, mode !== 'sourceChanged'); assert.equal(audit.sourceCount, 1);
    const launch = await readJson(join(run, 'launch.json'));
    assert.equal(launch.maximumOwnedPhasesSeconds, launch.runTimeoutSeconds + 49);
    assert.equal(environment.APPDATA, 'original');
  }
});

test('mocked teleport orchestration preserves headed args, live ownership and verification failures', async t => {
  const project = await temporary(t), environment = { APPDATA: 'original', EXTRA: 'preserve' };
  await writeFile(join(project, 'source.gd'), 'frozen');
  const hash = await sha256(join(project, 'source.gd'));
  for (const mode of ['success', 'cleanup', 'warning', 'missingCapture', 'wrongSeed', 'missingReport', 'sourceChanged']) {
    const outputDirectory = `artifacts/citadel-runtime-integration/candidate-teleport-${mode}`, run = join(project, outputDirectory);
    const action = runTeleportPlaytest({ outputDirectory, seed: 'Exact-Seed', candidateRegion: '-1,0', timeoutSeconds: 90 }, {
      projectPath: project, env: environment, sourceHashes: async () => ({ 'source.gd': hash }), git: () => 'synthetic-head',
      runOwnedProcess: async options => {
        assert.deepEqual(options.args, ['--path', project, '--script', 'res://scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd', '--resolution', '1280x720', '--windowed']);
        assert.equal(options.timeoutSeconds, 210); assert.equal(options.liveOwnershipPath, join(run, 'live-ownership.json'));
        assert.equal(options.env.CITADEL_CANDIDATE_TELEPORT_SECONDS, '90'); assert.equal(options.env.CITADEL_CANDIDATE_TELEPORT_REGION, '-1,0');
        assert.equal(options.env.CITADEL_CANDIDATE_TELEPORT_SEED, 'Exact-Seed'); assert.equal(options.env.APPDATA, join(run, 'userdata'));
        await writeFile(options.stdoutPath, mode === 'warning' ? 'WARNING: unexpected' : ''); await writeFile(options.stderrPath, '');
        const capture = join(run, 'capture.png'); if (mode !== 'missingCapture') await writeFile(capture, 'synthetic');
        if (mode !== 'missingReport') await writeJson(join(run, 'report.json'), { passed: true, seed: 'Exact-Seed', actualSeed: mode === 'wrongSeed' ? 'wrong' : 'Exact-Seed', outcome: 'synthetic', setupPlacements: [{}, {}], captures: [{ saved: true, path: capture }] });
        if (mode === 'sourceChanged') await writeFile(join(project, 'source.gd'), 'changed');
        return { ...goodOwned, rootExited: true, forcedCleanup: false, timedOut: false, functionalExitCode: 0, cleanupPassed: mode !== 'cleanup' };
      },
    });
    if (mode === 'success') { const result = await action; assert.equal(result.passed, true); assert.equal(result.setupPlacements, 2); assert.equal(result.visualInspectionRequired, true); }
    else await assert.rejects(action);
    const verification = await readJson(join(run, 'verification.json'));
    assert.equal(verification.visualInspectionRequired, true); assert.equal(verification.naturalExit, true);
    assert.equal(verification.engineErrorWarningCount, mode === 'warning' ? 1 : 0);
    assert.equal((await readJson(join(run, 'launch.json'))).internalDeadlineSeconds, 45);
    assert.equal(environment.APPDATA, 'original');
  }
});

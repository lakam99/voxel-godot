import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { runOwnedProcess } from '../lib/owned-process.mjs';
import { parseWatchdogArguments } from '../run-godot-scene-watchdog.mjs';
import { requireOwnedWindowsTick } from '../lib/owned-live-clock.mjs';
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';

const fixture = path.join(import.meta.dirname, 'owned-process-fixture.mjs');
const root = mkdtempSync(path.join(tmpdir(), 'owned-watchdog-tests-'));
console.log('Watchdog fixture reports: ' + root);
const sleep = ms => new Promise(r => setTimeout(r, ms));
let sequence = 0;
function options(mode, extra = {}) {
  const dir = path.join(root, String(++sequence));
  return { projectPath: root, executable: process.execPath, args: [fixture, mode],
    timeoutSeconds: 5, cleanupGraceMilliseconds: 100, finalCleanupTimeoutMilliseconds: 3000,
    stdoutPath: path.join(dir, 'stdout.log'), stderrPath: path.join(dir, 'stderr.log'),
    summaryPath: path.join(dir, 'summary.json'), ...extra };
}
function running(pid) { try { process.kill(pid, 0); return true; } catch { return false; } }
async function until(predicate, milliseconds = 8000) {
  const deadline = Date.now() + milliseconds;
  while (Date.now() < deadline) { const value = predicate(); if (value) return value; await sleep(30); }
  throw new Error('Fixture observation deadline expired');
}
function readJson(file) { try { return JSON.parse(readFileSync(file, 'utf8')); } catch { return null; } }
function zero(s) { assert.equal(s.authoritativeZeroProven, true, JSON.stringify(s)); assert.deepEqual(s.finalJobMemberPids, []); }

test('synthetic live replacement contention retries briefly but persistent failure still terminates', { skip: process.platform !== 'win32' }, async () => {
  for (const failures of [2, Infinity]) {
    const o = options('exit', { args: ['-e', 'setTimeout(()=>process.exit(0),500)'],
      liveOwnershipPath: path.join(root, `retry-${failures}.json`) });
    const original = fs.renameSync;
    let injected = 0;
    fs.renameSync = (from, to) => {
      if (to === o.liveOwnershipPath && injected < failures) {
        injected++;
        throw Object.assign(new Error('Injected Windows replacement contention'), { code: 'EPERM', syscall: 'rename' });
      }
      return original(from, to);
    };
    syncBuiltinESMExports();
    let result;
    try { result = await runOwnedProcess(o); }
    finally { fs.renameSync = original; syncBuiltinESMExports(); }
    zero(result);
    if (failures === 2) {
      assert.equal(injected, 2); assert.equal(result.overallExitCode, 0);
      assert.equal(result.liveOwnershipError, null); assert.equal(result.forcedCleanup, false);
    } else {
      assert.ok(injected >= 4); assert.notEqual(result.overallExitCode, 0);
      assert.equal(result.forcedCleanup, true); assert.match(result.liveOwnershipError, /contention/);
    }
  }
});

test('run-specific abort cancels owned tree without needing a writable stop file', { skip: process.platform !== 'win32' }, async()=>{
  const controller=new AbortController();
  const o=options('tree',{signal:controller.signal});
  const pending=runOwnedProcess(o);
  await until(()=>{try{return readFileSync(o.stdoutPath,'utf8').includes('child');}catch{return false;}});
  controller.abort();
  const result=await pending;
  assert.equal(result.stopRequested,true);assert.equal(result.timedOut,false);assert.notEqual(result.overallExitCode,0);zero(result);
});

test('live clock contract rejects missing/malformed native timestamps without a Node clock fallback', () => {
  for (const value of [undefined, null, '', 123, 123n, 'NaN', '-1', '1.5', '1e3',
    ' 123', '123\n', '18446744073709551616', '999999999999999999999']) {
    assert.throws(() => requireOwnedWindowsTick(value), /Windows GetTickCount64/);
  }
  for (const value of ['0', '2472078', '9007199254740993', '18446744073709551615'])
    assert.equal(requireOwnedWindowsTick(value), value);
});

test('CLI camelcase, kebab and PowerShell parameter spelling preserve argv', () => {
  for (const flag of ['--projectPath', '--project-path', '-ProjectPath']) {
    const p = parseWatchdogArguments([flag, root, '-GodotExe', process.execPath, '-Scene', 'res://x.tscn',
      '-Headless', '--timeout-seconds', '0', '--', '--child-flag', 'a b']);
    assert.equal(p.timeoutSeconds, '0');
    assert.deepEqual(p.args, ['--headless', '--path', root, 'res://x.tscn', '--child-flag', 'a b']);
  }
  assert.throws(() => parseWatchdogArguments(['--wat']), /Unknown/);
});

test('CLI help is launch-free and creates no watchdog outputs', async () => {
  for (const flag of ['--help', '-Help']) {
    assert.deepEqual(parseWatchdogArguments([flag]), { help: true });
    const cwd = mkdtempSync(path.join(root, 'help-'));
    const child = spawn(process.execPath, ['--import',
      pathToFileURL(path.join(import.meta.dirname, 'owned-process-no-launch.mjs')).href,
      path.join(import.meta.dirname, '../run-godot-scene-watchdog.mjs'), flag],
      { cwd, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '', diagnostics = '';
    child.stdout.on('data', b => { output += b; });
    child.stderr.on('data', b => { diagnostics += b; });
    const [code] = await once(child, 'close');
    assert.equal(code, 0, diagnostics);
    assert.match(output, /Usage:/); assert.match(output, /0 disables deadline/);
    assert.equal(diagnostics, ''); assert.deepEqual(readdirSync(cwd), []);
  }
  assert.deepEqual(parseWatchdogArguments(['--executable', process.execPath, '--', '--help']).args, ['--help']);
});

test('real Windows owned-process fixtures', { skip: process.platform !== 'win32', timeout: 90000 }, async t => {
  await t.test('argv, complete env, output capture, atomic membership and successful cleanup', async () => {
    const values = ['', 'a b', 'a"b', 'C:\\space path\\', 'two\\\\"quotes', '日本語', '$(); &'];
    // This Node build requires SystemRoot for its native crypto initialization.
    // PATH and all other parent entries must still be absent from the child.
    const o = options('echo', { args: [fixture, 'echo', ...values],
      env: { ONLY_OWNED_FIXTURE: 'yes', SystemRoot: process.env.SystemRoot } });
    const s = await runOwnedProcess(o);
    assert.equal(s.overallExitCode, 0, JSON.stringify(s)); assert.equal(s.cleanupPassed, true); zero(s);
    const echo = readJson(o.stdoutPath);
    assert.deepEqual(echo.args, values);
    assert.equal(echo.env.ONLY_OWNED_FIXTURE, 'yes'); assert.equal(echo.env.PATH, undefined);
    assert.equal(echo.cwd, root);
    assert.match(readFileSync(o.stderrPath, 'utf8'), /fixture stderr/);
    assert.equal(s.assignedAtomicallyByProcThreadAttributeJobList, true);
    assert.deepEqual(s.jobMembershipEvidence[0].memberPids, [s.rootPid]);
    assert.equal(readJson(o.summaryPath).overallExitCode, 0);
  });
  await t.test('nonzero functional result remains separate from clean cleanup', async () => {
    const s = await runOwnedProcess(options('exit', { args: [fixture, 'exit', '23'] }));
    assert.equal(s.functionalExitCode, 23); assert.equal(s.overallExitCode, 23);
    assert.equal(s.cleanupPassed, true); zero(s);
  });
  await t.test('CLI executes a harmless Node child and returns the functional status', async () => {
    const o = options('exit');
    const child = spawn(process.execPath, [path.join(import.meta.dirname, '../run-godot-scene-watchdog.mjs'),
      '-ProjectPath', root, '--executable', process.execPath, '--timeoutSeconds', '5',
      '--stdout-path', o.stdoutPath, '-StderrPath', o.stderrPath, '--summaryPath', o.summaryPath,
      '--', fixture, 'exit', '17'], { stdio: ['ignore', 'pipe', 'pipe'] });
    let text = ''; child.stdout.on('data', b => { text += b; });
    const [code] = await once(child, 'close');
    assert.equal(code, 17);
    const s = JSON.parse(text); assert.equal(s.functionalExitCode, 17); zero(s);
    assert.equal(readJson(o.summaryPath).cleanupPassed, true);
  });
  await t.test('native CreateProcess failure produces a durable launch-failure result', async () => {
    const exe = path.join(root, 'not-executable.exe'); writeFileSync(exe, 'not an executable');
    const o = options('hold', { executable: exe }), s = await runOwnedProcess(o);
    assert.equal(s.overallExitCode, 127, JSON.stringify(s));
    assert.equal(s.nativeCreateReachedProcess, false); assert.equal(s.processCreatedSuspended, false);
    assert.match(s.fatalException, /CreateProcessW/);
    assert.equal(readJson(o.summaryPath).overallExitCode, 127);
  });
  for (const mode of ['scratch', 'publication']) {
    await t.test('synthetic ' + mode + ' failure keeps durable report, returned JSON and CLI exit aligned', async () => {
      const o = options('exit'), marker = path.join(root, mode + '.injected');
      const child = spawn(process.execPath, [
        '--import', pathToFileURL(path.join(import.meta.dirname, 'owned-process-publication-fault.mjs')).href,
        path.join(import.meta.dirname, '../run-godot-scene-watchdog.mjs'),
        '--projectPath', root, '--executable', process.execPath, '--timeoutSeconds', '5',
        '--stdoutPath', o.stdoutPath, '--stderrPath', o.stderrPath, '--summaryPath', o.summaryPath,
        '--', fixture, 'exit', '0'], {
        env: { ...process.env, OWNED_TEST_FAULT: mode, OWNED_TEST_SUMMARY: o.summaryPath,
          OWNED_TEST_FAULT_MARKER: marker }, stdio: ['ignore', 'pipe', 'pipe'],
      });
      let output = '', diagnostics = '';
      child.stdout.on('data', b => { output += b; });
      child.stderr.on('data', b => { diagnostics += b; });
      const [code] = await once(child, 'close');
      assert.ok(existsSync(marker), diagnostics || output || 'Fault preload did not execute');
      assert.equal(readFileSync(marker, 'utf8'), mode, 'fault must actually trigger');
      const returned = JSON.parse(output), saved = readJson(o.summaryPath);
      assert.deepEqual(saved, returned, 'durable report must match the returned CLI object');
      assert.equal(code, returned.overallExitCode);
      assert.equal(returned.functionalExitCode, 0);
      assert.equal(returned.authoritativeZeroProven, true);
      if (mode === 'scratch') {
        assert.equal(code, 0); assert.equal(saved.cleanupPassed, true);
        assert.equal(saved.schema, 'godot-scene-watchdog/v5');
      } else {
        assert.equal(code, 126); assert.equal(saved.cleanupPassed, false);
        assert.equal(saved.schema, 'godot-scene-watchdog/emergency-v1');
        assert.equal(saved.reason, 'primary_summary_failed');
        assert.match(saved.cleanupErrors[0], /synthetic transient publication failure/);
      }
    });
  }
  await t.test('timeout terminates root and detached descendant but leaves unrelated process alive', async () => {
    const outsider = spawn(process.execPath, [fixture, 'hold'], { stdio: 'ignore' });
    try {
      const o = options('tree', { timeoutSeconds: 1 });
      const start = Date.now(), s = await runOwnedProcess(o), ids = readJson(o.stdoutPath);
      assert.equal(s.timedOut, true); assert.equal(s.overallExitCode, 125, JSON.stringify(s));
      assert.equal(s.functionalExitCode, null); assert.equal(s.cleanupPassed, false); zero(s);
      assert.equal(running(ids.pid), false); assert.equal(running(ids.child), false);
      assert.equal(running(outsider.pid), true); assert.ok(Date.now() - start < 6000);
    } finally { const exited = once(outsider, 'exit'); outsider.kill(); await exited; }
  });
  await t.test('successful root with surviving detached descendant is a cleanup failure', async () => {
    const o = options('orphan'), s = await runOwnedProcess(o);
    assert.equal(s.functionalExitCode, 0); assert.equal(s.overallExitCode, 125);
    assert.equal(s.cleanupPassed, false); zero(s);
    assert.equal(running(readJson(o.stdoutPath).child), false);
  });
  await t.test('interactive no-deadline execution publishes compatible identities and responds to stop', async () => {
    const o = options('tree', { timeoutSeconds: 0, stopRequestPath: path.join(root, 'interactive.stop'),
      liveOwnershipPath: path.join(root, 'interactive.live.json') });
    const promise = runOwnedProcess(o);
    const live = await until(() => { const v = readJson(o.liveOwnershipPath); return v?.state === 'running' && v.members.length >= 2 ? v : null; });
    assert.equal(live.schema, 'godot-live-ownership/v1');
    assert.equal(live.orchestratorPid, process.pid);
    assert.notEqual(live.watchdogPid, process.pid);
    assert.match(live.watchdogCreationFileTime, /^\d+$/);
    assert.match(live.observedTickMilliseconds, /^\d+$/);
    assert.ok(live.members.every(m => /^\d+$/.test(m.creationFileTime)));
    await sleep(1200); assert.equal(running(live.rootPid), true);
    writeFileSync(o.stopRequestPath, 'stop');
    const s = await promise;
    assert.equal(s.stopRequested, true); assert.equal(s.timedOut, false);
    assert.equal(s.overallExitCode, 126); zero(s);
    assert.equal(readJson(o.liveOwnershipPath).state, 'stopping');
  });
  await t.test('monitoring failure stops the owned tree without overwriting foreign live record', async () => {
    const o = options('tree', { liveOwnershipPath: path.join(root, 'tampered.live.json') });
    const promise = runOwnedProcess(o);
    await until(() => readJson(o.liveOwnershipPath)?.state === 'running');
    writeFileSync(o.liveOwnershipPath, JSON.stringify({ runId: 'foreign' }));
    const s = await promise;
    assert.equal(s.overallExitCode, 126); assert.match(s.monitoringException, /changed owner/); zero(s);
    assert.equal(readJson(o.liveOwnershipPath).runId, 'foreign');
  });
  await t.test('loss of Node orchestrator closes private job and kills descendants', async () => {
    const o = options('tree', { timeoutSeconds: 0, liveOwnershipPath: path.join(root, 'parent-loss.live.json') });
    const orchestrator = spawn(process.execPath, [fixture, 'orchestrator', JSON.stringify(o), path.join(root, 'lost-result.json')],
      { stdio: 'ignore' });
    try {
      const live = await until(() => { const v = readJson(o.liveOwnershipPath); return v?.members?.length >= 2 ? v : null; });
      const exited = once(orchestrator, 'exit'); orchestrator.kill(); await exited;
      await until(() => live.members.every(m => !running(m.pid)) && !running(live.watchdogPid));
      assert.equal(existsSync(o.summaryPath), false);
    } finally { if (orchestrator.exitCode === null && orchestrator.signalCode === null) orchestrator.kill(); }
  });
  await t.test('invalid executable and occupied/aliased paths never launch or overwrite', async () => {
    const missing = await runOwnedProcess(options('hold', { executable: path.join(root, 'missing.exe') }));
    assert.equal(missing.overallExitCode, 127); assert.equal(missing.processCreatedSuspended, false);
    const o = options('hold');
    writeFileSync(path.join(root, 'existing'), 'preserve');
    o.stdoutPath = path.join(root, 'existing');
    const s = await runOwnedProcess(o);
    assert.equal(s.overallExitCode, 127); assert.equal(readFileSync(o.stdoutPath, 'utf8'), 'preserve');
    const alias = options('hold'); alias.stderrPath = alias.stdoutPath;
    assert.equal((await runOwnedProcess(alias)).processCreatedSuspended, false);
  });
});

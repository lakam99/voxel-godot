import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync, linkSync, unlinkSync, renameSync, statSync } from 'node:fs';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { buildOwnedNativeHost, openOwnedNativeHost } from './owned-native-host.mjs';
import { requireOwnedWindowsTick } from './owned-live-clock.mjs';

const now = () => new Date().toISOString();
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

export function automatedGodotArguments(executable, args) {
  const result = [...args];
  if (!/godot/i.test(path.basename(executable))) return result;
  if (result.some(argument => argument === '--audio-driver' || argument.startsWith('--audio-driver='))) return result;
  // Test-side bus muting happens after the engine has already initialized its
  // audio backend. Every watchdog-owned Godot launch is automated, so select
  // the engine's non-playing driver before project startup. Production/manual
  // launches outside this owner remain unchanged.
  return ['--audio-driver', 'Dummy', ...result];
}

function environmentBlock(env) {
  const entries = new Map();
  for (const key of Object.keys(env).sort()) {
    const value = env[key];
    if (value === undefined) continue;
    if (!key || key.includes('\0') || key.slice(1).includes('=') || String(value).includes('\0'))
      throw new Error('Invalid environment entry');
    const canonical = key.toUpperCase();
    if (!entries.has(canonical)) entries.set(canonical, key + '=' + String(value));
  }
  return [...entries].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([, v]) => v).join('\0') + '\0\0';
}

function atomicJson(file, value, replace = false) {
  const temporary = file + '.' + randomUUID() + '.tmp';
  try {
    writeFileSync(temporary, JSON.stringify(value) + '\n', { flag: 'wx', flush: true });
    // Hard-link publication is atomic and refuses to overwrite an existing result.
    if (replace) renameSync(temporary, file);
    else linkSync(temporary, file);
  } finally {
    // Publication is the commit point. Scratch-file removal cannot invalidate
    // the committed JSON or mask an earlier publication error. In particular,
    // never return a new failure while the durable summary still says success.
    try { if (existsSync(temporary)) unlinkSync(temporary); } catch { /* Best-effort scratch cleanup. */ }
  }
}
function integer(value, fallback, min, max, name) {
  const n = value === undefined ? fallback : Number(value);
  if (!Number.isInteger(n) || n < min || n > max) throw new Error(name + ' is out of range');
  return n;
}

/**
 * Windows Job Object owned-process runner. env, when supplied, is the COMPLETE
 * child environment; omission inherits process.env. timeoutSeconds=0 is interactive.
 * Resolves a watchdog summary (including launch/monitor failures); callers must
 * inspect overallExitCode separately from functionalExitCode.
 */
export async function runOwnedProcess(options = {}) {
  let emergencyResult;
  const runId = options.runId ?? randomUUID().replaceAll('-', '');
  if (typeof runId !== 'string' || !/^[a-f0-9]{32}$/i.test(runId))
    throw new Error('runId must be exactly 32 hexadecimal characters');
  const s = {
    schema: 'godot-scene-watchdog/v5', runId,
    projectPath: null, executable: null, godotExe: null,
    scene: options.scene ?? null, sceneArguments: options.sceneArguments ?? [],
    headless: !!options.headless, args: [],
    launchTimeUtc: null, completedTimeUtc: null,
    timeoutSeconds: null, cleanupGraceMilliseconds: null, finalCleanupTimeoutMilliseconds: null,
    terminalCleanupElapsedMilliseconds: 0, terminalCleanupExpired: false,
    exactCommandLine: null, rootPid: null, rootThreadId: null,
    processCreatedSuspended: false, assignedAtomicallyByProcThreadAttributeJobList: false,
    primaryThreadResumed: false, nativeCreateReachedProcess: false, launchedProcessRequiresZeroProof: false,
    rootExited: false, functionalExitCode: null, timedOut: false,
    stopRequestPath: null, stopRequested: false, stopRequestedAtUtc: null,
    monitoringException: null, fatalException: null, forcedCleanup: false,
    terminateJobObjectAttempted: false, terminateJobObjectSucceeded: false,
    completionZeroMessageObserved: false, completionZeroWaitTimedOut: false,
    cleanupUnresolved: false, fallbackCaptureAttempted: false, fallbackCaptureSucceeded: false,
    fallbackCaptureError: null, fallbackCapturedPids: [], fallbackJobClosed: false,
    fallbackRetainedWaitFailed: false, fallbackZeroProven: false, postCloseCompletionZeroProven: false,
    authoritativeZeroProven: false, zeroProofSource: null, membershipUncertaintyResolvedByZeroProof: false,
    jobCloseAttempted: false, fallbackPostCloseWaits: [],
    membershipQueryFailed: false, finalMembershipKnown: false, finalJobMemberPids: [],
    cleanupPassed: false, overallExitCode: 127,
    stdoutPath: null, stderrPath: null, summaryPath: null, liveOwnershipPath: null,
    liveOwnershipError: null, liveOwnershipSequence: 0,
    jobMembershipEvidence: [], cleanupErrors: [],
    ownershipAuthority: 'Windows Job Object membership only',
    supportedWindowsBaseline: 'Windows 10 or Windows Server 2016 and later (PROC_THREAD_ATTRIBUTE_JOB_LIST required)',
  };
  let host, initialized = false, jobClosed = false, liveCreated = false, identity;
  let signalReason, terminalStart, terminalDeadline, summarySafe = false;
  const signal = name => { signalReason = name; };
  const onInt = () => signal('SIGINT'), onTerm = () => signal('SIGTERM');
  const onAbort = () => signal('Run-specific abort requested');
  const remaining = () => {
    const n = Math.max(0, Math.floor(terminalDeadline - performance.now()));
    if (n === 0) s.terminalCleanupExpired = true;
    return n;
  };
  const rpc = (op, fields = {}) => host.request(op, fields,
    terminalDeadline === undefined ? 5000 : Math.max(1, remaining()));
  function assertStop() {
    if (signalReason || (s.stopRequestPath && existsSync(s.stopRequestPath))) {
      s.stopRequested = true; s.stopRequestedAtUtc ??= now();
      throw new Error(signalReason || 'Run-local stop requested; terminating the owned Job Object.');
    }
  }
  async function membership(phase, suppress = false) {
    try {
      const ids = await rpc('members');
      // Bound evidence during arbitrarily long interactive runs.
      if (s.jobMembershipEvidence.length >= 256) s.jobMembershipEvidence.splice(1, 1);
      s.jobMembershipEvidence.push({ observedAtUtc: now(), phase, querySucceeded: true, memberPids: ids, error: null });
      return ids;
    } catch (e) {
      s.membershipQueryFailed = true;
      s.jobMembershipEvidence.push({ observedAtUtc: now(), phase, querySucceeded: false, memberPids: [], error: e.message });
      if (!suppress) throw e;
      return null;
    }
  }
  function prove(source) {
    s.authoritativeZeroProven = true; s.cleanupUnresolved = false; s.zeroProofSource = source;
    s.finalMembershipKnown = true; s.finalJobMemberPids = [];
    s.membershipUncertaintyResolvedByZeroProof = s.membershipQueryFailed;
  }
  async function publish(state) {
    if (!s.liveOwnershipPath) return;
    for (let attempt = 0; ; attempt++) {
    try {
      const observation = state === 'running' ? await rpc('live') : { members: [], tick: await rpc('tick') };
      const snapshot = {
        schema: 'godot-live-ownership/v1', runId, state, observedAtUtc: now(),
        observedTickMilliseconds: requireOwnedWindowsTick(observation.tick),
        sequence: ++s.liveOwnershipSequence, maximumAgeMilliseconds: 1000,
        projectPath: s.projectPath, godotExe: s.executable,
        watchdogPid: identity.pid, watchdogCreationFileTime: identity.creationFileTime,
        orchestratorPid: process.pid, rootPid: s.rootPid, members: observation.members,
        authority: 'Windows Job Object membership',
      };
      if (liveCreated && JSON.parse(readFileSync(s.liveOwnershipPath, 'utf8')).runId !== runId)
        throw new Error('Live ownership path changed owner.');
      atomicJson(s.liveOwnershipPath, snapshot, liveCreated); liveCreated = true;
      return;
    } catch (e) {
      // Windows readers may briefly deny replacement. Re-observe job membership
      // and ownership on each bounded retry; never publish a stale receipt or
      // suppress a persistent monitoring failure.
      if (liveCreated && e.syscall === 'rename' && ['EPERM', 'EACCES', 'EBUSY'].includes(e.code) && attempt < 3) {
        await delay(20);
        if (state === 'running') assertStop();
        continue;
      }
      s.liveOwnershipError = e.message; throw e;
    }
    }
  }
  async function closeJob() {
    if (jobClosed) return;
    s.jobCloseAttempted = true; await rpc('closeJob'); jobClosed = true;
  }
  async function terminate() {
    if (s.terminateJobObjectAttempted) return;
    s.forcedCleanup = true; s.terminateJobObjectAttempted = true;
    try {
      await rpc('terminate'); s.terminateJobObjectSucceeded = true;
      const milliseconds = Math.min(remaining(), Math.max(1000, Math.min(10000, s.cleanupGraceMilliseconds)));
      if (!milliseconds) throw new Error('Terminal cleanup deadline expired');
      s.completionZeroMessageObserved = await rpc('zero', { milliseconds });
      s.completionZeroWaitTimedOut = !s.completionZeroMessageObserved;
    } catch (e) { s.cleanupErrors.push(e.message); }
  }
  process.on('SIGINT', onInt); process.on('SIGTERM', onTerm);
  options.signal?.addEventListener('abort', onAbort, { once: true });
  if (options.signal?.aborted) onAbort();
  try {
    s.timeoutSeconds = integer(options.timeoutSeconds, 300, 0, 86400, 'timeoutSeconds');
    s.cleanupGraceMilliseconds = integer(options.cleanupGraceMilliseconds, 2000, 0, 60000, 'cleanupGraceMilliseconds');
    s.finalCleanupTimeoutMilliseconds = integer(options.finalCleanupTimeoutMilliseconds, 30000, 1000, 300000, 'finalCleanupTimeoutMilliseconds');
    s.projectPath = path.resolve(options.projectPath || process.cwd());
    if (!statSync(s.projectPath).isDirectory()) throw new Error('projectPath is not a directory');
    if (!options.executable) throw new Error('executable is required');
    s.executable = s.godotExe = path.resolve(options.executable);
    if (!statSync(s.executable).isFile()) throw new Error('executable is not a file');
    s.args = options.args ?? [];
    if (!Array.isArray(s.args) || s.args.some(a => typeof a !== 'string' || a.includes('\0')))
      throw new Error('args must be an array of NUL-free strings');
    s.args = automatedGodotArguments(s.executable, s.args);
    if (options.env !== undefined && (options.env === null || typeof options.env !== 'object' || Array.isArray(options.env)))
      throw new Error('env must be a complete environment map');
    const base = path.join(s.projectPath, 'artifacts', 'watchdog', runId);
    const paths = new Set();
    for (const [field, suffix] of [['stdoutPath', 'stdout.log'], ['stderrPath', 'stderr.log'],
      ['summaryPath', 'summary.json'], ['stopRequestPath', null], ['liveOwnershipPath', null]]) {
      const value = options[field] || (suffix ? path.join(base, suffix) : null);
      if (!value) continue;
      const resolved = path.resolve(value), key = resolved.toLowerCase();
      if (paths.has(key)) throw new Error('Watchdog paths must be distinct: ' + field);
      paths.add(key);
      if (existsSync(resolved)) throw new Error(field + ' already exists: ' + resolved);
      mkdirSync(path.dirname(resolved), { recursive: true });
      s[field] = resolved;
    }
    summarySafe = true;
    assertStop();
    const native = await buildOwnedNativeHost();
    assertStop();
    host = openOwnedNativeHost(native, process.env);
    identity = await rpc('init'); initialized = true;
    await publish('starting');
    assertStop();
    s.launchTimeUtc = now();
    // A lost RPC response must not erase the possibility that Windows created
    // a suspended process. Only a native negative acknowledgement can clear it.
    s.launchedProcessRequiresZeroProof = true;
    Object.assign(s, await rpc('create', { executable: s.executable, args: [s.executable, ...s.args],
      projectPath: s.projectPath, stdoutPath: s.stdoutPath, stderrPath: s.stderrPath,
      environment: environmentBlock(options.env ?? process.env) }));
    s.processCreatedSuspended = s.assignedAtomicallyByProcThreadAttributeJobList = s.nativeCreateReachedProcess = true;
    s.launchedProcessRequiresZeroProof = true;
    const initial = await membership('assigned_before_resume');
    if (initial.length !== 1 || initial[0] !== s.rootPid) throw new Error('Job must contain exactly the suspended root before resume');
    assertStop();
    await rpc('resume'); s.primaryThreadResumed = true;
    const start = performance.now();
    try {
      while (true) {
        assertStop();
        const left = s.timeoutSeconds === 0 ? Infinity : s.timeoutSeconds * 1000 - (performance.now() - start);
        if (left <= 0) { s.timedOut = true; break; }
        const polled = await rpc('poll', { milliseconds: Math.max(1, Math.floor(Math.min(250, left))) });
        if (polled.exited) { s.rootExited = true; s.functionalExitCode = polled.exitCode; break; }
        await publish('running');
      }
      assertStop();
      if (s.rootExited) {
        const grace = performance.now() + s.cleanupGraceMilliseconds;
        while (true) {
          const ids = await membership('root_exit_cleanup_grace');
          if (ids.length === 0 || performance.now() >= grace) break;
          assertStop();
          await delay(Math.min(50, Math.max(1, grace - performance.now())));
        }
      }
      assertStop();
    } catch (e) { s.monitoringException = e.message; throw e; }
  } catch (e) {
    s.fatalException = e.message;
    if (e.nativeCreateReachedProcess === false && !s.processCreatedSuspended)
      s.launchedProcessRequiresZeroProof = false;
    if (e.nativeCreateReachedProcess) s.nativeCreateReachedProcess = s.launchedProcessRequiresZeroProof = true;
  } finally {
    terminalStart = performance.now();
    terminalDeadline = terminalStart + (s.finalCleanupTimeoutMilliseconds ?? 30000);
    if (host) {
      try {
        if (liveCreated) {
          try { await publish('stopping'); }
          catch (e) { s.monitoringException = e.message; s.cleanupErrors.push(e.message); }
        }
        if (initialized) {
          const before = await membership('finally_before_cleanup', true);
          if (s.timedOut || s.monitoringException || before === null || before.length) await terminate();
          const final = await membership('final_before_job_close', true);
          if (final !== null) { s.finalMembershipKnown = true; s.finalJobMemberPids = final; }
          if (s.completionZeroMessageObserved) prove('bounded_completion_port_active_process_zero');
          else if (final?.length === 0) prove('job_membership_zero');
          if (!s.authoritativeZeroProven && !s.terminateJobObjectAttempted) await terminate();
          if (!s.authoritativeZeroProven && s.terminateJobObjectSucceeded && remaining()) {
            s.fallbackCaptureAttempted = true;
            try {
              s.fallbackCapturedPids = await rpc('capture'); s.fallbackCaptureSucceeded = true;
              await closeJob(); s.fallbackJobClosed = true;
              let allExited = true;
              for (const [index, pid] of s.fallbackCapturedPids.entries()) {
                const record = { pid, waitedByRetainedHandle: false, signaled: false, exitCode: null,
                  stillActiveRejected: false, handleClosed: false, error: null };
                try {
                  if (!remaining()) throw new Error('Terminal cleanup deadline expired');
                  record.waitedByRetainedHandle = true;
                  record.exitCode = await rpc('waitCaptured', { index, milliseconds: remaining() });
                  record.signaled = record.handleClosed = true;
                } catch (e) {
                  record.error = e.message; record.stillActiveRejected = e.message.includes('STILL_ACTIVE');
                  s.fallbackRetainedWaitFailed = true; allExited = false; s.cleanupErrors.push(e.message);
                }
                s.fallbackPostCloseWaits.push(record);
              }
              if (allExited) { s.fallbackZeroProven = true; prove('stable_retained_member_handles_signaled_after_job_close'); }
            } catch (e) { s.fallbackCaptureError = e.message; s.cleanupErrors.push(e.message); }
          }
          if (!s.authoritativeZeroProven && s.launchedProcessRequiresZeroProof) {
            await closeJob();
            if (remaining()) {
              s.postCloseCompletionZeroProven = await rpc('zero', { milliseconds: remaining() });
              if (s.postCloseCompletionZeroProven) prove('bounded_post_close_completion_port_active_process_zero');
            }
          }
          await closeJob();
        }
        await rpc('close');
      } catch (e) { s.cleanupErrors.push(e.message); host.abort(); }
      finally { await host.finish(Math.min(1000, remaining() || 1)); }
    }
    s.cleanupUnresolved = s.launchedProcessRequiresZeroProof && !s.authoritativeZeroProven;
    s.terminalCleanupElapsedMilliseconds = Math.round(performance.now() - terminalStart);
    s.cleanupPassed = s.processCreatedSuspended && s.assignedAtomicallyByProcThreadAttributeJobList &&
      s.primaryThreadResumed && s.rootExited && !s.forcedCleanup && s.authoritativeZeroProven &&
      !s.cleanupUnresolved && s.finalMembershipKnown && s.finalJobMemberPids.length === 0 && s.cleanupErrors.length === 0;
    if ((s.membershipQueryFailed && !s.membershipUncertaintyResolvedByZeroProof) ||
      s.cleanupUnresolved || s.monitoringException || s.cleanupErrors.length) s.overallExitCode = 126;
    else if (s.forcedCleanup) s.overallExitCode = 125;
    else if (s.timedOut) s.overallExitCode = 124;
    else if (!s.primaryThreadResumed || !s.rootExited || s.functionalExitCode === null) s.overallExitCode = 127;
    else s.overallExitCode = s.functionalExitCode > 0x7fffffff ? 1 : s.functionalExitCode;
    s.completedTimeUtc = now();
    process.off('SIGINT', onInt); process.off('SIGTERM', onTerm);
    options.signal?.removeEventListener('abort', onAbort);
    if (summarySafe) {
      try { atomicJson(s.summaryPath, s); }
      catch (e) {
        // Keep this independent of the primary payload: serialization itself
        // may have failed. The returned/CLI object is exactly the retry payload.
        emergencyResult = {
          schema: 'godot-scene-watchdog/emergency-v1', runId,
          overallExitCode: 126, functionalExitCode: s.functionalExitCode,
          cleanupPassed: false, authoritativeZeroProven: s.authoritativeZeroProven,
          cleanupUnresolved: s.cleanupUnresolved, timedOut: s.timedOut,
          forcedCleanup: s.forcedCleanup, rootPid: s.rootPid,
          stdoutPath: s.stdoutPath, stderrPath: s.stderrPath, summaryPath: s.summaryPath,
          reason: 'primary_summary_failed',
          cleanupErrors: ['Summary publication failed: ' + e.message],
        };
        try { atomicJson(s.summaryPath, emergencyResult); }
        catch (retryError) {
          // Persistent I/O failure cannot promise a durable report. Surface it
          // explicitly on the API/CLI channel; never replace a foreign result.
          emergencyResult.summaryPersistenceFailed = true;
          emergencyResult.cleanupErrors.push('Emergency summary publication failed: ' + retryError.message);
        }
      }
    }
  }
  return emergencyResult ?? s;
}

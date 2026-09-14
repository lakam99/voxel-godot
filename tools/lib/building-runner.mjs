import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';

export const projectDefault = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const godotDefault = 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe';
export const watchdogSources = ['tools/run-godot-scene-watchdog.mjs', 'tools/lib/owned-process.mjs', 'tools/lib/owned-native-host.mjs', 'tools/lib/owned-live-clock.mjs', 'tools/native/OwnedProcessHost.cs', 'tools/native/OwnedProcessNative.cs'];
export const slash = p => p.replaceAll('\\', '/');
export const shaBytes = b => createHash('sha256').update(b).digest('hex');
export const sha = p => shaBytes(fs.readFileSync(p));
export const read = p => JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, ''));
export const write = (p, v) => fs.writeFileSync(p, JSON.stringify(v, null, 2) + '\n');
export const demand = (ok, message) => { if (!ok) throw new Error(message); };
export const git = (project, ...args) => execFileSync('git', ['-C', project, ...args], { maxBuffer: 64 * 1024 * 1024, windowsHide: true });
export const uid = () => randomUUID().replaceAll('-', '');
export function options(argv, defaults = {}, switches = []) {
  const out = { ...defaults };
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i].replace(/^--?/, '').replaceAll('-', '').toLowerCase();
    demand(argv[i].startsWith('-') && (key in defaults || switches.includes(key)), `Unknown option: ${argv[i]}`);
    if (switches.includes(key)) out[key] = true;
    else { demand(i + 1 < argv.length && !/^--?[A-Za-z]/.test(argv[i + 1]), `Missing value: ${argv[i]}`); out[key] = argv[++i]; }
  }
  return out;
}
export function choice(value, values, label) { const match = values.find(v => v.toLowerCase() === String(value).toLowerCase()); demand(match !== undefined, `${label} must be one of ${values.join(', ')}`); return match; }
export function assertNoGodot(processList, { platform = process.platform, run } = {}) {
  // Preserve the original exclusive-engine pre/post gate without controlling
  // unrelated processes. Only the owned watchdog may terminate its own job.
  let names;
  if (processList == null && platform === 'win32') {
    // Get-Process provides structured names without invoking tasklist. Any
    // error, timeout, diagnostic output or incomplete inventory rejects.
    const script = [
      '$ErrorActionPreference = "Stop"',
      '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)',
      '$items = @(Get-Process -ErrorAction Stop | ForEach-Object { [PSCustomObject]@{ name = $_.ProcessName; pid = $_.Id } })',
      'if ($items.Count -eq 0) { throw "Empty process inventory" }',
      '[PSCustomObject]@{ schema = "process-name-inventory/v1"; complete = $true; count = $items.Count; processes = $items } | ConvertTo-Json -Depth 4 -Compress'
    ].join('; ');
    const result = (run ?? spawnSync)('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
      { encoding: 'utf8', windowsHide: true, timeout: 10000, maxBuffer: 1024 * 1024 });
    demand(result && !result.error && result.status === 0 && result.signal == null &&
      typeof result.stdout === 'string' && typeof result.stderr === 'string' && result.stderr.length === 0,
    'Windows process inventory failed or produced diagnostics');
    const inventory = JSON.parse(result.stdout.replace(/^\uFEFF/, ''));
    demand(inventory?.schema === 'process-name-inventory/v1' && inventory.complete === true &&
      Array.isArray(inventory.processes) && inventory.processes.length > 0 &&
      Number.isInteger(inventory.count) && inventory.count === inventory.processes.length &&
      inventory.processes.every(item => item && typeof item.name === 'string' && item.name.trim().length > 0 &&
        Number.isInteger(item.pid) && item.pid >= 0) &&
      new Set(inventory.processes.map(item => item.pid)).size === inventory.count,
    'Invalid or incomplete Windows process inventory');
    names = inventory.processes.map(item => item.name);
  } else {
    // Keep the existing injected CSV/plain-name contract and Unix behavior.
    const listing = processList ?? (run ?? execFileSync)('ps', ['-A', '-o', 'comm='], { encoding: 'utf8' });
    names = listing.split(/\r?\n/).map(line => line.startsWith('"') ? line.slice(1, line.indexOf('"', 1)) : line.trim());
  }
  demand(!names.some(name => /godot/i.test(name)), 'Another Godot instance is running or remains after the run');
}
export function integer(value, min, max, label) { const n = Number(value); demand(Number.isInteger(n) && n >= min && n <= max, `Invalid ${label}`); return n; }
export function inside(root, target) {
  const relative = path.relative(root, target);
  return relative !== '' && !relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative);
}
export function ownedPath(project, output, prefix = '') {
  const p = path.resolve(project, output);
  demand(path.dirname(p) === path.join(project, 'artifacts/citadel-runtime-integration') && path.basename(p).startsWith(prefix), `Use a ${prefix}* directory directly in artifacts/citadel-runtime-integration`);
  return p;
}
export function fresh(p) {
  demand(!fs.existsSync(p), `Fresh output required: ${p}`);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.mkdirSync(p); // Exclusive final directory creation: concurrent runners cannot overwrite evidence.
}
export function hashes(project, files) { return Object.fromEntries([...new Set(files)].map(f => [f, sha(path.resolve(project, f.replace(/^res:\/\//, '')))])); }
export function stable(project, before) { for (const [f, hash] of Object.entries(before)) demand(sha(path.resolve(project, f.replace(/^res:\/\//, ''))) === hash, `Source changed during execution: ${f}`); }
export function assertWatchdog(w, membership = false) {
  demand(w !== null && typeof w === 'object' && !Array.isArray(w), 'Missing watchdog evidence');
  const expected = { overallExitCode: 0, functionalExitCode: 0, cleanupPassed: true, authoritativeZeroProven: true, timedOut: false, forcedCleanup: false, cleanupUnresolved: false };
  for (const [key, value] of Object.entries(expected)) demand(Object.hasOwn(w, key) && w[key] === value, 'Missing, mistyped or failing watchdog field: ' + key);
  if (membership) demand(Object.hasOwn(w, 'finalMembershipKnown') && w.finalMembershipKnown === true && Object.hasOwn(w, 'finalJobMemberPids') && Array.isArray(w.finalJobMemberPids) && w.finalJobMemberPids.length === 0, 'Final owned membership is not proven empty');
}
export function resolveExecutable(executable, base = process.cwd()) {
  const resolved = fs.realpathSync(path.resolve(base, executable));
  demand(fs.statSync(resolved).isFile(), 'Executable is not a file: ' + resolved);
  return resolved;
}
export function resolveExecutablePair(executable, base = process.cwd()) {
  const launcher = resolveExecutable(executable, base);
  return { executable: launcher, runtime: resolveExecutable(launcher.replace(/_console\.exe$/i, '.exe')) };
}
export function assertReport(report, expected = {}) {
  for (const [key, value] of Object.entries(expected)) demand(JSON.stringify(report?.[key]) === JSON.stringify(value), `Report ${key} mismatch: expected ${JSON.stringify(value)}`);
}
export const engineErrors = /SCRIPT ERROR:|Parse Error:|ERROR:/i;
export const engineWarnings = /SCRIPT ERROR|Parse Error|Compile Error|ERROR:|WARNING:|leaked|resources still in use/i;
export function checkLogs(stdout, stderr, { pattern = engineWarnings, emptyStderr = false, expectedError = '', expectedCount = 0 } = {}) {
  demand(!emptyStderr || stderr.length === 0, 'Godot stderr is not empty');
  const lines = (stdout + '\n' + stderr).split(/\r?\n/).filter(line => pattern.test(line));
  demand(lines.length === expectedCount && lines.every(line => line === expectedError), `Unexpected engine diagnostics: ${lines.join('\n')}`);
  return lines;
}
export async function phaseRun(c, { args, env = {}, timeout = 45, prefix = '', membership = false, logPolicy = {}, live = false, logExtension = 'log', summaryName } = {}, runOwnedProcess) {
  const at = name => path.join(c.run, prefix + name);
  const stdoutPath = at('stdout.' + logExtension), stderrPath = at('stderr.' + logExtension), stopRequestPath = at('stop-request.txt');
  let watcherError, stopped = false;
  const inspect = () => {
    if (stopped) return;
    try {
      for (const p of [stdoutPath, stderrPath]) {
        if (!fs.existsSync(p)) continue;
        for (const line of fs.readFileSync(p, 'utf8').split(/\r?\n/)) {
          if (engineErrors.test(line) && line !== logPolicy.expectedError) {
            fs.writeFileSync(stopRequestPath, line); stopped = true; return;
          }
        }
      }
    } catch (e) {
      watcherError = e; stopped = true;
      try { fs.writeFileSync(stopRequestPath + '.watcher-error.txt', String(e)); fs.writeFileSync(stopRequestPath, String(e)); } catch { /* The terminal failure remains authoritative. */ }
    }
  };
  if (!runOwnedProcess) ({ runOwnedProcess } = await import('../run-godot-scene-watchdog.mjs'));
  const timer = setInterval(inspect, 100);
  let result;
  try {
    result = await runOwnedProcess({ projectPath: c.project, executable: c.executable, args: ['--path', c.project, ...args], env: { ...c.env, ...env }, timeoutSeconds: timeout, stdoutPath, stderrPath, summaryPath: at(summaryName ?? 'watchdog.json'), stopRequestPath, liveOwnershipPath: live ? at('live-ownership.json') : undefined });
  } finally { clearInterval(timer); inspect(); }
  demand(!watcherError, `Error watcher failed: ${watcherError}`);
  assertWatchdog(result, membership);
  checkLogs(fs.readFileSync(stdoutPath, 'utf8'), fs.readFileSync(stderrPath, 'utf8'), logPolicy);
  demand(!fs.existsSync(stopRequestPath), `Run received a stop request: ${stopRequestPath}`);
  return result;
}
export function context(o, prefix = null, within = false) {
  const project = fs.realpathSync(path.resolve(o.projectpath || projectDefault));
  demand(o.outputdirectory, 'OutputDirectory is required');
  const run = prefix === null ? path.resolve(project, o.outputdirectory) : ownedPath(project, o.outputdirectory, prefix);
  if (within) demand(inside(project, run), 'Output must stay inside the invoking project');
  demand(!fs.existsSync(run), `Fresh output required: ${run}`);
  return { project, run, executable: resolveExecutable(o.godotexe || godotDefault), env: { ...process.env } };
}
export function prepare(c, isolate = 'userdata', save = false) {
  fresh(c.run);
  if (isolate) {
    c.env.APPDATA = path.join(c.run, isolate === 'split' ? 'appdata' : isolate);
    c.env.LOCALAPPDATA = path.join(c.run, isolate === 'split' ? 'localappdata' : isolate);
    for (const p of new Set([c.env.APPDATA, c.env.LOCALAPPDATA])) fs.mkdirSync(p);
  }
  if (save) c.env.VOXEL_SAVE_PATH_OVERRIDE = path.join(c.run, 'test-save.json');
}
export function launchRecord(c, files, metadata = {}) {
  const sourceSha256 = hashes(c.project, [...files, ...watchdogSources]);
  write(path.join(c.run, 'launch.json'), { ...metadata, head: git(c.project, 'rev-parse', 'HEAD').toString().trim(), branch: git(c.project, 'branch', '--show-current').toString().trim(), recordedUtc: new Date().toISOString(), projectPath: c.project, sourceSha256 });
  return sourceSha256;
}
export function cli(main) {
  if (process.argv.slice(2).some(arg => /^(--?help|-h)$/i.test(arg))) {
    import('./building-help.mjs').then(({ runnerHelp }) => console.log(runnerHelp(path.basename(process.argv[1], '.mjs').replace(/^run-/, '')))).catch(error => { console.error(error); process.exitCode = 1; });
    return;
  }
  main().then(result => { if (result) console.log(JSON.stringify(result, null, 2)); }).catch(error => { console.error(error.stack || error); process.exitCode = 1; });
}

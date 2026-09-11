import { readFile, writeFile, mkdir, lstat, stat, open } from 'node:fs/promises';
import { dirname, basename, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';

export const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const godotExe = 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe';
export const expectedError = 'ERROR: Citadel structural completion failed: facade_completion_failed';
export const helperSource = 'tools/lib/citadel-candidate-runner.mjs';
export const watchdogSource = 'tools/run-godot-scene-watchdog.mjs';
export const watchdogDependencies = ['tools/lib/owned-process.mjs', 'tools/lib/owned-native-host.mjs', 'tools/native/OwnedProcessNative.cs', 'tools/native/OwnedProcessHost.cs'];
export const errorPattern = /SCRIPT ERROR:|Parse Error:|ERROR:|WARNING:|leaked|resources still in use/i;

export function parseOptions(argv, kind) {
  const names = ['OutputDirectory', ...(kind === 'watcher' ? [] : ['Seed', 'CandidateRegion']),
    ...(kind === 'recipe' ? ['CaptureBlueprint', 'ExpectReady', 'CaptureFailure', 'ExpectedRecipeSeed'] : []),
    ...(kind === 'teleport' ? ['TimeoutSeconds', 'StartupTimeoutSeconds', 'SkipTutorial', 'ForceDaytime', 'ForceClearWeather', 'ManualInspection', 'Resolution', 'SpawnCell', 'CaptureNavigationRejections'] : [])];
  const switches = new Set(['captureBlueprint', 'expectReady', 'captureFailure', 'skipTutorial', 'forceDaytime', 'forceClearWeather', 'manualInspection', 'captureNavigationRejections']);
  const options = {};
  for (let i = 0; i < argv.length; i++) {
    const match = /^--?([^=:]+)(?:[=:](.*))?$/.exec(argv[i]);
    const name = match && names.find(n => n.toLowerCase() === match[1].replaceAll('-', '').toLowerCase());
    if (!name) throw new Error(`Unknown option: ${argv[i]}`);
    const key = name[0].toLowerCase() + name.slice(1);
    if (Object.hasOwn(options, key)) throw new Error(`Duplicate option: ${name}`);
    if (switches.has(key)) {
      if (match[2] !== undefined && !/^(true|false|1|0|\$true|\$false)$/i.test(match[2])) throw new Error(`Invalid switch: ${name}`);
      options[key] = match[2] === undefined || /^(true|1|\$true)$/i.test(match[2]);
    } else {
      const value = match[2] ?? argv[++i];
      if (value === undefined || /^--?[a-z]/i.test(value)) throw new Error(`Missing value: ${name}`);
      options[key] = value;
    }
  }
  if (!options.outputDirectory?.trim()) throw new Error('OutputDirectory is required.');
  return options;
}

export function regionCoordinates(region) {
  if (!/^-?(0|[1-9][0-9]{0,6}),-?(0|[1-9][0-9]{0,6})$/.test(region)) throw new Error('CandidateRegion must be canonical x,z integers.');
  return region.split(',').map(coordinate => {
    const value = Number(coordinate);
    if (String(value) !== coordinate || value < -1048576 || value > 1048575) throw new Error('CandidateRegion is outside the supported field.');
    return value;
  });
}

export function integer(value, min, max, name) {
  if (!/^[+-]?\d+$/.test(String(value)) || !Number.isSafeInteger(Number(value)) || Number(value) < min || Number(value) > max) throw new Error(`Invalid ${name}: expected integer ${min}..${max}.`);
  return Number(value);
}
export function validateSeed(seed) {
  if (typeof seed !== 'string' || !seed.trim() || seed.length > 128) throw new Error('A nonempty seed of at most 128 characters is required.');
}
export function recipeOptions(input) {
  const o = { seed: 'atlas-30895044', candidateRegion: '0,-1', expectedRecipeSeed: 1747969299, captureBlueprint: false, expectReady: false, captureFailure: false, ...input };
  if (o.captureBlueprint && o.expectReady) throw new Error('ExpectReady requires public Recipe entry; cannot combine with CaptureBlueprint.');
  if (o.captureFailure && (o.expectReady || o.captureBlueprint)) throw new Error('CaptureFailure requires only public failure replay.');
  validateSeed(o.seed);
  o.region = regionCoordinates(o.candidateRegion);
  o.expectedRecipeSeed = integer(o.expectedRecipeSeed, 0, 2147483647, 'ExpectedRecipeSeed');
  o.expectedError = o.expectReady || o.captureBlueprint ? '' : expectedError;
  o.runSeconds = o.expectReady || o.captureFailure || o.captureBlueprint ? 540 : 180;
  o.sourceSeconds = o.runSeconds === 540 ? 450 : 150;
  o.proofSeconds = o.expectReady ? 60 : 0;
  return o;
}
export function teleportOptions(input, env) {
  const o = { seed: 'atlas-30895044', candidateRegion: '', timeoutSeconds: 600, startupTimeoutSeconds: 120, skipTutorial: false, forceDaytime: false, forceClearWeather: false, manualInspection: false, captureNavigationRejections: false, resolution: '1280x720', ...input };
  if (!['1280x720', '1920x1080'].includes(o.resolution)) throw new Error('Resolution must be 1280x720 or 1920x1080.');
  validateSeed(o.seed);
  if (o.candidateRegion !== '') regionCoordinates(o.candidateRegion);
  o.spawnCell ??= '';
  if (o.spawnCell !== '') {
    regionCoordinates(o.spawnCell);
    if (!o.skipTutorial || !o.candidateRegion) throw new Error('SpawnCell requires SkipTutorial and an explicit CandidateRegion; tutorial scenario placement must not override the initial location.');
  }
  o.timeoutSeconds = integer(o.timeoutSeconds, 90, 600, 'TimeoutSeconds');
  o.startupTimeoutSeconds = integer(o.startupTimeoutSeconds, 15, 180, 'StartupTimeoutSeconds');
  for (const key of ['skipTutorial', 'forceDaytime', 'forceClearWeather', 'manualInspection', 'captureNavigationRejections']) if (typeof o[key] !== 'boolean') throw new Error('Invalid boolean: ' + key);
  o.launchOptions = { skipTutorial: o.skipTutorial, forceDaytime: o.forceDaytime, forceClearWeather: o.forceClearWeather };
  o.gameArguments = Object.entries(o.launchOptions).filter(([, enabled]) => enabled).map(([key]) => '-' + key[0].toUpperCase() + key.slice(1));
  o.manualInspectionSeconds = o.manualInspection ? 1800 : 0;
  o.overallTimeoutSeconds = o.startupTimeoutSeconds + o.timeoutSeconds + o.manualInspectionSeconds;
  const inherited = Object.keys(env).filter(key => /^VOXEL_/i.test(key) && env[key]);
  if (inherited.length) throw new Error(`Unset inherited VOXEL_* modes before this diagnostic: ${inherited.join(', ')}`);
  return o;
}
export async function exists(path) {
  try { await lstat(path); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
export async function freshDirectory(project, output, prefix = '') {
  if (typeof output !== 'string' || !output.trim()) throw new Error('OutputDirectory is required.');
  const run = resolve(project, output.replaceAll('\\', '/'));
  const root = join(project, 'artifacts/citadel-runtime-integration');
  const normalize = s => process.platform === 'win32' ? s.toLowerCase() : s;
  if (normalize(dirname(run)) !== normalize(root) || !basename(run).toLowerCase().startsWith(prefix)) throw new Error(`Use a fresh ${prefix} directory directly under artifacts/citadel-runtime-integration.`);
  if (await exists(run)) throw new Error('Fresh output required; prior evidence is never overwritten.');
  await mkdir(root, { recursive: true });
  await mkdir(run); // Exclusive leaf creation also rejects a concurrent run.
  return run;
}
export const writeJson = (path, value) => writeFile(path, JSON.stringify(value, null, 2) + '\n', 'utf8');
export const readJson = async path => JSON.parse((await readFile(path, 'utf8')).replace(/^\uFEFF/, ''));
export const sha256 = async path => createHash('sha256').update(await readFile(path)).digest('hex');
export function git(project, args) { return execFileSync('git', ['-C', project, ...args], { encoding: 'utf8', windowsHide: true, maxBuffer: 32 * 1024 * 1024 }); }
export async function sourceHashes(project, kind, runner) {
  const patterns = kind === 'recipe' ? ['--cached', '--others', '--exclude-standard', '--', 'scripts/*.gd', 'scripts/**/*.gd'] : ['--cached', '--others', '--exclude-standard', '--', '*.gd', '*.tscn', 'project.godot'];
  const files = git(project, ['ls-files', '-z', ...patterns]).split('\0').filter(Boolean);
  files.push(`scripts/testing/buildings/CitadelCandidate${kind === 'recipe' ? 'RecipeDiagnostic' : 'TeleportPlaytest'}.gd`, runner, watchdogSource, ...watchdogDependencies, helperSource);
  if (kind === 'teleport') files.push('addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll', 'scripts/perf/RuntimeRenderObservation.gd');
  const hashes = {};
  for (const file of [...new Set(files)].sort()) hashes[file] = await sha256(join(project, file));
  return hashes;
}
export async function auditSources(project, hashes) {
  const finalSourceHashes = {}, changedSources = [], readErrors = [];
  for (const [path, expected] of Object.entries(hashes)) {
    try {
      const actual = await sha256(join(project, path));
      finalSourceHashes[path] = actual;
      if (actual !== expected) changedSources.push({ path, expected, actual });
    } catch (error) { readErrors.push({ path, error: error.message }); }
  }
  return { sourceCount: Object.keys(hashes).length, unchanged: !changedSources.length && !readErrors.length, changedSources, readErrors, finalSourceHashes };
}

// The recipe watcher deliberately rescans both complete logs: occurrences are
// counted across files, never accumulated across polling intervals.
export function recipeStopReason(texts, allowedLine = '') {
  let count = 0;
  for (const text of texts) for (const line of text.replace(/^\uFEFF/, '').split(/\r\n|\n|\r/)) {
    if (!/SCRIPT ERROR:|Parse Error:|ERROR:|WARNING:/i.test(line)) continue;
    if (allowedLine && line.trim() === allowedLine) {
      if (++count > 1) return 'Repeated inventoried engine error: ' + line;
    } else return line;
  }
  return '';
}
export function startCandidateWatcher({ stdoutPath, stderrPath, stopRequestPath, allowedLine = '', kind = 'recipe', intervalMs = 100 }) {
  const paths = [stdoutPath, stderrPath];
  const offsets = new Map(paths.map(path => [path, 0]));
  const tails = new Map(paths.map(path => [path, '']));
  let timer, stopped = false, failure = null, reason = '';
  let pending = Promise.resolve();
  async function scan() {
    if (reason || failure) return;
    try {
      const texts = [];
      for (const path of paths) {
        if (!(await exists(path))) { texts.push(''); continue; }
        if (kind === 'recipe') texts.push(await readFile(path, 'utf8'));
        else {
          const handle = await open(path, 'r');
          try {
            const size = (await handle.stat()).size, offset = offsets.get(path);
            if (size < offset) throw new Error('Engine log shrank during execution.');
            const buffer = Buffer.alloc(size - offset);
            const { bytesRead } = await handle.read(buffer, 0, buffer.length, offset);
            const text = tails.get(path) + buffer.subarray(0, bytesRead).toString('utf8');
            offsets.set(path, offset + bytesRead);
            tails.set(path, text.slice(-64));
            const match = /SCRIPT ERROR:|Parse Error:|ERROR:/i.exec(text);
            if (match) { reason = `Immediate owned stop: ${match[0]} in ${path}`; break; }
          } finally { await handle.close(); }
        }
      }
      if (kind === 'recipe') reason = recipeStopReason(texts, allowedLine);
      if (reason) await writeFile(stopRequestPath, reason);
    } catch (error) {
      failure = error;
      // Both writes are attempted even when the evidence directory fails.
      await Promise.allSettled([writeFile(stopRequestPath + '.watcher-error.txt', error.stack ?? String(error)),
        writeFile(stopRequestPath, kind === 'recipe' ? 'watcher failure' : 'Error watcher failed; stop owned run.')]);
    }
  }
  function queue() { pending = pending.then(scan); return pending; }
  function tick() { queue().finally(() => { if (!stopped && !reason && !failure) timer = setTimeout(tick, intervalMs); }); }
  tick();
  return {
    poll: queue,
    get reason() { return reason; },
    get failed() { return Boolean(failure); },
    async stop() { stopped = true; clearTimeout(timer); await queue(); },
  };
}
export async function engineErrors(paths) {
  const lines = [];
  for (const path of paths) for (const line of (await readFile(path, 'utf8')).replace(/^\uFEFF/, '').split(/\r\n|\n|\r/)) if (errorPattern.test(line)) lines.push(line.trim());
  return lines;
}
export function validateRecipeErrors(lines, allowed, requireOne) {
  if (lines.some(line => line !== allowed)) throw new Error('Unexpected engine error/warning.');
  if (requireOne && lines.length !== 1) throw new Error('Expected exactly one inventoried Composer error.');
}
export function ownedPassed(summary) { return summary?.overallExitCode === 0 && summary.cleanupPassed === true && summary.authoritativeZeroProven === true; }
export async function runCandidatePhase({ project, run, args, env, timeoutSeconds, prefix = '', kind, allowedLine = '', runOwnedProcess }) {
  const paths = { stdoutPath: join(run, prefix + 'stdout.log'), stderrPath: join(run, prefix + 'stderr.log'), summaryPath: join(run, prefix + 'watchdog.json'), stopRequestPath: join(run, prefix + 'stop-request.txt') };
  const watcher = startCandidateWatcher({ ...paths, allowedLine, kind });
  let summary;
  try {
    summary = await runOwnedProcess({ projectPath: project, executable: godotExe, args, env, timeoutSeconds, ...paths,
      ...(kind === 'recipe' ? { finalCleanupTimeoutMilliseconds: 15000 } : { liveOwnershipPath: join(run, 'live-ownership.json') }) });
  } finally { await watcher.stop(); }
  return { summary, ...paths, watcherFailed: watcher.failed || await exists(paths.stopRequestPath + '.watcher-error.txt'), stopRequested: Boolean(watcher.reason) };
}
export const isFile = async path => { try { return (await stat(path)).isFile(); } catch (error) { if (error.code === 'ENOENT') return false; throw error; } };
export async function cli(moduleUrl, main) {
  if (!process.argv[1] || resolve(process.argv[1]) !== fileURLToPath(moduleUrl)) return;
  try {
    if (process.argv.slice(2).some(arg => /^(--help|-help)$/i.test(arg))) {
      console.log(`Usage: node tools/${basename(fileURLToPath(moduleUrl))} -OutputDirectory <fresh integration artifact directory>`);
      return;
    }
    console.log(JSON.stringify(await main(process.argv.slice(2))));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}

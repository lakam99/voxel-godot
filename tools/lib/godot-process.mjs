import { mkdir, mkdtemp, readFile, writeFile, stat, open } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = fileURLToPath(new URL('../../', import.meta.url));

// Every game launch retains its own logs and Windows Job Object receipt.
// A gameplay report cannot override an engine failure or unresolved cleanup.
export async function runGodotProcess(executable, args, options = {}) {
  const { runOwnedProcess } = await import('../run-godot-scene-watchdog.mjs');
  const artifactRoot = join(projectRoot, 'artifacts', 'node-tools', 'process-runs');
  await mkdir(artifactRoot, { recursive: true });
  const output = await mkdtemp(join(artifactRoot, 'godot-'));
  const stdoutPath = join(output, 'stdout.log');
  const stderrPath = join(output, 'stderr.log');
  const summaryPath = join(output, 'watchdog.json');
  const stopRequestPath = join(output, 'stop-request.txt');
  const cancellation = new AbortController();
  let pendingScan;
  let watcherError;
  const offsets = new Map();
  const tails = new Map();
  const started = Date.now();
  let finished = false;
  const scan = async () => {
    if (pendingScan) return pendingScan;
    pendingScan = (async () => {
    try {
      for (const path of [stdoutPath, stderrPath]) {
        const file = await open(path, 'r').catch(error => { if (error.code === 'ENOENT') return null; throw error; });
        if (!file) continue;
        try {
          const size = (await file.stat()).size;
          let offset = offsets.get(path) ?? 0;
          if (size < offset) throw new Error('Engine log shrank during execution.');
          while (offset < size) {
            const buffer = Buffer.alloc(Math.min(65536,size-offset));
            const { bytesRead } = await file.read(buffer,0,buffer.length,offset);
            if (!bytesRead) break;
            offset += bytesRead;
            const text = (tails.get(path) ?? '') + buffer.subarray(0,bytesRead).toString('utf8');
            const error = text.match(/SCRIPT ERROR:|Parse Error:|ERROR:/);
            if (error) await writeFile(stopRequestPath, `Engine failure: ${error[0]} in ${path}`);
            tails.set(path,text.slice(-64));
          }
          offsets.set(path,offset);
        } finally { await file.close(); }
      }
      if (options.reportPath && !finished) {
        const text = await readFile(options.reportPath,'utf8').catch(error=>{if(error.code==='ENOENT')return '';throw error;});
        try {
          const report = JSON.parse(text.replace(/^\uFEFF/,''));
          finished = report.finished === true && (!options.expectedRunToken || report.runToken === options.expectedRunToken);
        } catch { /* Report may be mid-write. */ }
      }
      if (!finished && options.workTimeoutSeconds && Date.now()-started > options.workTimeoutSeconds*1000) {
        await writeFile(stopRequestPath,'Gameplay work deadline exceeded.');
      }
      if (!finished && options.progressPath && options.staleProgressSeconds) {
        const info = await stat(options.progressPath).catch(error=>{if(error.code==='ENOENT')return null;throw error;});
        if (info && Date.now()-info.mtimeMs > options.staleProgressSeconds*1000) await writeFile(stopRequestPath,'Gameplay progress is stale.');
      }
    } catch (error) {
      watcherError = error;
      cancellation.abort();
      await writeFile(stopRequestPath, `Log watcher failed: ${error.message}`).catch(() => {});
    }
    })();
    try { await pendingScan; } finally { pendingScan = null; }
  };
  const timer = setInterval(() => { void scan(); }, 100);
  let summary;
  try {
    summary = await runOwnedProcess({ projectPath: resolve(options.cwd ?? projectRoot), executable,
      args, env: options.env ?? process.env, timeoutSeconds: options.timeoutSeconds ?? 0,
      stdoutPath, stderrPath, summaryPath, stopRequestPath, signal: cancellation.signal });
  } finally { clearInterval(timer); if (pendingScan) await pendingScan; }
  await scan();
  const logReadErrors = [];
  const logs = await Promise.all([stdoutPath, stderrPath].map(path => readFile(path, 'utf8').catch(error=>{
    logReadErrors.push({path,error:error.message}); return '';
  })));
  if (options.stdio !== 'ignore') {
    process.stdout.write(logs[0]);
    process.stderr.write(logs[1]);
    process.stdout.write(`Owned-process evidence: ${summaryPath}\n`);
    if(summary.fatalException || summary.monitoringException) process.stderr.write(`Launch/monitor failure: ${summary.fatalException ?? summary.monitoringException}\n`);
  }
  const engineError = logs.some(log => /SCRIPT ERROR:|Parse Error:|ERROR:|WARNING:|leaked|resources still in use/.test(log));
  const passed = !logReadErrors.length && !watcherError && !engineError && summary.overallExitCode === 0
    && summary.cleanupPassed && summary.authoritativeZeroProven;
  return { code: passed ? 0 : (summary.overallExitCode || 1), signal: null, summary, summaryPath, logReadErrors };
}

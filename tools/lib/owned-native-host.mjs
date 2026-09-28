import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rename, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

const sources = ['OwnedProcessNative.cs', 'OwnedProcessHost.cs'].map(name =>
  fileURLToPath(new URL('../native/' + name, import.meta.url)));
let build;
export function buildOwnedNativeHost() {
  return build ??= compile().catch(error => { build = undefined; throw error; });
}
async function compile() {
  if (process.platform !== 'win32') throw new Error('Owned process watchdog requires Windows 10 / Server 2016 or later.');
  const contents = await Promise.all(sources.map(p => readFile(p)));
  const hash = createHash('sha256').update(Buffer.concat(contents)).digest('hex').slice(0, 24);
  const dir = path.join(tmpdir(), 'voxel-owned-process', hash);
  await mkdir(dir, { recursive: true });
  const exe = path.join(dir, 'owned-process.exe');
  if (existsSync(exe)) return exe;
  const compiler = path.join(process.env.SystemRoot || 'C:\\Windows',
    'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe');
  if (!existsSync(compiler)) throw new Error('C# compiler unavailable: ' + compiler);
  const temporary = path.join(dir, randomUUID() + '.exe');
  await new Promise((resolve, reject) => {
    const child = spawn(compiler, ['/nologo', '/target:exe', '/platform:x64',
      '/reference:System.Web.Extensions.dll', '/out:' + temporary, ...sources],
    { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', b => { output += b; });
    child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { child.kill(); reject(new Error('Native compiler timed out')); }, 30000);
    child.on('error', e => { clearTimeout(timer); reject(e); });
    child.on('close', code => {
      clearTimeout(timer);
      if (code === 0) resolve(); else reject(new Error('Native compiler failed: ' + output));
    });
  });
  try { await rename(temporary, exe); }
  catch (e) { if (!existsSync(exe)) throw e; await rm(temporary, { force: true }); }
  return exe;
}
// Requests are sequential. Only the retained helper ChildProcess is ever killed;
// target PIDs are evidence and are never used as termination authority.
export function openOwnedNativeHost(executable, env) {
  const child = spawn(executable, [], {
    env, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
  });
  let pending, dead, diagnostics = '';
  child.stderr.on('data', b => { diagnostics = (diagnostics + b).slice(-8192); });
  const fail = error => {
    dead = error;
    if (pending) { clearTimeout(pending.timer); pending.reject(error); pending = undefined; }
  };
  child.on('error', fail);
  child.stdin.on('error', fail);
  const closed = new Promise(resolve => child.on('close', (code, signal) => {
    fail(new Error('Native host closed (' + code + ', ' + signal + '): ' + diagnostics));
    resolve();
  }));
  createInterface({ input: child.stdout }).on('line', line => {
    if (!pending) { fail(new Error('Unexpected native host response')); child.kill(); return; }
    const request = pending; pending = undefined; clearTimeout(request.timer);
    try {
      const response = JSON.parse(line);
      if (response.ok) request.resolve(response.value);
      else {
        const error = new Error(response.error);
        error.nativeCreateReachedProcess = response.nativeCreateReachedProcess;
        request.reject(error);
      }
    } catch (error) { request.reject(error); }
  });
  return {
    pid: child.pid,
    request(op, fields = {}, timeout = 5000) {
      if (dead) return Promise.reject(dead);
      if (pending) return Promise.reject(new Error('Concurrent native request'));
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          fail(new Error('Native host RPC deadline expired during ' + op));
          child.kill(); // Kill-on-close remains the backstop; this alone is NOT zero proof.
        }, Math.max(1, timeout));
        pending = { resolve, reject, timer };
        child.stdin.write(JSON.stringify({ ...fields, op }) + '\n');
      });
    },
    async finish(timeout = 1000) {
      child.stdin.end();
      let timer;
      await Promise.race([closed, new Promise(resolve => {
        timer = setTimeout(() => { child.kill(); resolve(); }, Math.max(1, timeout));
      })]);
      clearTimeout(timer);
    },
    abort() { child.kill(); },
  };
}

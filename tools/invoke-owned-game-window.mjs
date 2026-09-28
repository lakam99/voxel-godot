import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, rmdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = dirname(fileURLToPath(import.meta.url));
const fields = ['LiveOwnershipPath', 'RunId', 'ProjectPath', 'Action', 'WindowHandle',
  'CapturePath', 'X', 'Y', 'Dx', 'Dy', 'Button', 'Key', 'HoldMilliseconds',
  'ExpectedClientWidth', 'ExpectedClientHeight'];
const names = new Map(fields.map(name => [name.toLowerCase(), name]));
const integers = new Set(['WindowHandle', 'X', 'Y', 'Dx', 'Dy', 'HoldMilliseconds',
  'ExpectedClientWidth', 'ExpectedClientHeight']);

export function parseOwnedWindowArguments(args) {
  const request = {};
  for (let i = 0; i < args.length; i++) {
    const match = /^--?([a-z][a-z-]*)(?:=(.*))?$/i.exec(args[i]);
    const name = match && names.get(match[1].replaceAll('-', '').toLowerCase());
    if (!name) throw new Error(`Unknown owned-window option: ${args[i]}`);
    if (Object.hasOwn(request, name)) throw new Error(`Duplicate option: ${name}`);
    const value = match[2] ?? args[++i];
    if (value === undefined || (value.startsWith('-') && !/^-\d+$/.test(value))) {
      throw new Error(`Missing value for ${name}`);
    }
    // Keep HWND as a decimal string across Node/JSON; never round a 64-bit handle.
    if (integers.has(name) && !/^-?\d+$/.test(value)) throw new Error(`${name} must be an integer`);
    request[name] = value;
  }
  for (const name of ['LiveOwnershipPath', 'RunId', 'ProjectPath']) {
    if (!request[name]?.trim()) throw new Error(`${name} is required`);
  }
  for (const name of ['LiveOwnershipPath', 'ProjectPath', 'CapturePath']) {
    if (request[name]) request[name] = resolve(request[name]);
  }
  return request;
}

// Compile source directly: no PowerShell, shell, package install, or desktop action.
// Each build uses a private directory; a concurrent identical build can safely win.
export function buildOwnedWindowHelper({ tests = false } = {}) {
  if (process.platform !== 'win32') throw new Error('Owned-window control requires Windows.');
  const compiler = join(process.env.SystemRoot ?? 'C:/Windows', 'Microsoft.NET/Framework64/v4.0.30319/csc.exe');
  if (!existsSync(compiler)) throw new Error(`Missing .NET Framework C# compiler: ${compiler}`);
  const sources = ['owned-window-native.cs', 'owned-window.cs', ...(tests ? ['owned-window-tests.cs'] : [])]
    .map(name => join(directory, 'native', name));
  const options = ['/nologo', '/target:exe', '/platform:x64', '/optimize+', '/warnaserror+',
    '/r:System.Web.Extensions.dll', '/r:System.Drawing.dll',
    `/main:${tests ? 'OwnedWindowTests' : 'OwnedWindowProgram'}`];
  const hash = createHash('sha256').update(JSON.stringify([compiler, options]));
  for (const source of sources) hash.update(readFileSync(source));
  const cache = join(tmpdir(), 'voxel-owned-window', hash.digest('hex'));
  const executable = join(cache, 'owned-window.exe');
  if (existsSync(executable)) return executable;
  mkdirSync(dirname(cache), { recursive: true });
  const staging = `${cache}-${process.pid}-${Date.now()}`;
  mkdirSync(staging);
  try {
    const result = spawnSync(compiler, [...options, `/out:${join(staging, 'owned-window.exe')}`, ...sources],
      { encoding: 'utf8', windowsHide: true, shell: false, timeout: 60000 });
    if (result.error || result.status !== 0) {
      throw new Error(`Owned-window helper compilation failed: ${result.error?.message ?? ''}\n${result.stdout ?? ''}${result.stderr ?? ''}`);
    }
    try { renameSync(staging, cache); }
    catch (error) { if (!existsSync(executable)) throw error; }
  } finally {
    // Only remove this build's known output; never recursively delete a cache.
    if (existsSync(staging)) {
      rmSync(join(staging, 'owned-window.exe'), { force: true });
      rmdirSync(staging);
    }
  }
  return executable;
}

export function main(args = process.argv.slice(2)) {
  if (args.length === 1 && /^(--help|-Help)$/i.test(args[0])) {
    process.stdout.write('Usage: node tools/invoke-owned-game-window.mjs -LiveOwnershipPath PATH -RunId ID -ProjectPath PATH [-Action Inspect|Focus|Capture|Click|Key|MouseLook] [options]\nInput requires -WindowHandle, -ExpectedClientWidth and -ExpectedClientHeight from Inspect.\n');
    return;
  }
  const request = parseOwnedWindowArguments(args);
  const executable = buildOwnedWindowHelper();
  // Do not impose a Node kill timer during a key/button hold: the helper owns
  // finally-based release and its bounded hold loop. Never retry failed input.
  const result = spawnSync(executable, [], {
    input: JSON.stringify(request), encoding: 'utf8', windowsHide: true, shell: false,
  });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); }
  catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
}

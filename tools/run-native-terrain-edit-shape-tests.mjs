#!/usr/bin/env node

import { createHash, randomUUID } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const project = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function option(name, fallback = undefined) {
  const prefix = `--${name}=`;
  const inline = process.argv.slice(2).find(value => value.startsWith(prefix));
  if (inline) return inline.slice(prefix.length);
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

function git(args) {
  return execFileSync('git', args, { cwd: project, encoding: 'utf8' }).trim();
}

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function record(path) {
  const value = statSync(path);
  return {
    path: relative(project, path).replaceAll('\\', '/'),
    bytes: value.size,
    sha256: sha256(path),
  };
}

function where(command) {
  const text = execFileSync('where.exe', [command], { encoding: 'utf8' }).trim();
  return text.split(/\r?\n/)[0];
}

function run(label, executable, args, output, environment = process.env, shell = false) {
  const started = Date.now();
  const result = spawnSync(executable, args, {
    cwd: project,
    encoding: 'utf8',
    env: environment,
    shell,
    windowsHide: true,
    maxBuffer: 64 * 1024 * 1024,
  });
  const stdout = result.stdout ?? '';
  const stderr = result.stderr ?? '';
  const stdoutPath = join(output, `${label}.stdout.log`);
  const stderrPath = join(output, `${label}.stderr.log`);
  writeFileSync(stdoutPath, stdout);
  writeFileSync(stderrPath, stderr);
  return {
    label,
    executable,
    args,
    shell,
    exitCode: result.status ?? -1,
    signal: result.signal ?? null,
    error: result.error?.message ?? null,
    durationMilliseconds: Date.now() - started,
    stdout: record(stdoutPath),
    stderr: record(stderrPath),
  };
}

function requirePassed(step) {
  if (step.exitCode !== 0 || step.signal || step.error) {
    throw new Error(`${step.label} failed with exit ${step.exitCode}: ${step.error ?? step.signal ?? 'see logs'}`);
  }
}

function nativeTestResult(step) {
  const stdout = readFileSync(resolve(project, step.stdout.path), 'utf8');
  const line = stdout.split(/\r?\n/).find(value => value.startsWith('{"schema":"native-world-backend-tests/v1"'));
  if (!line) throw new Error(`${step.label} emitted no native test receipt`);
  const parsed = JSON.parse(line);
  if (parsed.failed !== 0 || parsed.passed !== parsed.total || parsed.total < 1) {
    throw new Error(`${step.label} did not pass every registered test`);
  }
  return parsed;
}

function coverageSummary(exportValue, expectedPaths) {
  const files = exportValue?.data?.[0]?.files;
  if (!Array.isArray(files)) throw new Error('llvm-cov export schema is not recognized');
  const result = {};
  for (const expectedPath of expectedPaths) {
    const normalized = resolve(expectedPath).toLowerCase();
    const selected = files.find(file => resolve(file.filename).toLowerCase() === normalized);
    if (!selected) throw new Error(`llvm-cov omitted ${expectedPath}`);
    const source = relative(project, expectedPath).replaceAll('\\', '/');
    result[source] = {};
    for (const metric of ['lines', 'functions', 'branches']) {
      const summary = selected.summary?.[metric];
      if (!summary || summary.count < 1 || summary.covered !== summary.count) {
        throw new Error(`${source} ${metric} coverage is not 100%`);
      }
      result[source][metric] = {
        count: summary.count, covered: summary.covered, percent: summary.percent,
      };
    }
  }
  return result;
}

const runName = option('run-name', `native-edit-shape-${new Date().toISOString().replace(/[:.]/g, '-')}-${randomUUID().slice(0, 8)}`);
const output = resolve(project, option('output', join('artifacts', 'native-world-backend', runName)));
const llvmRootValue = option('llvm-root', process.env.VWB_LLVM_ROOT);
if (!llvmRootValue) throw new Error('Pass --llvm-root PATH or set VWB_LLVM_ROOT');
const llvmRoot = resolve(project, llvmRootValue);
if (existsSync(output)) throw new Error(`output already exists: ${output}`);
mkdirSync(output, { recursive: true });
const build = join(output, 'build');
const msvcObjects = join(build, 'msvc-obj');
mkdirSync(msvcObjects, { recursive: true });
const llvmObjects = join(build, 'llvm-obj');
mkdirSync(llvmObjects, { recursive: true });

const manifestPath = join(project, 'native', 'world_backend', 'source-manifest.json');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
if (manifest.schema !== 'native-world-backend-source-manifest/v1') throw new Error('unexpected native source manifest');
const backend = join(project, 'native', 'world_backend');
const core = join(backend, 'core');
const tests = join(backend, 'tests');
const coreSources = manifest.coreSources.map(path => join(backend, path));
const selectedTests = [
  join(tests, 'test_main.cpp'),
  join(tests, 'native_terrain_edit_shape_compiler_tests.cpp'),
  join(tests, 'native_cell_state_tests.cpp'),
  join(tests, 'native_terrain_volume_v2_codec_tests.cpp'),
];
const runnerPath = fileURLToPath(import.meta.url);
const trackedInputs = [...coreSources,
  ...manifest.coreHeaders.map(path => join(backend, path)),
  ...selectedTests, manifestPath, runnerPath].sort();
const sourcesBefore = trackedInputs.map(record);
const commitBefore = git(['rev-parse', 'HEAD']);
const branch = git(['branch', '--show-current']);
const statusBefore = git(['status', '--short']);
if (statusBefore) throw new Error('focused native receipt requires a clean worktree');

const cl = where('cl.CMD');
const clang = join(llvmRoot, 'bin', 'clang-cl.exe');
const profdata = join(llvmRoot, 'bin', 'llvm-profdata.exe');
const cov = join(llvmRoot, 'bin', 'llvm-cov.exe');
const tools = [cl, clang, profdata, cov]
  .map(path => ({ path, bytes: statSync(path).size, sha256: sha256(path) }));
const steps = [];
let status = 'running';
let failure = null;
let msvcTests = null;
let llvmTests = null;
let coverage = null;

try {
  const clangVersion = run('clang-version', clang, ['--version'], output);
  steps.push(clangVersion);
  requirePassed(clangVersion);
  const profdataVersion = run('llvm-profdata-version', profdata, ['--version'], output);
  steps.push(profdataVersion);
  requirePassed(profdataVersion);
  const covVersion = run('llvm-cov-version', cov, ['--version'], output);
  steps.push(covVersion);
  requirePassed(covVersion);

  const msvcExe = join(build, 'native-terrain-edit-shape-msvc-tests.exe');
  const msvcObjectPaths = [];
  for (const [index, source] of [...coreSources, ...selectedTests].entries()) {
    const object = join(msvcObjects, `${String(index).padStart(3, '0')}-${basename(source, '.cpp')}.obj`);
    const step = run(`msvc-compile-${String(index).padStart(3, '0')}`, cl,
      ['/nologo', ...(index === 0 ? ['/Bv'] : []), '/WX', '/std:c++17', '/EHsc', '/Od', '/RTC1', '/fp:strict', '/Z7',
        `/I${core}`, `/I${tests}`, '/c', source, `/Fo:${object}`], output, process.env, true);
    steps.push(step);
    requirePassed(step);
    msvcObjectPaths.push(object);
  }
  const msvcLinkResponse = join(build, 'msvc-link.rsp');
  writeFileSync(msvcLinkResponse, [
    '/nologo',
    ...msvcObjectPaths.map(path => `"${path}"`),
    `"/Fe:${msvcExe}"`,
    '/link',
    '/DEBUG:FULL',
    '/OPT:NOREF',
    '/OPT:NOICF',
    `"/PDB:${join(build, 'native-terrain-edit-shape-msvc-tests.pdb')}"`,
  ].join('\n'));
  const msvcLink = run('msvc-link', cl, [`@${msvcLinkResponse}`], output, process.env, true);
  msvcLink.responseFile = record(msvcLinkResponse);
  steps.push(msvcLink);
  requirePassed(msvcLink);
  const msvcExecute = run('msvc-execute', msvcExe, [], output);
  steps.push(msvcExecute);
  requirePassed(msvcExecute);
  msvcTests = nativeTestResult(msvcExecute);

  const llvmExe = join(build, 'native-terrain-edit-shape-llvm-tests.exe');
  const llvmEnvironment = { ...process.env, PATH: `${join(llvmRoot, 'bin')};${process.env.PATH ?? ''}` };
  const llvmObjectPaths = [];
  for (const [index, source] of [...coreSources, ...selectedTests].entries()) {
    const object = join(llvmObjects, `${String(index).padStart(3, '0')}-${basename(source, '.cpp')}.obj`);
    const step = run(`llvm-compile-${String(index).padStart(3, '0')}`, clang,
      ['/nologo', '/WX', '/std:c++17', '/EHsc', '/Od', '/Z7', '/fp:strict',
        '/clang:-fprofile-instr-generate', '/clang:-fcoverage-mapping', `/I${core}`, `/I${tests}`,
        '/c', source, `/Fo:${object}`], output, llvmEnvironment);
    steps.push(step);
    requirePassed(step);
    llvmObjectPaths.push(object);
  }
  const llvmLink = run('llvm-link', clang,
    ['/nologo', '/clang:-fprofile-instr-generate', ...llvmObjectPaths, `/Fe:${llvmExe}`,
      '/link', '/DEBUG:FULL', '/OPT:NOREF', '/OPT:NOICF',
      `/PDB:${join(build, 'native-terrain-edit-shape-llvm-tests.pdb')}`], output, llvmEnvironment);
  steps.push(llvmLink);
  requirePassed(llvmLink);
  const raw = join(build, 'native-terrain-edit-shape.profraw');
  const llvmExecute = run('llvm-execute', llvmExe, [], output, { ...process.env, LLVM_PROFILE_FILE: raw });
  steps.push(llvmExecute);
  requirePassed(llvmExecute);
  llvmTests = nativeTestResult(llvmExecute);
  const data = join(build, 'native-terrain-edit-shape.profdata');
  const merge = run('llvm-merge', profdata, ['merge', '-sparse', raw, '-o', data], output);
  steps.push(merge);
  requirePassed(merge);
  const exported = run('llvm-export', cov, ['export', llvmExe, `-instr-profile=${data}`, '-format=text'], output);
  steps.push(exported);
  requirePassed(exported);
  const exportValue = JSON.parse(readFileSync(resolve(project, exported.stdout.path), 'utf8'));
  const compilerPath = join(core, 'native_terrain_edit_shape_compiler.cpp');
  const cellStatePath = join(core, 'native_cell_state.cpp');
  coverage = coverageSummary(exportValue, [compilerPath, cellStatePath]);
  const textReport = run('llvm-report', cov,
    ['report', llvmExe, `-instr-profile=${data}`, '--show-branch-summary', compilerPath, cellStatePath], output);
  steps.push(textReport);
  requirePassed(textReport);
  status = 'passed';
} catch (error) {
  status = 'failed';
  failure = { message: error.message, stack: error.stack };
}

const commitAfter = git(['rev-parse', 'HEAD']);
const statusAfter = git(['status', '--short']);
const sourcesAfter = trackedInputs.map(record);
if (commitAfter !== commitBefore || statusAfter !== statusBefore
    || JSON.stringify(sourcesAfter) !== JSON.stringify(sourcesBefore)) {
  status = 'failed';
  failure = { message: 'git commit, worktree status, or source hashes changed during the focused run' };
}
const receipt = {
  schema: 'native-terrain-edit-shape-focused-receipt/v1',
  status,
  runName,
  startedFrom: { commit: commitBefore, branch, status: statusBefore },
  completedAtUtc: new Date().toISOString(),
  sourceInputs: sourcesBefore,
  tools,
  steps,
  tests: { msvc: msvcTests, llvm: llvmTests },
  coverage,
  unchanged: { commit: commitAfter === commitBefore, status: statusAfter === statusBefore,
    sourceHashes: JSON.stringify(sourcesAfter) === JSON.stringify(sourcesBefore) },
  failure,
};
const reportPath = join(output, 'report.json');
writeFileSync(reportPath, `${JSON.stringify(receipt, null, 2)}\n`);
process.stdout.write(`${JSON.stringify({ status, reportPath }, null, 2)}\n`);
process.exitCode = status === 'passed' ? 0 : 1;

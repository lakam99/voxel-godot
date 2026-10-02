#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { cp, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runOwnedProcess } from '../lib/owned-process.mjs';

const project = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const lockDirectory = join(project, 'native/voxel_tools');
const stagingDirectory = join(project, 'artifacts/vt/b');
const lockPath = join(lockDirectory, 'mesh_preparation.lock.json');

function demand(condition, message) {
  if (!condition) throw new Error(message);
}

function run(executable, args, options = {}) {
  const result = spawnSync(executable, args, {
    cwd: options.cwd ?? project, env: options.env ?? process.env,
    encoding: 'utf8', windowsHide: true, timeout: options.timeout ?? 120000,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    throw new Error(`${executable} ${args.join(' ')} failed: ${result.error?.message ?? result.stderr ?? result.stdout}`);
  }
  return result.stdout.trim();
}

async function sha256(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

async function pinnedCheckout(path, expectedCommit, label) {
  const actual = run('git', ['-C', path, 'rev-parse', 'HEAD']);
  demand(actual === expectedCommit, `${label} must be ${expectedCommit}; found ${actual}`);
}

async function archiveCheckout(checkout, revision, destination, archivePath) {
  await mkdir(destination, { recursive: true });
  run('git', ['-C', checkout, 'archive', '--format=tar', `--output=${archivePath}`, revision]);
  run('tar.exe', ['-xf', archivePath, '-C', destination]);
}

function applyCheckedPatch(directory, patch) {
  // Staging lives below the game repository. Stop Git from discovering that
  // parent repository, which otherwise silently filters these patch paths.
  const env = { ...process.env, GIT_CEILING_DIRECTORIES: dirname(directory) };
  run('git', ['-C', directory, 'apply', '--check', patch], { env });
  run('git', ['-C', directory, 'apply', patch], { env });
}

async function discoverMsvc(pin) {
  const programFilesX86 = process.env['ProgramFiles(x86)'] ?? 'C:/Program Files (x86)';
  const vswhere = join(programFilesX86, 'Microsoft Visual Studio/Installer/vswhere.exe');
  await stat(vswhere);
  const installation = run(vswhere, ['-latest', '-products', '*', '-requires',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath']);
  demand(installation, 'vswhere found no Visual Studio installation with MSVC x64 tools');
  const msvcRoot = join(installation, 'VC/Tools/MSVC');
  const versions = (await readdir(msvcRoot)).sort().reverse();
  demand(versions[0] === pin.toolsetVersion,
    `MSVC toolset must be ${pin.toolsetVersion}; found ${versions[0] ?? 'none'}`);
  const bin = join(msvcRoot, versions[0], 'bin/Hostx64/x64');
  const cl = join(bin, 'cl.exe');
  const link = join(bin, 'link.exe');
  const vcvars64 = join(installation, 'VC/Auxiliary/Build/vcvars64.bat');
  const banner = executable => {
    const result = spawnSync(executable, [], { encoding: 'utf8', windowsHide: true });
    demand(!result.error, `${executable} version probe failed: ${result.error?.message}`);
    return `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
  };
  const compilerVersion = /Compiler Version ([0-9.]+)/i.exec(banner(cl))?.[1];
  const linkerVersion = /Linker Version ([0-9.]+)/i.exec(banner(link))?.[1];
  const digests = {
    vcvars64Sha256: await sha256(vcvars64), clSha256: await sha256(cl),
    linkSha256: await sha256(link),
  };
  for (const [key, expected] of Object.entries(pin)) {
    const actual = { toolsetVersion: versions[0], compilerVersion, linkerVersion,
      vcvarsArgs: `-vcvars_ver=${versions[0]}`, ...digests }[key];
    demand(actual === expected, `MSVC ${key} must be ${expected}; found ${actual}`);
  }
  return { installation, toolsetVersion: versions[0], compilerVersion,
    linkerVersion, vcvars64, vcvarsArgs: pin.vcvarsArgs, cl, link, ...digests };
}

async function vcvarsEnvironment(msvc, outputDirectory) {
  // The batch file only prepares compiler variables. Builds run separately in
  // the repository's owned Windows Job Object helper.
  const captureScript = join(outputDirectory, 'capture-vcvars.cmd');
  await writeFile(captureScript, `@echo off\r\ncall "${msvc.vcvars64}" ${msvc.vcvarsArgs} >nul\r\nif errorlevel 1 exit /b 1\r\nset\r\n`);
  const output = run('cmd.exe', ['/d', '/c', captureScript]);
  const environment = { ...process.env };
  for (const line of output.split(/\r?\n/)) {
    const index = line.indexOf('=');
    if (index > 0) environment[line.slice(0, index)] = line.slice(index + 1);
  }
  demand(environment.VSCMD_ARG_TGT_ARCH === 'x64', 'vcvars64 did not prepare an x64 MSVC environment');
  demand(environment.VCToolsVersion?.replace(/\\$/, '') === msvc.toolsetVersion,
    `vcvars64 selected ${environment.VCToolsVersion ?? 'no'} toolset, expected ${msvc.toolsetVersion}`);
  demand(environment.INCLUDE && environment.LIB, 'vcvars64 omitted required compiler paths');
  return environment;
}

async function buildTarget({ source, cpp, target, python, environment, output, jobs }) {
  const prefix = join(output, `scons-${target}`);
  const args = ['-m', 'SCons', 'platform=windows', `target=${target}`, `-j${jobs}`];
  const result = await runOwnedProcess({
    projectPath: source, executable: python, args,
    env: { ...environment, GODOT_CPP_PATH: cpp }, timeoutSeconds: 1800,
    stdoutPath: `${prefix}.stdout.log`, stderrPath: `${prefix}.stderr.log`,
    summaryPath: `${prefix}.watchdog.json`,
  });
  demand(result.functionalExitCode === 0 && result.overallExitCode === 0
    && result.cleanupPassed && result.authoritativeZeroProven,
  `${target} build failed or was not cleaned up; see ${prefix}.watchdog.json`);
  return { target, args, stdout: `${prefix}.stdout.log`, stderr: `${prefix}.stderr.log`,
    watchdog: `${prefix}.watchdog.json`, functionalExitCode: result.functionalExitCode,
    authoritativeZeroProven: result.authoritativeZeroProven };
}

async function main() {
  demand(process.platform === 'win32', 'This staging runner builds Windows DLLs only');
  const lock = JSON.parse(await readFile(lockPath, 'utf8'));
  demand(lock.schema === 'voxel-tools-mesh-preparation-lock/v1', 'Unexpected native lock schema');
  const msvc = await discoverMsvc(lock.windows.msvc);
  if (process.argv.includes('--verify-toolchain-only')) {
    const scratch = await mkdtemp(join(tmpdir(), 'voxel-tools-msvc-'));
    try {
      const environment = await vcvarsEnvironment(msvc, scratch);
      const report = { schema: 'voxel-tools-msvc-preflight/v1', status: 'verified',
        toolchain: msvc, selectedToolset: environment.VCToolsVersion,
        lockPath, lockSha256: await sha256(lockPath) };
      const comparisonArgument = process.argv.find(arg => arg.startsWith('--compare-build-report='));
      if (comparisonArgument) {
        const previousPath = resolve(project, comparisonArgument.slice('--compare-build-report='.length));
        const previous = JSON.parse(await readFile(previousPath, 'utf8'));
        demand(previous.status === 'ready'
          && resolve(previous.build?.vcvars64 ?? '') === resolve(msvc.vcvars64),
          'Prior ready build did not use the discovered vcvars64 path');
        demand(previous.outputs?.length === 2, 'Prior ready build does not contain both DLL outputs');
        for (const item of previous.outputs) {
          demand(await sha256(item.stagedPath) === item.sha256,
            `Previously staged ${item.name} no longer matches its build receipt`);
        }
        report.comparedBuild = { reportPath: previousPath, vcvars64PathMatched: true,
          stagedOutputs: previous.outputs.map(({ name, sha256: hash }) => ({ name, sha256: hash })) };
      }
      await mkdir(stagingDirectory, { recursive: true });
      const reportPath = join(stagingDirectory, `msvc-preflight-${randomUUID().slice(0, 12)}.json`);
      await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
      console.log(JSON.stringify({ status: report.status, reportPath,
        toolsetVersion: msvc.toolsetVersion, selectedToolset: report.selectedToolset,
        comparedBuild: report.comparedBuild }, null, 2));
    } finally {
      await rm(scratch, { recursive: true, force: true });
    }
    return;
  }
  const sourceCheckout = join(project, 'artifacts/vt/source');
  const cppCheckout = join(project, 'artifacts/vt/godot-cpp-4.5');
  await pinnedCheckout(sourceCheckout, lock.voxelTools.commit, 'Voxel Tools');
  await pinnedCheckout(cppCheckout, lock.godotCpp.commit, 'godot-cpp');
  const sourcePatch = join(lockDirectory, lock.voxelTools.patch);
  const cppPatch = join(lockDirectory, lock.godotCpp.patch);
  demand(await sha256(sourcePatch) === lock.voxelTools.patchSha256, 'Voxel Tools patch digest differs from lock');
  demand(await sha256(cppPatch) === lock.godotCpp.patchSha256, 'godot-cpp patch digest differs from lock');
  const python = run('python', ['-c', 'import sys; print(sys.executable)']);
  const jobs = Math.max(1, Math.min(16, Number(process.env.VOXEL_TOOLS_BUILD_JOBS ?? 6) || 6));
  const runId = randomUUID().slice(0, 12);
  const output = join(stagingDirectory, runId);
  const source = join(output, 'source');
  const cpp = join(output, 'cpp');
  const reportPath = join(output, 'build-report.json');
  const report = {
    schema: 'voxel-tools-mesh-preparation-build/v1', runId, status: 'preparing',
    source: { repository: lock.voxelTools.repository, tag: lock.voxelTools.tag,
      commit: lock.voxelTools.commit, patchSha256: lock.voxelTools.patchSha256 },
    godotCpp: { tag: lock.godotCpp.tag, commit: lock.godotCpp.commit,
      patchSha256: lock.godotCpp.patchSha256 },
    build: { platform: 'windows', targets: lock.windows.targets, jobs, python,
      msvc, sconsVersion: run(python, ['-m', 'SCons', '--version']).split('\n')[1]?.trim() },
    steps: [], outputs: [], productionInstall: false,
  };
  await mkdir(output, { recursive: true });
  try {
    await archiveCheckout(sourceCheckout, lock.voxelTools.commit, source, join(output, 'source.tar'));
    await archiveCheckout(cppCheckout, lock.godotCpp.commit, cpp, join(output, 'cpp.tar'));
    applyCheckedPatch(source, sourcePatch);
    applyCheckedPatch(cpp, cppPatch);
    demand((await readFile(join(source, 'terrain/voxel_viewer.cpp'), 'utf8'))
      .includes('requires_mesh_preparation'), 'Voxel Tools patch did not reach staged source');
    demand((await readFile(join(cpp, 'tools/windows.py'), 'utf8'))
      .includes('SCons 4.10 can miss BuildTools discovery'), 'godot-cpp patch did not reach staged source');
    report.status = 'building';
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
    const environment = await vcvarsEnvironment(msvc, output);
    for (const target of lock.windows.targets) {
      report.steps.push(await buildTarget({ source, cpp, target, python, environment, output, jobs }));
      await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
    }
    const bin = join(source, 'project/addons/zylann.voxel/bin');
    const dlls = [lock.windows.editorDll, lock.windows.releaseDll];
    for (const name of dlls) {
      const path = join(bin, name);
      const info = await stat(path);
      demand(info.size > 0, `${name} is empty`);
      report.outputs.push({ name, sourcePath: path, bytes: info.size, sha256: await sha256(path) });
    }
    // Publish a ready set only after both DLLs and both owned builds pass.
    const ready = join(output, 'ready');
    await mkdir(ready, { recursive: true });
    for (const item of report.outputs) {
      const stagedPath = join(ready, item.name);
      await cp(item.sourcePath, stagedPath);
      demand(await sha256(stagedPath) === item.sha256, `${item.name} changed while staging`);
      item.stagedPath = stagedPath;
    }
    report.status = 'ready';
    report.readyDirectory = ready;
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
    console.log(JSON.stringify({ status: report.status, reportPath, readyDirectory: ready,
      outputs: report.outputs.map(({ name, sha256: hash }) => ({ name, sha256: hash })) }, null, 2));
  } catch (error) {
    report.status = 'failed';
    report.error = error.message;
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
    throw error;
  }
}

await main().catch(error => {
  console.error(error.stack ?? String(error));
  process.exitCode = 1;
});

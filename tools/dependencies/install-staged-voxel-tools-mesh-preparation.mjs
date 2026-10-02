#!/usr/bin/env node
import { randomUUID } from 'node:crypto';
import { cp, mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { activeReceiptPath, fileSha256, inspectPatchedInstall } from '../lib/voxel-tools-patched-install.mjs';

const project = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const lockDirectory = join(project, 'native/voxel_tools');
const lockPath = join(lockDirectory, 'mesh_preparation.lock.json');
const installRoot = join(project, 'artifacts/vt/install');
const bin = join(project, 'addons/zylann.voxel/bin');
const activePath = activeReceiptPath(project);
const dllNames = ['libvoxel.windows.editor.x86_64.dll', 'libvoxel.windows.template_release.x86_64.dll'];

function demand(condition, message) { if (!condition) throw new Error(message); }
function option(name) { return process.argv.find(arg => arg.startsWith(`${name}=`))?.slice(name.length + 1); }
function inside(parent, child) {
  const offset = relative(parent, child);
  return offset !== '' && offset !== '..' && !offset.startsWith(`..\\`) && !offset.startsWith('../') && !isAbsolute(offset);
}
async function json(path) { return JSON.parse(await readFile(path, 'utf8')); }
async function atomicJson(path, value) {
  const scratch = `${path}.${randomUUID()}.tmp`;
  try { await writeFile(scratch, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx' }); await rename(scratch, path); }
  finally { await rm(scratch, { force: true }); }
}
async function verifyBuild(reportPath, preflightPath) {
  const buildDirectory = dirname(reportPath);
  demand(basename(reportPath) === 'build-report.json'
    && inside(join(project, 'artifacts/vt/b'), buildDirectory),
  'Build report must be inside one isolated build staging directory');
  const lock = await json(lockPath);
  demand(lock.schema === 'voxel-tools-mesh-preparation-lock/v1', 'Unknown native lock schema');
  for (const source of [lock.voxelTools, lock.godotCpp]) {
    demand(await fileSha256(join(lockDirectory, source.patch)) === source.patchSha256,
      `Tracked patch differs from lock: ${source.patch}`);
  }
  const report = await json(reportPath);
  demand(report.schema === 'voxel-tools-mesh-preparation-build/v1' && report.status === 'ready'
    && report.productionInstall === false, 'Build report is not a ready isolated build');
  for (const [label, pinned] of [['source', lock.voxelTools], ['godotCpp', lock.godotCpp]]) {
    for (const key of ['tag', 'commit', 'patchSha256']) {
      demand(report[label]?.[key] === pinned[key], `${label}.${key} differs from lock`);
    }
  }
  demand(report.source.repository === lock.voxelTools.repository,
    'Voxel Tools repository differs from lock');
  demand(report.build?.platform === 'windows'
    && JSON.stringify(report.build.targets) === JSON.stringify(lock.windows.targets),
  'Build targets differ from lock');
  if (report.build.msvc) {
    for (const [key, value] of Object.entries(lock.windows.msvc)) {
      demand(report.build.msvc[key] === value, `Build MSVC ${key} differs from lock`);
    }
  } else {
    demand(preflightPath, 'This earlier build needs a matching MSVC preflight report');
    const preflight = await json(preflightPath);
    demand(preflight.schema === 'voxel-tools-msvc-preflight/v1'
      && preflight.status === 'verified' && preflight.lockSha256 === await fileSha256(lockPath)
      && resolve(preflight.comparedBuild?.reportPath ?? '') === reportPath
      && resolve(preflight.toolchain?.vcvars64 ?? '') === resolve(report.build.vcvars64 ?? ''),
    'MSVC preflight does not match this lock and ready build');
    for (const [key, value] of Object.entries(lock.windows.msvc)) {
      demand(preflight.toolchain[key] === value, `Preflight MSVC ${key} differs from lock`);
    }
  }
  demand(report.steps?.length === 2 && report.outputs?.length === 2,
    'Build report must include two successful builds and two DLLs');
  for (let index = 0; index < 2; index += 1) {
    const target = lock.windows.targets[index];
    const step = report.steps[index];
    demand(step.target === target && step.functionalExitCode === 0 && step.authoritativeZeroProven,
      `${target} build step lacks a clean success receipt`);
    demand(step.watchdog === join(buildDirectory, `scons-${target}.watchdog.json`),
      `${target} watchdog path is outside its verified build staging directory`);
    const watchdog = await json(step.watchdog);
    demand(watchdog.functionalExitCode === 0 && watchdog.overallExitCode === 0
      && watchdog.cleanupPassed && watchdog.authoritativeZeroProven,
    `${target} owned build watchdog is not clean`);
  }
  demand(report.readyDirectory === join(buildDirectory, 'ready'),
    'Ready directory is outside its verified build staging directory');
  const names = [lock.windows.editorDll, lock.windows.releaseDll];
  const outputs = [];
  for (const name of names) {
    const item = report.outputs.find(candidate => candidate.name === name);
    demand(item && item.stagedPath === join(report.readyDirectory, name), `${name} is missing from ready set`);
    demand((await stat(item.stagedPath)).size === item.bytes
      && await fileSha256(item.stagedPath) === item.sha256, `${name} staged bytes differ from build report`);
    outputs.push({ name, sha256: item.sha256, bytes: item.bytes, stagedPath: item.stagedPath });
  }
  demand(report.outputs.length === names.length, 'Unexpected additional staged DLL in build report');
  return { report, lock, outputs };
}

async function restore() {
  const receipt = (await inspectPatchedInstall(project))?.receipt;
  demand(receipt && ['installing', 'installed', 'restoring'].includes(receipt.status),
    'No reversible patched Voxel Tools installation is recorded');
  demand(inside(join(installRoot, 'backups'), receipt.backupDirectory), 'Backup directory escaped install storage');
  demand(receipt.originalOutputs?.length === 2 && receipt.patchedOutputs?.length === 2,
    'Install receipt does not contain both DLL pairs');
  for (const name of dllNames) {
    demand(receipt.originalOutputs.some(item => item.name === name)
      && receipt.patchedOutputs.some(item => item.name === name),
    `Install receipt is missing ${name}`);
  }
  for (const item of receipt.originalOutputs) {
    demand(await fileSha256(join(receipt.backupDirectory, item.name)) === item.sha256,
      `Original ${item.name} backup differs from install receipt`);
    if (receipt.status === 'installed') {
      const currentHash = await fileSha256(join(bin, item.name)).catch(error => {
        if (error.code === 'ENOENT') return null;
        throw error;
      });
      demand(currentHash === null || currentHash === item.sha256
        || currentHash === receipt.patchedOutputs.find(candidate => candidate.name === item.name)?.sha256,
      `${item.name} changed outside this install; refusing to overwrite it`);
    }
  }
  receipt.status = 'restoring';
  await atomicJson(activePath, receipt);
  for (const item of receipt.originalOutputs) {
    await cp(join(receipt.backupDirectory, item.name), join(bin, item.name));
    demand(await fileSha256(join(bin, item.name)) === item.sha256, `${item.name} restore verification failed`);
  }
  receipt.status = 'restored';
  receipt.restoredAt = new Date().toISOString();
  await atomicJson(join(receipt.backupDirectory, 'restore-receipt.json'), receipt);
  await rm(activePath);
  console.log(JSON.stringify({ status: 'restored', backupDirectory: receipt.backupDirectory }, null, 2));
}

async function main() {
  demand(process.platform === 'win32', 'Windows DLL installation only');
  if (process.argv.includes('--restore')) return restore();
  const reportArgument = option('--build-report');
  demand(reportArgument, 'Pass --build-report=<ready build-report.json>');
  const reportPath = resolve(project, reportArgument);
  const preflightArgument = option('--preflight-report');
  const preflightPath = preflightArgument ? resolve(project, preflightArgument) : null;
  const { outputs } = await verifyBuild(reportPath, preflightPath);
  const active = await inspectPatchedInstall(project);
  demand(!active, 'A patched install receipt already exists; use --restore before another installation');
  const originalOutputs = [];
  for (const item of outputs) {
    const path = join(bin, item.name);
    const info = await stat(path);
    demand(info.size > 0, `${item.name} is not installed`);
    originalOutputs.push({ name: item.name, bytes: info.size, sha256: await fileSha256(path) });
  }
  if (!process.argv.includes('--install')) {
    console.log(JSON.stringify({ status: 'verified', reportPath,
      originalOutputs, patchedOutputs: outputs.map(({ name, bytes, sha256 }) => ({ name, bytes, sha256 })),
      productionInstall: false }, null, 2));
    return;
  }
  const backupDirectory = join(installRoot, 'backups', randomUUID());
  await mkdir(backupDirectory, { recursive: true });
  for (const item of originalOutputs) {
    await cp(join(bin, item.name), join(backupDirectory, item.name));
    demand(await fileSha256(join(backupDirectory, item.name)) === item.sha256,
      `${item.name} original backup verification failed`);
  }
  const receipt = { schema: 'voxel-tools-mesh-preparation-install/v1', status: 'installing',
    installedAt: new Date().toISOString(), buildReport: reportPath,
    buildReportSha256: await fileSha256(reportPath), lockSha256: await fileSha256(lockPath),
    backupDirectory, originalOutputs,
    patchedOutputs: outputs.map(({ name, bytes, sha256 }) => ({ name, bytes, sha256 })) };
  await mkdir(installRoot, { recursive: true });
  await atomicJson(activePath, receipt);
  try {
    for (const item of outputs) {
      await cp(item.stagedPath, join(bin, item.name));
      demand(await fileSha256(join(bin, item.name)) === item.sha256,
        `${item.name} install verification failed`);
    }
    receipt.status = 'installed';
    await atomicJson(activePath, receipt);
    await atomicJson(join(backupDirectory, 'install-receipt.json'), receipt);
  } catch (error) {
    await restore();
    throw error;
  }
  console.log(JSON.stringify({ status: 'installed', receiptPath: activePath,
    backupDirectory, patchedOutputs: receipt.patchedOutputs }, null, 2));
}

await main().catch(error => { console.error(error.stack ?? String(error)); process.exitCode = 1; });

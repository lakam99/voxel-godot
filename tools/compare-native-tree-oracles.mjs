#!/usr/bin/env node

import {spawnSync} from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const scriptFile = fileURLToPath(import.meta.url);

function optionalArgument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 && index + 1 < process.argv.length ? process.argv[index + 1] : null;
}
function argument(name) {
  const value = optionalArgument(name);
  if (value === null) throw new Error(`missing ${name}`);
  return value;
}
function hashFile(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}
function fileReceipt(file) {
  const absolute = path.resolve(file);
  return {path: absolute, bytes: fs.statSync(absolute).size, sha256: hashFile(absolute)};
}
function rows(file, prefix) {
  return fs.readFileSync(file, 'utf8').split(/\r?\n/u)
    .filter(line => line.startsWith(prefix)).map(line => JSON.parse(line.slice(prefix.length)));
}
function normalizedCounts(value) {
  if (Array.isArray(value)) return value.map(Number);
  return ['trunk', 'primary', 'secondary', 'tertiary', 'twig'].map(order => Number(value[order] ?? 0));
}
function normalizeRaw(row) {
  return {
    seed: Number(row.seed), maturity: Number(row.maturity), signature: row.signature,
    height: Number(row.height), trunkRadius: Number(row.trunkRadius), canopyRadius: Number(row.canopyRadius),
    crownBase: Number(row.crownBase), crownHeight: Number(row.crownHeight), branchCount: Number(row.branchCount),
    foliageCount: Number(row.foliageCount), nodeCount: Number(row.nodeCount),
    segmentCountsByOrder: normalizedCounts(row.segmentCountsByOrder), raisedForkCount: Number(row.raisedForkCount),
    crownWindowCount: Number(row.crownWindowCount), viableAxisBudCount: Number(row.viableAxisBudCount),
    germinatedAxisCount: Number(row.germinatedAxisCount), grownMetamerCount: Number(row.grownMetamerCount),
    pipeModelJunctionCount: Number(row.pipeModelJunctionCount),
    occupiedCrownBins: Number(row.occupiedCrownBins ?? row.crownOccupancy?.occupiedBins),
    branchSelectionHash: Number(row.branchSelectionHash), foliageSelectionHash: Number(row.foliageSelectionHash),
    branchHashCheckpoints: row.branchHashCheckpoints, foliageHashCheckpoints: row.foliageHashCheckpoints,
  };
}
function normalizeWorker(row, index) {
  const renderLod = row.renderLod ?? {}, collision = row.collision ?? {}, variation = row.case ?? {};
  const review = Boolean(row.review ?? variation.presentation === 'review');
  return {
    caseIndex: Number(row.caseIndex ?? index), signature: row.signature, topologySignature: row.topologySignature,
    sourceBranches: Number(row.sourceBranches), sourceFoliage: Number(row.sourceFoliage),
    branches: Number(row.branches), foliage: Number(row.foliage),
    branchSelectionHash: Number(row.branchSelectionHash), foliageSelectionHash: Number(row.foliageSelectionHash),
    renderTier: row.renderTier ?? renderLod.tier ?? variation.renderLodTier ?? 'near',
    branchBudget: review ? null : Number(row.branchBudget ?? renderLod.branchBudget ?? row.branches),
    foliageBudget: review ? null : Number(row.foliageBudget ?? renderLod.foliageBudget ?? row.foliage),
    impostor: Boolean(row.impostor ?? row.runtimeImpostor ?? renderLod.impostor),
    collisionRadius: Number(row.collisionRadius ?? collision.trunkRadius),
    collisionHeight: Number(row.collisionHeight ?? collision.trunkHeight),
    crownHabit: row.crownHabit, methodology: row.methodology,
  };
}
function exact(label, godot, native) {
  const compare = (left, right, field) => {
    if (typeof left === 'number' && typeof right === 'number') {
      if (Number.isInteger(left) && Number.isInteger(right)) {
        if (left !== right) throw new Error(`${label}.${field}: ${left} != ${right}`);
        return;
      }
      const tolerance = 1e-12 * Math.max(1, Math.abs(left), Math.abs(right));
      if (!Number.isFinite(left) || !Number.isFinite(right) || Math.abs(left - right) > tolerance) {
        throw new Error(`${label}.${field}: ${left} != ${right} (tolerance ${tolerance})`);
      }
      return;
    }
    if (Array.isArray(left) && Array.isArray(right)) {
      if (left.length !== right.length) throw new Error(`${label}.${field}: array lengths differ`);
      left.forEach((value, index) => compare(value, right[index], `${field}[${index}]`));
      return;
    }
    if (left && right && typeof left === 'object' && typeof right === 'object') {
      const leftKeys = Object.keys(left), rightKeys = Object.keys(right);
      if (JSON.stringify(leftKeys) !== JSON.stringify(rightKeys)) throw new Error(`${label}.${field}: keys differ`);
      leftKeys.forEach(key => compare(left[key], right[key], field ? `${field}.${key}` : key));
      return;
    }
    if (left !== right) throw new Error(`${label}.${field}: ${JSON.stringify(left)} != ${JSON.stringify(right)}`);
  };
  compare(godot, native, '');
}
function runCaptured(executable, args, options, stdoutFile, stderrFile) {
  const result = spawnSync(executable, args, {...options, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024});
  fs.writeFileSync(stdoutFile, result.stdout ?? '', 'utf8');
  fs.writeFileSync(stderrFile, result.stderr ?? '', 'utf8');
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${executable} exited ${result.status}; inspect ${stderrFile}`);
  return {command: [executable, ...args], exitCode: result.status,
    stdout: fileReceipt(stdoutFile), stderr: fileReceipt(stderrFile)};
}
function projectScript(project, uri) {
  if (!uri.startsWith('res://')) throw new Error(`oracle script is not a res:// URI: ${uri}`);
  return path.join(project, ...uri.slice(6).split('/'));
}

const configFile = path.resolve(argument('--config'));
const config = JSON.parse(fs.readFileSync(configFile, 'utf8'));
if (config.schema !== 'native-tree-oracle-attestation-config/v1') throw new Error('unsupported config schema');
const project = path.resolve(optionalArgument('--project') ?? '.');
const outputFile = path.resolve(argument('--out'));
let rawGodotFile = optionalArgument('--raw-godot');
let workerGodotFile = optionalArgument('--worker-godot');
let nativeFile = optionalArgument('--native');
let execution = null;
const sourceFiles = [projectScript(project, config.raw.godotScript), projectScript(project, config.worker.godotScript),
  ...config.authoritySources.map(file => path.join(project, ...file.split('/'))),
  ...config.nativeAuthoritySources.map(file => path.join(project, ...file.split('/'))), configFile, scriptFile];
const sourcesBefore = sourceFiles.map(fileReceipt);

if (process.argv.includes('--run')) {
  const outputDirectory = path.resolve(argument('--out-dir'));
  fs.mkdirSync(outputDirectory, {recursive: true});
  const configuredGodot = optionalArgument('--godot') ?? process.env.GODOT4_CONSOLE;
  if (!configuredGodot) throw new Error('provide --godot or GODOT4_CONSOLE');
  const godot = path.resolve(configuredGodot);
  const nativeExecutable = path.resolve(argument('--native-exe'));
  rawGodotFile = path.join(outputDirectory, 'raw-godot.stdout.log');
  workerGodotFile = path.join(outputDirectory, 'worker-godot.stdout.log');
  nativeFile = path.join(outputDirectory, 'native.stdout.log');
  const audioEnvironment = {...process.env, VOXEL_DISABLE_AUDIO_PLAYBACK: '1'};
  const rawRun = runCaptured(godot,
    ['--headless', '--audio-driver', 'Dummy', '--path', project, '--script', config.raw.godotScript],
    {cwd: project, env: audioEnvironment}, rawGodotFile, path.join(outputDirectory, 'raw-godot.stderr.log'));
  const workerRun = runCaptured(godot,
    ['--headless', '--audio-driver', 'Dummy', '--path', project, '--script', config.worker.godotScript],
    {cwd: project, env: audioEnvironment}, workerGodotFile, path.join(outputDirectory, 'worker-godot.stderr.log'));
  const nativeRun = runCaptured(nativeExecutable, [],
    {cwd: project, env: {...process.env, [config.nativeEnvironment]: '1'}},
    nativeFile, path.join(outputDirectory, 'native.stderr.log'));
  const versionFile = path.join(outputDirectory, 'godot-version.stdout.log');
  const versionRun = runCaptured(godot, ['--version'], {cwd: project, env: audioEnvironment},
    versionFile, path.join(outputDirectory, 'godot-version.stderr.log'));
  execution = {audio: {driver: 'Dummy', VOXEL_DISABLE_AUDIO_PLAYBACK: '1'}, rawRun, workerRun, nativeRun,
    godot: {...fileReceipt(godot), version: fs.readFileSync(versionFile, 'utf8').trim(), versionRun},
    nativeExecutable: fileReceipt(nativeExecutable)};
}
if (!rawGodotFile || !workerGodotFile || !nativeFile) {
  throw new Error('provide --run with executables or all three preexisting log paths');
}

rawGodotFile = path.resolve(rawGodotFile); workerGodotFile = path.resolve(workerGodotFile);
nativeFile = path.resolve(nativeFile);
const rawGodot = rows(rawGodotFile, config.raw.godotPrefix).map(normalizeRaw);
const rawNative = rows(nativeFile, config.raw.nativePrefix).map(normalizeRaw);
const workerGodot = rows(workerGodotFile, config.worker.godotPrefix).map((row, index) => normalizeWorker(row, index));
const workerNative = rows(nativeFile, config.worker.nativePrefix).map((row, index) => normalizeWorker(row, index));
if (rawGodot.length !== config.raw.expectedCases || rawNative.length !== config.raw.expectedCases) {
  throw new Error(`expected ${config.raw.expectedCases} raw rows, got Godot=${rawGodot.length} native=${rawNative.length}`);
}
if (workerGodot.length !== config.worker.expectedCases || workerNative.length !== config.worker.expectedCases) {
  throw new Error(`expected ${config.worker.expectedCases} worker rows, got Godot=${workerGodot.length} native=${workerNative.length}`);
}
for (let index = 0; index < rawGodot.length; index += 1) exact(`raw case ${index}`, rawGodot[index], rawNative[index]);
for (let index = 0; index < workerGodot.length; index += 1) exact(`worker case ${index}`, workerGodot[index], workerNative[index]);

const sourcesAfter = sourceFiles.map(fileReceipt);
if (JSON.stringify(sourcesBefore) !== JSON.stringify(sourcesAfter)) {
  throw new Error('oracle authority sources changed during differential run');
}
const report = {
  schema: 'native-tree-oracle-differential/v1', family: config.family, status: 'passed',
  rawCases: rawGodot.length, workerCases: workerGodot.length,
  rawBranchCheckpoints: rawGodot.reduce((sum, row) => sum + row.branchHashCheckpoints.length, 0),
  rawFoliageCheckpoints: rawGodot.reduce((sum, row) => sum + row.foliageHashCheckpoints.length, 0),
  compared: {raw: Object.keys(rawGodot[0]), worker: Object.keys(workerGodot[0])},
  floatingTolerance: 'absolute <= 1e-12 * max(1, |Godot|, |native|); all integer hashes/checkpoints/counts exact',
  execution, sources: sourcesBefore, sourceFreezeVerified: true,
  outputs: [rawGodotFile, workerGodotFile, nativeFile].map(fileReceipt),
};
fs.mkdirSync(path.dirname(outputFile), {recursive: true});
fs.writeFileSync(outputFile, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
console.log(JSON.stringify(report));

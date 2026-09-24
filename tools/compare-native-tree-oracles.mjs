#!/usr/bin/env node

import {execFileSync} from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {runOwnedProcess} from './lib/owned-process.mjs';
import {requireWorkerEvidenceContract} from './lib/native-tree-oracle-evidence.mjs';

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
  const normalized = {
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
  // Shadow compilers may source-bind exact scalar/RNG/budget projections while
  // deliberately omitting topology. Keep those extra facts in the shared
  // attestation shape only when both oracle families emit them.
  if (row.crownPhase !== undefined) normalized.crownPhase = Number(row.crownPhase);
  if (row.crownCenter !== undefined) normalized.crownCenter = normalizeVector(row.crownCenter);
  if (row.crownRadii !== undefined) normalized.crownRadii = normalizeVector(row.crownRadii);
  if (row.growthProfile !== undefined) normalized.growthProfile = normalizeVector(row.growthProfile);
  if (row.renderBudgets !== undefined) normalized.renderBudgets = normalizeVector(row.renderBudgets);
  return normalized;
}
function normalizeVector(value) {
  return (value ?? []).map(Number);
}
function normalizeBranch(value) {
  if (!value || Object.keys(value).length === 0) return {};
  return {
    start: normalizeVector(value.start), end: normalizeVector(value.end),
    radiusStart: Number(value.radiusStart), radiusEnd: Number(value.radiusEnd),
    order: Number(value.order), parentNode: Number(value.parentNode), childNode: Number(value.childNode),
    stratumBias: Number(value.stratumBias), windWeight: Number(value.windWeight),
  };
}
function normalizeFoliage(value) {
  if (!value || Object.keys(value).length === 0) return {};
  return {
    position: normalizeVector(value.position), rotation: normalizeVector(value.rotation),
    scale: normalizeVector(value.scale), windWeight: Number(value.windWeight),
    variation: Number(value.variation), exposure: Number(value.exposure),
    clusterVariant: Number(value.clusterVariant), sourceSegment: Number(value.sourceSegment),
    sourceOrder: Number(value.sourceOrder),
  };
}
function normalizeWorker(row, index) {
  const renderLod = row.renderLod ?? {}, collision = row.collision ?? {}, variation = row.case ?? {};
  const normalized = row.normalized ?? {}, policy = row.renderPolicy ?? {}, interaction = row.interaction ?? {};
  const review = Boolean(row.review ?? variation.presentation === 'review');
  return {
    caseIndex: Number(row.caseIndex ?? index),
    recipeIdentityKey: row.recipeIdentityKey, requestKey: row.requestKey,
    signature: row.signature, topologySignature: row.topologySignature,
    sourceBranches: Number(row.sourceBranches), sourceFoliage: Number(row.sourceFoliage),
    branches: Number(row.branches), foliage: Number(row.foliage),
    branchSelectionHash: Number(row.branchSelectionHash), foliageSelectionHash: Number(row.foliageSelectionHash),
    normalized: {
      treeId: normalized.treeId, worldSeed: normalized.worldSeed, biome: normalized.biome,
      architecture: normalized.architecture, speciesGrammar: normalized.speciesGrammar,
      ageBand: normalized.ageBand, ageYears: Number(normalized.ageYears),
      growthStage: Number(normalized.growthStage), geneticSeed: Number(normalized.geneticSeed),
      height: Number(normalized.height), trunkRadius: Number(normalized.trunkRadius),
      canopyRadius: Number(normalized.canopyRadius), canopyDensity: Number(normalized.canopyDensity),
    },
    renderTier: row.renderTier ?? renderLod.tier ?? variation.renderLodTier ?? 'near',
    branchBudget: review ? null : Number(row.branchBudget ?? renderLod.branchBudget ?? row.branches),
    foliageBudget: review ? null : Number(row.foliageBudget ?? renderLod.foliageBudget ?? row.foliage),
    impostor: Boolean(row.impostor ?? row.runtimeImpostor ?? renderLod.impostor),
    renderPolicy: {
      visibilityRange: Number(policy.visibilityRange ?? row.visibilityRange),
      shadowRange: Number(policy.shadowRange ?? row.shadowRange),
      windResponse: Number(policy.windResponse ?? row.windResponse),
      shadowPolicy: policy.shadowPolicy, lodTier: policy.lodTier,
    },
    runtimeContinuousBole: Boolean(row.runtimeContinuousBole),
    pocContinuousWood: Boolean(row.pocContinuousWood),
    continuousTrunkPath: Boolean(row.continuousTrunkPath),
    graphConnected: Boolean(row.graphConnected),
    foliageDerivedFromFineSegments: Boolean(row.foliageDerivedFromFineSegments),
    collisionRadius: Number(row.collisionRadius ?? collision.trunkRadius),
    collisionHeight: Number(row.collisionHeight ?? collision.trunkHeight),
    interaction: {
      treeId: interaction.treeId, worldPosition: normalizeVector(interaction.worldPosition),
      worldRotationY: Number(interaction.worldRotationY), rootButtressCount: Number(interaction.rootButtressCount),
    },
    crownHabit: row.crownHabit, methodology: row.methodology,
    firstBranch: normalizeBranch(row.firstBranch), firstFoliage: normalizeFoliage(row.firstFoliage),
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
async function runCaptured(executable, args, options, stdoutFile, stderrFile) {
  const summaryFile = stdoutFile.replace(/\.stdout\.log$/u, '.watchdog.json');
  const summary = await runOwnedProcess({
    executable, args, projectPath: options.cwd, env: options.env, timeoutSeconds: options.timeoutSeconds ?? 120,
    cleanupGraceMilliseconds: 2000, finalCleanupTimeoutMilliseconds: 30000,
    stdoutPath: stdoutFile, stderrPath: stderrFile, summaryPath: summaryFile,
  });
  const drained = summary.overallExitCode === 0 && summary.functionalExitCode === 0
    && summary.cleanupPassed && summary.authoritativeZeroProven
    && summary.finalMembershipKnown && summary.finalJobMemberPids.length === 0;
  if (!drained) throw new Error(`${executable} failed or did not prove zero owned members; inspect ${summaryFile}`);
  return {command: [executable, ...summary.args], exitCode: summary.functionalExitCode,
    stdout: fileReceipt(stdoutFile), stderr: fileReceipt(stderrFile), watchdog: fileReceipt(summaryFile),
    processDrain: {cleanupPassed: true, authoritativeZeroProven: true, finalJobMemberPids: []}};
}
function projectScript(project, uri) {
  if (!uri.startsWith('res://')) throw new Error(`oracle script is not a res:// URI: ${uri}`);
  return path.join(project, ...uri.slice(6).split('/'));
}

const outputFile = path.resolve(argument('--out'));
if (fs.existsSync(outputFile)) fs.unlinkSync(outputFile);
const configFile = path.resolve(argument('--config'));
const config = JSON.parse(fs.readFileSync(configFile, 'utf8'));
if (config.schema !== 'native-tree-oracle-attestation-config/v1') throw new Error('unsupported config schema');
const project = path.resolve(optionalArgument('--project') ?? '.');
let rawGodotFile = optionalArgument('--raw-godot');
let workerGodotFile = optionalArgument('--worker-godot');
let nativeFile = optionalArgument('--native');
let execution = null;
const sourceFiles = [projectScript(project, config.raw.godotScript), projectScript(project, config.worker.godotScript),
  ...config.authoritySources.map(file => path.join(project, ...file.split('/'))),
  ...config.nativeAuthoritySources.map(file => path.join(project, ...file.split('/'))),
  path.join(project, 'tools/lib/native-tree-oracle-evidence.mjs'),
  path.join(project, 'tools/lib/owned-process.mjs'), path.join(project, 'tools/lib/owned-native-host.mjs'),
  path.join(project, 'tools/lib/owned-live-clock.mjs'), path.join(project, 'tools/native/OwnedProcessNative.cs'),
  path.join(project, 'tools/native/OwnedProcessHost.cs'), configFile, scriptFile];
const sourcesBefore = sourceFiles.map(fileReceipt);
const commitBefore = execFileSync('git', ['rev-parse', 'HEAD'], {cwd: project, encoding: 'utf8'}).trim();
const statusBefore = execFileSync('git', ['status', '--short'], {cwd: project, encoding: 'utf8'}).trim();

if (process.argv.includes('--run')) {
  const outputDirectory = path.resolve(argument('--out-dir'));
  fs.mkdirSync(outputDirectory, {recursive: true});
  if (statusBefore) throw new Error('source-bound execution requires a clean committed worktree');
  const runDirectory = path.join(outputDirectory, `.tree-oracle-run-${crypto.randomUUID()}`);
  fs.mkdirSync(runDirectory, {recursive: false});
  const configuredGodot = optionalArgument('--godot') ?? process.env.GODOT4_CONSOLE;
  if (!configuredGodot) throw new Error('provide --godot or GODOT4_CONSOLE');
  const godot = path.resolve(configuredGodot);
  const nativeExecutable = path.resolve(argument('--native-exe'));
  rawGodotFile = path.join(runDirectory, 'raw-godot.stdout.log');
  workerGodotFile = path.join(runDirectory, 'worker-godot.stdout.log');
  nativeFile = path.join(runDirectory, 'native.stdout.log');
  const audioEnvironment = {...process.env, VOXEL_DISABLE_AUDIO_PLAYBACK: '1'};
  const rawRun = await runCaptured(godot,
    ['--headless', '--audio-driver', 'Dummy', '--path', project, '--script', config.raw.godotScript],
    {cwd: project, env: audioEnvironment}, rawGodotFile, path.join(runDirectory, 'raw-godot.stderr.log'));
  const workerRun = await runCaptured(godot,
    ['--headless', '--audio-driver', 'Dummy', '--path', project, '--script', config.worker.godotScript],
    {cwd: project, env: audioEnvironment}, workerGodotFile, path.join(runDirectory, 'worker-godot.stderr.log'));
  const nativeRun = await runCaptured(nativeExecutable, [],
    {cwd: project, env: {...process.env, [config.nativeEnvironment]: '1'}},
    nativeFile, path.join(runDirectory, 'native.stderr.log'));
  const versionFile = path.join(runDirectory, 'godot-version.stdout.log');
  const versionRun = await runCaptured(godot, ['--version'], {cwd: project, env: audioEnvironment},
    versionFile, path.join(runDirectory, 'godot-version.stderr.log'));
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
requireWorkerEvidenceContract(workerGodot, config.worker.evidenceContract, 'Godot');
requireWorkerEvidenceContract(workerNative, config.worker.evidenceContract, 'native');
for (let index = 0; index < rawGodot.length; index += 1) exact(`raw case ${index}`, rawGodot[index], rawNative[index]);
for (let index = 0; index < workerGodot.length; index += 1) exact(`worker case ${index}`, workerGodot[index], workerNative[index]);

const sourcesAfter = sourceFiles.map(fileReceipt);
if (JSON.stringify(sourcesBefore) !== JSON.stringify(sourcesAfter)) {
  throw new Error('oracle authority sources changed during differential run');
}
const commitAfter = execFileSync('git', ['rev-parse', 'HEAD'], {cwd: project, encoding: 'utf8'}).trim();
const statusAfter = execFileSync('git', ['status', '--short'], {cwd: project, encoding: 'utf8'}).trim();
if (commitAfter !== commitBefore || statusAfter !== statusBefore) {
  throw new Error('git commit or tracked worktree state changed during differential run');
}
const report = {
  schema: 'native-tree-oracle-differential/v1', family: config.family, status: 'passed',
  rawCases: rawGodot.length, workerCases: workerGodot.length,
  rawBranchCheckpoints: rawGodot.reduce((sum, row) => sum + row.branchHashCheckpoints.length, 0),
  rawFoliageCheckpoints: rawGodot.reduce((sum, row) => sum + row.foliageHashCheckpoints.length, 0),
  compared: {raw: Object.keys(rawGodot[0]), worker: Object.keys(workerGodot[0])},
  floatingTolerance: 'absolute <= 1e-12 * max(1, |Godot|, |native|); all integer hashes/checkpoints/counts exact',
  execution, sources: sourcesBefore, sourceFreezeVerified: true,
  git: {commitSha: commitBefore, clean: statusBefore.length === 0},
  outputs: [rawGodotFile, workerGodotFile, nativeFile].map(fileReceipt),
};
fs.mkdirSync(path.dirname(outputFile), {recursive: true});
const temporaryReport = `${outputFile}.${crypto.randomUUID()}.tmp`;
try {
  fs.writeFileSync(temporaryReport, `${JSON.stringify(report, null, 2)}\n`, {encoding: 'utf8', flag: 'wx', flush: true});
  fs.renameSync(temporaryReport, outputFile);
} finally {
  if (fs.existsSync(temporaryReport)) fs.unlinkSync(temporaryReport);
}
console.log(JSON.stringify(report));

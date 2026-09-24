#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { access, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { dirname, isAbsolute, relative, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { findGodot, parseArguments } from './lib/voxel-tool-runtime.mjs';
import { runGodotProcess } from './lib/godot-process.mjs';
import { runOwnedProcess } from './lib/owned-process.mjs';

const project = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const parsed = parseArguments(process.argv.slice(2));
const configured = String(parsed.options.reportPath
  ?? 'artifacts/native-world-backend/n3-surface-deformation-godot-oracle/report.json');
const reportPath = isAbsolute(configured) ? configured : resolve(project, configured);
const receiptPath = resolve(dirname(reportPath), 'receipt.json');
const nativeReportPath = resolve(dirname(reportPath), 'native-observations.json');
const nativeSummaryPath = resolve(dirname(reportPath), 'native-owned-summary.json');
const nativeStdoutPath = resolve(dirname(reportPath), 'native-stdout.log');
const nativeStderrPath = resolve(dirname(reportPath), 'native-stderr.log');
await mkdir(dirname(reportPath), { recursive: true });
for (const path of [reportPath, receiptPath, nativeReportPath, nativeSummaryPath,
  nativeStdoutPath, nativeStderrPath]) await rm(path, { force: true });

const sources = [
  resolve(project, 'scripts/testing/native_world/N3NativeTerrainSurfaceDeformationOracleContract.gd'),
  resolve(project, 'native/world_backend/tests/native_terrain_edit_shape_compiler_tests.cpp'),
  resolve(project, 'native/world_backend/tests/test_harness.hpp'),
  resolve(project, 'native/world_backend/tests/test_main.cpp'),
  resolve(project, 'native/world_backend/core/native_terrain_edit_shape_compiler.cpp'),
  resolve(project, 'native/world_backend/core/native_terrain_edit_shape_compiler.hpp'),
  resolve(project, 'tools/lib/godot-process.mjs'),
  resolve(project, 'tools/lib/owned-process.mjs'),
  resolve(project, 'tools/lib/voxel-tool-runtime.mjs'),
  resolve(project, 'tools/run-godot-scene-watchdog.mjs'),
  fileURLToPath(import.meta.url),
];
const record = async path => ({
  path: relative(project, path).replaceAll('\\', '/'),
  bytes: (await stat(path)).size,
  sha256: createHash('sha256').update(await readFile(path)).digest('hex'),
});
const sourceInputs = await Promise.all(sources.map(record));
const commit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: project, encoding: 'utf8' }).trim();
const branch = execFileSync('git', ['branch', '--show-current'], { cwd: project, encoding: 'utf8' }).trim();
const statusBefore = execFileSync('git', ['status', '--short'], { cwd: project, encoding: 'utf8' }).trim();
const allowDirtyDevelopment = process.argv.includes('--allow-dirty-development');
if (statusBefore && !allowDirtyDevelopment) throw new Error('oracle receipt requires a clean worktree');
const godot = await findGodot(parsed.options.godotExe);
if (!parsed.options.nativeExe) throw new Error('Pass --native-exe PATH from a focused native receipt');
if (!parsed.options.nativeReceipt) throw new Error('Pass --native-receipt PATH from the same focused native build');
const nativeExe = isAbsolute(String(parsed.options.nativeExe))
  ? String(parsed.options.nativeExe) : resolve(project, String(parsed.options.nativeExe));
const nativeReceiptPath = isAbsolute(String(parsed.options.nativeReceipt))
  ? String(parsed.options.nativeReceipt) : resolve(project, String(parsed.options.nativeReceipt));
await access(nativeExe, fsConstants.F_OK);
await access(nativeReceiptPath, fsConstants.F_OK);
const nativeExeBefore = await record(nativeExe);
const nativeBuildReceiptRecord = await record(nativeReceiptPath);
const nativeBuildReceipt = JSON.parse(await readFile(nativeReceiptPath, 'utf8'));
if (nativeBuildReceipt.status !== 'passed') throw new Error('native focused receipt is not passed');
const engineCandidate = godot.replace(/_console\.exe$/i, '.exe');
const godotExecutables = [...new Set([godot, engineCandidate])];
for (const executable of godotExecutables) await access(executable, fsConstants.F_OK);
const godotBefore = await Promise.all(godotExecutables.map(record));
const execution = await runGodotProcess(godot, [
  '--headless', '--path', project,
  '--script', 'res://scripts/testing/native_world/N3NativeTerrainSurfaceDeformationOracleContract.gd',
], {
  env: { ...process.env, VOXEL_DISABLE_AUDIO_PLAYBACK: '1', N3_SURFACE_DEFORMATION_ORACLE_REPORT: reportPath },
  timeoutSeconds: Number(parsed.options.timeoutSeconds ?? 120),
});
const nativeExecution = await runOwnedProcess({
  executable: nativeExe,
  args: [],
  projectPath: project,
  env: {
    ...process.env,
    VOXEL_DISABLE_AUDIO_PLAYBACK: '1',
    N3_NATIVE_SURFACE_DEFORMATION_OBSERVATION_REPORT: nativeReportPath,
  },
  timeoutSeconds: Number(parsed.options.timeoutSeconds ?? 120),
  stdoutPath: nativeStdoutPath,
  stderrPath: nativeStderrPath,
  summaryPath: nativeSummaryPath,
});
await access(reportPath, fsConstants.F_OK);
await access(nativeReportPath, fsConstants.F_OK);
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const nativeReport = JSON.parse(await readFile(nativeReportPath, 'utf8'));
const canonical = value => {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value !== null && typeof value === 'object') return '{' + Object.keys(value).sort()
    .map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  return JSON.stringify(value);
};
const digest = value => createHash('sha256').update(canonical(value)).digest('hex');
const compare = (native, godot) => ({
  schema: native.schema === 'n3-native-terrain-surface-deformation-observations/v1'
    && godot.schema === 'n3-native-terrain-surface-deformation-oracle/v1',
  exactFields: canonical(native.observations) === canonical(godot.observations),
  nativeHashSelfConsistent: native.observationsSha256 === digest(native.observations),
  godotHashSelfConsistent: godot.observationsSha256 === digest(godot.observations),
  exactHash: native.observationsSha256 === godot.observationsSha256,
});
const comparison = compare(nativeReport, report);
const mismatchedSchema = structuredClone(nativeReport);
mismatchedSchema.schema = 'wrong/v0';
const mismatchedHash = structuredClone(nativeReport);
mismatchedHash.observationsSha256 = '0'.repeat(64);
const negativeComparisonTests = {
  schemaMismatchRejected: !compare(mismatchedSchema, report).schema,
  hashMismatchRejected: !compare(mismatchedHash, report).nativeHashSelfConsistent
    && !compare(mismatchedHash, report).exactHash,
};
const sourcesAfter = await Promise.all(sources.map(record));
const godotAfter = await Promise.all(godotExecutables.map(record));
const statusAfter = execFileSync('git', ['status', '--short'], { cwd: project, encoding: 'utf8' }).trim();
const nativeExeAfter = await record(nativeExe);
const audioPolicy = {
  godotDummyDriver: execution.summary?.args?.[0] === '--audio-driver'
    && execution.summary?.args?.[1] === 'Dummy',
  disableAudioPlaybackEnvironment: true,
};
const comparisonPassed = Object.values(comparison).every(Boolean)
  && Object.values(negativeComparisonTests).every(Boolean);
const outputRecords = await Promise.all([reportPath, nativeReportPath, nativeSummaryPath,
  nativeStdoutPath, nativeStderrPath].map(record));
const receipt = {
  schema: 'n3-native-terrain-surface-deformation-oracle-receipt/v1',
  status: execution.code === 0 && execution.summary?.authoritativeZeroProven
    && execution.summary?.cleanupPassed && audioPolicy.godotDummyDriver && report.passed
    && nativeExecution.overallExitCode === 0 && nativeExecution.authoritativeZeroProven
    && nativeExecution.cleanupPassed && nativeReport.passed && nativeReport.compilerCases === 6
    && comparisonPassed ? 'passed' : 'failed',
  evidenceClass: statusBefore ? 'development-diagnostic-dirty-source' : 'clean-source-attested',
  source: { commit, branch, status: statusBefore, inputs: sourceInputs },
  tools: {
    godotExecutables: godotBefore,
    nativeExecutable: nativeExeBefore,
    nativeBuildReceipt: nativeBuildReceiptRecord,
    nativeBuildToolchain: nativeBuildReceipt.tools,
  },
  audioPolicy,
  nativeExpectedContract: sourceInputs.find(input =>
    input.path === 'native/world_backend/tests/native_terrain_edit_shape_compiler_tests.cpp'),
  execution,
  nativeExecution,
  report,
  nativeReport,
  comparison,
  negativeComparisonTests,
  outputs: outputRecords,
  unchanged: statusAfter === statusBefore
    && JSON.stringify(sourcesAfter) === JSON.stringify(sourceInputs)
    && JSON.stringify(godotAfter) === JSON.stringify(godotBefore),
};
receipt.unchanged = receipt.unchanged && JSON.stringify(nativeExeAfter) === JSON.stringify(nativeExeBefore);
if (!receipt.unchanged) receipt.status = 'failed';
await writeFile(receiptPath, JSON.stringify(receipt, null, 2) + '\n');
process.stdout.write(JSON.stringify({ status: receipt.status, reportPath, receiptPath }, null, 2) + '\n');
if (receipt.status !== 'passed') process.exitCode = 1;

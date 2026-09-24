#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { access, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { dirname, isAbsolute, relative, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { findGodot, parseArguments } from './lib/voxel-tool-runtime.mjs';
import { runGodotProcess } from './lib/godot-process.mjs';

const project = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const parsed = parseArguments(process.argv.slice(2));
const configured = String(parsed.options.reportPath
  ?? 'artifacts/native-world-backend/n3-surface-deformation-godot-oracle/report.json');
const reportPath = isAbsolute(configured) ? configured : resolve(project, configured);
const receiptPath = resolve(dirname(reportPath), 'receipt.json');
await mkdir(dirname(reportPath), { recursive: true });
await rm(reportPath, { force: true });
await rm(receiptPath, { force: true });

const sources = [
  resolve(project, 'scripts/testing/native_world/N3NativeTerrainSurfaceDeformationOracleContract.gd'),
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
const execution = await runGodotProcess(godot, [
  '--headless', '--path', project,
  '--script', 'res://scripts/testing/native_world/N3NativeTerrainSurfaceDeformationOracleContract.gd',
], {
  env: { ...process.env, VOXEL_DISABLE_AUDIO_PLAYBACK: '1', N3_SURFACE_DEFORMATION_ORACLE_REPORT: reportPath },
  timeoutSeconds: Number(parsed.options.timeoutSeconds ?? 120),
});
await access(reportPath, fsConstants.F_OK);
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const sourcesAfter = await Promise.all(sources.map(record));
const statusAfter = execFileSync('git', ['status', '--short'], { cwd: project, encoding: 'utf8' }).trim();
const receipt = {
  schema: 'n3-native-terrain-surface-deformation-oracle-receipt/v1',
  status: execution.code === 0 && report.passed ? 'passed' : 'failed',
  evidenceClass: statusBefore ? 'development-diagnostic-dirty-source' : 'clean-source-attested',
  source: { commit, branch, status: statusBefore, inputs: sourceInputs },
  execution,
  report,
  unchanged: statusAfter === statusBefore && JSON.stringify(sourcesAfter) === JSON.stringify(sourceInputs),
};
if (!receipt.unchanged) receipt.status = 'failed';
await writeFile(receiptPath, JSON.stringify(receipt, null, 2) + '\n');
process.stdout.write(JSON.stringify({ status: receipt.status, reportPath, receiptPath }, null, 2) + '\n');
if (receipt.status !== 'passed') process.exitCode = 1;

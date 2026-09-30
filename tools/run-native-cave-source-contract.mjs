#!/usr/bin/env node

import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { findGodot, parseArguments, projectRoot, timestamp } from './lib/voxel-tool-runtime.mjs';
import { runOwnedProcess } from './lib/owned-process.mjs';

const { options } = parseArguments(process.argv.slice(2));
if (options.help) {
  process.stdout.write(`Usage: node tools/run-native-cave-source-contract.mjs [options]

Compares a working GDScript cave recipe with native effective-terrain samples.
This is an adapter contract, not headed gameplay acceptance.

  --godot-exe PATH      Godot console executable (or GODOT_EXE)
  --output-dir PATH     New output directory (must not already exist)
  --timeout-seconds N   Owned Godot process deadline (default 60)
`);
  process.exit(0);
}

const timeoutSeconds = Number(options.timeoutSeconds ?? 60);
if (!Number.isInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 300) {
  throw new Error('--timeout-seconds must be an integer from 1 through 300');
}
const runId = randomUUID().replaceAll('-', '').slice(0, 10);
const outputDirectory = path.resolve(options.outputDir ?? path.join(projectRoot, 'artifacts',
  'native-world-backend', `native-cave-source-${timestamp().replace(/[:.]/g, '-')}-${runId}`));
await mkdir(path.dirname(outputDirectory), { recursive: true });
await mkdir(outputDirectory, { recursive: false });

const godot = await findGodot(options.godotExe);
const nativeExtensionPath = path.join(projectRoot,
  'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll');
const nativeManifestPath = path.join(projectRoot, 'native/world_backend/source-manifest.json');
const nativeExtensionBytes = await readFile(nativeExtensionPath);
const nativeManifestBytes = await readFile(nativeManifestPath);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const reportPath = path.join(outputDirectory, 'report.json');
const processSummary = await runOwnedProcess({
  projectPath: projectRoot,
  executable: godot,
  args: ['--headless', '--audio-driver', 'Dummy', '--path', projectRoot,
    '--script', 'res://scripts/testing/native_world/NativeCaveSourceContractRunner.gd'],
  env: { ...process.env, NATIVE_CAVE_SOURCE_REPORT: reportPath.replaceAll('\\', '/') },
  timeoutSeconds,
  stdoutPath: path.join(outputDirectory, 'godot.stdout.log'),
  stderrPath: path.join(outputDirectory, 'godot.stderr.log'),
  summaryPath: path.join(outputDirectory, 'godot.watchdog.json'),
});

let report = null;
try {
  report = JSON.parse(await readFile(reportPath, 'utf8'));
} catch (error) {
  throw new Error(`Native cave contract did not publish a readable report at ${reportPath}: ${error.message}`);
}
const passed = processSummary.functionalExitCode === 0
  && processSummary.cleanupPassed === true
  && processSummary.authoritativeZeroProven === true
  && report.passed === true;
const receipt = {
  schema: 'native-cave-source-contract-receipt/v1',
  status: passed ? 'passed' : 'failed',
  evidenceLevel: report.evidenceLevel,
  reportPath,
  godot,
  process: {
    functionalExitCode: processSummary.functionalExitCode,
    timedOut: processSummary.timedOut,
    cleanupPassed: processSummary.cleanupPassed,
    authoritativeZeroProven: processSummary.authoritativeZeroProven,
    finalJobMemberPids: processSummary.finalJobMemberPids,
  },
  nativeExtension: {
    path: nativeExtensionPath,
    bytes: nativeExtensionBytes.length,
    sha256: hash(nativeExtensionBytes),
  },
  nativeSourceManifest: {
    path: nativeManifestPath,
    bytes: nativeManifestBytes.length,
    sha256: hash(nativeManifestBytes),
  },
  limitations: report.doesNotProve,
};
const receiptPath = path.join(outputDirectory, 'receipt.json');
await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, { flag: 'wx' });
process.stdout.write(`${JSON.stringify({ status: receipt.status, reportPath, receiptPath,
  failures: report.failures, recipeRegion: report.evidence?.recipeRegion,
  nativePages: Object.keys(report.evidence?.nativePages ?? {}).length,
  cleanupPassed: receipt.process.cleanupPassed,
  authoritativeZeroProven: receipt.process.authoritativeZeroProven }, null, 2)}\n`);
if (!passed) process.exitCode = 1;

#!/usr/bin/env node

import { randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { findGodot, parseArguments, projectRoot, timestamp } from './lib/voxel-tool-runtime.mjs';
import { runOwnedProcess } from './lib/owned-process.mjs';

const { options } = parseArguments(process.argv.slice(2));
if (options.help) {
  process.stdout.write(`Usage: node tools/run-cave-generation-contract.mjs [options]

Runs deterministic native/oracle cave generation parity and real-volume route
contracts. This is a focused generator contract, not live gameplay acceptance.

  --godot-exe PATH      Godot console executable (or GODOT_EXE)
  --output-dir PATH     New output directory (must not already exist)
  --timeout-seconds N   Owned Godot process deadline (default 180)
  --seed VALUE          Run one seed instead of the fixed five-seed sample
  --region X,Z          Run one region only
  --verify-primary      Prove primary-center behavior and fallback gating
`);
  process.exit(0);
}

const timeoutSeconds = Number(options.timeoutSeconds ?? 180);
if (!Number.isInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 600)
  throw new Error('--timeout-seconds must be an integer from 1 through 600');
if (options.region !== undefined && !/^-?\d+,-?\d+$/.test(String(options.region)))
  throw new Error('--region must be two comma-separated integers, X,Z');

const runId = randomUUID().replaceAll('-', '').slice(0, 10);
const outputDirectory = path.resolve(options.outputDir ?? path.join(projectRoot, 'artifacts', 'caves',
  `generation-contract-${timestamp().replace(/[:.]/g, '-')}-${runId}`));
await mkdir(path.dirname(outputDirectory), { recursive: true });
await mkdir(outputDirectory, { recursive: false });

const godot = await findGodot(options.godotExe);
const reportPath = path.join(outputDirectory, 'report.json');
const environment = {
  ...process.env,
  CAVE_CONTRACT_REPORT: reportPath.replaceAll('\\', '/'),
};
if (options.seed !== undefined) environment.CAVE_CONTRACT_SEED = String(options.seed);
if (options.region !== undefined) environment.CAVE_CONTRACT_REGION = String(options.region);
if (options.verifyPrimary) environment.CAVE_CONTRACT_VERIFY_PRIMARY = '1';

const wallStartedAt = Date.now();
const processSummary = await runOwnedProcess({
  projectPath: projectRoot,
  executable: godot,
  args: ['--headless', '--audio-driver', 'Dummy', '--path', projectRoot,
    '--script', 'res://scripts/testing/terrain/CaveGenerationContractRunner.gd'],
  env: environment,
  timeoutSeconds,
  stdoutPath: path.join(outputDirectory, 'godot.stdout.log'),
  stderrPath: path.join(outputDirectory, 'godot.stderr.log'),
  summaryPath: path.join(outputDirectory, 'godot.watchdog.json'),
});

let report;
try {
  report = JSON.parse(await readFile(reportPath, 'utf8'));
} catch (error) {
  throw new Error(`Cave generation contract did not publish a readable report at ${reportPath}: ${error.message}`);
}
const passed = processSummary.functionalExitCode === 0
  && processSummary.cleanupPassed === true
  && processSummary.authoritativeZeroProven === true
  && report.evidenceLevel === 'contract'
  && report.liveGameplayAcceptance === false
  && report.passed === true
  && Array.isArray(report.results)
  && report.results.length > 0
  && report.results.every(row => row.passed === true);
const receipt = {
  schema: 'cave-generation-contract-receipt/v1',
  status: passed ? 'passed' : 'failed',
  reportPath,
  godot,
  process: {
    functionalExitCode: processSummary.functionalExitCode,
    elapsedMilliseconds: Date.now() - wallStartedAt,
    timedOut: processSummary.timedOut,
    cleanupPassed: processSummary.cleanupPassed,
    authoritativeZeroProven: processSummary.authoritativeZeroProven,
    finalJobMemberPids: processSummary.finalJobMemberPids,
  },
  seeds: report.results.map(row => ({
    seed: row.seed,
    passed: row.passed,
    sampled: row.regionsSampled,
    substantial: row.substantialRecipes,
    allSampledPrevalence: row.allSampledPrevalence,
    proposalConditionedAcceptanceRate: row.proposalConditionedAcceptanceRate,
    failures: row.failures,
  })),
};
const receiptPath = path.join(outputDirectory, 'receipt.json');
await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, { flag: 'wx' });
process.stdout.write(`${JSON.stringify({ ...receipt, receiptPath }, null, 2)}\n`);
if (!passed) process.exitCode = 1;

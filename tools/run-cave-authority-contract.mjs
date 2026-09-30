#!/usr/bin/env node

import { randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { findGodot, parseArguments, projectRoot, timestamp } from './lib/voxel-tool-runtime.mjs';
import { runOwnedProcess } from './lib/owned-process.mjs';

const { options } = parseArguments(process.argv.slice(2));
if (options.help) {
  process.stdout.write(`Usage: node tools/run-cave-authority-contract.mjs [options]

Checks generated cave block parity, deterministic deep air/rock, and durable
dig/save/reload behavior. This is a service contract, not live gameplay proof.

  --godot-exe PATH      Godot console executable (or GODOT_EXE)
  --output-dir PATH     New output directory (must not already exist)
  --timeout-seconds N   Owned Godot process deadline (default 180)
`);
  process.exit(0);
}

const timeoutSeconds = Number(options.timeoutSeconds ?? 180);
if (!Number.isInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 900) {
  throw new Error('--timeout-seconds must be an integer from 1 through 900');
}
const runId = randomUUID().replaceAll('-', '').slice(0, 10);
const outputDirectory = path.resolve(options.outputDir ?? path.join(projectRoot, 'artifacts', 'caves',
  `authority-contract-${timestamp().replace(/[:.]/g, '-')}-${runId}`));
await mkdir(path.dirname(outputDirectory), { recursive: true });
await mkdir(outputDirectory, { recursive: false });

const godot = await findGodot(options.godotExe);
const reportPath = path.join(outputDirectory, 'report.json');
const processSummary = await runOwnedProcess({
  projectPath: projectRoot,
  executable: godot,
  args: ['--headless', '--audio-driver', 'Dummy', '--path', projectRoot,
    '--script', 'res://scripts/testing/terrain/CaveAuthorityContractRunner.gd'],
  env: { ...process.env, CAVE_AUTHORITY_REPORT: reportPath.replaceAll('\\', '/') },
  timeoutSeconds,
  stdoutPath: path.join(outputDirectory, 'godot.stdout.log'),
  stderrPath: path.join(outputDirectory, 'godot.stderr.log'),
  summaryPath: path.join(outputDirectory, 'godot.watchdog.json'),
});

let report;
try {
  report = JSON.parse(await readFile(reportPath, 'utf8'));
} catch (error) {
  throw new Error(`Cave authority contract did not publish a readable report at ${reportPath}: ${error.message}`);
}
const passed = processSummary.functionalExitCode === 0
  && processSummary.cleanupPassed === true
  && processSummary.authoritativeZeroProven === true
  && report.evidenceLevel === 'contract_service'
  && report.passed === true
  && Array.isArray(report.results)
  && report.results.length === 4
  && report.results.every(row => row.passed === true);
const receipt = {
  schema: 'cave-authority-contract-receipt/v1',
  status: passed ? 'passed' : 'failed',
  evidenceLevel: report.evidenceLevel,
  liveGameplayAcceptance: false,
  reportPath,
  godot,
  process: {
    functionalExitCode: processSummary.functionalExitCode,
    timedOut: processSummary.timedOut,
    cleanupPassed: processSummary.cleanupPassed,
    authoritativeZeroProven: processSummary.authoritativeZeroProven,
    finalJobMemberPids: processSummary.finalJobMemberPids,
  },
  seeds: report.results.map(row => ({ seed: row.seed, passed: row.passed, failures: row.failures })),
};
const receiptPath = path.join(outputDirectory, 'receipt.json');
await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, { flag: 'wx' });
process.stdout.write(`${JSON.stringify({ ...receipt, receiptPath }, null, 2)}\n`);
if (!passed) process.exitCode = 1;

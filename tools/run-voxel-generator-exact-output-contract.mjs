#!/usr/bin/env node

import { randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { findGodot, parseArguments, projectRoot, timestamp } from './lib/voxel-tool-runtime.mjs';
import { runOwnedProcess } from './lib/owned-process.mjs';

const { options } = parseArguments(process.argv.slice(2));
if (options.help) {
  process.stdout.write('Usage: node tools/run-voxel-generator-exact-output-contract.mjs [--output-dir PATH] [--godot-exe PATH] [--timeout-seconds N]\n');
  process.exit(0);
}
const timeoutSeconds = Number(options.timeoutSeconds ?? 90);
if (!Number.isInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 900) {
  throw new Error('--timeout-seconds must be an integer from 1 through 900');
}
const suffix = `${timestamp().replace(/[:.]/g, '-')}-${randomUUID().slice(0, 8)}`;
const outputDirectory = path.resolve(options.outputDir ?? path.join(projectRoot,
  'artifacts', 'terrain', `voxel-generator-exact-output-${suffix}`));
await mkdir(path.dirname(outputDirectory), { recursive: true });
await mkdir(outputDirectory, { recursive: false });
const reportPath = path.join(outputDirectory, 'report.json');
const processSummary = await runOwnedProcess({
  projectPath: projectRoot,
  executable: await findGodot(options.godotExe),
  args: ['--headless', '--audio-driver', 'Dummy', '--path', projectRoot,
    '--script', 'res://scripts/testing/terrain/VoxelGeneratorExactOutputContractRunner.gd'],
  env: { ...process.env, VOXEL_GENERATOR_EXACT_OUTPUT_REPORT: reportPath.replaceAll('\\', '/') },
  timeoutSeconds,
  stdoutPath: path.join(outputDirectory, 'godot.stdout.log'),
  stderrPath: path.join(outputDirectory, 'godot.stderr.log'),
  summaryPath: path.join(outputDirectory, 'godot.watchdog.json'),
});
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const passed = processSummary.functionalExitCode === 0
  && processSummary.cleanupPassed === true
  && processSummary.authoritativeZeroProven === true
  && report.schema === 'voxel-generator-exact-output-contract/v1'
  && report.complete === true && report.passed === true
  && Array.isArray(report.blocks) && report.blocks.length === 9
  && report.blocks.every(block => block.passed && block.voxels === 4096 && block.savedEditVoxels === 2);
const receipt = {
  schema: 'voxel-generator-exact-output-receipt/v1',
  status: passed ? 'passed' : 'failed',
  evidenceLevel: 'synthetic_service_contract',
  reportPath,
  process: {
    functionalExitCode: processSummary.functionalExitCode,
    timedOut: processSummary.timedOut,
    cleanupPassed: processSummary.cleanupPassed,
    authoritativeZeroProven: processSummary.authoritativeZeroProven,
    finalJobMemberPids: processSummary.finalJobMemberPids,
  },
  blocks: report.blocks.map(block => ({ seed: block.seed, block: block.block,
    mismatchCount: block.mismatchCount, workerUsec: block.workerUsec,
    referenceUsec: block.referenceUsec })),
};
const receiptPath = path.join(outputDirectory, 'receipt.json');
await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, { flag: 'wx' });
process.stdout.write(`${JSON.stringify({ ...receipt, receiptPath }, null, 2)}\n`);
if (!passed) process.exitCode = 1;

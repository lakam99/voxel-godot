#!/usr/bin/env node

import { randomUUID } from 'node:crypto';
import { mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { findGodot, parseArguments, projectRoot, timestamp } from './lib/voxel-tool-runtime.mjs';
import { runGodotProcess } from './lib/godot-process.mjs';

const { options } = parseArguments(process.argv.slice(2));
if (options.help) {
  process.stdout.write('Usage: node tools/run-native-cave-footprint-contract.mjs [--output-dir PATH] [--godot-exe PATH]\n');
  process.exit(0);
}
const outputDir = path.resolve(options.outputDir ?? path.join(projectRoot, 'artifacts', 'caves',
  `native-footprint-${timestamp().replace(/[:.]/g, '-')}-${randomUUID().slice(0, 8)}`));
await mkdir(outputDir, { recursive: false });
const reportPath = path.join(outputDir, 'report.json');
const result = await runGodotProcess(await findGodot(options.godotExe),
  ['--headless', '--path', projectRoot, '--script',
    'res://scripts/testing/terrain/NativeCaveFootprintContractRunner.gd'],
  { cwd: projectRoot, timeoutSeconds: 180,
    env: { ...process.env, NATIVE_CAVE_FOOTPRINT_REPORT: reportPath } });
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const passed = result.code === 0 && report.passed === true;
process.stdout.write(`${JSON.stringify({ status: passed ? 'passed' : 'failed', reportPath,
  watchdogPath: result.summaryPath, positiveQueries: report.positiveQueries,
  negativeQueries: report.negativeQueries, failures: report.failures }, null, 2)}\n`);
if (!passed) process.exitCode = 1;

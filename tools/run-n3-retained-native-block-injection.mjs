#!/usr/bin/env node

import { mkdir, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const output = join(project, 'artifacts', 'native-world-backend',
  `n3-retained-native-block-${Date.now()}-${randomUUID().slice(0, 8)}`);
const reportPath = join(output, 'report.json');
const screenshotPath = join(output, 'headed-terrain.png');
await mkdir(output, { recursive: true });
const execution = await runGodotProcess(await findGodot(), [
  '--audio-driver', 'Dummy', '--path', project, '--script',
  'res://scripts/testing/native_world/N3RetainedNativeBlockInjectionFixture.gd',
], {
  cwd: project,
  timeoutSeconds: 180,
  reportPath,
  env: { ...process.env, VWB_RETAINED_BLOCK_REPORT: reportPath,
    VWB_RETAINED_BLOCK_SCREENSHOT: screenshotPath },
});
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const screenshot = await stat(screenshotPath);
const passed = execution.code === 0 && report.passed === true && screenshot.size > 1000;
process.stdout.write(`${JSON.stringify({ status: passed ? 'passed' : 'failed',
  reportPath, screenshotPath, ownedProcessPath: execution.summaryPath,
  engineExitCode: execution.code, reportPassed: report.passed }, null, 2)}\n`);
process.exitCode = passed ? 0 : 1;

#!/usr/bin/env node

import { mkdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const advance = process.argv.includes('--advance');
const output = join(project, 'artifacts', 'native-world-backend',
  `n3-shaping-page-admission-${Date.now()}-${randomUUID().slice(0, 8)}`);
const reportPath = join(output, 'report.json');
await mkdir(output, { recursive: true });
const execution = await runGodotProcess(await findGodot(), [
  '--headless', '--audio-driver', 'Dummy', '--path', project, '--script',
  'res://scripts/testing/native_world/N3NativeShapingPageAdmissionContract.gd',
], {
  cwd: project,
  timeoutSeconds: 45,
  reportPath,
  env: { ...process.env, VWB_SHAPING_BRIDGE_REPORT: reportPath,
    VWB_SHAPING_ADVANCE: advance ? '1' : '0' },
});
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const passed = execution.code === 0 && report.passed === true;
process.stdout.write(`${JSON.stringify({ status: passed ? 'passed' : 'failed',
  reportPath, ownedProcessPath: execution.summaryPath,
  engineExitCode: execution.code, report }, null, 2)}\n`);
process.exitCode = passed ? 0 : 1;

#!/usr/bin/env node

import { mkdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const output = join(project, 'artifacts', 'native-world-backend',
  `n3-native-terrain-publisher-${Date.now()}-${randomUUID().slice(0, 8)}`);
const reportPath = join(output, 'report.json');
await mkdir(output, { recursive: true });
const execution = await runGodotProcess(await findGodot(), [
  '--audio-driver', 'Dummy', '--path', project, '--script',
  'res://scripts/testing/native_world/N3NativeTerrainBlockPublisherFixture.gd',
], { cwd: project, timeoutSeconds: 150, reportPath,
  env: { ...process.env, VWB_PUBLISHER_REPORT: reportPath } });
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const passed = execution.code === 0 && report.passed === true;
process.stdout.write(`${JSON.stringify({ status: passed ? 'passed' : 'failed',
  reportPath, ownedProcessPath: execution.summaryPath,
  engineExitCode: execution.code, reportPassed: report.passed }, null, 2)}\n`);
process.exitCode = passed ? 0 : 1;

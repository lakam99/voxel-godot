#!/usr/bin/env node

import { mkdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const output = join(project, 'artifacts', 'native-world-backend',
  `n3-n5-windowed-physical-${Date.now()}-${randomUUID().slice(0, 8)}`);
const reportPath = join(output, 'report.json');
await mkdir(output, { recursive: true });
const execution = await runGodotProcess(await findGodot(), [
  '--audio-driver', 'Dummy', '--path', project, '--script',
  'res://scripts/testing/native_world/N3N5WindowedPhysicalFixture.gd',
], {
  cwd: project,
  // This isolated worktree may have a cold Godot import cache. Bound one
  // focused fixture generously enough for project bootstrap, while retaining
  // an explicit shorter active-work deadline.
  timeoutSeconds: 360,
  workTimeoutSeconds: 300,
  reportPath,
  env: { ...process.env, N3_N5_WINDOWED_PHYSICAL_REPORT: reportPath },
});
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const passed = execution.code === 0 && report.passed === true;
process.stdout.write(`${JSON.stringify({ status: passed ? 'passed' : 'failed',
  reportPath, ownedProcessPath: execution.summaryPath,
  engineExitCode: execution.code, report }, null, 2)}\n`);
process.exitCode = passed ? 0 : 1;

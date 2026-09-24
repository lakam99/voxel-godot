#!/usr/bin/env node

import { mkdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const output = join(project, 'artifacts', 'native-world-backend',
  `n5-unpublished-candidate-retirement-${Date.now()}-${randomUUID().slice(0, 8)}`);
const reportPath = join(output, 'report.json');
await mkdir(output, { recursive: true });
if (process.env.N5_COLD_IMPORT === '1') {
  const imported = await runGodotProcess(await findGodot(), [
    '--headless', '--editor', '--import', '--path', project,
  ], { cwd: project, timeoutSeconds: 360, workTimeoutSeconds: 300 });
  if (imported.code !== 0) throw new Error(`Cold import failed: ${imported.summaryPath}`);
  process.stdout.write(`Cold import owned-process evidence: ${imported.summaryPath}\n`);
}
const execution = await runGodotProcess(await findGodot(), [
  '--audio-driver', 'Dummy', '--path', project, '--script',
  'res://scripts/testing/native_world/N5UnpublishedCandidateRetirementFixture.gd',
], {
  cwd: project,
  timeoutSeconds: 360,
  workTimeoutSeconds: 300,
  reportPath,
  env: { ...process.env, N5_UNPUBLISHED_RETIREMENT_REPORT: reportPath },
});
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const passed = execution.code === 0 && report.passed === true;
process.stdout.write(`${JSON.stringify({ status: passed ? 'passed' : 'failed',
  reportPath, ownedProcessPath: execution.summaryPath,
  engineExitCode: execution.code, report }, null, 2)}\n`);
process.exitCode = passed ? 0 : 1;

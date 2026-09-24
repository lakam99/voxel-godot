#!/usr/bin/env node

import { mkdir, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const output = join(project, 'artifacts', 'native-world-backend',
  `n5-collision-publication-runtime-${Date.now()}-${randomUUID().slice(0, 8)}`);
const reportPath = join(output, 'report.json');
await mkdir(output, { recursive: true });
const godot = await findGodot();
// A fresh isolated worktree has no .godot import cache. Import under the same
// owned-process watchdog before parsing the headed fixture.
if (!existsSync(join(project, '.godot', 'global_script_class_cache.cfg'))) {
  const imported = await runGodotProcess(godot, [
    '--headless', '--editor', '--import', '--audio-driver', 'Dummy', '--path', project,
  ], { cwd: project, timeoutSeconds: 240, workTimeoutSeconds: 210 });
  if (imported.code !== 0) throw new Error(`Godot import failed: ${imported.summaryPath}`);
}
const execution = await runGodotProcess(godot, [
  '--audio-driver', 'Dummy', '--path', project, '--script',
  'res://scripts/testing/native_world/N5CollisionPublicationRuntimeFixture.gd',
], {
  cwd: project,
  timeoutSeconds: 360,
  workTimeoutSeconds: 300,
  reportPath,
  env: { ...process.env, N5_COLLISION_PUBLICATION_RUNTIME_REPORT: reportPath },
});
let report;
try {
  report = JSON.parse(await readFile(reportPath, 'utf8'));
} catch {
  report = { passed: false, reason: 'fixture_report_missing' };
}
const passed = execution.code === 0 && report.passed === true;
process.stdout.write(`${JSON.stringify({ status: passed ? 'passed' : 'failed',
  reportPath, ownedProcessPath: execution.summaryPath,
  engineExitCode: execution.code, report }, null, 2)}\n`);
process.exitCode = passed ? 0 : 1;

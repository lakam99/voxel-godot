#!/usr/bin/env node

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const runToken = randomUUID();
const output = join(project, 'artifacts', 'native-world-backend',
  `n3-engine-insertion-contract-${Date.now()}-${runToken.slice(0, 8)}`);
const reportPath = join(output, 'report.json');
const executionPath = join(output, 'execution.json');
await mkdir(output, { recursive: true });
// Dependency installation/import is a separately authorized prerequisite.
if (!existsSync(join(project, '.godot', 'global_script_class_cache.cfg'))) {
  const blocked = { status: 'blocked', reason: 'existing_import_required', reportPath,
    executed: false, runToken };
  await writeFile(executionPath, `${JSON.stringify(blocked, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify(blocked, null, 2)}\n`);
  process.exitCode = 1;
} else {
  const execution = await runGodotProcess(await findGodot(), [
    '--audio-driver', 'Dummy', '--path', project, '--script',
    'res://scripts/testing/native_world/N3EngineInsertionContractFixture.gd',
  ], { cwd: project, timeoutSeconds: 180, workTimeoutSeconds: 150, reportPath,
    expectedRunToken: runToken,
    env: { ...process.env, VWB_ENGINE_INSERTION_REPORT: reportPath,
      VWB_ENGINE_INSERTION_RUN_TOKEN: runToken } });
  let report;
  try {
    report = JSON.parse((await readFile(reportPath, 'utf8')).replace(/^\uFEFF/, ''));
  } catch {
    report = { passed: false, reason: 'fixture_report_missing' };
  }
  const passed = execution.code === 0 && report.finished === true
    && report.runToken === runToken && report.passed === true;
  const result = { status: passed ? 'passed' : 'failed', runToken, reportPath,
    ownedProcessPath: execution.summaryPath, engineExitCode: execution.code,
    ownerDrainEvidence: report.evidence?.drain ?? null,
    processCleanupScope: 'owned watchdog cleanup is independent of fixture owner drain', report };
  await writeFile(executionPath, `${JSON.stringify(result, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  process.exitCode = passed ? 0 : 1;
}

#!/usr/bin/env node

import { access, mkdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const output = join(project, 'artifacts', 'native-world-backend',
  `n5-committed-stage-transfer-${Date.now()}-${randomUUID().slice(0, 8)}`);
const reportPath = join(output, 'report.json');
await mkdir(output, { recursive: true });
const godot = await findGodot();
const needsImport = await access(join(project, '.godot', 'uid_cache.bin'))
  .then(() => false, () => true);
const imported = needsImport ? await runGodotProcess(godot, [
  '--headless', '--editor', '--import', '--path', project,
], { cwd: project, timeoutSeconds: 120, stdio: 'ignore' }) : null;
if (imported && imported.code !== 0) {
  process.stdout.write(`${JSON.stringify({ status: 'import_failed',
    importOwnedProcessPath: imported.summaryPath }, null, 2)}\n`);
  process.exitCode = 1;
} else {
const execution = await runGodotProcess(godot, [
  '--headless', '--audio-driver', 'Dummy', '--path', project, '--script',
  'res://scripts/testing/native_world/N5CommittedStageTransferContract.gd',
], {
  cwd: project,
  timeoutSeconds: 90,
  reportPath,
  env: { ...process.env, VWB_N5_COMMITTED_STAGE_TRANSFER_REPORT: reportPath,
    VOXEL_SAVE_PATH_OVERRIDE: join(output, 'fixture-saves.bin') },
});
const report = JSON.parse(await readFile(reportPath, 'utf8').catch(() => '{}'));
const passed = execution.code === 0 && report.passed === true;
process.stdout.write(`${JSON.stringify({ status: passed ? 'passed' : 'failed',
  importOwnedProcessPath: imported?.summaryPath ?? null,
  reportPath, ownedProcessPath: execution.summaryPath,
  engineExitCode: execution.code, report }, null, 2)}\n`);
process.exitCode = passed ? 0 : 1;
}

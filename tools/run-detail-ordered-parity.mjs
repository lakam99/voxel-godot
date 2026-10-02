import { mkdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { findGodot, projectRoot } from './lib/voxel-tool-runtime.mjs';
import { runGodotProcess } from './lib/godot-process.mjs';

const output = join(projectRoot, 'artifacts', 'ecology', 'detail-ordered-parity');
await mkdir(output, { recursive: true });
const reportPath = join(output, `report-${randomUUID()}.json`);
const executable = await findGodot();
const command = ['--headless', '--path', projectRoot, '--script',
  'res://scripts/testing/environment/DetailOrderedParityProbe.gd'];
const processResult = await runGodotProcess(executable, command, {
  cwd: projectRoot, timeoutSeconds: 90, workTimeoutSeconds: 60,
  env: { ...process.env, DETAIL_ORDERED_PARITY_REPORT: reportPath },
});
let report;
try { report = JSON.parse(await readFile(reportPath, 'utf8')); }
catch (error) { throw new Error(`Detail parity report unavailable: ${error.message}`); }
if (processResult.code !== 0 || report.status !== 'passed' || report.attemptsCompared !== 53)
  throw new Error(`Detail parity failed: ${reportPath}; Godot exit ${processResult.code}`);
console.log(`passed: ${reportPath}`);

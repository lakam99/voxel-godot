#!/usr/bin/env node

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const output = join(project, 'artifacts', 'native-world-backend',
  `n3-private-main-headed-${Date.now()}-${randomUUID().slice(0, 8)}`);
await mkdir(output, { recursive: true });
const godot = await findGodot();
const continueFromIndex = process.argv.indexOf('--continue-from');
const continueFrom = continueFromIndex >= 0 ? process.argv[continueFromIndex + 1] : null;
if (continueFromIndex >= 0 && !continueFrom) throw new Error('--continue-from needs an artifact directory');
const historicalFromIndex = process.argv.indexOf('--historical-from');
const historicalFrom = historicalFromIndex >= 0 ? process.argv[historicalFromIndex + 1] : null;
if (historicalFromIndex >= 0 && !historicalFrom) throw new Error('--historical-from needs an artifact directory');
if (continueFrom && historicalFrom) throw new Error('Choose one source fixture');
const savePath = join(continueFrom ?? output, 'fixture-saves.json');
if (historicalFrom) {
  const sourceSlot = join(historicalFrom, 'fixture-saves_slot_n3-private-main-headed.json');
  const legacy = JSON.parse(await readFile(sourceSlot, 'utf8'));
  delete legacy.terrainVolume;
  legacy.terrain = [{ x: 0, z: 0, surfaceY: -10 }];
  await writeFile(join(output, 'fixture-saves_slot_n3-private-main-headed.json'), JSON.stringify(legacy));
  await writeFile(join(output, 'fixture-saves_active_seed.txt'), 'n3-private-main-headed');
}
async function phase(mode) {
  const reportPath = join(output, `${mode}-report.json`);
  const execution = await runGodotProcess(godot, [
    '--path', project, '--fixed-fps', '60', '--resolution', '1280x720',
    '--scene', 'res://scenes/testing/N3PrivateMainLoadHeaded.tscn',
  ], {
    cwd: project,
    timeoutSeconds: 420,
    reportPath,
    env: { ...process.env, VOXEL_PLAYTEST: mode === 'new_game' ? '1' : '',
      VOXEL_TEST_SEED: 'n3-private-main-headed',
      VOXEL_SAVE_PATH_OVERRIDE: historicalFrom ? join(output, 'fixture-saves.json') : savePath,
      VWB_N3_PRIVATE_MAIN_MODE: mode,
      VWB_N3_PRIVATE_MAIN_REPORT: reportPath,
      VWB_N3_PRIVATE_MAIN_CAPTURE_DIR: output },
  });
  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  return { mode, passed: execution.code === 0 && report.passed === true,
    reportPath, ownedProcessPath: execution.summaryPath, engineExitCode: execution.code,
    elapsedMs: report.elapsedMs, failure: report.failure,
    pendingCapture: report.pendingCapture, readyCapture: report.readyCapture };
}
const newGame = continueFrom || historicalFrom ? null : await phase('new_game');
const coldContinue = historicalFrom ? await phase('historical_continue')
  : continueFrom || newGame.passed ? await phase('continue') : null;
const passed = (continueFrom || historicalFrom || newGame.passed) && coldContinue?.passed === true;
process.stdout.write(`${JSON.stringify({ status: passed ? 'passed' : 'failed',
  newGame, coldContinue }, null, 2)}\n`);
process.exitCode = passed ? 0 : 1;

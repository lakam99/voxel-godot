#!/usr/bin/env node

import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const output = join(project, 'artifacts', 'native-world-backend',
  `n5-resident-collision-owner-${Date.now()}-${randomUUID().slice(0, 8)}`);
const reportPath = join(output, 'report.json');
const receiptPath = join(output, 'receipt.json');
await mkdir(output, { recursive: true });

const sourcePaths = [
  'scripts/terrain/NativeResidentCollisionOwner.gd',
  'scripts/terrain/NativeTerrainArtifactRequests.gd',
  'scripts/terrain/NativeCollisionRetirementReceipt.gd',
  'scripts/testing/native_world/N5ResidentCollisionOwnerFixture.gd',
  'scenes/testing/native_world/N5ResidentCollisionOwnerFixture.tscn',
  'tools/run-n5-resident-collision-owner.mjs',
];
const sourceSha256 = {};
for (const relativePath of sourcePaths) {
  const bytes = await readFile(join(project, relativePath));
  sourceSha256[relativePath] = createHash('sha256').update(bytes).digest('hex');
}

const git = (...args) => spawnSync('git', ['-C', project, ...args], {
  encoding: 'utf8', windowsHide: true,
}).stdout.trim();
const execution = await runGodotProcess(await findGodot(), [
  '--headless', '--audio-driver', 'Dummy', '--path', project,
  'res://scenes/testing/native_world/N5ResidentCollisionOwnerFixture.tscn',
], {
  cwd: project,
  timeoutSeconds: 60,
  reportPath,
  env: {
    ...process.env,
    VOXEL_DISABLE_AUDIO_PLAYBACK: '1',
    N5_RESIDENT_COLLISION_REPORT: reportPath,
  },
});
const fixtureReport = JSON.parse(await readFile(reportPath, 'utf8'));
const passed = execution.code === 0 && fixtureReport.passed === true;
const receipt = {
  schema: 'n5-resident-collision-owner-runner/v1',
  passed,
  gitHead: git('rev-parse', 'HEAD'),
  gitTree: git('rev-parse', 'HEAD^{tree}'),
  gitStatusShort: git('status', '--short'),
  command: [
    '--headless', '--audio-driver', 'Dummy', '--path', project,
    'res://scenes/testing/native_world/N5ResidentCollisionOwnerFixture.tscn',
  ],
  audioPlaybackDisabled: true,
  sourceSha256,
  reportPath,
  ownedProcessPath: execution.summaryPath,
  engineExitCode: execution.code,
  fixtureReport,
};
await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
process.stdout.write(`${JSON.stringify({
  status: passed ? 'passed' : 'failed', reportPath, receiptPath,
  ownedProcessPath: execution.summaryPath, engineExitCode: execution.code,
  reportSummary: {
    passed: fixtureReport.passed,
    elapsedMilliseconds: fixtureReport.elapsedMilliseconds,
    productionCutover: fixtureReport.productionCutover,
    boundedPreparationPassed: fixtureReport.evidence?.boundedPreparation?.passed,
    drainPhases: Object.fromEntries(Object.entries(fixtureReport.evidence?.drain ?? {})
      .map(([name, evidence]) => [name, evidence?.passed ?? evidence?.status])),
  },
}, null, 2)}\n`);
process.exitCode = passed ? 0 : 1;

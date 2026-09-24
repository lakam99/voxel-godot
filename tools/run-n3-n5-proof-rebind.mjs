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
  `n3-n5-proof-rebind-${Date.now()}-${randomUUID().slice(0, 8)}`);
const reportPath = join(output, 'report.json');
const receiptPath = join(output, 'receipt.json');
await mkdir(output, { recursive: true });

const sourcePaths = [
  'scripts/terrain/NativeTerrainArtifactRequests.gd',
  'scripts/terrain/NativeResidentCollisionOwner.gd',
  'scripts/terrain/NativeWindowedCollisionCoordinator.gd',
  'scripts/testing/native_world/N3N5WindowedPhysicalFixture.gd',
  'tools/run-n3-n5-proof-rebind.mjs',
];
const binaryPath = 'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll';
const sourceSha256 = {};
for (const relativePath of [...sourcePaths, binaryPath]) {
  sourceSha256[relativePath] = createHash('sha256')
    .update(await readFile(join(project, relativePath))).digest('hex');
}
const git = (...args) => spawnSync('git', ['-C', project, ...args], {
  encoding: 'utf8', windowsHide: true,
}).stdout.trim();
const args = ['--audio-driver', 'Dummy', '--path', project, '--script',
  'res://scripts/testing/native_world/N3N5WindowedPhysicalFixture.gd'];
const execution = await runGodotProcess(await findGodot(), args, {
  cwd: project,
  timeoutSeconds: 60,
  reportPath,
  env: {
    ...process.env,
    VOXEL_DISABLE_AUDIO_PLAYBACK: '1',
    N3_N5_PROOF_REBIND_ONLY: '1',
    N3_N5_WINDOWED_PHYSICAL_REPORT: reportPath,
  },
});
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const passed = execution.code === 0 && report.passed === true;
const receipt = {
  schema: 'n3-n5-proof-rebind-runner/v1',
  passed,
  productionCutover: false,
  gitHead: git('rev-parse', 'HEAD'),
  gitTree: git('rev-parse', 'HEAD^{tree}'),
  gitStatusShort: git('status', '--short'),
  command: args,
  audioPlaybackDisabled: true,
  sourceSha256,
  reportPath,
  ownedProcessPath: execution.summaryPath,
  engineExitCode: execution.code,
  report,
};
await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
process.stdout.write(`${JSON.stringify({
  status: passed ? 'passed' : 'failed',
  reportPath,
  receiptPath,
  ownedProcessPath: execution.summaryPath,
  engineExitCode: execution.code,
  reportSummary: {
    passed: report.passed,
    productionCutover: report.productionCutover,
    mode: report.evidence?.mode,
    localRevision: report.evidence?.retained?.physical?.provenance
      ?.requestIdentity?.sourceRevision,
    globalRevision: report.evidence?.retained?.physical?.provenance
      ?.globalLayoutIdentity?.sourceRevision,
    validatedBlocks: report.evidence?.retained?.physical
      ?.sourceTicketRebind?.validatedBlocks,
    actorContactAfterRebind: report.evidence?.retained?.actorContactAfterRebind,
    aggregateStatus: report.evidence?.retained?.aggregate?.status,
    coordinatorDrainStatus: report.evidence?.drain?.coordinator?.status,
    brokerDrainStatus: report.evidence?.drain?.broker?.status,
  },
}, null, 2)}\n`);
process.exitCode = passed ? 0 : 1;

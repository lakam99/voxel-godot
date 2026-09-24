#!/usr/bin/env node

import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';
import {
  auditN5CollisionMemorySourceFreeze,
  buildN5CollisionMemoryRunnerEnvelope,
} from './lib/n5-collision-memory-source-freeze.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const output = join(project, 'artifacts', 'native-world-backend',
  `n5-collision-memory-policy-${Date.now()}-${randomUUID().slice(0, 8)}`);
const godotReportPath = join(output, 'godot-report.json');
const envelopePath = join(output, 'runner-envelope.json');
const godotExecutable = await findGodot();
const sourcePaths = [
  'scripts/terrain/NativeCollisionMemoryPolicy.gd',
  'scripts/terrain/NativeCollisionMemoryAdmission.gd',
  'scripts/testing/native_world/N5CollisionMemoryPolicyContract.gd',
  'tools/run-n5-collision-memory-policy-contract.mjs',
  'tools/lib/godot-process.mjs',
  'tools/lib/voxel-tool-runtime.mjs',
  'tools/lib/n5-collision-memory-source-freeze.mjs',
  'tools/run-godot-scene-watchdog.mjs',
  'tools/lib/owned-process.mjs',
  'tools/lib/owned-native-host.mjs',
  'tools/lib/owned-live-clock.mjs',
  'tools/native/OwnedProcessNative.cs',
  'tools/native/OwnedProcessHost.cs',
  godotExecutable,
];
async function hashSources(paths) {
  return Object.fromEntries(await Promise.all(paths.map(async path => [
    path, createHash('sha256').update(await readFile(
      isAbsolute(path) ? path : join(project, path))).digest('hex'),
  ])));
}
function readHead() {
  return execFileSync('git', ['rev-parse', 'HEAD'], {
    cwd: project, encoding: 'utf8', windowsHide: true,
  }).trim();
}
const preSourceHashes = await hashSources(sourcePaths);
const preSourceCommit = readHead();
await mkdir(output, { recursive: true });
const execution = await runGodotProcess(godotExecutable, [
  '--audio-driver', 'Dummy', '--headless', '--path', project, '--script',
  'res://scripts/testing/native_world/N5CollisionMemoryPolicyContract.gd',
], {
  cwd: project,
  timeoutSeconds: 360,
  workTimeoutSeconds: 300,
  reportPath: godotReportPath,
  env: { ...process.env, VOXEL_DISABLE_AUDIO_PLAYBACK: '1',
    N5_COLLISION_MEMORY_POLICY_REPORT: godotReportPath,
    N5_COLLISION_MEMORY_POLICY_SOURCE_COMMIT: preSourceCommit,
    N5_COLLISION_MEMORY_POLICY_SOURCE_HASHES: JSON.stringify(preSourceHashes) },
});
const postSourceHashes = await hashSources(sourcePaths);
const postSourceCommit = readHead();
let godotReport = null;
let godotReportReadError = null;
try {
  godotReport = JSON.parse(await readFile(godotReportPath, 'utf8'));
} catch (error) {
  godotReportReadError = String(error?.message ?? error);
}
const reportedHashes = godotReport?.sourceHashes
  && typeof godotReport.sourceHashes === 'object'
  ? godotReport.sourceHashes : {};
const sourceFreeze = auditN5CollisionMemorySourceFreeze({
  paths: sourcePaths, preHashes: preSourceHashes, postHashes: postSourceHashes,
  reportHashes: reportedHashes, preCommit: preSourceCommit,
  postCommit: postSourceCommit, reportCommit: godotReport?.sourceCommit,
});
const envelope = buildN5CollisionMemoryRunnerEnvelope({
  executionCode: execution.code,
  godotReport,
  godotReportReadError,
  sourceFreeze,
  preCommit: preSourceCommit,
  postCommit: postSourceCommit,
  preHashes: preSourceHashes,
  postHashes: postSourceHashes,
  godotReportPath,
  watchdogPath: execution.summaryPath,
  godotExecutable,
});
const temporaryEnvelopePath = `${envelopePath}.${randomUUID()}.tmp`;
await writeFile(temporaryEnvelopePath, `${JSON.stringify(envelope, null, 2)}\n`);
await rename(temporaryEnvelopePath, envelopePath);
process.stdout.write(`${JSON.stringify({ ...envelope, envelopePath }, null, 2)}\n`);
process.exitCode = envelope.passed ? 0 : 1;

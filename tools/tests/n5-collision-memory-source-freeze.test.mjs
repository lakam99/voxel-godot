import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import {
  auditN5CollisionMemorySourceFreeze,
  buildN5CollisionMemoryRunnerEnvelope,
} from '../lib/n5-collision-memory-source-freeze.mjs';

const paths = ['policy.gd', 'runner.mjs', 'tools/lib/launcher.mjs'];
const hashes = Object.fromEntries(paths.map((path, index) => [path, `hash-${index}`]));

test('N5 source freeze accepts an unchanged exact source inventory and HEAD', () => {
  const result = auditN5CollisionMemorySourceFreeze({
    paths, preHashes: hashes, postHashes: { ...hashes },
    reportHashes: { ...hashes }, preCommit: 'commit-a',
    postCommit: 'commit-a', reportCommit: 'commit-a',
  });
  assert.equal(result.passed, true);
  assert.deepEqual(result.changedPaths, []);
});

test('N5 source freeze rejects a source changed during execution', () => {
  const postHashes = { ...hashes, 'runner.mjs': 'mutated-hash' };
  const result = auditN5CollisionMemorySourceFreeze({
    paths, preHashes: hashes, postHashes, reportHashes: hashes,
    preCommit: 'commit-a', postCommit: 'commit-a', reportCommit: 'commit-a',
  });
  assert.equal(result.passed, false);
  assert.deepEqual(result.changedPaths, ['runner.mjs']);
});

test('N5 source freeze rejects a HEAD change during execution', () => {
  const result = auditN5CollisionMemorySourceFreeze({
    paths, preHashes: hashes, postHashes: { ...hashes },
    reportHashes: { ...hashes }, preCommit: 'commit-a',
    postCommit: 'commit-b', reportCommit: 'commit-a',
  });
  assert.equal(result.passed, false);
  assert.deepEqual(result.changedPaths, ['git:HEAD']);
});

test('N5 source freeze rejects missing or extra report inventory entries', () => {
  const result = auditN5CollisionMemorySourceFreeze({
    paths, preHashes: hashes, postHashes: { ...hashes },
    reportHashes: { ...hashes, 'unfrozen.gd': 'hash-x' },
    preCommit: 'commit-a', postCommit: 'commit-a', reportCommit: 'commit-a',
  });
  assert.equal(result.passed, false);
  assert.deepEqual(result.changedPaths, ['source:inventory']);
});

test('N5 runner allows cold project bootstrap but keeps a bounded owned process', async () => {
  const runnerPath = fileURLToPath(new URL('../run-n5-collision-memory-policy-contract.mjs', import.meta.url));
  const runner = await readFile(runnerPath, 'utf8');
  assert.match(runner, /timeoutSeconds:\s*360/);
  assert.match(runner, /workTimeoutSeconds:\s*300/);
  assert.match(runner, /runGodotProcess\(/);
  assert.match(runner, /runner-envelope\.json/);
  assert.match(runner, /await rename\(temporaryEnvelopePath, envelopePath\)/);
  for (const required of [
    'tools/run-godot-scene-watchdog.mjs',
    'tools/lib/owned-process.mjs',
    'tools/lib/owned-native-host.mjs',
    'tools/lib/owned-live-clock.mjs',
    'tools/native/OwnedProcessNative.cs',
    'tools/native/OwnedProcessHost.cs',
  ]) assert.ok(runner.includes(`'${required}'`), `missing frozen ${required}`);
  assert.match(runner, /sourcePaths = \[[\s\S]*godotExecutable,[\s\S]*\]/);
});

const validGodotReport = {
  schema: 'n5-collision-memory-policy-contract/v2',
  passed: true,
  evidenceLevel: 'pure policy/ledger contract',
  productionWired: false,
  productionCapsConfigured: false,
};

const envelopeInput = sourceFreeze => ({
  executionCode: 0,
  godotReport: validGodotReport,
  sourceFreeze,
  preCommit: 'commit-a',
  postCommit: 'commit-a',
  preHashes: hashes,
  postHashes: hashes,
  godotReportPath: 'godot-report.json',
  watchdogPath: 'watchdog.json',
});

test('N5 runner envelope promotes only an exact green source freeze', () => {
  const envelope = buildN5CollisionMemoryRunnerEnvelope(envelopeInput({
    passed: true, changedPaths: [], inventoriesMatch: true, commitMatches: true,
  }));
  assert.equal(envelope.schema, 'n5-collision-memory-runner-envelope/v1');
  assert.equal(envelope.status, 'passed');
  assert.equal(envelope.passed, true);
  assert.equal(envelope.contractMatches, true);
});

test('N5 runner envelope persists failed verdict for post-run drift', () => {
  const envelope = buildN5CollisionMemoryRunnerEnvelope(envelopeInput({
    passed: false, changedPaths: ['runner.mjs'], inventoriesMatch: true,
    commitMatches: true,
  }));
  assert.equal(envelope.status, 'failed');
  assert.equal(envelope.passed, false);
  assert.equal(envelope.contractMatches, false);
  assert.deepEqual(envelope.sourceFreeze.changedPaths, ['runner.mjs']);
});

test('N5 runner envelope rejects a green Godot report with production flags', () => {
  const input = envelopeInput({
    passed: true, changedPaths: [], inventoriesMatch: true, commitMatches: true,
  });
  input.godotReport = { ...validGodotReport, productionWired: true };
  const envelope = buildN5CollisionMemoryRunnerEnvelope(input);
  assert.equal(envelope.status, 'failed');
  assert.equal(envelope.contractMatches, false);
});

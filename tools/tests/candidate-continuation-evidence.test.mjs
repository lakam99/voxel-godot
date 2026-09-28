import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { hashes } from '../lib/building-runner.mjs';
import { auditContinuationSources, auditContinuationInventory, assertContinuationOrigin } from '../lib/candidate-continuation-evidence.mjs';

test('source audit detects changed production inputs and missing origin artifacts', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'citadel-continuation-test-'));
  t.after(() => fs.rmSync(root, { recursive: true }));
  fs.writeFileSync(path.join(root, 'world.gd'), 'world source');
  fs.writeFileSync(path.join(root, 'source.bin'), 'origin');
  const before = hashes(root, ['world.gd', path.join(root, 'source.bin')]);
  assert.equal(auditContinuationSources(root, before).unchanged, true);
  fs.writeFileSync(path.join(root, 'world.gd'), 'changed world source');
  fs.unlinkSync(path.join(root, 'source.bin'));
  const result = auditContinuationSources(root, before);
  assert.equal(result.unchanged, false);
  assert.equal(result.changed.length, 1);
  assert.equal(result.unreadable.length, 1);
});

test('inventory rejects added, removed and unreadable file sets', () => {
  const added = auditContinuationInventory('.', {}, () => ({ 'new-source.gd': 'hash' }));
  assert.equal(added.unchanged, false);
  assert.deepEqual(added.added, ['new-source.gd']);
  const removed = auditContinuationInventory('.', { 'nonexistent-source.gd': 'hash' }, () => ({}));
  assert.equal(removed.unchanged, false);
  assert.deepEqual(removed.removed, ['nonexistent-source.gd']);
  const unreadable = auditContinuationInventory('.', {}, () => { throw new Error('denied'); });
  assert.equal(unreadable.unchanged, false);
  assert.equal(unreadable.unreadable[0].error, 'denied');
});

test('origin association rejects a swapped path or hash despite a passing report', () => {
  const source = path.resolve('source.bin'), input = path.resolve('input.bin');
  const report = { passed: true, sourcePath: source, inputPath: input, sourceSha256: 'a', inputSha256: 'b' };
  assert.doesNotThrow(() => assertContinuationOrigin(report, source, input, 'a', 'b'));
  for (const patch of [{ sourcePath: input }, { inputPath: source }, { sourceSha256: 'other' }, { inputSha256: 'other' }]) {
    assert.throws(() => assertContinuationOrigin({ ...report, ...patch }, source, input, 'a', 'b'), /exact origin/);
  }
});

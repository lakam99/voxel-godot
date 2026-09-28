#!/usr/bin/env node

import assert from 'node:assert/strict';
import { requireNativeFocusedReceiptBinding } from './lib/native-surface-oracle-attestation.mjs';

const commit = 'a'.repeat(40);
const source = { path: 'native/source.cpp', bytes: 12, sha256: 'b'.repeat(64) };
const executable = {
  path: 'artifacts/run/build/native-terrain-edit-shape-msvc-tests.exe',
  bytes: 34,
  sha256: 'c'.repeat(64),
};
const receipt = {
  schema: 'native-terrain-edit-shape-focused-receipt/v1',
  status: 'passed',
  evidenceClass: 'clean-source-attested',
  startedFrom: { commit, status: '' },
  sourceInputs: [source],
  unchanged: { commit: true, status: true, sourceHashes: true },
  buildArtifacts: { msvcExecutable: executable },
  steps: [{ label: 'msvc-execute', executable: executable.path, exitCode: 0 }],
};
const input = {
  project: 'C:/project', headCommit: commit, gitStatus: '', receipt,
  nativeReceiptPath: 'C:/project/artifacts/run/report.json',
  nativeExecutable: executable, currentSourceInputs: [source],
};
assert.equal(requireNativeFocusedReceiptBinding(input).commit, commit);
assert.throws(() => requireNativeFocusedReceiptBinding({ ...input, headCommit: 'd'.repeat(40) }),
  /receipt commit\/status/);
assert.throws(() => requireNativeFocusedReceiptBinding({
  ...input, currentSourceInputs: [{ ...source, sha256: 'e'.repeat(64) }],
}), /source input mismatch/);
assert.throws(() => requireNativeFocusedReceiptBinding({
  ...input, nativeExecutable: { ...executable, sha256: 'f'.repeat(64) },
}), /supplied native executable/);
process.stdout.write(JSON.stringify({
  schema: 'native-surface-oracle-attestation-helper-tests/v1',
  passed: 4,
  failed: 0,
}) + '\n');

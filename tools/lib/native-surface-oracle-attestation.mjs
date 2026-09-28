import { dirname, resolve } from 'node:path';

const fail = message => { throw new Error(`native focused receipt binding rejected: ${message}`); };
const sameRecord = (left, right) => left && right
  && left.path === right.path && left.bytes === right.bytes
  && String(left.sha256).toLowerCase() === String(right.sha256).toLowerCase();
const canonicalPath = (project, path) => resolve(project, path).toLowerCase();

export function requireNativeFocusedReceiptBinding({
  project,
  headCommit,
  gitStatus,
  receipt,
  nativeReceiptPath,
  nativeExecutable,
  currentSourceInputs,
}) {
  if (gitStatus !== '') fail('current worktree is not clean');
  if (receipt?.schema !== 'native-terrain-edit-shape-focused-receipt/v1'
      || receipt.status !== 'passed' || receipt.evidenceClass !== 'clean-source-attested') {
    fail('receipt is not a passed clean-source-attested focused receipt');
  }
  if (receipt.startedFrom?.commit !== headCommit || receipt.startedFrom?.status !== '') {
    fail('receipt commit/status does not match current clean HEAD');
  }
  if (!receipt.unchanged?.commit || !receipt.unchanged?.status
      || !receipt.unchanged?.sourceHashes) {
    fail('receipt did not finish with unchanged commit/status/source hashes');
  }
  if (!Array.isArray(receipt.sourceInputs) || receipt.sourceInputs.length === 0
      || !Array.isArray(currentSourceInputs)
      || currentSourceInputs.length !== receipt.sourceInputs.length) {
    fail('source inventory is missing or incomplete');
  }
  for (let index = 0; index < receipt.sourceInputs.length; index += 1) {
    if (!sameRecord(receipt.sourceInputs[index], currentSourceInputs[index])) {
      fail(`source input mismatch at index ${index}`);
    }
  }
  const recordedExecutable = receipt.buildArtifacts?.msvcExecutable;
  if (!sameRecord(recordedExecutable, nativeExecutable)) {
    fail('supplied native executable does not match recorded artifact bytes/hash/path');
  }
  if (canonicalPath(project, recordedExecutable.path)
      !== canonicalPath(project, nativeExecutable.path)) {
    fail('supplied native executable resolves to a different artifact path');
  }
  const expectedArtifactPath = resolve(dirname(nativeReceiptPath), 'build',
    'native-terrain-edit-shape-msvc-tests.exe');
  if (canonicalPath(project, recordedExecutable.path) !== expectedArtifactPath.toLowerCase()) {
    fail('recorded executable is not the focused receipt build artifact');
  }
  const execution = receipt.steps?.find(step => step.label === 'msvc-execute');
  if (!execution || execution.exitCode !== 0
      || canonicalPath(project, execution.executable)
        !== canonicalPath(project, recordedExecutable.path)) {
    fail('receipt did not execute the recorded MSVC artifact successfully');
  }
  return {
    schema: receipt.schema,
    commit: headCommit,
    sourceCount: receipt.sourceInputs.length,
    nativeExecutable: recordedExecutable,
  };
}

const sameKeys = (left, right) => {
  if (!left || typeof left !== 'object' || Array.isArray(left)
      || !right || typeof right !== 'object' || Array.isArray(right)) return false;
  const leftKeys = Object.keys(left).sort();
  const rightKeys = Object.keys(right).sort();
  return leftKeys.length === rightKeys.length
    && leftKeys.every((key, index) => key === rightKeys[index]);
};

export function auditN5CollisionMemorySourceFreeze({
  paths, preHashes, postHashes, reportHashes, preCommit, postCommit, reportCommit,
}) {
  const hasExactInventories = sameKeys(preHashes, postHashes)
    && sameKeys(preHashes, reportHashes)
    && Array.isArray(paths)
    && paths.length === Object.keys(preHashes ?? {}).length
    && new Set(paths).size === paths.length
    && paths.every(path => Object.hasOwn(preHashes, path));
  const changedPaths = [];
  if (hasExactInventories) {
    for (const path of paths) {
      if (preHashes[path] !== postHashes[path]
          || preHashes[path] !== reportHashes[path]) changedPaths.push(path);
    }
  } else {
    changedPaths.push('source:inventory');
  }
  if (preCommit !== postCommit || preCommit !== reportCommit) {
    changedPaths.push('git:HEAD');
  }
  return {
    passed: hasExactInventories && changedPaths.length === 0,
    changedPaths,
    inventoriesMatch: hasExactInventories,
    commitMatches: preCommit === postCommit && preCommit === reportCommit,
  };
}

export function buildN5CollisionMemoryRunnerEnvelope({
  executionCode, godotReport, godotReportReadError = null, sourceFreeze,
  preCommit, postCommit, preHashes, postHashes, godotReportPath,
  watchdogPath,
}) {
  const contractMatches = godotReport?.schema === 'n5-collision-memory-policy-contract/v2'
    && godotReport?.evidenceLevel === 'pure policy/ledger contract'
    && godotReport?.productionWired === false
    && godotReport?.productionCapsConfigured === false
    && sourceFreeze?.passed === true;
  const passed = executionCode === 0 && godotReport?.passed === true
    && contractMatches && godotReportReadError === null;
  return {
    schema: 'n5-collision-memory-runner-envelope/v1',
    status: passed ? 'passed' : 'failed',
    passed,
    evidenceLevel: 'runner-owned source-frozen pure policy/ledger contract',
    productionWired: false,
    productionCapsConfigured: false,
    executionCode,
    contractMatches,
    godotReportReadError,
    godotReportPath,
    watchdogPath,
    sourceFreeze,
    preSourceCommit: preCommit,
    postSourceCommit: postCommit,
    preSourceHashes: preHashes,
    postSourceHashes: postHashes,
    godotReport,
  };
}

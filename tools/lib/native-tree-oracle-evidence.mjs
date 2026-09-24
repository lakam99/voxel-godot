export function requireWorkerEvidenceContract(rows, contract, label) {
  if (contract === undefined) return;
  if (!contract || !Array.isArray(contract.allowedRenderTiers)
      || contract.allowedRenderTiers.length === 0
      || typeof contract.requireZeroTopology !== 'boolean'
      || typeof contract.topologySignaturePrefix !== 'string'
      || contract.topologySignaturePrefix.length === 0
      || (contract.requireIdentityKeys !== undefined && typeof contract.requireIdentityKeys !== 'boolean')
      || (contract.requireFiniteNormalizedNumbers !== undefined
        && typeof contract.requireFiniteNormalizedNumbers !== 'boolean')) {
    throw new Error('invalid worker evidence contract');
  }
  for (const [index, row] of rows.entries()) {
    if (!contract.allowedRenderTiers.includes(row.renderTier)) {
      throw new Error(`${label} worker ${index}: render tier ${row.renderTier} is not admitted evidence`);
    }
    if (contract.requireZeroTopology
        && (row.sourceBranches !== 0 || row.sourceFoliage !== 0
          || row.branches !== 0 || row.foliage !== 0)) {
      throw new Error(`${label} worker ${index}: detailed topology is outside this evidence contract`);
    }
    if (!row.signature || !row.topologySignature.startsWith(contract.topologySignaturePrefix)) {
      throw new Error(`${label} worker ${index}: missing admitted exact topology identity`);
    }
    if (contract.requireIdentityKeys) {
      if (typeof row.recipeIdentityKey !== 'string' || row.recipeIdentityKey.length === 0
          || typeof row.requestKey !== 'string' || row.requestKey.length === 0) {
        throw new Error(`${label} worker ${index}: missing exact request identities`);
      }
      if (row.requestKey !== `${row.recipeIdentityKey}:${row.renderTier}`) {
        throw new Error(`${label} worker ${index}: request identity field order or tier binding mismatch`);
      }
    }
    if (contract.requireFiniteNormalizedNumbers) {
      const normalized = row.normalized ?? {};
      const numbers = [normalized.ageYears, normalized.growthStage, normalized.geneticSeed,
        normalized.height, normalized.trunkRadius, normalized.canopyRadius,
        normalized.canopyDensity, row.collisionRadius, row.collisionHeight];
      if (!numbers.every(Number.isFinite)) {
        throw new Error(`${label} worker ${index}: non-finite canonical numeric evidence`);
      }
    }
  }
}

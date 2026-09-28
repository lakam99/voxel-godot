#!/usr/bin/env node

import assert from 'node:assert/strict';
import {requireWorkerEvidenceContract} from './lib/native-tree-oracle-evidence.mjs';

const contract = {
  allowedRenderTiers: ['impostor'],
  requireZeroTopology: true,
  topologySignaturePrefix: 'impostor:',
  requireIdentityKeys: true,
  requireFiniteNormalizedNumbers: true,
};
const exactImpostor = {
  renderTier: 'impostor', sourceBranches: 0, sourceFoliage: 0, branches: 0, foliage: 0,
  recipeIdentityKey: 'runtime:world:tree:forest:broadleaf:bushy_oak',
  requestKey: 'runtime:world:tree:forest:broadleaf:bushy_oak:impostor',
  signature: 'tree-v10-ada1a6f6', topologySignature: 'impostor:world:tree:bushy_oak',
  normalized: {ageYears: 40, growthStage: 0.8, geneticSeed: 42, height: 20,
    trunkRadius: 0.8, canopyRadius: 7, canopyDensity: 0.78},
  collisionRadius: 0.8, collisionHeight: 9.2,
};

assert.doesNotThrow(() => requireWorkerEvidenceContract([exactImpostor], contract, 'fixture'));
assert.throws(() => requireWorkerEvidenceContract([{...exactImpostor,
  renderTier: 'near', signature: '', topologySignature: ''}], contract, 'fixture'), /not admitted evidence/u);
assert.throws(() => requireWorkerEvidenceContract([{...exactImpostor,
  signature: '', topologySignature: ''}], contract, 'fixture'), /missing admitted exact topology identity/u);
assert.throws(() => requireWorkerEvidenceContract([{...exactImpostor,
  sourceBranches: 1, branches: 1}], contract, 'fixture'), /detailed topology/u);
assert.throws(() => requireWorkerEvidenceContract([exactImpostor], {}, 'fixture'), /invalid worker evidence/u);
assert.throws(() => requireWorkerEvidenceContract([{...exactImpostor,
  recipeIdentityKey: '', requestKey: ''}], contract, 'fixture'), /missing exact request identities/u);
assert.throws(() => requireWorkerEvidenceContract([{...exactImpostor,
  requestKey: `impostor:${exactImpostor.recipeIdentityKey}`}], contract, 'fixture'), /field order or tier binding mismatch/u);
assert.throws(() => requireWorkerEvidenceContract([{...exactImpostor,
  normalized: {...exactImpostor.normalized, canopyDensity: Number.NaN}}], contract, 'fixture'), /non-finite canonical numeric/u);

console.log(JSON.stringify({schema: 'native-tree-oracle-evidence-tests/v1', status: 'passed', assertions: 8}));

import fs from 'node:fs';
import path from 'node:path';
import { demand, sha, stable, watchdogSources } from './building-runner.mjs';

// Mirrored by Codec.RUNNER_SOURCE_PATHS and tested against its literal inventory.
// The Codec includes every entry in the checkpoint's hashed source fingerprint.
export const structuralRunnerSources = [
  'tools/run-citadel-structural-composer-two-phase-contract.mjs',
  'tools/lib/building-runner.mjs',
  'tools/lib/building-special.mjs',
  'tools/lib/building-special-sources.mjs',
  'tools/lib/building-source-bindings.mjs',
  'tools/lib/building-help.mjs',
  ...watchdogSources,
];

export function validatePhaseASourceBindings(project, launch, report) {
  demand(launch?.mode === 'PhaseA', 'Expected a Node Phase A launch');
  const map = launch.sourceSha256;
  demand(map && typeof map === 'object' && !Array.isArray(map), 'Missing Phase A source bindings');
  const fingerprint = report?.sourceFingerprint;
  demand(fingerprint?.ready === true && Array.isArray(fingerprint.entries), 'Missing Phase A checkpoint source fingerprint');
  const entries = new Map();
  for (const row of fingerprint.entries) {
    demand(Array.isArray(row) && row.length === 3 && typeof row[0] === 'string' && Number.isSafeInteger(row[1]) && row[1] >= 0 && typeof row[2] === 'string' && /^[a-f0-9]{64}$/.test(row[2]) && !entries.has(row[0]), 'Malformed Phase A source fingerprint row');
    entries.set(row[0], row);
  }
  for (const source of structuralRunnerSources) {
    demand(Object.hasOwn(map, source) && typeof map[source] === 'string' && /^[a-f0-9]{64}$/.test(map[source]), 'Missing required Phase A helper binding: ' + source);
    const row = entries.get(source);
    demand(row && row[2] === map[source], 'Phase A helper absent from or divergent with checkpoint fingerprint: ' + source);
    const file = path.join(project, source);
    demand(fs.statSync(file).size === row[1] && sha(file) === row[2], 'Phase A fingerprint source changed: ' + source);
  }
  // This is an early admission check. Codec also authenticates the fingerprint
  // against the checkpoint/core hashes and current files before reconstruction.
  stable(project, map);
}

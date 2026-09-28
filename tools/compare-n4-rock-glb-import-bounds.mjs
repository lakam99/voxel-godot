#!/usr/bin/env node

// Source-owned GLB vertex bounds versus Godot's imported Mesh.get_aabb().
// This comparison stops before runtime scaling, fallback and publication.
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';

const [sourcePath, godotPath] = process.argv.slice(2);
if (!sourcePath || !godotPath) throw new Error('Pass source-bounds and Godot-import report paths.');
const sourceBytes = await readFile(sourcePath), godotBytes = await readFile(godotPath);
const source = JSON.parse(sourceBytes), godot = JSON.parse(godotBytes);
if (source.schema !== 'n4-rock-glb-source-bounds/v1'
    || godot.schema !== 'n4-rock-import-bounds-oracle/v1' || godot.passed !== true
    || source.rows.length !== 6 || godot.rows.length !== 6)
  throw new Error('Expected complete source-matched six-rock receipts.');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const matches = [];
for (const asset of source.rows) {
  const imported = godot.rows.find(row => row.id === asset.id);
  if (!imported || imported.meshBounds?.length !== 1 || imported.meshBounds[0].meshClass !== 'ArrayMesh'
      || imported.path !== asset.path || imported.rootScale.some(v => v !== 1)
      || imported.rootPosition.some(v => v !== 0))
    throw new Error(`${asset.id}: imported scene shape or source path changed`);
  const mesh = imported.meshBounds[0];
  let maximumDifference = 0;
  for (const key of ['min', 'max']) for (let axis = 0; axis < 3; axis++) {
    const difference = Math.abs(asset[key][axis] - mesh[key][axis]);
    if (!Number.isFinite(difference) || difference > 2e-7)
      throw new Error(`${asset.id}: ${key}[${axis}] differs by ${difference}`);
    maximumDifference = Math.max(maximumDifference, difference);
  }
  matches.push({ id: asset.id, glbSha256: asset.glbSha256, maximumDifference });
}
process.stdout.write(`${JSON.stringify({ schema: 'n4-rock-glb-import-parity/v1',
  sourceSha256: hash(sourceBytes), godotSha256: hash(godotBytes), matches,
  passed: matches.length === 6 }, null, 2)}\n`);

#!/usr/bin/env node

// Independent bridge from real Godot make_wildlife constructor rows to the
// native typed geometry contract. Imported GLB hierarchies are deliberately
// excluded: the active animated asset registry remains a cutover admission.
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';

const reportPath = process.argv[2] ?? 'artifacts/native-world-backend/n4-wildlife-construction-oracle.json';
const report = JSON.parse(await readFile(reportPath, 'utf8'));
if (report.schema !== 'n4-wildlife-construction-oracle/v1' || report.passed !== true
    || report.registryReady !== true || report.cases?.length !== 6) {
  throw new Error('Expected a passing six-case direct Godot wildlife construction report.');
}

function vec(bits) {
  if (!Array.isArray(bits) || bits.length !== 3 || bits.some(v => !Number.isInteger(v) || v < 0 || v > 0xffffffff)) {
    throw new Error('Expected three valid float32 bit values.');
  }
  return bits.map(String);
}

function digestRow(row) {
  if (row.collision?.class !== 'BoxShape3D' || row.collision.disabled !== false
      || !row.visual || !row.metadata?.variant) throw new Error('Incomplete wildlife geometry row.');
  const parts = ['BoxShape3D', '0', ...vec(row.collision.centerBits), ...vec(row.collision.sizeBits),
    ...vec(row.visual.scaleBits), ...vec(row.visual.rotationBits)];
  const meshes = row.visual.meshes ?? [];
  if (row.animatedRequested === true && meshes.length !== 0) throw new Error('Animated row unexpectedly has procedural meshes.');
  if (row.animatedRequested === false && meshes.length !== 8) throw new Error('Procedural row needs eight meshes.');
  parts.push(String(meshes.length));
  for (const mesh of meshes) {
    if (!['SphereMesh', 'CylinderMesh'].includes(mesh.class)
        || !['wildlife', 'wildlifeDark'].includes(mesh.materialRole)) throw new Error('Invalid mesh kind/material.');
    parts.push(mesh.class, mesh.materialRole, ...vec(mesh.positionBits), ...vec(mesh.rotationBits),
      ...vec(mesh.scaleBits));
    for (const field of ['radiusBits', 'heightBits', 'topRadiusBits', 'bottomRadiusBits', 'radialSegments', 'rings']) {
      const value = mesh[field] ?? 0;
      if (!Number.isInteger(value) || value < 0 || value > 0xffffffff) throw new Error(`Invalid ${field}.`);
      parts.push(String(value));
    }
  }
  return createHash('sha256').update(parts.join('|')).digest('hex');
}

const rows = report.cases.map(row => {
  const digest = digestRow(row);
  if (digest !== row.geometryDigest) throw new Error(`Godot/native bridge mismatch: ${row.metadata.variant}`);
  return { biome: row.biome, seed: row.seed, variant: row.metadata.variant,
    presentation: row.animatedRequested ? 'animated_playable' : 'procedural_fallback',
    geometryGolden: digest };
});
process.stdout.write(`${JSON.stringify({ schema: 'n4-wildlife-native-geometry-goldens/v1',
  source: reportPath, importedGlbHierarchyIncluded: false, rows }, null, 2)}\n`);

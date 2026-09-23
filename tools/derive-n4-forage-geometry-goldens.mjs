#!/usr/bin/env node

// Re-encode direct Godot N4 forage construction rows in the independent,
// fixed-width geometry format used by the native decoder contract test.
// This is a fixture bridge, not gameplay or publication acceptance.
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';

const reportPath = process.argv[2] ?? 'artifacts/native-world-backend/n4-forage-construction-oracle.json';
const report = JSON.parse(await readFile(reportPath, 'utf8'));
if (report.schema !== 'n4-forage-construction-oracle/v1' || report.passed !== true || report.rows?.length !== 4) {
  throw new Error('Expected a passing four-row direct Godot forage construction report.');
}

class Writer {
  parts = [];
  u8(value) {
    if (!Number.isInteger(value) || value < 0 || value > 255) throw new Error(`Invalid u8: ${value}`);
    this.parts.push(Buffer.from([value]));
  }
  u32(value) {
    if (!Number.isInteger(value) || value < 0 || value > 0xffffffff) throw new Error(`Invalid u32: ${value}`);
    const bytes = Buffer.alloc(4);
    bytes.writeUInt32BE(value);
    this.parts.push(bytes);
  }
  u64(value) {
    const bytes = Buffer.alloc(8);
    bytes.writeBigUInt64BE(BigInt.asUintN(64, BigInt(value)));
    this.parts.push(bytes);
  }
  text(value) {
    const bytes = Buffer.from(value, 'utf8');
    this.u32(bytes.length);
    this.parts.push(bytes);
  }
  vec(bits) {
    if (!Array.isArray(bits) || bits.length !== 3) throw new Error('Expected three float32 bit values.');
    for (const value of bits) this.u32(value);
  }
  digest() { return createHash('sha256').update(Buffer.concat(this.parts)).digest('hex'); }
}

function digestRow(row) {
  if (row.physicalColliderPresent !== true || !row.collider || !Array.isArray(row.meshes)) {
    throw new Error(`Incomplete Godot forage row: ${row.biome}`);
  }
  const writer = new Writer();
  writer.u32(row.rotationBits[1]);
  writer.u32(row.collider.radiusBits);
  writer.u32(row.collider.positionBits[1]);
  writer.u8(row.navigationBlocksNpc ? 1 : 0);
  writer.u64(row.metadata.drop_count);
  writer.u64(row.finalRngState);
  writer.u32(row.meshes.length);
  for (const mesh of row.meshes) {
    const kind = mesh.meshClass === 'SphereMesh' ? 1 : mesh.meshClass === 'CylinderMesh' ? 2 : 0;
    if (!kind || !mesh.materialRole) throw new Error(`Missing mesh type/material role: ${row.biome}`);
    writer.u8(kind);
    writer.text(mesh.materialRole);
    writer.vec(mesh.positionBits);
    writer.vec(mesh.rotationBits);
    writer.vec(mesh.scaleBits);
    writer.u32(mesh.radiusBits ?? 0);
    writer.u32(mesh.heightBits);
    writer.u32(mesh.topRadiusBits ?? 0);
    writer.u32(mesh.bottomRadiusBits ?? 0);
    writer.u32(mesh.radialSegments);
    writer.u32(mesh.rings ?? 0);
  }
  return writer.digest();
}

const rows = report.rows.map(row => ({ biome: row.biome, seed: row.seed, geometryGolden: digestRow(row) }));
process.stdout.write(`${JSON.stringify({ schema: 'n4-forage-native-geometry-goldens/v1', source: reportPath, rows }, null, 2)}\n`);

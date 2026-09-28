#!/usr/bin/env node

// Extract source-owned vertex bounds from the active rock GLBs. This receipt
// describes glTF-space geometry only; Godot import and runtime scale parity
// remain separate admission steps.
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifestPath = path.join(projectRoot, 'assets/visual/generated/visual-manifest.json');
const manifestBytes = await readFile(manifestPath);
const manifest = JSON.parse(manifestBytes.toString('utf8'));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = message => { throw new Error(message); };

function glbBounds(bytes, assetId) {
  if (bytes.length < 28 || bytes.readUInt32LE(0) !== 0x46546c67 || bytes.readUInt32LE(4) !== 2
      || bytes.readUInt32LE(8) !== bytes.length) fail(`${assetId}: invalid GLB header`);
  let cursor = 12, json, binary;
  while (cursor < bytes.length) {
    if (cursor + 8 > bytes.length) fail(`${assetId}: truncated GLB chunk`);
    const length = bytes.readUInt32LE(cursor), kind = bytes.readUInt32LE(cursor + 4);
    cursor += 8;
    if (cursor + length > bytes.length) fail(`${assetId}: chunk exceeds GLB`);
    if (kind === 0x4e4f534a && json === undefined) json = JSON.parse(bytes.subarray(cursor, cursor + length).toString('utf8'));
    else if (kind === 0x004e4942 && binary === undefined) binary = bytes.subarray(cursor, cursor + length);
    cursor += length;
  }
  if (!json || !binary || json.scenes?.length !== 1 || json.scenes[0].nodes?.length !== 1
      || json.nodes?.length !== 1 || json.nodes[0].mesh !== 0 || json.meshes?.length !== 1
      || json.buffers?.length !== 1 || json.buffers[0].uri !== undefined
      || json.nodes[0].translation || json.nodes[0].rotation || json.nodes[0].scale || json.nodes[0].matrix
      || json.nodes[0].children) fail(`${assetId}: unsupported scene graph; exact transforms required`);
  const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
  let vertexCount = 0;
  for (const primitive of json.meshes[0].primitives ?? []) {
    const accessor = json.accessors?.[primitive.attributes?.POSITION];
    const view = json.bufferViews?.[accessor?.bufferView];
    if (!accessor || !view || accessor.componentType !== 5126 || accessor.type !== 'VEC3'
        || accessor.sparse || view.buffer !== 0 || !Number.isInteger(accessor.count)
        || accessor.count <= 0) fail(`${assetId}: unsupported POSITION accessor`);
    const stride = view.byteStride ?? 12;
    const start = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0);
    if (stride < 12 || start < 0 || start + (accessor.count - 1) * stride + 12 > binary.length
        || start + (accessor.count - 1) * stride + 12 > (view.byteOffset ?? 0) + view.byteLength)
      fail(`${assetId}: POSITION bytes exceed buffer view`);
    const localMin = [Infinity, Infinity, Infinity], localMax = [-Infinity, -Infinity, -Infinity];
    for (let i = 0; i < accessor.count; i++) for (let axis = 0; axis < 3; axis++) {
      const value = binary.readFloatLE(start + i * stride + axis * 4);
      if (!Number.isFinite(value)) fail(`${assetId}: nonfinite vertex`);
      localMin[axis] = Math.min(localMin[axis], value);
      localMax[axis] = Math.max(localMax[axis], value);
      min[axis] = Math.min(min[axis], value);
      max[axis] = Math.max(max[axis], value);
    }
    if (accessor.min?.some((value, axis) => value !== localMin[axis])
        || accessor.max?.some((value, axis) => value !== localMax[axis]))
      fail(`${assetId}: declared POSITION bounds differ from vertex bytes`);
    vertexCount += accessor.count;
  }
  if (!vertexCount) fail(`${assetId}: no POSITION vertices`);
  return { min, max, vertexCount, primitiveCount: json.meshes[0].primitives.length,
    identitySceneTransform: true };
}

const rows = [];
for (const asset of manifest.assets ?? []) {
  if (asset.family !== 'rock' || asset.runtimeEnabled === false) continue;
  if (!/^assets\/visual\/generated\/environment\/rock_[0-9]{2}\.glb$/.test(asset.path))
    fail(`${asset.id}: unexpected active rock path`);
  const bytes = await readFile(path.join(projectRoot, asset.path));
  rows.push({ id: asset.id, path: asset.path, glbSha256: hash(bytes), ...glbBounds(bytes, asset.id) });
}
if (rows.length !== 6 || new Set(rows.map(row => row.id)).size !== 6) fail('Expected six distinct active rock GLBs');
const receipt = { schema: 'n4-rock-glb-source-bounds/v1',
  manifestSha256: hash(manifestBytes), rows };
process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);

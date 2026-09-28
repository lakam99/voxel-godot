import { createHash } from 'node:crypto';

const textEncoder = new TextEncoder();

function u32(value) {
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32LE(value >>> 0);
  return bytes;
}

function u64(value) {
  const bytes = Buffer.alloc(8);
  bytes.writeBigUInt64LE(BigInt.asUintN(64, BigInt(value)));
  return bytes;
}

function i32(value) {
  const bytes = Buffer.alloc(4);
  bytes.writeInt32LE(value);
  return bytes;
}

function stringBytes(value) {
  const bytes = Buffer.from(textEncoder.encode(value));
  return Buffer.concat([u32(bytes.length), bytes]);
}

function binary64Bits(value) {
  const bytes = Buffer.alloc(8);
  bytes.writeDoubleLE(value);
  return bytes.readBigUInt64LE();
}

function legacyHash(codePoints) {
  let hash = 2166136261;
  for (const codePoint of codePoints) hash = Math.imul((hash ^ codePoint) >>> 0, 16777619) >>> 0;
  return hash;
}

export function referenceFrozenSourceIdentity(seedText = 'atlas-1492') {
  const seed = [...seedText].map(character => character.codePointAt(0));
  const recipes = [
    ['building.interior_program', 2], ['building.navigation_manifest', 9], ['building.terrain_profile', 1],
    ['citadel.generation_policy', 1], ['citadel.site_field', 1], ['citadel.survey_policy', 1],
    ['courtyard.placement', 1], ['furnishing.navigation_manifest', 2], ['landmark.recipe', 1],
    ['town.runtime_manifest', 1], ['tree.bushy_oak', 21], ['tree.conifer', 2],
    ['tree.procedural_grammar', 2], ['tree.savanna', 2], ['tree.spawn', 10],
  ].sort(([left], [right]) => Buffer.compare(Buffer.from(left), Buffer.from(right)));
  const constants = [
    ['CELL', 2, binary64Bits(1.35)], ['SECTION_SIZE', 1, 16n], ['CHUNK_SIZE', 1, 28n],
    ['MIN_HEIGHT', 2, binary64Bits(4.0)], ['MAX_HEIGHT', 2, binary64Bits(120.0)],
    ['WATER_LEVEL', 2, binary64Bits(11.1)], ['TOWN_REGION_CELLS', 1, 280n],
    ['WORLD_BOTTOM_CELL_Y', 1, BigInt.asUintN(32, -64n)],
  ].sort(([left], [right]) => Buffer.compare(Buffer.from(left), Buffer.from(right)));
  const parts = [Buffer.from('VWBK'), u32(1), u32(seed.length), ...seed.map(u32), u32(legacyHash(seed)),
    stringBytes('legacy-preservation-tree/cfcc96f2ebcb6a4c171cd37aca52fff6b65a6d8e'), u32(2),
    u32(recipes.length)];
  for (const [name, revision] of recipes) parts.push(stringBytes(name), u32(revision));
  // N0 §4.1 order: recipe/schema map, save/delta schema revisions, constants.
  parts.push(u32(2), u32(1), u32(constants.length));
  for (const [name, encoding, bits] of constants) {
    parts.push(stringBytes(name), Buffer.from([encoding]), encoding === 1 ? u32(Number(bits)) : u64(bits));
  }
  const bytes = Buffer.concat(parts);
  return {
    bytes,
    bytesHex: bytes.toString('hex'),
    digestHex: createHash('sha256').update(bytes).digest('hex'),
    legacyHash: legacyHash(seed),
  };
}

export function referenceFrozenSnapshotIdentity() {
  const source = referenceFrozenSourceIdentity();
  const bytes = Buffer.concat([
    Buffer.from('VWSN'), u32(1), u32(32), Buffer.from(source.digestHex, 'hex'),
    i32(-16), i32(-64), i32(-16), i32(16), i32(128), i32(16),
    u32(2), u64(1), u64(4), u32(1), u64(9), u64(7),
  ]);
  return { bytes, bytesHex: bytes.toString('hex'), digestHex: createHash('sha256').update(bytes).digest('hex') };
}

export function referenceFrozenArtifactIdentity() {
  const snapshot = referenceFrozenSnapshotIdentity();
  const bytes = Buffer.concat([
    Buffer.from('VWAR'), u32(1), u32(32), Buffer.from(snapshot.digestHex, 'hex'),
    Buffer.from([2]), u32(4), u32(5), u32(0),
    stringBytes('density+material'), stringBytes('half-open-owner'), stringBytes('one-cell-both-sides'),
  ]);
  return { bytes, bytesHex: bytes.toString('hex'), digestHex: createHash('sha256').update(bytes).digest('hex') };
}

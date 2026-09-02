#!/usr/bin/env node
// Artifact-only positive old-volume witnesses. Never clearance/concealment proof.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const CANDIDATE = 'f23ee5968eea292477f7ff5ef9081e97ad0cca52069ab7f79202f5f912204ee1';
const CHANNEL = 'CPU_neighbour_render_envelope';
const LIMITS = Object.freeze({ bytes: 64 * 1024 * 1024, rows: 4096, cells: 4096,
  houses: 64, parts: 4096, primitivesPerPart: 32768, totalPrimitives: 262144,
  perContactWork: 250000, totalWork: 16000000, seconds: 60, coordinate: 100000 });
const SCOPE = 'Positive coverage by original published cardinal BOX primitives of the owning house only. '
  + 'The target is a framing-box/reported-neighbour-envelope intersection, not proof of actual rotated-neighbour intersection. '
  + 'Uncovered cells are unproven by this subset, NOT absent from all old geometry. '
  + 'Missing original peer payload leaves the contact unresolved even when original owned-volume coverage is complete. '
  + 'Never collision clearance, visual acceptance, concealment, absence of z-fighting, rooted support, GPU or live gameplay acceptance.';
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const jsonHash = value => hash(JSON.stringify(value));
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
function requireThat(ok, reason) { if (!ok) throw new Error(reason); }
function numbers(a, n) { return Array.isArray(a) && a.length === n && a.every(v => typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= LIMITS.coordinate); }
function validBox(b) { return numbers(b, 6) && [0, 1, 2].every(i => b[i] < b[i + 3]); }
function same(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
function ids(values, label) {
  requireThat(Array.isArray(values) && values.length <= LIMITS.parts && values.every(v => typeof v === 'string' && v.length > 0), `invalid_ids:${label}`);
  requireThat(new Set(values).size === values.length, `duplicate_ids:${label}`);
  return values;
}
function setEqual(a, b) { return a.length === b.length && a.every(id => b.includes(id)); }
function mapIds(map, label) {
  requireThat(object(map) && Object.values(map).every(v => v === true), `invalid_id_map:${label}`);
  return ids(Object.keys(map), label);
}
function intersection(a, b) {
  requireThat(validBox(a) && validBox(b), 'invalid_intersection_box');
  const r = [0, 1, 2].map(i => Math.max(a[i], b[i]));
  r.push(...[0, 1, 2].map(i => Math.min(a[i + 3], b[i + 3])));
  return validBox(r) ? r : null;
}
function difference(cell, cut) {
  const overlap = intersection(cell, cut);
  if (!overlap) return { cells: [cell.slice()], overlap: null };
  const rest = cell.slice(), cells = [];
  for (let i = 0; i < 3; i++) {
    if (rest[i] < overlap[i]) { const low = rest.slice(); low[i + 3] = overlap[i]; cells.push(low); rest[i] = overlap[i]; }
    if (rest[i + 3] > overlap[i + 3]) { const high = rest.slice(); high[i] = overlap[i + 3]; cells.push(high); rest[i + 3] = overlap[i + 3]; }
  }
  requireThat(cells.every(validBox), 'nonpositive_difference_cell');
  return { cells, overlap };
}
function cover(region, boxes, budget = { work: 0, started: Date.now() }) {
  requireThat(validBox(region) && boxes.length <= LIMITS.primitivesPerPart, 'invalid_cover_input');
  let cells = [region.slice()], work = 0;
  const witnesses = [];
  // Sorting the actual primitive identities gives deterministic partition ownership.
  for (const box of [...boxes].sort((a, b) => a.key < b.key ? -1 : a.key > b.key ? 1 : 0)) {
    requireThat(validBox(box.bounds), 'invalid_witness_box');
    const next = [];
    for (const cell of cells) {
      requireThat(++work <= LIMITS.perContactWork && ++budget.work <= LIMITS.totalWork && Date.now() - budget.started <= LIMITS.seconds * 1000, 'partition_work_limit');
      const result = difference(cell, box.bounds);
      next.push(...result.cells);
      if (result.overlap) witnesses.push({ primitiveKey: box.key, partId: box.partId, primitiveId: box.primitiveId, cell: result.overlap });
      requireThat(next.length <= LIMITS.cells && witnesses.length <= LIMITS.cells, 'partition_cell_limit');
    }
    cells = next;
    if (cells.length === 0) break;
  }
  return { covered: cells.length === 0, witnesses, uncoveredCells: cells, work };
}

// Godot Transform3D stores float32 components, exported here as 15-significant-
// digit JSON numbers. Require exact decimal round-trip before recovery; this is
// representation decoding, NOT a geometric tolerance or a padded bound.
function recover32(v) {
  requireThat(typeof v === 'number' && Number.isFinite(v), 'nonfinite_transform');
  const stored = Math.fround(v);
  requireThat(Number.isFinite(stored) && Number(stored.toPrecision(15)) === v, 'unresolved_float32_transform_encoding');
  return stored;
}
function transform(t) {
  requireThat(object(t) && numbers(t.origin, 3) && Array.isArray(t.basis) && t.basis.length === 3 && t.basis.every(c => numbers(c, 3)), 'invalid_transform');
  return { origin: t.origin.map(recover32), basis: t.basis.map(c => c.map(recover32)) };
}
function cardinalBounds(t) {
  const used = new Set();
  for (const column of t.basis) {
    const nonzero = column.map((v, i) => v !== 0 ? i : -1).filter(i => i !== -1);
    if (nonzero.length !== 1 || used.has(nonzero[0])) return null;
    used.add(nonzero[0]);
  }
  const radius = [0, 1, 2].map(i => t.basis.reduce((sum, col) => sum + Math.abs(col[i]) * 0.5, 0));
  const bounds = [...t.origin.map((v, i) => v - radius[i]), ...t.origin.map((v, i) => v + radius[i])];
  requireThat(validBox(bounds), 'invalid_cardinal_bounds');
  return bounds;
}
function unitBox(p) {
  return p.type === 'box' && p.meshClass === 'BoxMesh' && p.meshDigest === 'unit_box'
    && same(p.localMeshBounds, { position: [-0.5, -0.5, -0.5], size: [1, 1, 1] });
}
function channel(payload, partId, name) {
  const result = payload[partId]?.[name];
  requireThat(object(result) && result.status === 'published' && Array.isArray(result.primitives)
    && result.primitives.length > 0 && result.primitives.length <= LIMITS.primitivesPerPart, `missing_published_payload:${partId}:${name}`);
  ids(result.primitives.map(p => p.id), `primitives:${partId}:${name}`);
  return result.primitives;
}
function originalBoxes(payload, partIds) {
  const boxes = [], skipped = [];
  for (const partId of partIds) {
    channel(payload, partId, 'visual').forEach((p, index) => {
      const key = `${partId}/visual/${index}/${p.id}`;
      if (!unitBox(p)) { skipped.push({ key, type: p.type, reason: 'unsupported_primitive_not_an_absence_claim' }); return; }
      let t, bounds;
      try { t = transform(p.transform); bounds = cardinalBounds(t); }
      catch (error) { skipped.push({ key, type: p.type, reason: error.message }); return; }
      if (!bounds) { skipped.push({ key, type: p.type, reason: 'noncardinal_box_envelope_not_coverage' }); return; }
      boxes.push({ key, partId, primitiveId: p.id, primitiveIndex: index, transform: t, bounds });
    });
  }
  requireThat(boxes.length + skipped.length <= LIMITS.primitivesPerPart, 'house_primitive_limit');
  return { boxes, skipped };
}
function validateClosure(publication, before, after) {
  requireThat(publication.passed === true && publication.diagnosticCompleted === true && publication.status === 'measurement_complete'
    && object(publication.checks) && Object.values(publication.checks).every(v => v === true), 'publication_not_complete_and_passed');
  const closure = publication.validatedClosure;
  requireThat(object(closure) && closure.ready === true && object(closure.houseScopes), 'missing_validated_closure');
  const houses = Object.keys(closure.houseScopes);
  requireThat(houses.length === 16 && houses.length <= LIMITS.houses, 'house_coverage_mismatch');
  requireThat(Array.isArray(publication.houseProofs) && publication.houseProofs.length === houses.length, 'missing_house_proofs');
  ids(publication.houseProofs.map(h => h.house), 'proof_houses');
  const owners = new Map(), frameTransforms = new Map(), common = new Set(), framing = [], witnessScopes = {};
  for (const house of houses) {
    const scope = closure.houseScopes[house];
    const proofs = publication.houseProofs.filter(h => h.house === house);
    requireThat(proofs.length === 1 && proofs[0].passed === true && same(proofs[0].closure, scope), `unbound_house_closure:${house}`);
    const ownFrames = ids(scope.framingIds, `${house}:frames`);
    requireThat(ownFrames.length >= 1 && ownFrames.length <= 3 && ownFrames[0] === proofs[0].headerId, 'invalid_framing_grammar');
    const trims = ids(scope.trimIds, `${house}:trims`), gables = ids(scope.gableIds, `${house}:gables`), direct = ids(scope.directPeerIds, `${house}:direct`);
    requireThat(trims.length === 7 && gables.length === 2 && direct.length <= 2, 'invalid_common_grammar');
    const sourceIds = [...new Set([...trims, ...gables, ...direct])];
    requireThat(setEqual(ids(scope.commonIds, `${house}:common`), sourceIds), 'common_not_exact_declared_closure');
    for (const id of sourceIds) { requireThat(Object.hasOwn(before, id) && Object.hasOwn(after, id), `missing_common_payload:${id}`); common.add(id); }
    const captures = proofs[0].framingPublication;
    requireThat(Array.isArray(captures) && setEqual(ids(captures.map(c => c.partId), 'frame_captures'), ownFrames), 'missing_source_framing_transform');
    for (const id of ownFrames) {
      requireThat(!owners.has(id) && !Object.hasOwn(before, id), `duplicate_or_preexisting_framing:${id}`);
      owners.set(id, house); framing.push(id);
      const source = captures.find(c => c.partId === id);
      const primitives = channel(after, id, 'visual');
      requireThat(primitives.length === 1 && unitBox(primitives[0]) && source.preserveBearingFaces === true, 'framing_not_one_actual_unit_box');
      const t = transform(primitives[0].transform), sourceTransform = transform(source.sourceTransform);
      requireThat(same(t, sourceTransform) && cardinalBounds(t) !== null, `source_publication_transform_mismatch:${id}`);
      frameTransforms.set(id, { transform: t, bounds: cardinalBounds(t), primitiveId: primitives[0].id });
    }
    witnessScopes[house] = { originalPartIds: sourceIds, ...originalBoxes(before, sourceIds) };
  }
  requireThat(setEqual(framing, mapIds(closure.framing, 'closure_frames')) && setEqual(framing, ids(publication.framingIds, 'publication_frames')), 'framing_closure_mismatch');
  requireThat(same(framing, closure.appendOrder), 'framing_append_order_mismatch');
  requireThat(setEqual([...common], mapIds(closure.common, 'closure_common')) && setEqual(Object.keys(before), [...common]), 'before_payload_membership_mismatch');
  requireThat(setEqual(Object.keys(after), [...common, ...framing]) && setEqual(Object.keys(after), mapIds(closure.selected, 'closure_selected')), 'after_payload_membership_mismatch');
  requireThat(publication.publicationPasses?.length === 2 && publication.publicationPasses.every(p => p.complete === true && p.executedPartCount === p.expectedPartCount && p.executedOrderDigest === p.expectedOrderDigest), 'incomplete_publication_order');
  requireThat(publication.publicationPasses[0].executedOrderDigest === closure.sourcePrefixOrderDigest, 'original_order_binding_mismatch');
  const totalPrimitives = Object.values(witnessScopes).reduce((sum, s) => sum + s.boxes.length + s.skipped.length, 0);
  requireThat(totalPrimitives <= LIMITS.totalPrimitives, 'total_primitive_limit');
  return { owners, frameTransforms, witnessScopes, totalPrimitives, beforePayloads: before };
}
function rowIdentity(clearanceSHA, index, row) {
  return { rowId: `${clearanceSHA}:blockedOrUnresolved:${index}`, sourceArrayIndex: index, inputRowSHA256: jsonHash(row) };
}
function classifyRow(row, index, clearanceSHA, context, budget) {
  const base = { ...rowIdentity(clearanceSHA, index, row), inputRow: row, classification: 'unproven', coverageEstablished: false, witnesses: [], uncoveredCells: [] };
  let region = null;
  try {
    requireThat(row.channel === CHANNEL && typeof row.headerId === 'string' && typeof row.obstacleId === 'string' && validBox(row.headerBounds) && validBox(row.obstacleBounds), 'invalid_contact_row');
    const house = context.owners.get(row.headerId);
    requireThat(house !== undefined, 'framing_without_unique_owner');
    const frame = context.frameTransforms.get(row.headerId);
    base.originalPeer = { available: false, partId: row.obstacleId, reason: 'original_peer_payload_not_captured' };
    if (Object.hasOwn(context.beforePayloads, row.obstacleId)) {
      const peer = channel(context.beforePayloads, row.obstacleId, 'visual');
      base.originalPeer = { available: true, partId: row.obstacleId, primitiveCount: peer.length,
        visualPayloadSHA256: jsonHash(context.beforePayloads[row.obstacleId].visual),
        scope: 'Original capture available; no source-only inference of unchanged published peer bounds or row-to-peer-primitive correspondence.' };
    }
    base.house = house; base.framingId = row.headerId; base.framingTransform = frame.transform;
    base.rawFramingBounds = frame.bounds;
    base.reportedOverlap = intersection(row.headerBounds, row.obstacleBounds);
    region = intersection(frame.bounds, row.obstacleBounds);
    base.overlapRegion = region;
    // Exact reported-decimal identity, not an epsilon comparison. Tied/unknown
    // exporter rounding stays unproven; never silently realign the contact.
    requireThat(same(frame.bounds.map(v => Number(v.toPrecision(15))), row.headerBounds), 'unproven_header_interval_serialization_binding');
    requireThat(region !== null, 'no_positive_bound_overlap_not_an_absence_claim');
    const result = cover(region, context.witnessScopes[house].boxes, budget);
    return { ...base, ...result, originalOwnedVolumeCoverageEstablished: result.covered,
      classification: !base.originalPeer.available ? 'unresolved_original_peer_payload_missing'
        : result.covered ? 'retained_original_published_cardinal_occupancy' : 'unproven_by_original_cardinal_subset',
      coverageEstablished: result.covered && base.originalPeer.available };
  } catch (error) {
    return { ...base, reason: error.message, uncoveredCells: region ? [region] : [], uncoveredMeaning: 'Unproven target; no absence claim.' };
  }
}

function readBound(file, sha) {
  requireThat(typeof file === 'string' && path.isAbsolute(file), 'absolute_input_required');
  requireThat(/^[a-f0-9]{64}$/.test(sha ?? ''), 'explicit_sha256_required');
  const stat = fs.statSync(file);
  requireThat(stat.isFile() && stat.size > 0 && stat.size <= LIMITS.bytes, 'input_byte_limit');
  const bytes = fs.readFileSync(file);
  requireThat(bytes.length === stat.size && hash(bytes) === sha, `input_hash_mismatch:${file}`);
  const value = JSON.parse(bytes.toString('utf8'));
  requireThat(object(value), 'input_not_json_object');
  return { path: file, sha256: sha, bytes: bytes.length, value };
}
function artifactBinding(record, input) {
  requireThat(object(record) && record.ready === true && record.sha256 === input.sha256 && record.bytes === input.bytes
    && record.partCount === Object.keys(input.value).length && typeof record.path === 'string' && path.resolve(record.path) === path.resolve(input.path), 'payload_artifact_chain_mismatch');
}
function parseArgs(argv) {
  const required = ['clearance', 'clearance-sha256', 'publication', 'publication-sha256', 'before', 'before-sha256', 'after', 'after-sha256', 'candidate-sha256', 'output'];
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i]?.slice(2);
    requireThat(argv[i]?.startsWith('--') && required.includes(key) && !Object.hasOwn(args, key) && typeof argv[i + 1] === 'string' && !argv[i + 1].startsWith('--'), 'unknown_duplicate_or_missing_argument');
    args[key] = argv[i + 1];
  }
  requireThat(required.every(k => Object.hasOwn(args, k)), `required_arguments:${required.join(',')}`);
  for (const key of ['clearance', 'publication', 'before', 'after', 'output']) requireThat(path.isAbsolute(args[key]), `absolute_path_required:${key}`);
  for (const key of required.filter(k => k.endsWith('sha256'))) requireThat(/^[a-f0-9]{64}$/.test(args[key]), `invalid_hash:${key}`);
  requireThat(args['candidate-sha256'] === CANDIDATE, 'not_current_bound_candidate');
  return args;
}
function classify(args) {
  requireThat(!fs.existsSync(args.output) && fs.statSync(path.dirname(args.output)).isDirectory(), 'fresh_output_existing_parent_required');
  const clearance = readBound(args.clearance, args['clearance-sha256']), publication = readBound(args.publication, args['publication-sha256']);
  const before = readBound(args.before, args['before-sha256']), after = readBound(args.after, args['after-sha256']);
  const c = clearance.value, p = publication.value;
  requireThat(c.candidateSha256 === args['candidate-sha256'] && p.inputSha256 === c.candidateSha256
    && path.isAbsolute(c.candidatePath) && path.isAbsolute(p.inputPath) && path.resolve(c.candidatePath) === path.resolve(p.inputPath), 'candidate_chain_mismatch');
  requireThat(c.status === 'measurement_complete' && c.stopReason === '' && c.checks?.complete_bounded_geometry_coverage === true
    && c.checks?.every_added_framing_piece_examined === true && c.checks?.inputs_immutable === true, 'incomplete_clearance_measurement');
  artifactBinding(p.beforePayloadArtifact, before); artifactBinding(p.afterPayloadArtifact, after);
  const context = validateClosure(p, before.value, after.value);
  requireThat(setEqual(ids(c.headerIds, 'clearance_frames'), [...context.owners.keys()]), 'clearance_framing_scope_mismatch');
  requireThat(c.executedSourceOrderDigest === p.publicationPasses[1].executedOrderDigest, 'clearance_publication_order_mismatch');
  requireThat(Array.isArray(c.blockedOrUnresolved) && c.blockedOrUnresolved.length <= LIMITS.rows, 'contact_row_limit');
  const inputRows = c.blockedOrUnresolved.map((row, index) => ({ row, index })).filter(r => r.row.channel === CHANNEL);
  requireThat(inputRows.length === 341, 'current_render_inventory_not_341');
  const budget = { work: 0, started: Date.now() };
  const contacts = inputRows.map(({ row, index }) => classifyRow(row, index, clearance.sha256, context, budget));
  const identities = contacts.map(r => r.rowId);
  requireThat(new Set(identities).size === inputRows.length, 'duplicate_output_row_identity');
  const duplicateContent = {};
  for (const row of contacts) (duplicateContent[row.inputRowSHA256] ??= []).push(row.rowId);
  const inputs = { clearance, publication, before, after };
  for (const record of Object.values(inputs)) requireThat(hash(fs.readFileSync(record.path)) === record.sha256, 'input_changed_during_measurement');
  const counts = { renderInputRows: inputRows.length, outputRows: contacts.length, retainedPositiveCoverage: contacts.filter(r => r.coverageEstablished).length,
    originalOwnedVolumeCovered: contacts.filter(r => r.originalOwnedVolumeCoverageEstablished).length,
    unresolvedOriginalPeerMissing: contacts.filter(r => r.classification === 'unresolved_original_peer_payload_missing').length,
    uncoveredByCardinalSubset: contacts.filter(r => r.classification === 'unproven_by_original_cardinal_subset').length,
    bindingOrWorkUnproven: contacts.filter(r => r.classification === 'unproven').length, partitionWork: budget.work };
  const report = { measurementComplete: contacts.length === inputRows.length, acceptanceClaim: false, scope: SCOPE, candidateSHA256: args['candidate-sha256'],
    candidateBinding: 'Matching SHA identities in both explicitly hash-verified reports; candidate binary is not independently decoded here.',
    inputs: Object.fromEntries(Object.entries(inputs).map(([k, r]) => [k, { path: r.path, sha256: r.sha256, bytes: r.bytes }])),
    command: process.argv, classifierSHA256: hash(fs.readFileSync(fileURLToPath(import.meta.url))), limits: LIMITS, counts,
    arithmetic: 'Recovered exact float32 Transform3D components after decimal round-trip checks; scalar64 interval subtraction, no epsilon. No padded payload bounds, source wall boxes, or rotated envelopes used as coverage witnesses.',
    excludedNonRenderRows: c.blockedOrUnresolved.flatMap((row, index) => row.channel === CHANNEL ? [] : [{ sourceArrayIndex: index, channel: row.channel }]),
    repeatedInputRowsPreserved: Object.entries(duplicateContent).filter(([, rows]) => rows.length > 1).map(([sha256, rows]) => ({ sha256, rows })),
    publicationClosure: p.validatedClosure, originalWitnessScopes: context.witnessScopes, contacts };
  writeFresh(args.output, report);
  return { output: args.output, sha256: hash(fs.readFileSync(args.output)), ...counts, acceptanceClaim: false };
}
function writeFresh(output, report) {
  const bytes = Buffer.from(JSON.stringify(report, null, 2) + '\n');
  requireThat(bytes.length <= LIMITS.bytes, 'output_byte_limit');
  const fd = fs.openSync(output, 'wx');
  try { fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  requireThat(hash(fs.readFileSync(output)) === hash(bytes), 'output_readback_hash_mismatch');
}

function selfTest() {
  const u = [0, 0, 0, 1, 1, 1], box = (key, bounds) => ({ key, bounds, partId: 'synthetic', primitiveId: key });
  const solids = [box('left', [0, 0, 0, 0.5, 1, 1]), box('right', [0.5, 0, 0, 1, 1, 1])];
  const frozen = JSON.stringify(solids);
  assert.equal(cover(u, solids).covered, true);
  const gap = cover(u, [solids[0], box('right', [0.5 + 1e-8, 0, 0, 1, 1, 1])]);
  assert.equal(gap.covered, false); assert.deepEqual(gap.uncoveredCells, [[0.5, 0, 0, 0.5 + 1e-8, 1, 1]]);
  assert.deepEqual(cover(u, solids), cover(u, [...solids].reverse())); assert.equal(JSON.stringify(solids), frozen);
  assert.equal(cover(u, [box('touch', [1, 0, 0, 2, 1, 1])]).covered, false);
  assert.deepEqual(cardinalBounds({ origin: [0, 0, 0], basis: [[0, -2, 0], [3, 0, 0], [0, 0, 4]] }), [-1.5, -1, -2, 1.5, 1, 2]);
  assert.equal(cardinalBounds({ origin: [0, 0, 0], basis: [[1, 0.25, 0], [0, 1, 0], [0, 0, 1]] }), null);
  const primitive = { type: 'box', meshClass: 'BoxMesh', meshDigest: 'unit_box', id: 'rotated', localMeshBounds: { position: [-0.5, -0.5, -0.5], size: [1, 1, 1] }, transform: { origin: [0.5, 0.5, 0.5], basis: [[2, 0.25, 0], [0, 2, 0], [0, 0, 2]] } };
  const subset = originalBoxes({ synthetic: { visual: { status: 'published', primitives: [primitive] } } }, ['synthetic']);
  assert.equal(subset.boxes.length, 0); assert.equal(subset.skipped.length, 1); assert.equal(cover(u, subset.boxes).covered, false);
  assert.throws(() => parseArgs([])); assert.throws(() => parseArgs(['--clearance', '/a', '--clearance', '/b']));
  assert.throws(() => readBound('relative.json', '0'.repeat(64))); assert.throws(() => channel({}, 'missing', 'visual'));
  assert.throws(() => ids(['same', 'same'], 'duplicate_scope'));
  const a = rowIdentity('a'.repeat(64), 1, { primitive: 'actual_box' }), b = rowIdentity('a'.repeat(64), 2, { primitive: 'actual_box' });
  assert.notEqual(a.rowId, b.rowId); assert.equal(a.inputRowSHA256, b.inputRowSHA256);
  assert.throws(() => cover([0, 0, 0, 0, 1, 1], solids));
  assert.throws(() => cover(u, solids, { work: LIMITS.totalWork, started: Date.now() }));
  const wrong = classifyRow({ channel: CHANNEL, headerId: 'missing', obstacleId: 'x', headerBounds: u, obstacleBounds: u }, 0, 'a'.repeat(64), { owners: new Map() }, { work: 0, started: Date.now() });
  assert.equal(wrong.coverageEstablished, false); assert.equal(wrong.classification, 'unproven');
  const context = { owners: new Map([['frame', 'house']]), beforePayloads: {},
    frameTransforms: new Map([['frame', { bounds: u, transform: primitive.transform }]]),
    witnessScopes: { house: { boxes: solids } } };
  const missingPeer = classifyRow({ channel: CHANNEL, headerId: 'frame', obstacleId: 'uncaptured', headerBounds: u, obstacleBounds: u }, 3, 'a'.repeat(64), context, { work: 0, started: Date.now() });
  assert.equal(missingPeer.originalOwnedVolumeCoverageEstablished, true);
  assert.equal(missingPeer.coverageEstablished, false);
  assert.equal(missingPeer.classification, 'unresolved_original_peer_payload_missing');
  return { syntheticControlsPassed: true, scope: SCOPE };
}

try {
  const args = process.argv.slice(2);
  console.log(JSON.stringify(args.length === 1 && args[0] === '--self-test' ? selfTest() : classify(parseArgs(args)), null, 2));
} catch (error) {
  console.error(JSON.stringify({ measurementComplete: false, acceptanceClaim: false, error: error.message }));
  process.exitCode = 2;
}

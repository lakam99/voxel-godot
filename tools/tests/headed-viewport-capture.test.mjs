// Behavioral Node contract for the headed evidence helper's viewport receipt protocol.
// The PNGs and receipts here are synthetic; this file does not prove rendered visuals.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { deflateSync } from 'node:zlib';
import { createHeadedTestEvidence } from '../lib/headed-test-evidence.mjs';

const RECEIPT_SCHEMA = 'voxel-automated-test-viewport-capture-receipt/v1';
const VIEWPORT_CAPTURE_TYPE = 'godot-rendered-viewport';

function temporary(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'headed-viewport-capture-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function makeRun(root, { captureMode = 'godot_viewport' } = {}) {
  const runId = '2468ace013579bdf2468ace013579bdf';
  const runnerId = 'headed-viewport-capture-contract';
  const outputDirectory = path.join(root, 'artifacts', 'nested-run', 'he');
  const evidence = createHeadedTestEvidence({
    projectPath: root,
    runnerId,
    runId,
    outputDirectory,
    sourceIdentity: { branch: 'fixture', head: 'a'.repeat(40), sourceSha256: { 'fixture.gd': 'b'.repeat(64) } },
    captureMode,
  });
  const status = evidence.publishPhase('candidate_search', 'harness', 'contract phase');
  fs.writeFileSync(evidence.metadata.liveOwnershipPath, JSON.stringify({
    schema: 'godot-live-ownership/v1',
    state: 'running',
    runId,
  }));
  return { evidence, runId, runnerId, status };
}

async function waitForJson(filePath, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(filePath)) return JSON.parse(fs.readFileSync(filePath, 'utf8'));
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  throw new Error(`Timed out waiting for helper request: ${filePath}`);
}

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) {
      crc = (crc & 1) ? (0xedb88320 ^ (crc >>> 1)) : (crc >>> 1);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const typeBytes = Buffer.from(type, 'ascii');
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([typeBytes, data])));
  return Buffer.concat([length, typeBytes, data, checksum]);
}

function syntheticPng(width = 2, height = 1) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6; // RGBA
  const rows = [];
  for (let y = 0; y < height; y++) {
    rows.push(Buffer.from([0])); // PNG filter: None
    rows.push(Buffer.from(Array.from({ length: width * 4 }, (_, i) => (i * 37 + y * 19) % 256)));
  }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk('IHDR', header),
    pngChunk('IDAT', deflateSync(Buffer.concat(rows))),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

function receiptFromRequest(request, overrides = {}) {
  return {
    schema: RECEIPT_SCHEMA,
    captureType: VIEWPORT_CAPTURE_TYPE,
    captureId: request.captureId,
    runnerId: request.runnerId,
    runId: request.runId,
    watchdogRunId: request.watchdogRunId,
    statusSequence: request.statusSequence,
    phase: request.phase,
    phaseKind: request.phaseKind,
    captureName: request.captureName,
    sourceIdentityJson: request.sourceIdentityJson,
    sourceIdentitySha256: request.sourceIdentitySha256,
    capturePath: request.capturePath,
    receiptPath: request.receiptPath,
    captured: true,
    width: 2,
    height: 1,
    screenshotBytes: 0,
    capturedAtUnixMilliseconds: Date.now(),
    ...overrides,
  };
}

test('fresh nested evidence setup preserves the default owned-window environment', t => {
  const root = temporary(t);
  const { evidence } = makeRun(root, { captureMode: 'owned_window' });

  assert.equal(fs.statSync(evidence.metadata.outputDirectory).isDirectory(), true);
  assert.equal(fs.statSync(evidence.metadata.captureDirectory).isDirectory(), true);
  const env = evidence.environment();
  assert.equal(env.VOXEL_AUTOMATED_TEST_CAPTURE_MODE, 'owned_window');
  assert.equal(env.VOXEL_AUTOMATED_TEST_RUN_ID, evidence.metadata.runId);
  assert.equal(env.VOXEL_AUTOMATED_TEST_VIEWPORT_CAPTURE_REQUEST, undefined);
  assert.equal(env.VOXEL_AUTOMATED_TEST_VIEWPORT_CAPTURE_RECEIPT, undefined);

  assert.throws(() => createHeadedTestEvidence({
    projectPath: root,
    runnerId: 'second-run',
    runId: '13579bdf2468ace013579bdf2468ace0',
    outputDirectory: evidence.metadata.outputDirectory,
  }));
});

test('viewport capture rejects a receipt bound to another run', async t => {
  const root = temporary(t);
  const { evidence, runId } = makeRun(root);
  const pending = evidence.captureScreenshot({ name: 'candidate-search', phase: 'candidate_search', phaseKind: 'harness' });
  try {
    const request = await waitForJson(evidence.metadata.viewportCaptureRequestPath);
    assert.equal(request.runId, runId);
    assert.equal(request.sourceIdentitySha256, evidence.metadata.sourceIdentitySha256);
    fs.writeFileSync(evidence.metadata.viewportCaptureReceiptPath, JSON.stringify(
      receiptFromRequest(request, { runId: 'ffffffffffffffffffffffffffffffff' }),
    ));

    await assert.rejects(pending, /viewport receipt does not match the exact run/i);
    assert.equal(fs.existsSync(request.capturePath), false);
    assert.equal(fs.readFileSync(evidence.metadata.captureManifestPath, 'utf8').trim(), '');
  } finally {
    await pending.catch(() => {});
  }
});

test('viewport capture accepts a matching receipt and hashes the supplied PNG bytes', async t => {
  const root = temporary(t);
  const { evidence, runId, runnerId, status } = makeRun(root);
  const image = syntheticPng();
  const pending = evidence.captureScreenshot({ name: 'candidate-search', phase: 'candidate_search', phaseKind: 'harness' });
  let row, expectedRequest;
  try {
    const request = await waitForJson(evidence.metadata.viewportCaptureRequestPath);
    expectedRequest = request;
    assert.equal(request.statusSequence, status.sequence);
    assert.equal(request.sourceIdentitySha256, evidence.metadata.sourceIdentitySha256);
    fs.writeFileSync(request.capturePath, image);
    fs.writeFileSync(evidence.metadata.viewportCaptureReceiptPath, JSON.stringify(
      receiptFromRequest(request, { screenshotBytes: image.length }),
    ));
    row = await pending;
  } finally {
    await pending.catch(() => {});
  }

  assert.equal(row.captureType, VIEWPORT_CAPTURE_TYPE);
  assert.equal(row.captureId, `${runId}:${String(status.sequence).padStart(6, '0')}`);
  assert.equal(row.runnerId, runnerId);
  assert.equal(row.runId, runId);
  assert.equal(row.phase, 'candidate_search');
  assert.equal(row.sourceIdentitySha256, evidence.metadata.sourceIdentitySha256);
  assert.equal(row.screenshotBytes, image.length);
  assert.equal(row.screenshotSha256.length, 64);
  assert.equal(row.viewportCaptureReceipt.captureId, expectedRequest.captureId);
  assert.equal(row.viewportCaptureReceipt.runnerId, runnerId);
  assert.equal(row.viewportCaptureReceipt.statusSequence, status.sequence);
  assert.equal(row.viewportCaptureReceipt.capturePath, row.path);
  assert.equal(row.viewportCaptureReceipt.width, 2);
  assert.equal(row.viewportCaptureReceipt.height, 1);
  assert.equal(row.viewportCaptureReceipt.screenshotBytes, image.length);

  const finalized = evidence.finalize({
    watchdogSummary: { runId, overallExitCode: 0, functionalExitCode: 0, cleanupPassed: true, authoritativeZeroProven: true },
    acceptancePassed: true,
  });
  assert.equal(finalized.captures.length, 1);
  assert.equal(finalized.captures[0].sha256, row.screenshotSha256);
  assert.equal(finalized.processAcceptancePassed, true);
  assert.equal(finalized.accepted, false, 'a synthetic protocol fixture is not visual review');
});

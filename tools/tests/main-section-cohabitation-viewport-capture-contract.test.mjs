// Static contract checks only. This test does not start Godot or inspect images.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync } from 'node:zlib';
import { assertRealContainedPath, validatePng } from '../lib/headed-test-evidence.mjs';

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = relative => fs.readFileSync(path.join(project, relative), 'utf8');

const gate = read('scripts/testing/world/MainSectionCohabitationGate.gd');
const overlay = read('scripts/testing/AutomatedTestOverlay.gd');
const evidence = read('tools/lib/headed-test-evidence.mjs');
const runner = read('tools/lib/building-runner.mjs');
const gateRunner = read('tools/visible-world/run-main-section-cohabitation-gate.mjs');
const existingViewportCapture = read('scripts/testing/world/EcologyMainRetirementPlaytest.gd');
const projectConfig = read('project.godot');

test('Godot test evidence captures the rendered viewport after a draw frame', () => {
  assert.match(existingViewportCapture, /await RenderingServer\.frame_post_draw/);
  assert.match(existingViewportCapture, /get_viewport\(\)\.get_texture\(\)\.get_image\(\)/);
  assert.match(overlay, /await RenderingServer\.frame_post_draw/);
  assert.match(overlay, /var texture := get_viewport\(\)\.get_texture\(\)/);
  assert.match(overlay, /viewport_image = texture\.get_image\(\)/);
  assert.match(overlay, /viewport_image\.save_png/);
});

test('cohabitation runner requests viewport captures through the overlay protocol', () => {
  assert.match(projectConfig, /AutomatedTestOverlay="\*res:\/\/scripts\/testing\/AutomatedTestOverlay\.gd"/);
  assert.match(gateRunner, /captureMode:\s*'godot_viewport'/);
  assert.match(gateRunner, /capture\.captureType === 'godot-rendered-viewport'/);
  assert.ok(gateRunner.includes('(capture.captureId.includes(name) || capture.phase === ({'));
  assert.ok(gateRunner.includes("})[name]) && capture.captureType === 'godot-rendered-viewport'"));
  assert.ok(gateRunner.includes("'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd'"));
  assert.ok(gateRunner.includes("'scripts/world/StaticInstanceAttributeBuffer.gd'"));
  assert.ok(gateRunner.includes("'scripts/world/OwnedValueArtifactRetirement.gd'"));
  assert.match(overlay, /VIEWPORT_CAPTURE_REQUEST_ENV/);
  assert.match(overlay, /VIEWPORT_CAPTURE_RECEIPT_ENV/);
  assert.match(overlay, /statusSequence/);
  assert.match(overlay, /sourceIdentitySha256/);
});

test('viewport checkpoint path has no HWND focus or desktop capture dependency', () => {
  const start = evidence.indexOf("if (metadata.captureMode === 'godot_viewport')", evidence.indexOf('async function captureScreenshot'));
  const end = evidence.indexOf('// Preserve the existing owned-window evidence path for other headed tests.', start);
  assert.ok(start >= 0 && end > start, 'direct viewport capture branch exists');
  const viewportBranch = evidence.slice(start, end);
  assert.match(viewportBranch, /requestGodotViewportCapture/);
  assert.match(viewportBranch, /viewportReceiptSchema/);
  assert.doesNotMatch(viewportBranch, /inspectFocusCaptureOwnedWindow|windowTool|Foreground|HWND/i);
});

test('captures retain exact run, runner, phase, source hash, and image hash bindings', () => {
  assert.ok(evidence.includes('sourceIdentitySha256'));
  assert.ok(evidence.includes('sourceSha256'));
  assert.ok(evidence.includes('statusSequence'));
  assert.ok(evidence.includes('screenshotSha256: sha256(image)'));
  assert.ok(runner.includes('godot-viewport-final-capture-ack/v1'));
  assert.ok(runner.includes('captureRow?.screenshotSha256'));
  assert.ok(runner.includes('progressAcceptance = checkpoint.acceptancePassed === true && captureResult.error === null && captureRow !== null'));
  assert.ok(gate.includes('final_rendered_viewport_checkpoint_captured'));
  assert.ok(gate.includes('sourceIdentitySha256'));
  const inspect = evidence.slice(evidence.indexOf('export function inspectScreenshotBinding'),
    evidence.indexOf('/** Reviewer receipts must cover every image'));
  assert.ok(inspect.includes('row.runnerId === evidence.runnerId'));
  assert.ok(inspect.includes('viewport.capturePath'));
  assert.ok(inspect.includes('viewport.screenshotBytes === bytes.length'));
  assert.ok(inspect.includes('viewport.sourceIdentityJson === canonicalJson(evidence.sourceIdentity)'));
  assert.ok(inspect.includes('validatePng(bytes)'));
  assert.ok(inspect.includes('assertRealContainedPath'));
  assert.ok(inspect.includes('const evidenceAfterInspection = readEvidenceSafely(absolute)'));
  assert.ok(inspect.includes('evidenceAfterInspection.sha256 === evidenceFile.sha256'));
});

test('the gate publishes its final report only after a bounded viewport acknowledgement', () => {
  const ackWait = gate.indexOf('var capture_ack: Dictionary = await _wait_for_final_viewport_capture_ack(passed)');
  const finalProgress = gate.indexOf('_write_progress("finished"', ackWait);
  const finalReport = gate.indexOf('var report :=', ackWait);
  assert.ok(ackWait >= 0 && finalProgress > ackWait && finalReport > ackWait);
  assert.match(gate, /FINAL_VIEWPORT_CAPTURE_ACK_TIMEOUT_SECONDS := 30\.0/);
  assert.match(gate, /Time\.get_ticks_usec\(\) < deadline_usec/);
  assert.ok(gate.includes('timed_out_waiting_for_runner_final_viewport_capture_ack'));
  assert.ok(gate.includes('report_reason = "final_rendered_viewport_checkpoint_capture_failed"'));
  assert.match(gate, /final_rendered_viewport_checkpoint_captured/);
  assert.ok(gate.includes('var capture_passed := bool(capture_ack.get("captured", false))'));
  assert.match(runner, /stage === 'awaiting_final_viewport_capture'/);
  assert.match(runner, /captureResult\.error === null && captureRow !== null/);
});

test('Main fixture compilation precedes the headed gate and checks frozen sources', () => {
  const compile = gateRunner.indexOf("args: ['--headless', '--check-only', '--script'");
  const stable = gateRunner.indexOf('stable(c.project, sourceSha256);', compile);
  const headed = gateRunner.indexOf("args: ['--resolution'", stable);
  assert.ok(compile >= 0 && stable > compile && headed > stable);
  assert.match(gateRunner.slice(compile, stable), /prefix: 'parse-'/);
  assert.match(gate, /var receipt_matches: bool = viewport_receipt is Dictionary/);
});

test('visual inspection remains explicit and pending until a hash-matched review is recorded', () => {
  assert.match(evidence, /visualInspection: \{ status: captures\.length > 0 \? 'pending' : 'unavailable'/);
  assert.match(evidence, /reviewedCaptureSha256: \[\]/);
  assert.match(evidence, /visualInspectionRequired: true/);
  assert.match(gateRunner, /visualInspection\.status === 'pending'/);
  assert.match(gateRunner, /visualInspection\.reviewedCaptureSha256\.length === 0/);
});

function pngCrc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc & 1) ? (0xedb88320 ^ (crc >>> 1)) : (crc >>> 1);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const typeBytes = Buffer.from(type, 'ascii');
  const size = Buffer.alloc(4);
  size.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(pngCrc32(Buffer.concat([typeBytes, data])));
  return Buffer.concat([size, typeBytes, data, crc]);
}

function validPngFixture() {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(1, 0);
  header.writeUInt32BE(1, 4);
  header[8] = 8;
  header[9] = 6;
  const scanline = Buffer.from([0, 32, 64, 96, 255]);
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk('IHDR', header),
    pngChunk('IDAT', deflateSync(scanline)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

test('PNG validation inflates scanlines and rejects a file truncated immediately after IHDR', () => {
  const png = validPngFixture();
  assert.deepEqual(
    (({ width, height, decodedBytes }) => ({ width, height, decodedBytes }))(validatePng(png)),
    { width: 1, height: 1, decodedBytes: 5 },
  );
  const afterIhdr = 8 + 12 + 13;
  assert.throws(() => validatePng(png.subarray(0, afterIhdr)), /missing IHDR, IDAT, or IEND/);

  const idatStart = afterIhdr;
  const idatLength = png.readUInt32BE(idatStart);
  const idatDataStart = idatStart + 8;
  const truncatedDeflate = Buffer.concat([
    png.subarray(0, idatStart),
    pngChunk('IDAT', png.subarray(idatDataStart, idatDataStart + idatLength - 1)),
    png.subarray(idatDataStart + idatLength + 4),
  ]);
  assert.throws(() => validatePng(truncatedDeflate), /IDAT stream is truncated or corrupt/);

  const badCrc = Buffer.from(png);
  badCrc[idatDataStart + idatLength] ^= 0xff;
  assert.throws(() => validatePng(badCrc), /chunk CRC mismatch: IDAT/);
});

test('real evidence-path containment rejects a pre-existing directory junction or symlink', t => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'viewport-containment-contract-'));
  t.after(() => fs.rmSync(scratch, { recursive: true, force: true }));
  const run = path.join(scratch, 'run');
  const outside = path.join(scratch, 'outside');
  fs.mkdirSync(run);
  fs.mkdirSync(outside);
  fs.writeFileSync(path.join(outside, 'capture.png'), 'outside');
  const link = path.join(run, 'linked-capture-directory');
  try {
    fs.symlinkSync(outside, link, 'junction');
  } catch (error) {
    if (['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) {
      t.skip('Windows did not allow creation of a junction in the temp directory');
      return;
    }
    throw error;
  }
  assert.throws(
    () => assertRealContainedPath(run, path.join(link, 'capture.png'), { label: 'Screenshot inspection path' }),
    /symbolic link or junction|resolves outside its run directory/,
  );
});

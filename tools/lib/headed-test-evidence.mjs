import { createHash, randomUUID } from 'node:crypto';
import { appendFileSync, existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { inflateSync } from 'node:zlib';

const runSchema = 'voxel-automated-test-run/v1';
const statusSchema = 'voxel-automated-test-status/v1';
const captureSchema = 'voxel-automated-test-capture/v1';
const captureFailureSchema = 'voxel-automated-test-capture-failure/v1';
const evidenceSchema = 'voxel-automated-test-visual-evidence/v1';
const reviewSchema = 'voxel-automated-test-visual-review/v1';
const viewportRequestSchema = 'voxel-automated-test-viewport-capture-request/v1';
const viewportReceiptSchema = 'voxel-automated-test-viewport-capture-receipt/v1';
const runIdPattern = /^[a-f0-9]{32}$/i;
const phaseKinds = new Set(['harness', 'initialized_main_readiness_wait', 'gameplay', 'failure']);
const pngSignature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const maxPngPixels = 16_777_216;
// The window CLI may spend up to 60 seconds compiling its helper, then 5 seconds
// in the bounded native action. Leave a small margin for process startup and IO.
const windowToolTimeoutMs = 70000;
const windowTool = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../invoke-owned-game-window.mjs');

function demand(condition, message) { if (!condition) throw new Error(message); }
function sha256(bytes) { return createHash('sha256').update(bytes).digest('hex'); }
const pngCrcTable = Uint32Array.from({ length: 256 }, (_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit++) value = (value & 1) ? (0xedb88320 ^ (value >>> 1)) : (value >>> 1);
  return value >>> 0;
});
function pngCrc32(bytes, start, end) {
  let crc = 0xffffffff;
  for (let index = start; index < end; index++) crc = pngCrcTable[(crc ^ bytes[index]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}
function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort()
    .map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}
function isWithinPath(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}
function pathEntryExists(file) {
  try { lstatSync(file); return true; } catch (error) { if (error?.code === 'ENOENT') return false; throw error; }
}
export function assertRealContainedPath(rootPath, candidatePath, { allowMissingLeaf = false, label = 'Evidence path' } = {}) {
  const root = path.resolve(rootPath);
  const candidate = path.resolve(candidatePath);
  const relative = path.relative(root, candidate);
  demand(isWithinPath(root, candidate), `${label} escapes its run directory: ${candidate}`);
  const rootStat = lstatSync(root);
  demand(rootStat.isDirectory() && !rootStat.isSymbolicLink(), `${label} run directory is not a real directory: ${root}`);
  const realRoot = realpathSync(root);
  let current = root;
  const parts = relative ? relative.split(path.sep).filter(Boolean) : [];
  for (let index = 0; index < parts.length; index++) {
    current = path.join(current, parts[index]);
    let entry;
    try { entry = lstatSync(current); }
    catch (error) {
      if (allowMissingLeaf && index === parts.length - 1 && error?.code === 'ENOENT') return false;
      throw new Error(`${label} component is unavailable: ${current}: ${error.message}`, { cause: error });
    }
    demand(!entry.isSymbolicLink(), `${label} contains a symbolic link or junction: ${current}`);
    if (index < parts.length - 1) demand(entry.isDirectory(), `${label} parent is not a directory: ${current}`);
    const realCurrent = realpathSync(current);
    demand(isWithinPath(realRoot, realCurrent), `${label} resolves outside its run directory: ${current}`);
  }
  return true;
}

/** Validate every PNG chunk and fully inflate the bounded image stream. */
export function validatePng(bytes, { maxPixels = maxPngPixels } = {}) {
  demand(Buffer.isBuffer(bytes) && bytes.length >= 8 && bytes.subarray(0, 8).equals(pngSignature), 'Screenshot is not a PNG');
  let offset = 8, header = null, paletteEntries = 0, sawPalette = false;
  let sawTransparency = false, sawIdat = false, idatClosed = false, sawIend = false;
  const idat = [];
  while (offset < bytes.length) {
    demand(offset + 12 <= bytes.length, 'PNG ends inside a chunk header');
    const length = bytes.readUInt32BE(offset), typeStart = offset + 4, dataStart = offset + 8;
    const dataEnd = dataStart + length, chunkEnd = dataEnd + 4;
    demand(Number.isSafeInteger(dataEnd) && chunkEnd <= bytes.length, 'PNG ends inside a chunk payload or CRC');
    const type = bytes.toString('ascii', typeStart, typeStart + 4);
    demand(/^[A-Za-z]{4}$/.test(type) && type[2] === type[2].toUpperCase(), `PNG chunk type is invalid: ${type}`);
    demand(pngCrc32(bytes, typeStart, dataEnd) === bytes.readUInt32BE(dataEnd), `PNG chunk CRC mismatch: ${type}`);
    const data = bytes.subarray(dataStart, dataEnd);
    if (header === null) demand(type === 'IHDR' && length === 13, 'PNG must begin with one 13-byte IHDR chunk');
    else demand(type !== 'IHDR', 'PNG contains a duplicate IHDR chunk');
    if (sawIdat && type !== 'IDAT') idatClosed = true;
    if (type === 'IHDR') {
      const width = data.readUInt32BE(0), height = data.readUInt32BE(4), bitDepth = data[8], colorType = data[9];
      const depths = { 0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16] };
      demand(width > 0 && height > 0 && Number.isSafeInteger(width * height) && width * height <= maxPixels,
        'PNG dimensions are empty or exceed the screenshot pixel limit');
      demand(depths[colorType]?.includes(bitDepth), 'PNG color type and bit depth are invalid');
      demand(data[10] === 0 && data[11] === 0 && data[12] <= 1,
        'PNG compression, filter, or interlace method is unsupported');
      header = { width, height, bitDepth, colorType, interlace: data[12] };
    } else if (type === 'PLTE') {
      demand(header && !sawIdat && !sawPalette && length > 0 && length <= 768 && length % 3 === 0
        && header.colorType !== 0 && header.colorType !== 4,
      'PNG PLTE chunk is misplaced or malformed');
      paletteEntries = length / 3;
      demand(header.colorType !== 3 || paletteEntries <= 2 ** header.bitDepth,
        'PNG palette exceeds indexed bit depth');
      sawPalette = true;
    } else if (type === 'tRNS') {
      demand(header && !sawIdat && !sawTransparency, 'PNG tRNS chunk is misplaced or duplicated');
      if (header.colorType === 0) demand(length === 2, 'PNG grayscale tRNS chunk must contain one sample');
      else if (header.colorType === 2) demand(length === 6, 'PNG truecolor tRNS chunk must contain three samples');
      else if (header.colorType === 3) demand(sawPalette && length > 0 && length <= paletteEntries,
        'PNG indexed tRNS chunk does not match its palette');
      else demand(false, 'PNG tRNS is forbidden for alpha color types');
      sawTransparency = true;
    } else if (type === 'IDAT') {
      demand(header && !idatClosed, 'PNG IDAT chunks must be consecutive and follow IHDR');
      sawIdat = true;
      idat.push(data);
    } else if (type === 'IEND') {
      demand(sawIdat && length === 0 && !sawIend, 'PNG IEND chunk is misplaced or malformed');
      sawIend = true;
      offset = chunkEnd;
      demand(offset === bytes.length, 'PNG has trailing bytes after IEND');
      break;
    } else {
      demand(header !== null && type[0] === type[0].toLowerCase(), `PNG contains an unknown critical chunk: ${type}`);
    }
    offset = chunkEnd;
  }
  demand(header && sawIdat && sawIend, 'PNG is missing IHDR, IDAT, or IEND');
  demand(header.colorType !== 3 || sawPalette, 'Indexed PNG is missing PLTE');
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[header.colorType];
  const bitsPerPixel = channels * header.bitDepth;
  const geometry = header.interlace === 0 ? [[0, 0, 1, 1]]
    : [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4], [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]];
  const passes = geometry.map(([x, y, dx, dy]) => {
    const width = header.width <= x ? 0 : Math.ceil((header.width - x) / dx);
    const height = header.height <= y ? 0 : Math.ceil((header.height - y) / dy);
    return { width, height, rowBytes: Math.ceil(width * bitsPerPixel / 8) };
  }).filter(pass => pass.width && pass.height);
  const expectedBytes = passes.reduce((sum, pass) => sum + pass.height * (pass.rowBytes + 1), 0);
  demand(Number.isSafeInteger(expectedBytes) && expectedBytes > 0, 'PNG decoded image size is invalid');
  const compressed = Buffer.concat(idat);
  let inflated;
  try { inflated = inflateSync(compressed, { info: true, maxOutputLength: expectedBytes }); }
  catch (error) { throw new Error(`PNG IDAT stream is truncated or corrupt: ${error.message}`, { cause: error }); }
  demand(inflated.engine?.bytesWritten === compressed.length, 'PNG IDAT stream contains trailing compressed bytes');
  demand(inflated.buffer.length === expectedBytes, 'PNG decompressed scanline length does not match its dimensions');
  let scanlineOffset = 0;
  for (const pass of passes) for (let row = 0; row < pass.height; row++) {
    demand(inflated.buffer[scanlineOffset] <= 4, 'PNG scanline has an invalid filter method');
    scanlineOffset += pass.rowBytes + 1;
  }
  return { ...header, decodedBytes: inflated.buffer.length };
}
function readBytesWithinRoot(root, file, label) {
  assertRealContainedPath(root, file, { label });
  demand(lstatSync(file).isFile(), `${label} is not a regular file: ${file}`);
  const realFile = realpathSync(file);
  const bytes = readFileSync(realFile);
  assertRealContainedPath(root, file, { label: `${label} after read` });
  demand(realpathSync(file) === realFile, `${label} path changed while it was being read`);
  return bytes;
}
function readJsonWithinRoot(root, file, message) {
  try { return JSON.parse(readBytesWithinRoot(root, file, message).toString('utf8').replace(/^\uFEFF/, '')); }
  catch (error) { throw new Error(`${message}: ${error.message}`, { cause: error }); }
}
function atomicJson(file, value) {
  const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx', flush: true });
    renameSync(temporary, file);
  } finally {
    try { if (existsSync(temporary)) unlinkSync(temporary); } catch { /* best-effort temporary cleanup */ }
  }
}
function validateRunId(runId) {
  demand(typeof runId === 'string' && runIdPattern.test(runId), 'runId must be the exact 32-character hexadecimal ID used by the owned-process watchdog');
}
export function headedCapturePath(captureDirectory, sequence) {
  demand(Number.isSafeInteger(sequence) && sequence >= 0, 'Capture sequence must be a nonnegative safe integer');
  return path.join(captureDirectory, `${String(sequence).padStart(2, '0')}.png`);
}
function execFileText(executable, args, options, action) {
  return new Promise((resolve, reject) => {
    execFile(executable, args, options, (error, stdout, stderr) => {
      if (error) {
        const output = [stderr, stdout].filter(value => typeof value === 'string' && value.trim()).join('\n').slice(-4000);
        const detail = output ? `; ${action} output: ${output}` : '';
        reject(new Error(`${action} failed: ${error.message}${detail}`, { cause: error }));
      } else resolve(stdout);
    });
  });
}
function transientOwnedWindowError(error) {
  return /Expected exactly one visible owned Godot game client|Windows refused foreground focus|Owned game window lost foreground focus|inspected owned Godot game window could not be focused before capture/i
    .test(String(error?.message ?? error));
}

/** Inspect, focus, then capture one exact currently owned HWND; retry only transient window races. */
export async function inspectFocusCaptureOwnedWindow({ liveOwnershipPath, runId, projectPath, capturePath,
  runDirectory = path.dirname(path.resolve(liveOwnershipPath)),
  invoke, wait = ms => new Promise(resolve => setTimeout(resolve, ms)), maxAttempts = 3 }) {
  validateRunId(runId);
  demand(typeof invoke === 'function', 'An owned-window action invoker is required');
  demand(Number.isInteger(maxAttempts) && maxAttempts >= 1 && maxAttempts <= 5,
    'maxAttempts must be between 1 and 5');
  const common = ['--live-ownership-path', liveOwnershipPath, '--run-id', runId,
    '--project-path', projectPath];
  let lastError = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      const inspectArgs = [...common, '--action', 'Inspect'];
      const inspected = await invoke(inspectArgs, 'Inspect');
      const inspectedWindow = inspected?.window;
      demand(inspected?.schema === 'owned-game-window-action/v1' && inspected?.status === 'completed'
        && inspected?.runId === runId && inspected?.action === 'Inspect'
        && inspectedWindow?.Hwnd !== undefined && Number.isSafeInteger(inspectedWindow?.Pid)
        && inspectedWindow.Pid > 0 && Number.isInteger(inspectedWindow?.Width)
        && Number.isInteger(inspectedWindow?.Height),
      'Owned-window Inspect receipt is incomplete or belongs to another run');
      const handle = String(inspectedWindow.Hwnd);
      const focusArgs = [...common, '--action', 'Focus', '--window-handle', handle];
      const focused = await invoke(focusArgs, 'Focus');
      demand(focused?.schema === 'owned-game-window-action/v1' && focused?.status === 'completed'
        && focused?.runId === runId && focused?.action === 'Focus'
        && String(focused.window?.Hwnd) === handle
        && focused.window?.Pid === inspectedWindow.Pid && focused.window?.Foreground === true,
      'The inspected owned Godot game window could not be focused before capture');
      const captureArgs = [...common, '--action', 'Capture', '--window-handle', handle,
        '--expected-client-width', String(inspectedWindow.Width),
        '--expected-client-height', String(inspectedWindow.Height), '--capture-path', capturePath];
      const receipt = await invoke(captureArgs, 'Capture');
      const afterLive = readJsonWithinRoot(runDirectory, liveOwnershipPath,
        'Cannot reread owned live-process record after capture');
      demand(receipt?.schema === 'owned-game-window-action/v1' && receipt?.status === 'completed'
        && receipt?.runId === runId && receipt?.action === 'Capture'
        && String(receipt.window?.Hwnd) === handle
        && receipt.window?.Pid === inspectedWindow.Pid && receipt.window?.Foreground === true,
      'Native capture receipt does not match the focused inspected HWND/PID');
      demand(afterLive.runId === runId && afterLive.state === 'running'
        && Array.isArray(afterLive.members) && afterLive.members.some(member => member.pid === receipt.window?.Pid),
      'Captured HWND PID is not a current member of this exact owned run');
      return receipt;
    } catch (error) {
      lastError = error;
      try { if (existsSync(capturePath)) unlinkSync(capturePath); } catch { /* preserve the capture error */ }
      if (attempt >= maxAttempts || !transientOwnedWindowError(error)) throw error;
      await wait(150);
    }
  }
  throw lastError ?? new Error('Owned-window capture failed without an error receipt');
}
function parseCaptureManifest(file, root) {
  const text = readBytesWithinRoot(root, file, 'Capture manifest').toString('utf8');
  return text.split(/\r?\n/).filter(line => line.trim()).map((line, index) => {
    try { return JSON.parse(line); }
    catch (error) { throw new Error(`Invalid capture manifest row ${index + 1}: ${error.message}`); }
  });
}

/**
 * Create metadata for one headed run. Pass `runId` to the watchdog itself so
 * this identity, the overlay, and godot-live-ownership/v1 are identical.
 */
export function createHeadedTestEvidence({ projectPath, runnerId, runId, outputDirectory,
  startedAtUnixMs = Date.now(), sourceIdentity = {}, captureMode = 'owned_window' }) {
  validateRunId(runId);
  demand(typeof runnerId === 'string' && runnerId.trim(), 'runnerId is required');
  demand(Number.isSafeInteger(startedAtUnixMs) && startedAtUnixMs > 0, 'startedAtUnixMs must be a positive safe integer');
  demand(['owned_window', 'godot_viewport'].includes(captureMode), 'captureMode must be owned_window or godot_viewport');
  const project = path.resolve(projectPath);
  const output = path.resolve(outputDirectory);
  const captureDirectory = path.join(output, 's');
  const captureManifestPath = path.join(output, 'm.jsonl');
  const statusPath = path.join(output, 't.json');
  const liveOwnershipPath = path.join(output, 'l.json');
  const finalCaptureAckPath = path.join(output, 'a.json');
  const evidencePath = path.join(output, 'e.json');
  const viewportCaptureRequestPath = path.join(output, 'viewport-capture-request.json');
  const viewportCaptureReceiptPath = path.join(output, 'viewport-capture-receipt.json');
  const sourceIdentityJson = canonicalJson(sourceIdentity);
  const sourceIdentitySha256 = sha256(Buffer.from(sourceIdentityJson, 'utf8'));
  const startedAtUtc = new Date(startedAtUnixMs).toISOString();
  const outputParent = path.dirname(output);
  mkdirSync(outputParent, { recursive: true });
  assertRealContainedPath(outputParent, output, { allowMissingLeaf: true, label: "Headed-test output" });
  mkdirSync(output);
  const outputEntry = lstatSync(output);
  demand(outputEntry.isDirectory() && !outputEntry.isSymbolicLink(), 'Headed-test output must be a real directory');
  assertRealContainedPath(output, output, { label: 'Headed-test output' });
  const metadata = Object.freeze({
    schema: runSchema, projectPath: project, runnerId: runnerId.trim(), runId,
    watchdogRunId: runId, startedAtUtc, startedAtUnixMs,
    outputDirectory: output, captureDirectory, captureManifestPath, statusPath,
    liveOwnershipPath, finalCaptureAckPath, evidencePath, sourceIdentity,
    sourceIdentityJson, sourceIdentitySha256, captureMode,
    viewportCaptureRequestPath, viewportCaptureReceiptPath,
  });
  mkdirSync(captureDirectory, { recursive: true });
  assertRealContainedPath(output, captureDirectory, { label: 'Headed-test capture directory' });
  for (const file of [captureManifestPath, statusPath, evidencePath]) {
    assertRealContainedPath(output, file, { allowMissingLeaf: true, label: 'Headed-test evidence file' });
    demand(!pathEntryExists(file), `Fresh headed-test evidence path required: ${file}`);
  }
  writeFileSync(captureManifestPath, '', { flag: 'wx' });
  let sequence = 0;
  let currentStatus = null;

  function publishPhase(phase, phaseKind = 'harness', detail = '') {
    demand(typeof phase === 'string' && phase.trim(), 'phase is required');
    demand(phaseKinds.has(phaseKind), `phaseKind must be one of: ${[...phaseKinds].join(', ')}`);
    currentStatus = {
      schema: statusSchema, runnerId: metadata.runnerId, runId, watchdogRunId: runId,
      startedAtUtc, startedAtUnixMs, sequence: ++sequence, updatedAtUtc: new Date().toISOString(),
      sourceIdentitySha256: metadata.sourceIdentitySha256,
      phase: phase.trim(), phaseKind, detail: String(detail).slice(0, 512),
    };
    assertRealContainedPath(output, statusPath, { allowMissingLeaf: true, label: 'Headed-test status file' });
    atomicJson(statusPath, currentStatus);
    return currentStatus;
  }

  function environment(base = {}) {
    demand(currentStatus !== null, 'Publish the initial phase before launching Godot');
    return {
      ...base,
      VOXEL_AUTOMATED_TEST: '1',
      VOXEL_AUTOMATED_TEST_NAME: metadata.runnerId,
      VOXEL_AUTOMATED_TEST_RUN_ID: runId,
      VOXEL_AUTOMATED_TEST_STATUS: statusPath,
      VOXEL_AUTOMATED_TEST_STARTED_UTC: startedAtUtc,
      VOXEL_AUTOMATED_TEST_CAPTURE_MODE: metadata.captureMode,
      VOXEL_AUTOMATED_TEST_SOURCE_IDENTITY: metadata.sourceIdentityJson,
      VOXEL_AUTOMATED_TEST_SOURCE_IDENTITY_SHA256: metadata.sourceIdentitySha256,
      VOXEL_AUTOMATED_TEST_CAPTURE_DIR: captureDirectory,
      VOXEL_AUTOMATED_TEST_CAPTURE_MANIFEST: captureManifestPath,
      VOXEL_AUTOMATED_TEST_LIVE_OWNERSHIP: liveOwnershipPath,
      VOXEL_AUTOMATED_TEST_FINAL_CAPTURE_ACK: finalCaptureAckPath,
      ...(metadata.captureMode === 'godot_viewport' ? {
        VOXEL_AUTOMATED_TEST_VIEWPORT_CAPTURE_REQUEST: metadata.viewportCaptureRequestPath,
        VOXEL_AUTOMATED_TEST_VIEWPORT_CAPTURE_RECEIPT: metadata.viewportCaptureReceiptPath,
      } : {}),
    };
  }

  async function requestGodotViewportCapture(request) {
    assertRealContainedPath(output, metadata.viewportCaptureRequestPath,
      { allowMissingLeaf: true, label: 'Viewport capture request' });
    assertRealContainedPath(output, metadata.viewportCaptureReceiptPath,
      { allowMissingLeaf: true, label: 'Viewport capture receipt' });
    for (const file of [metadata.viewportCaptureRequestPath, metadata.viewportCaptureReceiptPath]) {
      try { if (pathEntryExists(file)) unlinkSync(file); } catch { /* capture failure remains authoritative */ }
    }
    atomicJson(metadata.viewportCaptureRequestPath, request);
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      if (existsSync(metadata.viewportCaptureReceiptPath)) {
        assertRealContainedPath(output, metadata.viewportCaptureReceiptPath, { label: 'Viewport capture receipt' });
        return readJsonWithinRoot(output, metadata.viewportCaptureReceiptPath,
          'Cannot read Godot viewport capture receipt');
      }
      await new Promise(resolve => setTimeout(resolve, 40));
    }
    throw new Error('Timed out waiting for the in-game viewport capture receipt');
  }

  async function captureScreenshot({ name, phase, phaseKind = 'gameplay', detail = '' }) {
    demand(currentStatus !== null, 'Publish the current phase before capturing a screenshot');
    demand(typeof name === 'string' && name.trim(), 'Screenshot name is required');
    demand(phaseKinds.has(phaseKind), `phaseKind must be one of: ${[...phaseKinds].join(', ')}`);
    const beforeStatus = readJsonWithinRoot(output, statusPath, 'Cannot read headed-test status');
    const beforeLive = readJsonWithinRoot(output, liveOwnershipPath, 'Cannot read owned live-process record');
    demand(beforeStatus.schema === statusSchema && beforeStatus.runId === runId && beforeStatus.runnerId === metadata.runnerId,
      'Status record does not belong to this headed test');
    demand(beforeStatus.phase === phase && beforeStatus.phaseKind === phaseKind,
      'Capture phase must exactly match the visible overlay status');
    demand(beforeStatus.sourceIdentitySha256 === metadata.sourceIdentitySha256,
      'Capture phase source identity does not match this headed test');
    demand(beforeLive.schema === 'godot-live-ownership/v1' && beforeLive.state === 'running' && beforeLive.runId === runId,
      'Live Godot ownership record is not running under this exact runId');

    const captureId = `${runId}:${String(sequence).padStart(6, '0')}`;
    const capturePath = headedCapturePath(captureDirectory, sequence);
    assertRealContainedPath(output, capturePath, { allowMissingLeaf: true, label: 'Screenshot path' });
    demand(!pathEntryExists(capturePath), `Capture path already exists: ${capturePath}`);
    let receipt;
    let captureType = 'owned-window';
    if (metadata.captureMode === 'godot_viewport') {
      captureType = 'godot-rendered-viewport';
      const request = {
        schema: viewportRequestSchema, captureType, captureId,
        runnerId: metadata.runnerId, runId, watchdogRunId: runId,
        statusSequence: beforeStatus.sequence, phase: phase.trim(), phaseKind,
        captureName: name.trim(), detail: String(detail).slice(0, 512),
        capturePath, receiptPath: metadata.viewportCaptureReceiptPath,
        sourceIdentityJson: metadata.sourceIdentityJson,
        sourceIdentitySha256: metadata.sourceIdentitySha256,
      };
      try {
        receipt = await requestGodotViewportCapture(request);
        const statusAtCapture = readJsonWithinRoot(output, statusPath,
          'Cannot reread headed-test status after viewport capture');
        demand(statusAtCapture.runId === runId && statusAtCapture.runnerId === metadata.runnerId
          && statusAtCapture.sequence === beforeStatus.sequence && statusAtCapture.phase === phase
          && statusAtCapture.phaseKind === phaseKind
          && statusAtCapture.sourceIdentitySha256 === metadata.sourceIdentitySha256,
        'Headed-test phase or source identity changed during viewport capture');
        demand(receipt.schema === viewportReceiptSchema && receipt.captureType === captureType
          && receipt.captureId === captureId && receipt.runnerId === metadata.runnerId
          && receipt.runId === runId && receipt.watchdogRunId === runId
          && receipt.statusSequence === beforeStatus.sequence && receipt.phase === phase.trim()
          && receipt.phaseKind === phaseKind && receipt.captureName === name.trim()
          && receipt.capturePath === capturePath
          && receipt.receiptPath === metadata.viewportCaptureReceiptPath
          && receipt.sourceIdentityJson === metadata.sourceIdentityJson
          && receipt.sourceIdentitySha256 === metadata.sourceIdentitySha256
          && receipt.captured === true,
        `Godot viewport receipt does not match the exact run, phase, source identity, and path: ${receipt.reason ?? 'binding mismatch'}`);
      } catch (error) {
        try { if (existsSync(capturePath)) unlinkSync(capturePath); } catch { /* keep capture error authoritative */ }
        throw error;
      } finally {
        try { if (pathEntryExists(metadata.viewportCaptureRequestPath)) unlinkSync(metadata.viewportCaptureRequestPath); } catch { /* cleanup is best-effort */ }
        try { if (pathEntryExists(metadata.viewportCaptureReceiptPath)) unlinkSync(metadata.viewportCaptureReceiptPath); } catch { /* cleanup is best-effort */ }
      }
    } else {
      // Preserve the existing owned-window evidence path for other headed tests.
      await new Promise(resolve => setTimeout(resolve, 350));
      const statusAtCapture = readJsonWithinRoot(output, statusPath,
        'Cannot reread headed-test status before capture');
      demand(statusAtCapture.runId === runId && statusAtCapture.sequence === beforeStatus.sequence
        && statusAtCapture.phase === phase && statusAtCapture.phaseKind === phaseKind
        && statusAtCapture.sourceIdentitySha256 === metadata.sourceIdentitySha256,
      'Headed-test phase changed while preparing the screenshot');
      try {
        receipt = await inspectFocusCaptureOwnedWindow({ liveOwnershipPath, runId,
          projectPath: project, capturePath,
          invoke: async (args, action) => {
            const stdout = await execFileText(process.execPath, [windowTool, ...args],
              { cwd: project, encoding: 'utf8', windowsHide: true, timeout: windowToolTimeoutMs,
                maxBuffer: 1024 * 1024 }, action);
            return JSON.parse(stdout.trim());
          }});
      } catch (error) {
        try { if (existsSync(capturePath)) unlinkSync(capturePath); } catch { /* keep capture error authoritative */ }
        throw error;
      }
    }
    assertRealContainedPath(output, capturePath, { label: 'Screenshot path' });
    const realCapturePath = realpathSync(capturePath);
    const image = readFileSync(realCapturePath);
    assertRealContainedPath(output, capturePath, { label: 'Screenshot path after read' });
    demand(realpathSync(capturePath) === realCapturePath, 'Screenshot path changed while it was being read');
    const png = validatePng(image);
    if (metadata.captureMode === 'godot_viewport') {
      demand(image.length === receipt.screenshotBytes
        && png.width === receipt.width && png.height === receipt.height
        && Number.isInteger(receipt.width) && receipt.width > 0
        && Number.isInteger(receipt.height) && receipt.height > 0,
      'Godot viewport receipt dimensions or byte count do not match the PNG');
    }
    const row = {
      schema: captureSchema, captureId, runnerId: metadata.runnerId, runId,
      watchdogRunId: runId, phase: phase.trim(), phaseKind,
      statusSequence: beforeStatus.sequence,
      captureType, sourceIdentity: metadata.sourceIdentity,
      sourceSha256: metadata.sourceIdentity?.sourceSha256 ?? {},
      sourceIdentitySha256: metadata.sourceIdentitySha256,
      captureName: name.trim(),
      elapsedMilliseconds: Math.max(0, Date.now() - startedAtUnixMs),
      capturedAtUnixMilliseconds: Date.now(), path: capturePath,
      screenshotBytes: image.length, screenshotSha256: sha256(image),
    };
    if (metadata.captureMode === 'godot_viewport') row.viewportCaptureReceipt = receipt;
    else {
      row.windowHandle = String(receipt.window?.Hwnd);
      row.pid = receipt.window?.Pid;
      row.ownershipSequence = receipt.ownershipSequence;
      row.nativeCaptureReceipt = receipt;
    }
    if (detail) row.detail = String(detail).slice(0, 512);
    appendFileSync(captureManifestPath, `${JSON.stringify(row)}\n`, { flag: 'a', flush: true });
    sequence += 1;
    return row;
  }

  async function captureFailure(detail) {
    publishPhase('failure', 'failure', detail);
    return captureScreenshot({ name: 'failure', phase: 'failure', phaseKind: 'failure', detail });
  }

  function recordCaptureFailure({ phase, phaseKind = 'failure', reason, detail = '' }) {
    demand(typeof phase === 'string' && phase.trim(), 'Failure capture phase is required');
    demand(phaseKinds.has(phaseKind), `phaseKind must be one of: ${[...phaseKinds].join(', ')}`);
    const row = {
      schema: captureFailureSchema, captureId: `${runId}:failure:${String(sequence).padStart(6, '0')}`,
      runnerId: metadata.runnerId, runId, watchdogRunId: runId,
      sourceIdentity: metadata.sourceIdentity, sourceSha256: metadata.sourceIdentity?.sourceSha256 ?? {},
      sourceIdentitySha256: metadata.sourceIdentitySha256,
      statusSequence: currentStatus?.sequence ?? -1,
      phase: phase.trim(), phaseKind, elapsedMilliseconds: Math.max(0, Date.now() - startedAtUnixMs),
      recordedAtUnixMilliseconds: Date.now(), reason: String(reason).slice(0, 4000), detail: String(detail).slice(0, 1000),
    };
    appendFileSync(captureManifestPath, `${JSON.stringify(row)}\n`, { flag: 'a', flush: true });
    sequence += 1;
    return row;
  }

  function finalize({ watchdogSummary, acceptancePassed = false, sourceIdentity: finalSourceIdentity = sourceIdentity,
    diagnostics = [] }) {
    demand(watchdogSummary?.runId === runId, 'Watchdog summary runId does not match headed-test runId');
    demand(canonicalJson(finalSourceIdentity) === metadata.sourceIdentityJson,
      'Final source identity changed after headed-test launch');
    demand(sha256(Buffer.from(metadata.sourceIdentityJson, 'utf8')) === metadata.sourceIdentitySha256,
      'Source identity digest changed after headed-test launch');
    assertRealContainedPath(output, captureManifestPath, { label: 'Capture manifest' });
    const rows = parseCaptureManifest(captureManifestPath, output);
    const captures = [];
    const captureFailures = [];
    rows.forEach((row, index) => {
      if (row.schema === captureFailureSchema) {
        demand(row.runnerId === metadata.runnerId && row.runId === runId && row.watchdogRunId === runId,
          `Screenshot failure identity mismatch at record ${index + 1}`);
        demand(row.sourceIdentitySha256 === metadata.sourceIdentitySha256
          && canonicalJson(row.sourceIdentity) === metadata.sourceIdentityJson
          && canonicalJson(row.sourceSha256) === canonicalJson(metadata.sourceIdentity?.sourceSha256 ?? {}),
        `Screenshot failure source identity/hash mismatch at record ${index + 1}`);
        captureFailures.push({ captureId: row.captureId, phase: row.phase, phaseKind: row.phaseKind,
          statusSequence: row.statusSequence, sourceIdentitySha256: row.sourceIdentitySha256,
          sourceSha256: row.sourceSha256, elapsedMilliseconds: row.elapsedMilliseconds,
          reason: row.reason, detail: row.detail });
        return;
      }
      demand(row.schema === captureSchema && row.runnerId === metadata.runnerId && row.runId === runId && row.watchdogRunId === runId,
        `Screenshot identity mismatch at capture ${index + 1}`);
      demand(row.sourceIdentitySha256 === metadata.sourceIdentitySha256
        && canonicalJson(row.sourceIdentity) === metadata.sourceIdentityJson
        && canonicalJson(row.sourceSha256) === canonicalJson(metadata.sourceIdentity?.sourceSha256 ?? {})
        && Number.isSafeInteger(row.statusSequence) && row.statusSequence > 0,
      `Screenshot source identity/hash mismatch at capture ${index + 1}`);
      demand(row.captureType === (metadata.captureMode === 'godot_viewport'
        ? 'godot-rendered-viewport' : 'owned-window'),
      `Screenshot capture mode mismatch at capture ${index + 1}`);
      demand(typeof row.phase === 'string' && row.phase.trim() && Number.isSafeInteger(row.elapsedMilliseconds),
        `Screenshot phase or elapsed time missing at capture ${index + 1}`);
      const resolved = path.resolve(row.path);
      const captureRelative = path.relative(captureDirectory, resolved);
      demand(captureRelative && captureRelative !== '..' && !captureRelative.startsWith(`..${path.sep}`) && !path.isAbsolute(captureRelative),
        `Screenshot escaped the run capture directory: ${row.captureId}`);
      assertRealContainedPath(output, resolved, { label: 'Finalized screenshot path' });
      demand(lstatSync(resolved).isFile(), `Screenshot is not a regular file: ${row.captureId}`);
      const realResolved = realpathSync(resolved);
      const relativePath = path.relative(output, resolved);
      const bytes = readFileSync(realResolved);
      assertRealContainedPath(output, resolved, { label: 'Finalized screenshot path after read' });
      demand(realpathSync(resolved) === realResolved, `Screenshot path changed during finalization: ${row.captureId}`);
      const png = validatePng(bytes);
      demand(bytes.length === row.screenshotBytes
        && sha256(bytes) === row.screenshotSha256, `Screenshot hash mismatch: ${row.captureId}`);
      let captureBinding;
      if (row.captureType === 'godot-rendered-viewport') {
        const viewport = row.viewportCaptureReceipt;
        demand(viewport?.schema === viewportReceiptSchema && viewport?.captured === true
          && viewport.captureId === row.captureId && viewport.runId === runId
          && viewport.watchdogRunId === runId
          && viewport.runnerId === metadata.runnerId && viewport.phase === row.phase
          && viewport.phaseKind === row.phaseKind
          && viewport.statusSequence === row.statusSequence && viewport.capturePath === row.path
          && viewport.captureName === row.captureName
          && viewport.receiptPath === metadata.viewportCaptureReceiptPath
          && viewport.screenshotBytes === bytes.length
          && viewport.width === png.width && viewport.height === png.height
          && viewport.sourceIdentityJson === metadata.sourceIdentityJson
          && viewport.sourceIdentitySha256 === metadata.sourceIdentitySha256,
        `Godot viewport receipt mismatch: ${row.captureId}`);
        captureBinding = { viewportCaptureReceipt: viewport };
      } else {
        demand(row.captureType === 'owned-window'
          && row.nativeCaptureReceipt?.runId === runId
          && row.nativeCaptureReceipt?.window?.Pid === row.pid
          && String(row.nativeCaptureReceipt?.window?.Hwnd) === row.windowHandle,
        `HWND/PID capture receipt mismatch: ${row.captureId}`);
        captureBinding = { windowHandle: row.windowHandle, pid: row.pid,
          ownershipSequence: row.ownershipSequence };
      }
      captures.push({
        captureId: row.captureId, runnerId: row.runnerId, runId: row.runId,
        watchdogRunId: row.watchdogRunId, phase: row.phase, phaseKind: row.phaseKind,
        statusSequence: row.statusSequence,
        captureType: row.captureType, sourceIdentity: row.sourceIdentity,
        sourceSha256: row.sourceSha256, sourceIdentitySha256: row.sourceIdentitySha256,
        captureName: String(row.captureName ?? ''),
        elapsedMilliseconds: row.elapsedMilliseconds, capturedAtUnixMilliseconds: row.capturedAtUnixMilliseconds,
        relativePath: relativePath.split(path.sep).join('/'), bytes: bytes.length, sha256: row.screenshotSha256,
        ...captureBinding,
      });
    });
    const cleanupPassed = watchdogSummary.cleanupPassed === true && watchdogSummary.authoritativeZeroProven === true
      && watchdogSummary.overallExitCode === 0 && watchdogSummary.functionalExitCode === 0;
    const processAcceptancePassed = cleanupPassed && acceptancePassed === true
      && captures.length > 0 && captureFailures.length === 0;
    const evidence = {
      schema: evidenceSchema, runnerId: metadata.runnerId, runId,
      watchdogRunId: runId, startedAtUtc, finishedAtUtc: new Date().toISOString(),
      sourceIdentity: finalSourceIdentity, sourceIdentitySha256: metadata.sourceIdentitySha256,
      captureMode: metadata.captureMode, watchdog: watchdogSummary, captures, captureFailures,
      diagnostics: diagnostics.slice(-32).map(row => ({ ...row })),
      accepted: false,
      acceptancePassed: acceptancePassed === true,
      processAcceptancePassed,
      visualInspection: { status: captures.length > 0 ? 'pending' : 'unavailable',
        requiredCaptureIds: captures.map(row => row.captureId), reviewedCaptureSha256: [] },
    };
    atomicJson(evidencePath, evidence);
    return evidence;
  }

  return { metadata, publishPhase, environment, captureScreenshot, captureFailure, recordCaptureFailure, finalize };
}

function readEvidenceSafely(file) {
  const absolute = path.resolve(file);
  const root = path.dirname(absolute);
  assertRealContainedPath(root, absolute, { label: 'Visual evidence file' });
  const realFile = realpathSync(absolute);
  const bytes = readFileSync(realFile);
  assertRealContainedPath(root, absolute, { label: 'Visual evidence file after read' });
  demand(realpathSync(absolute) === realFile, 'Visual evidence path changed while it was being read');
  let value;
  try { value = JSON.parse(bytes.toString('utf8').replace(/^\uFEFF/, '')); }
  catch (error) { throw new Error(`Cannot parse visual evidence: ${error.message}`, { cause: error }); }
  return { absolute, root, realFile, bytes, sha256: sha256(bytes), value };
}

/** Verify PNG hashes and run/window identity before opening images for review. */
export function inspectScreenshotBinding({ evidencePath, expectedRunId }) {
  validateRunId(expectedRunId);
  const evidenceFile = readEvidenceSafely(evidencePath);
  const { absolute, root: outputRoot, value: evidence } = evidenceFile;
  demand(evidence.schema === evidenceSchema && evidence.runId === expectedRunId && evidence.watchdogRunId === expectedRunId,
    'Visual evidence runId mismatch');
  demand(typeof evidence.runnerId === 'string' && evidence.runnerId.trim(), 'Visual evidence runnerId is missing');
  const hasSourceIdentityDigest = typeof evidence.sourceIdentitySha256 === 'string';
  if (hasSourceIdentityDigest) {
    demand(sha256(Buffer.from(canonicalJson(evidence.sourceIdentity), 'utf8')) === evidence.sourceIdentitySha256,
      'Visual evidence source identity digest mismatch');
  } else {
    demand(evidence.captureMode !== 'godot_viewport', 'Viewport evidence is missing its source identity digest');
  }
  demand(Array.isArray(evidence.captures) && evidence.captures.length > 0, 'Visual evidence has no captures');
  const captures = evidence.captures.map(row => {
    const fullPath = path.resolve(outputRoot, row.relativePath);
    demand(isWithinPath(outputRoot, fullPath), 'Screenshot escaped the visual evidence directory');
    assertRealContainedPath(outputRoot, fullPath, { label: 'Screenshot inspection path' });
    demand(lstatSync(fullPath).isFile(), 'Screenshot is not a regular file');
    const realFullPath = realpathSync(fullPath);
    const bytes = readFileSync(realFullPath);
    assertRealContainedPath(outputRoot, fullPath, { label: 'Screenshot inspection path after read' });
    demand(realpathSync(fullPath) === realFullPath, 'Screenshot path changed during inspection');
    const png = validatePng(bytes);
    demand(bytes.length === row.bytes && sha256(bytes) === row.sha256,
      'Screenshot hash or PNG mismatch');
    demand(row.runnerId === evidence.runnerId && row.runId === expectedRunId
      && row.watchdogRunId === expectedRunId,
    'Screenshot runner/run identity mismatch');
    const captureModeType = evidence.captureMode === 'godot_viewport'
      ? 'godot-rendered-viewport' : 'owned-window';
    demand(row.captureType === captureModeType || (!evidence.captureMode && row.captureType === undefined),
      'Screenshot capture mode mismatch');
    if (hasSourceIdentityDigest) {
      demand(row.sourceIdentitySha256 === evidence.sourceIdentitySha256
        && canonicalJson(row.sourceIdentity) === canonicalJson(evidence.sourceIdentity)
        && canonicalJson(row.sourceSha256) === canonicalJson(evidence.sourceIdentity?.sourceSha256 ?? {}),
      `Screenshot source identity/hash mismatch: ${row.captureId}`);
    }
    if (row.captureType === 'godot-rendered-viewport') {
      const viewport = row.viewportCaptureReceipt;
      const receiptPath = path.resolve(outputRoot, viewport?.receiptPath ?? '');
      demand(isWithinPath(outputRoot, receiptPath), 'Viewport receipt path escaped the run directory');
      demand(receiptPath === path.join(outputRoot, 'viewport-capture-receipt.json'),
        'Viewport receipt path does not match this headed run');
      assertRealContainedPath(outputRoot, receiptPath, {
        allowMissingLeaf: true, label: 'Embedded viewport receipt path',
      });
      demand(viewport?.schema === viewportReceiptSchema && viewport?.captureType === 'godot-rendered-viewport'
        && viewport?.captured === true && viewport.captureId === row.captureId
        && viewport.runnerId === row.runnerId && viewport.runId === row.runId
        && viewport.watchdogRunId === row.watchdogRunId
        && viewport.statusSequence === row.statusSequence && viewport.phase === row.phase
        && viewport.phaseKind === row.phaseKind && viewport.captureName === row.captureName
        && path.resolve(viewport.capturePath) === fullPath
        && viewport.screenshotBytes === bytes.length
        && viewport.width === png.width && viewport.height === png.height
        && viewport.sourceIdentityJson === canonicalJson(evidence.sourceIdentity)
        && viewport.sourceIdentitySha256 === evidence.sourceIdentitySha256
        && row.sourceIdentitySha256 === evidence.sourceIdentitySha256,
      'Screenshot viewport receipt mismatch');
    } else {
      demand((row.captureType === 'owned-window' || row.captureType === undefined)
        && row.windowHandle && row.pid > 0,
        `Screenshot HWND/PID identity mismatch: ${row.captureId}`);
    }
    return { captureId: row.captureId, runnerId: row.runnerId, runId: row.runId, phase: row.phase,
      phaseKind: row.phaseKind, captureType: row.captureType, elapsedMilliseconds: row.elapsedMilliseconds,
      statusSequence: row.statusSequence,
      screenshotPath: realFullPath, screenshotSha256: row.sha256,
      sourceIdentity: row.sourceIdentity, sourceSha256: row.sourceSha256,
      sourceIdentitySha256: row.sourceIdentitySha256,
      ...(row.captureType === 'godot-rendered-viewport'
        ? { viewportCaptureReceipt: row.viewportCaptureReceipt }
        : { windowHandle: row.windowHandle, pid: row.pid }),
      metadataBindingPassed: true, visualInspectionRequired: true };
  });
  const evidenceAfterInspection = readEvidenceSafely(absolute);
  demand(evidenceAfterInspection.sha256 === evidenceFile.sha256
    && evidenceAfterInspection.realFile === evidenceFile.realFile,
  'Visual evidence changed while its screenshots were being inspected');
  return { schema: 'voxel-automated-test-screenshot-inspection/v1', runnerId: evidence.runnerId,
    runId: expectedRunId, evidenceSha256: evidenceFile.sha256, captures };
}

/** Reviewer receipts must cover every image and match its recorded SHA-256. */
export function validateVisualInspection(evidence, review) {
  demand(review?.schema === reviewSchema && review.runnerId === evidence?.runnerId && review.runId === evidence?.runId,
    'Visual-review identity does not match evidence run');
  demand(typeof review.reviewer === 'string' && review.reviewer.trim(), 'Visual reviewer identity is required');
  const expected = new Map((evidence.captures ?? []).map(row => [row.captureId, row.sha256]));
  const reviewed = new Map((review.captures ?? []).map(row => [row.captureId, row]));
  demand(expected.size > 0 && Array.isArray(review.captures)
    && review.captures.length === expected.size && reviewed.size === expected.size,
  'Review must include every capture exactly once');
  for (const [captureId, hash] of expected) {
    const row = reviewed.get(captureId);
    demand(row?.screenshotSha256 === hash && row.inspected === true && ['pass', 'fail'].includes(row.result)
      && typeof row.notes === 'string' && row.notes.trim(), `Missing hash-matched visual inspection: ${captureId}`);
  }
  const visualInspection = {
    status: [...reviewed.values()].every(row => row.result === 'pass') ? 'passed' : 'failed',
    reviewer: review.reviewer.trim(), inspectedAtUtc: review.inspectedAtUtc,
    reviewedCaptureIds: [...reviewed.keys()], reviewedCaptureSha256: [...reviewed.values()].map(row => row.screenshotSha256),
    reviewedCaptures: [...reviewed.values()].map(row => ({ captureId: row.captureId,
      screenshotSha256: row.screenshotSha256, inspected: true, result: row.result, notes: row.notes.trim() })),
  };
  return { ...evidence, visualInspection,
    accepted: evidence.processAcceptancePassed === true && visualInspection.status === 'passed' };
}

/** Validate every image and persist the hash-bound review as a new evidence file. */
export function persistVisualInspection({ evidencePath, review, outputPath }) {
  const sourcePath = path.resolve(evidencePath);
  const sourceRead = readEvidenceSafely(sourcePath);
  const evidence = sourceRead.value;
  const initialBinding = inspectScreenshotBinding({ evidencePath: sourcePath, expectedRunId: evidence.runId });
  demand(initialBinding.evidenceSha256 === sourceRead.sha256,
    'Visual evidence changed between review read and screenshot validation');
  const reviewed = validateVisualInspection(evidence, review);
  const destination = path.resolve(outputPath ?? path.join(path.dirname(sourcePath), 'visual-evidence-reviewed.json'));
  demand(destination !== sourcePath, 'Reviewed evidence must be written to a new path');
  const destinationRoot = path.dirname(destination);
  assertRealContainedPath(destinationRoot, destination, { allowMissingLeaf: true, label: 'Reviewed evidence path' });
  demand(!pathEntryExists(destination), `Fresh reviewed-evidence path required: ${destination}`);
  const finalBinding = inspectScreenshotBinding({ evidencePath: sourcePath, expectedRunId: evidence.runId });
  demand(finalBinding.evidenceSha256 === initialBinding.evidenceSha256,
    'Visual evidence changed during review validation');
  atomicJson(destination, reviewed);
  return { outputPath: destination, runId: reviewed.runId, runnerId: reviewed.runnerId,
    accepted: reviewed.accepted, visualInspectionStatus: reviewed.visualInspection.status };
}

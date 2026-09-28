import { access, readFile, writeFile } from 'node:fs/promises';
import { isAbsolute, join, resolve } from 'node:path';

export const evidenceLevels = [
  'unit', 'contract', 'synthetic', 'static_audit', 'integration',
  'acceptance_visual', 'scene-load-smoke',
];

// PowerShell property access and string comparisons are case-insensitive.
function propertyKey(object, name) {
  return Object.keys(object ?? {}).find((key) => key.toLowerCase() === name.toLowerCase());
}
function getProp(object, name) {
  return object?.[propertyKey(object, name)];
}
function setProp(object, name, value) {
  const oldKey = propertyKey(object, name);
  if (oldKey !== undefined && oldKey !== name) delete object[oldKey];
  object[name] = value;
}
function psString(value) {
  if (value == null) return '';
  if (typeof value === 'boolean') return value ? 'True' : 'False';
  return String(value);
}
function equal(left, right) {
  return psString(left).toLowerCase() === psString(right).toLowerCase();
}

// Do not trim, split commas, discard duplicates, or ignore scalar claims.
export function evidenceStringArray(value) {
  return (Array.isArray(value) ? value : [value])
    .filter((item) => item != null)
    .flatMap((item) => psString(item).split(';').filter((part) => part !== ''));
}
function sameStringSet(left, right) {
  const a = left.map((item) => item.toLowerCase()).sort();
  const b = right.map((item) => item.toLowerCase()).sort();
  return a.length === b.length && a.every((item, index) => item === b[index]);
}
function valueCount(value) {
  // Get-PropValue's PowerShell pipeline unwraps a singleton array before
  // Value-Count receives it; [null] therefore supplies no proof.
  if (Array.isArray(value) && value.length === 1) value = value[0];
  return value == null ? 0 : Array.isArray(value) ? value.length : 1;
}
function switchValue(value) {
  return value === true || (typeof value === 'string' && /^(true|\$true|1|yes|on)$/i.test(value));
}
async function exists(path) {
  try { await access(path); return true; } catch { return false; }
}

export async function readEvidenceJson(path) {
  const bytes = await readFile(path);
  const text = bytes[0] === 0xff && bytes[1] === 0xfe
    ? bytes.toString('utf16le') : bytes.toString('utf8');
  return JSON.parse(text.replace(/^\uFEFF/, ''));
}
export async function writeEvidenceJson(path, value) {
  await writeFile(path, JSON.stringify(value, null, 2) + '\n', 'utf8');
}

/**
 * Port of assert-test-evidence-report.ps1. Returns the success summary; on
 * validation failure stamps every error before throwing. Missing/invalid JSON
 * invalid parameters, and a relative screenshot without ScreenshotDir fail
 * without stamping (the original Join-Path rejects its empty base path).
 * RegistryPath is provenance,
 * not a registry lookup. This checks evidence structure, not gameplay success.
 * Run-token authentication and report freshness belong to the launching runner,
 * as in PowerShell; this port preserves their fields without inventing proof.
 *
 * Aggregate callers can pass their project root as cwd for relative registry
 * paths. Standalone calls resolve relative paths against the invoking cwd,
 * matching PowerShell GetFullPath.
 */
export async function validateEvidence(options, { cwd = process.cwd() } = {}) {
  for (const name of ['reportPath', 'runnerId']) {
    if (typeof options[name] !== 'string' || options[name].length === 0) {
      throw new Error(`Missing required parameter: ${name}`);
    }
  }
  const evidenceLevel = options.evidenceLevel ?? 'unit';
  if (!evidenceLevels.some((level) => equal(level, evidenceLevel))) {
    throw new Error(`Invalid EvidenceLevel '${evidenceLevel}': expected ${evidenceLevels.join(', ')}`);
  }
  const reportPath = resolve(cwd, options.reportPath);
  const screenshotDir = options.screenshotDir ? resolve(cwd, options.screenshotDir) : '';
  const registryPath = options.registryPath ? resolve(cwd, options.registryPath) : '';
  if (!(await exists(reportPath))) {
    throw new Error(`Evidence report missing for ${options.runnerId}: ${reportPath}`);
  }
  const report = await readEvidenceJson(reportPath);
  if (!report || typeof report !== 'object' || Array.isArray(report)) {
    throw new Error('Evidence report must be a JSON object');
  }
  const errors = [];
  const expectedClaims = evidenceStringArray(options.acceptanceClaims);
  const requiredScreenshots = evidenceStringArray(options.requiredScreenshots);
  const existingEvidenceLevel = psString(getProp(report, 'evidenceLevel'));
  const existingClaims = evidenceStringArray(getProp(report, 'acceptanceClaims'));
  if (existingEvidenceLevel !== '' && !equal(existingEvidenceLevel, evidenceLevel)) {
    errors.push(`report evidenceLevel '${existingEvidenceLevel}' does not match registry evidenceLevel '${evidenceLevel}'`);
  }
  if (existingClaims.length > 0 && !sameStringSet(existingClaims, expectedClaims)) {
    errors.push(`report acceptanceClaims '${existingClaims.join(',')}' do not match registry acceptanceClaims '${expectedClaims.join(',')}'`);
  }
  if (expectedClaims.length > 0 && !equal(evidenceLevel, 'acceptance_visual')) {
    errors.push('acceptanceClaims are only allowed for acceptance_visual runners');
  }
  if (expectedClaims.length > 0 || switchValue(options.requireForbiddenCallSelfScan)) {
    if (!equal(getProp(getProp(report, 'forbiddenCallSelfScan'), 'status'), 'passed')) {
      errors.push('acceptance report must include forbiddenCallSelfScan.status == passed');
    }
  }
  if (equal(evidenceLevel, 'acceptance_visual') || switchValue(options.requireVisualProof)) {
    if (equal(evidenceLevel, 'acceptance_visual') && expectedClaims.length === 0) {
      errors.push('acceptance_visual runner must declare at least one acceptance claim');
    }
    if (requiredScreenshots.length === 0) {
      errors.push('visual-evidence runner must declare required screenshots');
    }
    for (const fileName of requiredScreenshots) {
      if (screenshotDir === '' && !isAbsolute(fileName)) {
        throw new Error(`required screenshot '${fileName}' is relative but no ScreenshotDir was provided`);
      }
      const candidate = isAbsolute(fileName) ? fileName : join(screenshotDir, fileName);
      if (!(await exists(candidate))) errors.push(`required screenshot missing: ${candidate}`);
    }
    const captureCount = ['captures', 'visualCaptures']
      .reduce((count, key) => count + valueCount(getProp(report, key)), 0);
    if (captureCount <= 0) errors.push('visual-evidence report must include captures or visualCaptures');
    const timelineCount = ['timeline', 'timelineTail', 'miraTimeline', 'doorStateTimeline']
      .reduce((count, key) => count + valueCount(getProp(report, key)), 0);
    if (timelineCount <= 0) errors.push('visual-evidence report must include timeline proof');
  }
  setProp(report, 'evidenceLevel', evidenceLevel);
  setProp(report, 'acceptanceClaims', expectedClaims);
  setProp(report, 'testIntegrity', {
    registryId: options.runnerId,
    registryPath,
    evidenceLevel,
    liveGameplayAcceptance: expectedClaims.length > 0,
    requiredScreenshots,
    validationStatus: errors.length === 0 ? 'passed' : 'failed',
    validationErrors: errors,
    stampedUtc: new Date().toISOString(),
  });
  await writeEvidenceJson(reportPath, report);
  if (errors.length > 0) {
    throw new Error(`Evidence validation failed for ${options.runnerId}: ${errors.join('; ')}`);
  }
  return { runnerId: options.runnerId, reportPath, evidenceLevel, acceptanceClaims: expectedClaims, status: 'passed' };
}

// Integration export for aggregate runEvidenceValidation; no shared runtime import.
export const runEvidenceValidation = validateEvidence;

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, readFile, writeFile, rm, copyFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { evidenceLevels, evidenceStringArray, readEvidenceJson, runEvidenceValidation } from '../lib/evidence-validation.mjs';
import { parseEvidenceArguments, runEvidenceStaticTool } from '../lib/evidence-cli.mjs';
import { runEvidenceRegistrySelfTest } from '../lib/evidence-self-test.mjs';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const validator = join(projectRoot, 'tools/assert-test-evidence-report.mjs');
const baseline = await readEvidenceJson(join(projectRoot, 'tools/tests/fixtures/evidence-powershell-baseline.json'));
function normalizeOracle(value, dir) {
  if (typeof value === 'string') return value.replaceAll(dir, '<WORK_DIR>').replaceAll('\\', '/');
  if (Array.isArray(value)) return value.map((item) => normalizeOracle(item, dir));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, normalizeOracle(item, dir)]));
  return value;
}

async function sandbox(t) {
  const dir = await mkdtemp(join(tmpdir(), 'voxel-evidence-parity-'));
  // Only remove the exact directory returned by mkdtemp, never a project path.
  t.after(() => rm(dir, { recursive: true, force: true }));
  await mkdir(join(dir, 'screens [literal]'));
  await writeFile(join(dir, 'screens [literal]', 'spawn.png'), 'static-audit placeholder');
  await writeFile(join(dir, 'screens [literal]', 'door.png'), 'static-audit placeholder');
  return dir;
}
function argsFor(options) {
  return Object.entries(options).flatMap(([key, value]) => {
    if (value === false || value === undefined) return [];
    return value === true ? ['-' + key] : ['-' + key, String(value)];
  });
}
function invokeNode(args, cwd) {
  const result = spawnSync(process.execPath, [validator, ...args], { cwd, encoding: 'utf8', windowsHide: true });
  assert.ifError(result.error);
  assert.notEqual(result.status, null, result.stderr);
  return result;
}
function withoutTimestamp(report) {
  const clone = structuredClone(report);
  if (clone.testIntegrity) {
    assert.ok(Number.isFinite(Date.parse(clone.testIntegrity.stampedUtc)));
    delete clone.testIntegrity.stampedUtc;
  }
  return clone;
}
const visualReport = {
  forbiddenCallSelfScan: { status: 'passed' },
  captures: [{ saved: true }],
  timeline: [{ event: 'door_open' }],
  payload: { preserved: ['do not replace gameplay fields'] },
};
const visualOptions = {
  evidenceLevel: 'acceptance_visual', acceptanceClaims: 'real_behavior',
  requiredScreenshots: 'spawn.png;door.png', screenshotDir: 'screens [literal]',
};
const cases = baseline.cases;

for (const fixture of cases) {
  test('validator contract: ' + fixture.name, async (t) => {
    const dir = await sandbox(t);
    const reportPath = join(dir, 'report.json');
    const options = { reportPath: 'report.json', runnerId: 'fixture', registryPath: 'registry.json', ...fixture.options };
    if (options.requiredScreenshots === '$ABSOLUTE') options.requiredScreenshots = join(dir, 'screens [literal]', 'spawn.png');
    await writeFile(reportPath, JSON.stringify(fixture.report));
    const execution = invokeNode(argsFor(options), dir);
    assert.equal(execution.status === 0, fixture.passed, execution.stderr);
    const actual = await readEvidenceJson(reportPath);
    assert.equal(actual.testIntegrity.validationStatus, fixture.passed ? 'passed' : 'failed');
    assert.deepEqual(actual.acceptanceClaims, evidenceStringArray(options.acceptanceClaims));
    if (fixture.passed) assert.equal(JSON.parse(execution.stdout).status, 'passed');
    else assert.match(execution.stderr, /Evidence validation failed/);
    assert.equal(execution.status, fixture.exitCode);
    assert.deepEqual(normalizeOracle(withoutTimestamp(actual), dir), fixture.stampedReport);
    if (fixture.passed) assert.deepEqual(normalizeOracle(JSON.parse(execution.stdout), dir), fixture.summary);
  });
}

test('invalid CLI inputs and invalid files fail without stamping', async (t) => {
  const dir = await sandbox(t);
  const reportPath = join(dir, 'report.json');
  const inputs = [
    ['-ReportPath', reportPath],
    ['-RunnerId', 'fixture'],
    ['-ReportPath', reportPath, '-RunnerId', 'fixture', '-EvidenceLevel', 'bogus'],
    ['-ReportPath', reportPath, '-RunnerId', 'fixture', '-Unknown', 'ignored'],
    ['-ReportPath', reportPath, '-RunnerId', 'fixture', '-RequireVisualProof=maybe'],
  ];
  for (const args of inputs) {
    await writeFile(reportPath, '{}');
    assert.equal(invokeNode(args, dir).status, 1);
    assert.equal(await readFile(reportPath, 'utf8'), '{}');
  }
  await writeFile(reportPath, '{invalid json');
  assert.equal(invokeNode(['-ReportPath', reportPath, '-RunnerId', 'fixture'], dir).status, 1);
  assert.equal(await readFile(reportPath, 'utf8'), '{invalid json');
  await rm(reportPath);
  assert.match(invokeNode(['-ReportPath', reportPath, '-RunnerId', 'fixture'], dir).stderr, /Evidence report missing/);
});

test('relative screenshot without directory is rejected', async (t) => {
  const dir = await sandbox(t);
  const reportPath = join(dir, 'report.json');
  await writeFile(reportPath, JSON.stringify(visualReport));
  const options = { ...visualOptions, screenshotDir: '', reportPath, runnerId: 'fixture' };
  const result = invokeNode(argsFor(options), dir);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /relative but no ScreenshotDir/);
  assert.deepEqual(await readEvidenceJson(reportPath), visualReport);
  assert.equal(result.status, baseline.relativeScreenshotWithoutDirectory.exitCode);
  assert.equal(baseline.relativeScreenshotWithoutDirectory.stamped, false);
});

test('aggregate export supports arrays, semicolons, BOM and caller path base', async (t) => {
  const dir = await sandbox(t);
  const reportPath = join(dir, 'report.json');
  for (const encoding of ['utf8', 'utf16le']) {
    await writeFile(reportPath, '\uFEFF' + JSON.stringify({ ...visualReport, acceptanceClaims: ['b', 'A'] }), encoding);
    const result = await runEvidenceValidation({
      ...visualOptions, reportPath: 'report.json', runnerId: 'aggregate',
      acceptanceClaims: [null, 'a;;', 'b'], requiredScreenshots: ['spawn.png;door.png'],
    }, { cwd: dir });
    assert.equal(result.reportPath, reportPath);
    assert.deepEqual(result.acceptanceClaims, ['a', 'b']);
  }
});

test('CLI aliases and explicit switches preserve requests', () => {
  assert.deepEqual(parseEvidenceArguments([
    '--report-path=report.json', '-RunnerId', 'fixture', '-RequireVisualProof:$false',
    '--require-forbidden-call-self-scan', 'true',
  ]), { reportPath: 'report.json', runnerId: 'fixture', requireVisualProof: false, requireForbiddenCallSelfScan: true });
  assert.throws(() => parseEvidenceArguments(['-RunnerId']), /Missing value/);
  assert.throws(() => parseEvidenceArguments(['-RunnerId', 'a', '-RunnerId', 'b']), /Duplicate/);
});

test('static dispatch invokes validator and ignores unrelated tools', async (t) => {
  const dir = await sandbox(t);
  await writeFile(join(dir, 'report.json'), '{}');
  let output = '';
  const context = { cwd: dir, stdout: { write: (text) => { output += text; } } };
  assert.equal(await runEvidenceStaticTool('unrelated', [], context), false);
  assert.equal(output, '');
  assert.equal(await runEvidenceStaticTool('assert-test-evidence-report', ['-ReportPath', 'report.json', '-RunnerId', 'dispatch'], context), true);
  assert.equal(JSON.parse(output).runnerId, 'dispatch');
});

test('self-test runs all four real CLI controls and matches PowerShell report', async (t) => {
  const dir = await sandbox(t);
  const workDir = join(dir, 'artifacts/test-runners/evidence-self-test');
  await mkdir(workDir, { recursive: true });
  const staleReport = { runToken: 'stale-fixture', passed: true, resultCount: 999, testIntegrity: { validationStatus: 'passed' } };
  for (const name of ['synthetic-claims-acceptance.json', 'good-acceptance.json', 'integration-visual-without-claims.json', 'bad-guard-acceptance.json']) {
    await writeFile(join(workDir, name), JSON.stringify(staleReport));
  }
  await writeFile(join(dir, 'artifacts/test-runners/test-evidence-registry-self-test.json'), JSON.stringify(staleReport));
  const report = await runEvidenceRegistrySelfTest({}, { projectRoot: dir, cwd: dir });
  assert.equal(report.passed, true);
  assert.equal(report.resultCount, 4);
  assert.equal(report.failureCount, 0);
  assert.deepEqual(report.results.map((result) => result.details), ['exitCode=1', 'exitCode=0', 'exitCode=0', 'exitCode=1']);
  assert.equal(report.testIntegrity.validationStatus, 'passed');
  assert.equal(report.runToken, undefined);
  for (const name of ['synthetic-claims-acceptance.json', 'good-acceptance.json', 'integration-visual-without-claims.json', 'bad-guard-acceptance.json']) {
    const fixture = await readEvidenceJson(join(workDir, name));
    assert.equal(fixture.runToken, undefined, 'stale fixture must be replaced');
    assert.ok(fixture.testIntegrity.stampedUtc, 'validator must actually write the child stamp');
  }
  assert.equal((await readEvidenceJson(join(workDir, 'synthetic-claims-acceptance.json'))).testIntegrity.validationStatus, 'failed');
  assert.equal((await readEvidenceJson(join(workDir, 'bad-guard-acceptance.json'))).testIntegrity.validationStatus, 'failed');
  assert.deepEqual(normalizeOracle(withoutTimestamp(report), dir), baseline.selfTest);
});

for (const exitCode of [0, 1]) {
  test('self-test rejects an always-' + (exitCode ? 'fail' : 'pass') + ' validator (synthetic mutation control)', async (t) => {
    const dir = await sandbox(t);
    let calls = 0;
    const context = { projectRoot: dir, cwd: dir, executeEvidence: () => { calls += 1; return { exitCode }; } };
    const report = await runEvidenceRegistrySelfTest({}, context);
    assert.equal(calls, 4);
    assert.equal(report.passed, false);
    assert.equal(report.failureCount, 2);
    assert.equal(report.results.filter((result) => !result.passed).length, 2);
    let output = '';
    await assert.rejects(runEvidenceStaticTool('test-evidence-registry-self-test', [], {
      ...context, stdout: { write: (text) => { output += text; } },
    }), /self-test failed/);
    assert.equal(JSON.parse(output).passed, false);
  });
}


test('frozen oracle records original source provenance and complete contract inventory', () => {
  assert.equal(baseline.schemaVersion, 1);
  assert.match(baseline.provenance.baselineCommit, /^[a-f0-9]{40}$/);
  assert.equal(baseline.provenance.scripts.length, 2);
  for (const source of baseline.provenance.scripts) {
    assert.match(source.sha256, /^[a-f0-9]{64}$/);
    assert.match(source.gitBlob, /^[a-f0-9]{40}$/);
  }
  assert.equal(cases.length, 42);
  assert.equal(new Set(cases.map((fixture) => fixture.name)).size, cases.length);
  assert.equal(baseline.selfTest.results.length, 4);
});

test('both entrypoints work with only Node files and no executable search path', async (t) => {
  const dir = await sandbox(t);
  await mkdir(join(dir, 'tools/lib'), { recursive: true });
  for (const name of [
    'assert-test-evidence-report.mjs', 'test-evidence-registry-self-test.mjs',
    'lib/evidence-validation.mjs', 'lib/evidence-cli.mjs', 'lib/evidence-self-test.mjs',
  ]) {
    await copyFile(join(projectRoot, 'tools', name), join(dir, 'tools', name));
  }
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => key.toLowerCase() !== 'path'));
  env.PATH = '';
  for (const [entrypoint, args] of [
    ['test-evidence-registry-self-test.mjs', ['-ReportPath', 'isolated-self-test.json']],
    ['assert-test-evidence-report.mjs', ['-ReportPath', 'isolated-self-test.json', '-RunnerId', 'isolated', '-EvidenceLevel', 'static_audit']],
  ]) {
    const execution = spawnSync(process.execPath, [join(dir, 'tools', entrypoint), ...args], {
      cwd: dir, env, encoding: 'utf8', windowsHide: true,
    });
    assert.ifError(execution.error);
    assert.equal(execution.status, 0, execution.stderr);
  }
  const report = await readEvidenceJson(join(dir, 'isolated-self-test.json'));
  assert.equal(report.resultCount, 4);
  assert.equal(report.failureCount, 0);
  assert.equal(report.testIntegrity.registryId, 'isolated');
});

import { mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { readEvidenceJson, validateEvidence, writeEvidenceJson } from './evidence-validation.mjs';

const defaultProjectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

/**
 * The four original PowerShell controls exercise the actual validator CLI in
 * child Node processes. Placeholder screenshots are static-audit fixtures only.
 * projectRoot/cwd allow isolated test sandboxes; executeEvidence is a unit-test
 * seam used to prove an always-pass/always-fail validator cannot pass this suite.
 */
export async function runEvidenceRegistrySelfTest(options = {}, {
  projectRoot = defaultProjectRoot,
  cwd = process.cwd(),
  executeEvidence,
} = {}) {
  const reportPath = options.reportPath
    ? resolve(cwd, options.reportPath)
    : join(projectRoot, 'artifacts/test-runners/test-evidence-registry-self-test.json');
  const workDir = join(projectRoot, 'artifacts/test-runners/evidence-self-test');
  const registryPath = join(projectRoot, 'tools/test-runner-registry.json');
  const evidenceScript = join(defaultProjectRoot, 'tools/assert-test-evidence-report.mjs');
  await mkdir(dirname(reportPath), { recursive: true });
  await mkdir(workDir, { recursive: true });
  await rm(reportPath, { force: true });
  const execute = executeEvidence ?? ((args) => {
    const result = spawnSync(process.execPath, [evidenceScript, ...args], { cwd, encoding: 'utf8', windowsHide: true });
    if (result.error) throw result.error;
    if (result.status === null) throw new Error(`Evidence validator terminated: ${result.signal}`);
    return { exitCode: result.status };
  });
  const results = [];
  async function runCase(name, fileName, report, args, shouldPass) {
    const casePath = join(workDir, fileName);
    await writeEvidenceJson(casePath, report);
    const execution = await execute([
      '-ReportPath', casePath, '-RunnerId', report.testId,
      ...args, '-RegistryPath', registryPath,
    ]);
    results.push({
      name,
      passed: shouldPass ? execution.exitCode === 0 : execution.exitCode !== 0,
      details: `exitCode=${execution.exitCode}`,
    });
  }
  const base = { schemaVersion: 1, finished: true, passed: true, failureCount: 0, resultCount: 1 };
  await runCase('synthetic_report_claiming_acceptance_fails', 'synthetic-claims-acceptance.json', {
    ...base, testId: 'synthetic_claims_acceptance', evidenceLevel: 'acceptance_visual',
    acceptanceClaims: ['fake_live_door_traversal'], resultCount: 0,
  }, ['-EvidenceLevel', 'synthetic'], false);

  const screenshotDir = join(workDir, 'good-acceptance-screenshots');
  await mkdir(screenshotDir, { recursive: true });
  for (const fileName of ['spawn.png', 'door_open.png']) {
    await writeFile(join(screenshotDir, fileName), 'placeholder screenshot proof\n');
  }
  const proof = {
    captures: [{ stage: 'spawn', saved: true }],
    timeline: [{ event: 'door_open', time: 1.0 }],
  };
  const visualArgs = ['-RequiredScreenshots', 'spawn.png;door_open.png', '-ScreenshotDir', screenshotDir, '-RequireVisualProof'];
  const acceptanceArgs = [
    '-EvidenceLevel', 'acceptance_visual', '-AcceptanceClaims', 'proves_real_behavior',
    ...visualArgs, '-RequireForbiddenCallSelfScan',
  ];
  await runCase('acceptance_report_with_guard_screenshots_and_timeline_passes', 'good-acceptance.json', {
    ...base, testId: 'good_acceptance', forbiddenCallSelfScan: { status: 'passed' }, ...proof,
  }, acceptanceArgs, true);
  await runCase('integration_visual_report_without_acceptance_claims_passes', 'integration-visual-without-claims.json', {
    ...base, testId: 'integration_visual_without_claims', evidenceLevel: 'integration', acceptanceClaims: [],
    ...proof, timeline: [{ event: 'camera_pose', time: 1.0 }],
  }, ['-EvidenceLevel', 'integration', ...visualArgs], true);
  await runCase('acceptance_report_with_failed_guard_fails', 'bad-guard-acceptance.json', {
    ...base, testId: 'bad_guard_acceptance', forbiddenCallSelfScan: { status: 'failed' }, ...proof,
  }, acceptanceArgs, false);

  const failureCount = results.filter((result) => !result.passed).length;
  await writeEvidenceJson(reportPath, {
    schemaVersion: 1, testId: 'test_evidence_registry_self_test', evidenceLevel: 'static_audit',
    acceptanceClaims: [], finished: true, passed: failureCount === 0,
    failureCount, resultCount: results.length, results,
  });
  await validateEvidence({
    reportPath, runnerId: 'test_evidence_registry_self_test', evidenceLevel: 'static_audit', registryPath,
  });
  return readEvidenceJson(reportPath);
}

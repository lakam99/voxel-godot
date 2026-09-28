import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { parseAuditArguments, projectRoot } from './npc-source-audit.mjs';

export async function runAcceptanceGuardSelfTest(rawArgs = process.argv.slice(2)) {
  if(rawArgs.some(arg=>/^(--?help|-h)$/i.test(arg))) { console.log('Usage: node tools/npc/test-npc-acceptance-guard.mjs [--report-path PATH]');return; }
  const options = parseAuditArguments(rawArgs);
  const reportPath = options.reportpath
    ? resolve(String(options.reportpath).replaceAll('\\', '/'))
    : join(projectRoot, 'artifacts/npc/reports/npc-acceptance-guard-self-test.json');
  const workDir = join(projectRoot, 'artifacts/npc/guard-self-test');
  await mkdir(dirname(reportPath), { recursive: true });
  await mkdir(workDir, { recursive: true });
  await rm(reportPath, { force: true });
  const results = [];
  const addResult = (name, passed, details) => results.push({ name, passed, details });
  const runGuard = (runnerPath, outReport, testId, allowed = []) => spawnSync(process.execPath, [
    join(projectRoot, 'tools/npc/assert-npc-acceptance-runner-clean.mjs'),
    '-RunnerPath', runnerPath, '-ReportPath', outReport, '-TestId', testId, '-PassThruJson',
    ...(allowed.length ? ['-AllowedShortcutPattern', allowed.join(';')] : []),
  ], { encoding: 'utf8', cwd: projectRoot });
  const guardReports = {
    realTutorial: join(workDir, 'real-tutorial-guard.json'),
    goHomeVisual: join(workDir, 'go-home-visual-guard.json'),
    fakeRunner: join(workDir, 'fake-runner-guard-report.json'),
    fixedPostLoadDelay: join(workDir, 'fixed-post-load-delay-guard-report.json'),
  };
  // Clear only our named reports so prior failures cannot masquerade as fresh evidence.
  for (const path of Object.values(guardReports)) await rm(path, { force: true });
  const tutorial = runGuard(
    join(projectRoot, 'scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd'),
    guardReports.realTutorial, 'npc_tutorial_real_knock_repair_sleep_morning_foragers',
    ['final_rescue_fixture_setup_allowance'],
  );
  addResult('guard_passes_real_tutorial_runner_with_documented_fixture_allowance', tutorial.status === 0, 'exitCode=' + tutorial.status);
  const goHome = runGuard(
    join(projectRoot, 'scripts/testing/npc/NpcGoHomeVisualPlaytestRunner.gd'),
    guardReports.goHomeVisual, 'npc_go_home_visual_door_traversal',
    ['safe_place_npc.*visual_go_home_spawn', 'player\\.global_position\\s*=\\s*Vector3\\(float\\(center\\.x - 10\\)'],
  );
  addResult('guard_passes_go_home_runner_with_documented_fixture_allowances', goHome.status === 0, 'exitCode=' + goHome.status);
  const cases = [
    {
      file: 'FakeAcceptanceRunner.gd', report: guardReports.fakeRunner, testId: 'fake_acceptance_runner',
      source: 'extends Node\n\nfunc _ready() -> void:\n    on_door_opened(null)\n',
      name: 'guard_fails_fake_runner_and_reports_offending_line', ruleId: 'direct_tutorial_door_progress',
    },
    {
      file: 'FixedPostLoadDelayRunner.gd', report: guardReports.fixedPostLoadDelay, testId: 'fixed_post_load_delay_acceptance_runner',
      source: 'extends Node\n\nconst STARTUP_FRAMES := 80\n\nfunc _ready() -> void:\n    await wait_physics_frames(STARTUP_FRAMES)\n',
      name: 'guard_fails_fixed_post_load_startup_delay', ruleId: 'fixed_post_load_startup_delay',
    },
  ];
  for (const item of cases) {
    const path = join(workDir, item.file);
    await writeFile(path, item.source);
    const child = runGuard(path, item.report, item.testId);
    let scan;
    try { scan = JSON.parse(await readFile(item.report, 'utf8')).forbiddenCallSelfScan; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const hasOffense = scan?.status === 'failed' && scan.matches?.some((match) => match.ruleId === item.ruleId);
    addResult(item.name, child.status === 1 && Boolean(hasOffense),
      'exitCode=' + child.status + ' guardStatus=' + (scan?.status ?? '') + ' reportHasOffense=' + Boolean(hasOffense));
  }
  const failureCount = results.filter((result) => !result.passed).length;
  const report = {
    schemaVersion: 1, testId: 'npc_acceptance_guard_self_test', evidenceLevel: 'static_audit',
    acceptanceClaims: [], finished: true, passed: failureCount === 0, failureCount,
    resultCount: results.length, results, guardReports,
  };
  await writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');
  const evidence = spawnSync(process.execPath, [
    join(projectRoot, 'tools/assert-test-evidence-report.mjs'),
    '-ReportPath', reportPath, '-RunnerId', 'npc_acceptance_guard_self_test',
    '-EvidenceLevel', 'static_audit', '-RegistryPath', join(projectRoot, 'tools/test-runner-registry.json'),
  ], { encoding: 'utf8', cwd: projectRoot });
  // Evidence validation is a real Node invocation; never turn its failure into success.
  if (evidence.status !== 0) {
    throw new Error('Acceptance guard self-test evidence validation failed: ' + (evidence.error?.message ?? evidence.stderr ?? evidence.stdout));
  }
  const finalReport = JSON.parse(await readFile(reportPath, 'utf8'));
  process.stdout.write(JSON.stringify(finalReport, null, 2) + '\n');
  if (failureCount) process.exitCode = 1;
  return finalReport;
}

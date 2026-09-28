import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import {
  acceptanceRules, routeStateRules, legacyRules, scanSourceLines,
  auditProductionSources, auditNavmeshBackend, liveRuntimeFiles, allowedFiles, projectRoot,
} from './npc-source-audit.mjs';

// Fixed parity fixtures below were derived from tools/npc historical audit sources.
// Baseline commit: e09cc95b6211ecfb7de1fcf9902406b0cb176a5d.
// SHA-256 of Git blob bytes (LF, not the CRLF checkout):
// assert-npc-route-state-writers: 927738240e7aff1fb51ccff4e2b3db3b2b8aac94ee30c3155db095a59c72e32c
// assert-npc-legacy-pathfinding-clean: 19a83515b050029c86737ad5ca9756eb6fe7f23e7280806301b06685fd46bff2
// audit-npc-navmesh-backend: 673cd10e84bdfda62a742648a65a1b1e466b21fba11b1018e0f22d226bdb419e
// assert-npc-acceptance-runner-clean: 8f07e10f329216218b05e38cadb45c29c3fef263ce6fe46a14e15a17051e1fad
// test-npc-acceptance-guard: 6bc0b825bd5fb81378310b96931e34e6b14e1a85addabd557a40c9986cf10f76
// Tests require neither historical PowerShell files nor Git history at runtime.
const routeCases = [
  ['route_status_entry_write', 'entry["routeStatus"] = x'],
  ['route_reason_entry_write', "entry['routeReason'] = x"],
  ['route_lease_entry_write', 'entry["routeLease"] = x'],
  ['route_lease_id_entry_write', 'entry["routeLeaseId"] = x'],
  ['route_lease_generation_entry_write', 'entry["routeLeaseGeneration"] = x'],
  ['route_lease_entry_erase', 'entry.erase("routeLease")'],
  ['route_lease_id_entry_erase', "entry.erase('routeLeaseId')"],
  ['route_status_meta_write', 'body.set_meta("npc_route_status", x)'],
  ['route_reason_meta_write', 'body.set_meta("npc_route_reason", x)'],
  ['route_authority_state_write', 'entry["routeAuthorityState"] = x'],
  ['route_authority_reason_write', 'entry["routeAuthorityReason"] = x'],
  ['route_probe_certificate_write', 'entry["probeCertificate"] = x'],
];
const legacyCases = [
  ['generated_cell_fallback_flag_write', 'entry["safeOpenTerrainGeneratedFallback"] = true'],
  ['generated_cell_public_route_call', 'plan_generated_cell_route(x)'],
  ['generated_cell_private_route_call', '_plan_generated_cell_bridge_route(x)'],
  ['exact_home_lattice_route_call', '_plan_exact_home_collision_lattice_route(x)'],
  ['exact_home_lattice_selector_call', '_should_try_exact_home_collision_lattice_route(x)'],
  ['collision_lattice_repair_call', '_plan_collision_lattice_repair_route(x)'],
  ['fallback_only_generated_bridge_flag', 'entry["generatedBridgeFallbackOnly"] = true'],
  ['home_cell_bridge_repair_flag', 'entry["allowHomeCellBridgeRepair"] = true'],
  ['runtime_partial_endpoint_status', 'status := "partial"'],
];
const guardCases = [
  ['direct_tutorial_door_progress', 'on_door_opened(null)'],
  ['direct_tutorial_interaction', 'interact_with(x)'],
  ['direct_tutorial_completion', 'complete_step(x)'],
  ['direct_block_progress', 'on_block_placed(x)'],
  ['direct_sleep_or_bed_progress', 'on_bed_used(x)'],
  ['inventory_grant', 'inventory_system.add_item(x)'],
  ['direct_npc_movement_helper', 'move_npc(x)'],
  ['direct_door_service', 'request_door_state(x)'],
  ['fake_inside_home_metadata', 'set_meta("npc_inside_home", true)'],
  ['fake_scripted_arrival_metadata', 'set_meta("npc_scripted_arrived", true)'],
  ['actor_transform_write', 'actor.global_position = x'],
  ['safe_place_npc', 'safe_place_npc(x)'],
  ['source_scan_acceptance', 'read_text(x)'],
  ['fixed_post_load_startup_delay', 'await wait_physics_frames(STARTUP_FRAMES)'],
];
for (const [name, rules, cases] of [
  ['route writer', routeStateRules, routeCases], ['legacy', legacyRules, legacyCases], ['guard', acceptanceRules, guardCases],
]) {
  test(name + ' preserves every PS1 rule ID and case-insensitive matching', () => {
    assert.deepEqual(rules.map((rule) => rule.id), cases.map(([id]) => id));
    for (const [id, source] of cases) {
      for (const line of [source, source.toUpperCase()]) {
        const matches = scanSourceLines('\n  ' + line, rules);
        assert.deepEqual(matches.map((match) => match.ruleId), [id]);
        assert.equal(matches[0].lineNumber, 2);
        assert.equal(matches[0].line, line);
        assert.ok(matches[0].reason.length > 15);
      }
    }
  });
}

test('self-test executes all four original cases and honestly propagates baseline failures', async (t) => {
  const { root } = await fixture(t);
  const reportPath = join(root, 'self-test.json');
  const child = invoke('test-npc-acceptance-guard', ['-ReportPath', reportPath]);
  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  assert.equal(report.resultCount, 4);
  assert.deepEqual(report.results.map((result) => result.name), [
    'guard_passes_real_tutorial_runner',
    'guard_passes_go_home_runner_with_documented_fixture_allowances',
    'guard_fails_fake_runner_and_reports_offending_line',
    'guard_fails_fixed_post_load_startup_delay',
  ]);
  const fixtures = [
    ['NpcRealTutorialPlaythroughRunner.gd', []],
    ['NpcGoHomeVisualPlaytestRunner.gd', [
      'safe_place_npc.*visual_go_home_spawn',
      'player\\.global_position\\s*=\\s*Vector3\\(float\\(center\\.x - 10\\)',
    ]],
  ];
  for (let index = 0; index < fixtures.length; index++) {
    const [file, allowedPatterns] = fixtures[index];
    const source = await readFile(join(projectRoot, 'scripts/testing/npc', file), 'utf8');
    const matches = scanSourceLines(source, acceptanceRules, { allowedPatterns });
    assert.equal(report.results[index].passed, matches.length === 0);
  }
  for (const [index, field, ruleId] of [
    [2, 'fakeRunner', 'direct_tutorial_door_progress'],
    [3, 'fixedPostLoadDelay', 'fixed_post_load_startup_delay'],
  ]) {
    assert.equal(report.results[index].passed, true);
    const failure = JSON.parse(await readFile(report.guardReports[field], 'utf8'));
    assert.equal(failure.forbiddenCallSelfScan.status, 'failed');
    assert.equal(failure.forbiddenCallSelfScan.matches[0].ruleId, ruleId);
  }
  const failures = report.results.filter((result) => !result.passed).length;
  assert.equal(report.failureCount, failures);
  assert.equal(report.passed, failures === 0);
  assert.equal(child.status, failures ? 1 : 0, child.stderr);
  assert.equal(report.testIntegrity.validationStatus, 'passed');
  assert.equal(report.evidenceLevel, 'static_audit');
  assert.deepEqual(report.acceptanceClaims, []);
});

test('line semantics preserve comments, definitions, false positives and match multiplicity', () => {
  assert.equal(scanSourceLines('# move_npc(x)', acceptanceRules).length, 1);
  assert.equal(scanSourceLines(' # plan_generated_cell_route(x)', legacyRules, { skipComments: true }).length, 0);
  for (const [, source] of legacyCases.slice(1, 6)) {
    assert.equal(scanSourceLines('func ' + source + ':', legacyRules).length, 0);
    assert.equal(scanSourceLines('static func ' + source + ':', legacyRules).length, 1);
  }
  assert.equal(scanSourceLines('var text = "plan_generated_cell_route(x)"', legacyRules).length, 1);
  assert.equal(scanSourceLines('entry["routeStatus"] == x', routeStateRules).length, 1);
  assert.equal(scanSourceLines('entry["routeStatus"] = x; entry["routeStatus"] = y', routeStateRules).length, 1);
  assert.equal(scanSourceLines('sleep_at_bed(x); request_crossing(x)', acceptanceRules).length, 2);
  for (const source of ['status = "partial"', '"status": "partial"']) assert.equal(scanSourceLines(source, legacyRules).length, 1);
  assert.equal(scanSourceLines('move_npc(x) # FIXTURE', acceptanceRules, { allowedPatterns: ['fixture'] }).length, 0);
  assert.equal(scanSourceLines('move_npc(x)', acceptanceRules, { allowedPatterns: ['fixture'] }).length, 1);
});

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'npc-source-audit-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const put = async (path, source) => {
    const target = join(root, path.replaceAll('\\', '/'));
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, source);
    return target;
  };
  return { root, put };
}
test('production scopes and exact writer allowlist, report fields and failure counts', async (t) => {
  const { root, put } = await fixture(t);
  const source = routeCases.map(([, line]) => line).join('\n');
  await put('scripts/ordinary.gd', source);
  for (const path of allowedFiles) await put(path, source);
  await put('scripts/TESTING/ignored.GD', source);
  await put('scenes/testing/ignored.gd', source);
  await put('addons/ignored.gd', source);
  await put('.godot/ignored.gd', source);
  await put('scripts/npc_ai/routing/NpcRouteStateStoreImposter.gd', source);
  const report = await auditProductionSources('route-state', root);
  assert.equal(report.ruleCount, 12);
  assert.equal(report.forbiddenRouteStateWriterScan.matches.length, 24);
  assert.equal(report.failureCount, 1);
  assert.equal(report.resultCount, 1);
  assert.equal(report.evidenceLevel, 'static_audit');
  assert.equal(report.passed, false);
  assert.equal(report.forbiddenRouteStateWriterScan.status, 'failed');
  assert.deepEqual(Object.keys(report.forbiddenRouteStateWriterScan.matches[0]), ['file', 'lineNumber', 'line', 'ruleId', 'reason']);
  await put('scripts/legacy.gd', legacyCases.map(([, line]) => line).join('\n'));
  const legacy = await auditProductionSources('legacy', root);
  assert.equal(legacy.ruleCount, 9);
  assert.equal(legacy.forbiddenLegacyPathfindingScan.matches.length, 9);
  assert.equal(legacy.failureCount, 1);
});
test('clean reports and navmesh fixed live-file scope, fixed strings, comments and detect mode', async (t) => {
  const { root, put } = await fixture(t);
  for (const path of liveRuntimeFiles) await put(path, 'extends Node\n');
  const report = await auditProductionSources('route-state', root);
  assert.equal(report.passed, true);
  assert.equal(report.failureCount, 0);
  assert.equal(report.results[0].details, 'route state writers are locked to approved authority files');
  await put('scripts/not-live.gd', 'LocalAStarPlannerScript');
  await put(liveRuntimeFiles[0], '# LocalAStarPlannerScript LocalAStarPlannerScript\nlocalastarplannerscript\nHierarchicalRoutePlannerScript\n');
  const detected = await auditNavmeshBackend(false, root);
  assert.equal(detected.mode, 'detect');
  assert.equal(detected.legacyPatternCount, 2);
  assert.equal(detected.failOnLegacy, false);
  assert.equal(detected.scannedFiles.length, 8);
  assert.match(detected.matches[0].hit, /:1:# LocalAStarPlannerScript/);
  assert.equal((await auditNavmeshBackend(true, root)).mode, 'fail_on_legacy');
});

const invoke = (name, args = [], cwd = projectRoot) => spawnSync(process.execPath, [
  join(projectRoot, 'tools/npc/' + name + '.mjs'), ...args,
], { encoding: 'utf8', cwd });
test('guard CLI enforces failures, original JSON envelope, allowances and success non-writing', async (t) => {
  const { root, put } = await fixture(t);
  await put('Runner.gd', 'MOVE_NPC(x) # SETUP\nawait wait_physics_frames(STARTUP_FRAMES)\n');
  const reportPath = join(root, 'report.json');
  const bad = invoke('assert-npc-acceptance-runner-clean', [
    '-RunnerPath', 'Runner.gd', '-ReportPath', reportPath, '-TestId', 'fixture_guard', '-PassThruJson',
  ], root);
  assert.equal(bad.status, 1, bad.stderr);
  const report = JSON.parse(bad.stdout);
  assert.deepEqual(report, JSON.parse(await readFile(reportPath, 'utf8')));
  assert.equal(report.testId, 'fixture_guard');
  assert.equal(report.failureCount, 1);
  assert.equal(report.forbiddenCallSelfScan.matches.length, 2);
  assert.equal(report.forbiddenCallSelfScan.ruleCount, 14);
  const good = invoke('assert-npc-acceptance-runner-clean', [
    '--runner-path', 'Runner.gd', '--report-path', reportPath, '--pass-thru-json',
    '--allowed-shortcut-pattern', 'setup;;', 'startup_frames',
  ], root);
  assert.equal(good.status, 0, good.stderr);
  const scan = JSON.parse(good.stdout);
  assert.equal(scan.status, 'passed');
  assert.deepEqual(scan.allowedShortcutPattern, ['setup', 'startup_frames']);
  assert.deepEqual(report, JSON.parse(await readFile(reportPath, 'utf8')), 'success preserves pre-existing report');
  const freshPath = join(root, 'fresh.json');
  await put('Clean.gd', 'extends Node');
  const clean = invoke('assert-npc-acceptance-runner-clean', [
    '-RunnerPath', 'Clean.gd', '-ReportPath', freshPath,
  ], root);
  assert.equal(clean.status, 0);
  assert.equal(clean.stdout, '');
  await assert.rejects(access(freshPath));
  assert.notEqual(invoke('assert-npc-acceptance-runner-clean', ['-RunnerPath', 'Clean.gd'], root).status, 0);
  assert.notEqual(invoke('assert-npc-acceptance-runner-clean', ['-RunnerPath', 'Missing.gd', '-ReportPath', freshPath], root).status, 0);
});
test('source CLI reports and navmesh fail switch agree with source scan, independent of cwd', async (t) => {
  const { root } = await fixture(t);
  for (const [kind, tool] of [
    ['route-state', 'assert-npc-route-state-writers'], ['legacy', 'assert-npc-legacy-pathfinding-clean'],
  ]) {
    const expected = await auditProductionSources(kind);
    const reportPath = join(root, kind + '.json');
    const result = invoke(tool, ['--report-path', reportPath], root);
    assert.equal(result.status, expected.passed ? 0 : 1, result.stderr);
    assert.deepEqual(JSON.parse(await readFile(reportPath, 'utf8')), expected);
    assert.equal(result.stdout, expected.passed ? '' : JSON.stringify(expected, null, 2) + '\n');
  }
  const detect = invoke('audit-npc-navmesh-backend', [], root);
  assert.equal(detect.status, 0, detect.stderr);
  assert.equal(JSON.parse(detect.stdout).mode, 'detect');
  for (const flag of ['-FailOnLegacy', '--fail-on-legacy']) {
    const result = invoke('audit-npc-navmesh-backend', [flag], root);
    const report = JSON.parse(result.stdout);
    assert.equal(result.status, report.legacyPatternCount ? 1 : 0);
    assert.equal(report.mode, 'fail_on_legacy');
  }
});

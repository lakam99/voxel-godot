import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

// Preserve the PowerShell audits' rule order, case-insensitive -match semantics,
// whole-line comment exclusions, and one finding per rule per source line.
export const routeStateRules = [
  {
    "id": "route_status_entry_write",
    "pattern": "\\[\\s*[\"']routeStatus[\"']\\s*\\]\\s*=",
    "reason": "routeStatus must be written through NpcRouteStateStore."
  },
  {
    "id": "route_reason_entry_write",
    "pattern": "\\[\\s*[\"']routeReason[\"']\\s*\\]\\s*=",
    "reason": "routeReason must be written through NpcRouteStateStore."
  },
  {
    "id": "route_lease_entry_write",
    "pattern": "\\[\\s*[\"']routeLease[\"']\\s*\\]\\s*=",
    "reason": "routeLease must be written through NpcRouteStateStore."
  },
  {
    "id": "route_lease_id_entry_write",
    "pattern": "\\[\\s*[\"']routeLeaseId[\"']\\s*\\]\\s*=",
    "reason": "routeLeaseId must be written through NpcRouteStateStore."
  },
  {
    "id": "route_lease_generation_entry_write",
    "pattern": "\\[\\s*[\"']routeLeaseGeneration[\"']\\s*\\]\\s*=",
    "reason": "routeLeaseGeneration must be written through NpcRouteStateStore."
  },
  {
    "id": "route_lease_entry_erase",
    "pattern": "\\.erase\\(\\s*[\"']routeLease[\"']\\s*\\)",
    "reason": "routeLease must be cleared through NpcRouteStateStore."
  },
  {
    "id": "route_lease_id_entry_erase",
    "pattern": "\\.erase\\(\\s*[\"']routeLeaseId[\"']\\s*\\)",
    "reason": "routeLeaseId must be cleared through NpcRouteStateStore."
  },
  {
    "id": "route_status_meta_write",
    "pattern": "set_meta\\s*\\(\\s*[\"']npc_route_status[\"']",
    "reason": "npc_route_status metadata must be published through NpcRouteStateStore."
  },
  {
    "id": "route_reason_meta_write",
    "pattern": "set_meta\\s*\\(\\s*[\"']npc_route_reason[\"']",
    "reason": "npc_route_reason metadata must be published through NpcRouteStateStore."
  },
  {
    "id": "route_authority_state_write",
    "pattern": "\\[\\s*[\"']routeAuthorityState[\"']\\s*\\]\\s*=",
    "reason": "routeAuthorityState must be written by the route authority/store only."
  },
  {
    "id": "route_authority_reason_write",
    "pattern": "\\[\\s*[\"']routeAuthorityReason[\"']\\s*\\]\\s*=",
    "reason": "routeAuthorityReason must be written by the route authority/store only."
  },
  {
    "id": "route_probe_certificate_write",
    "pattern": "\\[\\s*[\"']probeCertificate[\"']\\s*\\]\\s*=",
    "reason": "route probe proof must be written by the route authority/store only."
  }
];

export const legacyRules = [
  {
    "id": "generated_cell_fallback_flag_write",
    "pattern": "\\[\\s*[\"']safeOpenTerrainGeneratedFallback[\"']\\s*\\]\\s*=",
    "reason": "Production code must not enable generated-cell bridge fallback."
  },
  {
    "id": "generated_cell_public_route_call",
    "pattern": "\\bplan_generated_cell_route\\s*\\(",
    "reason": "Production routing must not call the generated-cell bridge route API.",
    "functionName": "plan_generated_cell_route"
  },
  {
    "id": "generated_cell_private_route_call",
    "pattern": "\\b_plan_generated_cell_bridge_route\\s*\\(",
    "reason": "Production routing must not call the generated-cell bridge implementation.",
    "functionName": "_plan_generated_cell_bridge_route"
  },
  {
    "id": "exact_home_lattice_route_call",
    "pattern": "\\b_plan_exact_home_collision_lattice_route\\s*\\(",
    "reason": "Production routing must not call exact-home collision lattice as a separate planner.",
    "functionName": "_plan_exact_home_collision_lattice_route"
  },
  {
    "id": "exact_home_lattice_selector_call",
    "pattern": "\\b_should_try_exact_home_collision_lattice_route\\s*\\(",
    "reason": "Production routing must not select exact-home collision lattice recovery.",
    "functionName": "_should_try_exact_home_collision_lattice_route"
  },
  {
    "id": "collision_lattice_repair_call",
    "pattern": "\\b_plan_collision_lattice_repair_route\\s*\\(",
    "reason": "Production routing must not repair routes through collision lattice/generated-cell fallback.",
    "functionName": "_plan_collision_lattice_repair_route"
  },
  {
    "id": "fallback_only_generated_bridge_flag",
    "pattern": "\\[\\s*[\"']generatedBridgeFallbackOnly[\"']\\s*\\]\\s*=",
    "reason": "Production code must not enable generated bridge fallback-only routing."
  },
  {
    "id": "home_cell_bridge_repair_flag",
    "pattern": "\\[\\s*[\"']allowHomeCellBridgeRepair[\"']\\s*\\]\\s*=",
    "reason": "Production code must not enable home cell-bridge repair."
  },
  {
    "id": "runtime_partial_endpoint_status",
    "pattern": "status\\s*:?\\=\\s*[\"']partial[\"']|[\"']status[\"']\\s*:\\s*[\"']partial[\"']",
    "reason": "Production runtime routing must not claim partial endpoint success."
  }
];

export const acceptanceRules = [
  {
    "id": "direct_tutorial_door_progress",
    "pattern": "\\bon_door_opened\\b",
    "reason": "Acceptance tests must open doors through real input/interaction paths, not tutorial progression callbacks."
  },
  {
    "id": "direct_tutorial_interaction",
    "pattern": "\\binteract_with\\b",
    "reason": "Acceptance tests must interact through player proximity, prompts, raycasts, and HUD flow."
  },
  {
    "id": "direct_tutorial_completion",
    "pattern": "\\bcomplete_step\\b",
    "reason": "Acceptance tests must observe objective completion through gameplay."
  },
  {
    "id": "direct_block_progress",
    "pattern": "\\bon_block_placed\\b",
    "reason": "Acceptance tests must place blocks through the placement system when placement is part of the claim."
  },
  {
    "id": "direct_sleep_or_bed_progress",
    "pattern": "\\b(on_bed_used|sleep_at_bed)\\b",
    "reason": "Acceptance tests must use beds through real player interaction when sleep is part of the claim."
  },
  {
    "id": "inventory_grant",
    "pattern": "\\binventory_system\\.add_item\\s*\\(",
    "reason": "Acceptance tests must not grant progression resources during the act phase."
  },
  {
    "id": "direct_npc_movement_helper",
    "pattern": "\\bmove_npc\\b",
    "reason": "Acceptance tests must let behavior, routing, and the CharacterBody motor drive NPC movement."
  },
  {
    "id": "direct_door_service",
    "pattern": "\\b(request_door_state|request_crossing)\\b",
    "reason": "Acceptance tests must not directly drive door services when proving live door traversal."
  },
  {
    "id": "fake_inside_home_metadata",
    "pattern": "set_meta\\s*\\(\\s*[\"']npc_inside_home[\"']",
    "reason": "Acceptance tests must not mark home arrival through metadata."
  },
  {
    "id": "fake_scripted_arrival_metadata",
    "pattern": "set_meta\\s*\\(\\s*[\"']npc_scripted_arrived[\"']",
    "reason": "Acceptance tests must not mark scripted arrival through metadata."
  },
  {
    "id": "actor_transform_write",
    "pattern": "\\b(player|body|npc_body|actor|mira_body|rowan_body|niko_body|sera_body)\\.global_position\\s*=",
    "reason": "Acceptance tests must not teleport actors during the behavior being proven."
  },
  {
    "id": "safe_place_npc",
    "pattern": "\\bsafe_place_npc\\b",
    "reason": "Acceptance tests may only use safe placement as narrowly documented fixture setup."
  },
  {
    "id": "source_scan_acceptance",
    "pattern": "\\bread_text\\s*\\(",
    "reason": "Acceptance tests must not pass by scanning source text instead of exercising behavior."
  },
  {
    "id": "fixed_post_load_startup_delay",
    "pattern": "\\bawait\\s+wait_physics_frames\\s*\\(\\s*STARTUP_FRAMES\\s*\\)",
    "reason": "Live acceptance must begin from live readiness gates, not a fixed post-load physics-frame delay."
  }
];

export const liveRuntimeFiles = [
  'scripts\\NpcPathing.gd',
  'scripts\\npc_ai\\NpcAutonomySystem.gd',
  'scripts\\npc_ai\\routing\\NpcNavigationCoordinator.gd',
  'scripts\\npc_ai\\routing\\NpcRouteCoordinatorAdapter.gd',
  'scripts\\npc_ai\\movement\\NpcRouteMovementController.gd',
  'scripts\\npc_ai\\behavior\\NpcSemanticGoalPlanner.gd',
  'scripts\\npc_ai\\behavior\\NpcTaskPlanner.gd',
  'scripts\\npc_ai\\behavior\\NpcPlanExecutor.gd',
];
export const navmeshPatterns = [
  { name: 'LocalAStarPlanner', pattern: 'LocalAStarPlannerScript' },
  { name: 'HierarchicalRoutePlanner', pattern: 'HierarchicalRoutePlannerScript' },
];
export const allowedFiles = [
  'scripts\\npc_ai\\routing\\NpcRouteStateStore.gd',
  'scripts\\npc_ai\\routing\\NpcRouteAuthority.gd',
  'scripts\\npc_ai\\routing\\NpcRouteAuthorityV2.gd',
];
const ignoredScopes = ['scripts/testing', 'scenes/testing', 'addons', '.godot'];
const portablePath = (value) => String(value).replaceAll('\\', '/');
const linesOf = (source) => source.replace(/^\uFEFF/, '').split(/\r\n|\n|\r/);
const json = (value) => JSON.stringify(value, null, 2) + '\n';
const regex = (pattern) => new RegExp(pattern, 'i');

export function parseAuditArguments(args) {
  const options = {};
  for (let i = 0; i < args.length; i++) {
    const match = /^--?([^=:]+)(?:[=:](.*))?$/.exec(args[i]);
    if (!match) throw new Error('Unexpected audit argument: ' + args[i]);
    const key = match[1].replaceAll('-', '').toLowerCase();
    if (!['reportpath', 'runnerpath', 'testid', 'allowedshortcutpattern', 'passthrujson', 'failonlegacy'].includes(key)) {
      throw new Error('Unknown audit option: ' + args[i]);
    }
    let value = match[2];
    if (value === undefined && args[i + 1] !== undefined && !args[i + 1].startsWith('-')) value = args[++i];
    if (value === undefined) {
      if (!['passthrujson', 'failonlegacy'].includes(key)) throw new Error('Missing value for ' + args[i]);
      value = true;
    }
    if (key === 'allowedshortcutpattern') {
      options[key] ??= [];
      options[key].push(value);
      while (args[i + 1] !== undefined && !args[i + 1].startsWith('-')) options[key].push(args[++i]);
    } else options[key] = value;
  }
  return options;
}
const enabled = (value) => value === true || /^(?:\$?true|1|yes|on)$/i.test(String(value));
async function writeReport(path, report) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, json(report));
}
async function gdFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await gdFiles(path));
    else if (entry.isFile() && /\.gd$/i.test(entry.name)) files.push(path);
  }
  return files.sort();
}

export function scanSourceLines(source, rules, { skipComments = false, allowedPatterns = [] } = {}) {
  const compiled = rules.map((rule) => ({
    ...rule,
    expression: regex(rule.pattern),
    definition: rule.functionName ? regex('^\\s*func\\s+' + rule.functionName + '\\s*\\(') : null,
  }));
  const allowed = allowedPatterns.map(regex);
  const matches = [];
  linesOf(source).forEach((line, index) => {
    if (skipComments && line.trimStart().startsWith('#')) return;
    for (const rule of compiled) {
      if (!rule.expression.test(line)) continue;
      if (rule.definition?.test(line) || allowed.some((pattern) => pattern.test(line))) continue;
      matches.push({ lineNumber: index + 1, line: line.trim(), ruleId: rule.id, reason: rule.reason });
    }
  });
  return matches;
}

export async function auditProductionSources(kind, root = projectRoot) {
  const route = kind === 'route-state';
  if (!route && kind !== 'legacy') throw new Error('Unknown production audit: ' + kind);
  const rules = route ? routeStateRules : legacyRules;
  const violations = [];
  for (const file of await gdFiles(join(root, 'scripts'))) {
    const relativePath = relative(root, file).replaceAll('/', '\\');
    const normalized = portablePath(relativePath).toLowerCase();
    if (ignoredScopes.some((scope) => normalized.startsWith(scope.toLowerCase() + '/'))) continue;
    if (route && allowedFiles.some((allowed) => allowed.toLowerCase() === relativePath.toLowerCase())) continue;
    for (const match of scanSourceLines(await readFile(file, 'utf8'), rules, { skipComments: true })) {
      violations.push({ file: relativePath, ...match });
    }
  }
  const passed = violations.length === 0;
  const testId = route ? 'npc_route_state_writer_static_audit' : 'npc_legacy_pathfinding_static_audit';
  return {
    schemaVersion: 1, testId, evidenceLevel: 'static_audit', finished: true,
    passed, failureCount: passed ? 0 : 1, resultCount: 1,
    ...(route ? { allowedFiles } : {}), ignoredScopes, ruleCount: rules.length,
    [route ? 'forbiddenRouteStateWriterScan' : 'forbiddenLegacyPathfindingScan']: {
      status: passed ? 'passed' : 'failed', matches: violations,
    },
    results: [{
      name: testId, passed,
      details: route
        ? (passed ? 'route state writers are locked to approved authority files' : 'found ' + violations.length + ' unauthorized route-state writes')
        : (passed ? 'no active production generated-cell, exact-lattice, or partial-endpoint fallback source found' : 'found ' + violations.length + ' active legacy pathfinding source matches'),
    }],
  };
}

export async function auditNavmeshBackend(failOnLegacy = false, root = projectRoot) {
  const matches = [];
  // Unlike -match audits, rg --fixed-strings is case-sensitive and scans comments.
  for (const item of navmeshPatterns) {
    for (const relativePath of liveRuntimeFiles) {
      const path = resolve(root, portablePath(relativePath));
      let source;
      try { source = await readFile(path, 'utf8'); }
      catch (error) {
        // The old rg invocation suppressed missing-path diagnostics.
        if (error.code === 'ENOENT') continue;
        throw error;
      }
      linesOf(source).forEach((line, index) => {
        if (line.includes(item.pattern)) matches.push({ ...item, hit: path + ':' + (index + 1) + ':' + line });
      });
    }
  }
  return {
    schemaVersion: 1, mode: failOnLegacy ? 'fail_on_legacy' : 'detect',
    legacyPatternCount: matches.length, failOnLegacy, scannedFiles: liveRuntimeFiles, matches,
  };
}

export async function runSourceAudit(toolId, rawArgs = process.argv.slice(2)) {
  if(rawArgs.some(arg=>/^(--?help|-h)$/i.test(arg))) { console.log(`Usage: node tools/${toolId}.mjs [--report-path PATH] [--fail-on-legacy]`);return; }
  const options = parseAuditArguments(rawArgs);
  if (toolId === 'npc/audit-npc-navmesh-backend') {
    const report = await auditNavmeshBackend(enabled(options.failonlegacy));
    process.stdout.write(json(report));
    if (report.failOnLegacy && report.legacyPatternCount) process.exitCode = 1;
    return report;
  }
  const kind = toolId === 'npc/assert-npc-route-state-writers' ? 'route-state'
    : toolId === 'npc/assert-npc-legacy-pathfinding-clean' ? 'legacy' : null;
  const report = await auditProductionSources(kind);
  const defaultPath = kind === 'route-state'
    ? 'artifacts/npc/reports/npc-route-state-writer-audit.json'
    : 'artifacts/npc/reports/npc-legacy-pathfinding-audit.json';
  await writeReport(resolve(projectRoot, portablePath(options.reportpath ?? defaultPath)), report);
  if (enabled(options.passthrujson)) process.stdout.write(json(report));
  if (!report.passed) {
    process.stdout.write(json(report));
    process.exitCode = 1;
  }
  return report;
}

// Returns the scan on both success and failure. As in PS1, success does not
// create or overwrite ReportPath; callers should consume this returned scan.
export async function runAcceptanceRunnerAudit(rawArgs = process.argv.slice(2)) {
  if(rawArgs.some(arg=>/^(--?help|-h)$/i.test(arg))) { console.log('Usage: node tools/npc/assert-npc-acceptance-runner-clean.mjs --runner-path PATH --report-path PATH [--allowed-shortcut-pattern REGEX]');return; }
  const options = parseAuditArguments(rawArgs);
  if (!options.runnerpath || !options.reportpath) throw new Error('RunnerPath and ReportPath are required.');
  const runnerPath = resolve(portablePath(options.runnerpath));
  const reportPath = resolve(portablePath(options.reportpath));
  const testId = String(options.testid ?? 'npc_acceptance_runner_static_guard');
  const allowedShortcutPattern = (options.allowedshortcutpattern ?? []).flatMap((value) => String(value).split(';')).filter((value) => value !== '');
  let source;
  try { source = await readFile(runnerPath, 'utf8'); }
  catch (error) {
    if (error.code === 'ENOENT') throw new Error('Acceptance runner source does not exist: ' + runnerPath);
    throw error;
  }
  const matches = scanSourceLines(source, acceptanceRules, { allowedPatterns: allowedShortcutPattern });
  const scan = {
    status: matches.length ? 'failed' : 'passed', runnerPath, testId,
    ruleCount: acceptanceRules.length, allowedShortcutPattern, matches,
  };
  if (matches.length) {
    const report = {
      schemaVersion: 1, testId, finished: true, passed: false, failureCount: 1, resultCount: 1,
      forbiddenCallSelfScan: scan,
      results: [{ name: 'npc_acceptance_runner_static_guard', passed: false, details: 'acceptance runner source contains forbidden shortcut calls' }],
    };
    await writeReport(reportPath, report);
    process.stdout.write(json(report));
    process.exitCode = 1;
  } else if (enabled(options.passthrujson)) process.stdout.write(json(scan));
  return scan;
}

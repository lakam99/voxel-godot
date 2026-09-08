import * as fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { undergroundAuditChecks } from './legacy-underground-audit-checks.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
export const treeMatrixCases = [
  ['broadleaf-mature', 'forest', 'broadleaf', 'mature'], ['broadleaf-old', 'forest', 'broadleaf', 'old'],
  ['conifer-mature', 'taiga', 'conifer', 'mature'], ['conifer-old', 'taiga', 'conifer', 'old'],
  ['savanna-mature', 'savanna', 'savanna', 'mature'], ['savanna-old', 'savanna', 'savanna', 'old'],
];
export const canopyCaptures = ['menu_before_save_and_harvest.png', 'generated_tree_trunk_player_pov.png',
  'generated_tree_before_harvest.png', 'tree_falling_after_live_input.png', 'forest_after_chunk_reload.png',
  'menu_before_continue_verify.png', 'continue_dense_forest_removed_tree_persisted.png'];

function argumentsFor(args, allowed) {
  const result = {};
  for (let i = 0; i < args.length; i++) {
    const match = /^--?([^=:]+)(?:[=:](.*))?$/.exec(args[i]);
    const key = match?.[1].replaceAll('-', '').toLowerCase();
    if (!allowed.includes(key)) throw new Error(`Unknown workflow option: ${args[i]}`);
    if (Object.hasOwn(result, key)) throw new Error(`Duplicate workflow option: ${args[i]}`);
    const value = match[2] ?? args[++i];
    if (value === undefined || (/^--?[A-Za-z]/.test(value))) throw new Error(`Missing value for ${key}`);
    result[key] = value;
  }
  return result;
}
function integer(value, fallback, name, minimum = -2147483648) {
  if (value === undefined) return fallback;
  if (!/^-?\d+$/.test(String(value)) || !Number.isSafeInteger(Number(value)) || Number(value) < minimum || Number(value) > 2147483647)
    throw new Error(`Invalid integer ${name}`);
  return Number(value);
}
function boolean(value, fallback) {
  if (value === undefined) return fallback;
  if (/^(true|\$true|1)$/i.test(value)) return true;
  if (/^(false|\$false|0)$/i.test(value)) return false;
  throw new Error('GodMode must be true or false.');
}
function environment(parent, values, remove = []) {
  const excluded = new Set([...Object.keys(values), ...remove].map(k => k.toUpperCase()));
  return { ...Object.fromEntries(Object.entries(parent).filter(([k]) => !excluded.has(k.toUpperCase()))), ...values };
}
const help = args => args.some(arg => /^(--help|-Help|-h)$/i.test(arg));

// Pure rule evaluator: preserves PowerShell -match's case-insensitivity and
// evaluates EVERY required alternative separately, not one aggregate OR match.
export function evaluateUndergroundAudit(sources, checks = undergroundAuditChecks) {
  const findings = [];
  for (const check of checks) for (const file of check.files) {
    const finding = (type, extra = {}) => findings.push({ id: check.id, file, type, ...extra, requirement: check.requirement });
    if (!sources.has(file)) { finding('missing_file'); continue; }
    let source = sources.get(file);
    if (check.entrypointPattern && !new RegExp(check.entrypointPattern, 'i').test(source))
      finding('missing_required_pattern', { pattern: check.entrypointPattern });
    for (const dependency of check.composedSources ?? []) {
      if (!sources.has(dependency)) findings.push({ id: check.id, file: dependency, type: 'missing_file', requirement: check.requirement });
      else source += '\n' + sources.get(dependency);
    }
    if (check.forbiddenPattern && new RegExp(check.forbiddenPattern, 'i').test(source))
      finding('forbidden_pattern', { pattern: check.forbiddenPattern });
    for (const pattern of check.requiredPattern?.split('|') ?? [])
      if (!new RegExp(pattern, 'i').test(source)) finding('missing_required_pattern', { pattern });
  }
  return { schemaVersion: 1, runnerId: 'underground_volume_static_audit', evidenceLevel: 'static_audit',
    status: findings.length ? 'failed' : 'passed', findingCount: findings.length, findings };
}

// Test injection replaces only process execution/time/output. Production wrappers
// always use the default owned-process implementations; no test CLI is exposed.
export function createLegacyWorkflowPorts(dependencies = {}) {
  const projectRoot = path.resolve(dependencies.projectRoot ?? root);
  const parentEnv = dependencies.env ?? process.env;
  const emit = dependencies.emit ?? (value => process.stdout.write(`${typeof value === 'string' ? value : JSON.stringify(value, null, 2)}\n`));
  const uuid = dependencies.uuid ?? randomUUID;
  const findGodot = dependencies.findGodot ?? (async explicit => (await import('./voxel-tool-runtime.mjs')).findGodot(explicit));
  const runGodot = dependencies.runGodot ?? (async (...args) => (await import('./godot-process.mjs')).runGodotProcess(...args));
  const runOwned = dependencies.runOwned ?? (async options => (await import('./owned-process.mjs')).runOwnedProcess(options));
  const sleep = dependencies.sleep ?? (ms => new Promise(resolve => setTimeout(resolve, ms)));
  const now = dependencies.now ?? Date.now;
  const resolve = (candidate, fallback) => path.resolve(projectRoot, candidate || fallback);
  const exists = async file => fs.stat(file).then(s => s.isFile(), e => { if (e.code === 'ENOENT') return false; throw e; });
  const read = async file => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
  const write = async (file, value) => { await fs.mkdir(path.dirname(file), { recursive: true }); await fs.writeFile(file, JSON.stringify(value, null, 2) + '\n'); };

  async function canopy(options) {
    const artifactDir = resolve(options.artifactdir, 'artifacts/vegetation/vox123-canopy-release');
    const watchdog = integer(options.watchdogseconds, 420, 'WatchdogSeconds', 1);
    const selection = [options.targetbiome ?? '', options.targetarchitecture ?? '', options.requiredageband ?? ''];
    const choices = [['', 'forest', 'taiga', 'savanna'], ['', 'broadleaf', 'conifer', 'savanna'], ['', 'mature', 'old', 'ancient']];
    if (selection.some((v, i) => !choices[i].includes(v))) throw new Error('Invalid canopy biome, architecture, or age band.');
    if (selection.some(Boolean) && !selection.every(Boolean)) throw new Error('TargetBiome, TargetArchitecture, and RequiredAgeBand must be provided together.');
    const godot = await findGodot(options.godotexe);
    const savePath = path.join(artifactDir, 'canopy-release-save.json');
    const activeSeedPath = path.join(artifactDir, 'canopy-release-save_active_seed.txt');
    const saveReport = path.join(artifactDir, 'save-and-harvest.json');
    const continueReport = path.join(artifactDir, 'continue-verify.json');
    const saveProgress = path.join(artifactDir, 'save-and-harvest-progress.txt');
    const continueProgress = path.join(artifactDir, 'continue-verify-progress.txt');
    const screenshotDir = path.join(artifactDir, 'screenshots');
    await fs.mkdir(screenshotDir, { recursive: true });
    for (const file of [savePath, activeSeedPath, saveReport, continueReport, saveProgress, continueProgress]) await fs.rm(file, { force: true });
    for (const [directory, predicate] of [[artifactDir, name => name.startsWith('canopy-release-save_slot_')], [screenshotDir, name => /\.png$/i.test(name)]]) {
      for (const entry of await fs.readdir(directory, { withFileTypes: true }))
        if (entry.isFile() && predicate(entry.name)) await fs.rm(path.join(directory, entry.name));
    }
    const env = environment(parentEnv, {
      VOXEL_SAVE_PATH_OVERRIDE: savePath, VOXEL_CANOPY_RELEASE_SCREENSHOT_DIR: screenshotDir,
      VOXEL_CANOPY_RELEASE_WATCHDOG_SECONDS: String(watchdog),
      ...(selection.every(Boolean) ? { VOXEL_CANOPY_RELEASE_TARGET_BIOME: selection[0],
        VOXEL_CANOPY_RELEASE_TARGET_ARCHITECTURE: selection[1], VOXEL_CANOPY_RELEASE_REQUIRED_AGE_BAND: selection[2] } : {}),
    }, ['VOXEL_PLAYTEST', 'VOXEL_TEST_SEED', 'VOXEL_CANOPY_RELEASE_TARGET_BIOME',
      'VOXEL_CANOPY_RELEASE_TARGET_ARCHITECTURE', 'VOXEL_CANOPY_RELEASE_REQUIRED_AGE_BAND']);
    async function stage(name, reportPath, progressPath, propId = '') {
      const token = uuid().replaceAll('-', '');
      const stageEnv = environment(env, { VOXEL_CANOPY_RELEASE_STAGE: name, VOXEL_CANOPY_RELEASE_REPORT: reportPath,
        VOXEL_CANOPY_RELEASE_PROGRESS: progressPath, VOXEL_CANOPY_RELEASE_RUN_TOKEN: token,
        ...(propId ? { VOXEL_CANOPY_EXPECTED_REMOVED_PROP_ID: propId } : {}),
      }, ['VOXEL_CANOPY_EXPECTED_REMOVED_PROP_ID']);
      const result = await runGodot(godot, ['--path', projectRoot, '--resolution', '1280x720', '--scene', 'res://scenes/testing/CanopyReleasePlaytest.tscn'],
        { cwd: projectRoot, env: stageEnv, timeoutSeconds: watchdog, reportPath, expectedRunToken: token, progressPath });
      if (!(await exists(reportPath))) throw new Error(`Missing canopy release stage report: ${reportPath}`);
      const report = await read(reportPath);
      if (report.runnerId !== 'canopy_release_playtest' || report.evidenceLevel !== 'acceptance_visual') throw new Error('Canopy release report identity mismatch');
      if (result.code !== 0 || report.passed !== true || report.runToken !== token) throw new Error(`Canopy release stage failed or stale: ${name}`);
      return report;
    }
    const save = await stage('save_and_harvest', saveReport, saveProgress);
    const removedPropId = typeof save.harvest?.propId === 'string' ? save.harvest.propId : '';
    if (!removedPropId || !(await exists(activeSeedPath))) throw new Error('Save/harvest stage did not persist its isolated save or removed prop ID');
    const continued = await stage('continue_verify', continueReport, continueProgress, removedPropId);
    const missing = [];
    for (const name of canopyCaptures) if (!(await exists(path.join(screenshotDir, name)))) missing.push(name);
    if (missing.length) throw new Error(`Missing canopy release captures: ${missing.join(', ')}`);
    return { runnerId: 'canopy_release_playtest', passed: true, seed: save.seed,
      targetBiome: selection[0], targetArchitecture: selection[1], requiredAgeBand: selection[2], removedPropId,
      saveResultCount: save.resultCount, continueResultCount: continued.resultCount, saveReport, continueReport, screenshotDir };
  }

  async function matrix(options) {
    const artifactDir = resolve(options.artifactdir, 'artifacts/vegetation/procedural-tree-interaction-matrix');
    const reportPath = path.join(artifactDir, 'interaction-matrix.json');
    await fs.mkdir(artifactDir, { recursive: true });
    await fs.rm(reportPath, { force: true }); // A failed rerun must not leave old green evidence.
    const results = [];
    for (const [key, biome, architecture, ageBand] of treeMatrixCases) {
      const caseDir = path.join(artifactDir, key);
      const result = await canopy({ ...options, artifactdir: caseDir, targetbiome: biome, targetarchitecture: architecture, requiredageband: ageBand });
      const save = await read(result.saveReport), continued = await read(result.continueReport);
      if (save.passed !== true || continued.passed !== true) throw new Error(`Family/age interaction reports failed: ${key}`);
      results.push({ case: key, biome, architecture, ageBand, seed: save.seed, propId: save.harvest?.propId,
        recipeSignature: save.treeBefore?.recipeSignature ?? null, branchCount: save.treeBefore?.branchCount ?? null,
        foliageClusterCount: save.treeBefore?.foliageClusterCount ?? null, breakTotalMs: save.harvest?.destroyMetrics?.totalMs ?? null,
        saveReport: result.saveReport, continueReport: result.continueReport, screenshotDir: result.screenshotDir });
    }
    const report = { runnerId: 'procedural_tree_family_age_interaction_matrix', evidenceLevel: 'headed_gameplay_acceptance', passed: true,
      caseCount: results.length, cases: results,
      scope: 'Six independent headed production Main Menu runs. Each proves a naturally generated, selected biome/family/age tree is published procedurally, targeted, broken through viewport input, falls/drops, remains removed through chunk reload, and remains removed after save/Continue.',
      limitations: 'The matrix proves interaction/removal persistence for each requested family and age. Recipe determinism, old-save additive loading, wind, streaming budgets, and NPC safety remain covered by their dedicated non-matrix runners.' };
    await write(reportPath, report);
    return report;
  }

  async function audit(options) {
    const sources = new Map();
    for (const file of new Set(undergroundAuditChecks.flatMap(c => [...c.files, ...(c.composedSources ?? [])]))) {
      try { sources.set(file, await fs.readFile(path.join(projectRoot, file), 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    const report = evaluateUndergroundAudit(sources);
    await write(resolve(options.reportpath, 'artifacts/underground-volume-audit.json'), report);
    emit(report);
    if (report.findingCount) throw new Error(`Underground volume static audit failed: ${report.findingCount} findings.`);
    return report;
  }

  async function runLegacyWorkflow(toolId, args = []) {
    const ids = ['run-procedural-tree-interaction-matrix', 'run-underground-volume-audit', 'run-canopy-release-playtest'];
    if (!ids.includes(toolId)) throw new Error(`Unknown legacy workflow: ${toolId}`);
    if (help(args)) { emit(`Usage: node tools/${toolId}.mjs ${toolId === 'run-underground-volume-audit' ? '[-ReportPath PATH]' : '[-GodotExe PATH] [-ArtifactDir PATH] [-WatchdogSeconds 420]'}${toolId === 'run-canopy-release-playtest' ? ' [-TargetBiome forest|taiga|savanna -TargetArchitecture broadleaf|conifer|savanna -RequiredAgeBand mature|old|ancient]' : ''}`); return; }
    const options = argumentsFor(args, toolId === 'run-underground-volume-audit' ? ['reportpath'] : ['godotexe', 'artifactdir', 'watchdogseconds', ...(toolId === 'run-canopy-release-playtest' ? ['targetbiome', 'targetarchitecture', 'requiredageband'] : [])]);
    if (toolId === 'run-underground-volume-audit') return audit(options);
    const report = await (toolId === 'run-canopy-release-playtest' ? canopy(options) : matrix(options));
    emit(report); return report;
  }

  async function runUndergroundInteractive(args = []) {
    if (help(args)) { emit('Usage: node tools/run-underground-interactive-playtest.mjs [-GodotExe PATH] [-Seed TEXT] [-SearchRadius 32] [-MinDepthCells 4] [-MaxDepthCells 30] [-GodMode true|false] [-LaunchInfoPath PATH]'); return; }
    const options = argumentsFor(args, ['godotexe', 'seed', 'searchradius', 'mindepthcells', 'maxdepthcells', 'godmode', 'launchinfopath']);
    const seed = options.seed || `interactive-underground-${uuid().replaceAll('-', '').slice(0, 8)}`;
    const searchRadius = integer(options.searchradius, 32, 'SearchRadius');
    const minDepthCells = integer(options.mindepthcells, 4, 'MinDepthCells');
    const maxDepthCells = integer(options.maxdepthcells, 30, 'MaxDepthCells');
    const godMode = boolean(options.godmode, true);
    const launchInfoPath = resolve(options.launchinfopath, 'artifacts/underground/interactive-underground-launch.json');
    const godot = await findGodot(options.godotexe);
    await fs.mkdir(path.dirname(launchInfoPath), { recursive: true });
    await fs.rm(launchInfoPath, { force: true });
    const processRoot = resolve(null, 'artifacts/node-tools/process-runs');
    await fs.mkdir(processRoot, { recursive: true });
    const runDir = await fs.mkdtemp(path.join(processRoot, 'underground-interactive-'));
    const liveOwnershipPath = path.join(runDir, 'live-ownership.json'), stopRequestPath = path.join(runDir, 'stop-request.txt');
    const env = environment(parentEnv, { VOXEL_PLAYTEST: '1', VOXEL_TEST_SEED: seed, VOXEL_UNDERGROUND_INTERACTIVE: '1',
      VOXEL_UNDERGROUND_INTERACTIVE_SEARCH_RADIUS: String(Math.max(1, searchRadius)),
      VOXEL_UNDERGROUND_INTERACTIVE_MIN_DEPTH: String(Math.max(1, minDepthCells)),
      VOXEL_UNDERGROUND_INTERACTIVE_MAX_DEPTH: String(Math.max(minDepthCells, maxDepthCells)),
      VOXEL_UNDERGROUND_INTERACTIVE_GOD_MODE: godMode ? '1' : '0', VOXEL_UNDERGROUND_INTERACTIVE_LAUNCH_INFO: launchInfoPath });
    const controller = new AbortController();
    let settled = false, summary, processError, receipt;
    const running = runOwned({ projectPath: projectRoot, executable: godot,
      args: ['--resolution', '1280x720', '--path', projectRoot, '--scene', 'res://scenes/Main.tscn'], env,
      timeoutSeconds: 0, signal: controller.signal, liveOwnershipPath, stopRequestPath, stdoutPath: path.join(runDir, 'stdout.log'),
      stderrPath: path.join(runDir, 'stderr.log'), summaryPath: path.join(runDir, 'watchdog.json') })
      .then(value => { summary = value; }, error => { processError = error; }).finally(() => { settled = true; });
    const deadline = now() + 60000;
    try {
      do {
        const hasInfo = await exists(launchInfoPath);
        if (!receipt && (hasInfo || now() >= deadline)) {
          const live = await exists(liveOwnershipPath) ? await read(liveOwnershipPath) : null;
          const processId = live?.rootPid ?? summary?.rootPid;
          if (processId) {
            receipt = { processId, seed, searchRadius, minDepthCells, maxDepthCells, godMode, launchInfoPath,
              launchInfo: hasInfo ? await read(launchInfoPath) : null };
            emit(receipt); // Initial receipt does not claim terminal cleanup or acceptance.
          }
        }
        if (settled) break;
        await sleep(250);
      } while (true);
      await running;
      if (processError) throw processError;
      if (!receipt) throw new Error(`Godot exited before writing underground launch info. Exit code: ${summary?.functionalExitCode}`);
      if (summary.overallExitCode !== 0 || !summary.cleanupPassed || !summary.authoritativeZeroProven)
        throw new Error(`Interactive Godot or owned-process cleanup failed: ${path.join(runDir, 'watchdog.json')}`);
      return receipt;
    } catch (error) {
      const observerError = error instanceof Error ? error : new Error(String(error));
      // Cancellation is independent of disk access and scoped to this owned run.
      // Always signal first: an unwritable stop file must not strand the owner.
      controller.abort(observerError);
      try {
        if (!settled) await fs.writeFile(stopRequestPath, `Interactive launch observer failed: ${observerError.message}`);
      } catch (stopError) {
        observerError.stopRequestWriteError = stopError;
      } finally {
        await running; // Never reject to the caller before owned cleanup settles.
      }
      if (processError && processError !== observerError) observerError.ownedProcessError = processError;
      throw observerError;
    }
  }
  return { runLegacyWorkflow, runUndergroundInteractive };
}

const production = createLegacyWorkflowPorts();
export const runLegacyWorkflow = (toolId, args = process.argv.slice(2)) => production.runLegacyWorkflow(toolId, args);
export const runUndergroundInteractive = (args = process.argv.slice(2)) => production.runUndergroundInteractive(args);

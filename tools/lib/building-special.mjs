import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { sourceFiles } from './building-special-sources.mjs';
import { structuralRunnerSources, validatePhaseASourceBindings } from './building-source-bindings.mjs';
import { options, choice, integer, context, prepare, launchRecord, stable, phaseRun, read, sha, uid, git, demand, assertReport, assertWatchdog, assertNoGodot, engineErrors, inside, resolveExecutablePair } from './building-runner.mjs';

export const defaultStages = { entry: 'physical_validation_started', resolve: 'physical_resolve_schema', grid: 'physical_grid_cells', support_resolution: 'physical_resolve_support', validation: 'physical_validation_part', frame: 'physical_frame_part', final: 'physical_validation_completed' };
const common = { outputdirectory: '', godotexe: '', projectpath: '' };
const defaults = {
  'building-contract': { contract: '', reportenvironment: '', timeoutseconds: 30 },
  'building-validation-cancellation-contract': { stagemap: JSON.stringify(defaultStages), timeoutseconds: 60 },
  'citadel-completion-cancellation-contract': { phase: '', archive: 'artifacts/citadel-visual-reset/opening-head-batch-06/candidate.bin', laterstage: 'bracket_first_started', timeoutseconds: 60 },
  'citadel-main-menu-diagnostic': {},
  'citadel-recipe-preparation-contract': { phase: '', referencedirectory: '' },
  'citadel-sign-completion-contract': { phase: '', finalsnapshot: 'artifacts/citadel-runtime-integration/final-structural-source-01/result.bin', referencesnapshot: 'artifacts/citadel-runtime-integration/source-reference-01/reference.bin' },
  'citadel-sign-socket-bounds-contract': {},
  'citadel-structural-composer-two-phase-contract': { mode: '', phaseadirectory: '', seed: 208159 },
  'citadel-visual-preservation': { mode: 'Contract', variant: 'urban', seed: 208159 },
  'household-sign-placement-contract': { inputsnapshot: 'artifacts/sign-socket-investigation/raw-01/fixture.bin', referencesnapshot: 'artifacts/citadel-runtime-integration/source-reference-01/reference.bin' },
  'npc-biped-poc': { seed: 209154, artifactdir: 'artifacts/npcs/npc-biped-poc', timeoutseconds: 600 },
  'npc-biped-recipe-contract': { artifactdir: 'artifacts/npcs/npc-biped-recipe-contract', timeoutseconds: 120 },
};
export async function runSpecial(name, argv, runOwnedProcess) {
  const switches = name === 'building-contract' ? ['outputisdirectory'] : name === 'npc-biped-poc' ? ['capture'] : ['building-validation-cancellation-contract', 'citadel-completion-cancellation-contract'].includes(name) ? ['authorizelaunch'] : [];
  const o = options(argv, { ...common, ...defaults[name] }, switches);
  if (name.startsWith('npc-biped')) o.outputdirectory ||= o.artifactdir;
  if (switches.includes('authorizelaunch')) demand(o.authorizelaunch, 'Launch deferred: stable interfaces must be confirmed before -AuthorizeLaunch');
  const c = context(o, ['building-contract', 'citadel-main-menu-diagnostic'].includes(name) ? '' : null, switches.includes('authorizelaunch'));
  const at = n => path.join(c.run, n);
  const resolve = p => path.resolve(c.project, p);
  const env = {};
  const files = [...sourceFiles[name], 'tools/run-' + name + '.mjs', 'tools/lib/building-runner.mjs', 'tools/lib/building-special.mjs', 'tools/lib/building-special-sources.mjs', 'tools/lib/building-source-bindings.mjs', 'tools/run-godot-scene-watchdog.mjs'];
  const metadata = { evidenceLevel: 'source/service or visual diagnostic only; no gameplay acceptance inferred' };
  let script, args, timeout = 45, reportPath = at('report.json'), expected = {}, noReport = false, isolate = false, save = false, membership = false, logPolicy = { pattern: engineErrors }, referenceHash, phaseA, checkpoint, runId = uid(), executableBefore;
  const bindInput = (key, input, hashKey = key + '_SHA') => { const p = resolve(input); env[key] = p; env[hashKey] = sha(p); files.push(p); return p; };

  if (name === 'building-contract') {
    demand(/^[A-Z][A-Z0-9_]+$/.test(o.reportenvironment), 'Invalid report variable');
    if (/^[A-Za-z0-9]+\.gd$/.test(o.contract)) script = 'res://scripts/testing/buildings/' + o.contract;
    else {
      demand(o.contract.startsWith('res://artifacts/citadel-runtime-integration/'), 'Invalid contract');
      const target = resolve(o.contract.slice(6));
      demand(inside(resolve('artifacts/citadel-runtime-integration'), target) && path.extname(target) === '.gd', 'Invalid artifact contract path');
      script = o.contract;
    }
    timeout = integer(o.timeoutseconds, 1, 240, 'TimeoutSeconds');
    env[o.reportenvironment] = o.outputisdirectory ? c.run : reportPath;
    isolate = 'userdata'; logPolicy = {};
  } else if (name === 'building-validation-cancellation-contract') {
    script = 'BuildingValidationCancellationContract.gd';
    const stages = typeof o.stagemap === 'string' ? JSON.parse(o.stagemap) : o.stagemap;
    for (const k of Object.keys(defaultStages)) demand(typeof stages[k] === 'string' && stages[k].trim(), 'Missing exact stage string: ' + k);
    Object.assign(env, { BUILDING_CANCELLATION_REPORT: reportPath, BUILDING_CANCELLATION_STAGES: JSON.stringify(stages) });
    timeout = integer(o.timeoutseconds, 1, 60, 'TimeoutSeconds');
    Object.assign(metadata, { schema: 'building_validation_cancellation_launch/v1', stageMap: stages, scope: 'Small synthetic fixtures invoking real source proofs. No old/new frozen full-input differential, headed or NPC acceptance.' });
    expected = { complete: true, passed: true, schema: 'building_validation_cancellation_contract/v1' };
  } else if (name === 'citadel-completion-cancellation-contract') {
    o.phase = choice(o.phase, ['cancellation', 'parity'], 'Phase');
    script = 'CitadelCompletionCancellationContract.gd';
    const archive = resolve(o.archive), archiveSha = '65149b8198ceaa52b19d27a1a8c2ee82edd5614e52bfd3d1e2cc65928e8b78cb';
    if (o.phase === 'cancellation') { demand(inside(c.project, archive) && sha(archive) === archiveSha, 'Immutable opening-head archive binding failed'); demand(o.laterstage.trim(), 'LaterStage required'); files.push(archive); }
    Object.assign(env, { CITADEL_COMPLETION_PHASE: o.phase, CITADEL_COMPLETION_REPORT: reportPath, CITADEL_COMPLETION_PROGRESS: at('progress.json'), CITADEL_COMPLETION_ARCHIVE: archive, CITADEL_COMPLETION_LATER_STAGE: o.laterstage });
    Object.assign(metadata, { schema: 'citadel_completion_contract_launch/v1', phase: o.phase, archive, archiveSha256: archiveSha, laterStage: o.laterstage, scope: 'Source/service only; no fullbuild, headed or runtime acceptance.' });
    timeout = integer(o.timeoutseconds, 1, 60, 'TimeoutSeconds'); expected = { complete: true, passed: true, phase: o.phase };
  } else if (name === 'citadel-main-menu-diagnostic') {
    files.push('tools/invoke-owned-game-window.mjs', 'tools/native/owned-window.cs', 'tools/native/owned-window-native.cs');
    const cleared = Object.keys(c.env).filter(k => /^(VOXEL_|CITADEL_|BUILDING_|TREE_)/i.test(k));
    for (const k of cleared) delete c.env[k];
    args = ['res://scenes/MainMenu.tscn']; timeout = 600; isolate = 'userdata'; noReport = true;
    Object.assign(metadata, { scene: args[0], headless: false, clearedEnvironmentNames: cleared, evidenceLevel: 'ordinary menu diagnostic, no engine-side fixture; no acceptance inferred' });
  } else if (name === 'citadel-recipe-preparation-contract') {
    o.phase = choice(o.phase, ['reference', 'fixture', 'worker'], 'Phase');
    script = 'CitadelRecipePreparationContract.gd';
    let referencePath = at('reference.bin'); referenceHash = '';
    if (o.phase !== 'reference') {
      demand(o.referencedirectory, 'Completed ReferenceDirectory is required');
      const dir = resolve(o.referencedirectory), r = read(path.join(dir, 'report.json'));
      assertReport(r, { passed: true, complete: true, referenceSnapshotComplete: true, phase: 'reference' });
      assertWatchdog(read(path.join(dir, 'watchdog.json')));
      referencePath = path.join(dir, 'reference.bin'); referenceHash = sha(referencePath);
      demand(referenceHash === r.referenceSha256, 'Reference artifact hash mismatch');
      demand(!/^(SCRIPT ERROR|ERROR):/im.test(fs.readFileSync(path.join(dir, 'stderr.log'), 'utf8')), 'Reference logged engine errors');
      files.push(referencePath, path.join(dir, 'report.json'), path.join(dir, 'watchdog.json'));
    }
    Object.assign(env, { VOXEL_CITADEL_RECIPE_PREPARATION_REPORT: reportPath, VOXEL_CITADEL_RECIPE_PREPARATION_PHASE: o.phase, VOXEL_CITADEL_RECIPE_REFERENCE: referencePath, VOXEL_CITADEL_RECIPE_REFERENCE_SHA256: referenceHash });
    timeout = o.phase === 'worker' ? 900 : 450; isolate = 'userdata'; save = true;
    expected = { passed: true, complete: true, phase: o.phase, [o.phase === 'reference' ? 'referenceSnapshotComplete' : 'fullArtifactsCompared']: true, ...(o.phase !== 'reference' ? { referenceSha256: referenceHash } : {}) };
  } else if (name === 'citadel-sign-completion-contract') {
    o.phase = choice(o.phase, ['final_old', 'final_new', 'initial', 'blocked'], 'Phase');
    script = 'CitadelSignCompletionContract.gd';
    bindInput('SIGN_COMPLETION_FINAL', o.finalsnapshot); bindInput('SIGN_COMPLETION_REFERENCE', o.referencesnapshot);
    Object.assign(env, { SIGN_COMPLETION_PHASE: o.phase, SIGN_COMPLETION_REPORT: reportPath });
  } else if (name === 'household-sign-placement-contract') {
    script = 'HouseholdSignPlacementContract.gd';
    bindInput('VOXEL_SIGN_PLACEMENT_INPUT', o.inputsnapshot); bindInput('VOXEL_SIGN_PLACEMENT_REFERENCE', o.referencesnapshot);
    env.VOXEL_SIGN_PLACEMENT_REPORT = reportPath;
  } else if (name === 'citadel-sign-socket-bounds-contract') {
    script = 'CitadelSignSocketBoundsContract.gd';
    bindInput('VOXEL_SIGN_BOUNDS_INPUT', 'artifacts/citadel-runtime-integration/actual-site-shop-02/result.bin');
    bindInput('VOXEL_SIGN_BOUNDS_FAILURE', 'artifacts/citadel-runtime-integration/actual-site-source-03/report.json');
    const launch = bindInput('VOXEL_SIGN_BOUNDS_LAUNCH', 'artifacts/citadel-runtime-integration/actual-site-source-03/launch.json');
    const recipe = read(launch).dependencies?.['res://scripts/buildings/HouseholdSignMountRecipe.gd'];
    demand(typeof recipe === 'string' && /^[a-f0-9]{64}$/i.test(recipe), 'Missing original sign recipe SHA');
    Object.assign(env, { VOXEL_SIGN_BOUNDS_REPORT: reportPath, VOXEL_SIGN_BOUNDS_RECIPE_SHA: recipe, VOXEL_SIGN_BOUNDS_ARM: 'urban_civic_house_east_sign_arm', VOXEL_SIGN_BOUNDS_BLOCKER: 'castle_terrace_block_03_right_05' });
  } else if (name === 'citadel-visual-preservation') {
    o.mode = choice(o.mode, ['Import', 'Contract', 'Capture'], 'Mode'); o.variant = choice(o.variant, ['urban', 'compound'], 'Variant');
    const seed = integer(o.seed, 1, 2147483647, 'Seed');
    demand(o.mode === 'Contract' || o.variant === 'urban', 'Variant applies only to contracts');
    Object.assign(env, { VOXEL_CITADEL_VISUAL_PRESERVATION_REPORT: reportPath, VOXEL_CITADEL_VISUAL_PRESERVATION_TOKEN: randomUUID(), VOXEL_CITADEL_VISUAL_PRESERVATION_PROGRESS: at('progress.txt'), VOXEL_CITADEL_URBAN_POC_REPORT: reportPath, VOXEL_CITADEL_URBAN_POC_SCREENSHOT_DIR: at('screenshots') });
    isolate = 'split'; timeout = 360;
    if (o.mode === 'Import') { args = ['--headless', '--editor', '--import']; noReport = true; }
    if (o.mode === 'Contract') args = ['--headless', '--script', 'res://scripts/testing/buildings/CitadelVisualPreservationContract.gd', '--', '--variant', o.variant];
    if (o.mode === 'Capture') { args = ['res://scenes/testing/buildings/CitadelUrbanPocTest.tscn', '--', '--seed', String(seed), '--citadel-scale', '1.25']; expected = { seed }; }
  } else if (name.startsWith('npc-biped')) {
    timeout = integer(o.timeoutseconds, 1, 86400, 'TimeoutSeconds');
    if (name === 'npc-biped-poc') {
      args = ['--resolution', '1280x720', '--scene', 'res://scenes/testing/NpcBipedPocTest.tscn', '--', '--seed', String(integer(o.seed, -2147483648, 2147483647, 'Seed'))];
      if (o.capture) { reportPath = at('npc-biped-poc-report.json'); env.VOXEL_NPC_BIPED_POC_REPORT = reportPath; env.VOXEL_NPC_BIPED_POC_CAPTURE = at('npc-biped-poc.png'); expected = { status: 'passed' }; }
      else noReport = true;
    } else {
      script = 'res://scripts/testing/npcs/NpcBipedRecipeContractRunner.gd'; reportPath = at('npc-biped-recipe-contract.json'); env.VOXEL_NPC_BIPED_RECIPE_CONTRACT_REPORT = reportPath;
    }
  } else if (name === 'citadel-structural-composer-two-phase-contract') {
    o.mode = choice(o.mode, ['Codec', 'PhaseA', 'PhaseB'], 'Mode');
    const seed = integer(o.seed, -2147483648, 2147483647, 'Seed');
    const { runtime } = resolveExecutablePair(c.executable);
    files.push(...structuralRunnerSources);
    executableBefore = { [c.executable]: sha(c.executable), [runtime]: sha(runtime) };
    isolate = 'split'; membership = true; logPolicy = { emptyStderr: true };
    Object.assign(env, { VOXEL_GODOT_EXE: c.executable, VOXEL_GODOT_RUNTIME_EXE: runtime, VOXEL_STRUCTURAL_COMPOSER_SEED: String(seed), VOXEL_STRUCTURAL_RUN_ID: runId });
    if (o.mode === 'Codec') {
      script = 'CitadelStructuralComposerCheckpointCodecContract.gd'; timeout = 120;
      Object.assign(env, { VOXEL_STRUCTURAL_CODEC_REPORT: reportPath, VOXEL_STRUCTURAL_CODEC_ARTIFACT_DIR: c.run });
    } else if (o.mode === 'PhaseA') {
      script = 'CitadelStructuralCompletionComposerPhaseAContract.gd'; timeout = 360;
      reportPath = at('phase-a-report.json'); checkpoint = at('checkpoint.bin');
      Object.assign(env, { VOXEL_STRUCTURAL_PHASE_A_REPORT: reportPath, VOXEL_STRUCTURAL_PHASE_A_REPORT_TEMP: at('.phase-a-report-' + runId + '.tmp'), VOXEL_STRUCTURAL_CHECKPOINT: checkpoint, VOXEL_STRUCTURAL_CHECKPOINT_TEMP: at('.checkpoint-' + runId + '.tmp') });
    } else {
      demand(o.phaseadirectory, 'PhaseADirectory required'); const dir = resolve(o.phaseadirectory);
      const phaseAPath = path.join(dir, 'phase-a-report.json'); checkpoint = path.join(dir, 'checkpoint.bin'); phaseA = read(phaseAPath);
      assertReport(phaseA, { passed: true, seed });
      // The old wrapper contained all phase logic in one fingerprinted file.
      // Bind the factored Node helpers/native sources across phases as well.
      const phaseALaunchPath = path.join(dir, 'launch.json'), phaseALaunch = read(phaseALaunchPath);
      validatePhaseASourceBindings(c.project, phaseALaunch, phaseA);
      files.push(phaseALaunchPath, ...Object.keys(phaseALaunch.sourceSha256));
      demand(typeof phaseA.runId === 'string' && phaseA.runId, 'Missing Phase A run ID');
      runId = phaseA.runId; script = 'CitadelStructuralCompletionComposerPhaseBContract.gd'; timeout = 120; reportPath = at('phase-b-report.json');
      Object.assign(env, { VOXEL_STRUCTURAL_RUN_ID: runId, VOXEL_STRUCTURAL_PHASE_A_REPORT: phaseAPath, VOXEL_STRUCTURAL_CHECKPOINT: checkpoint, VOXEL_STRUCTURAL_PHASE_A_REPORT_SHA256: sha(phaseAPath), VOXEL_STRUCTURAL_CHECKPOINT_SHA256: sha(checkpoint), VOXEL_STRUCTURAL_PHASE_B_REPORT: reportPath, VOXEL_STRUCTURAL_PHASE_B_REPORT_TEMP: at('.phase-b-report-' + uid() + '.tmp') });
      files.push(phaseAPath, checkpoint);
    }
    expected = { passed: true };
  } else throw new Error('Unknown specialized runner: ' + name);

  if (script && !script.startsWith('res://')) script = 'res://scripts/testing/buildings/' + script;
  if (script) { files.push(script.slice(6)); args = ['--headless', '--script', script]; }
  const exclusive = ['citadel-structural-composer-two-phase-contract', 'citadel-visual-preservation'].includes(name);
  if (exclusive) assertNoGodot();
  if (name === 'citadel-main-menu-diagnostic')
    files.push('project.godot', 'scripts/testing/AutomatedTestOverlay.gd', 'tools/lib/headed-test-evidence.mjs', 'tools/lib/building-runner.mjs');
  prepare(c, isolate, save);
  if (name === 'citadel-main-menu-diagnostic') fs.mkdirSync(at('screenshots'));
  const before = launchRecord(c, files, { ...metadata, timeoutSeconds: timeout, phase: o.phase, mode: o.mode });
  if (name === 'building-contract') await phaseRun(c, { args: [...args, '--check-only'], env, timeout, prefix: 'parse-', logPolicy }, runOwnedProcess);
  const headed = name === 'citadel-main-menu-diagnostic';
  const w = await phaseRun(c, { args, env, timeout, membership, logPolicy, live: headed,
    ...(headed ? { headedTest: { runnerId: name, sourceIdentity: { branch: git(c.project, 'branch', '--show-current').toString().trim(), head: git(c.project, 'rev-parse', 'HEAD').toString().trim(), sourceSha256: before } } } : {}),
    ...(name === 'citadel-structural-composer-two-phase-contract' ? { logExtension: 'txt', summaryName: 'watchdog-summary.json' } : {}) }, runOwnedProcess);
  stable(c.project, before);
  if (exclusive) assertNoGodot();
  if (executableBefore) stable(c.project, executableBefore);
  if (noReport) return { launcherClean: true, ownedZero: true, evidenceLevel: metadata.evidenceLevel, summaryPath: at('watchdog.json') };
  const report = read(reportPath); assertReport(report, expected);
  if (name === 'citadel-structural-composer-two-phase-contract' && o.mode === 'PhaseA') {
    assertReport(report, { runId, checkpointSha256: sha(checkpoint) }); demand(Number(report.checkpointSize) === fs.statSync(checkpoint).size, 'Checkpoint size mismatch');
  }
  return { reportPath, ownedZero: true, engineLogsClean: true, checks: Object.keys(report.checks ?? {}).length, phase: o.phase, referenceSha256: report.referenceSha256, elapsedSeconds: report.elapsedUsec === undefined ? undefined : report.elapsedUsec / 1000000, cleanupPassed: w.cleanupPassed };
}

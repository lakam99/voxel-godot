#!/usr/bin/env node
import { copyFile, lstat, mkdir, readFile } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { projectRoot, parseOptions, teleportOptions, freshDirectory, writeJson, readJson, sourceHashes, runtimeBinaryManifest, auditSources, git, exists, isFile, runCandidatePhase, ownedPassed, engineErrors, cli, sha256, validateSeed } from './lib/citadel-candidate-runner.mjs';

const runner = 'tools/run-citadel-candidate-teleport-playtest.mjs';
const script = 'res://scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd';
const saveDirectory = ['userdata', 'Godot', 'app_userdata', 'Voxel Biome World Godot'];
const normalized = value => process.platform === 'win32' ? value.toLowerCase() : value;
const vector3 = value => Array.isArray(value) && value.length === 3 && value.every(Number.isFinite);

const sameHashInventory = (left, right) => JSON.stringify(Object.entries(left ?? {}).sort()) === JSON.stringify(Object.entries(right ?? {}).sort());

async function rejectReparseComponents(root, target, label) {
  const rootPath = resolve(root), targetPath = resolve(target);
  const suffix = relative(rootPath, targetPath);
  if (suffix.startsWith('..') || isAbsolute(suffix)) throw new Error(`${label} escapes its trusted root.`);
  const rootInfo = await lstat(rootPath);
  if (rootInfo.isSymbolicLink()) throw new Error(`${label} contains a symlink, junction, or reparse component.`);
  let cursor = rootPath;
  for (const component of suffix.split(/[\\/]/).filter(Boolean)) {
    cursor = join(cursor, component);
    const info = await lstat(cursor);
    if (info.isSymbolicLink()) throw new Error(`${label} contains a symlink, junction, or reparse component.`);
  }
}

async function ordinarySaveReceipt(run, seed, report) {
  validateSeed(seed);
  if (!/^[A-Za-z0-9._-]+$/.test(seed)) throw new Error('Active seed is not safe for a save-slot filename.');
  const root = join(run, ...saveDirectory);
  const activePath = join(root, 'voxel_biome_world_saves_active_seed.txt');
  const slotName = `voxel_biome_world_saves_slot_${seed}.bin`;
  const slotPath = join(root, slotName);
  await rejectReparseComponents(run, activePath, 'Journey save path');
  await rejectReparseComponents(run, slotPath, 'Journey save path');
  const activeSeed = (await readFile(activePath, 'utf8')).replace(/^\uFEFF/, '').trim();
  const slotHeader = await readFile(slotPath);
  const playerPosition = report?.originalPlayerPosition;
  if (activeSeed !== seed || slotHeader.subarray(0, 4).toString('ascii') !== 'VBW2' || !vector3(playerPosition)) {
    throw new Error('Journey save must be a binary v2 slot with matching active seed and a reported player position.');
  }
  return { version: 2, activeSeed: seed, playerPosition,
    activeRelativePath: relative(run, activePath).replaceAll('\\', '/'), slotRelativePath: relative(run, slotPath).replaceAll('\\', '/'),
    activeSeedSha256: await sha256(activePath), slotSha256: await sha256(slotPath) };
}

async function captureIntegrityReceipts(run, report) {
  if (!Array.isArray(report?.captures) || report.captures.length === 0) throw new Error('Final journey acceptance requires captures.');
  const receipts = [];
  const seen = new Set();
  for (const capture of report.captures) {
    if (capture?.saved !== true || typeof capture.path !== 'string') throw new Error('Final journey capture receipt is incomplete.');
    const path = resolve(capture.path);
    const relativePath = relative(run, path).replaceAll('\\', '/');
    if (!relativePath || relativePath.startsWith('..') || isAbsolute(relativePath) || seen.has(relativePath)) throw new Error('Final journey capture path is unsafe or duplicated.');
    seen.add(relativePath);
    await rejectReparseComponents(run, path, 'Journey capture path');
    const info = await lstat(path);
    if (!info.isFile() || info.isSymbolicLink()) throw new Error('Final journey capture is not a regular file.');
    receipts.push({ relativePath, bytes: info.size, sha256: await sha256(path) });
  }
  return receipts;
}

async function readFinalAcceptanceReceipt(sourceRun) {
  const path = join(sourceRun, 'final-acceptance.json');
  if (!(await exists(path))) throw new Error('ContinueFrom final acceptance receipt is missing.');
  await rejectReparseComponents(sourceRun, path, 'ContinueFrom final acceptance receipt');
  await rejectReparseComponents(sourceRun, join(sourceRun, 'report.json'), 'ContinueFrom report');
  const receipt = await readJson(path);
  if (receipt.schema !== 'citadel-menu-journey-final-acceptance/v1' || receipt.finalized !== true || receipt.passed !== true
      || receipt.placementMode !== 'menu_journey') throw new Error('ContinueFrom final acceptance receipt is invalid.');
  if (receipt.reportSha256 !== await sha256(join(sourceRun, 'report.json'))) throw new Error('ContinueFrom report changed after final acceptance.');
  return receipt;
}

async function verifyFinalAcceptance(sourceRun, sourceReport, receipt = null) {
  receipt ??= await readFinalAcceptanceReceipt(sourceRun);
  await validateTeleportReport(sourceReport, sourceReport.seed, isFile, true, null);
  const captures = await captureIntegrityReceipts(sourceRun, sourceReport);
  if (JSON.stringify(captures) !== JSON.stringify(receipt.captures)) throw new Error('ContinueFrom capture evidence changed after final acceptance.');
  const save = await ordinarySaveReceipt(sourceRun, sourceReport.actualSeed, sourceReport);
  if (JSON.stringify(save) !== JSON.stringify(receipt.save)) throw new Error('ContinueFrom save changed after final acceptance.');
  return { receipt, save, captures };
}

export async function prepareContinueSave(project, run, continueFrom, dependencies = {}) {
  const artifactRoot = resolve(project, 'artifacts/citadel-runtime-integration');
  const sourceRun = resolve(project, String(continueFrom).replaceAll('\\', '/'));
  if (normalized(dirname(sourceRun)) !== normalized(artifactRoot) || !basename(sourceRun).toLowerCase().startsWith('menu-journey-')) {
    throw new Error('ContinueFrom must name an existing menu-journey directory directly under artifacts/citadel-runtime-integration.');
  }
  if (normalized(sourceRun) === normalized(run)) throw new Error('ContinueFrom cannot be the new output directory.');
  await rejectReparseComponents(artifactRoot, sourceRun, 'ContinueFrom');
  await rejectReparseComponents(sourceRun, join(sourceRun, 'report.json'), 'ContinueFrom report');
  const sourceReport = await readJson(join(sourceRun, 'report.json'));
  const finalReceipt = await readFinalAcceptanceReceipt(sourceRun);
  if (sourceReport.passed !== true || sourceReport.placementMode !== 'menu_journey') {
    throw new Error('ContinueFrom must be a passed ordinary New Game menu journey, not a failed or continued run.');
  }
  if (sourceReport.seed !== sourceReport.actualSeed) throw new Error('ContinueFrom report and saved seed disagree.');
  const finalAcceptance = await verifyFinalAcceptance(sourceRun, sourceReport, finalReceipt);
  await rejectReparseComponents(sourceRun, join(sourceRun, 'verification.json'), 'ContinueFrom verification');
  const sourceVerification = await readJson(join(sourceRun, 'verification.json'));
  if (finalAcceptance.receipt.verificationSha256 !== await sha256(join(sourceRun, 'verification.json'))) throw new Error('ContinueFrom verification changed after final acceptance.');
  if (sourceVerification.naturalExit !== true || sourceVerification.functionalExitCode !== 0 || sourceVerification.ownedZero !== true ||
      sourceVerification.cleanupPassed !== true || sourceVerification.engineErrorWarningCount !== 0 || sourceVerification.watcherFailed !== false ||
      sourceVerification.binariesFrozen !== true || !Array.isArray(sourceVerification.changedSources) || sourceVerification.changedSources.length !== 0) {
    throw new Error('ContinueFrom source verification did not complete cleanly with frozen sources.');
  }
  const sourceLaunchPath = join(sourceRun, 'launch.json');
  await rejectReparseComponents(sourceRun, sourceLaunchPath, 'ContinueFrom launch provenance');
  const sourceLaunch = await readJson(sourceLaunchPath);
  if (finalAcceptance.receipt.launchSha256 !== await sha256(sourceLaunchPath)) throw new Error('ContinueFrom launch provenance changed after final acceptance.');
  if (sourceLaunch.placementMode !== 'menu_journey') throw new Error('ContinueFrom launch provenance is not an ordinary New Game menu journey.');
  const recordedSourceHashes = sourceLaunch.sourceHashes;
  if (typeof recordedSourceHashes !== 'object' || recordedSourceHashes == null || Array.isArray(recordedSourceHashes) || Object.keys(recordedSourceHashes).length === 0) {
    throw new Error('ContinueFrom requires a complete recorded source hash inventory.');
  }
  for (const [path, hash] of Object.entries(recordedSourceHashes)) {
    const resolvedPath = resolve(project, path);
    const projectRelative = relative(project, resolvedPath);
    if (!path || projectRelative.startsWith('..') || isAbsolute(projectRelative) || !/^[a-f0-9]{64}$/.test(hash)) {
      throw new Error('ContinueFrom launch source hashes are malformed.');
    }
  }
  const currentSourceAudit = await auditSources(project, recordedSourceHashes);
  if (!currentSourceAudit.unchanged) throw new Error('ContinueFrom was produced by sources that do not match the current workspace.');
  const currentSourceHashes = await (dependencies.currentSourceHashes ?? sourceHashes)(project, 'teleport', dependencies.runner ?? 'tools/run-world-streaming-maturity-journey.mjs');
  if (!sameHashInventory(currentSourceHashes, recordedSourceHashes)) throw new Error('ContinueFrom source inventory does not exactly match the current workspace.');
  const recordedBinaries = sourceLaunch.binaries;
  if (typeof recordedBinaries !== 'object' || recordedBinaries == null || Array.isArray(recordedBinaries) || Object.keys(recordedBinaries).length === 0) {
    throw new Error('ContinueFrom requires a complete recorded runtime binary inventory.');
  }
  const currentBinaries = await (dependencies.currentRuntimeBinaries ?? runtimeBinaryManifest)(project);
  if (JSON.stringify(currentBinaries) !== JSON.stringify(recordedBinaries)) throw new Error('ContinueFrom runtime binaries do not match the current runtime.');
  const sourceAuditPath = join(sourceRun, 'source-hash-audit.json');
  if (!(await exists(sourceAuditPath))) throw new Error('ContinueFrom source hash audit is missing.');
  await rejectReparseComponents(sourceRun, sourceAuditPath, 'ContinueFrom source hash audit');
  const sourceAudit = await readJson(sourceAuditPath);
  if (finalAcceptance.receipt.sourceAuditSha256 !== await sha256(sourceAuditPath)) throw new Error('ContinueFrom source audit changed after final acceptance.');
  if (sourceAudit.unchanged !== true || !Array.isArray(sourceAudit.changedSources) || sourceAudit.changedSources.length ||
      !Array.isArray(sourceAudit.readErrors) || sourceAudit.readErrors.length) {
    throw new Error('ContinueFrom source hash audit was not clean.');
  }
  if (!sameHashInventory(sourceAudit.finalSourceHashes, recordedSourceHashes)) throw new Error('ContinueFrom source hash receipts disagree.');
  const sourceSaveDirectory = join(sourceRun, ...saveDirectory);
  const activeSeedPath = join(sourceSaveDirectory, 'voxel_biome_world_saves_active_seed.txt');
  const activeSeed = (await readFile(activeSeedPath, 'utf8')).replace(/^\uFEFF/, '').trim();
  validateSeed(activeSeed);
  if (!/^[A-Za-z0-9._-]+$/.test(activeSeed)) throw new Error('ContinueFrom active seed is not safe for a save-slot filename.');
  const slotName = `voxel_biome_world_saves_slot_${activeSeed}.bin`;
  const sourceSlotPath = join(sourceSaveDirectory, slotName);
  const slotHeader = await readFile(sourceSlotPath);
  const playerPosition = sourceReport.originalPlayerPosition;
  if (slotHeader.subarray(0, 4).toString('ascii') !== 'VBW2' || !vector3(playerPosition)) throw new Error('ContinueFrom save must be a binary v2 slot with a reported player position.');
  if (sourceReport.seed !== activeSeed || sourceReport.actualSeed !== activeSeed) throw new Error('ContinueFrom report and saved seed disagree.');
  const activeSeedSha256 = await sha256(activeSeedPath);
  const slotSha256 = await sha256(sourceSlotPath);
  if (activeSeedSha256 !== finalAcceptance.save.activeSeedSha256 || slotSha256 !== finalAcceptance.save.slotSha256) {
    throw new Error('ContinueFrom save no longer matches its frozen final acceptance receipt.');
  }
  const destinationSaveDirectory = join(run, ...saveDirectory);
  await mkdir(destinationSaveDirectory, { recursive: true });
  const destinationActiveSeedPath = join(destinationSaveDirectory, 'voxel_biome_world_saves_active_seed.txt');
  const destinationSlotPath = join(destinationSaveDirectory, slotName);
  await copyFile(activeSeedPath, destinationActiveSeedPath);
  await copyFile(sourceSlotPath, destinationSlotPath);
  const copiedHashes = await Promise.all([sha256(activeSeedPath), sha256(destinationActiveSeedPath), sha256(sourceSlotPath), sha256(destinationSlotPath)]);
  if (copiedHashes[0] !== activeSeedSha256 || copiedHashes[1] !== activeSeedSha256 || copiedHashes[2] !== slotSha256 || copiedHashes[3] !== slotSha256) {
    throw new Error('ContinueFrom save changed while it was being copied.');
  }
  return {
    sourceOutputDirectory: relative(project, sourceRun).replaceAll('\\', '/'),
    activeSeed,
    playerPosition,
    sourceReportPassed: true,
    sourcePlacementMode: sourceReport.placementMode,
    sourceVerificationPassed: true,
    currentSourceParityChecked: true,
    exactCurrentSourceInventoryMatched: true,
    currentRuntimeBinaryParityChecked: true,
    saveVersion: 2,
    activeSeedSha256,
    slotSha256,
    copiedFiles: ['voxel_biome_world_saves_active_seed.txt', slotName],
    policy: 'immutable source save copied into a fresh isolated user profile; no save fields rewritten'
  };
}

function requireEvidence(condition, message) { if (!condition) throw new Error(message); }

export function validateMenuJourneyEvidence(report, continueSave = null) {
  requireEvidence(Array.isArray(report?.captures) && report.captures.length > 0 && report?.checks?.all_captures_saved === true,
    'Menu journey must claim a nonempty complete capture set.');
  const resolution = report?.evidence?.renderResolution;
  requireEvidence(report?.checks?.requested_render_resolution === true && Array.isArray(resolution?.requested)
    && Array.isArray(resolution?.window) && resolution.requested.length === 2
    && JSON.stringify(resolution.requested) === JSON.stringify(resolution.window)
    && ['1280,720', '1920,1080'].includes(resolution.window.join(',')),
  'Menu journey did not independently prove its requested native render window resolution.');
  requireEvidence(Array.isArray(report?.setupPlacements) && report.setupPlacements.length === 0, 'Menu journey must independently prove zero setup teleports.');
  requireEvidence(report?.checks?.setup_write_limit === true && report?.evidence?.seedSelection?.setupTeleportCount === 0,
    'Menu journey zero-teleport receipts are incomplete.');
  const holds = report?.evidence?.terrainCollisionHolds;
  requireEvidence(report?.checks?.menu_journey_no_terrain_collision_holds === true && holds?.frames === 0
    && Array.isArray(holds?.samples) && holds.samples.length === 0 && holds?.samplesDropped === 0
    && holds?.reasons && Object.keys(holds.reasons).length === 0,
  'Menu journey did not satisfy the required zero collision-hold policy.');
  const policy = report?.evidence?.menuJourneySurvivalPolicy;
  requireEvidence(report?.checks?.menu_journey_survival_policy === true && policy?.enabled === true
    && policy?.reason === 'citadel_menu_journey' && policy?.scope === 'player_survival_damage_only',
  'Menu journey godmode policy was not disclosed consistently.');
  requireEvidence(report?.acceptanceClassification === 'streaming_and_physical_journey_diagnostic'
    && report?.godMode?.enabled === true && report.godMode.scope === 'player_survival_damage_only'
    && report.godMode.notAcceptanceFor?.includes('survival') && report.godMode.notAcceptanceFor?.includes('combat'),
  'Godmode journey must explicitly exclude survival and combat acceptance.');
  const inspection = report?.evidence?.playerScaleInspection;
  requireEvidence(report?.checks?.menu_journey_player_scale_inspection === true && inspection?.passed === true
    && inspection?.reason === 'ordinary_player_scale_inspection_complete' && Array.isArray(inspection?.stages),
  'Menu journey itinerary completion evidence is missing.');
  const stages = inspection.stages;
  const stage = name => stages.find(row => row?.stage === name);
  const indices = names => names.map(name => stages.findIndex(row => row?.stage === name));
  const movementStages = ['gate_cross', 'return_gate_cross', 'home_entry', 'home_exit',
    'gate_stair_base', 'gate_stair_landing_00', 'gate_stair_exit_00'];
  for (const name of movementStages) requireEvidence(stage(name)?.movement?.passed === true, `Menu journey itinerary stage did not pass: ${name}.`);
  requireEvidence(stage('gate_cross').movement.gateInteriorClearance > 1.0, 'Gate crossing did not prove interior clearance.');
  requireEvidence(stage('interior_views')?.strictInside === true, 'Home itinerary did not independently prove strict interior entry.');
  for (const [name, desiredOpen] of [['gate_open', true], ['home_open', true], ['home_close', false], ['gate_stair_door_open', true]]) {
    const interaction = stage(name)?.interaction;
    requireEvidence(interaction?.passed === true && interaction.desiredOpen === desiredOpen && interaction.actualOpen === desiredOpen,
      `Door interaction sequence did not prove ${name}.`);
    const attachment = interaction?.nativeAttachment;
    requireEvidence(attachment?.passed === true && attachment.before?.passed === true
      && attachment.firstMotion?.passed === true && attachment.after?.passed === true
      && attachment.beforeCapture === true && attachment.firstDrawCapture === true
      && JSON.stringify(attachment.before.identity) === JSON.stringify(attachment.after.identity)
      && JSON.stringify(attachment.before.collisionIds) === JSON.stringify(attachment.after.collisionIds),
    `Native attachment identity, first-motion draw, or collision preservation missing for ${name}.`);
    requireEvidence(attachment.before.motionKind === (name === 'gate_open' ? 'raise' : 'swing'),
      `Door motion kind was not the expected production swing/raise path for ${name}.`);
  }
  const ordered = indices(['gate_open', 'gate_cross', 'return_gate_cross', 'home_open', 'home_entry', 'home_exit', 'home_close',
    'gate_stair_door_open', 'gate_stair_base', 'gate_stair_landing_00', 'gate_stair_exit_00']);
  requireEvidence(ordered.every(index => index >= 0) && ordered.every((value, index) => index === 0 || value > ordered[index - 1]),
    'Menu journey itinerary or door sequence was incomplete or out of order.');
  if (!continueSave) {
    const departure = report?.evidence?.tutorialDeparture;
    requireEvidence(report?.checks?.tutorial_departure_via_generated_door === true && departure?.passed === true
      && departure?.approached === true && departure?.rayFoundDoor === true && departure?.opened === true && departure?.exited === true,
    'New Game journey did not prove the claimed tutorial-door departure sequence.');
  }
}

export async function validateTeleportReport(report, seed, captureExists = isFile, menuJourney = false, continueSave = null) {
  const expectedPlacementMode = continueSave ? 'menu_continue_journey' : 'menu_journey';
  if (!report || report.passed !== true || (!menuJourney && (report.seed !== seed || report.actualSeed !== seed)) || (menuJourney && (report.placementMode !== expectedPlacementMode || !report.actualSeed))) throw new Error('No successful headed diagnostic report.');
  if (continueSave) {
    if (report.actualSeed !== continueSave.activeSeed || !vector3(report.originalPlayerPosition)) throw new Error('Continue journey restored the wrong seed or omitted its player position.');
    const errorSquared = report.originalPlayerPosition.reduce((sum, coordinate, index) => sum + (coordinate - continueSave.playerPosition[index]) ** 2, 0);
    // A CharacterBody may settle against the authoritative terrain during the
    // few physics frames between gameplay enablement and fixture attachment.
    // One metre is strict enough to reject another spawn while allowing that
    // normal collision recovery; the source position remains recorded exactly.
    if (errorSquared > 1.0) throw new Error('Continue journey did not restore the copied save position.');
  }
  if (menuJourney) validateMenuJourneyEvidence(report, continueSave);
  if (!Array.isArray(report.captures)) throw new Error('Missing reported viewport captures.');
  for (const capture of report.captures) if (capture.saved !== true || typeof capture.path !== 'string' || !(await captureExists(capture.path))) throw new Error('Missing reported viewport capture.');
}
export async function runTeleportPlaytest(input, dependencies = {}) {
  const inheritedEnv = dependencies.env ?? process.env;
  const o = teleportOptions(input, inheritedEnv), project = dependencies.projectPath ?? projectRoot;
  const effectiveRunner = dependencies.runner ?? runner;
  const initialSpawn = o.spawnCell !== '';
  const run = await freshDirectory(project, o.outputDirectory, o.menuJourney ? 'menu-journey-' : 'candidate-teleport-');
  await mkdir(join(run, 'userdata'));
  const continueSave = o.menuContinueJourney
    ? await (dependencies.prepareContinueSave ?? prepareContinueSave)(project, run, o.continueFrom, { runner: effectiveRunner })
    : null;
  const hashes = await (dependencies.sourceHashes ?? sourceHashes)(project, 'teleport', effectiveRunner);
  const binaries = await (dependencies.runtimeBinaryManifest ?? runtimeBinaryManifest)(project);
  const args = [script, '--resolution', o.resolution, '--windowed', ...(o.gameArguments.length ? ['--', ...o.gameArguments] : [])];
  const placementMode = o.menuContinueJourney ? 'menu_continue_journey' : (o.menuJourney ? 'menu_journey' : (initialSpawn ? 'initial_spawn' : 'teleport'));
  await writeJson(join(run, 'launch.json'), { schema: 'citadel-candidate-teleport-launch/v1', projectPath: project, head: (dependencies.git ?? git)(project, ['rev-parse', 'HEAD']).trim(), seed: continueSave?.activeSeed ?? o.seed, requestedRegion: o.candidateRegion,
    timeoutSeconds: o.overallTimeoutSeconds, startupTimeoutSeconds: o.startupTimeoutSeconds, testTimeoutSeconds: o.timeoutSeconds, manualInspectionSeconds: o.manualInspectionSeconds, scaleSoakSeconds: o.scaleSoakSeconds, playerInspectionOnly: o.playerInspectionOnly, internalDeadlineSeconds: o.timeoutSeconds - 45, launchOptions: o.launchOptions, resolution: o.resolution, headed: true, scene: script, arguments: args, sourceHashes: hashes, binaries, recordedUtc: new Date().toISOString(),
    spawnCell: o.spawnCell, placementMode, continueSave, captureNavigationRejections: o.captureNavigationRejections,
    evidenceLevel: o.menuContinueJourney ? 'headed visible Main Menu Continue journey from an immutable ordinary save copy; zero setup teleports; not NPC acceptance' : (o.menuJourney ? 'headed visible Main Menu New Game journey; zero setup teleports; not NPC acceptance' : (initialSpawn ? 'headed initial-location New Game diagnostic; bypasses title UI; not ordinary menu or NPC acceptance' : 'headed teleport-assisted diagnostic; not continuous travel or NPC acceptance')),
    fixtureChanges: [o.menuContinueJourney ? 'visible Main Menu Continue input; exact prior ordinary save copied to a fresh isolated profile; zero setup teleports' : (o.menuJourney ? 'visible Main Menu New Game input; production-selected seed; zero setup teleports' : (initialSpawn ? 'seed and initial spawn selection before player attachment and terrain streaming; no generated artifact prewarm' : 'seed-selector-only Main subclass')),
      (initialSpawn || o.menuJourney) ? 'zero setup teleports; ordinary startup owns physics readiness' : 'two counted exterior setup teleports; physics held only for setup clearance',
      'isolated ordinary user data',
      ...((o.scaleSoakSeconds > 0 || o.menuJourney) ? ['test-only player-survival god mode; movement, collision, world time, weather, hostiles, NPCs and autosave remain live; this is not survival or combat acceptance'] : []),
      ...(o.playerInspectionOnly ? ['focused player-scale itinerary shakedown; does not execute or prove the retirement soak'] : []),
      'labelled diagnostic camera views after ordinary player approach'] });
  const env = { ...inheritedEnv, APPDATA: join(run, 'userdata'), LOCALAPPDATA: join(run, 'userdata'), CITADEL_CANDIDATE_TELEPORT_OUTPUT: run, CITADEL_CANDIDATE_TELEPORT_SEED: o.menuJourney ? '' : o.seed,
    CITADEL_CANDIDATE_TELEPORT_SECONDS: String(o.timeoutSeconds), CITADEL_CANDIDATE_STARTUP_SECONDS: String(o.startupTimeoutSeconds), CITADEL_CANDIDATE_MANUAL_SECONDS: String(o.manualInspectionSeconds), CITADEL_CANDIDATE_TELEPORT_REGION: o.candidateRegion, CITADEL_CANDIDATE_RESOLUTION: o.resolution,
    CITADEL_CANDIDATE_SPAWN_CELL: o.spawnCell,
    CITADEL_CANDIDATE_SCALE_SOAK_SECONDS: String(o.scaleSoakSeconds),
    CITADEL_CANDIDATE_PLAYER_INSPECTION_ONLY: o.playerInspectionOnly ? '1' : '',
    CITADEL_CANDIDATE_MENU_JOURNEY: o.menuJourney ? '1' : '',
    CITADEL_CANDIDATE_MENU_CONTINUE_JOURNEY: o.menuContinueJourney ? '1' : '',
    VOXEL_NAVIGATION_REJECTION_DIAGNOSTICS: o.captureNavigationRejections ? '1' : '' };
  const runOwnedProcess = dependencies.runOwnedProcess ?? (await import('./run-godot-scene-watchdog.mjs')).runOwnedProcess;
  const result = await runCandidatePhase({ project, run, kind: 'teleport', env, runOwnedProcess, timeoutSeconds: o.overallTimeoutSeconds, args: ['--path', project, '--script', ...args] });
  const watch = result.summary;
  const pathAudit = await auditSources(project, hashes);
  const finalHashes = await (dependencies.sourceHashes ?? sourceHashes)(project, 'teleport', effectiveRunner);
  const initialPaths = new Set(Object.keys(hashes));
  const finalPaths = new Set(Object.keys(finalHashes));
  const addedSources = [...finalPaths].filter(path => !initialPaths.has(path)).sort();
  const removedSources = [...initialPaths].filter(path => !finalPaths.has(path)).sort();
  const changedSources = [...new Set([
    ...Object.keys(hashes).filter(path => finalHashes[path] != null && finalHashes[path] !== hashes[path]),
    ...pathAudit.changedSources.map(row => row.path),
  ])].sort();
  const completeInventoryFrozen = sameHashInventory(finalHashes, hashes) && pathAudit.unchanged;
  const audit = { schema: 'citadel-source-hash-audit/v2', unchanged: completeInventoryFrozen,
    initialSourceCount: Object.keys(hashes).length, finalSourceCount: Object.keys(finalHashes).length,
    addedSources, removedSources, changedSources, readErrors: pathAudit.readErrors,
    initialSourceHashes: hashes, finalSourceHashes: finalHashes };
  await writeJson(join(run, 'source-hash-audit.json'), audit);
  const changed = [...new Set([...addedSources, ...removedSources, ...changedSources, ...pathAudit.readErrors.map(row => row.path)])];
  const finalBinaries = await (dependencies.runtimeBinaryManifest ?? runtimeBinaryManifest)(project);
  const binariesFrozen = JSON.stringify(finalBinaries) === JSON.stringify(binaries);
  const errors = await engineErrors([result.stdoutPath, result.stderrPath]);
  const reportPath = join(run, 'report.json');
  const report = await exists(reportPath) ? await readJson(reportPath) : null;
  const verification = { naturalExit: watch.rootExited === true && !watch.forcedCleanup && !watch.timedOut, functionalExitCode: watch.functionalExitCode, ownedZero: watch.authoritativeZeroProven,
    cleanupPassed: watch.cleanupPassed, engineErrorWarningCount: errors.length, changedSources: changed,
    binariesFrozen, binaries, finalBinaries, reportPath, watcherFailed: result.watcherFailed, visualInspectionRequired: true };
  await writeJson(join(run, 'verification.json'), { ...verification,
    receiptScope: 'owned lifecycle and preliminary frozen-input checks only; not reusable source acceptance',
    finalAcceptanceReceipt: null });
  if (!ownedPassed(watch)) throw new Error('Diagnostic failed or owned cleanup unresolved; retain report/log/watchdog evidence.');
  if (verification.watcherFailed || result.stopRequested || errors.length || changed.length || !binariesFrozen) throw new Error('Watcher, engine log, or frozen source/binary verification failed.');
  await validateTeleportReport(report, o.seed, isFile, o.menuJourney, continueSave);
  if (o.captureNavigationRejections && report.evidence?.navigationPublication?.rejectionDiagnosticsEnabled !== true) throw new Error('Navigation rejection diagnostics were requested but not recorded.');
  if (initialSpawn && (report.placementMode !== 'initial_spawn' || report.setupPlacements?.length !== 0 || report.initialSpawn?.requestedCell !== o.spawnCell || report.checks?.initial_spawn_selected_before_attachment !== true)) throw new Error('Initial spawn evidence mismatch.');
  if (o.gameArguments.length && Object.entries(o.launchOptions).some(([key, value]) => report.launchOptions?.[key] !== value)) throw new Error('Game launch options did not match requested options.');
  let finalAcceptance = null;
  if (o.menuJourney && !o.menuContinueJourney) {
    const captures = await captureIntegrityReceipts(run, report);
    const save = await ordinarySaveReceipt(run, report.actualSeed, report);
    finalAcceptance = { schema: 'citadel-menu-journey-final-acceptance/v1', finalized: true, passed: true,
      placementMode: 'menu_journey', reportSha256: await sha256(reportPath), captures, save,
      launchSha256: await sha256(join(run, 'launch.json')),
      verificationSha256: await sha256(join(run, 'verification.json')),
      sourceAuditSha256: await sha256(join(run, 'source-hash-audit.json')),
      policy: 'Written only after outer report validation, capture integrity, save-v2 receipt, lifecycle, complete source inventory, and runtime binary checks pass.' };
    await writeJson(join(run, 'final-acceptance.json'), finalAcceptance);
  }
  return { passed: true, outcome: report.outcome, setupPlacements: Array.isArray(report.setupPlacements) ? report.setupPlacements.length : report.setupPlacements == null ? 0 : 1, reportPath, ownedZero: true, visualInspectionRequired: true };
}
await cli(import.meta.url, argv => runTeleportPlaytest(parseOptions(argv, 'teleport')));

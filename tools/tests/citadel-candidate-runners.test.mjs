import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, appendFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { expectedError, parseOptions, recipeOptions, teleportOptions, regionCoordinates, freshDirectory, recipeStopReason, validateRecipeErrors, ownedPassed, startCandidateWatcher, runCandidatePhase, auditSources, sha256, sourceHashes, helperSource, watchdogSource, watchdogDependencies, engineErrors, godotEngineSiblingPath, readJson, runtimeBinaryManifest, writeJson } from '../lib/citadel-candidate-runner.mjs';
import { recipeVerification, runRecipeDiagnostic } from '../run-citadel-candidate-recipe-diagnostic.mjs';
import { prepareContinueSave, validateMenuJourneyEvidence, validateTeleportReport, runTeleportPlaytest } from '../run-citadel-candidate-teleport-playtest.mjs';
import { runWatcherCases } from '../test-candidate-recipe-error-watcher.mjs';

async function temporary(t) {
  const dir = await mkdtemp(join(tmpdir(), 'citadel-candidate-unit-'));
  t.after(async () => {
    assert.equal(resolve(dir).startsWith(resolve(tmpdir()) + (process.platform === 'win32' ? '\\' : '/')), true);
    await rm(dir, { recursive: true, force: true });
  });
  return dir;
}
const goodOwned = { overallExitCode: 0, cleanupPassed: true, authoritativeZeroProven: true };
const fixtureBinaries = () => ({
  godot: { path: 'synthetic-godot-console', bytes: 1, sha256: 'b'.repeat(64) },
  godotEngine: { path: 'synthetic-godot-engine', bytes: 2, sha256: 'e'.repeat(64) },
});

async function createContinueSource(project, name, overrides = {}) {
  const source = join(project, `artifacts/citadel-runtime-integration/${name}`);
  const saveRoot = join(source, 'userdata/Godot/app_userdata/Voxel Biome World Godot');
  const sourcePath = `provenance/${name}.gd`;
  await mkdir(saveRoot, { recursive: true });
  await mkdir(join(project, 'provenance'), { recursive: true });
  await writeFile(join(project, sourcePath), 'frozen source');
  const sourceHash = await sha256(join(project, sourcePath));
  const capturePath = join(source, 'capture.png');
  await writeFile(capturePath, 'frozen capture');
  const report = { ...menuJourneyReport(false), captures: [{ saved: true, path: capturePath }], ...overrides.report };
  await writeJson(join(source, 'report.json'), report);
  await writeJson(join(source, 'verification.json'), { naturalExit: true, functionalExitCode: 0, ownedZero: true, cleanupPassed: true, engineErrorWarningCount: 0, watcherFailed: false, binariesFrozen: true, changedSources: [], ...overrides.verification });
  const sourceHashes = overrides.omitSourceHashes ? undefined : { [sourcePath]: sourceHash };
  await writeJson(join(source, 'launch.json'), { placementMode: 'menu_journey', binaries: fixtureBinaries(), ...(sourceHashes ? { sourceHashes } : {}), ...overrides.launch });
  if (overrides.audit !== false) await writeJson(join(source, 'source-hash-audit.json'), { unchanged: true, changedSources: [], readErrors: [], finalSourceHashes: sourceHashes ?? {}, ...overrides.audit });
  await writeFile(join(saveRoot, 'voxel_biome_world_saves_active_seed.txt'), 'atlas-123\n');
  await writeFile(join(saveRoot, 'voxel_biome_world_saves_slot_atlas-123.bin'), overrides.slotBytes ?? Buffer.concat([Buffer.from('VBW2'), Buffer.from([0, 0, 0, 0])]));
  if (overrides.acceptance !== false) {
    const slotPath = join(saveRoot, 'voxel_biome_world_saves_slot_atlas-123.bin');
    const activePath = join(saveRoot, 'voxel_biome_world_saves_active_seed.txt');
    await writeJson(join(source, 'final-acceptance.json'), {
      schema: 'citadel-menu-journey-final-acceptance/v1', finalized: true, passed: true, placementMode: 'menu_journey',
      reportSha256: await sha256(join(source, 'report.json')),
      captures: [{ relativePath: 'capture.png', bytes: (await readFile(capturePath)).length, sha256: await sha256(capturePath) }],
      save: { version: 2, activeSeed: 'atlas-123', playerPosition: [1, 2, 3],
        activeRelativePath: 'userdata/Godot/app_userdata/Voxel Biome World Godot/voxel_biome_world_saves_active_seed.txt',
        slotRelativePath: 'userdata/Godot/app_userdata/Voxel Biome World Godot/voxel_biome_world_saves_slot_atlas-123.bin',
        activeSeedSha256: await sha256(activePath), slotSha256: await sha256(slotPath) },
      launchSha256: await sha256(join(source, 'launch.json')),
      verificationSha256: await sha256(join(source, 'verification.json')),
      sourceAuditSha256: overrides.audit === false ? '' : await sha256(join(source, 'source-hash-audit.json')),
      ...overrides.acceptance,
    });
  }
  return { source, saveRoot, sourcePath, sourceHashes, capturePath };
}

const prepareFixtureContinue = (project, destination, path, hashes) => prepareContinueSave(project, destination, path,
  { currentSourceHashes: async () => hashes, currentRuntimeBinaries: async () => fixtureBinaries() });

function menuJourneyReport(continued = false) {
  const movement = { passed: true };
  const interaction = desiredOpen => ({ passed: true, desiredOpen, actualOpen: desiredOpen });
  const stages = [
    { stage: 'gate_open', interaction: interaction(true) },
    { stage: 'gate_cross', movement: { passed: true, gateInteriorClearance: 2 } },
    { stage: 'return_gate_cross', movement },
    { stage: 'home_open', interaction: interaction(true) },
    { stage: 'home_entry', movement },
    { stage: 'interior_views', strictInside: true },
    { stage: 'home_exit', movement },
    { stage: 'home_close', interaction: interaction(false) },
    { stage: 'gate_stair_door_open', interaction: interaction(true) },
    { stage: 'gate_stair_base', movement },
    { stage: 'gate_stair_landing_00', movement },
    { stage: 'gate_stair_exit_00', movement },
  ];
  return {
    passed: true, seed: 'atlas-123', actualSeed: 'atlas-123',
    placementMode: continued ? 'menu_continue_journey' : 'menu_journey',
    originalPlayerPosition: [1, 2, 3], setupPlacements: [], captures: [{ saved: true, path: '/capture.png' }],
    checks: { setup_write_limit: true, menu_journey_no_terrain_collision_holds: true,
      menu_journey_survival_policy: true, menu_journey_player_scale_inspection: true,
      all_captures_saved: true, requested_render_resolution: true,
      ...(!continued ? { tutorial_departure_via_generated_door: true } : {}) },
    evidence: { seedSelection: { setupTeleportCount: 0 },
      renderResolution: { requested: [1920, 1080], window: [1920, 1080], viewport: [1280, 720] },
      terrainCollisionHolds: { frames: 0, reasons: {}, samples: [], samplesDropped: 0 },
      menuJourneySurvivalPolicy: { enabled: true, reason: 'citadel_menu_journey', scope: 'player_survival_damage_only' },
      playerScaleInspection: { passed: true, reason: 'ordinary_player_scale_inspection_complete', stages },
      ...(!continued ? { tutorialDeparture: { passed: true, approached: true, rayFoundDoor: true, opened: true, exited: true } } : {}) },
    acceptanceClassification: 'streaming_and_physical_journey_diagnostic',
    godMode: { enabled: true, scope: 'player_survival_damage_only', reason: 'citadel_menu_journey', notAcceptanceFor: ['survival', 'combat'] },
  };
}

test('CLI preserves PowerShell-style names and negative regions, accepts kebab-case, rejects unknown/missing/duplicate options', () => {
  assert.deepEqual(parseOptions(['-OutputDirectory', 'out', '-CandidateRegion', '-1,0', '-CaptureBlueprint'], 'recipe'), { outputDirectory: 'out', candidateRegion: '-1,0', captureBlueprint: true });
  assert.deepEqual(parseOptions(['--output-directory=out', '-ExpectReady:$false', '--capture-failure=true'], 'recipe'), { outputDirectory: 'out', expectReady: false, captureFailure: true });
  for (const args of [[], ['-OutputDirectory'], ['-Unknown'], ['-OutputDirectory', 'out', '-OutputDirectory', 'again'], ['-OutputDirectory', 'out', '-CaptureFailure=nope']]) assert.throws(() => parseOptions(args, 'recipe'));
});
test('recipe modes retain ceilings, structured-rejection policy, and exclusivity', () => {
	for (const [mode, run, source, proof, error] of [['default', 540, 450, 60, ''], ['captureFailure', 540, 450, 0, ''], ['captureBlueprint', 540, 450, 0, ''], ['expectReady', 540, 450, 60, '']]) {
    const o = recipeOptions(mode === 'default' ? {} : { [mode]: true });
    assert.deepEqual([o.runSeconds, o.sourceSeconds, o.proofSeconds, o.expectedError], [run, source, proof, error]);
    assert.equal(o.expectedRecipeSeed, 1747969299);
  }
  for (const input of [{ captureBlueprint: true, expectReady: true }, { captureFailure: true, expectReady: true }, { captureFailure: true, captureBlueprint: true }, { expectedRecipeSeed: -1 }, { expectedRecipeSeed: 2147483648 }, { expectedRecipeSeed: '1.5' }, { seed: ' ' }, { seed: 'x'.repeat(129) }]) assert.throws(() => recipeOptions(input));
  assert.equal(recipeOptions({ expectedRecipeSeed: '0' }).expectedRecipeSeed, 0);
});
test('canonical region field bounds and teleport environment/deadline validation', () => {
  const spawn = teleportOptions(parseOptions(['-OutputDirectory','out','-SpawnCell','-3334,-2666','-CandidateRegion','-2,-2','-SkipTutorial'], 'teleport'), {});
  assert.equal(spawn.spawnCell, '-3334,-2666');
  assert.deepEqual(spawn.gameArguments, ['-SkipTutorial']);
  for (const input of [{ spawnCell: '1,2' }, { spawnCell: '1,2', skipTutorial: true }, { spawnCell: '1,2', candidateRegion: '0,0' }, { spawnCell: '1.5,2', skipTutorial: true, candidateRegion: '0,0' }]) assert.throws(() => teleportOptions(input, {}));
  assert.equal(teleportOptions({}, {}).resolution, '1280x720');
  assert.equal(teleportOptions(parseOptions(['-OutputDirectory','out','-Resolution','1920x1080'], 'teleport'), {}).resolution, '1920x1080');
  for (const resolution of ['0x0', '1920x0', '1280x720 --headless', null]) assert.throws(() => teleportOptions({ resolution }, {}));
  const flags = parseOptions(['-OutputDirectory','out','-SkipTutorial','-ForceDaytime','-ForceClearWeather','-StartupTimeoutSeconds','45'], 'teleport');
  const launch = teleportOptions(flags, {});
  assert.deepEqual(launch.gameArguments, ['-SkipTutorial','-ForceDaytime','-ForceClearWeather']);
  assert.equal(launch.overallTimeoutSeconds,645);
  const manual = teleportOptions(parseOptions(['-OutputDirectory','out','-ManualInspection'], 'teleport'), {});
  assert.equal(manual.manualInspectionSeconds,1800);
  assert.equal(manual.overallTimeoutSeconds,2520);
  assert.equal(manual.timeoutSeconds,600);
  assert.throws(()=>teleportOptions({manualInspection:'true'},{}));
  assert.deepEqual(teleportOptions({},{}).gameArguments,[]);
  assert.throws(()=>teleportOptions({skipTutorial:'false'},{}));
  for(const startupTimeoutSeconds of [14,361,'no']) assert.throws(()=>teleportOptions({startupTimeoutSeconds},{}));
  assert.deepEqual(regionCoordinates('-1048576,1048575'), [-1048576, 1048575]);
  for (const region of ['-0,0', '00,1', '+1,0', '1, 0', '0,0\n', '1048576,0', '-1048577,0', '', '1.0,0']) assert.throws(() => regionCoordinates(region));
  assert.equal(teleportOptions({}, {}).timeoutSeconds, 600);
  assert.equal(teleportOptions({ timeoutSeconds: '90' }, { VOXEL_EMPTY: '' }).timeoutSeconds, 90);
  for (const timeoutSeconds of [89, 2401, 90.5, 'x']) assert.throws(() => teleportOptions({ timeoutSeconds }, {}));
  assert.throws(() => teleportOptions({}, { VOXEL_FAST_BOOT: '0' }), /Unset inherited/);
  assert.throws(() => teleportOptions({}, { voxel_test: '1' }), /Unset inherited/);
  const diagnostic = teleportOptions(parseOptions(['-OutputDirectory','out','-CaptureNavigationRejections'], 'teleport'), {});
  assert.equal(diagnostic.captureNavigationRejections, true);
  assert.deepEqual(diagnostic.gameArguments, []);
  assert.throws(() => teleportOptions({captureNavigationRejections:true}, {VOXEL_NAVIGATION_REJECTION_DIAGNOSTICS:'1'}), /Unset inherited/);
  assert.throws(() => teleportOptions({captureNavigationRejections:'true'}, {}), /Invalid boolean/);
});
test('journey CLI and continuation mode require one explicit source', () => {
  const parsed = parseOptions(['-OutputDirectory','artifacts/citadel-runtime-integration/menu-journey-next','-ContinueFrom','artifacts/citadel-runtime-integration/menu-journey-prior'], 'journey');
  assert.equal(parsed.continueFrom, 'artifacts/citadel-runtime-integration/menu-journey-prior');
  const continued = teleportOptions({ ...parsed, menuJourney: true, menuContinueJourney: true }, {});
  assert.equal(continued.menuContinueJourney, true);
  for (const input of [
    { menuJourney: true, menuContinueJourney: true },
    { menuJourney: true, continueFrom: 'artifacts/citadel-runtime-integration/menu-journey-prior' },
    { menuContinueJourney: true, continueFrom: 'artifacts/citadel-runtime-integration/menu-journey-prior' }
  ]) assert.throws(() => teleportOptions(input, {}));
  const base = ['-OutputDirectory', 'artifacts/citadel-runtime-integration/menu-journey-next'];
  for (const ignored of [
    ['-Seed', 'ignored'], ['-CandidateRegion', '0,0'], ['-SkipTutorial'], ['-ForceDaytime'], ['-ForceClearWeather'], ['-SpawnCell', '0,0'],
    ['-ManualInspection'], ['-ScaleSoakSeconds', '180'], ['-PlayerInspectionOnly'], ['-CaptureNavigationRejections']
  ]) assert.throws(() => parseOptions([...base, ...ignored], 'journey'), /Unknown option/);
});
test('continue preparation copies only the active ordinary save with immutable provenance', async t => {
  const project = await temporary(t);
  const { saveRoot, sourceHashes } = await createContinueSource(project, 'menu-journey-prior');
  const destination = join(project, 'artifacts/citadel-runtime-integration/menu-journey-next');
  await mkdir(destination, { recursive: true });
  await writeFile(join(saveRoot, 'unrelated-cache.bin'), 'must-not-copy');
  const receipt = await prepareFixtureContinue(project, destination, 'artifacts/citadel-runtime-integration/menu-journey-prior', sourceHashes);
  assert.deepEqual(receipt.playerPosition, [1, 2, 3]);
  assert.equal(receipt.activeSeed, 'atlas-123');
  assert.equal(receipt.sourceReportPassed, true);
  assert.equal(receipt.sourcePlacementMode, 'menu_journey');
  assert.equal(receipt.sourceVerificationPassed, true);
  assert.equal(receipt.currentSourceParityChecked, true);
  const copiedRoot = join(destination, 'userdata/Godot/app_userdata/Voxel Biome World Godot');
  assert.equal((await readFile(join(copiedRoot, 'voxel_biome_world_saves_active_seed.txt'), 'utf8')).trim(), 'atlas-123');
  assert.deepEqual(await readFile(join(copiedRoot, 'voxel_biome_world_saves_slot_atlas-123.bin')),
    await readFile(join(source.saveRoot, 'voxel_biome_world_saves_slot_atlas-123.bin')));
  assert.equal(receipt.saveVersion, 2);
  await assert.rejects(readFile(join(copiedRoot, 'unrelated-cache.bin')));
  await assert.rejects(prepareContinueSave(project, destination, '../menu-journey-escape'));
});
test('continue preparation rejects failed, continued, stale, or internally inconsistent sources', async t => {
  const project = await temporary(t);
  const cases = [
    ['menu-journey-failed', { report: { passed: false } }, /passed ordinary New Game/],
    ['menu-journey-continued', { report: { placementMode: 'menu_continue_journey' } }, /passed ordinary New Game/],
    ['menu-journey-bad-exit', { verification: { functionalExitCode: 1 } }, /verification/],
    ['menu-journey-binary-changed-during-run', { verification: { binariesFrozen: false } }, /verification/],
    ['menu-journey-binary-current-mismatch', { launch: { binaries: { godot: { path: 'other', bytes: 2, sha256: 'c'.repeat(64) } } } }, /binaries do not match/],
    ['menu-journey-changed-during-run', { verification: { changedSources: ['source.gd'] } }, /verification/],
    ['menu-journey-invalid-outer-evidence', { report: { checks: { all_captures_saved: true } } }, /render window resolution|zero-teleport|collision-hold|itinerary/],
    ['menu-journey-bad-launch', { launch: { placementMode: 'menu_continue_journey' } }, /launch provenance/],
    ['menu-journey-bad-audit', { audit: { unchanged: false } }, /hash audit/],
    ['menu-journey-disagreeing-audit', { audit: { finalSourceHashes: {} } }, /hash receipts disagree/],
    ['menu-journey-wrong-seed', { report: { actualSeed: 'atlas-other' } }, /saved seed disagree/]
  ];
  for (const [name, overrides, expected] of cases) {
    const { sourceHashes } = await createContinueSource(project, name, overrides);
    const destination = join(project, `artifacts/citadel-runtime-integration/menu-journey-destination-${name}`);
    await mkdir(destination, { recursive: true });
    await assert.rejects(prepareFixtureContinue(project, destination, `artifacts/citadel-runtime-integration/${name}`, sourceHashes ?? {}), expected);
  }
  const stale = await createContinueSource(project, 'menu-journey-stale');
  await writeFile(join(project, stale.sourcePath), 'mutated after source journey');
  const staleDestination = join(project, 'artifacts/citadel-runtime-integration/menu-journey-destination-stale');
  await mkdir(staleDestination, { recursive: true });
  await assert.rejects(prepareFixtureContinue(project, staleDestination, 'artifacts/citadel-runtime-integration/menu-journey-stale', stale.sourceHashes), /do not match the current workspace/);
});
test('continue preparation fails closed without source parity, clean audit, exact inventory, or save v2', async t => {
  const project = await temporary(t);
  await createContinueSource(project, 'menu-journey-legacy', { omitSourceHashes: true });
  const destination = join(project, 'artifacts/citadel-runtime-integration/menu-journey-destination-legacy');
  await mkdir(destination, { recursive: true });
  await assert.rejects(prepareContinueSave(project, destination, 'artifacts/citadel-runtime-integration/menu-journey-legacy'), /complete recorded source hash inventory/);
  const missingAudit = await createContinueSource(project, 'menu-journey-missing-audit', { audit: false });
  const missingAuditDestination = join(project, 'artifacts/citadel-runtime-integration/menu-journey-destination-missing-audit');
  await mkdir(missingAuditDestination, { recursive: true });
  await assert.rejects(prepareFixtureContinue(project, missingAuditDestination, 'artifacts/citadel-runtime-integration/menu-journey-missing-audit', missingAudit.sourceHashes), /audit is missing/);
  const v1 = await createContinueSource(project, 'menu-journey-invalid-binary', { slotBytes: Buffer.from('invalid') });
  const v1Destination = join(project, 'artifacts/citadel-runtime-integration/menu-journey-destination-v1');
  await mkdir(v1Destination, { recursive: true });
  await assert.rejects(prepareFixtureContinue(project, v1Destination, 'artifacts/citadel-runtime-integration/menu-journey-invalid-binary', v1.sourceHashes), /binary v2 slot/);
  const mismatch = await createContinueSource(project, 'menu-journey-inventory-mismatch');
  const mismatchDestination = join(project, 'artifacts/citadel-runtime-integration/menu-journey-destination-inventory-mismatch');
  await mkdir(mismatchDestination, { recursive: true });
  await assert.rejects(prepareFixtureContinue(project, mismatchDestination, 'artifacts/citadel-runtime-integration/menu-journey-inventory-mismatch', { ...mismatch.sourceHashes, 'new-input.tres': 'a'.repeat(64) }), /exactly match/);
});

test('continue source acceptance is final-only and rejects post-run report, capture, save, verification, and audit mutation', async t => {
  const project = await temporary(t);
  const missing = await createContinueSource(project, 'menu-journey-no-final', { acceptance: false });
  const missingDestination = join(project, 'artifacts/citadel-runtime-integration/menu-journey-destination-no-final');
  await mkdir(missingDestination, { recursive: true });
  await assert.rejects(prepareFixtureContinue(project, missingDestination, 'artifacts/citadel-runtime-integration/menu-journey-no-final', missing.sourceHashes), /final acceptance receipt is missing/);
  for (const mutation of ['report', 'capture', 'save', 'verification', 'audit']) {
    const source = await createContinueSource(project, `menu-journey-mutated-${mutation}`);
    if (mutation === 'report') await writeFile(join(source.source, 'report.json'), '{}');
    if (mutation === 'capture') await writeFile(source.capturePath, 'changed capture');
    if (mutation === 'save') await writeFile(join(source.saveRoot, 'voxel_biome_world_saves_slot_atlas-123.bin'), 'invalid');
    if (mutation === 'verification') await writeFile(join(source.source, 'verification.json'), '{}');
    if (mutation === 'audit') await writeFile(join(source.source, 'source-hash-audit.json'), '{}');
    const destination = join(project, `artifacts/citadel-runtime-integration/menu-journey-destination-mutated-${mutation}`);
    await mkdir(destination, { recursive: true });
    await assert.rejects(prepareFixtureContinue(project, destination,
      `artifacts/citadel-runtime-integration/menu-journey-mutated-${mutation}`, source.sourceHashes),
    /changed after final acceptance|version 2|verification changed|source audit changed/);
  }
});

test('continue provenance rejects a junction component before reading source evidence', async t => {
  const project = await temporary(t);
  const real = await createContinueSource(project, 'menu-journey-real-junction-target');
  const link = join(project, 'artifacts/citadel-runtime-integration/menu-journey-linked-source');
  await symlink(real.source, link, 'junction');
  const destination = join(project, 'artifacts/citadel-runtime-integration/menu-journey-destination-linked');
  await mkdir(destination, { recursive: true });
  await assert.rejects(prepareFixtureContinue(project, destination,
    'artifacts/citadel-runtime-integration/menu-journey-linked-source', real.sourceHashes), /symlink, junction, or reparse/);
});
test('fresh direct artifact directories never overwrite evidence or allow traversal', async t => {
  const project = await temporary(t);
  const relative = 'artifacts/citadel-runtime-integration/candidate-recipe-one';
  const dir = await freshDirectory(project, relative, 'candidate-recipe-');
  await writeFile(join(dir, 'evidence'), 'keep');
  await assert.rejects(freshDirectory(project, relative, 'candidate-recipe-'), /Fresh output/);
  assert.equal(await readFile(join(dir, 'evidence'), 'utf8'), 'keep');
  for (const path of ['../candidate-recipe-escape', 'artifacts/citadel-runtime-integration/nested/candidate-recipe-two', 'artifacts/citadel-runtime-integration/candidate-teleport-two']) await assert.rejects(freshDirectory(project, path, 'candidate-recipe-'));
});
test('actual watcher synthetic five-case regression with repeated unchanged polls', async t => {
  const rows = await runWatcherCases(await temporary(t));
  assert.equal(rows.length, 5); assert.ok(rows.every(row => row.passed));
});
test('recipe allowance is exact, once across logs, and final scan rejects warnings/leaks', async t => {
  const logs = [`  ${expectedError}  \ntrace`, ''];
  for (let i = 0; i < 8; i++) assert.equal(recipeStopReason(logs, expectedError), '');
  assert.match(recipeStopReason([expectedError, expectedError], expectedError), /^Repeated/);
  for (const line of [expectedError.toLowerCase(), expectedError + ' detail', 'WARNING: x', 'Parse Error: x']) assert.equal(recipeStopReason([line], expectedError), line);
  assert.throws(() => validateRecipeErrors([], expectedError, true), /exactly one/);
  assert.throws(() => validateRecipeErrors([expectedError, expectedError], expectedError, true), /exactly one/);
  validateRecipeErrors([expectedError], expectedError, true);
  const dir = await temporary(t), path = join(dir, 'log');
  await writeFile(path, '\uFEFFWARNING: x\nObject leaked\nresources still in use\nbenign\n');
  const errors = await engineErrors([path]);
  assert.equal(errors.length, 3);
  assert.throws(() => validateRecipeErrors(errors, '', false), /Unexpected/);
});
test('teleport watcher detects split error tokens, rejects log shrink, defers warnings to final scan', async t => {
  const dir = await temporary(t);
  for (const scenario of ['split', 'shrink', 'warning']) {
    const stdoutPath = join(dir, scenario + '-out'), stderrPath = join(dir, scenario + '-err'), stopRequestPath = join(dir, scenario + '-stop');
    await writeFile(stdoutPath, scenario === 'split' ? 'SCRIPT ER' : 'a'.repeat(100)); await writeFile(stderrPath, '');
    const watcher = startCandidateWatcher({ stdoutPath, stderrPath, stopRequestPath, kind: 'teleport', intervalMs: 10000 });
    try {
      await watcher.poll();
      if (scenario === 'split') await appendFile(stdoutPath, 'ROR: failure');
      if (scenario === 'shrink') await writeFile(stdoutPath, '');
      if (scenario === 'warning') await appendFile(stdoutPath, 'WARNING: final-only');
      await watcher.poll();
      if (scenario === 'split') assert.match(await readFile(stopRequestPath, 'utf8'), /Immediate owned stop: SCRIPT ERROR:/);
      if (scenario === 'shrink') { assert.equal(watcher.failed, true); assert.match(await readFile(stopRequestPath + '.watcher-error.txt', 'utf8'), /shrank/); }
      if (scenario === 'warning') { assert.equal(watcher.reason, ''); assert.equal((await engineErrors([stdoutPath])).length, 1); }
    } finally { await watcher.stop(); }
  }
});
test('watcher read failure writes independent error and requests owned stop', async t => {
  const dir = await temporary(t), out = join(dir, 'out'); await mkdir(out);
  const stop = join(dir, 'stop');
  const watcher = startCandidateWatcher({ stdoutPath: out, stderrPath: join(dir, 'missing'), stopRequestPath: stop });
  await watcher.stop();
  assert.equal(watcher.failed, true);
  assert.equal(await readFile(stop, 'utf8'), 'watcher failure');
  assert.ok(await readFile(stop + '.watcher-error.txt', 'utf8'));
});
test('owned phase delegates exact args/env and budgets; final scan catches fast exits without process launches', async t => {
  const run = await temporary(t), project = join(run, 'project');
  const env = { SENTINEL: 'unchanged' }, args = ['--headless', '--path', project, '--script', 'fixture', '--check-only'];
  const result = await runCandidatePhase({ project, run, args, env, timeoutSeconds: 15, prefix: 'parse-', kind: 'recipe', runOwnedProcess: async options => {
    assert.equal(options.projectPath, project); assert.deepEqual(options.args, args); assert.equal(options.env, env);
    assert.equal(options.timeoutSeconds, 15); assert.equal(options.finalCleanupTimeoutMilliseconds, 15000);
    await writeFile(options.stdoutPath, 'WARNING: fast exit'); await writeFile(options.stderrPath, '');
    return goodOwned;
  } });
  assert.equal(result.stopRequested, true); assert.equal(result.watcherFailed, false);
  assert.equal(ownedPassed(goodOwned), true);
  for (const field of ['overallExitCode', 'cleanupPassed', 'authoritativeZeroProven']) assert.equal(ownedPassed({ ...goodOwned, [field]: null }), false);
  const teleport = await runCandidatePhase({ project, run, args: ['--path', project], env, timeoutSeconds: 600, kind: 'teleport', runOwnedProcess: async options => {
    assert.equal(options.liveOwnershipPath, join(run, 'live-ownership.json'));
    assert.equal(options.finalCleanupTimeoutMilliseconds, undefined);
    await writeFile(options.stdoutPath, ''); await writeFile(options.stderrPath, ''); return goodOwned;
  } });
  assert.equal(teleport.stopRequested, false);
  await assert.rejects(runCandidatePhase({ project, run, args, env, timeoutSeconds: 15, prefix: 'throw-', kind: 'recipe', runOwnedProcess: async () => { throw new Error('owned launch failed'); } }), /owned launch failed/);
});
test('source SHA256 audit records changed and missing sources without losing remaining hashes', async t => {
  const dir = await temporary(t);
  await writeFile(join(dir, 'same'), 'abc'); await writeFile(join(dir, 'changed'), 'after');
  const hash = await sha256(join(dir, 'same'));
  assert.equal(hash, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  const audit = await auditSources(dir, { same: hash, changed: hash, missing: hash });
  assert.equal(audit.unchanged, false); assert.equal(audit.sourceCount, 3);
  assert.deepEqual(audit.changedSources.map(row => row.path), ['changed']); assert.deepEqual(audit.readErrors.map(row => row.path), ['missing']);
  assert.equal(audit.finalSourceHashes.same, hash);
});
test('hash inventories include all project inputs while excluding runtime artifacts and caches', async t => {
  const dir = await temporary(t);
  execFileSync('git', ['init', dir], { windowsHide: true, stdio: 'ignore' });
  const recipe = 'tools/run-citadel-candidate-recipe-diagnostic.mjs', teleport = 'tools/run-citadel-candidate-teleport-playtest.mjs';
  const files = [recipe, teleport, helperSource, watchdogSource, 'resources/theme.tres', 'assets/model.glb', 'shaders/world.gdshader',
    'scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd', 'scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd', 'scripts/perf/RuntimeRenderObservation.gd', 'addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll', 'scripts/tracked.gd', 'scenes/tracked.tscn', 'project.godot', ...watchdogDependencies];
  files.push('addons/zylann.voxel/bin/libvoxel.windows.template_release.x86_64.dll',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_release.x86_64.dll');
  for (const path of files) { await mkdir(join(dir, path, '..'), { recursive: true }); await writeFile(join(dir, path), path); }
  execFileSync('git', ['-C', dir, 'add', '.'], { windowsHide: true });
  await writeFile(join(dir, 'scripts/untracked.gd'), 'untracked');
  await mkdir(join(dir, 'artifacts/run'), { recursive: true }); await writeFile(join(dir, 'artifacts/run/report.json'), 'runtime');
  const a = await sourceHashes(dir, 'recipe', recipe), b = await sourceHashes(dir, 'teleport', teleport);
  assert.ok(a['scripts/untracked.gd']); assert.ok(b['scripts/untracked.gd']);
  assert.ok(b['scenes/tracked.tscn']); assert.ok(b['project.godot']); assert.ok(b['addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll']);
  for (const file of ['resources/theme.tres', 'assets/model.glb', 'shaders/world.gdshader']) assert.ok(b[file]);
  assert.equal(b['artifacts/run/report.json'], undefined);
  assert.ok(a[recipe]); assert.ok(b[teleport]);
  for (const hashes of [a, b]) {
    assert.ok(hashes[helperSource]); assert.ok(hashes[watchdogSource]);
    for (const file of watchdogDependencies) assert.ok(hashes[file]);
    assert.equal(Object.keys(hashes).some(file => file.endsWith('.ps1')), false);
  }
});

test('runtime manifest freezes the actual Godot engine separately from its console launcher', async t => {
  const project = await temporary(t);
  const bin = join(project, 'godot-bin');
  const consolePath = join(bin, 'Godot_v4.6.1-stable_win64_console.exe');
  const enginePath = join(bin, 'Godot_v4.6.1-stable_win64.exe');
  const addonPaths = [
    'addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll',
    'addons/zylann.voxel/bin/libvoxel.windows.template_release.x86_64.dll',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_release.x86_64.dll',
  ];
  await mkdir(bin, { recursive: true });
  await writeFile(consolePath, 'unchanged launcher');
  await writeFile(enginePath, 'engine version one');
  for (const relativePath of addonPaths) {
    await mkdir(join(project, relativePath, '..'), { recursive: true });
    await writeFile(join(project, relativePath), relativePath);
  }
  assert.equal(godotEngineSiblingPath(consolePath), enginePath);
  const before = await runtimeBinaryManifest(project, consolePath);
  await writeFile(enginePath, 'engine version two');
  const after = await runtimeBinaryManifest(project, consolePath);
  assert.equal(after.godot.sha256, before.godot.sha256);
  assert.notEqual(after.godotEngine.sha256, before.godotEngine.sha256);
  assert.equal(after.godotEngine.path, enginePath);
});
test('all recipe receipts preserve failure vs capture vs independent proof requirements', () => {
  const failure = { diagnosticCompleted: true, expectedFailureReproduced: true, passed: false };
  for (const o of [recipeOptions({ captureFailure: true })]) {
    assert.equal(recipeVerification(o, failure, [], false, '/run').diagnosticVerified, true);
    assert.equal(recipeVerification(o, { ...failure, passed: true }, [], true, '/run').diagnosticVerified, false);
    assert.equal(recipeVerification(o, failure, ['changed'], true, '/run').diagnosticVerified, false);
  }
  const blueprint = { diagnosticCompleted: true, captureCompleted: true, recipePassed: false, passed: false, receipt: { contextUnchanged: true, sourceWithinDeadline: true } };
  const ready = { diagnosticCompleted: true, recipePassed: true, passed: true, receipt: { physicalPassed: true, physicalViolationCount: 0, contextUnchanged: true } };
  for (const [o, report] of [[recipeOptions({ captureBlueprint: true }), blueprint], [recipeOptions({ expectReady: true }), ready]]) {
    assert.equal(recipeVerification(o, report, [], true, '/run').diagnosticVerified, true);
    assert.equal(recipeVerification(o, report, [], false, '/run').diagnosticVerified, false);
    for (const key of Object.keys(report.receipt)) assert.equal(recipeVerification(o, { ...report, receipt: { ...report.receipt, [key]: null } }, [], true, '/run').diagnosticVerified, false);
  }
});
test('teleport validates exact seed, actual seed, successful report and each saved file', async () => {
  const report = { passed: true, seed: 'Atlas', actualSeed: 'Atlas', captures: [{ saved: true, path: '/capture.png' }] };
  await validateTeleportReport(report, 'Atlas', async path => path === '/capture.png');
  for (const override of [{ passed: false }, { seed: 'atlas' }, { actualSeed: 'other' }, { captures: null }, { captures: [{ saved: false, path: '/capture.png' }] }]) await assert.rejects(validateTeleportReport({ ...report, ...override }, 'Atlas', async () => true));
  await assert.rejects(validateTeleportReport(report, 'Atlas', async () => false), /Missing/);
});
test('continue report validation requires restored seed, placement mode, and saved position', async () => {
  const continueSave = { activeSeed: 'atlas-123', playerPosition: [1, 2, 3] };
  const report = { ...menuJourneyReport(true), originalPlayerPosition: [1.1, 2, 3] };
  await validateTeleportReport(report, 'ignored', async () => true, true, continueSave);
  for (const override of [
    { actualSeed: 'atlas-other' },
    { placementMode: 'menu_journey' },
    { originalPlayerPosition: [2.1, 2, 3] },
    { originalPlayerPosition: null }
  ]) await assert.rejects(validateTeleportReport({ ...report, ...override }, 'ignored', async () => true, true, continueSave));
});

test('outer journey validation independently rejects teleport, collision-hold, itinerary, door and godmode claim gaps', () => {
  assert.doesNotThrow(() => validateMenuJourneyEvidence(menuJourneyReport(false)));
  const cases = [
    value => { value.setupPlacements.push({ reason: 'hidden teleport' }); },
    value => { value.evidence.terrainCollisionHolds.frames = 1; },
    value => { value.evidence.playerScaleInspection.stages.find(row => row.stage === 'home_entry').movement.passed = false; },
    value => { value.evidence.playerScaleInspection.stages.find(row => row.stage === 'home_close').interaction.actualOpen = true; },
    value => { value.evidence.tutorialDeparture.opened = false; },
    value => { value.godMode.notAcceptanceFor = ['survival']; },
    value => { value.evidence.renderResolution.window = [1280, 720]; },
  ];
  for (const mutate of cases) {
    const value = structuredClone(menuJourneyReport(false)); mutate(value);
    assert.throws(() => validateMenuJourneyEvidence(value));
  }
  const continued = menuJourneyReport(true);
  assert.doesNotThrow(() => validateMenuJourneyEvidence(continued, { activeSeed: 'atlas-123' }));
});

test('headed journey report explicitly classifies godmode as outside survival and combat acceptance', async () => {
  const source = await readFile(new URL('../../scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd', import.meta.url), 'utf8');
  assert.match(source, /"acceptanceClassification":"streaming_and_physical_journey_diagnostic"/);
  assert.match(source, /"notAcceptanceFor":\["survival","combat"\]/);
  assert.match(source, /menu_journey_no_terrain_collision_holds=terrain_collision_hold_frames==0/);
});

test('mocked recipe orchestration preserves all modes, isolated env, phase order, and final audit on failure', async t => {
  const project = await temporary(t);
  await writeFile(join(project, 'source.gd'), 'frozen');
  const hash = await sha256(join(project, 'source.gd'));
  const environment = { APPDATA: 'original', LOCALAPPDATA: 'original-local', EXTRA: 'preserve' };
  for (const mode of ['default', 'captureFailure', 'captureBlueprint', 'expectReady', 'parseFailure', 'throwFailure', 'missingReport', 'sourceChanged']) {
    const outputDirectory = `artifacts/citadel-runtime-integration/candidate-recipe-${mode}`;
    const run = join(project, outputDirectory);
    const phases = [];
    const readyMode = !['captureFailure', 'captureBlueprint'].includes(mode);
    const input = { outputDirectory, ...(['captureFailure', 'captureBlueprint', 'expectReady'].includes(mode) ? { [mode]: true } : {}) };
    const action = runRecipeDiagnostic(input, {
      projectPath: project, env: environment, sourceHashes: async () => ({ 'source.gd': hash }), git: () => 'synthetic-head\n',
      runOwnedProcess: async options => {
        const parse = options.args.includes('--check-only'); phases.push(parse ? 'parse' : 'run');
        assert.equal(options.env.APPDATA, join(run, 'userdata')); assert.equal(options.env.EXTRA, 'preserve');
        assert.equal(environment.APPDATA, 'original');
        assert.equal(options.env.CITADEL_CANDIDATE_RECIPE_REGION, '0,-1');
        assert.equal(options.env.CITADEL_CANDIDATE_RECIPE_EXPECTED, '1747969299');
        assert.equal(options.env.CITADEL_CANDIDATE_EXPECT_READY, readyMode ? '1' : '0');
        assert.equal(options.env.CITADEL_CANDIDATE_CAPTURE_BLUEPRINT, mode === 'captureBlueprint' ? '1' : '0');
        assert.equal(options.env.CITADEL_CANDIDATE_CAPTURE_FAILURE, mode === 'captureFailure' ? '1' : '0');
        assert.equal(options.finalCleanupTimeoutMilliseconds, 15000);
        if (mode === 'throwFailure') throw new Error('mock watchdog failure');
		await writeFile(options.stdoutPath, '');
        await writeFile(options.stderrPath, '');
        if (mode === 'parseFailure') return { ...goodOwned, overallExitCode: 1 };
        if (!parse) {
          assert.equal(options.timeoutSeconds, 540);
		const report = readyMode ? { diagnosticCompleted: true, recipePassed: true, passed: true, receipt: { physicalPassed: true, physicalViolationCount: 0, contextUnchanged: true } }
            : mode === 'captureBlueprint' ? { diagnosticCompleted: true, captureCompleted: true, recipePassed: false, passed: false, receipt: { contextUnchanged: true, sourceWithinDeadline: true } }
              : { diagnosticCompleted: true, expectedFailureReproduced: true, passed: false };
          if (mode !== 'missingReport') await writeJson(join(run, 'report.json'), report);
			await writeFile(join(run, readyMode ? 'source.bin' : mode === 'captureBlueprint' ? 'caller-blueprint.bin' : 'failure.json'), 'synthetic');
          if (mode === 'sourceChanged') await writeFile(join(project, 'source.gd'), 'changed');
        } else assert.equal(options.timeoutSeconds, 15);
        return goodOwned;
      },
    });
    if (['parseFailure', 'throwFailure', 'missingReport', 'sourceChanged'].includes(mode)) await assert.rejects(action);
		else { const result = await action; assert.equal(result.diagnosticVerified, true); assert.equal(result.recipePassed, ['default', 'expectReady'].includes(mode)); }
    assert.deepEqual(phases, ['parseFailure', 'throwFailure'].includes(mode) ? ['parse'] : ['parse', 'run'], mode);
    const audit = await readJson(join(run, 'source-hash-audit.json'));
    assert.equal(audit.unchanged, mode !== 'sourceChanged'); assert.equal(audit.sourceCount, 1);
    const launch = await readJson(join(run, 'launch.json'));
    assert.equal(launch.maximumOwnedPhasesSeconds, launch.runTimeoutSeconds + 49);
    assert.equal(environment.APPDATA, 'original');
  }
});

test('mocked teleport orchestration preserves headed args, live ownership and verification failures', async t => {
  const project = await temporary(t), environment = { APPDATA: 'original', EXTRA: 'preserve' };
  await writeFile(join(project, 'source.gd'), 'frozen');
  const hash = await sha256(join(project, 'source.gd'));
  for (const mode of ['success', 'cleanup', 'warning', 'missingCapture', 'wrongSeed', 'missingReport', 'sourceChanged', 'sourceAdded', 'binaryChanged']) {
    const outputDirectory = `artifacts/citadel-runtime-integration/candidate-teleport-${mode}`, run = join(project, outputDirectory);
    let binaryManifestCalls = 0;
    let sourceHashCalls = 0;
    const action = runTeleportPlaytest({ outputDirectory, seed: 'Exact-Seed', candidateRegion: '-1,0', timeoutSeconds: 90 }, {
      projectPath: project, env: environment, sourceHashes: async () => ({ 'source.gd': hash,
        ...(mode === 'sourceAdded' && ++sourceHashCalls > 1 ? { 'new-resource.tres': 'd'.repeat(64) } : {}) }), git: () => 'synthetic-head',
      runtimeBinaryManifest: async () => ({
        godot: { path: 'synthetic-console', bytes: 1, sha256: 'a'.repeat(64) },
        godotEngine: { path: 'synthetic-engine', bytes: 2,
          sha256: (mode === 'binaryChanged' && ++binaryManifestCalls > 1 ? 'b' : 'e').repeat(64) },
      }),
      runOwnedProcess: async options => {
        assert.deepEqual(options.args, ['--path', project, '--script', 'res://scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd', '--resolution', '1280x720', '--windowed']);
        assert.equal(options.timeoutSeconds, 210); assert.equal(options.liveOwnershipPath, join(run, 'live-ownership.json'));
        assert.equal(options.env.CITADEL_CANDIDATE_TELEPORT_SECONDS, '90'); assert.equal(options.env.CITADEL_CANDIDATE_TELEPORT_REGION, '-1,0');
        assert.equal(options.env.CITADEL_CANDIDATE_TELEPORT_SEED, 'Exact-Seed'); assert.equal(options.env.APPDATA, join(run, 'userdata'));
        await writeFile(options.stdoutPath, mode === 'warning' ? 'WARNING: unexpected' : ''); await writeFile(options.stderrPath, '');
        const capture = join(run, 'capture.png'); if (mode !== 'missingCapture') await writeFile(capture, 'synthetic');
        if (mode !== 'missingReport') await writeJson(join(run, 'report.json'), { passed: true, seed: 'Exact-Seed', actualSeed: mode === 'wrongSeed' ? 'wrong' : 'Exact-Seed', outcome: 'synthetic', setupPlacements: [{}, {}], captures: [{ saved: true, path: capture }] });
        if (mode === 'sourceChanged') await writeFile(join(project, 'source.gd'), 'changed');
        return { ...goodOwned, rootExited: true, forcedCleanup: false, timedOut: false, functionalExitCode: 0, cleanupPassed: mode !== 'cleanup' };
      },
    });
    if (mode === 'success') { const result = await action; assert.equal(result.passed, true); assert.equal(result.setupPlacements, 2); assert.equal(result.visualInspectionRequired, true); }
    else await assert.rejects(action, undefined, `mode ${mode} must reject`);
    const verification = await readJson(join(run, 'verification.json'));
    assert.equal(verification.visualInspectionRequired, true); assert.equal(verification.naturalExit, true);
    assert.equal(verification.engineErrorWarningCount, mode === 'warning' ? 1 : 0);
    assert.equal(verification.binariesFrozen, mode !== 'binaryChanged');
    if (mode === 'sourceAdded') assert.deepEqual(verification.changedSources, ['new-resource.tres']);
    assert.equal((await readJson(join(run, 'launch.json'))).internalDeadlineSeconds, 45);
    assert.equal(environment.APPDATA, 'original');
    await writeFile(join(project, 'source.gd'), 'frozen');
  }
});

test('menu New Game writes final acceptance only after outer validation and freezes original v2 save bytes', async t => {
  const project = await temporary(t);
  await writeFile(join(project, 'source.gd'), 'source');
  const hash = await sha256(join(project, 'source.gd'));
  for (const valid of [true, false]) {
    const suffix = valid ? 'valid-final' : 'invalid-final';
    const outputDirectory = `artifacts/citadel-runtime-integration/menu-journey-${suffix}`;
    const run = join(project, outputDirectory);
    const action = runTeleportPlaytest({ outputDirectory, menuJourney: true, timeoutSeconds: 90 }, {
      projectPath: project, env: {}, sourceHashes: async () => ({ 'source.gd': hash }), git: () => 'synthetic-head',
      runtimeBinaryManifest: async () => fixtureBinaries(),
      runOwnedProcess: async options => {
        await writeFile(options.stdoutPath, ''); await writeFile(options.stderrPath, '');
        const capture = join(run, 'capture.png'); await writeFile(capture, 'capture bytes');
        const report = menuJourneyReport(false); report.captures = [{ saved: true, path: capture }];
        if (!valid) report.evidence.playerScaleInspection.passed = false;
        await writeJson(join(run, 'report.json'), report);
        const saveRoot = join(run, 'userdata/Godot/app_userdata/Voxel Biome World Godot'); await mkdir(saveRoot, { recursive: true });
        await writeFile(join(saveRoot, 'voxel_biome_world_saves_active_seed.txt'), 'atlas-123\n');
        await writeFile(join(saveRoot, 'voxel_biome_world_saves_slot_atlas-123.bin'), Buffer.concat([Buffer.from('VBW2'), Buffer.from([0, 0, 0, 0])]));
        return { ...goodOwned, rootExited: true, forcedCleanup: false, timedOut: false, functionalExitCode: 0 };
      },
    });
    if (valid) {
      await action;
      const acceptance = await readJson(join(run, 'final-acceptance.json'));
      assert.equal(acceptance.finalized, true); assert.equal(acceptance.save.version, 2);
      assert.equal(acceptance.save.slotSha256, await sha256(join(run, acceptance.save.slotRelativePath)));
    } else {
      await assert.rejects(action, /itinerary completion/);
      await assert.rejects(readFile(join(run, 'final-acceptance.json')));
      const verification = await readJson(join(run, 'verification.json'));
      assert.match(verification.receiptScope, /not reusable source acceptance/);
    }
  }
});

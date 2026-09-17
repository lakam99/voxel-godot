#!/usr/bin/env node
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { projectRoot, parseOptions, recipeOptions, freshDirectory, writeJson, readJson, sourceHashes, auditSources, git, exists, runCandidatePhase, ownedPassed, engineErrors, validateRecipeErrors, cli } from './lib/citadel-candidate-runner.mjs';

const runner = 'tools/run-citadel-candidate-recipe-diagnostic.mjs';
const script = 'res://scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd';
export function recipeVerification(o, report, changed, payloadExists, run) {
  let verified = changed.length === 0 && report.diagnosticCompleted === true && report.expectedFailureReproduced === true && report.passed === false;
	let recipePassed = false, payload = 'failure.json', expectedErrors = [];
  if (o.captureBlueprint) {
    payload = 'caller-blueprint.bin'; expectedErrors = [];
    verified = changed.length === 0 && report.diagnosticCompleted === true && report.captureCompleted === true && report.recipePassed === false && report.passed === false && report.receipt?.contextUnchanged === true && report.receipt?.sourceWithinDeadline === true && payloadExists;
  }
  if (o.expectReady) {
    recipePassed = report.recipePassed === true; payload = 'source.bin'; expectedErrors = [];
    verified = changed.length === 0 && report.diagnosticCompleted === true && recipePassed && report.passed === true && report.receipt?.physicalPassed === true && report.receipt?.physicalViolationCount === 0 && report.receipt?.contextUnchanged === true && payloadExists;
  }
  return { diagnosticVerified: Boolean(verified), recipePassed, expectedErrors, unexpectedErrors: [], changedSources: changed, ownedZero: true, payloadPath: join(run, payload) };
}

export async function runRecipeDiagnostic(input, dependencies = {}) {
  const o = recipeOptions(input), project = dependencies.projectPath ?? projectRoot;
  const run = await freshDirectory(project, o.outputDirectory, 'candidate-recipe-');
  await mkdir(join(run, 'userdata'));
  const hashes = await (dependencies.sourceHashes ?? sourceHashes)(project, 'recipe', runner);
  await writeJson(join(run, 'launch.json'), {
    schema: 'candidate-recipe-diagnostic-launch/v1', sourceHashes: hashes, head: (dependencies.git ?? git)(project, ['rev-parse', 'HEAD']).trim(), seed: o.seed, region: o.region, recipeSeed: o.expectedRecipeSeed,
    expectedError: o.expectedError, runTimeoutSeconds: o.runSeconds, sourcePreparationDeadlineSeconds: o.sourceSeconds, independentPhysicalDeadlineSeconds: o.proofSeconds,
    parseTimeoutSeconds: 15, cleanupCeilingPerPhaseSeconds: 15, maximumOwnedPhasesSeconds: o.runSeconds + 49,
    budgetScope: 'Source clock includes setup/survey and Recipe. CaptureFailure retains an inventoried failure; CaptureBlueprint retains the failed typed Composer caller. Both use the existing 450s source ceiling for measurement only, never recipe success. ExpectReady alone runs independent proof with a fresh 60s deadline after successful in-time Recipe. Export/report bounded by overall watchdog. No production or headed timeout changes.', script,
  });
  const env = { ...(dependencies.env ?? process.env), APPDATA: join(run, 'userdata'), LOCALAPPDATA: join(run, 'userdata'), CITADEL_CANDIDATE_RECIPE_OUTPUT: run,
    CITADEL_CANDIDATE_CAPTURE_BLUEPRINT: o.captureBlueprint ? '1' : '0', CITADEL_CANDIDATE_EXPECT_READY: o.expectReady ? '1' : '0', CITADEL_CANDIDATE_CAPTURE_FAILURE: o.captureFailure ? '1' : '0',
    CITADEL_CANDIDATE_RECIPE_SEED: o.seed, CITADEL_CANDIDATE_RECIPE_REGION: o.candidateRegion, CITADEL_CANDIDATE_RECIPE_EXPECTED: String(o.expectedRecipeSeed) };
  await writeJson(join(run, 'variant.json'), { captureBlueprint: o.captureBlueprint, expectReady: o.expectReady, captureFailure: o.captureFailure,
    sequence: o.captureBlueprint ? 'diagnostic old-equivalent Builder -> Urban.compose_prepared; not public Recipe or success' : 'public CitadelRecipePreparation.prepare' });
  try {
    const runOwnedProcess = dependencies.runOwnedProcess ?? (await import('./run-godot-scene-watchdog.mjs')).runOwnedProcess;
    for (const phase of ['parse', 'run']) {
      const allowed = phase === 'run' ? o.expectedError : '';
      const result = await runCandidatePhase({ project, run, kind: 'recipe', env, runOwnedProcess, allowedLine: allowed,
        prefix: phase === 'parse' ? 'parse-' : '', timeoutSeconds: phase === 'parse' ? 15 : o.runSeconds,
        args: ['--headless', '--path', project, '--script', script, ...(phase === 'parse' ? ['--check-only'] : [])] });
      if (!ownedPassed(result.summary) || result.watcherFailed || result.stopRequested) throw new Error(`${phase} failed; retain ${result.summaryPath} and logs`);
      validateRecipeErrors(await engineErrors([result.stdoutPath, result.stderrPath]), allowed, false);
    }
    const audit = await auditSources(project, hashes);
    const changed = [...audit.changedSources.map(row => row.path), ...audit.readErrors.map(row => row.path)];
    const report = await readJson(join(run, 'report.json'));
    const payload = o.expectReady ? 'source.bin' : o.captureBlueprint ? 'caller-blueprint.bin' : 'failure.json';
    const verification = recipeVerification(o, report, changed, await exists(join(run, payload)), run);
    await writeJson(join(run, 'verification.json'), verification);
    if (!verification.diagnosticVerified) throw new Error('Diagnostic identity or expected failure mismatch.');
    return { diagnosticVerified: true, recipePassed: verification.recipePassed, reportPath: join(run, 'report.json'), payloadPath: verification.payloadPath, ownedZero: true };
  } finally {
    await writeJson(join(run, 'source-hash-audit.json'), { schema: 'candidate-recipe-final-source-audit/v1', observedAtUtc: new Date().toISOString(), launchPath: join(run, 'launch.json'),
      ...await auditSources(project, hashes), scope: 'Source identity only; independent of recipe, watchdog, and cleanup pass/failure.' });
  }
}
await cli(import.meta.url, argv => runRecipeDiagnostic(parseOptions(argv, 'recipe')));

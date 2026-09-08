#!/usr/bin/env node
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { projectRoot, parseOptions, teleportOptions, freshDirectory, writeJson, readJson, sourceHashes, auditSources, git, exists, isFile, runCandidatePhase, ownedPassed, engineErrors, cli } from './lib/citadel-candidate-runner.mjs';

const runner = 'tools/run-citadel-candidate-teleport-playtest.mjs';
const script = 'res://scripts/testing/buildings/CitadelCandidateTeleportPlaytest.gd';
export async function validateTeleportReport(report, seed, captureExists = isFile) {
  if (!report || report.passed !== true || report.seed !== seed || report.actualSeed !== seed) throw new Error('No successful exact-seed diagnostic report.');
  if (!Array.isArray(report.captures)) throw new Error('Missing reported viewport captures.');
  for (const capture of report.captures) if (capture.saved !== true || typeof capture.path !== 'string' || !(await captureExists(capture.path))) throw new Error('Missing reported viewport capture.');
}
export async function runTeleportPlaytest(input, dependencies = {}) {
  const inheritedEnv = dependencies.env ?? process.env;
  const o = teleportOptions(input, inheritedEnv), project = dependencies.projectPath ?? projectRoot;
  const run = await freshDirectory(project, o.outputDirectory, 'candidate-teleport-');
  await mkdir(join(run, 'userdata'));
  const hashes = await (dependencies.sourceHashes ?? sourceHashes)(project, 'teleport', runner);
  const args = [script, '--resolution', '1280x720', '--windowed', ...(o.gameArguments.length ? ['--', ...o.gameArguments] : [])];
  await writeJson(join(run, 'launch.json'), { schema: 'citadel-candidate-teleport-launch/v1', projectPath: project, head: (dependencies.git ?? git)(project, ['rev-parse', 'HEAD']).trim(), seed: o.seed, requestedRegion: o.candidateRegion,
    timeoutSeconds: o.overallTimeoutSeconds, startupTimeoutSeconds: o.startupTimeoutSeconds, testTimeoutSeconds: o.timeoutSeconds, internalDeadlineSeconds: o.timeoutSeconds - 45, launchOptions: o.launchOptions, headed: true, scene: script, arguments: args, sourceHashes: hashes, recordedUtc: new Date().toISOString(),
    evidenceLevel: 'headed teleport-assisted diagnostic; not continuous travel or NPC acceptance', fixtureChanges: ['seed-selector-only Main subclass', 'two counted exterior setup teleports', 'physics held only for setup clearance', 'isolated ordinary user data', 'labelled diagnostic camera views after ordinary player approach'] });
  const env = { ...inheritedEnv, APPDATA: join(run, 'userdata'), LOCALAPPDATA: join(run, 'userdata'), CITADEL_CANDIDATE_TELEPORT_OUTPUT: run, CITADEL_CANDIDATE_TELEPORT_SEED: o.seed,
    CITADEL_CANDIDATE_TELEPORT_SECONDS: String(o.timeoutSeconds), CITADEL_CANDIDATE_STARTUP_SECONDS: String(o.startupTimeoutSeconds), CITADEL_CANDIDATE_TELEPORT_REGION: o.candidateRegion };
  const runOwnedProcess = dependencies.runOwnedProcess ?? (await import('./run-godot-scene-watchdog.mjs')).runOwnedProcess;
  const result = await runCandidatePhase({ project, run, kind: 'teleport', env, runOwnedProcess, timeoutSeconds: o.overallTimeoutSeconds, args: ['--path', project, '--script', ...args] });
  const watch = result.summary;
  const audit = await auditSources(project, hashes);
  const changed = [...audit.changedSources.map(row => row.path), ...audit.readErrors.map(row => row.path)];
  const errors = await engineErrors([result.stdoutPath, result.stderrPath]);
  const reportPath = join(run, 'report.json');
  const report = await exists(reportPath) ? await readJson(reportPath) : null;
  const verification = { naturalExit: watch.rootExited === true && !watch.forcedCleanup && !watch.timedOut, functionalExitCode: watch.functionalExitCode, ownedZero: watch.authoritativeZeroProven,
    cleanupPassed: watch.cleanupPassed, engineErrorWarningCount: errors.length, changedSources: changed, reportPath, watcherFailed: result.watcherFailed, visualInspectionRequired: true };
  await writeJson(join(run, 'verification.json'), verification);
  if (!ownedPassed(watch)) throw new Error('Diagnostic failed or owned cleanup unresolved; retain report/log/watchdog evidence.');
  if (verification.watcherFailed || result.stopRequested || errors.length || changed.length) throw new Error('Watcher, engine log, or frozen-source verification failed.');
  await validateTeleportReport(report, o.seed);
  if (o.gameArguments.length && Object.entries(o.launchOptions).some(([key, value]) => report.launchOptions?.[key] !== value)) throw new Error('Game launch options did not match requested options.');
  return { passed: true, outcome: report.outcome, setupPlacements: Array.isArray(report.setupPlacements) ? report.setupPlacements.length : report.setupPlacements == null ? 0 : 1, reportPath, ownedZero: true, visualInspectionRequired: true };
}
await cli(import.meta.url, argv => runTeleportPlaytest(parseOptions(argv, 'teleport')));

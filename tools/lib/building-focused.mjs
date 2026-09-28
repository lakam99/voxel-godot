import fs from 'node:fs';
import path from 'node:path';
import { specs } from './building-contract-specs.mjs';
import { options, choice, integer, context, prepare, launchRecord, stable, phaseRun, read, write, sha, uid, demand, assertReport, assertNoGodot, engineErrors } from './building-runner.mjs';

export async function runFocused(name, argv, runOwnedProcess) {
  const spec = specs[name];
  const defaults = { outputdirectory: '', godotexe: '', projectpath: '' };
  if (name === 'building-scene-publication-contract') defaults.phase = 'actual';
  if (name === 'citadel-structural-composer-contract') defaults.seed = 208159;
  if (name === 'citadel-site-build-queue-contract') defaults.outputdirectory = 'artifacts/citadel-runtime-integration/site-build-queue-contract-01';
  const o = options(argv, defaults);
  const c = context(o, spec.prefix);
  const files = [...spec.files];
  const env = { [spec.reportEnvironment]: spec.outputIsDirectory ? c.run : path.join(c.run, 'report.json') };
  const metadata = { schema: spec.launchSchema, evidenceLevel: spec.evidenceLevel, timeoutSeconds: spec.timeout };
  let timeout = spec.timeout;
  if (name === 'building-scene-publication-contract') {
    o.phase = choice(o.phase, ['facade', 'actual'], 'Phase');
    env.BUILDING_SCENE_PHASE = o.phase;
    timeout = o.phase === 'actual' ? 240 : 30;
    Object.assign(metadata, { phase: o.phase, seed: 'atlas-1492', headed: false, timeoutSeconds: timeout });
    if (o.phase === 'facade') files.splice(files.indexOf('scripts/buildings/BuildingScenePublicationJob.gd'), 1);
  }
  if (name === 'citadel-structural-composer-contract') {
    env.VOXEL_STRUCTURAL_COMPOSER_SEED = String(integer(o.seed, -2147483648, 2147483647, 'Seed'));
    env.VOXEL_STRUCTURAL_COMPOSER_PROGRESS = path.join(c.run, 'progress.jsonl');
  }
  if (['citadel-publication-service-contract', 'citadel-site-build-queue-contract'].includes(name)) metadata.seed = 'atlas-1492';
  if (['citadel-profile-snapshot-contract', 'citadel-publication-preflight'].includes(name)) {
    const fixture = path.join(c.project, 'artifacts/citadel-runtime-integration/actual-site-source-05/result.bin');
    metadata.fixtureSha256 = '7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf';
    demand(sha(fixture) === metadata.fixtureSha256, 'Actual Site fixture SHA mismatch');
    files.push(fixture);
  }
  if (name === 'citadel-site-selection-contract') {
    metadata.randomSeed = 'atlas-site-' + uid();
    metadata.fixedSeed = 'atlas-1492';
    metadata.densitySecondarySeed = metadata.randomSeed + ':density-secondary';
    env.VOXEL_CITADEL_SITE_SEED = metadata.randomSeed;
  }
  if (spec.emptyStderr) assertNoGodot();
  prepare(c, spec.isolate, spec.save);
  const before = launchRecord(c, files, metadata);
  let w, report, failure;
  try {
    w = await phaseRun(c, { args: ['--headless', '--script', spec.script], env, timeout, membership: spec.membership, logPolicy: { emptyStderr: spec.emptyStderr, ...(name === 'prepared-tree-publication-contract' ? { pattern: engineErrors } : {}) } }, runOwnedProcess);
    stable(c.project, before);
    if (spec.emptyStderr) assertNoGodot();
    report = read(path.join(c.run, 'report.json'));
    assertReport(report, { ...(spec.passed ? { passed: true } : {}), ...(spec.complete ? { complete: true } : {}), ...(spec.reportSchema ? { schema: spec.reportSchema } : {}) });
    if (spec.membership) {
      assertReport(report, { evidenceLevel: spec.evidenceLevel, failures: [] });
      const timingField = name === 'citadel-site-selection-contract' ? 'elapsedUsec' : 'maxPollUsec';
      demand(Object.hasOwn(report, timingField) && typeof report[timingField] === 'number' && Number.isFinite(report[timingField]) && report[timingField] >= 0, 'Missing or invalid report field: ' + timingField);
      if (name === 'citadel-site-selection-contract') {
        assertReport(report, { seeds: [metadata.fixedSeed, metadata.randomSeed, metadata.densitySecondarySeed] });
        demand(Array.isArray(report.density) && report.density.length === 3, 'Expected three density results');
      }
    }
  } catch (error) { failure = error; }
  if (name === 'citadel-profile-snapshot-contract') {
    // Persist the diagnostic summary even when the runner/report fails.
    let sourceStable = true;
    try { stable(c.project, before); } catch { sourceStable = false; }
    if (!w && fs.existsSync(path.join(c.run, 'watchdog.json'))) w = read(path.join(c.run, 'watchdog.json'));
    if (!report && fs.existsSync(path.join(c.run, 'report.json'))) report = read(path.join(c.run, 'report.json'));
    const errorWarningLines = ['stdout.log', 'stderr.log'].flatMap(n => fs.existsSync(path.join(c.run, n)) ? fs.readFileSync(path.join(c.run, n), 'utf8').split(/\r?\n/).filter(l => /SCRIPT ERROR:|Parse Error:|ERROR:|WARNING:|leaked|resources still in use/i.test(l)) : []).length;
    write(path.join(c.run, 'summary.json'), { exitCode: w?.overallExitCode ?? 1, sourceStable, errorWarningLines, cleanupPassed: w?.cleanupPassed ?? false, authoritativeZeroProven: w?.authoritativeZeroProven ?? false, forcedCleanup: w?.forcedCleanup, timedOut: w?.timedOut, passed: report?.passed === true, checks: Object.keys(report?.checks ?? {}).length, failure: failure?.message });
  }
  if (failure) throw failure;
  return { passed: spec.passed ? true : undefined, reportPath: path.join(c.run, 'report.json'), checks: Object.keys(report?.checks ?? {}).length, cleanupPassed: w.cleanupPassed, mainBeginUsec: report.mainBeginUsec, restoreUsec: report.actualRestoreUsec, maxPollUsec: report.maxPollUsec, randomSeed: metadata.randomSeed, evidenceLevel: spec.evidenceLevel };
}

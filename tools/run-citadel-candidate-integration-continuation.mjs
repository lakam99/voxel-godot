import path from 'node:path';
import fs from 'node:fs';
import { cli, options, projectDefault, inside, read, sha, demand, assertWatchdog, hashes, write, godotDefault } from './lib/building-runner.mjs';
import { runSpecial } from './lib/building-special.mjs';
import { continuationSources, auditContinuationSources, auditContinuationInventory, assertContinuationOrigin } from './lib/candidate-continuation-evidence.mjs';

// Offline artifact continuation only. No source artifact is installed in game.
if (process.argv.slice(2).some(arg => ['--help', '-Help', '-h'].includes(arg))) {
  console.log('Usage: node tools/run-citadel-candidate-integration-continuation.mjs -SourceDirectory <passed candidate-recipe directory> -OutputDirectory <fresh integration directory>\nOffline exact-artifact continuation; no recipe rebuild or runtime injection. Restore/terrain/publication phase ceilings: 30/60/60 seconds; owned watchdog: 170 seconds.');
} else await cli(async () => {
  const o = options(process.argv.slice(2), { sourcedirectory: '', outputdirectory: '' });
  demand(o.sourcedirectory && o.outputdirectory, 'SourceDirectory and fresh OutputDirectory are required.');
  const output = path.resolve(projectDefault, o.outputdirectory);
  demand(inside(path.join(projectDefault, 'artifacts/citadel-runtime-integration'), output) && !fs.existsSync(output), 'Fresh integration output required.');
  const directory = path.resolve(projectDefault, o.sourcedirectory);
  demand(inside(path.join(projectDefault, 'artifacts/citadel-runtime-integration'), directory), 'SourceDirectory must be an integration artifact directory.');
  const report = read(path.join(directory, 'report.json'));
  const verification = read(path.join(directory, 'verification.json'));
  const originLaunch = read(path.join(directory, 'launch.json'));
  const originAudit = read(path.join(directory, 'source-hash-audit.json'));
  const originWatchdog = read(path.join(directory, 'watchdog.json'));
  assertWatchdog(originWatchdog, true);
  const expectedScript = 'res://scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd';
  demand(originLaunch.script === expectedScript && Array.isArray(originLaunch.region) &&
    report.region === `(${originLaunch.region.join(', ')})` &&
    JSON.stringify(originWatchdog.args) === JSON.stringify(['--headless', '--path', projectDefault, '--script', expectedScript]) &&
    path.resolve(originWatchdog.executable) === path.resolve(godotDefault), 'Origin region, script or executable mismatch.');
  demand(report.schema === 'citadel-candidate-recipe-diagnostic/v1' && report.passed === true && report.recipePassed === true &&
    report.receipt?.physicalPassed === true && report.receipt.physicalViolationCount === 0 &&
    report.receipt.contextUnchanged === true && report.receipt.sourceWithinDeadline === true &&
    Number.isSafeInteger(report.receipt.partCount) && report.receipt.partCount > 0 &&
    report.receipt.physicalCheckedPartCount === report.receipt.partCount &&
    verification.diagnosticVerified === true && verification.recipePassed === true && verification.ownedZero === true &&
    Array.isArray(verification.changedSources) && verification.changedSources.length === 0,
  'Require a successful public candidate Recipe and independent physical proof.');
  const source = path.join(directory, 'source.bin'), input = path.join(directory, 'input.bin');
  demand(path.resolve(verification.payloadPath ?? '') === source && path.resolve(originAudit.launchPath ?? '') === path.join(directory, 'launch.json') &&
    path.resolve(originWatchdog.summaryPath ?? '') === path.join(directory, 'watchdog.json') &&
    path.resolve(originWatchdog.projectPath ?? '') === projectDefault &&
    originLaunch.seed === report.worldSeed && originLaunch.recipeSeed === report.recipeSeed &&
    originAudit.unchanged === true && Array.isArray(originAudit.changedSources) && !originAudit.changedSources.length &&
    Array.isArray(originAudit.readErrors) && !originAudit.readErrors.length &&
    JSON.stringify(originLaunch.sourceHashes) === JSON.stringify(originAudit.finalSourceHashes), 'Origin launch, verification, watchdog and source audit do not agree.');
  const sourceSha = report.receipt.sourceSha256, inputSha = report.receipt.inputSha256;
  demand(/^[a-f0-9]{64}$/.test(sourceSha) && /^[a-f0-9]{64}$/.test(inputSha) && sha(source) === sourceSha && sha(input) === inputSha, 'Pinned candidate artifact mismatch.');
  const fields = { CITADEL_CONTINUATION_SOURCE: source, CITADEL_CONTINUATION_SOURCE_SHA: sourceSha,
    CITADEL_CONTINUATION_INPUT: input, CITADEL_CONTINUATION_INPUT_SHA: inputSha };
  const originFiles = ['source.bin', 'input.bin', 'report.json', 'verification.json', 'watchdog.json', 'launch.json', 'source-hash-audit.json'].map(file => path.join(directory, file));
  const production = continuationSources(projectDefault);
  const before = { ...production, ...hashes(projectDefault, originFiles) };
  const origin = { directory, source, input, sourceSha256: sourceSha, inputSha256: inputSha,
    reportSha256: sha(path.join(directory, 'report.json')), launchSha256: sha(path.join(directory, 'launch.json')) };
  const receipt = { schema: 'citadel-candidate-continuation-evidence/v1', origin, injectedEnvironment: fields, outputDirectory: output, sourceSha256: before, startedUtc: new Date().toISOString() };
  const evidenceDirectory = output + '-evidence';
  demand(!fs.existsSync(evidenceDirectory), 'Fresh continuation evidence directory required.');
  fs.mkdirSync(evidenceDirectory);
  write(path.join(evidenceDirectory, 'before.json'), receipt);
  const previous = Object.fromEntries(Object.keys(fields).map(key => [key, process.env[key]]));
  let outcome, failure;
  try {
    Object.assign(process.env, fields);
    outcome = await runSpecial('building-contract', ['-Contract', 'CitadelCandidateIntegrationContinuation.gd',
      '-OutputDirectory', o.outputdirectory, '-ReportEnvironment', 'CITADEL_CANDIDATE_CONTINUATION_REPORT', '-TimeoutSeconds', '170']);
    demand(outcome.reportPath === path.join(output, 'report.json'), 'Unexpected continuation report path.');
    const watch = read(path.join(output, 'watchdog.json'));
    assertWatchdog(watch, true);
    demand(path.resolve(watch.projectPath) === projectDefault && path.resolve(watch.executable) === path.resolve(godotDefault) &&
      path.resolve(watch.summaryPath) === path.join(output, 'watchdog.json') &&
      JSON.stringify(watch.args) === JSON.stringify(['--path', projectDefault, '--headless', '--script', 'res://scripts/testing/buildings/CitadelCandidateIntegrationContinuation.gd']), 'Continuation launch identity mismatch.');
    assertContinuationOrigin(read(outcome.reportPath), source, input, sourceSha, inputSha);
  } catch (error) {
    failure = error;
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    const audit = auditContinuationSources(projectDefault, before);
    const inventory = auditContinuationInventory(projectDefault, production);
    const reportPath = path.join(output, 'report.json');
    const artifactHashes = {}, artifactReadErrors = [], errors = failure ? [failure] : [];
    for (const file of ['report.json', 'launch.json', 'parse-watchdog.json', 'watchdog.json']) {
      try { const target = path.join(output, file); artifactHashes[file] = fs.existsSync(target) ? sha(target) : null; }
      catch (error) { artifactReadErrors.push({ file, error: error.message }); errors.push(error); }
    }
    if (!audit.unchanged || !inventory.unchanged) errors.push(new Error('Continuation source/origin audit failed; inspect ' + evidenceDirectory));
    try { write(path.join(evidenceDirectory, 'after.json'), { ...receipt,
      completedUtc: new Date().toISOString(), audit, inventory, passed: !failure && audit.unchanged && inventory.unchanged,
      failure: failure?.message ?? null, reportPath, artifactHashes, artifactReadErrors }); }
    catch (error) { errors.push(error); }
    if (errors.length) throw new AggregateError(errors, errors.map(error => error.message).join('; '));
  }
  if (failure) throw failure;
  return outcome;
});

import fs from 'node:fs';
import path from 'node:path';
import { cli, options, projectDefault, inside, demand, hashes, write, context, prepare, launchRecord, phaseRun, read, assertReport, assertNoGodot } from './lib/building-runner.mjs';
import { continuationSources, auditContinuationSources, auditContinuationInventory } from './lib/candidate-continuation-evidence.mjs';
cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '' });
  demand(o.outputdirectory, 'OutputDirectory required');
  const output = path.resolve(projectDefault, o.outputdirectory), generated = output + '-source';
  demand(inside(path.join(projectDefault, 'artifacts/citadel-runtime-integration'), output) && !fs.existsSync(output) && !fs.existsSync(generated), 'Fresh integration directory required');
  const source = fs.readFileSync(path.join(projectDefault, 'scripts/buildings/CitadelStructuralCompletionRecipe.gd'), 'utf8').replaceAll('\r\n', '\n');
  const dependency = 'preload("res://scripts/buildings/CitadelBuntingAnchorRecipe.gd")';
  demand(source.split(dependency).length === 2, 'Exact interception point required');
  fs.mkdirSync(generated);
  const mirror = path.join(generated, 'Structural.gd');
  fs.writeFileSync(mirror, source.replace(dependency, 'preload("res://scripts/testing/buildings/CitadelBuntingStageCaptureStub.gd")'));
  const production = continuationSources(projectDefault);
  const before = { ...production, ...hashes(projectDefault, [mirror, 'artifacts/citadel-runtime-integration/candidate21-policy-capture-01/input.bin']) };
  write(path.join(generated, 'evidence-before.json'), { output, sourceSha256: before, startedUtc: new Date().toISOString() });
  const c = context(o, 'candidate22-bunting-');
  const script = 'res://scripts/testing/buildings/CitadelBuntingStageCapture.gd';
  const reportPath = path.join(output, 'report.json');
  const env = { CITADEL_BUNTING_CAPTURE_MIRROR: 'res://' + path.relative(projectDefault, mirror).replaceAll('\\', '/'), CITADEL_ORDERED_OPENING_REPORT: reportPath };
  let result;
  const errors = [];
  try {
    assertNoGodot();
    prepare(c);
    launchRecord(c, Object.keys(before), { schema: 'citadel-bunting-stage-capture/v1', script, env, timeoutSeconds: 330, phaseSeconds: 300 });
    const args = ['--headless', '--script', script];
    await phaseRun(c, { args: [...args, '--check-only'], env, timeout: 30, prefix: 'parse-', membership: true });
    await phaseRun(c, { args, env, timeout: 330, membership: true });
    const report = read(reportPath);
    assertReport(report, { passed: true });
    assertNoGodot();
    result = { reportPath, ownedZero: true, checks: report.checks, captureSha256: report.captureSha256 };
  } catch (error) { errors.push(error); }
  finally {
    const audit = auditContinuationSources(projectDefault, before);
    const inventory = auditContinuationInventory(projectDefault, production);
    if (!audit.unchanged || !inventory.unchanged) errors.push(new Error('Capture source audit failed'));
    try { write(path.join(generated, 'evidence-after.json'), { passed: errors.length === 0, output, audit, inventory, errors: errors.map(e => e.message), completedUtc: new Date().toISOString() }); }
    catch (error) { errors.push(error); }
  }
  if (errors.length) throw new AggregateError(errors, errors.map(e => e.message).join('; '));
  return result;
});

import fs from 'node:fs';
import path from 'node:path';
import { cli, options, projectDefault, inside, demand, hashes, read, sha, write, assertReport, assertWatchdog } from './lib/building-runner.mjs';
import { runSpecial } from './lib/building-special.mjs';
import { continuationSources, auditContinuationSources, auditContinuationInventory } from './lib/candidate-continuation-evidence.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { capturedirectory: '', outputdirectory: '' });
  demand(o.capturedirectory && o.outputdirectory, 'CaptureDirectory and OutputDirectory required');
  const integration = path.join(projectDefault, 'artifacts/citadel-runtime-integration');
  const capture = fs.realpathSync(path.resolve(projectDefault, o.capturedirectory));
  demand(inside(integration, capture), 'Capture must be inside the project integration artifacts');
  const input = path.join(capture, 'input.bin'), captureSource = capture + '-source';
  const originPaths = [path.join(capture, 'report.json'), path.join(capture, 'watchdog.json'), path.join(capture, 'parse-watchdog.json'),
    path.join(captureSource, 'evidence-before.json'), path.join(captureSource, 'evidence-after.json')];
  const [originReport, watchdog, parseWatchdog, originBefore, originAfter] = originPaths.map(read);
  assertReport(originReport, { passed: true, inputSha256: 'e46c25ba500c1c072f14ed72f8ad3ef5d6952d5443e687737f44e1d054e8d159' });
  demand(Object.keys(originReport.checks ?? {}).length > 0 && Object.values(originReport.checks).every(value => value === true), 'Capture checks are incomplete');
  assertWatchdog(watchdog); assertWatchdog(parseWatchdog);
  demand(originAfter.passed === true && originAfter.audit?.unchanged === true && originAfter.inventory?.unchanged === true, 'Capture source freeze failed');
  demand(fs.statSync(input).isFile() && fs.statSync(input).size > 0 && fs.statSync(input).size <= 64 * 1024 * 1024, 'Invalid captured input size');
  const inputSha256 = sha(input);
  demand(inputSha256 === originReport.captureSha256, 'Captured input SHA256 mismatch');
  const expectedOriginMirror = path.join(captureSource, 'Composer.gd');
  demand(path.resolve(projectDefault, String(originBefore.mirrorPath).replace(/^res:\/\//, '')) === expectedOriginMirror &&
    path.resolve(originBefore.output) === capture && originBefore.inputSha256 === originReport.inputSha256, 'Capture origin binding mismatch');
  const originAudit = auditContinuationSources(projectDefault, originBefore.sourceSha256);
  demand(originAudit.unchanged, 'Sources changed since acquisition; capture is not an unchanged baseline');
  const originProduction = { ...originBefore.sourceSha256 };
  for (const file of [expectedOriginMirror, path.join(captureSource, '.gdignore'), originBefore.inputPath]) delete originProduction[file];
  demand(auditContinuationInventory(projectDefault, originProduction).unchanged, 'Source inventory changed since acquisition');

  const output = path.resolve(projectDefault, o.outputdirectory), generated = output + '-source';
  demand(inside(integration, output) && !fs.existsSync(output) && !fs.existsSync(generated), 'Fresh integration output required');
  let mirrorText = fs.readFileSync(path.join(projectDefault, 'scripts/buildings/CitadelFacadeCompletionRecipe.gd'), 'utf8').replaceAll('\r\n', '\n');
  const shim = 'preload("res://scripts/testing/buildings/CitadelFacadePhaseReplayCapture.gd")';
  for (const source of ['OpeningHeadBandRecipe', 'LowerFacadeBearingRecipe']) {
    const dependency = `preload("res://scripts/buildings/${source}.gd")`;
    demand(mirrorText.split(dependency).length === 2, 'Exact facade interception point required: ' + source);
    mirrorText = mirrorText.replace(dependency, shim);
  }
  fs.mkdirSync(generated);
  const mirror = path.join(generated, 'Facade.gd'), ignored = path.join(generated, '.gdignore');
  fs.writeFileSync(ignored, ''); fs.writeFileSync(mirror, mirrorText);
  const production = continuationSources(projectDefault);
  demand(Object.keys(production).length === Object.keys(originProduction).length &&
    Object.entries(production).every(([file, hash]) => originProduction[file] === hash), 'Sources changed while preparing the phase mirror');
  const before = { ...production, ...hashes(projectDefault, [mirror, ignored, input, ...originPaths]) };
  demand(before[input] === inputSha256, 'Captured input changed before replay freeze');
  const replayEnv = {
    CITADEL_FACADE_PHASE_INPUT: 'res://' + path.relative(projectDefault, input).replaceAll('\\', '/'),
    CITADEL_FACADE_PHASE_INPUT_SHA256: inputSha256,
    CITADEL_FACADE_PHASE_MIRROR: 'res://' + path.relative(projectDefault, mirror).replaceAll('\\', '/'),
  };
  write(path.join(generated, 'evidence-before.json'), { output, inputPath: input, inputSha256, captureDirectory: capture,
    transformation: 'Normalize CRLF; redirect exactly the opening and lower facade preloads to a pass-through capture shim.',
    sourceSha256: before, startedUtc: new Date().toISOString() });
  const previous = Object.fromEntries(Object.keys(replayEnv).map(key => [key, process.env[key]]));
  Object.assign(process.env, replayEnv);
  let result, failure;
  try {
    result = await runSpecial('building-contract', ['-Contract', 'CitadelFacadePhaseReplay.gd', '-OutputDirectory', o.outputdirectory,
      '-ReportEnvironment', 'CITADEL_FACADE_PHASE_REPORT', '-TimeoutSeconds', '110']);
    const report = read(path.join(output, 'report.json'));
    assertReport(report, { passed: true, complete: true, inputSha256 });
    demand(Object.keys(report.checks ?? {}).length > 0 && Object.values(report.checks).every(value => value === true), 'Phase replay checks failed');
    const artifactNames = ['opening-input.bin', 'opening-expected.bin', 'lower-input.bin', 'lower-expected.bin',
      'facade-expected.bin', 'opening-physical.bin', 'lower-physical.bin'];
    demand(Object.keys(report.artifactSha256 ?? {}).length === artifactNames.length &&
      artifactNames.every(name => /^[a-f0-9]{64}$/.test(report.artifactSha256[name] ?? '')), 'Incomplete phase artifact inventory');
    for (const name of artifactNames) demand(sha(path.join(output, name)) === report.artifactSha256[name], 'Replay artifact hash mismatch: ' + name);
  } catch (error) { failure = error; }
  finally {
    for (const [key, value] of Object.entries(previous)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
    const audit = auditContinuationSources(projectDefault, before), inventory = auditContinuationInventory(projectDefault, production);
    write(path.join(generated, 'evidence-after.json'), { passed: !failure && audit.unchanged && inventory.unchanged, output, inputPath: input,
      inputSha256, failure: failure?.message ?? null, audit, inventory, completedUtc: new Date().toISOString() });
    if (!audit.unchanged || !inventory.unchanged) throw new AggregateError([...(failure ? [failure] : []), new Error('Phase replay source audit failed')]);
  }
  if (failure) throw failure;
  return result;
});

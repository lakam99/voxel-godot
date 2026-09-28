import fs from 'node:fs';
import path from 'node:path';
import { cli, options, projectDefault, inside, demand, hashes, read, sha, write, assertReport, assertWatchdog } from './lib/building-runner.mjs';
import { runSpecial } from './lib/building-special.mjs';
import { continuationSources, auditContinuationSources, auditContinuationInventory } from './lib/candidate-continuation-evidence.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { baselinedirectory: '', outputdirectory: '' });
  demand(o.baselinedirectory && o.outputdirectory, 'BaselineDirectory and OutputDirectory required');
  const integration = path.join(projectDefault, 'artifacts/citadel-runtime-integration');
  const baseline = fs.realpathSync(path.resolve(projectDefault, o.baselinedirectory));
  demand(inside(integration, baseline), 'Baseline must be inside project integration artifacts');
  const originPaths = ['report.json', 'watchdog.json', 'parse-watchdog.json'].map(name => path.join(baseline, name));
  originPaths.push(path.join(baseline + '-source', 'evidence-before.json'), path.join(baseline + '-source', 'evidence-after.json'));
  const [report, watchdog, parseWatchdog, originBefore, originAfter] = originPaths.map(read);
  assertReport(report, { passed: true, complete: true, inputSha256: '2aa1de5303ea96fdad744a14e17ee5ac6b6a3bbd57f3698ce5dee11cfd0fadbb' });
  assertWatchdog(watchdog); assertWatchdog(parseWatchdog);
  demand(Object.keys(report.checks ?? {}).length > 0 && Object.values(report.checks).every(value => value === true), 'Incomplete baseline checks');
  demand(originAfter.passed === true && originAfter.audit?.unchanged === true && originAfter.inventory?.unchanged === true, 'Baseline source freeze failed');
  const names = ['opening-input.bin', 'opening-expected.bin', 'lower-input.bin', 'lower-expected.bin',
    'facade-expected.bin', 'opening-physical.bin', 'lower-physical.bin'];
  demand(Object.keys(report.artifactSha256 ?? {}).length === names.length, 'Incomplete baseline artifact inventory');
  for (const name of names) demand(/^[a-f0-9]{64}$/.test(report.artifactSha256[name] ?? '') &&
    sha(path.join(baseline, name)) === report.artifactSha256[name], 'Baseline artifact mismatch: ' + name);
  for (const [file, expected] of Object.entries(originBefore.sourceSha256)) {
    if (/\.(dll|gdextension|exe)$/i.test(file)) demand(sha(path.resolve(projectDefault, file)) === expected, 'Baseline engine/native binary changed: ' + file);
  }
  const output = path.resolve(projectDefault, o.outputdirectory);
  demand(path.dirname(output) === integration && !fs.existsSync(output), 'Fresh direct integration output required');
  const production = continuationSources(projectDefault);
  const before = { ...production, ...hashes(projectDefault, [...originPaths, ...names.map(name => path.join(baseline, name))]) };
  const env = {
    CITADEL_FACADE_PARITY_BASELINE: 'res://' + path.relative(projectDefault, baseline).replaceAll('\\', '/'),
    CITADEL_FACADE_PARITY_BINDINGS: JSON.stringify(report.artifactSha256),
  };
  const previous = Object.fromEntries(Object.keys(env).map(key => [key, process.env[key]]));
  Object.assign(process.env, env);
  let result, failure;
  try {
    result = await runSpecial('building-contract', ['-Contract', 'CitadelFacadePhaseParity.gd', '-OutputDirectory', o.outputdirectory,
      '-ReportEnvironment', 'CITADEL_FACADE_PHASE_REPORT', '-TimeoutSeconds', '110']);
    assertReport(read(path.join(output, 'report.json')), { passed: true, complete: true });
  } catch (error) { failure = error; }
  finally {
    for (const [key, value] of Object.entries(previous)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
    const audit = auditContinuationSources(projectDefault, before), inventory = auditContinuationInventory(projectDefault, production);
    if (fs.existsSync(output)) write(path.join(output, 'comparison-evidence.json'), { passed: !failure && audit.unchanged && inventory.unchanged,
      baselineDirectory: baseline, artifactSha256: report.artifactSha256, sourceSha256: before,
      changedSinceBaseline: Object.entries(production).filter(([file, hash]) => originBefore.sourceSha256[file] !== hash).map(([file, hash]) => ({ file, before: originBefore.sourceSha256[file] ?? null, after: hash })),
      audit, inventory, failure: failure?.message ?? null, completedUtc: new Date().toISOString() });
    if (!audit.unchanged || !inventory.unchanged) throw new AggregateError([...(failure ? [failure] : []), new Error('Phase comparison source audit failed')]);
  }
  if (failure) throw failure;
  return result;
});

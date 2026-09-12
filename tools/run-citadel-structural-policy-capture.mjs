import fs from 'node:fs';
import path from 'node:path';
import { cli, options, projectDefault, inside, demand, hashes, sha, write } from './lib/building-runner.mjs';
import { runSpecial } from './lib/building-special.mjs';
import { continuationSources, auditContinuationSources, auditContinuationInventory } from './lib/candidate-continuation-evidence.mjs';
cli(async () => {
  const o = options(process.argv.slice(2), {
    outputdirectory: '',
    inputpath: 'artifacts/citadel-runtime-integration/candidate-recipe-source-profile-32/input.bin',
    inputsha256: 'e46c25ba500c1c072f14ed72f8ad3ef5d6952d5443e687737f44e1d054e8d159',
  });
  demand(o.outputdirectory, 'OutputDirectory required');
  const input = fs.realpathSync(path.resolve(projectDefault, o.inputpath.replace(/^res:\/\//, '')));
  const inputSha256 = o.inputsha256.toLowerCase();
  demand(inside(fs.realpathSync(projectDefault), input) && fs.statSync(input).isFile(), 'Input must be an existing project file');
  demand(fs.statSync(input).size > 0 && fs.statSync(input).size <= 4 * 1024 * 1024, 'Input byte limit exceeded');
  demand(/^[a-f0-9]{64}$/.test(inputSha256) && sha(input) === inputSha256, 'Exact input SHA256 required');
  const output = path.resolve(projectDefault, o.outputdirectory), generated = output + '-source';
  demand(inside(path.join(projectDefault, 'artifacts/citadel-runtime-integration'), output) && !fs.existsSync(output) && !fs.existsSync(generated), 'Fresh integration directory required');
  const source = fs.readFileSync(path.join(projectDefault, 'scripts/buildings/CitadelUrbanPocComposer.gd'), 'utf8').replaceAll('\r\n', '\n');
  const dependency = 'preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")';
  demand(source.split(dependency).length === 2 && source.split('class_name CitadelUrbanPocComposer\n').length === 2, 'Exact interception points required');
  fs.mkdirSync(generated);
  const ignored = path.join(generated, '.gdignore');
  fs.writeFileSync(ignored, '');
  fs.writeFileSync(path.join(generated, 'Composer.gd'), source.replace('class_name CitadelUrbanPocComposer\n', '').replace(dependency, 'preload("res://scripts/testing/buildings/CitadelStructuralPolicyCaptureStub.gd")'));
  const production = continuationSources(projectDefault);
  const before = { ...production, ...hashes(projectDefault, [path.join(generated, 'Composer.gd'), ignored, input]) };
  demand(before[input] === inputSha256, 'Input changed before source freeze');
  const captureEnv = {
    CITADEL_POLICY_CAPTURE_MIRROR: 'res://' + path.relative(projectDefault, path.join(generated, 'Composer.gd')).replaceAll('\\', '/'),
    CITADEL_POLICY_CAPTURE_INPUT: 'res://' + path.relative(projectDefault, input).replaceAll('\\', '/'),
    CITADEL_POLICY_CAPTURE_INPUT_SHA256: inputSha256,
  };
  write(path.join(generated, 'evidence-before.json'), { output, inputPath: input, inputSha256,
    mirrorPath: captureEnv.CITADEL_POLICY_CAPTURE_MIRROR,
    transformation: 'Normalize CRLF; remove exactly one class_name; redirect exactly one structural dependency to the capture stub.',
    sourceSha256: before, startedUtc: new Date().toISOString() });
  const previous = Object.fromEntries(Object.keys(captureEnv).map(key => [key, process.env[key]]));
  Object.assign(process.env, captureEnv);
  let result, failure;
  try {
    result = await runSpecial('building-contract', ['-Contract', 'CitadelStructuralPolicyCapture.gd', '-OutputDirectory', o.outputdirectory, '-ReportEnvironment', 'CITADEL_POLICY_CAPTURE_REPORT', '-TimeoutSeconds', '110']);
  } catch (error) {
    failure = error;
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    const audit = auditContinuationSources(projectDefault, before);
    const inventory = auditContinuationInventory(projectDefault, production);
    write(path.join(generated, 'evidence-after.json'), { passed: !failure && audit.unchanged && inventory.unchanged, output, inputPath: input, inputSha256,
      failure: failure?.message ?? null, audit, inventory, completedUtc: new Date().toISOString() });
    if (!audit.unchanged || !inventory.unchanged) throw new AggregateError([...(failure ? [failure] : []), new Error('Policy capture source audit failed; inspect evidence-after.json.')]);
  }
  if (failure) throw failure;
  return result;
});

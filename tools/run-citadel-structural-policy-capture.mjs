import fs from 'node:fs';
import path from 'node:path';
import { cli, options, projectDefault, inside, demand, hashes, write } from './lib/building-runner.mjs';
import { runSpecial } from './lib/building-special.mjs';
import { continuationSources, auditContinuationSources, auditContinuationInventory } from './lib/candidate-continuation-evidence.mjs';
cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '' });
  demand(o.outputdirectory, 'OutputDirectory required');
  const output = path.resolve(projectDefault, o.outputdirectory), generated = output + '-source';
  demand(inside(path.join(projectDefault, 'artifacts/citadel-runtime-integration'), output) && !fs.existsSync(output) && !fs.existsSync(generated), 'Fresh integration directory required');
  const source = fs.readFileSync(path.join(projectDefault, 'scripts/buildings/CitadelUrbanPocComposer.gd'), 'utf8').replaceAll('\r\n', '\n');
  const dependency = 'preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")';
  demand(source.split(dependency).length === 2 && source.split('class_name CitadelUrbanPocComposer\n').length === 2, 'Exact interception points required');
  fs.mkdirSync(generated);
  fs.writeFileSync(path.join(generated, 'Composer.gd'), source.replace('class_name CitadelUrbanPocComposer\n', '').replace(dependency, 'preload("res://scripts/testing/buildings/CitadelStructuralPolicyCaptureStub.gd")'));
  const production = continuationSources(projectDefault);
  const before = { ...production, ...hashes(projectDefault, [path.join(generated, 'Composer.gd'), 'artifacts/citadel-runtime-integration/candidate-recipe-21/input.bin']) };
  write(path.join(generated, 'evidence-before.json'), { output, sourceSha256: before, startedUtc: new Date().toISOString() });
  const previous = process.env.CITADEL_POLICY_CAPTURE_MIRROR;
  process.env.CITADEL_POLICY_CAPTURE_MIRROR = 'res://' + path.relative(projectDefault, path.join(generated, 'Composer.gd')).replaceAll('\\', '/');
  let result, failure;
  try {
    result = await runSpecial('building-contract', ['-Contract', 'CitadelStructuralPolicyCapture.gd', '-OutputDirectory', o.outputdirectory, '-ReportEnvironment', 'CITADEL_POLICY_CAPTURE_REPORT', '-TimeoutSeconds', '110']);
  } catch (error) {
    failure = error;
  } finally {
    if (previous === undefined) delete process.env.CITADEL_POLICY_CAPTURE_MIRROR; else process.env.CITADEL_POLICY_CAPTURE_MIRROR = previous;
    const audit = auditContinuationSources(projectDefault, before);
    const inventory = auditContinuationInventory(projectDefault, production);
    write(path.join(generated, 'evidence-after.json'), { passed: !failure && audit.unchanged && inventory.unchanged, output,
      failure: failure?.message ?? null, audit, inventory, completedUtc: new Date().toISOString() });
    if (!audit.unchanged || !inventory.unchanged) throw new AggregateError([...(failure ? [failure] : []), new Error('Policy capture source audit failed; inspect evidence-after.json.')]);
  }
  if (failure) throw failure;
  return result;
});

import fs from 'node:fs';
import path from 'node:path';
import { options, choice, integer, context, prepare, phaseRun, read, write, sha, shaBytes, hashes, stable, git, demand, assertReport, assertWatchdog, ownedPath, slash, engineErrors, watchdogSources } from './building-runner.mjs';

const composer = 'scripts/buildings/CitadelUrbanPocComposer.gd';
const helper = 'scripts/buildings/RetainedSurfaceBearingRecipe.gd';
const builder = 'scripts/buildings/CastleCompoundBlueprintBuilder.gd';
const planner = 'scripts/buildings/CastleCourtyardDistrictPlacementPlanner.gd';
const siteSha = '7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf';
export const expectedCompoundError = 'ERROR: Castle seed 1298433643 has missing or divergent sampler-owned palace approach authority';
export const literalScripts = /res:\/\/(scripts\/[A-Za-z0-9_/.]+\.gd)/g;
export const literalResources = /res:\/\/([A-Za-z0-9_/.-]+\.(?:gdshader|tres|json|gd))(?![A-Za-z0-9_])/g;
export const normalized = text => text.replaceAll('\r\n', '\n');
export function removeClass(text, name = '\\w+') {
  const expression = new RegExp('^class_name ' + name + '\\r?\\n', 'gm');
  demand([...text.matchAll(expression)].length === 1, 'Expected exactly one class_name removal');
  return text.replace(expression, '');
}
export function replaceOnce(text, needle, replacement) {
  demand(text.split(needle).length === 2, 'Exact capture/binding marker changed: ' + needle);
  return text.replace(needle, replacement);
}
export function archiveGraph(roots, load, inspect, pattern = literalScripts) {
  const queue = [...roots], bytes = new Map();
  while (queue.length) {
    const relative = queue.shift(); if (bytes.has(relative)) continue;
    const data = load(relative); bytes.set(relative, data);
    const source = data.toString('utf8'); inspect(relative, source, data);
    for (const hit of source.matchAll(new RegExp(pattern.source, pattern.flags))) queue.push(hit[1]);
  }
  return bytes;
}
export function landscapeCapture(old) {
  const house = '\tadd_perimeter_neighborhoods(blueprint, grammar, keep_front_z, foundation_height, variation)';
  const tree = '\tvar selected_tree_sites := select_open_paving_tree_sites(blueprint, seed)';
  demand(old.split(tree).length === 2, 'Exact tree capture marker changed');
  let capture = replaceOnce(old, house, '\thandoff["houseInput"] = {"blueprint":blueprint.snapshot(),"grammar":grammar.duplicate(true),"keepFrontZ":keep_front_z,"baseY":foundation_height,"variation":variation}\n' + house + '\n\thandoff["houseOutput"] = blueprint.snapshot()');
  const treeOffset = capture.indexOf(tree), next = capture.indexOf('\nstatic func ', treeOffset);
  demand(next >= 0, 'Missing next method after composer capture');
  return capture.slice(0, treeOffset) + '\thandoff["treeInput"] = blueprint.snapshot()\n\treturn blueprint\n\n' + capture.slice(next);
}
export function eligibleBaseline(c, directory, prefix, phase = 'baseline', binary = 'baseline.bin', hashField = 'baselineSha256') {
  demand(directory, 'Completed ' + phase + ' directory is required');
  const dir = ownedPath(c.project, directory, prefix), report = read(path.join(dir, 'report.json'));
  assertReport(report, { complete: true, passed: true, ...(phase ? { phase } : {}) });
  assertWatchdog(read(path.join(dir, 'watchdog.json')));
  const hash = sha(path.join(dir, binary)); demand(report[hashField] === hash, phase + ' artifact hash mismatch');
  return { dir, hash, report };
}
function writeArchive(c, name, bytes) {
  const target = path.join(c.run, name); fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, bytes, { flag: 'wx' }); return [slash(target), sha(target)];
}
export function errorInventory(stdout, stderr, failurePhase) {
  const lines = (stdout + '\n' + stderr).split(/\r?\n/).filter(line => engineErrors.test(line));
  const expectedErrorCount = failurePhase ? 2 : 0;
  return { passed: lines.length === expectedErrorCount && lines.every(l => l === expectedCompoundError), actualErrorLines: lines, expectedErrorCount };
}

export async function runFrozen(kind, argv, runOwnedProcess) {
  const compound = kind === 'compound', landscape = kind === 'landscape';
  const runnerName = 'citadel-' + (compound ? 'compound' : landscape ? 'landscape' : 'retained-paving') + '-cancellation-contract';
  const contractName = compound ? 'CitadelCompoundCancellationContract' : landscape ? 'CitadelLandscapeCancellationContract' : 'CitadelRetainedPavingCancellationContract';
  const prefix = compound ? 'compound-cancellation-' : landscape ? 'landscape-cancellation-' : 'retained-cancellation-';
  const o = options(argv, {
    phase: '', outputdirectory: '', baselinedirectory: '', cancelstage: '', canceloccurrence: 1,
    target: compound ? 'builder' : landscape ? 'sites' : 'adapter', mode: 'true', timeoutseconds: 90,
    ...(compound ? { reusereferencedirectory: '', expectedbuildersha256: '' } : { expectedcomposersha256: '', ...(landscape ? {} : { armstage: '', expectedhelpersha256: '' }) }),
  }, compound ? ['prepareonly', 'authorizecurrent'] : ['authorizecurrent']);
  o.phase = choice(o.phase, compound ? ['baseline', 'success', 'cancellation', 'failure', 'reuse-reference', 'reuse', 'planner'] : landscape ? ['baseline', 'parity', 'cancellation'] : ['baseline', 'success', 'cancellation', 'synthetic'], 'Phase');
  o.target = choice(o.target, compound ? ['builder', 'source'] : landscape ? ['houses', 'sites', 'records'] : ['adapter', 'helper'], 'Target');
  o.mode = choice(o.mode, ['omitted', 'empty', 'true'], 'Mode');
  const timeout = integer(o.timeoutseconds, 1, 90, 'TimeoutSeconds');
  const occurrence = integer(o.canceloccurrence, 1, 1000000, 'CancelOccurrence');
  demand(o.phase === 'baseline' || o.authorizecurrent || o.prepareonly, 'Current API runs held until interfaces are ready; pass -AuthorizeCurrent');
  if (compound && o.phase === 'cancellation') demand(o.cancelstage.trim(), 'Cancellation requires an explicit stage');
  const c = context(o, prefix), resolve = p => path.resolve(c.project, p), at = n => path.join(c.run, n);
  const revision = compound ? '6994d2a8602aa3a76ff3f18a470d79ba2e7cbe3b' : landscape ? 'f81799da786b0a944566fa3e39cc60b69f9bded8' : 'd9cb0ce068b2cecab09889486678953834a568af';
  const getOld = relative => git(c.project, 'show', revision + ':' + relative);
  const dependencies = {}, gitHashes = {}, liveDependencies = {}, changedDependencies = {};
  const currentSources = {}, referenceSources = {}, archives = {}, extraFiles = [];
  const checkFreeze = (relative, expected) => { if (expected) demand(sha(resolve(relative)) === expected, 'Authorized source freeze hash changed: ' + relative); };
  checkFreeze(builder, o.expectedbuildersha256); checkFreeze(composer, o.expectedcomposersha256); checkFreeze(helper, o.expectedhelpersha256);
  const historical = compound ? { 'actual-site-source-05/result.bin': siteSha } : landscape ? { 'compound-cancellation-baseline-01/baseline.bin': '12650d3e3cd9772026aaa17237511ea63535a75442aed64f5536bce3463f7ae1' } : { 'actual-site-shop-02/result.bin': 'b9244f0d92fd3810d525a29fd115ce295fe56e17135908f9ae11b68d1b992c2d', 'paving-source-diagnosis-01/pre-urban.bin': '19793b8d996f22eeaf6a1c33fba274a3c4ff8d0a696ef8a6e2b75c08ede4f439' };
  for (const [f, hash] of Object.entries(historical)) { const p = resolve('artifacts/citadel-runtime-integration/' + f); demand(sha(p) === hash, 'Historical input SHA mismatch: ' + f); extraFiles.push(p); }
  const baseline = o.phase === 'baseline' ? null : eligibleBaseline(c, o.baselinedirectory, prefix, compound ? 'baseline' : '');
  const reuse = o.phase === 'reuse' ? eligibleBaseline(c, o.reusereferencedirectory, prefix, 'reuse-reference', 'reuse-reference.bin', 'reuseReferenceSha256') : null;
  for (const source of [baseline, reuse].filter(Boolean)) extraFiles.push(path.join(source.dir, 'report.json'), path.join(source.dir, 'watchdog.json'), path.join(source.dir, source === reuse ? 'reuse-reference.bin' : 'baseline.bin'));
  const baselineLaunch = compound && baseline ? read(path.join(baseline.dir, 'launch.json')) : null;
  if (baselineLaunch) extraFiles.push(path.join(baseline.dir, 'launch.json'));
  let oldBytes, frozenText, bytes;
  if (compound) {
    oldBytes = getOld(builder); frozenText = removeClass(oldBytes.toString('utf8'), 'CastleCompoundBlueprintBuilder');
    const roots = ['scripts/world/CitadelSiteField.gd', ...[...frozenText.matchAll(literalScripts)].map(m => m[1])];
    bytes = archiveGraph(roots, getOld, (relative, text, data) => {
      demand(relative !== builder, 'Frozen dependency graph reaches mutable current builder');
      const key = 'res://' + relative, disk = fs.readFileSync(resolve(relative)), diskSha = shaBytes(disk);
      const approvedPlanner = o.phase !== 'baseline' && relative === planner;
      demand(normalized(disk.toString('utf8')) === normalized(text) || approvedPlanner, 'Dependency differs from baseline commit: ' + relative);
      if (o.phase === 'baseline') dependencies[key] = diskSha;
      else {
        demand(typeof baselineLaunch.dependencies?.[key] === 'string', 'Baseline dependency missing: ' + relative);
        dependencies[key] = baselineLaunch.dependencies[key];
        const archived = path.join(baseline.dir, 'dependencies', relative + '.txt');
        demand(sha(archived) === shaBytes(data), 'Archived dependency no longer equals exact Git bytes: ' + relative); extraFiles.push(archived);
      }
      if (approvedPlanner && diskSha !== dependencies[key]) changedDependencies[key] = { baselineSha256: dependencies[key], currentSha256: diskSha, policy: 'Authorized planner continuation. Old reference controls load archived planner, never current planner.' };
      else { demand(diskSha === dependencies[key], 'Baseline dependency byte identity changed: ' + relative); liveDependencies[key] = diskSha; }
      demand(!/\bCastleCompoundBlueprintBuilder\b/.test(text.replace(/#.*$/gm, '')), 'Global-class dependency reaches mutable builder: ' + relative);
    });
    if (o.phase !== 'baseline') archiveGraph([builder, 'scripts/buildings/CitadelRecipePreparation.gd'], relative => fs.readFileSync(resolve(relative)), (relative, text, data) => { currentSources['res://' + relative] = shaBytes(data); });
  } else {
    const roots = landscape ? [composer] : [helper, composer];
    bytes = archiveGraph(roots, getOld, (relative, text, data) => {
      const key = 'res://' + relative; gitHashes[key] = shaBytes(data);
      if (!roots.includes(relative)) {
        const disk = fs.readFileSync(resolve(relative));
        demand(normalized(disk.toString('utf8')) === normalized(text), 'Unchanged dependency differs from Git: ' + relative);
        if (landscape) demand(!text.includes('res://' + composer), 'Dependency reaches mutable composer: ' + relative);
        else {
          const code = text.replace(/#.*$/gm, '');
          demand(!/\bCitadelUrbanPocComposer\b|\bRetainedSurfaceBearingRecipe\b/.test(code) || /res:\/\/scripts\/buildings\/(CitadelUrbanPocComposer|RetainedSurfaceBearingRecipe)\.gd/.test(code), 'Global mutable root dependency requires explicit binding: ' + relative);
        }
        dependencies[key] = shaBytes(disk);
      }
    }, landscape ? literalResources : literalScripts);
    if (!landscape && o.phase !== 'baseline') for (const relative of bytes.keys()) currentSources['res://' + relative] = sha(resolve(relative));
  }

  prepare(c, false);
  if (compound) {
    if (o.phase === 'baseline') {
      writeArchive(c, 'GitCastleCompoundBlueprintBuilder.gd.txt', oldBytes);
      Object.assign(archives, Object.fromEntries([writeArchive(c, 'FrozenCastleCompoundBlueprintBuilder.gd', frozenText)]));
      for (const [relative, data] of bytes) writeArchive(c, 'dependencies/' + relative + '.txt', data);
    } else {
      const oldPlanner = removeClass(bytes.get(planner).toString('utf8'), 'CastleCourtyardDistrictPlacementPlanner');
      const plannerResource = 'res://' + slash(path.relative(c.project, at('FrozenCastleCourtyardDistrictPlacementPlanner.gd')));
      const boundBuilder = frozenText.replaceAll('res://' + planner, plannerResource);
      demand(boundBuilder !== frozenText, 'Old planner binding was not rewritten');
      Object.assign(referenceSources, Object.fromEntries([writeArchive(c, 'FrozenCastleCourtyardDistrictPlacementPlanner.gd', oldPlanner), writeArchive(c, 'BoundOldCastleCompoundBlueprintBuilder.gd', boundBuilder)]));
    }
  } else {
    for (const [relative, data] of bytes) writeArchive(c, 'git/' + relative + '.txt', data);
    if (landscape) {
      const old = removeClass(bytes.get(composer).toString('utf8'), 'CitadelUrbanPocComposer');
      Object.assign(archives, Object.fromEntries([writeArchive(c, 'FrozenComposer.gd', old), writeArchive(c, 'CaptureComposer.gd', landscapeCapture(old))]));
    } else {
      const oldHelper = removeClass(bytes.get(helper).toString('utf8'));
      const resourcePrefix = 'res://' + slash(path.relative(c.project, c.run)) + '/';
      const oldComposer = removeClass(bytes.get(composer).toString('utf8')).replaceAll('res://' + helper, resourcePrefix + 'FrozenRetainedSurfaceBearingRecipe.gd');
      demand(!oldComposer.includes('res://' + helper), 'Composer still depends on current helper');
      const captured = replaceOnce(oldComposer, 'return RetainedBearingRecipeScript.prepare(blueprint, retired_roots, targets, protected)', 'return {"targets":targets,"voids":protected}');
      Object.assign(archives, Object.fromEntries([writeArchive(c, 'FrozenRetainedSurfaceBearingRecipe.gd', oldHelper), writeArchive(c, 'FrozenCitadelUrbanPocComposer.gd', oldComposer), writeArchive(c, 'CaptureOldRetainedInput.gd', captured)]));
    }
  }
  const contractRelative = 'scripts/testing/buildings/' + contractName + '.gd';
  writeArchive(c, 'contract.gd.txt', fs.readFileSync(resolve(contractRelative)));
  writeArchive(c, 'wrapper.mjs.txt', fs.readFileSync(resolve('tools/run-' + runnerName + '.mjs')));
  const sources = hashes(c.project, [contractRelative, 'tools/run-' + runnerName + '.mjs', 'tools/lib/building-frozen.mjs', 'tools/lib/building-runner.mjs', ...watchdogSources, ...extraFiles]);
  const launch = { phase: o.phase, head: git(c.project, 'rev-parse', 'HEAD').toString().trim(), branch: git(c.project, 'branch', '--show-current').toString().trim(), timeoutSeconds: timeout, dependencies, baselineSha256: baseline?.hash ?? '', sourceSha256: sources, scope: 'Source-only historical/synthetic contract. No headed, navigation or gameplay acceptance.' };
  const env = {};
  if (compound) {
    Object.assign(launch, { baselineRevision: revision, gitBuilderSha256: shaBytes(oldBytes), frozenSha256: shaBytes(Buffer.from(frozenText)), siteSha256: siteSha, liveDependencies, changedDependencies, referenceSources, currentSources, mode: o.mode, reuseReferenceSha256: reuse?.hash ?? '', cancelStage: o.cancelstage, cancelOccurrence: occurrence, target: o.target, runnerSha256: sha(resolve(contractRelative)), dependencyPolicy: 'Transitive literal script graph; reject global mutable builder references. Exact Git bytes archived; live disk hashes bound before/after.' });
    Object.assign(env, { CITADEL_COMPOUND_PHASE: o.phase, CITADEL_COMPOUND_OUTPUT: slash(c.run), CITADEL_COMPOUND_SITE: slash(resolve('artifacts/citadel-runtime-integration/actual-site-source-05/result.bin')), CITADEL_COMPOUND_BASELINE: slash(baseline?.dir ?? ''), CITADEL_COMPOUND_CANCEL_STAGE: o.cancelstage, CITADEL_COMPOUND_CANCEL_OCCURRENCE: String(occurrence), CITADEL_COMPOUND_MODE: o.mode, CITADEL_COMPOUND_TARGET: o.target, CITADEL_COMPOUND_REUSE_REFERENCE: slash(reuse?.dir ?? '') });
  } else if (landscape) {
    Object.assign(launch, { revision, gitHashes, archives, compoundSha256: Object.values(historical)[0], currentComposerSha256: sha(resolve(composer)), testSha256: sha(resolve(contractRelative)), capturePolicy: 'Full Git composer class_name removed; capture original house input/output; stop before tree selector after bunting. Later Source stages never execute.', dependencyPolicy: 'Recursive literal gd/tres/gdshader/json graph. Exact Git bytes archived; live dependencies hash bound before/after.' });
    Object.assign(env, { LANDSCAPE_PHASE: o.phase, LANDSCAPE_OUTPUT: slash(c.run), LANDSCAPE_BASELINE: slash(baseline?.dir ?? ''), LANDSCAPE_TARGET: o.target, LANDSCAPE_MODE: o.mode, LANDSCAPE_CANCEL_STAGE: o.cancelstage, LANDSCAPE_CANCEL_OCCURRENCE: String(occurrence) });
  } else {
    Object.assign(launch, { revision, gitHashes, archives, currentSources, historical, testSha256: sha(resolve(contractRelative)), inputCapturePolicy: 'Full old composer bound to frozen helper. Capture variant replaces sole helper return with targets/voids; original bound composer executes baseline proof.' });
    Object.assign(env, { RETAINED_CANCEL_PHASE: o.phase, RETAINED_CANCEL_OUTPUT: slash(c.run), RETAINED_CANCEL_BASELINE: slash(baseline?.dir ?? ''), RETAINED_CANCEL_TARGET: o.target, RETAINED_CANCEL_MODE: o.mode, RETAINED_CANCEL_STAGE: o.cancelstage, RETAINED_CANCEL_ARM_STAGE: o.armstage, RETAINED_CANCEL_OCCURRENCE: String(occurrence) });
  }
  write(at('launch.json'), launch);
  if (o.prepareonly) return { preparedOnly: true, evidenceLevel: 'Prepared reference bindings only; no Godot run or test pass', outputDirectory: c.run };
  let failure;
  try {
    await phaseRun(c, { args: ['--headless', '--script', 'res://' + contractRelative], env, timeout, logPolicy: { pattern: engineErrors, expectedError: compound && o.phase === 'failure' ? expectedCompoundError : '', expectedCount: compound && o.phase === 'failure' ? 2 : 0 } }, runOwnedProcess);
    assertReport(read(at('summary.json')), { complete: true, passed: true });
    stable(c.project, sources); stable(c.project, compound ? liveDependencies : dependencies); stable(c.project, currentSources); stable(c.project, referenceSources); stable(c.project, archives);
    if (landscape) demand(sha(resolve(composer)) === launch.currentComposerSha256, 'Composer changed during execution');
  } catch (error) { failure = error; }
  if (compound && fs.existsSync(at('stdout.log')) && fs.existsSync(at('stderr.log'))) {
    const inventory = errorInventory(fs.readFileSync(at('stdout.log'), 'utf8'), fs.readFileSync(at('stderr.log'), 'utf8'), o.phase === 'failure');
    write(at('error-inventory.json'), inventory);
    if (!inventory.passed) failure ??= new Error('Unexpected error multiplicity; inspect error-inventory.json');
  }
  if (failure) throw failure;
  return { passed: true, phase: o.phase, reportPath: at('summary.json'), evidenceLevel: launch.scope };
}

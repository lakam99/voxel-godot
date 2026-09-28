import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { cli, options, projectDefault, inside, demand, hashes, read, sha, shaBytes, write, git, assertReport, assertWatchdog } from './lib/building-runner.mjs';
import { runSpecial } from './lib/building-special.mjs';
import { continuationSources, auditContinuationSources, auditContinuationInventory } from './lib/candidate-continuation-evidence.mjs';

const lowerPath = 'scripts/buildings/LowerFacadeBearingRecipe.gd';
const baseCommit = '612a970';
const artifactBindings = {
  'lower-input.bin': 'f884593fe778af32f9ffdc3407ad05512ef3679a9a8920908a03c070736fdfb3',
  'lower-expected.bin': '8b83118c4c295461fcb597844ca3ea3474cdef04b8b02e06309ac3727426e5bf',
  'lower-physical.bin': '676df9b2ff9739458427aeae64e77b3b77c8abd6118349111eab43eaecd29c91',
};
const spans = {
  prepare_all_bottom_rows: 'lower_total', _assembly_proof: 'assembly_build_and_reuse',
  _run_independent_completion: 'completion_loop', _support_targets_for_additions: 'support_target_scan',
  _propagate_rooted_supports: 'root_propagation', _current_unsupported_bottom_panels: 'discovery_and_physical',
  _verify_completion_reports: 'verification', _prepare_input: 'candidate_preparation',
  _build_root_context: 'initial_masonry_roots', _root_context_for: 'masonry_context_binding',
  _independent_masonry_records: 'masonry_record_scan', _shorten_body: 'shorten_body', _fit: 'fit',
  _select_prepared_panel: 'panel_selection', _admit_completion_delta: 'delta_admission',
  _commit_prepared_members: 'commit_members', _read: 'read_and_admit_initial_input',
  _protected: 'protected_volumes', _admit: 'member_admission',
};
const normalize = text => text.replaceAll('\r\n', '\n');
const resourcePath = file => 'res://' + path.relative(projectDefault, file).replaceAll('\\', '/');

// Exported for a read-only Node transformation audit. Importing does not launch Godot.
export function buildLowerTimingMirror(source) {
  let text = normalize(source);
  const edits = [];
  const replace = (needle, replacement, count = 1) => {
    const found = text.split(needle).length - 1;
    demand(found === count, `Exact timing interception changed (${found}/${count}): ${needle}`);
    text = text.replaceAll(needle, replacement);
    edits.push({ needle, count });
  };
  demand(!text.includes('CitadelLowerPhaseTimingMeter') && !text.includes('_timing_inner_'), 'Source is already instrumented');
  replace('extends RefCounted\n', 'extends RefCounted\nconst Timing = preload("res://scripts/testing/buildings/CitadelLowerPhaseTimingMeter.gd")\nconst TIMING_MIRROR_SCHEMA := "citadel-lower-timing-mirror/v1"\n');
  const copies = text.split('Copy.copy_blueprint(').length - 1;
  const grids = text.split('Copy.validation_grid_work(').length - 1;
  const clears = text.split('Copy.clear_caches(').length - 1;
  demand(copies === 10 && grids === 5 && clears === 6, 'Original copy/grid/clear call inventory changed');
  replace('Copy.copy_blueprint(', '_timed_copy_blueprint(', copies);
  replace('Copy.validation_grid_work(', '_timed_grid_admission(', grids);
  replace('Copy.clear_caches(', '_timed_clear_derived(', clears);
  replace('roots.snapshot()', '_timed_blueprint_snapshot(roots)', 2);
  replace('prepared_input.blueprint.snapshot()', '_timed_blueprint_snapshot(prepared_input.blueprint)');
  replace('b.snapshot()', '_timed_blueprint_snapshot(b)');
  replace('Connection._place_connection(domain, core, neutral, HALF, obstacles, work)',
    '_timed_place_connection(domain, core, neutral, HALF, obstacles, work)');
  for (const owner of ['blueprint', 'roots', 'before', 'after'])
    replace(`${owner}.validate_physical_integrity_cancellable(continuation)`, `_timed_physical(${owner}, continuation, false)`);
  replace('proof.validate_once(continuation)', '_timed_physical(proof, continuation, true)');
  replace('\tfunc resolved_support_record(target) -> Dictionary:',
    '\tfunc _index_structural_support_candidates(continuation: Callable) -> bool:\n' +
    '\t\tvar token: Dictionary = Timing.begin_span("assembly_support_index")\n' +
    '\t\tvar result: bool = super._index_structural_support_candidates(continuation)\n' +
    '\t\tTiming.end_span(token)\n\t\treturn result\n\tfunc resolved_support_record(target) -> Dictionary:');
  replace('\tvar candidates: Array = []\n\tfor seat in roots.parts:',
    '\tvar scan_token: Dictionary = Timing.begin_span("seat_scan",panel_id)\n\tvar candidates: Array = []\n\tfor seat in roots.parts:');
  replace('\tif candidates.size() > MAX_SEATS: return _fail("rooted_seat_candidate_limit")\n\tcandidates.sort_custom(',
    '\tTiming.end_span(scan_token)\n\tTiming.add_count("seatRecordsScanned",roots.parts.size())\n' +
    '\tif candidates.size() > MAX_SEATS: return _fail("rooted_seat_candidate_limit")\n' +
    '\tvar sort_token: Dictionary = Timing.begin_span("seat_sort",panel_id)\n\tcandidates.sort_custom(');
  replace('\t\treturn da < dc if da != dc else a.id < c.id)\n\tvar attempts: Array = []',
    '\t\treturn da < dc if da != dc else a.id < c.id)\n\tTiming.end_span(sort_token)\n\tvar attempts: Array = []');
  replace('\t\t\tif accepted.is_empty(): state = _timed_blueprint_snapshot(prepared_input.blueprint)',
    '\t\t\tvar commit_token: Dictionary = Timing.begin_span("commit_state_and_roots",panel_id)\n' +
    '\t\t\tif accepted.is_empty(): state = _timed_blueprint_snapshot(prepared_input.blueprint)');
  replace('\t\t\t_propagate_rooted_supports(rooted, support_graph)\n',
    '\t\t\t_propagate_rooted_supports(rooted, support_graph)\n\t\t\tTiming.end_span(commit_token)\n');
  replace('\t# Keep the complete target scan: a new beam can acquire ordinary-support',
    '\tTiming.add_count("supportTargetRecordsScanned",records.size())\n' +
    '\tTiming.add_count("supportTargetPairUpperBound",records.size()*influences.size())\n' +
    '\t# Keep the complete target scan: a new beam can acquire ordinary-support');

  const wrappers = [];
  for (const [name, label] of Object.entries(spans)) {
    const declarations = [...text.matchAll(new RegExp(`^static func ${name}\\((.*)\\)([^\\n]*):$`, 'gm'))];
    demand(declarations.length === 1, 'Exact timed function declaration required: ' + name);
    const [declaration, parameters, returns] = declarations[0];
    // These frozen declarations have only scalar/empty-container defaults.
    const parts = parameters.split(',').map(value => value.trim());
    const args = parts.map(value => {
      const match = /^([a-zA-Z_][a-zA-Z0-9_]*)\s*(?::|=|$)/.exec(value);
      demand(match, 'Unsupported timing parameter: ' + value);
      return match[1];
    });
    const context = args.includes('panel_id') ? 'panel_id' : args.includes('panel') ? 'panel.id' : args.includes('part') ? 'part.id' : '""';
    replace(declaration, declaration.replace(`func ${name}(`, `func _timing_inner_${name}(`));
    const isVoid = returns.trim() === '-> void';
    wrappers.push(`${declaration}\n\tvar token: Dictionary = Timing.begin_span("${label}",${context})\n` +
      `\t${isVoid ? '' : 'var result: Variant = '}_timing_inner_${name}(${args.join(', ')})\n` +
      '\tTiming.end_span(token)\n' + (isVoid ? '' : '\treturn result\n'));
  }
  text += '\n# Diagnostic pass-through wrappers; no proposal or proof result is changed.\n' + wrappers.join('\n') + `
static func _timed_copy_blueprint(snapshot: Dictionary):
\tvar token: Dictionary = Timing.begin_span("blueprint_copy")
\tvar result = Copy.copy_blueprint(snapshot)
\tTiming.end_span(token)
\tTiming.add_count("blueprintPartRecordsCopied",snapshot.parts.size())
\treturn result

static func _timed_blueprint_snapshot(blueprint) -> Dictionary:
\tvar token: Dictionary = Timing.begin_span("blueprint_snapshot")
\tvar result: Dictionary = blueprint.snapshot()
\tTiming.end_span(token)
\tTiming.add_count("blueprintPartRecordsSnapshotted",blueprint.parts.size())
\treturn result

static func _timed_grid_admission(blueprint) -> Dictionary:
\tvar token: Dictionary = Timing.begin_span("validation_grid_admission")
\tvar result: Dictionary = Copy.validation_grid_work(blueprint)
\tTiming.end_span(token)
\treturn result

static func _timed_clear_derived(blueprint) -> void:
\tvar token: Dictionary = Timing.begin_span("clear_derived_records")
\tCopy.clear_caches(blueprint)
\tTiming.end_span(token)

static func _timed_place_connection(domain: Array, core: Array, neutral: Vector3, half: Vector3, obstacles: Array, work: Dictionary) -> Dictionary:
\tvar token: Dictionary = Timing.begin_span("connection_placement")
\tvar result: Dictionary = Connection._place_connection(domain,core,neutral,half,obstacles,work)
\tTiming.end_span(token)
\treturn result

static func _timed_physical(proof, continuation: Callable, assembly: bool) -> Dictionary:
\tvar token: Dictionary = Timing.begin_span("physical_validation_assembly" if assembly else "physical_validation_base")
\tvar result: Dictionary = proof.validate_once(continuation) if assembly else proof.validate_physical_integrity_cancellable(continuation)
\tTiming.end_span(token)
\tTiming.add_count("physicalValidationCalls",1)
\tTiming.add_count("physicalPartChecks",result.get("checks",[]).size())
\tif assembly: Timing.add_count("assemblyReusedSupportRecords",proof.reused_count)
\treturn result
`;
  return { text, edits, spans, sha256: shaBytes(text) };
}

async function run() {
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
  for (const [name, expected] of Object.entries(artifactBindings))
    demand(report.artifactSha256?.[name] === expected && sha(path.join(baseline, name)) === expected, 'Frozen lower artifact mismatch: ' + name);
  for (const [file, expected] of Object.entries(originBefore.sourceSha256))
    if (/\.(dll|gdextension|exe)$/i.test(file)) demand(sha(path.resolve(projectDefault, file)) === expected, 'Baseline engine/native binary changed: ' + file);
  const original = fs.readFileSync(path.join(projectDefault, lowerPath), 'utf8');
  const committed = git(projectDefault, 'show', `${baseCommit}:${lowerPath}`).toString();
  demand(normalize(original) === normalize(committed), 'Lower production source differs from the accepted 612a970 transaction');
  const transformed = buildLowerTimingMirror(original);
  const output = path.resolve(projectDefault, o.outputdirectory), generated = output + '-source';
  demand(path.dirname(output) === integration && !fs.existsSync(output) && !fs.existsSync(generated), 'Fresh direct integration output required');
  fs.mkdirSync(generated);
  const mirror = path.join(generated, 'Lower.gd'), ignored = path.join(generated, '.gdignore');
  fs.writeFileSync(ignored, ''); fs.writeFileSync(mirror, transformed.text);
  const production = continuationSources(projectDefault);
  const before = { ...production, ...hashes(projectDefault, [mirror, ignored, ...originPaths, ...Object.keys(artifactBindings).map(name => path.join(baseline, name))]) };
  demand(before[lowerPath] === shaBytes(original) && before[mirror] === transformed.sha256, 'Lower source/mirror changed before diagnostic freeze');
  const provenance = { output, baselineDirectory: baseline, artifactSha256: artifactBindings, baseCommit,
    originalPath: lowerPath, originalSha256: sha(path.join(projectDefault, lowerPath)), mirrorPath: resourcePath(mirror), mirrorSha256: transformed.sha256,
    transformations: transformed.edits, instrumentedFunctions: transformed.spans,
    transformationScope: 'One exact Lower source mirror with balanced pass-through timing wrappers and the existing non-native AssemblyProof index super-call observer. Base Blueprint/Copy/native code remains unchanged.',
    sourceSha256: before };
  write(path.join(generated, 'evidence-before.json'), { ...provenance, startedUtc: new Date().toISOString() });
  const env = { CITADEL_LOWER_TIMING_BASELINE: resourcePath(baseline), CITADEL_LOWER_TIMING_BINDINGS: JSON.stringify(artifactBindings),
    CITADEL_LOWER_TIMING_MIRROR: resourcePath(mirror), CITADEL_LOWER_TIMING_MIRROR_SHA256: transformed.sha256 };
  const previous = Object.fromEntries(Object.keys(env).map(key => [key, process.env[key]]));
  Object.assign(process.env, env);
  let result, failure;
  try {
    result = await runSpecial('building-contract', ['-Contract', 'CitadelLowerPhaseTiming.gd', '-OutputDirectory', o.outputdirectory,
      '-ReportEnvironment', 'CITADEL_FACADE_PHASE_REPORT', '-TimeoutSeconds', '90']);
    const measured = read(path.join(output, 'report.json'));
    assertReport(measured, { passed: true, complete: true, schema: 'citadel-lower-phase-diagnostic/v1', mirrorSha256: transformed.sha256 });
    demand(Object.keys(measured.checks ?? {}).length > 0 && Object.values(measured.checks).every(value => value === true), 'Lower diagnostic parity or instrumentation failed');
    demand(sha(path.join(output, 'lower-actual.bin')) === artifactBindings['lower-expected.bin'] &&
      sha(path.join(output, 'lower-physical-actual.bin')) === artifactBindings['lower-physical.bin'], 'Saved full typed diagnostic artifacts differ');
  } catch (error) { failure = error; }
  finally {
    for (const [key, value] of Object.entries(previous)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
    const audit = auditContinuationSources(projectDefault, before), inventory = auditContinuationInventory(projectDefault, production);
    write(path.join(generated, 'evidence-after.json'), { passed: !failure && audit.unchanged && inventory.unchanged,
      output, baselineDirectory: baseline, artifactSha256: artifactBindings, audit, inventory,
      failure: failure?.message ?? null, completedUtc: new Date().toISOString() });
    if (!audit.unchanged || !inventory.unchanged) throw new AggregateError([...(failure ? [failure] : []), new Error('Lower diagnostic source freeze failed')]);
  }
  if (failure) throw failure;
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) cli(run);

import fs from 'node:fs';
import path from 'node:path';
import { cli, options, projectDefault, demand, hashes, read, sha, write, assertReport, assertNoGodot, godotDefault, resolveExecutablePair } from './lib/building-runner.mjs';
import { runSpecial } from './lib/building-special.mjs';
import { continuationSources, auditContinuationSources, auditContinuationInventory } from './lib/candidate-continuation-evidence.mjs';

const sourceSha256 = '42f3c7b2ff1dee451f98dbd286c1a2d346c9e0033326f578ec8a6fea75418067';
const siteId = 'citadel-site-v1:16:atlas-3376622889:-2,-2';
const originText = '(-4500.9, 41.85, -3800.25)';
const worldOrigin = [-4500.9, 41.85, -3800.25];

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', demandorder: 'canonical' });
  demand(o.outputdirectory, 'OutputDirectory required; acquisition runs only when the Godot baseline window is available');
  const demandOrder = String(o.demandorder).toLowerCase();
  demand(['canonical', 'rotating'].includes(demandOrder), 'DemandOrder must be Canonical or Rotating');
  const integration = path.join(projectDefault, 'artifacts/citadel-runtime-integration');
  const source = path.join(integration, 'candidate-recipe-source-profile-32/source.bin');
  const sourceReportPath = path.join(path.dirname(source), 'report.json');
  const originReportPath = path.join(integration, 'candidate-teleport-navigation-filter-12/report.json');
  const sourceReport = read(sourceReportPath), originReport = read(originReportPath);
  assertReport(sourceReport, { passed: true, recipePassed: true, recipeSeed: 1393179273, worldSeed: 'atlas-3376622889' });
  demand(sourceReport.receipt?.sourceSha256 === sourceSha256 && sourceReport.receipt?.sourceSnapshotBeforeDiagnosticPhysicalValidation === true &&
    sourceReport.receipt?.context?.siteKey === siteId, 'Pinned source32 report binding failed');
  demand(fs.statSync(source).isFile() && fs.statSync(source).size > 0 && fs.statSync(source).size <= 64 * 1024 * 1024 &&
    sha(source) === sourceSha256, 'Pinned source32 binary hash or size failed');
  assertReport(originReport, { passed: true, seed: 'atlas-3376622889' });
  const scene = originReport.evidence?.sceneAudit, binding = originReport.evidence?.acceptedIdentity?.binding;
  demand(originReport.candidate?.siteId === siteId && originReport.candidate?.recipeSeed === 1393179273 &&
    scene?.sourceOrigin === originText && scene?.rootPosition === originText && scene?.rootMatchesProfile === true && scene?.sourceStillMatches === true,
  'The default world origin must match the actual headed12 accepted source');
  demand(binding?.siteId === siteId && typeof binding?.sourceKey === 'string' && binding.sourceKey.length > 0 &&
    Number.isInteger(binding?.generation) && binding.generation > 0 && Object.keys(binding).length === 3, 'Headed12 source binding is invalid');

  const output = path.resolve(projectDefault, o.outputdirectory), evidence = output + '-source';
  demand(path.dirname(output) === integration && !fs.existsSync(output) && !fs.existsSync(evidence), 'Fresh output directly inside integration artifacts required');
  // Read-only exclusivity check: an unrelated headed run is never controlled.
  assertNoGodot();
  fs.mkdirSync(evidence);
  const inventory = continuationSources(projectDefault);
  const before = { ...inventory, ...hashes(projectDefault, [source, sourceReportPath, originReportPath]) };
  demand(before[source] === sourceSha256, 'Source changed before acquisition freeze');
  const engine = resolveExecutablePair(godotDefault);
  const engineSha256 = Object.fromEntries(Object.values(engine).map(file => [file, before[file]]));
  const nativeSha256 = Object.fromEntries(Object.entries(inventory).filter(([file]) => /\.(dll|gdextension)$/i.test(file)));
  const relevantEnvironment = Object.keys(process.env).filter(key => /^(VOXEL_|CITADEL_|BUILDING_|TREE_)/i.test(key));
  const previous = Object.fromEntries(relevantEnvironment.map(key => [key, process.env[key]]));
  write(path.join(evidence, 'evidence-before.json'), { schema: 'citadel-dense-navigation-acquisition/v1', output, sourcePath: source,
    sourceSha256, sourceReportPath, originReportPath, originReportSha256: before[originReportPath], worldOrigin, binding,
    sourceSha256Inventory: before, engineSha256, nativeSha256, clearedEnvironmentNames: relevantEnvironment, demandOrder,
    comparison: { artifact: 'navigation-tiles.bin', excludedPaths: ['preparationUsec'], ordered: true },
    scope: 'Offline saved-source dense navigation preparation oracle only. No recipe regeneration or live acceptance.', startedUtc: new Date().toISOString() });
  for (const key of relevantEnvironment) delete process.env[key];
  process.env.CITADEL_DENSE_NAVIGATION_ORDER = demandOrder;
  let result, failure;
  try {
    result = await runSpecial('building-contract', ['-Contract', 'CitadelDenseNavigationBaseline.gd', '-OutputDirectory', o.outputdirectory,
      '-ReportEnvironment', 'CITADEL_DENSE_NAVIGATION_REPORT', '-TimeoutSeconds', '150']);
    const report = read(path.join(output, 'report.json'));
    assertReport(report, { schema: 'citadel-dense-navigation-baseline/v1', complete: true, passed: true, sourceSha256, demandOrder,
      originReportSha256: before[originReportPath], worldOrigin: originText, binding });
    demand(Object.keys(report.checks ?? {}).length > 0 && Object.values(report.checks).every(value => value === true), 'Dense baseline checks failed');
    if (demandOrder === 'rotating') {
      const schedule = report.demandSchedule;
      demand(schedule?.turns > 1 && schedule.permutedTurns > 0 && schedule.changedSelections > 0 &&
        schedule.maxSelected > 0 && schedule.maxSelected <= 8 && schedule.activeCoverage === true &&
        schedule.completionCoverage === true && schedule.domainUnchanged === true &&
        schedule.domainInventory?.scope === 'source_navigation_output' &&
        Array.isArray(schedule.domainInventory.tileKeys) && schedule.domainInventory.tileKeys.length === schedule.domainCount &&
        /^[a-f0-9]{64}$/.test(schedule.domainTypedSha256 ?? '') && Array.isArray(schedule.firstTurns) &&
        schedule.firstTurns.length > 0 && schedule.firstTurns.length <= 8,
      'Rotating demand did not prove bounded, changing selections and complete batch coverage');
    }
    demand(JSON.stringify(report.comparison?.excludedPaths) === JSON.stringify(['preparationUsec']) && report.comparison?.ordered === true,
      'Only the root preparationUsec timing may be excluded from later comparison');
    demand(/^[a-f0-9]{64}$/.test(report.semanticSha256 ?? '') && /^[a-f0-9]{64}$/.test(report.rawTypedSha256 ?? ''), 'Missing complete typed navigation digests');
    const artifact = path.join(output, 'navigation-tiles.bin');
    demand(Object.keys(report.artifactSha256 ?? {}).length === 1 && report.artifactSha256['navigation-tiles.bin'] === sha(artifact) &&
      report.artifactBytes === fs.statSync(artifact).size, 'Dense typed artifact hash or size mismatch');
    demand(report.counts?.tiles > 0 && report.counts?.surfaceCount > 0 && Array.isArray(report.tilesInProducerOrder) &&
      report.tilesInProducerOrder.length === report.counts.tiles && report.tileFieldTotals?.surfaces === report.counts.surfaceCount,
    'Incomplete dense tile inventory');
    assertNoGodot();
  } catch (error) { failure = error; }
  finally {
    delete process.env.CITADEL_DENSE_NAVIGATION_ORDER;
    for (const [key, value] of Object.entries(previous)) process.env[key] = value;
    const audit = auditContinuationSources(projectDefault, before), inventoryAudit = auditContinuationInventory(projectDefault, inventory);
    write(path.join(evidence, 'evidence-after.json'), { passed: !failure && audit.unchanged && inventoryAudit.unchanged, output,
      sourcePath: source, sourceSha256, failure: failure?.message ?? null, audit, inventory: inventoryAudit, completedUtc: new Date().toISOString() });
    if (!audit.unchanged || !inventoryAudit.unchanged) throw new AggregateError([...(failure ? [failure] : []), new Error('Dense baseline source/native/engine freeze failed')]);
  }
  if (failure) throw failure;
  return { ...result, artifactPath: path.join(output, 'navigation-tiles.bin'), evidenceDirectory: evidence,
    evidenceLevel: 'offline saved-source preparation baseline; no live acceptance' };
});

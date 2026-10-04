import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'prepared-static-contributor-ledger-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/world/PreparedStaticContributorLedger.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd.uid',
    'scripts/buildings/BuildingSpatialDependencies.gd',
    'scripts/testing/buildings/PreparedStaticContributorLedgerContract.gd',
    'tools/run-prepared-static-contributor-ledger-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, {
    schema: 'prepared-static-contributor-ledger-launch/v1',
    evidenceLevel: 'pure_revisioned_prepared_segment_transaction_contract',
    headed: false,
    timeoutSeconds: 45,
    doesNotProve: 'No BuildingPartPublisher integration, section backend installation, collision, worker scheduling, rendering performance, or live gameplay acceptance.'
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/PreparedStaticContributorLedgerContract.gd'],
    env: { PREPARED_STATIC_CONTRIBUTOR_LEDGER_REPORT: path.join(c.run, 'report.json') },
    timeout: 45,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'prepared-static-contributor-ledger-contract/v1' && report.passed === true,
    'Prepared static contributor ledger contract failed.');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checks: report.checks,
    committedSourceParts: report.committedSourceParts,
    committedImpactedSections: report.committedImpactedSections,
    evidence: report.evidence
  };
});

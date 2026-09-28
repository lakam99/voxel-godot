import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'actual-navigation-tile-packet-closure-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/buildings/CitadelActualNavigationTilePacketClosureAudit.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingSpatialDependencies.gd',
    'scripts/buildings/BuildingNavigationTileProducer.gd',
    'scripts/buildings/BuildingPublicationSource.gd',
    'tools/run-citadel-actual-navigation-tile-packet-closure-audit.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs',
    'artifacts/citadel-runtime-integration/actual-site-source-05/result.bin'
  ];
  const before = launchRecord(c, files, {
    schema: 'citadel-actual-navigation-tile-packet-closure-audit-launch/v1',
    evidenceLevel: 'actual_frozen_source_compact_navigation_domain_and_packet_eligibility_audit',
    fixtureSha256: '7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf',
    headed: false,
    timeoutSeconds: 120
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/CitadelActualNavigationTilePacketClosureAudit.gd'],
    env: { CITADEL_TILE_PACKET_CLOSURE_REPORT: path.join(c.run, 'report.json') },
    timeout: 120,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, { schema: 'citadel-actual-navigation-tile-packet-closure-audit/v1', passed: true, complete: true });
  demand(report.workerThread === true, 'Audit did not run on its owned worker');
  return { reportPath: path.join(c.run, 'report.json'), counts: report.counts, evidenceLevel: report.evidenceLevel };
});

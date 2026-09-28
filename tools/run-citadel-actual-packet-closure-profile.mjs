import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'actual-packet-closure-profile-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/buildings/CitadelActualPacketClosureProfile.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingPublicationSource.gd',
    'scripts/buildings/BuildingSpatialDependencies.gd',
    'tools/run-citadel-actual-packet-closure-profile.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs',
    'artifacts/citadel-runtime-integration/actual-site-source-05/result.bin'
  ];
  launchRecord(c, files, {
    schema: 'citadel-actual-packet-closure-profile-launch/v1',
    evidenceLevel: 'actual_frozen_source_bounded_packet_compiler_trace',
    fixtureSha256: '7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf',
    headed: false,
    timeoutSeconds: 90
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/CitadelActualPacketClosureProfile.gd'],
    env: { CITADEL_PACKET_CLOSURE_PROFILE_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const value = read(path.join(c.run, 'report.json'));
  assertReport(value, { schema: 'citadel-actual-packet-closure-profile/v1', passed: true, complete: true });
  demand(value.compile?.reason === 'cancelled' || value.compile?.ready === true, 'bounded compiler did not reach a terminal state');
  return { reportPath: path.join(c.run, 'report.json'), compile: value.compile, evidenceLevel: value.evidenceLevel };
});

import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ecology-realized-prop-capture-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/Main.gd',
    'scripts/MainPropFactory.gd',
    'scripts/MainChunkTerrain.gd',
    'scripts/MainInteractionFlow.gd',
    'scripts/MainPlaytestTools.gd',
    'scripts/MainRuntimeTools.gd',
    'scripts/MainDiscoveryFlow.gd',
    'scripts/MainHudFlow.gd',
    'scripts/MainWorldEntities.gd',
    'scripts/MainCharacterState.gd',
    'scripts/MainGameLoop.gd',
    'scripts/MainSetupScene.gd',
    'scripts/MainSaveState.gd',
    'scripts/MainCore.gd',
    'scripts/MainInterface.gd',
    'scripts/world/EcologySourceValueLedger.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/testing/world/EcologyRealizedPropCaptureContract.gd',
    'tools/run-ecology-realized-prop-capture-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, {
    schema: 'ecology-realized-prop-capture-launch/v1',
    evidenceLevel: 'real_production_static_ecology_creator_outputs_with_rng_replay',
    headed: false,
    timeoutSeconds: 120,
    doesNotProve: 'No ecology census completeness for generated rock scenes, native section installation, save/replay, headed visual parity, traversal, or performance acceptance.'
  });
  await phaseRun(c, {
    args: ['--script', 'res://scripts/testing/world/EcologyRealizedPropCaptureContract.gd'],
    env: { ECOLOGY_REALIZED_PROP_CAPTURE_REPORT: path.join(c.run, 'report.json') },
    timeout: 120,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'ecology-realized-prop-capture-contract/v1' && report.passed === true,
    'Ecology realized prop capture contract failed.');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checks: report.checks,
    oreMemberCount: report.oreMemberCount,
    forageMemberCount: report.forageMemberCount,
    undergroundMemberCount: report.undergroundMemberCount,
    fallbackRockMemberCount: report.fallbackRockMemberCount,
    evidence: report.evidenceLevel
  };
});

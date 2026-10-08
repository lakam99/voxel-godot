import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ecology-forward-bounds-');
  prepare(c, 'userdata', false);
  const reportPath = path.join(c.run, 'report.json');
  const sourceSha256 = launchRecord(c, [
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
    'scripts/StructureSystem.gd',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologySourceValueLedger.gd',
    'scripts/world/EcologyDetailSourceValueBuilder.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/testing/world/EcologyForwardBoundsContract.gd',
    'scripts/testing/world/EcologyForwardBoundsContract.gd.uid',
    'tools/run-ecology-forward-bounds-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'ecology-forward-bounds-contract-launch/v1',
    evidenceLevel: 'production_source_geometry_contract',
    headed: false,
    timeoutSeconds: 45
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/EcologyForwardBoundsContract.gd'],
    env: { ECOLOGY_FORWARD_BOUNDS_REPORT: reportPath },
    timeout: 45,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  const report = read(reportPath);
  demand(report.schema === 'ecology-forward-bounds-contract/v1' && report.passed === true,
    'Ecology forward-bounds contract failed.');
  return { reportPath, checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});

import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'animated-asset-scene-state-descriptor-');
  prepare(c, 'userdata', false);
  const sourceSha256 = launchRecord(c, [
    'scripts/visual/AnimatedAssetRegistry.gd',
    'assets/generated/animated/boar_idle_walk.glb',
    'assets/generated/animated/chest_open_close.glb',
    'assets/generated/animated/deer_idle_walk.glb',
    'assets/generated/animated/door_open_close.glb',
    'assets/generated/animated/hare_idle_walk.glb',
    'scripts/testing/native_world/AnimatedAssetSceneStateDescriptorContract.gd',
    'scripts/testing/native_world/AnimatedAssetSceneStateDescriptorContract.gd.uid',
    'tools/run-animated-asset-scene-state-descriptor-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'animated-asset-scene-state-descriptor-contract-launch/v1',
    evidenceLevel: 'synthetic_scene_state_parser_contract_and_imported_asset_descriptor',
    headed: false,
    timeoutSeconds: 45
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/native_world/AnimatedAssetSceneStateDescriptorContract.gd'],
    env: { VOXEL_ANIMATED_SCENE_STATE_DESCRIPTOR_REPORT: path.join(c.run, 'report.json') },
    timeout: 45,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'animated-asset-scene-state-descriptor-contract/v1' && report.passed === true,
    'Animated asset SceneState descriptor contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});

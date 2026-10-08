import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ecology-main-retirement-smoke-');
  prepare(c, 'userdata', false);
  const stdoutPath = path.join(c.run, 'stdout.log');
  launchRecord(c, [
    'scenes/Main.tscn',
    'scenes/testing/world/EcologyMainRetirementPlaytest.tscn',
    'scripts/testing/world/EcologyMainRetirementPlaytest.gd',
    'scripts/testing/world/EcologyNativeRetirementFixture.gd',
    'scripts/testing/world/EcologyMainRetirementSmoke.gd',
    'tools/visible-world/run-ecology-main-retirement-smoke.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'ecology-main-retirement-smoke-launch/v1',
    evidenceLevel: 'fixture_main_scene_compile_load_smoke',
    headed: false,
    timeoutSeconds: 45,
    doesNotProve: 'Main startup/readiness, section installation, native receipts, source retirement, visuals, gameplay, collision, save/replay, traversal, or performance.'
  });
  const watchdog = await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/EcologyMainRetirementSmoke.gd'],
    timeout: 45,
    logPolicy: { emptyStderr: false }
  });
  const stdout = (await import('node:fs')).readFileSync(stdoutPath, 'utf8');
  demand(watchdog.functionalExitCode === 0 && stdout.includes('ECOLOGY_MAIN_RETIREMENT_SMOKE_OK'),
    'Ecology Main retirement fixture did not pass its compile/load smoke check.');
  return { evidenceLevel: 'fixture_main_scene_compile_load_smoke', stdoutPath };
});

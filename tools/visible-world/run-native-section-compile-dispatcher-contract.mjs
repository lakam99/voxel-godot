import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'native-section-compile-dispatcher-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/world/NativeSectionCompileDispatcherContract.gd',
    'scripts/testing/world/NativeSectionCompileDispatcherContract.gd.uid',
    'scripts/testing/world/WorldStaticSectionCandidateAssemblerContract.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'native/terrain_meshing/src/native_section_compile_dispatcher.cpp',
    'native/terrain_meshing/src/native_section_compile_dispatcher.h',
    'native/terrain_meshing/src/register_types.cpp',
    'native/terrain_meshing/build/world_backend/debug/build-manifest.json',
    'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'tools/visible-world/run-native-section-compile-dispatcher-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'native-section-compile-dispatcher-contract-launch/v1',
    evidenceLevel: 'synthetic_inputs_actual_native_worker_contract',
    headed: false,
    timeoutSeconds: 90,
    doesNotProve: 'Live renderer installation, source discovery, gameplay or traversal performance.'
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/NativeSectionCompileDispatcherContract.gd'],
    env: { VOXEL_NATIVE_SECTION_COMPILE_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'native-section-compile-dispatcher-contract/v1' && report.passed === true,
    'Actual native section compile dispatcher contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});

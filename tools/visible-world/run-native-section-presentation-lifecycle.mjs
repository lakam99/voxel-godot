import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'native-section-presentation-lifecycle-');
  prepare(c, 'userdata', false);
  const sourceHashes = launchRecord(c, [
    'scripts/testing/world/WholeSectionCandidateNativeInstallFixture.gd',
    'scripts/testing/world/WholeSectionCandidateNativeInstallFixture.gd.uid',
    'scripts/MainCore.gd',
    'scripts/MainCore.gd.uid',
    'scripts/MainRuntimeTools.gd',
    'scripts/MainRuntimeTools.gd.uid',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd.uid',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd.uid',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/ChunkRenderPacketOwner.gd.uid',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'native/terrain_meshing/src/native_section_compile_dispatcher.cpp',
    'native/terrain_meshing/src/native_section_compile_dispatcher.h',
    'native/terrain_meshing/build/world_backend/debug/build-manifest.json',
    'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'tools/visible-world/run-native-section-presentation-lifecycle.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'native-section-pending-presentation-lifecycle-launch/v1',
    evidenceLevel: 'headed_synthetic_producer_native_renderer_lifecycle_contract',
    headed: true,
    timeoutSeconds: 120,
    doesNotProve: 'Live Main provider census, ordinary-world startup or streaming, candidate-specific rasterization, unobscured pixel visibility, gameplay collision/interactions, save/replay, or runtime performance.'
  });
  await phaseRun(c, {
    args: ['--verbose', '--script', 'res://scripts/testing/world/WholeSectionCandidateNativeInstallFixture.gd'],
    env: {
      VOXEL_WHOLE_SECTION_NATIVE_LIFECYCLE_ONLY: '1',
      VOXEL_NATIVE_SECTION_LIFECYCLE_REPORT: path.join(c.run, 'report.json')
    },
    timeout: 120,
    // Godot's Vulkan loader can emit this exact, non-fatal registry warning on
    // Windows even when the renderer and native backend initialize normally.
    // Keep all other engine diagnostics fatal.
    logPolicy: {
      emptyStderr: false,
      expectedError: 'WARNING: GENERAL - Message Id Number: 0 | Message Id Name: Loader Message',
      expectedCount: 1
    }
  });
  stable(c.project, sourceHashes);
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'native-section-pending-presentation-lifecycle/v1' && report.passed === true,
    'Headed synthetic native section lifecycle fixture failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});

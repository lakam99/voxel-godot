import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'whole-section-candidate-native-install-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/world/WholeSectionCandidateNativeInstallFixture.gd',
    'scripts/MainRuntimeTools.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'tools/visible-world/run-whole-section-candidate-native-install.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'whole-section-candidate-native-install-launch/v1',
    evidenceLevel: 'headed_synthetic_production_candidate_installed_by_native_chunk_renderer',
    headed: true,
    timeoutSeconds: 120,
    doesNotProve: 'Real producer parity, world streaming, collision/interactions, save/replay, gameplay visuals, or runtime performance.'
  });
  await phaseRun(c, {
    args: ['--script', 'res://scripts/testing/world/WholeSectionCandidateNativeInstallFixture.gd'],
    env: { VOXEL_WHOLE_SECTION_NATIVE_INSTALL_REPORT: path.join(c.run, 'report.json') },
    timeout: 120,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'whole-section-candidate-native-install/v1' && report.passed === true,
    'Headed native whole-section install fixture failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});

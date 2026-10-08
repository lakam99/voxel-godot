import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ecology-native-visual-retirement-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/world/EcologyNativeRetirementFixture.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologySectionValueAdapter.gd.uid',
    'scripts/world/EcologySourceValueLedger.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/ActiveRemovedPropsSnapshot.gd',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'tools/visible-world/run-ecology-native-visual-retirement.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'ecology-native-visual-retirement-launch/v1',
    evidenceLevel: 'headed_ecology_native_receipt_gated_visual_retirement',
    headed: true,
    timeoutSeconds: 180,
    doesNotProve: 'Normal-world Main provider composition, visual parity, real harvest/save replay, collision response, or runtime performance.'
  });
  await phaseRun(c, {
    args: ['--script', 'res://scripts/testing/world/EcologyNativeRetirementFixture.gd'],
    env: { VOXEL_ECOLOGY_NATIVE_RETIREMENT_REPORT: path.join(c.run, 'report.json') },
    timeout: 180,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'ecology-native-visual-retirement/v1' && report.passed === true,
    'Headed native Ecology visual retirement fixture failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel, doesNotProve: report.doesNotProve };
});

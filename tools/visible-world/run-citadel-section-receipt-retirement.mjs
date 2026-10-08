import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'citadel-section-receipt-retirement-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/buildings/CitadelSectionReceiptRetirementFixture.gd',
    'scripts/world/CitadelPublicationService.gd',
    'scripts/world/CitadelSectionGeometryAdapter.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'tools/visible-world/run-citadel-section-receipt-retirement.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'citadel-section-receipt-retirement-launch/v1',
    evidenceLevel: 'headed_native_renderer_receipt_gates_synthetic_Citadel_visual_retirement',
    headed: true,
    timeoutSeconds: 120,
    doesNotProve: 'Normal-world Citadel membership/packet capture, multi-section retirement, gameplay collision/doors/navigation, save/reload parity, startup readiness or performance.'
  });
  await phaseRun(c, {
    args: ['--script', 'res://scripts/testing/buildings/CitadelSectionReceiptRetirementFixture.gd'],
    env: { VOXEL_CITADEL_SECTION_RECEIPT_RETIREMENT_REPORT: path.join(c.run, 'report.json') },
    timeout: 120,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.schema === 'citadel-section-receipt-retirement-fixture/v1' && report.passed === true,
    'Headed native Citadel section receipt and retirement fixture failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel };
});

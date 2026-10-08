import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), {
    outputdirectory: '',
    godotexe: '',
    projectpath: '',
    compileonly: false
  });
  const compileOnly = o.compileonly === true || String(o.compileonly).toLowerCase() === 'true';
  const c = context(o, compileOnly
    ? 'ordinary-structure-native-section-compile-'
    : 'ordinary-structure-native-section-receipt-');
  prepare(c, 'userdata', false);
  const hashes = launchRecord(c, [
    'scripts/world/StaticGeometryOwnerCompletion.gd',
    'scripts/world/CitadelPublicationService.gd',
    'scripts/world/CitadelSectionGeometryAdapter.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologyWorldSupportIndex.gd',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'scripts/testing/world/OrdinaryStructureNativeSectionReceiptFixture.gd',
    'scripts/MainChunkTerrain.gd',
    'scripts/StructureSystem.gd',
    'scripts/world/OrdinaryStructureBlockVisualRecipe.gd',
    'scripts/world/OrdinaryStructureStaticSectionProvider.gd',
    'scripts/world/OrdinaryStructureSectionGeometryAdapter.gd',
    'scripts/world/OrdinaryStructureVisualSourceCapture.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticSectionPresentationMembers.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'tools/visible-world/run-ordinary-structure-native-section-receipt.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: compileOnly
      ? 'ordinary-structure-native-section-compile-launch/v1'
      : 'ordinary-structure-native-section-receipt-launch/v1',
    evidenceLevel: compileOnly
      ? 'headless_gdscript_compile_load_smoke_only'
      : 'headed_production_ordinary_section_candidate_installed_by_native_renderer',
    headed: !compileOnly,
    timeoutSeconds: compileOnly ? 90 : 120,
    doesNotProve: compileOnly
      ? 'Candidate assembly, native receipt, visual retirement, collision-owner preservation, gameplay, save/reload or performance.'
      : 'Full-world provider roster, terrain/ecology/Citadel co-coverage, generated-town production layout, player interaction action, save/reload, durable edit/tombstone replay, normal startup/loading, traversal, visual parity beyond the fixture member or runtime performance. Unload/replay and identical recipe-body replacement are isolated renderer lifecycle evidence.'
  });
  const reportPath = path.join(c.run, 'report.json');
  await phaseRun(c, {
    args: [...(compileOnly ? ['--headless'] : []), '--script',
      'res://scripts/testing/world/OrdinaryStructureNativeSectionReceiptFixture.gd'],
    env: {
      VOXEL_ORDINARY_STRUCTURE_NATIVE_RECEIPT_REPORT: reportPath,
      VOXEL_ORDINARY_STRUCTURE_NATIVE_RECEIPT_COMPILE_ONLY: compileOnly ? '1' : '0'
    },
    timeout: compileOnly ? 90 : 120,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, hashes);
  if (compileOnly) return { evidenceLevel: 'headless_gdscript_compile_load_smoke_only' };
  const report = read(reportPath);
  demand(report.schema === 'ordinary-structure-native-section-receipt-fixture/v1'
    && report.passed === true,
  'Headed ordinary structure native section receipt fixture failed.');
  return { reportPath, checkCount: report.checkCount, evidenceLevel: report.evidenceLevel };
});

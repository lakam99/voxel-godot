import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ecology-main-tree-section-receipt-');
  prepare(c, 'userdata', true);
  const seed = 'ecology-main-retirement-stage5';
  const reportPath = path.join(c.run, 'report.json');
  const progressPath = path.join(c.run, 'progress.json');
  const sourceSha256 = launchRecord(c, [
    'scenes/Main.tscn',
    'scripts/Main.gd',
    'scripts/MainCore.gd',
    'scripts/MainPlaytestTools.gd',
    'scripts/MainPropFactory.gd',
    'scripts/MainRuntimeTools.gd',
    'scripts/MainChunkTerrain.gd',
    'scripts/MainSetupScene.gd',
    'scripts/world/GameLaunchOptions.gd',
    'scripts/environment/TreePublicationQueue.gd',
    'scripts/environment/TreeRuntimeRequestBuilder.gd',
    'scripts/environment/TreeSpawnService.gd',
    'scripts/environment/TreeEcologySampler.gd',
    'scripts/environment/ProceduralTreeRecipeBuilder.gd',
    'scripts/visual/ProceduralTreeVisualFactory.gd',
    'scripts/world/TreeSectionValueAdapter.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologySourceValueLedger.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/terrain/TerrainSectionShadowPublisher.gd',
    'scripts/world/OrdinaryStructureStaticSectionProvider.gd',
    'scripts/world/OrdinaryStructureSectionGeometryAdapter.gd',
    'resources/visual/procedural_tree_branch.gdshader',
    'resources/visual/procedural_tree_foliage.gdshader',
    'scenes/testing/world/EcologyMainTreeSectionReceiptPlaytest.tscn',
    'scripts/testing/world/EcologyMainTreeSectionReceiptPlaytest.gd',
    'tools/visible-world/run-ecology-main-tree-receipt.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h'
  ], {
    schema: 'ecology-main-tree-section-receipt-launch/v1',
    evidenceLevel: 'headed_Main_production_tree_queue_ecology_coordinator_native_receipt_lifecycle',
    seed,
    tutorialLaunchOption: '-SkipTutorial',
    headed: true,
    timeoutSeconds: 900,
    demandMode: 'exact resident terrain mesh callback replay for compiler-owned tree sections; publication lifecycle diagnostic, not traversal',
    doesNotProve: 'Global startup readiness, player traversal, harvest/save/reload, unload/replay, full ecology parity, or performance.'
  });
  await phaseRun(c, {
    args: ['--resolution', '1280x720',
      'res://scenes/testing/world/EcologyMainTreeSectionReceiptPlaytest.tscn', '--', '-SkipTutorial'],
    env: {
      VOXEL_PLAYTEST: '1',
      VOXEL_TEST_SEED: seed,
      VOXEL_ECOLOGY_TREE_RECEIPT_REPORT: reportPath,
      VOXEL_ECOLOGY_TREE_RECEIPT_PROGRESS: progressPath
    },
    timeout: 900,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  const report = read(reportPath);
  demand(report.schema === 'ecology-main-tree-section-receipt/v1'
    && report.passed === true && report.tutorialSkipped === true,
  'Headed Main tree section receipt lifecycle diagnostic failed.');
  demand(report.tree.sections.length >= 2
    && report.checks.all_owning_sections_have_current_native_receipt_for_exact_tree_revision?.passed === true
    && report.checks.same_tree_body_and_enabled_collider_survive_visual_retirement?.passed === true,
  'Tree receipt closure, exact source membership, or gameplay-owner retention was not proven.');
  return {
    reportPath,
    progressPath,
    checkCount: report.checkCount,
    seed: report.seed,
    worldId: report.worldId,
    sourceId: report.tree.sourceId,
    propId: report.tree.propId,
    sections: report.tree.sections,
    artifactGeneration: report.tree.artifactGeneration,
    sourceRevision: report.tree.sourceRevision,
    globalStartup: report.globalStartup,
    evidenceLevel: report.evidenceLevel,
    mode: report.mode,
    doesNotProve: report.doesNotProve
  };
});

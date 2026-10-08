import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable, git } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '', timeoutseconds: 1400 }, ['selectorsmoke', 'sectionpreflight']);
  const selectorSmoke = Boolean(o.selectorsmoke);
  const sectionPreflight = Boolean(o.sectionpreflight);
  const timeoutSeconds = selectorSmoke ? 45 : Math.max(30, Math.min(1400, Number(o.timeoutseconds) || 1400));
  const c = context(o, 'citadel-nonempty-section-receipt-');
  prepare(c, 'userdata', false);
  const sourceSha256 = launchRecord(c, [
    'scripts/world/StaticGeometryOwnerCompletion.gd',
    'scripts/world/StaticGeometryOwnerSectionSlice.gd',
    'scripts/world/OrdinaryStructureStaticSectionProvider.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/EcologyWorldSupportIndex.gd',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'scripts/world/CompiledTreeSectionArtifact.gd',
    'scripts/world/CompiledTreeSectionArtifact.gd.uid',
    'scripts/world/EcologyDetailSourceValueBuilder.gd',
    'scripts/world/EcologyDetailSourceValueBuilder.gd.uid',
    'scripts/world/StaticRenderMaterialFingerprint.gd',
    'scripts/world/StaticRenderMaterialFingerprint.gd.uid',
    'scripts/world/EcologyProducerCatalogContext.gd',
    'scripts/world/EcologySourceValueLedger.gd',
    'scripts/world/TreeSectionValueAdapter.gd',
    'scripts/world/VisibleWorldDemandController.gd',
    'scripts/world/VisibleSectionSupportLeaseBridge.gd',
    'scripts/world/VisibleSectionSupportLeaseBridge.gd.uid',
    'scripts/terrain/AuthoritativeTerrainSectionSnapshot.gd',
    'scripts/terrain/AuthoritativeTerrainSectionSnapshot.gd.uid',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/terrain/TerrainSectionShadowPublisher.gd',
    'scripts/testing/buildings/CitadelNonemptySectionReceiptFixture.gd',
    'scripts/Main.gd',
    'scripts/MainCore.gd',
    'scripts/MainPlaytestTools.gd',
    'scripts/MainRuntimeTools.gd',
    'scripts/MainSetupScene.gd',
    'scripts/StructureSystem.gd',
    'scripts/NpcSystem.gd',
    'scripts/world/CitadelPublicationService.gd',
    'scripts/world/CitadelLegacySectionVisualIndex.gd',
    'scripts/world/CitadelTerrainAdmission.gd',
    'scripts/world/CitadelSiteField.gd',
    'scripts/world/CitadelSiteBuildQueue.gd',
    'scripts/world/CitadelPublicationPlan.gd',
    'scripts/world/CitadelSectionGeometryAdapter.gd',
    'scripts/world/StaticTranslucentMeshPreparation.gd',
    'scripts/world/StaticTranslucentMeshPreparation.gd.uid',
    'scripts/world/GeneratedStructureRuntimeBindings.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingSpatialDependencies.gd',
    'scripts/buildings/MasonryDescriptorGeometry.gd',
    'scripts/buildings/BuildingSourceRecordBinding.gd',
    'scripts/buildings/BuildingSourceRecordBinding.gd.uid',
    'scripts/buildings/BuildingScenePublicationJob.gd',
    'scripts/buildings/FurnishingPublisher.gd',
    'scripts/buildings/FurnishingVisualRecipe.gd',
    'scripts/buildings/FurnishingVisualRecipe.gd.uid',
    'scripts/buildings/BuildingPartPublisher.gd',
    'scripts/buildings/BuildingWindowVisualRecipe.gd',
    'scripts/buildings/BuildingWindowVisualRecipe.gd.uid',
    'scripts/buildings/BuildingDoorSectionCapture.gd',
    'scripts/buildings/BuildingDoorSectionCapture.gd.uid',
    'scripts/buildings/BuildingDoorGeometry.gd',
    'scripts/buildings/BuildingStaticBatchFlush.gd',
    'scripts/buildings/BuildingMeshBatchUpload.gd',
    'scripts/buildings/BuildingPart.gd',
    'scripts/buildings/BuildingPart.gd.uid',
    'scripts/environment/TreePublicationQueue.gd',
    'scripts/environment/BiomeEnvironmentCatalog.gd',
    'scripts/environment/BiomeEnvironmentCatalog.gd.uid',
    'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd',
    'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd.uid',
    'scripts/environment/TreeRequestAdmission.gd',
    'scripts/environment/TreeRequestAdmission.gd.uid',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/PreparedStaticContributorLedger.gd',
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
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'scripts/testing/AutomatedTestOverlay.gd',
    'tools/lib/building-runner.mjs',
    'tools/visible-world/run-citadel-nonempty-section-receipt.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'citadel-nonempty-section-receipt-launch/v1',
    evidenceLevel: selectorSmoke ? 'headless_citadel_selector_smoke' : sectionPreflight ? 'renderer_backed_real_citadel_full_section_roster_preflight' : 'headed_real_citadel_source_plan_candidate_native_receipt_visual_ack',
    headed: !selectorSmoke,
    timeoutSeconds,
    doesNotProve: 'Normal menu startup, full multi-provider world roster, all Citadel parts, player interactions, save/reload or broad gameplay performance. Native mode covers only the measured root-part owner closure and renderer lifecycle.'
  });
  await phaseRun(c, {
    args: [...(selectorSmoke ? ['--headless'] : []), '--script', 'res://scripts/testing/buildings/CitadelNonemptySectionReceiptFixture.gd'],
    env: {
      VOXEL_CITADEL_NONEMPTY_SECTION_REPORT: path.join(c.run, 'report.json'),
      VOXEL_CITADEL_NONEMPTY_SECTION_SELECTOR_SMOKE: selectorSmoke ? '1' : '0',
      VOXEL_CITADEL_NONEMPTY_SECTION_PREFLIGHT: sectionPreflight ? '1' : '0'
    },
    timeout: timeoutSeconds,
    live: true, membership: true,
    headedTest: selectorSmoke || sectionPreflight ? undefined : {
      runnerId: 'citadel-nonempty-section-receipt',
      progressPath: path.join(c.run, 'progress.txt'),
      phaseMarkerPath: path.join(c.run, 'phase-marker.json'),
      staleProgressTimeoutMs: 45000,
      captureMode: 'godot_viewport', completionHandshake: true,
      sourceIdentity: {
        branch: git(c.project, 'branch', '--show-current').toString().trim(),
        head: git(c.project, 'rev-parse', 'HEAD').toString().trim(), sourceSha256
      }
    },
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  const report = read(path.join(c.run, 'report.json'));
  const expectedSchema = selectorSmoke ? 'citadel-nonempty-selector-smoke/v1' : sectionPreflight ? 'citadel-nonempty-section-preflight/v1' : 'citadel-nonempty-section-receipt-fixture/v1';
  demand(report.schema === expectedSchema && report.passed === true,
    selectorSmoke ? 'Headless Citadel section selector smoke failed.' : sectionPreflight ? 'Renderer-backed real Citadel complete section roster preflight failed.' : 'Headed actual nonempty Citadel section receipt fixture failed.');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel, source: report.source };
});

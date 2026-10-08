import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable, integer, git } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), {
    outputdirectory: '', godotexe: '', projectpath: '',
    seed: 'ecology-main-retirement-stage5', timeoutseconds: '960',
    startupwaitseconds: '300'
  });
  const timeoutSeconds = integer(o.timeoutseconds, 360, 1800, 'TimeoutSeconds');
  const startupWaitSeconds = integer(o.startupwaitseconds, 1, 1500, 'StartupWaitSeconds');
  const c = context(o, 'main-section-cohabitation-gate-');
  prepare(c, 'userdata', true);
  const reportPath = path.join(c.run, 'report.json');
  const progressPath = path.join(c.run, 'progress.json');
  const sourceSha256 = launchRecord(c, [
    'project.godot', 'scripts/testing/AutomatedTestOverlay.gd', 'tools/lib/headed-test-evidence.mjs',
    'scenes/Main.tscn',
    'scripts/Main.gd', 'scripts/MainCore.gd', 'scripts/MainChunkTerrain.gd',
    'scripts/MainPropFactory.gd', 'scripts/MainRuntimeTools.gd',
    'scripts/MainPlaytestTools.gd', 'scripts/perf/RuntimePerformanceMonitor.gd',
    'scripts/MainInteractionFlow.gd',
    'scripts/visual/AnimatedAssetRegistry.gd',
    'scripts/visual/VisualAssetRegistry.gd',
    'scripts/visual/ActiveVisualAssetSnapshot.gd',
    'scripts/environment/BiomeEnvironmentCatalog.gd',
    'scripts/environment/BiomeEnvironmentProfile.gd',
    'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd',
    'scripts/MainSetupScene.gd', 'scripts/world/GameLaunchOptions.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/StaticGeometryOwnerCompletion.gd',
    'scripts/buildings/BuildingPartPublisher.gd',
    'scripts/buildings/BuildingWindowVisualRecipe.gd',
    'scripts/buildings/BuildingWindowVisualRecipe.gd.uid',
    'scripts/buildings/FurnishingPublisher.gd',
    'scripts/buildings/FurnishingVisualRecipe.gd',
    'scripts/buildings/FurnishingVisualRecipe.gd.uid',
    'scripts/buildings/BuildingDoorSectionCapture.gd',
    'scripts/buildings/BuildingDoorSectionCapture.gd.uid',
    'scripts/buildings/BuildingDoorGeometry.gd',
    'scripts/buildings/BuildingSourceRecordBinding.gd',
    'scripts/buildings/BuildingStaticBatchFlush.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/EcologyProducerDomain.gd',
    'scripts/world/EcologyProducerCatalogContext.gd',
    'scripts/StructureSystem.gd',
    'scripts/world/EcologyWorldSupportIndex.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'scripts/world/CompiledTreeSectionArtifact.gd',
    'scripts/world/OwnedValueArtifactRetirement.gd',
    'scripts/environment/TreePublicationQueue.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/OrdinaryStructureStaticSectionProvider.gd',
    'scripts/world/EcologySectionValueAdapter.gd',
    'scripts/world/CitadelPublicationService.gd',
    'scripts/world/CitadelPublicationPlan.gd',
    'scripts/world/CitadelSectionGeometryAdapter.gd',
    'scripts/world/StaticTranslucentMeshPreparation.gd',
    'scripts/world/StaticTranslucentMeshPreparation.gd.uid',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/terrain/TerrainSectionShadowPublisher.gd',
    'scripts/testing/world/MainSectionCohabitationGate.gd',
    'scripts/testing/world/StaticSectionAdmissionDiagnostics.gd',
    'tools/visible-world/run-main-section-cohabitation-gate.mjs',
    'tools/lib/building-runner.mjs', 'tools/run-godot-scene-watchdog.mjs',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'native/terrain_meshing/src/native_section_compile_dispatcher.cpp',
    'native/terrain_meshing/src/native_section_compile_dispatcher.h',
    'native/terrain_meshing/src/native_tree_geometry_dispatcher.cpp',
    'native/terrain_meshing/src/native_tree_geometry_dispatcher.h',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll'
  ], {
    schema: 'main-section-cohabitation-gate-launch/v1',
    evidenceLevel: 'headed_real_Main_same_production_candidate_terrain_building_ecology_native_receipt',
    seed: o.seed, tutorialLaunchOption: '-SkipTutorial', headed: true,
    timeoutSeconds, startupWaitSeconds,
    candidateRequirement: 'One current installed production candidate with nonempty geometry manifest ranges from terrain, ordinary or blueprint building, and ecology/static-prop provider; all four registered providers current.',
    acceptanceBoundary: 'Candidate generation, census digest, content manifest digest, source revisions, native installed slot, current coordinator receipt, demand-installed state, and provider acknowledgement settlement must agree.',
    doesNotProve: 'Traversal/visual parity, collision or interaction parity, unload/replay, save/reload, or runtime performance.'
  });
  await phaseRun(c, {
    args: ['--headless', '--check-only', '--script', 'res://scripts/testing/world/MainSectionCohabitationGate.gd'],
    timeout: 90, prefix: 'parse-',
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  await phaseRun(c, {
    args: ['--resolution', '1280x720', '--script', 'res://scripts/testing/world/MainSectionCohabitationGate.gd', '--', '-SkipTutorial'],
    env: {
      VOXEL_PLAYTEST: '1', VOXEL_TEST_SEED: o.seed,
      VOXEL_MAIN_SECTION_COHABITATION_STARTUP_WAIT_SECONDS: String(startupWaitSeconds),
      VOXEL_MAIN_SECTION_COHABITATION_REPORT: reportPath,
      VOXEL_MAIN_SECTION_COHABITATION_PROGRESS: progressPath
    },
    timeout: timeoutSeconds, live: true, membership: true,
    headedTest: {
      runnerId: 'main-section-cohabitation-gate', progressPath,
      captureMode: 'godot_viewport',
      completionHandshake: true,
      sourceIdentity: { branch: git(c.project, 'branch', '--show-current').toString().trim(),
        head: git(c.project, 'rev-parse', 'HEAD').toString().trim(), seed: o.seed,
        tutorialLaunchOption: '-SkipTutorial', sourceSha256 }
    },
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  const report = read(reportPath);
  const visualEvidencePath = path.join(c.run, 'he', 'e.json');
  const headedEvidence = read(visualEvidencePath);
  demand(report.schema === 'main-section-cohabitation-gate/v1'
    && report.passed === true && report.gameplayAcceptance === false,
  'Headed Main production section cohabitation gate failed.');
  const check = name => report.checks.find(row => row.name === name);
  demand(check('same_current_production_candidate_contains_terrain_building_and_ecology')?.passed === true
    && check('candidate_generation_digest_and_current_revisions_match_native_receipt')?.passed === true
    && check('all_required_provider_install_acknowledgements_settled')?.passed === true
    && check('installed_candidate_completed_native_worker_compilation')?.passed === true,
  'The real candidate did not prove same-generation nonempty provider cohabitation, native receipt identity, and settled acknowledgements.');
  demand(headedEvidence.schema === 'voxel-automated-test-visual-evidence/v1'
    && headedEvidence.runId === headedEvidence.watchdogRunId
    && ['initial-loading', 'main-readiness', 'candidate-search', 'test-success'].every(name =>
      headedEvidence.captures.some(capture => (capture.captureId.includes(name) || capture.phase === ({
        'initial-loading': 'loading_initial_game_window', 'main-readiness': 'waiting_for_main_startup',
        'candidate-search': 'candidate_search', 'test-success': 'test_success'
      })[name]) && capture.captureType === 'godot-rendered-viewport'
        && capture.sourceIdentitySha256 === headedEvidence.sourceIdentitySha256))
    && headedEvidence.captureMode === 'godot_viewport'
    && headedEvidence.captureFailures.length === 0
    && headedEvidence.visualInspection.status === 'pending'
    && headedEvidence.visualInspection.requiredCaptureIds.length === headedEvidence.captures.length
    && headedEvidence.visualInspection.reviewedCaptureSha256.length === 0,
  'Run-bound in-game viewport checkpoints or their pending visual-inspection bindings are missing.');
  return {
    reportPath, progressPath, seed: report.seed, worldId: report.worldId,
    evidence: report.evidence, checkCount: report.checkCount,
    visualEvidencePath,
    visualInspectionStatus: headedEvidence.visualInspection.status,
    evidenceLevel: 'headed_real_Main_same_production_candidate_terrain_building_ecology_native_receipt',
    doesNotProve: report.doesNotProve
  };
});

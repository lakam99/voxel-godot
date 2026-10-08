import path from 'node:path';
import fs from 'node:fs';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable, git } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '', seed: 'atlas-71906947' });
  const c = context(o, 'terrain-fluid-section-native-receipt-');
  prepare(c, 'userdata', false);
  const reportPath = path.join(c.run, 'report.json');
  const progressPath = path.join(c.run, 'progress.json');
  const screenshotPath = path.join(c.run, 'fluid-section-native-receipt.png');
  const sourceSha256 = launchRecord(c, [
    'project.godot', 'scripts/testing/AutomatedTestOverlay.gd', 'tools/lib/headed-test-evidence.mjs',
    'scenes/Main.tscn',
    'scripts/Main.gd',
    'scripts/MainPropFactory.gd',
    'scripts/MainChunkTerrain.gd',
    'scripts/MainInteractionFlow.gd',
    'scripts/MainPlaytestTools.gd',
    'scripts/MainDiscoveryFlow.gd',
    'scripts/MainHudFlow.gd',
    'scripts/MainWorldEntities.gd',
    'scripts/MainCharacterState.gd',
    'scripts/MainGameLoop.gd',
    'scripts/MainSetupScene.gd',
    'scripts/MainSaveState.gd',
    'scripts/MainCore.gd',
    'scripts/MainInterface.gd',
    'scripts/MainRuntimeTools.gd',
    'scripts/world/GameLaunchOptions.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/TerrainVolumeService.gd',
    'scripts/WorldGenerationSystem.gd',
    'scripts/terrain/AuthoritativeTerrainSectionSnapshot.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/terrain/TerrainSectionShadowPublisher.gd',
    'scripts/TerrainMeshingService.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/PreparedStaticContributorLedger.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/environment/TreePublicationQueue.gd',
    'scripts/world/TreeRecipeSectionCompiler.gd',
    'scripts/world/CompiledTreeSectionArtifact.gd',
    'scripts/testing/world/TreeRecipeSectionCompilerContract.gd',
    'tools/visible-world/run-tree-recipe-section-compiler-contract.mjs',
    'scripts/testing/terrain/Vox43UndergroundFluidVisualRunner.gd',
    'scripts/testing/world/TerrainFluidSectionNativeReceiptPlaytest.gd',
    'scripts/testing/world/StaticSectionAdmissionDiagnostics.gd',
    'tools/visible-world/run-terrain-fluid-section-native-receipt-playtest.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs',
    'native/terrain_meshing/src/terrain_meshing_backend.cpp',
    'native/terrain_meshing/src/terrain_meshing_backend.h',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
    'addons/zylann.voxel/voxel.gdextension',
    'addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_release.x86_64.dll'
  ], {
    schema: 'terrain-fluid-section-native-receipt-launch/v1',
    evidenceLevel: 'headed_real_Main_live_fluid_census_contribution_coordinator_native_receipt',
    seed: o.seed,
    tutorialLaunchOption: '-SkipTutorial',
    headed: true,
    timeoutSeconds: 960,
    mode: 'headed Main generated-fluid receipt, real volume revision mutation during native replacement staging, exact restore, retained previous native slot and VoxelTools coverage, retry to current receipt',
    doesNotProve: 'ordinary traversal or spawn flow, terrain/fluid visual parity or retirement, save/reload parity, normal gameplay readiness, or streaming performance; a missing positive physics ray hit does not establish collision parity'
  });
  await phaseRun(c, {
    args: ['--resolution', '1280x720', '--script', 'res://scripts/testing/world/TerrainFluidSectionNativeReceiptPlaytest.gd', '--', '-SkipTutorial'],
    env: {
      VOXEL_PLAYTEST: '1',
      VOXEL_TEST_SEED: o.seed,
      VOXEL_TERRAIN_FLUID_SECTION_RECEIPT_REPORT: reportPath,
      VOXEL_TERRAIN_FLUID_SECTION_RECEIPT_PROGRESS: progressPath,
      VOXEL_TERRAIN_FLUID_SECTION_RECEIPT_SCREENSHOT: screenshotPath
    },
    timeout: 960,
    live: true,
    membership: true,
    headedTest: { runnerId: 'terrain-fluid-section-native-receipt-playtest', progressPath,
      completionHandshake: true, sourceIdentity: {
      head: git(c.project, 'rev-parse', 'HEAD').toString().trim(), seed: o.seed, sourceSha256
    } },
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceSha256);
  const report = read(reportPath);
  const progress = read(progressPath);
  const check = name => report.checks.find(row => row.name === name);
  const startupCheck = check('real_main_startup_ready_for_diagnostic');
  if (startupCheck?.passed === false) {
    const startupFailure = startupCheck.details ?? {};
    demand(startupFailure.startupReadinessDiagnosticSchema === 'main-startup-readiness-timeout/v1'
      && startupFailure.startupWait?.readinessAccepted === false
      && ['main_startup_failed', 'readiness_wait_timed_out'].includes(startupFailure.startupWait?.outcome),
    'Main startup failure was not classified with bounded wait diagnostics.');
    demand(startupFailure.readinessDomainsAtWaitEnd?.status === 'ready'
      && startupFailure.loadingStateAtWaitEnd?.status === 'ready'
      && ['ready', 'unavailable'].includes(startupFailure.sourceCaptureSchedulerAtWaitEnd?.status)
      && (typeof startupFailure.sectionCompiler?.status === 'string'
        || typeof startupFailure.sectionCompiler?.compiler?.status === 'string'),
    'Main startup failure diagnostics are missing readiness, loading, source-capture, or tree-compiler state.');
  }
  const visualEvidencePath = path.join(c.run, 'he', 'e.json');
  const visualEvidence = read(visualEvidencePath);
  demand(report.schema === 'terrain-fluid-section-native-receipt/v1'
    && report.passed === true && report.gameplayAcceptance === false,
  'Real Main fluid-to-section native receipt diagnostic failed.');
  demand(progress.stage === 'finished' && progress.details?.passed === true,
    'Final playtest progress did not report a passing result for the headed capture handshake.');
  demand(check('real_coordinator_candidate_native_receipt_and_exact_translucent_fluid_layer')?.passed === true
    && check('replacement_starts_from_current_receipt_and_unedited_generated_fluid_cell')?.passed === true
    && check('real_replacement_candidate_reaches_native_staging_before_restore_mutation')?.passed === true
    && check('source_revision_change_cancels_staged_candidate_and_retains_old_native_and_voxeltools_owners')?.passed === true
    && check('restored_source_retries_to_new_current_native_receipt_with_collision_authority_live')?.passed === true
    && check('voxeltools_fluid_comparison_and_collision_authorities_remain_live')?.passed === true,
  'A source revision change during real staged replacement did not preserve the old receipt/owner and retry to a current native receipt.');
  demand(fs.existsSync(screenshotPath), 'Fluid section receipt screenshot is missing.');
  demand(visualEvidence.schema === 'voxel-automated-test-visual-evidence/v1'
    && visualEvidence.runId === visualEvidence.watchdogRunId
    && visualEvidence.captures.some(capture => capture.runId === visualEvidence.runId
      && capture.phase === 'test_success')
    && visualEvidence.captureFailures.length === 0,
  'Run-bound final screenshot evidence is missing or its capture failed.');
  return {
    reportPath,
    progressPath,
    screenshotPath,
    visualEvidencePath,
    checkCount: report.checkCount,
    seed: report.seed,
    worldId: report.worldId,
    sectionKey: report.sectionKey,
    fluidSourceId: report.fluidSourceId,
    evidenceLevel: report.evidenceLevel,
    mode: report.mode,
    doesNotProve: report.doesNotProve
  };
});

import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, assertReport, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'ordinary-static-section-provider-');
  prepare(c, 'userdata', false);
  launchRecord(c, [
    'scripts/testing/OrdinaryStructureStaticSectionProviderContract.gd',
    'scripts/world/OrdinaryStructureStaticSectionProvider.gd',
    'scripts/world/OrdinaryStructureSectionGeometryAdapter.gd',
    'scripts/world/OrdinaryStructureVisualSourceCapture.gd',
    'scripts/StructureSystem.gd',
    'scripts/world/OrdinaryStructureBlockVisualRecipe.gd',
    'scripts/visual/StaticItemAssetRegistry.gd',
    'assets/generated/static/static-item-manifest.json',
    'assets/generated/static/workbench.glb',
    'assets/generated/static/bed.glb',
    'assets/generated/static/traderStall.glb',
    'assets/generated/static/spikeTrap.glb',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/PreparedStaticContributorLedger.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/StandaloneStructureCandidate.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticSectionPresentationMembers.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/buildings/BuildingSpatialDependencies.gd',
    'tools/visible-world/run-ordinary-static-section-provider-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ], {
    schema: 'ordinary-static-section-provider-launch/v1',
    evidenceLevel: 'synthetic_real_coordinator_and_ordinary_provider_geometry_contract',
    headed: false,
    timeoutSeconds: 90,
    doesNotProve: 'native upload or receipt, production registration, save/reload, headed visual parity, or performance.'
  });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/OrdinaryStructureStaticSectionProviderContract.gd'],
    env: { VOXEL_ORDINARY_STATIC_SECTION_PROVIDER_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false, expectedError: 'ERROR: Failed to read the root certificate store.', pattern: /SCRIPT ERROR:|Parse Error:|Compile Error:|ERROR:(?! Failed to read the root certificate store\\.)|WARNING:|leaked|resources still in use/i }
  });
  const report = read(path.join(c.run, 'report.json'));
  assertReport(report, {
    schema: 'ordinary-structure-static-section-provider-contract/v1',
    complete: true,
    passed: true
  });
  demand(report.checkCount >= 8, 'ordinary static section provider coverage unexpectedly shrank');
  return {
    reportPath: path.join(c.run, 'report.json'),
    checkCount: report.checkCount,
    evidenceLevel: report.evidenceLevel,
    doesNotProve: report.doesNotProve
  };
});

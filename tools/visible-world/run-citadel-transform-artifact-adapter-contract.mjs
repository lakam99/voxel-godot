import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from '../lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'citadel-transform-adapter-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/world/StaticGeometryOwnerCompletion.gd',
    'scripts/world/StaticGeometryOwnerSectionSlice.gd',
    'scripts/testing/world/CitadelTransformArtifactAdapterContract.gd',
    'scripts/world/CitadelSectionGeometryAdapter.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/OrdinaryStructureSectionGeometryAdapter.gd',
    'scripts/buildings/BuildingPartPublisher.gd',
    'scripts/buildings/BuildingStaticBatchFlush.gd',
    'scripts/buildings/BuildingPart.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingInstanceBuffer.gd',
    'scripts/buildings/ConstructionMaterialCatalog.gd',
    'resources/visual/building_material.gdshader',
    'tools/visible-world/run-citadel-transform-artifact-adapter-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, { schema: 'citadel-transform-artifact-adapter-launch/v1',
    evidenceLevel: 'synthetic_real_producer_adapter_assembler_contract', headed: false, timeoutSeconds: 90 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/world/CitadelTransformArtifactAdapterContract.gd'],
    env: { CITADEL_TRANSFORM_ADAPTER_REPORT: path.join(c.run, 'report.json') },
    timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.evidence === 'synthetic_real_producer_to_citadel_transform_adapter_and_assembler_contract'
    && report.passed === true
    && Object.values(report.checks ?? {}).every(value => value === true),
  'Citadel transform artifact adapter contract did not prove the complete real-producer-to-assembler slice.');
  return { reportPath: path.join(c.run, 'report.json'), checks: report.checks,
    sourcePartId: report.sourcePartId, sourceId: report.sourceId,
    sectionKey: report.sectionKey, doesNotProve: report.doesNotProve };
});

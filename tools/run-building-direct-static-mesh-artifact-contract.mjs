import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'building-direct-static-mesh-artifact-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/buildings/BuildingDirectStaticMeshArtifactContract.gd',
    'scripts/testing/buildings/BuildingDirectStaticMeshArtifactContract.gd.uid',
    'scripts/buildings/BuildingPartPublisher.gd',
    'scripts/buildings/BuildingStaticBatchFlush.gd',
    'scripts/buildings/BuildingPart.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingGoodsGeometry.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/CitadelSectionGeometryAdapter.gd',
    'scripts/world/OrdinaryStructureSectionGeometryAdapter.gd',
    'resources/visual/building_material.gdshader',
    'tools/run-building-direct-static-mesh-artifact-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  const sourceHashes = launchRecord(c, files, { schema: 'building-direct-static-mesh-artifact-launch/v1',
    evidenceLevel: 'synthetic_direct_static_mesh_artifact_contract', headed: false, timeoutSeconds: 60 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/BuildingDirectStaticMeshArtifactContract.gd'],
    env: { BUILDING_DIRECT_STATIC_MESH_ARTIFACT_REPORT: path.join(c.run, 'report.json') },
    timeout: 60,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceHashes);
  const report = read(path.join(c.run, 'report.json'));
  for (const check of [
    'bounded_flush_completed',
    'all_direct_mesh_sources_have_committed_artifacts',
    'exact_mesh_material_transform_revision_and_render_policy',
    'legacy_direct_meshes_remain_visible_and_ack_addressable',
    'artifact_only_groups_do_not_create_packet_receipts',
    'planar_ground_mesh_has_finite_render_support',
    'far_planar_mesh_adapts_from_encoded_segment_bounds',
    'collision_metadata_survives_visual_staging',
    'goods_non_box_meshes_are_included',
    'artifact_only_flush_group_count'
  ]) {
    demand(report.checks?.[check] === true, `Direct static mesh artifact contract failed: ${check}`);
  }
  demand(report.evidence === 'synthetic_direct_static_mesh_artifact_contract' && report.passed === true,
    'Direct static mesh artifact report is incomplete or failed.');
  return { reportPath: path.join(c.run, 'report.json'), checks: report.checks,
    sources: report.sources, turns: report.turns, doesNotProve: report.doesNotProve };
});

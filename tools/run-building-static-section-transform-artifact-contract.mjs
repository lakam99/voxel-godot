import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand, stable } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'building-transform-artifact-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/buildings/BuildingStaticSectionTransformArtifactContract.gd',
    'scripts/buildings/BuildingPartPublisher.gd',
    'scripts/buildings/BuildingWindowVisualRecipe.gd',
    'scripts/buildings/BuildingWindowVisualRecipe.gd.uid',
    'scripts/buildings/BuildingDoorSectionCapture.gd',
    'scripts/buildings/BuildingDoorSectionCapture.gd.uid',
    'scripts/buildings/BuildingDoorGeometry.gd',
    'scripts/buildings/BuildingStaticBatchFlush.gd',
    'scripts/buildings/BuildingBlueprint.gd',
    'scripts/buildings/ConstructionMaterialCatalog.gd',
    'scripts/buildings/BuildingInstanceBuffer.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingSourceRecordBinding.gd',
    'scripts/buildings/BuildingSourceRecordBinding.gd.uid',
    'scripts/world/CitadelPublicationPlan.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/OrdinaryStructureSectionGeometryAdapter.gd',
    'resources/visual/building_material.gdshader',
    'tools/run-building-static-section-transform-artifact-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  const sourceHashes = launchRecord(c, files, { schema: 'building-static-section-transform-artifact-launch/v1',
    evidenceLevel: 'synthetic_static_transform_producer_contract', headed: false, timeoutSeconds: 60 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/BuildingStaticSectionTransformArtifactContract.gd'],
    env: { BUILDING_STATIC_SECTION_TRANSFORM_ARTIFACT_REPORT: path.join(c.run, 'report.json') },
    timeout: process.env.BUILDING_MASONRY_SUPPORT_DIAGNOSTIC === '1' ? 180 : 60,
    logPolicy: { emptyStderr: false }
  });
  stable(c.project, sourceHashes);
  const report = read(path.join(c.run, 'report.json'));
  for (const motion of ['swing', 'raise']) {
    for (const check of ['complete_capture', 'complete_moving_and_fixed_roster',
      'pose_preserves_neutral_geometry_identity', 'collision_and_body_preserved',
      'unknown_child_keeps_capture_pending', 'moved_body_invalidates_capture',
      'complete_bundle_uses_body_anchor', 'outside_declared_motion_keeps_capture_pending',
      'visibility_policy_sealed_for_every_batch', 'mixed_batch_visibility_preserved',
      'visibility_changes_source_content_identity', 'loading_parent_does_not_rewrite_source_visibility']) {
      demand(report.checks?.[`real_${motion}_producer_${check}`] === true,
        `Door producer contract failed: ${motion}/${check}`);
    }
  }
  demand(report.evidence === 'synthetic_building_static_section_transform_artifact_contract' && report.passed === true
    && report.checks?.publication_boundary_completes_with_artifact === true
    && report.checks?.prepared_segment_source_also_commits_a_section_artifact === true
    && report.checks?.prepared_segment_artifact_preserves_flattened_instance_payload === true
    && report.checks?.invalid_artifact_commit_preserves_prior_accepted_revision === true
    && report.checks?.artifact_binds_exact_source_revision_and_owners === true
    && report.checks?.artifact_segments_are_readonly_and_exact === true
    && report.checks?.artifact_watch_receipt_accepts_exact_immutable_roster === true
    && report.checks?.artifact_watch_receipt_rejects_replaced_roster_reference === true
    && report.checks?.artifact_watch_receipt_revokes_on_material_change === true
    && report.checks?.legacy_multimesh_remains_the_only_visible_source_visual === true
    && report.checks?.real_resumable_publish_part_batch_admitted === true
    && report.checks?.real_resumable_prepared_geometry_job_advanced_under_source_context === true
    && report.checks?.real_resumable_pending_context_restored_after_every_slice === true
    && report.checks?.real_resumable_static_batch_has_exact_source_identity === true
    && report.checks?.real_resumable_publication_commits_matching_artifact_identity === true
    && report.checks?.real_resumable_pending_job_collision_authority_preserved === true
    && report.checks?.pending_job_missing_identity_fails_closed === true
    && report.checks?.mixed_good_and_rejected_groups_never_form_complete_source === true
    && report.checks?.mixed_group_rejection_retains_legacy_visuals === true
    && report.checks?.corrected_source_retries_under_fresh_complete_boundary === true
    && report.checks?.direct_door_visual_is_explicit_pending_dependency_not_empty === true
    && report.checks?.record_binding_extraction_preserves_exact_serialization_bytes === true
    && report.checks?.plan_expected_revisions_include_noncolliding_and_direct_door_sources === true
    && report.checks?.plan_signature_binds_noncolliding_source_transform === true
    && report.checks?.plan_visual_identity_replays_deterministically === true
    && report.checks?.stale_and_missing_revisions_fail_closed === true
    && report.checks?.target_battlement_uses_real_opaque_building_shader === true
    && report.checks?.material_parameter_mutation_invalidates_capture === true
    && report.checks?.mesh_resource_mutation_invalidates_capture === true
    && report.checks?.mesh_mutation_rejects_commit_without_replacing_prior_artifact === true
    && report.checks?.same_owner_cell_parent_move_rejects_capture_and_commit === true,
  'Static building transform artifact contract did not prove immutable preparation and retained legacy visibility.');
  return { reportPath: path.join(c.run, 'report.json'), checks: report.checks,
    doesNotProve: report.doesNotProve };
});

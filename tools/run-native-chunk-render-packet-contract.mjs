import path from 'node:path';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'native-chunk-packet-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/buildings/NativeChunkRenderPacketContract.gd',
    'scripts/Main.gd',
    'scripts/MainCore.gd',
    'scripts/MainRuntimeTools.gd',
    'scripts/MainPlaytestTools.gd',
    'scripts/terrain/VoxelTerrainRuntime.gd',
    'scripts/terrain/VoxelTerrainSiteGate.gd',
    'scripts/world/ChunkRenderPacketOwner.gd',
    'scripts/world/WorldStaticSectionCoordinator.gd',
    'scripts/world/StaticSectionSourceRoster.gd',
    'scripts/world/CitadelPublicationService.gd',
    'scripts/world/CitadelPublicationPlan.gd',
    'scripts/world/PreparedStaticContributorLedger.gd',
    'scripts/world/StaticInstanceAttributeBuffer.gd',
    'scripts/terrain/TerrainSectionShadowPublisher.gd',
    'scripts/world/PreparedStaticSectionSnapshotBuilder.gd',
    'scripts/world/ChunkStaticRenderSectionSnapshot.gd',
    'scripts/world/StaticRenderMeshFingerprint.gd',
    'scripts/world/NativeStaticSectionInstallSession.gd',
    'scripts/world/StaticSectionPresentationMembers.gd',
    'scripts/world/WorldStaticSectionCandidateAssembler.gd',
    'scripts/world/CitadelSectionGeometryAdapter.gd',
    'scripts/world/StaticRenderSectionGrid.gd',
    'scripts/buildings/BuildingInstanceBuffer.gd',
    'scripts/buildings/BuildingPartPublisher.gd',
    'scripts/buildings/BuildingPart.gd',
    'scripts/buildings/BuildingPart.gd.uid',
    'scripts/buildings/BuildingDoorSectionCapture.gd',
    'scripts/buildings/BuildingDoorSectionCapture.gd.uid',
    'scripts/buildings/BuildingDoorGeometry.gd',
    'scripts/buildings/BuildingStaticBatchFlush.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'native/terrain_meshing/src/chunk_render_packet_backend.cpp',
    'native/terrain_meshing/src/chunk_render_packet_backend.h',
    'native/terrain_meshing/build/world_backend/debug/build-manifest.json',
    'tools/run-native-chunk-render-packet-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  const nativeSourcePath = path.join(c.project, 'native/terrain_meshing/src/chunk_render_packet_backend.cpp');
  const sourceBytes = fs.readFileSync(nativeSourcePath);
  const sourceSha = createHash('sha256').update(sourceBytes).digest('hex');
  const nativeHeaderPath = path.join(c.project, 'native/terrain_meshing/src/chunk_render_packet_backend.h');
  const headerBytes = fs.readFileSync(nativeHeaderPath);
  const headerSha = createHash('sha256').update(headerBytes).digest('hex');
  const buildManifest = read(path.join(c.project, 'native/terrain_meshing/build/world_backend/debug/build-manifest.json'));
  const buildRecord = buildManifest.extensionSources?.find(row => row.path === 'native/terrain_meshing/src/chunk_render_packet_backend.cpp');
  const headerRecord = buildManifest.extensionHeaders?.find(row => row.path === 'native/terrain_meshing/src/chunk_render_packet_backend.h');
  demand(buildManifest.schema === 'native-world-backend-build-manifest/v1' && buildRecord?.sha256 === sourceSha
    && buildRecord.bytes === sourceBytes.length && headerRecord?.sha256 === headerSha
    && headerRecord.bytes === headerBytes.length,
  'Native GDExtension DLL build manifest does not match chunk packet backend source/header; rebuild the extension first.');
  launchRecord(c, files, { schema: 'native-chunk-render-packet-launch/v1',
    evidenceLevel: 'native_chunk_packet_and_building_flush_contract', headed: true, timeoutSeconds: 60 });
  await phaseRun(c, {
    args: ['--script', 'res://scripts/testing/buildings/NativeChunkRenderPacketContract.gd'],
    env: { NATIVE_CHUNK_PACKET_REPORT: path.join(c.run, 'report.json') },
    timeout: 60,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  const checks = report.checks || {};
  const requiredAttachmentChecks = [
    'attachment_real_refcounted_publisher_identity_is_valid',
    'attachment_ack_rejects_changed_source_boundary',
    'attachment_backend_detach_retains_cancellation_until_session_ack',
    'attachment_backend_exit_releases_installed_and_staged_external_roots',
    'attachment_body_destroy_withdraws_complete_packet',
    'attachment_candidate_body_loss_quiesces_but_retains_token',
    'attachment_candidate_body_loss_settles_with_exact_cleanup_proof',
    'attachment_candidate_body_previous_claim_cannot_withdraw_candidate',
    'attachment_candidate_pivot_loss_quiesces_but_retains_token',
    'attachment_candidate_pivot_loss_settles_with_exact_cleanup_proof',
    'attachment_candidate_pivot_previous_claim_cannot_withdraw_candidate',
    'attachment_capacity_reentry_prunes_only_dead_claim_and_restores_original_visibility',
    'attachment_claim_capacity_is_explicit_and_bounded',
    'attachment_commit_rejects_changed_neutral_body_placement',
    'attachment_commit_rejects_changed_publisher_incarnation',
    'attachment_commit_rejects_changed_source_revision',
    'attachment_different_incarnation_rollback_retains_hidden_suppression',
    'attachment_final_restore_receipts_bind_exact_true_and_false_operations',
    'attachment_final_withdraw_restores_all_claims_with_original_visibility',
    'attachment_first_commit_has_zero_legacy_native_overlap',
    'attachment_legacy_claim_is_installed_after_ack',
    'attachment_legacy_claim_is_pending_until_ack',
    'attachment_lost_replacement_pivot_retains_surviving_fixed_legacy',
    'attachment_missing_previous_is_partial_failure_with_retained_owner',
    'attachment_missing_previous_rollback_hides_replacement_and_restores_legacy',
    'attachment_out_of_range_raise_invalidates_whole_packet',
    'attachment_out_of_range_swing_invalidates_whole_packet',
    'attachment_partial_cleanup_requires_exact_token_acknowledgement',
    'attachment_partial_rollback_requires_explicit_cleanup',
    'attachment_partial_upload_preserves_previous_visible_packet',
    'attachment_pending_receipt_binds_exact_source_and_root_set',
    'attachment_pivot_destroy_withdraws_complete_packet',
    'attachment_previous_body_loss_preserves_candidate_and_ack',
    'attachment_previous_body_previous_claim_cannot_withdraw_candidate',
    'attachment_previous_pivot_loss_preserves_candidate_and_ack',
    'attachment_previous_pivot_previous_claim_cannot_withdraw_candidate',
    'attachment_provider_fallback_withdraws_whole_packet',
    'attachment_provider_first_pivot_admission_waits_for_ack',
    'attachment_provider_first_pivot_withdrawal_has_exact_cancellation_proof',
    'attachment_provider_first_revision_admission_waits_for_ack',
    'attachment_provider_first_revision_withdrawal_has_exact_cancellation_proof',
    'attachment_reclaim_clears_restoration_receipts',
    'attachment_release_accounts_all_three_retiring_roots',
    'attachment_release_drains_all_payload_and_roots',
    'attachment_release_restores_exact_legacy_before_free',
    'attachment_retirement_releases_only_actual_root_payload',
    'attachment_rollback_restores_entire_previous_root_set',
    'attachment_root_set_accepts_matching_presentation_token',
    'attachment_same_id_detach_readd_preserves_suppression_claims',
    'attachment_same_id_detach_reentry_restores_original_true_and_false',
    'attachment_staged_owner_loss_retains_explicit_abort_proof',
    'attachment_previous_staged_body_ack',
    'attachment_previous_staged_body_cancel',
    'attachment_previous_staged_pivot_ack',
    'attachment_previous_staged_pivot_cancel',
    'attachment_previous_staged_revision_ack',
    'attachment_previous_staged_revision_cancel',
    'attachment_previous_staged_detach_ack',
    'attachment_previous_staged_detach_cancel',
    'attachment_previous_pending_body_ack',
    'attachment_previous_pending_body_cancel',
    'attachment_previous_pending_pivot_ack',
    'attachment_previous_pending_pivot_cancel',
    'attachment_previous_pending_revision_ack',
    'attachment_previous_pending_revision_cancel',
    'attachment_previous_pending_detach_ack',
    'attachment_previous_pending_detach_cancel',
    'attachment_stale_owner_never_restores_moved_or_replacement_visual',
    'attachment_stale_source_can_restore_retained_previous_geometry',
    'attachment_suppressed_incarnation_reentry_becomes_geometry_owner',
    'attachment_suppressed_owner_exit_preserves_current_packet_and_surviving_claim',
    'attachment_suppression_capacity_backpressure_preserves_live_claims_and_visibility',
    'attachment_suppression_transfers_through_next_candidate_ack',
    'attachment_swing_and_raise_follow_parent_same_call_without_recompile',
    'attachment_three_batches_stage_hidden',
    'pending_ack_shows_candidate_hides_but_retains_previous_render_instances',
    'borrowed_ack_restores_original_hidden_previous_only_source_mount',
    'presentation_ack_retires_previous_render_instances',
    'native_installed_box_renderer_draw_and_mutation_isolation',
    'native_installed_array_renderer_draw_and_mutation_isolation',
    'native_installed_box_surface_material_rid_valid',
    'native_installed_array_surface_material_rid_valid',
    'native_installed_box_anchor_detached_before_rid_release',
    'native_installed_array_anchor_detached_before_rid_release',
    'native_packet_fixture_has_rendered_world_scenario',
    'native_box_candidate_rid_hidden_until_commit',
    'native_array_candidate_rid_hidden_until_commit',
  ];
  for (const name of requiredAttachmentChecks) {
    demand(checks[name] === true, `Native attachment contract missing or failed: ${name}`);
  }
  demand(report.schema === 'native_chunk_render_packet_contract/v1'
    && report.evidence === 'native_building_packet_flush_and_replay; world-owned coordinator installs a census-checked candidate through the native backend and rejects incomplete replacement census; section manifest binds actual ArrayMesh content digest and rejects mismatched resource binding; packet batches install as backend-owned RenderingServer mesh and MultiMesh RIDs under engine-managed VisualInstance3D anchors; source mesh mutation leaves installed renderer data intact; cancellation, acknowledgement, rollback, and unload retain or retire native batches; no generated-world/live-gameplay acceptance' && report.passed === true
    && checks.native_backend_attached_to_actual_chunk === true
    && checks.native_backend_rejects_wrong_owner_cell === true
    && checks.native_packet_generation_one_installs === true
    && checks.native_packet_receipt_matches_generation_one === true
    && checks.native_packet_generation_two_replaces_generation_one === true
    && checks.native_packet_stale_release_preserves_current_generation === true
    && checks.production_static_flush_installs_through_native_backend === true
    && checks['32_cell_source_owner_differs_from_28_cell_stream_chunk'] === true
    && checks.production_packet_attaches_to_actual_28_cell_stream_chunk === true
    && checks.nonzero_packet_retires_from_actual_chunk_owner === true
    && checks.native_backend_recreated_for_replacement_chunk === true
    && checks.production_static_packet_replays_after_chunk_recreation === true
    && checks.production_static_packet_release_acknowledged === true
    && checks.native_packet_republishes_after_chunk_replacement === true
    && checks.native_packet_release_acknowledged === true
    && checks.native_packet_capacity_fixture_fills_installed_limit === true
    && checks.production_flush_fails_closed_at_installed_packet_capacity === true
    && checks.main_runtime_creates_chunk_owned_native_backend === true
    && checks.main_runtime_admits_and_requests_production_chunk === true
    && checks.main_runtime_releases_backend_before_unregistering_chunk === true
    && checks.main_runtime_chunk_retirement_frees_native_owner === true
    && checks.main_runtime_preserves_retained_terrain_owner === true
    && checks.main_runtime_preserves_startup_auxiliary_terrain_owner === true
    && checks.main_runtime_retires_owner_after_dependencies_release === true
    && checks.bound_section_candidate_installs_through_native_chunk_renderer === true
    && checks.section_candidate_rejects_mesh_binding_with_different_content === true
    && checks.cancelled_section_replacement_keeps_previous_native_root_visible === true
    && checks.native_section_slot_rejects_reused_generation === true
    && checks.section_install_revalidates_registry_owner_before_upload === true
    && checks.section_owner_accepts_cross_chunk_manifest_and_retains_old_slot_on_cancel === true
    && checks.main_runtime_creates_independent_static_section_owner === true
    && checks.main_runtime_retires_static_section_owner_after_render_demand === true
    && checks.world_coordinator_candidate_installs_and_promotes_through_native_renderer === true
    && checks.native_section_slot_installs_transvoxel_shaped_array_mesh === true
    && checks.native_mesh_surface_payload_bytes_are_reserved_and_reported === true
    && checks.world_coordinator_rejects_incomplete_source_census_without_replacing_slot === true,
  'Native chunk packet lifecycle contract failed.');
  return { reportPath: path.join(c.run, 'report.json'), checks,
    nativeSourceSha256: sourceSha,
    nativeHeaderSha256: headerSha,
    evidence: 'Production building flush/replay; a mesh-content-bound section candidate installs through the native backend, preserves old content on cancellation, and rejects mismatched resource bindings and incomplete contributor census; native ArrayMesh installation with CPU mesh-array accounting; Main.gd chunk creation/retirement uses actual VoxelTerrainRuntime demand bookkeeping and a stubbed site gate; no generated-world or gameplay acceptance.' };
});

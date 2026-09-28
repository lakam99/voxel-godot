#!/usr/bin/env node

import { randomUUID } from 'node:crypto';
import { mkdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const output = join(project, 'artifacts', 'native-world-backend',
  `n3-borrowed-typed-cell-${Date.now()}-${randomUUID().slice(0, 8)}`);
const reportPath = join(output, 'report.json');
await mkdir(output, { recursive: true });

const execution = await runGodotProcess(await findGodot(), [
  '--headless', '--audio-driver', 'Dummy', '--path', project, '--script',
  'res://scripts/testing/native_world/N3BorrowedTypedCellContract.gd',
], {
  cwd: project, timeoutSeconds: 150, reportPath,
  env: { ...process.env, VOXEL_DISABLE_AUDIO_PLAYBACK: '1',
    VWB_BORROWED_TYPED_CELL_REPORT: reportPath },
});
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const checks = report.checks && typeof report.checks === 'object' ? report.checks : {};
const required = [
  'extension_exact_path_loaded', 'backend_class_registered',
  'child_requires_parent', 'real_layered_commit', 'parent_lease_ready',
  'outside_primary_page_rejected', 'parent_drain_waits_for_child',
  'second_child_refused', 'child_zero_quota_observed',
  'child_one_quota_observed', 'child_next_atomic_bounded',
  'child_shared_frame_bounded', 'absent_has_no_sparse_header',
  'present_exact_header_keys_durable',
  'present_source_layer_durable', 'present_scalar_values_durable',
  'present_payload_explicitly_omitted_durable',
  'present_exact_header_keys_overlay',
  'present_source_layer_overlay', 'present_scalar_values_overlay',
  'present_payload_explicitly_omitted_overlay',
  'overlay_precedes_durable_at_same_cell', 'explicit_air_record_differs_from_absent',
  'pending_child_requires_cancel_before_drain', 'direct_child_cancel',
  'direct_child_cancel_revokes_header', 'direct_child_retry_new_issue',
  'child_negative_quota_rejected_without_header',
  'unissued_child_issue_rejected_advance',
  'unissued_child_issue_rejected_cancel',
  'unissued_child_issue_rejected_drain',
  'drained_child_issue_rejected_while_new_active_advance',
  'drained_child_issue_rejected_while_new_active_cancel',
  'drained_child_issue_rejected_while_new_active_drain',
  'valid_child_survives_bad_issue_and_quota',
  'real_between_advance_writer', 'stale_child_fails_without_header',
  'parent_stale_after_writer', 'parent_and_child_drained_after_stale',
  'parent_cancel_revokes_child', 'cancelled_parent_still_waits_for_child_drain',
  'parent_drains_after_child', 'child_replay_rejected_after_drain',
  'parent_replay_rejected_after_drain',
];
const requiredChecksPassed = required.every(name => checks[name] === true);
const allReportedChecksPassed = Object.values(checks).length > 0
  && Object.values(checks).every(value => value === true);
const passed = execution.code === 0
  && report.schema === 'n3-borrowed-typed-cell-contract/v1'
  && report.passed === true && requiredChecksPassed && allReportedChecksPassed
  && report.drainedIssues?.parent === true && report.drainedIssues?.child === true;
process.stdout.write(`${JSON.stringify({ status: passed ? 'passed' : 'failed',
  reportPath, ownedProcessPath: execution.summaryPath,
  engineExitCode: execution.code, requiredChecksPassed, report }, null, 2)}\n`);
process.exitCode = passed ? 0 : 1;

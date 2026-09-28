#!/usr/bin/env node

import { randomUUID } from 'node:crypto';
import { mkdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runGodotProcess } from './lib/godot-process.mjs';
import { findGodot } from './lib/voxel-tool-runtime.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));
const output = join(project, 'artifacts', 'native-world-backend',
  `n3-borrowed-source-lease-${Date.now()}-${randomUUID().slice(0, 8)}`);
const reportPath = join(output, 'report.json');
await mkdir(output, { recursive: true });

const execution = await runGodotProcess(await findGodot(), [
  '--headless', '--audio-driver', 'Dummy', '--path', project, '--script',
  'res://scripts/testing/native_world/N3BorrowedSourceLeaseContract.gd',
], {
  cwd: project, timeoutSeconds: 150, reportPath,
  env: { ...process.env, VOXEL_DISABLE_AUDIO_PLAYBACK: '1',
    VWB_BORROWED_SOURCE_LEASE_REPORT: reportPath },
});
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const checks = report.checks && typeof report.checks === 'object' ? report.checks : {};
const required = [
  'two_real_leases_issued', 'global_issue_distinguishes_owners',
  'foreign_issue_cannot_advance_other_owner', 'foreign_issue_cannot_cancel_other_owner',
  'zero_quota_no_work', 'one_quota_bounded', 'active_a_drained', 'active_b_drained',
  'exact_rebegin_issues_fresh_identity', 'between_advance_writer_committed',
  'old_issue_replay_rejected_while_new_issue_active',
  'between_advance_write_revokes_old_issue', 'stale_issue_drained',
  'source_lease_reaches_ready', 'ready_pin_matches_public_sync_oracle',
  'ready_replay_idempotent', 'ready_issue_drained',
  'pending_reports_next_atomic_hint', 'shared_frame_work_cap_observed',
];
const requiredChecksPassed = required.every((name) => checks[name] === true);
const allReportedChecksPassed = Object.values(checks).length > 0
  && Object.values(checks).every((value) => value === true);
const passed = execution.code === 0
  && report.schema === 'n3-borrowed-source-lease-contract/v1'
  && report.passed === true && requiredChecksPassed && allReportedChecksPassed
  && report.drainedIssues?.a === true && report.drainedIssues?.b === true;
process.stdout.write(`${JSON.stringify({ status: passed ? 'passed' : 'failed',
  reportPath, ownedProcessPath: execution.summaryPath,
  engineExitCode: execution.code, requiredChecksPassed, report }, null, 2)}\n`);
process.exitCode = passed ? 0 : 1;

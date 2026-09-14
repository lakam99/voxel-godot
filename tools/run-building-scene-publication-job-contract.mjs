import path from 'node:path';
import { cli, options, context, prepare, launchRecord, phaseRun, read, demand } from './lib/building-runner.mjs';

cli(async () => {
  const o = options(process.argv.slice(2), { outputdirectory: '', godotexe: '', projectpath: '' });
  const c = context(o, 'scene-job-packet-order-');
  prepare(c, 'userdata', false);
  const files = [
    'scripts/testing/buildings/BuildingScenePublicationJobContract.gd',
    'scripts/buildings/BuildingScenePublicationJob.gd',
    'scripts/buildings/BuildingPublicationPreparation.gd',
    'scripts/buildings/BuildingPartPublisher.gd',
	'scripts/buildings/FurnishingPublisher.gd',
    'scripts/buildings/BuildingPublicationSource.gd',
    'tools/run-building-scene-publication-job-contract.mjs',
    'tools/lib/building-runner.mjs',
    'tools/run-godot-scene-watchdog.mjs'
  ];
  launchRecord(c, files, { schema: 'building-scene-publication-job-launch/v1', evidenceLevel: 'synthetic_scene_packet_transaction_contract', headed: false, timeoutSeconds: 90 });
  await phaseRun(c, {
    args: ['--headless', '--script', 'res://scripts/testing/buildings/BuildingScenePublicationJobContract.gd'],
    env: { BUILDING_SCENE_PUBLICATION_JOB_OUTPUT: c.run }, timeout: 90,
    logPolicy: { emptyStderr: false }
  });
  const report = read(path.join(c.run, 'report.json'));
  demand(report.failureCount === 0 && report.checks?.packet_order_transaction_canonical === true && report.checks?.packet_order_adapter_accepts_exact_canonical_transaction === true
	&& report.checks?.packet_foreground_no_background_autoselection === true
	&& report.checks?.packet_foreground_deferral_preserves_resident_receipt === true
	&& report.checks?.packet_furnishing_compiler_emits_frozen_record === true
	&& report.checks?.packet_furnishing_publishes_live_witness === true
	&& report.checks?.packet_furnishing_append_preserves_structural_receipt === true
	&& report.checks?.packet_door_compiler_admits_frozen_source === true
	&& report.checks?.packet_door_rejects_unbound_lifecycle_before_nodes === true
	&& report.checks?.packet_door_registration_precedes_exact_receipt === true
	&& report.checks?.packet_door_retirement_acknowledges_live_registered_body === true,
    'packet transaction ordering contract failed');
  return { reportPath: path.join(c.run, 'report.json'), checkCount: report.checkCount, evidence: report.evidence };
});

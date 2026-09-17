#!/usr/bin/env node
import { cli, parseOptions } from './lib/citadel-candidate-runner.mjs';
import { runTeleportPlaytest } from './run-citadel-candidate-teleport-playtest.mjs';

const runner = 'tools/run-world-streaming-maturity-journey.mjs';

await cli(import.meta.url, async argv => {
  const options = parseOptions(argv, 'journey');
  return runTeleportPlaytest({
    outputDirectory: options.outputDirectory,
    // A production-selected candidate can require several kilometres of
    // ordinary collision-backed travel after one or more site rejections.
    // Keep the release journey bounded, but give the corrected local steering
    // enough time to complete the Citadel itinerary in the same process.
    timeoutSeconds: options.timeoutSeconds ?? 2400,
    startupTimeoutSeconds: options.startupTimeoutSeconds ?? 180,
    resolution: options.resolution ?? '1920x1080',
    menuJourney: true,
    menuContinueJourney: Boolean(options.continueFrom),
    continueFrom: options.continueFrom ?? ''
  }, { runner });
});

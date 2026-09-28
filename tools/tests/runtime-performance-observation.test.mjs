import test from 'node:test';
import assert from 'node:assert/strict';
import {
  headedToolEnvironment,
  runtimePerformanceObservationArguments,
  runtimePerformanceOwnedLifecycle
} from '../lib/voxel-tool-runtime.mjs';

test('runtime performance observation is a real-time headed launch without fixed fps', () => {
  const args = runtimePerformanceObservationArguments('C:/project', 'res://scenes/testing/RuntimePerformanceObservation.tscn', {
    resolution: '1920x1080'
  });
  assert.deepEqual(args, [
    '--path', 'C:/project', '--resolution', '1920x1080', '--windowed',
    '--scene', 'res://scenes/testing/RuntimePerformanceObservation.tscn'
  ]);
  assert.equal(args.includes('--fixed-fps'), false);
  assert.equal(args.includes('--headless'), false);
  assert.throws(() => runtimePerformanceObservationArguments('C:/project', 'scene', { resolution: '800x600' }), /Resolution/);
});

test('only runtime performance wrapper declares ordinary real-time project pacing', () => {
  const leakedBase = {
    KEEP_ME: 'preserved',
    VOXEL_RUNTIME_PERF_LAUNCH_MODE: 'inherited_stale_value',
    VOXEL_ROUTE_PLAN_DETAILED_TIMING: 'inherited_expensive_diagnostic'
  };
  assert.deepEqual(headedToolEnvironment(leakedBase, 'run-runtime-performance-observation'), {
    KEEP_ME: 'preserved',
    VOXEL_RUNTIME_PERF_LAUNCH_MODE: 'ordinary_realtime_project_pacing'
  });
  assert.deepEqual(headedToolEnvironment(leakedBase, 'run-normal-runtime-performance-pass'), {
    KEEP_ME: 'preserved'
  });
  assert.deepEqual(headedToolEnvironment(leakedBase, 'run-light-shadow-visual-playtest'), {
    KEEP_ME: 'preserved'
  });
});

test('owned lifecycle requires natural root exit and authoritative zero membership', () => {
  const passing = runtimePerformanceOwnedLifecycle({
    cleanupPassed: true,
    authoritativeZeroProven: true,
    finalMembershipKnown: true,
    finalJobMemberPids: [],
    rootExited: true,
    timedOut: false,
    forcedCleanup: false,
    cleanupUnresolved: false
  });
  assert.equal(passing.passed, true);
  assert.equal(passing.zeroOwnedWork, true);
  assert.equal(passing.naturalShutdown, true);
  for (const mutation of [
    { finalJobMemberPids: [42] },
    { authoritativeZeroProven: false },
    { forcedCleanup: true },
    { timedOut: true },
    { cleanupPassed: false },
    { rootExited: false }
  ]) assert.equal(runtimePerformanceOwnedLifecycle({
    cleanupPassed: true,
    authoritativeZeroProven: true,
    finalMembershipKnown: true,
    finalJobMemberPids: [],
    rootExited: true,
    timedOut: false,
    forcedCleanup: false,
    cleanupUnresolved: false,
    ...mutation
  }).passed, false);
});

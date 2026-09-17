#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { parseLoadingMatrixOptions, runLoadingMatrix } from './lib/world-streaming-loading-matrix.mjs';

export function loadingMatrixExitCode(result) {
  if (result?.dryRun) return 0;
  if (result?.evaluationMode === 'functional-diagnostic') return result.functionalPassed === true ? 0 : 1;
  return result?.gate5LoadingAccepted === true ? 0 : 1;
}

if (process.argv.slice(2).some(argument => /^(--?help|-h)$/i.test(argument))) {
  console.log('Usage: node tools/run-world-streaming-maturity-loading-matrix.mjs -OutputDirectory artifacts/world-streaming-maturity/g5/loading-matrix-<fresh> [-EvaluationMode gate5|functional-diagnostic] [-KnownSeed gate5-loading-known-seed-v1] [-Resolution 1920x1080] [-TimeoutSeconds 330] [-DryRun]');
} else if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = await runLoadingMatrix(parseLoadingMatrixOptions(process.argv.slice(2)));
    console.log(JSON.stringify(result));
    process.exitCode = loadingMatrixExitCode(result);
  } catch (error) {
    console.error(error.stack || error.message);
    process.exitCode = 1;
  }
}

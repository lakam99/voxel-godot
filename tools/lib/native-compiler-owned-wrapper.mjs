import { spawn } from 'node:child_process';

const [encoded] = process.argv.slice(2);
if (!encoded) throw new Error('Missing native compiler wrapper request.');
const request = JSON.parse(encoded);
if (typeof request.executable !== 'string' || !Array.isArray(request.args) || typeof request.mspdbsrv !== 'string'
    || (request.vctip !== undefined && typeof request.vctip !== 'string')) {
  throw new Error('Invalid native compiler wrapper request.');
}

function run(executable, args, stdio) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { env: process.env, shell: false, windowsHide: true, stdio });
    child.once('error', reject);
    child.once('exit', (code, signal) => resolve({ code, signal }));
  });
}

// Start one run-owned telemetry server whose idle timeout is longer than the
// entire parallel build. All compiler/linker children then reuse this server
// rather than creating an uncontrolled no-argument survivor.
const vctipArgs = ['-upload:skip', '-timeout:60'];
const vctipRun = request.vctip ? run(request.vctip, vctipArgs, 'ignore') : null;
if (vctipRun) await new Promise(resolve => setTimeout(resolve, 500));
let result;
try {
  result = await run(request.executable, request.args, 'inherit');
  if (result.signal) throw new Error(`Compiler terminated by ${result.signal}`);
  process.exitCode = result.code ?? 1;
} finally {
  // The runner assigns a unique _MSPDBSRV_ENDPOINT_. Stop only that endpoint
  // before this owned root exits so Job Object zero-membership is natural.
  await run(request.mspdbsrv, ['-stop'], 'ignore');
  // Await the exact server started above. Its 60-second idle timer begins
  // after the final compiler/linker client disconnects, proving a natural
  // zero-owned-process state without killing or whitelisting telemetry.
  if (vctipRun) await vctipRun;
}

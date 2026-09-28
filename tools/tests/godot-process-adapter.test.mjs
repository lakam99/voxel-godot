import test from 'node:test';
import assert from 'node:assert/strict';
import { runGodotProcess } from '../lib/godot-process.mjs';

// Real harmless Node children exercise the launch adapter; these are tooling
// integration tests, never Godot/gameplay acceptance.
test('shared adapter preserves clean and nonzero functional results', {skip:process.platform!=='win32'}, async () => {
  const success = await runGodotProcess(process.execPath,['-e','console.log("fixture complete")'],{timeoutSeconds:5,stdio:'ignore'});
  assert.equal(success.code,0);
  assert.equal(success.summary.authoritativeZeroProven,true);
  const failure = await runGodotProcess(process.execPath,['-e','process.exit(7)'],{timeoutSeconds:5,stdio:'ignore'});
  assert.equal(failure.code,7);
  assert.equal(failure.summary.cleanupPassed,true);
});
test('fast engine-error and warning output override otherwise successful exit', {skip:process.platform!=='win32'}, async () => {
  for(const token of ['ERROR: failed fixture','WARNING: failed fixture']) {
    const result = await runGodotProcess(process.execPath,['-e',`console.error(${JSON.stringify(token)})`],{timeoutSeconds:5,stdio:'ignore'});
    assert.notEqual(result.code,0);
    assert.equal(result.summary.authoritativeZeroProven,true);
  }
});
test('split engine-error output requests bounded owned stop', {skip:process.platform!=='win32'}, async () => {
  const result = await runGodotProcess(process.execPath,['-e','process.stderr.write("ERR");setTimeout(()=>process.stderr.write("OR: failed fixture"),180);setInterval(()=>{},1000)'],{timeoutSeconds:5,stdio:'ignore'});
  assert.notEqual(result.code,0);
  assert.equal(result.summary.stopRequested,true);
  assert.equal(result.summary.timedOut,false);
  assert.equal(result.summary.authoritativeZeroProven,true);
});
test('pre-log launch failure returns the original watchdog diagnosis and receipt path', {skip:process.platform!=='win32'}, async()=>{
  const result=await runGodotProcess('C:/nonexistent-node-migration/godot.exe',[],{timeoutSeconds:5,stdio:'ignore'});
  assert.notEqual(result.code,0);assert.ok(result.summary.fatalException);assert.ok(result.summaryPath.endsWith('watchdog.json'));assert.equal(result.logReadErrors.length,2);
});

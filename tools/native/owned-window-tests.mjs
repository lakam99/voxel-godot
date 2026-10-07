import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { buildOwnedWindowHelper, NATIVE_WINDOW_HELPER_TIMEOUT_MS, parseOwnedWindowArguments,
	runNativeWindowHelper } from '../invoke-owned-game-window.mjs';

// Pure parser and fake-desktop controller tests. No action against a real window.
const base = ['-LiveOwnershipPath', 'unused.json', '-RunId', 'test-run', '-ProjectPath', '.'];
assert.equal(parseOwnedWindowArguments([...base, '--window-handle', '9007199254740993']).WindowHandle, '9007199254740993');
assert.equal(parseOwnedWindowArguments([...base, '--dx=-1000']).Dx, '-1000');
assert.throws(() => parseOwnedWindowArguments([...base, '-Key']), /Missing value/);
assert.throws(() => parseOwnedWindowArguments([...base, '-RunId', 'duplicate']), /Duplicate/);
assert.throws(() => parseOwnedWindowArguments([...base, '--unsafe']), /Unknown/);
assert.throws(() => parseOwnedWindowArguments([...base, '-WindowHandle', '1.5']), /integer/);
assert.throws(() => parseOwnedWindowArguments([]), /required/);
let helperInvocation;
const injectedResult = runNativeWindowHelper('owned-window.exe', { Action:'Capture' },
	(executable, args, options) => {
		helperInvocation = {executable, args, options};
		return {status:0, stdout:'{}', stderr:''};
	});
assert.equal(injectedResult.status, 0);
assert.equal(helperInvocation.executable, 'owned-window.exe');
assert.deepEqual(helperInvocation.args, []);
assert.equal(helperInvocation.options.timeout, NATIVE_WINDOW_HELPER_TIMEOUT_MS);
assert.equal(helperInvocation.options.shell, false);
assert.equal(helperInvocation.options.windowsHide, true);
assert.equal(helperInvocation.options.input, JSON.stringify({Action:'Capture'}));
for (const action of ['Key', 'Click', 'key', 'cLiCk']) {
	runNativeWindowHelper('owned-window.exe', { Action:action },
		(_executable, _args, options) => {
			assert.equal(Object.hasOwn(options, 'timeout'), false,
				`${action} must preserve native finally-based input release`);
			return {status:0};
		});
}
for (const action of ['Inspect', 'Focus', 'MouseLook']) {
	runNativeWindowHelper('owned-window.exe', { Action:action },
		(_executable, _args, options) => {
			assert.equal(options.timeout, NATIVE_WINDOW_HELPER_TIMEOUT_MS);
			return {status:0};
		});
}
buildOwnedWindowHelper(); // Compile the actual production entry point too; do not run it.
const result = spawnSync(buildOwnedWindowHelper({ tests: true }), [], {
  encoding: 'utf8', windowsHide: true, shell: false, timeout: 30000,
});
if (result.stdout) process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);
assert.ifError(result.error);
assert.equal(result.status, 0, 'Synthetic owned-window controller tests failed');
const report = JSON.parse(result.stdout);
assert.equal(report.passed, true);
process.stdout.write(`Node argument and timeout validation: 8 passed; native synthetic checks: ${report.testCount} passed.\n`);

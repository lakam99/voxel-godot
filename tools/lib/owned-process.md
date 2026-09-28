# Native owned-process watchdog

Import runOwnedProcess from tools/lib/owned-process.mjs or the re-export in
tools/run-godot-scene-watchdog.mjs. The async function resolves the watchdog
summary; it does not throw for a child failure.

Options:
- projectPath: working directory, defaults to the caller's current directory.
- executable: required absolute or caller-relative executable path.
- args: exact string argv excluding the executable, defaults to [].
- env: COMPLETE child environment map. Omit to inherit process.env. The helper
  passes an explicit Windows Unicode environment block; no parent variables are
  silently added. Applications can require SystemRoot or other platform entries.
- timeoutSeconds: integer 0–86400, default 300. Zero disables the execution
  deadline; stop requests and bounded terminal cleanup remain enabled.
- stdoutPath, stderrPath, summaryPath: unique, nonexistent output paths.
  Defaults are under projectPath/artifacts/watchdog/<runId>/.
- stopRequestPath, liveOwnershipPath: optional unique run-local paths.
- cleanupGraceMilliseconds: integer 0–60000, default 2000.
- finalCleanupTimeoutMilliseconds: integer 1000–300000, default 30000.

A stop file (or directory), SIGINT, SIGTERM, or monitoring failure stops only the
private job. The function returns functionalExitCode separately from cleanup:
overallExitCode is 126 for unresolved cleanup/monitoring errors, 125 for forced
cleanup (including an ordinary timeout), 124 for timeout without forced cleanup,
127 for launch failure, or the root's functional code. This preserves PS1
precedence. A root that exits zero while leaving a descendant alive is a harness
failure, even after that descendant is successfully stopped.

cleanupPassed means an unforced root exit with proven zero membership and no
cleanup errors; it can be true when functionalExitCode is nonzero.
Summary publication failure returns an emergency-v1 report with overallExitCode
126 and cleanupPassed=false, retaining functionalExitCode and the actual
authoritativeZeroProven value. One bounded retry publishes that exact emergency
object to the original summary path without overwriting an existing file. If
both attempts fail, the returned/CLI report explicitly sets
summaryPersistenceFailed=true; no durable receipt is claimed. Once publication
commits, temporary-file deletion is best effort and cannot change the published
result. A failed deletion can leave a redundant temporary hard link.
authoritativeZeroProven means a successful job-membership query found no members,
the private completion port delivered ACTIVE_PROCESS_ZERO, or the exact stable
member set was captured through validated retained handles and every handle
signaled after successful termination and job close. Closing a job or killing
the helper alone is never reported as proof.

The retained Win32 primitives were ported from the existing PS1. Creation uses
CREATE_SUSPENDED plus STARTUPINFOEX JOB_LIST and restricted HANDLE_LIST attributes;
there is no create-then-assign race and no unowned launch fallback. The helper
never terminates a target by PID, name, ancestry, or command line. Node requests
bounded operations over private pipes. EOF or helper exit closes its private
kill-on-close job. If Node dies abruptly, cleanup still occurs, but no final
summary is fabricated; consumers must reject stale live snapshots.

Native source is compiled directly using the Windows .NET Framework 64-bit C#
compiler into a content-addressed temporary cache. Neither execution nor build
invokes PowerShell or reads the old PS1. Windows 10 / Server 2016 or later is
required. Compilation and individual RPCs are bounded; terminal operations share
one monotonic cleanup deadline. Failure to obtain proof remains failure.

Live JSON retains godot-live-ownership/v1: runId, state (starting/running/stopping),
observedAtUtc, observedTickMilliseconds (Windows GetTickCount64 decimal string),
sequence, maximumAgeMilliseconds (1000), projectPath, godotExe, rootPid,
watchdogPid, watchdogCreationFileTime, members[{pid,creationFileTime}], and
authority="Windows Job Object membership". The watchdog identity is the native
helper retaining the job; additive orchestratorPid identifies Node. Creation
times are decimal strings to retain all FILETIME bits. Stopping invalidates the
record with an empty member array. A replaced runId is never overwritten.

CLI accepts camelcase, kebab-case, and PS-style switches:
node tools/run-godot-scene-watchdog.mjs -ProjectPath PATH -GodotExe EXE
-Scene res://scenes/Example.tscn -Headless -TimeoutSeconds 60
-StdoutPath OUT -StderrPath ERR -SummaryPath REPORT -- SCENE_ARGUMENTS

For generic processes, use --executable and put exact child argv after --.
SceneArguments or args also introduces remaining argv; --args=JSON_ARRAY is
supported. --env accepts a JSON environment map.

Verification: node --test tools/tests/owned-process-watchdog.test.mjs.
These are real Windows process-lifecycle tests using harmless Node fixtures.
They cover atomic pre-resume membership, quoting/Unicode/env, functional failure,
CLI status, native launch failure, timeouts, detached descendants, an unrelated
process, interactive stop, monitoring-error cleanup, no-overwrite paths, and
abrupt parent loss. They are not Godot/gameplay acceptance, and do not inject
Win32 API failures to force the retained-handle/post-close fallback branches.

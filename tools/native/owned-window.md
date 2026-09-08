# Owned game window Node port

`node tools/invoke-owned-game-window.mjs` replaces the former PowerShell entry
point. It accepts the original `-PascalCase` parameters and `--kebab-case`
equivalents. `--help` performs no native build or desktop action.

Node compiles `owned-window.cs` and `owned-window-native.cs` directly with the
Windows .NET Framework 4.x 64-bit C# compiler, then sends one JSON request to
the resulting helper over stdin. No PowerShell, shell evaluation, dependency
download, or generated executable is required in the repository. Executables
are cached under the system temporary directory by source/options hash.
This tool requires Windows and the Framework64 compiler; it fails explicitly
when either is unavailable.

## Watchdog interface

The atomically replaced live file retains `godot-live-ownership/v1`:

| Field | Required contract |
| --- | --- |
| `schema` | Exact `godot-live-ownership/v1` |
| `runId` | Exact caller-supplied run ID |
| `state` | Exact `running` |
| `authority` | Exact `Windows Job Object membership` |
| `projectPath` | Full Windows path, compared case-insensitively |
| `observedTickMilliseconds` | Decimal **string** from Windows `GetTickCount64`, neither future nor more than 1,000 ms old |
| `sequence` | Nonnegative, nondecreasing signed 64-bit integer (number or decimal string) |
| `watchdogPid` | Live watchdog/native-job-host PID |
| `watchdogCreationFileTime` | Exact positive decimal FILETIME **string** |
| `members` | Array of `{pid, creationFileTime}` from current Job Object membership; creation time is an exact decimal **string** |

The consumer independently enforces the 1,000 ms maximum, regardless of any
`maximumAgeMilliseconds` field. Other publisher fields are allowed. The
producer's PID may identify its retained native host rather than its Node
orchestrator, provided the matching creation time identifies that same host.
Do not substitute Node `performance.now()` or wall time for Windows tick time.

Files over 1 MiB are rejected. Each confirmation rereads the live file with
read/write/delete sharing, verifies the watchdog process is live and has the
exact creation identity, requires exactly one membership record matching the
window PID, verifies that member's creation identity, and inspects the window
again. Titles and PID ancestry never select or authorize a target.

## Preserved action checks

The helper requires a visible, non-minimized, unowned top-level `Engine` window
with valid physical-pixel client bounds. Automatic selection succeeds only
with exactly one matching game window. Inspect allows background windows;
Focus requests foreground and verifies the result. Capture and input require
foreground ownership and an unobscured client inside the virtual desktop.

Input requires the previously inspected HWND and expected client dimensions.
Click also checks client coordinates, point ownership, actual cursor position,
and stable bounds after cursor motion. Key/button holds reread ownership and
focus at intervals of at most 25 ms of requested sleep. A `finally` releases
only the attempted key/button, including when the down event throws or focus
is lost. DPI context is restored in an outer `finally`.

MouseLook retains its pre/post checks and a failure receipt with
`inputAttempted`, `inputSent`, and `automaticRetrySafe: false`. No failed input
is automatically retried or reversed. Live JSON remains trusted local IPC,
not a security boundary against a process able to rewrite the run directory.
`SendInput` is global: do not run concurrently with a person or another
desktop driver. These checks preserve the original race limitations of global
input; they do not make `SendInput` HWND-addressed.

Capture uses screen pixels, never `PrintWindow`, checks ownership/bounds and
occlusion again after copying, and creates the PNG with `FileMode.CreateNew`.
The result schema remains `owned-game-window-action/v1`, including PascalCase
window fields and the original action metadata. The HWND input stays a decimal
string through Node JSON so a 64-bit handle is not rounded.

## Validation without desktop actions

```text
node tools/native/owned-window-tests.mjs
```

This compiles both production and test entry points, runs seven Node parser
checks, and runs 46 synthetic C# checks against the production controller with
a fake desktop. It covers stale/future ownership, sequence regression, exact
creation identity, duplicate/missing membership, window movement, focus loss,
bounded holds, cleanup after failed input, MouseLook receipts, capture
verification ordering, argument bounds, and the native INPUT structure layout.
The tests never construct the native desktop implementation or call Windows
APIs. They do not prove live focus behavior, actual input delivery, screenshots,
or gameplay acceptance.

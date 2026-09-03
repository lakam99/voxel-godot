[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [Parameter(Mandatory = $true)][string]$GodotExe,
    [Parameter(Mandatory = $true)][string]$Scene,
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 300,
    [ValidateRange(0, 60000)][int]$CleanupGraceMilliseconds = 2000,
    [ValidateRange(1000, 300000)][int]$FinalCleanupTimeoutMilliseconds = 30000,
    [string]$StdoutPath,
    [string]$StderrPath,
    [string]$SummaryPath,
    [string]$StopRequestPath,
    [string]$LiveOwnershipPath,
    [switch]$Headless,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$SceneArguments = @()
)

$ErrorActionPreference = 'Stop'

if (-not ('VoxelGodotWatchdogNativeV2' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class VoxelGodotWatchdogProcessInfo
{
    public IntPtr ProcessHandle;
    public IntPtr ThreadHandle;
    public uint ProcessId;
    public uint ThreadId;
}

public sealed class VoxelGodotWatchdogCapturedMember
{
    public long ProcessId;
    public IntPtr ProcessHandle;
}

public static class VoxelGodotWatchdogNativeV2
{
    public static bool LastCreateReachedProcess { get; private set; }
    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, FILE_SHARE_DELETE = 4;
    const uint CREATE_NEW = 1, OPEN_EXISTING = 3, FILE_ATTRIBUTE_NORMAL = 0x80;
    const uint STARTF_USESTDHANDLES = 0x100;
    const uint CREATE_SUSPENDED = 4, CREATE_UNICODE_ENVIRONMENT = 0x400;
    const uint EXTENDED_STARTUPINFO_PRESENT = 0x80000, CREATE_NO_WINDOW = 0x08000000;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    const int JobObjectBasicProcessIdList = 3, JobObjectAssociateCompletionPortInformation = 7;
    const int JobObjectExtendedLimitInformation = 9;
    const int ERROR_MORE_DATA = 234;
    const uint WAIT_OBJECT_0 = 0, WAIT_TIMEOUT = 0x102, WAIT_FAILED = 0xFFFFFFFF;
    const uint PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x00020002;
    // PROC_THREAD_ATTRIBUTE_JOB_LIST requires Windows 10 / Windows Server 2016 or later.
    const uint PROC_THREAD_ATTRIBUTE_JOB_LIST = 0x0002000D;
    const uint JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO = 4;
    const uint SYNCHRONIZE = 0x00100000, PROCESS_QUERY_LIMITED_INFORMATION = 0x00001000;
    const uint STILL_ACTIVE = 259;
    static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);
    public const uint ForcedExitCode = 0xE0000001;

    [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES {
        public int nLength; public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct STARTUPINFO {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct STARTUPINFOEX {
        public STARTUPINFO StartupInfo; public IntPtr lpAttributeList;
    }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION {
        public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId;
    }
    [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_ASSOCIATE_COMPLETION_PORT {
        public IntPtr CompletionKey, CompletionPort;
    }

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr a, string n);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool SetInformationJobObject(IntPtr j, int c, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION i, uint l);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool SetInformationJobObject(IntPtr j, int c, ref JOBOBJECT_ASSOCIATE_COMPLETION_PORT i, uint l);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool QueryInformationJobObject(IntPtr j, int c, IntPtr i, uint l, out uint r);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool TerminateJobObject(IntPtr j, uint e);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr CreateIoCompletionPort(IntPtr f, IntPtr p, UIntPtr k, uint t);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetQueuedCompletionStatus(IntPtr p, out uint b, out UIntPtr k, out IntPtr o, uint m);
    [DllImport("kernel32.dll")] static extern ulong GetTickCount64();
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateFileW(string n, uint a, uint s, ref SECURITY_ATTRIBUTES sa, uint d, uint f, IntPtr t);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CreateProcessW(string a, StringBuilder c, IntPtr pa, IntPtr ta,
        [MarshalAs(UnmanagedType.Bool)] bool h, uint f, IntPtr e, string d, ref STARTUPINFOEX s, out PROCESS_INFORMATION p);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool InitializeProcThreadAttributeList(IntPtr l, int c, uint f, ref IntPtr s);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool UpdateProcThreadAttribute(IntPtr l, uint f, IntPtr a, IntPtr v, IntPtr s, IntPtr p, IntPtr r);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr l);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h, uint m);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetExitCodeProcess(IntPtr p, out uint e);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a,
        [MarshalAs(UnmanagedType.Bool)] bool i, uint p);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint GetProcessId(IntPtr p);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool IsProcessInJob(IntPtr p, IntPtr j, [MarshalAs(UnmanagedType.Bool)] out bool r);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetProcessTimes(IntPtr p, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CloseHandle(IntPtr h);

    static Win32Exception Error(string operation) {
        return new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed");
    }
    public static IntPtr CreateKillOnCloseJob() {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw Error("CreateJobObjectW");
        var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref limits,
            (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)))) {
            int error = Marshal.GetLastWin32Error(); CloseHandle(job);
            throw new Win32Exception(error, "SetInformationJobObject(KILL_ON_JOB_CLOSE) failed");
        }
        return job;
    }
    public static IntPtr CreateCompletionPortAndAssociateJob(IntPtr job) {
        IntPtr port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, IntPtr.Zero, UIntPtr.Zero, 1);
        if (port == IntPtr.Zero) throw Error("CreateIoCompletionPort");
        var association = new JOBOBJECT_ASSOCIATE_COMPLETION_PORT {
            CompletionKey = job, CompletionPort = port
        };
        if (!SetInformationJobObject(job, JobObjectAssociateCompletionPortInformation, ref association,
            (uint)Marshal.SizeOf(typeof(JOBOBJECT_ASSOCIATE_COMPLETION_PORT)))) {
            int error = Marshal.GetLastWin32Error(); CloseHandle(port);
            throw new Win32Exception(error, "SetInformationJobObject(AssociateCompletionPort) failed");
        }
        return port;
    }
    static SECURITY_ATTRIBUTES InheritableAttributes() {
        var a = new SECURITY_ATTRIBUTES(); a.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
        a.bInheritHandle = true; return a;
    }
    public static IntPtr CreateNewOutputFile(string path) {
        SECURITY_ATTRIBUTES a = InheritableAttributes();
        IntPtr h = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
            ref a, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (h == INVALID_HANDLE_VALUE) throw Error("CreateFileW(CREATE_NEW) for " + path); return h;
    }
    public static IntPtr OpenInheritedNullInput() {
        SECURITY_ATTRIBUTES a = InheritableAttributes();
        IntPtr h = CreateFileW("NUL", GENERIC_READ, FILE_SHARE_READ|FILE_SHARE_WRITE,
            ref a, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (h == INVALID_HANDLE_VALUE) throw Error("CreateFileW(NUL)"); return h;
    }
    public static VoxelGodotWatchdogProcessInfo CreateSuspendedProcessInAtomicJob(IntPtr job,
        string app, string commandLine, string directory, IntPtr input, IntPtr output, IntPtr error) {
        LastCreateReachedProcess = false;
        if (String.IsNullOrEmpty(commandLine) || commandLine.Length > 32766)
            throw new ArgumentException("CreateProcessW command line must contain 1 through 32766 characters.");
        IntPtr attributes = IntPtr.Zero, handles = IntPtr.Zero, jobs = IntPtr.Zero;
        PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
        bool processCreated = false, handedOff = false;
        try {
            IntPtr size = IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);
            if (size == IntPtr.Zero) throw Error("InitializeProcThreadAttributeList(size query)");
            attributes = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(attributes, 2, 0, ref size))
                throw Error("InitializeProcThreadAttributeList");
            int handleBytes = checked(IntPtr.Size * 3); handles = Marshal.AllocHGlobal(handleBytes);
            Marshal.WriteIntPtr(handles, 0, input); Marshal.WriteIntPtr(handles, IntPtr.Size, output);
            Marshal.WriteIntPtr(handles, IntPtr.Size * 2, error);
            if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(PROC_THREAD_ATTRIBUTE_HANDLE_LIST),
                handles, new IntPtr(handleBytes), IntPtr.Zero, IntPtr.Zero))
                throw Error("UpdateProcThreadAttribute(HANDLE_LIST)");
            jobs = Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobs, job);
            if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(PROC_THREAD_ATTRIBUTE_JOB_LIST),
                jobs, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                throw Error("UpdateProcThreadAttribute(JOB_LIST)");
            var si = new STARTUPINFOEX(); si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
            si.StartupInfo.dwFlags = STARTF_USESTDHANDLES; si.StartupInfo.hStdInput = input;
            si.StartupInfo.hStdOutput = output; si.StartupInfo.hStdError = error; si.lpAttributeList = attributes;
            var mutable = new StringBuilder(commandLine);
            if (!CreateProcessW(app, mutable, IntPtr.Zero, IntPtr.Zero, true,
                CREATE_SUSPENDED|CREATE_UNICODE_ENVIRONMENT|EXTENDED_STARTUPINFO_PRESENT|CREATE_NO_WINDOW,
                IntPtr.Zero, directory, ref si, out pi)) throw Error("CreateProcessW(CREATE_SUSPENDED, JOB_LIST)");
            processCreated = true;
            LastCreateReachedProcess = true;
            var result = new VoxelGodotWatchdogProcessInfo { ProcessHandle=pi.hProcess, ThreadHandle=pi.hThread,
                ProcessId=pi.dwProcessId, ThreadId=pi.dwThreadId };
            handedOff = true;
            return result;
        } finally {
            if (processCreated && !handedOff) {
                TerminateJobObject(job, ForcedExitCode);
                CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
            }
            if (attributes != IntPtr.Zero) DeleteProcThreadAttributeList(attributes);
            if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
            if (jobs != IntPtr.Zero) Marshal.FreeHGlobal(jobs);
            if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
        }
    }
    public static void ResumePrimaryThread(IntPtr thread) {
        if (ResumeThread(thread) == 0xFFFFFFFF) throw Error("ResumeThread");
    }
    public static long ProcessCreationFileTime(IntPtr process) {
        long creation, exit, kernel, user;
        if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) throw Error("GetProcessTimes");
        return creation;
    }
    public static ulong LiveTickCount() { return GetTickCount64(); }
    public static bool WaitForProcess(IntPtr process, uint milliseconds) {
        uint r = WaitForSingleObject(process, milliseconds);
        if (r == WAIT_OBJECT_0) return true; if (r == WAIT_TIMEOUT) return false;
        if (r == WAIT_FAILED) throw Error("WaitForSingleObject(process)");
        throw new InvalidOperationException("Unexpected process wait status " + r + ".");
    }
    public static uint ReadProcessExitCode(IntPtr process) {
        uint e; if (!GetExitCodeProcess(process, out e)) throw Error("GetExitCodeProcess"); return e;
    }
    public static long[] GetJobProcessIds(IntPtr job) {
        int capacity = 16;
        for (int attempt=0; attempt<10; attempt++) {
            int bytes = checked(8 + capacity * IntPtr.Size); IntPtr buffer = Marshal.AllocHGlobal(bytes);
            try {
                Marshal.WriteInt32(buffer, 0, 0); Marshal.WriteInt32(buffer, 4, 0);
                uint returned; bool ok = QueryInformationJobObject(job, JobObjectBasicProcessIdList,
                    buffer, (uint)bytes, out returned); int error = ok ? 0 : Marshal.GetLastWin32Error();
                uint assigned = (uint)Marshal.ReadInt32(buffer, 0), count = (uint)Marshal.ReadInt32(buffer, 4);
                if (!ok && error != ERROR_MORE_DATA)
                    throw new Win32Exception(error, "QueryInformationJobObject(ProcessIdList) failed");
                if (!ok || assigned > count || count > capacity) {
                    long needed = Math.Max((long)capacity*2, Math.Max((long)assigned, (long)count));
                    if (needed > 1048576) throw new InvalidOperationException("Job membership exceeded safety limit.");
                    capacity = (int)needed; continue;
                }
                var ids = new List<long>((int)count);
                for (int i=0; i<count; i++) ids.Add(Marshal.ReadIntPtr(buffer, 8+i*IntPtr.Size).ToInt64());
                return ids.ToArray();
            } finally { Marshal.FreeHGlobal(buffer); }
        }
        throw new InvalidOperationException("Job membership did not stabilize during bounded queries.");
    }
    public static void TerminateOwnedJob(IntPtr job) {
        if (!TerminateJobObject(job, ForcedExitCode)) throw Error("TerminateJobObject");
    }
    public static bool WaitForActiveProcessZero(IntPtr port, IntPtr expectedKey, uint milliseconds) {
        ulong deadline = GetTickCount64() + milliseconds;
        uint remaining = milliseconds;
        while (true) {
            uint message; UIntPtr key; IntPtr overlapped;
            bool dequeued = GetQueuedCompletionStatus(port, out message, out key, out overlapped, remaining);
            if (!dequeued) {
                int error = Marshal.GetLastWin32Error();
                if (overlapped == IntPtr.Zero && error == (int)WAIT_TIMEOUT) return false;
                throw new Win32Exception(error, "GetQueuedCompletionStatus failed");
            }
            UIntPtr expected = UIntPtr.Size == 4
                ? new UIntPtr(unchecked((uint)expectedKey.ToInt32()))
                : new UIntPtr(unchecked((ulong)expectedKey.ToInt64()));
            if (key.Equals(expected) &&
                message == JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO) return true;
            ulong now = GetTickCount64();
            if (now >= deadline) return false;
            remaining = (uint)Math.Min((ulong)UInt32.MaxValue, deadline - now);
        }
    }
    static bool SameIds(long[] left, long[] right) {
        if (left.Length != right.Length) return false;
        for (int i=0; i<left.Length; i++) if (left[i] != right[i]) return false;
        return true;
    }
    static void CloseCaptured(List<VoxelGodotWatchdogCapturedMember> members) {
        foreach (VoxelGodotWatchdogCapturedMember member in members)
            if (member.ProcessHandle != IntPtr.Zero) CloseHandle(member.ProcessHandle);
    }
    public static VoxelGodotWatchdogCapturedMember[] CaptureStableJobMembers(IntPtr job,
        int maximumAttempts, uint retryDelayMilliseconds) {
        if (maximumAttempts < 1 || maximumAttempts > 100)
            throw new ArgumentOutOfRangeException("maximumAttempts");
        string lastFailure = "membership changed during capture";
        for (int attempt=0; attempt<maximumAttempts; attempt++) {
            long[] before = GetJobProcessIds(job); Array.Sort(before);
            var captured = new List<VoxelGodotWatchdogCapturedMember>(before.Length);
            bool retry = false;
            try {
                foreach (long pidValue in before) {
                    if (pidValue <= 0 || pidValue > UInt32.MaxValue) {
                        lastFailure = "job returned an invalid process ID"; retry = true; break;
                    }
                    uint pid = (uint)pidValue;
                    IntPtr process = OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
                    if (process == IntPtr.Zero) {
                        lastFailure = "OpenProcess failed during a membership race"; retry = true; break;
                    }
                    var member = new VoxelGodotWatchdogCapturedMember { ProcessId=pidValue, ProcessHandle=process };
                    captured.Add(member);
                    uint retainedPid = GetProcessId(process);
                    bool inJob; uint state = WaitForSingleObject(process, 0);
                    if (retainedPid != pid || !IsProcessInJob(process, job, out inJob) || !inJob ||
                        state != WAIT_TIMEOUT) {
                        lastFailure = "retained process identity or job membership changed"; retry = true; break;
                    }
                }
                if (!retry) {
                    long[] after = GetJobProcessIds(job); Array.Sort(after);
                    if (SameIds(before, after)) {
                        bool revalidated = true;
                        foreach (VoxelGodotWatchdogCapturedMember member in captured) {
                            bool inJob; uint state = WaitForSingleObject(member.ProcessHandle, 0);
                            if (GetProcessId(member.ProcessHandle) != (uint)member.ProcessId ||
                                !IsProcessInJob(member.ProcessHandle, job, out inJob) || !inJob ||
                                state != WAIT_TIMEOUT) {
                                revalidated = false; break;
                            }
                        }
                        if (revalidated) {
                            long[] confirmed = GetJobProcessIds(job); Array.Sort(confirmed);
                            if (SameIds(before, confirmed)) return captured.ToArray();
                            lastFailure = "job membership changed after handle revalidation";
                        } else lastFailure = "retained handles failed final identity revalidation";
                    } else lastFailure = "job membership was not stable across capture";
                }
            } catch (Exception error) {
                lastFailure = error.Message;
            }
            CloseCaptured(captured);
            if (attempt + 1 < maximumAttempts && retryDelayMilliseconds > 0)
                System.Threading.Thread.Sleep((int)retryDelayMilliseconds);
        }
        throw new InvalidOperationException("Stable job-member capture failed: " + lastFailure);
    }
    public static uint WaitForCapturedProcessExit(IntPtr process, uint milliseconds) {
        uint wait = WaitForSingleObject(process, milliseconds);
        if (wait == WAIT_TIMEOUT)
            throw new TimeoutException("Timed out waiting for captured job process to exit.");
        if (wait == WAIT_FAILED) throw Error("WaitForSingleObject(captured process)");
        if (wait != WAIT_OBJECT_0)
            throw new InvalidOperationException("Unexpected captured-process wait status " + wait + ".");
        uint exitCode;
        if (!GetExitCodeProcess(process, out exitCode)) throw Error("GetExitCodeProcess(captured process)");
        if (exitCode == STILL_ACTIVE)
            throw new InvalidOperationException("Captured process signaled but still reports STILL_ACTIVE.");
        return exitCode;
    }
    public static void CloseNativeHandle(IntPtr handle) {
        if (handle != IntPtr.Zero && handle != INVALID_HANDLE_VALUE && !CloseHandle(handle)) throw Error("CloseHandle");
    }
    public static string BuildCommandLine(string[] arguments) {
        if (arguments == null || arguments.Length == 0) throw new ArgumentException("argv[0] is required.");
        var result = new StringBuilder();
        for (int i=0; i<arguments.Length; i++) {
            if (arguments[i] == null) throw new ArgumentException("Arguments cannot contain null.");
            if (i>0) result.Append(' '); result.Append(Quote(arguments[i]));
        }
        return result.ToString();
    }
    static string Quote(string value) {
        if (value.Length == 0) return "\"\""; bool required = false;
        foreach (char c in value) if (Char.IsWhiteSpace(c) || c == '"') { required=true; break; }
        if (!required) return value;
        var q = new StringBuilder(); q.Append('"'); int slashes=0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { q.Append('\\', checked(slashes*2+1)); q.Append('"'); slashes=0; continue; }
            if (slashes>0) { q.Append('\\', slashes); slashes=0; } q.Append(c);
        }
        if (slashes>0) q.Append('\\', checked(slashes*2)); q.Append('"'); return q.ToString();
    }
}
'@
}

function Get-PreexistingGodotEvidence {
    try { $processes = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'Godot%'" -ErrorAction Stop) }
    catch { throw "Unable to snapshot preexisting Godot identities: $($_.Exception.Message)" }
    @($processes | ForEach-Object {
        $created = $null
        try { if ($null -ne $_.CreationDate) { $created = ([datetime]$_.CreationDate).ToUniversalTime().ToString('o') } } catch {}
        $path = if ([string]::IsNullOrWhiteSpace([string]$_.ExecutablePath)) { $null } else { [string]$_.ExecutablePath }
        $complete = ($null -ne $created) -and ($null -ne $path)
        [pscustomobject][ordered]@{
            pid=[int64]$_.ProcessId; parentPid=[int64]$_.ParentProcessId; name=[string]$_.Name
            creationTimeUtc=$created; executablePath=$path
            commandLine=if ([string]::IsNullOrWhiteSpace([string]$_.CommandLine)) { $null } else { [string]$_.CommandLine }
            fullIdentity=if ($complete) { '{0}|{1}|{2}' -f [int64]$_.ProcessId,$created,$path } else { $null }
            identityComplete=[bool]$complete; authority='evidence_only_not_used_for_ownership_or_cleanup'
        }
    })
}

function Resolve-UniqueOutputPath([string]$Path, [string]$Label) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if ([IO.File]::Exists($resolved) -or [IO.Directory]::Exists($resolved)) {
        throw "$Label already exists; refusing to overwrite: $resolved"
    }
    $directory = [IO.Path]::GetDirectoryName($resolved)
    if ([string]::IsNullOrWhiteSpace($directory)) { throw "$Label has no parent directory: $resolved" }
    [void][IO.Directory]::CreateDirectory($directory)
    $resolved
}

function Write-AtomicJsonNoOverwrite([string]$Path, [string]$Json) {
    if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
        throw "SummaryPath already exists; refusing to overwrite: $Path"
    }
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path),[guid]::NewGuid().ToString('N'))
    $stream = $null
    try {
        $stream = [IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Json)
        $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true); $stream.Dispose(); $stream=$null
        [IO.File]::Move($temporary,$Path); $temporary=$null
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

$runId = [guid]::NewGuid().ToString('N')
if ([string]::IsNullOrWhiteSpace($StdoutPath)) { $StdoutPath = Join-Path ([IO.Path]::GetTempPath()) "godot-watchdog-$runId.stdout.log" }
if ([string]::IsNullOrWhiteSpace($StderrPath)) { $StderrPath = Join-Path ([IO.Path]::GetTempPath()) "godot-watchdog-$runId.stderr.log" }
if ([string]::IsNullOrWhiteSpace($SummaryPath)) { $SummaryPath = Join-Path ([IO.Path]::GetTempPath()) "godot-watchdog-$runId.summary.json" }

$resolvedProjectPath=$null; $resolvedGodotExe=$null; $resolvedStdoutPath=$null; $resolvedStderrPath=$null; $resolvedSummaryPath=$null
$exactCommandLine=$null; $launchStartedUtc=$null; $preexistingGodotProcesses=@()
$membershipEvidence=[Collections.Generic.List[object]]::new(); $cleanupErrors=[Collections.Generic.List[string]]::new()
$fatalException=$null; $monitoringException=$null
$jobHandle=[IntPtr]::Zero; $jobCompletionKey=[IntPtr]::Zero; $completionPortHandle=[IntPtr]::Zero
$processHandle=[IntPtr]::Zero; $threadHandle=[IntPtr]::Zero
$stdinHandle=[IntPtr]::Zero; $stdoutHandle=[IntPtr]::Zero; $stderrHandle=[IntPtr]::Zero
$rootPid=$null; $rootThreadId=$null; $processCreated=$false; $assignedToJob=$false; $resumed=$false
$nativeCreateReachedProcess=$false
$rootExited=$false; $functionalExitCode=$null; $timedOut=$false; $forcedCleanup=$false
$resolvedStopRequestPath=$null; $stopRequested=$false; $stopRequestedAtUtc=$null
$terminateJobAttempted=$false; $terminateJobSucceeded=$false; $membershipQueryFailed=$false
$completionZeroMessageObserved=$false; $completionZeroWaitTimedOut=$false; $cleanupUnresolved=$false
$fallbackCaptureAttempted=$false; $fallbackCaptureSucceeded=$false; $fallbackCaptureError=$null
$fallbackCapturedPids=@(); $fallbackPostCloseWaits=[Collections.Generic.List[object]]::new()
$fallbackJobClosed=$false; $fallbackZeroProven=$false; $postCloseCompletionZeroProven=$false
$fallbackRetainedWaitFailed=$false
$authoritativeZeroProven=$false; $zeroProofSource=$null
$membershipUncertaintyResolvedByZeroProof=$false; $jobCloseAttempted=$false
$finalMembershipKnown=$false; $finalJobMemberPids=@(); $overallExitCode=127
$terminalCleanupStopwatch=$null; $terminalCleanupExpired=$false

$resolvedLiveOwnershipPath=$null; $liveOwnershipCreated=$false; $liveOwnershipSequence=0
$liveOwnershipLastTick=[uint64]0; $liveOwnershipError=$null; $liveWatchdogCreation=$null

function Publish-LiveOwnership([string]$State) {
    if ($null -eq $script:resolvedLiveOwnershipPath) { return }
    $observedTick=[VoxelGodotWatchdogNativeV2]::LiveTickCount()
    $observedUtc=[datetime]::UtcNow.ToString('o')
    $rows=@(); $captured=@()
    try {
        if ($State -eq 'running') {
            # Handles are rechecked against the exact Job Object, never ancestry.
            $captured=@([VoxelGodotWatchdogNativeV2]::CaptureStableJobMembers($script:jobHandle,3,10))
            $rows=@($captured | ForEach-Object {
                [ordered]@{pid=$_.ProcessId; creationFileTime=[string][VoxelGodotWatchdogNativeV2]::ProcessCreationFileTime($_.ProcessHandle)}
            })
        }
        $script:liveOwnershipSequence++
        $snapshot=[ordered]@{
            schema='godot-live-ownership/v1'; runId=$runId; state=$State
            observedAtUtc=$observedUtc; observedTickMilliseconds=[string]$observedTick
            sequence=$script:liveOwnershipSequence; maximumAgeMilliseconds=1000
            projectPath=$resolvedProjectPath; godotExe=$resolvedGodotExe
            watchdogPid=$PID; watchdogCreationFileTime=$script:liveWatchdogCreation
            rootPid=$rootPid; members=$rows; authority='Windows Job Object membership'
        }
        $json=$snapshot | ConvertTo-Json -Depth 6 -Compress
        if (-not $script:liveOwnershipCreated) {
            Write-AtomicJsonNoOverwrite $script:resolvedLiveOwnershipPath $json
            $script:liveOwnershipCreated=$true
        } else {
            $previous=[IO.File]::ReadAllText($script:resolvedLiveOwnershipPath) | ConvertFrom-Json
            if ($previous.runId -cne $runId) { throw 'Live ownership path changed owner.' }
            $temporary=$script:resolvedLiveOwnershipPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
            try {
                Write-AtomicJsonNoOverwrite $temporary $json
                [IO.File]::Replace($temporary,$script:resolvedLiveOwnershipPath,[NullString]::Value)
            } finally {
                if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
            }
        }
        $script:liveOwnershipLastTick=$observedTick
    } catch {
        $script:liveOwnershipError=$_.Exception.Message
        throw
    } finally {
        foreach ($member in $captured) { Close-WatchdogHandle $member.ProcessHandle 'live membership handle' }
    }
}

function Assert-NoStopRequest {
    if ($null -eq $script:resolvedStopRequestPath) { return }
    if (-not $script:stopRequested -and
        ([IO.File]::Exists($script:resolvedStopRequestPath) -or [IO.Directory]::Exists($script:resolvedStopRequestPath))) {
        $script:stopRequested=$true
        $script:stopRequestedAtUtc=[datetime]::UtcNow.ToString('o')
    }
    if ($script:stopRequested) { throw 'Run-local stop requested; terminating the owned Job Object.' }
}

function Get-JobMembership([string]$Phase, [switch]$SuppressFailure) {
    try {
        $ids = [long[]][VoxelGodotWatchdogNativeV2]::GetJobProcessIds($jobHandle)
        $membershipEvidence.Add([pscustomobject][ordered]@{observedAtUtc=[datetime]::UtcNow.ToString('o');phase=$Phase;querySucceeded=$true;memberPids=@($ids);error=$null})
        [pscustomobject]@{Succeeded=$true;ProcessIds=@($ids);Error=$null}
    } catch {
        $script:membershipQueryFailed=$true; $message=$_.Exception.Message
        $membershipEvidence.Add([pscustomobject][ordered]@{observedAtUtc=[datetime]::UtcNow.ToString('o');phase=$Phase;querySucceeded=$false;memberPids=@();error=$message})
        if (-not $SuppressFailure) { throw "Job membership query failed during ${Phase}: $message" }
        [pscustomobject]@{Succeeded=$false;ProcessIds=@();Error=$message}
    }
}

function Close-WatchdogHandle([IntPtr]$Handle, [string]$Label) {
    if ($Handle -eq [IntPtr]::Zero -or $Handle -eq [IntPtr](-1)) { return }
    try { [VoxelGodotWatchdogNativeV2]::CloseNativeHandle($Handle) }
    catch { $cleanupErrors.Add("$Label close failed: $($_.Exception.Message)") }
}

function Get-TerminalCleanupRemainingMilliseconds {
    if ($null -eq $script:terminalCleanupStopwatch) {
        return [uint32]$FinalCleanupTimeoutMilliseconds
    }
    $remaining=[int64]$FinalCleanupTimeoutMilliseconds-[int64]$script:terminalCleanupStopwatch.ElapsedMilliseconds
    if ($remaining -le 0) {
        $script:terminalCleanupExpired=$true
        return [uint32]0
    }
    return [uint32][math]::Min([uint64][uint32]::MaxValue,[uint64]$remaining)
}

function Set-TerminalCleanupTimeout([string]$Phase) {
    $script:terminalCleanupExpired=$true
    $script:cleanupUnresolved=$true
    $message="Terminal cleanup deadline of ${FinalCleanupTimeoutMilliseconds}ms expired during $Phase."
    if (-not $cleanupErrors.Contains($message)) { $cleanupErrors.Add($message) }
}

function Invoke-ForcedJobTermination {
    if ($script:terminateJobAttempted) { return }
    $script:forcedCleanup=$true; $script:terminateJobAttempted=$true
    try {
        [VoxelGodotWatchdogNativeV2]::TerminateOwnedJob($script:jobHandle)
        $script:terminateJobSucceeded=$true
    } catch {
        $script:cleanupUnresolved=$true
        $cleanupErrors.Add("TerminateJobObject failed: $($_.Exception.Message)")
        return
    }
    if ($script:completionPortHandle -eq [IntPtr]::Zero) {
        $script:cleanupUnresolved=$true
        $cleanupErrors.Add('Completion-port handle was unavailable after TerminateJobObject.')
        return
    }
    $boundedWait=[uint32][math]::Max(1000,[math]::Min(10000,$CleanupGraceMilliseconds))
    $remaining=Get-TerminalCleanupRemainingMilliseconds
    if ($remaining -eq 0) {
        Set-TerminalCleanupTimeout 'forced job termination completion proof'
        return
    }
    $boundedWait=[uint32][math]::Min($boundedWait,$remaining)
    try {
        $script:completionZeroMessageObserved=[VoxelGodotWatchdogNativeV2]::WaitForActiveProcessZero(
            $script:completionPortHandle,$script:jobHandle,$boundedWait)
        if (-not $script:completionZeroMessageObserved) {
            $script:completionZeroWaitTimedOut=$true; $script:cleanupUnresolved=$true
            $cleanupErrors.Add("Timed out after ${boundedWait}ms waiting for JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO.")
        }
    } catch {
        $script:cleanupUnresolved=$true
        $cleanupErrors.Add("Completion-port cleanup wait failed: $($_.Exception.Message)")
    }
}

function Set-AuthoritativeZeroProof([string]$Source) {
    $script:authoritativeZeroProven=$true; $script:cleanupUnresolved=$false
    $script:zeroProofSource=$Source
    $script:finalMembershipKnown=$true; $script:finalJobMemberPids=@()
    if ($script:membershipQueryFailed) { $script:membershipUncertaintyResolvedByZeroProof=$true }
    for ($index=$cleanupErrors.Count-1; $index-ge 0; $index--) {
        if ($cleanupErrors[$index].Contains('Timed out after') -and
            $cleanupErrors[$index].Contains('JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO')) {
            $cleanupErrors.RemoveAt($index)
        }
    }
}

function Close-JobHandleOnce {
    if ($script:jobHandle -eq [IntPtr]::Zero) { return $true }
    $script:jobCloseAttempted=$true
    $closed=$false
    try {
        [VoxelGodotWatchdogNativeV2]::CloseNativeHandle($script:jobHandle)
        $closed=$true
        $script:jobHandle=[IntPtr]::Zero
    } catch {
        $cleanupErrors.Add("Kill-on-close job handle close failed: $($_.Exception.Message)")
    }
    return $closed
}

try {
    $resolvedProjectPath=[IO.Path]::GetFullPath($ProjectPath); $resolvedGodotExe=[IO.Path]::GetFullPath($GodotExe)
    if (-not [IO.Directory]::Exists($resolvedProjectPath)) { throw "ProjectPath does not exist: $resolvedProjectPath" }
    if (-not [IO.File]::Exists($resolvedGodotExe)) { throw "GodotExe does not exist: $resolvedGodotExe" }
    if ([string]::IsNullOrWhiteSpace($Scene)) { throw 'Scene cannot be empty.' }
    $resolvedStdoutPath=Resolve-UniqueOutputPath $StdoutPath 'StdoutPath'
    $resolvedStderrPath=Resolve-UniqueOutputPath $StderrPath 'StderrPath'
    $resolvedSummaryPath=Resolve-UniqueOutputPath $SummaryPath 'SummaryPath'
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not $paths.Add($resolvedStdoutPath) -or -not $paths.Add($resolvedStderrPath) -or -not $paths.Add($resolvedSummaryPath)) {
        throw 'StdoutPath, StderrPath, and SummaryPath must be distinct.'
    }
    if (-not [string]::IsNullOrWhiteSpace($StopRequestPath)) {
        $resolvedStopRequestPath=Resolve-UniqueOutputPath $StopRequestPath 'StopRequestPath'
        if (-not $paths.Add($resolvedStopRequestPath)) { throw 'StopRequestPath must be distinct from output files.' }
    }
    if (-not [string]::IsNullOrWhiteSpace($LiveOwnershipPath)) {
        $resolvedLiveOwnershipPath=Resolve-UniqueOutputPath $LiveOwnershipPath 'LiveOwnershipPath'
        if (-not $paths.Add($resolvedLiveOwnershipPath)) { throw 'LiveOwnershipPath must be distinct from all other outputs.' }
        $currentProcess=[Diagnostics.Process]::GetCurrentProcess()
        try { $liveWatchdogCreation=[string][VoxelGodotWatchdogNativeV2]::ProcessCreationFileTime($currentProcess.Handle) }
        finally { $currentProcess.Dispose() }
        Publish-LiveOwnership 'starting'
    }
    $preexistingGodotProcesses=Get-PreexistingGodotEvidence
    $arguments=[Collections.Generic.List[string]]::new(); $arguments.Add($resolvedGodotExe)
    if ($Headless) { $arguments.Add('--headless') }; $arguments.Add('--path'); $arguments.Add($resolvedProjectPath); $arguments.Add($Scene)
    foreach ($arg in $SceneArguments) { if ($null -eq $arg) { throw 'SceneArguments cannot contain null.' }; $arguments.Add([string]$arg) }
    $exactCommandLine=[VoxelGodotWatchdogNativeV2]::BuildCommandLine($arguments.ToArray())

    $jobHandle=[VoxelGodotWatchdogNativeV2]::CreateKillOnCloseJob()
    $jobCompletionKey=$jobHandle
    $completionPortHandle=[VoxelGodotWatchdogNativeV2]::CreateCompletionPortAndAssociateJob($jobHandle)
    $stdinHandle=[VoxelGodotWatchdogNativeV2]::OpenInheritedNullInput()
    $stdoutHandle=[VoxelGodotWatchdogNativeV2]::CreateNewOutputFile($resolvedStdoutPath)
    $stderrHandle=[VoxelGodotWatchdogNativeV2]::CreateNewOutputFile($resolvedStderrPath)
    $launchStartedUtc=[datetime]::UtcNow
    $native=[VoxelGodotWatchdogNativeV2]::CreateSuspendedProcessInAtomicJob($jobHandle,$resolvedGodotExe,$exactCommandLine,$resolvedProjectPath,$stdinHandle,$stdoutHandle,$stderrHandle)
    $processHandle=$native.ProcessHandle; $threadHandle=$native.ThreadHandle; $rootPid=[long]$native.ProcessId; $rootThreadId=[long]$native.ThreadId
    $processCreated=$true; $assignedToJob=$true
    $initial=Get-JobMembership 'assigned_before_resume'
    if ($initial.ProcessIds.Count -ne 1 -or $initial.ProcessIds[0] -ne $rootPid) { throw "Assigned job did not contain exactly suspended root $rootPid." }
    [VoxelGodotWatchdogNativeV2]::ResumePrimaryThread($threadHandle); $resumed=$true
    try {
        if ($null -eq $resolvedStopRequestPath -and $null -eq $resolvedLiveOwnershipPath) {
            $rootExited=[VoxelGodotWatchdogNativeV2]::WaitForProcess($processHandle,[uint32]($TimeoutSeconds*1000))
        } else {
            $executionWatch=[Diagnostics.Stopwatch]::StartNew()
            while (-not $rootExited) {
                Assert-NoStopRequest
                if ($null -ne $resolvedLiveOwnershipPath -and
                    ([VoxelGodotWatchdogNativeV2]::LiveTickCount()-$liveOwnershipLastTick -ge 250)) {
                    Publish-LiveOwnership 'running'
                }
                $remaining=[int64]$TimeoutSeconds*1000-$executionWatch.ElapsedMilliseconds
                if ($remaining -le 0) { break }
                $rootExited=[VoxelGodotWatchdogNativeV2]::WaitForProcess($processHandle,[uint32][math]::Min(250,$remaining))
            }
            $executionWatch.Stop()
        }
        Assert-NoStopRequest
        if ($rootExited) { $functionalExitCode=[uint32][VoxelGodotWatchdogNativeV2]::ReadProcessExitCode($processHandle) } else { $timedOut=$true }
        if ($rootExited) {
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while ($true) {
                $members=Get-JobMembership 'root_exit_cleanup_grace'
                if ($members.ProcessIds.Count -eq 0 -or $watch.ElapsedMilliseconds -ge $CleanupGraceMilliseconds) { break }
                $left=$CleanupGraceMilliseconds-$watch.ElapsedMilliseconds
                Start-Sleep -Milliseconds ([int][math]::Min(50,[math]::Max(1,$left)))
            }
            $watch.Stop()
        }
        Assert-NoStopRequest
    } catch { $monitoringException=$_.Exception.Message; throw }
} catch { $fatalException=$_.Exception.Message }
finally {
    $terminalCleanupStopwatch=[Diagnostics.Stopwatch]::StartNew()
    if ($liveOwnershipCreated) {
        try { Publish-LiveOwnership 'stopping' }
        catch {
            $monitoringException="Live ownership invalidation failed: $($_.Exception.Message)"
            $cleanupErrors.Add($monitoringException)
        }
    }
    $nativeCreateReachedProcess=[bool][VoxelGodotWatchdogNativeV2]::LastCreateReachedProcess
    $launchedProcessRequiresZeroProof=$processCreated -or $nativeCreateReachedProcess
    if ($jobHandle -ne [IntPtr]::Zero) {
        $before=Get-JobMembership 'finally_before_cleanup' -SuppressFailure
        $mustTerminate=$timedOut -or ($null -ne $monitoringException) -or (-not $before.Succeeded) -or $before.ProcessIds.Count -gt 0
        if ($mustTerminate) { Invoke-ForcedJobTermination }
        $final=Get-JobMembership 'final_before_job_close' -SuppressFailure
        if ($final.Succeeded) { $finalMembershipKnown=$true; $finalJobMemberPids=@($final.ProcessIds) }
        if ($completionZeroMessageObserved) { Set-AuthoritativeZeroProof 'bounded_completion_port_active_process_zero' }
        elseif ($finalMembershipKnown -and $finalJobMemberPids.Count -eq 0) { Set-AuthoritativeZeroProof 'job_membership_zero' }
        if ((-not $finalMembershipKnown -or $finalJobMemberPids.Count -gt 0) -and -not $terminateJobAttempted) {
            Invoke-ForcedJobTermination
            $final=Get-JobMembership 'final_after_terminate_job' -SuppressFailure
            if ($final.Succeeded) { $finalMembershipKnown=$true; $finalJobMemberPids=@($final.ProcessIds) }
            if ($completionZeroMessageObserved) { Set-AuthoritativeZeroProof 'bounded_completion_port_active_process_zero' }
            elseif ($finalMembershipKnown -and $finalJobMemberPids.Count -eq 0) { Set-AuthoritativeZeroProof 'job_membership_zero_after_terminate' }
        }
        if (-not $authoritativeZeroProven) { $cleanupUnresolved=$true }
        if (-not $authoritativeZeroProven -and $terminateJobSucceeded) {
            $fallbackCaptureAttempted=$true
            $fallbackMembers=@()
            try {
                $fallbackMembers=@([VoxelGodotWatchdogNativeV2]::CaptureStableJobMembers($jobHandle,12,25))
                $fallbackCapturedPids=@($fallbackMembers|ForEach-Object{[long]$_.ProcessId})
                $fallbackCaptureSucceeded=$true
            } catch {
                $fallbackCaptureError=$_.Exception.Message
                $cleanupErrors.Add("Stable fallback member capture failed: $fallbackCaptureError")
            }
            if ($fallbackCaptureSucceeded) {
                $fallbackJobClosed=Close-JobHandleOnce
                $allFallbackMembersExited=$fallbackJobClosed
                foreach ($member in $fallbackMembers) {
                    $waitRecord=[pscustomobject][ordered]@{
                        pid=[long]$member.ProcessId; waitedByRetainedHandle=$false; signaled=$false
                        exitCode=$null; stillActiveRejected=$false; handleClosed=$false; error=$null
                    }
                    try {
                        $remaining=Get-TerminalCleanupRemainingMilliseconds
                        if ($remaining -eq 0) {
                            Set-TerminalCleanupTimeout "retained job-process wait for PID $($member.ProcessId)"
                            throw [TimeoutException]::new('Terminal cleanup deadline expired before retained-handle wait.')
                        }
                        $waitRecord.waitedByRetainedHandle=$true
                        $waitRecord.exitCode=[uint32][VoxelGodotWatchdogNativeV2]::WaitForCapturedProcessExit($member.ProcessHandle,$remaining)
                        $waitRecord.signaled=$true
                    } catch {
                        $allFallbackMembersExited=$false
                        $fallbackRetainedWaitFailed=$true
                        $waitRecord.error=$_.Exception.Message
                        $waitRecord.stillActiveRejected=$waitRecord.error.Contains('STILL_ACTIVE')
                        $cleanupErrors.Add("Fallback retained-handle wait failed for captured PID $($member.ProcessId): $($waitRecord.error)")
                    } finally {
                        try {
                            [VoxelGodotWatchdogNativeV2]::CloseNativeHandle($member.ProcessHandle)
                            $waitRecord.handleClosed=$true
                        } catch {
                            $cleanupErrors.Add("Fallback retained handle close failed for captured PID $($member.ProcessId): $($_.Exception.Message)")
                        }
                        $fallbackPostCloseWaits.Add($waitRecord)
                    }
                }
                if ($allFallbackMembersExited) {
                    $fallbackZeroProven=$true
                    Set-AuthoritativeZeroProof 'stable_retained_member_handles_signaled_after_job_close'
                }
            }
        }
        $requiresPostCloseCompletion=$launchedProcessRequiresZeroProof -and (
            ($terminateJobAttempted -and -not $terminateJobSucceeded) -or
            ($fallbackCaptureAttempted -and -not $fallbackCaptureSucceeded) -or
            $fallbackRetainedWaitFailed -or -not $authoritativeZeroProven)
        if ($requiresPostCloseCompletion) {
            if ($jobHandle -ne [IntPtr]::Zero) { [void](Close-JobHandleOnce) }
            $remaining=Get-TerminalCleanupRemainingMilliseconds
            if ($completionPortHandle -eq [IntPtr]::Zero) {
                $cleanupUnresolved=$true
                $cleanupErrors.Add('Completion-port handle unavailable for terminal post-close zero proof.')
            } elseif ($remaining -eq 0) {
                Set-TerminalCleanupTimeout 'post-close completion-port zero proof'
            } else {
                try {
                    $postCloseCompletionZeroProven=[VoxelGodotWatchdogNativeV2]::WaitForActiveProcessZero(
                        $completionPortHandle,$jobCompletionKey,$remaining)
                    if ($postCloseCompletionZeroProven) {
                        Set-AuthoritativeZeroProof 'bounded_post_close_completion_port_active_process_zero'
                    } else {
                        Set-TerminalCleanupTimeout 'post-close completion-port zero proof'
                    }
                } catch {
                    $cleanupUnresolved=$true
                    $cleanupErrors.Add("Terminal post-close completion wait failed: $($_.Exception.Message)")
                }
            }
        }
    }
    Close-WatchdogHandle $threadHandle 'primary thread handle'; Close-WatchdogHandle $processHandle 'root process handle'
    Close-WatchdogHandle $stdinHandle 'stdin handle'; Close-WatchdogHandle $stdoutHandle 'stdout handle'
    Close-WatchdogHandle $stderrHandle 'stderr handle'
    if ($jobHandle -ne [IntPtr]::Zero -and -not (Close-JobHandleOnce)) {
        $cleanupUnresolved=$true
    }
    Close-WatchdogHandle $completionPortHandle 'completion port handle'

    $cleanupPassed=$processCreated -and $assignedToJob -and $resumed -and $rootExited -and (-not $forcedCleanup) -and $authoritativeZeroProven -and (-not $cleanupUnresolved) -and $finalMembershipKnown -and $finalJobMemberPids.Count -eq 0 -and $cleanupErrors.Count -eq 0
    if (($membershipQueryFailed -and -not $membershipUncertaintyResolvedByZeroProof) -or $cleanupUnresolved -or $null -ne $monitoringException -or $cleanupErrors.Count -gt 0) { $overallExitCode=126 }
    elseif ($forcedCleanup) { $overallExitCode=125 }
    elseif ($timedOut) { $overallExitCode=124 }
    elseif (-not $processCreated -or -not $assignedToJob -or -not $resumed -or -not $rootExited -or $null -eq $functionalExitCode) { $overallExitCode=127 }
    elseif ([uint64]$functionalExitCode -gt [int32]::MaxValue) { $overallExitCode=1 }
    else { $overallExitCode=[int]$functionalExitCode }

    $completedUtc=[datetime]::UtcNow

    $emergencyFunctional=if ($null -eq $functionalExitCode) {'null'} else {[string][uint32]$functionalExitCode}
    $emergencyTimedOut=if ($timedOut) {'true'} else {'false'}
    $emergencyJson='{"schema":"godot-scene-watchdog/emergency-v1","runId":"'+$runId+'","overallExitCode":126,"functionalExitCode":'+$emergencyFunctional+',"timedOut":'+$emergencyTimedOut+',"cleanupUnresolved":true,"reason":"primary_summary_failed"}'
    $durableSummaryWritten=$false; $summaryJson=$null
    try {
    $summary=[ordered]@{
        schema='godot-scene-watchdog/v5'; runId=$runId; projectPath=$resolvedProjectPath; godotExe=$resolvedGodotExe
        scene=$Scene; sceneArguments=@($SceneArguments); headless=[bool]$Headless
        launchTimeUtc=if ($null -ne $launchStartedUtc) {$launchStartedUtc.ToString('o')} else {$null}
        completedTimeUtc=$completedUtc.ToString('o'); timeoutSeconds=$TimeoutSeconds; cleanupGraceMilliseconds=$CleanupGraceMilliseconds
        finalCleanupTimeoutMilliseconds=$FinalCleanupTimeoutMilliseconds; terminalCleanupElapsedMilliseconds=$terminalCleanupStopwatch.ElapsedMilliseconds
        terminalCleanupExpired=$terminalCleanupExpired
        exactCommandLine=$exactCommandLine; rootPid=$rootPid; rootThreadId=$rootThreadId
        processCreatedSuspended=$processCreated; assignedAtomicallyByProcThreadAttributeJobList=$assignedToJob; primaryThreadResumed=$resumed
        nativeCreateReachedProcess=$nativeCreateReachedProcess; launchedProcessRequiresZeroProof=$launchedProcessRequiresZeroProof
        rootExited=$rootExited; functionalExitCode=$functionalExitCode; timedOut=$timedOut
        stopRequestPath=$resolvedStopRequestPath; stopRequested=$stopRequested; stopRequestedAtUtc=$stopRequestedAtUtc
        monitoringException=$monitoringException; fatalException=$fatalException; forcedCleanup=$forcedCleanup
        terminateJobObjectAttempted=$terminateJobAttempted; terminateJobObjectSucceeded=$terminateJobSucceeded
        completionZeroMessageObserved=$completionZeroMessageObserved; completionZeroWaitTimedOut=$completionZeroWaitTimedOut
        cleanupUnresolved=$cleanupUnresolved
        fallbackCaptureAttempted=$fallbackCaptureAttempted; fallbackCaptureSucceeded=$fallbackCaptureSucceeded
        fallbackCaptureError=$fallbackCaptureError; fallbackCapturedPids=@($fallbackCapturedPids)
        fallbackJobClosed=$fallbackJobClosed; fallbackRetainedWaitFailed=$fallbackRetainedWaitFailed
        fallbackZeroProven=$fallbackZeroProven; postCloseCompletionZeroProven=$postCloseCompletionZeroProven
        authoritativeZeroProven=$authoritativeZeroProven; zeroProofSource=$zeroProofSource
        membershipUncertaintyResolvedByZeroProof=$membershipUncertaintyResolvedByZeroProof
        jobCloseAttempted=$jobCloseAttempted
        fallbackPostCloseWaits=@($fallbackPostCloseWaits)
        membershipQueryFailed=$membershipQueryFailed; finalMembershipKnown=$finalMembershipKnown; finalJobMemberPids=@($finalJobMemberPids)
        cleanupPassed=$cleanupPassed; overallExitCode=$overallExitCode
        stdoutPath=$resolvedStdoutPath; stderrPath=$resolvedStderrPath; summaryPath=$resolvedSummaryPath
        preexistingGodotProcesses=@($preexistingGodotProcesses); jobMembershipEvidence=@($membershipEvidence); cleanupErrors=@($cleanupErrors)
        ownershipAuthority='Windows Job Object membership only'
        supportedWindowsBaseline='Windows 10 or Windows Server 2016 and later (PROC_THREAD_ATTRIBUTE_JOB_LIST required)'
        architecture=@(
            'Create a private Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE and associate a private I/O completion port.',
            'Open unique stdout/stderr files with CREATE_NEW and inheritable handles; provide inheritable NUL stdin.',
            'Build one exact Windows command line from argv using CommandLineToArgvW-compatible quoting.',
            'Initialize two STARTUPINFOEX attributes: restricted PROC_THREAD_ATTRIBUTE_HANDLE_LIST and private PROC_THREAD_ATTRIBUTE_JOB_LIST.',
            'Call CreateProcessW with the job list so Windows assigns the process atomically before creation returns, then ResumeThread.',
            'Wait for root completion by retained process handle and read its functional exit code separately.',
            'Query JobObjectBasicProcessIdList for cleanup grace/evidence; never infer ownership from PID ancestry or command lines.',
            'After TerminateJobObject, wait boundedly for JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO and then require a successful zero-member query.',
            'Only after TerminateJobObject succeeds, unresolved proof may capture a stable exact set of job-member handles, close the job once, and wait each handle to a non-STILL_ACTIVE exit.',
            'All retained-handle and completion-port cleanup waits share one terminal deadline; expiry records unresolved cleanup and exits 126.',
            'Cleanup state becomes resolved only after zero membership, completion-port ACTIVE_PROCESS_ZERO, or fully successful retained-handle proof.'
        )
        caveats=@(
            'Windows 10/Windows Server 2016 or later is required because PROC_THREAD_ATTRIBUTE_JOB_LIST is the atomic assignment authority.',
            'Preexisting Godot identities are evidence only and never affect ownership, waiting, or termination.',
            'Job member PIDs are observational evidence; Job Object membership is the ownership authority.',
            'A failed membership query or missing ACTIVE_PROCESS_ZERO confirmation prevents a clean result and takes exit 126 precedence.',
            'Stable fallback capture uses PID only to open a candidate handle; GetProcessId plus IsProcessInJob and repeated job snapshots must revalidate identity before job close.',
            'The explicit post-close completion wait is bounded by the terminal cleanup deadline; process exit still closes any retained kill-on-close job handle as the final backstop.',
            'Any forced cleanup is a nonzero harness failure even when functionalExitCode is zero.',
            'Closing the kill-on-close job handle is the final backstop after explicit cleanup attempts.'
        )
    }
        if ($null -ne $resolvedLiveOwnershipPath) {
            $summary['liveOwnershipPath']=$resolvedLiveOwnershipPath
            $summary['liveOwnershipError']=$liveOwnershipError
            $summary['liveOwnershipSequence']=$liveOwnershipSequence
        }
        $summaryJson=$summary|ConvertTo-Json -Depth 12 -Compress
        if ([string]::IsNullOrWhiteSpace($resolvedSummaryPath)) { throw 'SummaryPath could not be resolved.' }
        Write-AtomicJsonNoOverwrite $resolvedSummaryPath $summaryJson
        $durableSummaryWritten=$true
    } catch {
        $overallExitCode=126
        if (-not [string]::IsNullOrWhiteSpace($resolvedSummaryPath) -and
            -not [IO.File]::Exists($resolvedSummaryPath) -and -not [IO.Directory]::Exists($resolvedSummaryPath)) {
            try { Write-AtomicJsonNoOverwrite $resolvedSummaryPath $emergencyJson } catch {}
        }
        try { Write-Output $emergencyJson }
        catch { try { [Console]::Out.WriteLine($emergencyJson) } catch {} }
    }
    if ($durableSummaryWritten) {
        try { Write-Output $summaryJson }
        catch { try { [Console]::Out.WriteLine($summaryJson) } catch {} }
    }
}

exit $overallExitCode

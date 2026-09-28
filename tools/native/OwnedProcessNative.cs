// Ported from run-godot-scene-watchdog.ps1; Win32 ownership primitives are intentionally shared in semantics.
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
        string app, string commandLine, string directory, IntPtr input, IntPtr output, IntPtr error, string environment) {
        LastCreateReachedProcess = false;
        if (String.IsNullOrEmpty(commandLine) || commandLine.Length > 32766)
            throw new ArgumentException("CreateProcessW command line must contain 1 through 32766 characters.");
        IntPtr attributes = IntPtr.Zero, handles = IntPtr.Zero, jobs = IntPtr.Zero, environmentBlock = IntPtr.Zero;
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
            environmentBlock = Marshal.StringToHGlobalUni(environment);
            if (!CreateProcessW(app, mutable, IntPtr.Zero, IntPtr.Zero, true,
                CREATE_SUSPENDED|CREATE_UNICODE_ENVIRONMENT|EXTENDED_STARTUPINFO_PRESENT|CREATE_NO_WINDOW,
                environmentBlock, directory, ref si, out pi)) throw Error("CreateProcessW(CREATE_SUSPENDED, JOB_LIST)");
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
            if (environmentBlock != IntPtr.Zero) Marshal.FreeHGlobal(environmentBlock);
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

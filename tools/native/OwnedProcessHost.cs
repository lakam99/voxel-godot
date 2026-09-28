using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;
using Native = VoxelGodotWatchdogNativeV2;

// Line-delimited RPC. Only this process retains the private job handle.
// EOF (including loss of the Node parent) closes the kill-on-close job.
public static class OwnedProcessHost {
    static IntPtr job, key, port, input, output, error;
    static VoxelGodotWatchdogProcessInfo root;
    static VoxelGodotWatchdogCapturedMember[] captured;
    static bool terminated;
    static JavaScriptSerializer json = new JavaScriptSerializer();
    static string S(Dictionary<string, object> c, string k) { return (string)c[k]; }
    static uint U(Dictionary<string, object> c, string k) { return Convert.ToUInt32(c[k]); }
    static void Close(ref IntPtr h) {
        if (h == IntPtr.Zero) return;
        Native.CloseNativeHandle(h); h = IntPtr.Zero;
    }
    static object Run(Dictionary<string, object> c) {
        switch(S(c, "op")) {
        case "init":
            if (job != IntPtr.Zero) throw new InvalidOperationException("Already initialized");
            job = Native.CreateKillOnCloseJob(); key = job;
            port = Native.CreateCompletionPortAndAssociateJob(job);
            return new { pid = System.Diagnostics.Process.GetCurrentProcess().Id,
                creationFileTime = Native.ProcessCreationFileTime(System.Diagnostics.Process.GetCurrentProcess().Handle).ToString() };
        case "create":
            if (root != null) throw new InvalidOperationException("Already launched");
            input = Native.OpenInheritedNullInput();
            output = Native.CreateNewOutputFile(S(c, "stdoutPath"));
            error = Native.CreateNewOutputFile(S(c, "stderrPath"));
            var args = json.ConvertToType<string[]>(c["args"]);
            string command = Native.BuildCommandLine(args);
            root = Native.CreateSuspendedProcessInAtomicJob(job, S(c, "executable"), command,
                S(c, "projectPath"), input, output, error, S(c, "environment"));
            return new { rootPid = root.ProcessId, rootThreadId = root.ThreadId, exactCommandLine = command };
        case "resume":
            Native.ResumePrimaryThread(root.ThreadHandle); return true;
        case "poll":
            bool exited = Native.WaitForProcess(root.ProcessHandle, U(c, "milliseconds"));
            return new { exited = exited, exitCode = exited ? (object)Native.ReadProcessExitCode(root.ProcessHandle) : null };
        case "tick": return Native.LiveTickCount().ToString();
        case "members": return Native.GetJobProcessIds(job);
        case "terminate": Native.TerminateOwnedJob(job); terminated = true; return true;
        case "zero": return Native.WaitForActiveProcessZero(port, key, U(c, "milliseconds"));
        case "capture":
            if (!terminated) throw new InvalidOperationException("Capture requires successful job termination");
            captured = Native.CaptureStableJobMembers(job, 12, 25);
            return Array.ConvertAll(captured, m => m.ProcessId);
        case "waitCaptured":
            int index = Convert.ToInt32(c["index"]);
            var member = captured[index];
            try { return Native.WaitForCapturedProcessExit(member.ProcessHandle, U(c, "milliseconds")); }
            finally { Close(ref member.ProcessHandle); }
        case "live":
            var members = Native.CaptureStableJobMembers(job, 3, 10);
            try {
                var rows = new List<object>();
                foreach (var m in members) rows.Add(new { pid = m.ProcessId,
                    creationFileTime = Native.ProcessCreationFileTime(m.ProcessHandle).ToString() });
                return new { members = rows, tick = Native.LiveTickCount().ToString() };
            } finally { foreach (var m in members) Close(ref m.ProcessHandle); }
        case "closeJob": Close(ref job); return true;
        case "close":
            Cleanup(); return true;
        default: throw new ArgumentException("Unknown operation");
        }
    }
    static void Cleanup() {
        // Job close comes first: even a later handle-close error cannot leave live children.
        Close(ref job);
        if (captured != null) foreach (var m in captured) Close(ref m.ProcessHandle);
        if (root != null) { Close(ref root.ThreadHandle); Close(ref root.ProcessHandle); }
        Close(ref input); Close(ref output); Close(ref error); Close(ref port);
    }
    public static int Main() {
        Console.InputEncoding = new System.Text.UTF8Encoding(false);
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        try {
            string line;
            while ((line = Console.ReadLine()) != null) {
                Dictionary<string, object> c = null;
                try {
                    c = json.Deserialize<Dictionary<string, object>>(line);
                    object value = Run(c);
                    Console.WriteLine(json.Serialize(new { ok = true, value = value }));
                    Console.Out.Flush();
                    if (S(c, "op") == "close") break;
                } catch (Exception e) {
                    Console.WriteLine(json.Serialize(new { ok = false, error = e.Message,
                        nativeCreateReachedProcess = Native.LastCreateReachedProcess }));
                    Console.Out.Flush();
                }
            }
            return 0;
        } finally { Cleanup(); }
    }
}

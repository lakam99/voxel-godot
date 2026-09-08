using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Web.Script.Serialization;

public static class OwnedWindowJson {
    public static string ReadBounded(TextReader reader) {
        var chars = new char[1048577];
        int count = 0, read;
        while (count < chars.Length && (read = reader.Read(chars, count, chars.Length - count)) > 0) count += read;
        if (count > 1048576) throw new InvalidOperationException("Oversized JSON input.");
        return new string(chars, 0, count);
    }
    public static Dictionary<string, object> Parse(string json) {
        if (json.Length > 1048576) throw new InvalidOperationException("Oversized JSON input.");
        var value = new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 32 }.DeserializeObject(json) as Dictionary<string, object>;
        if (value == null) throw new InvalidOperationException("Expected a JSON object.");
        return value;
    }
    public static string Serialize(object value) { return new JavaScriptSerializer().Serialize(value); }
    public static string Text(Dictionary<string, object> value, string key, string fallback) {
        object field;
        if (!value.TryGetValue(key, out field)) {
            if (fallback != null) return fallback;
            throw new InvalidOperationException("Missing " + key);
        }
        if (!(field is string) || string.IsNullOrWhiteSpace((string)field)) throw new InvalidOperationException("Invalid " + key);
        return (string)field;
    }
    public static long Integer(Dictionary<string, object> value, string key, long? fallback) {
        object field;
        if (!value.TryGetValue(key, out field)) {
            if (fallback.HasValue) return fallback.Value;
            throw new InvalidOperationException("Missing " + key);
        }
        // No floating-point coercion. Creation times use Text instead.
        if (!(field is string) && !(field is int) && !(field is long)) throw new InvalidOperationException("Invalid integer " + key);
        long result;
        if (!long.TryParse(Convert.ToString(field, CultureInfo.InvariantCulture), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out result))
            throw new InvalidOperationException("Invalid integer " + key);
        return result;
    }
    public static string Creation(Dictionary<string, object> value, string key) {
        string text = Text(value, key, null);
        long parsed;
        if (!long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out parsed) || parsed <= 0 || parsed.ToString(CultureInfo.InvariantCulture) != text)
            throw new InvalidOperationException("Invalid decimal FILETIME " + key);
        return text;
    }
    public static uint Pid(Dictionary<string, object> value, string key) {
        long pid = Integer(value, key, null);
        if (pid <= 0 || pid > uint.MaxValue) throw new InvalidOperationException("Invalid PID " + key);
        return (uint)pid;
    }
}

public sealed class OwnedWindowRequest {
    public string LiveOwnershipPath, RunId, ProjectPath, Action, CapturePath, Key, Button;
    public long WindowHandle;
    public int X, Y, Dx, Dy, HoldMilliseconds, ExpectedClientWidth, ExpectedClientHeight;
    public ushort KeyCode;
    static int IntOption(Dictionary<string, object> value, string name, int fallback, int min, int max) {
        long number = OwnedWindowJson.Integer(value, name, fallback);
        if (number < min || number > max) throw new InvalidOperationException(name + " is outside the allowed range.");
        return (int)number;
    }
    static string Choice(string value, params string[] options) {
        foreach (string option in options) if (string.Equals(value, option, StringComparison.OrdinalIgnoreCase)) return option;
        throw new InvalidOperationException("Invalid choice: " + value);
    }
    public static OwnedWindowRequest Parse(string json) {
        var value = OwnedWindowJson.Parse(json);
        var known = new HashSet<string>(new string[] {"LiveOwnershipPath", "RunId", "ProjectPath", "Action", "WindowHandle", "CapturePath", "X", "Y", "Dx", "Dy", "Button", "Key", "HoldMilliseconds", "ExpectedClientWidth", "ExpectedClientHeight"});
        foreach (string key in value.Keys) if (!known.Contains(key)) throw new InvalidOperationException("Unknown option: " + key);
        var r = new OwnedWindowRequest();
        r.LiveOwnershipPath = Path.GetFullPath(OwnedWindowJson.Text(value, "LiveOwnershipPath", null));
        r.RunId = OwnedWindowJson.Text(value, "RunId", null);
        r.ProjectPath = Path.GetFullPath(OwnedWindowJson.Text(value, "ProjectPath", null));
        r.Action = Choice(OwnedWindowJson.Text(value, "Action", "Inspect"), "Inspect", "Focus", "Capture", "Click", "Key", "MouseLook");
        r.Button = Choice(OwnedWindowJson.Text(value, "Button", "Left"), "Left", "Right");
        r.WindowHandle = OwnedWindowJson.Integer(value, "WindowHandle", 0);
        if (r.WindowHandle < 0) throw new InvalidOperationException("WindowHandle must be nonnegative.");
        r.X = IntOption(value, "X", -1, int.MinValue, int.MaxValue);
        r.Y = IntOption(value, "Y", -1, int.MinValue, int.MaxValue);
        r.Dx = IntOption(value, "Dx", 0, -1000, 1000);
        r.Dy = IntOption(value, "Dy", 0, -1000, 1000);
        r.HoldMilliseconds = IntOption(value, "HoldMilliseconds", 80, 1, 2000);
        r.ExpectedClientWidth = IntOption(value, "ExpectedClientWidth", 0, 0, 16384);
        r.ExpectedClientHeight = IntOption(value, "ExpectedClientHeight", 0, 0, 16384);
        r.Key = OwnedWindowJson.Text(value, "Key", "");
        r.CapturePath = OwnedWindowJson.Text(value, "CapturePath", "");
        if (r.CapturePath.Length != 0) r.CapturePath = Path.GetFullPath(r.CapturePath);
        if ((r.Action == "Click" || r.Action == "Key" || r.Action == "MouseLook") &&
            (r.WindowHandle <= 0 || r.ExpectedClientWidth < 64 || r.ExpectedClientHeight < 64))
            throw new InvalidOperationException("Input requires the inspected HWND and expected client width/height.");
        if (r.Action == "Capture" && r.CapturePath.Length == 0) throw new InvalidOperationException("CapturePath is required.");
        if (r.Action == "Key") {
            var named = new Dictionary<string, ushort>(StringComparer.OrdinalIgnoreCase) {
                {"Enter",13},{"Escape",27},{"Space",32},{"Tab",9},{"Shift",16},{"Backspace",8},
                {"Left",37},{"Up",38},{"Right",39},{"Down",40},{"F3",114}
            };
            if (!named.TryGetValue(r.Key, out r.KeyCode)) {
                if (r.Key.Length == 1 && ((r.Key[0] >= 'a' && r.Key[0] <= 'z') ||
                    (r.Key[0] >= 'A' && r.Key[0] <= 'Z') || (r.Key[0] >= '0' && r.Key[0] <= '9')))
                    r.KeyCode = (ushort)char.ToUpperInvariant(r.Key[0]);
                else throw new InvalidOperationException("Key must be one letter/digit or Enter/Escape/Space/Tab/Shift/Backspace/arrow/F3.");
            }
        }
        return r;
    }
}

public sealed class OwnedWindowController {
    readonly IOwnedDesktop desktop;
    readonly OwnedWindowRequest request;
    long lastSequence = -1;
    public Dictionary<string, object> FailureReport { get; private set; }
    public OwnedWindowController(IOwnedDesktop desktop, OwnedWindowRequest request) { this.desktop = desktop; this.request = request; }
    Dictionary<string, object> ReadOwnership() {
        var value = OwnedWindowJson.Parse(desktop.ReadSnapshot(request.LiveOwnershipPath));
        if (OwnedWindowJson.Text(value, "schema", null) != "godot-live-ownership/v1" ||
            OwnedWindowJson.Text(value, "runId", null) != request.RunId ||
            OwnedWindowJson.Text(value, "state", null) != "running" ||
            OwnedWindowJson.Text(value, "authority", null) != "Windows Job Object membership" ||
            !string.Equals(Path.GetFullPath(OwnedWindowJson.Text(value, "projectPath", null)), request.ProjectPath, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Wrong/inactive live ownership source.");
        ulong now = desktop.Tick(), observed;
        if (!ulong.TryParse(OwnedWindowJson.Text(value, "observedTickMilliseconds", null), NumberStyles.None, CultureInfo.InvariantCulture, out observed))
            throw new InvalidOperationException("Invalid observedTickMilliseconds.");
        if (observed > now || now - observed > 1000) throw new InvalidOperationException("Live ownership snapshot is stale or future-dated.");
        long sequence = OwnedWindowJson.Integer(value, "sequence", null);
        if (sequence < 0 || sequence < lastSequence) throw new InvalidOperationException("Live ownership sequence went backwards.");
        lastSequence = sequence;
        desktop.VerifyProcess(OwnedWindowJson.Pid(value, "watchdogPid"), OwnedWindowJson.Creation(value, "watchdogCreationFileTime"));
        return value;
    }
    static List<Dictionary<string, object>> Members(Dictionary<string, object> live) {
        object value;
        if (!live.TryGetValue("members", out value) || !(value is object[])) throw new InvalidOperationException("Invalid membership array.");
        var result = new List<Dictionary<string, object>>();
        foreach (object row in (object[])value) {
            var member = row as Dictionary<string, object>;
            if (member == null) throw new InvalidOperationException("Invalid member.");
            OwnedWindowJson.Pid(member, "pid");
            OwnedWindowJson.Creation(member, "creationFileTime");
            result.Add(member);
        }
        return result;
    }
    static bool SameBounds(OwnedGameWindowInfo a, OwnedGameWindowInfo b) {
        return a.X == b.X && a.Y == b.Y && a.Width == b.Width && a.Height == b.Height;
    }
    OwnedGameWindowInfo ConfirmWindow(long handle, bool requireForeground) {
        var live = ReadOwnership();
        var info = desktop.Inspect(handle);
        var matches = Members(live).FindAll(delegate(Dictionary<string, object> member) { return OwnedWindowJson.Pid(member, "pid") == info.Pid; });
        if (matches.Count != 1) throw new InvalidOperationException("Window PID is not an exact current owned member.");
        desktop.VerifyProcess(info.Pid, OwnedWindowJson.Creation(matches[0], "creationFileTime"));
        var again = desktop.Inspect(handle);
        if (again.Pid != info.Pid || !SameBounds(again, info)) throw new InvalidOperationException("Window identity or client bounds changed during verification.");
        if (requireForeground && !again.Foreground) throw new InvalidOperationException("Owned game window lost foreground focus.");
        return again;
    }
    void ConfirmStableWindow(OwnedGameWindowInfo original) {
        var current = ConfirmWindow(original.Hwnd, true);
        if (!SameBounds(current, original)) throw new InvalidOperationException("Client moved/resized before or during input.");
    }
    void ConfirmInputSize(OwnedGameWindowInfo info) {
        if (info.Width != request.ExpectedClientWidth || info.Height != request.ExpectedClientHeight)
            throw new InvalidOperationException("Client size differs from inspected input coordinates.");
    }
    public Dictionary<string, object> Execute() {
        IntPtr previous = desktop.SetDpi(new IntPtr(-4));
        if (previous == IntPtr.Zero) throw new InvalidOperationException("Unable to use physical-pixel DPI coordinates.");
        string started = DateTime.UtcNow.ToString("o");
        bool relativeMoveAttempted = false, relativeMoveSent = false;
        try {
            var live = ReadOwnership();
            long handle = request.WindowHandle;
            if (handle == 0) {
                var ownedIds = new HashSet<uint>();
                foreach (var member in Members(live)) ownedIds.Add(OwnedWindowJson.Pid(member, "pid"));
                var candidates = new List<long>();
                foreach (long window in desktop.VisibleGameWindows()) if (ownedIds.Contains(desktop.Inspect(window).Pid)) candidates.Add(window);
                if (candidates.Count != 1) throw new InvalidOperationException("Expected exactly one visible owned Godot game client; provide an inspected HWND if ambiguous.");
                handle = candidates[0];
            }
            var info = ConfirmWindow(handle, request.Action != "Inspect" && request.Action != "Focus");
            if (request.Action == "Focus") {
                if (!desktop.Focus(handle)) throw new InvalidOperationException("Windows refused foreground focus.");
                info = ConfirmWindow(handle, true);
            }
            if (request.Action == "MouseLook") {
                ConfirmInputSize(info);
                desktop.VerifyUnobscured(info);
                desktop.AssertInputsReleased(0);
                ConfirmStableWindow(info);
                relativeMoveAttempted = true;
                desktop.RelativeMouseMove(request.Dx, request.Dy);
                relativeMoveSent = true;
                ConfirmStableWindow(info);
                desktop.VerifyUnobscured(info);
            }
            if (request.Action == "Click" || request.Action == "Key") {
                ConfirmInputSize(info);
                desktop.VerifyUnobscured(info);
                desktop.AssertInputsReleased(request.KeyCode);
                bool right = request.Button == "Right", downAttempted = false;
                try {
                    if (request.Action == "Click") {
                        if (request.X < 0 || request.Y < 0 || request.X >= info.Width || request.Y >= info.Height)
                            throw new InvalidOperationException("Click must be inside client pixels.");
                        int x = checked(info.X + request.X), y = checked(info.Y + request.Y);
                        desktop.VerifyPoint(handle, x, y);
                        desktop.MoveCursor(x, y);
                        ConfirmStableWindow(info);
                        desktop.VerifyCursor(handle, x, y);
                        downAttempted = true;
                        desktop.MouseButton(right, false);
                    } else {
                        ConfirmStableWindow(info);
                        downAttempted = true;
                        desktop.Keyboard(request.KeyCode, false);
                    }
                    ulong holdStart = desktop.Tick();
                    do {
                        ConfirmStableWindow(info);
                        ulong elapsed = desktop.Tick() - holdStart;
                        if (elapsed < (ulong)request.HoldMilliseconds) desktop.Sleep((int)Math.Min(25UL, (ulong)request.HoldMilliseconds - elapsed));
                    } while (desktop.Tick() - holdStart < (ulong)request.HoldMilliseconds);
                } finally {
                    // Release only the attempted button/key, including a failed SendInput.
                    if (downAttempted) {
                        if (request.Action == "Click") desktop.MouseButton(right, true);
                        else desktop.Keyboard(request.KeyCode, true);
                    }
                }
            }
            string savedCapture = null;
            if (request.Action == "Capture") {
                savedCapture = request.CapturePath;
                desktop.VerifyUnobscured(info);
                desktop.Capture(info, savedCapture, delegate {
                    var after = ConfirmWindow(handle, true);
                    desktop.VerifyUnobscured(after);
                    if (!SameBounds(after, info)) throw new InvalidOperationException("Client moved during capture.");
                });
            }
            return new Dictionary<string, object> {
                {"schema", "owned-game-window-action/v1"}, {"runId", request.RunId}, {"action", request.Action}, {"status", "completed"},
                {"startedUtc", started}, {"completedUtc", DateTime.UtcNow.ToString("o")}, {"ownershipSequence", lastSequence},
                {"window", info}, {"capturePath", savedCapture}, {"key", request.Key}, {"button", request.Button},
                {"clientX", request.X}, {"clientY", request.Y}, {"relativeDx", request.Dx}, {"relativeDy", request.Dy},
                {"requestedHoldMilliseconds", request.HoldMilliseconds}
            };
        } catch (Exception error) {
            if (request.Action == "MouseLook") FailureReport = new Dictionary<string, object> {
                {"schema", "owned-game-window-action/v1"}, {"runId", request.RunId}, {"action", request.Action}, {"status", "failed"},
                {"relativeDx", request.Dx}, {"relativeDy", request.Dy}, {"inputAttempted", relativeMoveAttempted},
                {"inputSent", relativeMoveSent}, {"automaticRetrySafe", false}, {"reason", error.Message}
            };
            throw;
        } finally {
            if (desktop.SetDpi(previous) == IntPtr.Zero) throw new InvalidOperationException("DPI context restoration failed.");
        }
    }
}

public static class OwnedWindowProgram {
    public static int Main(string[] args) {
        OwnedWindowController controller = null;
        try {
            if (args.Length != 0) throw new InvalidOperationException("Expected one JSON request on stdin, no arguments.");
            var request = OwnedWindowRequest.Parse(OwnedWindowJson.ReadBounded(Console.In));
            controller = new OwnedWindowController(new WindowsDesktop(), request);
            Console.WriteLine(OwnedWindowJson.Serialize(controller.Execute()));
            return 0;
        } catch (Exception error) {
            if (controller != null && controller.FailureReport != null) Console.WriteLine(OwnedWindowJson.Serialize(controller.FailureReport));
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}

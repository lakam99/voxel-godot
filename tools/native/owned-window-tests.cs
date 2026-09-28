using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

// Synthetic controller tests. This executable never constructs WindowsDesktop
// or calls a Windows API; it exercises production policy with a fake desktop.
public sealed class FakeOwnedDesktop : IOwnedDesktop {
    public readonly List<string> Events = new List<string>();
    public readonly Dictionary<string, object> Snapshot;
    public Action<FakeOwnedDesktop, int> OnRead, OnInspect;
    public string FailEvent;
    public bool Foreground = true, FocusSucceeds = true, MoveLosesFocus, DownLosesFocus, CaptureMoves;
    public int Reads, Inspections, X = 100;
    public ulong Now = 10000;
    public long[] Windows = new long[] { 101 };
    public FakeOwnedDesktop() {
        Snapshot = new Dictionary<string, object> {
            {"schema", "godot-live-ownership/v1"}, {"runId", "test-run"}, {"state", "running"},
            {"authority", "Windows Job Object membership"}, {"projectPath", Path.GetFullPath(".")},
            {"sequence", 7}, {"observedTickMilliseconds", "10000"}, {"watchdogPid", 20},
            {"watchdogCreationFileTime", "134000000000000001"}, {"members", new object[] {
                new Dictionary<string, object> { {"pid", 30}, {"creationFileTime", "134000000000000003"} }
            }}
        };
    }
    void Event(string name) {
        Events.Add(name);
        if (FailEvent == name) { FailEvent = null; throw new InvalidOperationException("injected " + name); }
    }
    public string ReadSnapshot(string path) {
        Event("read"); Reads++;
        Snapshot["observedTickMilliseconds"] = Now.ToString();
        if (OnRead != null) OnRead(this, Reads);
        return OwnedWindowJson.Serialize(Snapshot);
    }
    public ulong Tick() { return Now; }
    public void Sleep(int milliseconds) { Event("sleep"); Now += (ulong)milliseconds; }
    public void VerifyProcess(uint pid, string creation) {
        Event("verify:" + pid);
        if ((pid != 20 && pid != 30) || creation != (pid == 20 ? "134000000000000001" : "134000000000000003"))
            throw new InvalidOperationException("Owned PID creation identity changed or exited");
    }
    public OwnedGameWindowInfo Inspect(long handle) {
        Event("inspect"); Inspections++;
        if (OnInspect != null) OnInspect(this, Inspections);
        return new OwnedGameWindowInfo { Hwnd = handle, Pid = 30, X = X, Y = 200, Width = 1280, Height = 720, ClassName = "Engine", Foreground = Foreground };
    }
    public long[] VisibleGameWindows() { Event("enumerate"); return Windows; }
    public void VerifyUnobscured(OwnedGameWindowInfo info) { Event("unobscured"); }
    public void VerifyPoint(long handle, int x, int y) { Event("point"); }
    public void VerifyCursor(long handle, int x, int y) { Event("cursor"); }
    public void AssertInputsReleased(int key) { Event("released:" + key); }
    public void MoveCursor(int x, int y) { Event("cursor-move"); }
    public void RelativeMouseMove(int dx, int dy) { Event("relative-move"); if (MoveLosesFocus) Foreground = false; }
    public void MouseButton(bool right, bool up) { Event("mouse:" + (right ? "right:" : "left:") + (up ? "up" : "down")); if (!up && DownLosesFocus) Foreground = false; }
    public void Keyboard(ushort key, bool up) { Event("key:" + key + (up ? ":up" : ":down")); if (!up && DownLosesFocus) Foreground = false; }
    public bool Focus(long handle) { Event("focus"); if (FocusSucceeds) Foreground = true; return FocusSucceeds; }
    public IntPtr SetDpi(IntPtr value) { Event(value.ToInt64() == -4 ? "dpi-enter" : "dpi-restore"); return new IntPtr(-3); }
    public void Capture(OwnedGameWindowInfo info, string path, Action verifyAfterCopy) {
        Event("capture-copy"); if (CaptureMoves) X++;
        verifyAfterCopy(); Event("capture-save");
    }
}

public static class OwnedWindowTests {
    static readonly List<string> passed = new List<string>();
    static void Assert(bool condition, string message) { if (!condition) throw new Exception(message); }
    static void Test(string name, Action test) { test(); passed.Add(name); }
    static void Reject(Action act, string expected) {
        try { act(); } catch (Exception error) {
            Assert(error.Message.IndexOf(expected, StringComparison.OrdinalIgnoreCase) >= 0, "Wrong error: " + error.Message + "; expected " + expected);
            return;
        }
        throw new Exception("Expected rejection: " + expected);
    }
    static Dictionary<string, object> Options(string action) {
        var value = new Dictionary<string, object> {
            {"LiveOwnershipPath", Path.Combine(Path.GetTempPath(), "unused-owned-window.json")},
            {"RunId", "test-run"}, {"ProjectPath", Path.GetFullPath(".")}, {"Action", action},
            {"WindowHandle", "101"}, {"ExpectedClientWidth", "1280"}, {"ExpectedClientHeight", "720"},
            {"X", "12"}, {"Y", "34"}, {"Key", "w"}
        };
        if (action == "Capture") value["CapturePath"] = Path.Combine(Path.GetTempPath(), "unused-owned-window.png");
        return value;
    }
    static OwnedWindowController Controller(FakeOwnedDesktop fake, string action) {
        return new OwnedWindowController(fake, OwnedWindowRequest.Parse(OwnedWindowJson.Serialize(Options(action))));
    }
    static bool NoInput(FakeOwnedDesktop f) {
        return !f.Events.Exists(delegate(string e) { return e.StartsWith("key:") || e.StartsWith("mouse:") || e == "relative-move" || e == "cursor-move"; });
    }
    public static int Main() {
        try {
            Test("native INPUT ABI x64 layout", delegate {
                var native = typeof(WindowsDesktop);
                var input = native.GetNestedType("INPUT", System.Reflection.BindingFlags.NonPublic);
                Assert(Marshal.SizeOf(input) == 40 && Marshal.OffsetOf(input, "data").ToInt32() == 8, "Incorrect SendInput layout");
            });
            foreach (string field in new string[] {"schema", "runId", "state", "authority", "projectPath"}) {
                string key = field;
                Test("reject wrong " + key, delegate {
                    var f = new FakeOwnedDesktop(); f.Snapshot[key] = "wrong";
                    Reject(delegate { Controller(f, "Key").Execute(); }, "Wrong/inactive");
                    Assert(NoInput(f) && f.Events.Contains("dpi-restore"), "Input or DPI leak");
                });
            }
            foreach (string offset in new string[] {"8999", "10001"}) {
                string tick = offset;
                Test("reject stale/future tick " + tick, delegate {
                    var f = new FakeOwnedDesktop(); f.OnRead = delegate(FakeOwnedDesktop d, int n) { d.Snapshot["observedTickMilliseconds"] = tick; };
                    Reject(delegate { Controller(f, "Key").Execute(); }, "stale or future"); Assert(NoInput(f), "Input sent");
                });
            }
            Test("accept exact 1000ms age boundary", delegate {
                var f = new FakeOwnedDesktop(); f.OnRead = delegate(FakeOwnedDesktop d, int n) { d.Snapshot["observedTickMilliseconds"] = "9000"; };
                Controller(f, "Inspect").Execute();
            });
            Test("reject regressing sequence", delegate {
                var f = new FakeOwnedDesktop(); f.OnRead = delegate(FakeOwnedDesktop d, int n) { d.Snapshot["sequence"] = n == 1 ? 5 : 4; };
                Reject(delegate { Controller(f, "Key").Execute(); }, "sequence went backwards"); Assert(NoInput(f), "Input sent");
            });
            Test("reject watchdog PID reuse", delegate {
                var f = new FakeOwnedDesktop(); f.Snapshot["watchdogCreationFileTime"] = "134000000000000002";
                Reject(delegate { Controller(f, "Key").Execute(); }, "creation identity"); Assert(NoInput(f), "Input sent");
            });
            Test("reject numeric FILETIME before precision loss", delegate {
                var f = new FakeOwnedDesktop(); f.Snapshot["watchdogCreationFileTime"] = 134000000000000001L;
                Reject(delegate { Controller(f, "Inspect").Execute(); }, "Invalid watchdogCreationFileTime");
            });
            foreach (int count in new int[] {0, 2}) {
                int size = count;
                Test("reject owned membership count " + size, delegate {
                    var f = new FakeOwnedDesktop(); var rows = new List<object>();
                    for (int i = 0; i < size; i++) rows.Add(new Dictionary<string, object> {{"pid",30},{"creationFileTime","134000000000000003"}});
                    f.Snapshot["members"] = rows.ToArray();
                    Reject(delegate { Controller(f, "Key").Execute(); }, "exact current owned member"); Assert(NoInput(f), "Input sent");
                });
            }
            Test("reject member PID reuse", delegate {
                var f = new FakeOwnedDesktop(); ((Dictionary<string, object>)((object[])f.Snapshot["members"])[0])["creationFileTime"] = "134000000000000004";
                Reject(delegate { Controller(f, "Key").Execute(); }, "creation identity"); Assert(NoInput(f), "Input sent");
            });
            Test("reject changing client during identity verification", delegate {
                var f = new FakeOwnedDesktop(); f.OnInspect = delegate(FakeOwnedDesktop d, int n) { if (n == 2) d.X++; };
                Reject(delegate { Controller(f, "Key").Execute(); }, "bounds changed"); Assert(NoInput(f), "Input sent");
            });
            Test("reject focus loss before input", delegate {
                var f = new FakeOwnedDesktop(); f.Foreground = false;
                Reject(delegate { Controller(f, "Key").Execute(); }, "foreground focus"); Assert(NoInput(f), "Input sent");
            });
            Test("inspect permits background window and preserves result schema", delegate {
                var f = new FakeOwnedDesktop(); f.Foreground = false;
                var result = Controller(f, "Inspect").Execute();
                Assert((string)result["schema"] == "owned-game-window-action/v1" && (string)result["status"] == "completed" && NoInput(f), "Inspect result");
                Assert(f.Events.Contains("verify:20") && f.Events.Contains("verify:30") && f.Events.Contains("dpi-restore"), "Missing verification");
            });
            Test("focus confirms foreground after request", delegate {
                var f = new FakeOwnedDesktop(); f.Foreground = false;
                Controller(f, "Focus").Execute(); Assert(f.Foreground && f.Reads >= 3 && NoInput(f), "Focus verification");
            });
            Test("focus refusal fails", delegate {
                var f = new FakeOwnedDesktop(); f.FocusSucceeds = false;
                Reject(delegate { Controller(f, "Focus").Execute(); }, "refused foreground");
            });
            Test("ambiguous enumeration fails", delegate {
                var f = new FakeOwnedDesktop(); f.Windows = new long[] {101, 102};
                var options = Options("Inspect"); options["WindowHandle"] = "0";
                Reject(delegate { new OwnedWindowController(f, OwnedWindowRequest.Parse(OwnedWindowJson.Serialize(options))).Execute(); }, "exactly one");
            });
            foreach (string action in new string[] {"Click", "Key"}) {
                string kind = action;
                Test(kind + " releases own input on focus loss during hold", delegate {
                    var f = new FakeOwnedDesktop(); f.DownLosesFocus = true;
                    Reject(delegate { Controller(f, kind).Execute(); }, "foreground focus");
                    string up = kind == "Click" ? "mouse:left:up" : "key:87:up";
                    Assert(f.Events.Contains(up) && f.Events[f.Events.Count - 1] == "dpi-restore", "Missing release/restore");
                    Assert(f.Events.FindAll(delegate(string e) { return e.EndsWith(":up"); }).Count == 1, "Released unrelated input");
                });
                Test(kind + " attempts release when down SendInput fails", delegate {
                    var f = new FakeOwnedDesktop(); f.FailEvent = kind == "Click" ? "mouse:left:down" : "key:87:down";
                    Reject(delegate { Controller(f, kind).Execute(); }, "injected");
                    Assert(f.Events.Contains(kind == "Click" ? "mouse:left:up" : "key:87:up"), "Missing release");
                });
                Test(kind + " holds bounded input with repeated ownership reads", delegate {
                    var f = new FakeOwnedDesktop(); Controller(f, kind).Execute();
                    Assert(f.Now == 10080 && f.Reads >= 6 && f.Events.Contains("unobscured"), "Missing bounded hold or checks");
                });
            }
            foreach (string failure in new string[] {"unobscured", "released:87", "cursor"}) {
                string stage = failure;
                Test("reject " + stage + " before down", delegate {
                    var f = new FakeOwnedDesktop(); f.FailEvent = stage;
                    Reject(delegate { Controller(f, stage == "cursor" ? "Click" : "Key").Execute(); }, "injected");
                    Assert(!f.Events.Exists(delegate(string e) { return e.EndsWith(":down") || e.EndsWith(":up"); }), "Unexpected button/key event");
                });
            }
            Test("MouseLook post-failure is never retry safe", delegate {
                var f = new FakeOwnedDesktop(); f.MoveLosesFocus = true; var controller = Controller(f, "MouseLook");
                Reject(delegate { controller.Execute(); }, "foreground focus");
                var failure = controller.FailureReport;
                Assert((bool)failure["inputAttempted"] && (bool)failure["inputSent"] && !(bool)failure["automaticRetrySafe"], "Incorrect movement failure receipt");
                Assert(f.Events.FindAll(delegate(string e) { return e == "relative-move"; }).Count == 1, "Retried or reversed input");
            });
            Test("MouseLook failed SendInput reports attempted but not sent", delegate {
                var f = new FakeOwnedDesktop(); f.FailEvent = "relative-move"; var controller = Controller(f, "MouseLook");
                Reject(delegate { controller.Execute(); }, "injected");
                Assert((bool)controller.FailureReport["inputAttempted"] && !(bool)controller.FailureReport["inputSent"], "Incorrect attempted state");
            });
            Test("MouseLook precheck failure reports no attempted input", delegate {
                var f = new FakeOwnedDesktop(); f.Foreground = false; var controller = Controller(f, "MouseLook");
                Reject(delegate { controller.Execute(); }, "foreground focus");
                Assert(!(bool)controller.FailureReport["inputAttempted"] && NoInput(f), "Incorrect attempted state");
            });
            Test("capture movement invalidates screenshot before save", delegate {
                var f = new FakeOwnedDesktop(); f.CaptureMoves = true;
                Reject(delegate { Controller(f, "Capture").Execute(); }, "Client moved during capture");
                Assert(!f.Events.Contains("capture-save") && NoInput(f), "Saved invalid capture");
            });
            Test("capture verifies after pixel copy before save", delegate {
                var f = new FakeOwnedDesktop(); Controller(f, "Capture").Execute();
                Assert(f.Events.IndexOf("capture-copy") < f.Events.LastIndexOf("verify:30") &&
                    f.Events.LastIndexOf("verify:30") < f.Events.IndexOf("capture-save"), "Capture verification order");
            });
            Test("64-bit HWND parsed losslessly", delegate {
                var options = Options("Inspect"); options["WindowHandle"] = "9007199254740993";
                Assert(OwnedWindowRequest.Parse(OwnedWindowJson.Serialize(options)).WindowHandle == 9007199254740993L, "Rounded HWND");
            });
            foreach (string field in new string[] {"Dx", "Dy", "HoldMilliseconds", "WindowHandle", "ExpectedClientWidth", "Key"}) {
                string key = field;
                Test("reject invalid request " + key, delegate {
                    var options = Options("Key"); options[key] = key == "Key" ? "Control" : "99999999999999999999";
                    Reject(delegate { OwnedWindowRequest.Parse(OwnedWindowJson.Serialize(options)); }, key == "Key" ? "Key must" : "integer");
                });
            }
            Test("input requires inspected window dimensions", delegate {
                var options = Options("Key"); options.Remove("ExpectedClientHeight");
                Reject(delegate { OwnedWindowRequest.Parse(OwnedWindowJson.Serialize(options)); }, "Input requires");
            });
            Test("size mismatch fails before input", delegate {
                var f = new FakeOwnedDesktop(); var options = Options("Key"); options["ExpectedClientWidth"] = "1200";
                Reject(delegate { new OwnedWindowController(f, OwnedWindowRequest.Parse(OwnedWindowJson.Serialize(options))).Execute(); }, "Client size differs");
                Assert(NoInput(f), "Input sent");
            });
            Test("outside click rejected before cursor movement", delegate {
                var f = new FakeOwnedDesktop(); var options = Options("Click"); options["X"] = "1280";
                Reject(delegate { new OwnedWindowController(f, OwnedWindowRequest.Parse(OwnedWindowJson.Serialize(options))).Execute(); }, "inside client");
                Assert(NoInput(f), "Input sent");
            });
            Test("bounded JSON input rejects oversized input", delegate {
                Reject(delegate { OwnedWindowJson.ReadBounded(new StringReader(new string('x', 1048577))); }, "Oversized");
            });
            Console.WriteLine(OwnedWindowJson.Serialize(new { evidenceLevel = "synthetic", passed = true, testCount = passed.Count, tests = passed, scope = "Production controller and ABI validation with fake desktop; no Windows API calls or live gameplay." }));
            return 0;
        } catch (Exception error) {
            Console.Error.WriteLine(error.ToString());
            Console.WriteLine(OwnedWindowJson.Serialize(new { evidenceLevel = "synthetic", passed = false, completed = passed }));
            return 1;
        }
    }
}

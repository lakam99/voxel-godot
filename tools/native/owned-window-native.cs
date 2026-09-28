using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public sealed class OwnedGameWindowInfo {
    public long Hwnd; public uint Pid; public int X, Y, Width, Height;
    public string ClassName; public bool Foreground;
}

// The controller and its pure tests share this boundary. Production always uses
// WindowsDesktop; no CLI option can replace ownership checks or native input.
public interface IOwnedDesktop {
    string ReadSnapshot(string path);
    ulong Tick();
    void Sleep(int milliseconds);
    void VerifyProcess(uint pid, string creation);
    OwnedGameWindowInfo Inspect(long handle);
    long[] VisibleGameWindows();
    void VerifyUnobscured(OwnedGameWindowInfo info);
    void VerifyPoint(long handle, int x, int y);
    void VerifyCursor(long handle, int x, int y);
    void AssertInputsReleased(int key);
    void MoveCursor(int x, int y);
    void RelativeMouseMove(int dx, int dy);
    void MouseButton(bool right, bool up);
    void Keyboard(ushort key, bool up);
    bool Focus(long handle);
    IntPtr SetDpi(IntPtr value);
    void Capture(OwnedGameWindowInfo info, string path, Action verifyAfterCopy);
}

public sealed class WindowsDesktop : IOwnedDesktop {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x,y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left,top,right,bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx,dy; public uint mouseData,dwFlags,time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk,wScan; public uint dwFlags,time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION data; }
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr arg);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint command);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder text, int size);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT point);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count, INPUT[] input, int size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr h, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint milliseconds);
    [DllImport("kernel32.dll")] static extern uint GetProcessId(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern ulong GetTickCount64();

    public string ReadSnapshot(string path) {
        using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
            if (file.Length > 1048576) throw new InvalidOperationException("Oversized live ownership snapshot.");
            using (var reader = new StreamReader(file)) return OwnedWindowJson.ReadBounded(reader);
        }
    }
    public ulong Tick() { return GetTickCount64(); }
    public void Sleep(int milliseconds) { Thread.Sleep(milliseconds); }
    public bool Focus(long handle) { return SetForegroundWindow(new IntPtr(handle)); }
    public IntPtr SetDpi(IntPtr value) { return SetThreadDpiAwarenessContext(value); }

    public void VerifyProcess(uint pid, string expectedCreation) {
        IntPtr h=OpenProcess(0x00100000|0x1000,false,pid);
        if (h==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot open owned process identity");
        try {
            long creation,exit,kernel,user;
            if (GetProcessId(h)!=pid || WaitForSingleObject(h,0)!=258 ||
                !GetProcessTimes(h,out creation,out exit,out kernel,out user) || creation.ToString(System.Globalization.CultureInfo.InvariantCulture)!=expectedCreation)
                throw new InvalidOperationException("Owned PID creation identity changed or exited");
        } finally { if (!CloseHandle(h)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Identity handle close failed"); }
    }
    public OwnedGameWindowInfo Inspect(long handle) {
        IntPtr h=new IntPtr(handle); uint pid; RECT rect; POINT origin=new POINT();
        var name=new StringBuilder(256);
        if (!IsWindow(h) || !IsWindowVisible(h) || IsIconic(h) || GetAncestor(h,2)!=h ||
            GetWindow(h,4)!=IntPtr.Zero || GetClassNameW(h,name,name.Capacity)==0 || name.ToString()!="Engine" ||
            GetWindowThreadProcessId(h,out pid)==0 || !GetClientRect(h,out rect) || !ClientToScreen(h,ref origin))
            throw new InvalidOperationException("Not an available top-level Godot game window");
        int width=rect.right-rect.left, height=rect.bottom-rect.top;
        if (width<64 || height<64 || width>16384 || height>16384) throw new InvalidOperationException("Invalid game client size");
        return new OwnedGameWindowInfo {Hwnd=handle,Pid=pid,X=origin.x,Y=origin.y,Width=width,Height=height,ClassName=name.ToString(),Foreground=GetForegroundWindow()==h};
    }
    public long[] VisibleGameWindows() {
        var result=new List<long>();
        if (!EnumWindows(delegate(IntPtr h,IntPtr unused) {
            try { Inspect(h.ToInt64()); result.Add(h.ToInt64()); } catch (InvalidOperationException) { }
            return true;
        },IntPtr.Zero)) throw new InvalidOperationException("Cannot enumerate game windows.");
        return result.ToArray();
    }
    public void VerifyUnobscured(OwnedGameWindowInfo info) {
        int left=GetSystemMetrics(76), top=GetSystemMetrics(77), width=GetSystemMetrics(78), height=GetSystemMetrics(79);
        if (info.X<left || info.Y<top || info.X+info.Width>left+width || info.Y+info.Height>top+height)
            throw new InvalidOperationException("Game client is outside the virtual screen");
        IntPtr target=new IntPtr(info.Hwnd); int count=0;
        for (IntPtr h=GetWindow(target,3); h!=IntPtr.Zero; h=GetWindow(h,3)) {
            if (++count>4096) throw new InvalidOperationException("Window order did not stabilize");
            if (!IsWindowVisible(h) || IsIconic(h)) continue;
            RECT rect;
            if (!GetWindowRect(h,out rect)) throw new InvalidOperationException("Cannot inspect overlapping window");
            if (rect.left<info.X+info.Width && rect.right>info.X && rect.top<info.Y+info.Height && rect.bottom>info.Y)
                throw new InvalidOperationException("Game client is obscured by another window");
        }
    }
    public void VerifyPoint(long window, int x, int y) {
        var point=new POINT {x=x,y=y};
        if (GetAncestor(WindowFromPoint(point),2)!=new IntPtr(window)) throw new InvalidOperationException("Click point is not on the owned game window");
    }
    public void VerifyCursor(long window, int x, int y) {
        POINT point;
        if (!GetCursorPos(out point) || point.x!=x || point.y!=y) throw new InvalidOperationException("Cursor moved away from requested click point");
        VerifyPoint(window,x,y);
    }
    public void AssertInputsReleased(int requestedKey) {
        foreach (int key in new int[]{1,2,4,16,17,18,91,92,requestedKey})
            if (key>0 && (GetAsyncKeyState(key)&0x8000)!=0) throw new InvalidOperationException("User input or modifier is already held");
    }
    static void Send(INPUT value) {
        if (SendInput(1,new INPUT[]{value},Marshal.SizeOf(typeof(INPUT)))!=1)
            throw new Win32Exception(Marshal.GetLastWin32Error(),"SendInput did not insert exactly one event");
    }
    public void MoveCursor(int x,int y) {
        int left=GetSystemMetrics(76),top=GetSystemMetrics(77),width=GetSystemMetrics(78),height=GetSystemMetrics(79);
        if (width<=1 || height<=1) throw new InvalidOperationException("Invalid virtual desktop");
        Send(new INPUT {type=0,data=new INPUTUNION {mi=new MOUSEINPUT {dx=(int)Math.Round((x-left)*65535.0/(width-1)),dy=(int)Math.Round((y-top)*65535.0/(height-1)),dwFlags=0x0001|0x8000|0x4000}}});
    }
    public void RelativeMouseMove(int dx,int dy) {
        if (dx < -1000 || dx > 1000 || dy < -1000 || dy > 1000)
            throw new ArgumentOutOfRangeException("Relative mouse delta exceeds 1000");
        Send(new INPUT {type=0,data=new INPUTUNION {mi=new MOUSEINPUT {dx=dx,dy=dy,dwFlags=0x0001}}});
    }
    public void MouseButton(bool right,bool up) {
        Send(new INPUT {type=0,data=new INPUTUNION {mi=new MOUSEINPUT {dwFlags=right?(up?0x0010u:0x0008u):(up?0x0004u:0x0002u)}}});
    }
    public void Keyboard(ushort key,bool up) {
        uint extended=(key>=0x21 && key<=0x28)?1u:0u;
        Send(new INPUT {type=1,data=new INPUTUNION {ki=new KEYBDINPUT {wVk=key,dwFlags=extended|(up?2u:0u)}}});
    }
    public void Capture(OwnedGameWindowInfo info, string path, Action verifyAfterCopy) {
        if (File.Exists(path) || Directory.Exists(path)) throw new InvalidOperationException("Capture path already exists.");
        using (var bitmap = new Bitmap(info.Width, info.Height))
        using (var graphics = Graphics.FromImage(bitmap)) {
            graphics.CopyFromScreen(info.X, info.Y, 0, 0, bitmap.Size, CopyPixelOperation.SourceCopy);
            verifyAfterCopy();
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                bitmap.Save(file, ImageFormat.Png);
        }
    }
}

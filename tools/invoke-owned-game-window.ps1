[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$LiveOwnershipPath,
    [Parameter(Mandatory=$true)][string]$RunId,
    [Parameter(Mandatory=$true)][string]$ProjectPath,
    [ValidateSet('Inspect','Focus','Capture','Click','Key')][string]$Action='Inspect',
    [long]$WindowHandle=0,
    [string]$CapturePath,
    [int]$X=-1,
    [int]$Y=-1,
    [ValidateSet('Left','Right')][string]$Button='Left',
    [string]$Key,
    [ValidateRange(1,2000)][int]$HoldMilliseconds=80,
    [int]$ExpectedClientWidth=0,
    [int]$ExpectedClientHeight=0
)
# One action per invocation. Inspect first; pass its exact HWND and client size
# for input. Capture does not use PrintWindow (GPU content may be absent): it
# captures the unobscured foreground client pixels, then revalidates ownership.
# Live JSON is local trusted IPC, NOT a security boundary against a malicious
# process able to rewrite the run directory. No PID ancestry/title selection.
# SendInput is global, not HWND-addressed: never use concurrently with a person
# or another desktop driver. Focus is checked before input and during each hold;
# finally releases ONLY this helper's attempted key/button, even on focus loss.
# https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-sendinput
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if (-not ('OwnedGameWindowNativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class OwnedGameWindowInfo {
    public long Hwnd; public uint Pid; public int X, Y, Width, Height;
    public string ClassName; public bool Foreground;
}
public static class OwnedGameWindowNativeV1 {
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
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder text, int size);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT point);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count, INPUT[] input, int size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr h, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint milliseconds);
    [DllImport("kernel32.dll")] static extern uint GetProcessId(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();

    public static void VerifyProcess(uint pid, string expectedCreation) {
        IntPtr h=OpenProcess(0x00100000|0x1000,false,pid);
        if (h==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot open owned process identity");
        try {
            long creation,exit,kernel,user;
            if (GetProcessId(h)!=pid || WaitForSingleObject(h,0)!=258 ||
                !GetProcessTimes(h,out creation,out exit,out kernel,out user) || creation.ToString()!=expectedCreation)
                throw new InvalidOperationException("Owned PID creation identity changed or exited");
        } finally { if (!CloseHandle(h)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Identity handle close failed"); }
    }
    public static OwnedGameWindowInfo Inspect(long handle) {
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
    public static long[] VisibleGameWindows() {
        var result=new List<long>();
        EnumWindows(delegate(IntPtr h,IntPtr unused) {
            try { Inspect(h.ToInt64()); result.Add(h.ToInt64()); } catch (InvalidOperationException) { }
            return true;
        },IntPtr.Zero);
        return result.ToArray();
    }
    public static void VerifyUnobscured(OwnedGameWindowInfo info) {
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
    public static void VerifyPoint(long window, int x, int y) {
        var point=new POINT {x=x,y=y};
        if (GetAncestor(WindowFromPoint(point),2)!=new IntPtr(window)) throw new InvalidOperationException("Click point is not on the owned game window");
    }
    public static void VerifyCursor(long window, int x, int y) {
        POINT point;
        if (!GetCursorPos(out point) || point.x!=x || point.y!=y) throw new InvalidOperationException("Cursor moved away from requested click point");
        VerifyPoint(window,x,y);
    }
    public static void AssertInputsReleased(int requestedKey) {
        foreach (int key in new int[]{1,2,4,16,17,18,91,92,requestedKey})
            if (key>0 && (GetAsyncKeyState(key)&0x8000)!=0) throw new InvalidOperationException("User input or modifier is already held");
    }
    static void Send(INPUT value) {
        if (SendInput(1,new INPUT[]{value},Marshal.SizeOf(typeof(INPUT)))!=1)
            throw new Win32Exception(Marshal.GetLastWin32Error(),"SendInput did not insert exactly one event");
    }
    public static void MoveCursor(int x,int y) {
        int left=GetSystemMetrics(76),top=GetSystemMetrics(77),width=GetSystemMetrics(78),height=GetSystemMetrics(79);
        if (width<=1 || height<=1) throw new InvalidOperationException("Invalid virtual desktop");
        Send(new INPUT {type=0,data=new INPUTUNION {mi=new MOUSEINPUT {dx=(int)Math.Round((x-left)*65535.0/(width-1)),dy=(int)Math.Round((y-top)*65535.0/(height-1)),dwFlags=0x0001|0x8000|0x4000}}});
    }
    public static void MouseButton(bool right,bool up) {
        Send(new INPUT {type=0,data=new INPUTUNION {mi=new MOUSEINPUT {dwFlags=right?(up?0x0010u:0x0008u):(up?0x0004u:0x0002u)}}});
    }
    public static void Keyboard(ushort key,bool up) {
        uint extended=(key>=0x21 && key<=0x28)?1u:0u;
        Send(new INPUT {type=1,data=new INPUTUNION {ki=new KEYBDINPUT {wVk=key,dwFlags=extended|(up?2u:0u)}}});
    }
}
'@
}

$ownershipFile=[IO.Path]::GetFullPath($LiveOwnershipPath)
$expectedProject=[IO.Path]::GetFullPath($ProjectPath)
$lastSequence=[long]-1
function Read-Ownership {
    $stream=$null; $reader=$null
    try {
        $stream=[IO.FileStream]::new($ownershipFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($stream.Length -gt 1048576) { throw 'Oversized live ownership snapshot.' }
        $reader=[IO.StreamReader]::new($stream)
        $value=$reader.ReadToEnd() | ConvertFrom-Json
    } finally {
        if ($null -ne $reader) { $reader.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() }
    }
    if ($value.schema -cne 'godot-live-ownership/v1' -or $value.runId -cne $RunId -or $value.state -cne 'running' -or
        $value.authority -cne 'Windows Job Object membership' -or [IO.Path]::GetFullPath($value.projectPath) -ine $expectedProject) {
        throw 'Wrong/inactive live ownership source.'
    }
    $now=[OwnedGameWindowNativeV1]::GetTickCount64()
    $observed=[uint64]::Parse([string]$value.observedTickMilliseconds)
    if ($observed -gt $now -or $now-$observed -gt 1000) { throw 'Live ownership snapshot is stale or future-dated.' }
    if ([long]$value.sequence -lt $script:lastSequence) { throw 'Live ownership sequence went backwards.' }
    $script:lastSequence=[long]$value.sequence
    [OwnedGameWindowNativeV1]::VerifyProcess([uint32]$value.watchdogPid,[string]$value.watchdogCreationFileTime)
    return $value
}

function Confirm-Window([long]$Handle, [bool]$RequireForeground) {
    $live=Read-Ownership
    $info=[OwnedGameWindowNativeV1]::Inspect($Handle)
    $members=@($live.members | Where-Object { [long]$_.pid -eq [long]$info.Pid })
    if ($members.Count -ne 1) { throw 'Window PID is not an exact current owned member.' }
    [OwnedGameWindowNativeV1]::VerifyProcess($info.Pid,[string]$members[0].creationFileTime)
    $again=[OwnedGameWindowNativeV1]::Inspect($Handle)
    if ($again.Pid -ne $info.Pid -or $again.X -ne $info.X -or $again.Y -ne $info.Y -or $again.Width -ne $info.Width -or $again.Height -ne $info.Height) {
        throw 'Window identity or client bounds changed during verification.'
    }
    if ($RequireForeground -and -not $again.Foreground) { throw 'Owned game window lost foreground focus.' }
    return $again
}

function Confirm-StableWindow($Original) {
    $current=Confirm-Window $Original.Hwnd $true
    if ($current.X -ne $Original.X -or $current.Y -ne $Original.Y -or $current.Width -ne $Original.Width -or $current.Height -ne $Original.Height) {
        throw 'Client moved/resized before or during input.'
    }
    return $current
}

if ($Action -in @('Click','Key') -and ($WindowHandle -le 0 -or $ExpectedClientWidth -lt 64 -or $ExpectedClientHeight -lt 64)) {
    throw 'Input requires the inspected HWND and expected client width/height.'
}
if ($Action -eq 'Capture' -and [string]::IsNullOrWhiteSpace($CapturePath)) { throw 'CapturePath is required.' }
$keyCode=[ushort]0
if ($Action -eq 'Key') {
    $named=@{Enter=13;Escape=27;Space=32;Tab=9;Shift=16;Backspace=8;Left=37;Up=38;Right=39;Down=40;F3=114}
    if ($named.ContainsKey($Key)) { $keyCode=[ushort]$named[$Key] }
    elseif ($Key -cmatch '^[a-zA-Z0-9]$') { $keyCode=[ushort][char]$Key.ToUpperInvariant() }
    else { throw 'Key must be one letter/digit or Enter/Escape/Space/Tab/Shift/Backspace/arrow/F3.' }
}
$dpiPrevious=[OwnedGameWindowNativeV1]::SetThreadDpiAwarenessContext([IntPtr](-4))
if ($dpiPrevious -eq [IntPtr]::Zero) { throw 'Unable to use physical-pixel DPI coordinates.' }
$started=[datetime]::UtcNow
try {
    $live=Read-Ownership
    if ($WindowHandle -eq 0) {
        $ownedIds=@($live.members | ForEach-Object { [long]$_.pid })
        $candidates=@([OwnedGameWindowNativeV1]::VisibleGameWindows() | Where-Object { $ownedIds -contains [long][OwnedGameWindowNativeV1]::Inspect($_).Pid })
        if ($candidates.Count -ne 1) { throw 'Expected exactly one visible owned Godot game client; provide an inspected HWND if ambiguous.' }
        $WindowHandle=[long]$candidates[0]
    }
    $info=Confirm-Window $WindowHandle ($Action -notin @('Inspect','Focus'))
    if ($Action -eq 'Focus') {
        if (-not [OwnedGameWindowNativeV1]::SetForegroundWindow([IntPtr]$WindowHandle)) { throw 'Windows refused foreground focus.' }
        $info=Confirm-Window $WindowHandle $true
    }
    if ($Action -in @('Click','Key')) {
        if ($info.Width -ne $ExpectedClientWidth -or $info.Height -ne $ExpectedClientHeight) { throw 'Client size differs from inspected input coordinates.' }
        [OwnedGameWindowNativeV1]::VerifyUnobscured($info)
        [OwnedGameWindowNativeV1]::AssertInputsReleased([int]$keyCode)
        $right=$Button -eq 'Right'; $downAttempted=$false
        try {
            if ($Action -eq 'Click') {
                if ($X -lt 0 -or $Y -lt 0 -or $X -ge $info.Width -or $Y -ge $info.Height) { throw 'Click must be inside client pixels.' }
                $screenX=$info.X+$X; $screenY=$info.Y+$Y
                [OwnedGameWindowNativeV1]::VerifyPoint($WindowHandle,$screenX,$screenY)
                [OwnedGameWindowNativeV1]::MoveCursor($screenX,$screenY)
                $null=Confirm-StableWindow $info
                [OwnedGameWindowNativeV1]::VerifyCursor($WindowHandle,$screenX,$screenY)
                $downAttempted=$true
                [OwnedGameWindowNativeV1]::MouseButton($right,$false)
            } else {
                $null=Confirm-StableWindow $info
                $downAttempted=$true
                [OwnedGameWindowNativeV1]::Keyboard($keyCode,$false)
            }
            $hold=[Diagnostics.Stopwatch]::StartNew()
            do {
                $null=Confirm-StableWindow $info
                $remaining=$HoldMilliseconds-$hold.ElapsedMilliseconds
                if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int][math]::Min(25,$remaining)) }
            } while ($hold.ElapsedMilliseconds -lt $HoldMilliseconds)
        } finally {
            if ($downAttempted) {
                if ($Action -eq 'Click') { [OwnedGameWindowNativeV1]::MouseButton($right,$true) }
                else { [OwnedGameWindowNativeV1]::Keyboard($keyCode,$true) }
            }
        }
    }
    $savedCapture=$null
    if ($Action -eq 'Capture') {
        $savedCapture=[IO.Path]::GetFullPath($CapturePath)
        if ([IO.File]::Exists($savedCapture) -or [IO.Directory]::Exists($savedCapture)) { throw 'Capture path already exists.' }
        [OwnedGameWindowNativeV1]::VerifyUnobscured($info)
        Add-Type -AssemblyName System.Drawing
        $bitmap=$null; $graphics=$null; $file=$null
        try {
            $bitmap=[Drawing.Bitmap]::new($info.Width,$info.Height)
            $graphics=[Drawing.Graphics]::FromImage($bitmap)
            $graphics.CopyFromScreen($info.X,$info.Y,0,0,$bitmap.Size,[Drawing.CopyPixelOperation]::SourceCopy)
            $after=Confirm-Window $WindowHandle $true
            [OwnedGameWindowNativeV1]::VerifyUnobscured($after)
            if ($after.X -ne $info.X -or $after.Y -ne $info.Y -or $after.Width -ne $info.Width -or $after.Height -ne $info.Height) { throw 'Client moved during capture.' }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($savedCapture))
            $file=[IO.FileStream]::new($savedCapture,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $bitmap.Save($file,[Drawing.Imaging.ImageFormat]::Png)
        } finally {
            if ($null -ne $file) { $file.Dispose() }
            if ($null -ne $graphics) { $graphics.Dispose() }
            if ($null -ne $bitmap) { $bitmap.Dispose() }
        }
    }
    [ordered]@{schema='owned-game-window-action/v1';runId=$RunId;action=$Action;status='completed';startedUtc=$started.ToString('o');completedUtc=[datetime]::UtcNow.ToString('o');ownershipSequence=$lastSequence;window=$info;capturePath=$savedCapture;key=$Key;button=$Button;clientX=$X;clientY=$Y;requestedHoldMilliseconds=$HoldMilliseconds} | ConvertTo-Json -Depth 5 -Compress
} finally {
    if ([OwnedGameWindowNativeV1]::SetThreadDpiAwarenessContext($dpiPrevious) -eq [IntPtr]::Zero) { throw 'DPI context restoration failed.' }
}

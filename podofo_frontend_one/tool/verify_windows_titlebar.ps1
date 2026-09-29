param(
    [string]$Flutter = 'flutter',
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifacts = Join-Path $projectRoot 'build/titlebar-review'
New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
Push-Location $projectRoot
try {
    if (!$SkipBuild) {
        try {
            # CMake development warnings on stderr are not build failures.
            $ErrorActionPreference = 'Continue'
            & $Flutter build windows --release --no-pub -t tool/title_bar_smoke.dart
            $buildExitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = 'Stop' }
        if ($buildExitCode -ne 0) { throw 'Native fixture build failed.' }
    }
    # Reject the normal app before launching anything: it opens the user's data.
    $configPath = Join-Path $projectRoot 'windows/flutter/ephemeral/generated_config.cmake'
    if (!(Test-Path -LiteralPath $configPath) -or
        ([IO.File]::ReadAllText($configPath).Replace('\', '/') -notmatch
            '"FLUTTER_TARGET=tool/+title_bar_smoke\.dart"')) {
        throw 'The current build is not the isolated title bar fixture. Run without -SkipBuild.'
    }
    Add-Type -AssemblyName Accessibility
    Add-Type -AssemblyName System.Drawing
    Add-Type -ReferencedAssemblies ([Accessibility.IAccessible].Assembly.Location),System.Drawing @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Accessibility;
public static class NativeCaptionTest {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int x,y; }
    [StructLayout(LayoutKind.Sequential)] public struct HighContrast { public uint size, flags; public IntPtr scheme; }
    [StructLayout(LayoutKind.Sequential)] public struct TitleInfo {
        public int size; public Rect bounds;
        [MarshalAs(UnmanagedType.ByValArray,SizeConst=6)] public int[] states;
        [MarshalAs(UnmanagedType.ByValArray,SizeConst=6)] public Rect[] rects;
    }
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action,uint size,ref HighContrast value,uint flags);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
    [DllImport("user32.dll",EntryPoint="SendMessageW")] static extern IntPtr GetTitleInfo(IntPtr hwnd,uint msg,IntPtr wp,ref TitleInfo info);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd,IntPtr dc,uint flags);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string name,string title);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr hwnd,ref Point point);
    [DllImport("user32.dll")] static extern int GetWindowRgn(IntPtr hwnd,IntPtr region);
    [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int left,int top,int right,int bottom);
    [DllImport("gdi32.dll")] static extern bool PtInRegion(IntPtr region,int x,int y);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr hwnd,uint id,ref Guid iid,[MarshalAs(UnmanagedType.Interface)] out IAccessible accessible);
    static IAccessible Accessible(IntPtr hwnd) {
        var iid = typeof(IAccessible).GUID; IAccessible accessible;
        Marshal.ThrowExceptionForHR(AccessibleObjectFromWindow(hwnd,0xfffffffe,ref iid,out accessible));
        return accessible;
    }
    public static void Invoke(IntPtr hwnd,int child) {
        var accessible = Accessible(hwnd);
        try { accessible.accDoDefaultAction(child); }
        finally { Marshal.ReleaseComObject(accessible); }
    }
    public static void VerifyAppearance(IntPtr hwnd,bool dark) {
        var contrast = new HighContrast { size=(uint)Marshal.SizeOf(typeof(HighContrast)) };
        if(!SystemParametersInfo(0x42,contrast.size,ref contrast,0)) throw new Exception("Cannot read high-contrast preference.");
        // High contrast deliberately uses system colors, not app light/dark.
        if((contrast.flags & 1) != 0) return;
        var info = new TitleInfo { size=Marshal.SizeOf(typeof(TitleInfo)) };
        GetTitleInfo(hwnd,0x33f,IntPtr.Zero,ref info);
        Rect window; GetWindowRect(hwnd,out window);
        var button = info.rects[2];
        using(var bitmap = Render(hwnd)) {
            // Sample inside Minimize's backplate, away from its glyph and border.
            var color = bitmap.GetPixel(button.left+(button.right-button.left)/4-window.left,
                                        (button.top+button.bottom)/2-window.top);
            int expected = dark ? 0 : 255;
            if(Math.Abs(color.R-expected)>8 || Math.Abs(color.G-expected)>8 || Math.Abs(color.B-expected)>8)
                throw new Exception("Native caption color differs from app preference: " + color);
        }
    }
    public static string Verify(IntPtr hwnd) {
        var info = new TitleInfo { size = Marshal.SizeOf(typeof(TitleInfo)) };
        GetTitleInfo(hwnd,0x33f,IntPtr.Zero,ref info);
        var accessible = Accessible(hwnd);
        var child = FindWindowEx(hwnd,IntPtr.Zero,"FLUTTERVIEW",null);
        var region = CreateRectRgn(0,0,0,0);
        try {
            if(GetWindowRgn(child,region) == 0) throw new Exception("Flutter view has no caption cutout.");
            var ids = new[]{2,3,5}; var expected = new[]{8,9,20}; var names = new string[3];
            for(int i=0;i<3;i++) {
                int id = ids[i]; var rect = info.rects[id];
                int x=(rect.left+rect.right)/2, y=(rect.top+rect.bottom)/2;
                var point = new Point { x=x,y=y };
                int hit = SendMessage(hwnd,0x84,IntPtr.Zero,new IntPtr((y<<16)|(x&0xffff))).ToInt32();
                if(hit != expected[i]) throw new Exception("Caption hit test: expected " + expected[i] + ", got " + hit);
                ScreenToClient(child,ref point);
                if(PtInRegion(region,point.x,point.y)) throw new Exception("Flutter obscures a native caption button.");
                names[i] = accessible.get_accName(id);
                if(String.IsNullOrEmpty(names[i])) throw new Exception("Missing accessible caption name.");
                if(Convert.ToInt32(accessible.get_accRole(id)) != 43) throw new Exception("Caption must expose ROLE_SYSTEM_PUSHBUTTON.");
                if((Convert.ToInt32(accessible.get_accState(id)) & 0x8001) != 0) throw new Exception("Caption is unavailable or invisible.");
            }
            return String.Join(", ",names);
        } finally { DeleteObject(region); Marshal.ReleaseComObject(accessible); }
    }
    static Bitmap Render(IntPtr hwnd) {
        Rect rect; GetWindowRect(hwnd,out rect);
        var bitmap = new Bitmap(rect.right-rect.left,rect.bottom-rect.top);
        try {
            using(var graphics = Graphics.FromImage(bitmap)) {
                var dc = graphics.GetHdc();
                try { if(!PrintWindow(hwnd,dc,2)) throw new Exception("Window capture failed."); }
                finally { graphics.ReleaseHdc(dc); }
            }
            return bitmap;
        } catch { bitmap.Dispose(); throw; }
    }
    public static void Capture(IntPtr hwnd,string path) {
        using(var bitmap = Render(hwnd)) bitmap.Save(path,ImageFormat.Png);
    }
}
'@
    [NativeCaptionTest]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
    function Wait-Until([scriptblock]$Condition, [string]$Failure) {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            if (& $Condition) { return }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        throw $Failure
    }
    function Wait-Captions([IntPtr]$Window) {
        # IsZoomed/IsIconic change before WM_SIZE has finished laying out the
        # Flutter child and DWM frame. Verify the settled result, not that gap.
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            try { return [NativeCaptionTest]::Verify($Window) }
            catch { $lastCaptionError = $_ }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        throw $lastCaptionError
    }
    foreach ($theme in @('dark', 'light')) {
        $events = Join-Path $artifacts ('close-' + [Guid]::NewGuid().ToString('N') + '.txt')
        $exe = Join-Path $projectRoot 'build/windows/x64/runner/Release/PoDoFo.exe'
        # SkipBuild is only for a binary previously built with title_bar_smoke.dart.
        $fixture = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -ArgumentList ('"' + $events + '" ' + $theme) -WindowStyle Hidden -PassThru
        $null = $fixture.Handle
        try {
            Wait-Until { $fixture.Refresh(); $fixture.MainWindowHandle -ne 0 } 'Fixture did not create a window.'
            $window = $fixture.MainWindowHandle
            Wait-Until { $fixture.Refresh(); $fixture.MainWindowTitle -eq 'PoDoFo caption test' } 'The executable is not the isolated title bar fixture.'
            Wait-Until {
                try { [NativeCaptionTest]::VerifyAppearance($window, $theme -eq 'dark'); return $true }
                catch { return $false }
            } 'Native caption appearance did not follow the app theme.'
            Write-Output ('Theme: ' + $theme)
            Write-Output ('Restored: ' + (Wait-Captions $window))
            # Caption bounds settle before Flutter presents its resized frame.
            Start-Sleep -Milliseconds 1000
            [NativeCaptionTest]::Capture($window,(Join-Path $artifacts ($theme + '-restored.png')))
            [NativeCaptionTest]::Invoke($window,3)
            Wait-Until { [NativeCaptionTest]::IsZoomed($window) } 'Native Maximize action failed.'
            Write-Output ('Maximized: ' + (Wait-Captions $window))
            Start-Sleep -Milliseconds 1000
            [NativeCaptionTest]::Capture($window,(Join-Path $artifacts ($theme + '-maximized.png')))
            [NativeCaptionTest]::Invoke($window,3)
            Wait-Until { ![NativeCaptionTest]::IsZoomed($window) } 'Native Restore action failed.'
            Write-Output ('Restored again: ' + (Wait-Captions $window))
            [NativeCaptionTest]::Invoke($window,2)
            Wait-Until { [NativeCaptionTest]::IsIconic($window) } 'Native Minimize action failed.'
            [NativeCaptionTest]::PostMessage($window,0x112,[IntPtr]0xf120,[IntPtr]::Zero) | Out-Null
            Wait-Until { ![NativeCaptionTest]::IsIconic($window) } 'Restore from minimized failed.'
            [NativeCaptionTest]::PostMessage($window,0x31e,[IntPtr]::Zero,[IntPtr]::Zero) | Out-Null
            Start-Sleep -Milliseconds 100
            [NativeCaptionTest]::VerifyAppearance($window, $theme -eq 'dark')
            [NativeCaptionTest]::Invoke($window,5)
            Wait-Until { Test-Path -LiteralPath $events } 'Close bypassed the Dart window lifecycle.'
            if (!$fixture.WaitForExit(15000)) { throw 'Guarded close did not finish.' }
            if ($fixture.ExitCode -ne 0) { throw "Fixture exited with $($fixture.ExitCode)." }
            Write-Output 'Native hit testing, clipping, accessibility, window actions, and guarded close passed.'
        } finally {
            $fixture.Refresh()
            if (!$fixture.HasExited) {
                $fixture.CloseMainWindow() | Out-Null
                if (!$fixture.WaitForExit(15000)) { $fixture.Kill() }
            }
        }
    }
} finally { Pop-Location }

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'quota-model.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$codexNativeSource = @"
using System;
using System.Drawing;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class CodexTaskbarNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string windowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr handle, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr handle, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr handle);
    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr handle, IntPtr dc);
    [DllImport("gdi32.dll")]
    private static extern uint GetPixel(IntPtr dc, int x, int y);
    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr handle, int attribute, out RECT value, int size);

    [DllImport("user32.dll", EntryPoint = "SetWindowLong")]
    private static extern int SetWindowLong32(IntPtr handle, int index, int value);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
    private static extern IntPtr SetWindowLongPtr64(IntPtr handle, int index, IntPtr value);

    public static void SetOwner(IntPtr handle, IntPtr owner)
    {
        if (IntPtr.Size == 8)
            SetWindowLongPtr64(handle, -8, owner);
        else
            SetWindowLong32(handle, -8, owner.ToInt32());
    }

    public static Color SampleTaskbarBesideWindow(IntPtr handle, Color fallback)
    {
        RECT value;
        if (DwmGetWindowAttribute(handle, 9, out value, Marshal.SizeOf(typeof(RECT))) != 0)
            return fallback;
        IntPtr dc = GetDC(IntPtr.Zero);
        if (dc == IntPtr.Zero) return fallback;
        try
        {
            uint pixel = GetPixel(dc, Math.Max(0, value.Left - 4), value.Top + Math.Max(1, (value.Bottom - value.Top) / 2));
            if (pixel == 0xffffffff) return fallback;
            return Color.FromArgb((int)(pixel & 0xff), (int)((pixel >> 8) & 0xff), (int)((pixel >> 16) & 0xff));
        }
        finally { ReleaseDC(IntPtr.Zero, dc); }
    }

    public static readonly IntPtr TopMost = new IntPtr(-1);
    public const uint NoActivate = 0x0010;
    public const uint ShowWindow = 0x0040;
}

public static class CodexWidgetMouseHook
{
    public static int RightClickCount = 0;
    public const int ShowMenuMessage = 0x8000 + 83;
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT Point;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    private delegate IntPtr HookProcedure(int code, IntPtr message, IntPtr data);
    private static HookProcedure procedure;
    private static IntPtr hook = IntPtr.Zero;
    private static Rectangle bounds;
    private static Control owner;

    [DllImport("user32.dll")]
    private static extern IntPtr SetWindowsHookEx(int hookId, HookProcedure procedure, IntPtr module, uint threadId);
    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr handle, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr handle, int attribute, out CodexTaskbarNative.RECT value, int size);

    public static void SetBounds(int x, int y, int width, int height)
    {
        bounds = new Rectangle(x, y, width, height);
    }

    public static void SetBoundsFromWindow(IntPtr handle)
    {
        CodexTaskbarNative.RECT value;
        int result = DwmGetWindowAttribute(handle, 9, out value, Marshal.SizeOf(typeof(CodexTaskbarNative.RECT)));
        if (result == 0)
            bounds = Rectangle.FromLTRB(value.Left, value.Top, value.Right, value.Bottom);
    }

    public static void Start(Control callbackOwner)
    {
        Stop();
        owner = callbackOwner;
        procedure = HookCallback;
        hook = SetWindowsHookEx(14, procedure, IntPtr.Zero, 0);
        if (hook == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    public static void Stop()
    {
        if (hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }
        owner = null;
        procedure = null;
    }

    public static void InjectRightClick(int x, int y)
    {
        SetCursorPos(x, y);
        mouse_event(0x0008, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0010, 0, 0, 0, UIntPtr.Zero);
    }

    public static void InjectRightClickAtBoundsCenter()
    {
        InjectRightClick(bounds.Left + bounds.Width / 2, bounds.Top + bounds.Height / 2);
    }

    private static IntPtr HookCallback(int code, IntPtr message, IntPtr data)
    {
        const int RightButtonUp = 0x0205;
        if (code >= 0 && message.ToInt32() == RightButtonUp)
        {
            MSLLHOOKSTRUCT value = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(data, typeof(MSLLHOOKSTRUCT));
            if (bounds.Contains(value.Point.X, value.Point.Y))
            {
                Control callbackOwner = owner;
                int x = value.Point.X;
                int y = value.Point.Y;
                if (callbackOwner != null && !callbackOwner.IsDisposed)
                {
                    RightClickCount++;
                    int packed = ((y & 0xffff) << 16) | (x & 0xffff);
                    PostMessage(callbackOwner.Handle, ShowMenuMessage, IntPtr.Zero, new IntPtr(packed));
                }
                return new IntPtr(1);
            }
        }
        return CallNextHookEx(hook, code, message, data);
    }
}

public sealed class CodexTaskbarWidgetForm : Form
{
    public CodexTaskbarWidgetForm() { DoubleBuffered = true; }
    public string TopLine = "--%";
    public string BottomLine = "--d--h";
    public Color DisplayColor = Color.White;
    public ContextMenuStrip RightClickMenu;

    protected override bool ShowWithoutActivation
    {
        get { return true; }
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams value = base.CreateParams;
            value.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            value.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            return value;
        }
    }

    protected override void OnPaint(PaintEventArgs args)
    {
        base.OnPaint(args);
        args.Graphics.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;
        using (Font font = new Font("Segoe UI", 14, FontStyle.Regular, GraphicsUnit.Pixel))
        using (Brush brush = new SolidBrush(DisplayColor))
        using (StringFormat format = new StringFormat())
        {
            format.Alignment = StringAlignment.Center;
            format.FormatFlags = StringFormatFlags.NoWrap;
            format.LineAlignment = StringAlignment.Center;
            args.Graphics.DrawString(TopLine, font, brush, new RectangleF(0, 2, Width, 20), format);
            args.Graphics.DrawString(BottomLine, font, brush, new RectangleF(0, 22, Width, 20), format);
        }
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == CodexWidgetMouseHook.ShowMenuMessage)
        {
            int packed = message.LParam.ToInt32();
            int x = (short)(packed & 0xffff);
            int y = (short)((packed >> 16) & 0xffff);
            if (RightClickMenu != null) RightClickMenu.Show(new Point(x, y));
            return;
        }
        base.WndProc(ref message);
    }
}
"@
Add-Type -TypeDefinition $codexNativeSource -ReferencedAssemblies System.Windows.Forms.dll,System.Drawing.dll

$codexMutexCreated = $false
$codexMutex = [Threading.Mutex]::new($true, 'Local\Wangnov-CodexMeter-TaskbarWidget', [ref]$codexMutexCreated)
if (-not $codexMutexCreated) {
    $codexMutex.Dispose()
    exit 0
}

$codexRoot = Join-Path $env:LOCALAPPDATA 'CodexMeter'
$codexStatePath = Join-Path $codexRoot 'widget-state.json'
$codexPidPath = Join-Path $codexRoot 'widget.pid'
$codexLogRoot = Join-Path $codexRoot 'logs'
$codexLogPath = Join-Path $codexLogRoot 'taskbar-widget.log'
$codexStopFlagPath = Join-Path $codexRoot 'stop.flag'
$codexConfigPath = Join-Path $PSScriptRoot 'taskbar-widget.json'
New-Item -ItemType Directory -Force -Path $codexRoot | Out-Null
New-Item -ItemType Directory -Force -Path $codexLogRoot | Out-Null
[IO.File]::WriteAllText($codexPidPath, [Diagnostics.Process]::GetCurrentProcess().Id.ToString(), (New-Object Text.UTF8Encoding($false)))

function Write-CodexLog {
    param([string]$Level, [string]$Message)
    try {
        if ((Test-Path -LiteralPath $codexLogPath) -and (Get-Item -LiteralPath $codexLogPath).Length -gt 1048576) {
            $codexOldLog = $codexLogPath + '.old'
            Remove-Item -LiteralPath $codexOldLog -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $codexLogPath -Destination $codexOldLog -Force
        }
        $codexSafeMessage = ([string]$Message).Replace("`r", ' ').Replace("`n", ' ')
        $codexLine = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [' + $Level + '] ' + $codexSafeMessage + [Environment]::NewLine
        [IO.File]::AppendAllText($codexLogPath, $codexLine, (New-Object Text.UTF8Encoding($true)))
    } catch {}
}

function Enable-CodexStartup {
    try {
        $codexStartBat = Join-Path $PSScriptRoot 'start-widget.bat'
        $codexRunCommand = $env:ComSpec + ' /d /c ""' + $codexStartBat + '""'
        $codexRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        New-Item -Path $codexRunKey -Force | Out-Null
        New-ItemProperty -Path $codexRunKey -Name 'CodexMeterTaskbarWidget' -Value $codexRunCommand -PropertyType String -Force | Out-Null
        Write-CodexLog 'INFO' 'Current-user startup entry enabled.'
    } catch {
        Write-CodexLog 'ERROR' ('Failed to enable startup: ' + $_.Exception.Message)
    }
}

$codexConfig = [pscustomobject]@{
    refreshSeconds = 300
    requestTimeoutSeconds = 15
    width = 156
    gap = 8
    xOffset = 0
    yOffset = 0
    notifyOnReset = $true
    rotateSeconds = 6
    autoRotate = $true
    appServerPath = ''
}
if (Test-Path -LiteralPath $codexConfigPath) {
    try {
        $codexLoadedConfig = Get-Content -Raw -LiteralPath $codexConfigPath | ConvertFrom-Json
        foreach ($codexProperty in $codexConfig.PSObject.Properties.Name) {
            if ($null -ne $codexLoadedConfig.$codexProperty) {
                $codexConfig.$codexProperty = $codexLoadedConfig.$codexProperty
            }
        }
    } catch {}
}
$codexConfig.refreshSeconds = [Math]::Max(30, [Math]::Min(3600, [int]$codexConfig.refreshSeconds))
$codexConfig.requestTimeoutSeconds = [Math]::Max(5, [Math]::Min(60, [int]$codexConfig.requestTimeoutSeconds))
$codexConfig.width = [Math]::Max(120, [Math]::Min(220, [int]$codexConfig.width))
$codexConfig.gap = [Math]::Max(0, [Math]::Min(40, [int]$codexConfig.gap))
$codexConfig.rotateSeconds = [Math]::Max(3, [Math]::Min(60, [int]$codexConfig.rotateSeconds))
Enable-CodexStartup
Write-CodexLog 'INFO' 'Widget starting. Quota source is online-only.'
$script:codexExitReason = 'unexpected-message-loop-exit'

function Get-CodexState {
    if (-not (Test-Path -LiteralPath $codexStatePath)) { return @{} }
    try {
        $codexRaw = Get-Content -Raw -LiteralPath $codexStatePath | ConvertFrom-Json
        $codexResult = @{}
        foreach ($codexProperty in $codexRaw.PSObject.Properties) {
            $codexResult[$codexProperty.Name] = $codexProperty.Value
        }
        return $codexResult
    } catch { return @{} }
}

function Save-CodexState {
    param([hashtable]$State)
    $codexJson = $State | ConvertTo-Json -Depth 6 -Compress
    [IO.File]::WriteAllText($codexStatePath, $codexJson, (New-Object Text.UTF8Encoding($false)))
}

function Show-CodexResetNotification {
    param([string]$WindowKey)
    if (-not [bool]$codexConfig.notifyOnReset) { return }
    $codexNotice = New-Object Windows.Forms.NotifyIcon
    $codexNotice.Icon = [Drawing.SystemIcons]::Information
    $codexNotice.Visible = $true
    $codexNotice.BalloonTipTitle = 'Codex Meter'
    $codexNotice.BalloonTipText = (CN '\u989d\u5ea6\u5df2\u6062\u590d\uff1a') + $WindowKey.Split(':')[0]
    $codexNotice.BalloonTipIcon = [Windows.Forms.ToolTipIcon]::Info
    $codexNotice.ShowBalloonTip(8000)
    Write-CodexLog 'INFO' ('Reset notification shown for ' + $WindowKey)
    # Keep notification objects alive until the UI timer disposes them.
    $script:codexNotices.Add([pscustomobject]@{ icon=$codexNotice; until=[DateTime]::UtcNow.AddSeconds(10) })

}

function Update-CodexResetState {
    param([object[]]$Windows)
    $codexState = Get-CodexState
    $codexNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($codexWindow in $Windows) {
        $codexPrevious = $codexState[$codexWindow.key]
        if ($null -ne $codexPrevious) {
            $codexOldReset = [long]$codexPrevious.resetUnix
            $codexOldNotified = [long]$codexPrevious.notifiedUnix
            $codexCycleAdvanced = [long]$codexWindow.resetUnix -gt ($codexOldReset + 60)
            $codexUsageDropped = [double]$codexWindow.usedPercent + 5 -le [double]$codexPrevious.usedPercent
            if ($codexOldReset -gt 0 -and $codexOldNotified -lt $codexOldReset -and
                ($codexCycleAdvanced -and ($codexNow -ge $codexOldReset -or $codexUsageDropped))) {
                Show-CodexResetNotification $codexWindow.key
                $codexOldNotified = $codexOldReset
            }
        } else {
            $codexOldNotified = 0
        }
        $codexState[$codexWindow.key] = [pscustomobject]@{
            resetUnix = [long]$codexWindow.resetUnix
            usedPercent = [double]$codexWindow.usedPercent
            notifiedUnix = [long]$codexOldNotified
        }
    }
    Save-CodexState $codexState
}

function Get-CodexTextColor {
    try {
        $codexTheme = Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name SystemUsesLightTheme
        if ([int]$codexTheme -eq 1) { return [Drawing.Color]::FromArgb(24, 24, 24) }
    } catch {}
    return [Drawing.Color]::White
}

$codexForm = New-Object CodexTaskbarWidgetForm
$codexForm.Text = 'Codex Meter Taskbar Widget'
$codexForm.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
$codexForm.ShowInTaskbar = $false
$codexForm.TopMost = $true
$codexForm.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
$codexForm.BackColor = [Drawing.Color]::FromArgb(245, 245, 245)
$codexForm.StartPosition = [Windows.Forms.FormStartPosition]::Manual
$codexForm.Width = [int]$codexConfig.width
$codexForm.Height = 44
$codexTimeoutText = ([string][char]0x8D85) + ([string][char]0x65F6)
$codexRefreshText = -join ([char[]]@(0x7ACB, 0x5373, 0x5237, 0x65B0))
$codexLogText = -join ([char[]]@(0x6253, 0x5F00, 0x9519, 0x8BEF, 0x65E5, 0x5FD7))
$codexExitText = -join ([char[]]@(0x9000, 0x51FA))

$codexMenu = New-Object Windows.Forms.ContextMenuStrip
$codexRefreshMenu = $codexMenu.Items.Add($codexRefreshText)
$codexLogMenu = $codexMenu.Items.Add($codexLogText)
[void]$codexMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$codexExitMenu = $codexMenu.Items.Add($codexExitText)
$codexRefreshMenu.Add_Click({ Update-CodexWidget })
$codexLogMenu.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $codexLogPath)) {
            [IO.File]::WriteAllText($codexLogPath, '', (New-Object Text.UTF8Encoding($true)))
        }
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $codexLogPath + '"')
    } catch {
        Write-CodexLog 'ERROR' ('Failed to open log: ' + $_.Exception.Message)
    }
})
$codexExitMenu.Add_Click({
    try {
        [IO.File]::WriteAllText($codexStopFlagPath, 'user-exit', (New-Object Text.UTF8Encoding($false)))
        $script:codexExitReason = 'user-menu'
        Write-CodexLog 'INFO' 'Exit requested from context menu.'
    } catch {}
    $codexForm.Close()
})
$codexForm.ContextMenuStrip = $codexMenu
$codexForm.RightClickMenu = $codexMenu

function Set-CodexWidgetPosition {
    $codexTaskbar = [CodexTaskbarNative]::FindWindow('Shell_TrayWnd', $null)
    if ($codexTaskbar -eq [IntPtr]::Zero) { return }
    $codexTaskbarRect = New-Object CodexTaskbarNative+RECT
    if (-not [CodexTaskbarNative]::GetWindowRect($codexTaskbar, [ref]$codexTaskbarRect)) { return }

    $codexTray = [CodexTaskbarNative]::FindWindowEx($codexTaskbar, [IntPtr]::Zero, 'TrayNotifyWnd', $null)
    $codexTrayRect = New-Object CodexTaskbarNative+RECT
    $codexHasTray = $codexTray -ne [IntPtr]::Zero -and [CodexTaskbarNative]::GetWindowRect($codexTray, [ref]$codexTrayRect)
    $codexTaskbarHeight = $codexTaskbarRect.Bottom - $codexTaskbarRect.Top
    $codexX = if ($codexHasTray) {
        $codexTrayRect.Left - $codexForm.Width - [int]$codexConfig.gap
    } else {
        $codexTaskbarRect.Right - 340 - $codexForm.Width
    }
    $codexY = $codexTaskbarRect.Top + [Math]::Max(0, [int](($codexTaskbarHeight - $codexForm.Height) / 2))
    $codexX += [int]$codexConfig.xOffset
    $codexY += [int]$codexConfig.yOffset
    $script:codexWidgetX = $codexX
    $script:codexWidgetY = $codexY
    [CodexTaskbarNative]::SetOwner($codexForm.Handle, $codexTaskbar)
    [void][CodexTaskbarNative]::SetWindowPos($codexForm.Handle, [CodexTaskbarNative]::TopMost,
        $codexX, $codexY, $codexForm.Width, $codexForm.Height,
        [CodexTaskbarNative]::NoActivate -bor [CodexTaskbarNative]::ShowWindow)
    $codexBackground = [CodexTaskbarNative]::SampleTaskbarBesideWindow($codexForm.Handle, $codexForm.BackColor)
    if ($codexForm.BackColor.ToArgb() -ne $codexBackground.ToArgb()) {
        $codexForm.BackColor = $codexBackground
        $codexForm.Invalidate()
    }
}


$script:codexNotices = New-Object Collections.Generic.List[object]
$script:codexSnapshot = $null
$script:codexFetch = $null
$script:codexFetchFailed = $false
$script:codexPage = 0
$script:codexRotationActive = $false
$script:codexNextPage = [DateTime]::UtcNow.AddSeconds($codexConfig.rotateSeconds)
$script:codexLastSuccess = $null
$codexTip = New-Object Windows.Forms.ToolTip
$codexTip.AutoPopDelay = 20000
function CN([string]$Text) { return [regex]::Unescape($Text) }

function Render-CodexWidget {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $pages = @()
    $details = @()
    if ($script:codexFetchFailed) {
        $pages += ,@($codexTimeoutText, (CN '\u8054\u7f51\u83b7\u53d6\u5931\u8d25'))
    } elseif ($null -eq $script:codexSnapshot) {
        $pages += ,@((CN '\u83b7\u53d6\u4e2d'), '--')
    } else {
        foreach ($window in @($script:codexSnapshot.windows | Sort-Object windowSeconds)) {
            $label = if ($window.windowSeconds -eq 18000) {'5h'} elseif ($window.windowSeconds -eq 604800) {'7d'} else { '{0}h' -f ($window.windowSeconds / 3600) }
            $top = '{0} {1}%' -f $label, [int][Math]::Round($window.remainingPercent)
            $bottom = Format-QuotaCountdown $window.resetUnix $now
            $pages += ,@($top, $bottom)
            $details += "$top $bottom"
        }
        $credits = $script:codexSnapshot.credits
        if ($null -eq $credits) {
            $pages += ,@((CN '\u91cd\u7f6e\u5361 --'), (CN '\u6682\u4e0d\u53ef\u7528'))
            $details += (CN '\u91cd\u7f6e\u5361\uff1a\u63a5\u53e3\u672a\u63d0\u4f9b')
        } else {
            $top = (CN '\u91cd\u7f6e\u5361 {0} \u6b21') -f $credits.availableCount
            $bottom = if ($credits.availableCount -eq 0) { CN '\u6682\u65e0\u53ef\u7528\u5361' } else { CN '\u5230\u671f\u65f6\u95f4\u672a\u63d0\u4f9b' }
            $details += $top
            foreach ($credit in $credits.credits) {
                if ($null -eq $credit.expiresAt) { $details += (CN '\u5230\u671f\u65f6\u95f4\u672a\u63d0\u4f9b'); continue }
                $date = [DateTimeOffset]::FromUnixTimeSeconds($credit.expiresAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
                $details += ((CN '\u5230\u671f\uff1a') + $date)
            }
            $first = @($credits.credits | Where-Object { $null -ne $_.expiresAt } | Select-Object -First 1)
            if ($first.Count -gt 0) {
                $bottom = if ($first[0].expiresAt -le $now) { CN '\u5df2\u5230\u671f\uff0c\u8bf7\u5237\u65b0' } else { (CN '\u5230\u671f ') + (Format-QuotaCountdown $first[0].expiresAt $now) }
            }
            if ($credits.incomplete) { $details += (CN '\u660e\u7ec6\u4e0d\u5b8c\u6574\uff0c\u6b21\u6570\u4ee5\u670d\u52a1\u7aef\u4e3a\u51c6') }
            $pages += ,@($top, $bottom)
        }
    }
    $script:codexPageCount = $pages.Count
    $script:codexPage = (($script:codexPage % $pages.Count) + $pages.Count) % $pages.Count
    $selected = $pages[$script:codexPage]
    if ($codexForm.TopLine -ne $selected[0] -or $codexForm.BottomLine -ne $selected[1]) {
        $codexForm.TopLine = $selected[0]; $codexForm.BottomLine = $selected[1]; $codexForm.Invalidate()
    }
    if ($null -ne $script:codexLastSuccess) { $details += ((CN '\u4e0a\u6b21\u6210\u529f\uff1a') + $script:codexLastSuccess.ToString('MM-dd HH:mm:ss')) }
    $codexTip.SetToolTip($codexForm, ($details -join [Environment]::NewLine))
    $script:codexDetailLines = $details
}

function Update-CodexWidget {
    if ($null -ne $script:codexFetch) { return }
    $exe = [string]$codexConfig.appServerPath
    if ([string]::IsNullOrWhiteSpace($exe)) {
        $command = Get-Command codex.exe -ErrorAction SilentlyContinue
        if ($null -ne $command) { $exe = $command.Source }
    }
    $worker = [PowerShell]::Create()
    [void]$worker.AddScript({
        param($model, $executable, $timeout)
        . $model
        if ([string]::IsNullOrWhiteSpace($executable)) { throw 'App Server executable unavailable.' }
        Get-AppQuota $executable $timeout
    }).AddArgument((Join-Path $PSScriptRoot 'quota-model.ps1')).AddArgument($exe).AddArgument([int]$codexConfig.requestTimeoutSeconds)
    $script:codexFetch = [pscustomobject]@{worker=$worker;handle=$worker.BeginInvoke()}
}

function Complete-CodexFetch {
    if ($null -eq $script:codexFetch -or -not $script:codexFetch.handle.IsCompleted) { return }
    $fetch = $script:codexFetch
    try {
        $result = @($fetch.worker.EndInvoke($fetch.handle))
        if ($fetch.worker.HadErrors -or $result.Count -eq 0) {
            $errorType = if ($fetch.worker.Streams.Error.Count -gt 0) { $fetch.worker.Streams.Error[0].Exception.GetType().FullName } else { 'EmptyResponse' }
            throw ('Online query failed. Type=' + $errorType)
        }
        $script:codexSnapshot = $result[-1]
        $script:codexFetchFailed = $false
        $script:codexLastSuccess = Get-Date
        $script:codexPage = 0
        Render-CodexWidget
        $script:codexRotationActive = [bool]$codexConfig.autoRotate -and $script:codexPageCount -gt 1
        if ($script:codexRotationActive) { $script:codexPage = 1 }
        Write-CodexLog 'INFO' ('Refresh display started. Page=' + $script:codexPage + ' IntervalSeconds=' + $codexConfig.refreshSeconds)
        $script:codexNextPage = [DateTime]::UtcNow.AddSeconds($codexConfig.rotateSeconds)
        $count = if ($null -eq $script:codexSnapshot.credits) {'unknown'} else {$script:codexSnapshot.credits.availableCount}
        Write-CodexLog 'INFO' ("Quota fetched. Source=" + $script:codexSnapshot.source + " Windows=" + $script:codexSnapshot.windows.Count + " ResetCredits=" + $count)
        if ($script:codexSnapshot.warning) { Write-CodexLog 'WARN' $script:codexSnapshot.warning }
        try { Update-CodexResetState $script:codexSnapshot.windows } catch { Write-CodexLog 'ERROR' ('Notification/state update failed: ' + $_.Exception.Message) }
    } catch {
        $script:codexSnapshot = $null
        $script:codexFetchFailed = $true
        $script:codexRotationActive = $false
        $script:codexPage = 0
        Write-CodexLog 'ERROR' $_.Exception.Message
    } finally {
        $fetch.worker.Dispose()
        $script:codexFetch = $null
    }
    Render-CodexWidget
}

$codexLayoutTimer = New-Object Windows.Forms.Timer
$codexLayoutTimer.Interval = 1000
$codexLayoutTimer.Add_Tick({
    Complete-CodexFetch
    for ($i = $script:codexNotices.Count - 1; $i -ge 0; $i--) {
        if ([DateTime]::UtcNow -ge $script:codexNotices[$i].until) {
            $script:codexNotices[$i].icon.Dispose(); $script:codexNotices.RemoveAt($i)
        }
    }
    $hover = $codexForm.Bounds.Contains([Windows.Forms.Cursor]::Position)
    if ($script:codexRotationActive -and -not $hover -and -not $codexMenu.Visible -and [DateTime]::UtcNow -ge $script:codexNextPage) {
        $step = Get-NextQuotaPage $script:codexPage $script:codexPageCount
        $script:codexPage = $step.page
        $script:codexRotationActive = $step.active
        if (-not $step.active) { Write-CodexLog 'INFO' 'Refresh display finished. Primary quota stays visible.' }
        $script:codexNextPage = [DateTime]::UtcNow.AddSeconds($codexConfig.rotateSeconds)
    }
    Render-CodexWidget
    $codexColor = Get-CodexTextColor
    $codexForm.DisplayColor = $codexColor
    $codexForm.Invalidate()
    Set-CodexWidgetPosition
})

$codexDetailMenu = New-Object Windows.Forms.ToolStripMenuItem
$codexDetailMenu.Text = CN '\u989d\u5ea6\u548c\u91cd\u7f6e\u5361\u660e\u7ec6'
$codexMenu.Items.Insert(1, $codexDetailMenu)
$codexRotateMenu = New-Object Windows.Forms.ToolStripMenuItem
$codexRotateMenu.Text = CN '\u5237\u65b0\u540e\u8f6e\u64ad'
$codexRotateMenu.Checked = [bool]$codexConfig.autoRotate
$codexRotateMenu.CheckOnClick = $true
$codexRotateMenu.Add_Click({
    $codexConfig.autoRotate = $codexRotateMenu.Checked
    if (-not $codexConfig.autoRotate) { $script:codexPage = 0; $script:codexRotationActive = $false; Render-CodexWidget }
    try { [IO.File]::WriteAllText($codexConfigPath, ($codexConfig | ConvertTo-Json), [Text.Encoding]::UTF8) } catch { Write-CodexLog 'ERROR' 'Unable to save rotation preference.' }
})
$codexMenu.Items.Insert(2, $codexRotateMenu)
$codexMenu.Add_Opening({
    $codexDetailMenu.DropDownItems.Clear()
    foreach ($line in $script:codexDetailLines) { [void]$codexDetailMenu.DropDownItems.Add([string]$line) }
})
$codexForm.Add_MouseWheel({
    param($sender,$eventArgs)
    $script:codexPage += $(if ($eventArgs.Delta -gt 0) {-1} else {1})
    $script:codexRotationActive = $true
    $script:codexNextPage = [DateTime]::UtcNow.AddSeconds($codexConfig.rotateSeconds)
    Render-CodexWidget
})
$codexForm.Add_MouseClick({
    param($sender,$eventArgs)
    if ($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left) {
        $script:codexPage++
        $script:codexRotationActive = $true
        $script:codexNextPage = [DateTime]::UtcNow.AddSeconds($codexConfig.rotateSeconds)
        Render-CodexWidget
    }
})

$codexQuotaTimer = New-Object Windows.Forms.Timer
$codexQuotaTimer.Interval = [int]$codexConfig.refreshSeconds * 1000
$codexQuotaTimer.Add_Tick({ Update-CodexWidget })

$codexForm.Add_Shown({
    Set-CodexWidgetPosition
    Write-CodexLog 'INFO' 'Taskbar ownership and native right-click menu enabled.'
    Update-CodexWidget
    $codexLayoutTimer.Start()
    $codexQuotaTimer.Start()
})
$codexForm.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:codexExitReason -eq 'unexpected-message-loop-exit') {
        $script:codexExitReason = 'form-closing:' + [string]$eventArgs.CloseReason
    }
    Write-CodexLog 'INFO' ('Form closing. Reason=' + [string]$eventArgs.CloseReason + ' ExitReason=' + $script:codexExitReason)
})
$codexForm.Add_FormClosed({
    $codexLayoutTimer.Stop()
    $codexQuotaTimer.Stop()
    foreach ($notice in $script:codexNotices) { $notice.icon.Dispose() }
    $codexTip.Dispose()
    Remove-Item -LiteralPath $codexPidPath -Force -ErrorAction SilentlyContinue
    Write-CodexLog 'INFO' ('Widget stopped. ExitReason=' + $script:codexExitReason)
})

try {
    [Windows.Forms.Application]::add_ThreadException({
        param($sender, $eventArgs)
        $script:codexExitReason = 'ui-thread-exception'
        Write-CodexLog 'FATAL' ('Unhandled UI exception: ' + $eventArgs.Exception.ToString())
    })
    [Windows.Forms.Application]::Run($codexForm)
} catch {
    $script:codexExitReason = 'fatal-script-exception'
    Write-CodexLog 'FATAL' ('Fatal widget exception: ' + $_.Exception.ToString())
    throw
} finally {
    Remove-Item -LiteralPath $codexPidPath -Force -ErrorAction SilentlyContinue
    $codexMutex.ReleaseMutex()
    $codexMutex.Dispose()
}

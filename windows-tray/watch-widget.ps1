$ErrorActionPreference = 'Stop'

$codexRoot = Join-Path $env:LOCALAPPDATA 'CodexMeter'
$codexLogRoot = Join-Path $codexRoot 'logs'
$codexLogPath = Join-Path $codexLogRoot 'taskbar-widget.log'
$codexWatchdogPidPath = Join-Path $codexRoot 'watchdog.pid'
$codexStopFlagPath = Join-Path $codexRoot 'stop.flag'
$codexWorkerPath = Join-Path $PSScriptRoot 'taskbar-widget.ps1'
New-Item -ItemType Directory -Force -Path $codexLogRoot | Out-Null

function Write-CodexWatchdogLog {
    param([string]$Level, [string]$Message)
    try {
        $codexSafeMessage = ([string]$Message).Replace("`r", ' ').Replace("`n", ' ')
        $codexLine = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [' + $Level + '] [watchdog] ' + $codexSafeMessage + [Environment]::NewLine
        [IO.File]::AppendAllText($codexLogPath, $codexLine, (New-Object Text.UTF8Encoding($true)))
    } catch {}
}

$codexMutexCreated = $false
$codexMutex = [Threading.Mutex]::new($true, 'Local\Wangnov-CodexMeter-TaskbarWatchdog', [ref]$codexMutexCreated)
if (-not $codexMutexCreated) {
    $codexMutex.Dispose()
    exit 0
}

try {
    Remove-Item -LiteralPath $codexStopFlagPath -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($codexWatchdogPidPath, [Diagnostics.Process]::GetCurrentProcess().Id.ToString(), (New-Object Text.UTF8Encoding($false)))
    Write-CodexWatchdogLog 'INFO' 'Watchdog started.'
    while (-not (Test-Path -LiteralPath $codexStopFlagPath)) {
        $codexArguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $codexWorkerPath + '"'
        $codexWorker = Start-Process -FilePath 'powershell.exe' -ArgumentList $codexArguments -WindowStyle Hidden -PassThru
        Write-CodexWatchdogLog 'INFO' ('Widget process started. PID=' + $codexWorker.Id)
        $codexWorker.WaitForExit()
        $codexExitCode = $codexWorker.ExitCode
        $codexWorker.Dispose()
        if (Test-Path -LiteralPath $codexStopFlagPath) { break }
        Write-CodexWatchdogLog 'ERROR' ('Widget exited unexpectedly. ExitCode=' + $codexExitCode + '. Restarting in 3 seconds.')
        Start-Sleep -Seconds 3
    }
    Write-CodexWatchdogLog 'INFO' 'Stop flag detected. Watchdog stopped.'
} catch {
    Write-CodexWatchdogLog 'FATAL' ('Watchdog failed: ' + $_.Exception.ToString())
    throw
} finally {
    Remove-Item -LiteralPath $codexWatchdogPidPath -Force -ErrorAction SilentlyContinue
    $codexMutex.ReleaseMutex()
    $codexMutex.Dispose()
}

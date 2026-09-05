# Pure parsing/formatting helpers; safe to dot-source in tests and background runspaces.
function Get-NextQuotaPage([int]$Page, [int]$Count) {
    if ($Page -le 0 -or $Page + 1 -ge $Count) { return [pscustomobject]@{page=0;active=$false} }
    return [pscustomobject]@{page=($Page+1);active=$true}
}

function ConvertTo-ResetCredits($Value) {
    if ($null -eq $Value -or $null -eq $Value.availableCount -or
        $Value.availableCount -is [bool] -or $Value.availableCount -is [string]) { return $null }
    $count = [double]$Value.availableCount
    if ([double]::IsNaN($count) -or [double]::IsInfinity($count) -or $count -lt 0 -or $count -gt [int]::MaxValue -or $count -ne [Math]::Floor($count)) { return $null }
    $dates = @()
    foreach ($row in @($Value.credits | Select-Object -First 100)) {
        if ($null -eq $row -or $row.status -ne 'available') { continue }
        $expiry = $null
        if ($null -ne $row.expiresAt) {
            $number = 0.0
            if (-not [double]::TryParse([string]$row.expiresAt, [ref]$number) -or [double]::IsNaN($number) -or $number -lt 0 -or $number -gt 253402300799) { continue }
            $expiry = [long]$number
        }
        $dates += [pscustomobject]@{ expiresAt = $expiry }
    }
    return [pscustomobject]@{ availableCount = [int]$count; credits = @($dates | Sort-Object @{Expression={if ($null -eq $_.expiresAt) {[long]::MaxValue} else {$_.expiresAt}}} | Select-Object -First ([int]$count)); incomplete = ($dates.Count -ne $count) }
}

function Format-QuotaCountdown([long]$Reset, [long]$Now) {
    $seconds = [Math]::Max(0, $Reset - $Now)
    $hours = [long][Math]::Floor($seconds / 3600)
    if ($hours -ge 24) { return '{0}d{1:00}h' -f [long][Math]::Floor($hours / 24), ($hours % 24) }
    return '{0}h{1:00}m' -f $hours, [long][Math]::Floor(($seconds % 3600) / 60)
}

function ConvertFrom-AppQuota($Payload) {
    $limits = $Payload.rateLimits
    if ($null -ne $Payload.rateLimitsByLimitId) { $limits = $Payload.rateLimitsByLimitId.codex }
    if ($null -eq $limits) { throw 'Aggregate Codex quota unavailable.' }
    $windows = @()
    foreach ($name in @('primary','secondary')) {
        $w = $limits.$name
        if ($null -eq $w -or $null -eq $w.usedPercent -or $w.windowDurationMins -le 0 -or $w.resetsAt -le 0) { continue }
        $used = [double]$w.usedPercent
        if ([double]::IsNaN($used) -or [double]::IsInfinity($used) -or $used -lt 0 -or $used -gt 100) { continue }
        $seconds = [long]$w.windowDurationMins * 60
        $windows += [pscustomobject]@{key=($name + ':' + $seconds);usedPercent=$used;remainingPercent=(100-$used);resetUnix=[long]$w.resetsAt;windowSeconds=$seconds}
    }
    if ($windows.Count -eq 0) { throw 'No valid quota windows.' }
    return [pscustomobject]@{ windows=$windows; credits=(ConvertTo-ResetCredits $Payload.rateLimitResetCredits); source='App Server'; warning=$null }
}

function Get-AppQuota([string]$Executable, [int]$TimeoutSeconds) {
    $started = $false
    $process = New-Object Diagnostics.Process
    $process.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $Executable
    $process.StartInfo.Arguments = 'app-server'
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        [void]$process.Start()
        $started = $true
        # Drain stderr to avoid pipe deadlock; never log raw server output.
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine('{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex_meter_windows","version":"2"},"capabilities":{}}}')
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $read = $process.StandardOutput.ReadLineAsync()
            $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $read.Wait($remaining)) { throw 'App Server timeout.' }
            if ($null -eq $read.Result) { throw 'App Server exited before response.' }
            $message = $read.Result | ConvertFrom-Json
            if ($message.id -eq 1) {
                if ($null -ne $message.error) { throw ('App Server initialization error code=' + $message.error.code) }
                $process.StandardInput.WriteLine('{"method":"initialized","params":{}}')
                $process.StandardInput.WriteLine('{"id":2,"method":"account/rateLimits/read"}')
            } elseif ($message.id -eq 2) {
                if ($null -ne $message.error) { throw ('App Server quota error code=' + $message.error.code) }
                return ConvertFrom-AppQuota $message.result
            }
        }
        throw 'App Server timeout.'
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
        $process.Dispose()
    }
}

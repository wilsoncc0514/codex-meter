param([switch]$Live)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'quota-model.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$step = Get-NextQuotaPage 1 3
Assert ($step.page -eq 2 -and $step.active) 'Weekly advances to credits'
$step = Get-NextQuotaPage $step.page 3
Assert ($step.page -eq 0 -and -not $step.active) 'Credits return to permanent primary'
$step = Get-NextQuotaPage 0 3
Assert ($step.page -eq 0 -and -not $step.active) 'Primary stays idle'
$step = Get-NextQuotaPage 1 2
Assert ($step.page -eq 0 -and -not $step.active) 'Missing window finishes one-shot rotation'
Assert ($null -eq (ConvertTo-ResetCredits $null)) 'Missing credits must be unknown'
Assert ($null -eq (ConvertTo-ResetCredits ([pscustomobject]@{availableCount=-1}))) 'Negative credits'
$zero = ConvertTo-ResetCredits ([pscustomobject]@{availableCount=0;credits=@()})
Assert ($null -ne $zero -and $zero.availableCount -eq 0) 'Zero is known'
$two = ConvertTo-ResetCredits ([pscustomobject]@{availableCount=2;credits=@([pscustomobject]@{status='available';expiresAt=2000000000})})
Assert ($two.availableCount -eq 2 -and $two.incomplete) 'Count must not be inferred from detail rows'
Assert ((Format-QuotaCountdown 90061 0) -eq '1d01h') 'Day countdown'
Assert ((Format-QuotaCountdown 3599 0) -eq '0h59m') 'Minute countdown'
Assert ((Format-QuotaCountdown 10 20) -eq '0h00m') 'Expired countdown'
$payload = '{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":2000000000}}},"rateLimitResetCredits":{"availableCount":2}}' | ConvertFrom-Json
$snapshot = ConvertFrom-AppQuota $payload
Assert ($snapshot.windows.Count -eq 1 -and $snapshot.windows[0].remainingPercent -eq 75) 'Quota conversion'
Assert ($snapshot.credits.availableCount -eq 2) 'Credit propagation'
foreach ($file in Get-ChildItem $PSScriptRoot -Filter '*.ps1') {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) ('Syntax: ' + $file.Name + ' ' + $errors)
}
# Exercise the real renderer with non-UI doubles, including unknown/zero/error pages.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'taskbar-widget.ps1'),[ref]$tokens,[ref]$errors)
foreach ($name in @('CN','Render-CodexWidget')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    Invoke-Expression $definition.Extent.Text
}
$codexForm=[pscustomobject]@{TopLine='';BottomLine=''}
$codexForm | Add-Member ScriptMethod Invalidate {}
$codexTip=New-Object PSObject
$codexTip | Add-Member ScriptMethod SetToolTip {param($form,$text)}
$codexTimeoutText='TIMEOUT'
$script:codexSnapshot=$snapshot; $script:codexPage=0; $script:codexFetchFailed=$false; $script:codexLastSuccess=$null
Render-CodexWidget
Assert ($codexForm.TopLine -eq '5h 75%') 'Quota page'
$script:codexPage=1
Render-CodexWidget
Assert ($codexForm.TopLine -match '2') 'Credit page'
$script:codexSnapshot.credits=$zero
Render-CodexWidget
Assert ($codexForm.TopLine -match '0') 'Zero credit page'
$script:codexSnapshot.credits=$null
Render-CodexWidget
Assert ($codexForm.TopLine -match '--') 'Unknown credit page'
$script:codexFetchFailed=$true
Render-CodexWidget
Assert ($codexForm.TopLine -eq 'TIMEOUT' -and $script:codexPageCount -eq 1) 'Failure must hide stale credits'
'Offline assertions passed.'
if ($Live) {
    $snapshot = Get-AppQuota (Get-Command codex.exe).Source 20
    [pscustomobject]@{source=$snapshot.source; windows=$snapshot.windows.Count; resetCount=$snapshot.credits.availableCount; detailCount=@($snapshot.credits.credits).Count} | ConvertTo-Json
}

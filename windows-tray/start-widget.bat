@echo off
powershell.exe -NoProfile -WindowStyle Hidden -Command "Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'CodexMeter\stop.flag') -Force -ErrorAction SilentlyContinue"
start "Codex Meter" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0watch-widget.ps1"
exit /b 0

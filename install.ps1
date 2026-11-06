# Install: registers the on-demand scheduled task 'XiaokePet' (starts the pet outside Claude, so it survives
# app restarts) and writes hooks-snippet.json with this folder's paths filled in, to merge into
# ~/.claude/settings.json under "hooks". Nothing starts at logon; the task only runs when a hook calls it.
#   powershell -ExecutionPolicy Bypass -File install.ps1
param([string]$TaskName = 'XiaokePet')
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pet = Join-Path $dir 'pet.ps1'
$launch = (Join-Path $dir 'launch.ps1') -replace '\\', '/'

$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $pet + '"')
$set = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$pr = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $act -Settings $set -Principal $pr -Force | Out-Null
Write-Host "Scheduled task '$TaskName' registered."

function Hook([string]$ev) {
  @{ type = 'command'; async = $true; timeout = 20; command = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $launch + '" ' + $ev) }
}
$hooks = [ordered]@{
  UserPromptSubmit = @(@{ hooks = @(Hook 'work') })
  Stop             = @(@{ hooks = @(Hook 'done') })
  Notification     = @(@{ matcher = 'permission_prompt|elicitation_dialog'; hooks = @(Hook 'need') })
  SessionEnd       = @(@{ hooks = @(Hook 'end') })
}
$out = Join-Path $dir 'hooks-snippet.json'
$utf8 = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText($out, (@{ hooks = $hooks } | ConvertTo-Json -Depth 6), $utf8)
Write-Host "Wrote $out"
Write-Host 'Merge its "hooks" into ~/.claude/settings.json (or ask Claude Code to do it), then restart Claude.'

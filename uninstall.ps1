# Uninstall: closes the pet and removes the scheduled task. Remove the four hooks that call launch.ps1
# from ~/.claude/settings.json yourself.
param([string]$TaskName = 'XiaokePet')
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like ('*' + (Join-Path $dir 'pet.ps1') + '*') } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Pet closed, task '$TaskName' removed. Now delete the launch.ps1 hooks from ~/.claude/settings.json."

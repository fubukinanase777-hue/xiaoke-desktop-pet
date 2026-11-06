# Hook entry. Usage: launch.ps1 work|done|need|end   (hook JSON on stdin)
# Records the session state + an event file, makes sure the pet is running, returns at once.
param([string]$Event = 'done')
$ErrorActionPreference = 'SilentlyContinue'
[Console]::InputEncoding = [Text.Encoding]::UTF8
$raw = ''
try { $raw = [Console]::In.ReadToEnd() } catch {}
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sessDir = Join-Path $dir 'state\sessions'
$evDir = Join-Path $dir 'state\events'
New-Item -ItemType Directory -Force -Path $sessDir, $evDir | Out-Null
$utf8 = New-Object Text.UTF8Encoding $false
Add-Content -LiteralPath (Join-Path $dir 'fired.log') -Value ((Get-Date -Format 's') + ' ' + $Event)

$info = $null
try { $info = $raw | ConvertFrom-Json } catch {}
$sid = 'unknown'
if ($info -and $info.session_id) { $sid = [string]$info.session_id }
$sf = Join-Path $sessDir ($sid + '.json')

# A turn that ends while background work it started is still running (Bash run_in_background,
# async subagents) is a progress report, not the finish: Claude will be woken again when it completes.
# launched ids: toolUseResult.backgroundTaskId (Bash) / status async_launched + agentId (subagents);
# finished ids: <task-id>x</task-id> in task notifications. Launches older than bgMaxMinutes are ignored.
function PendingBackground([string]$path, [double]$maxMin) {
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return 0 }
  $launched = @{}; $finished = @{}
  $cut = [DateTime]::UtcNow.AddMinutes(-$maxMin)
  foreach ($ln in [IO.File]::ReadLines($path)) {
    if ($ln.Contains('<task-id>')) {
      foreach ($mm in [regex]::Matches($ln, '<task-id>(\w+)</task-id>')) { $finished[$mm.Groups[1].Value] = 1 }
    }
    # tasks killed with TaskStop never send a <task-id> notification (2026-11-06: three stopped tasks
    # kept the pet "busy" for up to bgMaxMinutes); the structured TaskStop result marks them finished
    if ($ln.Contains('"toolUseResult":{"message":"Successfully stopped task: ')) {
      foreach ($mm in [regex]::Matches($ln, '"toolUseResult":\{"message":"Successfully stopped task: (\w+)')) { $finished[$mm.Groups[1].Value] = 1 }
    }
    if (-not $ln.Contains('"type":"user"')) { continue }
    # structured fields of the tool result only (unescaped quotes), so ids quoted inside some
    # command's output (e.g. grepping another transcript) are never taken for real launches
    $isBash = $ln.Contains('"backgroundTaskId":"')
    $isAgent = $ln.Contains('"status":"async_launched"')
    if (-not ($isBash -or $isAgent)) { continue }
    $ts = [regex]::Match($ln, '"timestamp":"([^"]+)"')
    if ($ts.Success) {
      try { if ([DateTime]::Parse($ts.Groups[1].Value).ToUniversalTime() -lt $cut) { continue } } catch {}
    }
    if ($isBash) { foreach ($mm in [regex]::Matches($ln, '"backgroundTaskId":"(\w+)"')) { $launched[$mm.Groups[1].Value] = 1 } }
    if ($isAgent) { foreach ($mm in [regex]::Matches($ln, '"agentId":"(\w+)"')) { $launched[$mm.Groups[1].Value] = 1 } }
  }
  return @($launched.Keys | Where-Object { -not $finished.ContainsKey($_) }).Count
}
if ($Event -eq 'done' -and $info -and $info.transcript_path) {
  $maxMin = 120
  try { $c = Get-Content (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json; if ($c.bgMaxMinutes) { $maxMin = [double]$c.bgMaxMinutes } } catch {}
  $n = PendingBackground ([string]$info.transcript_path) $maxMin
  if ($n -gt 0) { $Event = 'progress' }
  Add-Content -LiteralPath (Join-Path $dir 'fired.log') -Value ('  pending background: ' + $n + '  (session ' + $sid.Substring(0, [Math]::Min(8, $sid.Length)) + ')')
}

if ($Event -eq 'end') {
  Remove-Item -LiteralPath $sf -Force
} else {
  $state = $Event; if ($Event -eq 'progress') { $state = 'work' }  # still working
  $st = @{ state = $state; t = [DateTime]::UtcNow.Ticks; cwd = '' }
  # desktop app's own session id (local_...) -> lets the pet open exactly this conversation
  if ($env:CLAUDE_CODE_HOST_SESSION_ID) { $st.host = [string]$env:CLAUDE_CODE_HOST_SESSION_ID }
  if ($info -and $info.cwd) { $st.cwd = [string]$info.cwd }
  [IO.File]::WriteAllText($sf, ($st | ConvertTo-Json -Compress), $utf8)
  $ef = Join-Path $evDir ('{0}_{1}_{2}.json' -f [DateTime]::UtcNow.Ticks, $Event, ([guid]::NewGuid().ToString('N').Substring(0, 6)))
  [IO.File]::WriteAllText($ef, $raw, $utf8)
}

$m = $null
if (-not [Threading.Mutex]::TryOpenExisting('Local\XiaokePet', [ref]$m)) {
  # Started through the on-demand scheduled task 'XiaokePet' so the pet is not a child of the Claude app:
  # hooks run inside the app's job object, and anything started from there dies when the app restarts
  # or updates (2026-11-06). (WMI Win32_Process.Create was tried first: security software blocks
  # powershell started that way.) Falls back to a plain child process if the task is missing.
  $ok = $false
  & schtasks.exe /run /tn 'XiaokePet' *> $null
  if ($LASTEXITCODE -eq 0) { $ok = $true }
  if (-not $ok) {
    $a = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $dir 'pet.ps1') + '"'))
    Start-Process -FilePath 'powershell.exe' -ArgumentList $a -WindowStyle Hidden
  }
  Add-Content -LiteralPath (Join-Path $dir 'fired.log') -Value ('  pet started (' + $(if ($ok) { 'task' } else { 'start-process' }) + ')')
} else { $m.Dispose() }

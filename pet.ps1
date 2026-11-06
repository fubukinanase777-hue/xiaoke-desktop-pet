# Xiaoke desktop pet. One instance (mutex Local\XiaokePet). Reads state\sessions + state\events written by launch.ps1.
# Modes (priority): need > wait (done, not seen yet) > work > idle (> doze after dozeMinutes idle).  cheer / poke* = one-shots.
# All user-facing text lives in config.json (this file stays ASCII for Windows PowerShell 5.1).
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$created = $false
$mtx = New-Object System.Threading.Mutex($true, 'Local\XiaokePet', [ref]$created)
if (-not $created) { exit }

Add-Type -Namespace XiaokeW -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
'@

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sessDir = Join-Path $dir 'state\sessions'
$evDir = Join-Path $dir 'state\events'
$posFile = Join-Path $dir 'state\pos.json'
New-Item -ItemType Directory -Force -Path $sessDir, $evDir | Out-Null
$utf8 = New-Object Text.UTF8Encoding $false
function LoadCfg { Get-Content (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
$script:cfg = LoadCfg

# ---- frames ----
$script:img = @{}
Get-ChildItem (Join-Path $dir 'art\frames') -Filter '*.png' | Where-Object { $_.BaseName -match '^(work|idle|cheer|need|wait|poke|doze|wake)\d+$' } | ForEach-Object {
  $bi = New-Object Windows.Media.Imaging.BitmapImage
  $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.UriSource = [uri]$_.FullName; $bi.EndInit(); $bi.Freeze()
  $script:img[$_.BaseName] = $bi
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        Width="400" Height="330">
  <Grid>
    <Image x:Name="Pet" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,4,0"
           RenderOptions.BitmapScalingMode="HighQuality" Cursor="Hand">
      <Image.RenderTransformOrigin>0.5,1</Image.RenderTransformOrigin>
      <Image.RenderTransform>
        <TransformGroup><ScaleTransform x:Name="Squash"/><TranslateTransform x:Name="Hop"/></TransformGroup>
      </Image.RenderTransform>
    </Image>
    <Border x:Name="Bubble" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,120,150"
            CornerRadius="14" Background="#FAFFFDF8" BorderBrush="#E0A070" BorderThickness="1.4"
            Padding="14,9,16,10" MaxWidth="250" Visibility="Collapsed" Opacity="0" Cursor="Hand">
      <Border.Effect><DropShadowEffect BlurRadius="12" ShadowDepth="2" Opacity="0.28" Color="#5A3A20"/></Border.Effect>
      <StackPanel>
        <TextBlock x:Name="Say" FontFamily="Microsoft YaHei UI" FontSize="15" FontWeight="SemiBold" Foreground="#5A3420" TextWrapping="Wrap"/>
        <TextBlock x:Name="Sub" FontFamily="Microsoft YaHei UI" FontSize="11.5" Foreground="#9A7A62" TextWrapping="Wrap" Margin="0,4,0,0"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Parse($xaml)
$pet = $win.FindName('Pet'); $bubble = $win.FindName('Bubble'); $say = $win.FindName('Say'); $sub = $win.FindName('Sub')
$hop = $win.FindName('Hop'); $squash = $win.FindName('Squash')
$pet.Height = [double]$script:cfg.height

# ---- position (remembered) ----
$wa = [Windows.SystemParameters]::WorkArea
$win.Left = $wa.Right - $win.Width - 6
$win.Top = $wa.Bottom - $win.Height - 46
if (Test-Path -LiteralPath $posFile) {
  try {
    $p = Get-Content -LiteralPath $posFile -Raw | ConvertFrom-Json
    $vl = [Windows.SystemParameters]::VirtualScreenLeft; $vt = [Windows.SystemParameters]::VirtualScreenTop
    $vw = [Windows.SystemParameters]::VirtualScreenWidth; $vh = [Windows.SystemParameters]::VirtualScreenHeight
    if ($p.left -gt $vl - 300 -and $p.left -lt $vl + $vw - 100 -and $p.top -gt $vt - 200 -and $p.top -lt $vt + $vh - 100) {
      $win.Left = [double]$p.left; $win.Top = [double]$p.top
    }
  } catch {}
}

# ---- animation ----
$script:mode = ''
$script:seq = @(); $script:si = 0; $script:idleCount = 0
$anim = New-Object Windows.Threading.DispatcherTimer
function ShowFrame($n) { if ($script:img.ContainsKey($n)) { $pet.Source = $script:img[$n] } }
function SetMode([string]$m, [bool]$force = $false) {
  if ($m -eq $script:mode -and -not $force) { return }
  $script:mode = $m
  $a = $script:cfg.anim.$m
  $fps = 2; if ($a -and $a.fps) { $fps = [double]$a.fps }
  $anim.Interval = [TimeSpan]::FromMilliseconds(1000.0 / $fps)
  $script:si = 0
  if ($m -eq 'idle') { $script:seq = @('idle1') }
  elseif ($a.seqs) { $all = @($a.seqs); $script:seq = @($all[(Get-Random -Maximum $all.Count)]) }  # several variants: pick one (Get-Random on a pipeline would flatten them)
  else { $script:seq = @($a.seq) }
  ShowFrame $script:seq[0]
}
# cheer and the poke reactions play once, then fall back to whatever the state is
function OneShot { return ($script:mode -eq 'cheer' -or $script:mode -like 'poke*') }
function NextIdleFrame {
  # mostly reading, blink now and then, rarely stretch or yawn
  # cfg.anim.idle.extras = [{seq, chance}]: after `extrasAfter` quiet ticks, each tick rolls once over all extras
  $script:idleCount++
  $a = $script:cfg.anim.idle
  $after = 30; if ($a -and $null -ne $a.extrasAfter) { $after = [int]$a.extrasAfter }
  $ex = @(); if ($a -and $a.extras) { $ex = @($a.extras) }
  if ($ex.Count -eq 0) {  # old built-in set: stretch, yawn
    $ex = @(@{ seq = @('idle3', 'idle3', 'idle3', 'idle1'); chance = 8 }, @{ seq = @('idle4', 'idle4', 'idle4', 'idle1'); chance = 6 })
  }
  if ($script:idleCount -gt $after) {
    $r = Get-Random -Maximum 100; $acc = 0
    foreach ($e in $ex) {
      $acc += [int]$e.chance
      if ($r -lt $acc) { $script:idleCount = 0; return @($e.seq | Where-Object { $script:img.ContainsKey($_) }) + @('idle1') }
    }
  }
  if ((Get-Random -Maximum 100) -lt 10) { return @('idle2', 'idle1') }
  return @('idle1')
}
$anim.Add_Tick({
  $script:si++
  if ($script:si -ge $script:seq.Count) {
    if (OneShot) { SetMode (Resolve) $true; return }
    if ($script:mode -eq 'idle') { $script:seq = NextIdleFrame }
    elseif ($script:mode -eq 'doze') { $script:seq = NextDozeFrame }
    else { $script:seq = NextLoop $script:mode }
    $script:si = 0
  }
  ShowFrame $script:seq[$script:si]
})

function NextLoop([string]$m) {
  # looping modes (work, wait, need): when one pass ends, now and then play one of cfg.anim.<m>.extras
  # ([{seq, chance}], chance in % per pass), otherwise the base loop again
  $a = $script:cfg.anim.$m
  if ($a -and $a.extras) {
    $r = Get-Random -Maximum 100; $acc = 0
    foreach ($e in @($a.extras)) {
      $acc += [int]$e.chance
      if ($r -lt $acc) { $s = @($e.seq | Where-Object { $script:img.ContainsKey($_) }); if ($s.Count) { return $s } }
    }
  }
  if ($a.seq) { return @($a.seq) }
  return $script:seq
}
function NextDozeFrame {
  # asleep: breathing loop; now and then a silent sleep-talk bubble
  $a = $script:cfg.anim.doze
  $ch = 5; if ($null -ne $script:cfg.sleepTalkChance) { $ch = [int]$script:cfg.sleepTalkChance }  # 0 = never (a plain if would treat 0 as unset)
  if ($bubble.Visibility -ne 'Visible' -and (Get-Random -Maximum 100) -lt $ch) { Speak 'sleepTalk' '' }
  if ($a -and $a.extras) {  # now and then a small move in her sleep (smack lips, nuzzle the book, smile in a dream)
    $r = Get-Random -Maximum 100; $acc = 0
    foreach ($e in @($a.extras)) {
      $acc += [int]$e.chance
      if ($r -lt $acc) { $s = @($e.seq | Where-Object { $script:img.ContainsKey($_) }); if ($s.Count) { return $s } }
    }
  }
  if ($a -and $a.loop) { return @($a.loop) }
  return @('doze3')
}

# ---- state ----
$script:unread = $false; $script:needPending = $false; $script:eventAt = [DateTime]::MinValue
$script:hidden = $false; $script:lastLine = ''; $script:target = ''
function Working {
  $now = [DateTime]::UtcNow.Ticks; $stale = [TimeSpan]::FromMinutes([double]$script:cfg.staleMinutes).Ticks
  foreach ($f in Get-ChildItem -LiteralPath $sessDir -Filter '*.json') {
    try { $s = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    if ($s.state -eq 'work' -and ($now - [long]$s.t) -lt $stale) { return $true }
  }
  return $false
}
$script:idleSince = $null
function Resolve {
  if ($script:needPending) { $script:idleSince = $null; return 'need' }
  if ($script:unread) { $script:idleSince = $null; return 'wait' }
  if (Working) { $script:idleSince = $null; return 'work' }
  # idle long enough (no session working, nothing waiting, not poked) -> she dozes off
  $now = [DateTime]::UtcNow
  if (-not $script:idleSince) { $script:idleSince = $now }
  if ($script:cfg.dozeMinutes -and $script:img.ContainsKey('doze1') -and ($now - $script:idleSince).TotalMinutes -ge [double]$script:cfg.dozeMinutes) { return 'doze' }
  return 'idle'
}

# ---- bubble + voice ----
$bubbleTimer = New-Object Windows.Threading.DispatcherTimer
function FadeBubble([double]$to) {
  $a = New-Object Windows.Media.Animation.DoubleAnimation($to, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(260))))
  if ($to -eq 0) { $a.Add_Completed({ if ($bubble.Opacity -lt 0.05) { $bubble.Visibility = 'Collapsed' } }) } else { $bubble.Visibility = 'Visible' }
  $bubble.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
}
$bubbleTimer.Add_Tick({ $bubbleTimer.Stop(); FadeBubble 0 })
$script:player = New-Object Windows.Media.MediaPlayer
$brushDone = (New-Object Windows.Media.BrushConverter).ConvertFromString('#E0A070')
$brushProg = (New-Object Windows.Media.BrushConverter).ConvertFromString('#B8C4CE')
function Speak($kind, $sublineText) {
  $script:cfg = LoadCfg
  # progress = quieter look: grey-blue rim, shorter stay
  $secs = [double]$script:cfg.bubbleSec
  if ($kind -eq 'progress' -or $kind -eq 'sleepTalk') {
    $bubble.BorderBrush = $brushProg
    if ($script:cfg.progressBubbleSec) { $secs = [double]$script:cfg.progressBubbleSec }
  } else { $bubble.BorderBrush = $brushDone }
  if ($kind -like 'poke*' -and $script:cfg.pokeBubbleSec) { $secs = [double]$script:cfg.pokeBubbleSec }
  $script:bubbleKind = $kind
  # voice set: cfg.voice names one of cfg.voices, or 'rotate' = a random set each time
  $pool = @()
  if ($script:cfg.voices) {
    $names = @($script:cfg.voices.PSObject.Properties.Name)
    $vname = [string]$script:cfg.voice
    if ($vname -eq 'rotate' -or -not ($names -contains $vname)) {
      $cand = @($names | Where-Object { $_ -ne $script:lastVoice })
      if ($cand.Count -eq 0) { $cand = $names }
      $vname = $cand | Get-Random
    }
    $script:lastVoice = $vname
    $pool = @($script:cfg.voices.$vname.$kind)
  } else { $pool = @($script:cfg.lines.$kind) }
  if ($pool.Count -gt 1) { $pool = @($pool | Where-Object { $_.text -ne $script:lastLine }) }
  $line = $pool | Get-Random
  if (-not $line) { return }
  $script:lastLine = $line.text
  $say.Text = $line.text
  if ($sublineText) { $sub.Text = $sublineText; $sub.Visibility = 'Visible' } else { $sub.Visibility = 'Collapsed' }
  FadeBubble 1
  $bubbleTimer.Stop(); $bubbleTimer.Interval = [TimeSpan]::FromSeconds($secs); $bubbleTimer.Start()
  $quiet = ($kind -eq 'progress' -and $script:cfg.progressSound -eq $false) -or ($kind -eq 'sleepTalk' -and $script:cfg.sleepTalkVoice -eq $false)
  if (-not $script:cfg.muted -and -not $quiet -and $line.audio) {
    $ap = Join-Path $dir $line.audio
    if (Test-Path -LiteralPath $ap) {
      $script:player.Close(); $script:player.Volume = [double]$script:cfg.volume
      $script:player.Open([uri]$ap); $script:player.Play()
    }
  }
}
function Snippet($info) {
  $m = $info.last_assistant_message
  if (-not $m -and $info.transcript_path -and (Test-Path -LiteralPath $info.transcript_path)) {
    $tail = Get-Content -LiteralPath $info.transcript_path -Tail 40 -Encoding UTF8
    for ($i = $tail.Count - 1; $i -ge 0 -and -not $m; $i--) {
      if ($tail[$i].Length -gt 400000) { continue }
      try { $o = $tail[$i] | ConvertFrom-Json } catch { continue }
      if ($o.type -eq 'assistant') { foreach ($c in @($o.message.content)) { if ($c.type -eq 'text' -and $c.text.Trim()) { $m = $c.text } } }
    }
  }
  if (-not $m) { return '' }
  $s = ($m -replace '[`*#>|\[\]_]', '' -replace '\s+', ' ').Trim()
  if ($s.Length -gt 34) { $s = $s.Substring(0, 34) + [char]0x2026 }
  return $s
}
function Seen {
  $script:unread = $false; $script:needPending = $false
  $bubbleTimer.Stop(); FadeBubble 0
  if (-not (OneShot)) { SetMode (Resolve) }
}

# ---- poke: click her when nothing is waiting for you ----
$script:pokes = New-Object System.Collections.ArrayList
function Bounce([string]$how) {
  if ($how -eq 'shake') {
    $k = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $k.Duration = New-Object Windows.Duration([TimeSpan]::FromMilliseconds(420))
    $i = 0
    foreach ($x in @(-6, 6, -5, 5, -3, 3, 0)) {
      $i++
      [void]$k.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame($x, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(60 * $i)))))
    }
    $hop.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $k)
  } else {
    # squashed by the poke (from the feet), then a little hop up; 'jolt' = startled awake, bigger
    $sq = 0.9; $up = -14; if ($how -eq 'jolt') { $sq = 0.84; $up = -26 }
    $sy = New-Object Windows.Media.Animation.DoubleAnimation($sq, 1, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(260))))
    $sx = New-Object Windows.Media.Animation.DoubleAnimation(1.06, 1, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(260))))
    $el = New-Object Windows.Media.Animation.ElasticEase; $el.Oscillations = 2; $el.Springiness = 4; $el.EasingMode = 'EaseOut'
    $sy.EasingFunction = $el; $sx.EasingFunction = $el
    $squash.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $sy)
    $squash.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $sx)
    $a = New-Object Windows.Media.Animation.DoubleAnimation(0, $up, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(150))))
    $a.BeginTime = [TimeSpan]::FromMilliseconds(120)
    $a.AutoReverse = $true
    $e = New-Object Windows.Media.Animation.QuadraticEase; $e.EasingMode = 'EaseOut'; $a.EasingFunction = $e
    $hop.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $a)
  }
}
function Poke {
  $now = [DateTime]::UtcNow
  [void]$script:pokes.Add($now)
  while ($script:pokes.Count -gt 0 -and ($now - $script:pokes[0]).TotalSeconds -gt 4) { $script:pokes.RemoveAt(0) }
  $many = 4; if ($script:cfg.pokeManyCount) { $many = [int]$script:cfg.pokeManyCount }
  $dozing = ($script:mode -eq 'doze')
  $script:idleSince = $now  # any poke wakes her up / keeps her awake
  if ($dozing) {
    $script:pokes.Clear()
    $kind = 'pokeWake'; Bounce 'jolt'
  } elseif ($script:pokes.Count -ge $many) {
    $script:pokes.Clear()
    $kind = 'pokeMany'; Bounce 'shake'
  } else {
    $kind = 'pokeIdle'; if (Working) { $kind = 'pokeWork' }
    Bounce 'hop'
  }
  SetMode $kind $true
  Speak $kind ''
}

# ---- event loop ----
$poll = New-Object Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(500)
$poll.Add_Tick({
  foreach ($f in @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' | Sort-Object Name)) {
    $kind = ($f.BaseName -split '_')[1]
    $info = $null
    try { $info = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    Remove-Item -LiteralPath $f.FullName -Force
    $proj = ''; if ($info -and $info.cwd) { $proj = Split-Path -Leaf ([string]$info.cwd) }
    $hostId = ''
    if ($info -and $info.session_id) {
      $sfp = Join-Path $sessDir ([string]$info.session_id + '.json')
      try { $hostId = [string](Get-Content -LiteralPath $sfp -Raw -Encoding UTF8 | ConvertFrom-Json).host } catch {}
    }
    if ($kind -eq 'done' -or $kind -eq 'need') { $script:target = $hostId }
    if ($kind -eq 'progress') {
      # mid-task report: say so quietly, keep working, nothing marked unread
      if ($script:needPending -or $script:unread) { continue }  # don't cover a louder message
      $script:target = $hostId
      $snip = ''; if ($info) { $snip = Snippet $info }
      $parts = @($proj, $snip) | Where-Object { $_ }
      if (-not $script:hidden) { Speak 'progress' ($parts -join (' ' + [char]0x00B7 + ' ')) }
      continue
    }
    if ($kind -eq 'work') {
      $script:unread = $false; $script:needPending = $false; $bubbleTimer.Stop(); FadeBubble 0
    } elseif ($kind -eq 'done') {
      $script:needPending = $false; $script:unread = $true; $script:eventAt = [DateTime]::UtcNow
      $snip = ''; if ($info) { $snip = Snippet $info }
      $parts = @($proj, $snip) | Where-Object { $_ }
      if ($script:hidden) { $win.Show(); $script:hidden = $false }
      Speak 'done' ($parts -join (' ' + [char]0x00B7 + ' '))
      SetMode 'cheer' $true
      continue
    } elseif ($kind -eq 'need') {
      $script:needPending = $true; $script:eventAt = [DateTime]::UtcNow
      if ($script:hidden) { $win.Show(); $script:hidden = $false }
      Speak 'need' $proj
    }
  }
  # the user looked at Claude: treat as seen (after a short grace so the celebration still plays)
  if ($script:cfg.clearWhenClaudeFocused -and ($script:unread -or $script:needPending) -and ([DateTime]::UtcNow - $script:eventAt).TotalSeconds -gt 4) {
    $h = [XiaokeW.U]::GetForegroundWindow(); $fpid = [uint32]0
    [void][XiaokeW.U]::GetWindowThreadProcessId($h, [ref]$fpid)
    $fp = Get-Process -Id $fpid
    if ($fp -and $fp.ProcessName -eq 'Claude') { Seen }
  }
  if (-not (OneShot)) { SetMode (Resolve) }
})

# ---- mouse: drag to move, click = seen + jump to Claude, right-click = menu ----
$script:downPos = $null
$win.Add_MouseLeftButtonDown({
  $script:downPos = @($win.Left, $win.Top)
  try { $win.DragMove() } catch {}
  if ([math]::Abs($win.Left - $script:downPos[0]) -lt 3 -and [math]::Abs($win.Top - $script:downPos[1]) -lt 3) {
    # something for you (finished / needs you / a progress bubble still up) -> open it; otherwise it's a poke
    $openable = $script:unread -or $script:needPending -or ($bubble.Visibility -eq 'Visible' -and $script:bubbleKind -eq 'progress')
    if (-not $openable) { Poke; return }
    $t = $script:target
    Seen
    if ($t -and $t -match '^local_[A-Za-z0-9-]{1,64}$') {
      # opens the desktop app on exactly the conversation that finished
      Start-Process ('claude://claude.ai/epitaxy/' + $t)
    }
    $p = Get-Process -Name 'Claude' | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) {
      if ([XiaokeW.U]::IsIconic($p.MainWindowHandle)) { [void][XiaokeW.U]::ShowWindow($p.MainWindowHandle, 9) }
      [void][XiaokeW.U]::SetForegroundWindow($p.MainWindowHandle)
    }
  } else {
    [IO.File]::WriteAllText($posFile, (@{ left = $win.Left; top = $win.Top } | ConvertTo-Json -Compress), $utf8)
  }
})
$menu = New-Object Windows.Controls.ContextMenu
$miMute = New-Object Windows.Controls.MenuItem
$miHide = New-Object Windows.Controls.MenuItem; $miHide.Header = $script:cfg.ui.hide
$miReset = New-Object Windows.Controls.MenuItem; $miReset.Header = $script:cfg.ui.reset
$miQuit = New-Object Windows.Controls.MenuItem; $miQuit.Header = $script:cfg.ui.quit
function MuteLabel { if ($script:cfg.muted) { $miMute.Header = $script:cfg.ui.unmute } else { $miMute.Header = $script:cfg.ui.mute } }
MuteLabel
$miMute.Add_Click({
  $c = LoadCfg; $c.muted = -not [bool]$c.muted
  [IO.File]::WriteAllText((Join-Path $dir 'config.json'), ($c | ConvertTo-Json -Depth 8), $utf8)
  $script:cfg = $c; MuteLabel
})
$miHide.Add_Click({ $script:hidden = $true; $win.Hide() })
$miReset.Add_Click({ Get-ChildItem -LiteralPath $sessDir -Filter '*.json' | Remove-Item -Force; Seen; SetMode (Resolve) $true })
$miQuit.Add_Click({ $win.Close() })
# voice submenu: one item per set in cfg.voices, plus 'rotate'
$miVoice = New-Object Windows.Controls.MenuItem; $miVoice.Header = $script:cfg.ui.voice
$miVoice.FontFamily = 'Microsoft YaHei UI'
function VoiceChecks { foreach ($it in $miVoice.Items) { $it.IsChecked = ([string]$it.Tag -eq [string]$script:cfg.voice) } }
$vnames = @(); if ($script:cfg.voices) { $vnames = @($script:cfg.voices.PSObject.Properties.Name) }
$vlist = $vnames; if ($vnames.Count -gt 1) { $vlist = $vnames + @('rotate') }  # 'rotate' only makes sense with 2+ sets
foreach ($vn in $vlist) {
  $it = New-Object Windows.Controls.MenuItem
  $it.Tag = $vn; $it.IsCheckable = $true; $it.FontFamily = 'Microsoft YaHei UI'
  if ($vn -eq 'rotate') { $it.Header = $script:cfg.ui.rotate } else { $it.Header = $vn }
  $it.Add_Click({
    $c = LoadCfg; $c.voice = [string]$this.Tag
    [IO.File]::WriteAllText((Join-Path $dir 'config.json'), ($c | ConvertTo-Json -Depth 8), $utf8)
    $script:cfg = $c; VoiceChecks
    if (-not $script:hidden) { Speak 'done' '' }  # let her say one line in the new voice
  })
  [void]$miVoice.Items.Add($it)
}
VoiceChecks
# sleep-talk submenu: how often (cfg.sleepTalkOptions = [{label, chance}]) + whether she says it out loud
$miSleep = New-Object Windows.Controls.MenuItem; $miSleep.Header = $script:cfg.ui.sleepTalk
function SleepChecks {
  foreach ($it in $miSleep.Items) {
    if ($it -isnot [Windows.Controls.MenuItem]) { continue }
    if ($it.Tag -eq 'voice') { $it.IsChecked = -not ($script:cfg.sleepTalkVoice -eq $false) }
    else { $it.IsChecked = ([int]$it.Tag -eq [int]$script:cfg.sleepTalkChance) }
  }
}
function SaveCfg($c) { [IO.File]::WriteAllText((Join-Path $dir 'config.json'), ($c | ConvertTo-Json -Depth 8), $utf8); $script:cfg = $c }
foreach ($op in @($script:cfg.sleepTalkOptions)) {
  if (-not $op) { continue }
  $it = New-Object Windows.Controls.MenuItem
  $it.Tag = [string]$op.chance; $it.Header = [string]$op.label; $it.IsCheckable = $true; $it.FontFamily = 'Microsoft YaHei UI'
  $it.Add_Click({ $c = LoadCfg; $c.sleepTalkChance = [int]$this.Tag; SaveCfg $c; SleepChecks })
  [void]$miSleep.Items.Add($it)
}
[void]$miSleep.Items.Add((New-Object Windows.Controls.Separator))
$miSleepVoice = New-Object Windows.Controls.MenuItem
$miSleepVoice.Tag = 'voice'; $miSleepVoice.Header = $script:cfg.ui.sleepTalkVoice; $miSleepVoice.IsCheckable = $true; $miSleepVoice.FontFamily = 'Microsoft YaHei UI'
$miSleepVoice.Add_Click({
  $c = LoadCfg
  $on = -not ($c.sleepTalkVoice -eq $false)
  if ($c.PSObject.Properties.Name -contains 'sleepTalkVoice') { $c.sleepTalkVoice = -not $on } else { $c | Add-Member -NotePropertyName sleepTalkVoice -NotePropertyValue (-not $on) }
  SaveCfg $c; SleepChecks
})
[void]$miSleep.Items.Add($miSleepVoice)
SleepChecks
# volume slider (0-100 -> MediaPlayer 0..1): live while dragging, saved + one sample line on release
$miVol = New-Object Windows.Controls.MenuItem; $miVol.StaysOpenOnClick = $true
$vp = New-Object Windows.Controls.StackPanel; $vp.Orientation = 'Horizontal'
$vt = New-Object Windows.Controls.TextBlock; $vt.Text = [string]$script:cfg.ui.volume; $vt.VerticalAlignment = 'Center'; $vt.Margin = '0,0,8,0'; $vt.FontFamily = 'Microsoft YaHei UI'
$vs = New-Object Windows.Controls.Slider; $vs.Minimum = 0; $vs.Maximum = 100; $vs.Width = 140; $vs.VerticalAlignment = 'Center'
$vs.IsMoveToPointEnabled = $true; $vs.SmallChange = 5; $vs.LargeChange = 10
$vs.Value = [double]$script:cfg.volume * 100
$vn2 = New-Object Windows.Controls.TextBlock; $vn2.Width = 38; $vn2.Margin = '8,0,0,0'; $vn2.VerticalAlignment = 'Center'; $vn2.Text = ('{0}%' -f [int]$vs.Value)
foreach ($x in @($vt, $vs, $vn2)) { [void]$vp.Children.Add($x) }
$miVol.Header = $vp
$vs.Add_ValueChanged({ $script:player.Volume = $vs.Value / 100; $vn2.Text = ('{0}%' -f [int]$vs.Value) })
$vs.Add_PreviewMouseUp({
  $c = LoadCfg; $c.volume = [math]::Round($vs.Value / 100, 2); SaveCfg $c
  if (-not $c.muted) {
    $lines = @(@($c.voices.([string]$c.voice).pokeIdle) | Where-Object { $_.audio })
    if ($lines.Count) {
      $ap = Join-Path $dir ($lines | Get-Random).audio
      if (Test-Path -LiteralPath $ap) { $script:player.Close(); $script:player.Volume = [double]$c.volume; $script:player.Open([uri]$ap); $script:player.Play() }
    }
  }
})
$items = @($miMute, $miVol, $miVoice, $miSleep, $miHide, $miReset, $miQuit)
if ($vnames.Count -lt 2) { $items = @($miMute, $miVol, $miSleep, $miHide, $miReset, $miQuit) }  # one voice set: no voice menu
foreach ($mi in $items) { $mi.FontFamily = 'Microsoft YaHei UI'; [void]$menu.Items.Add($mi) }
$pet.ContextMenu = $menu

SetMode (Resolve) $true
$anim.Start(); $poll.Start()
[void]$win.ShowDialog()
$script:player.Close()
$mtx.ReleaseMutex()

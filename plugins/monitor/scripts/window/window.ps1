# polaris-monitor window for Windows, also opened from WSL: an always-on-top card in the
# bottom-right corner that lists the Claude Code sessions recorded by session.sh, with the
# usage limits saved by statusline.sh. It never reads the Claude login or calls an API.
#
# Opened by /polaris-monitor:open-window, which copies this file, mascots.json and
# themes.json to ~/.polaris-monitor (the Windows profile's on WSL). A named mutex keeps a
# single window; when this file changes (a newer plugin version was copied), the open window
# closes itself and the new one, which waits up to 5 seconds for the mutex, takes over.
#
# Dots: green (pulsing) working, red finished, blue asked a question, yellow waiting for
# permission. The mascot walks around the card while a session works, jumps on top while
# one waits for you and stands still otherwise. Drag with the left button; the arrow on a
# session with subagents collapses its subagent rows; right-click for the options, which
# are saved in config.json (the macOS window reads the same file).
#
# Mascots and color themes come from mascots.json and themes.json next to this file, plus
# the user's own in <folder>\custom\, which add to or replace them and are never overwritten.
# The window reloads them within 2 seconds of a change.
#
# Testing: -Snapshot out.png renders the card off screen, saves the PNG and, next to it,
# out.png.txt with what the window saw, then exits. -Folder replaces ~/.polaris-monitor,
# -UsageFile reads the usage from that file whatever its age, and -Pulse sets the phase of
# the working dot (0 = brightest, 0.5 = dimmest).
param([string]$Snapshot, [string]$Folder, [string]$UsageFile, [string]$Pulse)
Add-Type -AssemblyName PresentationFramework
if (-not $Folder) { $Folder = Join-Path $HOME '.polaris-monitor' }
$sessionsDir = Join-Path $Folder 'sessions'

# Short fixed messages and exception type names only, never session content.
$logFile = Join-Path $Folder 'monitor.log'
function Write-Log($text) {
    if ($Snapshot) { return }
    try {
        if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 256KB) {
            Move-Item -LiteralPath $logFile "$logFile.1" -Force
        }
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$PID] $text`r`n"
        [IO.File]::AppendAllText($logFile, $line, [Text.UTF8Encoding]::new($false))
    } catch {}
}

if (-not $Snapshot) {
    $mutex = [Threading.Mutex]::new($false, 'PolarisMonitorWindow')
    $owned = $false
    try { $owned = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { $mutex.Dispose(); exit }
}
$version = (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc
Write-Log 'opened'

# --- Mascots and themes: the plugin's files, then the user's in custom\ (same key replaces).
$assetFiles = @(
    @{ kind = 'mascots'; path = Join-Path $PSScriptRoot 'mascots.json' },
    @{ kind = 'themes'; path = Join-Path $PSScriptRoot 'themes.json' },
    @{ kind = 'mascots'; path = Join-Path $Folder 'custom\mascots.json' },
    @{ kind = 'themes'; path = Join-Path $Folder 'custom\themes.json' }
)
# The Dark theme, also the fallback for any color a theme leaves out or gets wrong.
$defaultTheme = [ordered]@{
    card = '#F21C1D2F'; text = '#FFFFFF'; muted = '#A6A5C4'; faint = '#7C7F9E'; accent = '#DEDAF4'
    divider = '#33FFFFFF'; track = '#33365A'; bar = '#699BFB'; barWarning = '#F59E0B'; barCritical = '#EF4444'
    working = '#22C55E'; finished = '#EF4444'; question = '#699BFB'; permission = '#FACC15'
}
$sizes = [ordered]@{ small = 0.85; normal = 1.0; large = 1.25 }

function Test-Color($value) { $value -is [string] -and $value -match '^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$' }
function Test-Key($value) { $value -is [string] -and $value -match '^[a-z0-9-]{1,32}$' }

# A mascot needs a rectangular sprite and a pixel size that keep it within 32 px of height
# (the room above the card) and 64 px of width; its colors must be hex.
function ConvertTo-Mascot($key, $entry) {
    $sprite = @($entry.sprite | Where-Object { $_ -is [string] })
    if (-not $sprite.Count -or $sprite.Count -ne @($entry.sprite).Count) { return $null }
    if (@($sprite | Where-Object { $_.Length -ne $sprite[0].Length -or $_.Length -lt 1 }).Count) { return $null }
    $pixel = @($entry.pixel)
    if ($pixel.Count -ne 2) { return $null }
    try { $pw = [double]$pixel[0]; $ph = [double]$pixel[1] } catch { return $null }
    if ($pw -lt 0.5 -or $ph -lt 0.5 -or $sprite.Count * $ph -gt 32 -or $sprite[0].Length * $pw -gt 64) { return $null }
    $colors = $entry.colors
    foreach ($part in 'body', 'face', 'feet') { if (-not (Test-Color $colors.$part)) { return $null } }
    if ($null -ne $colors.outline -and -not (Test-Color $colors.outline)) { return $null }
    $name = $(if ($entry.name -is [string] -and $entry.name.Trim()) { $entry.name.Trim() } else { $key })
    @{ name = $name; sprite = $sprite; pw = $pw; ph = $ph; body = $colors.body; face = $colors.face; feet = $colors.feet; outline = $colors.outline }
}

$mascots = [ordered]@{}
$themes = [ordered]@{}
$assetStamps = ''
function Get-AssetStamps {
    ($assetFiles | ForEach-Object { if ([IO.File]::Exists($_.path)) { [IO.File]::GetLastWriteTimeUtc($_.path).Ticks } else { 0 } }) -join ','
}
function Import-Assets {
    $script:mascots = [ordered]@{}
    $dark = [ordered]@{ name = 'Dark' }
    foreach ($color in $defaultTheme.Keys) { $dark[$color] = $defaultTheme[$color] }
    $script:themes = [ordered]@{ dark = $dark }
    foreach ($file in $assetFiles) {
        if (-not [IO.File]::Exists($file.path)) { continue }
        try { $data = [IO.File]::ReadAllText($file.path) | ConvertFrom-Json } catch {
            Write-Log "$($file.kind) file is not valid JSON ($($_.Exception.GetType().Name))"
            continue
        }
        foreach ($property in @($data.PSObject.Properties)) {
            if (-not (Test-Key $property.Name)) { Write-Log "ignored $($file.kind) entry: bad name"; continue }
            if ($file.kind -eq 'mascots') {
                $mascot = ConvertTo-Mascot $property.Name $property.Value
                if ($mascot) { $script:mascots[$property.Name] = $mascot } else { Write-Log "ignored mascot $($property.Name): invalid" }
            } else {
                $theme = [ordered]@{ name = $(if ($property.Value.name -is [string]) { $property.Value.name } else { $property.Name }) }
                foreach ($color in $defaultTheme.Keys) {
                    $theme[$color] = $(if (Test-Color $property.Value.$color) { $property.Value.$color } else { $defaultTheme[$color] })
                }
                $script:themes[$property.Name] = $theme
            }
        }
    }
    $script:assetStamps = Get-AssetStamps
}
Import-Assets

# --- Sounds: off by default (the hooks already beep). Custom files in sounds\ replace the
# Windows ones: question, finished and all-done, as .wav or .mp3.
function Find-CustomSound($name) {
    foreach ($ext in 'wav', 'mp3') {
        $file = Join-Path $Folder "sounds\$name.$ext"
        if (Test-Path -LiteralPath $file -PathType Leaf) { return $file }
    }
}
$sounds = @{
    question   = "$env:WINDIR\Media\Windows Notify Messaging.wav"
    finished   = "$env:WINDIR\Media\Windows Notify System Generic.wav"
    'all-done' = "$env:WINDIR\Media\tada.wav"
}
foreach ($name in @($sounds.Keys)) {
    $custom = Find-CustomSound $name
    if ($custom) { $sounds[$name] = $custom }
}

# --- Options (right-click), saved in config.json; without the file, the defaults.
$configFile = Join-Path $Folder 'config.json'
$config = @{ opacity = 1.0; mascot = $true; character = 'star'; theme = 'dark'; size = 'normal'; volume = 1.0; usage = $true; sound = $false; subagents = $true }
if ([IO.File]::Exists($configFile)) {
    try {
        $saved = [IO.File]::ReadAllText($configFile) | ConvertFrom-Json
        # 1.0, not 1: [math]::Min(1, x) would pick the integer overload and turn 0.5 into 0
        if ($null -ne $saved.opacity) { $config.opacity = [math]::Min(1.0, [math]::Max(0.2, [double]$saved.opacity)) }
        if ($null -ne $saved.volume) { $config.volume = [math]::Min(1.0, [math]::Max(0.0, [double]$saved.volume)) }
        foreach ($key in 'mascot', 'usage', 'sound', 'subagents') {
            if ($null -ne $saved.$key) { $config[$key] = [bool]$saved.$key }
        }
        foreach ($key in 'character', 'theme', 'size') {
            if (Test-Key $saved.$key) { $config[$key] = [string]$saved.$key }
        }
    } catch { Write-Log "config.json is invalid, using the defaults ($($_.Exception.GetType().Name))" }
}
function Save-Config {
    try { [IO.File]::WriteAllText($configFile, ($config | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false)) } catch {}
}
# a choice that no longer exists (a removed custom file) falls back to the default
function Get-Theme { if ($themes.Contains($config.theme)) { $themes[$config.theme] } else { $themes['dark'] } }
function Get-ThemeKey { if ($themes.Contains($config.theme)) { $config.theme } else { 'dark' } }
function Get-Scale { if ($sizes.Contains($config.size)) { $sizes[$config.size] } else { 1.0 } }
function Get-SizeKey { if ($sizes.Contains($config.size)) { $config.size } else { 'normal' } }
function Get-MascotKey {
    if ($mascots.Contains($config.character)) { return $config.character }
    if ($mascots.Contains('star')) { return 'star' }
    @($mascots.Keys)[0]
}

# MediaPlayer has a volume, SoundPlayer does not. Open never throws: a failure arrives later
# in MediaFailed (Windows "N" editions without the media pack), and then SoundPlayer plays it.
$player = New-Object Windows.Media.MediaPlayer
$player.Volume = $config.volume
$player.Add_MediaOpened({ $player.Play() })
$fallbackPlayer = New-Object Media.SoundPlayer
$player.Add_MediaFailed({
    try { $fallbackPlayer.SoundLocation = $player.Source.LocalPath; $fallbackPlayer.Play() }
    catch { Write-Log "could not play a sound ($($_.Exception.GetType().Name))" }
})

$lastSituation = @{}  # session id -> last situation seen
# Snapshot: start from the situations in previous.json, to see which sound would play
$previousFile = Join-Path $Folder 'previous.json'
if ($Snapshot -and (Test-Path -LiteralPath $previousFile)) {
    (Get-Content -LiteralPath $previousFile -Raw | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $lastSituation[$_.Name] = $_.Value }
}
$soundChosen = $null  # the last sound decided (the snapshot reports it instead of playing it)

# A fixed-size 320x440 layout that never moves by itself: the card is pinned to its
# bottom-right corner and grows upwards inside it. The Viewbox scales it for the size option.
# The rest is transparent and lets clicks through.
$margin = 34  # room around the card, where the mascot walks
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        FontFamily="Inter, Segoe UI" FontSize="12">
  <Viewbox Stretch="Uniform">
    <Grid Width="320" Height="440">
      <Border Name="Card" CornerRadius="8" Padding="10,6"
              HorizontalAlignment="Right" VerticalAlignment="Bottom">
        <StackPanel>
          <StackPanel Name="Sessions"/>
          <Border Name="Divider" Height="1" Margin="0,5,0,4"/>
          <StackPanel Name="Usage"/>
        </StackPanel>
      </Border>
      <Canvas Name="Mascot" IsHitTestVisible="False" HorizontalAlignment="Left" VerticalAlignment="Top">
        <Canvas.RenderTransform><MatrixTransform/></Canvas.RenderTransform>
      </Canvas>
    </Grid>
  </Viewbox>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$card = $win.FindName('Card')
$divider = $win.FindName('Divider')
$sessionsPanel = $win.FindName('Sessions')
$usagePanel = $win.FindName('Usage')
$mascot = $win.FindName('Mascot')
$card.Margin = [Windows.Thickness]::new($margin)

function New-Brush($hex) { [Windows.Media.BrushConverter]::new().ConvertFromString($hex) }

# The opacity option dims the card and the mascot alike.
function Set-Opacity($value) {
    $card.Opacity = $value
    $mascot.Opacity = $value
}
Set-Opacity $config.opacity

# Working: the green dot pulses, for anyone who cannot tell green from red. One animated
# brush, so the pulse keeps going while the list is rebuilt every 2 s. Opacity
# 0.65 + 0.35 * cos(2 pi phase), a full cycle in 1.6 s.
$workingDot = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($defaultTheme.working))
if ($Snapshot) {
    $phase = $(if ($Pulse) { [double]::Parse($Pulse, [Globalization.CultureInfo]::InvariantCulture) } else { 0 })
    $workingDot.Opacity = 0.65 + 0.35 * [math]::Cos(2 * [math]::PI * $phase)
} else {
    $pulsing = [Windows.Media.Animation.DoubleAnimation]::new(1, 0.3, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(800)))
    $pulsing.AutoReverse = $true
    $pulsing.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $pulsing.EasingFunction = New-Object Windows.Media.Animation.SineEase -Property @{ EasingMode = 'EaseInOut' }
    [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($pulsing, 20)
    $workingDot.BeginAnimation([Windows.Media.Brush]::OpacityProperty, $pulsing)
}

$childRows = @{}  # subagent rows, by "session/subagent" (see Update-Window)

# Colors of the card itself; the rows pick theirs up when they are rebuilt.
function Set-Theme {
    $theme = Get-Theme
    $card.Background = New-Brush $theme.card
    $divider.Background = New-Brush $theme.divider
    $workingDot.Color = [Windows.Media.ColorConverter]::ConvertFromString($theme.working)
    $childRows.Clear()
}
Set-Theme

# The size option: the window grows or shrinks around its bottom-right corner.
$place = @{ x = $null; y = $null; dragging = $false }
function Set-Size {
    $scale = Get-Scale
    $width = 320 * $scale; $height = 440 * $scale
    if ($null -ne $place.x) {
        $place.x += $win.Width - $width
        $place.y += $win.Height - $height
    }
    $win.Width = $width
    $win.Height = $height
}
Set-Size

function New-Text($text, $color, $width) {
    $block = New-Object Windows.Controls.TextBlock
    $block.Text = $text
    $block.Foreground = New-Brush $color
    $block.VerticalAlignment = 'Center'
    if ($width) { $block.Width = $width }
    $block
}

function New-Row {
    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = [Windows.Thickness]::new(0, 2, 0, 2)
    foreach ($element in $args) { [void]$row.Children.Add($element) }
    $row
}

# "now", "12m", "1h05", "3d4h"
function Format-Elapsed($minutes) {
    $m = [math]::Max(0, [int][math]::Floor($minutes))
    if ($m -lt 1) { return 'now' }
    if ($m -lt 60) { return "${m}m" }
    if ($m -lt 1440) { return '{0}h{1:00}' -f [math]::Floor($m / 60), ($m % 60) }
    return '{0}d{1}h' -f [math]::Floor($m / 1440), [math]::Floor(($m % 1440) / 60)
}

# --- Transcripts. Only regular files (no links) under the Claude config directory's projects
# folder are read: the path comes from a session file anything on the machine could write.
# Sessions recorded inside WSL point at Linux paths, so they get no transcript details here.
$configDir = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' })
$projectsRoot = [IO.Path]::GetFullPath((Join-Path $configDir 'projects')).TrimEnd('\') + '\'
function Get-SafeTranscript($path) {
    if (-not $path -or $path -isnot [string]) { return $null }
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Ignore
        if (-not $item -or $item.PSIsContainer -or $item.LinkType) { return $null }
        if ($item.FullName.StartsWith($projectsRoot, [StringComparison]::OrdinalIgnoreCase)) { return $item.FullName }
    } catch {}
    return $null
}

# The /rename title ("custom-title") wins over the automatic one ("ai-title"). Reads only the
# part of the transcript added since the last read, and never half a line.
$titles = @{}  # transcript -> @{ read; custom; ai }
function Get-Title($transcript) {
    $transcript = Get-SafeTranscript $transcript
    if (-not $transcript) { return $null }
    $t = $titles[$transcript]
    if (-not $t) { $t = @{ read = 0L; custom = $null; ai = $null }; $titles[$transcript] = $t }
    try {
        $stream = [IO.File]::Open($transcript, 'Open', 'Read', 'ReadWrite')
        try {
            if ($stream.Length -lt $t.read) { $t.read = 0L; $t.custom = $null; $t.ai = $null }
            $count = [int]($stream.Length - $t.read)
            if ($count -gt 0) {
                [void]$stream.Seek($t.read, 'Begin')
                $buffer = New-Object byte[] $count
                $done = 0
                while ($done -lt $count) { $k = $stream.Read($buffer, $done, $count - $done); if ($k -le 0) { break }; $done += $k }
                $end = [Array]::LastIndexOf($buffer, [byte]10, $done - 1) + 1
                $t.read += $end
                $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $end)
                foreach ($match in [regex]::Matches($text, '(?m)^.*"type":"(?:custom|ai)-title".*$')) {
                    try { $line = $match.Value | ConvertFrom-Json } catch { continue }
                    if ($line.type -eq 'custom-title' -and $line.customTitle) { $t.custom = $line.customTitle }
                    elseif ($line.type -eq 'ai-title' -and $line.aiTitle) { $t.ai = $line.aiTitle }
                }
            }
        } finally { $stream.Dispose() }
    } catch {}
    if ($t.custom) { $t.custom } else { $t.ai }
}

# What the last message of the conversation asks for: 'box' (an open AskUserQuestion), 'text'
# (a reply ending in a question) or nothing. Reads only the end of the transcript, and only
# when its size changed.
$lastRequests = @{}  # transcript -> @{ size; result }
function Get-LastRequest($transcript) {
    $transcript = Get-SafeTranscript $transcript
    if (-not $transcript) { return $null }
    $info = Get-Item -LiteralPath $transcript -ErrorAction Ignore
    if (-not $info) { return $null }
    $cached = $lastRequests[$transcript]
    if ($cached -and $cached.size -eq $info.Length) { return $cached.result }
    $result = $null
    try {
        $stream = [IO.File]::Open($transcript, 'Open', 'Read', 'ReadWrite')
        try {
            $count = [int][math]::Min($stream.Length, 65536)
            $partial = $count -lt $stream.Length  # read from the middle: the first line may be cut
            [void]$stream.Seek(-$count, 'End')
            $buffer = New-Object byte[] $count
            [void]$stream.Read($buffer, 0, $count)
        } finally { $stream.Dispose() }
        $lines = [Text.Encoding]::UTF8.GetString($buffer).Split("`n")
        for ($i = $lines.Count - 1; $i -ge [int]$partial; $i--) {
            $line = $lines[$i]
            if ($line -notmatch '"type":"(assistant|user)"' -or $line -match '"isSidechain":true') { continue }
            # each block of a reply is its own line; parse JSON (slow in PowerShell 5) only for text
            if ($line -match '"type":"assistant"') {
                if ($line -match '"type":"tool_use"') { if ($line -match '"name":"AskUserQuestion"') { $result = 'box' } }
                elseif ($line -match '"type":"text"') {
                    $block = @(($line | ConvertFrom-Json).message.content)[-1]
                    # a "?" inside quotes or backticks is a quotation, not a question for you
                    $last = ($block.text.Trim() -split "`n")[-1] -replace '"[^"]*"|`[^`]*`', ''
                    if ($last -match '\?') { $result = 'text' }
                }
            }
            break
        }
    } catch {}
    $lastRequests[$transcript] = @{ size = $info.Length; result = $result }
    $result
}

# The situation, from the hook state and the last message. Working and permission only turn
# into a question with the box (a "?" in the middle of the work does not count).
function Get-Situation($s) {
    $state = $s.state
    # approving a permission fires no hook until the session stops: if the transcript changed
    # after the request, the session went back to work
    $safe = Get-SafeTranscript $s.transcript
    if ($state -eq 'permission' -and $safe) {
        $changed = (Get-Item -LiteralPath $safe -ErrorAction Ignore).LastWriteTimeUtc
        if ($changed -and ([DateTimeOffset]$changed).ToUnixTimeMilliseconds() / 1000 -gt $s.since + 2) { $state = 'working' }
    }
    $request = Get-LastRequest $s.transcript
    switch ($state) {
        'waiting' { if ($request) { 'question' } else { 'finished' } }
        default { if ($request -eq 'box') { 'question' } else { $state } }
    }
}

# A session is alive while its process runs; without a process id (Windows and WSL
# sessions), while it was updated in the last 6 hours. Files of dead sessions are deleted.
function Get-Sessions($now) {
    $seen = @{}
    Get-ChildItem -LiteralPath $sessionsDir -Filter *.json -ErrorAction Ignore | ForEach-Object {
        $file = $_
        if ($file.BaseName -notmatch '^[A-Za-z0-9_-]{1,128}$') { return }
        try { $s = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
        $alive = $(if ($s.pid) { [bool](Get-Process -Id $s.pid -ErrorAction Ignore) } else { $now - $s.updated -le 6 * 3600 })
        if (-not $alive) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Ignore
            return
        }
        $s | Add-Member -NotePropertyName id -NotePropertyValue $file.BaseName
        $title = Get-Title $s.transcript
        if ($title) { $s.name = $title }
        $key = $(if ($s.pid) { "pid:$($s.pid)" } else { "id:$($s.id)" })
        if (-not $seen[$key] -or $seen[$key].updated -lt $s.updated) { $seen[$key] = $s }
    }
    $seen.Values |
        ForEach-Object { $_ | Add-Member -NotePropertyName situation -NotePropertyValue (Get-Situation $_) -PassThru } |
        Sort-Object updated -Descending
}

# A sound when a session changes to finished, question or permission (once per change, never
# on opening). A question wins over finished; when the last session finishes and nothing
# else runs or waits, the all-done sound.
function Send-Notice($sessions) {
    $chosen = $null
    foreach ($s in $sessions) {
        $before = $lastSituation[$s.id]
        if ($before -and $before -ne $s.situation -and $s.situation -ne 'working' -and $chosen -notin 'permission', 'question') {
            $chosen = $s.situation
        }
        $lastSituation[$s.id] = $s.situation
    }
    if (-not $chosen) { return }
    $name = $(if ($chosen -eq 'finished') { 'finished' } else { 'question' })
    if ($chosen -eq 'finished' -and -not @($sessions | Where-Object { $_.situation -ne 'finished' })) { $name = 'all-done' }
    $script:soundChosen = $name
    if ($Snapshot -or -not $config.sound -or $config.volume -le 0) { return }
    try { $player.Open([Uri]::new($sounds[$name])) } catch { Write-Log "could not play $name ($($_.Exception.GetType().Name))" }
}

# --- Usage, from the file the status line saves; older than 1 hour means unavailable.
$usage = @{ next = [DateTime]::MinValue; data = $null }
function Read-Usage($file, [switch]$AnyAge) {
    if (-not $file -or -not [IO.File]::Exists($file)) { return $null }
    try {
        $saved = [IO.File]::ReadAllText($file) | ConvertFrom-Json
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$saved.updated
        if (-not $AnyAge -and (-not $saved.updated -or $age -gt 3600)) { return $null }
        $windows = [ordered]@{}
        foreach ($pair in @(@('5h', $saved.five_hour), @('7d', $saved.seven_day))) {
            if ($null -ne $pair[1] -and $null -ne $pair[1].used_percentage) {
                $windows[$pair[0]] = @{ percent = [double]$pair[1].used_percentage; resets = $pair[1].resets_at }
            }
        }
        if ($windows.Count) { return $windows }
    } catch { Write-Log "usage.json is unreadable ($($_.Exception.GetType().Name))" }
    $null
}
if ($Snapshot) { $usage = @{ next = [DateTime]::MaxValue; data = (Read-Usage $UsageFile -AnyAge) } }

function New-Meter($label, $window) {
    $theme = Get-Theme
    $percent = $window.percent
    $color = $(if ($percent -ge 95) { $theme.barCritical } elseif ($percent -ge 80) { $theme.barWarning } else { $theme.bar })
    $track = New-Object Windows.Controls.Border
    $track.Width = 118; $track.Height = 4
    $track.CornerRadius = [Windows.CornerRadius]::new(2)
    $track.Background = New-Brush $theme.track
    $track.VerticalAlignment = 'Center'
    $bar = New-Object Windows.Controls.Border
    $bar.Width = 118 * [math]::Min([math]::Max($percent, 0), 100) / 100
    $bar.CornerRadius = [Windows.CornerRadius]::new(2)
    $bar.Background = New-Brush $color
    $bar.HorizontalAlignment = 'Left'
    $track.Child = $bar
    $percentText = New-Text ('{0:0}%' -f $percent) $color 38
    $percentText.TextAlignment = 'Right'
    $left = ''
    if ($window.resets) { $left = Format-Elapsed (([double]$window.resets - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) / 60) }
    $leftText = New-Text $left $theme.faint 48
    $leftText.TextAlignment = 'Right'
    New-Row (New-Text $label $theme.muted 18) $track $percentText $leftText
}

# --- Subagent rows, cached by "session/subagent": the list is rebuilt every 2 s, and a new row
# would restart the sideways scroll of a long description.
$childWidth = 144
function New-ChildRow($text, $type) {
    $theme = Get-Theme
    $branch = New-Text ([string][char]0x2514) $theme.faint 16
    $branch.Margin = [Windows.Thickness]::new(8, 0, 6, 0)
    $view = New-Object Windows.Controls.Canvas
    $view.Width = $childWidth
    $view.Height = 16
    $view.ClipToBounds = $true
    $view.VerticalAlignment = 'Center'
    $label = New-Text $text $theme.muted
    $label.FontSize = 11
    $label.TextWrapping = 'NoWrap'
    [void]$view.Children.Add($label)
    $label.Measure([Windows.Size]::new(100000, 100))
    $overflow = $label.DesiredSize.Width - $childWidth
    if ($overflow -gt 1 -and -not $Snapshot) {
        # pause, slide to the end at about 25 px/s, pause, slide back, repeat
        $target = -($overflow + 4)
        $slide = [math]::Max(1.5, $overflow / 25)
        $shift = New-Object Windows.Media.TranslateTransform
        $label.RenderTransform = $shift
        $scroll = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $scroll.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds(2 * $slide + 2.4))
        $scroll.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        foreach ($point in @(@(0, 0), @(0, 1.2), @($target, 1.2 + $slide), @($target, 2.4 + $slide), @(0, 2.4 + 2 * $slide))) {
            $frame = [Windows.Media.Animation.LinearDoubleKeyFrame]::new([double]$point[0], [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($point[1])))
            [void]$scroll.KeyFrames.Add($frame)
        }
        [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($scroll, 30)
        $shift.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $scroll)
    }
    $elapsed = New-Text '' $theme.faint 36
    $elapsed.FontSize = 11
    $elapsed.TextAlignment = 'Right'
    $row = New-Row $branch $view $elapsed
    $row.Margin = [Windows.Thickness]::new(0, 0, 0, 2)
    $row.ToolTip = "${type}: $text"
    @{ row = $row; elapsed = $elapsed; text = $text }
}

$collapsed = @{}  # session id -> $true while its subagent rows are hidden (until the window closes)
$tooltips = @{ working = 'working'; finished = 'finished'; question = 'asked you a question'; permission = 'waiting for permission' }

function Update-Window {
    $theme = Get-Theme
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000
    $sessions = @(Get-Sessions $now)
    Send-Notice $sessions
    $sessionsPanel.Children.Clear()
    if (-not $sessions) { [void]$sessionsPanel.Children.Add((New-Text 'no open sessions' $theme.muted)) }
    $liveChildren = @{}
    foreach ($s in $sessions) {
        $color = $(if ($tooltips.ContainsKey($s.situation)) { $theme[$s.situation] } else { $theme.muted })
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 8; $dot.Height = 8
        $dot.Fill = $(if ($s.situation -eq 'working') { $workingDot } else { New-Brush $color })
        $dot.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
        $dot.VerticalAlignment = 'Center'
        # @(if ...) keeps a single subagent a list
        $children = @(if ($config.subagents) { $s.subagents | Where-Object { $_ -and $_.id } })
        $isCollapsed = [bool]$collapsed["$($s.id)"]
        $name = New-Text $s.name $theme.text 142
        $name.TextTrimming = 'CharacterEllipsis'
        # arrow slot: pointing down while the subagents show, right (with the count) when collapsed
        $slot = New-Object Windows.Controls.Border
        $slot.Width = 28
        $slot.Background = [Windows.Media.Brushes]::Transparent
        if ($children.Count) {
            $arrow = [string][char]0x203A
            $chevron = New-Text $(if ($isCollapsed) { "$arrow $($children.Count)" } else { $arrow }) $theme.accent
            $chevron.FontSize = 16
            $chevron.FontWeight = 'Bold'
            $chevron.HorizontalAlignment = 'Center'
            if (-not $isCollapsed) { $chevron.LayoutTransform = [Windows.Media.RotateTransform]::new(90) }
            $slot.Child = $chevron
            $slot.Tag = "collapse:$($s.id)"
            $slot.Cursor = [Windows.Input.Cursors]::Hand
            $slot.ToolTip = $(if ($isCollapsed) { 'Show subagents' } else { 'Hide subagents' })
        }
        $elapsed = New-Text (Format-Elapsed (($now - $s.since) / 60)) $color 36
        $elapsed.TextAlignment = 'Right'
        $row = New-Row $dot $name $slot $elapsed
        $row.Background = [Windows.Media.Brushes]::Transparent
        $row.ToolTip = $(if ($tooltips.ContainsKey($s.situation)) { $tooltips[$s.situation] } else { $s.situation })
        $row.Tag = "session:$($s.id)"
        [void]$sessionsPanel.Children.Add($row)
        foreach ($sub in $(if ($isCollapsed) { @() } else { $children })) {
            $key = "$($s.id)/$($sub.id)"
            $text = $(if ($sub.desc) { "$($sub.desc)" } else { "$($sub.type)" })
            $cached = $childRows[$key]
            if (-not $cached -or $cached.text -ne $text) {
                $cached = New-ChildRow $text "$($sub.type)"
                $childRows[$key] = $cached
            }
            $cached.elapsed.Text = Format-Elapsed (($now - $sub.since) / 60)
            $liveChildren[$key] = $true
            [void]$sessionsPanel.Children.Add($cached.row)
        }
    }
    foreach ($key in @($childRows.Keys)) { if (-not $liveChildren.ContainsKey($key)) { $childRows.Remove($key) } }
    # waiting for you beats working, which beats idle
    $situations = @($sessions | ForEach-Object { $_.situation })
    Set-MascotMode $(if ($situations -contains 'question' -or $situations -contains 'permission') { 'jumping' }
                     elseif ($situations -contains 'working') { 'walking' } else { 'standing' })

    if ($config.usage -and [DateTime]::Now -ge $usage.next) {
        $usage.next = [DateTime]::Now.AddSeconds(10)
        $usage.data = Read-Usage (Join-Path $Folder 'usage.json')
    }
    # rebuilt every 2 s so the time to reset keeps counting between reads
    $usagePanel.Children.Clear()
    if (-not $config.usage -and -not $Snapshot) {
        [void]$usagePanel.Children.Add((New-Text 'usage off (right-click)' $theme.faint))
    } elseif ($usage.data) {
        foreach ($label in $usage.data.Keys) { [void]$usagePanel.Children.Add((New-Meter $label $usage.data[$label])) }
    } else {
        [void]$usagePanel.Children.Add((New-Text 'usage unavailable' $theme.faint))
    }
}

# --- Mascot, drawn from its sprite: '#' body, 'o' eyes and 'u' smile (the face color), 'A'
# and 'B' the two pairs of feet, which alternate while walking. The origin (0,0) is between
# the feet, so the mascot stands on the card's edge.
$mascotParts = New-Object Collections.ArrayList

# jumping: up fast, slowing at the top; AutoReverse speeds up the way down
$hop = New-Object Windows.Controls.Canvas
$hop.RenderTransform = New-Object Windows.Media.TranslateTransform
[void]$mascot.Children.Add($hop)
$jump = [Windows.Media.Animation.DoubleAnimation]::new(0, -5, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(160)))
$jump.AutoReverse = $true
$jump.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
$jump.EasingFunction = New-Object Windows.Media.Animation.QuadraticEase -Property @{ EasingMode = 'EaseOut' }
[Windows.Media.Animation.Timeline]::SetDesiredFrameRate($jump, 40)

# One shape per color: the pixel rectangles are merged, so there are no seams between them
# (and the outline strokes only the outer edge).
function New-SpriteShape($m, $pattern, $color, $stroke) {
    $geometry = $null
    $sprite = $m.sprite
    for ($line = 0; $line -lt $sprite.Count; $line++) {
        foreach ($match in [regex]::Matches($sprite[$line], $pattern)) {
            $x = ($match.Index - [int][math]::Floor($sprite[0].Length / 2)) * $m.pw
            $rect = [Windows.Rect]::new($x, ($line - $sprite.Count) * $m.ph, $match.Length * $m.pw, $m.ph)
            $piece = [Windows.Media.RectangleGeometry]::new($rect)
            $geometry = $(if ($geometry) { [Windows.Media.Geometry]::Combine($geometry, $piece, [Windows.Media.GeometryCombineMode]::Union, $null) } else { $piece })
        }
    }
    $shape = New-Object Windows.Shapes.Path
    $shape.Data = $geometry
    $shape.Fill = New-Brush $color
    if ($stroke) { $shape.Stroke = New-Brush $stroke; $shape.StrokeThickness = $m.pw * 2; $shape.StrokeLineJoin = 'Miter' }
    [Windows.Media.RenderOptions]::SetEdgeMode($shape, [Windows.Media.EdgeMode]::Aliased)
    [void]$hop.Children.Add($shape)
    [void]$mascotParts.Add($shape)
    $shape
}
function Build-Mascot {
    foreach ($part in $mascotParts) { $hop.Children.Remove($part) }
    $mascotParts.Clear()
    $script:outlineA = $null; $script:outlineB = $null; $script:feetA = $null; $script:feetB = $null
    $key = Get-MascotKey
    if (-not $key) { return }
    $m = $mascots[$key]
    if ($m.outline) {
        [void](New-SpriteShape $m '[#ou]+' $m.outline $m.outline)
        $script:outlineA = New-SpriteShape $m 'A+' $m.outline $m.outline
        $script:outlineB = New-SpriteShape $m 'B+' $m.outline $m.outline
    }
    [void](New-SpriteShape $m '[#ou]+' $m.body)
    [void](New-SpriteShape $m '[ou]+' $m.face)
    $script:feetA = New-SpriteShape $m 'A+' $m.feet
    $script:feetB = New-SpriteShape $m 'B+' $m.feet
    $script:feetB.Visibility = $(if ($walk.mode -eq 'walking') { 'Hidden' } else { 'Visible' })
    Sync-Outline
}
function Sync-Outline {
    if ($outlineA) { $outlineA.Visibility = $feetA.Visibility; $outlineB.Visibility = $feetB.Visibility }
}
$walk = @{ clock = [Diagnostics.Stopwatch]::StartNew(); duration = 0; start = 0; mode = $null }
Build-Mascot

# The path is the card's rounded border, clockwise; the mascot turns with the corners. It is
# rebuilt when the card changes size, keeping the mascot's place. Outside 'walking' the
# mascot stays in the middle of the top edge.
function Set-WalkPath {
    $w = $card.ActualWidth; $h = $card.ActualHeight
    if (-not $w) { return }
    $origin = $card.TranslatePoint([Windows.Point]::new(0, 0), $mascot.Parent)
    if ($walk.mode -ne 'walking') {
        $mascot.RenderTransform.BeginAnimation([Windows.Media.MatrixTransform]::MatrixProperty, $null)
        $mascot.RenderTransform.Matrix = [Windows.Media.Matrix]::new(1, 0, 0, 1, $origin.X + $w / 2, $origin.Y)
        $walk.duration = 0  # it starts from here when it walks again
        return
    }
    $r = 8; $left = $origin.X; $right = $origin.X + $w; $top = $origin.Y; $bottom = $origin.Y + $h
    $data = [string]::Format([Globalization.CultureInfo]::InvariantCulture,
        'M {0},{2} L {1},{2} A {8},{8} 0 0 1 {3},{4} L {3},{5} A {8},{8} 0 0 1 {1},{6} L {0},{6} A {8},{8} 0 0 1 {7},{5} L {7},{4} A {8},{8} 0 0 1 {0},{2} Z',
        [object[]]@(($left + $r), ($right - $r), $top, $right, ($top + $r), ($bottom - $r), $bottom, $left, $r))
    $perimeter = 2 * ($w + $h) - (8 - 2 * [math]::PI) * $r
    # how far around the card it is; when it starts walking, the middle of the top edge
    $fraction = $(if ($walk.duration) { ($walk.clock.Elapsed.TotalSeconds + $walk.start) % $walk.duration / $walk.duration }
                  else { ($w / 2 - $r) / $perimeter })
    $walk.duration = $perimeter / 50  # about 50 px/s
    $walk.start = $fraction * $walk.duration
    $walk.clock.Restart()
    $animation = New-Object Windows.Media.Animation.MatrixAnimationUsingPath
    $animation.PathGeometry = [Windows.Media.PathGeometry]::CreateFromGeometry([Windows.Media.Geometry]::Parse($data))
    $animation.DoesRotateWithTangent = $true
    $animation.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds($walk.duration))
    $animation.BeginTime = [TimeSpan]::FromSeconds(-$walk.start)
    $animation.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($animation, 40)
    $mascot.RenderTransform.BeginAnimation([Windows.Media.MatrixTransform]::MatrixProperty, $animation)
}
$card.Add_SizeChanged({ Set-WalkPath })

$step = New-Object Windows.Threading.DispatcherTimer
$step.Interval = [TimeSpan]::FromMilliseconds(160)  # one step per half jump
$step.Add_Tick({
    if (-not $feetA) { return }
    $shown = $feetA.Visibility
    $feetA.Visibility = $feetB.Visibility
    $feetB.Visibility = $shown
    Sync-Outline
})

# 'walking' (a session works): walks, hops and steps. 'jumping' (a question or permission):
# hops on top of the card. 'standing' (nothing runs): stands on top, all feet down.
function Set-MascotMode($mode) {
    if (-not $config.mascot -or -not $feetA) {
        $step.Stop()
        $mascot.Visibility = 'Hidden'
        $walk.mode = $null
        return
    }
    $mascot.Visibility = 'Visible'
    if ($walk.mode -eq $mode) { return }
    $walk.mode = $mode
    $walking = $mode -eq 'walking'
    $hop.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $(if ($mode -eq 'standing' -or $Snapshot) { $null } else { $jump }))
    $step.Stop()
    $feetA.Visibility = 'Visible'
    $feetB.Visibility = $(if ($walking) { 'Hidden' } else { 'Visible' })
    Sync-Outline
    if ($walking -and -not $Snapshot) { $step.Start() }
    Set-WalkPath
}

# Born in the bottom-right corner (the margin keeps the card off the edge). Only dragging
# moves it: right after opening, WPF sometimes throws a transparent window elsewhere, so it
# is put back right away and every 2 s.
$area = [Windows.SystemParameters]::WorkArea
$place.x = $area.Right - $win.Width
$place.y = $area.Bottom - $win.Height
if ($Snapshot) { $place.x = -10000; $win.ShowActivated = $false }  # drawn off screen
function Restore-Position {
    if ($place.dragging) { return }
    if ([math]::Abs($win.Left - $place.x) -gt 1 -or [math]::Abs($win.Top - $place.y) -gt 1) {
        $win.Left = $place.x
        $win.Top = $place.y
    }
}
$win.Left = $place.x
$win.Top = $place.y
$win.Add_LocationChanged({ Restore-Position })

# The element under a point, from its Tag: "session:<id>", "collapse:<id>" or nothing.
function Get-TargetAt($point) {
    for ($e = [Windows.Media.VisualTreeHelper]::HitTest($win, $point).VisualHit; $e; $e = [Windows.Media.VisualTreeHelper]::GetParent($e)) {
        if ("$($e.Tag)" -like 'session:*' -or "$($e.Tag)" -like 'collapse:*') { return "$($e.Tag)" }
    }
}
$win.Add_MouseLeftButtonDown({
    # DragMove runs the timers inside this handler, and PowerShell resolves variables through
    # the call stack: names here must not shadow the script's own variables.
    $pressedTarget = Get-TargetAt ($_.GetPosition($win))
    $place.dragging = $true
    try { $win.DragMove() } finally { $place.dragging = $false }
    $wasClick = [math]::Abs($win.Left - $place.x) -le 2 -and [math]::Abs($win.Top - $place.y) -le 2
    $place.x = $win.Left
    $place.y = $win.Top
    if ($wasClick -and $pressedTarget -like 'collapse:*') {
        $sessionId = $pressedTarget.Substring(9)
        $collapsed[$sessionId] = -not [bool]$collapsed[$sessionId]
        Update-Window
    }
})
$win.Dispatcher.Add_UnhandledException({ Write-Log "error: $($_.Exception.GetType().Name)" })

# --- Right-click menu, styled like the card. It is rebuilt on every right-click, so it lists
# the mascots and themes of the files as they are now. Themes and sizes sit in submenus.
$menu = [Windows.Markup.XamlReader]::Parse(@'
<ContextMenu xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             HasDropShadow="False" FontFamily="Inter, Segoe UI" FontSize="12">
  <ContextMenu.Template>
    <ControlTemplate TargetType="ContextMenu">
      <Border Background="#1C1D2F" BorderBrush="#33365A" BorderThickness="1,1,0,0" Padding="0,4">
        <ItemsPresenter/>
      </Border>
    </ControlTemplate>
  </ContextMenu.Template>
  <ContextMenu.Resources>
    <Style TargetType="MenuItem">
      <Setter Property="Foreground" Value="#DEDAF4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Grid>
              <Border x:Name="bd" Background="Transparent" Padding="12,5">
                <DockPanel>
                  <TextBlock x:Name="arrow" DockPanel.Dock="Right" Text="&#x203A;" FontSize="14"
                             Foreground="#A6A5C4" Margin="18,0,0,0" VerticalAlignment="Center"
                             Visibility="Collapsed"/>
                  <StackPanel Orientation="Horizontal">
                    <Border x:Name="box" Width="11" Height="11" BorderBrush="#5A5D86"
                            BorderThickness="1" CornerRadius="2" VerticalAlignment="Center"
                            Margin="0,0,6,0" Visibility="Collapsed">
                      <Border x:Name="tick" Width="5" Height="5" CornerRadius="1" Background="#DEDAF4"
                              Visibility="Collapsed"/>
                    </Border>
                    <ContentPresenter ContentSource="Header" VerticalAlignment="Center" RecognizesAccessKey="True"/>
                  </StackPanel>
                </DockPanel>
              </Border>
              <Popup x:Name="PART_Popup" Placement="Right" HorizontalOffset="-2" VerticalOffset="-5"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="None"
                     IsOpen="{Binding IsSubmenuOpen, RelativeSource={RelativeSource TemplatedParent}}">
                <Border Background="#1C1D2F" BorderBrush="#33365A" BorderThickness="1" Padding="0,4">
                  <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Cycle"/>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="HasItems" Value="True">
                <Setter TargetName="arrow" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A2C48"/>
              </Trigger>
              <Trigger Property="IsCheckable" Value="True">
                <Setter TargetName="box" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
                <Setter TargetName="box" Property="BorderBrush" Value="#A6A5C4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Separator">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Separator">
            <Border Background="#33FFFFFF" Height="1" Margin="0,3"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </ContextMenu.Resources>
</ContextMenu>
'@)

# A menu item, in the menu or in a submenu; its Tag tells the handler what it is ($this is the
# clicked item).
function Add-MenuItem($header, $checked, $tag, $onClick, $parent = $menu) {
    $item = New-Object Windows.Controls.MenuItem
    $item.Header = $header
    if ($null -ne $checked) { $item.IsCheckable = $true; $item.IsChecked = $checked }
    $item.Tag = $tag
    $item.Add_Click($onClick)
    [void]$parent.Items.Add($item)
}
function Add-Submenu($header) {
    $item = New-Object Windows.Controls.MenuItem
    $item.Header = $header
    [void]$menu.Items.Add($item)
    $item
}
function Add-Separator { [void]$menu.Items.Add((New-Object Windows.Controls.Separator)) }
function Add-SliderItem($label, $minimum, $value, $onChange) {
    $panel = New-Object Windows.Controls.StackPanel
    $panel.Orientation = 'Horizontal'
    $panel.Margin = [Windows.Thickness]::new(0, 2, 0, 2)
    [void]$panel.Children.Add((New-Text $label '#DEDAF4' 70))
    $slider = New-Object Windows.Controls.Slider
    $slider.Minimum = $minimum; $slider.Maximum = 100; $slider.Value = $value * 100
    $slider.Width = 85; $slider.VerticalAlignment = 'Center'
    $percent = New-Text ('{0}%' -f [int]($value * 100)) '#A6A5C4' 32
    $percent.TextAlignment = 'Right'
    $slider.Add_ValueChanged({ $percent.Text = '{0}%' -f [int]$slider.Value; & $onChange ([math]::Round($slider.Value / 100, 2)) }.GetNewClosure())
    [void]$panel.Children.Add($slider)
    [void]$panel.Children.Add($percent)
    [void]$menu.Items.Add($panel)
}

function Build-Menu($removeId) {
    $menu.Items.Clear()
    # Remove one session from the list (only on a session row): deletes its state file; a
    # session that is still alive comes back on its next hook event.
    if ($removeId) {
        Add-MenuItem 'Remove session from the monitor' $null $removeId {
            if ("$($this.Tag)" -match '^[A-Za-z0-9_-]{1,128}$') {
                Remove-Item -LiteralPath (Join-Path $sessionsDir "$($this.Tag).json") -Force -ErrorAction Ignore
                Update-Window
            }
        }
        Add-Separator
    }
    Add-MenuItem 'Show mascot' $config.mascot $null { $config.mascot = $this.IsChecked; Save-Config; Update-Window }
    $current = Get-MascotKey
    foreach ($key in $mascots.Keys) {
        Add-MenuItem "Mascot: $($mascots[$key].name)" ($key -eq $current) $key {
            $config.character = "$($this.Tag)"; Save-Config; $walk.mode = $null; Build-Mascot; Update-Window
        }
    }
    Add-Separator
    $themeMenu = Add-Submenu 'Theme'
    $current = Get-ThemeKey
    foreach ($key in $themes.Keys) {
        Add-MenuItem $themes[$key].name ($key -eq $current) $key {
            $config.theme = "$($this.Tag)"; Save-Config; Set-Theme; Update-Window
        } $themeMenu
    }
    $sizeMenu = Add-Submenu 'Size'
    $current = Get-SizeKey
    foreach ($key in $sizes.Keys) {
        Add-MenuItem (Get-Culture).TextInfo.ToTitleCase($key) ($key -eq $current) $key {
            $config.size = "$($this.Tag)"; Save-Config; Set-Size; Restore-Position
        } $sizeMenu
    }
    Add-Separator
    Add-MenuItem 'Show usage' $config.usage $null {
        $config.usage = $this.IsChecked
        if ($config.usage) { $usage.next = [DateTime]::MinValue } else { $usage.data = $null }
        Save-Config; Update-Window
    }
    Add-MenuItem 'Show subagents' $config.subagents $null { $config.subagents = $this.IsChecked; Save-Config; Update-Window }
    Add-MenuItem 'Window sound' $config.sound $null { $config.sound = $this.IsChecked; Save-Config }
    Add-SliderItem 'Opacity' 20 $config.opacity { param($v) $config.opacity = $v; Set-Opacity $v; Save-Config }
    Add-SliderItem 'Volume' 0 $config.volume { param($v) $config.volume = $v; $player.Volume = $v; Save-Config }
    Add-Separator
    Add-MenuItem 'Close' $null $null { Write-Log 'closed from the menu'; $win.Close() }
}
# The menu as one line, for the snapshot report: items by header ("*" when checked), "-" for a
# separator, "Theme > Dark*, Light" for a submenu, and the sliders by their label.
function Get-MenuOutline {
    $parts = foreach ($entry in $menu.Items) {
        if ($entry -is [Windows.Controls.Separator]) { '-' }
        elseif ($entry -is [Windows.Controls.MenuItem]) {
            $label = "$($entry.Header)$(if ($entry.IsChecked) { '*' })"
            if ($entry.HasItems) {
                $label += ' > ' + (@($entry.Items | ForEach-Object { "$($_.Header)$(if ($_.IsChecked) { '*' })" }) -join ', ')
            }
            $label
        } else { $entry.Children[0].Text }
    }
    $parts -join ' | '
}
$win.Add_PreviewMouseRightButtonDown({
    $rightTarget = Get-TargetAt ($_.GetPosition($win))
    $rightId = $null
    if ($rightTarget -like 'session:*') { $rightId = $rightTarget.Substring(8) }
    elseif ($rightTarget -like 'collapse:*') { $rightId = $rightTarget.Substring(9) }
    Build-Menu $rightId
})
$win.ContextMenu = $menu
try { Add-Type -Namespace PolarisMonitor -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, uint a, ref int v, uint s);' } catch {}
$menu.Add_Opened({
    try {
        $source = [Windows.PresentationSource]::FromVisual($menu)
        if ($source -is [Windows.Interop.HwndSource]) {
            $none = -2  # DWMWA_COLOR_NONE: no white border around the popup
            [void][PolarisMonitor.Dwm]::DwmSetWindowAttribute($source.Handle, 34, [ref]$none, 4)
        }
    } catch {}
})

# "Always on top" sometimes breaks and a normal window comes in front. When that happens, go
# back on top without taking the focus. Only then: otherwise it would fight the Start menu,
# the snipping tool and other always-on-top windows.
if (-not $Snapshot) {
    try {
        Add-Type -Namespace PolarisMonitor -Name Topmost -MemberDefinition @'
[DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
[DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
// Returns the process id of the first normal window (of another process) above this one,
// after going back on top; 0 when nothing is in front.
public static uint Restore(IntPtr h, uint self) {
    for (IntPtr w = GetWindow(h, 3); w != IntPtr.Zero; w = GetWindow(w, 3)) {  // 3 = the one above
        uint pid;
        GetWindowThreadProcessId(w, out pid);
        if (pid == self || !IsWindowVisible(w) || (GetWindowLong(w, -20) & 0x8) != 0) continue;  // 0x8 = topmost
        SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x13);  // -1 = top; 0x13 = no move, size or activate
        return pid;
    }
    return 0;
}
'@
    } catch { Write-Log "always-on-top fix unavailable ($($_.Exception.GetType().Name))" }
}
function Restore-Topmost {
    if (-not ('PolarisMonitor.Topmost' -as [type])) { return }
    [void][PolarisMonitor.Topmost]::Restore((New-Object Windows.Interop.WindowInteropHelper $win).Handle, $PID)
}

# Edited mascot or theme files apply within 2 s, without reopening the window.
function Update-Assets {
    if ((Get-AssetStamps) -eq $assetStamps) { return }
    Import-Assets
    Write-Log 'mascots or themes reloaded'
    $walk.mode = $null
    Build-Mascot
    Set-Theme
}

# This file was replaced by a newer version: close, so the window that was just opened takes
# over. The window never relaunches itself.
function Close-IfUpdated {
    if ($Snapshot) { return }
    if ((Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc -eq $version) { return }
    $timer.Stop()
    Write-Log 'file updated: closing'
    $win.Close()
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ Update-Assets; Update-Window; Restore-Position; Restore-Topmost; Close-IfUpdated })
$timer.Start()

if ($Snapshot) {
    $wait = New-Object Windows.Threading.DispatcherTimer
    $wait.Interval = [TimeSpan]::FromMilliseconds(1200)
    $wait.Add_Tick({
        $wait.Stop()
        $image = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$win.Width, [int]$win.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $image.Render($win.Content)
        $png = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $png.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($image))
        $out = [IO.File]::Create($Snapshot)
        try { $png.Save($out) } finally { $out.Dispose() }
        $report = @(Get-Sessions ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000) | ForEach-Object {
            "session: $($_.name) | hook=$($_.state) | window=$($_.situation) | subagents=$(@($_.subagents | Where-Object { $_ -and $_.id }).Count)"
        })
        $report += "mascot: $(if ($config.mascot -and $feetA) { "$(Get-MascotKey) $($walk.mode)" } else { 'off' })"
        $report += "look: $(Get-ThemeKey) $(Get-SizeKey)"
        $report += "usage: $(if ($usage.data) { ($usage.data.Keys | ForEach-Object { '{0}={1:0}' -f $_, $usage.data[$_].percent }) -join ' ' } else { 'unavailable' })"
        $report += "sound: $(if ($soundChosen) { $soundChosen } else { 'none' })"
        Build-Menu $null
        $report += "menu: $(Get-MenuOutline)"
        [IO.File]::WriteAllLines("$Snapshot.txt", [string[]]$report, [Text.UTF8Encoding]::new($false))
        $win.Close()
    })
    $win.Add_ContentRendered({ $wait.Start() })
}

Update-Window
[void]$win.ShowDialog()
Write-Log "closed ($($Error.Count) errors$(if ($Error.Count) { "; last: $($Error[0].Exception.GetType().Name)" }))"

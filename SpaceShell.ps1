<#
SpaceShell.ps1 — a colourful terminal space shooter for PowerShell
- Works on Windows PowerShell 5.1 and PowerShell 7+
- Uses ANSI colors when available; falls back to ConsoleColor rendering

Controls:
  ←/→ or A/D  Move
  SPACE       Shoot (always 3 bullets: * * *)
  P           Pause
  Q / Esc     Quit

Run:
  .\SpaceShell.ps1
  .\SpaceShell.ps1 -Fps 30 -Lives 3
  .\SpaceShell.ps1 -NewWindow
#>

[CmdletBinding()]
param(
  [int]$Fps = 30,
  [int]$Lives = 3,
  [switch]$NewWindow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Launch game in a new terminal window (PS5-safe)
# Usage: .\SpaceShell.ps1 -NewWindow
# -----------------------------
if ($NewWindow) {
  $self = $PSCommandPath
  if (-not $self) { $self = $MyInvocation.MyCommand.Path }  # PS5 fallback
  if (-not $self) { throw "Cannot relaunch: script path not found." }

  $wd = Split-Path -Parent $self

  $args = @(
    "-NoExit",
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $self,
    "-Fps", $Fps,
    "-Lives", $Lives
  )

  Start-Process -FilePath "powershell.exe" -WorkingDirectory $wd -ArgumentList $args | Out-Null
  return
}

# -----------------------------
# VT / ANSI helpers
# -----------------------------
$ESC = [char]27
$VT = @{
  Reset   = "$ESC[0m"
  HideCur = "$ESC[?25l"
  ShowCur = "$ESC[?25h"
  Home    = "$ESC[H"
  Clear   = "$ESC[2J"
  Bold    = "$ESC[1m"

  Gray    = "$ESC[90m"
  White   = "$ESC[97m"
  Cyan    = "$ESC[96m"
  Green   = "$ESC[92m"
  Yellow  = "$ESC[93m"
  Red     = "$ESC[91m"
  Magenta = "$ESC[95m"
  Blue    = "$ESC[94m"
}

function Test-VtSupport {
  try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    return $true
  } catch {
    return $false
  }
}

$UseVt = Test-VtSupport

# -----------------------------
# Utility
# -----------------------------
function Clamp([int]$v, [int]$min, [int]$max) {
  if ($v -lt $min) { return $min }
  if ($v -gt $max) { return $max }
  return $v
}

function NowMs { [Environment]::TickCount }

function Read-Keys {
  $keys = New-Object System.Collections.Generic.List[ConsoleKeyInfo]
  while ([Console]::KeyAvailable) {
    $keys.Add([Console]::ReadKey($true)) | Out-Null
  }
  return $keys
}

function Safe-Beep([int]$freq = 800, [int]$durMs = 40) {
  try { [Console]::Beep($freq, $durMs) } catch { }
}

# -----------------------------
# Frame buffer with per-cell "color token"
# -----------------------------
enum CToken {
  None = 0
  Star
  Player
  Bullet
  Enemy
  Enemy2
  Hud
  Title
  PowerUp
}

function New-Frame([int]$w, [int]$h) {
  $frame = [ordered]@{
    W = $w
    H = $h
    Ch = New-Object 'char[]' ($w * $h)
    Ct = New-Object 'CToken[]' ($w * $h)
  }
  for ($i=0; $i -lt $frame.Ch.Length; $i++) { $frame.Ch[$i] = ' '; $frame.Ct[$i] = [CToken]::None }
  return $frame
}

function Set-Cell([hashtable]$f, [int]$x, [int]$y, [char]$ch, [CToken]$ct) {
  if ($x -lt 0 -or $y -lt 0 -or $x -ge $f.W -or $y -ge $f.H) { return }
  $idx = $y * $f.W + $x
  $f.Ch[$idx] = $ch
  $f.Ct[$idx] = $ct
}

function Draw-Text([hashtable]$f, [int]$x, [int]$y, [string]$text, [CToken]$ct) {
  for ($i=0; $i -lt $text.Length; $i++) {
    Set-Cell $f ($x + $i) $y $text[$i] $ct
  }
}

function Token-ToVt([CToken]$ct) {
  switch ($ct) {
    ([CToken]::Star)   { return $VT.Gray }
    ([CToken]::Player) { return $VT.Cyan }
    ([CToken]::Bullet) { return $VT.Green }
    ([CToken]::Enemy)  { return $VT.Red }
    ([CToken]::Enemy2) { return $VT.Yellow }
    ([CToken]::Hud)    { return $VT.White }
    ([CToken]::Title)  { return $VT.Magenta + $VT.Bold }
    ([CToken]::PowerUp){ return $VT.Blue }
    default            { return $VT.Reset }
  }
}

function Token-ToConsoleColor([CToken]$ct) {
  switch ($ct) {
    ([CToken]::Star)   { return [ConsoleColor]::DarkGray }
    ([CToken]::Player) { return [ConsoleColor]::Cyan }
    ([CToken]::Bullet) { return [ConsoleColor]::Green }
    ([CToken]::Enemy)  { return [ConsoleColor]::Red }
    ([CToken]::Enemy2) { return [ConsoleColor]::Yellow }
    ([CToken]::Hud)    { return [ConsoleColor]::White }
    ([CToken]::Title)  { return [ConsoleColor]::Magenta }
    ([CToken]::PowerUp){ return [ConsoleColor]::Blue }
    default            { return [ConsoleColor]::Gray }
  }
}

function Render-Frame([hashtable]$f) {
  if ($UseVt) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($VT.Home)

    $w = $f.W; $h = $f.H
    $last = [CToken]::None
    for ($y=0; $y -lt $h; $y++) {
      for ($x=0; $x -lt $w; $x++) {
        $idx = $y*$w + $x
        $ct = $f.Ct[$idx]
        if ($ct -ne $last) {
          $last = $ct
          [void]$sb.Append((Token-ToVt $ct))
        }
        [void]$sb.Append($f.Ch[$idx])
      }
      [void]$sb.Append($VT.Reset)
      if ($y -lt $h - 1) { [void]$sb.Append("`n") }
      $last = [CToken]::None
    }
    [Console]::Write($sb.ToString() + $VT.Reset)
  } else {
    [Console]::SetCursorPosition(0,0)
    $w = $f.W; $h = $f.H
    for ($y=0; $y -lt $h; $y++) {
      $x = 0
      while ($x -lt $w) {
        $idx = $y*$w + $x
        $ct = $f.Ct[$idx]
        [Console]::ForegroundColor = (Token-ToConsoleColor $ct)

        $start = $x
        while ($x -lt $w -and $f.Ct[$y*$w + $x] -eq $ct) { $x++ }
        $len = $x - $start
        $chunk = New-Object 'char[]' $len
        for ($i=0; $i -lt $len; $i++) { $chunk[$i] = $f.Ch[$y*$w + $start + $i] }
        [Console]::Write($chunk -join '')
      }
      if ($y -lt $h - 1) { [Console]::Write("`n") }
    }
    [Console]::ResetColor()
  }
}

# -----------------------------
# Game state & settings
# -----------------------------
function Ensure-TerminalSize {
  $w = [Console]::WindowWidth
  $h = [Console]::WindowHeight
  if ($w -lt 60 -or $h -lt 25) {
    throw "Terminal too small. Resize to at least 60x25. Current: ${w}x${h}"
  }
}

Ensure-TerminalSize

$W = [Console]::WindowWidth
$H = [Console]::WindowHeight

try {
  if ([Console]::BufferWidth -lt $W) { [Console]::BufferWidth = $W }
  if ([Console]::BufferHeight -lt $H) { [Console]::BufferHeight = $H }
} catch { }

$rand = [Random]::new()

# Starfield
$stars = New-Object System.Collections.Generic.List[hashtable]
$starCount = [Math]::Max(60, [int]($W * $H / 35))
for ($i=0; $i -lt $starCount; $i++) {
  $stars.Add(@{ x = $rand.Next(0,$W); y = $rand.Next(0,$H); s = $rand.Next(1,4) }) | Out-Null
}

$player = @{
  x = [int]($W/2)
  y = $H - 3
  cooldown = 0
}

$bullets  = New-Object System.Collections.Generic.List[hashtable]
$enemies  = New-Object System.Collections.Generic.List[hashtable]
$powerUps = New-Object System.Collections.Generic.List[hashtable]

$score = 0
$level = 1
$lives = $Lives
$gameOver = $false
$paused = $false

# Power mode: affects fire rate only
$powerUntilMs = 0
$powerDurationMs = 6000
$powerSpawnAcc = 0.0

# Bullets
$bulletSpeed = 4
$bulletChar  = '*'
$shotOffsets = @(-1, 0, 1)     # always 3 bullets
$baseCooldownMs  = 160
$powerCooldownMs = 95

# Boss (spawn once after Level 1, i.e. when entering Level 2)
$bossSpawned = $false
$bossHp = 18

# Spawn pacing
$spawnAcc  = 0.0
$spawnRate = 0.65

# Enemies pacing
$enemySpeed = 0.16

function Spawn-Enemy {
  param([int]$W)
  $x = $rand.Next(2, $W-2)
  $type = if ($rand.NextDouble() -lt 0.2) { 2 } else { 1 }
  $enemies.Add(@{ x = $x; y = 2; type = $type; hp = if ($type -eq 2) { 2 } else { 1 } }) | Out-Null
}

function Spawn-PowerUp {
  param([int]$W)
  $x = $rand.Next(2, $W-2)
  $powerUps.Add(@{ x = $x; y = 2 }) | Out-Null
}

function Is-Boss([hashtable]$e) {
  return ($null -ne $e -and $e.ContainsKey('boss') -and $e['boss'] -eq $true)
}

function Boss-Alive {
  foreach ($e in $enemies) {
    if (Is-Boss $e) { return $true }
  }
  return $false
}

function Draw-Ship([hashtable]$f, [int]$x, [int]$y) {
  Set-Cell $f ($x-1) $y '/'   ([CToken]::Player)
  Set-Cell $f ($x)   $y 'M'   ([CToken]::Player)
  Set-Cell $f ($x+1) $y '\'   ([CToken]::Player)
  Set-Cell $f ($x-1) ($y+1) '|' ([CToken]::Player)
  Set-Cell $f ($x)   ($y+1) '_' ([CToken]::Player)
  Set-Cell $f ($x+1) ($y+1) '|' ([CToken]::Player)
}

function Draw-Enemy([hashtable]$f, [int]$x, [int]$y, [int]$type, [bool]$boss = $false) {
  if ($type -eq 2) {
    $mid = if ($boss) { 'B' } else { 'A' }
    Set-Cell $f ($x-1) $y '\' ([CToken]::Enemy2)
    Set-Cell $f ($x)   $y $mid ([CToken]::Enemy2)
    Set-Cell $f ($x+1) $y '/' ([CToken]::Enemy2)
    Set-Cell $f ($x-1) ($y+1) '/' ([CToken]::Enemy2)
    Set-Cell $f ($x)   ($y+1) '_' ([CToken]::Enemy2)
    Set-Cell $f ($x+1) ($y+1) '\' ([CToken]::Enemy2)
  } else {
    Set-Cell $f ($x-1) $y '\' ([CToken]::Enemy)
    Set-Cell $f ($x)   $y 'W' ([CToken]::Enemy)
    Set-Cell $f ($x+1) $y '/' ([CToken]::Enemy)
    Set-Cell $f ($x-1) ($y+1) '/' ([CToken]::Enemy)
    Set-Cell $f ($x)   ($y+1) '_' ([CToken]::Enemy)
    Set-Cell $f ($x+1) ($y+1) '\' ([CToken]::Enemy)
  }
}

function Rect-Hit {
  param(
    [int]$ax,[int]$ay,[int]$aw,[int]$ah,
    [int]$bx,[int]$by,[int]$bw,[int]$bh
  )
  return -not (
  $ax + $aw - 1 -lt $bx -or
          $bx + $bw - 1 -lt $ax -or
          $ay + $ah - 1 -lt $by -or
          $by + $bh - 1 -lt $ay
  )
}

function Reset-ConsoleState {
  if ($UseVt) {
    [Console]::Write($VT.Reset + $VT.ShowCur)
  } else {
    [Console]::CursorVisible = $true
    [Console]::ResetColor()
  }
}

# -----------------------------
# Game wrapper: don't close on exceptions
# -----------------------------
try {

  # -----------------------------
  # Title screen
  # -----------------------------
  try {
    if ($UseVt) { [Console]::Write($VT.Clear + $VT.Home + $VT.HideCur) }
    else { [Console]::Clear(); [Console]::CursorVisible = $false }

    $titleFrame = New-Frame $W $H
    $t1 = "SPACE SHELL"
    $t2 = "A tiny PowerShell space shooter"
    $t3 = "← → / A D move   SPACE shoot   P pause   Q/Esc quit"
    $t4 = "Press ENTER to start"

    Draw-Text $titleFrame ([int](($W-$t1.Length)/2)) 5  $t1 ([CToken]::Title)
    Draw-Text $titleFrame ([int](($W-$t2.Length)/2)) 7  $t2 ([CToken]::Hud)
    Draw-Text $titleFrame ([int](($W-$t3.Length)/2)) 10 $t3 ([CToken]::Hud)
    Draw-Text $titleFrame ([int](($W-$t4.Length)/2)) 12 $t4 ([CToken]::Hud)
    Render-Frame $titleFrame

    while ($true) {
      $k = [Console]::ReadKey($true)
      if ($k.Key -eq [ConsoleKey]::Enter) { break }
      if ($k.Key -eq [ConsoleKey]::Escape -or $k.Key -eq [ConsoleKey]::Q) { return }
    }
  } finally { }

  # -----------------------------
  # Main loop
  # -----------------------------
  $dtTarget = [Math]::Max(10, [int](1000 / [Math]::Max(5,$Fps)))
  $lastTick = NowMs
  $accEnemyMove = 0.0
  $accStarMove  = 0.0
  $accPowerMove = 0.0

  try {
    if ($UseVt) { [Console]::Write($VT.Clear + $VT.Home + $VT.HideCur) }
    else { [Console]::Clear(); [Console]::CursorVisible = $false }

    while (-not $gameOver) {
      if ([Console]::WindowWidth -ne $W -or [Console]::WindowHeight -ne $H) {
        throw "Window resized. Restart the game after resizing."
      }

      $now = NowMs
      $dtMs = $now - $lastTick
      if ($dtMs -lt 0) { $dtMs = $dtTarget }
      $lastTick = $now

      $keys = Read-Keys

      foreach ($k in $keys) {
        switch ($k.Key) {
          ([ConsoleKey]::Escape) { $gameOver = $true }
          ([ConsoleKey]::Q)      { $gameOver = $true }
          ([ConsoleKey]::P)      { $paused = -not $paused }
        }
      }

      if (-not $paused) {
        # Input
        $left = $false; $right = $false; $shoot = $false
        foreach ($k in $keys) {
          if ($k.Key -eq [ConsoleKey]::LeftArrow -or $k.Key -eq [ConsoleKey]::A) { $left = $true }
          if ($k.Key -eq [ConsoleKey]::RightArrow -or $k.Key -eq [ConsoleKey]::D) { $right = $true }
          if ($k.Key -eq [ConsoleKey]::Spacebar) { $shoot = $true }
        }

        # Move 1 cell per frame instead of jumping
        if ($left)  { $player.x -= 1 }
        if ($right) { $player.x += 1 }
        $player.x = Clamp $player.x 3 ($W-4)

        # Shooting: ALWAYS 3 bullets (* * *). Power-up affects cooldown only.
        if ($player.cooldown -gt 0) { $player.cooldown -= $dtMs }
        $powerActive = ($now -lt $powerUntilMs)

        if ($shoot -and $player.cooldown -le 0) {
          foreach ($dx in $shotOffsets) {
            $bx = $player.x + $dx
            if ($bx -ge 1 -and $bx -le ($W - 2)) {
              # keep y0 for swept collision
              $bullets.Add(@{ x = $bx; y = ($player.y - 1); y0 = ($player.y - 1) }) | Out-Null
            }
          }
          Safe-Beep 800 50
          $player.cooldown = if ($powerActive) { $powerCooldownMs } else { $baseCooldownMs }
        }

        # Stars drift
        $accStarMove += $dtMs
        if ($accStarMove -ge 60) {
          $steps = [int]($accStarMove / 60)
          $accStarMove -= 60 * $steps
          foreach ($s in $stars) {
            $s.y += $s.s * $steps
            if ($s.y -ge $H) { $s.y = 0; $s.x = $rand.Next(0,$W); $s.s = $rand.Next(1,4) }
          }
        }

        # Spawn enemies (pause normal spawns while boss is alive)
        if (-not (Boss-Alive)) {
          $spawnAcc += ($dtMs / 1000.0) * ($spawnRate + ($level-1)*0.10)
          while ($spawnAcc -ge 1.0) { $spawnAcc -= 1.0; Spawn-Enemy -W $W }
        }

        # Spawn '+' power-up occasionally
        $powerSpawnAcc += ($dtMs / 1000.0) * 0.10
        while ($powerSpawnAcc -ge 1.0) {
          $powerSpawnAcc -= 1.0
          if ($rand.NextDouble() -lt 0.75) { Spawn-PowerUp -W $W }
        }

        # Move bullets (fast) with swept support
        for ($i=$bullets.Count-1; $i -ge 0; $i--) {
          $b = $bullets[$i]
          $b.y0 = $b.y
          $b.y  -= $bulletSpeed
          if ($b.y -lt 1) { $bullets.RemoveAt($i) }
        }

        # Move enemies (SLOWER baseline, slow scaling)
        $accEnemyMove += $dtMs
        $movePeriod = [Math]::Max(70, [int](260 / (1 + ($level-1)*0.08) / [Math]::Max(0.2,$enemySpeed)))
        if ($accEnemyMove -ge $movePeriod) {
          $steps = [int]($accEnemyMove / $movePeriod)
          $accEnemyMove -= $movePeriod * $steps
          for ($i=$enemies.Count-1; $i -ge 0; $i--) {
            $enemies[$i].y += 1 * $steps
            if ($enemies[$i].y -ge $H-2) {
              $enemies.RemoveAt($i)
              $lives--
              if ($lives -le 0) { $gameOver = $true }
            }
          }
        }

        # Move power-ups
        $accPowerMove += $dtMs
        if ($accPowerMove -ge 90) {
          $steps = [int]($accPowerMove / 90)
          $accPowerMove -= 90 * $steps
          for ($i=$powerUps.Count-1; $i -ge 0; $i--) {
            $powerUps[$i].y += 1 * $steps
            if ($powerUps[$i].y -ge $H-1) { $powerUps.RemoveAt($i) }
          }
        }

        # Collisions: player picks up '+'
        for ($pi=$powerUps.Count-1; $pi -ge 0; $pi--) {
          $pup = $powerUps[$pi]
          if (Rect-Hit ($player.x-1) ($player.y) 3 2 ($pup.x) ($pup.y) 1 1) {
            $powerUps.RemoveAt($pi)
            $powerUntilMs = $now + $powerDurationMs
          }
        }

        # Collisions: bullet vs enemy
        for ($bi=$bullets.Count-1; $bi -ge 0; $bi--) {
          $b = $bullets[$bi]

          $hit = $false
          $yTop = [Math]::Min($b.y0, $b.y)
          $yBot = [Math]::Max($b.y0, $b.y)

          for ($ei=$enemies.Count-1; $ei -ge 0; $ei--) {
            $e = $enemies[$ei]

            # Enemy rect is (x-1..x+1) and (y..y+1)
            $ex1 = $e.x - 1; $ex2 = $e.x + 1
            $ey1 = $e.y;     $ey2 = $e.y + 1

            # Swept overlap: bullet x must be inside enemy x-range, and bullet segment crosses enemy y-range
            if ($b.x -ge $ex1 -and $b.x -le $ex2 -and -not ($yBot -lt $ey1 -or $yTop -gt $ey2)) {
              $e.hp -= 1
              $hit = $true
              if ($e.hp -le 0) {
                $score += if ($e.type -eq 2) { 40 } else { 20 }
                if (Is-Boss $e) {
                  Safe-Beep 300 120 # boss defeat sound
                  $score += 200
                }
                $enemies.RemoveAt($ei)
              } else {
                $score += 5
              }
              break
            }
          }
          if ($hit) { $bullets.RemoveAt($bi) }
        }

        # Collisions: player vs enemy
        for ($ei=$enemies.Count-1; $ei -ge 0; $ei--) {
          $e = $enemies[$ei]
          if (Rect-Hit ($player.x-1) ($player.y) 3 2 ($e.x-1) ($e.y) 3 2) {
            $enemies.RemoveAt($ei)
            Safe-Beep 220 120 # crash sound
            $lives--
            if ($lives -le 0) { $gameOver = $true }
          }
        }

        # Level up (spawn boss ONCE after level 1)
        $newLevel = 1 + [int]([Math]::Floor($score / 250))
        if ($newLevel -ne $level) {

          if (-not $bossSpawned -and $newLevel -eq 2) {
            $bossSpawned = $true
            $enemies.Add(@{
              x = [int]($W / 2)
              y = 3
              type = 2
              hp = $bossHp
              boss = $true
            }) | Out-Null
            Safe-Beep 600 120 # boss spawn sound
          }

          $level = $newLevel
          $spawnRate  = [Math]::Min(1.20, 0.65 + ($level-1)*0.06)
          $enemySpeed = [Math]::Min(0.45, 0.16 + ($level-1)*0.018)
        }
      }

      # Render
      $f = New-Frame $W $H

      foreach ($s in $stars) { Set-Cell $f $s.x $s.y '.' ([CToken]::Star) }

      $now2 = NowMs
      $powerLeft = [Math]::Max(0, [int](($powerUntilMs - $now2) / 1000))
      $powerText = if ($powerLeft -gt 0) { "   Power: ON ($powerLeft s)" } else { "" }
      $bossText  = if (Boss-Alive) { "   BOSS!" } else { "" }

      $hud = "Score: $score   Lives: $lives   Level: $level$powerText$bossText"
      Draw-Text $f 2 0 $hud ([CToken]::Hud)
      Draw-Text $f ($W - 26) 0 "P:Pause  Q/Esc:Quit" ([CToken]::Hud)

      if ($paused) {
        $msg = "PAUSED"
        Draw-Text $f ([int](($W-$msg.Length)/2)) ([int]($H/2)-1) $msg ([CToken]::Title)
        $msg2 = "Press P to resume"
        Draw-Text $f ([int](($W-$msg2.Length)/2)) ([int]($H/2)+1) $msg2 ([CToken]::Hud)
      }

      Draw-Ship $f $player.x $player.y
      foreach ($b in $bullets) { Set-Cell $f $b.x $b.y $bulletChar ([CToken]::Bullet) }
      foreach ($pup in $powerUps) { Set-Cell $f $pup.x $pup.y '+' ([CToken]::PowerUp) }
      foreach ($e in $enemies) { Draw-Enemy $f $e.x $e.y $e.type (Is-Boss $e) }

      Render-Frame $f

      $frameSpent = (NowMs) - $now
      $sleep = $dtTarget - $frameSpent
      if ($sleep -gt 0) { Start-Sleep -Milliseconds $sleep }
    }

    # Game over screen
    $end = New-Frame $W $H
    $t1 = "GAME OVER"
    $t2 = "Final Score: $score   Level: $level"
    $t3 = "Press ENTER to exit"
    Draw-Text $end ([int](($W-$t1.Length)/2)) ([int]($H/2)-2) $t1 ([CToken]::Title)
    Draw-Text $end ([int](($W-$t2.Length)/2)) ([int]($H/2)) $t2 ([CToken]::Hud)
    Draw-Text $end ([int](($W-$t3.Length)/2)) ([int]($H/2)+2) $t3 ([CToken]::Hud)
    Render-Frame $end

    while ($true) {
      $k = [Console]::ReadKey($true)
      if ($k.Key -eq [ConsoleKey]::Enter -or $k.Key -eq [ConsoleKey]::Escape -or $k.Key -eq [ConsoleKey]::Q) { break }
    }
  }
  finally {
    Reset-ConsoleState
    try { [Console]::SetCursorPosition(0, [Math]::Min([Console]::CursorTop, [Console]::WindowHeight-1)) } catch { }
    Write-Host ""
  }

}
catch {
  try { Reset-ConsoleState } catch { }
  Write-Host ""
  Write-Host "FATAL ERROR:" -ForegroundColor Red
  Write-Host $_.Exception.ToString()
  Write-Host ""
  Write-Host "Press any key to close..."
  try { [Console]::ReadKey($true) | Out-Null } catch { }
}

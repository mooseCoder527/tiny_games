<#
SpaceShell.ps1 — a colorful terminal space shooter for PowerShell
- Works on Windows PowerShell 5.1 and PowerShell 7+
- Uses ANSI colors when available; falls back to ConsoleColor rendering
Controls: Left/Right or A/D, Space = shoot, P = pause, Q/Esc = quit
#>

[CmdletBinding()]
param(
  [int]$Fps = 30,
  [int]$Lives = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
    # Windows 10+ terminals generally support VT. In classic console, support varies.
    # We'll attempt to print VT and see if it doesn't throw.
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

# -----------------------------
# Frame buffer with per-cell "color token"
# We render as ANSI with minimal color switches (fast), otherwise fallback to ConsoleColor.
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
}

function New-Frame([int]$w, [int]$h) {
  $frame = [ordered]@{
    W = $w
    H = $h
    Ch = New-Object 'char[]' ($w * $h)
    Ct = New-Object 'CToken[]' ($w * $h)
  }
  # Fill with space
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
    default            { return [ConsoleColor]::Gray }
  }
}

function Render-Frame([hashtable]$f) {
  if ($UseVt) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($VT.Home)

    $w = $f.W; $h = $f.H
    $last = [CToken]::None
    $lastVt = $VT.Reset
    for ($y=0; $y -lt $h; $y++) {
      for ($x=0; $x -lt $w; $x++) {
        $idx = $y*$w + $x
        $ct = $f.Ct[$idx]
        if ($ct -ne $last) {
          $last = $ct
          $lastVt = Token-ToVt $ct
          [void]$sb.Append($lastVt)
        }
        [void]$sb.Append($f.Ch[$idx])
      }
      [void]$sb.Append($VT.Reset)
      if ($y -lt $h - 1) { [void]$sb.Append("`n") }
      $last = [CToken]::None
    }
    [Console]::Write($sb.ToString() + $VT.Reset)
  } else {
    # Fallback (slower): set cursor to 0,0 and write line by line grouping colors
    [Console]::SetCursorPosition(0,0)
    $w = $f.W; $h = $f.H
    for ($y=0; $y -lt $h; $y++) {
      $x = 0
      while ($x -lt $w) {
        $idx = $y*$w + $x
        $ct = $f.Ct[$idx]
        $color = Token-ToConsoleColor $ct
        [Console]::ForegroundColor = $color

        # group run
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
# Game state
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

# Keep buffer at least as big as window to avoid scroll
try {
  if ([Console]::BufferWidth -lt $W) { [Console]::BufferWidth = $W }
  if ([Console]::BufferHeight -lt $H) { [Console]::BufferHeight = $H }
} catch { }

# Starfield
$rand = [Random]::new()
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

$bullets = New-Object System.Collections.Generic.List[hashtable]
$enemies = New-Object System.Collections.Generic.List[hashtable]

$score = 0
$level = 1
$lives = $Lives
$gameOver = $false
$paused = $false

# spawn pacing
$spawnAcc = 0.0
$spawnRate = 0.65 # base (higher = more enemies)
$enemySpeed = 0.25

function Spawn-Enemy {
  param([int]$W)
  $x = $rand.Next(2, $W-2)
  $type = if ($rand.NextDouble() -lt 0.2) { 2 } else { 1 }
  $enemies.Add(@{ x = $x; y = 2; type = $type; hp = if ($type -eq 2) { 2 } else { 1 } }) | Out-Null
}

function Draw-Ship([hashtable]$f, [int]$x, [int]$y) {
  # Small ASCII ship:
  #  /A\
  #  |_|
  Set-Cell $f ($x-1) $y '/'   ([CToken]::Player)
  Set-Cell $f ($x)   $y 'M'   ([CToken]::Player)
  Set-Cell $f ($x+1) $y '\'   ([CToken]::Player)
  Set-Cell $f ($x-1) ($y+1) '|' ([CToken]::Player)
  Set-Cell $f ($x)   ($y+1) '_' ([CToken]::Player)
  Set-Cell $f ($x+1) ($y+1) '|' ([CToken]::Player)
}

function Draw-Enemy([hashtable]$f, [int]$x, [int]$y, [int]$type) {
  if ($type -eq 2) {
    # tougher enemy
    #  \M/
    #  /_\
    Set-Cell $f ($x-1) $y '\' ([CToken]::Enemy2)
    Set-Cell $f ($x)   $y 'A' ([CToken]::Enemy2)
    Set-Cell $f ($x+1) $y '/' ([CToken]::Enemy2)
    Set-Cell $f ($x-1) ($y+1) '/' ([CToken]::Enemy2)
    Set-Cell $f ($x)   ($y+1) '_' ([CToken]::Enemy2)
    Set-Cell $f ($x+1) ($y+1) '\' ([CToken]::Enemy2)
  } else {
    # basic enemy
    #  \W/
    #  /_\
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
# Title screen
# -----------------------------
try {
  if ($UseVt) {
    [Console]::Write($VT.Clear + $VT.Home + $VT.HideCur)
  } else {
    [Console]::Clear()
    [Console]::CursorVisible = $false
  }

  $titleFrame = New-Frame $W $H
  $t1 = "SPACE SHELL"
  $t2 = "A tiny PowerShell space shooter"
  $t3 = "← → / A D move   SPACE shoot   P pause   Q/Esc quit"
  $t4 = "Press ENTER to start"

  Draw-Text $titleFrame ([int](($W-$t1.Length)/2)) 5 $t1 ([CToken]::Title)
  Draw-Text $titleFrame ([int](($W-$t2.Length)/2)) 7 $t2 ([CToken]::Hud)
  Draw-Text $titleFrame ([int](($W-$t3.Length)/2)) 10 $t3 ([CToken]::Hud)
  Draw-Text $titleFrame ([int](($W-$t4.Length)/2)) 12 $t4 ([CToken]::Hud)

  Render-Frame $titleFrame

  while ($true) {
    $k = [Console]::ReadKey($true)
    if ($k.Key -eq [ConsoleKey]::Enter) { break }
    if ($k.Key -eq [ConsoleKey]::Escape -or $k.Key -eq [ConsoleKey]::Q) { return }
  }
} finally {
  # proceed into game
}

# -----------------------------
# Main loop
# -----------------------------
$dtTarget = [Math]::Max(10, [int](1000 / [Math]::Max(5,$Fps)))
$lastTick = NowMs
$accEnemyMove = 0.0
$accStarMove = 0.0

try {
  if ($UseVt) {
    [Console]::Write($VT.Clear + $VT.Home + $VT.HideCur)
  } else {
    [Console]::Clear()
    [Console]::CursorVisible = $false
  }

  while (-not $gameOver) {
    # window changes? keep it simple: detect and exit gracefully
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
      # Input (continuous)
      $left = $false; $right = $false; $shoot = $false
      foreach ($k in $keys) {
        if ($k.Key -eq [ConsoleKey]::LeftArrow -or $k.Key -eq [ConsoleKey]::A) { $left = $true }
        if ($k.Key -eq [ConsoleKey]::RightArrow -or $k.Key -eq [ConsoleKey]::D) { $right = $true }
        if ($k.Key -eq [ConsoleKey]::Spacebar) { $shoot = $true }
      }

      if ($left)  { $player.x -= 2 }
      if ($right) { $player.x += 2 }
      $player.x = Clamp $player.x 3 ($W-4)

      if ($player.cooldown -gt 0) { $player.cooldown -= $dtMs }
      if ($shoot -and $player.cooldown -le 0) {
        $bullets.Add(@{ x = $player.x; y = $player.y - 1 }) | Out-Null
        $player.cooldown = 140
      }

      # Stars drift
      $accStarMove += $dtMs
      if ($accStarMove -ge 60) {
        $steps = [int]($accStarMove / 60)
        $accStarMove -= 60 * $steps
        foreach ($s in $stars) {
          $s.y += $s.s * $steps
          if ($s.y -ge $H) {
            $s.y = 0
            $s.x = $rand.Next(0,$W)
            $s.s = $rand.Next(1,4)
          }
        }
      }

      # Spawn enemies (rate scales with level)
      $spawnAcc += ($dtMs / 1000.0) * ($spawnRate + ($level-1)*0.12)
      while ($spawnAcc -ge 1.0) {
        $spawnAcc -= 1.0
        Spawn-Enemy -W $W
      }

      # Move bullets
      for ($i=$bullets.Count-1; $i -ge 0; $i--) {
        $bullets[$i].y -= 2
        if ($bullets[$i].y -lt 1) { $bullets.RemoveAt($i) }
      }

      # Move enemies (downwards over time)
      $accEnemyMove += $dtMs
      $movePeriod = [Math]::Max(40, [int](180 / (1 + ($level-1)*0.12) / [Math]::Max(0.2,$enemySpeed)))
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

      # Collisions: bullet vs enemy
      for ($bi=$bullets.Count-1; $bi -ge 0; $bi--) {
        $b = $bullets[$bi]
        $hit = $false
        for ($ei=$enemies.Count-1; $ei -ge 0; $ei--) {
          $e = $enemies[$ei]
          # enemy sprite is 3x2 centered on e.x,e.y
          if (Rect-Hit ($b.x) ($b.y) 1 1 ($e.x-1) ($e.y) 3 2) {
            $e.hp -= 1
            $hit = $true
            if ($e.hp -le 0) {
              $score += if ($e.type -eq 2) { 40 } else { 20 }
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
        # player sprite is 3x2 centered on player.x,player.y
        if (Rect-Hit ($player.x-1) ($player.y) 3 2 ($e.x-1) ($e.y) 3 2) {
          $enemies.RemoveAt($ei)
          $lives--
          if ($lives -le 0) { $gameOver = $true }
        }
      }

      # Level up
      $newLevel = 1 + [int]([Math]::Floor($score / 250))
      if ($newLevel -ne $level) {
        $level = $newLevel
        $spawnRate = [Math]::Min(1.35, 0.65 + ($level-1)*0.08)
        $enemySpeed = [Math]::Min(0.75, 0.25 + ($level-1)*0.03)
      }
    }

    # -----------------------------
    # Render
    # -----------------------------
    $f = New-Frame $W $H

    # Stars
    foreach ($s in $stars) {
      Set-Cell $f $s.x $s.y '.' ([CToken]::Star)
    }

    # HUD
    $hud = "Score: $score   Lives: $lives   Level: $level"
    Draw-Text $f 2 0 $hud ([CToken]::Hud)
    Draw-Text $f ($W - 26) 0 "P:Pause  Q/Esc:Quit" ([CToken]::Hud)

    if ($paused) {
      $msg = "PAUSED"
      Draw-Text $f ([int](($W-$msg.Length)/2)) ([int]($H/2)-1) $msg ([CToken]::Title)
      $msg2 = "Press P to resume"
      Draw-Text $f ([int](($W-$msg2.Length)/2)) ([int]($H/2)+1) $msg2 ([CToken]::Hud)
    }

    # Player
    Draw-Ship $f $player.x $player.y

    # Bullets
    foreach ($b in $bullets) {
      Set-Cell $f $b.x $b.y '*' ([CToken]::Bullet)
    }

    # Enemies
    foreach ($e in $enemies) {
      Draw-Enemy $f $e.x $e.y $e.type
    }

    Render-Frame $f

    # Frame pacing
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
